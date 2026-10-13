-- =========================================================
-- FS25 Income Mod - IM-6 income schedule: host authority + Event
-- =========================================================
-- The administrator chooses one whole-number amount; Daily pays it once per in-game
-- day, Hourly once per in-game hour. The host is the sole writer of the amount, the
-- pay mode and the money. Every change goes through one validator on the server:
--
--   administrator -> known operation and mode -> whole number -> range -> revision
--
-- then applies, saves, advances the revision and publishes one copied view. A refused
-- request changes nothing. A client never applies locally: it sends a request and
-- shows WAITING until the host's view arrives.
--
-- The controller below is pure over the manager's settings and live income system, so
-- the bench drives it offline. IncomeScheduleEvent is the wire glue, on the
-- EmergencyLoanEvent pattern (request to the server, reply to the requesting connection
-- only) plus a view broadcast to every client after each accepted change.
--
-- Native bindings (verified): UserManager:getUserByConnection (users/UserManager.lua:74),
-- User:getIsMasterUser (users/User.lua:93), Server:broadcastEvent (network/Server.lua:542),
-- active month length Environment.daysPerPeriod (environment/Environment.lua:377-383).
-- =========================================================

IncomeSchedule = IncomeSchedule or {}

IncomeSchedule.OP = {
    VIEW          = 1,
    PREVIEW       = 2,
    APPLY         = 3,
    RESET_PREVIEW = 4,
    RESET_APPLY   = 5,
}
IncomeSchedule.OP_NAME = {}
for name, code in pairs(IncomeSchedule.OP) do IncomeSchedule.OP_NAME[code] = name end

-- A new amount is 0 through CAP. 0 means the live difficulty default.
IncomeSchedule.CAP = 999999
IncomeSchedule.MAX_TEXT = 32
IncomeSchedule.MAX_CODE = 32
IncomeSchedule.MAX_SEQUENCE = 2147483647

IncomeSchedule.STATE = {
    WAITING     = "WAITING",      -- a client that has no host view yet
    SCHEDULED   = "SCHEDULED",
    DISABLED    = "DISABLED",
    UNAVAILABLE = "UNAVAILABLE",  -- the active month length is not usable
}

IncomeSchedule.UNIT = {
    [1] = "PER_HOUR",   -- Settings.PAY_MODE_HOURLY
    [2] = "PER_DAY",    -- Settings.PAY_MODE_DAILY
}

-- The values a full Reset restores (the existing Settings:resetToDefaults set), listed
-- for the preview a player confirms.
IncomeSchedule.RESET_DEFAULTS = {
    { key = "enabled",             value = true },
    { key = "difficulty",          value = 2 },     -- Normal
    { key = "payMode",             value = 1 },     -- Hourly
    { key = "incomeMultiplier",    value = 1 },     -- 1x
    { key = "customAmount",        value = 0 },     -- the difficulty default
    { key = "seasonalEffects",     value = false },
    { key = "showNotifications",   value = true },
    { key = "showHUD",             value = true },
    { key = "debugMode",           value = false },
    { key = "experimentalSystems", value = false },
}

local function finite(v)
    return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

--- ASCII whole-number text, optional surrounding spaces. No sign, decimal point,
--- exponent or grouping punctuation is accepted. Returns the number, or nil and
--- NOT_WHOLE_NUMBER. The range is checked separately (see checkRange).
function IncomeSchedule.parseWholeAmount(text)
    if type(text) ~= "string" or #text > IncomeSchedule.MAX_TEXT then
        return nil, "NOT_WHOLE_NUMBER"
    end
    local trimmed = text:match("^%s*(.-)%s*$")
    if trimmed == nil or trimmed == "" or not trimmed:match("^%d+$") then
        return nil, "NOT_WHOLE_NUMBER"
    end
    local value = tonumber(trimmed)
    if not finite(value) then return nil, "NOT_WHOLE_NUMBER" end
    return value
end

--- 0 through CAP for a new amount. An amount above CAP passes only when it is the
--- exact amount already saved (a legacy save), so a mode-only change keeps it.
function IncomeSchedule.checkRange(value, currentAmount)
    if value >= 0 and value <= IncomeSchedule.CAP then return true end
    return value == currentAmount
end

--- The active month length, or nil when it is not usable.
function IncomeSchedule.activeDaysPerPeriod()
    local env = g_currentMission ~= nil and g_currentMission.environment or nil
    local d = env ~= nil and env.daysPerPeriod or nil
    if finite(d) and d > 0 then return d end
    return nil
end

--- The payment path's own seasonal factor (IncomeSystem:getSeasonalMultiplier), with
--- the payment path's built 1.0 fallback.
local function seasonFactor(incomeSystem)
    if incomeSystem ~= nil and incomeSystem.getSeasonalMultiplier ~= nil then
        local ok, f = pcall(incomeSystem.getSeasonalMultiplier, incomeSystem)
        if ok and finite(f) then return f end
    end
    return 1.0
end

--- A settings-shaped probe carrying `amount` and `mode` over the live settings, so the
--- view is computed by the real Settings:getPaymentAmount / getDifficultyAmount.
local function probeSettings(settings, overrides)
    local probe = setmetatable({}, { __index = settings })
    for k, v in pairs(overrides or {}) do probe[k] = v end
    return probe
end

--- The accepted view (brief 3.1), copied. `settings` is the live Settings or a probe;
--- `incomeSystem` the live instance (its seasonal factor); `canEdit` the requester's
--- advisory capability (nil = not stated, e.g. a broadcast).
function IncomeSchedule.buildView(settings, incomeSystem, revision, canEdit)
    local amount = tonumber(settings.customAmount) or 0
    local payment = settings:getPaymentAmount()
    local factor = seasonFactor(incomeSystem)
    local days = IncomeSchedule.activeDaysPerPeriod()

    local view = {
        revision              = revision or 0,
        unit                  = IncomeSchedule.UNIT[settings.payMode] or "PER_HOUR",
        amount                = amount,
        usesDifficultyDefault = amount == 0,
        defaultAmount         = settings:getDifficultyAmount(),
        payment               = payment,
        paymentThisSeason     = EmergencyLoan.payoutGross(payment, factor),
        daysThisMonth         = days,
        paymentsThisMonth     = nil,
        monthEstimate         = nil,
        canEdit               = canEdit,
        legacyOverCap         = amount > IncomeSchedule.CAP,
        -- The inputs the existing readers show beside the amount (IM-6 3.6: every reader
        -- reads the accepted view, and a client's own settings are not the host's).
        enabled               = settings.enabled == true,
        difficulty            = settings.difficulty,
        incomeMultiplier      = settings.incomeMultiplier,
        seasonalEffects       = settings.seasonalEffects == true,
        seasonFactor          = factor,
    }
    if days ~= nil then
        view.paymentsThisMonth = EmergencyLoan.payoutsPerPeriod(settings.payMode, days)
        view.monthEstimate     = EmergencyLoan.periodGross(payment, factor, settings.payMode, days)
    end
    -- DISABLED first: it is a fact about the schedule a reader must show (on or off),
    -- where UNAVAILABLE only says the month estimate cannot be made. A disabled schedule
    -- with an unknown month length is DISABLED with no estimate (nil, never 0).
    if settings.enabled ~= true then
        view.paymentState = IncomeSchedule.STATE.DISABLED   -- the estimate is hypothetical
    elseif days == nil then
        view.paymentState = IncomeSchedule.STATE.UNAVAILABLE
    else
        view.paymentState = IncomeSchedule.STATE.SCHEDULED
    end
    return view
end

--- Is the requester an administrator? The local server actor (the host's own UI, a
--- listen host, a dedicated server's console) arrives with no connection and is the
--- administrator, as SettingsHub's admin pattern treats the local host. A remote
--- request is an administrator only when its user is the master user.
function IncomeSchedule.isAdmin(connection)
    if connection == nil then return true end
    local mission = g_currentMission
    local um = mission ~= nil and mission.userManager or nil
    if um == nil or um.getUserByConnection == nil then return false end
    local ok, user = pcall(um.getUserByConnection, um, connection)
    if not ok or user == nil or user.getIsMasterUser == nil then return false end
    local okM, isMaster = pcall(user.getIsMasterUser, user)
    return okM and isMaster == true
end

--- Validate a request against the host's state in the brief's order. Pure: writes
--- nothing. Returns { status, amount, mode } where status is "OK" or a refusal code.
--- req: { operation, amountText ("" keeps the saved amount), mode (0 keeps the saved
---        mode), revision, confirm }
function IncomeSchedule.validate(settings, revision, isAdmin, req)
    local OP = IncomeSchedule.OP
    local op = req.operation
    if op == OP.VIEW then return { status = "OK" } end

    -- 1. administrator
    if isAdmin ~= true then return { status = "NOT_ADMIN" } end

    -- 2. known operation and pay mode
    if IncomeSchedule.OP_NAME[op] == nil then return { status = "UNKNOWN_OPERATION" } end
    if op == OP.RESET_PREVIEW or op == OP.RESET_APPLY then
        if op == OP.RESET_APPLY then
            if req.revision ~= revision then return { status = "STALE_PREVIEW" } end
            if req.confirm ~= true then return { status = "CONFIRM_REQUIRED" } end
        end
        return { status = "OK" }
    end
    local mode = req.mode
    if mode == nil or mode == 0 then mode = settings.payMode end
    if IncomeSchedule.UNIT[mode] == nil then return { status = "UNKNOWN_PAY_MODE" } end

    -- 3. whole number, 4. range
    local current = tonumber(settings.customAmount) or 0
    local amount = current
    if req.amountText ~= nil and req.amountText ~= "" then
        local value, reason = IncomeSchedule.parseWholeAmount(req.amountText)
        if value == nil then return { status = reason } end
        if not IncomeSchedule.checkRange(value, current) then return { status = "OUT_OF_RANGE" } end
        amount = value
    end

    -- 5. current revision for every player-facing apply, amount-only included
    if op == OP.APPLY and req.revision ~= revision then
        return { status = "STALE_PREVIEW" }
    end
    return { status = "OK", amount = amount, mode = mode }
end

--- Serve one request as the host. Mutates only on an accepted APPLY / RESET_APPLY.
--- Returns the reply payload { status, operation, view, revision }. `mgr` is the
--- IncomeManager (settings, incomeSystem, scheduleRevision).
function IncomeSchedule.serve(mgr, isAdmin, req)
    local OP = IncomeSchedule.OP
    local settings = mgr.settings
    local revision = mgr.scheduleRevision or 0
    local verdict = IncomeSchedule.validate(settings, revision, isAdmin, req)
    local reply = { status = verdict.status, operation = req.operation, sequence = req.sequence }

    if verdict.status ~= "OK" then
        -- A refusal changes nothing; a stale preview carries a fresh view.
        reply.view = IncomeSchedule.buildView(settings, mgr.incomeSystem, revision, isAdmin == true)
        return reply
    end

    local op = req.operation
    if op == OP.VIEW then
        reply.view = IncomeSchedule.buildView(settings, mgr.incomeSystem, revision, isAdmin == true)
    elseif op == OP.PREVIEW then
        local probe = probeSettings(settings, { customAmount = verdict.amount, payMode = verdict.mode })
        reply.view = IncomeSchedule.buildView(probe, mgr.incomeSystem, revision, true)
    elseif op == OP.RESET_PREVIEW then
        local overrides = {}
        for _, d in ipairs(IncomeSchedule.RESET_DEFAULTS) do overrides[d.key] = d.value end
        reply.view = IncomeSchedule.buildView(probeSettings(settings, overrides), mgr.incomeSystem, revision, true)
    elseif op == OP.APPLY then
        local modeChanged = verdict.mode ~= settings.payMode
        settings.customAmount = verdict.amount
        settings.payMode = verdict.mode
        if modeChanged then IncomeSchedule.rebaseLiveMarkers(mgr) end
        IncomeSchedule.commit(mgr)
        reply.view = IncomeSchedule.buildView(settings, mgr.incomeSystem, mgr.scheduleRevision, true)
    elseif op == OP.RESET_APPLY then
        settings:resetToDefaults(false)
        IncomeSchedule.rebaseLiveMarkers(mgr)
        IncomeSchedule.commit(mgr)
        reply.view = IncomeSchedule.buildView(settings, mgr.incomeSystem, mgr.scheduleRevision, true)
    end
    reply.revision = reply.view and reply.view.revision or revision
    return reply
end

--- Every accepted mode change and every full Reset: the live income system's payout
--- markers move to now, so the next poll counts from the change and the switch itself
--- pays nothing. Writes the live instance only, never the IncomeSystem class table.
function IncomeSchedule.rebaseLiveMarkers(mgr)
    local sys = mgr ~= nil and mgr.incomeSystem or nil
    local env = g_currentMission ~= nil and g_currentMission.environment or nil
    if sys == nil or env == nil or sys.rebaseForScheduleChange == nil then return false end
    sys:rebaseForScheduleChange(env)
    return true
end

--- After an accepted change: save, advance the revision, publish the view, refresh the
--- host's own Esc controls.
function IncomeSchedule.commit(mgr)
    if mgr.settings ~= nil and mgr.settings.save ~= nil then mgr.settings:save() end
    mgr.scheduleRevision = (mgr.scheduleRevision or 0) + 1
    if mgr.publishIncomeScheduleView ~= nil then mgr:publishIncomeScheduleView(true) end
    if mgr.settingsUI ~= nil and mgr.settingsUI.refreshUI ~= nil then
        pcall(mgr.settingsUI.refreshUI, mgr.settingsUI)
    end
end

-- =========================================================
-- Readers (IM-6 3.6): the HUD, the report, the RfPda guest and the Esc page
-- =========================================================
-- Every reader shows the host's accepted view. On a client this machine's own settings
-- are its local defaults, not the host's schedule, so no reader reads them.

IncomeSchedule.GATE = "im6_income_schedule"

--- The typed Esc amount control and the schedule explanation are LOCKED behind the
--- gate (brief 3.7). Fail closed: an unreadable opt-in keeps them hidden. The host
--- authority itself is never gated.
function IncomeSchedule.explanationReleased()
    if ReleaseGate == nil or ReleaseGate.isReleased == nil then return false end
    local optIn = nil
    if ReleaseGate.liveOptIn ~= nil then optIn = ReleaseGate.liveOptIn() end
    return ReleaseGate.isReleased(IncomeSchedule.GATE, optIn) == true
end

--- The accepted view for a reader (of `mgr`, else g_IncomeManager); WAITING when there
--- is none yet.
function IncomeSchedule.readerView(mgr)
    mgr = mgr or g_IncomeManager
    local view = nil
    if mgr ~= nil and mgr.getIncomeScheduleView ~= nil then view = mgr:getIncomeScheduleView() end
    return view or { paymentState = IncomeSchedule.STATE.WAITING }
end

-- Settings' own getters over a view's values; the payment is the host's figure.
local ReaderSettings = setmetatable({}, { __index = function(_, key) return Settings[key] end })
function ReaderSettings:getPaymentAmount() return self.payment end

--- A settings-shaped, read-only copy of an accepted view, so each reader keeps its own
--- layout and getters while every value it shows is the host's. nil while WAITING.
function IncomeSchedule.readerSettings(view)
    if type(view) ~= "table" or view.paymentState == nil or view.paymentState == IncomeSchedule.STATE.WAITING then
        return nil
    end
    return setmetatable({
        enabled          = view.enabled == true,
        payMode          = view.unit == "PER_DAY" and 2 or 1,
        difficulty       = view.difficulty,
        incomeMultiplier = view.incomeMultiplier,
        seasonalEffects  = view.seasonalEffects == true,
        customAmount     = view.amount,
        payment          = view.payment,
    }, { __index = ReaderSettings })
end

--- When the next payment falls, from the accepted mode and this machine's clock; nil
--- when nothing is scheduled (WAITING or DISABLED).
function IncomeSchedule.nextPaymentInfo(view)
    local s = IncomeSchedule.readerSettings(view)
    if s == nil or s.enabled ~= true or IncomeSystem == nil or IncomeSystem.getNextPaymentInfo == nil then
        return nil
    end
    -- IncomeSystem:getNextPaymentInfo reads only self.settings.payMode and the clock.
    return IncomeSystem.getNextPaymentInfo({ settings = s })
end

local function text(key, fallback)
    if g_i18n ~= nil and g_i18n.hasText ~= nil and g_i18n:hasText(key) then
        return g_i18n:getText(key)
    end
    return fallback or key
end
IncomeSchedule.text = text

function IncomeSchedule.money(v)
    if v == nil then return "--" end
    if g_i18n ~= nil and g_i18n.formatMoney ~= nil then
        return g_i18n:formatMoney(v, 0, true, true)
    end
    return string.format("$%d", math.floor(v))
end

--- "Current seasonal adjustment: 1.2x" (brief 3.6: never a season named from the
--- ambiguous label path).
function IncomeSchedule.seasonAdjustText(view)
    local factor = type(view) == "table" and tonumber(view.seasonFactor) or nil
    return string.format(text("im6_season_adjust", "Current seasonal adjustment: %s"),
        factor ~= nil and string.format("%.1fx", factor) or "--")
end

--- The explanation a reader adds when the gate is released: the month at this rate
--- (hypothetical when income is off, unavailable when the month length is unknown,
--- never 0) and that the one amount applies to every active farm. {} while WAITING.
function IncomeSchedule.explanationLines(view)
    local lines = {}
    if type(view) ~= "table" or view.paymentState == nil or view.paymentState == IncomeSchedule.STATE.WAITING then
        return lines
    end
    if view.paymentState == IncomeSchedule.STATE.DISABLED then
        lines[#lines + 1] = text("im6_line_disabled", "Income is off; the figures below are what it would pay if it were on.")
    end
    if view.monthEstimate == nil or view.daysThisMonth == nil then
        lines[#lines + 1] = text("im6_line_month_unavailable", "Month estimate: not available (the month length is not known).")
    else
        lines[#lines + 1] = string.format(text("im6_line_month", "Month of %s days: %s payments, about %s gross before any loan repayment."),
            tostring(view.daysThisMonth), tostring(view.paymentsThisMonth or 0), IncomeSchedule.money(view.monthEstimate))
    end
    lines[#lines + 1] = text("im6_line_every_farm", "The amount applies to every active farm. Nothing is paid at the moment of a change.")
    return lines
end

-- =========================================================
-- Wire: IncomeScheduleEvent
-- =========================================================
-- One class, three kinds: a REQUEST (client to server), a REPLY (server to the
-- requesting connection only) and a VIEW (server to every client after an accepted
-- change, or when the host's view moves). Money and counts travel as the loan's
-- nil-preserving decimal text, so an unknown estimate never arrives as 0.

IncomeScheduleEvent = IncomeScheduleEvent or {}
local IncomeScheduleEvent_mt = Class(IncomeScheduleEvent, Event)
InitEventClass(IncomeScheduleEvent, "IncomeScheduleEvent")

IncomeScheduleEvent.KIND = { REQUEST = 1, REPLY = 2, VIEW = 3 }

function IncomeScheduleEvent.emptyNew()
    return Event.new(IncomeScheduleEvent_mt)
end

function IncomeScheduleEvent.newRequest(sequence, operation, amountText, mode, revision, confirm)
    local self = IncomeScheduleEvent.emptyNew()
    self.kind       = IncomeScheduleEvent.KIND.REQUEST
    self.sequence   = sequence or 1
    self.operation  = operation or IncomeSchedule.OP.VIEW
    self.amountText = amountText or ""
    self.mode       = mode or 0
    self.revision   = revision or 0
    self.confirm    = confirm == true
    return self
end

function IncomeScheduleEvent.newReply(payload)
    local self = IncomeScheduleEvent.emptyNew()
    self.kind = IncomeScheduleEvent.KIND.REPLY
    self.payload = payload or {}
    return self
end

function IncomeScheduleEvent.newView(view)
    local self = IncomeScheduleEvent.emptyNew()
    self.kind = IncomeScheduleEvent.KIND.VIEW
    self.payload = { view = view }
    return self
end

local function clampInt(v, hi)
    local n = tonumber(v) or 0
    if n ~= n then n = 0 end
    return math.max(0, math.min(math.floor(n), hi))
end

--- canEdit on the wire: 0 not stated, 1 no, 2 yes.
local function encodeTri(v)
    if v == nil then return 0 end
    return v == true and 2 or 1
end
local function decodeTri(n)
    if n == 2 then return true elseif n == 1 then return false end
    return nil
end

function IncomeScheduleEvent.writeView(streamId, v)
    local C = EmergencyLoanController
    streamWriteBool(streamId, v ~= nil)
    if v == nil then return end
    streamWriteUIntN(streamId, clampInt(v.revision, IncomeSchedule.MAX_SEQUENCE), 31)
    streamWriteString(streamId, C.encodeCode(v.unit))
    streamWriteString(streamId, C.encodeAmount(v.amount))
    streamWriteBool(streamId, v.usesDifficultyDefault == true)
    streamWriteString(streamId, C.encodeAmount(v.defaultAmount))
    streamWriteString(streamId, C.encodeAmount(v.payment))
    streamWriteString(streamId, C.encodeAmount(v.paymentThisSeason))
    streamWriteInt32(streamId, C.encodeOptInt(v.daysThisMonth))
    streamWriteInt32(streamId, C.encodeOptInt(v.paymentsThisMonth))
    streamWriteString(streamId, C.encodeAmount(v.monthEstimate))
    streamWriteString(streamId, C.encodeCode(v.paymentState))
    streamWriteUInt8(streamId, encodeTri(v.canEdit))
    streamWriteBool(streamId, v.legacyOverCap == true)
    streamWriteBool(streamId, v.enabled == true)
    streamWriteUInt8(streamId, clampInt(v.difficulty, 255))
    streamWriteUInt8(streamId, clampInt(v.incomeMultiplier, 255))
    streamWriteBool(streamId, v.seasonalEffects == true)
    streamWriteString(streamId, C.encodeAmount(v.seasonFactor))
end

function IncomeScheduleEvent.readView(streamId)
    local C = EmergencyLoanController
    if not streamReadBool(streamId) then return nil end
    local v = {}
    v.revision              = streamReadUIntN(streamId, 31)
    v.unit                  = C.decodeCode(streamReadString(streamId))
    v.amount                = C.parseAmount(streamReadString(streamId))
    v.usesDifficultyDefault = streamReadBool(streamId)
    v.defaultAmount         = C.parseAmount(streamReadString(streamId))
    v.payment               = C.parseAmount(streamReadString(streamId))
    v.paymentThisSeason     = C.parseAmount(streamReadString(streamId))
    v.daysThisMonth         = C.decodeOptInt(streamReadInt32(streamId))
    v.paymentsThisMonth     = C.decodeOptInt(streamReadInt32(streamId))
    v.monthEstimate         = C.parseAmount(streamReadString(streamId))
    v.paymentState          = C.decodeCode(streamReadString(streamId))
    v.canEdit               = decodeTri(streamReadUInt8(streamId))
    v.legacyOverCap         = streamReadBool(streamId)
    v.enabled               = streamReadBool(streamId)
    v.difficulty            = streamReadUInt8(streamId)
    v.incomeMultiplier      = streamReadUInt8(streamId)
    v.seasonalEffects       = streamReadBool(streamId)
    v.seasonFactor          = C.parseAmount(streamReadString(streamId))
    return v
end

function IncomeScheduleEvent:writeStream(streamId, connection)
    streamWriteUInt8(streamId, self.kind or IncomeScheduleEvent.KIND.REQUEST)
    if self.kind == IncomeScheduleEvent.KIND.REQUEST then
        streamWriteUIntN(streamId, math.max(1, clampInt(self.sequence, IncomeSchedule.MAX_SEQUENCE)), 31)
        streamWriteUInt8(streamId, clampInt(self.operation, 255))
        streamWriteString(streamId, tostring(self.amountText or ""):sub(1, IncomeSchedule.MAX_TEXT))
        streamWriteUInt8(streamId, clampInt(self.mode, 255))
        streamWriteUIntN(streamId, clampInt(self.revision, IncomeSchedule.MAX_SEQUENCE), 31)
        streamWriteBool(streamId, self.confirm == true)
    else
        local p = self.payload or {}
        if self.kind == IncomeScheduleEvent.KIND.REPLY then
            streamWriteUIntN(streamId, clampInt(p.sequence, IncomeSchedule.MAX_SEQUENCE), 31)
            streamWriteUInt8(streamId, clampInt(p.operation, 255))
            streamWriteString(streamId, tostring(p.status or "UNAVAILABLE"):sub(1, IncomeSchedule.MAX_CODE))
        end
        IncomeScheduleEvent.writeView(streamId, p.view)
    end
end

function IncomeScheduleEvent:readStream(streamId, connection)
    self.kind = streamReadUInt8(streamId)
    if self.kind == IncomeScheduleEvent.KIND.REQUEST then
        self.sequence   = streamReadUIntN(streamId, 31)
        self.operation  = streamReadUInt8(streamId)
        self.amountText = streamReadString(streamId)
        self.mode       = streamReadUInt8(streamId)
        self.revision   = streamReadUIntN(streamId, 31)
        self.confirm    = streamReadBool(streamId)
    else
        self.payload = {}
        if self.kind == IncomeScheduleEvent.KIND.REPLY then
            self.payload.sequence  = streamReadUIntN(streamId, 31)
            self.payload.operation = streamReadUInt8(streamId)
            self.payload.status    = streamReadString(streamId)
        end
        self.payload.view = IncomeScheduleEvent.readView(streamId)
        -- The revision a confirm must carry back is the one the host previewed at.
        self.payload.revision = self.payload.view ~= nil and self.payload.view.revision or nil
    end
    self:run(connection)
end

function IncomeScheduleEvent:run(connection)
    local mgr = g_IncomeManager
    if mgr == nil then return end
    if self.kind == IncomeScheduleEvent.KIND.REQUEST then
        -- Server: serve the request and reply to THIS connection only.
        if g_server == nil then return end
        local reply = mgr:handleIncomeScheduleRequest(self, connection)
        if connection ~= nil and reply ~= nil then
            connection:sendEvent(IncomeScheduleEvent.newReply(reply))
        end
    elseif g_server ~= nil then
        -- The host is the author of every view; it never takes one from a connection.
        return
    elseif self.kind == IncomeScheduleEvent.KIND.REPLY then
        mgr:onIncomeScheduleReply(self.payload)
    elseif self.kind == IncomeScheduleEvent.KIND.VIEW then
        mgr:onIncomeScheduleView(self.payload.view)
    end
end
