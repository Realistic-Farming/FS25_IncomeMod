-- =========================================================
-- FS25 Income Mod (version 2.1.5.0)
-- =========================================================
-- Author: TisonK
-- =========================================================
-- COPYRIGHT NOTICE:
-- All rights reserved. Unauthorized redistribution, copying,
-- or claiming this code as your own is strictly prohibited.
-- Original author: TisonK
-- =========================================================

---@class UIHelper
UIHelper = UIHelper or {}

-- =========================================================
-- Internal helpers
-- =========================================================

local function getText(key)
    local text = g_i18n:getText(key)
    if text == nil or text == "" then
        Logging.warning("im: Missing translation for key: " .. tostring(key))
        return key
    end
    return text
end

-- Exposed as a module-level helper so SettingsUI can reuse it without
-- creating a separate global function that pollutes the namespace.
function UIHelper.getText(key)
    return getText(key)
end

-- =========================================================
-- Shared tooltip applicator
-- Both binary and multi options use identical tooltip logic.
-- =========================================================

local function applyTooltip(row, opt, lbl, tooltipText)
    if opt.setToolTipText then opt:setToolTipText(tooltipText) end
    if lbl and lbl.setToolTipText then lbl:setToolTipText(tooltipText) end
    opt.toolTipText = tooltipText
    if lbl then lbl.toolTipText = tooltipText end
    if row.setToolTipText then row:setToolTipText(tooltipText) end
    row.toolTipText = tooltipText
    if opt.elements and opt.elements[1] and opt.elements[1].setText then
        opt.elements[1]:setText(tooltipText)
    end
end

-- =========================================================
-- Section Header
-- =========================================================

function UIHelper.createSection(layout, textId)
    local section = nil
    for _, el in ipairs(layout.elements) do
        if el.name == "sectionHeader" then
            section = el:clone(layout)
            section.id = nil
            section:setText(getText(textId))
            layout:addElement(section)
            break
        end
    end
    return section
end

-- =========================================================
-- Description Row
-- =========================================================

function UIHelper.createDescription(layout, textId)
    local template = nil
    for _, el in ipairs(layout.elements) do
        if el.elements and #el.elements >= 2 then
            local secondChild = el.elements[2]
            if secondChild.setText then
                template = secondChild
                break
            end
        end
    end

    if not template then
        Logging.warning("im: Description template not found!")
        return nil
    end

    local desc = template:clone(layout)
    desc.id = nil

    if desc.setText then
        desc:setText(getText(textId))
    end
    if desc.textSize then
        desc.textSize = desc.textSize * 0.85
    end
    if desc.textColor then
        desc.textColor = { 0.7, 0.7, 0.7, 1 }
    end

    layout:addElement(desc)
    return desc
end

-- =========================================================
-- Binary Option (checkbox-style)
-- =========================================================
-- Like MultiTextOptionElement, CheckedOptionElement's GuiElement base
-- calls self[callbackName](self.target, ...) directly (raiseCallback),
-- it does NOT look the string up on self.target. Assigning a string here
-- ("handleChange") made GuiElement try to call that string as a function
-- on every update tick -> "attempt to call a string value" spam in
-- GuiElement.lua:1638. onClickCallback must be a function, same as the
-- multi-option below.

function UIHelper.createBinaryOption(layout, id, textId, state, callback)
    local template = nil

    for _, el in ipairs(layout.elements) do
        if el.elements and #el.elements >= 2 then
            local firstChild = el.elements[1]
            if firstChild.id and (
                string.find(firstChild.id, "^check") or
                string.find(firstChild.id, "Check")
            ) then
                template = el
                break
            end
        end
    end

    if not template then
        Logging.warning("im: BinaryOption template not found!")
        return nil
    end

    local row = template:clone(layout)
    row.id = nil

    local opt = row.elements[1]
    local lbl = row.elements[2]

    opt.id = nil
    if lbl then lbl.id = nil end

    if opt.toolTipText then opt.toolTipText = "" end
    if lbl and lbl.toolTipText then lbl.toolTipText = "" end

    -- GIANTS calls onClickCallback(target, element) where element is the
    -- CheckedOptionElement itself. Read element.isChecked / element.state
    -- (2 = checked) the same way createMultiOption reads element.state.
    opt.target = nil
    opt.onClickCallback = function(_, element)
        if not callback then return end
        local checked
        if type(element) == "table" then
            if element.isChecked ~= nil then
                checked = element.isChecked
            elseif element.state ~= nil then
                checked = (element.state == 2)
            end
        end
        if checked ~= nil then
            callback(checked)
        end
    end

    if lbl and lbl.setText then
        lbl:setText(getText(textId .. "_short"))
    end

    layout:addElement(row)

    if opt.setState then
        opt:setState(1)
    end

    if state then
        if opt.setIsChecked then
            opt:setIsChecked(true)
        elseif opt.setState then
            opt:setState(2)
        end
    end

    applyTooltip(row, opt, lbl, getText(textId .. "_long"))

    return opt
end

-- =========================================================
-- Multi-value Option (MultiTextOption style)
-- =========================================================
-- MultiTextOptionElement dispatches via GuiElement:raiseCallback, which calls:
--   onClickCallback(self.target, element)
-- where element is the MultiTextOptionElement table (NOT the integer index).
-- The selected index lives at element.state. onClickCallback must be a
-- function — using a string caused "attempt to call a string value" every frame.

function UIHelper.createMultiOption(layout, id, textId, options, state, callback)
    local template = nil

    for _, el in ipairs(layout.elements) do
        if el.elements and #el.elements >= 2 then
            local firstChild = el.elements[1]
            if firstChild.id and string.find(firstChild.id, "^multi") then
                template = el
                break
            end
        end
    end

    if not template then
        Logging.warning("im: MultiOption template not found!")
        return nil
    end

    local row = template:clone(layout)
    row.id = nil

    local opt = row.elements[1]
    local lbl = row.elements[2]

    opt.id     = nil
    opt.target = nil
    if lbl then lbl.id = nil end

    if opt.toolTipText then opt.toolTipText = "" end
    if lbl and lbl.toolTipText then lbl.toolTipText = "" end

    if opt.setTexts then
        opt:setTexts(options)
    end
    -- Explicitly set the cycle count in case the cloned template's numTexts
    -- differs from the number of options we just provided via setTexts.
    opt.numTexts = #options

    -- GIANTS calls onClickCallback(target, element) where element is the
    -- MultiTextOptionElement itself (not the integer state). Read element.state
    -- to get the 1-based selected index.
    opt.onClickCallback = function(_, element)
        if not callback then return end
        local idx = type(element) == "number" and element
                 or (type(element) == "table" and element.state)
        if idx ~= nil then
            callback(idx)
        end
    end

    if lbl and lbl.setText then
        lbl:setText(getText(textId .. "_short"))
    end

    layout:addElement(row)

    -- Set state AFTER addElement so any internal FS25 layout-pass re-init
    -- that might reset element state has already happened.
    if opt.setState then
        opt:setState(state)
    end

    applyTooltip(row, opt, lbl, getText(textId .. "_long"))

    return opt
end
