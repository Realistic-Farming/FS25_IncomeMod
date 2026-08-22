-- =========================================================
-- FS25 Income Mod
-- =========================================================
-- IncomeMasterHUDBridge - optional bridge to FS25_MasterHUD (bedrock)
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
--   * MasterHUD installed -> the income HUD overlay registers as a subscribe()
--     element so MasterHUD owns the single suspend-aware draw loop and cross-mod
--     ordering; IncomeMod's own FSBaseMission.draw hook stands down when active.
--   * MasterHUD absent -> IncomeMod's own draw hook runs the exact same body.
--
-- drawStack() is the single source of the draw body, shared with the fallback hook
-- so the two paths can never diverge. IncomeHUD:draw self-guards on getIsClient /
-- GUI-visible / showHUD / visible, so calling it every frame is a no-op when hidden.
--
-- Mouse routing stays on IncomeMod's own addModEventListener handler (MasterHUD owns
-- draw ordering + suspend, not input), same as WorkerCosts keeps its own mouse
-- handler. The IncomeReportDialog (g_gui:showDialog) is an in-game-menu dialog, not a
-- HUD overlay, and stays g_gui-managed.
--
-- The cross-mod handle is g_currentMission.masterHUD (published in Mission00.load).
-- =========================================================

IncomeMasterHUDBridge = IncomeMasterHUDBridge or {}

IncomeMasterHUDBridge.HUD_ID = "IncomeMod_HUD"
IncomeMasterHUDBridge.active = false   -- MasterHUD present and we registered

-- The income HUD draw body. Resolves the manager from the canonical global so it can
-- be driven either by MasterHUD's loop or by IncomeMod's own draw hook.
function IncomeMasterHUDBridge.drawStack()
    -- Suite hide: MasterHUD # key. No-op when MasterHUD absent.
    local mh = (g_currentMission ~= nil and g_currentMission.masterHUD) or g_masterHUD
    if mh ~= nil and mh.areHudsHidden ~= nil and mh:areHudsHidden() then return end
    local im = g_IncomeManager
    if im ~= nil and im.incomeHUD ~= nil then
        im.incomeHUD:draw()
    end
end

-- Register with MasterHUD if present. Called from IncomeManager:onMissionLoaded.
function IncomeMasterHUDBridge.register(im)
    IncomeMasterHUDBridge.active = false

    local hud = (g_currentMission ~= nil and g_currentMission.masterHUD) or g_masterHUD
    if hud == nil then
        Logging.info("Income Mod: MasterHUD not detected; income HUD uses its own draw hook")
        return
    end

    local ok, err = pcall(function()
        hud:subscribe(IncomeMasterHUDBridge.HUD_ID, {
            draw = IncomeMasterHUDBridge.drawStack,
        })
    end)

    if ok then
        IncomeMasterHUDBridge.active = true
        Logging.info("Income Mod: Registered income HUD with MasterHUD (single draw loop + menu-suspend)")
        if hud.registerEditListener ~= nil then
            hud:registerEditListener(IncomeMasterHUDBridge.HUD_ID, {
                enter = function()
                    local ih = im ~= nil and im.incomeHUD or nil
                    if ih ~= nil and ih.enterEditMode ~= nil then ih:enterEditMode() end
                end,
                exit = function()
                    local ih = im ~= nil and im.incomeHUD or nil
                    if ih ~= nil and ih.editMode and ih.exitEditMode ~= nil then ih:exitEditMode() end
                end,
            })
        end
    else
        Logging.warning("Income Mod: MasterHUD registration failed: %s (using own draw hook)", tostring(err))
    end
end
