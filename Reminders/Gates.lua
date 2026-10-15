-- Reminders/Gates.lua
-- The text reminders' shared gates (BH.REMINDER_GATES) and the update
-- function of each reminder: Beacon, Earth Shield, repair, Symbiotic
-- Relationship, Coach Whistle, pet, bags, healthstones.
--
-- Moved out of Squizzumables.lua unchanged in 2.0 phase 2 (the split). The
-- core's private names it uses are published on BH just before where this
-- code used to sit, and re-declared below under the same names, so not a
-- line of the moved code had to change. Its load-time check (every gate a
-- reminder names must exist) still runs at load, after the core has defined
-- BH.REMINDERS.

local addonName, ns = ...
local BH = ns.BH

local BEACON_AURA_IDS          = BH.BEACON_AURA_IDS
local BEACON_OF_FAITH          = BH.BEACON_OF_FAITH
local BEACON_OF_VIRTUE         = BH.BEACON_OF_VIRTUE
local COACH_WHISTLE_ITEM_ID    = BH.COACH_WHISTLE_ITEM_ID
local ELEMENTAL_ORBIT_SPELL_ID = BH.ELEMENTAL_ORBIT_SPELL_ID
local ES_AURA_IDS              = BH.ES_AURA_IDS
local SYMBIOTIC_AURA_SPELL_ID  = BH.SYMBIOTIC_AURA_SPELL_ID
local GetCoachedAllyExpiration = BH.GetCoachedAllyExpiration
local HasRealPlayerGroupMember = BH.HasRealPlayerGroupMember
local ShouldShowReminders      = BH.ShouldShowReminders
local GetGroupUnits            = BH.GetGroupUnits

-- ============================================================================
-- Reminder gates
--
-- Every Update<Name>Reminder used to open with the same twenty-odd lines: bail
-- if the frame does not exist, bail if preview mode owns visibility, hide if
-- the reminder is switched off, hide if the wrong class, hide if the wrong
-- spec, hide if the spell is not known, hide unless the content type allows
-- it. Ten copies of the same checks, each free to drift from the others -- and
-- they had.
--
-- The checks are named predicates now, and each reminder record lists the ones
-- it wants in `gates`. What is left in each Update function is the part that is
-- genuinely specific to that reminder.
-- ============================================================================

BH.REMINDER_GATES = {
    enabled = function(def)
        return BH.settings and BH.settings[def.key .. "ReminderEnabled"] ~= false
    end,

    class = function(def)
        local _, class = UnitClass("player")
        return class == def.class
    end,

    spec = function(def)
        ---@diagnostic disable-next-line: undefined-global
        local specID = PlayerUtil and PlayerUtil.GetCurrentSpecID and PlayerUtil.GetCurrentSpecID()
        return specID == def.spec
    end,

    notSpec = function(def)
        ---@diagnostic disable-next-line: undefined-global
        local specID = PlayerUtil and PlayerUtil.GetCurrentSpecID and PlayerUtil.GetCurrentSpecID()
        return specID ~= def.notSpec
    end,

    knows = function(def)
        return BH.PlayerKnowsSpell(def.knowsSpell)
    end,

    -- The buff has its own tick in the class-buff list, and unticking it should
    -- silence the reminder too.
    buffEnabled = function(def)
        return BH:IsEnabled(def.buffEnabledSpell)
    end,

    equipped = function(def)
        return GetInventoryItemID("player", 13) == def.equippedItem
            or GetInventoryItemID("player", 14) == def.equippedItem
    end,

    -- The content-type gate: dungeons, raids, the open world and so on, per the
    -- player's "Show in" settings.
    visible = function()
        return ShouldShowReminders()
    end,

    outOfCombat = function()
        return not InCombatLockdown()
    end,

    group = function()
        return GetNumGroupMembers() > 0
    end,

    -- Stricter than `group`: a solo delve fills the party with NPC companions,
    -- and telling someone to buff their bodyguard is noise.
    realGroup = function()
        return HasRealPlayerGroupMember()
    end,
}

-- A misspelled gate would otherwise pass silently and the reminder would show
-- in situations it was meant to be hidden in, which is the sort of bug that
-- goes unnoticed for a patch cycle. Fail loudly at load instead.
for _, def in ipairs(BH.REMINDERS) do
    for _, name in ipairs(def.gates or {}) do
        if not BH.REMINDER_GATES[name] then
            error(("Squizzumables: reminder '%s' declares unknown gate '%s'"):format(def.key, name))
        end
    end
end

--- Run a reminder's shared gates.
---
--- Returns the frame when they all pass, and nil when one fails (having hidden
--- the frame) or when there is nothing to decide yet -- no frame built, or
--- preview mode owning visibility. Callers open with
---
---     local frame = self:ReminderGate(BH.REMINDERS_BY_KEY.beacon)
---     if not frame then return end
function BH:ReminderGate(def)
    local frame = self[def.key .. "ReminderFrame"]
    if not frame then return nil end
    -- Preview mode owns visibility: SetAllFramesPreview has already shown this
    -- frame so it can be positioned, and this pass must not undo that. Without
    -- it, UpdateButtons (driven by UNIT_AURA) hid every previewed reminder
    -- within a fraction of a second of the preview being turned on.
    if self.unlockMode then return nil end

    for _, name in ipairs(def.gates or {}) do
        if not BH.REMINDER_GATES[name](def) then
            frame:Hide()
            return nil
        end
    end
    return frame
end

function BH:UpdateAllReminders()
    self:UpdateBeaconReminder()
    self:UpdateEarthShieldReminder()
    self:UpdateRepairReminder()
    self:UpdateSymbioticReminder()
    self:UpdateCoachWhistleReminder()
    self:UpdatePetReminder()
    self:UpdateBagReminder()
    self:UpdateHealthstoneReminder()
end

-- Update beacon reminder visibility for Holy Paladins
-- Shows big centered text when beacons are missing
function BH:UpdateBeaconReminder()
    local frame = self:ReminderGate(BH.REMINDERS_BY_KEY.beacon)
    if not frame then return end

    -- Determine how many beacons needed based on talents
    -- Beacon of Faith = 2 beacons, Beacon of Light = 1 beacon
    -- Beacon of Virtue is a short CD active ability, no persistent beacon needed
    if BH.PlayerKnowsSpell(BEACON_OF_VIRTUE) then
        self.beaconReminderFrame:Hide()
        return
    end
    local beaconsNeeded = 1
    if BH.PlayerKnowsSpell(BEACON_OF_FAITH) then
        beaconsNeeded = 2
    end

    -- Auras go secret in combat, and an unreadable aura is indistinguishable
    -- from an absent one. This reminder fires on *absence*, so a secret pass
    -- counts zero and asserts "missing" for a buff that is actually up -- and
    -- keeps asserting it, because applying the buff cannot be seen either.
    -- Hold whatever the last readable pass decided instead. The player's own
    -- cast still clears it: see OnReminderSpellcast.
    --
    -- Beacon of Faith needs two beacons, so one cast is not enough to call it
    -- done -- count the casts seen since going blind and only clear once they
    -- cover what is needed.
    if BH.Secrets.AurasAreSecret() then
        self.beaconsNeededLast = beaconsNeeded
        if (self.beaconsBelieved or 0) >= beaconsNeeded then
            self.beaconReminderFrame:Hide()
        else
            local locked = self.settings and self.settings.beaconReminderLocked
            self.beaconReminderFrame:Show()
            self.beaconReminderFrame:EnableMouse(BH:ReminderMouseEnabled(locked))
        end
        return
    end

    -- Count beacons sourced by the player on group members.
    --
    -- Also record *whose* GUIDs carry them. Once auras go secret this is the
    -- only handle left on the buff: PollBlindReminderLoss watches those units
    -- for death, which is readable when the aura is not.
    local myBeaconCount = 0
    local beaconedGUIDs = {}
    local groupSize = GetNumGroupMembers()
    if groupSize > 0 then
        local isRaid = IsInRaid()
        for i = 1, groupSize do
            local unit = isRaid and ("raid" .. i) or ("party" .. i)
            if UnitExists(unit) and not UnitIsDeadOrGhost(unit) then
                for _, auraID in ipairs(BEACON_AURA_IDS) do
                    local auraData = C_UnitAuras.GetUnitAuraBySpellID(unit, auraID)
                    if BH.Secrets.AuraIsFromPlayer(auraData) then
                        myBeaconCount = myBeaconCount + 1
                        beaconedGUIDs[#beaconedGUIDs + 1] = UnitGUID(unit)
                        break -- only count one beacon per unit
                    end
                end
            end
        end
        -- Also check player (in raid, player is included; in party, check separately)
        if not isRaid then
            for _, auraID in ipairs(BEACON_AURA_IDS) do
                local auraData = C_UnitAuras.GetPlayerAuraBySpellID(auraID)
                if BH.Secrets.AuraIsFromPlayer(auraData) then
                    myBeaconCount = myBeaconCount + 1
                    beaconedGUIDs[#beaconedGUIDs + 1] = UnitGUID("player")
                    break
                end
            end
        end
        -- Baseline for the blind tracking below: what is actually up, who is
        -- carrying it, and how many of those are alive right now.
        self.beaconedGUIDs     = beaconedGUIDs
        self.beaconsNeededLast = beaconsNeeded
        self.beaconsBelieved   = myBeaconCount
        self.beaconedAliveLast = #beaconedGUIDs
    else
        -- Solo - no group members to beacon
        self.beaconReminderFrame:Hide()
        return
    end

    if myBeaconCount < beaconsNeeded then
        self.beaconReminderFrame:Show()
        -- Enable/disable mouse based on lock
        local locked = self.settings and self.settings.beaconReminderLocked
        self.beaconReminderFrame:EnableMouse(BH:ReminderMouseEnabled(locked))
    else
        self.beaconReminderFrame:Hide()
    end
end

-- Update Earth Shield reminder visibility for Restoration Shamans
-- Uses the same multi-shaman slot logic as the old button system
function BH:UpdateEarthShieldReminder()
    local frame = self:ReminderGate(BH.REMINDERS_BY_KEY.earthShield)
    if not frame then return end

    -- Same logic as the old multi-shaman Earth Shield checks:
    -- Count how many Earth Shields the player has sourced (self + others)
    -- With Elemental Orbit the player can maintain ES on self + 1 other (max 2).
    -- Without Elemental Orbit the player can maintain 1 external ES (max 1).
    local myESCount = 0
    local esGUIDs = {}

    -- Auras go secret in combat, and an unreadable aura is indistinguishable
    -- from an absent one. This reminder fires on *absence*, so a secret pass
    -- counts zero and asserts "missing" for a shield that is actually up -- and
    -- keeps asserting it, because applying it cannot be seen either. Hold
    -- whatever the last readable pass decided instead. The player's own cast
    -- still clears it (OnReminderSpellcast) and PollBlindReminderLoss brings it
    -- back if the shielded target dies.
    if BH.Secrets.AurasAreSecret() then
        if (self.esBelieved or 0) >= (self.esNeededLast or 1) then
            self.earthShieldReminderFrame:Hide()
        else
            local locked = self.settings and self.settings.earthShieldReminderLocked
            self.earthShieldReminderFrame:Show()
            self.earthShieldReminderFrame:EnableMouse(BH:ReminderMouseEnabled(locked))
        end
        return
    end

    -- Check if I have Earth Shield on myself
    for _, checkID in ipairs(ES_AURA_IDS) do
        local auraData = C_UnitAuras.GetPlayerAuraBySpellID(checkID)
        if BH.Secrets.AuraIsFromPlayer(auraData) then
            myESCount = myESCount + 1
            esGUIDs[#esGUIDs + 1] = UnitGUID("player")
            break
        end
    end

    -- Check group members for Earth Shields sourced by me
    local isRaid = IsInRaid()
    local groupSize = GetNumGroupMembers()
    for i = 1, groupSize do
        local unit = isRaid and ("raid" .. i) or ("party" .. i)
        if not (isRaid and UnitIsUnit(unit, "player")) and UnitExists(unit) then
            for _, checkID in ipairs(ES_AURA_IDS) do
                local auraData = C_UnitAuras.GetUnitAuraBySpellID(unit, checkID)
                if BH.Secrets.AuraIsFromPlayer(auraData) then
                    myESCount = myESCount + 1
                    esGUIDs[#esGUIDs + 1] = UnitGUID(unit)
                    break
                end
            end
        end
    end

    -- Max slots: 2 with Elemental Orbit, 1 without.
    --
    -- Read the talent, do not infer it from having a shield on yourself. That
    -- inference was wrong in both directions: a shaman who simply shielded
    -- themselves was credited with Elemental Orbit and told forever that a
    -- second shield was missing, and a shaman who *has* Elemental Orbit but has
    -- placed their only shield on someone else was scored 1-of-1 and never told
    -- to shield themselves. The button logic has always read the talent
    -- directly (see the Earth Shield button block); this now agrees with it.
    local maxES = BH.PlayerKnowsSpell(ELEMENTAL_ORBIT_SPELL_ID) and 2 or 1
    self.esGUIDs      = esGUIDs
    self.esNeededLast = maxES
    self.esBelieved   = myESCount
    self.esAliveLast  = #esGUIDs

    if myESCount < maxES then
        self.earthShieldReminderFrame:Show()
        -- Enable/disable mouse based on lock
        local locked = self.settings and self.settings.earthShieldReminderLocked
        self.earthShieldReminderFrame:EnableMouse(BH:ReminderMouseEnabled(locked))
    else
        self.earthShieldReminderFrame:Hide()
    end
end

-- Update repair reminder visibility
-- Shows big centered text when any equipped item's durability is below threshold
function BH:UpdateRepairReminder()
    local frame = self:ReminderGate(BH.REMINDERS_BY_KEY.repair)
    if not frame then return end

    local threshold = self.settings.repairReminderThreshold or 20
    local lowestPct = 100

    for slot = 1, 19 do
        local current, maximum = GetInventoryItemDurability(slot)
        if current and maximum and maximum > 0 then
            local pct = (current / maximum) * 100
            if pct < lowestPct then
                lowestPct = pct
            end
        end
    end

    if lowestPct < threshold then
        self.repairReminderText:SetText(string.format("REPAIR (%d%%)", math.floor(lowestPct)))
        self.repairReminderFrame:Show()
        -- Enable/disable mouse based on lock
        local locked = self.settings and self.settings.repairReminderLocked
        self.repairReminderFrame:EnableMouse(BH:ReminderMouseEnabled(locked))
    else
        self.repairReminderFrame:Hide()
    end
end

-- Update Symbiotic Relationship reminder visibility for Druids
-- Shows big centered text when any party/raid member is missing the buff
function BH:UpdateSymbioticReminder()
    local frame = self:ReminderGate(BH.REMINDERS_BY_KEY.symbiotic)
    if not frame then return end

    -- Auras go secret in combat, and an unreadable aura is indistinguishable
    -- from an absent one. This reminder fires on *absence*, so a secret pass
    -- counts zero and asserts "missing" for a buff that is actually up -- and
    -- keeps asserting it, because applying the buff cannot be seen either.
    -- Hold whatever the last readable pass decided instead. The player's own
    -- cast still clears it: see OnReminderSpellcast.
    if BH.Secrets.AurasAreSecret() then return end

    -- Check if the player has the Symbiotic Relationship buff on themselves
    local auraData = C_UnitAuras.GetPlayerAuraBySpellID(SYMBIOTIC_AURA_SPELL_ID)
    if not auraData then
        local locked = self.settings and self.settings.symbioticReminderLocked
        self.symbioticReminderFrame:Show()
        self.symbioticReminderFrame:EnableMouse(BH:ReminderMouseEnabled(locked))
    else
        self.symbioticReminderFrame:Hide()
    end
end

-- Update Emerald Coach's Whistle reminder visibility
function BH:UpdateCoachWhistleReminder()
    local frame = self:ReminderGate(BH.REMINDERS_BY_KEY.coachWhistle)
    if not frame then return end

    -- Show if coaching needs refreshing (buff missing or below min duration threshold)
    local coachExp = GetCoachedAllyExpiration()
    if not self:NeedsRefresh(COACH_WHISTLE_ITEM_ID, coachExp) then
        frame:Hide()
    else
        local locked = self.settings and self.settings.coachWhistleReminderLocked
        frame:Show()
        frame:EnableMouse(BH:ReminderMouseEnabled(locked))
    end
end

-- Hunter: No Pet reminder
function BH:UpdatePetReminder()
    local frame = self:ReminderGate(BH.REMINDERS_BY_KEY.pet)
    if not frame then return end

    -- Show when player has no active pet
    if UnitExists("pet") then
        frame:Hide()
    else
        frame:Show()
        local locked = self.settings and self.settings.petReminderLocked
        frame:EnableMouse(BH:ReminderMouseEnabled(locked))
    end
end

-- Update food "no items in bag" reminder

-- The four "nothing in your bags" reminders, as one frame.
--
-- Food, flask, oil and augment rune each used to have their own frame, so a
-- player who was short of all four got four banners stacked up the screen, each
-- needing its own position, scale and lock. They are one line of text now,
-- naming whichever are actually missing -- the same shape the role CC alert
-- uses for healer and tank.
--
-- The per-category settings survive as *watch* toggles: unticking Food means
-- "do not tell me about food", not "hide a frame".
local BAG_REMINDER_ORDER = { "food", "flask", "oil", "augmentRune" }
local BAG_REMINDER_WORDS = {
    food        = "FOOD",
    flask       = "FLASK",
    oil         = "WEAPON OIL",
    augmentRune = "AUGMENT RUNE",
}

-- "FOOD", "FOOD OR FLASK", "FOOD, FLASK OR OIL" -- read aloud rather than a
-- comma-separated dump, since this is a sentence the player reads at a glance.
local function JoinMissing(words)
    local n = #words
    if n == 0 then return nil end
    if n == 1 then return words[1] end
    if n == 2 then return words[1] .. " OR " .. words[2] end
    return table.concat(words, ", ", 1, n - 1) .. " OR " .. words[n]
end

--- Which watched categories have nothing usable in the bags.
local function MissingBagCategories()
    local missing = {}
    for _, key in ipairs(BAG_REMINDER_ORDER) do
        -- Watched at all?
        if BH.settings and BH.settings[key .. "ReminderEnabled"] ~= false then
            local list = BH.consumables and BH.consumables[key]
            local anyEnabled, anyInBags = false, false
            for _, itemID in ipairs(list or {}) do
                if BH:IsEnabled(itemID) then
                    anyEnabled = true
                    if BH:HasItemInBags(itemID) then
                        anyInBags = true
                        break
                    end
                end
            end
            -- Nothing enabled in a category is not the same as nothing carried:
            -- the player has simply not asked us to track it.
            if anyEnabled and not anyInBags then
                missing[#missing + 1] = BAG_REMINDER_WORDS[key]
            end
        end
    end
    return missing
end

--- Watched categories you are carrying some of, but `threshold` or fewer:
--- { "FLASK (2 LEFT)", ... }. Counts add up every enabled item of the
--- category, since any of them does the job. threshold 0 turns this off.
local function LowBagCategories(threshold)
    local low = {}
    if not threshold or threshold <= 0 then return low end
    for _, key in ipairs(BAG_REMINDER_ORDER) do
        if BH.settings and BH.settings[key .. "ReminderEnabled"] ~= false then
            local total = 0
            for _, itemID in ipairs(BH.consumables and BH.consumables[key] or {}) do
                if BH:IsEnabled(itemID) then
                    local entry = BH:GetBagEntry(itemID)
                    total = total + (entry and entry.count or 0)
                end
            end
            if total > 0 and total <= threshold then
                low[#low + 1] = string.format("%s (%d LEFT)", BAG_REMINDER_WORDS[key], total)
            end
        end
    end
    return low
end

function BH:UpdateBagReminder()
    -- Oil is suppressed for Holy Paladins running a Lightsmith rite, since the
    -- imbue replaces oils entirely for them. Handled by IsEnabled on the items
    -- themselves rather than here, so it applies wherever the list is read.
    local frame = self:ReminderGate(BH.REMINDERS_BY_KEY.bags)
    if not frame then return end

    local missing = MissingBagCategories()
    local text
    if #missing > 0 then
        text = "NO " .. JoinMissing(missing) .. " IN BAGS"
    else
        -- Nothing is out: warn about anything running low instead. Empty
        -- always wins, since that is the more urgent reading.
        local low = LowBagCategories(self.settings and self.settings.bagsLowThreshold or 1)
        if #low > 0 then text = "LOW ON " .. table.concat(low, ", ") end
    end
    if not text then
        frame:Hide()
        return
    end

    if self.bagsReminderText then
        self.bagsReminderText:SetText(text)
    end
    local locked = self.settings and self.settings.bagsReminderLocked
    frame:EnableMouse(BH:ReminderMouseEnabled(locked))
    frame:Show()
end




-- Healthstones.
--
-- Deliberately not a consumable category. Food, flask, oil and augment runes
-- are "you are missing this buff, click to apply it"; a healthstone is "you are
-- not carrying one", and the moment you *use* it is not a moment for a
-- reminder. So this is a bag-presence check with no button.
local HEALTHSTONE_ITEM_IDS = {
    5512,    -- Healthstone
    224464,  -- Demonic Healthstone
}

local CREATE_HEALTHSTONE_SPELL_ID = 6201
local CREATE_SOULWELL_SPELL_ID    = 29893

-- Which healthstone action to offer a warlock.
--
-- Solo, Create Healthstone is the whole job. In a group the useful cast is a
-- Soulwell: it serves everyone including the warlock, so it replaces the
-- personal version rather than sitting alongside it.
--
-- Falls back to the personal cast if Soulwell is somehow unknown, so a
-- low-level warlock still gets a usable button.
function BH.HealthstoneAction()
    if IsInGroup() and BH.PlayerKnowsSpell(CREATE_SOULWELL_SPELL_ID) then
        return CREATE_SOULWELL_SPELL_ID, "Soulwell"
    end
    if BH.PlayerKnowsSpell(CREATE_HEALTHSTONE_SPELL_ID) then
        return CREATE_HEALTHSTONE_SPELL_ID, "Healthstone"
    end
    return nil
end

-- Is there anyone here who can make one?
--
-- Includes the player, since a warlock can conjure their own. GetGroupUnits
-- already yields "player" first, so solo warlocks are covered without a
-- special case.
-- Is the player carrying a healthstone of any kind?
function BH.HasHealthstone()
    for _, itemID in ipairs(HEALTHSTONE_ITEM_IDS) do
        if BH:HasItemInBags(itemID) then return true end
    end
    return false
end

local function GroupHasWarlock()
    for _, unit in ipairs(GetGroupUnits()) do
        if UnitExists(unit) then
            local _, class = UnitClass(unit)
            if class == "WARLOCK" then return true end
        end
    end
    return false
end
BH.HEALTHSTONE_ITEM_IDS = HEALTHSTONE_ITEM_IDS

function BH:UpdateHealthstoneReminder()
    -- Unlike the consumable reminders this stays up in combat -- being without
    -- a healthstone matters most mid-fight, and pulling one from a Soulwell is
    -- something you can still do -- so there is no outOfCombat gate here.
    local frame = self:ReminderGate(BH.REMINDERS_BY_KEY.healthstone)
    if not frame then return end

    if BH.HasHealthstone() then
        self.healthstoneReminderFrame:Hide()
        return
    end

    -- A warlock gets a Create Healthstone button instead of being told
    -- about it, since they are the one who can fix it. See the
    -- healthstoneCheck branch in CollectClassBuffButtons.
    local _, playerClass = UnitClass("player")
    if playerClass == "WARLOCK" then
        self.healthstoneReminderFrame:Hide()
        return
    end

    -- Only worth saying if someone can actually make you one. Healthstones
    -- come from warlocks and nowhere else, so without one in the group this
    -- is a reminder to do something you cannot do.
    if not GroupHasWarlock() then
        self.healthstoneReminderFrame:Hide()
        return
    end

    local locked = self.settings and self.settings.healthstoneReminderLocked
    self.healthstoneReminderFrame:Show()
    self.healthstoneReminderFrame:EnableMouse(BH:ReminderMouseEnabled(locked))
end

-- Force-show or real-update all reminder frames depending on preview mode.
-- Call this whenever unlockMode changes.
function BH:RefreshAllReminderFrames()
    if self.unlockMode then
        -- SetAllFramesPreview already showed, tinted and unlocked every
        -- movable frame, reminders included. This used to repeat that job
        -- from its own hand-written list, and honoured each frame's lock
        -- while doing it -- which is why a locked reminder showed its
        -- preview tint and then refused to be dragged.
        self:SetAllFramesPreview(true)
        -- Role CC has two toggles rather than one enabled key, so it
        -- decides for itself whether there is anything to show.
        self:UpdateRoleCCFrame()
        if self.repairReminderFrame and self.repairReminderFrame:IsShown() and self.repairReminderText then
            self.repairReminderText:SetText("REPAIR (15%)")
        end
    else
        -- Restore real state
        self:UpdateBeaconReminder()
        self:UpdateEarthShieldReminder()
        self:UpdateSymbioticReminder()
        self:UpdateCoachWhistleReminder()
        self:UpdateRepairReminder()
        self:UpdateBagReminder()
        self:UpdateHealthstoneReminder()
        -- Role CC: shows only while a watched healer or tank actually has CC,
        -- and labels itself with whichever roles those are.
        self:UpdateRoleCCFrame()
    end
end
