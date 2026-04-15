-- =========================================================
-- FS25 Income Mod (version 2.1.6.0)
-- =========================================================
-- Author: TisonK
-- =========================================================
-- COPYRIGHT NOTICE:
-- All rights reserved. Unauthorized redistribution, copying,
-- or claiming this code as your own is strictly prohibited.
-- Original author: TisonK
-- =========================================================

---@class IncomeReportDialog
IncomeReportDialog = {}
local IncomeReportDialog_mt = Class(IncomeReportDialog, ScreenElement)

IncomeReportDialog.MAX_ROWS = 10
IncomeReportDialog.instance = nil
IncomeReportDialog.xmlPath  = nil

-- =========================================================
-- Singleton Constructor
-- =========================================================

function IncomeReportDialog.getInstance(modDirectory)
    if IncomeReportDialog.instance == nil then
        if IncomeReportDialog.xmlPath == nil then
            IncomeReportDialog.xmlPath = modDirectory .. "gui/IncomeReportDialog.xml"
        end

        IncomeReportDialog.instance = IncomeReportDialog.new()
        g_gui:loadGui(IncomeReportDialog.xmlPath, "IncomeReportDialog", IncomeReportDialog.instance)
    end

    return IncomeReportDialog.instance
end

function IncomeReportDialog.new(target, customMt)
    local self = ScreenElement.new(target, customMt or IncomeReportDialog_mt)

    self.histRows    = {}
    self.isBackAllowed = true

    return self
end

-- =========================================================
-- Lifecycle
-- =========================================================

function IncomeReportDialog:onCreate()
    -- Cache all 10 history row element groups
    for i = 0, IncomeReportDialog.MAX_ROWS - 1 do
        local rowId = "histRow" .. i
        self.histRows[i] = {
            row    = self[rowId],
            day    = self[rowId .. "Day"],
            time   = self[rowId .. "Time"],
            payType = self[rowId .. "Type"],
            amount = self[rowId .. "Amount"],
            season = self[rowId .. "Season"],
        }
    end
end

--- Show the dialog if no other GUI is open.
function IncomeReportDialog:show()
    if g_gui.currentGui ~= nil then return end

    if not g_IncomeManager or not g_IncomeManager.incomeSystem then
        Logging.warning("im: IncomeReportDialog:show() — income system not available")
        return
    end

    self:updateDisplay()
    g_gui:showDialog("IncomeReportDialog")
end

--- Called by the FS25 GUI system when the dialog becomes visible (maps to XML onOpen="onOpen").
--- Refreshes data so the report is always current, even if the dialog is opened by means
--- other than the show() helper (e.g., direct g_gui:showDialog calls from other mods).
function IncomeReportDialog:onOpen()
    IncomeReportDialog:superClass().onOpen(self)
    if g_IncomeManager and g_IncomeManager.incomeSystem then
        self:updateDisplay()
    end
end

-- =========================================================
-- Display Update
-- =========================================================

function IncomeReportDialog:updateDisplay()
    self:updateSummary()
    self:updateStats()
    self:updateHistoryRows()
end

--- Fill the three summary rows with live settings values.
function IncomeReportDialog:updateSummary()
    local s = g_IncomeManager and g_IncomeManager.settings
    if not s then return end

    -- Row 1: Status / Mode / Difficulty
    if self.statusText then
        local label = s.enabled
            and g_i18n:getText("im_report_enabled")
            or  g_i18n:getText("im_report_disabled")
        self.statusText:setText(label)
        if s.enabled then
            self.statusText:setTextColor(0.3, 1.0, 0.3, 1)
        else
            self.statusText:setTextColor(1.0, 0.4, 0.4, 1)
        end
    end

    if self.modeText then
        self.modeText:setText(s:getPayModeName())
        self.modeText:setTextColor(0.8, 0.9, 1, 1)
    end

    if self.difficultyText then
        self.difficultyText:setText(s:getDifficultyName())
        self.difficultyText:setTextColor(0.8, 0.9, 1, 1)
    end

    -- Row 2: Amount / Multiplier / Seasonal
    if self.amountText then
        self.amountText:setText(string.format("$%d", s:getPaymentAmount()))
        self.amountText:setTextColor(0.8, 0.9, 1, 1)
    end

    if self.multiplierText then
        self.multiplierText:setText(s:getMultiplierName())
        self.multiplierText:setTextColor(0.8, 0.9, 1, 1)
    end

    if self.seasonalText then
        if s.seasonalEffects then
            self.seasonalText:setText(g_i18n:getText("im_report_enabled"))
            self.seasonalText:setTextColor(0.3, 1.0, 0.3, 1)
        else
            self.seasonalText:setText(g_i18n:getText("im_report_disabled"))
            self.seasonalText:setTextColor(0.6, 0.6, 0.6, 1)
        end
    end
end

--- Fill the stats row: total earned, average, and next payment time.
--- Note: history is a ring buffer capped at MAX_HISTORY (10) entries, so total
--- and average reflect only the most recent payments, not all-time earnings.
function IncomeReportDialog:updateStats()
    local sys = g_IncomeManager and g_IncomeManager.incomeSystem
    if not sys then return end

    local history = sys.paymentHistory or {}
    local total   = 0
    local count   = #history

    for _, entry in ipairs(history) do
        total = total + (entry.amount or 0)
    end

    if self.totalEarnedText then
        self.totalEarnedText:setText(string.format("$%d", total))
    end

    if self.avgPaymentText then
        if count > 0 then
            self.avgPaymentText:setText(string.format("$%d", math.floor(total / count)))
        else
            self.avgPaymentText:setText("--")
        end
    end

    if self.nextPaymentText then
        if sys.isInitialized and g_IncomeManager.settings.enabled then
            self.nextPaymentText:setText(sys:getNextPaymentInfo())
        else
            self.nextPaymentText:setText("--")
        end
    end
end

--- Fill history rows (most recent first).
function IncomeReportDialog:updateHistoryRows()
    local sys = g_IncomeManager and g_IncomeManager.incomeSystem
    local history = (sys and sys.paymentHistory) or {}
    local count   = #history

    local hasData = count > 0

    if self.noHistoryText then
        self.noHistoryText:setVisible(not hasData)
    end

    for i = 0, IncomeReportDialog.MAX_ROWS - 1 do
        local row = self.histRows[i]
        if row and row.row then
            -- history[1] is the most recent (inserted at front); show in that order
            local dataIndex = i + 1
            if dataIndex <= count then
                local entry = history[dataIndex]
                row.row:setVisible(true)

                if row.day then
                    row.day:setText(string.format("Day %d", entry.day or 0))
                end

                if row.time then
                    row.time:setText(string.format("%02d:00", entry.hour or 0))
                end

                if row.payType then
                    row.payType:setText(entry.payType or "?")
                end

                if row.amount then
                    row.amount:setText(string.format("$%d", entry.amount or 0))
                end

                if row.season then
                    local mult = entry.seasonMult
                    if mult and mult ~= 1.0 then
                        row.season:setText(string.format("x%.1f", mult))
                        if mult > 1.0 then
                            row.season:setTextColor(0.3, 1.0, 0.3, 1)
                        else
                            row.season:setTextColor(1.0, 0.6, 0.3, 1)
                        end
                    else
                        row.season:setText("--")
                        row.season:setTextColor(0.6, 0.6, 0.6, 1)
                    end
                end
            else
                row.row:setVisible(false)
            end
        end
    end
end

-- =========================================================
-- Button Callbacks
-- =========================================================

function IncomeReportDialog:onCloseDialog()
    g_gui:closeDialogByName("IncomeReportDialog")
end

function IncomeReportDialog:onClickBack()
    g_gui:closeDialogByName("IncomeReportDialog")
end

-- =========================================================
-- Input / Close Events
-- =========================================================

function IncomeReportDialog:inputEvent(action, value, eventUsed)
    eventUsed = IncomeReportDialog:superClass().inputEvent(self, action, value, eventUsed)

    if not eventUsed and action == InputAction.MENU_BACK and value > 0 then
        g_gui:closeDialogByName("IncomeReportDialog")
        eventUsed = true
    end

    return eventUsed
end

function IncomeReportDialog:onClose()
    IncomeReportDialog:superClass().onClose(self)
end
