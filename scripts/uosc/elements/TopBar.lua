local Element = require('elements/Element')

---@alias TopBarButtonProps {icon: string; hover_fg?: string; hover_bg?: string; command: (fun():string)}

---@class TopBar : Element
local TopBar = class(Element)

function TopBar:new() return Class.new(self) --[[@as TopBar]] end
function TopBar:init()
	Element.init(self, 'top_bar', {render_order = 4, ignores_curtain = true})
	self.size = 0
	self.alt_title_size = 0
	self.chapter_size = 0
	self.titles_spacing = 1
	self.icon_size, self.font_size, self.title_by = 1, 1, 1
	self.show_alt_as_main = false
	self.show_filename = false
	self.danmaku_match = nil
	self.bangumi_match = nil
	self.recognized_title = nil
	self.main_title, self.alt_title = nil, nil
	---@type table<string, string|nil>
	self.render_titles = {}
	---@type {index: number; title: string}|nil
	self.current_chapter = nil

	local function maximized_command()
		if state.platform == 'windows' then
			mp.command(state.border
				and (state.fullscreen and 'set fullscreen no;cycle window-maximized' or 'cycle window-maximized')
				or 'set window-maximized no;cycle fullscreen')
		else
			mp.command(state.fullormaxed and 'set fullscreen no;set window-maximized no' or 'set window-maximized yes')
		end
	end

	local close = {icon = 'close', is_close = true, hover_fg = 'ffffff', command = function() mp.command('quit') end}
	local max = {icon = 'crop_square', command = maximized_command}
	local min = {icon = 'minimize', command = function() mp.command('cycle window-minimized') end}
	self.buttons = options.top_bar_controls == 'left' and {close, max, min} or {min, max, close}

	self:register_observers()
	self:decide_enabled()
	self:update_dimensions()
	mp.register_script_message('topbar-toggle-title', function() self:toggle_title() end)
end

---@return string|nil
local function expand_template(template)
	-- escape ASS, and strip newlines and trailing slashes and trim whitespace
	local tmp = mp.command_native({'expand-text', template}):gsub('\\n', ' '):gsub('[\\%s]+$', ''):gsub('^%s+', '')
	return tmp and tmp ~= '' and ass_escape(tmp) or nil
end

function TopBar:add_template_listener(template, callback)
	local props = get_expansion_props(template)
	for prop, _ in pairs(props) do
		self:observe_mp_property(prop, 'native', callback)
	end
	if not next(props) then callback() end
end

function TopBar:register_observers()
	-- Main title
	if #options.top_bar_title > 0 and options.top_bar_title ~= 'no' then
		if options.top_bar_title == 'yes' then
			local template = nil
			local function update_main_title()
				self.main_title = expand_template(template)
				self:update_render_titles()
			end
			local function remove_template_listener(callback) mp.unobserve_property(callback) end

			self:observe_mp_property('title', 'string', function(_, title)
				remove_template_listener(update_main_title)
				template = title
				if template then
					if template:sub(-6) == ' - mpv' then template = template:sub(1, -7) end
					self:add_template_listener(template, update_main_title)
				end
			end)
		elseif type(options.top_bar_title) == 'string' then
			self:add_template_listener(options.top_bar_title, function()
				self.main_title = expand_template(options.top_bar_title)
				self:update_render_titles()
			end)
		end
	end

	-- Alt title
	if #options.top_bar_alt_title > 0 and options.top_bar_alt_title ~= 'no' then
		self:add_template_listener(options.top_bar_alt_title, function()
			self.alt_title = expand_template(options.top_bar_alt_title)
			self:update_render_titles()
		end)
	end

	-- Smart anime recognition metadata (uosc_danmaku preferred, bangumi_sync fallback)
	self:observe_mp_property('path', 'string', function()
		self.show_filename = false
		self:refresh_recognized_title()
	end)
	self:observe_mp_property('user-data/uosc_danmaku/match-info', 'native', function(_, info)
		self.danmaku_match = type(info) == 'table' and info or nil
		self:refresh_recognized_title()
	end)
	self:observe_mp_property('user-data/bangumi_sync/match-info', 'native', function(_, info)
		self.bangumi_match = type(info) == 'table' and info or nil
		self:refresh_recognized_title()
	end)
end

local EP_UNITS = {'话', '集', '回', '話'}
local SEP_PREFIXES = {' ', '\t', '：', ':', '-', '—', '–', '·', '|', '　'}

local function trim_str(s)
	return tostring(s or ''):gsub('^%s+', ''):gsub('%s+$', '')
end

local function strip_leading_seps(s)
	local changed = true
	while changed and s ~= '' do
		changed = false
		for _, sep in ipairs(SEP_PREFIXES) do
			if s:sub(1, #sep) == sep then
				s = s:sub(#sep + 1)
				changed = true
				break
			end
		end
	end
	return s
end

local function split_episode_label(ep_str)
	ep_str = trim_str(ep_str)
	if ep_str == '' then return nil, nil end
	local prefix = '第'
	if ep_str:sub(1, #prefix) == prefix then
		local after_di = ep_str:sub(#prefix + 1)
		local num_str, rest = after_di:match('^%s*(%d+%.?%d*)%s*(.*)$')
		if num_str and rest then
			for _, unit in ipairs(EP_UNITS) do
				if rest:sub(1, #unit) == unit then
					local title_rest = trim_str(strip_leading_seps(rest:sub(#unit + 1)))
					return prefix .. num_str .. unit, (title_rest ~= '' and title_rest or nil)
				end
			end
		end
	end
	return nil, ep_str
end

local function extract_filename_episode_title(path)
	if not path or path == '' or path:match('^https?://') then return nil end
	local name = path:match('[^/\\]+$') or path
	name = name:gsub('%.[^%.]+$', '')
	local after = name:match('[Ss]%d%d?[._%s%-]*[Ee][Pp]?%d%d?%d?[._%s%-]+(.+)$')
		or name:match('[._%s%-][Ee][Pp]?%d%d?%d?[._%s%-]+(.+)$')
	if not after then return nil end
	after = after:gsub('%b[]', ' '):gsub('%b()', ' '):gsub('【.-】', ' ')
	after = after:gsub('[._]+', ' ')
	local cut_patterns = {
		'%f[%w][24][Kk]%f[%W].*',
		'%f[%w]%d%d%d+[pPiI]%f[%W].*',
		'%f[%w][Ww][Ee][Bb][%s%-]?[Dd][Ll].*',
		'%f[%w][Ww][Ee][Bb][Rr][Ii][Pp].*',
		'%f[%w][Bb][Dd][Rr][Ii][Pp].*',
		'%f[%w][Bb][Ll][Uu][%-]?[Rr][Aa][Yy].*',
		'%f[%w][Hh][Ee][Vv][Cc].*',
		'%f[%w][Hh]%s*26[45].*',
		'%f[%w][Xx]26[45].*',
		'%f[%w][Aa][Vv]1%f[%W].*',
		'%f[%w]10[Bb][Ii][Tt].*',
		'%f[%w]8[Bb][Ii][Tt].*',
		'%f[%w][Aa][Aa][Cc]%d*.*',
		'%f[%w][Ff][Ll][Aa][Cc].*',
		'%f[%w][Dd][Dd][Pp]%d*.*',
		'%f[%w][Cc][Rr]%f[%W].*',
		'%f[%w][Aa][Mm][Zz][Nn]%f[%W].*',
		'%f[%w][Nn][Ff]%f[%W].*',
		'%f[%w][Bb][%-][Gg][Ll][Oo][Bb][Aa][Ll].*',
		'%f[%w][Bb][Aa][Hh][Aa]%f[%W].*',
		'%f[%w][Cc][Hh][SsTt]%f[%W].*',
		'%f[%w][Gg][Bb]%f[%W].*',
		'%f[%w][Bb][Ii][Gg]5%f[%W].*',
		'%f[%w][Jj][Pp][Nn]%f[%W].*',
	}
	for _, pat in ipairs(cut_patterns) do
		after = after:gsub(pat, '')
	end
	after = trim_str(after:gsub('%s+', ' '):gsub('[%-%s_]+$', ''))
	local low = after:lower()
	if #after < 2 or low == 'chapters' or low == 'final' or low == 'end' or low == 'uncensored'
		or low:match('^v%d+$') or low:match('^[%d%p%s]+$') then
		return nil
	end
	return after
end

function TopBar:refresh_recognized_title()
	local cur_path = mp.get_property('path') or ''
	local dm, bgm = nil, nil
	if self.danmaku_match and trim_str(self.danmaku_match.anime) ~= ''
		and (not self.danmaku_match.path or self.danmaku_match.path == '' or self.danmaku_match.path == cur_path) then
		dm = self.danmaku_match
	end
	if self.bangumi_match and trim_str(self.bangumi_match.anime) ~= ''
		and (not self.bangumi_match.path or self.bangumi_match.path == '' or self.bangumi_match.path == cur_path) then
		bgm = self.bangumi_match
	end

	local anime = (dm and trim_str(dm.anime)) or (bgm and trim_str(bgm.anime)) or nil
	if anime and anime ~= '' then
		local dm_num, dm_ep_title = split_episode_label(dm and dm.episode)
		local bgm_num, bgm_ep_title = split_episode_label(bgm and bgm.episode)
		if bgm and trim_str(bgm.episode_title) ~= '' then
			bgm_ep_title = trim_str(bgm.episode_title)
		end

		local ep_num = dm_num or bgm_num
		if not ep_num and bgm and bgm.episode_num then
			ep_num = '第' .. tostring(bgm.episode_num) .. '话'
		end

		local ep_title = bgm_ep_title or dm_ep_title or extract_filename_episode_title(cur_path)
		if ep_title then
			ep_title = trim_str(ep_title)
			if ep_num and ep_title:sub(1, #ep_num) == ep_num then
				ep_title = trim_str(strip_leading_seps(ep_title:sub(#ep_num + 1)))
			end
			if ep_title == '' or ep_title == anime or ep_title == ep_num then
				ep_title = nil
			end
		end

		local ep_full = ''
		if ep_num and ep_title then
			ep_full = ep_num .. ' ' .. ep_title
		elseif ep_num then
			ep_full = ep_num
		elseif ep_title then
			ep_full = ep_title
		end

		local label = ep_full ~= '' and (anime .. ' · ' .. ep_full) or anime
		self.recognized_title = ass_escape(label)
	else
		self.recognized_title = nil
	end
	self:update_render_titles()
end

function TopBar:get_visibility()
	-- Persistent porcelain top header bar in windowed & maximized modes; auto-hide in fullscreen
	if not state.fullscreen and (not state.border or state.title_bar == false) then
		return 1
	end
	return Element.get_visibility(self)
end

function TopBar:decide_enabled()
	if options.top_bar == 'no-border' then
		self.enabled = not state.border or state.title_bar == false or state.fullscreen
	else
		self.enabled = options.top_bar == 'always'
	end
	self.enabled = self.enabled and (options.top_bar_controls or options.top_bar_title ~= 'no' or state.has_playlist)
end

-- Set titles. Both have to be passed at the same time so that they can be normalized & deduplicated.
function TopBar:update_render_titles()
	local main, alt = self.main_title, self.alt_title

	if main == 'No file' then
		main = ulang._border_title
	end

	-- Fall back to alt title if main is empty
	if not main or main == '' then
		main, alt = alt, nil
	end

	-- Deduplicate the main and alt titles by checking if one completely
	-- contains the other, and using only the longer one.
	if main and alt and not self.show_alt_as_main then
		local longer_title, shorter_title
		if #main < #alt then
			longer_title, shorter_title = alt, main
		else
			longer_title, shorter_title = main, alt
		end

		local escaped_shorter_title = regexp_escape(shorter_title --[[@as string]])
		if string.match(longer_title --[[@as string]], escaped_shorter_title) then
			main, alt = longer_title, nil
		end
	end

	if self.show_alt_as_main and alt and alt ~= '' then
		main, alt = alt, nil
	end

	-- Prefer recognized anime title & episode by default; click once to toggle raw filename
	if self.recognized_title and not self.show_filename then
		main, alt = self.recognized_title, nil
	end

	self.render_titles.main, self.render_titles.alt = main, alt
	self:update_dimensions()
	request_render()
end

function TopBar:select_current_chapter()
	local current_chapter_index = self.current_chapter and self.current_chapter.index
	local current_chapter
	if state.time and state.chapters then
		_, current_chapter = itable_find(state.chapters, function(c) return state.time >= c.time end, #state.chapters, 1)
	end
	local new_chapter_index = current_chapter and current_chapter.index
	if current_chapter_index ~= new_chapter_index then
		self.current_chapter = current_chapter
		if itable_has(config.top_bar_flash_on, 'chapter') then
			self:flash()
		end
		self:update_dimensions()
	end
end

function TopBar:update_dimensions()
	self.size = round(options.top_bar_size * state.scale)
	self.title_spacing = round(2 * state.scale)
	self.icon_size = round(self.size * 0.5)
	self.font_size = math.floor((self.size - (math.ceil(self.size * 0.28) * 2)) * options.font_scale)
	self.alt_title_size = round(self.font_size * 1.2)
	self.chapter_size = round(self.font_size * 1.1)
	local window_border_size = Elements:v('window_border', 'size', 0)
	local wb_enabled = Elements:v('window_border', 'enabled', false)
	local top_ay = wb_enabled and Elements:v('window_border', 'top_bar_ay', 0) or window_border_size
	local vp = Elements:v('window_border', 'viewport')
	local min_hitbox_height = self.size
	if self.render_titles.alt and options.top_bar_alt_title_place == 'below' then
		min_hitbox_height = min_hitbox_height + self.title_spacing + self.alt_title_size
	end
	self.ax = window_border_size
	self.ay = top_ay
	self.bx = display.width - window_border_size
	-- Align bottom edge to video viewport top when persistent chrome is active
	local chrome_by = (wb_enabled and vp and vp.ay) or (top_ay + self.size)
	self.by = math.max(chrome_by, top_ay + min_hitbox_height - options.proximity_in)
end

function TopBar:toggle_title()
	if self.recognized_title then
		self.show_filename = not self.show_filename
		self:update_render_titles()
		return
	end
	if options.top_bar_alt_title_place ~= 'toggle' then return end
	self.show_alt_as_main = not self.show_alt_as_main
	self:update_render_titles()
end

function TopBar:on_prop_time() end
function TopBar:on_prop_chapters() end

function TopBar:on_prop_border()
	self:decide_enabled()
	self:update_dimensions()
end

function TopBar:on_prop_title_bar()
	self:decide_enabled()
	self:update_dimensions()
end

function TopBar:on_prop_fullscreen()
	self:decide_enabled()
	self:update_dimensions()
end

function TopBar:on_prop_maximized()
	self:decide_enabled()
	self:update_dimensions()
end

function TopBar:on_prop_has_playlist()
	self:decide_enabled()
	self:update_dimensions()
end

function TopBar:on_display() self:update_dimensions() end

function TopBar:on_options()
	self:decide_enabled()
	self:update_dimensions()
end

function TopBar:render()
	local visibility = self:get_visibility()
	if visibility <= 0 then return end
	local ass = assdraw.ass_new()
	-- `by` might be artificially extended so people with low proximity options
	-- can still click on chapter button, so we can't use it for rendering.
	local ax, ay, bx, by = self.ax, self.ay, self.bx, self.ay + self.size
	local margin = math.floor((self.size - self.font_size) / 4)
	local is_framed = Elements:v('window_border', 'enabled', false) and not state.fullscreen

	-- In fullscreen (no persistent WindowBorder), draw translucent porcelain header strip
	if not is_framed then
		ass:rect(ax, ay, bx, by + round(2 * state.scale), {
			color = bg,
			opacity = visibility * 0.62,
		})
		ass:rect(ax, by + round(2 * state.scale), bx, by + round(3 * state.scale), {
			color = bgt,
			opacity = visibility * 0.14,
		})
	end

	-- Window controls
	if options.top_bar_controls then
		local is_left, button_ax = options.top_bar_controls == 'left', 0
		if is_left then
			button_ax = ax
			ax = self.size * #self.buttons
		else
			button_ax = bx - self.size * #self.buttons
			bx = button_ax
		end

		for _, button in ipairs(self.buttons) do
			local rect = {ax = button_ax, ay = ay, bx = button_ax + self.size, by = by}
			local is_hover = get_point_to_rectangle_proximity(cursor, rect) <= 0
			local opacity = is_hover and 0.96 or (is_framed and 0.92 or config.opacity.controls)
			local button_fg = is_hover and (button.hover_fg or fgt) or bgt
			local button_bg = is_hover and (button.is_close and config.color.error or button.hover_bg or fg)
				or (is_framed and (config.color.surface or bg) or bg)
			local icon_name = (button.icon == 'crop_square' and state.maximized) and 'filter_none' or button.icon

			cursor:zone('primary_down', rect, button.command)

			local bg_size = self.size - margin * 2
			local bg_ax = rect.ax + math.floor((self.size - bg_size) / 2)
			local bg_ay = rect.ay + margin
			local bg_bx, bg_by = bg_ax + bg_size, bg_ay + bg_size
			local btn_radius = math.min(state.radius, math.floor(bg_size / 2))

			if not is_hover and is_framed then
				ass:rect(bg_ax, bg_ay + 1, bg_bx, bg_by + 1, {
					color = config.color.shadow,
					opacity = math.min(0.35, visibility * 0.06 * (config.shadow_mult or 1.0)),
					radius = btn_radius,
				})
			end

			ass:rect(bg_ax, bg_ay, bg_bx, bg_by, {
				color = button_bg,
				opacity = visibility * opacity,
				radius = btn_radius,
			})

			ass:icon(bg_ax + bg_size / 2, bg_ay + bg_size / 2, bg_size * 0.54, icon_name, {
				color = button_fg,
				border = 0,
				opacity = visibility,
			})

			button_ax = button_ax + self.size
		end
	end

	-- Window title
	local main_title, alt_title = self.render_titles.main, self.render_titles.alt
	if main_title or state.has_playlist then
		local padding = round(self.font_size / 2)
		local left_aligned = options.top_bar_controls == 'left'
		local title_ax, title_bx, title_ay = ax + margin, bx - margin, self.ay + margin

		-- Playlist position
		if state.has_playlist then
			local text = state.playlist_pos .. '' .. state.playlist_count
			local formatted_text = '{\\b1}' .. state.playlist_pos .. '{\\b0\\fs' .. self.font_size * 0.9 .. '}/'
				.. state.playlist_count
			local opts = {size = self.font_size, wrap = 2, color = fgt, opacity = visibility}
			local rect_width = round(text_width(text, opts) + padding * 2)
			local ax = left_aligned and title_bx - rect_width or title_ax
			local rect = {
				ax = ax,
				ay = title_ay,
				bx = ax + rect_width,
				by = by - margin,
			}
			local opacity = get_point_to_rectangle_proximity(cursor, rect) <= 0
				and 1 or config.opacity.playlist_position
			if opacity > 0 then
				ass:rect(rect.ax, rect.ay, rect.bx, rect.by, {
					color = fg, opacity = visibility * opacity, radius = state.radius,
				})
			end
			ass:txt(rect.ax + (rect.bx - rect.ax) / 2, rect.ay + (rect.by - rect.ay) / 2, 5, formatted_text, opts)
			if left_aligned then title_bx = rect.ax - margin else title_ax = rect.bx + margin end

			-- Click action
			cursor:zone('primary_down', rect, function() mp.command('script-binding uosc/playlist') end)
		end

		-- Skip rendering titles if there's not enough horizontal space
		if title_bx - title_ax > self.font_size * 3 and options.top_bar_title ~= 'no' then
			-- Main title
			if main_title then
				local is_recognized_view = (self.recognized_title ~= nil and not self.show_filename)
				local dot_space = is_recognized_view and round(14 * state.scale) or 0
				local opts = {
					size = self.font_size,
					bold = is_recognized_view,
					wrap = 2,
					color = bgt,
					opacity = visibility,
					border = 0,
					clip = string.format('\\clip(%d, %d, %d, %d)', self.ax, ay, title_bx, by),
				}
				local rect_ideal_width = round(text_width(main_title, opts) + padding * 2 + dot_space)
				local rect_width = math.min(rect_ideal_width, title_bx - title_ax)
				local ax = left_aligned and title_bx - rect_width or title_ax
				local by = by - margin
				local title_rect = {ax = ax, ay = title_ay, bx = ax + rect_width, by = by}
				local is_title_hover = get_point_to_rectangle_proximity(cursor, title_rect) <= 0
				opts.clip = string.format('\\clip(%d, %d, %d, %d)', title_rect.ax, ay, title_rect.bx - math.floor(padding * 0.5), by)

				if self.recognized_title or options.top_bar_alt_title_place == 'toggle' then
					cursor:zone('primary_down', title_rect, function() self:toggle_title() end)
				end

				local pill_fill = (is_title_hover and self.recognized_title) and (config.color.surface_hover or bg)
					or (is_framed and (config.color.surface or bg) or bg)
				if is_framed then
					ass:rect(title_rect.ax, title_rect.ay + 1, title_rect.bx, title_rect.by + 1, {
						color = config.color.shadow,
						opacity = math.min(0.35, visibility * 0.06 * (config.shadow_mult or 1.0)),
						radius = state.radius,
					})
				end
				ass:rect(title_rect.ax, title_rect.ay, title_rect.bx, title_rect.by, {
					color = pill_fill,
					opacity = visibility * (is_framed and 0.96 or config.opacity.title),
					radius = state.radius,
				})

				if is_recognized_view then
					local dot_r = round(3.5 * state.scale)
					ass:circle(ax + padding + dot_r, ay + (self.size / 2), dot_r, {
						color = fg,
						opacity = visibility * 0.92,
					})
				end

				local align = left_aligned and rect_ideal_width == rect_width and 6 or 4
				local x = align == 6 and title_rect.bx - padding or ax + padding + dot_space
				ass:txt(x, ay + (self.size / 2), align, main_title, opts)

				if is_title_hover and self.recognized_title then
					ass:tooltip(title_rect, is_recognized_view and '切换文件名' or '切换番剧名', {
						align = 2,
						offset = round(10 * state.scale),
					})
				end

				title_ay = by + self.title_spacing + (is_framed and round(6 * state.scale) or 0)
			end

			-- Alt title
			if alt_title and options.top_bar_alt_title_place == 'below' then
				local by = title_ay + self.alt_title_size
				local opts = {
					size = round(self.alt_title_size * 0.77),
					wrap = 2,
					color = bgt,
					border = options.text_border * state.scale,
					border_color = bg,
					opacity = visibility,
				}
				local rect_ideal_width = round(text_width(alt_title, opts) + padding * 2)
				local rect_width = math.min(rect_ideal_width, title_bx - title_ax)
				local ax = left_aligned and title_bx - rect_width or title_ax
				local bx = ax + rect_width
				opts.clip = string.format('\\clip(%d, %d, %d, %d)', title_ax, title_ay, bx, by)
				ass:rect(ax, title_ay, bx, by, {
					color = bg, opacity = visibility * config.opacity.title, radius = state.radius,
				})
				local align = left_aligned and rect_ideal_width == rect_width and 6 or 4
				local x = align == 6 and bx - padding or ax + padding
				ass:txt(x, title_ay + self.alt_title_size / 2, align, alt_title, opts)
				title_ay = by + self.title_spacing
			end
		end
		self.title_by = title_ay - 1
	else
		self.title_by = ay
	end

	return ass
end

return TopBar
