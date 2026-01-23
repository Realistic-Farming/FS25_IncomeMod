---@class UIHelper
UIHelper = {}

-- Безпечне отримання тексту локалізації
local function getTextSafe(key)
    local text = g_i18n:getText(key)
    if text == nil or text == "" then
        Logging.warning("RHM: Missing translation for key: " .. tostring(key))
        return key
    end
    return text
end

function UIHelper.createSection(layout, textId)
    local section = nil
    for _, el in ipairs(layout.elements) do
        if el.name == "sectionHeader" then
            section = el:clone(layout)
            section.id = nil
            section:setText(getTextSafe(textId))
            layout:addElement(section)
            break
        end
    end
    return section
end

function UIHelper.createDescription(layout, textId)
    -- Створюємо текстовий елемент з описом
    local template = nil
    
    -- Шукаємо текстовий елемент (label)
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
        Logging.warning("RHM: Description template not found!")
        return nil
    end
    
    -- Клонуємо template
    local desc = template:clone(layout)
    desc.id = nil
    
    -- Встановлюємо текст
    if desc.setText then
        desc:setText(getTextSafe(textId))
    end
    
    -- Встановлюємо меншій шрифт та сірий колір для опису
    if desc.textSize then
        desc.textSize = desc.textSize * 0.85
    end
    
    if desc.textColor then
        desc.textColor = {0.7, 0.7, 0.7, 1} -- сірий колір
    end
    
    layout:addElement(desc)
    return desc
end


function UIHelper.createBinaryOption(layout, id, textId, state, callback)
    local template = nil
    
    -- Шукаємо шаблон
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
        Logging.warning("RHM: BinaryOption template not found!")
        return nil 
    end
    
    local row = template:clone(layout)
    row.id = nil
    
    local opt = row.elements[1]
    local lbl = row.elements[2]
    
    -- Очищаємо ID та target
    opt.id = nil
    opt.target = nil
    if lbl then lbl.id = nil end
    
    -- Очищаємо старі tooltips від template
    if opt.toolTipText then opt.toolTipText = "" end
    if lbl and lbl.toolTipText then lbl.toolTipText = "" end
    
    -- Callback - ПРЯМЕ ПРИСВОЄННЯ (не перевіряємо if)
    -- Аргументи приходять у зворотному порядку!
    -- Перший аргумент: newState (число), другий: element (таблиця)
    opt.onClickCallback = function(newState, element)
        -- newState це число (1 або 2)
        local isChecked = (newState == 2)
        callback(isChecked)
    end
    
    -- Встановлюємо тексти
    if lbl and lbl.setText then
        lbl:setText(getTextSafe(textId .. "_short"))
    end
    
    -- Додаємо елемент В ПЕРШУ ЧЕРГУ
    layout:addElement(row)
    
    -- КРИТИЧНО: Спочатку скидаємо state до базового
    if opt.setState then
        opt:setState(1) -- Спочатку завжди unchecked
    end
    
    -- ТЕПЕР встановлюємо потрібний state
    if state then
        -- Використовуємо setIsChecked якщо доступний (правильніший спосіб)
        if opt.setIsChecked then
            opt:setIsChecked(true)
        elseif opt.setState then
            opt:setState(2)
        end
    end
    
    -- ТЕПЕР встановлюємо tooltip (ПІСЛЯ додавання до layout)
    local tooltipText = getTextSafe(textId .. "_long")
    
    -- Спосіб 1: через метод setToolTipText
    if opt.setToolTipText then
        opt:setToolTipText(tooltipText)
    end
    if lbl and lbl.setToolTipText then
        lbl:setToolTipText(tooltipText)
    end
    
    -- Спосіб 2: пряме присвоєння властивості
    opt.toolTipText = tooltipText
    if lbl then
        lbl.toolTipText = tooltipText
    end
    
    -- Спосіб 3: встановлюємо на весь row
    if row.setToolTipText then
        row:setToolTipText(tooltipText)
    end
    row.toolTipText = tooltipText
    
    -- Спосіб 4 (FS25 side description style): встановити текст на перший child елемент самого контролу
    if opt.elements and opt.elements[1] and opt.elements[1].setText then
        opt.elements[1]:setText(tooltipText)
    end
    
    return opt
end

function UIHelper.createMultiOption(layout, id, textId, options, state, callback)
    local template = nil
    
    -- Шукаємо шаблон MultiTextOption
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
        Logging.warning("RHM: MultiOption template not found!")
        return nil 
    end
    
    local row = template:clone(layout)
    row.id = nil
    
    local opt = row.elements[1]
    local lbl = row.elements[2]
    
    -- Очищаємо ID та target
    opt.id = nil
    opt.target = nil
    if lbl then lbl.id = nil end
    
    -- Очищаємо старі tooltips від template
    if opt.toolTipText then opt.toolTipText = "" end
    if lbl and lbl.toolTipText then lbl.toolTipText = "" end
    
    -- Встановлюємо опції
    if opt.setTexts then
        opt:setTexts(options)
    end
    
    if opt.setState then
        opt:setState(state)
    end
    
    -- Callback - ПРЯМЕ ПРИСВОЄННЯ (не перевір яємо if)
    -- Аргументи приходять у зворотному порядку!
    -- Перший аргумент: newState (число - індекс опції), другий: element (таблиця)
    opt.onClickCallback = function(newState, element)
        -- newState це число - індекс вибраної опції (1, 2, 3, ...)
        callback(newState)
    end
    
    -- Встановлюємо тексти
    if lbl and lbl.setText then
        lbl:setText(getTextSafe(textId .. "_short"))
    end
    
    -- Додаємо елемент В ПЕРШУ ЧЕРГУ
    layout:addElement(row)
    
    -- ТЕПЕР встановлюємо tooltip (ПІСЛЯ додавання до layout)
    local tooltipText = getTextSafe(textId .. "_long")
    
    -- Спосіб 1: через метод setToolTipText
    if opt.setToolTipText then
        opt:setToolTipText(tooltipText)
    end
    if lbl and lbl.setToolTipText then
        lbl:setToolTipText(tooltipText)
    end
    
    -- Спосіб 2: пряме присвоєння властивості
    opt.toolTipText = tooltipText
    if lbl then
        lbl.toolTipText = tooltipText
    end
    
    -- Спосіб 3: встановлюємо на весь row
    if row.setToolTipText then
        row:setToolTipText(tooltipText)
    end
    row.toolTipText = tooltipText
    
    -- Спосіб 4 (FS25 side description style): встановити текст на перший child елемент самого контролу
    -- Саме так працює в референсному моді MudSystemSettings
    if opt.elements and opt.elements[1] and opt.elements[1].setText then
        opt.elements[1]:setText(tooltipText)
    end
    
    print(string.format("RHM: Set tooltip for %s: %s", textId, tooltipText))
    
    return opt
end