local Element = require('elements/Element')

---@class WindowBorder : Element
local WindowBorder = class(Element)

function WindowBorder:new() return Class.new(self) --[[@as WindowBorder]] end
function WindowBorder:init()
	Element.init(self, 'window_border', {render_order = 9999})
	self.size = 0
	self:decide_enabled()
end

function WindowBorder:decide_enabled()
	self.enabled = options.window_border_size > 0 and not state.fullormaxed and (not state.border or state.title_bar == false)
	self.size = self.enabled and round(options.window_border_size * state.scale) or 0
end

function WindowBorder:on_prop_border() self:decide_enabled() end
function WindowBorder:on_prop_title_bar() self:decide_enabled() end
function WindowBorder:on_prop_fullormaxed() self:decide_enabled() end
function WindowBorder:on_options() self:decide_enabled() end

function WindowBorder:render()
	if self.size > 0 then
		local ass = assdraw.ass_new()
		local s = self.size
		local w, h = display.width, display.height
		local inner_clip = '\\iclip(' .. s .. ',' .. s .. ',' .. (w - s) .. ',' .. (h - s) .. ')'

		-- Soft porcelain outer window bezel
		ass:rect(0, 0, w + 1, h + 1, {
			color = bg, clip = inner_clip, opacity = math.max(config.opacity.border, 0.96),
		})

		-- Delicate 1px outer hairline framing the window edge
		local outer_line = '\\iclip(1,1,' .. (w - 1) .. ',' .. (h - 1) .. ')'
		ass:rect(0, 0, w + 1, h + 1, {
			color = bgt, clip = outer_line, opacity = 0.22,
		})

		-- Crisp 1px inner rim separating porcelain bezel from video viewport
		local rim = math.max(s - 1, 1)
		local inner_rim_clip = '\\clip(' .. rim .. ',' .. rim .. ',' .. (w - rim) .. ',' .. (h - rim) .. ')'
			.. '\\iclip(' .. s .. ',' .. s .. ',' .. (w - s) .. ',' .. (h - s) .. ')'
		ass:rect(rim, rim, w - rim, h - rim, {
			color = bgt, clip = inner_rim_clip, opacity = 0.16,
		})
		return ass
	end
end

return WindowBorder
