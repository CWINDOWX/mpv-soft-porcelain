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
local msg = require("mp.msg")

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
    remaining_sec = 90,
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
    search_seq = 0
}

local open_main_menu
local open_end_prompt

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
            state.remaining_sec = tonumber(parsed.remaining_sec)
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
    f:write(utils.format_json({ mode = state.mode, remaining_sec = state.remaining_sec }) or "{}")
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
    local cur = get_open_menu_type()
    if cur == "bgm_main_menu" then
        open_main_menu("update-menu")
        return true
    elseif cur == "bgm_end_prompt" then
        open_end_prompt("update-menu")
        return true
    end
    return false
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
    run_cli({ "match", path, hint_anime or "" }, function(res)
        if state.current_path ~= path then return end
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
                local captured_name = state.subject_name
                local captured_season = state.season
                local captured_ep = state.episode
                mp.add_timeout(4.5, function()
                    if state.current_path ~= captured_path then return end
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
        if want_menu and cur_menu ~= "bgm_main_menu" and cur_menu ~= "bgm_end_prompt" then
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

open_end_prompt = function(action)
    local label = state.subject_name or "当前番剧"
    if state.episode then
        label = label .. " · 第" .. tostring(state.episode) .. "话"
    end
    local items = {
        {
            title = label,
            selectable = false,
            muted = true,
            separator = true
        }
    }
    for _, it in ipairs(build_mark_items(true)) do
        table.insert(items, it)
    end
    table.insert(items, {
        title = "暂不标记",
        icon = "close",
        value = { "script-message-to", "bangumi_sync", "skip-prompt" }
    })
    table.insert(items, {
        title = "更换番剧关联",
        icon = "search",
        value = { "script-message-to", "bangumi_sync", "open-search" }
    })

    local menu = {
        type = "bgm_end_prompt",
        title = "标记本集已看？",
        items = items
    }
    mp.commandv("script-message-to", "uosc", action or "open-menu", utils.format_json(menu))
end

local function mode_label(m)
    if m == "auto" then return "自动同步" end
    if m == "manual" then return "仅手动" end
    return "片尾询问"
end

open_main_menu = function(action)
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
    state.prompted = true
end)
mp.register_script_message("open-search", function() open_search_menu() end)
mp.register_script_message("do-search", function(query) execute_search(query) end)

mp.register_script_message("bind-subject", function(sid, sname)
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
            run_cli({ "bind", folder, sid, sname, state.episode and tostring(state.episode) or "" }, function(res)
                if state.current_path ~= captured_path or state.subject_id ~= captured_sid then return end
                local et = tostring(res and res.episode_title or ""):gsub("^%s+", ""):gsub("%s+$", "")
                if et ~= "" then
                    state.episode_title = et
                    publish_match_info()
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
    state.playback_seq = state.playback_seq + 1
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
        match_current_file("")
    end)
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
