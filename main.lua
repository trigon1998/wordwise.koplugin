--[[--
Word Wise: draw short definitions above difficult words as a per-page overlay
on the ORIGINAL book — no copy, no file rewrite.

How it works:
  * A view module registered with ReaderView paints gloss strings on top of the
    page. For the current page we walk the visible words, look each up in the
    dictionary, and remember a screen box + gloss for the difficult ones.
  * To leave room for the gloss above each line, we raise the document's line
    spacing uniformly (setInterlineSpacePercent). Every line gets the same
    height whether or not it carries a hint, and an interline change only
    re-renders (it never rebuilds the DOM, so no "reload document?" prompt).
  * Hints are recomputed on every page turn / re-render, so only the visible
    page is ever processed.

@module koplugin.wordwise
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local Event = require("ui/event")
local Font = require("ui/font")
local InfoMessage = require("ui/widget/infomessage")
local ButtonDialog = require("ui/widget/buttondialog")
local RenderText = require("ui/rendertext")
local SpinWidget = require("ui/widget/spinwidget")
local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local LuaSettings = require("luasettings")
local _ = require("gettext")
local T = require("ffi/util").template

local WordWiseDB = require("wordwise_db")
local WordWiseL10N = require("wordwise_l10n")

-- The plugin ships a built-in open dictionary (bundled beside this file), but a
-- user-supplied canonical-schema database dropped into WW_DIR overrides it. The
-- resolution order is WW_DIR/wordwise.db, first *.db in WW_DIR, then bundled.
local WW_DIR = DataStorage:getDataDir() .. "/wordwise"
local STATE_PATH = WW_DIR .. "/state.lua"
local KNOWN_WORDS_PATH = WW_DIR .. "/known_words.lua"
local MAX_INLINE_HINT_WIDTH = 240
-- ButtonDialog derives row height from content unless height is explicit. Keep
-- sense rows uniform so the popup remains scannable and scrolls on a regular grid.
local SENSE_ROW_HEIGHT = Screen:scaleBySize(52)

-- Directory this plugin was loaded from, used to find the bundled dictionary.
local PLUGIN_ROOT = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("[^/\\]+$", "")
local BUNDLED_DB = PLUGIN_ROOT .. "wordwise.db"

local CEFR_LEVELS = { "A1", "A2", "B1", "B2", "C1", "C2" }
local CEFR_RANK = { A1 = 1, A2 = 2, B1 = 3, B2 = 4, C1 = 5, C2 = 6 }
local DEFAULT_CEFR = "B1"
-- While hints are on we raise the book's line-spacing setting to this value, to
-- open a gloss gap above each line. Disabling restores the default spacing.
local HINT_INTERLINE_MIN = 180
local GLOSS_FONT_SIZE = 10        -- default hint font size (adjustable 6..20)
local GLOSS_FONT_MIN = 6          -- selectable hint font-size range (slider)
local GLOSS_FONT_MAX = 20
local WORD_WALK_GUARD = 4000       -- hard cap on words scanned per page

local WordWise = WidgetContainer:extend{
    name = "wordwise",
    is_doc_only = true,
}

-- Only reflowable (crengine) documents expose the word/box APIs we need.
function WordWise:isSupportedDocument()
    return self.ui and self.ui.document and self.ui.rolling ~= nil and not self.ui.paging
end

function WordWise:getCEFRLevel()
    local level = G_reader_settings:readSetting("wordwise_cefr_level") or DEFAULT_CEFR
    return CEFR_RANK[level] and level or DEFAULT_CEFR
end

function WordWise:getCEFRRank()
    return CEFR_RANK[self:getCEFRLevel()] or CEFR_RANK[DEFAULT_CEFR]
end

function WordWise:getGlossFontSize()
    return G_reader_settings:readSetting("wordwise_gloss_font_size") or GLOSS_FONT_SIZE
end

-- Whether to draw the horizontal underline rule beneath each gloss. The
-- downward caret that points at the word is always drawn; this only controls
-- the "underline" part. On by default. Global, like the hint level.
function WordWise:getShowUnderline()
    return G_reader_settings:nilOrTrue("wordwise_show_underline")
end

-- Resolve only open/user-supplied databases. Kindle/Amazon conversion is
-- intentionally not part of this Android-focused fork.
function WordWise:getDBPath()
    if self._db_path ~= nil then return self._db_path or nil end
    self._db_path = false
    if lfs.attributes(WW_DIR, "mode") == "directory" then
        local preferred = WW_DIR .. "/wordwise.db"
        if lfs.attributes(preferred, "mode") == "file" then
            self._db_path = preferred
            return preferred
        end
        for name in lfs.dir(WW_DIR) do
            if name:match("%.db$") then
                self._db_path = WW_DIR .. "/" .. name
                return self._db_path
            end
        end
    end
    if lfs.attributes(BUNDLED_DB, "mode") == "file" then
        self._db_path = BUNDLED_DB
        return BUNDLED_DB
    end
    return nil
end

function WordWise:getDB()
    if self.db == nil then
        local path = self:getDBPath()
        self.db = (path and WordWiseDB.open(path)) or false
    end
    return self.db or nil
end

function WordWise:hasDB()
    return self:getDBPath() ~= nil
end

function WordWise:ensureDataDir()
    if lfs.attributes(WW_DIR, "mode") ~= "directory" then
        lfs.mkdir(WW_DIR)
    end
end

-- User choices live beside KOReader's data, not inside the plugin folder.
-- LuaSettings writes a backup and atomically replaces the state file, so plugin
-- updates do not remove known words or selected senses.
function WordWise:getState()
    if self.state_file then return self.state_file end
    self:ensureDataDir()
    self.state_file = LuaSettings:open(STATE_PATH)
    local legacy_selected = G_reader_settings:readSetting("wordwise_selected_senses") or {}
    local selected = self.state_file:readSetting("selected_senses", {})
    local changed = false
    for key, value in pairs(legacy_selected) do
        if selected[key] == nil then selected[key] = value; changed = true end
    end
    self.state_file:saveSetting("selected_senses", selected)
    if changed or not lfs.attributes(STATE_PATH, "mode") then self.state_file:flush() end
    self.selected_senses = selected
    return self.state_file
end

function WordWise:flushState()
    if self.state_file then self.state_file:flush() end
    if self.known_file then self.known_file:flush() end
end

-- Enabled state is per-book (stored in the book's sidecar), so each book
-- remembers whether Word Wise is on. Off by default: a book is only affected
-- once the reader turns it on there.
function WordWise:isEnabled()
    local ds = self.ui and self.ui.doc_settings
    return (ds and ds:isTrue("wordwise_enabled")) or false
end

-- Known words are keyed by lemma, so Know suppresses every sense of that
-- word. The state is stored in KOReader's data directory and survives plugin
-- replacement or update.
function WordWise:getKnownWords()
    if self.known_words then return self.known_words end
    self:ensureDataDir()
    self.known_file = LuaSettings:open(KNOWN_WORDS_PATH)
    local known_words = self.known_file:readSetting("words", {})
    -- Migrate the previous global word-level setting if it exists. The older
    -- sense-level setting cannot be safely converted without knowing its lemma.
    local legacy_words = G_reader_settings:readSetting("wordwise_known_words") or {}
    local changed = false
    for word, value in pairs(legacy_words) do
        if known_words[word] == nil then known_words[word] = value; changed = true end
    end
    self.known_file:saveSetting("words", known_words)
    if changed or not lfs.attributes(KNOWN_WORDS_PATH, "mode") then self.known_file:flush() end
    self.known_words = known_words
    return known_words
end

function WordWise:isWordKnown(entry)
    return entry and entry.word and self:getKnownWords()[entry.word:lower()] == true
end

function WordWise:setWordKnown(entry, known)
    if not (entry and entry.word) then return end
    local known_words = self:getKnownWords()
    known_words[entry.word:lower()] = known or nil
    self.known_file:saveSetting("words", known_words):flush()
end

-- Kept as aliases for callers from the earlier sense-level implementation.
function WordWise:isSenseKnown(entry) return self:isWordKnown(entry) end
function WordWise:setSenseKnown(entry, known) self:setWordKnown(entry, known) end

-- Lifecycle ----------------------------------------------------------------

function WordWise:init()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    -- infofont is NotoSans (proportional), suitable for compact glosses.
    self.gloss_face = Font:getFace("infofont", self:getGlossFontSize())
    self.hints = {}
    self:getState()
    -- Register the paint-only overlay. Tap handling is registered separately on
    -- ReaderUI so a miss returns false and normal Android page turns survive.
    self.overlay = { paintTo = function(_, bb, x, y) self:paintHints(bb, x, y) end }
    if self.ui.view then
        self.ui.view:registerViewModule("wordwise", self.overlay)
    end
    self:registerDictButtons()
end

-- The first sense used by the standard dictionary popup, if it is known to
-- Word Wise. The Word Wise action buttons remain available for glossed words.
function WordWise:dictLemmaFor(dict_popup)
    if not (dict_popup and dict_popup.word) then return nil end
    local key = dict_popup.word:gsub("[^%a]", "")
    if #key < 3 then return nil end
    local db = self:getDB()
    if not db then return nil end
    local entries = db:lookupAll(key)
    return entries and entries[1] or nil
end

-- Localize one of Word Wise's own UI strings to the current UI language. These
-- strings aren't in KOReader's catalog (see wordwise_l10n.lua), so we translate
-- them ourselves: look up the key for the current language, fall back to the
-- English source (en_GB), and substitute any extra args into %1, %2, ... .
function WordWise:tr(key, ...)
    local lang = G_reader_settings:readSetting("language")
    local t = lang and WordWiseL10N[lang]
    local s = (t and t[key]) or (WordWiseL10N.en_GB and WordWiseL10N.en_GB[key]) or key
    if select("#", ...) > 0 then return T(s, ...) end
    return s
end

-- Label for the toggle button given the popup's selected sense.
function WordWise:knownButtonText(entry)
    if entry and self:isSenseKnown(entry) then return self:tr("show") end
    return self:tr("know")
end

-- Toggle only the selected sense, hide/show its hint, and update the popup
-- button in place. This preserves other senses of the same word.
function WordWise:onKnownButtonTap(dict_popup)
    local entry = self:dictLemmaFor(dict_popup)
    if not entry then return end
    self:setSenseKnown(entry, not self:isSenseKnown(entry))
    self:refresh()
    local bt = dict_popup.button_table
    local button = bt and bt.button_by_id and bt.button_by_id["wordwise_known"]
    if button then
        button:setText(self:knownButtonText(entry), button.width)
        UIManager:setDirty(dict_popup, function() return "ui", button.dimen end)
    end
end

-- Add an "I already know this word" button to the dictionary popup. Tapping it
-- suppresses the Word Wise hint for that word everywhere; on a known word it
-- flips to "Show Word Wise hint" so the choice is reversible.
--
-- Two KOReader vintages are supported: the newer ReaderDictionary:addToDictButtons
-- API (used when present), and older builds that instead emit a DictButtonsReady
-- event -- handled by WordWise:onDictButtonsReady below. Only one path is ever
-- live on a given build, so the button is never duplicated.
function WordWise:registerDictButtons()
    if not (self.ui and self.ui.dictionary
            and self.ui.dictionary.addToDictButtons) then
        return
    end
    self.ui.dictionary:addToDictButtons({
        id = "wordwise_known",
        conditional = true,
        show_func = function(dict_popup)
            return self:dictLemmaFor(dict_popup) ~= nil
        end,
        text_func = function(dict_popup)
            return self:knownButtonText(self:dictLemmaFor(dict_popup))
        end,
        callback = function(dict_popup)
            self:onKnownButtonTap(dict_popup)
        end,
    })
end

-- Older-build hook: inject the button into the popup's button rows just before
-- the button table is built. Fires only on builds without addToDictButtons.
-- Placed directly below the VocabBuilder "Add to vocabulary builder" row when
-- present (its plugin sorts before ours, so it has already inserted its row);
-- otherwise appended.
function WordWise:onDictButtonsReady(dict_popup, buttons)
    local lemma = self:dictLemmaFor(dict_popup)
    if not lemma then return end
    local pos = #buttons + 1
    for i, row in ipairs(buttons) do
        if row[1] and row[1].id == "vocabulary" then
            pos = i + 1
            break
        end
    end
    table.insert(buttons, pos, {
        {
            id = "wordwise_known",
            text = self:knownButtonText(lemma),
            font_bold = false,
            callback = function() self:onKnownButtonTap(dict_popup) end,
        },
    })
end

-- The line spacing the current book is set to (crengine's configurable value,
-- the same one the Font menu edits and the sidecar persists).
function WordWise:currentLineSpacing()
    return (self.ui.font and self.ui.font.configurable
        and self.ui.font.configurable.line_spacing) or 100
end

-- The line spacing to fall back to as "default": the reader's global default if
-- set, else KOReader's built-in medium default (100). Used when restoring on
-- disable if we have no trustworthy captured original.
function WordWise:defaultLineSpacing()
    return G_reader_settings:readSetting("copt_line_spacing")
        or (G_defaults and G_defaults:readSetting("DCREREADER_CONFIG_LINE_SPACE_PERCENT_MEDIUM"))
        or 100
end

-- Turn the raised gloss spacing on/off by editing the book's ACTUAL line-spacing
-- setting (not a runtime-only override), which persists per-book. Only called
-- when the reader toggles Word Wise: enabling sets HINT_INTERLINE_MIN (=180%),
-- disabling sets the default. We never re-assert it on open, so once it is on
-- the reader is free to lower the line spacing again and it sticks.
function WordWise:setLineSpacing(on)
    if not self:isSupportedDocument() then return end
    local conf = self.ui.font and self.ui.font.configurable
    if not conf then return end
    conf.line_spacing = on and HINT_INTERLINE_MIN or self:defaultLineSpacing()
    self.ui.document:setInterlineSpacePercent(conf.line_spacing)
    self.ui:handleEvent(Event:new("UpdatePos"))
end

function WordWise:onReaderReady()
    self:setupTouchZones()
    if not self:isSupportedDocument() then return end
    if self:isEnabled() and self:hasDB() then
        -- The book was left at the raised spacing (persisted per-book) when it
        -- was turned on, so it reopens laid out correctly; just paint the hints.
        UIManager:nextTick(function() self:refresh() end)
    end
end

-- Close the dictionary DB when the document closes so the SQLite connection and
-- prepared statement are released deterministically (rather than at GC).
function WordWise:onCloseDocument()
    self:flushState()
    if self.db then
        self.db:close()
        self.db = nil
    end
end

-- Recompute per page turn / re-render.
function WordWise:onPosUpdate() self:computePageHints() end
function WordWise:onPageUpdate() self:computePageHints() end

-- A KOReader "profile" switch -- or any font / margin / line-height / style
-- change -- re-renders the document, moving every word to a new position. Our
-- hints cache absolute screen boxes, so after such a reflow they would keep
-- painting glosses at the OLD positions (scattered over the new text) until the
-- reader toggled Word Wise off and on. PosUpdate / PageUpdate don't reliably
-- refresh + repaint the overlay on the delayed "partial rerendering" path,
-- which KOReader enables by default, so also key off the re-render events every
-- other position-caching module (highlights, annotations, dogear, page map,
-- ToC, thumbnails) uses. nextTick lets the new layout settle first; refresh()
-- recomputes the hints and its full setDirty repaints them against the final
-- geometry.
function WordWise:onDocumentRerendered()
    if not (self:isEnabled() and self:isSupportedDocument()) then return end
    UIManager:nextTick(function() self:refresh() end)
end
WordWise.onDocumentPartiallyRerendered = WordWise.onDocumentRerendered

-- Core: enumerate this page's words, keep glosses for the difficult ones -----

function WordWise:computePageHints()
    self.hints = {}
    self.text_col = nil
    if not (self:isEnabled() and self:isSupportedDocument()) then return end
    local db = self:getDB()
    if not db then return end
    local doc = self.ui.document
    local page = doc:getCurrentPage()
    local start_xp = doc:getPageXPointer(page)
    if not start_xp then return end
    local cefr_rank = self:getCEFRRank()

    local first_xp, last_xp
    local xp = doc:getNextVisibleWordStart(start_xp)
    local guard = 0
    while xp and guard < WORD_WALK_GUARD do
        guard = guard + 1
        if not doc:isXPointerInCurrentPage(xp) then break end
        local end_xp = doc:getNextVisibleWordEnd(xp)
        if not end_xp then break end
        first_xp = first_xp or xp
        last_xp = end_xp
        local word = doc:getTextFromXPointers(xp, end_xp)
        if word then
            local key = word:gsub("[^%a]", "")
            if #key >= 3 then
                local entries = db:lookupAll(key)
                if entries and #entries > 0 then
                    local selected_key = self.selected_senses[entries[1].word:lower()]
                    local entry
                    for _, candidate in ipairs(entries) do
                        if candidate.sense_key == selected_key and candidate.cefr_rank >= cefr_rank and not self:isSenseKnown(candidate) then
                            entry = candidate
                            break
                        end
                    end
                    if not entry then
                        for _, candidate in ipairs(entries) do
                            if candidate.cefr_rank >= cefr_rank and not self:isSenseKnown(candidate) then
                                entry = candidate
                                break
                            end
                        end
                    end
                    if entry then
                        local boxes = doc:getScreenBoxesFromPositions(xp, end_xp, true)
                        local sbox = boxes and boxes[1]
                        if sbox and sbox.w > 0 and sbox.h > 0 then
                            self.hints[#self.hints + 1] = {
                                text = entry.gloss, entry = entry, senses = entries,
                                word = word, box = sbox,
                                cefr_rank = entry.cefr_rank,
                            }
                        end
                    end
                end
            end
        end
        local nxt = doc:getNextVisibleWordStart(end_xp)
        if not nxt or nxt == xp then break end
        xp = nxt
    end

    if first_xp and last_xp then
        local line_boxes = doc:getScreenBoxesFromPositions(first_xp, last_xp, true)
        local lo, hi
        for _, b in ipairs(line_boxes or {}) do
            if b.w > 0 then
                if not lo or b.x < lo then lo = b.x end
                if not hi or b.x + b.w > hi then hi = b.x + b.w end
            end
        end
        if lo and hi and hi > lo then self.text_col = { left = lo, right = hi } end
    end
end

-- Hit-test only rendered hints. A miss deliberately returns false so KOReader's
-- normal tap-forward/tap-backward zones still receive the gesture.
local function pointInBox(pos, box)
    return pos and box and pos.x >= box.x and pos.x <= box.x + box.w
        and pos.y >= box.y and pos.y <= box.y + box.h
end

function WordWise:setSelectedSense(entry)
    if not (entry and entry.sense_key) then return end
    self.selected_senses[(entry.word or ""):lower()] = entry.sense_key
    self:getState():saveSetting("selected_senses", self.selected_senses):flush()
    self:refresh()
end

function WordWise:showHintActions(hint)
    local buttons = {}
    local current_entry = hint.entry
    local current_key = current_entry and current_entry.sense_key
    for _, entry in ipairs(hint.senses or {}) do
        -- The selected/displayed sense is already shown in the dialog title.
        -- Do not repeat it as a selectable row below.
        local is_current = current_key and entry.sense_key == current_key
        if not is_current and not self:isSenseKnown(entry) then
            local cefr = entry.cefr_level or ""
            local pos = entry.pos and (" (" .. entry.pos .. ")") or ""
            table.insert(buttons, {{
                text = string.format("%s%s: %s", cefr, pos, entry.gloss),
                align = "left",
                -- Explicit height makes one-line and wrapped rows identical.
                height = SENSE_ROW_HEIGHT,
                padding_v = Screen:scaleBySize(4),
                -- Keep the row readable; KOReader may reduce the face or wrap
                -- within this fixed-height cell for especially long glosses.
                avoid_text_truncation = true,
                text_font_bold = true,
                text_font_size = 17,
                callback = function()
                    self:setSelectedSense(entry)
                    UIManager:close(self._hint_dialog)
                end,
            }})
        end
    end
    local function close_dialog()
        if self._hint_dialog then UIManager:close(self._hint_dialog) end
    end
    table.insert(buttons, {
        {
            text = self:isSenseKnown(current_entry) and self:tr("show_short") or self:tr("know_short"),
            callback = function()
                self:setSenseKnown(current_entry, not self:isSenseKnown(current_entry))
                close_dialog()
                self:refresh()
            end,
            text_font_size = 15,
            padding_h = 8,
        },
        {
            text = self:tr("dictionary_short"),
            callback = function()
                close_dialog()
                if self.ui.dictionary and self.ui.dictionary.onLookupWord then
                    self.ui.dictionary:onLookupWord(hint.word, true, { hint.box })
                end
            end,
            text_font_size = 15,
            padding_h = 8,
        },
        {
            text = self:tr("cancel"),
            id = "close",
            callback = close_dialog,
            text_font_size = 15,
            padding_h = 8,
        },
    })
    self._hint_dialog = ButtonDialog:new{
        title = T("Word Wise: %1", hint.word) .. "\n" .. (current_entry and current_entry.gloss or hint.text or ""),
        title_align = "left",
        width_factor = 0.92,
        rows_per_page = 8,
        buttons = buttons,
    }
    UIManager:show(self._hint_dialog)
    return true
end

function WordWise:onHintTap(ges)
    if not (self:isEnabled() and ges and self.ui and self.ui.view) then return false end
    -- getScreenBoxesFromPositions() returns screen-space boxes, matching ges.pos.
    local pos = ges.pos
    for _, hint in ipairs(self.hints or {}) do
        if pointInBox(pos, hint.hit_box or hint.box) then return self:showHintActions(hint) end
    end
    return false
end

function WordWise:setupTouchZones()
    if self._touch_zones_ready or not (self.ui and self.ui.registerTouchZones) then return end
    self.ui:registerTouchZones({
        {
            id = "wordwise_hint_tap", ges = "tap",
            screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
            overrides = {
                "tap_top_left_corner", "tap_top_right_corner",
                "tap_left_bottom_corner", "tap_right_bottom_corner",
                "readerhighlight_tap",
                "readerfooter_tap", "readermenu_ext_tap", "readermenu_tap",
                "tap_forward", "tap_backward",
            },
            handler = function(ges) return self:onHintTap(ges) end,
        },
    })
    self._touch_zones_ready = true
end

local GLOSS_HGAP = 8   -- minimum horizontal gap between two glosses on a line
local CARET_DEPTH = 7  -- height (and half-width) of the downward caret

-- Draw a small downward caret at cx that points to the
-- exact word below it, optionally flanked by a thin horizontal rule spanning
-- [x0, x1] (the "underline"). The caret always identifies the word; with_rule
-- adds the underline when the reader wants it.
local function drawWordMarker(bb, x0, x1, cx, ytop, color, with_rule)
    local half = CARET_DEPTH
    if cx - half < x0 then cx = x0 + half end
    if cx + half > x1 then cx = x1 - half end
    if with_rule then
        if cx - half > x0 then bb:paintRect(x0, ytop, (cx - half) - x0, 1, color) end
        if x1 > cx + half then bb:paintRect(cx + half, ytop, x1 - (cx + half), 1, color) end
    end
    -- two diagonals meeting at the tip (cx, ytop + half), pointing down
    for i = 0, half do
        bb:setPixel(cx - half + i, ytop + i, color)
        bb:setPixel(cx + half - i, ytop + i, color)
    end
end

-- Font-level vertical metrics (max ascent/descent) for the current gloss face,
-- the same for every gloss no matter which glyphs a given string contains.
-- paintHints lays glosses out with these instead of each string's own ink
-- extents (sizeUtf8Text's y_top/y_bottom), so the caret always sits the same
-- distance below the baseline. Per-string extents made a gloss with no
-- descenders (e.g. "an outdoor meal") pull its caret right up against the
-- letters and look cramped, while one with descenders ("a background scene or
-- setting") looked fine. Cached; recomputed when the face changes (font size).
function WordWise:getGlossMetrics()
    local face = self.gloss_face
    local m = self._gloss_metrics
    if m and m.face == face then return m end
    local ascent, descent
    local ok, height, asc = pcall(function()
        return face.ftsize:getHeightAndAscender()
    end)
    if ok and height and asc then
        ascent = math.floor(asc + 0.5)
        descent = math.ceil(height - asc)
    else
        -- Fallback for builds without the freetype metrics API: probe a string
        -- spanning the full ascender + descender range of the face.
        local sz = RenderText:sizeUtf8Text(0, 10000, face, "Agjpqy", true, false)
        ascent, descent = sz.y_top, sz.y_bottom
    end
    if descent < 0 then descent = 0 end
    m = { face = face, ascent = ascent, descent = descent }
    self._gloss_metrics = m
    return m
end

function WordWise:paintHints(bb, x, y)
    if not (self:isEnabled() and self.hints and #self.hints > 0) then return end
    local screen_w, screen_h = bb:getWidth(), bb:getHeight()
    local color = Blitbuffer.COLOR_BLACK
    local show_underline = self:getShowUnderline()

    local left_bound, right_bound = 2, screen_w - 2
    if self.text_col then
        left_bound = self.text_col.left
        right_bound = self.text_col.right
    else
        local ok, margins = pcall(function() return self.ui.document:getPageMargins() end)
        if ok and margins and margins.left and margins.right then
            left_bound = margins.left
            right_bound = screen_w - margins.right
        end
    end

    local GLOSS_RULE_GAP = 1
    local spacing = self:currentLineSpacing()
    local metrics = self:getGlossMetrics()
    local ascent, descent = metrics.ascent, metrics.descent
    local max_hint_width = math.min(MAX_INLINE_HINT_WIDTH,
        math.max(120, math.floor((right_bound - left_bound) * 0.48)))
    local safe_top = 4
    local safe_bottom = screen_h - 4
    local items = {}

    for _, h in ipairs(self.hints) do
        local full_text = h.entry and h.entry.gloss or h.text or ""
        local full_w = RenderText:sizeUtf8Text(0, screen_w, self.gloss_face, full_text, true, false).x
        local display_text = full_text
        if full_w > max_hint_width then
            display_text = RenderText:truncateTextByWidth(full_text, self.gloss_face, max_hint_width, true, false)
        end
        local text_w = RenderText:sizeUtf8Text(0, screen_w, self.gloss_face, display_text, true, false).x
        local tx = math.floor(h.box.x + (h.box.w - text_w) / 2 + 0.5)
        local max_x = right_bound - text_w
        if tx > max_x then tx = max_x end
        if tx < left_bound then tx = left_bound end

        local leading = h.box.h * (1 - 100 / spacing)
        local word_top = h.box.y + math.floor(leading / 2)
        local word_bottom = h.box.y + h.box.h - math.floor(leading / 2)
        local above_baseline = math.floor(math.min(
            h.box.y + (ascent - descent) / 2,
            word_top - 1 - descent
        ) + 0.5)
        local above_top = above_baseline - ascent
        local above_marker_y = math.min(above_baseline + descent + GLOSS_RULE_GAP,
            word_top - CARET_DEPTH - 1)

        -- Prefer the normal above-word placement. If the full ink rectangle
        -- would enter the top safe inset, move the whole unit below the word.
        local below_marker_y = word_bottom + 1
        local below_baseline = math.floor(below_marker_y + CARET_DEPTH + GLOSS_RULE_GAP + ascent + 0.5)
        local below_top = below_baseline - ascent
        local below = above_top < safe_top
        local baseline = below and below_baseline or above_baseline
        local marker_y = below and below_marker_y or above_marker_y
        local text_top = below and below_top or above_top
        local text_bottom = baseline + descent
        -- Word boxes on a single rendered line can differ by a few pixels due
        -- to glyph ascent/descent. Quantize the band so collision detection
        -- treats them as one row instead of allowing overlap.
        local band_size = math.max(12, h.box.h * 0.5)
        local band = math.floor((h.box.y + (below and h.box.h or 0)) / band_size + 0.5)

        items[#items + 1] = {
            h = h, text = display_text, full_text = full_text,
            x0 = tx, x1 = tx + text_w, band = band,
            cefr_rank = (h.entry and h.entry.cefr_rank) or 99,
            marker_y = marker_y, baseline = baseline, text_top = text_top,
            text_bottom = text_bottom, below = below,
            word_cx = math.floor(h.box.x + h.box.w / 2 + 0.5),
        }
    end

    -- De-overlap each above/below band. We first try the word-centered
    -- position, then search the gaps around already placed hints, choosing the
    -- legal position closest to the word. Only a hint that cannot fit anywhere
    -- in the line is dropped.
    table.sort(items, function(a, b)
        if a.band ~= b.band then return a.band < b.band end
        if a.cefr_rank ~= b.cefr_rank then return a.cefr_rank > b.cefr_rank end
        return a.x0 < b.x0
    end)
    local placed = {}
    local function overlaps(x0, x1, list)
        for _, iv in ipairs(list or {}) do
            if x0 < iv[2] + GLOSS_HGAP and x1 + GLOSS_HGAP > iv[1] then return true end
        end
        return false
    end
    local function find_slot(it, list)
        local preferred = it.x0
        local candidates = { preferred, left_bound, right_bound - (it.x1 - it.x0) }
        for _, iv in ipairs(list or {}) do
            candidates[#candidates + 1] = iv[2] + GLOSS_HGAP
            candidates[#candidates + 1] = iv[1] - GLOSS_HGAP - (it.x1 - it.x0)
        end
        local best, best_distance
        for _, candidate in ipairs(candidates) do
            local width = it.x1 - it.x0
            local x0 = math.max(left_bound, math.min(candidate, right_bound - width))
            local x1 = x0 + width
            if x1 <= right_bound and not overlaps(x0, x1, list) then
                local distance = math.abs(x0 - preferred)
                if not best_distance or distance < best_distance then
                    best, best_distance = x0, distance
                end
            end
        end
        return best
    end
    for _, it in ipairs(items) do
        if it.text_top >= safe_top and it.text_bottom <= safe_bottom then
            local list = placed[it.band]
            if not list then list = {}; placed[it.band] = list end
            local x0 = find_slot(it, list)
            if x0 then
                local width = it.x1 - it.x0
                it.x0, it.x1 = x0, x0 + width
                list[#list + 1] = { it.x0, it.x1 }
                local hit_top = math.min(it.text_top, it.h.box.y) - 5
                local hit_bottom = math.max(it.text_bottom, it.h.box.y + it.h.box.h) + 5
                it.h.hit_box = {
                    x = math.max(left_bound, it.x0 - 5),
                    y = math.max(0, hit_top),
                    w = math.min(right_bound, it.x1 + 5) - math.max(left_bound, it.x0 - 5),
                    h = hit_bottom - math.max(0, hit_top),
                }
                RenderText:renderUtf8Text(bb, it.x0, it.baseline, self.gloss_face,
                    it.text, true, false, color)
                if it.below then
                    -- Below-word hints use an upward-pointing marker.
                    local half = CARET_DEPTH
                    local cx = math.max(it.x0 + half, math.min(it.word_cx, it.x1 - half))
                    if show_underline then
                        if cx - half > it.x0 then bb:paintRect(it.x0, it.marker_y, cx - half - it.x0, 1, color) end
                        if it.x1 > cx + half then bb:paintRect(cx + half, it.marker_y, it.x1 - cx - half, 1, color) end
                    end
                    for i = 0, half do
                        bb:setPixel(cx - half + i, it.marker_y + half - i, color)
                        bb:setPixel(cx + half - i, it.marker_y + half - i, color)
                    end
                else
                    drawWordMarker(bb, it.x0, it.x1, it.word_cx, it.marker_y, color, show_underline)
                end
            end
        end
    end
end

-- Recompute + repaint for settings that do not relayout the document.
function WordWise:refresh()
    self:computePageHints()
    UIManager:setDirty("all", "ui")
end

function WordWise:setCEFRLevel(value)
    if not CEFR_RANK[value] then return end
    G_reader_settings:saveSetting("wordwise_cefr_level", value)
    self:refresh()
end

function WordWise:setGlossFontSize(value)
    G_reader_settings:saveSetting("wordwise_gloss_font_size", value)
    -- rebuild the cached face; paintHints re-measures gloss widths from it
    self.gloss_face = Font:getFace("infofont", value)
    self:refresh()
end

function WordWise:setShowUnderline(on)
    G_reader_settings:saveSetting("wordwise_show_underline", on)
    self:refresh()
end

function WordWise:showKnownWordsPath()
    self:getKnownWords()
    UIManager:show(InfoMessage:new{
        text = self:tr("known_words_file", KNOWN_WORDS_PATH),
    })
end

function WordWise:setEnabled(on)
    if on and not self:hasDB() then
        UIManager:show(InfoMessage:new{
            text = self:tr("no_db") .. WW_DIR,
        })
        return
    end
    self.ui.doc_settings:saveSetting("wordwise_enabled", on) -- per-book
    self:setLineSpacing(on) -- relayout + repaint; onPosUpdate recomputes hints
    if not on then
        self.hints = {}
        UIManager:setDirty("all", "ui")
    end
end

-- Menu ----------------------------------------------------------------------

function WordWise:onDispatcherRegisterActions()
    Dispatcher:registerAction("wordwise_toggle", {
        category = "none", event = "WordWiseToggle",
        title = self:tr("toggle"), reader = true,
    })
end

function WordWise:addToMainMenu(menu_items)
    menu_items.wordwise = {
        text = _("Word Wise"),
        sorting_hint = "more_tools",
        sub_item_table_func = function() return self:getSubMenu() end,
    }
end

function WordWise:getSubMenu()
    return {
        {
            text = self:tr("show_inline"),
            checked_func = function() return self:isEnabled() end,
            enabled_func = function() return self:isSupportedDocument() and self:hasDB() end,
            callback = function() self:setEnabled(not self:isEnabled()) end,
        },
        {
            text_func = function()
                return self:tr("cefr_level", self:getCEFRLevel())
            end,
            enabled_func = function() return self:isSupportedDocument() and self:hasDB() end,
            sub_item_table_func = function()
                local items = {}
                for _, level in ipairs(CEFR_LEVELS) do
                    items[#items + 1] = {
                        text = level,
                        checked_func = function() return self:getCEFRLevel() == level end,
                        radio = true,
                        callback = function()
                            G_reader_settings:saveSetting("wordwise_cefr_level", level)
                            self:refresh()
                        end,
                    }
                end
                return items
            end,
        },
        {
            text = self:tr("underline"),
            checked_func = function() return self:getShowUnderline() end,
            enabled_func = function() return self:isSupportedDocument() and self:hasDB() end,
            callback = function() self:setShowUnderline(not self:getShowUnderline()) end,
        },
        {
            text_func = function()
                return self:tr("known_words_menu")
            end,
            enabled_func = function() return self:isSupportedDocument() end,
            callback = function() self:showKnownWordsPath() end,
        },
        {
            text_func = function()
                return self:tr("font_size_menu", self:getGlossFontSize())
            end,
            enabled_func = function() return self:isSupportedDocument() and self:hasDB() end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                UIManager:show(SpinWidget:new{
                    title_text = self:tr("font_size_title"),
                    value = self:getGlossFontSize(),
                    value_min = GLOSS_FONT_MIN,
                    value_max = GLOSS_FONT_MAX,
                    default_value = GLOSS_FONT_SIZE,
                    keep_shown_on_apply = true, -- live preview as you slide/apply
                    callback = function(spin)
                        self:setGlossFontSize(spin.value)
                        if touchmenu_instance then touchmenu_instance:updateItems() end
                    end,
                })
            end,
        },
    }
end

function WordWise:onWordWiseToggle()
    self:setEnabled(not self:isEnabled())
    return true
end

return WordWise
