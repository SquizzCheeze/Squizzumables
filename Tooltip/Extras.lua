-- Tooltip/Extras.lua
-- Tooltip stage 2, ElvUI's extras: item level with Shift (by inspecting),
-- Mythic+ score and best run, a player's mount, IDs (spells, items, auras,
-- creatures, currencies, toys, mounts, quests), item counts, an edge in the
-- item's quality colour, and the sell price as text or hidden.
--
-- Settings are on Tooltip.lua's Extras page; this file is only behaviour.
-- Same rules as stage 1: canaccessvalue before any read, nothing at all for
-- a player whose identity is secret, and the per-player reads (inspect,
-- auras, Mythic+) out of combat only, where 12.x restricts them anyway.

local addonName, ns = ...
local BH = ns.BH
local TT = ns.Tooltip
if not (TT and TT.shared) then return end
local SH = TT.shared
local Active, Settings, ModDown = SH.Active, SH.Settings, SH.ModDown

local function IDsShown() return ModDown(Settings().ttIDs or "HIDE") end

local function AddID(tt, id, label)
    if id == nil or not canaccessvalue(id) then return end
    tt:AddLine("|cffca3c3c" .. (label or ID) .. ":|r |cffffffff" .. tostring(id) .. "|r")
end

local function SecretIdentity(unit)
    local f = C_Secrets and C_Secrets.ShouldUnitIdentityBeSecret
    if not f then return false end
    local secret = f(unit)
    return not canaccessvalue(secret) or secret
end

-- ============================================================================
-- Item level (Shift, out of combat)
-- ============================================================================

local cache = {}                 -- guid -> { level, time }
local shown = setmetatable({}, { __mode = "k" })   -- tooltip -> guid already given a line
local lastAsked, lastAskedAt = nil, 0
local waitingGUID

local function AddLevel(tt, level, guid, tier)
    if shown[tt] == guid then return end
    shown[tt] = guid
    local right = tostring(math.floor(level + 0.5))
    -- Tier set pieces (stage 3, Tooltip/More.lua).
    if tier and TT.TierText then right = TT.TierText(tier) .. " " .. right end
    tt:AddDoubleLine(STAT_AVERAGE_ITEM_LEVEL .. ":", right, nil, nil, nil, 1, 1, 1)
    tt:Show()
end

local function ItemLevel(tt, unit)
    if InCombatLockdown() or not IsShiftKeyDown() or Settings().ttItemLevel == false then return end
    local guid = UnitGUID(unit)
    if not canaccessvalue(guid) or not guid then return end
    local isMe = UnitIsUnit(unit, "player")
    if canaccessvalue(isMe) and isMe then
        local _, equipped = GetAverageItemLevel()
        if equipped then AddLevel(tt, equipped, guid, TT.CountTier and TT.CountTier("player")) end
        return
    end
    local c = cache[guid]
    if c and GetTime() - c.time < 120 then AddLevel(tt, c.level, guid, c.tier) return end
    local can = CanInspect(unit)
    if not (canaccessvalue(can) and can) then return end
    -- Leave the inspect window's own inspection alone.
    if InspectFrame and InspectFrame:IsShown() then return end
    if lastAsked == guid and GetTime() - lastAskedAt < 4 then return end
    lastAsked, lastAskedAt, waitingGUID = guid, GetTime(), guid
    NotifyInspect(unit)
end

local function OnInspectReady(guid)
    if not (waitingGUID and guid == waitingGUID) then return end
    waitingGUID = nil
    if not UnitExists("mouseover") then return end
    local mg = UnitGUID("mouseover")
    if not canaccessvalue(mg) or mg ~= guid then return end
    local level = C_PaperDollInfo and C_PaperDollInfo.GetInspectItemLevel
        and C_PaperDollInfo.GetInspectItemLevel("mouseover")
    if not (level and canaccessvalue(level) and level > 0) then return end
    local tier = TT.CountTier and TT.CountTier("mouseover")
    cache[guid] = { level = level, time = GetTime(), tier = tier }
    if GameTooltip:IsShown() and not GameTooltip:IsForbidden() then AddLevel(GameTooltip, level, guid, tier) end
end

-- ============================================================================
-- Unit extras
-- ============================================================================

local function Mythic(tt, unit)
    local s = Settings()
    if BH.IS_FOREVER or InCombatLockdown() or s.ttMythic == false then return end
    local info = C_PlayerInfo and C_PlayerInfo.GetPlayerMythicPlusRatingSummary
        and C_PlayerInfo.GetPlayerMythicPlusRatingSummary(unit)
    local score = info and info.currentSeasonScore
    if not (score and canaccessvalue(score) and score > 0) then return end
    local color = s.ttMythicColor ~= false and C_ChallengeMode.GetDungeonScoreRarityColor(score)
    local r, g, b = 1, 1, 1
    if color then r, g, b = color.r, color.g, color.b end
    tt:AddDoubleLine(DUNGEON_SCORE .. ":", tostring(score), nil, nil, nil, r, g, b)
    if s.ttMythicBest ~= false and type(info.runs) == "table" and s.ttBetterMythic ~= false and TT.BestRunLine then
        TT.BestRunLine(tt, info.runs)   -- stage 3's fuller line (Tooltip/More.lua)
    elseif s.ttMythicBest ~= false and type(info.runs) == "table" then
        local best = 0
        for _, run in ipairs(info.runs) do
            if run.finishedSuccess and (run.bestRunLevel or 0) > best then best = run.bestRunLevel end
        end
        if best > 0 then tt:AddDoubleLine("Mythic+ Best Run:", "+" .. best, nil, nil, nil, r, g, b) end
    end
end

local function Mount(tt, unit)
    if InCombatLockdown() or Settings().ttMount == false or not C_MountJournal then return end
    for i = 1, 40 do
        local aura = C_UnitAuras.GetAuraDataByIndex(unit, i, "HELPFUL")
        if not aura then return end
        local id = aura.spellId
        if not canaccessvalue(id) then return end
        local mountID = id and C_MountJournal.GetMountFromSpell(id)
        if mountID and mountID > 0 then
            local name = aura.name
            if name and canaccessvalue(name) then
                tt:AddDoubleLine(MOUNT .. ":", name, nil, nil, nil, 1, 1, 1)
            end
            if IsControlKeyDown() then
                local _, _, source = C_MountJournal.GetMountInfoExtraByID(mountID)
                if source and canaccessvalue(source) and source ~= "" then
                    tt:AddLine(source, 1, 1, 1, true)
                end
            end
            return
        end
    end
end

local function NPCID(tt, unit)
    if not IDsShown() then return end
    local guid = UnitGUID(unit)
    if not canaccessvalue(guid) or not guid then return end
    local kind, _, _, _, _, id = strsplit("-", guid)
    if (kind == "Creature" or kind == "Vehicle" or kind == "Pet") and tonumber(id) then AddID(tt, tonumber(id)) end
end

local function OnUnit(tt)
    if tt ~= GameTooltip or tt:IsForbidden() or not Active() then return end
    local unit = SH.TooltipUnit(tt)
    if not unit then return end
    local isPlayer = UnitIsPlayer(unit)
    if not canaccessvalue(isPlayer) then return end
    if isPlayer then
        if SecretIdentity(unit) then return end
        local isMe = UnitIsUnit(unit, "player")
        if canaccessvalue(isMe) and not isMe then Mount(tt, unit) end
        Mythic(tt, unit)
        ItemLevel(tt, unit)
    else
        NPCID(tt, unit)
    end
end

-- ============================================================================
-- Items
-- ============================================================================

local ITEM_TIPS = { GameTooltip = true, ItemRefTooltip = true, ShoppingTooltip1 = true, ShoppingTooltip2 = true }
local tinted = setmetatable({}, { __mode = "k" })

local function SetEdge(tt, r, g, b)
    local sk = SH.skins[tt]
    if not sk then return end
    for _, e in ipairs(sk.edges) do e:SetColorTexture(r, g, b, 1) end
end

local function OnItem(tt, data)
    if not (tt and not tt:IsForbidden() and ITEM_TIPS[tt:GetName() or ""] and Active()) then return end
    local s = Settings()
    local _, link = tt:GetItem()
    local id = data and data.id
    if link and canaccessvalue(link) then
        if s.ttQuality then
            local q = C_Item.GetItemQualityByID(link)
            if q and q > 1 then
                local r, g, b = C_Item.GetItemQualityColor(q)
                SetEdge(tt, r, g, b)
                tinted[tt] = true
            end
        end
        local lines = {}
        if s.ttCountBags ~= false then
            local n = C_Item.GetItemCount(link)
            if n and n > 0 then lines[#lines + 1] = { "Bags", n } end
        end
        if s.ttCountBank then
            local bags = C_Item.GetItemCount(link) or 0
            local all = C_Item.GetItemCount(link, true, nil, true, true) or 0
            if all - bags > 0 then lines[#lines + 1] = { "Bank", all - bags } end
        end
        if s.ttCountStack then
            local stack = select(8, C_Item.GetItemInfo(link))
            if stack and stack > 1 then lines[#lines + 1] = { "Stack Size", stack } end
        end
        local showID = IDsShown() and id and canaccessvalue(id)
        if showID or #lines > 0 then tt:AddLine(" ") end
        if showID then AddID(tt, id) end
        for _, l in ipairs(lines) do
            tt:AddDoubleLine("|cffca3c3c" .. l[1] .. ":|r", tostring(l[2]), nil, nil, nil, 1, 1, 1)
        end
    elseif IDsShown() and id then
        AddID(tt, id)
    end
end

local function OnTooltipCleared(tt)
    if tinted[tt] then
        tinted[tt] = nil
        SetEdge(tt, 0, 0, 0)
    end
    shown[tt] = nil
end

-- ============================================================================
-- Other IDs
-- ============================================================================

local function OnSimpleID(tt, data)
    if not (tt and not tt:IsForbidden() and Active() and IDsShown()) then return end
    local id = data and data.id
    if id then AddID(tt, id) end
end

local function OnMacro(tt)
    if not (tt and not tt:IsForbidden() and Active() and IDsShown()) then return end
    local info = tt:GetTooltipData()
    local line = info and info.lines and info.lines[1]
    if line and line.tooltipID then AddID(tt, line.tooltipID) end
end

local function OnSellPrice(tt, lineData)
    if not Active() or tt:IsForbidden() or tt.isShopping then return end
    local mode = Settings().ttSellPrice or "BLIZZARD"
    if mode == "BLIZZARD" then return end
    if mode == "HIDE" then return true end
    local price = lineData and lineData.price
    if not (price and canaccessvalue(price)) then return end
    local r, g, b = HIGHLIGHT_FONT_COLOR:GetRGB()
    local maxPrice = lineData.maxPrice
    if maxPrice and canaccessvalue(maxPrice) and maxPrice >= 1 then
        tt:AddLine(SELL_PRICE, r, g, b)
        tt:AddLine("    " .. MINIMUM .. ": " .. C_CurrencyInfo.GetCoinTextureString(price), r, g, b)
        tt:AddLine("    " .. MAXIMUM .. ": " .. C_CurrencyInfo.GetCoinTextureString(maxPrice), r, g, b)
    else
        tt:AddLine(SELL_PRICE .. ": " .. C_CurrencyInfo.GetCoinTextureString(price), r, g, b)
    end
    return true
end

-- ============================================================================
-- Wiring
-- ============================================================================

local hooked
function TT.ApplyExtras()
    if hooked or not Active() then return end
    hooked = true
    local P, T = TooltipDataProcessor, Enum.TooltipDataType
    if P and P.AddTooltipPostCall and T then
        P.AddTooltipPostCall(T.Unit, OnUnit)
        P.AddTooltipPostCall(T.Item, OnItem)
        P.AddTooltipPostCall(T.Spell, OnSimpleID)
        P.AddTooltipPostCall(T.UnitAura, OnSimpleID)
        P.AddTooltipPostCall(T.Currency, OnSimpleID)
        P.AddTooltipPostCall(T.Toy, OnSimpleID)
        P.AddTooltipPostCall(T.Mount, OnSimpleID)
        P.AddTooltipPostCall(T.Quest, OnSimpleID)
        P.AddTooltipPostCall(T.Macro, OnMacro)
    end
    local L = Enum.TooltipDataLineType
    if P and P.AddLinePreCall and L and L.SellPrice then P.AddLinePreCall(L.SellPrice, OnSellPrice) end
    for name in pairs(ITEM_TIPS) do
        local tt = _G[name]
        if tt then tt:HookScript("OnTooltipCleared", OnTooltipCleared) end
    end

    local ev = CreateFrame("Frame")
    ev:RegisterEvent("INSPECT_READY")
    ev:RegisterEvent("MODIFIER_STATE_CHANGED")
    ev:SetScript("OnEvent", function(_, event, arg)
        if not Active() then return end
        if event == "INSPECT_READY" then
            OnInspectReady(arg)
        elseif GameTooltip:IsShown() and not GameTooltip:IsForbidden() and GameTooltip:GetOwner() == UIParent
                and UnitExists("mouseover") and not InCombatLockdown() and not SecretIdentity("mouseover") then
            -- Shift and Ctrl change what a unit tooltip shows.
            if GameTooltip.RefreshData then pcall(GameTooltip.RefreshData, GameTooltip) end
        end
    end)
end

-- ============================================================================
-- ElvUI's extras, copied once per profile
-- ============================================================================

function TT.SeedExtras()
    local s = BH.settings
    if not s or s.ttExtrasSeededFromElvUI then return end
    local E = SH.Elv()
    local db = E and E.db and E.db.tooltip
    if type(db) ~= "table" then return end
    s.ttExtrasSeededFromElvUI = true
    local function Bool(v, key) if v ~= nil then s[key] = v and true or false end end
    Bool(db.inspectDataEnable, "ttItemLevel")
    if db.mythicDataEnable == false or db.dungeonScore == false then s.ttMythic = false end
    Bool(db.mythicBestRun, "ttMythicBest")
    Bool(db.dungeonScoreColor, "ttMythicColor")
    Bool(db.showMount, "ttMount")
    Bool(db.itemQuality, "ttQuality")
    local m = db.modifierID
    if m == "SHOW" or m == "HIDE" or m == "SHIFT" or m == "CTRL" or m == "ALT" then s.ttIDs = m end
    local c = db.itemCount
    if type(c) == "table" then
        Bool(c.bags, "ttCountBags")
        Bool(c.bank, "ttCountBank")
        Bool(c.stack, "ttCountStack")
    end
    if db.moneyLines then s.ttSellPrice = db.moneyHide and "HIDE" or "TEXT" end
    BH:SaveSettings()
end
