--[[
    柔雾瓷白 · 多主题配色管理器（6 套精选柔和主题，全界面实时切换与持久化）
    - 入口：右键菜单「工具 → 主题配色」或 script-message-to theme_picker open-menu
    - 快捷键/消息：
        script-message-to theme_picker open-menu   打开主题选择菜单（点击即实时预览）
        script-message-to theme_picker set <id>    直接切换指定主题
        script-message-to theme_picker cycle       顺序循环切换主题
    - 持久化：~~/saved-theme.json
    - 广播属性：user-data/porcelain/theme（uosc 与全部自定义面板/浮窗实时同步配色）
]]

local mp = require("mp")
local utils = require("mp.utils")

local STATE_PATH = mp.command_native({"expand-path", "~~/saved-theme.json"})
local DEFAULT_THEME_ID = "porcelain"

local function rgb_to_bgr(hex)
    hex = tostring(hex or ""):gsub("^#", "")
    if #hex ~= 6 then return "000000" end
    return (hex:sub(5, 6) .. hex:sub(3, 4) .. hex:sub(1, 2)):upper()
end

-- Unified 6-theme palette (shared with Android Porcelain MPV)
local THEMES = {
    {
        id = "porcelain",
        name = "柔雾瓷白",
        hint = "瓷白浅底 · 静谧钴蓝",
        is_dark = false,
        bg            = "F4F6FA",
        idle_bg       = "#E9EEF5",
        play_bg       = "#12151C",
        surface       = "FFFFFF",
        surface_hover = "EAF1F8",
        fg            = "3578B8",
        fg_hover      = "2864A0",
        fg_soft       = "DAE6F3",
        fgt           = "FFFFFF",
        bgt           = "1E293B",
        muted         = "64748B",
        track         = "CBD5E1",
        curtain       = "E2E8F0",
        success       = "2A9D6F",
        error         = "D6455D",
        error_hover   = "BD334A",
        match         = "2563EB",
        heatmap       = "569CE0",
    },
    {
        id = "sakura",
        name = "樱雾浅粉",
        hint = "樱雾奶白 · 淡雅绯樱",
        is_dark = false,
        bg            = "FBF4F6",
        idle_bg       = "#F3E7EB",
        play_bg       = "#141115",
        surface       = "FFFFFF",
        surface_hover = "F7E8EE",
        fg            = "C85A7C",
        fg_hover      = "AE4567",
        fg_soft       = "F6DCE4",
        fgt           = "FFFFFF",
        bgt           = "2E1E25",
        muted         = "7A606A",
        track         = "E2CCD4",
        curtain       = "EFE1E6",
        success       = "2E9B72",
        error         = "D6455D",
        error_hover   = "BC3249",
        match         = "C85A7C",
        heatmap       = "E07B9B",
    },
    {
        id = "celadon",
        name = "青瓷抹茶",
        hint = "冰青瓷白 · 温润竹绿",
        is_dark = false,
        bg            = "F2F7F4",
        idle_bg       = "#E4EFE9",
        play_bg       = "#101614",
        surface       = "FFFFFF",
        surface_hover = "E4F0EA",
        fg            = "2E8B6E",
        fg_hover      = "227259",
        fg_soft       = "D5EDE4",
        fgt           = "FFFFFF",
        bgt           = "1B2D26",
        muted         = "5B746A",
        track         = "C5D9D0",
        curtain       = "DDEAE4",
        success       = "2A9D6F",
        error         = "D6455D",
        error_hover   = "BD334A",
        match         = "2E8B6E",
        heatmap       = "52AD90",
    },
    {
        id = "amber",
        name = "暖纸琥珀",
        hint = "暖杏米纸 · 温润琥珀",
        is_dark = false,
        bg            = "FAF6EF",
        idle_bg       = "#F1EADF",
        play_bg       = "#161310",
        surface       = "FFFDF9",
        surface_hover = "F3EAD9",
        fg            = "C2762A",
        fg_hover      = "A65F1C",
        fg_soft       = "F4E1C8",
        fgt           = "FFFFFF",
        bgt           = "2D241C",
        muted         = "78695B",
        track         = "DFD3C3",
        curtain       = "EAE1D3",
        success       = "2E9368",
        error         = "D24B4B",
        error_hover   = "B73838",
        match         = "C2762A",
        heatmap       = "DE964E",
    },
    {
        id = "midnight",
        name = "暮夜深蓝",
        hint = "暮夜深蓝 · 晴空柔蓝",
        is_dark = true,
        bg            = "161E2B",
        idle_bg       = "#111824",
        play_bg       = "#0D121A",
        surface       = "212C3E",
        surface_hover = "2A384F",
        fg            = "6CA8E8",
        fg_hover      = "84B9F0",
        fg_soft       = "213954",
        fgt           = "0D1B2A",
        bgt           = "E6EDF6",
        muted         = "96A8BE",
        track         = "334358",
        curtain       = "0B1018",
        success       = "46C291",
        error         = "E86B7E",
        error_hover   = "F28091",
        match         = "7CB4E8",
        heatmap       = "5E9BE0",
    },
    {
        id = "obsidian",
        name = "极夜墨黑",
        hint = "极夜深墨 · 冰雾蓝白",
        is_dark = true,
        bg            = "0E1117",
        idle_bg       = "#080A0F",
        play_bg       = "#06080C",
        surface       = "191F29",
        surface_hover = "232B38",
        fg            = "7EB8F2",
        fg_hover      = "96C8F8",
        fg_soft       = "1B2D42",
        fgt           = "09131F",
        bgt           = "EDF2F8",
        muted         = "8E9BAD",
        track         = "2A3342",
        curtain       = "05070B",
        success       = "4AC796",
        error         = "EB6E80",
        error_hover   = "F58394",
        match         = "7EB8F2",
        heatmap       = "6AA8E8",
    },
}

local THEMES_BY_ID = {}
for idx, t in ipairs(THEMES) do
    t._index = idx
    THEMES_BY_ID[t.id] = t
end

local current_id = DEFAULT_THEME_ID

local function load_saved_theme()
    local f = io.open(STATE_PATH, "rb")
    if not f then return DEFAULT_THEME_ID end
    local raw = f:read("*a")
    f:close()
    local parsed = raw and utils.parse_json(raw)
    if type(parsed) == "table" and type(parsed.theme) == "string" and THEMES_BY_ID[parsed.theme] then
        return parsed.theme
    end
    return DEFAULT_THEME_ID
end

local function save_theme(id)
    local payload = utils.format_json({ theme = id })
    if not payload then return end
    local f = io.open(STATE_PATH, "wb")
    if f then
        f:write(payload)
        f:close()
    end
end

local function build_payload(t)
    return {
        id            = t.id,
        name          = t.name,
        is_dark       = t.is_dark,
        bg            = rgb_to_bgr(t.bg),
        surface       = rgb_to_bgr(t.surface),
        surface_hover = rgb_to_bgr(t.surface_hover),
        fg            = rgb_to_bgr(t.fg),
        fg_hover      = rgb_to_bgr(t.fg_hover),
        fg_soft       = rgb_to_bgr(t.fg_soft),
        fgt           = rgb_to_bgr(t.fgt),
        bgt           = rgb_to_bgr(t.bgt),
        muted         = rgb_to_bgr(t.muted),
        track         = rgb_to_bgr(t.track),
        curtain       = rgb_to_bgr(t.curtain),
        shadow        = "000000",
        shadow_mult   = t.is_dark and 2.2 or 1.0,
        success       = rgb_to_bgr(t.success),
        error         = rgb_to_bgr(t.error),
        error_hover   = rgb_to_bgr(t.error_hover),
        match         = rgb_to_bgr(t.match),
        heatmap       = rgb_to_bgr(t.heatmap),
    }
end

local function sync_background_color()
    local t = THEMES_BY_ID[current_id] or THEMES[1]
    local is_idle = mp.get_property_bool("idle-active", false)
    mp.set_property("background-color", is_idle and t.idle_bg or t.play_bg)
end

local function apply_theme(id, persist, notify)
    local t = THEMES_BY_ID[id] or THEMES[1]
    current_id = t.id
    mp.set_property_native("user-data/porcelain/theme", build_payload(t))
    sync_background_color()
    if persist then
        save_theme(t.id)
    end
    if notify then
        mp.osd_message("主题配色：" .. t.name, 1.8)
    end
end

local function open_menu(action)
    if (not action or action == "open-menu")
        and mp.get_property_native("user-data/uosc/menu/type") == "theme_picker_menu" then
        mp.commandv("script-message-to", "uosc", "close-menu")
        return
    end

    local items = {}
    for i, t in ipairs(THEMES) do
        local active = (t.id == current_id)
        local icon = active and "check_circle" or (t.is_dark and "dark_mode" or "light_mode")
        table.insert(items, {
            title = t.name,
            hint = t.hint,
            icon = icon,
            active = active,
            keep_open = true,
            separator = (i == 4), -- subtle divider between 4 light themes and 2 dark themes
            value = { "script-message-to", "theme_picker", "set", t.id },
        })
    end

    local menu = {
        type = "theme_picker_menu",
        title = "主题配色",
        search_style = "disabled",
        items = items,
    }
    mp.commandv("script-message-to", "uosc", action or "open-menu", utils.format_json(menu))
end

mp.register_script_message("open-menu", function()
    open_menu("open-menu")
end)

mp.register_script_message("set", function(id)
    if not THEMES_BY_ID[id] then return end
    apply_theme(id, true, false)
    if mp.get_property_native("user-data/uosc/menu/type") == "theme_picker_menu" then
        open_menu("update-menu")
    else
        mp.osd_message("主题配色：" .. THEMES_BY_ID[id].name, 1.8)
    end
end)

mp.register_script_message("cycle", function()
    local cur = THEMES_BY_ID[current_id] or THEMES[1]
    local nxt = THEMES[(cur._index % #THEMES) + 1]
    apply_theme(nxt.id, true, true)
    if mp.get_property_native("user-data/uosc/menu/type") == "theme_picker_menu" then
        open_menu("update-menu")
    end
end)

mp.observe_property("idle-active", "bool", function()
    sync_background_color()
end)

-- Startup init
current_id = load_saved_theme()
apply_theme(current_id, false, false)
