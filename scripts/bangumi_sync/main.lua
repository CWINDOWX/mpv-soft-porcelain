--[[
    Bangumi 番剧进度同步脚本（适配 uosc 控制栏与柔和菜单）
    - 自动识别当前播放番剧、集数与单集标题（联动 uosc_danmaku + Bangumi 剧集缓存）
    - 片尾剩余 ≤ 90 秒时轻柔提醒标记本集已看（支持切换：片尾询问 / 自动同步 / 仅手动）
    - 标记已看在当前二级菜单内原地响应：正在请求 -> 同步成功 / 失败
    - 快捷键：Ctrl+B 打开 Bangumi 菜单
    - 控制栏按钮：button:bgm_sync
]]

local mp = require("mp")
local utils = require("mp.utils")
local assdraw = require("mp.assdraw")
local msg = require("mp.msg")
local options = require("mp.options")

local script_opts = {
    prompt_timeout = 5, -- 片尾自动提示窗口倒计时（秒），0 表示不自动消失
    remaining_sec = 90, -- 片尾剩余多少秒时触发提醒/同步
}
options.read_options(script_opts, "bangumi_sync")

local CFG_DIR = mp.command_native({"expand-path", "~~/"})
local SCRIPT_DIR = mp.get_script_directory()
local CLI_PATH = utils.join_path(SCRIPT_DIR, "bgm_cli.py")
local PREF_PATH = mp.command_native({"expand-path", "~~/_cache/bangumi-sync-pref.json"})

-- Find bundled mpv-lazy python.exe first, then fallback to PATH python
local function find_python()
    local parent = utils.split_path(CFG_DIR:gsub("[/\\]+$", ""))
    local bundled = utils.join_path(parent, "python.exe")
    if utils.file_info(bundled) then
        return bundled
    end
    return "python"
end

local PYTHON_BIN = find_python()

local state = {
    logged_in = false,
    nickname = nil,
    username = nil,
    mode = "prompt", -- "prompt" | "auto" | "manual"
    remaining_sec = math.max(5, tonumber(script_opts.remaining_sec) or 90),
    prompt_timeout = math.max(0, tonumber(script_opts.prompt_timeout) or 5),
    prompt_timeout_custom = false,
    current_path = nil,
    subject_id = nil,
    subject_name = nil,
    season = 1,
    episode = nil,
    episode_title = nil,
    synced = false,
    prompted = false,
    busy = false,
    mark_status = nil,  -- nil | "loading" | "success" | "error"
    mark_error = nil,
    login_status = nil, -- nil | "loading" | "error"
    login_error = nil,
    playback_seq = 0,
    match_seq = 0,
    search_seq = 0
}

local open_main_menu
local open_end_prompt
local hide_end_prompt
local is_end_prompt_open

local function load_prefs()
    local f = io.open(PREF_PATH, "rb")
    if not f then return end
    local raw = f:read("*a")
    f:close()
    local parsed = raw and utils.parse_json(raw)
    if type(parsed) == "table" then
        if parsed.mode == "prompt" or parsed.mode == "auto" or parsed.mode == "manual" then
            state.mode = parsed.mode
        end
        if tonumber(parsed.remaining_sec) then
            state.remaining_sec = math.max(5, tonumber(parsed.remaining_sec))
        end
        if parsed.prompt_timeout ~= nil and tonumber(parsed.prompt_timeout) then
            state.prompt_timeout = math.max(0, tonumber(parsed.prompt_timeout))
            state.prompt_timeout_custom = true
        end
    end
end

local function save_prefs()
    local dir = utils.split_path(PREF_PATH)
    if dir and not utils.file_info(dir) then
        mp.command_native({"subprocess", args = {"cmd", "/c", "mkdir", dir}, playback_only = false})
    end
    local f = io.open(PREF_PATH, "wb")
    if not f then return end
    local payload = { mode = state.mode, remaining_sec = state.remaining_sec }
    if state.prompt_timeout_custom then
        payload.prompt_timeout = state.prompt_timeout
    end
    f:write(utils.format_json(payload) or "{}")
    f:close()
end

local function run_cli(args, cb)
    local cmd = { PYTHON_BIN, CLI_PATH, CFG_DIR }
    for _, a in ipairs(args) do
        table.insert(cmd, tostring(a))
    end
    mp.command_native_async({
        name = "subprocess",
        args = cmd,
        capture_stdout = true,
        capture_stderr = true,
        playback_only = false
    }, function(success, res, err)
        if not success or not res or res.status ~= 0 then
            local detail = (res and res.stderr and #res.stderr > 0) and res.stderr or tostring(err or "调用失败")
            msg.warn("bgm_cli error: " .. detail)
            if cb then cb({ ok = false, error = detail }) end
            return
        end
        local data = utils.parse_json(res.stdout or "")
        if type(data) ~= "table" then
            if cb then cb({ ok = false, error = "返回格式异常" }) end
            return
        end
        if cb then cb(data) end
    end)
end

local function publish_match_info()
    if not state.current_path or not state.subject_name or state.subject_name == "" then
        return
    end
    local ep_label = ""
    if state.episode then
        ep_label = "第" .. tostring(state.episode) .. "话"
        if state.episode_title and state.episode_title ~= "" then
            ep_label = ep_label .. " " .. state.episode_title
        end
    elseif state.episode_title and state.episode_title ~= "" then
        ep_label = state.episode_title
    end
    mp.set_property_native("user-data/bangumi_sync/match-info", {
        anime = state.subject_name,
        episode = ep_label,
        episode_num = state.episode,
        episode_title = state.episode_title or "",
        path = state.current_path
    })
end

local function get_open_menu_type()
    return mp.get_property_native("user-data/uosc/menu/type")
end

local function refresh_open_bgm_menu()
    local refreshed = false
    if get_open_menu_type() == "bgm_main_menu" then
        open_main_menu("update-menu")
        refreshed = true
    end
    if is_end_prompt_open and is_end_prompt_open() then
        open_end_prompt("update-menu")
        refreshed = true
    end
    return refreshed
end

local function update_uosc_button()
    local badge = nil
    local active = false
    local tooltip = "Bangumi"

    if state.synced then
        badge = "✓"
        active = true
        tooltip = "Bangumi · 已看"
    elseif state.logged_in then
        badge = state.episode and ("E" .. tostring(state.episode)) or "BGM"
        tooltip = state.subject_name and ("Bangumi · " .. state.subject_name) or "Bangumi"
    else
        badge = nil
        tooltip = "Bangumi · 未登录"
    end

    mp.commandv("script-message-to", "uosc", "set-button", "bgm_sync", utils.format_json({
        icon = state.synced and "bookmark_added" or "bookmark_border",
        active = active,
        badge = badge,
        tooltip = tooltip,
        command = "script-message-to bangumi_sync open-menu"
    }))
end

local function refresh_status(cb)
    run_cli({ "status" }, function(res)
        if res.ok and res.logged_in then
            state.logged_in = true
            state.username = res.username
            state.nickname = res.nickname
        else
            state.logged_in = false
            state.username = nil
            state.nickname = nil
        end
        update_uosc_button()
        if cb then cb() end
    end)
end

local function match_current_file(hint_anime)
    local path = mp.get_property("path")
    if not path or path == "" or path:match("^https?://") then return end
    local duration = mp.get_property_number("duration", 0)
    if duration > 0 and duration < 60 then return end

    state.current_path = path
    state.match_seq = state.match_seq + 1
    local req_seq = state.match_seq
    run_cli({ "match", path, hint_anime or "" }, function(res)
        if req_seq ~= state.match_seq or state.current_path ~= path then return end
        if res.ok and res.matched then
            state.subject_id = res.subject_id
            state.subject_name = res.subject_name
            state.season = res.season or 1
            state.episode = res.episode
            local et = tostring(res.episode_title or ""):gsub("^%s+", ""):gsub("%s+$", "")
            state.episode_title = (et ~= "") and et or nil
            publish_match_info()
            msg.info(string.format("Bangumi 匹配: #%s %s S%sE%s %s",
                tostring(res.subject_id), tostring(res.subject_name),
                tostring(state.season), tostring(state.episode), tostring(state.episode_title or "")))

            -- If uosc_danmaku couldn't match an English/Romaji filename on Dandanplay,
            -- feed the resolved official Chinese title + episode so danmaku loads automatically!
            if state.subject_name and state.episode then
                local captured_path = path
                local captured_seq = req_seq
                local captured_name = state.subject_name
                local captured_season = state.season
                local captured_ep = state.episode
                mp.add_timeout(4.5, function()
                    if captured_seq ~= state.match_seq or state.current_path ~= captured_path then return end
                    if not mp.get_property_bool("user-data/uosc_danmaku/has-danmaku", false) then
                        msg.info("向 uosc_danmaku 补充中文番剧名以自动加载弹幕: " .. captured_name)
                        mp.commandv("script-message-to", "uosc_danmaku", "match-by-title",
                            captured_name, tostring(captured_season), tostring(captured_ep))
                    end
                end)
            end
        else
            state.episode = res.episode
        end
        update_uosc_button()
        refresh_open_bgm_menu()
    end)
end

local function show_mark_feedback(open_if_from_menu, fallback_osd)
    if refresh_open_bgm_menu() then
        return true
    end
    if open_if_from_menu then
        open_main_menu("open-menu")
        return true
    end
    if fallback_osd and fallback_osd ~= "" then
        mp.osd_message(fallback_osd, 3)
    end
    return false
end

local function mark_current_watched(from_menu)
    local cur_menu = get_open_menu_type()
    local want_menu = from_menu or cur_menu == "menu"

    if state.busy then
        if want_menu and cur_menu ~= "bgm_main_menu" and not (is_end_prompt_open and is_end_prompt_open()) then
            open_main_menu("open-menu")
        end
        return
    end
    if not state.logged_in then
        state.mark_status = "error"
        state.mark_error = "请先登录 Bangumi"
        show_mark_feedback(want_menu, state.mark_error)
        return
    end
    if not state.subject_id or not state.episode then
        state.mark_status = "error"
        state.mark_error = not state.subject_id and "尚未关联番剧" or "未识别当前集数"
        show_mark_feedback(want_menu, state.mark_error)
        return
    end

    state.busy = true
    state.mark_status = "loading"
    state.mark_error = nil
    local playback_seq = state.playback_seq
    local subject_id, episode = state.subject_id, state.episode

    show_mark_feedback(want_menu, "Bangumi 同步中…")

    run_cli({ "mark", subject_id, episode }, function(res)
        if playback_seq ~= state.playback_seq then return end
        state.busy = false
        if state.subject_id ~= subject_id or state.episode ~= episode then return end
        if res.ok then
            state.synced = true
            state.prompted = true
            state.mark_status = "success"
            state.mark_error = nil
            local et = tostring(res.episode_title or ""):gsub("^%s+", ""):gsub("%s+$", "")
            if et ~= "" and (not state.episode_title or state.episode_title == "") then
                state.episode_title = et
                publish_match_info()
            end
            update_uosc_button()
            if not refresh_open_bgm_menu() then
                mp.osd_message(string.format("✓ 已标记第 %s 话已看", tostring(state.episode)), 2.5)
            end
        else
            state.mark_status = "error"
            state.mark_error = tostring(res.error or "请求失败"):gsub("[\r\n]+", " ")
            if not refresh_open_bgm_menu() then
                mp.osd_message("Bangumi 同步失败：" .. state.mark_error, 3.5)
            end
        end
    end)
end

local function build_search_menu(query, list)
    return {
        type = "bgm_search_menu",
        title = "搜索番剧",
        search_style = "palette",
        search_debounce = "submit",
        search_suggestion = query or "",
        on_search = { "script-message-to", "bangumi_sync", "do-search" },
        items = list
    }
end

local function execute_search(query, skip_spinner)
    query = tostring(query or ""):gsub("^%s+", ""):gsub("%s+$", "")
    state.search_seq = state.search_seq + 1
    local seq = state.search_seq

    if query == "" then
        mp.commandv("script-message-to", "uosc", "update-menu", utils.format_json(
            build_search_menu("", { { title = "输入番剧名按 Enter 搜索", selectable = false, muted = true, italic = true } })
        ))
        return
    end

    if not skip_spinner then
        mp.commandv("script-message-to", "uosc", "update-menu", utils.format_json(
            build_search_menu(query, { { icon = "spinner", title = "搜索中…", selectable = false, muted = true, italic = true } })
        ))
    end

    run_cli({ "search", query }, function(res)
        -- Ignore stale results if user already started a newer search
        if seq ~= state.search_seq then return end
        if not res.ok then
            mp.commandv("script-message-to", "uosc", "update-menu", utils.format_json(
                build_search_menu(query, { { title = "搜索失败：" .. tostring(res.error or "网络异常"), selectable = false, muted = true } })
            ))
            return
        end
        if not res.items or #res.items == 0 then
            mp.commandv("script-message-to", "uosc", "update-menu", utils.format_json(
                build_search_menu(query, { { title = "无匹配结果", selectable = false, muted = true } })
            ))
            return
        end
        local items = {}
        for _, s in ipairs(res.items) do
            local hint = (s.date ~= "" and s.date or "") .. (s.eps and s.eps > 0 and (" · " .. s.eps .. "话") or "")
            local display_name = (s.name_cn and s.name_cn ~= "") and s.name_cn or s.name
            table.insert(items, {
                title = display_name,
                hint = hint,
                icon = (state.subject_id == s.id) and "check_circle" or "movie",
                active = (state.subject_id == s.id),
                value = { "script-message-to", "bangumi_sync", "bind-subject", tostring(s.id), display_name }
            })
        end
        mp.commandv("script-message-to", "uosc", "update-menu", utils.format_json(
            build_search_menu(query, items)
        ))
    end)
end

local function open_search_menu(initial_query)
    local query = initial_query or state.subject_name or mp.get_property("filename/no-ext") or ""
    query = tostring(query):gsub("^%s+", ""):gsub("%s+$", "")

    local initial_items = query ~= ""
        and { { icon = "spinner", title = "搜索中…", selectable = false, muted = true, italic = true } }
        or { { title = "输入番剧名按 Enter 搜索", selectable = false, muted = true, italic = true } }

    mp.commandv("script-message-to", "uosc", "open-menu", utils.format_json(
        build_search_menu(query, initial_items)
    ))

    if query ~= "" then
        execute_search(query, true)
    end
end

local function build_mark_items(is_end_prompt)
    local items = {}
    local ep_short = state.episode and ("第" .. tostring(state.episode) .. "话") or nil

    local title, hint, icon, active
    if state.mark_status == "loading" then
        title = "正在请求…"
        hint = ep_short or "同步中"
        icon = "spinner"
        active = true
    elseif state.mark_status == "success" then
        title = is_end_prompt and "已标记已看" or "已标记本集已看"
        hint = "同步成功"
        icon = "check_circle"
        active = true
    elseif state.mark_status == "error" then
        title = is_end_prompt and "标记已看" or "标记本集已看"
        hint = "请求失败"
        icon = "error_outline"
        active = false
    elseif state.synced then
        title = "本集已看"
        hint = "已同步"
        icon = "check_circle"
        active = true
    else
        title = is_end_prompt and "标记已看" or "标记本集已看"
        hint = ep_short or (state.subject_name and "未识别集数" or "未匹配")
        icon = is_end_prompt and "check_circle" or "bookmark_add"
        active = is_end_prompt
    end

    table.insert(items, {
        title = title,
        hint = hint,
        icon = icon,
        active = active,
        keep_open = true,
        value = { "script-message-to", "bangumi_sync", "mark-now" }
    })

    if state.mark_status == "error" and state.mark_error and state.mark_error ~= "" then
        table.insert(items, {
            title = state.mark_error,
            icon = "info_outline",
            selectable = false,
            muted = true
        })
    end

    return items
end

-- ======================== Compact Bottom-Right End-of-Episode Toast ========================

local prompt_overlay = mp.create_osd_overlay("ass-events")
prompt_overlay.z = 2120

-- Soft Porcelain palette (ASS BGR hex)
local C_BG          = "FAF6F4" -- #F4F6FA porcelain white
local C_BGT         = "3B291E" -- #1E293B deep slate ink
local C_FG          = "B87835" -- #3578B8 serene cerulean
local C_FG_HOVER    = "A06428" -- #2864A0 deeper cerulean
local C_FGT         = "FFFFFF" -- #FFFFFF crisp white
local C_MUTED       = "8B7464" -- #64748B slate muted
local C_SUCCESS     = "6F9D2A" -- #2A9D6F soft emerald
local C_ERROR       = "5D45D6" -- #D6455D muted coral
local C_ERROR_HOVER = "4A33BD" -- #BD334A deeper coral
local C_SHADOW      = "000000" -- pure dark drop shadow
local C_SH_MULT     = 1.0

local cached_ui_font = mp.get_property("osd-font") or "Microsoft YaHei UI"
local render_end_prompt
local ensure_prompt_timer

local prompt = {
    visible = false,
    closing = false,
    opacity = 0,
    duration = 0,          -- seconds; 0 = persistent
    remaining = 0,
    last_time = nil,
    paused = false,
    pause_on_hover = true,
    was_paused = false,
    color_mode = nil,      -- nil | "success" | "error"
    hover_zone = nil,      -- "agree" | "close" | "card" | nil
    card_rect = nil,
    agree_rect = nil,
    close_rect = nil,
    osd_w = mp.get_property_number("osd-width", 1280) or 1280,
    osd_h = mp.get_property_number("osd-height", 720) or 720,
    mouse_x = -1,
    mouse_y = -1,
    mouse_hover = false,
    click_bound = false,
    esc_bound = false,
    toast_hovered_prop = false,
    tick_timer = nil,
    fade_start = nil,
    fade_from = 0,
    fade_to = 1,
    fade_dur = 0.2,
}

is_end_prompt_open = function()
    return prompt.visible and not prompt.closing
end

local function clamp(lo, v, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function alpha_hex(opacity)
    local a = 255 - math.floor(clamp(0, opacity or 0, 1) * 255 + 0.5)
    return string.format("%02X", a)
end

local function ass_escape(str)
    str = tostring(str or "")
    str = str:gsub("\\", "\\\239\187\191")
    str = str:gsub("{", "\\{")
    str = str:gsub("}", "\\}")
    str = str:gsub("[\r\n]+", " ")
    return str
end

local function utf8_next_pos(s, i)
    local b = s:byte(i)
    if not b then return i end
    if b < 0x80 then return i + 1 end
    if b < 0xE0 then return i + 2 end
    if b < 0xF0 then return i + 3 end
    return i + 4
end

local function estimate_em_width(s)
    local w, i, len = 0, 1, #s
    while i <= len do
        local b = s:byte(i)
        local nxt = utf8_next_pos(s, i)
        if b < 0x80 then
            w = w + (b == 32 and 0.30 or 0.50)
        else
            w = w + 0.86
        end
        i = nxt
    end
    return w
end

local function truncate_em(s, max_em)
    if max_em <= 1.2 then return "…" end
    if estimate_em_width(s) <= max_em then return s end
    local w, i, len, last_ok = 0, 1, #s, 0
    local budget = max_em - 0.85
    while i <= len do
        local b = s:byte(i)
        local nxt = utf8_next_pos(s, i)
        local cw = (b < 0x80) and (b == 32 and 0.30 or 0.50) or 0.86
        if w + cw > budget then break end
        w = w + cw
        last_ok = nxt - 1
        i = nxt
    end
    if last_ok <= 0 then return "…" end
    return s:sub(1, last_ok) .. "…"
end

local function draw_round_rect(ass, ax, ay, bx, by, r, color, opacity)
    ass:new_event()
    ass:append(string.format("{\\pos(0,0)\\rDefault\\an7\\blur0\\bord0\\1c&H%s&\\1a&H%s&}",
        color, alpha_hex(opacity)))
    ass:draw_start()
    ass:round_rect_cw(ax, ay, bx, by, r)
    ass:draw_stop()
end

local function draw_text(ass, x, y, align, text, size, color, opacity, bold, font, clip)
    ass:new_event()
    local ui_font = font or cached_ui_font
    local tags = string.format("\\pos(%.1f,%.1f)\\rDefault\\an%d\\blur0\\bord0\\shad0\\fn%s\\fs%.1f\\1c&H%s&\\alpha&H%s&%s%s",
        x, y, align, ui_font, size, color, alpha_hex(opacity), bold and "\\b1" or "", clip or "")
    ass:append("{" .. tags .. "}" .. text)
end

-- Rounded-rectangle perimeter countdown progress border (drains clockwise from 12 o'clock)
local function draw_border_progress(ass, ax, ay, bx, by, radius, thickness, fraction, color, opacity)
    fraction = clamp(0, fraction or 0, 1)
    if fraction <= 0.001 or opacity <= 0.004 then return end
    local w, h = bx - ax, by - ay
    if w <= 2 or h <= 2 then return end

    local r = clamp(0, radius or 0, math.min(w, h) / 2)
    local t = clamp(1, thickness or 2.5, math.min(w, h) / 2)
    local r_in = math.max(0, r - t)

    local cx = (ax + bx) / 2
    local half_top = math.max(0, w / 2 - r)
    local side_v = math.max(0, h - 2 * r)
    local side_h = math.max(0, w - 2 * r)
    local arc_len = (math.pi / 2) * r
    local perim = 2 * half_top + side_h + 2 * side_v + 4 * arc_len
    if perim <= 0 then return end

    local iax, iay, ibx, iby = ax + t, ay + t, bx - t, by - t
    local segs = {
        { kind = "line", len = half_top, ox0 = cx, oy0 = ay, ox1 = bx - r, oy1 = ay, ix0 = cx, iy0 = iay, ix1 = ibx - r_in, iy1 = iay },
        { kind = "arc",  len = arc_len,  ocx = bx - r, ocy = ay + r, icx = ibx - r_in, icy = iay + r_in, a0 = -math.pi / 2, a1 = 0 },
        { kind = "line", len = side_v,   ox0 = bx, oy0 = ay + r, ox1 = bx, oy1 = by - r, ix0 = ibx, iy0 = iay + r_in, ix1 = ibx, iy1 = iby - r_in },
        { kind = "arc",  len = arc_len,  ocx = bx - r, ocy = by - r, icx = ibx - r_in, icy = iby - r_in, a0 = 0, a1 = math.pi / 2 },
        { kind = "line", len = side_h,   ox0 = bx - r, oy0 = by, ox1 = ax + r, oy1 = by, ix0 = ibx - r_in, iy0 = iby, ix1 = iax + r_in, iy1 = iby },
        { kind = "arc",  len = arc_len,  ocx = ax + r, ocy = by - r, icx = iax + r_in, icy = iby - r_in, a0 = math.pi / 2, a1 = math.pi },
        { kind = "line", len = side_v,   ox0 = ax, oy0 = by - r, ox1 = ax, oy1 = ay + r, ix0 = iax, iy0 = iby - r_in, ix1 = iax, iy1 = iay + r_in },
        { kind = "arc",  len = arc_len,  ocx = ax + r, ocy = ay + r, icx = iax + r_in, icy = iay + r_in, a0 = math.pi, a1 = 1.5 * math.pi },
        { kind = "line", len = half_top, ox0 = ax + r, oy0 = ay, ox1 = cx, oy1 = ay, ix0 = iax + r_in, iy0 = iay, ix1 = cx, iy1 = iay },
    }

    local is_full = fraction >= 0.999
    local s_start = is_full and 0 or (1 - fraction) * perim
    local s_end = perim
    local ox, oy, ix, iy = {}, {}, {}, {}
    local n = 0

    local function push_pt(px, py, qx, qy)
        if n > 0 and math.abs(ox[n] - px) < 0.05 and math.abs(oy[n] - py) < 0.05
            and math.abs(ix[n] - qx) < 0.05 and math.abs(iy[n] - qy) < 0.05 then
            return
        end
        n = n + 1
        ox[n], oy[n], ix[n], iy[n] = px, py, qx, qy
    end

    local cursor_s = 0
    for _, seg in ipairs(segs) do
        local seg_end = cursor_s + seg.len
        if seg.len > 0.001 and seg_end > s_start and cursor_s < s_end then
            local u0 = clamp(0, (math.max(cursor_s, s_start) - cursor_s) / seg.len, 1)
            local u1 = clamp(0, (math.min(seg_end, s_end) - cursor_s) / seg.len, 1)
            if u1 > u0 + 1e-6 then
                if seg.kind == "line" then
                    push_pt(
                        seg.ox0 + (seg.ox1 - seg.ox0) * u0, seg.oy0 + (seg.oy1 - seg.oy0) * u0,
                        seg.ix0 + (seg.ix1 - seg.ix0) * u0, seg.iy0 + (seg.iy1 - seg.iy0) * u0
                    )
                    push_pt(
                        seg.ox0 + (seg.ox1 - seg.ox0) * u1, seg.oy0 + (seg.oy1 - seg.oy0) * u1,
                        seg.ix0 + (seg.ix1 - seg.ix0) * u1, seg.iy0 + (seg.iy1 - seg.iy0) * u1
                    )
                else
                    local steps = math.max(2, math.ceil(math.max(8, r / 1.4) * (u1 - u0)))
                    for i = 0, steps do
                        local u = u0 + (u1 - u0) * (i / steps)
                        local a = seg.a0 + (seg.a1 - seg.a0) * u
                        local ca, sa = math.cos(a), math.sin(a)
                        push_pt(
                            seg.ocx + r * ca, seg.ocy + r * sa,
                            seg.icx + r_in * ca, seg.icy + r_in * sa
                        )
                    end
                end
            end
        end
        cursor_s = seg_end
    end

    if n < 2 then return end

    ass:new_event()
    ass:append(string.format("{\\pos(0,0)\\rDefault\\an7\\blur0\\bord0\\1c&H%s&\\1a&H%s&}",
        color, alpha_hex(opacity)))
    ass:draw_start()
    if is_full then
        ass:move_to(ox[1], oy[1])
        for i = 2, n do ass:line_to(ox[i], oy[i]) end
        ass:move_to(ix[n], iy[n])
        for i = n - 1, 1, -1 do ass:line_to(ix[i], iy[i]) end
    else
        ass:move_to(ox[1], oy[1])
        for i = 2, n do ass:line_to(ox[i], oy[i]) end
        for i = n, 1, -1 do ass:line_to(ix[i], iy[i]) end
    end
    ass:draw_stop()
end

local function set_toast_hovered_prop(val)
    val = val == true
    if prompt.toast_hovered_prop ~= val then
        prompt.toast_hovered_prop = val
        mp.set_property_bool("user-data/uosc/toast-hovered", val)
    end
end

local function unbind_prompt_input()
    if prompt.click_bound then
        mp.disable_key_bindings("bgm_prompt_click")
        prompt.click_bound = false
    end
    if prompt.esc_bound then
        mp.remove_key_binding("bgm-prompt-esc")
        prompt.esc_bound = false
    end
    set_toast_hovered_prop(false)
end

local function stop_prompt_timer()
    if prompt.tick_timer then
        prompt.tick_timer:kill()
        prompt.tick_timer = nil
    end
end

local function clear_prompt_overlay()
    stop_prompt_timer()
    prompt_overlay:remove()
    prompt.visible = false
    prompt.closing = false
    prompt.opacity = 0
    prompt.card_rect = nil
    prompt.agree_rect = nil
    prompt.close_rect = nil
    prompt.hover_zone = nil
    prompt.fade_start = nil
    unbind_prompt_input()
end

local function point_in_rect(x, y, r)
    return r and x >= r.ax and x <= r.bx and y >= r.ay and y <= r.by
end

hide_end_prompt = function(instant)
    if not prompt.visible and prompt.opacity <= 0.01 then
        clear_prompt_overlay()
        return
    end
    if instant or prompt.opacity <= 0.04 then
        clear_prompt_overlay()
        return
    end
    if prompt.closing then return end
    prompt.closing = true
    prompt.fade_start = mp.get_time()
    prompt.fade_from = prompt.opacity
    prompt.fade_to = 0
    prompt.fade_dur = 0.20
    unbind_prompt_input()
    ensure_prompt_timer()
end

local function dismiss_end_prompt()
    state.prompted = true
    hide_end_prompt(false)
end

local function handle_prompt_click()
    if not prompt.visible or prompt.closing then return end
    if prompt.hover_zone == "close" then
        dismiss_end_prompt()
    elseif prompt.hover_zone == "agree" then
        if not state.busy and state.mark_status ~= "success" then
            mark_current_watched(false)
        end
    end
end

mp.set_key_bindings({
    { "MBTN_LEFT", function() end, handle_prompt_click },
    { "MBTN_LEFT_DBL", function() end },
}, "bgm_prompt_click", "force")

local function update_prompt_hover(mx, my, is_hover)
    if not prompt.visible or prompt.closing then
        if prompt.click_bound then
            mp.disable_key_bindings("bgm_prompt_click")
            prompt.click_bound = false
        end
        set_toast_hovered_prop(false)
        return
    end

    local zone = nil
    if is_hover and point_in_rect(mx, my, prompt.card_rect) then
        if point_in_rect(mx, my, prompt.close_rect) then
            zone = "close"
        elseif point_in_rect(mx, my, prompt.agree_rect) then
            zone = "agree"
        else
            zone = "card"
        end
    end

    local inside = zone ~= nil
    set_toast_hovered_prop(inside)

    if inside and not prompt.click_bound then
        mp.enable_key_bindings("bgm_prompt_click", "")
        prompt.click_bound = true
    elseif not inside and prompt.click_bound then
        mp.disable_key_bindings("bgm_prompt_click")
        prompt.click_bound = false
    end

    if zone ~= prompt.hover_zone then
        prompt.hover_zone = zone
        render_end_prompt()
        if not inside and prompt.duration > 0 and not prompt.paused then
            ensure_prompt_timer()
        end
    end
end

render_end_prompt = function()
    local op = prompt.opacity
    if not prompt.visible or op <= 0.01 then
        if not prompt.visible then prompt_overlay:remove() end
        return
    end

    local w, h = prompt.osd_w, prompt.osd_h
    if w <= 0 or h <= 0 then return end
    local scale = clamp(0.85, h / 720, 1.45)

    local card_w = math.floor(276 * scale)
    local card_h = math.floor(86 * scale)
    local margin_r = math.floor(24 * scale)
    local margin_b = math.floor(26 * scale)
    local radius = math.floor(13 * scale)
    local border_t = math.max(2, math.floor(2.8 * scale + 0.5))

    local bx = w - margin_r
    local ax = bx - card_w
    local by = h - margin_b
    local ay = by - card_h

    local pad_x = math.floor(12 * scale)
    local pad_top = math.floor(10 * scale)
    local pad_bot = math.floor(11 * scale)
    local row1_h = math.floor(26 * scale)
    local row1_cy = ay + pad_top + row1_h / 2

    local close_size = math.floor(24 * scale)
    local close_bx = bx - pad_x
    local close_ax = close_bx - close_size
    local close_ay = math.floor(row1_cy - close_size / 2)
    local close_by = close_ay + close_size

    local btn_ax = ax + pad_x
    local btn_bx = bx - pad_x
    local btn_ay = ay + pad_top + row1_h + math.floor(6 * scale)
    local btn_by = by - pad_bot
    local btn_cy = (btn_ay + btn_by) / 2
    local btn_r = math.floor(8.5 * scale)

    prompt.card_rect = { ax = ax, ay = ay, bx = bx, by = by }
    prompt.close_rect = { ax = close_ax, ay = close_ay, bx = close_bx, by = close_by }
    prompt.agree_rect = { ax = btn_ax, ay = btn_ay, bx = btn_bx, by = btn_by }

    local is_close_hover = (prompt.hover_zone == "close")
    local is_agree_hover = (prompt.hover_zone == "agree")

    local accent = C_FG
    if prompt.color_mode == "success" then
        accent = C_SUCCESS
    elseif prompt.color_mode == "error" then
        accent = C_ERROR
    end

    local ass = assdraw.ass_new()

    -- Soft layered elevation shadow
    draw_round_rect(ass, ax - 1, ay + math.floor(4 * scale), bx + 1, by + math.floor(7 * scale),
        radius + 1, C_SHADOW, math.min(0.45, op * 0.11 * C_SH_MULT))
    draw_round_rect(ass, ax, ay + math.floor(2 * scale), bx, by + math.floor(3 * scale),
        radius, C_SHADOW, math.min(0.45, op * 0.10 * C_SH_MULT))

    -- Frosted Soft Porcelain card surface
    draw_round_rect(ass, ax, ay, bx, by, radius, C_BG, op * 0.96)

    -- Perimeter countdown progress border (full at start, drains clockwise to 0)
    if prompt.duration > 0 then
        local frac = prompt.closing and 0 or clamp(0, prompt.remaining / prompt.duration, 1)
        draw_border_progress(ass, ax, ay, bx, by, radius, border_t, 1, accent, op * 0.16)
        if frac > 0 then
            draw_border_progress(ass, ax, ay, bx, by, radius, border_t, frac, accent, op * 0.92)
        end
    else
        draw_border_progress(ass, ax, ay, bx, by, radius, math.max(1.5, border_t * 0.7), 1, accent, op * 0.22)
    end

    -- Row 1 left: Anime title + episode (auto-truncated cleanly to preserve episode & never collide with ×)
    local title_size = math.floor(14.5 * scale + 0.5)
    local text_ax = ax + pad_x
    local text_max_x = close_ax - math.floor(8 * scale)
    local max_em = math.max(4, (text_max_x - text_ax) / title_size)
    local base_name = tostring(state.subject_name or "当前番剧")
    local ep_suffix = state.episode and (" · 第" .. tostring(state.episode) .. "话") or ""
    local display_title
    if ep_suffix ~= "" then
        local ep_em = estimate_em_width(ep_suffix)
        display_title = truncate_em(base_name, math.max(2.5, max_em - ep_em)) .. ep_suffix
    else
        display_title = truncate_em(base_name, max_em)
    end
    local title_clip = string.format("\\clip(%d,%d,%d,%d)", text_ax, ay, text_max_x, btn_ay)
    draw_text(ass, text_ax, row1_cy, 4, ass_escape(display_title), title_size, C_BGT, op, true, nil, title_clip)

    -- Row 1 right: Close × button on the exact same line
    if is_close_hover then
        draw_round_rect(ass, close_ax, close_ay, close_bx, close_by, math.floor(7 * scale), C_ERROR, op * 0.92)
    end
    draw_text(ass, (close_ax + close_bx) / 2, (close_ay + close_by) / 2, 5, "close",
        math.floor(15 * scale), is_close_hover and "FFFFFF" or C_MUTED, op * (is_close_hover and 1 or 0.85),
        false, "MaterialIconsRound-Regular")

    -- Row 2: Agree / Mark watched button
    local btn_bg, btn_op, btn_icon, btn_label
    if state.mark_status == "loading" then
        btn_bg = C_FG
        btn_op = op * 0.76
        btn_icon = "autorenew"
        btn_label = "正在同步…"
    elseif state.mark_status == "success" then
        btn_bg = C_SUCCESS
        btn_op = op * 0.96
        btn_icon = "check_circle"
        btn_label = "已标记已看"
    elseif state.mark_status == "error" then
        btn_bg = is_agree_hover and C_ERROR_HOVER or C_ERROR
        btn_op = op * (is_agree_hover and 1.0 or 0.94)
        btn_icon = "error_outline"
        btn_label = "同步失败 · 点击重试"
    else
        btn_bg = is_agree_hover and C_FG_HOVER or C_FG
        btn_op = op * (is_agree_hover and 1.0 or 0.94)
        btn_icon = "check_circle"
        btn_label = "标记已看"
    end

    draw_round_rect(ass, btn_ax, btn_ay, btn_bx, btn_by, btn_r, btn_bg, btn_op)

    local btn_fs = math.floor(13.5 * scale + 0.5)
    local icon_sz = math.floor(15.5 * scale + 0.5)
    local gap = math.floor(6 * scale)
    local label_w = estimate_em_width(btn_label) * btn_fs
    local group_w = icon_sz + gap + label_w
    local start_x = (btn_ax + btn_bx - group_w) / 2
    draw_text(ass, start_x + icon_sz / 2, btn_cy, 5, btn_icon,
        icon_sz, C_FGT, op, false, "MaterialIconsRound-Regular")
    draw_text(ass, start_x + icon_sz + gap, btn_cy, 4, ass_escape(btn_label),
        btn_fs, C_FGT, op, true)

    prompt_overlay.res_x = w
    prompt_overlay.res_y = h
    prompt_overlay.data = ass.text
    prompt_overlay:update()
end

ensure_prompt_timer = function()
    if prompt.tick_timer then return end
    prompt.tick_timer = mp.add_periodic_timer(0.016, function()
        if not prompt.visible then
            stop_prompt_timer()
            return
        end
        local now = mp.get_time()
        local keep_running = false

        -- Opacity fade-in / fade-out
        if prompt.fade_start then
            local p = clamp(0, (now - prompt.fade_start) / prompt.fade_dur, 1)
            if prompt.fade_to > prompt.fade_from then
                prompt.opacity = prompt.fade_from + (prompt.fade_to - prompt.fade_from) * (1 - (1 - p) ^ 3)
            else
                prompt.opacity = prompt.fade_from * (1 - p) ^ 2
            end
            if p >= 1 then
                prompt.opacity = prompt.fade_to
                prompt.fade_start = nil
                if prompt.closing then
                    clear_prompt_overlay()
                    return
                end
            else
                keep_running = true
            end
        end

        -- Countdown tick
        if not prompt.closing and prompt.duration > 0 then
            local hovered = prompt.pause_on_hover and prompt.hover_zone ~= nil
            if prompt.paused or hovered then
                prompt.was_paused = true
                prompt.last_time = now
            else
                local dt = 0
                if prompt.was_paused then
                    prompt.was_paused = false
                elseif prompt.last_time then
                    dt = clamp(0, now - prompt.last_time, 0.25)
                end
                prompt.last_time = now
                prompt.remaining = math.max(0, prompt.remaining - dt)
                if prompt.remaining <= 0 then
                    hide_end_prompt(false)
                    keep_running = true
                else
                    keep_running = true
                end
            end
        end

        render_end_prompt()
        if not keep_running then
            stop_prompt_timer()
        end
    end)
end

open_end_prompt = function(action)
    local is_update = (action == "update-menu")
    if is_update and (not prompt.visible or prompt.closing) then return end

    local timeout = state.prompt_timeout
    local pause_timer = false
    local pause_on_hover = true
    local color_mode = nil
    local reset_timer = not is_update

    if state.mark_status == "loading" then
        pause_timer = true
    elseif state.mark_status == "success" then
        timeout = 1.8
        reset_timer = true
        pause_on_hover = false
        color_mode = "success"
    elseif state.mark_status == "error" then
        timeout = timeout > 0 and math.max(timeout, 6) or 0
        reset_timer = true
        color_mode = "error"
    end

    local now = mp.get_time()
    prompt.paused = pause_timer
    prompt.pause_on_hover = pause_on_hover
    prompt.color_mode = color_mode
    if reset_timer then
        prompt.duration = timeout > 0 and timeout or 0
        prompt.remaining = prompt.duration
        prompt.last_time = now
        prompt.was_paused = false
    elseif not pause_timer then
        prompt.last_time = now
        prompt.was_paused = false
    end

    if not is_update then
        prompt.visible = true
        prompt.closing = false
        prompt.opacity = math.max(prompt.opacity, 0.05)
        prompt.fade_start = now
        prompt.fade_from = prompt.opacity
        prompt.fade_to = 1
        prompt.fade_dur = 0.20
        if not prompt.esc_bound then
            mp.add_forced_key_binding("ESC", "bgm-prompt-esc", dismiss_end_prompt)
            prompt.esc_bound = true
        end
    end

    render_end_prompt()
    update_prompt_hover(prompt.mouse_x, prompt.mouse_y, prompt.mouse_hover)
    if prompt.fade_start or (prompt.duration > 0 and not prompt.paused) then
        ensure_prompt_timer()
    end
end

mp.observe_property("osd-font", "string", function(_, v)
    if v and v ~= "" then
        cached_ui_font = v
        if prompt.visible then render_end_prompt() end
    end
end)
mp.observe_property("user-data/porcelain/theme", "native", function(_, t)
    if type(t) ~= "table" then return end
    if t.bg then C_BG = t.bg end
    if t.bgt then C_BGT = t.bgt end
    if t.fg then C_FG = t.fg end
    if t.fg_hover then C_FG_HOVER = t.fg_hover end
    if t.fgt then C_FGT = t.fgt end
    if t.muted then C_MUTED = t.muted end
    if t.success then C_SUCCESS = t.success end
    if t.error then C_ERROR = t.error end
    if t.error_hover then C_ERROR_HOVER = t.error_hover end
    if t.shadow then C_SHADOW = t.shadow end
    if type(t.shadow_mult) == "number" then C_SH_MULT = t.shadow_mult end
    if prompt.visible then render_end_prompt() end
end)
mp.observe_property("osd-width", "number", function(_, v)
    if v and v > 0 then prompt.osd_w = v; if prompt.visible then render_end_prompt() end end
end)
mp.observe_property("osd-height", "number", function(_, v)
    if v and v > 0 then prompt.osd_h = v; if prompt.visible then render_end_prompt() end end
end)
mp.observe_property("mouse-pos", "native", function(_, pos)
    if type(pos) == "table" and pos.x and pos.y then
        prompt.mouse_x = pos.x
        prompt.mouse_y = pos.y
        prompt.mouse_hover = pos.hover == true
        update_prompt_hover(pos.x, pos.y, prompt.mouse_hover)
    end
end)

local function mode_label(m)
    if m == "auto" then return "自动同步" end
    if m == "manual" then return "仅手动" end
    return "片尾询问"
end

local PROMPT_TIMEOUT_PRESETS = { 3, 5, 8, 12, 15, 0 }

local function timeout_label(sec)
    if not sec or sec <= 0 then return "不自动关闭" end
    if math.floor(sec) == sec then
        return string.format("%d 秒", sec)
    end
    return string.format("%.1f 秒", sec)
end

open_main_menu = function(action)
    if not action or action == "open-menu" then
        hide_end_prompt(true)
    end
    if (not action or action == "open-menu") and get_open_menu_type() == "bgm_main_menu" then
        mp.commandv("script-message-to", "uosc", "close-menu")
        return
    end
    if not action or action == "open-menu" then
        if not state.busy then
            if state.mark_status == "success" or state.mark_status == "error" then
                state.mark_status = nil
                state.mark_error = nil
            end
        end
        if state.login_status == "error" then
            state.login_status = nil
            state.login_error = nil
        end
    end

    local items = {}

    if state.logged_in then
        table.insert(items, {
            title = tostring(state.nickname or state.username),
            hint = "@" .. tostring(state.username),
            icon = "person",
            selectable = false,
            muted = true,
            separator = true
        })
    else
        table.insert(items, {
            title = state.login_status == "loading" and "正在验证 Token…" or "从剪贴板登录",
            hint = state.login_status == "error" and "登录失败" or "Token",
            icon = state.login_status == "loading" and "spinner" or "login",
            active = true,
            keep_open = true,
            value = { "script-message-to", "bangumi_sync", "login-clipboard" }
        })
        if state.login_status == "error" and state.login_error and state.login_error ~= "" then
            table.insert(items, {
                title = state.login_error,
                icon = "info_outline",
                selectable = false,
                muted = true
            })
        end
        table.insert(items, {
            title = "获取 Access Token",
            hint = "next.bgm.tv",
            icon = "open_in_new",
            separator = true,
            value = { "script-message-to", "bangumi_sync", "open-token-page" }
        })
    end

    if state.current_path then
        local mark_items = build_mark_items(false)
        for _, it in ipairs(mark_items) do
            table.insert(items, it)
        end
        table.insert(items, {
            title = "更换番剧关联",
            hint = state.subject_name or "未关联",
            icon = "search",
            separator = true,
            value = { "script-message-to", "bangumi_sync", "open-search" }
        })
    end

    table.insert(items, {
        title = "同步模式",
        hint = mode_label(state.mode),
        icon = "tune",
        keep_open = true,
        value = { "script-message-to", "bangumi_sync", "cycle-mode" }
    })

    table.insert(items, {
        title = "提示时长",
        hint = timeout_label(state.prompt_timeout),
        icon = "timer",
        keep_open = true,
        value = { "script-message-to", "bangumi_sync", "cycle-prompt-timeout" }
    })

    if state.logged_in then
        table.insert(items, {
            title = "退出登录",
            icon = "logout",
            keep_open = true,
            value = { "script-message-to", "bangumi_sync", "logout" }
        })
    end

    local menu = {
        type = "bgm_main_menu",
        title = "Bangumi",
        items = items
    }
    mp.commandv("script-message-to", "uosc", action or "open-menu", utils.format_json(menu))
end

-- Script messages
mp.register_script_message("open-menu", function() open_main_menu("open-menu") end)
mp.register_script_message("mark-now", function(source)
    mark_current_watched(source == "from-menu")
end)
mp.register_script_message("skip-prompt", function()
    dismiss_end_prompt()
end)
mp.register_script_message("open-end-prompt", function(test_name, test_ep)
    if test_name and test_name ~= "" then
        state.subject_name = test_name
        state.episode = tonumber(test_ep) or state.episode
    end
    open_end_prompt("open-menu")
end)
mp.register_script_message("open-search", function() open_search_menu() end)
mp.register_script_message("do-search", function(query) execute_search(query) end)

mp.register_script_message("bind-subject", function(sid, sname)
    state.match_seq = state.match_seq + 1
    local bind_seq = state.match_seq
    state.subject_id = tonumber(sid)
    state.subject_name = sname
    state.episode_title = nil
    state.synced = false
    state.mark_status = nil
    state.mark_error = nil
    publish_match_info()
    update_uosc_button()
    if state.current_path then
        local captured_path = state.current_path
        local captured_sid = state.subject_id
        local folder = utils.split_path(state.current_path)
        if folder then
            run_cli({ "bind", folder, sid, sname, state.episode and tostring(state.episode) or "", captured_path }, function(res)
                if bind_seq ~= state.match_seq or state.current_path ~= captured_path or state.subject_id ~= captured_sid then return end
                if not res or not res.ok then
                    mp.osd_message("目录关联保存失败：" .. tostring(res and res.error or "写入错误"), 3.0)
                    return
                end
                local changed_meta = false
                if state.episode == nil and tonumber(res.episode) then
                    state.episode = tonumber(res.episode)
                    if tonumber(res.season) then
                        state.season = tonumber(res.season)
                    end
                    changed_meta = true
                end
                local et = tostring(res.episode_title or ""):gsub("^%s+", ""):gsub("%s+$", "")
                if et ~= "" then
                    state.episode_title = et
                    changed_meta = true
                end
                if changed_meta then
                    publish_match_info()
                    update_uosc_button()
                    refresh_open_bgm_menu()
                end
                mp.osd_message("已关联：" .. sname, 2.2)
            end)
        end
    end
end)

mp.register_script_message("cycle-mode", function()
    if state.mode == "prompt" then state.mode = "auto"
    elseif state.mode == "auto" then state.mode = "manual"
    else state.mode = "prompt" end
    save_prefs()
    open_main_menu("update-menu")
end)

mp.register_script_message("cycle-prompt-timeout", function()
    local next_val = PROMPT_TIMEOUT_PRESETS[1]
    for i, v in ipairs(PROMPT_TIMEOUT_PRESETS) do
        if math.abs(state.prompt_timeout - v) < 0.05 then
            next_val = PROMPT_TIMEOUT_PRESETS[(i % #PROMPT_TIMEOUT_PRESETS) + 1]
            break
        end
    end
    state.prompt_timeout = next_val
    state.prompt_timeout_custom = true
    save_prefs()
    open_main_menu("update-menu")
end)

mp.register_script_message("set-prompt-timeout", function(val)
    local num = tonumber(val)
    if not num then return end
    state.prompt_timeout = math.max(0, num)
    state.prompt_timeout_custom = true
    save_prefs()
    if get_open_menu_type() == "bgm_main_menu" then
        open_main_menu("update-menu")
    end
end)

mp.register_script_message("login-clipboard", function()
    if state.login_status == "loading" then return end
    local token = mp.get_property("clipboard/text") or ""
    token = token:gsub("^%s+", ""):gsub("%s+$", "")
    if token == "" then
        state.login_status = "error"
        state.login_error = "剪贴板为空，请先复制 Token"
        if not refresh_open_bgm_menu() then
            mp.osd_message(state.login_error, 2.5)
        end
        return
    end
    state.login_status = "loading"
    state.login_error = nil
    if not refresh_open_bgm_menu() then
        mp.osd_message("正在验证 Token…", 2)
    end
    run_cli({ "login", token }, function(res)
        if res.ok then
            state.logged_in = true
            state.username = res.username
            state.nickname = res.nickname
            state.login_status = nil
            state.login_error = nil
            update_uosc_button()
            if not refresh_open_bgm_menu() then
                mp.osd_message("✓ 登录成功：" .. tostring(res.nickname), 2.5)
            end
        else
            state.login_status = "error"
            state.login_error = tostring(res.error or "Token 无效"):gsub("[\r\n]+", " ")
            if not refresh_open_bgm_menu() then
                mp.osd_message("登录失败：" .. state.login_error, 3.5)
            end
        end
    end)
end)

mp.register_script_message("open-token-page", function()
    mp.command_native_async({
        name = "subprocess",
        args = { "cmd", "/c", "start", "", "https://next.bgm.tv/demo/access-token" },
        playback_only = false
    })
    mp.osd_message("已打开页面，复制 Token 后点击「从剪贴板登录」", 3.5)
end)

mp.register_script_message("logout", function()
    run_cli({ "logout" }, function()
        state.logged_in = false
        state.username = nil
        state.nickname = nil
        state.synced = false
        state.mark_status = nil
        state.mark_error = nil
        update_uosc_button()
        if not refresh_open_bgm_menu() then
            mp.osd_message("已退出登录", 2)
        end
    end)
end)

mp.register_script_message("uosc-version", function()
    update_uosc_button()
end)

-- React to file load and uosc_danmaku automatic anime match
mp.register_event("file-loaded", function()
    hide_end_prompt(true)
    state.playback_seq = state.playback_seq + 1
    state.match_seq = state.match_seq + 1
    local load_match_seq = state.match_seq
    state.busy = false
    state.current_path = mp.get_property("path")
    state.subject_id = nil
    state.subject_name = nil
    state.season = 1
    state.episode = nil
    state.episode_title = nil
    state.synced = false
    state.prompted = false
    state.mark_status = nil
    state.mark_error = nil
    mp.set_property_native("user-data/bangumi_sync/match-info", nil)
    update_uosc_button()
    mp.add_timeout(0.8, function()
        if load_match_seq ~= state.match_seq then return end
        match_current_file("")
    end)
end)

mp.register_event("end-file", function()
    hide_end_prompt(true)
end)

mp.observe_property("user-data/uosc_danmaku/match-info", "native", function(_, info)
    if type(info) == "table" and info.anime and info.anime ~= "" and info.path == state.current_path then
        if not state.subject_id then
            match_current_file(info.anime)
        end
    end
end)

-- Check near end of episode (every 2 seconds)
mp.add_periodic_timer(2.0, function()
    if state.mode == "manual" or not state.logged_in or state.synced or state.prompted then return end
    if not state.subject_id or not state.episode then return end
    if mp.get_property_bool("idle-active", true) then return end
    local duration = mp.get_property_number("duration", 0)
    local remaining = mp.get_property_number("time-remaining", 9999)
    if duration < 180 then return end
    if remaining <= state.remaining_sec then
        state.prompted = true
        if state.mode == "auto" then
            mark_current_watched(false)
        else
            open_end_prompt("open-menu")
        end
    end
end)

mp.add_key_binding("Ctrl+b", "bangumi-sync-menu", function() open_main_menu("open-menu") end)

load_prefs()
refresh_status()
mp.add_timeout(0.8, update_uosc_button)
