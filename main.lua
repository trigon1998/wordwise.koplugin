--[[--
Word Wise: draw short definitions above difficult words (like Kindle's Word
Wise) as a per-page overlay on the ORIGINAL book — no copy, no file rewrite.

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
local RenderText = require("ui/rendertext")
local SpinWidget = require("ui/widget/spinwidget")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local _ = require("gettext")
local T = require("ffi/util").template

local WordWiseDB = require("wordwise_db")
local WordWiseKindle = require("wordwise_kindle")
local WordWiseL10N = require("wordwise_l10n")

-- The plugin ships a built-in open dictionary (bundled beside this file), but a
-- user-supplied canonical-schema database dropped into WW_DIR overrides it — so
-- you can swap in your own (e.g. a personal Kindle-derived DB) without deleting
-- anything. Resolution order: WW_DIR/wordwise.db, first *.db in WW_DIR, bundled.
local WW_DIR = DataStorage:getDataDir() .. "/wordwise"

-- Directory this plugin was loaded from, used to find the bundled dictionary.
local PLUGIN_ROOT = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("[^/\\]+$", "")
local BUNDLED_DB = PLUGIN_ROOT .. "wordwise.db"

local MAX_LEVEL = 5                -- hint level 1 (rarest words only) .. 5 (most hints)
local DEFAULT_LEVEL = 3           -- middle of the slider, like Kindle's default
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

function WordWise:getHintLevel()
    return G_reader_settings:readSetting("wordwise_hint_level") or DEFAULT_LEVEL
end

function WordWise:getGlossFontSize()
    return G_reader_settings:readSetting("wordwise_gloss_font_size") or GLOSS_FONT_SIZE
end

-- Resolve the dictionary path: a user DB in WW_DIR (wordwise.db, else the first
-- *.db found there) overrides the dictionary bundled with the plugin. If none
-- is present but this is a Kindle with its own Word Wise corpus on disk, that
-- is converted once into WW_DIR/wordwise.db and used from then on (personal
-- use only -- see wordwise_kindle.lua). Cached (nil = not yet resolved, false
-- = none).
function WordWise:getDBPath()
    if self._db_path ~= nil then
        return self._db_path or nil
    end
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
    if WordWiseKindle.available() then
        if lfs.attributes(WW_DIR, "mode") ~= "directory" then
            lfs.mkdir(WW_DIR)
        end
        -- One-time conversion; on slow device storage this can take a while,
        -- so show something rather than leave the UI looking hung.
        local info = InfoMessage:new{
            text = _("Building Word Wise dictionary from this Kindle's data (one-time)…"),
        }
        UIManager:show(info)
        UIManager:forceRePaint()
        local converted = WW_DIR .. "/wordwise.db"
        local ok = WordWiseKindle.convert(WordWiseKindle.KLLD_PATH, converted, BUNDLED_DB)
        UIManager:close(info)
        if ok then
            self._db_path = converted
            return converted
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

-- Enabled state is per-book (stored in the book's sidecar), so each book
-- remembers whether Word Wise is on. Off by default: a book is only affected
-- once the reader turns it on there.
function WordWise:isEnabled()
    local ds = self.ui and self.ui.doc_settings
    return (ds and ds:isTrue("wordwise_enabled")) or false
end

-- Known words: lemmas the user has marked "I already know this word" from the
-- dictionary popup. Stored as a set { [lemma] = true } and suppressed from
-- hints across every book (global, like the hint level). Keyed by lemma so all
-- inflected forms of a word are hidden once it is marked known.
function WordWise:getKnownWords()
    if self.known_words == nil then
        self.known_words = G_reader_settings:readSetting("wordwise_known_words") or {}
    end
    return self.known_words
end

function WordWise:isWordKnown(lemma)
    return lemma ~= nil and self:getKnownWords()[lemma] == true
end

function WordWise:setWordKnown(lemma, known)
    if not lemma then return end
    local kw = self:getKnownWords()
    kw[lemma] = known or nil
    G_reader_settings:saveSetting("wordwise_known_words", kw)
end

-- Lifecycle ----------------------------------------------------------------

function WordWise:init()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    -- infofont is NotoSans (proportional), closer to Kindle's gloss font than
    -- the monospace infont.
    self.gloss_face = Font:getFace("infofont", self:getGlossFontSize())
    self.hints = {}
    -- Register the overlay painter with ReaderView.
    self.overlay = { paintTo = function(_, bb, x, y) self:paintHints(bb, x, y) end }
    if self.ui.view then
        self.ui.view:registerViewModule("wordwise", self.overlay)
    end
    self:registerDictButtons()
end

-- The lemma this dictionary popup is looking at, if it is a word Word Wise
-- knows (so the "already know" button only appears for glossed words). Returns
-- the de-inflected lemma, matching how hints are keyed.
function WordWise:dictLemmaFor(dict_popup)
    if not (dict_popup and dict_popup.word) then return nil end
    local key = dict_popup.word:gsub("[^%a]", "")
    if #key < 3 then return nil end
    local db = self:getDB()
    if not db then return nil end
    local entry = db:lookup(key)
    return entry and entry.key or nil
end

-- Localize one of the button strings ("know" / "show") to the UI language.
-- These strings aren't in KOReader's catalog (see wordwise_l10n.lua), so we
-- translate them ourselves and fall back to English via gettext.
function WordWise:tr(which)
    local lang = G_reader_settings:readSetting("language")
    local t = lang and WordWiseL10N[lang]
    if t and t[which] then return t[which] end
    if which == "show" then return _("Show Word Wise hint") end
    return _("I already know this word")
end

-- Label for the toggle button given the popup's lemma.
function WordWise:knownButtonText(lemma)
    if lemma and self:isWordKnown(lemma) then
        return self:tr("show")
    end
    return self:tr("know")
end

-- Toggle the known state for the popup's word, hide/show its hint, and flip the
-- button's own label in place (both KOReader vintages build a button_table with
-- our button id, so this works whichever registration path added the button).
function WordWise:onKnownButtonTap(dict_popup)
    local lemma = self:dictLemmaFor(dict_popup)
    if not lemma then return end
    self:setWordKnown(lemma, not self:isWordKnown(lemma))
    self:refresh()  -- repaint the page so the hint appears/disappears now
    local bt = dict_popup.button_table
    local button = bt and bt.button_by_id and bt.button_by_id["wordwise_known"]
    if button then
        button:setText(self:knownButtonText(lemma), button.width)
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
    if self.db then
        self.db:close()
        self.db = nil
    end
end

-- Recompute per page turn / re-render.
function WordWise:onPosUpdate() self:computePageHints() end
function WordWise:onPageUpdate() self:computePageHints() end

-- Core: enumerate this page's words, keep glosses for the difficult ones -----

function WordWise:computePageHints()
    self.hints = {}
    if not (self:isEnabled() and self:isSupportedDocument()) then return end
    local db = self:getDB()
    if not db then return end
    local doc = self.ui.document
    local page = doc:getCurrentPage()
    local start_xp = doc:getPageXPointer(page)
    if not start_xp then return end
    local level = self:getHintLevel()

    local xp = doc:getNextVisibleWordStart(start_xp)
    local guard = 0
    while xp and guard < WORD_WALK_GUARD do
        guard = guard + 1
        if not doc:isXPointerInCurrentPage(xp) then break end
        local end_xp = doc:getNextVisibleWordEnd(xp)
        if not end_xp then break end
        local word = doc:getTextFromXPointers(xp, end_xp)
        if word then
            local key = word:gsub("[^%a]", "")
            if #key >= 3 then
                local entry = db:lookup(key)
                -- difficulty 1 = rarest .. 5 = common; show up to the hint level,
                -- and never for words the user has marked as already known.
                if entry and entry.difficulty <= level and not self:isWordKnown(entry.key) then
                    local boxes = doc:getScreenBoxesFromPositions(xp, end_xp, true)
                    -- Use the FIRST line-segment: a word hyphenated across two
                    -- lines otherwise yields a tall multi-line bounding box and
                    -- the gloss lands a line too high / off-column.
                    local sbox = boxes and boxes[1]
                    if sbox and sbox.w > 0 and sbox.h > 0 then
                        self.hints[#self.hints + 1] = {
                            text = entry.gloss, box = sbox,
                            difficulty = entry.difficulty,
                        }
                    end
                end
            end
        end
        local nxt = doc:getNextVisibleWordStart(end_xp)
        if not nxt or nxt == xp then break end
        xp = nxt
    end
end

local GLOSS_HGAP = 8   -- minimum horizontal gap between two glosses on a line
local CARET_DEPTH = 7  -- height (and half-width) of the downward caret

-- Draw the Kindle-style marker: a thin horizontal rule spanning [x0, x1] with a
-- small downward caret at cx that points to the exact word below it.
local function drawWordMarker(bb, x0, x1, cx, ytop, color)
    local half = CARET_DEPTH
    if cx - half < x0 then cx = x0 + half end
    if cx + half > x1 then cx = x1 - half end
    if cx - half > x0 then bb:paintRect(x0, ytop, (cx - half) - x0, 1, color) end
    if x1 > cx + half then bb:paintRect(cx + half, ytop, x1 - (cx + half), 1, color) end
    -- two diagonals meeting at the tip (cx, ytop + half), pointing down
    for i = 0, half do
        bb:setPixel(cx - half + i, ytop + i, color)
        bb:setPixel(cx + half - i, ytop + i, color)
    end
end

function WordWise:paintHints(bb, x, y)
    if not (self:isEnabled() and self.hints and #self.hints > 0) then return end
    local screen_w = bb:getWidth()
    local color = Blitbuffer.COLOR_BLACK

    -- Lay each gloss out: measure it, center it over its word, and clamp it
    -- fully on screen (right edge first, so the left wins if the gloss is wider
    -- than the page -- e.g. a word wrapped across a line break anchors on its
    -- first segment, which can sit hard against the right margin).
    --
    -- Vertically, the hint unit is gloss text, then the rule, then the caret
    -- pointing down at the word. The raised leading is split evenly above/below
    -- each line's glyphs, so the blank band above the word is centered on the
    -- line-box top (box.y). We center the whole unit in that band so it sits in
    -- the middle of the gap regardless of the line spacing -- but never let the
    -- caret drop onto the word (clamp to just above it when the gap is tight).
    local GLOSS_RULE_GAP = 1  -- padding between the gloss text bottom and the rule
    local spacing = self:currentLineSpacing()
    local items = {}
    for _, h in ipairs(self.hints) do
        local sz = RenderText:sizeUtf8Text(0, screen_w, self.gloss_face, h.text, true, false)
        local w = sz.x
        local tx = math.floor(h.box.x + (h.box.w - w) / 2 + 0.5)
        local max_x = screen_w - w - 2
        if tx > max_x then tx = max_x end
        if tx < 2 then tx = 2 end
        local leading = h.box.h * (1 - 100 / spacing)
        local word_top = h.box.y + math.floor(leading / 2)
        -- Center the gloss TEXT itself in the blank band (box.y is the band's
        -- centre): the glyph extent [baseline - y_top, baseline + y_bottom] is
        -- centred on box.y. Keep it clear of the word below; the rule sits just
        -- under the text and the caret points down at the word (never onto it).
        local baseline = h.box.y + (sz.y_top - sz.y_bottom) / 2
        baseline = math.floor(math.min(baseline, word_top - 1 - sz.y_bottom) + 0.5)
        -- Rule sits below the text's descenders with 1px padding (never onto the word).
        local marker_y = math.min(baseline + sz.y_bottom + GLOSS_RULE_GAP, word_top - CARET_DEPTH - 1)
        items[#items + 1] = {
            h = h, x0 = tx, x1 = tx + w, band = h.box.y,
            difficulty = h.difficulty or 5,
            marker_y = marker_y,
            baseline = baseline,
            word_cx = math.floor(h.box.x + h.box.w / 2 + 0.5),
        }
    end

    -- De-overlap: glosses on the same line (same band) can collide
    -- horizontally. Place them rarer-word-first (lower difficulty = more
    -- valuable) and drop any that would still overlap an already-placed gloss,
    -- keeping the page readable. Different lines sit in separate bands, so they
    -- never overlap vertically.
    table.sort(items, function(a, b)
        if a.band ~= b.band then return a.band < b.band end
        if a.difficulty ~= b.difficulty then return a.difficulty < b.difficulty end
        return a.x0 < b.x0
    end)
    local placed = {}  -- band -> list of {x0, x1}
    for _, it in ipairs(items) do
        if it.baseline > 2 then
            local list = placed[it.band]
            local fits = true
            if list then
                for _, iv in ipairs(list) do
                    if it.x0 < iv[2] + GLOSS_HGAP and it.x1 + GLOSS_HGAP > iv[1] then
                        fits = false
                        break
                    end
                end
            else
                list = {}
                placed[it.band] = list
            end
            if fits then
                list[#list + 1] = { it.x0, it.x1 }
                RenderText:renderUtf8Text(bb, it.x0, it.baseline, self.gloss_face,
                    it.h.text, true, false, color)
                drawWordMarker(bb, it.x0, it.x1, it.word_cx, it.marker_y, color)
            end
        end
    end
end

-- Recompute + repaint (interline change already repaints; this is for the
-- difficulty/enable toggles that don't relayout).
function WordWise:refresh()
    self:computePageHints()
    UIManager:setDirty("all", "ui")
end

function WordWise:setHintLevel(value)
    G_reader_settings:saveSetting("wordwise_hint_level", value)
    self:refresh()
end

function WordWise:setGlossFontSize(value)
    G_reader_settings:saveSetting("wordwise_gloss_font_size", value)
    -- rebuild the cached face; paintHints re-measures gloss widths from it
    self.gloss_face = Font:getFace("infofont", value)
    self:refresh()
end

function WordWise:setEnabled(on)
    if on and not self:hasDB() then
        UIManager:show(InfoMessage:new{
            text = _("No Word Wise dictionary found.\nPlace a dictionary (*.db) in:\n") .. WW_DIR,
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
        title = _("Toggle Word Wise hints"), reader = true,
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
            text = _("Show inline hints"),
            checked_func = function() return self:isEnabled() end,
            enabled_func = function() return self:isSupportedDocument() and self:hasDB() end,
            callback = function() self:setEnabled(not self:isEnabled()) end,
        },
        {
            text_func = function()
                return T(_("Hint level: %1"), self:getHintLevel())
            end,
            enabled_func = function() return self:isSupportedDocument() and self:hasDB() end,
            sub_item_table_func = function()
                local items = {}
                local labels = {
                    _("1 — only the rarest words"), _("2"), _("3"), _("4"),
                    _("5 — most hints"),
                }
                for d = 1, MAX_LEVEL do
                    items[d] = {
                        text = labels[d],
                        checked_func = function() return self:getHintLevel() == d end,
                        radio = true,
                        callback = function() self:setHintLevel(d) end,
                    }
                end
                return items
            end,
        },
        {
            text_func = function()
                return T(_("Hint font size: %1"), self:getGlossFontSize())
            end,
            enabled_func = function() return self:isSupportedDocument() and self:hasDB() end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                UIManager:show(SpinWidget:new{
                    title_text = _("Hint font size"),
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
