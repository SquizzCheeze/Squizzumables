-- Squizzumables.lua
-- A simple WoW addon to check inventory for consumables (food, flask, oil) and
-- your class buffs (e.g. Fortitude for priests) and show clickable buttons in a
-- movable frame. Designed for Dragonflight/Midnight (12.0.1) but should work
-- with other retail versions.

-- Every file in this addon receives (addonName, ns) as varargs. `ns` is a table
-- private to this addon, so nothing here touches the global namespace — `BH`
-- used to be a global, and a two-letter name in _G is asking for a collision
-- with another addon.
local addonName, ns = ...
ns.BH = ns.BH or {}
local BH = ns.BH

-- Shared theme and widget kit, defined in UI/Widgets.lua which loads first.
local SQ_COLORS           = ns.SQ_COLORS
local ApplySQBackdrop     = ns.ApplySQBackdrop
local SQ_GetClickEdge     = ns.SQ_GetClickEdge
local CreateSQButton      = ns.CreateSQButton
local CreateSQEditBox     = ns.CreateSQEditBox
local CreateSQSlider      = ns.CreateSQSlider
local CreateSQCheckbox    = ns.CreateSQCheckbox
local CreateSQColorPicker = ns.CreateSQColorPicker
local CreateSQDropdown    = ns.CreateSQDropdown
local CreateSQDivider     = ns.CreateSQDivider

-- Default settings for appearance
BH.defaultSettings = {
    -- Unused since 2.0: the grow direction decides the anchor (BH:GrowAnchor).
    -- Kept so profiles exported to an older copy still carry a value.
    anchorPoint = "LEFT",

    -- Draw headings, tab highlights, checkboxes, slider fills and button
    -- accents in the player's class colour instead of the default warm gold.
    -- 2.0: superseded by theme.preset (UI/Theme.lua); still read for a profile
    -- that has never picked a preset, and kept in step by Theme.SetPreset.
    -- Default false since 2.0: gold is the default accent for new installs and
    -- new profiles (user decision 2026-10-15). Saved values are untouched.
    useClassColorAccent = false,
    -- Mirror our own timers onto Blizzard's encounter timeline. See
    -- Core/EncounterTimeline.lua for why only the write side of the API is used.
    timelineTimers = true,
    -- The four class reminders' own lock and scale keys. Since 2.0 they share
    -- the one Class Reminder frame (Reminders/RemindersTab.lua describes its
    -- settings): its lock writes these four locks, which the reminders' own
    -- code still reads; the scales are only read once more, by migration 9.
    beaconReminderLocked = false,
    beaconReminderScale = 1.0,
    earthShieldReminderLocked = false,
    earthShieldReminderScale = 1.0,
    symbioticReminderLocked = false,
    symbioticReminderScale = 1.0,

    coachWhistleReminderLocked = false,
    coachWhistleReminderScale = 1.0,
    coachWhistleReminderEnabled = true,

    -- Hunter: No Pet reminder
    petReminderLocked = false,
    petReminderScale = 1.0,
    cdmEnabled = false,
    cdmHideBlizzard = false,
    cdmViewersFollowGroups = true,
    -- Off: tracked buffs use Blizzard's own icons, which is what makes their
    -- swipes work in combat. Ticking it goes back to proxy icons, which cannot.
    cdmProxyBuffIcons = false,
    -- On: tracked buffs and buff bars are drawn as our own icons and bars,
    -- filled in by the client's AuraContainer (Squizzumables_CDMAuras.lua), so
    -- the group's styling applies and the sweep still works in combat. Off
    -- goes back to borrowing Blizzard's frames.
    cdmNativeBuffs = true,

    -- Nameplate purge glow (Squizzumables_Nameplates.lua). Off by default: it
    -- is a nameplate feature in an addon that otherwise has none, and most
    -- players run a nameplate addon with opinions of its own.
    --
    -- The module is currently DISABLED: its .toc line is commented out and its
    -- options tab is unwired, so none of these are read. They stay so that a
    -- profile written while it was enabled still loads, and so the feature can
    -- be revived without a migration. See CLAUDE.md.
    npPurgeEnabled = false,
    npPurgeOnlyWhenCapable = true,
    npPurgeTargetOnly = false,
    npPurgeCombatOnly = false,
    npPurgeInstanceOnly = false,
    npPurgeMaxIcons = 3,
    npPurgeIconSize = 26,
    npPurgeSpacing = 2,
    npPurgePerRow = 3,
    npPurgeAnchor = "TOP",          -- TOP, BOTTOM, LEFT, RIGHT of the health bar
    npPurgeOffsetX = 0,
    npPurgeOffsetY = 4,
    npPurgeShape = "none",
    npPurgeZoom = 0.07,
    npPurgeBorder = true,
    npPurgeBorderColor = { 0, 0, 0, 0.9 },
    npPurgeShowDuration = true,
    npPurgeDurationSize = 12,
    npPurgeShowStacks = true,
    npPurgeStackSize = 11,
    npPurgeGlow = true,
    npPurgeGlowStyle = "halo",      -- "halo" (ours) or "game" (Blizzard's)
    npPurgeGlowColor = { r = 1, g = 0.82, b = 0 },

    -- Where the addon shows itself. Filled from CONTENT_TYPES on load, so a
    -- content type added later reaches existing players through ApplyDefaults
    -- rather than needing a migration.
    contentTypes = {},
    -- Minimap button. The angle is where round the minimap it was dragged to;
    -- 200 degrees puts it bottom-left, clear of the default clock and tracking
    -- icons.
    minimapButtonAngle = 200,

    -- Feast announce
    feastAnnounceText = "",
    -- Per-context channels (mirrors WindTools Announcement system)
    feastAnnounceChannel = {
        solo     = "NONE",
        party    = "PARTY",
        instance = "INSTANCE_CHAT",
        raid     = "RAID",
    },

    -- Dungeon callouts (array of {instanceID, name, buttons={...}})
    dungeonCallouts = {},

    -- Class buff sound alert (per-spellID, indexed by spellID)
    classBuffSounds = {},

    -- User-registered custom sounds (array of {name=string, file=string})
    -- Files should be placed in Interface\AddOns\Squizzumables\Media\Sounds\
    customSounds = {},


    -- Buff sounds: a sound when one of the player's own auras is applied or
    -- removed, keyed by aura spell ID.
    --
    --   [spellID] = { added = <sound name>, removed = <sound name>,
    --                 channel = "Master" }
    --
    -- Separate from `alerts` below because it is a different mechanism, not a
    -- variant of one. These are handed to C_UnitAuras.AddAuraSound and played
    -- by the client, which is the only way to alert on an aura that is secret
    -- in combat -- and the reason there is no image: the client plays the sound
    -- and reports nothing back, so there is no moment at which we could draw
    -- anything. See Alerts/BuffSounds.lua.
    buffSounds = {},

    -- Kelerts: the lust alert.
    --
    -- Once a general "alert on any aura you name" system; that half is gone,
    -- replaced by buffSounds above, because an image alert cannot fire on a
    -- secret aura no matter how it is wired. What remains is the lust alert,
    -- which still works precisely because the lust debuffs are among the few
    -- auras the client keeps readable in combat.
    alerts = {
        lust = {
            name    = "Lust / Exhaustion",
            builtin = true,
            trigger = { type = "aura", harmful = true },
            enabled           = false,
            texture           = "duckrun",
            sound             = "Squizzumables: Ducky",
            duration          = 5,
            frameCount        = 15,
            fps               = 30,
            loop              = true,
            opacity           = 1.0,
            soundLoop         = false,
            soundLoopInterval = 2.0,
            soundChannel      = "Master",
            -- Random sound pool: [soundName] = true for sounds included in the
            -- random pick. Empty by default — with nothing checked, the alert
            -- just uses `sound` above unchanged (opt-in feature).
            randomSounds      = {},
        },
    },

}

-- ============================================================================
-- Shared helpers
-- ============================================================================

-- Does the player know this spell?  See BH.PlayerKnowsSpell below.
--
-- This used to fall back through IsPlayerSpell / IsSpellKnownOrOverridesKnown /
-- IsSpellKnown to cover talent-granted and override spells. All three are now
-- deprecated aliases into C_SpellBook, and the fallbacks were dead code besides:
-- C_SpellBook.IsSpellKnown always returns a boolean, so the check ahead of them
-- returned on every call. If a base spell replaced by a talent override ever
-- needs to count as known, C_SpellBook.IsSpellKnownOrInSpellBook(spellID) is the
-- single modern call for it — but that is a behaviour change, not a cleanup.
--
-- Inclusive bag range to scan for consumables.
--
-- This used to be hardcoded as 0..4, which skipped the reagent bag entirely —
-- anything the player kept there was invisible to the addon. NUM_BAG_SLOTS is
-- the four normal bags and NUM_REAGENTBAG_SLOTS is the reagent bag; both are
-- Blizzard constants, with literal fallbacks in case they are ever unset.
local FIRST_BAG = BACKPACK_CONTAINER or 0
local LAST_BAG  = (NUM_BAG_SLOTS or 4) + (NUM_REAGENTBAG_SLOTS or 1)
BH.FIRST_BAG, BH.LAST_BAG = FIRST_BAG, LAST_BAG

-- ----------------------------------------------------------------------------
-- Bag snapshot
--
-- Everything that wants to know "is this item in my bags, and how many" reads
-- this table instead of walking the bags itself.
--
-- The walks were the problem, not their cost individually. UpdateButtons is
-- driven by UNIT_AURA, which fires for every unit in the group on every aura
-- change, so in a raid it runs more or less continuously -- and each run did
-- several full six-bag walks, plus another complete walk inside CountItemInBags
-- for every button it built. The reminder checks were worse again: a bag walk
-- nested inside a loop over the configured consumables, so O(items x bags x
-- slots) each time.
--
-- Bag contents only change on bag events, so the scan belongs there. One walk
-- per actual change, and every consumer becomes a hash lookup.
--
--   BH.bagCache[itemID] = { count, link, quality, bag, slot }
--
-- `count` is the summed stack count; `bag`/`slot` are the first location found,
-- kept because the item link and crafting quality are per-slot data.
-- ----------------------------------------------------------------------------

BH.bagCache = {}

function BH:RebuildBagCache()
    local cache = wipe(self.bagCache)
    for bag = FIRST_BAG, LAST_BAG do
        local slots = C_Container.GetContainerNumSlots(bag)
        for slot = 1, slots do
            local itemID = C_Container.GetContainerItemID(bag, slot)
            if itemID then
                local entry = cache[itemID]
                if entry then
                    local info = C_Container.GetContainerItemInfo(bag, slot)
                    entry.count = entry.count + (info and info.stackCount or 1)
                else
                    local info = C_Container.GetContainerItemInfo(bag, slot)
                    cache[itemID] = {
                        count   = (info and info.stackCount) or 1,
                        link    = C_Container.GetContainerItemLink(bag, slot),
                        -- craftingQuality is real on retail (it drives the quality border);
                        -- the generated ContainerItemInfo annotation just lags behind it.
                        ---@diagnostic disable-next-line: undefined-field
                        quality = info and info.craftingQuality,
                        bag     = bag,
                        slot    = slot,
                    }
                end
            end
        end
    end
    self.bagCacheStale = false
end

-- Rebuild only if something has actually changed since the last scan. Callers
-- can hit this freely; it is a flag check in the common case.
function BH:EnsureBagCache()
    if self.bagCacheStale ~= false then self:RebuildBagCache() end
    return self.bagCache
end

function BH:MarkBagCacheStale()
    self.bagCacheStale = true
end

--- The cache entry for an item, or nil if it is not in the player's bags.
function BH:GetBagEntry(itemID)
    if not itemID then return nil end
    return self:EnsureBagCache()[itemID]
end

--- Is this item in the player's bags at all?
function BH:HasItemInBags(itemID)
    return self:GetBagEntry(itemID) ~= nil
end

-- ----------------------------------------------------------------------------
-- Options-panel widget cache
--
-- WoW frames are never garbage collected: SetParent(nil) orphans a frame but
-- does not free it. The options lists used to destroy and rebuild their rows on
-- every refresh, so each /sq config leaked a full set of frames for the rest of
-- the session.
--
-- These lists are rebuilt from the same stable data every time, so instead of
-- pooling anonymous frames we cache each widget under a key describing what it
-- represents. A refresh hides everything in the cache, then re-acquires and
-- re-anchors the widgets it still needs; only genuinely new keys allocate.
--
-- Usage:
--     self:ResetWidgetCache("itemRowCache")
--     local row, isNew = self:AcquireWidget("itemRowCache", key, factory)
--     if isNew then ... end   -- one-time setup
--     row:Show()
-- ----------------------------------------------------------------------------

-- Hide and unanchor every widget in a cache, ready for a refresh pass.
function BH:ResetWidgetCache(cacheName)
    local cache = self[cacheName]
    if not cache then return end
    for _, widget in pairs(cache) do
        if widget.Hide then widget:Hide() end
        if widget.ClearAllPoints then widget:ClearAllPoints() end
    end
end

-- Fetch the cached widget for `key`, creating it via `factory()` on a miss.
-- Returns the widget and whether it was created on this call.
function BH:AcquireWidget(cacheName, key, factory)
    local cache = self[cacheName]
    if not cache then
        cache = {}
        self[cacheName] = cache
    end
    local widget = cache[key]
    if widget then
        return widget, false
    end
    widget = factory()
    cache[key] = widget
    return widget, true
end

-- Use this instead of IsSpellKnown anywhere in the addon.
function BH.PlayerKnowsSpell(spellID)
    if not spellID then return false end
    -- The IsPlayerSpell / IsSpellKnownOrOverridesKnown / IsSpellKnown globals that
    -- used to follow this check are all deprecated aliases into C_SpellBook, and
    -- were unreachable anyway: IsSpellKnown always returns a boolean, so the
    -- `known ~= nil` return above fired every time. See the note in the release
    -- notes about C_SpellBook.IsSpellKnownOrInSpellBook if override spells ever
    -- need to count as known.
    if C_SpellBook and C_SpellBook.IsSpellKnown then
        local known = C_SpellBook.IsSpellKnown(spellID)
        if known ~= nil then return known end
    end
    return false
end

-- ============================================================================
-- Profile System
-- ============================================================================

-- Every draggable frame that persists its own anchor, as
-- { <key on BH holding the frame>, <SquizzumablesDB key holding the position> }.
-- This table is the single source of truth for three things:
--   1. PROFILE_POSITION_KEYS below (what moves between profiles)
--   2. the generated BH:Save<Name>Position / BH:Load<Name>Position wrappers (see
--      the loop after BH:LoadFramePos)
--   3. BH:LoadAllFramePositions (re-anchors everything after a profile switch)
-- Add a new draggable frame here and all three follow automatically.
-- The consumable categories, in display order.
--
-- One list, because the empty customItems table used to be written out
-- longhand in seven places -- so adding a category meant finding all seven,
-- and missing one would silently drop the player's custom items for it.
local CONSUMABLE_CATEGORIES = { "food", "flask", "oil", "augmentRune" }
BH.CONSUMABLE_CATEGORIES = CONSUMABLE_CATEGORIES

-- Category display names, for the options UI and reminder text.
local CONSUMABLE_LABELS = {
    food = "Food", flask = "Flask", oil = "Weapon Oil", augmentRune = "Augment Rune",
}
BH.CONSUMABLE_LABELS = CONSUMABLE_LABELS

local function NewCustomItemsTable()
    local t = {}
    for _, cat in ipairs(CONSUMABLE_CATEGORIES) do t[cat] = {} end
    return t
end
-- Exposed so ProfileIO can build the same shape on import rather than
-- carrying its own literal, which had already fallen a category behind.
BH.NewCustomItemsTable = NewCustomItemsTable

local POSITION_PAIRS = {
    { "markersFrame",             "markersPosition" },
    { "pullReadyFrame",           "pullReadyPosition" },
    -- Beacon, Earth Shield, Symbiotic and No Pet sit in this one frame since
    -- 2.0 (migration 9 carried their positions over).
    { "classReminderFrame",       "classReminderPosition" },
    { "repairReminderFrame",      "repairReminderPosition" },
    { "coachWhistleReminderFrame","coachWhistleReminderPosition" },
    { "bresCounterFrame",         "bresCounterPosition" },
    { "healthstoneReminderFrame", "healthstoneReminderPosition" },
    { "bagsReminderFrame",        "bagsReminderPosition" },
    { "healerCCReminderFrame",    "healerCCReminderPosition" },
    { "deathTallyFrame",          "deathTallyPosition" },
    { "targetDistanceFrame",      "targetDistancePosition" },
}

-- All position keys stored in profiles.
-- Derived from POSITION_PAIRS plus the frames whose Save/Load wrappers are
-- hand-written rather than generated:
--   framePosition         — the main button frame (BH:SaveFramePosition)
--   calloutsFramePosition — the dungeon callouts button frame
--   kelAlertPosition      — the Just For Kel alert (Alerts/Kelerts.lua)
-- Deliberately NOT included: raidToolsPosition, a pre-1.x key that
-- BH:LoadMarkersPosition migrates into markersPosition and then clears.
local PROFILE_POSITION_KEYS = {
    "framePosition",
    "calloutsFramePosition",
    "kelAlertPosition",
}
for _, pair in ipairs(POSITION_PAIRS) do
    PROFILE_POSITION_KEYS[#PROFILE_POSITION_KEYS + 1] = pair[2]
end

-- Get character-realm key for the current character
function BH:GetCharKey()
    local name = UnitName("player")
    local realm = GetNormalizedRealmName() or GetRealmName() or "Unknown"
    return name .. "-" .. realm
end

-- Ensure profile tables exist, and migrate legacy data if needed
function BH:EnsureProfiles()
    if not SquizzumablesDB then SquizzumablesDB = {} end

    if not SquizzumablesDB.profiles then
        -- First time: migrate existing data into a Default profile
        SquizzumablesDB.profiles = {}
        local defaultProfile = {
            settings = SquizzumablesDB.settings and CopyTable(SquizzumablesDB.settings) or CopyTable(BH.defaultSettings),
            disabled = SquizzumablesDB.disabled and CopyTable(SquizzumablesDB.disabled) or {},
            minDuration = SquizzumablesDB.minDuration and CopyTable(SquizzumablesDB.minDuration) or {},
            customItems = SquizzumablesDB.customItems and CopyTable(SquizzumablesDB.customItems) or NewCustomItemsTable(),
            positions = {},
        }
        -- Migrate position data
        for _, key in ipairs(PROFILE_POSITION_KEYS) do
            if SquizzumablesDB[key] then
                defaultProfile.positions[key] = CopyTable(SquizzumablesDB[key])
            end
        end
        SquizzumablesDB.profiles["Default"] = defaultProfile
    end

    if not SquizzumablesDB.charProfiles then
        SquizzumablesDB.charProfiles = {}
    end

    if not SquizzumablesDB.specProfiles then
        SquizzumablesDB.specProfiles = {}
    end

    -- Ensure Default profile always exists
    if not SquizzumablesDB.profiles["Default"] then
        SquizzumablesDB.profiles["Default"] = {
            settings = CopyTable(BH.defaultSettings),
            disabled = {},
            minDuration = {},
            customItems = NewCustomItemsTable(),
            positions = {},
        }
    end

    -- Assign current character to Default if no assignment
    local charKey = self:GetCharKey()
    if not SquizzumablesDB.charProfiles[charKey] then
        SquizzumablesDB.charProfiles[charKey] = "Default"
    end

    -- Verify assignment points to an existing profile
    local assigned = SquizzumablesDB.charProfiles[charKey]
    if not SquizzumablesDB.profiles[assigned] then
        SquizzumablesDB.charProfiles[charKey] = "Default"
    end
end

-- Get the active profile name for the current character.
-- If a spec-specific profile is assigned for the current spec, that wins;
-- otherwise falls back to the character-level profile assignment.
function BH:GetActiveProfileName()
    local charKey = self:GetCharKey()
    -- Check spec-specific override first
    local specID = self:GetCurrentSpecID()
    if specID and SquizzumablesDB.specProfiles then
        local charSpecProfiles = SquizzumablesDB.specProfiles[charKey]
        if charSpecProfiles and charSpecProfiles[specID] then
            local specProfileName = charSpecProfiles[specID]
            -- Verify the profile still exists
            if SquizzumablesDB.profiles and SquizzumablesDB.profiles[specProfileName] then
                return specProfileName
            end
        end
    end
    return SquizzumablesDB.charProfiles and SquizzumablesDB.charProfiles[charKey] or "Default"
end

-- Get the active profile table
function BH:GetActiveProfile()
    local name = self:GetActiveProfileName()
    return SquizzumablesDB.profiles and SquizzumablesDB.profiles[name]
end

-- Save current runtime data into the active profile
function BH:SaveToProfile()
    local profile = self:GetActiveProfile()
    if not profile then return end

    profile.settings = CopyTable(SquizzumablesDB.settings or {})
    profile.disabled = CopyTable(SquizzumablesDB.disabled or {})
    profile.minDuration = CopyTable(SquizzumablesDB.minDuration or {})
    profile.customItems = CopyTable(SquizzumablesDB.customItems or NewCustomItemsTable())

    if not profile.positions then profile.positions = {} end
    for _, key in ipairs(PROFILE_POSITION_KEYS) do
        if SquizzumablesDB[key] then
            profile.positions[key] = CopyTable(SquizzumablesDB[key])
        end
    end
end

-- Load a profile's data into runtime SquizzumablesDB locations
function BH:LoadFromProfile(profileName)
    local profile = SquizzumablesDB.profiles and SquizzumablesDB.profiles[profileName]
    if not profile then return end

    SquizzumablesDB.settings = CopyTable(profile.settings or BH.defaultSettings)
    SquizzumablesDB.disabled = CopyTable(profile.disabled or {})
    SquizzumablesDB.minDuration = CopyTable(profile.minDuration or {})
    SquizzumablesDB.customItems = CopyTable(profile.customItems or NewCustomItemsTable())

    if profile.positions then
        for _, key in ipairs(PROFILE_POSITION_KEYS) do
            if profile.positions[key] then
                SquizzumablesDB[key] = CopyTable(profile.positions[key])
            else
                SquizzumablesDB[key] = nil
            end
        end
    end
end

-- Save a single position key to the active profile
function BH:SavePositionToProfile(posKey)
    local profile = self:GetActiveProfile()
    if not profile then return end
    if not profile.positions then profile.positions = {} end
    if SquizzumablesDB[posKey] then
        profile.positions[posKey] = CopyTable(SquizzumablesDB[posKey])
    else
        profile.positions[posKey] = nil
    end
end

-- Generic position helpers to reduce per-frame boilerplate.
--   frameRef   : string — key on self that holds the frame (e.g. "frame", "markersFrame")
--   posKey     : string — saved variable key (e.g. "framePosition")
--   defaultPt  : string — optional default anchor point ("CENTER" if nil)
function BH:SaveFramePos(frameRef, posKey)
    local f = self[frameRef]
    if not f then return end
    local point, _, relPoint, x, y = f:GetPoint()
    SquizzumablesDB[posKey] = { point = point, relativePoint = relPoint, x = x, y = y }
    self:SavePositionToProfile(posKey)
end

function BH:LoadFramePos(frameRef, posKey)
    local f = self[frameRef]
    if not f then return end
    local pos = SquizzumablesDB and SquizzumablesDB[posKey]
    if pos then
        f:ClearAllPoints()
        f:SetPoint(pos.point, UIParent, pos.relativePoint, pos.x, pos.y)
    end
end

-- Create a new profile (optionally copying from another)
function BH:CreateProfile(name, copyFrom)
    if not SquizzumablesDB.profiles then return false end
    if SquizzumablesDB.profiles[name] then return false end

    local source = copyFrom and SquizzumablesDB.profiles[copyFrom]
    if source then
        SquizzumablesDB.profiles[name] = CopyTable(source)
    else
        SquizzumablesDB.profiles[name] = {
            settings = CopyTable(BH.defaultSettings),
            disabled = {},
            minDuration = {},
            customItems = NewCustomItemsTable(),
            positions = {},
        }
    end
    return true
end

-- Delete a profile (cannot delete Default)
function BH:DeleteProfile(name)
    if name == "Default" then return false end
    if not SquizzumablesDB.profiles or not SquizzumablesDB.profiles[name] then return false end

    -- Reassign any characters using this profile to Default
    if SquizzumablesDB.charProfiles then
        for charKey, profileName in pairs(SquizzumablesDB.charProfiles) do
            if profileName == name then
                SquizzumablesDB.charProfiles[charKey] = "Default"
            end
        end
    end

    SquizzumablesDB.profiles[name] = nil
    return true
end

-- Copy current settings into the Default profile
function BH:UpdateDefaultProfile()
    self:SaveToProfile()
    local active = self:GetActiveProfile()
    if not active then return end
    SquizzumablesDB.profiles["Default"] = CopyTable(active)
end

-- Switch the current character to a different profile
function BH:SwitchToProfile(profileName)
    if not SquizzumablesDB.profiles[profileName] then return false end

    -- Save current data to the old profile first
    self:SaveToProfile()

    -- Assign new profile
    local charKey = self:GetCharKey()
    SquizzumablesDB.charProfiles[charKey] = profileName

    -- Load new profile into runtime
    self:LoadFromProfile(profileName)

    -- Refresh BH references
    self.settings = SquizzumablesDB.settings
    self.disabled = SquizzumablesDB.disabled
    self.minDuration = SquizzumablesDB.minDuration
    self.customItems = SquizzumablesDB.customItems

    -- The Cooldown Manager layout is part of the profile as of 1.70, so it has
    -- to be rebuilt here rather than left showing the old profile's groups.
    -- After the BH references above, since the rebuild reads cdmEnabled.
    if self.cdm and self.cdm.OnProfileChanged then self.cdm:OnProfileChanged() end
    if self.ApplyTargetDistance then self:ApplyTargetDistance() end
    if self.ApplyCursor then self:ApplyCursor() end
    -- The theme is account-wide (shared with SquizzFrames) and does not change with the profile; this only repaints the accent.
    ns.Theme.Apply()

    return true
end

-- Get sorted list of profile names (Default always first)
function BH:GetProfileList()
    local list = {}
    if SquizzumablesDB.profiles then
        for name in pairs(SquizzumablesDB.profiles) do
            table.insert(list, name)
        end
    end
    table.sort(list, function(a, b)
        if a == "Default" then return true end
        if b == "Default" then return false end
        return a < b
    end)
    return list
end

-- Get the numeric spec ID for the player's current specialisation.
-- Returns nil if no spec is active (e.g. no talents chosen yet).
function BH:GetCurrentSpecID()
    local specIndex = GetSpecialization()
    if not specIndex then return nil end
    local specID = select(1, GetSpecializationInfo(specIndex))
    return specID
end

-- Get the spec-profile name assigned to the current spec (or nil = use char profile).
function BH:GetSpecProfile()
    local charKey = self:GetCharKey()
    local specID = self:GetCurrentSpecID()
    if not specID then return nil end
    if not SquizzumablesDB.specProfiles then return nil end
    local charSpecProfiles = SquizzumablesDB.specProfiles[charKey]
    if not charSpecProfiles then return nil end
    local name = charSpecProfiles[specID]
    -- Return nil if profile no longer exists
    if name and SquizzumablesDB.profiles and SquizzumablesDB.profiles[name] then
        return name
    end
    return nil
end

-- Assign (or clear) a spec-specific profile for the current spec.
-- Pass nil to clear (revert to character-level profile).
function BH:SetSpecProfile(profileName)
    local charKey = self:GetCharKey()
    local specID = self:GetCurrentSpecID()
    if not specID then return end
    if not SquizzumablesDB.specProfiles then SquizzumablesDB.specProfiles = {} end
    if not SquizzumablesDB.specProfiles[charKey] then
        SquizzumablesDB.specProfiles[charKey] = {}
    end
    if profileName then
        SquizzumablesDB.specProfiles[charKey][specID] = profileName
    else
        SquizzumablesDB.specProfiles[charKey][specID] = nil
    end
end

-- Called on PLAYER_SPECIALIZATION_CHANGED: save old profile then switch to the
-- profile assigned to the new spec (if any).
function BH:OnSpecChanged()
    -- Cannot reposition frames during combat lockdown (ClearAllPoints is protected).
    -- Defer the entire profile switch until combat ends.
    if InCombatLockdown() then
        self.pendingSpecChange = true
        return
    end
    self.pendingSpecChange = nil
    -- Save current settings to whichever profile is active before the spec change.
    self:SaveToProfile()
    -- Determine what profile to load for the new spec.
    local newProfileName = self:GetActiveProfileName()  -- already reads the new spec
    self:LoadFromProfile(newProfileName)
    self.settings  = SquizzumablesDB.settings
    self.disabled  = SquizzumablesDB.disabled
    self.minDuration = SquizzumablesDB.minDuration
    self.customItems = SquizzumablesDB.customItems
    self:LoadAllFramePositions()
    self:ApplyAllFrameScales()
    self:UpdateFrameLock()
    self:UpdateButtons()
    -- A spec change can also change which profile is active (specProfiles), and
    -- the group layout belongs to the profile as of 1.70. The per-spec half of
    -- the CDM data -- assignments and free icons -- changes here too, so the
    -- cached view is stale either way.
    if self.cdm and self.cdm.OnProfileChanged then self.cdm:OnProfileChanged() end
    if self.ApplyTargetDistance then self:ApplyTargetDistance() end
    if self.ApplyCursor then self:ApplyCursor() end
    -- The theme is account-wide (shared with SquizzFrames) and does not change with the profile; this only repaints the accent.
    ns.Theme.Apply()
    -- Outside the panel check: the new profile has its own alerts, so the
    -- client-side aura sound registrations have to follow it whether or not the
    -- options panel happens to be open. Leaving them would keep playing the
    -- previous profile's sounds with nothing on screen explaining why.
    if self.RefreshAuraSoundRegistrations then self:RefreshAuraSoundRegistrations("profile load") end
    if self.optionsPanel and self.optionsPanel:IsShown() then
        self:RefreshSettingsTab()
        self:RefreshItemList()
        self:RefreshRaidToolsTab()
        self:RefreshTextRemindersTab()
        if self.RefreshJustForKelTab then self:RefreshJustForKelTab() end
    end
end

-- Load settings
-- ----------------------------------------------------------------------------
-- Defaults and versioned migrations
--
-- Two separate jobs that were previously tangled together in LoadSettings:
--
--   MIGRATIONS     run once each, in order, to repair existing saved data.
--   ApplyDefaults  runs every load, after them. Backfills anything still
--                  missing, at any depth.
--
-- Migrations run first because ApplyDefaults replaces any value whose default
-- is a table -- so a legacy string where a table is now expected would be gone
-- before the migration that knows how to convert it ever sees it.
--
-- The old code filled only top-level keys and then hand-wrote a deep merge for
-- each nested table that turned out to need one -- kelLustAlert, then
-- feastAnnounceChannel. Every future nested default would have silently failed
-- to reach existing users until someone noticed, which is exactly how
-- kelLustMigrated2 and kelLustMigrated3 came to exist.
-- ----------------------------------------------------------------------------

-- Fill in anything absent from `tbl` that `defaults` defines, recursively.
-- Never overwrites a value the player has set, including `false`.
local function ApplyDefaults(tbl, defaults)
    for k, v in pairs(defaults) do
        if type(v) == "table" then
            if type(tbl[k]) ~= "table" then tbl[k] = {} end
            ApplyDefaults(tbl[k], v)
        elseif tbl[k] == nil then
            tbl[k] = v
        end
    end
    return tbl
end
BH.ApplyDefaults = ApplyDefaults

-- Ordered, run-once fixes for saved data. Keyed by the dbVersion they bring the
-- database up to, so adding one means appending an entry and bumping
-- DB_VERSION -- no new boolean flag in SquizzumablesDB each time.
--
-- Each receives (db, settings). They only ever repair existing data: a fresh
-- install is stamped at DB_VERSION and skips all of them, so it cannot be
-- retroactively "fixed" into defaults that no longer apply.
local DB_VERSION = 9

local MIGRATIONS = {
    -- v1: the lust alert shipped with enabled = false by mistake.
    [1] = function(_, s)
        if type(s.kelLustAlert) == "table" and s.kelLustAlert.enabled == false then
            s.kelLustAlert.enabled = true
        end
    end,

    -- v2: its sound defaulted to "None"; give it the raid warning.
    [2] = function(_, s)
        if type(s.kelLustAlert) == "table" and s.kelLustAlert.sound == "None" then
            s.kelLustAlert.sound = "__builtin_raidwarning"
        end
    end,

    -- v3: duckrun became the default texture/frames/fps/sound.
    [3] = function(_, s)
        if type(s.kelLustAlert) ~= "table" then return end
        local la = s.kelLustAlert
        if la.texture == "" or la.texture == nil then la.texture = "duckrun" end
        if (la.frameCount or 0) == 0 then la.frameCount = 15 end
        if (la.fps or 10) == 10 then la.fps = 30 end
        if la.sound == "None" or la.sound == "__builtin_raidwarning" or la.sound == nil then
            la.sound = "Squizzumables: Ducky"
        end
    end,

    -- v5: the single kelLustAlert became one entry in an alerts table, so the
    -- player can add their own. Carries the configured alert across rather
    -- than letting ApplyDefaults hand back a fresh one -- someone who picked
    -- a texture and sound should keep them.
    --
    -- Unlike the earlier migrations this also walks the stored profiles. Those
    -- are copied wholesale into the live settings on a profile switch, and
    -- ApplyDefaults does not run again at that point, so a profile left holding
    -- the old key would quietly lose its alert the first time it was selected.
    [5] = function(db, s)
        local function MoveAlert(t)
            if type(t) ~= "table" or type(t.kelLustAlert) ~= "table" then return end
            t.alerts = t.alerts or {}
            local moved = t.kelLustAlert
            moved.name    = moved.name or "Lust / Exhaustion"
            moved.builtin = true
            moved.trigger = moved.trigger or { type = "aura", harmful = true }
            t.alerts.lust = moved
            t.kelLustAlert = nil
        end

        MoveAlert(s)
        for _, profile in pairs(db.profiles or {}) do
            MoveAlert(profile.settings)
        end
    end,

    -- v4: feastAnnounceChannel went from a single string to a per-context table.
    [4] = function(_, s)
        if type(s.feastAnnounceChannel) ~= "string" then return end
        local old = s.feastAnnounceChannel
        s.feastAnnounceChannel = CopyTable(BH.defaultSettings.feastAnnounceChannel)
        -- Keep the player's old choice where it still means something.
        if old == "INSTANCE_CHAT" then
            s.feastAnnounceChannel.party    = "INSTANCE_CHAT"
            s.feastAnnounceChannel.instance = "INSTANCE_CHAT"
        elseif old == "RAID" or old == "RAID_WARNING" then
            s.feastAnnounceChannel.party    = old
            s.feastAnnounceChannel.instance = old
            s.feastAnnounceChannel.raid     = old
        end
    end,

    -- v6: user-made Kelerts become buff sounds.
    --
    -- They could never fire in combat. A Kelert trigger reads the aura, and
    -- since 12.1 the client hides nearly every aura from addons in combat --
    -- so an alert on an ordinary buff worked in a city and was silent in the
    -- pull it was made for. C_UnitAuras.AddAuraSound plays a sound without any
    -- value reaching addon code, which is the only way through, and it cannot
    -- carry an image because the client reports nothing back.
    --
    -- So the sound survives the move and the image does not. Nothing is
    -- announced to the player: an alert that has never once fired when it
    -- mattered is not a feature worth writing a notice about.
    --
    -- The lust alert stays where it is. It has no trigger.spellID (it watches
    -- five debuffs at once) and those debuffs are among the few the client
    -- leaves readable, so it works in combat today, image and all.
    [6] = function(db, s)
        local function MoveAlerts(t)
            if type(t) ~= "table" or type(t.alerts) ~= "table" then return end
            t.buffSounds = type(t.buffSounds) == "table" and t.buffSounds or {}
            for id, alert in pairs(t.alerts) do
                local spellID = type(alert) == "table" and not alert.builtin
                                and tonumber(alert.trigger and alert.trigger.spellID)
                if spellID then
                    -- Only when the sound is one the client can be handed. A
                    -- Kelert set to "None" carried its whole meaning in the
                    -- image, so there is nothing to migrate and nothing to keep.
                    local sound = alert.sound
                    if sound and sound ~= "None" then
                        t.buffSounds[spellID] = {
                            added   = sound,
                            channel = alert.soundChannel or "Master",
                        }
                    end
                    t.alerts[id] = nil
                end
            end
        end

        MoveAlerts(s)
        for _, profile in pairs(db.profiles or {}) do
            MoveAlerts(profile.settings)
        end
    end,

    -- v7: callouts set to Say or Yell become Instance.
    --
    -- Those two channels are gone. Callout buttons now send through
    -- SendChatMessage rather than a secure macro button, because the macro was
    -- a protected action and the client refused it in Mythic+ -- and SAY/YELL
    -- are the one pair Blizzard restricts for addons inside instances, so they
    -- could not come along.
    --
    -- Rewritten rather than left alone: an unmapped channel would fall back to
    -- Instance at click time anyway, and having the dropdown show a value it no
    -- longer offers is worse than moving it.
    [7] = function(db, s)
        local function Rechannel(t)
            for _, group in ipairs(type(t) == "table" and t.dungeonCallouts or {}) do
                for _, callout in ipairs(group.buttons or {}) do
                    if callout.channel == "SAY" or callout.channel == "YELL" then
                        callout.channel = "INSTANCE"
                    end
                end
            end
        end

        Rechannel(s)
        for _, profile in pairs(db.profiles or {}) do
            Rechannel(profile.settings)
        end
    end,

    -- v8 (2.0): the 2px gap between an icon and the label below it moved from
    -- the Label Y Offset's default (-2) into the Below position itself, so 0
    -- now means "just under the icon" like every other position. Only the
    -- exact old default is rewritten, so a label the player moved stays put
    -- and one that was never touched draws exactly where it did.
    [8] = function(db, s)
        local function Rezero(t)
            if type(t) == "table" and t.buttonLabelOffsetY == -2 then t.buttonLabelOffsetY = 0 end
        end
        Rezero(s)
        for _, profile in pairs(db.profiles or {}) do
            Rezero(profile.settings)
        end
    end,

    -- v9 (2.0): Beacon, Earth Shield, Symbiotic and No Pet became one Class
    -- Reminder frame (user request 2026-10-16). It takes the position, scale
    -- and lock of the reminder for the class being played, so it stays where
    -- the player put it; a profile with no saved position for that one takes
    -- the first of the others that has one. The four old locks are set to
    -- the shared one, since the reminders' own code still reads them. The old
    -- position keys are left in place, unused.
    [9] = function(db, s)
        local _, class = UnitClass("player")
        local order = {}
        for _, key in ipairs(BH.CLASS_REMINDER_KEYS) do
            if BH.REMINDERS_BY_KEY[key].class == class then
                table.insert(order, 1, key)
            else
                order[#order + 1] = key
            end
        end

        local function Carry(settings, positions)
            local src = order[1]
            if positions and not positions[src .. "ReminderPosition"] then
                for _, key in ipairs(order) do
                    if positions[key .. "ReminderPosition"] then src = key break end
                end
            end
            if type(settings) == "table" then
                settings.classReminderScale  = settings[src .. "ReminderScale"] or 1.0
                settings.classReminderLocked = settings[src .. "ReminderLocked"] and true or false
                for _, key in ipairs(order) do
                    settings[key .. "ReminderLocked"] = settings.classReminderLocked
                end
            end
            local pos = positions and positions[src .. "ReminderPosition"]
            if pos then positions.classReminderPosition = CopyTable(pos) end
        end

        Carry(s, db)
        for _, profile in pairs(db.profiles or {}) do
            Carry(profile.settings, profile.positions)
        end
    end,
}

-- Run whichever migrations this database has not seen, in order.
local function RunMigrations(db, settings, isNewInstall)
    if isNewInstall then
        db.dbVersion = DB_VERSION
        return
    end

    -- No dbVersion yet: either a genuinely old database, or one from before
    -- versioning. The three legacy booleans say which of the first three
    -- migrations already ran; anything they do not cover starts from zero.
    if db.dbVersion == nil then
        local done = 0
        if db.kelLustMigrated  then done = 1 end
        if db.kelLustMigrated2 then done = 2 end
        if db.kelLustMigrated3 then done = 3 end
        db.dbVersion = done
    end

    for version = db.dbVersion + 1, DB_VERSION do
        local migrate = MIGRATIONS[version]
        if migrate then migrate(db, settings) end
        db.dbVersion = version
    end
end

function BH:LoadSettings()
    -- Always use defaults for consumables and class buffs
    -- This ensures new items added to config are always available
    local defaults = BH.defaults or {}

    -- A genuinely new install, decided BEFORE anything below creates the
    -- profiles and settings. It used to be `not SquizzumablesDB.settings`, read
    -- after EnsureProfiles and LoadFromProfile had already made them, so it
    -- was never true: a new install ran every old-data migration on fresh
    -- defaults, and Core/Welcome.lua's greeting -- which tested the same thing
    -- four seconds after login -- never once showed. Read by RunMigrations and
    -- by the first-run check (BH.freshInstall), which shows setup (2.0).
    local freshInstall = not (SquizzumablesDB and (SquizzumablesDB.settings or SquizzumablesDB.profiles))
    if BH.freshInstall == nil then BH.freshInstall = freshInstall end

    -- Initialize SquizzumablesDB if needed
    if not SquizzumablesDB then
        SquizzumablesDB = {}
    end
    
    -- Initialize and migrate profile system
    self:EnsureProfiles()
    
    -- Load active profile into runtime
    self:LoadFromProfile(self:GetActiveProfileName())
    
    -- Ensure disabled table exists (preserves user preferences)
    if not SquizzumablesDB.disabled then
        SquizzumablesDB.disabled = {}
    end
    
    -- Ensure minDuration table exists (per-item min duration before showing)
    if not SquizzumablesDB.minDuration then
        SquizzumablesDB.minDuration = {}
    end
    
    -- Ensure customItems table exists for user-added items
    if not SquizzumablesDB.customItems then
        SquizzumablesDB.customItems = NewCustomItemsTable()
    end
    
    -- Load appearance settings with defaults
    local isNewInstall = freshInstall
    if not SquizzumablesDB.settings then
        SquizzumablesDB.settings = CopyTable(BH.defaultSettings)
    end
    self.settings = SquizzumablesDB.settings

    -- Migrations first, then defaults. The order matters: ApplyDefaults
    -- replaces any value whose default is a table, so on a legacy database
    -- where feastAnnounceChannel is still a plain string it would wipe that
    -- string before migration 4 could read the player's old choice out of it.
    RunMigrations(SquizzumablesDB, self.settings, isNewInstall)

    -- Then backfill anything still missing, at any depth.
    ApplyDefaults(self.settings, BH.defaultSettings)
    -- Join the theme shared with SquizzFrames (account-wide), offering this
    -- profile's own pre-sharing choice as the seed, then repaint from it.
    ns.Theme.Attach(isNewInstall)
    ns.Theme.Apply()

    -- Enforce minimum button spacing
    if self.settings.buttonSpacing < 5 then
        self.settings.buttonSpacing = 5
    end
    
    -- Start with defaults
    self.consumables = CopyTable(defaults.consumables or {})
    self.classBuffs = CopyTable(defaults.classBuffs or {})
    self.disabled = SquizzumablesDB.disabled
    self.minDuration = SquizzumablesDB.minDuration
    self.customItems = SquizzumablesDB.customItems
    
    -- Merge custom items into consumables
    for category, items in pairs(self.customItems) do
        if self.consumables[category] then
            for _, itemID in ipairs(items) do
                -- Only add if not already in list
                local exists = false
                for _, existingID in ipairs(self.consumables[category]) do
                    if existingID == itemID then
                        exists = true
                        break
                    end
                end
                if not exists then
                    table.insert(self.consumables[category], itemID)
                end
            end
        end
    end
    
    -- Apply frame lock setting
    self:UpdateFrameLock()
    -- Apply drag handle position
end

-- Save settings
function BH:SaveSettings()
    -- Save disabled preferences, custom items, min durations, and settings
    SquizzumablesDB.disabled = self.disabled
    SquizzumablesDB.minDuration = self.minDuration
    SquizzumablesDB.customItems = self.customItems
    SquizzumablesDB.settings = self.settings
    -- Also save to active profile
    self:SaveToProfile()
end

-- Save/Load frame position (main consumable frame)
function BH:SaveFramePosition()
    self:SaveFramePos("frame", "framePosition")
end
function BH:LoadFramePosition()
    self:LoadFramePos("frame", "framePosition")
end
function BH:ResetFramePosition()
    self.frame:ClearAllPoints()
    self.frame:SetPoint("CENTER")
    SquizzumablesDB.framePosition = nil
    self:SavePositionToProfile("framePosition")
end

-- Save/Load reminder frame positions — thin wrappers around the generic helpers.
-- POSITION_PAIRS is declared up in the Profile System section, since
-- PROFILE_POSITION_KEYS is derived from it.
for _, pair in ipairs(POSITION_PAIRS) do
    local frameRef, posKey = pair[1], pair[2]
    -- Derive the function base name by stripping a trailing "Frame" and capitalizing.
    -- e.g. "markersFrame" → "Markers", "healerCCReminderFrame" → "HealerCCReminder"
    local baseName = frameRef:gsub("Frame$", ""):gsub("^%l", string.upper)
    BH["Save" .. baseName .. "Position"] = function(self)
        self:SaveFramePos(frameRef, posKey)
    end
    BH["Load" .. baseName .. "Position"] = function(self)
        self:LoadFramePos(frameRef, posKey)
    end
end

-- LoadMarkersPosition migration for old single-frame position
function BH:LoadMarkersPosition()
    self:LoadFramePos("markersFrame", "markersPosition")
    if SquizzumablesDB and SquizzumablesDB.raidToolsPosition then
        if not SquizzumablesDB.markersPosition and self.markersFrame then
            local pos = SquizzumablesDB.raidToolsPosition
            self.markersFrame:ClearAllPoints()
            self.markersFrame:SetPoint(pos.point, UIParent, pos.relativePoint, pos.x, pos.y)
        end
        SquizzumablesDB.raidToolsPosition = nil
    end
end

-- Re-anchor every draggable frame from the current SquizzumablesDB positions.
-- Call this after anything that swaps the underlying position data wholesale —
-- profile switch, profile create, profile delete, and login.
--
-- Previously each of those sites hand-listed the loaders to call and every list
-- was missing a different subset (coach whistle, pet, flask, oil, healer CC,
-- Kel alert and callouts were never re-anchored on a profile switch).
function BH:LoadAllFramePositions()
    -- The Class Reminder frame takes the size of this character's reminder
    -- before it is placed: a position saved by a corner then lands exactly
    -- where that reminder was (migration 9 copied it from there).
    if self.classReminderFrame and self.ClassReminderKey then
        local def = BH.REMINDERS_BY_KEY[self:ClassReminderKey()]
        if def then self.classReminderFrame:SetSize(def.size[1], def.size[2]) end
    end
    self:LoadFramePosition()        -- main button frame
    self:UpdateFrameAnchor()        -- ...onto its grow edge, in place (2.0)
    self:LoadMarkersPosition()      -- has its own legacy raidToolsPosition migration
    for _, pair in ipairs(POSITION_PAIRS) do
        if pair[2] ~= "markersPosition" then   -- already done above, with migration
            self:LoadFramePos(pair[1], pair[2])
        end
    end
    self:LoadCalloutsFramePosition()
    if self.LoadKelAlertPosition then self:LoadKelAlertPosition() end
end

-- Apply each frame's saved scale setting. Frames whose scale is configurable use
-- the settings key "<key>Scale"; the value is stored as a 0-2 multiplier.
local SCALED_FRAMES = {
    -- One scale for the four class reminders, on the frame they sit in.
    { "classReminderFrame",       "classReminderScale" },
    { "repairReminderFrame",      "repairReminderScale" },
    { "coachWhistleReminderFrame","coachWhistleReminderScale" },
    { "bresCounterFrame",         "bresCounterScale" },
    { "healthstoneReminderFrame", "healthstoneReminderScale" },
    { "bagsReminderFrame",        "bagsReminderScale" },
    { "healerCCReminderFrame",    "healerCCReminderScale" },
    { "kelAlertFrame",            "kelAlertScale" },
    -- deathTallyScale was settable in the Kelerts tab but never re-applied on
    -- login, so the M+ Death Tally always came back at 1.0 after a reload.
    { "deathTallyFrame",          "deathTallyScale" },
}
-- Not listed here: raidToolsMarkersScale / raidToolsPullReadyScale, which
-- BH:CreateRaidToolsFrame applies itself when it builds those frames.
function BH:ApplyAllFrameScales()
    for _, pair in ipairs(SCALED_FRAMES) do
        local frame = self[pair[1]]
        if frame then
            frame:SetScale((self.settings and self.settings[pair[2]]) or 1.0)
        end
    end
end

-- The edge of the button block that stays put, from the layout and grow
-- direction (2.0, user request 2026-10-15). It used to be its own Anchor
-- Point setting, defaulting to Left, so a vertical stack set to grow down
-- still grew up AND down from the middle of its left edge unless the player
-- also found and changed the anchor. Growing down means the top stays put.
function BH:GrowAnchor()
    local layout = self.settings and self.settings.layoutDirection or "HORIZONTAL"
    local grow = self.settings and self.settings.growDirection or "RIGHT"
    if grow == "OUTWARD" then return "CENTER" end
    if layout == "VERTICAL" then
        return grow == "UP" and "BOTTOM" or "TOP"
    end
    return grow == "LEFT" and "RIGHT" or "LEFT"
end

-- Re-anchor the frame on its grow edge, where it sits now, so the block grows
-- away from that edge as buttons are added. Called when the layout or grow
-- direction changes, after a drag, and after positions load.
function BH:UpdateFrameAnchor()
    local anchor = self:GrowAnchor()
    local width, height = self.frame:GetSize()
    local cx, cy = self.frame:GetCenter()
    if not cx then return end

    -- Determine where the anchor point currently sits on screen
    local ax, ay = cx, cy
    if anchor == "TOP" then         ay = cy + height / 2
    elseif anchor == "BOTTOM" then  ay = cy - height / 2
    elseif anchor == "LEFT" then    ax = cx - width / 2
    elseif anchor == "RIGHT" then   ax = cx + width / 2
    end

    -- Same anchor point on UIParent
    local pcx, pcy = UIParent:GetCenter()
    local pw, ph = UIParent:GetSize()
    local px, py = pcx, pcy
    if anchor == "TOP" then         py = pcy + ph / 2
    elseif anchor == "BOTTOM" then  py = pcy - ph / 2
    elseif anchor == "LEFT" then    px = pcx - pw / 2
    elseif anchor == "RIGHT" then   px = pcx + pw / 2
    end

    self.frame:ClearAllPoints()
    self.frame:SetPoint(anchor, UIParent, anchor, ax - px, ay - py)
    self:SaveFramePosition()
end

-- Update frame lock state
function BH:UpdateFrameLock()
    if self.unlockMode then
        self.frame:SetMovable(true)
        return
    end
    if self.settings and self.settings.frameLocked then
        self.frame:SetMovable(false)
    else
        self.frame:SetMovable(true)
    end
end

-- Add a custom item to a category
function BH:AddCustomItem(category, itemID)
    if not self.customItems then
        self.customItems = NewCustomItemsTable()
    end
    if not self.customItems[category] then
        self.customItems[category] = {}
    end
    
    -- Check if already exists in defaults or custom
    for _, existingID in ipairs(self.consumables[category] or {}) do
        if existingID == itemID then
            return false, "Item already in list"
        end
    end
    
    -- Add to custom items
    table.insert(self.customItems[category], itemID)
    -- Also add to current consumables
    table.insert(self.consumables[category], itemID)
    return true
end

-- Remove a custom item from a category
function BH:RemoveCustomItem(category, itemID)
    if not self.customItems or not self.customItems[category] then
        return false
    end
    
    -- Check if it's a custom item (not in defaults)
    local isDefault = false
    local defaults = BH.defaults or {}
    if defaults.consumables and defaults.consumables[category] then
        for _, defaultID in ipairs(defaults.consumables[category]) do
            if defaultID == itemID then
                isDefault = true
                break
            end
        end
    end
    
    if isDefault then
        return false, "Cannot remove default items"
    end
    
    -- Remove from custom items
    for i, id in ipairs(self.customItems[category]) do
        if id == itemID then
            table.remove(self.customItems[category], i)
            break
        end
    end
    
    -- Remove from consumables
    for i, id in ipairs(self.consumables[category]) do
        if id == itemID then
            table.remove(self.consumables[category], i)
            break
        end
    end
    
    return true
end

-- Check if item is a custom (user-added) item
function BH:IsCustomItem(category, itemID)
    if not self.customItems or not self.customItems[category] then
        return false
    end
    for _, id in ipairs(self.customItems[category]) do
        if id == itemID then
            return true
        end
    end
    return false
end

-- Check if item/spell is enabled
function BH:IsEnabled(id)
    if not self.disabled then return true end
    return not self.disabled[id]
end

-- Get minimum duration threshold for an item/spell (in minutes, default 30)
function BH:GetMinDuration(id)
    if not self.minDuration then return 30 end
    return self.minDuration[id] or 30
end

-- Set minimum duration threshold for an item/spell (in minutes)
function BH:SetMinDuration(id, minutes)
    if not self.minDuration then
        self.minDuration = {}
    end
    self.minDuration[id] = minutes
end

-- Check if a buff needs refreshing based on min duration setting
-- Returns true if buff is missing OR remaining time is below threshold
function BH:NeedsRefresh(id, expirationTime)
    local minMinutes = self:GetMinDuration(id)
    if minMinutes == 0 then
        -- No minimum set, only show if buff is completely missing
        return expirationTime == nil
    end

    if expirationTime == nil then
        -- Buff is missing
        return true
    end

    -- expirationTime can be a secret number (client 12.1.0+, in combat/M+/PvP);
    -- both the == 0 check and the subtraction below throw on a secret value
    -- rather than just misbehaving. Resolve it once through BH.Secrets; an
    -- unreadable value is treated as "don't nag" rather than risking a
    -- false-positive refresh prompt.
    local expiration = BH.Secrets.SafeNumber(expirationTime, nil)
    if expiration == nil then return false end

    -- expirationTime of 0 means permanent/charge-based buff (no duration)
    if expiration == 0 then return false end

    local remainingMinutes = (expiration - GetTime()) / 60
    return remainingMinutes < minMinutes
end


-- ============================================================================
-- Main Options Panel
-- ============================================================================

-- The options window (2.0.x): LibSquizzShell-1.0, the window shared with
-- SquizzFrames (Libs/; a copy in each addon -- change both and bump MINOR). It
-- draws the title bar (name, search, Unlock Frames, close), the grouped
-- sidebar, each page's header, the preview column, resizing, Escape and the
-- hide-in-combat; this function only registers the pages and builds them.
--
-- What stayed ours:
--   * every page builder, unchanged -- each is handed its frame, as before,
--     and BH[page.field] still names it
--   * the settings search: ns.Rows indexes every row as it is built, and the
--     shell asks it for results (spec.search) so ranking, sub-tab jumps and
--     the flash are exactly what they were
--   * the preview column's content (UI/PreviewColumn.lua), built into the
--     shell's column, with its own heading
--   * BH.switchTab(key), self.optionsPanel (the window frame, still named
--     SQUIZZUMABLESOptions) and self.unlockBtn, which the rest of the addon uses
function BH:CreateOptionsPanel(noShow)
    if not self.consumables then
        self:LoadSettings()
    end

    if self.optionsWindow then
        self:RefreshItemList()
        self:RefreshSettingsTab()
        self:RefreshRaidToolsTab()
        self:RefreshTextRemindersTab()
        if self.RefreshJustForKelTab then self:RefreshJustForKelTab() end
        if not noShow then self.optionsWindow:Open() end
        return
    end

    local Shell = LibStub("LibSquizzShell-1.0")
    local bh = self

    -- The pages, in six named groups (2.0 shell, design doc "Options window").
    -- Keys are the 1.x tab keys, which search, BH.switchTab and the slash
    -- commands use; `field` is the frame's name on BH, which the page builders
    -- and refreshers use; `build` is the BH method that fills it (Consumables
    -- is built by BuildConsumablesPage). No Nameplates page: the purge-glow
    -- module is disabled and unloaded -- see the Nameplate purge glow note in
    -- CLAUDE.md for what to restore when the feature comes back.
    local NAV = {
        { group = "Reminders", pages = {
            { key = "items",      label = "Consumables",      field = "itemsTab",         preview = "buttons",
              subtitle = "Food, flasks, oils and the rest of your consumables" },
            { key = "classbuffs", label = "Class Buffs",      field = "classBuffsTab",    build = "BuildClassBuffsTab", preview = "buttons",
              subtitle = "Your class's buffs, pets and weapon imbues" },
            { key = "reminders",  label = "Text Reminders",   field = "textRemindersTab", build = "BuildTextRemindersTab", preview = "textreminders",
              subtitle = "On-screen reminders for what you're missing" },
        } },
        { group = "Cooldowns", pages = {
            { key = "cdm",        label = "Cooldown Manager", field = "cdmTab",           build = "BuildCDMTab",
              subtitle = "Your cooldown, utility and buff groups" },
            { key = "cdmcustom",  label = "Custom Icons",     field = "cdmCustomTab",     build = "BuildCustomCooldownsTab",
              subtitle = "Icons of your own for spells and items" },
        } },
        { group = "Alerts", pages = {
            { key = "kel",        label = "Kelerts",          field = "kelTab",           build = "BuildJustForKelTab", preview = "kelerts",
              subtitle = "Alerts for buffs, cooldowns and more" },
            { key = "sounds",     label = "Sounds",           field = "soundsTab",        build = "BuildSoundsTab",
              subtitle = "Sounds for your alerts" },
        } },
        { group = "Group", pages = {
            { key = "raidtools",  label = "Raid Tools",       field = "raidToolsTab",     build = "BuildRaidToolsTab", preview = "raidtools",
              subtitle = "Markers, pull timer, ready check and more" },
            { key = "callouts",   label = "Callouts",         field = "calloutsTab",      build = "BuildCalloutsTab", preview = "callouts",
              subtitle = "Quick callouts for your group" },
        } },
        { group = "Fun", pages = {
            { key = "cursor",     label = "Cursor",           field = "cursorTab",        build = "BuildCursorTab", preview = "cursor",
              subtitle = "Effects that follow your cursor" },
        } },
        { group = "General", pages = {
            { key = "settings",   label = "Settings",         field = "settingsTab",      build = "BuildSettingsTab", preview = "buttons",
              subtitle = "Theme, profiles and general options" },
        } },
    }
    -- The order the pages were always BUILT in, kept as it was: a builder may
    -- lean on something an earlier one set up, and the sidebar's order is no
    -- reason to find out. Consumables follows, as it always did.
    local BUILD_ORDER = { "settings", "raidtools", "reminders", "cdm", "cdmcustom", "sounds",
        "classbuffs", "callouts", "kel", "cursor", "items" }

    -- Build a page with ns.Rows.currentPage set, so every option widget it
    -- creates is indexed against it -- that is what lets a search result say
    -- where it lives and jump to it.
    local function Builder(page)
        return function(host)
            bh[page.field] = host
            ns.Rows.currentPage = page
            if page.key == "items" then
                bh:BuildConsumablesPage(host)
            else
                local builder = bh[page.build]
                if builder then builder(bh, host) end
            end
            ns.Rows.currentPage = nil
        end
    end

    local groups = {}
    for _, group in ipairs(NAV) do
        local pages = {}
        for _, page in ipairs(group.pages) do
            local kind = page.preview
            pages[#pages + 1] = {
                key = page.key, label = page.label, subtitle = page.subtitle,
                layout = "fill",
                build = Builder(page),
                preview = kind and function(column)
                    local pc = ns.PreviewColumn.Create(column, kind)
                    if pc then
                        pc:ClearAllPoints()
                        pc:SetAllPoints(column)
                        pc:Show()
                    end
                end or nil,
                previewTitle = false, -- PreviewColumn draws its own heading
            }
        end
        groups[#groups + 1] = { label = group.group, pages = pages }
    end

    Shell:RegisterAddon("Squizzumables", {
        title = "Squizzumables",
        groups = groups,
        -- Our own search: fuzzy, ranked, and its jump opens the right sub-tab
        -- and flashes the row. The window has already shown the page, so the
        -- jump's own switchTab is stood down for the call.
        search = function(query)
            local out = {}
            for _, res in ipairs(ns.Rows.Search(query, 12)) do
                local e = res.entry
                if e.page and e.page.key then
                    out[#out + 1] = {
                        label = e.label,
                        page = e.page.key,
                        path = e.page.label .. ((e.section and e.section.label) and (" > " .. e.section.label) or ""),
                        onSelect = function()
                            local switch = bh.switchTab
                            bh.switchTab = nil
                            ns.Rows.JumpTo(e)
                            bh.switchTab = switch
                        end,
                    }
                end
            end
            return out
        end,
    })

    local win = Shell:CreateWindow({
        name = "SQUIZZUMABLESOptions",
        addons = { "Squizzumables" },
        title = "SQUIZZUMABLES",
        width = 900, height = 620,
        minWidth = 840, minHeight = 520,
        previewWidth = ns.PreviewColumn.WIDTH,
        combat = "hide",
        buttons = {
            { key = "unlock", label = self.unlockMode and "Lock Frames" or "Unlock Frames", width = 112,
              tip = "Makes every draggable frame in the addon visible and movable at once, whatever "
                .. "its own lock setting says. The options panel hides while unlocked so it is not in "
                .. "the way. Also available as /sq unlock.",
              onClick = function() bh:SetUnlockMode(not bh.unlockMode) end },
        },
        -- 2.0 motion: the page coming in fades up over 0.12s (instant with
        -- Reduce motion), its preview with it.
        onShowPage = function(_, _, page)
            if page and page.frame then ns.Motion.Appear(page.frame, 0.12) end
            if page and page.previewFrame then ns.Motion.Appear(page.previewFrame, 0.12) end
        end,
    })
    self.optionsWindow = win
    self.optionsPanel = win.frame
    self.unlockBtn = win.buttons.unlock
    self.switchTab = function(key) win:ShowPage("Squizzumables:" .. key) end

    local order = {}
    for _, key in ipairs(BUILD_ORDER) do order[#order + 1] = "Squizzumables:" .. key end
    win:BuildAllPages(order)

    self:RefreshItemList()
    self:RefreshClassBuffList()
    self:RefreshSettingsTab()
    self:RefreshRaidToolsTab()
    self:RefreshTextRemindersTab()
    if self.RefreshJustForKelTab then self:RefreshJustForKelTab() end
    self:RefreshCalloutsTab()
    -- noShow: built for the combined window (LibSquizzShell), not shown yet.
    if not noShow then win:Open("Squizzumables:settings") end
end

-- The Consumables page: built by hand rather than from rows, as it always was.
function BH:BuildConsumablesPage(itemsTab)
    local desc = itemsTab:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    desc:SetPoint("TOPLEFT", itemsTab, "TOPLEFT", 14, -10)
    desc:SetWidth(400)
    desc:SetText("Check items to enable. Drag items from your bags to the drop zones to add.")
    desc:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])

    local scrollFrame = CreateFrame("ScrollFrame", nil, itemsTab, "UIPanelScrollFrameTemplate")
    ns.TuneScrollStep(scrollFrame)
    scrollFrame:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -8)
    scrollFrame:SetPoint("BOTTOMRIGHT", itemsTab, "BOTTOMRIGHT", -22, 4)

    local scrollChild = CreateFrame("Frame", nil, scrollFrame)
    scrollChild:SetSize(390, 1)
    scrollFrame:SetScrollChild(scrollChild)
    self.scrollChild = scrollChild
end


-- ============================================================================
-- LibSharedMedia-3.0 helper (optional -- gracefully absent if LSM not loaded)
-- ============================================================================

-- The addon's own sound folder: the bundled sounds, and where custom sounds
-- used to have to go. An addon updater replaces this whole folder, so custom
-- files dropped in here were deleted on every update.
local CUSTOM_SOUNDS_PATH = "Interface\\AddOns\\Squizzumables\\Media\\Sounds\\"

-- Where custom sounds go now (V1.89): a sibling folder the updater never
-- installed and so never touches. It has no .toc, so it is not an addon and
-- never shows in the addon list; the client reads loose files by path.
local USER_SOUNDS_PATH = "Interface\\AddOns\\SquizzumablesMedia\\Sounds\\"

-- Custom sound entries carry dir = "media" once added under V1.89 or later.
-- An entry without it predates the move and still points at the old folder,
-- so nobody's existing sound goes quiet.
local function CustomSoundPath(entry)
    if entry.dir == "media" then return USER_SOUNDS_PATH .. entry.file end
    return CUSTOM_SOUNDS_PATH .. entry.file
end

-- Search order for a sound being added: the new folder first, then the old
-- one, so a file somebody already has in Media\Sounds is still found.
local CUSTOM_SOUND_DIRS = {
    { key = "media",  path = USER_SOUNDS_PATH },
    { key = "legacy", path = CUSTOM_SOUNDS_PATH },
}

-- The filenames worth trying for what was typed. Any folder part is dropped
-- (people paste full paths), and with no extension both formats are tried,
-- .ogg first because it is the game's own format.
local function CustomSoundCandidates(input)
    local file = input:gsub("^.*[\\/]", "")
    local lower = file:lower()
    if lower:match("%.ogg$") or lower:match("%.mp3$") then return { file } end
    return { file .. ".ogg", file .. ".mp3" }
end

-- "powerpuff_girls-intro.mp3" -> "Powerpuff Girls Intro".
local function CustomSoundNameFromFile(input)
    local base = input:gsub("^.*[\\/]", "")
    base = base:gsub("%.[Oo][Gg][Gg]$", ""):gsub("%.[Mm][Pp]3$", "")
    base = base:gsub("[_%-]+", " "):gsub("%s+", " ")
    base = base:match("^%s*(.-)%s*$") or ""
    base = base:gsub("(%a)([%w']*)", function(first, rest) return first:upper() .. rest end)
    return base
end

-- One test sound at a time: a new test or preview stops the last one, which
-- matters for anything longer than a ping (a theme tune plays for a while).
local customSoundTestHandle
local function StopCustomSoundTest()
    if customSoundTestHandle then
        StopSound(customSoundTestHandle)
        customSoundTestHandle = nil
    end
end

local function PlayCustomSoundTest(path)
    StopCustomSoundTest()
    local willPlay, handle = PlaySoundFile(path, "Master")
    if willPlay then customSoundTestHandle = handle end
    return willPlay
end

-- Finds a typed sound by PLAYING each candidate until one starts. Addons get
-- no file-exists or directory API, and PlaySoundFile reporting it will not
-- play is the only signal there is (DandersFrames' SoundEngine reads it the
-- same way). The one that is found plays, which doubles as the preview.
--
-- Returns dirKey, file on success, or nil, reason where reason is "off"
-- (sound disabled in the game settings, so nothing can be checked) or
-- "missing".
local function FindCustomSound(input)
    if not GetCVarBool("Sound_EnableAllSound") then
        StopCustomSoundTest()
        return nil, "off"
    end
    for _, dir in ipairs(CUSTOM_SOUND_DIRS) do
        for _, file in ipairs(CustomSoundCandidates(input)) do
            if PlayCustomSoundTest(dir.path .. file) then
                return dir.key, file
            end
        end
    end
    return nil, "missing"
end

local function GetLSM()
    return LibStub and LibStub("LibSharedMedia-3.0", true)
end

-- Returns a sorted list of {text=name, value=name} items for a sound dropdown.
-- Always includes a "None" entry first. Falls back to a small built-in list
-- when LSM is unavailable.
local SQ_BUILTIN_SOUNDS = {
    { text = "None",             value = "None" },
    { text = "Ready Check",      value = "__builtin_readycheck" },
    { text = "Raid Warning",     value = "__builtin_raidwarning" },
    { text = "Quest Complete",   value = "__builtin_questcomplete" },
}

local function BuildSoundDropdownItems()
    local lsm = GetLSM()
    if not lsm then
        return SQ_BUILTIN_SOUNDS
    end
    local names = lsm:List("sound")
    local items = { { text = "None", value = "None" } }
    for _, name in ipairs(names) do
        table.insert(items, { text = name, value = name })
    end
    return items
end

-- Expose as a BH method so other files can build the list
function BH:BuildSoundDropdownItems()
    return BuildSoundDropdownItems()
end

--- Fonts, from LibSharedMedia, with the addon's own default first.
---
--- "__default" rather than nil as the sentinel: a dropdown cannot hold nil as a
--- value, and an empty string would be indistinguishable from an unset setting.
function BH:BuildFontDropdownItems()
    local items = { { text = "Default", value = "__default" } }
    local lsm = GetLSM()
    if not lsm then return items end
    for _, name in ipairs(lsm:List("font") or {}) do
        items[#items + 1] = { text = name, value = name }
    end
    return items
end

-- Plays the named sound via LSM, or falls back to a built-in sound kit.
local function PlaySQSound(soundName, channel)
    if not soundName or soundName == "None" then return end
    channel = channel or "Master"
    local lsm = GetLSM()
    if lsm then
        local path = lsm:Fetch("sound", soundName)
        if path then
            PlaySoundFile(path, channel)
            return
        end
    end
    -- Built-in fallbacks
    if soundName == "__builtin_readycheck"    then PlaySound(8960,  channel) end
    if soundName == "__builtin_raidwarning"   then PlaySound(11742, channel) end
    if soundName == "__builtin_questcomplete" then PlaySound(878,   channel) end
end

-- Public wrapper so other files (e.g. Alerts/Kelerts.lua) can play sounds.
function BH:PlaySound(name, channel)
    PlaySQSound(name, channel)
end

-- The file path behind a media name, without playing it.
--
-- C_UnitAuras.AddAuraSound hands the file to the client to play later, so it
-- needs the path up front rather than a LibSharedMedia name. Returns nil for
-- "None" and for the __builtin_* entries, which are sound kit IDs rather than
-- files and so cannot be registered that way.
function BH:ResolveSoundPath(name)
    if not name or name == "None" then return nil end
    if name:match("^__builtin_") then return nil end
    local lsm = GetLSM()
    if not lsm then return nil end
    return lsm:Fetch("sound", name)
end

-- Sounds that ship with the addon — always available regardless of other addons.
-- Files live in Media\Sounds\ inside this addon folder.
local SQ_BUNDLED_SOUNDS = {
    { name = "Squizzumables: Ducky",              file = "Ducky.ogg" },
    { name = "Squizzumables: Ducky's Lust Attack", file = "DUCKYS_LUST_ATTACK.ogg" },
    { name = "Squizzumables: Move Ya Drongo",     file = "Move_ya_drongo.ogg" },
    { name = "Squizzumables: Ducky's Lust Attack 2", file = "DUCKYS_LUST_ATTACK2.ogg" },
    { name = "Squizzumables: Kel's Flail",        file = "Kel's Flail.ogg" },
    { name = "Squizzumables: Chemical X",         file = "ChemicalX.mp3" },
}

-- Registers all user custom sounds from settings into LibSharedMedia.
-- Called at PLAYER_LOGIN after LoadSettings. Safe to call multiple times.
local function RegisterCustomSoundsWithLSM()
    local lsm = GetLSM()
    if not lsm then return end
    -- Register bundled sounds first
    for _, entry in ipairs(SQ_BUNDLED_SOUNDS) do
        lsm:Register("sound", entry.name, CUSTOM_SOUNDS_PATH .. entry.file)
    end
    -- Register user-added sounds from saved settings
    local sounds = BH.settings and BH.settings.customSounds
    if not sounds then return end
    for _, entry in ipairs(sounds) do
        if entry.name and entry.file and entry.name ~= "" and entry.file ~= "" then
            lsm:Register("sound", entry.name, CustomSoundPath(entry))
        end
    end
end
-- Show or hide the Just For Kel alert image for positioning while frames are
-- unlocked. It is normally only visible for a few seconds when an alert fires,
-- so without this it is the one frame Unlock Frames could not reach.
-- Single entry point for Unlock Frames, used by the Settings button, /sq unlock
-- and the Close button on the floating control. Having one path is what stops
-- the three of them drifting: each has to hide the panel, refresh six different
-- frame groups and keep the button label in sync.
-- Alignment grid and snapping while unlocked: Libs/LibSquizzGrid-1.0, a
-- library shared with SquizzFrames (each embeds a copy; LibStub runs the
-- newer), so one grid and one toolbar serve both addons and either's frames
-- snap to the other's. Its toolbar holds [Grid] and [Snap]; Snap is off by
-- default, and while it is off every drag is the plain StartMoving it always
-- was. Settings are account-wide at SquizzumablesDB.snapGrid.
--
-- Frames that used self:StartMoving() / StopMovingOrSizing() call
-- BH:GridStartMoving / BH:GridStopMoving instead. With Snap on the frame is
-- left anchored CENTER to UIParent's CENTER, which every saver here reads back
-- correctly: SaveFramePos stores GetPoint() generically, and the CDM groups
-- measure with GetCenter().
function BH:Grid()
    local g = LibStub and LibStub("LibSquizzGrid-1.0", true)
    if g and not self._gridStorageSet and SquizzumablesDB then
        SquizzumablesDB.snapGrid = SquizzumablesDB.snapGrid or {}
        g:SetStorage(SquizzumablesDB.snapGrid)
        self._gridStorageSet = true
    end
    return g
end

function BH:GridStartMoving(frame)
    local g = self:Grid()
    if g then
        g:RegisterTarget(frame) -- anything draggable is worth snapping to
        g:StartMoving(frame)
    else
        frame:StartMoving()
    end
end

function BH:GridStopMoving(frame)
    local g = self:Grid()
    if g then g:StopMoving(frame) else frame:StopMovingOrSizing() end
end

-- A frame other frames may snap to. Only used while it is visible.
function BH:GridTarget(frame)
    local g = self:Grid()
    if g and frame then g:RegisterTarget(frame) end
end

--- `keepPanel`: leave the options window open. The preview column's Show
--- Them On Screen button passes it -- its whole point is changing settings
--- while watching the frames (user report 2026-10-16); the window can be
--- dragged aside if it covers one.
--- `quiet`: no chat line. Following Blizzard's Edit Mode (UI/EditMode.lua)
--- passes it, or every visit to Edit Mode would print two.
function BH:SetUnlockMode(on, keepPanel, quiet)
    on = on and true or false
    if self.unlockMode == on then return end

    -- Not during combat lockdown.
    --
    -- SetAllFramesPreview calls EnableMouse on BH.frame (SQUIZZUMABLESFrame),
    -- which parents the SecureActionButtonTemplate consumable buttons. In
    -- combat that is refused with ADDON_ACTION_BLOCKED naming this addon.
    -- ADDON_ACTION_BLOCKED is a client event, not a Lua error, so nothing
    -- aborts: the call silently does nothing and the frames come up unlocked
    -- but not actually mouse-enabled -- boxes you can see and cannot drag.
    --
    -- The flag is set AFTER this check on purpose. It used to be set first, so
    -- a failure part-way left unlockMode true with nothing on screen, and the
    -- `if self.unlockMode == on then return end` above then made every later
    -- attempt a silent no-op until a reload.
    --
    -- Only entering is blocked. Leaving has to work in combat whatever else is
    -- true: zoning into an instance force-locks, and that can land mid-pull --
    -- refusing there would strand the player in unlock mode inside content.
    -- SetAllFramesPreview guards its own mouse calls for that direction.
    if on and InCombatLockdown() then
        print("|cffff6666Squizzumables:|r frames cannot be unlocked during combat. "
            .. "Try again when you leave combat.")
        return
    end

    self.unlockMode = on

    -- The grid and its toolbar come and go with unlock mode. Leaving must work
    -- in combat (see above); hiding a few plain textures is fine there.
    local grid = self:Grid()
    if grid then
        if on then
            -- Every positioned frame is something the others can snap to:
            -- the POSITION_PAIRS frames plus the three kept outside that list
            -- (main buttons, callouts, lust alert). Registering is idempotent,
            -- and a frame not built yet is simply skipped until next time.
            for _, pair in ipairs(POSITION_PAIRS) do self:GridTarget(self[pair[1]]) end
            self:GridTarget(self.frame)
            self:GridTarget(self.calloutsButtonFrame)
            self:GridTarget(self.kelAlertFrame)
            grid:Activate("Squizzumables")
        else
            grid:Deactivate("Squizzumables")
        end
    end

    if on and not keepPanel then
        -- Get the options panel out of the way. It is 820 wide and will usually
        -- be sitting on top of the frames being positioned. Remember whether it
        -- was open so it can be put back when frames are locked again.
        self.unlockReopenPanel = (self.optionsPanel and self.optionsPanel:IsShown()) and true or false
        if self.optionsPanel then self.optionsPanel:Hide() end
    elseif on then
        self.unlockReopenPanel = false
    end

    self:UpdateButtons()
    self:UpdateRaidToolsVisibility()
    self:RefreshAllReminderFrames()
    self:UpdateCalloutsButtonFrame()
    self:UpdateFrameLock()
    self:UpdateKelAlertUnlockState()
    if self.unlockBtn then
        self.unlockBtn:SetText(on and "Lock Frames" or "Unlock Frames")
    end

    if on then
        if not quiet then
            print("Squizzumables: frames unlocked - drag them into place, then click Done or use /sq unlock.")
        end
    else
        if not quiet then print("Squizzumables: frames locked.") end
        if self.unlockReopenPanel then
            self.unlockReopenPanel = false
            self:CreateOptionsPanel()
        end
    end
end

-- The unlock control is free-floating and keeps its own saved position, so it
-- stays where the player parked it across sessions instead of snapping back
-- beside the options panel.
function BH:SaveUnlockControlPosition()
    self:SaveFramePos("previewControlFrame", "unlockControlPosition")
end

function BH:LoadUnlockControlPosition()
    local f = self.previewControlFrame
    if not f then return end
    local pos = SquizzumablesDB and SquizzumablesDB.unlockControlPosition
    if pos then
        f:ClearAllPoints()
        f:SetPoint(pos.point, UIParent, pos.relativePoint, pos.x, pos.y)
    elseif not f:GetPoint() then
        f:ClearAllPoints()
        f:SetPoint("TOP", UIParent, "TOP", 0, -140)
    end
end

function BH:UpdateKelAlertUnlockState()
    local f = self.kelAlertFrame
    if not f and self.LoadKelAlertPosition then
        -- Creates the frame on demand; it is built lazily on first alert.
        self:LoadKelAlertPosition()
        f = self.kelAlertFrame
    end
    if not f then return end

    if self.unlockMode then
        -- Showing the frame is not enough to see it. Its texture is only set
        -- when an alert actually fires, so until then it is a 200x200 frame
        -- drawing nothing -- visible to the mouse but invisible to the eye.
        -- Give it the shared Edit Mode box (UI/EditMode.lua), so there is
        -- something to aim at, named like every other frame.
        ns.EditMode.Show(f, "Lust Alert", {
            find  = "Enable this alert",
            nudge = function(dx, dy)
                f:AdjustPointsOffset(dx, dy)
                BH:SaveKelAlertPosition()
            end,
        })
        -- SetMovable as well as EnableMouse, because "Lock all frames" clears
        -- it (SetAllFramesLocked) and nothing put it back: this frame is not in
        -- MOVABLE_FRAMES, so it misses the SetMovable(true) that
        -- SetAllFramesPreview does for everything else. One press of Lock all
        -- frames used to leave the alert undraggable even here, for the rest of
        -- the session. Preview overrides the lock; so does this.
        f:SetMovable(true)
        f:EnableMouse(true)
        f:Show()
    else
        ns.EditMode.Hide(f)
        -- Always click-through outside Unlock Frames. See EnsureAlertFrame for
        -- why the old per-frame lock setting is not consulted any more.
        f:EnableMouse(false)
        f:Hide()
    end
end


-- Published for Options/SoundsTab.lua (2.0 split), which re-declares them
-- under the same names. None is reassigned after load.
BH.CUSTOM_SOUNDS_PATH      = CUSTOM_SOUNDS_PATH
BH.CustomSoundNameFromFile = CustomSoundNameFromFile
BH.CustomSoundPath         = CustomSoundPath
BH.FindCustomSound         = FindCustomSound
BH.GetLSM                  = GetLSM
BH.SQ_BUNDLED_SOUNDS       = SQ_BUNDLED_SOUNDS
BH.StopCustomSoundTest     = StopCustomSoundTest
BH.PlayCustomSoundTest     = PlayCustomSoundTest


-- Emerald Coach's Whistle constants (declared here so RefreshItemList can reference them)
local COACH_WHISTLE_ITEM_ID = 193718
local COACHED_AURA_SPELL_ID = 386578  -- "Coached" 1-hour buff applied to the coached ally

-- configuration
-- Buffs and consumables are now defined in SQUIZZUMABLES_Config.lua for customization

local function Debug(msg)
    --print(addonName..": "..msg)
end

-- Count total stack quantity of an itemID across all bags
local function CountItemInBags(itemID)
    local entry = BH:GetBagEntry(itemID)
    return entry and entry.count or 0
end

-- create main frame
BH.frame = CreateFrame("Frame", "SQUIZZUMABLESFrame", UIParent)
BH.frame:SetSize(50, 50)
BH.frame:SetPoint("CENTER")
BH.frame:SetMovable(true)
BH.frame:SetClampedToScreen(true)

-- The buttons frame is dragged by grabbing the frame itself, in unlock mode.
--
-- It used to carry a small tab above its top-left corner as the only way to
-- move it, which meant the main frame worked differently from every other
-- frame in the addon and put a permanent scrap of UI on screen. Mouse is off
-- outside unlock mode so this can never intercept a click meant for a button
-- inside it; SetAllFramesPreview turns it on.
BH.frame:EnableMouse(false)
BH.frame:RegisterForDrag("LeftButton")
BH.frame:SetScript("OnDragStart", function(self)
    if BH.unlockMode then BH:GridStartMoving(self) end
end)
BH.frame:SetScript("OnDragStop", function(self)
    BH:GridStopMoving(self)
    -- Re-anchor on the grow edge where it was dropped (a drag re-anchors the
    -- frame on its own); UpdateFrameAnchor saves the position.
    BH:UpdateFrameAnchor()
end)

-- Non-secure container for pet summon buttons.
-- BH.frame is hidden when entering combat; BH.petFrame is a plain Frame so its
-- Show()/Hide() are not protected and can be called from addon code in combat.
-- Pet buttons are parented here so they remain visible/clickable mid-fight.
BH.petFrame = CreateFrame("Frame", "SQUIZZUMABLESPetFrame", UIParent)
BH.petFrame:SetAllPoints(BH.frame)  -- always matches BH.frame's position and size
-- Use the secure state-driver system to show/hide pet buttons in combat.
-- This runs inside WoW's secure execution environment, so it is never blocked
-- by InCombatLockdown.  The value only changes when BOTH [combat] and [pet]
-- are simultaneously true/false; out-of-combat pet changes leave the evaluated
-- value as "show" in all cases, so UpdateButtons() remains in full control
-- of visibility outside combat.
RegisterStateDriver(BH.petFrame, "visibility", "[combat,pet]hide;show")

-- Non-secure container for group-wide class buff buttons (Arcane Intellect,
-- Battle Shout, Mark of the Wild, Skyfury, etc.) that should stay visible in
-- combat.  Unlike BH.frame (hidden on PLAYER_REGEN_DISABLED), this frame is
-- never hidden from combat-lockdown code, so it keeps its pre-combat state.
-- Show()/Hide() are only called from UpdateButtons(), which always runs outside
-- of combat, so no ADDON_ACTION_BLOCKED can occur.
BH.combatBuffFrame = CreateFrame("Frame", "SQUIZZUMABLESCombatBuffFrame", UIParent)
BH.combatBuffFrame:SetAllPoints(BH.frame)  -- always matches BH.frame's position and size
BH.combatBuffFrame:Hide()

-- The buttons frame has no drag tab: it is dragged directly in unlock mode.
-- See the OnDragStart on BH.frame above.

-- icon buttons table
BH.buttons = {}

-- Symbiotic Relationship spell IDs
local SYMBIOTIC_CAST_SPELL_ID = 474750    -- The talent/cast spell
local SYMBIOTIC_AURA_SPELL_ID = 474754    -- The buff on party members

-- build button list
-- M+ active state
BH.challengeModeActive = false
BH.unlockMode = false

-- ============================================================================
-- Text reminder registry
--
-- Every one of these is the same frame: a movable, lockable, scalable label
-- pinned to UIParent that shows when some condition holds. They used to be ten
-- near-identical ~27-line blocks of construction, ten Update<Name>Reminder
-- functions, ten blocks in the options tab and ten branches in the tab's
-- refresh -- around 1,470 lines in which the only thing that actually differed
-- per reminder was the label and one predicate.
--
-- Each entry below drives all of that. Conventions derived from `key`:
--   BH[key.."ReminderFrame"]  / BH[key.."ReminderText"]   the widgets
--   settings[key.."ReminderEnabled" / "Scale" / "Locked"] the settings keys
--   SquizzumablesDB[key.."ReminderPosition"]              the saved anchor
--   BH:Save/Load<Key>ReminderPosition()                   generated already
--     from POSITION_PAIRS, which uses the same naming
--
-- Adding a reminder means adding an entry here and a shouldShow predicate --
-- no new frame code, no new options-tab block, no new settings keys.
-- ============================================================================

BH.REMINDERS = {
    {
        key = "beacon", globalName = "SQUIZZUMABLESBeaconReminder",
        gates = { "enabled", "class", "spec", "visible" },
        class = "PALADIN", spec = 65, classFrame = true,
        label = "Beacon Reminder (Holy Paladin)",
        sectionHeader = "BEACON REMINDER (HOLY PALADIN)",
        enableLabel = "Enable Beacon Reminder",
        scaleLabel = "Beacon Reminder Scale",
        lockLabel = "Lock Beacon Reminder",
        tooltip = "Shows a large reminder when you are missing one of your beacons. Holy Paladins only; hidden if you are talented into Beacon of Virtue.",
        text = "REMEMBER YOUR BEACON", color = { 1, 0.82, 0 },
        size = { 280, 50 }, defaultY = 200,
        combatSafe = true,
    },
    {
        key = "earthShield", globalName = "SQUIZZUMABLESEarthShieldReminder",
        -- realGroup, not group: a delve companion or a follower dungeon's NPCs
        -- fill the party, so `group` was true while there was nobody shieldable
        -- in it. A solo shaman with Elemental Orbit got told to place a second
        -- Earth Shield on Brann.
        gates = { "enabled", "class", "knows", "buffEnabled", "visible", "realGroup" },
        class = "SHAMAN", knowsSpell = 974, buffEnabledSpell = 974, classFrame = true,
        label = "Earth Shield Reminder (Shaman)",
        sectionHeader = "EARTH SHIELD REMINDER (SHAMAN)",
        enableLabel = "Enable Earth Shield Reminder",
        scaleLabel = "Earth Shield Reminder Scale",
        lockLabel = "Lock Earth Shield Reminder",
        tooltip = "Shows a large reminder when Earth Shield is missing from its expected target. Shamans who know Earth Shield only.",
        text = "REMEMBER EARTH SHIELD", color = { 0.00, 0.44, 0.87 },
        size = { 320, 50 }, defaultY = 160,
        combatSafe = true,
    },
    {
        key = "repair", globalName = "SquizzumablesRepairReminderFrame",
        -- No "visible" gate: worn gear is worth flagging anywhere, not just
        -- in the content types the other reminders are limited to.
        gates = { "enabled", "outOfCombat" },
        label = "Repair Reminder",
        sectionHeader = "REPAIR REMINDER",
        enableLabel = "Enable Repair Reminder",
        scaleLabel = "Repair Reminder Scale",
        lockLabel = "Lock Repair Reminder",
        tooltip = "Shows a reminder when your most damaged equipped item drops below the durability threshold. Hidden during combat.",
        text = "REPAIR", color = { 0.9, 0.2, 0.2 },
        size = { 300, 40 }, defaultY = 120,
        -- The only reminder that was never given the HIGH strata. Kept as-is
        -- so its stacking order relative to other frames does not change.
        strata = false,
    },
    {
        key = "symbiotic", globalName = "SQUIZZUMABLESSymbioticReminder",
        gates = { "enabled", "class", "knows", "visible", "group" },
        class = "DRUID", knowsSpell = SYMBIOTIC_CAST_SPELL_ID, classFrame = true,
        label = "Symbiotic Relationship Reminder (Druid)",
        sectionHeader = "SYMBIOTIC RELATIONSHIP REMINDER (DRUID)",
        enableLabel = "Enable Symbiotic Relationship Reminder",
        scaleLabel = "Symbiotic Reminder Scale",
        lockLabel = "Lock Symbiotic Relationship Reminder",
        tooltip = "Shows a reminder when a party or raid member is missing Symbiotic Relationship. Druids who have the talent only.",
        text = "SYMBIOTIC RELATIONSHIP", color = { 0.2, 0.9, 0.2 },
        size = { 340, 50 }, defaultY = 80,
        combatSafe = true,
    },
    {
        key = "coachWhistle", globalName = "SQUIZZUMABLESCoachWhistleReminder",
        gates = { "enabled", "equipped", "visible", "realGroup" },
        equippedItem = COACH_WHISTLE_ITEM_ID,
        label = "Emerald Coach's Whistle Reminder",
        text = "USE COACH'S WHISTLE", color = { 0.2, 0.9, 0.6 },
        size = { 340, 50 }, defaultY = 40,
        combatSafe = true,
    },
    {
        key = "pet", globalName = "SQUIZZUMABLESPetReminder",
        -- Survival (255) has no pet.
        gates = { "enabled", "class", "notSpec", "visible" },
        class = "HUNTER", notSpec = 255, classFrame = true,
        label = "No Pet Reminder (Hunter)",
        -- Its tick moved from Class Buffs to Text Reminders > Class in 2.0.
        enableLabel = "Enable No Pet Reminder",
        tooltip = "Shows a large NO PET reminder when your pet is dismissed or dead. Hunters only; not "
               .. "Survival, which has no pet.",
        text = "NO PET", color = { 0.00, 0.78, 1.0 },
        size = { 240, 50 }, defaultY = 0,
        combatSafe = true,
    },
    {
        -- One frame for all four bag reminders. See BH:UpdateBagReminder for
        -- why they were merged; the per-category enable settings survive as
        -- watch toggles.
        key = "bags", globalName = "SQUIZZUMABLESBagsReminder",
        gates = { "enabled", "outOfCombat", "visible" },
        label = "Nothing In Bags Reminder",
        sectionHeader = "BAG REMINDERS",
        enableLabel = "Enable Bag Reminders",
        scaleLabel = "Bag Reminder Scale",
        lockLabel = "Lock Bag Reminder",
        tooltip = "One reminder naming whichever of food, flask, weapon oil or augment rune you have none of. Pick which to watch below.",
        text = "NO FOOD IN BAGS", color = { 1, 0.55, 0.0 },
        size = { 420, 50 }, defaultY = 240,
    },
    {
        key = "healthstone", globalName = "SQUIZZUMABLESHealthstoneReminder",
        gates = { "enabled", "visible" },
        label = "No Healthstone Reminder",
        sectionHeader = "HEALTHSTONE REMINDER",
        enableLabel = "Enable Healthstone Reminder",
        scaleLabel = "Healthstone Reminder Scale",
        lockLabel = "Lock Healthstone Reminder",
        tooltip = "Shows a reminder when you are not carrying a healthstone and there is a warlock in the group who could make you one. Warlocks get a Create Healthstone button instead. Stays up in combat, since that is when it matters and a Soulwell can still be used.",
        text = "NO HEALTHSTONE", color = { 1.0, 0.35, 0.35 },
        size = { 260, 50 }, defaultY = 400,
        combatSafe = true,
    },
    {
        key = "healerCC", globalName = "SQUIZZUMABLESHealerCCReminder",
        label = "Role CC Alert",
        -- Initial text only; BH:UpdateRoleCCFrame rewrites it at runtime to name
        -- whichever watched roles are actually crowd controlled.
        text = "HEALER IN CC", color = { 1.0, 0.2, 0.2 },
        size = { 280, 50 }, defaultY = 360,
        -- Visibility is driven by BH:CheckRoleCC off UNIT_AURA rather than by
        -- the shared update pass, so this one has no shouldShow predicate.
        eventDriven = true,
    },
}

-- Look up a reminder definition by key.
BH.REMINDERS_BY_KEY = {}
for _, def in ipairs(BH.REMINDERS) do
    BH.REMINDERS_BY_KEY[def.key] = def
end

-- "beacon" -> "Beacon", "healerCC" -> "HealerCC". Matches the naming that
-- POSITION_PAIRS already uses to generate Save/Load<Name>Position.
local function ReminderBaseName(key)
    return (key:gsub("^%l", string.upper))
end
BH.ReminderBaseName = ReminderBaseName

-- What a reminder frame shows: its text, in its colour, centred. Shared by
-- CreateReminderFrame and the Text Reminders page's preview
-- (UI/PreviewColumn.lua), which draws plain copies with it.
function BH.ReminderText(frame, def)
    local text = frame:CreateFontString(nil, "OVERLAY")
    text:SetFont("Fonts\\FRIZQT__.TTF", 24, "OUTLINE")
    text:SetPoint("CENTER", frame, "CENTER", 0, 0)
    text:SetText(def.text)
    text:SetTextColor(def.color[1], def.color[2], def.color[3], 1)
    return text
end

-- The one Class Reminder frame (2.0, user request 2026-10-16). Beacon, Earth
-- Shield, Symbiotic and No Pet each belong to one class, so a player only
-- ever sees one of them -- yet each was its own frame with its own position,
-- scale and lock, four boxes in Edit Mode for what is one reminder. They now
-- sit at the centre of this frame (`classFrame = true` in BH.REMINDERS): it
-- is what moves, scales (classReminderScale) and locks (classReminderLocked),
-- while each keeps its own on/off and its own show/hide logic. Shown always
-- and empty; it takes the mouse only while frames are unlocked.
local CLASS_REMINDER_KEYS = { "beacon", "earthShield", "symbiotic", "pet" }
BH.CLASS_REMINDER_KEYS = CLASS_REMINDER_KEYS

local classReminderFrame = CreateFrame("Frame", "SQUIZZUMABLESClassReminder", UIParent)
classReminderFrame:SetSize(340, 50)
classReminderFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 200)
classReminderFrame:SetFrameStrata("HIGH")
classReminderFrame:SetMovable(true)
classReminderFrame:SetClampedToScreen(true)
classReminderFrame:EnableMouse(false)
classReminderFrame:RegisterForDrag("LeftButton")
classReminderFrame:SetScript("OnDragStart", function(self)
    if not (BH.settings and BH.settings.classReminderLocked) or BH.unlockMode then
        BH:GridStartMoving(self)
        self:SetUserPlaced(false)
    end
end)
classReminderFrame:SetScript("OnDragStop", function(self)
    BH:GridStopMoving(self)
    BH:SaveClassReminderPosition()
end)
BH.classReminderFrame = classReminderFrame

--- Which class reminder this character has ("beacon" for a class with none,
--- as the sample Edit Mode and the preview show).
function BH:ClassReminderKey()
    local _, class = UnitClass("player")
    for _, key in ipairs(CLASS_REMINDER_KEYS) do
        if BH.REMINDERS_BY_KEY[key].class == class then return key end
    end
    return "beacon"
end

-- Build one reminder frame from its definition. Replaces ten copies of this.
local function CreateReminderFrame(def)
    local key       = def.key
    local lockedKey = key .. "ReminderLocked"
    local saveFn    = "Save" .. ReminderBaseName(key) .. "ReminderPosition"

    -- A class reminder lives in the Class Reminder frame, and dragging it
    -- moves that frame.
    local parent = def.classFrame and classReminderFrame or UIParent
    local mover  = def.classFrame and classReminderFrame or nil
    if def.classFrame then
        lockedKey = "classReminderLocked"
        saveFn    = "SaveClassReminderPosition"
    end

    local frame = CreateFrame("Frame", def.globalName, parent)
    frame:SetSize(def.size[1], def.size[2])
    if def.classFrame then
        frame:SetPoint("CENTER", classReminderFrame, "CENTER", 0, 0)
    else
        frame:SetPoint("CENTER", UIParent, "CENTER", 0, def.defaultY)
    end
    if def.strata ~= false then frame:SetFrameStrata("HIGH") end
    frame:SetMovable(true)
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self)
        if not (BH.settings and BH.settings[lockedKey]) or BH.unlockMode then
            local moving = mover or self
            BH:GridStartMoving(moving)
            moving:SetUserPlaced(false)
        end
    end)
    frame:SetScript("OnDragStop", function(self)
        BH:GridStopMoving(mover or self)
        if BH[saveFn] then BH[saveFn](BH) end
    end)
    frame:Hide()

    -- 2.0 motion (UI/Motion.lua): grows in from 90% over 0.15s and fades out
    -- over 0.2s; instant with Reduce motion. Plain frames, so this runs in
    -- combat too, for the reminders that stay up there.
    ns.Motion.WrapShowHide(frame, { appear = 0.15, fromScale = 0.9, fade = 0.2 })

    local text = BH.ReminderText(frame, def)

    -- Keep the historical field names: BH.beaconReminderFrame and friends are
    -- referenced throughout the addon and in POSITION_PAIRS / SCALED_FRAMES.
    BH[key .. "ReminderFrame"] = frame
    BH[key .. "ReminderText"]  = text
    return frame
end

for _, def in ipairs(BH.REMINDERS) do
    CreateReminderFrame(def)
end

-- ============================================================================
-- Movable frames and preview mode
--
-- One list of every frame the player can drag, and one routine that puts them
-- all into preview. Adding a frame here is all it takes for it to get the green
-- preview tint and become draggable.
--
-- This replaced a dozen hand-written blocks, each creating its own overlay
-- texture and each having to be remembered. Predictably the list had drifted:
-- the Coach's Whistle, pet and role-CC frames had no overlay at all, and the
-- pet frame could not be positioned from preview until someone noticed.
--
-- The important rule, and the one the old code got wrong: **preview overrides
-- the per-frame lock**. It used to do `frame:EnableMouse(not locked)` even in
-- preview, so a locked frame sat there showing its tint and refusing to move --
-- which is the exact opposite of what unlocking is for.
-- ============================================================================

-- `label` names the frame on its preview overlay, so the green boxes in unlock
-- mode can be told apart.
-- `find` is the settings row Edit Mode shows when the frame is selected (any
-- text the settings search finds it by); `posKey` is where its position is
-- saved, for the arrow-key nudge.
local MOVABLE_FRAMES = {
    -- field                enabled setting            extra gate
    { field = "frame", label = "Consumables", find = "Button Size", posKey = "framePosition" },  -- main buttons frame; always previewable
    { field = "markersFrame",        label = "Raid Markers",   enabled = "raidToolsShowMarkers",   gate = "raidToolsEnabled", muteChildren = true,
      find = "Show Markers Frame" },
    { field = "pullReadyFrame",      label = "Pull / Ready",   enabled = "raidToolsShowPullReady", gate = "raidToolsEnabled", muteChildren = true,
      find = "Show Pull/Ready Frame" },
    { field = "bresCounterFrame",    label = "Battle Res",     enabled = "bresCounterEnabled", find = "Enable Battle Res Counter" },
    { field = "deathTallyFrame",     label = "Death Tally",    enabled = "deathTallyEnabled", find = "Death Tally" },
    { field = "calloutsButtonFrame", label = "Callouts",       enabled = "dungeonCallouts", muteChildren = true,
      find = "Callouts", posKey = "calloutsFramePosition" },
    { field = "targetDistanceFrame", label = "Target Distance", enabled = "targetDistanceEnabled", find = "Show Target Distance" },
}

-- Every text reminder, from the registry rather than by hand -- except the
-- four class reminders, which move as one Class Reminder frame.
MOVABLE_FRAMES[#MOVABLE_FRAMES + 1] = {
    field = "classReminderFrame", label = "Class Reminder", find = "Class Reminder Scale",
    classReminder = true,
}
for _, def in ipairs(BH.REMINDERS) do
    if not def.classFrame then
        MOVABLE_FRAMES[#MOVABLE_FRAMES + 1] = {
            field   = def.key .. "ReminderFrame",
            enabled = def.key .. "ReminderEnabled",
            label   = def.label or def.key,
            find    = def.enableLabel,
        }
    end
end

-- The rest of the position keys, from POSITION_PAIRS.
do
    local posKeyOf = {}
    for _, pair in ipairs(POSITION_PAIRS) do posKeyOf[pair[1]] = pair[2] end
    for _, def in ipairs(MOVABLE_FRAMES) do
        def.posKey = def.posKey or posKeyOf[def.field]
    end
end
BH.MOVABLE_FRAMES = MOVABLE_FRAMES

-- The unlock overlay. Kept on the frame itself rather than in a dozen BH fields.
-- Every previewable frame gets the same box, and there are well over a
-- dozen of them once the reminders and the Cooldown Manager groups are counted.
-- Unlabelled they are indistinguishable, so a box sitting near some other
-- frame's contents reads as that frame's drag region being misaligned -- there
-- is no way to tell from looking, or from a screenshot, which frame a given
-- rectangle belongs to. So each one says what it is.
--
-- 2.0: the green box is gone; every frame gets the shared Edit Mode mover
-- (UI/EditMode.lua) -- theme accent box, its name, hover and select, the
-- arrow-key nudge, and its settings shown when selected.
local function SetPreviewOverlay(frame, on, def)
    if not frame then return end
    if on then
        local posKey, field = def and def.posKey, def and def.field
        ns.EditMode.Show(frame, def and def.label, {
            find  = def and def.find,
            nudge = posKey and function(dx, dy)
                frame:AdjustPointsOffset(dx, dy)
                BH:SaveFramePos(field, posKey)
            end,
        })
    else
        ns.EditMode.Hide(frame)
    end
end

-- Is this frame switched on at all? A frame the player has disabled stays
-- hidden in preview -- there is nothing to position.
-- Stop a frame's buttons responding while it is being positioned.
--
-- The markers and pull/ready frames are almost entirely covered by their own
-- buttons, so a click aimed at "the frame" lands on a button instead: trying to
-- drag them fired a ready check, started a pull, or set a raid marker. During
-- preview their children go click-through so the drag reaches the frame.
--
-- Restores to mouse-enabled on the way out rather than remembering per-button
-- state, because every child of these frames is a button that wants the mouse.
local function MuteFrameChildren(frame, muted)
    if not frame then return end
    -- The marker and pull/ready buttons are SecureActionButtonTemplate frames,
    -- so leave them alone under lockdown. Preview is an out-of-combat activity
    -- anyway; this is here so a stray call in combat cannot taint anything.
    if InCombatLockdown() then return end
    local ok, children = pcall(function() return { frame:GetChildren() } end)
    if not ok or not children then return end
    for _, child in ipairs(children) do
        if child and child.EnableMouse then
            child:EnableMouse(not muted)
        end
    end
end

local function FrameEnabledForPreview(def, settings)
    if not settings then return true end
    if def.enabled and settings[def.enabled] == false then return false end
    if def.gate and settings[def.gate] == false then return false end
    return true
end

--- Put every movable frame into (or out of) preview.
---
--- Mouse state is skipped entirely during combat lockdown. Several of these
--- frames parent SecureActionButtonTemplate buttons (the consumable buttons,
--- the markers and the pull/ready buttons), and EnableMouse on those is refused
--- in combat with ADDON_ACTION_BLOCKED naming this addon. That refusal is a
--- client event rather than a Lua error, so nothing aborts and the failure is
--- invisible except in BugSack -- the frames come up looking unlocked but not
--- actually draggable. Entering preview is blocked in combat by SetUnlockMode;
--- LEAVING it still has to run here (zoning into an instance force-locks, which
--- can happen mid-pull), so the guard is on the mouse calls rather than on the
--- whole function.
function BH:SetAllFramesPreview(on)
    local canTouchMouse = not InCombatLockdown()
    for _, def in ipairs(MOVABLE_FRAMES) do
        local frame = self[def.field]
        if frame then
            if on and FrameEnabledForPreview(def, self.settings) then
                -- Unconditionally movable and mouse-enabled: preview exists to
                -- override the lock, not to respect it.
                frame:SetMovable(true)
                if canTouchMouse then frame:EnableMouse(true) end
                frame:SetClampedToScreen(true)
                SetPreviewOverlay(frame, true, def)
                if def.muteChildren then MuteFrameChildren(frame, true) end
                frame:Show()
            else
                SetPreviewOverlay(frame, false)
                if def.muteChildren then MuteFrameChildren(frame, false) end
                if on then frame:Hide() end
            end
        end
    end

    -- The buttons frame only takes the mouse while being positioned. Left on,
    -- it would sit over its own secure buttons and eat their clicks.
    --
    -- This is the exact call the ADDON_ACTION_BLOCKED report named
    -- (SQUIZZUMABLESFrame:EnableMouse), since this frame parents the secure
    -- consumable buttons.
    if self.frame and canTouchMouse then
        self.frame:EnableMouse(on and true or false)
    end

    -- The Class Reminder frame is empty: in preview it shows this
    -- character's class reminder (Beacon, as a sample, for a class without
    -- one), click-through so the drag and the Edit Mode select reach the
    -- frame itself. Leaving, the frame stops taking the mouse -- it is an
    -- invisible box otherwise -- and the reminders' own updaters decide again.
    local classFrame = self.classReminderFrame
    if classFrame then
        local sampleKey = on and self:ClassReminderKey()
        for _, key in ipairs(BH.CLASS_REMINDER_KEYS) do
            local f = self[key .. "ReminderFrame"]
            if f and on then
                f:SetShown(key == sampleKey)
                if canTouchMouse then f:EnableMouse(false) end
            end
        end
        if not on and canTouchMouse then classFrame:EnableMouse(false) end
    end
end

-- === Battle Res Counter (Inspired by BigWigs BattleRes) ===
-- Difficulty IDs that have battle res charges (BigWigs approach)
local BREZ_DIFFICULTY_IDS = {
    [2] = true,  -- 5 Player (Heroic)
    [3] = true,  -- 10 Player
    [4] = true,  -- 25 Player
    [5] = true,  -- 10 Player (Heroic)
    [6] = true,  -- 25 Player (Heroic)
    [8] = true,  -- Mythic+ Keystone
    [14] = true, -- Normal Raid
    [15] = true, -- Heroic Raid
    [16] = true, -- Mythic Raid
    [17] = true, -- Looking For Raid
    [23] = true, -- Mythic Dungeon
    [33] = true, -- Timewalking (Raid)
}
local bresTrackingActive = false

-- Helper: check if current difficulty supports brez pool
local function IsInBrezContent()
    local _, _, diffID = GetInstanceInfo()
    return BREZ_DIFFICULTY_IDS[diffID] or false
end

-- Bres counter frame
BH.bresCounterFrame = CreateFrame("Frame", "SquizzumablesBresCounterFrame", UIParent)
BH.bresCounterFrame:SetSize(250, 30)
BH.bresCounterFrame:SetPoint("TOP", UIParent, "TOP", 0, -100)
BH.bresCounterFrame:SetMovable(true)
BH.bresCounterFrame:SetClampedToScreen(true)
BH.bresCounterFrame:EnableMouse(true)
BH.bresCounterFrame:SetFrameStrata("MEDIUM")
BH.bresCounterFrame:SetFixedFrameStrata(true)
BH.bresCounterFrame:RegisterForDrag("LeftButton")
BH.bresCounterFrame:SetScript("OnDragStart", function()
    if not (BH.settings and BH.settings.bresCounterLocked) or BH.unlockMode then
        BH:GridStartMoving(BH.bresCounterFrame)
        BH.bresCounterFrame:SetUserPlaced(false)
    end
end)
BH.bresCounterFrame:SetScript("OnDragStop", function()
    BH:GridStopMoving(BH.bresCounterFrame)
    BH:SaveBresCounterPosition()
end)
BH.bresCounterFrame:Hide()

BH.bresCounterText = BH.bresCounterFrame:CreateFontString(nil, "OVERLAY")
BH.bresCounterText:SetFont("Fonts\\FRIZQT__.TTF", 20, "OUTLINE")
BH.bresCounterText:SetPoint("CENTER", BH.bresCounterFrame, "CENTER", 0, 0)
BH.bresCounterText:SetText("BREZ: 0")
BH.bresCounterText:SetTextColor(ns.Theme.RGBA("highlight"))

-- AnimationGroup-based timer (BigWigs pattern: more efficient than OnUpdate)
do
    local updater = BH.bresCounterFrame:CreateAnimationGroup()
    updater:SetLooping("REPEAT")
    BH.bresUpdater = updater

    local GetSpellCharges = C_Spell.GetSpellCharges
    local floor = math.floor

    updater:SetScript("OnLoop", function()
        if BH.unlockMode then return end -- preview uses UpdateBresCounter() directly

        if not BH.settings or not BH.settings.bresCounterEnabled then
            BH.bresCounterFrame:Hide()
            return
        end

        local chargeInfo = GetSpellCharges(20484) -- Rebirth = shared brez pool
        if chargeInfo then
            local charges = chargeInfo.currentCharges
            local maxCharges = chargeInfo.maxCharges or 5
            local startTime = chargeInfo.cooldownStartTime
            local fullDuration = chargeInfo.cooldownDuration
            local timeToNext

            if charges < maxCharges and startTime and startTime > 0 and fullDuration and fullDuration > 0 then
                timeToNext = fullDuration - (GetTime() - startTime)
                if timeToNext < 0 then timeToNext = 0 end
            end

            -- Format display text
            local text
            if charges == 0 and timeToNext and timeToNext > 0 then
                local mins = floor(timeToNext / 60)
                local secs = floor(timeToNext % 60)
                text = string.format("BREZ: Not Available for %d:%02d", mins, secs)
            elseif timeToNext and timeToNext > 0 and charges < maxCharges then
                local mins = floor(timeToNext / 60)
                local secs = floor(timeToNext % 60)
                text = string.format("BREZ: %d (%d:%02d)", charges, mins, secs)
            else
                text = string.format("BREZ: %d", charges)
            end
            BH.bresCounterText:SetText(text)

            -- Color-code: red (0), orange (1), green (2+)
            if charges == 0 then
                BH.bresCounterText:SetTextColor(ns.Theme.RGBA("critical"))
            elseif charges == 1 then
                BH.bresCounterText:SetTextColor(ns.Theme.RGBA("warning"))
            else
                BH.bresCounterText:SetTextColor(ns.Theme.RGBA("good"))
            end

            BH.bresCounterFrame:Show()
            local locked = BH.settings and BH.settings.bresCounterLocked
            BH.bresCounterFrame:EnableMouse(not locked)

            -- track charges for next comparison
        else
            BH.bresCounterFrame:Hide()
        end
    end)

    local anim = updater:CreateAnimation()
    anim:SetDuration(1)
end

-- Read by Group/RaidTools.lua, which cannot see the local above (2.0 split).
function BH.BresTrackingActive() return bresTrackingActive end

function BH:StartBresTracking()
    if bresTrackingActive then return end
    bresTrackingActive = true
    self.bresUpdater:Play()
end

function BH:StopBresTracking()
    bresTrackingActive = false
    self.bresUpdater:Stop()
    if self.bresCounterFrame then
        self.bresCounterFrame:Hide()
    end
end

-- Update brez counter for preview mode
function BH:UpdateBresCounter()
    if not self.bresCounterFrame then return end
    if self.unlockMode then
        self.bresCounterText:SetText("BREZ: 3 (2:45)")
        self.bresCounterText:SetTextColor(ns.Theme.RGBA("good"))
        self.bresCounterFrame:Show()
        self.bresCounterFrame:EnableMouse(true)
        return
    end
end

-- Current party/raid unit tokens (including "player"), regardless of tracking state.
local function GetGroupUnits()
    local units = { "player" }
    if IsInGroup() then
        local isRaid = IsInRaid()
        local count = GetNumGroupMembers()
        for i = 1, count do
            table.insert(units, (isRaid and "raid" or "party") .. i)
        end
    end
    return units
end
-- Also used by Group/DeathTally.lua (2.0 split).
BH.GetGroupUnits = GetGroupUnits

-- Earth Shield aura IDs (974 = base, 383648 = Elemental Orbit variant)
local ES_AURA_IDS = { 974, 383648 }
-- Elemental Orbit talent spell ID (allows keeping ES on self + 1 other simultaneously)
local ELEMENTAL_ORBIT_SPELL_ID = 383014
-- Therazane's Resilience talent spell ID (ES loses no charges and lasts 60 min)
local THERAZANES_RESILIENCE_SPELL_ID = 1217622

-- Beacon spell IDs
local BEACON_OF_FAITH = 156910
local BEACON_OF_VIRTUE = 200025
-- All possible beacon aura IDs (the buff applied to targets)
local BEACON_AURA_IDS = { 53563, 156910, 200025 }

-- Check if player is in a valid instance type (dungeon, raid, delve, follower dungeon)

-- ----------------------------------------------------------------------------
-- Content types
--
-- Where the addon is allowed to show itself. This used to be one hardcoded rule
-- -- "party, raid or scenario" -- plus a separate hardcoded suppression during
-- Mythic+, so a player who wanted reminders in open world, or who *did* want
-- them in a key, had no way to say so.
--
-- Order here is the order shown in the settings.
-- ----------------------------------------------------------------------------

local CONTENT_TYPES = {
    { key = "world",         label = "Open World",        default = false },
    { key = "normalDungeon", label = "Dungeon (Normal)",  default = true  },
    { key = "heroicDungeon", label = "Dungeon (Heroic)",  default = true  },
    { key = "mythicDungeon", label = "Dungeon (Mythic)",  default = true  },
    -- Off by default: the addon has always hidden itself in a key, on the
    -- grounds that a timed run is not the moment for a nag.
    { key = "mythicPlus",    label = "Mythic+",           default = false },
    { key = "lfr",           label = "Raid (LFR)",        default = true  },
    { key = "normalRaid",    label = "Raid (Normal)",     default = true  },
    { key = "heroicRaid",    label = "Raid (Heroic)",     default = true  },
    { key = "mythicRaid",    label = "Raid (Mythic)",     default = true  },
    { key = "timewalking",   label = "Timewalking",       default = true  },
    { key = "delve",         label = "Delves & Scenarios",default = true  },
    { key = "pvp",           label = "Battlegrounds & Arenas", default = false },
}
BH.CONTENT_TYPES = CONTENT_TYPES

-- Publish the shipped defaults into defaultSettings, rather than writing them
-- out a second time up there. ApplyDefaults then backfills them like any
-- other nested setting, so a content type added later reaches existing
-- players without a migration.
BH.defaultSettings.contentTypes = BH.defaultSettings.contentTypes or {}
for _, ct in ipairs(CONTENT_TYPES) do
    BH.defaultSettings.contentTypes[ct.key] = ct.default
end

-- Difficulty IDs that need naming. Everything else falls through to the plain
-- normal/heroic split for its instance type.
local DIFFICULTY_TIMEWALKING = { [24] = true, [33] = true }

--- Which of the above the player is currently in.
local function CurrentContentType()
    -- Mythic+ first: a key runs inside a party instance, so the instance type
    -- alone would report it as a mythic dungeon.
    if BH.challengeModeActive
        or (C_ChallengeMode and C_ChallengeMode.IsChallengeModeActive
            and C_ChallengeMode.IsChallengeModeActive()) then
        return "mythicPlus"
    end

    local _, instanceType = IsInInstance()
    local _, _, difficultyID = GetInstanceInfo()

    if DIFFICULTY_TIMEWALKING[difficultyID or 0] then return "timewalking" end

    if instanceType == "party" then
        if difficultyID == 23 then return "mythicDungeon" end
        if difficultyID == 2  then return "heroicDungeon" end
        return "normalDungeon"
    elseif instanceType == "raid" then
        if difficultyID == 17 then return "lfr" end
        if difficultyID == 16 then return "mythicRaid" end
        if difficultyID == 15 then return "heroicRaid" end
        return "normalRaid"
    elseif instanceType == "scenario" then
        -- Delves report as scenarios, and are far and away the common case.
        return "delve"
    elseif instanceType == "pvp" or instanceType == "arena" then
        return "pvp"
    end

    return "world"
end
BH.CurrentContentType = CurrentContentType

--- Is the addon switched on for where the player is standing?
function BH:ContentTypeEnabled()
    local key = CurrentContentType()
    local setting = self.settings and self.settings.contentTypes
    if setting and setting[key] ~= nil then return setting[key] end
    -- No stored value: fall back to the shipped default for that type.
    for _, ct in ipairs(CONTENT_TYPES) do
        if ct.key == key then return ct.default end
    end
    return false
end
-- Kept under its historical name because a dozen call sites use it. It is now
-- simply "is the addon switched on for this content type" -- the old
-- party/raid/scenario test and the delve map-type fallback are both
-- expressed in CONTENT_TYPES instead.
local function IsInValidInstance()
    return BH:ContentTypeEnabled() and true or false
end

-- Check if we should show buttons (valid instance, not in combat, M+ not active)
-- ============================================================================
local function ShouldShowButtons()
    -- Unlock mode bypasses instance check
    if BH.unlockMode then
        -- Still hide in combat even in preview
        if InCombatLockdown() then
            return false
        end
        return true
    end
    
    -- Must be in valid instance
    if not IsInValidInstance() then
        return false
    end
    
    -- Whether to hide during a key is the content gate's decision now
    -- ("Mythic+" in the content types, off by default), so this no longer
    -- returns false on its own account. It still re-syncs the flag, because a
    -- reload mid-key misses CHALLENGE_MODE_START and the death tally depends
    -- on it.
    if C_ChallengeMode and C_ChallengeMode.IsChallengeModeActive
        and C_ChallengeMode.IsChallengeModeActive() then
        BH.challengeModeActive = true
        if not BH.DeathTallyActive() then
            BH:StartDeathTallyTracking()
        end
    end

    -- Hide in combat
    if InCombatLockdown() then
        return false
    end

    return true
end

-- The same visibility rules, minus the combat check.
--
-- ShouldShowButtons has to refuse in combat because the main frame parents
-- SecureActionButtonTemplate buttons, which cannot be created or changed under
-- lockdown. The plain reminder frames have no secure children and no such
-- restriction, and the two reminders that matter most -- Beacon and Earth
-- Shield -- are precisely the ones you need mid-pull. Sharing one predicate
-- meant they vanished the instant a pull started and did not come back until
-- combat ended.
--
-- Reminders flagged combatSafe in BH.REMINDERS use this instead. The rest
-- (repair, and the "no food/flask/oil in bags" trio) stay on the combat gate,
-- because none of them can be acted on mid-fight anyway.
local function ShouldShowReminders()
    if BH.unlockMode then return true end
    -- IsInValidInstance is the content-type gate, which already covers Mythic+
    -- -- so there is no separate key check here any more.
    if not IsInValidInstance() then return false end
    return true
end

-- Debounce handle for UpdateButtons -- collapses rapid-fire UNIT_AURA group events into one call
local _updateButtonsPending = false

function BH:ScheduleUpdateButtons()
    if _updateButtonsPending then return end
    _updateButtonsPending = true
    C_Timer.After(0.2, function()
        _updateButtonsPending = false
        BH:UpdateButtons()
    end)
end

-- Published for the Reminders/ files (2.0 split), which cannot see these
-- locals. Each re-declares them under the same names, so its code is
-- unchanged. None is reassigned after load (checked before each move), so a
-- copy taken when those files load stays correct. The reminder helpers
-- themselves (CreateButton, the buff checks...) are published by
-- Reminders/Helpers.lua, where they now live.
BH.BEACON_AURA_IDS                = BEACON_AURA_IDS
BH.BEACON_OF_FAITH                = BEACON_OF_FAITH
BH.BEACON_OF_VIRTUE               = BEACON_OF_VIRTUE
BH.COACH_WHISTLE_ITEM_ID          = COACH_WHISTLE_ITEM_ID
BH.COACHED_AURA_SPELL_ID          = COACHED_AURA_SPELL_ID
BH.ELEMENTAL_ORBIT_SPELL_ID       = ELEMENTAL_ORBIT_SPELL_ID
BH.ES_AURA_IDS                    = ES_AURA_IDS
BH.SYMBIOTIC_AURA_SPELL_ID        = SYMBIOTIC_AURA_SPELL_ID
BH.SYMBIOTIC_CAST_SPELL_ID        = SYMBIOTIC_CAST_SPELL_ID
BH.THERAZANES_RESILIENCE_SPELL_ID = THERAZANES_RESILIENCE_SPELL_ID
BH.ShouldShowButtons              = ShouldShowButtons
BH.ShouldShowReminders            = ShouldShowReminders





-- hook events
BH.frame:RegisterEvent("PLAYER_LOGIN")
-- Sub-zone changes too, not just new areas. Walking to the runeforge inside
-- Acherus changes only the sub-zone, and the Death Knight rune button needs
-- to swap between Death Gate and Runeforging when it does.
BH.frame:RegisterEvent("ZONE_CHANGED")
BH.frame:RegisterEvent("ZONE_CHANGED_INDOORS")
BH.frame:RegisterEvent("BAG_UPDATE_DELAYED")
BH.frame:RegisterEvent("GET_ITEM_INFO_RECEIVED")
BH.frame:RegisterEvent("UNIT_AURA")
BH.frame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
BH.frame:RegisterEvent("PLAYER_ENTERING_WORLD")
BH.frame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
BH.frame:RegisterEvent("PLAYER_REGEN_DISABLED")  -- entering combat
BH.frame:RegisterEvent("PLAYER_REGEN_ENABLED")   -- leaving combat
BH.frame:RegisterEvent("CHALLENGE_MODE_START")
BH.frame:RegisterEvent("CHALLENGE_MODE_COMPLETED")
BH.frame:RegisterEvent("CHALLENGE_MODE_RESET")
BH.frame:RegisterEvent("GROUP_ROSTER_UPDATE")
BH.frame:RegisterEvent("UNIT_PET")  -- pet summoned/dismissed (e.g. Water Elemental)
BH.frame:RegisterEvent("UPDATE_INVENTORY_DURABILITY")  -- durability changed (repair, damage)
BH.frame:RegisterEvent("PLAYER_ALIVE")     -- resurrection accepted (before or after release)
BH.frame:RegisterEvent("PLAYER_UNGHOST")   -- leaving ghost form (corpse run / spirit healer)
BH.frame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")  -- spec swap → may switch profiles
BH.frame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")  -- feast: player's own cast
-- Temporary weapon enchants (rogue poisons, weapon oils, sharpening stones).
-- Nothing else reports them: they put no aura on the player, so UNIT_AURA never
-- fires, and once applied they consume nothing, so BAG_UPDATE_DELAYED does not
-- either. Without this the reminder cleared only when some unrelated event
-- happened along.
BH.frame:RegisterUnitEvent("UNIT_INVENTORY_CHANGED", "player")
C_ChatInfo.RegisterAddonMessagePrefix("SQ_FEAST")
C_ChatInfo.RegisterAddonMessagePrefix("SQ_CALLOUT")
BH.frame:RegisterEvent("CHAT_MSG_ADDON")
-- Pull countdowns, so the encounter-timeline mirror picks up a pull started by
-- anyone in the group rather than only our own Raid Tools button.
BH.frame:RegisterEvent("START_PLAYER_COUNTDOWN")
BH.frame:RegisterEvent("CANCEL_PLAYER_COUNTDOWN")
  -- inter-addon feast alerts from other Squizzumables users
BH.frame:SetScript("OnEvent", function(self, event, arg1, ...)
    if event == "PLAYER_LOGIN" then
        BH:LoadSettings()
        -- Register user custom sounds into LSM before any UI is built
        RegisterCustomSoundsWithLSM()
        -- Must follow the LSM registration: the client-side aura sounds need a
        -- resolved file path, and LSM is what resolves a media name to one.
        if BH.RefreshAuraSoundRegistrations then BH:RefreshAuraSoundRegistrations("login") end
        BH:CreateRaidToolsFrame()
        BH:LoadAllFramePositions()
        BH:ApplyAllFrameScales()
        -- Build feast spell lookup; retry after 2s in case item cache isn't ready yet
        BH.BuildFeastSpellLookup()
        C_Timer.After(2, BH.BuildFeastSpellLookup)
        -- Build consumable buff spell ID cache (food/flask detection in HasFoodBuff/HasFlaskBuff).
        -- Retry after 2s in case item data hasn't fully loaded on the first pass.
        BH.BuildConsumableBuffCache()
        C_Timer.After(2, BH.BuildConsumableBuffCache)
        -- Build callout button frame and restore its saved position
        BH:BuildCalloutsButtonFrame()
        BH:LoadCalloutsFramePosition()
        BH:UpdateCalloutsButtonFrame()
        BH:UpdateRaidToolsVisibility()
        BH:UpdateButtons()
        -- Initialize CDM module
        if BH.cdm and BH.cdm.Initialize then
            BH.cdm:Initialize()
        end
    elseif event == "CHALLENGE_MODE_START" then
        -- M+ started - hide buttons to avoid taint
        BH.challengeModeActive = true
        BH:StartBresTracking()
        BH:StartDeathTallyTracking()
        -- Delay UpdateButtons by 1 frame: aura state (e.g. Water/Lightning Shield)
        -- may not be accurate at the exact moment CHALLENGE_MODE_START fires.
        C_Timer.After(0, function() BH:UpdateButtons() end)
    elseif event == "CHALLENGE_MODE_COMPLETED" or event == "CHALLENGE_MODE_RESET" then
        -- M+ ended or reset - can show buttons again
        BH.challengeModeActive = false
        BH:StopBresTracking()
        BH:StopDeathTallyTracking()
        -- Suppress buff sounds briefly: classBuffWasNeeded is cleared during M+
        -- (buttons never shown while key is active), so the first UpdateButtons after
        -- the key ends would fire sounds for any buffs not yet reapplied.
        BH.suppressBuffSounds = true
        C_Timer.After(3, function() BH.suppressBuffSounds = false end)
        BH:UpdateButtons()
    elseif event == "PLAYER_REGEN_DISABLED" then
        -- Suppress buff sounds briefly on entering combat. The sound block in
        -- UpdateButtons already skips itself while auras are secret, which is
        -- the real guard; this is the fallback for a client where
        -- C_Secrets.ShouldAurasBeSecret is unavailable, since there the secret
        -- check silently answers "not secret" and stops protecting anything.
        BH.suppressBuffSounds = true
        C_Timer.After(3, function() BH.suppressBuffSounds = false end)
        -- Entering combat: hide the main button frame (hides all non-pet buttons inside it).
        -- Pet buttons live on BH.petFrame (a plain non-secure Frame) so they stay visible.
        BH.frame:Hide()
        -- Reminder frames are plain Frames with no secure children, so combat
        -- does not force them down. Hide only the ones you could not act on
        -- mid-fight anyway; the combatSafe ones (Beacon, Earth Shield,
        -- Symbiotic) stay up, which is the whole point of them. Driven off the
        -- registry rather than a hand-written list, because a hand-written list
        -- of frames is exactly what drifted out of sync in bug 1.1.
        BH:HideCombatUnsafeReminders()
        if BH.bresCounterFrame then BH.bresCounterFrame:EnableMouse(false) end
        if BH.deathTallyFrame then BH.deathTallyFrame:EnableMouse(false) end
    elseif event == "PLAYER_REGEN_ENABLED" then
        -- If a spec change fired during combat, apply it now that we're out.
        if BH.pendingSpecChange then
            BH:OnSpecChanged()
        end
        -- (Buff-sound registrations postponed by combat are flushed by
        -- BH.Gate itself since 2.0.)
        -- Use the debounced scheduler (0.2s delay) rather than immediate UpdateButtons:
        -- aura data (e.g. Lightning Shield, Water Shield) may not be fully settled the
        -- moment PLAYER_REGEN_ENABLED fires, causing false "buff missing" detections.
        BH:ScheduleUpdateButtons()
        -- Re-evaluate every reminder now the combat gate has lifted: the ones
        -- hidden for the pull come back, and the ones that stayed up take the
        -- mouse again.
        BH:UpdateAllReminders()
        -- Re-enable brez counter mouse interaction out of combat
        if BH.bresCounterFrame and bresTrackingActive then
            if not (BH.settings and BH.settings.bresCounterLocked) then
                BH.bresCounterFrame:EnableMouse(true)
            end
        end
        if BH.deathTallyFrame and BH.deathTallyFrame:IsShown() then
            if not (BH.settings and BH.settings.deathTallyLocked) then
                BH.deathTallyFrame:EnableMouse(true)
            end
        end
    elseif event == "PLAYER_ALIVE" or event == "PLAYER_UNGHOST" then
        -- Suppress buff sounds briefly after resurrection: aura data may not be
        -- queryable immediately and would otherwise fire a false alert.
        BH.suppressBuffSounds = true
        C_Timer.After(3, function() BH.suppressBuffSounds = false end)
        BH.playerZoning = true
        C_Timer.After(3, function() BH.playerZoning = false end)
        BH:ScheduleUpdateButtons()
    elseif event == "ZONE_CHANGED" or event == "ZONE_CHANGED_INDOORS" then
        -- Sub-zone only. Cheap by comparison with the full zone handler below --
        -- it just rebuilds the buttons, which is what the runeforge swap needs.
        BH:UpdateButtons()
    elseif event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED_NEW_AREA" then
        -- Suppress buff sounds briefly after a loading screen: aura state is not
        -- restored immediately and would otherwise fire a false alert.
        BH.suppressBuffSounds = true
        C_Timer.After(3, function() BH.suppressBuffSounds = false end)
        -- Suppress lust alert during zone transition: UNIT_AURA fires as auras
        -- re-apply and would otherwise trigger a false lust alert.
        BH.playerZoning = true
        C_Timer.After(3, function() BH.playerZoning = false end)

        -- Remember every instance visited, for the callouts dungeon list.
        --
        -- The season's Mythic+ maps come from C_ChallengeMode, but nothing
        -- equivalent exists for raids: the Encounter Journal numbers its
        -- instances in a different space entirely (measured -- the current
        -- tier's raids report 1312/1317/1320 while GetInstanceInfo says 3004
        -- standing inside one), and no reliable bridge between them turned up.
        --
        -- Recording the pair as we see it sidesteps the whole mapping problem
        -- and covers more than raids: old dungeons, scenarios, anything. The
        -- cost is having been there once, which is not really a cost -- nobody
        -- writes callouts for a place they have never been.
        BH:RememberVisitedInstance()

        -- Zone change - check instance type and reset M+ state if not in dungeon
        local inInstance = IsInInstance()
        if not inInstance then
            BH.challengeModeActive = false
        else
            -- Entering an instance: leave unlock mode so the placeholders and
            -- forced-visible frames do not follow the player into content.
            -- Goes through SetUnlockMode so the button label, the floating
            -- control and every frame group are all brought back into line --
            -- this used to set the flag directly and left the button reading
            -- the wrong thing.
            BH:SetUnlockMode(false)
        end
        BH:CheckInstanceSound()
        -- Start/stop brez tracking based on instance type
        -- Delay by 1 frame: difficulty info isn't accurate until after PLAYER_ENTERING_WORLD (BigWigs pattern)
        C_Timer.After(0, function()
            if IsInBrezContent() and not bresTrackingActive then
                BH:StartBresTracking()
            elseif not IsInBrezContent() and bresTrackingActive then
                BH:StopBresTracking()
            end
        end)
        BH:UpdateButtons()
        BH:UpdateRaidToolsVisibility()
        BH:UpdateCalloutsButtonFrame()
        BH:RefreshRoleCCWatchList()
    elseif event == "GET_ITEM_INFO_RECEIVED" then
        -- Rebuild feast lookup if this is a feast item whose data just arrived
        for _, feastItemID in ipairs(BH.FEAST_ITEM_IDS) do
            if feastItemID == arg1 then
                BH.BuildFeastSpellLookup()
                break
            end
        end
    elseif event == "BAG_UPDATE_DELAYED" or event == "PLAYER_EQUIPMENT_CHANGED" or event == "GROUP_ROSTER_UPDATE" or event == "UNIT_PET" then
        -- Bag contents changed: drop the snapshot. Marked rather than
        -- rebuilt so several events in a row cost one scan, and the scan
        -- happens on the next read rather than on the event.
        if event == "BAG_UPDATE_DELAYED" then
            BH:MarkBagCacheStale()
            BH.BuildFeastSpellLookup()  -- pick up feast items added to bags mid-session
        end
        BH:UpdateButtons()
        if event == "GROUP_ROSTER_UPDATE" then
            BH:UpdateRaidToolsVisibility()
            BH:RefreshRoleCCWatchList()
            -- Pick up members who joined after tracking started (e.g. replaced a
            -- dropped player) so their combat-log deaths can be attributed —
            -- combat log gives destGUID only, so a never-seen GUID can't be
            -- resolved to a name without first seeing them via a unit token.
            if BH.DeathTallyActive() then
                BH:SyncDeathTallyRoster()
                BH:UpdateDeathTallyDisplay()
            end
        end
    elseif event == "UNIT_INVENTORY_CHANGED" then
        -- A temporary weapon enchant went on or fell off -- see the registration
        -- comment. Debounced rather than immediate: this arrives in bursts when
        -- gear or bag contents shift, and one rebuild covers the whole burst.
        BH:ScheduleUpdateButtons()
    elseif event == "UNIT_AURA" then
        -- Registered for EVERY unit, and that means nameplates, target, focus,
        -- boss and the rest -- in a pull the busiest event in the game. None of
        -- the three consumers below reads any of those (the reminders look at
        -- you, your pet and your group; role CC at party/raid; Kel alerts at
        -- you alone), yet each one still pushed the button bar into a full
        -- rebuild 0.2s later, so standing near a pack meant rebuilding it up
        -- to five times a second for the whole fight. One table lookup drops
        -- them. Built lazily, on BH rather than as a file local.
        local units = BH.GROUP_AURA_UNITS
        if not units then
            units = { player = true, pet = true }
            for i = 1, 4 do units["party" .. i] = true end
            for i = 1, 40 do units["raid" .. i] = true end
            BH.GROUP_AURA_UNITS = units
        end
        if not (arg1 and units[arg1]) then return end
        -- Fires for every unit in the group; debounce to avoid rebuilding buttons on every party member aura change
        BH:ScheduleUpdateButtons()
        local ccUnit = arg1
        BH:CheckRoleCC(ccUnit)
        if BH.CheckKelAlerts then BH:CheckKelAlerts(ccUnit) end
    elseif event == "START_PLAYER_COUNTDOWN" then
        -- arg1 is initiatedBy, then timeRemaining and totalTime. All three can
        -- be secret, and the two we care about get compared, so launder them
        -- through SafeNumber rather than trusting the payload.
        local timeRemaining, totalTime = ...
        local seconds = BH.Secrets.SafeNumber(totalTime, nil)
            or BH.Secrets.SafeNumber(timeRemaining, nil)
        if seconds and seconds > 0 and BH.Timeline then
            BH.Timeline.Start("pull", seconds)
        end
    elseif event == "CANCEL_PLAYER_COUNTDOWN" then
        if BH.Timeline then BH.Timeline.Stop("pull") end
    elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
        -- Your own spec only. The event also fires for group members, and a
        -- full profile reload for someone else's spec is wasted work that
        -- also tears down and rebuilds the Cooldown Manager.
        if not arg1 or arg1 == "player" then
            BH:OnSpecChanged()
        end
    elseif event == "UPDATE_INVENTORY_DURABILITY" then
        BH:UpdateRepairReminder()
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        local castGUID, spellID = ...
        if arg1 == "player" then
            BH:OnFeastSpellcast(arg1, castGUID, spellID)
            BH:OnReminderSpellcast(spellID)
            -- Rogue poisons are spells that leave no aura and consume nothing,
            -- so the cast itself is the earliest signal that a reminder may now
            -- be satisfied -- earlier than the weapon-enchant event above.
            -- Debounced, and UpdateButtons does not rebuild in combat anyway,
            -- so this costs nothing during a fight.
            BH:ScheduleUpdateButtons()
        end
    elseif event == "CHAT_MSG_ADDON" then
        local prefix, payload, _, sender = arg1, ...
        if prefix == "SQ_FEAST" then
            BH:OnFeastAddonMessage(payload)
        elseif prefix == "SQ_CALLOUT" then
            -- sender is "Name-Realm"; strip realm to match UnitName("player")
            local senderName = sender:match("^([^%-]+)")
            if senderName ~= UnitName("player") then
                if payload and payload ~= "None" then
                    PlaySQSound(payload)
                end
            end
        end
    end
end)

-- No OnUpdate on BH.frame: button countdowns are driven by each button's own
-- throttled OnUpdate in CreateButton. An empty handler here still costs a Lua
-- call every rendered frame for the whole session.

-- slash command to move/reset
-- /rl -> ReloadUI, claimed only if nothing else answers it.
--
-- Blizzard ships /reload, never /rl; the short form is an addon convention.
-- Taking it from an addon that already provides it would be rude and might
-- replace a richer version, so this checks first and skips quietly. Deferred
-- to PLAYER_LOGIN so addons loading after this file are visible to the check.
--
-- Both registries are consulted: hash_SlashCmdList (uppercased, slash
-- included) holds what has been imported, SlashCmdList holds what has been
-- registered since -- the import wipes the latter as it moves entries over.
do
    local function TakenAlready()
        local hash = _G.hash_SlashCmdList
        if hash and hash['/RL'] then return true end
        for name in pairs(SlashCmdList) do
            local i = 1
            local cmd = _G['SLASH_' .. name .. i]
            while cmd do
                if strupper(cmd) == '/RL' then return true end
                i = i + 1
                cmd = _G['SLASH_' .. name .. i]
            end
        end
        return false
    end

    local f = CreateFrame('Frame')
    f:RegisterEvent('PLAYER_LOGIN')
    f:SetScript('OnEvent', function(self)
        self:UnregisterEvent('PLAYER_LOGIN')
        if TakenAlready() then return end
        SLASH_SQUIZZUMABLESRELOAD1 = '/rl'
        SlashCmdList['SQUIZZUMABLESRELOAD'] = function() ReloadUI() end
    end)
end

SLASH_SQUIZZUMABLES1 = '/sq'
SlashCmdList['SQUIZZUMABLES'] = function(msg)
    if msg == 'reset' then
        BH.frame:ClearAllPoints()
        BH.frame:SetPoint('CENTER')
        print(addonName.." frame reset to center")
    elseif msg == 'config' then
        BH:CreateOptionsPanel()
    elseif msg and msg:lower() == 'cdms' then
        -- Kelerts > CDM Alerts (2.0). Was /squizz cdms; /squizz is now the
        -- combined window's (LibSquizzShell), where it still works too.
        BH:CreateOptionsPanel()
        if BH.switchTab then BH.switchTab("kel") end
        if BH.kelPages and BH.kelPages.Select then BH.kelPages.Select("buffsounds") end
    elseif msg == 'raidtools' then
        if InCombatLockdown() then
            print(addonName..": Cannot toggle raid tools in combat")
            return
        end
        if BH.markersFrame then
            if BH.markersFrame:IsShown() then
                BH.markersFrame:Hide()
            else
                BH.markersFrame:Show()
            end
        end
        if BH.pullReadyFrame then
            if BH.pullReadyFrame:IsShown() then
                BH.pullReadyFrame:Hide()
            else
                BH.pullReadyFrame:Show()
            end
        end
    elseif msg == "unlock" then
        -- Reachable without opening the panel, which matters because the panel
        -- can cover the frames being positioned.
        BH:SetUnlockMode(not BH.unlockMode)
    elseif msg == 'reload' then
        BH:UpdateButtons()
        print(addonName.." buttons updated")
    elseif msg == 'feast' then
        print(addonName.." Feast Debug:")
        local enabled = BH.settings and BH.settings.feastAnnounceEnabled
        local chanDB = type(BH.settings.feastAnnounceChannel) == "table"
            and BH.settings.feastAnnounceChannel
            or BH.defaultSettings.feastAnnounceChannel
        local effectiveChannel = BH:GetAnnounceChannel(chanDB)
        print("  enabled:", tostring(enabled))
        print("  channels: solo=", chanDB.solo, " party=", chanDB.party, " instance=", chanDB.instance, " raid=", chanDB.raid)
        print("  effective channel:", effectiveChannel)
        print("  IsInGroup:", tostring(IsInGroup()), " IsInInstance:", tostring(IsInInstance()), " IsInRaid:", tostring(IsInRaid()))
        print("  challengeModeActive:", tostring(BH.challengeModeActive))
        local count = 0
        for _ in pairs(BH.feastSpellLookup) do count = count + 1 end
        print("  feastSpellLookup entries:", count)
        for _, name in pairs(BH.feastSpellLookup) do
            print("    feast:", name)
        end
        print("  Item lookup test:")
        for _, itemID in ipairs(BH.FEAST_ITEM_IDS) do
            local itemName = C_Item.GetItemNameByID(itemID)
            local spellName, spellID = C_Item.GetItemSpell(itemID)
            local hasSpell = (spellID ~= nil)
            local safeName = spellName and (type(spellName) == "string" and spellName or "[secret]") or "nil"
            print(string.format("    itemID %d: name=%s, spellName=%s, hasSpellID=%s",
                itemID, tostring(itemName), safeName, tostring(hasSpell)))
        end
    elseif msg == "cdm" then
        if BH.cdm and BH.cdm.PrintSoundDiagnostics then
            BH.cdm:PrintSoundDiagnostics()
        else
            print(addonName .. ": Cooldown Manager module not loaded.")
        end
    elseif msg == "range" then
        if BH.PrintRangeDiagnostics then
            BH:PrintRangeDiagnostics()
        else
            print(addonName .. ": Target distance module not loaded.")
        end
    elseif msg == "cdmtaint" then
        if BH.cdm and BH.cdm.PrintTaintDiagnostics then
            BH.cdm:PrintTaintDiagnostics()
        else
            print(addonName .. ": Cooldown Manager module not loaded.")
        end
    elseif msg == "cdmbuff" then
        if BH.cdm and BH.cdm.PrintBuffDiagnostics then
            BH.cdm:PrintBuffDiagnostics()
        else
            print(addonName .. ": Cooldown Manager module not loaded.")
        end
    elseif msg == "cdmnative" then
        if BH.cdm and BH.cdm.native then
            BH.cdm.native:PrintDiagnostics()
        else
            print(addonName .. ": native buff module not loaded.")
        end
    elseif msg == "nameplates" then
        if BH.Nameplates then
            BH.Nameplates:PrintDiagnostics()
        else
            print(addonName .. ": nameplate module not loaded.")
        end
    elseif msg == "nameplates test" then
        if BH.Nameplates then BH.Nameplates:TestRow() end
    elseif msg == "nameplates testoff" then
        if BH.Nameplates then BH.Nameplates:TestRowOff() end
    elseif msg:match("^nameplates test %S+$") then
        if BH.Nameplates then BH.Nameplates:TestRow(msg:match("^nameplates test (%S+)$")) end
    elseif msg == "buffsounds try" then
        if BH.TryAuraSoundRegistrationNow then BH:TryAuraSoundRegistrationNow() end
    elseif msg == "buffsounds" then
        if BH.PrintBuffSoundDiagnostics then
            BH:PrintBuffSoundDiagnostics()
        else
            print(addonName .. ": Spell alerts module not loaded.")
        end
    elseif msg == "buffimages" then
        if BH.PrintBuffImageDiagnostics then
            BH:PrintBuffImageDiagnostics()
        else
            print(addonName .. ": Spell alerts module not loaded.")
        end
    elseif msg and (msg == "cdmbuffs" or msg:match("^cdmbuffs ")) then
        if BH.PrintCDMBuffEntries then
            BH:PrintCDMBuffEntries(msg:match("^cdmbuffs%s+(.+)$"))
        else
            print(addonName .. ": Spell alerts module not loaded.")
        end
    elseif msg == "notes" then
        if BH.ShowReleaseNotes then BH.ShowReleaseNotes() end
    elseif msg == "setup" then
        -- First-run setup (UI/Setup.lua), any time.
        if BH.ShowSetup then BH.ShowSetup() end
    elseif msg == "welcome" then
        if BH.ShowFirstRun then BH.ShowFirstRun() end
    elseif msg == "dk" then
        -- Death Knight runeforge diagnostics.
        --
        -- IsSpellUsable turned out not to track the runeforge requirement -- it
        -- reports usable as soon as the spell is known -- so the zone is what
        -- decides. This prints both, plus the zone strings being matched, so a
        -- mismatch can be spotted rather than inferred.
        local function say(fmt, ...) print("|cff33ff99Squizzumables|r: " .. string.format(fmt, ...)) end
        local _, class = UnitClass("player")
        say("class: %s", tostring(class))

        local RUNEFORGING, DEATH_GATE = 53428, 50977
        local rfKnown = BH.PlayerKnowsSpell(RUNEFORGING)
        local dgKnown = BH.PlayerKnowsSpell(DEATH_GATE)
        local rfUsable, rfNoPower
        if C_Spell.IsSpellUsable then rfUsable, rfNoPower = C_Spell.IsSpellUsable(RUNEFORGING) end
        say("Runeforging (%d): known=%s usable=%s (usable is NOT proximity-aware)",
            RUNEFORGING, tostring(rfKnown), tostring(rfUsable))
        say("at a runeforge (by zone): %s", tostring(BH.AtRuneforge and BH.AtRuneforge()))
        say("Death Gate  (%d): known=%s", DEATH_GATE, tostring(dgKnown))

        -- Called plainly, not as `BH.x and BH.x()`: an and/or expression is
        -- adjusted to a single value, so the second return would always be nil.
        local actionID, actionLabel
        if BH.RuneforgeAction then actionID, actionLabel = BH.RuneforgeAction() end
        say("button would offer: %s (%s)", tostring(actionID), tostring(actionLabel))

        local needs, slot
        if BH.WeaponNeedsRune then needs, slot = BH.WeaponNeedsRune() end
        say("weapon needs a rune: %s%s", tostring(needs), slot and (" (" .. slot .. ")") or "")
        for _, slotID in ipairs({ 16, 17 }) do
            local link = GetInventoryItemLink("player", slotID)
            if link then
                local ench = link:match("item:%d+:(%-?%d+):")
                say("  slot %d enchantID: %s", slotID, tostring(ench))
            else
                say("  slot %d: empty", slotID)
            end
        end

        -- Where we are, so a zone check can be added precisely if IsSpellUsable
        -- turns out not to track proximity.
        local mapID = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
        say("map: %s (%s)", tostring(mapID), tostring(GetRealZoneText()))
        say("sub-zone: %s", tostring(GetSubZoneText()))
    elseif msg == "timeline" then
        if BH.Timeline and BH.Timeline.PrintDiagnostics then
            BH.Timeline.PrintDiagnostics()
        else
            print(addonName .. ": Encounter timeline module not loaded.")
        end
    elseif msg:match("^auras%s+%d+$") then
        -- Per-spell aura secrecy report: /sq auras <spellID>
        --
        -- Exists to answer one question that cannot be answered by reading the
        -- code: when a Kelert fires out of combat but not in combat, is the
        -- aura genuinely unreadable, or is the addon failing to look?
        --
        -- Blizzard's secrecy is per-spell (C_Secrets.ShouldSpellAuraBeSecret),
        -- not a single global switch, so "auras are secret" being false does not
        -- mean this particular aura is readable. Run it twice with the buff
        -- actually up -- once out of combat, once in -- and compare.
        local spellID = tonumber(msg:match("(%d+)"))
        local name = C_Spell.GetSpellName(spellID)
        local _, instanceType = IsInInstance()
        -- `cond and predicate() or "unavailable"` cannot report these, because a
        -- predicate that correctly answers false collapses through the `or` and
        -- comes out as "unavailable" -- which is exactly what the first run of
        -- this command printed out of combat for a spell that simply was not
        -- secret. Distinguish "the predicate does not exist" from "it said no".
        local function Describe(value)
            if value == nil then return "predicate unavailable" end
            return tostring(value)
        end
        print(addonName .. string.format(" aura secrecy for %s (%d):",
            tostring(BH.Secrets.SafeString(name, "unknown spell")), spellID))
        print(string.format("  in combat: %s, instance: %s",
            tostring(InCombatLockdown()), tostring(instanceType)))
        print(string.format("  client has secret restrictions: %s",
            tostring(C_Secrets and C_Secrets.HasSecretRestrictions
                and C_Secrets.HasSecretRestrictions())))
        print(string.format("  auras secret generally: %s",
            tostring(BH.Secrets.AurasAreSecret())))
        print(string.format("  THIS spell's aura secret: %s",
            Describe(C_Secrets and C_Secrets.ShouldSpellAuraBeSecret
                and C_Secrets.ShouldSpellAuraBeSecret(spellID))))
        -- Whether the *cast* is readable, which is a separate permission from
        -- the aura and the basis of the only workaround for a secret buff:
        -- trigger on "I cast this" rather than on "I have this".
        print(string.format("  THIS spell's cast secret: %s",
            Describe(C_Secrets and C_Secrets.ShouldUnitSpellCastBeSecret
                and C_Secrets.ShouldUnitSpellCastBeSecret("player", spellID))))
        -- The presence check a Kelert trigger actually performs. If this says
        -- NO while the buff is visibly on you, that is the whole bug.
        local aura = BH.Secrets.GetAuraBySpellID("player", spellID)
        print(string.format("  GetUnitAuraBySpellID found it: %s", aura and "YES" or "NO"))
        if aura then
            print(string.format("    table has secret fields: %s",
                tostring(BH.Secrets.HasAnySecret(aura))))
            print(string.format("    spellID readable: %s, expiration readable: %s",
                tostring(BH.Secrets.SafeAuraSpellID(aura) ~= nil),
                tostring(BH.Secrets.SafeAuraExpiration(aura) ~= nil)))
        end
        -- Whether Blizzard's own cooldown data knows this spell, and under
        -- which category.
        --
        -- Categories 2 and 3 are the tracked-*buff* viewers, and the addon has
        -- never enumerated them -- CDM_VIEWERS in Squizzumables_CDM.lua is
        -- Essential and Utility only. So "it is not in the CDM" can mean either
        -- "Blizzard does not track it" or "we only ever looked at the cooldown
        -- half", and those lead to different conclusions about whether the
        -- tracked-buff set is worth reading as a source of aura IDs.
        --
        -- allowUnlearned so the whole spec set is searched, not just what is
        -- currently talented. linkedSpellIDs is reported because that is where
        -- a cast/aura pair lives when the two IDs differ.
        if C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCategorySet then
            local found = false
            for category = 0, 3 do
                local ok, ids = pcall(C_CooldownViewer.GetCooldownViewerCategorySet, category, true)
                for _, cdID in ipairs((ok and ids) or {}) do
                    local info = C_CooldownViewer.GetCooldownViewerCooldownInfo(cdID)
                    if info and info.spellID == spellID then
                        found = true
                        print(string.format(
                            "  in CDM category %d: isKnown %s, hasAura %s, selfAura %s, linked %d",
                            category, tostring(info.isKnown), tostring(info.hasAura),
                            tostring(info.selfAura), #(info.linkedSpellIDs or {})))
                    end
                end
            end
            if not found then
                print("  not in any CDM category (0-3), even allowing unlearned")
            end
        end
        print("  Run this again with the buff up in combat and compare the two.")
    elseif msg == 'auras' then
        -- Paladin aura diagnostics: which auras the addon can actually see on you.
        -- If an aura you have active reads "detected: NO" here, the problem is the
        -- spell ID in Squizzumables_Config.lua, not the show/hide logic.
        local _, class = UnitClass("player")
        print(addonName .. " Paladin Aura Debug:")
        print("  class:", class, " specID:",
            tostring(PlayerUtil and PlayerUtil.GetCurrentSpecID and PlayerUtil.GetCurrentSpecID()))
        -- Report the context too. "Auras are secret" means something very
        -- different in combat (expected, nothing is wrong) than standing in a
        -- city (something is badly wrong), and the previous output could not
        -- tell the two apart.
        local _, instanceType = IsInInstance()
        print(string.format("  in combat: %s, instance: %s",
            tostring(InCombatLockdown()), tostring(instanceType)))
        print("  auras are secret right now:", tostring(BH.Secrets.AurasAreSecret()),
            InCombatLockdown() and "(expected in combat)" or "(UNEXPECTED out of combat)")
        local info = BH.classBuffs and BH.classBuffs[class]
        if not (info and info.auras) then
            print("  no aura list configured for this class")
        else
            for _, auraInfo in ipairs(info.auras) do
                local aura = BH.Secrets.GetAuraBySpellID("player", auraInfo.spellID)
                local name = C_Spell.GetSpellName(auraInfo.spellID)
                print(string.format("    %s (%d): detected: %s, source: %s, enabled: %s",
                    tostring(name), auraInfo.spellID,
                    aura and "YES" or "NO",
                    tostring(BH.Secrets.SafeAuraSourceUnit(aura)),
                    tostring(BH:IsEnabled(auraInfo.spellID))))
            end
        end
    elseif msg == 'debug' then
        -- Debug: show quality info for all consumable items in bags
        print(addonName.." Quality Debug:")
        for bag = FIRST_BAG, LAST_BAG do
            for slot = 1, C_Container.GetContainerNumSlots(bag) do
                local itemID = C_Container.GetContainerItemID(bag, slot)
                if itemID then
                    local itemLink = C_Container.GetContainerItemLink(bag, slot)
                    local containerInfo = C_Container.GetContainerItemInfo(bag, slot)
                    -- See the note at the other craftingQuality read: the field exists,
                    -- the annotation does not.
                    ---@diagnostic disable-next-line: undefined-field
                    local craftingQuality = containerInfo and containerInfo.craftingQuality
                    local apiQuality = nil
                    if itemLink and C_TradeSkillUI and C_TradeSkillUI.GetItemCraftedQualityByItemInfo then
                        apiQuality = C_TradeSkillUI.GetItemCraftedQualityByItemInfo(itemLink)
                    end
                    local itemName = C_Item.GetItemNameByID(itemID)
                    -- Only show items that might be consumables (check if in our lists)
                    local isTracked = false
                    if BH.consumables then
                        for _, list in pairs(BH.consumables) do
                            for _, id in ipairs(list) do
                                if id == itemID then isTracked = true break end
                            end
                            if isTracked then break end
                        end
                    end
                    if isTracked then
                        -- Extract just the item string portion for bonus ID analysis
                        local itemString = itemLink and itemLink:match("item[%-?%d:]+") or "none"
                        print(string.format("  %s (ID:%d): containerQ=%s, apiQ=%s",
                            itemName or "Unknown", itemID,
                            tostring(craftingQuality), tostring(apiQuality)))
                        print(string.format("    itemString: %s", itemString))
                    end
                end
            end
        end
    else
        -- Only the commands a player has a reason to run.
        --
        -- The diagnostics -- feast, auras, cdm, timeline, dk, debug, buffsounds
        -- -- are deliberately absent. They all still work; they are support
        -- tools, and printing them here only invites people to run dumps they
        -- have no way to read. Ask for one by name when a bug report needs it.
        -- Keep this list in step when a *player-facing* command is added, and
        -- see CLAUDE.md for the full set including the hidden ones.
        print(addonName.." commands:")
        print("  /sq config - open options")
        print("  /sq reset - reset frame position")
        print("  /sq raidtools - toggle raid tools frame")
        print("  /sq unlock - toggle Unlock Frames (drag everything into place)")
        print("  /sq reload - update buttons")
        print("  /sq notes - reopen the release notes for this version")
        print("  /sq setup - run setup again (role, suggested extras, placing frames, theme)")
        print("  /ginvite <name> - guild invite a player")
    end
end

-- /squizz shortcut to open config directly; /squizz CDMS opens CDM Alerts
-- (Kelerts > CDM Alerts since 2.0, which replaced the CDM Sounds tab)
-- /squizz belongs to the shared window library now (LibSquizzShell): with
-- SquizzFrames installed too it opens the combined window, and on its own it
-- opens ours. This tells it how to build and open our window, and claims
-- /squizz cdms (Kelerts > CDM Alerts).
do
    local Shell = LibStub("LibSquizzShell-1.0", true)
    if Shell and Shell.RegisterOpener then
        Shell:RegisterOpener("Squizzumables", {
            open = function(pageId, show)
                -- Asked for the window only: build it once, nothing more.
                if not show and BH.optionsWindow then return BH.optionsWindow end
                BH:CreateOptionsPanel(not show)
                if show and pageId and BH.optionsWindow then BH.optionsWindow:Open(pageId) end
                return BH.optionsWindow
            end,
            slash = function(msg)
                if not (msg and msg:upper() == "CDMS") then return false end
                BH:CreateOptionsPanel()
                if BH.switchTab then BH.switchTab("kel") end
                if BH.kelPages and BH.kelPages.Select then BH.kelPages.Select("buffsounds") end
                return true
            end,
        })
    end
end

------------------------------------------------------------
-- Guild Invite on right-click context menu
------------------------------------------------------------
do
    -- Slash command: /ginvite <name>
    SLASH_SQGINVITE1 = "/ginvite"
    SlashCmdList["SQGINVITE"] = function(msg)
        msg = msg and msg:match("^%s*(.-)%s*$") or ""
        if msg == "" then
            print("|cFFFFD100Squizzumables:|r Usage: /ginvite <player name>")
            return
        end
        if IsInGuild() then
            C_GuildInfo.Invite(msg)
        else
            print("|cFFFFD100Squizzumables:|r You are not in a guild.")
        end
    end

    -- CanGuildInvite is a global Blizzard API function (not on C_GuildInfo)
    local function CanGuildInvite()
        return _G.CanGuildInvite and _G.CanGuildInvite()
    end

    -- Check if a player (by name) is already in our guild
    ---@param playerName string
    local function IsPlayerInOurGuild(playerName)
        if not IsInGuild() or not playerName then return false end
        local numMembers = GetNumGuildMembers and GetNumGuildMembers() or 0
        for i = 1, numMembers do
            local rosterName = GetGuildRosterInfo(i)
            if rosterName then
                local nameOnly = rosterName:match("^([^-]+)") or rosterName
                local checkName = playerName:match("^([^-]+)") or playerName
                if nameOnly == checkName then
                    return true
                end
            end
        end
        return false
    end

    -- Hook player context menus using the modern Menu API (same pattern as WindTools)
    -- Menu_ModifyMenu receives: (owner, rootDescription, contextData)
    local function SQ_ModifyMenu(_, rootDescription, contextData)
        if not BH.settings or BH.settings.guildInviteContextEnabled == false then return end
        if not CanGuildInvite() then return end
        if not contextData then return end

        local which = contextData.which
        if not which then return end

        -- Only show on player-related menus (mirrors WindTools supportTypes)
        local validTypes = {
            PARTY = true, RAID = true, RAID_PLAYER = true, PLAYER = true,
            FRIEND = true, FRIEND_OFFLINE = true,
            GUILD = true, GUILD_OFFLINE = true,
            CHAT_ROSTER = true, COMMUNITIES_WOW_MEMBER = true,
            TARGET = true, FOCUS = true, ARENAENEMY = true,
            BN_FRIEND = true, WORLD_STATE_SCORE = true,
            RAF_RECRUIT = true,
        }
        if not validTypes[which] then return end

        -- For unit-based menus, validate it's a player unit (not pet/npc)
        if contextData.unit then
            local unit = contextData.unit
            if UnitIsUnit(unit, "player") then return end
            if UnitPlayerControlled and not UnitPlayerControlled(unit) then return end
            -- Skip if they're already in any guild (invite would just fail)
            -- GetGuildInfo returns nil when out of range; in that case we can't
            -- determine guild status so we still show the button
            local guildName = GetGuildInfo(unit)
            if guildName and guildName ~= "" then return end
        end

        -- Resolve the player name and server from contextData
        local name = contextData.name
        local server = contextData.server

        -- Unit-based menus (party/raid/target/focus frames) don't populate
        -- contextData.name/.server -- only a unit token -- so derive them
        if (not name or name == "") and contextData.unit then
            local unitName, unitServer
            if UnitNameUnmodified then
                unitName, unitServer = UnitNameUnmodified(contextData.unit)
            else
                unitName, unitServer = UnitName(contextData.unit)
            end
            if unitName and unitName ~= "" and unitName ~= UNKNOWNOBJECT then
                name = unitName
                if unitServer and unitServer ~= "" then
                    server = unitServer
                end
            end
        end

        -- BN friends: resolve WoW character name from BattleNet API
        if which == "BN_FRIEND" and contextData.bnetIDAccount then
            local bnetID = contextData.bnetIDAccount
            local numBNOnlineFriend = select(2, BNGetNumFriends())
            for i = 1, numBNOnlineFriend do
                local accountInfo = C_BattleNet.GetFriendAccountInfo(i)
                if accountInfo
                    and accountInfo.bnetAccountID == bnetID
                    and accountInfo.gameAccountInfo
                    and accountInfo.gameAccountInfo.isOnline
                then
                    local numGameAccounts = C_BattleNet.GetFriendNumGameAccounts(i)
                    if numGameAccounts and numGameAccounts > 0 then
                        for j = 1, numGameAccounts do
                            local gameAccountInfo = C_BattleNet.GetFriendGameAccountInfo(i, j)
                            if gameAccountInfo
                                and gameAccountInfo.clientProgram == "WoW"
                                and gameAccountInfo.wowProjectID == 1
                            then
                                name = gameAccountInfo.characterName
                                server = gameAccountInfo.realmName
                                break
                            end
                        end
                    elseif accountInfo.gameAccountInfo.clientProgram == "WoW"
                        and accountInfo.gameAccountInfo.wowProjectID == 1
                    then
                        name = accountInfo.gameAccountInfo.characterName
                        server = accountInfo.gameAccountInfo.realmName
                    end
                    break
                end
            end
            -- If we couldn't resolve a WoW character, skip (not playing WoW)
            if not name or name == "" then return end
        end

        -- Skip self
        if name == UnitName("player") and (not server or server == GetRealmName()) then return end
        if not name or name == "" then return end

        -- Build full name with server if cross-realm
        local fullName = name
        if server and server ~= "" and server ~= GetRealmName() then
            fullName = name .. "-" .. server
        end

        -- Skip if already in our guild
        if IsPlayerInOurGuild(fullName) then return end

        rootDescription:CreateDivider()
        rootDescription:CreateButton(
            "|cFFFFD100Guild Invite: " .. name .. "|r",
            function()
                C_GuildInfo.Invite(fullName)
            end
        )
    end

    -- Register after all default menus are built (PLAYER_LOGIN ensures
    -- the Menu API and unit popup types are fully initialized)
    local regFrame = CreateFrame("Frame")
    regFrame:RegisterEvent("PLAYER_LOGIN")
    regFrame:SetScript("OnEvent", function()
        if Menu and Menu.ModifyMenu then
            for _, popupType in ipairs({
                "PARTY", "RAID", "RAID_PLAYER", "PLAYER",
                "FRIEND", "FRIEND_OFFLINE",
                "GUILD", "GUILD_OFFLINE",
                "CHAT_ROSTER", "COMMUNITIES_WOW_MEMBER",
                "TARGET", "FOCUS", "ARENAENEMY",
                "BN_FRIEND", "WORLD_STATE_SCORE",
                "RAF_RECRUIT",
            }) do
                pcall(function()
                    Menu.ModifyMenu("MENU_UNIT_" .. popupType, SQ_ModifyMenu)
                end)
            end
        end
    end)
end

-- end of addon
