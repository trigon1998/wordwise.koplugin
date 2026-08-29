local Blitbuffer = require("ffi/blitbuffer")
local BD = require("ui/bidi")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local ButtonTable = require("ui/widget/buttontable")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local T = require("ffi/util").template

local Screen = Device.screen
local SENSE_ROW_HEIGHT = Screen:scaleBySize(52)
local PAGE_BUTTON_HEIGHT = Screen:scaleBySize(42)
local ACTION_BUTTON_HEIGHT = Screen:scaleBySize(48)

local SenseRow = InputContainer:extend{
    width = 0,
    height = SENSE_ROW_HEIGHT,
    font_size = nil,
    selected = false,
    entry = nil,
    on_select = nil,
}

function SenseRow:init()
    local pad_h = Screen:scaleBySize(12)
    local pad_v = Screen:scaleBySize(4)
    local inner_width = math.max(Screen:scaleBySize(40), self.width - 2 * pad_h)
    local cefr_face = Font:getFace("infofont")
    local regular_face = Font:getFace("infofont")
    local italic_face = Font:getFace("NotoSans-Italic.ttf")
    local cefr = TextWidget:new{
        text = self.entry.cefr_level or "",
        face = cefr_face,
        bold = self.selected,
        padding = 0,
    }
    local open = TextWidget:new{text = " (", face = regular_face, padding = 0}
    local pos = TextWidget:new{
        text = self.entry.pos or "",
        face = italic_face,
        padding = 0,
    }
    local close = TextWidget:new{text = "): ", face = regular_face, padding = 0}
    local prefix = HorizontalGroup:new{align = "center", cefr, open, pos, close}
    local prefix_width = prefix:getSize().w
    local definition = TextBoxWidget:new{
        text = self.entry.gloss or "",
        face = regular_face,
        width = math.max(Screen:scaleBySize(20), inner_width - prefix_width),
        height = math.max(Screen:scaleBySize(20), self.height - 2 * pad_v),
        height_overflow_show_ellipsis = true,
        alignment = "left",
        alignment_strict = true,
        line_height = 0.15,
        bold = self.selected,
    }
    self[1] = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding_left = pad_h,
        padding_right = pad_h,
        padding_top = pad_v,
        padding_bottom = pad_v,
        dimen = Geom:new{w = self.width, h = self.height},
        HorizontalGroup:new{align = "center", prefix, definition},
    }
    self.ges_events.Tap = {
        GestureRange:new{
            ges = "tap",
            range = Geom:new{x = 0, y = 0, w = self.width, h = self.height},
        }
    }
end

function SenseRow:onTap()
    if self.on_select then self.on_select(self.entry) end
    return true
end

local HintDialog = InputContainer:extend{
    owner = nil,
    hint = nil,
    width_factor = 0.92,
    row_height = SENSE_ROW_HEIGHT,
}

function HintDialog:init()
    self._closed = false
    if Device:isTouchDevice() then
        self.ges_events.TapClose = {
            GestureRange:new{
                ges = "tap",
                range = Geom:new{x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight()},
            }
        }
    end
    if Device:hasKeys() then
        self.key_events.Close = {{ Device.input.group.Back }}
    end

    self.width = math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * self.width_factor)
    self.inner_width = self.width - 2 * Size.padding.button
    self.system_face = Font:getFace("infofont")
    self.popup_font_size = self.system_face.orig_size or self.system_face.size or Screen:scaleBySize(16)
    self.row_height = SENSE_ROW_HEIGHT
    self.regular_face = self.system_face
    self.title_face = self.system_face
    self.current_entry = self.hint.entry
    self.alternatives = {}
    local current_key = self.current_entry and self.current_entry.sense_key
    for _, entry in ipairs(self.hint.senses or {}) do
        local is_current = current_key and entry.sense_key == current_key
        if is_current or not self.owner:isSenseKnown(entry) then
            self.alternatives[#self.alternatives + 1] = entry
        end
    end
    self.page = 1
    self.page_size = self:calculatePageSize()
    self.page_count = math.max(1, math.ceil(#self.alternatives / self.page_size))
    self:_build()
end

function HintDialog:calculatePageSize()
    local dialog_budget = math.floor(Screen:getHeight() * 0.94)
    local title_height = math.floor(Screen:getHeight() * 0.17)
    local fixed_height = title_height
        + 2 * Size.line.medium
        + PAGE_BUTTON_HEIGHT
        + ACTION_BUTTON_HEIGHT
        + 2 * Size.border.window
        + Screen:scaleBySize(6)
    local available_height = math.max(self.row_height, dialog_budget - fixed_height)
    -- Each row except the last is followed by a separator in the viewport.
    return math.max(1, math.floor((available_height + Size.line.medium)
        / (self.row_height + Size.line.medium)))
end

function HintDialog:closeDialog()
    if self._closed then return end
    self._closed = true
    if self.owner._hint_dialog == self then self.owner._hint_dialog = nil end
    UIManager:close(self)
end

function HintDialog:pageLabel()
    return self.owner:tr("page_indicator", self.page, self.page_count)
end

function HintDialog:setPage(page)
    page = math.max(1, math.min(self.page_count, page))
    if page == self.page then return end
    self.page = page
    self:_rebuildContent()
    UIManager:setDirty(self, function() return "ui", self.dialog_frame.dimen end)
end

function HintDialog:_makeContent()
    local content = VerticalGroup:new{width = self.inner_width}
    local first = (self.page - 1) * self.page_size + 1
    local last = math.min(#self.alternatives, first + self.page_size - 1)
    for index = first, last do
        local entry = self.alternatives[index]
        table.insert(content, SenseRow:new{
            width = self.inner_width,
            height = self.row_height,
            font_size = self.popup_font_size,
            selected = current_key and entry.sense_key == current_key or false,
            entry = entry,
            on_select = function(selected)
                self.owner:setSelectedSense(selected)
                self:closeDialog()
            end,
        })
        if index < last then
            table.insert(content, LineWidget:new{
                background = Blitbuffer.COLOR_GRAY,
                dimen = Geom:new{w = self.inner_width, h = Size.line.medium},
            })
        end
    end
    -- Keep the content viewport height fixed, so the footer never moves when
    -- the last page has fewer rows than earlier pages.
    local content_height = self.page_size * self.row_height
        + math.max(0, self.page_size - 1) * Size.line.medium
    return FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        dimen = Geom:new{w = self.inner_width, h = content_height},
        content,
    }
end

function HintDialog:_makePageControls()
    local label_prev, label_next = "‹", "›"
    if BD.mirroredUILayout and BD.mirroredUILayout() then label_prev, label_next = label_next, label_prev end
    self.arrow_prev = label_prev
    self.arrow_next = label_next
    return ButtonTable:new{
        width = self.inner_width,
        buttons = {{
            {
                text = self.arrow_prev,
                font_face = "infofont",
                font_size = self.popup_font_size,
                font_bold = false,
                width = Screen:scaleBySize(52),
                height = PAGE_BUTTON_HEIGHT,
                enabled = self.page > 1,
                callback = function() self:setPage(self.page - 1) end,
            },
            {
                text = self:pageLabel(),
                font_face = "infofont",
                font_size = self.popup_font_size,
                font_bold = false,
                height = PAGE_BUTTON_HEIGHT,
                enabled = false,
                callback = function() end,
            },
            {
                text = self.arrow_next,
                font_face = "infofont",
                font_size = self.popup_font_size,
                font_bold = false,
                width = Screen:scaleBySize(52),
                height = PAGE_BUTTON_HEIGHT,
                enabled = self.page < self.page_count,
                callback = function() self:setPage(self.page + 1) end,
            },
        }},
        zero_sep = true,
        show_parent = self,
    }
end

function HintDialog:_makeActions()
    local function known()
        self.owner:setWordKnown(self.current_entry, not self.owner:isWordKnown(self.current_entry))
        self.owner:refresh()
        self:closeDialog()
    end
    local function dictionary()
        local box = self.hint.box
        self:closeDialog()
        if self.owner.ui.dictionary and self.owner.ui.dictionary.onLookupWord then
            self.owner.ui.dictionary:onLookupWord(self.hint.word, true, { box })
        end
    end
    return ButtonTable:new{
        width = self.inner_width,
        buttons = {{
            {
                text = self.owner:isWordKnown(self.current_entry) and self.owner:tr("show_short") or self.owner:tr("know_short"),
                font_face = "infofont",
                height = ACTION_BUTTON_HEIGHT,
                callback = known,
            },
            {
                text = self.owner:tr("dictionary_short"),
                font_face = "infofont",
                height = ACTION_BUTTON_HEIGHT,
                callback = dictionary,
            },
            {
                text = self.owner:tr("cancel"),
                font_face = "infofont",
                id = "close",
                height = ACTION_BUTTON_HEIGHT,
                callback = function() self:closeDialog() end,
            },
        }},
        zero_sep = true,
        show_parent = self,
    }
end

function HintDialog:_build()
    local title_text = T("Word Wise: %1", self.hint.word) .. "\n" .. (self.current_entry.gloss or self.hint.text or "")
    self.title_widget = TextBoxWidget:new{
        text = title_text,
        face = self.title_face,
        width = self.inner_width,
        height = math.floor(Screen:getHeight() * 0.17),
        height_overflow_show_ellipsis = true,
        alignment = "left",
        alignment_strict = true,
        line_height = 0.15,
    }
    self.page_controls = self:_makePageControls()
    self.content_viewport = self:_makeContent()
    self.action_table = self:_makeActions()
    self:_assemble()
end

function HintDialog:_rebuildContent()
    -- ButtonDialog uses this lifecycle pattern: recursively free the currently
    -- mounted tree before replacing it, so old TextWidgets, SenseRows and
    -- ButtonTables release their native resources instead of becoming orphans.
    self:free()
    self[1] = nil
    self.dialog_frame = nil
    self.title_widget = nil
    self.page_controls = nil
    self.content_viewport = nil
    self.action_table = nil
    self:_build()
end

function HintDialog:_assemble()
    local body = VerticalGroup:new{align = "left"}
    table.insert(body, self.title_widget)
    table.insert(body, LineWidget:new{
        background = Blitbuffer.COLOR_GRAY,
        dimen = Geom:new{w = self.inner_width, h = Size.line.medium},
    })
    table.insert(body, self.page_controls)
    table.insert(body, self.content_viewport)
    table.insert(body, LineWidget:new{
        background = Blitbuffer.COLOR_GRAY,
        dimen = Geom:new{w = self.inner_width, h = Size.line.medium},
    })
    table.insert(body, self.action_table)
    -- Keep the popup static. MovableContainer's default hold/hold_pan behavior
    -- changes alpha and moved offsets, which is not wanted for this dialog.
    self.dialog_frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.window,
        radius = Size.radius.window,
        padding = Size.padding.button,
        padding_top = 0,
        padding_bottom = 0,
        body,
    }
    self[1] = CenterContainer:new{
        dimen = Screen:getSize(),
        self.dialog_frame,
    }
end

function HintDialog:onShow()
    UIManager:setDirty(self, function()
        return "ui", self.dialog_frame.dimen
    end)
end

function HintDialog:onCloseWidget()
    if self.dialog_frame and self.dialog_frame.dimen then
        UIManager:setDirty(nil, function()
            return "ui", self.dialog_frame.dimen
        end)
    end
end

function HintDialog:onTapClose(_, ges)
    if self.dialog_frame and ges and ges.pos
            and ges.pos:notIntersectWith(self.dialog_frame.dimen) then
        self:onClose()
    end
    -- Only the tap-close event is consumed. Hold/pan/swipe are deliberately
    -- not registered here, so they cannot dim or move the popup.
    return true
end

function HintDialog:onClose()
    self:closeDialog()
    return true
end

return HintDialog
