-- Reminders/Helpers.lua
-- The reminder buttons' building blocks: the button itself (CreateButton and
-- its pool), the buff checks for the player and the group, weapon runes and
-- enchants, and the consumable buff cache.
--
-- Moved out of Squizzumables.lua unchanged in 2.0 phase 2 (the split). Loads
-- after Reminders/Items.lua (whose quality tables it uses) and before
-- Reminders/Buttons.lua and Reminders/Gates.lua, which re-declare what this
-- file publishes at its end.

local addonName, ns = ...
local BH = ns.BH

local SQ_GetClickEdge = ns.SQ_GetClickEdge

local ITEM_ID_QUALITY        = BH.ITEM_ID_QUALITY
local ParseQualityFromLink   = BH.ParseQualityFromLink
local HEARTY_FOOD_IDS        = BH.HEARTY_FOOD_IDS
local CONSUMABLE_STAT_LABELS = BH.CONSUMABLE_STAT_LABELS
local COACHED_AURA_SPELL_ID  = BH.COACHED_AURA_SPELL_ID

-- The core's debug print, which is switched off.
local function Debug(msg)
    --print(addonName..": "..msg)
end

-- Get crafted quality level for an item link (returns 1-5 or nil)
-- craftingQuality is optional fallback from C_Container.GetContainerItemInfo
local function GetItemCraftedQualityFromLink(itemLink, craftingQuality)
    -- First try the container info craftingQuality (most reliable)
    if craftingQuality and craftingQuality > 0 then
        return craftingQuality
    end
    -- Try TradeSkillUI API
    if itemLink and C_TradeSkillUI and C_TradeSkillUI.GetItemCraftedQualityByItemInfo then
        local quality = C_TradeSkillUI.GetItemCraftedQualityByItemInfo(itemLink)
        if quality and quality > 0 then
            return quality
        end
    end
    -- Try parsing from item link bonus IDs
    local parsedQuality = ParseQualityFromLink(itemLink)
    if parsedQuality then
        return parsedQuality
    end
    -- Fallback: check hardcoded item ID -> quality mapping
    if itemLink then
        local itemID = itemLink:match("item:(%d+)")
        if itemID then
            local hardcodedQuality = ITEM_ID_QUALITY[tonumber(itemID)]
            if hardcodedQuality then
                return hardcodedQuality
            end
        end
    end
    return nil
end

-- Quality pip atlas names (Midnight: Tier1/Tier2 Inv size)
local QUALITY_ATLAS = {
    [1] = "Professions-Icon-Quality-12-Tier1-Inv",
    [2] = "Professions-Icon-Quality-12-Tier1-Inv",  -- Silver (Rank 1)
    [3] = "Professions-Icon-Quality-12-Tier2-Inv",  -- Gold (Rank 2)
    [4] = "Professions-Icon-Quality-12-Tier2-Inv",
    [5] = "Professions-Icon-Quality-12-Tier2-Inv",
}

-- Get item name (without quality pip - pip is shown on icon instead)
local function GetItemNameWithQuality(itemID, itemLink, craftingQuality)
    return C_Item.GetItemNameByID(itemID)
end

-- Pool of reusable secure buttons (avoids creating named frames on every UpdateButtons call)
local SQ_BUTTON_POOL = {}

-- Write the remaining-time readout onto a button.
--
-- btn.expirationTime has already been resolved through BH.Secrets.SafeNumber by
-- the time this runs, so it is either a usable number or nil and the arithmetic
-- here is always safe. Shared by the initial paint in CreateButton and the
-- throttled OnUpdate, so a rebuild never leaves the text blank.
local function PaintButtonTimer(btn)
    local expiration = btn.expirationTime
    if not expiration or expiration == 0 then
        btn.timer:SetText("")
        return
    end
    local remaining = expiration - GetTime()
    if remaining <= 0 then
        btn.timer:SetText("")
        btn.expirationTime = nil
    elseif remaining < 60 then
        btn.timer:SetText(string.format("%d", math.floor(remaining)))
    else
        local mins = math.floor(remaining / 60)
        local secs = math.floor(remaining % 60)
        btn.timer:SetText(string.format("%d:%02d", mins, secs))
    end
end

-- Where a button's label goes: the Label Position setting (buttonLabelAnchor)
-- picks a side of the icon, and the X/Y offsets are measured from there, 0,0
-- meaning "just off that edge". "auto" (and anything unknown) is below the icon,
-- or beside it on the right in a vertical layout -- the two placements there
-- were before the setting existed. Side labels get a fixed width and justify
-- away from the icon; the others are the icon's width, centred.
--
-- Used by DressButton and BH:LayoutButtons alike. Before this the vertical
-- layout hard-coded its label 4px right of the icon and never read the
-- offsets, so the offset sliders did nothing there (user report 2026-10-16).
local LABEL_PLACES = {
    --          label point  icon point   gap x  gap y  justify   beside
    BOTTOM = { "TOP",       "BOTTOM",    0,     -2,    "CENTER", false },
    TOP    = { "BOTTOM",    "TOP",       0,      2,    "CENTER", false },
    RIGHT  = { "LEFT",      "RIGHT",     4,      0,    "LEFT",   true  },
    LEFT   = { "RIGHT",     "LEFT",     -4,      0,    "RIGHT",  true  },
    CENTER = { "CENTER",    "CENTER",    0,      0,    "CENTER", false },
}
local SIDE_LABEL_WIDTH = 80

function BH.PlaceButtonLabel(btn, size, vertical)
    local s = BH.settings or {}
    local place = LABEL_PLACES[s.buttonLabelAnchor] or LABEL_PLACES[vertical and "RIGHT" or "BOTTOM"]
    btn.label:ClearAllPoints()
    btn.label:SetPoint(place[1], btn.icon, place[2],
        place[3] + (s.buttonLabelOffsetX or 0), place[4] + (s.buttonLabelOffsetY or 0))
    btn.label:SetWidth(place[6] and SIDE_LABEL_WIDTH or size)
    btn.label:SetJustifyH(place[5])
end

-- The parts every reminder button has, made once per frame; DressButton
-- reconfigures them on every use. Split out of CreateButton in 2.0 phase 3, so
-- the options preview builds its sample buttons with the real code on a plain,
-- non-secure frame (BH.DressPreviewButton) rather than a copy that drifts.
local function BuildButtonParts(btn)
    -- Everything written over the icon lives on this frame, not the button.
    -- The glow is a child frame (glowHost, and Blizzard's alert under it),
    -- and a child frame always draws above its parent's own regions -- so
    -- text on the button itself sat underneath the glow. Levelled well
    -- above the button in the sizing block below. No mouse, so clicks
    -- still land on the secure button.
    btn.textLayer = CreateFrame("Frame", nil, btn)
    btn.textLayer:SetAllPoints(btn)

    -- Header font string (always created; hidden when not needed)
    btn.header = btn.textLayer:CreateFontString(nil, "OVERLAY")
    btn.header:SetJustifyH("CENTER")
    btn.header:SetTextColor(ns.Theme.RGBA("btnHeader"))  -- Light blue

    -- Icon texture
    btn.icon = btn:CreateTexture(nil, "BACKGROUND")

    -- The glow's own frame, sized over the icon. Blizzard's proc animation
    -- sizes itself to the frame it is given, and the button is icon +
    -- label + header, so glowing the button would box the text. It also
    -- keeps the alert frame Blizzard builds off the secure button.
    btn.glowHost = CreateFrame("Frame", nil, btn)
    btn.glowHost:SetPoint("CENTER", btn.icon, "CENTER", 0, 0)

    -- Quality pip overlay
    btn.qualityPip = btn.textLayer:CreateTexture(nil, "OVERLAY")
    btn.qualityPip:SetSize(30, 30)

    -- Timer font string
    btn.timer = btn.textLayer:CreateFontString(nil, "OVERLAY")
    btn.timer:SetTextColor(ns.Theme.RGBA("btnTimer"))  -- Yellow

    -- Bag count font string
    btn.countText = btn.textLayer:CreateFontString(nil, "OVERLAY")
    btn.countText:SetTextColor(ns.Theme.RGBA("btnText"))

    -- Label font string
    btn.label = btn.textLayer:CreateFontString(nil, "OVERLAY")
    btn.label:SetJustifyH("CENTER")
    btn.label:SetWordWrap(true)
    btn.label:SetMaxLines(3)
    btn.label:SetTextColor(ns.Theme.RGBA("btnText"))

    -- Hearty food badge (top-right corner of icon)
    btn.heartyBadge = btn.textLayer:CreateFontString(nil, "OVERLAY")
    btn.heartyBadge:SetTextColor(ns.Theme.RGBA("btnBadge"))  -- Warm gold
end

-- How a reminder button looks -- size, fonts, header, icon and shape, quality
-- pip, hearty badge, the timer and its countdown, bag count, label -- from the
-- current settings and theme. Everything a click does is CreateButton's.
---@param btn table
---@param texture number|string
---@param tooltip string
---@param actionType string  "spell", "item", "macro" or "oil"
---@param actionValue number|string|table  a table only for "oil": { itemID, slot }
---@param labelText string?
---@param headerText string?
---@param expirationTime number?
---@param itemLink string?
---@param craftingQuality number?
---@param bagCount number?
local function DressButton(btn, texture, tooltip, actionType, actionValue, labelText, headerText, expirationTime, itemLink, craftingQuality, bagCount)
    local size = (BH.settings and BH.settings.buttonSize) or 36
    local headerHeight = headerText and 12 or 0

    -- Font sizes (re-apply every use so settings changes take effect)
    local headerFontSize = (BH.settings and BH.settings.buttonHeaderFontSize) or 10
    btn.header:SetFont("Fonts\\FRIZQT__.TTF", headerFontSize, "OUTLINE")
    local timerFontSize = (BH.settings and BH.settings.buttonTimerFontSize) or 10
    btn.timer:SetFont("Fonts\\FRIZQT__.TTF", timerFontSize, "OUTLINE")
    local countFontSize = (BH.settings and BH.settings.buttonCountFontSize) or 10
    btn.countText:SetFont("Fonts\\FRIZQT__.TTF", countFontSize, "OUTLINE")
    local labelFontSize = (BH.settings and BH.settings.buttonLabelFontSize) or 10
    btn.label:SetFont("Fonts\\FRIZQT__.TTF", labelFontSize, "OUTLINE")

    -- Size
    btn:SetSize(size, size + 26 + headerHeight)
    btn.icon:SetSize(size, size)
    -- Sized explicitly rather than to the icon's anchors, so the size is
    -- there to measure the instant the glow starts. Resize because Blizzard's
    -- alert keeps whatever size it measured on its first show.
    btn.glowHost:SetSize(size, size)
    ns.Glow.Resize(btn.glowHost)
    -- Text above the glow: glowHost sits one level over the button and
    -- Blizzard's alert one over that, so +10 clears both with room to spare.
    -- Re-asserted on every use because a pooled button is reparented.
    btn.textLayer:SetFrameLevel(btn:GetFrameLevel() + 10)

    -- Header text above icon (for MH/OH)
    btn.header:ClearAllPoints()
    btn.icon:ClearAllPoints()
    if headerText then
        -- Strip realm suffix from player names (e.g. "Name-Realm" → "Name")
        local displayHeader = headerText:match("^([^%-]+)") or headerText
        btn.header:SetText(displayHeader)
        btn.header:SetWidth(0)  -- unconstrained: let text determine its own width
        btn.header:SetPoint("TOP", btn, "TOP", 0, 0)
        btn.header:Show()
        btn.icon:SetPoint("TOP", btn, "TOP", 0, -headerHeight)
    else
        btn.header:SetText("")
        btn.header:Hide()
        btn.icon:SetPoint("TOP", btn, "TOP", 0, 0)
    end
    btn.icon:SetTexture(texture)

    -- Icon shape, the same set as the Cooldown Manager's (UI/Shapes.lua). The
    -- glow takes that shape's art, so a round icon gets a round glow.
    local shape = (BH.settings and BH.settings.buttonIconShape) or "none"
    ns.Shapes.SetMask(btn, shape, btn.icon)
    ns.Glow.SetShape(btn.glowHost, ns.Shapes.GLOW[shape])

    -- Quality pip overlay on icon (anchored top left, inside icon)
    btn.qualityPip:ClearAllPoints()
    btn.qualityPip:SetPoint("TOPLEFT", btn.icon, "TOPLEFT", 2, -2)
    btn.qualityPip:Hide()
    if itemLink or craftingQuality then
        local quality = GetItemCraftedQualityFromLink(itemLink, craftingQuality)
        if quality and quality > 0 and QUALITY_ATLAS[quality] then
            btn.qualityPip:SetAtlas(QUALITY_ATLAS[quality])
            btn.qualityPip:Show()
        end
    end

    -- Hearty food badge ("H" at top-right of icon)
    local heartyBadgeFontSize = math.max(8, math.floor(size * 0.4))
    btn.heartyBadge:SetFont("Fonts\\FRIZQT__.TTF", heartyBadgeFontSize, "OUTLINE")
    btn.heartyBadge:ClearAllPoints()
    btn.heartyBadge:SetPoint("TOPRIGHT", btn.icon, "TOPRIGHT", -1, -1)
    local isHearty = false
    if actionType == "item" then
        -- only "oil" passes a table; "item" is always an item ID
        ---@cast actionValue number
        if HEARTY_FOOD_IDS[actionValue] then
            isHearty = true
        else
            local itemName = C_Item.GetItemNameByID(actionValue)
            if itemName and itemName:lower():find("hearty") then
                isHearty = true
            end
        end
    end
    if isHearty then
        btn.heartyBadge:SetText("H")
        btn.heartyBadge:Show()
    else
        btn.heartyBadge:SetText("")
        btn.heartyBadge:Hide()
    end

    -- Timer text on icon (shows remaining buff time).
    --
    -- expirationTime can be a secret number (client 12.1.0+, in combat/M+/PvP):
    -- assigning/passing it around is fine, but comparing or doing arithmetic on
    -- it throws ("attempt to compare ... a secret number value") — confirmed via
    -- a live user crash report.
    --
    -- BH.Secrets.SafeNumber checks that once, here, and stores either a usable
    -- number or nil. The OnUpdate below can then do plain arithmetic: it never
    -- sees a secret value, so it needs no pcall and allocates no closure. (The
    -- previous version built a fresh closure for pcall on every button on every
    -- rendered frame.)
    btn.expirationTime = BH.Secrets.SafeNumber(expirationTime, nil)
    btn.timer:ClearAllPoints()
    btn.timer:SetPoint("CENTER", btn.icon, "CENTER", 0, 0)
    btn.timerElapsed = 0
    if btn.expirationTime and btn.expirationTime > 0 then
        -- Paint once immediately. UpdateButtons rebuilds the whole button list
        -- often (see the note there), and every rebuild lands here; if the text
        -- were left blank until the first throttled tick the countdown would
        -- visibly flicker on every rebuild.
        PaintButtonTimer(btn)
        btn:SetScript("OnUpdate", function(self, elapsed)
            -- The readout is whole seconds; refreshing it every frame is wasted
            -- work. Accumulate and repaint ~10x/sec instead.
            self.timerElapsed = self.timerElapsed + elapsed
            if self.timerElapsed < 0.1 then return end
            self.timerElapsed = 0
            PaintButtonTimer(self)
        end)
    else
        btn.timer:SetText("")
        btn:SetScript("OnUpdate", nil)
    end

    -- Bag count text on icon (bottom-right corner)
    btn.countText:ClearAllPoints()
    btn.countText:SetPoint("BOTTOMRIGHT", btn.icon, "BOTTOMRIGHT", -2, 2)
    if bagCount and bagCount > 0 then
        btn.countText:SetText(tostring(bagCount))
        btn.countText:Show()
    else
        btn.countText:SetText("")
        btn.countText:Hide()
    end

    -- Label text (conditionally shown), placed by the Label Position setting.
    BH.PlaceButtonLabel(btn, size, (BH.settings and BH.settings.layoutDirection) == "VERTICAL")
    if BH.settings and BH.settings.showLabelText ~= false then
        if labelText then
            btn.label:SetText(labelText)
        elseif actionType == "item" or actionType == "oil" then
            local itemID = (actionType == "oil") and actionValue.itemID or actionValue
            ---@cast itemID number
            -- Use short stat label for consumables that have one (e.g. "Int", "Mast")
            local statLabel = CONSUMABLE_STAT_LABELS and CONSUMABLE_STAT_LABELS[itemID]
            if statLabel then
                btn.label:SetText(statLabel)
            else
                local itemName = GetItemNameWithQuality(itemID, itemLink, craftingQuality)
                if itemName then
                    btn.label:SetText(itemName)
                else
                    btn.label:SetText("Loading...")
                    C_Item.RequestLoadItemDataByID(itemID)
                    local ticker
                    ticker = C_Timer.NewTicker(0.1, function()
                        local name = GetItemNameWithQuality(itemID, itemLink, craftingQuality)
                        if name then
                            btn.label:SetText(name)
                            ticker:Cancel()
                        end
                    end, 30)
                end
            end
        elseif actionType == "spell" then
            ---@cast actionValue number
            local spellName = C_Spell.GetSpellName(actionValue)
            btn.label:SetText(spellName or "Spell")
        elseif actionType == "macro" then
            btn.label:SetText(tooltip or "Macro")
        end
        btn.label:Show()
    else
        btn.label:SetText("")
        btn.label:Hide()
    end
end

-- The button's glow, from the settings (see the notes where CreateButton calls
-- it). Shared with the options preview.
local function GlowButton(btn)
    btn.glowHost.sqGlowSelfOnly = (BH.settings and BH.settings.buttonGlowStyle) == "ring"
    ns.Glow.Set(btn.glowHost, BH.settings and BH.settings.glowReminderButtons ~= false, nil, true)
end

-- Annotated because the language server infers unannotated parameter types from call
-- sites and had guessed `headerText` was a table, which then made every string call
-- site read as a type mismatch. The types below are what the body actually requires.
---@param id number
---@param texture number|string
---@param tooltip string
---@param actionType string  "spell", "item", "macro" or "oil"
---@param actionValue number|string|table  a table only for "oil": { itemID, slot }
---@param labelText string?
---@param headerText string?
---@param expirationTime number?
---@param itemLink string?
---@param craftingQuality number?
---@param bagCount number?
local function CreateButton(id, texture, tooltip, actionType, actionValue, labelText, headerText, expirationTime, itemLink, craftingQuality, bagCount)
    -- Try to reuse a pooled button; only allocate a new frame when the pool is empty
    local btn = table.remove(SQ_BUTTON_POOL)

    if not btn then
        -- First use: create an anonymous (un-named) frame so it can be GC'd eventually,
        -- and create all child objects once.  They are reconfigured on every reuse.
        btn = CreateFrame("Button", nil, BH.frame, "SecureActionButtonTemplate")
        BuildButtonParts(btn)
    else
        -- Returning from pool: re-parent and make visible
        btn:SetParent(BH.frame)
        btn:Show()
    end

    DressButton(btn, texture, tooltip, actionType, actionValue, labelText, headerText, expirationTime, itemLink, craftingQuality, bagCount)

    if actionType == "item" then
        btn:SetAttribute("type", "item")
        btn:SetAttribute("item", "item:" .. actionValue)
    elseif actionType == "spell" then
        btn:SetAttribute("type", "spell")
        btn:SetAttribute("spell", actionValue)
    elseif actionType == "oil" then
        -- Oil uses macro to apply to specific weapon slot
        btn:SetAttribute("type", "macro")
        btn:SetAttribute("macrotext", "/use item:" .. actionValue.itemID .. "\n/use " .. actionValue.slot)
    elseif actionType == "macro" then
        -- Generic macro (e.g. healer-targeted spells)
        btn:SetAttribute("type", "macro")
        btn:SetAttribute("macrotext", actionValue)
    end

    -- Store actionID for fade-out tracking
    if actionType == "oil" then
        btn.actionID = tostring(actionValue.itemID) .. "_" .. tostring(actionValue.slot)
    else
        btn.actionID = tostring(actionValue)
    end

    Debug("Created button #"..id.." type="..tostring(actionType).." value="..tostring(actionValue))

    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if actionType == "item" then
            GameTooltip:SetItemByID(actionValue)
        elseif actionType == "oil" then
            GameTooltip:SetItemByID(actionValue.itemID)
        elseif actionType == "spell" then
            GameTooltip:SetSpellByID(actionValue)
        else
            GameTooltip:SetText(tooltip)
        end
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Fire the secure action once per click, on the edge the client is
    -- configured for. Registering both "AnyDown" and "AnyUp" (as this did) makes
    -- every physical click attempt the cast twice, with the second attempt
    -- landing inside the GCD of the first. Matching ActionButtonUseKeyDown is
    -- what Blizzard's own action buttons do, so these behave like the rest of
    -- the player's bars.
    btn:RegisterForClicks(SQ_GetClickEdge())
    btn:SetFrameStrata("MEDIUM")  -- Below the options panel (DIALOG)
    btn:Enable()

    -- Glow, if the player wants it.
    --
    -- Every visible button gets one, because a button only exists when
    -- something needs doing -- whether the buff is missing outright or just
    -- running short. The point is to be noticeable from outside the eye
    -- line, so singling out a subset would defeat it.
    --
    -- "ring" forces the self-drawn pulse; anything else is the proc animation.
    -- Read on every build, which is enough for a style change to apply:
    -- UpdateButtons stops every glow before a button is reused.
    --
    -- Always skipBirth: the start burst is a large bright flash meant for a
    -- one-off proc, and UpdateButtons rebuilds every button every few seconds,
    -- so each rebuild replayed it and the icons strobed. Straight to the loop.
    GlowButton(btn)

    return btn
end

-- Check if a unit has a specific buff by spellID (or any of a list of spellIDs)
-- spellIDs can be a single number or a table of numbers
local function UnitHasBuff(unit, spellIDs)
    local idList = type(spellIDs) == "table" and spellIDs or { spellIDs }

    -- Primary: direct spellID lookup. This one does not throw on secret auras,
    -- so it is always preferred when the spell ID is known.
    for _, id in ipairs(idList) do
        local auraData = BH.Secrets.GetAuraBySpellID(unit, id)
        if auraData then
            return true, BH.Secrets.SafeAuraExpiration(auraData)
        end
    end

    -- Fallback: scan all HELPFUL auras and compare spellId. Needed because
    -- GetUnitAuraBySpellID returns nil for some protected/stance auras (e.g.
    -- Lightning Shield, Water Shield) in M+ instances.
    --
    -- Both the scan and the field reads go through BH.Secrets: as of 12.1.0
    -- GetAuraDataByIndex throws when auras are secret, and the fields on the
    -- table it returns can be secret independently of that — comparing one with
    -- `==` throws ("attempt to compare field 'spellId' (a secret number
    -- value...)"), which is the v1.58 crash. SafeAuraSpellID returns nil for an
    -- unreadable field, so the comparison below is always safe.
    if unit == "player" then
        local foundExpiration
        BH.Secrets.ForEachAura("player", "HELPFUL", function(auraData)
            local spellID = BH.Secrets.SafeAuraSpellID(auraData)
            if not spellID then return end
            for _, id in ipairs(idList) do
                if spellID == id then
                    foundExpiration = BH.Secrets.SafeAuraExpiration(auraData) or false
                    return true  -- stop scanning
                end
            end
        end)
        if foundExpiration ~= nil then
            return true, foundExpiration or nil
        end
    end

    -- Final fallback: IsCurrentSpell for toggle/stance auras (e.g. Lightning Shield,
    -- Water Shield) whose spellId may not compare equal via == in 12.0.5.
    -- Only meaningful for the player's own buffs. Guard against nil in some builds.
    if unit == "player" and IsCurrentSpell then
        for _, id in ipairs(idList) do
            if IsCurrentSpell(id) then
                return true, nil
            end
        end
    end

    return false
end

-- Count how many players of a given class are in the group (including the player)
local function CountClassInGroup(className)
    local count = 0

    -- Check player
    local _, playerClass = UnitClass("player")
    if playerClass == className then
        count = count + 1
    end

    local groupSize = GetNumGroupMembers()
    if groupSize == 0 then
        return count
    end

    local isRaid = IsInRaid()
    for i = 1, groupSize do
        local unit = isRaid and ("raid" .. i) or ("party" .. i)
        if isRaid and UnitIsUnit(unit, "player") then
            -- already counted player above
        elseif UnitExists(unit) then
            local _, unitClass = UnitClass(unit)
            if unitClass == className then
                count = count + 1
            end
        end
    end

    return count
end

-- Find healers in the current group/raid and return the first one missing the given buff
-- Returns: targetName (or nil), allBuffed (bool)
local function FindUnbuffedHealer(spellID)
    local groupSize = GetNumGroupMembers()
    if groupSize == 0 then return nil, true end

    local isRaid = IsInRaid()
    for i = 1, groupSize do
        local unit = isRaid and ("raid" .. i) or ("party" .. i)
        -- Skip self in raid (party units don't include player)
        if isRaid and UnitIsUnit(unit, "player") then
            -- skip
        elseif UnitExists(unit) then
            local role = UnitGroupRolesAssigned(unit)
            if role == "HEALER" then
                local has = UnitHasBuff(unit, spellID)
                if not has then
                    return UnitName(unit), false
                end
            end
        end
    end
    return nil, true  -- all healers buffed (or no healers found)
end

-- Find a tank in the group missing a specific buff (or with lowest expiration)
-- Returns: tankName, allBuffed, lowestExpiration
local function FindUnbuffedTank(spellID)
    local groupSize = GetNumGroupMembers()
    if groupSize == 0 then return nil, true, nil end

    local isRaid = IsInRaid()
    local lowestName, lowestExpires = nil, nil
    for i = 1, groupSize do
        local unit = isRaid and ("raid" .. i) or ("party" .. i)
        if isRaid and UnitIsUnit(unit, "player") then
            -- skip self
        elseif UnitExists(unit) and UnitIsPlayer(unit) and UnitIsConnected(unit)
            and not UnitIsDeadOrGhost(unit) then
            local role = UnitGroupRolesAssigned(unit)
            if role == "TANK" then
                local has, expires = UnitHasBuff(unit, spellID)
                if not has then
                    return UnitName(unit), false, nil
                end
                if expires and expires > 0 then
                    if not lowestExpires or expires < lowestExpires then
                        lowestExpires = expires
                        lowestName = UnitName(unit)
                    end
                end
            end
        end
    end
    return lowestName, true, lowestExpires
end

-- Returns true if any group/raid member (not the player) currently has a buff
-- that was cast by the player (sourceUnit == "player").
-- Used to detect if e.g. Earth Shield is already placed on a group member.
local function PlayerHasBuffOnGroupMember(spellIDs)
    local groupSize = GetNumGroupMembers()
    if groupSize == 0 then return false end
    local isRaid = IsInRaid()
    local ids = type(spellIDs) == "table" and spellIDs or { spellIDs }
    for i = 1, groupSize do
        local unit = isRaid and ("raid" .. i) or ("party" .. i)
        if not UnitIsUnit(unit, "player") and UnitExists(unit) then
            for _, checkID in ipairs(ids) do
                local auraData = C_UnitAuras.GetUnitAuraBySpellID(unit, checkID)
                if BH.Secrets.AuraIsFromPlayer(auraData) then
                    return true
                end
            end
        end
    end
    return false
end

-- Returns: true if someone is missing the buff, lowestExpiration (or nil)
local function GroupNeedsBuff(spellID)
    -- Solo: just check player
    local groupSize = GetNumGroupMembers()
    if groupSize == 0 then
        local has, expires = UnitHasBuff("player", spellID)
        if not has then return true, nil end
        return false, expires
    end

    local isRaid = IsInRaid()
    local lowestExpires = nil
    local anyMissing = false

    -- Check player first (use GetUnitAuraBySpellID via UnitHasBuff for full aura list reliability)
    local has, expires = UnitHasBuff("player", spellID)
    if not has then
        anyMissing = true
    elseif expires and expires > 0 then
        lowestExpires = expires
    end

    for i = 1, groupSize do
        local unit = isRaid and ("raid" .. i) or ("party" .. i)
        if isRaid and UnitIsUnit(unit, "player") then
            -- already checked player
        elseif UnitExists(unit) and UnitIsPlayer(unit) and UnitIsConnected(unit)
            and not UnitIsDeadOrGhost(unit) and UnitIsVisible(unit) then
            local uHas, uExpires = UnitHasBuff(unit, spellID)
            if not uHas then
                anyMissing = true
            elseif uExpires and uExpires > 0 then
                if not lowestExpires or uExpires < lowestExpires then
                    lowestExpires = uExpires
                end
            end
        end
    end

    return anyMissing, lowestExpires
end

-- check weapon enchants (for oils)
-- Returns: hasEnchant (bool), expirationTime (GetTime()-based, or nil)

-- Does an equipped weapon lack a permanent enchant?
--
-- Death Knight runeforges are permanent enchants, and GetWeaponEnchantInfo only
-- reports *temporary* ones -- so the weapon-imbue path used for Shaman and
-- Paladin cannot see a rune at all, present or absent.
--
-- The enchant ID is the second field of the item string:
--     item:<itemID>:<enchantID>:...
-- Zero, or absent, means no enchant.
--
-- Returns: needsRune, slotLabel. Reports the main hand first; only mentions the
-- off hand when the main hand is fine, so the button says one thing at a time.
local RUNEFORGING_SPELL_ID = 53428
local DEATH_GATE_SPELL_ID  = 50977

-- Are we somewhere with a runeforge?
--
-- Matched against Blizzard's own localised zone strings rather than literal
-- English, so this works in any locale. The globals are guarded because a
-- missing one must not become a nil comparison, and because falling through to
-- Death Gate is the harmless direction -- Death Gate is useful anywhere,
-- Runeforging is useful in exactly one place.
local function AtRuneforge()
    local names = {
        ORDER_HALL_DEATHKNIGHT,                     -- "Acherus"
        DUNGEON_FLOOR_ICECROWNCITADELDEATHKNIGHT1,  -- "Lower Acherus"
        DUNGEON_FLOOR_ICECROWNCITADELDEATHKNIGHT2,  -- "Upper Acherus"
        DUNGEON_FLOOR_BROKENSHORE1,                 -- "The Heart of Acherus"
    }
    local here = { GetRealZoneText(), GetSubZoneText(), GetZoneText() }
    for _, want in ipairs(names) do
        if type(want) == "string" and want ~= "" then
            for _, got in ipairs(here) do
                -- Substring, not equality: the zone reports as "Acherus: The
                -- Ebon Hold" while the global is just "Acherus", so an exact
                -- match only ever hit on the sub-zone -- which meant the check
                -- depended on standing in the right room.
                if type(got) == "string" and got ~= "" and got:find(want, 1, true) then
                    return true
                end
            end
        end
    end
    return false
end

-- Which action to offer for an unruneforged weapon.
--
-- Runeforging can only be cast at a runeforge, so away from one the useful
-- button is Death Gate, which drops you in Acherus beside one. Standing there,
-- offering Death Gate is absurd, so the button becomes the runeforge itself.
--
-- This originally inferred proximity from C_Spell.IsSpellUsable, on the basis
-- that the spell requires a nearby object. It does not: the API reports usable
-- from the moment the spell is known, so the button showed Runeforging out in
-- the world where it cannot be cast. The zone is the signal that actually
-- works.
local function RuneforgeAction()
    if AtRuneforge() and BH.PlayerKnowsSpell(RUNEFORGING_SPELL_ID) then
        return RUNEFORGING_SPELL_ID, "Runeforge"
    end
    if BH.PlayerKnowsSpell(DEATH_GATE_SPELL_ID) then
        return DEATH_GATE_SPELL_ID, "To Acherus"
    end
    return nil
end
BH.RuneforgeAction = RuneforgeAction
BH.AtRuneforge = AtRuneforge


local function WeaponNeedsRune()
    local function slotState(slotID)
        local link = GetInventoryItemLink("player", slotID)
        if not link then return false, false end          -- nothing equipped
        -- The enchant field is *empty* on an unenchanted item ("item:12345::"),
        -- not zero, so the digits are optional. Matching %d+ here happened to
        -- work only because a failed match also came back nil.
        local ench = tonumber(link:match("item:%d+:(%-?%d*):"))
        return true, (ench or 0) ~= 0
    end

    local mhEquipped, mhEnchanted = slotState(16)
    if mhEquipped and not mhEnchanted then return true, "MH" end

    local ohEquipped, ohEnchanted = slotState(17)
    if ohEquipped and not ohEnchanted then return true, "OH" end

    return false, nil
end
BH.WeaponNeedsRune = WeaponNeedsRune
local function GetMainHandEnchantInfo()
    local hasMain, mainExpiration = GetWeaponEnchantInfo()
    if hasMain and mainExpiration then
        -- mainExpiration is in milliseconds remaining
        return true, GetTime() + (mainExpiration / 1000)
    end
    return hasMain or false, nil
end

local function GetOffHandEnchantInfo()
    local _, _, _, _, hasOff, offExpiration = GetWeaponEnchantInfo()
    if hasOff and offExpiration then
        return true, GetTime() + (offExpiration / 1000)
    end
    return hasOff or false, nil
end

local function HasOffHandWeapon()
    local itemID = GetInventoryItemID("player", 17)
    if not itemID then return false end
    
    -- Check if it's actually a weapon (not shield, held in off-hand, etc.)
    local _, _, _, _, _, _, _, _, invType = C_Item.GetItemInfo(itemID)
    if not invType then
        -- Item info might not be loaded yet, try async
        C_Item.RequestLoadItemDataByID(itemID)
        return false  -- Safe default, will re-check on next update
    end
    
    -- Only show OH oil for actual weapons
    -- INVTYPE_WEAPON = One-Hand, INVTYPE_WEAPONOFFHAND = Off-Hand weapon
    -- INVTYPE_2HWEAPON = Two-Hand (Fury warriors can equip these in off-hand via Titan's Grip)
    if invType == "INVTYPE_WEAPON" or invType == "INVTYPE_WEAPONOFFHAND" or invType == "INVTYPE_2HWEAPON" then
        return true
    end
    
    -- Don't show for shields (INVTYPE_SHIELD) or held in off-hand items (INVTYPE_HOLDABLE)
    return false
end


-- Returns true if any party/raid member (excluding the player) currently has the "Coached" buff,
-- indicating the player has already assigned their coached ally this session.
-- Returns the expirationTime of the Coached buff on any real player group member, or nil if none.
local function GetCoachedAllyExpiration()
    local groupSize = GetNumGroupMembers()
    local isRaid = IsInRaid()
    for i = 1, groupSize do
        local unit = isRaid and ("raid" .. i) or ("party" .. i)
        if UnitExists(unit) and not UnitIsUnit(unit, "player") and UnitIsPlayer(unit) then
            -- Direct spellID lookup instead of scanning by index — avoids the
            -- 12.1.0 taint error GetAuraDataByIndex throws when auras are
            -- secret (in combat, encounters, M+, PvP).
            local aura = C_UnitAuras.GetUnitAuraBySpellID(unit, COACHED_AURA_SPELL_ID)
            if aura then
                return aura.expirationTime
            end
        end
    end
    return nil
end

-- Returns true if at least one real player group member (not the player, not an NPC) exists
local function HasRealPlayerGroupMember()
    local groupSize = GetNumGroupMembers()
    local isRaid = IsInRaid()
    for i = 1, groupSize do
        local unit = isRaid and ("raid" .. i) or ("party" .. i)
        if UnitExists(unit) and not UnitIsUnit(unit, "player") and UnitIsPlayer(unit)
            and not UnitIsDeadOrGhost(unit) and UnitIsConnected(unit) then
            return true
        end
    end
    return false
end

-- get spell icon safely
local function GetSpellIcon(spellID)
    local info = C_Spell.GetSpellInfo(spellID)
    return info and info.iconID
end

-- Cache of buff spell IDs for configured consumables, built at PLAYER_LOGIN.
-- C_Item.GetItemSpell returns the spell that the item directly applies — in Midnight this
-- IS the buff aura spell ID for both food and flasks (all are instant-use consumables).
local _consumableBuffCache = { food = {}, flask = {} }
-- Spell names (from C_Item.GetItemSpell) and item names (from GetItemNameByID)
-- stored so the AuraUtil fallback can match Midnight food buff names like
-- "Beledar's Bounty" that differ from the classic "Well Fed" pattern.
local _consumableBuffNames = { food = {}, flask = {} }

local function BuildConsumableBuffCache()
    if not BH.consumables then return end
    _consumableBuffCache = { food = {}, flask = {}, augmentRune = {} }
    _consumableBuffNames = { food = {}, flask = {}, augmentRune = {} }
    for _, category in ipairs({ "food", "flask", "augmentRune" }) do
        local list = BH.consumables[category]
        if list then
            for _, itemID in ipairs(list) do
                local spellName, spellID = C_Item.GetItemSpell(itemID)
                if spellID then
                    _consumableBuffCache[category][spellID] = true
                end
                -- Store spell name; for flasks this IS the buff name.
                -- For food, the eat-cast spell name may or may not match the
                -- resulting buff name, but it's worth checking.
                if spellName then
                    _consumableBuffNames[category][spellName] = true
                end
                -- Also store the item name itself in case the buff is named
                -- after the food/flask item (common in Midnight).
                local itemName = C_Item.GetItemNameByID(itemID)
                if itemName then
                    _consumableBuffNames[category][itemName] = true
                end
            end
        end
    end
end

-- Scan all HELPFUL auras on the player, calling func(auraData) for each; return
-- true from func to stop. Uses C_UnitAuras.GetAuraDataByIndex directly (avoids
-- AuraUtil wrapper version quirks), via BH.Secrets.ForEachAura which handles the
-- 12.1.0 throw-on-secret behaviour. Falls back to AuraUtil.ForEachAura if the
-- direct API is unavailable.
local function ForEachPlayerBuff(func)
    if C_UnitAuras.GetAuraDataByIndex then
        BH.Secrets.ForEachAura("player", "HELPFUL", func)
    elseif AuraUtil and AuraUtil.ForEachAura then
        AuraUtil.ForEachAura("player", "HELPFUL", nil, func)
    end
end

-- Check if the player has any food buff active.
-- Returns: hasBuff (bool), expirationTime (number|nil; 0 = permanent/charge-based)
-- Midnight regular food → "Well Fed" buff; hearty food → "Hearty Well Fed" buff.
local function HasFoodBuff()
    -- Primary: direct spellID lookup using the full (unfiltered) aura list.
    -- GetUnitAuraBySpellID("player") checks all auras; GetPlayerAuraBySpellID is
    -- filtered and misses some buff types (same issue as Devotion Aura on paladins).
    for spellID in pairs(_consumableBuffCache.food) do
        local auraData = BH.Secrets.GetAuraBySpellID("player", spellID)
        if auraData then
            return true, BH.Secrets.SafeAuraExpiration(auraData)
        end
    end
    -- Fallback: scan all HELPFUL auras by name.
    -- "Well Fed" = regular Midnight food; "Hearty Well Fed" = hearty food (both
    -- contain "Well Fed"). Also checks cached item/spell names for custom food.
    -- Protected auras return secret string values for name, and calling :find()
    -- on a secret string throws — SafeAuraName returns nil for those, so the
    -- aura is simply skipped.
    local found, expTime = false, nil
    ForEachPlayerBuff(function(auraData)
        local name = BH.Secrets.SafeAuraName(auraData)
        if not name then return end
        if name:find("Well Fed") or name:find("Hearty")
            or _consumableBuffNames.food[name] then
            found = true
            expTime = BH.Secrets.SafeAuraExpiration(auraData)
            return true  -- stop iterating once a match is found
        end
    end)
    return found, expTime
end

-- Check if the player has any flask buff active.
-- Returns: hasBuff (bool), expirationTime (number|nil; 0 = permanent/charge-based)
local function HasFlaskBuff()
    -- Primary: direct spellID lookup (flask items directly apply the buff spell,
    -- so GetItemSpell gives the correct buff spell ID for flasks).
    for spellID in pairs(_consumableBuffCache.flask) do
        local auraData = BH.Secrets.GetAuraBySpellID("player", spellID)
        if auraData then
            return true, BH.Secrets.SafeAuraExpiration(auraData)
        end
    end
    -- Fallback: scan by name. Midnight flask buffs contain "Flask" in the name.
    -- Also checks cached item/spell names for custom flasks. Same secret-string
    -- handling as HasFoodBuff.
    local found, expTime = false, nil
    ForEachPlayerBuff(function(auraData)
        local name = BH.Secrets.SafeAuraName(auraData)
        if not name then return end
        if name:find("Flask") or _consumableBuffNames.flask[name] then
            found = true
            expTime = BH.Secrets.SafeAuraExpiration(auraData)
            return true
        end
    end)
    return found, expTime
end

-- Known augment rune buffs.
--
-- The cache built from C_Item.GetItemSpell covers the *use* spell, which for
-- these is not always the buff that ends up on the player, so the buff IDs are
-- listed too. Both are checked; whichever answers first wins.
local AUGMENT_RUNE_BUFF_IDS = {
    1264426,  -- Void-Touched Augment Rune (Midnight)
    1234969,  -- Ethereal Augment Rune (The War Within)
}

local function HasAugmentRuneBuff()
    for spellID in pairs(_consumableBuffCache.augmentRune or {}) do
        local auraData = BH.Secrets.GetAuraBySpellID("player", spellID)
        if auraData then
            return true, BH.Secrets.SafeAuraExpiration(auraData)
        end
    end
    for _, spellID in ipairs(AUGMENT_RUNE_BUFF_IDS) do
        local auraData = BH.Secrets.GetAuraBySpellID("player", spellID)
        if auraData then
            return true, BH.Secrets.SafeAuraExpiration(auraData)
        end
    end
    return false, nil
end

-- For Reminders/Buttons.lua and Reminders/Gates.lua (which re-declare them
-- under the same names) and the core's PLAYER_LOGIN handler. None is
-- reassigned after load, so the copies they take stay correct.
BH.CountClassInGroup          = CountClassInGroup
BH.CreateButton               = CreateButton
-- For the options preview (UI/PreviewColumn.lua): sample buttons built,
-- dressed and glowed by the real code on a plain frame -- never secure, never
-- pooled, never clickable.
BH.NewPreviewButton = function(parent)
    local btn = CreateFrame("Button", nil, parent)
    BuildButtonParts(btn)
    btn:EnableMouse(false)
    return btn
end
BH.DressPreviewButton         = DressButton
BH.GlowPreviewButton          = GlowButton
BH.FindUnbuffedHealer         = FindUnbuffedHealer
BH.FindUnbuffedTank           = FindUnbuffedTank
BH.GetMainHandEnchantInfo     = GetMainHandEnchantInfo
BH.GetOffHandEnchantInfo      = GetOffHandEnchantInfo
BH.GetSpellIcon               = GetSpellIcon
BH.GroupNeedsBuff             = GroupNeedsBuff
BH.HasAugmentRuneBuff         = HasAugmentRuneBuff
BH.HasFlaskBuff               = HasFlaskBuff
BH.HasFoodBuff                = HasFoodBuff
BH.HasOffHandWeapon           = HasOffHandWeapon
BH.PlayerHasBuffOnGroupMember = PlayerHasBuffOnGroupMember
BH.SQ_BUTTON_POOL             = SQ_BUTTON_POOL
BH.UnitHasBuff                = UnitHasBuff
BH.GetCoachedAllyExpiration   = GetCoachedAllyExpiration
BH.HasRealPlayerGroupMember   = HasRealPlayerGroupMember
BH.BuildConsumableBuffCache   = BuildConsumableBuffCache
