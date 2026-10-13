--!text: gui/IncomeReportDialog.xml
--!load: tools/test/lua/f282_environment_model.lua, src/ReleaseGate.lua, src/settings/SettingsManager.lua, src/settings/Settings.lua, src/IncomeSystem.lua, src/EmergencyLoan.lua, src/EmergencyLoanEvent.lua, src/IncomeSchedule.lua, tools/test/lua/im6_world.lua, src/settings/SettingsHubBridge.lua, src/settings/SettingsGUI.lua, src/settings/SettingsUI.lua, src/IncomeManager.lua, src/ui/IncomeHUD.lua, src/ui/IncomeReportDialog.lua, src/gui/ImRfPdaGuest.lua
-- IM6-B-readers_test.lua - R17 / IM-6 PR B: the readers and the gated typed amount control.
--
-- THE ENTRY-POINT BAR: every group stands on the world of im6_world.lua (the REAL
-- IncomeManager.new and onMissionLoaded on a dedicated host and its clients, the REAL
-- IncomeScheduleEvent over the stream tape both ways), and every reader is entered the
-- way production enters it:
--   HUD    the REAL IncomeHUD.new, then IncomeHUD:draw (the frame hook's call)
--   report the REAL IncomeReportDialog.getInstance, whose g_gui:loadGui the fixture
--          answers by building one element per id in the SHIPPED gui/IncomeReportDialog.xml
--          (as the engine's loader assigns ids to the target) and calling onCreate; then
--          onOpen, the dialog's own lifecycle entry
--   PDA    the REAL ImRfPdaGuest.tryRegister against an rfEscModules host, then the onShow
--          it registered
--   Esc    the REAL SettingsUI:inject, then the option callback it installed
-- No view, figure or text is placed in a reader by hand. The host's schedule differs from
-- every client's own settings file, so a reader that read local settings shows the wrong
-- mode, difficulty, multiplier and amount.
--
-- Groups:
--   A  the view carries what the readers show; a disabled schedule with an unknown month is
--      DISABLED with no estimate; a host change that moves only a reader field is republished
--   B  HUD: WAITING, then the host's values; the current seasonal adjustment, never a season
--      name; next payment from the host's mode; the every-farm row only when released
--   C  report: WAITING, then the host's summary and next payment; the gated estimate line
--   D  PDA: WAITING, then the host's summary and hints; the gated explanation
--   E  Esc typed amount (gated): hidden when locked; disabled for a non-admin; typed text
--      goes through host preview, confirm and apply; a legacy amount is shown and entered
--      exactly and its permanence is warned
--   F  the gate fails closed

local OP = IncomeSchedule.OP
local HOURLY, DAILY = Settings.PAY_MODE_HOURLY, Settings.PAY_MODE_DAILY
local W = IM6

-- The host: Daily, 1000 at Hard difficulty and the 5x multiplier, seasonal effects on,
-- in autumn (the payment path's factor 1.2). Every client's own file holds the defaults.
local HOST = { payMode = DAILY, customAmount = 1000, difficulty = Settings.DIFFICULTY_HARD,
               incomeMultiplier = 3, seasonalEffects = true }
local AUTUMN = 2

-- ── the renderer the HUD draws through ───────────────────────────────────────
local rendered = {}
RenderText = { ALIGN_LEFT = 0, ALIGN_CENTER = 1, ALIGN_RIGHT = 2 }
function setTextBold() end
function setTextAlignment() end
function setTextColor() end
function renderText(_x, _y, _size, text) rendered[#rendered + 1] = tostring(text) end
function setOverlayColor() end
function renderOverlay() end
function createImageOverlay() return 1 end
function getBaseGameRenderer() return nil end
g_pixelSizeY = 1 / 1080

local function drawHud(c)
    W.asClient(c)
    c.hud = c.hud or IncomeHUD.new(c.mgr.incomeSystem, c.mgr.settings)
    rendered = {}
    c.hud:draw()
    return table.concat(rendered, " | ")
end
local function has(text, part) return text:find(part, 1, true) ~= nil end

-- ── the GUI loader the report is built by ────────────────────────────────────
local function element(id, visible)
    local el = { id = id, text = "", visible = visible ~= false }
    function el:setText(t) self.text = t end
    function el:setTextColor() end
    function el:setVisible(v) self.visible = v end
    function el:setDisabled(v) self.disabled = v end
    return el
end
local loadedGuis = {}
local function guiWorld()
    return { loadGui = function(_self, _path, name, target)
        local xml = T.text["gui/IncomeReportDialog.xml"]
        for attrs in xml:gmatch("<(%a+%s[^>]-)/?>") do
            local id = attrs:match('%sid="([%w_]+)"')
            if id ~= nil then target[id] = element(id, attrs:match('%svisible="false"') == nil) end
        end
        loadedGuis[name] = target
        if target.onCreate then target:onCreate() end
    end }
end
local function openReport(c)
    W.asClient(c)
    IncomeReportDialog.instance = nil
    g_gui = guiWorld()
    local dlg = IncomeReportDialog.getInstance("./")
    g_gui = nil
    dlg:onOpen()
    -- The loan band's own view request is the loan's event (its bars are F309's); only
    -- this client's schedule requests stay queued for the host.
    local scheduleMt = getmetatable(IncomeScheduleEvent.emptyNew())
    local kept = {}
    for _, ev in ipairs(c.outbox) do
        if getmetatable(ev) == scheduleMt then kept[#kept + 1] = ev end
    end
    c.outbox = kept
    return dlg
end

-- ── the RfPda host the guest registers with ──────────────────────────────────
local function pdaShow(c)
    W.asClient(c)
    local registered = nil
    c.mission.rfEscModules = { registerModule = function(_self, spec) registered = spec; return true end }
    ImRfPdaGuest.reset()
    ImRfPdaGuest.tryRegister()
    local els = {}
    local container = { getDescendantById = function(_self, id)
        els[id] = els[id] or element(id)
        return els[id]
    end }
    registered.onShow(container)
    return els, registered
end

-- ══════════════════════════════════════════════════════════════════════════════
-- A. THE VIEW CARRIES WHAT THE READERS SHOW
-- ══════════════════════════════════════════════════════════════════════════════
do
    W.newHost(HOST, { season = AUTUMN })
    local c = W.newClient("c", true)
    W.pump(c)
    local v = c.mgr:getIncomeScheduleView()
    T.eq("A1 [wire] the client holds the host's reader fields",
        table.concat({ tostring(v.enabled), tostring(v.difficulty), tostring(v.incomeMultiplier), tostring(v.seasonalEffects),
            v.seasonFactor ~= nil and string.format("%.1f", v.seasonFactor) or "nil" }, " "), "true 3 3 true 1.2")
    T.eq("A2 [world] the client's own file says otherwise", c.mgr.settings.difficulty .. " " .. c.mgr.settings.incomeMultiplier
        .. " " .. tostring(c.mgr.settings.seasonalEffects), "2 1 false")
    T.eq("A3 the payment and the next gross are the host's", math.floor(v.payment) .. " " .. math.floor(v.paymentThisSeason), "5000 6000")
    T.eq("A4 every event crossed the tape without a fault", W.tapeFaults, 0)
end
do
    W.newHost({ payMode = DAILY, customAmount = 1000, enabled = false }, { daysPerPeriod = 0 })
    local c = W.newClient("c", true)
    W.pump(c)
    local v = c.mgr:getIncomeScheduleView()
    T.eq("A5 income off with an unknown month: DISABLED, and no estimate crosses as 0",
        v.paymentState .. " " .. tostring(v.daysThisMonth) .. " " .. tostring(v.monthEstimate), "DISABLED nil nil")
end

-- A host change that moves only a reader field still reaches the clients (Bob's MAJOR on
-- cbc134e): seasonal effects switched on through SettingsHub in summer, whose factor is
-- 1.0, moves no payment, count or estimate.
do
    W.newHost({ payMode = DAILY, customAmount = 1000, seasonalEffects = false }, { season = 1 })
    local c = W.newClient("c", true)
    W.pump(c)
    W.asHost()
    W.host.mgr:update(1000)
    W.deliverBroadcasts()
    W.asClient(c)
    T.eq("A6 [world] the client holds seasonal effects off", tostring(c.mgr:getIncomeScheduleView().seasonalEffects), "false")
    W.asHost()
    W.hubModules.IncomeMod.onChange("seasonalEffects", true, 1)
    local before = #W.broadcasts
    W.host.mgr:update(1000)
    T.eq("A7 the host republishes a view whose only move is a reader field", #W.broadcasts - before, 1)
    W.deliverBroadcasts()
    W.asClient(c)
    local v = c.mgr:getIncomeScheduleView()
    T.eq("A8 and the client's readers follow it", tostring(v.seasonalEffects) .. " " .. math.floor(v.paymentThisSeason), "true 1000")
end

-- ══════════════════════════════════════════════════════════════════════════════
-- B. THE HUD
-- ══════════════════════════════════════════════════════════════════════════════
do
    W.newHost(HOST, { season = AUTUMN })
    local c = W.newClient("c", true)
    local waiting = drawHud(c)
    T.ok("B1 [reached] IncomeHUD.new and draw rendered the panel", has(waiting, "INCOME MOD"), waiting)
    T.ok("B2 before the host answers the HUD says it is waiting", has(waiting, "[--]") and has(waiting, "Waiting for the host"), waiting)
    T.ok("B3 and shows none of this machine's own figures", not has(waiting, "Hourly") and not has(waiting, "Normal")
        and not has(waiting, "$2400"), waiting)
    W.pump(c)
    local text = drawHud(c)
    T.ok("B4 after the view arrives: the host's mode, difficulty and amount", has(text, "[ON]") and has(text, "Daily")
        and has(text, "Hard") and has(text, "$5000"), text)
    T.ok("B5 the host's multiplier, not the client's", has(text, "Multiplier: 5x"), text)
    T.ok("B6 the current seasonal adjustment, never a season name", has(text, "Current seasonal adjustment: 1.2x")
        and not has(text, "Season:") and not has(text, "Autumn"), text)
    T.ok("B7 the next payment follows the host's Daily mode", has(text, "Next: End of day"), text)
    T.ok("B8 the every-farm row is hidden while the gate is LOCKED", not has(text, "Paid to every active farm"), text)
    local lockedH = c.hud.lastBgH
    c.mgr.settings.experimentalSystems = true         -- this machine's own opt-in
    local released = drawHud(c)
    T.ok("B9 released, the HUD says the amount is paid to every active farm", has(released, "Paid to every active farm"), released)
    T.ok("B10 and the panel grew by that row", c.hud.lastBgH > lockedH)
end
do
    W.newHost({ payMode = DAILY, customAmount = 1000, enabled = false })
    local c = W.newClient("c", true)
    W.pump(c)
    local text = drawHud(c)
    T.ok("B11 income off on the host: [OFF] and nothing due", has(text, "[OFF]") and has(text, "Next: --"), text)
end

-- ══════════════════════════════════════════════════════════════════════════════
-- C. THE REPORT
-- ══════════════════════════════════════════════════════════════════════════════
do
    W.newHost(HOST, { season = AUTUMN })
    local c = W.newClient("c", true)
    local dlg = openReport(c)
    T.ok("C1 [reached] the shipped XML declares the estimate line and the loader built it", dlg.scheduleEstimateText ~= nil)
    T.eq("C2 before the host answers the summary says it is waiting, with no figure of its own",
        dlg.statusText.text .. " | " .. dlg.modeText.text .. " " .. dlg.difficultyText.text .. " " .. dlg.amountText.text
        .. " " .. dlg.multiplierText.text, "Waiting for the host | -- -- -- --")
    W.pump(c)
    dlg = openReport(c)
    T.eq("C3 after the view arrives the summary is the host's",
        table.concat({ dlg.statusText.text, dlg.modeText.text, dlg.difficultyText.text, dlg.amountText.text,
            dlg.multiplierText.text, dlg.seasonalText.text }, " "),
        "im_report_enabled Daily Hard $5000 5x im_report_enabled")
    T.ok("C4 the next payment follows the host's Daily mode", has(dlg.nextPaymentText.text, "midnight"), dlg.nextPaymentText.text)
    T.eq("C5 the estimate line is hidden while the gate is LOCKED", tostring(dlg.scheduleEstimateText.visible) .. " '" .. dlg.scheduleEstimateText.text .. "'", "false ''")
    c.mgr.settings.experimentalSystems = true
    dlg = openReport(c)
    local est = dlg.scheduleEstimateText.text
    T.ok("C6 released: the month at this rate, gross before the loan", dlg.scheduleEstimateText.visible == true
        and has(est, "Month of 3 days: 3 payments, about $18000 gross before any loan repayment."), est)
    T.ok("C7 and that the amount applies to every active farm", has(est, "every active farm"), est)
    T.ok("C8 the loan band keeps its own lines", dlg.loanStatusText ~= nil and dlg.loanForecastIncomeText ~= nil)
end
do
    W.newHost({ payMode = DAILY, customAmount = 1000, enabled = false }, { daysPerPeriod = 0 })
    local c = W.newClient("c", true, { experimentalSystems = true })
    W.pump(c)
    local dlg = openReport(c)
    local est = dlg.scheduleEstimateText.text
    T.ok("C9 off with an unknown month: hypothetical and unavailable, never a 0 month", has(est, "Income is off")
        and has(est, "Month estimate: not available") and not has(est, "Month of"), est)
    T.eq("C10 and nothing is due", dlg.nextPaymentText.text, "--")
end

-- ══════════════════════════════════════════════════════════════════════════════
-- D. THE RFPDA GUEST
-- ══════════════════════════════════════════════════════════════════════════════
do
    W.newHost(HOST, { season = AUTUMN })
    local c = W.newClient("c", true)
    local els, spec = pdaShow(c)
    T.ok("D1 [reached] tryRegister registered the guest with its onShow", spec ~= nil and type(spec.onShow) == "function")
    T.eq("D2 before the host answers the page says it is waiting", els.rfFwTableTitle.text, "Waiting for the host's income settings.")
    W.pump(c)
    els = pdaShow(c)
    local title = els.rfFwTableTitle.text
    T.ok("D3 the summary is the host's: on, Daily, the host's amount", has(title, "On") and has(title, "Daily") and has(title, "$5000")
        and not has(title, "Hourly"), title)
    local hint = els.rfFwHintTable.text
    T.ok("D4 the hints are the host's difficulty, multiplier and seasonal switch",
        has(hint, "Difficulty: Hard") and has(hint, "Multiplier: 5x") and has(hint, "Seasonal: On"), hint)
    T.ok("D5 the next payment follows the host's Daily mode", has(els.rfFwMore.text, "midnight"), els.rfFwMore.text)
    T.ok("D6 the explanation is absent while the gate is LOCKED", not has(els.rfFwMore.text, "every active farm"), els.rfFwMore.text)
    c.mgr.settings.experimentalSystems = true
    els = pdaShow(c)
    T.ok("D7 released: the month at this rate and every active farm",
        has(els.rfFwMore.text, "Month of 3 days: 3 payments") and has(els.rfFwMore.text, "every active farm"), els.rfFwMore.text)
end

-- ══════════════════════════════════════════════════════════════════════════════
-- E. THE TYPED AMOUNT (LOCKED behind im6_income_schedule)
-- ══════════════════════════════════════════════════════════════════════════════
do
    W.newHost(HOST, { season = AUTUMN })
    local locked = W.newClient("locked", true)
    W.pump(locked)
    W.asClient(locked)
    W.injectOn(locked)
    T.eq("E1 locked: the Esc page has no typed amount row", W.options.im6_amount, nil)
    T.ok("E2 [reached] while the pay-mode row is there", W.options.im_paymode ~= nil)

    local a = W.newClient("a", true, { experimentalSystems = true })
    W.pump(a)
    W.asClient(a)
    W.injectOn(a)
    local opt = W.options.im6_amount
    T.ok("E3 released: the row shows the host's amount, usable by an administrator",
        opt ~= nil and opt.texts[1] == "$1000" and opt.disabled == false, opt and (tostring(opt.texts[1]) .. " " .. tostring(opt.disabled)))
    W.click("im6_amount", 1)
    local entry = W.inputs[#W.inputs]
    T.ok("E4 any arrow opens the typed entry, starting from the host's exact amount",
        entry ~= nil and entry.defaultText == "1000" and entry.target == nil, entry and entry.defaultText)
    W.type("1e3")
    W.pump(a)
    T.eq("E5 exponent text is refused by the host with the reason, and nothing changes",
        tostring(W.infos[#W.infos]) .. " | " .. W.hostState(),
        "Not a whole number. Use digits only, for example 5000. Nothing changed. | mode=2 amount=1000 rev=1 saves=0")
    W.click("im6_amount", 1)
    W.type("2500")
    W.pump(a)
    local d = W.dialogs[#W.dialogs]
    T.ok("E6 a valid amount is previewed by the host and shown before anything changes",
        d ~= nil and has(d.text, "Amount per payment: $12500.") and has(d.text, "Set this amount per payment?"), d and d.text)
    T.eq("E7 nothing changed while the confirm is open", W.hostState(), "mode=2 amount=1000 rev=1 saves=0")
    W.answer(false)
    T.eq("E8 No changes nothing", W.hostState(), "mode=2 amount=1000 rev=1 saves=0")
    W.click("im6_amount", 1)
    W.type("2500")
    W.pump(a)
    W.answer(true)
    W.pump(a)
    T.eq("E9 Yes applies it on the host", W.hostState(), "mode=2 amount=2500 rev=2 saves=1")
    T.eq("E10 the row follows the accepted amount", W.options.im6_amount.texts[1], "$2500")
    W.click("im6_amount", 1)
    W.type("5000", false)
    T.eq("E11 cancelling the entry sends nothing", #a.outbox .. " " .. W.hostState(), "0 mode=2 amount=2500 rev=2 saves=1")

    local p = W.newClient("player", false, { experimentalSystems = true })
    W.pump(p)
    W.asClient(p)
    W.injectOn(p)
    T.eq("E12 a non-admin sees the amount without a working control", tostring(W.options.im6_amount.disabled), "true")
    local before = #W.inputs
    W.click("im6_amount", 1)
    T.eq("E13 and a press opens nothing", #W.inputs - before, 0)
end
do
    W.newHost({ payMode = DAILY, customAmount = 2000000 })
    local a = W.newClient("a", true, { experimentalSystems = true })
    W.pump(a)
    W.asClient(a)
    W.injectOn(a)
    T.eq("E14 a legacy amount above the cap shows exactly", W.options.im6_amount.texts[1], "$2000000")
    W.click("im6_amount", 1)
    local entry = W.inputs[#W.inputs]
    T.ok("E15 the entry starts from it exactly and can hold it", entry.defaultText == "2000000"
        and entry.maxCharacters >= #"2000000", entry.defaultText .. " " .. tostring(entry.maxCharacters))
    W.type("5000")
    W.pump(a)
    local d = W.dialogs[#W.dialogs]
    T.ok("E16 lowering it warns that it cannot go back above 999999", d ~= nil
        and has(d.text, "cannot be set back above 999999"), d and d.text)
    T.eq("E17 nothing changed yet", W.hostState(), "mode=2 amount=2000000 rev=1 saves=0")
end

-- ══════════════════════════════════════════════════════════════════════════════
-- F. THE GATE FAILS CLOSED
-- ══════════════════════════════════════════════════════════════════════════════
do
    W.newHost(HOST)
    local c = W.newClient("c", true, { experimentalSystems = true })
    W.asClient(c)
    T.eq("F1 [world] this machine opted in", tostring(IncomeSchedule.explanationReleased()), "true")
    local live = ReleaseGate.liveOptIn
    ReleaseGate.liveOptIn = function() return nil end
    T.eq("F2 an opt-in that cannot be read keeps the explanation and typed control hidden", tostring(IncomeSchedule.explanationReleased()), "false")
    ReleaseGate.liveOptIn = live
    T.eq("F3 every event crossed the tape without a fault", W.tapeFaults, 0)
    T.eq("F4 every request got exactly one reply", W.replyErrors, 0)
end
