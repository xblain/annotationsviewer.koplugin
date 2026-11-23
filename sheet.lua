--[[--
The card that opens for an annotation: the highlight in its colour, the note, and the style,
colour, custom-cover and delete actions.

Moved out of main.lua, which is at Lua's 200-locals-per-chunk limit. The shapes it draws with
(SheetFrame, RoundedBox, RoundedOutline) live here too, since nothing else uses them.
]]

local InputContainer = require("ui/widget/container/inputcontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local LeftContainer = require("ui/widget/container/leftcontainer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local GestureRange = require("ui/gesturerange")
local UIManager = require("ui/uimanager")
local LineWidget = require("ui/widget/linewidget")
local BlitBuffer = require("ffi/blitbuffer")
local Screen = require("device").screen
local Device = require("device")
local Input = Device.input
local Font = require("ui/font")
local Size = require("ui/size")
local Geom = require("ui/geometry")
local _ = require("ano_i18n").gettext

local Core = require("core")
local getHighlightColor = Core.getHighlightColor
local Util = require("avutil")
local createJustifiedLine = Util.createJustifiedLine
local UI = require("avui")
local StrikeoutLineWidget = UI.StrikeoutLineWidget
local UnderlineWidget = UI.UnderlineWidget
local NoteItemWidget = require("noteitem")
-- noteslist.lua requires this file, so the reference is taken on first use.
local NotesListWidget
local function notesList()
    NotesListWidget = NotesListWidget or require("noteslist")
    return NotesListWidget
end

local G_reader_settings = Core.G
local COLORS = Core.COLORS
local TapBox = UI.TapBox
local Pill = UI.Pill

local getSetting = Core.getSetting
local getFaceOr = Core.getFaceOr
local SERIF_FONT = Core.SERIF_FONT
local getLineHeight = Util.getLineHeight
local ReaderHighlight = require("apps/reader/modules/readerhighlight")
local IconButton = require("ui/widget/iconbutton")
local TextViewer = require("ui/widget/textviewer")
local OverlapGroup = require("ui/widget/overlapgroup")
local RightContainer = require("ui/widget/container/rightcontainer")
local lfs = require("libs/libkoreader-lfs")

-- Names this file calls that live in another module.
local getJustify = Core.getJustify
local getNoteFaces = NoteItemWidget.getNoteFaces
local trimParagraph = Core.trimParagraph
local wrapText = Core.wrapText
local isNoBackgroundStyle = Core.isNoBackgroundStyle

-- Colours and styles offered for a highlight.
local HIGHLIGHT_STYLES = { lighten = true, underscore = true, strikeout = true, invert = true }

local HIGHLIGHT_STYLES = {
    { "lighten", _("Lighten") }, { "underscore", _("Underline") },
    { "strikeout", _("Strikeout") }, { "invert", _("Invert") },
}

local function cleanHighlightText(text)
    local paras = {}
    for p in ((text or ""):gsub("\r", "") .. "\n"):gmatch("([^\n]*)\n") do
        p = trimParagraph(p)
        if p ~= "" then table.insert(paras, p) end
    end
    return table.concat(paras, "\n")
end

local function buildHighlightLines(text, face, width, drawer, color, max_lines, in_box)
    drawer = drawer or "lighten"
    local h_pad, v_pad = Size.padding.small, 1
    local line_width = width - h_pad * 2
    local fg, bg = BlitBuffer.COLOR_BLACK, BlitBuffer.COLOR_WHITE
    if drawer == "invert" then
        fg, bg = BlitBuffer.COLOR_WHITE, BlitBuffer.COLOR_BLACK
    elseif not isNoBackgroundStyle(drawer) then
local function getHighlightColor(color)
    local val = COLORS.highlightCode(color)
    if val and BlitBuffer.colorFromString then
        return BlitBuffer.colorFromString(val)
    end
    return BlitBuffer.COLOR_GRAY
end

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
    local nw = Core.NoteWrapper:new(note)
    local W, H = Screen:getWidth(), Screen:getHeight()
    -- tap outside: the whole of the current screen (also after a rotation)
    self.ges_events.TapOutside = { GestureRange:new{ ges = "tap", range = Geom:new{ x = 0, y = 0, w = W, h = H } } }
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
    -- KOReader's page number (EPUB positions aren't numbers, so its label is used when there), then the date
    local page_no = note.page_label
    if page_no == nil and tonumber(note.page) and tonumber(note.page) > 0 then page_no = tonumber(note.page) end
    if page_no ~= nil and page_no ~= "" then table.insert(meta, _("page") .. " " .. tostring(page_no)) end
    local date_text = NoteItemWidget:formatDate(note.datetime, NoteItemWidget.dateStyle("sheet"))
    if date_text then table.insert(meta, date_text) end
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
            notesList().showDialog(TextViewer:new{ title = note.book_title or _("Annotation"), text = quote_text })
        end } or box)
        if cut then
            table.insert(group, VerticalSpan:new{ width = Screen:scaleBySize(4) })
            table.insert(group, TextWidget:new{ text = _("Tap the highlight to read all of it"),
                face = Font:getFace("cfont", 12), fgcolor = MUTED })
        end
        -- Custom cover, both modes in one block:
        --   row 1  "Custom cover:" with the links right after it (add/change the question, choose
        --          words, remove every picked word)
        --   row 2  the question badge, in the same white pill with a black outline as the colour
        --          chips below (a "?" before the question, a ✕ after it)
        --   row 3+ the picked words, one chip each with a ✕
        -- Tapping the question badge or a word chip drops just that one.
        do
            local picked = NoteItemWidget.clozePhrases(note)
            local question = NoteItemWidget.noteQuestion(note)
            local small_face = Font:getFace("cfont", 12)
            local gap_s = Screen:scaleBySize(6)
            table.insert(group, VerticalSpan:new{ width = gap_s })
            -- row 1: the label and the links, all on one line
            local head = HorizontalGroup:new{ align = "center" }
            table.insert(head, TextWidget:new{ text = _("Custom cover:"), face = small_face, fgcolor = MUTED })
            local function link(text, cb)
                table.insert(head, HorizontalSpan:new{ width = Screen:scaleBySize(10) })
                table.insert(head, TapBox:new{
                    decoratedText(TextWidget:new{ text = text, face = small_face }, "underline", MUTED),
                    callback = cb,
                })
            end
            link(question and _("Change question…") or _("Add a question…"), function()
                viewer:editQuestion(note, function() self:rebuild() end)
            end)
            link(_("Choose words…"), function()
                viewer:editCloze(note, function() self:rebuild() end)
            end)
            if picked then
                link(_("Remove all picked words"), function()
                    NoteItemWidget.setClozePhrases(note, nil)
                    self:rebuild()
                end)
            end
            table.insert(group, head)
            -- row 2: the question badge, drawn exactly like a picked-word chip (black pill with a
            -- ✕), with a "?" in front of the question
            if question then
                table.insert(group, VerticalSpan:new{ width = Screen:scaleBySize(4) })
                local q_face = Font:getFace("cfont", 12)
                local q_chip_h = Screen:scaleBySize(24)
                local q_close_w = TextWidget:new{ text = "✕", face = q_face }:getSize().w
                local q_mark_w = TextWidget:new{ text = "?", face = q_face, bold = true }:getSize().w
                local q_text_w = math.min(TextWidget:new{ text = question, face = q_face }:getSize().w,
                    inner - q_close_w - q_mark_w - Screen:scaleBySize(34))
                table.insert(group, TapBox:new{
                    Pill:new{ width = q_text_w + q_close_w + q_mark_w + Screen:scaleBySize(34),
                        height = q_chip_h, fill = BlitBuffer.COLOR_BLACK, border = 0,
                        HorizontalGroup:new{ align = "center",
                            TextWidget:new{ text = "?", face = q_face, bold = true,
                                fgcolor = BlitBuffer.COLOR_WHITE },
                            HorizontalSpan:new{ width = Screen:scaleBySize(6) },
                            TextWidget:new{ text = question, face = q_face,
                                fgcolor = BlitBuffer.COLOR_WHITE, max_width = q_text_w },
                            HorizontalSpan:new{ width = Screen:scaleBySize(5) },
                            TextWidget:new{ text = "✕", face = q_face, fgcolor = BlitBuffer.COLOR_WHITE },
                        } },
                    callback = function()
                        NoteItemWidget.setNoteQuestion(note, nil)
                        self:rebuild()
                    end,
                })
            end
            -- row 3+: the picked words, wrapped
            if picked then
                table.insert(group, VerticalSpan:new{ width = Screen:scaleBySize(4) })
                local chip_gap = gap_s
                local chip_h = Screen:scaleBySize(24)
                local close_w = TextWidget:new{ text = "✕", face = small_face }:getSize().w
                local rows = VerticalGroup:new{ align = "left" }
                local row, row_w = HorizontalGroup:new{ align = "center" }, 0
                local function newRow()
                    table.insert(rows, row)
                    table.insert(rows, VerticalSpan:new{ width = chip_gap })
                    row, row_w = HorizontalGroup:new{ align = "center" }, 0
                end
                for _i, word in ipairs(picked) do
                    local text_w = math.min(TextWidget:new{ text = word, face = small_face }:getSize().w,
                        inner - close_w - Screen:scaleBySize(28))
                    local chip_w = text_w + close_w + Screen:scaleBySize(22)
                    if row_w > 0 and row_w + chip_gap + chip_w > inner then newRow() end
                    if row_w > 0 then
                        table.insert(row, HorizontalSpan:new{ width = chip_gap })
                        row_w = row_w + chip_gap
                    end
                    table.insert(row, TapBox:new{
                        Pill:new{ width = chip_w, height = chip_h, fill = BlitBuffer.COLOR_BLACK, border = 0,
                            HorizontalGroup:new{ align = "center",
                                TextWidget:new{ text = word, face = small_face,
                                    fgcolor = BlitBuffer.COLOR_WHITE, max_width = text_w },
                                HorizontalSpan:new{ width = Screen:scaleBySize(5) },
                                TextWidget:new{ text = "✕", face = small_face, fgcolor = BlitBuffer.COLOR_WHITE },
                                HorizontalSpan:new{ width = Screen:scaleBySize(1) },
                            } },
                        callback = function()
                            local left = {}
                            for _j, p in ipairs(picked) do if p ~= word then table.insert(left, p) end end
                            NoteItemWidget.setClozePhrases(note, left)
                            self:rebuild()
                        end,
                    })
                    row_w = row_w + chip_w
                end
                if row_w > 0 then table.insert(rows, row) end
                table.insert(group, rows)
            end
        end
    end

    -- 3. note, with an underlined Edit / Add note link
    local has_note = nw:hasUserNote()
    local link = TextWidget:new{ text = has_note and _("Edit") or _("Add note"), face = Font:getFace("cfont", 13) }
    local edit_link = TapBox:new{
        decoratedText(link, "underline", BlitBuffer.COLOR_BLACK),
        callback = function()
            viewer:editNote(note, parent, function() self:rebuild() end, nil, self)
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

    -- 4 and 5 (style, colour) are for highlights only: a bookmark has neither
    if not note.bookmark then
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
                    viewer:setHighlightField(note, "drawer", key, parent, nil, self)
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
        local key, name = c[2], NoteItemWidget.colorLabel(c[2])
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
                    viewer:setHighlightField(note, "color", key, parent, nil, self)
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
    end -- not a bookmark

    -- 6. actions: Go to (twice as wide) and Delete
    local btn_gap = Screen:scaleBySize(10)
    local btn_row = HorizontalGroup:new{}
    local can_open = note.book_path and lfs.attributes(note.book_path, "mode") ~= nil
    local unit = math.floor((inner - btn_gap) / 3)
    if can_open then
        local goto_text = _("Go to highlight")
        if note.bookmark then
            goto_text = page_no and (_("Go to page") .. " " .. tostring(page_no)) or _("Go to bookmark")
        end
        table.insert(btn_row, actionButton(goto_text, function()
            self:onClose()
            UIManager:close(parent)
            viewer:openBookAtNote(note)
        end, true, inner - btn_gap - unit))
        table.insert(btn_row, HorizontalSpan:new{ width = btn_gap })
    end
    table.insert(btn_row, actionButton(_("Delete"), function()
        -- the card opens over the sheet: Cancel goes back to it, Delete closes both
        viewer:confirmDelete(note, parent, function() self:onClose() end, self)
    end, false, can_open and unit or inner))
    table.insert(group, btn_row)

    -- Bookmarks: step to the previous / next one in the list without closing the sheet
    if note.bookmark and parent and parent.filtered_notes then
        local list, idx = parent.filtered_notes, nil
        for i, n in ipairs(list) do if n == note then idx = i; break end end
        if idx and #list > 1 then
            local function go(i)
                self.note = list[i]
                self:rebuild()
            end
            table.insert(group, VerticalSpan:new{ width = Screen:scaleBySize(12) })
            table.insert(group, LineWidget:new{ dimen = Geom:new{ w = inner, h = Size.line.medium }, background = COLORS.line })
            table.insert(group, notesList().navBar{
                width = inner, label = string.format("%d / %d", idx, #list),
                has_prev = idx > 1, has_next = idx < #list,
                first = function() go(1) end, prev = function() go(idx - 1) end,
                next = function() go(idx + 1) end, last = function() go(#list) end,
            })
        end
    end

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

-- AnnotationSheet is the usual import, but the other screens also draw rounded boxes, so the
-- shape classes are handed out alongside it as fields of the same table.
AnnotationSheet.RoundedBox = RoundedBox
AnnotationSheet.RoundedOutline = RoundedOutline
AnnotationSheet.SheetFrame = SheetFrame

AnnotationSheet.decoratedText = decoratedText
AnnotationSheet.HIGHLIGHT_STYLES = HIGHLIGHT_STYLES

AnnotationSheet.buildHighlightLines = buildHighlightLines

return AnnotationSheet
