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

        -- Register key actions via PlayerInputComponent hook (proven race-condition-safe pattern)
        if PlayerInputComponent and PlayerInputComponent.registerActionEvents then
            local originalRegisterActionEvents = PlayerInputComponent.registerActionEvents
            self._inputHookOriginal = originalRegisterActionEvents
            PlayerInputComponent.registerActionEvents = function(inputComponent, ...)
                originalRegisterActionEvents(inputComponent, ...)

                -- Only register for the local owning player, not networked players
                if not (inputComponent.player and inputComponent.player.isOwner) then return end
                -- Guard against double-registration on level reloads
                if g_IncomeManager and g_IncomeManager.toggleHUDEventId then return end
                if not g_IncomeManager or not g_IncomeManager.incomeHUD then return end

                g_inputBinding:beginActionEventsModification(PlayerInputComponent.INPUT_CONTEXT_NAME)

                -- HUD toggle: I key
                local hudOk, hudId = false, nil
                if not __rfMhOwnsHudKeys() then
                    local hudOk, hudId = g_inputBinding:registerActionEvent(
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
                    local edOk, edId = g_inputBinding:registerActionEvent(
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

-- Per-connection owner session (highest sequence, last result, outstanding quotes).
function IncomeManager:_loanSession(connection)
    self._loanSessions = self._loanSessions or {}
    local key = connection or "local"
    local s = self._loanSessions[key]
    if s == nil then
        s = { id = tostring(key), highest = 0, quotes = {}, quoteSeq = 0 }
        self._loanSessions[key] = s
    end
    return s
end

function IncomeManager:_nextLoanSequence()
    self._loanSeq = (self._loanSeq or 0) + 1
    if self._loanSeq > EmergencyLoanController.MAX_SEQUENCE then self._loanSeq = 1 end
    return self._loanSeq
end

function IncomeManager:_mintQuote(session, quote)
    session.quoteSeq = (session.quoteSeq or 0) + 1
    local token = string.format("q%d", session.quoteSeq)
    session.quotes[token] = quote
    return token
end

-- Compact a rich view into the Event reply payload (the wire + the client cache shape).
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
    }
end

--- getEmergencyLoanView(farmId?): on the server a pure authoritative sample (no actor
--- rights => NO_ACTOR_CONTEXT); nil keeps the local farm. On a client, only the local
--- farm's last authoritative reply (a different supplied farmId refuses).
function IncomeManager:getEmergencyLoanView(farmId)
    local loan = self.emergencyLoan
    if loan == nil then return nil, "NO_LOAN" end
    local isServer = g_currentMission and g_currentMission.getIsServer and g_currentMission:getIsServer()
    local localFarmId = nil
    pcall(function()
        if g_currentMission and g_currentMission.getFarmId then localFarmId = g_currentMission:getFarmId() end
    end)
    if isServer then
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
        local ok = pcall(function()
            g_client:getServerConnection():sendEvent(
                EmergencyLoanEvent.newRequest(self:_nextLoanSequence(), EmergencyLoanController.OP.VIEW))
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
    if self._pendingAccept and payload.token ~= nil and payload.token ~= ""
        and g_client and g_client.getServerConnection then
        self._pendingAccept = false
        pcall(function()
            g_client:getServerConnection():sendEvent(
                EmergencyLoanEvent.newRequest(self:_nextLoanSequence(),
                    EmergencyLoanController.OP.ACCEPT_QUOTE, nil, payload.token))
        end)
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

function IncomeManager:_uiQuoteThenAccept(quoteOp, amountText)
    local isServer = g_currentMission and g_currentMission.getIsServer and g_currentMission:getIsServer()
    if isServer then
        local quote = self:handleEmergencyLoanRequest(
            EmergencyLoanEvent.newRequest(self:_nextLoanSequence(), quoteOp, amountText), nil)
        self:onEmergencyLoanReply(quote)
        if quote and quote.token ~= nil and quote.token ~= "" then
            local accepted = self:handleEmergencyLoanRequest(
                EmergencyLoanEvent.newRequest(self:_nextLoanSequence(),
                    EmergencyLoanController.OP.ACCEPT_QUOTE, nil, quote.token), nil)
            self._emergencyView = accepted
        end
        return true
    end
    if g_client and g_client.getServerConnection and EmergencyLoanEvent then
        self._pendingAccept = true
        return pcall(function()
            g_client:getServerConnection():sendEvent(
                EmergencyLoanEvent.newRequest(self:_nextLoanSequence(), quoteOp, amountText))
        end)
    end
    return false
end

--- Server: handle one owner request from a connection and return the reply payload.
--- VIEW is view-only; quotes require farm-manager rights; ACCEPT_QUOTE consumes a minted
--- quote once and re-checks revision/cash before moving money. Replies go only to the
--- requesting connection (the caller sends it).
function IncomeManager:handleEmergencyLoanRequest(event, connection)
    local loan = self.emergencyLoan
    local seq = event and event.sequence or 0
    if loan == nil then return { status = "UNAVAILABLE", sequence = seq } end

    local actor, reason = EmergencyLoanController.resolveActor(connection)
    if actor == nil then return { status = reason or "NO_ACTOR", sequence = seq } end
    local farmId = actor.farmId
    local session = self:_loanSession(connection)
    local op = event.operation

    if op == EmergencyLoanController.OP.VIEW then
        return self:_viewReply(loan:getView(farmId, { isManager = actor.isManager }), seq)
    end

    -- All quote/accept operations require farm-manager rights on the acting farm.
    if actor.isManager ~= true then
        return self:_viewReply(loan:getView(farmId, { isManager = false }), seq, "NOT_MANAGER")
    end
    if loan:getReadiness() == EmergencyLoan.READINESS.UNAVAILABLE then
        return self:_viewReply(loan:getView(farmId, { isManager = true }), seq, "UNAVAILABLE")
    end

    if op == EmergencyLoanController.OP.BORROW_QUOTE then
        local offer = loan:computeOffer(farmId)
        local view = loan:getView(farmId, { isManager = true })
        if not offer or offer <= 0 then return self:_viewReply(view, seq, "NO_SHORTFALL") end
        local token = self:_mintQuote(session, { op = "borrow", farmId = farmId, amount = offer,
            revision = (loan.debts[farmId] and loan.debts[farmId].revision) or 0 })
        local reply = self:_viewReply(view, seq); reply.token = token; reply.offer = offer
        return reply
    elseif op == EmergencyLoanController.OP.MANUAL_AMOUNT_QUOTE or op == EmergencyLoanController.OP.PAYOFF_QUOTE then
        local debt = loan.debts[farmId]
        local view = loan:getView(farmId, { isManager = true })
        if not debt or not debt.active then return self:_viewReply(view, seq, "NO_DEBT") end
        local amount
        if op == EmergencyLoanController.OP.PAYOFF_QUOTE then
            amount = loan:payoffAmount(farmId)
        else
            amount = EmergencyLoanController.parseAmount(event.amountText)
            if not amount or amount <= 0 then return self:_viewReply(view, seq, "INVALID_AMOUNT") end
            local cash = loan:getBalance(farmId)
            amount = math.min(amount, loan:getOutstanding(farmId))
            if cash ~= nil and cash > 0 then amount = math.min(amount, cash) end
        end
        local token = self:_mintQuote(session, { op = "repay", farmId = farmId, amount = amount,
            revision = debt.revision })
        local reply = self:_viewReply(view, seq); reply.token = token
        return reply
    elseif op == EmergencyLoanController.OP.ACCEPT_QUOTE then
        local quote = session.quotes[event.token or ""]
        local view = loan:getView(farmId, { isManager = true })
        if quote == nil or quote.farmId ~= farmId then
            return self:_viewReply(view, seq, "STALE_QUOTE")
        end
        session.quotes[event.token] = nil  -- consume once
        local status
        if quote.op == "borrow" then
            local rev = (loan.debts[farmId] and loan.debts[farmId].revision) or 0
            if rev ~= quote.revision then status = "STALE_QUOTE"
            else
                local ok = (loan.debts[farmId] and loan.debts[farmId].active) and loan:redraw(farmId) or loan:grant(farmId)
                status = ok and "ACCEPTED" or "REFUSED"
            end
        else
            local debt = loan.debts[farmId]
            local cash = loan:getBalance(farmId)
            if not debt or not debt.active then status = "NO_DEBT"
            elseif debt.revision ~= quote.revision then status = "STALE_QUOTE"
            elseif cash == nil or quote.amount > cash then status = "INSUFFICIENT_CASH"
            else status = (loan:applyManualPayment(farmId, quote.amount) > 0) and "ACCEPTED" or "REFUSED" end
        end
        if status == "ACCEPTED" then self:saveEmergencyDebt() end
        local reply = self:_viewReply(loan:getView(farmId, { isManager = true }), seq)
        reply.status = status
        return reply
    end

    return { status = "UNKNOWN_OP", sequence = seq }
end

-- =========================================================
-- Cleanup
-- =========================================================

function IncomeManager:delete()
    -- Remove action events for I key (HUD) and U key (Report)
    if self.toggleHUDEventId and g_inputBinding then
        g_inputBinding:removeActionEvent(self.toggleHUDEventId)
        self.toggleHUDEventId = nil
    end

    if self.incomeReportEventId and g_inputBinding then
        g_inputBinding:removeActionEvent(self.incomeReportEventId)
        self.incomeReportEventId = nil
    end

    -- Restore the PlayerInputComponent hook if we patched it
    if self._inputHookOriginal and PlayerInputComponent then
        PlayerInputComponent.registerActionEvents = self._inputHookOriginal
        self._inputHookOriginal = nil
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
