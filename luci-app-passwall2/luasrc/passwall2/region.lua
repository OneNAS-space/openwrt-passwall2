-- Copyright (C) 2026 OneNAS-space
--
-- Region grouping of subscription nodes.
--
-- A subscription with "Group Nodes by Region" enabled gets its nodes created in one group per
-- region (ISO 3166 alpha-2 code: HK, JP, US ...), recognized from the node remarks. The name of
-- the subscription is kept in the "sub_src" option of every grouped node, and sub_of() returns
-- it, so that the old and the new nodes of one subscription are still matched, replaced and
-- deleted together. Nodes whose region cannot be recognized stay in the group named after the
-- subscription.
-- With "Generate Region Balancing Nodes" an Xray batch balancing node is created for every
-- region that has nodes. An existing Xray batch balancing node with the region code as remarks
-- is kept as it is; the region is only added to its node group when it is missing.
--
-- subscribe.lua calls this module while it updates the nodes:
--   md5_extra()      adds the region settings to the MD5 of a subscription, so that a changed
--                    setting is applied by the next update even if the nodes did not change;
--   tag()            sets group and sub_src of a node that is about to be created;
--   sync_balancing() after the nodes are created: creates / completes the balancing nodes;
--   backup()         right before the changes are committed.
-- No node is written twice: the grouping is part of the one call that creates the node.

local api = require "luci.passwall2.api"
local c_config = api.c_config
local i18n = api.i18n
local fs = api.fs
local UrlEncode = api.UrlEncode

local M = {}

-- Backups live in tmpfs: no flash space, no flash wear. Only the newest ones are kept.
local BACKUP_DIR = "/tmp/" .. c_config
local BACKUP_KEEP = 5

local BALANCING_STRATEGY = "leastPing"
local BALANCING_PROBE = "1m"

-- Raise it whenever REGIONS changes, so that the subscriptions are grouped again.
local RULES_VERSION = 1

-- { region code, { keywords }, { excluded keywords (optional) } }
-- Plain substring match, case sensitive; the flag emoji is added automatically.
-- No bare two-letter keywords: "NETWORK" contains "TW".
local REGIONS = {
	{ "HK", { "香港", "Hong Kong", "HongKong" } },
	{ "TW", { "台湾", "台灣", "Taiwan", "台北" } },
	{ "JP", { "日本", "Japan", "东京", "東京", "大阪", "Tokyo", "Osaka" } },
	{ "KR", { "韩国", "韓國", "Korea", "首尔", "首爾", "Seoul" } },
	{ "SG", { "新加坡", "Singapore", "狮城", "獅城" } },
	{ "US", { "美国", "美國", "United States", "USA", "洛杉矶", "洛杉磯", "圣何塞", "聖何塞",
		"硅谷", "西雅图", "西雅圖", "纽约", "紐約", "芝加哥", "达拉斯", "達拉斯",
		"Los Angeles", "San Jose", "Seattle", "New York", "Chicago", "Dallas" } },
	{ "DE", { "德国", "德國", "Germany", "法兰克福", "法蘭克福", "Frankfurt" } },
	{ "GB", { "英国", "英國", "United Kingdom", "Britain", "伦敦", "倫敦", "London" } },
	{ "FR", { "法国", "法國", "France", "巴黎", "Paris" } },
	{ "NL", { "荷兰", "荷蘭", "Netherlands", "阿姆斯特丹", "Amsterdam" } },
	{ "RU", { "俄罗斯", "俄羅斯", "Russia", "莫斯科", "Moscow" } },
	{ "CA", { "加拿大", "Canada", "多伦多", "多倫多", "Toronto", "温哥华", "溫哥華", "Vancouver" } },
	{ "AU", { "澳大利亚", "澳大利亞", "澳洲", "Australia", "悉尼", "Sydney", "墨尔本", "墨爾本", "Melbourne" } },
	{ "NZ", { "新西兰", "新西蘭", "New Zealand" } },
	{ "IN", { "印度", "India", "孟买", "孟買", "Mumbai" }, { "印度尼西亚", "印度尼西亞", "印尼" } },
	{ "ID", { "印度尼西亚", "印度尼西亞", "印尼", "Indonesia", "雅加达", "雅加達", "Jakarta" } },
	{ "MY", { "马来西亚", "馬來西亞", "Malaysia", "吉隆坡" } },
	{ "TH", { "泰国", "泰國", "Thailand", "曼谷", "Bangkok" } },
	{ "VN", { "越南", "Vietnam", "胡志明", "河内", "河內" } },
	{ "PH", { "菲律宾", "菲律賓", "Philippines", "马尼拉", "馬尼拉" } },
	{ "MO", { "澳门", "澳門", "Macau", "Macao" } },
	{ "TR", { "土耳其", "Turkey", "伊斯坦布尔", "伊斯坦布爾" } },
	{ "AE", { "阿联酋", "阿聯酋", "迪拜", "Dubai", "UAE" } },
	{ "SA", { "沙特", "Saudi" } },
	{ "IL", { "以色列", "Israel" } },
	{ "EG", { "埃及", "Egypt" } },
	{ "ZA", { "南非", "South Africa" } },
	{ "NG", { "尼日利亚", "尼日利亞", "Nigeria" } },
	{ "BR", { "巴西", "Brazil" } },
	{ "AR", { "阿根廷", "Argentina" } },
	{ "CL", { "智利", "Chile" } },
	{ "MX", { "墨西哥", "Mexico" } },
	{ "IT", { "意大利", "Italy", "米兰", "米蘭", "Milan" } },
	{ "ES", { "西班牙", "Spain", "马德里", "馬德里", "Madrid" } },
	{ "PT", { "葡萄牙", "Portugal" } },
	{ "CH", { "瑞士", "Switzerland", "苏黎世", "蘇黎世", "Zurich" } },
	{ "SE", { "瑞典", "Sweden", "斯德哥尔摩", "斯德哥爾摩" } },
	{ "NO", { "挪威", "Norway" } },
	{ "DK", { "丹麦", "丹麥", "Denmark" } },
	{ "FI", { "芬兰", "芬蘭", "Finland" } },
	{ "IE", { "爱尔兰", "愛爾蘭", "Ireland" } },
	{ "AT", { "奥地利", "奧地利", "Austria" } },
	{ "BE", { "比利时", "比利時", "Belgium" } },
	{ "PL", { "波兰", "波蘭", "Poland" } },
	{ "CZ", { "捷克", "Czech" } },
	{ "HU", { "匈牙利", "Hungary" } },
	{ "RO", { "罗马尼亚", "羅馬尼亞", "Romania" } },
	{ "BG", { "保加利亚", "保加利亞", "Bulgaria" } },
	{ "GR", { "希腊", "希臘", "Greece" } },
	{ "UA", { "乌克兰", "烏克蘭", "Ukraine" } },
	{ "LU", { "卢森堡", "盧森堡", "Luxembourg" } },
	{ "IS", { "冰岛", "冰島", "Iceland" } },
	{ "KZ", { "哈萨克斯坦", "哈薩克斯坦", "Kazakhstan" } },
	{ "MN", { "蒙古", "Mongolia" } },
	{ "KH", { "柬埔寨", "Cambodia" } },
	{ "PK", { "巴基斯坦", "Pakistan" } },
	{ "BD", { "孟加拉", "Bangladesh" } },
}

-- Regional indicator symbols as UTF-8 (Lua 5.1 has no utf8 library).
local function flag(code)
	local out = {}
	for i = 1, #code do
		out[#out + 1] = string.char(0xF0, 0x9F, 0x87, 0xA6 + code:byte(i) - 65)
	end
	return table.concat(out)
end

local REGION_CODE = {}
for _, r in ipairs(REGIONS) do
	r[2][#r[2] + 1] = flag(r[1])
	r[3] = r[3] or {}
	REGION_CODE[r[1]] = true
end

local function contains(s, k)
	return s:find(k, 1, true) ~= nil
end

-- Returns the list of region codes whose keywords occur in the remarks.
local function classify(remarks)
	local hits = {}
	for _, r in ipairs(REGIONS) do
		local hit = false
		for _, k in ipairs(r[2]) do
			if contains(remarks, k) then hit = true break end
		end
		if hit then
			for _, x in ipairs(r[3]) do
				if contains(remarks, x) then hit = false break end
			end
		end
		if hit then hits[#hits + 1] = r[1] end
	end
	return hits
end

local function log(...)
	api.log(1, ...)
end

-- Per run: the subscriptions seen by tag(), the regions that need a balancing node, and
-- whether this module took part at all (then the config is backed up before the commit).
local state = {
	subs = {},
	order = {},
	codes = {},
	used = false,
}

M.classify = classify

function M.is_code(name)
	return REGION_CODE[(name or ""):upper()] == true
end

-- Name of the subscription a node belongs to: sub_src when the node was put into a region
-- group, otherwise its group (which is the subscription name for subscribed nodes).
function M.sub_of(node)
	local s = node and node.sub_src
	if s and s ~= "" then return s end
	return node and node.group
end

-- Extra data for the MD5 of a subscription, or nil when region grouping is off.
function M.md5_extra(sub_cfg)
	if sub_cfg and sub_cfg.region_group == "1" then
		return { "region", RULES_VERSION, sub_cfg.region_balancing == "1" and "1" or "0" }
	end
	return nil
end

-- Returns the state of a subscription with region grouping enabled, otherwise nil.
local function sub_state(sub_cfg)
	local remark = sub_cfg and sub_cfg.remark
	if not remark or remark == "" or sub_cfg.region_group ~= "1" then return nil end
	local key = remark:lower()
	local s = state.subs[key]
	if s == nil then
		if M.is_code(remark) then
			s = false
			log(i18n.translatef("Region grouping skipped for [%s]: the subscription remark is the same as a region code, please rename it.", remark))
		else
			s = { name = remark, balancing = sub_cfg.region_balancing == "1", grouped = 0, unknown = 0, multi = 0 }
			state.order[#state.order + 1] = s
		end
		state.subs[key] = s
	end
	return s or nil
end

-- Puts a node that is about to be created into its region group. values is the table that is
-- handed to uci:section(); sub_cfg is the subscription the node comes from.
function M.tag(values, sub_cfg)
	local s = sub_state(sub_cfg)
	if not s then return end
	state.used = true
	local hits = classify(tostring(values.remarks or ""))
	if #hits == 1 then
		values.group = hits[1]
		values.sub_src = s.name
		s.grouped = s.grouped + 1
		if s.balancing then state.codes[hits[1]] = true end
	elseif #hits == 0 then
		s.unknown = s.unknown + 1
	else
		s.multi = s.multi + 1
	end
end

-- Creates the balancing node of every region that has nodes, or adds the region to the node
-- group of the existing one. Call it after the nodes have been created.
function M.sync_balancing()
	for _, s in ipairs(state.order) do
		if s.grouped + s.unknown + s.multi > 0 then
			log(i18n.translatef("Region grouping [%s]: %d node(s) grouped by region, %d not recognized, %d matched several regions.",
				s.name, s.grouped, s.unknown, s.multi))
		end
	end

	local codes = {}
	for code in pairs(state.codes) do codes[#codes + 1] = code end
	table.sort(codes)
	state.codes = {}
	if #codes == 0 then return end

	local by_remarks, taken = {}, {}
	api.uci_foreach_c("nodes", function(e)
		taken[e[".name"]] = true
		if e.protocol == "_balancing" and e.remarks then
			by_remarks[e.remarks] = by_remarks[e.remarks] or {}
			table.insert(by_remarks[e.remarks], e)
		end
	end)

	local n_created, n_updated = 0, 0
	for _, code in ipairs(codes) do
		local ng = UrlEncode(code)
		local list = by_remarks[code]
		if not list then
			local id
			repeat id = api.gen_random_char(8) until id ~= "" and not taken[id]
			taken[id] = true
			api.uci:section(c_config, "nodes", id, {
				type = "Xray",
				remarks = code,
				protocol = "_balancing",
				node_add_mode = "batch",
				node_group = ng,
				balancingStrategy = BALANCING_STRATEGY,
				probeInterval = BALANCING_PROBE,
			})
			n_created = n_created + 1
		elseif #list > 1 then
			log(i18n.translatef("Region balancing [%s] skipped: several nodes with this name exist.", code))
		else
			local b = list[1]
			if b.type ~= "Xray" or b.node_add_mode ~= "batch" then
				log(i18n.translatef("Region balancing [%s] skipped: the node with this name is not an Xray batch balancing node.", code))
			else
				local current = type(b.node_group) == "table" and table.concat(b.node_group, " ") or (b.node_group or "")
				local found = false
				for g in current:gmatch("%S+") do
					if g == ng then found = true break end
				end
				if not found then
					api.uci_set_c(b[".name"], "node_group", api.trim(current .. " " .. ng))
					n_updated = n_updated + 1
				end
			end
		end
	end
	if n_created + n_updated > 0 then
		log(i18n.translatef("Region balancing nodes: %d created, %d updated.", n_created, n_updated))
	end
end

-- Copies the committed config to BACKUP_DIR as passwall2.bak-<time>; the newest BACKUP_KEEP
-- copies are kept. Call it right before the staged changes are committed. A failed backup
-- never stops the subscription update.
function M.backup()
	if not state.used then return end
	pcall(function()
		local data = fs.readfile("/etc/config/" .. c_config)
		if not data then return end
		fs.mkdirr(BACKUP_DIR)
		local dest = string.format("%s/%s.bak-%s", BACKUP_DIR, c_config, os.date("%Y%m%d-%H%M%S"))
		if not fs.writefile(dest, data) then return end
		local pattern = "^" .. c_config .. "%.bak%-%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d$"
		local files = {}
		for name in (fs.dir(BACKUP_DIR) or function() end) do
			if name:match(pattern) then files[#files + 1] = name end
		end
		table.sort(files, function(a, b) return a > b end)
		for i = BACKUP_KEEP + 1, #files do
			fs.remove(BACKUP_DIR .. "/" .. files[i])
		end
	end)
end

return M
