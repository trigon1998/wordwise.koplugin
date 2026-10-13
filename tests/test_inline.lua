-- Headless inline rendering test: short labels, tap targets, and collision.
local root = (... and ... ~= "") and ... or "."
package.path = root .. "/?.lua;" .. package.path

local text_painted = {}
local pixels = 0
package.preload["ffi/blitbuffer"] = function()
    return { COLOR_BLACK = 0 }
end
package.preload["ui/font"] = function()
    return { getFace = function(_, _, size)
        return { point_size = size, ftsize = {
            getHeightAndAscender = function() return 12, 9 end
        } }
    end }
end
package.preload["ui/rendertext"] = function()
    return {
        sizeUtf8Text = function(_, _, _, text)
            return { x = #text * 5, y_top = 9, y_bottom = 3 }
        end,
        truncateTextByWidth = function(_, text, _, width)
            return text:sub(1, math.max(1, math.floor(width / 5) - 1)) .. "…"
        end,
        renderUtf8Text = function(_, _, _, _, text)
            text_painted[#text_painted + 1] = text
        end,
    }
end

local Microgloss = require("wordwise_microgloss")
assert(Microgloss.format("an extended explanation with unnecessary extra detail", "micro")
    == "an extended explanation with…")
assert(Microgloss.format("very confused", "micro") == "very confused")
assert(Microgloss.format("confused and unable to make sense of a thing", "short")
    == "confused and unable to make sense…")
assert(Microgloss.format("a person who plays an instrument", "micro")
    == "a person who plays…")
assert(Microgloss.format(nil, "micro") == "")
assert(Microgloss.isValidLength("micro"))
assert(not Microgloss.isValidLength("missing"))

local Inline = require("wordwise_inline")
local bb = {
    getWidth = function() return 600 end,
    getHeight = function() return 800 end,
    setPixel = function() pixels = pixels + 1 end,
}
local font = { ftsize = { getHeightAndAscender = function() return 12, 9 end } }
local hints = {
    {
        box = { x = 60, y = 170, w = 100, h = 31 },
        entry = { gloss = "done quickly without much care or interest", cefr_rank = 5 },
        cefr_rank = 5,
    },
    {
        box = { x = 370, y = 170, w = 120, h = 31 },
        entry = { gloss = "very confused and unable to decide what to do", cefr_rank = 3 },
        cefr_rank = 3,
    },
}
Inline.paint(bb, 0, 0, hints,
    { face = font, length = "micro", line_spacing = 170 })
assert(#text_painted == 2)
assert(hints[1].inline_visible == true and hints[1].hit_box)
assert(hints[2].inline_visible == true and hints[2].hit_box)
assert(pixels > 0)
assert(#text_painted[1] < 40, text_painted[1])
assert(#text_painted[2] < 40, text_painted[2])
-- The same page can repaint safely without reallocating full definition strings.
Inline.paint(bb, 0, 0, hints,
    { face = font, length = "micro", line_spacing = 170 })
assert(#text_painted == 4)
-- Changing length must update the display cache.
Inline.paint(bb, 0, 0, hints,
    { face = font, length = "short", line_spacing = 170 })
assert(#text_painted == 6)
assert(text_painted[5] ~= text_painted[3])
print("microgloss_inline_paint_tap_targets_and_cache_ok")
