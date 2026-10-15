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
local CreateSQDivider  = ns.CreateSQDivider

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

    -- Hunter: add No Pet reminder toggle below the class buff rows
    if playerClass == "HUNTER" then
      yOffset = yOffset - 8

      -- Built once, then re-anchored and re-synced. The divider in particular
      -- used to be created fresh on every refresh and never tracked or hidden,
      -- so it leaked a frame per refresh on top of the row itself.
      local petDivider = self:AcquireWidget("classBuffRowCache", "petDivider", function()
          return CreateSQDivider(sc, yOffset)
      end)
      petDivider:Show()
      petDivider:SetPoint("TOPLEFT", sc, "TOPLEFT", 0, yOffset)
      yOffset = yOffset - 18

      local petHdr = self:AcquireWidget("classBuffRowCache", "petHeader", function()
          local fs = sc:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
          fs:SetText("NO PET REMINDER")
          ns.ApplyAccent(fs, "text")
          return fs
      end)
      petHdr:Show()
      petHdr:SetPoint("TOPLEFT", sc, "TOPLEFT", 0, yOffset)
      yOffset = yOffset - 22

      local petRow, petRowIsNew = self:AcquireWidget("classBuffRowCache", "petRow", function()
          local f = CreateFrame("Frame", nil, sc)
          -- Sized generously; the rows inside anchor from the top so extra
          -- height is harmless, and too little would clip the last row.
          f:SetSize(380, 130)
          return f
      end)
      petRow:Show()
      petRow:SetPoint("TOPLEFT", sc, "TOPLEFT", 0, yOffset)
      self.petReminderRow = petRow

      -- Height of the three rows below, shared by the cached path and the
      -- build path so they cannot drift apart.
      local petRowHeight = ns.Rows.HEIGHTS.check * 2 + ns.Rows.HEIGHTS.slider + 8

      if not petRowIsNew then
          -- Rows sync themselves; nothing to re-apply by hand.
          ns.Rows.RefreshAll()
          yOffset = yOffset - petRowHeight
          sc:SetHeight(math.abs(yOffset) + 20)
          return
      end

        -- Positioned inside petRow rather than the tab body, so this tracks its
        -- own offset. Rows.Add takes whatever parent it is given.
        local py = 0
        py = py - ns.Rows.Add(petRow, py, {
            type = "check",
            indent = 0,
            label = "Show \"NO PET\" text when pet is missing",
            tooltip = "Shows a large NO PET reminder when your pet is dismissed or dead.",
            get = function() return BH.settings.petReminderEnabled ~= false end,
            set = function(v)
                BH.settings.petReminderEnabled = v
                BH:SaveSettings()
                BH:UpdatePetReminder()
            end,
        })

        py = py - ns.Rows.Add(petRow, py, {
            type = "slider",
            indent = 0,
            label = "Scale",
            width = 200, min = 50, max = 300, step = 5,
            tooltip = "Size of the NO PET reminder, as a percentage.",
            get = function() return (BH.settings.petReminderScale or 1.0) * 100 end,
            set = function(value, userInput)
                if not userInput then return end
                BH.settings.petReminderScale = value / 100
                if BH.petReminderFrame then BH.petReminderFrame:SetScale(value / 100) end
                BH:SaveSettings()
            end,
            disabled = function() return BH.settings.petReminderEnabled == false end,
        })

        py = py - ns.Rows.Add(petRow, py, {
            type = "check",
            indent = 0,
            label = "Lock position",
            tooltip = "Stops the NO PET reminder being dragged.",
            get = function() return BH.settings.petReminderLocked and true or false end,
            set = function(v)
                BH.settings.petReminderLocked = v
                if BH.petReminderFrame then
                    BH.petReminderFrame:EnableMouse(BH:ReminderMouseEnabled(v))
                end
                BH:SaveSettings()
            end,
            disabled = function() return BH.settings.petReminderEnabled == false end,
        })

        yOffset = yOffset - petRowHeight
        sc:SetHeight(math.abs(yOffset) + 20)
    end
end
