#!/bin/bash
# .github/scripts/build-passwall2.sh
#

set -euo pipefail

: "${OW_VER:?OW_VER is required}"
: "${PASSWALL2_REPO:?PASSWALL2_REPO is required}"
: "${GIT_REF:?GIT_REF is required}"

cd /builder

if [ ! -d ./scripts ]; then
  ./setup.sh
fi

echo "==> 1. Setup Feeds"
cat > feeds.conf.default <<EOF
src-git passwall2 https://github.com/${PASSWALL2_REPO}.git;${GIT_REF}
src-git base https://github.com/openwrt/openwrt.git;openwrt-${OW_VER}
src-git packages https://github.com/openwrt/packages.git;openwrt-${OW_VER}
src-git luci https://github.com/openwrt/luci.git;openwrt-${OW_VER}
src-git routing https://github.com/openwrt/routing.git;openwrt-${OW_VER}
src-git telephony https://github.com/openwrt/telephony.git;openwrt-${OW_VER}
EOF

./scripts/feeds update -a
./scripts/feeds install -a

echo "==> 2. Apply custom patches (newer golang/rust, refreshed patch-kernel.sh)"
git clone -b master --single-branch https://github.com/openwrt/packages.git temp_resp
rm -rf feeds/packages/lang/golang feeds/packages/lang/rust
cp -r temp_resp/lang/golang feeds/packages/lang/
cp -r temp_resp/lang/rust feeds/packages/lang/

git clone -b main --single-branch https://github.com/openwrt/openwrt.git temp_openwrt
cp -f temp_openwrt/scripts/patch-kernel.sh scripts/
rm -rf temp_resp temp_openwrt

echo "==> 3. Compile luci-app-passwall2"
cat > .config <<'EOF'
CONFIG_ALL_NONSHARED=n
CONFIG_ALL_KMODS=n
CONFIG_ALL=n
CONFIG_AUTOREMOVE=n
CONFIG_PACKAGE_luci-app-passwall2=m
EOF

make defconfig
make package/luci-app-passwall2/{clean,compile} -j"$(nproc)" V=s

echo "==> 4. Export artifacts"
mkdir -p /workspace/artifacts
find bin/packages/ -type f -name '*passwall2*.apk' -exec cp {} /workspace/artifacts/ \;

make clean

echo "==> Done."
