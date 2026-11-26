-- ItemBars/ItemBars.lua
-- Item Bars: up to five bars of item buttons that fill themselves from your
-- bags, quest log and equipped gear (the replacement for WindTools' Extra
-- Items Bar, which the user ran three of). Each bar takes a set of GROUPS --
-- quest items, potions, food, containers and so on -- in a fixed order and
-- shows every matching item it finds, up to its button count.
--
-- Groups are decided from the item itself (class and subclass, the bag's
-- "has loot" flag, the quest log's special items), not from hand-kept item ID
-- lists, so a new expansion's potions land on the potion bar without an
-- update. WindTools' code and lists are restricted-source and nothing of
-- theirs is copied; on first run with WindTools loaded its bar SETTINGS
-- (positions, sizes, groups, its custom and hidden lists) are read once, so
-- the bars come up where the user's already are.
--
-- Secure rules: the buttons are SecureActionButtonTemplate (type "item"), so
-- which item a button holds, its size and the bar's layout can only change
-- out of combat. In combat a bag change only refreshes counts and cooldowns;
-- the rebuild waits for PLAYER_REGEN_ENABLED. The holder each bar is placed
-- by is a plain frame (Edit Mode drags it); the secure bar is parented to
-- UIParent and only anchored to it, so showing or hiding the holder is never
-- a protected call.
--
-- Ctrl-right-click a button to hide that item (it joins Hidden Items).

local addonName, ns = ...
local BH = ns.BH
local S = BH.Secrets

local IB = {}
ns.ItemBars = IB

local NUM_BARS = 5
local MAX_BUTTONS = 24

-- ============================================================================
-- Groups
-- ============================================================================

local GROUPS = {
    { key = "QUEST",    label = "Quest Items",
      tip = "Items your quests ask you to use (nearest quest first), and any other usable quest item in your bags." },
    { key = "EQUIP",    label = "Equipped Gear With a Use",
      tip = "Trinkets and other gear you are wearing that has a Use: effect." },
    { key = "OPENABLE", label = "Containers",
      tip = "Bags, caches, coffers and anything else in your bags you can open for loot." },
    { key = "HOLIDAY",  label = "Holiday Items", tip = "Usable items from the holiday events." },
    { key = "USABLE",   label = "Other Usable Items",
      tip = "Anything else in your bags with a Use: effect that isn't a consumable: banners, profession tools, "
        .. "delve items and the like. Hearthstones start hidden (Hidden Items, General tab)." },
    { key = "POTION",   label = "Potions", tip = "Combat, healing and utility potions." },
    { key = "FLASK",    label = "Flasks, Phials and Elixirs" },
    { key = "VANTUS",   label = "Vantus Runes" },
    { key = "OTHER",    label = "Other Consumables",
      tip = "Consumables that are none of the others: drums, scrolls, toys-in-a-bag and other utility items." },
    { key = "FOOD",     label = "Food and Drink" },
    { key = "RUNE",     label = "Augment Runes" },
    { key = "ENHANCE",  label = "Weapon Oils and Stones" },
    { key = "BANDAGE",  label = "Bandages" },
    { key = "CUSTOM",   label = "Extra Items",
      tip = "The items listed under Extra Items on the General tab, in that order." },
}

-- What each bar holds on a fresh profile: the user's three WindTools bars.
local DEFAULT_GROUPS = {
    [1] = { QUEST = true, EQUIP = true, OPENABLE = true, HOLIDAY = true, USABLE = true },
    [2] = { POTION = true, FLASK = true, VANTUS = true, OTHER = true },
    [3] = { FOOD = true, RUNE = true, ENHANCE = true, BANDAGE = BH.IS_FOREVER or nil, CUSTOM = true },
}

-- Hearthstones have a Use: and would sit on the Other Usable bar forever.
local DEFAULT_HIDDEN = "6948, 140192, 110560"

local function GroupKey(n, group) return "ib" .. n .. "G_" .. group end

-- Classes and subclasses (Enum.ItemClass / Enum.ItemConsumableSubclass).
local CLASS_CONSUMABLE, CLASS_WEAPON, CLASS_ARMOR, CLASS_RECIPE = 0, 2, 4, 9
local CLASS_QUEST, CLASS_MISC, CLASS_BATTLEPET, CLASS_PROFESSION = 12, 15, 17, 19
local CONSUMABLE_GROUP = {
    [1] = "POTION", [2] = "FLASK", [3] = "FLASK", [5] = "FOOD",
    [6] = "ENHANCE", [7] = "BANDAGE", [9] = "VANTUS",
}
local MISC_HOLIDAY, MISC_PET, MISC_MOUNT = 3, 2, 5

local runeSet
local function RuneSet()
    if runeSet then return runeSet end
    runeSet = {}
    local list = BH.defaults and BH.defaults.consumables and BH.defaults.consumables.augmentRune
    for _, id in ipairs(list or {}) do runeSet[id] = true end
    return runeSet
end

local pendingData = false   -- an item's data was not cached yet; rescan when it arrives

local function HasUse(itemID)
    local name = C_Item.GetItemSpell(itemID)
    if name then return true end
    if C_Item.IsItemDataCachedByID and not C_Item.IsItemDataCachedByID(itemID) then
        pendingData = true
        if C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(itemID) end
    end
    return false
end

--- The one group a bag item belongs to, or nil.
local function Classify(itemID, hasLoot, isQuest)
    if hasLoot then return "OPENABLE" end
    if RuneSet()[itemID] then return "RUNE" end
    local _, _, _, _, _, classID, subID = C_Item.GetItemInfoInstant(itemID)
    if not classID then return nil end
    local group
    if isQuest or classID == CLASS_QUEST then
        group = "QUEST"
    elseif classID == CLASS_CONSUMABLE then
        group = CONSUMABLE_GROUP[subID] or "OTHER"
    elseif classID == CLASS_MISC and subID == MISC_HOLIDAY then
        group = "HOLIDAY"
    elseif classID == CLASS_WEAPON or classID == CLASS_ARMOR or classID == CLASS_RECIPE
        or classID == CLASS_BATTLEPET or classID == CLASS_PROFESSION
        or (classID == CLASS_MISC and (subID == MISC_PET or subID == MISC_MOUNT)) then
        return nil
    else
        group = "USABLE"
    end
    if not HasUse(itemID) then return nil end
    return group
end

-- ============================================================================
-- Lists from the settings
-- ============================================================================

local function ParseIDs(text)
    local list, set = {}, {}
    for id in tostring(text or ""):gmatch("%d+") do
        id = tonumber(id)
        if id and not set[id] then
            set[id] = true
            list[#list + 1] = id
        end
    end
    return list, set
end

local function HiddenSet()
    local _, set = ParseIDs(BH.settings and BH.settings.ibHidden)
    return set
end

-- ============================================================================
-- Scanning: what each group holds right now
-- ============================================================================

local pool = {}   -- group -> { entry, ... }; entry = { itemID = } or { slot = }

local function Scan()
    pendingData = false
    for _, g in ipairs(GROUPS) do pool[g.key] = {} end
    local hidden = HiddenSet()
    local seen = {}

    -- Quest log items first, nearest quest first.
    local quests = {}
    if C_QuestLog and C_QuestLog.GetNumQuestLogEntries and GetQuestLogSpecialItemInfo then
        for i = 1, C_QuestLog.GetNumQuestLogEntries() do
            local link = GetQuestLogSpecialItemInfo(i)
            local itemID = link and C_Item.GetItemInfoInstant(link)
            if itemID and not seen[itemID] and not hidden[itemID] then
                seen[itemID] = true
                local questID = C_QuestLog.GetQuestIDForLogIndex and C_QuestLog.GetQuestIDForLogIndex(i)
                local dist = questID and C_QuestLog.GetDistanceSqToQuest and C_QuestLog.GetDistanceSqToQuest(questID)
                quests[#quests + 1] = { itemID = itemID, dist = S.SafeNumber(dist, 1e9) or 1e9 }
            end
        end
    end
    table.sort(quests, function(a, b) return a.dist < b.dist end)
    for _, q in ipairs(quests) do table.insert(pool.QUEST, { itemID = q.itemID }) end

    -- Bags. Newest items (highest IDs) first within a group.
    local found = {}
    local lastBag = _G.NUM_TOTAL_EQUIPPED_BAG_SLOTS or _G.NUM_BAG_SLOTS or 4
    for bag = 0, lastBag do
        for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            local itemID = info and info.itemID
            if itemID and not seen[itemID] and not hidden[itemID] then
                seen[itemID] = true
                local isQuest = false
                if C_Container.GetContainerItemQuestInfo then
                    local q = C_Container.GetContainerItemQuestInfo(bag, slot)
                    isQuest = q and (q.isQuestItem or q.questID) and true or false
                end
                local group = Classify(itemID, info.hasLoot, isQuest)
                if group then found[#found + 1] = { itemID = itemID, group = group } end
            end
        end
    end
    table.sort(found, function(a, b) return a.itemID > b.itemID end)
    for _, f in ipairs(found) do table.insert(pool[f.group], { itemID = f.itemID }) end

    -- Equipped gear with a Use:.
    for slot = 1, 18 do
        local itemID = GetInventoryItemID("player", slot)
        if itemID and not hidden[itemID] and HasUse(itemID) then
            table.insert(pool.EQUIP, { slot = slot, itemID = itemID })
        end
    end

    -- Extra Items, in the order listed; only while you carry one.
    for _, itemID in ipairs((ParseIDs(BH.settings and BH.settings.ibCustom))) do
        if not hidden[itemID] and (C_Item.GetItemCount(itemID) or 0) > 0 then
            table.insert(pool.CUSTOM, { itemID = itemID })
        end
    end
end

-- ============================================================================
-- Settings
-- ============================================================================

local function Apply() if IB.Apply then IB.Apply() end end
local function BarOn(n) return function(s) return s["ib" .. n .. "Enabled"] end end

local OUTLINES = {
    { text = "None",          value = "NONE" },
    { text = "Outline",       value = "OUTLINE" },
    { text = "Thick outline", value = "THICKOUTLINE" },
}
local GROW = {
    { text = "Top left (fill right, then down)",     value = "TOPLEFT" },
    { text = "Top right (fill left, then down)",     value = "TOPRIGHT" },
    { text = "Bottom left (fill right, then up)",    value = "BOTTOMLEFT" },
    { text = "Bottom right (fill left, then up)",    value = "BOTTOMRIGHT" },
}

local pages = {
    { key = "general", label = "General", rows = {
        { key = "ibEnabled", type = "check", default = false,
          label = "Show Item Bars",
          tip = "Bars of item buttons that fill themselves from your bags: quest items, potions, food and "
            .. "so on. Each bar's tab says which groups it shows. Ctrl-right-click a button to hide that item.\n\n"
            .. "If WindTools' Extra Items Bar is still on, turn it off in WindTools (Item > Extra Items Bar) "
            .. "so the two don't sit on top of each other." },
        { key = "ibTooltip", type = "check", default = true,
          label = "Tooltips", tip = "Hovering a button shows the item's tooltip." },
        { key = "ibQuality", type = "check", default = true,
          label = "Crafted Quality", tip = "The crafted-quality pip in the corner of crafted items." },
        { type = "header", label = "COUNT TEXT" },
        { key = "ibFont", type = "dropdown", default = "__default",
          items = function() return BH:BuildFontDropdownItems() end,
          label = "Font", tip = "Font of the item counts." },
        { key = "ibCountSize", type = "slider", default = 12, min = 6, max = 24, step = 1,
          label = "Font Size", tip = "Size of the item counts." },
        { key = "ibCountOutline", type = "dropdown", default = "OUTLINE", items = OUTLINES,
          label = "Font Outline", tip = "An outline round the numbers." },
        { type = "header", label = "ITEMS" },
        { key = "ibCustom", type = "editbox", default = "",
          label = "Extra Items",
          tip = "Item IDs for the Extra Items group, separated by commas, in the order you want them. An item "
            .. "only shows while you carry one." },
        { key = "ibHidden", type = "editbox", default = DEFAULT_HIDDEN,
          label = "Hidden Items",
          tip = "Item IDs that never show on any bar, separated by commas. Ctrl-right-clicking a button adds "
            .. "its item here." },
    } },
}

for n = 1, NUM_BARS do
    local on = BarOn(n)
    local p = "ib" .. n
    local rows = {
        { key = p .. "Enabled", type = "check", default = n <= 3,
          label = "Show Bar " .. n, tip = "Show this bar. It only appears while it has something to show." },
        { type = "header", label = "GROUPS" },
        { type = "text", label = "Filled in this order, until the bar is full." },
    }
    local defaults = DEFAULT_GROUPS[n] or {}
    for _, g in ipairs(GROUPS) do
        rows[#rows + 1] = { key = GroupKey(n, g.key), type = "check", default = defaults[g.key] and true or false,
            label = g.label, tip = g.tip, when = on }
    end
    local layout = {
        { type = "header", label = "LAYOUT" },
        { key = p .. "Buttons", type = "slider", default = 12, min = 1, max = MAX_BUTTONS, step = 1,
          label = "Buttons", tip = "The most buttons the bar shows.", when = on },
        { key = p .. "PerRow", type = "slider", default = 12, min = 1, max = MAX_BUTTONS, step = 1,
          label = "Buttons per Row", tip = "Buttons in a row before the next row starts.", when = on },
        { key = p .. "Width", type = "slider", default = 35, min = 16, max = 80, step = 1,
          label = "Button Width", tip = "Width of each button.", when = on },
        { key = p .. "Height", type = "slider", default = 30, min = 16, max = 80, step = 1,
          label = "Button Height", tip = "Height of each button. The icon is cropped to fit.", when = on },
        { key = p .. "Spacing", type = "slider", default = 3, min = 0, max = 20, step = 1,
          label = "Spacing", tip = "Space between buttons.", when = on },
        { key = p .. "Grow", type = "dropdown", default = "TOPRIGHT", items = GROW,
          label = "Grow From",
          tip = "The corner the first button sits in. The bar's position is kept at this corner, so it grows "
            .. "away from it as items come and go.", when = on },
        { type = "header", label = "BACKGROUND" },
        { key = p .. "Backdrop", type = "check", default = true,
          label = "Background", tip = "A dark background behind the buttons.", when = on },
        { key = p .. "Padding", type = "slider", default = 3, min = 0, max = 20, step = 1,
          label = "Padding", tip = "Space between the background's edge and the buttons.", when = on },
        { type = "header", label = "VISIBILITY" },
        { key = p .. "Mouseover", type = "check", default = false,
          label = "Show on Mouseover", tip = "The bar fades out until you point at it.", when = on },
        { key = p .. "FadeAlpha", type = "slider", default = 0, min = 0, max = 100, step = 5,
          label = "Faded Opacity", tip = "How visible the bar stays while faded, in percent.",
          when = function(s) return on(s) and s[p .. "Mouseover"] end },
        { key = p .. "Visibility", type = "editbox", default = "[petbattle]hide;show",
          label = "Visibility Condition",
          tip = "A macro condition deciding when the bar shows, the same as for action bars. The default "
            .. "hides it in pet battles. Example: [combat]show;hide", when = on },
    }
    for _, r in ipairs(layout) do rows[#rows + 1] = r end
    pages[#pages + 1] = { key = "bar" .. n, label = "Bar " .. n, rows = rows }
end

IB.SETTINGS = ns.Settings.Describe({ master = "ibEnabled", apply = Apply, pages = pages })

function BH:BuildItemBarsTab(parent)
    ns.Settings.Build(IB.SETTINGS, parent)
end

-- ============================================================================
-- Buttons
-- ============================================================================

local bars = {}            -- n -> { holder, bar, buttons }
local inCombatDirty = false

local function ResolveFont(name)
    if name and name ~= "__default" then
        local lsm = LibStub and LibStub("LibSharedMedia-3.0", true)
        local path = lsm and lsm:Fetch("font", name, true)
        if path then return path end
    end
    return STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"
end

local function HideItem(self)
    local itemID = self.itemID
    if not itemID or not BH.settings then return end
    local _, set = ParseIDs(BH.settings.ibHidden)
    if set[itemID] then return end
    local text = BH.settings.ibHidden or ""
    BH.settings.ibHidden = (text:match("%S") and (text .. ", ") or "") .. itemID
    BH:SaveSettings()
    local name = C_Item.GetItemNameByID(itemID) or ("item " .. itemID)
    print("|cff33cc99Squizzumables:|r " .. name .. " hidden from the item bars (General tab, Hidden Items).")
    if ns.Rows and ns.Rows.RefreshAll then ns.Rows.RefreshAll() end
    IB.Apply()
end

local function ButtonEnter(self)
    if not (BH.settings and BH.settings.ibTooltip) or not self.itemID then return end
    GameTooltip_SetDefaultAnchor(GameTooltip, self)
    if self.slot then
        GameTooltip:SetInventoryItem("player", self.slot)
    else
        GameTooltip:SetItemByID(self.itemID)
    end
    GameTooltip:AddLine("Ctrl-right-click: hide this item", 0.6, 0.6, 0.6)
    GameTooltip:Show()
end

local function ButtonLeave(self)
    if GameTooltip:IsOwned(self) then GameTooltip:Hide() end
end

local function CreateButton(bar, n, i)
    local b = CreateFrame("Button", "SquizzumablesItemBar" .. n .. "Button" .. i, bar,
        "SecureActionButtonTemplate, BackdropTemplate")
    b:RegisterForClicks(ns.SQ_GetClickEdge and ns.SQ_GetClickEdge() or "AnyUp")
    b:SetAttribute("type", "item")
    -- Ctrl-right-click: a handler on the button itself (SecureActionButton
    -- runs rawget(self, type) for an unknown type), so nothing is used.
    b:SetAttribute("ctrl-type2", "sqhide")
    b.sqhide = HideItem
    b:SetBackdrop({ edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
    b:SetBackdropBorderColor(0, 0, 0, 1)

    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetPoint("TOPLEFT", 1, -1)
    b.icon:SetPoint("BOTTOMRIGHT", -1, 1)

    b.cooldown = CreateFrame("Cooldown", nil, b, "CooldownFrameTemplate")
    b.cooldown:SetAllPoints(b.icon)
    b.cooldown:SetDrawEdge(false)

    local over = CreateFrame("Frame", nil, b)
    over:SetAllPoints()
    over:SetFrameLevel(b.cooldown:GetFrameLevel() + 2)
    b.count = over:CreateFontString(nil, "OVERLAY")
    b.count:SetPoint("BOTTOMRIGHT", -1, 2)
    b.quality = over:CreateTexture(nil, "OVERLAY")
    b.quality:SetPoint("TOPLEFT", -2, 2)

    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints(b.icon)
    hl:SetColorTexture(1, 1, 1, 0.2)

    b:SetScript("OnEnter", ButtonEnter)
    b:SetScript("OnLeave", ButtonLeave)
    b:Hide()
    return b
end

--- Counts, cooldown and greying: plain regions, so this runs in combat too.
local function RefreshButton(b)
    local itemID = b.itemID
    if not itemID then return end
    if b.slot then
        b.count:SetText("")
        local start, duration, enable = GetInventoryItemCooldown("player", b.slot)
        CooldownFrame_Set(b.cooldown, S.SafeNumber(start, 0), S.SafeNumber(duration, 0), S.SafeNumber(enable, 1) ~= 0)
        b.icon:SetDesaturated(false)
        return
    end
    local count = C_Item.GetItemCount(itemID, false, true) or 0
    b.count:SetText(count > 1 and count or "")
    local start, duration, enable = C_Container.GetItemCooldown(itemID)
    local on = not (enable == false or enable == 0)
    CooldownFrame_Set(b.cooldown, S.SafeNumber(start, 0), S.SafeNumber(duration, 0), on)
    local usable = C_Item.IsUsableItem(itemID)
    b.icon:SetDesaturated(count == 0 or not usable)
end

local function RefreshAllButtons()
    for _, rec in pairs(bars) do
        for _, b in ipairs(rec.buttons) do
            if b:IsShown() then RefreshButton(b) end
        end
    end
end

-- Crops the square icon to the button's shape, like ElvUI's.
local function CropIcon(tex, w, h)
    local inset = 0.08
    local range = 1 - 2 * inset
    if w >= h then
        local cut = (range - range * h / w) / 2
        tex:SetTexCoord(inset, 1 - inset, inset + cut, 1 - inset - cut)
    else
        local cut = (range - range * w / h) / 2
        tex:SetTexCoord(inset + cut, 1 - inset - cut, inset, 1 - inset)
    end
end

local function StyleButton(b, s, w, h)
    b:SetSize(w, h)
    CropIcon(b.icon, w, h)
    local outline = s.ibCountOutline or "OUTLINE"
    b.count:SetFont(ResolveFont(s.ibFont), s.ibCountSize or 12, outline == "NONE" and "" or outline)
    b.quality:SetSize(math.max(10, math.floor(h * 0.5)), math.max(10, math.floor(h * 0.5)))
end

local function SetButtonItem(b, entry, s)
    b.itemID, b.slot = entry.itemID, entry.slot
    b:SetAttribute("item", entry.slot and tostring(entry.slot) or ("item:" .. entry.itemID))
    local icon = entry.slot and GetInventoryItemTexture("player", entry.slot) or C_Item.GetItemIconByID(entry.itemID)
    b.icon:SetTexture(icon or 134400)
    b.quality:Hide()
    if s.ibQuality ~= false and C_TradeSkillUI and C_TradeSkillUI.GetItemCraftedQualityInfo then
        local link = entry.slot and GetInventoryItemLink("player", entry.slot) or entry.itemID
        local ok, info = pcall(C_TradeSkillUI.GetItemCraftedQualityInfo, link)
        if ok and type(info) == "table" and info.iconInventory then
            b.quality:SetAtlas(info.iconInventory, false)
            b.quality:Show()
        end
    end
end

-- ============================================================================
-- Bars
-- ============================================================================

local function DefaultPosition(n)
    return { point = "BOTTOM", relPoint = "BOTTOM", x = 0, y = 200 + (n - 1) * 40 }
end

local function SavePosition(n)
    local rec = bars[n]
    local s = BH.settings
    if not (rec and s) then return end
    local f = rec.holder
    local l, r, t, b = f:GetLeft(), f:GetRight(), f:GetTop(), f:GetBottom()
    if not l then return end
    local scale = f:GetEffectiveScale() / UIParent:GetEffectiveScale()
    l, r, t, b = l * scale, r * scale, t * scale, b * scale
    local point = s["ib" .. n .. "Grow"] or "TOPRIGHT"
    local x = point:find("LEFT") and l or (r - UIParent:GetWidth())
    local y = point:find("TOP") and (t - UIParent:GetHeight()) or b
    s["ib" .. n .. "Position"] = { point = point, relPoint = point, x = math.floor(x + 0.5), y = math.floor(y + 0.5) }
    BH:SaveSettings()
end

local function CreateBar(n)
    if bars[n] then return bars[n] end
    local holder = CreateFrame("Frame", "SquizzumablesItemBar" .. n .. "Holder", UIParent)
    holder:SetMovable(true)
    holder:SetClampedToScreen(true)
    holder:RegisterForDrag("LeftButton")
    holder:EnableMouse(false)
    holder:SetScript("OnDragStart", function(self)
        if InCombatLockdown() or not BH.unlockMode then return end
        BH:GridStartMoving(self)
    end)
    holder:SetScript("OnDragStop", function(self)
        BH:GridStopMoving(self)
        SavePosition(n)
        IB.Apply()
    end)

    local bar = CreateFrame("Frame", "SquizzumablesItemBar" .. n, UIParent, "SecureHandlerStateTemplate, BackdropTemplate")
    bar:SetFrameStrata("LOW")
    bar:Hide()

    local rec = { holder = holder, bar = bar, buttons = {} }
    for i = 1, MAX_BUTTONS do rec.buttons[i] = CreateButton(bar, n, i) end
    bars[n] = rec
    BH["itemBar" .. n] = holder
    return rec
end

local function SetDriver(rec, cond)
    if rec.driver == cond then return end
    if rec.driver then UnregisterStateDriver(rec.bar, "visibility") end
    rec.driver = cond
    if cond then RegisterStateDriver(rec.bar, "visibility", cond) end
end

local function HideBar(rec)
    SetDriver(rec, nil)
    rec.bar:Hide()
    for _, b in ipairs(rec.buttons) do b:Hide() end
end

local function FillEntries(n, s)
    local limit = math.max(1, math.min(MAX_BUTTONS, s["ib" .. n .. "Buttons"] or 12))
    local out, used = {}, {}
    for _, g in ipairs(GROUPS) do
        if #out >= limit then break end
        if s[GroupKey(n, g.key)] then
            for _, entry in ipairs(pool[g.key] or {}) do
                if #out >= limit then break end
                local id = entry.slot and ("slot" .. entry.slot) or entry.itemID
                if not used[id] then
                    used[id] = true
                    out[#out + 1] = entry
                end
            end
        end
    end
    return out, limit
end

local function GridSize(count, perRow, w, h, sp, pad)
    local cols = math.min(count, perRow)
    local rows = math.ceil(count / perRow)
    return 2 * pad + cols * w + (cols - 1) * sp, 2 * pad + rows * h + (rows - 1) * sp
end

local function LayoutBar(n, s)
    local rec = CreateBar(n)
    local p = "ib" .. n
    local holder, bar = rec.holder, rec.bar
    if not (s.ibEnabled and s[p .. "Enabled"]) then
        holder:Hide()
        HideBar(rec)
        return
    end

    local w, h = s[p .. "Width"] or 35, s[p .. "Height"] or 30
    local sp, pad = s[p .. "Spacing"] or 3, s[p .. "Padding"] or 3
    local perRow = math.max(1, s[p .. "PerRow"] or 12)
    local grow = s[p .. "Grow"] or "TOPRIGHT"
    local entries, limit = FillEntries(n, s)

    -- The holder is the full-size grid: what Edit Mode drags.
    local pos = s[p .. "Position"] or DefaultPosition(n)
    holder:ClearAllPoints()
    holder:SetPoint(pos.point or "BOTTOM", UIParent, pos.relPoint or pos.point or "BOTTOM", pos.x or 0, pos.y or 0)
    holder:SetSize(GridSize(limit, perRow, w, h, sp, pad))
    holder:EnableMouse(BH.unlockMode and true or false)
    holder:Show()

    if BH.unlockMode or #entries == 0 then
        HideBar(rec)
        return
    end

    bar:ClearAllPoints()
    bar:SetPoint(grow, holder, grow, 0, 0)
    bar:SetSize(GridSize(#entries, perRow, w, h, sp, pad))
    if s[p .. "Backdrop"] ~= false then
        bar:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
        bar:SetBackdropColor(0.06, 0.06, 0.06, 0.8)
        bar:SetBackdropBorderColor(0, 0, 0, 1)
    else
        bar:SetBackdrop(nil)
    end

    local right = grow:find("RIGHT") and -1 or 1
    local up = grow:find("BOTTOM") and 1 or -1
    for i, b in ipairs(rec.buttons) do
        local entry = entries[i]
        if entry then
            StyleButton(b, s, w, h)
            SetButtonItem(b, entry, s)
            local col, row = (i - 1) % perRow, math.floor((i - 1) / perRow)
            b:ClearAllPoints()
            b:SetPoint(grow, bar, grow, right * (pad + col * (w + sp)), up * (pad + row * (h + sp)))
            b:Show()
            RefreshButton(b)
        else
            b.itemID, b.slot = nil, nil
            b:Hide()
        end
    end

    local cond = s[p .. "Visibility"]
    if not cond or not cond:match("%S") then cond = "show" end
    SetDriver(rec, cond)
    rec.mouseover = s[p .. "Mouseover"] and true or false
    rec.fadeAlpha = (s[p .. "FadeAlpha"] or 0) / 100
    bar:SetAlpha(rec.mouseover and rec.fadeAlpha or 1)
end

function IB.Apply()
    local s = BH.settings
    if not s then return end
    if InCombatLockdown() then
        inCombatDirty = true
        RefreshAllButtons()
        return
    end
    inCombatDirty = false
    if s.ibEnabled then Scan() end
    for n = 1, NUM_BARS do
        if s.ibEnabled or bars[n] then LayoutBar(n, s) end
    end
end

-- Edit Mode's arrow-key nudge (MOVABLE_FRAMES in Squizzumables.lua).
function IB.Nudge(n, dx, dy)
    local s = BH.settings
    if not s then return end
    local key = "ib" .. n .. "Position"
    local pos = s[key] or DefaultPosition(n)
    s[key] = { point = pos.point, relPoint = pos.relPoint, x = (pos.x or 0) + dx, y = (pos.y or 0) + dy }
    BH:SaveSettings()
    IB.Apply()
end

-- Mouseover fading. Alpha is not protected, so this runs in combat.
local fader = CreateFrame("Frame")
local fadeElapsed = 0
fader:SetScript("OnUpdate", function(_, elapsed)
    fadeElapsed = fadeElapsed + elapsed
    if fadeElapsed < 0.05 then return end
    local step = fadeElapsed * 4
    fadeElapsed = 0
    for _, rec in pairs(bars) do
        if rec.mouseover and rec.bar:IsShown() then
            local target = rec.bar:IsMouseOver() and 1 or rec.fadeAlpha
            local a = rec.bar:GetAlpha()
            if a < target then a = math.min(target, a + step)
            elseif a > target then a = math.max(target, a - step) end
            rec.bar:SetAlpha(a)
        end
    end
end)

-- ============================================================================
-- Copying WindTools' Extra Items Bar settings, once per profile
-- ============================================================================

local WT_GROUP = {
    QUEST = "QUEST", EQUIP = "EQUIP", OPENABLE = "OPENABLE", HOLIDAY = "HOLIDAY", CUSTOM = "CUSTOM",
    BANNER = "USABLE", DELVE = "USABLE", UTILITY = "OTHER", MAGEFOOD = "FOOD",
}
local function MapWTGroup(token)
    if WT_GROUP[token] then return WT_GROUP[token] end
    if token:match("^SLOT:") then return "EQUIP" end
    if token:match("^PROF") then return "USABLE" end
    if token:match("^POTION") then return "POTION" end
    if token:match("^FLASK") or token:match("^ELIXIR") or token:match("^PHIAL") then return "FLASK" end
    if token:match("^VANTUS") then return "VANTUS" end
    if token:match("^FOOD") then return "FOOD" end
    if token:match("^RUNE") then return "RUNE" end
    if token:match("^BANDAGE") then return "BANDAGE" end
    return nil
end

local function SeedFromWindTools()
    local s = BH.settings
    if not s or s.ibSeededFromWT then return end
    if not C_AddOns.IsAddOnLoaded("ElvUI_WindTools") then return end
    local elv = _G["ElvUI"]
    local E = type(elv) == "table" and elv[1]
    local wt = E and E.db and E.db.WT and E.db.WT.item and E.db.WT.item.extraItemsBar
    if type(wt) ~= "table" then return end
    s.ibSeededFromWT = true

    local ids = {}
    for _, id in pairs(wt.customList or {}) do
        if tonumber(id) then ids[#ids + 1] = tostring(id) end
    end
    if #ids > 0 then s.ibCustom = table.concat(ids, ", ") end
    local hidden = {}
    for id, on in pairs(wt.blackList or {}) do
        if on and tonumber(id) then hidden[#hidden + 1] = tonumber(id) end
    end
    table.sort(hidden)
    local _, have = ParseIDs(s.ibHidden)
    for _, id in ipairs(hidden) do
        if not have[id] then s.ibHidden = (s.ibHidden ~= "" and (s.ibHidden .. ", ") or "") .. id end
    end

    for n = 1, NUM_BARS do
        local b = wt["bar" .. n]
        if type(b) == "table" then
            local p = "ib" .. n
            s[p .. "Enabled"] = (wt.enable ~= false and b.enable) and true or false
            if type(b.include) == "string" then
                for _, g in ipairs(GROUPS) do s[GroupKey(n, g.key)] = false end
                for token in b.include:gmatch("[^,%s]+") do
                    local g = MapWTGroup(token)
                    if g then s[GroupKey(n, g)] = true end
                end
            end
            if tonumber(b.numButtons) then s[p .. "Buttons"] = math.min(MAX_BUTTONS, tonumber(b.numButtons)) end
            if tonumber(b.buttonsPerRow) then s[p .. "PerRow"] = math.min(MAX_BUTTONS, tonumber(b.buttonsPerRow)) end
            if tonumber(b.buttonWidth) then s[p .. "Width"] = tonumber(b.buttonWidth) end
            if tonumber(b.buttonHeight) then s[p .. "Height"] = tonumber(b.buttonHeight) end
            if tonumber(b.spacing) then s[p .. "Spacing"] = tonumber(b.spacing) end
            if tonumber(b.backdropSpacing) then s[p .. "Padding"] = tonumber(b.backdropSpacing) end
            if b.backdrop ~= nil then s[p .. "Backdrop"] = b.backdrop and true or false end
            if type(b.anchor) == "string" then s[p .. "Grow"] = b.anchor end
            if b.mouseOver ~= nil then s[p .. "Mouseover"] = b.mouseOver and true or false end
            if tonumber(b.alphaMin) then s[p .. "FadeAlpha"] = math.floor(tonumber(b.alphaMin) * 100 + 0.5) end
            if type(b.visibility) == "string" then s[p .. "Visibility"] = b.visibility end
            if b.tooltip ~= nil and n == 1 then s.ibTooltip = b.tooltip and true or false end
            local cf = b.countFont
            if n == 1 and type(cf) == "table" then
                local lsm = LibStub and LibStub("LibSharedMedia-3.0", true)
                if cf.name and lsm and lsm:IsValid("font", cf.name) then s.ibFont = cf.name end
                if tonumber(cf.size) then s.ibCountSize = tonumber(cf.size) end
            end
            -- "BOTTOMRIGHT,UIParent,BOTTOMRIGHT,-392,229"
            local mover = E.db.movers and E.db.movers["WTExtraItemsBar" .. n .. "Mover"]
            if type(mover) == "string" then
                local point, _, relPoint, x, y = strsplit(",", mover)
                if point and relPoint and tonumber(x) and tonumber(y) then
                    s[p .. "Position"] = { point = point, relPoint = relPoint, x = tonumber(x), y = tonumber(y) }
                end
            end
        end
    end
    BH:SaveSettings()
end

-- After a profile switch, reset or Edit Mode change too.
function BH:ApplyItemBars()
    SeedFromWindTools()
    IB.Apply()
end

-- ============================================================================
-- Events
-- ============================================================================

local rebuildQueued = false
local function QueueRebuild()
    if rebuildQueued then return end
    rebuildQueued = true
    C_Timer.After(0.2, function()
        rebuildQueued = false
        IB.Apply()
    end)
end

local REBUILD = {
    BAG_UPDATE_DELAYED = true, QUEST_LOG_UPDATE = true, QUEST_ACCEPTED = true, QUEST_REMOVED = true,
    PLAYER_EQUIPMENT_CHANGED = true, ZONE_CHANGED_NEW_AREA = true, PLAYER_ENTERING_WORLD = true,
}

local ev = CreateFrame("Frame")
ev:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        BH:ApplyItemBars()
        return
    end
    local s = BH.settings
    if not (s and s.ibEnabled) then return end
    if event == "PLAYER_REGEN_ENABLED" then
        if inCombatDirty then QueueRebuild() end
    elseif event == "GET_ITEM_INFO_RECEIVED" or event == "ITEM_DATA_LOAD_RESULT" then
        if pendingData then QueueRebuild() end
    elseif REBUILD[event] then
        QueueRebuild()
    else
        RefreshAllButtons()
    end
end)
ev:RegisterEvent("PLAYER_LOGIN")
for _, e in ipairs({
    "PLAYER_REGEN_ENABLED", "GET_ITEM_INFO_RECEIVED", "ITEM_DATA_LOAD_RESULT",
    "BAG_UPDATE_DELAYED", "QUEST_LOG_UPDATE", "QUEST_ACCEPTED", "QUEST_REMOVED",
    "PLAYER_EQUIPMENT_CHANGED", "ZONE_CHANGED_NEW_AREA", "PLAYER_ENTERING_WORLD",
    "BAG_UPDATE_COOLDOWN", "SPELL_UPDATE_COOLDOWN", "SPELL_UPDATE_USABLE",
}) do
    pcall(ev.RegisterEvent, ev, e)
end

IB.NUM_BARS = NUM_BARS
