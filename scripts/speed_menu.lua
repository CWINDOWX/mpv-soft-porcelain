--[[
    柔雾瓷白 · 倍速滑块面板（适配 uosc 控制栏独立按钮）
    - 控制栏按钮：button:speed_menu（1.0x 时素雅常驻，非 1.0x 或面板展开时高亮并显示当前倍速角标）
    - 点击就近在控制栏上方弹出紧凑滑块卡片（对数刻度，1.0x 居中，带常用倍速磁吸点）
    - 支持左键实时拖动、滚轮/方向键微调、右键/双击/重置按钮一键恢复 1.0x、Esc 或点击空白处关闭
]]

local mp = require("mp")
local utils = require("mp.utils")
local assdraw = require("mp.assdraw")

-- Soft Porcelain palette (ASS BGR hex)
local C_BG      = "FAF6F4" -- #F4F6FA porcelain card surface
local C_WHITE   = "FFFFFF" -- #FFFFFF elevated chip/thumb
local C_BGT     = "3B291E" -- #1E293B deep slate ink
local C_MUTED   = "8B7464" -- #64748B muted slate
local C_TRACK   = "E1D5CB" -- #CBD5E1 soft slate track
local C_FG      = "B87835" -- #3578B8 serene cerulean accent
local C_FG_SOFT = "F3E6DA" -- #DAE6F3 pale sky tint

local MIN_SPEED = 0.25
local MAX_SPEED = 4.0
local LOG2_MIN  = -2 -- log2(0.25)
local LOG2_SPAN = 4  -- log2(4.0) - log2(0.25)

-- Curated magnetic snap points (log2 scale places 0.25 / 0.5 / 1.0 / 2.0 / 4.0 evenly at 0/25/50/75/100%)
local SNAPS = {
    { val = 0.25, tag = "0.25x", major = true,  radius = 0.022 },
    { val = 0.5,  tag = "0.5x",  major = true,  radius = 0.022 },
    { val = 0.75, tag = nil,     major = false, radius = 0.013 },
    { val = 1.0,  tag = "1.0x",  major = true,  radius = 0.026 },
    { val = 1.25, tag = nil,     major = false, radius = 0.013 },
    { val = 1.5,  tag = nil,     major = false, radius = 0.013 },
    { val = 2.0,  tag = "2.0x",  major = true,  radius = 0.022 },
    { val = 3.0,  tag = nil,     major = false, radius = 0.013 },
    { val = 4.0,  tag = "4.0x",  major = true,  radius = 0.022 },
}

local overlay = mp.create_osd_overlay("ass-events")
overlay.z = 2200

local P = {
    open = false,
    opacity = 0,
    osd_w = 1280,
    osd_h = 720,
    mx = -1,
    my = -1,
    anchor = nil,
    from_controls = false,
    dragging = false,
    hover_id = nil,
    card_rect = nil,
    slider_rect = nil,
    reset_rect = nil,
    fade_timer = nil,
    drag_timer = nil,
    raise_timer = nil,
    keys_bound = false,
    prev_menu_type = nil,
    dock = nil,
    margin_top = 0,
    margin_left = 0,
    margin_right = 0,
    margin_bottom = 0,
    ui_font = mp.get_property("osd-font") or "Microsoft YaHei UI",
    speed = mp.get_property_number("speed", 1) or 1,
}

local function clamp(lo, v, hi)
    return math.max(lo, math.min(hi, v))
end

local function round(v)
    return math.floor(v + 0.5)
end

local function alpha_hex(opacity)
    local a = 255 - round(clamp(0, opacity, 1) * 255)
    return string.format("%02X", a)
end

local function approx(a, b)
    return math.abs((tonumber(a) or 1) - (tonumber(b) or 1)) < 0.005
end

local function fmt_speed(v)
    local s = string.format("%.2f", tonumber(v) or 1)
    s = s:gsub("0+$", ""):gsub("%.$", "")
    if not s:find("%.") then s = s .. ".0" end
    return s .. "x"
end

local function fmt_badge(v)
    local s = string.format("%.2f", tonumber(v) or 1)
    s = s:gsub("0+$", ""):gsub("%.$", "")
    return s .. "x"
end

local function pt_in(x, y, r)
    return r ~= nil and x >= r.ax and x <= r.bx and y >= r.ay and y <= r.by
end

local function val_to_norm(v)
    local safe = clamp(MIN_SPEED, tonumber(v) or 1, MAX_SPEED)
    return clamp(0, (math.log(safe) / math.log(2) - LOG2_MIN) / LOG2_SPAN, 1)
end

local function norm_to_val(t, allow_snap)
    t = clamp(0, t, 1)
    if allow_snap then
        local best_val, best_dist = nil, math.huge
        for _, sp in ipairs(SNAPS) do
            local st = val_to_norm(sp.val)
            local d = math.abs(t - st)
            if d < sp.radius and d < best_dist then
                best_dist = d
                best_val = sp.val
            end
        end
        if best_val ~= nil then
            return best_val
        end
    end
    local raw = 2 ^ (LOG2_MIN + t * LOG2_SPAN)
    local step = (raw >= 2.0) and 0.1 or 0.05
    local quantized = round(raw / step) * step
    return clamp(MIN_SPEED, round(quantized * 100) / 100, MAX_SPEED)
end

local function draw_rrect(ass, ax, ay, bx, by, r, color, opacity)
    ass:new_event()
    local tags = string.format("\\pos(0,0)\\rDefault\\an7\\blur0\\bord0\\1c&H%s&\\1a&H%s&",
        color, alpha_hex(opacity))
    ass:append("{" .. tags .. "}")
    ass:draw_start()
    if r and r > 0 then
        ass:round_rect_cw(ax, ay, bx, by, r)
    else
        ass:rect_cw(ax, ay, bx, by)
    end
    ass:draw_stop()
end

local function draw_circle(ass, cx, cy, r, color, opacity)
    draw_rrect(ass, cx - r, cy - r, cx + r, cy + r, r, color, opacity)
end

local function draw_txt(ass, x, y, align, text, size, color, opacity, bold)
    ass:new_event()
    local tags = string.format("\\pos(%.1f,%.1f)\\rDefault\\an%d\\blur0\\bord0\\shad0\\fn%s\\fs%d\\1c&H%s&\\alpha&H%s&%s",
        x, y, align, P.ui_font, size, color, alpha_hex(opacity), bold and "\\b1" or "")
    ass:append("{" .. tags .. "}" .. text)
end

local function update_uosc_button()
    local spd = P.speed or 1
    local is_custom = not approx(spd, 1.0)
    local label = fmt_badge(spd)

    mp.commandv("script-message-to", "uosc", "set-button", "speed_menu", utils.format_json({
        icon = "speed",
        active = is_custom or P.open,
        badge = is_custom and label or nil,
        tooltip = "倍速 · " .. label,
        command = "script-message-to speed_menu open-menu",
    }))
end

local function render_panel()
    if P.opacity <= 0.01 then
        overlay:remove()
        P.card_rect = nil
        P.slider_rect = nil
        P.reset_rect = nil
        return
    end

    local w, h = P.osd_w, P.osd_h
    if w <= 200 or h <= 160 then return end

    local dock = P.dock
    local scale = (type(dock) == "table" and tonumber(dock.scale))
        or clamp(0.8, math.min(h / 720, w / 1280), 1.35)
    local wb = (type(dock) == "table" and tonumber(dock.wb)) or 0
    local op = P.opacity

    local pad_x = round(18 * scale)
    local pad_top = round(14 * scale)
    local pad_bot = round(13 * scale)
    local header_h = round(24 * scale)
    local gap_y = round(10 * scale)
    local slider_h = round(42 * scale)

    local card_w = math.min(round(328 * scale), w - wb * 2 - round(24 * scale))
    local card_h = pad_top + header_h + gap_y + slider_h + pad_bot

    local top_safe = math.floor(h * P.margin_top) + round(10 * scale)
    local left_safe = math.max(wb, math.floor(w * P.margin_left)) + round(12 * scale)
    local right_safe = math.max(wb, math.floor(w * P.margin_right)) + round(12 * scale)
    local bot_safe = h - math.max(wb, math.floor(h * P.margin_bottom)) - round(12 * scale)

    local ax, ay
    local dock_gap = round(12 * scale)
    if P.from_controls and type(dock) == "table" and tonumber(dock.ay) then
        local btn = type(dock.buttons) == "table" and dock.buttons.speed_menu or nil
        local center_x = (btn and (btn.ax + btn.bx) / 2)
            or (P.anchor and P.anchor.x)
            or (w / 2)
        ax = round(clamp(left_safe, center_x - card_w / 2, math.max(left_safe, w - right_safe - card_w)))
        ay = round(clamp(top_safe, dock.ay - dock_gap - card_h, math.max(top_safe, bot_safe - card_h)))
    elseif P.anchor then
        ax = round(clamp(left_safe, P.anchor.x - card_w / 2, math.max(left_safe, w - right_safe - card_w)))
        local above_y = P.anchor.y - card_h - round(14 * scale)
        if above_y >= top_safe then
            ay = round(above_y)
        else
            ay = round(clamp(top_safe, P.anchor.y + round(14 * scale), math.max(top_safe, bot_safe - card_h)))
        end
    else
        ax = round((w - card_w) / 2)
        local ref_by = (type(dock) == "table" and tonumber(dock.ay)) and (dock.ay - dock_gap) or bot_safe
        ay = round(clamp(top_safe, ref_by - card_h, math.max(top_safe, bot_safe - card_h)))
    end

    local bx = ax + card_w
    local by = ay + card_h
    local card_r = round(14 * scale)

    P.card_rect = { ax = ax, ay = ay, bx = bx, by = by }

    local ass = assdraw.ass_new()

    -- Soft elevation shadow
    draw_rrect(ass, ax - 2, ay + round(5 * scale), bx + 2, by + round(9 * scale), card_r + 2, C_BGT, op * 0.08)
    draw_rrect(ass, ax, ay + round(2 * scale), bx, by + round(4 * scale), card_r, C_BGT, op * 0.10)

    -- Main frosted porcelain card (pure borderless vector fill)
    draw_rrect(ass, ax, ay, bx, by, card_r, C_BG, op * 0.96)

    local cx1 = ax + pad_x
    local cx2 = bx - pad_x
    local y = ay + pad_top

    local spd = P.speed or 1
    local is_custom = not approx(spd, 1.0)
    local norm = val_to_norm(spd)
    local slider_active = P.dragging or (P.hover_id == "slider")

    -- === Header: Title (left) + Live Readout & Reset Chip (right, fixed slots) ===
    local hdr_cy = y + round(header_h / 2)
    draw_txt(ass, cx1, hdr_cy, 4, "倍速", round(14.5 * scale), C_BGT, op, true)

    local rst_w = round(42 * scale)
    local rst_h = round(22 * scale)
    local rst_rect = {
        ax = cx2 - rst_w,
        ay = hdr_cy - round(rst_h / 2),
        bx = cx2,
        by = hdr_cy - round(rst_h / 2) + rst_h,
    }
    P.reset_rect = rst_rect
    local rst_hov = is_custom and (P.hover_id == "reset")
    local rst_bg = rst_hov and C_FG or C_WHITE
    local rst_bg_op = rst_hov and 0.96 or (is_custom and 0.94 or 0.45)
    local rst_fg = rst_hov and C_WHITE or (is_custom and C_BGT or C_MUTED)
    local rst_fg_op = is_custom and 1.0 or 0.45

    draw_rrect(ass, rst_rect.ax, rst_rect.ay, rst_rect.bx, rst_rect.by, round(7 * scale), rst_bg, op * rst_bg_op)
    draw_txt(ass, (rst_rect.ax + rst_rect.bx) / 2, (rst_rect.ay + rst_rect.by) / 2, 5, "重置",
        round(11.5 * scale), rst_fg, op * rst_fg_op, rst_hov)

    local val_x = rst_rect.ax - round(10 * scale)
    local val_color = (is_custom or slider_active) and C_FG or C_BGT
    draw_txt(ass, val_x, hdr_cy, 6, fmt_speed(spd), round(15 * scale), val_color, op, true)

    -- === Slider Track + Magnetic Snap Notches + Thumb ===
    local sy = y + header_h + gap_y
    local track_h = math.max(5, round(6 * scale))
    local thumb_r = round(8.5 * scale)
    local snap_r = math.max(2.6, 3.3 * scale)
    local minor_r = math.max(1.8, 2.2 * scale)

    local tr_ax = cx1 + thumb_r
    local tr_bx = cx2 - thumb_r
    local tr_w = math.max(1, tr_bx - tr_ax)
    local tr_cy = sy + round(13 * scale)
    local tr_ay = tr_cy - math.floor(track_h / 2)
    local tr_by = tr_ay + track_h
    local fill_x = tr_ax + tr_w * norm

    -- Base track
    draw_rrect(ass, tr_ax, tr_ay, tr_bx, tr_by, math.floor(track_h / 2), C_TRACK, op * 0.95)
    -- Active progress fill
    if fill_x > tr_ax + 1 then
        draw_rrect(ass, tr_ax, tr_ay, fill_x, tr_by, math.floor(track_h / 2), C_FG, op * 0.96)
    end

    -- Snap points & major labels
    for _, sp in ipairs(SNAPS) do
        local st = val_to_norm(sp.val)
        local sx = tr_ax + tr_w * st
        local passed = (st <= norm + 0.005)
        local snapped_here = approx(spd, sp.val)

        if sp.major then
            draw_circle(ass, sx, tr_cy, snap_r + 1.1, passed and C_FG or C_MUTED, op * (passed and 0.90 or 0.48))
            draw_circle(ass, sx, tr_cy, math.max(1.6, snap_r - 0.3), C_WHITE, op * 0.98)
            if sp.tag then
                local align = (st <= 0.04) and 7 or ((st >= 0.96) and 9 or 8)
                draw_txt(ass, sx, tr_cy + round(12 * scale), align, sp.tag,
                    round(11 * scale), snapped_here and C_FG or C_MUTED,
                    op * (snapped_here and 1.0 or 0.80), snapped_here)
            end
        else
            draw_circle(ass, sx, tr_cy, minor_r, passed and C_FG_SOFT or C_WHITE, op * (passed and 0.90 or 0.85))
        end
    end

    -- Tactile borderless concentric thumb handle
    local r_now = slider_active and (thumb_r + round(1.5 * scale)) or thumb_r
    local ring_w = math.max(2.2, 2.5 * scale)
    draw_circle(ass, fill_x, tr_cy + 1.2, r_now + 1.4, C_BGT, op * 0.13)
    draw_circle(ass, fill_x, tr_cy, r_now, C_FG, op * (slider_active and 1.0 or 0.95))
    draw_circle(ass, fill_x, tr_cy, math.max(2.5, r_now - ring_w), C_WHITE, op)

    P.slider_rect = {
        ax = cx1 - round(4 * scale),
        ay = sy - round(2 * scale),
        bx = cx2 + round(4 * scale),
        by = by - round(4 * scale),
        tr_ax = tr_ax,
        tr_bx = tr_bx,
    }

    overlay.res_x = w
    overlay.res_y = h
    overlay.data = ass.text
    overlay:update()
end

local function set_speed_value(v)
    local cur = mp.get_property_number("speed", 1) or 1
    v = clamp(MIN_SPEED, round(v * 100) / 100, MAX_SPEED)
    if math.abs(v - cur) > 1e-4 then
        mp.set_property_number("speed", v)
    end
end

local function nudge_speed(dir)
    local cur = mp.get_property_number("speed", 1) or 1
    local step = (cur > 2.0 or (cur >= 2.0 and dir > 0)) and 0.1 or 0.05
    local next_v = round((cur + step * dir) / step) * step
    set_speed_value(next_v)
end

local function update_slider_from_x(mx)
    if not P.slider_rect then return end
    local r = P.slider_rect
    local t = (mx - r.tr_ax) / math.max(1, r.tr_bx - r.tr_ax)
    local nv = norm_to_val(t, true)
    set_speed_value(nv)
end

local function stop_drag_poll()
    if P.drag_timer then
        P.drag_timer:kill()
        P.drag_timer = nil
    end
end

local close_panel

local function on_left_down()
    if not P.open then return end
    local pos = mp.get_property_native("mouse-pos")
    if type(pos) == "table" and pos.x and pos.y then
        P.mx, P.my = pos.x, pos.y
    end

    if not pt_in(P.mx, P.my, P.card_rect) then
        local dock = P.dock
        local in_dock = type(dock) == "table" and pt_in(P.mx, P.my, dock)
        local in_timeline = type(dock) == "table"
            and (pt_in(P.mx, P.my, dock.timeline) or (tonumber(dock.by) and P.my >= dock.by))
        local in_self_btn = in_dock and type(dock.buttons) == "table"
            and pt_in(P.mx, P.my, dock.buttons.speed_menu)
        if (in_dock and not in_self_btn) or in_timeline then
            close_panel(true)
            mp.commandv("script-message-to", "uosc", "click-controls", "speed_menu",
                tostring(P.mx), tostring(P.my))
        else
            close_panel(false)
        end
        return
    end

    if pt_in(P.mx, P.my, P.reset_rect) then
        set_speed_value(1.0)
        render_panel()
        return
    end

    if pt_in(P.mx, P.my, P.slider_rect) then
        P.dragging = true
        update_slider_from_x(P.mx)
        render_panel()
        stop_drag_poll()
        P.drag_timer = mp.add_periodic_timer(1 / 60, function()
            if not P.open or not P.dragging then
                stop_drag_poll()
                return
            end
            local cur = mp.get_property_native("mouse-pos")
            if type(cur) == "table" and cur.x and cur.y then
                P.mx, P.my = cur.x, cur.y
                update_slider_from_x(cur.x)
            end
        end)
    end
end

local function on_left_up()
    stop_drag_poll()
    if not P.open then return end
    if P.dragging then
        P.dragging = false
        render_panel()
    end
end

local function on_left_dbl()
    if not P.open then return end
    if pt_in(P.mx, P.my, P.slider_rect) then
        set_speed_value(1.0)
        render_panel()
    end
end

local function on_right_click()
    if not P.open then return end
    if pt_in(P.mx, P.my, P.card_rect) then
        set_speed_value(1.0)
        render_panel()
    else
        close_panel(false)
    end
end

-- Forced key section with EMPTY flags ("") disables allow-vo-dragging so dragging slides smoothly!
mp.set_key_bindings({
    { "MBTN_LEFT",     on_left_up, on_left_down },
    { "MBTN_LEFT_DBL", on_left_dbl },
    { "MBTN_RIGHT",    on_right_click },
    { "WHEEL_UP",      function() if P.open then nudge_speed(1) end end },
    { "WHEEL_DOWN",    function() if P.open then nudge_speed(-1) end end },
    { "BS",            function() if P.open then set_speed_value(1.0) end end },
    { "ESC",           function() close_panel(false) end },
}, "speed_slider_panel", "force")

local function bind_keys()
    mp.enable_key_bindings("speed_slider_panel", "")
    mp.add_forced_key_binding("LEFT", "speed_slider_left", function() if P.open then nudge_speed(-1) end end, { repeatable = true })
    mp.add_forced_key_binding("RIGHT", "speed_slider_right", function() if P.open then nudge_speed(1) end end, { repeatable = true })
    P.keys_bound = true
end

local function unbind_keys()
    stop_drag_poll()
    if P.raise_timer then P.raise_timer:kill(); P.raise_timer = nil end
    if not P.keys_bound then return end
    mp.disable_key_bindings("speed_slider_panel")
    mp.remove_key_binding("speed_slider_left")
    mp.remove_key_binding("speed_slider_right")
    P.keys_bound = false
end

close_panel = function(instant)
    if not P.open and P.opacity <= 0.01 then return end
    P.open = false
    P.dragging = false
    P.hover_id = nil
    unbind_keys()
    mp.commandv("script-message-to", "uosc", "external-popup", "speed_menu", "false", "false")
    update_uosc_button()

    if P.fade_timer then P.fade_timer:kill(); P.fade_timer = nil end

    if instant or P.opacity <= 0.05 then
        P.opacity = 0
        P.anchor = nil
        P.from_controls = false
        overlay:remove()
        return
    end

    local start_op = P.opacity
    local t0 = mp.get_time()
    P.fade_timer = mp.add_periodic_timer(0.016, function()
        local prog = math.min((mp.get_time() - t0) / 0.14, 1)
        P.opacity = start_op * (1 - prog) ^ 2
        render_panel()
        if prog >= 1 then
            P.fade_timer:kill()
            P.fade_timer = nil
            P.opacity = 0
            P.anchor = nil
            P.from_controls = false
            overlay:remove()
        end
    end)
end

local function open_panel()
    if P.open then
        close_panel(false)
        return
    end

    local pos = mp.get_property_native("mouse-pos")
    if type(pos) == "table" and pos.hover and pos.x and pos.y and pos.x >= 0 and pos.y >= 0 then
        P.mx, P.my = pos.x, pos.y
        P.anchor = { x = pos.x, y = pos.y }
    else
        P.anchor = nil
    end

    local dock = P.dock or mp.get_property_native("user-data/uosc/controls/dock")
    P.dock = dock
    local scale = (type(dock) == "table" and tonumber(dock.scale)) or 1
    P.from_controls = type(dock) == "table" and tonumber(dock.ay) ~= nil
        and (P.anchor == nil or P.anchor.y >= dock.ay - round(24 * scale))

    -- Close any overlapping uosc menu or danmaku style panel
    mp.commandv("script-message-to", "uosc", "close-menu")
    mp.commandv("script-message-to", "uosc_danmaku", "close_danmaku_style_panel")
    mp.commandv("script-message-to", "uosc", "external-popup", "speed_menu", "true", P.from_controls and "true" or "false")

    P.open = true
    P.dragging = false
    P.hover_id = nil
    bind_keys()
    update_uosc_button()

    -- Re-promote key section once after uosc finishes tearing down any prior menu
    if P.raise_timer then P.raise_timer:kill() end
    P.raise_timer = mp.add_timeout(0.06, function()
        P.raise_timer = nil
        if P.open then bind_keys() end
    end)

    if P.fade_timer then P.fade_timer:kill() end
    local t0 = mp.get_time()
    P.opacity = 0.10
    render_panel()
    P.fade_timer = mp.add_periodic_timer(0.016, function()
        local prog = math.min((mp.get_time() - t0) / 0.16, 1)
        P.opacity = 1 - (1 - prog) ^ 3
        render_panel()
        if prog >= 1 then
            P.fade_timer:kill()
            P.fade_timer = nil
        end
    end)
end

-- Script messages
mp.register_script_message("open-menu", open_panel)
mp.register_script_message("toggle", open_panel)
mp.register_script_message("close", function() close_panel(true) end)
mp.register_script_message("uosc-close-popups", function() close_panel(true) end)
mp.register_script_message("uosc-version", update_uosc_button)

-- Observers
mp.observe_property("osd-width", "number", function(_, v)
    if v and v > 0 then P.osd_w = v; if P.open then render_panel() end end
end)
mp.observe_property("osd-height", "number", function(_, v)
    if v and v > 0 then P.osd_h = v; if P.open then render_panel() end end
end)
mp.observe_property("osd-font", "string", function(_, v)
    if v and v ~= "" then P.ui_font = v; if P.open then render_panel() end end
end)
mp.observe_property("user-data/uosc/controls/dock", "native", function(_, v)
    P.dock = v
    if P.open then render_panel() end
end)
mp.observe_property("video-margin-ratio-top", "number", function(_, v)
    P.margin_top = v or 0
    if P.open then render_panel() end
end)
mp.observe_property("video-margin-ratio-left", "number", function(_, v)
    P.margin_left = v or 0
    if P.open then render_panel() end
end)
mp.observe_property("video-margin-ratio-right", "number", function(_, v)
    P.margin_right = v or 0
    if P.open then render_panel() end
end)
mp.observe_property("video-margin-ratio-bottom", "number", function(_, v)
    P.margin_bottom = v or 0
    if P.open then render_panel() end
end)
mp.observe_property("speed", "number", function(_, v)
    P.speed = v or 1
    update_uosc_button()
    if P.open or P.opacity > 0.01 then render_panel() end
end)
mp.observe_property("user-data/uosc/menu/type", "native", function(_, val)
    if P.open and val ~= nil and val ~= "" and val ~= P.prev_menu_type then
        close_panel(true)
    end
    P.prev_menu_type = val
end)
mp.observe_property("mouse-pos", "native", function(_, pos)
    if type(pos) ~= "table" or not pos.x or not pos.y then return end
    P.mx, P.my = pos.x, pos.y
    if not P.open then return end
    if P.dragging then
        update_slider_from_x(P.mx)
        return
    end
    local nid = nil
    if pt_in(P.mx, P.my, P.reset_rect) then
        nid = "reset"
    elseif pt_in(P.mx, P.my, P.slider_rect) then
        nid = "slider"
    end
    if nid ~= P.hover_id then
        P.hover_id = nid
        render_panel()
    end
end)

update_uosc_button()
mp.add_timeout(0.6, update_uosc_button)
