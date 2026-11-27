-- Skins/Windows2.lua
-- Batch 2 of the window skins: the character window, friends, the group
-- finder and PvP. These are big windows made almost entirely of Blizzard's
-- standard controls, so SK.Auto does most of the work and this file only
-- handles what is particular to each.

local _, ns = ...
local SK = ns.Skins
local Hide = SK.Hide

local function G(name) return _G[name] end

local function HideNamed(...)
    for i = 1, select("#", ...) do Hide(G(select(i, ...))) end
end

-- A round icon button (the group finder's and PvP's category buttons): the
-- ring and the circle mask go, the icon is squared off with a border.
local function CategoryButton(btn)
    if not btn or not SK.Once(btn) then return end
    Hide(btn.bg or btn.Background)
    Hide(btn.ring or btn.Ring)
    local icon = btn.icon or btn.Icon
    local mask = btn.CircleMask
    if icon and mask and icon.RemoveMaskTexture then icon:RemoveMaskTexture(mask) end
    if icon then SK.Icon(icon) end
    local hl = btn.GetHighlightTexture and btn:GetHighlightTexture()
    if hl then hl:SetColorTexture(1, 1, 1, 0.08) end
    SK.Backdrop(btn, "button")
    SK.Hover(btn)
end

-- ============================================================================
-- Character
-- ============================================================================

local SLOTS = { "Head", "Neck", "Shoulder", "Back", "Chest", "Shirt", "Tabard", "Wrist", "Hands", "Waist",
                "Legs", "Feet", "Finger0", "Finger1", "Trinket0", "Trinket1", "MainHand", "SecondaryHand" }

SK.Define("character", function()
    local cf = G("CharacterFrame")
    if not cf then return end
    SK.Window(cf)

    for _, s in ipairs(SLOTS) do
        local slot = G("Character" .. s .. "Slot")
        if slot then
            Hide(G("Character" .. s .. "SlotFrame"))
            SK.ItemButton(slot)
        end
    end

    -- The model's frame and backdrop art.
    HideNamed("PaperDollInnerBorderTopLeft", "PaperDollInnerBorderTopRight", "PaperDollInnerBorderBottomLeft",
              "PaperDollInnerBorderBottomRight", "PaperDollInnerBorderLeft", "PaperDollInnerBorderRight",
              "PaperDollInnerBorderTop", "PaperDollInnerBorderBottom", "PaperDollInnerBorderBottom2",
              "CharacterModelFrameBackgroundTopLeft", "CharacterModelFrameBackgroundTopRight",
              "CharacterModelFrameBackgroundBotLeft", "CharacterModelFrameBackgroundBotRight",
              "CharacterModelFrameBackgroundOverlay")
    local scene = G("CharacterModelScene")
    if scene then
        Hide(scene.BackgroundOverlay)
        for _, k in ipairs({ "BackgroundTopLeft", "BackgroundTopRight", "BackgroundBotLeft", "BackgroundBotRight" }) do
            Hide(scene[k])
        end
    end

    -- Stats on the right.
    local pane = G("CharacterStatsPane")
    if pane then
        Hide(pane.ClassBackground)
        for _, k in ipairs({ "ItemLevelCategory", "AttributesCategory", "EnhancementsCategory" }) do
            local cat = pane[k]
            if cat then Hide(cat.Background) end
        end
        if pane.ItemLevelFrame then Hide(pane.ItemLevelFrame.Background) end
    end

    -- The three small tabs above the stats (stats, titles, equipment sets).
    for i = 1, 3 do
        local tab = G("PaperDollSidebarTab" .. i)
        if tab and SK.Once(tab) then
            Hide(tab.TabBg)
            Hide(tab.Hider)
            if tab.Highlight then tab.Highlight:SetColorTexture(1, 1, 1, 0.15) end
            if tab.Icon then SK.Icon(tab.Icon) end
        end
    end
    local sidebar = G("PaperDollSidebarTabs")
    if sidebar then
        Hide(sidebar.DecorLeft)
        Hide(sidebar.DecorRight)
    end

    SK.Auto(cf)
    for _, n in ipairs({ "ReputationFrame", "TokenFrame", "CurrencyTransferLog", "TokenFramePopup" }) do
        if G(n) then SK.Auto(G(n)) end
    end
    SK.Window(G("TokenFramePopup"))
    SK.Window(G("ReputationDetailFrame"))
    if cf.ReputationFrame and cf.ReputationFrame.ReputationDetailFrame then
        SK.Window(cf.ReputationFrame.ReputationDetailFrame)
        SK.Auto(cf.ReputationFrame.ReputationDetailFrame)
    end
end)

-- ============================================================================
-- Friends
-- ============================================================================

SK.Define("friends", function()
    local ff = G("FriendsFrame")
    if not ff then return end
    SK.Window(ff)

    -- The Battle.net bar along the top.
    local bnet = G("FriendsFrameBattlenetFrame")
    if bnet and SK.Once(bnet) then
        SK.Strip(bnet)
        SK.Backdrop(bnet, "button")
        if bnet.BroadcastButton then
            SK.Strip(bnet.BroadcastButton)
        end
        if bnet.BroadcastFrame then
            SK.Strip(bnet.BroadcastFrame)
            Hide(bnet.BroadcastFrame.Border)
            SK.Backdrop(bnet.BroadcastFrame, "panel")
            SK.Auto(bnet.BroadcastFrame)
        end
        if bnet.UnavailableInfoFrame then
            SK.Strip(bnet.UnavailableInfoFrame)
            SK.Backdrop(bnet.UnavailableInfoFrame, "panel")
        end
    end

    SK.Auto(ff)
    for _, n in ipairs({ "AddFriendFrame", "FriendsFriendsFrame", "RecruitAFriendRewardsFrame",
                         "RecruitAFriendRecruitmentFrame" }) do
        local f = G(n)
        if f then
            if f.Border then Hide(f.Border) end
            SK.Window(f)
            SK.Auto(f)
        end
    end
end)

-- ============================================================================
-- Group finder
-- ============================================================================

SK.Define("lfg", function()
    local pve = G("PVEFrame")
    if not pve then return end
    SK.Window(pve)
    HideNamed("PVEFrameBlueBg", "PVEFrameTLCorner", "PVEFrameTRCorner", "PVEFrameBRCorner", "PVEFrameBLCorner",
              "PVEFrameLLVert", "PVEFrameRLVert", "PVEFrameBottomLine", "PVEFrameTopLine", "PVEFrameTopFiligree",
              "PVEFrameBottomFiligree", "LFDQueueFrameBackground", "RaidFinderQueueFrameBackground",
              "LFDParentFrameRoleBackground", "RaidFinderFrameRoleBackground", "ScenarioQueueFrameBackground")
    Hide(pve.shadows)

    local gf = G("GroupFinderFrame")
    if gf then
        for i = 1, 4 do CategoryButton(gf["groupButton" .. i]) end
    end

    local list = G("LFGListFrame")
    if list then
        for _, k in ipairs({ "CategorySelection", "SearchPanel", "ApplicationViewer", "EntryCreation" }) do
            local panel = list[k]
            if panel then Hide(panel.Background) end
        end
    end

    SK.Auto(pve)
    for _, n in ipairs({ "LFGListApplicationDialog", "LFGListInviteDialog", "LFGDungeonReadyDialog",
                         "LFGDungeonReadyStatus", "LFGListCreateRoleDialog" }) do
        local f = G(n)
        if f then
            Hide(f.Border)
            Hide(f.Background)
            SK.Window(f)
            SK.Auto(f)
        end
    end
end)

-- ============================================================================
-- PvP (loads with the PvP tab)
-- ============================================================================

SK.Define("pvp", function()
    local q = G("PVPQueueFrame")
    if q then
        for i = 1, 4 do CategoryButton(q["CategoryButton" .. i]) end
    end
    for _, n in ipairs({ "HonorFrame", "ConquestFrame", "TrainingGroundsFrame", "PlunderstormFrame" }) do
        local f = G(n)
        if f then
            Hide(f.ConquestBarBackground)
            SK.Auto(f)
        end
    end
    if G("PVPUIFrame") then SK.Auto(G("PVPUIFrame")) end
    local dlg = G("PVPTalentPrestigeLevelDialog")
    if dlg then
        SK.Window(dlg)
        SK.Auto(dlg)
    end
end)
