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
        sizeUtf8Text = function(_, _, _, _, text)
            return { x = #text * 5, y_top = 9, y_bottom = 3 }
        end,
        truncateTextByWidth = function(_, text, _, width)
            return text:sub(1, math.max(1, math.floor(width / 5) - 1)) .. "…"
        end,
        renderUtf8Text = function(_, _, _, _, _, text)
            text_painted[#text_painted + 1] = text
        end,
    }
end

local Microgloss = require("wordwise_microgloss")
assert(Microgloss.format("an extended explanation with unnecessary extra detail", "micro")
    == "extended explanation…")
assert(Microgloss.format("very confused", "micro") == "very confused")
assert(Microgloss.format("confused and unable to make sense of a thing", "short")
    == "confused and unable to make sense…")
assert(Microgloss.format("a person who plays an instrument", "micro")
    == "person who plays…")
assert(Microgloss.format(nil, "micro") == "")
assert(Microgloss.isValidLength("micro"))
assert(not Microgloss.isValidLength("missing"))
assert(Microgloss.format("a dishonest or fraudulent person with bad intentions", "micro")
    == "dishonest or fraudulent person…")
assert(Microgloss.format("a dishonest or fraudulent person with bad intentions", "short")
    == "dishonest or fraudulent person with bad…")

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
local candidates, rendered = Inline.paint(bb, 0, 0, hints,
    { face = font, length = "micro", line_spacing = 170 })
assert(#text_painted == 2, "painted=" .. tostring(#text_painted) .. " candidates=" .. tostring(candidates) .. " rendered=" .. tostring(rendered) .. " first=" .. tostring(hints[1].inline_visible) .. " second=" .. tostring(hints[2].inline_visible))
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
-- An overcrowded row must safely drop overlapping labels, never draw one
-- on top of another. The caller then underlines their source words.
local crowded = {}
for i = 1, 5 do
    crowded[#crowded + 1] = {
        box = { x = 30 + (i - 1) * 20, y = 340, w = 35, h = 32 },
        entry = { gloss = "a dishonest or fraudulent person", cefr_rank = 5 },
        cefr_rank = 5,
    }
end
local candidates, shown = Inline.paint(bb, 0, 0, crowded,
    { face = font, length = "short", line_spacing = 170 })
assert(candidates == 5 and shown < candidates, "expected collision fallback")
for _, hint in ipairs(crowded) do
    assert(hint.inline_visible or hint.hit_box == nil)
end
print("microgloss_inline_paint_tap_targets_and_cache_ok")
