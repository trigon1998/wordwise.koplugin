--[[
Word Wise dictionary access.

The runtime schema supports multiple context-sensitive hints per word:

  entries(
      id INTEGER PRIMARY KEY,
      word TEXT NOT NULL COLLATE NOCASE,
      short_def TEXT NOT NULL,
      full_def TEXT,
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

-- Open English WordNet contains entries for surnames, government departments,
-- religious titles, and other named/specialized senses. Older generated DBs
-- have no explicit sense rank and may place those before the everyday meaning
-- simply because their lexical entry was enumerated first.
local function legacy_sense_penalty(gloss)
    local text = (gloss or ""):lower()
    if text:match("^united states ")
            or text:match("^[%a%-]+ statesman ")
            or text:match("^english [%a%-]+ who ")
            or text:match("%(%d%d%d%d%-%d%d%d%d%)")
            or text:match("^the federal department ")
            or text:match("^the sacred writings of ")
            or text:match("^a river in ")
            or text:match("^a city in ")
            or text:match("^a town in ")
            or text:match("^the capital of ")
            or text:find("term of address for priests", 1, true)
            or text:find("theologians in the period", 1, true)
            or text:find("first person in the trinity", 1, true) then
        return 1
    end
    return 0
end

local NO_DEINFLECT = {
    morning = true, evening = true, passing = true,
}

local IRREGULAR = {
    does = "do", goes = "go", has = "have", children = "child", men = "man",
    women = "woman", people = "person", mice = "mouse", geese = "goose",
    teeth = "tooth", feet = "foot",
}

local function candidates(w)
    if NO_DEINFLECT[w] then return { w } end
    local out = { w }
    local seen = { [w] = true }
    local n = #w
    local function add(s, min_length)
        if s and #s >= (min_length or 3) and not seen[s] then
            seen[s] = true
            out[#out + 1] = s
        end
    end
    add(IRREGULAR[w], 2)
    if n >= 5 and w:sub(-3) == "ies" then add(w:sub(1, n - 3) .. "y") end
    -- Try the ordinary trailing-s form first: rates -> rate, notes -> note,
    -- uses -> use. Only then try -es, which handles boxes/classes/wishes.
    if n >= 4 and w:sub(-1) == "s" then add(w:sub(1, n - 1)) end
    if n >= 5 and w:sub(-2) == "es" then add(w:sub(1, n - 2)) end
    if n >= 5 and w:sub(-2) == "ly" then add(w:sub(1, n - 2)) end
    if n >= 5 and w:sub(-2) == "ed" then
        if w:sub(n - 2, n - 2) == w:sub(n - 3, n - 3) then add(w:sub(1, n - 3)) end
        add(w:sub(1, n - 1))
        add(w:sub(1, n - 2))
    end
    if n >= 6 and w:sub(-3) == "ing" then
        if w:sub(n - 3, n - 3) == w:sub(n - 4, n - 4) then add(w:sub(1, n - 4)) end
        -- Restored-e forms must precede the bare stem: riding -> ride rather
        -- than rid, hoping -> hope rather than hop.
        add(w:sub(1, n - 3) .. "e")
        add(w:sub(1, n - 3))
    end
    return out
end

local WordWiseDB = {}
WordWiseDB.__index = WordWiseDB

-- Page turns can expose thousands of unique surface forms over a long session.
-- Keep the fast in-memory lookup cache bounded; the SQLite database remains the
-- source of truth. FIFO is intentional here: it avoids touching table metadata
-- on every cache hit while still placing a hard ceiling on retained results.
local CACHE_LIMIT = 1024

function WordWiseDB.open(path)
    local ok, conn = pcall(SQ3.open, path, "ro")
    if not ok or not conn then
        logger.warn("WordWiseDB: cannot open", path, tostring(conn))
        return nil
    end

    local columns = {}
    local schema_stmt
    local ok_schema = pcall(function()
        schema_stmt = conn:prepare("PRAGMA table_info(entries);")
        for row in schema_stmt:rows() do
            columns[row[2]] = true
        end
        schema_stmt:close()
        schema_stmt = nil
    end)
    if schema_stmt then pcall(function() schema_stmt:close() end) end
    if not ok_schema or not columns.word or not columns.short_def then
        logger.warn("WordWiseDB: unsupported entries schema", path)
        pcall(function() conn:close() end)
        return nil
    end

    local self = setmetatable({
        conn = conn,
        cache = {},
        cache_order = {},
        cache_head = 1,
        cache_count = 0,
        legacy = not columns.cefr_level,
    }, WordWiseDB)
    self.has_full_def = columns.full_def == true
    self.has_sense_rank = columns.sense_rank == true
    if columns.cefr_level then
        local full_def_column = self.has_full_def and ", full_def" or ""
        local sense_rank_column = self.has_sense_rank and ", sense_rank" or ""
        self.query_sql = "SELECT rowid, word, short_def, cefr_level, pos, sense_key, source"
            .. full_def_column
            .. sense_rank_column
            .. " FROM entries WHERE word = ?1 COLLATE NOCASE "
            .. "ORDER BY CASE WHEN source = 'open_glosses.tsv' THEN 0 ELSE 1 END"
            .. (self.has_sense_rank and ", sense_rank" or "")
            .. ", rowid;"
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
                    local full_gloss = self.has_full_def and shorten(row[8]) or gloss
                    local rank_index = self.has_full_def and 9 or 8
                    result[#result + 1] = {
                        id = tonumber(row[1]),
                        word = row[2] or key,
                        gloss = gloss,
                        full_gloss = full_gloss or gloss,
                        cefr_level = level,
                        cefr_rank = CEFR_RANK[level],
                        pos = pos,
                        sense_key = skey,
                        source = source,
                        sense_rank = self.has_sense_rank and tonumber(row[rank_index]) or nil,
                        _legacy_order = #result + 1,
                    }
                end
            end
        end
        self.stmt:clearbind():reset()
    end)
    if not ok then logger.warn("WordWiseDB: lookup failed for", key, tostring(err)) end
    if not self.has_sense_rank and #result > 1 then
        table.sort(result, function(a, b)
            local ap = a.source == "open_glosses.tsv" and -1
                or legacy_sense_penalty(a.full_gloss)
            local bp = b.source == "open_glosses.tsv" and -1
                or legacy_sense_penalty(b.full_gloss)
            if ap ~= bp then return ap < bp end
            return a._legacy_order < b._legacy_order
        end)
    end
    for _, entry in ipairs(result) do entry._legacy_order = nil end
    return result
end

-- Return every usable sense for a surface word, or nil.
function WordWiseDB:_cacheInsert(surface, value)
    self.cache[surface] = value
    self.cache_order[#self.cache_order + 1] = surface
    self.cache_count = self.cache_count + 1
    while self.cache_count > CACHE_LIMIT do
        local old = self.cache_order[self.cache_head]
        -- Leave the consumed slot intact until periodic compaction; holes make
        -- Lua's length operator undefined for array-like tables.
        self.cache_head = self.cache_head + 1
        if old and self.cache[old] ~= nil then
            self.cache[old] = nil
            self.cache_count = self.cache_count - 1
        end
    end
    -- Compact the queue occasionally so eviction metadata itself cannot grow.
    if self.cache_head > CACHE_LIMIT and self.cache_head > (#self.cache_order / 2) then
        local compacted = {}
        for i = self.cache_head, #self.cache_order do
            compacted[#compacted + 1] = self.cache_order[i]
        end
        self.cache_order = compacted
        self.cache_head = 1
    end
end

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
    self:_cacheInsert(surface, #result > 0 and result or false)
    return #result > 0 and result or nil
end

function WordWiseDB:lookup(word)
    local rows = self:lookupAll(word)
    return rows and rows[1] or nil
end

-- Exposed for lightweight regression tests and for future callers that need to
-- preview the same de-inflection order without opening SQLite.
function WordWiseDB.candidates(word)
    if not word then return {} end
    return candidates(word:lower())
end

function WordWiseDB:close()
    if self.stmt then pcall(function() self.stmt:close() end) end
    if self.conn then pcall(function() self.conn:close() end) end
    self.stmt, self.conn = nil, nil
    self.cache, self.cache_order = {}, {}
    self.cache_head, self.cache_count = 1, 0
end

return WordWiseDB
