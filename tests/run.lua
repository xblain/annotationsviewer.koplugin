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

local real = {
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
        else if cur ~= "" then table.insert(lines, cur) end; cur = word end
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
T.setSetting("export_dir", "/proc/no/such/folder")
local bad_path, bad_err = E.write(mixed, opts(), "")
check("write: unwritable folder gives an error", bad_path == nil and bad_err ~= nil)
T.setSetting("export_dir", nil)
-- the filter line in plain words
local fw = setmetatable({ active_filter = { notes_presence = "only", books_exclude = { Zeta = true, Alpha = true },
    search_note = "love" } }, { __index = T.NotesListWidget })
check("filter label in words", fw:exportFilterLabel() == "Notes, Hide Alpha, Zeta, Note: “love”", fw:exportFilterLabel())
check("chips still count several books", fw:getFilterChips()[1].label == "Hide 2 books")

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
