-- Tiny, offline, extractive labels for above-word inline hints.
-- Always derive from the selected WordNet sense's short definition. Never
-- invent a synonym or pick a different sense to make a label shorter.
local Microgloss = {}

local limits = {
    micro = { words = 4, chars = 34 },
    short = { words = 6, chars = 50 },
}

function Microgloss.lengths()
    return { "micro", "short" }
end

function Microgloss.isValidLength(mode)
    return limits[mode] ~= nil
end

function Microgloss.format(text, mode)
    if type(text) ~= "string" then return "" end
    mode = limits[mode] and mode or "micro"
    local max_words, max_chars = limits[mode].words, limits[mode].chars
    local clean = text:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    clean = clean:gsub("^%([^)]-%)%s*", "")
    -- Articles add almost no meaning to a short above-word label. Omitting one
    -- frees a word slot for the informative part of the same WordNet sense:
    -- "a dishonest or fraudulent person" -> "dishonest or fraudulent person".
    clean = clean:gsub("^[Aa]n?%s+", ""):gsub("^[Tt]he%s+", "")
    if clean == "" then return "" end

    -- Prefer an intact short clause over splitting a definition at a comma.
    -- This is deliberately extractive; the full sense is always a tap away.
    local result, count, consumed = {}, 0, 0
    for token in clean:gmatch("%S+") do
        local value = table.concat(result, " ")
        local candidate = value == "" and token or (value .. " " .. token)
        if count >= max_words or (count > 0 and #candidate > max_chars) then break end
        count = count + 1
        result[count] = token
        consumed = consumed + #token + (count > 1 and 1 or 0)
    end
    local truncated = consumed < #clean
    local trailing = {
        ["and"] = true, ["or"] = true, ["the"] = true, ["a"] = true,
        ["an"] = true, ["of"] = true, ["to"] = true, ["for"] = true,
        ["with"] = true, ["without"] = true, ["by"] = true, ["in"] = true,
        ["on"] = true, ["at"] = true, ["who"] = true, ["which"] = true,
        ["that"] = true, ["is"] = true, ["are"] = true,
    }
    if truncated then
        -- Don't leave a dangling preposition at the end of a hint.
        while #result > 2 and trailing[(result[#result] or ""):lower():gsub("[^%a]", "")] do
            table.remove(result)
        end
    end
    local out = table.concat(result, " "):gsub("[%s,;:%.!%?%-]+$", "")
    if out == "" then return "" end
    return out .. (truncated and "…" or "")
end

return Microgloss
