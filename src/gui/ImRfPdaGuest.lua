-- =========================================================
-- ImRfPdaGuest - Esc RF PDA Income framework (Table shell)
-- Stage-8 densify 2026-08-05 (Samantha DESIGN Option B + George ENGINE ACK).
-- Soft-detect: mission.incomeManager then g_IncomeManager.
-- Read-only; no money writes. History ring capped at 10; Esc paints 8.
-- =========================================================

ImRfPdaGuest = {}

local MOD_DIR = g_currentModDirectory
local MOD_NAME = g_currentModName
local PANEL_ID = "income"
local PANEL_ORDER = 50
local MAX_ROWS = 8
local HISTORY_CAP = 10
local _registered = false

local function tr(key, fallback)
    local modEnv = g_modEnvironments and g_modEnvironments[MOD_NAME]
    local i18n = (modEnv and modEnv.i18n) or g_i18n
    if i18n then
        local ok, text = pcall(function() return i18n:getText(key) end)
        if ok and type(text) == "string" and text ~= "" then
            local lower = text:lower()
            if lower ~= tostring(key):lower()
                and text ~= ("$l10n_" .. key)
                and not lower:find("^missing%s")
                and not lower:find("^missing_")
            then
                return text
            end
        end
    end
    return fallback or key
end

local function getHost()
    if g_currentMission ~= nil and g_currentMission.rfEscModules ~= nil then
        return g_currentMission.rfEscModules
    end
    local env = getfenv(0)
    if env ~= nil and env.g_rfEscModules ~= nil then
        return env.g_rfEscModules
    end
    if RfEscModules ~= nil then
        return RfEscModules.getOrCreate()
    end
    return nil
end

local function getHostPage()
    if g_inGameMenu == nil then return nil end
    return g_inGameMenu.menuRealisticFarming
end

local function findDescendant(root, id)
    if root == nil or id == nil then return nil end
    if root.getDescendantById then
        local el = root:getDescendantById(id)
        if el ~= nil then return el end
    end
    local page = getHostPage()
    if page and page.getDescendantById then
        return page:getDescendantById(id)
    end
    return nil
end

local function setText(el, text)
    if el ~= nil and type(el.setText) == "function" then el:setText(text or "") end
end

local function setVis(el, visible)
    if el ~= nil and type(el.setVisible) == "function" then el:setVisible(visible) end
end

local function formatMoney(amount)
    if amount == nil then return "--" end
    if g_i18n and g_i18n.formatMoney then return g_i18n:formatMoney(amount, 0, true, true) end
    return string.format("%.0f", amount)
end

local function paintSide(container, key, fallback)
    setVis(findDescendant(container, "wcSideInfoShell"), false)
    setVis(findDescendant(container, "mdSideInfoShell"), false)
    local shell = findDescendant(container, "rfSideInfoShell")
    local body = findDescendant(container, "rfSideInfoBody")
    setVis(shell, true)
    setText(body, tr(key, fallback))
end


local function refreshFwAbs(container)
    local page = getHostPage()
    local host = findDescendant(container, "rfHostPlaceholder") or (page and page.rfHostPlaceholder)
    local shell = findDescendant(container, "rfFrameworkGlanceShell")
    local status = findDescendant(container, "rfFwStatusBlock")
    local tableBlock = findDescendant(container, "rfFwTableBlock")
    for _, el in ipairs({ host, shell, status, tableBlock }) do
        if el ~= nil and type(el.updateAbsolutePosition) == "function" then
            el:updateAbsolutePosition()
        end
    end
end

local function clearHostDupes(container)
    setText(findDescendant(container, "rfHostBody"), "")
    setText(findDescendant(container, "rfHostTitle"), "")
    setText(findDescendant(container, "rfHostBlurb"), "")
    setVis(findDescendant(container, "rfHostTitle"), false)
    setVis(findDescendant(container, "rfHostBlurb"), false)
end

local function showTableMode(container)
    setVis(findDescendant(container, "rfFrameworkGlanceShell"), true)
    setVis(findDescendant(container, "rfFwStatusBlock"), false)
    setVis(findDescendant(container, "rfFwTableBlock"), true)
    refreshFwAbs(container)
end

local function labeled(label, value)
    local lbl = tostring(label or ""):gsub(":%s*$", "")
    return string.format("%s: %s", lbl, tostring(value or "--"))
end

local function getMgr()
    if g_currentMission ~= nil and g_currentMission.incomeManager ~= nil then
        return g_currentMission.incomeManager
    end
    return g_IncomeManager
end

local function clearRows(container)
    for i = 1, MAX_ROWS do
        for _, c in ipairs({"A", "B", "C", "D"}) do
            local el = findDescendant(container, "rfFwRow" .. i .. c)
            setVis(el, false)
            setText(el, "")
        end
    end
end

local function paintHeaders(container)
    setText(findDescendant(container, "rfFwColA"), tr("im_rf_pda_col_day", "Day"))
    setText(findDescendant(container, "rfFwColB"), tr("im_rf_pda_col_time", "Time"))
    setText(findDescendant(container, "rfFwColC"), tr("im_rf_pda_col_type", "Type"))
    setText(findDescendant(container, "rfFwColD"), tr("im_rf_pda_col_amount", "Amount"))
end

local function optionalHint(s)
    if s == nil then return "" end
    local parts = {}
    if type(s.getDifficultyName) == "function" then
        local d = s:getDifficultyName()
        if d ~= nil and tostring(d) ~= "" then
            parts[#parts + 1] = labeled(tr("im_rf_pda_lbl_difficulty", "Difficulty"), d)
        end
    end
    if type(s.getMultiplierName) == "function" then
        local m = s:getMultiplierName()
        if m ~= nil and tostring(m) ~= "" then
            parts[#parts + 1] = labeled(tr("im_rf_pda_lbl_multiplier", "Multiplier"), m)
        end
    end
    if s.seasonalEffects ~= nil then
        local season = s.seasonalEffects and tr("im_rf_pda_on", "On") or tr("im_rf_pda_off", "Off")
        parts[#parts + 1] = labeled(tr("im_rf_pda_lbl_seasonal", "Seasonal"), season)
    end
    if #parts == 0 then return "" end
    return table.concat(parts, "  ·  ")
end

function ImRfPdaGuest.onShow(container, lightOnly)
    clearHostDupes(container)
    showTableMode(container)
    paintSide(container, "rf_pda_side_info_income",
        "Passive income glance: on/off, pay mode, amount, next payment.\n"
        .. "Table = recent payments (last 10 kept; Esc shows 8). Esc never moves money.")
    paintHeaders(container)

    local titleEl = findDescendant(container, "rfFwTableTitle")
    local moreEl = findDescendant(container, "rfFwMore")
    local hintEl = findDescendant(container, "rfFwHintTable")
    local emptyEl = findDescendant(container, "rfFwEmptyHint")

    local mgr = getMgr()
    local s = mgr and mgr.settings
    local sys = mgr and mgr.incomeSystem
    if mgr == nil or s == nil then
        setVis(titleEl, true)
        setText(titleEl, tr("im_rf_pda_waiting", "Income manager not ready"))
        clearRows(container)
        setVis(emptyEl, false)
        setText(emptyEl, "")
        setText(moreEl, "")
        setText(hintEl, "")
        return
    end

    local onOff = s.enabled and tr("im_rf_pda_on", "On") or tr("im_rf_pda_off", "Off")
    local modeName = "--"
    if type(s.getPayModeName) == "function" then modeName = s:getPayModeName() or "--" end
    local amount = "--"
    if type(s.getPaymentAmount) == "function" then amount = formatMoney(s:getPaymentAmount()) end
    -- Summary band: Income On/Off · mode · amount (Samantha title slot; door exempts income title hide).
    local summary = string.format("%s: %s  ·  %s  ·  %s",
        tr("im_rf_pda_lbl_enabled", "Income"), onOff, modeName, amount)
    setVis(titleEl, true)
    setText(titleEl, summary)

    local nextPay = "--"
    if sys ~= nil and sys.isInitialized and type(sys.getNextPaymentInfo) == "function" then
        nextPay = sys:getNextPaymentInfo() or "--"
    elseif sys == nil or not sys.isInitialized then
        nextPay = tr("im_rf_pda_waiting_init", "waiting")
    end

    local history = (sys and sys.paymentHistory) or {}
    local n = #history
    local total = 0
    for _, e in ipairs(history) do total = total + (tonumber(e.amount) or 0) end
    local avg = n > 0 and (total / n) or 0

    local moreParts = {}
    moreParts[#moreParts + 1] = labeled(tr("im_rf_pda_lbl_next", "Next payment"), nextPay)
    if n == 0 then
        moreParts[#moreParts + 1] = labeled(tr("im_rf_pda_lbl_recent", "Recent ring"), tr("im_rf_pda_no_history", "no payments yet"))
    else
        moreParts[#moreParts + 1] = string.format("%s: %s  ·  avg %s  (%d of %d)",
            tr("im_rf_pda_lbl_recent", "Recent ring"), formatMoney(total), formatMoney(avg), n, HISTORY_CAP)
    end
    moreParts[#moreParts + 1] = tr("im_rf_pda_cap_note", "System keeps last 10 payments only (true data cap).")
    if n > MAX_ROWS then
        moreParts[#moreParts + 1] = string.format(tr("im_rf_pda_showing_of", "Showing %d of %d"), MAX_ROWS, n)
    end
    setText(moreEl, table.concat(moreParts, "  ·  "))
    setText(hintEl, optionalHint(s))

    if n == 0 then
        clearRows(container)
        setVis(emptyEl, true)
        setText(emptyEl, tr("im_rf_pda_no_history", "no payments yet"))
        return
    end

    setVis(emptyEl, false)
    setText(emptyEl, "")
    local show = math.min(n, MAX_ROWS)
    for i = 1, MAX_ROWS do
        local a = findDescendant(container, "rfFwRow" .. i .. "A")
        local b = findDescendant(container, "rfFwRow" .. i .. "B")
        local c = findDescendant(container, "rfFwRow" .. i .. "C")
        local d = findDescendant(container, "rfFwRow" .. i .. "D")
        if i <= show then
            local e = history[i]
            local day = tonumber(e and e.day)
            local hour = tonumber(e and e.hour) or 0
            local payType = (e and e.payType) or "?"
            setVis(a, true); setVis(b, true); setVis(c, true); setVis(d, true)
            setText(a, day ~= nil and string.format("Day %d", day) or "--")
            setText(b, string.format("%02d:00", hour))
            setText(c, tostring(payType))
            setText(d, formatMoney(e and e.amount))
        else
            setVis(a, false); setVis(b, false); setVis(c, false); setVis(d, false)
            setText(a, ""); setText(b, ""); setText(c, ""); setText(d, "")
        end
    end
end

function ImRfPdaGuest.onHide() end

function ImRfPdaGuest.tryRegister()
    if RfEscBootstrap ~= nil then
        if MOD_DIR == nil then
            print("[Income] ImRfPdaGuest: WARNING MOD_DIR nil - cannot ensureDoor")
        else
            local doorOk = RfEscBootstrap.ensureDoor(MOD_DIR, {
                profilesXml = MOD_DIR .. "xml/gui/rfEscProfiles.xml",
                iconPath = "textures/ui/menuIcon.dds",
            })
            if not doorOk then print("[Income] ImRfPdaGuest: WARNING ensureDoor failed (will retry)") end
        end
    end
    local host = getHost()
    local registerFn = host and (host.registerModule or host.registerPanel)
    if host == nil or registerFn == nil then return false end
    if not _registered then
        local ok = registerFn(host, {
            id = PANEL_ID,
            title = tr("im_rf_pda_module_title", "Income"),
            blurb = tr("im_rf_pda_blurb", "Passive income glance: on/off, pay mode, amount, next payment, recent payment table."),
            order = PANEL_ORDER,
            isAvailable = function() return getMgr() ~= nil end,
            onShow = ImRfPdaGuest.onShow,
            onHide = ImRfPdaGuest.onHide,
        })
        if ok then
            _registered = true
            print("[Income] ImRfPdaGuest: registered module income on rfEscModules")
        else
            return false
        end
    end
    return _registered and g_inGameMenu ~= nil and g_inGameMenu.menuRealisticFarming ~= nil
end

function ImRfPdaGuest.isRegistered() return _registered end
function ImRfPdaGuest.reset() _registered = false end
