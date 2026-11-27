-- modified from https://github.com/rkscv/danmaku/blob/main/danmaku.lua
local msg = require('mp.msg')
local unpack = unpack or table.unpack

local osd_width, osd_height, pause = 0, 0, true
local time_pos_observer_active = false
local overlay = mp.create_osd_overlay('ass-events')

-- High-FPS smooth wall-clock interpolation state (eliminates 24fps video-rate judder)
local smooth_timer = nil
local sync_video_pos = nil
local sync_wall_time = nil
local playback_speed = 1.0
local cached_display_fps = 60
local re_entity = "&#%d+;"
local re_fs = "\\fs(%d+)"

local function pick_target_danmaku_fps()
    local dfps = cached_display_fps
    if not dfps or dfps < 40 then return 60 end
    -- Choose an exact integer divisor of display refresh rate in [60, 90] for zero beat judder
    -- e.g. 60Hz -> 60, 120Hz -> 60, 144Hz -> 72, 165Hz -> 82.5, 180Hz -> 90 (or 60), 240Hz -> 80
    for div = 1, 6 do
        local candidate = dfps / div
        if candidate <= 90.5 and candidate >= 58 then
            return candidate
        end
    end
    return 60
end

local function prepare_event_cache(event)
    if event._cached_body ~= nil then return end
    local body = event.text or ""
    if event.move then
        body = body:gsub("\\move%(.-%)", "")
    else
        body = body:gsub("\\pos%(.-%)", "")
    end
    body = body:gsub(re_entity, "")
    if body:match(re_fs) then
        body = body:gsub(re_fs, function(size)
            local n = tonumber(size) or 0
            return string.format("\\fs%d", math.floor(n * 1.5))
        end)
    end
    event._cached_body = body
    event._cached_body_mono = body:gsub("{\\c&H[%x]+&}", "")
end

local function realtime_position_text(event, pos, displayarea, top_offset, mono_color)
    top_offset = top_offset or 0
    prepare_event_cache(event)
    local clean_text = mono_color and event._cached_body_mono or event._cached_body
    local an = (event.style ~= "SP" and event.style ~= "MSG") and 8 or 7

    if not event.move then
        local cur_x, current_y = unpack(event.pos)
        if not current_y then return end
        local shifted_y = tonumber(current_y) + top_offset
        if shifted_y > displayarea then return end
        return string.format("{\\pos(%.1f,%.1f)\\an%d}%s", tonumber(cur_x) or 960, shifted_y, an, clean_text)
    end

    local x1, y1, x2, y2 = unpack(event.move)
    local duration = event.end_time - event.start_time
    if duration <= 0 then return end
    local progress = (pos - event.start_time) / duration
    local current_x = x1 + (x2 - x1) * progress
    local current_y = y1 + (y2 - y1) * progress + top_offset
    if current_y > displayarea then return end
    return string.format("{\\pos(%.2f,%.1f)\\an%d}%s", current_x, current_y, an, clean_text)
end

function render(pos_arg)
    if COMMENTS == nil then return end

    local pos, err
    if pos_arg == nil then
        pos, err = mp.get_property_number('time-pos')
        if err ~= nil then
            return msg.error(err)
        end
    else
        pos = pos_arg
    end

    if not pos then
        overlay:remove()
        return
    end

    local fontname = tostring(options.fontname or "Microsoft YaHei UI")
    local fontsize = tonumber(options.fontsize) or 36
    local opacity = tonumber(options.opacity) or 0.78
    local displayarea_ratio = tonumber(options.displayarea) or 0.72
    local scrolltime = tonumber(options.scrolltime) or 13
    local fixtime = tonumber(options.fixtime) or 5
    local alpha = string.format("%02X", math.floor((1 - math.max(0, math.min(1, opacity))) * 255 + 0.5))

    local width, height = 1920, 1080
    if osd_width > 0 and osd_height > 0 then
        local ratio = osd_width / osd_height
        if width / height < ratio then
            height = width / ratio
            fontsize = fontsize - ratio * 2
        end
    end

    local ass_events = {}
    local max_display = math.max(scrolltime, fixtime)
    local window_start = pos - max_display

    -- 跳过已结束的弹幕
    local lo = binary_search(COMMENTS, window_start, function(item) return item.start_time end)

    local ass_prefix = string.format("{\\rDefault\\fn%s\\fs%d\\c&HFFFFFF&\\alpha&H%s\\bord%s\\shad%s\\b%s\\q2}",
        fontname, math.max(12, math.floor(fontsize)), alpha, tostring(options.outline or 1.0), tostring(options.shadow or 0.5), options.bold and "1" or "0")

    local top_margin_ratio = mp.get_property_number("video-margin-ratio-top", 0) or 0
    local top_offset = math.floor(height * top_margin_ratio)
    local max_y = top_offset + (height - top_offset) * displayarea_ratio
    local block_scroll = options.block_scroll
    local block_top = options.block_top
    local block_bottom = options.block_bottom
    local block_color = options.block_color

    for i = lo, #COMMENTS do
        local event = COMMENTS[i]
        if not event then break end

        if event.start_time > pos then break end  -- 后续弹幕提前退出
        if event.end_time >= pos then
            local blocked = (block_scroll and event.style == "R2L")
                or (block_top and event.style == "TOP")
                or (block_bottom and event.style == "BTM")
            if not blocked then
                local text = realtime_position_text(event, pos, max_y, top_offset, block_color)
                if text then
                    ass_events[#ass_events + 1] = ass_prefix .. text
                end
            end
        end
    end

    overlay.res_x = width
    overlay.res_y = height
    overlay.data = table.concat(ass_events, '\n')
    overlay:update()
end

local function time_pos_callback(_, time_pos)
    if time_pos then
        local now = mp.get_time()
        -- Anchor wall-clock interpolation smoothly to video clock
        if sync_video_pos == nil or sync_wall_time == nil then
            sync_video_pos = time_pos
            sync_wall_time = now
        else
            local predicted = sync_video_pos + (now - sync_wall_time) * playback_speed
            local drift = time_pos - predicted
            if math.abs(drift) > 0.15 then
                -- Seek or buffering jump: snap immediately
                sync_video_pos = time_pos
                sync_wall_time = now
                render(time_pos)
            else
                -- Gently pull phase lock without visible jump
                sync_video_pos = predicted + drift * 0.35
                sync_wall_time = now
            end
        end
    else
        sync_video_pos = nil
        sync_wall_time = nil
        overlay:remove()
    end
end

local function smooth_tick()
    if pause or not ENABLED or COMMENTS == nil then return end
    if sync_video_pos == nil or sync_wall_time == nil then
        local tp = mp.get_property_number('time-pos')
        if not tp then return end
        sync_video_pos = tp
        sync_wall_time = mp.get_time()
    end
    local smooth_pos = sync_video_pos + (mp.get_time() - sync_wall_time) * playback_speed
    render(smooth_pos)
end

local function start_time_observer()
    if not time_pos_observer_active then
        sync_video_pos = mp.get_property_number('time-pos')
        sync_wall_time = mp.get_time()
        mp.observe_property('time-pos', 'number', time_pos_callback)
        time_pos_observer_active = true
    end
    if smooth_timer then
        smooth_timer:kill()
        smooth_timer = nil
    end
    local target_fps = pick_target_danmaku_fps()
    smooth_timer = mp.add_periodic_timer(1 / target_fps, smooth_tick)
end

local function stop_time_observer()
    if smooth_timer then
        smooth_timer:kill()
        smooth_timer = nil
    end
    if time_pos_observer_active then
        mp.unobserve_property(time_pos_callback)
        time_pos_observer_active = false
    end
    sync_video_pos = nil
    sync_wall_time = nil
end

function render_danmaku(from_menu, no_osd)
    if ENABLED and (from_menu or get_danmaku_visibility()) then
        if not no_osd then
            show_loaded(true)
        end
        mp.commandv("script-message-to", "uosc", "set", "show_danmaku", "on")
        show_danmaku_func()
    else
        show_message("")
        hide_danmaku_func()
    end
end

local function filter_state(label, name)
    local filters = mp.get_property_native("vf")
    for _, filter in pairs(filters) do
        if filter.label == label or filter.name == name
        or filter.params[name] ~= nil then
            return true
        end
    end
    return false
end

function show_danmaku_func()
    mp.set_property_bool(HAS_DANMAKU, true)
    set_danmaku_visibility(true)
    render()
    if not pause then
        start_time_observer()
    end
    if options.vf_fps then
        local display_fps = mp.get_property_number('display-fps')
        local video_fps = mp.get_property_number('estimated-vf-fps')
        if (display_fps and display_fps < 58) or (video_fps and video_fps > 58) then
            return
        end
        if not filter_state("danmaku", "fps") then
            mp.commandv("vf", "append", string.format("@danmaku:fps=fps=%s", options.fps))
        end
    end
end

function hide_danmaku_func()
    stop_time_observer()
    mp.set_property_bool(HAS_DANMAKU, false)
    set_danmaku_visibility(false)
    overlay:remove()
    if filter_state("danmaku") then
        mp.commandv("vf", "remove", "@danmaku")
    end
end

local message_overlay = mp.create_osd_overlay('ass-events')
local message_timer = mp.add_timeout(3, function()
    message_overlay:remove()
end, true)

function show_message(text, time)
    message_timer.timeout = time or 3
    message_timer:kill()
    message_overlay:remove()
    local width, height = 1920, 1080
    if osd_width > 0 and osd_height > 0 then
        local ratio = osd_width / osd_height
        if width / height < ratio then
            height = width / ratio
        end
    end
    local top_r = mp.get_property_number("video-margin-ratio-top", 0) or 0
    local msg_y = (tonumber(options.message_y) or 96) + (options.message_anlignment >= 7 and math.floor(height * top_r) or 0)
    local msg_x = (tonumber(options.message_x) or 28) + math.floor(width * (mp.get_property_number("video-margin-ratio-left", 0) or 0))
    local message = string.format("{\\an%d\\pos(%d,%d)}%s", options.message_anlignment, msg_x, msg_y, text)
    message_overlay.res_x = width
    message_overlay.res_y = height
    message_overlay.data = message
    message_overlay:update()
    message_timer:resume()
end

mp.observe_property('osd-width', 'number', function(_, value) osd_width = value or osd_width end)
mp.observe_property('osd-height', 'number', function(_, value) osd_height = value or osd_height end)
mp.observe_property('speed', 'number', function(_, value)
    if value and value > 0 then
        playback_speed = value
        sync_video_pos = mp.get_property_number('time-pos')
        sync_wall_time = mp.get_time()
    end
end)
mp.observe_property('display-fps', 'number', function(_, value)
    if value and value > 0 then
        cached_display_fps = value
        if smooth_timer and not pause and ENABLED and COMMENTS ~= nil then
            start_time_observer()
        end
    end
end)
mp.observe_property('pause', 'bool', function(_, value)
    if value ~= nil then
        pause = value
    end
    if ENABLED then
        if pause then
            stop_time_observer()
        elseif COMMENTS ~= nil then
            start_time_observer()
        end
    end
end)

mp.register_event('playback-restart', function(event)
    if event.error then
        return msg.error(event.error)
    end
    sync_video_pos = mp.get_property_number('time-pos')
    sync_wall_time = mp.get_time()
    if ENABLED and COMMENTS ~= nil then
        render(sync_video_pos)
    end
end)

mp.add_hook("on_unload", 50, function()
    COMMENTS, DELAY = nil, 0
    stop_time_observer()
    overlay:remove()
    mp.set_property_native(DELAY_PROPERTY, 0)
    if filter_state("danmaku") then
        mp.commandv("vf", "remove", "@danmaku")
    end

    if options.save_danmaku then
        save_danmaku(true)
    end

    for file in pairs(DANMAKU.hash_samples or {}) do
        os.remove(file)
    end

    DANMAKU = {sources = {}, count = 1}
    async_running = false
end)
