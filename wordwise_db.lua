--[[
Word Wise dictionary access.

The runtime schema supports multiple context-sensitive hints per word:

  entries(
      id INTEGER PRIMARY KEY,
      word TEXT NOT NULL COLLATE NOCASE,
      short_def TEXT NOT NULL,
      cefr_level TEXT NOT NULL,
      pos TEXT,
      sense_key TEXT NOT NULL,
      source TEXT
  )

A compatibility path accepts the upstream difficulty column and maps its old
1..5 bands to approximate CEFR levels. New databases should use cefr_level.
--]]--

local SQ3 = require("lua-ljsqlite3/init")
local logger = require("logger")

local CEFR_RANK = { A1 = 1, A2 = 2, B1 = 3, B2 = 4, C1 = 5, C2 = 6 }
-- Bootstrap-only compatibility mapping: upstream 1 was rarest/hardest.
local LEGACY_DIFFICULTY = { [1] = "C2", [2] = "C1", [3] = "B2", [4] = "B1", [5] = "A2" }

local function normalize_cefr(value)
    if value == nil then return nil end
    local level = tostring(value):upper():gsub("%s+", "")
    if CEFR_RANK[level] then return level end
    return nil
end

local function sense_key(word, gloss, pos)
    return (word or ""):lower() .. "\31" .. (pos or "") .. "\31" .. (gloss or "")
end

local function shorten(def)
    if not def or def == "" then return nil end
    def = def:gsub("^%s+", ""):gsub("%s+$", "")
    if def == "" then return nil end
    return def
end

local NO_DEINFLECT = {
    morning = true, evening = true, passing = true,
}

local function candidates(w)
    if NO_DEINFLECT[w] then return { w } end
    local out = { w }
    local n = #w
    local function add(s) if s and #s >= 3 then out[#out + 1] = s end end
    if n >= 5 and w:sub(-3) == "ies" then add(w:sub(1, n - 3) .. "y") end
    if n >= 5 and w:sub(-2) == "es" then add(w:sub(1, n - 2)) end
    if n >= 4 and w:sub(-1) == "s" then add(w:sub(1, n - 1)) end
    if n >= 5 and w:sub(-2) == "ly" then add(w:sub(1, n - 2)) end
    if n >= 5 and w:sub(-2) == "ed" then
        add(w:sub(1, n - 1))
        add(w:sub(1, n - 2))
        if w:sub(n - 2, n - 2) == w:sub(n - 3, n - 3) then add(w:sub(1, n - 3)) end
    end
    if n >= 6 and w:sub(-3) == "ing" then
        add(w:sub(1, n - 3))
        add(w:sub(1, n - 3) .. "e")
        if w:sub(n - 3, n - 3) == w:sub(n - 4, n - 4) then add(w:sub(1, n - 4)) end
    end
    return out
end

local WordWiseDB = {}
WordWiseDB.__index = WordWiseDB

function WordWiseDB.open(path)
    local ok, conn = pcall(SQ3.open, path, "ro")
    if not ok or not conn then
        logger.warn("WordWiseDB: cannot open", path, tostring(conn))
        return nil
    end

    local columns = {}
    local ok_schema = pcall(function()
        for row in conn:prepare("PRAGMA table_info(entries);"):rows() do
            columns[row[2]] = true
        end
    end)
    if not ok_schema or not columns.word or not columns.short_def then
        logger.warn("WordWiseDB: unsupported entries schema", path)
        pcall(function() conn:close() end)
        return nil
    end

    local self = setmetatable({ conn = conn, cache = {}, legacy = not columns.cefr_level }, WordWiseDB)
    if columns.cefr_level then
        self.query_sql = "SELECT rowid, word, short_def, cefr_level, pos, sense_key, source FROM entries WHERE word = ?1 COLLATE NOCASE ORDER BY rowid;"
    elseif columns.difficulty then
        self.query_sql = "SELECT rowid, word, short_def, difficulty, pos FROM entries WHERE word = ?1 COLLATE NOCASE ORDER BY rowid;"
    else
        logger.warn("WordWiseDB: entries has neither cefr_level nor difficulty", path)
        pcall(function() conn:close() end)
        return nil
    end
    local ok_stmt, stmt = pcall(function() return conn:prepare(self.query_sql) end)
    if not ok_stmt or not stmt then
        logger.warn("WordWiseDB: prepare failed", tostring(stmt))
        pcall(function() conn:close() end)
        return nil
    end
    self.stmt = stmt
    return self
end

function WordWiseDB:_query(key)
    local result = {}
    local ok, err = pcall(function()
        self.stmt:reset():clearbind()
        self.stmt:bind(key)
        for row in self.stmt:rows() do
            local gloss = shorten(row[3])
            if gloss then
                local level
                local pos
                local skey
                local source
                if self.legacy then
                    level = LEGACY_DIFFICULTY[tonumber(row[4])] or "B1"
                    pos = row[5]
                    skey = sense_key(row[2] or key, gloss, pos)
                    source = "legacy-upstream-difficulty"
                else
                    level = normalize_cefr(row[4])
                    pos = row[5]
                    skey = row[6] or sense_key(row[2] or key, gloss, pos)
                    source = row[7]
                end
                if level then
                    result[#result + 1] = {
                        id = tonumber(row[1]),
                        word = row[2] or key,
                        gloss = gloss,
                        cefr_level = level,
                        cefr_rank = CEFR_RANK[level],
                        pos = pos,
                        sense_key = skey,
                        source = source,
                    }
                end
            end
        end
        self.stmt:clearbind():reset()
    end)
    if not ok then logger.warn("WordWiseDB: lookup failed for", key, tostring(err)) end
    return result
end

-- Return every usable sense for a surface word, or nil.
function WordWiseDB:lookupAll(word)
    if not word or word == "" then return nil end
    local surface = word:lower()
    local cached = self.cache[surface]
    if cached ~= nil then return cached or nil end
    local result = {}
    for _, cand in ipairs(candidates(surface)) do
        local rows = self:_query(cand)
        for _, entry in ipairs(rows or {}) do
            result[#result + 1] = entry
        end
        if #result > 0 then break end
    end
    self.cache[surface] = #result > 0 and result or false
    return #result > 0 and result or nil
end

function WordWiseDB:lookup(word)
    local rows = self:lookupAll(word)
    return rows and rows[1] or nil
end

function WordWiseDB:close()
    if self.stmt then pcall(function() self.stmt:close() end) end
    if self.conn then pcall(function() self.conn:close() end) end
    self.stmt, self.conn = nil, nil
end

return WordWiseDB
