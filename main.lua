local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ReaderHighlight = require("apps/reader/modules/readerhighlight")
local FrameContainer = require("ui/widget/container/framecontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Event = require("ui/event")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local LeftContainer = require("ui/widget/container/leftcontainer")
local TopContainer = require("ui/widget/container/topcontainer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local CenterContainer = require("ui/widget/container/centercontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local Button = require("ui/widget/button")
local InputContainer = require("ui/widget/container/inputcontainer")
local GestureRange = require("ui/gesturerange")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local ButtonDialogTitle = require("ui/widget/buttondialogtitle")
local TextViewer = require("ui/widget/textviewer")
local SpinWidget = require("ui/widget/spinwidget")
local IconButton = require("ui/widget/iconbutton")
local IconWidget = require("ui/widget/iconwidget")
local LineWidget = require("ui/widget/linewidget")
local RightContainer = require("ui/widget/container/rightcontainer")
local BlitBuffer = require("ffi/blitbuffer")
local Screen = require("device").screen
local Device = require("device")
local Input = Device.input
local logger = require("logger")
local FontList = require("fontlist")
local DocSettings = require("docsettings")
local ReadHistory = require("readhistory")
local G_reader_settings = require("luasettings"):open(require("datastorage"):getSettingsDir() .. "/settings.annotationsviewer.lua")
local lfs = require("libs/libkoreader-lfs")
local Font = require("ui/font")
local Size = require("ui/size")
local Geom = require("ui/geometry")
local _ = require("gettext")
local BD = require("ui/bidi")
local DEFAULT_CONTENT_FONT_SIZE = 16
local DEFAULT_TITLE_FONT_SIZE = 22
local DEFAULT_INFO_FONT_SIZE = 15
local DEFAULT_H_MARGIN = 50
local DEFAULT_NOTE_SPACING = 30
local DEFAULT_TEXT_MARGIN = 0
local DEFAULT_TRUNCATE_LINES = 5
local DEFAULT_TITLE_MARGIN = 8
local DEFAULT_INFO_MARGIN = 6
local DEFAULT_TOP_PADDING = 16
local function getSetting(key, default)
    local val = G_reader_settings:readSetting("annotationsviewer_" .. key)
    if val == nil then return default end
    if type(default) == "number" then
        local nval = tonumber(val)
        if nval == nil then return default end
        return nval
    end
    return val
end

local function setSetting(key, value)
    G_reader_settings:saveSetting("annotationsviewer_" .. key, value)
    G_reader_settings:flush()
end
local function getContentFontSize()
    local v = getSetting("content_font_size", DEFAULT_CONTENT_FONT_SIZE)
    v = tonumber(v)
    if not v or v <= 0 then return DEFAULT_CONTENT_FONT_SIZE end
    return v
end
local function getTitleFontSize()
    local v = getSetting("title_font_size", DEFAULT_TITLE_FONT_SIZE)
    v = tonumber(v)
    if not v or v <= 0 then return DEFAULT_TITLE_FONT_SIZE end
    return v
end
local function getInfoFontSize()
    local v = getSetting("info_font_size", DEFAULT_INFO_FONT_SIZE)
    v = tonumber(v)
    if not v or v <= 0 then return DEFAULT_INFO_FONT_SIZE end
    return v
end
local function getHMargin() return Screen:scaleBySize(getSetting("h_margin", DEFAULT_H_MARGIN)) end
local function getNoteSpacing() return Screen:scaleBySize(getSetting("note_spacing", DEFAULT_NOTE_SPACING)) end
local function getTextMargin() return Screen:scaleBySize(getSetting("text_margin", DEFAULT_TEXT_MARGIN)) end
local preview_truncate_lines = nil
local function getTruncateLines()
    if preview_truncate_lines then return preview_truncate_lines end
    return getSetting("truncate_lines", DEFAULT_TRUNCATE_LINES)
end
local function getJustify() return getSetting("justify", false) end
local function getTitleMargin() return Screen:scaleBySize(getSetting("title_margin", DEFAULT_TITLE_MARGIN)) end
local function getInfoMargin() return Screen:scaleBySize(getSetting("info_margin", DEFAULT_INFO_MARGIN)) end
local function getTitleFont() return getSetting("title_font", nil) end
local function getInfoFont() return getSetting("info_font", nil) end
local function getContentFont() return getSetting("content_font", nil) end
local function getShowTotalNotes() return getSetting("show_total", true) end
local function getTopPadding() return Screen:scaleBySize(getSetting("top_padding", DEFAULT_TOP_PADDING)) end
local function getHideDupTitle() return getSetting("hide_dup_title", true) ~= false end
local function getHideDupInfo() return getSetting("hide_dup_info", true) ~= false end
local function getFilterTitlebarBtn() return getSetting("filter_titlebar_btn", true) ~= false end
local function getSwipeSetting() return getSetting("swipe_direction", "both") end
local function getDedupInfoFields() return getSetting("dedup_info_fields", "date,author,chapter") end
local function getShowInfo() return getSetting("show_info", true) ~= false end
local function getInfoFields() return getSetting("info_fields", "date,author,chapter") end
local getNoteInfoKey -- defined below
local function getAlwaysShowFirstOnPage() return getSetting("always_show_first_on_page", true) ~= false end
-- Repeat the book title / the chapter·date line at the top of every page. Both start from the
-- older single "show on every page" setting.
local function getRepeatTitleOnPage() return getSetting("repeat_title_on_page", getAlwaysShowFirstOnPage()) ~= false end
local function getRepeatInfoOnPage() return getSetting("repeat_info_on_page", getAlwaysShowFirstOnPage()) ~= false end
-- extra space above a book title that is not at the top of the page
local BOOK_GAP = Screen:scaleBySize(14)
-- Which header rows an annotation leaves out, given what came right before it.
local function getHeaderSkips(note, is_first_on_page, prev_title, prev_info_key, dedup_fields)
    local skip_title = getHideDupTitle()
        and not (getRepeatTitleOnPage() and is_first_on_page)
        and (note.book_title == prev_title)
    local skip_info = getHideDupInfo()
        and not (getRepeatInfoOnPage() and is_first_on_page)
        and (getNoteInfoKey(note, dedup_fields) == prev_info_key)
    return skip_title, skip_info
end
-- "default" = Prev / Next bar at the bottom. The older "left" / "right" bars were merged into it.
local function getPaginationStyle()
    local style = getSetting("pagination_style", "default")
    if style == "left" or style == "right" then return "default" end
    return style
end
local function getScrollbarBookMarks() return getSetting("sb_book_marks", true) ~= false end
local function isScrollbarStyle(style)
    style = style or getPaginationStyle()
    return style == "scrollbar" or style == "scrollbar_chevrons"
end
-- Same look as before the redesign: 1px black track, narrow outline thumb
local SB_THUMB_WIDTH  = Screen:scaleBySize(8)
local SB_TRACK_WIDTH  = Screen:scaleBySize(1)
local SB_STRIP_WIDTH  = Screen:scaleBySize(32 + 16 + 3)
local SB_MARGIN_RIGHT = 0
local SB_MARGIN_V_TOP    = Screen:scaleBySize(16)
local SB_MARGIN_V_BOTTOM = SB_MARGIN_V_TOP -- same space below as above
-- The plugin's own colours (from the design), as fixed grey values rather than KOReader's
-- named greys, so every screen uses exactly the same shades.
local COLORS = {
    ink        = BlitBuffer.COLOR_BLACK,
    muted      = BlitBuffer.Color8(0x45), -- secondary text: tabs, info line, author, counts
    disabled   = BlitBuffer.Color8(0xAA), -- buttons that can't be used
    line       = BlitBuffer.Color8(0xBD), -- separators
    line_light = BlitBuffer.Color8(0xD6), -- row lines, line under book titles
    section_bg = BlitBuffer.Color8(0xE9), -- section bars in Filter & sort
    section_fg = BlitBuffer.Color8(0x33),
}
-- where a book starts: a short notch across the track, like chapter ticks on Kindle/Kobo
local SB_MARK_OVERHANG = Screen:scaleBySize(3)          -- how far it sticks out on each side
local SB_MARK_HEIGHT   = math.max(1, math.floor(Screen:scaleBySize(1)))
-- Header: top bar (menu, title, search, filter, close), tab row, optional active-filter row
local TOPBAR_HEIGHT    = Screen:scaleBySize(50)
local TOPBAR_BOOK_HEIGHT = TOPBAR_HEIGHT -- one-book view: same bar, title + author line
local TABS_HEIGHT      = Screen:scaleBySize(38)
local FOOTER_BAR_HEIGHT = Screen:scaleBySize(48) -- page buttons bar (non-scrollbar styles)
-- mockup: 22px icons in 44px buttons, 8px from the screen edges, 4px between menu and title
local HEADER_ICON_SIZE = Screen:scaleBySize(22)
local HEADER_ICON_PAD  = Screen:scaleBySize(11)
-- Serif used for book titles, highlights and the screen title unless the user picked a font
local SERIF_FONT = "NotoSerif-Regular.ttf"
-- Icons shipped with the plugin (drawn in the style of KOReader's own mdlight set)
local PLUGIN_DIR = (debug.getinfo(1, "S").source or ""):match("^@(.*/)[^/]*$") or "./"
local function pluginIcon(name) return PLUGIN_DIR .. "icons/" .. name .. ".svg" end
local function getFaceOr(font_name, size, fallback)
    return (font_name and font_name ~= "" and Font:getFace(font_name, size))
        or Font:getFace(fallback, size) or Font:getFace("cfont", size)
end

getNoteInfoKey = function(note, fields_setting)
    local parts = {}
    local fields = {}
    for f in fields_setting:gmatch("[^,]+") do fields[f] = true end
    if fields["date"] then
        table.insert(parts, note.datetime and note.datetime:match("^(%d+-%d+-%d+)") or "")
    end
    if fields["author"] then
        table.insert(parts, note.book_authors or "")
    end
    if fields["chapter"] then
        table.insert(parts, note.chapter or "")
    end
    return table.concat(parts, "|")
end

local SORT_MODES = {
    date_newest = { label = _("Newest First") },
    date_oldest = { label = _("Oldest First") },
    author_asc = { label = _("A to Z (by Date)") },
    author_desc = { label = _("Z to A (by Date)") },
    author_location_asc = { label = _("Location: Begin to End") },
    author_location_desc = { label = _("Location: End to Begin") },
    book_asc = { label = _("A to Z (by Date)") },
    book_desc = { label = _("Z to A (by Date)") },
    book_location_asc = { label = _("Location: Begin to End") },
    book_location_desc = { label = _("Location: End to Begin") },
    filename_asc = { label = _("A to Z (by Date)") },
    filename_desc = { label = _("Z to A (by Date)") },
    filename_location_asc = { label = _("Location: Begin to End") },
    filename_location_desc = { label = _("Location: End to Begin") },
}

local SORT_CATEGORIES = {
    date = { "date_newest", "date_oldest" },
    author = { "author_asc", "author_desc", "author_location_asc", "author_location_desc" },
    book = { "book_asc", "book_desc", "book_location_asc", "book_location_desc" },
    filename = { "filename_asc", "filename_desc", "filename_location_asc", "filename_location_desc" },
}

local SPIN_MENUS = {
    font_size = {
        dialog_name = "font_size_dialog",
        title = _("Font sizes"),
        settings = {
            { label = _("Title size: "), key = "title_font_size", default = DEFAULT_TITLE_FONT_SIZE, min = 8, max = 48, step = 1, getter = getTitleFontSize },
            { label = _("Info size: "), key = "info_font_size", default = DEFAULT_INFO_FONT_SIZE, min = 8, max = 48, step = 1, getter = getInfoFontSize },
            { label = _("Content size: "), key = "content_font_size", default = DEFAULT_CONTENT_FONT_SIZE, min = 8, max = 48, step = 1, getter = getContentFontSize },
        }
    },
    section_margin = {
        dialog_name = "section_margin_dialog",
        title = _("Space between notes"),
        settings = {
            { label = _("Below the book title: "), key = "title_margin", default = DEFAULT_TITLE_MARGIN, min = 0, max = 30, step = 1, getter = function() return getSetting("title_margin", DEFAULT_TITLE_MARGIN) end },
            { label = _("Below the chapter · date line: "), key = "info_margin", default = DEFAULT_INFO_MARGIN, min = 0, max = 30, step = 1, getter = function() return getSetting("info_margin", DEFAULT_INFO_MARGIN) end },
        }
    },
    margins = {
        dialog_name = "margin_dialog",
        title = _("Page margins"),
        settings = {
            { label = _("Top padding: "), key = "top_padding", default = DEFAULT_TOP_PADDING, min = 0, max = 100, step = 5, getter = function() return getSetting("top_padding", DEFAULT_TOP_PADDING) end },
            { label = _("Horizontal margin: "), key = "h_margin", default = DEFAULT_H_MARGIN, min = 5, max = 60, step = 5, getter = function() return getSetting("h_margin", DEFAULT_H_MARGIN) end },
            { label = _("Landscape width (%): "), key = "landscape_width_pct", default = 80, min = 40, max = 100, step = 5, getter = function() return getSetting("landscape_width_pct", 80) end },
            { label = _("Between annotations: "), key = "note_spacing", default = DEFAULT_NOTE_SPACING, min = 5, max = 100, step = 2, getter = function() return getSetting("note_spacing", DEFAULT_NOTE_SPACING) end },
            { label = _("Space above the note: "), key = "note_offset", default = 8, min = 0, max = 40, step = 2, getter = function() return getSetting("note_offset", 8) end },
            { label = _("Extra indent for the note: "), key = "note_indent", default = 0, min = 0, max = 60, step = 2, getter = function() return getSetting("note_indent", 0) end },
            { label = _("Line spacing: "), key = "line_spacing", default = 0, min = -15, max = 20, step = 1, getter = function() return getSetting("line_spacing", 0) end },
            { label = _("Text indent: "), key = "text_margin", default = DEFAULT_TEXT_MARGIN, min = 0, max = 30, step = 2, getter = function() return getSetting("text_margin", DEFAULT_TEXT_MARGIN) end },
        }
    }
}

local HIGHLIGHT_COLORS = BlitBuffer.HIGHLIGHT_COLORS

-- Sorting compares titles many times; normalise each title only once.
local _normalized_title_cache = {}
local _lower_cache = {}
local function lowerCached(str)
    str = str or ""
    local l = _lower_cache[str]
    if not l then l = str:lower(); _lower_cache[str] = l end
    return l
end
local normalizeBookTitleUncached
local function normalizeBookTitle(title)
    if not title then return "" end
    local n = _normalized_title_cache[title]
    if not n then
        n = normalizeBookTitleUncached(title)
        _normalized_title_cache[title] = n
    end
    return n
end
normalizeBookTitleUncached = function(title)
    local normalized = title:lower():gsub("^%s+", ""):gsub("%s+$", "")
    normalized = normalized:gsub("^the%s+", ""):gsub("^a%s+", ""):gsub("^an%s+", "")
    return normalized
end

local function compareByDatetime(a, b, reverse)
    local cmp = (a.datetime or "") > (b.datetime or "") and 1 or ((a.datetime or "") < (b.datetime or "") and -1 or 0)
    return reverse and cmp < 0 or cmp > 0
end

local function compareByPosition(a, b, reverse)
    local pos_a = tonumber(a.pos0) or 0
    local pos_b = tonumber(b.pos0) or 0
    if reverse then return pos_a > pos_b else return pos_a < pos_b end
end

local SORT_COMPARATORS = {
    date_newest = function(a, b) return (a.datetime or "") > (b.datetime or "") end,
    date_oldest = function(a, b) return (a.datetime or "") < (b.datetime or "") end,
    
    author_asc = function(a, b)
        if a.book_authors ~= b.book_authors then return a.book_authors < b.book_authors end
        return compareByDatetime(a, b)
    end,
    author_desc = function(a, b)
        if a.book_authors ~= b.book_authors then return a.book_authors > b.book_authors end
        return compareByDatetime(a, b)
    end,
    
    book_asc = function(a, b)
        local title_a = normalizeBookTitle(a.book_title)
        local title_b = normalizeBookTitle(b.book_title)
        if title_a ~= title_b then return title_a < title_b end
        return compareByDatetime(a, b)
    end,
    book_desc = function(a, b)
        local title_a = normalizeBookTitle(a.book_title)
        local title_b = normalizeBookTitle(b.book_title)
        if title_a ~= title_b then return title_a > title_b end
        return compareByDatetime(a, b)
    end,
    
    author_location_asc = function(a, b)
        if a.book_authors ~= b.book_authors then return a.book_authors < b.book_authors end
        local title_a = normalizeBookTitle(a.book_title)
        local title_b = normalizeBookTitle(b.book_title)
        if title_a ~= title_b then return title_a < title_b end
        return compareByPosition(a, b)
    end,
    author_location_desc = function(a, b)
        if a.book_authors ~= b.book_authors then return a.book_authors < b.book_authors end
        local title_a = normalizeBookTitle(a.book_title)
        local title_b = normalizeBookTitle(b.book_title)
        if title_a ~= title_b then return title_a < title_b end
        return compareByPosition(a, b, true)
    end,
    
    book_location_asc = function(a, b)
        local title_a = normalizeBookTitle(a.book_title)
        local title_b = normalizeBookTitle(b.book_title)
        if title_a ~= title_b then return title_a < title_b end
        return compareByPosition(a, b)
    end,
    book_location_desc = function(a, b)
        local title_a = normalizeBookTitle(a.book_title)
        local title_b = normalizeBookTitle(b.book_title)
        if title_a ~= title_b then return title_a < title_b end
        return compareByPosition(a, b, true)
    end,
    
    filename_location_asc = function(a, b)
        local filename_a = lowerCached(a.book_filename)
        local filename_b = lowerCached(b.book_filename)
        if filename_a ~= filename_b then return filename_a < filename_b end
        local title_a = normalizeBookTitle(a.book_title)
        local title_b = normalizeBookTitle(b.book_title)
        if title_a ~= title_b then return title_a < title_b end
        return compareByPosition(a, b)
    end,
    filename_location_desc = function(a, b)
        local filename_a = lowerCached(a.book_filename)
        local filename_b = lowerCached(b.book_filename)
        if filename_a ~= filename_b then return filename_a > filename_b end
        local title_a = normalizeBookTitle(a.book_title)
        local title_b = normalizeBookTitle(b.book_title)
        if title_a ~= title_b then return title_a < title_b end
        return compareByPosition(a, b, true)
    end,
    
    filename_asc = function(a, b)
        local filename_a = lowerCached(a.book_filename)
        local filename_b = lowerCached(b.book_filename)
        if filename_a ~= filename_b then return filename_a < filename_b end
        return compareByDatetime(a, b)
    end,
    filename_desc = function(a, b)
        local filename_a = lowerCached(a.book_filename)
        local filename_b = lowerCached(b.book_filename)
        if filename_a ~= filename_b then return filename_a > filename_b end
        return compareByDatetime(a, b)
    end,
}

local function getHighlightColor(color)
        local val = HIGHLIGHT_COLORS[color and color:lower() or ""]
    if val and BlitBuffer.colorFromString then
        return BlitBuffer.colorFromString(val)
    end
    return BlitBuffer.COLOR_GRAY
end
local function isNoBackgroundStyle(drawer)
    if not drawer then return false end
    local d = drawer:lower()
    return d == "strikeout" or d == "underscore"
end

local function truncateAuthorDisplay(author_str)
    if not author_str or author_str == "Unknown" then return author_str end
    if not author_str:find("\n") then return author_str end
    local first_author = author_str:match("^([^\n]+)")
    if first_author then
        first_author = first_author:match("^%s*(.-)%s*$")
        return first_author .. " et al."
    end
    return author_str
end

local NoteWrapper = {}
function NoteWrapper:new(note)
    return setmetatable({ _note = note }, { __index = self })
end
function NoteWrapper:getDisplayAuthors()
    if not self._note.book_authors or self._note.book_authors == "" or self._note.book_authors == "Unknown" then
        return nil
    end
    return truncateAuthorDisplay(self._note.book_authors)
end
function NoteWrapper:getTags()
    local tags = self._note.tags or self._note.keywords or {}
    if type(tags) == "string" then
        local result = {}
        for tag in tags:gmatch("[^,;\n|\t]+") do
            tag = tag:match("^%s*(.-)%s*$")
            if tag ~= "" then table.insert(result, tag) end
        end
        return result
    end
    return tags
end
function NoteWrapper:getNormalizedColor()
    return self._note.color and self._note.color:lower() or nil
end
function NoteWrapper:getNormalizedDrawer()
    return self._note.drawer and self._note.drawer:lower() or nil
end
function NoteWrapper:hasHighlightedText()
    return self._note.highlighted_text and self._note.highlighted_text ~= "" or false
end
function NoteWrapper:hasUserNote()
    return self._note.user_note and self._note.user_note ~= "" or false
end

-- Text measurement caches. Font:getFace() returns cached face objects, so a face's
-- table identity is a stable key; weak keys let unused faces be collected.
local _word_width_cache = setmetatable({}, { __mode = "k" })  -- [face][word] = px
local _line_height_cache = setmetatable({}, { __mode = "k" }) -- [face] = px
local _box_height_cache = setmetatable({}, { __mode = "k" })  -- [face]["w:bold:text"] = px

local function measureTextWidth(text, face)
    local tw = TextWidget:new{ text = text, face = face }
    local w = tw:getSize().w
    tw:free()
    return w
end

local function getWordWidths(face)
    local fc = _word_width_cache[face]
    if not fc then
        fc = {}
        -- Words never contain spaces, so " " is free to hold the width of one space.
        fc[" "] = measureTextWidth("x x", face) - 2 * measureTextWidth("x", face)
        _word_width_cache[face] = fc
    end
    return fc
end

-- Height of one TextWidget line in this face (TextWidget height does not depend on the text).
local function getLineHeight(face)
    local h = _line_height_cache[face]
    if not h then
        local tw = TextWidget:new{ text = "x", face = face }
        h = tw:getSize().h
        tw:free()
        _line_height_cache[face] = h
    end
    return h
end

-- Height of a wrapped TextBoxWidget (book title / info row), cached by text and width.
local function getBoxHeight(text, face, width, bold)
    local fc = _box_height_cache[face]
    if not fc then fc = {}; _box_height_cache[face] = fc end
    local key = width .. (bold and ":b:" or ":n:") .. text
    local h = fc[key]
    if not h then
        local tb = TextBoxWidget:new{ text = text, face = face, width = width, alignment = "left", bold = bold }
        h = tb:getSize().h
        tb:free()
        fc[key] = h
    end
    return h
end

-- Greedy word wrap. Same result as measuring every candidate line, but word widths are
-- measured once per face and summed; only lines that end up within the rounding error of
-- max_width are measured for real, so the line breaks are unchanged.
local function wrapParagraph(text, face, max_width, lines)
-- Words to wrap: split at spaces; Chinese / Japanese / Korean text has none, so such words are
-- cut into their characters with KOReader's util.splitToWords (the pieces join without a space).
    local function wrapTokens(txt)
        local tokens = {}
        for word in txt:gmatch("%S+") do
            if word:find("[\227-\237\239]") then
                for i, piece in ipairs(require("util").splitToWords(word)) do
                    table.insert(tokens, { piece, i > 1 })
                end
            else
                table.insert(tokens, { word, false })
            end
        end
        return tokens
    end
    local widths = getWordWidths(face)
    local space_w = widths[" "]
    local current_line, current_w, words_since_exact = "", 0, 0
    for _t, tok in ipairs(wrapTokens(text)) do
        local word, joined = tok[1], tok[2]
        local sep, sep_w = joined and "" or " ", joined and 0 or space_w
        local ww = widths[word]
        if not ww then
            ww = measureTextWidth(word, face)
            widths[word] = ww
        end
        if current_line == "" then
            current_line, current_w, words_since_exact = word, ww, 0
        else
            local est = current_w + sep_w + ww
            -- each summed width can be off by about a pixel of rounding
            local slack = 2 + words_since_exact
            local fits
            if est <= max_width - slack then
                fits = true
                current_w = est
                words_since_exact = words_since_exact + 1
            elseif est > max_width + slack then
                fits = false
            else
                local exact = measureTextWidth(current_line .. sep .. word, face)
                fits = exact <= max_width
                if fits then current_w, words_since_exact = exact, 0 end
            end
            if fits then
                current_line = current_line .. sep .. word
            else
                table.insert(lines, current_line)
                current_line, current_w, words_since_exact = word, ww, 0
            end
        end
    end
    if current_line ~= "" then table.insert(lines, current_line) end
end

-- Wraps text to max_width, keeping the text's paragraph breaks (blank lines are dropped).
-- Returns the lines and a set of line numbers that end a paragraph (not to be justified).
-- Strip spaces (including no-break spaces) from both ends of a paragraph; books often
-- leave them in front of a line, which then shows as a stray indent.
local NBSP = "\194\160"
local function trimParagraph(p)
    local changed = true
    while changed do
        changed = false
        local t = p:gsub("^%s+", ""):gsub("%s+$", "")
        if t:sub(1, 2) == NBSP then t = t:sub(3); changed = true end
        if t:sub(-2) == NBSP then t = t:sub(1, -3); changed = true end
        p = t
    end
    return p
end
local function wrapText(text, face, max_width)
    local lines, para_end = {}, {}
    for paragraph in (text:gsub("\r", "") .. "\n"):gmatch("([^\n]*)\n") do
        paragraph = trimParagraph(paragraph)
        if paragraph ~= "" then
            wrapParagraph(paragraph, face, max_width, lines)
            para_end[#lines] = true
        end
    end
    return lines, para_end
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
    -- a line that is far shorter than the column (end of a truncated highlight) is not stretched
    local natural = TextWidget:new{ text = text, face = face }
    local natural_w = natural:getSize().w
    natural:free()
    if natural_w < target_width * 0.8 then
        for _, w in ipairs(word_widgets) do w:free() end
        return TextWidget:new{ text = text, face = face, fgcolor = fgcolor }
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
    bb:paintRect(x, y + (self.y_offset or math.floor(self.height / 2)), self.width, Size.line.medium, BlitBuffer.COLOR_BLACK)
end
local UnderlineWidget = InputContainer:extend{ width = nil, height = nil }
function UnderlineWidget:init() self.dimen = Geom:new{ w = self.width, h = self.height } end
function UnderlineWidget:paintTo(bb, x, y)
    bb:paintRect(x, y + self.height - Size.line.medium, self.width, Size.line.medium, BlitBuffer.COLOR_BLACK)
end
local NoteItemWidget = InputContainer:extend{ width = nil, note = nil, show_parent = nil, is_last = false, is_preview = false, disable_tap = false, skip_title = false, skip_info = false }

-- Longest a note (the text you wrote) is shown in the list; longer ones end with "...".
NoteItemWidget.DEFAULT_NOTE_LINES = 5
-- font of the user notes: its own font / size, otherwise the same as the highlight text
function NoteItemWidget.noteFace()
    local font = getSetting("note_font", nil)
    if not font or font == "" then font = getContentFont() end
    local size = getSetting("note_font_size", nil) or getContentFontSize()
    return getFaceOr(font ~= "" and font or SERIF_FONT, size, "cfont")
end
-- space between the highlight and its note
function NoteItemWidget.noteOffset() return Screen:scaleBySize(getSetting("note_offset", 8)) end
-- how far the note is moved in from the left
function NoteItemWidget.noteIndent() return Screen:scaleBySize(getSetting("note_indent", 0)) end
-- A box that shows only the middle part of its child (used for negative line spacing, where the lines
-- sit closer than their natural height): w x h, the child is moved by dy and cut off at the box.
NoteItemWidget.LineBox = WidgetContainer:extend{ w = 0, h = 0, dy = 0 }
function NoteItemWidget.LineBox:getSize() return Geom:new{ w = self.w, h = self.h } end
function NoteItemWidget.LineBox:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.w, h = self.h }
    local buf = BlitBuffer.new(self.w, self.h, bb:getType())
    buf:blitFrom(bb, 0, 0, x, y, self.w, self.h) -- start from what is already there (the page, a highlight)
    self[1]:paintTo(buf, 0, self.dy)
    bb:blitFrom(buf, x, y, 0, 0, self.w, self.h)
    buf:free()
end
-- extra space between the lines of a highlight and of a note (Spacing page)
function NoteItemWidget.lineSpacing() return Screen:scaleBySize(getSetting("line_spacing", 0)) end
function NoteItemWidget.noteLinesMax()
    local v = tonumber(getSetting("truncate_note_lines", NoteItemWidget.DEFAULT_NOTE_LINES))
    if not v or v < 1 then return NoteItemWidget.DEFAULT_NOTE_LINES end
    return v
end
-- First `max` lines, the last one shortened to take the "..." (cutting whole characters).
function NoteItemWidget.cutLines(lines, max, face, width)
    if #lines <= max then return lines, false end
    local out = {}
    for i = 1, max do out[i] = lines[i] end
    local last = out[max]
    while #last > 0 and measureTextWidth(last .. "...", face) > width do
        last = last:gsub("[\128-\191]*[^\128-\191]$", "")
    end
    out[max] = last .. "..."
    return out, true
end
-- Night mode inverts the whole screen. Things that must keep their real colours (highlight
-- colours and the text on them) are drawn in true colour into a copy of what is behind them and
-- copied back inverted, so the screen's own inversion turns them right again -- the same idea
-- as an image widget's `original_in_nightmode = false`.
function NoteItemWidget.paintTrue(bb, x, y, w, h, draw)
    if not Screen.night_mode or w <= 0 or h <= 0 then return draw(bb, x, y) end
    local buf = BlitBuffer.new(w, h, bb:getType())
    buf:blitFrom(bb, 0, 0, x, y, w, h)
    buf:invert()
    draw(buf, 0, 0)
    bb:invertblitFrom(buf, x, y, 0, 0, w, h)
    buf:free()
end
NoteItemWidget.TruePaint = WidgetContainer:extend{}
function NoteItemWidget.TruePaint:getSize() return self[1]:getSize() end
function NoteItemWidget.TruePaint:paintTo(bb, x, y)
    local size = self[1]:getSize()
    self.dimen = Geom:new{ x = x, y = y, w = size.w, h = size.h }
    NoteItemWidget.paintTrue(bb, x, y, size.w, size.h, function(b, xx, yy) self[1]:paintTo(b, xx, yy) end)
end

-- Faces used by NoteItemWidget (shared by the real layout and the height measurement).
local function getNoteFaces()
    local title_font, info_font, content_font = getTitleFont(), getInfoFont(), getContentFont()
    local title_size, info_size, content_size = getTitleFontSize(), getInfoFontSize(), getContentFontSize()
    local title_face = getFaceOr(title_font ~= "" and title_font or SERIF_FONT, title_size, "cfont")
    local info_face = getFaceOr(info_font, info_size, "cfont")
    local content_face = getFaceOr(content_font ~= "" and content_font or SERIF_FONT, content_size, "cfont")
    return title_face, info_face, content_face
end

-- Text of the line above each highlight (chapter · date), or "" when the row is turned off.
-- The author is shown in the book header instead (see getHeaderAuthor).
local function buildInfoText(note, note_wrapper, skip_title, hide_chapter) -- luacheck: ignore 212
    if not getShowInfo() then return "" end
    local info_fields = {}
    for f in getInfoFields():gmatch("[^,]+") do info_fields[f] = true end
    local info_parts = {}
    if info_fields["chapter"] and not hide_chapter and note.chapter and note.chapter ~= "" then
        table.insert(info_parts, NoteItemWidget.chapterLabel(note.chapter))
    end
    local date_text = NoteItemWidget:formatDate(note.datetime) or ""
    if info_fields["date"] and date_text ~= "" then table.insert(info_parts, date_text) end
    return table.concat(info_parts, " · ")
end

-- "1." or "12" on its own reads oddly; show it as "Chapter 1"
function NoteItemWidget.chapterLabel(chapter)
    local num = chapter:match("^%s*(%d+)[%.%s]*$")
    return num and (_("Chapter") .. " " .. num) or chapter
end
-- Search words in a drawn line get a thick black line underneath. `widget` is a TextWidget, or a
-- justified line (HorizontalGroup of word widgets and gaps); `text` is the line's text.
function NoteItemWidget.markLine(widget, text, query, case_sensitive, face)
    if not query or query == "" or not text or text == "" then return widget end
    local function words_in(str)
        local found = {}
        local hay = case_sensitive and str or str:lower()
        local q = case_sensitive and query or query:lower()
        for word in q:gmatch("%S+") do
            local from = 1
            while true do
                local a, b = hay:find(word, from, true)
                if not a then break end
                local pre = TextWidget:new{ text = str:sub(1, a - 1), face = face }
                local mid = TextWidget:new{ text = str:sub(a, b), face = face }
                table.insert(found, { x = pre:getSize().w, w = mid:getSize().w })
                pre:free(); mid:free()
                from = b + 1
            end
        end
        return found
    end
    local marks = {}
    if widget.text ~= nil then -- single TextWidget
        marks = words_in(text)
    else -- justified: word widgets with their own gaps
        local x = 0
        for _i, ch in ipairs(widget) do
            local cw = ch:getSize().w
            if ch.text ~= nil then
                for _j, m in ipairs(words_in(ch.text)) do table.insert(marks, { x = x + m.x, w = m.w }) end
            end
            x = x + cw
        end
    end
    if #marks == 0 then return widget end
    local size = widget:getSize()
    local thick = math.max(2, Screen:scaleBySize(2))
    local og = OverlapGroup:new{ dimen = Geom:new{ w = size.w, h = size.h }, widget }
    for _i, mk in ipairs(marks) do
        if mk.x < size.w then
            local mark = LineWidget:new{ dimen = Geom:new{ w = math.max(1, math.min(mk.w, size.w - mk.x)), h = thick }, background = BlitBuffer.COLOR_BLACK }
            mark.overlap_offset = { mk.x, size.h - thick }
            table.insert(og, mark)
        end
    end
    return og
end
-- Author shown on the right of the book header, in capitals; nil when off.
local function getHeaderAuthor(note_wrapper)
    if not getShowInfo() then return nil end
    if not getInfoFields():find("author", 1, true) then return nil end
    local a = note_wrapper:getDisplayAuthors()
    if not a or a == "" or a == "Unknown" then return nil end
    return a:upper()
end
local HEADER_AUTHOR_GAP = Screen:scaleBySize(12)
local HEADER_LINE_GAP = Screen:scaleBySize(3)
-- Size of the book header: title on the left, author on the right, thin line below.
-- Returns title width, author max width and total height. Shared by measuring and drawing.
local function getHeaderLayout(title_text, author_text, title_face, info_face, content_width)
    local author_w = 0
    if author_text then
        author_w = math.min(measureTextWidth(author_text, info_face), math.floor(content_width * 0.4))
    end
    local title_w = content_width - (author_text and (author_w + HEADER_AUTHOR_GAP) or 0)
    local title_h = getBoxHeight(title_text, title_face, title_w, true)
    return title_w, author_w, title_h + HEADER_LINE_GAP + Size.line.thin
end

local NOTE_ICON_CHAR = "\u{F040}"

-- Height NoteItemWidget:init() would produce for these params, computed without building
-- any widgets. Must mirror the layout in NoteItemWidget:init().
-- Width of the annotation column: portrait uses all the room the scrollbar leaves (the side
-- margin does the rest); landscape uses the "Landscape width" share of the screen, centred.
function NoteItemWidget.columnWidth(avail, W, H)
    if W <= H then return avail end
    local pct = tonumber(getSetting("landscape_width_pct", 80)) or 80
    return math.min(avail, math.floor(W * math.max(pct, 30) / 100))
end
-- Width the annotations may use: with a scrollbar they reach to the middle of its track (the side margin
-- does the rest). A small side margin would put the text behind the scrollbar strip, so then the
-- column is made narrower to keep a little air between the text and the strip.
-- How far both sides are pushed in so that text stays clear of the scrollbar (thumb, marks, page number):
-- 0 when the side margin is already wide enough. The same on the left and the right, so the text stays centred.
function NoteItemWidget.scrollInset()
    if not isScrollbarStyle() then return 0 end
    return math.max(0, Screen:scaleBySize(22) - getHMargin())
end
function NoteItemWidget.listAvail(W)
    if not isScrollbarStyle() then return W end
    local center = W - SB_STRIP_WIDTH - SB_MARGIN_RIGHT + math.floor(SB_STRIP_WIDTH / 2)
    return center - 2 * NoteItemWidget.scrollInset()
end
function NoteItemWidget.showHeadings() return getSetting("chapter_headings", true) ~= false end
function NoteItemWidget.repeatChapter() return getSetting("repeat_chapter_on_page", true) ~= false end
-- Chapter heading of the one-book list: drawn exactly like a book header (same font, line, margin).
function NoteItemWidget.headingHeight(chapter, width)
    local content_width = width - getHMargin() * 2 - Size.padding.default * 2
    local title_face, info_face = getNoteFaces()
    local _tw, _aw, header_h = getHeaderLayout(NoteItemWidget.chapterLabel(chapter), nil, title_face, info_face, content_width)
    return header_h + getTitleMargin()
end
function NoteItemWidget.chapterHeading(chapter, width)
    local h_margin = getHMargin()
    local h_padding = Size.padding.default
    local inner_width = width - h_margin * 2
    local content_width = inner_width - h_padding * 2
    local title_face, info_face = getNoteFaces()
    local text = NoteItemWidget.chapterLabel(chapter)
    local title_w, _aw, header_h = getHeaderLayout(text, nil, title_face, info_face, content_width)
    local widget = VerticalGroup:new{ align = "left",
        TextBoxWidget:new{ text = text, face = title_face, width = title_w, alignment = "left", bold = true },
        VerticalSpan:new{ width = HEADER_LINE_GAP },
        LineWidget:new{ dimen = Geom:new{ w = content_width, h = Size.line.thin }, background = COLORS.line_light } }
    widget = CenterContainer:new{ dimen = Geom:new{ w = content_width, h = header_h }, widget }
    return HorizontalGroup:new{ HorizontalSpan:new{ width = h_margin + h_padding },
        VerticalGroup:new{ widget, VerticalSpan:new{ width = getTitleMargin() } } }
end
local function measureNoteHeight(note, width, skip_title, skip_info)
    local h_margin = getHMargin()
    local text_margin = getTextMargin()
    local inner_width = width - h_margin * 2
    local content_width = inner_width - Size.padding.default * 2
    local line_width = content_width - text_margin * 2 - Size.padding.small * 2
    local title_face, info_face, content_face = getNoteFaces()
    local note_wrapper = NoteWrapper:new(note)

    local h = 0
    if not skip_title then
        local _tw, _aw, header_h = getHeaderLayout(note.book_title or "Unknown",
            getHeaderAuthor(note_wrapper), title_face, info_face, content_width)
        h = h + header_h + getTitleMargin()
    end
    local info_text = buildInfoText(note, note_wrapper, skip_title, NoteItemWidget.measure_hide_chapter)
    local info_visible = not skip_info and info_text ~= ""
    if info_visible then
        h = h + getBoxHeight(info_text, info_face, content_width, false)
    end
    if (not skip_title) or info_visible then
        h = h + getInfoMargin()
    end
    local line_h = getLineHeight(content_face)
    if note_wrapper:hasHighlightedText() then
        local n = #wrapText(note.highlighted_text or "", content_face, line_width)
        local max_lines = getTruncateLines() or math.huge
        if n > max_lines then n = max_lines end
        h = h + n * (line_h + 2 + NoteItemWidget.lineSpacing()) -- each line has 1px padding above and below, plus the line spacing
    end
    if note_wrapper:hasUserNote() then
        h = h + NoteItemWidget.noteOffset()
        local note_face = NoteItemWidget.noteFace()
        local note_line_h = getLineHeight(note_face)
        local widths = getWordWidths(note_face)
        local icon_w = widths[NOTE_ICON_CHAR]
        if not icon_w then
            icon_w = measureTextWidth(NOTE_ICON_CHAR, note_face)
            widths[NOTE_ICON_CHAR] = icon_w
        end
        local n = math.min(#wrapText(note.user_note, note_face, line_width - icon_w - Screen:scaleBySize(6) - NoteItemWidget.noteIndent()),
            NoteItemWidget.noteLinesMax())
        local ls = NoteItemWidget.lineSpacing()
        if ls < 0 then h = h + math.max(note_line_h + ls, n * (note_line_h + ls))
        else h = h + math.max(note_line_h, n * note_line_h + (n - 1) * ls) end
    end
    return h
end

-- Measured heights, kept across refreshes. Invalidated per note when its text changes and
-- for all notes when anything that affects layout changes (see getLayoutSignature).
local _note_height_cache = setmetatable({}, { __mode = "k" })

local function getLayoutSignature(width)
    return table.concat({
        width, getHMargin(), getTextMargin(), NoteItemWidget.lineSpacing(), getTitleMargin(), getInfoMargin(),
        getTitleFontSize(), getInfoFontSize(), getContentFontSize(),
        tostring(getTitleFont()), tostring(getInfoFont()), tostring(getContentFont()),
        tostring(getSetting("note_font", nil)), tostring(getSetting("note_font_size", nil)), NoteItemWidget.noteOffset(), NoteItemWidget.noteIndent(),
        tostring(getTruncateLines()), tostring(NoteItemWidget.noteLinesMax()), tostring(getShowInfo()), getInfoFields(), tostring(NoteItemWidget.measure_hide_chapter),
        os.date("%Y%m%d"), -- "Today"/"Yesterday" labels change the info row text
    }, "|")
end

local function getNoteHeight(note, width, skip_title, skip_info, signature)
    local entry = _note_height_cache[note]
    if not entry or entry.sig ~= signature
            or entry.hl ~= note.highlighted_text or entry.un ~= note.user_note then
        entry = { sig = signature, hl = note.highlighted_text, un = note.user_note }
        _note_height_cache[note] = entry
    end
    local key = (skip_title and 2 or 0) + (skip_info and 1 or 0)
    local h = entry[key]
    if not h then
        h = measureNoteHeight(note, width, skip_title, skip_info)
        entry[key] = h
    end
    return h
end

function NoteItemWidget:init()
    local h_margin = getHMargin()
    local text_margin = getTextMargin()
    local note_spacing = getNoteSpacing()
    local title_margin = getTitleMargin()
    local info_margin = getInfoMargin()
    local inner_width = self.width - h_margin * 2
    self.dimen = Geom:new{ w = self.width, h = 0 }

    local h_padding = Size.padding.default
    local content_width = inner_width - h_padding * 2
    local justify = getJustify()

    local note_wrapper = NoteWrapper:new(self.note)
    local title_text = self.note.book_title or "Unknown"

    local title_face, info_face, content_face = getNoteFaces()
    local header_widget
    if not self.skip_title then
        -- Book header: title left, author right (in capitals), thin line underneath
        local author_text = getHeaderAuthor(note_wrapper)
        local title_w, author_w, header_h = getHeaderLayout(title_text, author_text, title_face, info_face, content_width)
        local title_widget = TextBoxWidget:new{
            text = title_text, face = title_face,
            width = title_w, alignment = "left", bold = true,
        }
        local row = HorizontalGroup:new{ align = "top", title_widget }
        if author_text then
            local author_widget = TextWidget:new{
                text = author_text, face = info_face, max_width = author_w,
                fgcolor = COLORS.muted,
            }
            -- line the author up with the middle of the title's first line
            local first_line_h = getLineHeight(title_face)
            local pad = math.max(0, math.floor((first_line_h - author_widget:getSize().h) / 2))
            table.insert(row, HorizontalSpan:new{ width = HEADER_AUTHOR_GAP + (author_w - author_widget:getSize().w) })
            table.insert(row, VerticalGroup:new{ VerticalSpan:new{ width = pad }, author_widget })
        end
        header_widget = VerticalGroup:new{
            align = "left",
            row,
            VerticalSpan:new{ width = HEADER_LINE_GAP },
            LineWidget:new{
                dimen = Geom:new{ w = content_width, h = Size.line.thin },
                background = COLORS.line_light,
            },
        }
        -- keep the measured and drawn heights identical
        header_widget = CenterContainer:new{ dimen = Geom:new{ w = content_width, h = header_h }, header_widget }
    end

    local drawer = self.note.drawer or "lighten"
    local show_info_header = getShowInfo()
    local info_text = buildInfoText(self.note, note_wrapper, self.skip_title, self.show_parent and self.show_parent.single_book and NoteItemWidget.showHeadings())

    -- Same colour and same kind of text widget as the tabs (a single-line TextWidget) when it
    -- fits on one line, so it renders exactly like them; the box keeps the measured height.
    local date_widget
    local info_box_h = getBoxHeight(info_text, info_face, content_width, false)
    if info_text ~= "" and measureTextWidth(info_text, info_face) <= content_width then
        date_widget = LeftContainer:new{
            dimen = Geom:new{ w = content_width, h = info_box_h },
            TextWidget:new{ text = info_text, face = info_face, fgcolor = COLORS.muted },
        }
    else
        date_widget = TextBoxWidget:new{
            text = info_text, face = info_face,
            width = content_width, alignment = "left",
            fgcolor = COLORS.muted,
        }
    end

    local text_fgcolor = BlitBuffer.COLOR_BLACK
    local show_strikeout = drawer == "strikeout"
    local show_underline = drawer == "underscore"
    local no_background = isNoBackgroundStyle(drawer)

    local bg_color = BlitBuffer.COLOR_WHITE
    if drawer == "invert" then
        text_fgcolor = BlitBuffer.COLOR_WHITE
        bg_color = BlitBuffer.COLOR_BLACK
    elseif not no_background then
        bg_color = getHighlightColor(self.note.color)
    end

    local text_content_width = content_width - text_margin * 2
    local line_width = text_content_width - Size.padding.small * 2
    -- underline the search words (not in the faded preview of the next annotation)
    local search_af = self.show_parent and self.show_parent.active_filter
    local function markw(widget, text, face)
        if self.is_preview or not search_af or not search_af.search_any then return widget end
        return NoteItemWidget.markLine(widget, text, search_af.search_any, search_af.search_any_case == true, face or content_face)
    end

    local note_content = VerticalGroup:new{ align = "left" }
    if header_widget then
        table.insert(note_content, LeftContainer:new{
            dimen = Geom:new{ w = inner_width, h = header_widget:getSize().h },
            HorizontalGroup:new{ HorizontalSpan:new{ width = h_padding }, header_widget },
        })
        table.insert(note_content, VerticalSpan:new{ width = title_margin })
    end
    local info_visible = show_info_header and not self.skip_info and info_text ~= ""
    if info_visible then
        table.insert(note_content, LeftContainer:new{
            dimen = Geom:new{ w = inner_width, h = date_widget:getSize().h },
            HorizontalGroup:new{ HorizontalSpan:new{ width = h_padding }, date_widget },
        })
    end
    -- only add the post-header margin when at least one header row is actually shown
    local any_header_visible = (not self.skip_title) or info_visible
    if any_header_visible then
        table.insert(note_content, VerticalSpan:new{ width = info_margin })
    end
    
    if note_wrapper:hasHighlightedText() then
        
        local full_lines, para_end = wrapText(self.note.highlighted_text or "", content_face, line_width)
        local max_lines = getTruncateLines() or math.huge
        local truncated = false
        local lines = full_lines
        local last_line_no_ell
        local ell = "..."
        if #full_lines > max_lines then
            truncated = true
            lines = {}
            for i = 1, max_lines do lines[i] = full_lines[i] end
            
            local last = lines[#lines] or ""
            local tw = TextWidget:new{ text = last .. ell, face = content_face }
            while tw:getSize().w > line_width and #last > 0 do
                tw:free()
                last = last:sub(1, -2)
                tw = TextWidget:new{ text = last .. ell, face = content_face }
            end
            tw:free()
            last_line_no_ell = last
        end

        local lines_group = VerticalGroup:new{ align = "left" }
        for i, line in ipairs(lines) do
            local line_widget
            local is_last = (i == #lines)
            if is_last and truncated then
                
                if justify == true and (#lines > 1 or true) then
                    
                    local ell_meas = TextWidget:new{ text = ell, face = content_face }
                    local ell_w = ell_meas:getSize().w
                    ell_meas:free()
                    if last_line_no_ell and #last_line_no_ell > 0 then
                        local justified_part = markw(createJustifiedLine(last_line_no_ell, content_face, math.max(0, line_width - ell_w), text_fgcolor), last_line_no_ell)
                        local ell_widget = TextWidget:new{ text = ell, face = content_face, fgcolor = text_fgcolor }
                        line_widget = HorizontalGroup:new{ justified_part, ell_widget }
                    else
                        line_widget = TextWidget:new{ text = ell, face = content_face, fgcolor = text_fgcolor }
                    end
                else
                    line_widget = markw(TextWidget:new{ text = (last_line_no_ell or line) .. ell, face = content_face, fgcolor = text_fgcolor }, (last_line_no_ell or line) .. ell)
                end
            else
                if justify == true and i < #lines and #lines > 1 and not para_end[i] then
                    line_widget = markw(createJustifiedLine(line, content_face, line_width, text_fgcolor), line)
                else
                    line_widget = markw(TextWidget:new{ text = line, face = content_face, fgcolor = text_fgcolor }, line)
                end
            end
            local line_size = line_widget:getSize()
            -- line spacing goes into the padding above and below the line, so a coloured highlight
            -- stays one solid block
            local ls = NoteItemWidget.lineSpacing()
            local lsp = math.max(0, ls) -- a negative spacing is done by trimming the line below
            local v_pad_top = 1 + math.floor(lsp / 2)
            local v_pad_bot = 1 + math.ceil(lsp / 2)
            local h_pad = Size.padding.small
            local line_container

            if show_strikeout or show_underline then
                local OverlapGroup = require("ui/widget/overlapgroup")
                local total_h = line_size.h + v_pad_top + v_pad_bot
                local total_w = line_size.w + h_pad * 2
                local overlap_items = {
                    CenterContainer:new{
                        dimen = Geom:new{ w = total_w, h = total_h },
                        line_widget,
                    },
                }
                if show_strikeout then
                    table.insert(overlap_items, StrikeoutLineWidget:new{ width = total_w, height = total_h, y_offset = math.floor(total_h / 2) })
                end
                if show_underline then
                    table.insert(overlap_items, UnderlineWidget:new{ width = total_w, height = total_h })
                end
                line_container = OverlapGroup:new{ dimen = Geom:new{ w = total_w, h = total_h }, unpack(overlap_items) }
            else
                line_container = FrameContainer:new{
                    padding = 1, padding_left = h_pad, padding_right = h_pad,
                    padding_top = v_pad_top, padding_bottom = v_pad_bot,
                    margin = 0, bordersize = 0, background = bg_color,
                    line_widget,
                }
            end
            if ls < 0 then
                local lc = line_container:getSize()
                line_container = NoteItemWidget.LineBox:new{ w = lc.w, h = math.max(2, lc.h + ls), dy = math.floor(ls / 2), line_container }
            end
            table.insert(lines_group, line_container)
        end

        local lines_widget = lines_group
        if drawer ~= "invert" and not no_background then -- coloured highlight: keeps its colour at night
            lines_widget = NoteItemWidget.TruePaint:new{ lines_group }
        end
        table.insert(note_content, LeftContainer:new{
            dimen = Geom:new{ w = inner_width, h = lines_group:getSize().h },
            HorizontalGroup:new{ HorizontalSpan:new{ width = h_padding + text_margin }, lines_widget },
        })
    end

    if note_wrapper:hasUserNote() then
        table.insert(note_content, VerticalSpan:new{ width = NoteItemWidget.noteOffset() })

        local note_face = NoteItemWidget.noteFace()
        local note_icon_char = NOTE_ICON_CHAR
        local icon_margin = Screen:scaleBySize(6)
        local note_icon = TextWidget:new{
            text = note_icon_char,
            face = note_face,
            fgcolor = BlitBuffer.COLOR_BLACK,
        }
        local icon_size = note_icon:getSize().w

        local note_text_width = line_width - icon_size - icon_margin - NoteItemWidget.noteIndent()
        local note_lines = NoteItemWidget.cutLines(wrapText(self.note.user_note, note_face, note_text_width),
            NoteItemWidget.noteLinesMax(), note_face, note_text_width)
        local note_text_group = VerticalGroup:new{ align = "left" }
        for li, line in ipairs(note_lines) do
            local ls = NoteItemWidget.lineSpacing()
            if li > 1 and ls > 0 then table.insert(note_text_group, VerticalSpan:new{ width = ls }) end
            local line_widget = markw(TextWidget:new{
                text = line, face = note_face, fgcolor = BlitBuffer.COLOR_BLACK,
            }, line, note_face)
            if ls < 0 then
                local lsz = line_widget:getSize()
                line_widget = NoteItemWidget.LineBox:new{ w = lsz.w, h = math.max(2, lsz.h + ls), dy = math.floor(ls / 2), line_widget }
            end
            table.insert(note_text_group, line_widget)
        end

                
        local note_row = HorizontalGroup:new{
            note_icon,
            HorizontalSpan:new{ width = icon_margin },
            note_text_group,
        }
        table.insert(note_content, LeftContainer:new{
            dimen = Geom:new{ w = inner_width, h = note_row:getSize().h },
            HorizontalGroup:new{ HorizontalSpan:new{ width = h_padding + text_margin + NoteItemWidget.noteIndent() }, note_row },
        })
    end

    

    self.dimen.h = note_content:getSize().h
    self[1] = HorizontalGroup:new{
        HorizontalSpan:new{ width = h_margin }, note_content, HorizontalSpan:new{ width = h_margin },
    }

end
function NoteItemWidget:formatDate(datetime)
    if not datetime or datetime == "" then return nil end
    local year, month, day = datetime:match("(%d+)-(%d+)-(%d+)")
    if not year then return datetime end
    local note_time = os.time({year = tonumber(year), month = tonumber(month), day = tonumber(day)})
    local today = os.date("*t")
    local today_key = today.year * 10000 + today.month * 100 + today.day
    if NoteItemWidget._today_key ~= today_key then
        NoteItemWidget._today_key = today_key
        NoteItemWidget._today_start = os.time({ year = today.year, month = today.month, day = today.day })
    end
    local today_start = NoteItemWidget._today_start
    if note_time >= today_start then return _("Today")
    elseif note_time >= today_start - 86400 then return _("Yesterday")
    else
        -- "3 Feb" this year, "3 Feb 2025" for older ones
        local d = os.date("*t", note_time)
        local day_month = tostring(d.day) .. " " .. os.date("%b", note_time)
        if d.year == today.year then return day_month end
        return day_month .. " " .. d.year
    end
end
-- Text of the active-filter label shown under the title; "" means no filter is shown.
local function filterToString(filter, skip_presence)
    if not filter then return "" end
    local parts = {}
    -- Colour / style
    if filter.cs and next(filter.cs) then
        local names = {}
        for k in pairs(filter.cs) do
            local t, v = k:match("^(%a+):(.+)$")
            local name
            if t == "color" then
                for _i, hc in ipairs(ReaderHighlight.highlight_colors) do
                    if hc[2] == v then name = hc[1]; break end
                end
            end
            table.insert(names, name or (v:sub(1, 1):upper() .. v:sub(2)))
        end
        table.sort(names)
        table.insert(parts, (filter.cs_exclude and "C≠ " or "C: ") .. table.concat(names, ", "))
    end
    -- Books include / exclude
    if filter.books and next(filter.books) then
        local books = {}
        for k in pairs(filter.books) do table.insert(books, k) end
        table.insert(parts, "B: " .. table.concat(books, ", "))
    end
    if filter.books_exclude and next(filter.books_exclude) then
        local books = {}
        for k in pairs(filter.books_exclude) do table.insert(books, k) end
        table.insert(parts, "B≠ " .. table.concat(books, ", "))
    end
    -- Tags include / exclude
    if filter.tags and next(filter.tags) then
        local tags = {}
        for k in pairs(filter.tags) do table.insert(tags, k) end
        table.insert(parts, "T: " .. table.concat(tags, ", "))
    end
    if filter.tags_exclude and next(filter.tags_exclude) then
        local tags = {}
        for k in pairs(filter.tags_exclude) do table.insert(tags, k) end
        table.insert(parts, "T≠ " .. table.concat(tags, ", "))
    end
    -- Highlight text include / exclude
    if filter.search_highlight and filter.search_highlight ~= "" then
        local mode = filter.search_highlight_mode or "all"
        local mode_str = mode == "any" and " (any word)" or mode == "phrase" and " (phrase)" or ""
        local case_str = filter.search_highlight_case and " [Aa]" or ""
        table.insert(parts, "H: \"" .. filter.search_highlight .. "\"" .. mode_str .. case_str)
    end
    if filter.search_highlight_exclude and filter.search_highlight_exclude ~= "" then
        local mode = filter.search_highlight_exclude_mode or "all"
        local mode_str = mode == "any" and " (any word)" or mode == "phrase" and " (phrase)" or ""
        local case_str = filter.search_highlight_exclude_case and " [Aa]" or ""
        table.insert(parts, "H≠ \"" .. filter.search_highlight_exclude .. "\"" .. mode_str .. case_str)
    end
    -- Note text include / exclude
    if filter.search_note and filter.search_note ~= "" then
        local mode = filter.search_note_mode or "all"
        local mode_str = mode == "any" and " (any word)" or mode == "phrase" and " (phrase)" or ""
        local case_str = filter.search_note_case and " [Aa]" or ""
        table.insert(parts, "N: \"" .. filter.search_note .. "\"" .. mode_str .. case_str)
    end
    if filter.search_note_exclude and filter.search_note_exclude ~= "" then
        local mode = filter.search_note_exclude_mode or "all"
        local mode_str = mode == "any" and " (any word)" or mode == "phrase" and " (phrase)" or ""
        local case_str = filter.search_note_exclude_case and " [Aa]" or ""
        table.insert(parts, "N≠ \"" .. filter.search_note_exclude .. "\"" .. mode_str .. case_str)
    end
    -- Chapters include / exclude
    if filter.chapters and next(filter.chapters) then
        local chs = {}
        for k in pairs(filter.chapters) do table.insert(chs, k) end
        table.sort(chs)
        table.insert(parts, "Ch: " .. table.concat(chs, ", "))
    end
    if filter.chapters_exclude and next(filter.chapters_exclude) then
        local chs = {}
        for k in pairs(filter.chapters_exclude) do table.insert(chs, k) end
        table.sort(chs)
        table.insert(parts, "Ch≠ " .. table.concat(chs, ", "))
    end
    if filter.search_any and filter.search_any ~= "" then
        local case_str = filter.search_any_case and " [Aa]" or ""
        table.insert(parts, _("Search: ") .. "\"" .. filter.search_any .. "\"" .. case_str)
    end
    -- the tabs already show this, so the header row can leave it out
    if not skip_presence then
        if filter.notes_presence == "only" then
            table.insert(parts, _("Notes only"))
        elseif filter.notes_presence == "exclude" then
            table.insert(parts, _("Without notes"))
        end
    end
    return #parts > 0 and table.concat(parts, "; ") or ""
end

-- Wraps a widget so a tap on it calls callback(ges).
local TapBox = InputContainer:extend{ callback = nil }
function TapBox:init()
    local size = self[1]:getSize()
    self.dimen = Geom:new{ x = 0, y = 0, w = size.w, h = size.h }
    self.ges_events = {
        TapBox = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } },
    }
    if self.hold_callback then
        self.ges_events.HoldBox = { GestureRange:new{ ges = "hold", range = function() return self.dimen end } }
    end
end
function TapBox:onTapBox(_, ges)
    if self.callback then self.callback(ges) end
    return true
end
function TapBox:onHoldBox(_, ges)
    if self.hold_callback then self.hold_callback(ges) end
    return true
end

-- Header icon button: a KOReader icon by name, or (file) one of the plugin's icons,
-- falling back to the named icon if that file is missing.
local function newHeaderButton(icon, callback, show_parent, file, allow_flash)
    local btn = IconButton:new{
        icon = icon,
        width = HEADER_ICON_SIZE, height = HEADER_ICON_SIZE,
        padding = HEADER_ICON_PAD,
        callback = callback,
        show_parent = show_parent,
        allow_flash = allow_flash ~= false,
    }
    if file and lfs.attributes(file, "mode") == "file" then
        local img = IconWidget:new{ file = file, width = HEADER_ICON_SIZE, height = HEADER_ICON_SIZE }
        btn.image:free()
        btn.image = img
        btn.horizontal_group[2] = img
        btn:update()
    end
    return btn
end

-- Fully rounded chip filled with a colour. Draws its own fill row by row, because
-- FrameContainer's rounded fill leaves square colour corners outside the border on colour screens.
local Pill = InputContainer:extend{ width = 0, height = 0, fill = nil, border = 1, border_color = nil }
function Pill:getSize() return Geom:new{ w = self.width, h = self.height } end
function Pill:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }
    local w, h = self.width, self.height
    local r = math.floor(h / 2)
    if self.fill then
        local rgb = not BlitBuffer.isColor8(self.fill)
        for row = 0, h - 1 do
            local dy = math.abs(row + 0.5 - h / 2)
            local inset = math.ceil(r - math.sqrt(math.max(0, r * r - dy * dy)))
            if rgb then
                bb:paintRectRGB32(x + inset, y + row, w - inset * 2, 1, self.fill)
            else
                bb:paintRect(x + inset, y + row, w - inset * 2, 1, self.fill)
            end
        end
    end
    if self.border > 0 then
        bb:paintBorder(x, y, w, h, self.border, self.border_color or BlitBuffer.COLOR_BLACK, r,
            G_reader_settings:nilOrTrue("anti_alias_ui"))
    end
    if self[1] then
        local cs = self[1]:getSize()
        self[1]:paintTo(bb, x + math.floor((w - cs.w) / 2), y + math.floor((h - cs.h) / 2))
    end
end

-- Colour & style filter: a set of "color:<key>" / "style:<drawer>" entries in af.cs, and
-- af.cs_exclude to hide them instead of showing only them. Older saved filters used a single
-- af.type/af.value (and type_exclude/value_exclude); they are moved into the set here.
local function normalizeColorStyle(af)
    if not af then return end
    if af.type and af.value then
        af.cs = af.cs or {}
        af.cs[af.type .. ":" .. af.value] = true
        af.cs_exclude = false
    end
    if af.type_exclude and af.value_exclude then
        if not (af.cs and next(af.cs)) then
            af.cs = { [af.type_exclude .. ":" .. af.value_exclude] = true }
            af.cs_exclude = true
        end
    end
    af.type, af.value, af.type_exclude, af.value_exclude = nil, nil, nil, nil
    if af.cs and not next(af.cs) then af.cs, af.cs_exclude = nil, nil end
end
local function colorStyleMatches(af, note)
    local nw = NoteWrapper:new(note)
    local c, d = nw:getNormalizedColor(), nw:getNormalizedDrawer()
    local has_c, has_s, hit_c, hit_s = false, false, false, false
    for k in pairs(af.cs) do
        local t, v = k:match("^(%a+):(.+)$")
        if t == "color" then has_c = true; if v == c then hit_c = true end
        elseif t == "style" then has_s = true; if v == d then hit_s = true end end
    end
    if af.cs_exclude then return not (hit_c or hit_s) end
    -- several colours: any of them; colours and styles together: both must match
    return (not has_c or hit_c) and (not has_s or hit_s)
end

local NotesListWidget = InputContainer:extend{
    width = nil, height = nil, notes_list = nil, filtered_notes = nil,
    viewer = nil, current_page = 1, pages = nil, active_filter = nil,
    single_book = false,
    covers_fullscreen = true,
}
-- Sizes that depend on the screen and on whether a filter row is shown.
function NotesListWidget:computeLayout()
    self.width = Screen:getWidth()
    self.height = Screen:getHeight()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    local _chips, chips_h = self:buildFilterChips(self.width)
    self.chips_height = chips_h
    self.topbar_height = self.single_book and TOPBAR_BOOK_HEIGHT or TOPBAR_HEIGHT
    self.title_height = self.topbar_height + TABS_HEIGHT + chips_h
    local pag_style = getPaginationStyle()
    -- scrollbar column: its left edge (sb_x) and the middle of the track
    self.sb_x = self.width - SB_STRIP_WIDTH - SB_MARGIN_RIGHT
    self.sb_track_center = self.sb_x + math.floor(SB_STRIP_WIDTH / 2)
    if isScrollbarStyle(pag_style) then
        -- both scrollbar styles draw their controls in the side strip, not in a bottom bar
        self.footer_height = 0
    else
        self.footer_height = FOOTER_BAR_HEIGHT + Size.line.medium
    end
    self.content_height = self.height - self.title_height - self.footer_height - getTopPadding()
    -- width given to each annotation, and how far it is pushed right (landscape column)
    local avail = NoteItemWidget.listAvail(self.width)
    self.note_width = NoteItemWidget.columnWidth(avail, self.width, self.height)
    self.note_x_offset = math.floor((avail - self.note_width) / 2) + NoteItemWidget.scrollInset()
end
function NotesListWidget:init()
    self.width = Screen:getWidth()
    self.height = Screen:getHeight()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    
    self:computeLayout()
    self:applyFilter()
    self:calculatePages()
    if Device:hasKeys() then
        self.key_events.GotoPrevPage = { { Input.group.PgBack } }
        self.key_events.GotoNextPage = { { Input.group.PgFwd } }
        self.key_events.Close = { { Input.group.Back } }  
    end
    local swipe_setting = getSwipeSetting()
    if swipe_setting ~= "disabled" and not G_reader_settings:isTrue("page_turns_disable_swipe") then
        local swipe_dimen = self.dimen
        self.ges_events = {}
        if swipe_setting == "horizontal" or swipe_setting == "both" then
            self.ges_events.SwipeWest = { GestureRange:new{ ges = "swipe", range = swipe_dimen, direction = "west" } }
            self.ges_events.SwipeEast = { GestureRange:new{ ges = "swipe", range = swipe_dimen, direction = "east" } }
        end
        if swipe_setting == "vertical" or swipe_setting == "both" then
            self.ges_events.SwipeNorth = { GestureRange:new{ ges = "swipe", range = swipe_dimen, direction = "north" } }
            self.ges_events.SwipeSouth = { GestureRange:new{ ges = "swipe", range = swipe_dimen, direction = "south" } }
        end
    else
        self.ges_events = {}
    end
    
    self:updatePage()
    self.initial_update = true
end
function NotesListWidget:applyFilter()
    local function textMatches(raw, query, mode, case_sensitive)
        local text = case_sensitive and raw or raw:lower()
        local q    = case_sensitive and query or query:lower()
        if mode == "phrase" then
            return text:find(q, 1, true) ~= nil
        elseif mode == "any" then
            for word in q:gmatch("%S+") do
                if text:find(word, 1, true) then return true end
            end
            return false
        else -- "all"
            for word in q:gmatch("%S+") do
                if not text:find(word, 1, true) then return false end
            end
            return true
        end
    end
    normalizeColorStyle(self.active_filter)
    self.filtered_notes = {}
    local counts = { all = 0, highlights = 0, notes = 0 }
    for _, note in ipairs(self.notes_list) do
        local match = true
        if self.active_filter then
            local af = self.active_filter
            -- Books include / exclude
            if af.books and next(af.books) then
                match = af.books[note.book_title] == true
            end
            if match and af.books_exclude and next(af.books_exclude) then
                if af.books_exclude[note.book_title] then match = false end
            end
            -- Tags include / exclude
            if match and af.tags and next(af.tags) then
                local nw = NoteWrapper:new(note)
                local found = false
                for _, tag in ipairs(nw:getTags()) do
                    if af.tags[tag] then found = true; break end
                end
                match = found
            end
            if match and af.tags_exclude and next(af.tags_exclude) then
                local nw = NoteWrapper:new(note)
                for _, tag in ipairs(nw:getTags()) do
                    if af.tags_exclude[tag] then match = false; break end
                end
            end
            -- Chapters include / exclude
            if match and af.chapters and next(af.chapters) then
                match = note.chapter and af.chapters[note.chapter] == true
            end
            if match and af.chapters_exclude and next(af.chapters_exclude) then
                if note.chapter and af.chapters_exclude[note.chapter] then match = false end
            end
            -- Colour / style
            if match and af.cs and next(af.cs) then
                match = colorStyleMatches(af, note)
            end
            -- Highlight text include / exclude
            if match and af.search_highlight and af.search_highlight ~= "" then
                match = textMatches(note.highlighted_text or "", af.search_highlight,
                    af.search_highlight_mode or "all", af.search_highlight_case == true)
            end
            if match and af.search_highlight_exclude and af.search_highlight_exclude ~= "" then
                if textMatches(note.highlighted_text or "", af.search_highlight_exclude,
                    af.search_highlight_exclude_mode or "all", af.search_highlight_exclude_case == true) then
                    match = false
                end
            end
            -- Note text include / exclude
            if match and af.search_note and af.search_note ~= "" then
                match = textMatches(note.user_note or "", af.search_note,
                    af.search_note_mode or "all", af.search_note_case == true)
            end
            if match and af.search_note_exclude and af.search_note_exclude ~= "" then
                if textMatches(note.user_note or "", af.search_note_exclude,
                    af.search_note_exclude_mode or "all", af.search_note_exclude_case == true) then
                    match = false
                end
            end
            -- Search box: highlight or note text
            if match and af.search_any and af.search_any ~= "" then
                local case = af.search_any_case == true
                match = textMatches(note.highlighted_text or "", af.search_any, "all", case)
                    or textMatches(note.user_note or "", af.search_any, "all", case)
            end
        end
        -- Notes presence last, so the tab counts can be taken before it
        local has_note = note.user_note ~= nil and note.user_note ~= ""
        if match then
            counts.all = counts.all + 1
            if has_note then counts.notes = counts.notes + 1 else counts.highlights = counts.highlights + 1 end
            local presence = self.active_filter and self.active_filter.notes_presence
            if presence == "only" then
                match = has_note
            elseif presence == "exclude" then
                match = not has_note
            end
        end
        if match then table.insert(self.filtered_notes, note) end
    end
    self.tab_counts = counts
end
-- Scrollbar marks follow the sort order: a mark where the group changes. Books (or authors) when
-- sorted by book / author / file, months when sorted by date, chapters in one book sorted by location.
function NotesListWidget.markKey(note, single)
    local mode = getSetting("sort_mode", "date_newest")
    local by = mode:match("^(%a+)_") or "date"
    if single then
        if mode:find("location", 1, true) then return note.chapter or "" end
        return (note.datetime or ""):sub(1, 7)
    end
    if by == "date" then return (note.datetime or ""):sub(1, 7) end
    if by == "author" then return note.book_authors or "" end
    return note.book_title or ""
end
function NotesListWidget:calculatePages()
    self.pages = {}
    local note_spacing = getNoteSpacing()
    local current_page_notes, current_height = {}, 0
    
    local available_content_height = self.content_height
    -- An annotation that would end within a few pixels of the bottom goes to the next page
    -- (and shows here faded and cut off), so a page never ends flush with the screen edge.
    local end_gap = 3
    local effective_content_height = available_content_height - end_gap
    
    local dedup_prev_title = nil
    local dedup_prev_info_key = nil
    local dedup_fields = getDedupInfoFields()
    local note_width = self.note_width
    -- pages on which a new group starts (book, author, month or chapter, by sort order), for the scrollbar marks
    self.book_start_pages = {}
    local prev_mark_key
    NoteItemWidget.measure_hide_chapter = (self.single_book and NoteItemWidget.showHeadings()) and true or false
    local layout_sig = getLayoutSignature(note_width)
    local prev_chapter = nil
    for i, note in ipairs(self.filtered_notes) do
        local is_first_on_page = (#current_page_notes == 0)
        local skip_title, skip_info = getHeaderSkips(note, is_first_on_page, dedup_prev_title, dedup_prev_info_key, dedup_fields)
        if self.single_book then skip_title = true end
        local item_height = getNoteHeight(note, note_width, skip_title, skip_info, layout_sig)
        local has_ch = self.single_book and NoteItemWidget.showHeadings() and note.chapter and note.chapter ~= ""
        if has_ch and ((is_first_on_page and NoteItemWidget.repeatChapter()) or note.chapter ~= prev_chapter) then item_height = item_height + NoteItemWidget.headingHeight(note.chapter, note_width) end
        local spacing = 0
        if not is_first_on_page then
            spacing = note_spacing + (skip_title and 0 or BOOK_GAP)
        end
        local next_height = current_height + spacing + item_height
        if next_height <= effective_content_height then
            current_height = next_height
            table.insert(current_page_notes, i)
        else
            if #current_page_notes > 0 then table.insert(self.pages, current_page_notes) end
            -- Re-measure as first on the new page: the repeat options may bring headers back
            current_page_notes = {i}
            local st, si = getHeaderSkips(note, true, dedup_prev_title, dedup_prev_info_key, dedup_fields)
            if self.single_book then st = true end
            current_height = getNoteHeight(note, note_width, st, si, layout_sig) + (has_ch and NoteItemWidget.headingHeight(note.chapter, note_width) or 0)
        end
        prev_chapter = note.chapter
        local mark_key = NotesListWidget.markKey(note, self.single_book)
        if i > 1 and mark_key ~= prev_mark_key then
            self.book_start_pages[#self.pages + 1] = true
        end
        prev_mark_key = mark_key
        dedup_prev_title = note.book_title
        dedup_prev_info_key = getNoteInfoKey(note, dedup_fields)
    end
    if #current_page_notes > 0 then table.insert(self.pages, current_page_notes) end
    if #self.pages == 0 then self.pages = {{}} end
    self.total_pages = #self.pages
end
function NotesListWidget:createFooter()
    local style = getPaginationStyle()

    if isScrollbarStyle(style) then
        -- Slim scrollbar in a strip on the right: outline thumb, page number underneath,
        -- marks where books start; "Scrollbar + Buttons" adds up/down arrows at the ends.
        if self.total_pages <= 1 then return VerticalGroup:new{} end
        local self_ref = self
        local has_chevrons = (style == "scrollbar_chevrons")
        local strip_w = SB_STRIP_WIDTH
        local strip_x = self.sb_x
        local strip_y = self.title_height + SB_MARGIN_V_TOP
        local strip_h = self.height - strip_y - SB_MARGIN_V_BOTTOM
        local btn_h = has_chevrons and strip_w or 0 -- square arrow buttons, as before
        local page_label = TextWidget:new{
            text = string.format("%d/%d", self.current_page, self.total_pages),
            face = Font:getFace("cfont", 12), bold = true,
            fgcolor = COLORS.muted,
            max_width = strip_w + SB_MARGIN_RIGHT,
        }
        local label_h = page_label:getSize().h + Screen:scaleBySize(6)
        local track_y = btn_h                         -- relative to strip_y
        local track_h = strip_h - btn_h * 2 - label_h
        local total = self.total_pages
        local thumb_h = math.max(Screen:scaleBySize(16), math.floor(track_h / total))
        local travel = track_h - thumb_h
        local function pageY(p) -- top of the thumb when page p is shown
            return math.floor((p - 1) / (total - 1) * travel + 0.5)
        end
        local up_enabled = self.current_page > 1
        local dn_enabled = self.current_page < total
        local icon_size = Screen:scaleBySize(32)
        local up_icon, dn_icon
        if has_chevrons then
            up_icon = IconWidget:new{ icon = "chevron.up", width = icon_size, height = icon_size, dim = not up_enabled }
            dn_icon = IconWidget:new{ icon = "chevron.up", rotation_angle = 180, width = icon_size, height = icon_size, dim = not dn_enabled }
        end
        local marks = {}
        if getScrollbarBookMarks() then
            for p in pairs(self.book_start_pages or {}) do table.insert(marks, p) end
        end
        local range = Geom:new{ x = strip_x, y = strip_y, w = strip_w + SB_MARGIN_RIGHT, h = strip_h }
        local ScrollStrip = InputContainer:extend{}
        function ScrollStrip:init()
            self.dimen = Geom:new{ x = strip_x, y = strip_y, w = strip_w, h = strip_h }
            self.ges_events = { TapStrip = { GestureRange:new{ ges = "tap", range = range } } }
        end
        function ScrollStrip:getSize() return Geom:new{ w = strip_w, h = strip_h } end
        function ScrollStrip:onTapStrip(_, ges)
            if not ges or not ges.pos then return end
            local y = ges.pos.y - strip_y
            if has_chevrons and y < btn_h then
                if up_enabled then self_ref:onGotoPrevPage() end
            elseif has_chevrons and y >= strip_h - btn_h then
                if dn_enabled then self_ref:onGotoNextPage() end
            elseif y >= track_y and y < track_y + track_h then
                local rel = (y - track_y) / track_h
                local page = math.max(1, math.min(total, math.ceil(rel * total)))
                if page ~= self_ref.current_page then
                    self_ref.current_page = page
                    self_ref:updatePage()
                end
            end
            return true
        end
        function ScrollStrip:paintTo(bb, x, y)
            -- thumb and track positions exactly as before the redesign
            local thumb_x = x + math.floor((strip_w - SB_THUMB_WIDTH) / 2)
            local track_x = thumb_x + math.floor((SB_THUMB_WIDTH - SB_TRACK_WIDTH) / 2)
            local icon_x = x + math.floor((strip_w - icon_size) / 2)
            if up_icon then up_icon:paintTo(bb, icon_x, y) end
            local ty = y + track_y
            bb:paintRect(track_x, ty, SB_TRACK_WIDTH, track_h, COLORS.ink)
            -- same overhang on both sides of the track, so the notch is centred on it
            local mark_x = track_x - SB_MARK_OVERHANG
            local mark_w = SB_TRACK_WIDTH + SB_MARK_OVERHANG * 2
            for _i, p in ipairs(marks) do
                if p > 1 then -- the top of the track already marks page 1
                    bb:paintRect(mark_x, ty + pageY(p) + math.floor(thumb_h / 2), mark_w, SB_MARK_HEIGHT, COLORS.ink)
                end
            end
            local thumb_y = ty + pageY(self_ref.current_page)
            local radius = math.floor(SB_THUMB_WIDTH / 2)
            bb:paintRoundedRect(thumb_x, thumb_y, SB_THUMB_WIDTH, thumb_h, BlitBuffer.COLOR_WHITE, radius)
            -- Size.border.default = 1px at 160dpi, scaled up on denser screens like the thumb itself
            bb:paintBorder(thumb_x, thumb_y, SB_THUMB_WIDTH, thumb_h, Size.border.default, BlitBuffer.COLOR_BLACK, radius)
            local lw = page_label:getSize().w
            page_label:paintTo(bb, track_x - math.floor(lw / 2), ty + track_h + Screen:scaleBySize(6))
            if dn_icon then dn_icon:paintTo(bb, icon_x, y + strip_h - icon_size) end
        end
        return VerticalGroup:new{
            VerticalSpan:new{ width = strip_y },
            HorizontalGroup:new{ HorizontalSpan:new{ width = strip_x }, ScrollStrip:new{} },
        }
    else
        -- Bottom bar as in the mockup: thin line on top, "‹ Prev" left, "1 / 4" centred,
        -- "Next ›" right, with first / last page buttons on the outside (holding Prev / Next
        -- also jumps to the first / last page).
        local chevron_left, chevron_right = "chevron.left", "chevron.right"
        local chevron_first, chevron_last = "chevron.first", "chevron.last"
        if BD.mirroredUILayout() then
            chevron_left, chevron_right = chevron_right, chevron_left
            chevron_first, chevron_last = chevron_last, chevron_first
        end
        local has_prev = self.current_page > 1
        local has_next = self.current_page < self.total_pages
        local face = Font:getFace("cfont", 13)
        local icon = Screen:scaleBySize(20)
        local function pageButton(text, icon_name, icon_first, enabled, callback, hold_callback)
            local tw = TextWidget:new{ text = text, face = face, bold = enabled,
                fgcolor = enabled and COLORS.ink or COLORS.disabled }
            local iw = IconWidget:new{ icon = icon_name, width = icon, height = icon, dim = not enabled }
            local row = icon_first and HorizontalGroup:new{ align = "center", iw, HorizontalSpan:new{ width = Screen:scaleBySize(4) }, tw }
                or HorizontalGroup:new{ align = "center", tw, HorizontalSpan:new{ width = Screen:scaleBySize(4) }, iw }
            return TapBox:new{
                CenterContainer:new{ dimen = Geom:new{ w = row:getSize().w + Screen:scaleBySize(20), h = FOOTER_BAR_HEIGHT }, row },
                callback = function() if enabled then callback() end end,
                hold_callback = function() if enabled then hold_callback() end end,
            }
        end
        -- first / last page: icon only, next to Prev / Next
        local function jumpButton(icon_name, enabled, callback)
            local iw = IconWidget:new{ icon = icon_name, width = icon, height = icon, dim = not enabled }
            return TapBox:new{
                CenterContainer:new{ dimen = Geom:new{ w = icon + Screen:scaleBySize(20), h = FOOTER_BAR_HEIGHT }, iw },
                callback = function() if enabled then callback() end end,
            }
        end
        local function goFirst() self.current_page = 1; self:updatePage() end
        local function goLast() self.current_page = self.total_pages; self:updatePage() end
        local bar_dimen = Geom:new{ w = self.width, h = FOOTER_BAR_HEIGHT }
        local side = Screen:scaleBySize(12) - Screen:scaleBySize(10) -- mockup padding minus the button's own
        local bar = OverlapGroup:new{
            dimen = bar_dimen, allow_mirroring = false,
            LeftContainer:new{ dimen = bar_dimen, HorizontalGroup:new{ HorizontalSpan:new{ width = side },
                jumpButton(chevron_first, has_prev, goFirst),
                pageButton(_("Prev"), chevron_left, true, has_prev,
                    function() self:onGotoPrevPage() end, goFirst) } },
            CenterContainer:new{ dimen = bar_dimen, TextWidget:new{
                text = string.format("%d / %d", self.current_page, self.total_pages), face = face, bold = true } },
            RightContainer:new{ dimen = bar_dimen, HorizontalGroup:new{
                pageButton(_("Next"), chevron_right, false, has_next,
                    function() self:onGotoNextPage() end, goLast),
                jumpButton(chevron_last, has_next, goLast),
                HorizontalSpan:new{ width = side } } },
        }
        return BottomContainer:new{
            dimen = Geom:new{ w = self.width, h = self.height },
            FrameContainer:new{
                width = self.width, padding = 0, margin = 0, bordersize = 0,
                background = BlitBuffer.COLOR_WHITE,
                VerticalGroup:new{
                    LineWidget:new{ dimen = Geom:new{ w = self.width, h = Size.line.medium }, background = COLORS.line },
                    bar,
                },
            },
        }
    end
end
-- Label for the sort button in the tab row, e.g. "Newest first" or "Book · A to Z (by Date)".
local SORT_CATEGORY_LABELS = { author = _("Author"), book = _("Book"), filename = _("Filename") }
local SORT_SHORT_LABELS = {
    date_newest = _("Newest first"), date_oldest = _("Oldest first"),
    asc = _("A–Z"), desc = _("Z–A"),
    location_asc = _("start to end"), location_desc = _("end to start"),
}
local function sortModeLabel(mode)
    if not SORT_MODES[mode] then mode = "date_newest" end
    if SORT_SHORT_LABELS[mode] then return SORT_SHORT_LABELS[mode] end
    local cat, rest = mode:match("^(%a+)_(.+)$")
    return (SORT_CATEGORY_LABELS[cat] or cat) .. " · " .. (SORT_SHORT_LABELS[rest] or SORT_MODES[mode].label)
end

-- Active-filter chips under the tabs: one black chip per filter (tap to remove it),
-- "Clear all", and "N of M" on the right. Laid out over as many rows as needed.
local STYLE_NAMES = { lighten = _("Lighten"), underscore = _("Underline"), strikeout = _("Strikeout"), invert = _("Invert") }
local function colorName(key)
    for _i, v in ipairs(ReaderHighlight.highlight_colors) do
        if v[2] == key then return v[1] end
    end
    return key and (key:sub(1, 1):upper() .. key:sub(2)) or ""
end
local function setLabel(set, many)
    local keys = {}
    for k in pairs(set) do table.insert(keys, k) end
    if #keys == 1 then return keys[1] end
    return string.format(many, #keys)
end
local CHIP_HEIGHT = Screen:scaleBySize(32)
local CHIP_GAP = Screen:scaleBySize(8)
local CHIPS_PAD_TOP, CHIPS_PAD_BOTTOM = Screen:scaleBySize(6), Screen:scaleBySize(6)

function NotesListWidget:getFilterChips()
    local af = self.active_filter or {}
    local chips = {}
    -- prefix: shown before the colour dot ("Hide ● Yellow")
    local function add(label, clear, colors, prefix)
        table.insert(chips, { label = label, clear = clear, colors = colors, prefix = prefix })
    end
    local function quoted(t) return "“" .. t .. "”" end
    normalizeColorStyle(af)
    if af.cs and next(af.cs) then
        local keys = {}
        for k in pairs(af.cs) do table.insert(keys, k) end
        table.sort(keys)
        local prefix = af.cs_exclude and _("Hide") or nil
        for _i, k in ipairs(keys) do
            local t, v = k:match("^(%a+):(.+)$")
            local function clear() af.cs[k] = nil; if not next(af.cs) then af.cs, af.cs_exclude = nil, nil end end
            if t == "color" then
                add(colorName(v), clear, { v }, prefix)
            else
                add((prefix and (prefix .. " ") or "") .. (STYLE_NAMES[v] or v), clear)
            end
        end
    end
    if af.books and next(af.books) then add(setLabel(af.books, _("%d books")), function() af.books = nil end) end
    if af.books_exclude and next(af.books_exclude) then
        add(_("Hide") .. " " .. setLabel(af.books_exclude, _("%d books")), function() af.books_exclude = nil end)
    end
    if af.chapters and next(af.chapters) then add(setLabel(af.chapters, _("%d chapters")), function() af.chapters = nil end) end
    if af.chapters_exclude and next(af.chapters_exclude) then
        add(_("Hide") .. " " .. setLabel(af.chapters_exclude, _("%d chapters")), function() af.chapters_exclude = nil end)
    end
    if af.tags and next(af.tags) then add(setLabel(af.tags, _("%d tags")), function() af.tags = nil end) end
    if af.tags_exclude and next(af.tags_exclude) then
        add(_("Hide") .. " " .. setLabel(af.tags_exclude, _("%d tags")), function() af.tags_exclude = nil end)
    end
    if af.search_any and af.search_any ~= "" then add(quoted(af.search_any), function() af.search_any = nil end) end
    if af.search_highlight and af.search_highlight ~= "" then
        add(_("Highlight:") .. " " .. quoted(af.search_highlight), function() af.search_highlight = nil end)
    end
    if af.search_highlight_exclude and af.search_highlight_exclude ~= "" then
        add(_("Highlight not:") .. " " .. quoted(af.search_highlight_exclude), function() af.search_highlight_exclude = nil end)
    end
    if af.search_note and af.search_note ~= "" then
        add(_("Note:") .. " " .. quoted(af.search_note), function() af.search_note = nil end)
    end
    if af.search_note_exclude and af.search_note_exclude ~= "" then
        add(_("Note not:") .. " " .. quoted(af.search_note_exclude), function() af.search_note_exclude = nil end)
    end
    return chips
end

-- Builds the chips area for width w. Returns the widget (nil when no filters) and its height.
function NotesListWidget:buildFilterChips(w)
    local chips = self:getFilterChips()
    if #chips == 0 then return nil, 0 end
    local side = Screen:scaleBySize(24)
    local face = Font:getFace("cfont", 13)
    local small = Font:getFace("cfont", 12)
    local count_w = TextWidget:new{ text = string.format(_("%d of %d"), 9999, 9999), face = small }:getSize().w + Screen:scaleBySize(8)
    local avail = w - side * 2
    local items = {}
    for _i, c in ipairs(chips) do
        local content = HorizontalGroup:new{ align = "center" }
        if c.prefix then
            table.insert(content, TextWidget:new{ text = c.prefix, face = face, fgcolor = BlitBuffer.COLOR_WHITE })
            table.insert(content, HorizontalSpan:new{ width = Screen:scaleBySize(6) })
        end
        if c.colors then
            for _j, key in ipairs(c.colors) do
                table.insert(content, Pill:new{ width = Screen:scaleBySize(10), height = Screen:scaleBySize(10), border = 0, true_color = true,
                    fill = key == "gray" and BlitBuffer.COLOR_GRAY or getHighlightColor(key) })
                table.insert(content, HorizontalSpan:new{ width = Screen:scaleBySize(6) })
            end
        end
        table.insert(content, TextWidget:new{ text = c.label, face = face, fgcolor = BlitBuffer.COLOR_WHITE,
            max_width = math.floor(avail * 0.6) })
        table.insert(content, HorizontalSpan:new{ width = Screen:scaleBySize(4) })
        -- KOReader's close icon, inverted to white-on-black to sit on the black chip
        table.insert(content, IconWidget:new{ icon = "close", width = Screen:scaleBySize(14), height = Screen:scaleBySize(14), invert = true })
        local chip_w = content:getSize().w + Screen:scaleBySize(20)
        table.insert(items, { w = chip_w, widget = TapBox:new{
            Pill:new{ width = chip_w, height = CHIP_HEIGHT, fill = BlitBuffer.COLOR_BLACK, border = 0, content },
            callback = function()
                c.clear()
                self.current_page = 1
                self:refresh()
            end,
        } })
    end
    local clear = TextWidget:new{ text = _("Clear all"), face = face }
    local clear_sz = clear:getSize()
    local clear_w = clear_sz.w + Screen:scaleBySize(16)
    table.insert(items, { w = clear_w, widget = TapBox:new{
        CenterContainer:new{ dimen = Geom:new{ w = clear_w, h = CHIP_HEIGHT }, VerticalGroup:new{ clear,
            LineWidget:new{ dimen = Geom:new{ w = clear_sz.w, h = Size.line.medium }, background = BlitBuffer.COLOR_BLACK } } },
        callback = function() self:clearFilters() end,
    } })
    -- flow into rows; the first row keeps room for the count on the right
    local rows = VerticalGroup:new{ align = "left" }
    local row, row_w, limit = HorizontalGroup:new{ align = "center" }, 0, avail - count_w
    local n_rows = 1
    for _i, it in ipairs(items) do
        if row_w > 0 and row_w + CHIP_GAP + it.w > limit then
            table.insert(rows, row)
            table.insert(rows, VerticalSpan:new{ width = CHIP_GAP })
            row, row_w, limit = HorizontalGroup:new{ align = "center" }, 0, avail
            n_rows = n_rows + 1
        end
        if row_w > 0 then table.insert(row, HorizontalSpan:new{ width = CHIP_GAP }); row_w = row_w + CHIP_GAP end
        table.insert(row, it.widget)
        row_w = row_w + it.w
    end
    table.insert(rows, row)
    local h = CHIPS_PAD_TOP + n_rows * CHIP_HEIGHT + (n_rows - 1) * CHIP_GAP + CHIPS_PAD_BOTTOM + Size.line.thin
    local count = TextWidget:new{
        text = string.format(_("%d of %d"), #(self.filtered_notes or {}), #(self.notes_list or {})),
        face = small, fgcolor = COLORS.muted,
    }
    local first_row = Geom:new{ w = avail, h = CHIP_HEIGHT }
    local area = VerticalGroup:new{ align = "left",
        VerticalSpan:new{ width = CHIPS_PAD_TOP },
        HorizontalGroup:new{ HorizontalSpan:new{ width = side },
            OverlapGroup:new{ dimen = Geom:new{ w = avail, h = rows:getSize().h }, allow_mirroring = false,
                rows,
                RightContainer:new{ dimen = first_row, count },
            },
        },
        VerticalSpan:new{ width = CHIPS_PAD_BOTTOM },
        HorizontalGroup:new{ HorizontalSpan:new{ width = side },
            LineWidget:new{ dimen = Geom:new{ w = avail, h = Size.line.thin }, background = COLORS.line } },
    }
    return area, h
end

-- Top bar, tab row and (when filters are on) the active-filter row. Height is self.title_height.
function NotesListWidget:buildHeader()
    local w = self.width
    local side = Screen:scaleBySize(8)
    local h_pad = getHMargin() + Size.padding.default
    if h_pad > Screen:scaleBySize(24) then h_pad = Screen:scaleBySize(24) end
    local header = VerticalGroup:new{ align = "left" }

    -- 1. top bar
    local title
    local bar_h = self.topbar_height or TOPBAR_HEIGHT
    if self.single_book then
        -- one book: its title, and "Author · N annotations" underneath
        local first = self.notes_list and self.notes_list[1] or {}
        local book_title = self.book_title or first.book_title or _("Annotations")
        local authors = first.book_authors and NoteWrapper:new(first):getDisplayAuthors()
        local n = #(self.notes_list or {})
        local sub = (n == 1) and _("1 annotation") or string.format(_("%d annotations"), n)
        if authors and authors ~= "" and authors ~= "Unknown" then sub = authors .. " · " .. sub end
        local max_w = math.floor(w * 0.55)
        local t = TextWidget:new{ text = book_title, face = getFaceOr(SERIF_FONT, 19, "cfont"), bold = true, max_width = max_w }
        local st = TextWidget:new{ text = sub, face = Font:getFace("cfont", 12), fgcolor = COLORS.muted, max_width = max_w }
        -- Text boxes include room for descenders and line gap; placing the second line from
        -- the title's baseline keeps the two lines close together, like in the mockup.
        local cap = math.floor(Screen:scaleBySize(12) * 0.72)
        local sub_y = t:getBaseline() + Screen:scaleBySize(5) - (st:getBaseline() - cap)
        local tsz, ssz = t:getSize(), st:getSize()
        st.overlap_offset = { 0, sub_y }
        title = OverlapGroup:new{ allow_mirroring = false,
            dimen = Geom:new{ w = math.max(tsz.w, ssz.w), h = math.max(tsz.h, sub_y + ssz.h) }, t, st }
    else
        title = TextWidget:new{
            text = _("Annotations"), face = getFaceOr(SERIF_FONT, 21, "cfont"), bold = true,
            max_width = math.floor(w / 2),
        }
    end
    local right = HorizontalGroup:new{ align = "center" }
    table.insert(right, newHeaderButton("appbar.search", function() self:showSearchDialog() end, self))
    if getFilterTitlebarBtn() then
        local fbtn = newHeaderButton("appbar.settings", function() self:showFilterMenu(false) end, self,
            pluginIcon("appbar.filter"))
        local n = #self:getFilterChips()
        if n > 0 then
            -- small black badge with the number of active filters, top right of the icon
            local d = Screen:scaleBySize(16)
            local num = TextWidget:new{ text = tostring(n), face = Font:getFace("cfont", 10), bold = true, fgcolor = BlitBuffer.COLOR_WHITE }
            local badge = Pill:new{ width = d, height = d, fill = BlitBuffer.COLOR_BLACK, border = 0, num }
            local bs = fbtn:getSize()
            badge.overlap_offset = { bs.w - d - Screen:scaleBySize(4), Screen:scaleBySize(4) }
            fbtn = OverlapGroup:new{ dimen = Geom:new{ w = bs.w, h = bs.h }, allow_mirroring = false, fbtn, badge }
        end
        table.insert(right, fbtn)
    end
    table.insert(right, newHeaderButton("close", function() self:onClose() end, self, nil, false))
    table.insert(right, HorizontalSpan:new{ width = side })
    local bar_dimen = Geom:new{ w = w, h = bar_h }
    table.insert(header, OverlapGroup:new{
        dimen = bar_dimen, allow_mirroring = false,
        LeftContainer:new{ dimen = bar_dimen, HorizontalGroup:new{
            align = "center",
            HorizontalSpan:new{ width = side },
            newHeaderButton("appbar.menu", function() self:showMainMenu() end, self),
            -- same space between icon and title as between the screen edge and the icon
            HorizontalSpan:new{ width = side },
            title,
        } },
        RightContainer:new{ dimen = bar_dimen, right },
    })

    -- 2. tabs: All / Highlights (no note) / Notes, plus the sort button
    local counts = self.tab_counts or { all = 0, highlights = 0, notes = 0 }
    local presence = self.active_filter and self.active_filter.notes_presence
    local show_counts = getShowTotalNotes()
    local tab_face = Font:getFace("cfont", 15)
    local line_h = Size.line.thin
    local underline_h = Screen:scaleBySize(2)
    local row_h = TABS_HEIGHT - line_h
    local tabs = HorizontalGroup:new{ align = "top", HorizontalSpan:new{ width = h_pad } }
    for i, tab in ipairs({
        { key = nil,       label = _("All"),        n = counts.all },
        { key = "exclude", label = _("Highlights"), n = counts.highlights },
        { key = "only",    label = _("Notes"),      n = counts.notes },
    }) do
        local active = (presence == tab.key)
        local text = tab.label .. (show_counts and ("  " .. tab.n) or "")
        local tw = TextWidget:new{
            text = text, face = tab_face, bold = active,
            fgcolor = active and COLORS.ink or COLORS.muted,
        }
        local tab_w = tw:getSize().w
        local box = VerticalGroup:new{
            CenterContainer:new{ dimen = Geom:new{ w = tab_w, h = row_h - underline_h }, tw },
            active and LineWidget:new{ dimen = Geom:new{ w = tab_w, h = underline_h }, background = BlitBuffer.COLOR_BLACK }
                or VerticalSpan:new{ width = underline_h },
        }
        if i > 1 then table.insert(tabs, HorizontalSpan:new{ width = Screen:scaleBySize(20) }) end
        table.insert(tabs, TapBox:new{ box, callback = function() self:setNotesPresence(tab.key) end })
    end
    local sort_text = TextWidget:new{
        text = sortModeLabel(getSetting("sort_mode", "date_newest")),
        face = Font:getFace("cfont", 13), fgcolor = COLORS.muted,
        max_width = math.floor(w * 0.4),
    }
    local arrow_size = Screen:scaleBySize(14)
    local sort_label = HorizontalGroup:new{
        align = "center", sort_text, HorizontalSpan:new{ width = Screen:scaleBySize(3) },
        IconWidget:new{ icon = "chevron.up", rotation_angle = 180, width = arrow_size, height = arrow_size },
    }
    local sort_btn = TapBox:new{
        CenterContainer:new{ dimen = Geom:new{ w = sort_label:getSize().w + h_pad, h = row_h }, sort_label },
        callback = function() self:showSortMenu(false) end,
    }
    local tabs_dimen = Geom:new{ w = w, h = row_h }
    table.insert(header, OverlapGroup:new{
        dimen = tabs_dimen, allow_mirroring = false,
        LeftContainer:new{ dimen = tabs_dimen, tabs },
        RightContainer:new{ dimen = tabs_dimen, HorizontalGroup:new{ sort_btn, HorizontalSpan:new{ width = math.floor(h_pad / 2) } } },
    })
    table.insert(header, LineWidget:new{ dimen = Geom:new{ w = w, h = line_h }, background = COLORS.line })

    -- 3. active-filter chips (the tab is not repeated here)
    local chips = self:buildFilterChips(w)
    if chips then table.insert(header, chips) end
    return header
end

function NotesListWidget:setNotesPresence(key)
    self.active_filter = self.active_filter or {}
    if self.active_filter.notes_presence == key then return end
    self.active_filter.notes_presence = key
    self.current_page = 1
    self:refresh()
end

-- Remove all filters except the tab that is selected.
function NotesListWidget:clearFilters()
    local presence = self.active_filter and self.active_filter.notes_presence
    self.active_filter = { notes_presence = presence }
    self.current_page = 1
    self:refresh()
end

function NotesListWidget:showSearchDialog(on_done)
    local InputDialog = require("ui/widget/inputdialog")
    local af = self.active_filter or {}
    local dialog
    local buttons
    local run
    function run(text)
        UIManager:close(dialog)
        self.active_filter = self.active_filter or {}
        self.active_filter.search_any = (text and text ~= "") and text or nil
        self.current_page = 1
        self:refresh()
        if on_done then on_done() end
    end
    buttons = {{
        { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
        { text = _("Clear"), callback = function() run(nil) end },
        { text = _("Search"), is_enter_default = true, callback = function() run(dialog:getInputText()) end },
    }}
    dialog = InputDialog:new{
        title = _("Search annotations"),
        input = af.search_any or "",
        input_hint = _("Words in highlights or notes"),
        buttons = buttons,
    }
    NotesListWidget.showDialog(dialog)
    dialog:onShowKeyboard()
end

function NotesListWidget:updatePage()
    self:computeLayout()
    local pag_style = getPaginationStyle()
    local header = self:buildHeader()

    local notes_group = VerticalGroup:new{ align = "left" }
    local top_padding = getTopPadding()
    if top_padding > 0 then
        table.insert(notes_group, VerticalSpan:new{ width = top_padding })
    end
    local x_offset = self.note_x_offset or 0
    local function place(widget)
        if x_offset > 0 then
            return HorizontalGroup:new{ HorizontalSpan:new{ width = x_offset }, widget }
        end
        return widget
    end

    local page_indices = self.pages[self.current_page] or {}
    local prev_chapter = nil
    local last_note_widget = nil
    -- vertical extent of each drawn annotation (relative to the top of the notes area),
    -- used by onTap() to find what was tapped
    local tap_rows = {}
    local row_y = top_padding
    local note_spacing = getNoteSpacing()
    local dedup_fields = getDedupInfoFields()
    local note_width = self.note_width
    -- determine dedup state from last note of previous page
    local dedup_prev_title = nil
    local dedup_prev_info_key = nil
    do
        local prev_page = self.pages[self.current_page - 1]
        if prev_page and #prev_page > 0 then
            local prev_note = self.filtered_notes[prev_page[#prev_page]]
            if prev_note then
                dedup_prev_title = prev_note.book_title
                dedup_prev_info_key = getNoteInfoKey(prev_note, dedup_fields)
            end
        end
    end
    for i, idx in ipairs(page_indices) do
        local note = self.filtered_notes[idx]
        if note then
            local is_first_on_page = (i == 1)
            local skip_title, skip_info = getHeaderSkips(note, is_first_on_page, dedup_prev_title, dedup_prev_info_key, dedup_fields)
            if self.single_book then skip_title = true end
            if not is_first_on_page then
                local gap = note_spacing + (skip_title and 0 or BOOK_GAP)
                table.insert(notes_group, VerticalSpan:new{ width = gap })
                row_y = row_y + gap
            end
            if self.single_book and NoteItemWidget.showHeadings() and note.chapter and note.chapter ~= "" and ((is_first_on_page and NoteItemWidget.repeatChapter()) or note.chapter ~= prev_chapter) then
                table.insert(notes_group, place(NoteItemWidget.chapterHeading(note.chapter, note_width)))
                row_y = row_y + NoteItemWidget.headingHeight(note.chapter, note_width)
            end
            prev_chapter = note.chapter
            local note_widget = NoteItemWidget:new{ width = note_width, note = note, show_parent = self, skip_title = skip_title, skip_info = skip_info }
            table.insert(notes_group, place(note_widget))
            table.insert(tap_rows, { top = row_y, bottom = row_y + note_widget.dimen.h, note = note })
            row_y = row_y + note_widget.dimen.h
            if i == #page_indices then last_note_widget = note_widget end
            dedup_prev_title = note.book_title
            dedup_prev_info_key = getNoteInfoKey(note, dedup_fields)
        end
    end

    -- Last page of a filtered list: say how many annotations the filters hide, with a way back
    if #page_indices > 0 and self.current_page == self.total_pages then
        local active = false
        for k, v in pairs(self.active_filter or {}) do
            if k ~= "notes_presence" and v and (type(v) ~= "table" or next(v)) then active = true end
        end
        local hidden = #self.notes_list - #self.filtered_notes
        if active and hidden > 0 then
            local used = 0
            for _i, w in ipairs(notes_group) do if w.getSize then used = used + w:getSize().h end end
            local face = Font:getFace("cfont", 13)
            local msg = TextWidget:new{ text = string.format(hidden == 1 and _("1 more annotation is hidden by filters") or _("%d more annotations are hidden by filters"), hidden),
                face = face, fgcolor = COLORS.muted, max_width = self.note_width - 2 * getHMargin() }
            local link = TextWidget:new{ text = _("Show all"), face = face }
            local line = LineWidget:new{ dimen = Geom:new{ w = link:getSize().w, h = Size.line.medium }, background = BlitBuffer.COLOR_BLACK }
            local gap = Screen:scaleBySize(16)
            local box_h = gap + msg:getSize().h + Screen:scaleBySize(8) + link:getSize().h + line:getSize().h + gap
            if used + box_h <= self.height - self.title_height - self.footer_height then
                table.insert(notes_group, place(CenterContainer:new{ dimen = Geom:new{ w = self.note_width, h = box_h },
                    VerticalGroup:new{ align = "center", msg, VerticalSpan:new{ width = Screen:scaleBySize(8) },
                        VerticalGroup:new{ link, line } } }))
                table.insert(tap_rows, { top = used + gap + msg:getSize().h, bottom = used + box_h,
                    action = function() self:clearFilters() end })
            end
        end
    end

    -- Filters (or the tab) leave nothing: say so in the middle of the list
    if #page_indices == 0 and NotesListWidget.States then
        notes_group = NotesListWidget.States.noMatch(self, self.width,
            self.height - self.title_height - self.footer_height)
    end

    -- First annotation of the next page, faded and cut off, as a hint that there is more
    if last_note_widget and self.current_page < self.total_pages then
        local next_page_indices = self.pages[self.current_page + 1]
        local next_note = next_page_indices and next_page_indices[1] and self.filtered_notes[next_page_indices[1]]
        if next_note then
            local used_height = 0
            for _i, w in ipairs(notes_group) do
                if w.getSize then used_height = used_height + w:getSize().h end
            end
            local available_height = self.height - self.title_height - self.footer_height - used_height - note_spacing - 2
            if available_height > 0 then
                local preview_skip_title, preview_skip_info = getHeaderSkips(next_note, false, dedup_prev_title, dedup_prev_info_key, dedup_fields)
                if self.single_book then preview_skip_title = true end
                local preview_widget = NoteItemWidget:new{
                    width = note_width, note = next_note, show_parent = self,
                    is_preview = true, disable_tap = true,
                    skip_title = preview_skip_title, skip_info = preview_skip_info,
                }
                local AlphaContainer = require("ui/widget/container/alphacontainer")
                table.insert(notes_group, VerticalSpan:new{ width = note_spacing })
                table.insert(notes_group, place(AlphaContainer:new{
                    alpha = 0.2,
                    FrameContainer:new{
                        width = note_width, height = available_height,
                        padding = 0, margin = 0, bordersize = 0,
                        preview_widget,
                    },
                }))
            end
        end
    end

    local footer = self:createFooter()
    self.tap_rows = tap_rows
    self.tap_rows_origin_y = self.title_height
    local list_height = self.height - self.title_height - self.footer_height

    local content = OverlapGroup:new{
        allow_mirroring = false,
        dimen = Geom:new{ w = self.width, h = self.height },
        VerticalGroup:new{
            align = "left",
            header,
            TopContainer:new{ dimen = Geom:new{ w = self.width, h = list_height }, notes_group },
        },
        footer,
    }

    self[1] = FrameContainer:new{
        width = self.width, height = self.height, padding = 0, margin = 0, bordersize = 0,
        background = BlitBuffer.COLOR_WHITE,
        content,
    }

    self.ges_events = self.ges_events or {}
    local tap_height = self.height - self.title_height - self.footer_height
    -- In scrollbar mode, exclude the scrollbar column so taps/swipes there reach the strip
    local tap_width = self.width
    if isScrollbarStyle(pag_style) and self.sb_x then
        tap_width = self.sb_x
    end
    self.ges_events.Tap = { GestureRange:new{ ges = "tap", range = Geom:new{ x = 0, y = self.title_height, w = tap_width, h = tap_height } } }
    -- Narrow swipe range so the scrollbar column isn't claimed by page-turn swipes
    local swipe_range = Geom:new{ x = 0, y = 0, w = tap_width, h = self.height }
    local swipe_setting = getSwipeSetting()
    local horiz = swipe_setting == "horizontal" or swipe_setting == "both"
    local vert = swipe_setting == "vertical" or swipe_setting == "both"
    self.ges_events.SwipeWest  = horiz and { GestureRange:new{ ges = "swipe", range = swipe_range, direction = "west" } } or nil
    self.ges_events.SwipeEast  = horiz and { GestureRange:new{ ges = "swipe", range = swipe_range, direction = "east" } } or nil
    self.ges_events.SwipeNorth = vert and { GestureRange:new{ ges = "swipe", range = swipe_range, direction = "north" } } or nil
    self.ges_events.SwipeSouth = vert and { GestureRange:new{ ges = "swipe", range = swipe_range, direction = "south" } } or nil

    UIManager:setDirty(self, "ui")
end
function NotesListWidget:showMainMenu()
    NotesListWidget.States.menu(self)
end
-- Builds Markdown for a list of notes, grouped under a heading per book (in list order).
local function notesToMarkdown(notes, filter_label)
    local out = { "# " .. _("Annotations"), "" }
    if filter_label and filter_label ~= "" then
        table.insert(out, "_" .. _("Filter") .. ": " .. filter_label .. "_")
        table.insert(out, "")
    end
    local current_book
    for _i, note in ipairs(notes) do
        local book = note.book_title or "Unknown"
        if book ~= current_book then
            current_book = book
            local authors = note.book_authors
            table.insert(out, "## " .. book .. ((authors and authors ~= "") and (" — " .. tostring(authors)) or ""))
            table.insert(out, "")
        end
        local meta = {}
        if note.datetime and note.datetime ~= "" then table.insert(meta, note.datetime:sub(1, 10)) end
        if note.chapter and note.chapter ~= "" then table.insert(meta, note.chapter) end
        if note.page then table.insert(meta, _("page") .. " " .. tostring(note.page)) end
        if #meta > 0 then table.insert(out, "*" .. table.concat(meta, " · ") .. "*") end
        local text = note.highlighted_text or ""
        if text:find("%S") then
            for line in (text:gsub("\r", "") .. "\n"):gmatch("([^\n]*)\n") do
                table.insert(out, "> " .. line)
            end
        end
        local user_note = note.user_note or ""
        if user_note:find("%S") then
            table.insert(out, "")
            table.insert(out, "**" .. _("Note") .. ":** " .. user_note:gsub("\r", ""):gsub("\n", "  \n"))
        end
        table.insert(out, "")
    end
    return table.concat(out, "\n")
end

-- Writes the annotations currently in the list (with the active filter and sort order)
-- to a Markdown file in KOReader's data folder.
function NotesListWidget:exportToMarkdown()
    local notes = self.filtered_notes or {}
    if #notes == 0 then
        NotesListWidget.showDialog(InfoMessage:new{ text = _("Nothing to export.") })
        return
    end
    local DataStorage = require("datastorage")
    local dir = DataStorage:getDataDir() .. "/exports"
    if lfs.attributes(dir, "mode") ~= "directory" then lfs.mkdir(dir) end
    local path = dir .. "/annotations-" .. os.date("%Y%m%d-%H%M%S") .. ".md"
    local file, err = io.open(path, "w")
    if not file then
        NotesListWidget.showDialog(InfoMessage:new{ text = _("Export failed:") .. " " .. tostring(err) })
        return
    end
    file:write(notesToMarkdown(notes, filterToString(self.active_filter)))
    file:close()
    NotesListWidget.States.exported(#notes, path)
end

-- back_to_menu == false: opened from the sort button in the tab row, so don't reopen the ☰ menu.
function NotesListWidget:showSortMenu(_back_to_menu, on_done)
    NotesListWidget.States.sortMenu(self, on_done)
end
function NotesListWidget:showSpinMenu(_menu_key, _parent_callback)
    self:showSettingsMenu() -- the numbers are rows on the Settings page now
end
function NotesListWidget:applySort()
    local sort_mode = getSetting("sort_mode", "date_newest")
    self:sortNotesList(self.notes_list, sort_mode)
end
function NotesListWidget:sortNotesList(notes_list, sort_mode)
    sort_mode = sort_mode or getSetting("sort_mode", "date_newest")
    local comparator = SORT_COMPARATORS[sort_mode]
    if comparator then
        table.sort(notes_list, comparator)
    end
    return notes_list
end
function NotesListWidget:showSettingsMenu()
    -- the sub-dialogs (spin settings, typefaces) come back here: rebuild the page if it is open
    if self.settings_screen then
        self.settings_screen:rebuild()
        return
    end
    self.settings_screen = NotesListWidget.SettingsScreen:new{ list = self }
    UIManager:show(self.settings_screen, "flashui")
end
function NotesListWidget:showPaginationStyleMenu()
    local current = getPaginationStyle()
    local function check(v) return current == v and "\u{2713} " or "  " end
    local function apply(v)
        setSetting("pagination_style", v)
        UIManager:close(self.pagination_style_dialog)
        self:refresh()
        self:showSettingsMenu()
    end
    local buttons = {
        {{ text = check("default")   .. _("Prev / Next Buttons"), callback = function() apply("default")   end }},
        {{ text = check("scrollbar") .. _("Scrollbar"),                           callback = function() apply("scrollbar") end }},
        {{ text = check("scrollbar_chevrons") .. _("Scrollbar + Buttons"),        callback = function() apply("scrollbar_chevrons") end }},
        {{ text = _("Back"), callback = function()
            UIManager:close(self.pagination_style_dialog)
            self:showSettingsMenu()
        end }},
    }
    self.pagination_style_dialog = ButtonDialogTitle:new{ title = _("Pagination Style"), buttons = buttons }
    NotesListWidget.showDialog(self.pagination_style_dialog)
end
function NotesListWidget:showSwipeSettingMenu()
    local current = getSwipeSetting()
    local function check(v) return current == v and "\u{2713} " or "  " end
    local function apply(v)
        setSetting("swipe_direction", v)
        UIManager:close(self.swipe_dialog)
        self:refresh()
        self:showSettingsMenu()
    end
    local buttons = {
        {{ text = check("both")       .. _("Both (horizontal + vertical)"), callback = function() apply("both")       end }},
        {{ text = check("horizontal") .. _("Horizontal only"),              callback = function() apply("horizontal") end }},
        {{ text = check("vertical")   .. _("Vertical only"),                callback = function() apply("vertical")   end }},
        {{ text = check("disabled")   .. _("Disabled"),                     callback = function() apply("disabled")   end }},
        {{ text = _("Back"), callback = function()
            UIManager:close(self.swipe_dialog)
            self:showSettingsMenu()
        end }},
    }
    self.swipe_dialog = ButtonDialogTitle:new{ title = _("Swipe Gestures"), buttons = buttons }
    NotesListWidget.showDialog(self.swipe_dialog)
end
function NotesListWidget:showInfoFieldsMenu()
    local fields_setting = getInfoFields()
    local active = {}
    for f in fields_setting:gmatch("[^,]+") do active[f] = true end

    local function toggleField(field)
        if active[field] then active[field] = nil else active[field] = true end
        local parts = {}
        for _, f in ipairs({"date", "author", "chapter"}) do
            if active[f] then table.insert(parts, f) end
        end
        local new_val = #parts > 0 and table.concat(parts, ",") or "date"
        setSetting("info_fields", new_val)
        fields_setting = new_val
        active = {}
        for f in new_val:gmatch("[^,]+") do active[f] = true end
        self:refresh()
        UIManager:close(self.info_fields_dialog)
        self:showInfoFieldsMenu()
    end

    local function check(field) return active[field] and "\u{2713} " or "  " end
    local buttons = {
        {{ text = check("date")    .. _("Date"),    callback = function() toggleField("date")    end }},
        {{ text = check("author")  .. _("Author"),  callback = function() toggleField("author")  end }},
        {{ text = check("chapter") .. _("Chapter"), callback = function() toggleField("chapter") end }},
        {{ text = _("Back"), callback = function()
            UIManager:close(self.info_fields_dialog)
            self:showSettingsMenu()
        end }},
    }
    self.info_fields_dialog = ButtonDialogTitle:new{ title = _("Show Info Header: Fields"), buttons = buttons }
    NotesListWidget.showDialog(self.info_fields_dialog)
end
function NotesListWidget:showDedupInfoFieldsMenu()
    local fields_setting = getDedupInfoFields()
    local active = {}
    for f in fields_setting:gmatch("[^,]+") do active[f] = true end

    local function toggleField(field)
        if active[field] then active[field] = nil else active[field] = true end
        local parts = {}
        for _, f in ipairs({"date", "author", "chapter"}) do
            if active[f] then table.insert(parts, f) end
        end
        local new_val = #parts > 0 and table.concat(parts, ",") or "date"
        setSetting("dedup_info_fields", new_val)
        fields_setting = new_val
        active = {}
        for f in new_val:gmatch("[^,]+") do active[f] = true end
        self:refresh()
        UIManager:close(self.dedup_fields_dialog)
        self:showDedupInfoFieldsMenu()
    end

    local function check(field) return active[field] and "✓ " or "  " end
    local buttons = {
        {{ text = check("date")    .. _("Date"),    callback = function() toggleField("date")    end }},
        {{ text = check("author")  .. _("Author"),  callback = function() toggleField("author")  end }},
        {{ text = check("chapter") .. _("Chapter"), callback = function() toggleField("chapter") end }},
        {{ text = _("Back"), callback = function()
            UIManager:close(self.dedup_fields_dialog)
            self:showSettingsMenu()
        end }},
    }
    self.dedup_fields_dialog = ButtonDialogTitle:new{ title = _("Hide Repeat Info: Match By"), buttons = buttons }
    NotesListWidget.showDialog(self.dedup_fields_dialog)
end
function NotesListWidget:showFontSizeMenu()
    self:showSpinMenu("font_size", function() self:showSettingsMenu() end)
end
function NotesListWidget:showFontsMenu()
    self:showSettingsMenu() -- the fonts are rows on the Settings page now
end
function NotesListWidget:showSectionMarginMenu()
    self:showSpinMenu("section_margin", function() self:showSettingsMenu() end)
end
function NotesListWidget:showMarginMenu()
    self:showSpinMenu("margins", function() self:showSettingsMenu() end)
end
function NotesListWidget:showSpinSetting(title, key, default, min, max, step, back_callback)
    NotesListWidget.showDialog(SpinWidget:new{
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
function NotesListWidget:showFilterMenu(show_back)
    local ButtonDialog = require("ui/widget/buttondialog")
    local RadioButtonWidget = require("ui/widget/radiobuttonwidget")
    
    local function ensureFilter()
        if not self.active_filter or type(self.active_filter) ~= "table" then
            self.active_filter = {}
        end
    end

    local showFilterMenu  -- forward reference

    local function showToggleFilter(config, restore_offset)
        local data = config.collector(self.notes_list)
        local keys = {}
        for key in pairs(data) do table.insert(keys, key) end
        table.sort(keys)

        local function getState(key)
            local inc = (self.active_filter and self.active_filter[config.filter_key]) or {}
            local exc = (self.active_filter and self.active_filter[config.exclude_filter_key]) or {}
            if inc[key] then return "include"
            elseif exc[key] then return "exclude"
            else return "none" end
        end

        local function cycleState(key)
            ensureFilter()
            local inc = self.active_filter[config.filter_key] or {}
            local exc = self.active_filter[config.exclude_filter_key] or {}
            local state = getState(key)
            if state == "none" then
                inc[key] = true
            elseif state == "include" then
                inc[key] = nil
                exc[key] = true
            else
                exc[key] = nil
            end
            self.active_filter[config.filter_key] = next(inc) and inc or nil
            self.active_filter[config.exclude_filter_key] = next(exc) and exc or nil
        end

        local dialog
        local buttons = {}

        -- Determine column count
        local ncols
        if config.columns == "auto" then
            ncols = #keys > 20 and 3 or #keys > 10 and 2 or 1
        elseif config.columns == "auto2" then
            ncols = #keys > 10 and 2 or 1
        else
            ncols = config.columns or 1
        end

        -- Build item button definitions first, then pack into rows
        local item_btns = {}
        for _, key in ipairs(keys) do
            local state = getState(key)
            local mark = state == "include" and "[+] " or state == "exclude" and "[-] " or "[ ] "
            local display_text = config.formatter(key, data[key])
            local k = key
            table.insert(item_btns, {
                text = mark .. display_text,
                callback = function()
                    local offset = dialog:getScrolledOffset()
                    cycleState(k)
                    UIManager:close(dialog)
                    showToggleFilter(config, offset)
                end,
            })
        end
        local i = 1
        while i <= #item_btns do
            local row = {}
            for c = 1, ncols do
                if item_btns[i] then
                    table.insert(row, item_btns[i])
                    i = i + 1
                end
            end
            table.insert(buttons, row)
        end
        table.insert(buttons, {
            { text = _(config.apply_label), callback = function()
                UIManager:close(dialog)
                self:refresh()
                showFilterMenu(show_back)
            end },
        })
        table.insert(buttons, {
            { text = _(config.clear_label), callback = function()
                ensureFilter()
                self.active_filter[config.filter_key] = nil
                self.active_filter[config.exclude_filter_key] = nil
                UIManager:close(dialog)
                self:refresh()
                showFilterMenu(show_back)
            end },
        })
        dialog = ButtonDialog:new{
            title = _(config.dialog_title),
            buttons = buttons,
            width_factor = 0.7,
        }
        NotesListWidget.showDialog(dialog)
        if restore_offset then
            dialog:setScrolledOffset(restore_offset)
        end
    end
    
    local FILTER_CONFIGS = {
        book = {
            filter_key = "books",
            exclude_filter_key = "books_exclude",
            dialog_title = "Filter by Book",
            apply_label = "Apply Book Filter",
            columns = "auto2",
            collector = function(notes_list)
                local books = {}
                for _, note in ipairs(notes_list) do
                    if note.book_title then 
                        books[note.book_title] = note.book_authors or "Unknown"
                    end
                end
                return books
            end,
            formatter = function(title, author)
                local display_author = author
                if author and author ~= "Unknown" and author:find("\n") then
                    local first_author = author:match("^([^\n]+)")
                    if first_author then
                        first_author = first_author:match("^%s*(.-)%s*$")
                        display_author = first_author .. " et al."
                    end
                end
                return display_author ~= "Unknown" and (display_author .. " - " .. title) or title
            end,
        },
        tags = {
            filter_key = "tags",
            exclude_filter_key = "tags_exclude",
            dialog_title = "Filter by Tags",
            apply_label = "Apply Tags Filter",
            clear_label = "Clear Tags Filter",
            columns = "auto",
            collector = function(notes_list)
                local tags = {}
                local book_filter = self.active_filter and self.active_filter.books
                for _, note in ipairs(notes_list) do
                    if not book_filter or not next(book_filter) or book_filter[note.book_title] then
                        local note_wrapper = NoteWrapper:new(note)
                        local note_tags = note_wrapper:getTags()
                        for _, tag in ipairs(note_tags) do
                            if tag ~= "" then tags[tag] = true end
                        end
                    end
                end
                return tags
            end,
            formatter = function(tag, _) return tag end,
        },
        chapter = {
            filter_key = "chapters",
            exclude_filter_key = "chapters_exclude",
            dialog_title = "Filter by Chapter",
            apply_label = "Apply Chapter Filter",
            columns = "auto2",
            collector = function(notes_list)
                local chapters = {}
                local book_filter = self.active_filter and self.active_filter.books
                for _, note in ipairs(notes_list) do
                    if not book_filter or not next(book_filter) or book_filter[note.book_title] then
                        if note.chapter and note.chapter ~= "" then
                            chapters[note.chapter] = true
                        end
                    end
                end
                return chapters
            end,
            formatter = function(ch, _) return ch end,
        },
    }

    -- Single-book context: launched from the reader (current book only),
    -- or the book filter is narrowed to exactly one book.
    local function isSingleBookContext()
        if self.single_book then return true end
        local book_filter = self.active_filter and self.active_filter.books
        if book_filter and next(book_filter) then
            local count = 0
            for _ in pairs(book_filter) do count = count + 1 end
            if count == 1 then return true end
        end
        return false
    end
    
    local function showBookFilter()
        showToggleFilter(FILTER_CONFIGS.book)
    end

    local function showTagsFilter()
        showToggleFilter(FILTER_CONFIGS.tags)
    end

    local function showColorStyleFilter(is_exclude)
        local type_key  = is_exclude and "type_exclude"  or "type"
        local value_key = is_exclude and "value_exclude" or "value"
        local colors, styles = {}, {}
        for _, note in ipairs(self.notes_list) do
            local note_wrapper = NoteWrapper:new(note)
            local color = note_wrapper:getNormalizedColor()
            if color then colors[color] = true end
            local drawer = note_wrapper:getNormalizedDrawer()
            if drawer then styles[drawer] = true end
        end
        local curr_type = self.active_filter and self.active_filter[type_key] or nil
        local curr_val  = self.active_filter and self.active_filter[value_key] or nil
        local radio_buttons = {}
        for style, _ in pairs(styles) do
            local name = style:sub(1,1):upper() .. style:sub(2)
            local button = { text = name or style, checked = curr_type == "style" and curr_val == style,
                             provider = { type = "style", value = style } }
            if style == "invert" then
                button.fgcolor = BlitBuffer.COLOR_WHITE
                button.bgcolor = BlitBuffer.COLOR_BLACK
            end
            table.insert(radio_buttons, { button })
        end
        for _, v in ipairs(ReaderHighlight.highlight_colors) do
            local name, color_key = v[1], v[2]
            if colors[color_key] then
                local color_value = HIGHLIGHT_COLORS[color_key]
                if color_value then
                    table.insert(radio_buttons, {
                        { text = name, checked = curr_type == "color" and curr_val == color_key,
                          bgcolor = BlitBuffer.colorFromString(color_value),
                          provider = { type = "color", value = color_key } },
                    })
                end
            end
        end
        if colors["gray"] then
            table.insert(radio_buttons, {
                { text = _("Gray"), checked = curr_type == "color" and curr_val == "gray",
                  bgcolor = BlitBuffer.COLOR_GRAY,
                  provider = { type = "color", value = "gray" } },
            })
        end
        table.insert(radio_buttons, {
            { text = _( "Clear Filter" ), checked = curr_type == nil, provider = nil },
        })
        NotesListWidget.showDialog(RadioButtonWidget:new{
            title_text = is_exclude and _("Exclude Color/Style") or _("Filter by Color/Style"),
            width_factor = 0.6,
            radio_buttons = radio_buttons,
            callback = function(radio)
                self.active_filter = self.active_filter or {}
                -- clear the opposite side so only one is ever active
                local opp_type  = is_exclude and "type"  or "type_exclude"
                local opp_value = is_exclude and "value" or "value_exclude"
                self.active_filter[opp_type]  = nil
                self.active_filter[opp_value] = nil
                if radio.provider then
                    self.active_filter[type_key]  = radio.provider.type
                    self.active_filter[value_key] = radio.provider.value
                else
                    self.active_filter[type_key]  = nil
                    self.active_filter[value_key] = nil
                end
                self:refresh()
                showFilterMenu(show_back)
            end,
            colorful = true,
            dithered = true,
        })
    end

    local function showTextSearchFilter(field_key, dialog_title, hint, is_exclude)
        local InputDialog = require("ui/widget/inputdialog")
        local actual_key = is_exclude and (field_key .. "_exclude") or field_key
        local mode_key = actual_key .. "_mode"
        local case_key = actual_key .. "_case"
        local init_query = (self.active_filter and self.active_filter[actual_key]) or ""
        local init_mode  = (self.active_filter and self.active_filter[mode_key]) or "all"
        local init_case  = (self.active_filter and self.active_filter[case_key]) or false
        local dialog_mode = init_mode
        local dialog_case = init_case
        local input_dialog
        local function rebuildDialog(saved_query)
            if input_dialog then UIManager:close(input_dialog) end
            local function modeBtn(label, m)
                return {
                    text = (dialog_mode == m and "✓ " or "") .. label,
                    callback = function()
                        local q = input_dialog:getInputText()
                        dialog_mode = m
                        rebuildDialog(q)
                    end,
                }
            end
            input_dialog = InputDialog:new{
                title = _(dialog_title),
                input = saved_query,
                input_hint = hint,
                buttons = {
                    {
                        modeBtn(_("All Words"), "all"),
                        modeBtn(_("Any Word"), "any"),
                        modeBtn(_("Exact Phrase"), "phrase"),
                    },
                    {
                        {
                            text = dialog_case and _("Case-Sensitive: On") or _("Case-Sensitive: Off"),
                            callback = function()
                                local q = input_dialog:getInputText()
                                dialog_case = not dialog_case
                                rebuildDialog(q)
                            end,
                        },
                    },
                    {
                        { text = _("Cancel"), callback = function() UIManager:close(input_dialog) end },
                        { text = _("Clear"), callback = function()
                            UIManager:close(input_dialog)
                            if self.active_filter then
                                self.active_filter[actual_key] = nil
                                self.active_filter[mode_key]   = nil
                                self.active_filter[case_key]   = nil
                            end
                            self:refresh()
                            showFilterMenu(show_back)
                        end },
                        { text = is_exclude and _("Exclude") or _("Search"), is_enter_default = true, callback = function()
                            local q = input_dialog:getInputText()
                            UIManager:close(input_dialog)
                            ensureFilter()
                            self.active_filter[actual_key] = q ~= "" and q or nil
                            self.active_filter[mode_key]   = dialog_mode
                            self.active_filter[case_key]   = dialog_case
                            self:refresh()
                            showFilterMenu(show_back)
                        end },
                    },
                },
            }
            NotesListWidget.showDialog(input_dialog)
            input_dialog:onShowKeyboard()
        end
        rebuildDialog(init_query)
    end

    -- cs_exclude tracks whether the Color/Style row acts as Filter or Exclude
    -- initialise to exclude if an exclude is already active but no include is
    local cs_exclude = false
    if self.active_filter then
        local has_inc = self.active_filter.type ~= nil
        local has_exc = self.active_filter.type_exclude ~= nil
        if has_exc and not has_inc then cs_exclude = true end
    end

    local function isActive(keys)
        if not self.active_filter then return false end
        for _, k in ipairs(keys) do
            local v = self.active_filter[k]
            if type(v) == "table" and next(v) then return true end
            if type(v) == "string" and v ~= "" then return true end
        end
        return false
    end

    local function mark(keys, label)
        return (isActive(keys) and "✓ " or "") .. label
    end

    showFilterMenu = function(show_back)
        if self.filter_dialog then UIManager:close(self.filter_dialog) end
        local af = self.active_filter or {}
        local main_buttons = {}

        -- Group 1: Scope
        if not self.single_book then
            table.insert(main_buttons, {
                { text = mark({"books","books_exclude"}, _("Filter by Book")), callback = function()
                    showBookFilter()
                end },
            })
        end
        if isSingleBookContext() then
            table.insert(main_buttons, {
                { text = mark({"chapters","chapters_exclude"}, _("Filter by Chapter")), callback = function()
                    UIManager:close(self.filter_dialog)
                    showToggleFilter(FILTER_CONFIGS.chapter)
                end },
            })
        end
        table.insert(main_buttons, {
            { text = mark({"tags","tags_exclude"}, _("Filter by Tags")), callback = function()
                showTagsFilter()
            end },
        })

        -- Group 2: Color / Style
        table.insert(main_buttons, {})
        local cs_action_label = cs_exclude and _("Exclude Color/Style") or _("Filter by Color/Style")
        local cs_active = isActive({"type","value","type_exclude","value_exclude"})
        local cs_toggle_label = cs_exclude and _("Mode: Exclude") or _("Mode: Filter")
        table.insert(main_buttons, {
            { text = (cs_active and "\u{2713} " or "") .. cs_action_label, callback = function()
                showColorStyleFilter(cs_exclude)
            end },
            { text = cs_toggle_label, callback = function()
                cs_exclude = not cs_exclude
                ensureFilter()
                if cs_exclude then
                    self.active_filter.type  = nil
                    self.active_filter.value = nil
                else
                    self.active_filter.type_exclude  = nil
                    self.active_filter.value_exclude = nil
                end
                self:refresh()
                showFilterMenu(show_back)
            end },
        })

        -- Group 3: Text search
        table.insert(main_buttons, {})
        -- the search box from the top bar (highlights and notes together)
        if af.search_any and af.search_any ~= "" then
            table.insert(main_buttons, {
                { text = "✓ " .. _("Search: ") .. "\"" .. af.search_any .. "\"", callback = function()
                    UIManager:close(self.filter_dialog)
                    self:showSearchDialog()
                end },
                { text = _("Clear Search"), callback = function()
                    self.active_filter.search_any = nil
                    self:refresh()
                    showFilterMenu(show_back)
                end },
            })
        else
            table.insert(main_buttons, {
                { text = _("Search Highlights and Notes…"), callback = function()
                    UIManager:close(self.filter_dialog)
                    self:showSearchDialog()
                end },
            })
        end
        table.insert(main_buttons, {
            { text = mark({"search_highlight"}, _("Filter by Highlight Text")), callback = function()
                UIManager:close(self.filter_dialog)
                showTextSearchFilter("search_highlight", "Filter by Highlight Text", _("Words in highlighted text…"), false)
            end },
            { text = mark({"search_highlight_exclude"}, _("Exclude by Highlight Text")), callback = function()
                UIManager:close(self.filter_dialog)
                showTextSearchFilter("search_highlight", "Exclude Highlight Text", _("Words to hide highlighted text…"), true)
            end },
        })
        table.insert(main_buttons, {
            { text = mark({"search_note"}, _("Filter by Note Text")), callback = function()
                UIManager:close(self.filter_dialog)
                showTextSearchFilter("search_note", "Filter by Note Text", _("Words in annotation notes…"), false)
            end },
            { text = mark({"search_note_exclude"}, _("Exclude by Note Text")), callback = function()
                UIManager:close(self.filter_dialog)
                showTextSearchFilter("search_note", "Exclude Note Text", _("Words to hide annotation notes…"), true)
            end },
        })

        -- Group 4: Notes presence (3-state cycle)
        table.insert(main_buttons, {})
        local np = af.notes_presence
        local np_label
        if np == "only" then
            np_label = "\u{2713} " .. _("With Notes Only")
        elseif np == "exclude" then
            np_label = "\u{2713} " .. _("Highlights Only (no notes)")
        else
            np_label = _("Notes: All")
        end
        table.insert(main_buttons, {
            { text = np_label, callback = function()
                ensureFilter()
                if np == nil then
                    self.active_filter.notes_presence = "only"
                elseif np == "only" then
                    self.active_filter.notes_presence = "exclude"
                else
                    self.active_filter.notes_presence = nil
                end
                self:refresh()
                showFilterMenu(show_back)
            end },
        })

        -- Group 5: Clear / Back
        table.insert(main_buttons, {})
        table.insert(main_buttons, {
            { text = _("Clear All Filters"), callback = function()
                self.active_filter = {}
                cs_exclude = false
                self:refresh()
                showFilterMenu(show_back)
            end },
        })
        if show_back then
            table.insert(main_buttons, {
                { text = _("Back"), callback = function()
                    if self.filter_dialog then UIManager:close(self.filter_dialog) end
                    self:showMainMenu()
                end },
            })
        end

        self.filter_dialog = ButtonDialog:new{
            title = _("Annotation Filters"),
            buttons = main_buttons,
            width_factor = 0.7,
        }
        NotesListWidget.showDialog(self.filter_dialog)
    end
    -- The full-screen "Filter & sort" screen replaces the old menu above. The pickers it opens
    -- (books, tags, chapters, text) are the ones defined here; when they finish they call
    -- showFilterMenu(), which now just redraws that screen.
    showFilterMenu = function()
        if self.filter_screen then self.filter_screen:rebuild() end
    end
    local function back() if self.filter_screen then self.filter_screen:rebuild() end end
    self:showFilterScreen{
        books = function() self:showBookPicker(back) end,
        tags = function() self:showTagPicker(back) end,
        chapters = function() self:showChapterPicker(back) end,
        chapters_available = isSingleBookContext,
        text = function(field, title, hint, is_exclude) showTextSearchFilter(field, title, hint, is_exclude) end,
    }
end
function NotesListWidget:refresh()
    self:computeLayout()
    local prev_page = self.current_page or 1
    self:applyFilter()
    self:calculatePages()
    self.current_page = math.max(1, math.min(prev_page, self.total_pages or 1))
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
function NotesListWidget:onSwipeWest()  return self:onGotoNextPage() end
function NotesListWidget:onSwipeNorth() return self:onGotoNextPage() end
function NotesListWidget:onSwipeEast()  return self:onGotoPrevPage() end
function NotesListWidget:onSwipeSouth() return self:onGotoPrevPage() end
-- Forward an unhandled gesture to the KOReader gestures plugin by directly
-- resolving the canonical gesture name and calling gestureAction(). This
-- bypasses the event-stack limitation where UIManager only propagates events
-- to is_always_active widgets after the top widget.
local function _forwardGestureToPlugin(ges_event)
    local g
    local ReaderUI = require("apps/reader/readerui")
    if ReaderUI.instance then g = ReaderUI.instance.gestures end
    if not g then
        local FileManager = require("apps/filemanager/filemanager")
        if FileManager.instance then g = FileManager.instance.gestures end
    end
    if not g then return end

    local sw  = Screen:getWidth()
    local sh  = Screen:getHeight()
    local pos = ges_event.pos
    if not pos then return end
    local x, y = pos.x, pos.y
    local gt  = ges_event.ges
    local dir = ges_event.direction

    local function readZone(key)
        local d = G_defaults:readSetting(key)
        if not d then return nil end
        return { ratio_x = d.x, ratio_y = d.y, ratio_w = d.w, ratio_h = d.h }
    end
    local function inZone(z)
        if not z then return false end
        return x >= z.ratio_x * sw and x < (z.ratio_x + z.ratio_w) * sw
           and y >= z.ratio_y * sh and y < (z.ratio_y + z.ratio_h) * sh
    end

    local candidates = {}

    if gt == "swipe" then
        local is_diag = dir == "northeast" or dir == "northwest"
                     or dir == "southeast" or dir == "southwest"
        if is_diag then
            if ges_event.distance and ges_event.distance <= Screen:scaleBySize(300) then
                candidates[#candidates+1] = "short_diagonal_swipe"
            end
        else
            local le = readZone("DSWIPE_ZONE_LEFT_EDGE")
            local re = readZone("DSWIPE_ZONE_RIGHT_EDGE")
            local te = readZone("DSWIPE_ZONE_TOP_EDGE")
            local be = readZone("DSWIPE_ZONE_BOTTOM_EDGE")
            if inZone(le) then
                if dir == "south" then candidates[#candidates+1] = "one_finger_swipe_left_edge_down"
                elseif dir == "north" then candidates[#candidates+1] = "one_finger_swipe_left_edge_up" end
            elseif inZone(re) then
                if dir == "south" then candidates[#candidates+1] = "one_finger_swipe_right_edge_down"
                elseif dir == "north" then candidates[#candidates+1] = "one_finger_swipe_right_edge_up" end
            elseif inZone(te) then
                if dir == "east" then candidates[#candidates+1] = "one_finger_swipe_top_edge_right"
                elseif dir == "west" then candidates[#candidates+1] = "one_finger_swipe_top_edge_left" end
            elseif inZone(be) then
                if dir == "east" then candidates[#candidates+1] = "one_finger_swipe_bottom_edge_right"
                elseif dir == "west" then candidates[#candidates+1] = "one_finger_swipe_bottom_edge_left" end
            end
        end
    elseif gt == "two_finger_swipe" then
        local map = {
            east="two_finger_swipe_east", west="two_finger_swipe_west",
            north="two_finger_swipe_north", south="two_finger_swipe_south",
            northeast="two_finger_swipe_northeast", northwest="two_finger_swipe_northwest",
            southeast="two_finger_swipe_southeast", southwest="two_finger_swipe_southwest",
        }
        if map[dir] then candidates[#candidates+1] = map[dir] end
    elseif gt == "multiswipe" then
        local orig = UIManager.sendEvent
        UIManager.sendEvent = function(um, ev) return UIManager:broadcastEvent(ev) end
        pcall(g.multiswipeAction, g, ges_event.multiswipe_directions, ges_event)
        UIManager.sendEvent = orig
        return true
    elseif gt == "spread" then candidates[#candidates+1] = "spread_gesture"
    elseif gt == "pinch"  then candidates[#candidates+1] = "pinch_gesture"
    elseif gt == "rotate" then
        if dir == "cw"  then candidates[#candidates+1] = "rotate_cw"
        elseif dir == "ccw" then candidates[#candidates+1] = "rotate_ccw" end
    end

    if #candidates == 0 then return end

    local ges_name = candidates[1]
    for _, name in ipairs(candidates) do
        if g.gestures and g.gestures[name] ~= nil then ges_name = name; break end
    end

    local orig = UIManager.sendEvent
    UIManager.sendEvent = function(um, ev) return UIManager:broadcastEvent(ev) end
    pcall(g.gestureAction, g, ges_name, ges_event)
    UIManager.sendEvent = orig
    return true
end

-- Show one of KOReader's own dialogs (edit note, confirm, number, buttons ...) and let it pass
-- the gestures it doesn't use on to the KOReader gestures plugin, as the list does.
function NotesListWidget.showDialog(w, ...)
    local IC = require("ui/widget/container/inputcontainer")
    if type(w) == "table" and not w.toast and w.onGesture == IC.onGesture then
        w.onGesture = function(self, ev)
            if IC.onGesture(self, ev) then return true end
            return _forwardGestureToPlugin(ev)
        end
    end
    return UIManager:show(w, ...)
end
function NotesListWidget:onGesture(ev)
    -- Let InputContainer handle registered ges_events / touch zones first
    local InputContainer = require("ui/widget/container/inputcontainer")
    if InputContainer.onGesture(self, ev) then return true end
    return _forwardGestureToPlugin(ev)
end
function NotesListWidget:onTap(_, ges)
    if not ges or not ges.pos then return end
    -- exclude scrollbar column
    local pag_style = getPaginationStyle()
    if (pag_style == "scrollbar" or pag_style == "scrollbar_chevrons") and self.sb_x and ges.pos.x >= self.sb_x then
        return
    end
    local tap_y = ges.pos.y
    if tap_y < self.title_height then
        return
    end

    -- Use the positions recorded when the page was drawn
    local rel_y = tap_y - (self.tap_rows_origin_y or self.title_height)
    for _, row in ipairs(self.tap_rows or {}) do
        if rel_y >= row.top and rel_y < row.bottom then
            if row.action then row.action() return true end
            self:onNoteSelected(row.note)
            return true
        end
    end
    return false
end
function NotesListWidget:onNoteSelected(note)
    if self.viewer and self.viewer.showNoteDetails then
        self.viewer:showNoteDetails(note, self)
    end
end
function NotesListWidget:onClose()
    -- full-screen widget: refresh what was underneath, or e-ink keeps showing the list
    UIManager:close(self, "flashui")
    return true
end
-- Screen rotated or window resized: rebuild the layout for the new size and stay on the
-- page that shows the annotation that was at the top before.
function NotesListWidget:onScreenResize()
    local page = self.pages and self.pages[self.current_page]
    local first_idx = page and page[1]
    self.current_page = 1
    self:init()
    if first_idx then
        for p, indices in ipairs(self.pages) do
            if indices[#indices] and indices[#indices] >= first_idx then
                if p ~= self.current_page then
                    self.current_page = p
                    self:updatePage()
                end
                break
            end
        end
    end
    UIManager:setDirty(self, "full")
    return false
end
-- Rotation doesn't always reach this widget as an event, so also check the size whenever
-- we're painted and re-layout (outside the paint) if the screen changed.
function NotesListWidget:paintTo(bb, x, y)
    if (self.width ~= Screen:getWidth() or self.height ~= Screen:getHeight()) and not self._resize_pending then
        self._resize_pending = true
        UIManager:nextTick(function()
            self._resize_pending = nil
            if self.width ~= Screen:getWidth() or self.height ~= Screen:getHeight() then
                self:onScreenResize()
            end
        end)
    end
    InputContainer.paintTo(self, bb, x, y)
end

-- Module-level caches: survive across plugin open/close within the same KOReader session,
-- and are saved to disk (see loadPersistentCache) so they also survive restarts.
-- "mtime" holds a key describing the sidecar's state (modification time and size); an entry
-- is only used while the key still matches.
local _annotation_cache = {}  -- [book_path] = { data = {...}, mtime = key }
local _book_info_cache   = {}  -- [book_path] = { data = {...}, mtime = key }

local function fileStamp(path)
    local attr = path and lfs.attributes(path)
    if attr and attr.mode == "file" then
        return attr.modification .. ":" .. attr.size
    end
end

-- Returns a key for the current state of a book's sidecar, plus the sidecar path.
-- The second value is false when the book definitely has no sidecar (so no annotations),
-- and nil when that can't be determined (KOReader < 2023).
local function getSidecarKey(book_path)
    local ok, sidecar = pcall(DocSettings.findSidecarFile, DocSettings, book_path)
    if not ok then
        -- Fallback: KOReader < 2023 API
        local ok_old, old_sidecar = pcall(DocSettings.getSidecarFile, DocSettings, book_path)
        sidecar = ok_old and old_sidecar or nil
    end
    local stamp = sidecar and fileStamp(sidecar)
    if stamp then return stamp, sidecar end
    -- Fall back to the book file itself
    return "book:" .. (fileStamp(book_path) or ""), (ok and false or nil)
end

-- Key for the book info (title/authors/tags): the sidecar key plus the custom metadata file,
-- which KOReader keeps next to the sidecar and updates when book info is edited.
local function getBookInfoKey(sidecar_key, sidecar)
    local dir = sidecar and sidecar:match("^(.*)/")
    return sidecar_key .. "|" .. ((dir and fileStamp(dir .. "/custom_metadata.lua")) or "")
end

-- On-disk copy of the caches above, so a KOReader restart doesn't mean parsing every
-- book's sidecar again. Bump CACHE_VERSION whenever the cached data's shape changes.
local CACHE_VERSION = 1
local _persist = nil        -- LuaSettings object, loaded on the first scan
local _persist_dirty = false
local _persist_count = 0

local function loadPersistentCache()
    if _persist then return end
    local ok_ds, DataStorage = pcall(require, "datastorage")
    local ok_ls, LuaSettings = pcall(require, "luasettings")
    if not (ok_ds and ok_ls) then return end
    local dir = DataStorage:getDataDir() .. "/cache"
    if lfs.attributes(dir, "mode") ~= "directory" then lfs.mkdir(dir) end
    local ok, settings = pcall(LuaSettings.open, LuaSettings, dir .. "/annotationsviewer.lua")
    if not ok or not settings then return end
    _persist = settings
    local d = settings.data
    if d.version ~= CACHE_VERSION or type(d.books) ~= "table" then
        settings.data = { version = CACHE_VERSION, books = {} }
        _persist_dirty = true
        return
    end
    _persist_count = 0
    for path, b in pairs(d.books) do
        _persist_count = _persist_count + 1
        if not _annotation_cache[path] and b.key and b.annotations then
            _annotation_cache[path] = { data = b.annotations, mtime = b.key }
        end
        if not _book_info_cache[path] and b.info_key and b.info then
            _book_info_cache[path] = { data = b.info, mtime = b.info_key }
        end
    end
end

-- Writes the caches for the given books (the ones found by the last scan) back to disk,
-- but only if something was read from a sidecar since the last save.
local function savePersistentCache(paths)
    if not _persist then return end
    if not _persist_dirty and #paths == _persist_count then return end
    local books = {}
    for _, path in ipairs(paths) do
        local a, i = _annotation_cache[path], _book_info_cache[path]
        if a then
            books[path] = {
                key = a.mtime, annotations = a.data,
                info_key = i and i.mtime, info = i and i.data,
            }
        end
    end
    _persist.data = { version = CACHE_VERSION, books = books }
    local ok, err = pcall(_persist.flush, _persist)
    if not ok then logger.warn("AnnotationsViewer: could not save cache:", err) end
    _persist_dirty = false
    _persist_count = #paths
end

-- Write-back helpers -------------------------------------------------------------------

local function positionsEqual(a, b)
    if a == b then return true end
    if type(a) == "table" and type(b) == "table" then -- PDF/CBZ positions
        return a.x == b.x and a.y == b.y and a.page == b.page
    end
    return false
end

-- Does a stored or live annotation item correspond to this plugin note?
-- Matches on date, highlighted text and position, so two highlights saved in the same
-- second with the same text are told apart.
local function itemMatchesNote(item, note)
    if item.datetime ~= note.datetime then return false end
    if (item.text or "") ~= (note.highlighted_text or "") then return false end
    if note.pos0 ~= nil then
        return positionsEqual(item.pos0, note.pos0) and positionsEqual(item.pos1, note.pos1)
    end
    return true
end

-- Returns the ReaderUI if this book is currently open, so changes go through KOReader.
local function getLiveReader(book_path)
    local ReaderUI = require("apps/reader/readerui")
    local ui = ReaderUI and ReaderUI.instance
    if ui and ui.document and ui.document.file == book_path
            and ui.annotation and ui.annotation.annotations then
        return ui
    end
end

local function findLiveIndex(ui, note)
    for i, item in ipairs(ui.annotation.annotations) do
        if itemMatchesNote(item, note) then return i end
    end
end

-- Finds the annotation for `note` in its (closed) book's sidecar, calls fn(item, list, index)
-- on it and saves the sidecar. Returns true if the annotation was found.
local function editStoredAnnotation(note, fn)
    local ok, doc_settings = pcall(DocSettings.open, DocSettings, note.book_path)
    if not ok or not doc_settings or not doc_settings.data then return false end
    local data = doc_settings.data
    local found = false
    if type(data.annotations) == "table" then
        for i, item in ipairs(data.annotations) do
            if itemMatchesNote(item, note) then
                fn(item, data.annotations, i)
                found = true
                break
            end
        end
    end
    if not found then -- legacy format (KOReader < 2024)
        for _, page_highlights in pairs(data.highlight or {}) do
            if type(page_highlights) == "table" then
                for i, hl in ipairs(page_highlights) do
                    if itemMatchesNote(hl, note) then
                        fn(hl, page_highlights, i)
                        found = true
                        break
                    end
                end
            end
            if found then break end
        end
    end
    if found then doc_settings:flush() end
    return found
end

local function nowStamp() return os.date("%Y-%m-%d %H:%M:%S") end

-- Changes the style or colour of a highlight in the open book, the way ReaderHighlight does
-- (including the PDF annotation), and tells KOReader about the real item.
local function setLiveHighlightField(ui, index, field, value)
    local item = ui.annotation.annotations[index]
    local hl = ui.highlight
    local pdf = hl and hl.writePdfAnnotation
    if pdf then hl:writePdfAnnotation("delete", item) end
    item[field] = value
    if pdf and ui.paging then
        hl:writePdfAnnotation("save", item)
        if item.note then hl:writePdfAnnotation("content", item, item.note) end
    end
    ui:handleEvent(Event:new("AnnotationsModified", { item }))
end

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
    Dispatcher:registerAction("show_current_book_annotations", {
        category = "none",
        event = "ShowCurrentBookAnnotations",
        title = _("Show current book annotations"),
        reader = true,
    })
    if not self.ui.document then
        self.ui.menu:registerToMainMenu(self)
    else
        self.ui.menu:registerToMainMenu(self)
    end
end
function AllNotesViewer:onShowAllAnnotations()
    self:showAllNotes()
end
function AllNotesViewer:onShowCurrentBookAnnotations()
    self:showCurrentBookNotes()
end
function AllNotesViewer:showCurrentBookNotes()
    local ReaderUI = require("apps/reader/readerui")
    local ui = self.ui or (ReaderUI and ReaderUI.instance)
    if not ui or not ui.document then return end
    local book_path = ui.document.file
    if not book_path then return end
    -- Prefer live in-memory annotations so unsaved changes are visible
    local annotations
    if ui.annotation and ui.annotation.annotations then
        annotations = self:convertLiveAnnotations(ui.annotation.annotations)
    else
        annotations = self:loadBookAnnotations(book_path)
    end
    if not annotations or #annotations == 0 then
        annotations = {} -- the list shows "No annotations yet"
    end
    local book_info = self:getBookInfo(book_path)
    local book_title = book_info and book_info.title or (book_path:match("([^/\\]+)$") or book_path)
    self:showNotesForBook(book_path, book_title, annotations)
end
function AllNotesViewer:addToMainMenu(menu_items)
    if self.ui and self.ui.document then
        menu_items.current_book_notes_viewer = {
            text = _("Book Annotations"),
            sorting_hint = "navi",
            callback = function() self:showCurrentBookNotes() end,
        }
    else
        menu_items.all_notes_viewer = {
            text = _("Annotations"),
            sorting_hint = "filemanager_settings",
            callback = function() self:showAllNotes() end,
        }
    end
end
-- Tells an open ReaderUI that the annotation for `note` changed, sending KOReader's own item
-- (not the plugin's copy) so KOReader updates its modification time and redraws it.
function AllNotesViewer:notifyLiveReader(book_path, note)
    local ui = getLiveReader(book_path)
    if not ui then return end
    local index = findLiveIndex(ui, note)
    local item = index and ui.annotation.annotations[index]
    if item then
        ui:handleEvent(Event:new("AnnotationsModified", { item }))
    end
end
-- "Reload annotations" in the ☰ menu: forget everything read so far (memory and the file in the
-- cache folder), then open the list again, which reads all books afresh.
function AllNotesViewer:reloadAnnotations(list)
    for k in pairs(_annotation_cache) do _annotation_cache[k] = nil end
    for k in pairs(_book_info_cache) do _book_info_cache[k] = nil end
    if _persist then
        _persist.data = { version = CACHE_VERSION, books = {} }
        pcall(_persist.flush, _persist)
    end
    _persist, _persist_dirty, _persist_count = nil, false, 0
    local single = list and list.single_book
    if list then list:onClose() end
    if single then self:showCurrentBookNotes() else self:showAllNotes() end
end
function AllNotesViewer:clearBookCache(book_path)
    _annotation_cache[book_path] = nil
    -- book_info rarely changes, but clear it too so tags/title edits are reflected
    _book_info_cache[book_path] = nil
end
function AllNotesViewer:convertLiveAnnotations(live)
    local annotations = {}
    for _, item in ipairs(live) do
        if item.drawer then
            local has_highlight = item.text and item.text ~= ""
            local has_note = item.note and item.note ~= ""
            if has_highlight or has_note then
                table.insert(annotations, {
                    page = item.page or item.pageno or 0,
                    pos0 = item.pos0, pos1 = item.pos1,
                    chapter = item.chapter or "",
                    text = item.text or "",
                    notes = item.note or "",
                    datetime = item.datetime or "",
                    drawer = item.drawer,
                    color = item.color or "yellow",
                    tags = item.tags, keywords = item.keywords,
                })
            end
        end
    end
    return annotations
end
-- key/sidecar are optional: pass them when getSidecarKey() was already called for this book.
function AllNotesViewer:loadBookAnnotations(book_path, key, sidecar)
    local annotations = {}
    if not book_path then return annotations end
    if not key then key, sidecar = getSidecarKey(book_path) end
    local cached = _annotation_cache[book_path]
    if cached and cached.mtime == key then
        return cached.data
    end
    local ok, doc_settings = pcall(DocSettings.open, DocSettings, book_path)
    if not ok or not doc_settings then return annotations end
    _persist_dirty = true
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
                        tags = item.tags, keywords = item.keywords
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
                                tags = hl.tags, keywords = hl.keywords
                            })
                        end
                    end
                end
            end
        end
    end
    table.sort(annotations, function(a, b) return (a.datetime or "") > (b.datetime or "") end)
    _annotation_cache[book_path] = { data = annotations, mtime = key }
    -- Fill the book info cache from the same file, so getBookInfo() doesn't open it again
    if #annotations > 0 then self:getBookInfo(book_path, data, key, sidecar) end
    return annotations
end
-- data/key/sidecar are optional: pass data when the book's settings are already open, and
-- key/sidecar when getSidecarKey() was already called for this book.
function AllNotesViewer:getBookInfo(book_path, data, key, sidecar)
    if not key then key, sidecar = getSidecarKey(book_path) end
    local info_key = getBookInfoKey(key, sidecar)
    local cached = _book_info_cache[book_path]
    if cached and cached.mtime == info_key then
        return cached.data
    end
    _persist_dirty = true
    local opened = data ~= nil
    if not data then
        local ok, doc_settings = pcall(DocSettings.open, DocSettings, book_path)
        opened = ok and doc_settings ~= nil
        data = opened and doc_settings.data or {}
    end
    local filename = book_path:match("([^/\\]+)$") or book_path
    
    local custom_metadata = {}
    if opened then
        local custom_metadata_file = DocSettings:findCustomMetadataFile(book_path)
        if custom_metadata_file then
            local ok_cm, cm_data = pcall(dofile, custom_metadata_file)
            if ok_cm and cm_data then
                custom_metadata = cm_data
            end
        end
    end
    
    local title = (custom_metadata.custom_props and custom_metadata.custom_props.title) or 
                  (custom_metadata.doc_props and custom_metadata.doc_props.title) or
                  (data.doc_props and data.doc_props.title)
    local authors = (custom_metadata.custom_props and custom_metadata.custom_props.authors) or 
                    (custom_metadata.doc_props and custom_metadata.doc_props.authors) or
                    (data.doc_props and data.doc_props.authors)
    local tags = (custom_metadata.custom_props and (custom_metadata.custom_props.tags or custom_metadata.custom_props.keywords)) or
                 (custom_metadata.doc_props and (custom_metadata.doc_props.tags or custom_metadata.doc_props.keywords)) or
                 (data.doc_props and (data.doc_props.tags or data.doc_props.keywords))
    
    if not title or title == "" then title = filename:gsub("%.[^.]+$", "") end
    
    local info = { path = book_path, filename = filename, title = title or filename, authors = authors or "Unknown", tags = tags }
    _book_info_cache[book_path] = { data = info, mtime = info_key }
    return info
end
function AllNotesViewer:findAllNotes()
    local notes_data = {}
    local seen = {}  -- deduplicate by book_path
    local scanned = {} -- books with a sidecar, kept in the on-disk cache
    loadPersistentCache()

    -- Helper: load annotations for a path and add to notes_data if any found
    local function addBook(book_path)
        if seen[book_path] then return end
        seen[book_path] = true
        if not lfs.attributes(book_path, "mode") then return end
        local live_ui = getLiveReader(book_path)
        local key, sidecar = getSidecarKey(book_path)
        -- Books without a sidecar have no annotations: skip opening their settings
        if sidecar == false and not live_ui then return end
        local annotations
        if live_ui then
            -- The open book's sidecar is only written on close/autosave: use what's in memory
            annotations = self:convertLiveAnnotations(live_ui.annotation.annotations)
        else
            table.insert(scanned, book_path)
            annotations = self:loadBookAnnotations(book_path, key, sidecar)
        end
        if #annotations > 0 then
            local book_info = self:getBookInfo(book_path, nil, key, sidecar)
            table.insert(notes_data, {
                path = book_path, filename = book_info.filename,
                title = book_info.title, authors = book_info.authors,
                tags = book_info.tags, notes = annotations,
            })
        end
    end

    -- Source 1: cover browser book info databases (every book ever shown in the file browser).
    -- KOReader's CoverBrowser keeps it in <settings>/bookinfo_cache.sqlite3; the Project Title
    -- plugin keeps its own copy. Opened read-only so a missing file is never created.
    local ok_sq, SQ3 = pcall(require, "lua-ljsqlite3/init")
    local ok_ds, DataStorage = pcall(require, "datastorage")
    if ok_sq and ok_ds then
        local settings_dir = DataStorage:getSettingsDir()
        for _, db_name in ipairs({ "bookinfo_cache.sqlite3", "PT_bookinfo_cache.sqlite3" }) do
            local db_path = settings_dir .. "/" .. db_name
            if lfs.attributes(db_path, "mode") == "file" then
                local ok_db, db = pcall(SQ3.open, db_path, "ro")
                if ok_db and db then
                    local ok_q, res = pcall(db.exec, db,
                        "SELECT directory, filename FROM bookinfo WHERE directory IS NOT NULL AND filename IS NOT NULL")
                    if ok_q and res and res[1] then
                        local dirs, files = res[1], res[2]
                        for i = 1, #dirs do
                            local dir = dirs[i]
                            local sep = dir:sub(-1) == "/" and "" or "/"
                            addBook(dir .. sep .. files[i])
                        end
                    elseif not ok_q then
                        logger.warn("AnnotationsViewer: could not read", db_path, res)
                    end
                    pcall(db.close, db)
                end
            end
        end
    end

    -- Source 2: ReadHistory (books opened but possibly not browsed via file manager)
    local history = ReadHistory.hist
    if history then
        for _, item in ipairs(history) do
            if item.file then addBook(item.file) end
        end
    end

    savePersistentCache(scanned)
    return notes_data
end
function AllNotesViewer:showNotesForBook(book_path, book_title, raw_annotations)
    local book_info = self:getBookInfo(book_path)
    local notes_list = {}
    local function split_tags(val)
        if not val then return nil end
        if type(val) == "table" then return val end
        if type(val) == "string" then
            local t = {}
            for tag in val:gmatch("[^,;\n|\t]+") do
                tag = tag:match("^%s*(.-)%s*$")
                if tag ~= "" then table.insert(t, tag) end
            end
            return t
        end
        return nil
    end
    local book_tags_table = split_tags(book_info and book_info.tags)
    for _, note in ipairs(raw_annotations) do
        local note_tags = split_tags(note.tags) or book_tags_table or {}
        local tag_set = {}
        for _, tag in ipairs(note_tags) do if tag ~= "" then tag_set[tag] = true end end
        local all_tags = {}
        for tag in pairs(tag_set) do table.insert(all_tags, tag) end
        table.sort(all_tags)
        table.insert(notes_list, {
            book_title = book_title,
            book_authors = book_info and book_info.authors or nil,
            book_filename = book_path:match("([^/\\]+)$") or book_path,
            book_path = book_path,
            page = note.page, chapter = note.chapter,
            pos0 = note.pos0, pos1 = note.pos1,
            highlighted_text = note.text, user_note = note.notes,
            datetime = note.datetime, drawer = note.drawer, color = note.color,
            tags = all_tags,
        })
    end
    local sort_mode = getSetting("sort_mode", "date_newest")
    NotesListWidget:sortNotesList(notes_list, sort_mode)
    UIManager:show(NotesListWidget:new{ notes_list = notes_list, viewer = self, single_book = true, book_title = book_title })
end
function AllNotesViewer:showAllNotes()
    -- The first open after starting KOReader may have to read many books: say so
    local loading
    if not _persist then
        loading = NotesListWidget.States.loading()
    end
    local all_notes_by_book = self:findAllNotes()
    local notes_list = {}
    
    local function split_tags(val)
        if not val then return nil end
        if type(val) == "table" then return val end
        if type(val) == "string" then
            local t = {}
            for tag in val:gmatch("[^,;\n|\t]+") do
                tag = tag:match("^%s*(.-)%s*$")
                if tag ~= "" then table.insert(t, tag) end
            end
            return t
        end
        return nil
    end
    
    for _, book_data in ipairs(all_notes_by_book) do
        local book_tags_table = split_tags(book_data.tags)
        for _, note in ipairs(book_data.notes) do
            local note_tags = split_tags(note.tags) or book_tags_table or {}
            
            local tag_set = {}
            for _, tag in ipairs(note_tags) do if tag ~= "" then tag_set[tag] = true end end
            local all_tags = {}
            for tag in pairs(tag_set) do table.insert(all_tags, tag) end
            table.sort(all_tags)
            table.insert(notes_list, {
                book_title = book_data.title, book_authors = book_data.authors,
                book_filename = book_data.filename,
                book_path = book_data.path, page = note.page, chapter = note.chapter,
                pos0 = note.pos0, pos1 = note.pos1,
                highlighted_text = note.text, user_note = note.notes,
                datetime = note.datetime, drawer = note.drawer, color = note.color,
                tags = all_tags
            })
        end
    end
    local sort_mode = getSetting("sort_mode", "date_newest")
    NotesListWidget:sortNotesList(notes_list, sort_mode)
    local widget = NotesListWidget:new{ notes_list = notes_list, viewer = self }
    if loading then UIManager:close(loading) end
    UIManager:show(widget)
end
-- Annotation sheet and Filter & sort screen (in a block to stay under Lua's 200-locals limit)
do
-- Annotation sheet: opens from the bottom when an annotation is tapped. Shows the whole
-- highlight in its colour, the note, style and colour choices, and Go to / Copy / Delete.
local HIGHLIGHT_STYLES = {
    { "lighten", _("Lighten") }, { "underscore", _("Underline") },
    { "strikeout", _("Strikeout") }, { "invert", _("Invert") },
}
-- Highlight text as the list draws it: one row per wrapped line, each in the highlight's
-- colour (or underlined / struck through / inverted). Returns the widget and whether the
-- text was cut to max_lines.
local function cleanHighlightText(text)
    local paras = {}
    for p in ((text or ""):gsub("\r", "") .. "\n"):gmatch("([^\n]*)\n") do
        p = trimParagraph(p)
        if p ~= "" then table.insert(paras, p) end
    end
    return table.concat(paras, "\n")
end
-- in_box: the caller paints the colour behind all lines (rounded box), so lines get no
-- background of their own, only the text colour and underline/strikeout.
local function buildHighlightLines(text, face, width, drawer, color, max_lines, in_box)
    drawer = drawer or "lighten"
    local h_pad, v_pad = Size.padding.small, 1
    local line_width = width - h_pad * 2
    local fg, bg = BlitBuffer.COLOR_BLACK, BlitBuffer.COLOR_WHITE
    if drawer == "invert" then
        fg, bg = BlitBuffer.COLOR_WHITE, BlitBuffer.COLOR_BLACK
    elseif not isNoBackgroundStyle(drawer) then
        bg = getHighlightColor(color)
    end
    local lines, para_end = wrapText(text, face, line_width)
    local cut = max_lines and #lines > max_lines
    if cut then
        local kept = {}
        for i = 1, max_lines do kept[i] = lines[i] end
        local last = kept[max_lines]
        while #last > 0 and measureTextWidth(last .. "…", face) > line_width do last = last:sub(1, -2) end
        kept[max_lines] = last .. "…"
        lines = kept
    end
    local justify = getJustify() == true
    local group = VerticalGroup:new{ align = "left" }
    for i, line in ipairs(lines) do
        local w
        if justify and i < #lines and not para_end[i] and not (cut and i == #lines) then
            w = createJustifiedLine(line, face, line_width, fg)
        else
            w = TextWidget:new{ text = line, face = face, fgcolor = fg }
        end
        local sz = w:getSize()
        local total_w, total_h = sz.w + h_pad * 2, sz.h + v_pad * 2
        if drawer == "strikeout" or drawer == "underscore" then
            local items = { CenterContainer:new{ dimen = Geom:new{ w = total_w, h = total_h }, w } }
            if drawer == "strikeout" then
                table.insert(items, StrikeoutLineWidget:new{ width = total_w, height = total_h, y_offset = math.floor(total_h / 2) })
            else
                table.insert(items, UnderlineWidget:new{ width = total_w, height = total_h })
            end
            table.insert(group, OverlapGroup:new{ dimen = Geom:new{ w = total_w, h = total_h }, unpack(items) })
        else
            table.insert(group, FrameContainer:new{
                padding = v_pad, padding_left = h_pad, padding_right = h_pad,
                margin = 0, bordersize = 0, background = (not in_box) and bg or nil, w,
            })
        end
    end
    return group, cut
end

local AnnotationSheet = InputContainer:extend{
    note = nil, viewer = nil, parent_widget = nil,
}
function AnnotationSheet:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.ges_events = {
        TapOutside = { GestureRange:new{ ges = "tap", range = self.dimen } },
    }
    if Device:hasKeys() then
        self.key_events.Close = { { Input.group.Back } }
    end
    self:build()
end
-- Row-by-row helpers for rounded shapes we draw ourselves (exact control over corners).
local function circleInset(r, row) -- distance in from the edge of a radius-r corner on this row
    local dy = r - row - 0.5
    if dy <= 0 then return 0 end
    if dy >= r then return r end
    return math.ceil(r - math.sqrt(r * r - dy * dy))
end
local function paintRow(bb, x, y, w, color)
    if w <= 0 then return end
    if BlitBuffer.isColor8(color) then bb:paintRect(x, y, w, 1, color) else bb:paintRectRGB32(x, y, w, 1, color) end
end

-- Bottom sheet: white panel across the full width, rounded top corners, border on top only.
local SheetFrame = InputContainer:extend{ width = 0, radius = 0, border = 2, pad_x = 0, pad_top = 0, pad_bottom = 0 }
function SheetFrame:getSize()
    return Geom:new{ w = self.width, h = self[1]:getSize().h + self.pad_top + self.pad_bottom + self.border }
end
function SheetFrame:paintTo(bb, x, y)
    local size = self:getSize()
    self.dimen = Geom:new{ x = x, y = y, w = size.w, h = size.h }
    local w, h, r, bw = size.w, size.h, self.radius, self.border
    -- The rounded top is drawn with KOReader's own (anti-aliased) rounded fill and border on
    -- a scratch copy of the strip under it. That rounded box is wider than the sheet (by
    -- `ext` on each side), so the corners curve on past the sheet's edges instead of ending
    -- in a short upright line; only the visible middle and top rows are copied back.
    -- narrower than the screen (landscape): real corners and outlined sides instead
    local narrow = w < Screen:getWidth()
    local ext = narrow and 0 or math.floor(r * 0.3)
    local band_h = math.min(h, r * 2 + bw * 2)
    local tmp = BlitBuffer.new(w + ext * 2, band_h, bb:getType())
    tmp:fill(BlitBuffer.COLOR_WHITE)
    tmp:blitFrom(bb, ext, 0, x, y, w, band_h)
    tmp:paintRoundedRect(0, 0, w + ext * 2, band_h, BlitBuffer.COLOR_WHITE, r)
    tmp:paintBorder(0, 0, w + ext * 2, band_h, bw, BlitBuffer.COLOR_BLACK, r, G_reader_settings:nilOrTrue("anti_alias_ui"))
    bb:blitFrom(tmp, x, y, ext, 0, w, r)
    tmp:free()
    bb:paintRect(x, y + r, w, h - r, BlitBuffer.COLOR_WHITE)
    if narrow then
        bb:paintRect(x, y + r, bw, h - r, BlitBuffer.COLOR_BLACK)
        bb:paintRect(x + w - bw, y + r, bw, h - r, BlitBuffer.COLOR_BLACK)
    end
    self[1]:paintTo(bb, x + self.pad_x, y + bw + self.pad_top)
end

-- Box with rounded corners, filled row by row (so a colour fill looks the same on colour
-- and black-and-white screens, with no square colour corners), optional outline, padded child.
local RoundedBox = InputContainer:extend{ width = 0, fill = nil, radius = 0, border = 0, border_color = nil, pad_x = 0, pad_y = 0 }
function RoundedBox:getSize()
    return Geom:new{ w = self.width, h = self[1]:getSize().h + self.pad_y * 2 }
end
function RoundedBox:paintTo(bb, x, y)
    local size = self:getSize()
    self.dimen = Geom:new{ x = x, y = y, w = size.w, h = size.h }
    local w, h, r = size.w, size.h, self.radius
    if self.fill then
        for row = 0, h - 1 do
            local o = 0
            if row < r then o = circleInset(r, row) elseif row >= h - r then o = circleInset(r, h - 1 - row) end
            paintRow(bb, x + o, y + row, w - o * 2, self.fill)
        end
    end
    if self.border > 0 then
        bb:paintBorder(x, y, w, h, self.border, self.border_color or BlitBuffer.COLOR_BLACK, r,
            G_reader_settings:nilOrTrue("anti_alias_ui"))
    end
    self[1]:paintTo(bb, x + self.pad_x, y + self.pad_y)
end

-- Draws its child, then a rounded border over it, cutting the child's corners to the curve
-- (so a filled first/last segment follows the rounded corner, like CSS overflow:hidden).
local RoundedOutline = InputContainer:extend{ radius = 0, border = 2, color = nil }
function RoundedOutline:getSize()
    local cs = self[1]:getSize()
    return Geom:new{ w = cs.w + self.border * 2, h = cs.h + self.border * 2 }
end
function RoundedOutline:paintTo(bb, x, y)
    local size = self:getSize()
    self.dimen = Geom:new{ x = x, y = y, w = size.w, h = size.h }
    local w, h, r = size.w, size.h, self.radius
    self[1]:paintTo(bb, x + self.border, y + self.border)
    for row = 0, r - 1 do
        local o = circleInset(r, row)
        paintRow(bb, x, y + row, o, BlitBuffer.COLOR_WHITE)
        paintRow(bb, x + w - o, y + row, o, BlitBuffer.COLOR_WHITE)
        paintRow(bb, x, y + h - 1 - row, o, BlitBuffer.COLOR_WHITE)
        paintRow(bb, x + w - o, y + h - 1 - row, o, BlitBuffer.COLOR_WHITE)
    end
    bb:paintBorder(x, y, w, h, self.border, self.color or BlitBuffer.COLOR_BLACK, r,
        G_reader_settings:nilOrTrue("anti_alias_ui"))
end

-- Text with an underline or a line through it, as a single widget.
local function decoratedText(tw, deco, color)
    if not deco then return tw end
    local sz = tw:getSize()
    local line_h = Size.line.medium
    local line = LineWidget:new{ dimen = Geom:new{ w = sz.w, h = line_h }, background = color }
    if deco == "underline" then
        return VerticalGroup:new{ tw, line }
    end
    -- strikeout: line a little above the middle (x-height middle)
    return OverlapGroup:new{ dimen = Geom:new{ w = sz.w, h = sz.h }, tw,
        VerticalGroup:new{ VerticalSpan:new{ width = math.floor(sz.h * 0.55) }, line } }
end

function AnnotationSheet:build()
    local note, viewer, parent = self.note, self.viewer, self.parent_widget
    local nw = NoteWrapper:new(note)
    local W, H = Screen:getWidth(), Screen:getHeight()
    -- bottom sheet as in the mockup: full width (in landscape no wider than the list column)
    local sheet_w = W
    if W > H then sheet_w = math.min(W, math.floor(H * 1.1)) end
    local P = Screen:scaleBySize(28)
    local inner = sheet_w - P * 2
    local gap = Screen:scaleBySize(18)
    local label_gap = Screen:scaleBySize(8)
    -- KOReader's own border sizes (Size.*): scaled for the screen's DPI like all its dialogs
    local thick = Size.border.thick   -- 2px at 160dpi
    local thin = Size.border.button   -- 1.5px at 160dpi
    local LIGHT = COLORS.line
    local MUTED = COLORS.muted
    local label_face = Font:getFace("cfont", 11)
    local group = VerticalGroup:new{ align = "left" }
    local function sectionLabel(text, right)
        local lbl = TextWidget:new{ text = text, face = label_face, bold = true, fgcolor = MUTED }
        if not right then return lbl end
        local d = Geom:new{ w = inner, h = math.max(lbl:getSize().h, right:getSize().h) }
        return OverlapGroup:new{ dimen = d, allow_mirroring = false,
            LeftContainer:new{ dimen = d, lbl }, RightContainer:new{ dimen = d, right } }
    end
    local function actionButton(text, callback, primary, width)
        local tw = TextWidget:new{ text = text, face = Font:getFace("cfont", 15), bold = primary,
            max_width = width - Screen:scaleBySize(12),
            fgcolor = primary and BlitBuffer.COLOR_WHITE or BlitBuffer.COLOR_BLACK }
        local height = Screen:scaleBySize(48)
        local bw = primary and 0 or thin
        return TapBox:new{
            FrameContainer:new{
                bordersize = bw, radius = Screen:scaleBySize(8), padding = 0, margin = 0,
                background = primary and BlitBuffer.COLOR_BLACK or BlitBuffer.COLOR_WHITE,
                CenterContainer:new{ dimen = Geom:new{ w = width - bw * 2, h = height - bw * 2 }, tw },
            },
            callback = callback,
        }
    end

    -- 1. book title, info line, close
    local close_btn = IconButton:new{
        icon = "close", width = Screen:scaleBySize(22), height = Screen:scaleBySize(22),
        padding = Screen:scaleBySize(11), allow_flash = false,
        callback = function() self:onClose() end, show_parent = self,
    }
    local close_w = close_btn:getSize().w
    local text_w = inner - close_w + Screen:scaleBySize(10)
    local meta = {}
    local authors = nw:getDisplayAuthors()
    if authors and authors ~= "Unknown" then table.insert(meta, ((note.book_authors or authors):gsub("\n", ", "))) end
    if note.chapter and note.chapter ~= "" then table.insert(meta, note.chapter) end
    local date_text = NoteItemWidget:formatDate(note.datetime)
    if date_text then table.insert(meta, date_text) end
    if tonumber(note.page) and tonumber(note.page) > 0 then table.insert(meta, _("page") .. " " .. tostring(tonumber(note.page))) end
    local head = VerticalGroup:new{ align = "left",
        TextBoxWidget:new{ text = note.book_title or _("Annotation"), face = getFaceOr(SERIF_FONT, 20, "cfont"),
            bold = true, width = text_w },
    }
    if #meta > 0 then
        table.insert(head, VerticalSpan:new{ width = Screen:scaleBySize(3) })
        table.insert(head, TextBoxWidget:new{ text = table.concat(meta, " · "), face = Font:getFace("cfont", 12),
            fgcolor = MUTED, width = text_w })
    end
    -- close button pulled up and right like the mockup (-8px / -10px)
    table.insert(group, HorizontalGroup:new{ align = "top", head,
        HorizontalSpan:new{ width = inner - text_w - close_w + Screen:scaleBySize(10) },
        VerticalGroup:new{ VerticalSpan:new{ width = 0 }, close_btn } })
    table.insert(group, VerticalSpan:new{ width = gap - Screen:scaleBySize(8) })

    -- 2. the highlight in a rounded box: filled with its colour (Lighten) or black (Invert),
    -- or white with a light outline (Underline/Strikeout, whose lines are drawn on the text).
    -- Long ones are cut and open in full on tap.
    if nw:hasHighlightedText() then
        local drawer = note.drawer or "lighten"
        local no_fill = isNoBackgroundStyle(drawer)
        local fill
        if drawer == "invert" then
            fill = BlitBuffer.COLOR_BLACK
        elseif not no_fill then
            -- same colour value and the same drawing call (paintRectRGB32) as the list's lines,
            -- so the screen turns it into exactly the same shade there and here
            fill = getHighlightColor(note.color)
        end
        local quote_text = cleanHighlightText(note.highlighted_text)
        local content_face = select(3, getNoteFaces())
        local max_lines = math.max(3, math.floor(H * 0.28 / (getLineHeight(content_face) + 2)))
        local pad_v, pad_h = Screen:scaleBySize(10), Screen:scaleBySize(12)
        local ob = Size.border.thin
        -- same outer size for every style: the outline (when shown) takes the place of padding
        local bw = no_fill and ob or 0
        local lines, cut = buildHighlightLines(quote_text, content_face, inner - (pad_h + ob) * 2,
            drawer, note.color, max_lines, true)
        local box = RoundedBox:new{
            true_color = not no_fill and drawer ~= "invert",
            width = inner, fill = fill or BlitBuffer.COLOR_WHITE, radius = Screen:scaleBySize(6),
            border = bw, border_color = LIGHT, pad_x = pad_h + ob, pad_y = pad_v + ob,
            lines,
        }
        table.insert(group, cut and TapBox:new{ box, callback = function()
            NotesListWidget.showDialog(TextViewer:new{ title = note.book_title or _("Annotation"), text = quote_text })
        end } or box)
        if cut then
            table.insert(group, VerticalSpan:new{ width = Screen:scaleBySize(4) })
            table.insert(group, TextWidget:new{ text = _("Tap the highlight to read all of it"),
                face = Font:getFace("cfont", 12), fgcolor = MUTED })
        end
        table.insert(group, VerticalSpan:new{ width = gap })
    end

    -- 3. note, with an underlined Edit / Add note link
    local has_note = nw:hasUserNote()
    local link = TextWidget:new{ text = has_note and _("Edit") or _("Add note"), face = Font:getFace("cfont", 13) }
    local edit_link = TapBox:new{
        decoratedText(link, "underline", BlitBuffer.COLOR_BLACK),
        callback = function()
            viewer:editNote(note, parent, function() self:rebuild() end)
        end,
    }
    table.insert(group, sectionLabel(_("YOUR NOTE"), edit_link))
    table.insert(group, VerticalSpan:new{ width = Screen:scaleBySize(6) })
    if has_note then
        table.insert(group, TextBoxWidget:new{
            text = note.user_note, face = Font:getFace("cfont", 15), width = inner, line_height = 0.45,
            height = math.min(Screen:scaleBySize(120), math.floor(H * 0.18)),
            height_adjust = true, height_overflow_show_ellipsis = true,
        })
    else
        table.insert(group, TextWidget:new{ text = _("No note yet."), face = Font:getFace("cfont", 15), fgcolor = MUTED })
    end
    table.insert(group, VerticalSpan:new{ width = gap })

    -- 4. style: one bordered row of four; Underline/Strikeout labels show their line;
    -- the chosen one is filled black with white bold text
    table.insert(group, sectionLabel(_("STYLE")))
    table.insert(group, VerticalSpan:new{ width = label_gap })
    local current = note.drawer or "lighten"
    local cell_w = math.floor((inner - thin * 2 - thin * 3) / 4)
    local cell_h = Screen:scaleBySize(44)
    local seg = HorizontalGroup:new{}
    local ui_face = Font:getFace("cfont", 14)
    for i, st in ipairs(HIGHLIGHT_STYLES) do
        local key = st[1]
        local on = (current == key)
        if i > 1 then
            table.insert(seg, LineWidget:new{ dimen = Geom:new{ w = thin, h = cell_h }, background = BlitBuffer.COLOR_BLACK })
        end
        local color = on and BlitBuffer.COLOR_WHITE or BlitBuffer.COLOR_BLACK
        local tw = TextWidget:new{ text = st[2], face = ui_face, bold = on, fgcolor = color,
            max_width = cell_w - Screen:scaleBySize(24) }
        local deco = (key == "underscore" and "underline") or (key == "strikeout" and "strike") or nil
        local label = HorizontalGroup:new{ align = "center", decoratedText(tw, deco, color) }
        table.insert(seg, TapBox:new{
            FrameContainer:new{
                bordersize = 0, padding = 0, margin = 0,
                background = on and BlitBuffer.COLOR_BLACK or BlitBuffer.COLOR_WHITE,
                CenterContainer:new{ dimen = Geom:new{ w = cell_w, h = cell_h }, label },
            },
            callback = function()
                if not on then
                    viewer:setHighlightField(note, "drawer", key, parent)
                    self:rebuild()
                end
            end,
        })
    end
    table.insert(group, RoundedOutline:new{ radius = Screen:scaleBySize(8), border = thin, seg })
    table.insert(group, VerticalSpan:new{ width = gap })

    -- 5. colour: white rounded chips with a colour dot and the name; the chosen one has a
    -- thick black border and bold name. Widths are worked out for the bold version so
    -- choosing a colour never reflows the rows.
    table.insert(group, sectionLabel(_("COLOUR")))
    table.insert(group, VerticalSpan:new{ width = label_gap })
    local cur_color = nw:getNormalizedColor()
    local chip_h = Screen:scaleBySize(36)
    local chip_gap = Screen:scaleBySize(8)
    local dot = Screen:scaleBySize(16)
    local chip_face = Font:getFace("cfont", 13)
    local rows = VerticalGroup:new{ align = "left" }
    local row, row_w = HorizontalGroup:new{}, 0
    for _i, c in ipairs(ReaderHighlight.highlight_colors) do
        local key, name = c[2], c[1]
        local on = (cur_color == key)
        local widest = TextWidget:new{ text = name, face = chip_face, bold = true }:getSize().w
        local label = HorizontalGroup:new{ align = "center",
            Pill:new{ width = dot, height = dot, border = 0, true_color = true,
                fill = key == "gray" and BlitBuffer.COLOR_GRAY or getHighlightColor(key) },
            HorizontalSpan:new{ width = Screen:scaleBySize(6) },
            TextWidget:new{ text = name, face = chip_face, bold = on },
        }
        -- the same space on both sides: dot and name sit in the middle of the chip
        local pad = Screen:scaleBySize(12)
        local chip_w = pad * 2 + dot + Screen:scaleBySize(6) + widest
        local chip = TapBox:new{
            Pill:new{
                width = chip_w, height = chip_h,
                label, -- Pill centres its child
                fill = BlitBuffer.COLOR_WHITE,
                border = on and thick or thin,
                border_color = on and BlitBuffer.COLOR_BLACK or LIGHT,
            },
            callback = function()
                if not on then
                    viewer:setHighlightField(note, "color", key, parent)
                    self:rebuild()
                end
            end,
        }
        if row_w > 0 and row_w + chip_gap + chip_w > inner then
            table.insert(rows, row)
            table.insert(rows, VerticalSpan:new{ width = chip_gap })
            row, row_w = HorizontalGroup:new{}, 0
        end
        if row_w > 0 then table.insert(row, HorizontalSpan:new{ width = chip_gap }); row_w = row_w + chip_gap end
        table.insert(row, chip)
        row_w = row_w + chip_w
    end
    if row_w > 0 then table.insert(rows, row) end
    table.insert(group, rows)
    table.insert(group, VerticalSpan:new{ width = gap + Screen:scaleBySize(4) })

    -- 6. actions: Go to (twice as wide) and Delete
    local btn_gap = Screen:scaleBySize(10)
    local btn_row = HorizontalGroup:new{}
    local can_open = note.book_path and lfs.attributes(note.book_path, "mode") ~= nil
    local unit = math.floor((inner - btn_gap) / 3)
    if can_open then
        table.insert(btn_row, actionButton(has_note and _("Go to note") or _("Go to highlight"), function()
            self:onClose()
            UIManager:close(parent)
            viewer:openBookAtNote(note)
        end, true, inner - btn_gap - unit))
        table.insert(btn_row, HorizontalSpan:new{ width = btn_gap })
    end
    table.insert(btn_row, actionButton(_("Delete"), function()
        self:onClose()
        viewer:confirmDelete(note, parent)
    end, false, can_open and unit or inner))
    table.insert(group, btn_row)

    self.sheet = SheetFrame:new{
        -- Size.border.window: the outline KOReader uses on its own dialogs and buttons
        width = sheet_w, radius = Screen:scaleBySize(14), border = Size.border.window,
        pad_x = P, pad_top = Screen:scaleBySize(18), pad_bottom = Screen:scaleBySize(18), -- same as screen footers
        group,
    }
    local sheet_h = self.sheet:getSize().h
    self[1] = BottomContainer:new{
        dimen = Geom:new{ w = W, h = H },
        CenterContainer:new{ dimen = Geom:new{ w = W, h = sheet_h }, self.sheet },
    }
end
function AnnotationSheet:rebuild()
    self:build()
    UIManager:setDirty(self, "ui")
end
function AnnotationSheet:onTapOutside(_, ges)
    local d = self.sheet and self.sheet.dimen
    if d and ges and ges.pos and ges.pos:intersectWith(d) then return true end
    self:onClose()
    return true
end
function AnnotationSheet:onClose()
    UIManager:close(self, "ui", self.sheet and self.sheet.dimen)
    return true
end

-- "Filter & sort": full-screen page from the mockup. Changes apply straight away (the list
-- behind updates and the button shows how many are left); Cancel / ✕ / Back put everything
-- back as it was when the page opened.
-- Shared title bar for full-screen pages (Filter & sort, pickers): same height, icon size,
-- spacing and serif title as the list's top bar; ‹ on the left, ✕ on the right (both cancel).
local Page = {} -- shared pieces of the full-screen pages (kept in one table: Lua allows 200 locals)
-- A tick (or ✕) drawn with plain white strokes, so it shows on every device (no icon file, no font glyph)
Page.Glyph = WidgetContainer:extend{ kind = "check", size = 18 }
function Page.Glyph:getSize() return Geom:new{ w = self.size, h = self.size } end
function Page.Glyph:paintTo(bb, x, y)
    local s = self.size
    local t = math.max(2, Screen:scaleBySize(2))
    local function stroke(x1, y1, x2, y2)
        local steps = math.max(math.abs(x2 - x1), math.abs(y2 - y1))
        for i = 0, steps do
            local f = steps > 0 and i / steps or 0
            local px, py = x + math.floor(x1 + (x2 - x1) * f), y + math.floor(y1 + (y2 - y1) * f)
            bb:paintRect(px, py, t, t, BlitBuffer.COLOR_WHITE)
        end
    end
    if self.kind == "check" then
        stroke(s * 0.12, s * 0.52, s * 0.38, s * 0.78)
        stroke(s * 0.38, s * 0.78, s * 0.88, s * 0.2)
    else
        stroke(s * 0.2, s * 0.2, s * 0.8, s * 0.8)
        stroke(s * 0.8, s * 0.2, s * 0.2, s * 0.8)
    end
end
-- KOReader's own "check" / "close" icon in white. KOReader icons are black on white, so the icon is
-- painted onto a white scratch buffer, inverted by hand and copied over: this does not depend on
-- IconWidget's `invert` flag or its alpha handling, which is what showed up as white boxes before.
-- If the icon file is missing (or comes out blank) the drawn Glyph above is used instead.
Page.IconMark = WidgetContainer:extend{ icon = "check", size = 18 }
function Page.IconMark:init()
    self.iw = IconWidget:new{ icon = self.icon, width = self.size, height = self.size }
    self.glyph = Page.Glyph:new{ kind = self.icon == "close" and "close" or "check", size = self.size }
    self.missing = tostring(self.iw.file or ""):find("icon-not-found", 1, true) ~= nil
    if self.missing then logger.warn("AnnotationsViewer: icon '" .. self.icon .. "' not found, drawing it instead") end
end
function Page.IconMark:getSize() return Geom:new{ w = self.size, h = self.size } end
function Page.IconMark:paintTo(bb, x, y)
    if self.missing then return self.glyph:paintTo(bb, x, y) end
    local n = self.size
    local tmp = BlitBuffer.new(n, n, bb:getType())
    tmp:fill(BlitBuffer.COLOR_WHITE)
    self.iw:paintTo(tmp, 0, 0)
    -- blank (all white) result: nothing visible from the icon, draw the tick ourselves
    local dark = false
    for yy = 0, n - 1, 2 do
        for xx = 0, n - 1, 2 do
            if tmp:getPixel(xx, yy):getColor8().a < 200 then dark = true; break end
        end
        if dark then break end
    end
    if not dark then tmp:free(); return self.glyph:paintTo(bb, x, y) end
    tmp:invertRect(0, 0, n, n)
    bb:blitFrom(tmp, x, y, 0, 0, n, n)
    tmp:free()
end
-- The ✓ / ✕ text characters (what KOReader's own CheckMark widget uses), centred on the ink: the
-- character is drawn once on a scratch buffer, its real outline measured, and the dark pixels are then
-- painted in white so that the outline sits exactly in the middle of the box (a font's own metrics
-- leave glyphs off-centre). No glyph in the font (blank result) -> KOReader's icon is used instead.
Page.TextMark = WidgetContainer:extend{ icon = "check", size = 18 }
function Page.TextMark:init()
    self.char = self.icon == "close" and "\226\156\149" or "\226\156\147" -- ✕ / ✓
    self.fallback = Page.IconMark:new{ icon = self.icon, size = self.size }
end
function Page.TextMark:getSize() return Geom:new{ w = self.size, h = self.size } end
function Page.TextMark:measure(bbtype)
    local n = self.size
    local m = n * 3
    local tmp = BlitBuffer.new(m, m, bbtype)
    tmp:fill(BlitBuffer.COLOR_WHITE)
    local face = Font:getFace("cfont", self.icon == "close" and 15 or 18)
    local tw = TextWidget:new{ text = self.char, face = face, bold = true }
    tw:paintTo(tmp, 0, 0)
    tw:free()
    local dots, x0, x1, y0, y1 = {}, m, -1, m, -1
    for yy = 0, m - 1 do
        for xx = 0, m - 1 do
            local g = tmp:getPixel(xx, yy):getColor8().a
            if g < 200 then
                table.insert(dots, { xx, yy, 255 - g })
                if xx < x0 then x0 = xx end; if xx > x1 then x1 = xx end
                if yy < y0 then y0 = yy end; if yy > y1 then y1 = yy end
            end
        end
    end
    tmp:free()
    if #dots == 0 then self.dots = false; return end
    local ox = math.floor((n - (x1 - x0 + 1)) / 2) - x0
    local oy = math.floor((n - (y1 - y0 + 1)) / 2) - y0
    self.dots = {}
    for _, d in ipairs(dots) do
        local px, py = d[1] + ox, d[2] + oy
        if px >= 0 and py >= 0 and px < n and py < n then
            table.insert(self.dots, { px, py, BlitBuffer.Color8(d[3]) })
        end
    end
end
function Page.TextMark:paintTo(bb, x, y)
    if self.dots == nil then self:measure(bb:getType()) end
    if not self.dots then return self.fallback:paintTo(bb, x, y) end
    for _, d in ipairs(self.dots) do bb:paintRect(x + d[1], y + d[2], 1, 1, d[3]) end
end
function Page.header(owner, title, on_back, right_items, no_back, on_close)
    local W = Screen:getWidth()
    local side = Screen:scaleBySize(8)
    local d = Geom:new{ w = W, h = TOPBAR_HEIGHT }
    local right = HorizontalGroup:new{ align = "center" }
    for _i, it in ipairs(right_items or {}) do table.insert(right, it) end
    table.insert(right, newHeaderButton("close", on_close or on_back, owner, nil, false))
    table.insert(right, HorizontalSpan:new{ width = side })
    local right_w = right:getSize().w
    local left_w = side + HEADER_ICON_SIZE + HEADER_ICON_PAD * 2 + side
    -- no_back: pages that only have ✕ (the empty-list page) start the title at the edge
    local left = HorizontalGroup:new{ align = "center", HorizontalSpan:new{ width = side + (no_back and side or 0) } }
    if not no_back then
        table.insert(left, newHeaderButton(BD.mirroredUILayout() and "chevron.right" or "chevron.left", on_back, owner, nil, false))
        table.insert(left, HorizontalSpan:new{ width = side })
    end
    table.insert(left, TextWidget:new{ text = title, face = getFaceOr(SERIF_FONT, 21, "cfont"), bold = true,
        max_width = W - left_w - right_w - side })
    return VerticalGroup:new{
        OverlapGroup:new{ dimen = d, allow_mirroring = false,
            LeftContainer:new{ dimen = d, left },
            RightContainer:new{ dimen = d, right },
        },
        LineWidget:new{ dimen = Geom:new{ w = W, h = Size.line.thin }, background = COLORS.line },
    }
end
-- Shared bottom bar: line, then Cancel (1/3) and the main button (2/3), 48 high, same padding
-- everywhere.
Page.BUTTON_H = Screen:scaleBySize(48)
Page.FOOTER_TOP, Page.FOOTER_BOTTOM = Screen:scaleBySize(12), Screen:scaleBySize(18)
function Page.button(text, primary, width, callback)
    local tw = TextWidget:new{ text = text, face = Font:getFace("cfont", 15), bold = primary,
        max_width = width - Screen:scaleBySize(12), fgcolor = primary and BlitBuffer.COLOR_WHITE or COLORS.ink }
    return TapBox:new{ RoundedBox:new{ width = width, radius = Screen:scaleBySize(8),
        fill = primary and COLORS.ink or BlitBuffer.COLOR_WHITE, border = primary and 0 or Size.border.button,
        border_color = COLORS.ink, pad_x = 0, pad_y = 0,
        CenterContainer:new{ dimen = Geom:new{ w = width, h = Page.BUTTON_H }, tw } }, callback = callback }
end
function Page.footer(cancel_cb, primary_text, primary_cb)
    local W = Screen:getWidth()
    local P = Screen:scaleBySize(24)
    local inner = W - P * 2
    local gap = Screen:scaleBySize(10)
    local bw1 = math.floor((inner - gap) / 3)
    return VerticalGroup:new{
        LineWidget:new{ dimen = Geom:new{ w = W, h = Size.line.thin }, background = COLORS.line },
        VerticalSpan:new{ width = Page.FOOTER_TOP },
        HorizontalGroup:new{ HorizontalSpan:new{ width = P },
            Page.button(_("Cancel"), false, bw1, cancel_cb),
            HorizontalSpan:new{ width = gap },
            Page.button(primary_text, true, inner - gap - bw1, primary_cb) },
        VerticalSpan:new{ width = Page.FOOTER_BOTTOM },
    }
end
-- Scrolling body for the full-screen pages. KOReader's scroll container keeps room for its bar
-- on the right (3 bar widths) and would add a horizontal bar when the content is as wide as
-- the screen, so the content is measured that much narrower (the right padding is what gets
-- cut). The bar is drawn like the list's own: a thin line with a rounded, outlined thumb.
-- How much narrower than the screen the content of a scrolling page is laid out, so the right
-- padding plus the scrollbar strip match the list (strip of SB_STRIP_WIDTH, thumb centred).
-- (plus a little slack, so nothing at the right edge can end up under the crop line)
Page.SCROLL_EXTRA = 0 -- (a wider strip made the right-hand controls get cut off on the device)
function Page.scrollable(w, h, show_parent, child)
    if not Page.ScrollClass then
        local SC = require("ui/widget/container/scrollablecontainer")
        local C = SC:extend{ scroll_bar_width = SB_THUMB_WIDTH }
        function C:initState()
            SC.initState(self)
            local bar = self._v_scroll_bar
            if not bar then return end
            bar.paintTo = function(b, bb, x, y)
                b.touch_dimen = Geom:new{ x = x - b.extra_touch_on_side, y = y,
                    w = b.width + 2 * b.extra_touch_on_side, h = b.height }
                -- thumb centred in the strip, with the same space above and below as the list's
                local tx = x + math.floor((b.width - SB_THUMB_WIDTH) / 2)
                local top, th_total = y + SB_MARGIN_V_TOP, b.height - SB_MARGIN_V_TOP - SB_MARGIN_V_BOTTOM
                bb:paintRect(tx + math.floor((SB_THUMB_WIDTH - SB_TRACK_WIDTH) / 2), top, SB_TRACK_WIDTH, th_total, COLORS.ink)
                local th = math.max(Screen:scaleBySize(16), math.floor(th_total * (b.high - b.low)))
                local ty = top + math.min(math.floor(b.low * th_total), th_total - th)
                local radius = math.floor(SB_THUMB_WIDTH / 2)
                bb:paintRoundedRect(tx, ty, SB_THUMB_WIDTH, th, BlitBuffer.COLOR_WHITE, radius)
                bb:paintBorder(tx, ty, SB_THUMB_WIDTH, th, Size.border.default, BlitBuffer.COLOR_BLACK, radius)
            end
        end
        Page.ScrollClass = C
        Page.ClipClass = WidgetContainer:extend{ clip_w = 0 }
        function Page.ClipClass:getSize()
            return Geom:new{ w = self.clip_w, h = self[1]:getSize().h }
        end
    end
    return Page.ScrollClass:new{ dimen = Geom:new{ w = w, h = h }, show_parent = show_parent,
        Page.ClipClass:new{ clip_w = w - 3 * SB_THUMB_WIDTH, child } }
end
-- Live sample of the list for the Text / Spacing pages: two real annotations drawn with the
-- current settings, clipped to a fixed height so the page below does not move.
Page.PreviewClip = WidgetContainer:extend{ w = 0, h = 0 }
function Page.PreviewClip:getSize() return Geom:new{ w = self.w, h = self.h } end
function Page.PreviewClip:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.w, h = self.h }
    local buf = BlitBuffer.new(self.w, self.h, bb:getType())
    buf:fill(BlitBuffer.COLOR_WHITE)
    self[1]:paintTo(buf, 0, 0)
    bb:blitFrom(buf, x, y, 0, 0, self.w, self.h)
    buf:free()
    if isScrollbarStyle() then -- the list's scrollbar: thin track and an outlined thumb, as a sample
        local cx = self.w - SB_STRIP_WIDTH - SB_MARGIN_RIGHT + math.floor(SB_STRIP_WIDTH / 2)
        local top, bot = Screen:scaleBySize(10), self.h - Screen:scaleBySize(10)
        bb:paintRect(x + cx, y + top, Size.line.thin, bot - top, BlitBuffer.COLOR_BLACK)
        local tw, th = SB_THUMB_WIDTH, math.floor((bot - top) / 3)
        bb:paintRect(x + cx - math.floor(tw / 2), y + top, tw, th, BlitBuffer.COLOR_WHITE)
        bb:paintBorder(x + cx - math.floor(tw / 2), y + top, tw, th, Size.border.default, BlitBuffer.COLOR_BLACK, math.floor(tw / 2))
    end
end
function Page.preview(list, h, mark_gap)
    local W = Screen:getWidth()
    local samples = {
        { book_title = "Lorem Ipsum", book_authors = "Dolor Sit", chapter = "Chapter One",
          datetime = "2026-01-09 10:12:00", drawer = "lighten", color = "yellow",
          highlighted_text = "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat.",
          user_note = "Duis aute irure dolor in reprehenderit in voluptate velit esse." },
        { book_title = "Lorem Ipsum", book_authors = "Dolor Sit", chapter = "Chapter One",
          datetime = "2026-01-09 10:20:00", drawer = "lighten", color = "blue",
          highlighted_text = "Excepteur sint occaecat cupidatat non proident, sunt in culpa qui officia deserunt mollit anim id est laborum." },
    }
    local g = VerticalGroup:new{ align = "left" }
    local top = getTopPadding()
    local first_h
    if top > 0 then table.insert(g, VerticalSpan:new{ width = top }) end
    -- same width and centring as the real list
    local avail = NoteItemWidget.listAvail(W)
    local nw = NoteItemWidget.columnWidth(avail, W, Screen:getHeight())
    local x_off = math.floor((avail - nw) / 2) + NoteItemWidget.scrollInset()
    for i, n in ipairs(samples) do
        if i > 1 then table.insert(g, VerticalSpan:new{ width = getNoteSpacing() }) end
        local ok, wdg = pcall(function()
            return NoteItemWidget:new{ width = nw, note = n, show_parent = list, skip_title = i > 1, disable_tap = true }
        end)
        if ok then
            table.insert(g, x_off > 0 and HorizontalGroup:new{ HorizontalSpan:new{ width = x_off }, wdg } or wdg)
            if i == 1 then first_h = wdg:getSize().h end
        end
    end
    -- Spacing page: end the preview just after the top of the second note, so the gap between the
    -- notes can be judged from the sliver of the next one
    if mark_gap and first_h then
        h = math.min(math.floor(Screen:getHeight() * 0.5), top + first_h + getNoteSpacing() + Screen:scaleBySize(28))
    end
    return VerticalGroup:new{ align = "left",
        Page.PreviewClip:new{ w = W, h = h, g },
        LineWidget:new{ dimen = Geom:new{ w = W, h = Size.line.thin }, background = COLORS.line } }
end
-- Pill / RoundedBox with `true_color = true` keep their colours in night mode (see paintTrue).
do
    local function trueColor(cls)
        local base = cls.paintTo
        function cls:paintTo(bb, x, y)
            if not self.true_color or not Screen.night_mode then return base(self, bb, x, y) end
            local size = self:getSize()
            NoteItemWidget.paintTrue(bb, x, y, size.w, size.h, function(b, xx, yy) base(self, b, xx, yy) end)
            self.dimen = Geom:new{ x = x, y = y, w = size.w, h = size.h }
        end
    end
    trueColor(Pill)
    trueColor(RoundedBox)
end
-- Menus, sheets and dropdowns sit above the list: pass the gestures they don't use on to the
-- KOReader gestures plugin, as the list does (corner taps, edge swipes, ...).
function Page.forwardGestures(cls)
    function cls:onGesture(ev)
        if self.toast then return false end -- toasts let everything through anyway
        if InputContainer.onGesture(self, ev) then return true end
        return _forwardGestureToPlugin(ev)
    end
end
Page.forwardGestures(AnnotationSheet)
-- Full-screen pages: rebuild for the new size when the screen was rotated.
function Page.watchResize(cls)
    function cls:paintTo(bb, x, y)
        local W, H = Screen:getWidth(), Screen:getHeight()
        if self.dimen and (self.dimen.w ~= W or self.dimen.h ~= H) and not self._resize_pending then
            self._resize_pending = true
            UIManager:nextTick(function()
                self._resize_pending = nil
                self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
                if self.rebuild then self:rebuild() else self:build() end
                UIManager:setDirty(self, "full")
            end)
        end
        InputContainer.paintTo(self, bb, x, y)
    end
end
-- ✕ on a sub page: close it and every page under it, back to the list.
function Page.exitAll(w)
    local first = true
    while w do
        UIManager:close(w, first and "flashui" or nil)
        first = false
        w = w.parent_screen or w.parent
    end
end
-- Full-screen pages are paged like the list, with the same Prev / Next bar instead of a scrollbar:
-- `rows` (a VerticalGroup) is cut into pages of whole rows that fit `avail` high; the first
-- `opts.fixed` rows stay on every page; `opts.left` pads the rows on the left. The page number is
-- kept in owner.page_idx, so rebuilding after a change stays on the same page.
function Page.paged(owner, W, avail, rows, opts)
    opts = opts or {}
    local fixed_n = opts.fixed or 0
    local n = #rows
    local fixed_h = 0
    for i = 1, math.min(fixed_n, n) do fixed_h = fixed_h + rows[i]:getSize().h end
    local total = 0
    for i = 1, n do total = total + rows[i]:getSize().h end
    local bar_h = FOOTER_BAR_HEIGHT + Size.line.medium
    local function wrap(g)
        if opts.left then return HorizontalGroup:new{ HorizontalSpan:new{ width = opts.left }, g } end
        return g
    end
    local pages = {}
    if total <= avail then
        pages[1] = { first = 1, last = n }
    else
        local cap = avail - bar_h - fixed_h
        local cur, h = nil, 0
        for i = fixed_n + 1, n do
            local rh = rows[i]:getSize().h
            if not cur or (h + rh > cap and h > 0) then
                local start = i
                if cur and i > 1 and rows[i - 1].keep_with_next and cur.last == i - 1 and cur.first < i - 1 then
                    -- a heading would end the page: it moves to the next one with its rows
                    cur.last = i - 2
                    start = i - 1
                    h = rows[start]:getSize().h
                else
                    h = 0
                end
                cur = { first = start, last = start }
                table.insert(pages, cur)
            end
            cur.last = i
            h = h + rh
        end
        if #pages == 0 then pages[1] = { first = n + 1, last = n } end
    end
    local count = #pages
    if count == 1 and owner.ges_events then owner.ges_events.PagedSwipe = nil end
    owner.page_idx = math.max(1, math.min(owner.page_idx or 1, count))
    local pg = pages[owner.page_idx]
    local g = VerticalGroup:new{ align = "left" }
    for i = 1, math.min(fixed_n, n) do table.insert(g, rows[i]) end
    for i = pg.first, pg.last do table.insert(g, rows[i]) end
    local content = wrap(g)
    if count == 1 then return content end

    local function go(p)
        owner.page_idx = p
        if owner.rebuild then owner:rebuild() else owner:build(); UIManager:setDirty(owner, "ui") end
    end
    local cur = owner.page_idx
    local has_prev, has_next = cur > 1, cur < count
    local face = Font:getFace("cfont", 13)
    local icon = Screen:scaleBySize(20)
    local cl, cr, cf, clast = "chevron.left", "chevron.right", "chevron.first", "chevron.last"
    if BD.mirroredUILayout() then cl, cr, cf, clast = cr, cl, clast, cf end
    local function pageButton(text, icon_name, icon_first, enabled, cb, hold_cb)
        local tw = TextWidget:new{ text = text, face = face, bold = enabled, fgcolor = enabled and COLORS.ink or COLORS.disabled }
        local iw = IconWidget:new{ icon = icon_name, width = icon, height = icon, dim = not enabled }
        local row = icon_first and HorizontalGroup:new{ align = "center", iw, HorizontalSpan:new{ width = Screen:scaleBySize(4) }, tw }
            or HorizontalGroup:new{ align = "center", tw, HorizontalSpan:new{ width = Screen:scaleBySize(4) }, iw }
        return TapBox:new{ CenterContainer:new{ dimen = Geom:new{ w = row:getSize().w + Screen:scaleBySize(20), h = FOOTER_BAR_HEIGHT }, row },
            callback = function() if enabled then cb() end end,
            hold_callback = function() if enabled then hold_cb() end end }
    end
    local function jumpButton(icon_name, enabled, cb)
        local iw = IconWidget:new{ icon = icon_name, width = icon, height = icon, dim = not enabled }
        return TapBox:new{ CenterContainer:new{ dimen = Geom:new{ w = icon + Screen:scaleBySize(20), h = FOOTER_BAR_HEIGHT }, iw },
            callback = function() if enabled then cb() end end }
    end
    local bd = Geom:new{ w = W, h = FOOTER_BAR_HEIGHT }
    local side = Screen:scaleBySize(2)
    local bar = OverlapGroup:new{ dimen = bd, allow_mirroring = false,
        LeftContainer:new{ dimen = bd, HorizontalGroup:new{ HorizontalSpan:new{ width = side },
            jumpButton(cf, has_prev, function() go(1) end),
            pageButton(_("Prev"), cl, true, has_prev, function() go(cur - 1) end, function() go(1) end) } },
        CenterContainer:new{ dimen = bd, TextWidget:new{ text = string.format("%d / %d", cur, count), face = face, bold = true } },
        RightContainer:new{ dimen = bd, HorizontalGroup:new{
            pageButton(_("Next"), cr, false, has_next, function() go(cur + 1) end, function() go(count) end),
            jumpButton(clast, has_next, function() go(count) end),
            HorizontalSpan:new{ width = side } } } }
    -- swipes (as the list's swipe setting) and page-turn keys also turn the pages
    local sw = getSwipeSetting()
    owner.ges_events = owner.ges_events or {}
    owner.ges_events.PagedSwipe = sw ~= "disabled" and { GestureRange:new{ ges = "swipe",
        range = Geom:new{ x = 0, y = 0, w = W, h = Screen:getHeight() } } } or nil
    owner.onPagedSwipe = function(_self, _args, ges)
        local d = ges and ges.direction
        local horiz = sw == "horizontal" or sw == "both"
        local vert = sw == "vertical" or sw == "both"
        if (d == "west" and horiz) or (d == "north" and vert) then
            if has_next then go(cur + 1) end
            return true
        elseif (d == "east" and horiz) or (d == "south" and vert) then
            if has_prev then go(cur - 1) end
            return true
        end
    end
    if Device:hasKeys() then
        owner.key_events = owner.key_events or {}
        owner.key_events.PagedNext = { { Input.group.PgFwd } }
        owner.key_events.PagedPrev = { { Input.group.PgBack } }
        owner.onPagedNext = function() if has_next then go(cur + 1) end return true end
        owner.onPagedPrev = function() if has_prev then go(cur - 1) end return true end
    end
    local used = content:getSize().h
    return VerticalGroup:new{ align = "left", content,
        VerticalSpan:new{ width = math.max(0, avail - bar_h - used) },
        LineWidget:new{ dimen = Geom:new{ w = W, h = Size.line.medium }, background = COLORS.line },
        bar }
end
function Page.countText(n)
    return n == 1 and _("Show 1 annotation") or string.format(_("Show %d annotations"), n)
end

-- States board: loading, no annotations, nothing matches, delete confirmation, export done.
-- Kept in one table (NotesListWidget.States) so the code outside this block can call it.
do -- own scope: keeps the main chunk under Lua's 200-locals limit
local States = {}
NotesListWidget.States = States

-- Text as separate single-line TextWidgets (same rendering as the tabs, so small grey text is
-- not drawn lighter than elsewhere on some devices); centred or left aligned within width.
function States.lines(text, face, width, color, bold, centered)
    local g = VerticalGroup:new{ align = centered and "center" or "left" }
    for _i, l in ipairs((wrapText(text, face, width))) do
        table.insert(g, TextWidget:new{ text = l, face = face, fgcolor = color, bold = bold })
    end
    if not centered then return g end
    return CenterContainer:new{ dimen = Geom:new{ w = width, h = g:getSize().h }, g }
end
function States.title(text, size, width, centered)
    return States.lines(text, getFaceOr(SERIF_FONT, size, "cfont"), width, COLORS.ink, true, centered)
end

-- Popup card: white box with KOReader's window border and rounded corners, at the centre or
-- the bottom. modal: tap outside / Back closes it. toast: never blocks the screen under it
-- (taps go through) and closes itself after `timeout` seconds.
States.Card = InputContainer:extend{
    anchor = "center", build = nil, modal = false, toast = false, timeout = nil, cancel_cb = nil,
    width = nil, pad_h = nil, pad_v = nil, left = nil, top = nil, -- for the ☰ menu: own size and place
}
Page.forwardGestures(States.Card)
function States.Card:init()
    local W, H = Screen:getWidth(), Screen:getHeight()
    local col_w = W > H and math.min(W, math.floor(H * 1.1)) or W
    local margin = Screen:scaleBySize(14)
    local bw = Size.border.window
    local pad = Screen:scaleBySize(16) + bw
    local pad_x, pad_y = self.pad_h or pad, self.pad_v or pad
    local box_w = self.width or (col_w - margin * 2)
    self.box = RoundedBox:new{ width = box_w, fill = BlitBuffer.COLOR_WHITE, radius = Screen:scaleBySize(10),
        border = bw, border_color = COLORS.ink, pad_x = pad_x, pad_y = pad_y, self.build(box_w - pad_x * 2, self) }
    local box_h = self.box:getSize().h
    self.box_x = self.left or math.floor((W - box_w) / 2)
    if self.top then
        self.box_y = self.top
    elseif self.anchor == "bottom" then
        self.box_y = H - box_h - Screen:scaleBySize(16)
    else
        self.box_y = math.floor((H - box_h) / 2)
    end
    -- only the card's own area is repainted when it appears or goes away
    self.dimen = Geom:new{ x = self.box_x, y = self.box_y, w = box_w, h = box_h }
    self[1] = self.box
    self.ges_events = {}
    if self.modal then
        self.ges_events.TapOutside = { GestureRange:new{ ges = "tap", range = Geom:new{ x = 0, y = 0, w = W, h = H } } }
        if Device:hasKeys() then self.key_events.Close = { { Input.group.Back } } end
    end
end
function States.Card:paintTo(bb)
    self.box:paintTo(bb, self.box_x, self.box_y)
end
function States.Card:onShow()
    if self.timeout then
        self.timeout_cb = function() UIManager:close(self, "ui") end
        UIManager:scheduleIn(self.timeout, self.timeout_cb)
    end
end
function States.Card:onCloseWidget()
    if self.timeout_cb then UIManager:unschedule(self.timeout_cb) end
end
function States.Card:onTapOutside(_arg, ges)
    if ges and ges.pos and ges.pos:intersectWith(self.dimen) then return true end
    self:onClose()
    if self.cancel_cb then self.cancel_cb() end
    return true
end
function States.Card:onClose()
    UIManager:close(self, "ui")
    return true
end
function States.Card:show()
    UIManager:show(self, "ui", self.dimen)
    return self
end

-- Shown over the library while the first open reads the books.
function States.loading()
    local card = States.Card:new{ build = function(w)
        return VerticalGroup:new{ align = "center",
            States.title(_("Loading annotations…"), 17, w, true),
            VerticalSpan:new{ width = Screen:scaleBySize(6) },
            States.lines(_("Reading your books. Only the first time after starting KOReader."),
                Font:getFace("cfont", 13), w, COLORS.muted, false, true),
        }
    end }
    card:show()
    UIManager:forceRePaint()
    return card
end

-- Delete confirmation: shows the highlight that will go, and says when its note goes too.
function States.confirmDelete(note, on_delete)
    local nw = NoteWrapper:new(note)
    local has_text = nw:hasHighlightedText()
    States.Card:new{ modal = true, build = function(w, card)
        local g = VerticalGroup:new{ align = "left" }
        table.insert(g, States.title(has_text and _("Delete this highlight?") or _("Delete this annotation?"), 17, w))
        if has_text then
            table.insert(g, VerticalSpan:new{ width = Screen:scaleBySize(10) })
            local drawer = note.drawer or "lighten"
            local no_fill = isNoBackgroundStyle(drawer)
            local fill
            if drawer == "invert" then fill = BlitBuffer.COLOR_BLACK
            elseif not no_fill then fill = getHighlightColor(note.color) end
            local face = select(3, getNoteFaces())
            local pad_h, pad_v, ob = Screen:scaleBySize(10), Screen:scaleBySize(8), Size.border.thin
            local lines = buildHighlightLines(cleanHighlightText(note.highlighted_text), face,
                w - (pad_h + ob) * 2, drawer, note.color, 2, true)
            table.insert(g, RoundedBox:new{ width = w, fill = fill or BlitBuffer.COLOR_WHITE,
                true_color = not no_fill and drawer ~= "invert",
                radius = Screen:scaleBySize(6), border = no_fill and ob or 0, border_color = COLORS.line,
                pad_x = pad_h + ob, pad_y = pad_v + ob, lines })
        end
        table.insert(g, VerticalSpan:new{ width = Screen:scaleBySize(10) })
        table.insert(g, States.lines(nw:hasUserNote()
            and _("Your note on it is deleted too. This can’t be undone.") or _("This can’t be undone."),
            Font:getFace("cfont", 13), w, COLORS.muted, false, false))
        table.insert(g, VerticalSpan:new{ width = Screen:scaleBySize(14) })
        local gap = Screen:scaleBySize(10)
        local bw = math.floor((w - gap) / 2)
        table.insert(g, HorizontalGroup:new{
            Page.button(_("Cancel"), false, bw, function() card:onClose() end),
            HorizontalSpan:new{ width = gap },
            Page.button(_("Delete"), true, w - gap - bw, function() card:onClose(); on_delete() end),
        })
        return g
    end }:show()
end

-- Export done: a note at the bottom that closes itself; the list under it stays usable.
function States.exported(count, path)
    local rel = path
    local ok, DataStorage = pcall(require, "datastorage")
    if ok then
        local dir = DataStorage:getDataDir()
        local name = dir:match("([^/\\]+)[/\\]*$")
        if not name or name == "." then name = "koreader" end
        if path:sub(1, #dir) == dir then rel = name .. path:sub(#dir + 1) end
    end
    States.Card:new{ anchor = "bottom", toast = true, timeout = 5, build = function(w)
        local icon_s = Screen:scaleBySize(18)
        local gap = Screen:scaleBySize(8)
        local title = count == 1 and _("Exported 1 annotation") or string.format(_("Exported %d annotations"), count)
        return VerticalGroup:new{ align = "left",
            HorizontalGroup:new{ align = "center",
                IconWidget:new{ icon = "check", width = icon_s, height = icon_s },
                HorizontalSpan:new{ width = gap },
                TextWidget:new{ text = title, face = Font:getFace("cfont", 15), bold = true, max_width = w - icon_s - gap } },
            VerticalSpan:new{ width = Screen:scaleBySize(6) },
            TextWidget:new{ text = rel, face = Font:getFace("cfont", 12), fgcolor = COLORS.muted, max_width = w },
        }
    end }:show()
end

-- The ☰ menu: a card under the button with an icon, a label and a short status on each row.
-- (Sort is on the tab row and in Filter & sort.)
function States.menu(list)
    local W = Screen:getWidth()
    local af = list.active_filter or {}
    local n_filters = #list:getFilterChips()
    local items = {
        { icon = "filter", label = _("Filter & sort"),
            value = n_filters == 0 and _("None active") or string.format(_("%d active"), n_filters),
            cb = function() list:showFilterMenu(false) end },
    }
    if not list.single_book then
        local seen, n_books = {}, 0
        for _i, n in ipairs(list.notes_list) do
            if n.book_title and not seen[n.book_title] then seen[n.book_title] = true; n_books = n_books + 1 end
        end
        local filtered = (af.books and next(af.books)) or (af.books_exclude and next(af.books_exclude))
        table.insert(items, { icon = "book.opened", label = _("Books"),
            value = filtered and _("Filtered") or string.format(_("All %d"), n_books),
            cb = function() list:showBookPicker(function() end) end })
    end
    table.insert(items, "line")
    table.insert(items, { icon = "move.up", label = _("Export to Markdown"),
        value = string.format(_("%d shown"), #(list.filtered_notes or {})), cb = function() list:exportToMarkdown() end })
    table.insert(items, { icon = "cre.render.reload", label = _("Reload annotations"),
        cb = function() list.viewer:reloadAnnotations(list) end })
    table.insert(items, "line")
    table.insert(items, { icon = "appbar.settings", label = _("Settings"), chevron = true,
        cb = function() list:showSettingsMenu() end })
    local bw = Size.border.window
    States.Card:new{ modal = true, width = math.min(Screen:scaleBySize(330), W - Screen:scaleBySize(20)),
        left = Screen:scaleBySize(10), top = TOPBAR_HEIGHT + Screen:scaleBySize(4),
        pad_h = bw, pad_v = bw + Screen:scaleBySize(6),
        build = function(w, card)
            local g = VerticalGroup:new{ align = "left" }
            local side, icon_s, gap = Screen:scaleBySize(16), Screen:scaleBySize(22), Screen:scaleBySize(14)
            for _i, it in ipairs(items) do
                if it == "line" then
                    table.insert(g, VerticalSpan:new{ width = Screen:scaleBySize(6) })
                    table.insert(g, HorizontalGroup:new{ HorizontalSpan:new{ width = side },
                        LineWidget:new{ dimen = Geom:new{ w = w - side * 2, h = Size.line.thin }, background = COLORS.line_light } })
                    table.insert(g, VerticalSpan:new{ width = Screen:scaleBySize(6) })
                else
                    local icon_file = it.icon == "filter" and pluginIcon("appbar.filter") or nil
                    local icon
                    if icon_file and lfs.attributes(icon_file, "mode") == "file" then
                        icon = IconWidget:new{ file = icon_file, width = icon_s, height = icon_s }
                    else
                        icon = IconWidget:new{ icon = it.icon == "filter" and "appbar.settings" or it.icon, width = icon_s, height = icon_s }
                    end
                    local value = it.value and TextWidget:new{ text = it.value, face = Font:getFace("cfont", 12),
                        fgcolor = COLORS.muted, max_width = math.floor(w * 0.35) }
                    local right = HorizontalGroup:new{ align = "center" }
                    if value then table.insert(right, value) end
                    if it.chevron then
                        table.insert(right, IconWidget:new{ icon = "chevron.right", width = Screen:scaleBySize(16), height = Screen:scaleBySize(16) })
                    end
                    table.insert(right, HorizontalSpan:new{ width = side })
                    local label_w = w - side - icon_s - gap - right:getSize().w - gap
                    local d = Geom:new{ w = w, h = Screen:scaleBySize(50) }
                    local cb = it.cb
                    table.insert(g, TapBox:new{ OverlapGroup:new{ dimen = d, allow_mirroring = false,
                        LeftContainer:new{ dimen = d, HorizontalGroup:new{ align = "center",
                            HorizontalSpan:new{ width = side }, icon, HorizontalSpan:new{ width = gap },
                            TextWidget:new{ text = it.label, face = Font:getFace("cfont", 15), max_width = label_w } } },
                        RightContainer:new{ dimen = d, right } },
                        callback = function() card:onClose(); cb() end })
                end
            end
            return g
        end }:show()
end

-- Sort order as a dropdown card under the sort label: one block per field (Date / Author / Book /
-- Filename), two columns (ascending | descending), ✓ on the current order.
function States.sortMenu(list, on_done)
    local W = Screen:getWidth()
    local current = getSetting("sort_mode", "date_newest")
    local short = {
        date_newest = _("Newest first"), date_oldest = _("Oldest first"),
        asc = _("A to Z · by date"), desc = _("Z to A · by date"),
        loc_asc = _("Begin to end"), loc_desc = _("End to begin"),
    }
    local blocks = {
        { _("Date"), { { "date_newest", short.date_newest }, { "date_oldest", short.date_oldest } } },
    }
    for _i, f in ipairs({ { "author", _("Author") }, { "book", _("Book") }, { "filename", _("Filename") } }) do
        table.insert(blocks, { f[2], {
            { f[1] .. "_asc", short.asc }, { f[1] .. "_desc", short.desc },
            { f[1] .. "_location_asc", short.loc_asc }, { f[1] .. "_location_desc", short.loc_desc } } })
    end
    local bw = Size.border.window
    States.Card:new{ modal = true, width = math.min(Screen:scaleBySize(340), W - Screen:scaleBySize(20)),
        left = W - math.min(Screen:scaleBySize(340), W - Screen:scaleBySize(20)) - Screen:scaleBySize(10),
        top = list.topbar_height + Screen:scaleBySize(4),
        pad_h = bw, pad_v = bw + Screen:scaleBySize(4),
        build = function(w, card)
            local g = VerticalGroup:new{ align = "left" }
            local side = Screen:scaleBySize(16)
            local cell_w = math.floor((w - side * 2) / 2)
            local cell_h = Screen:scaleBySize(40)
            for bi, blk in ipairs(blocks) do
                table.insert(g, VerticalSpan:new{ width = Screen:scaleBySize(bi == 1 and 6 or 10) })
                table.insert(g, HorizontalGroup:new{ HorizontalSpan:new{ width = side },
                    TextWidget:new{ text = blk[1]:upper(), face = Font:getFace("cfont", 11), bold = true, fgcolor = COLORS.muted } })
                table.insert(g, VerticalSpan:new{ width = Screen:scaleBySize(2) })
                local modes = blk[2]
                for i = 1, #modes, 2 do
                    local rowg = HorizontalGroup:new{ HorizontalSpan:new{ width = side } }
                    for k = i, math.min(i + 1, #modes) do
                        local mode, label = modes[k][1], modes[k][2]
                        local on = mode == current
                        table.insert(rowg, TapBox:new{
                            LeftContainer:new{ dimen = Geom:new{ w = cell_w, h = cell_h },
                                TextWidget:new{ text = (on and "✓ " or "") .. label, face = Font:getFace("cfont", 14),
                                    bold = on, max_width = cell_w - Screen:scaleBySize(6) } },
                            callback = function()
                                card:onClose()
                                setSetting("sort_mode", mode)
                                list:applySort()
                                list:refresh()
                                if on_done then on_done() end
                            end })
                    end
                    table.insert(g, rowg)
                end
            end
            table.insert(g, VerticalSpan:new{ width = Screen:scaleBySize(4) })
            return g
        end }:show()
end

-- Centre of the list when filters (or the tab) leave nothing: what happened, and one tap to undo.
function States.noMatch(list, width, height)
    local filtered = #list:getFilterChips() > 0
    local col_w = math.min(width, math.floor(Screen:getHeight() * 1.1)) - Screen:scaleBySize(22) * 2
    if #(list.notes_list or {}) == 0 then
        -- no annotations at all: the list's own title bar stays, the body explains
        local icon_s = Screen:scaleBySize(44)
        return CenterContainer:new{ dimen = Geom:new{ w = width, h = height }, VerticalGroup:new{ align = "center",
            IconWidget:new{ icon = "edit", width = icon_s, height = icon_s },
            VerticalSpan:new{ width = Screen:scaleBySize(12) },
            States.title(_("No annotations yet"), 18, col_w, true),
            VerticalSpan:new{ width = Screen:scaleBySize(10) },
            States.lines(list.single_book and _("Highlight a passage in this book and it shows up here.")
                or _("Highlight a passage in any book and it shows up here."),
                Font:getFace("cfont", 13), col_w, COLORS.muted, false, true),
        } }
    end
    local g = VerticalGroup:new{ align = "center",
        States.title(filtered and _("Nothing matches") or _("Nothing here"), 18, col_w, true),
        VerticalSpan:new{ width = Screen:scaleBySize(12) },
    }
    local hidden = #(list.notes_list or {})
    local body = _("No annotations in this view.")
    if filtered then
        body = _("No annotations fit these filters.") .. " "
            .. (hidden == 1 and _("1 is hidden.") or string.format(_("%d are hidden."), hidden))
    end
    table.insert(g, States.lines(body, Font:getFace("cfont", 13), col_w, COLORS.muted, false, true))
    if filtered then
        table.insert(g, VerticalSpan:new{ width = Screen:scaleBySize(14) })
        table.insert(g, Page.button(_("Clear filters"), true, Screen:scaleBySize(170), function() list:clearFilters() end))
    end
    return CenterContainer:new{ dimen = Geom:new{ w = width, h = height }, g }
end

end

local function deepCopy(t)
    if type(t) ~= "table" then return t end
    local c = {}
    for k, v in pairs(t) do c[k] = deepCopy(v) end
    return c
end
local SORT_CHOICES = {
    { "date_newest", _("Newest") }, { "date_oldest", _("Oldest") },
    { "book_asc", _("Book A–Z") }, { "author_asc", _("Author A–Z") },
    { "book_location_asc", _("Position in book") },
}
local FilterScreen = InputContainer:extend{ list = nil, helpers = nil, covers_fullscreen = true }
Page.watchResize(FilterScreen)
Page.forwardGestures(FilterScreen)
function FilterScreen:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.saved_filter = deepCopy(self.list.active_filter or {})
    self.saved_sort = getSetting("sort_mode", "date_newest")
    if Device:hasKeys() then self.key_events.Close = { { Input.group.Back } } end
    self:build()
end
function FilterScreen:rebuild()
    -- keep the scroll position when the page is rebuilt after a change
    local offset = self.scroller and self.scroller:getScrolledOffset()
    self:build()
    if offset and self.scroller then self.scroller:setScrolledOffset(offset) end
    UIManager:setDirty(self, "ui")
end
function FilterScreen:changed()
    self.list.current_page = 1
    self.list:refresh()
    self:rebuild()
end
function FilterScreen:build()
    local list = self.list
    list.active_filter = list.active_filter or {}
    local af = list.active_filter
    normalizeColorStyle(af)
    local W, H = Screen:getWidth(), Screen:getHeight()
    local P = Screen:scaleBySize(24)
    local inner = W - P * 2 - (self.narrow and Page.SCROLL_EXTRA or 0)
    local thin = Size.border.button
    local LIGHT = COLORS.line_light   -- row lines
    local MUTED = COLORS.muted
    local face15 = Font:getFace("cfont", 15)
    local face14 = Font:getFace("cfont", 14)
    local face13 = Font:getFace("cfont", 13)
    local function underlined(text, face)
        local tw = TextWidget:new{ text = text, face = face }
        return VerticalGroup:new{ tw, LineWidget:new{ dimen = Geom:new{ w = tw:getSize().w, h = Size.line.medium },
            background = BlitBuffer.COLOR_BLACK } }
    end
    local function rowLine()
        return HorizontalGroup:new{ HorizontalSpan:new{ width = P },
            LineWidget:new{ dimen = Geom:new{ w = inner, h = Size.line.thin }, background = COLORS.line_light } }
    end
    local function padded(widget, top, bottom)
        return VerticalGroup:new{ align = "left", VerticalSpan:new{ width = top or 0 },
            HorizontalGroup:new{ HorizontalSpan:new{ width = P }, widget }, VerticalSpan:new{ width = bottom or 0 } }
    end
    -- section title as in the mockup: small caps-style grey label with a black line under it
    local first_section = true
    local function sectionBar(text)
        local top = Screen:scaleBySize(first_section and 10 or 20)
        first_section = false
        local bar = VerticalGroup:new{ align = "left", VerticalSpan:new{ width = top },
            HorizontalGroup:new{ HorizontalSpan:new{ width = P }, VerticalGroup:new{ align = "left",
                TextWidget:new{ text = text, face = Font:getFace("cfont", 11), bold = true, fgcolor = COLORS.muted },
                VerticalSpan:new{ width = Screen:scaleBySize(6) },
                LineWidget:new{ dimen = Geom:new{ w = inner, h = Size.line.medium }, background = COLORS.ink } } } }
        bar.keep_with_next = true -- Page.paged never leaves a heading alone at the end of a page
        return bar
    end
    local function labelRow(left, right)
        local d = Geom:new{ w = inner, h = math.max(left:getSize().h, right and right:getSize().h or 0) }
        return OverlapGroup:new{ dimen = d, allow_mirroring = false,
            LeftContainer:new{ dimen = d, left }, right and RightContainer:new{ dimen = d, right } or nil }
    end
    -- chip: black with white bold text when on; white with a border when off. Width is
    -- always that of the "on" (bold) version so choosing never reflows the rows.
    local function chip(text, on, callback, opts)
        opts = opts or {}
        local h = opts.h or Screen:scaleBySize(34)
        local color = on and BlitBuffer.COLOR_WHITE or BlitBuffer.COLOR_BLACK
        local widest = TextWidget:new{ text = text, face = face13, bold = true }:getSize().w
        local tw = TextWidget:new{ text = text, face = face13, bold = on, fgcolor = color }
        local label = decoratedText(tw, opts.deco, color)
        local content = HorizontalGroup:new{ align = "center" }
        local extra = 0
        local dots = opts.dots or (opts.dot and { opts.dot }) or {}
        for _i, dname in ipairs(dots) do
            table.insert(content, Pill:new{ width = Screen:scaleBySize(12), height = Screen:scaleBySize(12), border = 0, true_color = true,
                fill = dname == "gray" and BlitBuffer.COLOR_GRAY or getHighlightColor(dname) })
            table.insert(content, HorizontalSpan:new{ width = Screen:scaleBySize(6) })
            extra = extra + Screen:scaleBySize(18)
        end
        table.insert(content, label)
        local w = widest + extra + Screen:scaleBySize(28)
        return { w = w, widget = TapBox:new{
            Pill:new{ width = w, height = h, fill = on and BlitBuffer.COLOR_BLACK or BlitBuffer.COLOR_WHITE,
                border = on and 0 or thin, border_color = COLORS.line, content },
            callback = callback, hold_callback = opts.hold,
        } }
    end
    local function flow(items, gap)
        gap = gap or Screen:scaleBySize(8)
        local rows = VerticalGroup:new{ align = "left" }
        local row, row_w = HorizontalGroup:new{}, 0
        for _i, it in ipairs(items) do
            if row_w > 0 and row_w + gap + it.w > inner then
                table.insert(rows, row); table.insert(rows, VerticalSpan:new{ width = gap })
                row, row_w = HorizontalGroup:new{}, 0
            end
            if row_w > 0 then table.insert(row, HorizontalSpan:new{ width = gap }); row_w = row_w + gap end
            table.insert(row, it.widget); row_w = row_w + it.w
        end
        if row_w > 0 then table.insert(rows, row) end
        return rows
    end
    local function setSummary(inc, exc, total)
        local n_inc, n_exc = 0, 0
        for _k in pairs(inc or {}) do n_inc = n_inc + 1 end
        for _k in pairs(exc or {}) do n_exc = n_exc + 1 end
        if n_inc == 0 and n_exc == 0 then return _("Any"), false end
        local parts = {}
        if n_inc > 0 then table.insert(parts, total and string.format(_("%d of %d"), n_inc, total) or string.format(_("%d chosen"), n_inc)) end
        if n_exc > 0 then table.insert(parts, string.format(_("%d hidden"), n_exc)) end
        return table.concat(parts, ", "), true
    end
    local function navRow(label, value, active, callback)
        local h = Screen:scaleBySize(50)
        local right = HorizontalGroup:new{ align = "center",
            TextWidget:new{ text = value, face = face15, bold = active, fgcolor = active and BlitBuffer.COLOR_BLACK or MUTED,
                max_width = math.floor(inner * 0.55) },
            HorizontalSpan:new{ width = Screen:scaleBySize(6) },
            IconWidget:new{ icon = "chevron.right", width = Screen:scaleBySize(16), height = Screen:scaleBySize(16) } }
        local d = Geom:new{ w = inner, h = h }
        return VerticalGroup:new{ align = "left",
            TapBox:new{ HorizontalGroup:new{ HorizontalSpan:new{ width = P },
                OverlapGroup:new{ dimen = d, allow_mirroring = false,
                    LeftContainer:new{ dimen = d, TextWidget:new{ text = label, face = face15 } },
                    RightContainer:new{ dimen = d, right } },
                HorizontalSpan:new{ width = P } }, callback = callback },
            rowLine(),
        }
    end

    local body = VerticalGroup:new{ align = "left" }
    table.insert(body, sectionBar(_("FILTER")))

    -- books / tags / chapters (the existing pickers: tap an item to show only it, again to hide it)
    local book_count
    do
        local seen = {}
        book_count = 0
        for _i, n in ipairs(list.notes_list) do
            if n.book_title and not seen[n.book_title] then seen[n.book_title] = true; book_count = book_count + 1 end
        end
    end
    if not list.single_book then
        local v, on = setSummary(af.books, af.books_exclude, book_count)
        table.insert(body, navRow(_("Books"), v, on, function() self.helpers.books() end))
    end
    do
        local v, on = setSummary(af.tags, af.tags_exclude)
        table.insert(body, navRow(_("Tags"), v, on, function() self.helpers.tags() end))
    end
    if self.helpers.chapters_available() then
        local v, on = setSummary(af.chapters, af.chapters_exclude)
        table.insert(body, navRow(_("Chapters"), v, on, function() self.helpers.chapters() end))
    end

    -- notes: All / With a note / Without (same as the tabs)
    do
        local seg = HorizontalGroup:new{}
        local cell_h = Screen:scaleBySize(40)
        local cell_w = math.floor((inner - thin * 2 - thin * 2) / 3)
        for i, opt in ipairs({ { nil, _("All") }, { "only", _("With a note") }, { "exclude", _("Without") } }) do
            local on = (af.notes_presence == opt[1])
            if i > 1 then table.insert(seg, LineWidget:new{ dimen = Geom:new{ w = thin, h = cell_h }, background = BlitBuffer.COLOR_BLACK }) end
            table.insert(seg, TapBox:new{
                FrameContainer:new{ bordersize = 0, padding = 0, margin = 0,
                    background = on and BlitBuffer.COLOR_BLACK or BlitBuffer.COLOR_WHITE,
                    CenterContainer:new{ dimen = Geom:new{ w = cell_w, h = cell_h },
                        TextWidget:new{ text = opt[2], face = face14, bold = on,
                            max_width = cell_w - Screen:scaleBySize(8),
                            fgcolor = on and BlitBuffer.COLOR_WHITE or BlitBuffer.COLOR_BLACK } } },
                callback = function()
                    if af.notes_presence ~= opt[1] then af.notes_presence = opt[1]; self:changed() end
                end,
            })
        end
        table.insert(body, padded(VerticalGroup:new{ align = "left",
            TextWidget:new{ text = _("Notes"), face = face15 },
            VerticalSpan:new{ width = Screen:scaleBySize(8) },
            RoundedOutline:new{ radius = Screen:scaleBySize(8), border = thin, seg },
        }, Screen:scaleBySize(14), Screen:scaleBySize(14)))
        table.insert(body, rowLine())
    end

    -- colour & style: chips for all colours and styles; "Hide these instead" flips
    -- between showing only these and hiding these
    do
        local items = {}
        -- setting: only offer colours/styles that some highlight uses (off = offer all)
        local only_used = getSetting("hide_unused_cs", false) == true
        local used = {}
        if only_used then
            for _i, n in ipairs(list.notes_list) do
                local nw = NoteWrapper:new(n)
                local c, d = nw:getNormalizedColor(), nw:getNormalizedDrawer()
                if c then used["color:" .. c] = true end
                if d then used["style:" .. d] = true end
            end
        end
        -- shown: all, or (setting) only used ones, plus whatever is currently chosen
        local function offered(key) return not only_used or used[key] or (af.cs and af.cs[key]) end
        local function toggle(key)
            af.cs = af.cs or {}
            if af.cs[key] then af.cs[key] = nil else af.cs[key] = true end
            if not next(af.cs) then af.cs, af.cs_exclude = nil, nil end
            self:changed()
        end
        for _i, hc in ipairs(ReaderHighlight.highlight_colors) do
            local key = "color:" .. hc[2]
            if offered(key) then
                table.insert(items, chip(hc[1], af.cs and af.cs[key], function() toggle(key) end, { dot = hc[2] }))
            end
        end
        for _i, st in ipairs(HIGHLIGHT_STYLES) do
            local key = "style:" .. st[1]
            if offered(key) then
                local deco = (st[1] == "underscore" and "underline") or (st[1] == "strikeout" and "strike") or nil
                table.insert(items, chip(st[2], af.cs and af.cs[key], function() toggle(key) end, { deco = deco }))
            end
        end
        local flip = TapBox:new{ underlined(af.cs_exclude and _("Show only these instead") or _("Hide these instead"), face13),
            callback = function()
                af.cs_exclude = not af.cs_exclude
                if af.cs and next(af.cs) then self:changed() else self:rebuild() end
            end }
        table.insert(body, padded(VerticalGroup:new{ align = "left",
            labelRow(TextWidget:new{ text = af.cs_exclude and _("Hide colour & style") or _("Colour & style"), face = face15 }, flip),
            VerticalSpan:new{ width = Screen:scaleBySize(8) },
            flow(items),
        }, Screen:scaleBySize(14), Screen:scaleBySize(14)))
        table.insert(body, rowLine())
    end

    -- text contains: the search box (highlights and notes); more text filters below it
    do
        local q = af.search_any
        local field_h = Screen:scaleBySize(42)
        local field_text = TextWidget:new{ text = (q and q ~= "") and q or _("Search highlights and notes"), face = face14,
            fgcolor = (q and q ~= "") and BlitBuffer.COLOR_BLACK or MUTED, max_width = inner - Screen:scaleBySize(24) }
        local field = TapBox:new{
            RoundedBox:new{ width = inner, radius = Screen:scaleBySize(8), border = thin, border_color = BlitBuffer.COLOR_BLACK,
                fill = BlitBuffer.COLOR_WHITE, pad_x = Screen:scaleBySize(12), pad_y = math.floor((field_h - field_text:getSize().h) / 2),
                field_text },
            callback = function() list:showSearchDialog(function() self:rebuild() end) end,
        }
        local more_active = false
        for _i, k in ipairs({ "search_highlight", "search_highlight_exclude", "search_note", "search_note_exclude" }) do
            if af[k] and af[k] ~= "" then more_active = true end
        end
        local more = TapBox:new{ underlined((more_active and "✓ " or "") .. _("More text filters"), face13),
            callback = function() self:showTextFilters() end }
        table.insert(body, padded(VerticalGroup:new{ align = "left",
            labelRow(TextWidget:new{ text = _("Text contains"), face = face15 }, more),
            VerticalSpan:new{ width = Screen:scaleBySize(8) },
            field,
        }, Screen:scaleBySize(14), Screen:scaleBySize(14)))
    end

    -- sort
    table.insert(body, sectionBar(_("SORT")))
    do
        local cur = getSetting("sort_mode", "date_newest")
        local items, known = {}, false
        local function apply(mode)
            setSetting("sort_mode", mode)
            list:applySort()
            self:changed()
        end
        for _i, sc in ipairs(SORT_CHOICES) do
            if sc[1] == cur then known = true end
            table.insert(items, chip(sc[2], sc[1] == cur, function() if sc[1] ~= cur then apply(sc[1]) end end, { h = Screen:scaleBySize(36) }))
        end
        -- all other orders (by author/file name, reversed, …) stay in the full sort list
        table.insert(items, chip(known and _("More…") or sortModeLabel(cur), not known,
            function() list:showSortMenu(false, function() self:rebuild() end) end, { h = Screen:scaleBySize(36) }))
        table.insert(body, padded(flow(items), Screen:scaleBySize(14), Screen:scaleBySize(14)))
    end

    -- saved filters: the current filters and sort order under a name, one tap to bring them back
    table.insert(body, sectionBar(_("SAVED FILTERS")))
    do
        local presets = getSetting("filter_presets", {})
        local function same(a, b)
            if type(a) ~= type(b) then return false end
            if type(a) ~= "table" then return a == b end
            for k, v in pairs(a) do if k ~= "notes_presence" and not same(v, b[k]) then return false end end
            for k in pairs(b) do if k ~= "notes_presence" and a[k] == nil then return false end end
            return true
        end
        local chips = {}
        for i, p in ipairs(presets) do
            local on = same(p.filter or {}, list.active_filter or {}) and (p.sort or "") == getSetting("sort_mode", "date_newest")
            table.insert(chips, chip(p.name, on, function()
                local presence = list.active_filter and list.active_filter.notes_presence
                list.active_filter = deepCopy(p.filter) or {}
                list.active_filter.notes_presence = presence
                if p.sort and p.sort ~= getSetting("sort_mode", "date_newest") then
                    setSetting("sort_mode", p.sort)
                    list:applySort()
                end
                self:changed()
            end, { hold = function()
                local ConfirmBox = require("ui/widget/confirmbox")
                NotesListWidget.showDialog(ConfirmBox:new{
                    text = string.format(_("Delete the saved filter “%s”?"), p.name),
                    ok_text = _("Delete"),
                    ok_callback = function()
                        table.remove(presets, i)
                        setSetting("filter_presets", presets)
                        self:rebuild()
                    end })
            end }))
        end
        if #presets == 0 then
            table.insert(body, padded(TextWidget:new{ text = _("Nothing saved yet."), face = face13, fgcolor = COLORS.muted },
                Screen:scaleBySize(12), Screen:scaleBySize(4)))
        else
            table.insert(body, padded(flow(chips), Screen:scaleBySize(14), Screen:scaleBySize(6)))
            table.insert(body, padded(TextWidget:new{ text = _("Hold one to delete it."), face = Font:getFace("cfont", 12), fgcolor = COLORS.muted },
                0, Screen:scaleBySize(4)))
        end
        local save_tw = TextWidget:new{ text = _("Save current filters…"), face = face13 }
        table.insert(body, padded(TapBox:new{ VerticalGroup:new{ save_tw, LineWidget:new{
                dimen = Geom:new{ w = save_tw:getSize().w, h = Size.line.medium }, background = BlitBuffer.COLOR_BLACK } },
            callback = function()
                local InputDialog = require("ui/widget/inputdialog")
                local dlg
                local function save()
                    local name = (dlg:getInputText() or ""):gsub("^%s+", ""):gsub("%s+$", "")
                    if name == "" then name = string.format(_("Filter %d"), #presets + 1) end
                    local copy = deepCopy(list.active_filter) or {}
                    copy.notes_presence = nil
                    table.insert(presets, { name = name, filter = copy, sort = getSetting("sort_mode", "date_newest") })
                    setSetting("filter_presets", presets)
                    UIManager:close(dlg)
                    self:rebuild()
                end
                dlg = InputDialog:new{ title = _("Save filters"), input = "", input_hint = _("Name"),
                    description = _("Saves the filters and sort order as they are now."),
                    buttons = {{
                        { text = _("Cancel"), id = "close", callback = function() UIManager:close(dlg) end },
                        { text = _("Save"), is_enter_default = true, callback = save } } } }
                NotesListWidget.showDialog(dlg)
                dlg:onShowKeyboard()
            end }, Screen:scaleBySize(14), Screen:scaleBySize(14)))
    end

    -- title bar and bottom bar, shared with the pickers
    local header = Page.header(self, _("Filter & sort"), function() self:onClose() end, {
        TapBox:new{ CenterContainer:new{ dimen = Geom:new{ w = Screen:scaleBySize(90), h = TOPBAR_HEIGHT }, underlined(_("Reset all"), face14) },
            callback = function()
                list.active_filter = {}
                self:changed()
            end },
    }, true)
    local footer = Page.footer(function() self:onClose() end, Page.countText(#(list.filtered_notes or {})),
        function() self:onDone() end)

    -- body scrolls when it doesn't fit (landscape, small screens)
    local avail = H - header:getSize().h - footer:getSize().h
    local body_widget = Page.paged(self, W, avail, body)
    self[1] = FrameContainer:new{ width = W, height = H, padding = 0, margin = 0, bordersize = 0,
        background = BlitBuffer.COLOR_WHITE,
        OverlapGroup:new{ dimen = Geom:new{ w = W, h = H }, allow_mirroring = false,
            VerticalGroup:new{ align = "left", header, body_widget },
            BottomContainer:new{ dimen = Geom:new{ w = W, h = H }, footer },
        },
    }
end
function FilterScreen:showTextFilters()
    local ButtonDialog = require("ui/widget/buttondialog")
    local af = self.list.active_filter or {}
    local dialog
    local function entry(field, is_exclude, label, title, hint)
        local key = is_exclude and (field .. "_exclude") or field
        local on = af[key] and af[key] ~= ""
        return { text = (on and "✓ " or "") .. label, callback = function()
            UIManager:close(dialog)
            self.helpers.text(field, title, hint, is_exclude)
        end }
    end
    dialog = ButtonDialog:new{
        title = _("Text filters"),
        buttons = {
            { entry("search_highlight", false, _("Highlight contains"), "Filter by Highlight Text", _("Words in highlighted text…")) },
            { entry("search_highlight", true, _("Highlight doesn't contain"), "Exclude by Highlight Text", _("Words in highlighted text…")) },
            { entry("search_note", false, _("Note contains"), "Filter by Note Text", _("Words in your notes…")) },
            { entry("search_note", true, _("Note doesn't contain"), "Exclude by Note Text", _("Words in your notes…")) },
            { { text = _("Close"), callback = function() UIManager:close(dialog) end } },
        },
    }
    NotesListWidget.showDialog(dialog)
end
function FilterScreen:onDone()
    self.list.filter_screen = nil
    UIManager:close(self, "flashui")
    return true
end
function FilterScreen:onClose()
    -- Cancel: put filters and sort back as they were
    self.list.active_filter = self.saved_filter
    if getSetting("sort_mode", "date_newest") ~= self.saved_sort then
        setSetting("sort_mode", self.saved_sort)
        self.list:applySort()
    end
    self.list:refresh()
    return self:onDone()
end
function NotesListWidget:showFilterScreen(helpers)
    if self.filter_screen then UIManager:close(self.filter_screen) end
    self.filter_screen = FilterScreen:new{ list = self, helpers = helpers }
    UIManager:show(self.filter_screen, "flashui")
end

-- Settings: one full-screen page (Text / List / Pages / Filter) instead of the chain of button
-- dialogs. Every setting is still here; changes apply straight away. The list-of-numbers
-- settings (font sizes, margins, spacing) and the typeface picker keep their own dialogs.
do -- own scope: keeps the main chunk under Lua's 200-locals limit
local SS = InputContainer:extend{ list = nil, page = nil, parent_screen = nil, covers_fullscreen = true }
Page.watchResize(SS)
Page.forwardGestures(SS)
NotesListWidget.SettingsScreen = SS
function SS:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    if Device:hasKeys() then self.key_events.Close = { { Input.group.Back } } end
    self:build()
end
function SS:rebuild()
    local offset = self.scroller and self.scroller:getScrolledOffset()
    self:build()
    if offset and self.scroller then self.scroller:setScrolledOffset(offset) end
    UIManager:setDirty(self, "ui")
end
-- a changed setting: redraw the list behind, then this page
function SS:changed()
    self.list:refresh()
    self:rebuild()
end
function SS:onClose()
    UIManager:close(self, "flashui")
    -- a sub page: the Settings page under it redraws with the new values
    if self.page and self.list.settings_screen then self.list.settings_screen:rebuild() end
    return true
end
function SS:onCloseWidget()
    if self.list.settings_screen == self then self.list.settings_screen = nil end
end
function SS:build()
    local W, H = Screen:getWidth(), Screen:getHeight()
    local P = Screen:scaleBySize(24)
    local inner = W - P * 2 - (self.narrow and Page.SCROLL_EXTRA or 0)
    local thin = Size.border.button
    local MUTED = COLORS.muted
    local face15, face13 = Font:getFace("cfont", 15), Font:getFace("cfont", 13)
    local face12 = Font:getFace("cfont", 12)
    local function rowLine()
        return HorizontalGroup:new{ HorizontalSpan:new{ width = P },
            LineWidget:new{ dimen = Geom:new{ w = inner, h = Size.line.thin }, background = COLORS.line_light } }
    end
    -- section title as in the mockup: small caps-style grey label with a black line under it
    local first_section = true
    local function sectionBar(text)
        local top = Screen:scaleBySize(first_section and 10 or 20)
        first_section = false
        local bar = VerticalGroup:new{ align = "left", VerticalSpan:new{ width = top },
            HorizontalGroup:new{ HorizontalSpan:new{ width = P }, VerticalGroup:new{ align = "left",
                TextWidget:new{ text = text, face = Font:getFace("cfont", 11), bold = true, fgcolor = COLORS.muted },
                VerticalSpan:new{ width = Screen:scaleBySize(6) },
                LineWidget:new{ dimen = Geom:new{ w = inner, h = Size.line.medium }, background = COLORS.ink } } } }
        bar.keep_with_next = true -- Page.paged never leaves a heading alone at the end of a page
        return bar
    end
    local function padded(widget, top, bottom)
        return VerticalGroup:new{ align = "left", VerticalSpan:new{ width = top or 0 },
            HorizontalGroup:new{ HorizontalSpan:new{ width = P }, widget }, VerticalSpan:new{ width = bottom or 0 } }
    end
    -- label (with an optional grey line under it) on the left, a control on the right
    local function row(label, sub, control, callback)
        local ctl_w = control and control:getSize().w or 0
        local left = TextWidget:new{ text = label, face = face15, max_width = inner - ctl_w - Screen:scaleBySize(12) }
        if sub then
            left = VerticalGroup:new{ align = "left", left, VerticalSpan:new{ width = Screen:scaleBySize(2) },
                TextWidget:new{ text = sub, face = face12, fgcolor = MUTED, max_width = inner - ctl_w - Screen:scaleBySize(12) } }
        end
        local d = Geom:new{ w = inner, h = Screen:scaleBySize(sub and 58 or 50) }
        local line = HorizontalGroup:new{ HorizontalSpan:new{ width = P },
            OverlapGroup:new{ dimen = d, allow_mirroring = false,
                LeftContainer:new{ dimen = d, left },
                control and RightContainer:new{ dimen = d, control } or nil },
            HorizontalSpan:new{ width = P } }
        return VerticalGroup:new{ align = "left", callback and TapBox:new{ line, callback = callback } or line, rowLine() }
    end
    local function navRow(label, value, callback)
        local right = HorizontalGroup:new{ align = "center" }
        if value and value ~= "" then
            table.insert(right, TextWidget:new{ text = value, face = face15, fgcolor = MUTED, max_width = math.floor(inner * 0.5) })
            table.insert(right, HorizontalSpan:new{ width = Screen:scaleBySize(6) })
        end
        table.insert(right, IconWidget:new{ icon = "chevron.right", width = Screen:scaleBySize(16), height = Screen:scaleBySize(16) })
        return row(label, nil, right, callback)
    end
    -- on/off switch: black track with a white knob on the right when on
    local function toggle(label, sub, key, getter)
        local on = getter() == true
        local sw_w, sw_h, knob, m = Screen:scaleBySize(50), Screen:scaleBySize(28), Screen:scaleBySize(20), Screen:scaleBySize(4)
        local track = Pill:new{ width = sw_w, height = sw_h, fill = on and BlitBuffer.COLOR_BLACK or BlitBuffer.COLOR_WHITE,
            border = on and 0 or thin, border_color = BlitBuffer.COLOR_BLACK }
        local k = Pill:new{ width = knob, height = knob, border = 0, fill = on and BlitBuffer.COLOR_WHITE or BlitBuffer.COLOR_BLACK }
        k.overlap_offset = { on and (sw_w - knob - m) or m, math.floor((sw_h - knob) / 2) }
        local sw = OverlapGroup:new{ dimen = Geom:new{ w = sw_w, h = sw_h }, allow_mirroring = false, track, k }
        return row(label, sub, sw, function() setSetting(key, not on); self:changed() end)
    end
    local function outlineCells(cells, cell_h)
        local seg = HorizontalGroup:new{}
        for i, c in ipairs(cells) do
            if i > 1 then table.insert(seg, LineWidget:new{ dimen = Geom:new{ w = thin, h = cell_h }, background = BlitBuffer.COLOR_BLACK }) end
            table.insert(seg, c)
        end
        return RoundedOutline:new{ radius = Screen:scaleBySize(8), border = thin, seg }
    end
    -- step/default given: the number can be tapped to open the number dialog (type a value)
    local function stepper(label, sub, key, value, min, max, step, default)
        step = step or 1
        local h = Screen:scaleBySize(36)
        local function cell(text, w, cb, bold)
            return TapBox:new{ CenterContainer:new{ dimen = Geom:new{ w = w, h = h },
                TextWidget:new{ text = text, face = face15, bold = bold } }, callback = cb }
        end
        local function set(v) v = math.max(min, math.min(max, v)); if v ~= value then setSetting(key, v); self:changed() end end
        local ctl = outlineCells({ cell("−", Screen:scaleBySize(44), function() set(value - step) end),
            cell(tostring(value), Screen:scaleBySize(48), default and function()
                self.list:showSpinSetting(label, key, default, min, max, step, function() self:rebuild() end)
            end or nil, true),
            cell("+", Screen:scaleBySize(44), function() set(value + step) end) }, h)
        return row(label, sub, ctl)
    end
    -- options side by side in one rounded outline, the chosen one black
    local function segment(label, options, current, pick)
        local n = #options
        local cell_h = Screen:scaleBySize(40)
        local cell_w = math.floor((inner - thin * 2 - thin * (n - 1)) / n)
        local cells = {}
        for _i, opt in ipairs(options) do
            local on = (current == opt[1])
            table.insert(cells, TapBox:new{
                FrameContainer:new{ bordersize = 0, padding = 0, margin = 0,
                    background = on and BlitBuffer.COLOR_BLACK or BlitBuffer.COLOR_WHITE,
                    CenterContainer:new{ dimen = Geom:new{ w = cell_w, h = cell_h },
                        TextWidget:new{ text = opt[2], face = face13, bold = on,
                            max_width = cell_w - Screen:scaleBySize(8),
                            fgcolor = on and BlitBuffer.COLOR_WHITE or BlitBuffer.COLOR_BLACK } } },
                callback = function() if not on then pick(opt[1]) end end })
        end
        return VerticalGroup:new{ align = "left",
            padded(VerticalGroup:new{ align = "left", TextWidget:new{ text = label, face = face15 },
                VerticalSpan:new{ width = Screen:scaleBySize(8) }, outlineCells(cells, cell_h) },
                Screen:scaleBySize(12), Screen:scaleBySize(14)),
            rowLine() }
    end
    -- which of date / author / chapter are on: small chips on the right (black when on)
    local function fieldChips(label, sub, getter, key)
        local active = {}
        for f in getter():gmatch("[^,]+") do active[f] = true end
        local chips = HorizontalGroup:new{ align = "center" }
        for i, f in ipairs({ { "date", _("Date") }, { "author", _("Author") }, { "chapter", _("Chapter") } }) do
            local on = active[f[1]]
            local text = f[2]
            local widest = TextWidget:new{ text = f[2], face = face13, bold = true }:getSize().w
            local w = widest + Screen:scaleBySize(20)
            local color = on and BlitBuffer.COLOR_WHITE or BlitBuffer.COLOR_BLACK
            if i > 1 then table.insert(chips, HorizontalSpan:new{ width = Screen:scaleBySize(6) }) end
            table.insert(chips, TapBox:new{
                Pill:new{ width = w, height = Screen:scaleBySize(32), fill = on and BlitBuffer.COLOR_BLACK or BlitBuffer.COLOR_WHITE,
                    border = on and 0 or thin, border_color = COLORS.line,
                    TextWidget:new{ text = text, face = face13, bold = on, fgcolor = color } },
                callback = function()
                    if on then active[f[1]] = nil else active[f[1]] = true end
                    local parts = {}
                    for _j, k in ipairs({ "date", "author", "chapter" }) do if active[k] then table.insert(parts, k) end end
                    setSetting(key, #parts > 0 and table.concat(parts, ",") or "date")
                    self:changed()
                end })
        end
        return row(label, sub, chips)
    end
    local list = self.list
    local function back() self:rebuild() end

    local body = VerticalGroup:new{ align = "left" }
    local function add(w) table.insert(body, w) end

    local function fontRow(label, key, getter)
        return navRow(label, NotesListWidget.SubPage.fontName(getter()), function()
            UIManager:show(NotesListWidget.SubPage:new{ list = list, parent = self, font_key = key, title = label })
        end)
    end
    local function numberRows(menu_key)
        for _i, st in ipairs(SPIN_MENUS[menu_key].settings) do
            add(stepper((st.label:gsub(":%s*$", "")), nil, st.key, st.getter(), st.min, st.max, st.step, st.default))
        end
    end
    if self.page == "text" then
        add(sectionBar(_("FONTS")))
        add(fontRow(_("Title font"), "title_font", getTitleFont))
        add(fontRow(_("Info font"), "info_font", getInfoFont))
        add(fontRow(_("Content font"), "content_font", getContentFont))
        add(navRow(_("Note font"), getSetting("note_font", nil) and NotesListWidget.SubPage.fontName(getSetting("note_font", nil))
                or _("Same as content"), function()
            UIManager:show(NotesListWidget.SubPage:new{ list = list, parent = self, font_key = "note_font", title = _("Note font") })
        end))
        add(sectionBar(_("SIZES")))
        numberRows("font_size")
        local content_size = getContentFontSize()
        add(stepper(_("Note size"), _("Same as the content size until you change it"), "note_font_size",
            getSetting("note_font_size", nil) or content_size, 8, 48, 1, content_size))
        add(stepper(_("Lines per highlight"), _("Longer ones end with “…”; tap to read all"), "truncate_lines", getTruncateLines(), 1, 20))
        add(stepper(_("Lines per note"), _("Longer notes end with “…”; tap to read all"), "truncate_note_lines", NoteItemWidget.noteLinesMax(), 1, 20))
        add(toggle(_("Justify text"), nil, "justify", getJustify))
    elseif self.page == "spacing" then
        -- grouped by where the space is, in the order an annotation is drawn: page, between annotations,
        -- the heading, the highlight text, the note
        local function rowsFor(keys)
            local by_key = {}
            for _, menu in ipairs({ "margins", "section_margin" }) do
                for _, st in ipairs(SPIN_MENUS[menu].settings) do by_key[st.key] = st end
            end
            for _, key in ipairs(keys) do
                local st = by_key[key]
                add(stepper((st.label:gsub(":%s*$", "")), nil, st.key, st.getter(), st.min, st.max, st.step, st.default))
            end
        end
        add(sectionBar(_("PAGE")))
        rowsFor({ "top_padding", "h_margin", "landscape_width_pct" })
        add(sectionBar(_("BETWEEN ANNOTATIONS")))
        rowsFor({ "note_spacing" })
        add(sectionBar(_("BOOK HEADING")))
        rowsFor({ "title_margin", "info_margin" })
        add(sectionBar(_("HIGHLIGHT TEXT")))
        rowsFor({ "text_margin", "line_spacing" })
        add(sectionBar(_("YOUR NOTE")))
        rowsFor({ "note_offset", "note_indent" })
    elseif self.page == "info" then
        add(sectionBar(_("INFO ROW")))
        add(toggle(_("Show book / info row"), nil, "show_info", getShowInfo))
        add(fieldChips(_("Info row shows"), nil, getInfoFields, "info_fields"))
        add(toggle(_("Title on each page"), nil, "repeat_title_on_page", getRepeatTitleOnPage))
        add(toggle(_("Chapter headings in one book"), _("Heading above each chapter when you open a single book"), "chapter_headings", NoteItemWidget.showHeadings))
        add(toggle(_("Chapter heading on each page"), nil, "repeat_chapter_on_page", NoteItemWidget.repeatChapter))
        add(toggle(_("Chapter / date on each page"), nil, "repeat_info_on_page", getRepeatInfoOnPage))
        add(toggle(_("Hide duplicate book header"), nil, "hide_dup_title", getHideDupTitle))
        add(toggle(_("Hide duplicate info header"), nil, "hide_dup_info", getHideDupInfo))
        add(fieldChips(_("Duplicate check"), _("Repeated info is hidden when these match"), getDedupInfoFields, "dedup_info_fields"))
    else
        add(sectionBar(_("LIST")))
        add(navRow(_("Text"), string.format("%d · %d · %d", getTitleFontSize(), getInfoFontSize(), getContentFontSize()),
            function() UIManager:show(SS:new{ list = list, page = "text", parent_screen = self }, "flashui") end))
        add(navRow(_("Spacing"), string.format("%d · %d", getSetting("h_margin", DEFAULT_H_MARGIN), getSetting("note_spacing", DEFAULT_NOTE_SPACING)),
            function() UIManager:show(SS:new{ list = list, page = "spacing", parent_screen = self }, "flashui") end))
        do
            local names = {}
            local active = {}
            for f in getInfoFields():gmatch("[^,]+") do active[f] = true end
            for _i, f in ipairs({ { "date", _("Date") }, { "author", _("Author") }, { "chapter", _("Chapter") } }) do
                if active[f[1]] then table.insert(names, f[2]) end
            end
            add(navRow(_("Info row and repeats"), getShowInfo() and table.concat(names, " · ") or _("Off"),
                function() UIManager:show(SS:new{ list = list, page = "info", parent_screen = self }, "flashui") end))
        end
        add(toggle(_("Counts on tabs"), nil, "show_total", getShowTotalNotes))
        add(toggle(_("Filter button in title bar"), nil, "filter_titlebar_btn", getFilterTitlebarBtn))

        add(sectionBar(_("PAGES")))
        add(segment(_("Page controls"), { { "default", _("Prev / Next") }, { "scrollbar", _("Scrollbar") },
            { "scrollbar_chevrons", _("Scrollbar + buttons") } }, getPaginationStyle(),
            function(v) setSetting("pagination_style", v); self:changed() end))
        add(toggle(_("Marks on the scrollbar"), _("Where a new book, author, month or chapter starts, by sort order"), "sb_book_marks", getScrollbarBookMarks))
        add(segment(_("Swipe to turn pages"), { { "both", _("Both") }, { "horizontal", _("Horizontal") },
            { "vertical", _("Vertical") }, { "disabled", _("Off") } }, getSwipeSetting(),
            function(v) setSetting("swipe_direction", v); self:changed() end))

        add(sectionBar(_("FILTER")))
        add(toggle(_("Only offer used colours and styles"), nil, "hide_unused_cs",
            function() return getSetting("hide_unused_cs", false) == true end))
    end

    local titles = { text = _("Text"), spacing = _("Spacing"), info = _("Info row and repeats") }
    local right_items
    if self.page == "text" or self.page == "spacing" then
        local keys = self.page == "text" and { "font_size" } or { "margins", "section_margin" }
        right_items = { TapBox:new{ CenterContainer:new{ dimen = Geom:new{ w = Screen:scaleBySize(90), h = TOPBAR_HEIGHT },
                (function()
                    local tw = TextWidget:new{ text = _("Reset"), face = Font:getFace("cfont", 14) }
                    return VerticalGroup:new{ tw, LineWidget:new{ dimen = Geom:new{ w = tw:getSize().w, h = Size.line.medium },
                        background = BlitBuffer.COLOR_BLACK } }
                end)() },
            callback = function()
                for _i, key in ipairs(keys) do
                    for _j, st in ipairs(SPIN_MENUS[key].settings) do setSetting(st.key, st.default) end
                end
                if self.page == "text" then
                    setSetting("title_font", nil); setSetting("info_font", nil); setSetting("content_font", nil)
                    setSetting("note_font", nil); setSetting("note_font_size", nil)
                    setSetting("truncate_lines", DEFAULT_TRUNCATE_LINES); setSetting("truncate_note_lines", NoteItemWidget.DEFAULT_NOTE_LINES); setSetting("justify", false)
                end
                self:changed()
            end } }
    end
    local header = Page.header(self, titles[self.page] or _("Settings"), function() self:onClose() end, right_items,
        not self.page, function() Page.exitAll(self) end)
    local top_group = VerticalGroup:new{ align = "left", header }
    if self.page == "text" or self.page == "spacing" then
        table.insert(top_group, Page.preview(self.list, math.floor(H * 0.26), self.page == "spacing"))
    end
    local avail = H - top_group:getSize().h
    local body_widget = Page.paged(self, W, avail, body)
    self[1] = FrameContainer:new{ width = W, height = H, padding = 0, margin = 0, bordersize = 0,
        background = BlitBuffer.COLOR_WHITE,
        VerticalGroup:new{ align = "left", top_group, body_widget } }
end
end

-- Font list behind the three font rows of Settings: a sample line in the chosen font on top
-- (fixed height, so the page does not jump between fonts), then every font to tap.
do -- own scope: keeps the main chunk under Lua's 200-locals limit
NotesListWidget.SubPage = InputContainer:extend{ list = nil, parent = nil, font_key = nil, title = "", covers_fullscreen = true }
Page.watchResize(NotesListWidget.SubPage)
Page.forwardGestures(NotesListWidget.SubPage)
function NotesListWidget.SubPage:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    if Device:hasKeys() then self.key_events.Close = { { Input.group.Back } } end
    self:build()
end
function NotesListWidget.SubPage:rebuild()
    local offset = self.scroller and self.scroller:getScrolledOffset()
    self:build()
    if offset and self.scroller then self.scroller:setScrolledOffset(offset) end
    UIManager:setDirty(self, "ui")
end
function NotesListWidget.SubPage:onClose()
    UIManager:close(self, "flashui")
    if self.parent then self.parent:rebuild() end -- the page with the font rows shows the new name
    self.list:showSettingsMenu()
    return true
end
function NotesListWidget.SubPage.fontName(path)
    if not path or path == "" then return _("Default") end
    return path:match("([^/\\]+)$") or path
end
function NotesListWidget.SubPage:build()
    local list = self.list
    local W, H = Screen:getWidth(), Screen:getHeight()
    local P = Screen:scaleBySize(24)
    local inner = W - P * 2
    local face15 = Font:getFace("cfont", 15)
    local function rowLine()
        return HorizontalGroup:new{ HorizontalSpan:new{ width = P },
            LineWidget:new{ dimen = Geom:new{ w = inner, h = Size.line.thin }, background = COLORS.line_light } }
    end
    local current = getSetting(self.font_key, nil)
    local body = VerticalGroup:new{ align = "left" }
    local box_h = Screen:scaleBySize(64)
    local sample = TextWidget:new{ text = _("The quick brown fox jumps over the lazy dog."),
        face = getFaceOr(current, 20, "cfont"), max_width = inner - Screen:scaleBySize(28) }
    table.insert(body, VerticalSpan:new{ width = Screen:scaleBySize(14) })
    table.insert(body, HorizontalGroup:new{ HorizontalSpan:new{ width = P },
        RoundedBox:new{ width = inner, radius = Screen:scaleBySize(8), border = Size.border.button, border_color = COLORS.line,
            fill = BlitBuffer.COLOR_WHITE, pad_x = 0, pad_y = 0,
            CenterContainer:new{ dimen = Geom:new{ w = inner, h = box_h }, sample } } })
    table.insert(body, VerticalSpan:new{ width = Screen:scaleBySize(14) })
    table.insert(body, rowLine())
    local fonts, seen = {}, {}
    for _i, font_path in ipairs(FontList:getFontList()) do
        local name = font_path:match("([^/\\]+)$") or font_path
        if not seen[name] then seen[name] = true; table.insert(fonts, { name = name, path = font_path }) end
    end
    table.sort(fonts, function(a, b) return a.name:lower() < b.name:lower() end)
    table.insert(fonts, 1, { name = _("Default"), path = nil })
    for _i, f in ipairs(fonts) do
        local on = (f.path == nil and (current == nil or current == "")) or (f.path ~= nil and current == f.path)
        local d = Geom:new{ w = inner, h = Screen:scaleBySize(46) }
        local mark = on and TextWidget:new{ text = "✓", face = Font:getFace("cfont", 17), bold = true } or nil
        local line = HorizontalGroup:new{ HorizontalSpan:new{ width = P },
            OverlapGroup:new{ dimen = d, allow_mirroring = false,
                LeftContainer:new{ dimen = d, TextWidget:new{ text = f.name, face = face15, bold = on, max_width = inner - Screen:scaleBySize(40) } },
                mark and RightContainer:new{ dimen = d, mark } or nil },
            HorizontalSpan:new{ width = P } }
        table.insert(body, VerticalGroup:new{ align = "left", TapBox:new{ line, callback = function()
            setSetting(self.font_key, f.path)
            list:refresh(); self:rebuild()
        end }, rowLine() })
    end
    local header = Page.header(self, self.title, function() self:onClose() end, nil, false, function()
        Page.exitAll(self); self.list:refresh()
    end)
    local avail = H - header:getSize().h
    local body_widget = Page.paged(self, W, avail, body, { fixed = 4 })
    self[1] = FrameContainer:new{ width = W, height = H, padding = 0, margin = 0, bordersize = 0,
        background = BlitBuffer.COLOR_WHITE,
        VerticalGroup:new{ align = "left", header, body_widget } }
end
end

-- Full-screen picker for Books, Chapters and Tags (BookFilter / ChapterFilter boards).
-- Books, Chapters and Tags: the same "Only these" / "Hide these" switch and checkboxes. A tap marks
-- an item with the switch's side (✓ only, ✕ hide) or clears it.
-- Changes count live ("Show N annotations"); Cancel / ‹ / ✕ put the filter back.
local ListPicker = InputContainer:extend{
    list = nil, title = "", items = nil, inc_key = nil, exc_key = nil,
    mode_labels = nil, search_hint = nil, on_done = nil,
    covers_fullscreen = true,
}
Page.watchResize(ListPicker)
Page.forwardGestures(ListPicker)
function ListPicker:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    local af = self.list.active_filter or {}
    self.list.active_filter = af
    self.saved_inc = deepCopy(af[self.inc_key])
    self.saved_exc = deepCopy(af[self.exc_key])
    self.query = ""
    -- the side a tap marks: the one already in use ("only" when both are)
    self.mode = (af[self.inc_key] and next(af[self.inc_key])) and "inc"
        or ((af[self.exc_key] and next(af[self.exc_key])) and "exc" or "inc")
    if Device:hasKeys() then self.key_events.Close = { { Input.group.Back } } end
    self:build()
end
function ListPicker:state(key)
    local af = self.list.active_filter
    if af[self.inc_key] and af[self.inc_key][key] then return "inc" end
    if af[self.exc_key] and af[self.exc_key][key] then return "exc" end
    return nil
end
function ListPicker:set(key, st)
    local af = self.list.active_filter
    for _i, k in ipairs({ self.inc_key, self.exc_key }) do
        if af[k] then af[k][key] = nil; if not next(af[k]) then af[k] = nil end end
    end
    if st then
        local k = (st == "inc") and self.inc_key or self.exc_key
        af[k] = af[k] or {}
        af[k][key] = true
    end
end
function ListPicker:changed()
    self.list:applyFilter() -- count only; the list is redrawn when the picker closes
    local offset = self.scroller and self.scroller:getScrolledOffset()
    self:build()
    if offset and self.scroller then self.scroller:setScrolledOffset(offset) end
    UIManager:setDirty(self, "ui")
end
function ListPicker:visibleItems()
    if self.query == "" then return self.items end
    local q = self.query:lower()
    local out = {}
    for _i, it in ipairs(self.items) do
        if ((it.title or "") .. " " .. (it.subtitle or "")):lower():find(q, 1, true) then table.insert(out, it) end
    end
    return out
end
function ListPicker:build()
    local W, H = Screen:getWidth(), Screen:getHeight()
    local P = Screen:scaleBySize(24)
    local inner = W - P * 2
    local thin = Size.border.button
    local face13, face14, face15 = Font:getFace("cfont", 13), Font:getFace("cfont", 14), Font:getFace("cfont", 15)
    local function underlined(text)
        local tw = TextWidget:new{ text = text, face = face13 }
        return VerticalGroup:new{ tw, LineWidget:new{ dimen = Geom:new{ w = tw:getSize().w, h = Size.line.medium }, background = COLORS.ink } }
    end
    local visible = self:visibleItems()

    local header = Page.header(self, self.title, function() self:onClose() end, nil, false, function()
        self:onClose()
        if self.list.filter_screen then self.list.filter_screen:onClose() end
    end)

    -- controls: mode switch, search, "N of M selected", Select all / Clear
    local controls = VerticalGroup:new{ align = "left" }
    do
        local seg = HorizontalGroup:new{}
        local cell_h = Screen:scaleBySize(40)
        local cell_w = math.floor((inner - thin * 3) / 2)
        for i, m in ipairs({ { "inc", self.mode_labels[1] }, { "exc", self.mode_labels[2] } }) do
            local on = (self.mode == m[1])
            if i > 1 then table.insert(seg, LineWidget:new{ dimen = Geom:new{ w = thin, h = cell_h }, background = COLORS.ink }) end
            table.insert(seg, TapBox:new{
                FrameContainer:new{ bordersize = 0, padding = 0, margin = 0, background = on and COLORS.ink or BlitBuffer.COLOR_WHITE,
                    CenterContainer:new{ dimen = Geom:new{ w = cell_w, h = cell_h },
                        TextWidget:new{ text = m[2], face = face14, bold = on, max_width = cell_w - Screen:scaleBySize(8),
                            fgcolor = on and BlitBuffer.COLOR_WHITE or COLORS.ink } } },
                callback = function()
                    if self.mode == m[1] then return end
                    -- everything chosen moves to the other side, unless both sides are in use
                    -- (then only what a tap marks changes)
                    local chosen, mixed = {}, false
                    for _i, it in ipairs(self.items) do
                        local st = self:state(it.key)
                        if st then table.insert(chosen, it.key); if st ~= self.mode then mixed = true end end
                    end
                    self.mode = m[1]
                    if not mixed then for _i, key in ipairs(chosen) do self:set(key, m[1]) end end
                    self:changed()
                end,
            })
        end
        table.insert(controls, RoundedOutline:new{ radius = Screen:scaleBySize(8), border = thin, seg })
        table.insert(controls, VerticalSpan:new{ width = Screen:scaleBySize(12) })
    end
    if self.search_hint then
        local has_q = self.query ~= ""
        local qtext = TextWidget:new{ text = has_q and self.query or self.search_hint, face = face14,
            fgcolor = has_q and COLORS.ink or COLORS.muted, max_width = inner - Screen:scaleBySize(60) }
        local field_h = Screen:scaleBySize(42)
        table.insert(controls, TapBox:new{
            RoundedBox:new{ width = inner, radius = Screen:scaleBySize(8), border = thin, border_color = COLORS.line,
                fill = BlitBuffer.COLOR_WHITE, pad_x = Screen:scaleBySize(12), pad_y = math.floor((field_h - qtext:getSize().h) / 2),
                HorizontalGroup:new{ align = "center",
                    IconWidget:new{ icon = "appbar.search", width = Screen:scaleBySize(18), height = Screen:scaleBySize(18) },
                    HorizontalSpan:new{ width = Screen:scaleBySize(8) }, qtext } },
            callback = function() self:askQuery() end,
        })
        table.insert(controls, VerticalSpan:new{ width = Screen:scaleBySize(10) })
    end
    local n_sel = 0
    for _i, it in ipairs(self.items) do if self:state(it.key) then n_sel = n_sel + 1 end end
    local d = Geom:new{ w = inner, h = Screen:scaleBySize(32) }
    local links = HorizontalGroup:new{ align = "center" }
    table.insert(links, TapBox:new{ underlined(_("Select all")), callback = function()
        for _i, it in ipairs(visible) do self:set(it.key, self.mode) end
        self:changed()
    end })
    table.insert(links, HorizontalSpan:new{ width = Screen:scaleBySize(18) })
    table.insert(links, TapBox:new{ underlined(_("Clear")), callback = function()
        for _i, it in ipairs(self.items) do self:set(it.key, nil) end
        self:changed()
    end })
    table.insert(controls, OverlapGroup:new{ dimen = d, allow_mirroring = false,
        LeftContainer:new{ dimen = d, TextWidget:new{ text = string.format(_("%d of %d selected"), n_sel, #self.items),
            face = face13, fgcolor = COLORS.muted } },
        RightContainer:new{ dimen = d, links } })
    local top = VerticalGroup:new{ align = "left", header,
        HorizontalGroup:new{ HorizontalSpan:new{ width = P }, VerticalGroup:new{ align = "left",
            -- same space above the switch as between the switch and the search field
            VerticalSpan:new{ width = Screen:scaleBySize(12) }, controls,
            VerticalSpan:new{ width = Screen:scaleBySize(6) } } },
        LineWidget:new{ dimen = Geom:new{ w = W, h = Size.line.thin }, background = COLORS.line } }

    -- rows (grouped when items have a group, e.g. chapters by book)
    local rinner = inner - (self.narrow and Page.SCROLL_EXTRA or 0)
    local rows = VerticalGroup:new{ align = "left" }
    local box = Screen:scaleBySize(24)
    local last_group
    for _i, it in ipairs(visible) do
        if it.group and it.group ~= last_group then
            last_group = it.group
            local gd = Geom:new{ w = rinner, h = Screen:scaleBySize(40) }
            local group_name = it.group
            table.insert(rows, OverlapGroup:new{ dimen = gd, allow_mirroring = false,
                LeftContainer:new{ dimen = gd, TextWidget:new{ text = group_name, face = getFaceOr(SERIF_FONT, 17, "cfont"), bold = true,
                    max_width = rinner - Screen:scaleBySize(60) } },
                RightContainer:new{ dimen = gd, TapBox:new{ underlined(_("All")), callback = function()
                    for _j, x in ipairs(self.items) do if x.group == group_name then self:set(x.key, self.mode or "inc") end end
                    self:changed()
                end } } })
            table.insert(rows, LineWidget:new{ dimen = Geom:new{ w = rinner, h = Size.line.thin }, background = COLORS.line_light })
        end
        local st = self:state(it.key)
        local mark
        if st == "exc" then
            mark = RoundedBox:new{ width = box, radius = Screen:scaleBySize(5), fill = COLORS.ink, pad_x = 0, pad_y = 0,
                CenterContainer:new{ dimen = Geom:new{ w = box, h = box },
                    Page.TextMark:new{ icon = "close", size = Screen:scaleBySize(16) } } }
        elseif st then
            mark = RoundedBox:new{ width = box, radius = Screen:scaleBySize(5), fill = COLORS.ink, pad_x = 0, pad_y = 0,
                CenterContainer:new{ dimen = Geom:new{ w = box, h = box },
                    Page.TextMark:new{ icon = "check", size = Screen:scaleBySize(18) } } }
        else
            mark = RoundedBox:new{ width = box, radius = Screen:scaleBySize(5), border = Size.border.button, border_color = COLORS.ink,
                fill = BlitBuffer.COLOR_WHITE, pad_x = 0, pad_y = 0, VerticalSpan:new{ width = box } }
        end
        local count = TextWidget:new{ text = tostring(it.count or ""), face = face13, fgcolor = COLORS.muted }
        local text_w = rinner - box - Screen:scaleBySize(14) * 2 - count:getSize().w
        local texts = VerticalGroup:new{ align = "left",
            TextWidget:new{ text = it.title, face = it.serif and getFaceOr(SERIF_FONT, 17, "cfont") or face15,
                bold = it.serif, max_width = text_w } }
        if it.subtitle and it.subtitle ~= "" then
            table.insert(texts, TextWidget:new{ text = it.subtitle, face = Font:getFace("cfont", 12), fgcolor = COLORS.muted, max_width = text_w })
        end
        local pad = Screen:scaleBySize(12)
        local row_h = math.max(box, texts:getSize().h) + pad * 2
        local rd = Geom:new{ w = rinner, h = row_h }
        local key = it.key
        table.insert(rows, TapBox:new{ OverlapGroup:new{ dimen = rd, allow_mirroring = false,
            LeftContainer:new{ dimen = rd, HorizontalGroup:new{ align = "center", mark, HorizontalSpan:new{ width = Screen:scaleBySize(14) }, texts } },
            RightContainer:new{ dimen = rd, count } },
            callback = function()
                -- tap: clear a marked item, or mark it with the switch's side
                -- (not `x and nil or y`: nil is false in Lua, that always gives y)
                if self:state(key) then self:set(key, nil) else self:set(key, self.mode) end
                self:changed()
            end })
        table.insert(rows, LineWidget:new{ dimen = Geom:new{ w = rinner, h = Size.line.thin }, background = COLORS.line_light })
    end
    if #visible == 0 then
        table.insert(rows, VerticalSpan:new{ width = Screen:scaleBySize(24) })
        table.insert(rows, TextWidget:new{ text = _("Nothing found."), face = face14, fgcolor = COLORS.muted })
    end

    local footer = Page.footer(function() self:onClose() end, Page.countText(#(self.list.filtered_notes or {})),
        function() self:onDone() end)

    local avail = H - top:getSize().h - footer:getSize().h
    local body = Page.paged(self, W, avail, rows, { left = P })
    self[1] = FrameContainer:new{ width = W, height = H, padding = 0, margin = 0, bordersize = 0, background = BlitBuffer.COLOR_WHITE,
        OverlapGroup:new{ dimen = Geom:new{ w = W, h = H }, allow_mirroring = false,
            VerticalGroup:new{ align = "left", top, body },
            BottomContainer:new{ dimen = Geom:new{ w = W, h = H }, footer } } }
end
function ListPicker:askQuery()
    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    dialog = InputDialog:new{
        title = self.search_hint, input = self.query,
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Clear"), callback = function() UIManager:close(dialog); self.query = ""; self.page_idx = 1; self:changed() end },
            { text = _("Search"), is_enter_default = true, callback = function()
                self.query = dialog:getInputText() or ""; self.page_idx = 1
                UIManager:close(dialog)
                self:changed()
            end },
        }},
    }
    NotesListWidget.showDialog(dialog)
    dialog:onShowKeyboard()
end
function ListPicker:onDone()
    UIManager:close(self, "flashui")
    self.list.current_page = 1
    self.list:refresh()
    if self.on_done then self.on_done() end
    return true
end
function ListPicker:onClose()
    local af = self.list.active_filter
    af[self.inc_key] = self.saved_inc
    af[self.exc_key] = self.saved_exc
    self.list:applyFilter()
    UIManager:close(self, "flashui")
    if self.on_done then self.on_done() end
    return true
end

function NotesListWidget:showBookPicker(on_done)
    local by_title, items = {}, {}
    for _i, n in ipairs(self.notes_list) do
        local t = n.book_title or _("Unknown")
        local it = by_title[t]
        if not it then
            local a = NoteWrapper:new(n):getDisplayAuthors()
            it = { key = t, title = t, subtitle = (a and a ~= "Unknown") and a or nil, count = 0, serif = true }
            by_title[t] = it
            table.insert(items, it)
        end
        it.count = it.count + 1
    end
    table.sort(items, function(a, b) return normalizeBookTitle(a.title) < normalizeBookTitle(b.title) end)
    UIManager:show(ListPicker:new{ list = self, title = _("Books"), items = items, inc_key = "books", exc_key = "books_exclude",
        mode_labels = { _("Only these books"), _("Hide these books") }, search_hint = _("Search title or author"), on_done = on_done })
end
function NotesListWidget:showChapterPicker(on_done)
    local seen, items = {}, {}
    local book_filter = self.active_filter and self.active_filter.books
    for _i, n in ipairs(self.notes_list) do
        if n.chapter and n.chapter ~= "" and (not book_filter or not next(book_filter) or book_filter[n.book_title]) then
            local it = seen[n.chapter]
            if not it then
                it = { key = n.chapter, title = n.chapter, group = n.book_title, count = 0 }
                seen[n.chapter] = it
                table.insert(items, it)
            end
            it.count = it.count + 1
        end
    end
    -- grouped by book, chapters in reading order where known
    local first_pos = {}
    for i, n in ipairs(self.notes_list) do if n.chapter and not first_pos[n.chapter] then first_pos[n.chapter] = i end end
    table.sort(items, function(a, b)
        if a.group ~= b.group then return normalizeBookTitle(a.group or "") < normalizeBookTitle(b.group or "") end
        return (first_pos[a.key] or 0) < (first_pos[b.key] or 0)
    end)
    UIManager:show(ListPicker:new{ list = self, title = _("Chapters"), items = items, inc_key = "chapters", exc_key = "chapters_exclude",
        mode_labels = { _("Only these chapters"), _("Hide these chapters") }, on_done = on_done })
end
function NotesListWidget:showTagPicker(on_done)
    local seen, items = {}, {}
    local book_filter = self.active_filter and self.active_filter.books
    for _i, n in ipairs(self.notes_list) do
        if not book_filter or not next(book_filter) or book_filter[n.book_title] then
            for _j, tag in ipairs(NoteWrapper:new(n):getTags()) do
                if tag ~= "" then
                    local it = seen[tag]
                    if not it then it = { key = tag, title = tag, count = 0 }; seen[tag] = it; table.insert(items, it) end
                    it.count = it.count + 1
                end
            end
        end
    end
    table.sort(items, function(a, b) return a.title:lower() < b.title:lower() end)
    UIManager:show(ListPicker:new{ list = self, title = _("Tags"), items = items, inc_key = "tags", exc_key = "tags_exclude",
        mode_labels = { _("Only these tags"), _("Hide these tags") }, on_done = on_done })
end

function AllNotesViewer:showNoteDetails(note, parent_widget)
    UIManager:show(AnnotationSheet:new{ note = note, viewer = self, parent_widget = parent_widget }, "ui")
end
end
function AllNotesViewer:showColorPicker(note, parent_widget)
    local RadioButtonWidget = require("ui/widget/radiobuttonwidget")
        local colors = {}
        for _, v in ipairs(ReaderHighlight.highlight_colors) do
            if v[2] ~= "gray" then
                table.insert(colors, { v[2], v[1], BlitBuffer.HIGHLIGHT_COLORS[v[2]] })
            end
        end
        table.insert(colors, { "gray", _("Gray"), BlitBuffer.COLOR_GRAY })
    local radio_buttons = {}
    for _, c in ipairs(colors) do
                table.insert(radio_buttons, {
                        { text = c[2], checked = note.color == c[1],
                            bgcolor = c[1] == "gray" and BlitBuffer.COLOR_GRAY or BlitBuffer.colorFromString(c[3]), provider = c[1] },
                })
    end
    NotesListWidget.showDialog(RadioButtonWidget:new{
        title_text = _("Select Color"),
        width_factor = 0.6,
        radio_buttons = radio_buttons,
        callback = function(radio)
            self:updateHighlightColor(note, radio.provider, parent_widget)
        end,
        colorful = true,
        dithered = true,
    })
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
    NotesListWidget.showDialog(dialog)
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
    local dialog
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
    NotesListWidget.showDialog(dialog)
end
-- Updates the plugin's own list after a change and redraws it.
local function updateListedNote(parent_widget, note, fn)
    for i, n in ipairs(parent_widget.notes_list) do
        if n == note or (n.book_path == note.book_path and itemMatchesNote(
                { datetime = n.datetime, text = n.highlighted_text, pos0 = n.pos0, pos1 = n.pos1 }, note)) then
            fn(n, i)
            break
        end
    end
    parent_widget:refresh()
end

function AllNotesViewer:setHighlightField(note, field, value, parent_widget, done_text)
    if not note.book_path then return end
    local updated = false
    local ui = getLiveReader(note.book_path)
    if ui then
        local index = findLiveIndex(ui, note)
        if index then
            setLiveHighlightField(ui, index, field, value)
            updated = true
        end
    else
        updated = editStoredAnnotation(note, function(item)
            item[field] = value
            item.datetime_updated = nowStamp()
        end)
    end
    if updated then
        self:clearBookCache(note.book_path)
        updateListedNote(parent_widget, note, function(n) n[field] = value end)
        if done_text then NotesListWidget.showDialog(InfoMessage:new{ text = done_text, timeout = 1 }) end
    end
end
function AllNotesViewer:updateHighlightStyle(note, new_style, parent_widget)
    self:setHighlightField(note, "drawer", new_style, parent_widget, _("Style updated."))
end
function AllNotesViewer:updateHighlightColor(note, new_color, parent_widget)
    self:setHighlightField(note, "color", new_color, parent_widget, _("Color updated."))
end
function AllNotesViewer:confirmDelete(note, parent_widget)
    NotesListWidget.States.confirmDelete(note, function()
        self:deleteAnnotation(note, parent_widget)
    end)
end
function AllNotesViewer:deleteAnnotation(note, parent_widget)
    if not note.book_path then return end
    local deleted = false
    local ui = getLiveReader(note.book_path)
    if ui then
        local index = findLiveIndex(ui, note)
        if index then
            if ui.highlight and ui.highlight.deleteHighlight then
                -- KOReader's own path: removes the PDF annotation, updates statistics,
                -- the "has annotations" flag and the footer
                ui.highlight:deleteHighlight(index)
            else
                local item = table.remove(ui.annotation.annotations, index)
                ui:handleEvent(Event:new("AnnotationsModified", { item, index_modified = -index }))
            end
            deleted = true
        end
    else
        local remaining
        deleted = editStoredAnnotation(note, function(_, list, i)
            table.remove(list, i)
            remaining = #list
        end)
        if deleted and remaining == 0 then
            -- keep the file browser's "has annotations" marker in sync
            local ok_bl, BookList = pcall(require, "ui/widget/booklist")
            if ok_bl and BookList.setBookInfoCacheProperty then
                BookList.setBookInfoCacheProperty(note.book_path, "has_annotations", false)
            end
        end
    end
    if deleted then
        self:clearBookCache(note.book_path)
        updateListedNote(parent_widget, note, function(_, i) table.remove(parent_widget.notes_list, i) end)
    end
end
-- First lines of the highlight, for the edit-note dialog (about three lines' worth).
local function cleanHighlightTextForDialog(text)
    local t = trimParagraph(((text or ""):gsub("%s+", " ")))
    if #t > 180 then
        local cut = t:sub(1, 180):gsub("[\128-\191]+$", "")
        -- do not leave half a UTF-8 character at the end
        while #cut > 0 and cut:byte(#cut) >= 0xC0 do cut = cut:sub(1, -2) end
        t = cut:gsub("%s+%S*$", "") .. "…"
    end
    return t
end
function AllNotesViewer:editNote(note, parent_widget, on_done)
    local InputDialog = require("ui/widget/inputdialog")
    local input_dialog
    local has_note = note.user_note and note.user_note:find("%S") ~= nil
    -- what the note is about: "Book · Chapter · date", then the start of the highlight
    local about = {}
    if note.book_title and note.book_title ~= "" then table.insert(about, note.book_title) end
    local info = buildInfoText(note, NoteWrapper:new(note))
    if info ~= "" then table.insert(about, info) end
    local quote = cleanHighlightTextForDialog(note.highlighted_text)
    local description = table.concat(about, " · ")
    if quote ~= "" then description = description .. (description ~= "" and "\n\n" or "") .. quote end
    local function save(text)
        UIManager:close(input_dialog)
        self:saveNoteEdit(note, text, parent_widget)
        if on_done then on_done() end
    end
    local row = {}
    if has_note then
        -- blank input deletes the note too; this just says so
        table.insert(row, { text = _("Remove note"), callback = function() save("") end })
    end
    table.insert(row, { text = _("Cancel"), id = "close", callback = function() UIManager:close(input_dialog) end })
    input_dialog = InputDialog:new{
        title = has_note and _("Edit note") or _("Add note"),
        description = description ~= "" and description or nil,
        input = note.user_note or "",
        input_hint = _("Your note on this passage"),
        input_type = "text",
        text_height = Screen:scaleBySize(120),
        buttons = {
            {
                unpack(row),
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function() save(input_dialog:getInputText()) end,
                },
            },
        },
    }
    NotesListWidget.showDialog(input_dialog)
    input_dialog:onShowKeyboard()
end
function AllNotesViewer:saveNoteEdit(note, new_note_text, parent_widget)
    if not note.book_path then return end
    local value = new_note_text ~= "" and new_note_text or nil -- blank input deletes the note, as in KOReader
    local updated = false
    local ui = getLiveReader(note.book_path)
    if ui then
        local index = findLiveIndex(ui, note)
        if index then
            -- same steps as ReaderBookmark:setBookmarkNote()
            local item = ui.annotation.annotations[index]
            local getType = ui.bookmark and ui.bookmark.getBookmarkType
            local type_before = getType and getType(item)
            item.note = value
            if ui.highlight and ui.highlight.writePdfAnnotation then
                ui.highlight:writePdfAnnotation("content", item, value or "")
            end
            local type_after = getType and getType(item)
            if type_before == "highlight" and type_after == "note" then
                ui:handleEvent(Event:new("AnnotationsModified", { item, nb_highlights_added = -1, nb_notes_added = 1 }))
            elseif type_before == "note" and type_after == "highlight" then
                ui:handleEvent(Event:new("AnnotationsModified", { item, nb_highlights_added = 1, nb_notes_added = -1 }))
            else
                ui:handleEvent(Event:new("AnnotationsModified", { item }))
            end
            updated = true
        end
    else
        updated = editStoredAnnotation(note, function(item)
            item.note = value
            item.datetime_updated = nowStamp()
        end)
    end
    if updated then
        self:clearBookCache(note.book_path)
        updateListedNote(parent_widget, note, function(n) n.user_note = value end)
        NotesListWidget.showDialog(InfoMessage:new{ text = _("Note saved."), timeout = 1 })
    end
end
function AllNotesViewer:openBookAtNote(note)
    local book_path = note.book_path
    if not book_path then
        NotesListWidget.showDialog(InfoMessage:new{ text = _("Cannot find book path.") })
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
-- Internals exposed for tests/run.lua; KOReader doesn't use this.
AllNotesViewer._test = {
    wrapText = wrapText,
    normalizeBookTitle = normalizeBookTitle,
    SORT_COMPARATORS = SORT_COMPARATORS,
    filterToString = filterToString,
    sortModeLabel = sortModeLabel,
    itemMatchesNote = itemMatchesNote,
    notesToMarkdown = notesToMarkdown,
    NotesListWidget = NotesListWidget,
}

return AllNotesViewer
