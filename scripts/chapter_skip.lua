--[[
    智能章节 OP / ED 跳过助手（柔雾瓷白右下角交互胶囊 + uosc 菜单设置）
    - 利用视频内嵌章节标注（OP / Opening / 片头 / ED / Ending / 片尾 / 预告 等）精准识别片头片尾
    - 三种模式可自由切换并自动持久化到 ~~/saved-chapter-skip.json：
        1. prompt（默认）：播放到 OP / ED 时在画面右下角浮现瓷白跳过胶囊，点击或按 S 跳过，点 × 或按 Esc 忽略
        2. auto          ：进入 OP / ED 时自动跳过（5 秒内按 Alt+Backspace 可退回）
        3. off           ：完全关闭跳过与提示
    - 快捷键：S 跳过当前 OP/ED · Shift+S 打开跳过设置菜单 · Alt+BS 撤销刚执行的自动跳过
    - 控制栏按钮：button:chapter_skip
]]

local mp = require("mp")
local utils = require("mp.utils")
local assdraw = require("mp.assdraw")
local msg = require("mp.msg")

local STATE_PATH = mp.command_native({"expand-path", "~~/saved-chapter-skip.json"})

local config = {
    mode = "prompt",       -- "prompt" | "auto" | "off"
    skip_op = true,
    skip_ed = true,
    skip_preview = false,
    ed_next_episode = false, -- true: 片尾最后一章直接切下一集；false: 跳至结尾以便触发 Bangumi 同步
}

local runtime = {
    chapters = {},          -- detected OP/ED/Preview map: [index] = { kind, label, start_t, end_t, is_last, raw_title }
    detected_list = {},     -- ordered summary list
    handled = {},           -- [chapter_index] = true (skipped or dismissed during this file)
    active_chap = nil,      -- currently prompted chapter record
    prompt_visible = false,
    prompt_opacity = 0,
    hover_zone = nil,       -- "skip" | "close" | nil
    skip_rect = nil,
    close_rect = nil,
    osd_w = 1280,
    osd_h = 720,
    mouse_x = -1,
    mouse_y = -1,
    click_bound = false,
    key_bound = false,
    undo_info = nil,        -- { from_time, label, expire }
    hide_timer = nil,
    fade_timer = nil,
}

local overlay = mp.create_osd_overlay("ass-events")
overlay.z = 2100

-- Soft Porcelain palette (ASS BGR hex)
local C_BG = "FAF6F4"       -- #F4F6FA porcelain white
local C_BGT = "3B291E"      -- #1E293B deep slate ink
local C_FG = "B87835"       -- #3578B8 serene cerulean
local C_FGT = "FFFFFF"      -- #FFFFFF crisp white
local C_MUTED = "8B7464"    -- #64748B slate muted
local C_CLOSE = "5D45D6"    -- #D6455D muted coral hover
local C_SHADOW = "000000"   -- pure dark drop shadow
local C_SH_MULT = 1.0

local function load_config()
    local f = io.open(STATE_PATH, "rb")
    if not f then return end
    local raw = f:read("*a")
    f:close()
    local parsed = raw and utils.parse_json(raw)
    if type(parsed) ~= "table" then return end
    if parsed.mode == "prompt" or parsed.mode == "auto" or parsed.mode == "off" then
        config.mode = parsed.mode
    end
    if type(parsed.skip_op) == "boolean" then config.skip_op = parsed.skip_op end
    if type(parsed.skip_ed) == "boolean" then config.skip_ed = parsed.skip_ed end
    if type(parsed.skip_preview) == "boolean" then config.skip_preview = parsed.skip_preview end
    if type(parsed.ed_next_episode) == "boolean" then config.ed_next_episode = parsed.ed_next_episode end
end

local function save_config()
    local f = io.open(STATE_PATH, "wb")
    if not f then return end
    f:write(utils.format_json(config) or "{}")
    f:close()
end

local function fmt_time(sec)
    sec = math.max(0, math.floor((sec or 0) + 0.5))
    local m = math.floor(sec / 60)
    local s = sec % 60
    return string.format("%02d:%02d", m, s)
end

local function classify_chapter(title, start_t, end_t, duration)
    if not title or title == "" then return nil end
    local seg_dur = end_t - start_t
    -- OP/ED chapters are typically 15s ~ 240s; guard against mis-tagged full episodes
    if seg_dur < 15 or seg_dur > 240 then return nil end
    if duration > 0 and seg_dur > duration * 0.45 then return nil end

    local trimmed = title:gsub("^%s+", ""):gsub("%s+$", "")
    local low = trimmed:lower()

    -- Check Preview / Next Episode first
    local is_preview =
        low:find("preview", 1, true)
        or low:find("next%s+episode")
        or low:find("next%s+ep")
        or trimmed:find("预告", 1, true)
        or trimmed:find("預告", 1, true)
        or trimmed:find("次回", 1, true)
    if is_preview then
        if duration <= 0 or start_t >= duration * 0.55 then
            return "preview", "预告"
        end
    end

    -- Check OP (Opening)
    local is_op =
        low:match("^op$")
        or low:match("^op[%s%d._%-:]+$")
        or low:match("^op%d*%s*[%-(（【]")
        or low:match("%f[%a]opening%f[%A]")
        or low:match("%f[%a]intro%f[%A]")
        or low:match("%f[%a]title%s*sequence%f[%A]")
        or low:match("^ncop")
        or trimmed:find("片头", 1, true)
        or trimmed:find("片頭", 1, true)
        or trimmed:find("主题曲", 1, true)
        or trimmed:find("主題曲", 1, true)
        or trimmed:find("オープニング", 1, true)
    if is_op then
        if duration <= 0 or start_t <= duration * 0.55 then
            return "op", "片头 (OP)"
        end
    end

    -- Check ED (Ending)
    local is_ed =
        low:match("^ed$")
        or low:match("^ed[%s%d._%-:]+$")
        or low:match("^ed%d*%s*[%-(（【]")
        or low:match("%f[%a]ending%f[%A]")
        or low:match("%f[%a]outro%f[%A]")
        or low:match("%f[%a]credits?%f[%A]")
        or low:match("%f[%a]closing%f[%A]")
        or low:match("^nced")
        or trimmed:find("片尾", 1, true)
        or trimmed:find("职员表", 1, true)
        or trimmed:find("職員表", 1, true)
        or trimmed:find("エンディング", 1, true)
    if is_ed then
        if duration <= 0 or start_t >= duration * 0.40 then
            return "ed", "片尾 (ED)"
        end
    end

    return nil
end

local function is_kind_enabled(kind)
    if kind == "op" then return config.skip_op end
    if kind == "ed" then return config.skip_ed end
    if kind == "preview" then return config.skip_preview end
    return false
end

local function mode_label(m)
    if m == "auto" then return "自动跳过" end
    if m == "off" then return "关闭" end
    return "提示询问"
end

local function update_uosc_button()
    local active = false
    local badge = nil
    local tooltip = "跳过 OP/ED · " .. mode_label(config.mode)

    if runtime.active_chap and runtime.prompt_visible then
        active = true
        badge = runtime.active_chap.kind == "op" and "OP" or (runtime.active_chap.kind == "ed" and "ED" or "预告")
        tooltip = "按 S 跳过" .. runtime.active_chap.label
    elseif config.mode == "auto" then
        active = true
        badge = "AUTO"
    elseif config.mode == "prompt" and #runtime.detected_list > 0 then
        badge = tostring(#runtime.detected_list)
        tooltip = string.format("跳过 OP/ED · %d 段", #runtime.detected_list)
    end

    mp.commandv("script-message-to", "uosc", "set-button", "chapter_skip", utils.format_json({
        icon = config.mode == "off" and "skip_next" or "fast_forward",
        active = active,
        badge = badge,
        tooltip = tooltip,
        command = "script-message-to chapter_skip open-menu",
    }))
end

local function unbind_click()
    if runtime.click_bound then
        mp.disable_key_bindings("chapter_skip_click")
        runtime.click_bound = false
    end
end

local function unbind_prompt_keys()
    if runtime.key_bound then
        mp.remove_key_binding("chapter-skip-esc")
        runtime.key_bound = false
    end
end

local function clear_overlay()
    overlay:remove()
    runtime.skip_rect = nil
    runtime.close_rect = nil
    runtime.hover_zone = nil
    unbind_click()
    unbind_prompt_keys()
end

local function hide_prompt(instant)
    if runtime.hide_timer then
        runtime.hide_timer:kill()
        runtime.hide_timer = nil
    end
    if runtime.fade_timer then
        runtime.fade_timer:kill()
        runtime.fade_timer = nil
    end
    runtime.prompt_visible = false
    if instant or runtime.prompt_opacity <= 0.05 then
        runtime.prompt_opacity = 0
        clear_overlay()
        update_uosc_button()
        return
    end
    -- Smooth fade-out
    local start_op = runtime.prompt_opacity
    local t0 = mp.get_time()
    local dur = 0.18
    runtime.fade_timer = mp.add_periodic_timer(0.016, function()
        local p = math.min((mp.get_time() - t0) / dur, 1)
        runtime.prompt_opacity = start_op * (1 - p) ^ 2
        if p >= 1 then
            runtime.fade_timer:kill()
            runtime.fade_timer = nil
            runtime.prompt_opacity = 0
            clear_overlay()
            update_uosc_button()
        else
            -- redraw fading
            local _ = render_prompt and render_prompt()
        end
    end)
end

local function alpha_hex(opacity)
    local a = 255 - math.floor(math.max(0, math.min(1, opacity)) * 255 + 0.5)
    return string.format("%02X", a)
end

local function draw_round_rect(ass, ax, ay, bx, by, r, color, opacity, border, border_color, border_opacity)
    ass:new_event()
    local tags = string.format("\\pos(0,0)\\rDefault\\an7\\blur0\\bord%s\\1c&H%s&\\1a&H%s&",
        tostring(border or 0), color, alpha_hex(opacity))
    if border and border > 0 then
        tags = tags .. string.format("\\3c&H%s&\\3a&H%s&", border_color or C_BGT, alpha_hex(border_opacity or opacity))
    end
    ass:append("{" .. tags .. "}")
    ass:draw_start()
    ass:round_rect_cw(ax, ay, bx, by, r)
    ass:draw_stop()
end

local cached_ui_font = mp.get_property("osd-font") or "Microsoft YaHei UI"
mp.observe_property("osd-font", "string", function(_, v)
    if v and v ~= "" then cached_ui_font = v end
end)

local function draw_text(ass, x, y, align, text, size, color, opacity, bold, font)
    ass:new_event()
    local ui_font = font or cached_ui_font
    local tags = string.format("\\pos(%.1f,%.1f)\\rDefault\\an%d\\blur0\\bord0\\shad0\\fn%s\\fs%d\\1c&H%s&\\alpha&H%s&%s",
        x, y, align, ui_font, size, color, alpha_hex(opacity), bold and "\\b1" or "")
    ass:append("{" .. tags .. "}" .. text)
end

function render_prompt()
    local chap = runtime.active_chap
    local op = runtime.prompt_opacity
    if not chap or op <= 0.01 then
        clear_overlay()
        return
    end

    local w, h = runtime.osd_w, runtime.osd_h
    if w <= 0 or h <= 0 then return end
    local scale = math.max(0.85, math.min(1.45, h / 720))

    local pill_w = math.floor(276 * scale)
    local pill_h = math.floor(50 * scale)
    local margin_r = math.floor(24 * scale)
    -- Positioned neatly in the clean gap between the floating controls dock and volume button
    local margin_b = math.floor(128 * scale)
    local radius = math.floor(12 * scale)

    local bx = w - margin_r
    local ax = bx - pill_w
    local by = h - margin_b
    local ay = by - pill_h

    local close_w = math.floor(38 * scale)
    local split_x = bx - close_w

    runtime.skip_rect = { ax = ax, ay = ay, bx = split_x, by = by }
    runtime.close_rect = { ax = split_x, ay = ay, bx = bx, by = by }

    local is_skip_hover = (runtime.hover_zone == "skip")
    local is_close_hover = (runtime.hover_zone == "close")

    local ass = assdraw.ass_new()

    -- Soft layered elevation shadow
    draw_round_rect(ass, ax - 1, ay + math.floor(4 * scale), bx + 1, by + math.floor(6 * scale),
        radius + 1, C_SHADOW, math.min(0.45, op * 0.12 * C_SH_MULT), 0)
    draw_round_rect(ass, ax, ay + math.floor(2 * scale), bx, by + math.floor(3 * scale),
        radius, C_SHADOW, math.min(0.45, op * 0.10 * C_SH_MULT), 0)

    -- Main frosted porcelain pill body (borderless smooth fill)
    local main_bg = is_skip_hover and C_FG or C_BG
    draw_round_rect(ass, ax, ay, bx, by, radius, main_bg, op * 0.96, 0)

    -- Left accent icon circle / tag pill
    local badge_pad = math.floor(10 * scale)
    local badge_size = pill_h - badge_pad * 2
    local badge_ax = ax + badge_pad
    local badge_ay = ay + badge_pad
    draw_round_rect(ass, badge_ax, badge_ay, badge_ax + badge_size, badge_ay + badge_size,
        math.floor(9 * scale), is_skip_hover and C_BG or C_FG, op * 0.96, 0)
    draw_text(ass, badge_ax + badge_size / 2, badge_ay + badge_size / 2, 5, "fast_forward",
        math.floor(badge_size * 0.62), is_skip_hover and C_FG or C_FGT, op, false, "MaterialIconsRound-Regular")

    -- Text stack
    local text_x = badge_ax + badge_size + math.floor(11 * scale)
    local primary_label = "跳过" .. chap.label
    local sub_label = "S 跳过 · Esc 忽略"
    draw_text(ass, text_x, ay + math.floor(pill_h * 0.34), 4, primary_label,
        math.floor(16.5 * scale), is_skip_hover and C_FGT or C_BGT, op, true)
    draw_text(ass, text_x, ay + math.floor(pill_h * 0.72), 4, sub_label,
        math.floor(11.5 * scale), is_skip_hover and C_FGT or C_MUTED, op * (is_skip_hover and 0.90 or 0.85), false)

    -- Subtle vertical divider before close button
    ass:new_event()
    ass:append(string.format("{\\pos(0,0)\\rDefault\\an7\\blur0\\bord0\\1c&H%s&\\1a&H%s&}",
        is_skip_hover and C_FGT or C_BGT, alpha_hex(op * 0.14)))
    ass:draw_start()
    ass:rect_cw(split_x, ay + math.floor(11 * scale), split_x + 1, by - math.floor(11 * scale))
    ass:draw_stop()

    -- Right close × hover highlight & glyph
    if is_close_hover then
        draw_round_rect(ass, split_x + math.floor(4 * scale), ay + math.floor(6 * scale),
            bx - math.floor(6 * scale), by - math.floor(6 * scale),
            math.floor(8 * scale), C_CLOSE, op * 0.92, 0)
    end
    draw_text(ass, split_x + close_w / 2 - math.floor(1 * scale), ay + pill_h / 2, 5, "close",
        math.floor(16 * scale), is_close_hover and "FFFFFF" or (is_skip_hover and C_FGT or C_MUTED),
        op * (is_close_hover and 1 or 0.85), false, "MaterialIconsRound-Regular")

    overlay.res_x = w
    overlay.res_y = h
    overlay.data = ass.text
    overlay:update()
end

local function perform_skip(chap, is_auto)
    if not chap then return false end
    local cur_pos = mp.get_property_number("time-pos", 0)
    local duration = mp.get_property_number("duration", 0)
    runtime.handled[chap.index] = true
    hide_prompt(true)

    local did_next = false
    if chap.is_last and chap.kind ~= "op" and config.ed_next_episode then
        local pl_pos = mp.get_property_number("playlist-pos", 0)
        local pl_cnt = mp.get_property_number("playlist-count", 0)
        if pl_cnt > 1 and pl_pos + 1 < pl_cnt then
            mp.command("playlist-next")
            did_next = true
        end
    end

    if not did_next then
        local target = chap.end_t
        if chap.is_last and duration > 0 then
            -- Land right near the end so Bangumi sync / keep-open behaves naturally
            target = math.max(chap.start_t + 1, duration - 1.5)
        end
        mp.commandv("seek", tostring(target), "absolute+exact")
    end

    if is_auto then
        runtime.undo_info = {
            from_time = cur_pos,
            label = chap.label,
            expire = mp.get_time() + 6.0,
        }
        mp.osd_message("已跳过" .. chap.label .. "（Alt+BS 撤销）", 2.5)
    else
        mp.osd_message("已跳过" .. chap.label, 1.5)
    end
    update_uosc_button()
    return true
end

local function dismiss_current_prompt()
    if runtime.active_chap then
        runtime.handled[runtime.active_chap.index] = true
    end
    hide_prompt(false)
end

local function handle_pill_click()
    if not runtime.prompt_visible or not runtime.active_chap then return end
    if runtime.hover_zone == "close" then
        dismiss_current_prompt()
    elseif runtime.hover_zone == "skip" then
        perform_skip(runtime.active_chap, false)
    end
end

local function point_in_rect(x, y, r)
    return r and x >= r.ax and x <= r.bx and y >= r.ay and y <= r.by
end

mp.set_key_bindings({
    { "MBTN_LEFT", function() end, handle_pill_click },
    { "MBTN_LEFT_DBL", function() end },
}, "chapter_skip_click", "force")

local function update_hover(mx, my)
    if not runtime.prompt_visible then
        unbind_click()
        return
    end
    local zone = nil
    if point_in_rect(mx, my, runtime.close_rect) then
        zone = "close"
    elseif point_in_rect(mx, my, runtime.skip_rect) then
        zone = "skip"
    end

    if zone ~= nil and not runtime.click_bound then
        mp.enable_key_bindings("chapter_skip_click", "")
        runtime.click_bound = true
    elseif zone == nil and runtime.click_bound then
        unbind_click()
    end

    if zone ~= runtime.hover_zone then
        runtime.hover_zone = zone
        render_prompt()
    end
end

local function show_prompt(chap)
    runtime.active_chap = chap
    runtime.prompt_visible = true

    if runtime.hide_timer then runtime.hide_timer:kill() end
    if runtime.fade_timer then runtime.fade_timer:kill() end

    if not runtime.key_bound then
        mp.add_forced_key_binding("ESC", "chapter-skip-esc", dismiss_current_prompt)
        runtime.key_bound = true
    end

    -- Smooth OutCubic fade-in
    local t0 = mp.get_time()
    local dur = 0.22
    runtime.prompt_opacity = 0.05
    render_prompt()
    runtime.fade_timer = mp.add_periodic_timer(0.016, function()
        local p = math.min((mp.get_time() - t0) / dur, 1)
        runtime.prompt_opacity = 1 - (1 - p) ^ 3
        render_prompt()
        if p >= 1 then
            runtime.fade_timer:kill()
            runtime.fade_timer = nil
            update_hover(runtime.mouse_x, runtime.mouse_y)
        end
    end)

    -- Auto-hide prompt after 14s so it doesn't linger forever if user wants to watch OP/ED
    runtime.hide_timer = mp.add_timeout(14.0, function()
        if runtime.prompt_visible then
            hide_prompt(false)
        end
    end)

    update_uosc_button()
end

local function rebuild_chapters()
    runtime.chapters = {}
    runtime.detected_list = {}
    local raw_list = mp.get_property_native("chapter-list") or {}
    local duration = mp.get_property_number("duration", 0)
    if #raw_list == 0 then
        update_uosc_button()
        return
    end

    for i, ch in ipairs(raw_list) do
        local start_t = tonumber(ch.time) or 0
        local next_ch = raw_list[i + 1]
        local end_t = next_ch and (tonumber(next_ch.time) or duration) or duration
        local kind, label = classify_chapter(ch.title, start_t, end_t, duration)
        if kind then
            local rec = {
                index = i - 1, -- mpv `chapter` property is 0-based
                kind = kind,
                label = label,
                raw_title = ch.title or "",
                start_t = start_t,
                end_t = end_t,
                is_last = (i == #raw_list),
            }
            runtime.chapters[rec.index] = rec
            table.insert(runtime.detected_list, rec)
        end
    end

    if #runtime.detected_list > 0 then
        local parts = {}
        for _, rec in ipairs(runtime.detected_list) do
            table.insert(parts, string.format("%s (%s–%s)", rec.label, fmt_time(rec.start_t), fmt_time(rec.end_t)))
        end
        msg.info("已识别章节标注: " .. table.concat(parts, ", "))
    end
    update_uosc_button()
end

local function check_current_chapter()
    if config.mode == "off" then
        if runtime.prompt_visible then hide_prompt(true) end
        return
    end
    local chap_idx = mp.get_property_number("chapter", -1)
    local rec = runtime.chapters[chap_idx]
    if not rec or not is_kind_enabled(rec.kind) then
        if runtime.prompt_visible then hide_prompt(false) end
        runtime.active_chap = nil
        update_uosc_button()
        return
    end

    if runtime.handled[chap_idx] then
        return
    end

    local pos = mp.get_property_number("time-pos", 0)
    -- Don't re-trigger if we are already within 2 seconds of chapter end
    if rec.end_t - pos < 2.0 then
        return
    end

    if config.mode == "auto" then
        perform_skip(rec, true)
    elseif config.mode == "prompt" then
        if not runtime.prompt_visible or runtime.active_chap ~= rec then
            show_prompt(rec)
        end
    end
end

local function open_settings_menu(action)
    local items = {}

    -- Detected summary banner
    if #runtime.detected_list > 0 then
        local parts = {}
        for _, rec in ipairs(runtime.detected_list) do
            table.insert(parts, string.format("%s %s–%s", rec.label, fmt_time(rec.start_t), fmt_time(rec.end_t)))
        end
        table.insert(items, {
            title = "已识别：" .. table.concat(parts, " · "),
            icon = "verified",
            selectable = false,
            muted = true,
            separator = true,
        })
    else
        table.insert(items, {
            title = "未检测到 OP / ED 章节",
            icon = "info_outline",
            selectable = false,
            muted = true,
            separator = true,
        })
    end

    -- Immediate skip action if currently inside an OP/ED chapter
    local cur_idx = mp.get_property_number("chapter", -1)
    local cur_rec = runtime.chapters[cur_idx]
    if cur_rec then
        table.insert(items, {
            title = "跳过" .. cur_rec.label,
            hint = "S",
            icon = "fast_forward",
            active = true,
            separator = true,
            value = { "script-message-to", "chapter_skip", "skip-now" },
        })
    end

    -- Mode selection
    local modes = {
        { id = "prompt", title = "提示询问" },
        { id = "auto",   title = "自动跳过" },
        { id = "off",    title = "关闭" },
    }
    for i, m in ipairs(modes) do
        local is_cur = (config.mode == m.id)
        table.insert(items, {
            title = m.title,
            icon = is_cur and "radio_button_checked" or "radio_button_unchecked",
            active = is_cur,
            keep_open = true,
            separator = (i == #modes),
            value = { "script-message-to", "chapter_skip", "set-mode", m.id },
        })
    end

    -- Granular toggles
    local toggles = {
        { key = "skip_op",         title = "跳过片头 (OP)",  val = config.skip_op },
        { key = "skip_ed",         title = "跳过片尾 (ED)",  val = config.skip_ed },
        { key = "skip_preview",    title = "跳过预告",       val = config.skip_preview },
        { key = "ed_next_episode", title = "片尾切下一集",    val = config.ed_next_episode },
    }
    for _, t in ipairs(toggles) do
        table.insert(items, {
            title = t.title,
            hint = t.val and "开" or "关",
            icon = t.val and "check_box" or "check_box_outline_blank",
            active = t.val,
            keep_open = true,
            value = { "script-message-to", "chapter_skip", "toggle", t.key },
        })
    end

    local menu = {
        type = "chapter_skip_menu",
        title = "跳过 OP / ED",
        search_style = "disabled",
        items = items,
    }
    mp.commandv("script-message-to", "uosc", action or "open-menu", utils.format_json(menu))
end

local function skip_now_command()
    local cur_idx = mp.get_property_number("chapter", -1)
    local rec = runtime.chapters[cur_idx] or runtime.active_chap
    if rec then
        perform_skip(rec, false)
    else
        mp.osd_message("当前不在标注的 OP / ED 章节中", 1.8)
    end
end

local function undo_auto_skip()
    if runtime.undo_info and mp.get_time() <= runtime.undo_info.expire then
        local t = runtime.undo_info.from_time
        local lbl = runtime.undo_info.label
        runtime.undo_info = nil
        mp.commandv("seek", tostring(t), "absolute+exact")
        mp.osd_message("↩ 已退回到" .. lbl .. "起点", 2.0)
    end
end

-- Script messages
mp.register_script_message("open-menu", function()
    if mp.get_property_native("user-data/uosc/menu/type") == "chapter_skip_menu" then
        mp.commandv("script-message-to", "uosc", "close-menu")
        return
    end
    open_settings_menu("open-menu")
end)
mp.register_script_message("skip-now", skip_now_command)
mp.register_script_message("undo-skip", undo_auto_skip)

mp.register_script_message("set-mode", function(new_mode)
    if new_mode ~= "prompt" and new_mode ~= "auto" and new_mode ~= "off" then return end
    config.mode = new_mode
    save_config()
    if new_mode == "off" then hide_prompt(true) end
    update_uosc_button()
    open_settings_menu("update-menu")
    mp.osd_message("OP/ED 跳过模式：" .. mode_label(new_mode), 1.8)
end)

mp.register_script_message("toggle", function(key)
    if type(config[key]) ~= "boolean" then return end
    config[key] = not config[key]
    save_config()
    update_uosc_button()
    open_settings_menu("update-menu")
end)

mp.register_script_message("uosc-version", update_uosc_button)

-- Observers & events
mp.observe_property("osd-width", "number", function(_, v)
    if v and v > 0 then runtime.osd_w = v; if runtime.prompt_visible then render_prompt() end end
end)
mp.observe_property("osd-height", "number", function(_, v)
    if v and v > 0 then runtime.osd_h = v; if runtime.prompt_visible then render_prompt() end end
end)
mp.observe_property("user-data/porcelain/theme", "native", function(_, t)
    if type(t) ~= "table" then return end
    if t.bg then C_BG = t.bg end
    if t.bgt then C_BGT = t.bgt end
    if t.fg then C_FG = t.fg end
    if t.fgt then C_FGT = t.fgt end
    if t.muted then C_MUTED = t.muted end
    if t.error then C_CLOSE = t.error end
    if t.shadow then C_SHADOW = t.shadow end
    if type(t.shadow_mult) == "number" then C_SH_MULT = t.shadow_mult end
    if runtime.prompt_visible then render_prompt() end
end)
mp.observe_property("mouse-pos", "native", function(_, pos)
    if type(pos) == "table" and pos.x and pos.y then
        runtime.mouse_x = pos.x
        runtime.mouse_y = pos.y
        update_hover(pos.x, pos.y)
    end
end)
mp.observe_property("chapter-list", "native", function()
    rebuild_chapters()
    check_current_chapter()
end)
mp.observe_property("chapter", "number", function()
    check_current_chapter()
end)
mp.register_event("file-loaded", function()
    runtime.handled = {}
    runtime.active_chap = nil
    runtime.undo_info = nil
    hide_prompt(true)
    rebuild_chapters()
    mp.add_timeout(0.4, check_current_chapter)
end)
mp.register_event("end-file", function()
    runtime.chapters = {}
    runtime.detected_list = {}
    runtime.handled = {}
    runtime.active_chap = nil
    hide_prompt(true)
    update_uosc_button()
end)

-- Init
load_config()
mp.add_timeout(0.7, update_uosc_button)
