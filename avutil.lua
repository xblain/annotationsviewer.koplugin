--[[--
Shared helpers for annotationsviewer.koplugin.

Measurement and text wrapping. These were `local`s at the top of main.lua; they are plain
functions on a table here so the main chunk keeps its local count down (Lua allows 200 locals
per chunk, and the plugin is large enough to reach that limit).

The caches below are per-face and live for the life of the plugin, exactly as before: measuring
is the expensive part of drawing a long list, and every face is measured once.
]]

local TextWidget = require("ui/widget/textwidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
-- KOReader's own util, for splitting CJK text into characters. This module is deliberately not
-- called util.lua: a file of that name in the plugin directory would shadow KOReader's, which the
-- rest of KOReader requires ~116 times.
local KOReaderUtil = require("util")

local Util = {}

-- [face] = { word = width, [" "] = width of one space }
local _word_width_cache = setmetatable({}, { __mode = "k" }) -- keyed by face table
-- [face] = height of one line
local _line_height_cache = setmetatable({}, { __mode = "k" })
-- [face]["w:bold:text"] = height of a wrapped TextBoxWidget
local _box_height_cache = setmetatable({}, { __mode = "k" })

-- Width of `text` in this face.
function Util.measureTextWidth(text, face)
    local tw = TextWidget:new{ text = text, face = face }
    local w = tw:getSize().w
    tw:free()
    return w
end

-- The per-face table of measured word widths. Words never contain spaces, so " " is free to
-- hold the width of one space.
function Util.getWordWidths(face)
    local fc = _word_width_cache[face]
    if not fc then
        fc = {}
        fc[" "] = Util.measureTextWidth("x x", face) - 2 * Util.measureTextWidth("x", face)
        _word_width_cache[face] = fc
    end
    return fc
end

-- Height of one TextWidget line in this face (TextWidget height does not depend on the text).
function Util.getLineHeight(face)
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
function Util.getBoxHeight(text, face, width, bold)
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

function Util.wrapParagraph(text, face, max_width, lines)
-- Words to wrap: split at spaces; Chinese / Japanese / Korean text has none, so such words are
-- cut into their characters with KOReader's util.splitToWords (the pieces join without a space).
    -- closing punctuation never starts a line: it stays with the character before it
    local closing = "。，、；：？！）」』】》〉〕］｝”’…"
    local function wrapTokens(txt)
        local tokens = {}
        for word in txt:gmatch("%S+") do
            if word:find("[\227-\237\239\240]") then -- also 4-byte characters (CJK beyond U+20000)
                for i, piece in ipairs(KOReaderUtil.splitToWords(word)) do
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
    local widths = Util.getWordWidths(face)
    local space_w = widths[" "]
    -- a word wider than the column (a long URL) is broken between characters
    local tokens, src = {}, wrapTokens(text)
    for t = 1, #src do
        local tok = src[t]
        local word = tok[1]
        local ww = widths[word]
        if not ww then ww = Util.measureTextWidth(word, face); widths[word] = ww end
        if ww <= max_width or not word:find("[^\128-\191].*[^\128-\191]") then
            table.insert(tokens, tok)
        else
            local piece, joined = "", tok[2]
            for ch in word:gmatch("[^\128-\191][\128-\191]*") do
                if piece ~= "" and Util.measureTextWidth(piece .. ch, face) > max_width then
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
            ww = Util.measureTextWidth(word, face)
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
                local exact = Util.measureTextWidth(current_line .. sep .. word, face)
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

return Util
