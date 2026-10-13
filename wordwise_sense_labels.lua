-- Explicitly approved sense-level hints. Never guess a synonym from lemma
-- spelling or from another WordNet synset. This module is optional: when no
-- matching reviewed label exists, Inline must fall back to dictionary text.
local Labels = {}
Labels.__index = Labels

local function trim(text)
    return (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

function Labels.load(path)
    local self = setmetatable({ by_sense = {}, accepted = 0 }, Labels)
    local fh = io.open(path, "rb")
    if not fh then return self end
    for line in fh:lines() do
        if line:sub(1, 1) ~= "#" and line ~= "" then
            local sense, word, pos, source, kind, label, status =
                line:match("^([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)$")
            sense, word, pos, source = trim(sense), trim(word), trim(pos), trim(source)
            label, kind, status = trim(label), trim(kind), trim(status)
            -- Strictly opt in only reviewed entries; preserve the selected
            -- WordNet sense and exact source in the match key.
            if status == "approved" and #sense >= 8 and word ~= ""
                    and source:match("^oewn:2024:") and (kind == "synonym" or kind == "paraphrase")
                    and label ~= "" and #label <= 70 and not label:find("[%c]")
                    and not self.by_sense[sense] then
                self.by_sense[sense] = {
                    word = word:lower(), pos = pos, source = source,
                    text = label, kind = kind,
                }
                self.accepted = self.accepted + 1
            end
        end
    end
    fh:close()
    return self
end

function Labels:get(entry)
    if type(entry) ~= "table" or not entry.sense_key then return nil end
    local candidate = self.by_sense[entry.sense_key]
    if not candidate then return nil end
    if candidate.word ~= (entry.word or ""):lower()
            or candidate.pos ~= (entry.pos or "")
            or candidate.source ~= (entry.source or "") then
        return nil
    end
    return candidate.text, candidate.kind
end

return Labels
