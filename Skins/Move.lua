-- Squizzumables: drag Blizzard's windows anywhere (WindTools' Move Frames).
--
-- Left-drag any empty part of a window to move it. Blizzard places most
-- windows itself each time they open (the UI panel manager), so a moved
-- window goes back to its usual spot next time unless Remember Positions is
-- on: then the saved spot is put back after Blizzard's own placement.
--
-- Settings: skMove / skMoveSave on the Skins page (profile). Positions are
-- account-wide, in SquizzumablesDB.windowPositions. Works with or without the
-- skins. Waits while WindTools' Move Frames is on.

local _, ns = ...
local BH = ns.BH

local MV = {}
ns.MoveWindows = MV

-- Every window worth moving, on either client; missing ones are skipped.
local NAMES = {
    "CharacterFrame", "SpellBookFrame", "PlayerSpellsFrame", "PlayerTalentFrame", "ClassTalentFrame",
    "FriendsFrame", "PVEFrame", "CollectionsJournal", "EncounterJournal", "AchievementFrame",
    "LegacySystemFrame", "MerchantFrame", "MailFrame", "OpenMailFrame", "GossipFrame", "QuestFrame",
    "QuestLogFrame", "BankFrame", "GuildBankFrame", "AuctionHouseFrame", "AuctionFrame",
    "ProfessionsFrame", "ProfessionsCustomerOrdersFrame", "TradeSkillFrame", "TradeFrame",
    "ClassTrainerFrame", "InspectFrame", "CommunitiesFrame", "GuildFrame", "SettingsPanel",
    "DressUpFrame", "ItemSocketingFrame", "ItemUpgradeFrame", "MacroFrame", "AddonList",
    "ChannelFrame", "LootFrame", "TabardFrame", "PetStableFrame", "GuildRegistrarFrame",
    "PetitionFrame", "TaxiFrame", "FlightMapFrame", "WeeklyRewardsFrame", "ChallengesKeystoneFrame",
    "HelpFrame", "TimeManagerFrame", "CalendarFrame", "BlackMarketFrame", "VoidStorageFrame",
    "WardrobeFrame", "TransmogFrame", "ScrappingMachineFrame", "ExpansionLandingPage",
    "GenericTraitFrame", "ItemInteractionFrame", "AzeriteEssenceUI", "CovenantSanctumFrame",
    "PerksProgramFrame", "PlayerChoiceFrame", "RaidParentFrame", "LFGParentFrame",
    "WorldMapFrame", "GuildControlUI", "ReforgingFrame", "ArchaeologyFrame",
    "CraftFrame", "KeyBindingFrame", "QuickKeybindFrame", "ColorPickerFrame",
}

-- Pages that cover their whole window take its drags; they move the window.
local CHILDREN = {
    SendMailFrame = "MailFrame",
}

local function Settings() return BH.settings or {} end

local function WindToolsOn()
    if not C_AddOns.IsAddOnLoaded("ElvUI_WindTools") then return false end
    local E = _G.ElvUI and _G.ElvUI[1]
    local m = E and E.private and E.private.WT and E.private.WT.misc
    return type(m) == "table" and m.moveFrames and m.moveFrames.enable and true or false
end

local function Active()
    return Settings().skMove ~= false and not WindToolsOn()
end

local function Store()
    if not SquizzumablesDB then return nil end
    SquizzumablesDB.windowPositions = SquizzumablesDB.windowPositions or {}
    return SquizzumablesDB.windowPositions
end

local function CanTouch(f)
    return not (InCombatLockdown() and f:IsProtected())
end

local function Restore(f)
    if not (Active() and Settings().skMoveSave) then return end
    local p = Store()
    p = p and p[f:GetName()]
    if not p or not CanTouch(f) then return end
    -- A maximised world map belongs to the whole screen.
    if f == _G.WorldMapFrame and f.IsMaximized and f:IsMaximized() then return end
    f:ClearAllPoints()
    f:SetPoint(p[1], UIParent, p[2], p[3], p[4])
end

-- Kept here, never written into Blizzard's frames (that taints them).
local moving = {}

local function DragStart(f)
    if not Active() or not CanTouch(f) then return end
    if f == _G.WorldMapFrame and f.IsMaximized and f:IsMaximized() then return end
    f:StartMoving()
    moving[f] = true
end

local function DragStop(f)
    if not moving[f] then return end
    moving[f] = nil
    f:StopMovingOrSizing()
    -- Keep it out of the game's own layout cache; we keep the position.
    if f.SetUserPlaced then f:SetUserPlaced(false) end
    if Settings().skMoveSave then
        local point, _, rel, x, y = f:GetPoint(1)
        local p = Store()
        if p and point then p[f:GetName()] = { point, rel or point, x or 0, y or 0 } end
    end
end

local done = {}
local function Take(f)
    if done[f] or not f.SetMovable then return end
    if f.IsForbidden and f:IsForbidden() then return end
    if not CanTouch(f) then return end
    done[f] = true
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    if not f:IsMouseEnabled() then f:EnableMouse(true) end
    f:RegisterForDrag("LeftButton")
    f:HookScript("OnDragStart", DragStart)
    f:HookScript("OnDragStop", DragStop)
    f:HookScript("OnHide", DragStop)
    f:HookScript("OnShow", function(self)
        Restore(self)
        -- Blizzard's panel manager may place it again just after showing.
        C_Timer.After(0, function() if self:IsShown() then Restore(self) end end)
    end)
end

local children = {}
local function TakeChild(child, parent)
    if children[child] or not done[parent] then return end
    if not CanTouch(child) then return end
    children[child] = true
    if not child:IsMouseEnabled() then child:EnableMouse(true) end
    child:RegisterForDrag("LeftButton")
    child:HookScript("OnDragStart", function() DragStart(parent) end)
    child:HookScript("OnDragStop", function() DragStop(parent) end)
end

function MV.Scan()
    if not Active() then return end
    for _, name in ipairs(NAMES) do
        local f = _G[name]
        if type(f) == "table" and f.GetObjectType then Take(f) end
    end
    for child, parent in pairs(CHILDREN) do
        local c, p = _G[child], _G[parent]
        if type(c) == "table" and type(p) == "table" then TakeChild(c, p) end
    end
end

-- Positions the panel manager writes on every layout pass get ours back.
local hooked
local function HookManager()
    if hooked or not _G.UpdateUIPanelPositions then return end
    hooked = true
    hooksecurefunc("UpdateUIPanelPositions", function()
        if not (Active() and Settings().skMoveSave) then return end
        for f in pairs(done) do
            if f:IsShown() then Restore(f) end
        end
    end)
end

function MV.ResetPositions()
    if SquizzumablesDB then SquizzumablesDB.windowPositions = {} end
    print("|cff33cc99Squizzumables:|r window positions forgotten; each window goes back to its usual spot when next opened.")
end

SLASH_SQUIZZMOVE1 = "/sqmove"
SlashCmdList.SQUIZZMOVE = function(msg)
    if (msg or ""):lower():match("reset") then
        MV.ResetPositions()
    else
        print("|cff33cc99Squizzumables:|r /sqmove reset forgets every saved window position.")
    end
end

local pending
local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_REGEN_ENABLED")
ev:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then HookManager() end
    if pending then return end
    pending = true
    C_Timer.After(0.2, function()
        pending = nil
        MV.Scan()
    end)
end)
