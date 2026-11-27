--[[--
Shared state and helpers for annotationsviewer.koplugin.

These used to be `local`s at the top of main.lua. They live here because the parts of the plugin
in other files all need the same values, and because main.lua is at Lua's 200-locals-per-chunk
limit — moving a definition out gives the chunk room for the code that stays in it.

main.lua keeps thin aliases (`local Page = Core.Page` and the like) so the code that uses them
did not have to change.
]]

local BlitBuffer = require("ffi/blitbuffer")
local Screen = require("device").screen
local Font = require("ui/font")

local Util = require("avutil")
local _ = require("ano_i18n").gettext
local logger = require("logger")
local ReaderHighlight = require("apps/reader/modules/readerhighlight")
local lfs = require("libs/libkoreader-lfs")
local DocSettings = require("docsettings")
local DataStorage = require("datastorage")

-- Names this file calls that live in another module.
local HIGHLIGHT_COLORS = BlitBuffer.HIGHLIGHT_COLORS

local Core = {}


-- The plugin's own settings file: fonts, margins, review mode, picked words, questions. These
-- are display choices only; nothing here is ever written into a book's sidecar.
Core.G = require("luasettings"):open(
    require("datastorage"):getSettingsDir() .. "/annotationsviewer.lua")

-- Default sizes and spacing, as the Settings pages show them.
Core.DEFAULT_CONTENT_FONT_SIZE = 16
Core.DEFAULT_TITLE_FONT_SIZE = 22
Core.DEFAULT_INFO_FONT_SIZE = 15
Core.DEFAULT_H_MARGIN = 50
Core.DEFAULT_NOTE_SPACING = 30
Core.DEFAULT_TEXT_MARGIN = 0
Core.DEFAULT_TRUNCATE_LINES = 5
Core.DEFAULT_TITLE_MARGIN = 8
Core.DEFAULT_INFO_MARGIN = 6
Core.DEFAULT_TOP_PADDING = 16

-- A no-break space, as UTF-8. Books often leave these around a highlighted line.
local NBSP = "\194\160"

-- The palette: `ink` and `muted` are the two text weights, the rest are rules and fills.
Core.COLORS = {
    ink        = BlitBuffer.COLOR_BLACK,
    muted      = BlitBuffer.Color8(0x45), -- secondary text: tabs, info line, author, counts
    disabled   = BlitBuffer.Color8(0xAA), -- buttons that can't be used
    line       = BlitBuffer.Color8(0xBD), -- separators
    line_light = BlitBuffer.Color8(0xD6), -- row lines, line under book titles
    section_bg = BlitBuffer.Color8(0xE9), -- section bars in Filter & sort
    section_fg = BlitBuffer.Color8(0x33),
}

-- Bars and icons, worked out once from the screen DPI.
Core.TOPBAR_HEIGHT = Screen:scaleBySize(50)
Core.HEADER_ICON_SIZE = Screen:scaleBySize(22)
Core.HEADER_ICON_PAD = Screen:scaleBySize(11)
Core.CHIP_GAP = Screen:scaleBySize(8)
-- Extra space above a book title that is not at the top of the page.
Core.BOOK_GAP = Screen:scaleBySize(14)
Core.PLUGIN_DIR = (debug.getinfo(1, "S").source or ""):match("^@(.*/)[^/]*$") or "./"
Core.SB_STRIP_WIDTH = Screen:scaleBySize(26)
Core.SB_MARGIN_RIGHT = Screen:scaleBySize(10)

-- The serif face used for titles, highlights and the screen title unless the reader picked one.
Core.SERIF_FONT = "NotoSerif-Regular.ttf"

-- The shared helper tables. They start empty and the code that owns each one fills it in.
Core.SortState = { opened = {}, cache = {} }
-- The old fixed sort names, translated to rules, and the keys a rule may use.
Core.SortState.LEGACY = {
    date_newest = "date:desc", date_oldest = "date:asc",
    author_asc = "author:asc", author_desc = "author:desc",
    author_location_asc = "author:asc,book:asc,pos:asc", author_location_desc = "author:asc,book:asc,pos:desc",
    book_asc = "book:asc", book_desc = "book:desc",
    book_location_asc = "book:asc,pos:asc", book_location_desc = "book:asc,pos:desc",
    filename_asc = "file:asc", filename_desc = "file:desc",
    filename_location_asc = "file:asc,pos:asc", filename_location_desc = "file:asc,pos:desc",
    opened_recent = "opened:desc", opened_oldest = "opened:asc",
}
Core.SortState.KEYS = { date = true, opened = true, author = true, book = true, file = true,
    pos = true, chapter = true }
Core.NoteWrapper = {}
Core.Export = {}
Core.Page = {}
Core.States = {}

-- A setting from the plugin's own file. LuaSettings stores the truthy/falsey value as given, so
-- booleans come back as booleans and sizes as numbers.
function Core.getSetting(key, default)
    local val = Core.G:readSetting("annotationsviewer_" .. key)
    if val == nil then return default end
    if type(default) == "number" then
        local nval = tonumber(val)
        if nval == nil then return default end
        return nval
    end
    return val
end

-- Save and flush in one call: saveSetting only changes memory, and a setting that is not flushed
-- is lost when KOReader exits.
function Core.setSetting(key, value)
    Core.G:saveSetting("annotationsviewer_" .. key, value)
    Core.G:flush()
end

-- A face by name and size, falling back when the font is missing or the name is empty.
function Core.getFaceOr(font_name, size, fallback)
    return (font_name and font_name ~= "" and Font:getFace(font_name, size))
        or Font:getFace(fallback, size) or Font:getFace("cfont", size)
end

function Core.getContentFontSize()
    local v = Core.getSetting("content_font_size", Core.DEFAULT_CONTENT_FONT_SIZE)
    v = tonumber(v)
    if not v or v <= 0 then return Core.DEFAULT_CONTENT_FONT_SIZE end
    return v
end

function Core.getTitleFontSize()
    local v = Core.getSetting("title_font_size", Core.DEFAULT_TITLE_FONT_SIZE)
    v = tonumber(v)
    if not v or v <= 0 then return Core.DEFAULT_TITLE_FONT_SIZE end
    return v
end

function Core.getInfoFontSize()
    local v = Core.getSetting("info_font_size", Core.DEFAULT_INFO_FONT_SIZE)
    v = tonumber(v)
    if not v or v <= 0 then return Core.DEFAULT_INFO_FONT_SIZE end
    return v
end

function Core.getHMargin() return Screen:scaleBySize(Core.getSetting("h_margin", Core.DEFAULT_H_MARGIN)) end

function Core.getSettingsFontShift()
    local v = tonumber(Core.getSetting("settings_font_shift", 0))
    if not v then return 0 end
    if v < -3 then return -3 end
    if v > 9 then return 9 end
    return math.floor(v)
end

function Core.getNoteSpacing() return Screen:scaleBySize(Core.getSetting("note_spacing", Core.DEFAULT_NOTE_SPACING)) end

function Core.getTextMargin() return Screen:scaleBySize(Core.getSetting("text_margin", Core.DEFAULT_TEXT_MARGIN)) end

function Core.getTruncateLines()
    return Core.getSetting("truncate_lines", Core.DEFAULT_TRUNCATE_LINES)
end

function Core.getJustify() return Core.getSetting("justify", false) end

function Core.getTitleMargin() return Screen:scaleBySize(Core.getSetting("title_margin", Core.DEFAULT_TITLE_MARGIN)) end

function Core.getInfoMargin() return Screen:scaleBySize(Core.getSetting("info_margin", Core.DEFAULT_INFO_MARGIN)) end

function Core.getTitleFont() return Core.getSetting("title_font", nil) end

function Core.getInfoFont() return Core.getSetting("info_font", nil) end

function Core.getContentFont() return Core.getSetting("content_font", nil) end

function Core.getShowTotalNotes() return Core.getSetting("show_total", true) end

function Core.getTopPadding() return Screen:scaleBySize(Core.getSetting("top_padding", Core.DEFAULT_TOP_PADDING)) end

function Core.getHideDupTitle() return Core.getSetting("hide_dup_title", true) ~= false end

function Core.getHideDupInfo() return Core.getSetting("hide_dup_info", true) ~= false end

function Core.getSwipeSetting() return Core.getSetting("swipe_direction", "both") end

function Core.getTapSetting() return Core.getSetting("tap_action", "goto") == "card" and "card" or "goto" end

function Core.getHoldSetting() return Core.getSetting("hold_action", "card") == "goto" and "goto" or "card" end

-- Review mode covers the styles ticked in Settings. A missing setting means every style, which is
-- what a fresh install shows; an empty table means nothing is covered.
Core.REVIEW_STYLES = { "lighten", "underscore", "strikeout", "invert" }

function Core.getReviewCoverStyles()
    local v = Core.G:readSetting("annotationsviewer_review_cover_styles")
    if type(v) ~= "table" then return nil end -- nil: every style
    local out = {}
    for _i, k in ipairs(Core.REVIEW_STYLES) do if v[k] == true then out[k] = true end end
    return out -- may be empty: nothing chosen
end

function Core.reviewCoversDrawer(drawer)
    drawer = drawer or "lighten"
    local chosen = Core.getReviewCoverStyles()
    if not chosen then return true end -- nothing set: all styles
    return chosen[drawer] == true
end

function Core.getDedupInfoFields() return Core.getSetting("dedup_info_fields", "date,author,chapter") end

function Core.getShowInfo() return Core.getSetting("show_info", true) ~= false end

function Core.getInfoFields() return Core.getSetting("info_fields", "date,author,chapter") end

function Core.getAlwaysShowFirstOnPage() return Core.getSetting("always_show_first_on_page", true) ~= false end

-- Repeat the book title / the chapter-date line at the top of every page. Both start from the
-- older single "show on every page" setting.
function Core.getRepeatTitleOnPage()
    return Core.getSetting("repeat_title_on_page", Core.getAlwaysShowFirstOnPage()) ~= false
end

function Core.getRepeatInfoOnPage()
    return Core.getSetting("repeat_info_on_page", Core.getAlwaysShowFirstOnPage()) ~= false
end

-- "default" = Prev / Next bar at the bottom. The older "left" / "right" bars were merged into it.
function Core.getPaginationStyle()
    local style = Core.getSetting("pagination_style", "default")
    if style == "left" or style == "right" then return "default" end
    return style
end

function Core.getScrollbarBookMarks() return Core.getSetting("sb_book_marks", true) ~= false end

function Core.isScrollbarStyle(style)
    style = style or Core.getPaginationStyle()
    return style == "scrollbar" or style == "scrollbar_chevrons"
end

-- Titles normalized before, so formatting a long list does not redo the work.
Core._normalized_title_cache = setmetatable({}, { __mode = "k" })

-- Lowercased strings, remembered: sorting a large list lowercases the same titles often.
Core._lower_cache = setmetatable({}, { __mode = "k" })

function Core.lowerCached(str)
    str = str or ""
    local l = Core._lower_cache[str]
    if not l then l = str:lower(); Core._lower_cache[str] = l end
    return l
end

function Core.normalizeBookTitle(title)
    if not title then return "" end
    local n = Core._normalized_title_cache[title]
    if not n then
        n = Core.normalizeBookTitleUncached(title)
        Core._normalized_title_cache[title] = n
    end
    return n
end

function Core.compareByPosition(a, b, reverse)
    -- KOReader keeps a book's annotations in reading order, so the place in that list
    -- is the most reliable position (an xpointer alone can't tell h2[1] from p[2])
    local oa, ob = tonumber(a.order), tonumber(b.order)
    if oa and ob and oa ~= ob then
        if reverse then return oa > ob else return oa < ob end
    end
    local ka, kb = Core.positionKey(a), Core.positionKey(b)
    for i = 1, math.max(#ka, #kb) do
        local x, y = ka[i] or -1, kb[i] or -1
        if x ~= y then
            if reverse then return x > y else return x < y end
        end
    end
    return false
end

function Core.trimParagraph(p)
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

function Core.wrapText(text, face, max_width)
    local lines, para_end = {}, {}
    for paragraph in (text:gsub("\r", "") .. "\n"):gmatch("([^\n]*)\n") do
        paragraph = Core.trimParagraph(paragraph)
        if paragraph ~= "" then
            Util.wrapParagraph(paragraph, face, max_width, lines)
            para_end[#lines] = true
        end
    end
    return lines, para_end
end

function Core.normalizeColorStyle(af)
    if type(af) ~= "table" then return end
    local function valid(t, v) return (t == "color" or t == "style") and type(v) == "string" and v ~= "" end
    local inc = valid(af.type, af.value)
    local exc = valid(af.type_exclude, af.value_exclude)
    if inc then
        af.cs = type(af.cs) == "table" and af.cs or {}
        af.cs[af.type .. ":" .. af.value] = true
        af.cs_exclude = false
        -- an old filter that also hid something: "show yellow, hide Underline" is "yellow, with
        -- any style but Underline" (colours and styles together must both match). Hiding the same
        -- kind as the one shown adds nothing.
        if exc and af.type_exclude ~= af.type then
            if af.type_exclude == "style" then
                local styles = { "lighten", "underscore", "strikeout", "invert" }
                for n = 1, #styles do
                    if styles[n] ~= af.value_exclude then af.cs["style:" .. styles[n]] = true end
                end
            else
                local colors = ReaderHighlight.highlight_colors or {}
                for n = 1, #colors do
                    local key = colors[n][2]
                    if type(key) == "string" and key ~= af.value_exclude then af.cs["color:" .. key] = true end
                end
            end
        end
    elseif exc and not (type(af.cs) == "table" and next(af.cs)) then
        af.cs = { [af.type_exclude .. ":" .. af.value_exclude] = true }
        af.cs_exclude = true
    end
    af.type, af.value, af.type_exclude, af.value_exclude = nil, nil, nil, nil
    -- drop what can't be a colour or style (a hand-edited or broken saved filter)
    if af.cs ~= nil and type(af.cs) ~= "table" then af.cs = nil end
    if af.cs then
        for k in pairs(af.cs) do
            local t, v
            if type(k) == "string" then t, v = k:match("^(%a+):(.+)$") end
            if not valid(t, v) or af.cs[k] ~= true then af.cs[k] = nil end
        end
    end
    if af.cs and not next(af.cs) then af.cs, af.cs_exclude = nil, nil end
end

function Core.getSidecarKey(book_path)
    local ok, sidecar = pcall(function()
        local list = Core.sidecarCandidates(book_path)
        for i = 1, #list do
            if list[i].size > 0 then return list[i].path end -- open() skips empty files
        end
    end)
    local stamp = ok and type(sidecar) == "string" and Core.fileStamp(sidecar)
    if stamp then return stamp, sidecar end
    -- Fall back to the book file itself. false: KOReader looked and there is no sidecar;
    -- nil: it couldn't look (`a and false or nil` would always give nil)
    local none = nil
    if ok then none = false end
    return "book:" .. (Core.fileStamp(book_path) or ""), none
end

function Core.itemMatchesNote(item, note)
    -- the list keeps "" for an item without a date, so compare both the same way
    if (item.datetime or "") ~= (note.datetime or "") then return false end
    if note.bookmark then -- a bookmark has no text of its own: match on its place
        return item.drawer == nil and Core.positionsEqual(item.page or item.pageno, note.page)
    end
    if (item.text or "") ~= (note.highlighted_text or "") then return false end
    if note.pos0 ~= nil then
        return Core.positionsEqual(item.pos0, note.pos0) and Core.positionsEqual(item.pos1, note.pos1)
    end
    return true
end

Core.CACHE_VERSION = 5 -- 3: bookmarks and page labels are kept; 4: old-format books marked legacy, with notes;

Core._persist = nil        -- LuaSettings object, loaded on the first scan

Core._persist_dirty = false

Core._persist_count = 0

Core._annotation_cache = {}  -- [book_path] = { data = {...}, mtime = key }

Core._book_info_cache   = {}  -- [book_path] = { data = {...}, mtime = key }

function Core.loadPersistentCache()
    if Core._persist then return end
    local ok_ds, DataStorage = pcall(require, "datastorage")
    local ok_ls, LuaSettings = pcall(require, "luasettings")
    if not (ok_ds and ok_ls) then return end
    local dir = DataStorage:getDataDir() .. "/cache"
    if lfs.attributes(dir, "mode") ~= "directory" then lfs.mkdir(dir) end
    local ok, settings = pcall(LuaSettings.open, LuaSettings, dir .. "/annotationsviewer.lua")
    if not ok or not settings then return end
    Core._persist = settings
    local d = settings.data
    if d.version ~= Core.CACHE_VERSION or type(d.books) ~= "table" then
        settings.data = { version = Core.CACHE_VERSION, books = {} }
        Core._persist_dirty = true
        return
    end
    Core._persist_count = 0
    for path, b in pairs(d.books) do
        Core._persist_count = Core._persist_count + 1
        if not Core._annotation_cache[path] and b.key and b.annotations then
            Core._annotation_cache[path] = { data = b.annotations, mtime = b.key }
        end
        if not Core._book_info_cache[path] and b.info_key and b.info then
            Core._book_info_cache[path] = { data = b.info, mtime = b.info_key }
        end
    end
end

function Core.savePersistentCache(paths)
    if not Core._persist then return end
    if not Core._persist_dirty and #paths == Core._persist_count then return end
    local books = {}
    for _, path in ipairs(paths) do
        local a, i = Core._annotation_cache[path], Core._book_info_cache[path]
        if a then
            books[path] = {
                key = a.mtime, annotations = a.data,
                info_key = i and i.mtime, info = i and i.data,
            }
        end
    end
    Core._persist.data = { version = Core.CACHE_VERSION, books = books }
    local ok, err = pcall(Core._persist.flush, Core._persist)
    if not ok then logger.warn("AnnotationsViewer: could not save cache:", err) end
    Core._persist_dirty = false
    Core._persist_count = #paths
end

function Core.getLiveReader(book_path)
    local ReaderUI = require("apps/reader/readerui")
    local ui = ReaderUI and ReaderUI.instance
    if ui and ui.document and Core.samePath(ui.document.file, book_path)
            and ui.annotation and ui.annotation.annotations then
        return ui
    end
end

-- The book isn't open: find the annotation for `note` in its sidecar, call fn(item, list, index)
-- on it and save the sidecar. Returns true if the annotation was found. As in the original plugin.
function Core.editStoredAnnotation(note, fn)
    local ok, doc_settings = pcall(DocSettings.open, DocSettings, note.book_path)
    if not ok or not doc_settings or not doc_settings.data then return false end
    local data = doc_settings.data
    local found = false
    if type(data.annotations) == "table" then
        for i, item in ipairs(data.annotations) do
            if Core.itemMatchesNote(item, note) then fn(item, data.annotations, i); found = true; break end
        end
    end
    if not found then -- legacy format (KOReader < 2024)
        for _, page_highlights in pairs(data.highlight or {}) do
            if type(page_highlights) == "table" then
                for i, hl in ipairs(page_highlights) do
                    if Core.itemMatchesNote(hl, note) then fn(hl, page_highlights, i); found = true; break end
                end
            end
            if found then break end
        end
    end
    if found then doc_settings:flush() end
    return found
end

function Core.nowStamp() return os.date("%Y-%m-%d %H:%M:%S") end

function Core.getBookInfoKey(sidecar_key, sidecar)
    local dir = sidecar and sidecar:match("^(.*)/")
    return sidecar_key .. "|" .. ((dir and Core.fileStamp(dir .. "/custom_metadata.lua")) or "")
end

function Core.fileStamp(path)
    local attr = path and lfs.attributes(path)
    if attr and attr.mode == "file" then
        return attr.modification .. ":" .. attr.size
    end
end


function Core.positionsEqual(a, b)
    if a == b then return true end
    if type(a) == "table" and type(b) == "table" then -- PDF/CBZ positions
        return a.x == b.x and a.y == b.y and a.page == b.page
    end
    return false
end

function Core.normalizeBookTitleUncached(title)
    local normalized = title:lower():gsub("^%s+", ""):gsub("%s+$", "")
    normalized = normalized:gsub("^the%s+", ""):gsub("^a%s+", ""):gsub("^an%s+", "")
    return normalized
end



function Core.SortState.parse(mode)
    if type(mode) ~= "string" then return nil end
    mode = Core.SortState.LEGACY[mode] or mode
    local levels = {}
    for tok in mode:gmatch("[^,]+") do
        local key, dir = tok:match("^(%a+):(%a+)$")
        if not (key and Core.SortState.KEYS[key] and (dir == "asc" or dir == "desc")) then return nil end
        levels[#levels + 1] = { key = key, dir = dir }
    end
    if #levels == 0 or #levels > 3 then return nil end
    return levels
end
-- The all-annotations list and the one-book list each remember their own order. A book list that
-- never had its own order set starts in reading order (first highlight in the book first).
-- The Bookmarks tab has an order of its own too (bm_tab: the list is on that tab); until one is
-- set it follows the annotations' order.
function Core.SortState.get(single) return Core.SortState.getFor(single, Core.SortState.bm_tab) end
function Core.SortState.set(single, mode) Core.SortState.setFor(single, Core.SortState.bm_tab, mode) end
-- bm: the order of the Bookmarks tab (else of the annotation tabs)
function Core.SortState.getFor(single, bm)
    if bm then
        local own = Core.getSetting(single and "sort_mode_book_bm" or "sort_mode_bm", nil)
        if own then return own end
    end
    if single then return Core.getSetting("sort_mode_book", nil) or "book:asc,pos:asc" end
    return Core.getSetting("sort_mode", "date_newest")
end
function Core.SortState.setFor(single, bm, mode)
    Core.setSetting((single and "sort_mode_book" or "sort_mode") .. (bm and "_bm" or ""), mode)
end
-- All four sort orders as stored, for Cancel: nil for the Bookmarks tab means "follow the
-- annotation order", and has to come back as nil, not as a copy of that order.
Core.SortState.SETTING_KEYS = { "sort_mode", "sort_mode_bm", "sort_mode_book", "sort_mode_book_bm" }
function Core.SortState.snapshot()
    local snap = {}
    for i = 1, #Core.SortState.SETTING_KEYS do snap[i] = Core.getSetting(Core.SortState.SETTING_KEYS[i], nil) end
    return snap
end
-- Puts them back; true when something changed.
function Core.SortState.restore(snap)
    local changed = false
    for i = 1, #Core.SortState.SETTING_KEYS do
        if Core.getSetting(Core.SortState.SETTING_KEYS[i], nil) ~= snap[i] then
            Core.setSetting(Core.SortState.SETTING_KEYS[i], snap[i])
            changed = true
        end
    end
    return changed
end
function Core.SortState.encode(levels)
    local parts = {}
    for _, l in ipairs(levels) do parts[#parts + 1] = l.key .. ":" .. l.dir end
    return table.concat(parts, ",")
end
-- Keys that still do something after the levels chosen so far.
function Core.SortState.allowedAfter(prev, single)
    -- one book: every highlight has the same author, title and file, so only date and place count
    if single then
        if not prev then return { "date", "pos", "chapter" } end
        if prev.key == "chapter" then return { "date", "pos" } end
        return prev.key == "date" and { "pos" } or {}
    end
    if not prev then return { "date", "opened", "author", "book", "file", "pos" } end
    if prev.key == "pos" then return {} end
    if prev.key == "date" then return { "author", "book", "file" } end -- a day, then the books of that day
    if prev.key == "author" then return { "opened", "book", "file", "date", "pos" } end
    return { "date", "pos" } -- book, file name and last opened already single out a book
end
-- The rule as it applies to a view: in one book only its date or place part counts.
function Core.SortState.view(mode, single)
    local levels = Core.SortState.parse(mode) or Core.SortState.parse("date:desc")
    if not single then
        -- a rule saved for one book (chapter) or edited by hand: keep what makes sense here
        local out = Core.SortState.revalidate(levels, false)
        if #out == 0 then out = Core.SortState.parse("date:desc") end
        return out
    end
    local first = levels[1].key
    if first == "date" or first == "chapter" or first == "pos" then
        local keep = {}
        for _, l in ipairs(levels) do
            if l.key == "date" or l.key == "chapter" or l.key == "pos" then keep[#keep + 1] = l end
        end
        local out = Core.SortState.revalidate(keep, true)
        -- a chapter on its own: inside a chapter the highlights follow the book
        if out[#out].key == "chapter" then out[#out + 1] = { key = "pos", dir = "asc" } end
        return out
    end
    -- older rules (book, author ...): only the place part counts, else the date part
    for _, l in ipairs(levels) do
        if l.key == "pos" then return { { key = "pos", dir = l.dir } } end
    end
    for _, l in ipairs(levels) do
        if l.key == "date" then return { { key = "date", dir = l.dir } } end
    end
    return Core.SortState.parse("date:desc")
end
function Core.SortState.normView(mode, single)
    return Core.SortState.encode(Core.SortState.view(mode, single))
end
function Core.SortState.cmp3(x, y) if x < y then return -1 elseif x > y then return 1 end return 0 end
function Core.SortState.keyCmp(key, a, b)
    if key == "date" then return Core.SortState.cmp3(a.datetime or "", b.datetime or "")
    elseif key == "opened" then return Core.SortState.cmp3(Core.SortState.opened[a.book_path or ""] or 0, Core.SortState.opened[b.book_path or ""] or 0)
    elseif key == "author" then return Core.SortState.cmp3(Core.lowerCached(a.book_authors), Core.lowerCached(b.book_authors))
    elseif key == "book" then return Core.SortState.cmp3(Core.normalizeBookTitle(a.book_title), Core.normalizeBookTitle(b.book_title))
    elseif key == "file" then return Core.SortState.cmp3(Core.lowerCached(a.book_filename), Core.lowerCached(b.book_filename))
    elseif key == "chapter" then return Core.SortState.cmp3(a.chapter_rank or 0, b.chapter_rank or 0) end
    return 0
end
function Core.SortState.posCmp(a, b, dir)
    local c = Core.SortState.keyCmp("book", a, b)
    if c == 0 then c = Core.SortState.cmp3(a.book_path or "", b.book_path or "") end
    if c ~= 0 then return c end
    local pc = 0
    if Core.compareByPosition(a, b) then pc = -1 elseif Core.compareByPosition(b, a) then pc = 1 end
    return dir == "desc" and -pc or pc
end
function Core.SortState.build(mode)
    local levels = Core.SortState.parse(mode)
    if not levels then return nil end
    local id = Core.SortState.encode(levels)
    if Core.SortState.cache[id] then return Core.SortState.cache[id] end
    local day_only = {}
    for n, l in ipairs(levels) do
        if l.key == "date" and levels[n + 1] then day_only[n] = true end
    end
    local f = function(a, b)
        for n, l in ipairs(levels) do
            local c
            if l.key == "pos" then c = Core.SortState.posCmp(a, b, l.dir)
            elseif day_only[n] then
                c = Core.SortState.cmp3((a.datetime or ""):sub(1, 10), (b.datetime or ""):sub(1, 10))
                if l.dir == "desc" then c = -c end
            else
                c = Core.SortState.keyCmp(l.key, a, b)
                if l.dir == "desc" then c = -c end
            end
            if c ~= 0 then return c < 0 end
        end
        local c = Core.SortState.keyCmp("book", a, b)
        if c == 0 then c = Core.SortState.cmp3(a.book_path or "", b.book_path or "") end
        if c ~= 0 then return c < 0 end
        c = -Core.SortState.keyCmp("date", a, b)
        if c ~= 0 then return c < 0 end
        return Core.SortState.posCmp(a, b, "asc") < 0
    end
    Core.SortState.cache[id] = f
    return f
end

function Core.COLORS.highlightCode(key)
    if type(key) ~= "string" then return nil end
    key = key:lower()
    if ReaderHighlight.getHighlightColorCode then
        local ok, code = pcall(ReaderHighlight.getHighlightColorCode, ReaderHighlight, key, nil, false)
        if ok and type(code) == "string" and code:match("^#%x%x%x%x%x%x$") then return code end
    end
    return HIGHLIGHT_COLORS[key]
end
function Core.getHighlightColor(color)
    local val = Core.COLORS.highlightCode(color)
    if val and BlitBuffer.colorFromString then
        return BlitBuffer.colorFromString(val)
    end
    return BlitBuffer.COLOR_GRAY
end

-- A comparable position for an annotation. Books keep an xpointer text in pos0, PDFs a table
-- with x/y; neither is a number, so their digit runs are compared one by one.
function Core.positionKey(n)
    local key = { tonumber(n.page) or 0 }
    local p = n.pos0
    if type(p) == "string" then
        for d in p:gmatch("%d+") do key[#key + 1] = tonumber(d) or 0 end
    elseif type(p) == "table" then
        key[#key + 1] = tonumber(p.y) or 0
        key[#key + 1] = tonumber(p.x) or 0
    end
    return key
end

function Core.samePath(a, b)
    if type(a) ~= "string" or type(b) ~= "string" then return false end
    if a == b then return true end
    if Core.realPath(a) == Core.realPath(b) then return true end
    -- two mounts of the same storage (no link to follow): the same file on the same device
    local fa, fb = lfs.attributes(a), lfs.attributes(b)
    return fa ~= nil and fb ~= nil and fa.mode == "file" and fa.ino ~= nil and fa.ino ~= 0
        and fa.dev == fb.dev and fa.ino == fb.ino
end

function Core.sidecarCandidates(book_path)
    if type(book_path) ~= "string" or book_path == "" or not DocSettings.findSidecarFile then error("no API") end
    local name = DocSettings.getSidecarFilename(book_path)
    local list = {}
    local function add(path, backup)
        local attr = path and lfs.attributes(path)
        if not attr or attr.mode ~= "file" then return false end
        local prev = list[#list]
        -- a backup is never newer than its file (DocSettings buildCandidates)
        if backup and prev and prev.path .. ".old" == path then
            if prev.mtime < attr.modification then prev.mtime = attr.modification end
        end
        table.insert(list, { path = path, mtime = attr.modification, size = attr.size, prio = #list + 1 })
        return true
    end
    local doc_dir = DocSettings:getSidecarDir(book_path, "doc")
    add(doc_dir .. "/" .. name); add(doc_dir .. "/" .. name .. ".old", true)
    add(doc_dir .. "/" .. (book_path:match("([^/]+)$") or "") .. ".lua")
    local dir_dir = DocSettings:getSidecarDir(book_path, "dir")
    add(dir_dir .. "/" .. name); add(dir_dir .. "/" .. name .. ".old", true)
    -- the hash folder when it is in use, as open() does (KOReader reads a few small parts of the
    -- book for its name once and keeps that in memory)
    if DocSettings.isHashLocationEnabled and DocSettings.isHashLocationEnabled() then
        local hash_dir = DocSettings:getSidecarDir(book_path, "hash")
        add(hash_dir .. "/" .. name); add(hash_dir .. "/" .. name .. ".old", true)
    end
    if DocSettings.getHistoryPath then
        local hist = DocSettings:getHistoryPath(book_path)
        if hist ~= "" then add(hist); add(hist .. ".old", true) end
    end
    add(book_path .. ".kpdfview.lua")
    table.sort(list, function(a, b)
        if a.mtime == b.mtime then return a.prio < b.prio end
        return a.mtime > b.mtime
    end)
    return list
end

function Core.isNoBackgroundStyle(drawer)
    if not drawer then return false end
    local d = drawer:lower()
    return d == "strikeout" or d == "underscore"
end

Core.SPIN_MENUS = {
    font_size = {
        dialog_name = "font_size_dialog",
        title = _("Font sizes"),
        settings = {
            { label = _("Title size: "), key = "title_font_size", default = Core.DEFAULT_TITLE_FONT_SIZE, min = 8, max = 48, step = 1, getter = getTitleFontSize, getter = Core.getTitleFontSize },
            { label = _("Info size: "), key = "info_font_size", default = Core.DEFAULT_INFO_FONT_SIZE, min = 8, max = 48, step = 1, getter = getInfoFontSize, getter = Core.getInfoFontSize },
            { label = _("Content size: "), key = "content_font_size", default = Core.DEFAULT_CONTENT_FONT_SIZE, min = 8, max = 48, step = 1, getter = getContentFontSize, getter = Core.getContentFontSize },
        }
    },
    section_margin = {
        dialog_name = "section_margin_dialog",
        title = _("Space between notes"),
        settings = {
            { label = _("Below the book title: "), key = "title_margin", default = Core.DEFAULT_TITLE_MARGIN, min = 0, max = 30, step = 1, getter = function() return Core.getSetting("title_margin", Core.DEFAULT_TITLE_MARGIN) end },
            { label = _("Below the chapter · date line: "), key = "info_margin", default = Core.DEFAULT_INFO_MARGIN, min = 0, max = 30, step = 1, getter = function() return Core.getSetting("info_margin", Core.DEFAULT_INFO_MARGIN) end },
        }
    },
    margins = {
        dialog_name = "margin_dialog",
        title = _("Page margins"),
        settings = {
            { label = _("Top padding: "), key = "top_padding", default = Core.DEFAULT_TOP_PADDING, min = 0, max = 100, step = 5, getter = function() return Core.getSetting("top_padding", Core.DEFAULT_TOP_PADDING) end },
            { label = _("Horizontal margin: "), key = "h_margin", default = Core.DEFAULT_H_MARGIN, min = 5, max = 60, step = 5, getter = function() return Core.getSetting("h_margin", Core.DEFAULT_H_MARGIN) end },
            { label = _("Landscape width (%): "), key = "landscape_width_pct", default = 80, min = 40, max = 100, step = 5, getter = function() return Core.getSetting("landscape_width_pct", 80) end },
            { label = _("Between annotations: "), key = "note_spacing", default = Core.DEFAULT_NOTE_SPACING, min = 5, max = 100, step = 2, getter = function() return Core.getSetting("note_spacing", Core.DEFAULT_NOTE_SPACING) end },
            { label = _("Space above the note: "), key = "note_offset", default = 8, min = 0, max = 40, step = 2, getter = function() return Core.getSetting("note_offset", 8) end },
            { label = _("Extra indent for the note: "), key = "note_indent", default = 0, min = 0, max = 60, step = 2, getter = function() return Core.getSetting("note_indent", 0) end },
            { label = _("Line spacing: "), key = "line_spacing", default = 0, min = -15, max = 20, step = 1, getter = function() return Core.getSetting("line_spacing", 0) end },
            { label = _("Text indent: "), key = "text_margin", default = Core.DEFAULT_TEXT_MARGIN, min = 0, max = 30, step = 2, getter = function() return Core.getSetting("text_margin", Core.DEFAULT_TEXT_MARGIN) end },
        }
    }
}

Core._realpaths = {}
function Core.realPath(path)
    if type(path) ~= "string" then return path end
    local real = Core._realpaths[path]
    if real == nil then
        local ok, ffiutil = pcall(require, "ffi/util")
        local ok_rp, rp = false, nil
        if ok and type(ffiutil) == "table" and ffiutil.realpath then ok_rp, rp = pcall(ffiutil.realpath, path) end
        real = (ok_rp and type(rp) == "string" and rp ~= "") and rp or path
        Core._realpaths[path] = real
    end
    return real
end

return Core