-- Word Wise data layer.
--
-- The plugin is dictionary-agnostic: it reads a single canonical SQLite schema
-- and does not care how the database was produced. Ship nothing; the user
-- supplies a database at <data>/wordwise/ (see build_wordwise_db.py, which can
-- derive one from a Kindle WordWise.kll dictionary for personal use, or any
-- other source rebuilt into the same shape).
--
-- Canonical schema:
--   entries(word TEXT PRIMARY KEY COLLATE NOCASE,
--           short_def TEXT NOT NULL,
--           difficulty INTEGER NOT NULL,   -- 1 rarest .. 5 most common
--           pos TEXT)
--
-- A word is glossed when its difficulty <= the user's hint level, so a low
-- hint level shows only rare/hard words and a high one also shows common ones.
local SQ3 = require("lua-ljsqlite3/init")
local logger = require("logger")

local LOOKUP_SQL = "SELECT short_def, difficulty FROM entries WHERE word = ?1 LIMIT 1;"

local WordWiseDB = {}
WordWiseDB.__index = WordWiseDB

-- Glosses are shown in full, untrimmed -- just tidy surrounding whitespace.
local function shorten(def)
    if not def or def == "" then return nil end
    def = def:gsub("^%s+", ""):gsub("%s+$", "")
    if def == "" then return nil end
    return def
end

-- Common nouns/adjectives that happen to end in a stripped suffix but are NOT
-- inflected forms of something else -- de-inflecting them risks landing on an
-- unrelated real dictionary word (e.g. morning -> morn, an archaic word that
-- happens to be defined as "morning", making morning look like it defines
-- itself; passing -> passe, an unrelated word meaning "no longer fashionable").
-- Over-generation is normally harmless since candidates must resolve to a real
-- entry, but these specific collisions are real entries, so it isn't.
local NO_DEINFLECT = {
    morning = true, evening = true, passing = true,
}

-- The dictionary is keyed by lemma (base form). Book text carries inflected
-- forms, so on a miss we try a few cheap English de-inflections. Order matters:
-- more specific rules first. Candidates are only accepted if they resolve to a
-- real entry, so over-generation is normally harmless (see NO_DEINFLECT above
-- for the exceptions).
local function candidates(w)
    if NO_DEINFLECT[w] then return { w } end
    local out = { w }
    local n = #w
    local function add(s) if s and #s >= 3 then out[#out + 1] = s end end
    if n >= 5 and w:sub(-3) == "ies" then
        add(w:sub(1, n - 3) .. "y")            -- studies -> study
    end
    if n >= 5 and w:sub(-2) == "es" then
        add(w:sub(1, n - 2))                   -- boxes -> box
    end
    if n >= 4 and w:sub(-1) == "s" then
        add(w:sub(1, n - 1))                   -- traditions -> tradition
    end
    if n >= 5 and w:sub(-2) == "ly" then
        add(w:sub(1, n - 2))                   -- splendidly -> splendid
    end
    if n >= 5 and w:sub(-2) == "ed" then
        add(w:sub(1, n - 1))                   -- glimpsed -> glimpse
        add(w:sub(1, n - 2))                   -- walked -> walk
        if w:sub(n - 2, n - 2) == w:sub(n - 3, n - 3) then
            add(w:sub(1, n - 3))               -- stopped -> stop
        end
    end
    if n >= 6 and w:sub(-3) == "ing" then
        add(w:sub(1, n - 3))                   -- hurrying -> hurry, going -> go
        add(w:sub(1, n - 3) .. "e")            -- making -> make
        if w:sub(n - 3, n - 3) == w:sub(n - 4, n - 4) then
            add(w:sub(1, n - 4))               -- running -> run
        end
    end
    return out
end

function WordWiseDB.open(path)
    local ok, conn = pcall(SQ3.open, path)
    if not ok or not conn then
        logger.warn("WordWiseDB: cannot open", path, tostring(conn))
        return nil
    end
    local self = setmetatable({ conn = conn, cache = {} }, WordWiseDB)
    local ok2, stmt = pcall(function() return conn:prepare(LOOKUP_SQL) end)
    if not ok2 or not stmt then
        logger.warn("WordWiseDB: prepare failed", tostring(stmt))
        pcall(function() conn:close() end)
        return nil
    end
    self.stmt = stmt
    return self
end

-- One raw lookup of an exact key. Returns {gloss, difficulty} or nil.
function WordWiseDB:_query(key)
    local result = nil
    local ok, err = pcall(function()
        self.stmt:reset():clearbind()
        self.stmt:bind(key)
        local row = self.stmt:step()
        if row then
            local gloss = shorten(row[1])
            local difficulty = tonumber(row[2])
            if gloss and difficulty then
                -- key is the lemma that actually matched (a de-inflected
                -- candidate), so callers can suppress every surface form of it.
                result = { gloss = gloss, difficulty = difficulty, key = key }
            end
        end
        self.stmt:clearbind():reset()
    end)
    if not ok then
        logger.warn("WordWiseDB: lookup failed for", key, tostring(err))
    end
    return result
end

-- Return { gloss = <string>, difficulty = <int> } or nil. Cached per surface
-- word (including negative results). Tries the word, then de-inflected forms.
function WordWiseDB:lookup(word)
    local key = word:lower()
    local cached = self.cache[key]
    if cached ~= nil then
        return cached or nil
    end
    local result = nil
    for _, cand in ipairs(candidates(key)) do
        result = self:_query(cand)
        if result then break end
    end
    self.cache[key] = result or false
    return result
end

function WordWiseDB:close()
    if self.stmt then pcall(function() self.stmt:close() end) end
    if self.conn then pcall(function() self.conn:close() end) end
    self.stmt, self.conn = nil, nil
end

return WordWiseDB
