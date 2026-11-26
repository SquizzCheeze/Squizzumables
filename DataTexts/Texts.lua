-- DataTexts/Texts.lua
-- The six texts ElvUI puts under its chat panels: Talent/Loot Specialization,
-- Durability, Currencies (left) and System, Time, Gold (right). Written from
-- what ElvUI's show, not from its code (its licence forbids that).

local addonName, ns = ...
local BH = ns.BH
local DT = ns.DataTexts

local function Hex(r, g, b) return DT.Hex(r, g, b) end
local WHITE = { 1, 1, 1 }
local GREY = { 0.7, 0.7, 0.7 }

local function Icon(fileID, size)
    if not fileID then return "" end
    return "|T" .. fileID .. ":" .. (size or 14) .. ":" .. (size or 14) .. ":0:0:64:64:5:59:5:59|t"
end

-- ============================================================================
-- Talent / Loot Specialization
-- ============================================================================

local SI = C_SpecializationInfo

local function SpecIndex() return SI and SI.GetSpecialization and SI.GetSpecialization() end

local function SpecInfo(index)
    if not (index and SI and SI.GetSpecializationInfo) then return nil end
    local id, name, _, icon = SI.GetSpecializationInfo(index)
    return id, name, icon
end

local function LootSpec()
    local id = GetLootSpecialization and GetLootSpecialization() or 0
    if id == 0 then return nil end
    local _, name, _, icon = GetSpecializationInfoByID(id)
    return id, name, icon
end

local function NumSpecs()
    return (GetNumSpecializations and GetNumSpecializations()) or 0
end

DT.Register("Talent/Loot Specialization", {
    label = "Talent/Loot Specialization",
    events = { "PLAYER_ENTERING_WORLD", "PLAYER_SPECIALIZATION_CHANGED", "PLAYER_LOOT_SPEC_UPDATED",
        "ACTIVE_TALENT_GROUP_CHANGED" },
    text = function()
        local _, name, icon = SpecInfo(SpecIndex())
        if not name then return DT.Format("Spec", "-") end
        local out = Icon(icon) .. " " .. DT.ValueHex() .. name .. "|r"
        local _, _, lootIcon = LootSpec()
        if lootIcon then out = out .. "  " .. Icon(lootIcon) end
        return out
    end,
    onEnter = function(_, tt)
        local _, name = SpecInfo(SpecIndex())
        tt:AddLine("Specialization", 1, 1, 1)
        tt:AddDoubleLine("Active", name or "-", 1, 0.82, 0, 1, 1, 1)
        local _, lootName = LootSpec()
        tt:AddDoubleLine("Loot", lootName or ("Current (" .. (name or "-") .. ")"), 1, 0.82, 0, 1, 1, 1)
        tt:AddLine(" ")
        tt:AddLine("Click: talents", 0.7, 0.7, 0.7)
        tt:AddLine("Right-click: change spec or loot spec", 0.7, 0.7, 0.7)
    end,
    onClick = function(slot, button)
        if button == "RightButton" then
            MenuUtil.CreateContextMenu(slot, function(_, root)
                local current = SpecIndex()
                root:CreateTitle("Specialization")
                for i = 1, NumSpecs() do
                    local _, name, icon = SpecInfo(i)
                    if name then
                        root:CreateRadio(Icon(icon) .. " " .. name, function() return i == current end, function()
                            if InCombatLockdown() then return end
                            if i ~= current and SI.SetSpecialization then SI.SetSpecialization(i) end
                        end)
                    end
                end
                if SetLootSpecialization then
                    root:CreateDivider()
                    root:CreateTitle("Loot Specialization")
                    local loot = GetLootSpecialization() or 0
                    local _, curName = SpecInfo(current)
                    root:CreateRadio("Current (" .. (curName or "-") .. ")", function() return loot == 0 end,
                        function() SetLootSpecialization(0) end)
                    for i = 1, NumSpecs() do
                        local id, name, icon = SpecInfo(i)
                        if id then
                            root:CreateRadio(Icon(icon) .. " " .. name, function() return loot == id end,
                                function() SetLootSpecialization(id) end)
                        end
                    end
                end
            end)
            return
        end
        if InCombatLockdown() then return end
        if PlayerSpellsUtil and PlayerSpellsUtil.ToggleClassTalentOrSpecFrame then
            PlayerSpellsUtil.ToggleClassTalentOrSpecFrame()
        elseif ToggleTalentFrame then
            ToggleTalentFrame()
        end
    end,
})

-- ============================================================================
-- Durability
-- ============================================================================

local DURABILITY_SLOTS = { 1, 3, 5, 6, 7, 8, 9, 10, 16, 17, 18 }   -- the slots that wear

local function DurabilityColor(pct)
    if pct >= 75 then return 0.1, 1, 0.1 end
    if pct >= 35 then return 1, 0.82, 0 end
    return 1, 0.1, 0.1
end

local function Lowest()
    local low
    for _, slotID in ipairs(DURABILITY_SLOTS) do
        local cur, max = GetInventoryItemDurability(slotID)
        if cur and max and max > 0 then
            local pct = cur / max * 100
            if not low or pct < low then low = pct end
        end
    end
    return low
end

DT.Register("Durability", {
    label = "Durability",
    events = { "PLAYER_ENTERING_WORLD", "UPDATE_INVENTORY_DURABILITY", "PLAYER_EQUIPMENT_CHANGED", "MERCHANT_CLOSED" },
    text = function()
        local low = Lowest()
        if not low then return DT.Labelled("dtDurabilityLabel", "Durability", "-") end
        local label = BH.settings and BH.settings.dtDurabilityLabel
        if label == nil then label = "Durability" end
        local value = Hex(DurabilityColor(low)) .. math.floor(low + 0.5) .. "%|r"
        return label == "" and value or (label .. ": " .. value)
    end,
    onEnter = function(_, tt)
        tt:AddLine("Durability", 1, 1, 1)
        for _, slotID in ipairs(DURABILITY_SLOTS) do
            local cur, max = GetInventoryItemDurability(slotID)
            if cur and max and max > 0 then
                local pct = cur / max * 100
                local link = GetInventoryItemLink("player", slotID)
                local r, g, b = DurabilityColor(pct)
                tt:AddDoubleLine(link or "-", math.floor(pct + 0.5) .. "%", 1, 1, 1, r, g, b)
            end
        end
        tt:AddLine(" ")
        tt:AddLine("Click: character window", 0.7, 0.7, 0.7)
    end,
    onClick = function()
        if InCombatLockdown() then return end
        ToggleCharacter("PaperDollFrame")
    end,
})

-- ============================================================================
-- Currencies (the ones you track in the currency window, else gold)
-- ============================================================================

local function Tracked()
    local list = {}
    local CI = C_CurrencyInfo
    if not (CI and CI.GetBackpackCurrencyInfo) then return list end
    for i = 1, 10 do
        local info = CI.GetBackpackCurrencyInfo(i)
        if not info then break end
        list[#list + 1] = info
    end
    return list
end

local function GoldText(copper, short)
    copper = copper or 0
    if short then
        local g = math.floor(copper / 10000)
        return BreakUpLargeNumbers(g) .. "|TInterface\\MoneyFrame\\UI-GoldIcon:12:12:2:0|t"
    end
    return GetMoneyString(copper, true)
end

DT.Register("Currencies", {
    label = "Currencies",
    events = { "PLAYER_ENTERING_WORLD", "CURRENCY_DISPLAY_UPDATE", "PLAYER_MONEY" },
    text = function()
        local list = Tracked()
        if #list == 0 then return GoldText(GetMoney(), true) end
        local parts = {}
        for _, info in ipairs(list) do
            parts[#parts + 1] = Icon(info.iconFileID, 12) .. " " .. DT.ValueHex() .. BreakUpLargeNumbers(info.quantity) .. "|r"
        end
        return table.concat(parts, "  ")
    end,
    onEnter = function(_, tt)
        tt:AddLine("Currencies", 1, 1, 1)
        tt:AddDoubleLine("Gold", GoldText(GetMoney()), 1, 0.82, 0, 1, 1, 1)
        for _, info in ipairs(Tracked()) do
            tt:AddDoubleLine(Icon(info.iconFileID) .. " " .. info.name, BreakUpLargeNumbers(info.quantity), 1, 1, 1, 1, 1, 1)
        end
        tt:AddLine(" ")
        tt:AddLine("Track more in the currency window (click)", 0.7, 0.7, 0.7)
    end,
    onClick = function()
        if InCombatLockdown() then return end
        ToggleCharacter("TokenFrame")
    end,
})

-- ============================================================================
-- System: frame rate and latency, add-on memory on hover
-- ============================================================================

local function LatencyColor(ms)
    if ms < 100 then return 0.1, 1, 0.1 end
    if ms < 250 then return 1, 0.82, 0 end
    return 1, 0.1, 0.1
end

local function FpsColor(fps)
    if fps >= 50 then return 0.1, 1, 0.1 end
    if fps >= 25 then return 1, 0.82, 0 end
    return 1, 0.1, 0.1
end

local function Memory(kb)
    if kb >= 1024 then return string.format("%.2f MB", kb / 1024) end
    return string.format("%.0f KB", kb)
end

DT.Register("System", {
    label = "System",
    interval = 1,
    text = function()
        local fps = math.floor((GetFramerate() or 0) + 0.5)
        local _, _, home, world = GetNetStats()
        local ms = math.max(home or 0, world or 0)
        return "FPS: " .. Hex(FpsColor(fps)) .. fps .. "|r  MS: " .. Hex(LatencyColor(ms)) .. ms .. "|r"
    end,
    onEnter = function(_, tt)
        local _, _, home, world = GetNetStats()
        tt:AddLine("System", 1, 1, 1)
        tt:AddDoubleLine("Home latency", (home or 0) .. " ms", 1, 0.82, 0, LatencyColor(home or 0))
        tt:AddDoubleLine("World latency", (world or 0) .. " ms", 1, 0.82, 0, LatencyColor(world or 0))
        UpdateAddOnMemoryUsage()
        local list, total = {}, 0
        for i = 1, C_AddOns.GetNumAddOns() do
            if C_AddOns.IsAddOnLoaded(i) then
                local kb = GetAddOnMemoryUsage(i) or 0
                total = total + kb
                list[#list + 1] = { (C_AddOns.GetAddOnInfo(i)), kb }
            end
        end
        table.sort(list, function(a, b) return a[2] > b[2] end)
        tt:AddDoubleLine("Add-on memory", Memory(total), 1, 0.82, 0, 1, 1, 1)
        tt:AddLine(" ")
        local shown = IsShiftKeyDown() and #list or math.min(10, #list)
        for i = 1, shown do tt:AddDoubleLine(list[i][1], Memory(list[i][2]), 1, 1, 1, GREY[1], GREY[2], GREY[3]) end
        if shown < #list then tt:AddLine("Hold Shift for all " .. #list, 0.7, 0.7, 0.7) end
        tt:AddLine("Click: free unused memory", 0.7, 0.7, 0.7)
    end,
    onClick = function()
        if InCombatLockdown() then return end
        collectgarbage("collect")
        DT.RefreshTooltip("System")
    end,
})

-- ============================================================================
-- Time: local time, realm time and lockouts
-- ============================================================================

local function Clock(h, m)
    local use24 = GetCVarBool and GetCVarBool("timeMgrUseMilitaryTime")
    if use24 then return string.format("%02d:%02d", h, m) end
    local suffix = h >= 12 and " PM" or " AM"
    h = h % 12
    if h == 0 then h = 12 end
    return string.format("%d:%02d", h, m) .. suffix
end

local function LocalClock()
    local t = date("*t")
    return Clock(t.hour, t.min)
end

local function RealmClock()
    local h, m = GetGameTime()
    return Clock(h, m)
end

local function UseLocal()
    return not (GetCVarBool and GetCVarBool("timeMgrUseLocalTime") == false)
end

local function Remaining(sec)
    local d, h, m = math.floor(sec / 86400), math.floor(sec % 86400 / 3600), math.floor(sec % 3600 / 60)
    if d > 0 then return d .. "d " .. h .. "h" end
    if h > 0 then return h .. "h " .. m .. "m" end
    return m .. "m"
end

DT.Register("Time", {
    label = "Time",
    interval = 5,
    events = { "PLAYER_ENTERING_WORLD", "UPDATE_INSTANCE_INFO" },
    onShow = function() if RequestRaidInfo then RequestRaidInfo() end end,
    text = function()
        return DT.ValueHex() .. (UseLocal() and LocalClock() or RealmClock()) .. "|r"
    end,
    onEnter = function(_, tt)
        tt:AddLine("Time", 1, 1, 1)
        tt:AddDoubleLine("Local time", LocalClock(), 1, 0.82, 0, 1, 1, 1)
        tt:AddDoubleLine("Realm time", RealmClock(), 1, 0.82, 0, 1, 1, 1)
        local raids, dungeons = {}, {}
        for i = 1, (GetNumSavedInstances and GetNumSavedInstances() or 0) do
            local name, _, reset, _, locked, extended, _, isRaid, _, diffName, numEnc, progress = GetSavedInstanceInfo(i)
            if name and (locked or extended) then
                local row = { name .. " |cffaaaaaa(" .. (diffName or "") .. ")|r",
                    (numEnc and numEnc > 0 and (progress .. "/" .. numEnc .. "  ") or "") .. Remaining(reset or 0) }
                table.insert(isRaid and raids or dungeons, row)
            end
        end
        for _, group in ipairs({ { "Raids", raids }, { "Dungeons", dungeons } }) do
            if #group[2] > 0 then
                tt:AddLine(" ")
                tt:AddLine(group[1], 1, 1, 1)
                for _, row in ipairs(group[2]) do tt:AddDoubleLine(row[1], row[2], 1, 1, 1, WHITE[1], WHITE[2], WHITE[3]) end
            end
        end
        tt:AddLine(" ")
        tt:AddLine("Click: calendar", 0.7, 0.7, 0.7)
        tt:AddLine("Right-click: clock settings", 0.7, 0.7, 0.7)
    end,
    onClick = function(_, button)
        if InCombatLockdown() then return end
        if button == "RightButton" then
            if TimeManager_Toggle then TimeManager_Toggle() end
        elseif ToggleCalendar then
            ToggleCalendar()
        end
    end,
})

-- ============================================================================
-- Gold: this character, this session, and the rest of your characters
-- ============================================================================

-- Account-wide, keyed by GUID (on WoW Forever a name and surname can repeat).
local function GoldDB()
    if not SquizzumablesDB then return nil end
    SquizzumablesDB.gold = SquizzumablesDB.gold or {}
    return SquizzumablesDB.gold
end

local sessionStart

local function Record()
    local db, guid = GoldDB(), UnitGUID("player")
    if not (db and guid) then return end
    local name = UnitName("player")
    local _, class = UnitClass("player")
    db[guid] = { name = name, realm = GetRealmName(), class = class, money = GetMoney() }
end

DT.Register("Gold", {
    label = "Gold",
    events = { "PLAYER_ENTERING_WORLD", "PLAYER_MONEY" },
    onEvent = function()
        if not sessionStart then sessionStart = GetMoney() end
        Record()
    end,
    text = function() return GoldText(GetMoney(), true) end,
    onEnter = function(_, tt)
        local now = GetMoney()
        local change = now - (sessionStart or now)
        tt:AddLine("Gold", 1, 1, 1)
        if change >= 0 then
            tt:AddDoubleLine("This session", "+" .. GoldText(change), 1, 0.82, 0, 0.1, 1, 0.1)
        else
            tt:AddDoubleLine("This session", "-" .. GoldText(-change), 1, 0.82, 0, 1, 0.1, 0.1)
        end
        local db, total, rows = GoldDB(), 0, {}
        for _, c in pairs(db or {}) do
            total = total + (c.money or 0)
            rows[#rows + 1] = c
        end
        table.sort(rows, function(a, b) return (a.money or 0) > (b.money or 0) end)
        tt:AddLine(" ")
        tt:AddLine("Characters", 1, 1, 1)
        for _, c in ipairs(rows) do
            local r, g, b = DT.ClassColor(c.class)
            tt:AddDoubleLine((c.name or "?") .. " |cffaaaaaa" .. (c.realm or "") .. "|r", GoldText(c.money), r, g, b, 1, 1, 1)
        end
        tt:AddLine(" ")
        tt:AddDoubleLine("Total", GoldText(total), 1, 0.82, 0, 1, 1, 1)
        tt:AddLine("Click: bags", 0.7, 0.7, 0.7)
    end,
    onClick = function()
        if ToggleAllBags then ToggleAllBags() end
    end,
})
