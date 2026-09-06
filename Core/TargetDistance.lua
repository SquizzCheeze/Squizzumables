-- Core/TargetDistance.lua
-- An estimate of how far away your target is, as movable on-screen text.
--
-- WHY THIS IS AN ESTIMATE AND NOT A NUMBER
--
-- There is no API that returns the distance to a hostile unit, and there has
-- not been for many years -- it was removed precisely because it is combat
-- information. What an addon can ask is a yes/no question: "is this unit within
-- range of this spell/item?" So distance is *bracketed* rather than measured.
-- Ask a ladder of known ranges and the answer falls between the largest rung
-- that says no and the smallest that says yes. That is why the readout is a
-- band ("30-35") rather than a figure, and why the bands are wider further out,
-- where there are fewer rungs to ask about.
--
-- WHERE THE RUNGS COME FROM
--
-- Two sources, deliberately weighted towards the first:
--
--   1. YOUR OWN SPELLS. C_Spell.GetSpellInfo returns a real minRange/maxRange
--      per spell, so the ladder is built from whatever your character actually
--      knows, with the ranges the game currently reports. This costs nothing to
--      maintain and follows talents that extend a spell's range on its own,
--      because it is read live rather than written down here.
--
--   2. A SMALL TABLE OF FIXED-RANGE ITEMS, to fill the gaps your class leaves.
--      A melee spec has almost no long rungs and a caster has almost no short
--      ones, so without these the band would be uselessly wide at one end.
--
-- The item IDs come from the same public set LibRangeCheck-3.0 uses (MIT,
-- mitch0 and the WoWUIDev community, https://www.curseforge.com/wow/addons/librangecheck-3-0).
-- Only a handful per rung are kept rather than its full list -- it carries
-- dozens deep for maximum redundancy, which is the right call for a general
-- library and more than a single readout needs. NOT taken from EllesmereUI,
-- whose licence reserves all rights.
--
-- This is the one part that can go stale: an item that is removed or has its
-- range changed stops answering. Each rung therefore holds several ids and any
-- one answering is enough, an unanswerable rung is dropped at build time rather
-- than trusted, and the spell ladder above covers most of the useful span
-- without any of them. /sq range prints what the ladder actually built.

local addonName, ns = ...
ns.BH = ns.BH or {}
local BH = ns.BH

-- ============================================================================
-- Range estimation
-- ============================================================================

local Range = {}
BH.Range = Range

-- Fixed-range harm items, longest-lived ids first within each rung.
--
-- Rungs are chosen for a readable spread rather than completeness: 1yd steps
-- close in are meaningless when the answer is a band anyway, and past 40 the
-- interesting question is only ever "am I too far".
local RANGE_ITEMS = {
    { range = 5,   ids = { 8149, 17117, 22432 } },      -- Voodoo Charm / Rat Catcher's Flute / Devilsaur Barb
    { range = 8,   ids = { 34368, 33278, 37932 } },     -- Attuned Crystal Cores / Burning Torch / Miner's Lantern
    { range = 10,  ids = { 10699, 17626, 9606 } },      -- Yeh'kinya's Bramble / Frostwolf Muzzle / Treant Muisek Vessel
    { range = 15,  ids = { 30651, 30652 } },            -- Dertrok's First / Second Wand
    { range = 20,  ids = { 10645, 1191, 4388 } },       -- Gnomish Death Ray / Bag of Marbles / Discombobulator Ray
    { range = 25,  ids = { 13289, 24268, 31463 } },     -- Egan's Blaster / Netherweave Net / Zezzak's Shard
    { range = 30,  ids = { 835, 1399, 4479 } },         -- Large Rope Net / Magic Candle / Burning Charm
    { range = 35,  ids = { 24269, 18904, 35121 } },     -- Heavy Netherweave Net / Zorbin's Ultra-Shrinker / Wolf Bait
    { range = 40,  ids = { 28767, 4945, 34255 } },      -- The Decapitator / Faintly Glowing Skull / Razorthorn Flayer Gland
    { range = 45,  ids = { 23836, 32698, 34691 } },     -- Goblin Rocket Launcher / Wrangling Rope / Arcane Binder
    { range = 50,  ids = { 116139, 134836 } },          -- Haunting Memento / Trident
    { range = 60,  ids = { 32825, 37877 } },            -- Soul Cannon / Silver Feather
    { range = 70,  ids = { 41265 } },                   -- Eyesore Blaster
    { range = 80,  ids = { 35278, 42769 } },            -- Reinforced Net / Spear of Hodir
    { range = 100, ids = { 33119, 44212 } },            -- Malister's Frost Wand / SGM-3
}

-- The built ladder: ascending { range, spells = {…}, items = {…} }.
local ladder = {}
local ladderBuilt = false

-- Several probes per rung, because a spell can answer nil rather than
-- true/false -- ground-targeted and conditionally-castable spells do, and a
-- rung with only one of those in it is a rung that never answers.
local MAX_PROBES_PER_RUNG = 3

local function AddProbe(byRange, range, kind, id)
    local rung = byRange[range]
    if not rung then
        rung = { range = range, spells = {}, items = {} }
        byRange[range] = rung
    end
    local list = (kind == "spell") and rung.spells or rung.items
    if #list < MAX_PROBES_PER_RUNG then
        list[#list + 1] = id
    end
end

-- Walk the spellbook for harmful spells with a usable max range.
--
-- minRange > 0 is skipped rather than handled: a spell with a minimum range
-- answers false both when you are too far AND when you are too close, so it
-- cannot tell the two apart and would read as "far away" while standing on top
-- of the target -- the one case where being wrong actually matters.
local function CollectSpellProbes(byRange)
    if not (C_SpellBook and C_SpellBook.GetNumSpellBookSkillLines) then return end

    local numLines = C_SpellBook.GetNumSpellBookSkillLines() or 0
    for i = 1, numLines do
        local line = C_SpellBook.GetSpellBookSkillLineInfo(i)
        if line and not line.isGuild and line.numSpellBookItems then
            local first = (line.itemIndexOffset or 0) + 1
            local last = (line.itemIndexOffset or 0) + line.numSpellBookItems
            for slot = first, last do
                local item = C_SpellBook.GetSpellBookItemInfo(slot, Enum.SpellBookSpellBank.Player)
                if item and item.itemType == Enum.SpellBookItemType.Spell
                   and not item.isPassive and not item.isOffSpec then
                    local sid = item.spellID or item.actionID
                    if sid and C_Spell.IsSpellHarmful and C_Spell.IsSpellHarmful(sid) then
                        local info = C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(sid)
                        local minR = info and BH.Secrets.SafeNumber(info.minRange, nil)
                        local maxR = info and BH.Secrets.SafeNumber(info.maxRange, nil)
                        if maxR and maxR > 0 and minR == 0 then
                            AddProbe(byRange, math.floor(maxR + 0.5), "spell", sid)
                        end
                    end
                end
            end
        end
    end
end

-- Ask for the item data we need, so IsItemInRange has something to answer with.
--
-- An item whose data is not cached answers nil, which at build time is
-- indistinguishable from an item that no longer exists. Requesting them at
-- login and rebuilding once they arrive is what keeps a cold cache from
-- permanently pruning good rungs.
local itemsRequested = false
local function RequestItemData()
    if itemsRequested then return end
    itemsRequested = true
    if not (C_Item and C_Item.RequestLoadItemDataByID) then return end
    for _, rung in ipairs(RANGE_ITEMS) do
        for _, id in ipairs(rung.ids) do
            if C_Item.IsItemDataCachedByID and not C_Item.IsItemDataCachedByID(id) then
                C_Item.RequestLoadItemDataByID(id)
            end
        end
    end
end

local function CollectItemProbes(byRange)
    if not (C_Item and C_Item.GetItemInfo) then return end
    for _, rung in ipairs(RANGE_ITEMS) do
        for _, id in ipairs(rung.ids) do
            -- Only items the client can actually answer about. An uncached id
            -- would silently return nil for every query and make its rung dead
            -- weight in the middle of the ladder.
            if C_Item.GetItemInfo(id) then
                AddProbe(byRange, rung.range, "item", id)
            end
        end
    end
end

function Range:Build()
    local byRange = {}
    CollectSpellProbes(byRange)
    CollectItemProbes(byRange)

    ladder = {}
    for _, rung in pairs(byRange) do
        if #rung.spells > 0 or #rung.items > 0 then
            ladder[#ladder + 1] = rung
        end
    end
    table.sort(ladder, function(a, b) return a.range < b.range end)
    ladderBuilt = true
    return ladder
end

function Range:Invalidate()
    ladderBuilt = false
end

function Range:GetLadder()
    if not ladderBuilt then self:Build() end
    return ladder
end

-- Is `unit` within this rung's range? true / false / nil when unanswerable.
--
-- Spells before items: a spell reflects the character's current talents, and
-- costs no item cache. Any probe giving a definite answer wins; only if every
-- probe on the rung answers nil is the rung itself unanswerable.
-- Item range checks are PROTECTED in combat against a unit you cannot attack.
--
-- Calling one anyway raises ADDON_ACTION_BLOCKED naming this addon. That is not
-- a Lua error, so nothing fails visibly and nothing stops -- it just logs, and
-- on a 0.15s poll it logs continuously, which is how this first showed up: a
-- blocked-action report with `UNKNOWN()` and two anonymous C frames above the
-- item probe.
--
-- Spell checks have no such restriction, which is the asymmetry to remember:
-- C_Spell.IsSpellInRange is AllowedWhenTainted, C_Item.IsItemInRange is not.
-- LibRangeCheck-3.0 guards its item checkers with exactly this predicate and
-- leaves its spell checkers unguarded, which is the confirmation that the rule
-- is about items specifically rather than about range checking generally.
--
-- The cost of the guard is a coarser band on a friendly target mid-fight, since
-- only the spell rungs can answer there. That is the right way round: a wider
-- estimate beats a correct one that spams the error log.
local function ItemProbesAllowed(unit)
    return not (InCombatLockdown() and not UnitCanAttack("player", unit))
end

local function RungAnswer(rung, unit, allowItems)
    for _, sid in ipairs(rung.spells) do
        local inRange = C_Spell.IsSpellInRange and C_Spell.IsSpellInRange(sid, unit)
        if inRange ~= nil and not BH.Secrets.IsSecret(inRange) then
            return inRange and true or false
        end
    end
    if allowItems then
        for _, iid in ipairs(rung.items) do
            local inRange = C_Item.IsItemInRange and C_Item.IsItemInRange(iid, unit)
            if inRange ~= nil and not BH.Secrets.IsSecret(inRange) then
                return inRange and true or false
            end
        end
    end
    return nil
end

--- Estimate the distance to `unit` as a band.
---
--- Returns minRange, maxRange. A nil maxRange means "further than the longest
--- rung that answered", which is the honest answer rather than a made-up
--- ceiling. Returns nil when nothing could be asked at all.
function Range:GetRange(unit)
    unit = unit or "target"
    if not UnitExists(unit) then return nil end
    if UnitIsDeadOrGhost(unit) then return nil end

    local l = self:GetLadder()
    if #l == 0 then return nil end

    -- Walk up until something says "yes, within". Everything below the first
    -- yes is a no, so that rung's range is the upper bound and the previous
    -- answered rung is the lower.
    -- Decided once per query rather than per rung: it cannot change part way
    -- through a walk, and it is two API calls we would otherwise make for every
    -- rung on every tick.
    local allowItems = ItemProbesAllowed(unit)

    local lastNo = nil
    for i = 1, #l do
        local answer = RungAnswer(l[i], unit, allowItems)
        if answer == true then
            return lastNo, l[i].range
        elseif answer == false then
            lastNo = l[i].range
        end
        -- nil: unanswerable rung, skip it without disturbing the bounds
    end

    -- Nothing answered "within", so the target is beyond the top of the ladder.
    return lastNo, nil
end

-- ============================================================================
-- Display
-- ============================================================================

local DEFAULT_TEXT_SIZE = 18
local POLL_INTERVAL = 0.15

local FORMATS = {
    { text = "Range (30-35)", value = "band" },
    { text = "Maximum (35)",  value = "max" },
    { text = "Minimum (30)",  value = "min" },
}
BH.TARGET_DISTANCE_FORMATS = FORMATS

local ALIGNMENTS = {
    { text = "Left",   value = "LEFT" },
    { text = "Center", value = "CENTER" },
    { text = "Right",  value = "RIGHT" },
}
BH.TARGET_DISTANCE_ALIGNMENTS = ALIGNMENTS

local STRATAS = {
    { text = "Background", value = "BACKGROUND" },
    { text = "Low",        value = "LOW" },
    { text = "Medium",     value = "MEDIUM" },
    { text = "High",       value = "HIGH" },
    { text = "Dialog",     value = "DIALOG" },
}
BH.TARGET_DISTANCE_STRATAS = STRATAS

local function FormatRange(minR, maxR, style)
    if style == "max" then
        if maxR then return tostring(maxR) end
        return minR and (minR .. "+") or "?"
    elseif style == "min" then
        if minR then return tostring(minR) end
        return maxR and ("<" .. maxR) or "?"
    end

    -- Band, the default.
    if minR and maxR then return minR .. "-" .. maxR end
    if maxR then return "0-" .. maxR end
    if minR then return minR .. "+" end
    return "?"
end
BH.FormatTargetRange = FormatRange

function BH:BuildTargetDistanceFrame()
    if self.targetDistanceFrame then return self.targetDistanceFrame end

    local f = CreateFrame("Frame", "SquizzumablesTargetDistance", UIParent)
    f:SetSize(120, 28)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, -120)
    f:SetMovable(true)
    f:EnableMouse(false)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self2)
        if InCombatLockdown() then return end
        self2:StartMoving()
    end)
    f:SetScript("OnDragStop", function(self2)
        self2:StopMovingOrSizing()
        BH:SaveTargetDistancePosition()
    end)
    f:Hide()

    local text = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    text:SetPoint("CENTER", f, "CENTER", 0, 0)
    f.text = text

    self.targetDistanceFrame = f
    self:ApplyTargetDistanceStyle()
    return f
end

--- Font size, alignment and strata, from settings.
function BH:ApplyTargetDistanceStyle()
    local f = self.targetDistanceFrame
    if not f then return end
    local s = self.settings or {}

    local size = s.targetDistanceTextSize or DEFAULT_TEXT_SIZE
    f.text:SetFont("Fonts\\FRIZQT__.TTF", size, "OUTLINE")
    f.text:SetJustifyH(s.targetDistanceAlign or "CENTER")
    f:SetFrameStrata(s.targetDistanceStrata or "HIGH")

    -- The box grows with the text so the drag region in unlock mode matches
    -- what is actually on screen, rather than a fixed rectangle the number
    -- rattles around inside.
    f:SetSize(math.max(60, size * 5), size + 10)

    -- {r=,g=,b=}, matching every other colour setting in the addon rather than
    -- inventing an array shape the colour picker rows would not understand.
    local c = s.targetDistanceColor or {}
    f.text:SetTextColor(c.r or 1, c.g or 1, c.b or 1, 1)
end

local function ShouldShow()
    local s = BH.settings
    if not s or not s.targetDistanceEnabled then return false end
    if BH.unlockMode then return true end
    if not UnitExists("target") then return false end
    if UnitIsDeadOrGhost("target") then return false end
    -- Hostile only unless asked otherwise: the probes are harmful spells and
    -- items, so a friendly target answers nothing and the readout would sit
    -- there showing "?".
    if not s.targetDistanceFriendly and not UnitCanAttack("player", "target") then
        return false
    end
    return true
end

local pollTicker

function BH:UpdateTargetDistance()
    local f = self.targetDistanceFrame
    if not f then return end

    -- Mouse only while being positioned, re-asserted every pass.
    --
    -- SetAllFramesPreview turns the mouse ON for every movable frame entering
    -- unlock mode, but the pass that leaves it only restores mouse state for
    -- frames in BH.REMINDERS -- this is not one. Left alone it would stay
    -- mouse-enabled for the rest of the session, and a transparent text frame
    -- that silently eats clicks is exactly the bug the Just For Kel alert image
    -- had in 1.68. Driving it from the poll means it corrects itself no matter
    -- how unlock mode was left.
    f:EnableMouse(BH.unlockMode and true or false)

    if not ShouldShow() then
        f:Hide()
        return
    end

    f:Show()

    -- Unlock mode shows a sample rather than a live reading, so the frame can
    -- be positioned without needing something to target.
    --
    -- Unconditionally, not only when there is no target: unlock mode is the one
    -- path that skips the hostile-only check in ShouldShow, so querying here
    -- could ask about a friendly unit -- which is exactly the case the item
    -- probes are refused for. A positioning aid has no business making range
    -- calls at all.
    if self.unlockMode then
        f.text:SetText("30-35")
        return
    end

    local minR, maxR = self.Range:GetRange("target")
    if not minR and not maxR then
        f.text:SetText("?")
        return
    end

    f.text:SetText(FormatRange(minR, maxR,
        (self.settings and self.settings.targetDistanceFormat) or "band"))
end

--- Start or stop the poll, matching the setting. Called from the options panel
--- and at login.
function BH:ApplyTargetDistance()
    local s = self.settings or {}

    if not s.targetDistanceEnabled then
        if pollTicker then pollTicker:Cancel() pollTicker = nil end
        if self.targetDistanceFrame then self.targetDistanceFrame:Hide() end
        return
    end

    self:BuildTargetDistanceFrame()
    self:LoadTargetDistancePosition()
    self:ApplyTargetDistanceStyle()
    RequestItemData()

    -- A ticker rather than OnUpdate, the same "cheaper than per-frame" pattern
    -- the battle res counter and death tally use. Distance never needs to be
    -- more current than a few frames, and each tick walks a ladder.
    if not pollTicker then
        pollTicker = C_Timer.NewTicker(POLL_INTERVAL, function()
            BH:UpdateTargetDistance()
        end)
    end
    self:UpdateTargetDistance()
end

-- ============================================================================
-- Events
-- ============================================================================

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("PLAYER_TARGET_CHANGED")
-- The ladder is built from the player's own spellbook, so anything that changes
-- which spells exist invalidates it. Ranges also move with talents, which is
-- why this is rebuilt rather than merely re-sorted.
ev:RegisterEvent("SPELLS_CHANGED")
ev:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
ev:RegisterEvent("TRAIT_CONFIG_UPDATED")
ev:RegisterEvent("GET_ITEM_INFO_RECEIVED")

ev:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        C_Timer.After(2, function()
            if BH.ApplyTargetDistance then BH:ApplyTargetDistance() end
        end)
        return
    end

    if event == "PLAYER_TARGET_CHANGED" then
        if BH.UpdateTargetDistance then BH:UpdateTargetDistance() end
        return
    end

    if event == "GET_ITEM_INFO_RECEIVED" then
        -- An item we asked for at login has arrived, so a rung that was pruned
        -- as unanswerable may now be usable. Cheap: the rebuild only happens on
        -- the next query.
        Range:Invalidate()
        return
    end

    -- Spec, talent or spellbook change.
    Range:Invalidate()
end)

-- Unlisted diagnostic: what the ladder actually built, which is the only way to
-- tell "my class has no rung near that distance" from "the probes are broken".
function BH:PrintRangeDiagnostics()
    print("Squizzumables target distance:")
    print("  enabled:", tostring(BH.settings and BH.settings.targetDistanceEnabled))
    local l = self.Range:GetLadder()
    print(string.format("  ladder rungs: %d", #l))
    for _, rung in ipairs(l) do
        print(string.format("      %3dyd  %d spell(s), %d item(s)",
            rung.range, #rung.spells, #rung.items))
    end
    if UnitExists("target") then
        -- Whether the item rungs are usable right now. When this is false the
        -- band is spell-only and therefore wider, which otherwise looks like
        -- the ladder having lost half its rungs.
        print("  item probes allowed on this target:",
            tostring(ItemProbesAllowed("target")))
        local minR, maxR = self.Range:GetRange("target")
        print(string.format("  current target: %s (%s)",
            FormatRange(minR, maxR, "band"),
            BH.Secrets.SafeString(UnitName("target"), "<name hidden>")))
    else
        print("  no target")
    end
end
