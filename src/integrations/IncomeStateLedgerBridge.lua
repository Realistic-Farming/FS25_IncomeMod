-- =========================================================
-- FS25 Income Mod
-- =========================================================
-- IncomeStateLedgerBridge - optional bridge to FS25_StateLedger (bedrock)
-- =========================================================
-- Author: TisonK
-- =========================================================
-- COPYRIGHT NOTICE:
-- All rights reserved. Unauthorized redistribution, copying,
-- or claiming this code as your own is strictly prohibited.
-- Original author: TisonK
-- =========================================================
--
-- Strictly delegate-when-present, mirroring SoilFertilizer / WorkerCosts:
--   * StateLedger installed -> the shared master save file is the LOAD source of
--     truth for the income TIMER STATE (lastHour / lastDay / lastMonotonicDay, which
--     prevents a missed or double payment across a reload). FS25_IncomeMod_state.xml
--     is still written every save as the standalone safety copy, so removing the
--     ledger later never loses data.
--   * StateLedger absent -> nothing changes; FS25_IncomeMod_state.xml is primary.
--
-- ONE module only: IncomeMod_State. Settings are NOT a StateLedger module here:
-- settings persistence + MP sync are SettingsHub's domain (it persists admin values
-- via its own ledger module and broadcasts them via NetworkSync), and IncomeMod keeps
-- its own FS25_IncomeMod.xml as the standalone settings fallback. A third settings
-- copy in a per-mod ledger module would just be a conflicting duplicate. This matches
-- SoilFertilizer, whose StateLedger module carries soil state, not settings.
--
-- The HUD layout file (FS25_IncomeMod_hud.xml) stays client-local, untouched.
--
-- Timing note (same as WorkerCosts): IncomeMod loads its timer state in
-- IncomeManager:onMissionLoaded (= loadMission00Finished), the same phase StateLedger
-- parses its file in. So register() force-triggers the idempotent parseFile after
-- registering, guaranteeing deserialize has delivered before loadState reads,
-- independent of mod load order. (SoilFertilizer reads later in onMissionStarted, so
-- hook order never mattered for it.)
--
-- The cross-mod handle is g_currentMission.stateLedger (published in Mission00.load).
-- =========================================================

IncomeStateLedgerBridge = IncomeStateLedgerBridge or {}

-- LOCKED persistence key. Never renamed after first persist.
IncomeStateLedgerBridge.MODULE_ID = "IncomeMod_State"

IncomeStateLedgerBridge.active       = false   -- ledger present and we registered
IncomeStateLedgerBridge.delivered    = false   -- deserialize has fired (once)
IncomeStateLedgerBridge.pendingState = nil     -- cached table (nil = new save / no block)

-- True when the ledger is the timer-state load source of truth this session.
function IncomeStateLedgerBridge.hasState()
    return IncomeStateLedgerBridge.active
        and IncomeStateLedgerBridge.delivered
        and IncomeStateLedgerBridge.pendingState ~= nil
end

-- Apply the cached timer-state block into the income system. Returns true on apply.
function IncomeStateLedgerBridge.applyState(incomeSystem)
    if incomeSystem == nil or type(IncomeStateLedgerBridge.pendingState) ~= "table" then
        return false
    end
    incomeSystem:loadState(IncomeStateLedgerBridge.pendingState)
    return true
end

-- Register with StateLedger if present. Called from IncomeManager:onMissionLoaded,
-- before self:loadState() reads the timer state.
function IncomeStateLedgerBridge.register(im)
    IncomeStateLedgerBridge.active       = false
    IncomeStateLedgerBridge.delivered    = false
    IncomeStateLedgerBridge.pendingState = nil

    local ledger = (g_currentMission ~= nil and g_currentMission.stateLedger) or g_stateLedger
    if ledger == nil then
        Logging.info("Income Mod: StateLedger not detected; timer state uses its own FS25_IncomeMod_state.xml")
        return
    end
    if im == nil then return end

    local ok, err = pcall(function()
        ledger:registerModule(IncomeStateLedgerBridge.MODULE_ID, {
            serialize = function()
                local sys = im.incomeSystem
                if sys ~= nil and sys.saveState ~= nil then
                    return sys:saveState()
                end
                return { lastHour = -1, lastDay = -1, lastMonotonicDay = -1 }
            end,
            deserialize = function(data)
                IncomeStateLedgerBridge.delivered    = true
                IncomeStateLedgerBridge.pendingState = data   -- nil on a brand-new save
            end,
        })
    end)

    if not ok then
        Logging.warning("Income Mod: StateLedger registration failed: %s (falling back to own XML)", tostring(err))
        return
    end

    IncomeStateLedgerBridge.active = true

    -- Force the (idempotent) parse now so deserialize has delivered before loadState
    -- reads a few lines later, independent of which mod's loadMission00Finished handler
    -- ran first. A no-op if StateLedger already parsed (it loaded first).
    if ledger.parseFile ~= nil then
        pcall(function() ledger:parseFile() end)
    end

    Logging.info("Income Mod: Registered with StateLedger as '%s' (FS25_IncomeMod_state.xml kept as safety copy)",
        IncomeStateLedgerBridge.MODULE_ID)
end
