-- Reminders/Items.lua
-- The Items options tab (one row per consumable, with quality, minimum
-- duration and sound), and the item-quality tables it shares with the
-- reminder helpers.
--
-- Moved out of Squizzumables.lua unchanged in 2.0 phase 2 (the split). The
-- Coach Whistle constants stay in the core, which reads them while loading
-- (the reminder registry), and are re-declared here from BH. The tables the
-- helpers need are published at the end of this file, which loads before
-- Reminders/Helpers.lua.

local addonName, ns = ...
local BH = ns.BH

local SQ_COLORS        = ns.SQ_COLORS
local CreateSQEditBox  = ns.CreateSQEditBox
local CreateSQSlider   = ns.CreateSQSlider
local CreateSQDropdown = ns.CreateSQDropdown

local COACH_WHISTLE_ITEM_ID = BH.COACH_WHISTLE_ITEM_ID

-- The core's private sound helpers, through their public wrappers.
local function PlaySQSound(name, channel) BH:PlaySound(name, channel) end
local function BuildSoundDropdownItems() return BH:BuildSoundDropdownItems() end

local CONFIG_QUALITY_ATLAS = {
    [1] = "Professions-Icon-Quality-12-Tier1-Inv",
    [2] = "Professions-Icon-Quality-12-Tier1-Inv",  -- Silver (Rank 1)
    [3] = "Professions-Icon-Quality-12-Tier2-Inv",  -- Gold (Rank 2)
    [4] = "Professions-Icon-Quality-12-Tier2-Inv",
    [5] = "Professions-Icon-Quality-12-Tier2-Inv",
}

-- Find an item in bags and return its link and crafting quality (for quality detection)
local function FindItemInBags(itemID)
    local entry = BH:GetBagEntry(itemID)
    if not entry then return nil, nil end
    return entry.link, entry.quality
end

-- Check if player meets item level requirement (for config panel)
local function ConfigMeetsLevelRequirement(itemID)
    local playerLevel = UnitLevel("player")
    local _, _, _, _, minLevel = C_Item.GetItemInfo(itemID)
    -- If item info not loaded yet, assume we can use it
    if not minLevel then return true end
    return playerLevel >= minLevel
end

-- Crafted quality bonus IDs (used as fallback for parsing from item links)
-- These cover multiple expansions and variations
local QUALITY_BONUS_IDS = {
    -- Dragonflight / TWW / Midnight standard crafted quality
    [8840] = 1, [8841] = 2, [8842] = 3, [8843] = 4, [8844] = 5,
    -- Alternate set
    [9623] = 1, [9624] = 2, [9625] = 3, [9626] = 4, [9627] = 5,
    -- TWW / Midnight additional sets
    [10249] = 1, [10250] = 2, [10251] = 3, [10252] = 4, [10253] = 5,
    [10254] = 1, [10255] = 2, [10256] = 3, [10257] = 4, [10258] = 5,
    [10421] = 1, [10422] = 2, [10423] = 3, [10424] = 4, [10425] = 5,
    -- More potential sets from later patches
    [10876] = 1, [10877] = 2, [10878] = 3, [10879] = 4, [10880] = 5,
    [11081] = 1, [11082] = 2, [11083] = 3, [11084] = 4, [11085] = 5,
}

-- Items that use different item IDs for ranks instead of bonus IDs
-- Maps itemID -> quality tier (Midnight consumables: Silver=tier 2, Gold=tier 3)
local ITEM_ID_QUALITY = {
    -- Thalassian Phoenix Oil (Rank 1 = Silver, Rank 2 = Gold)
    [243733] = 2,  -- Thalassian Phoenix Oil Rank 1 (Silver)
    [243734] = 3,  -- Thalassian Phoenix Oil Rank 2 (Gold)
    -- Refulgent Whetstone
    [237370] = 2,  -- Refulgent Whetstone Rank 1 (Silver)
    [237371] = 3,  -- Refulgent Whetstone Rank 2 (Gold)
    -- Midnight Flasks (Rank 1 = Silver, Rank 2 = Gold)
    [241327] = 2,  -- Flask of the Shattered Sun R1 (Silver)
    [241326] = 3,  -- Flask of the Shattered Sun R2 (Gold)
    [241323] = 2,  -- Flask of the Magisters R1 (Silver)
    [241322] = 3,  -- Flask of the Magisters R2 (Gold)
    [241321] = 2,  -- Flask of Thalassian Resistance R1 (Silver)
    [241320] = 3,  -- Flask of Thalassian Resistance R2 (Gold)
    [241324] = 3,  -- Flask of the Blood Knights (Gold)
    [241325] = 2,  -- Flask of the Blood Knights (Silver)
}

-- Stat labels for consumables — shown in the settings Items tab next to the item name.
-- Edit these if the expansion renames or rebalances the stats.
local CONSUMABLE_STAT_LABELS = {
    -- Flasks
    [241327] = "+Crit",  [241326] = "+Crit",   -- Flask of the Shattered Sun (R1/R2)
    [241323] = "+Mastery",       [241322] = "+Mastery",        -- Flask of the Magisters (R1/R2)
    [241321] = "+Vers",      [241320] = "+Vers",       -- Flask of Thalassian Resistance (R1/R2)
    [241324] = "+Haste",      [241325] = "+Haste",       -- Flask of the Blood Knights (R1/R2)
}

-- Hearty food item IDs (persist through death — shown with "H" badge on HUD buttons)
local HEARTY_FOOD_IDS = {
    [266996] = true,  -- Hearty Harandar Celebration
    [268679] = true,  -- Hearty Impossibly Royal Roast
    [242747] = true,  -- Hearty Royal Roast
    [268680] = true,  -- Hearty Flora Frenzy
    [242746] = true,  -- Hearty Champion's Bento
    [266985] = true,  -- Hearty Silvermoon Parade
    [242745] = true,  -- Hearty Blooming Feast
    [242744] = true,  -- Hearty Quel'dorei Medley
    [242749] = true,  -- Hearty Crimson Calamari
}

-- Parse crafted quality from item link bonus IDs
local function ParseQualityFromLink(itemLink)
    if not itemLink then return nil end
    -- Extract the item string from the link
    local itemString = itemLink:match("item[%-?%d:]+")
    if not itemString then return nil end
    -- Split by colon and check bonus IDs
    for bonusID in itemString:gmatch(":(%d+)") do
        local quality = QUALITY_BONUS_IDS[tonumber(bonusID)]
        if quality then
            return quality
        end
    end
    return nil
end

-- Try to get crafted quality using multiple methods
local function GetCraftedQuality(itemLink, craftingQuality)
    -- Method 1: Direct craftingQuality from container info
    if craftingQuality and craftingQuality > 0 then
        return craftingQuality
    end
    
    if not itemLink then return nil end
    
    -- Method 2: C_TradeSkillUI API
    if C_TradeSkillUI and C_TradeSkillUI.GetItemCraftedQualityByItemInfo then
        local quality = C_TradeSkillUI.GetItemCraftedQualityByItemInfo(itemLink)
        if quality and quality > 0 then
            return quality
        end
    end
    
    -- Method 3: Parse item link for quality bonus IDs
    local parsedQuality = ParseQualityFromLink(itemLink)
    if parsedQuality then
        return parsedQuality
    end
    
    -- Method 4: Check hardcoded item ID -> quality mapping (for items with rank variants)
    local itemID = itemLink:match("item:(%d+)")
    if itemID then
        itemID = tonumber(itemID)
        local hardcodedQuality = ITEM_ID_QUALITY[itemID]
        if hardcodedQuality then
            return hardcodedQuality
        end
    end
    
    return nil
end


-- Get crafted quality from item link (for config panel)
-- craftingQuality is optional fallback from C_Container.GetContainerItemInfo
local function GetConfigItemQuality(itemLink, craftingQuality)
    return GetCraftedQuality(itemLink, craftingQuality)
end

-- Create a single item row with icon, name, checkbox, and min duration
---@param parent table
---@param yOffset number
---@param itemID number|string  item IDs are numbers; spell rows pass the spell ID
---@param itemType string  "item" or "spell"
---@param className string?
---@param category string?
---@param showMinDuration boolean?
---@param soundSpellID number?
function BH:CreateItemRow(parent, yOffset, itemID, itemType, className, category, showMinDuration, soundSpellID)
    local rowHeight = soundSpellID and 56 or 30
    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(380, rowHeight)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, yOffset)
    
    -- Checkbox (styled to match other tabs)
    -- Use TOPLEFT anchor so content stays pinned to the top of the row for any height.
    -- For 30px rows: center lands at y=-15, identical to the old LEFT(4,0) centering.
    -- For taller sound rows: icon stays near the top rather than shifting to mid-row.
    local checkContainer = CreateFrame("Frame", nil, row)
    checkContainer:SetSize(16, 16)
    checkContainer:SetPoint("TOPLEFT", row, "TOPLEFT", 4, -7)

    local checkbox = CreateFrame("CheckButton", nil, checkContainer)
    checkbox:SetSize(16, 16)
    checkbox:SetPoint("CENTER")

    local boxBG = checkbox:CreateTexture(nil, "BACKGROUND")
    boxBG:SetAllPoints()
    boxBG:SetColorTexture(SQ_COLORS.control[1], SQ_COLORS.control[2], SQ_COLORS.control[3], 1)

    local boxBorder = CreateFrame("Frame", nil, checkbox, "BackdropTemplate")
    boxBorder:SetAllPoints()
    boxBorder:SetBackdrop({
        edgeFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeSize = 1,
    })
    boxBorder:SetBackdropBorderColor(SQ_COLORS.border[1], SQ_COLORS.border[2], SQ_COLORS.border[3], 0.8)

    local check = checkbox:CreateTexture(nil, "OVERLAY")
    check:SetSize(12, 12)
    check:SetPoint("CENTER")
    ns.ApplyAccent(check, "texture", 0.9)
    checkbox:SetCheckedTexture(check)

    checkbox:SetChecked(self:IsEnabled(itemID))
    checkbox:SetScript("OnClick", function(self)
        BH.disabled[itemID] = not self:GetChecked()
        BH:SaveSettings()
        BH:UpdateButtons()
    end)
    checkbox:SetScript("OnEnter", function()
        do local ar, ag, ab = ns.GetAccentColor(); boxBorder:SetBackdropBorderColor(ar, ag, ab, 0.6) end
    end)
    checkbox:SetScript("OnLeave", function()
        boxBorder:SetBackdropBorderColor(SQ_COLORS.border[1], SQ_COLORS.border[2], SQ_COLORS.border[3], 0.8)
    end)
    
    -- Icon
    local icon = row:CreateTexture(nil, "ARTWORK")
    icon:SetSize(24, 24)
    icon:SetPoint("LEFT", checkContainer, "RIGHT", 8, 0)
    
    -- Name
    local nameText = row:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    nameText:SetPoint("LEFT", icon, "RIGHT", 8, 0)
    nameText:SetWidth(150)
    nameText:SetJustifyH("LEFT")
    
    -- Quality pip texture (shown next to name for crafted items)
    local qualityPip = row:CreateTexture(nil, "ARTWORK")
    qualityPip:SetSize(24, 24)
    qualityPip:SetPoint("LEFT", nameText, "RIGHT", 2, 0)
    qualityPip:Hide()  -- Hidden by default, shown if item has quality
    
    -- Min Duration editbox with label
    local minLabel = row:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    minLabel:SetPoint("LEFT", qualityPip, "RIGHT", 5, 0)
    minLabel:SetText("Min:")
    minLabel:SetTextColor(0.7, 0.7, 0.7)
    
    local minEdit = CreateSQEditBox(row, 32, 18, {
        numeric = true, maxLetters = 2, justifyH = "CENTER",
    })
    minEdit:SetPoint("LEFT", minLabel, "RIGHT", 2, 0)
    minEdit:SetText(tostring(self:GetMinDuration(itemID)))
    -- Commit on focus lost as well as on Enter. Every other edit box in the
    -- addon saves without Enter (OnTextChanged here, an explicit
    -- OnEditFocusLost in the Kelerts tab), so an Enter-only box reads as
    -- broken: typing 20 and clicking away discarded it, and the next row.Sync
    -- repainted the stored value -- reported as "it won't save, it keeps
    -- reverting to 30".
    local function CommitMin(box)
        local text = box:GetText()
        if text == "" then
            -- Cleared and clicked away. Treat that as "no change" rather than
            -- as 0, which is a real setting ("only show when missing") and not
            -- what an empty box means.
            box:SetText(tostring(BH:GetMinDuration(itemID)))
            return
        end
        local value = math.max(0, math.min(60, tonumber(text) or 0))
        box:SetText(tostring(value))
        BH:SetMinDuration(itemID, value)
        BH:SaveSettings()
        BH:UpdateButtons()
    end
    minEdit:SetScript("OnEnterPressed", function(self)
        CommitMin(self)
        self:ClearFocus()
    end)
    minEdit:SetScript("OnEscapePressed", function(self)
        self:SetText(tostring(BH:GetMinDuration(itemID)))
        self:ClearFocus()
    end)

    -- Scroll to nudge the value, but only while the box has focus.
    --
    -- These rows live in a scrolling list, and a frame with EnableMouseWheel
    -- swallows the wheel rather than passing it up -- so a box that listened
    -- all the time would silently rewrite a threshold whenever someone scrolled
    -- the list with the cursor over it. Requiring focus first makes the wheel
    -- something you opt into by clicking in, and leaves list scrolling alone
    -- everywhere else.
    minEdit:SetScript("OnMouseWheel", function(self, delta)
        local step = IsShiftKeyDown() and 5 or 1
        local current = tonumber(self:GetText()) or BH:GetMinDuration(itemID)
        self:SetText(tostring(math.max(0, math.min(60, current + delta * step))))
        CommitMin(self)
    end)

    -- onFocusLost/onFocusGained rather than SetScript: the widget's own focus
    -- scripts own the border colour. See CreateSQEditBox.
    minEdit.onFocusGained = function(self) self:EnableMouseWheel(true) end
    minEdit.onFocusLost = function(self)
        self:EnableMouseWheel(false)
        CommitMin(self)
    end
    minEdit.onEnter = function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Min minutes remaining")
        GameTooltip:AddLine("Show button when buff has less than this many minutes left.", 1, 1, 1, true)
        GameTooltip:AddLine("0 = only show when buff is missing", 0.7, 0.7, 0.7, true)
        GameTooltip:AddLine("Click in, then scroll to adjust (Shift for 5).", 0.7, 0.7, 0.7, true)
        GameTooltip:Show()
    end
    minEdit.onLeave = function() GameTooltip:Hide() end
    
    local minSuffix = row:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    minSuffix:SetPoint("LEFT", minEdit, "RIGHT", 2, 0)
    minSuffix:SetText("m")
    minSuffix:SetTextColor(0.7, 0.7, 0.7)
    
    -- Hide min duration for class buffs (spell type) - not applicable
    -- Exception: timed class buffs (e.g. Rogue poisons, self shields) do have durations
    if itemType == "spell" and not showMinDuration then
        minLabel:Hide()
        minEdit:Hide()
        minSuffix:Hide()
    end
    
    -- Delete button for custom items
    if category and self:IsCustomItem(category, itemID) then
        local deleteBtn = CreateFrame("Button", nil, row)
        deleteBtn:SetSize(20, 20)
        deleteBtn:SetPoint("RIGHT", row, "RIGHT", -5, 0)
        deleteBtn:SetNormalTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Up")
        deleteBtn:SetHighlightTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Highlight")
        deleteBtn:SetScript("OnClick", function()
            local success, err = BH:RemoveCustomItem(category, itemID)
            if success then
                BH:RefreshItemList()
                print("Squizzumables: Item removed")
            else
                print("Squizzumables: " .. (err or "Cannot remove item"))
            end
        end)
        deleteBtn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText("Remove this item")
            GameTooltip:Show()
        end)
        deleteBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end
    
    -- Load item info async
    if itemType == "item" then
        -- Set icon immediately if available
        local itemIcon = C_Item.GetItemIconByID(itemID)
        if itemIcon then
            icon:SetTexture(itemIcon)
        else
            icon:SetTexture(134400) -- Question mark icon as placeholder
        end
        
        -- Check for crafted quality by finding item in bags
        local itemLink, craftingQuality = FindItemInBags(itemID)
        if itemLink or craftingQuality then
            local quality = GetConfigItemQuality(itemLink, craftingQuality)
            if quality and quality > 0 and CONFIG_QUALITY_ATLAS[quality] then
                qualityPip:SetAtlas(CONFIG_QUALITY_ATLAS[quality])
                qualityPip:Show()
            end
        end
        
        -- Stat suffix for settings display (e.g. "Flask of the Magisters (Int)")
        local statSuffix = CONSUMABLE_STAT_LABELS and CONSUMABLE_STAT_LABELS[itemID]
        local function WithStatLabel(name)
            return statSuffix and (name .. " (" .. statSuffix .. ")") or name
        end
        -- Try to get item name synchronously first
        local itemName = C_Item.GetItemNameByID(itemID)
        if itemName then
            nameText:SetText(WithStatLabel(itemName))
        else
            -- Set temporary text showing item ID
            nameText:SetText("Item ID: " .. itemID)
            
            -- Try C_Item.GetItemInfo to trigger cache request (returns nil if not cached)
            local name, _, _, _, _, _, _, _, _, itemTexture = C_Item.GetItemInfo(itemID)
            if name then
                nameText:SetText(WithStatLabel(name))
                if itemTexture then
                    icon:SetTexture(itemTexture)
                end
            else
                -- Request item data and use callback. Item rows always carry a
                -- numeric ID; the string half of itemID belongs to spell rows.
                local item = Item:CreateFromItemID(tonumber(itemID) or 0)
                if item and not item:IsItemEmpty() then
                    item:ContinueOnItemLoad(function()
                        local loadedName = item:GetItemName()
                        if loadedName then
                            nameText:SetText(WithStatLabel(loadedName))
                        end
                        local loadedIcon = C_Item.GetItemIconByID(itemID)
                        if loadedIcon then
                            icon:SetTexture(loadedIcon)
                        end
                    end)
                end
            end
        end
    elseif itemType == "spell" then
        local spellIcon = nil
        local spellName = nil
        local info = C_Spell.GetSpellInfo(itemID)
        if info then
            spellIcon = info.iconID
            spellName = info.name
        end
        icon:SetTexture(spellIcon or 134400)
        -- Show class name prefix if provided
        if className then
            nameText:SetText(className .. ": " .. (spellName or ("Spell " .. itemID)))
        else
            nameText:SetText(spellName or ("Spell: " .. itemID))
        end
    end

    -- Re-apply the parts of this row that can change between refreshes, so
    -- BH:RefreshItemList can reuse a cached row instead of building a new one.
    -- (WoW frames are never garbage collected, so rebuilding the list leaked a
    -- full set of frames on every /sq config.)
    --
    -- Everything not touched here is fixed for the row's identity: the row is
    -- cached under itemID + itemType + category, so the spell name/icon, the
    -- label text and the widget layout can never change for a given cached row.
    row.Sync = function()
        checkbox:SetChecked(BH:IsEnabled(itemID))
        if not minEdit:HasFocus() then
            minEdit:SetText(tostring(BH:GetMinDuration(itemID)))
        end
        if itemType == "item" then
            -- Crafted quality comes from the stack currently in bags, so it can
            -- differ from one refresh to the next (e.g. R2 flasks replacing R1).
            qualityPip:Hide()
            local link, quality = FindItemInBags(itemID)
            if link or quality then
                local q = GetConfigItemQuality(link, quality)
                if q and q > 0 and CONFIG_QUALITY_ATLAS[q] then
                    qualityPip:SetAtlas(CONFIG_QUALITY_ATLAS[q])
                    qualityPip:Show()
                end
            end
            -- If the item name was still uncached when this row was built, the
            -- label is a placeholder; retry now that it may have arrived.
            local shown = nameText:GetText()
            if shown and shown:find("^Item ID: ") then
                local itemName = C_Item.GetItemNameByID(itemID)
                if itemName then
                    local suffix = CONSUMABLE_STAT_LABELS and CONSUMABLE_STAT_LABELS[itemID]
                    nameText:SetText(suffix and (itemName .. " (" .. suffix .. ")") or itemName)
                    local ic = C_Item.GetItemIconByID(itemID)
                    if ic then icon:SetTexture(ic) end
                end
            end
        end
    end

    -- Sound dropdown for class buff rows (second line)
    -- x=28 aligns "Sound:" with the left edge of the icon above (checkContainer=4+16, icon offset=+8)
    if soundSpellID then
        local soundLbl = row:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        -- Icon bottom is at y=-27 (checkContainer at TOPLEFT(4,-7), icon 24px centered at y=-15).
        -- Sound row starts at y=-34 giving a clean 7px gap below the icon.
        -- CreateSQDropdown with empty label: btn appears at container_y - 4  (label has 0 height).
        soundLbl:SetPoint("TOPLEFT", row, "TOPLEFT", 28, -34)
        soundLbl:SetText("Sound:")
        soundLbl:SetTextColor(0.6, 0.6, 0.6)

        local sndDD = CreateSQDropdown(row, "", 220, BuildSoundDropdownItems(), function(value)
            BH.settings.classBuffSounds = BH.settings.classBuffSounds or {}
            BH.settings.classBuffSounds[soundSpellID] = value
            BH:SaveSettings()
        end)
        sndDD:SetPoint("TOPLEFT", row, "TOPLEFT", 74, -27)
        local curSnd = BH.settings and BH.settings.classBuffSounds and BH.settings.classBuffSounds[soundSpellID] or "None"
        sndDD:SetSelectedValue(curSnd)

        -- Icon-only play button using the built-in WoW VoiceChat-Speaker texture
        local sndPreviewBtn = CreateFrame("Button", nil, row)
        sndPreviewBtn:SetSize(22, 22)
        sndPreviewBtn:SetPoint("TOPLEFT", row, "TOPLEFT", 298, -31)
        local normalTex = sndPreviewBtn:CreateTexture(nil, "BACKGROUND")
        normalTex:SetAllPoints()
        normalTex:SetTexture("Interface\\Common\\VoiceChat-Speaker")
        local highlightTex = sndPreviewBtn:CreateTexture(nil, "HIGHLIGHT")
        highlightTex:SetAllPoints()
        highlightTex:SetTexture("Interface\\Common\\VoiceChat-Speaker")
        highlightTex:SetAlpha(0.6)
        sndPreviewBtn:SetScript("OnEnter", function(self) normalTex:SetAlpha(0.7) end)
        sndPreviewBtn:SetScript("OnLeave", function(self) normalTex:SetAlpha(1.0) end)
        sndPreviewBtn:SetScript("OnClick", function()
            local snd = BH.settings and BH.settings.classBuffSounds and BH.settings.classBuffSounds[soundSpellID] or "None"
            PlaySQSound(snd)
        end)
    end

    return row
end

-- Refresh the item list in the scroll frame
function BH:RefreshItemList()
    -- Hide everything from the previous pass; widgets we still need get
    -- re-acquired and re-anchored below. See BH:AcquireWidget — rebuilding
    -- these rows used to leak a full set of frames on every refresh.
    self:ResetWidgetCache("itemRowCache")

    local yOffset = 0
    local rowHeight = 32

    -- Helper to add category header
    local function AddHeader(text)
        local headerFrame, isNew = self:AcquireWidget("itemRowCache", "header:" .. text, function()
            local f = CreateFrame("Frame", nil, self.scrollChild)
            f:SetSize(380, 20)
            return f
        end)
        headerFrame:Show()
        headerFrame:SetPoint("TOPLEFT", self.scrollChild, "TOPLEFT", 0, yOffset)
        if not isNew then
            yOffset = yOffset - 25
            return
        end
        local header = headerFrame:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
        header:SetPoint("LEFT", headerFrame, "LEFT", 5, 0)
        header:SetText(text)
        yOffset = yOffset - 25
    end

    -- Helper to create drop zone for adding items
    local function AddDropZone(category, categoryName)
        local dropFrame, isNew = self:AcquireWidget("itemRowCache", "drop:" .. category, function()
            local f = CreateFrame("Button", nil, self.scrollChild)
            f:SetSize(370, 28)
            return f
        end)
        dropFrame:Show()
        dropFrame:SetPoint("TOPLEFT", self.scrollChild, "TOPLEFT", 5, yOffset)
        if not isNew then
            yOffset = yOffset - 32
            return
        end

        -- Background
        local bg = dropFrame:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0.2, 0.4, 0.2, 0.3)
        dropFrame.bg = bg
        
        -- Simple border using textures
        local borderTop = dropFrame:CreateTexture(nil, "BORDER")
        borderTop:SetColorTexture(0.4, 0.6, 0.4, 0.8)
        borderTop:SetHeight(1)
        borderTop:SetPoint("TOPLEFT", dropFrame, "TOPLEFT", 0, 0)
        borderTop:SetPoint("TOPRIGHT", dropFrame, "TOPRIGHT", 0, 0)
        
        local borderBottom = dropFrame:CreateTexture(nil, "BORDER")
        borderBottom:SetColorTexture(0.4, 0.6, 0.4, 0.8)
        borderBottom:SetHeight(1)
        borderBottom:SetPoint("BOTTOMLEFT", dropFrame, "BOTTOMLEFT", 0, 0)
        borderBottom:SetPoint("BOTTOMRIGHT", dropFrame, "BOTTOMRIGHT", 0, 0)
        
        local borderLeft = dropFrame:CreateTexture(nil, "BORDER")
        borderLeft:SetColorTexture(0.4, 0.6, 0.4, 0.8)
        borderLeft:SetWidth(1)
        borderLeft:SetPoint("TOPLEFT", dropFrame, "TOPLEFT", 0, 0)
        borderLeft:SetPoint("BOTTOMLEFT", dropFrame, "BOTTOMLEFT", 0, 0)
        
        local borderRight = dropFrame:CreateTexture(nil, "BORDER")
        borderRight:SetColorTexture(0.4, 0.6, 0.4, 0.8)
        borderRight:SetWidth(1)
        borderRight:SetPoint("TOPRIGHT", dropFrame, "TOPRIGHT", 0, 0)
        borderRight:SetPoint("BOTTOMRIGHT", dropFrame, "BOTTOMRIGHT", 0, 0)
        
        -- Text
        local text = dropFrame:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        text:SetPoint("CENTER")
        text:SetText("+ Drag " .. categoryName .. " item here to add")
        text:SetTextColor(0.7, 1, 0.7)
        
        -- Handle item drops
        dropFrame:SetScript("OnReceiveDrag", function()
            local infoType, itemID = GetCursorInfo()
            if infoType == "item" and itemID then
                local success, err = BH:AddCustomItem(category, itemID)
                if success then
                    ClearCursor()
                    BH:RefreshItemList()
                    print("Squizzumables: Added item to " .. categoryName)
                else
                    print("Squizzumables: " .. (err or "Could not add item"))
                end
            end
        end)
        
        dropFrame:SetScript("OnClick", function(self)
            local infoType, itemID = GetCursorInfo()
            if infoType == "item" and itemID then
                local success, err = BH:AddCustomItem(category, itemID)
                if success then
                    ClearCursor()
                    BH:RefreshItemList()
                    print("Squizzumables: Added item to " .. categoryName)
                else
                    print("Squizzumables: " .. (err or "Could not add item"))
                end
            end
        end)
        
        -- Visual feedback on hover with item
        dropFrame:SetScript("OnEnter", function(self)
            local infoType = GetCursorInfo()
            if infoType == "item" then
                self.bg:SetColorTexture(0.3, 0.6, 0.3, 0.5)
            end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText("Drop an item here to add it to " .. categoryName)
            GameTooltip:Show()
        end)
        
        dropFrame:SetScript("OnLeave", function(self)
            self.bg:SetColorTexture(0.2, 0.4, 0.2, 0.3)
            GameTooltip:Hide()
        end)
        
        yOffset = yOffset - 32
    end

    -- Acquire (or build) the row for one consumable, re-anchoring and re-syncing
    -- it rather than rebuilding. Keyed by category + itemID: within a category an
    -- item is always rendered the same way, so a cached row is always valid.
    ---@param itemID number
    ---@param category string
    local function AddItemRow(itemID, category)
        local row, isNew = self:AcquireWidget("itemRowCache", category .. ":" .. itemID, function()
            return self:CreateItemRow(self.scrollChild, yOffset, itemID, "item", nil, category)
        end)
        row:Show()
        row:SetPoint("TOPLEFT", self.scrollChild, "TOPLEFT", 0, yOffset)
        if not isNew and row.Sync then row.Sync() end
        yOffset = yOffset - rowHeight
    end
    
    -- Food section - only show items in bags that meet level requirement
    AddHeader("Food")
    if self.consumables and self.consumables.food then
        for _, itemID in ipairs(self.consumables.food) do
            if FindItemInBags(itemID) and ConfigMeetsLevelRequirement(itemID) then
                AddItemRow(itemID, "food")
            end
        end
    end
    AddDropZone("food", "Food")
    yOffset = yOffset - 5
    
    -- Flask section - only show items in bags that meet level requirement
    AddHeader("Flasks")
    if self.consumables and self.consumables.flask then
        for _, itemID in ipairs(self.consumables.flask) do
            if FindItemInBags(itemID) and ConfigMeetsLevelRequirement(itemID) then
                AddItemRow(itemID, "flask")
            end
        end
    end
    AddDropZone("flask", "Flask")
    yOffset = yOffset - 5
    
    -- Oil section - only show items in bags that meet level requirement
    AddHeader("Weapon Oils")
    if self.consumables and self.consumables.oil then
        for _, itemID in ipairs(self.consumables.oil) do
            if FindItemInBags(itemID) and ConfigMeetsLevelRequirement(itemID) then
                AddItemRow(itemID, "oil")
            end
        end
    end
    AddDropZone("oil", "Weapon Oil")
    yOffset = yOffset - 5

    -- Augment rune section - only show items in bags that meet level requirement
    AddHeader("Augment Runes")
    if self.consumables and self.consumables.augmentRune then
        for _, itemID in ipairs(self.consumables.augmentRune) do
            if FindItemInBags(itemID) and ConfigMeetsLevelRequirement(itemID) then
                AddItemRow(itemID, "augmentRune")
            end
        end
    end
    AddDropZone("augmentRune", "Augment Rune")
    yOffset = yOffset - 5

    -- Emerald Coach's Whistle section.
    -- Only rendered while the whistle is equipped, and its contents never vary,
    -- so it is built once and thereafter only re-anchored and re-synced. The
    -- five top-level widgets are kept in self.coachSectionWidgets in layout
    -- order, each with the vertical space it consumes.
    if (GetInventoryItemID("player", 13) == COACH_WHISTLE_ITEM_ID
        or GetInventoryItemID("player", 14) == COACH_WHISTLE_ITEM_ID) then

      if self.coachSectionWidgets then
        -- Already built: re-anchor in order and re-sync the values that can
        -- have changed (a profile switch rewrites all four settings).
        for _, entry in ipairs(self.coachSectionWidgets) do
            local widget, height, indent = entry[1], entry[2], entry[3]
            widget:Show()
            widget:ClearAllPoints()
            widget:SetPoint("TOPLEFT", self.scrollChild, "TOPLEFT", indent, yOffset)
            yOffset = yOffset - height
        end
        if self.itemsCoachEnableCb then
            self.itemsCoachEnableCb:SetChecked(BH.settings and BH.settings.coachWhistleReminderEnabled ~= false)
        end
        if self.itemsCoachMinEdit and not self.itemsCoachMinEdit:HasFocus() then
            self.itemsCoachMinEdit:SetText(tostring(BH:GetMinDuration(COACH_WHISTLE_ITEM_ID)))
        end
        if self.itemsCoachScaleSlider then
            self.itemsCoachScaleSlider:SetValue((BH.settings and BH.settings.coachWhistleReminderScale or 1.0) * 100)
        end
        if self.itemsCoachLockCb then
            self.itemsCoachLockCb:SetChecked(BH.settings and BH.settings.coachWhistleReminderLocked or false)
        end
      else
        self.coachSectionWidgets = {}
        local coachWidgets = self.coachSectionWidgets

        local hdr = self.scrollChild:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
        hdr:SetPoint("TOPLEFT", self.scrollChild, "TOPLEFT", 5, yOffset)
        hdr:SetText("Emerald Coach's Whistle")
        coachWidgets[#coachWidgets + 1] = { hdr, 25, 5 }
        yOffset = yOffset - 25

        -- Enable reminder checkbox
        local coachEnableRow = CreateFrame("Frame", nil, self.scrollChild)
        coachEnableRow:SetSize(380, 24)
        coachEnableRow:SetPoint("TOPLEFT", self.scrollChild, "TOPLEFT", 0, yOffset)
        coachWidgets[#coachWidgets + 1] = { coachEnableRow, 30, 0 }

        local coachEnableCb = CreateFrame("CheckButton", nil, coachEnableRow)
        coachEnableCb:SetSize(16, 16)
        coachEnableCb:SetPoint("LEFT", coachEnableRow, "LEFT", 4, 0)
        local cbBG = coachEnableCb:CreateTexture(nil, "BACKGROUND")
        cbBG:SetAllPoints(); cbBG:SetColorTexture(SQ_COLORS.control[1], SQ_COLORS.control[2], SQ_COLORS.control[3], 1)
        local cbBorder = CreateFrame("Frame", nil, coachEnableCb, "BackdropTemplate")
        cbBorder:SetAllPoints()
        cbBorder:SetBackdrop({ edgeFile = "Interface\\BUTTONS\\WHITE8X8", edgeSize = 1 })
        cbBorder:SetBackdropBorderColor(SQ_COLORS.border[1], SQ_COLORS.border[2], SQ_COLORS.border[3], 0.8)
        local cbCheck = coachEnableCb:CreateTexture(nil, "OVERLAY")
        cbCheck:SetSize(12, 12); cbCheck:SetPoint("CENTER")
        ns.ApplyAccent(cbCheck, "texture", 0.9)
        coachEnableCb:SetCheckedTexture(cbCheck)
        coachEnableCb:SetChecked(BH.settings and BH.settings.coachWhistleReminderEnabled ~= false)
        coachEnableCb:SetScript("OnClick", function(self)
            BH.settings.coachWhistleReminderEnabled = self:GetChecked()
            BH:SaveSettings()
            BH:UpdateCoachWhistleReminder()
        end)
        self.itemsCoachEnableCb = coachEnableCb

        local coachEnableLbl = coachEnableRow:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        coachEnableLbl:SetPoint("LEFT", coachEnableCb, "RIGHT", 8, 0)
        coachEnableLbl:SetText("Enable Coach's Whistle Reminder")
        yOffset = yOffset - 30

        -- Min duration row
        local coachMinRow = CreateFrame("Frame", nil, self.scrollChild)
        coachMinRow:SetSize(380, 24)
        coachMinRow:SetPoint("TOPLEFT", self.scrollChild, "TOPLEFT", 0, yOffset)
        coachWidgets[#coachWidgets + 1] = { coachMinRow, 30, 0 }

        local coachMinLbl = coachMinRow:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        coachMinLbl:SetPoint("LEFT", coachMinRow, "LEFT", 28, 0)
        coachMinLbl:SetText("Min remaining (0–60 min):")
        coachMinLbl:SetTextColor(0.7, 0.7, 0.7)

        local coachMinEdit = CreateSQEditBox(coachMinRow, 32, 18, {
            numeric = true, maxLetters = 2, justifyH = "CENTER",
        })
        coachMinEdit:SetPoint("LEFT", coachMinLbl, "RIGHT", 4, 0)
        coachMinEdit:SetText(tostring(BH:GetMinDuration(COACH_WHISTLE_ITEM_ID)))
        -- Same commit-on-focus-lost contract as the per-item Min boxes above.
        local function CommitCoachMin(box)
            local text = box:GetText()
            if text == "" then
                box:SetText(tostring(BH:GetMinDuration(COACH_WHISTLE_ITEM_ID)))
                return
            end
            local v = math.max(0, math.min(60, tonumber(text) or 0))
            box:SetText(tostring(v))
            BH:SetMinDuration(COACH_WHISTLE_ITEM_ID, v)
            BH:SaveSettings()
            BH:UpdateButtons()
        end
        coachMinEdit:SetScript("OnEnterPressed", function(self)
            CommitCoachMin(self)
            self:ClearFocus()
        end)
        coachMinEdit:SetScript("OnEscapePressed", function(self)
            self:SetText(tostring(BH:GetMinDuration(COACH_WHISTLE_ITEM_ID)))
            self:ClearFocus()
        end)
        -- Wheel only while focused, for the same reason as the item rows.
        coachMinEdit:SetScript("OnMouseWheel", function(self, delta)
            local step = IsShiftKeyDown() and 5 or 1
            local current = tonumber(self:GetText()) or BH:GetMinDuration(COACH_WHISTLE_ITEM_ID)
            self:SetText(tostring(math.max(0, math.min(60, current + delta * step))))
            CommitCoachMin(self)
        end)
        coachMinEdit.onFocusGained = function(self) self:EnableMouseWheel(true) end
        coachMinEdit.onFocusLost = function(self)
            self:EnableMouseWheel(false)
            CommitCoachMin(self)
        end
        coachMinEdit.onEnter = function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText("Min minutes remaining")
            GameTooltip:AddLine("Re-show the button when the Coached buff has less than this many minutes left.", 1, 1, 1, true)
            GameTooltip:AddLine("0 = only show when no ally is coached yet", 0.7, 0.7, 0.7, true)
            GameTooltip:AddLine("Click in, then scroll to adjust (Shift for 5).", 0.7, 0.7, 0.7, true)
            GameTooltip:Show()
        end
        coachMinEdit.onLeave = function() GameTooltip:Hide() end
        self.itemsCoachMinEdit = coachMinEdit

        local coachMinSfx = coachMinRow:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        coachMinSfx:SetPoint("LEFT", coachMinEdit, "RIGHT", 2, 0)
        coachMinSfx:SetText("m")
        coachMinSfx:SetTextColor(0.7, 0.7, 0.7)
        yOffset = yOffset - 30

        -- Scale slider row
        local coachScaleSlider = CreateSQSlider(self.scrollChild, "Reminder Scale", 300, 50, 200, 5)
        coachScaleSlider:SetPoint("TOPLEFT", self.scrollChild, "TOPLEFT", 4, yOffset)
        coachScaleSlider:SetValue((BH.settings and BH.settings.coachWhistleReminderScale or 1.0) * 100)
        coachScaleSlider:SetAfterValueChanged(function(value)
            BH.settings.coachWhistleReminderScale = value / 100
            BH:SaveSettings()
            if BH.coachWhistleReminderFrame then BH.coachWhistleReminderFrame:SetScale(value / 100) end
        end)
        coachWidgets[#coachWidgets + 1] = { coachScaleSlider, 50, 4 }
        self.itemsCoachScaleSlider = coachScaleSlider
        yOffset = yOffset - 50

        -- Lock checkbox row
        local coachLockRow = CreateFrame("Frame", nil, self.scrollChild)
        coachLockRow:SetSize(380, 24)
        coachLockRow:SetPoint("TOPLEFT", self.scrollChild, "TOPLEFT", 0, yOffset)
        coachWidgets[#coachWidgets + 1] = { coachLockRow, 30, 0 }

        local coachLockCb = CreateFrame("CheckButton", nil, coachLockRow)
        coachLockCb:SetSize(16, 16)
        coachLockCb:SetPoint("LEFT", coachLockRow, "LEFT", 4, 0)
        local clBG = coachLockCb:CreateTexture(nil, "BACKGROUND")
        clBG:SetAllPoints(); clBG:SetColorTexture(SQ_COLORS.control[1], SQ_COLORS.control[2], SQ_COLORS.control[3], 1)
        local clBorder = CreateFrame("Frame", nil, coachLockCb, "BackdropTemplate")
        clBorder:SetAllPoints()
        clBorder:SetBackdrop({ edgeFile = "Interface\\BUTTONS\\WHITE8X8", edgeSize = 1 })
        clBorder:SetBackdropBorderColor(SQ_COLORS.border[1], SQ_COLORS.border[2], SQ_COLORS.border[3], 0.8)
        local clCheck = coachLockCb:CreateTexture(nil, "OVERLAY")
        clCheck:SetSize(12, 12); clCheck:SetPoint("CENTER")
        ns.ApplyAccent(clCheck, "texture", 0.9)
        coachLockCb:SetCheckedTexture(clCheck)
        coachLockCb:SetChecked(BH.settings and BH.settings.coachWhistleReminderLocked or false)
        coachLockCb:SetScript("OnClick", function(self)
            BH.settings.coachWhistleReminderLocked = self:GetChecked()
            BH:SaveSettings()
            if BH.coachWhistleReminderFrame then
                BH.coachWhistleReminderFrame:SetMovable(not self:GetChecked())
                BH.coachWhistleReminderFrame:EnableMouse(not self:GetChecked())
            end
        end)
        self.itemsCoachLockCb = coachLockCb

        local coachLockLbl = coachLockRow:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        coachLockLbl:SetPoint("LEFT", coachLockCb, "RIGHT", 8, 0)
        coachLockLbl:SetText("Lock Position")
        yOffset = yOffset - 30
      end
    end

    -- Update scroll child height
    self.scrollChild:SetHeight(math.abs(yOffset) + 20)
end

-- For Reminders/Helpers.lua, which re-declares them under the same names.
BH.ITEM_ID_QUALITY        = ITEM_ID_QUALITY
BH.ParseQualityFromLink   = ParseQualityFromLink
BH.HEARTY_FOOD_IDS        = HEARTY_FOOD_IDS
BH.CONSUMABLE_STAT_LABELS = CONSUMABLE_STAT_LABELS
