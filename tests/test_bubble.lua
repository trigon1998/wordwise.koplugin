-- Headless geometry and lifecycle checks for the non-modal definition bubble.
local root = (... and ... ~= "") and ... or "."
package.path = root .. "/?.lua;" .. package.path

local freed, frames_painted, pixels = 0, 0, 0

package.preload["ffi/blitbuffer"] = function()
    return { COLOR_WHITE = 0, COLOR_BLACK = 1 }
end
package.preload["device"] = function()
    return { screen = {
        getWidth = function() return 600 end,
        getHeight = function() return 800 end,
        scaleBySize = function(_, value) return value end,
    } }
end
package.preload["ui/font"] = function()
    return { getFace = function(_, _, size) return { size = size } end }
end
package.preload["ui/widget/textboxwidget"] = function()
    return { new = function(_, options)
        assert(options.width > 0)
        assert(options.text:find("perfunctory", 1, true) or options.text:find("bewildered", 1, true))
        return options
    end }
end
package.preload["ui/widget/container/framecontainer"] = function()
    return { new = function()
        return {
            getSize = function() return { w = 240, h = 80 } end,
            free = function() freed = freed + 1 end,
            paintTo = function(_, _, x, y)
                assert(x >= 0 and y >= 0)
                frames_painted = frames_painted + 1
            end,
        }
    end }
end

local Bubble = require("wordwise_bubble")
local bubble = Bubble.new()
local hint = {
    word = "perfunctory",
    entry = { gloss = "done without care" },
    box = { x = 110, y = 200, w = 90, h = 24 },
}
bubble:show(hint, 24, "Tap for meanings")
assert(bubble.hint == hint)
assert(bubble.box.x >= 0)
assert(bubble.box.y >= 0)
assert(bubble.box.x + bubble.box.w <= 600)
assert(bubble.box.y + bubble.box.h <= 800)
assert(bubble:contains({ x = bubble.box.x + 2, y = bubble.box.y + 2 }))
assert(not bubble:contains({ x = 600, y = 800 }))

bubble:paint({ paintRect = function(_, x, y, w, h)
    assert(type(x) == "number" and type(y) == "number")
    assert(w > 0 and h > 0)
    pixels = pixels + 1
end }, 0, 0)
assert(frames_painted == 1 and pixels > 0)

bubble:show({
    word = "bewildered",
    entry = { gloss = "confused" },
    box = { x = 520, y = 750, w = 72, h = 25 },
}, 24, "Tap for meanings")
assert(freed == 1)
assert(bubble.box.x + bubble.box.w <= 600)
assert(bubble.box.y + bubble.box.h <= 800)
assert(bubble:close())
assert(freed == 2)
assert(not bubble:close())
assert(bubble.hint == nil and bubble.box == nil)
print("bubble_geometry_tap_and_cleanup_ok")
