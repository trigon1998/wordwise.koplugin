--[[
    Word Wise Hint Dialog for KOReader
    Provides multi-sense pagination, CEFR typography, fixed footer,
    and KOReader native pagination controls (< Page X of Y >).
    Fixes hold/pan transparency and movement bugs.
--]]

local Button = require("ui/widget/button")
local ButtonTable = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("geom")
local HGroup = require("ui/widget/horizontalgroup")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local Screen = require("device").screen
local Size = require("ui/elements/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VGroup = require("ui/widget/verticalgroup")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

local WordWiseHintDialog = InputContainer:extend{
    word = "",
    lemma = "",
    current_sense = nil,
    senses = nil,
    is_known = false,
    on_select_sense = nil,
    on_toggle_known = nil,
    on_open_dict = nil,
    on_close = nil,

    -- UI dimensions & paging
    page_size = 2, -- number of alternative senses per page
    current_page = 1,
    total_pages = 1,
    is_closed = false,
}

function WordWiseHintDialog:init()
    self.senses = self.senses or {}
    self.total_pages = math.max(1, math.ceil(#self.senses / self.page_size))
    self.current_page = 1

    -- Set modal bounds to full screen to capture touch events outside dialog frame
    self.dimen = Geom:new{
        x = 0,
        y = 0,
        w = Screen:getWidth(),
        h = Screen:getHeight(),
    }

    self:buildDialog()

    if UIManager then
        UIManager:show(self)
        UIManager:setDirty(self, "ui")
    end
end

-- Safely close the dialog only once
function WordWiseHintDialog:closeDialog()
    if self.is_closed then return end
    self.is_closed = true

    if UIManager then
        UIManager:close(self)
    end

    if self.on_close then
        self.on_close()
    end
end

-- Rebuild dialog on page switch after releasing previous widget tree
function WordWiseHintDialog:gotoPage(page)
    if page < 1 or page > self.total_pages or page == self.current_page then
        return
    end

    self.current_page = page

    -- Free existing widget hierarchy recursively to prevent memory leaks
    self:free()

    -- Rebuild the widget hierarchy
    self:buildDialog()

    if UIManager then
        UIManager:setDirty(self, "ui")
    end
end

-- Constructs the popup layout
function WordWiseHintDialog:buildDialog()
    local screen_w = Screen:getWidth()
    local dialog_w = math.min(math.floor(screen_w * 0.90), math.floor(Size.border.window * 25 or 550))
    local padding = Size.padding.default

    local main_vgroup = VGroup:new{
        align = "left",
    }

    ----------------------------------------------------------------------------
    -- 1. HEADER: Word Wise title & active sense definition
    ----------------------------------------------------------------------------
    local header_title = TextWidget:new{
        text = "Word Wise: " .. (self.word or ""),
        face = Font:getFace("headerfont", 18),
        bold = true,
        padding = 0,
    }

    local current_def_text = ""
    if self.current_sense and self.current_sense.short_def then
        current_def_text = self.current_sense.short_def
    elseif #self.senses > 0 then
        current_def_text = self.senses[1].short_def or ""
    end

    local header_def = TextWidget:new{
        text = current_def_text,
        face = Font:getFace("infofont", 16),
        width = dialog_w - (padding * 4),
        padding = 0,
    }

    local header_container = VGroup:new{
        align = "left",
        padding = padding,
        header_title,
        header_def,
    }
    table.insert(main_vgroup, header_container)

    ----------------------------------------------------------------------------
    -- 2. PAGE CONTROLS: KOReader native chevron style (< Page X of Y >)
    ----------------------------------------------------------------------------
    table.insert(main_vgroup, LineWidget:new{ background = "gray", dimen = Geom:new{ w = dialog_w, h = Size.line.thin } })

    local page_text = string.format("Page %d of %d", self.current_page, self.total_pages)

    local btn_prev = Button:new{
        text = "<",
        font_size = 18,
        is_borderless = true,
        show_bg = false,
        enabled = (self.current_page > 1),
        padding = Size.padding.large,
        callback = function()
            self:gotoPage(self.current_page - 1)
        end,
    }

    local page_indicator = TextWidget:new{
        text = page_text,
        face = Font:getFace("infofont", 15),
        padding = Size.padding.large,
    }

    local btn_next = Button:new{
        text = ">",
        font_size = 18,
        is_borderless = true,
        show_bg = false,
        enabled = (self.current_page < self.total_pages),
        padding = Size.padding.large,
        callback = function()
            self:gotoPage(self.current_page + 1)
        end,
    }

    local nav_hgroup = HGroup:new{
        align = "center",
        btn_prev,
        page_indicator,
        btn_next,
    }

    local page_controls = CenterContainer:new{
        dimen = Geom:new{ w = dialog_w, h = Size.button.height },
        widget = nav_hgroup,
    }
    table.insert(main_vgroup, page_controls)

    table.insert(main_vgroup, LineWidget:new{ background = "gray", dimen = Geom:new{ w = dialog_w, h = Size.line.thin } })

    ----------------------------------------------------------------------------
    -- 3. CONTENT VIEWPORT: Fixed height list of sense rows
    ----------------------------------------------------------------------------
    local start_idx = (self.current_page - 1) * self.page_size + 1
    local end_idx = math.min(start_idx + self.page_size - 1, #self.senses)

    local row_height = math.floor(Size.button.height * 1.1)
    local viewport_h = row_height * self.page_size

    local senses_vgroup = VGroup:new{
        align = "left",
    }

    local rows_added = 0
    for i = start_idx, end_idx do
        local sense = self.senses[i]
        rows_added = rows_added + 1

        local sense_row = self:createSenseRow(sense, dialog_w - (padding * 2), row_height)
        table.insert(senses_vgroup, sense_row)

        if rows_added < self.page_size and i < end_idx then
            table.insert(senses_vgroup, LineWidget:new{ background = "lightgray", dimen = Geom:new{ w = dialog_w, h = Size.line.thin } })
        end
    end

    -- Add empty filler to maintain fixed viewport height on last page
    while rows_added < self.page_size do
        rows_added = rows_added + 1
        local dummy_filler = WidgetContainer:new{
            dimen = Geom:new{ w = dialog_w, h = row_height },
        }
        table.insert(senses_vgroup, dummy_filler)
        if rows_added < self.page_size then
            table.insert(senses_vgroup, LineWidget:new{ background = "transparent", dimen = Geom:new{ w = dialog_w, h = Size.line.thin } })
        end
    end

    local viewport_container = FrameContainer:new{
        padding = 0,
        margin = 0,
        bordersize = 0,
        dimen = Geom:new{ w = dialog_w, h = viewport_h },
        widget = senses_vgroup,
    }
    table.insert(main_vgroup, viewport_container)

    table.insert(main_vgroup, LineWidget:new{ background = "gray", dimen = Geom:new{ w = dialog_w, h = Size.line.thin } })

    ----------------------------------------------------------------------------
    -- 4. FOOTER: Fixed action buttons (Know/Show, Dictionary, Cancel)
    ----------------------------------------------------------------------------
    local know_btn_text = self.is_known and _("Show") or _("Know")

    local footer_buttons = {
        {
            {
                text = know_btn_text,
                callback = function()
                    if self.on_toggle_known then
                        self.on_toggle_known(self.lemma, not self.is_known)
                    end
                    self:closeDialog()
                end,
            },
            {
                text = _("Dictionary"),
                callback = function()
                    local word_to_lookup = self.word
                    self:closeDialog()
                    if self.on_open_dict then
                        self.on_open_dict(word_to_lookup)
                    end
                end,
            },
            {
                text = _("Cancel"),
                callback = function()
                    self:closeDialog()
                end,
            },
        }
    }

    local footer_table = ButtonTable:new{
        width = dialog_w,
        buttons = footer_buttons,
        zero_sep = true,
        show_parent = self,
    }
    table.insert(main_vgroup, footer_table)

    ----------------------------------------------------------------------------
    -- OUTER FRAME & MODAL POSITIONING
    ----------------------------------------------------------------------------
    local dialog_frame = FrameContainer:new{
        background = "white",
        bordersize = Size.border.window or 2,
        padding = 0,
        margin = 0,
        widget = main_vgroup,
    }

    -- Center the dialog on screen
    local frame_dim = dialog_frame:getSize()
    local pos_x = math.floor((screen_w - frame_dim.w) / 2)
    local pos_y = math.floor((Screen:getHeight() - frame_dim.h) / 2)

    self.dialog_frame = CenterContainer:new{
        dimen = Geom:new{
            x = pos_x,
            y = pos_y,
            w = frame_dim.w,
            h = frame_dim.h,
        },
        widget = dialog_frame,
    }

    self[1] = self.dialog_frame
end

-- Builds a single sense row with KOReader typography:
-- [CEFR] (POS): Definition
function WordWiseHintDialog:createSenseRow(sense, width, row_h)
    local cefr_text = sense.cefr_level or ""
    local pos_text = sense.pos and ("(" .. sense.pos .. ")") or ""
    local def_text = sense.short_def or ""

    local item_hgroup = HGroup:new{
        align = "center",
        padding = Size.padding.default,
    }

    -- CEFR level (Bold)
    if cefr_text ~= "" then
        table.insert(item_hgroup, TextWidget:new{
            text = cefr_text .. " ",
            face = Font:getFace("infofont", 16),
            bold = true,
            padding = 0,
        })
    end

    -- Part of Speech (Italic / In Parentheses)
    if pos_text ~= "" then
        table.insert(item_hgroup, TextWidget:new{
            text = pos_text .. ": ",
            face = Font:getFace("italicfont", 15),
            padding = 0,
        })
    end

    -- Definition (Regular)
    table.insert(item_hgroup, TextWidget:new{
        text = def_text,
        face = Font:getFace("infofont", 15),
        width = width - 120,
        padding = 0,
    })

    local row_container = InputContainer:new{
        dimen = Geom:new{ w = width, h = row_h },
        widget = CenterContainer:new{
            dimen = Geom:new{ w = width, h = row_h },
            widget = item_hgroup,
        },
    }

    function row_container:onTap(arg, gesture)
        if self.show_parent and self.show_parent.on_select_sense then
            self.show_parent.on_select_sense(sense.sense_key)
        end
        if self.show_parent then
            self.show_parent:closeDialog()
        end
        return true
    end

    row_container.show_parent = self
    return row_container
end

----------------------------------------------------------------------------
-- GESTURE HANDLING & BUG FIXES
----------------------------------------------------------------------------

-- Handle tap outside popup to close
function WordWiseHintDialog:onTap(arg, gesture)
    if not gesture or not gesture.pos then
        return false
    end

    local frame_box = self.dialog_frame and self.dialog_frame.dimen
    if frame_box then
        local px, py = gesture.pos.x, gesture.pos.y
        if px < frame_box.x or px > frame_box.x + frame_box.w or
           py < frame_box.y or py > frame_box.y + frame_box.h then
            self:closeDialog()
            return true
        end
    end
    return false
end

-- Fix: Consume hold/swipe gestures to prevent popup transparency & moving
function WordWiseHintDialog:onHold(arg, gesture)
    return true
end

function WordWiseHintDialog:onHoldPan(arg, gesture)
    return true
end

function WordWiseHintDialog:onSwipe(arg, gesture)
    return true
end

function WordWiseHintDialog:onPan(arg, gesture)
    return true
end

function WordWiseHintDialog:onClose()
    self:closeDialog()
end

return WordWiseHintDialog