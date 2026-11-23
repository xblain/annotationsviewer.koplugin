--[[--
Small widgets shared by annotationsviewer.koplugin.

These were `local`s at the top of main.lua. They are plain widgets that know nothing about
annotations, so they live here to keep the main chunk (and its 200-local limit) smaller.
]]

local InputContainer = require("ui/widget/container/inputcontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local BlitBuffer = require("ffi/blitbuffer")

-- The plugin's settings file. The module keeps its own handle (luasettings returns the same
-- table for the same path), which is only read here, for the anti-aliasing preference.
local G_reader_settings = require("luasettings"):open(
    require("datastorage"):getSettingsDir() .. "/annotationsviewer.lua")

local UI = {}

-- Wraps any widget so a tap on it calls `callback(ges)`. `hold_callback` is optional: with it
-- set, a long press on the same box calls that instead.
UI.TapBox = InputContainer:extend{ callback = nil }
function UI.TapBox:init()
    local size = self[1]:getSize()
    self.dimen = Geom:new{ x = 0, y = 0, w = size.w, h = size.h }
    self.ges_events = {
        TapBox = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } },
    }
    if self.hold_callback then
        self.ges_events.HoldBox = { GestureRange:new{ ges = "hold", range = function() return self.dimen end } }
    end
end
function UI.TapBox:onTapBox(_, ges)
    if self.callback then self.callback(ges) end
    return true
end
function UI.TapBox:onHoldBox(_, ges)
    if self.hold_callback then self.hold_callback(ges) end
    return true
end

-- Fully rounded chip filled with a colour. Draws its own fill row by row, because
-- FrameContainer's rounded fill leaves square colour corners outside the border on colour screens.
UI.Pill = InputContainer:extend{ width = 0, height = 0, fill = nil, border = 1, border_color = nil }
function UI.Pill:getSize() return Geom:new{ w = self.width, h = self.height } end
function UI.Pill:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }
    local w, h = self.width, self.height
    local r = math.floor(h / 2)
    if self.fill then
        local rgb = not BlitBuffer.isColor8(self.fill)
        for row = 0, h - 1 do
            local dy = math.abs(row + 0.5 - h / 2)
            local inset = math.ceil(r - math.sqrt(math.max(0, r * r - dy * dy)))
            if rgb then
                bb:paintRectRGB32(x + inset, y + row, w - inset * 2, 1, self.fill)
            else
                bb:paintRect(x + inset, y + row, w - inset * 2, 1, self.fill)
            end
        end
    end
    if self.border > 0 then
        bb:paintBorder(x, y, w, h, self.border, self.border_color or BlitBuffer.COLOR_BLACK, r,
            G_reader_settings:nilOrTrue("anti_alias_ui"))
    end
    if self[1] then
        local cs = self[1]:getSize()
        self[1]:paintTo(bb, x + math.floor((w - cs.w) / 2), y + math.floor((h - cs.h) / 2))
    end
end

local Size = require("ui/size")

UI.StrikeoutLineWidget = InputContainer:extend{ width = nil, height = nil, y_offset = nil }
function UI.StrikeoutLineWidget:init() self.dimen = Geom:new{ w = self.width, h = self.height } end
function UI.StrikeoutLineWidget:paintTo(bb, x, y)
    bb:paintRect(x, y + (self.y_offset or math.floor(self.height / 2)), self.width, Size.line.medium, BlitBuffer.COLOR_BLACK)
end
UI.UnderlineWidget = InputContainer:extend{ width = nil, height = nil }
function UI.UnderlineWidget:init() self.dimen = Geom:new{ w = self.width, h = self.height } end
function UI.UnderlineWidget:paintTo(bb, x, y)
    bb:paintRect(x, y + self.height - Size.line.medium, self.width, Size.line.medium, BlitBuffer.COLOR_BLACK)
end

return UI
