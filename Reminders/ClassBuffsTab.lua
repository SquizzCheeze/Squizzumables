-- Reminders/ClassBuffsTab.lua
-- The Class Buffs options page: your class's buffs, imbues and runes, each
-- with its own toggle and sound.
--
-- Moved out of Squizzumables.lua unchanged in 2.0 phase 2 (the split). It
-- reaches the core only through BH; BH.CLASS_NAMES is published from here,
-- as before (Core/Welcome.lua reads it at runtime).

local addonName, ns = ...
local BH = ns.BH

local SQ_COLORS        = ns.SQ_COLORS

-- ============================================================================
-- Class Buffs Tab
-- ============================================================================

local CLASS_NAMES = {
    PRIEST = "Priest", MAGE = "Mage", WARRIOR = "Warrior", DRUID = "Druid",
    EVOKER = "Evoker", PALADIN = "Paladin", SHAMAN = "Shaman", WARLOCK = "Warlock",
    HUNTER = "Hunter", ROGUE = "Rogue", DEATHKNIGHT = "Death Knight",
    MONK = "Monk", DEMONHUNTER = "Demon Hunter",
}
BH.CLASS_NAMES = CLASS_NAMES

function BH:BuildClassBuffsTab(parent)
    local desc = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    desc:SetPoint("TOPLEFT", parent, "TOPLEFT", 14, -10)
    desc:SetWidth(400)
    desc:SetText("Enable or disable class buff tracking and choose a sound alert for each buff.")
    desc:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])

    local scrollFrame = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
    ns.TuneScrollStep(scrollFrame)
    scrollFrame:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -8)
    scrollFrame:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -22, 4)

    local scrollChild = CreateFrame("Frame", nil, scrollFrame)
    scrollChild:SetSize(390, 1)
    scrollFrame:SetScrollChild(scrollChild)
    self.classBuffScrollChild = scrollChild
end

function BH:RefreshClassBuffList()
    if not self.classBuffScrollChild then return end

    -- Hide the previous pass; rows we still need are re-acquired below rather
    -- than rebuilt (see BH:AcquireWidget).
    self:ResetWidgetCache("classBuffRowCache")

    local sc = self.classBuffScrollChild
    local yOffset = 0

    local function AddHeader(text)
        local headerFrame, isNew = self:AcquireWidget("classBuffRowCache", "header:" .. text, function()
            local f = CreateFrame("Frame", nil, sc)
            f:SetSize(380, 20)
            local header = f:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
            header:SetPoint("LEFT", f, "LEFT", 5, 0)
            header:SetText(text)
            return f
        end)
        local _ = isNew
        headerFrame:Show()
        headerFrame:SetPoint("TOPLEFT", sc, "TOPLEFT", 0, yOffset)
        yOffset = yOffset - 25
    end

    -- Acquire (or build) the row for one class-buff spell. Keyed by spell ID:
    -- the arguments below are fixed for a given spell, so a cached row stays valid.
    ---@param spellID number
    ---@param showMinDuration boolean
    ---@param className string
    local function AddSpellRow(spellID, showMinDuration, className)
        local row, isNew = self:AcquireWidget("classBuffRowCache", "spell:" .. spellID, function()
            return self:CreateItemRow(sc, yOffset, spellID, "spell", className, nil, showMinDuration, spellID)
        end)
        row:Show()
        row:SetPoint("TOPLEFT", sc, "TOPLEFT", 0, yOffset)
        if not isNew and row.Sync then row.Sync() end
        yOffset = yOffset - 58
    end

    local _, playerClass = UnitClass("player")
    if self.classBuffs and playerClass then
        local info = self.classBuffs[playerClass]
        if info then
            local headerAdded = false
            if info.auraCheck and info.auras then
                for _, auraInfo in ipairs(info.auras) do
                    if auraInfo.spellID then
                        if not headerAdded then
                            AddHeader("Class Buff")
                            headerAdded = true
                        end
                        AddSpellRow(auraInfo.spellID, false, CLASS_NAMES[playerClass] or playerClass)
                    end
                end
                -- Weapon imbues (Paladin Lightsmith Rites; Holy and Protection both)
                if info.weaponImbues then
                    for _, imbueInfo in ipairs(info.weaponImbues) do
                        if imbueInfo.spellID then
                            if not headerAdded then
                                AddHeader("Class Buff")
                                headerAdded = true
                            end
                            AddSpellRow(imbueInfo.spellID, true, CLASS_NAMES[playerClass] or playerClass)
                        end
                    end
                end
            else
                local buffList = info.spellID and { info } or info
                local seenSpellIDs = {}
                for _, buffInfo in ipairs(buffList) do
                    if buffInfo.spellID and not seenSpellIDs[buffInfo.spellID] then
                        seenSpellIDs[buffInfo.spellID] = true
                        if not headerAdded then
                            AddHeader("Class Buff")
                            headerAdded = true
                        end
                        -- Every class buff gets the minimum-duration box, not just
                        -- self/tank/imbue ones. NeedsRefresh has always applied
                        -- GetMinDuration to group buffs too -- defaulting to 30
                        -- minutes -- so the threshold was already in force for
                        -- Fortitude and friends, just with no way to see or change
                        -- it. Permanent buffs are unaffected either way, since
                        -- NeedsRefresh returns early on an expiration of 0.
                        AddSpellRow(buffInfo.spellID, not (buffInfo.weaponRune or buffInfo.healthstoneCheck), CLASS_NAMES[playerClass] or playerClass)
                    end
                end
            end
        end
    end

    sc:SetHeight(math.abs(yOffset) + 20)
    -- The Hunter's No Pet reminder used to be set up here; since 2.0 it is one
    -- of the class reminders on Text Reminders > Class.
end
