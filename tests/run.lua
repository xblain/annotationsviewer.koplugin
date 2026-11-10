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
    ["luasettings"] = { open = function() return { data = {}, readSetting = function() return nil end,
        saveSetting = function() end, flush = function() end, isTrue = function() return false end } end },
}
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

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
