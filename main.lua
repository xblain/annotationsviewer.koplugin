local WidgetContainer = require("ui/widget/container/widgetcontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local LeftContainer = require("ui/widget/container/leftcontainer")
local RightContainer = require("ui/widget/container/rightcontainer")
local TopContainer = require("ui/widget/container/topcontainer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local CenterContainer = require("ui/widget/container/centercontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local LineWidget = require("ui/widget/linewidget")
local Button = require("ui/widget/button")
local InputContainer = require("ui/widget/container/inputcontainer")
local GestureRange = require("ui/gesturerange")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local ButtonDialogTitle = require("ui/widget/buttondialogtitle")
local TextViewer = require("ui/widget/textviewer")
local SpinWidget = require("ui/widget/spinwidget")
local TitleBar = require("ui/widget/titlebar")
local Blitbuffer = require("ffi/blitbuffer")
local Screen = require("device").screen
local Device = require("device")
local FontList = require("fontlist")
local DocSettings = require("docsettings")
local ReadHistory = require("readhistory")
local G_reader_settings = require("luasettings"):open(require("datastorage"):getSettingsDir() .. "/settings.reader.lua")
local lfs = require("libs/libkoreader-lfs")
local Font = require("ui/font")
local Size = require("ui/size")
local Geom = require("ui/geometry")
local G_defaults = require("luadefaults"):open()
local _ = require("gettext")
local BD = require("ui/bidi")
local DEFAULT_CONTENT_FONT_SIZE = 18
local DEFAULT_TITLE_FONT_SIZE = 18
local DEFAULT_INFO_FONT_SIZE = 15
local DEFAULT_H_MARGIN = 30
local DEFAULT_V_MARGIN = 20
local DEFAULT_NOTE_SPACING = 30
local DEFAULT_TEXT_MARGIN = 10
local DEFAULT_TRUNCATE_WORDS = 60
local DEFAULT_TITLE_MARGIN = 2
local DEFAULT_INFO_MARGIN = 6
local DEFAULT_CONTENT_MARGIN = 8
local DEFAULT_TOP_PADDING = 0
local function getSetting(key, default)
    local val = G_reader_settings:readSetting("allnotesviewer_" .. key)
    if val == nil then return default end
    return val
end
local function setSetting(key, value)
    G_reader_settings:saveSetting("allnotesviewer_" .. key, value)
    G_reader_settings:flush()
end
local function getContentFontSize() return getSetting("content_font_size", DEFAULT_CONTENT_FONT_SIZE) end
local function getTitleFontSize() return getSetting("title_font_size", DEFAULT_TITLE_FONT_SIZE) end
local function getInfoFontSize() return getSetting("info_font_size", DEFAULT_INFO_FONT_SIZE) end
local function getHMargin() return Screen:scaleBySize(getSetting("h_margin", DEFAULT_H_MARGIN)) end
local function getVMargin() return Screen:scaleBySize(getSetting("v_margin", DEFAULT_V_MARGIN)) end
local function getNoteSpacing() return Screen:scaleBySize(getSetting("note_spacing", DEFAULT_NOTE_SPACING)) end
local function getTextMargin() return Screen:scaleBySize(getSetting("text_margin", DEFAULT_TEXT_MARGIN)) end
local function getTruncateWords() return getSetting("truncate_words", DEFAULT_TRUNCATE_WORDS) end
local function getShowSeparator() return getSetting("show_separator", true) end
local function getJustify() return getSetting("justify", false) end
local function getTitleMargin() return Screen:scaleBySize(getSetting("title_margin", DEFAULT_TITLE_MARGIN)) end
local function getInfoMargin() return Screen:scaleBySize(getSetting("info_margin", DEFAULT_INFO_MARGIN)) end
local function getContentMargin() return Screen:scaleBySize(getSetting("content_margin", DEFAULT_CONTENT_MARGIN)) end
local function getTitleFont() return getSetting("title_font", nil) end
local function getInfoFont() return getSetting("info_font", nil) end
local function getContentFont() return getSetting("content_font", nil) end
local function getShowTotalNotes() return getSetting("show_total", true) end
local function getTopPadding() return Screen:scaleBySize(getSetting("top_padding", DEFAULT_TOP_PADDING)) end
local HIGHLIGHT_COLORS = {
    yellow = Blitbuffer.colorFromString("#FFFF00"),
    green = Blitbuffer.colorFromString("#00FF00"),
    blue = Blitbuffer.colorFromString("#0000FF"),
    pink = Blitbuffer.colorFromString("#FF00FF"),
    orange = Blitbuffer.colorFromString("#FFA500"),
    red = Blitbuffer.colorFromString("#FF0000"),
    cyan = Blitbuffer.colorFromString("#00FFFF"),
    gray = Blitbuffer.colorFromString("#808080"),
    lighten = Blitbuffer.colorFromString("#E0E0E0"),
}
local function getHighlightColor(color)
    if not color then return HIGHLIGHT_COLORS.lighten end
    local lower = color:lower()
    if HIGHLIGHT_COLORS[lower] then return HIGHLIGHT_COLORS[lower] end
    if color:match("^#") then return Blitbuffer.colorFromString(color) end
    return HIGHLIGHT_COLORS.lighten
end
local function getColorName(color)
    if not color then return nil end
    local lower = color:lower()
    if lower == "yellow" or lower:find("ffff00") then return "Yellow"
    elseif lower == "green" or lower:find("00ff00") then return "Green"
    elseif lower == "blue" or lower:find("0000ff") then return "Blue"
    elseif lower == "pink" or lower:find("ff00ff") then return "Pink"
    elseif lower == "orange" or lower:find("ffa500") then return "Orange"
    elseif lower == "red" or lower:find("ff0000") then return "Red"
    elseif lower == "cyan" or lower:find("00ffff") then return "Cyan"
    elseif lower == "gray" or lower:find("808080") then return "Gray"
    else return color end
end
local function getStyleName(drawer)
    if not drawer then return nil end
    local d = drawer:lower()
    if d == "underscore" then return "Underline"
    elseif d == "strikeout" then return "Strikeout"
    elseif d == "invert" then return "Invert"
    elseif d == "lighten" then return "Lighten"
    elseif d == "highlight" then return "Highlight"
    else return drawer end
end
local function isNoBackgroundStyle(drawer)
    if not drawer then return false end
    local d = drawer:lower()
    return d == "strikeout" or d == "underscore"
end
local function truncateText(text, max_words)
    if not text then return "" end
    local clean_text = text:gsub("\n", " "):gsub("%s+", " ")
    local words = {}
    for word in clean_text:gmatch("%S+") do table.insert(words, word) end
    if #words > max_words then
        return table.concat(words, " ", 1, max_words) .. "..."
    end
    return clean_text
end
local function wrapText(text, face, max_width)
    local lines = {}
    local words = {}
    for word in text:gmatch("%S+") do table.insert(words, word) end
    local current_line = ""
    for _, word in ipairs(words) do
        local test_line = current_line == "" and word or (current_line .. " " .. word)
        local tw = TextWidget:new{ text = test_line, face = face }
        local w = tw:getSize().w
        tw:free()
        if w <= max_width then
            current_line = test_line
        else
            if current_line ~= "" then table.insert(lines, current_line) end
            current_line = word
        end
    end
    if current_line ~= "" then table.insert(lines, current_line) end
    return lines
end
local function createJustifiedLine(text, face, target_width, fgcolor)
    local words = {}
    for word in text:gmatch("%S+") do table.insert(words, word) end
    if #words <= 1 then
        return TextWidget:new{ text = text, face = face, fgcolor = fgcolor }
    end
    local total_word_width = 0
    local word_widgets = {}
    for _, word in ipairs(words) do
        local tw = TextWidget:new{ text = word, face = face, fgcolor = fgcolor }
        total_word_width = total_word_width + tw:getSize().w
        table.insert(word_widgets, tw)
    end
    local available_space = target_width - total_word_width
    local gaps = #words - 1
    if gaps <= 0 or available_space <= 0 then
        for _, w in ipairs(word_widgets) do w:free() end
        return TextWidget:new{ text = text, face = face, fgcolor = fgcolor }
    end
    local space_per_gap = math.floor(available_space / gaps)
    local extra_space = available_space - (space_per_gap * gaps)
    local hg = HorizontalGroup:new{}
    for i, tw in ipairs(word_widgets) do
        table.insert(hg, tw)
        if i < #word_widgets then
            local gap = space_per_gap
            if extra_space > 0 then
                gap = gap + 1
                extra_space = extra_space - 1
            end
            table.insert(hg, HorizontalSpan:new{ width = gap })
        end
    end
    return hg
end
local StrikeoutLineWidget = InputContainer:extend{ width = nil, height = nil, y_offset = nil }
function StrikeoutLineWidget:init() self.dimen = Geom:new{ w = self.width, h = self.height } end
function StrikeoutLineWidget:paintTo(bb, x, y)
    bb:paintRect(x, y + (self.y_offset or math.floor(self.height / 2)), self.width, 2, Blitbuffer.COLOR_BLACK)
end
local UnderlineWidget = InputContainer:extend{ width = nil, height = nil }
function UnderlineWidget:init() self.dimen = Geom:new{ w = self.width, h = self.height } end
function UnderlineWidget:paintTo(bb, x, y)
    bb:paintRect(x, y + self.height - 2, self.width, 2, Blitbuffer.COLOR_BLACK)
end
local NoteItemWidget = InputContainer:extend{ width = nil, note = nil, show_parent = nil, is_last = false }
function NoteItemWidget:init()
    local h_margin = getHMargin()
    local text_margin = getTextMargin()
    local note_spacing = getNoteSpacing()
    local title_margin = getTitleMargin()
    local info_margin = getInfoMargin()
    local content_margin = getContentMargin()
    local inner_width = self.width - h_margin * 2
    self.dimen = Geom:new{ w = self.width, h = 0 }

    local content_font_size = getContentFontSize()
    local title_font_size = getTitleFontSize()
    local info_font_size = getInfoFontSize()
    local h_padding = Size.padding.default
    local content_width = inner_width - h_padding * 2
    local justify = getJustify()

    local title_text = self.note.book_title or "Unknown"

    local title_font = getTitleFont()
    local title_face = title_font and Font:getFace(title_font, title_font_size) or Font:getFace("cfont", title_font_size)
    local title_widget = TextBoxWidget:new{
        text = title_text, face = title_face,
        width = content_width, alignment = "left", bold = true,
    }

    local date_text = self:formatDate(self.note.datetime) or ""
    local drawer = self.note.drawer or "lighten"
    local style_name = getStyleName(drawer)
    local info_parts = {}
    if date_text ~= "" then table.insert(info_parts, date_text) end
    if self.note.chapter and self.note.chapter ~= "" then
        table.insert(info_parts, self.note.chapter)
    end
    local info_text = table.concat(info_parts, " | ")

    local info_font = getInfoFont()
    local info_face = info_font and Font:getFace(info_font, info_font_size) or Font:getFace("cfont", info_font_size)
    local date_widget = TextBoxWidget:new{
        text = info_text, face = info_face,
        width = content_width, alignment = "left",
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
    }

    local text_fgcolor = Blitbuffer.COLOR_BLACK
    local show_strikeout = drawer == "strikeout"
    local show_underline = drawer == "underscore"
    local no_background = isNoBackgroundStyle(drawer)

    local bg_color = Blitbuffer.COLOR_WHITE
    if drawer == "invert" then
        text_fgcolor = Blitbuffer.COLOR_WHITE
        bg_color = Blitbuffer.COLOR_BLACK
    elseif not no_background then
        bg_color = getHighlightColor(self.note.color)
    end

    local content_font = getContentFont()
    local content_face = content_font and Font:getFace(content_font, content_font_size) or Font:getFace("cfont", content_font_size)
    local text_content_width = content_width - text_margin * 2
    local line_width = text_content_width - Size.padding.small * 2

    local note_content = VerticalGroup:new{ align = "left" }
    if not self.is_first then
        table.insert(note_content, VerticalSpan:new{ width = note_spacing })
    end
    table.insert(note_content, LeftContainer:new{
        dimen = Geom:new{ w = inner_width, h = title_widget:getSize().h },
        HorizontalGroup:new{ HorizontalSpan:new{ width = h_padding }, title_widget },
    })
    table.insert(note_content, VerticalSpan:new{ width = title_margin })
    if info_text ~= "" then
        table.insert(note_content, LeftContainer:new{
            dimen = Geom:new{ w = inner_width, h = date_widget:getSize().h },
            HorizontalGroup:new{ HorizontalSpan:new{ width = h_padding }, date_widget },
        })
    end
    table.insert(note_content, VerticalSpan:new{ width = info_margin })

    -- Render highlight text with style
    if self.note.highlighted_text and self.note.highlighted_text ~= "" then
        local highlight_text = truncateText(self.note.highlighted_text, getTruncateWords())
        local lines = wrapText(highlight_text, content_face, line_width)
        local lines_group = VerticalGroup:new{ align = "left" }

        for i, line in ipairs(lines) do
            local line_widget
            if justify == true and i < #lines and #lines > 1 then
                line_widget = createJustifiedLine(line, content_face, line_width, text_fgcolor)
            else
                line_widget = TextWidget:new{
                    text = line, face = content_face, fgcolor = text_fgcolor,
                }
            end
            local line_size = line_widget:getSize()
            local v_pad = 1
            local h_pad = Size.padding.small
            local line_container

            if show_strikeout or show_underline then
                local OverlapGroup = require("ui/widget/overlapgroup")
                local total_h = line_size.h + v_pad * 2
                local total_w = line_size.w + h_pad * 2
                local overlap_items = {
                    CenterContainer:new{
                        dimen = Geom:new{ w = total_w, h = total_h },
                        line_widget,
                    },
                }
                if show_strikeout then
                    table.insert(overlap_items, StrikeoutLineWidget:new{
                        width = total_w, height = total_h,
                        y_offset = math.floor(total_h / 2),
                    })
                end
                if show_underline then
                    table.insert(overlap_items, UnderlineWidget:new{
                        width = total_w, height = total_h,
                    })
                end
                line_container = OverlapGroup:new{
                    dimen = Geom:new{ w = total_w, h = total_h },
                    unpack(overlap_items),
                }
            else
                line_container = FrameContainer:new{
                    padding = v_pad, padding_left = h_pad, padding_right = h_pad,
                    padding_top = v_pad, padding_bottom = v_pad,
                    margin = 0, bordersize = 0, background = bg_color,
                    line_widget,
                }
            end
            table.insert(lines_group, line_container)
        end

        table.insert(note_content, LeftContainer:new{
            dimen = Geom:new{ w = inner_width, h = lines_group:getSize().h },
            HorizontalGroup:new{ HorizontalSpan:new{ width = h_padding + text_margin }, lines_group },
        })
    end

    -- Render note text with pen icon (using bookmark-style pencil character)
    if self.note.user_note and self.note.user_note ~= "" then
        table.insert(note_content, VerticalSpan:new{ width = Screen:scaleBySize(8) })

        local note_icon_char = "\u{F040}" -- Font Awesome pencil icon (same as bookmark note prefix)
        local icon_margin = Screen:scaleBySize(6)
        local note_icon = TextWidget:new{
            text = note_icon_char,
            face = content_face,
            fgcolor = Blitbuffer.COLOR_BLACK,
        }
        local icon_size = note_icon:getSize().w

        -- Calculate text width accounting for icon and margin
        local note_text_width = line_width - icon_size - icon_margin
        local note_lines = wrapText(self.note.user_note, content_face, note_text_width)
        local note_text_group = VerticalGroup:new{ align = "left" }
        for _, line in ipairs(note_lines) do
            local line_widget = TextWidget:new{
                text = line, face = content_face, fgcolor = Blitbuffer.COLOR_BLACK,
            }
            table.insert(note_text_group, line_widget)
        end

        -- Icon on left, text on right
        local note_row = HorizontalGroup:new{
            note_icon,
            HorizontalSpan:new{ width = icon_margin },
            note_text_group,
        }
        table.insert(note_content, LeftContainer:new{
            dimen = Geom:new{ w = inner_width, h = note_row:getSize().h },
            HorizontalGroup:new{ HorizontalSpan:new{ width = h_padding + text_margin }, note_row },
        })
    end

    table.insert(note_content, VerticalSpan:new{ width = content_margin })

    table.insert(note_content, VerticalSpan:new{ width = note_spacing })
    local separator = LineWidget:new{
        dimen = Geom:new{ w = inner_width, h = Size.line.thin },
        background = getShowSeparator() == true and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE,
    }
    table.insert(note_content, CenterContainer:new{
        dimen = Geom:new{ w = inner_width, h = separator:getSize().h },
        separator,
    })

    self.dimen.h = note_content:getSize().h
    self[1] = HorizontalGroup:new{
        HorizontalSpan:new{ width = h_margin }, note_content, HorizontalSpan:new{ width = h_margin },
    }
    self.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = self.dimen } } }
end
function NoteItemWidget:formatDate(datetime)
    if not datetime or datetime == "" then return nil end
    local year, month, day = datetime:match("(%d+)-(%d+)-(%d+)")
    if not year then return datetime end
    local note_time = os.time({year = tonumber(year), month = tonumber(month), day = tonumber(day)})
    local today_start = os.time({year = os.date("*t").year, month = os.date("*t").month, day = os.date("*t").day})
    if note_time >= today_start then return "Today"
    elseif note_time >= today_start - 86400 then return "Yesterday"
    else return os.date("%d %b %Y", note_time) end
end
function NoteItemWidget:onTap()
    if self.show_parent and self.show_parent.onNoteSelected then
        self.show_parent:onNoteSelected(self.note)
    end
    return true
end
local NotesListWidget = InputContainer:extend{
    width = nil, height = nil, notes_list = nil, filtered_notes = nil,
    viewer = nil, current_page = 1, pages = nil, active_filter = nil,
}
function NotesListWidget:init()
    self.width = Screen:getWidth()
    self.height = Screen:getHeight()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    -- Get actual titlebar height from a temp TitleBar with same settings
    local temp_title = TitleBar:new{
        title = "temp",
        width = self.width,
        fullscreen = true,
        with_bottom_line = false,
        title_top_padding = Screen:scaleBySize(10),
        bottom_v_padding = 0,
        left_icon_size_ratio = 1,
        right_icon_size_ratio = 1,
        button_padding = Screen:scaleBySize(5),
        left_icon = "appbar.menu",
        close_callback = function() end,
    }
    self.title_height = temp_title:getHeight()
    -- Create temp page_info to get actual height like KeyValuePage
    local temp_button = Button:new{ icon = "chevron.first", bordersize = 0 }
    self.footer_height = temp_button:getSize().h
    temp_button:free()
    self.content_height = self.height - self.title_height - self.footer_height - getVMargin() * 2 - getTopPadding()
    self:applyFilter()
    self:calculatePages()
    self:updatePage()
    if Device:hasKeys() then
        self.key_events = {
            ReadPrevItem = { { "Up" }, event = "GotoPrevPage" },
            ReadNextItem = { { "Down" }, event = "GotoNextPage" },
            GotoPrevPage = { { Device.input.group.PgBack }, event = "GotoPrevPage" },
            GotoNextPage = { { Device.input.group.PgFwd }, event = "GotoNextPage" },
            Close = { { Device.input.group.Back }, event = "Close" },
        }
    end
    if not G_reader_settings:isTrue("page_turns_disable_swipe") then
        self.ges_events = { Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } } }
    end
end
function NotesListWidget:applyFilter()
    self.filtered_notes = {}
    for _, note in ipairs(self.notes_list) do
        local match = true
        if self.active_filter then
            if self.active_filter.type == "color" then
                match = note.color and note.color:lower() == self.active_filter.value
            elseif self.active_filter.type == "style" then
                match = note.drawer and note.drawer:lower() == self.active_filter.value
            end
        end
        if match then table.insert(self.filtered_notes, note) end
    end
end
function NotesListWidget:calculatePages()
    self.pages = {}
    local current_page_notes, current_height = {}, 0
    for i, note in ipairs(self.filtered_notes) do
        local temp_widget = NoteItemWidget:new{ width = self.width, note = note, show_parent = self }
        local item_height = temp_widget.dimen.h
        if current_height + item_height <= self.content_height then
            table.insert(current_page_notes, i)
            current_height = current_height + item_height
        else
            if #current_page_notes > 0 then table.insert(self.pages, current_page_notes) end
            current_page_notes = {i}
            current_height = item_height
        end
    end
    if #current_page_notes > 0 then table.insert(self.pages, current_page_notes) end
    if #self.pages == 0 then self.pages = {{}} end
    self.total_pages = #self.pages
end
function NotesListWidget:createFooter()
    local RightContainer = require("ui/widget/container/rightcontainer")
    local chevron_left = "chevron.left"
    local chevron_right = "chevron.right"
    local chevron_first = "chevron.first"
    local chevron_last = "chevron.last"
    if BD.mirroredUILayout() then
        chevron_left, chevron_right = chevron_right, chevron_left
        chevron_first, chevron_last = chevron_last, chevron_first
    end

    self.page_info_first_chev = Button:new{
        icon = chevron_first,
        callback = function() self.current_page = 1; self:updatePage() end,
        bordersize = 0,
        show_parent = self,
    }
    self.page_info_left_chev = Button:new{
        icon = chevron_left,
        callback = function() self:onGotoPrevPage() end,
        bordersize = 0,
        show_parent = self,
    }
    self.page_info_text = Button:new{
        text = string.format("%d / %d", self.current_page, self.total_pages),
        text_font_bold = false,
        text_font_face = "pgfont",
        bordersize = 0,
        show_parent = self,
    }
    self.page_info_right_chev = Button:new{
        icon = chevron_right,
        callback = function() self:onGotoNextPage() end,
        bordersize = 0,
        show_parent = self,
    }
    self.page_info_last_chev = Button:new{
        icon = chevron_last,
        callback = function() self.current_page = self.total_pages; self:updatePage() end,
        bordersize = 0,
        show_parent = self,
    }

    self.page_info_first_chev:enableDisable(self.current_page > 1)
    self.page_info_left_chev:enableDisable(self.current_page > 1)
    self.page_info_right_chev:enableDisable(self.current_page < self.total_pages)
    self.page_info_last_chev:enableDisable(self.current_page < self.total_pages)

    self.page_info = HorizontalGroup:new{
        self.page_info_first_chev,
        self.page_info_left_chev,
        self.page_info_text,
        self.page_info_right_chev,
        self.page_info_last_chev,
    }

    -- ProjectTitle style: 98% width RightContainer inside BottomContainer
    local page_info_container = RightContainer:new{
        dimen = Geom:new{ w = math.floor(self.width * 0.98), h = self.page_info:getSize().h },
        self.page_info,
    }

    return BottomContainer:new{
        dimen = Geom:new{ w = self.width, h = self.height },
        page_info_container,
    }
end
function NotesListWidget:updatePage()
    local v_margin = getVMargin()
    local filter_text = ""
    if self.active_filter then
        if self.active_filter.type == "color" then
            filter_text = " [" .. getColorName(self.active_filter.value) .. "]"
        else
            filter_text = " [" .. getStyleName(self.active_filter.value) .. "]"
        end
    end
    
    local title_text
    if getShowTotalNotes() == true then
        title_text = string.format(_("Annotations (%d)%s"), #self.filtered_notes, filter_text)
    else
        title_text = _("Annotations") .. filter_text
    end
    
    -- TitleBar with adjusted padding for proper height
    local title_bar = TitleBar:new{
        title = title_text,
        fullscreen = true,
        width = self.width,
        with_bottom_line = false,
        title_top_padding = Screen:scaleBySize(10),
        bottom_v_padding = 0,
        left_icon_size_ratio = 1,
        right_icon_size_ratio = 1,
        button_padding = Screen:scaleBySize(5),
        close_callback = function() self:onClose() end,
        left_icon = "appbar.menu",
        left_icon_tap_callback = function() self:showMainMenu() end,
        show_parent = self,
    }

    local notes_group = VerticalGroup:new{ align = "left" }
    local top_padding = getTopPadding()
    if top_padding > 0 then
        table.insert(notes_group, VerticalSpan:new{ width = top_padding })
    end
    table.insert(notes_group, VerticalSpan:new{ width = v_margin })
    local page_indices = self.pages[self.current_page] or {}
        for i, idx in ipairs(page_indices) do
            local note = self.filtered_notes[idx]
            if note then
                local is_last = (i == #page_indices)
                local is_first = (i == 1)
                table.insert(notes_group, NoteItemWidget:new{ width = self.width, note = note, show_parent = self, is_last = is_last, is_first = is_first })
            end
    end
    table.insert(notes_group, VerticalSpan:new{ width = v_margin })
    
    local footer = self:createFooter()
    
    local content = OverlapGroup:new{
        allow_mirroring = false,
        dimen = Geom:new{ w = self.width, h = self.height },
        VerticalGroup:new{
            align = "left",
            title_bar,
            TopContainer:new{ dimen = Geom:new{ w = self.width, h = self.content_height + v_margin * 2 + getTopPadding() }, notes_group },
        },
        footer,
    }

    self[1] = FrameContainer:new{
        width = self.width, height = self.height, padding = 0, margin = 0, bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        content,
    }
    UIManager:setDirty(self, "ui")
end
function NotesListWidget:showMainMenu()
    local buttons = {
        {{ text = _("Filter"), callback = function()
            UIManager:close(self.main_menu)
            self:showFilterMenu()
        end }},
        {{ text = _("Settings"), callback = function()
            UIManager:close(self.main_menu)
            self:showSettingsMenu()
        end }},
        {{ text = _("Cancel"), callback = function() UIManager:close(self.main_menu) end }},
    }
    self.main_menu = ButtonDialogTitle:new{ title = _("Menu"), buttons = buttons }
    UIManager:show(self.main_menu)
end
function NotesListWidget:showSettingsMenu()
    local show_sep = getShowSeparator()
    local sep_text = show_sep == true and "On" or "Off"
    local justify_text = getJustify() == true and "On" or "Off"
    local show_total_text = getShowTotalNotes() == true and "On" or "Off"
    
    local buttons = {
        {{ text = _("Font Sizes..."), callback = function()
            UIManager:close(self.settings_dialog)
            self:showFontSizeMenu()
        end }},
        {{ text = _("Fonts..."), callback = function()
            UIManager:close(self.settings_dialog)
            self:showFontsMenu()
        end }},
        {{ text = _("Section Margins..."), callback = function()
            UIManager:close(self.settings_dialog)
            self:showSectionMarginMenu()
        end }},
        {{ text = _("Margins..."), callback = function()
            UIManager:close(self.settings_dialog)
            self:showMarginMenu()
        end }},
        {{ text = _("Truncate Words: ") .. getTruncateWords(), callback = function()
            UIManager:close(self.settings_dialog)
            self:showSpinSetting(_("Truncate Words"), "truncate_words", DEFAULT_TRUNCATE_WORDS, 10, 200, 10, function() self:showSettingsMenu() end)
        end }},
        {{ text = _("Justify Text: ") .. justify_text, callback = function()
            UIManager:close(self.settings_dialog)
            setSetting("justify", not (getJustify() == true))
            self:refresh()
            self:showSettingsMenu()
        end }},
        {{ text = _("Note Separator: ") .. sep_text, callback = function()
            UIManager:close(self.settings_dialog)
            setSetting("show_separator", not (show_sep == true))
            self:refresh()
            self:showSettingsMenu()
        end }},
        {{ text = _("Show Total: ") .. show_total_text, callback = function()
            UIManager:close(self.settings_dialog)
            setSetting("show_total", not (getShowTotalNotes() == true))
            self:refresh()
            self:showSettingsMenu()
        end }},
        {{ text = _("Back"), callback = function()
            UIManager:close(self.settings_dialog)
            self:showMainMenu()
        end }},
    }
    self.settings_dialog = ButtonDialogTitle:new{ title = _("Settings"), buttons = buttons }
    UIManager:show(self.settings_dialog)
end
function NotesListWidget:showFontSizeMenu()
    local buttons = {
        {{ text = _("Title Size: ") .. getTitleFontSize(), callback = function()
            UIManager:close(self.font_size_dialog)
            self:showSpinSetting(_("Title Font Size"), "title_font_size", DEFAULT_TITLE_FONT_SIZE, 8, 48, 1, function() self:showFontSizeMenu() end)
        end }},
        {{ text = _("Info Size: ") .. getInfoFontSize(), callback = function()
            UIManager:close(self.font_size_dialog)
            self:showSpinSetting(_("Info Font Size"), "info_font_size", DEFAULT_INFO_FONT_SIZE, 8, 48, 1, function() self:showFontSizeMenu() end)
        end }},
        {{ text = _("Content Size: ") .. getContentFontSize(), callback = function()
            UIManager:close(self.font_size_dialog)
            self:showSpinSetting(_("Content Font Size"), "content_font_size", DEFAULT_CONTENT_FONT_SIZE, 8, 48, 1, function() self:showFontSizeMenu() end)
        end }},
        {{ text = _("Back"), callback = function()
            UIManager:close(self.font_size_dialog)
            self:showSettingsMenu()
        end }},
    }
    self.font_size_dialog = ButtonDialogTitle:new{ title = _("Font Sizes"), buttons = buttons }
    UIManager:show(self.font_size_dialog)
end
function NotesListWidget:showFontsMenu()
    local function getAvailableFonts()
        local fonts = {}
        local seen = {}
        local font_list = FontList:getFontList()
        for _, font_path in ipairs(font_list) do
            local font_name = font_path:match("([^/\\]+)$") or font_path
            if not seen[font_name] then
                seen[font_name] = true
                table.insert(fonts, { name = font_name, path = font_path })
            end
        end
        table.sort(fonts, function(a, b) return a.name:lower() < b.name:lower() end)
        return fonts
    end
    local function getFontDisplayName(font_path)
        if not font_path or font_path == "" then return "Default" end
        return font_path:match("([^/\\]+)$") or font_path
    end
    local function showFontPicker(title, setting_key, current_value, back_callback)
        local Menu = require("ui/widget/menu")
        local available_fonts = getAvailableFonts()
        local menu_items = {}
        table.insert(menu_items, {
            text = (current_value == nil or current_value == "") and "✓ Default" or "   Default",
            callback = function()
                setSetting(setting_key, nil)
                self:refresh()
                UIManager:close(self.font_picker_menu)
                if back_callback then back_callback() end
            end,
        })
        for _, font in ipairs(available_fonts) do
            local is_selected = current_value == font.path
            local check = is_selected and "✓ " or "   "
            table.insert(menu_items, {
                text = check .. font.name,
                callback = function()
                    setSetting(setting_key, font.path)
                    self:refresh()
                    UIManager:close(self.font_picker_menu)
                    if back_callback then back_callback() end
                end,
            })
        end
        self.font_picker_menu = Menu:new{
            title = title,
            item_table = menu_items,
            width = Screen:getWidth() - Screen:scaleBySize(20),
            height = Screen:getHeight(),
            single_line = true,
            items_per_page = 14,
            close_callback = function()
                UIManager:close(self.font_picker_menu)
            end,
        }
        UIManager:show(self.font_picker_menu)
    end
    local buttons = {
        {{ text = _("Title Font: ") .. getFontDisplayName(getTitleFont()), callback = function()
            UIManager:close(self.fonts_dialog)
            showFontPicker(_("Select Title Font"), "title_font", getTitleFont(), function() self:showFontsMenu() end)
        end }},
        {{ text = _("Info Font: ") .. getFontDisplayName(getInfoFont()), callback = function()
            UIManager:close(self.fonts_dialog)
            showFontPicker(_("Select Info Font"), "info_font", getInfoFont(), function() self:showFontsMenu() end)
        end }},
        {{ text = _("Content Font: ") .. getFontDisplayName(getContentFont()), callback = function()
            UIManager:close(self.fonts_dialog)
            showFontPicker(_("Select Content Font"), "content_font", getContentFont(), function() self:showFontsMenu() end)
        end }},
        {{ text = _("Back"), callback = function()
            UIManager:close(self.fonts_dialog)
            self:showSettingsMenu()
        end }},
    }
    self.fonts_dialog = ButtonDialogTitle:new{ title = _("Fonts"), buttons = buttons }
    UIManager:show(self.fonts_dialog)
end
function NotesListWidget:showSectionMarginMenu()
    local buttons = {
        {{ text = _("After Title: ") .. getSetting("title_margin", DEFAULT_TITLE_MARGIN), callback = function()
            UIManager:close(self.section_margin_dialog)
            self:showSpinSetting(_("Margin After Title"), "title_margin", DEFAULT_TITLE_MARGIN, 0, 30, 1, function() self:showSectionMarginMenu() end)
        end }},
        {{ text = _("After Info: ") .. getSetting("info_margin", DEFAULT_INFO_MARGIN), callback = function()
            UIManager:close(self.section_margin_dialog)
            self:showSpinSetting(_("Margin After Info"), "info_margin", DEFAULT_INFO_MARGIN, 0, 30, 1, function() self:showSectionMarginMenu() end)
        end }},
        {{ text = _("After Content: ") .. getSetting("content_margin", DEFAULT_CONTENT_MARGIN), callback = function()
            UIManager:close(self.section_margin_dialog)
            self:showSpinSetting(_("Margin After Content"), "content_margin", DEFAULT_CONTENT_MARGIN, 0, 30, 1, function() self:showSectionMarginMenu() end)
        end }},
        {{ text = _("Back"), callback = function()
            UIManager:close(self.section_margin_dialog)
            self:showSettingsMenu()
        end }},
    }
    self.section_margin_dialog = ButtonDialogTitle:new{ title = _("Section Margins"), buttons = buttons }
    UIManager:show(self.section_margin_dialog)
end
function NotesListWidget:showMarginMenu()
    local buttons = {
        {{ text = _("Top Padding: ") .. getSetting("top_padding", DEFAULT_TOP_PADDING), callback = function()
            UIManager:close(self.margin_dialog)
            self:showSpinSetting(_("Top Padding"), "top_padding", DEFAULT_TOP_PADDING, 0, 100, 5, function() self:showMarginMenu() end)
        end }},
        {{ text = _("Horizontal Margin: ") .. getSetting("h_margin", DEFAULT_H_MARGIN), callback = function()
            UIManager:close(self.margin_dialog)
            self:showSpinSetting(_("Horizontal Margin"), "h_margin", DEFAULT_H_MARGIN, 5, 60, 5, function() self:showMarginMenu() end)
        end }},
        {{ text = _("Vertical Margin: ") .. getSetting("v_margin", DEFAULT_V_MARGIN), callback = function()
            UIManager:close(self.margin_dialog)
            self:showSpinSetting(_("Vertical Margin"), "v_margin", DEFAULT_V_MARGIN, 5, 40, 5, function() self:showMarginMenu() end)
        end }},
        {{ text = _("Note Spacing: ") .. getSetting("note_spacing", DEFAULT_NOTE_SPACING), callback = function()
            UIManager:close(self.margin_dialog)
            self:showSpinSetting(_("Note Spacing"), "note_spacing", DEFAULT_NOTE_SPACING, 5, 100, 2, function() self:showMarginMenu() end)
        end }},
        {{ text = _("Text Margin: ") .. getSetting("text_margin", DEFAULT_TEXT_MARGIN), callback = function()
            UIManager:close(self.margin_dialog)
            self:showSpinSetting(_("Text Margin"), "text_margin", DEFAULT_TEXT_MARGIN, 0, 30, 2, function() self:showMarginMenu() end)
        end }},
        {{ text = _("Back"), callback = function()
            UIManager:close(self.margin_dialog)
            self:showSettingsMenu()
        end }},
    }
    self.margin_dialog = ButtonDialogTitle:new{ title = _("Margins"), buttons = buttons }
    UIManager:show(self.margin_dialog)
end
function NotesListWidget:showSpinSetting(title, key, default, min, max, step, back_callback)
    UIManager:show(SpinWidget:new{
        title_text = title,
        value = getSetting(key, default), value_min = min, value_max = max, value_step = step,
        default_value = default, ok_text = _("Set"),
        callback = function(spin)
            setSetting(key, spin.value)
            self:refresh()
            if back_callback then back_callback() end
        end,
        cancel_callback = function()
            if back_callback then back_callback() end
        end,
    })
end
function NotesListWidget:showFilterMenu()
    local RadioButtonWidget = require("ui/widget/radiobuttonwidget")
    local colors, styles = {}, {}
    for _, note in ipairs(self.notes_list) do
        if note.color then colors[note.color:lower()] = true end
        if note.drawer then styles[note.drawer:lower()] = true end
    end
    local color_map = {
        { "yellow", _("Yellow"), "#FFFF00" },
        { "green", _("Green"), "#00FF00" },
        { "blue", _("Blue"), "#0000FF" },
        { "pink", _("Pink"), "#FF00FF" },
        { "orange", _("Orange"), "#FFA500" },
        { "red", _("Red"), "#FF0000" },
        { "cyan", _("Cyan"), "#00FFFF" },
        { "purple", _("Purple"), "#800080" },
        { "gray", _("Gray"), "#808080" },
    }
    local radio_buttons = {}
    local curr_type = self.active_filter and self.active_filter.type or nil
    local curr_val = self.active_filter and self.active_filter.value or nil
    -- Add style options
    for style, _ in pairs(styles) do
        local name = getStyleName(style)
        table.insert(radio_buttons, {
            { text = name or style, checked = curr_type == "style" and curr_val == style,
              provider = { type = "style", value = style } },
        })
    end
    -- Add color options with actual colors
    for _, c in ipairs(color_map) do
        if colors[c[1]] then
            table.insert(radio_buttons, {
                { text = c[2], checked = curr_type == "color" and curr_val == c[1],
                  bgcolor = Blitbuffer.colorFromString(c[3]),
                  provider = { type = "color", value = c[1] } },
            })
        end
    end
    -- Add clear option
    table.insert(radio_buttons, {
        { text = _("Clear Filter"), checked = curr_type == nil, provider = nil },
    })
    UIManager:show(RadioButtonWidget:new{
        title_text = _("Filter Annotations"),
        width_factor = 0.6,
        radio_buttons = radio_buttons,
        callback = function(radio)
            self.active_filter = radio.provider
            self:refresh()
        end,
        colorful = true,
        dithered = true,
    })
end
function NotesListWidget:refresh()
    self.content_height = self.height - self.title_height - self.footer_height - getVMargin() * 2 - getTopPadding()
    self.current_page = 1
    self:applyFilter()
    self:calculatePages()
    self:updatePage()
end
function NotesListWidget:onGotoNextPage()
    if self.current_page < self.total_pages then
        self.current_page = self.current_page + 1
    else
        self.current_page = 1
    end
    self:updatePage()
    return true
end
function NotesListWidget:onGotoPrevPage()
    if self.current_page > 1 then
        self.current_page = self.current_page - 1
    else
        self.current_page = self.total_pages
    end
    self:updatePage()
    return true
end
function NotesListWidget:onSwipe(_, ges)
    if ges.direction == "west" then return self:onGotoNextPage()
    elseif ges.direction == "east" then return self:onGotoPrevPage()
    end
end
function NotesListWidget:onNoteSelected(note) self.viewer:showNoteDetails(note, self) end
function NotesListWidget:onClose() UIManager:close(self) return true end
local AllNotesViewer = WidgetContainer:extend{ name = "allnotesviewer", is_doc_only = false }
AllNotesViewer.is_doc_only = false
function AllNotesViewer:init()
    local Dispatcher = require("dispatcher")
    Dispatcher:registerAction("show_all_annotations", {
        category = "none",
        event = "ShowAllAnnotations",
        title = _("Show all annotations"),
        filemanager = true,
    })
    if not self.ui.document then -- FileManager only, not Reader
        self.ui.menu:registerToMainMenu(self)
    end
end
function AllNotesViewer:onShowAllAnnotations()
    self:showAllNotes()
end
function AllNotesViewer:addToMainMenu(menu_items)
    menu_items.all_notes_viewer = {
        text = _("Annotations"),
        sorting_hint = "filemanager_settings",
        callback = function() self:showAllNotes() end,
    }
end
function AllNotesViewer:loadBookAnnotations(book_path)
    local annotations = {}
    if not book_path then return annotations end
    local ok, doc_settings = pcall(DocSettings.open, DocSettings, book_path)
    if not ok or not doc_settings then return annotations end
    local data = doc_settings.data
    if not data then return annotations end
    
    local items = data.annotations
    if items and #items > 0 then
        for _, item in ipairs(items) do
            if item.drawer then
                local has_highlight = item.text and item.text ~= ""
                local has_note = item.note and item.note ~= ""
                if has_highlight or has_note then
                    table.insert(annotations, {
                        page = item.page or item.pageno or 0, pos0 = item.pos0, pos1 = item.pos1,
                        chapter = item.chapter or "", text = item.text or "", notes = item.note or "",
                        datetime = item.datetime or "", drawer = item.drawer, color = item.color or "yellow",
                    })
                end
            end
        end
    else
        local highlights = data.highlight or {}
        for page, page_highlights in pairs(highlights) do
            if type(page_highlights) == "table" then
                for _, hl in ipairs(page_highlights) do
                    if hl.drawer then
                        local has_highlight = hl.text and hl.text ~= ""
                        local has_note = hl.note and hl.note ~= ""
                        if has_highlight or has_note then
                            table.insert(annotations, {
                                page = tonumber(page) or 0, pos0 = hl.pos0, pos1 = hl.pos1,
                                chapter = hl.chapter or "", text = hl.text or "", notes = hl.note or "",
                                datetime = hl.datetime or "", drawer = hl.drawer, color = hl.color or "yellow",
                            })
                        end
                    end
                end
            end
        end
    end
    table.sort(annotations, function(a, b) return (a.datetime or "") > (b.datetime or "") end)
    return annotations
end
function AllNotesViewer:getBookInfo(book_path)
    local ok, doc_settings = pcall(DocSettings.open, DocSettings, book_path)
    local data = ok and doc_settings and doc_settings.data or {}
    local filename = book_path:match("([^/\\]+)$") or book_path
    local title = data.doc_props and data.doc_props.title
    local authors = data.doc_props and data.doc_props.authors
    if not title or title == "" then title = filename:gsub("%.[^.]+$", "") end
    return { path = book_path, filename = filename, title = title or filename, authors = authors or "Unknown" }
end
function AllNotesViewer:findAllNotes()
    local notes_data = {}
    local history = ReadHistory.hist
    if not history then return notes_data end
    for _, item in ipairs(history) do
        local book_path = item.file
        if book_path and lfs.attributes(book_path, "mode") then
            local annotations = self:loadBookAnnotations(book_path)
            if #annotations > 0 then
                local book_info = self:getBookInfo(book_path)
                table.insert(notes_data, {
                    path = book_path, filename = book_info.filename,
                    title = book_info.title, authors = book_info.authors, notes = annotations,
                })
            end
        end
    end
    return notes_data
end
function AllNotesViewer:showAllNotes()
    local all_notes_by_book = self:findAllNotes()
    local notes_list = {}
    for _, book_data in ipairs(all_notes_by_book) do
        for _, note in ipairs(book_data.notes) do
            table.insert(notes_list, {
                book_title = book_data.title, book_authors = book_data.authors,
                book_path = book_data.path, page = note.page, chapter = note.chapter,
                pos0 = note.pos0, pos1 = note.pos1,
                highlighted_text = note.text, user_note = note.notes,
                datetime = note.datetime, drawer = note.drawer, color = note.color,
            })
        end
    end
    if #notes_list == 0 then
        UIManager:show(InfoMessage:new{ text = _("No annotations found.") })
        return
    end
    table.sort(notes_list, function(a, b) return (a.datetime or "") > (b.datetime or "") end)
    UIManager:show(NotesListWidget:new{ notes_list = notes_list, viewer = self })
end
function AllNotesViewer:showNoteDetails(note, parent_widget)
    -- Icon prefixes matching KOReader bookmark details
    local ICON_HIGHLIGHT = "\u{2592}\u{2002}" -- medium shade + en space
    local ICON_NOTE = "\u{F040}\u{2002}" -- pencil + en space

    local text_parts = {}
    if note.highlighted_text and note.highlighted_text ~= "" then
        table.insert(text_parts, ICON_HIGHLIGHT .. note.highlighted_text)
    end
    if note.user_note and note.user_note ~= "" then
        if #text_parts > 0 then
            table.insert(text_parts, "\n\n")
        end
        table.insert(text_parts, ICON_NOTE .. note.user_note)
    end

    local title = note.book_title or _("Annotation")
    local book_exists = note.book_path and lfs.attributes(note.book_path, "mode") ~= nil
    local has_note = note.user_note and note.user_note ~= ""
    local goto_text = has_note and _("Go to Note") or _("Go to Highlight")
    local edit_text = has_note and _("Edit Note") or _("Add Note")
    local popup
    local buttons = {}
    if book_exists then
        table.insert(buttons, { text = goto_text, callback = function()
            UIManager:close(popup)
            UIManager:close(parent_widget)
            self:openBookAtNote(note)
        end })
    end
    table.insert(buttons, { text = edit_text, callback = function()
        UIManager:close(popup)
        self:editNote(note, parent_widget)
    end })
    table.insert(buttons, { text = _("Style"), callback = function()
        UIManager:close(popup)
        self:showStyleMenu(note, parent_widget)
    end })
    table.insert(buttons, { text = _("Delete"), callback = function()
        UIManager:close(popup)
        self:confirmDelete(note, parent_widget)
    end })
    table.insert(buttons, { text = _("Close"), callback = function() UIManager:close(popup) end })
    
    popup = TextViewer:new{
        title = title, text = table.concat(text_parts, ""),
        width = Screen:getWidth() - Size.margin.fullscreen_popout * 8,
        height = Screen:getHeight() * 0.7,
        buttons_table = { buttons },
    }
    UIManager:show(popup)
end
function AllNotesViewer:showStyleMenu(note, parent_widget)
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    dialog = ButtonDialog:new{
        title = _("Highlight Style"),
        buttons = {
            {
                { text = _("Change Style"), callback = function()
                    UIManager:close(dialog)
                    self:showStylePicker(note, parent_widget)
                end },
            },
            {
                { text = _("Change Color"), callback = function()
                    UIManager:close(dialog)
                    self:showColorPicker(note, parent_widget)
                end },
            },
            {
                { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
            },
        },
    }
    UIManager:show(dialog)
end
function AllNotesViewer:showStylePicker(note, parent_widget)
    local ButtonDialog = require("ui/widget/buttondialog")
    local styles = {
        { _("Lighten"), "lighten" },
        { _("Underline"), "underscore" },
        { _("Strikethrough"), "strikeout" },
        { _("Invert"), "invert" },
    }
    local buttons = {}
    for _, style in ipairs(styles) do
        table.insert(buttons, {
            { text = style[1] .. (note.drawer == style[2] and "  ✓" or ""),
              callback = function()
                  UIManager:close(dialog)
                  self:updateHighlightStyle(note, style[2], parent_widget)
              end },
        })
    end
    table.insert(buttons, { { text = _("Cancel"), callback = function() UIManager:close(dialog) end } })
    dialog = ButtonDialog:new{ title = _("Select Style"), buttons = buttons }
    UIManager:show(dialog)
end
function AllNotesViewer:showColorPicker(note, parent_widget)
    local RadioButtonWidget = require("ui/widget/radiobuttonwidget")
    local curr_color = note.color or "yellow"
    local colors = {
        { "yellow", _("Yellow"), "#FFFF00" },
        { "green", _("Green"), "#00FF00" },
        { "blue", _("Blue"), "#0000FF" },
        { "pink", _("Pink"), "#FF00FF" },
        { "orange", _("Orange"), "#FFA500" },
        { "red", _("Red"), "#FF0000" },
        { "cyan", _("Cyan"), "#00FFFF" },
        { "purple", _("Purple"), "#800080" },
        { "gray", _("Gray"), "#808080" },
    }
    local radio_buttons = {}
    for _, c in ipairs(colors) do
        table.insert(radio_buttons, {
            { text = c[2], checked = curr_color == c[1],
              bgcolor = Blitbuffer.colorFromString(c[3]), provider = c[1] },
        })
    end
    UIManager:show(RadioButtonWidget:new{
        title_text = _("Select Color"),
        width_factor = 0.6,
        radio_buttons = radio_buttons,
        default_provider = curr_color,
        callback = function(radio)
            self:updateHighlightColor(note, radio.provider, parent_widget)
        end,
        colorful = true,
        dithered = true,
    })
end
function AllNotesViewer:updateHighlightStyle(note, new_style, parent_widget)
    if not note.book_path then return end
    local ok, doc_settings = pcall(DocSettings.open, DocSettings, note.book_path)
    if not ok or not doc_settings then return end
    local data = doc_settings.data
    if not data then return end
    local updated = false
    -- Try to update in annotations array first
    local items = data.annotations
    if items and #items > 0 then
        for _, item in ipairs(items) do
            if item.datetime == note.datetime and item.text == note.highlighted_text then
                item.drawer = new_style
                updated = true
                break
            end
        end
    end
    -- If not found in annotations, try highlight table
    if not updated then
        local highlights = data.highlight or {}
        for _, page_highlights in pairs(highlights) do
            if type(page_highlights) == "table" then
                for _, hl in ipairs(page_highlights) do
                    if hl.datetime == note.datetime and hl.text == note.highlighted_text then
                        hl.drawer = new_style
                        updated = true
                        break
                    end
                end
            end
            if updated then break end
        end
    end
    if updated then
        doc_settings:flush()
        -- Update in current notes list
        for _, n in ipairs(parent_widget.notes_list) do
            if n.datetime == note.datetime and n.highlighted_text == note.highlighted_text then
                n.drawer = new_style
                break
            end
        end
        parent_widget:refresh()
        UIManager:show(require("ui/widget/infomessage"):new{ text = _("Style updated."), timeout = 1 })
    end
end
function AllNotesViewer:updateHighlightColor(note, new_color, parent_widget)
    if not note.book_path then return end
    local ok, doc_settings = pcall(DocSettings.open, DocSettings, note.book_path)
    if not ok or not doc_settings then return end
    local data = doc_settings.data
    if not data then return end
    local updated = false
    -- Try to update in annotations array first
    local items = data.annotations
    if items and #items > 0 then
        for _, item in ipairs(items) do
            if item.datetime == note.datetime and item.text == note.highlighted_text then
                item.color = new_color
                updated = true
                break
            end
        end
    end
    -- If not found in annotations, try highlight table
    if not updated then
        local highlights = data.highlight or {}
        for _, page_highlights in pairs(highlights) do
            if type(page_highlights) == "table" then
                for _, hl in ipairs(page_highlights) do
                    if hl.datetime == note.datetime and hl.text == note.highlighted_text then
                        hl.color = new_color
                        updated = true
                        break
                    end
                end
            end
            if updated then break end
        end
    end
    if updated then
        doc_settings:flush()
        -- Update in current notes list
        for _, n in ipairs(parent_widget.notes_list) do
            if n.datetime == note.datetime and n.highlighted_text == note.highlighted_text then
                n.color = new_color
                break
            end
        end
        parent_widget:refresh()
        UIManager:show(require("ui/widget/infomessage"):new{ text = _("Color updated."), timeout = 1 })
    end
end
function AllNotesViewer:confirmDelete(note, parent_widget)
    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text = _("Delete this annotation?"),
        ok_text = _("Delete"),
        ok_callback = function()
            self:deleteAnnotation(note, parent_widget)
        end,
    })
end
function AllNotesViewer:deleteAnnotation(note, parent_widget)
    if not note.book_path then return end
    local ok, doc_settings = pcall(DocSettings.open, DocSettings, note.book_path)
    if not ok or not doc_settings then return end
    local data = doc_settings.data
    if not data then return end
    local deleted = false
    -- Try to delete from annotations array first
    local items = data.annotations
    if items and #items > 0 then
        for i = #items, 1, -1 do
            local item = items[i]
            if item.datetime == note.datetime and item.text == note.highlighted_text then
                table.remove(items, i)
                deleted = true
                break
            end
        end
    end
    -- If not found in annotations, try highlight table
    if not deleted then
        local highlights = data.highlight or {}
        for page, page_highlights in pairs(highlights) do
            if type(page_highlights) == "table" then
                for i = #page_highlights, 1, -1 do
                    local hl = page_highlights[i]
                    if hl.datetime == note.datetime and hl.text == note.highlighted_text then
                        table.remove(page_highlights, i)
                        deleted = true
                        break
                    end
                end
            end
            if deleted then break end
        end
    end
    if deleted then
        doc_settings:flush()
        -- Remove from current notes list
        for i = #parent_widget.notes_list, 1, -1 do
            local n = parent_widget.notes_list[i]
            if n.datetime == note.datetime and n.highlighted_text == note.highlighted_text then
                table.remove(parent_widget.notes_list, i)
                break
            end
        end
        parent_widget:refresh()
    end
end
function AllNotesViewer:editNote(note, parent_widget)
    local InputDialog = require("ui/widget/inputdialog")
    local input_dialog
    input_dialog = InputDialog:new{
        title = _("Edit Note"),
        input = note.user_note or "",
        input_type = "text",
        text_height = Screen:scaleBySize(150),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(input_dialog)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local new_note_text = input_dialog:getInputText()
                        UIManager:close(input_dialog)
                        self:saveNoteEdit(note, new_note_text, parent_widget)
                    end,
                },
            },
        },
    }
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end
function AllNotesViewer:saveNoteEdit(note, new_note_text, parent_widget)
    if not note.book_path then return end
    local ok, doc_settings = pcall(DocSettings.open, DocSettings, note.book_path)
    if not ok or not doc_settings then return end
    local data = doc_settings.data
    if not data then return end
    local updated = false
    -- Try to update in annotations array first
    local items = data.annotations
    if items and #items > 0 then
        for _, item in ipairs(items) do
            if item.datetime == note.datetime and item.text == note.highlighted_text then
                item.note = new_note_text
                updated = true
                break
            end
        end
    end
    -- If not found in annotations, try highlight table
    if not updated then
        local highlights = data.highlight or {}
        for _, page_highlights in pairs(highlights) do
            if type(page_highlights) == "table" then
                for _, hl in ipairs(page_highlights) do
                    if hl.datetime == note.datetime and hl.text == note.highlighted_text then
                        hl.note = new_note_text
                        updated = true
                        break
                    end
                end
            end
            if updated then break end
        end
    end
    if updated then
        doc_settings:flush()
        -- Update in current notes list
        for _, n in ipairs(parent_widget.notes_list) do
            if n.datetime == note.datetime and n.highlighted_text == note.highlighted_text then
                n.user_note = new_note_text
                break
            end
        end
        parent_widget:refresh()
        UIManager:show(require("ui/widget/infomessage"):new{ text = _("Note saved."), timeout = 1 })
    end
end
function AllNotesViewer:openBookAtNote(note)
    local book_path = note.book_path
    if not book_path then
        UIManager:show(InfoMessage:new{ text = _("Cannot find book path.") })
        return
    end
    
    local ReaderUI = require("apps/reader/readerui")
    
    local function gotoNote(ui)
        if not ui or not ui.document then return end
        local target_page = note.page
        if note.pos0 and ui.document.getPageFromXPointer then
            local ok, page = pcall(function() return ui.document:getPageFromXPointer(note.pos0) end)
            if ok and page then target_page = page end
        end
        if target_page and target_page > 0 then
            ui:handleEvent(require("ui/event"):new("GotoPage", target_page))
        end
    end
    
    if ReaderUI.instance and ReaderUI.instance.document then
        if ReaderUI.instance.document.file == book_path then
            gotoNote(ReaderUI.instance)
            return
        end
    end
    
    ReaderUI:showReader(book_path)
    UIManager:scheduleIn(1.5, function()
        local ui = require("apps/reader/readerui").instance
        if ui then gotoNote(ui) end
    end)
end
return AllNotesViewer