local Element = require('elements/Element')

---@class WindowBorder : Element
local WindowBorder = class(Element)

function WindowBorder:new() return Class.new(self) --[[@as WindowBorder]] end
function WindowBorder:init()
	Element.init(self, 'window_border', {render_order = 3.5, ignores_curtain = true})
	self.size = 0
	self.top_bar_ay = 0
	self.viewport = {ax = 0, ay = 0, bx = display.width, by = display.height, radius = 0}
	self:decide_enabled()
end

-- Last applied margins; one state change (resize/fullscreen/maximize) fires several observers,
-- so skip redundant property writes that would otherwise re-trigger video layout each time.
local applied_margins = {}

local function set_margin(side, value)
	value = round(value * 10000) / 10000
	if applied_margins[side] == value then return end
	applied_margins[side] = value
	mp.set_property_number('video-margin-ratio-' .. side, value)
end

function WindowBorder:sync_video_margins()
	if not display.width or display.width <= 100 or not display.height or display.height <= 100 then return end
	if self.enabled and not state.fullscreen then
		local vp = self.viewport
		set_margin('top', clamp(0, vp.ay / display.height, 0.35))
		set_margin('left', clamp(0, vp.ax / display.width, 0.25))
		set_margin('right', clamp(0, (display.width - vp.bx) / display.width, 0.25))
		set_margin('bottom', clamp(0, (display.height - vp.by) / display.height, 0.25))
	else
		set_margin('top', 0)
		set_margin('left', 0)
		set_margin('right', 0)
		set_margin('bottom', 0)
	end
end

function WindowBorder:decide_enabled()
	local framed = not state.fullscreen and (not state.border or state.title_bar == false)
	self.enabled = framed
	local is_max = state.maximized and not state.fullscreen
	self.size = (framed and not is_max and options.window_border_size > 0)
		and round(options.window_border_size * state.scale) or 0
	local tb = framed and round(options.top_bar_size * state.scale) or 0
	self.top_bar_ay = is_max and 0 or round(self.size * 0.35)
	local vy1 = framed and (self.top_bar_ay + tb + (is_max and 0 or round(self.size * 0.35))) or 0
	local inner_r = (framed and not is_max and self.size > 0) and round(12 * state.scale) or 0
	self.viewport = {
		ax = self.size,
		ay = vy1,
		bx = math.max(self.size + 1, display.width - self.size),
		by = math.max(vy1 + 1, display.height - self.size),
		radius = inner_r,
	}
	self:sync_video_margins()
end

function WindowBorder:on_display() self:decide_enabled() end
function WindowBorder:on_prop_border() self:decide_enabled() end
function WindowBorder:on_prop_title_bar() self:decide_enabled() end
function WindowBorder:on_prop_fullscreen() self:decide_enabled() end
function WindowBorder:on_prop_maximized() self:decide_enabled() end
function WindowBorder:on_prop_fullormaxed() self:decide_enabled() end
function WindowBorder:on_options() self:decide_enabled() end

function WindowBorder:render()
	if not self.enabled then return end
	local w, h = display.width, display.height
	local vp = self.viewport
	local ass = assdraw.ass_new()

	-- Build inverted rounded-rect clip for the inner video viewport
	local cutout = assdraw.ass_new()
	if vp.radius > 0 then
		cutout:round_rect_cw(vp.ax, vp.ay, vp.bx, vp.by, vp.radius)
	else
		cutout:rect_cw(vp.ax, vp.ay, vp.bx, vp.by)
	end
	local iclip = '\\iclip(' .. cutout.scale .. ', ' .. cutout.text .. ')'

	-- Seamless Soft Porcelain outer frame + persistent top bar chrome
	ass:rect(0, 0, w + 1, h + 1, {
		color = bg,
		clip = iclip,
		opacity = 1,
	})

	-- Subtle separator line below persistent top bar only when unrounded (maximized)
	if vp.radius <= 0 then
		ass:rect(0, vp.ay - 1, w, vp.ay, {color = bgt, opacity = 0.12})
	end

	-- Subtle outer edge hairline framing the window against bright wallpapers
	if self.size > 0 then
		local outer_line = '\\iclip(1,1,' .. (w - 1) .. ',' .. (h - 1) .. ')'
		ass:rect(0, 0, w + 1, h + 1, {
			color = bgt,
			clip = outer_line,
			opacity = 0.18,
		})
	end

	return ass
end

return WindowBorder
