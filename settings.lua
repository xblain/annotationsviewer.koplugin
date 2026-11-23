--[[--
The plugin's own settings screens: "Filter & sort" and the Settings page (Text, List, Pages,
Review, Custom cover, Bookmarks, Dates, Info and Export).

Moved out of main.lua, which is at Lua's 200-locals-per-chunk limit. They read their settings
through Core and talk to the list through `self.list`, so nothing here needs the plugin itself.
]]

local AnnotationSheet = require("sheet")
local RoundedBox = AnnotationSheet.RoundedBox
local RoundedOutline = AnnotationSheet.RoundedOutline
local InputContainer = require("ui/widget/container/inputcontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local OverlapGroup = require("ui/widget/overlapgroup")
local CenterContainer = require("ui/widget/container/centercontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local RightContainer = require("ui/widget/container/rightcontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local GestureRange = require("ui/gesturerange")
local UIManager = require("ui/uimanager")
local LineWidget = require("ui/widget/linewidget")
local InfoMessage = require("ui/widget/infomessage")
local IconButton = require("ui/widget/iconbutton")
local IconWidget = require("ui/widget/iconwidget")
local FontList = require("fontlist")
local SpinWidget = require("ui/widget/spinwidget")
local TextViewer = require("ui/widget/textviewer")
local BlitBuffer = require("ffi/blitbuffer")
local Screen = require("device").screen
local Device = require("device")
local Input = Device.input
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local Font = require("ui/font")
local Size = require("ui/size")
local Geom = require("ui/geometry")
local _ = require("ano_i18n").gettext
local BD = require("ui/bidi")

local Core = require("core")
local Util = require("avutil")
local UI = require("avui")
local NoteItemWidget = require("noteitem")
local NotesListWidget = require("noteslist")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local ReaderHighlight = require("apps/reader/modules/readerhighlight")

-- Names this file calls that live in another module.
local getContentFontSize = Core.getContentFontSize
local getHighlightColor = Core.getHighlightColor
local getInfoFontSize = Core.getInfoFontSize
local normalizeColorStyle = Core.normalizeColorStyle

local G_reader_settings = Core.G
local COLORS = Core.COLORS
local Page = Core.Page
local Export = Core.Export
local States = Core.States
local SortState = Core.SortState
local TapBox = UI.TapBox
local Pill = UI.Pill

local getSetting = Core.getSetting
local getContentFont = Core.getContentFont
local getDedupInfoFields = Core.getDedupInfoFields
local getInfoFont = Core.getInfoFont
local getTitleFont = Core.getTitleFont
local setSetting = Core.setSetting
local getSettingsFontShift = Core.getSettingsFontShift
local getReviewCoverStyles = Core.getReviewCoverStyles
local isScrollbarStyle = Core.isScrollbarStyle
local getPaginationStyle = Core.getPaginationStyle
local getSwipeSetting = Core.getSwipeSetting
local getTapSetting = Core.getTapSetting
local getHoldSetting = Core.getHoldSetting
local getShowTotalNotes = Core.getShowTotalNotes
local getScrollbarBookMarks = Core.getScrollbarBookMarks
local getRepeatTitleOnPage = Core.getRepeatTitleOnPage
local getRepeatInfoOnPage = Core.getRepeatInfoOnPage
local getHideDupTitle = Core.getHideDupTitle
local getHideDupInfo = Core.getHideDupInfo
local getTruncateLines = Core.getTruncateLines
local getJustify = Core.getJustify
local getShowInfo = Core.getShowInfo
local getInfoFields = Core.getInfoFields
local getFaceOr = Core.getFaceOr
local sortModeLabel = NotesListWidget.sortModeLabel

local TOPBAR_HEIGHT = Core.TOPBAR_HEIGHT
local CHIP_GAP = Core.CHIP_GAP
local SERIF_FONT = Core.SERIF_FONT
local DEFAULT_TRUNCATE_LINES = Core.DEFAULT_TRUNCATE_LINES
local HIGHLIGHT_STYLES = AnnotationSheet.HIGHLIGHT_STYLES
local REVIEW_STYLES = Core.REVIEW_STYLES
local SPIN_MENUS = Core.SPIN_MENUS
local decoratedText = AnnotationSheet.decoratedText
local deepCopy = NotesListWidget.deepCopy

local SettingsScreens = {}

local FilterScreen = InputContainer:extend{ list = nil, helpers = nil, covers_fullscreen = true }
function FilterScreen:init()
    -- Core.Page exists only once main.lua has loaded, so install the hooks here
    if not self.page_hooks then
        self.page_hooks = true
    end
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.saved_filter = deepCopy(self.list.active_filter or {})
    self.saved_sorts = Core.SortState.snapshot() -- a saved filter can change the other tab's order too
    if Device:hasKeys() then self.key_events.Close = { { Input.group.Back } } end
    self:build()
end
function FilterScreen:rebuild()
    self:build()
    UIManager:setDirty(self, "ui")
end
function FilterScreen:changed()
    self.list.current_page = 1
    self.list:refresh()
    self:rebuild()
end
function FilterScreen:build()
    local list = self.list
    list.active_filter = list.active_filter or {}
    local af = list.active_filter
    normalizeColorStyle(af)
    local W, H = Screen:getWidth(), Screen:getHeight()
    local P = Screen:scaleBySize(24)
    local inner = W - P * 2
    local thin = Size.border.button
    local MUTED = COLORS.muted
    -- same shift as the Settings page, so the two read alike
    local imp_shift = getSettingsFontShift()
    local face15 = Font:getFace("cfont", 15 + imp_shift)
    local face14 = Font:getFace("cfont", 14 + imp_shift)
    local face13 = Font:getFace("cfont", 13 + imp_shift)
    local function underlined(text, face)
        local tw = TextWidget:new{ text = text, face = face }
        return VerticalGroup:new{ tw, LineWidget:new{ dimen = Geom:new{ w = tw:getSize().w, h = Size.line.medium },
            background = BlitBuffer.COLOR_BLACK } }
    end
    local function rowLine() return Core.Page.rowLine(P, inner) end
    local function padded(widget, top, bottom) return Core.Page.padded(widget, P, top, bottom) end
    local sectionBar = Core.Page.sectionBars(P, inner)
    local function labelRow(left, right)
        local d = Geom:new{ w = inner, h = math.max(left:getSize().h, right and right:getSize().h or 0) }
        return OverlapGroup:new{ dimen = d, allow_mirroring = false,
            LeftContainer:new{ dimen = d, left }, right and RightContainer:new{ dimen = d, right } or nil }
    end
    -- chip: black with white bold text when on; white with a border when off. Width is
    -- always that of the "on" (bold) version so choosing never reflows the rows.
    local function chip(text, on, callback, opts)
        opts = opts or {}
        local h = opts.h or Screen:scaleBySize(34)
        -- opts.single: one of a single choice (saved filters): a thick black outline when chosen,
        -- as on the annotation sheet; black fill is for chips of which several can be on
        local filled = on and not opts.single
        local color = filled and BlitBuffer.COLOR_WHITE or BlitBuffer.COLOR_BLACK
        local widest = TextWidget:new{ text = text, face = face13, bold = true }:getSize().w
        local tw = TextWidget:new{ text = text, face = face13, bold = on, fgcolor = color }
        local label = decoratedText(tw, opts.deco, color)
        local content = HorizontalGroup:new{ align = "center" }
        local extra = 0
        local dots = opts.dots or (opts.dot and { opts.dot }) or {}
        for _i, dname in ipairs(dots) do
            table.insert(content, Pill:new{ width = Screen:scaleBySize(12), height = Screen:scaleBySize(12), border = 0, true_color = true,
                fill = dname == "gray" and BlitBuffer.COLOR_GRAY or getHighlightColor(dname) })
            table.insert(content, HorizontalSpan:new{ width = Screen:scaleBySize(6) })
            extra = extra + Screen:scaleBySize(18)
        end
        table.insert(content, label)
        local w = math.max(widest + extra + Screen:scaleBySize(28), opts.w or 0) -- opts.w: stretch to this width
        return { w = w, widget = TapBox:new{
            Pill:new{ width = w, height = h, fill = filled and BlitBuffer.COLOR_BLACK or BlitBuffer.COLOR_WHITE,
                border = filled and 0 or (on and Size.border.thick or thin),
                border_color = on and COLORS.ink or COLORS.line, content },
            callback = callback, hold_callback = opts.hold,
        } }
    end
    local function flow(items, gap)
        gap = gap or Screen:scaleBySize(8)
        local rows = VerticalGroup:new{ align = "left" }
        local row, row_w = HorizontalGroup:new{}, 0
        for _i, it in ipairs(items) do
            if row_w > 0 and row_w + gap + it.w > inner then
                table.insert(rows, row); table.insert(rows, VerticalSpan:new{ width = gap })
                row, row_w = HorizontalGroup:new{}, 0
            end
            if row_w > 0 then table.insert(row, HorizontalSpan:new{ width = gap }); row_w = row_w + gap end
            table.insert(row, it.widget); row_w = row_w + it.w
        end
        if row_w > 0 then table.insert(rows, row) end
        return rows
    end
    local function setSummary(inc, exc, total)
        local n_inc, n_exc = 0, 0
        for _k in pairs(inc or {}) do n_inc = n_inc + 1 end
        for _k in pairs(exc or {}) do n_exc = n_exc + 1 end
        if n_inc == 0 and n_exc == 0 then return _("Any"), false end
        local parts = {}
        if n_inc > 0 then table.insert(parts, total and string.format(_("%d of %d"), n_inc, total) or string.format(_("%d chosen"), n_inc)) end
        if n_exc > 0 then table.insert(parts, string.format(_("%d hidden"), n_exc)) end
        return table.concat(parts, ", "), true
    end
    local function navRow(label, value, active, callback)
        local h = Screen:scaleBySize(50)
        local right = HorizontalGroup:new{ align = "center",
            TextWidget:new{ text = value, face = face15, bold = active, fgcolor = active and BlitBuffer.COLOR_BLACK or MUTED,
                max_width = math.floor(inner * 0.55) },
            HorizontalSpan:new{ width = Screen:scaleBySize(6) },
            IconWidget:new{ icon = "chevron.right", width = Screen:scaleBySize(16), height = Screen:scaleBySize(16) } }
        local d = Geom:new{ w = inner, h = h }
        return VerticalGroup:new{ align = "left",
            TapBox:new{ HorizontalGroup:new{ HorizontalSpan:new{ width = P },
                OverlapGroup:new{ dimen = d, allow_mirroring = false,
                    LeftContainer:new{ dimen = d, TextWidget:new{ text = label, face = face15 } },
                    RightContainer:new{ dimen = d, right } },
                HorizontalSpan:new{ width = P } }, callback = callback },
            rowLine(),
        }
    end

    local body = VerticalGroup:new{ align = "left" }
    table.insert(body, sectionBar(_("FILTER")))
    -- books / tags / chapters (the existing pickers: tap an item to show only it, again to hide it)
    local book_count = list:offeredCount("books", "books_exclude", NotesListWidget.bookKeys)
    if not list.single_book then
        local v, on = setSummary(af.books, af.books_exclude, book_count)
        table.insert(body, navRow(_("Books"), v, on, function() self.helpers.books() end))
        -- authors, series, language: only when some book has one (or a filter is on)
        local labels = { authors = _("Authors"), series = _("Series"), languages = _("Language") }
        for i = 1, #NotesListWidget.META_KINDS do
            local kind = NotesListWidget.META_KINDS[i]
            local exc = kind .. "_exclude"
            local has_value = false
            for ni = 1, #list.notes_list do
                local vals = NotesListWidget.metaValues(list.notes_list[ni], kind)
                for j = 1, #vals do
                    if vals[j] ~= "" then has_value = true end
                end
            end
            local filtered = (type(af[kind]) == "table" and next(af[kind])) or (type(af[exc]) == "table" and next(af[exc]))
            if has_value or filtered then
                local count = list:offeredCount(kind, exc, function(n) return NotesListWidget.metaValues(n, kind) end)
                local mv, mon = setSummary(af[kind], af[exc], count)
                table.insert(body, navRow(labels[kind], mv, mon, function() self.helpers.meta(kind) end))
            end
        end
    end
    do
        local v, on = setSummary(af.tags, af.tags_exclude)
        table.insert(body, navRow(_("Tags"), v, on, function() self.helpers.tags() end))
    end
    if self.helpers.chapters_available() then
        local v, on = setSummary(af.chapters, af.chapters_exclude)
        table.insert(body, navRow(_("Chapters"), v, on, function() self.helpers.chapters() end))
    end

    -- (What shows - all, with a note, without, bookmarks - is the tab row's job, not a filter:
    -- filters apply to every tab, so there is no "Notes" row here.)

    -- colour & style: chips for all colours and styles; "Hide these instead" flips
    -- between showing only these and hiding these. Not on the Bookmarks tab: bookmarks have no
    -- colour or style, so these would do nothing there.
    if list:tabKey() ~= "bookmarks" then
        local items = {}
        -- setting: only offer colours/styles that some highlight uses (off = offer all)
        local only_used = getSetting("hide_unused_cs", false) == true
        local used = {}
        if only_used then
            for _i, n in ipairs(list.notes_list) do
                local nw = Core.NoteWrapper:new(n)
                local c, d = nw:getNormalizedColor(), nw:getNormalizedDrawer()
                if c then used["color:" .. c] = true end
                if d then used["style:" .. d] = true end
            end
        end
        -- shown: all, or (setting) only used ones, plus whatever is currently chosen
        local function offered(key) return not only_used or used[key] or (af.cs and af.cs[key]) end
        local function toggle(key)
            af.cs = af.cs or {}
            if af.cs[key] then af.cs[key] = nil else af.cs[key] = true end
            if not next(af.cs) then af.cs, af.cs_exclude = nil, nil end
            self:changed()
        end
        for _i, hc in ipairs(ReaderHighlight.highlight_colors) do
            local key = "color:" .. hc[2]
            if offered(key) then
                table.insert(items, chip(NoteItemWidget.colorLabel(hc[2]), af.cs and af.cs[key], function() toggle(key) end, { dot = hc[2] }))
            end
        end
        -- the styles on a row of their own, stretched to equal widths across it; natural widths
        -- (wrapping) when they would not fit side by side
        local styles = {}
        for n = 1, #HIGHLIGHT_STYLES do
            local st = HIGHLIGHT_STYLES[n]
            if offered("style:" .. st[1]) then table.insert(styles, st) end
        end
        local gap = Screen:scaleBySize(8)
        local function styleChips(w)
            local list = {}
            for n = 1, #styles do
                local st = styles[n]
                local key = "style:" .. st[1]
                local deco = (st[1] == "underscore" and "underline") or (st[1] == "strikeout" and "strike") or nil
                list[n] = chip(st[2], af.cs and af.cs[key], function() toggle(key) end, { deco = deco, w = w })
            end
            return list
        end
        local each = #styles > 0 and math.floor((inner - gap * (#styles - 1)) / #styles) or 0
        local style_items = styleChips(each)
        for n = 1, #style_items do
            if style_items[n].w > each then style_items = styleChips(nil); break end
        end
        local flip = TapBox:new{ underlined(af.cs_exclude and _("Show only these instead") or _("Hide these instead"), face13),
            callback = function()
                af.cs_exclude = not af.cs_exclude
                if af.cs and next(af.cs) then self:changed() else self:rebuild() end
            end }
        table.insert(body, padded(VerticalGroup:new{ align = "left",
            labelRow(TextWidget:new{ text = af.cs_exclude and _("Hide colour & style") or _("Colour & style"), face = face15 }, flip),
            VerticalSpan:new{ width = Screen:scaleBySize(8) },
            flow(items),
            (#items > 0 and #style_items > 0) and VerticalSpan:new{ width = gap } or nil,
            #style_items > 0 and flow(style_items) or nil,
        }, Screen:scaleBySize(14), Screen:scaleBySize(14)))
        table.insert(body, rowLine())
    end

    -- text contains: the search box (highlights and notes); more text filters below it
    do
        local q = af.search_any
        local field_h = Screen:scaleBySize(42)
        local field_text = TextWidget:new{ text = (q and q ~= "") and q or _("Search highlights and notes"), face = face14,
            fgcolor = (q and q ~= "") and BlitBuffer.COLOR_BLACK or MUTED, max_width = inner - Screen:scaleBySize(24) }
        local field = TapBox:new{
            RoundedBox:new{ width = inner, radius = Screen:scaleBySize(8), border = thin, border_color = BlitBuffer.COLOR_BLACK,
                fill = BlitBuffer.COLOR_WHITE, pad_x = Screen:scaleBySize(12), pad_y = math.floor((field_h - field_text:getSize().h) / 2),
                field_text },
            callback = function() list:showSearchDialog(function() self:rebuild() end) end,
        }
        local more_active = false
        for _i, k in ipairs({ "search_highlight", "search_highlight_exclude", "search_note", "search_note_exclude" }) do
            if af[k] and af[k] ~= "" then more_active = true end
        end
        local more = TapBox:new{ underlined((more_active and "✓ " or "") .. _("More text filters"), face13),
            callback = function() self:showTextFilters() end }
        table.insert(body, padded(VerticalGroup:new{ align = "left",
            labelRow(TextWidget:new{ text = _("Text contains"), face = face15 }, more),
            VerticalSpan:new{ width = Screen:scaleBySize(8) },
            field,
        }, Screen:scaleBySize(14), Screen:scaleBySize(14)))
    end

    -- sort: one row, drawn like the Books and Tags rows; the value is the same label the list shows
    -- next to the tabs ("Titles A–Z › Start to end"). A tap opens the Sort page (SortPicker), where
    -- Then by / And then by are set. The quick picks stay on the sort card in the tab row.
    table.insert(body, sectionBar(_("SORT")))
    do
        local single = list.single_book
        table.insert(body, navRow(_("Sort by"), sortModeLabel(Core.SortState.get(single), single), true,
            function() list:showSortPicker(function() self:rebuild() end) end))
    end

    -- saved filters: the current filters and sort order under a name, one tap to bring them back
    table.insert(body, sectionBar(_("SAVED FILTERS")))
    do
        local presets = getSetting("filter_presets", {})
        local function same(a, b)
            if type(a) ~= type(b) then return false end
            if type(a) ~= "table" then return a == b end
            for k, v in pairs(a) do if k ~= "notes_presence" and not same(v, b[k]) then return false end end
            for k in pairs(b) do if k ~= "notes_presence" and a[k] == nil then return false end end
            return true
        end
        local chips = {}
        -- A saved filter keeps both sort orders: the annotation tabs' (sort) and the Bookmarks
        -- tab's (sort_bm); each tab gets its own back. (Filters saved before kept one order, from
        -- the kind of tab they were saved on: p.bm.) The filters apply on every tab.
        local single = list.single_book
        local function sortsOf(p)
            if p.bm then return nil, p.sort end
            return p.sort, p.sort_bm
        end
        local function sortHere(p)
            local a, b = sortsOf(p)
            if Core.SortState.bm_tab then return b end
            return a
        end
        for i, p in ipairs(presets) do
            local here = sortHere(p)
            -- compared the way it applies (an old or broken saved filter is cleaned up on applying)
            local pf = deepCopy(p.filter) or {}
            normalizeColorStyle(pf)
            NotesListWidget.dropStaleSearchOptions(pf)
            local on = same(pf, list.active_filter or {}) and (not here
                or Core.SortState.normView(here, single) == Core.SortState.normView(Core.SortState.get(single), single))
            table.insert(chips, chip(p.name, on, function()
                local presence = list.active_filter and list.active_filter.notes_presence
                list.active_filter = deepCopy(p.filter) or {}
                list.active_filter.notes_presence = presence
                local a, b = sortsOf(p)
                if a then Core.SortState.setFor(single, false, a) end
                if b then Core.SortState.setFor(single, true, b) end
                if a or b then list:applySort() end
                self:changed()
            end, { single = true, hold = function()
                local ConfirmBox = require("ui/widget/confirmbox")
                NotesListWidget.showDialog(ConfirmBox:new{
                    text = string.format(_("Delete the saved filter “%s”?"), p.name),
                    ok_text = _("Delete"),
                    ok_callback = function()
                        table.remove(presets, i)
                        setSetting("filter_presets", presets)
                        self:rebuild()
                    end })
            end }))
        end
        if #presets == 0 then
            table.insert(body, padded(TextWidget:new{ text = _("Nothing saved yet."), face = face13, fgcolor = COLORS.muted },
                Screen:scaleBySize(12), Screen:scaleBySize(4)))
        else
            table.insert(body, padded(flow(chips), Screen:scaleBySize(14), Screen:scaleBySize(6)))
            table.insert(body, padded(TextWidget:new{ text = _("Hold one to delete it."), face = Font:getFace("cfont", 12 + getSettingsFontShift()), fgcolor = COLORS.muted },
                0, Screen:scaleBySize(4)))
        end
        local save_tw = TextWidget:new{ text = _("Save current filters…"), face = face13 }
        table.insert(body, padded(TapBox:new{ VerticalGroup:new{ save_tw, LineWidget:new{
                dimen = Geom:new{ w = save_tw:getSize().w, h = Size.line.medium }, background = BlitBuffer.COLOR_BLACK } },
            callback = function()
                local InputDialog = require("ui/widget/inputdialog")
                local dlg
                local function save()
                    local name = (dlg:getInputText() or ""):gsub("^%s+", ""):gsub("%s+$", "")
                    if name == "" then name = string.format(_("Filter %d"), #presets + 1) end
                    local copy = deepCopy(list.active_filter) or {}
                    copy.notes_presence = nil
                    table.insert(presets, { name = name, filter = copy, sort = Core.SortState.getFor(list.single_book, false),
                        sort_bm = Core.SortState.getFor(list.single_book, true) })
                    setSetting("filter_presets", presets)
                    UIManager:close(dlg)
                    self:rebuild()
                end
                dlg = InputDialog:new{ title = _("Save filters"), input = "", input_hint = _("Name"),
                    description = _("Saves the filters and the sort orders (annotations and bookmarks) as they are now."),
                    buttons = {{
                        { text = _("Cancel"), id = "close", callback = function() UIManager:close(dlg) end },
                        { text = _("Save"), is_enter_default = true, callback = save } } } }
                NotesListWidget.showDialog(dlg)
                dlg:onShowKeyboard()
            end }, Screen:scaleBySize(14), Screen:scaleBySize(14)))
    end

    -- title bar and bottom bar, shared with the pickers
    local header = Core.Page.header(self, _("Filter & sort"), function() self:onClose() end, {
        TapBox:new{ CenterContainer:new{ dimen = Geom:new{ w = Screen:scaleBySize(90), h = TOPBAR_HEIGHT }, underlined(_("Reset all"), face14) },
            callback = function()
                -- clears the filters; the tab stays (as "Clear all" next to the filter chips)
                local presence = list.active_filter and list.active_filter.notes_presence
                list.active_filter = { notes_presence = presence }
                self:changed()
            end },
    }, true)
    local footer = Core.Page.footer(function() self:onClose() end, Core.Page.countText(#(list.filtered_notes or {}), list),
        function() self:onDone() end)

    -- body scrolls when it doesn't fit (landscape, small screens)
    local avail = H - header:getSize().h - footer:getSize().h
    local body_widget = Core.Page.paged(self, W, avail, body)
    self[1] = FrameContainer:new{ width = W, height = H, padding = 0, margin = 0, bordersize = 0,
        background = BlitBuffer.COLOR_WHITE,
        OverlapGroup:new{ dimen = Geom:new{ w = W, h = H }, allow_mirroring = false,
            VerticalGroup:new{ align = "left", header, body_widget },
            BottomContainer:new{ dimen = Geom:new{ w = W, h = H }, footer },
        },
    }
end
function FilterScreen:showTextFilters()
    local ButtonDialog = require("ui/widget/buttondialog")
    local af = self.list.active_filter or {}
    local dialog
    local function entry(field, is_exclude, label, title, hint)
        local key = is_exclude and (field .. "_exclude") or field
        local on = af[key] and af[key] ~= ""
        return { text = (on and "✓ " or "") .. label, callback = function()
            UIManager:close(dialog)
            self.helpers.text(field, title, hint, is_exclude)
        end }
    end
    dialog = ButtonDialog:new{
        title = _("Text filters"),
        buttons = {
            { entry("search_highlight", false, _("Highlight contains"), _("Filter by Highlight Text"), _("Words in highlighted text…")) },
            { entry("search_highlight", true, _("Highlight doesn't contain"), _("Exclude by Highlight Text"), _("Words in highlighted text…")) },
            { entry("search_note", false, _("Note contains"), _("Filter by Note Text"), _("Words in your notes…")) },
            { entry("search_note", true, _("Note doesn't contain"), _("Exclude by Note Text"), _("Words in your notes…")) },
            { { text = _("Close"), callback = function() UIManager:close(dialog) end } },
        },
    }
    NotesListWidget.showDialog(dialog)
end
function FilterScreen:onDone()
    self.list.filter_screen = nil
    UIManager:close(self, "flashui")
    return true
end
function FilterScreen:onClose()
    -- Cancel: put filters and sort back as they were
    self.list.active_filter = self.saved_filter
    if Core.SortState.restore(self.saved_sorts) then self.list:applySort() end
    self.list:refresh()
    return self:onDone()
end
function NotesListWidget:showFilterScreen(helpers)
    if self.filter_screen then UIManager:close(self.filter_screen) end
    self.filter_screen = FilterScreen:new{ list = self, helpers = helpers }
    UIManager:show(self.filter_screen, "flashui")
end

-- Settings: one full-screen page (Text / List / Pages / Filter) instead of the chain of button
-- dialogs. Every setting is still here; changes apply straight away. The list-of-numbers
-- settings (font sizes, margins, spacing) and the typeface picker keep their own dialogs.
do -- own scope: keeps the main chunk under Lua's 200-locals limit
local SS = InputContainer:extend{ list = nil, page = nil, parent_screen = nil, covers_fullscreen = true }
NotesListWidget.SettingsScreen = SS
function SS:init()
    -- Core.Page exists only once main.lua has loaded, so install the hooks here
    if not self.page_hooks then
        self.page_hooks = true
    end
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    if Device:hasKeys() then self.key_events.Close = { { Input.group.Back } } end
    self:build()
end
function SS:rebuild()
    self:build()
    UIManager:setDirty(self, "ui")
end
-- a changed setting: redraw the list behind, then this page
function SS:changed()
    self.list:refresh()
    self:rebuild()
end
function SS:onClose()
    UIManager:close(self, "flashui")
    -- a sub page: the Settings page under it redraws with the new values
    if self.page and self.list.settings_screen then self.list.settings_screen:rebuild() end
    return true
end
function SS:onCloseWidget()
    if self.list.settings_screen == self then self.list.settings_screen = nil end
end
function SS:build()
    local W, H = Screen:getWidth(), Screen:getHeight()
    local P = Screen:scaleBySize(24)
    local inner = W - P * 2
    local thin = Size.border.button
    local MUTED = COLORS.muted
    -- The Settings page's own text size, as a shift on its usual sizes (Settings > Text size).
    -- Its headings are 15, its controls 13 and its notes 12; the shift moves all three together,
    -- so making the page easier to read does not throw its layout out of proportion.
    local page_shift = getSettingsFontShift()
    local face15, face13 = Font:getFace("cfont", 15 + page_shift), Font:getFace("cfont", 13 + page_shift)
    local face12 = Font:getFace("cfont", 12 + page_shift)
    local function rowLine() return Core.Page.rowLine(P, inner) end
    local sectionBar = Core.Page.sectionBars(P, inner)
    local function padded(widget, top, bottom) return Core.Page.padded(widget, P, top, bottom) end
    -- label (with an optional grey line under it) on the left, a control on the right
    local function row(label, sub, control, callback)
        local ctl_w = control and control:getSize().w or 0
        local left = TextWidget:new{ text = label, face = face15, max_width = inner - ctl_w - Screen:scaleBySize(12) }
        if sub then
            left = VerticalGroup:new{ align = "left", left, VerticalSpan:new{ width = Screen:scaleBySize(2) },
                TextWidget:new{ text = sub, face = face12, fgcolor = MUTED, max_width = inner - ctl_w - Screen:scaleBySize(12) } }
        end
        local d = Geom:new{ w = inner, h = Screen:scaleBySize(sub and 58 or 50) }
        local line = HorizontalGroup:new{ HorizontalSpan:new{ width = P },
            OverlapGroup:new{ dimen = d, allow_mirroring = false,
                LeftContainer:new{ dimen = d, left },
                control and RightContainer:new{ dimen = d, control } or nil },
            HorizontalSpan:new{ width = P } }
        return VerticalGroup:new{ align = "left", callback and TapBox:new{ line, callback = callback } or line, rowLine() }
    end
    local function navRow(label, value, callback)
        local right = HorizontalGroup:new{ align = "center" }
        if value and value ~= "" then
            table.insert(right, TextWidget:new{ text = value, face = face15, fgcolor = MUTED, max_width = math.floor(inner * 0.5) })
            table.insert(right, HorizontalSpan:new{ width = Screen:scaleBySize(6) })
        end
        table.insert(right, IconWidget:new{ icon = "chevron.right", width = Screen:scaleBySize(16), height = Screen:scaleBySize(16) })
        return row(label, nil, right, callback)
    end
    -- on/off switch: black track with a white knob on the right when on
    local function toggle(label, sub, key, getter, after)
        local on = getter() == true
        local sw_w, sw_h, knob, m = Screen:scaleBySize(50), Screen:scaleBySize(28), Screen:scaleBySize(20), Screen:scaleBySize(4)
        local track = Pill:new{ width = sw_w, height = sw_h, fill = on and BlitBuffer.COLOR_BLACK or BlitBuffer.COLOR_WHITE,
            border = on and 0 or thin, border_color = BlitBuffer.COLOR_BLACK }
        local k = Pill:new{ width = knob, height = knob, border = 0, fill = on and BlitBuffer.COLOR_WHITE or BlitBuffer.COLOR_BLACK }
        k.overlap_offset = { on and (sw_w - knob - m) or m, math.floor((sw_h - knob) / 2) }
        local sw = OverlapGroup:new{ dimen = Geom:new{ w = sw_w, h = sw_h }, allow_mirroring = false, track, k }
        return row(label, sub, sw, function() setSetting(key, not on); if after then after() end; self:changed() end)
    end
    local function outlineCells(cells, cell_h)
        local seg = HorizontalGroup:new{}
        for i, c in ipairs(cells) do
            if i > 1 then table.insert(seg, LineWidget:new{ dimen = Geom:new{ w = thin, h = cell_h }, background = BlitBuffer.COLOR_BLACK }) end
            table.insert(seg, c)
        end
        return RoundedOutline:new{ radius = Screen:scaleBySize(8), border = thin, seg }
    end
    -- step/default given: the number can be tapped to open the number dialog (type a value)
    local function stepper(label, sub, key, value, min, max, step, default)
        step = step or 1
        local h = Screen:scaleBySize(36)
        local function cell(text, w, cb, bold)
            return TapBox:new{ CenterContainer:new{ dimen = Geom:new{ w = w, h = h },
                TextWidget:new{ text = text, face = face15, bold = bold } }, callback = cb }
        end
        local function set(v) v = math.max(min, math.min(max, v)); if v ~= value then setSetting(key, v); self:changed() end end
        local ctl = outlineCells({ cell("−", Screen:scaleBySize(44), function() set(value - step) end),
            cell(tostring(value), Screen:scaleBySize(48), default and function()
                self.list:showSpinSetting(label, key, default, min, max, step, function() self:rebuild() end)
            end or nil, true),
            cell("+", Screen:scaleBySize(44), function() set(value + step) end) }, h)
        return row(label, sub, ctl)
    end
    -- options side by side in one rounded outline, the chosen one black
    local function segment(label, options, current, pick)
        local n = #options
        local cell_h = Screen:scaleBySize(40)
        local cell_w = math.floor((inner - thin * 2 - thin * (n - 1)) / n)
        local cells = {}
        for _i, opt in ipairs(options) do
            local on = (current == opt[1])
            table.insert(cells, TapBox:new{
                FrameContainer:new{ bordersize = 0, padding = 0, margin = 0,
                    background = on and BlitBuffer.COLOR_BLACK or BlitBuffer.COLOR_WHITE,
                    CenterContainer:new{ dimen = Geom:new{ w = cell_w, h = cell_h },
                        TextWidget:new{ text = opt[2], face = face13, bold = on,
                            max_width = cell_w - Screen:scaleBySize(8),
                            fgcolor = on and BlitBuffer.COLOR_WHITE or BlitBuffer.COLOR_BLACK } } },
                callback = function() if not on then pick(opt[1]) end end })
        end
        return VerticalGroup:new{ align = "left",
            padded(VerticalGroup:new{ align = "left", TextWidget:new{ text = label, face = face15 },
                VerticalSpan:new{ width = Screen:scaleBySize(8) }, outlineCells(cells, cell_h) },
                Screen:scaleBySize(12), Screen:scaleBySize(14)),
            rowLine() }
    end
    -- which of date / author / chapter are on: small chips on the right (black when on)
    local function fieldChips(label, sub, getter, key)
        local active = {}
        for f in getter():gmatch("[^,]+") do active[f] = true end
        local chips = HorizontalGroup:new{ align = "center" }
        for i, f in ipairs({ { "date", _("Date") }, { "author", _("Author") }, { "chapter", _("Chapter") } }) do
            local on = active[f[1]]
            local text = f[2]
            local widest = TextWidget:new{ text = f[2], face = face13, bold = true }:getSize().w
            local w = widest + Screen:scaleBySize(20)
            local color = on and BlitBuffer.COLOR_WHITE or BlitBuffer.COLOR_BLACK
            if i > 1 then table.insert(chips, HorizontalSpan:new{ width = Screen:scaleBySize(6) }) end
            table.insert(chips, TapBox:new{
                Pill:new{ width = w, height = Screen:scaleBySize(32), fill = on and BlitBuffer.COLOR_BLACK or BlitBuffer.COLOR_WHITE,
                    border = on and 0 or thin, border_color = COLORS.line,
                    TextWidget:new{ text = text, face = face13, bold = on, fgcolor = color } },
                callback = function()
                    if on then active[f[1]] = nil else active[f[1]] = true end
                    local parts = {}
                    for _j, k in ipairs({ "date", "author", "chapter" }) do if active[k] then table.insert(parts, k) end end
                    setSetting(key, #parts > 0 and table.concat(parts, ",") or "date")
                    self:changed()
                end })
        end
        return row(label, sub, chips)
    end
    local list = self.list

    local body = VerticalGroup:new{ align = "left" }
    local function add(w) table.insert(body, w) end

    local function fontRow(label, key, getter)
        return navRow(label, NotesListWidget.SubPage.fontName(getter()), function()
            UIManager:show(NotesListWidget.SubPage:new{ list = list, parent = self, font_key = key, title = label })
        end)
    end
    local function numberRows(menu_key)
        for _i, st in ipairs(SPIN_MENUS[menu_key].settings) do
            add(stepper((st.label:gsub(":%s*$", "")), nil, st.key, st.getter(), st.min, st.max, st.step, st.default))
        end
    end
    if self.page == "text" then
        add(sectionBar(_("FONTS")))
        add(fontRow(_("Title font"), "title_font", getTitleFont))
        add(fontRow(_("Info font"), "info_font", getInfoFont))
        add(navRow(_("Author font"), getSetting("author_font", nil) and NotesListWidget.SubPage.fontName(getSetting("author_font", nil))
                or _("Same as info"), function()
            UIManager:show(NotesListWidget.SubPage:new{ list = list, parent = self, font_key = "author_font", title = _("Author font") })
        end))
        add(fontRow(_("Content font"), "content_font", getContentFont))
        add(navRow(_("Note font"), getSetting("note_font", nil) and NotesListWidget.SubPage.fontName(getSetting("note_font", nil))
                or _("Same as content"), function()
            UIManager:show(NotesListWidget.SubPage:new{ list = list, parent = self, font_key = "note_font", title = _("Note font") })
        end))
        add(sectionBar(_("SIZES")))
        numberRows("font_size")
        local info_size = getInfoFontSize()
        add(stepper(_("Author size"), _("Same as the info size until you change it"), "author_font_size",
            getSetting("author_font_size", nil) or info_size, 8, 48, 1, info_size))
        local content_size = getContentFontSize()
        add(stepper(_("Note size"), _("Same as the content size until you change it"), "note_font_size",
            getSetting("note_font_size", nil) or content_size, 8, 48, 1, content_size))
        add(stepper(_("Lines per highlight"), _("Longer ones end with “…”; tap to read all"), "truncate_lines", getTruncateLines(), 1, 20))
        add(stepper(_("Lines per note"), _("Longer notes end with “…”; tap to read all"), "truncate_note_lines", NoteItemWidget.noteLinesMax(), 1, 20))
        add(toggle(_("Justify text"), nil, "justify", getJustify))
        add(sectionBar(_("CAPITALS")))
        local case_opts = { { "normal", _("As written") }, { "upper", _("CAPITALS") } }
        add(segment(_("Book and chapter titles"), case_opts, getSetting("title_case", "normal"),
            function(v) setSetting("title_case", v); self:changed() end))
        add(segment(_("Chapter · date line"), case_opts, getSetting("info_case", "normal"),
            function(v) setSetting("info_case", v); self:changed() end))
        add(segment(_("Author name"), { { "upper", _("CAPITALS") }, { "normal", _("As written") } },
            getSetting("author_case", "upper"), function(v) setSetting("author_case", v); self:changed() end))
    elseif self.page == "spacing" then
        -- grouped by where the space is, in the order an annotation is drawn: page, between annotations,
        -- the heading, the highlight text, the note
        local function rowsFor(keys)
            local by_key = {}
            for _, menu in ipairs({ "margins", "section_margin" }) do
                for _, st in ipairs(SPIN_MENUS[menu].settings) do by_key[st.key] = st end
            end
            for _, key in ipairs(keys) do
                local st = by_key[key]
                add(stepper((st.label:gsub(":%s*$", "")), nil, st.key, st.getter(), st.min, st.max, st.step, st.default))
            end
        end
        add(sectionBar(_("PAGE")))
        rowsFor({ "top_padding", "h_margin", "landscape_width_pct" })
        add(sectionBar(_("BETWEEN ANNOTATIONS")))
        rowsFor({ "note_spacing" })
        add(sectionBar(_("BOOK HEADING")))
        rowsFor({ "title_margin", "info_margin" })
        add(sectionBar(_("HIGHLIGHT TEXT")))
        rowsFor({ "text_margin", "line_spacing" })
        add(sectionBar(_("YOUR NOTE")))
        rowsFor({ "note_offset", "note_indent" })
    elseif self.page == "review" then
        -- Review mode: which styles of highlight get covered when the mode is switched on in the
        -- list's top bar. Nothing set means every style, which is what a fresh install shows.
        add(sectionBar(_("COVER THESE STYLES")))
        local chosen = getReviewCoverStyles()
        for _i, st in ipairs({ { "lighten", _("Highlight") }, { "underscore", _("Underline") },
                { "strikeout", _("Strikeout") }, { "invert", _("Invert") } }) do
            local key, label = st[1], st[2]
            local on = (chosen == nil) or chosen[key] == true -- nothing set: every style is on
            local sw_w, sw_h, knob, m = Screen:scaleBySize(50), Screen:scaleBySize(28), Screen:scaleBySize(20), Screen:scaleBySize(4)
            local track = Pill:new{ width = sw_w, height = sw_h, fill = on and BlitBuffer.COLOR_BLACK or BlitBuffer.COLOR_WHITE,
                border = on and 0 or thin, border_color = BlitBuffer.COLOR_BLACK }
            local k = Pill:new{ width = knob, height = knob, border = 0, fill = on and BlitBuffer.COLOR_WHITE or BlitBuffer.COLOR_BLACK }
            k.overlap_offset = { on and (sw_w - knob - m) or m, math.floor((sw_h - knob) / 2) }
            local sw = OverlapGroup:new{ dimen = Geom:new{ w = sw_w, h = sw_h }, allow_mirroring = false, track, k }
            add(row(label, nil, sw, function()
                local cur = getReviewCoverStyles()
                local next_styles = {}
                for _j, name in ipairs(REVIEW_STYLES) do
                    local was_on = (cur == nil) or cur[name] == true -- nothing set: all on
                    if name == key then was_on = not was_on end
                    if was_on then next_styles[name] = true end
                end
                if next(next_styles) == nil then
                    -- nothing chosen covers no annotation text: only the notes, the picked words
                    -- and the questions are hidden, so their "always" switches are turned on too
                    G_reader_settings:saveSetting("annotationsviewer_review_cover_styles", {}) -- empty: none
                    setSetting("review_notes_always", true)
                    setSetting("review_cloze_always", true)
                    setSetting("review_question_always", true)
                else
                    G_reader_settings:saveSetting("annotationsviewer_review_cover_styles", next_styles)
                end
                self:changed()
            end))
        end
        add(VerticalSpan:new{ width = Screen:scaleBySize(12) })
        add(padded(VerticalGroup:new{ align = "left",
            TextBoxWidget:new{ text = _("With nothing chosen, only the notes and the custom cover (question and picked words) are covered."),
                face = face12, fgcolor = MUTED, width = inner } }, Screen:scaleBySize(12), Screen:scaleBySize(14)))
        add(rowLine())
        -- What happens to the notes: whether a note is hidden at all, then how the highlight and
        -- its note share the hiding
        add(sectionBar(_("NOTES")))
        add(toggle(_("Always cover notes"),
            _("Notes are hidden even when their style is not covered above"), "review_notes_always",
            function() return getSetting("review_notes_always", true) == true end))
        add(toggle(_("Cover only the note when there is one"),
            _("A highlight with a note keeps its text: only the note is hidden. Off: both are hidden"),
            "review_note_only", function() return getSetting("review_note_only", true) == true end))
        add(rowLine())
        -- Custom cover: the finer-grained counterpart of the whole-line cover above. Two modes:
        -- "picked words" (only some words of an annotation are covered) and "question" (the whole
        -- text is replaced by a question written for it). One reader-facing block, split in two.
        add(sectionBar(_("CUSTOM COVER")))
        -- What it is for, then each mode with how it is used, its own setting and its own clear.
        -- The counts and "Remove all" cover what the list is showing (this book, or the whole
        -- library as its filters leave it), not every book on the device.
        add(padded(VerticalGroup:new{ align = "left",
            TextBoxWidget:new{ text = _("A separate way of covering, more precise than the whole line. It has two modes, question and picked words; the list's “Custom” tab shows the annotations that have either."),
                face = face12, fgcolor = MUTED, width = inner } },
            Screen:scaleBySize(10), Screen:scaleBySize(6)))
        -- 1. question
        add(padded(VerticalGroup:new{ align = "left",
            TextWidget:new{ text = _("Question"), face = face15 },
            VerticalSpan:new{ width = Screen:scaleBySize(3) },
            TextBoxWidget:new{ text = _("Open an annotation's card and add a question for it, with the annotation itself as the answer. In review mode its text is replaced by the question, in bold; tap the row to swap question and text."),
                face = face12, fgcolor = MUTED, width = inner } },
            Screen:scaleBySize(10), Screen:scaleBySize(6)))
        add(toggle(_("Always show questions"),
            _("A question replaces the text even when its style is not covered above"), "review_question_always",
            function() return getSetting("review_question_always", true) == true end))
        do
            local notes = (self.list and (self.list.filtered_notes or self.list.notes_list)) or {}
            local n = NoteItemWidget.countClozeFor(notes, "question")
            local link = TextWidget:new{ text = _("Remove all"), face = face15,
                fgcolor = n > 0 and BlitBuffer.COLOR_BLACK or MUTED }
            local underline = LineWidget:new{ dimen = Geom:new{ w = link:getSize().w, h = Size.line.medium },
                background = n > 0 and BlitBuffer.COLOR_BLACK or MUTED }
            add(row(_("Annotations with a question"),
                n > 0 and (n == 1 and _("1 in this list") or string.format(_("%d in this list"), n))
                    or _("None in this list"),
                VerticalGroup:new{ align = "right", link, underline },
                n > 0 and function() NoteItemWidget.clearClozeFor(notes, "question"); self:changed() end or nil))
        end
        add(rowLine())
        -- 2. picked words
        add(padded(VerticalGroup:new{ align = "left",
            TextWidget:new{ text = _("Picked words"), face = face15 },
            VerticalSpan:new{ width = Screen:scaleBySize(3) },
            TextBoxWidget:new{ text = _("Open an annotation's card, delete everything that should stay readable and tap Add; in review mode only those words are covered, the rest of the line stays readable."),
                face = face12, fgcolor = MUTED, width = inner } },
            Screen:scaleBySize(10), Screen:scaleBySize(6)))
        add(toggle(_("Always cover picked words"),
            _("Picked words are hidden even when their style is not covered above"), "review_cloze_always",
            function() return getSetting("review_cloze_always", true) == true end))
        do
            local notes = (self.list and (self.list.filtered_notes or self.list.notes_list)) or {}
            local n = NoteItemWidget.countClozeFor(notes, "cloze")
            local link = TextWidget:new{ text = _("Remove all"), face = face15,
                fgcolor = n > 0 and BlitBuffer.COLOR_BLACK or MUTED }
            local underline = LineWidget:new{ dimen = Geom:new{ w = link:getSize().w, h = Size.line.medium },
                background = n > 0 and BlitBuffer.COLOR_BLACK or MUTED }
            add(row(_("Annotations with picked words"),
                n > 0 and (n == 1 and _("1 in this list") or string.format(_("%d in this list"), n))
                    or _("None in this list"),
                VerticalGroup:new{ align = "right", link, underline },
                n > 0 and function() NoteItemWidget.clearClozeFor(notes, "cloze"); self:changed() end or nil))
        end
        add(rowLine())
        add(sectionBar(_("MODE")))
        add(toggle(_("Start the list in review mode"),
            _("The list opens with the text already covered"), "review_start_on",
            function() return getSetting("review_start_on", false) == true end))
    elseif self.page == "bookmarks" then
        -- only what is a bookmark's own; fonts, capitals, margins and the note are the annotations'
        add(sectionBar(_("BOOKMARK LINE")))
        add(navRow(_("Font"), getSetting("bm_font", nil) and NotesListWidget.SubPage.fontName(getSetting("bm_font", nil))
                or _("Same as info"), function()
            UIManager:show(NotesListWidget.SubPage:new{ list = list, parent = self, font_key = "bm_font", title = _("Bookmark font") })
        end))
        local info_size = getInfoFontSize()
        add(stepper(_("Text size"), _("Same as the info size until you change it"), "bm_line_size",
            getSetting("bm_line_size", nil) or info_size, 8, 48, 1, info_size))
        add(segment(_("Date"), { { "sort", _("When sorted by date") }, { "always", _("Always") }, { "never", _("Never") } },
            NoteItemWidget.bmDate(), function(v) setSetting("bm_date", v); self:changed() end))
        add(sectionBar(_("NOTE")))
        add(toggle(_("Icon before the note"), nil, "bm_note_icon", NoteItemWidget.bmNoteIcon))
        add(sectionBar(_("SPACING")))
        add(stepper(_("Between bookmarks"), nil, "bm_spacing",
            getSetting("bm_spacing", NoteItemWidget.DEFAULT_BM_SPACING), 0, 100, 2, NoteItemWidget.DEFAULT_BM_SPACING))
    elseif self.page == "dates" then
        -- how dates are written: the month for every date (the clock is KOReader's own setting),
        -- then year and time for the list and for the annotation sheet, each its own
        add(sectionBar(_("DATE FORMAT")))
        local sample_t = os.time({ year = 2026, month = 9, day = 3, hour = 14 })
        add(segment(_("Month"), { { "short", "3 " .. NoteItemWidget.monthName(sample_t, false) },
                { "long", "3 " .. NoteItemWidget.monthName(sample_t, true) } }, getSetting("date_month", "short"),
            function(v) setSetting("date_month", v); self:changed() end))
        -- above a highlight: always, or only when the order goes by date (bookmarks: Bookmarks page)
        add(sectionBar(_("ABOVE HIGHLIGHTS")))
        add(segment(_("Show the date"), { { "sort", _("When sorted by date") }, { "always", _("Always") } },
            getSetting("info_date_when", "always"), function(v) setSetting("info_date_when", v); self:changed() end))
        local places = { { "list", _("IN THE LIST") }, { "sheet", _("ON THE ANNOTATION SHEET") } }
        for n = 1, #places do
            local place = places[n]
            local where = place[1]
            local st = NoteItemWidget.dateStyle(where)
            add(sectionBar(place[2]))
            add(segment(_("Year"), { { "relevant", _("When not this year") }, { "always", _("Always") } }, st.year,
                function(v) setSetting("date_year_" .. where, v); self:changed() end))
            add(segment(_("Time"), { { "never", _("Never") }, { "recent", _("Today and yesterday") }, { "always", _("Always") } }, st.time,
                function(v) setSetting("date_time_" .. where, v); self:changed() end))
        end
    elseif self.page == "info" then
        add(sectionBar(_("INFO ROW")))
        add(toggle(_("Show book / info row"), nil, "show_info", getShowInfo))
        add(fieldChips(_("Info row shows"), nil, getInfoFields, "info_fields"))
        add(toggle(_("Title on each page"), nil, "repeat_title_on_page", getRepeatTitleOnPage))
        add(toggle(_("Chapter headings in one book"), _("Heading above each chapter when you open a single book"), "chapter_headings", NoteItemWidget.showHeadings))
        add(toggle(_("Chapter heading on each page"), nil, "repeat_chapter_on_page", NoteItemWidget.repeatChapter))
        add(toggle(_("Chapter / date on each page"), nil, "repeat_info_on_page", getRepeatInfoOnPage))
        add(toggle(_("Hide duplicate book header"), nil, "hide_dup_title", getHideDupTitle))
        add(toggle(_("Hide duplicate info header"), nil, "hide_dup_info", getHideDupInfo))
        add(fieldChips(_("Duplicate check"), _("Repeated info is hidden when these match"), getDedupInfoFields, "dedup_info_fields"))
    elseif self.page == "export" then
        local o = Core.Export.options()
        local function pick(key) return function(v) setSetting("export_" .. key, v); self:rebuild() end end
        local function opt(key) return function() return Core.Export.options()[key] end end
        local function onOff(label, sub, key) return toggle(label, sub, "export_" .. key, opt(key)) end
        add(sectionBar(_("FORMAT")))
        add(segment(_("File type"), { { "md", _("Markdown") }, { "txt", _("Plain text") },
            { "html", _("HTML") }, { "epub", _("EPUB") } }, o.format, pick("format")))
        add(sectionBar(_("INCLUDE")))
        add(onOff(_("Title and filter at the top"), nil, "header"))
        add(onOff(_("Author"), _("After the book title"), "author"))
        add(segment(_("Chapter"), { { "line", _("In the info line") }, { "heading", _("As headings") }, { "none", _("Leave out") } },
            o.chapter, pick("chapter")))
        add(segment(_("Date"), { { "date", _("Date") }, { "datetime", _("Date and time") }, { "none", _("Leave out") } },
            o.date, pick("date")))
        if o.date ~= "none" then
            local sample_t = os.time({ year = 2026, month = 9, day = 3, hour = 14 })
            add(segment(_("Date format"), { { "iso", "2026-09-03" },
                    { "long", "3 " .. NoteItemWidget.monthName(sample_t) .. " 2026" } }, o.date_style, pick("date_style")))
        end
        -- the smaller parts as chips under one label (black when on; several can be on)
        do
            local chips = HorizontalGroup:new{ align = "center" }
            local parts = { { "page", _("Page") }, { "notes", _("Notes") }, { "style", _("Colour and style") }, { "tags", _("Tags") } }
            for i = 1, #parts do
                local key, text = parts[i][1], parts[i][2]
                local on = o[key] == true
                local w = TextWidget:new{ text = text, face = face13, bold = true }:getSize().w + Screen:scaleBySize(20)
                if i > 1 then table.insert(chips, HorizontalSpan:new{ width = Screen:scaleBySize(6) }) end
                table.insert(chips, TapBox:new{
                    Pill:new{ width = w, height = Screen:scaleBySize(32), fill = on and BlitBuffer.COLOR_BLACK or BlitBuffer.COLOR_WHITE,
                        border = on and 0 or thin, border_color = COLORS.line,
                        TextWidget:new{ text = text, face = face13, bold = on, fgcolor = on and BlitBuffer.COLOR_WHITE or BlitBuffer.COLOR_BLACK } },
                    callback = function() setSetting("export_" .. key, not on); self:rebuild() end })
            end
            add(VerticalGroup:new{ align = "left",
                padded(VerticalGroup:new{ align = "left", TextWidget:new{ text = _("Also include"), face = face15 },
                    VerticalSpan:new{ width = Screen:scaleBySize(8) }, chips }, Screen:scaleBySize(12), Screen:scaleBySize(14)),
                rowLine() })
        end
        add(sectionBar(_("ORDER")))
        add(segment(_("Books"), { { "book", _("Each book once") }, { "list", _("As in the list") } }, o.group, pick("group")))
        -- the book's order is a sort of the notes, so it applies whenever chapters are shown at all
        if o.chapter ~= "none" then
            add(segment(_("Chapters"), { { "book", _("In book order") }, { "list", _("As in the list") } },
                o.chapter_order, pick("chapter_order")))
        end
        if o.format == "md" or o.format == "html" or o.format == "epub" then
            add(sectionBar(_("STYLE")))
            add(segment(_("Highlight"), { { "quote", _("Quote") }, { "italic", _("Italic") }, { "plain", _("Plain") } },
                o.highlight, pick("highlight")))
            add(segment(_("Note"), { { "bold", _("Bold label") }, { "quote", _("Quote") }, { "italic", _("Italic") } },
                o.note_style, pick("note_style")))
        end
        add(sectionBar(_("FILES")))
        add(segment(_("Files"), { { "one", _("One file") }, { "book", _("One per book") } }, o.files, pick("files")))
        add(onOff(_("Date and time in the file name"), _("Off: exporting again replaces the file"), "name_date"))
        add(navRow(_("Folder"), Core.Export.shortDir(), function()
            local start = Core.Export.dir()
            if lfs.attributes(start, "mode") ~= "directory" then start = require("datastorage"):getDataDir() end
            UIManager:show(require("ui/widget/pathchooser"):new{
                select_directory = true, select_file = false, show_files = false, path = start,
                onConfirm = function(path) setSetting("export_dir", path); self:rebuild() end,
            })
        end))
    else
        add(sectionBar(_("LIST")))
        add(navRow(_("Text"), _("Fonts, sizes, capitals"),
            function() UIManager:show(SS:new{ list = list, page = "text", parent_screen = self }, "flashui") end))
        add(navRow(_("Spacing"), _("Margins, lines, notes"),
            function() UIManager:show(SS:new{ list = list, page = "spacing", parent_screen = self }, "flashui") end))
        do
            local names = {}
            local active = {}
            for f in getInfoFields():gmatch("[^,]+") do active[f] = true end
            for _i, f in ipairs({ { "date", _("Date") }, { "author", _("Author") }, { "chapter", _("Chapter") } }) do
                if active[f[1]] then table.insert(names, f[2]) end
            end
            add(navRow(_("Info row and repeats"), getShowInfo() and table.concat(names, " · ") or _("Off"),
                function() UIManager:show(SS:new{ list = list, page = "info", parent_screen = self }, "flashui") end))
        end
        add(navRow(_("Dates"), NoteItemWidget:formatDate(os.date("%Y-%m-%d 14:05:00", os.time() - 40 * 86400)) or "",
            function() UIManager:show(SS:new{ list = list, page = "dates", parent_screen = self }, "flashui") end))
        add(navRow(_("Bookmarks"), _("Line size, date, spacing"),
            function() UIManager:show(SS:new{ list = list, page = "bookmarks", parent_screen = self }, "flashui") end))
        add(toggle(_("Counts on tabs"), nil, "show_total", getShowTotalNotes))
        -- The Settings page's own text size: its headings, controls and notes all move together,
        -- so a page that is hard to read on a small screen can be made bigger without leaving the
        -- plugin. The default 15/13/12 is what 0 means.
        add(stepper(_("Text size of this page"),
            _("Headings, controls and notes of the plugin's own screens, all together"),
            "settings_font_shift", getSettingsFontShift(), -3, 9, 1, 0))

        add(sectionBar(_("PAGES")))
        add(segment(_("Page controls"), { { "default", _("Prev / Next") }, { "scrollbar", _("Scrollbar") },
            { "scrollbar_chevrons", _("Scrollbar + buttons") } }, getPaginationStyle(),
            function(v) setSetting("pagination_style", v); self:changed() end))
        add(toggle(_("Marks on the scrollbar"), _("Where a new book, author, month or chapter starts, by sort order"), "sb_book_marks", getScrollbarBookMarks))
        add(segment(_("Swipe to turn pages"), { { "both", _("Both") }, { "horizontal", _("Horizontal") },
            { "vertical", _("Vertical") }, { "disabled", _("Off") } }, getSwipeSetting(),
            function(v) setSetting("swipe_direction", v); self:changed() end))
        add(segment(_("Tapping an annotation"), { { "goto", _("Goes to the highlight") },
            { "card", _("Opens the card") } }, getTapSetting(),
            function(v) setSetting("tap_action", v); self:changed() end))
        add(segment(_("Holding an annotation"), { { "card", _("Opens the card") },
            { "goto", _("Goes to the highlight") } }, getHoldSetting(),
            function(v) setSetting("hold_action", v); self:changed() end))

        add(sectionBar(_("EXPORT")))
        add(navRow(_("Export"), NotesListWidget.Export.summary(),
            function() UIManager:show(SS:new{ list = list, page = "export", parent_screen = self }, "flashui") end))

        add(sectionBar(_("KOREADER")))
        add(toggle(_("KOReader's Bookmarks open here"), _("Its menu entries, gestures and Bookmarks buttons open the Bookmarks tab here"),
            "take_over_bookmarks", function()
                -- same test as AllNotesViewer.takeOverOn, which settings.lua cannot reach
                local v = getSetting("take_over_bookmarks", false)
                return v == true or v == "all" or v == "bookmarks"
            end))

        add(sectionBar(_("FILTER")))
        add(toggle(_("Only offer used colours and styles"), nil, "hide_unused_cs",
            function() return getSetting("hide_unused_cs", false) == true end))
    end

    local titles = { text = _("Text"), spacing = _("Spacing"), info = _("Info row and repeats"), bookmarks = _("Bookmarks"), dates = _("Dates"),
        export = _("Export"), review = _("Review mode") }
    local right_items
    if self.page == "text" or self.page == "spacing" or self.page == "bookmarks" or self.page == "export" then
        local keys = ({ text = { "font_size" }, spacing = { "margins", "section_margin" } })[self.page] or {}
        right_items = { TapBox:new{ CenterContainer:new{ dimen = Geom:new{ w = Screen:scaleBySize(90), h = TOPBAR_HEIGHT },
                (function()
                    local tw = TextWidget:new{ text = _("Reset"), face = Font:getFace("cfont", 14 + getSettingsFontShift()) }
                    return VerticalGroup:new{ tw, LineWidget:new{ dimen = Geom:new{ w = tw:getSize().w, h = Size.line.medium },
                        background = BlitBuffer.COLOR_BLACK } }
                end)() },
            callback = function()
                for _i, key in ipairs(keys) do
                    for _j, st in ipairs(SPIN_MENUS[key].settings) do setSetting(st.key, st.default) end
                end
                if self.page == "export" then
                    for k in pairs(NotesListWidget.Export.DEFAULTS) do setSetting("export_" .. k, nil) end
                    setSetting("export_dir", nil)
                end
                if self.page == "bookmarks" then
                    setSetting("bm_line_size", nil); setSetting("bm_spacing", nil); setSetting("bm_date", nil)
                    setSetting("bm_note_icon", nil); setSetting("bm_font", nil)
                end
                if self.page == "text" then
                    setSetting("title_font", nil); setSetting("info_font", nil); setSetting("content_font", nil)
                    setSetting("note_font", nil); setSetting("note_font_size", nil)
                    setSetting("author_font", nil); setSetting("author_font_size", nil); setSetting("author_case", "upper")
                    setSetting("title_case", "normal"); setSetting("info_case", "normal")
                    setSetting("truncate_lines", DEFAULT_TRUNCATE_LINES); setSetting("truncate_note_lines", NoteItemWidget.DEFAULT_NOTE_LINES); setSetting("justify", false)
                end
                self:changed()
            end } }
    end
    -- opened from ☰ → Core.Export: a page of its own (only ✕), with Copy / Core.Export at the bottom
    local header = Core.Page.header(self, titles[self.page] or _("Settings"), function() self:onClose() end, right_items,
        not self.page or self.export_action, function() Core.Page.exitAll(self) end)
    local top_group = VerticalGroup:new{ align = "left", header }
    if self.page == "text" or self.page == "spacing" or self.page == "bookmarks" or self.page == "dates" then
        table.insert(top_group, Core.Page.preview(self.list, math.floor(H * 0.26), self.page == "spacing", self.page == "bookmarks"))
    elseif self.page == "export" then
        table.insert(top_group, Core.Page.exportPreview(self.list, math.floor(H * 0.26)))
    end
    local footer
    if self.export_action then
        local n = #(list.filtered_notes or {})
        local bm = NotesListWidget.Export.allBookmarks(list.filtered_notes or {})
        local label = n == 0 and _("Nothing to export") or bm and (n == 1 and _("Export 1 bookmark") or string.format(_("Export %d bookmarks"), n))
            or (n == 1 and _("Export 1 annotation") or string.format(_("Export %d annotations"), n))
        local P2 = Screen:scaleBySize(24)
        local inner2 = W - P2 * 2
        local gap = Screen:scaleBySize(10)
        local bw1 = math.floor((inner2 - gap) / 3)
        footer = VerticalGroup:new{
            LineWidget:new{ dimen = Geom:new{ w = W, h = Size.line.thin }, background = COLORS.line },
            VerticalSpan:new{ width = Core.Page.FOOTER_TOP },
            HorizontalGroup:new{ HorizontalSpan:new{ width = P2 },
                Core.Page.button(_("Copy"), false, bw1, function() self:onClose(); list:copyList() end),
                HorizontalSpan:new{ width = gap },
                Core.Page.button(label, true, inner2 - gap - bw1, function() self:onClose(); list:exportList() end) },
            VerticalSpan:new{ width = Core.Page.FOOTER_BOTTOM },
        }
    end
    local avail = H - top_group:getSize().h - (footer and footer:getSize().h or 0)
    local body_widget = Core.Page.paged(self, W, avail, body)
    self[1] = FrameContainer:new{ width = W, height = H, padding = 0, margin = 0, bordersize = 0,
        background = BlitBuffer.COLOR_WHITE,
        VerticalGroup:new{ align = "left", top_group, body_widget, footer } }
end
-- SS lives in this `do` scope (it keeps the chunk's local count down), so it is handed out here.
SettingsScreens.SettingsScreen = SS
end

-- The two screens: "Filter & sort" and the Settings page. The list opens the second one through
-- NotesListWidget.SettingsScreen (set in the block above); it is returned here as well.
return {
    FilterScreen = FilterScreen,
    SettingsScreen = SettingsScreens.SettingsScreen,
}