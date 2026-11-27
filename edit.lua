--[[--
Editing an annotation from the viewer: writing a new style, colour or note, deleting it, and the
custom-cover (question and picked words) editors.

An annotation of a book that is not open is changed by writing the book's sidecar directly, as the
original plugin did; the book is never opened for an edit. An open book is changed through
KOReader's live annotations. Only "Go to highlight" opens a book.

These used to be methods written at the end of main.lua. The file returns a table of functions;
main.lua copies them onto AllNotesViewer, so `self` is the plugin and every call site
(`viewer:editNote(...)`) is unchanged.
]]

local NotesListWidget = require("noteslist")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local Geom = require("ui/geometry")
local Screen = require("device").screen
local DocSettings = require("docsettings")
local logger = require("logger")
local _ = require("ano_i18n").gettext
local ReaderHighlight = require("apps/reader/modules/readerhighlight")

local Core = require("core")
local Util = require("avutil")
local NoteItemWidget = require("noteitem")
local Event = require("ui/event")

-- Names this file calls that live in another module.
local buildInfoText = NoteItemWidget.buildInfoText
local getLiveReader = Core.getLiveReader
local editStoredAnnotation = Core.editStoredAnnotation
local nowStamp = Core.nowStamp

local getSetting = Core.getSetting
local setSetting = Core.setSetting
local normalizeColorStyle = Core.normalizeColorStyle
local normalizeBookTitle = Core.normalizeBookTitle
local compareByPosition = Core.compareByPosition
local trimParagraph = Core.trimParagraph
local wrapText = Core.wrapText
local findLiveIndex = NotesListWidget.findLiveIndex
local setLiveHighlightField = NotesListWidget.setLiveHighlightField
local View = {}

-- Old-format books (KOReader < 2024) are edited in their own `highlight[page]` entries by
-- Core.editStoredAnnotation, as in the original plugin: nothing to block.
function View.legacyBlocked(note)
    return false
end
-- Close the card and the list: "Go to highlight" closes both before the book opens.
-- sheet: the annotation card; list: the full-screen list behind it.
function View:closeListForEdit(sheet, list)
    if type(sheet) == "table" and type(sheet.onClose) == "function" then
        pcall(sheet.onClose, sheet)
    end
    if type(list) == "table" and list.notes_list and type(list.onClose) == "function" then
        pcall(list.onClose, list)
    end
end
-- Changes a highlight's style or colour. An open book's live annotation is changed in place; a
-- closed book's sidecar is written directly and the book stays closed.
function View:setHighlightField(note, field, value, parent_widget, done_text, sheet)
    if not note.book_path then return end
    local ui = getLiveReader(note.book_path)
    local index = ui and findLiveIndex(ui, note)
    local updated
    if index then
        setLiveHighlightField(ui, index, field, value)
        updated = true
    else
        updated = editStoredAnnotation(note, function(item)
            item[field] = value
            item.datetime_updated = nowStamp()
        end)
    end
    if updated then
        note[field] = value -- the card is drawn from the note: it has to show the new value
        if not index and type(sheet) == "table" and type(sheet.rebuild) == "function" then
            pcall(sheet.rebuild, sheet)
        end
        self:clearBookCache(note.book_path)
        self:updateListedNote(parent_widget, note, function(n) n[field] = value end)
        if done_text then NotesListWidget.showDialog(InfoMessage:new{ text = done_text, timeout = 1 }) end
    elseif ui then -- the book is open but its copy of this annotation is gone
        self:saveFailed()
    end
end
-- Nothing was changed because the annotation is no longer in the book's file (changed elsewhere,
-- book moved ...): say so. on_dismiss runs when the message is closed.
function View.saveFailed(on_dismiss)
    NotesListWidget.showDialog(InfoMessage:new{
        text = _("Could not save: this annotation was not found in the book's file. Tap Reload annotations and try again."),
        dismiss_callback = on_dismiss,
    })
end
function View:updateHighlightStyle(note, new_style, parent_widget)
    self:setHighlightField(note, "drawer", new_style, parent_widget, _("Style updated."))
end
function View:updateHighlightColor(note, new_color, parent_widget)
    self:setHighlightField(note, "color", new_color, parent_widget, _("Color updated."))
end
-- before_delete: runs once Delete is tapped (closes the sheet the card was opened from)
-- sheet: the annotation card the delete came from (nil from elsewhere)
function View:confirmDelete(note, parent_widget, before_delete, sheet)
    NotesListWidget.States.confirmDelete(note, function()
        if before_delete then before_delete() end
        self:deleteAnnotation(note, parent_widget)
    end)
end
-- Removes one annotation from the open book through KOReader's own path for its type.
function View:deleteLiveAnnotation(ui, index, note)
    if not ui or not index then return end
    if note.bookmark then
        local item = ui.annotation.annotations[index]
        if ui.bookmark and ui.bookmark.removeItem then
            ui.bookmark:removeItem(item, index)
        else
            table.remove(ui.annotation.annotations, index)
            ui:handleEvent(Event:new("AnnotationsModified", { item, index_modified = -index }))
        end
        return
    end
    if ui.highlight and ui.highlight.deleteHighlight then
        ui.highlight:deleteHighlight(index)
    else
        local item = table.remove(ui.annotation.annotations, index)
        ui:handleEvent(Event:new("AnnotationsModified", { item, index_modified = -index }))
    end
end
-- A closed book: the annotation is taken out of its sidecar and saved, the book stays closed.
-- A book left without any annotation loses its "has annotations" marker in the file browser.
function View:deleteAnnotation(note, parent_widget)
    if not note.book_path then return end
    local ui = getLiveReader(note.book_path)
    local index = ui and findLiveIndex(ui, note)
    local deleted
    if index then
        self:deleteLiveAnnotation(ui, index, note)
        deleted = true
    else
        local remaining
        deleted = editStoredAnnotation(note, function(_, list, i)
            table.remove(list, i)
            remaining = #list
        end)
        if deleted and remaining == 0 then
            -- keep the file browser's "has annotations" marker in sync
            local ok_bl, BookList = pcall(require, "ui/widget/booklist")
            if ok_bl and BookList and BookList.setBookInfoCacheProperty then
                BookList.setBookInfoCacheProperty(note.book_path, "has_annotations", false)
            end
        end
    end
    if deleted then
        self:clearBookCache(note.book_path)
        self:updateListedNote(parent_widget, note, function(_, i) table.remove(parent_widget.notes_list, i) end)
    elseif ui then -- the book is open but its copy of this annotation is gone
        self:saveFailed()
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
-- Custom cover: what review mode should cover in this highlight. Each place is added on its own:
-- the field shows the whole highlight, the reader deletes what should stay readable and taps
-- "Add", which saves that phrase straight away (no separate Save needed) and puts the whole
-- highlight back in the field for the next one. "Reselect" puts the highlight back when the field
-- was cut too far. (An empty line as a separator does not work: the on-screen keyboard's Enter
-- saves and closes the dialog.)
-- A phrase is kept exactly as it was left: its own punctuation is part of what was picked, and
-- splitting on commas would cut it, and could break a multi-byte character.
function View:editCloze(note, on_done)
    if not note or not note.book_path then return end
    local InputDialog = require("ui/widget/inputdialog")
    local highlight = note.highlighted_text or ""
    local picked = {}
    for _i, w in ipairs(NoteItemWidget.clozePhrases(note) or {}) do table.insert(picked, w) end
    local dialog
    local function clean(text)
        return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
    end
    -- every add writes the list out at once, so the pick is kept even if the reader leaves the
    -- dialog with the keyboard's Back instead of a button
    local function store()
        NoteItemWidget.setClozePhrases(note, #picked > 0 and picked or nil)
    end
    local function add(text)
        local phrase = clean(text)
        if phrase == "" then return end
        for _i, w in ipairs(picked) do if w == phrase then
            dialog:setInputText(highlight) -- already there: just get ready for the next one
            return
        end end
        table.insert(picked, phrase)
        store()
        if on_done then on_done() end
        -- back to the whole highlight, ready for the next one
        dialog:setInputText(highlight)
        UIManager:show(InfoMessage:new{ text = _("Added:") .. " " .. phrase, timeout = 1 })
    end
    local buttons = {
        {
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Save"), is_enter_default = true, callback = function()
                -- whatever is still in the field is added too, so "Add" is optional
                local phrase = clean(dialog:getInputText())
                local seen = false
                for _i, w in ipairs(picked) do if w == phrase then seen = true break end end
                -- only when it is not the untouched whole highlight (that means "nothing added")
                if phrase ~= "" and not seen and phrase ~= clean(highlight) then
                    table.insert(picked, phrase)
                end
                store()
                UIManager:close(dialog)
                if on_done then on_done() end
            end },
        },
        {
            { text = _("Reselect"), callback = function()
                dialog:setInputText(highlight)
            end },
            { text = _("Add"), callback = function() add(dialog:getInputText()) end },
        },
    }
    dialog = InputDialog:new{
        title = _("Custom cover: words to cover"),
        description = _("Delete everything that should stay readable, then tap Add; each one is saved at once."),
        input = highlight,
        input_type = "text",
        text_height = Screen:scaleBySize(140),
        buttons = buttons,
    }
    NotesListWidget.showDialog(dialog)
    dialog:onShowKeyboard()
end
-- Question cover: the question written for this whole annotation. In review mode its text is
-- replaced by this question (in bold) instead of an empty colour bar, so the reader has something
-- to answer; tapping the row swaps question and text, and back.
function View:editQuestion(note, on_done)
    if not note or not note.book_path then return end
    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    local function save(text)
        UIManager:close(dialog)
        NoteItemWidget.setNoteQuestion(note, text)
        if on_done then on_done() end
    end
    dialog = InputDialog:new{
        title = _("Question for this annotation"),
        description = _("In review mode the whole text is replaced by this question. Tap the row to swap question and text."),
        input = NoteItemWidget.noteQuestion(note) or "",
        input_hint = _("What does this passage say?"),
        input_type = "text",
        text_height = Screen:scaleBySize(100),
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Save"), is_enter_default = true, callback = function() save(dialog:getInputText()) end },
        } },
    }
    NotesListWidget.showDialog(dialog)
    dialog:onShowKeyboard()
end
-- The note is edited right where it is: a closed book is not opened, its sidecar is written
-- directly when Save is tapped (View:saveNoteEdit).
-- start_text: what the field starts with instead of the saved note (after a failed save).
-- sheet: the annotation card holding the Edit link (nil when editNote is called from elsewhere).
function View:editNote(note, parent_widget, on_done, start_text, sheet)
    if self:legacyBlocked(note) then return end
    if type(sheet) == "table" and type(sheet.onClose) == "function" then
        pcall(sheet.onClose, sheet) -- the card closes: the list under it stays, refreshed
    end
    local InputDialog = require("ui/widget/inputdialog")
    local input_dialog
    local has_note = note.user_note and note.user_note:find("%S") ~= nil
    -- what the note is about: "Book · Chapter · date", then the start of the highlight
    local about = {}
    if note.book_title and note.book_title ~= "" then table.insert(about, note.book_title) end
    local info = buildInfoText(note, Core.NoteWrapper:new(note))
    if info ~= "" then table.insert(about, info) end
    local quote = cleanHighlightTextForDialog(note.highlighted_text)
    local description = table.concat(about, " · ")
    if quote ~= "" then description = description .. (description ~= "" and "\n\n" or "") .. quote end
    local function save(text)
        local typed = input_dialog:getInputText() -- kept if the save fails
        UIManager:close(input_dialog)
        self:saveNoteEdit(note, text, parent_widget, function()
            self:editNote(note, parent_widget, on_done, typed)
        end)
        if on_done then on_done() end
    end
    local row = {}
    if has_note then
        -- blank input deletes the note too; this just says so
        table.insert(row, { text = _("Remove note"), callback = function() save("") end })
    end
    table.insert(row, { text = _("Cancel"), id = "close", callback = function() UIManager:close(input_dialog) end })
    -- Save last in the row (unpack(row) in the middle of a table keeps only its first button,
    -- which lost Cancel whenever there was a note)
    table.insert(row, {
        text = _("Save"),
        is_enter_default = true,
        callback = function() save(input_dialog:getInputText()) end,
    })
    input_dialog = InputDialog:new{
        title = has_note and _("Edit note") or _("Add note"),
        description = description ~= "" and description or nil,
        input = start_text or note.user_note or "",
        input_hint = note.bookmark and _("Your note on this page") or _("Your note on this passage"),
        input_type = "text",
        text_height = Screen:scaleBySize(120),
        -- Enter types a new line instead of pressing Save: a note is often more than one line.
        -- With allow_newline InputDialog drops the Enter-to-save behaviour of is_enter_default.
        allow_newline = true,
        buttons = { row },
    }
    NotesListWidget.showDialog(input_dialog)
    input_dialog:onShowKeyboard()
end
-- The open book gets the note through KOReader's live annotation (as before); a closed book's
-- sidecar is written directly, as the original plugin did.
-- on_fail: run after the "could not save" message is closed (editNote reopens with the text).
function View:saveNoteEdit(note, new_note_text, parent_widget, on_fail)
    if not note.book_path or self:legacyBlocked(note) then return end
    local value = new_note_text ~= "" and new_note_text or nil -- blank input deletes the note, as in KOReader
    local updated = false
    local ui = getLiveReader(note.book_path)
    local index = ui and findLiveIndex(ui, note)
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
    else
        -- a closed book: the sidecar is written directly, as the original plugin did
        updated = editStoredAnnotation(note, function(item)
            item.note = value
            item.datetime_updated = nowStamp()
        end)
    end
    if updated then
        -- the note the card is drawn from carries the new text too (the card is rebuilt afterwards)
        note.user_note = value
        self:clearBookCache(note.book_path)
        self:updateListedNote(parent_widget, note, function(n) n.user_note = value end)
        NotesListWidget.showDialog(InfoMessage:new{ text = _("Note saved."), timeout = 1 })
    elseif ui then -- the book is open but its copy of this annotation is gone
        self:saveFailed(on_fail)
    end
end
-- Opens the note's book: "Go to highlight" and reading a card in the book's own list use this.
-- Editing never does: an edit of a closed book writes its sidecar directly.
-- on_ready runs first (the card and the list close themselves there), then after_open(ui) once the
-- book is laid out. Without no_jump the book is also shown at the highlight's place.
function View:openBookAtNote(note, on_ready, after_open, no_jump)
    local book_path = note.book_path
    if not book_path then
        NotesListWidget.showDialog(InfoMessage:new{ text = _("Cannot find book path.") })
        return
    end

    local ReaderUI = require("apps/reader/readerui")

    -- Jump the way KOReader's own bookmark list does: to the exact spot (xpointer or page)
    -- with the highlight marked, after remembering where the reader was, so KOReader's Back
    -- returns there. Older KOReader without these: go to the page number.
    local function gotoNote(ui)
        if no_jump then return end -- editing only needs the book open, not its page shown
        if not ui or not ui.document then return end
        -- EPUB-like books need an xpointer here, PDFs a page number (very old sidecars kept a
        -- page number for EPUBs too: those take the fallback below)
        local fits = (ui.rolling and type(note.page) == "string")
            or (ui.paging and tonumber(note.page) and tonumber(note.page) > 0)
        if ui.bookmark and ui.bookmark.gotoBookmark and fits then
            if ui.link and ui.link.addCurrentLocationToStack then ui.link:addCurrentLocationToStack() end
            ui.bookmark:gotoBookmark(note.page, note.pos0)
            return
        end
        local target_page = tonumber(note.page)
        local xp = note.pos0 or (type(note.page) == "string" and note.page or nil)
        if xp and ui.document.getPageFromXPointer then
            local ok, page = pcall(function() return ui.document:getPageFromXPointer(xp) end)
            if ok and page then target_page = page end
        end
        if target_page and target_page > 0 then
            ui:handleEvent(Event:new("GotoPage", target_page))
        end
    end
    -- the book has to be laid out before its page is shown or its annotations are used
    local function runAfterOpen(ui)
        if not after_open then return end
        UIManager:scheduleIn(0.3, function()
            if ui and ui.document then pcall(after_open, ui) end
        end)
    end

    -- a book that is already open is used as it is (its annotations are the live ones)
    if ReaderUI.instance and ReaderUI.instance.document then
        if Core.samePath(ReaderUI.instance.document.file, book_path) then
            if on_ready then on_ready() end
            gotoNote(ReaderUI.instance)
            runAfterOpen(ReaderUI.instance)
            return
        end
    end

    -- KOReader 2026.03+ calls this once the book is open; older versions ignore the extra
    -- argument, so the timer below is the fallback for them.
    local done = false
    local function opened(ui)
        if done then return end
        done = true
        if on_ready then on_ready() end
        gotoNote(ui)
        runAfterOpen(ui)
    end
    ReaderUI:showReader(book_path, nil, nil, nil, opened)
    UIManager:scheduleIn(1.5, function()
        if done then return end
        local ui = require("apps/reader/readerui").instance
        if ui and ui.document and Core.samePath(ui.document.file, book_path) then opened(ui) end
    end)
end
-- Internals exposed for tests/run.lua; KOReader doesn't use this.

return View