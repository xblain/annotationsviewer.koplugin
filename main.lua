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
local OverlapGroup = require("ui/widget/overlapgroup")
local CenterContainer = require("ui/widget/container/centercontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local GestureRange = require("ui/gesturerange")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local TextViewer = require("ui/widget/textviewer")
local SpinWidget = require("ui/widget/spinwidget")
local IconButton = require("ui/widget/iconbutton")
local LineWidget = require("ui/widget/linewidget")
local RightContainer = require("ui/widget/container/rightcontainer")
local BlitBuffer = require("ffi/blitbuffer")
local Screen = require("device").screen
local logger = require("logger")
local FontList = require("fontlist")
local DocSettings = require("docsettings")
local ReadHistory = require("readhistory")
-- The settings handle, the palette and the shared helper tables live in core.lua, so every
-- part of the plugin reads the same ones (and this chunk, at Lua's 200-local limit, keeps
-- its local count down).
local Core = require("core")
local G_reader_settings = Core.G
local COLORS = Core.COLORS
local SortState = Core.SortState
local lfs = require("libs/libkoreader-lfs")
local Font = require("ui/font")
local Size = require("ui/size")
local Geom = require("ui/geometry")
local _ = require("ano_i18n").gettext
local BD = require("ui/bidi")
local DataStorage = require("datastorage")
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
-- How much bigger (or smaller) the Settings page's own text is than its usual size. It is a shift
-- rather than a size so the three sizes the page uses keep their proportions.
local function getNoteSpacing() return Screen:scaleBySize(getSetting("note_spacing", DEFAULT_NOTE_SPACING)) end
local function getTextMargin() return Screen:scaleBySize(getSetting("text_margin", DEFAULT_TEXT_MARGIN)) end
local function getTruncateLines()
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
local function getSwipeSetting() return getSetting("swipe_direction", "both") end
-- What a tap on an annotation in the list does: "goto" jumps straight to the highlight in the
-- book (the annotation card then opens on a long press), "card" opens the card on a tap.
local function getTapSetting() return getSetting("tap_action", "goto") == "card" and "card" or "goto" end
-- What holding an annotation does: "card" (the default) opens its card, "goto" jumps to it in the
-- book. Set apart from the tap so both can be chosen freely (tap to jump / hold for the card, or
-- the other way round).
local function getHoldSetting() return getSetting("hold_action", "card") == "goto" and "goto" or "card" end
-- Review mode: highlight text in the list is covered, one row at a time is revealed on a tap.
-- "review_cover_styles" says which styles (KOReader's `drawer` names) are covered. A missing
-- setting means every style: a fresh install covers all four, and the switches in Settings show
-- all four on. Choosing none covers no highlight text (the mode then only hides the notes; see
-- "Always cover notes", which is turned on along with that choice).
local REVIEW_STYLES = { "lighten", "underscore", "strikeout", "invert" }
local function getReviewCoverStyles()
    local v = G_reader_settings:readSetting("annotationsviewer_review_cover_styles")
    if type(v) ~= "table" then return nil end -- nil: every style
    local out = {}
    for _i, k in ipairs(REVIEW_STYLES) do if v[k] == true then out[k] = true end end
    return out -- may be empty: nothing chosen
end
local function reviewCoversDrawer(drawer)
    drawer = drawer or "lighten"
    local chosen = getReviewCoverStyles()
    if not chosen then return true end -- nothing set: all styles
    return chosen[drawer] == true
end
-- Phrases a reader picked inside a highlight to be covered on their own ("excavated"), so review
-- mode tests just those words instead of the whole line. Kept per book and per annotation:
-- { [book_path] = { [annotation key] = { phrase, phrase, ... } } }.
-- The annotation key is the item's datetime plus its position, which is what tells two
-- annotations of one book apart across a reload.
-- The functions live on NoteItemWidget: the main chunk is at its 200-local limit.
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
local BOOK_GAP = Core.BOOK_GAP
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
-- where a book starts: a short notch across the track, like chapter ticks on Kindle/Kobo
local SB_MARK_OVERHANG = Screen:scaleBySize(3)          -- how far it sticks out on each side
local SB_MARK_HEIGHT   = math.max(1, math.floor(Screen:scaleBySize(1)))
-- Header: top bar (menu, title, search, filter, close), tab row, optional active-filter row
local TOPBAR_HEIGHT    = Screen:scaleBySize(50)
local TOPBAR_BOOK_HEIGHT = Screen:scaleBySize(54) -- one-book view: title + author line, a bit taller to fit the larger second line
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
    opened_recent = { label = _("Last opened book first") },
    opened_oldest = { label = _("Longest unopened book first") },
}

local SPIN_MENUS = Core.SPIN_MENUS

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
-- These helpers now live in core.lua, shared with edit.lua and the settings screens.
local normalizeColorStyle = Core.normalizeColorStyle
local normalizeBookTitle = Core.normalizeBookTitle
local compareByPosition = Core.compareByPosition
local trimParagraph = Core.trimParagraph
local wrapText = Core.wrapText
normalizeBookTitleUncached = function(title)
    local normalized = title:lower():gsub("^%s+", ""):gsub("%s+$", "")
    normalized = normalized:gsub("^the%s+", ""):gsub("^a%s+", ""):gsub("^an%s+", "")
    return normalized
end

-- Where a note sits in its book: page first, then the exact spot. EPUB-like books
-- keep an xpointer text ("/body/DocFragment[3]/body/p[12]/text().5") in pos0, PDFs a
-- table with x/y; neither is a number, so compare their digit runs one by one.
local positionKey = Core.positionKey

-- A sort order is a rule: up to three levels "key:direction" joined by commas, for example
-- "author:asc,book:asc,pos:asc". The old fixed names (author_location_asc, ...) still work and are
-- translated to rules. Whatever the levels leave tied is settled by: book A-Z, newest first, position.
-- Parse a rule (or an old name) into { {key=, dir=}, ... }; nil when it is not valid.
local SORT_COMPARATORS = setmetatable({}, { __index = function(_, mode) return Core.SortState.build(mode) end })

-- A highlight colour's code ("#rrggbb"). Newer KOReader (after 2026.07) lets you give each
-- colour its own name and code (Highlight color → hold a colour): its code is used then, the
-- built-in one otherwise. Never inverted for night mode: the list paints true colours itself.
function COLORS.highlightCode(key)
    if type(key) ~= "string" then return nil end
    key = key:lower()
    if ReaderHighlight.getHighlightColorCode then
        local ok, code = pcall(ReaderHighlight.getHighlightColorCode, ReaderHighlight, key, nil, false)
        if ok and type(code) == "string" and code:match("^#%x%x%x%x%x%x$") then return code end
    end
    return HIGHLIGHT_COLORS[key]
end
local function getHighlightColor(color)
    local val = COLORS.highlightCode(color)
    if val and BlitBuffer.colorFromString then
        return BlitBuffer.colorFromString(val)
    end
    return BlitBuffer.COLOR_GRAY
end
local isNoBackgroundStyle = Core.isNoBackgroundStyle

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

function Core.NoteWrapper:new(note)
    return setmetatable({ _note = note }, { __index = self })
end
function Core.NoteWrapper:getDisplayAuthors()
    if not self._note.book_authors or self._note.book_authors == "" or self._note.book_authors == "Unknown" then
        return nil
    end
    return truncateAuthorDisplay(self._note.book_authors)
end
function Core.NoteWrapper:getTags()
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
function Core.NoteWrapper:getNormalizedColor()
    return self._note.color and self._note.color:lower() or nil
end
function Core.NoteWrapper:getNormalizedDrawer()
    return self._note.drawer and self._note.drawer:lower() or nil
end
function Core.NoteWrapper:hasHighlightedText()
    return self._note.highlighted_text and self._note.highlighted_text ~= "" or false
end
function Core.NoteWrapper:hasUserNote()
    return self._note.user_note and self._note.user_note ~= "" or false
end

-- Text measurement caches. Font:getFace() returns cached face objects, so a face's
-- table identity is a stable key; weak keys let unused faces be collected.
-- Width and height measurement live in util.lua, together with the caches they fill: every
-- drawn line goes through them, and the caches are per-face module state, not this chunk's.
local Util = require("avutil")
local function measureTextWidth(text, face) return Util.measureTextWidth(text, face) end
local function getWordWidths(face) return Util.getWordWidths(face) end
local function getLineHeight(face) return Util.getLineHeight(face) end
local function getBoxHeight(text, face, width, bold) return Util.getBoxHeight(text, face, width, bold) end

-- Greedy word wrap. Same result as measuring every candidate line, but word widths are
-- measured once per face and summed; only lines that end up within the rounding error of
-- max_width are measured for real, so the line breaks are unchanged.
local function wrapParagraph(text, face, max_width, lines)
-- Words to wrap: split at spaces; Chinese / Japanese / Korean text has none, so such words are
-- cut into their characters with KOReader's util.splitToWords (the pieces join without a space).
    -- closing punctuation never starts a line: it stays with the character before it
    local closing = "。，、；：？！）」』】》〉〕］｝”’…"
    local function wrapTokens(txt)
        local tokens = {}
        for word in txt:gmatch("%S+") do
            if word:find("[\227-\237\239\240]") then -- also 4-byte characters (CJK beyond U+20000)
                for i, piece in ipairs(require("avutil").splitToWords(word)) do
                    if i > 1 and closing:find(piece, 1, true) then
                        tokens[#tokens][1] = tokens[#tokens][1] .. piece
                    else
                        table.insert(tokens, { piece, i > 1 })
                    end
                end
            else
                table.insert(tokens, { word, false })
            end
        end
        return tokens
    end
    local widths = getWordWidths(face)
    local space_w = widths[" "]
    -- a word wider than the column (a long URL) is broken between characters
    local tokens, src = {}, wrapTokens(text)
    for t = 1, #src do
        local tok = src[t]
        local word = tok[1]
        local ww = widths[word]
        if not ww then ww = measureTextWidth(word, face); widths[word] = ww end
        if ww <= max_width or not word:find("[^\128-\191].*[^\128-\191]") then
            table.insert(tokens, tok)
        else
            local piece, joined = "", tok[2]
            for ch in word:gmatch("[^\128-\191][\128-\191]*") do
                if piece ~= "" and measureTextWidth(piece .. ch, face) > max_width then
                    table.insert(tokens, { piece, joined })
                    piece, joined = "", true
                end
                piece = piece .. ch
            end
            if piece ~= "" then table.insert(tokens, { piece, joined }) end
        end
    end
    local current_line, current_w, words_since_exact = "", 0, 0
    for _t, tok in ipairs(tokens) do
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
-- UnderlineWidget and StrikeoutLineWidget live in avui.lua (three files draw with them).
local UI = require("avui")
local StrikeoutLineWidget = UI.StrikeoutLineWidget
local UnderlineWidget = UI.UnderlineWidget
local NoteItemWidget = require("noteitem")
-- NotesListWidget is needed below for two helpers it took with it, so it is required here rather
-- than where the list is first used.
local NotesListWidget = require("noteslist")

-- Widgets and helpers that the parts split out of this file still need.
local Device = require("device")
local Input = Device.input
local IconWidget = require("ui/widget/iconwidget")
local getNoteFaces = NoteItemWidget.getNoteFaces
local filterToString = NoteItemWidget.filterToString
local _nl_internals = NotesListWidget.internals or {}
local sortModeLabel = _nl_internals.sortModeLabel
local _forwardGestureToPlugin = _nl_internals._forwardGestureToPlugin
local getSidecarKey = Core.getSidecarKey
local getSettingsFontShift = Core.getSettingsFontShift
local itemMatchesNote = Core.itemMatchesNote
local Export = Core.Export

-- Shared with noteslist.lua: the cache is filled here while scanning and read there.
local loadPersistentCache = Core.loadPersistentCache
local savePersistentCache = Core.savePersistentCache
local getLiveReader = Core.getLiveReader
local getBookInfoKey = Core.getBookInfoKey

-- Wraps a widget so a tap on it calls callback(ges).
-- TapBox and Pill are plain widgets that know nothing about annotations; see ui.lua.
local TapBox = UI.TapBox
local Pill = UI.Pill

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

-- Colour & style filter: a set of "color:<key>" / "style:<drawer>" entries in af.cs, and
-- af.cs_exclude to hide them instead of showing only them. Older saved filters used a single
-- af.type/af.value (and type_exclude/value_exclude); they are moved into the set here.
local function colorStyleMatches(af, note)
    local nw = Core.NoteWrapper:new(note)
    local c, d = nw:getNormalizedColor(), nw:getNormalizedDrawer()
    local has_c, has_s, hit_c, hit_s = false, false, false, false
    for k in pairs(af.cs) do
        local t, v = k:match("^(%a+):(.+)$")
        if t == "color" then has_c = true; if v == c then hit_c = true end
        elseif t == "style" then has_s = true; if v == d then hit_s = true end end
    end
    if af.cs_exclude then return not (hit_c or hit_s) end
    -- several colours: any of them; colours and styles together: both must match. A highlight
    -- without a colour (Invert never has one, nor do some older highlights) matches on its style
    -- alone, or Invert with a colour would never show anything.
    if has_c and has_s and hit_s and (c == nil or d == "invert") then return true end
    return (not has_c or hit_c) and (not has_s or hit_s)
end

local AllNotesViewer = WidgetContainer:extend{ name = "allnotesviewer", is_doc_only = false }
AllNotesViewer.samePath = Core.samePath
AllNotesViewer.is_doc_only = false
function AllNotesViewer:init()
    AllNotesViewer.registerGestures()
    AllNotesViewer._current = self -- the open file browser's or book's plugin (used by the long-press button)
    AllNotesViewer.addFileDialogButton()
    AllNotesViewer.guardAllHandlers(self)
    self:takeOverInBook()
    self:takeOverBrowser()
    self.ui.menu:registerToMainMenu(self)
end
-- Every way into the plugin runs through here, so an error writes a report instead of closing
-- KOReader with nothing to read afterwards. The original error is still re-raised so it reaches
-- KOReader's own crash log as well.
function AllNotesViewer.guarded(where, fn, ...)
    local args = { ... }
    local n = select("#", ...)
    local ok, err = pcall(function() return fn(unpack(args, 1, n)) end)
    if ok then return end
    local report = AllNotesViewer.writeCrashReport(where, err)
    local text = _("Annotations Viewer stopped with an error:") .. "\n" .. tostring(err)
    if report then text = text .. "\n\n" .. _("Details written to:") .. "\n" .. report end
    pcall(UIManager.show, UIManager, InfoMessage:new{ text = text, timeout = 10 })
    error(err, 0)
end
-- Wraps the methods that KOReader can call into (menu entries, gesture handlers, event handlers)
-- so each one is guarded. Only once per method.
function AllNotesViewer.guardAllHandlers(self)
    if AllNotesViewer._guarded then return end
    AllNotesViewer._guarded = true
    local wrapped = AllNotesViewer._wrapped or {}
    AllNotesViewer._wrapped = wrapped
    local names = {
        "onShowAnnotationsHere", "onShowBookmarksHere", "showAllNotes", "showCurrentBookNotes",
        "showNoteDetails", "showNotesForBook", "openBookAtNote", "editNote", "editCloze",
        "editQuestion", "setHighlightField", "confirmDelete", "deleteAnnotation",
        "updateHighlightStyle", "updateHighlightColor", "saveNoteEdit", "reloadAnnotations",
        "clearBookCache", "showBookFile", "showColorPicker", "showStylePicker",
    }
    for _i, name in ipairs(names) do
        local fn = AllNotesViewer[name]
        if type(fn) == "function" and not wrapped["A:" .. name] then
            wrapped["A:" .. name] = true
            local where = name
            AllNotesViewer[name] = function(...)
                return AllNotesViewer.guarded(where, function(...) return fn(...) end, ...)
            end
        end
    end
    -- the list widget's own entry points, run unwrapped otherwise
    local NL = require("noteslist")
    if NL then
        for _i, name in ipairs({ "onNoteSelected", "onNoteGoto", "onTap", "onHold",
                                 "showSettingsMenu", "showFilterScreen", "showBookPicker",
                                 "showMetaPicker", "showChapterPicker", "showTagPicker",
                                 "showSortPicker" }) do
            local fn = NL[name]
            if type(fn) == "function" and not wrapped["L:" .. name] then
                wrapped["L:" .. name] = true
                local where = "NotesListWidget:" .. name
                NL[name] = function(...)
                    return AllNotesViewer.guarded(where, function(...) return fn(...) end, ...)
                end
            end
        end
    end
end
-- The plugin's gestures (Settings → Taps and gestures → Gesture manager), the same in the file
-- browser and in a book: "Annotations" opens this book's list in a book and all books in the file
-- browser; "Annotations: Bookmarks" does the same on the Bookmarks tab. Older versions had a
-- separate in-book action; it stays only for those who still have it on a gesture, so that gesture
-- keeps working.
AllNotesViewer.GESTURES = {
    { id = "show_all_annotations", event = "ShowAnnotationsHere", title = _("Annotations") },
    { id = "show_all_bookmarks", event = "ShowBookmarksHere", title = _("Annotations: Bookmarks") },
}
-- Actions of earlier versions. They stay registered so anything still set to them keeps working:
-- a gesture, a profile, or another plugin (SimpleUI and the like) that saved the action. They have
-- no menu section, so KOReader lists them nowhere for new choices, but still runs them.
AllNotesViewer.LEGACY_GESTURES = {
    { id = "show_current_book_annotations", event = "ShowCurrentBookAnnotations", title = _("Annotations") },
    { id = "show_current_book_bookmarks", event = "ShowCurrentBookBookmarksList", title = _("Annotations: Bookmarks") },
}
function AllNotesViewer.registerGestures()
    local Dispatcher = require("dispatcher")
    for n = 1, #AllNotesViewer.GESTURES do
        local g = AllNotesViewer.GESTURES[n]
        -- "general": KOReader runs it in the file browser and in a book. An action marked
        -- reader = true is switched off in the file browser (Dispatcher:isActionEnabled).
        Dispatcher:registerAction(g.id, { category = "none", event = g.event, title = g.title,
            general = true })
    end
    for _, g in ipairs(AllNotesViewer.LEGACY_GESTURES) do
        Dispatcher:registerAction(g.id, { category = "none", event = g.event, title = g.title })
    end
end
function AllNotesViewer:onShowAnnotationsHere()
    if self.ui and self.ui.document then self:showCurrentBookNotes() else self:showAllNotes() end
    return true
end
function AllNotesViewer:onShowBookmarksHere()
    if self.ui and self.ui.document then self:showCurrentBookNotes("bookmarks") else self:showAllNotes("bookmarks") end
    return true
end
-- the events of earlier versions, for anything that sends them itself
AllNotesViewer.onShowAllAnnotations = AllNotesViewer.onShowAnnotationsHere
AllNotesViewer.onShowCurrentBookAnnotations = AllNotesViewer.onShowAnnotationsHere
AllNotesViewer.onShowAllBookmarksList = AllNotesViewer.onShowBookmarksHere
AllNotesViewer.onShowCurrentBookBookmarksList = AllNotesViewer.onShowBookmarksHere
-- "Annotations" in a book's long-press menu (file browser, History, collections, search): opens
-- that book's list (on the Bookmarks tab when the book has only bookmarks). Only shown for a book
-- with annotations or bookmarks. Added once to KOReader's file dialogs; uses the plugin of the
-- open file browser or book.
function AllNotesViewer.addFileDialogButton()
    if AllNotesViewer._fd_added then return end
    local classes = {}
    for _, m in ipairs({ "apps/filemanager/filemanager", "apps/filemanager/filemanagerhistory",
            "apps/filemanager/filemanagercollection", "apps/filemanager/filemanagerfilesearcher" }) do
        local ok, c = pcall(require, m)
        if ok and type(c) == "table" then table.insert(classes, c) end
    end
    local FM = classes[1]
    if not FM or type(FM.addFileDialogButtons) ~= "function" then return end
    AllNotesViewer._fd_added = true
    local okr, DocumentRegistry = pcall(require, "document/documentregistry")
    local function row(file, is_file)
        if not is_file or (okr and type(DocumentRegistry.hasProvider) == "function" and not DocumentRegistry:hasProvider(file)) then
            return nil
        end
        local viewer = AllNotesViewer._current
        if viewer and not viewer:bookHasAnnotations(file) then return nil end
        return { { text = _("Annotations"), callback = function()
            for _, c in ipairs(classes) do
                local ok, menu = pcall(c.getMenuInstance)
                if ok and type(menu) == "table" and menu.file_dialog then UIManager:close(menu.file_dialog); menu.file_dialog = nil end
            end
            local v = AllNotesViewer._current
            if v then v:showBookFile(file) end
        end } }
    end
    for _, c in ipairs(classes) do FM.addFileDialogButtons(c, "annotationsviewer", row) end
    AllNotesViewer.takeOverBookmarksButton()
end
-- Whether a book has any annotations or bookmarks (the book open in the reader: its live ones).
function AllNotesViewer:bookHasAnnotations(path)
    local ReaderUI = require("apps/reader/readerui")
    local open = ReaderUI and ReaderUI.instance
    if open and open.document and Core.samePath(open.document.file, path)
            and open.annotation and open.annotation.annotations then
        return #open.annotation.annotations > 0
    end
    local ok, list = pcall(self.loadBookAnnotations, self, path)
    return ok and type(list) == "table" and #list > 0
end
-- Switch "KOReader's Bookmarks open here" (Settings → KOREADER, off by default). When on, every
-- way into KOReader's own bookmark lists opens this plugin's Bookmarks tab instead:
--   in a book: the Bookmarks menu entry, gesture and key (ReaderBookmark:onShowBookmark)
--   the Bookmark browser (2026.03 and later): its menu entry and gesture (onShowBookmarkBrowser)
--   the "Bookmarks" button in a book's long-press menu, History, search and collections
--   (genBookmarkBrowserButton): one book opens that book, several open all books.
-- KOReader's functions get a wrapper that looks at the switch each time, so turning it off works
-- straight away.
function AllNotesViewer.takeOverOn()
    local v = getSetting("take_over_bookmarks", false)
    return v == true or v == "all" or v == "bookmarks" -- (test builds stored a tab name)
end
function AllNotesViewer:takeOverInBook()
    local bm = self.ui and self.ui.bookmark
    if not bm or bm._av_show_bookmark or type(bm.onShowBookmark) ~= "function" then return end
    bm._av_show_bookmark = bm.onShowBookmark
    local viewer = self
    bm.onShowBookmark = function(this, ...)
        if AllNotesViewer.takeOverOn() then
            viewer:showCurrentBookNotes("bookmarks")
            return true
        end
        return this._av_show_bookmark(this, ...)
    end
end
function AllNotesViewer:takeOverBrowser()
    local coll = self.ui and self.ui.collections
    if not coll or coll._av_show_browser or type(coll.onShowBookmarkBrowser) ~= "function" then return end
    coll._av_show_browser = coll.onShowBookmarkBrowser
    local viewer = self
    coll.onShowBookmarkBrowser = function(this, ...)
        if AllNotesViewer.takeOverOn() then
            viewer:showAllNotes("bookmarks")
            return true
        end
        return this._av_show_browser(this, ...)
    end
end
function AllNotesViewer.takeOverBookmarksButton()
    local ok, coll = pcall(require, "apps/filemanager/filemanagercollection")
    if not ok or type(coll) ~= "table" or type(coll.genBookmarkBrowserButton) ~= "function" or coll._av_gen_button then return end
    coll._av_gen_button = coll.genBookmarkBrowserButton
    coll.genBookmarkBrowserButton = function(this, files, caller_pre_callback, ...)
        local button = this._av_gen_button(this, files, caller_pre_callback, ...)
        local paths = {}
        for path in pairs(type(files) == "table" and files or {}) do table.insert(paths, path) end
        if type(button) == "table" and #paths > 0 then
            local orig = button.callback
            button.callback = function(...)
                local viewer = AllNotesViewer._current
                if viewer and AllNotesViewer.takeOverOn() then
                    if caller_pre_callback then caller_pre_callback() end
                    if #paths == 1 then viewer:showBookFile(paths[1], "bookmarks") else viewer:showAllNotes("bookmarks") end
                elseif orig then
                    return orig(...)
                end
            end
        end
        return button
    end
end
-- One book's list by its path (tab: "bookmarks" or nil). The book open in the reader uses its live
-- annotations.
function AllNotesViewer:showBookFile(path, tab)
    local ReaderUI = require("apps/reader/readerui")
    local open = ReaderUI and ReaderUI.instance
    if open and open.document and Core.samePath(open.document.file, path) then
        return self:showCurrentBookNotes(tab)
    end
    local info = self:getBookInfo(path)
    self:showNotesForBook(path, info and info.title or (path:match("([^/\\]+)$") or path),
        self:loadBookAnnotations(path) or {}, tab)
end
-- tab: "bookmarks" opens the list on the Bookmarks tab; nil on All
function AllNotesViewer:showCurrentBookNotes(tab, focus_note)
    local ReaderUI = require("apps/reader/readerui")
    -- the book open right now wins: this plugin instance may have been created in the file browser
    -- (self.ui is the file manager there), and the list has to be built from the reader that is
    -- actually open — that is also the one whose annotations are live
    local ui = (ReaderUI and ReaderUI.instance) or self.ui
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
    -- Guarded like showAllNotes: an error here must not leave a loading message holding the input.
    local ok, res = pcall(function()
        return { self:showNotesForBook(book_path, book_title, annotations, tab, focus_note) }
    end)
    if not ok then
        local report = AllNotesViewer.writeCrashReport("showCurrentBookNotes", res)
        pcall(UIManager.show, UIManager, InfoMessage:new{
            text = _("The annotations could not be shown.") .. "\n\n"
                .. (report and (_("Details written to:") .. "\n" .. report) or tostring(res)),
            timeout = 10,
        })
        error(res, 0)
    end
    return unpack(res)
end
function AllNotesViewer:addToMainMenu(menu_items)
    if self.ui and self.ui.document then
        menu_items.current_book_notes_viewer = {
            text = _("Annotations"),
            sorting_hint = "navi",
            callback = function() self:showCurrentBookNotes() end,
        }
        -- "Annotations: Bookmarks" next to it, left out while KOReader's own Bookmarks open here
        -- (that entry then does the same). Read when KOReader builds its menu.
        if not AllNotesViewer.takeOverOn() then
            menu_items.current_book_bookmarks_viewer = {
                text = _("Annotations: Bookmarks"),
                sorting_hint = "navi",
                callback = function() self:showCurrentBookNotes("bookmarks") end,
            }
        end
    else
        menu_items.all_notes_viewer = {
            text = _("Annotations"),
            sorting_hint = "filemanager_settings",
            callback = function() self:showAllNotes() end,
        }
        if not AllNotesViewer.takeOverOn() then
            menu_items.all_bookmarks_viewer = {
                text = _("Annotations: Bookmarks"),
                sorting_hint = "filemanager_settings",
                callback = function() self:showAllNotes("bookmarks") end,
            }
        end
    end
end
-- "Reload annotations" in the ☰ menu: forget everything read so far (memory and the file in the
-- cache folder), then open the list again, which reads all books afresh.
function AllNotesViewer:reloadAnnotations(list)
    for k in pairs(Core._annotation_cache) do Core._annotation_cache[k] = nil end
    for k in pairs(Core._book_info_cache) do Core._book_info_cache[k] = nil end
    if Core._persist then
        Core._persist.data = { version = Core.CACHE_VERSION, books = {} }
        pcall(Core._persist.flush, Core._persist)
    end
    Core._persist, Core._persist_dirty, Core._persist_count = nil, false, 0
    local single = list and list.single_book
    if list then list:onClose() end
    if single then self:showCurrentBookNotes() else self:showAllNotes() end
end
function AllNotesViewer:clearBookCache(book_path)
    Core._annotation_cache[book_path] = nil
    -- book_info rarely changes, but clear it too so tags/title edits are reflected
    Core._book_info_cache[book_path] = nil
end
-- One item of KOReader's `annotations` list (sidecar or open book) as the plugin keeps it, or
-- nil when there is nothing to show. Highlights and notes have a `drawer`; an item without one
-- is a page bookmark: KOReader stores its place, chapter, date and an optional note, but no
-- text from the page (its `text` is only "in <chapter>"), so the list shows the page instead.
function AllNotesViewer.toNote(item, idx)
    local label = item.pageref or item.pageno -- page number as KOReader shows it
    if not item.drawer then
        if item.page == nil and item.pageno == nil then return nil end
        return {
            page = item.page or item.pageno, order = idx, page_label = label,
            chapter = item.chapter or "", text = "", notes = item.note or "",
            datetime = item.datetime or "", bookmark = true, bm_text = item.text,
            tags = item.tags, keywords = item.keywords,
        }
    end
    local has_highlight = item.text and item.text ~= ""
    local has_note = item.note and item.note ~= ""
    if not (has_highlight or has_note) then return nil end
    return {
        page = item.page or item.pageno or 0, order = idx, page_label = label,
        pos0 = item.pos0, pos1 = item.pos1,
        chapter = item.chapter or "", text = item.text or "", notes = item.note or "",
        datetime = item.datetime or "", drawer = item.drawer, color = item.color or "yellow",
        tags = item.tags, keywords = item.keywords,
    }
end
function AllNotesViewer:convertLiveAnnotations(live)
    local annotations = {}
    for idx, item in ipairs(live) do
        local n = AllNotesViewer.toNote(item, idx)
        if n then table.insert(annotations, n) end
    end
    return annotations
end
-- A sidecar in KOReader's old format (no `annotations` list; the book was not opened since
-- KOReader 2024) as plugin notes, each marked legacy. Built the way KOReader converts the file
-- when it opens the book (readerannotation.lua migrateToAnnotations / buildAnnotation), so the
-- list shows what KOReader will keep: every bookmark becomes one annotation, with its text
-- (`notes`), note (`text`, unless KOReader wrote it itself), date and position; the style and
-- colour come from the matching `highlight[page]` entry (the same date when both have one, and
-- the same position). A highlight without a bookmark only counts when KOReader still imports
-- those (no `highlights_imported`).
function AllNotesViewer.legacyNotes(data)
    local out = {}
    if type(data) ~= "table" then return out end
    local highlights = type(data.highlight) == "table" and data.highlight or {}
    local bookmarks = type(data.bookmarks) == "table" and data.bookmarks or {}
    local function samePos(a, b)
        if type(a) == "table" and type(b) == "table" then return a.x == b.x and a.y == b.y end
        return a == b
    end
    local function matches(hl, page, bm)
        if hl.datetime ~= nil and bm.datetime ~= nil and hl.datetime ~= bm.datetime then return false end
        if type(hl.pos0) == "table" and tonumber(bm.page) ~= tonumber(page) then return false end
        return samePos(hl.pos0, bm.pos0) and samePos(hl.pos1, bm.pos1)
    end
    -- KOReader's own text on a bookmark ("Page 12 <text> @ <date>", in KOReader's language) is
    -- not a note (readerbookmark.lua isBookmarkAutoText)
    local auto_tpl = "Page %1 %2 @ %3"
    local ok_gt, gettext = pcall(require, "gettext")
    if ok_gt and gettext then -- KOReader's gettext is a callable table
        local ok_t, t = pcall(gettext, auto_tpl)
        if ok_t and type(t) == "string" then auto_tpl = t end
    end
    local function esc(str) return (tostring(str):gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0")) end
    local function noteOf(bm)
        local t = type(bm.text) == "string" and bm.text or ""
        if t == "" or t == bm.notes then return "" end
        local pat = esc(auto_tpl):gsub("%%%%([123])", function(d)
            if d == "1" then return ".-" end
            local v = d == "2" and bm.notes or bm.datetime
            return v ~= nil and esc(v) or ".-"
        end)
        if t:match("^" .. pat .. "$") then return "" end
        return t
    end
    -- a PDF position without its page (old reflow highlights) gets it, as KOReader does
    local function withPage(pos, page)
        if type(pos) ~= "table" or pos.page ~= nil then return pos end
        local copy = {}
        for k, v in pairs(pos) do copy[k] = v end
        copy.page = page
        return copy
    end
    local hl_list = {}
    for page, page_highlights in pairs(highlights) do
        if type(page_highlights) == "table" then
            for k = 1, #page_highlights do
                local hl = page_highlights[k]
                if type(hl) == "table" and hl.drawer then table.insert(hl_list, { hl = hl, page = page }) end
            end
        end
    end
    local used = {}
    for j = 1, #bookmarks do
        local bm = bookmarks[j]
        if type(bm) == "table" and bm.page ~= nil then
            local note = noteOf(bm)
            if bm.highlighted then
                local hl, hl_page
                for k = 1, #hl_list do
                    -- KOReader takes the first match, even one another bookmark matched already
                    if matches(hl_list[k].hl, hl_list[k].page, bm) then
                        used[k] = true
                        hl, hl_page = hl_list[k].hl, hl_list[k].page
                        break
                    end
                end
                local text = type(bm.notes) == "string" and bm.notes or ""
                if text ~= "" or note ~= "" then
                    table.insert(out, {
                        page = bm.page, page_label = tonumber(hl_page) or tonumber(bm.page),
                        pos0 = withPage(bm.pos0, bm.page), pos1 = withPage(bm.pos1, bm.page),
                        chapter = bm.chapter or (hl and hl.chapter) or "", text = text, notes = note,
                        datetime = bm.datetime or "",
                        -- without its highlight entry KOReader uses the default style (lighten, yellow)
                        drawer = hl and hl.drawer or "lighten", color = hl and hl.color or "yellow",
                        tags = hl and hl.tags, keywords = hl and hl.keywords, legacy = true,
                    })
                end
            else -- a page bookmark
                table.insert(out, {
                    page = bm.page, page_label = tonumber(bm.page), chapter = bm.chapter or "", text = "",
                    notes = note, datetime = bm.datetime or "", bookmark = true, bm_text = bm.notes,
                    legacy = true,
                })
            end
        end
    end
    -- very old books (before 2014) had highlights that were never added to the bookmarks:
    -- KOReader imports those once, while highlights_imported is not set
    if not data.highlights_imported then
        for k = 1, #hl_list do
            local hl, page = hl_list[k].hl, hl_list[k].page
            local text = type(hl.text) == "string" and hl.text or ""
            if not used[k] and hl.pos0 ~= nil and text ~= "" then
                table.insert(out, {
                    page = type(hl.pos0) == "table" and (tonumber(page) or page) or hl.pos0, page_label = tonumber(page), pos0 = withPage(hl.pos0, page), pos1 = withPage(hl.pos1, page),
                    chapter = hl.chapter or "", text = text, notes = "",
                    datetime = hl.datetime or "", drawer = hl.drawer, color = hl.color or "yellow",
                    tags = hl.tags, keywords = hl.keywords, legacy = true,
                })
            end
        end
    end
    return out
end
-- What a sidecar file holds, read without changing anything on disk (DocSettings:open removes
-- empty or broken candidates), or nil. A missing or empty file falls back to KOReader's backup
-- copy (".old"), as DocSettings:open does.
-- book_path: when the sidecar couldn't be looked for (sidecar nil: KOReader before 2024 has no
-- findSidecarFile), read the book's settings the old way.
function AllNotesViewer.readSidecar(sidecar, book_path)
    if sidecar == nil and type(book_path) == "string" then
        local ok, ds = pcall(DocSettings.open, DocSettings, book_path)
        return ok and ds and type(ds.data) == "table" and ds.data or nil
    end
    if type(sidecar) ~= "string" or sidecar == "" then return nil end
    local paths = { sidecar, sidecar .. ".old" }
    for k = 1, 2 do
        local path = paths[k]
        local ok, stored
        if DocSettings.openSettingsFile then
            local ok_ds, ds = pcall(DocSettings.openSettingsFile, path)
            ok, stored = ok_ds and ds ~= nil, ds and ds.data
        else
            ok, stored = pcall(dofile, path)
        end
        if ok and type(stored) == "table" and next(stored) ~= nil then return stored end
    end
    -- that file doesn't load: the next one KOReader would read (it would delete this one)
    if type(book_path) == "string" then
        local ok_c, list = pcall(Core.sidecarCandidates, book_path)
        for i = 1, ok_c and #list or 0 do
            local path = list[i].path
            if path ~= sidecar and path ~= sidecar .. ".old" and list[i].size > 0 then
                local ok_r, stored = pcall(dofile, path)
                if ok_r and type(stored) == "table" and next(stored) ~= nil then return stored end
            end
        end
    end
end
-- key/sidecar are optional: pass them when getSidecarKey() was already called for this book.
function AllNotesViewer:loadBookAnnotations(book_path, key, sidecar)
    local annotations = {}
    if not book_path then return annotations end
    if not key then key, sidecar = getSidecarKey(book_path) end
    local cached = Core._annotation_cache[book_path]
    if cached and cached.mtime == key then
        return cached.data
    end
    Core._persist_dirty = true
    -- read only: DocSettings:open is for writing (it removes empty or broken sidecar files)
    local data = AllNotesViewer.readSidecar(sidecar, book_path) or {}
    
    local items = data.annotations
    -- an empty list is a converted book without annotations (KOReader keeps the old keys)
    if type(items) == "table" then
        for idx, item in ipairs(items) do
            local n = AllNotesViewer.toNote(item, idx)
            if n then table.insert(annotations, n) end
        end
    else -- old format (book not opened since KOReader 2024): shown, but not editable
        annotations = AllNotesViewer.legacyNotes(data)
    end
    table.sort(annotations, function(a, b) return (a.datetime or "") > (b.datetime or "") end)
    Core._annotation_cache[book_path] = { data = annotations, mtime = key }
    -- Fill the book info cache from the same file, so getBookInfo() doesn't open it again
    if #annotations > 0 then self:getBookInfo(book_path, data, key, sidecar) end
    return annotations
end
-- data/key/sidecar are optional: pass data when the book's settings are already open, and
-- key/sidecar when getSidecarKey() was already called for this book.
function AllNotesViewer:getBookInfo(book_path, data, key, sidecar)
    if not key then key, sidecar = getSidecarKey(book_path) end
    local info_key = getBookInfoKey(key, sidecar)
    local cached = Core._book_info_cache[book_path]
    if cached and cached.mtime == info_key then
        return cached.data
    end
    Core._persist_dirty = true
    data = data or AllNotesViewer.readSidecar(sidecar, book_path) or {}
    local filename = book_path:match("([^/\\]+)$") or book_path
    
    local custom_metadata = {}
    do
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
    
    -- series and language: the book's own metadata, as KOReader's book information shows it
    local function prop(name)
        local v = (custom_metadata.custom_props and custom_metadata.custom_props[name])
            or (custom_metadata.doc_props and custom_metadata.doc_props[name])
            or (data.doc_props and data.doc_props[name])
        if type(v) == "number" then v = tostring(v) end
        return type(v) == "string" and v ~= "" and v or nil
    end
    local series, language = prop("series"), prop("language")

    if not title or title == "" then title = filename:gsub("%.[^.]+$", "") end
    
    local info = { path = book_path, filename = filename, title = title or filename, authors = authors or "Unknown", tags = tags,
        series = series, language = language }
    Core._book_info_cache[book_path] = { data = info, mtime = info_key }
    return info
end
function AllNotesViewer:findAllNotes()
    local notes_data = {}
    local seen = {}  -- paths already tried
    local scanned = {} -- books with a sidecar, kept in the on-disk cache
    loadPersistentCache()
    Core._realpaths = {} -- links may have changed since the last scan

    -- Helper: load annotations for a path and add to notes_data if any found
    local added = {} -- real paths of the books already listed
    local function addBook(book_path)
        if seen[book_path] then return end
        seen[book_path] = true
        -- another spelling of a book already listed; one that found nothing doesn't count, as
        -- KOReader may keep the sidecar under the other spelling
        local real = Core.realPath(book_path)
        if added[real] then return end
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
            added[real] = true
            local book_info = self:getBookInfo(book_path, nil, key, sidecar)
            table.insert(notes_data, {
                path = book_path, filename = book_info.filename,
                title = book_info.title, authors = book_info.authors,
                series = book_info.series, language = book_info.language,
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
-- Tags from a book or an annotation: a list, or one string split at , ; | tab or newline.
function AllNotesViewer.splitTags(val)
    if type(val) == "table" then return val end
    if type(val) ~= "string" then return nil end
    local t = {}
    for tag in val:gmatch("[^,;\n|\t]+") do
        tag = tag:match("^%s*(.-)%s*$")
        if tag ~= "" then table.insert(t, tag) end
    end
    return t
end
-- One entry of the list from an annotation read from a book. book: { title, authors, filename,
-- path }; book_tags: the book's tags as a list (used when the annotation has none of its own).
function AllNotesViewer.listNote(note, book, book_tags)
    local tag_set, all_tags = {}, {}
    for _, tag in ipairs(AllNotesViewer.splitTags(note.tags) or book_tags or {}) do
        if tag ~= "" then tag_set[tag] = true end
    end
    for tag in pairs(tag_set) do table.insert(all_tags, tag) end
    table.sort(all_tags)
    return {
        book_title = book.title, book_authors = book.authors, book_filename = book.filename, book_path = book.path,
        book_series = book.series, book_language = book.language,
        page = note.page, chapter = note.chapter, order = note.order,
        pos0 = note.pos0, pos1 = note.pos1,
        highlighted_text = note.text, user_note = note.notes,
        datetime = note.datetime, drawer = note.drawer, color = note.color,
        bookmark = note.bookmark, bm_text = note.bm_text, page_label = note.page_label,
        legacy = note.legacy, tags = all_tags,
    }
end
function AllNotesViewer:showNotesForBook(book_path, book_title, raw_annotations, tab, focus_note)
    local book_info = self:getBookInfo(book_path)
    local notes_list = {}
    local book = { title = book_title, authors = book_info and book_info.authors or nil,
        filename = book_path:match("([^/\\]+)$") or book_path, path = book_path,
        series = book_info and book_info.series, language = book_info and book_info.language }
    local book_tags = AllNotesViewer.splitTags(book_info and book_info.tags)
    for _, note in ipairs(raw_annotations) do
        table.insert(notes_list, AllNotesViewer.listNote(note, book, book_tags))
    end
    Core.SortState.bm_tab = nil -- a new list starts sorted for the annotation tabs (see syncSortTab)
    NotesListWidget:sortNotesList(notes_list, Core.SortState.get(true), true)
    -- focus_note: the list opens on the page that holds this annotation
    local list = NotesListWidget:new{ notes_list = notes_list, viewer = self, single_book = true, book_title = book_title,
        focus_note = focus_note,
        active_filter = tab and { notes_presence = tab } or nil }
    UIManager:show(list)
    return list
end
-- tab: "bookmarks" opens on the Bookmarks tab
function AllNotesViewer:showAllNotes(tab)
    -- Anything that goes wrong while the list is being built used to leave the loading message on
    -- screen for good: it takes over the input, so the device had to be restarted. The whole
    -- sequence runs guarded, and even on failure the screen is handed back before the error is
    -- reported.
    local loading
    local function buildAndShow()
        -- The first open after starting KOReader may have to read many books: say so
        if not Core._persist then
            loading = NotesListWidget.States.loading()
        end
        local all_notes_by_book = self:findAllNotes()
        local notes_list = {}
        for _, book_data in ipairs(all_notes_by_book) do
            local book = { title = book_data.title, authors = book_data.authors, filename = book_data.filename, path = book_data.path,
                series = book_data.series, language = book_data.language }
            local book_tags = AllNotesViewer.splitTags(book_data.tags)
            for _, note in ipairs(book_data.notes) do
                table.insert(notes_list, AllNotesViewer.listNote(note, book, book_tags))
            end
        end
        Core.SortState.bm_tab = nil -- a new list starts sorted for the annotation tabs (see syncSortTab)
        NotesListWidget:sortNotesList(notes_list, Core.SortState.get(false), false)
        return NotesListWidget:new{ notes_list = notes_list, viewer = self,
            active_filter = tab and { notes_presence = tab } or nil }
    end
    local ok, widget = pcall(buildAndShow)
    if loading then pcall(UIManager.close, UIManager, loading) end
    if not ok then
        -- Close the loading message so the screen is usable again, write the whole traceback to a
        -- file (a message on screen is gone before it can be read or copied), then let the error
        -- go on to KOReader so it lands in crash.log as usual.
        local report = AllNotesViewer.writeCrashReport("showAllNotes", widget)
        pcall(UIManager.show, UIManager, InfoMessage:new{
            text = _("The annotations could not be shown.") .. "\n\n"
                .. (report and (_("Details written to:") .. "\n" .. report) or tostring(widget)),
            timeout = 10,
        })
        error(widget, 0)
    end
    UIManager:show(widget)
end
-- Writes `err` with its traceback to a file next to the plugin, and returns the path.
-- The reader can copy that file; the on-screen message cannot be selected.
function AllNotesViewer.writeCrashReport(where, err)
    local path = (PLUGIN_DIR or "./") .. "crash-annotationsviewer.txt"
    local ok, f = pcall(io.open, path, "w")
    if not ok or not f then return nil end
    f:write("annotationsviewer.koplugin\n")
    f:write("when: " .. tostring(os.date("%Y-%m-%d %H:%M:%S")) .. "\n")
    f:write("where: " .. tostring(where) .. "\n\n")
    f:write(tostring(err) .. "\n\n")
    f:write("traceback:\n")
    f:write(debug.traceback("", 2) or "(none)")
    f:write("\n")
    f:close()
    return path
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
        kept[max_lines] = NoteItemWidget.cutLine(kept[max_lines], "…", face, line_width) .. "…"
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

-- The annotation card, and the rounded shapes it draws with, live in sheet.lua.
local AnnotationSheet = require("sheet")
-- The rounded shapes are defined in sheet.lua with the card; the rest of main.lua draws boxes too.
local RoundedBox = AnnotationSheet.RoundedBox
local RoundedOutline = AnnotationSheet.RoundedOutline
-- "Filter & sort": full-screen page from the mockup. Changes apply straight away (the list
-- behind updates and the button shows how many are left); Cancel / ✕ / Back put everything
-- back as it was when the page opened.
-- Shared title bar for full-screen pages (Filter & sort, pickers): same height, icon size,
-- spacing and serif title as the list's top bar; ‹ on the left, ✕ on the right (both cancel).
NotesListWidget.Page = Core.Page
-- A tick (or ✕) drawn with plain white strokes, so it shows on every device (no icon file, no font glyph)
Core.Page.Glyph = WidgetContainer:extend{ kind = "check", size = 18 }
function Core.Page.Glyph:getSize() return Geom:new{ w = self.size, h = self.size } end
function Core.Page.Glyph:paintTo(bb, x, y)
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
Core.Page.IconMark = WidgetContainer:extend{ icon = "check", size = 18 }
function Core.Page.IconMark:init()
    self.iw = IconWidget:new{ icon = self.icon, width = self.size, height = self.size }
    self.glyph = Core.Page.Glyph:new{ kind = self.icon == "close" and "close" or "check", size = self.size }
    self.missing = tostring(self.iw.file or ""):find("icon-not-found", 1, true) ~= nil
    if self.missing then logger.warn("AnnotationsViewer: icon '" .. self.icon .. "' not found, drawing it instead") end
end
function Core.Page.IconMark:getSize() return Geom:new{ w = self.size, h = self.size } end
function Core.Page.IconMark:paintTo(bb, x, y)
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
Core.Page.TextMark = WidgetContainer:extend{ icon = "check", size = 18 }
function Core.Page.TextMark:init()
    self.char = self.icon == "close" and "\226\156\149" or "\226\156\147" -- ✕ / ✓
    self.fallback = Core.Page.IconMark:new{ icon = self.icon, size = self.size }
end
function Core.Page.TextMark:getSize() return Geom:new{ w = self.size, h = self.size } end
function Core.Page.TextMark:measure(bbtype)
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
function Core.Page.TextMark:paintTo(bb, x, y)
    if self.dots == nil then self:measure(bb:getType()) end
    if not self.dots then return self.fallback:paintTo(bb, x, y) end
    for _, d in ipairs(self.dots) do bb:paintRect(x + d[1], y + d[2], 1, 1, d[3]) end
end
NoteItemWidget.TextMark = Core.Page.TextMark -- also used by the active-filter chips in the list
function Core.Page.header(owner, title, on_back, right_items, no_back, on_close)
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
Core.Page.BUTTON_H = Screen:scaleBySize(48)
Core.Page.FOOTER_TOP, Core.Page.FOOTER_BOTTOM = Screen:scaleBySize(12), Screen:scaleBySize(18)
function Core.Page.button(text, primary, width, callback)
    local tw = TextWidget:new{ text = text, face = Font:getFace("cfont", 15), bold = primary,
        max_width = width - Screen:scaleBySize(12), fgcolor = primary and BlitBuffer.COLOR_WHITE or COLORS.ink }
    return TapBox:new{ RoundedBox:new{ width = width, radius = Screen:scaleBySize(8),
        fill = primary and COLORS.ink or BlitBuffer.COLOR_WHITE, border = primary and 0 or Size.border.button,
        border_color = COLORS.ink, pad_x = 0, pad_y = 0,
        CenterContainer:new{ dimen = Geom:new{ w = width, h = Core.Page.BUTTON_H }, tw } }, callback = callback }
end
function Core.Page.footer(cancel_cb, primary_text, primary_cb)
    local W = Screen:getWidth()
    local P = Screen:scaleBySize(24)
    local inner = W - P * 2
    local gap = Screen:scaleBySize(10)
    local bw1 = math.floor((inner - gap) / 3)
    return VerticalGroup:new{
        LineWidget:new{ dimen = Geom:new{ w = W, h = Size.line.thin }, background = COLORS.line },
        VerticalSpan:new{ width = Core.Page.FOOTER_TOP },
        HorizontalGroup:new{ HorizontalSpan:new{ width = P },
            Core.Page.button(_("Cancel"), false, bw1, cancel_cb),
            HorizontalSpan:new{ width = gap },
            Core.Page.button(primary_text, true, inner - gap - bw1, primary_cb) },
        VerticalSpan:new{ width = Core.Page.FOOTER_BOTTOM },
    }
end
-- Live sample of the list for the Text / Spacing pages: two real annotations drawn with the
-- current settings, clipped to a fixed height so the page below does not move.
Core.Page.PreviewClip = WidgetContainer:extend{ w = 0, h = 0 }
function Core.Page.PreviewClip:getSize() return Geom:new{ w = self.w, h = self.h } end
function Core.Page.PreviewClip:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.w, h = self.h }
    local buf = BlitBuffer.new(self.w, self.h, bb:getType())
    buf:fill(BlitBuffer.COLOR_WHITE)
    self[1]:paintTo(buf, 0, 0)
    bb:blitFrom(buf, x, y, 0, 0, self.w, self.h)
    buf:free()
    if isScrollbarStyle() and not self.no_bar then -- the list's scrollbar: thin track and an outlined thumb, as a sample
        local cx = self.w - SB_STRIP_WIDTH - SB_MARGIN_RIGHT + math.floor(SB_STRIP_WIDTH / 2)
        local top, bot = Screen:scaleBySize(10), self.h - Screen:scaleBySize(10)
        bb:paintRect(x + cx, y + top, Size.line.thin, bot - top, BlitBuffer.COLOR_BLACK)
        local tw, th = SB_THUMB_WIDTH, math.floor((bot - top) / 3)
        bb:paintRect(x + cx - math.floor(tw / 2), y + top, tw, th, BlitBuffer.COLOR_WHITE)
        bb:paintBorder(x + cx - math.floor(tw / 2), y + top, tw, th, Size.border.default, BlitBuffer.COLOR_BLACK, math.floor(tw / 2))
    end
end
function Core.Page.preview(list, h, mark_gap, bookmarks)
    local W = Screen:getWidth()
    local samples = bookmarks and {
        -- the Bookmarks page: bookmarks as they show in the list, one with a note, one with a long chapter
        { book_title = "Lorem Ipsum", book_authors = "Dolor Sit", chapter = "Chapter One", bookmark = true,
          page_label = 12, datetime = "2026-01-09 10:12:00", highlighted_text = "",
          user_note = "Duis aute irure dolor in reprehenderit in voluptate velit esse." },
        { book_title = "Lorem Ipsum", book_authors = "Dolor Sit", chapter = "Chapter Two", bookmark = true,
          page_label = 27, datetime = "2026-01-11 08:40:00", highlighted_text = "" },
        { book_title = "Lorem Ipsum", book_authors = "Dolor Sit", bookmark = true, page_label = 41,
          chapter = "Chapter Three: Excepteur sint occaecat cupidatat non proident, sunt in culpa",
          datetime = "2026-01-14 21:03:00", highlighted_text = "" },
    } or {
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
        if i > 1 then table.insert(g, VerticalSpan:new{ width = NoteItemWidget.gapAbove(n, true) }) end
        local ok, wdg = pcall(function()
            return NoteItemWidget:new{ width = nw, note = n, show_parent = list, skip_title = i > 1, disable_tap = true }
        end)
        -- the preview is a nicety: if a row cannot be built, leave it out rather than fail the page
        if ok and wdg then
            table.insert(g, x_off > 0 and HorizontalGroup:new{ HorizontalSpan:new{ width = x_off }, wdg } or wdg)
            if i == 1 then
                local ok_size, size = pcall(wdg.getSize, wdg)
                if ok_size and size then first_h = size.h end
            end
        end
    end
    -- Spacing page: end the preview just after the top of the second note, so the gap between the
    -- notes can be judged from the sliver of the next one. Text page: tall enough for the whole first
    -- annotation with its note (a bigger or taller note font is not cut off). Bookmarks: all of them.
    -- Never more than half the screen.
    local max_h = math.floor(Screen:getHeight() * 0.5)
    if bookmarks then
        h = math.min(max_h, g:getSize().h + Screen:scaleBySize(12))
    elseif mark_gap and first_h then
        h = math.min(max_h, top + first_h + getNoteSpacing() + Screen:scaleBySize(28))
    elseif first_h then
        h = math.min(max_h, math.max(h, top + first_h + Screen:scaleBySize(12)))
    end
    return VerticalGroup:new{ align = "left",
        Core.Page.PreviewClip:new{ w = W, h = h, g },
        LineWidget:new{ dimen = Geom:new{ w = W, h = Size.line.thin }, background = COLORS.line } }
end
-- Core.Export page: the start of the file as it will be written (the first annotations of the list, or
-- Lorem ipsum when the list is empty), in a fixed-width font, cut off at h.
function Core.Page.exportPreview(list, h)
    local W = Screen:getWidth()
    local o = Core.Export.options()
    local notes = {}
    -- the first three, long texts cut short (the preview only shows the start anyway)
    for i, n in ipairs(list.filtered_notes or {}) do
        if i > 3 then break end
        local c = {}
        for k, v in pairs(n) do c[k] = v end
        for k in pairs({ highlighted_text = true, user_note = true }) do
            if type(c[k]) == "string" and #c[k] > 400 then c[k] = c[k]:sub(1, 400):gsub("[\192-\255][\128-\191]*$", "") .. "…" end
        end
        table.insert(notes, c)
    end
    if #notes == 0 then
        notes = {
            { book_title = "Lorem Ipsum", book_authors = "Dolor Sit", chapter = "Chapter One", page_label = 12,
              datetime = "2026-01-09 10:12:00", drawer = "lighten", color = "yellow", tags = { "lorem" },
              highlighted_text = "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore.",
              user_note = "Duis aute irure dolor in reprehenderit." },
            { book_title = "Lorem Ipsum", book_authors = "Dolor Sit", chapter = "Chapter Two", page_label = 27,
              datetime = "2026-01-11 08:40:00", drawer = "underscore", color = "blue",
              highlighted_text = "Excepteur sint occaecat cupidatat non proident." },
        }
    end
    local text
    -- The preview never writes files: an EPUB per book would go through the archive writer, so the
    -- preview always takes build(), which returns the text to show.
    if o.files == "book" and o.format ~= "epub" then
        local f = Core.Export.files(notes, o, list.exportFilterLabel and list:exportFilterLabel() or "", "20260109-101200")[1]
        text = f and f.text or ""
    else
        text = Core.Export.build(notes, o, list.exportFilterLabel and list:exportFilterLabel() or "")
    end
    local P = Screen:scaleBySize(24)
    local box = TextBoxWidget:new{ text = text, face = Font:getFace("scfont", 13), width = W - P * 2 }
    local top = Screen:scaleBySize(10)
    local g = VerticalGroup:new{ align = "left", VerticalSpan:new{ width = top },
        HorizontalGroup:new{ HorizontalSpan:new{ width = P }, box } }
    -- end on a whole line, never half of one
    local lh = tonumber(box.line_height_px)
    if lh and lh > 0 and g:getSize().h + top > h then
        h = top + math.max(1, math.floor((h - top * 2) / lh)) * lh
    end
    h = math.min(h, g:getSize().h + top)
    return VerticalGroup:new{ align = "left",
        Core.Page.PreviewClip:new{ w = W, h = h, no_bar = true, g },
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
function Core.Page.forwardGestures(cls)
    NotesListWidget.trackWindow(cls)
    function cls:onGesture(ev)
        if self.toast then return false end -- toasts let everything through anyway
        if InputContainer.onGesture(self, ev) then return true end
        return _forwardGestureToPlugin(ev, self)
    end
end
Core.Page.forwardGestures(AnnotationSheet)
-- Full-screen pages: rebuild for the new size when the screen was rotated.
function Core.Page.watchResize(cls)
    function cls:paintTo(bb, x, y)
        local W, H = Screen:getWidth(), Screen:getHeight()
        if self.dimen and (self.dimen.w ~= W or self.dimen.h ~= H) and not self._resize_pending then
            self._resize_pending = true
            UIManager:nextTick(function()
                self._resize_pending = nil
                self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
                if self.rebuild then self:rebuild() else self:build() end
                -- the whole screen: a popup (the sheet) moved, and what was under its old place
                -- must be drawn again too
                UIManager:setDirty("all", "full")
            end)
        end
        InputContainer.paintTo(self, bb, x, y)
    end
end
Core.Page.watchResize(AnnotationSheet) -- the sheet follows a rotation
-- ✕ on a sub page: close it and every page under it, back to the list.
function Core.Page.exitAll(w)
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
-- Which rows go on which page: { first, last } per page (rows 1..fixed on every page). A heading
-- (keep_with_next) never ends a page; a block taller than a page is split into its rows, which
-- gives a new rows list (returned as the second value).
-- Pieces shared by the full-screen pages (P: side padding, inner: width between the paddings).
-- a thin grey line between rows
function Core.Page.rowLine(P, inner)
    return HorizontalGroup:new{ HorizontalSpan:new{ width = P },
        LineWidget:new{ dimen = Geom:new{ w = inner, h = Size.line.thin }, background = COLORS.line_light } }
end
-- a widget indented by P, with space above and below
function Core.Page.padded(widget, P, top, bottom)
    local g = VerticalGroup:new{ align = "left", VerticalSpan:new{ width = top or 0 } }
    if Core.Page.isColumn(widget) then -- each row indented on its own, so a tall column can be split over pages
        for k = 1, #widget do table.insert(g, HorizontalGroup:new{ HorizontalSpan:new{ width = P }, widget[k] }) end
    else
        table.insert(g, HorizontalGroup:new{ HorizontalSpan:new{ width = P }, widget })
    end
    table.insert(g, VerticalSpan:new{ width = bottom or 0 })
    return g
end
-- section titles as in the mockup: small caps-style grey label with a black line under it. Returns
-- a function for one page build (the first title has less space above it).
function Core.Page.sectionBars(P, inner)
    local first_section = true
    return function(text)
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
end
-- A column of rows that can be split over pages: a left-aligned VerticalGroup
function Core.Page.isColumn(r)
    if type(r) ~= "table" or r.align ~= "left" then return false end
    local mt = getmetatable(r)
    while mt and mt.__index do
        if mt.__index == VerticalGroup then return true end
        mt = type(mt.__index) == "table" and getmetatable(mt.__index) or nil
    end
    return false
end
function Core.Page.splitPages(rows, avail, bar_h, fixed_n)
    local n = #rows
    local fixed_h, total = 0, 0
    for i = 1, math.min(fixed_n, n) do fixed_h = fixed_h + rows[i]:getSize().h end
    for i = 1, n do total = total + rows[i]:getSize().h end
    local pages = {}
    if total <= avail then
        pages[1] = { first = 1, last = n }
    else
        local cap = avail - bar_h - fixed_h
        -- a block taller than a page is split into its own rows, so it can't run under the footer
        -- only a column of rows (a VerticalGroup) can be split
        local function splittable(r)
            return r:getSize().h > cap and #r > 1 and Core.Page.isColumn(r)
        end
        local split = false
        for i = fixed_n + 1, n do
            if splittable(rows[i]) then split = true; break end
        end
        if split then
            local flat = {}
            local function add(r)
                if splittable(r) then
                    for k = 1, #r do add(r[k]) end
                else
                    flat[#flat + 1] = r
                end
            end
            for i = 1, n do
                if i <= fixed_n then flat[#flat + 1] = rows[i] else add(rows[i]) end
            end
            rows, n = flat, #flat
        end
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
    return pages, rows
end
function Core.Page.paged(owner, W, avail, rows, opts)
    opts = opts or {}
    local fixed_n = opts.fixed or 0
    local n
    local bar_h = FOOTER_BAR_HEIGHT + Size.line.medium
    local function wrap(g)
        if opts.left then return HorizontalGroup:new{ HorizontalSpan:new{ width = opts.left }, g } end
        return g
    end
    local pages
    pages, rows = Core.Page.splitPages(rows, avail, bar_h, fixed_n)
    n = #rows
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
    local bar = NotesListWidget.navBar{
        width = W, label = string.format("%d / %d", cur, count), has_prev = has_prev, has_next = has_next,
        first = function() go(1) end, prev = function() go(cur - 1) end,
        next = function() go(cur + 1) end, last = function() go(count) end,
        side = Screen:scaleBySize(2),
    }
    -- left / right swipes and page-turn keys also turn the pages. Always left / right, whatever the
    -- list's swipe setting: these pages turn sideways like KOReader's own menus.
    owner.ges_events = owner.ges_events or {}
    owner.ges_events.PagedSwipe = { GestureRange:new{ ges = "swipe",
        range = Geom:new{ x = 0, y = 0, w = W, h = Screen:getHeight() } } }
    owner.onPagedSwipe = function(_self, _args, ges)
        local d = ges and BD.flipDirectionIfMirroredUILayout(ges.direction)
        if d == "west" then
            if has_next then go(cur + 1) end
            return true
        elseif d == "east" then
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
function Core.Page.countText(n, list)
    if list and list:tabKey() == "bookmarks" then
        return n == 1 and _("Show 1 bookmark") or string.format(_("Show %d bookmarks"), n)
    end
    return n == 1 and _("Show 1 annotation") or string.format(_("Show %d annotations"), n)
end

-- Core.States board: loading, no annotations, nothing matches, delete confirmation, export done.
-- Kept in one table (NotesListWidget.States) so the code outside this block can call it.
do -- own scope: keeps the main chunk under Lua's 200-locals limit
NotesListWidget.States = Core.States

-- Text as separate single-line TextWidgets (same rendering as the tabs, so small grey text is
-- not drawn lighter than elsewhere on some devices); centred or left aligned within width.
function Core.States.lines(text, face, width, color, bold, centered)
    local g = VerticalGroup:new{ align = centered and "center" or "left" }
    for _i, l in ipairs((wrapText(text, face, width))) do
        table.insert(g, TextWidget:new{ text = l, face = face, fgcolor = color, bold = bold })
    end
    if not centered then return g end
    return CenterContainer:new{ dimen = Geom:new{ w = width, h = g:getSize().h }, g }
end
function Core.States.title(text, size, width, centered)
    return Core.States.lines(text, getFaceOr(SERIF_FONT, size, "cfont"), width, COLORS.ink, true, centered)
end

-- Popup card: white box with KOReader's window border and rounded corners, at the centre or
-- the bottom. modal: tap outside / Back closes it. toast: never blocks the screen under it
-- (taps go through) and closes itself after `timeout` seconds.
Core.States.Card = InputContainer:extend{
    anchor = "center", build = nil, modal = false, toast = false, timeout = nil, cancel_cb = nil,
    width = nil, pad_h = nil, pad_v = nil, left = nil, top = nil, -- for the ☰ menu: own size and place
}
function Core.States.Card:init()
    local W, H = Screen:getWidth(), Screen:getHeight()
    self.screen_w, self.screen_h = W, H
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
function Core.States.Card:paintTo(bb)
    -- the screen was rotated: build the card again for the new size and place
    if (self.screen_w ~= Screen:getWidth() or self.screen_h ~= Screen:getHeight()) and not self._resize_pending then
        self._resize_pending = true
        UIManager:nextTick(function()
            self._resize_pending = nil
            if not UIManager:isWidgetShown(self) then return end -- closed in the meantime
            -- a card placed by hand (the ☰ menu, the sort card) would be in the wrong place: it closes
            if self.left or self.top then return self:onClose() end
            if self.timeout_cb then UIManager:unschedule(self.timeout_cb) end
            self:init()
            if self.timeout then self:onShow() end
            UIManager:setDirty("all", "full") -- also where the card was before
        end)
    end
    self.box:paintTo(bb, self.box_x, self.box_y)
end
function Core.States.Card:onShow()
    if self.timeout then
        self.timeout_cb = function() UIManager:close(self, "ui", self.dimen) end -- only its own area
        UIManager:scheduleIn(self.timeout, self.timeout_cb)
    end
end
function Core.States.Card:onCloseWidget()
    if self.timeout_cb then UIManager:unschedule(self.timeout_cb) end
end
Core.Page.forwardGestures(Core.States.Card) -- after onShow / onCloseWidget, which it wraps
function Core.States.Card:onTapOutside(_arg, ges)
    if ges and ges.pos and ges.pos:intersectWith(self.dimen) then return true end
    return self:onClose()
end
-- Back, tap outside, Cancel: closes, then cancel_cb (e.g. back to the menu it came from).
function Core.States.Card:onClose()
    local cb = self.cancel_cb
    self.cancel_cb = nil
    UIManager:close(self, "ui")
    if cb then cb() end
    return true
end
-- A choice was made: closes without cancel_cb.
function Core.States.Card:dismiss()
    self.cancel_cb = nil
    return self:onClose()
end
function Core.States.Card:show()
    UIManager:show(self, "ui", self.dimen)
    return self
end

-- Shown over the library while the first open reads the books.
function Core.States.loading()
    local card = Core.States.Card:new{ build = function(w)
        return VerticalGroup:new{ align = "center",
            Core.States.title(_("Loading annotations…"), 17, w, true),
            VerticalSpan:new{ width = Screen:scaleBySize(6) },
            Core.States.lines(_("Reading your books. Only the first time after starting KOReader."),
                Font:getFace("cfont", 13), w, COLORS.muted, false, true),
        }
    end }
    card:show()
    UIManager:forceRePaint()
    return card
end

-- Delete confirmation: shows the highlight that will go, and says when its note goes too.
function Core.States.confirmDelete(note, on_delete)
    local nw = Core.NoteWrapper:new(note)
    local has_text = nw:hasHighlightedText()
    Core.States.Card:new{ modal = true, build = function(w, card)
        local g = VerticalGroup:new{ align = "left" }
        local title = has_text and _("Delete this highlight?") or _("Delete this annotation?")
        if note.bookmark then title = _("Delete this bookmark?") end
        table.insert(g, Core.States.title(title, 17, w))
        if note.bookmark then -- which one: "Page 34 · Chapter Two"
            local where = { NoteItemWidget.pageText(note) }
            if note.chapter and note.chapter ~= "" then table.insert(where, note.chapter) end
            if #where > 0 then
                table.insert(g, VerticalSpan:new{ width = Screen:scaleBySize(6) })
                table.insert(g, Core.States.lines(table.concat(where, " · "), Font:getFace("cfont", 14), w, COLORS.ink, true, false))
            end
        end
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
        table.insert(g, Core.States.lines(nw:hasUserNote()
            and _("Your note on it is deleted too. This can’t be undone.") or _("This can’t be undone."),
            Font:getFace("cfont", 13), w, COLORS.muted, false, false))
        table.insert(g, VerticalSpan:new{ width = Screen:scaleBySize(14) })
        local gap = Screen:scaleBySize(10)
        local bw = math.floor((w - gap) / 2)
        table.insert(g, HorizontalGroup:new{
            Core.Page.button(_("Cancel"), false, bw, function() card:onClose() end),
            HorizontalSpan:new{ width = gap },
            Core.Page.button(_("Delete"), true, w - gap - bw, function() card:onClose(); on_delete() end),
        })
        return g
    end }:show()
end

-- Core.Export done: a note at the bottom that closes itself; the list under it stays usable.
-- path: the file, or the folder when there are several files; copied: put on the clipboard instead.
function Core.States.exported(count, path, bookmarks, n_files, copied)
    local rel = path
    local ok, DataStorage = pcall(require, "datastorage")
    if ok and path then
        local dir = DataStorage:getDataDir()
        local name = dir:match("([^/\\]+)[/\\]*$")
        if not name or name == "." then name = "koreader" end
        if path:sub(1, #dir) == dir then rel = name .. path:sub(#dir + 1) end
    end
    Core.States.Card:new{ anchor = "bottom", toast = true, timeout = 5, build = function(w)
        local icon_s = Screen:scaleBySize(18)
        local gap = Screen:scaleBySize(8)
        local title
        if copied then
            title = bookmarks and (count == 1 and _("Copied 1 bookmark") or string.format(_("Copied %d bookmarks"), count))
                or (count == 1 and _("Copied 1 annotation") or string.format(_("Copied %d annotations"), count))
        else
            title = count == 1 and _("Exported 1 annotation") or string.format(_("Exported %d annotations"), count)
            if bookmarks then
                title = count == 1 and _("Exported 1 bookmark") or string.format(_("Exported %d bookmarks"), count)
            end
        end
        local sub = rel
        if copied then sub = _("to the clipboard")
        elseif n_files and n_files > 1 then
            -- Lua 5.1 has no positional arguments, so every translation keeps this order
            sub = string.format(_("%d files in %s"), n_files, tostring(rel))
        end
        return VerticalGroup:new{ align = "left",
            HorizontalGroup:new{ align = "center",
                IconWidget:new{ icon = "check", width = icon_s, height = icon_s },
                HorizontalSpan:new{ width = gap },
                TextWidget:new{ text = title, face = Font:getFace("cfont", 15), bold = true, max_width = w - icon_s - gap } },
            VerticalSpan:new{ width = Screen:scaleBySize(6) },
            TextWidget:new{ text = tostring(sub or ""), face = Font:getFace("cfont", 12), fgcolor = COLORS.muted, max_width = w },
        }
    end }:show()
end

-- The ☰ menu: a card under the button with an icon, a label and a short status on each row.
-- (Filters and sort are behind the funnel button and the tab row.)
function Core.States.menu(list)
    local W = Screen:getWidth()
    local af = list.active_filter or {}
    local items = {}
    if not list.single_book then
        local n_books = list:offeredCount("books", "books_exclude", NotesListWidget.bookKeys)
        local filtered = (af.books and next(af.books)) or (af.books_exclude and next(af.books_exclude))
        table.insert(items, { icon = "book.opened", label = _("Books"),
            value = filtered and _("Filtered") or string.format(_("All %d"), n_books),
            cb = function() list:showBookPicker(function() end) end })
    end
    -- Review mode sits right under Books (both are about what the list shows), so it is found
    -- without hunting through Settings. The eye in the top bar switches it on and off.
    table.insert(items, { icon = "appbar.review", file = pluginIcon("appbar.review"),
        label = _("Review mode"), chevron = true,
        value = list.review_on and _("On") or NotesListWidget.reviewStylesSummary(),
        cb = function() UIManager:show(NotesListWidget.SettingsScreen:new{ list = list, page = "review" }, "flashui") end })
    if #items > 0 then table.insert(items, "line") end -- (no line at the top of the one-book menu)
    table.insert(items, { icon = "move.up", label = _("Export"), chevron = true,
        value = string.format(_("%d shown"), #(list.filtered_notes or {})), cb = function() list:showExportPage() end })
    table.insert(items, { icon = "cre.render.reload", label = _("Reload annotations"),
        cb = function() list.viewer:reloadAnnotations(list) end })
    table.insert(items, "line")
    table.insert(items, { icon = "appbar.settings", label = _("Settings"), chevron = true,
        cb = function() list:showSettingsMenu() end })
    local bw = Size.border.window
    Core.States.Card:new{ modal = true, width = math.min(Screen:scaleBySize(330), W - Screen:scaleBySize(20)),
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
                    -- it.file: one of the plugin's own icons (icons/<name>.svg), else a KOReader icon name
                    local icon
                    if it.file and lfs.attributes(it.file, "mode") == "file" then
                        icon = IconWidget:new{ file = it.file, width = icon_s, height = icon_s }
                    else
                        icon = IconWidget:new{ icon = it.icon, width = icon_s, height = icon_s }
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

-- Sort order as a dropdown card under the sort label: up to three levels (sort by, then by, then by).
-- Each level is a row of chips for the keys that still make sense plus a two-part bar for the
-- direction, and a sentence at the bottom says in words what the order is.
-- Sort chips as wide as their text; each row is filled to the edge by sharing out what is left.
-- items = { { label, on, callback } }; the chosen one gets a thick black outline.
function Core.States.sortChips(g, side, inner, items)
    local thin, thick = Size.border.button, Size.border.thick
    local gap = Screen:scaleBySize(8)
    local chip_h = Screen:scaleBySize(36)
    local face = Font:getFace("cfont", 13)
        local widths = {}
    for i, it in ipairs(items) do
        widths[i] = TextWidget:new{ text = it.label, face = face, bold = true }:getSize().w + Screen:scaleBySize(26)
    end
    local rows, row, row_w = {}, {}, 0
    for i in ipairs(items) do
        if #row > 0 and row_w + gap + widths[i] > inner then
            rows[#rows + 1] = row; row, row_w = {}, 0
        end
        row_w = row_w + (#row > 0 and gap or 0) + widths[i]
        row[#row + 1] = i
    end
    if #row > 0 then rows[#rows + 1] = row end
    for _, r in ipairs(rows) do
        local used = (#r - 1) * gap
        for _, i in ipairs(r) do used = used + widths[i] end
        -- rows may stretch to the edge, but a chip never gets narrower than its text. One wider
        -- than the row says so (the sort card then uses the menu); on the full pages it gets the
        -- whole row, as wide as it can be on the screen.
        local extra, rg = math.max(0, inner - used), HorizontalGroup:new{ HorizontalSpan:new{ width = side } }
        for k, i in ipairs(r) do
            local it = items[i]
            if widths[i] > inner then Core.States.chip_overflow = true end
            local cw = math.min(inner, widths[i] + math.floor(extra / #r) + (k == #r and extra % #r or 0))
            local color = BlitBuffer.COLOR_BLACK
            if k > 1 then table.insert(rg, HorizontalSpan:new{ width = gap }) end
            table.insert(rg, TapBox:new{
                Pill:new{ width = cw, height = chip_h, fill = BlitBuffer.COLOR_WHITE,
                    border = it.on and thick or thin, border_color = it.on and COLORS.ink or COLORS.line,
                    TextWidget:new{ text = it.label, face = face, bold = it.on, fgcolor = color,
                        max_width = cw - Screen:scaleBySize(8) } },
                callback = it.callback })
        end
        table.insert(g, rg)
        table.insert(g, VerticalSpan:new{ width = gap })
    end
end

-- The Sort by / Then by / And then by rows: per level a row of key chips (as wide as their text,
-- each row filled to the edge; the chosen one has a thick black outline) and a two-part direction
-- bar. Used by the sort card and by the Filter & sort page. Appends to group g.
-- o = { width, side, single, levels, apply = function(new_levels), heading = function(text) }
function Core.States.sortLevels(g, o)
    local side, inner, single, levels = o.side, o.width, o.single, o.levels
    local thin = Size.border.button
    local bar_h = Screen:scaleBySize(38)
    local face = Font:getFace("cfont", 13)
    local heading = o.heading
    local function chipRows(items) Core.States.sortChips(g, side, inner, items) end
    -- two joined halves in one outline, the chosen one black
    local function directionBar(lv, on_flip)
        local cell_h = bar_h
        local cell_w = math.floor((inner - thin * 2 - thin) / 2)
        local cells = {}
        for _, dir in ipairs({ "asc", "desc" }) do
            local on = lv.dir == dir
            if lv.key == "date" or lv.key == "opened" then dir = dir == "asc" and "desc" or "asc"; on = lv.dir == dir end
            table.insert(cells, TapBox:new{
                FrameContainer:new{ bordersize = 0, padding = 0, margin = 0,
                    background = on and BlitBuffer.COLOR_BLACK or BlitBuffer.COLOR_WHITE,
                    CenterContainer:new{ dimen = Geom:new{ w = cell_w, h = cell_h },
                        TextWidget:new{ text = Core.SortState.dirName(lv.key, dir, single), face = face, bold = on,
                            max_width = cell_w - Screen:scaleBySize(8),
                            fgcolor = on and BlitBuffer.COLOR_WHITE or BlitBuffer.COLOR_BLACK } } },
                callback = function() if not on then on_flip() end end })
        end
        local seg = HorizontalGroup:new{}
        for i, c in ipairs(cells) do
            if i > 1 then table.insert(seg, LineWidget:new{ dimen = Geom:new{ w = thin, h = cell_h }, background = BlitBuffer.COLOR_BLACK }) end
            table.insert(seg, c)
        end
        table.insert(g, HorizontalGroup:new{ HorizontalSpan:new{ width = side },
            RoundedOutline:new{ radius = Screen:scaleBySize(8), border = thin, seg } })
    end
    local titles = { _("Sort by"), _("Then by"), _("And then by") }
    for n = 1, 3 do
        local prev = levels[n - 1]
        local allowed = Core.SortState.allowedAfter(prev, single)
        if (n == 1 or prev) and #allowed > 0 then
            heading(titles[n])
            local lv = levels[n]
            local function upto(k)
                local c = {}
                for x = 1, k do c[x] = levels[x] end
                return c
            end
            local keys = {}
            if n > 1 then keys[1] = { label = _("None"), on = lv == nil, callback = function() if lv then o.apply(upto(n - 1)) end end } end
            for _, k in ipairs(allowed) do
                keys[#keys + 1] = { label = Core.SortState.keyName(k, single), on = lv ~= nil and lv.key == k,
                    callback = function()
                        if lv and lv.key == k then return end
                        local c = upto(n - 1)
                        c[n] = { key = k, dir = (k == "date" or k == "opened") and "desc" or "asc" }
                        for x = n + 1, #levels do c[x] = levels[x] end
                        o.apply(c)
                    end }
            end
            chipRows(keys)
            if lv then
                directionBar(lv, function()
                    local c = upto(#levels)
                    c[n] = { key = lv.key, dir = lv.dir == "asc" and "desc" or "asc" }
                    o.apply(c)
                end)
            end
        end
    end
end

-- The usual orders, one tap each: on the sort card and on the Sort page.
function Core.States.quickPicks(single)
    return single and Core.SortState.QUICK_BOOK or {
        { _("Newest"), "date:desc" }, { _("Oldest"), "date:asc" }, { _("Book A–Z"), "book:asc" },
        { _("Author A–Z"), "author:asc" }, { _("Last opened book"), "opened:desc" },
        { _("In book order"), "book:asc,pos:asc" },
    }
end
function Core.States.sortMenu(list, on_done)
    local W = Screen:getWidth()
    local single = list.single_book
    local current = Core.SortState.get(single)
    local levels = Core.SortState.view(current, single)
    local function apply(new_levels, card)
        card:onClose()
        Core.SortState.set(single, Core.SortState.encode(Core.SortState.revalidate(new_levels, single)))
        list:applySort()
        list:refresh()
        if on_done then on_done() end
        Core.States.sortMenu(list, on_done)
    end
    local quick = Core.States.quickPicks(single)
    local card_w = math.min(Screen:scaleBySize(360), W - Screen:scaleBySize(20))
    local bw = Size.border.window
    local too_tall = false
    local sort_card = Core.States.Card:new{ modal = true, width = card_w,
        left = W - card_w - Screen:scaleBySize(10),
        top = list.topbar_height + Screen:scaleBySize(4),
        pad_h = bw, pad_v = bw + Screen:scaleBySize(4),
        build = function(w, card)
            -- tier 0: everything; 1: without the quick picks; 2: also without the sentence.
            -- (The chips themselves never change size.)
            -- The first tier that fits the screen is used.
            local function make(tier, lvls)
            local levels = lvls or levels
            local g = VerticalGroup:new{ align = "left" }
            local side = Screen:scaleBySize(16)
            local inner = w - side * 2
            local thin = Size.border.button
            local function heading(text)
                table.insert(g, VerticalSpan:new{ width = Screen:scaleBySize(10) })
                table.insert(g, HorizontalGroup:new{ HorizontalSpan:new{ width = side },
                    TextWidget:new{ text = text:upper(), face = Font:getFace("cfont", 11), bold = true, fgcolor = COLORS.muted } })
                table.insert(g, VerticalSpan:new{ width = Screen:scaleBySize(4) })
            end
            local encoded = Core.SortState.encode(levels)
            if tier < 1 then
                heading(_("Quick picks"))
                local items = {}
                for _, q in ipairs(quick) do
                    items[#items + 1] = { label = q[1], on = Core.SortState.encode(Core.SortState.parse(q[2])) == encoded,
                        callback = function() apply(Core.SortState.parse(q[2]), card) end }
                end
                Core.States.sortChips(g, side, inner, items)
                -- a line between the usual orders and building your own
                table.insert(g, VerticalSpan:new{ width = Screen:scaleBySize(4) })
                table.insert(g, HorizontalGroup:new{ HorizontalSpan:new{ width = side },
                    LineWidget:new{ dimen = Geom:new{ w = inner, h = Size.line.medium }, background = COLORS.line } })
                table.insert(g, VerticalSpan:new{ width = Screen:scaleBySize(2) })
            end
            Core.States.sortLevels(g, { width = inner, side = side, single = single, levels = levels,
                heading = heading, apply = function(c) apply(c, card) end })
            if tier < 2 then
                table.insert(g, VerticalSpan:new{ width = Screen:scaleBySize(12) })
                table.insert(g, HorizontalGroup:new{ HorizontalSpan:new{ width = side },
                    FrameContainer:new{ bordersize = thin, color = COLORS.line, radius = Screen:scaleBySize(8),
                        padding = Screen:scaleBySize(8), margin = 0,
                        TextBoxWidget:new{ text = Core.SortState.describe(levels, single), face = Font:getFace("cfont", 13),
                            width = inner - Screen:scaleBySize(16) - thin * 2 } } })
            end
            table.insert(g, VerticalSpan:new{ width = Screen:scaleBySize(6) })
            return g
            end
            local avail = Screen:getHeight() - list.topbar_height - Screen:scaleBySize(20) - (bw + Screen:scaleBySize(4)) * 2
            -- Which version to use is decided on the fullest card there can be (three levels, all
            -- with a direction), so picking a different order never swaps the card for the menu or back.
            local fullest = Core.SortState.parse(single and "chapter:asc,date:desc,pos:asc" or "author:asc,book:asc,pos:asc")
            local use = 2
            for tier = 0, 2 do
                if make(tier, fullest):getSize().h <= avail then use = tier; break end
            end
            local g = make(use)
            Core.States.chip_overflow = false
            if make(use, fullest):getSize().h > avail then too_tall = true end
            -- a chip wider than the card (big font, narrow screen): the menu, as chips never shrink
            if Core.States.chip_overflow then too_tall = true end
            return g
        end }
    -- still too tall for this screen: a plain menu instead (one row per level)
    if too_tall then Core.States.sortList(list, on_done) else sort_card:show() end
end

-- The sort order as a menu, for screens too small for the chip card: a row per level that opens a
-- list of keys, and a row under it that flips the direction.
-- on_cancel: Back / tap outside (the sort menu opens again)
function Core.States.chooseCard(list, title, options, on_cancel)
    local W = Screen:getWidth()
    local card_w = math.min(Screen:scaleBySize(360), W - Screen:scaleBySize(20))
    local bw = Size.border.window
    Core.States.Card:new{ modal = true, width = card_w, cancel_cb = on_cancel,
        left = W - card_w - Screen:scaleBySize(10), top = list.topbar_height + Screen:scaleBySize(4),
        pad_h = bw, pad_v = bw + Screen:scaleBySize(4),
        build = function(w, card)
            local g = VerticalGroup:new{ align = "left" }
            local side = Screen:scaleBySize(16)
            table.insert(g, HorizontalGroup:new{ HorizontalSpan:new{ width = side },
                TextWidget:new{ text = title:upper(), face = Font:getFace("cfont", 11), bold = true, fgcolor = COLORS.muted } })
            table.insert(g, VerticalSpan:new{ width = Screen:scaleBySize(4) })
            for _, o in ipairs(options) do
                local d = Geom:new{ w = w - side * 2, h = Screen:scaleBySize(46) }
                table.insert(g, HorizontalGroup:new{ HorizontalSpan:new{ width = side }, TapBox:new{
                    LeftContainer:new{ dimen = d, TextWidget:new{ text = (o.on and "✓ " or "") .. o.label,
                        face = Font:getFace("cfont", 15), bold = o.on, max_width = d.w } },
                    callback = function() card:dismiss(); o.callback() end } })
            end
            return g
        end }:show()
end
function Core.States.sortList(list, on_done)
    local W = Screen:getWidth()
    local single = list.single_book
    local levels = Core.SortState.view(Core.SortState.get(single), single)
    local function apply(new_levels)
        Core.SortState.set(single, Core.SortState.encode(Core.SortState.revalidate(new_levels, single)))
        list:applySort()
        list:refresh()
        if on_done then on_done() end
        Core.States.sortList(list, on_done)
    end
    local function upto(k)
        local c = {}
        for x = 1, k do c[x] = levels[x] end
        return c
    end
    local card_w = math.min(Screen:scaleBySize(360), W - Screen:scaleBySize(20))
    local bw = Size.border.window
    local quick = Core.States.quickPicks(single)
    Core.States.Card:new{ modal = true, width = card_w,
        left = W - card_w - Screen:scaleBySize(10), top = list.topbar_height + Screen:scaleBySize(4),
        pad_h = bw, pad_v = bw + Screen:scaleBySize(4),
        build = function(w, card)
            local g = VerticalGroup:new{ align = "left" }
            local side = Screen:scaleBySize(16)
            local inner = w - side * 2
            local function row(label, value, callback)
                local d = Geom:new{ w = inner, h = Screen:scaleBySize(46) }
                table.insert(g, HorizontalGroup:new{ HorizontalSpan:new{ width = side }, TapBox:new{
                    OverlapGroup:new{ dimen = d, allow_mirroring = false,
                        LeftContainer:new{ dimen = d, TextWidget:new{ text = label, face = Font:getFace("cfont", 15),
                            max_width = math.floor(inner * 0.4) } },
                        RightContainer:new{ dimen = d, TextWidget:new{ text = value, face = Font:getFace("cfont", 14), bold = true,
                            max_width = math.floor(inner * 0.58) } } },
                    callback = function() card:dismiss(); callback() end } })
                table.insert(g, HorizontalGroup:new{ HorizontalSpan:new{ width = side },
                    LineWidget:new{ dimen = Geom:new{ w = inner, h = Size.line.thin }, background = COLORS.line_light } })
            end
            row(_("Quick picks"), sortModeLabel(Core.SortState.get(single), single) .. " ›", function()
                local opts, now = {}, Core.SortState.encode(levels)
                for _, q in ipairs(quick) do
                    opts[#opts + 1] = { label = q[1], on = Core.SortState.encode(Core.SortState.parse(q[2])) == now,
                        callback = function() apply(Core.SortState.parse(q[2])) end }
                end
                Core.States.chooseCard(list, _("Quick picks"), opts, function() Core.States.sortList(list, on_done) end)
            end)
            local titles = { _("Sort by"), _("Then by"), _("And then by") }
            for n = 1, 3 do
                local prev = levels[n - 1]
                local allowed = Core.SortState.allowedAfter(prev, single)
                if (n == 1 or prev) and #allowed > 0 then
                    local lv = levels[n]
                    row(titles[n], (lv and Core.SortState.keyName(lv.key, single) or _("None")) .. " ›", function()
                        local opts = {}
                        if n > 1 then
                            opts[1] = { label = _("None"), on = lv == nil, callback = function() apply(upto(n - 1)) end }
                        end
                        for _, k in ipairs(allowed) do
                            opts[#opts + 1] = { label = Core.SortState.keyName(k, single), on = lv ~= nil and lv.key == k,
                                callback = function()
                                    if lv and lv.key == k then return Core.States.sortList(list, on_done) end
                                    local c = upto(n - 1)
                                    c[n] = { key = k, dir = (k == "date" or k == "opened") and "desc" or "asc" }
                                    for x = n + 1, #levels do c[x] = levels[x] end
                                    apply(c)
                                end }
                        end
                        Core.States.chooseCard(list, titles[n], opts, function() Core.States.sortList(list, on_done) end)
                    end)
                    if lv then
                        row("", Core.SortState.dirName(lv.key, lv.dir, single) .. " ⇅", function()
                            local c = upto(#levels)
                            c[n] = { key = lv.key, dir = lv.dir == "asc" and "desc" or "asc" }
                            apply(c)
                        end)
                    end
                end
            end
            table.insert(g, VerticalSpan:new{ width = Screen:scaleBySize(6) })
            return g
        end }:show()
end

-- Centre of the list when filters (or the tab) leave nothing: what happened, and one tap to undo.
function Core.States.noMatch(list, width, height)
    local filtered = #list:getFilterChips() > 0
    local col_w = math.min(width, math.floor(Screen:getHeight() * 1.1)) - Screen:scaleBySize(22) * 2
    if #(list.notes_list or {}) == 0 then
        -- no annotations at all: the list's own title bar stays, the body explains
        local icon_s = Screen:scaleBySize(44)
        return CenterContainer:new{ dimen = Geom:new{ w = width, h = height }, VerticalGroup:new{ align = "center",
            IconWidget:new{ icon = "edit", width = icon_s, height = icon_s },
            VerticalSpan:new{ width = Screen:scaleBySize(12) },
            Core.States.title(_("No annotations yet"), 18, col_w, true),
            VerticalSpan:new{ width = Screen:scaleBySize(10) },
            Core.States.lines(list.single_book and _("Highlight a passage in this book and it shows up here.")
                or _("Highlight a passage in any book and it shows up here."),
                Font:getFace("cfont", 13), col_w, COLORS.muted, false, true),
        } }
    end
    local g = VerticalGroup:new{ align = "center",
        Core.States.title(filtered and _("Nothing matches") or _("Nothing here"), 18, col_w, true),
        VerticalSpan:new{ width = Screen:scaleBySize(12) },
    }
    local hidden = list.tab_totals and list.tab_totals[list:tabKey()] or #(list.notes_list or {})
    local bm_tab = list:tabKey() == "bookmarks"
    local body = bm_tab and _("No bookmarks in this view.") or _("No annotations in this view.")
    if filtered then
        body = (bm_tab and _("No bookmarks fit these filters.") or _("No annotations fit these filters.")) .. " "
            .. (hidden == 1 and _("1 is hidden.") or string.format(_("%d are hidden."), hidden))
    end
    table.insert(g, Core.States.lines(body, Font:getFace("cfont", 13 + getSettingsFontShift()), col_w, COLORS.muted, false, true))
    if filtered then
        table.insert(g, VerticalSpan:new{ width = Screen:scaleBySize(14) })
        table.insert(g, Core.Page.button(_("Clear filters"), true, Screen:scaleBySize(170), function() list:clearFilters() end))
    end
    return CenterContainer:new{ dimen = Geom:new{ w = width, h = height }, g }
end

end

-- The Filter & sort and Settings screens live in settings.lua.
local SettingsScreens = require("settings")

-- Font list behind the three font rows of Settings: a sample line in the chosen font on top
-- (fixed height, so the page does not jump between fonts), then every font to tap.

-- Full-screen picker for Books, Chapters and Tags (BookFilter / ChapterFilter boards).
-- Books, Chapters and Tags: the same "Only these" / "Hide these" switch and checkboxes. A tap marks
-- an item with the switch's side (✓ only, ✕ hide) or clears it.
-- Changes count live ("Show N annotations"); Cancel / ‹ / ✕ put the filter back.

-- Sort page, opened from the Sort row on Filter & sort: the page frame of the Books / Tags pickers
-- (same header, footer and paging) around the sort card's levels: per level a row of key chips and
-- a two-part direction bar, and the order in words underneath. Then by / And then by appear when
-- the level before allows them.
-- Changes show straight away; Cancel / ‹ / ✕ put the old order back.

-- The pickers count what the open tab is about: bookmarks on the Bookmarks tab, annotations
-- (highlights and notes) on the others. An item with nothing of that kind is left out, unless it
-- is already ticked (so it can still be unticked).
-- How many entries a picker offers on this tab (what pickerItems keeps): values with something on
-- this tab, plus the ones chosen in the filter. keysOf(note) gives a note's values. Used for the
-- "N of M" / "All M" on Filter & sort and the ☰ menu, so they match the picker.
function NotesListWidget.bookKeys(n) return { n.book_title or _("Unknown") } end
-- kind: "authors", "series" or "languages"

function AllNotesViewer:showNoteDetails(note, parent_widget)
    UIManager:show(AnnotationSheet:new{ note = note, viewer = self, parent_widget = parent_widget }, "ui")
end
end
function AllNotesViewer:showColorPicker(note, parent_widget)
    local RadioButtonWidget = require("ui/widget/radiobuttonwidget")
        local colors = {}
        for _, v in ipairs(ReaderHighlight.highlight_colors) do
            if v[2] ~= "gray" then
                table.insert(colors, { v[2], NoteItemWidget.colorLabel(v[2]), COLORS.highlightCode(v[2]) })
            end
        end
        table.insert(colors, { "gray", NoteItemWidget.colorLabel("gray"), BlitBuffer.COLOR_GRAY })
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
    -- no list: the change was made after the list had to close to open the book
    if type(parent_widget) ~= "table" or type(parent_widget.notes_list) ~= "table" then return end
    for i, n in ipairs(parent_widget.notes_list) do
        if n == note or (n.book_path == note.book_path and itemMatchesNote(
                { datetime = n.datetime, text = n.highlighted_text, pos0 = n.pos0, pos1 = n.pos1,
                  page = n.page, drawer = n.drawer }, note)) then
            fn(n, i)
            break
        end
    end
    parent_widget:refresh()
end

-- A note from a book still in KOReader's old format can't be changed until KOReader has opened
-- the book once (it converts the file then). Says so and returns true. An open book is already
-- converted in memory, so changes go through KOReader as usual.
-- The editing operations (open the book, write style / colour / note / delete, and the
-- custom-cover editors) live in edit.lua; copy them onto the plugin as methods.
for _name, _fn in pairs(require("edit")) do AllNotesViewer[_name] = _fn end

-- Internals exposed for tests/run.lua; KOReader doesn't use this.
AllNotesViewer._test = {
    wrapText = wrapText,
    normalizeBookTitle = normalizeBookTitle,
    SORT_COMPARATORS = SORT_COMPARATORS,
    SortState = Core.SortState,
    filterToString = NoteItemWidget.filterToString,
    sortModeLabel = NotesListWidget.sortModeLabel,
    compareByPosition = compareByPosition,
    itemMatchesNote = Core.itemMatchesNote,
    legacyNotes = AllNotesViewer.legacyNotes,
    samePath = AllNotesViewer.samePath,
    getSidecarKey = Core.getSidecarKey,
    normalizeColorStyle = normalizeColorStyle,
    ReaderHighlight = ReaderHighlight,
    UIManager = UIManager,
    COLORS = COLORS,
    readSidecar = AllNotesViewer.readSidecar,
    DocSettings = DocSettings,
    notesToMarkdown = Core.Export.notesToMarkdown,
    Export = Core.Export,
    setSetting = setSetting,
    getSetting = getSetting,
    NotesListWidget = NotesListWidget,
    NoteItemWidget = NoteItemWidget,
    listNote = AllNotesViewer.listNote,
    splitTags = AllNotesViewer.splitTags,
}

AllNotesViewer.updateListedNote = updateListedNote
return AllNotesViewer