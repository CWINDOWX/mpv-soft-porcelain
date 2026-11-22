--[[
    Bangumi 番剧进度同步脚本（适配 uosc 控制栏与柔和菜单）
    - 自动识别当前播放番剧与集数（联动 uosc_danmaku 匹配结果 + 本地文件夹记忆）
    - 片尾剩余 ≤ 90 秒时轻柔提醒标记本集已看（支持切换：弹窗确认 / 自动同步 / 仅手动）
    - 支持从剪贴板一键粘贴 Bangumi Access Token 登录，凭据保存在本地 bangumi-auth.json（不进 Git）
    - 快捷键：Ctrl+B 打开 Bangumi 同步菜单
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
    episode = nil,
    synced = false,
    prompted = false,
    busy = false,
    search_seq = 0
}

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

local function update_uosc_button()
    local badge = nil
    local active = false
    local tooltip = "Bangumi 观影同步（Ctrl+B）"

    if state.synced then
        badge = "✓"
        active = true
        tooltip = "Bangumi：本集已同步"
    elseif state.logged_in then
        badge = state.episode and ("E" .. tostring(state.episode)) or "BGM"
        tooltip = "Bangumi：" .. (state.subject_name or state.nickname or "已登录") .. "（Ctrl+B）"
    else
        badge = nil
        tooltip = state.subject_name
            and ("Bangumi 已识别：" .. state.subject_name .. " · 点击登录同步 (Ctrl+B)")
            or "Bangumi 同步（点击粘贴 Token 登录 · Ctrl+B）"
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
            mp.set_property_native("user-data/bangumi_sync/match-info", {
                anime = state.subject_name,
                episode = state.episode and ("第" .. tostring(state.episode) .. "话") or "",
                path = path
            })
            msg.info(string.format("Bangumi 匹配: #%s %s S%sE%s", tostring(res.subject_id), tostring(res.subject_name), tostring(state.season), tostring(res.episode)))

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
    end)
end

local function mark_current_watched()
    if state.busy then return end
    if not state.logged_in then
        mp.osd_message("请先在 Bangumi 菜单中登录 Access Token", 2.5)
        return
    end
    if not state.subject_id or not state.episode then
        mp.osd_message("尚未识别当前番剧/集数，请先在菜单中手动搜索关联", 3)
        return
    end

    state.busy = true
    mp.osd_message("正在同步到 Bangumi…", 2)
    run_cli({ "mark", state.subject_id, state.episode }, function(res)
        state.busy = false
        if res.ok then
            state.synced = true
            state.prompted = true
            update_uosc_button()
            mp.osd_message(string.format("✓ Bangumi 已标记已看：%s · 第 %s 集", state.subject_name or "", tostring(state.episode)), 3.2)
        else
            mp.osd_message("Bangumi 同步失败：" .. tostring(res.error or "未知错误"), 4)
        end
    end)
end

local function build_search_menu(query, list, footnote_text)
    return {
        type = "bgm_search_menu",
        title = "搜索并关联 Bangumi 番剧",
        search_style = "palette",
        search_debounce = "submit",
        search_suggestion = query or "",
        on_search = { "script-message-to", "bangumi_sync", "do-search" },
        footnote = footnote_text or "输入番剧名按 Enter 搜索；选中后将自动记住当前文件夹",
        items = list
    }
end

local function execute_search(query, skip_spinner)
    query = tostring(query or ""):gsub("^%s+", ""):gsub("%s+$", "")
    state.search_seq = state.search_seq + 1
    local seq = state.search_seq

    if query == "" then
        mp.commandv("script-message-to", "uosc", "update-menu", utils.format_json(
            build_search_menu("", { { title = "请输入番剧名称后按 Enter 搜索", selectable = false, muted = true, italic = true } })
        ))
        return
    end

    if not skip_spinner then
        mp.commandv("script-message-to", "uosc", "update-menu", utils.format_json(
            build_search_menu(query, { { icon = "spinner", title = "正在搜索 Bangumi…", selectable = false, muted = true, italic = true } })
        ))
    end

    run_cli({ "search", query }, function(res)
        -- Ignore stale results if user already started a newer search
        if seq ~= state.search_seq then return end
        if not res.ok then
            mp.commandv("script-message-to", "uosc", "update-menu", utils.format_json(
                build_search_menu(query, { { title = "搜索失败：" .. tostring(res.error or "网络异常，请按 Enter 重试"), selectable = false, muted = true } })
            ))
            return
        end
        if not res.items or #res.items == 0 then
            mp.commandv("script-message-to", "uosc", "update-menu", utils.format_json(
                build_search_menu(query, { { title = "未找到相关番剧，请换个关键词按 Enter 搜索", selectable = false, muted = true } })
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
        and { { icon = "spinner", title = "正在搜索 Bangumi…", selectable = false, muted = true, italic = true } }
        or { { title = "请输入番剧名称后按 Enter 搜索", selectable = false, muted = true, italic = true } }

    mp.commandv("script-message-to", "uosc", "open-menu", utils.format_json(
        build_search_menu(query, initial_items)
    ))

    if query ~= "" then
        execute_search(query, true)
    end
end

local function open_end_prompt()
    local label = string.format("%s · 第 %s 集", state.subject_name or "当前番剧", tostring(state.episode or "?"))
    local menu = {
        type = "bgm_end_prompt",
        title = "即将播完 · 同步 Bangumi 进度？",
        footnote = label,
        items = {
            {
                title = "标记本集已看（" .. label .. "）",
                hint = "立即同步",
                icon = "check_circle",
                active = true,
                value = { "script-message-to", "bangumi_sync", "mark-now" }
            },
            {
                title = "暂不标记（跳过本次）",
                hint = "ESC 关闭",
                icon = "close",
                value = { "script-message-to", "bangumi_sync", "skip-prompt" }
            },
            {
                title = "番剧识别不对？手动更换关联",
                icon = "search",
                value = { "script-message-to", "bangumi_sync", "open-search" }
            }
        }
    }
    mp.commandv("script-message-to", "uosc", "open-menu", utils.format_json(menu))
end

local function mode_label(m)
    if m == "auto" then return "片尾静默自动同步" end
    if m == "manual" then return "仅手动同步" end
    return "片尾弹窗确认（推荐）"
end

local function open_main_menu(action)
    if (not action or action == "open-menu") and mp.get_property("user-data/uosc/menu/type") == "bgm_main_menu" then
        mp.commandv("script-message-to", "uosc", "close-menu")
        return
    end
    local items = {}

    if state.logged_in then
        table.insert(items, {
            title = "已登录：" .. tostring(state.nickname or state.username),
            hint = "@" .. tostring(state.username),
            icon = "person",
            selectable = false,
            muted = true
        })
    else
        table.insert(items, {
            title = "使用剪贴板中的 Access Token 登录",
            hint = "先复制 Token 再点此项",
            icon = "login",
            active = true,
            value = { "script-message-to", "bangumi_sync", "login-clipboard" }
        })
        table.insert(items, {
            title = "打开浏览器获取个人 Access Token",
            hint = "next.bgm.tv",
            icon = "open_in_new",
            value = { "script-message-to", "bangumi_sync", "open-token-page" }
        })
    end

    if state.current_path then
        local match_desc = state.subject_name
            and (state.subject_name .. (state.episode and (" · 第 " .. tostring(state.episode) .. " 集") or ""))
            or "尚未匹配番剧"
        table.insert(items, {
            title = state.synced and ("✓ 本集已标记已看：" .. match_desc) or ("标记本集已看：" .. match_desc),
            hint = state.synced and "已完成" or "立即同步",
            icon = state.synced and "check_circle" or "bookmark_add",
            active = not state.synced and state.logged_in and state.subject_id ~= nil,
            separator = true,
            value = { "script-message-to", "bangumi_sync", "mark-now" }
        })
        table.insert(items, {
            title = "搜索 / 更换当前文件夹关联的番剧",
            hint = state.subject_id and ("#" .. tostring(state.subject_id)) or "未关联",
            icon = "search",
            value = { "script-message-to", "bangumi_sync", "open-search" }
        })
    end

    table.insert(items, {
        title = "同步模式：" .. mode_label(state.mode),
        hint = "点击切换",
        icon = "tune",
        separator = true,
        keep_open = true,
        value = { "script-message-to", "bangumi_sync", "cycle-mode" }
    })

    if state.logged_in then
        table.insert(items, {
            title = "退出当前 Bangumi 账号",
            icon = "logout",
            value = { "script-message-to", "bangumi_sync", "logout" }
        })
    end

    local menu = {
        type = "bgm_main_menu",
        title = "Bangumi 收藏同步",
        footnote = "快捷键 Ctrl+B · 片尾剩余 " .. tostring(state.remaining_sec) .. " 秒触发",
        items = items
    }
    mp.commandv("script-message-to", "uosc", action or "open-menu", utils.format_json(menu))
end

-- Script messages
mp.register_script_message("open-menu", function() open_main_menu("open-menu") end)
mp.register_script_message("mark-now", mark_current_watched)
mp.register_script_message("skip-prompt", function()
    state.prompted = true
    mp.osd_message("已跳过本集同步", 1.5)
end)
mp.register_script_message("open-search", function() open_search_menu() end)
mp.register_script_message("do-search", function(query) execute_search(query) end)

mp.register_script_message("bind-subject", function(sid, sname)
    state.subject_id = tonumber(sid)
    state.subject_name = sname
    if state.current_path and sname and sname ~= "" then
        mp.set_property_native("user-data/bangumi_sync/match-info", {
            anime = sname,
            episode = state.episode and ("第" .. tostring(state.episode) .. "话") or "",
            path = state.current_path
        })
    end
    update_uosc_button()
    if state.current_path then
        local folder = utils.split_path(state.current_path)
        if folder then
            run_cli({ "bind", folder, sid, sname }, function()
                mp.osd_message("已为当前目录关联 Bangumi：" .. sname, 2.5)
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
    local token = mp.get_property("clipboard/text") or ""
    token = token:gsub("^%s+", ""):gsub("%s+$", "")
    if token == "" then
        mp.osd_message("剪贴板为空，请先复制 Bangumi Access Token", 3)
        return
    end
    mp.osd_message("正在验证 Bangumi Token…", 2)
    run_cli({ "login", token }, function(res)
        if res.ok then
            state.logged_in = true
            state.username = res.username
            state.nickname = res.nickname
            update_uosc_button()
            mp.osd_message("✓ Bangumi 登录成功：" .. tostring(res.nickname), 3)
        else
            mp.osd_message("登录失败：" .. tostring(res.error or "Token 无效"), 4)
        end
    end)
end)

mp.register_script_message("open-token-page", function()
    mp.command_native_async({
        name = "subprocess",
        args = { "cmd", "/c", "start", "", "https://next.bgm.tv/demo/access-token" },
        playback_only = false
    })
    mp.osd_message("已打开浏览器，生成并复制 Token 后点击「从剪贴板登录」", 4)
end)

mp.register_script_message("logout", function()
    run_cli({ "logout" }, function()
        state.logged_in = false
        state.username = nil
        state.nickname = nil
        state.synced = false
        update_uosc_button()
        mp.osd_message("已退出 Bangumi 登录", 2)
    end)
end)

mp.register_script_message("uosc-version", function()
    update_uosc_button()
end)

-- React to file load and uosc_danmaku automatic anime match
mp.register_event("file-loaded", function()
    state.current_path = mp.get_property("path")
    state.subject_id = nil
    state.subject_name = nil
    state.episode = nil
    state.synced = false
    state.prompted = false
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
            mark_current_watched()
        else
            open_end_prompt()
        end
    end
end)

mp.add_key_binding("Ctrl+b", "bangumi-sync-menu", open_main_menu)

load_prefs()
refresh_status()
mp.add_timeout(0.8, update_uosc_button)
