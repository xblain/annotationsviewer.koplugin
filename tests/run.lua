-- Tests for the plugin's pure logic. They run with plain Lua 5.1 / LuaJIT outside KOReader,
-- using stand-ins for KOReader's modules. From the repo root:  lua tests/run.lua
package.path = "./?.lua;" .. package.path

-- Stand-in for any KOReader module: every field/call returns another stand-in, and
-- :extend{} returns a fresh class table, so main.lua can load.
local function stub()
    local s = {}
    return setmetatable(s, {
        __index = function(_, k)
            if k == "extend" or k == "new" then
                return function(_, o) return setmetatable(o or {}, { __index = stub() }) end
            end
            return stub()
        end,
        __call = function() return stub() end,
    })
end

-- Text width stand-in: 10px per character, so wrapping is predictable.
local TextWidget = {}
function TextWidget:new(o)
    return { getSize = function() return { w = 10 * #(o.text or ""), h = 20 } end, free = function() end }
end

-- A column of widgets, as KOReader's: instances have the class as metatable
local VerticalGroup = {}
VerticalGroup.__index = VerticalGroup
function VerticalGroup:extend(o) o = o or {}; setmetatable(o, self); self.__index = self; return o end
function VerticalGroup:new(o) o = o or {}; setmetatable(o, self); self.__index = self; return o end
function VerticalGroup:getSize()
    local h, w = 0, 0
    for _, c in ipairs(self) do local sz = c:getSize(); h = h + sz.h; w = math.max(w, sz.w) end
    return { w = w, h = h }
end
VerticalGroup.free = function() end

local real = {
    ["ui/widget/verticalgroup"] = VerticalGroup,
    ["gettext"] = function(str) return str end,
    ["ui/widget/textwidget"] = TextWidget,
    ["device"] = { screen = { scaleBySize = function(_, v) return v end, getWidth = function() return 600 end,
                              getHeight = function() return 800 end }, input = {} },
    -- KOReader's util.splitToWords for the tests: Chinese / Japanese characters one by one,
    -- everything else (Latin, Hangul) stays whole
    ["util"] = { splitToWords = function(str)
        local out = {}
        for ch in str:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
            local b = ch:byte(1)
            local cjk = #ch == 3 and b >= 227 and b <= 233
            if cjk or #out == 0 or (out[#out]:byte(1) >= 227 and out[#out]:byte(1) <= 233 and #out[#out] == 3) then
                table.insert(out, ch)
            else
                out[#out] = out[#out] .. ch
            end
        end
        return out
    end },
    ["logger"] = { info = function() end, warn = function() end, dbg = function() end },
    ["datastorage"] = { getSettingsDir = function() return "/tmp" end, getDataDir = function() return "/tmp" end },
    -- a settings file that remembers what is saved while the tests run
    ["luasettings"] = { open = function()
        local data = {}
        return { data = data, readSetting = function(_, k) return data[k] end,
            saveSetting = function(_, k, v) data[k] = v end, flush = function() end, isTrue = function() return false end }
    end },
}
-- the real LuaFileSystem when it is installed (export writes files)
do
    local ok, lfs = pcall(require, "lfs")
    if ok and type(lfs) == "table" then real["libs/libkoreader-lfs"] = lfs end
end
local real_require = require
require = function(name) -- luacheck: ignore
    if real[name] ~= nil then return real[name] end
    local ok, mod = pcall(real_require, name)
    if ok then return mod end
    return stub()
end

local plugin = dofile("main.lua")
local T = plugin._test
assert(T, "main.lua must expose _test")

local passed, failed = 0, 0
local function check(name, cond, detail)
    if cond then passed = passed + 1
    else failed = failed + 1; print("FAIL: " .. name .. (detail and (" -- " .. detail) or "")) end
end
local function join(t) return table.concat(t, "|") end

-- wrapText: must equal the simple "measure every candidate line" algorithm
local function naiveWrap(text, max)
    local lines, cur = {}, ""
    for word in text:gmatch("%S+") do
        local test = cur == "" and word or (cur .. " " .. word)
        if 10 * #test <= max then cur = test
        else
            if cur ~= "" then table.insert(lines, cur) end
            cur = word
            -- a word wider than the line is broken between characters
            while 10 * #cur > max and #cur > 1 do
                local n = math.max(1, math.floor(max / 10))
                table.insert(lines, cur:sub(1, n)); cur = cur:sub(n + 1)
            end
        end
    end
    if cur ~= "" then table.insert(lines, cur) end
    return lines
end
local face = {}
local samples = {
    "the quick brown fox jumps over the lazy dog",
    "a",
    "",
    "supercalifragilisticexpialidocious word",
    "one two three four five six seven eight nine ten eleven twelve thirteen",
}
for _, text in ipairs(samples) do
    for _, w in ipairs({ 50, 100, 155, 300 }) do
        check("wrap '" .. text:sub(1, 12) .. "' @" .. w, join(T.wrapText(text, face, w)) == join(naiveWrap(text, w)),
            join(T.wrapText(text, face, w)) .. " vs " .. join(naiveWrap(text, w)))
    end
end
-- Chinese / Japanese / Korean text: no spaces to wrap at, so lines must break between characters
-- (the stand-in measures 10px per byte, a character is 3 bytes = 30px)
do
    local function noLineWiderThan(lines, max)
        for _i, l in ipairs(lines) do if 10 * #l > max then return false end end
        return true
    end
    local samples = {
        chinese  = "这是一个很长的句子用来测试中文文本在高亮中是否可以正确换行而不会超出屏幕的宽度",
        japanese = "吾輩は猫である。名前はまだ無い。どこで生れたかとんと見当がつかぬ。",
        korean   = "대한민국은 민주공화국이다 대한민국의 주권은 국민에게 있고 모든 권력은 국민으로부터 나온다",
        mixed    = "Chapter 3 第三章 The 旅 begins 시작 here",
    }
    for name, text in pairs(samples) do
        local got = T.wrapText(text, face, 240)
        check(name .. ": wraps into several lines", #got > 1, #got .. " line(s)")
        check(name .. ": no line wider than the column", noLineWiderThan(got, 240), join(got))
        -- nothing lost: joining the lines (with a space where the source had one) restores the text
        local flat = join(got):gsub("|", ""):gsub("%s+", "")
        check(name .. ": all characters kept", flat == text:gsub("%s+", ""), flat)
    end
    -- Latin text is wrapped exactly as before
    check("latin unchanged", join(T.wrapText("one two three four", face, 100)) == "one two|three four",
        join(T.wrapText("one two three four", face, 100)))
end
-- paragraphs are kept, blank lines dropped, paragraph ends marked
local lines, para_end = T.wrapText("first para\n\nsecond one here\r\nthird", face, 100)
check("paragraph lines", join(lines) == "first para|second one|here|third", join(lines))
check("paragraph ends", para_end[1] and para_end[3] and para_end[4] and not para_end[2])

-- spaces (also no-break spaces) at the ends of a paragraph are dropped
local trimmed = T.wrapText(" \194\160 1778 \n\194\160Frances", face, 100)
check("trim paragraph ends", join(trimmed) == "1778|Frances", join(trimmed))

-- short sort labels
check("sort label date", T.sortModeLabel("date_newest") == "Newest first")
check("sort label book location", T.sortModeLabel("book_location_desc") == "Book · end to start", T.sortModeLabel("book_location_desc"))
check("sort label unknown", T.sortModeLabel("nope") == "Newest first")

-- normalizeBookTitle
check("title article", T.normalizeBookTitle("  The Hobbit ") == "hobbit")
check("title nil", T.normalizeBookTitle(nil) == "")

-- sorting
local notes = {
    { book_title = "Beta", datetime = "2026-01-02", pos0 = 2 },
    { book_title = "Alpha", datetime = "2026-01-03", pos0 = 1 },
    { book_title = "The Alpha", datetime = "2026-01-01", pos0 = 3 },
}
local function sorted(mode)
    local copy = { notes[1], notes[2], notes[3] }
    table.sort(copy, T.SORT_COMPARATORS[mode])
    local out = {}
    for i, n in ipairs(copy) do out[i] = n.datetime end
    return join(out)
end
check("sort newest", sorted("date_newest") == "2026-01-03|2026-01-02|2026-01-01", sorted("date_newest"))
check("sort oldest", sorted("date_oldest") == "2026-01-01|2026-01-02|2026-01-03", sorted("date_oldest"))
check("sort book asc ignores 'The'", sorted("book_asc") == "2026-01-03|2026-01-01|2026-01-02", sorted("book_asc"))

-- filter label
check("no filter", T.filterToString(nil) == "")
check("notes only label", T.filterToString({ notes_presence = "only" }) ~= "")

-- annotation matching (date + text + position)
local note = { datetime = "d", highlighted_text = "t", pos0 = "x0", pos1 = "x1" }
check("match same", T.itemMatchesNote({ datetime = "d", text = "t", pos0 = "x0", pos1 = "x1" }, note))
check("no match other position", not T.itemMatchesNote({ datetime = "d", text = "t", pos0 = "y0", pos1 = "x1" }, note))
check("match pdf positions", T.itemMatchesNote({ datetime = "d", text = "t", pos0 = { x = 1, y = 2, page = 3 }, pos1 = { x = 4, y = 5, page = 3 } },
    { datetime = "d", highlighted_text = "t", pos0 = { x = 1, y = 2, page = 3 }, pos1 = { x = 4, y = 5, page = 3 } }))
-- an item without a date: the list keeps "" for it, so it must still be found
check("match item without datetime", T.itemMatchesNote({ text = "t", pos0 = "x0", pos1 = "x1" },
    { datetime = "", highlighted_text = "t", pos0 = "x0", pos1 = "x1" }))
check("match bookmark without datetime", T.itemMatchesNote({ page = 5 }, { bookmark = true, datetime = "", page = 5 }))
check("missing item gives false", not T.itemMatchesNote({ datetime = "other", text = "t", pos0 = "x0", pos1 = "x1" }, note))
check("dated item does not match undated note", not T.itemMatchesNote({ datetime = "d", text = "t", pos0 = "x0", pos1 = "x1" },
    { datetime = "", highlighted_text = "t", pos0 = "x0", pos1 = "x1" }))

-- applyFilter
local list = {
    { book_title = "A", highlighted_text = "alpha beta", user_note = "my note", drawer = "lighten", color = "yellow" },
    { book_title = "B", highlighted_text = "gamma", user_note = nil, drawer = "lighten", color = "red" },
}
local function filtered(af)
    local w = { notes_list = list, active_filter = af }
    T.NotesListWidget.applyFilter(w)
    local out = {}
    for i, n in ipairs(w.filtered_notes) do out[i] = n.book_title end
    return join(out)
end
check("filter none", filtered(nil) == "A|B")
check("filter notes only", filtered({ notes_presence = "only" }) == "A", filtered({ notes_presence = "only" }))
check("filter without notes", filtered({ notes_presence = "exclude" }) == "B")
check("filter book", filtered({ books = { B = true } }) == "B")
check("filter highlight text", filtered({ search_highlight = "beta" }) == "A")

-- markdown export
local md = T.notesToMarkdown({ { book_title = "A", book_authors = "Me", datetime = "2026-01-01 10:00:00",
    highlighted_text = "line1\nline2", user_note = "n" } }, "")
check("markdown book heading", md:find("## A — Me", 1, true) ~= nil, md)
check("markdown quote lines", md:find("> line1\n> line2", 1, true) ~= nil, md)
check("markdown note", md:find("**Note:** n", 1, true) ~= nil, md)

-- bookmarks: reading them from KOReader's annotations list
local toNote = plugin.toNote
local bm = toNote({ page = "/body/p[3]", pageno = 34, chapter = "Two", text = "in Two", datetime = "2026-01-09 10:00:00" }, 4)
check("bookmark kept", bm and bm.bookmark == true)
check("bookmark has no highlighted text", bm and bm.text == "")
check("bookmark page label", bm and bm.page_label == 34)
check("bookmark keeps its order", bm and bm.order == 4)
check("bookmark keeps KOReader's text for matching", bm and bm.bm_text == "in Two")
local bm2 = toNote({ page = 7, pageno = 7, pageref = "vii", datetime = "d", note = "n" }, 1)
check("bookmark page label prefers pageref", bm2 and bm2.page_label == "vii")
check("bookmark note", bm2 and bm2.notes == "n")
check("bookmark without position skipped", toNote({ datetime = "d" }, 1) == nil)
check("empty highlight skipped", toNote({ drawer = "lighten", text = "", datetime = "d" }, 1) == nil)
local hl = toNote({ drawer = "lighten", text = "t", pos0 = "a", pos1 = "b", page = "a", pageno = 12, datetime = "d" }, 2)
check("highlight kept", hl and not hl.bookmark and hl.text == "t" and hl.page_label == 12)

-- old-format sidecars (KOReader before 2024): notes are in bookmarks[].text
local legacy = T.legacyNotes({
    highlight = {
        [12] = {
            { datetime = "2023-05-01 10:00:00", drawer = "lighten", color = "red", text = "first passage",
              pos0 = "/body/p[1].0", pos1 = "/body/p[1].5", chapter = "One" },
            { datetime = "2023-05-02 10:00:00", drawer = "underscore", text = "second passage",
              pos0 = "/body/p[2].0", pos1 = "/body/p[2].5" },
        },
    },
    bookmarks = {
        { datetime = "2023-05-01 10:00:00", highlighted = true, notes = "first passage", text = "my old note",
          page = "/body/p[1].0", pos0 = "/body/p[1].0", pos1 = "/body/p[1].5", chapter = "One" },
        { datetime = "2023-05-02 10:00:00", highlighted = true, notes = "second passage",
          text = "Page 13 second passage @ 2023-05-02 10:00:00",
          page = "/body/p[2].0", pos0 = "/body/p[2].0", pos1 = "/body/p[2].5", chapter = "Two" },
        { datetime = "2023-05-03 09:00:00", page = "/body/p[9].0", notes = "Page 40", text = "page note", chapter = "Three" },
        { datetime = "2023-05-04 09:00:00", page = "/body/p[11].0", notes = "Page 44", text = "Page 44" },
    },
})
local by_text = {}
for _, n in ipairs(legacy) do by_text[n.bookmark and ("bm:" .. n.datetime) or n.text] = n end
check("legacy: note taken from bookmarks[].text", by_text["first passage"] and by_text["first passage"].notes == "my old note")
check("legacy: KOReader's automatic bookmark text is not a note", by_text["second passage"] and by_text["second passage"].notes == "")
check("legacy: chapter from the bookmark when the highlight has none", by_text["second passage"] and by_text["second passage"].chapter == "Two")
check("legacy: highlight keeps style and colour", by_text["first passage"].drawer == "lighten" and by_text["first passage"].color == "red"
    and by_text["second passage"].color == "yellow")
local pbm = by_text["bm:2023-05-03 09:00:00"]
check("legacy: a page bookmark stays a bookmark", pbm and pbm.bookmark == true and pbm.notes == "page note" and pbm.text == "")
check("legacy: page bookmark without a note", by_text["bm:2023-05-04 09:00:00"] and by_text["bm:2023-05-04 09:00:00"].notes == "")
check("legacy: highlights become no bookmarks", #legacy == 4, #legacy)
local all_legacy = true
for _, n in ipairs(legacy) do if not n.legacy then all_legacy = false end end
check("legacy: every note marked legacy", all_legacy)
-- what KOReader keeps when it converts the file: text, note and date come from the bookmark
local conv = T.legacyNotes({
    highlights_imported = true,
    highlight = { [4] = {
        { datetime = "a", drawer = "strikeout", color = "blue", text = "old text", note = "plugin-only note",
          pos0 = "/p[1].0", pos1 = "/p[1].9" },
        { datetime = "b", drawer = "lighten", text = "never bookmarked", pos0 = "/p[5].0", pos1 = "/p[5].9" },
    } },
    bookmarks = {
        { datetime = "a", highlighted = true, notes = "edited text", text = "My thought Page 4 edited text @ a",
          page = "/p[1].0", pos0 = "/p[1].0", pos1 = "/p[1].9" },
        { datetime = "c", highlighted = true, notes = "orphan text", text = "",
          page = "/p[7].0", pos0 = "/p[7].0", pos1 = "/p[7].9" },
    },
})
local c_by = {}
for _, n in ipairs(conv) do c_by[n.text] = n end
check("legacy: text from the bookmark, style from the highlight", c_by["edited text"] and c_by["edited text"].drawer == "strikeout"
    and c_by["edited text"].color == "blue")
check("legacy: a note typed before KOReader's own text is kept", c_by["edited text"] and c_by["edited text"].notes == "My thought Page 4 edited text @ a")
check("legacy: a note only in highlight[] is not shown (KOReader drops it)", c_by["old text"] == nil and c_by["edited text"].notes ~= "plugin-only note")
check("legacy: highlight without bookmark dropped once imported", c_by["never bookmarked"] == nil)
check("legacy: bookmark without highlight entry gets the default style", c_by["orphan text"] and c_by["orphan text"].drawer == "lighten")
local not_imported = T.legacyNotes({ highlight = { [2] = { { datetime = "x", drawer = "underscore", text = "pre-2014", pos0 = "/p[2].0", pos1 = "/p[2].5" } } } })
check("legacy: before highlights_imported every highlight counts", #not_imported == 1 and not_imported[1].text == "pre-2014")
check("legacy: no bookmarks and imported gives nothing", #T.legacyNotes({ highlights_imported = true,
    highlight = { [2] = { { datetime = "x", drawer = "lighten", text = "t", pos0 = "a", pos1 = "b" } } } }) == 0)
local reflow = T.legacyNotes({ highlights_imported = true, highlight = {},
    bookmarks = { { datetime = "r", highlighted = true, page = 9, notes = "reflow", pos0 = { x = 1, y = 2 }, pos1 = { x = 3, y = 4 } } } })
check("legacy pdf: a position without page gets the bookmark's page", reflow[1] and reflow[1].pos0.page == 9 and reflow[1].pos1.page == 9)
local old_pdf = T.legacyNotes({ highlight = { [3] = { { datetime = "z", drawer = "lighten", text = "pdf 2013", pos0 = { x = 1, y = 1 }, pos1 = { x = 2, y = 2 } } } } })
check("legacy pdf before 2014: page is the page number", old_pdf[1] and old_pdf[1].page == 3 and old_pdf[1].pos0.page == 3)
local twice = T.legacyNotes({ highlights_imported = true,
    highlight = { [1] = { { datetime = "d", drawer = "underscore", color = "green", text = "t", pos0 = "/a", pos1 = "/b" } } },
    bookmarks = { { datetime = "d", highlighted = true, notes = "t", page = "/a", pos0 = "/a", pos1 = "/b" },
                  { datetime = "d", highlighted = true, notes = "t", page = "/a", pos0 = "/a", pos1 = "/b" } } })
check("legacy: two bookmarks on one highlight both keep its style", #twice == 2 and twice[2].drawer == "underscore")
do -- KOReader's gettext is a callable table; a German sidecar has German automatic texts
    local real_gt = real["gettext"]
    real["gettext"] = setmetatable({}, { __call = function(_, str)
        return str == "Page %1 %2 @ %3" and "Seite %1 %2 @ %3" or str end })
    local de = T.legacyNotes({ highlights_imported = true, highlight = {},
        bookmarks = { { datetime = "2023-01-01 10:00:00", highlighted = true, notes = "Text (1)",
            text = "Seite 12 Text (1) @ 2023-01-01 10:00:00", page = "/p", pos0 = "/p", pos1 = "/q" } } })
    real["gettext"] = real_gt
    check("legacy: KOReader's translated automatic text is not a note", de[1] and de[1].notes == "", de[1] and de[1].notes)
end
local ok_empty, empty = pcall(T.legacyNotes, { highlight = { [3] = { { drawer = "lighten" }, "junk" } }, bookmarks = { "junk", { page = nil } } })
check("legacy: missing fields give no error", ok_empty and #empty == 0)
check("legacy: no data", #T.legacyNotes(nil) == 0 and #T.legacyNotes({}) == 0)
local pdf = T.legacyNotes({
    highlight = { [5] = { { datetime = "d", drawer = "lighten", text = "pdf text", pos0 = { x = 1, y = 2 }, pos1 = { x = 3, y = 4 } } } },
    bookmarks = {
        { datetime = "d", highlighted = true, page = 6, notes = "pdf text", text = "wrong page", pos0 = { x = 1, y = 2 }, pos1 = { x = 3, y = 4 } },
        { datetime = "d", highlighted = true, page = 5, notes = "pdf text", text = "pdf note", pos0 = { x = 1, y = 2 }, pos1 = { x = 3, y = 4 } },
    },
})
local pdf_hl
for _, n in ipairs(pdf) do if n.page == 5 then pdf_hl = n end end
check("legacy pdf: the highlight entry matches the bookmark on its page", pdf_hl and pdf_hl.notes == "pdf note" and pdf_hl.page_label == 5)

-- the same book under two spellings of its path (links, /mnt/us vs /mnt/base-us)
do
    local real_fu = real["ffi/util"]
    local calls = 0
    real["ffi/util"] = { realpath = function(p)
        calls = calls + 1
        local map = { ["/home/u/BooksLink/a.epub"] = "/home/u/Books/a.epub", ["/home/u/Books/a.epub"] = "/home/u/Books/a.epub",
            ["/mnt/us/b.epub"] = "/mnt/base-us/b.epub", ["/mnt/base-us/b.epub"] = "/mnt/base-us/b.epub" }
        return map[p] -- nil: the file doesn't exist
    end }
    T.NotesListWidget._realpaths = {}
    check("samePath: equal strings", T.samePath("/x/a.epub", "/x/a.epub"))
    check("samePath: through a link", T.samePath("/home/u/BooksLink/a.epub", "/home/u/Books/a.epub"))
    check("samePath: kindle mount names", T.samePath("/mnt/us/b.epub", "/mnt/base-us/b.epub"))
    check("samePath: other books differ", not T.samePath("/home/u/Books/a.epub", "/mnt/us/b.epub"))
    check("samePath: missing files compare as written", not T.samePath("/gone/a.epub", "/gone/b.epub") and T.samePath("/gone/a.epub", "/gone/a.epub"))
    check("samePath: nil is never the same", not T.samePath(nil, "/x") and not T.samePath(nil, nil))
    local before = calls
    T.samePath("/home/u/BooksLink/a.epub", "/home/u/Books/a.epub")
    check("samePath: realpath kept per path", calls == before)
    real["ffi/util"] = { realpath = function() error("boom") end }
    T.NotesListWidget._realpaths = {}
    check("samePath: realpath failing falls back to the string", not T.samePath("/p/a", "/p/b") and T.samePath("/p/a", "/p/a"))
    real["ffi/util"] = real_fu
    T.NotesListWidget._realpaths = {}
    -- two mounts of the same files: no link to follow, but the same file (a hard link here)
    local lfs_real = real["libs/libkoreader-lfs"]
    if type(lfs_real) == "table" and lfs_real.attributes and lfs_real.attributes("/", "ino") ~= nil then
        local a = os.tmpname()
        local b = a .. "-mount2"
        local fh = io.open(a, "w"); fh:write("x"); fh:close()
        os.execute("ln '" .. a .. "' '" .. b .. "' 2>/dev/null")
        real["ffi/util"] = { realpath = function(p) return p end } -- as if nothing were a link
        T.NotesListWidget._realpaths = {}
        check("samePath: same file on two mounts", T.samePath(a, b))
        local c = a .. "-other"
        fh = io.open(c, "w"); fh:write("x"); fh:close()
        check("samePath: a copy is not the same book", not T.samePath(a, c))
        os.remove(a); os.remove(b); os.remove(c)
        real["ffi/util"] = real_fu
        T.NotesListWidget._realpaths = {}
    end
end

-- library scans only read sidecars
do
    local DS = T.DocSettings
    local orig_open = rawget(DS, "openSettingsFile")
    local lfsx = real["libs/libkoreader-lfs"]
    local dir = os.tmpname(); os.remove(dir); os.execute("mkdir -p '" .. dir .. "/b.sdr' '" .. dir .. "/ds/b.sdr'")
    local book = dir .. "/b.epub"
    local side = dir .. "/b.sdr/metadata.epub.lua"          -- "doc" location
    local dside = dir .. "/ds/b.sdr/metadata.epub.lua"      -- "dir" location
    local saved = {}
    for _, k in ipairs({ "findSidecarFile", "getSidecarFilename", "getSidecarDir", "isHashLocationEnabled", "getHistoryPath" }) do
        saved[k] = rawget(DS, k)
    end
    DS.findSidecarFile = function() end
    DS.getSidecarFilename = function() return "metadata.epub.lua" end
    DS.getSidecarDir = function(_, _p, loc) return loc == "dir" and (dir .. "/ds/b.sdr") or (dir .. "/b.sdr") end
    DS.isHashLocationEnabled = function() return false end
    DS.getHistoryPath = function() return "" end
    local function write(path, text, mtime)
        local f = io.open(path, "w"); f:write(text); f:close()
        if mtime and lfsx and lfsx.touch then lfsx.touch(path, mtime, mtime) end
    end
    local function pick() return select(2, T.getSidecarKey(book)) end
    check("getSidecarKey: no sidecar gives false", pick() == false, tostring(pick()))
    write(side, "return { a = 1 }", 1000)
    check("getSidecarKey: the book's own folder", pick() == side, tostring(pick()))
    if lfsx and lfsx.touch then
        write(dside, "return { a = 2 }", 2000)
        check("getSidecarKey: the newest copy wins, as KOReader reads it", pick() == dside, tostring(pick()))
        os.remove(dside)
        write(side .. ".old", "return { a = 0 }", 3000)
        check("getSidecarKey: a newer backup never goes before its file", pick() == side, tostring(pick()))
        os.remove(side)
        check("getSidecarKey: only the backup left (crash while saving)", pick() == side .. ".old", tostring(pick()))
        write(side, "", 4000)
        check("getSidecarKey: an empty file is skipped", pick() == side .. ".old", tostring(pick()))
        os.remove(side .. ".old")
        -- the newest file doesn't load (cut off by a power cut), another copy does
        write(side, "return {{{ cut off", 5000)
        write(dside, 'return { annotations = { { text = "good copy", drawer = "lighten" } } }', 1000)
        DS.openSettingsFile = function(path)
            local ok, stored = pcall(dofile, path)
            return { data = (ok and type(stored) == "table") and stored or {} }
        end
        local d = T.readSidecar(pick(), book)
        check("readSidecar: a broken newest file falls back to the next copy", d and d.annotations and d.annotations[1].text == "good copy")
        check("readSidecar: the broken file is kept", io.open(side) ~= nil)
        DS.openSettingsFile = orig_open
        -- the hash folder in use: a newer copy there is the one KOReader reads
        os.execute("mkdir -p '" .. dir .. "/hash/ab'")
        local hside = dir .. "/hash/ab/metadata.epub.lua"
        DS.getSidecarDir = function(_, _p, loc)
            return (loc == "dir" and (dir .. "/ds/b.sdr")) or (loc == "hash" and (dir .. "/hash/ab")) or (dir .. "/b.sdr")
        end
        write(side, "return { a = 1 }", 1000)
        write(hside, "return { a = 3 }", 6000)
        check("getSidecarKey: hash folder not in use is not looked at", pick() == side, tostring(pick()))
        DS.isHashLocationEnabled = function() return true end
        check("getSidecarKey: a newer copy in the hash folder wins", pick() == hside, tostring(pick()))
        DS.isHashLocationEnabled = function() return false end
        os.remove(hside)
    end
    os.remove(side); os.remove(dside)
    DS.findSidecarFile = false -- an older KOReader without it
    check("getSidecarKey: can't look gives nil", pick() == nil)
    for k, v in pairs(saved) do DS[k] = v end
    DS.findSidecarFile = saved.findSidecarFile
    -- KOReader's own openSettingsFile (docsettings.lua): next() on what dofile gave
    DS.openSettingsFile = function(path)
        local ok, stored = pcall(dofile, path)
        local new = {}
        if ok and next(stored) ~= nil then new.data = stored else new.data = {} end
        return new
    end
    write(side, 'return { annotations = { { text = "t", drawer = "lighten", datetime = "d" } } }')
    local data = T.readSidecar(side)
    check("readSidecar: reads the file", data and data.annotations and data.annotations[1].text == "t")
    local fh = io.open(side, "w"); fh:close() -- empty file: KOReader's open() would delete it
    fh = io.open(side .. ".old", "w"); fh:write('return { annotations = { { text = "backup", drawer = "lighten" } } }'); fh:close()
    local d2 = T.readSidecar(side)
    check("readSidecar: empty file falls back to .old", d2 and d2.annotations[1].text == "backup")
    check("readSidecar: the empty file is left alone", io.open(side) ~= nil)
    os.remove(side .. ".old")
    fh = io.open(side, "w"); fh:write("return {{{ broken"); fh:close()
    check("readSidecar: broken file gives nil, no error", T.readSidecar(side) == nil)
    check("readSidecar: the broken file is left alone", io.open(side) ~= nil)
    check("readSidecar: no path", T.readSidecar(nil) == nil and T.readSidecar(false) == nil)
    os.remove(side); os.execute("rm -rf '" .. dir .. "'")
    DS.openSettingsFile = orig_open
end

-- broken or old sort and filter settings fall back to defaults
do
    local SS = T.SortState
    local ok_d, desc = pcall(SS.describe, SS.view("chapter:asc,date:desc", false), false)
    check("all books: a one-book rule (chapter) doesn't error", ok_d and type(desc) == "string", tostring(desc))
    check("all books: chapter dropped, newest first", SS.encode(SS.view("chapter:asc,date:desc", false)) == "date:desc")
    check("all books: a valid rule is kept", SS.encode(SS.view("author:asc,book:asc,pos:asc", false)) == "author:asc,book:asc,pos:asc")
    check("all books: an old name still works", SS.encode(SS.view("author_location_asc", false)) ~= "date:desc")
    -- an unknown rule: the label and the order agree (newest first)
    check("label for garbage", T.sortModeLabel("garbage") == T.sortModeLabel("date_newest"), T.sortModeLabel("garbage"))
    local gnotes = { { datetime = "2026-01-01" }, { datetime = "2026-03-01" }, { datetime = "2026-02-01" } }
    T.NotesListWidget:sortNotesList(gnotes, "garbage", false)
    check("garbage rule sorts newest first", gnotes[1].datetime == "2026-03-01" and gnotes[3].datetime == "2026-01-01")
    local notes2 = { { datetime = "2026-01-01" }, { datetime = "2026-03-01" } }
    T.NotesListWidget:sortNotesList(notes2, "chapter:asc", false)
    check("chapter rule in all books sorts newest first", notes2[1].datetime == "2026-03-01")
    T.setSetting("sort_mode", "chapter:asc,date:desc")
    local k1 = T.NotesListWidget.markKey({ datetime = "2026-03-05", book_title = "A" }, false)
    check("scrollbar marks follow the order the list really has (months)", k1 == "2026-03", tostring(k1))
    T.setSetting("sort_mode", nil)
end
do
    local N = T.normalizeColorStyle
    local f = { cs = { yellow = true, ["color:red"] = true, [3] = true, ["style:"] = true, ["bogus:x"] = true } }
    N(f)
    check("colour filter: broken keys dropped", f.cs and f.cs["color:red"] and f.cs.yellow == nil and f.cs[3] == nil
        and f.cs["style:"] == nil and f.cs["bogus:x"] == nil)
    local f2 = { cs = { yellow = true } }
    N(f2)
    check("colour filter: nothing valid left means no filter", f2.cs == nil and f2.cs_exclude == nil)
    check("filterToString: a key that is off is not listed", not T.filterToString({ cs = { ["color:red"] = false, ["color:blue"] = true } }):find("Red", 1, true))
    local ok_s, str = pcall(T.filterToString, { cs = { yellow = true, ["color:red"] = true } })
    check("filterToString: a broken key is left out", ok_s and str:find("C: ", 1, true) ~= nil and not str:find("ellow", 1, true), tostring(str))
    local w = setmetatable({ active_filter = { cs = { yellow = true, ["style:underscore"] = true } } }, { __index = T.NotesListWidget })
    local ok_c, chips = pcall(w.getFilterChips, w)
    check("chips: a broken colour key doesn't error", ok_c and type(chips) == "table", tostring(chips))
    -- old saved filters
    local old1 = { type = "color", value = "yellow", type_exclude = "style", value_exclude = "underscore" }
    N(old1)
    check("old filter: show yellow, hide Underline is kept", old1.cs and old1.cs["color:yellow"] and not old1.cs["style:underscore"]
        and old1.cs["style:lighten"] and old1.cs["style:invert"] and not old1.cs_exclude and old1.type == nil)
    local old2 = { type_exclude = "color", value_exclude = "red" }
    N(old2)
    check("old filter: hide only", old2.cs and old2.cs["color:red"] and old2.cs_exclude == true)
    local old3 = { type = "style", value = "lighten", type_exclude = "style", value_exclude = "invert" }
    N(old3)
    check("old filter: hiding the same kind adds nothing", old3.cs and old3.cs["style:lighten"] and not old3.cs["style:invert"])
    -- what the old+new filter shows
    local olist = {
        { highlighted_text = "a", drawer = "lighten", color = "yellow" },
        { highlighted_text = "b", drawer = "underscore", color = "yellow" },
        { highlighted_text = "c", drawer = "lighten", color = "red" },
    }
    local lw = { notes_list = olist, active_filter = { type = "color", value = "yellow", type_exclude = "style", value_exclude = "underscore" } }
    T.NotesListWidget.applyFilter(lw)
    local shown = {}
    for _, n in ipairs(lw.filtered_notes) do shown[#shown + 1] = n.highlighted_text end
    check("old filter: yellow shown, yellow underline hidden", table.concat(shown, "|") == "a", table.concat(shown, "|"))
end

-- KOReader's own colour names and codes (newer KOReader lets you rename and recolour them)
do
    local RH, NIW = T.ReaderHighlight, T.NoteItemWidget
    local saved = { rawget(RH, "highlight_colors"), rawget(RH, "getHighlightColorString"), rawget(RH, "getHighlightColorCode") }
    RH.highlight_colors = { { "Red", "red" }, { "Yellow", "yellow" }, { "Gray", "gray" } }
    -- KOReader 2026.07: no custom colours (getHighlightColorString gives the built-in name)
    RH.getHighlightColorCode = false
    RH.getHighlightColorString = function(self, key)
        for _, c in ipairs(self.highlight_colors) do if c[2] == key then return c[1] end end
        return key
    end
    check("colour label: built-in name", NIW.colorLabel("red") == "Red")
    check("colour label: unknown key capitalised", NIW.colorLabel("teal") == "Teal")
    -- newer KOReader: custom names and codes
    local custom = { red = { name = "Anger", code = "#123456" }, yellow = { name = "Joy" } }
    RH.getHighlightColorString = function(self, key)
        if custom[key] and custom[key].name then return custom[key].name end
        for _, c in ipairs(self.highlight_colors) do if c[2] == key then return c[1] end end
        return key
    end
    local night_asked
    RH.getHighlightColorCode = function(_, key, _force, honor_night)
        night_asked = honor_night
        return custom[key] and custom[key].code or (key == "yellow" and "#FFFF00") or nil
    end
    check("colour label: your own name", NIW.colorLabel("red") == "Anger" and NIW.colorLabel("yellow") == "Joy")
    check("colour label: any case of the key", NIW.colorLabel("RED") == "Anger")
    check("colour label: no own name keeps the built-in one", NIW.colorLabel("gray") == "Gray")
    check("colour code: your own code", T.COLORS.highlightCode("red") == "#123456" and T.COLORS.highlightCode("RED") == "#123456")
    check("colour code: never asks for night mode (the list inverts itself)", night_asked == false)
    check("colour code: a code without your own one", T.COLORS.highlightCode("yellow") == "#FFFF00")
    local fstr = T.filterToString({ cs = { ["color:red"] = true, ["style:lighten"] = true } })
    check("filter line uses your colour name", fstr:find("Anger", 1, true) ~= nil, fstr)
    local w = setmetatable({ active_filter = { cs = { ["color:yellow"] = true } } }, { __index = T.NotesListWidget })
    local chips = w:getFilterChips()
    check("active-filter chip uses your colour name", chips[1] and chips[1].label == "Joy", chips[1] and chips[1].label)
    RH.getHighlightColorCode = function() error("boom") end
    RH.getHighlightColorString = function() error("boom") end
    check("colours: a failing KOReader call falls back", NIW.colorLabel("red") == "Red")
    RH.highlight_colors, RH.getHighlightColorString, RH.getHighlightColorCode = saved[1], saved[2], saved[3]
end

-- gestures passed on from the list
do
    local UI, NLW = T.UIManager, T.NotesListWidget
    local saved_ui = { rawget(UI, "sendEvent"), rawget(UI, "broadcastEvent"), rawget(UI, "close") }
    local saved_disp = real["dispatcher"]
    local disp = { isActionEnabled = function() return true end }
    real["dispatcher"] = disp
    local orig_enabled = disp.isActionEnabled
    local broadcast, closed = {}, {}
    UI.sendEvent = function() error("not replaced") end
    UI.broadcastEvent = function(_, ev) broadcast[#broadcast + 1] = ev end
    UI.close = function(_, w) closed[#closed + 1] = w end
    local list = { name = "list" }
    local sheet = { name = "sheet" }
    NLW._current = list
    local seen = {}
    NLW.runForwarded(function()
        seen.page_turn = disp:isActionEnabled({ category = "incrementalnumber", event = "GotoViewRel", reader = true })
        seen.rolling = disp:isActionEnabled({ event = "X", rolling = true })
        seen.own = disp:isActionEnabled({ category = "none", event = "ShowAnnotationsHere", general = true })
        seen.old_own = disp:isActionEnabled({ category = "none", event = "ShowCurrentBookAnnotations" })
        seen.frontlight = disp:isActionEnabled({ category = "none", event = "IncreaseFlIntensity", screen = true })
        seen.home = disp:isActionEnabled({ category = "none", event = "Home", general = true })
        seen.closed_on_check = #closed -- a QuickMenu checks actions while building the menu
        UI:sendEvent("refresh")
        UI:sendEvent({ handler = "onHome" })
    end, sheet)
    check("forwarded: a page turn doesn't reach the book", seen.page_turn == false and seen.rolling == false)
    check("forwarded: the plugin's own gesture opens no second list", seen.own == false and seen.old_own == false)
    check("forwarded: frontlight and the like still run", seen.frontlight == true)
    check("forwarded: events go to every window (refresh)", broadcast[1] == "refresh")
    check("forwarded: checking the file browser action closes nothing", seen.closed_on_check == 0 and seen.home == true)
    check("forwarded: sending it closes the plugin's windows first", closed[1] == sheet and closed[2] == list
        and broadcast[2] and broadcast[2].handler == "onHome")
    check("forwarded: KOReader's functions are put back", disp.isActionEnabled == orig_enabled and UI.sendEvent ~= nil
        and select(1, pcall(UI.sendEvent)) == false)
    NLW.runForwarded(function() error("gesture failed") end, list)
    check("forwarded: an error in the action is caught and things put back", disp.isActionEnabled == orig_enabled)
    NLW._current = nil
    UI.sendEvent, UI.broadcastEvent, UI.close = saved_ui[1], saved_ui[2], saved_ui[3]
    real["dispatcher"] = saved_disp
end

-- search without capitals in every language
do
    local saved_u, saved_util = real["ffi/utf8proc"], real["util"]
    -- one character for one without normalizing (İ, 2 bytes, becomes i, 1 byte), as utf8proc does
    local up = { ["É"] = "é", ["Ü"] = "ü", ["İ"] = "i" }
    real["ffi/utf8proc"] = { lowercase = function(str)
        local out = str:gsub("[\192-\253][\128-\191]*", function(c) return up[c] or c end):lower()
        return out
    end }
    real["util"] = setmetatable({ fixUtf8 = function(str) return str end }, { __index = saved_util })
    local NIW, NLW = T.NoteItemWidget, T.NotesListWidget
    NIW._lower, NIW._lower_n = {}, 0
    check("lower: accented capitals", NIW.lower("Élan ÜBER") == "élan über", NIW.lower("Élan ÜBER"))
    local lw = { notes_list = {
        { highlighted_text = "An Élan vital", user_note = "" },
        { highlighted_text = "nothing here", user_note = "ÜBER alles" },
        { highlighted_text = "élan, again" },
    }, active_filter = { search_any = "élan" } }
    NLW.applyFilter(lw)
    check("search: élan finds Élan", #lw.filtered_notes == 2, #lw.filtered_notes)
    lw.active_filter = { search_note = "über" }
    NLW.applyFilter(lw)
    check("search: über finds ÜBER in a note", #lw.filtered_notes == 1 and lw.filtered_notes[1].user_note == "ÜBER alles")
    lw.active_filter = { search_any = "élan", search_any_case = true }
    NLW.applyFilter(lw)
    check("search: case-sensitive still tells them apart", #lw.filtered_notes == 1)
    -- marks: positions found in the lowered text point at the original characters
    local str, low, map = NIW.lowerMap("Xİy élan")
    local a, b = low:find("élan", 1, true)
    check("marks: plain ASCII needs no map", select(3, NIW.lowerMap("Plain text")) == nil)
    check("marks: a longer lowered character is mapped back", map and str:sub(map.start[a], map.stop[b]) == "élan",
        map and str:sub(map.start[a], map.stop[b]))
    local ai = low:find("xiy", 1, true)
    check("marks: a character that got shorter maps to the whole original one", map and str:sub(map.start[ai], map.stop[ai + 2]) == "Xİy",
        map and str:sub(map.start[ai], map.stop[ai + 2]))
    -- a cleared search leaves no options behind
    lw.active_filter = { search_highlight = "", search_highlight_mode = "phrase", search_highlight_case = true,
        search_note = "x", search_note_mode = "any" }
    NLW.applyFilter(lw)
    local af = lw.active_filter
    check("cleared search: mode and case go", af.search_highlight == nil and af.search_highlight_mode == nil
        and af.search_highlight_case == nil)
    check("a search still set keeps its mode", af.search_note == "x" and af.search_note_mode == "any")
    lw.active_filter = { search_any_mode = "phrase", search_any_case = true }
    NLW.applyFilter(lw)
    check("no search at all: no options", next(lw.active_filter) == nil)
    real["ffi/utf8proc"], real["util"] = saved_u, saved_util
    NIW._lower, NIW._lower_n = {}, 0
end
-- the chapter filter goes when the book filter changes
do
    local af = { books = { A = true }, chapters = { ["Chapter 1"] = true }, chapters_exclude = { X = true } }
    T.NotesListWidget.booksChanged(af)
    check("book filter changed: chapters cleared", af.chapters == nil and af.chapters_exclude == nil and af.books.A)
    local w = setmetatable({ active_filter = { books = { A = true }, chapters = { ["Chapter 1"] = true } } }, { __index = T.NotesListWidget })
    local chips = w:getFilterChips()
    for _, c in ipairs(chips) do if c.label == "A" then c.clear() end end
    check("removing the book chip clears the chapter filter", w.active_filter.books == nil and w.active_filter.chapters == nil)
    -- the Books picker: picking a book clears the chapters, searching in it doesn't
    local lst = { active_filter = { books = { A = true }, chapters = { ["Chapter 1"] = true } }, applyFilter = function() end }
    local LP = T.NotesListWidget.ListPicker
    local p = setmetatable({ list = lst, inc_key = "books", exc_key = "books_exclude", build = function() end }, { __index = LP })
    p.books_sig = p:booksSig()
    p.query = "smith"
    p:changed() -- a search in the picker
    check("books picker: a search keeps the chapter filter", lst.active_filter.chapters ~= nil)
    p:set("B", "inc")
    p:changed()
    check("books picker: picking a book clears it", lst.active_filter.chapters == nil and lst.active_filter.books.B)
end

-- Cancel and Back go where you expect
do
    local SS = T.SortState
    T.setSetting("sort_mode", "author:asc")
    T.setSetting("sort_mode_bm", nil)            -- Bookmarks follow the annotation order
    T.setSetting("sort_mode_book", "book:asc,pos:asc")
    T.setSetting("sort_mode_book_bm", "date:desc")
    local snap = SS.snapshot()
    -- what a saved filter does: sets both tabs' order
    SS.setFor(false, false, "date:asc"); SS.setFor(false, true, "book:asc"); SS.setFor(true, true, "pos:asc")
    check("cancel: restore says something changed", SS.restore(snap) == true)
    check("cancel: both tabs' orders back", SS.getFor(false, false) == "author:asc" and SS.getFor(true, true) == "date:desc")
    check("cancel: Bookmarks follow the annotation order again", T.getSetting("sort_mode_bm", nil) == nil
        and SS.getFor(false, true) == "author:asc")
    check("cancel: nothing changed, nothing to redo", SS.restore(snap) == false)
    for _, k in ipairs({ "sort_mode", "sort_mode_bm", "sort_mode_book", "sort_mode_book_bm" }) do T.setSetting(k, nil) end
    -- cards: Back / tap outside run cancel_cb; a choice doesn't
    local Card = T.NotesListWidget.States.Card
    local UI = T.UIManager
    local saved_close = rawget(UI, "close")
    UI.close = function() end
    local back = 0
    local card = setmetatable({ cancel_cb = function() back = back + 1 end }, { __index = Card })
    card:onClose()
    check("card: Back goes back one level", back == 1)
    card:onClose()
    check("card: only once", back == 1)
    local chosen = setmetatable({ cancel_cb = function() back = back + 1 end }, { __index = Card })
    chosen:dismiss()
    check("card: a choice doesn't go back", back == 1)
    local outside = setmetatable({ cancel_cb = function() back = back + 1 end, dimen = { x = 0, y = 0, w = 10, h = 10 } }, { __index = Card })
    outside:onTapOutside(nil, { pos = { intersectWith = function() return false end } })
    check("card: tap outside goes back one level", back == 2)
    UI.close = saved_close
end

-- bookmarks: finding them again in the sidecar
local bnote = { bookmark = true, datetime = "d", page = "/body/p[3]" }
check("bookmark match", T.itemMatchesNote({ datetime = "d", page = "/body/p[3]", text = "in Two" }, bnote))
check("bookmark no match on other page", not T.itemMatchesNote({ datetime = "d", page = "/body/p[4]" }, bnote))
check("bookmark never matches a highlight", not T.itemMatchesNote({ datetime = "d", page = "/body/p[3]", drawer = "lighten" }, bnote))
check("bookmark match on pdf page", T.itemMatchesNote({ datetime = "d", page = 5 }, { bookmark = true, datetime = "d", page = 5 }))

-- bookmarks: tabs and filters
local blist = {
    { book_title = "A", highlighted_text = "alpha", user_note = "n", drawer = "lighten", color = "yellow" },
    { book_title = "A", highlighted_text = "beta", drawer = "lighten", color = "red" },
    { book_title = "A", highlighted_text = "", bookmark = true, page_label = 3, user_note = "page note" },
    { book_title = "B", highlighted_text = "", bookmark = true, page_label = 9 },
}
local function bfiltered(af)
    local w = { notes_list = blist, active_filter = af }
    T.NotesListWidget.applyFilter(w)
    local out = {}
    for i, n in ipairs(w.filtered_notes) do out[i] = (n.bookmark and "bm" or "hl") .. n.book_title end
    return join(out), w
end
local r, w0 = bfiltered(nil)
check("all tab leaves bookmarks out", r == "hlA|hlA", r)
check("bookmark count", w0.tab_counts.bookmarks == 2 and w0.tab_counts.all == 2)
check("highlight and note counts", w0.tab_counts.notes == 1 and w0.tab_counts.highlights == 1)
check("bookmarks tab", bfiltered({ notes_presence = "bookmarks" }) == "bmA|bmB")
check("notes tab leaves bookmarks out", bfiltered({ notes_presence = "only" }) == "hlA")
check("colour filter skips bookmarks", bfiltered({ notes_presence = "bookmarks", cs = { ["color:red"] = true } }) == "bmA|bmB")
check("book filter applies to bookmarks", bfiltered({ notes_presence = "bookmarks", books = { B = true } }) == "bmB")
check("search finds bookmark notes", bfiltered({ notes_presence = "bookmarks", search_any = "page" }) == "bmA")
local _r2, w2 = bfiltered({ notes_presence = "bookmarks", books = { B = true } })
check("tab totals ignore filters", w2.tab_totals.bookmarks == 2 and w2.tab_counts.bookmarks == 1)

-- bookmarks: page text and export
check("page text", T.NoteItemWidget.pageText({ page_label = 34 }) == "Page 34")
check("page text from pdf page", T.NoteItemWidget.pageText({ page = 5 }) == "Page 5")
check("no page text for an xpointer", T.NoteItemWidget.pageText({ page = "/body/p[3]" }) == nil)
local bmd = T.notesToMarkdown({ { book_title = "A", bookmark = true, datetime = "2026-01-09 10:00:00",
    chapter = "Two", page = "/body/p[3]", page_label = 34, highlighted_text = "", user_note = "n" } }, "")
check("markdown bookmark line", bmd:find("*Bookmark · 2026-01-09 · Two · page 34*", 1, true) ~= nil, bmd)
check("markdown no xpointer", bmd:find("/body", 1, true) == nil, bmd)

-- pickers count what the open tab is about
local NLW = T.NotesListWidget
local pw = setmetatable({ active_filter = {} }, { __index = NLW })
check("annotation counts on All", pw:countsHere({}) and not pw:countsHere({ bookmark = true }))
pw.active_filter = { notes_presence = "bookmarks" }
check("bookmark counts on Bookmarks", pw:countsHere({ bookmark = true }) and not pw:countsHere({}))
pw.active_filter = { books = { B = true } }
local kept = pw:pickerItems({ { key = "A", count = 2 }, { key = "B", count = 0 }, { key = "C", count = 0 } }, "books", "books_exclude")
check("picker keeps counted and ticked items", #kept == 2 and kept[1].key == "A" and kept[2].key == "B")

-- dates: year and time each shown always, never or only when they matter
local NIW = T.NoteItemWidget
local function fd(dt, year, time) return NIW:formatDate(dt, { year = year, time = time }) or "" end
local feb = os.date("%b", os.time({ year = 2024, month = 2, day = 3 }))
check("date: another year keeps its year", fd("2024-02-03 14:05:09", "relevant", "never") == "3 " .. feb .. " 2024")
check("date: year always", fd("2024-02-03 14:05:09", "always", "never") == "3 " .. feb .. " 2024")
check("date: time always", fd("2024-02-03 14:05:09", "always", "always") == "3 " .. feb .. " 2024, 14:05")
check("date: time only when recent (old date)", fd("2024-02-03 14:05:09", "relevant", "recent") == "3 " .. feb .. " 2024")
check("date: time only when recent (today)", fd(os.date("%Y-%m-%d 09:30:00"), "relevant", "recent") == "Today, 09:30")
check("date: this year without year", fd(os.date("%Y-01-01 08:00:00"), "relevant", "never"):match("%d%d%d%d") == nil or os.date("%m-%d") <= "01-02")
check("month: English name when KOReader's translation is missing", NIW.monthName(os.time({ year = 2024, month = 2, day = 3 }), true) == os.date("%B", os.time({ year = 2024, month = 2, day = 3 })))
check("clock: 24 hours stays as stored", NIW.twelveHour() ~= true and NIW.clockText("14:05") == "14:05")
check("clock: 12 hours", NIW.clockText("14:05", true) == "2:05 PM" and NIW.clockText("00:30", true) == "12:30 AM")
check("date: no time stored", fd("2024-02-03", "always", "always"):match(",") == nil)

-- export: options, grouping, formats, file names
local E = T.Export
local function opts(over)
    local o = {}
    for k, v in pairs(E.DEFAULTS) do o[k] = v end
    for k, v in pairs(over or {}) do o[k] = v end
    return o
end
check("export defaults from settings", E.options().format == "md" and E.options().header == true and E.options().style == false)
local mixed = {
    { book_path = "/a", book_title = "A", book_authors = "Ann\nBob", chapter = "One", datetime = "2026-01-09 10:12:00",
      highlighted_text = "first", drawer = "lighten", color = "yellow", tags = { "x", "y" }, page_label = 3 },
    { book_path = "/b", book_title = "B", chapter = "", datetime = "2026-01-10 11:00:00", highlighted_text = "second" },
    { book_path = "/a", book_title = "A", book_authors = "Ann\nBob", chapter = "Two", datetime = "2026-01-11 12:30:00",
      highlighted_text = "third", user_note = "my note\nline two" },
}
local function count(str, pat) local _s, n = str:gsub(pat, ""); return n end
local g = E.build(mixed, opts(), "")
check("export: each book once", count(g, "## A") == 1 and count(g, "## B") == 1, g)
check("export: book order of first appearance", g:find("## A", 1, true) < g:find("## B", 1, true), g)
check("export: third note stays with its book", g:find("third", 1, true) < g:find("## B", 1, true), g)
check("export: authors on one line", g:find("## A — Ann, Bob", 1, true) ~= nil, g)
local gl = E.build(mixed, opts({ group = "list" }), "")
check("export: list order repeats the book", count(gl, "## A") == 2, gl)
check("export: header", g:find("^# Annotations\n") ~= nil, g)
check("export: no header", not E.build(mixed, opts({ header = false }), "f"):find("# Annotations", 1, true))
check("export: filter line", E.build(mixed, opts(), "Notes, Hide 2 books"):find("_Filter: Notes, Hide 2 books_", 1, true) ~= nil)
check("export: no author", not E.build(mixed, opts({ author = false }), ""):find("Bob", 1, true))
local ch = E.build(mixed, opts({ chapter = "heading" }), "")
check("export: chapter headings", ch:find("### One", 1, true) and ch:find("### Two", 1, true) and not ch:find("· One", 1, true), ch)
check("export: chapter left out", not E.build(mixed, opts({ chapter = "none" }), ""):find("One", 1, true))
check("export: date and time", E.build(mixed, opts({ date = "datetime" }), ""):find("*2026-01-09 10:12 · One · page 3*", 1, true) ~= nil)
check("export: no date", not E.build(mixed, opts({ date = "none" }), ""):find("2026-01", 1, true))
local jan = os.date("%b", os.time({ year = 2026, month = 1, day = 9 }))
check("export: long date", E.build(mixed, opts({ date_style = "long" }), ""):find("9 " .. jan .. " 2026", 1, true) ~= nil)
check("export: no page", not E.build(mixed, opts({ page = false }), ""):find("page 3", 1, true))
check("export: colour and style", E.build(mixed, opts({ style = true }), ""):find("page 3 · Yellow · Lighten*", 1, true) ~= nil)
check("export: tags", E.build(mixed, opts({ tags = true }), ""):find("**Tags:** x, y", 1, true) ~= nil)
check("export: no tags by default", not g:find("Tags", 1, true))
check("export: notes", g:find("**Note:** my note  \nline two", 1, true) ~= nil, g)
check("export: notes left out", not E.build(mixed, opts({ notes = false }), ""):find("my note", 1, true))
check("export: italic highlight", E.build(mixed, opts({ highlight = "italic" }), ""):find("\n*first*\n", 1, true) ~= nil)
check("export: plain highlight", E.build(mixed, opts({ highlight = "plain" }), ""):find("\nfirst\n", 1, true) ~= nil)
check("export: quoted note", E.build(mixed, opts({ note_style = "quote" }), ""):find("> **Note:** my note\n> line two", 1, true) ~= nil)
check("export: italic note", E.build(mixed, opts({ note_style = "italic" }), ""):find("**Note:** *my note*  \n*line two*", 1, true) ~= nil)
local txt = E.build(mixed, opts({ format = "txt", style = true }), "f")
check("export txt: title", txt:find("^ANNOTATIONS\nFilter: f\n") ~= nil, txt)
check("export txt: book underline", txt:find("A — Ann, Bob\n============\n", 1, true) ~= nil, txt)
check("export txt: no markdown", not txt:find("[#>%*]"), txt)
check("export txt: note", txt:find("Note: my note\nline two", 1, true) ~= nil, txt)
check("export: escapes titles", E.build({ { book_title = "A *star* [x]", highlighted_text = "t" } }, opts(), ""):find("## A \\*star\\* \\[x\\]", 1, true) ~= nil)
check("export: highlight text not escaped", E.build({ { book_title = "A", highlighted_text = "a_b *c*" } }, opts(), ""):find("> a_b *c*", 1, true) ~= nil)
check("export: unknown book", E.build({ { highlighted_text = "t" } }, opts(), ""):find("## Unknown book", 1, true) ~= nil)
check("export: bookmarks title", E.build({ { book_title = "A", bookmark = true, page_label = 2 } }, opts(), ""):find("^# Bookmarks") ~= nil)
check("export: bookmark has no style", not E.build({ { book_title = "A", bookmark = true, drawer = "lighten", color = "red" } }, opts({ style = true }), ""):find("Red", 1, true))
-- file names
local used = {}
check("file name: unsafe characters", E.fileName('a/b:c*?"<>|', opts({ name_date = false }), used) == "a_b_c______.md")
check("file name: date", E.fileName("Book", opts(), {}, "20260109-101200") == "Book-20260109-101200.md")
check("file name: txt", E.fileName("Book", opts({ format = "txt", name_date = false }), {}) == "Book.txt")
local u2 = {}
E.fileName("Same", opts({ name_date = false }), u2)
check("file name: second one numbered", E.fileName("same", opts({ name_date = false }), u2) == "same (2).md")
local long = string.rep("é", 60) -- 120 bytes
local ln = E.fileName(long, opts({ name_date = false }), {})
check("file name: cut at whole characters", #ln <= 83 and not ln:find("[\192-\255]%.md$") and ln:sub(-3) == ".md", ln)
check("file name: empty", E.fileName("  ..  ", opts({ name_date = false }), {}) == "annotations.md")
local f1 = E.files(mixed, opts({ name_date = false }), "")
check("files: one file for several books", #f1 == 1 and f1[1].name == "annotations.md" and f1[1].count == 3)
local f2 = E.files({ mixed[1], mixed[3] }, opts({ name_date = false }), "")
check("files: one book named after it", f2[1].name == "A.md")
local fb = E.files(mixed, opts({ files = "book", name_date = false }), "f")
check("files: one per book", #fb == 2 and fb[1].name == "A.md" and fb[2].name == "B.md" and fb[1].count == 2)
check("files: no header in a book file", fb[1].text:find("^## A") ~= nil and not fb[1].text:find("Filter", 1, true))
check("files: bookmarks file name", E.files({ { book_path = "/a", book_title = "A", bookmark = true }, { book_path = "/b", book_title = "B", bookmark = true } },
    opts({ name_date = false }), "")[1].name == "bookmarks.md")
-- writing
local dir = os.tmpname()
os.remove(dir)
T.setSetting("export_dir", dir)
local lfs_ok, lfs = pcall(require, "lfs")
if lfs_ok and type(lfs) == "table" and lfs.attributes then
    local path, n = E.write(mixed, opts({ name_date = false }), "")
    check("write: one file", path == dir .. "/annotations.md" and n == 1, tostring(path) .. " " .. tostring(n))
    local fh = io.open(dir .. "/annotations.md")
    check("write: content", fh and fh:read("*a") == E.build(mixed, opts({ name_date = false }), ""))
    if fh then fh:close() end
    local p2, n2 = E.write(mixed, opts({ name_date = false, files = "book" }), "")
    check("write: a file per book", p2 == dir and n2 == 2 and io.open(dir .. "/B.md") ~= nil)
    os.remove(dir .. "/annotations.md"); os.remove(dir .. "/A.md"); os.remove(dir .. "/B.md"); lfs.rmdir(dir)
end
-- a full card: writing seems fine, closing fails -> an error, not "Exported"
do
    local real_open = io.open
    T.setSetting("export_dir", "/tmp")
    io.open = function() return { write = function() return true end, close = function() return nil, "No space left on device" end } end -- luacheck: ignore
    local fp, ferr = E.write(mixed, opts({ name_date = false }), "")
    io.open = function() return { write = function() return nil, "Input/output error" end, close = function() return true end } end -- luacheck: ignore
    local wp, werr = E.write(mixed, opts({ name_date = false }), "")
    io.open = real_open -- luacheck: ignore
    check("write: a failed close is an error", fp == nil and tostring(ferr):find("No space", 1, true) ~= nil, tostring(ferr))
    check("write: a failed write is an error", wp == nil and tostring(werr):find("Input/output", 1, true) ~= nil, tostring(werr))
end
check("filterToString: books and tags sorted", T.filterToString({ books = { Zeta = true, Alpha = true }, tags = { b = true, a = true } })
    :find("B: Alpha, Zeta", 1, true) ~= nil and T.filterToString({ tags = { b = true, a = true } }):find("T: a, b", 1, true) ~= nil)
T.setSetting("export_dir", "/proc/no/such/folder")
local bad_path, bad_err = E.write(mixed, opts(), "")
check("write: unwritable folder gives an error", bad_path == nil and bad_err ~= nil)
T.setSetting("export_dir", nil)
-- the filter line in plain words
local fw = setmetatable({ active_filter = { notes_presence = "only", books_exclude = { Zeta = true, Alpha = true },
    search_note = "love" } }, { __index = T.NotesListWidget })
check("filter label in words", fw:exportFilterLabel() == "Notes, Hide Alpha, Zeta, Note: “love”", fw:exportFilterLabel())
check("chips still count several books", fw:getFilterChips()[1].label == "Hide 2 books")

-- menu pages: a heading never ends a page, a block taller than a page is split into its rows
do
    local P = T.NotesListWidget.Page
    local function row(h, keep) return { getSize = function() return { w = 10, h = h } end, keep_with_next = keep } end
    -- 100 per page (avail 130 - bar 30): rows 60, heading 20, then 50 -> the heading goes to page 2
    local rows = { row(60), row(20, true), row(50), row(40) }
    local pages = P.splitPages(rows, 130, 30, 0)
    check("pages: heading moves to the next page", #pages == 3 and pages[1].last == 1 and pages[2].first == 2,
        #pages .. " " .. tostring(pages[1].last))
    local one = P.splitPages({ row(20), row(30) }, 130, 30, 0)
    check("pages: all fits on one page", #one == 1 and one[1].first == 1 and one[1].last == 2)
    -- a heading alone on a page stays (it can't move further)
    local lone = P.splitPages({ row(20, true), row(150) }, 130, 30, 0)
    check("pages: a heading at the top of a page stays", lone[1].first == 1)
    local block = VerticalGroup:new{ align = "left", row(60), row(60), row(60) }
    local centred = VerticalGroup:new{ row(60), row(60), row(60) }
    local _, flat3 = P.splitPages({ row(10), centred }, 130, 30, 0)
    check("pages: a centred column stays whole", #flat3 == 2)
    local pg, flat = P.splitPages({ row(10), block }, 130, 30, 0)
    check("pages: a tall block is split into its rows", #flat == 4 and #pg == 3, #flat .. " " .. #pg)
    local wide = { row(150) } -- a single tall row that isn't a column stays whole
    local _, flat2 = P.splitPages({ row(10), wide[1] }, 130, 30, 0)
    check("pages: a single tall row stays whole", #flat2 == 2)
end

-- long words, cut lines, glyphs
do
    local url = "https://example.com/" .. string.rep("abcdefghij", 8)
    local ulines = T.wrapText("see " .. url .. " here", face, 200)
    local ok_w = #ulines > 2
    for k = 1, #ulines do if 10 * #ulines[k] > 200 then ok_w = false end end
    check("wrap: a URL wider than the column is split, no line too wide", ok_w, join(ulines))
    check("wrap: nothing of the URL lost", join(ulines):gsub("|", ""):find(url, 1, true) ~= nil)
    local cut = NIW.cutLine("abcé", "…", face, 60)
    check("cut: whole characters only", cut == "abc", cut)
    local cut2 = NIW.cutLine("abé", "…", face, 70)
    check("cut: a 2-byte character kept when it fits", cut2 == "abé", cut2)
    local out, was = NIW.cutLines({ "one", "twé", "three" }, 2, face, 50, "…")
    check("cutLines: valid UTF-8 at the end", was and out[2] == "tw…", tostring(out[2]))
    check("cut: broken UTF-8 still ends", NIW.cutLine("\128\128abc", "…", face, 10) == "")
    check("bookmark glyph is 3 bytes", #NIW.BOOKMARK_CHAR == 3 and NIW.BOOKMARK_CHAR:byte(1) == 239)
end

-- page marks: the order parsed once by paginate gives the same keys as parsing it per annotation
do
    local L, SS = T.NotesListWidget, T.SortState
    local n = { book_title = "B", book_authors = "Au", chapter = "Ch", datetime = "2026-03-04 10:00:00" }
    local same = true
    for _, single in ipairs({ false, true }) do
        for _, rule in ipairs({ "date:desc", "author:asc,book:asc,pos:asc", "book:asc", "chapter:asc" }) do
            T.setSetting(single and "sort_mode_book" or "sort_mode", rule)
            local lv = SS.view(SS.get(single), single)
            if L.markKey(n, single, lv) ~= L.markKey(n, single) then same = false end
        end
    end
    T.setSetting("sort_mode", nil); T.setSetting("sort_mode_book", nil)
    check("markKey: parsed once, same keys", same)
end

-- list entries built in one place for the one-book and all-books lists
do
    check("splitTags: string", table.concat(T.splitTags(" a, b ;c|d") or {}, "+") == "a+b+c+d")
    check("splitTags: list kept, nil for nothing", #T.splitTags({ "x" }) == 1 and T.splitTags(nil) == nil)
    local book = { title = "T", authors = "A", filename = "t.epub", path = "/b/t.epub" }
    local e = T.listNote({ text = "hl", notes = "n", tags = "z, a, z", datetime = "d", color = "red" }, book, { "q" })
    check("listNote: fields", e.book_title == "T" and e.book_path == "/b/t.epub" and e.highlighted_text == "hl"
        and e.user_note == "n" and e.color == "red")
    check("listNote: own tags, sorted, no doubles", table.concat(e.tags, ",") == "a,z", table.concat(e.tags, ","))
    local e2 = T.listNote({ text = "hl" }, book, { "q" })
    check("listNote: book tags when it has none", table.concat(e2.tags, ",") == "q")
end

-- filter by author, series and language
do
    local L = T.NotesListWidget
    local mlist = {
        { book_title = "A", book_authors = "Ann\nBob", book_series = "Saga", book_language = "en", highlighted_text = "a" },
        { book_title = "B", book_authors = "Bob", book_language = "nl", highlighted_text = "b" },
        { book_title = "C", book_authors = "Unknown", highlighted_text = "c" },
    }
    local function mf(af)
        local w = { notes_list = mlist, active_filter = af }
        L.applyFilter(w)
        local out = {}
        for i, n in ipairs(w.filtered_notes) do out[i] = n.book_title end
        return table.concat(out)
    end
    check("authors: only Bob (one of two authors counts)", mf({ authors = { Bob = true } }) == "AB")
    check("authors: hide Ann", mf({ authors_exclude = { Ann = true } }) == "BC")
    check("authors: none = no author", mf({ authors = { [""] = true } }) == "C")
    check("series: only Saga", mf({ series = { Saga = true } }) == "A")
    local hn = mf({ series_exclude = { [""] = true } })
    check("series: hide none", hn == "A", hn)
    check("language: only nl", mf({ languages = { nl = true } }) == "B")
    check("language: hide en", mf({ languages_exclude = { en = true } }) == "BC")
    check("together: Bob and en", mf({ authors = { Bob = true }, languages = { en = true } }) == "A")
    check("old saved filter without these keys", mf({ books = { B = true } }) == "B")
    local fs = T.filterToString({ authors = { Bob = true, Ann = true }, series_exclude = { [""] = true }, languages = { en = true } })
    check("filterToString: authors, series, language", fs:find("A: Ann, Bob", 1, true) ~= nil and fs:find("S≠ None", 1, true) ~= nil
        and fs:find("L: en", 1, true) ~= nil, fs)
    local cw = setmetatable({ active_filter = { authors = { Bob = true }, series_exclude = { [""] = true, Saga = true } } }, { __index = L })
    local chips = cw:getFilterChips(true)
    local labels = {}
    for i, c in ipairs(chips) do labels[i] = c.label end
    check("chips: author and hidden series", table.concat(labels, "|") == "Bob|Hide None, Saga", table.concat(labels, "|"))
end

-- rotation: a popup rebuilt for the new size repaints the whole screen, so nothing of its old
-- place stays behind
do
    local UI, LW = T.UIManager, T.NotesListWidget
    local saved = { rawget(UI, "nextTick"), rawget(UI, "setDirty"), rawget(UI, "isWidgetShown") }
    local dirty = {}
    UI.nextTick = function(_, f) f() end
    UI.setDirty = function(_, w, mode) dirty[#dirty + 1] = { w = w, mode = mode } end
    UI.isWidgetShown = function() return true end
    local cls = {}
    LW.Page.watchResize(cls)
    local built = 0
    local w = setmetatable({ dimen = { w = 800, h = 600 }, build = function() built = built + 1 end }, { __index = cls })
    pcall(cls.paintTo, w, nil, 0, 0)
    check("rotation: page rebuilt once", built == 1, built)
    check("rotation: whole screen repainted", dirty[1] and dirty[1].w == "all" and dirty[1].mode == "full")
    dirty = {}
    local Card = LW.States.Card
    local card = setmetatable({ screen_w = 800, screen_h = 600, init = function() end, left = false, top = false, timeout = false, timeout_cb = false, _resize_pending = false,
        box = { paintTo = function() end } }, { __index = Card })
    card:paintTo(nil)
    check("rotation: card repaints the whole screen", dirty[1] and dirty[1].w == "all", dirty[1] and tostring(dirty[1].w))
    UI.nextTick, UI.setDirty, UI.isWidgetShown = saved[1], saved[2], saved[3]
end

-- "N of M" on Filter & sort and "All M" in ☰ count what the picker offers on this tab
do
    local LW = T.NotesListWidget
    local notes = {
        { book_title = "A", book_authors = "Ann" },
        { book_title = "B", book_authors = "Bob" },
        { book_title = "C", book_authors = "Cy", bookmark = true }, -- only bookmarks
    }
    local function view(tab, af)
        return setmetatable({ notes_list = notes, active_filter = af, tabKey = function() return tab end }, { __index = LW })
    end
    check("offered: books on the All tab", view("all", {}):offeredCount("books", "books_exclude", LW.bookKeys) == 2)
    check("offered: books on the Bookmarks tab", view("bookmarks", {}):offeredCount("books", "books_exclude", LW.bookKeys) == 1)
    check("offered: a chosen book still counts", view("all", { books = { C = true } }):offeredCount("books", "books_exclude", LW.bookKeys) == 3)
    local authors = function(n) return LW.metaValues(n, "authors") end
    check("offered: authors follow the tab", view("all", {}):offeredCount("authors", "authors_exclude", authors) == 2)
end

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
