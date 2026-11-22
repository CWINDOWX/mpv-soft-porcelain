--[[
    柔雾瓷白 · 弹幕样式滑块面板（带磁性贴合点 + 实时拖动预览 + 自动保存）
    - 右侧悬浮毛玻璃面板，左侧保留 ~70% 画面供实时观察弹幕效果
    - 支持鼠标点击/拖动滑块（靠近贴合点自动磁吸）、滚轮微调、预设一键切换、开关胶囊与恢复默认
    - 快捷键：Ctrl+Shift+D 打开/关闭 · Esc 或点击空白处关闭
]]

local mp = require("mp")
local assdraw = require("mp.assdraw")

-- Soft Porcelain palette (ASS BGR hex)
local C_BG       = "FAF6F4" -- #F4F6FA porcelain card surface
local C_WHITE    = "FFFFFF" -- #FFFFFF elevated chip/thumb
local C_BGT      = "3B291E" -- #1E293B deep slate ink
local C_MUTED    = "8B7464" -- #64748B muted slate
local C_TRACK    = "E1D5CB" -- #CBD5E1 soft slate track
local C_FG       = "B87835" -- #3578B8 serene cerulean accent
local C_FG_SOFT  = "F3E6DA" -- #DAE6F3 pale sky tint
local C_CLOSE    = "5D45D6" -- #D6455D coral close hover

local panel_overlay = mp.create_osd_overlay("ass-events")
panel_overlay.z = 2200

local P = {
    open = false,
    opacity = 0,
    osd_w = 1280,
    osd_h = 720,
    mx = -1,
    my = -1,
    dragging = nil,      -- slider def currently being dragged
    hover_id = nil,
    card_rect = nil,
    hitboxes = {},       -- list of { id, kind, rect, slider?, on_click?, on_wheel? }
    fade_timer = nil,
    rebuild_timer = nil,
    keys_bound = false,
}

local PRESETS = {
    {
        id = "comfort", label = "清爽",
        values = {
            fontname = "LXGW WenKai Mono Lite", fontsize = 36, opacity = 0.78,
            displayarea = 0.72, scrolltime = 13, fixtime = 5, bold = true,
            outline = 1.0, shadow = 0.5, max_screen_danmaku = 0, merge_tolerance = 5,
            block_top = false, block_bottom = false, block_scroll = false, block_color = false,
        }
    },
    {
        id = "soft", label = "护眼",
        values = {
            fontsize = 32, opacity = 0.50, displayarea = 0.50, scrolltime = 15,
            fixtime = 4, bold = false, outline = 0.8, shadow = 0.4, max_screen_danmaku = 40,
            block_bottom = true,
        }
    },
    {
        id = "large", label = "大字",
        values = {
            fontsize = 46, opacity = 0.88, displayarea = 0.72, scrolltime = 12,
            fixtime = 5, bold = true, outline = 1.6, shadow = 0.9,
        }
    },
    {
        id = "minimal", label = "极简",
        values = {
            fontsize = 30, opacity = 0.62, displayarea = 0.35, scrolltime = 14,
            fixtime = 4, bold = false, outline = 0.8, shadow = 0.4, max_screen_danmaku = 25,
            merge_tolerance = 8, block_top = true, block_bottom = true, block_color = true,
        }
    },
    {
        id = "party", label = "狂欢",
        values = {
            fontsize = 38, opacity = 0.88, displayarea = 0.95, scrolltime = 11,
            fixtime = 5, bold = true, outline = 1.0, shadow = 0.5, max_screen_danmaku = 0,
            merge_tolerance = 3, block_top = false, block_bottom = false, block_scroll = false, block_color = false,
        }
    },
}

local FONTS = {
    { id = "LXGW WenKai Mono Lite", label = "霞鹜文楷" },
    { id = "Microsoft YaHei UI",    label = "微软雅黑" },
    { id = "SimHei",                label = "黑体" },
    { id = "YouYuan",               label = "幼圆" },
}

-- Slider definitions with curated magnetic snap points (贴合点)
-- Note: `scrolltime` uses inverted slider direction so dragging RIGHT = faster!
local SLIDERS = {
    {
        id = "fontsize",
        label = "字体大小",
        min = 20, max = 60, step = 1,
        rebuild = true,
        snaps = {
            { val = 24, tag = "24" },
            { val = 30, tag = "30" },
            { val = 36, tag = "适中" },
            { val = 44, tag = "44" },
            { val = 56, tag = "56" },
        },
        get = function() return tonumber(options.fontsize) or 36 end,
        set = function(v) options.fontsize = math.floor(v + 0.5) end,
        fmt = function(v) return string.format("%d px", math.floor(v + 0.5)) end,
    },
    {
        id = "opacity",
        label = "不透明度",
        min = 0.15, max = 1.00, step = 0.01,
        rebuild = false,
        snaps = {
            { val = 0.30, tag = "30%" },
            { val = 0.45, tag = "护眼" },
            { val = 0.65, tag = "65%" },
            { val = 0.78, tag = "推荐" },
            { val = 1.00, tag = "100%" },
        },
        get = function() return tonumber(options.opacity) or 0.78 end,
        set = function(v) options.opacity = math.floor(v * 100 + 0.5) / 100 end,
        fmt = function(v) return string.format("%d%%", math.floor(v * 100 + 0.5)) end,
    },
    {
        id = "displayarea",
        label = "显示区域",
        min = 0.20, max = 1.00, step = 0.01,
        rebuild = false,
        snaps = {
            { val = 0.25, tag = "顶" },
            { val = 0.50, tag = "半屏" },
            { val = 0.72, tag = "避字幕" },
            { val = 0.85, tag = "85%" },
            { val = 1.00, tag = "全屏" },
        },
        get = function() return tonumber(options.displayarea) or 0.72 end,
        set = function(v) options.displayarea = math.floor(v * 100 + 0.5) / 100 end,
        fmt = function(v)
            local pct = math.floor(v * 100 + 0.5)
            return pct == 72 and "72% 避字幕" or (pct .. "%")
        end,
    },
    {
        id = "scrollspeed",
        label = "滚动速度",
        -- Internal value is scrolltime (seconds); inverted so right = faster!
        min = 6, max = 20, step = 1, inverted = true,
        rebuild = true,
        snaps = {
            { val = 18, tag = "慢" },
            { val = 15, tag = "柔和" },
            { val = 13, tag = "标准" },
            { val = 10, tag = "快" },
            { val = 6,  tag = "飞速" },
        },
        get = function() return tonumber(options.scrolltime) or 13 end,
        set = function(v) options.scrolltime = math.floor(v + 0.5) end,
        fmt = function(v)
            local s = math.floor(v + 0.5)
            local tag = s >= 17 and "慢" or (s >= 14 and "柔和" or (s >= 12 and "标准" or (s >= 9 and "较快" or "极速")))
            return string.format("%s (%ds)", tag, s)
        end,
    },
    {
        id = "outline",
        label = "描边粗细",
        min = 0.0, max = 3.5, step = 0.1,
        rebuild = false,
        snaps = {
            { val = 0.0, tag = "无" },
            { val = 0.5, tag = "细" },
            { val = 1.0, tag = "标准" },
            { val = 1.8, tag = "粗" },
            { val = 2.8, tag = "厚" },
        },
        get = function() return tonumber(options.outline) or 1.0 end,
        set = function(v) options.outline = math.floor(v * 10 + 0.5) / 10 end,
        fmt = function(v) return string.format("%.1f", v) end,
    },
    {
        id = "shadow",
        label = "阴影深度",
        min = 0.0, max = 2.5, step = 0.1,
        rebuild = false,
        snaps = {
            { val = 0.0, tag = "无" },
            { val = 0.5, tag = "轻" },
            { val = 1.2, tag = "中" },
            { val = 2.0, tag = "深" },
        },
        get = function() return tonumber(options.shadow) or 0.5 end,
        set = function(v) options.shadow = math.floor(v * 10 + 0.5) / 10 end,
        fmt = function(v) return string.format("%.1f", v) end,
    },
    {
        id = "density",
        label = "同屏上限",
        -- Map 120 to 0 (unlimited) at the right end!
        min = 15, max = 120, step = 5,
        rebuild = true,
        snaps = {
            { val = 20,  tag = "20" },
            { val = 40,  tag = "40" },
            { val = 60,  tag = "60" },
            { val = 90,  tag = "90" },
            { val = 120, tag = "不限" },
        },
        get = function()
            local m = tonumber(options.max_screen_danmaku) or 0
            return (m <= 0 or m >= 120) and 120 or m
        end,
        set = function(v)
            local n = math.floor(v + 0.5)
            options.max_screen_danmaku = (n >= 118) and 0 or n
        end,
        fmt = function(v)
            local n = math.floor(v + 0.5)
            return n >= 118 and "不限" or (n .. " 条")
        end,
    },
}

local function clamp(lo, v, hi)
    return math.max(lo, math.min(hi, v))
end

local function alpha_hex(opacity)
    local a = 255 - math.floor(clamp(0, opacity, 1) * 255 + 0.5)
    return string.format("%02X", a)
end

local function val_to_norm(slider, v)
    local t = (v - slider.min) / (slider.max - slider.min)
    t = clamp(0, t, 1)
    return slider.inverted and (1 - t) or t
end

local function norm_to_val(slider, t, allow_snap)
    t = clamp(0, t, 1)
    local eff_t = slider.inverted and (1 - t) or t
    local raw = slider.min + eff_t * (slider.max - slider.min)
    -- Magnetic snap to nearby curated snap point (within 3.6% of track width); otherwise nearest integer/step
    if allow_snap and slider.snaps then
        local best_snap, best_dist = nil, 0.036
        for _, sp in ipairs(slider.snaps) do
            local st = val_to_norm(slider, sp.val)
            local d = math.abs(t - st)
            if d < best_dist then
                best_dist = d
                best_snap = sp.val
            end
        end
        if best_snap ~= nil then
            return best_snap
        end
    end
    -- Quantize cleanly to nearest integer / step
    local stepped = slider.min + math.floor((raw - slider.min) / slider.step + 0.5) * slider.step
    return clamp(slider.min, stepped, slider.max)
end

local function schedule_apply(need_rebuild, save_now)
    if ENABLED and COMMENTS ~= nil and type(render) == "function" then
        render()
    end
    if save_now and type(save_danmaku_style) == "function" then
        save_danmaku_style()
    end
    if need_rebuild then
        if P.rebuild_timer then P.rebuild_timer:kill() end
        P.rebuild_timer = mp.add_timeout(0.18, function()
            P.rebuild_timer = nil
            if ENABLED and DANMAKU and DANMAKU.sources and next(DANMAKU.sources) ~= nil then
                if type(convert_danmaku_to_ass_events) == "function" then
                    convert_danmaku_to_ass_events(true)
                end
                if type(render) == "function" then
                    render()
                end
            end
            if type(save_danmaku_style) == "function" then
                save_danmaku_style()
            end
        end)
    end
end

local function draw_rrect(ass, ax, ay, bx, by, r, color, opacity, border, border_color, border_op)
    ass:new_event()
    local tags = string.format("\\pos(0,0)\\rDefault\\an7\\blur0\\bord%s\\1c&H%s&\\1a&H%s&",
        tostring(border or 0), color, alpha_hex(opacity))
    if border and border > 0 then
        tags = tags .. string.format("\\3c&H%s&\\3a&H%s&", border_color or C_BGT, alpha_hex(border_op or opacity))
    end
    ass:append("{" .. tags .. "}")
    ass:draw_start()
    if r and r > 0 then
        ass:round_rect_cw(ax, ay, bx, by, r)
    else
        ass:rect_cw(ax, ay, bx, by)
    end
    ass:draw_stop()
end

local function draw_circle(ass, cx, cy, r, color, opacity, border, border_color, border_op)
    draw_rrect(ass, cx - r, cy - r, cx + r, cy + r, r, color, opacity, border, border_color, border_op)
end

local function draw_txt(ass, x, y, align, text, size, color, opacity, bold, font)
    ass:new_event()
    local tags = string.format("\\pos(%.1f,%.1f)\\rDefault\\an%d\\blur0\\bord0\\shad0\\fn%s\\fs%d\\1c&H%s&\\alpha&H%s&%s",
        x, y, align, font or "LXGW WenKai Mono Lite", size, color, alpha_hex(opacity), bold and "\\b1" or "")
    ass:append("{" .. tags .. "}" .. text)
end

local function pt_in(x, y, r)
    return r and x >= r.ax and x <= r.bx and y >= r.ay and y <= r.by
end

local function render_panel()
    if P.opacity <= 0.01 then
        panel_overlay:remove()
        P.hitboxes = {}
        P.card_rect = nil
        return
    end

    local w, h = P.osd_w, P.osd_h
    if w <= 200 or h <= 200 then return end
    local op = P.opacity
    local scale = clamp(0.76, math.min(h / 740, w / 1180), 1.30)

    local top_safe = math.floor(h * (mp.get_property_number("video-margin-ratio-top", 0) or 0)) + math.floor(14 * scale)
    local bot_safe = math.floor(h * (mp.get_property_number("video-margin-ratio-bottom", 0) or 0)) + math.floor(16 * scale)
    local right_safe = math.floor(w * (mp.get_property_number("video-margin-ratio-right", 0) or 0)) + math.floor(18 * scale)

    local pad = math.floor(18 * scale)
    local card_w = math.floor(386 * scale)
    local header_h = math.floor(42 * scale)
    local preset_h = math.floor(30 * scale)
    local slider_row_h = math.floor(50 * scale)
    local font_row_h = math.floor(30 * scale)
    local toggle_row_h = math.floor(29 * scale)
    local footer_h = math.floor(32 * scale)
    local sec_gap = math.floor(10 * scale)

    local total_h = pad + header_h + sec_gap
        + preset_h + sec_gap
        + (#SLIDERS * slider_row_h) + sec_gap
        + font_row_h + math.floor(8 * scale)
        + (2 * toggle_row_h + math.floor(6 * scale)) + sec_gap
        + footer_h + pad

    -- Scale slightly if window is very short
    local avail_h = h - top_safe - bot_safe
    if total_h > avail_h and avail_h > 300 then
        local shrink = avail_h / total_h
        scale = scale * shrink
        pad = math.floor(18 * scale)
        card_w = math.floor(386 * scale)
        header_h = math.floor(42 * scale)
        preset_h = math.floor(30 * scale)
        slider_row_h = math.floor(50 * scale)
        font_row_h = math.floor(30 * scale)
        toggle_row_h = math.floor(29 * scale)
        footer_h = math.floor(32 * scale)
        sec_gap = math.floor(10 * scale)
        total_h = pad + header_h + sec_gap + preset_h + sec_gap + (#SLIDERS * slider_row_h)
            + sec_gap + font_row_h + math.floor(8 * scale) + (2 * toggle_row_h + math.floor(6 * scale))
            + sec_gap + footer_h + pad
    end

    local left_safe = math.floor(w * (mp.get_property_number("video-margin-ratio-left", 0) or 0)) + math.floor(18 * scale)
    local ax, ay
    if P.anchor then
        local gap_x = math.floor(10 * scale)
        local right_ax = math.floor(P.anchor.x + gap_x)
        local left_ax = math.floor(P.anchor.x - gap_x - card_w)
        -- Right of cursor if room allows; else flip left cleanly
        if right_ax + card_w <= w - right_safe then
            ax = math.max(left_safe, right_ax)
        elseif left_ax >= left_safe then
            ax = math.min(w - right_safe - card_w, left_ax)
        else
            ax = math.floor(clamp(left_safe, P.anchor.x - card_w / 2, math.max(left_safe, w - right_safe - card_w)))
        end
        ay = math.floor(clamp(top_safe, P.anchor.y - total_h / 2, math.max(top_safe, h - bot_safe - total_h)))
    else
        ax = w - right_safe - card_w
        ay = top_safe + math.floor((avail_h - total_h) / 2)
    end
    local bx = ax + card_w
    local by = ay + total_h
    local card_r = math.floor(14 * scale)

    P.card_rect = { ax = ax, ay = ay, bx = bx, by = by }
    P.hitboxes = {}

    local ass = assdraw.ass_new()

    -- Soft elevation shadow
    draw_rrect(ass, ax - 2, ay + math.floor(6 * scale), bx + 2, by + math.floor(10 * scale),
        card_r + 2, C_BGT, op * 0.08, 0)
    draw_rrect(ass, ax, ay + math.floor(2 * scale), bx, by + math.floor(4 * scale),
        card_r, C_BGT, op * 0.10, 0)

    -- Main frosted porcelain studio card
    draw_rrect(ass, ax, ay, bx, by, card_r, C_BG, op * 0.96, 1, C_BGT, op * 0.16)

    local cx1 = ax + pad
    local cx2 = bx - pad
    local cw = cx2 - cx1
    local y = ay + pad

    -- === Header ===
    draw_txt(ass, cx1, y + math.floor(11 * scale), 4, "弹幕样式调节",
        math.floor(18 * scale), C_BGT, op, true)
    draw_txt(ass, cx1, y + math.floor(31 * scale), 4, "拖动滑块实时预览 · 靠近圆点自动贴合",
        math.floor(11 * scale), C_MUTED, op * 0.85, false)

    local close_s = math.floor(28 * scale)
    local close_rect = { ax = cx2 - close_s, ay = y + math.floor(3 * scale), bx = cx2, by = y + math.floor(3 * scale) + close_s }
    local close_hov = (P.hover_id == "btn_close")
    draw_rrect(ass, close_rect.ax, close_rect.ay, close_rect.bx, close_rect.by, math.floor(8 * scale),
        close_hov and C_CLOSE or C_WHITE, op * (close_hov and 0.94 or 0.90), 1,
        close_hov and C_CLOSE or C_BGT, op * (close_hov and 0.3 or 0.12))
    draw_txt(ass, (close_rect.ax + close_rect.bx) / 2, (close_rect.ay + close_rect.by) / 2, 5, "close",
        math.floor(16 * scale), close_hov and C_WHITE or C_MUTED, op, false, "MaterialIconsRound-Regular")
    table.insert(P.hitboxes, { id = "btn_close", kind = "button", rect = close_rect, on_click = function() close_danmaku_style_panel() end })

    y = y + header_h + math.floor(4 * scale)
    -- Header divider
    draw_rrect(ass, cx1, y, cx2, y + 1, 0, C_BGT, op * 0.10, 0)
    y = y + math.floor(6 * scale)

    -- === Section 1: 5 Preset Chips ===
    local chip_gap = math.floor(6 * scale)
    local chip_w = (cw - chip_gap * (#PRESETS - 1)) / #PRESETS
    for idx, pr in ipairs(PRESETS) do
        local px1 = cx1 + (idx - 1) * (chip_w + chip_gap)
        local px2 = px1 + chip_w
        local prect = { ax = px1, ay = y, bx = px2, by = y + preset_h }
        local pid = "preset_" .. pr.id
        local hov = (P.hover_id == pid)
        draw_rrect(ass, prect.ax, prect.ay, prect.bx, prect.by, math.floor(8 * scale),
            hov and C_FG or C_WHITE, op * (hov and 0.94 or 0.92), 1,
            hov and C_FG or C_BGT, op * (hov and 0.30 or 0.12))
        draw_txt(ass, (prect.ax + prect.bx) / 2, (prect.ay + prect.by) / 2, 5, pr.label,
            math.floor(12.5 * scale), hov and C_WHITE or C_BGT, op, hov)
        table.insert(P.hitboxes, {
            id = pid, kind = "button", rect = prect,
            on_click = function()
                for k, v in pairs(pr.values) do options[k] = v end
                schedule_apply(true, true)
                render_panel()
                mp.osd_message("弹幕风格：" .. pr.label, 1.5)
            end
        })
    end
    y = y + preset_h + sec_gap

    -- === Section 2: 7 Magnetic-Snap Sliders ===
    local track_h = math.max(4, math.floor(5 * scale))
    local thumb_r = math.floor(7.5 * scale)
    local snap_r = math.max(2.5, 3.2 * scale)

    for _, sl in ipairs(SLIDERS) do
        local cur_val = sl.get()
        local norm = val_to_norm(sl, cur_val)
        local is_active = (P.dragging == sl) or (P.hover_id == "sl_" .. sl.id)

        -- Row label & right-aligned value badge
        draw_txt(ass, cx1, y + math.floor(9 * scale), 4, sl.label,
            math.floor(13.5 * scale), C_BGT, op, true)
        draw_txt(ass, cx2, y + math.floor(9 * scale), 6, sl.fmt(cur_val),
            math.floor(13 * scale), is_active and C_FG or C_MUTED, op, is_active)

        -- Track coordinates
        local tr_ax = cx1 + thumb_r
        local tr_bx = cx2 - thumb_r
        local tr_w = tr_bx - tr_ax
        local tr_cy = y + math.floor(26 * scale)
        local tr_ay = tr_cy - math.floor(track_h / 2)
        local tr_by = tr_ay + track_h
        local fill_x = tr_ax + tr_w * norm

        -- Base track
        draw_rrect(ass, tr_ax, tr_ay, tr_bx, tr_by, math.floor(track_h / 2), C_TRACK, op * 0.95, 0)
        -- Filled active progress
        if fill_x > tr_ax + 1 then
            draw_rrect(ass, tr_ax, tr_ay, fill_x, tr_by, math.floor(track_h / 2), C_FG, op * 0.95, 0)
        end

        -- Magnetic snap dots (贴合点) + micro labels underneath
        if sl.snaps then
            for _, sp in ipairs(sl.snaps) do
                local st = val_to_norm(sl, sp.val)
                local sx = tr_ax + tr_w * st
                local passed = (st <= norm + 0.005)
                local snapped_here = (math.abs(cur_val - sp.val) < (sl.step * 0.45))
                draw_circle(ass, sx, tr_cy, snap_r,
                    passed and C_WHITE or C_WHITE, op * 0.98,
                    1.2, passed and C_FG or C_MUTED, op * (passed and 0.90 or 0.55))
                if sp.tag then
                    local align = (st <= 0.06) and 7 or ((st >= 0.94) and 9 or 8)
                    draw_txt(ass, sx, tr_cy + math.floor(9 * scale), align, sp.tag,
                        math.floor(10.5 * scale), snapped_here and C_FG or C_MUTED,
                        op * (snapped_here and 1.0 or 0.78), snapped_here)
                end
            end
        end

        -- Tactile thumb handle (hover/drag grows smoothly)
        local r_now = is_active and (thumb_r + math.floor(1.5 * scale)) or thumb_r
        draw_circle(ass, fill_x, tr_cy + 1, r_now + 1, C_BGT, op * 0.14, 0)
        draw_circle(ass, fill_x, tr_cy, r_now, C_WHITE, op,
            math.max(2, 2.2 * scale), C_FG, op * (is_active and 1.0 or 0.92))

        -- Generous interactive hitbox for easy dragging & wheel nudging
        local hit_rect = {
            ax = cx1, ay = y + math.floor(4 * scale),
            bx = cx2, by = y + slider_row_h - math.floor(2 * scale),
            tr_ax = tr_ax, tr_bx = tr_bx,
        }
        table.insert(P.hitboxes, {
            id = "sl_" .. sl.id,
            kind = "slider",
            rect = hit_rect,
            slider = sl,
            on_wheel = function(dir)
                local delta = sl.step * dir * (sl.inverted and -1 or 1)
                local nv = clamp(sl.min, sl.get() + delta, sl.max)
                sl.set(nv)
                schedule_apply(sl.rebuild, true)
                render_panel()
            end,
        })

        y = y + slider_row_h
    end

    y = y + math.floor(4 * scale)
    draw_rrect(ass, cx1, y, cx2, y + 1, 0, C_BGT, op * 0.09, 0)
    y = y + math.floor(8 * scale)

    -- === Section 3: Font Family Chips ===
    local f_gap = math.floor(6 * scale)
    local f_w = (cw - f_gap * (#FONTS - 1)) / #FONTS
    for idx, fn in ipairs(FONTS) do
        local fx1 = cx1 + (idx - 1) * (f_w + f_gap)
        local frect = { ax = fx1, ay = y, bx = fx1 + f_w, by = y + font_row_h }
        local fid = "font_" .. idx
        local active = (tostring(options.fontname) == fn.id)
        local hov = (P.hover_id == fid)
        draw_rrect(ass, frect.ax, frect.ay, frect.bx, frect.by, math.floor(8 * scale),
            active and C_FG or (hov and C_FG_SOFT or C_WHITE), op * 0.94, 1,
            active and C_FG or C_BGT, op * (active and 0.35 or 0.12))
        draw_txt(ass, (frect.ax + frect.bx) / 2, (frect.ay + frect.by) / 2, 5, fn.label,
            math.floor(12 * scale), active and C_WHITE or C_BGT, op, active)
        table.insert(P.hitboxes, {
            id = fid, kind = "button", rect = frect,
            on_click = function()
                options.fontname = fn.id
                schedule_apply(false, true)
                render_panel()
            end
        })
    end
    y = y + font_row_h + math.floor(8 * scale)

    -- === Section 4: 6 Filter & Style Toggle Pills (2 rows × 3 cols) ===
    local merge_t = tonumber(options.merge_tolerance) or 5
    local toggles = {
        { id = "tg_bold",   label = "字体加粗", active = options.bold == true,
          click = function() options.bold = not (options.bold == true); schedule_apply(false, true) end },
        { id = "tg_top",    label = "屏蔽顶部", active = options.block_top == true,
          click = function() options.block_top = not (options.block_top == true); schedule_apply(false, true) end },
        { id = "tg_btm",    label = "屏蔽底部", active = options.block_bottom == true,
          click = function() options.block_bottom = not (options.block_bottom == true); schedule_apply(false, true) end },
        { id = "tg_scroll", label = "屏蔽滚动", active = options.block_scroll == true,
          click = function() options.block_scroll = not (options.block_scroll == true); schedule_apply(false, true) end },
        { id = "tg_color",  label = "统一纯白", active = options.block_color == true,
          click = function() options.block_color = not (options.block_color == true); schedule_apply(false, true) end },
        { id = "tg_merge",  label = merge_t >= 0 and ("去重 " .. math.floor(merge_t) .. "s") or "去重:关",
          active = merge_t >= 0,
          click = function()
              local cur = math.floor(tonumber(options.merge_tolerance) or 5)
              local nxt = (cur < 0) and 3 or (cur <= 3 and 5 or (cur <= 5 and 10 or -1))
              options.merge_tolerance = nxt
              schedule_apply(true, true)
          end },
    }
    local tg_gap = math.floor(6 * scale)
    local tg_w = (cw - tg_gap * 2) / 3
    for i, tg in ipairs(toggles) do
        local row = math.floor((i - 1) / 3)
        local col = (i - 1) % 3
        local tx1 = cx1 + col * (tg_w + tg_gap)
        local ty1 = y + row * (toggle_row_h + tg_gap)
        local trect = { ax = tx1, ay = ty1, bx = tx1 + tg_w, by = ty1 + toggle_row_h }
        local hov = (P.hover_id == tg.id)
        draw_rrect(ass, trect.ax, trect.ay, trect.bx, trect.by, math.floor(8 * scale),
            tg.active and C_FG or (hov and C_FG_SOFT or C_WHITE), op * 0.94, 1,
            tg.active and C_FG or C_BGT, op * (tg.active and 0.35 or 0.12))
        draw_txt(ass, (trect.ax + trect.bx) / 2, (trect.ay + trect.by) / 2, 5, tg.label,
            math.floor(11.8 * scale), tg.active and C_WHITE or C_BGT, op, tg.active)
        table.insert(P.hitboxes, {
            id = tg.id, kind = "button", rect = trect,
            on_click = function() tg.click(); render_panel() end
        })
    end
    y = y + 2 * toggle_row_h + tg_gap + sec_gap

    -- === Footer: Simplified/Traditional cycle + Reset ===
    local ch_val = math.floor(tonumber(options.chConvert) or 1)
    local ch_label = ch_val == 1 and "简繁：统一简体" or (ch_val == 2 and "简繁：统一繁体" or "简繁：保持原文")
    local foot_gap = math.floor(8 * scale)
    local ch_w = math.floor(cw * 0.56)
    local ch_rect = { ax = cx1, ay = y, bx = cx1 + ch_w, by = y + footer_h }
    local ch_hov = (P.hover_id == "btn_ch")
    draw_rrect(ass, ch_rect.ax, ch_rect.ay, ch_rect.bx, ch_rect.by, math.floor(8 * scale),
        ch_hov and C_FG_SOFT or C_WHITE, op * 0.94, 1, C_BGT, op * 0.14)
    draw_txt(ass, (ch_rect.ax + ch_rect.bx) / 2, (ch_rect.ay + ch_rect.by) / 2, 5, ch_label,
        math.floor(12 * scale), C_BGT, op, false)
    table.insert(P.hitboxes, {
        id = "btn_ch", kind = "button", rect = ch_rect,
        on_click = function()
            options.chConvert = (math.floor(tonumber(options.chConvert) or 0) + 1) % 3
            schedule_apply(true, true)
            render_panel()
        end
    })

    local rst_rect = { ax = cx1 + ch_w + foot_gap, ay = y, bx = cx2, by = y + footer_h }
    local rst_hov = (P.hover_id == "btn_reset")
    draw_rrect(ass, rst_rect.ax, rst_rect.ay, rst_rect.bx, rst_rect.by, math.floor(8 * scale),
        rst_hov and C_FG or C_WHITE, op * 0.94, 1, rst_hov and C_FG or C_BGT, op * 0.14)
    draw_txt(ass, (rst_rect.ax + rst_rect.bx) / 2, (rst_rect.ay + rst_rect.by) / 2, 5, "恢复默认",
        math.floor(12 * scale), rst_hov and C_WHITE or C_MUTED, op, rst_hov)
    table.insert(P.hitboxes, {
        id = "btn_reset", kind = "button", rect = rst_rect,
        on_click = function()
            if type(DANMAKU_STYLE_DEFAULTS) == "table" then
                for k, v in pairs(DANMAKU_STYLE_DEFAULTS) do options[k] = v end
            end
            schedule_apply(true, true)
            render_panel()
            mp.osd_message("已恢复默认弹幕样式", 1.8)
        end
    })

    panel_overlay.res_x = w
    panel_overlay.res_y = h
    panel_overlay.data = ass.text
    panel_overlay:update()
end

local function update_slider_from_x(sl, rect, mx)
    local t = (mx - rect.tr_ax) / math.max(1, rect.tr_bx - rect.tr_ax)
    local nv = norm_to_val(sl, t, true)
    if math.abs(nv - sl.get()) > 1e-6 then
        sl.set(nv)
        -- Instant live preview on every drag pixel; rebuild layout smoothly on release/debounce
        schedule_apply(sl.rebuild, false)
        render_panel()
    end
end

local function find_hitbox(mx, my)
    for i = #P.hitboxes, 1, -1 do
        local hb = P.hitboxes[i]
        if pt_in(mx, my, hb.rect) then
            return hb
        end
    end
    return nil
end

local function stop_drag_poll()
    if P.drag_timer then
        P.drag_timer:kill()
        P.drag_timer = nil
    end
end

local function on_left_down()
    if not P.open then return end
    local pos = mp.get_property_native("mouse-pos")
    if type(pos) == "table" and pos.x and pos.y then
        P.mx, P.my = pos.x, pos.y
    end
    if not pt_in(P.mx, P.my, P.card_rect) then
        close_danmaku_style_panel()
        return
    end
    local hb = find_hitbox(P.mx, P.my)
    if not hb then return end
    if hb.kind == "slider" then
        P.dragging = hb.slider
        P.drag_rect = hb.rect
        update_slider_from_x(hb.slider, hb.rect, P.mx)
        stop_drag_poll()
        -- Active 60Hz drag poll guarantees continuous silky sliding even if OS batches events
        P.drag_timer = mp.add_periodic_timer(1 / 60, function()
            if not P.open or not P.dragging or not P.drag_rect then
                stop_drag_poll()
                return
            end
            local cur = mp.get_property_native("mouse-pos")
            if type(cur) == "table" and cur.x and cur.y then
                P.mx, P.my = cur.x, cur.y
                update_slider_from_x(P.dragging, P.drag_rect, cur.x)
            end
        end)
    elseif hb.kind == "button" and hb.on_click then
        hb.on_click()
    end
end

local function on_left_up()
    stop_drag_poll()
    if not P.open then return end
    if P.dragging then
        local sl = P.dragging
        P.dragging = nil
        P.drag_rect = nil
        schedule_apply(sl.rebuild, true)
        render_panel()
    end
end

local function on_wheel(dir)
    if not P.open then return end
    local hb = find_hitbox(P.mx, P.my)
    if hb and hb.kind == "slider" and hb.on_wheel then
        hb.on_wheel(dir)
    end
end

-- Dedicated forced key section with EMPTY flags ("") to disable mpv `allow-vo-dragging`
-- so holding MBTN_LEFT slides smoothly instead of dragging the window!
mp.set_key_bindings({
    { "MBTN_LEFT",     on_left_up, on_left_down },
    { "MBTN_LEFT_DBL", function() end },
    { "WHEEL_UP",      function() on_wheel(1) end },
    { "WHEEL_DOWN",    function() on_wheel(-1) end },
    { "ESC",           function() close_danmaku_style_panel() end },
}, "dm_style_panel", "force")

local function bind_panel_keys()
    mp.enable_key_bindings("dm_style_panel", "")
    P.keys_bound = true
end

local function unbind_panel_keys()
    stop_drag_poll()
    if P.raise_timer then P.raise_timer:kill(); P.raise_timer = nil end
    if not P.keys_bound then return end
    mp.disable_key_bindings("dm_style_panel")
    P.keys_bound = false
end

function close_danmaku_style_panel(instant)
    if not P.open and P.opacity <= 0.01 then return end
    P.open = false
    P.dragging = nil
    P.drag_rect = nil
    P.hover_id = nil
    unbind_panel_keys()
    if uosc_available then
        mp.commandv("script-message-to", "uosc", "disable-elements", "danmaku_style_panel", "")
    end
    if P.fade_timer then P.fade_timer:kill(); P.fade_timer = nil end

    if instant or P.opacity <= 0.05 then
        P.opacity = 0
        P.anchor = nil
        panel_overlay:remove()
        return
    end
    local start_op = P.opacity
    local t0 = mp.get_time()
    P.fade_timer = mp.add_periodic_timer(0.016, function()
        local prog = math.min((mp.get_time() - t0) / 0.15, 1)
        P.opacity = start_op * (1 - prog) ^ 2
        render_panel()
        if prog >= 1 then
            P.fade_timer:kill()
            P.fade_timer = nil
            P.opacity = 0
            P.anchor = nil
            panel_overlay:remove()
        end
    end)
end

function open_danmaku_style_panel()
    if P.open then
        close_danmaku_style_panel()
        return
    end
    local pos = mp.get_property_native("mouse-pos")
    if type(pos) == "table" and pos.hover and pos.x and pos.y and pos.x >= 0 and pos.y >= 0 then
        P.mx, P.my = pos.x, pos.y
        P.anchor = { x = pos.x, y = pos.y }
    else
        P.anchor = nil
    end
    if uosc_available then
        mp.commandv("script-message-to", "uosc", "close-menu")
        mp.commandv("script-message-to", "uosc", "disable-elements", "danmaku_style_panel", "volume,controls,timeline,speed")
    end
    P.open = true
    P.dragging = nil
    P.in_card = false
    bind_panel_keys()
    -- Re-promote key section once after uosc finishes closing any prior menu
    if P.raise_timer then P.raise_timer:kill() end
    P.raise_timer = mp.add_timeout(0.06, function()
        P.raise_timer = nil
        if P.open then bind_panel_keys() end
    end)
    if P.fade_timer then P.fade_timer:kill() end

    local t0 = mp.get_time()
    P.opacity = 0.08
    render_panel()
    P.fade_timer = mp.add_periodic_timer(0.016, function()
        local prog = math.min((mp.get_time() - t0) / 0.18, 1)
        P.opacity = 1 - (1 - prog) ^ 3
        render_panel()
        if prog >= 1 then
            P.fade_timer:kill()
            P.fade_timer = nil
        end
    end)
end

-- Observers
mp.observe_property("osd-width", "number", function(_, v)
    if v and v > 0 then P.osd_w = v; if P.open then render_panel() end end
end)
mp.observe_property("osd-height", "number", function(_, v)
    if v and v > 0 then P.osd_h = v; if P.open then render_panel() end end
end)
mp.observe_property("mouse-pos", "native", function(_, pos)
    if type(pos) ~= "table" or not pos.x or not pos.y then return end
    P.mx, P.my = pos.x, pos.y
    if not P.open then return end
    local inside = pt_in(P.mx, P.my, P.card_rect)
    if inside and not P.in_card then
        P.in_card = true
        bind_panel_keys()
    elseif not inside and P.in_card then
        P.in_card = false
    end
    if P.dragging and P.drag_rect then
        update_slider_from_x(P.dragging, P.drag_rect, P.mx)
        return
    end
    local hb = find_hitbox(P.mx, P.my)
    local nid = hb and hb.id or nil
    if nid ~= P.hover_id then
        P.hover_id = nid
        render_panel()
    end
end)

mp.register_script_message("toggle_danmaku_style_panel", open_danmaku_style_panel)
mp.register_script_message("close_danmaku_style_panel", function() close_danmaku_style_panel(true) end)
