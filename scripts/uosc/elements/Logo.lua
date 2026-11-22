local Element = require('elements/Element')

--[[ Logo ]]

---@class Logo : Element
local Logo = class(Element)

function Logo:new() return Class.new(self) --[[@as Logo]] end
function Logo:init()
	Element.init(self, 'logo')
	self.enabled = state.is_idle
end

function Logo:decide_enabled() self.enabled = state.idlescreen and state.is_idle end
function Logo:on_prop_is_idle() self:decide_enabled() end
function Logo:on_prop_idlescreen() self:decide_enabled() end

function Logo:render()
	if Menu:is_open() then return end

	local ass = assdraw.ass_new()
	local scale = state.scale
	local cx = display.width / 2
	local cy = display.height / 2 - 26 * scale
	local r = round(50 * scale)

	-- Soft layered porcelain elevation shadow
	ass:circle(cx, cy + round(8 * scale), r + round(4 * scale), {
		color = bgt,
		opacity = 0.05,
	})
	ass:circle(cx, cy + round(3 * scale), r + round(1 * scale), {
		color = bgt,
		opacity = 0.08,
	})

	-- Pure frosted porcelain medallion (borderless smooth vector fill)
	ass:circle(cx, cy, r, {
		color = 'ffffff',
		opacity = 0.96,
	})

	-- Inner soft mist halo ring
	ass:circle(cx, cy, round(r * 0.78), {
		color = bg,
		opacity = 0.92,
	})

	-- Minimalist serene cerulean play glyph centered optically
	ass:icon(cx + round(2 * scale), cy, round(r * 1.05), 'play_arrow', {
		color = fg,
		opacity = 0.94,
	})

	-- Primary calm title
	local primary_msg = (options.idlemsg == 'default' or options.idlemsg == '')
		and '拖入视频开始播放' or tostring(options.idlemsg)
	local title_size = round(23 * scale)
	local title_y = cy + r + round(24 * scale)
	ass:txt(cx, title_y, 8, primary_msg, {
		size = title_size,
		color = bgt,
		bold = true,
		opacity = 0.88,
	})

	-- Quiet minimalist shortcut pill bar
	local sub_text = '右键 菜单  ·  Shift+A 画质  ·  Z 弹幕  ·  Ctrl+B 同步'
	local sub_size = round(13.5 * scale)
	local sub_opts = {size = sub_size, color = bgt, opacity = 0.58}
	local sub_w = text_width(sub_text, sub_opts)
	local pill_pad_x = round(16 * scale)
	local pill_pad_y = round(7 * scale)
	local pill_y = title_y + title_size + round(16 * scale)
	local pill_h = sub_size + pill_pad_y * 2
	if sub_w + pill_pad_x * 2 < display.width * 0.92 then
		ass:rect(
			cx - sub_w / 2 - pill_pad_x, pill_y + 1,
			cx + sub_w / 2 + pill_pad_x, pill_y + pill_h + 1,
			{
				color = bgt,
				opacity = 0.05,
				radius = math.floor(pill_h / 2),
			}
		)
		ass:rect(
			cx - sub_w / 2 - pill_pad_x, pill_y,
			cx + sub_w / 2 + pill_pad_x, pill_y + pill_h,
			{
				color = 'ffffff',
				opacity = 0.78,
				radius = math.floor(pill_h / 2),
			}
		)
		ass:txt(cx, pill_y + pill_h / 2, 5, sub_text, sub_opts)
	end

	return ass
end

return Logo
