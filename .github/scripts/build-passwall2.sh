#!/bin/bash
# .github/scripts/build-passwall2.sh
# Copyright (c) 2026 Jackie264 <OneNAS-space>

#!/bin/bash
# .github/scripts/build-passwall-packages.sh
#
# 在官方 openwrt/sdk 容器内执行。完整复刻原 workflow 里以下几步的逻辑，
# 全部合并到一次 `docker run` 里跑完：
#   1. 配置 feeds.conf.default，安装 feeds
#   2. 打补丁：替换较新的 golang/rust 源码、刷新 patch-kernel.sh、
#      修复 rust host 编译报错
#   3. 生成最小 .config，按 MODE 选择要编译的包
#   4. make download 下载源码
#   5. 编译选中的包
#   6. 把产出的 .apk 收集/改名到 /workspace/staging/<sdk_ver>/<platform>
#
# 环境变量（由 docker run -e 传入）：
#   MODE            "changed" 或 "all"
#   CHANGED_DIRS    MODE=changed 时，逗号分隔的变更目录列表，可能为空
#   SDK_VER         OpenWrt 分支号，例如 "25.12"
#   PLATFORM        当前矩阵平台标识，例如 "x86_64"
#   PACKAGES_REPO   passwall_packages 源仓库 "owner/repo"
#   PASSWALL2_REPO  passwall2 源仓库 "owner/repo"

set -euo pipefail

: "${MODE:?MODE is required}"
: "${SDK_VER:?SDK_VER is required}"
: "${PLATFORM:?PLATFORM is required}"
: "${PACKAGES_REPO:?PACKAGES_REPO is required}"
: "${PASSWALL2_REPO:?PASSWALL2_REPO is required}"
CHANGED_DIRS="${CHANGED_DIRS:-}"

cd /builder

# 防御性处理：部分 SDK tag（尤其是 main/SNAPSHOT 这类 nightly）镜像里只有一个
# setup.sh 桩脚本，需要先执行才能展开真正的 SDK 内容；带具体版本号的稳定 tag
# 通常已经内置好二进制，这一步是幂等的，不会有副作用。
if [ ! -d ./scripts ]; then
  ./setup.sh
fi

echo "::group::1. Configure feeds"
cat > feeds.conf.default <<EOF
src-git passwall_packages https://github.com/${PACKAGES_REPO}.git;main
src-git passwall2 https://github.com/${PASSWALL2_REPO}.git;main
src-git base https://github.com/openwrt/openwrt.git;openwrt-${SDK_VER}
src-git packages https://github.com/openwrt/packages.git;openwrt-${SDK_VER}
src-git luci https://github.com/openwrt/luci.git;openwrt-${SDK_VER}
src-git routing https://github.com/openwrt/routing.git;openwrt-${SDK_VER}
src-git telephony https://github.com/openwrt/telephony.git;openwrt-${SDK_VER}
EOF

./scripts/feeds update -a
./scripts/feeds install -a
echo "::endgroup::"

echo "::group::2. Apply patches"
rm -rf temp_resp
git clone -b master --single-branch https://github.com/openwrt/packages.git temp_resp
echo "update golang version"
rm -rf feeds/packages/lang/golang
cp -r temp_resp/lang/golang feeds/packages/lang
echo "update rust version"
rm -rf feeds/packages/lang/rust
cp -r temp_resp/lang/rust feeds/packages/lang
rm -rf temp_resp

git clone -b main --single-branch https://github.com/openwrt/openwrt.git temp_resp
cp -f temp_resp/scripts/patch-kernel.sh scripts/
rm -rf temp_resp

echo "fixed rust host build error"
sed -i 's/--set=llvm\.download-ci-llvm=true/--set=llvm.download-ci-llvm=false/' feeds/packages/lang/rust/Makefile
grep -q -- '--ci false \\' feeds/packages/lang/rust/Makefile || sed -i '/x\.py \\/a \      --ci false \\' feeds/packages/lang/rust/Makefile

./scripts/feeds update -a
./scripts/feeds install -a
echo "::endgroup::"

echo "::group::3. Generate .config"
cat > .config <<'EOF'
CONFIG_ALL_NONSHARED=n
CONFIG_ALL_KMODS=n
CONFIG_ALL=n
CONFIG_AUTOREMOVE=n
CONFIG_SIGNED_PACKAGES=n
EOF

if [ "$MODE" = "changed" ]; then
  declare -A PKG_MAP
  PKG_MAP["shadowsocks-libev"]="shadowsocks-libev-ss-local shadowsocks-libev-ss-redir shadowsocks-libev-ss-server"
  PKG_MAP["shadowsocks-rust"]="shadowsocks-rust-sslocal shadowsocks-rust-ssserver"
  PKG_MAP["shadowsocksr-libev"]="shadowsocksr-libev-ssr-local shadowsocksr-libev-ssr-redir shadowsocksr-libev-ssr-server"

  if [ -n "$CHANGED_DIRS" ]; then
    IFS=',' read -ra DIRS <<< "$CHANGED_DIRS"
    for DIR in "${DIRS[@]}"; do
      MF="feeds/passwall_packages/$DIR/Makefile"
      if [ -f "$MF" ]; then
        if [[ -n "${PKG_MAP[$DIR]:-}" ]]; then
          for PKG in ${PKG_MAP[$DIR]}; do
            echo "CONFIG_PACKAGE_${PKG}=m" >> .config
            echo "Selected (changed-mode): $PKG"
          done
        else
          PKG_NAME=$(awk -F '[:=]' '/^PKG_NAME[ \t]*[:=]/{print $2}' "$MF" | head -n1 | xargs)
          [ -z "$PKG_NAME" ] && PKG_NAME="$DIR"
          echo "CONFIG_PACKAGE_${PKG_NAME}=m" >> .config
          echo "Selected (changed-mode): $PKG_NAME"
        fi
      fi
    done
  fi

  make defconfig
  COUNT=$(grep -c '^CONFIG_PACKAGE_' .config || true)
  if [ "$COUNT" -eq 0 ]; then
    echo "❌ No changed packages detected, aborting build."
    exit 1
  fi
else
  cat >> .config <<'EOF'
CONFIG_PACKAGE_luci-app-passwall2=m
CONFIG_PACKAGE_luci-app-passwall2_Iptables_Transparent_Proxy=y
CONFIG_PACKAGE_luci-app-passwall2_Nftables_Transparent_Proxy=y
CONFIG_PACKAGE_luci-app-passwall2_INCLUDE_Haproxy=y
CONFIG_PACKAGE_luci-app-passwall2_INCLUDE_IPv6_Nat=y
CONFIG_PACKAGE_luci-app-passwall2_INCLUDE_NaiveProxy=y
CONFIG_PACKAGE_luci-app-passwall2_INCLUDE_Shadowsocks_Libev_Client=y
CONFIG_PACKAGE_luci-app-passwall2_INCLUDE_Shadowsocks_Libev_Server=y
CONFIG_PACKAGE_luci-app-passwall2_INCLUDE_Shadowsocks_Rust_Client=y
CONFIG_PACKAGE_luci-app-passwall2_INCLUDE_Shadowsocks_Rust_Server=y
CONFIG_PACKAGE_luci-app-passwall2_INCLUDE_ShadowsocksR_Libev_Client=y
CONFIG_PACKAGE_luci-app-passwall2_INCLUDE_ShadowsocksR_Libev_Server=y
CONFIG_PACKAGE_luci-app-passwall2_INCLUDE_Simple_Obfs=y
CONFIG_PACKAGE_luci-app-passwall2_INCLUDE_tuic_client=y
CONFIG_PACKAGE_luci-app-passwall2_INCLUDE_V2ray_Plugin=y
EOF
  make defconfig
fi
echo "::endgroup::"

echo "::group::4. Download sources"
make download -j"$(nproc)"
find dl -size -1024c -exec ls -l {} \; || true
echo "::endgroup::"

echo "::group::5. Build packages"
if [ "$MODE" = "changed" ] && [ -n "$CHANGED_DIRS" ]; then
  IFS=',' read -ra DIRS <<< "$CHANGED_DIRS"
  for DIR in "${DIRS[@]}"; do
    make package/"$DIR"/{clean,compile} -j"$(nproc)" V=s
  done
else
  PKGS=(
    chinadns-ng geoview naiveproxy shadowsocks-libev
    shadowsocks-rust shadowsocksr-libev simple-obfs
    tcping tuic-client v2ray-plugin
  )
  for PKG in "${PKGS[@]}"; do
    make package/"$PKG"/{clean,compile} -j"$(nproc)" V=s
  done
fi
echo "::endgroup::"

echo "::group::6. Collect artifacts"
DEST_DIR="/workspace/staging/${SDK_VER}/${PLATFORM}"
mkdir -p "$DEST_DIR"
find bin/packages/*/passwall_packages/ -type f -name "*.apk" | while read -r f; do
  base=$(basename "$f")
  pkgname=$(echo "$base" | sed -E 's/-[0-9].*//')
  standard_name=$(echo "$base" | sed "s/-${PLATFORM}\.apk\$/.apk/")
  echo "✅ Collecting: $pkgname (as $standard_name)"
  rm -f "$DEST_DIR/${pkgname}"*
  cp -v "$f" "$DEST_DIR/$standard_name"
done
echo "::endgroup::"

echo "==> Done."
