local msg = require('mp.msg')
local utils = require("mp.utils")
local unpack = unpack or table.unpack

input_loaded, input = pcall(require, "mp.input")
uosc_available = false
latest_menu_anime = {}

-- 打开番剧数据匹配菜单
function get_animes(query)
    local encoded_query = url_encode(query)
    local url = options.api_server .. "/api/v2/search/anime"
    local params = "keyword=" .. encoded_query
    local full_url = url .. "?" .. params
    local items = {}

    local message = "加载数据中..."
    local menu_type = "menu_anime"
    local menu_title = "在此处输入番剧名称"
    local footnote = "使用enter或ctrl+enter进行搜索"
    local menu_cmd = { "script-message-to", mp.get_script_name(), "search-anime-event" }
    if uosc_available then
        update_menu_uosc(menu_type, menu_title, message, footnote, menu_cmd, query)
    else
        show_message(message, 30)
    end
    msg.verbose("尝试获取番剧数据：" .. full_url)

    local args = make_danmaku_request_args("GET", full_url)

    if args == nil then
        return
    end

    local res = mp.command_native({ name = 'subprocess', capture_stdout = true, capture_stderr = true, args = args })

    if not res.status or res.status ~= 0 then
        local message = "获取数据失败"
        if uosc_available then
            update_menu_uosc(menu_type, menu_title, message, footnote, menu_cmd, query)
        else
            show_message(message, 3)
        end
        msg.error("HTTP 请求失败：" .. res.stderr)
    end

    local response = utils.parse_json(res.stdout)

    if not response or not response.animes then
        local message = "无结果"
        if uosc_available then
            update_menu_uosc(menu_type, menu_title, message, footnote, menu_cmd, query)
        else
            show_message(message, 3)
        end
        msg.info("无结果")
        return
    end

    for _, anime in ipairs(response.animes) do
        table.insert(items, {
            title = anime.animeTitle,
            hint = anime.typeDescription,
            value = {
                "script-message-to",
                mp.get_script_name(),
                "search-episodes-event",
                anime.animeTitle, anime.bangumiId,
            },
        })
    end

    if uosc_available then
        latest_menu_anime = update_menu_uosc(menu_type, menu_title, items, footnote, menu_cmd, query)
    elseif input_loaded then
        show_message("", 0)
        mp.add_timeout(0.1, function()
            latest_menu_anime = utils.format_json(items)
            open_menu_select(items)
        end)
    end
end

function get_episodes(animeTitle, bangumiId)
    local url = options.api_server .. "/api/v2/bangumi/" .. bangumiId
    local items = {}

    local message = "加载数据中..."
    local menu_type = "menu_episodes"
    local menu_title = "剧集信息"
    local footnote = "使用 / 打开筛选"

    if uosc_available then
        update_menu_uosc(menu_type, menu_title, message, footnote)
    else
        show_message(message, 30)
    end

    local args = make_danmaku_request_args("GET", url)

    if args == nil then
        return
    end

    local res = mp.command_native({ name = 'subprocess', capture_stdout = true, capture_stderr = true, args = args })

    if not res.status or res.status ~= 0 then
        local message = "获取数据失败"
        if uosc_available then
            update_menu_uosc(menu_type, menu_title, message, footnote)
        else
            show_message(message, 3)
        end
        msg.error("HTTP 请求失败：" .. res.stderr)
    end

    local response = utils.parse_json(res.stdout)

    if not response or not response.bangumi or not response.bangumi.episodes then
        local message = "无结果"
        if uosc_available then
            update_menu_uosc(menu_type, menu_title, message, footnote)
        else
            show_message(message, 3)
        end
        msg.info("无结果")
        return
    end

    table.insert(items, {
        title = "← 返回搜索结果",
        value = { "script-message-to", mp.get_script_name(), "open-latest-menu-anime", latest_menu_anime },
        keep_open = false,
        selectable = true,
    })

    for _, episode in ipairs(response.bangumi.episodes) do
        table.insert(items, {
            title = episode.episodeTitle,
            hint = episode.episodeNumber,
            value = { "script-message-to", mp.get_script_name(), "load-danmaku",
            animeTitle, episode.episodeTitle, episode.episodeId },
            keep_open = false,
            selectable = true,
        })
    end

    if uosc_available then
        footnote = mp.get_property("filename")
        update_menu_uosc(menu_type, menu_title, items, footnote)
    elseif input_loaded then
        mp.add_timeout(0.1, function()
            open_menu_select(items)
        end)
    end
end

function update_menu_uosc(menu_type, menu_title, menu_item, menu_footnote, menu_cmd, query)
    local items = {}
    if type(menu_item) == "string" then
        table.insert(items, {
            title = menu_item,
            value = "",
            italic = true,
            keep_open = true,
            selectable = false,
            align = "center",
            icon = "spinner",
        })
    else
        items = menu_item
    end

    local menu_props = {
        type = menu_type,
        title = menu_title,
        search_style = menu_cmd and "palette" or "on_demand",
        search_debounce = menu_cmd and "submit" or 0,
        on_search = menu_cmd,
        footnote = menu_footnote,
        search_suggestion = query,
        items = items,
    }
    local json_props = utils.format_json(menu_props)
    mp.commandv("script-message-to", "uosc", "open-menu", json_props)

    return json_props
end

function open_menu_select(menu_items, is_time)
    local item_titles, item_values = {}, {}
    for i, v in ipairs(menu_items) do
        item_titles[i] = is_time and "[" .. v.hint .. "] " .. v.title or
            (v.hint and v.title .. " (" .. v.hint .. ")" or v.title)
        item_values[i] = v.value
    end
    mp.commandv('script-message-to', 'console', 'disable')
    input.select({
        prompt = is_time and '筛选:' or '选择:',
        items = item_titles,
        submit = function(id)
            input.terminate()
            local v = item_values[id]
            if type(v) == 'table' then
                mp.commandv(unpack(v))
            elseif type(v) == 'string' then
                mp.command(v)
            end
        end,
    })
end

-- 打开弹幕输入搜索菜单
function open_input_menu_get()
    mp.commandv('script-message-to', 'console', 'disable')
    local title = parse_title()
    input.get({
        prompt = '番剧名称:',
        default_text = title,
        cursor_position = title and #title + 1,
        submit = function(text)
            input.terminate()
            mp.commandv("script-message-to", mp.get_script_name(), "search-anime-event", text)
        end
    })
end

function open_input_menu_uosc()
    local items = {}

    if DANMAKU.anime and DANMAKU.episode then
        local episode = DANMAKU.episode:gsub("%s.-$","")
        episode = episode:match("^(第.*[话回集]+)%s*") or episode
        items[#items + 1] = {
            title = string.format("已关联弹幕：%s-%s", DANMAKU.anime, episode),
            bold = true,
            italic = true,
            keep_open = true,
            selectable = false,
        }
    end

    items[#items + 1] = {
        hint = "  追加|ds或|dy或|dm可搜索电视剧|电影|国漫",
        keep_open = true,
        selectable = false,
    }

    local menu_props = {
        type = "menu_danmaku",
        title = "在此处输入番剧名称",
        search_style = "palette",
        search_debounce = "submit",
        search_suggestion = parse_title(),
        on_search = { "script-message-to", mp.get_script_name(), "search-anime-event" },
        footnote = "使用enter或ctrl+enter进行搜索",
        items = items
    }
    local json_props = utils.format_json(menu_props)
    mp.commandv("script-message-to", "uosc", "open-menu", json_props)
end

function open_input_menu()
    if uosc_available then
        open_input_menu_uosc()
    elseif input_loaded then
        open_input_menu_get()
    end
end

-- 打开弹幕源添加管理菜单
function open_add_menu_get()
    local menu_log, deal_value = {}, {}

    -- 重建菜单内容函数
    local function rebuild_menu_log(select_num)
        deal_value = {}
        menu_log = {
            { text = "【既有弹幕源】", style = "{\\c&H00CCFF&\\b1}" },
            { text = "----------------------------", style = "{\\c&H888888&}" }
        }

        local serial = 0
        for url, source in pairs(DANMAKU.sources) do
            if source.data then
                serial = serial + 1
                local action, text

                if source.from == "api_server" then
                    action = source.blocked and "unblock" or "block"
                    text = string.format("  [%02d] %s [来源：弹幕服务器%s]  ", serial, url,
                        source.blocked and "（已屏蔽）" or "（未屏蔽）")
                else
                    action = "delete"
                    text = string.format("  [%02d] %s [来源：用户添加]  ", serial, url)
                end

                local style = (tonumber(select_num) == serial) and
                    "{\\c&HFFDE7F&\\b1}" or (action == "unblock" and "{\\c&H4C4CC3&\\b0}" or "{\\c&HCCCCCC&\\b0}")

                deal_value[serial] = {value = url, action = action}
                table.insert(menu_log, {text = text, style = style})
            end
        end

        if serial == 0 then
            table.insert(menu_log, { text = "        无", style = "" })
        end
    end

    -- 显示菜单
    local function show_menu(extra_lines, select_num)
        rebuild_menu_log(select_num)

        local display = {}
        for _, item in ipairs(menu_log) do table.insert(display, item) end
        table.insert(display, { text = "----------------------------", style = "{\\c&H888888&}" })

        if extra_lines then
            if #extra_lines < 2 then table.insert(display, { text = "\n", style = "" }) end
            for _, line in ipairs(extra_lines) do table.insert(display, line) end
        else
            table.insert(display, { text = "\n", style = "" })
            table.insert(display, {
                text = "提示: 输入【选项数字】可屏蔽或删除既有弹幕源",
                style = "{\\c&H999999&}"
            })
        end

        input.set_log(display)
    end

    -- 获取操作提示
    local function get_hint(action)
        local hints = {
            block = "按回车执行，屏蔽该弹幕源",
            unblock = "按回车执行，解除该弹幕源的屏蔽",
            delete = "按回车执行，删除该弹幕源"
        }
        return hints[action] or "按回车执行，获取输入源地址url的弹幕"
    end

    input.get({
        keep_open = true,
        prompt = "请在此输入源地址url: ",
        opened = function() show_menu() end,
        edited = function(text)
            text = text:gsub("^%s*(.-)%s*$", "%1")

            if text == "" then
                show_menu()
                return
            end

            local num = tonumber(text)
            local event = num and deal_value[num]
            local hint = get_hint(event and event.action)

            show_menu({
                { text = string.format("已输入: %s", text), style = "{\\c&HCCCCCC&}" },
                { text = hint, style = "{\\c&H999999&}" }
            }, text)
        end,
        submit = function(text)
            text = text:gsub("^%s*(.-)%s*$", "%1")
            if text == "" then return end

            local num = tonumber(text)
            local event = num and deal_value[num]

            if event then
                local args = string.format('{"type":"activate","value":"%s","action":"%s"}',
                    string.gsub(event.value, '\\', '\\\\'), event.action)
                mp.commandv("script-message-to", mp.get_script_name(), "setup-danmaku-source", args)
            else
                input.terminate()
                mp.commandv("script-message-to", mp.get_script_name(), "add-source-event", text)
            end

            mp.add_timeout(0.1, show_menu)
        end
    })
end

function open_add_menu_uosc()
    local sources = {}
    for url, source in pairs(DANMAKU.sources) do
        if source.data then
            local item = {title = url, value = url, keep_open = true,}
            if source.from == "api_server" then
                if source.blocked then
                    item.hint = "来源：弹幕服务器（已屏蔽）"
                    item.actions = {{icon = "check", name = "unblock", label = "解除屏蔽"},}
                else
                    item.hint = "来源：弹幕服务器（未屏蔽）"
                    item.actions = {{icon = "not_interested", name = "block", label = "屏蔽"},}
                end
            else
                item.hint = "来源：用户添加"
                item.actions = {{icon = "delete", name = "delete", label = "删除"},}
            end
            table.insert(sources, item)
        end
    end
    local menu_props = {
        type = "menu_source",
        title = "在此输入源地址url",
        search_style = "palette",
        search_debounce = "submit",
        on_search = { "script-message-to", mp.get_script_name(), "add-source-event" },
        footnote = "使用enter或ctrl+enter进行添加",
        items = sources,
        item_actions_place = "outside",
        callback = {mp.get_script_name(), 'setup-danmaku-source'},
    }
    local json_props = utils.format_json(menu_props)
    mp.commandv("script-message-to", "uosc", "open-menu", json_props)
end

function open_add_menu()
    if uosc_available then
        open_add_menu_uosc()
    elseif input_loaded then
        open_add_menu_get()
    end
end

-- 打开弹幕内容菜单
function open_content_menu(pos)
    local items = {}
    local time_pos = pos or mp.get_property_native("time-pos")
    local duration = mp.get_property_number("duration", 0)

    if COMMENTS ~= nil then
        for _, event in ipairs(COMMENTS) do
            local text = event.clean_text:gsub("^m%s[mbl%s%-%d%.]+$", ""):gsub("^%s*(.-)%s*$", "%1")
            local delay = event.delay
            local start_time = event.start_time
            local end_time = event.end_time
            if text and text ~= "" and start_time >= 0 and start_time <= duration then
                local delay_label_suffix = nil
                local delay_num = delay and tonumber(delay)
                if delay_num and math.abs(delay_num) > 0 then
                    delay_label_suffix = string.format("已存在延迟: %+0.1fs", delay_num)
                end

                local adjust_label = '调整弹幕延迟'
                if delay_label_suffix then
                    adjust_label = adjust_label .. '（' .. delay_label_suffix .. '）'
                end

                table.insert(items, {
                    title = abbr_str(text, 60),
                    hint = seconds_to_time(start_time) .. "  (" .. utf8_sub(remove_query(event.source), 1, 70) .. ")",
                    actions = {
                        {
                            name = 'block_source',
                            icon = 'block',
                            label = '屏蔽对应弹幕源'
                        },
                        {
                            name = 'adjust_delay',
                            icon = 'more_time',
                            label = adjust_label,
                        },
                    },
                    value = { "seek", start_time, "absolute" },
                    active = time_pos >= start_time and time_pos <= end_time,
                })
            end
        end
    end

    local menu_props = {
        type = "menu_content",
        title = "弹幕内容",
        footnote = "使用 / 打开搜索",
        items = items,
        item_actions_place = "outside",
        callback = {mp.get_script_name(), 'handle-danmaku-content-action'},
    }
    local json_props = utils.format_json(menu_props)

    if uosc_available then
        mp.commandv("script-message-to", "uosc", "open-menu", json_props)
    elseif input_loaded then
        open_menu_select(items, true)
    end
end

local menu_items_config = {
    bold = { title = "粗体", hint = options.bold, original = options.bold,
        footnote = "true / false", },
    fontsize = { title = "大小", hint = options.fontsize, original = options.fontsize,
        scope = { min = 0, max = math.huge }, footnote = "请输入整数(>=0)", },
    outline = { title = "描边", hint = options.outline, original = options.outline,
        scope = { min = 0.0, max = 4.0 }, footnote = "输入范围：(0.0-4.0)" },
    shadow = { title = "阴影", hint = options.shadow, original = options.shadow,
        scope = { min = 0, max = math.huge }, footnote = "请输入整数(>=0)", },
    scrolltime = { title = "速度", hint = options.scrolltime, original = options.scrolltime,
        scope = { min = 1, max = math.huge }, footnote = "请输入整数(>=1)", },
    opacity = { title = "透明度", hint = options.opacity, original = options.opacity,
        scope = { min = 0, max = 1 }, footnote = "输入范围：0（完全透明）到1（不透明）", },
    displayarea = { title = "弹幕显示范围", hint = options.displayarea, original = options.displayarea,
        scope = { min = 0.0, max = 1.0 }, footnote = "显示范围(0.0-1.0)", },
}
-- 创建一个包含键顺序的表，这是样式菜单的排布顺序
local ordered_keys = {"bold", "fontsize", "outline", "shadow", "scrolltime", "opacity", "displayarea"}

-- 设置弹幕样式菜单
function open_style_menu_get(query, indicator)
    mp.commandv('script-message-to', 'console', 'disable')
    local menu_log = {}

    local select_num = 0
    local select_query = nil
    if query then
        if tonumber(query) ~= nil then
            select_num = tonumber(query)
        else
            for i, v in ipairs(ordered_keys) do
                if v == query then
                    select_num = i
                end
            end
        end
        select_query = ordered_keys[select_num]
    end

    local function build_menu(source)
        menu_log = {
            { text = "【弹幕样式菜单】", style = "{\\c&H00CCFF&\\b1}" },
            { text = ("-"):rep(33), style = "{\\c&H888888&}" }
        }

        local serial = 0
        for _, key in ipairs(ordered_keys) do
            serial = serial + 1
            local config = menu_items_config[key]
            local text = string.format("  [%02d] %s   [目前：%s] ", serial, config.title, config.hint)
            text = config.hint ~= config.original and text .. "⟳" or text
            local style = serial == select_num and "{\\c&HFFDE7F&}" or "{\\c&HCCCCCC&}"
            local item_config = { text = text, style = style }
            table.insert(menu_log, item_config)
        end

        table.insert(menu_log, { text = ("-"):rep(33), style = "{\\c&H888888&}" })
        if select_num == 0 then
            table.insert(menu_log, {
                text = "注: 样式更改仅在本次播放生效",
                style = "{\\c&HFFDE7F&}"
            })
            table.insert(menu_log, {
                text = "提示: 输入【w】可上移选项，【s】可下移选项",
                style = "{\\c&H999999&}"
            })
        else
            local input_text = source and source or ""
            local config = menu_items_config[select_query]
            local suffix = ""
            if config and config.hint ~= config.original then
                suffix = "（输入\\r恢复默认配置）"
            end
            input_text = string.format("已输入%s: %s", suffix, input_text)

            local scope = config and config.footnote or ""
            local hint_text = select_query == "bold" and "提示: 输入【y】切换状态" or "提示: " .. scope
            local hint_style = "{\\c&H999999&}"
            if source and source:lower() == "\\r" then
                hint_text = string.format("提示: 回车将恢复默认配置 < %s >", config.original)
            end
            if indicator == "refresh" or indicator == "updata" then
                indicator = ""
                hint_text = "提示: 样式更改成功"
                hint_style = "{\\c&HFFDE7F&}"
                mp.add_timeout(1.5, build_menu)
            elseif indicator == "error" then
                indicator = ""
                hint_text = "提示: 输入非数字字符或范围出错"
                hint_style = "{\\c&H4C4CC3&}"
                mp.add_timeout(1.5, build_menu)
            end

            table.insert(menu_log, { text = input_text, style = "{\\c&HCCCCCC&}" })
            table.insert(menu_log, { text = hint_text, style = hint_style })
        end
        input.set_log(menu_log)
    end

    input.get({
        keep_open = true,
        prompt = "请在此输入操作（w/s|上移/下移）: ",
        opened = function() build_menu() end,
        edited = function(text)
            text = text:gsub("^%s*(.-)%s*$", "%1")

            if text == "" then
                build_menu()
                return
            end

            if text:lower() == "w" or text:lower() == "s" then
                input.terminate()
                select_num = text:lower() == "w" and select_num - 1 or select_num + 1
                select_num = (select_num > #ordered_keys) and 1 or (select_num <= 0 and #ordered_keys or select_num)
                mp.add_timeout(0.01, function()
                    open_style_menu_get(select_num)
                end)
                return
            end

            build_menu(text)
        end,
        submit = function(text)
            if select_query == nil then return end
            text = text:gsub("^%s*(.-)%s*$", "%1")
            if text == "" then return end

            if text:lower() == "\\r" then
                input.terminate()
                local args = string.format('{"type":"activate","action":"%s","index":%d}', select_query, select_num)
                mp.commandv("script-message-to", mp.get_script_name(), "setup-danmaku-style", args)
            else
                if menu_items_config[select_query]["scope"] ~= nil then
                    input.terminate()
                    mp.commandv("script-message-to", mp.get_script_name(), "setup-danmaku-style", select_query, text)
                elseif text:lower() == "y" and select_query == "bold" then
                    input.terminate()
                    local args = string.format('{"type":"activate","index":%d}', select_num)
                    mp.commandv("script-message-to", mp.get_script_name(), "setup-danmaku-style", args)
                end
            end
            return
        end
    })
end

local DANMAKU_STYLE_PRESETS = {
    {
        id = "comfort",
        title = "清爽舒适（默认）",
        hint = "36px · 78% · 避让字幕",
        values = {
            fontname = "LXGW WenKai Mono Lite", fontsize = 36, opacity = 0.78,
            displayarea = 0.72, scrolltime = 13, fixtime = 5, bold = true,
            outline = 1.0, shadow = 0.5, max_screen_danmaku = 0, merge_tolerance = 5,
            block_top = false, block_bottom = false, block_scroll = false, block_color = false,
        }
    },
    {
        id = "soft",
        title = "淡雅护眼",
        hint = "32px · 55% · 上半屏",
        values = {
            fontsize = 32, opacity = 0.55, displayarea = 0.50, scrolltime = 15,
            fixtime = 4, bold = false, outline = 0.8, shadow = 0.4, max_screen_danmaku = 45,
            block_bottom = true,
        }
    },
    {
        id = "clear_large",
        title = "大字清晰",
        hint = "46px · 88% · 粗体描边",
        values = {
            fontsize = 46, opacity = 0.88, displayarea = 0.72, scrolltime = 12,
            fixtime = 5, bold = true, outline = 1.6, shadow = 0.9,
        }
    },
    {
        id = "minimal",
        title = "极简不挡画面",
        hint = "30px · 65% · 顶部35%",
        values = {
            fontsize = 30, opacity = 0.65, displayarea = 0.35, scrolltime = 14,
            fixtime = 4, bold = false, outline = 0.8, shadow = 0.4, max_screen_danmaku = 30,
            merge_tolerance = 8, block_top = true, block_bottom = true, block_color = true,
        }
    },
    {
        id = "party",
        title = "高能狂欢",
        hint = "38px · 88% · 全屏不限",
        values = {
            fontsize = 38, opacity = 0.88, displayarea = 0.95, scrolltime = 11,
            fixtime = 5, bold = true, outline = 1.0, shadow = 0.5, max_screen_danmaku = 0,
            merge_tolerance = 3, block_top = false, block_bottom = false, block_scroll = false, block_color = false,
        }
    },
}

local function style_num(v, fallback)
    local n = tonumber(v)
    return n ~= nil and n or fallback
end

local function style_approx(a, b)
    return math.abs(style_num(a, -9999) - style_num(b, -8888)) < 0.015
end

local function build_danmaku_style_menu_props()
    local script = mp.get_script_name()
    local fs = math.floor(style_num(options.fontsize, 44) + 0.5)
    local op = style_num(options.opacity, 0.78)
    local op_pct = math.floor(op * 100 + 0.5)
    local area = style_num(options.displayarea, 0.72)
    local area_pct = math.floor(area * 100 + 0.5)
    local st = math.floor(style_num(options.scrolltime, 13) + 0.5)
    local ft = math.floor(style_num(options.fixtime, 5) + 0.5)
    local ol = style_num(options.outline, 1.2)
    local sh = style_num(options.shadow, 0.6)
    local max_dm = math.floor(style_num(options.max_screen_danmaku, 0) + 0.5)
    local merge_t = math.floor(style_num(options.merge_tolerance, 5) + 0.5)
    local ch_conv = math.floor(style_num(options.chConvert, 1) + 0.5)

    local function choice_item(title, hint, key, val, is_active)
        return {
            title = title,
            hint = hint,
            icon = is_active and "radio_button_checked" or "radio_button_unchecked",
            active = is_active,
            keep_open = true,
            value = { "script-message-to", script, "dm-style-set", key, tostring(val) },
        }
    end

    local function step_item(title, hint, key, delta, min_v, max_v, icon)
        return {
            title = title,
            hint = hint,
            icon = icon,
            keep_open = true,
            value = { "script-message-to", script, "dm-style-step", key, tostring(delta), tostring(min_v), tostring(max_v) },
        }
    end

    local function toggle_item(title, hint_on, hint_off, key, enabled)
        return {
            title = title,
            hint = enabled and hint_on or hint_off,
            icon = enabled and "check_box" or "check_box_outline_blank",
            active = enabled,
            keep_open = true,
            value = { "script-message-to", script, "dm-style-toggle", key },
        }
    end

    -- 1. 一键风格预设
    local preset_items = {}
    for _, p in ipairs(DANMAKU_STYLE_PRESETS) do
        table.insert(preset_items, {
            title = p.title,
            hint = p.hint,
            icon = "auto_awesome",
            keep_open = true,
            value = { "script-message-to", script, "dm-style-preset", p.id },
        })
    end

    -- 2. 字体大小（按真实观感校准档位 + 精细 ±2 步进）
    local fontsize_items = {
        step_item("字号 −2", "当前 " .. fs .. " px", "fontsize", -2, 18, 76, "remove"),
        step_item("字号 +2", "当前 " .. fs .. " px", "fontsize", 2, 18, 76, "add"),
    }
    fontsize_items[2].separator = true
    for _, opt_row in ipairs({
        {24, "超小 (24 px)", "极简轻盈不抢戏"},
        {28, "极小 (28 px)", "细腻紧凑"},
        {32, "较小 (32 px)", "清爽通透"},
        {36, "适中 (36 px)", "推荐默认 · 舒适易读"},
        {42, "偏大 (42 px)", "清晰醒目"},
        {48, "较大 (48 px)", "大屏 / 远距观看"},
        {56, "特大 (56 px)", "高分屏醒目"},
    }) do
        table.insert(fontsize_items, choice_item(opt_row[2], opt_row[3], "fontsize", opt_row[1], fs == opt_row[1]))
    end

    -- 3. 不透明度
    local opacity_items = {
        step_item("透明度 −10%", "当前 " .. op_pct .. "%", "opacity", -0.10, 0.10, 1.00, "remove"),
        step_item("透明度 +10%", "当前 " .. op_pct .. "%", "opacity", 0.10, 0.10, 1.00, "add"),
    }
    opacity_items[2].separator = true
    for _, opt_row in ipairs({
        {0.30, "30%（极淡）", "几乎不干扰画面"},
        {0.45, "45%（淡雅）", "轻柔半透明"},
        {0.60, "60%（柔和）", "护眼适中"},
        {0.78, "78%（推荐）", "清晰且通透"},
        {0.90, "90%（醒目）", "接近不透明"},
        {1.00, "100%（完全不透明）", "最高对比度"},
    }) do
        table.insert(opacity_items, choice_item(opt_row[2], opt_row[3], "opacity", opt_row[1], style_approx(op, opt_row[1])))
    end

    -- 4. 显示区域
    local area_items = {}
    for _, opt_row in ipairs({
        {0.25, "顶部 25%", "极简不遮主体"},
        {0.45, "上半屏 45%", "留出人物与字幕"},
        {0.60, "上方 60%", "平衡视野"},
        {0.72, "避让字幕 72%", "推荐 · 不挡底部字幕"},
        {0.85, "宽幅 85%", "更多同屏轨道"},
        {1.00, "全屏 100%", "完整覆盖"},
    }) do
        table.insert(area_items, choice_item(opt_row[2], opt_row[3], "displayarea", opt_row[1], style_approx(area, opt_row[1])))
    end

    -- 5. 滚动速度
    local speed_items = {
        step_item("更慢 (+2 秒)", "当前 " .. st .. " 秒滚完", "scrolltime", 2, 4, 25, "remove"),
        step_item("更快 (−2 秒)", "当前 " .. st .. " 秒滚完", "scrolltime", -2, 4, 25, "add"),
    }
    speed_items[2].separator = true
    for _, opt_row in ipairs({
        {18, "极慢 (18 秒)", "从容阅读长弹幕"},
        {15, "柔和 (15 秒)", "轻松舒缓"},
        {13, "标准 (13 秒)", "推荐节奏"},
        {10, "较快 (10 秒)", "紧凑明快"},
        {8,  "快速 (8 秒)",  "高密弹幕不滞留"},
        {6,  "飞速 (6 秒)",  "极速掠过"},
    }) do
        table.insert(speed_items, choice_item(opt_row[2], opt_row[3], "scrolltime", opt_row[1], st == opt_row[1]))
    end

    -- 6. 字体与外观（字体/粗体/描边/阴影/固定弹幕时长）
    local font_items = {}
    for _, frow in ipairs({
        {"LXGW WenKai Mono Lite", "霞鹜文楷 Mono（内置推荐）", "柔和书卷质感"},
        {"Microsoft YaHei UI",    "微软雅黑 UI",            "现代无衬线"},
        {"SimHei",                "黑体 (SimHei)",          "经典醒目"},
        {"YouYuan",               "幼圆 (YouYuan)",         "圆润轻快"},
        {"sans-serif",            "系统默认无衬线",          "自动回退"},
    }) do
        table.insert(font_items, choice_item(frow[2], frow[3], "fontname", frow[1], tostring(options.fontname) == frow[1]))
    end

    local outline_items = {}
    for _, orow in ipairs({
        {0.0, "无描边 (0.0)", "纯粹无边"},
        {0.8, "细描边 (0.8)", "轻巧干净"},
        {1.2, "标准描边 (1.2)", "推荐默认"},
        {1.8, "加粗描边 (1.8)", "亮画面更清晰"},
        {2.5, "厚描边 (2.5)", "高反差醒目"},
        {3.5, "超厚描边 (3.5)", "极强边缘"},
    }) do
        table.insert(outline_items, choice_item(orow[2], orow[3], "outline", orow[1], style_approx(ol, orow[1])))
    end

    local shadow_items = {}
    for _, srow in ipairs({
        {0.0, "无阴影 (0.0)", "扁平轻盈"},
        {0.6, "轻阴影 (0.6)", "推荐默认"},
        {1.2, "中等阴影 (1.2)", "层次更立体"},
        {2.0, "深阴影 (2.0)", "强对比度"},
    }) do
        table.insert(shadow_items, choice_item(srow[2], srow[3], "shadow", srow[1], style_approx(sh, srow[1])))
    end

    local fixtime_items = {}
    for _, trow in ipairs({
        {3, "3 秒（短暂）", "减少遮挡"},
        {5, "5 秒（标准）", "推荐默认"},
        {7, "7 秒（较久）", "方便细看注释"},
    }) do
        table.insert(fixtime_items, choice_item(trow[2], trow[3], "fixtime", trow[1], ft == trow[1]))
    end

    local appearance_items = {
        { id = "style_font", title = "弹幕字体", hint = tostring(options.fontname), items = font_items },
        toggle_item("字体加粗", "已开启粗体", "常规字重", "bold", options.bold == true),
        { id = "style_outline", title = "描边粗细", hint = string.format("%.1f", ol), items = outline_items },
        { id = "style_shadow", title = "阴影深度", hint = string.format("%.1f", sh), items = shadow_items },
        { id = "style_fixtime", title = "顶部/底部弹幕停留时间", hint = ft .. " 秒", items = fixtime_items },
    }

    -- 7. 屏蔽与过滤
    local density_items = {}
    for _, drow in ipairs({
        {0,   "不限制",     "显示全部弹幕"},
        {25,  "精简 (25条)", "画面极度清爽"},
        {45,  "适中 (45条)", "日常番剧舒适"},
        {70,  "较多 (70条)", "保留高能氛围"},
        {100, "高密 (100条)", "仅防极端刷屏"},
    }) do
        table.insert(density_items, choice_item(drow[2], drow[3], "max_screen_danmaku", drow[1], max_dm == drow[1]))
    end

    local merge_items = {}
    for _, mrow in ipairs({
        {-1, "关闭合并",   "保留全部重复弹幕"},
        {3,  "3 秒内合并", "轻度去重"},
        {5,  "5 秒内合并", "推荐默认（显示 xN）"},
        {10, "10 秒内合并", "强力去刷屏"},
        {15, "15 秒内合并", "极简去重"},
    }) do
        table.insert(merge_items, choice_item(mrow[2], mrow[3], "merge_tolerance", mrow[1], merge_t == mrow[1]))
    end

    local ch_items = {
        choice_item("不转换（保持原文）", "简繁原样显示", "chConvert", 0, ch_conv == 0),
        choice_item("统一转换为简体中文", "推荐默认", "chConvert", 1, ch_conv == 1),
        choice_item("统一转换为繁体中文", "繁中显示", "chConvert", 2, ch_conv == 2),
    }

    local filter_tags = {}
    if options.block_top then table.insert(filter_tags, "禁顶") end
    if options.block_bottom then table.insert(filter_tags, "禁底") end
    if options.block_scroll then table.insert(filter_tags, "禁滚") end
    if options.block_color then table.insert(filter_tags, "纯白") end
    if max_dm > 0 then table.insert(filter_tags, "≤" .. max_dm .. "条") end
    local filter_summary = #filter_tags > 0 and table.concat(filter_tags, " · ") or "全类型显示"

    local filter_items = {
        toggle_item("屏蔽顶部固定弹幕", "已屏蔽", "正常显示", "block_top", options.block_top == true),
        toggle_item("屏蔽底部固定弹幕", "已屏蔽", "正常显示", "block_bottom", options.block_bottom == true),
        toggle_item("屏蔽滚动弹幕", "已屏蔽", "正常显示", "block_scroll", options.block_scroll == true),
        toggle_item("屏蔽彩色弹幕（统一纯白）", "已统一白色", "保留原色", "block_color", options.block_color == true),
    }
    filter_items[4].separator = true
    table.insert(filter_items, {
        id = "style_density", title = "同屏弹幕数量上限",
        hint = max_dm > 0 and (max_dm .. " 条") or "不限",
        items = density_items,
    })
    table.insert(filter_items, {
        id = "style_merge", title = "重复刷屏弹幕合并",
        hint = merge_t >= 0 and (merge_t .. " 秒") or "已关闭",
        items = merge_items,
    })
    table.insert(filter_items, {
        id = "style_chconv", title = "弹幕简繁转换",
        hint = ch_conv == 1 and "统一简体" or (ch_conv == 2 and "统一繁体" or "保持原文"),
        items = ch_items,
    })

    local area_label = area_pct .. "%" .. (area_pct == 72 and " 避让字幕" or "")
    local font_short = tostring(options.fontname):gsub("LXGW WenKai Mono Lite", "霞鹜文楷"):gsub("Microsoft YaHei UI", "微软雅黑")

    return {
        type = "menu_style",
        id = "menu_style_root",
        title = "弹幕样式与过滤（实时生效 · 自动保存）",
        search_style = "disabled",
        footnote = "点击任意项直接选择档位，无需手动输入数字；所有更改自动记住",
        items = {
            { id = "style_presets", title = "一键风格预设", hint = "5 套精选方案", separator = true, items = preset_items },
            { id = "style_fontsize", title = "字体大小", hint = fs .. " px", items = fontsize_items },
            { id = "style_opacity", title = "不透明度", hint = op_pct .. "%", items = opacity_items },
            { id = "style_area", title = "显示区域", hint = area_label, items = area_items },
            { id = "style_speed", title = "滚动速度", hint = st .. " 秒", items = speed_items },
            { id = "style_appearance", title = "字体 · 粗细 · 描边 · 阴影", hint = font_short .. (options.bold and " · 粗" or ""), items = appearance_items },
            { id = "style_filters", title = "屏蔽类型 · 密度 · 去重 · 简繁", hint = filter_summary, separator = true, items = filter_items },
            {
                title = "恢复全部默认弹幕样式",
                hint = "重置并保存",
                icon = "restart_alt",
                keep_open = true,
                value = { "script-message-to", script, "dm-style-reset" },
            },
        },
    }
end

function open_style_menu_uosc(actived, status)
    local action = (status == "update") and "update-menu" or "open-menu"
    local menu_props = build_danmaku_style_menu_props()
    mp.commandv("script-message-to", "uosc", action, utils.format_json(menu_props))
end

function open_style_menu(actived, status)
    if type(open_danmaku_style_panel) == "function" then
        open_danmaku_style_panel()
    elseif uosc_available then
        open_style_menu_uosc(actived, status)
    elseif input_loaded then
        mp.add_timeout(0.01, function()
            open_style_menu_get(actived, status)
        end)
    else
        show_message("无支持可用的 UI框架，不支持使用该功能", 3)
    end
end

-- 打开以指定时间为起点的延迟菜单
function open_delay_from_time_get(source, time, status)
    mp.commandv('script-message-to', 'console', 'disable')
    local menu_log = {}

    local function build_menu(query, input_text)
        menu_log = {
            { text = "【从该时间起调整弹幕延迟】", style = "{\\c&H00CCFF&\\b1}" },
            { text = ("-"):rep(33), style = "{\\c&H888888&}" }
        }

        table.insert(menu_log, { text = "\n", style = "" })
        local hint_text = "提示：请输入数字，单位（秒）/ 或者按照形如\"14m15s\"的格式输入分钟数加秒数"
        local hint_style = "{\\c&H999999&}"
        if status == "error" then
            hint_text = "提示: 输入非数字字符或范围出错"
            hint_style = "{\\c&H4C4CC3&}"
        end

        table.insert(menu_log, { text = input_text and ("已输入：" .. input_text) or "", style = "{\\c&HCCCCCC&}" })
        table.insert(menu_log, { text = hint_text, style = hint_style })
        input.set_log(menu_log)
    end

    input.get({
        keep_open = true,
        prompt = "请输入要设置的延迟（秒或 XmYs）: ",
        opened = function() build_menu() end,
        edited = function(text)
            text = text:gsub("^%s*(.-)%s*$", "%1")
            if text == "" then
                build_menu()
                return
            end
            build_menu(text)
        end,
        submit = function(text)
            text = text and text:gsub("^%s*(.-)%s*$", "%1") or ""
            if text == "" then return end
            input.terminate()
            local parsed = parse_delay_input(text)
            if parsed ~= nil then
                mp.commandv("script-message", "danmaku-delay", tostring(parsed), tostring(time), tostring(source))
            else
                open_delay_from_time(time, "error")
            end
        end
    })
end

function open_delay_from_time_uosc(source, time, status)
    if not uosc_available then
        show_message("无uosc UI框架，不支持使用该功能", 2)
        return
    end

    local menu_props = {
        type = "menu_delay_from_time",
        title = "从该时间起调整弹幕延迟",
        search_style = "palette",
        search_debounce = "submit",
        footnote = "请输入数字，单位（秒）/ 或者按照形如\"14m15s\"的格式输入分钟数加秒数",
        items = {},
        on_search = { "script-message-to", mp.get_script_name(), "setup-content-delay", tostring(time), tostring(source) },
    }

    if status == "error" then
    menu_props.title = "输入非数字字符或范围出错"
    mp.add_timeout(1.0, function() open_delay_from_time_uosc(source, time) end)
    end

    local json_props = utils.format_json(menu_props)
    mp.commandv("script-message-to", "uosc", "open-menu", json_props)
end

function open_delay_from_time(source, time, status)
    if uosc_available then
        open_delay_from_time_uosc(source, time, status)
    elseif input_loaded then
        mp.add_timeout(0.01, function()
            open_delay_from_time_get(source, time, status)
        end)
    else
        show_message("无支持可用的 UI框架，不支持使用该功能", 3)
    end
end

-- 设置弹幕源延迟菜单
function open_delay_menu_get(source, status)
    mp.commandv('script-message-to', 'console', 'disable')
    local menu_log = {}

    local serial = 0
    local select_num = 0
    if source and tonumber(source) ~= nil then
        select_num = tonumber(source)
    end
    local select_url = nil

    local function build_menu(query, text)
        menu_log = {
            { text = "【弹幕源延迟菜单】", style = "{\\c&H00CCFF&\\b1}" },
            { text = ("-"):rep(33), style = "{\\c&H888888&}" }
        }

        serial, select_num = 0, 0
        for url, src in pairs(DANMAKU.sources) do
            if src.data and not src.blocked then
                local delay = 0
                serial = serial + 1
                select_num = (url == source) and serial or select_num
                if src.delay_segments then
                    for _, seg in ipairs(src.delay_segments) do
                        if seg.start == 0 then
                            delay = seg.delay or 0
                            break
                        end
                    end
                end
                local hint = "当前弹幕源延迟: " .. string.format("%.1f", delay + 1e-10) .. "秒"
                local text = string.format("  [%02d] %s   [%s] ", serial, url, hint)
                local style = (serial == select_num) and "{\\c&HFFDE7F&}" or "{\\c&HCCCCCC&}"
                table.insert(menu_log, { text = text, style = style })
                select_url = serial == select_num and url or select_url
            end
        end
        if serial == 0 then
            table.insert(menu_log, { text = "        无", style = "" })
        end

        table.insert(menu_log, { text = ("-"):rep(33), style = "{\\c&H888888&}" })
        if select_num == 0 then
            table.insert(menu_log, { text = "\n", style = "" })
            table.insert(menu_log, {
                text = "提示: 输入【w】可上移选项，【s】可下移选项",
                style = "{\\c&H999999&}"
            })
        else
            local input_text = "已输入：" .. (text ~= nil and text or "")

            local hint_text = "提示：请输入数字，单位（秒）/ 或者按照形如\"14m15s\"的格式输入分钟数加秒数"
            local hint_style = "{\\c&H999999&}"
            if status == "refresh" then
                status = ""
                hint_text = "提示: 样式更改成功"
                hint_style = "{\\c&HFFDE7F&}"
                mp.add_timeout(1.5, build_menu)
            elseif status == "error" then
                status = ""
                hint_text = "提示: 输入非数字字符或范围出错"
                hint_style = "{\\c&H4C4CC3&}"
                mp.add_timeout(1.5, build_menu)
            end

--            table.insert(menu_log, { text = input_text, style = "{\\c&HCCCCCC&}" })
            table.insert(menu_log, { text = input_text, style = "{\\c&HCCCCCC&}" })
            table.insert(menu_log, { text = hint_text, style = hint_style })
        end
        input.set_log(menu_log)
    end

    input.get({
        keep_open = true,
        prompt = "请在此输入操作（w/s|上移/下移）: ",
        opened = function() build_menu() end,
        edited = function(text)
            text = text:gsub("^%s*(.-)%s*$", "%1")

            if text == "" then
                build_menu()
                return
            end

            if text:lower() == "w" or text:lower() == "s" then
                input.terminate()
                select_num = text:lower() == "w" and select_num - 1 or select_num + 1
                select_num = (select_num > serial) and 1 or (select_num <= 0 and serial or select_num)
                mp.add_timeout(0.01, function()
                    open_delay_menu_get(select_num)
                end)
                return
            end

            build_menu(select_num, text)
        end,
        submit = function(text)
            if select_url == nil then return end
            text = text:gsub("^%s*(.-)%s*$", "%1")
            if text == "" then return end

            input.terminate()
            mp.commandv("script-message-to", mp.get_script_name(), "setup-source-delay", select_url, text)
            return
        end
    })
end

function open_delay_menu_uosc(source_url, status)
    if not uosc_available then
        show_message("无uosc UI框架，不支持使用该功能", 2)
        return
    end

    local sources = {}
    for url, source in pairs(DANMAKU.sources) do
        if source.data and not source.blocked then
            local delay = 0
            if source.delay_segments then
                for _, seg in ipairs(source.delay_segments) do
                    if seg.start == 0 then
                        delay = seg.delay or 0
                        break
                    end
                end
            end
            local item = {title = url, value = url, keep_open = true,}
            item.hint = "当前弹幕源延迟:" .. string.format("%.1f", delay + 1e-10) .. "秒"
            item.active = url == source_url
            table.insert(sources, item)
        end
    end

    local menu_props = {
        type = "menu_delay",
        title = "弹幕源延迟设置",
        search_style = "disabled",
        items = sources,
        callback = {mp.get_script_name(), 'setup-source-delay'},
    }
    if source_url ~= nil then
        if status == "error" then
            menu_props.title = "输入非数字字符或范围出错"
            -- 创建一个定时器，在1秒后触发回调函数，删除搜索栏错误信息
            mp.add_timeout(1.0, function() open_delay_menu_uosc(source_url) end)
        else
            menu_props.title = "请输入数字，单位（秒）/ 或者按照形如\"14m15s\"的格式输入分钟数加秒数"
        end
        menu_props.search_style = "palette"
        menu_props.search_debounce = "submit"
        menu_props.on_search = { "script-message-to", mp.get_script_name(), "setup-source-delay", source_url }
    end

    local json_props = utils.format_json(menu_props)
    mp.commandv("script-message-to", "uosc", "open-menu", json_props)
end

function open_delay_menu(source, status)
    if uosc_available then
        open_delay_menu_uosc(source, status)
    elseif input_loaded then
        mp.add_timeout(0.01, function()
            open_delay_menu_get(source, status)
        end)
    else
        show_message("无支持可用的 UI框架，不支持使用该功能", 3)
    end
end

-- 总集合弹幕菜单
local total_menu_items_config = {
    { title = "弹幕搜索", action = "open_search_danmaku_menu" },
    { title = "从源添加弹幕", action = "open_add_source_menu" },
    { title = "弹幕源延迟设置", action = "open_source_delay_menu" },
    { title = "弹幕样式", action = "open_danmaku_style_menu" },
    { title = "弹幕内容", action = "open_content_danmaku_menu" },
}

function open_add_total_menu_uosc()
    local items = {}

    if DANMAKU.anime and DANMAKU.episode then
        local episode = DANMAKU.episode:gsub("%s.-$","")
        episode = episode:match("^(第.*[话回集]+)%s*") or episode
        items[#items + 1] = {
            title = string.format("已关联弹幕：%s-%s", DANMAKU.anime, episode),
            bold = true,
            italic = true,
            keep_open = true,
            selectable = false,
        }
    end

    for _, config in ipairs(total_menu_items_config) do
        table.insert(items, {
            title = config.title,
            value = { "script-message-to", mp.get_script_name(), config.action },
            keep_open = false,
            selectable = true,
        })
    end

    local menu_props = {
        type = "menu_total",
        title = "弹幕设置",
        search_style = "disabled",
        items = items,
    }
    local json_props = utils.format_json(menu_props)
    mp.commandv("script-message-to", "uosc", "open-menu", json_props)
end

function open_add_total_menu_select()
    local item_titles, item_values = {}, {}
    for i, config in ipairs(total_menu_items_config) do
        item_titles[i] = config.title
        item_values[i] = { "script-message-to", mp.get_script_name(), config.action }
    end

    mp.commandv('script-message-to', 'console', 'disable')
    input.select({
        prompt = '选择:',
        items = item_titles,
        submit = function(id)
            mp.commandv(unpack(item_values[id]))
        end,
    })
end

function open_add_total_menu()
    if uosc_available then
        open_add_total_menu_uosc()
    elseif input_loaded then
        open_add_total_menu_select()
    end
end


local function register_danmaku_uosc_buttons()
    mp.commandv(
        "script-message-to",
        "uosc",
        "set-button",
        "danmaku",
        utils.format_json({
            icon = "search",
            tooltip = "弹幕搜索 (Ctrl+D)",
            command = "script-message open_search_danmaku_menu",
        })
    )

    mp.commandv(
        "script-message-to",
        "uosc",
        "set-button",
        "danmaku_source",
        utils.format_json({
            icon = "add_box",
            tooltip = "从源添加弹幕",
            command = "script-message open_add_source_menu",
        })
    )

    mp.commandv(
        "script-message-to",
        "uosc",
        "set-button",
        "danmaku_styles",
        utils.format_json({
            icon = "palette",
            tooltip = "弹幕样式",
            command = "script-message open_danmaku_style_menu",
        })
    )

    mp.commandv(
        "script-message-to",
        "uosc",
        "set-button",
        "danmaku_delay",
        utils.format_json({
            icon = "more_time",
            tooltip = "弹幕源延迟设置",
            command = "script-message open_source_delay_menu",
        })
    )

    mp.commandv(
        "script-message-to",
        "uosc",
        "set-button",
        "danmaku_menu",
        utils.format_json({
            icon = "tune",
            tooltip = "弹幕管理与搜索 (Shift+D / Ctrl+D)",
            command = "script-message open_add_total_menu",
        })
    )

    local vis = (type(get_danmaku_visibility) == "function" and get_danmaku_visibility())
    mp.commandv("script-message-to", "uosc", "set", "show_danmaku", vis and "on" or "off")
end

register_danmaku_uosc_buttons()
mp.add_timeout(0.5, register_danmaku_uosc_buttons)

mp.register_script_message('uosc-version', function()
    uosc_available = true
    register_danmaku_uosc_buttons()
end)
mp.register_script_message("set", function(prop, value)
    if prop ~= "show_danmaku" then
        return
    end

    if value == "on" then
        ENABLED = true
        if COMMENTS == nil then
            set_danmaku_visibility(true)
            local path = mp.get_property("path")
            init(path)
        else
            show_loaded()
            show_danmaku_func()
        end
    else
        show_message("关闭弹幕", 2)
        ENABLED = false
        hide_danmaku_func()
    end

    mp.commandv("script-message-to", "uosc", "set", "show_danmaku", value)
end)

-- 注册函数给 uosc 按钮使用
mp.register_script_message("search-anime-event", function(query)
    if uosc_available then
        mp.commandv("script-message-to", "uosc", "close-menu", "menu_danmaku")
    end
    local name, class = query:match("^(.-)%s*|%s*(.-)%s*$")
    if name and class then
        query_extra(name, class)
    else
        get_animes(query)
    end
end)
mp.register_script_message("search-episodes-event", function(animeTitle, bangumiId)
    if uosc_available then
        mp.commandv("script-message-to", "uosc", "close-menu", "menu_anime")
    end
    get_episodes(animeTitle, bangumiId)
end)

-- Register script message to show the input menu
mp.register_script_message("load-danmaku", function(animeTitle, episodeTitle, episodeId)
    ENABLED = true
    DANMAKU.anime = animeTitle
    DANMAKU.episode = episodeTitle
    set_episode_id(episodeId, true)
end)

mp.register_script_message("add-source-event", function(query)
    if uosc_available then
        mp.commandv("script-message-to", "uosc", "close-menu", "menu_source")
    end
    ENABLED = true
    add_danmaku_source(query, true)
end)

mp.register_script_message("open_danmaku_style_menu", function()
    if uosc_available then
        mp.commandv("script-message-to", "uosc", "close-menu", "menu_total")
    end
    open_style_menu()
end)

mp.register_script_message("open_content_danmaku_menu", function()
    if uosc_available then
        mp.commandv("script-message-to", "uosc", "close-menu", "menu_total")
    end
    open_content_menu()
end)

mp.register_script_message("open-latest-menu-anime", function ()
    if uosc_available then
        mp.commandv("script-message-to", "uosc", "open-menu", latest_menu_anime)
    elseif input_loaded then
        show_message("", 0)
        mp.add_timeout(0.1, function()
            open_menu_select(utils.parse_json(latest_menu_anime))
        end)
    end
end)

local REBUILD_STYLE_KEYS = {
    fontsize = true,
    scrolltime = true,
    fixtime = true,
    max_screen_danmaku = true,
    merge_tolerance = true,
    chConvert = true,
}

local function apply_danmaku_style_change(need_rebuild, toast)
    if type(save_danmaku_style) == "function" then
        save_danmaku_style()
    end
    if ENABLED and COMMENTS ~= nil then
        if need_rebuild and type(convert_danmaku_to_ass_events) == "function" then
            convert_danmaku_to_ass_events(true)
        end
        if type(render) == "function" then
            render()
        end
    end
    if toast then
        mp.osd_message(toast, 1.8)
    end
    if uosc_available then
        open_style_menu_uosc(nil, "update")
    end
end

mp.register_script_message("dm-style-set", function(key, val)
    if not key then return end
    if key == "fontname" then
        options[key] = tostring(val)
    elseif key == "bold" or key == "block_top" or key == "block_bottom" or key == "block_scroll" or key == "block_color" then
        options[key] = (val == "true" or val == "yes" or val == "1")
    else
        local num = tonumber(val)
        if not num then return end
        options[key] = num
    end
    apply_danmaku_style_change(REBUILD_STYLE_KEYS[key] == true)
end)

mp.register_script_message("dm-style-step", function(key, delta_str, min_str, max_str)
    local delta = tonumber(delta_str)
    local min_v = tonumber(min_str)
    local max_v = tonumber(max_str)
    if not key or not delta then return end
    local cur = tonumber(options[key]) or 0
    local nxt = cur + delta
    if min_v and nxt < min_v then nxt = min_v end
    if max_v and nxt > max_v then nxt = max_v end
    -- Keep clean rounding for decimals vs integers
    if math.abs(delta) < 1 then
        nxt = math.floor(nxt * 100 + 0.5) / 100
    else
        nxt = math.floor(nxt + 0.5)
    end
    options[key] = nxt
    apply_danmaku_style_change(REBUILD_STYLE_KEYS[key] == true)
end)

mp.register_script_message("dm-style-toggle", function(key)
    if not key then return end
    options[key] = not (options[key] == true)
    apply_danmaku_style_change(false)
end)

mp.register_script_message("dm-style-preset", function(preset_id)
    for _, p in ipairs(DANMAKU_STYLE_PRESETS) do
        if p.id == preset_id then
            for k, v in pairs(p.values) do
                options[k] = v
            end
            apply_danmaku_style_change(true, "已切换弹幕风格：" .. p.title .. "（已记住）")
            return
        end
    end
end)

mp.register_script_message("dm-style-reset", function()
    if type(DANMAKU_STYLE_DEFAULTS) == "table" then
        for k, v in pairs(DANMAKU_STYLE_DEFAULTS) do
            options[k] = v
        end
    end
    apply_danmaku_style_change(true, "已恢复默认弹幕样式")
end)

mp.register_script_message("setup-danmaku-style", function(query, text)
    local event = utils.parse_json(query)
    if event ~= nil then
        -- item点击 或 图标点击
        if event.type == "activate" then
            if not event.action then
                if ordered_keys[event.index] == "bold" then
                    options.bold = not options.bold
                    menu_items_config.bold.hint = options.bold and "true" or "false"
                end
                -- "updata" 模式会保留输入框文字
                open_style_menu(ordered_keys[event.index], "updata")
                return
            else
                -- msg.info("event.action：" .. event.action)
                options[event.action] = menu_items_config[event.action]["original"]
                menu_items_config[event.action]["hint"] = options[event.action]
                open_style_menu(event.action, "updata")
                if event.action == "fontsize" or event.action == "scrolltime" then
                    load_danmaku(true)
                end
            end
        end
    else
        -- 数值输入
        if text == nil or text == "" then
            return
        end
        local newText, _ = text:gsub("%s", "") -- 移除所有空白字符
        if tonumber(newText) ~= nil and menu_items_config[query]["scope"] ~= nil then
            local num = tonumber(newText)
            local min_num = menu_items_config[query]["scope"]["min"]
            local max_num = menu_items_config[query]["scope"]["max"]
            if num and min_num <= num and num <= max_num then
                if string.match(menu_items_config[query]["footnote"], "整数") then
                    -- 输入范围为整数时向下取整
                    num = tostring(math.floor(num))
                end
                options[query] = tostring(num)
                menu_items_config[query]["hint"] = options[query]
                -- "refresh" 模式会清除输入框文字
                open_style_menu(query, "refresh")
                if query == "fontsize" or query == "scrolltime" then
                    load_danmaku(true, true)
                end
                return
            end
        end
        open_style_menu(query, "error")
    end
end)

mp.register_script_message('setup-danmaku-source', function(json)
    local event = utils.parse_json(json)
    if event.type == 'activate' then

        if event.action == "delete" then
            DANMAKU.sources[event.value] = nil
            remove_source_from_history(event.value)
            mp.commandv("script-message-to", "uosc", "close-menu", "menu_source")
            open_add_menu()
            load_danmaku(true)
        end

        if event.action == "block" then
            DANMAKU.sources[event.value]["blocked"] = true
            add_source_to_history(event.value, DANMAKU.sources[event.value])
            mp.commandv("script-message-to", "uosc", "close-menu", "menu_source")
            open_add_menu()
            load_danmaku(true)
        end

        if event.action == "unblock" then
            DANMAKU.sources[event.value]["blocked"] = false
            add_source_to_history(event.value, DANMAKU.sources[event.value])
            mp.commandv("script-message-to", "uosc", "close-menu", "menu_source")
            open_add_menu()
            load_danmaku(true)
        end
    end
end)

mp.register_script_message("setup-source-delay", function(query, text)
    local event = utils.parse_json(query)
    if event ~= nil then
        -- item点击
        if event.type == "activate" then
            open_delay_menu(event.value)
        end
    else
        -- 数值输入
        if text == nil or text == "" then
            return
        end
        local delay = parse_delay_input(text)
        if delay ~= nil then
            mp.commandv("script-message", "danmaku-delay", tostring(delay), "0")
            mp.commandv("script-message-to", "uosc", "close-menu", "menu_delay")
            mp.add_timeout(0.1, function()
                open_delay_menu(query, "refresh")
            end)
        else
            open_delay_menu(query, "error")
        end
    end
end)

mp.register_script_message('handle-danmaku-content-action', function(json)
    local event = utils.parse_json(json)
    if not event or event.type ~= 'activate' then return end

    if event.action then
        local d = COMMENTS[event.index]
        if not d or not d.source then return end

        if event.action == "block_source" then
            DANMAKU.sources[d.source]["blocked"] = true
            add_source_to_history(d.source, DANMAKU.sources[d.source])
            mp.commandv("script-message-to", "uosc", "close-menu", "menu_content")
            load_danmaku(true)
        elseif event.action == "adjust_delay" then
            -- 打开以该弹幕时间为起点的延迟菜单（该延迟将作用于该时间点及之后的弹幕），仅针对该条弹幕的 source
            mp.commandv("script-message", "open_content_delay_menu", d.source, tostring(d.start_time))
        end
    else
        if event.value then
            if type(event.value) == "table" then
                mp.commandv(unpack(event.value))
            else
                mp.command(event.value)
            end
            mp.commandv("script-message-to", "uosc", "close-menu", "menu_content")
        end
    end
end)

mp.register_script_message("open_content_delay_menu", function(source, time)
    open_delay_from_time(source, tonumber(time))
end)

mp.register_script_message("setup-content-delay", function(...)
    local args = {...}
    if #args == 1 then
        return
    end
    if #args >= 2 then
        local time = tonumber(args[1])
        local source = args[2]
        local delay_str = args[3]
        local delay = parse_delay_input(delay_str)
        if delay ~= nil then
            mp.commandv("script-message", "danmaku-delay", tostring(delay), tostring(time), tostring(source))
            mp.commandv("script-message-to", "uosc", "close-menu", "menu_delay_from_time")
        else
            open_delay_from_time(source, tonumber(time), "error")
        end
    end
end)
