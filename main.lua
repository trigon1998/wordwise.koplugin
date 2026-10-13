--[[--
Word Wise: switch between inline microgloss hints and tap-to-define underlines
on the ORIGINAL book — no copy, no file rewrite.

How it works:
  * Walk visible words, selecting offline WordNet meanings using CEFR thresholds.
  * Paint subtle underlines inside the original word boxes, without reflow.
  * Tap an underline for a short meaning; tap the bubble for the sense picker.
  * Recompute box positions on page turns and layout changes.

@module koplugin.wordwise
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local Font = require("ui/font")
local ConfirmBox = require("ui/widget/confirmbox")
local WordWiseHintDialog = require("wordwise_hint_dialog")
local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local LuaSettings = require("luasettings")
local NetworkMgr = require("ui/network/manager")
local Trapper = require("ui/trapper")
local _ = require("gettext")
local T = require("ffi/util").template

local WordWiseDB = require("wordwise_db")
local ReadingLevel = require("wordwise_reading_level")
local WordWiseBubble = require("wordwise_bubble")
local WordWiseInline = require("wordwise_inline")
local WordWiseMicrogloss = require("wordwise_microgloss")
local WordWiseLanguage = require("wordwise_language")
local WordWiseL10N = require("wordwise_l10n")
local WordWiseOTA = require("wordwise_ota")

-- The plugin ships a built-in open dictionary (bundled beside this file), but a
-- user-supplied canonical-schema database dropped into WW_DIR overrides it. The
-- resolution order is WW_DIR/wordwise.db, first *.db in WW_DIR, then bundled.
local WW_DIR = DataStorage:getDataDir() .. "/wordwise"
local STATE_PATH = WW_DIR .. "/state.lua"
local KNOWN_WORDS_PATH = WW_DIR .. "/known_words.lua"
local CHECK_UPDATES_SETTING = "wordwise_check_updates"

-- Directory this plugin was loaded from, used to find the bundled dictionary.
local PLUGIN_ROOT = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("[^/\\]+$", "")
local BUNDLED_DB = PLUGIN_ROOT .. "wordwise.db"
local PLUGIN_DIR = PLUGIN_ROOT:gsub("[/\\\\]$", "")
local PLUGIN_VERSION = WordWiseOTA.current_version

local CEFR_RANK = { A1 = 1, A2 = 2, B1 = 3, B2 = 4, C1 = 5, C2 = 6 }
local WORD_WALK_GUARD = 4000       -- hard cap on words scanned per page

local WordWise = WidgetContainer:extend{
    name = "wordwise",
    is_doc_only = true,
}

-- Only reflowable (crengine) documents expose the word/box APIs we need.
function WordWise:isSupportedDocument()
    return self.ui and self.ui.document and self.ui.rolling ~= nil and not self.ui.paging
end

-- Preserve six CEFR values in SQLite, exposing three reader proficiency modes.
-- Legacy A1/A2 maps to Basic, B1/B2 to Intermediate and C1/C2 to Advanced.
function WordWise:getReadingLevel()
    return ReadingLevel.resolve(
        G_reader_settings:readSetting("wordwise_reading_level"),
        G_reader_settings:readSetting("wordwise_cefr_level")
    )
end

function WordWise:getCEFRRank()
    return CEFR_RANK[ReadingLevel.threshold(self:getReadingLevel())]
end

-- Persist presentation independently for each book; existing books stay in Tap mode.
function WordWise:getDisplayMode()
    local ds = self.ui and self.ui.doc_settings
    local mode = ds and ds:readSetting("wordwise_display_mode")
    return mode == "inline" and "inline" or "tap"
end

function WordWise:getInlineHintLength()
    local value = G_reader_settings:readSetting("wordwise_inline_hint_length")
    return WordWiseMicrogloss.isValidLength(value) and value or "micro"
end

function WordWise:setInlineHintLength(length)
    if not WordWiseMicrogloss.isValidLength(length) then return end
    G_reader_settings:saveSetting("wordwise_inline_hint_length", length)
    self:refresh()
end

function WordWise:enableInlineSpacing()
    if not self:isSupportedDocument() then return end
    local ds = self.ui.doc_settings
    local conf = self.ui.font and self.ui.font.configurable
    if not ds or not conf then return end
    local before = tonumber(conf.line_spacing) or 100
    local target = math.max(before, 170)
    local applied = ds:readSetting("wordwise_applied_line_spacing")
    if not ds:has("wordwise_previous_line_spacing")
            or (applied ~= nil and applied ~= before) then
        -- The reader changed line spacing manually while inline hints were on.
        -- Their new value takes precedence over the old saved preference.
        ds:saveSetting("wordwise_previous_line_spacing", before)
    end
    ds:saveSetting("wordwise_applied_line_spacing", target)
    if before ~= target then
        conf.line_spacing = target
        self.ui.document:setInterlineSpacePercent(target)
        self.ui:handleEvent(Event:new("UpdatePos"))
    end
end

function WordWise:setDisplayMode(mode)
    if mode ~= "tap" and mode ~= "inline" then return end
    if mode == self:getDisplayMode() then return end
    self.ui.doc_settings:saveSetting("wordwise_display_mode", mode)
    if self.bubble then self.bubble:close() end
    if self:isEnabled() then
        if mode == "inline" then
            self:enableInlineSpacing()
        else
            self:restoreLegacyLineSpacing()
        end
    end
    self:refresh()
end

function WordWise:getNotifyUpdates()
    return G_reader_settings:isTrue(CHECK_UPDATES_SETTING)
end

function WordWise:setNotifyUpdates(enabled)
    G_reader_settings:saveSetting(CHECK_UPDATES_SETTING, enabled and true or false)
end

-- Strip only punctuation surrounding a single alphabetic token. Internal
-- apostrophes and hyphens are deliberately rejected: concatenating fragments
-- made contractions look like unrelated words (we'll -> well, he'll -> hell).
local function lookupKey(text)
    if not WordWiseLanguage.isAsciiWord(text) then return nil end
    local key = text:match("^%s*[^%a]*([%a]+)[^%a]*%s*$")
    if key and #key >= 3 then return key end
end

-- Resolve only open/user-supplied databases. Kindle/Amazon conversion is
-- intentionally not part of this Android-focused fork.
function WordWise:getDBCandidates()
    local candidates = {}
    if lfs.attributes(WW_DIR, "mode") == "directory" then
        local preferred = WW_DIR .. "/wordwise.db"
        if lfs.attributes(preferred, "mode") == "file" then
            candidates[#candidates + 1] = preferred
        end
        local names = {}
        for name in lfs.dir(WW_DIR) do
            if name ~= "wordwise.db" and name:lower():match("%.db$") then
                names[#names + 1] = name
            end
        end
        table.sort(names)
        for _, name in ipairs(names) do
            candidates[#candidates + 1] = WW_DIR .. "/" .. name
        end
    end
    if lfs.attributes(BUNDLED_DB, "mode") == "file" then
        candidates[#candidates + 1] = BUNDLED_DB
    end
    return candidates
end

function WordWise:getDBPath()
    if self._db_path ~= nil then return self._db_path or nil end
    self:getDB()
    return self._db_path or nil
end

function WordWise:getDB()
    if self.db == nil then
        self.db = false
        local rejected = {}
        for _, path in ipairs(self:getDBCandidates()) do
            local opened = WordWiseDB.open(path)
            if opened then
                self.db = opened
                self._db_path = path
                break
            end
            rejected[#rejected + 1] = path
        end
        if not self.db then self._db_path = false end
        if self.db and self._db_path == BUNDLED_DB and #rejected > 0
                and not self._db_fallback_notified then
            self._db_fallback_notified = true
            local rejected_path = rejected[1]
            UIManager:nextTick(function()
                if self.ui then
                    UIManager:show(InfoMessage:new{
                        text = self:tr("db_fallback", rejected_path),
                    })
                end
            end)
        end
    end
    return self.db or nil
end

function WordWise:hasDB()
    return self:getDB() ~= nil
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

function WordWise:cleanupOTABackup()
    WordWiseOTA:cleanup_backup(PLUGIN_DIR)
end

function WordWise:init()
    self:cleanupOTABackup()
    self._lifecycle_generation = (self._lifecycle_generation or 0) + 1
    self._hint_refresh_scheduled = false
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    -- infofont is NotoSans (proportional), suitable for compact glosses.
    self.bubble = WordWiseBubble.new()
    self.gloss_face = Font:getFace("infofont", 11)
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
    local key = lookupKey(dict_popup.word)
    if not key then return nil end
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

-- Previous releases forced 180% spacing for inline glosses. Restore the
-- exact saved per-book value, unless the reader changed it themselves.
function WordWise:restoreLegacyLineSpacing()
    if not self:isSupportedDocument() then return end
    local ds = self.ui.doc_settings
    local conf = self.ui.font and self.ui.font.configurable
    if not ds or not conf or not ds:has("wordwise_previous_line_spacing") then return end
    local previous = ds:readSetting("wordwise_previous_line_spacing")
    local applied = ds:readSetting("wordwise_applied_line_spacing")
    ds:delSetting("wordwise_previous_line_spacing")
    ds:delSetting("wordwise_applied_line_spacing")
    if type(previous) == "number" and conf.line_spacing == applied then
        conf.line_spacing = previous
        self.ui.document:setInterlineSpacePercent(previous)
        self.ui:handleEvent(Event:new("UpdatePos"))
    end
end

function WordWise:scheduleHintRefresh()
    if self._hint_refresh_scheduled then return end
    self._hint_refresh_scheduled = true
    local generation = self._lifecycle_generation
    UIManager:nextTick(function()
        self._hint_refresh_scheduled = false
        -- A document may have closed before nextTick runs. Do not retain or
        -- recompute stale page objects after the reader moved on.
        if generation ~= self._lifecycle_generation then return end
        if self:isEnabled() and self:isSupportedDocument() and self:hasDB() then
            self:computePageHints()
            UIManager:setDirty("all", "ui")
        end
    end)
end

function WordWise:onReaderReady()
    self:setupTouchZones()
    if not self:isSupportedDocument() then return end
    if self:isEnabled() and self:getDisplayMode() == "inline" then
        self:enableInlineSpacing()
    else
        self:restoreLegacyLineSpacing()
    end
    if self:isEnabled() and self:hasDB() then
        -- Coalesce the initial reader event with any immediate PosUpdate or
        -- rerender event emitted while the document settles.
        self:scheduleHintRefresh()
    end
end

-- Wake-time update checks are opt-in and silent unless a newer verified
-- release is available. The updater throttles these checks to once per hour.
function WordWise:onResume()
    self:backgroundUpdateCheck()
end

-- Close the dictionary DB when the document closes so the SQLite connection and
-- prepared statement are released deterministically (rather than at GC).
function WordWise:onCloseDocument()
    self._lifecycle_generation = (self._lifecycle_generation or 0) + 1
    self._hint_refresh_scheduled = false
    if self._hint_dialog then
        UIManager:close(self._hint_dialog)
        self._hint_dialog = nil
    end
    self:dismissOTAStatus()
    if self.bubble then self.bubble:close() end
    self:flushState()
    if self.db then
        self.db:close()
    end
    self.db = nil
    self._db_path = nil
    self._db_fallback_notified = nil
    self.hints = {}
end

-- Recompute once on the next UI tick. KOReader may emit PosUpdate, PageUpdate,
-- and a rerender event for one page turn; coalescing prevents duplicate word
-- walks and duplicate screen-box allocations.
function WordWise:onPosUpdate() self:scheduleHintRefresh() end
function WordWise:onPageUpdate() self:scheduleHintRefresh() end

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
    self:scheduleHintRefresh()
end
WordWise.onDocumentPartiallyRerendered = WordWise.onDocumentRerendered

-- Core: enumerate this page's words, keep glosses for the difficult ones -----

function WordWise:chooseHintEntry(entries, selected_key, cefr_rank)
    -- A sense explicitly selected in the popup is a display preference, not a
    -- vocabulary-level decision. The word already qualified for Word Wise via
    -- one of its senses, so do not silently discard the user's choice merely
    -- because that particular dictionary sense has a lower CEFR label.
    local word_qualifies = false
    for _, candidate in ipairs(entries or {}) do
        if candidate.cefr_rank >= cefr_rank
                and not self:isSenseKnown(candidate) then
            word_qualifies = true
            break
        end
    end
    if not word_qualifies then return nil end

    if selected_key then
        for _, candidate in ipairs(entries or {}) do
            if candidate.sense_key == selected_key
                    and not self:isSenseKnown(candidate) then
                return candidate
            end
        end
    end

    -- With no usable manual choice, retain the normal CEFR threshold behavior.
    for _, candidate in ipairs(entries or {}) do
        if candidate.cefr_rank >= cefr_rank
                and not self:isSenseKnown(candidate) then
            return candidate
        end
    end
end

function WordWise:computePageHints()
    if self.bubble then self.bubble:close() end
    self.hints = {}
    if not (self:isEnabled() and self:isSupportedDocument()) then return end
    local book_lang = self.ui.doc_props and self.ui.doc_props.language
    -- KOReader readerui.lua normalizes this from the document metadata.
    -- Never feed a known non-English book to the English WordNet overlay.
    if WordWiseLanguage.isEnglishBook(book_lang) == false then return end
    local db = self:getDB()
    if not db then return end
    local doc = self.ui.document
    local page = doc:getCurrentPage()
    local start_xp = doc:getPageXPointer(page)
    if not start_xp then return end
    local cefr_rank = self:getCEFRRank()

    local xp = doc:getNextVisibleWordStart(start_xp)
    local guard = 0
    local accented_tokens = 0
    while xp and guard < WORD_WALK_GUARD do
        guard = guard + 1
        if not doc:isXPointerInCurrentPage(xp) then break end
        local end_xp = doc:getNextVisibleWordEnd(xp)
        if not end_xp then break end
        local word = doc:getTextFromXPointers(xp, end_xp)
        if word then
            if not WordWiseLanguage.isAsciiWord(word) then
                accented_tokens = accented_tokens + 1
            end
            local key = lookupKey(word)
            if key then
                local entries = db:lookupAll(key)
                if entries and #entries > 0 then
                    local selected_key = self.selected_senses[entries[1].word:lower()]
                    local entry = self:chooseHintEntry(entries, selected_key, cefr_rank)
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
    -- Fallback when EPUB metadata omits the language. This rejects Vietnamese
    -- pages containing stray English homographs without scanning outside the
    -- already-enumerated visible words.
    if WordWiseLanguage.isEnglishBook(book_lang) == nil
            and WordWiseLanguage.pageIsNonEnglish(guard, accented_tokens) then
        self.hints = {}
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
    self._hint_dialog = WordWiseHintDialog:new{
        owner = self,
        hint = hint,
    }
    UIManager:show(self._hint_dialog)
    return true
end

function WordWise:onHintTap(ges)
    if not (self:isEnabled() and ges and self.ui and self.ui.view) then return false end
    local selected = self.ui.highlight
    if selected and (selected.hold_pos or selected.selected_text or selected.select_mode) then
        return false -- KOReader owns the text selection.
    end
    local pos = ges.pos
    if not pos then return false end

    if self:getDisplayMode() == "inline" then
        for _, hint in ipairs(self.hints or {}) do
            if pointInBox(pos, hint.box)
                    or (hint.inline_visible and pointInBox(pos, hint.hit_box)) then
                return self:showHintActions(hint)
            end
        end
        return false
    end

    if self.bubble and self.bubble:contains(pos) then
        local hint = self.bubble.hint
        self.bubble:close()
        self:showHintActions(hint) -- Existing sense picker / Know / Dictionary.
        return true
    end
    for _, hint in ipairs(self.hints or {}) do
        if pointInBox(pos, hint.box) then
            if self.bubble then
                local reader_font = self.ui.font and self.ui.font.configurable
                local size = reader_font and reader_font.font_size or 20
                self.bubble:show(hint, size, self:tr("tap_for_details"))
                UIManager:setDirty("all", "ui")
            end
            return true
        end
    end
    if self.bubble and self.bubble:close() then
        -- Dismissal never also turns the page.
        UIManager:setDirty("all", "ui")
        return true
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

-- Minimal, e-ink-friendly wavy underline inside each matched word box.
-- No added text, collision layout or reader line-spacing modifications.
function WordWise:paintHints(bb, x, y)
    if not self:isEnabled() then return end
    x, y = x or 0, y or 0
    local inline = self:getDisplayMode() == "inline"
    if inline then
        WordWiseInline.paint(bb, x, y, self.hints, {
            face = self.gloss_face,
            line_spacing = self.ui.font and self.ui.font.configurable
                and self.ui.font.configurable.line_spacing or 100,
            length = self:getInlineHintLength(),
        })
    end
    local step = math.max(1, math.floor(Screen:scaleBySize(2)))
    local thickness = math.max(1, math.floor(Screen:scaleBySize(1)))
    local wave = { 0, 1, 2, 1 }
    local width, height = Screen:getWidth(), Screen:getHeight()
    for _, hint in ipairs(self.hints or {}) do
        local box = hint.box
        -- Inline labels can collide on a dense page. Leave a visible underline
        -- and tap target for every word whose above-line label couldn't fit.
        if (not inline or not hint.inline_visible)
                and box and box.w > 0 and box.h >= thickness + 3 then
            local left = math.max(0, math.floor(box.x))
            local right = math.min(width, math.ceil(box.x + box.w))
            local baseline = math.floor(box.y + box.h - thickness - 3)
            for offset = 0, right - left - 1, step do
                local rise = wave[(math.floor(offset / step) % #wave) + 1]
                local line_y = baseline + rise
                if line_y >= 0 and line_y + thickness <= height then
                    bb:paintRect(x + left + offset, y + line_y,
                        math.min(step, right - left - offset), thickness,
                        Blitbuffer.COLOR_GRAY)
                end
            end
        end
    end
    if self.bubble and not inline then self.bubble:paint(bb, x, y) end
end

-- Recompute + repaint for settings that do not relayout the document.
function WordWise:refresh()
    self:computePageHints()
    UIManager:setDirty("all", "ui")
end

function WordWise:setReadingLevel(level)
    if not ReadingLevel.threshold(level) then return end
    G_reader_settings:saveSetting("wordwise_reading_level", level)
    self:refresh()
end

function WordWise:showKnownWordsPath()
    self:getKnownWords()
    UIManager:show(InfoMessage:new{
        text = self:tr("known_words_file", KNOWN_WORDS_PATH),
    })
end

function WordWise:otaErrorText(err)
    if err == "wantread" or err == "timeout" or err == "sink timeout" then
        return self:tr("update_network_retry")
    end
    return tostring(err or "unknown error")
end

function WordWise:dismissOTAStatus()
    if self._ota_status_message then
        local message = self._ota_status_message
        self._ota_status_message = nil
        UIManager:close(message)
    end
end

function WordWise:showOTAStatus(text)
    self:dismissOTAStatus()
    self._ota_status_message = InfoMessage:new{ text = text }
    UIManager:show(self._ota_status_message)
end

local function plainReleaseNotes(notes)
    notes = tostring(notes or "")
    notes = notes:gsub("\r\n", "\n")
    notes = notes:gsub("#+%s*", "")
    notes = notes:gsub("%*%*(.-)%*%*", "%1")
    notes = notes:gsub("`(.-)`", "%1")
    notes = notes:gsub("^%s+", ""):gsub("%s+$", "")
    return notes
end

function WordWise:installOTA(release)
    self:showOTAStatus(self:tr("downloading_update"))
    Trapper:wrap(function()
        local ok, install_err = WordWiseOTA:install(release, PLUGIN_DIR)
        self:dismissOTAStatus()
        if not ok then
            UIManager:show(InfoMessage:new{
                text = self:tr("update_install_failed", self:otaErrorText(install_err)),
            })
            return
        end
        UIManager:show(ConfirmBox:new{
            text = self:tr("update_installed", release.version),
            ok_text = self:tr("restart_button"),
            cancel_text = self:tr("later_button"),
            ok_callback = function() UIManager:restartKOReader() end,
        })
    end)
end

function WordWise:showOTARelease(release)
    local TextViewer = require("ui/widget/textviewer")
    local viewer
    local notes = plainReleaseNotes(release.notes)
    if notes == "" then notes = self:tr("no_release_notes") end
    viewer = TextViewer:new{
        title = self:tr("update_available_title"),
        text = self:tr("update_versions", PLUGIN_VERSION, release.version) .. "\n\n" .. notes,
        buttons_table = {{
            {
                text = self:tr("cancel"),
                callback = function() UIManager:close(viewer) end,
            },
            {
                text = self:tr("update_and_restart"),
                callback = function()
                    UIManager:close(viewer)
                    self:installOTA(release)
                end,
            },
        }},
        add_default_buttons = false,
    }
    UIManager:show(viewer)
end

function WordWise:backgroundUpdateCheck()
    if not self:getNotifyUpdates() or not NetworkMgr:isWifiOn() then return end
    UIManager:scheduleIn(0.1, function()
        local release, _, checked = WordWiseOTA:fetch_latest_cached()
        if not checked or not release then return end
        if WordWiseOTA.compare_versions(release.version, PLUGIN_VERSION) == 1 then
            local Notification = require("ui/widget/notification")
            Notification:notify(self:tr("update_notification", release.version),
                Notification.SOURCE_ALWAYS_SHOW)
        end
    end)
end

function WordWise:checkForOTA()
    local co = coroutine.running()
    if not co then
        Trapper:wrap(function() self:checkForOTA() end)
        return
    end
    local resume = function(result) coroutine.resume(co, result) end
    if NetworkMgr:willRerunWhenConnected(resume) then
        coroutine.yield()
        if not NetworkMgr:isConnected() then return end
    end

    self:showOTAStatus(self:tr("checking_update"))
    local release, err = WordWiseOTA:fetch_latest()
    self:dismissOTAStatus()
    if not release then
        UIManager:show(InfoMessage:new{ text = self:tr("update_check_failed", self:otaErrorText(err)) })
        return
    end
    local relation = WordWiseOTA.compare_versions(release.version, PLUGIN_VERSION)
    if relation == 0 then
        UIManager:show(InfoMessage:new{ text = self:tr("up_to_date", PLUGIN_VERSION) })
        return
    elseif relation == -1 then
        UIManager:show(InfoMessage:new{ text = self:tr("newer_installed", PLUGIN_VERSION, release.version) })
        return
    end

    self:showOTARelease(release)
end

function WordWise:setEnabled(on)
    if on and not self:hasDB() then
        UIManager:show(InfoMessage:new{
            text = self:tr("no_db") .. WW_DIR,
        })
        return
    end
    self.ui.doc_settings:saveSetting("wordwise_enabled", on) -- per-book
    if on and self:getDisplayMode() == "inline" then
        self:enableInlineSpacing()
    else
        self:restoreLegacyLineSpacing()
    end
    if on then
        self:refresh()
    else
        self.hints = {}
        if self.bubble then self.bubble:close() end
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
            text = self:tr("toggle_hints"),
            checked_func = function() return self:isEnabled() end,
            enabled_func = function() return self:isSupportedDocument() and self:hasDB() end,
            callback = function() self:setEnabled(not self:isEnabled()) end,
        },
        {
            text_func = function()
                return self:tr("display_mode", self:getDisplayMode() == "inline"
                    and self:tr("mode_inline") or self:tr("mode_tap"))
            end,
            enabled_func = function() return self:isSupportedDocument() and self:hasDB() end,
            sub_item_table_func = function()
                return {
                    {
                        text = self:tr("mode_tap"),
                        checked_func = function() return self:getDisplayMode() == "tap" end,
                        radio = true,
                        callback = function() self:setDisplayMode("tap") end,
                    },
                    {
                        text = self:tr("mode_inline"),
                        checked_func = function() return self:getDisplayMode() == "inline" end,
                        radio = true,
                        callback = function() self:setDisplayMode("inline") end,
                    },
                }
            end,
        },
        {
            text_func = function()
                return self:tr("inline_length", self:getInlineHintLength() == "micro"
                    and self:tr("micro_gloss") or self:tr("short_gloss"))
            end,
            enabled_func = function()
                return self:isSupportedDocument() and self:hasDB()
                    and self:getDisplayMode() == "inline"
            end,
            sub_item_table_func = function()
                local items = {}
                for _, length in ipairs(WordWiseMicrogloss.lengths()) do
                    items[#items + 1] = {
                        text = length == "micro" and self:tr("micro_gloss") or self:tr("short_gloss"),
                        checked_func = function() return self:getInlineHintLength() == length end,
                        radio = true,
                        callback = function() self:setInlineHintLength(length) end,
                    }
                end
                return items
            end,
        },
        {
            text_func = function()
                return self:tr("reading_level", self:getReadingLevel())
            end,
            enabled_func = function() return self:isSupportedDocument() and self:hasDB() end,
            sub_item_table_func = function()
                local items = {}
                for _, level in ipairs(ReadingLevel.levels) do
                    items[#items + 1] = {
                        text = level,
                        checked_func = function() return self:getReadingLevel() == level end,
                        radio = true,
                        callback = function()
                            self:setReadingLevel(level)
                        end,
                    }
                end
                return items
            end,
        },
        {
            text_func = function()
                return self:tr("known_words_menu")
            end,
            enabled_func = function() return self:isSupportedDocument() end,
            callback = function() self:showKnownWordsPath() end,
        },
        {
            text = self:tr("updates_menu"),
            sub_item_table_func = function()
                return {
                    {
                        text = self:tr("notify_updates"),
                        checked_func = function() return self:getNotifyUpdates() end,
                        callback = function()
                            self:setNotifyUpdates(not self:getNotifyUpdates())
                        end,
                    },
                    {
                        text = self:tr("check_update"),
                        callback = function() self:checkForOTA() end,
                    },
                    {
                        text = self:tr("installed_version", PLUGIN_VERSION),
                        enabled_func = function() return false end,
                    },
                }
            end,
        },
    }
end

function WordWise:onWordWiseToggle()
    self:setEnabled(not self:isEnabled())
    return true
end

return WordWise
