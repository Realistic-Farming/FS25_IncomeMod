-- =========================================================
-- FS25 Income Mod (version 2.0.0.4)
-- =========================================================
-- Author: TisonK
-- =========================================================
-- COPYRIGHT NOTICE:
-- All rights reserved. Unauthorized redistribution, copying,
-- or claiming this code as your own is strictly prohibited.
-- Original author: TisonK
-- =========================================================

---@class UIHelper
UIHelper = {}

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

    -- FS25 requires target+method-string for callback dispatch.
    -- Assigning a raw function to onClickCallback while target=nil means
    -- the engine never fires it. Bridge table acts as the required target.
    -- FS25 safe bridge
    local Bridge = {}
    local Bridge_mt = Class(Bridge)

    function Bridge.new(callback)
        local self = setmetatable({}, Bridge_mt)
        self._callback = callback
        return self
    end

    function Bridge:handleChange(newState)
        if self._callback then
            self._callback(newState == 2)
        end
    end

    local bridge = Bridge.new(callback)
    opt.target = bridge
    opt.onClickCallback = "handleChange"

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

    local tooltipText = getText(textId .. "_long")

    if opt.setToolTipText then opt:setToolTipText(tooltipText) end
    if lbl and lbl.setToolTipText then lbl:setToolTipText(tooltipText) end
    opt.toolTipText = tooltipText
    if lbl then lbl.toolTipText = tooltipText end
    if row.setToolTipText then row:setToolTipText(tooltipText) end
    row.toolTipText = tooltipText

    if opt.elements and opt.elements[1] and opt.elements[1].setText then
        opt.elements[1]:setText(tooltipText)
    end

    return opt
end

-- =========================================================
-- Multi-value Option (MultiTextOption style)
-- =========================================================

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

    if opt.setState then
        opt:setState(state)
    end

    local bridge = {}
    bridge._callback = callback

    function bridge:handleChange(newState)
        if self._callback then
            self._callback(newState)
        end
    end

    opt.target = bridge
    opt.onClickCallback = "handleChange"

    if lbl and lbl.setText then
        lbl:setText(getText(textId .. "_short"))
    end

    layout:addElement(row)

    local tooltipText = getText(textId .. "_long")

    if opt.setToolTipText then opt:setToolTipText(tooltipText) end
    if lbl and lbl.setToolTipText then lbl:setToolTipText(tooltipText) end
    opt.toolTipText = tooltipText
    if lbl then lbl.toolTipText = tooltipText end
    if row.setToolTipText then row:setToolTipText(tooltipText) end
    row.toolTipText = tooltipText

    if opt.elements and opt.elements[1] and opt.elements[1].setText then
        opt.elements[1]:setText(tooltipText)
    end

    return opt
end
