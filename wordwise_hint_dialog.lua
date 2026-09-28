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
local MAX_POPUP_SENSES = 8

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
            if #self.entries < MAX_POPUP_SENSES or entry.sense_key == self.current_key then
                self.entries[#self.entries + 1] = entry
            end
        end
    end

    -- Keep the list compact, but never hide the currently displayed sense when
    -- it falls after the first page of dictionary results.
    if #self.entries > MAX_POPUP_SENSES then
        table.remove(self.entries, MAX_POPUP_SENSES)
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
        + self.page_button_height
        + self.action_button_height
        + 2 * Size.border.window
        + 2 * Size.padding.button
    return math.max(1, math.floor((dialog_budget - fixed_height) / self.sense_row_height))
end

function HintDialog:_pageLabel()
    return self.owner:tr("page_indicator", self.page, self.page_count)
end

function HintDialog:_selectEntry(entry)
    local owner = self.owner
    self:closeDialog()
    owner:setSelectedSense(entry)
end

function HintDialog:_selectCallback(entry)
    -- Bind the entry as a function argument so each row owns a distinct
    -- upvalue on LuaJIT/Lua 5.1; no callback can drift to another loop item.
    return function() self:_selectEntry(entry) end
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
            height = self.sense_row_height,
            avoid_text_truncation = true,
            font_face = "infofont",
            font_size = self.popup_font_size,
            font_bold = is_current,
            callback = self:_selectCallback(entry),
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
            height = self.page_button_height,
            enabled = self.page > 1,
            callback = function() self:_setPage(self.page - 1) end,
        },
        {
            text = self:_pageLabel(),
            bordersize = 0,
            height = self.page_button_height,
            font_face = "infofont",
            font_size = self.popup_font_size,
            font_bold = false,
            enabled = false,
            callback = function() end,
        },
        {
            icon = icon_next,
            bordersize = 0,
            width = Screen:scaleBySize(52),
            height = self.page_button_height,
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
            height = self.action_button_height,
            font_face = "infofont",
            font_size = self.popup_font_size,
            font_bold = false,
            callback = function()
                self.owner:setWordKnown(self.current_entry,
                    not self.owner:isWordKnown(self.current_entry))
                self.owner:refresh()
                self:closeDialog()
            end,
        },
        {
            text = self.owner:tr("dictionary_short"),
            height = self.action_button_height,
            font_face = "infofont",
            font_size = self.popup_font_size,
            font_bold = false,
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
            height = self.action_button_height,
            font_face = "infofont",
            font_size = self.popup_font_size,
            font_bold = false,
            callback = function() self:closeDialog() end,
        },
    }
end

function HintDialog:_preparePage()
    self.title = T("Word Wise: %1", self.hint.word) .. "\n"
        .. (self.current_entry
            and (self.current_entry.full_gloss or self.current_entry.gloss)
            or self.hint.text or "")
    self.buttons = self:_makeSenseRows()
    self.buttons[#self.buttons + 1] = self:_makePageRow()
    self.buttons[#self.buttons + 1] = self:_makeActionRow()
end

function HintDialog:init()
    if not self.entries then
        local reader_font = self.owner.ui and self.owner.ui.font
            and self.owner.ui.font.configurable
        self.popup_font_size = (reader_font and reader_font.font_size) or 24
        local info_face = Font:getFace("infofont", self.popup_font_size)
        self.info_face = info_face
        -- Fixed 52px rows forced Button to shrink large reader fonts. Grow the
        -- row budgets with the current book font so the requested size is kept.
        self.sense_row_height = math.max(SENSE_ROW_HEIGHT,
            Screen:scaleBySize(self.popup_font_size + 20))
        self.page_button_height = math.max(PAGE_BUTTON_HEIGHT,
            Screen:scaleBySize(self.popup_font_size + 14))
        self.action_button_height = math.max(ACTION_BUTTON_HEIGHT,
            Screen:scaleBySize(self.popup_font_size + 16))
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
