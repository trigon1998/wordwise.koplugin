-- KOReader inline gloss painter, adapted from the proven Word Wise v0.2.13
-- renderer. Boxes from crengine are already screen-relative: do not add the\n-- ReaderView paint origin a second time. Keeps top-edge fallback but replaces
-- long dictionary descriptions with extractive microgloss labels.
local Blitbuffer = require("ffi/blitbuffer")
local Font = require("ui/font")
local RenderText = require("ui/rendertext")
local Microgloss = require("wordwise_microgloss")

local Inline = {}
local CARET_DEPTH = 5
local GLOSS_HGAP = 7
local MAX_HINT_WIDTH = 138

local function metrics(face)
    local ok, height, asc = pcall(function()
        return face.ftsize:getHeightAndAscender()
    end)
    if ok and height and asc then
        return math.floor(asc + .5), math.max(0, math.ceil(height - asc))
    end
    local test = RenderText:sizeUtf8Text(0, 10000, face, "Agjpqy", true, false)
    return test.y_top, math.max(0, test.y_bottom)
end

local function collision(x0, x1, intervals)
    for _, iv in ipairs(intervals) do
        if x0 < iv[2] + GLOSS_HGAP and x1 + GLOSS_HGAP > iv[1] then
            return true
        end
    end
    return false
end

local function slot(item, existing, left, right)
    local w = item.x1 - item.x0
    local choices = { item.x0, left, right - w }
    for _, iv in ipairs(existing) do
        choices[#choices + 1] = iv[2] + GLOSS_HGAP
        choices[#choices + 1] = iv[1] - GLOSS_HGAP - w
    end
    local best, dist
    for _, candidate in ipairs(choices) do
        local x0 = math.max(left, math.min(candidate, right - w))
        local x1 = x0 + w
        if x0 >= left and x1 <= right and not collision(x0, x1, existing) then
            local new_dist = math.abs(x0 - item.x0)
            if not dist or new_dist < dist then
                best, dist = x0, new_dist
            end
        end
    end
    return best
end

local function caret(bb, cx, y, up, color, ox, oy)
    for i = 0, CARET_DEPTH do
        local py = up and (y + CARET_DEPTH - i) or (y + i)
        bb:setPixel(ox + cx - CARET_DEPTH + i, oy + py, color)
        bb:setPixel(ox + cx + CARET_DEPTH - i, oy + py, color)
    end
end

function Inline.paint(bb, x, y, hints, options)
    if not hints or #hints == 0 then return end
    x, y = x or 0, y or 0
    options = options or {}
    local face = options.face or Font:getFace("infofont", options.font_size or 11)
    local ascent, descent = metrics(face)
    local width, height = bb:getWidth(), bb:getHeight()
    local left, right = 4, width - 4
    local max_width = math.min(MAX_HINT_WIDTH, math.floor((right - left) * .37))
    local spacing = math.max(100, tonumber(options.line_spacing) or 100)
    local mode = options.length or "micro"
    local items = {}

    for _, hint in ipairs(hints) do
        hint.hit_box, hint.inline_visible = nil, false
        local b = hint.box
        if b and b.w > 0 and b.h > 0 then
            local text = Microgloss.format(hint.entry and hint.entry.gloss or hint.text, mode)
            if text ~= "" and max_width > 0 then
                local cache = hint._micro_cache
                if not cache or cache.face ~= face or cache.source ~= text
                        or cache.max_width ~= max_width or cache.length ~= mode then
                    local text_width = RenderText:sizeUtf8Text(
                        0, width, face, text, true, false).x
                    if text_width > max_width then
                        text = RenderText:truncateTextByWidth(
                            text, face, max_width, true, false)
                        text_width = RenderText:sizeUtf8Text(
                            0, width, face, text, true, false).x
                    end
                    cache = { face = face, source = Microgloss.format(
                        hint.entry and hint.entry.gloss or hint.text, mode),
                        text = text, width = text_width,
                        max_width = max_width, length = mode }
                    hint._micro_cache = cache
                end
                if cache and cache.width > 0 and cache.width <= right - left then
                    local text_width = cache.width
                    local preferred = math.floor(b.x + (b.w - text_width) / 2 + .5)
                    preferred = math.max(left, math.min(right - text_width, preferred))
                    local leading = b.h * (1 - 100 / spacing)
                    local word_top = b.y + math.floor(leading / 2)
                    local word_bottom = b.y + b.h - math.floor(leading / 2)
                    local above_baseline = math.floor(math.min(
                        b.y + (ascent - descent) / 2, word_top - 2 - descent) + .5)
                    local above_top = above_baseline - ascent
                    local above_marker = math.min(above_baseline + descent + 1,
                        word_top - CARET_DEPTH - 1)
                    local below = above_top < 4
                    local marker = below and (word_bottom + 1) or above_marker
                    local baseline = below
                        and math.floor(marker + CARET_DEPTH + 1 + ascent + .5)
                        or above_baseline
                    local ttop, tbottom = baseline - ascent, baseline + descent
                    local band_h = math.max(12, b.h * .5)
                    local band = math.floor((b.y + (below and b.h or 0)) / band_h + .5)
                    items[#items + 1] = {
                        hint = hint, text = cache.text, width = text_width,
                        x0 = preferred, x1 = preferred + text_width,
                        baseline = baseline, marker = marker,
                        ttop = ttop, tbottom = tbottom, below = below,
                        band = band, rank = hint.cefr_rank or 0,
                        word_cx = math.floor(b.x + b.w / 2 + .5),
                    }
                end
            end
        end
    end
    table.sort(items, function(a, b)
        if a.band ~= b.band then return a.band < b.band end
        if a.rank ~= b.rank then return a.rank > b.rank end
        return a.x0 < b.x0
    end)

    local placed = {}
    local rendered_count = 0
    local color = Blitbuffer.COLOR_BLACK
    for _, item in ipairs(items) do
        if item.ttop >= 4 and item.tbottom < height - 4 then
            local intervals = placed[item.band]
            if not intervals then intervals = {}; placed[item.band] = intervals end
            local xx = slot(item, intervals, left, right)
            if xx then
                intervals[#intervals + 1] = { xx, xx + item.width }
                rendered_count = rendered_count + 1
                item.hint.inline_visible = true
                item.hint.hit_box = {
                    x = xx - 3, y = item.ttop - 2,
                    w = item.width + 6, h = item.tbottom - item.ttop + 4,
                }
                RenderText:renderUtf8Text(bb, xx, item.baseline,
                    face, item.text, true, false, color)
                local cx = math.max(xx + CARET_DEPTH,
                    math.min(xx + item.width - CARET_DEPTH, item.word_cx))
                if item.width >= CARET_DEPTH * 2 then
                    caret(bb, cx, item.marker, item.below, color, 0, 0)
                end
            end
        end
    end
    return #items, rendered_count
end

return Inline
