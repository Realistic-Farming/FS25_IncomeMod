-- =========================================================
-- FS25 Income Mod (version 2.0.0.1)
-- =========================================================
-- Income HUD Overlay
-- Displays income status, payment method, and history.
-- Toggle with the IM_TOGGLE_HUD action (default: I key).
-- =========================================================
-- Author: TisonK
-- =========================================================
-- COPYRIGHT NOTICE:
-- All rights reserved. Unauthorized redistribution, copying,
-- or claiming this code as your own is strictly prohibited.
-- Original author: TisonK
-- =========================================================

---@class IncomeHUD
IncomeHUD = {}
local IncomeHUD_mt = Class(IncomeHUD)

IncomeHUD.MAX_HISTORY_ROWS = 5

function IncomeHUD.new(incomeSystem, settings)
    local self = setmetatable({}, IncomeHUD_mt)

    self.incomeSystem = incomeSystem
    self.settings     = settings

    -- Runtime visibility (I key toggle — not persisted)
    -- settings.showHUD is the persistent layer
    self.visible = true

    -- Panel anchor: top-left of content area (text starts here)
    self.posX        = 0.77
    self.posY        = 0.90
    self.panelWidth  = 0.21

    -- Layout constants (normalized screen coords)
    self.LINE_H      = 0.017
    self.PAD         = 0.007
    self.TEXT_TITLE  = 0.013
    self.TEXT_NORMAL = 0.011
    self.TEXT_SMALL  = 0.0095

    -- 1x1 pixel overlay used for all colored rectangles (NPCFavorHUD pattern)
    self.bgOverlay = nil
    if createImageOverlay then
        self.bgOverlay = createImageOverlay("dataS/menu/base/graph_pixel.dds")
    end

    -- Color palette
    self.COLORS = {
        BG           = {0.06, 0.06, 0.06, 0.78},
        BORDER       = {0.35, 0.65, 0.35, 0.55},
        DIVIDER      = {0.25, 0.25, 0.25, 0.85},
        SHADOW       = {0.00, 0.00, 0.00, 0.35},
        HEADER       = {1.00, 1.00, 1.00, 1.00},
        ENABLED      = {0.30, 0.90, 0.30, 1.00},
        DISABLED     = {0.90, 0.30, 0.30, 1.00},
        LABEL        = {0.70, 0.85, 0.70, 1.00},
        VALUE        = {1.00, 1.00, 1.00, 1.00},
        DIM          = {0.55, 0.55, 0.55, 1.00},
        AMOUNT       = {0.35, 0.90, 0.35, 1.00},
        SEASONAL     = {0.90, 0.78, 0.30, 1.00},
        HINT         = {0.55, 0.70, 1.00, 0.75},
    }

    return self
end

-- =========================================================
-- Cleanup
-- =========================================================

function IncomeHUD:delete()
    if self.bgOverlay then
        delete(self.bgOverlay)
        self.bgOverlay = nil
    end
end

-- =========================================================
-- Toggle (called by I key action event)
-- =========================================================

function IncomeHUD:toggleVisibility()
    self.visible = not self.visible
    local msg = self.visible and "Income HUD shown" or "Income HUD hidden"
    if g_currentMission and g_currentMission.hud and g_currentMission.hud.showBlinkingWarning then
        g_currentMission.hud:showBlinkingWarning(msg, 2000)
    end
end

-- =========================================================
-- Draw (called every frame from FSBaseMission.draw hook)
-- =========================================================

function IncomeHUD:draw()
    -- Only draw on clients (not dedicated server console)
    if not g_currentMission or not g_currentMission:getIsClient() then
        return
    end

    -- Hide behind any GUI overlay or dialog
    if g_gui and (g_gui:getIsGuiVisible() or g_gui:getIsDialogVisible()) then
        return
    end

    -- Hide behind the fullscreen map
    if g_currentMission.hud and g_currentMission.hud.ingameMap then
        if g_currentMission.hud.ingameMap.state == IngameMap.STATE_LARGE_MAP then
            return
        end
    end

    -- Persistent and runtime visibility gates
    if not self.settings.showHUD then return end
    if not self.visible          then return end
    if not self.bgOverlay        then return end

    self:drawPanel()
end

-- =========================================================
-- Panel Rendering
-- =========================================================

function IncomeHUD:drawPanel()
    local s   = self.settings
    local sys = self.incomeSystem
    local x   = self.posX
    local w   = self.panelWidth
    local pad = self.PAD
    local lh  = self.LINE_H

    -- Decide which optional rows are visible
    local histCount  = math.min(#sys.paymentHistory, IncomeHUD.MAX_HISTORY_ROWS)
    local showMult   = s:getMultiplierValue() > 1
    local showSeason = s.seasonalEffects

    -- Compute background height from row count
    --   Fixed rows:   title (1) + mode/diff/amount (1) + next (1) + hist header (1) + hist min (1) + hint (1) = 6
    --   Optional rows: multiplier, seasonal
    --   History rows: override the "min 1" if history exists
    local nRows = 6
        + (showMult   and 1 or 0)
        + (showSeason and 1 or 0)
        + math.max(histCount - 1, 0)  -- history rows beyond the guaranteed "min 1"

    local nDividers = 3  -- after title row, after next row, after hist rows
    local bgH = pad * 2 + nRows * lh + nDividers * 0.004
    local bgX = x - pad
    local bgY = self.posY - bgH + pad
    local bgW = w + pad * 2

    -- Drop shadow
    local so = 0.002
    self:rect(bgX + so, bgY - so, bgW, bgH, self.COLORS.SHADOW)

    -- Background fill
    self:rect(bgX, bgY, bgW, bgH, self.COLORS.BG)

    -- Border lines
    local bw = 0.0012
    self:rect(bgX,           bgY + bgH - bw, bgW, bw, self.COLORS.BORDER)  -- top
    self:rect(bgX,           bgY,            bgW, bw, self.COLORS.BORDER)  -- bottom
    self:rect(bgX,           bgY,            bw, bgH, self.COLORS.BORDER)  -- left
    self:rect(bgX + bgW - bw, bgY,           bw, bgH, self.COLORS.BORDER)  -- right

    -- Draw content rows, starting just inside the top of the panel
    -- cy is the text BASELINE for each row (decrements downward each row)
    local cy = self.posY - pad

    -- ── Title row ─────────────────────────────────────────
    setTextBold(true)
    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextColor(self.COLORS.HEADER[1], self.COLORS.HEADER[2], self.COLORS.HEADER[3], self.COLORS.HEADER[4])
    renderText(x, cy - self.TEXT_TITLE, self.TEXT_TITLE, "INCOME MOD")

    -- ON / OFF status (right-aligned on same row)
    local statusColor = s.enabled and self.COLORS.ENABLED or self.COLORS.DISABLED
    setTextAlignment(RenderText.ALIGN_RIGHT)
    setTextColor(statusColor[1], statusColor[2], statusColor[3], statusColor[4])
    renderText(x + w, cy - self.TEXT_TITLE, self.TEXT_TITLE, s.enabled and "[ON]" or "[OFF]")
    setTextBold(false)
    cy = cy - lh

    -- Divider
    self:divider(bgX, cy + lh * 0.35, bgW)
    cy = cy - 0.004

    -- ── Mode | Difficulty | Amount ────────────────────────
    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextColor(self.COLORS.LABEL[1], self.COLORS.LABEL[2], self.COLORS.LABEL[3], self.COLORS.LABEL[4])
    renderText(x, cy - self.TEXT_NORMAL, self.TEXT_NORMAL, s:getPayModeName())

    setTextAlignment(RenderText.ALIGN_CENTER)
    setTextColor(self.COLORS.LABEL[1], self.COLORS.LABEL[2], self.COLORS.LABEL[3], self.COLORS.LABEL[4])
    renderText(x + w * 0.5, cy - self.TEXT_NORMAL, self.TEXT_NORMAL, s:getDifficultyName())

    local amtFmt = g_i18n:formatMoney(s:getPaymentAmount(), 0, true, true)
    setTextAlignment(RenderText.ALIGN_RIGHT)
    setTextColor(self.COLORS.AMOUNT[1], self.COLORS.AMOUNT[2], self.COLORS.AMOUNT[3], self.COLORS.AMOUNT[4])
    renderText(x + w, cy - self.TEXT_NORMAL, self.TEXT_NORMAL, amtFmt)
    cy = cy - lh

    -- ── Multiplier row (only when > 1x) ──────────────────
    if showMult then
        setTextAlignment(RenderText.ALIGN_LEFT)
        setTextColor(self.COLORS.DIM[1], self.COLORS.DIM[2], self.COLORS.DIM[3], self.COLORS.DIM[4])
        renderText(x, cy - self.TEXT_SMALL, self.TEXT_SMALL, "Multiplier: " .. s:getMultiplierName())
        cy = cy - lh
    end

    -- ── Seasonal row (only when seasonal effects enabled) ─
    if showSeason then
        local seasonMult  = sys:getSeasonalMultiplier()
        local seasonNames = { [0] = "Spring", [1] = "Summer", [2] = "Autumn", [3] = "Winter" }
        local seasonIdx   = 0
        if g_currentMission and g_currentMission.environment then
            local ok, sv = pcall(function() return g_currentMission.environment.currentSeason end)
            if ok and sv ~= nil then
                seasonIdx = sv % 4
            end
        end
        local seasonName = seasonNames[seasonIdx] or "?"
        setTextAlignment(RenderText.ALIGN_LEFT)
        setTextColor(self.COLORS.SEASONAL[1], self.COLORS.SEASONAL[2], self.COLORS.SEASONAL[3], self.COLORS.SEASONAL[4])
        renderText(x, cy - self.TEXT_SMALL, self.TEXT_SMALL,
            string.format("Season: %s (%.1fx)", seasonName, seasonMult))
        cy = cy - lh
    end

    -- ── Next payment ──────────────────────────────────────
    local nextText = self:buildNextPaymentText()
    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextColor(self.COLORS.DIM[1], self.COLORS.DIM[2], self.COLORS.DIM[3], self.COLORS.DIM[4])
    renderText(x, cy - self.TEXT_SMALL, self.TEXT_SMALL, "Next: " .. nextText)
    cy = cy - lh

    -- Divider
    self:divider(bgX, cy + lh * 0.35, bgW)
    cy = cy - 0.004

    -- ── History header ────────────────────────────────────
    setTextBold(true)
    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextColor(self.COLORS.LABEL[1], self.COLORS.LABEL[2], self.COLORS.LABEL[3], self.COLORS.LABEL[4])
    renderText(x, cy - self.TEXT_NORMAL, self.TEXT_NORMAL, "Recent Payments")
    setTextBold(false)
    cy = cy - lh

    -- ── History rows ──────────────────────────────────────
    if #sys.paymentHistory == 0 then
        setTextAlignment(RenderText.ALIGN_LEFT)
        setTextColor(self.COLORS.DIM[1], self.COLORS.DIM[2], self.COLORS.DIM[3], self.COLORS.DIM[4])
        renderText(x, cy - self.TEXT_SMALL, self.TEXT_SMALL, "No payments yet")
        cy = cy - lh
    else
        for i = 1, histCount do
            local entry = sys.paymentHistory[i]
            if entry then
                local timeStr = string.format("D%d %02d:00", entry.day, entry.hour)
                local typeStr = entry.payType == "hourly" and "[H]" or "[D]"
                local entAmt  = g_i18n:formatMoney(entry.amount, 0, true, true)

                setTextAlignment(RenderText.ALIGN_LEFT)
                setTextColor(self.COLORS.DIM[1], self.COLORS.DIM[2], self.COLORS.DIM[3], self.COLORS.DIM[4])
                renderText(x, cy - self.TEXT_SMALL, self.TEXT_SMALL, timeStr .. " " .. typeStr)

                setTextAlignment(RenderText.ALIGN_RIGHT)
                setTextColor(self.COLORS.AMOUNT[1], self.COLORS.AMOUNT[2], self.COLORS.AMOUNT[3], self.COLORS.AMOUNT[4])
                renderText(x + w, cy - self.TEXT_SMALL, self.TEXT_SMALL, entAmt)

                cy = cy - lh
            end
        end
    end

    -- Divider
    self:divider(bgX, cy + lh * 0.35, bgW)
    cy = cy - 0.004

    -- ── Hint row ─────────────────────────────────────────
    setTextAlignment(RenderText.ALIGN_CENTER)
    setTextColor(self.COLORS.HINT[1], self.COLORS.HINT[2], self.COLORS.HINT[3], self.COLORS.HINT[4])
    renderText(x + w * 0.5, cy - self.TEXT_SMALL, self.TEXT_SMALL, "[I] Toggle HUD")

    -- Reset text state
    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextBold(false)
    setTextColor(1, 1, 1, 1)
end

-- =========================================================
-- Next Payment Text (compact, for HUD display)
-- =========================================================

function IncomeHUD:buildNextPaymentText()
    if not g_currentMission or not g_currentMission.environment then
        return "?"
    end
    local env = g_currentMission.environment
    local s   = self.settings

    if s.payMode == Settings.PAY_MODE_HOURLY then
        local nextHour   = (env.currentHour + 1) % 24
        local msIntoHour = env.dayTime % 3600000
        local minsRem    = math.ceil((3600000 - msIntoHour) / 60000)
        return string.format("%02d:00 (~%dm)", nextHour, minsRem)
    else
        local minsRem = math.ceil((86400000 - env.dayTime) / 60000)
        return string.format("End of day (~%dm)", minsRem)
    end
end

-- =========================================================
-- Rendering Helpers
-- =========================================================

-- Render a solid-color rectangle using the bgOverlay
function IncomeHUD:rect(rx, ry, rw, rh, color)
    setOverlayColor(self.bgOverlay, color[1], color[2], color[3], color[4])
    renderOverlay(self.bgOverlay, rx, ry, rw, rh)
end

-- Render a thin horizontal divider line
function IncomeHUD:divider(dx, dy, dw)
    self:rect(dx, dy, dw, 0.001, self.COLORS.DIVIDER)
end
