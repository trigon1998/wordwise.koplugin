-- Word Wise hint popup.
--
-- Keep this as a thin specialization of KOReader's ButtonDialog. The first
-- paginated implementation replaced ButtonDialog with a hand-built input tree;
-- that changed the gesture path which had worked through v0.2.5 and caused
-- both hint-tap and popup interaction regressions.

local BD = require("ui/bidi")
local ButtonDialog = require("ui/widget/buttondialog")
local Device = require("device")
local Font = require("ui/font")
local Size = require("ui/size")
local UIManager = require("ui/uimanager")
local T = require("ffi/util").template

local Screen = Device.screen
local SENSE_ROW_HEIGHT = Screen:scaleBySize(52)
local PAGE_BUTTON_HEIGHT = Screen:scaleBySize(42)
local ACTION_BUTTON_HEIGHT = Screen:scaleBySize(48)

local HintDialog = ButtonDialog:extend{
    owner = nil,
    hint = nil,
    width_factor = 0.92,
    title_align = "left",
    use_info_style = true,
    dismissable = true,
}

function HintDialog:_collectEntries()
    self.current_entry = self.hint.entry
    self.current_key = self.current_entry and self.current_entry.sense_key
    self.entries = {}
    for _, entry in ipairs(self.hint.senses or {}) do
        if not self.owner:isSenseKnown(entry) then
            self.entries[#self.entries + 1] = entry
        end
    end

    -- A known-word filter should not normally remove the displayed entry, but
    -- retain it defensively so the title and selected row never disagree.
    if self.current_entry and #self.entries == 0 then
        self.entries[1] = self.current_entry
    end
end

function HintDialog:_calculatePageSize()
    local dialog_budget = math.floor(Screen:getHeight() * 0.94)
    local title_budget = math.floor(Screen:getHeight() * 0.17)
    local fixed_height = title_budget
        + PAGE_BUTTON_HEIGHT
        + ACTION_BUTTON_HEIGHT
        + 2 * Size.border.window
        + 2 * Size.padding.button
    return math.max(1, math.floor((dialog_budget - fixed_height) / SENSE_ROW_HEIGHT))
end

function HintDialog:_pageLabel()
    return self.owner:tr("page_indicator", self.page, self.page_count)
end

function HintDialog:_selectEntry(entry)
    self.owner:setSelectedSense(entry)
    self:closeDialog()
end

function HintDialog:_setPage(page)
    page = math.max(1, math.min(self.page_count, page))
    if page == self.page then return end
    self.page = page
    self:_preparePage()
    self:reinit()
    UIManager:setDirty(self, "ui")
end

function HintDialog:_makeSenseRows()
    local rows = {}
    local first = (self.page - 1) * self.page_size + 1
    local last = math.min(#self.entries, first + self.page_size - 1)
    for index = first, last do
        local entry = self.entries[index]
        local is_current = self.current_key ~= nil
            and entry.sense_key == self.current_key
        local cefr = entry.cefr_level or ""
        local pos = entry.pos and entry.pos ~= "" and (" (" .. entry.pos .. ")") or ""
        rows[#rows + 1] = {{
            text = string.format("%s%s: %s", cefr, pos, entry.gloss or ""),
            align = "left",
            height = SENSE_ROW_HEIGHT,
            padding_v = Screen:scaleBySize(4),
            avoid_text_truncation = true,
            text_font_face = "infofont",
            text_font_size = self.popup_font_size,
            text_font_bold = is_current,
            callback = function() self:_selectEntry(entry) end,
        }}
    end
    return rows
end

function HintDialog:_makePageRow()
    local icon_prev, icon_next = "chevron.left", "chevron.right"
    if BD.mirroredUILayout and BD.mirroredUILayout() then
        icon_prev, icon_next = icon_next, icon_prev
    end
    return {
        {
            icon = icon_prev,
            bordersize = 0,
            width = Screen:scaleBySize(52),
            height = PAGE_BUTTON_HEIGHT,
            enabled = self.page > 1,
            callback = function() self:_setPage(self.page - 1) end,
        },
        {
            text = self:_pageLabel(),
            bordersize = 0,
            height = PAGE_BUTTON_HEIGHT,
            text_font_face = "infofont",
            text_font_size = self.popup_font_size,
            text_font_bold = false,
            enabled = false,
            callback = function() end,
        },
        {
            icon = icon_next,
            bordersize = 0,
            width = Screen:scaleBySize(52),
            height = PAGE_BUTTON_HEIGHT,
            enabled = self.page < self.page_count,
            callback = function() self:_setPage(self.page + 1) end,
        },
    }
end

function HintDialog:_makeActionRow()
    return {
        {
            text = self.owner:isWordKnown(self.current_entry)
                and self.owner:tr("show_short") or self.owner:tr("know_short"),
            height = ACTION_BUTTON_HEIGHT,
            text_font_face = "infofont",
            text_font_size = self.popup_font_size,
            callback = function()
                self.owner:setWordKnown(self.current_entry,
                    not self.owner:isWordKnown(self.current_entry))
                self.owner:refresh()
                self:closeDialog()
            end,
        },
        {
            text = self.owner:tr("dictionary_short"),
            height = ACTION_BUTTON_HEIGHT,
            text_font_face = "infofont",
            text_font_size = self.popup_font_size,
            callback = function()
                local box = self.hint.box
                local word = self.hint.word
                self:closeDialog()
                if self.owner.ui.dictionary and self.owner.ui.dictionary.onLookupWord then
                    self.owner.ui.dictionary:onLookupWord(word, true, { box })
                end
            end,
        },
        {
            text = self.owner:tr("cancel"),
            id = "close",
            height = ACTION_BUTTON_HEIGHT,
            text_font_face = "infofont",
            text_font_size = self.popup_font_size,
            callback = function() self:closeDialog() end,
        },
    }
end

function HintDialog:_preparePage()
    self.title = T("Word Wise: %1", self.hint.word) .. "\n"
        .. (self.current_entry and self.current_entry.gloss or self.hint.text or "")
    self.buttons = self:_makeSenseRows()
    self.buttons[#self.buttons + 1] = self:_makePageRow()
    self.buttons[#self.buttons + 1] = self:_makeActionRow()
end

function HintDialog:init()
    if not self.entries then
        local info_face = Font:getFace("infofont")
        self.popup_font_size = info_face.orig_size or 24
        self.info_face = info_face
        self.page = 1
        self:_collectEntries()
        self.page_size = self:_calculatePageSize()
        self.page_count = math.max(1, math.ceil(#self.entries / self.page_size))
    end
    self:_preparePage()
    ButtonDialog.init(self)

    -- ButtonDialog wraps itself in a MovableContainer. KOReader enables hold,
    -- hold-pan and swipe movement there by default; for this popup those events
    -- are the reported opacity/movement bug, so make only this instance static.
    if self.movable then
        self.movable.ges_events = {}
        self.movable.unmovable = true
    end
end

function HintDialog:closeDialog()
    if self._closed then return end
    self._closed = true
    if self.owner._hint_dialog == self then self.owner._hint_dialog = nil end
    UIManager:close(self)
end

function HintDialog:onClose()
    self:closeDialog()
    return true
end

function HintDialog:onCloseWidget()
    if self.owner._hint_dialog == self then self.owner._hint_dialog = nil end
    return ButtonDialog.onCloseWidget(self)
end

return HintDialog
