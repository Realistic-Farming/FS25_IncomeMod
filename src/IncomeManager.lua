-- 2026-08-22 (Wizard): with MasterHUD installed this mod's own HUD hide/move keys must not
-- merely be inert, they must not REGISTER at all - that is what removes their rows from the
-- F1 legend and the Controls list. Probed on TaxMod first: skipping registration does remove
-- the row, so the pattern is used suite-wide. Only HUD hide/move actions are gated; every
-- other action this mod registers is untouched.
local function __rfMhOwnsHudKeys()
    return ((g_currentMission ~= nil and g_currentMission.masterHUD) or g_masterHUD) ~= nil
end

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

---@class IncomeManager
IncomeManager = IncomeManager or {}
local IncomeManager_mt = Class(IncomeManager)

-- RSF-F201 item 12: the session-lived input-hook record, on the latched class
-- table and outside the per-mission instance. Holds the install latch, the
-- captured predecessor and the per-owner arming flag, nothing else.
IncomeManager._f201Input = IncomeManager._f201Input or { installed = false, active = false, original = nil }

function IncomeManager.new(mission, modDirectory, modName)
    local self = setmetatable({}, IncomeManager_mt)

    self.mission      = mission
    self.modDirectory = modDirectory
    self.modName      = modName

    self.settingsManager = SettingsManager.new()
    self.settings        = Settings.new(self.settingsManager)
    self.incomeSystem    = IncomeSystem.new(self.settings)
    -- [C3] EMERGENCY LOAN: the never-stuck recovery hatch. Owns the per-farm
    -- debt ledger; server-authoritative grant + Time Guard interest + income
    -- repayment. Armed in onMissionLoaded.
    self.emergencyLoan = EmergencyLoan.new()
    self.emergencyLoan.settings     = self.settings
    self.emergencyLoan.incomeSystem = self.incomeSystem
    -- RSF-F309 item 6: owner sessions die with their connection.
    IncomeManager.installLoanSessionTeardown()

    -- UI injection and HUD: client-side only
    if mission:getIsClient() and g_gui then
        self.settingsUI = SettingsUI.new(self.settings)

        InGameMenuSettingsFrame.onFrameOpen = Utils.appendedFunction(
            InGameMenuSettingsFrame.onFrameOpen,
            function()
                self.settingsUI:inject()
            end
        )

        InGameMenuSettingsFrame.updateButtons = Utils.appendedFunction(
            InGameMenuSettingsFrame.updateButtons,
            function(frame)
                if self.settingsUI then
                    self.settingsUI:ensureResetButton(frame)
                end
            end
        )

        -- Income HUD overlay
        self.incomeHUD = IncomeHUD.new(self.incomeSystem, self.settings)

        -- Income Report Dialog (singleton; loaded once, shown on demand)
        self.incomeReportDialog = IncomeReportDialog.getInstance(self.modDirectory)

        -- Register key actions via PlayerInputComponent hook (proven race-condition-safe pattern).
        -- RSF-F201 PLAYER-lifetime companion: the wrapper is installed ONCE per loaded
        -- script environment with its record on the IncomeManager class table, and
        -- delete() no longer restores the captured predecessor (that can unhook a
        -- later mod's wrapper). Item 11: the two `local` redeclarations inside the
        -- MasterHUD gate that shadowed hudOk/hudId and edOk/edId are gone, so the
        -- handles land in the outer locals, the toggle handle is stored, the edit
        -- handle is stored and labelled, and the standalone failure line stops
        -- printing for a control that works.
        if PlayerInputComponent and PlayerInputComponent.registerActionEvents then
            local hook = IncomeManager._f201Input
            if not hook.installed then
                hook.installed = true
                local originalRegisterActionEvents = PlayerInputComponent.registerActionEvents
                hook.original = originalRegisterActionEvents
                PlayerInputComponent.registerActionEvents = function(inputComponent, ...)
                    originalRegisterActionEvents(inputComponent, ...)
                    if not hook.active then return end

                    -- Only register for the local owning player, not networked players
                    if not (inputComponent.player and inputComponent.player.isOwner) then return end
                    -- Guard against double-registration on level reloads
                    if g_IncomeManager and g_IncomeManager.toggleHUDEventId then return end
                    if not g_IncomeManager or not g_IncomeManager.incomeHUD then return end

                    g_inputBinding:beginActionEventsModification(PlayerInputComponent.INPUT_CONTEXT_NAME)

                    -- HUD toggle: I key
                    local hudOk, hudId = false, nil
                    if not __rfMhOwnsHudKeys() then
                        hudOk, hudId = g_inputBinding:registerActionEvent(
                            InputAction.IM_TOGGLE_HUD,
                            g_IncomeManager,
                            g_IncomeManager.onToggleHUDInput,
                            false,  -- triggerUp
                            true,   -- triggerDown
                            false,  -- triggerAlways
                            true    -- startActive
                        )
                    end
                    if hudOk and hudId then
                        g_IncomeManager.toggleHUDEventId = hudId
                        Logging.info("Income Mod: HUD toggle registered")
                    else
                        Logging.warning("Income Mod: HUD toggle registration failed")
                    end

                    -- HUD move/edit. Registered here, not only through the MasterHUD bridge,
                    -- so a standalone install (no MasterHUD) can still reposition the panel.
                    -- The callback stands down by itself when MasterHUD is present.
                    local edOk, edId = false, nil
                    if not __rfMhOwnsHudKeys() then
                        edOk, edId = g_inputBinding:registerActionEvent(
                            InputAction.IM_HUD_EDIT,
                            g_IncomeManager,
                            g_IncomeManager.onHUDEditInput,
                            false, true, false, true
                        )
                    end
                    if edOk and edId then
                        g_IncomeManager.hudEditEventId = edId
                        g_inputBinding:setActionEventText(edId,
                            (g_i18n ~= nil and g_i18n:getText("input_IM_HUD_EDIT")) or "Move Income HUD")
                        Logging.info("Income Mod: HUD move/edit registered")
                    end

                    -- Income Report
                    local repOk, repId = g_inputBinding:registerActionEvent(
                        InputAction.IM_INCOME_REPORT,
                        g_IncomeManager,
                        g_IncomeManager.onIncomeReportInput,
                        false,  -- triggerUp
                        true,   -- triggerDown
                        false,  -- triggerAlways
                        true    -- startActive
                    )
                    if repOk and repId then
                        g_IncomeManager.incomeReportEventId = repId
                        Logging.info("Income Mod: Income Report (U) registered")
                    else
                        Logging.warning("Income Mod: Income Report (U) registration failed")
                    end

                    g_inputBinding:endActionEventsModification()
                end
            end
            -- Arm registration for this owner. The wrapper resolves g_IncomeManager
            -- at callback time, so no stale manager is captured.
            hook.active = true
        end
    end

    self.settingsGUI = SettingsGUI.new()
    self.settingsGUI:registerConsoleCommands()

    self.settings:load()

    return self
end

-- =========================================================
-- Called after map load is complete
-- =========================================================

function IncomeManager:onMissionLoaded()
    -- Register with SettingsHub (if installed) so FarmTablet's System
    -- Settings app can list Income Mod's settings. No-ops safely if
    -- SettingsHub isn't present.
    IncomeSettingsHubBridge.register(self)

    -- StateLedger (bedrock, delegate-when-present): when installed, the shared master
    -- save file becomes the load source of truth for the income timer state;
    -- FS25_IncomeMod_state.xml stays the standalone safety copy. Registered BEFORE
    -- self:loadState() below so the ledger's deserialize has delivered when we read
    -- (register() forces the parse, since we load in the same phase StateLedger parses).
    if IncomeStateLedgerBridge then
        IncomeStateLedgerBridge.register(self)
    end

    -- [C3] EMERGENCY LOAN: register the debt-ledger sidecar with StateLedger
    -- (delegate-when-present) so the ledger's deserialize has delivered before
    -- the loan reads its state. No-ops when StateLedger is absent (the loan is
    -- then session-only, which is the graceful degrade for a recovery hatch).
    if IncomeEmergencyLoanBridge then
        IncomeEmergencyLoanBridge.register(self)
    end

    -- [C3/F130] Select and install the authoritative debt snapshot, apply any native
    -- MP->SP conversion once, and re-register the interest accrual for restored debt.
    -- Server-only (the loan is server-authoritative; clients receive views via the Event).
    if self.emergencyLoan and g_currentMission and g_currentMission:getIsServer() then
        self:loadEmergencyDebt()
    end

    -- MasterHUD (bedrock, delegate-when-present): when installed, the income HUD draw
    -- folds into MasterHUD's single suspend-aware loop and our own FSBaseMission.draw
    -- hook stands down. No-ops when MasterHUD is absent (own hook draws it).
    if IncomeMasterHUDBridge then
        IncomeMasterHUDBridge.register(self)
    end

    if self.incomeSystem then
        self.incomeSystem:initialize()
    end

    -- Restore HUD layout (position/scale) saved by the player
    if self.incomeHUD then
        self.incomeHUD:loadLayout()
    end

    -- Restore timer state from previous save (prevents double-payment on reload)
    self:loadState()

    -- Single startup notification (client-side only, notification is now in
    -- IncomeSystem:showNotification which guards getIsClient internally)
    if self.settings.enabled and self.settings.showNotifications then
        if g_currentMission and g_currentMission:getIsClient() then
            g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_OK, "Income Mod Active - Type 'income' for commands")
        end
    end
end

-- =========================================================
-- Key Action Callback
-- =========================================================

function IncomeManager:onHUDEditInput()
    -- MasterHUD takeover: with MasterHUD installed it owns the suite-wide hide/move
    -- binds, so this per-mod key is deliberately inert. Standalone, it runs.
    if ((g_currentMission ~= nil and g_currentMission.masterHUD) or g_masterHUD) ~= nil then
        return
    end
    local hud = self.incomeHUD
    if hud == nil then return end
    if hud.editMode then hud:exitEditMode() else hud:enterEditMode() end
end

function IncomeManager:onToggleHUDInput()
    -- 2026-08-22 (Wizard): MasterHUD takeover. When MasterHUD is installed it owns the
    -- suite-wide hide/move binds, so this mod's own per-mod key is deliberately inert:
    -- one surface, one way to reach it. Standalone (no MasterHUD) this runs normally.
    -- Canonical presence check, the same expression the suite's MasterHUD bridges use.
    if ((g_currentMission ~= nil and g_currentMission.masterHUD) or g_masterHUD) ~= nil then
        return
    end
    if self.incomeHUD then
        self.incomeHUD:toggleVisibility()
    end
end

function IncomeManager:onIncomeReportInput()
    if self.incomeReportDialog then
        self.incomeReportDialog:show()
    end
end

-- =========================================================
-- Per-frame update
-- =========================================================

function IncomeManager:update(dt)
    if self.incomeSystem then
        self.incomeSystem:update(dt)
    end
    if self.emergencyLoan then
        -- [C3] refresh the forecast cache on the day boundary, never per-frame.
        local env = g_currentMission and g_currentMission.environment
        local mono = env and env.currentMonotonicDay or -1
        if mono ~= -1 and mono ~= self._emergencyLoanDay then
            self._emergencyLoanDay = mono
            self.emergencyLoan:onDayChange()
        end
    end
    if self.incomeHUD then
        self.incomeHUD:update(dt)
    end
end

-- =========================================================
-- Save (called from saveToXMLFile hook and on delete)
-- =========================================================

function IncomeManager:save()
    if self.settings then
        self.settings:save()
    end

    -- Persist timer state so reloads don't cause missed/double payments
    if self.incomeSystem and self.settingsManager then
        self.settingsManager:saveTimerState(
            self.incomeSystem.lastHour,
            self.incomeSystem.lastDay,
            self.incomeSystem.lastMonotonicDay
        )
    end
end

-- =========================================================
-- Load Timer State
-- =========================================================

function IncomeManager:loadState()
    if not self.incomeSystem then return end
    -- StateLedger is the load source of truth when present and it delivered a state
    -- block; otherwise read the standalone FS25_IncomeMod_state.xml (also the first-load
    -- path right after installing the ledger onto an existing save). The state file is
    -- written every save regardless, as a safety copy.
    if IncomeStateLedgerBridge and IncomeStateLedgerBridge.hasState() then
        IncomeStateLedgerBridge.applyState(self.incomeSystem)
        return
    end
    if self.settingsManager then
        local state = self.settingsManager:loadTimerState()
        if state then
            self.incomeSystem:loadState(state)
        end
    end
end

-- =========================================================
-- [C3/F130] Emergency loan: persistence, public view, owner Event
-- =========================================================

--- Select and install the authoritative debt snapshot (StateLedger primary, own-XML
--- fallback), apply the native MP->SP conversion once, and re-register interest accrual
--- for restored positive debt. Server-only. Runs once in onMissionLoaded.
function IncomeManager:loadEmergencyDebt()
    local loan = self.emergencyLoan
    if loan == nil then return end

    local installed = false
    -- Prefer a StateLedger-delivered non-nil block; an explicit nil delivery (new save)
    -- falls through to the own-XML fallback below.
    if IncomeEmergencyLoanBridge and IncomeEmergencyLoanBridge.hasState() then
        installed = loan:deserialize(IncomeEmergencyLoanBridge.pendingState) == true
    end

    if not installed then
        local mi = g_currentMission and g_currentMission.missionInfo
        local snap = EmergencyLoanDebtStorage.load(mi)
        if snap == false then
            -- Malformed/unsupported primary: retain file, expose UNAVAILABLE, block mutation.
            loan:setReadiness(EmergencyLoan.READINESS.UNAVAILABLE)
            Logging.warning("Income Mod: emergency debt file malformed; loan marked UNAVAILABLE")
            return
        elseif type(snap) == "table" then
            loan:deserialize(snap)  -- valid (a new-format empty snapshot is authoritative empty)
        else
            loan:setReadiness(EmergencyLoan.READINESS.READY)  -- no file: brand-new / pre-C3 save
        end
    end

    -- Native MP->SP farm conversion, once, before use (mergedFarms is populated during
    -- FarmManager load, before this loadMission00Finished handler).
    local fm = g_farmManager
    if fm ~= nil and type(fm.mergedFarms) == "table" and next(fm.mergedFarms) ~= nil then
        loan:remapMergedFarms(fm.mergedFarms)
    end

    -- Re-register the month-cadence accrual for restored positive debt.
    for farmId, d in pairs(loan.debts) do
        if d.active and ((d.principal or 0) + (d.accruedInterest or 0)) > 0 then
            loan:registerInterestAccrual(farmId)
        end
    end
end

--- Persist the debt to its isolated XML (server-only). Called from the active career
--- save window (FSCareerMissionInfo.saveToXMLFile), preserving timer/settings/HUD work.
function IncomeManager:saveEmergencyDebt(missionInfo)
    if self.emergencyLoan == nil then return end
    if g_currentMission == nil or not g_currentMission:getIsServer() then return end
    EmergencyLoanDebtStorage.save(self.emergencyLoan,
        missionInfo or (g_currentMission and g_currentMission.missionInfo))
end

-- Per-connection owner session: the highest command sequence processed, the last
-- command and its result (an exact retry is answered from here, RSF-F309 item 6), and
-- ONE outstanding quote (bounded owner state: minting a new quote drops the old token).
-- Sessions are volatile: a closed connection drops its own (onLoanConnectionClosed),
-- teardown drops all, and a reload starts empty while the debt revision persists.
function IncomeManager:_loanSession(connection)
    self._loanSessions = self._loanSessions or {}
    local key = connection or "local"
    local s = self._loanSessions[key]
    if s == nil then
        s = { id = tostring(key), highest = 0, lastCommand = nil, lastResult = nil,
              quote = nil, quoteSeq = 0 }
        self._loanSessions[key] = s
    end
    return s
end

--- The next client-side request sequence, or nil when the session has used them all.
--- RSF-F309 item 6 (C3-SDS:218): a session never wraps; at MAX_SEQUENCE it REFUSES to
--- send another owner command and the counter stays where it is.
function IncomeManager:_nextLoanSequence()
    local used = self._loanSeq or 0
    -- Compared BEFORE the increment, so the counter itself never crosses the ceiling
    -- (an integer build would wrap negative on MAX + 1).
    if used >= EmergencyLoanController.MAX_SEQUENCE then
        Logging.warning("Income Mod: emergency loan request sequence exhausted for this session; no further owner commands until the next session")
        return nil
    end
    self._loanSeq = used + 1
    return self._loanSeq
end

--- Build one owner request, or nil when the sequence is exhausted (never wraps).
function IncomeManager:_newLoanRequest(op, amountText, token)
    local seq = self:_nextLoanSequence()
    if seq == nil then return nil, "SEQUENCE_EXHAUSTED" end
    return EmergencyLoanEvent.newRequest(seq, op, amountText, token), seq
end

--- Mint the session's ONE outstanding quote. A previous unaccepted quote is dropped
--- with its token: only the latest bound sum can be accepted (RSF-F309 items 5 and 6).
function IncomeManager:_mintQuote(session, quote)
    session.quoteSeq = (session.quoteSeq or 0) + 1
    local token = string.format("q%d", session.quoteSeq)
    quote.token = token
    session.quote = quote
    return token
end

--- The assumptions a quote is bound to (RSF-F309 item 5): the debt revision, the
--- owner's readiness, the farm's cash and the terms computeOffer depends on. ACCEPT
--- re-reads the same set and refuses on ANY difference; it never recomputes and pays a
--- different sum.
function IncomeManager:_quoteBinding(loan, farmId)
    return {
        revision  = (loan.debts[farmId] and loan.debts[farmId].revision) or 0,
        readiness = loan:getReadiness(),
        cash      = loan:getBalance(farmId),
        terms     = loan:quoteTerms(),
    }
end

local function bindingMatches(quote, now, checkCash)
    if quote.revision ~= now.revision then return false end
    if quote.readiness ~= now.readiness then return false end
    if quote.terms ~= now.terms then return false end
    if checkCash and quote.cash ~= now.cash then return false end
    return true
end

--- One outstanding owner-UI command per session on a pure client (RSF-F309 item 6):
--- a quote awaiting its reply, an accept awaiting its result, or a quote-then-accept
--- flow whose auto-accept has not gone out yet. A second command while any of these
--- is in flight is refused as BUSY, so the in-flight reply still reaches the UI that
--- is waiting for it (a double-clicked Borrow would otherwise lose both).
function IncomeManager:_isLoanUiBusy()
    return self._pendingQuote ~= nil or self._pendingResult ~= nil or self._pendingAccept == true
end

--- A connection that closed takes its owner session (sequence, cached result, quote)
--- with it; a reconnecting player starts a fresh one (RSF-F309 item 6).
function IncomeManager:onLoanConnectionClosed(connection)
    if connection == nil or self._loanSessions == nil then return end
    self._loanSessions[connection] = nil
end

-- RSF-F309 item 6: the session-teardown hook record, on the class table like F201's
-- input record, so the FSBaseMission wrapper is installed ONCE per loaded script
-- environment and routes to whichever manager is live.
IncomeManager._f309ConnHook = IncomeManager._f309ConnHook or { installed = false }

--- Append the per-connection session teardown to FSBaseMission:onConnectionClosed
--- (FSBaseMission.lua:834; the server calls it for every closed client connection from
--- Server.lua:298/:475/:488). Returns true when this call installed it.
function IncomeManager.installLoanSessionTeardown()
    local rec = IncomeManager._f309ConnHook
    if rec.installed then return false end
    if FSBaseMission == nil or type(FSBaseMission.onConnectionClosed) ~= "function"
        or Utils == nil or type(Utils.appendedFunction) ~= "function" then
        return false
    end
    FSBaseMission.onConnectionClosed = Utils.appendedFunction(FSBaseMission.onConnectionClosed,
        function(_mission, connection, _reason)
            local mgr = g_IncomeManager
            if mgr ~= nil and mgr.onLoanConnectionClosed ~= nil then
                mgr:onLoanConnectionClosed(connection)
            end
        end)
    rec.installed = true
    return true
end

-- Copy a cost/missing-input list so the reply never aliases the loan's live tables.
local function copyEntries(list)
    if type(list) ~= "table" then return nil end
    local out = {}
    for i, e in ipairs(list) do
        if type(e) == "table" then
            out[i] = { sourceId = e.sourceId, amount = e.amount, basis = e.basis,
                       dueDay = e.dueDay, dueTimeMs = e.dueTimeMs }
        else
            out[i] = e
        end
    end
    return out
end

local function copyClock(c)
    if type(c) ~= "table" then return nil end
    return { monotonicDay = c.monotonicDay, timeOfDayMs = c.timeOfDayMs }
end

-- Compact a rich view into the Event reply payload (the wire + the client cache shape).
-- Carries the whole version-1 view (debt, rate, forecast, costs, coverage) under the SAME
-- field names as EmergencyLoan:getView, so the report band renders one shape whether it
-- reads the host's rich view or a pure client's cached reply. nil stays nil (unknown).
function IncomeManager:_viewReply(v, sequence, statusOverride)
    return {
        version      = EmergencyLoan.VIEW_VERSION,
        status       = statusOverride or (v and v.forecastStatus) or "UNAVAILABLE",
        sequence     = sequence or 0,
        readiness    = v and v.readiness,
        cash         = v and v.cash,
        outstanding  = v and v.outstanding,
        nativeLoan   = v and v.nativeLoan,
        offer        = v and v.offer,
        canBorrow    = v and v.canBorrow,
        canRepay     = v and v.canRepay,
        borrowReason = v and v.borrowReason,
        repayReason  = v and v.repayReason,
        -- [C3/F130] forecast + debt detail the report's loan band shows (brief section 2).
        farmId                  = v and v.farmId,
        revision                = v and v.revision,
        asOf                    = v and copyClock(v.asOf),
        principal               = v and v.principal,
        accruedInterest         = v and v.accruedInterest,
        drawCount               = v and v.drawCount,
        effectiveMonthlyRate    = v and v.effectiveMonthlyRate,
        costLockReason          = v and v.costLockReason,
        automaticRepaymentShare = v and v.automaticRepaymentShare,
        forecastStatus          = v and v.forecastStatus,
        horizonEnd              = v and copyClock(v.horizonEnd),
        minimumBalance          = v and v.minimumBalance,
        shortfall               = v and v.shortfall,
        expectedGrossIncome     = v and v.expectedGrossIncome,
        expectedNetIncome       = v and v.expectedNetIncome,
        workingCashBasis        = v and v.workingCashBasis,
        workingCashAmount       = v and v.workingCashAmount,
        knownCosts              = v and copyEntries(v.knownCosts),
        estimatedCosts          = v and copyEntries(v.estimatedCosts),
        missingInputs           = v and copyEntries(v.missingInputs),
    }
end

--- getEmergencyLoanView(farmId?): on the server, nil is the LOCAL PLAYER's view: the
--- host resolves its own actor (farm + manager rights) exactly as it would for a remote
--- connection, so the report can offer Borrow/Pay Off to the host player. An explicit
--- farmId is a pure authoritative sample with no actor rights (NO_ACTOR_CONTEXT); a
--- dedicated server with no local player also falls back to that sample. On a client,
--- only the local farm's last authoritative reply (a different supplied farmId refuses).
function IncomeManager:getEmergencyLoanView(farmId)
    local loan = self.emergencyLoan
    if loan == nil then return nil, "NO_LOAN" end
    local isServer = g_currentMission and g_currentMission.getIsServer and g_currentMission:getIsServer()
    local localFarmId = nil
    pcall(function()
        if g_currentMission and g_currentMission.getFarmId then localFarmId = g_currentMission:getFarmId() end
    end)
    if isServer then
        if farmId == nil then
            local actor = EmergencyLoanController.resolveActor(nil)
            if actor ~= nil then
                return loan:getView(actor.farmId, { isManager = actor.isManager })
            end
        end
        local target = farmId
        if target == nil then target = localFarmId end
        if type(target) ~= "number" then return nil, "NO_FARM" end
        return loan:getView(target, nil)  -- pure sample: canBorrow/canRepay false, NO_ACTOR_CONTEXT
    end
    if farmId ~= nil and localFarmId ~= nil and farmId ~= localFarmId then return nil, "OTHER_FARM" end
    if self._emergencyView == nil then return nil, "NO_VIEW_YET" end
    return self._emergencyView
end

--- Ask the host for the current view without moving money.
function IncomeManager:refreshEmergencyLoanView()
    if g_currentMission and g_currentMission.getIsServer and g_currentMission:getIsServer() then
        local v = self:getEmergencyLoanView(nil)
        if v then self._emergencyView = self:_viewReply(v, 0) end
        return true
    end
    if g_client and g_client.getServerConnection and EmergencyLoanEvent then
        local ev = self:_newLoanRequest(EmergencyLoanController.OP.VIEW)
        if ev == nil then return false end
        local ok = pcall(function()
            g_client:getServerConnection():sendEvent(ev)
        end)
        return ok
    end
    return false
end

--- Open IncomeMod's own report (navigation only; never accepts a loan). Returns true
--- only when the registered dialog root actually entered g_gui.dialogs (show() returns
--- nil whether refused or shown, so its nil proves nothing).
function IncomeManager:openEmergencyLoanReport()
    if g_gui == nil then return false, "NO_GUI" end
    if g_gui.currentGui ~= nil then return false, "GUI_BUSY" end
    if self.incomeReportDialog == nil or g_IncomeManager == nil or g_IncomeManager.incomeSystem == nil then
        return false, "NO_HOST"
    end
    pcall(function() self.incomeReportDialog:show() end)
    local root = g_gui.guis and g_gui.guis["IncomeReportDialog"]
    for _, d in pairs(g_gui.dialogs or {}) do
        if d == root and root ~= nil then return true end
    end
    return false, "OPEN_REFUSED"
end

--- Client: cache a reply as the local farm's last authoritative view. If a UI action
--- is mid-flight and the reply carries a fresh quote token, accept it (the two-step
--- quote->accept the owner Event requires on a pure client).
function IncomeManager:onEmergencyLoanReply(payload)
    if type(payload) ~= "table" then return end
    self._emergencyView = payload
    -- A pure client's report opened on "no view yet"; now that the host has answered,
    -- redraw the loan band so the buttons appear without the player reopening it.
    local dlg = self.incomeReportDialog
    if dlg ~= nil and dlg.onLoanViewArrived ~= nil then
        pcall(function() dlg:onLoanViewArrived() end)
    end

    -- A reply the confirming UI is waiting on belongs to that UI, matched by the exact
    -- sequence it sent. An older/foreign reply never resolves a pending confirmation.
    local waiting = self._pendingResult
    if waiting ~= nil and waiting.sequence == payload.sequence then
        self._pendingResult = nil
        if waiting.callback ~= nil then waiting.callback(payload) end
        return
    end
    waiting = self._pendingQuote
    if waiting ~= nil and waiting.sequence == payload.sequence then
        self._pendingQuote = nil
        if waiting.callback ~= nil then waiting.callback(payload) end
        return  -- a quote awaiting player confirmation is NEVER auto-accepted
    end

    if self._pendingAccept and payload.token ~= nil and payload.token ~= ""
        and g_client and g_client.getServerConnection then
        self._pendingAccept = false
        local ev = self:_newLoanRequest(EmergencyLoanController.OP.ACCEPT_QUOTE, nil, payload.token)
        if ev ~= nil then
            pcall(function()
                g_client:getServerConnection():sendEvent(ev)
            end)
        end
    end
end

-- UI entry points: borrow / payoff. Each is a quote-then-accept. On a listen host (or SP)
-- both steps run locally and synchronously; on a pure client the quote request goes over
-- the Event and onEmergencyLoanReply accepts the returned token. The server always
-- re-checks manager rights, acting farm, cash and the quote revision before moving money.
function IncomeManager:uiBorrow() self:_uiQuoteThenAccept(EmergencyLoanController.OP.BORROW_QUOTE) end
function IncomeManager:uiPayoff() self:_uiQuoteThenAccept(EmergencyLoanController.OP.PAYOFF_QUOTE) end
function IncomeManager:uiManualRepay(amountText)
    self:_uiQuoteThenAccept(EmergencyLoanController.OP.MANUAL_AMOUNT_QUOTE, amountText)
end

--- Quote a player-chosen repayment amount WITHOUT accepting it. `amountText` is the
--- untrusted typed value; the server validates it against current cash and debt and
--- returns its own exact amount plus a one-shot token. onQuote receives that reply (or
--- nil when no request could be sent). No money moves until uiAcceptQuote runs.
function IncomeManager:uiManualRepayQuote(amountText, onQuote)
    return self:_uiQuoteOnly(EmergencyLoanController.OP.MANUAL_AMOUNT_QUOTE, amountText, onQuote)
end

--- Quote a full payoff WITHOUT accepting it. The server binds the exact outstanding
--- (principal + all accrued interest) and returns it with a one-shot token; the player
--- confirms THAT sum and only uiAcceptQuote moves money. Replaces the one-step uiPayoff
--- for the report, whose button was the only "confirmation" the payoff ever had.
function IncomeManager:uiPayoffQuote(onQuote)
    return self:_uiQuoteOnly(EmergencyLoanController.OP.PAYOFF_QUOTE, nil, onQuote)
end

function IncomeManager:_uiQuoteOnly(quoteOp, amountText, onQuote)
    local function deliver(reply) if onQuote ~= nil then onQuote(reply) end end
    if g_currentMission and g_currentMission.getIsServer and g_currentMission:getIsServer() then
        local ev = self:_newLoanRequest(quoteOp, amountText)
        if ev == nil then deliver(nil); return false, "SEQUENCE_EXHAUSTED" end
        local reply = self:handleEmergencyLoanRequest(ev, nil)
        if type(reply) == "table" then self._emergencyView = reply end
        deliver(reply)
        return true
    end
    if g_client and g_client.getServerConnection and EmergencyLoanEvent then
        if self:_isLoanUiBusy() then deliver(nil); return false, "BUSY" end
        local ev, seq = self:_newLoanRequest(quoteOp, amountText)
        if ev == nil then deliver(nil); return false, "SEQUENCE_EXHAUSTED" end
        self._pendingQuote = { sequence = seq, callback = onQuote }
        local ok = pcall(function()
            g_client:getServerConnection():sendEvent(ev)
        end)
        if not ok then self._pendingQuote = nil; deliver(nil) end
        return ok
    end
    deliver(nil)
    return false
end

--- Accept one already-minted quote by its token. The server re-checks rights, farm,
--- cash and the debt revision before moving money, and consumes the token once, so a
--- repeated confirmation cannot repeat a completed payment.
function IncomeManager:uiAcceptQuote(token, onResult)
    local function deliver(reply) if onResult ~= nil then onResult(reply) end end
    if type(token) ~= "string" or token == "" then deliver(nil); return false end
    if g_currentMission and g_currentMission.getIsServer and g_currentMission:getIsServer() then
        local ev = self:_newLoanRequest(EmergencyLoanController.OP.ACCEPT_QUOTE, nil, token)
        if ev == nil then deliver(nil); return false, "SEQUENCE_EXHAUSTED" end
        local reply = self:handleEmergencyLoanRequest(ev, nil)
        if type(reply) == "table" then self._emergencyView = reply end
        deliver(reply)
        return true
    end
    if g_client and g_client.getServerConnection and EmergencyLoanEvent then
        if self:_isLoanUiBusy() then deliver(nil); return false, "BUSY" end
        local ev, seq = self:_newLoanRequest(EmergencyLoanController.OP.ACCEPT_QUOTE, nil, token)
        if ev == nil then deliver(nil); return false, "SEQUENCE_EXHAUSTED" end
        self._pendingResult = { sequence = seq, callback = onResult }
        local ok = pcall(function()
            g_client:getServerConnection():sendEvent(ev)
        end)
        if not ok then self._pendingResult = nil; deliver(nil) end
        return ok
    end
    deliver(nil)
    return false
end

--- Drop owner-UI request state (teardown, farm/mission change). Waiting callbacks are
--- released without being called: a torn-down dialog must never resolve a confirmation.
function IncomeManager:clearEmergencyLoanUiState()
    self._pendingQuote  = nil
    self._pendingResult = nil
    self._pendingAccept = false
end

function IncomeManager:_uiQuoteThenAccept(quoteOp, amountText)
    local isServer = g_currentMission and g_currentMission.getIsServer and g_currentMission:getIsServer()
    if isServer then
        local ev = self:_newLoanRequest(quoteOp, amountText)
        if ev == nil then return false, "SEQUENCE_EXHAUSTED" end
        local quote = self:handleEmergencyLoanRequest(ev, nil)
        self:onEmergencyLoanReply(quote)
        if quote and quote.token ~= nil and quote.token ~= "" then
            local ev2 = self:_newLoanRequest(EmergencyLoanController.OP.ACCEPT_QUOTE, nil, quote.token)
            if ev2 == nil then return false, "SEQUENCE_EXHAUSTED" end
            local accepted = self:handleEmergencyLoanRequest(ev2, nil)
            self._emergencyView = accepted
        end
        return true
    end
    if g_client and g_client.getServerConnection and EmergencyLoanEvent then
        if self:_isLoanUiBusy() then return false, "BUSY" end
        local ev = self:_newLoanRequest(quoteOp, amountText)
        if ev == nil then return false, "SEQUENCE_EXHAUSTED" end
        self._pendingAccept = true
        return pcall(function()
            g_client:getServerConnection():sendEvent(ev)
        end)
    end
    return false
end

--- Server: handle one owner request from a connection and return the reply payload.
--- Discipline (RSF-F309 item 6, the same order as EmergencyLoanController.evaluateManual,
--- C3-SDS:214/218): resolve the actor, farm and rights FIRST, so nothing cached is
--- disclosed to the wrong hands; then the session sequence (older refuses, an exact
--- retry of the last command returns its cached result without running again, a
--- changed payload on the same sequence refuses); then the quote token; then apply.
--- VIEW is view-only and outside the command discipline. ACCEPT_QUOTE consumes the
--- token once and re-reads every assumption the quote bound (revision, readiness, cash,
--- terms, and for a borrow the recomputed offer) before moving the BOUND sum, never a
--- recomputed one (item 5). Replies go only to the requesting connection (the caller
--- sends it).
function IncomeManager:handleEmergencyLoanRequest(event, connection)
    local C = EmergencyLoanController
    local loan = self.emergencyLoan
    local seq = event and event.sequence or 0
    if loan == nil then return { status = "UNAVAILABLE", sequence = seq } end

    -- 1. actor, farm, rights
    local actor, reason = C.resolveActor(connection)
    if actor == nil then return { status = reason or "NO_ACTOR", sequence = seq } end
    local farmId = actor.farmId
    local op = event.operation

    if op == C.OP.VIEW then
        return self:_viewReply(loan:getView(farmId, { isManager = actor.isManager }), seq)
    end
    if actor.isManager ~= true then
        return self:_viewReply(loan:getView(farmId, { isManager = false }), seq, "NOT_MANAGER")
    end

    -- 2. session sequence: monotonic, exact retry cached, changed payload refused
    local session = self:_loanSession(connection)
    if type(seq) ~= "number" or seq ~= seq or seq < 1 or seq > C.MAX_SEQUENCE or seq ~= math.floor(seq) then
        return self:_viewReply(loan:getView(farmId, { isManager = true }), seq, "BAD_SEQUENCE")
    end
    if seq < session.highest then
        return self:_viewReply(loan:getView(farmId, { isManager = true }), seq, "OLD_SEQUENCE")
    end
    if seq == session.highest then
        local last = session.lastCommand
        if last ~= nil and last.farmId == farmId and last.operation == op
            and last.amountText == (event.amountText or "") and last.token == (event.token or "") then
            local cached = {}
            for k, v in pairs(session.lastResult or {}) do cached[k] = v end
            cached.sequence = seq
            return cached
        end
        return self:_viewReply(loan:getView(farmId, { isManager = true }), seq, "CHANGED_PAYLOAD")
    end

    -- Reserve the sequence BEFORE any money moves; record the command and its result
    -- so an exact retry is answered from the record and never applied twice.
    session.highest = seq
    session.lastCommand = { farmId = farmId, operation = op,
                            amountText = event.amountText or "", token = event.token or "" }
    local function record(reply)
        session.lastResult = reply
        return reply
    end

    if loan:getReadiness() == EmergencyLoan.READINESS.UNAVAILABLE then
        return record(self:_viewReply(loan:getView(farmId, { isManager = true }), seq, "UNAVAILABLE"))
    end

    -- 3. quotes
    if op == C.OP.BORROW_QUOTE then
        local offer = loan:computeOffer(farmId)
        local view = loan:getView(farmId, { isManager = true })
        if not offer or offer <= 0 then return record(self:_viewReply(view, seq, "NO_SHORTFALL")) end
        local quote = self:_quoteBinding(loan, farmId)
        quote.op = "borrow"; quote.farmId = farmId; quote.amount = offer
        local token = self:_mintQuote(session, quote)
        local reply = self:_viewReply(view, seq); reply.token = token; reply.offer = offer
        reply.quoteAmount = offer
        return record(reply)
    elseif op == C.OP.MANUAL_AMOUNT_QUOTE or op == C.OP.PAYOFF_QUOTE then
        local debt = loan.debts[farmId]
        local view = loan:getView(farmId, { isManager = true })
        if not debt or not debt.active then return record(self:_viewReply(view, seq, "NO_DEBT")) end
        local amount
        if op == C.OP.PAYOFF_QUOTE then
            amount = loan:payoffAmount(farmId)
        else
            amount = C.parseAmount(event.amountText)
            if not amount or amount <= 0 then return record(self:_viewReply(view, seq, "INVALID_AMOUNT")) end
            local cash = loan:getBalance(farmId)
            amount = math.min(amount, loan:getOutstanding(farmId))
            if cash ~= nil and cash > 0 then amount = math.min(amount, cash) end
        end
        local quote = self:_quoteBinding(loan, farmId)
        quote.op = "repay"; quote.farmId = farmId; quote.amount = amount
        local token = self:_mintQuote(session, quote)
        local reply = self:_viewReply(view, seq); reply.token = token
        -- The amount the server actually bound, after clamping the requested value to
        -- current cash and debt. The player confirms THIS sum, not the one typed.
        reply.quoteAmount = amount
        return record(reply)

    -- 4. accept: token, then every bound assumption, then the bound sum
    elseif op == C.OP.ACCEPT_QUOTE then
        local quote = session.quote
        local view = loan:getView(farmId, { isManager = true })
        if quote == nil or quote.token ~= (event.token or "") or quote.farmId ~= farmId then
            return record(self:_viewReply(view, seq, "STALE_QUOTE"))
        end
        session.quote = nil  -- consume once
        local now = self:_quoteBinding(loan, farmId)
        local status
        if quote.op == "borrow" then
            local offerNow = loan:computeOffer(farmId)
            if not bindingMatches(quote, now, true) or offerNow ~= quote.amount then
                status = "STALE_QUOTE"
            else
                -- Explicit branch selection (item 5): an active line re-draws, a
                -- missing or retired one is granted; a refusal is REFUSED and never
                -- falls through into the other branch.
                local debt = loan.debts[farmId]
                local ok
                if debt ~= nil and debt.active == true then
                    ok = loan:redraw(farmId, quote.amount)
                else
                    ok = loan:grant(farmId, quote.amount)
                end
                status = (ok == true) and "ACCEPTED" or "REFUSED"
            end
        else
            local debt = loan.debts[farmId]
            local cash = now.cash
            if not debt or not debt.active then status = "NO_DEBT"
            elseif not bindingMatches(quote, now, false) then status = "STALE_QUOTE"
            elseif cash == nil or quote.amount > cash then status = "INSUFFICIENT_CASH"
            else status = (loan:applyManualPayment(farmId, quote.amount) > 0) and "ACCEPTED" or "REFUSED" end
        end
        if status == "ACCEPTED" then self:saveEmergencyDebt() end
        local reply = self:_viewReply(loan:getView(farmId, { isManager = true }), seq)
        reply.status = status
        return record(reply)
    end

    return record({ status = "UNKNOWN_OP", sequence = seq })
end

-- =========================================================
-- Cleanup
-- =========================================================

function IncomeManager:delete()
    -- RSF-F201: retire this owner's registration activity first. The PLAYER
    -- wrapper itself stays installed (restoring it per mission can remove a
    -- later mod's wrapper); the next IncomeManager.new re-arms it.
    IncomeManager._f201Input.active = false
    self:clearEmergencyLoanUiState()
    -- RSF-F309 item 6: owner sessions (sequences, cached results, quotes) are volatile
    -- and end with the mission; the debt revision persists in the save, so a token from
    -- before a reload can never be accepted after it.
    self._loanSessions = nil

    -- Remove action events for I key (HUD) and U key (Report)
    if self.toggleHUDEventId and g_inputBinding then
        g_inputBinding:removeActionEvent(self.toggleHUDEventId)
        self.toggleHUDEventId = nil
    end

    if self.incomeReportEventId and g_inputBinding then
        g_inputBinding:removeActionEvent(self.incomeReportEventId)
        self.incomeReportEventId = nil
    end
    -- HUD move/edit handle (F201 item 11): it had no teardown arm anywhere before.
    if self.hudEditEventId and g_inputBinding then
        g_inputBinding:removeActionEvent(self.hudEditEventId)
        self.hudEditEventId = nil
    end

    -- Destroy HUD overlay
    if self.incomeHUD then
        self.incomeHUD:saveLayout()
        self.incomeHUD:delete()
        self.incomeHUD = nil
    end

    -- Release singleton dialog reference (the FS25 GUI system owns the element tree;
    -- we just drop our handle so it can be GC'd if the session ends)
    self.incomeReportDialog = nil

    self:save()
    Logging.info("Income Mod: Shut down cleanly")
end
