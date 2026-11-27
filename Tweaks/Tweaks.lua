-- Tweaks/Tweaks.lua
-- Small things ElvUI did that are easy to miss once it is gone: auto repair,
-- a totem bar, the talking head's size, a reputation bar, Blizzard's
-- cooldown numbers and collapsing the objective tracker in Mythic+.
--
-- Each one is off by default and, like the other ElvUI replacements, stays out
-- of the way while ElvUI still does the same job; ElvUI's settings are copied
-- over once. Written from what ElvUI's options do, never from its code.

local addonName, ns = ...
local BH = ns.BH
local S = BH.Secrets

local TW = {}
ns.Tweaks = TW

local function Elv()
    local elv = _G["ElvUI"]
    return C_AddOns.IsAddOnLoaded("ElvUI") and type(elv) == "table" and elv[1] or nil
end

local function Secret(v) return S and S.IsSecret and S.IsSecret(v) end
local function Apply() if TW.Apply then TW.Apply() end end

-- What ElvUI still handles (so ours waits).
local ELV_DOES = {
    repair = function(E) return E.db and E.db.general and E.db.general.autoRepair ~= "NONE" end,
    totems = function(E) return E.private and E.private.general and E.private.general.totemTracker end,
    talkingHead = function(E) return E.db and E.db.general and (E.db.general.talkingHeadFrameScale or 1) ~= 1 end,
    rep = function(E) return E.db and E.db.databars and E.db.databars.reputation and E.db.databars.reputation.enable end,
    tracker = function(E) return E.db and E.db.general and E.db.general.objectiveFrameAutoHideInKeystone end,
}

function TW.ElvDoes(what)
    local E = Elv()
    if not E then return false end
    local ok, yes = pcall(ELV_DOES[what], E)
    return ok and yes and true or false
end

local function Note(what, name, where)
    return "\n\nWaits while ElvUI's " .. name .. " is on (" .. where .. ")."
end

local function WTNote(name, where)
    return "\n\nWaits while WindTools' " .. name .. " is on (WindTools > " .. where .. ")."
end

-- What WindTools still handles (so ours waits).
local function WTdb()
    if not C_AddOns.IsAddOnLoaded("ElvUI_WindTools") then return nil end
    local E = Elv()
    return E and E.db and E.db.WT or nil
end

local WT_DOES = {
    keystone = function(wt) return wt.combat.quickKeystone.enable end,
    vignette = function(wt) return wt.skins.vignetting.enable end,
}

function TW.WTDoes(what)
    local wt = WTdb()
    if not wt then return false end
    local ok, yes = pcall(WT_DOES[what], wt)
    return ok and yes and true or false
end

-- ============================================================================
-- Settings
-- ============================================================================

local GROWTH = {
    { text = "Right", value = "RIGHT" }, { text = "Left", value = "LEFT" },
    { text = "Down", value = "DOWN" }, { text = "Up", value = "UP" },
}

TW.SETTINGS = ns.Settings.Describe({
    apply = Apply,
    pages = {
        { key = "general", label = "General", rows = {
            { type = "header", label = "REPAIR" },
            { key = "twRepair", type = "dropdown", default = "NONE", label = "Auto Repair",
              items = { { text = "Off", value = "NONE" }, { text = "Guild funds first", value = "GUILD" },
                  { text = "Your own gold", value = "PLAYER" } },
              tip = "Repair everything when you open a vendor that repairs. Guild funds first falls back to your "
                .. "own gold." .. Note("repair", "Auto Repair", "General > Misc") },
            { type = "header", label = "TALKING HEAD" },
            { key = "twTalkingHead", type = "dropdown", default = "SHOW", label = "Talking Head",
              items = { { text = "Show", value = "SHOW" }, { text = "Hide", value = "HIDE" } },
              tip = "The portrait that pops up when an NPC speaks." },
            { key = "twTalkingHeadScale", type = "slider", default = 100, min = 50, max = 150, step = 5,
              label = "Talking Head Size", tip = "In percent. Place it with Edit Mode.",
              when = function(s) return s.twTalkingHead ~= "HIDE" end },
            { type = "header", label = "COOLDOWNS" },
            { key = "twCooldownNumbers", type = "dropdown", default = "KEEP", label = "Cooldown Numbers",
              items = { { text = "Leave as it is", value = "KEEP" }, { text = "Show", value = "ON" },
                  { text = "Hide", value = "OFF" } },
              tip = "Blizzard's own countdown numbers on cooldowns everywhere (bags, buffs, Blizzard's frames). "
                .. "ElvUI's cooldown text did this; with ElvUI off, Show puts numbers back." },
            { type = "header", label = "OBJECTIVES" },
            { key = "twTrackerKeystone", type = "check", default = false, label = "Collapse Objectives in Mythic+",
              tip = "Your quests fold away when a key starts, leaving the key's timer, and come back when you "
                .. "leave." .. Note("tracker", "Hide in Keystone", "General > Objective Frame") },
            { type = "header", label = "MYTHIC+" },
            { key = "twQuickKeystone", type = "check", default = false, label = "Insert Keystone Automatically",
              tip = "Your keystone goes into the font of power as soon as you open it." .. WTNote("Quick Keystone",
                  "Combat") },
            { type = "header", label = "SCREEN" },
            { key = "twVignette", type = "check", default = false, label = "Darken the Screen Edges",
              tip = "A soft shadow round the edges of the game world, under all of the interface."
                .. WTNote("Vignetting", "Skins") },
            { key = "twVignetteLevel", type = "slider", default = 30, min = 5, max = 100, step = 5,
              label = "How Dark", tip = "In percent.", when = function(s) return s.twVignette end },
        } },
        { key = "mail", label = "Mail", rows = {
            { key = "twMail", type = "check", default = false, label = "Contacts Beside the Mail Window",
              tip = "A list next to the Send tab: your other characters, online friends, guild members and "
                .. "favourites. Click a name to send to them, right-click to add or remove a favourite. The "
                .. "Contacts button opens and closes it." .. WTNote("Contacts", "Item") },
            { key = "twMailPage", type = "dropdown", default = "ALTS", label = "Opens On",
              items = { { text = "Your characters", value = "ALTS" }, { text = "Friends", value = "FRIENDS" },
                  { text = "Guild", value = "GUILD" }, { text = "Favourites", value = "FAVORITE" } },
              when = function(s) return s.twMail end },
        } },
        { key = "totems", label = "Totem Bar", rows = {
            { key = "twTotems", type = "check", default = false, label = "Show the Totem Bar",
              tip = "Your totems (and other summons Blizzard shows as totems: Efflorescence, Consecration, "
                .. "ghouls...) on a bar of their own, placed with Edit Mode. Right-click one to cancel it."
                .. Note("totems", "Totem Tracker", "General > Totem Tracker") },
            { key = "twTotemSize", type = "slider", default = 36, min = 16, max = 64, step = 1, label = "Size",
              when = function(s) return s.twTotems end },
            { key = "twTotemSpacing", type = "slider", default = 2, min = 0, max = 20, step = 1, label = "Spacing",
              when = function(s) return s.twTotems end },
            { key = "twTotemGrow", type = "dropdown", default = "RIGHT", items = GROWTH, label = "Grows",
              when = function(s) return s.twTotems end },
        } },
        { key = "rep", label = "Reputation Bar", rows = {
            { key = "twRep", type = "check", default = false, label = "Show the Reputation Bar",
              tip = "The faction you watch (tick \"Show as Experience Bar\" in the reputation window), placed with "
                .. "Edit Mode. Hover for the details, click for the reputation window."
                .. Note("rep", "Reputation bar", "DataBars > Reputation") },
            { key = "twRepWidth", type = "slider", default = 222, min = 4, max = 800, step = 1, label = "Width",
              when = function(s) return s.twRep end },
            { key = "twRepHeight", type = "slider", default = 10, min = 4, max = 800, step = 1, label = "Height",
              when = function(s) return s.twRep end },
            { key = "twRepVertical", type = "check", default = false, label = "Fill Upwards",
              tip = "Fill from bottom to top, for a tall thin bar.", when = function(s) return s.twRep end },
            { key = "twRepText", type = "dropdown", default = "NONE", label = "Text",
              items = { { text = "None", value = "NONE" }, { text = "Percent", value = "PERCENT" },
                  { text = "Current / Max", value = "CURMAX" }, { text = "Remaining", value = "REMAINING" } },
              when = function(s) return s.twRep and not s.twRepVertical end },
            { key = "twRepFont", type = "dropdown", default = "__default",
              items = function() return BH:BuildFontDropdownItems() end, label = "Font",
              when = function(s) return s.twRep and not s.twRepVertical end },
        } },
    },
})

function BH:BuildTweaksTab(parent)
    ns.Settings.Build(TW.SETTINGS, parent)
end

-- ============================================================================
-- Placement helpers (Edit Mode)
-- ============================================================================

local function Place(f, pos, default)
    pos = pos or default
    f:ClearAllPoints()
    f:SetPoint(pos.point, UIParent, pos.relPoint or pos.point, pos.x or 0, pos.y or 0)
end

local function SaveCenter(f, key)
    local cx, cy = f:GetCenter()
    if not cx then return end
    local scale = f:GetEffectiveScale() / UIParent:GetEffectiveScale()
    local ux, uy = UIParent:GetCenter()
    BH.settings[key] = { point = "CENTER", relPoint = "CENTER",
        x = math.floor(cx * scale - ux + 0.5), y = math.floor(cy * scale - uy + 0.5) }
    BH:SaveSettings()
end

local function Movable(f, key)
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self)
        if InCombatLockdown() or not BH.unlockMode then return end
        BH:GridStartMoving(self)
    end)
    f:SetScript("OnDragStop", function(self)
        BH:GridStopMoving(self)
        SaveCenter(self, key)
        Apply()
    end)
end

function TW.Nudge(key, default, dx, dy)
    local s = BH.settings
    if not s then return end
    local pos = s[key] or default
    s[key] = { point = pos.point, relPoint = pos.relPoint, x = (pos.x or 0) + dx, y = (pos.y or 0) + dy }
    BH:SaveSettings()
    Apply()
end

-- ============================================================================
-- Auto repair
-- ============================================================================

local function Repair()
    local mode = BH.settings and BH.settings.twRepair or "NONE"
    if mode == "NONE" or TW.ElvDoes("repair") or not CanMerchantRepair() then return end
    local cost, can = GetRepairAllCost()
    if not can or not cost or cost <= 0 then return end
    if mode == "GUILD" and IsInGuild() and CanGuildBankRepair and CanGuildBankRepair() then
        local allowance = GetGuildBankWithdrawMoney()
        if allowance == -1 or allowance >= cost then
            RepairAllItems(true)
            print("|cff33cc99Squizzumables:|r Repaired for " .. GetMoneyString(cost, true) .. " from guild funds.")
            return
        end
    end
    if GetMoney() >= cost then
        RepairAllItems()
        print("|cff33cc99Squizzumables:|r Repaired for " .. GetMoneyString(cost, true) .. ".")
    else
        print("|cff33cc99Squizzumables:|r Not enough gold to repair (" .. GetMoneyString(cost, true) .. ").")
    end
end

-- ============================================================================
-- Talking head
-- ============================================================================

local talkingHooked
local function TalkingHead(s)
    local th = _G.TalkingHeadFrame
    if not th then return end
    if TW.ElvDoes("talkingHead") then return end
    th:SetScale((s.twTalkingHeadScale or 100) / 100)
    if not talkingHooked and th.PlayCurrent then
        talkingHooked = true
        hooksecurefunc(th, "PlayCurrent", function(self)
            if BH.settings and BH.settings.twTalkingHead == "HIDE" and self.CloseImmediately then
                self:CloseImmediately()
            end
        end)
    end
end

-- ============================================================================
-- Cooldown numbers
-- ============================================================================

local function CooldownNumbers(s)
    local mode = s.twCooldownNumbers or "KEEP"
    if mode == "KEEP" then return end
    local want = mode == "ON" and "1" or "0"
    if GetCVar("countdownForCooldowns") ~= want then SetCVar("countdownForCooldowns", want) end
end

-- ============================================================================
-- Objective tracker in Mythic+
-- ============================================================================

local trackerPending

-- Never tracker:SetCollapsed() from here: it writes the tracker's
-- isCollapsed from addon code, Blizzard's ForceExpand reads it as the key
-- timer starts, and the scenario update then runs tainted (MawBuffs'
-- GetAuraDataByIndex refused, user report 2026-11-27). The quests are folded
-- by hiding sections instead (Quest/QuestExtras.lua), keeping the timer.
local function Tracker()
    local s = BH.settings
    if not s then return end
    trackerPending = nil
    local inKey = C_ChallengeMode and C_ChallengeMode.IsChallengeModeActive and C_ChallengeMode.IsChallengeModeActive()
    local want = s.twTrackerKeystone and inKey and not TW.ElvDoes("tracker")
    local qx = ns.QuestExtras
    if qx and qx.SetKeystoneFold then qx.SetKeystoneFold(want) end
end

-- ============================================================================
-- Totem bar: Blizzard's own totem buttons (they read the totem data, which can
-- be secret, in Blizzard's code), moved into slots on our bar
-- ============================================================================

local TOTEM_DEFAULT = { point = "CENTER", relPoint = "CENTER", x = -200, y = -250 }
local totemBar
local totemSlots = {}
local blizzTotems = setmetatable({}, { __mode = "k" })   -- Blizzard button -> true, once restyled

local function TotemBar()
    if totemBar then return totemBar end
    totemBar = CreateFrame("Frame", "SquizzumablesTotemBar", UIParent)
    totemBar:SetFrameStrata("LOW")
    Movable(totemBar, "twTotemPosition")
    BH.totemBar = totemBar
    for i = 1, (MAX_TOTEMS or 4) do
        local slot = CreateFrame("Frame", nil, totemBar)
        slot.bg = slot:CreateTexture(nil, "BACKGROUND")
        slot.bg:SetAllPoints()
        slot.bg:SetColorTexture(0, 0, 0, 1)
        slot.icon = slot:CreateTexture(nil, "ARTWORK")
        slot.icon:SetPoint("TOPLEFT", 1, -1)
        slot.icon:SetPoint("BOTTOMRIGHT", -1, 1)
        slot.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        slot.cd = CreateFrame("Cooldown", nil, slot, "CooldownFrameTemplate")
        slot.cd:SetAllPoints(slot.icon)
        slot.cd:SetDrawEdge(false)
        slot.cd:SetHideCountdownNumbers(false)
        slot:Hide()
        totemSlots[i] = slot
    end
    return totemBar
end

local function TotemsActive()
    local s = BH.settings
    return s and s.twTotems and not TW.ElvDoes("totems") and _G.TotemFrame ~= nil
end

local function FillSlot(slot, button)
    local slotIndex = button.slot
    local _, _, startTime, duration, icon = GetTotemInfo(slotIndex)
    if not startTime then
        slot.cd:Clear()
        slot:Hide()
        return
    end
    slot.icon:SetTexture(icon)
    if not canaccessvalue(duration) then
        local d = GetTotemDuration and GetTotemDuration(slotIndex)
        if d then slot.cd:SetCooldownFromDurationObject(d) else slot.cd:Clear() end
    elseif duration and duration > 0 then
        slot.cd:SetCooldown(startTime, duration)
    else
        slot.cd:Clear()
    end
    -- Blizzard's button stays on top, see-through: its tooltip and its
    -- right-click to cancel keep working.
    if button:GetParent() ~= slot then button:SetParent(slot) end
    button:ClearAllPoints()
    button:SetAllPoints(slot)
    if not blizzTotems[button] then
        blizzTotems[button] = true
        if button.Border then button.Border:SetAlpha(0) end
        if button.Icon then button.Icon:SetAlpha(0) end
        if button.Duration then button.Duration:SetAlpha(0) end
    end
    slot:Show()
end

local function UpdateTotems()
    if not TotemsActive() then
        if totemBar then totemBar:Hide() end
        return
    end
    TotemBar()
    for _, slot in ipairs(totemSlots) do slot:Hide() end
    local pool = _G.TotemFrame.totemPool
    if pool then
        for button in pool:EnumerateActive() do
            local slot = totemSlots[button.layoutIndex or 0]
            if slot then FillSlot(slot, button) end
        end
    end
    totemBar:Show()
end

local function LayoutTotems(s)
    local bar = TotemBar()
    local size, gap, grow = s.twTotemSize or 36, s.twTotemSpacing or 2, s.twTotemGrow or "RIGHT"
    local n = #totemSlots
    local horizontal = grow == "RIGHT" or grow == "LEFT"
    local long = size * n + gap * (n - 1)
    bar:SetSize(horizontal and long or size, horizontal and size or long)
    for i, slot in ipairs(totemSlots) do
        slot:SetSize(size, size)
        slot:ClearAllPoints()
        local off = (i - 1) * (size + gap)
        if grow == "RIGHT" then slot:SetPoint("LEFT", bar, "LEFT", off, 0)
        elseif grow == "LEFT" then slot:SetPoint("RIGHT", bar, "RIGHT", -off, 0)
        elseif grow == "DOWN" then slot:SetPoint("TOP", bar, "TOP", 0, -off)
        else slot:SetPoint("BOTTOM", bar, "BOTTOM", 0, off) end
    end
    Place(bar, s.twTotemPosition, TOTEM_DEFAULT)
    bar:EnableMouse(BH.unlockMode and true or false)
end

-- Switched off: Blizzard's buttons go back to its own totem frame.
local function GiveBack()
    local home = _G.TotemFrame
    if not home then return end
    for button in pairs(blizzTotems) do
        blizzTotems[button] = nil
        button:SetParent(home)
        if button.Border then button.Border:SetAlpha(1) end
        if button.Icon then button.Icon:SetAlpha(1) end
        if button.Duration then button.Duration:SetAlpha(1) end
    end
    if home.Update then home:Update() end
end

local totemHooked
local function Totems(s)
    if not TotemsActive() then
        if totemBar then totemBar:Hide() end
        if next(blizzTotems) then GiveBack() end
        return
    end
    LayoutTotems(s)
    if not totemHooked then
        totemHooked = true
        hooksecurefunc(_G.TotemFrame, "Update", UpdateTotems)
    end
    UpdateTotems()
end

-- ============================================================================
-- Reputation bar
-- ============================================================================

local REP_DEFAULT = { point = "CENTER", relPoint = "CENTER", x = 0, y = -300 }
local repBar

local function RepInfo()
    local R = C_Reputation
    local data = R and R.GetWatchedFactionData and R.GetWatchedFactionData()
    if not data or not data.factionID or data.factionID == 0 then return nil end
    local id = data.factionID
    local info = { name = data.name, min = data.currentReactionThreshold, max = data.nextReactionThreshold,
        value = data.currentStanding, reaction = data.reaction }
    info.label = _G["FACTION_STANDING_LABEL" .. (data.reaction or 4)] or ""
    local c = FACTION_BAR_COLORS and FACTION_BAR_COLORS[data.reaction or 4]
    info.r, info.g, info.b = c and c.r or 0, c and c.g or 0.6, c and c.b or 0.1

    if R.IsMajorFaction and R.IsMajorFaction(id) and C_MajorFactions then
        local renown = C_MajorFactions.GetMajorFactionRenownInfo(id)
        if renown then
            info.label = (RENOWN_LEVEL_LABEL or "Renown %d"):format(renown.renownLevel)
            info.min, info.max, info.value = 0, renown.renownLevelThreshold, renown.renownReputationEarned
            if C_MajorFactions.HasMaximumRenown(id) then info.value = info.max end
            info.r, info.g, info.b = 0, 0.75, 0.94
        end
    elseif C_GossipInfo and C_GossipInfo.GetFriendshipReputation then
        local f = C_GossipInfo.GetFriendshipReputation(id)
        if f and f.friendshipFactionID and f.friendshipFactionID > 0 then
            info.label = f.reaction
            if f.nextThreshold then
                info.min, info.max, info.value = f.reactionThreshold, f.nextThreshold, f.standing
            else
                info.min, info.max, info.value = 0, 1, 1
            end
        end
    end

    if R.IsFactionParagonForCurrentPlayer and R.IsFactionParagonForCurrentPlayer(id) then
        local cur, threshold, _, pending = R.GetFactionParagonInfo(id)
        if cur and threshold and threshold > 0 then
            info.label = "Paragon" .. (pending and " (reward waiting)" or "")
            info.min, info.max, info.value = 0, threshold, cur % threshold
            if pending then info.value = threshold end
        end
    end
    if not info.max or info.max <= info.min then info.min, info.max, info.value = 0, 1, 1 end
    return info
end

local function RepText(s, info)
    local mode = s.twRepText or "NONE"
    local cur, span = info.value - info.min, info.max - info.min
    if mode == "PERCENT" then return info.label .. ": " .. math.floor(cur / span * 100 + 0.5) .. "%" end
    if mode == "CURMAX" then return info.label .. ": " .. BreakUpLargeNumbers(cur) .. " / " .. BreakUpLargeNumbers(span) end
    if mode == "REMAINING" then return info.label .. ": " .. BreakUpLargeNumbers(span - cur) .. " to go" end
    return ""
end

local function RepTooltip(self)
    local info = RepInfo()
    if not info then return end
    GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
    GameTooltip:AddLine(info.name, 1, 1, 1)
    GameTooltip:AddDoubleLine("Standing", info.label, 1, 0.82, 0, info.r, info.g, info.b)
    local cur, span = info.value - info.min, info.max - info.min
    GameTooltip:AddDoubleLine("Progress", BreakUpLargeNumbers(cur) .. " / " .. BreakUpLargeNumbers(span)
        .. " (" .. math.floor(cur / span * 100 + 0.5) .. "%)", 1, 0.82, 0, 1, 1, 1)
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Click: reputation window", 0.7, 0.7, 0.7)
    GameTooltip:Show()
end

local function RepBar()
    if repBar then return repBar end
    local f = CreateFrame("Button", "SquizzumablesReputationBar", UIParent)
    f:SetFrameStrata("LOW")
    f.bg = f:CreateTexture(nil, "BACKGROUND")
    f.bg:SetAllPoints()
    f.bg:SetColorTexture(0, 0, 0, 1)
    f.bar = CreateFrame("StatusBar", nil, f)
    f.bar:SetPoint("TOPLEFT", 1, -1)
    f.bar:SetPoint("BOTTOMRIGHT", -1, 1)
    f.bar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
    f.inner = f.bar:CreateTexture(nil, "BACKGROUND")
    f.inner:SetAllPoints()
    f.inner:SetColorTexture(0.1, 0.1, 0.1, 0.9)
    f.text = f.bar:CreateFontString(nil, "OVERLAY")
    f.text:SetPoint("CENTER")
    Movable(f, "twRepPosition")
    f:SetScript("OnEnter", RepTooltip)
    f:SetScript("OnLeave", GameTooltip_Hide)
    f:SetScript("OnClick", function()
        if BH.unlockMode or InCombatLockdown() then return end
        ToggleCharacter("ReputationFrame")
    end)
    repBar = f
    BH.repBar = f
    return f
end

local function UpdateRep()
    local s = BH.settings
    if not (s and s.twRep) or TW.ElvDoes("rep") then
        if repBar then repBar:Hide() end
        return
    end
    local f = RepBar()
    local info = RepInfo()
    if not info and not BH.unlockMode then
        f:Hide()
        return
    end
    info = info or { min = 0, max = 1, value = 0.5, label = "Reputation", r = 0, g = 0.6, b = 0.1 }
    f.bar:SetMinMaxValues(info.min, info.max)
    f.bar:SetValue(info.value)
    f.bar:SetStatusBarColor(info.r, info.g, info.b)
    f.text:SetText(s.twRepVertical and "" or RepText(s, info))
    f:Show()
end

local function Rep(s)
    if not s.twRep or TW.ElvDoes("rep") then
        if repBar then repBar:Hide() end
        return
    end
    local f = RepBar()
    f:SetSize(s.twRepWidth or 222, s.twRepHeight or 10)
    f.bar:SetOrientation(s.twRepVertical and "VERTICAL" or "HORIZONTAL")
    local path = STANDARD_TEXT_FONT
    if s.twRepFont and s.twRepFont ~= "__default" then
        local lsm = LibStub and LibStub("LibSharedMedia-3.0", true)
        path = lsm and lsm:Fetch("font", s.twRepFont, true) or path
    end
    f.text:SetFont(path, math.max(8, math.min(14, (s.twRepHeight or 10) - 2)), "OUTLINE")
    Place(f, s.twRepPosition, REP_DEFAULT)
    UpdateRep()
end

-- ============================================================================
-- Keystone into the font of power
-- ============================================================================

local function InsertKeystone()
    local s = BH.settings
    if not (s and s.twQuickKeystone) or TW.WTDoes("keystone") then return end
    if C_ChallengeMode.HasSlottedKeystone and C_ChallengeMode.HasSlottedKeystone() then return end
    for bag = 0, NUM_BAG_SLOTS or 4 do
        for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
            local id = C_Container.GetContainerItemID(bag, slot)
            if id and C_Item.IsItemKeystoneByID(id) then
                C_Container.UseContainerItem(bag, slot)
                return
            end
        end
    end
end

local keystoneHooked
local function HookKeystone()
    local f = _G.ChallengesKeystoneFrame
    if keystoneHooked or not f then return end
    keystoneHooked = true
    f:HookScript("OnShow", InsertKeystone)
end

-- ============================================================================
-- Vignette: four soft black edges, drawn under the whole interface
-- ============================================================================

local vignette
local function Vignette(s)
    if not s.twVignette or TW.WTDoes("vignette") then
        if vignette then vignette:Hide() end
        return
    end
    if not vignette then
        vignette = CreateFrame("Frame", "SquizzumablesVignette", UIParent)
        vignette:SetAllPoints(UIParent)
        vignette:SetFrameStrata("BACKGROUND")
        vignette:SetFrameLevel(0)
        vignette:EnableMouse(false)
        vignette.edges = {}
        for _, side in ipairs({ "TOP", "BOTTOM", "LEFT", "RIGHT" }) do
            local t = vignette:CreateTexture(nil, "BACKGROUND")
            t:SetTexture("Interface\\Buttons\\WHITE8x8")
            t.side = side
            vignette.edges[side] = t
        end
    end
    local a = (s.twVignetteLevel or 30) / 100
    local dark, clear = CreateColor(0, 0, 0, a), CreateColor(0, 0, 0, 0)
    local w, h = UIParent:GetWidth(), UIParent:GetHeight()
    local depth = math.min(w, h) * 0.3
    for side, t in pairs(vignette.edges) do
        t:ClearAllPoints()
        if side == "TOP" or side == "BOTTOM" then
            t:SetPoint(side .. "LEFT")
            t:SetPoint(side .. "RIGHT")
            t:SetHeight(depth)
            -- VERTICAL runs bottom colour to top colour.
            if side == "TOP" then t:SetGradient("VERTICAL", clear, dark) else t:SetGradient("VERTICAL", dark, clear) end
        else
            t:SetPoint("TOP" .. side)
            t:SetPoint("BOTTOM" .. side)
            t:SetWidth(depth)
            if side == "LEFT" then t:SetGradient("HORIZONTAL", dark, clear) else t:SetGradient("HORIZONTAL", clear, dark) end
        end
    end
    vignette:Show()
end

-- ============================================================================
-- Apply, events, ElvUI copy
-- ============================================================================

function TW.Apply()
    local s = BH.settings
    if not s then return end
    TalkingHead(s)
    CooldownNumbers(s)
    Totems(s)
    Rep(s)
    Tracker()
    HookKeystone()
    Vignette(s)
    if ns.MailContacts then ns.MailContacts.Apply() end
end

local function PositionFromMover(str)
    if type(str) ~= "string" then return nil end
    local pt, _, rel, x, y = strsplit(",", str)
    if not (pt and rel and tonumber(x) and tonumber(y)) then return nil end
    return { point = pt, relPoint = rel, x = tonumber(x), y = tonumber(y) }
end

local function Seed()
    local s = BH.settings
    if not s or s.twSeededFromElvUI then return end
    local E = Elv()
    if not (E and E.db and E.db.general) then return end
    s.twSeededFromElvUI = true
    local g, movers = E.db.general, E.db.movers or {}
    if g.autoRepair == "GUILD" or g.autoRepair == "PLAYER" then s.twRepair = g.autoRepair end
    if tonumber(g.talkingHeadFrameScale) then s.twTalkingHeadScale = math.floor(g.talkingHeadFrameScale * 100 + 0.5) end
    if g.objectiveFrameAutoHideInKeystone then s.twTrackerKeystone = true end
    if E.private and E.private.general and E.private.general.totemTracker then
        s.twTotems = true
        local t = g.totems or {}
        if tonumber(t.size) then s.twTotemSize = tonumber(t.size) end
        if tonumber(t.spacing) then s.twTotemSpacing = tonumber(t.spacing) end
        local vertical = t.growthDirection == "VERTICAL"
        local descending = t.sortDirection == "DESCENDING"
        s.twTotemGrow = vertical and (descending and "UP" or "DOWN") or (descending and "LEFT" or "RIGHT")
        s.twTotemPosition = PositionFromMover(movers.TotemTrackerMover) or s.twTotemPosition
    end
    local r = E.db.databars and E.db.databars.reputation
    if type(r) == "table" and r.enable then
        s.twRep = true
        if tonumber(r.width) then s.twRepWidth = tonumber(r.width) end
        if tonumber(r.height) then s.twRepHeight = tonumber(r.height) end
        s.twRepVertical = r.orientation == "VERTICAL"
            or (r.orientation == "AUTOMATIC" and (r.height or 0) > (r.width or 0))
        local lsm = LibStub and LibStub("LibSharedMedia-3.0", true)
        if r.font and lsm and lsm:IsValid("font", r.font) then s.twRepFont = r.font end
        if r.textFormat == "PERCENT" then s.twRepText = "PERCENT"
        elseif r.textFormat == "CURMAX" or r.textFormat == "CURMAXPERC" then s.twRepText = "CURMAX"
        elseif r.textFormat == "REM" then s.twRepText = "REMAINING" end
        s.twRepPosition = PositionFromMover(movers.ReputationBarMover) or s.twRepPosition
    end
    BH:SaveSettings()
end

-- WindTools' quick keystone, vignette and contacts switches, copied once.
local function SeedFromWT()
    local s = BH.settings
    local wt = WTdb()
    if not (s and wt) or s.twSeededFromWT then return end
    s.twSeededFromWT = true
    local function On(path)
        local ok, v = pcall(path, wt)
        return ok and v and true or false
    end
    s.twQuickKeystone = On(function(w) return w.combat.quickKeystone.enable end)
    s.twVignette = On(function(w) return w.skins.vignetting.enable end)
    local ok, level = pcall(function() return wt.skins.vignetting.level end)
    if ok and tonumber(level) then s.twVignetteLevel = tonumber(level) end
    local okC, c = pcall(function() return wt.item.contacts end)
    if okC and type(c) == "table" then
        s.twMail = c.enable and true or false
        if c.defaultPage == "ALTS" or c.defaultPage == "FRIENDS" or c.defaultPage == "GUILD"
            or c.defaultPage == "FAVORITE" then s.twMailPage = c.defaultPage end
    end
    BH:SaveSettings()
end

function BH:ApplyTweaks()
    Seed()
    SeedFromWT()
    TW.Apply()
end

local ev = CreateFrame("Frame")
for _, e in ipairs({ "PLAYER_LOGIN", "MERCHANT_SHOW", "UPDATE_FACTION", "MAJOR_FACTION_RENOWN_LEVEL_CHANGED",
    "PLAYER_ENTERING_WORLD", "CHALLENGE_MODE_START", "CHALLENGE_MODE_COMPLETED", "CHALLENGE_MODE_RESET",
    "PLAYER_REGEN_ENABLED", "ADDON_LOADED", "DISPLAY_SIZE_CHANGED", "UI_SCALE_CHANGED" }) do
    pcall(ev.RegisterEvent, ev, e)
end
ev:SetScript("OnEvent", function(_, event, arg)
    if event == "ADDON_LOADED" then
        if arg == "Blizzard_ChallengesUI" then HookKeystone() end
    elseif event == "DISPLAY_SIZE_CHANGED" or event == "UI_SCALE_CHANGED" then
        if vignette and BH.settings then Vignette(BH.settings) end
    elseif event == "PLAYER_LOGIN" then
        BH:ApplyTweaks()
    elseif event == "MERCHANT_SHOW" then
        Repair()
    elseif event == "UPDATE_FACTION" or event == "MAJOR_FACTION_RENOWN_LEVEL_CHANGED" then
        UpdateRep()
    elseif event == "PLAYER_REGEN_ENABLED" then
        if trackerPending then Tracker() end
    else
        -- Entering the world and keys starting or ending. The key state
        -- settles a moment after the event.
        C_Timer.After(1, Tracker)
        if event == "PLAYER_ENTERING_WORLD" then UpdateRep() end
    end
end)
