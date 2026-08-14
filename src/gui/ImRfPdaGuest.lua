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

local _guiWarned = false

--- Move a shared shell element by pixel string, using the engine's own normalizer.
--- textSize / position are NORMALISED in FS25 (TextElement defaults to 0.03), so a raw
--- pixel number here would throw the layout across the screen. Nil-safe: if GuiUtils is
--- absent we skip the move and leave the XML baseline rather than guess.
local function setElPosPx(el, xPx, yPx)
    if el == nil or type(el.setPosition) ~= "function" then return false end
    if GuiUtils == nil or type(GuiUtils.getNormalizedXValue) ~= "function"
        or type(GuiUtils.getNormalizedYValue) ~= "function" then
        if not _guiWarned then
            _guiWarned = true
            print("[IncomeMod] ImRfPdaGuest: GuiUtils normalizer absent - leaving rfFwTableTitle at XML baseline")
        end
        return false
    end
    el:setPosition(GuiUtils.getNormalizedXValue(xPx, 0), GuiUtils.getNormalizedYValue(yPx, 0))
    if type(el.updateAbsolutePosition) == "function" then el:updateAbsolutePosition() end
    return true
end

-- ============================================================
-- BUILD 21:41: the column grid, applied every show.
-- ============================================================
-- All four Table guests (Income, Depot, Dairy, NPC Favor) paint into the SAME shared
-- elements, so whichever ran last leaves its geometry behind for the next one. Every guest
-- therefore has to state its own grid on entry rather than assume the XML baseline, or it
-- inherits the previous module's columns. This block is the even 4-bay.
--
-- Y IS HELD. Each move reads the element's own current Y and writes it straight back, and
-- setSize keeps the element's own height, so this can only ever change X and width.
--
-- Positions and sizes are NORMALISED in FS25, so everything goes through GuiUtils. A raw
-- pixel integer here would throw the row off the screen.
local FW_GRID_COLS = {
    { "A", "10px", "280px" },
    { "B", "310px", "280px" },
    { "C", "610px", "220px" },
    { "D", "850px", "280px" },
}
local FW_GRID_RULES = { "300px", "600px", "840px" }
local _fwGridWarned = false

local function applyFwGrid(container)
    if GuiUtils == nil or type(GuiUtils.getNormalizedXValue) ~= "function"
        or type(GuiUtils.getNormalizedScreenValues) ~= "function" then
        if not _fwGridWarned then
            _fwGridWarned = true
            print("[RF] applyFwGrid: GuiUtils normalizer absent - leaving the XML grid")
        end
        return
    end

    local function place(el, xPx, wPx)
        if el == nil then return end
        if type(el.setPosition) == "function" and el.position ~= nil then
            el:setPosition(GuiUtils.getNormalizedXValue(xPx, 0), el.position[2])
        end
        if wPx ~= nil and type(el.setSize) == "function" and el.size ~= nil then
            local norms = GuiUtils.getNormalizedScreenValues(wPx .. " 1px")
            if type(norms) == "table" and norms[1] ~= nil then
                el:setSize(norms[1], el.size[2])
            end
        end
        if type(el.updateAbsolutePosition) == "function" then el:updateAbsolutePosition() end
    end

    -- BUILD 21:54: this was ipairs over a table my generator had written with ",," between
    -- entries, which puts a nil at the skipped index. ipairs stops at the first nil, so only
    -- column A was ever placed and B, C and D stayed on the freeze XML while the rules moved
    -- anyway. A literal 1..4 walk cannot be truncated by a hole, and skipping a nil entry
    -- costs one column rather than throwing inside onShow.
    for i = 1, 4 do
        local c = FW_GRID_COLS[i]
        if c ~= nil then
            local letter, xPx, wPx = c[1], c[2], c[3]
            place(findDescendant(container, "rfFwCol" .. letter), xPx, wPx)
            for row = 1, 8 do
                place(findDescendant(container, "rfFwRow" .. row .. letter), xPx, wPx)
            end
        end
    end
    -- Vertical rules keep their own Y and their 1px width; only the column boundary moves.
    for i, xPx in ipairs(FW_GRID_RULES) do
        place(findDescendant(container, "rfFwRuleCol" .. i), xPx, nil)
    end
end

-- ============================================================
-- BUILD 22:15: optical centring, after the text exists.
-- ============================================================
-- Even-grid was dead on arrival as product: sliding a cell 15 to 45 px does not move where a
-- short left-glued word sits, so two builds of cell geometry changed nothing on screen. What
-- moves is the WORD, to the middle of its own bay, and the width of a word is only knowable
-- once setText has run.
--
-- The bay never changes. Only the element's X moves inside it, so a string that fills or
-- overflows its bay is left exactly where the freeze put it, and setSize is never called.
-- textAlignment and profiles are untouched by design.
local FW_OPTICAL_BOXES = {
    { "A", "10px", "280px" },
    { "B", "310px", "280px" },
    { "C", "610px", "220px" },
    { "D", "850px", "280px" }
}
local _opticalWarned = false

local function opticalCentreFwCells(container)
    if GuiUtils == nil or type(GuiUtils.getNormalizedXValue) ~= "function"
        or type(GuiUtils.getNormalizedScreenValues) ~= "function" then
        return
    end

    --- Centre one cell's text inside its bay, or leave the freeze X alone. Every refusal
    --- below is deliberate: a hidden or empty cell has nothing to centre, and a string that
    --- is as wide as its bay is already using all of it.
    local function centre(el, leftPx, widthPx)
        if el == nil then
            return
        end
        if type(el.getTextWidth) ~= "function" then
            if not _opticalWarned then
                _opticalWarned = true
                print("[RF] optical centre: getTextWidth absent - leaving the freeze X")
            end
            return
        end
        if el.visible == false then
            return
        end
        if type(el.text) ~= "string" or el.text == "" then
            return
        end
        local norms = GuiUtils.getNormalizedScreenValues(widthPx .. " 1px")
        if type(norms) ~= "table" or norms[1] == nil then
            return
        end
        local cellW = norms[1]
        local okW, textW = pcall(function() return el:getTextWidth() end)
        if not okW or type(textW) ~= "number" or textW <= 0 or textW >= cellW then
            return
        end
        if type(el.setPosition) == "function" and el.position ~= nil then
            local left = GuiUtils.getNormalizedXValue(leftPx, 0)
            el:setPosition(left + (cellW - textW) * 0.5, el.position[2])
            if type(el.updateAbsolutePosition) == "function" then el:updateAbsolutePosition() end
        end
    end

    for i = 1, 4 do
        local b = FW_OPTICAL_BOXES[i]
        if b ~= nil then
            centre(findDescendant(container, "rfFwCol" .. b[1]), b[2], b[3])
            for row = 1, 8 do
                centre(findDescendant(container, "rfFwRow" .. row .. b[1]), b[2], b[3])
            end
        end
    end
end

-- ============================================================
-- BUILD 07:06: the empty notice lives in the FIRST CELL, not across the sheet.
-- ============================================================
-- 22:32 fixed the vertical half of this and left the horizontal half wrong. The notice kept
-- the XML's 1120 box and was then optically centred inside it, so a left-aligned RF_HintText
-- painted its glyph run in the middle of the sheet and walked straight over rfFwRuleCol1 at
-- 300. Wizard's read is the plain one: the copy belongs in the first box, under DAY on Income
-- and under FILL on Depot.
--
-- So the box becomes bay A itself: the same 10 / 280 window rfFwColA and rfFwRow1A already
-- use, on the row-1 axis, one pitch high. Inner right edge is 290 against a rule at 300, which
-- is 10px of air, and that is exactly why this box is never nudged. A 280 box moved right is
-- a box that crosses the line Wizard is complaining about, so the X here is the freeze X and
-- nothing measures it. A string wider than the bay TRUNCATEs with an ellipsis; that is the
-- overflow valve, not a defect.
--
-- rfFwEmptyHint is ONE element behind all nine doors. Shrinking it is only safe because every
-- other page restores it, which is why Dairy and NPC Favor ship alongside this change.
--
-- ONE function owns X, Y, W, H and textMaxNumLines for both states. 22:32 split them and came
-- out correctly placed on one axis and wrong on the other.
local FW_HINT_X     = "10px"      -- sheet left and bay A left are the same edge
local FW_HINT_Y     = "-68px"     -- the row-1 glyph axis, same as rfFwRow1A
local FW_HINT_BAY_W = "280px"     -- bay A. 10 + 280 = 290, clear of rfFwRuleCol1 at 300
local FW_HINT_BAY_H = "22px"      -- 28 pitch less clearance: ends at -90, above the -92 rule
local FW_HINT_XML_W = "1120px"    -- the shared XML box, restored for every other page
local FW_HINT_XML_H = "44px"

--- Put rfFwEmptyHint in one of its two states and nothing in between.
--- "bay" is this page with an empty table: first cell, one line, truncating.
--- "xml" is every other case: the box exactly as RfPdaMenuPage.xml declares it.
local function setFwEmptyHintBox(container, mode)
    local el = findDescendant(container, "rfFwEmptyHint")
    if el == nil then
        return
    end
    if GuiUtils == nil or type(GuiUtils.getNormalizedXValue) ~= "function"
        or type(GuiUtils.getNormalizedYValue) ~= "function"
        or type(GuiUtils.getNormalizedScreenValues) ~= "function" then
        return
    end
    local bay = mode == "bay"
    -- Line count first. setSize re-runs the text layout, so the number of lines has to be
    -- true before the width it is measured against changes under it.
    el.textMaxNumLines = bay and 1 or 2
    local norms = GuiUtils.getNormalizedScreenValues(
        (bay and FW_HINT_BAY_W or FW_HINT_XML_W) .. " "
        .. (bay and FW_HINT_BAY_H or FW_HINT_XML_H))
    if type(norms) ~= "table" or norms[1] == nil or norms[2] == nil then
        return
    end
    if type(el.setSize) == "function" then
        el:setSize(norms[1], norms[2])
    end
    if type(el.setPosition) == "function" then
        el:setPosition(GuiUtils.getNormalizedXValue(FW_HINT_X, 0),
                       GuiUtils.getNormalizedYValue(FW_HINT_Y, 0))
        if type(el.updateAbsolutePosition) == "function" then el:updateAbsolutePosition() end
    end
end

--- Empty gets bay A, anything else gets the shared box back. This reads the element rather
--- than re-deriving the row count, so it stays in step with whichever refusal path inside
--- _paintShow actually ran.
local function placeFwEmptyHint(container)
    local el = findDescendant(container, "rfFwEmptyHint")
    local showing = el ~= nil and el.visible ~= false
        and type(el.text) == "string" and el.text ~= ""
    setFwEmptyHintBox(container, showing and "bay" or "xml")
end

function ImRfPdaGuest._paintShow(container, lightOnly)
    applyFwGrid(container)
    clearHostDupes(container)
    showTableMode(container)
    paintSide(container, "rf_pda_side_info_income",
        "Passive income glance: on/off, pay mode, amount, next payment.\n"
        .. "Table = recent payments (last 10 kept; Esc shows 8). Esc never moves money.")
    paintHeaders(container)

    local titleEl = findDescendant(container, "rfFwTableTitle")
    -- Wizard eyes-on: the On / mode / amount summary belongs at the BOTTOM of the page,
    -- not smashed under the page title. Sits below rfFwMore (-292) and rfFwHintTable (-328).
    -- Re-applied every show so returning from a sibling Table module cannot leave it high.
    --
    -- BUILD 21:16: X was 0, which left the summary hanging one card inset to the left of
    -- the rows above it. 10px is the same left edge every other cell in the framed block
    -- uses, so the footer reads as one flush stack rather than a stray line.
    setElPosPx(titleEl, "10px", "-360px")
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

--- Restore the shared Table title to its XML baseline.
--- rfFwTableTitle is shared with Dairy / Depot / NPCFavor, so Income must not leave it
--- at -360. NOTE: no host currently calls onHide (verified across the suite), which is
--- why each sibling guest also sets this id explicitly on its own onShow - that is what
--- actually prevents the bleed today. This stays correct for when onHide is wired.
function ImRfPdaGuest.onHide(container)
    if container == nil then return end
    -- BUILD 21:16: 0 / 0 was the PRE-16:32 baseline. The shared XML has put this title
    -- at 10 / -8 since the card inset landed, so handing it back to 0 / 0 restored it to a
    -- position that no longer exists.
    setElPosPx(findDescendant(container, "rfFwTableTitle"), "10px", "-8px")
end

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


--- BUILD 22:15: onShow is now a wrapper. The paint runs first and may return early on any
--- of its refusal paths; the optical pass then runs regardless, which is what puts the
--- centred copy on an EMPTY table as well as a full one.
function ImRfPdaGuest.onShow(container, lightOnly)
    ImRfPdaGuest._paintShow(container, lightOnly)
    opticalCentreFwCells(container)
    placeFwEmptyHint(container)
end
