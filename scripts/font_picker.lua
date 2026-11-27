--[[
    独立字体选择器（支持界面字体与弹幕字体各自自由切换 + 搜索系统已安装字体 + 持久化保存）
    - 界面字体：script-message-to font_picker open-ui-font（持久化到 ~~/saved-ui-font.json）
    - 弹幕字体：script-message-to font_picker open-danmaku-font（调用 uosc_danmaku 实时保存）
]]

local mp = require("mp")
local utils = require("mp.utils")

local DEFAULT_FONT = "Microsoft YaHei UI"
local UI_FONT_STATE_PATH = mp.command_native({"expand-path", "~~/saved-ui-font.json"})

local CURATED_FONTS = {
    { id = "Microsoft YaHei UI", label = "微软雅黑 UI", always = true },
    { id = "微软雅黑",           label = "微软雅黑",    aliases = { "Microsoft YaHei" } },
    { id = "黑体",               label = "黑体",        aliases = { "SimHei" } },
    { id = "楷体",               label = "楷体",        aliases = { "KaiTi" } },
    { id = "仿宋",               label = "仿宋",        aliases = { "FangSong" } },
    { id = "幼圆",               label = "幼圆",        aliases = { "YouYuan" } },
    { id = "等线",               label = "等线",        aliases = { "DengXian" } },
}

local cached_system_fonts = nil
local loading_system_fonts = false
local pending_callbacks = {}
local current_dm_font = DEFAULT_FONT

local function load_saved_ui_font()
    local f = io.open(UI_FONT_STATE_PATH, "rb")
    if not f then return nil end
    local raw = f:read("*a")
    f:close()
    if not raw or raw == "" then return nil end
    local parsed = utils.parse_json(raw)
    if type(parsed) == "table" and type(parsed.font) == "string" and parsed.font ~= "" then
        return parsed.font
    end
    return nil
end

local function save_ui_font(font)
    local payload = utils.format_json({ font = font })
    if not payload then return end
    local f = io.open(UI_FONT_STATE_PATH, "wb")
    if f then
        f:write(payload)
        f:close()
    end
end

local function load_saved_danmaku_font()
    local path = mp.command_native({"expand-path", "~~/saved-danmaku-style.json"})
    local f = io.open(path, "rb")
    if not f then return current_dm_font end
    local raw = f:read("*a")
    f:close()
    local parsed = raw and utils.parse_json(raw) or nil
    if type(parsed) == "table" and type(parsed.fontname) == "string" and parsed.fontname ~= "" then
        current_dm_font = parsed.fontname
    end
    return current_dm_font
end

local function fetch_system_fonts(cb)
    if cached_system_fonts then
        cb(cached_system_fonts)
        return
    end
    table.insert(pending_callbacks, cb)
    if loading_system_fonts then return end
    loading_system_fonts = true

    local ps_cmd = "[Console]::OutputEncoding=[System.Text.Encoding]::UTF8; "
        .. "Add-Type -AssemblyName System.Drawing; "
        .. "(New-Object System.Drawing.Text.InstalledFontCollection).Families | ForEach-Object { $_.Name }"

    mp.command_native_async({
        name = "subprocess",
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
        args = { "powershell", "-NoProfile", "-NonInteractive", "-Command", ps_cmd },
    }, function(success, res)
        loading_system_fonts = false
        local seen = {}
        local list = {}
        if success and res and res.status == 0 and type(res.stdout) == "string" then
            for line in res.stdout:gmatch("[^\r\n]+") do
                local name = line:gsub("^%s+", ""):gsub("%s+$", "")
                if name ~= "" and not seen[name] then
                    seen[name] = true
                    table.insert(list, name)
                end
            end
        end
        table.sort(list, function(a, b) return a:lower() < b:lower() end)
        cached_system_fonts = { list = list, set = seen }

        local cbs = pending_callbacks
        pending_callbacks = {}
        for _, fn in ipairs(cbs) do fn(cached_system_fonts) end
    end)
end

local function build_menu_props(mode, active_font, sys_fonts)
    local is_ui = (mode == "ui")
    local cmd_name = is_ui and "set-ui-font" or "set-danmaku-font"
    local items = {}
    local added = {}

    local function push_font(font_id, title, hint, separator)
        if added[font_id] then return end
        added[font_id] = true
        local is_active = (active_font == font_id)
        table.insert(items, {
            title = title,
            hint = is_active and "当前" or hint,
            active = is_active,
            bold = is_active,
            separator = separator,
            value = { "script-message-to", "font_picker", cmd_name, font_id },
        })
    end

    -- 1. Default reset entry
    push_font(DEFAULT_FONT, "系统默认（微软雅黑 UI）", "默认", false)

    -- 2. Current font if not default
    if active_font and active_font ~= "" and active_font ~= DEFAULT_FONT then
        push_font(active_font, active_font, "当前使用", true)
    end

    -- 3. Curated common Chinese fonts (matched against installed system list)
    local has_sys = sys_fonts and #sys_fonts.list > 0
    local curated_count = 0
    for _, cf in ipairs(CURATED_FONTS) do
        local matched_id = nil
        if cf.always or not has_sys or sys_fonts.set[cf.id] then
            matched_id = cf.id
        elseif cf.aliases then
            for _, al in ipairs(cf.aliases) do
                if sys_fonts.set[al] then
                    matched_id = al
                    break
                end
            end
        end
        if matched_id and not added[matched_id] then
            curated_count = curated_count + 1
            push_font(matched_id, cf.label, matched_id ~= cf.label and matched_id or "", false)
        end
    end
    if curated_count > 0 and #items > 0 then
        items[#items].separator = true
    end

    -- 4. Full installed system fonts
    if has_sys then
        for _, name in ipairs(sys_fonts.list) do
            push_font(name, name, "", false)
        end
    else
        table.insert(items, {
            title = "正在扫描系统已安装字体…",
            muted = true,
            selectable = false,
        })
    end

    return {
        type = is_ui and "font_picker_ui" or "font_picker_dm",
        title = is_ui and "界面字体（可输入搜索）" or "弹幕字体（可输入搜索）",
        footnote = "可直接键入字体名称筛选，选中后立即生效并自动保存",
        search_style = "on_demand",
        items = items,
    }
end

local function open_font_menu(mode, action)
    local is_ui = (mode == "ui")
    local active_font = is_ui
        and (mp.get_property("osd-font") or DEFAULT_FONT)
        or load_saved_danmaku_font()
    local uosc_action = action or "open-menu"

    if cached_system_fonts then
        mp.commandv("script-message-to", "uosc", uosc_action,
            utils.format_json(build_menu_props(mode, active_font, cached_system_fonts)))
    else
        mp.commandv("script-message-to", "uosc", uosc_action,
            utils.format_json(build_menu_props(mode, active_font, nil)))
        fetch_system_fonts(function(sys_fonts)
            local latest = is_ui
                and (mp.get_property("osd-font") or DEFAULT_FONT)
                or load_saved_danmaku_font()
            mp.commandv("script-message-to", "uosc", "update-menu",
                utils.format_json(build_menu_props(mode, latest, sys_fonts)))
        end)
    end
end

mp.register_script_message("open-ui-font", function()
    open_font_menu("ui", "open-menu")
end)

mp.register_script_message("open-danmaku-font", function()
    open_font_menu("dm", "open-menu")
end)

mp.register_script_message("set-ui-font", function(font)
    if not font or font == "" then return end
    mp.set_property("osd-font", font)
    save_ui_font(font)
    mp.osd_message("界面字体：" .. font, 1.8)
    open_font_menu("ui", "update-menu")
end)

mp.register_script_message("set-danmaku-font", function(font)
    if not font or font == "" then return end
    current_dm_font = font
    mp.commandv("script-message", "dm-style-set", "fontname", font, "silent")
    mp.osd_message("弹幕字体：" .. font, 1.8)
    open_font_menu("dm", "update-menu")
end)

-- Restore saved UI font on startup
local saved_ui = load_saved_ui_font()
if saved_ui then
    mp.set_property("osd-font", saved_ui)
end
