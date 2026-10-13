-- Small, non-modal definition bubble painted directly in the ReaderView overlay.
-- Tapping the bubble opens the existing multi-sense Word Wise action dialog.
local Blitbuffer = require("ffi/blitbuffer")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Screen = require("device").screen
local TextBoxWidget = require("ui/widget/textboxwidget")

local Bubble = {}
Bubble.__index = Bubble

local function scaled(value)
    return math.max(1, math.floor(Screen:scaleBySize(value)))
end

function Bubble.new()
    return setmetatable({}, Bubble)
end

function Bubble:close()
    local frame = self.frame
    self.frame, self.hint, self.box, self.pointer = nil, nil, nil, nil
    if frame then frame:free() end
    return frame ~= nil
end

function Bubble:contains(pos)
    local box = self.box
    return pos and box and pos.x >= box.x and pos.x < box.x + box.w
        and pos.y >= box.y and pos.y < box.y + box.h
end

function Bubble:show(hint, font_size, tap_text)
    self:close()
    if not hint or not hint.box then return end
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local edge, tail, gap = scaled(8), scaled(7), scaled(7)
    local padding, border = scaled(9), scaled(1)
    local requested_width = math.min(math.floor(sw * 0.80), sw - edge * 2)
    local text_width = math.max(1, requested_width - 2 * (padding + border))
    local face = Font:getFace("infofont",
        math.max(16, math.min(tonumber(font_size) or 20, 28)))
    local word = tostring(hint.word or ""):match("^%s*(.-)%s*$")
    local gloss = hint.entry and (hint.entry.gloss or hint.entry.full_gloss) or hint.text or ""
    local text = word .. "\n" .. gloss .. "\n" .. (tap_text or "Tap for all meanings")
    local frame = FrameContainer:new {
        padding = padding, margin = 0, bordersize = border, radius = scaled(6),
        background = Blitbuffer.COLOR_WHITE, color = Blitbuffer.COLOR_BLACK,
        TextBoxWidget:new {
            text = text, face = face, width = text_width, alignment = "left",
        },
    }
    local size = frame:getSize()
    local anchor = hint.box
    local center = anchor.x + anchor.w / 2
    local x = math.max(edge, math.min(sw - edge - size.w,
        math.floor(center - size.w / 2)))
    local below = anchor.y + anchor.h + gap + tail + size.h <= sh - edge
    local y = below and anchor.y + anchor.h + gap + tail
        or anchor.y - gap - tail - size.h
    local min_y = edge + (below and tail or 0)
    local max_y = sh - edge - size.h - (below and 0 or tail)
    y = math.max(min_y, math.min(math.max(min_y, max_y), y))
    local cx = math.floor(math.max(x + scaled(12),
        math.min(x + size.w - scaled(12), center)))
    self.hint, self.frame = hint, frame
    self.box = { x = x, y = y, w = size.w, h = size.h }
    self.pointer = { x = cx, tail = tail, below = below, border = border }
end

function Bubble:paint(bb, x, y)
    if not self.frame then return end
    x, y = x or 0, y or 0
    local box, pointer = self.box, self.pointer
    self.frame:paintTo(bb, x + box.x, y + box.y)
    local tail_y = pointer.below and (box.y - pointer.tail + pointer.border)
        or (box.y + box.h - pointer.border)
    for row = 0, pointer.tail - 1 do
        local half = pointer.below and row or (pointer.tail - row - 1)
        bb:paintRect(x + pointer.x - half, y + tail_y + row,
            2 * half + 1, 1, Blitbuffer.COLOR_BLACK)
        local inner = half - pointer.border
        if inner >= 0 then
            bb:paintRect(x + pointer.x - inner, y + tail_y + row,
                2 * inner + 1, 1, Blitbuffer.COLOR_WHITE)
        end
    end
end

return Bubble
