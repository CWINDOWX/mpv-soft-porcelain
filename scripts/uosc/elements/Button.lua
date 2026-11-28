local Element = require('elements/Element')

---@alias ButtonProps {icon: string; on_click?: function; is_clickable?: boolean; anchor_id?: string; active?: boolean; badge?: string|number; foreground?: string; background?: string; tooltip?: string}

---@class Button : Element
local Button = class(Element)

---@param id string
---@param props ButtonProps
function Button:new(id, props) return Class.new(self, id, props) --[[@as Button]] end
---@param id string
---@param props ButtonProps
function Button:init(id, props)
	self.icon = props.icon
	self.active = props.active
	self.tooltip = props.tooltip
	self.badge = props.badge
	self.foreground = props.foreground
	self.background = props.background
	self.is_clickable = true
	---@type fun()|nil
	self.on_click = props.on_click
	Element.init(self, id, props)
end

function Button:on_coordinates() self.font_size = round((self.by - self.ay) * 0.7) end
function Button:handle_cursor_click()
	if not self.on_click or not self.is_clickable then return end
	-- We delay the callback to next tick, otherwise we are risking race
	-- conditions as we are in the middle of event dispatching.
	-- For example, handler might add a menu to the end of the element stack, and that
	-- than picks up this click event we are in right now, and instantly closes itself.
	mp.add_timeout(0.01, self.on_click)
end

function Button:render()
	local visibility = self:get_visibility()
	if visibility <= 0 then return end
	cursor:zone('primary_down', self, function() self:handle_cursor_click() end)

	local ass = assdraw.ass_new()
	local is_clickable = self.is_clickable and self.on_click ~= nil
	local is_hover = self.proximity_raw <= 0
	local is_lit = self.active or (is_hover and is_clickable)

	-- Soft Porcelain pill styling (pure borderless vector fill for crisp smooth corners):
	-- Resting: frosted porcelain fill (bg) + crisp slate ink icon (bgt)
	-- Hover / Active: solid cerulean fill (fg) + crisp white icon (fgt), zero white halo/border
	local btn_fg = self.foreground or fg
	local btn_bg = self.background or bg
	local pill_color = is_lit and btn_fg or btn_bg
	local icon_color = is_lit and fgt or bgt
	local pill_opacity = self.active and (is_hover and 1 or 0.96)
		or (is_hover and is_clickable and 0.96 or config.opacity.controls)

	-- Background pill
	if pill_opacity > 0 then
		ass:rect(self.ax, self.ay, self.bx, self.by, {
			color = pill_color,
			radius = state.radius,
			opacity = visibility * pill_opacity,
		})
	end

	-- Tooltip on hover (suppressed while a menu or external popup is open so it doesn't poke into popups)
	if is_hover and self.tooltip and not Menu:is_open() and not state.external_popup then ass:tooltip(self, self.tooltip) end

	-- Badge
	local icon_clip
	local icon_offset_y = 0
	if self.badge then
		local badge_bg = is_lit and fgt or btn_fg
		local badge_fg = is_lit and btn_fg or fgt
		local badge_font_size = math.max(8, round(self.font_size * 0.42))
		local badge_opts = {size = badge_font_size, color = badge_fg, bold = true, opacity = visibility}
		local badge_width = text_width(self.badge, badge_opts)
		local pad_x = math.max(3, math.ceil(badge_font_size * 0.35))
		local width = math.ceil(badge_width + pad_x * 2)
		local height = math.ceil(badge_font_size * 1.25)
		local bx, by = round(self.bx + 2), round(self.by + 2)
		local badge_radius = math.min(state.radius, math.floor(height / 2))
		ass:rect(bx - width, by - height, bx, by, {
			color = badge_bg,
			radius = badge_radius,
			opacity = visibility,
		})
		ass:txt(bx - width / 2, by - height / 2, 5, self.badge, badge_opts)

		local clip_border = math.max(self.font_size / 22, 1)
		local clip_path = assdraw.ass_new()
		clip_path:round_rect_cw(
			math.floor((bx - width) - clip_border), math.floor((by - height) - clip_border), bx + 1, by + 1, badge_radius
		)
		icon_clip = '\\iclip(' .. clip_path.scale .. ', ' .. clip_path.text .. ')'
		icon_offset_y = -round(height * 0.22)
	end

	-- Icon
	local x, y = round(self.ax + (self.bx - self.ax) / 2), round(self.ay + (self.by - self.ay) / 2) + icon_offset_y
	local needs_border = pill_opacity < 0.4
	local icon_scale = self.badge and 0.80 or 0.92
	ass:icon(x, y, self.font_size * icon_scale, self.icon, {
		color = icon_color,
		border = needs_border and (options.text_border * state.scale) or 0,
		border_color = pill_color,
		opacity = visibility,
		clip = icon_clip,
	})

	return ass
end

return Button
