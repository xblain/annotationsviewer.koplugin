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

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
