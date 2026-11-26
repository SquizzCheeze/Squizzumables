-- Tooltip/More.lua
-- Tooltip stage 3, WindTools' tooltip extras: icons (race and spec in
-- Tooltip.lua; here the icon by an item's or spell's name, faction, battle
-- pet type and ID), the Mythic+ best run's dungeon and timed upgrades,
-- keystones, raid progression with Shift, tier set pieces, quest progress on
-- creatures, and a group listing's members by role.
--
-- WindTools is restricted-source, so its code was read for behaviour only.
-- Nothing here comes from it: dungeon names, icons and timers come from
-- C_ChallengeMode, raids from the Encounter Journal, each boss's kill
-- statistic is found in the game's own Statistics list by name, tier sets by
-- their item set, and other players' keystones through LibKeystone (shipped
-- with BigWigs, Details and others; used only when one of them loaded it).
-- The quest weights are MMOSimca's freely licensed data
-- (Tooltip/QuestWeights.lua).
--
-- Settings are on Tooltip.lua's "More" page. Same rules as stages 1 and 2.

local addonName, ns = ...
local BH = ns.BH
local TT = ns.Tooltip
if not (TT and TT.shared) then return end
local SH = TT.shared
local Active, Settings = SH.Active, SH.Settings

local function Readable(...)
    for i = 1, select("#", ...) do
        if not canaccessvalue(select(i, ...)) then return false end
    end
    return true
end

local function SecretIdentity(unit)
    local f = C_Secrets and C_Secrets.ShouldUnitIdentityBeSecret
    if not f then return false end
    local secret = f(unit)
    return not canaccessvalue(secret) or secret
end

local function Icon(tex, w, h)
    return "|T" .. tex .. ":" .. (h or 14) .. ":" .. (w or 16) .. ":0:0:64:64:5:59:9:55|t"
end

-- While WindTools runs one of these itself, ours stays out of the way. Only
-- for the ones WindTools hooks directly (title icons, quest progress, group
-- info): its faction and pet icons and pet ID ride on ElvUI's own unit
-- tooltip, which is off whenever ours runs, so those never defer.
local function WTDoes(key)
    local E = SH.Elv()
    local wt = E and E.private and E.private.WT and E.private.WT.tooltips
    if not (wt and C_AddOns.IsAddOnLoaded("ElvUI_WindTools")) then return false end
    local v = wt[key]
    if type(v) == "table" then return v.enable and true or false end
    return v and true or false
end

-- ============================================================================
-- Dungeons
-- ============================================================================

local SKIP_WORDS = { the = true, of = true, a = true, an = true }
local function ShortName(name)
    if not name or name:find("[\128-\255]") then return name end
    local out = ""
    for w in name:gmatch("[^%s%-,:']+") do
        if not SKIP_WORDS[w:lower()] then out = out .. w:sub(1, 1):upper() end
    end
    if #out < 2 then return name:sub(1, 4) end
    return out
end

local mapCache = {}
local function MapInfo(mapID)
    if not (mapID and canaccessvalue(mapID) and mapID > 0) then return nil end
    local m = mapCache[mapID]
    if m == nil then
        local name, _, timeLimit, texture = C_ChallengeMode.GetMapUIInfo(mapID)
        m = name and { name = name, short = ShortName(name), time = timeLimit, tex = texture } or false
        mapCache[mapID] = m
    end
    return m or nil
end

local function DungeonText(m)
    local s = Settings()
    local text = s.ttShortDungeons ~= false and m.short or m.name
    if s.ttDungeonIcons ~= false and m.tex then text = Icon(m.tex) .. " " .. text end
    return text
end

-- Called by Extras.lua's Mythic+ lines in place of its plain best run.
function TT.BestRunLine(tt, runs)
    local best
    for _, run in ipairs(runs) do
        if Readable(run.mapScore, run.challengeModeID, run.bestRunLevel, run.finishedSuccess)
                and (not best or run.mapScore > best.mapScore) then
            best = run
        end
    end
    local m = best and MapInfo(best.challengeModeID)
    if not (m and best.bestRunLevel and best.bestRunLevel > 0) then return end
    local level = tostring(best.bestRunLevel)
    if best.finishedSuccess then
        local c = C_ChallengeMode.GetSpecificDungeonOverallScoreRarityColor(best.mapScore)
        if c then level = c:WrapTextInColorCode(level) end
        local ms = best.bestRunDurationMS
        if m.time and m.time > 0 and ms and canaccessvalue(ms) then
            local sec = ms / 1000
            local ups = (sec <= m.time * 0.6 and 3) or (sec <= m.time * 0.8 and 2) or 1
            level = string.rep("+", ups) .. level
        end
    else
        level = "|cffaaaaaa" .. level .. "|r"
    end
    tt:AddDoubleLine("Mythic+ Best Run:", DungeonText(m) .. " " .. level, nil, nil, nil, 1, 1, 1)
end

-- ============================================================================
-- Keystones
-- ============================================================================

local keys = {}   -- short name (Name or Name-Realm) -> { level, map }
local LKS

local function KeystoneLine(tt, unit)
    if BH.IS_FOREVER or Settings().ttKeystone == false then return end
    local level, map
    local isMe = UnitIsUnit(unit, "player")
    if canaccessvalue(isMe) and isMe then
        level, map = C_MythicPlus.GetOwnedKeystoneLevel(), C_MythicPlus.GetOwnedKeystoneChallengeMapID()
    else
        local name = GetUnitName(unit, true)
        local k = name and canaccessvalue(name) and keys[name]
        if k then level, map = k.level, k.map end
    end
    if not (level and canaccessvalue(level) and level > 0) then return end
    local m = MapInfo(map)
    if not m then return end
    local text = DungeonText(m) .. " (" .. level .. ")"
    local c = C_ChallengeMode.GetKeystoneLevelRarityColor and C_ChallengeMode.GetKeystoneLevelRarityColor(level)
    if c then text = c:WrapTextInColorCode(text) end
    tt:AddDoubleLine("Keystone:", text, nil, nil, nil, 1, 1, 1)
end

local function OnKeystone(level, map, _, name)
    if type(name) ~= "string" or not canaccessvalue(name) then return end
    if not (tonumber(level) and tonumber(level) > 0) then keys[name] = nil return end
    keys[name] = { level = tonumber(level), map = tonumber(map) }
end

local lastRequest = 0
local function RequestKeys()
    if BH.IS_FOREVER or not (LKS and IsInGroup() and not IsInRaid()) then return end
    if GetTime() - lastRequest < 10 then return end
    lastRequest = GetTime()
    LKS.Request("PARTY")
end

-- ============================================================================
-- Tier sets (the slots tier pieces go in)
-- ============================================================================

local TIER_SLOTS = { 1, 3, 5, 7, 10 }
function TT.CountTier(unit)
    if Settings().ttTierSet == false then return nil end
    local counts, best = {}, 0
    for _, slot in ipairs(TIER_SLOTS) do
        local link = GetInventoryItemLink(unit, slot)
        if link and canaccessvalue(link) then
            local setID = select(16, C_Item.GetItemInfo(link))
            if setID and setID > 0 then
                counts[setID] = (counts[setID] or 0) + 1
                if counts[setID] > best then best = counts[setID] end
            end
        end
    end
    return best > 0 and best or nil
end

function TT.TierText(n)
    local color = (n >= 4 and "d946ef") or (n >= 2 and "3b82f6") or "34d399"
    return "|cff" .. color .. "(" .. n .. "/5)|r"
end

-- ============================================================================
-- Raid progression (Shift, out of combat)
-- ============================================================================

local DIFFS = {   -- highest first
    { key = "M", word = PLAYER_DIFFICULTY6 or "Mythic", color = "ff8000" },
    { key = "H", word = PLAYER_DIFFICULTY2 or "Heroic", color = "a335ee" },
    { key = "N", word = PLAYER_DIFFICULTY1 or "Normal", color = "1eff00" },
    { key = "L", word = PLAYER_DIFFICULTY3 or "Raid Finder", color = "0070dd" },
}

local raids   -- { { name, short, stats = { M = {ids}, H = ..., N = ..., L = ... } } }

-- This season's raids from the Encounter Journal, then each boss's kill
-- statistic by its name ("<boss> kills (<difficulty> <raid>)"). Once per
-- session; a raid whose statistics are not found simply gets no line.
local NO_RAIDS, lastTry = {}, 0
local function FindRaids()
    if raids then return raids end
    -- Nothing found yet: try again later rather than once and never.
    if GetTime() - lastTry < 30 then return NO_RAIDS end
    lastTry = GetTime()
    if not (EJ_GetNumTiers and EJ_SelectTier and EJ_GetInstanceByIndex) then return NO_RAIDS end
    local tiers = EJ_GetNumTiers() or 0
    if tiers < 1 then return NO_RAIDS end
    -- 0 means the journal has no tier chosen yet, which cannot be put back.
    local was = EJ_GetCurrentTier()
    local found = {}
    EJ_SelectTier(tiers)
    local i = 1
    while true do
        local _, name = EJ_GetInstanceByIndex(i, true)
        if not name then break end
        found[#found + 1] = { name = name, short = ShortName(name), stats = {} }
        i = i + 1
    end
    if was and was >= 1 and was ~= tiers then EJ_SelectTier(was) end
    if #found == 0 then return NO_RAIDS end
    raids = found

    for _, cat in ipairs(GetStatisticsCategoryList() or {}) do
        for j = 1, (GetCategoryNumAchievements(cat) or 0) do
            local id, statName = GetAchievementInfo(cat, j)
            local paren = statName and statName:match("%(([^()]+)%)%s*$")
            if paren then
                for _, raid in ipairs(raids) do
                    local a, b = paren:find(raid.name, 1, true)
                    if a then
                        local rest = paren:sub(1, a - 1) .. paren:sub(b + 1)
                        for _, d in ipairs(DIFFS) do
                            if rest:find(d.word, 1, true) then
                                raid.stats[d.key] = raid.stats[d.key] or {}
                                table.insert(raid.stats[d.key], id)
                                break
                            end
                        end
                    end
                end
            end
        end
    end
    return raids
end

local progCache = {}   -- guid -> { time, lines = { {left, right} } }
local progShown = setmetatable({}, { __mode = "k" })
local waitingProg

local function ReadProgression(statFn)
    local lines = {}
    for _, raid in ipairs(FindRaids()) do
        for _, d in ipairs(DIFFS) do
            local ids = raid.stats[d.key]
            if ids and #ids > 0 then
                local killed = 0
                for _, id in ipairs(ids) do
                    local v = tonumber(statFn(id))
                    if v and v > 0 then killed = killed + 1 end
                end
                if killed > 0 then
                    local left = Settings().ttShortDungeons ~= false and raid.short or raid.name
                    lines[#lines + 1] = { left, "|cff" .. d.color .. killed .. "/" .. #ids .. " " .. d.key .. "|r" }
                    break
                end
            end
        end
    end
    return lines
end

local function AddProgression(tt, guid, lines)
    if progShown[tt] == guid or #lines == 0 then return end
    progShown[tt] = guid
    tt:AddLine(" ")
    tt:AddLine("Raid Progression", 1, 0.82, 0)
    for _, l in ipairs(lines) do tt:AddDoubleLine(l[1], l[2], 1, 1, 1) end
    tt:Show()
end

local function Progression(tt, unit)
    if InCombatLockdown() or not IsShiftKeyDown() or Settings().ttProgression == false then return end
    local guid = UnitGUID(unit)
    if not canaccessvalue(guid) or not guid then return end
    if #FindRaids() == 0 then return end
    local isMe = UnitIsUnit(unit, "player")
    if canaccessvalue(isMe) and isMe then
        AddProgression(tt, guid, ReadProgression(GetStatistic))
        return
    end
    local c = progCache[guid]
    if c and GetTime() - c.time < 120 then AddProgression(tt, guid, c.lines) return end
    -- The achievement window's comparison uses the same slot; leave it be.
    if AchievementFrame and AchievementFrame:IsShown() then return end
    if waitingProg == guid then return end
    waitingProg = guid
    SetAchievementComparisonUnit(unit)
end

local function OnAchievementReady(guid)
    if not (waitingProg and guid == waitingProg) then return end
    waitingProg = nil
    local lines = ReadProgression(GetComparisonStatistic)
    ClearAchievementComparisonUnit()
    progCache[guid] = { time = GetTime(), lines = lines }
    local mg = UnitExists("mouseover") and UnitGUID("mouseover")
    if mg and canaccessvalue(mg) and mg == guid and GameTooltip:IsShown() and not GameTooltip:IsForbidden() then
        AddProgression(GameTooltip, guid, lines)
    end
end

-- ============================================================================
-- Faction and battle pet icons, pet ID
-- ============================================================================

local factionTex, petTex
local function CornerTexture()
    local t = GameTooltip:CreateTexture(nil, "OVERLAY")
    t:SetSize(35, 35)
    t:SetBlendMode("ADD")
    t:Hide()
    return t
end

local function FactionIcon(unit)
    if Settings().ttFactionIcon == false then return end
    local faction = UnitFactionGroup(unit)
    if not (faction and canaccessvalue(faction)) or (faction ~= "Alliance" and faction ~= "Horde") then return end
    factionTex = factionTex or CornerTexture()
    factionTex:ClearAllPoints()
    factionTex:SetPoint("TOPRIGHT", GameTooltip, "TOPRIGHT", 0, -5)
    factionTex:SetAlpha(0.5)
    factionTex:SetTexture("Interface\\FriendsFrame\\PlusManz-" .. faction)
    factionTex:Show()
end

local function PetLines(tt, unit)
    local wild, companion = UnitIsWildBattlePet(unit), UnitIsBattlePetCompanion(unit)
    if not Readable(wild, companion) or not (wild or companion) then return end
    local s = Settings()
    if s.ttPetIcon ~= false then
        local ptype = UnitBattlePetType(unit)
        local suffix = canaccessvalue(ptype) and PET_TYPE_SUFFIX and PET_TYPE_SUFFIX[ptype]
        if suffix then
            petTex = petTex or CornerTexture()
            petTex:ClearAllPoints()
            petTex:SetPoint("TOPRIGHT", GameTooltip, "TOPRIGHT", -5, -5)
            petTex:SetTexture("Interface\\PetBattles\\PetIcon-" .. suffix)
            petTex:SetTexCoord(0.188, 0.883, 0, 0.348)
            petTex:Show()
        end
    end
    if s.ttPetID ~= false then
        local species = UnitBattlePetSpeciesID(unit)
        if species and canaccessvalue(species) then
            tt:AddDoubleLine("Pet ID:", tostring(species), nil, nil, nil, 1, 1, 1)
        end
    end
end

local function ClearCorners()
    if factionTex then factionTex:Hide() end
    if petTex then petTex:Hide() end
end

-- ============================================================================
-- Quest progress on creatures
-- ============================================================================

local weights
local function QuestProgress(tt, unit)
    if Settings().ttQuestProgress == false or WTDoes("objectiveProgress") or not ns.LoadQuestWeights then return end
    local guid = UnitGUID(unit)
    if not canaccessvalue(guid) or not guid then return end
    local kind, _, _, _, _, npc = strsplit("-", guid)
    npc = tonumber(npc)
    if not (npc and (kind == "Creature" or kind == "Vehicle")) then return end
    weights = weights or ns.LoadQuestWeights()
    local decimals = Settings().ttQuestDecimals or 1
    for i = 1, C_QuestLog.GetNumQuestLogEntries() do
        local info = C_QuestLog.GetInfo(i)
        local w = info and not info.isHeader and weights[info.questID] and weights[info.questID][npc]
        if w and info.title then
            for line = 2, tt:NumLines() do
                local fs = _G["GameTooltipTextLeft" .. line]
                local text = fs and fs:GetText()
                if text and canaccessvalue(text) and text == info.title then
                    fs:SetText(text .. string.format(" |cffffffff+ %." .. decimals .. "f%%|r", w))
                    break
                end
            end
        end
    end
end

local function OnUnit(tt)
    if tt ~= GameTooltip or tt:IsForbidden() or not Active() then return end
    local unit = SH.TooltipUnit(tt)
    if not unit then return end
    local isPlayer = UnitIsPlayer(unit)
    if not canaccessvalue(isPlayer) then return end
    if isPlayer then
        if SecretIdentity(unit) then return end
        FactionIcon(unit)
        if not InCombatLockdown() then KeystoneLine(tt, unit) end
        Progression(tt, unit)
    else
        PetLines(tt, unit)
        QuestProgress(tt, unit)
    end
end

-- ============================================================================
-- Icon by the name
-- ============================================================================

local ICON_TIPS = { GameTooltip = true, ItemRefTooltip = true, ShoppingTooltip1 = true, ShoppingTooltip2 = true,
                    ItemRefShoppingTooltip1 = true, ItemRefShoppingTooltip2 = true }

local T = Enum.TooltipDataType
local function ItemIcon(id) return C_Item.GetItemIconByID(id) end
local function SpellIcon(id) return C_Spell.GetSpellTexture(id) end
local ICON_FOR = T and {
    [T.Item] = ItemIcon,
    [T.Toy] = ItemIcon,
    [T.Spell] = SpellIcon,
    [T.Mount] = function(id) return (select(3, C_MountJournal.GetMountInfoByID(id))) end,
    [T.Currency] = function(id)
        local info = C_CurrencyInfo.GetCurrencyInfo(id)
        return info and info.iconFileID
    end,
    [T.Achievement] = function(id) return (select(10, GetAchievementInfo(id))) end,
    [T.EquipmentSet] = function(id) return (select(2, C_EquipmentSet.GetEquipmentSetInfo(id))) end,
} or {}

local function TitleIcon(tt, data)
    if not (tt and not tt:IsForbidden() and Active()) or Settings().ttTitleIcon == false or WTDoes("titleIcon") then
        return
    end
    local name = tt:GetName()
    if not (name and ICON_TIPS[name]) or type(data) ~= "table" then return end
    local lines = data.lines
    local first = lines and lines[1]
    local title = first and first.leftText
    if not (title and canaccessvalue(title) and title ~= "") then return end
    local icon
    local fn = ICON_FOR[data.type]
    if fn and data.id and canaccessvalue(data.id) then
        icon = fn(data.id)
    elseif T and data.type == T.Macro and first.tooltipID and canaccessvalue(first.tooltipID) then
        local sub = (first.tooltipType == T.Item and ItemIcon) or (first.tooltipType == T.Spell and SpellIcon)
        icon = sub and sub(first.tooltipID)
    end
    if not icon then return end
    for i = 1, 3 do
        local fs = _G[name .. "TextLeft" .. i]
        local text = fs and fs:GetText()
        if text and canaccessvalue(text) and text:find(title, 1, true) then
            if not text:find("^|T") then fs:SetText("|T" .. icon .. ":18:18:0:0:64:64:5:59:5:59|t " .. text) end
            return
        end
    end
end

-- ============================================================================
-- Group finder listings
-- ============================================================================

local ROLE_ORDER = { "TANK", "HEALER", "DAMAGER" }
local ROLE_NAMES = { TANK = { "Tank", "2f6fd9" }, HEALER = { "Healer", "2fd96f" }, DAMAGER = { "Damage", "d93b3b" } }

local classIDs
local function ClassID(file)
    if not classIDs then
        classIDs = {}
        for i = 1, (GetNumClasses and GetNumClasses() or 13) do
            local info = C_CreatureInfo.GetClassInfo(i)
            if info and info.classFile then classIDs[info.classFile] = info.classID end
        end
    end
    return classIDs[file]
end

local function RoleIcon(role, size)
    local atlases = rawget(_G, "LFG_LIST_GROUP_DATA_ATLASES_BORDERLESS")
    local atlas = atlases and atlases[role]
    return atlas and CreateAtlasMarkup(atlas, size, size, 0, 0) or ""
end

local function HideBlizzardMembers(tooltip)
    local name = tooltip:GetName()
    if not name then return end
    local inList = false
    for i = 2, tooltip:NumLines() do
        local fs = _G[name .. "TextLeft" .. i]
        local text = fs and fs:GetText()
        if text and canaccessvalue(text) then
            if text == MEMBERS_COLON then
                inList = true
            elseif inList and (text == " " or text == "") then
                break
            end
            if inList then
                fs:SetText("")
                fs:Hide()
            end
        end
    end
    return inList
end

local function GroupInfo(tooltip, resultID)
    local s = Settings()
    if not Active() or s.ttGroupInfo == false or WTDoes("groupInfo")
            or C_AddOns.IsAddOnLoaded("PremadeGroupsFilter") then
        return
    end
    if not tooltip or tooltip:IsForbidden() then return end
    local info = C_LFGList.GetSearchResultInfo(resultID)
    if not (info and info.activityIDs) then return end
    local numMembers, warMode = info.numMembers, info.isWarMode
    if not canaccessvalue(numMembers) then return end
    if not canaccessvalue(warMode) then return end
    if not numMembers then return end
    if s.ttGroupDungeons == false then
        local act = C_LFGList.GetActivityInfoTable(info.activityIDs[1], nil, warMode)
        if act and act.categoryID == (GROUP_FINDER_CATEGORY_ID_DUNGEONS or 2) then return end
    end
    local byRole, total = { TANK = {}, HEALER = {}, DAMAGER = {} }, 0
    for i = 1, numMembers do
        local m = C_LFGList.GetSearchResultPlayerInfo(resultID, i)
        local role, class = m and m.assignedRole, m and m.classFilename
        local spec = m and m.specName
        if not canaccessvalue(spec) then spec = nil end
        if role and class and canaccessvalue(role) and canaccessvalue(class) and byRole[role]
                and Readable(m.className) then
            local key = class .. "|" .. (spec or "")
            local list = byRole[role]
            if not list[key] then
                list[key] = { class = class, className = m.className, spec = spec, n = 0 }
                table.insert(list, list[key])
            end
            list[key].n = list[key].n + 1
            total = total + 1
        end
    end
    -- Blizzard only lists members when it knows every one; so do we.
    if total ~= numMembers then return end
    if not HideBlizzardMembers(tooltip) then return end
    local compact = s.ttGroupCompact
    if compact then tooltip:AddLine(" ") end
    for _, role in ipairs(ROLE_ORDER) do
        local list = byRole[role]
        if #list > 0 then
            if not compact then
                local rn = ROLE_NAMES[role]
                tooltip:AddLine(" ")
                tooltip:AddLine(RoleIcon(role, 14) .. " |cff" .. rn[2] .. rn[1] .. "|r")
            end
            for _, e in ipairs(list) do
                local color = C_ClassColor.GetClassColor(e.class)
                local text = (e.className or e.class) .. ((e.spec and e.spec ~= "") and (" (" .. e.spec .. ")") or "")
                if color then text = color:WrapTextInColorCode(text) end
                local cid = ClassID(e.class)
                local specIcon = cid and e.spec and TT.SpecIcon(cid, e.spec)
                local line = "|A:classicon-" .. strlower(e.class) .. ":16:16|a "
                    .. (specIcon and (specIcon .. " ") or "") .. text
                if e.n > 1 then line = line .. " |cffffffffx " .. e.n .. "|r" end
                if compact then line = RoleIcon(role, 14) .. " " .. line end
                tooltip:AddLine(line)
            end
        end
    end
    tooltip:Show()
end

-- ============================================================================
-- Wiring
-- ============================================================================

local hooked, groupHooked
local function HookGroupFinder()
    if groupHooked or not LFGListUtil_SetSearchEntryTooltip then return end
    groupHooked = true
    hooksecurefunc("LFGListUtil_SetSearchEntryTooltip", GroupInfo)
end

function TT.ApplyMore()
    if hooked or not Active() then return end
    hooked = true
    local P = TooltipDataProcessor
    if P and P.AddTooltipPostCall and T then
        P.AddTooltipPostCall(T.Unit, OnUnit)
        for kind in pairs(ICON_FOR) do P.AddTooltipPostCall(kind, TitleIcon) end
        P.AddTooltipPostCall(T.Macro, TitleIcon)
    end
    GameTooltip:HookScript("OnTooltipCleared", function(tt)
        ClearCorners()
        progShown[tt] = nil
    end)
    HookGroupFinder()

    LKS = not BH.IS_FOREVER and LibStub and LibStub("LibKeystone", true) or nil
    if LKS then LKS.Register(TT, OnKeystone) end

    local ev = CreateFrame("Frame")
    ev:RegisterEvent("INSPECT_ACHIEVEMENT_READY")
    ev:RegisterEvent("GROUP_ROSTER_UPDATE")
    ev:RegisterEvent("PLAYER_ENTERING_WORLD")
    ev:RegisterEvent("CHALLENGE_MODE_COMPLETED")
    ev:RegisterEvent("ADDON_LOADED")
    ev:SetScript("OnEvent", function(_, event, arg)
        if event == "INSPECT_ACHIEVEMENT_READY" then
            if canaccessvalue(arg) then OnAchievementReady(arg) end
        elseif event == "ADDON_LOADED" then
            if arg == "Blizzard_GroupFinder" then HookGroupFinder() end
        elseif Active() then
            RequestKeys()
        end
    end)
    RequestKeys()
end

-- ============================================================================
-- WindTools' tooltip settings, copied once per profile
-- ============================================================================

function TT.SeedMore()
    local s = BH.settings
    if not s or s.ttMoreSeededFromWT then return end
    if not C_AddOns.IsAddOnLoaded("ElvUI_WindTools") then return end
    local E = SH.Elv()
    local db = E and E.db and E.db.WT and E.db.WT.tooltips
    local pv = E and E.private and E.private.WT and E.private.WT.tooltips
    if type(db) ~= "table" and type(pv) ~= "table" then return end
    s.ttMoreSeededFromWT = true
    local function Bool(v, key) if v ~= nil then s[key] = v and true or false end end
    local function On(t) return type(t) == "table" and t.enable end
    if type(pv) == "table" then
        Bool(On(pv.titleIcon), "ttTitleIcon")
        Bool(pv.factionIcon, "ttFactionIcon")
        Bool(pv.petIcon, "ttPetIcon")
        Bool(pv.petId, "ttPetID")
        Bool(pv.tierSet, "ttTierSet")
        Bool(On(pv.objectiveProgress), "ttQuestProgress")
        if type(pv.objectiveProgress) == "table" and tonumber(pv.objectiveProgress.accuracy) then
            s.ttQuestDecimals = math.max(0, math.min(2, tonumber(pv.objectiveProgress.accuracy)))
        end
        Bool(On(pv.progression), "ttProgression")
    end
    if type(db) == "table" then
        local tw = db.elvUITweaks
        if type(tw) == "table" then
            Bool(On(tw.raceIcon), "ttRaceIcon")
            Bool(On(tw.specIcon), "ttSpecIcon")
            Bool(On(tw.betterMythicPlusInfo), "ttBetterMythic")
            if type(tw.healthBar) == "table" then
                if tonumber(tw.healthBar.barYOffset) then s.ttBarOffsetY = tonumber(tw.healthBar.barYOffset) end
                if tonumber(tw.healthBar.textYOffset) then s.ttBarTextOffsetY = tonumber(tw.healthBar.textYOffset) end
            end
        end
        local k = db.keystone
        if type(k) == "table" then
            Bool(k.enable, "ttKeystone")
            Bool(k.useAbbreviation, "ttShortDungeons")
            Bool(On(k.icon), "ttDungeonIcons")
        end
        local g = db.groupInfo
        if type(g) == "table" then
            Bool(g.enable, "ttGroupInfo")
            if g.excludeDungeon ~= nil then s.ttGroupDungeons = not g.excludeDungeon end
            if g.mode then s.ttGroupCompact = g.mode == "COMPACT" end
        end
    end
    BH:SaveSettings()
end
