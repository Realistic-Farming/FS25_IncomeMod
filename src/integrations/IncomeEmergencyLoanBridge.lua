-- =========================================================
-- FS25 Income Mod - EMERGENCY LOAN StateLedger bridge (C3)
-- =========================================================
-- Optional bridge to FS25_StateLedger for the emergency-loan DEBT LEDGER.
-- Delegate-when-present, mirroring IncomeStateLedgerBridge:
--   * StateLedger installed -> the shared master save file is the load source of
--     truth for the per-farm emergency-debt ledger.
--   * StateLedger absent -> the loan is session-only (a recovery hatch degrades
--     to "you can still borrow this session" rather than refusing, which would
--     violate C1).
-- A SECOND module id beside IncomeMod_State: the debt ledger is separate state
-- from the income timer (different cadence, different merge rules).
-- =========================================================

IncomeEmergencyLoanBridge = IncomeEmergencyLoanBridge or {}

-- LOCKED persistence key. Never renamed after first persist.
IncomeEmergencyLoanBridge.MODULE_ID = "IncomeMod_EmergencyLoan"

IncomeEmergencyLoanBridge.active       = false
IncomeEmergencyLoanBridge.delivered    = false
IncomeEmergencyLoanBridge.pendingState = nil

-- True when the ledger is the debt-ledger load source of truth this session.
function IncomeEmergencyLoanBridge.hasState()
    return IncomeEmergencyLoanBridge.active
        and IncomeEmergencyLoanBridge.delivered
        and IncomeEmergencyLoanBridge.pendingState ~= nil
end

function IncomeEmergencyLoanBridge.applyState(emergencyLoan)
    if emergencyLoan == nil or type(IncomeEmergencyLoanBridge.pendingState) ~= "table" then
        return false
    end
    emergencyLoan:deserialize(IncomeEmergencyLoanBridge.pendingState)
    return true
end

-- Register with StateLedger if present. Called from IncomeManager:onMissionLoaded.
function IncomeEmergencyLoanBridge.register(im)
    IncomeEmergencyLoanBridge.active       = false
    IncomeEmergencyLoanBridge.delivered    = false
    IncomeEmergencyLoanBridge.pendingState = nil

    local ledger = (g_currentMission ~= nil and g_currentMission.stateLedger) or g_stateLedger
    if ledger == nil then
        Logging.info("Income Mod: StateLedger not detected - emergency loan debt is session-only")
        return
    end
    if im == nil or im.emergencyLoan == nil then return end

    local loan = im.emergencyLoan

    local ok, err = pcall(function()
        ledger:registerModule(IncomeEmergencyLoanBridge.MODULE_ID, {
            serialize   = function() return loan:serialize() end,
            deserialize = function(data)
                IncomeEmergencyLoanBridge.delivered    = true
                IncomeEmergencyLoanBridge.pendingState = data
            end,
        })
    end)

    if not ok then
        Logging.warning("Income Mod: Emergency loan StateLedger registration failed: %s (session-only)", tostring(err))
        return
    end

    IncomeEmergencyLoanBridge.active = true

    if ledger.parseFile ~= nil then
        pcall(function() ledger:parseFile() end)
    end
    IncomeEmergencyLoanBridge.applyState(loan)

    Logging.info("Income Mod: Emergency loan registered with StateLedger as '%s'",
        IncomeEmergencyLoanBridge.MODULE_ID)
end
