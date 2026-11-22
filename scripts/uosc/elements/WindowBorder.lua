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

function WindowBorder:sync_video_margins()
	if not display.width or display.width <= 100 or not display.height or display.height <= 100 then return end
	if self.enabled and not state.fullscreen then
		local vp = self.viewport
		local top_r = clamp(0, vp.ay / display.height, 0.35)
		local left_r = clamp(0, vp.ax / display.width, 0.25)
		local right_r = clamp(0, (display.width - vp.bx) / display.width, 0.25)
		local bottom_r = clamp(0, (display.height - vp.by) / display.height, 0.25)
		mp.set_property_number('video-margin-ratio-top', top_r)
		mp.set_property_number('video-margin-ratio-left', left_r)
		mp.set_property_number('video-margin-ratio-right', right_r)
		mp.set_property_number('video-margin-ratio-bottom', bottom_r)
	else
		mp.set_property_number('video-margin-ratio-top', 0)
		mp.set_property_number('video-margin-ratio-left', 0)
		mp.set_property_number('video-margin-ratio-right', 0)
		mp.set_property_number('video-margin-ratio-bottom', 0)
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

	-- Delicate inner rim tracing the rounded video viewport cleanly
	if vp.radius > 0 then
		ass:rect(vp.ax, vp.ay, vp.bx, vp.by, {
			color = bg,
			border = 1,
			border_color = bgt,
			radius = vp.radius,
			opacity = {main = 0, border = 0.16},
		})
	else
		ass:rect(0, vp.ay - 1, w, vp.ay, {color = bgt, opacity = 0.14})
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
