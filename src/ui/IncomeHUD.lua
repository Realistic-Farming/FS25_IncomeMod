-- =========================================================
-- FS25 Income Mod (version 2.1.5.0)
-- =========================================================
-- Income HUD Overlay
-- Displays income status, payment method, and history.
-- Toggle with the IM_TOGGLE_HUD action (default: I key).
-- RMB on panel to drag/resize (NPCFavor pattern).
-- =========================================================
-- Author: TisonK
-- =========================================================

---@class IncomeHUD
-- BUILD 17:57 (Wizard hot-reload law 2026-08-21, FS25-HotReload-Guide.md Part 1):
-- reuse the existing class table on Ctrl+R reload so updated methods land on the
-- table live metatables already reference, instead of orphaning it.
IncomeHUD = IncomeHUD or {}
local IncomeHUD_mt = Class(IncomeHUD)

IncomeHUD.MAX_HISTORY_ROWS  = 5
IncomeHUD.MIN_SCALE         = 0.60
IncomeHUD.MAX_SCALE         = 1.80
IncomeHUD.RESIZE_HANDLE_SIZE = 0.008
-- Wizard 2026-08-21 width wave: left/right edge drag adjusts a width multiplier,
-- independent of corner-scale (NPCFavor/Workplace pattern, suite-wide).
IncomeHUD.MIN_WIDTH_MULT = 0.7
IncomeHUD.MAX_WIDTH_MULT = 2.5
IncomeHUD.EDGE_BAND_W    = 0.008
IncomeHUD.EDGE_SENS      = 3.0

local function getBaseGameRenderer()
    local hud = (g_currentMission ~= nil and g_currentMission.masterHUD) or g_masterHUD
    return hud ~= nil and hud.renderer or nil
end

function IncomeHUD.new(incomeSystem, settings)
    local self = setmetatable({}, IncomeHUD_mt)

    self.incomeSystem = incomeSystem
    self.settings     = settings

    -- Runtime visibility (I key toggle — not persisted)
    self.visible = true

    -- Panel anchor: top-left of content area (text starts here)
    -- BUILD 17:10 (Sam DESIGN 17:08): factory home splits Income off the WE box -
    -- both mods shipped (0.77, 0.90) and stacked. Income sits under WE in the
    -- 0.550-0.750 band (posY is the panel TOP edge per the clamp below): 0.73-0.84,
    -- keeping the gap above Soil's top at ~0.709. Saved hudLayout XML still wins.
    -- Wizard 2026-08-21: factory home is the suite layout Wizard arranged
    -- in-game (bottom-left lane). A saved hudLayout XML still wins on load.
    self.posX       = 0.191667
    self.posY       = 0.980000
    self.panelWidth = 0.20

    -- Base layout constants (at scale 1.0 — multiplied by self.scale at draw time)
    self.LINE_H      = 0.017
    self.PAD         = 0.007
    self.TEXT_TITLE  = 0.013
    self.TEXT_NORMAL = 0.011
    self.TEXT_SMALL  = 0.0095

    -- Scale & edit state (NPCFavor / SoilHUD pattern)
    self.scale            = 1.471906   -- factory suite layout (Wizard 2026-08-22)
    self.editMode         = false
    self.dragging         = false
    self.resizing         = false
    self.dragOffsetX      = 0
    self.dragOffsetY      = 0
    self.resizeStartX     = 0
    self.resizeStartY     = 0
    self.resizeStartScale = 1.0
    self.hoverCorner      = nil
    self.animTimer        = 0

    -- Width state (edge-drag, NPCFavor/Workplace pattern)
    self.widthMult          = 0.700000   -- factory suite layout (Wizard 2026-08-22)
    self.edgeDragging       = nil   -- nil | "left" | "right"
    self.edgeDragStartX     = 0
    self.edgeDragStartWidth = 1.0

    -- Camera freeze (NPCFavor pattern)
    self.savedCamRotX = nil
    self.savedCamRotY = nil
    self.savedCamRotZ = nil

    -- Cached panel bounds (updated each drawPanel, used for hit-testing)
    self.lastBgX = 0
    self.lastBgY = 0
    self.lastBgW = 0
    self.lastBgH = 0

    -- 1x1 pixel overlay for all rect draws
    self.bgOverlay = nil
    if createImageOverlay then
        self.bgOverlay = createImageOverlay("dataS/menu/base/graph_pixel.dds")
    end

    -- Color palette
    self.COLORS = {
        BG           = {0.05, 0.05, 0.05, 0.82},   -- dark, matches native Field Info
        BORDER       = {0.20, 0.20, 0.20, 0.40},   -- neutral subtle border
        DIVIDER      = {0.25, 0.25, 0.25, 0.85},
        SHADOW       = {0.00, 0.00, 0.00, 0.35},
        HEADER       = {1.00, 1.00, 1.00, 1.00},
        ENABLED      = {0.30, 0.90, 0.30, 1.00},   -- green ON status — keep
        DISABLED     = {0.90, 0.30, 0.30, 1.00},   -- red OFF status — keep
        LABEL        = {0.72, 0.72, 0.72, 1.00},   -- neutral gray, no green tint
        VALUE        = {1.00, 1.00, 1.00, 1.00},
        DIM          = {0.55, 0.55, 0.55, 1.00},
        AMOUNT       = {0.35, 0.90, 0.35, 1.00},   -- green money — keep, semantic
        SEASONAL     = {0.90, 0.78, 0.30, 1.00},   -- yellow seasonal — keep, semantic
        HINT         = {0.52, 0.52, 0.52, 0.75},   -- neutral dim hint
        EDIT_BORDER  = {1.00, 0.60, 0.10, 0.90},   -- orange edit mode — matches SeasonalCropStress
        EDIT_HANDLE  = {1.00, 0.70, 0.20, 0.85},
    }

    return self
end

-- =========================================================
-- Cleanup
-- =========================================================

function IncomeHUD:delete()
    if self.editMode then self:exitEditMode() end
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
-- Edit mode
-- =========================================================

function IncomeHUD:enterEditMode()
    self.editMode = true
    self.dragging = false
    if g_inputBinding and g_inputBinding.setShowMouseCursor then
        g_inputBinding:setShowMouseCursor(true)
    end
    if getCamera and getRotation then
        local ok, cam = pcall(getCamera)
        if ok and cam and cam ~= 0 then
            local ok2, rx, ry, rz = pcall(getRotation, cam)
            if ok2 then
                self.savedCamRotX, self.savedCamRotY, self.savedCamRotZ = rx, ry, rz
            end
        end
    end
end

function IncomeHUD:exitEditMode()
    self.editMode     = false
    self.dragging     = false
    self.resizing     = false
    self.edgeDragging = nil
    self.hoverCorner  = nil
    self.savedCamRotX, self.savedCamRotY, self.savedCamRotZ = nil, nil, nil
    if g_inputBinding and g_inputBinding.setShowMouseCursor then
        g_inputBinding:setShowMouseCursor(false)
    end
    self:saveLayout()
end

-- =========================================================
-- HUD layout persistence
-- =========================================================

-- 2026-08-22 (Wizard "fix the bug so they save"): HUD layout now persists in
-- modSettings, not the savegame directory.
--
-- The old path wrote <savegameDirectory>/FS25_IncomeMod_hud.xml. That file is present in savegame0,
-- 5, 6 and 8 but never appeared in savegame1, so the write is not reliable in the
-- savegame directory. SoilFertilizer already persists its HUD under modSettings and
-- its hud.xml carried the live position, scale and width through every save and
-- restart, so that is the pattern that demonstrably survives and this now matches it.
--
-- modSettings is also global rather than per-savegame, which is the right scope for a
-- HUD layout: the player arranges their screen once, not once per save.
-- getUserProfileAppPath and createFolder are engine functions, both already used by
-- SoilFertilizer, FarmTablet and MarketDynamics in this suite.
function IncomeHUD:getLayoutPath()
    local ok, profilePath = pcall(getUserProfileAppPath)
    if ok and profilePath ~= nil and profilePath ~= "" then
        if profilePath:sub(-1) ~= "/" and profilePath:sub(-1) ~= "\\" then
            profilePath = profilePath .. "/"
        end
        local base = profilePath .. "modSettings/FS25_IncomeMod"
        createFolder(profilePath .. "modSettings")
        createFolder(base)
        createFolder(base .. "/HUD")
        return base .. "/HUD/hud.xml"
    end
    -- Dedicated server or any environment with no user profile path: keep the old
    -- savegame-dir file rather than losing the layout entirely.
    if g_currentMission ~= nil and g_currentMission.missionInfo ~= nil
    and g_currentMission.missionInfo.savegameDirectory ~= nil then
        return g_currentMission.missionInfo.savegameDirectory .. "/FS25_IncomeMod_hud.xml"
    end
end

--- The pre-2026-08-22 location. Read once on load so an arrangement saved before the
--- move is migrated instead of lost; the next save writes it to the new path.
function IncomeHUD:getLegacyLayoutPath()
    if g_currentMission ~= nil and g_currentMission.missionInfo ~= nil
    and g_currentMission.missionInfo.savegameDirectory ~= nil then
        return g_currentMission.missionInfo.savegameDirectory .. "/FS25_IncomeMod_hud.xml"
    end
end

function IncomeHUD:saveLayout()
    local path = self:getLayoutPath()
    if not path then return end
    local xml = XMLFile.create("im_hud", path, "hudLayout")
    if xml then
        xml:setFloat("hudLayout.posX",   self.posX)
        xml:setFloat("hudLayout.posY",   self.posY)
        xml:setFloat("hudLayout.scale",  self.scale)
        xml:setFloat("hudLayout.widthMult", self.widthMult or 1.0)
        xml:setBool("hudLayout.visible", self.visible)
        xml:save()
        xml:delete()
    end
end

function IncomeHUD:loadLayout()
    local path = self:getLayoutPath()
    if path == nil or not fileExists(path) then
        -- First run after the move: migrate the old savegame-dir sidecar.
        path = self:getLegacyLayoutPath()
        if path == nil or not fileExists(path) then return end
    end
    local xml = XMLFile.load("im_hud", path)
    if xml then
        self.posX    = xml:getFloat("hudLayout.posX",   self.posX)
        self.posY    = xml:getFloat("hudLayout.posY",   self.posY)
        self.scale   = xml:getFloat("hudLayout.scale",  self.scale)
        self.widthMult = math.max(IncomeHUD.MIN_WIDTH_MULT, math.min(IncomeHUD.MAX_WIDTH_MULT,
            xml:getFloat("hudLayout.widthMult", self.widthMult or 1.0)))
        self.visible = xml:getBool("hudLayout.visible", self.visible)
        xml:delete()
    end
end

-- =========================================================
-- Geometry helpers (use cached bounds — dynamic height)
-- =========================================================

function IncomeHUD:isPointerOverHUD(posX, posY)
    return posX >= self.lastBgX and posX <= self.lastBgX + self.lastBgW
       and posY >= self.lastBgY and posY <= self.lastBgY + self.lastBgH
end

function IncomeHUD:getResizeHandleRects()
    local hs = IncomeHUD.RESIZE_HANDLE_SIZE
    local bx, by, bw, bh = self.lastBgX, self.lastBgY, self.lastBgW, self.lastBgH
    return {
        bl = {x = bx,        y = by,        w = hs, h = hs},
        br = {x = bx+bw-hs,  y = by,        w = hs, h = hs},
        tl = {x = bx,        y = by+bh-hs,  w = hs, h = hs},
        tr = {x = bx+bw-hs,  y = by+bh-hs,  w = hs, h = hs},
    }
end

function IncomeHUD:hitTestCorner(posX, posY)
    for key, r in pairs(self:getResizeHandleRects()) do
        if posX >= r.x and posX <= r.x + r.w
        and posY >= r.y and posY <= r.y + r.h then
            return key
        end
    end
    return nil
end

function IncomeHUD:hitTestEdge(posX, posY)
    local band = IncomeHUD.EDGE_BAND_W
    local bx, by, bw, bh = self.lastBgX, self.lastBgY, self.lastBgW, self.lastBgH
    if posY >= by and posY <= by + bh then
        if posX >= bx - band / 2 and posX <= bx + band / 2 then return "left" end
        if posX >= bx + bw - band / 2 and posX <= bx + bw + band / 2 then return "right" end
    end
    return nil
end

function IncomeHUD:clampPosition()
    local bw = self.lastBgW
    local bh = self.lastBgH
    -- posX / posY are the text anchor inside the panel
    local pad = self.PAD * self.scale
    self.posX = math.max(pad + 0.01, math.min(1.0 - bw + pad - 0.01, self.posX))
    self.posY = math.max(bh - pad + 0.01, math.min(0.98, self.posY))
end

-- =========================================================
-- Mouse event (called from main.lua addModEventListener)
-- FS25 button numbers: 1=LMB, 3=RMB.
-- RMB over panel → exit edit only (suite Ctrl+# / MasterHUD enters edit).
-- Never enter via right-click so vehicle/tool RMB actions stay free.
-- =========================================================

function IncomeHUD:onMouseEvent(posX, posY, isDown, isUp, button, eventUsed)
    if eventUsed then return true end
    if not self.settings.showHUD then return false end
    if not self.visible then return false end

    -- RMB: exit if editing; never enter via right-click
    if isDown and button == Input.MOUSE_BUTTON_RIGHT then
        if self.editMode then
            self:exitEditMode()
            return true
        end
        return false
    end

    if not self.editMode then return false end

    -- LMB down: corner resize, edge width, or body drag
    if isDown and button == Input.MOUSE_BUTTON_LEFT then
        local corner = self:hitTestCorner(posX, posY)
        if corner then
            self.resizing         = true
            self.dragging         = false
            self.edgeDragging     = nil
            self.resizeStartX     = posX
            self.resizeStartY     = posY
            self.resizeStartScale = self.scale
            return true
        end
        local edge = self:hitTestEdge(posX, posY)
        if edge then
            self.edgeDragging       = edge
            self.dragging           = false
            self.resizing           = false
            self.edgeDragStartX     = posX
            self.edgeDragStartWidth = self.widthMult or 1.0
            return true
        end
        if self:isPointerOverHUD(posX, posY) then
            self.dragging    = true
            self.resizing    = false
            self.edgeDragging = nil
            -- offset from panel text anchor
            self.dragOffsetX = posX - self.posX
            self.dragOffsetY = posY - self.posY
            return true
        end
        return false
    end

    -- LMB up: end drag/resize/edge
    if isUp and button == Input.MOUSE_BUTTON_LEFT then
        if self.dragging or self.resizing or self.edgeDragging then
            self.dragging     = false
            self.resizing     = false
            self.edgeDragging = nil
            self:clampPosition()
            return true
        end
        return false
    end

    local handled = false

    -- Mouse movement: continuous drag / resize
    if self.dragging then
        local bw = self.lastBgW
        self.posX = math.max(0.0, math.min(1.0 - bw, posX - self.dragOffsetX))
        self.posY = math.max(0.05, math.min(0.98, posY - self.dragOffsetY))
        handled = true
    end

    if self.resizing then
        local cx = self.lastBgX + self.lastBgW * 0.5
        local cy = self.lastBgY + self.lastBgH * 0.5
        local startDist = math.sqrt((self.resizeStartX-cx)^2 + (self.resizeStartY-cy)^2)
        local currDist  = math.sqrt((posX-cx)^2 + (posY-cy)^2)
        local delta     = (currDist - startDist) * 2.5
        self.scale = math.max(IncomeHUD.MIN_SCALE,
            math.min(IncomeHUD.MAX_SCALE, self.resizeStartScale + delta))
        self:clampPosition()
        handled = true
    end

    -- Edge width drag: dx scaled by EDGE_SENS, left edge inverted so pulling
    -- outward always widens (NPCFavor/Workplace pattern).
    if self.edgeDragging then
        local dx = posX - self.edgeDragStartX
        if self.edgeDragging == "left" then dx = -dx end
        self.widthMult = math.max(IncomeHUD.MIN_WIDTH_MULT,
            math.min(IncomeHUD.MAX_WIDTH_MULT, self.edgeDragStartWidth + dx * IncomeHUD.EDGE_SENS))
        self:clampPosition()
        handled = true
    end

    -- Hover detection for corner handles
    if not self.dragging and not self.resizing and not self.edgeDragging then
        self.hoverCorner = self:hitTestCorner(posX, posY)
        if self.hoverCorner then
            handled = true
        end
    end

    return handled
end

-- =========================================================
-- Update (called every frame via IncomeManager:update)
-- =========================================================

function IncomeHUD:update(dt)
    self.animTimer = self.animTimer + dt

    if self.editMode then
        if g_inputBinding and g_inputBinding.setShowMouseCursor then
            g_inputBinding:setShowMouseCursor(true)
        end
        if self.savedCamRotX ~= nil and getCamera and setRotation then
            local ok, cam = pcall(getCamera)
            if ok and cam and cam ~= 0 then
                pcall(setRotation, cam, self.savedCamRotX, self.savedCamRotY, self.savedCamRotZ)
            end
        end
        if g_gui and (g_gui:getIsGuiVisible() or g_gui:getIsDialogVisible()) then
            self:exitEditMode()
        end
        if not self.dragging and not self.resizing then
            if g_inputBinding and g_inputBinding.mousePosXLast then
                self.hoverCorner = self:hitTestCorner(
                    g_inputBinding.mousePosXLast, g_inputBinding.mousePosYLast)
            end
        end
    else
        self.hoverCorner = nil
    end
end

-- =========================================================
-- Draw (called every frame from FSBaseMission.draw hook)
-- =========================================================

function IncomeHUD:draw()
    if not g_currentMission or not g_currentMission:getIsClient() then return end

    if not self.editMode then
        if g_gui and (g_gui:getIsGuiVisible() or g_gui:getIsDialogVisible()) then return end
        if g_currentMission.hud and g_currentMission.hud.ingameMap then
            if g_currentMission.hud.ingameMap.state == IngameMap.STATE_LARGE_MAP then return end
        end
    end

    if not self.settings.showHUD then return end
    if not self.visible          then return end
    if not self.bgOverlay        then return end

    self:drawPanel()
end

-- =========================================================
-- Panel Rendering
-- =========================================================

function IncomeHUD:drawPanel()
    local sc  = self.scale
    local s   = self.settings
    local sys = self.incomeSystem

    -- Scaled layout values (width also carries the edge-drag multiplier)
    local x   = self.posX
    local w   = self.panelWidth * (self.widthMult or 1.0) * sc
    local pad = self.PAD * sc
    local lh  = self.LINE_H * sc

    local histCount  = math.min(#sys.paymentHistory, IncomeHUD.MAX_HISTORY_ROWS)
    local showMult   = s:getMultiplierValue() > 1
    local showSeason = s.seasonalEffects

    local nRows = 6
        + (showMult   and 1 or 0)
        + (showSeason and 1 or 0)
        + math.max(histCount - 1, 0)

    local nDividers = 3
    local bgH = pad * 2 + nRows * lh + nDividers * (0.004 * sc)
    local bgX = x - pad
    local bgY = self.posY - bgH + pad
    local bgW = w + pad * 2

    -- Cache for hit-testing and resize handles
    self.lastBgX = bgX
    self.lastBgY = bgY
    self.lastBgW = bgW
    self.lastBgH = bgH

    local renderer = getBaseGameRenderer()
    local usedNativePanel = renderer ~= nil and renderer.renderPanel ~= nil
        and renderer:renderPanel(bgX, bgY, bgW, bgH, self.COLORS.BG[4])
    if not usedNativePanel then
        self:rect(bgX + 0.002, bgY - 0.002, bgW, bgH, self.COLORS.SHADOW)
        self:rect(bgX, bgY, bgW, bgH, self.COLORS.BG)
        local bw = 0.0012
        self:rect(bgX,           bgY + bgH - bw, bgW, bw, self.COLORS.BORDER)
        self:rect(bgX,           bgY,            bgW, bw, self.COLORS.BORDER)
        self:rect(bgX,           bgY,            bw, bgH, self.COLORS.BORDER)
        self:rect(bgX + bgW - bw, bgY,           bw, bgH, self.COLORS.BORDER)
    end

    -- Edit mode chrome
    if self.editMode then
        local pulse = 0.55 + 0.45 * math.sin(self.animTimer * 0.004)
        local ebw   = 0.002
        local ec    = self.COLORS.EDIT_BORDER
        self:rectA(bgX,            bgY,             bgW, ebw, ec, pulse)
        self:rectA(bgX,            bgY + bgH - ebw,  bgW, ebw, ec, pulse)
        self:rectA(bgX,            bgY,             ebw, bgH, ec, pulse)
        self:rectA(bgX + bgW - ebw, bgY,             ebw, bgH, ec, pulse)

        for key, r in pairs(self:getResizeHandleRects()) do
            local isHover = (self.hoverCorner == key)
            self:rectA(r.x, r.y, r.w, r.h, self.COLORS.EDIT_HANDLE, isHover and 1.0 or 0.65)
        end

        -- Left/right edge width handles (suite width vocabulary)
        local ehW   = 0.004
        local inset = bgH * 0.15
        self:rectA(bgX - ehW / 2,       bgY + inset, ehW, bgH - inset * 2,
            self.COLORS.EDIT_HANDLE, self.edgeDragging == "left" and 1.0 or 0.65)
        self:rectA(bgX + bgW - ehW / 2, bgY + inset, ehW, bgH - inset * 2,
            self.COLORS.EDIT_HANDLE, self.edgeDragging == "right" and 1.0 or 0.65)
    end

    -- ── Content rows ──────────────────────────────────────
    local tsTitle  = self.TEXT_TITLE  * sc
    local tsNormal = self.TEXT_NORMAL * sc
    local tsSmall  = self.TEXT_SMALL  * sc

    local cy = self.posY - pad

    -- Title row
    setTextBold(true)
    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextColor(self.COLORS.HEADER[1], self.COLORS.HEADER[2], self.COLORS.HEADER[3], self.COLORS.HEADER[4])
    renderText(x, cy - tsTitle, tsTitle, "INCOME MOD")

    local statusColor = s.enabled and self.COLORS.ENABLED or self.COLORS.DISABLED
    setTextAlignment(RenderText.ALIGN_RIGHT)
    setTextColor(statusColor[1], statusColor[2], statusColor[3], statusColor[4])
    renderText(x + w, cy - tsTitle, tsTitle, s.enabled and "[ON]" or "[OFF]")
    setTextBold(false)
    cy = cy - lh

    -- Divider
    self:divider(bgX, cy, bgW, sc)
    cy = cy - 0.004 * sc

    -- Mode | Difficulty | Amount
    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextColor(self.COLORS.LABEL[1], self.COLORS.LABEL[2], self.COLORS.LABEL[3], self.COLORS.LABEL[4])
    renderText(x, cy - tsNormal, tsNormal, s:getPayModeName())

    setTextAlignment(RenderText.ALIGN_CENTER)
    setTextColor(self.COLORS.LABEL[1], self.COLORS.LABEL[2], self.COLORS.LABEL[3], self.COLORS.LABEL[4])
    renderText(x + w * 0.5, cy - tsNormal, tsNormal, s:getDifficultyName())

    local amtFmt = g_i18n:formatMoney(s:getPaymentAmount(), 0, true, true)
    setTextAlignment(RenderText.ALIGN_RIGHT)
    setTextColor(self.COLORS.AMOUNT[1], self.COLORS.AMOUNT[2], self.COLORS.AMOUNT[3], self.COLORS.AMOUNT[4])
    renderText(x + w, cy - tsNormal, tsNormal, amtFmt)
    cy = cy - lh

    -- Multiplier row (optional)
    if showMult then
        setTextAlignment(RenderText.ALIGN_LEFT)
        setTextColor(self.COLORS.DIM[1], self.COLORS.DIM[2], self.COLORS.DIM[3], self.COLORS.DIM[4])
        renderText(x, cy - tsSmall, tsSmall, "Multiplier: " .. s:getMultiplierName())
        cy = cy - lh
    end

    -- Seasonal row (optional)
    if showSeason then
        local seasonMult  = sys:getSeasonalMultiplier()
        local seasonNames = { [0] = "Spring", [1] = "Summer", [2] = "Autumn", [3] = "Winter" }
        local seasonIdx   = 0
        if g_currentMission and g_currentMission.environment then
            local ok, sv = pcall(function() return g_currentMission.environment.currentSeason end)
            if ok and sv ~= nil then seasonIdx = sv % 4 end
        end
        setTextAlignment(RenderText.ALIGN_LEFT)
        setTextColor(self.COLORS.SEASONAL[1], self.COLORS.SEASONAL[2], self.COLORS.SEASONAL[3], self.COLORS.SEASONAL[4])
        renderText(x, cy - tsSmall, tsSmall,
            string.format("Season: %s (%.1fx)", seasonNames[seasonIdx] or "?", seasonMult))
        cy = cy - lh
    end

    -- Next payment
    local nextText = self:buildNextPaymentText()
    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextColor(self.COLORS.DIM[1], self.COLORS.DIM[2], self.COLORS.DIM[3], self.COLORS.DIM[4])
    renderText(x, cy - tsSmall, tsSmall, "Next: " .. nextText)
    cy = cy - lh

    -- Divider
    self:divider(bgX, cy, bgW, sc)
    cy = cy - 0.004 * sc

    -- History header
    setTextBold(true)
    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextColor(self.COLORS.LABEL[1], self.COLORS.LABEL[2], self.COLORS.LABEL[3], self.COLORS.LABEL[4])
    renderText(x, cy - tsNormal, tsNormal, "Recent Payments")
    setTextBold(false)
    cy = cy - lh

    -- History rows
    if #sys.paymentHistory == 0 then
        setTextAlignment(RenderText.ALIGN_LEFT)
        setTextColor(self.COLORS.DIM[1], self.COLORS.DIM[2], self.COLORS.DIM[3], self.COLORS.DIM[4])
        renderText(x, cy - tsSmall, tsSmall, "No payments yet")
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
                renderText(x, cy - tsSmall, tsSmall, timeStr .. " " .. typeStr)

                setTextAlignment(RenderText.ALIGN_RIGHT)
                setTextColor(self.COLORS.AMOUNT[1], self.COLORS.AMOUNT[2], self.COLORS.AMOUNT[3], self.COLORS.AMOUNT[4])
                renderText(x + w, cy - tsSmall, tsSmall, entAmt)
                cy = cy - lh
            end
        end
    end

    -- Divider
    self:divider(bgX, cy, bgW, sc)
    cy = cy - 0.004 * sc

    -- Hint row
    setTextAlignment(RenderText.ALIGN_CENTER)
    setTextColor(self.COLORS.HINT[1], self.COLORS.HINT[2], self.COLORS.HINT[3], self.COLORS.HINT[4])
    if self.editMode then
        renderText(x + w * 0.5, cy - tsSmall, tsSmall, "Drag: move   Corner: resize   RMB: done")
    else
        renderText(x + w * 0.5, cy - tsSmall, tsSmall, "RMB: move/resize")
    end

    -- Reset text state
    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextBold(false)
    setTextColor(1, 1, 1, 1)
end

-- =========================================================
-- Next Payment Text
-- =========================================================

function IncomeHUD:buildNextPaymentText()
    if not g_currentMission or not g_currentMission.environment then return "?" end
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

function IncomeHUD:rect(rx, ry, rw, rh, color)
    setOverlayColor(self.bgOverlay, color[1], color[2], color[3], color[4])
    renderOverlay(self.bgOverlay, rx, ry, rw, rh)
end

function IncomeHUD:rectA(rx, ry, rw, rh, color, alpha)
    setOverlayColor(self.bgOverlay, color[1], color[2], color[3], alpha)
    renderOverlay(self.bgOverlay, rx, ry, rw, rh)
end

function IncomeHUD:divider(dx, bandTopY, dw, sc)
    local dividerH = g_pixelSizeY or (1 / 1080)
    local bandH = 0.004 * (sc or 1.0)
    self:rect(dx, bandTopY - (bandH + dividerH) * 0.5,
        dw, dividerH, self.COLORS.DIVIDER)
end

-- =========================================================

-- BUILD 17:57 (Wizard hot-reload law, FS25-HotReload-Guide.md Part 2): after a

-- Ctrl+R reload the metatable chain does not reliably deliver updated methods to

-- live instances, so copy them on directly. The live instance lives on the

-- mission handle published by src/main.lua (mission.incomeManager), holding the

-- HUD as .incomeHUD (IncomeManager.lua). Functions only; state fields untouched.

if g_currentMission ~= nil and g_currentMission.incomeManager ~= nil
    and g_currentMission.incomeManager.incomeHUD ~= nil then
    local inst = g_currentMission.incomeManager.incomeHUD
    for k, v in pairs(IncomeHUD) do
        if type(v) == "function" then
            inst[k] = v
        end
    end
    -- Constructor-owned state is not replaced by method patching. Reset the old
    -- live-refresh proof colour so an already-running panel gets the finished
    -- base-game white heading as well.
    if inst.COLORS ~= nil then
        inst.COLORS.HEADER = {1.00, 1.00, 1.00, 1.00}
    end
    -- Fields new in the width wave that a pre-wave live instance lacks.
    if inst.widthMult == nil then inst.widthMult = 1.0 end
    -- Delivery proof in log.txt (Wizard 2026-08-21).
    print("[IncomeMod] IncomeHUD hot-patched onto live instance")
end
