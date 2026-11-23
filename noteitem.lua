--[[--
The row for one annotation: the highlight text, its note, and the review-mode cover
(whole line, picked words, or a question written for it).

Moved out of main.lua, which is at Lua's 200-locals-per-chunk limit. Everything it shares with
the rest of the plugin is reached through Core; the measuring and wrapping helpers it draws with
come from Util.
]]

local InputContainer = require("ui/widget/container/inputcontainer")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local LeftContainer = require("ui/widget/container/leftcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local CenterContainer = require("ui/widget/container/centercontainer")
local TextWidget = require("ui/widget/textwidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local FrameContainer = require("ui/widget/container/framecontainer")
local ImageWidget = require("ui/widget/imagewidget")
local BlitBuffer = require("ffi/blitbuffer")
local Screen = require("device").screen
local Font = require("ui/font")
local Size = require("ui/size")
local Geom = require("ui/geometry")
local _ = require("ano_i18n").gettext

local Core = require("core")
local BOOK_GAP = Core.BOOK_GAP
local getTitleFont = Core.getTitleFont
local getInfoFont = Core.getInfoFont
local getContentFont = Core.getContentFont
local Util = require("avutil")
local UI = require("avui")
local StrikeoutLineWidget = UI.StrikeoutLineWidget
local UnderlineWidget = UI.UnderlineWidget
local ReaderHighlight = require("apps/reader/modules/readerhighlight")
local LineWidget = require("ui/widget/linewidget")
local RightContainer = require("ui/widget/container/rightcontainer")

-- Names this file calls that live in another module.
local isScrollbarStyle = Core.isScrollbarStyle
local SB_MARGIN_RIGHT = Core.SB_MARGIN_RIGHT
local SB_STRIP_WIDTH = Core.SB_STRIP_WIDTH

local TapBox = UI.TapBox
local Pill = UI.Pill

local NoteItemWidget = InputContainer:extend{ width = nil, note = nil, show_parent = nil, is_last = false, is_preview = false, disable_tap = false, skip_title = false, skip_info = false }
NoteItemWidget.review_on = false -- set by the list (NotesListWidget:setReviewMode)
-- Custom cover: the words a reader picked inside a highlight, kept per book and per annotation.
-- In review mode a highlight that has any covers just those words instead of the whole line (it is
-- the finer-grained counterpart of the whole-line cover); a highlight with none is covered whole.
-- { [book_path] = { [annotation key] = { phrase, phrase, ... } } }
-- The key is the annotation's datetime plus its position, which tells two annotations of one book
-- apart across a reload. Kept in the settings file, not in the book: this is a display choice.
NoteItemWidget.CLOZE_KEY = "annotationsviewer_cloze"
-- The notes that carry a copy of their phrases (weak keys: a note that goes away takes its entry
-- with it). Used by "Remove all" to clear the copies along with the saved setting.
NoteItemWidget._cloze_notes = setmetatable({}, { __mode = "k" })
function NoteItemWidget.clozeStore()
    local v = Core.G:readSetting(NoteItemWidget.CLOZE_KEY)
    if type(v) ~= "table" then return {} end
    return v
end
function NoteItemWidget.clozeKeyFor(note)
    if not note then return nil end
    local pos = note.pos0
    if type(pos) == "table" then pos = tostring(pos.x) .. "," .. tostring(pos.y) end
    return tostring(note.datetime or "") .. "|" .. tostring(pos or note.page or "")
end
-- The phrases picked for this note, or nil when there are none (the whole line is covered then).
-- The note object carries its own copy while the list is open (`_av_cloze`), which is what the row
-- is drawn from; the settings file is the fallback across a reload. The exact key is tried first,
-- then an entry whose key starts with the note's datetime (the position half of a key can be
-- written differently after a reload).
function NoteItemWidget.clozePhrases(note)
    if not note then return nil end
    local own = note._av_cloze
    if type(own) == "table" and #own > 0 then return own end
    local book = note.book_path and NoteItemWidget.clozeStore()[note.book_path]
    if type(book) ~= "table" then return nil end
    local list = book[NoteItemWidget.clozeKeyFor(note)]
    if type(list) == "table" and #list > 0 then
        note._av_cloze = list -- remembered on the note for the rows drawn from it
        return list
    end
    local stamp = tostring(note.datetime or "")
    if stamp == "" then return nil end
    for key, value in pairs(book) do
        if type(value) == "table" and #value > 0 and type(key) == "string" and key:sub(1, #stamp) == stamp then
            note._av_cloze = value
            return value
        end
    end
    return nil
end
function NoteItemWidget.setClozePhrases(note, phrases)
    if not note then return end
    -- on the note itself first: the list is drawn from that object, and it is the same object the
    -- card was opened for, so the change shows as soon as the row is redrawn
    note._av_cloze = (phrases and #phrases > 0) and phrases or nil
    NoteItemWidget._cloze_notes[note] = note._av_cloze and true or nil
    if not note.book_path then return end
    local store = NoteItemWidget.clozeStore()
    local key = NoteItemWidget.clozeKeyFor(note)
    local book = store[note.book_path]
    if type(book) ~= "table" then book = {} store[note.book_path] = book end
    if phrases and #phrases > 0 then
        book[key] = phrases
    else
        book[key] = nil
        if next(book) == nil then store[note.book_path] = nil end
    end
    if next(store) == nil then
        Core.G:delSetting(NoteItemWidget.CLOZE_KEY)
    else
        Core.G:saveSetting(NoteItemWidget.CLOZE_KEY, store)
    end
    Core.G:flush() -- saveSetting only changes memory; without this the pick is lost
end
-- Question cover: one question written for a whole annotation. In review mode the annotation's
-- text is replaced by its question (in bold) instead of an empty colour bar, so the reader has
-- something to answer; a tap swaps between the question and the text, and back.
-- Kept like the picked words: { [book_path] = { [annotation key] = "question" } }, on the settings
-- file. When an annotation has both, the question wins (its whole text is replaced anyway).
NoteItemWidget.QUESTION_KEY = "annotationsviewer_question"
function NoteItemWidget.questionStore()
    local v = Core.G:readSetting(NoteItemWidget.QUESTION_KEY)
    if type(v) ~= "table" then return {} end
    return v
end
-- The question written for this note, or nil. Same lookup as the picked words: the copy on the
-- note first, then the exact key, then an entry starting with the note's datetime.
function NoteItemWidget.noteQuestion(note)
    if not note then return nil end
    local own = note._av_question
    if type(own) == "string" and own ~= "" then return own end
    local book = note.book_path and NoteItemWidget.questionStore()[note.book_path]
    if type(book) ~= "table" then return nil end
    local q = book[NoteItemWidget.clozeKeyFor(note)]
    if type(q) == "string" and q ~= "" then
        note._av_question = q
        return q
    end
    local stamp = tostring(note.datetime or "")
    if stamp == "" then return nil end
    for key, value in pairs(book) do
        if type(value) == "string" and value ~= "" and type(key) == "string" and key:sub(1, #stamp) == stamp then
            note._av_question = value
            return value
        end
    end
    return nil
end
function NoteItemWidget.setNoteQuestion(note, question)
    if not note then return end
    question = (type(question) == "string" and question:gsub("^%s+", ""):gsub("%s+$", "")) or ""
    note._av_question = (question ~= "") and question or nil
    NoteItemWidget._cloze_notes[note] = note._av_cloze or note._av_question or nil
    if not note.book_path then return end
    local store = NoteItemWidget.questionStore()
    local key = NoteItemWidget.clozeKeyFor(note)
    local book = store[note.book_path]
    if type(book) ~= "table" then book = {} store[note.book_path] = book end
    if question ~= "" then
        book[key] = question
    else
        book[key] = nil
        if next(book) == nil then store[note.book_path] = nil end
    end
    if next(store) == nil then
        Core.G:delSetting(NoteItemWidget.QUESTION_KEY)
    else
        Core.G:saveSetting(NoteItemWidget.QUESTION_KEY, store)
    end
    Core.G:flush()
end
-- Whether this note has a question that review mode can show as the question.
function NoteItemWidget.questionFor(note)
    if not NoteItemWidget.review_on or not note then return nil end
    if note.bookmark or note._av_revealed then return nil end
    if not (note.highlighted_text and note.highlighted_text ~= "") then return nil end
    if Core.getSetting("review_question_always", true) ~= true and not Core.reviewCoversDrawer(note.drawer) then
        return nil
    end
    return NoteItemWidget.noteQuestion(note)
end
-- Removes the picked words (and/or the questions) from every note in `notes`, which is what the
-- list is showing right now: "Remove all" in Settings clears what the reader can see, not every book
-- behind their back. Within one book that is that book's annotations; in the whole-library list it
-- is whatever the filters leave (a book filter, a search ...). Returns true when anything went.
function NoteItemWidget.clearClozeFor(notes, what)
    local went = false
    local cloze_store = NoteItemWidget.clozeStore()
    local q_store = NoteItemWidget.questionStore()
    for _i, note in ipairs(notes or {}) do
        local book = note.book_path
        local key = book and NoteItemWidget.clozeKeyFor(note)
        if book and key then
            if what ~= "question" and type(cloze_store[book]) == "table" and cloze_store[book][key] then
                cloze_store[book][key] = nil
                if next(cloze_store[book]) == nil then cloze_store[book] = nil end
                went = true
            end
            if what ~= "cloze" and type(q_store[book]) == "table" and q_store[book][key] then
                q_store[book][key] = nil
                if next(q_store[book]) == nil then q_store[book] = nil end
                went = true
            end
        end
        if what ~= "question" then note._av_cloze = nil end
        if what ~= "cloze" then note._av_question = nil end
    end
    if what ~= "question" then
        if next(cloze_store) == nil then
            Core.G:delSetting(NoteItemWidget.CLOZE_KEY)
        else
            Core.G:saveSetting(NoteItemWidget.CLOZE_KEY, cloze_store)
        end
    end
    if what ~= "cloze" then
        if next(q_store) == nil then
            Core.G:delSetting(NoteItemWidget.QUESTION_KEY)
        else
            Core.G:saveSetting(NoteItemWidget.QUESTION_KEY, q_store)
        end
    end
    Core.G:flush()
    return went
end
-- How many of `notes` have picked words / a question (what the two "Remove all" rows say).
function NoteItemWidget.countClozeFor(notes, what)
    local n = 0
    for _i, note in ipairs(notes or {}) do
        local hit = false
        if what ~= "question" and NoteItemWidget.clozePhrases(note) then hit = true end
        if not hit and what ~= "cloze" and NoteItemWidget.noteQuestion(note) then hit = true end
        if hit then n = n + 1 end
    end
    return n
end
-- Anything picked or asked at all, in any book (for the Settings page while no list is open).
function NoteItemWidget.hasAnyCloze() return next(NoteItemWidget.clozeStore()) ~= nil end
function NoteItemWidget.hasAnyQuestion() return next(NoteItemWidget.questionStore()) ~= nil end
-- [byte] = true for every byte of `text` that one of the picked phrases covers, or nil when none
-- of them occurs. Worked out on the whole highlight (not on a drawn line), so a phrase that wraps
-- across two lines is still found.
function NoteItemWidget.clozeMarks(text, phrases)
    if not text or text == "" or not phrases or #phrases == 0 then return nil end
    local sorted = {}
    for _i, ph in ipairs(phrases) do
        if type(ph) == "string" and ph ~= "" then table.insert(sorted, ph) end
    end
    if #sorted == 0 then return nil end
    -- longest first, so a phrase inside a longer one does not take its characters
    table.sort(sorted, function(a, b) return #a > #b end)
    local marks = {}
    for _i, ph in ipairs(sorted) do
        local from = 1
        while true do
            local s = text:find(ph, from, true)
            if not s then break end
            for b = s, s + #ph - 1 do marks[b] = true end
            from = s + 1
        end
    end
    return next(marks) and marks or nil
end
-- Splits a line into { text, covered } runs: what the reader left in the field is covered byte for
-- byte, everything around it is not. The text is never re-cut here: each run is a slice of the
-- original line, so the pieces joined back together are exactly the line again (no character can
-- be split in two, and the line keeps its width and wrapping).
-- phrases: the picked phrases, matched against `line` itself.
-- marks/base: instead of that, marks already worked out on the whole highlight, and where this
-- line starts in it (so a phrase wrapped across lines still covers its part of each).
-- A line nothing covers comes back as one uncovered run.
function NoteItemWidget.splitClozeRuns(line, phrases, marks, base)
    if not line or line == "" then return {} end
    local shift = 0
    if not marks then
        marks = NoteItemWidget.clozeMarks(line, phrases)
        if not marks then return { { text = line, covered = false } } end
    else
        shift = (base or 1) - 1
    end
    -- walk the bytes and group them; a character is never split because the marks come from whole
    -- phrase occurrences, which always start and end on character boundaries
    local runs = {}
    local i = 1
    while i <= #line do
        local covered = marks[i + shift] == true
        local j = i
        while j <= #line and (marks[j + shift] == true) == covered do j = j + 1 end
        local last = runs[#runs]
        if last and last.covered == covered then
            last.text = last.text .. line:sub(i, j - 1)
        else
            table.insert(runs, { text = line:sub(i, j - 1), covered = covered })
        end
        i = j
    end
    return runs
end
-- Search without capitals in every language, as KOReader's own search does (Utf8Proc folds
-- "Élan" to "élan", "ÜBER" to "über"); string.lower only knows A-Z. Kept per text.
NoteItemWidget._lower = {}
NoteItemWidget._lower_n = 0
function NoteItemWidget.lower(s)
    if type(s) ~= "string" or s == "" then return s or "" end
    local l = NoteItemWidget._lower[s]
    if l then return l end
    local ok, r = pcall(function() return require("ffi/utf8proc").lowercase(require("avutil").fixUtf8(s, "?")) end)
    l = (ok and type(r) == "string") and r or s:lower()
    NoteItemWidget._lower[s] = l
    NoteItemWidget._lower_n = NoteItemWidget._lower_n + 1
    return l
end
-- For marking matches in a drawn line: the text lowered character by character (one character
-- for one, as TextBoxWidget's own search does), with, for every byte of it, where that character
-- starts and ends in the text. Returns the text (made valid UTF-8), the lowered text and the map.
function NoteItemWidget.lowerMap(s)
    local ok_u, util = pcall(require, "util")
    if ok_u and util.fixUtf8 then s = util.fixUtf8(s, "?") end
    local ok, low = pcall(function() return require("ffi/utf8proc").lowercase(s, false) end)
    if not ok or type(low) ~= "string" then low = s:lower() end
    if not s:find("[\128-\255]") then return s, low, nil end -- plain ASCII: positions are the same
    local pat = "[%z\1-\127\192-\253][\128-\191]*"
    local orig, lowc = {}, {}
    for c in s:gmatch(pat) do orig[#orig + 1] = c end
    for c in low:gmatch(pat) do lowc[#lowc + 1] = c end
    if #orig ~= #lowc then return s, s:lower(), nil end
    local map, ob, lb = { start = {}, stop = {} }, 1, 1
    for i = 1, #orig do
        for k = 0, #lowc[i] - 1 do
            map.start[lb + k] = ob
            map.stop[lb + k] = ob + #orig[i] - 1
        end
        ob, lb = ob + #orig[i], lb + #lowc[i]
    end
    return s, low, map
end
-- A highlight colour as painted, and its name: the name you gave it in KOReader when it has one.
NoteItemWidget.colorValue = getHighlightColor
function NoteItemWidget.colorLabel(key)
    if type(key) ~= "string" or key == "" then return "" end
    key = key:lower()
    if ReaderHighlight.getHighlightColorString then
        local ok, name = pcall(ReaderHighlight.getHighlightColorString, ReaderHighlight, key)
        -- the key itself comes back for a colour KOReader doesn't know, unless you named it so
        local own = ReaderHighlight.custom_colors and ReaderHighlight.custom_colors[key]
        if ok and type(name) == "string" and name ~= "" and (name ~= key or (type(own) == "table" and own.name == key)) then
            return name
        end
    end
    for _i, v in ipairs(ReaderHighlight.highlight_colors or {}) do
        if v[2] == key then return v[1] end
    end
    return key:sub(1, 1):upper() .. key:sub(2)
end

-- Longest a note (the text you wrote) is shown in the list; longer ones end with "...".
NoteItemWidget.DEFAULT_NOTE_LINES = 5
-- font of the user notes: its own font / size, otherwise the same as the highlight text
function NoteItemWidget.noteFace()
    local font = Core.getSetting("note_font", nil)
    if not font or font == "" then font = getContentFont() end
    local size = Core.getSetting("note_font_size", nil) or Core.getContentFontSize()
    return Core.getFaceOr(font ~= "" and font or Core.SERIF_FONT, size, "cfont")
end
-- space between the highlight and its note
function NoteItemWidget.noteOffset() return Screen:scaleBySize(Core.getSetting("note_offset", 8)) end
-- how far the note is moved in from the left
function NoteItemWidget.noteIndent() return Screen:scaleBySize(Core.getSetting("note_indent", 0)) end
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
function NoteItemWidget.lineSpacing() return Screen:scaleBySize(Core.getSetting("line_spacing", 0)) end
-- Review mode. Whether an annotation's text is hidden right now: only while review mode is on,
-- only for the styles chosen in Settings, only for a real highlight (not a bookmark or a bare
-- note) and only until that row is tapped again (note._av_revealed).
function NoteItemWidget.isCovered(note)
    if not NoteItemWidget.review_on or not note then return false end
    if note.bookmark or note._av_revealed then return false end
    if not (note.highlighted_text and note.highlighted_text ~= "") then return false end
    return Core.reviewCoversDrawer(note.drawer)
end
-- "Cover only the note when there is one" (on by default): a highlight that has a note keeps its
-- text and only the note below it is hidden, so the highlight can be read and the note recalled
-- from it. Off: the highlight and its note are both hidden.
-- Words the reader picked inside the highlight win over this: those words are what is being
-- recalled, so they are covered even when the rest of the line (and its note) stay readable —
-- the two add up rather than replace each other.
function NoteItemWidget.coverHighlight(note)
    if not NoteItemWidget.isCovered(note) then return false end
    if NoteItemWidget.clozePhrases(note) then return true end
    if note.user_note and note.user_note ~= "" and Core.getSetting("review_note_only", true) == true then
        return false
    end
    return true
end
-- The words picked inside this highlight, when review mode should cover them: only while review
-- mode is on and the row has not been tapped open.
-- "Cover the picked words even when their style is not covered" (on by default) lets them through
-- whatever the styles in Settings say — the reader picked those words on purpose, so a style left
-- unticked is not a reason to show them. Off, they follow the style choice like the whole line.
function NoteItemWidget.clozeCovered(note)
    if not NoteItemWidget.review_on or not note then return false end
    if note.bookmark or note._av_revealed then return false end
    if not (note.highlighted_text and note.highlighted_text ~= "") then return false end
    if Core.getSetting("review_cloze_always", true) == true then return true end
    return Core.reviewCoversDrawer(note.drawer)
end
-- The note (the text you wrote) under an annotation is hidden in review mode:
--   - a bookmark's note, always (it has no highlight to read);
--   - with "Always cover notes" on (the default), whatever the style choice is: a note is what
--     is recalled from the highlight, so it is hidden even when its own style is not covered.
--     Choosing no style at all turns this on by itself, so "notes only" always hides the notes;
--   - off: a note is hidden only when its own style is covered.
function NoteItemWidget.coverNote(note)
    if not note or not NoteItemWidget.review_on or note._av_revealed then return false end
    if not (note.user_note and note.user_note ~= "") then return false end
    if note.bookmark then return true end -- no highlight to read: the note is the annotation
    if Core.getSetting("review_notes_always", true) == true then return true end
    return NoteItemWidget.isCovered(note)
end
-- What a covered line is drawn in: the same text in its own highlight's colour, so it reads as
-- an empty coloured bar (a yellow highlight stays yellow, an underlined one just goes blank)
-- instead of a black block. The colour is the one the row already paints behind the text.
function NoteItemWidget.maskColor(note)
    local drawer = note and note.drawer
    if drawer == "invert" then return BlitBuffer.COLOR_BLACK end
    if Core.isNoBackgroundStyle(drawer) then return BlitBuffer.COLOR_WHITE end -- no fill: just blank
    return Core.getHighlightColor(note and note.color)
end
function NoteItemWidget.noteLinesMax()
    local v = tonumber(Core.getSetting("truncate_note_lines", NoteItemWidget.DEFAULT_NOTE_LINES))
    if not v or v < 1 then return NoteItemWidget.DEFAULT_NOTE_LINES end
    return v
end
-- A line shortened until it fits `width` with `ell` after it, by whole characters (never half
-- of one). Returns the line without the ell.
function NoteItemWidget.cutLine(line, ell, face, width)
    while #line > 0 and Util.measureTextWidth(line .. ell, face) > width do
        local shorter = line:gsub("[^\128-\191][\128-\191]*$", "")
        if shorter == line then shorter = line:sub(1, -2) end -- broken UTF-8: a byte at a time
        line = shorter
    end
    return line
end
-- First `max` lines, the last one shortened to take the ell ("..." unless given).
function NoteItemWidget.cutLines(lines, max, face, width, ell)
    if #lines <= max then return lines, false end
    ell = ell or "..."
    local out = {}
    for i = 1, max do out[i] = lines[i] end
    out[max] = NoteItemWidget.cutLine(out[max], ell, face, width) .. ell
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
    local title_size, info_size, content_size = Core.getTitleFontSize(), Core.getInfoFontSize(), Core.getContentFontSize()
    local title_face = Core.getFaceOr(title_font ~= "" and title_font or Core.SERIF_FONT, title_size, "cfont")
    local info_face = Core.getFaceOr(info_font, info_size, "cfont")
    local content_face = Core.getFaceOr(content_font ~= "" and content_font or Core.SERIF_FONT, content_size, "cfont")
    return title_face, info_face, content_face
end

-- Font of the author name in the book header: its own font / size when set, otherwise exactly the
-- info face (what the author always used).
function NoteItemWidget.authorFace()
    local font, size = Core.getSetting("author_font", nil), Core.getSetting("author_font_size", nil)
    local _, info_face = NoteItemWidget.getNoteFaces()
    if (not font or font == "") and not size then return info_face end
    if not font or font == "" then font = getInfoFont() end
    return Core.getFaceOr(font, tonumber(size) or Core.getInfoFontSize(), "cfont")
end

-- Capitals: KOReader's UTF-8 aware upper-casing when it has one (accents), else plain ASCII upper
function NoteItemWidget.upper(str)
    local ok, u = pcall(require, "ffi/utf8proc")
    if ok and type(u) == "table" and u.uppercase_dumb then
        local ok2, r = pcall(u.uppercase_dumb, str)
        if ok2 and type(r) == "string" then return r end
    end
    return str:upper()
end
-- Book title and chapter headings / the chapter · date line, in capitals when the setting says so
function NoteItemWidget.titleText(str)
    return Core.getSetting("title_case", "normal") == "upper" and NoteItemWidget.upper(str) or str
end
function NoteItemWidget.infoText(str)
    return Core.getSetting("info_case", "normal") == "upper" and NoteItemWidget.upper(str) or str
end

-- Text of the line above each highlight (chapter · date), or "" when the row is turned off.
-- The author is shown in the book header instead (see getHeaderAuthor).
local function buildInfoText(note, note_wrapper, skip_title, hide_chapter) -- luacheck: ignore 212
    if not Core.getShowInfo() then return "" end
    local info_fields = {}
    for f in Core.getInfoFields():gmatch("[^,]+") do info_fields[f] = true end
    local info_parts = {}
    if info_fields["chapter"] and not hide_chapter and note.chapter and note.chapter ~= "" then
        table.insert(info_parts, NoteItemWidget.chapterLabel(note.chapter))
    end
    -- the date: always, or (setting) only when the order goes by date
    local show_date = info_fields["date"] and NoteItemWidget.infoShowsDate()
    local date_text = show_date and NoteItemWidget:formatDate(note.datetime) or ""
    if date_text ~= "" then table.insert(info_parts, date_text) end
    return NoteItemWidget.infoText(table.concat(info_parts, " · "))
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
    local q = query
    if not case_sensitive then q = select(2, NoteItemWidget.lowerMap(query)) end
    local function words_in(str)
        local found = {}
        local hay, map = str, nil
        if not case_sensitive then str, hay, map = NoteItemWidget.lowerMap(str) end
        for word in q:gmatch("%S+") do
            local from = 1
            while true do
                local a, b = hay:find(word, from, true)
                if not a then break end
                from = b + 1
                if map then a, b = map.start[a], map.stop[b] end -- back to the text's own bytes
                local pre = TextWidget:new{ text = str:sub(1, a - 1), face = face }
                local mid = TextWidget:new{ text = str:sub(a, b), face = face }
                table.insert(found, { x = pre:getSize().w, w = mid:getSize().w })
                pre:free(); mid:free()
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
-- Author shown on the right of the book header, in capitals (or as written, by setting); nil when off.
local function getHeaderAuthor(note_wrapper)
    if not Core.getShowInfo() then return nil end
    if not Core.getInfoFields():find("author", 1, true) then return nil end
    local a = note_wrapper:getDisplayAuthors()
    if not a or a == "" or a == "Unknown" then return nil end
    return Core.getSetting("author_case", "upper") == "normal" and a or NoteItemWidget.upper(a)
end
local HEADER_AUTHOR_GAP = Screen:scaleBySize(12)
local HEADER_LINE_GAP = Screen:scaleBySize(3)
-- Size of the book header: title on the left, author on the right, thin line below.
-- Returns title width, author max width and total height. Shared by measuring and drawing.
local function getHeaderLayout(title_text, author_text, title_face, info_face, content_width)
    local author_w = 0
    if author_text then
        author_w = math.min(Util.measureTextWidth(author_text, info_face), math.floor(content_width * 0.4))
    end
    local title_w = content_width - (author_text and (author_w + HEADER_AUTHOR_GAP) or 0)
    local title_h = Util.getBoxHeight(title_text, title_face, title_w, true)
    return title_w, author_w, title_h + HEADER_LINE_GAP + Size.line.thin
end

local NOTE_ICON_CHAR = "\238\171\170" -- U+EAEA, pencil (Material Design, in KOReader's symbol font)

-- Height NoteItemWidget:init() would produce for these params, computed without building
-- any widgets. Must mirror the layout in NoteItemWidget:init().
-- Width of the annotation column: portrait uses all the room the scrollbar leaves (the side
-- margin does the rest); landscape uses the "Landscape width" share of the screen, centred.
function NoteItemWidget.columnWidth(avail, W, H)
    if W <= H then return avail end
    local pct = tonumber(Core.getSetting("landscape_width_pct", 80)) or 80
    return math.min(avail, math.floor(W * math.max(pct, 30) / 100))
end
-- Width the annotations may use: with a scrollbar they reach to the middle of its track (the side margin
-- does the rest). A small side margin would put the text behind the scrollbar strip, so then the
-- column is made narrower to keep a little air between the text and the strip.
-- How far both sides are pushed in so that text stays clear of the scrollbar (thumb, marks, page number):
-- 0 when the side margin is already wide enough. The same on the left and the right, so the text stays centred.
-- no_sb: the list fits on one page, so no scrollbar is drawn and the full width is used.
function NoteItemWidget.scrollInset(no_sb)
    if no_sb or not isScrollbarStyle() then return 0 end
    return math.max(0, Screen:scaleBySize(22) - Core.getHMargin())
end
function NoteItemWidget.listAvail(W, no_sb)
    if no_sb or not isScrollbarStyle() then return W end
    local center = W - SB_STRIP_WIDTH - SB_MARGIN_RIGHT + math.floor(SB_STRIP_WIDTH / 2)
    return center - 2 * NoteItemWidget.scrollInset()
end
function NoteItemWidget.showHeadings() return Core.getSetting("chapter_headings", true) ~= false end
function NoteItemWidget.repeatChapter() return Core.getSetting("repeat_chapter_on_page", true) ~= false end
-- Chapter heading of the one-book list: drawn exactly like a book header (same font, line, margin).
function NoteItemWidget.headingHeight(chapter, width)
    local content_width = width - Core.getHMargin() * 2 - Size.padding.default * 2
    local title_face, info_face = NoteItemWidget.getNoteFaces()
    local _tw, _aw, header_h = NoteItemWidget.getHeaderLayout(NoteItemWidget.titleText(NoteItemWidget.chapterLabel(chapter)), nil, title_face, info_face, content_width)
    return header_h + Core.getTitleMargin()
end
function NoteItemWidget.chapterHeading(chapter, width)
    local h_margin = Core.getHMargin()
    local h_padding = Size.padding.default
    local inner_width = width - h_margin * 2
    local content_width = inner_width - h_padding * 2
    local title_face, info_face = NoteItemWidget.getNoteFaces()
    local text = NoteItemWidget.titleText(NoteItemWidget.chapterLabel(chapter))
    local title_w, _aw, header_h = NoteItemWidget.getHeaderLayout(text, nil, title_face, info_face, content_width)
    local widget = VerticalGroup:new{ align = "left",
        TextBoxWidget:new{ text = text, face = title_face, width = title_w, alignment = "left", bold = true },
        VerticalSpan:new{ width = HEADER_LINE_GAP },
        LineWidget:new{ dimen = Geom:new{ w = content_width, h = Size.line.thin }, background = Core.COLORS.line_light } }
    widget = CenterContainer:new{ dimen = Geom:new{ w = content_width, h = header_h }, widget }
    return HorizontalGroup:new{ HorizontalSpan:new{ width = h_margin + h_padding },
        VerticalGroup:new{ widget, VerticalSpan:new{ width = Core.getTitleMargin() } } }
end
-- A bookmark's line in the list, drawn like the info row above a highlight (same font and size):
-- ribbon and chapter on the left, "Page 34 · 8 Jan" on the right. Under a chapter heading (one
-- book) the chapter is left out and the page moves to the left. The date only shows when the
-- order goes by date. Bookmarks keep no text from the page, so this line and the note are all.
NoteItemWidget.BOOKMARK_CHAR = "\239\130\151" -- U+F097, KOReader's own bookmark mark (same font as the note icon)
function NoteItemWidget.pageText(note)
    local label = note.page_label
    if label == nil and type(note.page) == "number" and note.page > 0 then label = note.page end
    if label == nil or label == "" then return nil end
    return _("Page") .. " " .. tostring(label)
end
-- Bookmark settings: only what differs from an annotation. A bookmark is one short line (plus its
-- note), so it has its own space between bookmarks, its own size for that line (the info row's
-- size until changed) and its own choice of when the date shows. Fonts, capitals, margins and the
-- note's font and lines are the annotations' own.
NoteItemWidget.DEFAULT_BM_SPACING = 18
function NoteItemWidget.bmSpacing() return Screen:scaleBySize(Core.getSetting("bm_spacing", NoteItemWidget.DEFAULT_BM_SPACING)) end
function NoteItemWidget.bookmarkFace()
    local font, size = Core.getSetting("bm_font", nil), tonumber(Core.getSetting("bm_line_size", nil))
    if (not font or font == "") and not size then return (select(2, NoteItemWidget.getNoteFaces())) end
    if not font or font == "" then font = getInfoFont() end
    return Core.getFaceOr(font, size or Core.getInfoFontSize(), "cfont")
end
-- the ribbon and the space after it: the bookmark's chapter text and its note start this far in.
-- The column is as wide as the ribbon or the note icon, whichever is wider, so the note does not
-- move when its icon is turned on or off.
function NoteItemWidget.bookmarkIndent()
    return NoteItemWidget.bookmarkColumn() + Screen:scaleBySize(8)
end
function NoteItemWidget.bookmarkColumn()
    -- asked for every bookmark on a page: measured once per pair of faces
    local bf, nf = NoteItemWidget.bookmarkFace(), NoteItemWidget.noteFace()
    local c = NoteItemWidget._bm_col
    if not (c and c.bf == bf and c.nf == nf) then
        c = { bf = bf, nf = nf, w = math.max(Util.measureTextWidth(NoteItemWidget.BOOKMARK_CHAR, bf), Util.measureTextWidth(NOTE_ICON_CHAR, nf)) }
        NoteItemWidget._bm_col = c
    end
    return c.w
end
-- A bookmark's note: without the note icon (default) it lines up with the chapter text; with it,
-- the icon sits under the ribbon as on an annotation.
function NoteItemWidget.bmNoteIcon() return Core.getSetting("bm_note_icon", false) == true end
-- "sort" (only when the order goes by date), "always" or "never"
function NoteItemWidget.bmDate() return Core.getSetting("bm_date", "sort") end
-- Space above an item in the list: between bookmarks their own (smaller) space, else the space
-- between annotations; a new book header adds the book gap.
function NoteItemWidget.gapAbove(note, skip_title)
    return (note and note.bookmark and NoteItemWidget.bmSpacing() or Core.getNoteSpacing()) + (skip_title and 0 or BOOK_GAP)
end
-- Whether the info row above a highlight shows the date: the Date field is on and, with the
-- "when sorted by date" setting, the order goes by date.
function NoteItemWidget.infoShowsDate()
    local single = NoteItemWidget.list_single
    local key = Core.getInfoFields() .. "|" .. Core.getSetting("info_date_when", "always") .. "|" .. Core.SortState.get(single) .. tostring(single)
    if NoteItemWidget._isd_key ~= key then -- asked once per annotation when paging: worked out once
        local on = false
        for f in Core.getInfoFields():gmatch("[^,]+") do if f == "date" then on = true end end
        NoteItemWidget._isd_key = key
        NoteItemWidget._isd = on and (Core.getSetting("info_date_when", "always") ~= "sort" or NoteItemWidget.sortUsesDate(single))
    end
    return NoteItemWidget._isd
end
-- What makes two info rows "the same" for "Hide duplicate info header". A date that is not shown
-- does not count, or rows that look the same would both be drawn.
function NoteItemWidget.infoKey(note, fields_setting)
    local parts = {}
    local fields = {}
    for f in fields_setting:gmatch("[^,]+") do fields[f] = true end
    if fields["date"] and NoteItemWidget.infoShowsDate() then
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
-- Whether the open order uses the date (then a bookmark shows its date).
function NoteItemWidget.sortUsesDate(single)
    for _, l in ipairs(Core.SortState.view(Core.SortState.get(single), single)) do
        if l.key == "date" then return true end
    end
    return false
end
function NoteItemWidget.bookmarkRow(note, content_width, hide_chapter, single)
    local info_face = NoteItemWidget.bookmarkFace()
    local chapter = (not hide_chapter and note.chapter and note.chapter ~= "") and NoteItemWidget.chapterLabel(note.chapter) or nil
    local page = NoteItemWidget.pageText(note)
    local when = NoteItemWidget.bmDate()
    local date = (when == "always" or (when == "sort" and NoteItemWidget.sortUsesDate(single)))
        and NoteItemWidget:formatDate(note.datetime) or nil
    local left_text, right_parts = chapter, {}
    if left_text then
        if page then table.insert(right_parts, page) end
    else
        left_text = page or _("Bookmark")
    end
    if date then table.insert(right_parts, date) end
    local right_text = NoteItemWidget.infoText(table.concat(right_parts, " · "))
    local gap = Screen:scaleBySize(12)
    local right = right_text ~= "" and TextWidget:new{ text = right_text, face = info_face, fgcolor = Core.COLORS.muted,
        max_width = math.floor(content_width * 0.6) } or nil
    local right_w = right and right:getSize().w or 0
    local icon = TextWidget:new{ text = NoteItemWidget.BOOKMARK_CHAR, face = info_face }
    local col = NoteItemWidget.bookmarkColumn()
    local icon_gap = NoteItemWidget.bookmarkIndent() - col
    local label = TextWidget:new{ text = NoteItemWidget.infoText(left_text), face = info_face,
        max_width = math.max(Screen:scaleBySize(24), content_width - col - icon_gap - right_w - gap) }
    local h = math.max(label:getSize().h, icon:getSize().h)
    -- the mark is centred on the height of the text next to it
    local left = HorizontalGroup:new{ align = "center",
        CenterContainer:new{ dimen = Geom:new{ w = col, h = h }, icon },
        HorizontalSpan:new{ width = icon_gap }, label }
    local d = Geom:new{ w = content_width, h = h }
    return OverlapGroup:new{ dimen = d, allow_mirroring = false,
        LeftContainer:new{ dimen = d, left }, right and RightContainer:new{ dimen = d, right } or nil }
end
local function measureNoteHeight(note, width, skip_title, skip_info)
    local h_margin = Core.getHMargin()
    local text_margin = Core.getTextMargin()
    local inner_width = width - h_margin * 2
    local content_width = inner_width - Size.padding.default * 2
    local line_width = content_width - text_margin * 2 - Size.padding.small * 2
    local title_face, info_face, content_face = NoteItemWidget.getNoteFaces()
    local note_wrapper = Core.NoteWrapper:new(note)

    local h = 0
    if not skip_title then
        local _tw, _aw, header_h = NoteItemWidget.getHeaderLayout(NoteItemWidget.titleText(note.book_title or _("Unknown book")),
            NoteItemWidget.getHeaderAuthor(note_wrapper), title_face, NoteItemWidget.authorFace(), content_width)
        h = h + header_h + Core.getTitleMargin()
    end
    if note.bookmark then
        -- the bookmark line takes the place of the info row (and there is no highlight). It is one
        -- line of text and a mark in the same face, so it is as high as a line in that face
        -- (a TextWidget's height comes from its face, not its text).
        h = h + Util.getLineHeight(NoteItemWidget.bookmarkFace())
    else
        local info_text = NoteItemWidget.buildInfoText(note, note_wrapper, skip_title, NoteItemWidget.measure_hide_chapter)
        local info_visible = not skip_info and info_text ~= ""
        if info_visible then
            h = h + Util.getBoxHeight(info_text, info_face, content_width, false)
        end
        if (not skip_title) or info_visible then
            h = h + Core.getInfoMargin()
        end
    end
    local line_h = Util.getLineHeight(content_face)
    if note_wrapper:hasHighlightedText() then
        local n = #Core.wrapText(note.highlighted_text or "", content_face, line_width)
        local max_lines = Core.getTruncateLines() or math.huge
        if n > max_lines then n = max_lines end
        h = h + n * (line_h + 2 + NoteItemWidget.lineSpacing()) -- each line has 1px padding above and below, plus the line spacing
    end    if note_wrapper:hasUserNote() then
        -- a bookmark's note sits where a highlight's text would: the info margin below its line
        h = h + (note.bookmark and Core.getInfoMargin() or NoteItemWidget.noteOffset())
        local note_face = NoteItemWidget.noteFace()
        local note_line_h = Util.getLineHeight(note_face)
        local widths = Util.getWordWidths(note_face)
        local icon_w = widths[NOTE_ICON_CHAR]
        if not icon_w then
            icon_w = Util.measureTextWidth(NOTE_ICON_CHAR, note_face)
            widths[NOTE_ICON_CHAR] = icon_w
        end
        local wrap_w = line_width - icon_w - Screen:scaleBySize(6) - NoteItemWidget.noteIndent()
        if note.bookmark then wrap_w = content_width - NoteItemWidget.bookmarkIndent() end
        local n = math.min(#Core.wrapText(note.user_note, note_face, wrap_w), NoteItemWidget.noteLinesMax())
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
        width, Core.getHMargin(), Core.getTextMargin(), NoteItemWidget.lineSpacing(), Core.getTitleMargin(), Core.getInfoMargin(),
        Core.getTitleFontSize(), Core.getInfoFontSize(), Core.getContentFontSize(),
        tostring(getTitleFont()), tostring(getInfoFont()), tostring(getContentFont()),
        tostring(Core.getSetting("note_font", nil)), tostring(Core.getSetting("note_font_size", nil)),
        tostring(Core.getSetting("author_font", nil)), tostring(Core.getSetting("author_font_size", nil)), Core.getSetting("author_case", "upper"), Core.getSetting("title_case", "normal"), Core.getSetting("info_case", "normal"), NoteItemWidget.noteOffset(), NoteItemWidget.noteIndent(),
        tostring(Core.getTruncateLines()), tostring(NoteItemWidget.noteLinesMax()), tostring(Core.getShowInfo()), Core.getInfoFields(), tostring(NoteItemWidget.measure_hide_chapter),
        os.date("%Y%m%d"), -- "Today"/"Yesterday" labels change the info row text
        Core.getSetting("date_year_list", "relevant"), Core.getSetting("date_time_list", "never"), Core.getSetting("date_month", "short"), tostring(NoteItemWidget.twelveHour()),
        Core.getSetting("info_date_when", "always"), Core.SortState.get(NoteItemWidget.list_single), tostring(Core.getSetting("bm_line_size", nil)), tostring(Core.getSetting("bm_font", nil)), tostring(NoteItemWidget.bmNoteIcon()),
        tostring(NoteItemWidget.review_on), -- covered text changes what is drawn on each row
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
        h = NoteItemWidget.measureNoteHeight(note, width, skip_title, skip_info)
        entry[key] = h
    end
    return h
end

function NoteItemWidget:init()
    local h_margin = Core.getHMargin()    local text_margin = Core.getTextMargin()
    local title_margin = Core.getTitleMargin()
    local info_margin = Core.getInfoMargin()
    local inner_width = self.width - h_margin * 2
    self.dimen = Geom:new{ w = self.width, h = 0 }

    local h_padding = Size.padding.default
    local content_width = inner_width - h_padding * 2
    local justify = Core.getJustify()

    local note_wrapper = Core.NoteWrapper:new(self.note)
    local title_text = NoteItemWidget.titleText(self.note.book_title or _("Unknown book"))

    local title_face, info_face, content_face = NoteItemWidget.getNoteFaces()
    local header_widget
    if not self.skip_title then
        -- Book header: title left, author right (in capitals), thin line underneath
        local author_text = NoteItemWidget.getHeaderAuthor(note_wrapper)
        local author_face = NoteItemWidget.authorFace()
        local title_w, author_w, header_h = NoteItemWidget.getHeaderLayout(title_text, author_text, title_face, author_face, content_width)
        local title_widget = TextBoxWidget:new{
            text = title_text, face = title_face,
            width = title_w, alignment = "left", bold = true,
        }
        local row = HorizontalGroup:new{ align = "top", title_widget }
        if author_text then
            local author_widget = TextWidget:new{
                text = author_text, face = author_face, max_width = author_w,
                fgcolor = Core.COLORS.muted,
            }
            -- line the author up with the middle of the title's first line
            local first_line_h = Util.getLineHeight(title_face)
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
                background = Core.COLORS.line_light,
            },
        }
        -- keep the measured and drawn heights identical
        header_widget = CenterContainer:new{ dimen = Geom:new{ w = content_width, h = header_h }, header_widget }
    end

    local drawer = self.note.drawer or "lighten"
    local show_info_header = Core.getShowInfo()
    local info_text = NoteItemWidget.buildInfoText(self.note, note_wrapper, self.skip_title, self.show_parent and self.show_parent.single_book and NoteItemWidget.showHeadings())

    -- Same colour and same kind of text widget as the tabs (a single-line TextWidget) when it
    -- fits on one line, so it renders exactly like them; the box keeps the measured height.
    local date_widget
    local info_box_h = Util.getBoxHeight(info_text, info_face, content_width, false)
    if info_text ~= "" and Util.measureTextWidth(info_text, info_face) <= content_width then
        date_widget = LeftContainer:new{
            dimen = Geom:new{ w = content_width, h = info_box_h },
            TextWidget:new{ text = info_text, face = info_face, fgcolor = Core.COLORS.muted },
        }
    else
        date_widget = TextBoxWidget:new{
            text = info_text, face = info_face,
            width = content_width, alignment = "left",
            fgcolor = Core.COLORS.muted,
        }
    end

    local text_fgcolor = BlitBuffer.COLOR_BLACK
    local show_strikeout = drawer == "strikeout"
    local show_underline = drawer == "underscore"
    local no_background = Core.isNoBackgroundStyle(drawer)

    local bg_color = BlitBuffer.COLOR_WHITE
    if drawer == "invert" then
        text_fgcolor = BlitBuffer.COLOR_WHITE
        bg_color = BlitBuffer.COLOR_BLACK
    elseif not no_background then
        bg_color = Core.getHighlightColor(self.note.color)
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
    local is_bookmark = self.note.bookmark == true
    if is_bookmark then
        local single = self.show_parent and self.show_parent.single_book
        local row = NoteItemWidget.bookmarkRow(self.note, content_width, single and NoteItemWidget.showHeadings(), single)
        table.insert(note_content, LeftContainer:new{
            dimen = Geom:new{ w = inner_width, h = row:getSize().h },
            HorizontalGroup:new{ HorizontalSpan:new{ width = h_padding }, row },
        })
    end
    local info_visible = not is_bookmark and show_info_header and not self.skip_info and info_text ~= ""
    if info_visible then
        table.insert(note_content, LeftContainer:new{
            dimen = Geom:new{ w = inner_width, h = date_widget:getSize().h },
            HorizontalGroup:new{ HorizontalSpan:new{ width = h_padding }, date_widget },
        })
    end
    -- only add the post-header margin when at least one header row is actually shown
    local any_header_visible = not is_bookmark and ((not self.skip_title) or info_visible)
    if any_header_visible then
        table.insert(note_content, VerticalSpan:new{ width = info_margin })
    end
    
    if note_wrapper:hasHighlightedText() then
        
        local full_lines, para_end = Core.wrapText(self.note.highlighted_text or "", content_face, line_width)
        local max_lines = Core.getTruncateLines() or math.huge
        local truncated = false
        local lines = full_lines
        local last_line_no_ell
        local ell = "..."
        if #full_lines > max_lines then
            truncated = true
            lines = {}
            for i = 1, max_lines do lines[i] = full_lines[i] end
            
            last_line_no_ell = NoteItemWidget.cutLine(lines[#lines] or "", ell, content_face, line_width)
        end

        -- Review mode: hidden text keeps its own colour, so a yellow highlight reads as an empty
        -- yellow bar and the row measures exactly as before (the page layout does not move).
        -- With "cover only the note when there is one" on, a highlight that has a note keeps its
        -- text: the note below it is the thing to recall.
        local cover_highlight = NoteItemWidget.coverHighlight(self.note)
        local mask_fg = cover_highlight and NoteItemWidget.maskColor(self.note) or nil
        -- Question cover: the annotation's text is replaced by its own question (in bold), so the
        -- reader has something to answer instead of an empty colour bar. A tap swaps it for the
        -- text (and back), which is what _av_revealed does for the other cover styles.
        -- The question wins over picked words: it replaces the whole text anyway.
        local question = NoteItemWidget.questionFor(self.note)
        if question then
            -- the question takes the place of the highlight's lines; the rest of the row (the
            -- note, the style and colour choices) goes on as usual
            -- a question mark is added at the end unless the reader wrote one already (so it reads
            -- as a question in the list, not as a statement)
            local asked = question
            if not asked:find("[?？]%s*$") then asked = asked .. "?" end
            lines = Core.wrapText(asked, content_face, line_width)
            truncated = false
            last_line_no_ell = nil
        end
        -- Custom cover: the phrases picked inside this highlight. When there are any, only those
        -- words are covered and the rest of the line stays readable. They are covered on their own
        -- even when the rest of the line is not (a note keeps it readable, or the style is not
        -- covered): the two add up rather than replace each other, and a covered word is no use
        -- without its colour.
        local cloze = not question and NoteItemWidget.clozeCovered(self.note)
            and NoteItemWidget.clozePhrases(self.note) or nil
        local cloze_fg = NoteItemWidget.maskColor(self.note)

        local lines_group = VerticalGroup:new{ align = "left" }
        -- A question is drawn in the normal text colour and bold (it is text to read, not a cover);
        -- with a custom cover only the picked words are hidden and every other character is normal;
        -- without either the whole line is hidden (or shown) as one.
        local plain_fg = (question or cloze) and text_fgcolor or (mask_fg or text_fgcolor)
        local fg = plain_fg
        local question_bold = question and true or false
        -- One line as widgets: with no custom cover it is a single run, so nothing changes for a
        -- highlight the reader has not picked words in.
        -- The picked phrase is matched against the whole highlight, not one drawn line: a phrase
        -- longer than a line is wrapped across two of them, and matching per line found nothing
        -- there (which is why only short picks worked). Each drawn line takes the part of those
        -- matches that falls in it, found by walking the lines in order.
        local whole = (cloze and (self.note.highlighted_text or "")) or nil
        local marks = whole and NoteItemWidget.clozeMarks(whole, cloze) or nil
        local search_from = 1 -- where the current line starts looking in `whole`
        local function buildRuns(line)
            if not marks then
                return markw(TextWidget:new{ text = line, face = content_face, bold = question_bold,
                    fgcolor = fg }, line)
            end
            -- where this drawn line sits in the highlight (the wrapping drops and joins spaces, so
            -- the line is searched for rather than counted)
            local at = whole:find(line, search_from, true)
            if not at then at = whole:find(line, 1, true) end
            if at then search_from = at + #line end
            local runs = NoteItemWidget.splitClozeRuns(line, nil, marks, at or 1)
            if #runs <= 1 and not (runs[1] and runs[1].covered) then
                return markw(TextWidget:new{ text = line, face = content_face, fgcolor = plain_fg }, line)
            end
            local group = HorizontalGroup:new{ align = "top" }
            for _i, run in ipairs(runs) do
                table.insert(group, markw(TextWidget:new{
                    text = run.text, face = content_face,
                    fgcolor = run.covered and cloze_fg or plain_fg,
                }, run.text))
            end
            return group
        end
        for i, line in ipairs(lines) do
            local line_widget
            local is_last = (i == #lines)
            if is_last and truncated then
                
                if justify == true and not cloze and not question then
                    
                    local ell_meas = TextWidget:new{ text = ell, face = content_face }
                    local ell_w = ell_meas:getSize().w
                    ell_meas:free()
                    if last_line_no_ell and #last_line_no_ell > 0 then
                        local justified_part = markw(Core.createJustifiedLine(last_line_no_ell, content_face, math.max(0, line_width - ell_w), fg), last_line_no_ell)
                        local ell_widget = TextWidget:new{ text = ell, face = content_face, fgcolor = text_fgcolor }
                        line_widget = HorizontalGroup:new{ justified_part, ell_widget }
                    else
                        line_widget = TextWidget:new{ text = ell, face = content_face, fgcolor = text_fgcolor }
                    end
                else
                    line_widget = buildRuns((last_line_no_ell or line) .. ell)
                end
            else
                if justify == true and i < #lines and #lines > 1 and not para_end[i] and not cloze and not question then
                    line_widget = markw(Core.createJustifiedLine(line, content_face, line_width, fg), line)
                else
                    line_widget = buildRuns(line)
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
        table.insert(note_content, VerticalSpan:new{ width = is_bookmark and info_margin or NoteItemWidget.noteOffset() })

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
        -- a bookmark's note has no icon (unless the setting adds it): the ribbon above marks it, and the note lines up with
        -- the chapter text next to the ribbon
        local note_x = h_padding + text_margin + NoteItemWidget.noteIndent()
        local bm_pencil = is_bookmark and NoteItemWidget.bmNoteIcon()
        if is_bookmark then
            -- with or without its icon, the note starts where the chapter text does
            note_x = h_padding + (bm_pencil and 0 or NoteItemWidget.bookmarkIndent())
            note_text_width = content_width - NoteItemWidget.bookmarkIndent()
        end
        local note_lines = NoteItemWidget.cutLines(Core.wrapText(self.note.user_note, note_face, note_text_width),
            NoteItemWidget.noteLinesMax(), note_face, note_text_width)
        -- Review mode: the note is drawn in white on white, so the rows keep their height and the
        -- note reads as a blank block (the pencil icon stays, so the line is still recognisable)
        local note_covered = NoteItemWidget.coverNote(self.note)
        local note_fg = note_covered and BlitBuffer.COLOR_WHITE or BlitBuffer.COLOR_BLACK
        local note_text_group = VerticalGroup:new{ align = "left" }
        for li, line in ipairs(note_lines) do
            local ls = NoteItemWidget.lineSpacing()
            if li > 1 and ls > 0 then table.insert(note_text_group, VerticalSpan:new{ width = ls }) end
            local line_widget = markw(TextWidget:new{
                text = line, face = note_face, fgcolor = note_fg,
            }, line, note_face)
            if ls < 0 then
                local lsz = line_widget:getSize()
                line_widget = NoteItemWidget.LineBox:new{ w = lsz.w, h = math.max(2, lsz.h + ls), dy = math.floor(ls / 2), line_widget }
            end
            table.insert(note_text_group, line_widget)
        end

                
        local col = is_bookmark and NoteItemWidget.bookmarkColumn()
        local note_row = (is_bookmark and not bm_pencil) and note_text_group or bm_pencil and HorizontalGroup:new{
            CenterContainer:new{ dimen = Geom:new{ w = col, h = note_icon:getSize().h }, note_icon },
            HorizontalSpan:new{ width = NoteItemWidget.bookmarkIndent() - col },
            note_text_group,
        } or HorizontalGroup:new{
            note_icon,
            HorizontalSpan:new{ width = icon_margin },
            note_text_group,
        }
        table.insert(note_content, LeftContainer:new{
            dimen = Geom:new{ w = inner_width, h = note_row:getSize().h },
            HorizontalGroup:new{ HorizontalSpan:new{ width = note_x }, note_row },
        })
    end

    

    self.dimen.h = note_content:getSize().h
    self[1] = HorizontalGroup:new{
        HorizontalSpan:new{ width = h_margin }, note_content, HorizontalSpan:new{ width = h_margin },
    }

end
-- How a date is written, set apart for the list and for the annotation sheet:
--   year: "relevant" (Today, Yesterday, 3 Feb, and 3 Feb 2025 for another year) or "always" (3 Feb 2026)
--   time: "never", "recent" (only for today and yesterday: Today, 14:05) or "always" (3 Feb, 14:05)
NoteItemWidget.DATE_DEFAULTS = { list = { year = "relevant", time = "never" }, sheet = { year = "always", time = "always" } }
function NoteItemWidget.dateStyle(where)
    local d = NoteItemWidget.DATE_DEFAULTS[where] or NoteItemWidget.DATE_DEFAULTS.list
    where = NoteItemWidget.DATE_DEFAULTS[where] and where or "list"
    return { year = Core.getSetting("date_year_" .. where, d.year), time = Core.getSetting("date_time_" .. where, d.time) }
end
function NoteItemWidget:formatDate(datetime, style)
    if not datetime or datetime == "" then return nil end
    local year, month, day = datetime:match("(%d+)-(%d+)-(%d+)")
    if not year then return datetime end
    style = style or NoteItemWidget.dateStyle("list")
    local hm = datetime:match("[ T](%d%d?:%d%d)")
    local note_time = os.time({year = tonumber(year), month = tonumber(month), day = tonumber(day)})
    local out = NoteItemWidget.shortDate(note_time, style.year == "always")
    local recent = NoteItemWidget._today_start and note_time >= NoteItemWidget._today_start - 86400
    if hm and (style.time == "always" or (style.time == "recent" and recent)) then out = out .. ", " .. NoteItemWidget.clockText(hm) end
    return out
end
-- Month and clock, the same in the list and on the sheet. The month is short ("3 Feb") or long
-- ("3 February"), in KOReader's translation. The clock always follows KOReader's 12-hour clock setting
-- (Settings → Time and date).
function NoteItemWidget.monthName(t, long)
    if long == nil then long = Core.getSetting("date_month", "short") == "long" end
    local en = os.date(long and "%B" or "%b", t)
    local ok, dt = pcall(require, "datetime")
    local tr = ok and type(dt) == "table" and dt[long and "longMonthTranslation" or "shortMonthTranslation"]
    local name = type(tr) == "table" and tr[en]
    return type(name) == "string" and name or en
end
function NoteItemWidget.twelveHour()
    local ko = rawget(_G, "Core.G") -- KOReader's own settings (this file shadows the name)
    return ko and type(ko.isTrue) == "function" and ko:isTrue("twelve_hour_clock") or false
end
-- twelve: force the 12-hour clock (nil: KOReader's setting). The time comes from KOReader, in its
-- language ("14:05", "2:05 PM" or their translation); the plain one below is only used without KOReader.
function NoteItemWidget.clockText(hm, twelve)
    if twelve == nil then twelve = NoteItemWidget.twelveHour() end
    local h, m = hm:match("(%d+):(%d+)")
    if not h then return hm end
    h = tonumber(h)
    -- both clocks as KOReader writes them, in its language (some write 14.05)
    local ok, dt = pcall(require, "datetime")
    if ok and type(dt) == "table" and type(dt.secondsToHour) == "function" then
        local r = dt.secondsToHour(os.time({ year = 2000, month = 1, day = 1, hour = h, min = tonumber(m) }), twelve and true or false)
        if type(r) == "string" then return r end
    end
    if not twelve then return hm end
    local suffix = h < 12 and "AM" or "PM"
    h = h % 12
    if h == 0 then h = 12 end
    return string.format("%d:%s %s", h, m, suffix)
end
-- full: always "3 Feb 2026" (no Today / Yesterday, always the year)
function NoteItemWidget.shortDate(note_time, full)
    local today = os.date("*t")
    local today_key = today.year * 10000 + today.month * 100 + today.day
    if NoteItemWidget._today_key ~= today_key then
        NoteItemWidget._today_key = today_key
        NoteItemWidget._today_start = os.time({ year = today.year, month = today.month, day = today.day })
        -- from the calendar, not ± 24 h: a day with a clock change is 23 or 25 hours long
        NoteItemWidget._tomorrow_start = os.time({ year = today.year, month = today.month, day = today.day + 1 })
        NoteItemWidget._yesterday_start = os.time({ year = today.year, month = today.month, day = today.day - 1 })
    end
    local today_start = NoteItemWidget._today_start
    if full then
        local d = os.date("*t", note_time)
        return tostring(d.day) .. " " .. NoteItemWidget.monthName(note_time) .. " " .. d.year
    end
    -- after today (a device clock that was wrong when it was made): the date, not "Today"
    if note_time >= today_start and note_time < NoteItemWidget._tomorrow_start then return _("Today")
    elseif note_time >= NoteItemWidget._yesterday_start and note_time < today_start then return _("Yesterday")
    else
        -- "3 Feb" this year, "3 Feb 2025" for older ones
        local d = os.date("*t", note_time)
        local day_month = tostring(d.day) .. " " .. NoteItemWidget.monthName(note_time)
        if d.year == today.year then return day_month end
        return day_month .. " " .. d.year
    end
end
-- Text of the active-filter label shown under the title; "" means no filter is shown.
local function filterToString(filter, skip_presence)
    if not filter then return "" end
    local parts = {}
    -- Colour / style
    if type(filter.cs) == "table" and next(filter.cs) then
        local names = {}
        for k in pairs(filter.cs) do
            local t, v
            if type(k) == "string" then t, v = k:match("^(%a+):(.+)$") end -- a broken key is left out
            local name
            if t == "color" then name = NoteItemWidget.colorLabel(v) end
            if v and filter.cs[k] == true then table.insert(names, name or (v:sub(1, 1):upper() .. v:sub(2))) end
        end
        table.sort(names)
        if #names > 0 then table.insert(parts, (filter.cs_exclude and "C≠ " or "C: ") .. table.concat(names, ", ")) end
    end
    -- Books include / exclude
    if filter.books and next(filter.books) then
        local books = {}
        for k in pairs(filter.books) do table.insert(books, k) end
        table.sort(books)
        table.insert(parts, "B: " .. table.concat(books, ", "))
    end
    if filter.books_exclude and next(filter.books_exclude) then
        local books = {}
        for k in pairs(filter.books_exclude) do table.insert(books, k) end
        table.sort(books)
        table.insert(parts, "B≠ " .. table.concat(books, ", "))
    end
    -- Tags include / exclude
    if filter.tags and next(filter.tags) then
        local tags = {}
        for k in pairs(filter.tags) do table.insert(tags, k) end
        table.sort(tags)
        table.insert(parts, "T: " .. table.concat(tags, ", "))
    end
    if filter.tags_exclude and next(filter.tags_exclude) then
        local tags = {}
        for k in pairs(filter.tags_exclude) do table.insert(tags, k) end
        table.sort(tags)
        table.insert(parts, "T≠ " .. table.concat(tags, ", "))
    end
    -- Authors, series, language include / exclude
    local meta_kinds = { "authors", "series", "languages" } -- as NotesListWidget.META_KINDS (defined later)
    for i = 1, 3 do
        local kind = meta_kinds[i]
        local letter = kind:sub(1, 1):upper()
        for pi = 1, 2 do
            local k = pi == 1 and kind or (kind .. "_exclude")
            if type(filter[k]) == "table" and next(filter[k]) then
                local names = {}
                for v in pairs(filter[k]) do table.insert(names, v == "" and _("None") or v) end
                table.sort(names)
                table.insert(parts, letter .. (pi == 1 and ": " or "≠ ") .. table.concat(names, ", "))
            end
        end
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
        elseif filter.notes_presence == "bookmarks" then
            table.insert(parts, _("Bookmarks"))
        elseif filter.notes_presence == "custom" then
            table.insert(parts, _("Custom cover"))
        end
    end
    return #parts > 0 and table.concat(parts, "; ") or ""
end

-- Shared with main.lua, which lays out the preview and the export header.
NoteItemWidget.getNoteFaces = getNoteFaces
NoteItemWidget.filterToString = filterToString

NoteItemWidget.buildInfoText = buildInfoText

NoteItemWidget.getHeaderAuthor = getHeaderAuthor

NoteItemWidget.getHeaderLayout = getHeaderLayout

NoteItemWidget.measureNoteHeight = measureNoteHeight

NoteItemWidget.getLayoutSignature = getLayoutSignature
NoteItemWidget.getNoteHeight = getNoteHeight
NoteItemWidget.isScrollbarStyle = isScrollbarStyle

return NoteItemWidget
