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
    buttonSize = 36,
    buttonSpacing = 5,
    frameLocked = false,
    anchorPoint = "LEFT",
    growDirection = "RIGHT",
    layoutDirection = "HORIZONTAL", -- HORIZONTAL or VERTICAL
    showLabelText = true,

    -- Draw headings, tab highlights, checkboxes, slider fills and button
    -- accents in the player's class colour instead of the default warm gold.
    useClassColorAccent = true,
    -- Mirror our own timers onto Blizzard's encounter timeline. See
    -- Core/EncounterTimeline.lua for why only the write side of the API is used.
    timelineTimers = true,
    timelinePullTimer = true,
    raidToolsEnabled = true,
    raidToolsPullTimer = 10,
    raidToolsShowMarkers = true,
    raidToolsShowPullReady = true,
    raidToolsMarkersLocked = false,
    raidToolsPullReadyLocked = false,
    raidToolsMarkersScale = 1.0,
    raidToolsPullReadyScale = 1.0,
    raidToolsMarkersLayout = "HORIZONTAL",
    raidToolsMarkersGrow = "LEFT",
    beaconReminderLocked = false,
    beaconReminderScale = 1.0,
    beaconReminderEnabled = true,
    earthShieldReminderLocked = false,
    earthShieldReminderScale = 1.0,
    earthShieldReminderEnabled = true,
    guildInviteContextEnabled = true,
    skyreachSoundEnabled = true,
    repairReminderEnabled = true,
    repairReminderThreshold = 50,
    repairReminderLocked = false,

    repairReminderScale = 1.0,

    symbioticReminderLocked = false,
    symbioticReminderScale = 1.0,
    symbioticReminderEnabled = true,

    coachWhistleReminderLocked = false,
    coachWhistleReminderScale = 1.0,
    coachWhistleReminderEnabled = true,

    -- Hunter: No Pet reminder
    petReminderEnabled = true,
    petReminderLocked = false,
    petReminderScale = 1.0,
    bresCounterEnabled = true,
    bresCounterLocked = false,
    bresCounterScale = 1.0,
    cdmEnabled = false,
    cdmHideBlizzard = false,
    cdmViewersFollowGroups = true,
    -- Off: tracked buffs use Blizzard's own icons, which is what makes their
    -- swipes work in combat. Ticking it goes back to proxy icons, which cannot.
    cdmProxyBuffIcons = false,

    -- M+ Death Tally (per-player death counter, resets each key)
    -- Target distance readout (Core/TargetDistance.lua). Off by default: it is
    -- a persistent on-screen number rather than a reminder, so it should be
    -- asked for rather than appear unbidden.
    targetDistanceEnabled = false,
    targetDistanceFormat = "band",      -- "band" | "max" | "min"
    targetDistanceAlign = "CENTER",
    targetDistanceTextSize = 18,
    targetDistanceStrata = "HIGH",
    targetDistanceFriendly = false,     -- probes are harmful, so hostile only
    targetDistanceColor = { r = 1, g = 1, b = 1 },

    -- Co-tank tracker (Core/CoTank.lua). Off by default, like the other
    -- persistent readouts.
    coTankEnabled = false,
    coTankPreview = false,

    -- Frame
    coTankGrowth = "down",
    coTankRowSpacing = 6,
    coTankShowName = true,
    coTankNameSize = 12,
    coTankFont = nil,               -- LibSharedMedia name; nil = default font
    coTankShowInParty = true,
    coTankOnlyIfTank = false,
    coTankNotify = false,

    -- Shared icon look
    coTankIconZoom = 7,             -- percent cropped from each edge
    coTankBorderStyle = "border",   -- off | border | bordericon | icon
    coTankShowSwipe = true,
    coTankShowCountdown = true,
    coTankShowStacks = true,
    coTankStackColor = { r = 1, g = 1, b = 1 },
    coTankCountdownColor = { r = 1, g = 0.82, b = 0 },

    -- Debuffs group
    coTankDebuffFilter = "boss",    -- boss | bossrole | important | dispel | all
    coTankDebuffHidePermanent = true,
    coTankDebuffSize = 32,
    coTankDebuffSpacing = 2,
    coTankDebuffPerRow = 8,
    coTankDebuffMaxRows = 1,
    coTankDebuffOffsetX = 0,
    coTankDebuffOffsetY = 0,
    coTankDebuffStackSize = 13,
    coTankDebuffStackX = -1,
    coTankDebuffStackY = 1,
    coTankDebuffCountdownSize = 12,
    coTankDebuffCountdownX = 0,
    coTankDebuffCountdownY = 0,

    -- Defensives group. Spell IDs ARE permitted for helpful auras on a friendly
    -- unit, which is why this one is a list the player writes.
    coTankDefEnabled = false,
    coTankDefSpellIDs = "",
    coTankDefSize = 24,
    coTankDefSpacing = 2,
    coTankDefPerRow = 6,
    coTankDefMaxRows = 1,
    coTankDefOffsetX = 0,
    coTankDefOffsetY = 0,
    coTankDefStackSize = 11,
    coTankDefStackX = -1,
    coTankDefStackY = 1,
    coTankDefCountdownSize = 10,
    coTankDefCountdownX = 0,
    coTankDefCountdownY = 0,

    deathTallyEnabled = true,
    deathTallyLocked = false,
    deathTallyScale = 1.0,
    deathTallyClassColorNames = true,
    deathTallyHideRealm = true,
    deathTallyTitleFontSize = 13,
    deathTallyRowFontSize = 12,

    -- Food/Flask/Oil "no items in bag" reminders
    foodReminderEnabled = true,
    flaskReminderEnabled = true,
    oilReminderEnabled = true,
    -- The four bag categories share one frame now, so scale/lock/position are
    -- shared too. The per-category *Enabled keys survive as watch toggles.
    augmentRuneReminderEnabled = true,
    bagsReminderLocked = false,
    bagsReminderScale = 1.0,
    bagsReminderEnabled = true,
    healthstoneReminderLocked = false,
    healthstoneReminderScale = 1.0,
    healthstoneReminderEnabled = true,
    -- Where the addon shows itself. Filled from CONTENT_TYPES on load, so a
    -- content type added later reaches existing players through ApplyDefaults
    -- rather than needing a migration.
    contentTypes = {},
    -- Minimap button. The angle is where round the minimap it was dragged to;
    -- 200 degrees puts it bottom-left, clear of the default clock and tracking
    -- icons.
    -- Glow every reminder button, so they are noticeable without being looked
    -- at directly.
    glowReminderButtons = true,
    glowColor = { r = 1.0, g = 0.82, b = 0.0 },
    glowPulse = true,
    glowPulseSpeed = 0.6,
    glowMinAlpha = 0.35,
    minimapButtonHidden = false,
    minimapButtonAngle = 200,

    -- Feast announce
    feastAnnounceEnabled = true,
    feastAnnounceText = "",
    -- Per-context channels (mirrors WindTools Announcement system)
    feastAnnounceChannel = {
        solo     = "NONE",
        party    = "PARTY",
        instance = "INSTANCE_CHAT",
        raid     = "RAID",
    },
    feastAlertSound = "None",

    -- Dungeon callouts (array of {instanceID, name, buttons={...}})
    dungeonCallouts = {},

    -- Class buff sound alert (per-spellID, indexed by spellID)
    classBuffSounds = {},

    -- Role CC sound alert. healerCCAlertEnabled is the long-standing key for
    -- healer tracking and is kept as-is so existing profiles are unaffected;
    -- roleCCAlertTank was added in 1.60 and defaults off, so nobody gets a new
    -- alert they did not ask for.
    healerCCAlertEnabled = false,
    roleCCAlertTank = false,
    healerCCAlertSound = "None",
    healerCCReminderLocked = false,
    healerCCReminderScale = 1.0,

    -- User-registered custom sounds (array of {name=string, file=string})
    -- Files should be placed in Interface\AddOns\Squizzumables\Media\Sounds\
    customSounds = {},

    -- Button text appearance
    buttonLabelFontSize = 10,
    buttonTimerFontSize = 10,
    buttonCountFontSize = 10,
    buttonHeaderFontSize = 10,
    buttonLabelOffsetX = 0,
    buttonLabelOffsetY = -2,

    -- Kelerts: spell alert frame. No lock key: the alert image is click-through
    -- unconditionally, and Unlock Frames is what makes it draggable.
    kelAlertScale    = 1.0,

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
    -- anything. See Squizzumables_SpellAlerts.lua.
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
    { "beaconReminderFrame",      "beaconReminderPosition" },
    { "earthShieldReminderFrame", "earthShieldReminderPosition" },
    { "repairReminderFrame",      "repairReminderPosition" },
    { "symbioticReminderFrame",   "symbioticReminderPosition" },
    { "coachWhistleReminderFrame","coachWhistleReminderPosition" },
    { "petReminderFrame",         "petReminderPosition" },
    { "bresCounterFrame",         "bresCounterPosition" },
    { "healthstoneReminderFrame", "healthstoneReminderPosition" },
    { "bagsReminderFrame",        "bagsReminderPosition" },
    { "healerCCReminderFrame",    "healerCCReminderPosition" },
    { "deathTallyFrame",          "deathTallyPosition" },
    { "targetDistanceFrame",      "targetDistancePosition" },
    { "coTankFrame",              "coTankPosition" },
}

-- All position keys stored in profiles.
-- Derived from POSITION_PAIRS plus the frames whose Save/Load wrappers are
-- hand-written rather than generated:
--   framePosition         — the main button frame (BH:SaveFramePosition)
--   calloutsFramePosition — the dungeon callouts button frame
--   kelAlertPosition      — the Just For Kel alert (Squizzumables_SpellAlerts.lua)
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
    if self.ApplyCoTank then self:ApplyCoTank() end

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
    if self.ApplyCoTank then self:ApplyCoTank() end
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
local DB_VERSION = 7

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
    local isNewInstall = not SquizzumablesDB.settings
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
    self:LoadFramePosition()        -- main button frame
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
    { "beaconReminderFrame",      "beaconReminderScale" },
    { "earthShieldReminderFrame", "earthShieldReminderScale" },
    { "repairReminderFrame",      "repairReminderScale" },
    { "symbioticReminderFrame",   "symbioticReminderScale" },
    { "coachWhistleReminderFrame","coachWhistleReminderScale" },
    { "petReminderFrame",         "petReminderScale" },
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

-- Re-anchor the frame so the drag handle follows the buttons when anchor changes
function BH:UpdateFrameAnchor()
    local anchor = self.settings.anchorPoint or "LEFT"
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

function BH:CreateOptionsPanel()
    if not self.consumables then
        self:LoadSettings()
    end

    if self.optionsPanel then
        self:RefreshItemList()
        self:RefreshSettingsTab()
        self:RefreshRaidToolsTab()
        self:RefreshTextRemindersTab()
        if self.RefreshJustForKelTab then self:RefreshJustForKelTab() end
        self.optionsPanel:Show()
        return
    end

    -- Main frame
    local panel = CreateFrame("Frame", "SQUIZZUMABLESOptions", UIParent, "BackdropTemplate")
    -- Wider than the old 460x600: ten categories no longer have to be crammed
    -- into a tab strip that wrapped onto two rows, and the extra width gives
    -- the option rows somewhere to breathe.
    panel:SetSize(820, 620)
    panel:SetPoint("CENTER")
    panel:SetFrameStrata("DIALOG")
    panel:SetMovable(true)
    panel:SetResizable(true)
    if panel.SetResizeBounds then
        panel:SetResizeBounds(700, 520)
    elseif panel.SetMinResize then
        panel:SetMinResize(700, 520)
    end
    panel:EnableMouse(true)
    ApplySQBackdrop(panel, SQ_COLORS.bg, SQ_COLORS.border)
    self.optionsPanel = panel

    -- Resize grip, bottom-right.
    local resizeGrip = CreateFrame("Button", nil, panel)
    resizeGrip:SetSize(16, 16)
    resizeGrip:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -2, 2)
    local gripTex = resizeGrip:CreateTexture(nil, "OVERLAY")
    gripTex:SetAllPoints()
    gripTex:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    gripTex:SetVertexColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])
    resizeGrip:SetScript("OnMouseDown", function() panel:StartSizing("BOTTOMRIGHT") end)
    resizeGrip:SetScript("OnMouseUp", function() panel:StopMovingOrSizing() end)

    -- Combat protection: hide in combat, show after
    panel:RegisterEvent("PLAYER_REGEN_DISABLED")
    panel:RegisterEvent("PLAYER_REGEN_ENABLED")
    panel.wasShown = false
    panel:SetScript("OnEvent", function(self, event)
        if event == "PLAYER_REGEN_DISABLED" then
            if self:IsShown() then
                self.wasShown = true
                self:Hide()
            end
        elseif event == "PLAYER_REGEN_ENABLED" then
            if self.wasShown then
                self.wasShown = false
                self:Show()
            end
        end
    end)

    -- Title bar
    local titleBar = CreateFrame("Frame", nil, panel, "BackdropTemplate")
    titleBar:SetHeight(32)
    titleBar:SetPoint("TOPLEFT", panel, "TOPLEFT", 1, -1)
    titleBar:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -1, -1)
    titleBar:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
    })
    titleBar:SetBackdropColor(SQ_COLORS.titleBar[1], SQ_COLORS.titleBar[2], SQ_COLORS.titleBar[3], SQ_COLORS.titleBar[4])
    titleBar:EnableMouse(true)
    titleBar:RegisterForDrag("LeftButton")
    titleBar:SetScript("OnDragStart", function() panel:StartMoving() end)
    titleBar:SetScript("OnDragStop", function() panel:StopMovingOrSizing() end)

    -- Title text
    local titleMain = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    titleMain:SetPoint("LEFT", titleBar, "LEFT", 12, 0)
    titleMain:SetText("SQUIZZUMABLES")
    titleMain:SetTextColor(SQ_COLORS.textBright[1], SQ_COLORS.textBright[2], SQ_COLORS.textBright[3])

    local titleSub = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    titleSub:SetPoint("LEFT", titleMain, "RIGHT", 6, 0)
    titleSub:SetText("Configuration")
    titleSub:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])

    -- Close button
    local closeBtn = CreateFrame("Button", nil, titleBar)
    closeBtn:SetSize(32, 32)
    closeBtn:SetPoint("RIGHT", titleBar, "RIGHT", -2, 0)
    local closeText = closeBtn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    closeText:SetPoint("CENTER")
    closeText:SetText("X")
    closeText:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])
    closeBtn:SetScript("OnEnter", function() closeText:SetTextColor(SQ_COLORS.danger[1], SQ_COLORS.danger[2], SQ_COLORS.danger[3]) end)
    closeBtn:SetScript("OnLeave", function() closeText:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3]) end)
    closeBtn:SetScript("OnClick", function() panel:Hide() end)
    -- Also close on Escape
    table.insert(UISpecialFrames, "SQUIZZUMABLESOptions")

    -- ------------------------------------------------------------------------
    -- Settings search
    --
    -- Every option widget indexes itself as it is built, so this is only the
    -- box, the results list and the jump. Sits in the title bar, left of the
    -- close button.
    -- ------------------------------------------------------------------------
    -- Unlock Frames lives in the title bar rather than on the Settings tab, so
    -- it is one click away from whichever category is open -- positioning
    -- frames is something you do while looking at their settings, not after
    -- navigating back to Settings. Placed left of the search box to keep it off
    -- the close button.
    local unlockBtn = CreateSQButton(titleBar, "Unlock Frames", 112, 22)
    unlockBtn:SetScript("OnClick", function()
        BH:SetUnlockMode(not BH.unlockMode)
    end)
    ns.Rows.AddTooltip(unlockBtn, "Unlock Frames",
        "Makes every draggable frame in the addon visible and movable at once, whatever its own "
        .. "lock setting says. The options panel hides while unlocked so it is not in the way. "
        .. "Also available as /sq unlock.")
    self.unlockBtn = unlockBtn

    local searchBox = CreateSQEditBox(titleBar, 180, 20, { maxLetters = 40 })
    searchBox:SetPoint("RIGHT", closeBtn, "LEFT", -8, 0)

    local searchHint = searchBox:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    searchHint:SetPoint("LEFT", searchBox, "LEFT", 4, 0)
    searchHint:SetText("Search settings...")
    searchHint:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])

    -- Results drop below the box, over the content area.
    local resultsFrame = CreateFrame("Frame", nil, panel, "BackdropTemplate")
    resultsFrame:SetPoint("TOPRIGHT", searchBox, "BOTTOMRIGHT", 4, -4)
    resultsFrame:SetWidth(300)
    resultsFrame:SetFrameStrata("FULLSCREEN_DIALOG")
    ApplySQBackdrop(resultsFrame, SQ_COLORS.bg, SQ_COLORS.border)
    resultsFrame:Hide()
    self.searchResultsFrame = resultsFrame

    local MAX_RESULTS  = 8
    local RESULT_H     = 30
    local resultButtons = {}

    local function HideResults()
        resultsFrame:Hide()
    end

    local function ShowResults(query)
        local results = ns.Rows.Search(query, MAX_RESULTS)
        if #results == 0 then
            HideResults()
            return
        end
        for i, res in ipairs(results) do
            local btn = resultButtons[i]
            if not btn then
                btn = CreateFrame("Button", nil, resultsFrame)
                btn:SetHeight(RESULT_H)
                btn:SetPoint("TOPLEFT", resultsFrame, "TOPLEFT", 4, -4 - (i - 1) * RESULT_H)
                btn:SetPoint("TOPRIGHT", resultsFrame, "TOPRIGHT", -4, -4 - (i - 1) * RESULT_H)

                local hl = btn:CreateTexture(nil, "BACKGROUND")
                hl:SetAllPoints()
                hl:SetColorTexture(SQ_COLORS.controlHi[1], SQ_COLORS.controlHi[2], SQ_COLORS.controlHi[3], 0.6)
                hl:Hide()
                btn:SetScript("OnEnter", function() hl:Show() end)
                btn:SetScript("OnLeave", function() hl:Hide() end)

                btn.title = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                btn.title:SetPoint("TOPLEFT", btn, "TOPLEFT", 6, -3)
                btn.title:SetJustifyH("LEFT")
                btn.title:SetTextColor(SQ_COLORS.text[1], SQ_COLORS.text[2], SQ_COLORS.text[3])

                -- Which category the option lives in, so a result is
                -- identifiable when two tabs use a similar label ("Scale"
                -- appears on several).
                btn.where = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                btn.where:SetPoint("BOTTOMLEFT", btn, "BOTTOMLEFT", 6, 3)
                btn.where:SetJustifyH("LEFT")
                ns.ApplyAccent(btn.where, "text")

                resultButtons[i] = btn
            end
            btn.title:SetText(res.entry.label)
            -- "Raid Tools > Pull Timer" where the page has sub-tabs, so a
            -- result names the sub-tab it will switch to rather than just the
            -- page, which for a six-section page says almost nothing.
            local pageLabel = res.entry.page and res.entry.page.label or ""
            local sectionLabel = res.entry.section and res.entry.section.label
            btn.where:SetText(sectionLabel and (pageLabel .. " > " .. sectionLabel) or pageLabel)
            btn:SetScript("OnClick", function()
                ns.Rows.JumpTo(res.entry)
                searchBox:SetText("")
                searchBox:ClearFocus()
                searchHint:Show()
                HideResults()
            end)
            btn:Show()
        end
        for i = #results + 1, #resultButtons do resultButtons[i]:Hide() end
        resultsFrame:SetHeight(#results * RESULT_H + 8)
        resultsFrame:Show()
    end

    searchBox:SetScript("OnTextChanged", function(box)
        local text = box:GetText()
        searchHint:SetShown(text == "")
        ShowResults(text)
    end)
    searchBox.onFocusGained = function() searchHint:Hide() end
    searchBox.onFocusLost = function(box)
        searchHint:SetShown(box:GetText() == "")
    end
    searchBox:SetScript("OnEscapePressed", function(box)
        box:SetText("")
        box:ClearFocus()
        HideResults()
    end)
    -- Enter takes the top result, so a query can be completed without the mouse.
    searchBox:SetScript("OnEnterPressed", function(box)
        local results = ns.Rows.Search(box:GetText(), 1)
        if results[1] then ns.Rows.JumpTo(results[1].entry) end
        box:SetText("")
        box:ClearFocus()
        HideResults()
    end)

    -- Anchored after the search box exists, so it sits to its left rather than
    -- next to the close button, where a misclick would shut the panel.
    unlockBtn:SetPoint("RIGHT", searchBox, "LEFT", -10, 0)
    panel:HookScript("OnHide", HideResults)

    -- Accent line under title
    local accentLine = titleBar:CreateTexture(nil, "OVERLAY")
    accentLine:SetHeight(1)
    accentLine:SetPoint("BOTTOMLEFT", titleBar, "BOTTOMLEFT", 0, 0)
    accentLine:SetPoint("BOTTOMRIGHT", titleBar, "BOTTOMRIGHT", 0, 0)
    ns.ApplyAccent(accentLine, "texture", 0.4)

    -- Left navigation sidebar.
    --
    -- Replaces a horizontal tab strip that had to wrap onto two rows to fit ten
    -- categories. A vertical list scales to any number of entries, keeps every
    -- category visible at once, and leaves the full width of the panel for the
    -- options themselves.
    local NAV_WIDTH  = 180
    local NAV_ITEM_H = 26

    local navBar = CreateFrame("Frame", nil, panel, "BackdropTemplate")
    navBar:SetPoint("TOPLEFT", titleBar, "BOTTOMLEFT", 0, 0)
    navBar:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 1, 40)
    navBar:SetWidth(NAV_WIDTH)
    navBar:SetBackdrop({ bgFile = "Interface\\BUTTONS\\WHITE8X8" })
    navBar:SetBackdropColor(SQ_COLORS.tabInactive[1], SQ_COLORS.tabInactive[2], SQ_COLORS.tabInactive[3], 1)

    -- Divider between the sidebar and the content area.
    local navEdge = navBar:CreateTexture(nil, "OVERLAY")
    navEdge:SetWidth(1)
    navEdge:SetPoint("TOPRIGHT", navBar, "TOPRIGHT", 0, 0)
    navEdge:SetPoint("BOTTOMRIGHT", navBar, "BOTTOMRIGHT", 0, 0)
    navEdge:SetColorTexture(SQ_COLORS.border[1], SQ_COLORS.border[2], SQ_COLORS.border[3], 0.5)

    local navCursorY = -6

    local function CreateTab(text)
        local item = CreateFrame("Button", nil, navBar, "BackdropTemplate")
        item:SetHeight(NAV_ITEM_H)
        item:SetPoint("TOPLEFT", navBar, "TOPLEFT", 0, navCursorY)
        item:SetPoint("TOPRIGHT", navBar, "TOPRIGHT", -1, navCursorY)
        navCursorY = navCursorY - NAV_ITEM_H

        item:SetBackdrop({ bgFile = "Interface\\BUTTONS\\WHITE8X8" })
        item:SetBackdropColor(0, 0, 0, 0)

        local itemLabel = item:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        itemLabel:SetPoint("LEFT", item, "LEFT", 16, 0)
        itemLabel:SetJustifyH("LEFT")
        itemLabel:SetText(text)
        itemLabel:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])
        item.label = itemLabel

        -- Accent bar down the left edge of the selected entry, replacing the
        -- underline the horizontal tabs used.
        local marker = item:CreateTexture(nil, "OVERLAY")
        marker:SetWidth(3)
        marker:SetPoint("TOPLEFT", item, "TOPLEFT", 0, 0)
        marker:SetPoint("BOTTOMLEFT", item, "BOTTOMLEFT", 0, 0)
        ns.ApplyAccent(marker, "texture", 1)
        marker:Hide()
        item.marker = marker

        item:SetScript("OnEnter", function(self)
            if not self.isActive then
                self:SetBackdropColor(SQ_COLORS.controlHi[1], SQ_COLORS.controlHi[2], SQ_COLORS.controlHi[3], 0.5)
            end
        end)
        item:SetScript("OnLeave", function(self)
            if not self.isActive then self:SetBackdropColor(0, 0, 0, 0) end
        end)

        item.SetActive = function(self, active)
            self.isActive = active
            if active then
                self:SetBackdropColor(SQ_COLORS.tabActive[1], SQ_COLORS.tabActive[2], SQ_COLORS.tabActive[3], 1)
                self.label:SetTextColor(SQ_COLORS.textBright[1], SQ_COLORS.textBright[2], SQ_COLORS.textBright[3])
                self.marker:Show()
            else
                self:SetBackdropColor(0, 0, 0, 0)
                self.label:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])
                self.marker:Hide()
            end
        end
        return item
    end

    local settingsTabBtn = CreateTab("Settings")
    local itemsTabBtn = CreateTab("Items")
    local classBuffsTabBtn = CreateTab("Class Buffs")
    local raidToolsTabBtn = CreateTab("Raid Tools")
    local textRemindersTabBtn = CreateTab("Reminders")
    local cdmTabBtn = CreateTab("Cooldowns")
    local cdmCustomTabBtn = CreateTab("Custom Icons")
    local soundsTabBtn = CreateTab("Sounds")
    local calloutsTabBtn = CreateTab("Callouts")
    local kelTabBtn = CreateTab("Kelerts")
    local cdmSoundsTabBtn = CreateTab("CDM Sounds")

    -- Content area: everything right of the sidebar.
    local contentArea = CreateFrame("Frame", nil, panel)
    contentArea:SetPoint("TOPLEFT", navBar, "TOPRIGHT", 1, 0)
    contentArea:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -1, 40)

    -- Settings tab content
    local settingsTab = CreateFrame("Frame", nil, contentArea)
    settingsTab:SetAllPoints()
    self.settingsTab = settingsTab

    -- Items tab content
    local itemsTab = CreateFrame("Frame", nil, contentArea)
    itemsTab:SetAllPoints()
    itemsTab:Hide()
    self.itemsTab = itemsTab

    -- Raid Tools tab content
    local raidToolsTab = CreateFrame("Frame", nil, contentArea)
    raidToolsTab:SetAllPoints()
    raidToolsTab:Hide()
    self.raidToolsTab = raidToolsTab

    -- Text Reminders tab content
    local textRemindersTab = CreateFrame("Frame", nil, contentArea)
    textRemindersTab:SetAllPoints()
    textRemindersTab:Hide()
    self.textRemindersTab = textRemindersTab

    -- Cooldown Manager tab content
    local cdmTab = CreateFrame("Frame", nil, contentArea)
    cdmTab:SetAllPoints()
    cdmTab:Hide()
    self.cdmTab = cdmTab

    -- Custom cooldown icons tab content
    local cdmCustomTab = CreateFrame("Frame", nil, contentArea)
    cdmCustomTab:SetAllPoints()
    cdmCustomTab:Hide()
    self.cdmCustomTab = cdmCustomTab

    -- Sounds tab content
    local soundsTab = CreateFrame("Frame", nil, contentArea)
    soundsTab:SetAllPoints()
    soundsTab:Hide()
    self.soundsTab = soundsTab

    -- Callouts tab content
    local calloutsTab = CreateFrame("Frame", nil, contentArea)
    calloutsTab:SetAllPoints()
    calloutsTab:Hide()
    self.calloutsTab = calloutsTab

    -- Just For Kel tab content
    local kelTab = CreateFrame("Frame", nil, contentArea)
    kelTab:SetAllPoints()
    kelTab:Hide()
    self.kelTab = kelTab

    -- CDM Sounds tab content
    local cdmSoundsTab = CreateFrame("Frame", nil, contentArea)
    cdmSoundsTab:SetAllPoints()
    cdmSoundsTab:Hide()
    self.cdmSoundsTab = cdmSoundsTab

    -- Class Buffs tab content
    local classBuffsTab = CreateFrame("Frame", nil, contentArea)
    classBuffsTab:SetAllPoints()
    classBuffsTab:Hide()
    self.classBuffsTab = classBuffsTab

    -- Tab switching
    local function SwitchTab(active)
        settingsTabBtn:SetActive(active == "settings")
        itemsTabBtn:SetActive(active == "items")
        raidToolsTabBtn:SetActive(active == "raidtools")
        textRemindersTabBtn:SetActive(active == "reminders")
        cdmTabBtn:SetActive(active == "cdm")
        soundsTabBtn:SetActive(active == "sounds")
        classBuffsTabBtn:SetActive(active == "classbuffs")
        calloutsTabBtn:SetActive(active == "callouts")
        kelTabBtn:SetActive(active == "kel")
        cdmCustomTabBtn:SetActive(active == "cdmcustom")
        cdmSoundsTabBtn:SetActive(active == "cdmsounds")
        if active == "settings" then settingsTab:Show() else settingsTab:Hide() end
        if active == "items" then itemsTab:Show() else itemsTab:Hide() end
        if active == "raidtools" then raidToolsTab:Show() else raidToolsTab:Hide() end
        if active == "reminders" then textRemindersTab:Show() else textRemindersTab:Hide() end
        if active == "cdm" then cdmTab:Show() else cdmTab:Hide() end
        if active == "cdmcustom" then cdmCustomTab:Show() else cdmCustomTab:Hide() end
        if active == "sounds" then soundsTab:Show() else soundsTab:Hide() end
        if active == "classbuffs" then classBuffsTab:Show() else classBuffsTab:Hide() end
        if active == "callouts" then calloutsTab:Show() else calloutsTab:Hide() end
        if active == "kel" then kelTab:Show() else kelTab:Hide() end
        if active == "cdmsounds" then cdmSoundsTab:Show() else cdmSoundsTab:Hide() end
    end
    settingsTabBtn:SetScript("OnClick", function() SwitchTab("settings") end)
    itemsTabBtn:SetScript("OnClick", function() SwitchTab("items") end)
    raidToolsTabBtn:SetScript("OnClick", function() SwitchTab("raidtools") end)
    textRemindersTabBtn:SetScript("OnClick", function() SwitchTab("reminders") end)
    cdmTabBtn:SetScript("OnClick", function() SwitchTab("cdm") end)
    cdmCustomTabBtn:SetScript("OnClick", function() SwitchTab("cdmcustom") end)
    soundsTabBtn:SetScript("OnClick", function() SwitchTab("sounds") end)
    classBuffsTabBtn:SetScript("OnClick", function() SwitchTab("classbuffs") end)
    calloutsTabBtn:SetScript("OnClick", function() SwitchTab("callouts") end)
    kelTabBtn:SetScript("OnClick", function() SwitchTab("kel") end)
    cdmSoundsTabBtn:SetScript("OnClick", function() SwitchTab("cdmsounds") end)
    self.switchTab = SwitchTab
    SwitchTab("settings")

    -- Build each page with ns.Rows.currentPage set, so every option widget the
    -- page creates is indexed against the right sidebar category. That is what
    -- lets the settings search say where a result lives and jump to it.
    local pages = {
        { key = "settings",   label = "Settings",    frame = settingsTab,      build = "BuildSettingsTab" },
        { key = "raidtools",  label = "Raid Tools",  frame = raidToolsTab,     build = "BuildRaidToolsTab" },
        { key = "reminders",  label = "Reminders",   frame = textRemindersTab, build = "BuildTextRemindersTab" },
        { key = "cdm",        label = "Cooldowns",   frame = cdmTab,           build = "BuildCDMTab" },
        { key = "cdmcustom",  label = "Custom Icons", frame = cdmCustomTab,    build = "BuildCustomCooldownsTab" },
        { key = "sounds",     label = "Sounds",      frame = soundsTab,        build = "BuildSoundsTab" },
        { key = "classbuffs", label = "Class Buffs", frame = classBuffsTab,    build = "BuildClassBuffsTab" },
        { key = "callouts",   label = "Callouts",    frame = calloutsTab,      build = "BuildCalloutsTab" },
        { key = "kel",        label = "Kelerts",     frame = kelTab,           build = "BuildJustForKelTab" },
        { key = "cdmsounds",  label = "CDM Sounds",  frame = cdmSoundsTab,     build = "BuildCDMSoundsTab" },
    }
    for _, page in ipairs(pages) do
        local builder = self[page.build]
        if builder then
            ns.Rows.currentPage = page
            builder(self, page.frame)
        end
    end
    ns.Rows.currentPage = nil

    -- Build items tab
    local desc = itemsTab:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    desc:SetPoint("TOPLEFT", itemsTab, "TOPLEFT", 14, -10)
    desc:SetWidth(400)
    desc:SetText("Check items to enable. Drag items from your bags to the drop zones to add.")
    desc:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])

    local scrollFrame = CreateFrame("ScrollFrame", nil, itemsTab, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -8)
    scrollFrame:SetPoint("BOTTOMRIGHT", itemsTab, "BOTTOMRIGHT", -22, 4)

    local scrollChild = CreateFrame("Frame", nil, scrollFrame)
    scrollChild:SetSize(390, 1)
    scrollFrame:SetScrollChild(scrollChild)
    self.scrollChild = scrollChild

    -- Bottom bar with close button
    local bottomBar = CreateFrame("Frame", nil, panel)
    bottomBar:SetHeight(40)
    bottomBar:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 1, 1)
    bottomBar:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -1, 1)

    local bottomLine = bottomBar:CreateTexture(nil, "OVERLAY")
    bottomLine:SetHeight(1)
    bottomLine:SetPoint("TOPLEFT", bottomBar, "TOPLEFT", 0, 0)
    bottomLine:SetPoint("TOPRIGHT", bottomBar, "TOPRIGHT", 0, 0)
    bottomLine:SetColorTexture(SQ_COLORS.border[1], SQ_COLORS.border[2], SQ_COLORS.border[3], 0.3)

    local closeBtnBottom = CreateSQButton(bottomBar, "Close", 80, 26)
    closeBtnBottom:SetPoint("CENTER", bottomBar, "CENTER", 0, 0)
    closeBtnBottom:SetScript("OnClick", function() panel:Hide() end)

    self:RefreshItemList()
    self:RefreshClassBuffList()
    self:RefreshSettingsTab()
    self:RefreshRaidToolsTab()
    self:RefreshTextRemindersTab()
    if self.RefreshJustForKelTab then self:RefreshJustForKelTab() end
    self:RefreshCalloutsTab()
    panel:Show()
end

-- ============================================================================
-- Settings Tab Content
-- ============================================================================

-- StaticPopup for New Profile name input
StaticPopupDialogs["SQUIZZUMABLES_NEW_PROFILE"] = {
    text = "Enter a name for the new profile:",
    button1 = "Create",
    button2 = "Cancel",
    hasEditBox = true,
    maxLetters = 32,
    OnAccept = function(self)
        local name = self.editBox:GetText():match("^%s*(.-)%s*$")
        if name and name ~= "" then
            local copyFrom = BH:GetActiveProfileName()
            -- Save current state before copying
            BH:SaveToProfile()
            if BH:CreateProfile(name, copyFrom) then
                BH:SwitchToProfile(name)
                BH:LoadAllFramePositions()
                BH:ApplyAllFrameScales()
                BH:UpdateFrameLock()
                BH:UpdateButtons()
                BH:RefreshSettingsTab()
                print("Squizzumables: Created and switched to profile '" .. name .. "'")
            else
                print("Squizzumables: Profile '" .. name .. "' already exists.")
            end
        end
    end,
    EditBoxOnEnterPressed = function(self)
        local parent = self:GetParent()
        StaticPopupDialogs["SQUIZZUMABLES_NEW_PROFILE"].OnAccept(parent)
        parent:Hide()
    end,
    EditBoxOnEscapePressed = function(self)
        self:GetParent():Hide()
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- StaticPopup for Delete Profile confirmation
StaticPopupDialogs["SQUIZZUMABLES_DELETE_PROFILE"] = {
    text = "Delete profile '%s'? Characters using this profile will be switched to Default.",
    button1 = "Delete",
    button2 = "Cancel",
    OnAccept = function(self, data)
        if BH:DeleteProfile(data) then
            -- If we deleted our own active profile, we're now on Default
            BH:LoadFromProfile("Default")
            BH.settings = SquizzumablesDB.settings
            BH.disabled = SquizzumablesDB.disabled
            BH.minDuration = SquizzumablesDB.minDuration
            BH.customItems = SquizzumablesDB.customItems
            BH:LoadAllFramePositions()
            BH:ApplyAllFrameScales()
            BH:UpdateFrameLock()
            BH:UpdateButtons()
            -- Default's Cooldown Manager layout, not the deleted profile's.
            if BH.cdm and BH.cdm.OnProfileChanged then BH.cdm:OnProfileChanged() end
            if BH.ApplyTargetDistance then BH:ApplyTargetDistance() end
            if BH.ApplyCoTank then BH:ApplyCoTank() end
            BH:RefreshSettingsTab()
            print("Squizzumables: Deleted profile '" .. data .. "', switched to Default.")
        end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- Shared modal for both directions: export fills it with a string to copy,
-- import waits for one to be pasted. One frame because the two are the same
-- thing -- a big selectable text box -- and having two would mean two places to
-- get the select-all and focus handling right.
function BH:ShowProfileStringDialog(mode, text)
    local f = self.profileIOFrame
    if not f then
        f = CreateFrame("Frame", "SQUIZZUMABLESProfileIO", UIParent, "BackdropTemplate")
        f:SetSize(520, 260)
        f:SetPoint("CENTER")
        f:SetFrameStrata("FULLSCREEN_DIALOG")
        f:SetMovable(true)
        f:EnableMouse(true)
        f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", function(self) self:StartMoving() end)
        f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
        ApplySQBackdrop(f, SQ_COLORS.bg, SQ_COLORS.border)
        table.insert(UISpecialFrames, "SQUIZZUMABLESProfileIO")

        f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        f.title:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -12)
        ns.ApplyAccent(f.title, "text")

        f.hint = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        f.hint:SetPoint("TOPLEFT", f.title, "BOTTOMLEFT", 0, -6)
        f.hint:SetWidth(490)
        f.hint:SetJustifyH("LEFT")
        f.hint:SetWordWrap(true)
        f.hint:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])

        local scroll = CreateFrame("ScrollFrame", "SQUIZZUMABLESProfileIOScroll", f, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -74)
        scroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -34, 46)

        local edit = CreateFrame("EditBox", nil, scroll)
        edit:SetMultiLine(true)
        edit:SetAutoFocus(false)
        edit:SetFontObject(ChatFontNormal)
        edit:SetWidth(460)
        edit:SetScript("OnEscapePressed", function() f:Hide() end)
        scroll:SetScrollChild(edit)
        f.edit = edit

        f.action = CreateSQButton(f, "Import", 110, 24)
        f.action:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -14, 14)

        local closeBtn = CreateSQButton(f, "Close", 80, 24)
        closeBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 14, 14)
        closeBtn:SetScript("OnClick", function() f:Hide() end)

        self.profileIOFrame = f
    end

    f.edit:SetText(text or "")
    if mode == "export" then
        f.title:SetText("Export Profile")
        f.hint:SetText("Press Ctrl-A then Ctrl-C to copy this string. Anyone with Squizzumables "
            .. "can paste it into Import to get these settings.")
        f.action:Hide()
        -- Select it for them: the first thing anyone does here is select all.
        f.edit:SetFocus()
        f.edit:HighlightText()
    else
        f.title:SetText("Import Profile")
        f.hint:SetText("Paste a Squizzumables profile string here, then choose Import. "
            .. "It is added as a new profile -- nothing you already have is changed.")
        f.action:Show()
        f.action:SetText("Import")
        f.action:SetScript("OnClick", function()
            local data, err = ns.ProfileIO.Decode(f.edit:GetText())
            if not data then
                print("Squizzumables: " .. (err or "Could not read that string."))
                return
            end
            -- Never overwrite an existing profile silently: an import that
            -- quietly replaced the profile you were using would be unrecoverable.
            local name = data.name or "Imported"
            local base, n = name, 2
            while SquizzumablesDB.profiles and SquizzumablesDB.profiles[name] do
                name = base .. " (" .. n .. ")"
                n = n + 1
            end
            local ok, result = ns.ProfileIO.Apply(data, name)
            if not ok then
                print("Squizzumables: " .. tostring(result))
                return
            end
            print("Squizzumables: imported profile '" .. result .. "'. Select it from the Active Profile dropdown to use it.")
            f:Hide()
            BH:RefreshSettingsTab()
        end)
        f.edit:SetFocus()
    end
    f:Show()
end

function BH:BuildSettingsTab(parent)
    local scrollFrame = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    scrollFrame:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -22, 0)

    local content = CreateFrame("Frame", nil, scrollFrame)
    content:SetWidth(400)
    scrollFrame:SetScrollChild(content)

    local yOffset = -14
    local leftPad = 14

    -- === Profiles Section ===
    local profileSection = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    profileSection:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    profileSection:SetText("PROFILES")
    ns.ApplyAccent(profileSection, "text")
    yOffset = yOffset - 18

    local profileNote = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    profileNote:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    profileNote:SetWidth(370)
    profileNote:SetJustifyH("LEFT")
    profileNote:SetText("Per-character settings. Assign a spec-specific profile below to auto-switch on spec change.")
    profileNote:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])
    yOffset = yOffset - 34

    -- Active profile dropdown
    local function GetProfileDropdownItems()
        local items = {}
        for _, name in ipairs(BH:GetProfileList()) do
            table.insert(items, { text = name, value = name })
        end
        return items
    end

    local profileDropdown = CreateSQDropdown(content, "Active Profile", 200, GetProfileDropdownItems(), function(value)
        if value == BH:GetActiveProfileName() then return end
        BH:SwitchToProfile(value)
        BH:LoadAllFramePositions()
        BH:ApplyAllFrameScales()
        BH:UpdateFrameLock()
        BH:UpdateButtons()
        BH:RefreshSettingsTab()
        BH:RefreshItemList()
        BH:RefreshRaidToolsTab()
        BH:RefreshTextRemindersTab()
    end)
    profileDropdown:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    self.profileDropdown = profileDropdown
    ns.Rows.AddTooltip(profileDropdown, "Active Profile", "Which settings profile this character uses. Profiles hold every setting and every frame position, so you can keep one layout for raiding and another for M+.")
    yOffset = yOffset - 50

    -- Spec-specific profile dropdown
    -- Build items: first entry = none (use character-level profile), then all profiles
    local function GetSpecProfileDropdownItems()
        local specIndex = GetSpecialization()
        local specName = "Current Spec"
        if specIndex then
            local _, name = GetSpecializationInfo(specIndex)
            if name then specName = name end
        end
        local items = { { text = "\226\128\148 (use character profile)", value = "" } }
        for _, name in ipairs(BH:GetProfileList()) do
            table.insert(items, { text = name, value = name })
        end
        return items, specName
    end

    local specItems, specName = GetSpecProfileDropdownItems()
    local specProfileDropdown = CreateSQDropdown(content, "Profile for " .. specName, 200, specItems, function(value)
        local profileName = (value and value ~= "") and value or nil
        BH:SetSpecProfile(profileName)
    end)
    specProfileDropdown:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    specProfileDropdown:SetSelectedValue(BH:GetSpecProfile() or "")
    self.specProfileDropdown = specProfileDropdown
    ns.Rows.AddTooltip(specProfileDropdown, "Spec Profile", "Override the character profile for this specialisation only. Leave unset to always use the character profile.")
    yOffset = yOffset - 50

    -- Profile action buttons (row)
    local newProfileBtn = CreateSQButton(content, "New", 80, 24)
    newProfileBtn:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    newProfileBtn:SetScript("OnClick", function()
        StaticPopup_Show("SQUIZZUMABLES_NEW_PROFILE")
    end)

    local deleteProfileBtn = CreateSQButton(content, "Delete", 80, 24, SQ_COLORS.danger)
    deleteProfileBtn:SetPoint("LEFT", newProfileBtn, "RIGHT", 6, 0)
    deleteProfileBtn:SetScript("OnClick", function()
        local name = BH:GetActiveProfileName()
        if name == "Default" then
            print("Squizzumables: Cannot delete the Default profile.")
            return
        end
        local popup = StaticPopup_Show("SQUIZZUMABLES_DELETE_PROFILE", name)
        if popup then popup.data = name end
    end)

    local copyToDefaultBtn = CreateSQButton(content, "Copy to Default", 120, 24)
    copyToDefaultBtn:SetPoint("LEFT", deleteProfileBtn, "RIGHT", 6, 0)
    copyToDefaultBtn:SetScript("OnClick", function()
        BH:UpdateDefaultProfile()
        print("Squizzumables: Current settings copied to Default profile.")
    end)
    yOffset = yOffset - 32

    local exportBtn = CreateSQButton(content, "Export", 80, 24)
    exportBtn:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    exportBtn:SetScript("OnClick", function()
        local str, err = ns.ProfileIO.Export()
        if not str then
            print("Squizzumables: " .. (err or "Could not export that profile."))
            return
        end
        BH:ShowProfileStringDialog("export", str)
    end)
    ns.Rows.AddTooltip(exportBtn, "Export",
        "Produces a shareable string for the active profile. Only settings you have changed from "
        .. "the defaults are included, which keeps the string short and means importing it into a "
        .. "newer version picks up any newly added defaults.")

    local importBtn = CreateSQButton(content, "Import", 80, 24)
    importBtn:SetPoint("LEFT", exportBtn, "RIGHT", 6, 0)
    importBtn:SetScript("OnClick", function()
        BH:ShowProfileStringDialog("import", "")
    end)
    ns.Rows.AddTooltip(importBtn, "Import",
        "Paste a profile string from someone else. It always arrives as a new profile, so nothing "
        .. "you already have is overwritten.")
    yOffset = yOffset - 32

    local resetFromDefaultBtn = CreateSQButton(content, "Reset from Default", 140, 24)
    resetFromDefaultBtn:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    resetFromDefaultBtn:SetScript("OnClick", function()
        local defaultProfile = SquizzumablesDB.profiles and SquizzumablesDB.profiles["Default"]
        if not defaultProfile then return end
        -- Overwrite the active profile with Default's data
        local activeName = BH:GetActiveProfileName()
        SquizzumablesDB.profiles[activeName] = CopyTable(defaultProfile)
        BH:LoadFromProfile(activeName)
        BH.settings = SquizzumablesDB.settings
        BH.disabled = SquizzumablesDB.disabled
        BH.minDuration = SquizzumablesDB.minDuration
        BH.customItems = SquizzumablesDB.customItems
        BH:LoadAllFramePositions()
        BH:ApplyAllFrameScales()
        BH:UpdateFrameLock()
        BH:UpdateButtons()
        -- Default's Cooldown Manager layout came across with the CopyTable
        -- above, since it lives on the profile as of 1.70. Rebuild so it shows.
        if BH.cdm and BH.cdm.OnProfileChanged then BH.cdm:OnProfileChanged() end
        if BH.ApplyTargetDistance then BH:ApplyTargetDistance() end
        if BH.ApplyCoTank then BH:ApplyCoTank() end
        BH:RefreshSettingsTab()
        BH:RefreshItemList()
        BH:RefreshRaidToolsTab()
        BH:RefreshTextRemindersTab()
        print("Squizzumables: Reset to Default profile settings.")
    end)
    yOffset = yOffset - 34

    CreateSQDivider(content, yOffset)
    yOffset = yOffset - 14

    -- === Appearance Section ===
    local sectionLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sectionLabel:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    sectionLabel:SetText("APPEARANCE")
    ns.ApplyAccent(sectionLabel, "text")
    yOffset = yOffset - 22

    -- Button Size
    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "slider",
        label = "Button Size",
        width = 300, min = 20, max = 64, step = 2,
        tooltip = "Width and height of each reminder button, in pixels.",
        get = function() return BH.settings.buttonSize or 36 end,
        set = function(value)
            BH.settings.buttonSize = value
            BH:SaveSettings()
            BH:UpdateButtons()
        end,
    })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "slider",
        label = "Button Spacing",
        width = 300, min = 5, max = 20, step = 1,
        tooltip = "Gap between reminder buttons, in pixels.",
        get = function() return BH.settings.buttonSpacing or 5 end,
        set = function(value)
            BH.settings.buttonSpacing = value
            BH:SaveSettings()
            BH:UpdateButtons()
        end,
    })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "check",
        label = "Show Label Text",
        tooltip = "Show the name under each reminder button. Turn off for a more compact row of icons.",
        get = function() return BH.settings.showLabelText and true or false end,
        set = function(v)
            BH.settings.showLabelText = v
            BH:SaveSettings()
            BH:UpdateButtons()
        end,
    })


    -- Class-coloured accents. Recolours live rather than needing a reload:
    -- every long-lived accent region is registered with ns.ApplyAccent, and
    -- the handful of hover handlers read ns.GetAccentColor() as they run.
    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "check",
        label = "Use class colour for headings and accents",
        tooltip = "Draws section headings, the selected sidebar entry, checkbox ticks, "
               .. "slider fills and button accents in your class colour. "
               .. "Turn this off for the default warm gold.",
        get = function() return BH.settings and BH.settings.useClassColorAccent ~= false end,
        set = function(v)
            BH.settings.useClassColorAccent = v
            BH:SaveSettings()
        end,
        after = function() ns.RefreshAccentColors() end,
    })

    CreateSQDivider(content, yOffset)
    yOffset = yOffset - 14

    -- === Layout Section ===
    local layoutSection = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    layoutSection:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    layoutSection:SetText("LAYOUT")
    ns.ApplyAccent(layoutSection, "text")
    yOffset = yOffset - 22

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "dropdown",
        label = "Layout Direction",
        width = 160,
        tooltip = "Whether the reminder buttons lay out in a row or a column.",
        items = {
            { text = "Horizontal", value = "HORIZONTAL" },
            { text = "Vertical",   value = "VERTICAL" },
        },
        get = function() return BH.settings.layoutDirection or "HORIZONTAL" end,
        set = function(value)
            BH.settings.layoutDirection = value
            -- Not every grow direction is valid in every layout, so let the
            -- existing validator correct it; the grow row below rebuilds its
            -- own options from this on the refresh that follows.
            BH:ValidateGrowDirection()
            BH:SaveSettings()
            BH:UpdateButtons()
        end,
    })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "dropdown",
        label = "Grow Direction",
        width = 160,
        tooltip = "Which way new buttons are added from the anchor as the number of reminders changes.",
        -- A function, so the options follow the layout above rather than the
        -- layout handler reaching across to rewrite them.
        items = function()
            return BH:GetGrowItemsForLayout(BH.settings.layoutDirection or "HORIZONTAL")
        end,
        get = function() return BH.settings.growDirection end,
        set = function(value)
            BH.settings.growDirection = value
            BH:SaveSettings()
            BH:UpdateButtons()
        end,
    })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "dropdown",
        label = "Anchor Point",
        width = 160,
        tooltip = "Which edge of the button block stays put as buttons are added or removed.",
        items = {
            { text = "Top",    value = "TOP" },
            { text = "Left",   value = "LEFT" },
            { text = "Center", value = "CENTER" },
            { text = "Right",  value = "RIGHT" },
            { text = "Bottom", value = "BOTTOM" },
        },
        get = function() return BH.settings.anchorPoint or "CENTER" end,
        set = function(value)
            BH.settings.anchorPoint = value
            BH:SaveSettings()
            BH:UpdateButtons()
            BH:UpdateFrameAnchor()
        end,
    })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "check",
        label = "Lock Frame Position",
        tooltip = "Stops the reminder buttons being dragged. Unlock Frames overrides this while you are positioning things.",
        get = function() return BH.settings.frameLocked and true or false end,
        set = function(v)
            BH.settings.frameLocked = v
            BH:SaveSettings()
            BH:UpdateFrameLock()
        end,
    })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, { type = "divider" })
    yOffset = yOffset - ns.Rows.Add(content, yOffset, { type = "header", label = "BUTTON TEXT" })

    -- Six sliders that differ only in label, range and which setting they
    -- write, so they are a table rather than six near-identical blocks.
    for _, s in ipairs({
        { key = "buttonLabelFontSize",  label = "Label Font Size",          min = 6,   max = 24, default = 11,
          tip = "Size of the name text under each button." },
        { key = "buttonTimerFontSize",  label = "Timer Font Size",          min = 6,   max = 24, default = 12,
          tip = "Size of the remaining-time countdown drawn on each button." },
        { key = "buttonCountFontSize",  label = "Count Font Size",          min = 6,   max = 24, default = 11,
          tip = "Size of the bag-quantity number in the corner of each button." },
        { key = "buttonHeaderFontSize", label = "Header Font Size (MH/OH)", min = 6,   max = 24, default = 10,
          tip = "Size of the small header above a button, such as the MH and OH markers on weapon oils." },
        { key = "buttonLabelOffsetX",   label = "Label X Offset",           min = -20, max = 20, default = 0,
          tip = "Nudge the label text horizontally relative to its button." },
        { key = "buttonLabelOffsetY",   label = "Label Y Offset",           min = -20, max = 10, default = 0,
          tip = "Nudge the label text vertically relative to its button." },
    }) do
        yOffset = yOffset - ns.Rows.Add(content, yOffset, {
            type = "slider",
            label = s.label,
            width = 300, min = s.min, max = s.max, step = 1,
            tooltip = s.tip,
            get = function() return BH.settings[s.key] or s.default end,
            set = function(value)
                BH.settings[s.key] = value
                BH:SaveSettings()
                BH:UpdateButtons()
            end,
            -- The label offsets and font size only matter when labels are on.
            disabled = (s.key:find("Label") ~= nil)
                and function() return not BH.settings.showLabelText end
                or nil,
        })
    end


    CreateSQDivider(content, yOffset)
    yOffset = yOffset - 14

    -- === Preview & Reset Section ===
    local toolsSection = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    toolsSection:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    toolsSection:SetText("TOOLS")
    ns.ApplyAccent(toolsSection, "text")
    yOffset = yOffset - 24


    -- Reset button
    local resetBtn = CreateSQButton(content, "Reset to Defaults", 140, 26, SQ_COLORS.danger)
    resetBtn:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    resetBtn:SetScript("OnClick", function()
        BH.settings.buttonSize = BH.defaultSettings.buttonSize
        BH.settings.buttonSpacing = BH.defaultSettings.buttonSpacing
        BH.settings.frameLocked = BH.defaultSettings.frameLocked
        BH.settings.anchorPoint = BH.defaultSettings.anchorPoint
        BH.settings.growDirection = BH.defaultSettings.growDirection
        BH.settings.layoutDirection = BH.defaultSettings.layoutDirection
        BH.settings.showLabelText = BH.defaultSettings.showLabelText
        BH:ResetFramePosition()
        BH:SaveSettings()
        BH:UpdateFrameLock()
        BH:RefreshSettingsTab()
        BH:UpdateButtons()
    end)
    yOffset = yOffset - 40

    yOffset = yOffset - ns.Rows.Add(content, yOffset, { type = "divider" })
    yOffset = yOffset - ns.Rows.Add(content, yOffset, { type = "header", label = "SHOW IN" })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "text",
        label = "Which content the reminders appear in. Everything the addon shows -- buttons and text reminders alike -- is hidden where these are unticked.",
    })

    for _, ct in ipairs(BH.CONTENT_TYPES) do
        yOffset = yOffset - ns.Rows.Add(content, yOffset, {
            type = "check",
            label = ct.label,
            get = function()
                local t = BH.settings and BH.settings.contentTypes
                if t and t[ct.key] ~= nil then return t[ct.key] end
                return ct.default
            end,
            set = function(v)
                BH.settings.contentTypes = BH.settings.contentTypes or {}
                BH.settings.contentTypes[ct.key] = v
                BH:SaveSettings()
                BH:UpdateButtons()
                BH:UpdateAllReminders()
            end,
        })
    end

    yOffset = yOffset - ns.Rows.Add(content, yOffset, { type = "divider" })
    yOffset = yOffset - ns.Rows.Add(content, yOffset, { type = "header", label = "MISC" })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "check",
        label = "Glow reminder buttons",
        tooltip = "Pulses a highlight around each reminder button while it is showing, so they catch the eye without you having to look at them. Uses the same alert glow the game draws on your action bars.",
        get = function() return BH.settings.glowReminderButtons ~= false end,
        set = function(v)
            BH.settings.glowReminderButtons = v
            BH:SaveSettings()
            BH:UpdateButtons()
        end,
    })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "color",
        label = "Glow colour",
        tooltip = "Colour of the glow around reminder buttons.",
        get = function()
            local c = BH.settings.glowColor or {}
            return c.r or 1.0, c.g or 0.82, c.b or 0.0
        end,
        set = function(r, g, b)
            BH.settings.glowColor = { r = r, g = g, b = b }
            BH:SaveSettings()
            BH:UpdateButtons()
        end,
        disabled = function() return BH.settings.glowReminderButtons == false end,
    })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "check",
        label = "Pulse the glow",
        tooltip = "Fade the glow in and out. Turn this off for a steady ring instead.",
        get = function() return BH.settings.glowPulse ~= false end,
        set = function(v)
            BH.settings.glowPulse = v
            BH:SaveSettings()
            BH:UpdateButtons()
        end,
        disabled = function() return BH.settings.glowReminderButtons == false end,
    })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "slider",
        label = "Pulse speed (seconds)",
        width = 300, min = 0.2, max = 2.0, step = 0.1,
        tooltip = "How long one fade takes. Lower is faster and more urgent.",
        get = function() return BH.settings.glowPulseSpeed or 0.6 end,
        set = function(v)
            BH.settings.glowPulseSpeed = v
            BH:SaveSettings()
            BH:UpdateButtons()
        end,
        disabled = function()
            return BH.settings.glowReminderButtons == false
                or BH.settings.glowPulse == false
        end,
    })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "slider",
        label = "Pulse depth",
        width = 300, min = 0, max = 90, step = 5,
        tooltip = "How far the glow fades at its dimmest. 0 barely dims; higher fades further out.",
        get = function() return math.floor((1 - (BH.settings.glowMinAlpha or 0.35)) * 100) end,
        set = function(v)
            -- Stored as the alpha it dims *to*, shown as how far it fades --
            -- "more depth" reading as a bigger number is the way round a player
            -- expects.
            BH.settings.glowMinAlpha = 1 - (v / 100)
            BH:SaveSettings()
            BH:UpdateButtons()
        end,
        disabled = function()
            return BH.settings.glowReminderButtons == false
                or BH.settings.glowPulse == false
        end,
    })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "check",
        label = "Show minimap button",
        tooltip = "A button on the minimap: left-click for settings, right-click to unlock frames, drag to move it round the edge. The addon is also in Blizzard's addon compartment either way.",
        get = function() return not BH.settings.minimapButtonHidden end,
        set = function(v)
            BH.settings.minimapButtonHidden = not v
            BH:SaveSettings()
            BH:UpdateMinimapButton()
        end,
    })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "check",
        label = "Guild Invite on Right-Click",
        tooltip = "Adds a Guild Invite entry to the right-click menu on player names and unit frames.",
        get = function() return BH.settings.guildInviteContextEnabled == true end,
        set = function(v)
            BH.settings.guildInviteContextEnabled = v
            BH:SaveSettings()
        end,
    })

    -- Set scroll child height
    content:SetHeight(math.abs(yOffset) + 20)
end

-- Get grow direction dropdown items for a layout
function BH:GetGrowItemsForLayout(layout)
    if layout == "VERTICAL" then
        return {
            { text = "Up", value = "UP" },
            { text = "Down", value = "DOWN" },
        }
    else
        return {
            { text = "Left", value = "LEFT" },
            { text = "Right", value = "RIGHT" },
            { text = "Outward", value = "OUTWARD" },
        }
    end
end

-- Auto-correct grow direction when layout changes
function BH:ValidateGrowDirection()
    local layout = self.settings.layoutDirection or "HORIZONTAL"
    local grow = self.settings.growDirection or "RIGHT"
    if layout == "VERTICAL" then
        if grow == "LEFT" or grow == "OUTWARD" then
            self.settings.growDirection = "DOWN"
        elseif grow == "RIGHT" then
            self.settings.growDirection = "DOWN"
        end
    else
        if grow == "UP" then
            self.settings.growDirection = "LEFT"
        elseif grow == "DOWN" then
            self.settings.growDirection = "RIGHT"
        end
    end
end

-- Refresh settings tab values to match current settings
function BH:RefreshSettingsTab()
    if not self.settings then return end
    -- Every option row syncs itself from its own get(). What is left here is
    -- the two profile dropdowns, whose *item lists* change as profiles are
    -- created and deleted, and the unlock button caption.
    ns.Rows.RefreshAll()

    if self.profileDropdown then
        local items = {}
        for _, name in ipairs(self:GetProfileList()) do
            table.insert(items, { text = name, value = name })
        end
        self.profileDropdown:SetItems(items)
        self.profileDropdown:SetSelectedValue(self:GetActiveProfileName())
    end

    if self.specProfileDropdown then
        local specIndex = GetSpecialization()
        local specName = "Current Spec"
        if specIndex then
            local _, name = GetSpecializationInfo(specIndex)
            if name then specName = name end
        end
        local specItems = { { text = "\226\128\148 (use character profile)", value = "" } }
        for _, name in ipairs(self:GetProfileList()) do
            table.insert(specItems, { text = name, value = name })
        end
        self.specProfileDropdown.label:SetText("Profile for " .. specName)
        self.specProfileDropdown:SetItems(specItems)
        self.specProfileDropdown:SetSelectedValue(self:GetSpecProfile() or "")
    end

    if self.unlockBtn then
        self.unlockBtn:SetText(self.unlockMode and "Lock Frames" or "Unlock Frames")
    end
end

-- ============================================================================
-- Raid Tools Settings Tab
-- ============================================================================

function BH:BuildRaidToolsTab(parent)
    -- Six unrelated sections in one scroll had become the problem this page
    -- was, so each is now its own sub-tab. `content` is reassigned at every
    -- boundary below; the row calls themselves are unchanged.
    local pages = ns.SubTabs.Create(parent, {
        { key = "general",  label = "General" },
        { key = "pull",     label = "Pull Timer" },
        { key = "scale",    label = "Scale" },
        { key = "bres",     label = "Battle Res" },
        { key = "distance", label = "Target Distance" },
        { key = "cotank",   label = "Co-Tank" },
        { key = "position", label = "Position" },
    })

    local content = pages.general
    ns.Rows.currentSection = content.section

    local yOffset = -14
    local leftPad = 14

    -- === Module Toggle ===
    local sectionLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sectionLabel:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    sectionLabel:SetText("MODULE")
    ns.ApplyAccent(sectionLabel, "text")
    yOffset = yOffset - 22

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "check",
        label = "Enable Raid Tools",
        tooltip = "Master switch for the raid marker and pull timer frames. Turning this off hides both regardless of their own settings.",
        get = function() return BH.settings.raidToolsEnabled ~= false end,
        set = function(v)
            BH.settings.raidToolsEnabled = v
            BH:SaveSettings()
            BH:UpdateRaidToolsVisibility()
        end,
    })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "text",
        label = "Two movable frames: a compact markers frame (world + target markers) and a pull/ready frame (ready check + pull timer). Only visible when you are the group leader or assistant.",
    })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, { type = "divider" })
    yOffset = yOffset - ns.Rows.Add(content, yOffset, { type = "header", label = "FRAMES" })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "check",
        label = "Show Markers Frame",
        tooltip = "Shows the world marker and target marker buttons. Only usable while you are group leader or an assistant.",
        get = function() return BH.settings.raidToolsShowMarkers ~= false end,
        set = function(v)
            BH.settings.raidToolsShowMarkers = v
            BH:SaveSettings()
            BH:UpdateRaidToolsVisibility()
        end,
        -- Every frame here is gated on the master switch above, so grey them
        -- out rather than letting the player set something with no effect.
        disabled = function() return BH.settings.raidToolsEnabled == false end,
    })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "check",
        label = "Show Pull/Ready Frame",
        tooltip = "Shows the pull timer and ready check buttons. Only usable while you are group leader or an assistant.",
        get = function() return BH.settings.raidToolsShowPullReady ~= false end,
        set = function(v)
            BH.settings.raidToolsShowPullReady = v
            BH:SaveSettings()
            BH:UpdateRaidToolsVisibility()
        end,
        disabled = function() return BH.settings.raidToolsEnabled == false end,
    })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, { type = "divider" })


    -- === Markers Layout ===
    local layoutLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    layoutLabel:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    layoutLabel:SetText("MARKERS LAYOUT")
    ns.ApplyAccent(layoutLabel, "text")
    yOffset = yOffset - 22

    local function GetMarkersGrowItems()
        if BH.settings.raidToolsMarkersLayout == "VERTICAL" then
            return {
                { text = "Down", value = "DOWN" },
                { text = "Up",   value = "UP" },
            }
        end
        return {
            { text = "Left",  value = "LEFT" },
            { text = "Right", value = "RIGHT" },
        }
    end

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "dropdown",
        label = "Layout Direction",
        width = 200,
        tooltip = "Whether the marker buttons lay out in a row or a column.",
        items = {
            { text = "Horizontal", value = "HORIZONTAL" },
            { text = "Vertical",   value = "VERTICAL" },
        },
        get = function() return BH.settings.raidToolsMarkersLayout or "HORIZONTAL" end,
        set = function(v)
            BH.settings.raidToolsMarkersLayout = v
            -- The old grow direction may not exist in the new layout, so reset
            -- it. The grow dropdown below rebuilds its own options from this
            -- value on the refresh that follows.
            BH.settings.raidToolsMarkersGrow = (v == "VERTICAL") and "DOWN" or "LEFT"
            BH:SaveSettings()
            BH:UpdateMarkersLayout()
        end,
        disabled = function() return BH.settings.raidToolsEnabled == false end,
    })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "dropdown",
        label = "Grow Direction",
        width = 200,
        tooltip = "Which way the marker buttons extend from their anchor.",
        -- A function, so the options follow the layout above automatically
        -- instead of the layout dropdown having to reach over and rewrite them.
        items = GetMarkersGrowItems,
        get = function() return BH.settings.raidToolsMarkersGrow or "LEFT" end,
        set = function(v)
            BH.settings.raidToolsMarkersGrow = v
            BH:SaveSettings()
            BH:UpdateMarkersLayout()
        end,
        disabled = function() return BH.settings.raidToolsEnabled == false end,
    })

    -- Sub-tab boundary: size the page just finished, then move to the next.
    content:SetHeight(math.abs(yOffset) + 20)
    content = pages.pull
    ns.Rows.currentSection = content.section
    yOffset = -14

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "slider",
        label = "Countdown Duration (seconds)",
        width = 300, min = 3, max = 30, step = 1,
        tooltip = "How long the pull timer counts down for when you start one.",
        get = function() return BH.settings.raidToolsPullTimer or 10 end,
        set = function(value)
            BH.settings.raidToolsPullTimer = value
            BH:SaveSettings()
            if BH.rtPullBtn and not BH.rtPullActive then
                BH.rtPullBtn.label:SetText("Pull " .. value .. "s")
            end
        end,
        disabled = function() return BH.settings.raidToolsEnabled == false end,
    })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "check",
        label = "Show on encounter timeline",
        tooltip = "Adds the pull countdown to Blizzard's encounter timeline, alongside boss abilities. "
               .. "Works for a pull started by anyone in the group, not just your own button. "
               .. "Needs the encounter timeline itself to be turned on in Blizzard's settings.",
        get = function() return BH.settings.timelinePullTimer ~= false end,
        set = function(v)
            BH.settings.timelinePullTimer = v
            BH:SaveSettings()
            if not v and BH.Timeline then BH.Timeline.Stop("pull") end
        end,
    })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "text",
        indent = 18,
        width = 370,
        label = "The timeline may only draw during an encounter, in which case a pre-pull countdown will not appear.",
    })

    -- Sub-tab boundary: size the page just finished, then move to the next.
    content:SetHeight(math.abs(yOffset) + 20)
    content = pages.scale
    ns.Rows.currentSection = content.section
    yOffset = -14

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "slider",
        label = "Markers Frame Scale",
        width = 300, min = 50, max = 200, step = 5,
        tooltip = "Size of the marker button frame, as a percentage.",
        get = function() return (BH.settings.raidToolsMarkersScale or 1.0) * 100 end,
        set = function(value, userInput)
            BH.settings.raidToolsMarkersScale = value / 100
            BH:SaveSettings()
            if userInput and BH.markersFrame then
                BH.markersFrame:SetScale(value / 100)
            end
        end,
        disabled = function() return BH.settings.raidToolsEnabled == false end,
    })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "slider",
        label = "Pull/Ready Frame Scale",
        width = 300, min = 50, max = 200, step = 5,
        tooltip = "Size of the pull timer and ready check frame, as a percentage.",
        get = function() return (BH.settings.raidToolsPullReadyScale or 1.0) * 100 end,
        set = function(value, userInput)
            BH.settings.raidToolsPullReadyScale = value / 100
            BH:SaveSettings()
            if userInput and BH.pullReadyFrame then
                BH.pullReadyFrame:SetScale(value / 100)
            end
        end,
        disabled = function() return BH.settings.raidToolsEnabled == false end,
    })

    -- Sub-tab boundary: size the page just finished, then move to the next.
    content:SetHeight(math.abs(yOffset) + 20)
    content = pages.bres
    ns.Rows.currentSection = content.section
    yOffset = -14

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "check",
        label = "Enable Battle Res Counter",
        tooltip = "Shows how many battle resurrection charges the group has left. Only appears in content that grants charges.",
        get = function() return BH.settings.bresCounterEnabled and true or false end,
        set = function(v)
            BH.settings.bresCounterEnabled = v
            BH:SaveSettings()
            if not v and BH.bresCounterFrame then
                BH.bresCounterFrame:Hide()
            end
        end,
    })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "slider",
        label = "Battle Res Counter Scale",
        width = 300, min = 50, max = 200, step = 5,
        tooltip = "Size of the battle res counter, as a percentage.",
        get = function() return (BH.settings.bresCounterScale or 1.0) * 100 end,
        set = function(value, userInput)
            BH.settings.bresCounterScale = value / 100
            BH:SaveSettings()
            if userInput and BH.bresCounterFrame then
                BH.bresCounterFrame:SetScale(value / 100)
            end
        end,
        disabled = function() return not BH.settings.bresCounterEnabled end,
    })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "check",
        label = "Lock Battle Res Counter",
        tooltip = "Stops the battle res counter being dragged.",
        get = function() return BH.settings.bresCounterLocked and true or false end,
        set = function(v)
            BH.settings.bresCounterLocked = v
            BH:SaveSettings()
            if BH.bresCounterFrame then
                BH.bresCounterFrame:SetMovable(not v)
                BH.bresCounterFrame:EnableMouse(not v)
            end
        end,
        disabled = function() return not BH.settings.bresCounterEnabled end,
    })

    -- Sub-tab boundary: size the page just finished, then move to the next.
    content:SetHeight(math.abs(yOffset) + 20)
    content = pages.distance
    ns.Rows.currentSection = content.section
    yOffset = -14

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "check",
        label = "Show Target Distance",
        tooltip = "Shows roughly how far away your target is, as movable text. "
            .. "It reads as a band (\"30-35\") rather than a single number because the game gives "
            .. "addons no way to measure distance -- only to ask whether a spell or item would "
            .. "reach. Position it with Unlock Frames.",
        get = function() return BH.settings.targetDistanceEnabled and true or false end,
        set = function(v)
            BH.settings.targetDistanceEnabled = v
            BH:SaveSettings()
            BH:ApplyTargetDistance()
        end,
    })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "dropdown",
        label = "Distance Format",
        width = 160,
        tooltip = "How the estimate reads. The band is the honest one; the other two pick an end of it.",
        items = BH.TARGET_DISTANCE_FORMATS,
        get = function() return BH.settings.targetDistanceFormat or "band" end,
        set = function(value)
            BH.settings.targetDistanceFormat = value
            BH:SaveSettings()
            BH:UpdateTargetDistance()
        end,
        disabled = function() return not BH.settings.targetDistanceEnabled end,
    })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "dropdown",
        label = "Text Align",
        width = 160,
        tooltip = "Alignment of the distance text within its frame.",
        items = BH.TARGET_DISTANCE_ALIGNMENTS,
        get = function() return BH.settings.targetDistanceAlign or "CENTER" end,
        set = function(value)
            BH.settings.targetDistanceAlign = value
            BH:SaveSettings()
            BH:ApplyTargetDistanceStyle()
        end,
        disabled = function() return not BH.settings.targetDistanceEnabled end,
    })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "slider",
        label = "Distance Text Size",
        width = 300, min = 8, max = 48, step = 1,
        tooltip = "Font size of the distance text.",
        get = function() return BH.settings.targetDistanceTextSize or 18 end,
        set = function(value)
            BH.settings.targetDistanceTextSize = value
            BH:SaveSettings()
            BH:ApplyTargetDistanceStyle()
        end,
        disabled = function() return not BH.settings.targetDistanceEnabled end,
    })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "dropdown",
        label = "Frame Strata",
        width = 160,
        tooltip = "How far in front of other frames the distance text sits. Raise it if something covers it.",
        items = BH.TARGET_DISTANCE_STRATAS,
        get = function() return BH.settings.targetDistanceStrata or "HIGH" end,
        set = function(value)
            BH.settings.targetDistanceStrata = value
            BH:SaveSettings()
            BH:ApplyTargetDistanceStyle()
        end,
        disabled = function() return not BH.settings.targetDistanceEnabled end,
    })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "color",
        label = "Distance Text Colour",
        tooltip = "Colour of the distance text.",
        get = function()
            local c = BH.settings.targetDistanceColor or {}
            return c.r or 1, c.g or 1, c.b or 1
        end,
        set = function(r, g, b)
            BH.settings.targetDistanceColor = { r = r, g = g, b = b }
            BH:SaveSettings()
            BH:ApplyTargetDistanceStyle()
        end,
        disabled = function() return not BH.settings.targetDistanceEnabled end,
    })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "check",
        label = "Also Show For Friendly Targets",
        tooltip = "Off by default, and it will often read \"?\" when on. The estimate is built from "
            .. "harmful spells and items, and those refuse to answer about a friendly unit -- so "
            .. "there is frequently nothing to go on.",
        get = function() return BH.settings.targetDistanceFriendly and true or false end,
        set = function(v)
            BH.settings.targetDistanceFriendly = v
            BH:SaveSettings()
            BH:UpdateTargetDistance()
        end,
        disabled = function() return not BH.settings.targetDistanceEnabled end,
    })

    -- Sub-tab boundary: size the page just finished, then move to the next.
    content:SetHeight(math.abs(yOffset) + 20)
    content = pages.cotank
    ns.Rows.currentSection = content.section
    yOffset = -14

    local function coTankOff() return not BH.settings.coTankEnabled end

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "check",
        label = "Show Co-Tank Debuffs",
        tooltip = "A movable frame showing the debuffs on the other tank (or tanks) in your group, "
            .. "with their stack counts. Position it with Unlock Frames.",
        get = function() return BH.settings.coTankEnabled and true or false end,
        set = function(v)
            BH.settings.coTankEnabled = v
            BH:SaveSettings()
            BH:ApplyCoTank()
        end,
    })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "text",
        label = "The game draws these icons itself, which is the only way an addon can show "
            .. "another player's debuffs during a fight. It also decides what may be shown: "
            .. "debuffs cannot be picked out by name on a friendly target, so the filter below "
            .. "is as narrow as it gets. Defensives are the other way round -- those you list "
            .. "yourself.",
    })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "check",
        label = "Preview Layout",
        tooltip = "Shows sample icons so you can size and position everything without a group. "
            .. "These are placeholders, not real auras -- the game will not hand sample data to "
            .. "an addon -- so while preview is on the live display is switched off and the two "
            .. "cannot overlap. Unlock Frames turns this on by itself.",
        get = function() return BH.settings.coTankPreview and true or false end,
        set = function(v)
            BH.settings.coTankPreview = v
            BH:SaveSettings()
            BH:UpdateCoTank()
        end,
        disabled = coTankOff,
    })

    -- ===== FRAME =====
    yOffset = yOffset - ns.Rows.Add(content, yOffset, { type = "divider" })
    yOffset = yOffset - ns.Rows.Add(content, yOffset, { type = "header", label = "FRAME" })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "dropdown", label = "Grow Direction", width = 160,
        tooltip = "Whether extra tanks stack below the first or above it.",
        items = BH.COTANK_GROWTH,
        get = function() return BH.settings.coTankGrowth or "down" end,
        set = function(v) BH.settings.coTankGrowth = v BH:SaveSettings() BH:UpdateCoTank() end,
        disabled = coTankOff,
    })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "slider", label = "Spacing Between Tanks", width = 300, min = 0, max = 40, step = 1,
        tooltip = "Gap between one tank's block of icons and the next tank's.",
        get = function() return BH.settings.coTankRowSpacing or 6 end,
        set = function(v) BH.settings.coTankRowSpacing = v BH:SaveSettings() BH:UpdateCoTank() end,
        disabled = coTankOff,
    })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "check", label = "Show Tank Names",
        tooltip = "Shows each tank's name above their icons.",
        get = function() return BH.settings.coTankShowName ~= false end,
        set = function(v) BH.settings.coTankShowName = v BH:SaveSettings() BH:UpdateCoTank() end,
        disabled = coTankOff,
    })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "slider", label = "Name Text Size", width = 300, min = 6, max = 30, step = 1,
        tooltip = "Font size of the tank names.",
        get = function() return BH.settings.coTankNameSize or 12 end,
        set = function(v) BH.settings.coTankNameSize = v BH:SaveSettings() BH:UpdateCoTank() end,
        disabled = function() return coTankOff() or BH.settings.coTankShowName == false end,
    })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "dropdown", label = "Font", width = 200,
        tooltip = "Font for the names, stack counts and countdowns. The list comes from "
            .. "LibSharedMedia, so anything another addon has registered appears here.",
        items = BH:BuildFontDropdownItems(),
        get = function() return BH.settings.coTankFont or "__default" end,
        set = function(v)
            BH.settings.coTankFont = (v ~= "__default") and v or nil
            BH:SaveSettings()
            BH:UpdateCoTank()
            BH:CoTankNeedsReload()
        end,
        disabled = coTankOff,
    })

    -- ===== VISIBILITY =====
    yOffset = yOffset - ns.Rows.Add(content, yOffset, { type = "divider" })
    yOffset = yOffset - ns.Rows.Add(content, yOffset, { type = "header", label = "VISIBILITY" })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "check", label = "Show in Parties",
        tooltip = "Show in a five-player group as well as in a raid. Unticking makes it raid only.",
        get = function() return BH.settings.coTankShowInParty ~= false end,
        set = function(v) BH.settings.coTankShowInParty = v BH:SaveSettings() BH:UpdateCoTank() end,
        disabled = coTankOff,
    })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "check", label = "Only When I Am Tanking",
        tooltip = "Only show while your own role is set to Tank.",
        get = function() return BH.settings.coTankOnlyIfTank and true or false end,
        set = function(v) BH.settings.coTankOnlyIfTank = v BH:SaveSettings() BH:UpdateCoTank() end,
        disabled = coTankOff,
    })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "check", label = "Warn About Extra Tanks",
        tooltip = "Prints a note in chat when the group has more tanks than there are rows to show "
            .. "them in, so a missing tank is explained rather than simply absent.",
        get = function() return BH.settings.coTankNotify and true or false end,
        set = function(v) BH.settings.coTankNotify = v BH:SaveSettings() end,
        disabled = coTankOff,
    })

    -- ===== ICON LOOK =====
    yOffset = yOffset - ns.Rows.Add(content, yOffset, { type = "divider" })
    yOffset = yOffset - ns.Rows.Add(content, yOffset, { type = "header", label = "ICON LOOK" })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "dropdown", label = "Border By Debuff Type", width = 200,
        tooltip = "Puts a border around each icon coloured by dispel type -- magic, curse, disease, "
            .. "poison. The game picks the colour; this chooses which of its looks to use.",
        items = BH.COTANK_BORDER_STYLES,
        get = function() return BH.settings.coTankBorderStyle or "border" end,
        set = function(v)
            BH.settings.coTankBorderStyle = v
            BH:SaveSettings()
            BH:CoTankNeedsReload()
        end,
        disabled = coTankOff,
    })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "slider", label = "Icon Zoom %", width = 300, min = 0, max = 25, step = 1,
        tooltip = "How much of each icon's art is cropped from the edges.",
        get = function() return BH.settings.coTankIconZoom or 7 end,
        set = function(v)
            BH.settings.coTankIconZoom = v
            BH:SaveSettings() BH:UpdateCoTank() BH:CoTankNeedsReload()
        end,
        disabled = coTankOff,
    })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "check", label = "Show Cooldown Swipe",
        tooltip = "The darkened sweep across each icon as the aura runs down.",
        get = function() return BH.settings.coTankShowSwipe ~= false end,
        set = function(v) BH.settings.coTankShowSwipe = v BH:SaveSettings() BH:CoTankNeedsReload() end,
        disabled = coTankOff,
    })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "check", label = "Show Countdown",
        tooltip = "The remaining time as a number on each icon.",
        get = function()
            return BH.settings.coTankShowCountdown ~= false
        end,
        set = function(v)
            BH.settings.coTankShowCountdown = v
            BH:SaveSettings() BH:UpdateCoTank() BH:CoTankNeedsReload()
        end,
        disabled = coTankOff,
    })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "color", label = "Countdown Colour",
        tooltip = "Colour of the countdown numbers.",
        get = function()
            local c = BH.settings.coTankCountdownColor or {}
            return c.r or 1, c.g or 0.82, c.b or 0
        end,
        set = function(r, g, b)
            BH.settings.coTankCountdownColor = { r = r, g = g, b = b }
            BH:SaveSettings() BH:UpdateCoTank() BH:CoTankNeedsReload()
        end,
        disabled = coTankOff,
    })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "check", label = "Show Stacks",
        tooltip = "The stack count on each icon. This is usually the reason for watching another "
            .. "tank at all.",
        get = function()
            return BH.settings.coTankShowStacks ~= false
        end,
        set = function(v)
            BH.settings.coTankShowStacks = v
            BH:SaveSettings() BH:UpdateCoTank() BH:CoTankNeedsReload()
        end,
        disabled = coTankOff,
    })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "color", label = "Stack Colour",
        tooltip = "Colour of the stack counts.",
        get = function()
            local c = BH.settings.coTankStackColor or {}
            return c.r or 1, c.g or 1, c.b or 1
        end,
        set = function(r, g, b)
            BH.settings.coTankStackColor = { r = r, g = g, b = b }
            BH:SaveSettings() BH:UpdateCoTank() BH:CoTankNeedsReload()
        end,
        disabled = coTankOff,
    })

    -- ===== DEBUFFS =====
    yOffset = yOffset - ns.Rows.Add(content, yOffset, { type = "divider" })
    yOffset = yOffset - ns.Rows.Add(content, yOffset, { type = "header", label = "DEBUFFS" })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "dropdown", label = "Show", width = 200,
        tooltip = "Which of the other tank's debuffs to show. Boss debuffs is usually what you "
            .. "want: it separates tank busters from every minor effect in the room.",
        items = BH.COTANK_DEBUFF_FILTERS,
        get = function() return BH.settings.coTankDebuffFilter or "boss" end,
        set = function(v)
            BH.settings.coTankDebuffFilter = v
            BH:SaveSettings() BH:CoTankNeedsReload()
        end,
        disabled = coTankOff,
    })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "check", label = "Hide Permanent Debuffs",
        tooltip = "Hides auras with no duration, which are almost never what you are watching for.",
        get = function() return BH.settings.coTankDebuffHidePermanent ~= false end,
        set = function(v)
            BH.settings.coTankDebuffHidePermanent = v
            BH:SaveSettings() BH:CoTankNeedsReload()
        end,
        disabled = coTankOff,
    })

    yOffset = yOffset - BH:AddCoTankGroupRows(content, yOffset, "coTankDebuff", coTankOff, 64)

    -- ===== DEFENSIVES =====
    yOffset = yOffset - ns.Rows.Add(content, yOffset, { type = "divider" })
    yOffset = yOffset - ns.Rows.Add(content, yOffset, { type = "header", label = "DEFENSIVES" })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "check", label = "Show Defensives",
        tooltip = "A second row showing the other tank's active defensive cooldowns.",
        get = function() return BH.settings.coTankDefEnabled and true or false end,
        set = function(v)
            BH.settings.coTankDefEnabled = v
            BH:SaveSettings() BH:UpdateCoTank() BH:CoTankNeedsReload()
        end,
        disabled = coTankOff,
    })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "text",
        label = "Buffs on a friendly target CAN be matched by spell ID, unlike debuffs, so this "
            .. "one is a list you write. Enter the spell IDs of the defensives you care about, "
            .. "separated by spaces or commas. Left empty nothing is shown, because every buff a "
            .. "tank happens to have would be noise rather than a defensives tracker.",
    })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "editbox", label = "Defensive Spell IDs", width = 320,
        tooltip = "For example: 871 1160 12975 -- Shield Wall, Demoralizing Shout, Last Stand.",
        get = function() return BH.settings.coTankDefSpellIDs or "" end,
        set = function(v)
            BH.settings.coTankDefSpellIDs = v
            BH:SaveSettings() BH:CoTankNeedsReload()
        end,
        disabled = function() return coTankOff() or not BH.settings.coTankDefEnabled end,
    })

    yOffset = yOffset - BH:AddCoTankGroupRows(content, yOffset, "coTankDef",
        function() return coTankOff() or not BH.settings.coTankDefEnabled end, 48)

    -- Sub-tab boundary: size the page just finished, then move to the next.
    content:SetHeight(math.abs(yOffset) + 20)
    content = pages.position
    ns.Rows.currentSection = content.section
    yOffset = -14

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "check",
        label = "Lock Markers Frame",
        tooltip = "Stops the marker frame being dragged.",
        get = function() return BH.settings.raidToolsMarkersLocked and true or false end,
        set = function(v)
            BH.settings.raidToolsMarkersLocked = v
            BH:SaveSettings()
            if BH.markersFrame then
                BH.markersFrame:SetMovable(not v)
            end
            if BH.markersDragHandle then
                if v then BH.markersDragHandle:Hide() else BH.markersDragHandle:Show() end
            end
        end,
        disabled = function() return BH.settings.raidToolsEnabled == false end,
    })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "check",
        label = "Lock Pull/Ready Frame",
        tooltip = "Stops the pull timer frame being dragged.",
        get = function() return BH.settings.raidToolsPullReadyLocked and true or false end,
        set = function(v)
            BH.settings.raidToolsPullReadyLocked = v
            BH:SaveSettings()
            if BH.pullReadyFrame then
                BH.pullReadyFrame:SetMovable(not v)
            end
            if BH.pullReadyDragHandle then
                if v then BH.pullReadyDragHandle:Hide() else BH.pullReadyDragHandle:Show() end
            end
        end,
        disabled = function() return BH.settings.raidToolsEnabled == false end,
    })


    local resetBtn = CreateSQButton(content, "Reset Positions", 140, 26)
    resetBtn:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    resetBtn:SetScript("OnClick", function()
        if BH.markersFrame then
            BH.markersFrame:ClearAllPoints()
            BH.markersFrame:SetPoint("BOTTOMRIGHT", UIParent, "CENTER", 0, 0)
        end
        if BH.pullReadyFrame then
            BH.pullReadyFrame:ClearAllPoints()
            BH.pullReadyFrame:SetPoint("RIGHT", BH.markersFrame, "LEFT", -2, 0)
        end
        if SquizzumablesDB then
            SquizzumablesDB.markersPosition = nil
            SquizzumablesDB.pullReadyPosition = nil
            SquizzumablesDB.beaconReminderPosition = nil
            SquizzumablesDB.earthShieldReminderPosition = nil
            SquizzumablesDB.repairReminderPosition = nil
            SquizzumablesDB.symbioticReminderPosition = nil
            SquizzumablesDB.bresCounterPosition = nil
            SquizzumablesDB.deathTallyPosition = nil
            SquizzumablesDB.coachWhistleReminderPosition = nil
            SquizzumablesDB.bagsReminderPosition = nil
        end
        if BH.beaconReminderFrame then
            BH.beaconReminderFrame:ClearAllPoints()
            BH.beaconReminderFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 200)
        end
        if BH.earthShieldReminderFrame then
            BH.earthShieldReminderFrame:ClearAllPoints()
            BH.earthShieldReminderFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 160)
        end
        if BH.repairReminderFrame then
            BH.repairReminderFrame:ClearAllPoints()
            BH.repairReminderFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 120)
        end
        if BH.symbioticReminderFrame then
            BH.symbioticReminderFrame:ClearAllPoints()
            BH.symbioticReminderFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 80)
        end
        if BH.coachWhistleReminderFrame then
            BH.coachWhistleReminderFrame:ClearAllPoints()
            BH.coachWhistleReminderFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
        end
        if BH.bresCounterFrame then
            BH.bresCounterFrame:ClearAllPoints()
            BH.bresCounterFrame:SetPoint("TOP", UIParent, "TOP", 0, -100)
        end
        if BH.deathTallyFrame then
            BH.deathTallyFrame:ClearAllPoints()
            BH.deathTallyFrame:SetPoint("TOP", UIParent, "TOP", 220, -100)
        end
        if BH.bagsReminderFrame then
            BH.bagsReminderFrame:ClearAllPoints()
            BH.bagsReminderFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 240)
        end
        if BH.healerCCReminderFrame then
            BH.healerCCReminderFrame:ClearAllPoints()
            BH.healerCCReminderFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 360)
        end
        -- Reset CDM group positions
        if BH.cdm and BH.cdm.ResetPositions then
            BH.cdm:ResetPositions()
        end
    end)
    yOffset = yOffset - 40

    content:SetHeight(math.abs(yOffset) + 20)
    ns.Rows.currentSection = nil
end

-- Kept as a thin shim: the Raid Tools rows are declarative now, so each one
-- syncs itself from its own get(). The five call sites elsewhere just want
-- "make the panel match the settings", which RefreshAll does for every tab
-- at once.
function BH:RefreshRaidToolsTab()
    ns.Rows.RefreshAll()
end

-- ============================================================================
-- LibSharedMedia-3.0 helper (optional -- gracefully absent if LSM not loaded)
-- ============================================================================

local CUSTOM_SOUNDS_PATH = "Interface\\AddOns\\Squizzumables\\Media\\Sounds\\"

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

-- Public wrapper so other files (e.g. Squizzumables_SpellAlerts.lua) can play sounds.
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
            lsm:Register("sound", entry.name, CUSTOM_SOUNDS_PATH .. entry.file)
        end
    end
end

-- ============================================================================
-- Role CC Alert
-- ============================================================================
-- Role CC alert.
--
-- Tracks group members in the watched roles and raises one alert when any of
-- them is crowd-controlled. Healer tracking has always been here; tank tracking
-- was added in 1.60 by requests.
--
-- Deliberately one frame with per-role toggles rather than one frame per role:
-- a second frame would mean another scale slider, another lock checkbox and
-- another saved position in the addon's most crowded settings tab, for an alert
-- you will almost never see both halves of at once. The label names whichever
-- role is actually CC'd instead.
--
-- Settings keys are unchanged so existing profiles keep working:
--   healerCCAlertEnabled    healer tracking (long-standing key, kept as-is)
--   roleCCAlertTank         tank tracking (new, defaults off)
--   healerCCAlertSound      shared alert sound
--   healerCCReminder*       the shared frame's lock / scale / position
local roleWatchUnits = {}  -- unit token → "HEALER" or "TANK"
local roleCCActive   = {}  -- unit token → true while that unit has a CC debuff

local function UnitHasCCDebuff(unit)
    -- Guard: unit must exist, be connected, and still be a valid group member.
    -- When a member zones into an instance or goes out of range, UNIT_AURA
    -- fires during the transition but the unit is no longer reachable —
    -- reading auras in that window returns stale or garbage data and can
    -- trigger a false alert.
    if not unit or not UnitExists(unit) then return false end
    if not UnitIsConnected(unit) then return false end
    -- As of 12.1.0, GetAuraDataByIndex throws a taint error when auras are
    -- secret (in combat, encounters, M+, PvP) instead of returning nil — the
    -- exact scenario this alert needs to work in. BH.Secrets.ForEachAura absorbs
    -- that; a failed read is treated as "no CC". We only need to know whether
    -- *any* crowd-control debuff is present, so the scan stops at the first one.
    local hasCC = false
    BH.Secrets.ForEachAura(unit, "HARMFUL|CROWD_CONTROL", function()
        hasCC = true
        return true
    end)
    return hasCC
end

-- Which roles are currently being watched, per the settings.
local function WatchedRoles()
    local s = BH.settings
    return (s and s.healerCCAlertEnabled) and true or false,
           (s and s.roleCCAlertTank) and true or false
end

function BH:RefreshRoleCCWatchList()
    wipe(roleWatchUnits)
    wipe(roleCCActive)
    local watchHealer, watchTank = WatchedRoles()
    if not (watchHealer or watchTank) then return end
    if not IsInGroup() then return end
    local isRaid = IsInRaid()
    local count  = GetNumGroupMembers()
    for i = 1, count do
        local unit = (isRaid and "raid" or "party") .. i
        -- Only track members who exist AND are connected (not phased out, not
        -- in a different instance/zone). This prevents the alert from firing on
        -- stale aura data during zone transitions.
        if UnitExists(unit) and not UnitIsUnit(unit, "player")
            and UnitIsConnected(unit)
        then
            local role = UnitGroupRolesAssigned(unit)
            if (role == "HEALER" and watchHealer) or (role == "TANK" and watchTank) then
                roleWatchUnits[unit] = role
            end
        end
    end
end

-- Which watched roles currently have at least one CC'd member.
local function ActiveCCRoles()
    local healer, tank = false, false
    for u, role in pairs(roleWatchUnits) do
        if roleCCActive[u] then
            if role == "HEALER" then healer = true
            elseif role == "TANK" then tank = true end
        end
    end
    return healer, tank
end

-- Show or hide the shared frame, labelling whichever roles are CC'd.
--
-- Unlock mode has to be handled here rather than only by the caller: this runs
-- whenever a role toggle changes, so without the preview branch, ticking a role
-- box while previewing would immediately hide the frame the player is trying to
-- position.
function BH:UpdateRoleCCFrame()
    local frame = self.healerCCReminderFrame
    if not frame then return end

    local watchHealer, watchTank = WatchedRoles()
    local healer, tank

    if self.unlockMode then
        -- Show the frame for positioning if either role is watched, labelled
        -- with the roles being watched rather than the (empty) live CC state.
        if not (watchHealer or watchTank) then
            frame:Hide()
            return
        end
        healer, tank = watchHealer, watchTank
    else
        healer, tank = ActiveCCRoles()
        if not (healer or tank) then
            frame:Hide()
            return
        end
    end

    local label
    if healer and tank then label = "HEALER + TANK IN CC"
    elseif healer        then label = "HEALER IN CC"
    else                      label = "TANK IN CC" end
    if self.healerCCReminderText then self.healerCCReminderText:SetText(label) end
    local locked = self.settings and self.settings.healerCCReminderLocked
    frame:EnableMouse(BH:ReminderMouseEnabled(locked))
    frame:Show()
end

function BH:CheckRoleCC(unit)
    local watchHealer, watchTank = WatchedRoles()
    if not (watchHealer or watchTank) then
        if self.healerCCReminderFrame then self.healerCCReminderFrame:Hide() end
        return
    end
    if not unit or not roleWatchUnits[unit] then return end

    -- Skip units that are offline, out of range, or in a different zone/
    -- instance. UnitIsConnected returns false when the player has disconnected
    -- or phased out; UnitExists returns false when the unit token is no longer
    -- valid. Checking both prevents false positives during zone transitions
    -- where UNIT_AURA fires with stale data.
    if not UnitExists(unit) or not UnitIsConnected(unit) then
        -- Clear any lingering CC state for this unit so the alert frame doesn't
        -- stay visible from a previous real CC that was never cleared (the
        -- member zoned out before the CC wore off).
        if roleCCActive[unit] then
            roleCCActive[unit] = nil
            self:UpdateRoleCCFrame()
        end
        return
    end

    local hasCC = UnitHasCCDebuff(unit)
    local hadCC = roleCCActive[unit]
    roleCCActive[unit] = hasCC or nil
    if hasCC and not hadCC then
        PlaySQSound(self.settings.healerCCAlertSound or "None")
    end
    self:UpdateRoleCCFrame()
end

-- Show or hide the Just For Kel alert image for positioning while frames are
-- unlocked. It is normally only visible for a few seconds when an alert fires,
-- so without this it is the one frame Unlock Frames could not reach.
-- Single entry point for Unlock Frames, used by the Settings button, /sq unlock
-- and the Close button on the floating control. Having one path is what stops
-- the three of them drifting: each has to hide the panel, refresh six different
-- frame groups and keep the button label in sync.
function BH:SetUnlockMode(on)
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

    if on then
        -- Get the options panel out of the way. It is 820 wide and will usually
        -- be sitting on top of the frames being positioned. Remember whether it
        -- was open so it can be put back when frames are locked again.
        self.unlockReopenPanel = (self.optionsPanel and self.optionsPanel:IsShown()) and true or false
        if self.optionsPanel then self.optionsPanel:Hide() end
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
        print("Squizzumables: frames unlocked - drag them into place, then click Done or use /sq unlock.")
    else
        print("Squizzumables: frames locked.")
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
        -- Give it a labelled placeholder so there is something to aim at.
        if not f.unlockPlaceholder then
            local ph = CreateFrame("Frame", nil, f, "BackdropTemplate")
            ph:SetAllPoints()
            ph:SetBackdrop({
                bgFile   = "Interface\\BUTTONS\\WHITE8X8",
                edgeFile = "Interface\\BUTTONS\\WHITE8X8",
                edgeSize = 1,
            })
            ph:SetBackdropColor(0, 0, 0, 0.55)
            local r, g, b = ns.GetAccentColor()
            ph:SetBackdropBorderColor(r, g, b, 0.9)
            local phText = ph:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            phText:SetPoint("CENTER")
            phText:SetText("Just For Kel\nalert image")
            phText:SetJustifyH("CENTER")
            ns.ApplyAccent(phText, "text")
            f.unlockPlaceholder = ph
        end
        f.unlockPlaceholder:Show()
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
        if f.unlockPlaceholder then f.unlockPlaceholder:Hide() end
        -- Always click-through outside Unlock Frames. See EnsureAlertFrame for
        -- why the old per-frame lock setting is not consulted any more.
        f:EnableMouse(false)
        f:Hide()
    end
end

-- Any watched member currently CC'd? Used by the preview/refresh path.
function BH:AnyRoleCCActive()
    local healer, tank = ActiveCCRoles()
    return healer or tank
end

-- ============================================================================
-- Text Reminders Settings Tab
-- ============================================================================

-- Build one reminder's block of options from its BH.REMINDERS entry: section
-- header, enable toggle, any reminder-specific rows, scale, lock, divider.
-- Returns the vertical space used.
--
-- The scale and lock rows grey out when the reminder is disabled -- something
-- the hand-written version had no mechanism for.
function BH:AddReminderSection(content, y, key, skipDivider)
    local def = BH.REMINDERS_BY_KEY[key]
    if not def then return 0 end

    local Rows       = ns.Rows
    local enabledKey = def.enabledKey or (key .. "ReminderEnabled")
    local scaleKey   = key .. "ReminderScale"
    local lockedKey  = key .. "ReminderLocked"
    local frameKey   = key .. "ReminderFrame"
    local updateFn   = "Update" .. BH.ReminderBaseName(key) .. "Reminder"

    local function isOff() return BH.settings and BH.settings[enabledKey] == false end
    local function runUpdate() if BH[updateFn] then BH[updateFn](BH) end end

    local rows = {
        { type = "header", label = def.sectionHeader, tooltip = def.tooltip },
        { type = "check",  label = def.enableLabel,   tooltip = def.tooltip,
          get = function() return BH.settings and BH.settings[enabledKey] ~= false end,
          set = function(v) BH.settings[enabledKey] = v; BH:SaveSettings() end,
          after = runUpdate },
    }

    -- Reminder-specific rows sit between the enable toggle and the scale.
    if def.extraRows then
        for _, extra in ipairs(def.extraRows) do rows[#rows + 1] = extra end
    end

    rows[#rows + 1] = {
        type = "slider", label = def.scaleLabel, width = 300, min = 50, max = 200, step = 5,
        tooltip = "Size of the on-screen reminder, as a percentage.",
        disabled = isOff,
        get = function() return (BH.settings and BH.settings[scaleKey] or 1.0) * 100 end,
        set = function(v, userInput)
            BH.settings[scaleKey] = v / 100
            BH:SaveSettings()
            local f = BH[frameKey]
            if userInput and f then f:SetScale(v / 100) end
        end,
    }
    rows[#rows + 1] = {
        type = "check", label = def.lockLabel,
        tooltip = "Stops the reminder being dragged. Use Preview on the Settings tab to reposition it.",
        disabled = isOff,
        get = function() return BH.settings and BH.settings[lockedKey] or false end,
        set = function(v)
            BH.settings[lockedKey] = v
            BH:SaveSettings()
            local f = BH[frameKey]
            if f then f:SetMovable(not v); f:EnableMouse(not v) end
        end,
    }
    -- The section that ends a group omits its trailing divider, because the
    -- next block (Instance Sounds, Feast Announce) opens with its own.
    if not skipDivider then
        rows[#rows + 1] = { type = "divider" }
    end

    return Rows.AddAll(content, y, rows)
end

function BH:BuildTextRemindersTab(parent)
    -- Split by what the reminder is about rather than one long scroll. The
    -- dividers and section headings that used to separate these are gone: the
    -- sub-tab label says the same thing, and keeping both would name every
    -- section twice.
    local pages = ns.SubTabs.Create(parent, {
        { key = "class",  label = "Class" },
        { key = "sounds", label = "Instance Sounds" },
        { key = "bags",   label = "Bags" },
        { key = "feast",  label = "Feast" },
        { key = "cc",     label = "Role CC" },
    })

    local content = pages.class
    ns.Rows.currentSection = content.section

    local yOffset = -14
    local leftPad = 14

    -- The per-reminder sections are generated from BH.REMINDERS. Each was ~45
    -- lines of hand-positioned widgets plus a matching branch in
    -- BH:RefreshTextRemindersTab; the rows now carry their own get/set and
    -- refresh themselves, so both disappear.
    local classReminders = { "beacon", "earthShield", "symbiotic", "repair" }
    for i, key in ipairs(classReminders) do
        yOffset = yOffset - self:AddReminderSection(content, yOffset, key, i == #classReminders)
    end

    -- Sub-tab boundary.
    content:SetHeight(math.abs(yOffset) + 20)
    content = pages.sounds
    ns.Rows.currentSection = content.section
    yOffset = -14

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "check",
        label = "Play Sound on Skyreach (Mythic)",
        tooltip = "Plays a sound when you enter The Everbloom on Mythic difficulty, as a reminder about the Skyreach affix pull.",
        get = function() return BH.settings.skyreachSoundEnabled and true or false end,
        set = function(v)
            BH.settings.skyreachSoundEnabled = v
            BH:SaveSettings()
        end,
    })

    -- Sub-tab boundary.
    content:SetHeight(math.abs(yOffset) + 20)
    content = pages.bags
    ns.Rows.currentSection = content.section
    yOffset = -14

    local consumNote = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    consumNote:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    consumNote:SetWidth(380)
    consumNote:SetJustifyH("LEFT")
    consumNote:SetText("One reminder naming whichever of these you have none of, plus a separate healthstone reminder. Untick a category to stop it being mentioned.")
    consumNote:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])
    yOffset = yOffset - 28

    -- One section for the combined frame (enable / scale / lock / position),
    -- then the per-category watch toggles that decide what it can mention.
    yOffset = yOffset - self:AddReminderSection(content, yOffset, "bags", true)

    for _, cat in ipairs({
        { key = "food",        label = "Watch food" },
        { key = "flask",       label = "Watch flasks" },
        { key = "oil",         label = "Watch weapon oils" },
        { key = "augmentRune", label = "Watch augment runes" },
    }) do
        yOffset = yOffset - ns.Rows.Add(content, yOffset, {
            type = "check",
            indent = 28,
            label = cat.label,
            tooltip = "Include this in the bag reminder when you have none of it.",
            get = function() return BH.settings[cat.key .. "ReminderEnabled"] ~= false end,
            set = function(v)
                BH.settings[cat.key .. "ReminderEnabled"] = v
                BH:SaveSettings()
                BH:UpdateBagReminder()
            end,
            disabled = function() return BH.settings.bagsReminderEnabled == false end,
        })
    end

    yOffset = yOffset - self:AddReminderSection(content, yOffset, "healthstone", true)

    -- === Feast Announce ===
    -- Sub-tab boundary.
    content:SetHeight(math.abs(yOffset) + 20)
    content = pages.feast
    ns.Rows.currentSection = content.section
    yOffset = -14

    local feastNote = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    feastNote:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    feastNote:SetWidth(380)
    feastNote:SetJustifyH("LEFT")
    feastNote:SetText("Announces in group chat when you or anyone in the party places a feast. Custom message applies to your own feasts; party feasts use the caster's name.")
    feastNote:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])
    yOffset = yOffset - 28

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "check",
        label = "Enable Feast Announce",
        tooltip = "Announces to chat when you drop a feast, and alerts other Squizzumables users in your group with a sound.",
        get = function() return BH.settings.feastAnnounceEnabled ~= false end,
        set = function(v)
            BH.settings.feastAnnounceEnabled = v
            BH:SaveSettings()
        end,
    })

    -- Per-context channel grid (Solo / In Party / In Instance / In Raid)
    local feastChanTitle = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    feastChanTitle:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    feastChanTitle:SetText("Channel")
    feastChanTitle:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])
    yOffset = yOffset - 22

    local feastChanItems = {
        { text = "None",         value = "NONE"          },
        { text = "Party",        value = "PARTY"         },
        { text = "Instance",     value = "INSTANCE_CHAT" },
        { text = "Raid",         value = "RAID"          },
        { text = "Raid Warning", value = "RAID_WARNING"  },
        { text = "Say",          value = "SAY"           },
        { text = "Yell",         value = "YELL"          },
    }

    local colW = 96
    local ddW  = 90
    local contexts = {
        { label = "Solo",        key = "solo",     col = 0 },
        { label = "In Party",    key = "party",    col = 1 },
        { label = "In Instance", key = "instance", col = 2 },
        { label = "In Raid",     key = "raid",     col = 3 },
    }
    self.trFeastChannelDDs = {}
    for _, ctx in ipairs(contexts) do
        local lbl = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        lbl:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad + ctx.col * colW, yOffset)
        lbl:SetText(ctx.label)
        lbl:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])
    end
    yOffset = yOffset - 20
    for _, ctx in ipairs(contexts) do
        local dd = CreateSQDropdown(content, "", ddW, feastChanItems, function(value)
            if type(BH.settings.feastAnnounceChannel) ~= "table" then
                BH.settings.feastAnnounceChannel = CopyTable(BH.defaultSettings.feastAnnounceChannel)
            end
            BH.settings.feastAnnounceChannel[ctx.key] = value
            BH:SaveSettings()
        end)
        local chanDB = BH.settings and type(BH.settings.feastAnnounceChannel) == "table"
            and BH.settings.feastAnnounceChannel
            or BH.defaultSettings.feastAnnounceChannel
        dd:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad + ctx.col * colW, yOffset + 2)
        dd:SetSelectedValue(chanDB[ctx.key] or "NONE")
        self.trFeastChannelDDs[ctx.key] = dd
        ns.Rows.AddTooltip(dd, "Feast channel: " .. ctx.label, "Which chat channel the feast announcement goes to when you are " .. ctx.label:lower() .. ". Set to None to stay silent in that situation.")
    end
    yOffset = yOffset - 30

    local feastTextLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    feastTextLabel:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    feastTextLabel:SetText("Your feast message (leave blank for default):")
    feastTextLabel:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])
    yOffset = yOffset - 20

    local feastTextEdit = CreateSQEditBox(content, 360, 20, { maxLetters = 255 })
    feastTextEdit:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    feastTextEdit:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    feastTextEdit.placeholder = feastTextEdit:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    -- 6 to match the widget's text inset for a box this wide, so the
    -- placeholder sits exactly where the real text will.
    feastTextEdit.placeholder:SetPoint("LEFT", feastTextEdit, "LEFT", 6, 0)
    feastTextEdit.placeholder:SetText("Fresh off the barbie, no crocs were harmed\226\128\166")
    feastTextEdit.placeholder:SetTextColor(0.4, 0.4, 0.4)
    feastTextEdit:SetScript("OnTextChanged", function(self)
        feastTextEdit.placeholder:SetShown(self:GetText() == "")
        BH.settings.feastAnnounceText = self:GetText()
        BH:SaveSettings()
    end)
    feastTextEdit:SetScript("OnShow", function(self)
        feastTextEdit.placeholder:SetShown(self:GetText() == "")
    end)
    self.trFeastAnnounceTextEdit = feastTextEdit
    yOffset = yOffset - 34

    local feastTokenNote = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    feastTokenNote:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    feastTokenNote:SetWidth(380)
    feastTokenNote:SetJustifyH("LEFT")
    feastTokenNote:SetText("|cffffffffToken: {feast} = feast name.|r")
    feastTokenNote:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])
    yOffset = yOffset - 30

    -- Sound alert when another Squizzumables user places a feast
    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "sound",
        label = "Alert sound (plays when a feast is placed)",
        tooltip = "Sound played to you and to other Squizzumables users in the group when a feast is dropped.",
        get = function() return BH.settings.feastAlertSound or "None" end,
        set = function(value)
            BH.settings.feastAlertSound = value
            BH:SaveSettings()
        end,
        disabled = function() return BH.settings.feastAnnounceEnabled == false end,
    })

    -- === Healer CC Alert ===
    -- Sub-tab boundary.
    content:SetHeight(math.abs(yOffset) + 20)
    content = pages.cc
    ns.Rows.currentSection = content.section
    yOffset = -14
    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "text",
        label = "Plays a sound and shows an alert when a watched party or raid member is crowd controlled. Pick which roles to watch.",
    })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "check",
        label = "Alert when healer is CC'd",
        tooltip = "Watch group healers and raise the alert when one is crowd controlled.",
        get = function() return BH.settings.healerCCAlertEnabled == true end,
        set = function(v)
            BH.settings.healerCCAlertEnabled = v
            BH:SaveSettings()
            BH:RefreshRoleCCWatchList()
            BH:UpdateRoleCCFrame()
        end,
    })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "check",
        label = "Alert when tank is CC'd",
        tooltip = "Watch group tanks and raise the alert when one is crowd controlled. Shares the frame and sound with the healer alert; the label names whichever role is affected.",
        get = function() return BH.settings.roleCCAlertTank == true end,
        set = function(v)
            BH.settings.roleCCAlertTank = v
            BH:SaveSettings()
            BH:RefreshRoleCCWatchList()
            BH:UpdateRoleCCFrame()
        end,
    })

    -- Everything below only matters once at least one role is being watched.
    local function noRoleWatched()
        return not (BH.settings.healerCCAlertEnabled or BH.settings.roleCCAlertTank)
    end

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "check",
        label = "Lock Position",
        tooltip = "Stops the role CC alert being dragged.",
        get = function() return BH.settings.healerCCReminderLocked == true end,
        set = function(v)
            BH.settings.healerCCReminderLocked = v
            BH:SaveSettings()
            if BH.healerCCReminderFrame then
                BH.healerCCReminderFrame:SetMovable(not v)
                BH.healerCCReminderFrame:EnableMouse(BH:ReminderMouseEnabled(v))
            end
        end,
        disabled = noRoleWatched,
    })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "slider",
        label = "Scale",
        width = 200, min = 50, max = 200, step = 5,
        tooltip = "Size of the role CC alert, as a percentage.",
        get = function() return (BH.settings.healerCCReminderScale or 1.0) * 100 end,
        set = function(val)
            BH.settings.healerCCReminderScale = val / 100
            BH:SaveSettings()
            if BH.healerCCReminderFrame then BH.healerCCReminderFrame:SetScale(val / 100) end
        end,
        disabled = noRoleWatched,
    })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "sound",
        label = "Alert sound",
        tooltip = "Sound played when a watched healer or tank is crowd controlled.",
        get = function() return BH.settings.healerCCAlertSound or "None" end,
        set = function(value)
            BH.settings.healerCCAlertSound = value
            BH:SaveSettings()
        end,
        disabled = noRoleWatched,
    })

    content:SetHeight(math.abs(yOffset) + 20)
    ns.Rows.currentSection = nil
end

function BH:RefreshCustomSoundsList()
    if not self.customSoundsListFrame then return end

    -- Rows are cached by list position and refilled; removing an entry shifts
    -- everything up by one, so the labels and the remove handler are re-set on
    -- every pass. Only a longer list than we have ever shown allocates.
    self:ResetWidgetCache("customSoundRowCache")

    local sounds = self.settings and self.settings.customSounds or {}
    local rowY = 0
    for i, entry in ipairs(sounds) do
        local rowFrame, isNew = self:AcquireWidget("customSoundRowCache", i, function()
            local f = CreateFrame("Frame", nil, self.customSoundsListFrame)
            f:SetSize(380, 22)

            f.nameLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            f.nameLabel:SetPoint("LEFT", f, "LEFT", 0, 0)
            f.nameLabel:SetWidth(140)
            f.nameLabel:SetJustifyH("LEFT")
            f.nameLabel:SetTextColor(SQ_COLORS.text[1], SQ_COLORS.text[2], SQ_COLORS.text[3])

            f.fileLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            f.fileLabel:SetPoint("LEFT", f, "LEFT", 148, 0)
            f.fileLabel:SetWidth(180)
            f.fileLabel:SetJustifyH("LEFT")
            f.fileLabel:SetTextColor(0.5, 0.5, 0.5)

            f.removeBtn = CreateSQButton(f, "X", 22, 18, SQ_COLORS.danger)
            f.removeBtn:SetPoint("LEFT", f, "LEFT", 334, 0)
            return f
        end)
        local _ = isNew

        rowFrame:Show()
        rowFrame:SetPoint("TOPLEFT", self.customSoundsListFrame, "TOPLEFT", 0, rowY)
        rowFrame.nameLabel:SetText(entry.name or "")
        rowFrame.fileLabel:SetText(entry.file or "")

        local idx = i
        rowFrame.removeBtn:SetScript("OnClick", function()
            table.remove(self.settings.customSounds, idx)
            self:SaveSettings()
            self:RefreshCustomSoundsList()
            -- Rebuild Items tab so dropdowns reflect removal
            if self.scrollChild then self:RefreshItemList() end
        end)

        rowY = rowY - 24
    end
    self.customSoundsListFrame:SetHeight(math.abs(rowY) + 4)
end

-- ============================================================================
-- Sounds Tab
-- ============================================================================

function BH:BuildSoundsTab(parent)
    local leftPad = 14

    local scrollFrame = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    scrollFrame:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -22, 0)

    local content = CreateFrame("Frame", nil, scrollFrame)
    content:SetSize(430, 1)
    scrollFrame:SetScrollChild(content)

    local yOffset = -10

    -- === Bundled Sounds ===
    local bundledTitle = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    bundledTitle:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    bundledTitle:SetText("BUNDLED SOUNDS")
    ns.ApplyAccent(bundledTitle, "text")
    yOffset = yOffset - 18

    for _, entry in ipairs(SQ_BUNDLED_SOUNDS) do
        local rowFrame = CreateFrame("Frame", nil, content)
        rowFrame:SetSize(410, 22)
        rowFrame:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)

        local nameLabel = rowFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        nameLabel:SetPoint("LEFT", rowFrame, "LEFT", 0, 0)
        nameLabel:SetWidth(280)
        nameLabel:SetJustifyH("LEFT")
        nameLabel:SetText(entry.name)
        nameLabel:SetTextColor(SQ_COLORS.text[1], SQ_COLORS.text[2], SQ_COLORS.text[3])

        local unlockBtn = CreateFrame("Button", nil, rowFrame)
        unlockBtn:SetSize(22, 22)
        unlockBtn:SetPoint("LEFT", rowFrame, "LEFT", 286, 0)
        local pNorm = unlockBtn:CreateTexture(nil, "BACKGROUND")
        pNorm:SetAllPoints()
        pNorm:SetTexture("Interface\\Common\\VoiceChat-Speaker")
        local pHi = unlockBtn:CreateTexture(nil, "HIGHLIGHT")
        pHi:SetAllPoints()
        pHi:SetTexture("Interface\\Common\\VoiceChat-Speaker")
        pHi:SetAlpha(0.6)
        unlockBtn:SetScript("OnEnter", function() pNorm:SetAlpha(0.7) end)
        unlockBtn:SetScript("OnLeave", function() pNorm:SetAlpha(1.0) end)
        local soundFile = entry.file
        unlockBtn:SetScript("OnClick", function()
            PlaySoundFile(CUSTOM_SOUNDS_PATH .. soundFile, "Master")
        end)

        yOffset = yOffset - 26
    end

    -- === Custom Sounds ===
    yOffset = yOffset - 6
    local csDivider = CreateSQDivider(content, yOffset)
    csDivider:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    yOffset = yOffset - 18

    local csTitle = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    csTitle:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    csTitle:SetText("CUSTOM SOUNDS")
    ns.ApplyAccent(csTitle, "text")
    yOffset = yOffset - 18

    local csHint = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    csHint:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    csHint:SetWidth(400)
    csHint:SetJustifyH("LEFT")
    csHint:SetWordWrap(true)
    csHint:SetText("Place .ogg files in: |cFFFFFF00Interface\\AddOns\\Squizzumables\\Media\\Sounds\\|r then enter the display name and filename below.")
    csHint:SetTextColor(0.55, 0.55, 0.55)
    yOffset = yOffset - 34

    -- Column headers
    local csNameHdr = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    csNameHdr:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    csNameHdr:SetText("Display Name")
    csNameHdr:SetTextColor(0.6, 0.6, 0.6)

    local csFileHdr = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    csFileHdr:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad + 160, yOffset)
    csFileHdr:SetText("Filename")
    csFileHdr:SetTextColor(0.6, 0.6, 0.6)
    yOffset = yOffset - 18

    -- Dynamic list of user sounds
    local csListFrame = CreateFrame("Frame", nil, content)
    csListFrame:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    csListFrame:SetSize(410, 4)
    self.customSoundsListFrame = csListFrame
    self:RefreshCustomSoundsList()
    yOffset = yOffset - 8

    -- Add row: name input + file input + Add button
    local csNameEdit = CreateSQEditBox(content, 150, 20, { maxLetters = 64 })
    csNameEdit:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    csNameEdit:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    csNameEdit.placeholder = csNameEdit:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    csNameEdit.placeholder:SetPoint("LEFT", csNameEdit, "LEFT", 6, 0)
    csNameEdit.placeholder:SetText("e.g. My Alert")
    csNameEdit.placeholder:SetTextColor(0.4, 0.4, 0.4)
    csNameEdit:SetScript("OnTextChanged", function(self)
        csNameEdit.placeholder:SetShown(self:GetText() == "")
    end)
    csNameEdit:SetScript("OnShow", function(self)
        csNameEdit.placeholder:SetShown(self:GetText() == "")
    end)

    local csFileEdit = CreateSQEditBox(content, 160, 20, { maxLetters = 128 })
    csFileEdit:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad + 158, yOffset)
    csFileEdit:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    csFileEdit.placeholder = csFileEdit:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    csFileEdit.placeholder:SetPoint("LEFT", csFileEdit, "LEFT", 6, 0)
    csFileEdit.placeholder:SetText("mysound.ogg")
    csFileEdit.placeholder:SetTextColor(0.4, 0.4, 0.4)
    csFileEdit:SetScript("OnTextChanged", function(self)
        csFileEdit.placeholder:SetShown(self:GetText() == "")
    end)
    csFileEdit:SetScript("OnShow", function(self)
        csFileEdit.placeholder:SetShown(self:GetText() == "")
    end)

    local csAddBtn = CreateSQButton(content, "Add", 60, 22)
    csAddBtn:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad + 326, yOffset - 1)
    csAddBtn:SetScript("OnClick", function()
        local nameSuffix = csNameEdit:GetText():match("^%s*(.-)%s*$")
        local file = csFileEdit:GetText():match("^%s*(.-)%s*$")
        if nameSuffix == "" or file == "" then return end
        local name = "Squizzumables: " .. nameSuffix
        if not file:lower():match("%.ogg$") then
            file = file .. ".ogg"
        end
        self.settings.customSounds = self.settings.customSounds or {}
        for _, e in ipairs(self.settings.customSounds) do
            if e.name == name then return end
        end
        table.insert(self.settings.customSounds, { name = name, file = file })
        self:SaveSettings()
        local lsm = GetLSM()
        if lsm then
            lsm:Register("sound", name, CUSTOM_SOUNDS_PATH .. file)
        end
        csNameEdit:SetText("")
        csFileEdit:SetText("")
        csNameEdit.placeholder:Show()
        csFileEdit.placeholder:Show()
        self:RefreshCustomSoundsList()
        if self.scrollChild then self:RefreshItemList() end
    end)
    yOffset = yOffset - 30

    content:SetHeight(math.abs(yOffset) + 20)
end

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

function BH:RefreshTextRemindersTab()
    if not self.settings then return end
    -- Every migrated row syncs itself from its own get(); this only has to
    -- cover the two controls the declarative kit has no builder for -- the
    -- announce text box, and the per-context channel grid, which is a keyed
    -- set of dropdowns rather than one row.
    ns.Rows.RefreshAll()

    if self.trFeastAnnounceTextEdit then
        local txt = (self.settings.feastAnnounceText or "")
        self.trFeastAnnounceTextEdit:SetText(txt)
        self.trFeastAnnounceTextEdit.placeholder:SetShown(txt == "")
    end
    if self.trFeastChannelDDs then
        local chanDB = type(self.settings.feastAnnounceChannel) == "table"
            and self.settings.feastAnnounceChannel
            or BH.defaultSettings.feastAnnounceChannel
        for key, dd in pairs(self.trFeastChannelDDs) do
            dd:SetSelectedValue(chanDB[key] or "NONE")
        end
    end
end

-- ============================================================
-- DUNGEON CALLOUTS — in-game button frame + config tab
-- ============================================================

-- Stored channel -> the slash command the secure macro runs.
--
-- The buttons send through a macro on a SecureActionButtonTemplate, which is
-- what survives taint; see the button construction in
-- UpdateCalloutsButtonFrame. 1.64 briefly swapped this for SendChatMessage and
-- chat channel strings, which was wrong -- SendChatMessage is protected too.
--
-- Say and Yell stay removed. That part of 1.64 was right for its own reasons:
-- Blizzard restricts addon-initiated SAY and YELL inside instances, which is
-- the only place callouts appear.
local CALLOUT_SLASH_MAP = {
    INSTANCE     = "/instance",
    PARTY        = "/party",
    RAID         = "/raid",
    RAID_WARNING = "/rw",
}
local CALLOUT_CHANNEL_ITEMS = {
    { text = "Instance",     value = "INSTANCE"     },
    { text = "Party",        value = "PARTY"        },
    { text = "Raid",         value = "RAID"         },
    { text = "Raid Warning", value = "RAID_WARNING" },
}

function BH:SaveCalloutsFramePosition()
    self:SaveFramePos("calloutsButtonFrame", "calloutsFramePosition")
end
function BH:LoadCalloutsFramePosition()
    self:LoadFramePos("calloutsButtonFrame", "calloutsFramePosition")
end

-- Creates the persistent callout button frame (once at login).
-- Buttons inside it are rebuilt by UpdateCalloutsButtonFrame on zone change.
function BH:BuildCalloutsButtonFrame()
    if self.calloutsButtonFrame then return end
    local f = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    f:SetSize(144, 40)
    f:SetPoint("CENTER", UIParent, "CENTER", 200, 0)
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:Hide()

    -- Draggable by the frame itself, not only by its title bar. In unlock
    -- mode the callout buttons and the title bar are muted so the drag can
    -- reach this frame; without these scripts that left it unmovable from
    -- anywhere at all.
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        BH:SaveCalloutsFramePosition()
    end)
    ApplySQBackdrop(f)
    self.calloutsButtonFrame = f

    local titleBar = CreateFrame("Frame", nil, f, "BackdropTemplate")
    titleBar:SetHeight(14)
    titleBar:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
    titleBar:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, 0)
    titleBar:SetBackdrop({ bgFile = "Interface\\BUTTONS\\WHITE8X8", edgeSize = 0 })
    titleBar:SetBackdropColor(0.10, 0.10, 0.13, 1)
    titleBar:EnableMouse(true)
    titleBar:RegisterForDrag("LeftButton")
    titleBar:SetScript("OnDragStart", function() f:StartMoving() end)
    titleBar:SetScript("OnDragStop", function()
        f:StopMovingOrSizing()
        BH:SaveCalloutsFramePosition()
    end)
    local titleText = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    titleText:SetPoint("CENTER", titleBar, "CENTER", 0, 0)
    titleText:SetText("Callouts")
    titleText:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])
    self.calloutsButtonFrameBtns = {}
end

-- Rebuilds callout buttons for the current dungeon.  Must be called OOC.
function BH:UpdateCalloutsButtonFrame()
    if not self.calloutsButtonFrame then return end
    if InCombatLockdown() then return end
    -- Clear previous buttons
    for _, btn in ipairs(self.calloutsButtonFrameBtns or {}) do
        btn:Hide()
        btn:SetParent(nil)
    end
    self.calloutsButtonFrameBtns = {}
    local f = self.calloutsButtonFrame
    -- While frames are unlocked, show this even with no callouts configured for
    -- the current instance, so it can be positioned from anywhere. It is just
    -- its title bar in that state, which is enough to drag.
    local function ShowEmptyIfUnlocked()
        if BH.unlockMode then
            f:SetSize(144, 40)
            f:Show()
        else
            f:Hide()
        end
    end
    local callouts = self.settings and self.settings.dungeonCallouts
    if not callouts then ShowEmptyIfUnlocked(); return end
    local _, _, _, _, _, _, _, instanceID = GetInstanceInfo()
    local matchedGroup = nil
    for _, group in ipairs(callouts) do
        if group.instanceID == instanceID then matchedGroup = group; break end
    end
    if not matchedGroup or not matchedGroup.buttons or #matchedGroup.buttons == 0 then
        ShowEmptyIfUnlocked(); return
    end
    local BTN_H, BTN_W, GAP, TITLE_H = 24, 144, 2, 14
    local yOfs = -(TITLE_H + GAP)
    for _, callout in ipairs(matchedGroup.buttons) do
        -- SecureActionButtonTemplate running a macro, which is the mechanism
        -- that survives taint -- that is what it is for.
        --
        -- 1.64 briefly replaced this with a plain Button calling
        -- SendChatMessage, on the theory that dropping the secure button would
        -- remove the protected surface. It does the opposite. SendChatMessage
        -- carries HasRestrictions too, and from a plain OnClick in a key it is
        -- refused -- ADDON_ACTION_BLOCKED, on a real mouse click, which would
        -- normally be allowed. Being blocked anyway is the tell that the path
        -- is tainted, and a secure button is precisely how you execute an
        -- action from a tainted addon.
        --
        -- HookScript("OnClick") appends an insecure hook that runs AFTER the
        -- secure handler completes -- the documented safe pattern. (SetScript
        -- replaces the handler and taints it.)
        local btn = CreateFrame("Button", nil, f, "SecureActionButtonTemplate")
        btn:SetSize(BTN_W - 4, BTN_H)
        btn:SetPoint("TOPLEFT", f, "TOPLEFT", 2, yOfs)
        btn:RegisterForClicks(SQ_GetClickEdge())
        local bg = btn:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(SQ_COLORS.control[1], SQ_COLORS.control[2], SQ_COLORS.control[3], 1)
        btn:SetHighlightTexture("Interface\\BUTTONS\\WHITE8X8")
        btn:GetHighlightTexture():SetVertexColor(SQ_COLORS.controlHi[1], SQ_COLORS.controlHi[2], SQ_COLORS.controlHi[3], 0.4)
        local slash = CALLOUT_SLASH_MAP[callout.channel] or "/instance"
        btn:SetAttribute("type", "macro")
        btn:SetAttribute("macrotext", slash .. " " .. (callout.message or ""))
        local lbl = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        lbl:SetAllPoints()
        lbl:SetText(callout.label or "Callout")
        ns.ApplyAccent(lbl, "text")
        local sndName = callout.sound or "None"
        -- Sound only. The message is sent by the secure macro attribute above,
        -- because SendChatMessage is itself protected -- it carries the same
        -- HasRestrictions flag as AddAuraSound, and calling it from here was
        -- blocked in Mythic+ even on a real mouse click, which normally permits
        -- a protected call. Being refused anyway means the path is tainted.
        --
        -- So the secure button is not the problem and removing it was a
        -- mistake: it is the mechanism that survives taint, which is why it
        -- exists. Something taints this addon during a key; that is the bug,
        -- and this is not the place to work around it.
        btn:HookScript("OnClick", function()
            if sndName ~= "None" then
                PlaySQSound(sndName)
                -- Broadcast sound to other addon users in the group
                if IsInGroup() then
                    local addonChan = IsInInstance() and "INSTANCE_CHAT" or "PARTY"
                    C_ChatInfo.SendAddonMessage("SQ_CALLOUT", sndName, addonChan)
                end
            end
        end)
        table.insert(self.calloutsButtonFrameBtns, btn)
        yOfs = yOfs - BTN_H - GAP
    end
    local totalH = TITLE_H + GAP + #matchedGroup.buttons * (BTN_H + GAP)
    f:SetSize(BTN_W, totalH)
    f:Show()
end

function BH:RememberVisitedInstance()
    local name, instanceType, _, _, _, _, _, instanceID = GetInstanceInfo()
    if not instanceID or instanceID == 0 then return end
    -- Skip the open world and battlegrounds; callouts are for content you
    -- run repeatedly with the same pulls.
    if instanceType ~= "party" and instanceType ~= "raid" and instanceType ~= "scenario" then
        return
    end
    SquizzumablesDB.visitedInstances = SquizzumablesDB.visitedInstances or {}
    -- Re-recorded every visit rather than only when new: an instance can be
    -- renamed between patches, and the stored name is what the dropdown
    -- shows.
    SquizzumablesDB.visitedInstances[instanceID] = name
end

-- Every dungeon worth offering, deduped by instanceID.
--
-- Three sources. The season's Mythic+ list comes from
-- C_ChallengeMode.GetMapTable(), which is live data -- so this refreshes
-- itself when the season rotates and there is nothing to hardcode. The 6th
-- return of GetMapUIInfo is the same number GetInstanceInfo reports as its
-- instanceID, which is what callouts match on (verified in game: Murder Row
-- is challenge map 587, mapID 2813, and standing inside it GetInstanceInfo
-- also says 2813).
--
-- Then anything already configured, so a dungeon keeps its entry after the
-- season moves on, and finally whatever instance the player is standing in,
-- which is the only route for raids and non-seasonal dungeons.
local function CalloutDungeonList()
    local list, seen = {}, {}

    local function Add(instanceID, name, tag)
        if not instanceID or instanceID == 0 or seen[instanceID] then return end
        seen[instanceID] = true
        list[#list + 1] = { instanceID = instanceID, name = name or ("Instance " .. instanceID), tag = tag }
    end

    for _, group in ipairs(BH.settings and BH.settings.dungeonCallouts or {}) do
        Add(group.instanceID, group.name, "saved")
    end

    if C_ChallengeMode and C_ChallengeMode.GetMapTable then
        local ok, maps = pcall(C_ChallengeMode.GetMapTable)
        for _, mapChallengeModeID in ipairs((ok and maps) or {}) do
            local mapName, _, _, _, _, instanceID = C_ChallengeMode.GetMapUIInfo(mapChallengeModeID)
            Add(instanceID, mapName, "season")
        end
    end

    for instanceID, name in pairs(SquizzumablesDB and SquizzumablesDB.visitedInstances or {}) do
        Add(instanceID, name, "visited")
    end

    local hereName, _, _, _, _, _, _, hereID = GetInstanceInfo()
    Add(hereID, hereName, "here")

    table.sort(list, function(a, b) return (a.name or ""):lower() < (b.name or ""):lower() end)
    return list
end
BH.CalloutDungeonList = CalloutDungeonList

-- The stored group for a dungeon, or nil. Selecting a dungeon deliberately
-- does not create one: browsing the dropdown would otherwise fill the saved
-- settings with empty entries for every dungeon merely looked at. The group
-- is created on the first callout added to it.
function BH.CalloutGroupFor(instanceID)
    for _, group in ipairs(BH.settings and BH.settings.dungeonCallouts or {}) do
        if group.instanceID == instanceID then return group end
    end
    return nil
end

function BH:BuildCalloutsTab(parent)
    local scrollFrame = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    scrollFrame:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -22, 0)
    local content = CreateFrame("Frame", nil, scrollFrame)
    content:SetWidth(400)
    scrollFrame:SetScrollChild(content)

    local leftPad = 14
    local yOffset = -14

    local hdr = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hdr:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    hdr:SetText("DUNGEON CALLOUTS")
    ns.ApplyAccent(hdr, "text")
    yOffset = yOffset - 16

    local note = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    note:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    note:SetWidth(372)
    note:SetJustifyH("LEFT")
    note:SetText("Buttons appear automatically when you enter the matching dungeon. Clicking sends the message and plays the sound. Works in combat and M+.")
    note:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])
    yOffset = yOffset - 36

    local dungeonDrop
    local function DungeonDropItems()
        local items = {}
        for _, entry in ipairs(CalloutDungeonList()) do
            local group = BH.CalloutGroupFor(entry.instanceID)
            local count = group and #(group.buttons or {}) or 0
            -- The count is the whole point of the marker: it separates "set up"
            -- from "offered but empty" without opening each one.
            local suffix = (count > 0) and ("  |cff888888(" .. count .. ")|r") or ""
            if entry.tag == "here" then suffix = suffix .. "  |cff888888[here]|r" end
            items[#items + 1] = { text = (entry.name or "?") .. suffix, value = entry.instanceID }
        end
        return items
    end
    BH.CalloutDungeonDropItems = DungeonDropItems

    dungeonDrop = CreateSQDropdown(content, "Dungeon:", 250, DungeonDropItems(), function(val)
        BH.selectedCalloutInstanceID = val
        BH:RefreshCalloutsTab()
    end)
    dungeonDrop:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    self.calloutsDungeonDrop = dungeonDrop
    ns.Rows.AddTooltip(dungeonDrop, "Dungeon",
        "This season's Mythic+ dungeons, plus any you have already set up and whatever you are standing in. The number is how many callouts it has.")
    yOffset = yOffset - 46

    local addCalloutBtn = CreateSQButton(content, "+ Add Callout", 120, 24)
    addCalloutBtn:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    addCalloutBtn:SetScript("OnClick", function()
        local instanceID = BH.selectedCalloutInstanceID
        if not instanceID then return end
        BH.settings.dungeonCallouts = BH.settings.dungeonCallouts or {}
        local group = BH.CalloutGroupFor(instanceID)
        if not group then
            -- Created here rather than on selection, so the saved list only
            -- ever holds dungeons actually in use.
            local name
            for _, entry in ipairs(CalloutDungeonList()) do
                if entry.instanceID == instanceID then name = entry.name break end
            end
            group = { instanceID = instanceID, name = name, buttons = {} }
            table.insert(BH.settings.dungeonCallouts, group)
        end
        table.insert(group.buttons, { label = "", message = "", channel = "INSTANCE", sound = "None" })
        BH:SaveSettings()
        BH:UpdateCalloutsButtonFrame()
        BH:RefreshCalloutsTab()
    end)
    self.calloutsAddBtn = addCalloutBtn

    local delDungeonBtn = CreateSQButton(content, "Delete Dungeon", 120, 24, SQ_COLORS.danger)
    delDungeonBtn:SetPoint("LEFT", addCalloutBtn, "RIGHT", 8, 0)
    delDungeonBtn:SetScript("OnClick", function()
        local instanceID = BH.selectedCalloutInstanceID
        for i, group in ipairs(BH.settings.dungeonCallouts or {}) do
            if group.instanceID == instanceID then
                table.remove(BH.settings.dungeonCallouts, i)
                break
            end
        end
        BH:SaveSettings()
        BH:UpdateCalloutsButtonFrame()
        BH:RefreshCalloutsTab()
    end)
    self.calloutsDelDungeonBtn = delDungeonBtn
    ns.Rows.AddTooltip(delDungeonBtn, "Delete dungeon",
        "Remove every callout for this dungeon. It stays in the list above if the season still includes it.")
    yOffset = yOffset - 32

    -- The dungeon you are standing in is already in the dropdown, tagged
    -- [here]. This jumps straight to it, which is the common case while
    -- actually running the place and wanting a callout for the pull you just
    -- wiped on.
    local hereBtn = CreateSQButton(content, "+ Add Current Dungeon", 190, 24)
    hereBtn:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    hereBtn:SetScript("OnClick", function()
        local _, _, _, _, _, _, _, iID = GetInstanceInfo()
        if not iID or iID == 0 then return end
        BH.selectedCalloutInstanceID = iID
        BH:RefreshCalloutsTab()
    end)
    hereBtn:SetScript("OnEnter", function(s)
        GameTooltip:SetOwner(s, "ANCHOR_RIGHT")
        local dName, _, _, _, _, _, _, iID = GetInstanceInfo()
        if iID and iID ~= 0 then
            GameTooltip:SetText("Select: " .. (dName or "?") .. " (ID: " .. tostring(iID) .. ")")
            GameTooltip:AddLine("Nothing is saved until you add a callout.", 0.7, 0.7, 0.7, true)
        else
            GameTooltip:SetText("Must be inside a dungeon or raid.")
        end
        GameTooltip:Show()
    end)
    hereBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    self.calloutsHereBtn = hereBtn
    yOffset = yOffset - 32

    -- Dynamic dungeon list (rebuilt by RefreshCalloutsTab)
    local listFrame = CreateFrame("Frame", nil, content)
    listFrame:SetPoint("TOPLEFT", content, "TOPLEFT", 0, yOffset)
    listFrame:SetWidth(400)
    listFrame:SetHeight(10)
    self.calloutsTabContent = content
    self.calloutsTabListFrame = listFrame
    self.calloutsTabStaticHeight = math.abs(yOffset)
    self:RefreshCalloutsTab()
end

function BH:RefreshCalloutsTab()
    local listFrame = self.calloutsTabListFrame
    local content   = self.calloutsTabContent
    if not listFrame or not content then return end
    -- Clear previous dynamic content
    for _, child in pairs({ listFrame:GetChildren() }) do
        child:Hide(); child:SetParent(nil)
    end

    local leftPad = 14
    local W = 372
    local yOffset = 0

    -- Default the selection rather than showing nothing on first open: the
    -- instance you are standing in if it is one, else the first entry offered.
    local dungeons = BH.CalloutDungeonList and BH.CalloutDungeonList() or {}
    local selected = BH.selectedCalloutInstanceID
    local valid = false
    for _, entry in ipairs(dungeons) do
        if entry.instanceID == selected then valid = true break end
    end
    if not valid then
        local _, _, _, _, _, _, _, hereID = GetInstanceInfo()
        selected = (hereID and hereID ~= 0) and hereID or (dungeons[1] and dungeons[1].instanceID)
        BH.selectedCalloutInstanceID = selected
    end

    if self.calloutsDungeonDrop and BH.CalloutDungeonDropItems then
        self.calloutsDungeonDrop:SetItems(BH.CalloutDungeonDropItems())
        self.calloutsDungeonDrop:SetSelectedValue(selected)
    end

    -- Only the selected dungeon is rendered. Every configured dungeon used to
    -- be stacked into this one scroll, which grew without bound; now the tab is
    -- a fixed height whatever the player has set up.
    local group = selected and BH.CalloutGroupFor and BH.CalloutGroupFor(selected) or nil

    -- Delete only means something once a group exists.
    if self.calloutsDelDungeonBtn then
        self.calloutsDelDungeonBtn:SetAlpha(group and 1 or 0.35)
        self.calloutsDelDungeonBtn:SetEnabled(group and true or false)
    end

    if not selected then
        local none = listFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        none:SetPoint("TOPLEFT", listFrame, "TOPLEFT", leftPad, yOffset)
        none:SetText("No dungeons available. Enter one, or wait for the season list to load.")
        none:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])
        listFrame:SetHeight(24)
        content:SetHeight((self.calloutsTabStaticHeight or 0) + 24 + 20)
        return
    end

    if not group or #(group.buttons or {}) == 0 then
        local none = listFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        none:SetPoint("TOPLEFT", listFrame, "TOPLEFT", leftPad, yOffset)
        none:SetText("No callouts here yet. Add one above.")
        none:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])
        listFrame:SetHeight(24)
        content:SetHeight((self.calloutsTabStaticHeight or 0) + 24 + 20)
        return
    end

    do
        local groupFrame = CreateFrame("Frame", nil, listFrame)
        groupFrame:SetPoint("TOPLEFT", listFrame, "TOPLEFT", 0, yOffset)
        groupFrame:SetWidth(400)
        local gy = 0

        local div = CreateSQDivider(groupFrame, gy)
        div:SetPoint("TOPLEFT", groupFrame, "TOPLEFT", leftPad, gy)
        gy = gy - 18

        -- Per-callout rows
        for bIdx, callout in ipairs(group.buttons) do
            local rowFrame = CreateFrame("Frame", nil, groupFrame)
            rowFrame:SetPoint("TOPLEFT", groupFrame, "TOPLEFT", leftPad, gy)
            rowFrame:SetSize(W, 56)

            -- Row 1: [Label 86px] [Message 256px] [× 22px]
            local labelEdit = CreateSQEditBox(rowFrame, 86, 20, { maxLetters = 32 })
            labelEdit:SetPoint("TOPLEFT", rowFrame, "TOPLEFT", 0, 0)
            labelEdit:SetText(callout.label or "")
            local labelPH = labelEdit:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            labelPH:SetPoint("LEFT", labelEdit, "LEFT", 6, 0)
            labelPH:SetText("Label")
            labelPH:SetTextColor(0.4, 0.4, 0.4)
            labelPH:SetShown(labelEdit:GetText() == "")
            labelEdit:SetScript("OnTextChanged", function(self)
                labelPH:SetShown(self:GetText() == "")
                callout.label = self:GetText()
                BH:SaveSettings(); BH:UpdateCalloutsButtonFrame()
            end)
            labelEdit:SetScript("OnEnterPressed", function(s) s:ClearFocus() end)
            labelEdit:SetScript("OnEscapePressed", function(s) s:ClearFocus() end)
            labelEdit:SetScript("OnShow", function(s) labelPH:SetShown(s:GetText() == "") end)

            local msgEdit = CreateSQEditBox(rowFrame, 256, 20, { maxLetters = 200 })
            msgEdit:SetPoint("TOPLEFT", rowFrame, "TOPLEFT", 92, 0)
            msgEdit:SetText(callout.message or "")
            local msgPH = msgEdit:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            msgPH:SetPoint("LEFT", msgEdit, "LEFT", 6, 0)
            msgPH:SetText("Chat message text")
            msgPH:SetTextColor(0.4, 0.4, 0.4)
            msgPH:SetShown(msgEdit:GetText() == "")
            msgEdit:SetScript("OnTextChanged", function(self)
                msgPH:SetShown(self:GetText() == "")
                callout.message = self:GetText()
                BH:SaveSettings(); BH:UpdateCalloutsButtonFrame()
            end)
            msgEdit:SetScript("OnEnterPressed", function(s) s:ClearFocus() end)
            msgEdit:SetScript("OnEscapePressed", function(s) s:ClearFocus() end)
            msgEdit:SetScript("OnShow", function(s) msgPH:SetShown(s:GetText() == "") end)

            local delBtn = CreateSQButton(rowFrame, "×", 22, 20, SQ_COLORS.danger)
            delBtn:SetPoint("TOPLEFT", rowFrame, "TOPLEFT", 354, 0)
            -- Captured against the group table rather than its index: only one
            -- group is rendered now, and an index into dungeonCallouts would be
            -- wrong the moment another dungeon is deleted from under it.
            local cb = bIdx
            delBtn:SetScript("OnClick", function()
                table.remove(group.buttons, cb)
                BH:SaveSettings(); BH:UpdateCalloutsButtonFrame(); BH:RefreshCalloutsTab()
            end)

            -- Row 2: [Channel DD 100px] [Sound DD 200px] [▶ 22px]
            local chanDD = CreateSQDropdown(rowFrame, "", 100, CALLOUT_CHANNEL_ITEMS, function(value)
                callout.channel = value
                BH:SaveSettings(); BH:UpdateCalloutsButtonFrame()
            end)
            chanDD:SetPoint("TOPLEFT", rowFrame, "TOPLEFT", 0, -24)
            chanDD:SetSelectedValue(callout.channel or "INSTANCE")

            local sndDD = CreateSQDropdown(rowFrame, "", 200, BuildSoundDropdownItems(), function(value)
                callout.sound = value
                BH:SaveSettings(); BH:UpdateCalloutsButtonFrame()
            end)
            sndDD:SetPoint("TOPLEFT", rowFrame, "TOPLEFT", 106, -24)
            sndDD:SetSelectedValue(callout.sound or "None")

            local pvBtn = CreateFrame("Button", nil, rowFrame)
            pvBtn:SetSize(22, 22)
            pvBtn:SetPoint("TOPLEFT", rowFrame, "TOPLEFT", 312, -28)
            local pvn = pvBtn:CreateTexture(nil, "BACKGROUND")
            pvn:SetAllPoints(); pvn:SetTexture("Interface\\Common\\VoiceChat-Speaker")
            local pvh = pvBtn:CreateTexture(nil, "HIGHLIGHT")
            pvh:SetAllPoints(); pvh:SetTexture("Interface\\Common\\VoiceChat-Speaker"); pvh:SetAlpha(0.6)
            pvBtn:SetScript("OnEnter", function() pvn:SetAlpha(0.7) end)
            pvBtn:SetScript("OnLeave", function() pvn:SetAlpha(1.0) end)
            pvBtn:SetScript("OnClick", function() PlaySQSound(callout.sound or "None") end)

            gy = gy - 62
        end

        -- No "Add Callout" here any more: there is one in the header, which is
        -- always on screen rather than below however many rows this dungeon has.
        groupFrame:SetHeight(math.abs(gy))
        yOffset = yOffset + gy
    end

    listFrame:SetHeight(math.abs(yOffset) + 10)
    content:SetHeight((self.calloutsTabStaticHeight or 80) + math.abs(yOffset) + 20)
end
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

-- Emerald Coach's Whistle constants (declared here so RefreshItemList can reference them)
local COACH_WHISTLE_ITEM_ID = 193718
local COACHED_AURA_SPELL_ID = 386578  -- "Coached" 1-hour buff applied to the coached ally

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
    -- Exception: selfBuff spells (e.g. Rogue poisons) do have durations
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
    if BH.unlockMode then self:StartMoving() end
end)
BH.frame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    BH:SaveFramePosition()
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
    local size = (BH.settings and BH.settings.buttonSize) or 36
    local headerHeight = headerText and 12 or 0

    if not btn then
        -- First use: create an anonymous (un-named) frame so it can be GC'd eventually,
        -- and create all child objects once.  They are reconfigured on every reuse.
        btn = CreateFrame("Button", nil, BH.frame, "SecureActionButtonTemplate")

        -- Header font string (always created; hidden when not needed)
        btn.header = btn:CreateFontString(nil, "OVERLAY")
        btn.header:SetJustifyH("CENTER")
        btn.header:SetTextColor(0.2, 0.8, 1)  -- Light blue

        -- Icon texture
        btn.icon = btn:CreateTexture(nil, "BACKGROUND")

        -- Quality pip overlay
        btn.qualityPip = btn:CreateTexture(nil, "OVERLAY")
        btn.qualityPip:SetSize(30, 30)

        -- Timer font string
        btn.timer = btn:CreateFontString(nil, "OVERLAY")
        btn.timer:SetTextColor(1, 1, 0)  -- Yellow

        -- Bag count font string
        btn.countText = btn:CreateFontString(nil, "OVERLAY")
        btn.countText:SetTextColor(1, 1, 1)

        -- Label font string
        btn.label = btn:CreateFontString(nil, "OVERLAY")
        btn.label:SetJustifyH("CENTER")
        btn.label:SetWordWrap(true)
        btn.label:SetMaxLines(3)
        btn.label:SetTextColor(1, 1, 1)

        -- Hearty food badge (top-right corner of icon)
        btn.heartyBadge = btn:CreateFontString(nil, "OVERLAY")
        btn.heartyBadge:SetTextColor(1, 0.82, 0.2)  -- Warm gold
    else
        -- Returning from pool: re-parent and make visible
        btn:SetParent(BH.frame)
        btn:Show()
    end

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

    -- Label text below icon (conditionally shown)
    local labelOffX = (BH.settings and BH.settings.buttonLabelOffsetX) or 0
    local labelOffY = (BH.settings and BH.settings.buttonLabelOffsetY) or -2
    btn.label:ClearAllPoints()
    btn.label:SetPoint("TOP", btn.icon, "BOTTOM", labelOffX, labelOffY)
    btn.label:SetWidth(size)
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
    ns.Glow.Set(btn, BH.settings and BH.settings.glowReminderButtons ~= false, btn.icon)

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

-- Symbiotic Relationship spell IDs
local SYMBIOTIC_CAST_SPELL_ID = 474750    -- The talent/cast spell
local SYMBIOTIC_AURA_SPELL_ID = 474754    -- The buff on party members

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
        class = "PALADIN", spec = 65,
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
        class = "SHAMAN", knowsSpell = 974, buffEnabledSpell = 974,
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
        -- Sits between the enable toggle and the scale slider, as it did before.
        extraRows = {
            {
                type = "slider", label = "Durability Threshold (%)",
                width = 300, min = 0, max = 100, step = 1,
                tooltip = "Show the reminder once your most damaged equipped item falls below this percentage.",
                disabled = function() return BH.settings and BH.settings.repairReminderEnabled == false end,
                get = function() return BH.settings and BH.settings.repairReminderThreshold or 20 end,
                set = function(v)
                    BH.settings.repairReminderThreshold = v
                    BH:SaveSettings()
                    BH:UpdateRepairReminder()
                end,
            },
        },
        text = "REPAIR", color = { 0.9, 0.2, 0.2 },
        size = { 300, 40 }, defaultY = 120,
        -- The only reminder that was never given the HIGH strata. Kept as-is
        -- so its stacking order relative to other frames does not change.
        strata = false,
    },
    {
        key = "symbiotic", globalName = "SQUIZZUMABLESSymbioticReminder",
        gates = { "enabled", "class", "knows", "visible", "group" },
        class = "DRUID", knowsSpell = SYMBIOTIC_CAST_SPELL_ID,
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
        class = "HUNTER", notSpec = 255,
        label = "No Pet Reminder (Hunter)",
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

-- Build one reminder frame from its definition. Replaces ten copies of this.
local function CreateReminderFrame(def)
    local key       = def.key
    local lockedKey = key .. "ReminderLocked"
    local saveFn    = "Save" .. ReminderBaseName(key) .. "ReminderPosition"

    local frame = CreateFrame("Frame", def.globalName, UIParent)
    frame:SetSize(def.size[1], def.size[2])
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, def.defaultY)
    if def.strata ~= false then frame:SetFrameStrata("HIGH") end
    frame:SetMovable(true)
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self)
        if not (BH.settings and BH.settings[lockedKey]) or BH.unlockMode then
            self:StartMoving()
            self:SetUserPlaced(false)
        end
    end)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        if BH[saveFn] then BH[saveFn](BH) end
    end)
    frame:Hide()

    local text = frame:CreateFontString(nil, "OVERLAY")
    text:SetFont("Fonts\\FRIZQT__.TTF", 24, "OUTLINE")
    text:SetPoint("CENTER", frame, "CENTER", 0, 0)
    text:SetText(def.text)
    text:SetTextColor(def.color[1], def.color[2], def.color[3], 1)

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
local MOVABLE_FRAMES = {
    -- field                enabled setting            extra gate
    { field = "frame", label = "Consumables" },  -- main buttons frame; always previewable
    { field = "markersFrame",        label = "Raid Markers",   enabled = "raidToolsShowMarkers",   gate = "raidToolsEnabled", muteChildren = true },
    { field = "pullReadyFrame",      label = "Pull / Ready",   enabled = "raidToolsShowPullReady", gate = "raidToolsEnabled", muteChildren = true },
    { field = "bresCounterFrame",    label = "Battle Res",     enabled = "bresCounterEnabled" },
    { field = "deathTallyFrame",     label = "Death Tally",    enabled = "deathTallyEnabled" },
    { field = "calloutsButtonFrame", label = "Callouts",       enabled = "dungeonCallouts", muteChildren = true },
    { field = "targetDistanceFrame", label = "Target Distance", enabled = "targetDistanceEnabled" },
    { field = "coTankFrame",         label = "Co-Tank",        enabled = "coTankEnabled" },
}

-- Every text reminder, from the registry rather than by hand.
for _, def in ipairs(BH.REMINDERS) do
    MOVABLE_FRAMES[#MOVABLE_FRAMES + 1] = {
        field   = def.key .. "ReminderFrame",
        enabled = def.key .. "ReminderEnabled",
        label   = def.label or def.key,
    }
end
BH.MOVABLE_FRAMES = MOVABLE_FRAMES

-- The green tint. Kept on the frame itself rather than in a dozen BH fields.
-- Every previewable frame gets the same green box, and there are well over a
-- dozen of them once the reminders and the Cooldown Manager groups are counted.
-- Unlabelled they are indistinguishable, so a box sitting near some other
-- frame's contents reads as that frame's drag region being misaligned -- there
-- is no way to tell from looking, or from a screenshot, which frame a given
-- rectangle belongs to. So each one says what it is.
local function SetPreviewOverlay(frame, on, label)
    if not frame then return end
    if on then
        if not frame.sqPreviewOverlay then
            local ov = frame:CreateTexture(nil, "OVERLAY")
            ov:SetAllPoints()
            ov:SetColorTexture(0.1, 0.8, 0.1, 0.15)
            frame.sqPreviewOverlay = ov
        end
        frame.sqPreviewOverlay:Show()

        if label then
            if not frame.sqPreviewLabel then
                -- Own frame at TOOLTIP strata rather than a FontString on the
                -- frame itself: these overlap each other freely, and a label at
                -- the frame's own strata disappears under whatever is stacked
                -- on top of it.
                local holder = CreateFrame("Frame", nil, frame)
                holder:SetFrameStrata("TOOLTIP")
                holder:SetPoint("BOTTOMLEFT", frame, "TOPLEFT", 0, 2)
                holder:SetSize(240, 14)
                local fs = holder:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                fs:SetPoint("BOTTOMLEFT", holder, "BOTTOMLEFT", 0, 0)
                fs:SetJustifyH("LEFT")
                fs:SetTextColor(0.3, 1, 0.3)
                frame.sqPreviewLabelHolder = holder
                frame.sqPreviewLabel = fs
            end
            frame.sqPreviewLabel:SetText(label)
            frame.sqPreviewLabelHolder:Show()
        end
    else
        if frame.sqPreviewOverlay then frame.sqPreviewOverlay:Hide() end
        if frame.sqPreviewLabelHolder then frame.sqPreviewLabelHolder:Hide() end
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
                SetPreviewOverlay(frame, true, def.label)
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
        BH.bresCounterFrame:StartMoving()
        BH.bresCounterFrame:SetUserPlaced(false)
    end
end)
BH.bresCounterFrame:SetScript("OnDragStop", function()
    BH.bresCounterFrame:StopMovingOrSizing()
    BH:SaveBresCounterPosition()
end)
BH.bresCounterFrame:Hide()

BH.bresCounterText = BH.bresCounterFrame:CreateFontString(nil, "OVERLAY")
BH.bresCounterText:SetFont("Fonts\\FRIZQT__.TTF", 20, "OUTLINE")
BH.bresCounterText:SetPoint("CENTER", BH.bresCounterFrame, "CENTER", 0, 0)
BH.bresCounterText:SetText("BREZ: 0")
BH.bresCounterText:SetTextColor(1.0, 0.82, 0.0, 1)

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
                BH.bresCounterText:SetTextColor(0.9, 0.2, 0.2, 1)
            elseif charges == 1 then
                BH.bresCounterText:SetTextColor(1.0, 0.5, 0.0, 1)
            else
                BH.bresCounterText:SetTextColor(0.2, 0.9, 0.2, 1)
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
        self.bresCounterText:SetTextColor(0.2, 0.9, 0.2, 1)
        self.bresCounterFrame:Show()
        self.bresCounterFrame:EnableMouse(true)
        return
    end
end

-- ============================================================================
-- M+ Death Tally
-- ============================================================================
-- Self-tracked per-player death counter for the current Mythic+ run. Unlike
-- C_ChallengeMode.GetDeathCount() (a single group-wide total with no
-- per-player breakdown), this attributes each death to the group member who
-- died by polling UnitIsDeadOrGhost() per party/raid unit and edge-detecting
-- the false→true transition (see the ticker below) — not an event, since
-- neither UNIT_DIED nor COMBAT_LOG_EVENT_UNFILTERED proved reliable here.
--
-- Lifecycle: starts tracking (and auto-resets) on CHALLENGE_MODE_START, stops
-- tracking on CHALLENGE_MODE_COMPLETED/RESET. Stopping only stops counting
-- new deaths — the frame is left showing the final tally as a summary until
-- the next key start resets it, rather than hiding immediately.
local deathTallyActive = false
local deathTallyData  = {}   -- [GUID] = { name=, realm=, classFile=, count= }
local deathTallyOrder = {}   -- ordered list of GUIDs (party order), for stable row display
-- Set by the frame's close (X) button; hides the summary early once the group
-- is done with M+. Reset on the next CHALLENGE_MODE_START so the frame always
-- reappears for a new key regardless of whether the last one was dismissed.
local deathTallyManuallyClosed = false

BH.deathTallyFrame = CreateFrame("Frame", "SquizzumablesDeathTallyFrame", UIParent)
BH.deathTallyFrame:SetSize(180, 26)
BH.deathTallyFrame:SetPoint("TOP", UIParent, "TOP", 220, -100)
BH.deathTallyFrame:SetMovable(true)
BH.deathTallyFrame:SetClampedToScreen(true)
BH.deathTallyFrame:EnableMouse(true)
BH.deathTallyFrame:SetFrameStrata("MEDIUM")
BH.deathTallyFrame:SetFixedFrameStrata(true)
BH.deathTallyFrame:RegisterForDrag("LeftButton")
BH.deathTallyFrame:SetScript("OnDragStart", function()
    if not (BH.settings and BH.settings.deathTallyLocked) or BH.unlockMode then
        BH.deathTallyFrame:StartMoving()
        BH.deathTallyFrame:SetUserPlaced(false)
    end
end)
BH.deathTallyFrame:SetScript("OnDragStop", function()
    BH.deathTallyFrame:StopMovingOrSizing()
    BH:SaveDeathTallyPosition()
end)
BH.deathTallyFrame:Hide()

-- Close (X) button: dismiss the summary early once done with M+. Always
-- clickable regardless of the lock setting (lock only affects dragging).
BH.deathTallyCloseBtn = CreateFrame("Button", nil, BH.deathTallyFrame)
BH.deathTallyCloseBtn:SetSize(14, 14)
BH.deathTallyCloseBtn:SetPoint("TOPRIGHT", BH.deathTallyFrame, "TOPRIGHT", 2, 2)
local deathTallyCloseText = BH.deathTallyCloseBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
deathTallyCloseText:SetPoint("CENTER")
deathTallyCloseText:SetText("X")
deathTallyCloseText:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])
BH.deathTallyCloseBtn:SetScript("OnEnter", function()
    deathTallyCloseText:SetTextColor(SQ_COLORS.danger[1], SQ_COLORS.danger[2], SQ_COLORS.danger[3])
end)
BH.deathTallyCloseBtn:SetScript("OnLeave", function()
    deathTallyCloseText:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])
end)
BH.deathTallyCloseBtn:SetScript("OnClick", function()
    deathTallyManuallyClosed = true
    BH.deathTallyFrame:Hide()
end)

-- Poll-based death detection (BigWigs pattern: AnimationGroup ticker instead of
-- OnUpdate). Neither UNIT_DIED nor COMBAT_LOG_EVENT_UNFILTERED are relied on —
-- UNIT_DIED doesn't reliably fire for off-screen party/raid members, and CLEU
-- has been removed from the addon API. Polling UnitIsDeadOrGhost() per group
-- member and edge-detecting the false→true transition needs neither.
do
    local ticker = BH.deathTallyFrame:CreateAnimationGroup()
    ticker:SetLooping("REPEAT")
    BH.deathTallyTicker = ticker
    ticker:SetScript("OnLoop", function()
        BH:PollDeathTally()
    end)
    local anim = ticker:CreateAnimation()
    anim:SetDuration(0.5)
end

BH.deathTallyTitle = BH.deathTallyFrame:CreateFontString(nil, "OVERLAY")
BH.deathTallyTitle:SetFont("Fonts\\FRIZQT__.TTF", 13, "OUTLINE")
BH.deathTallyTitle:SetPoint("TOP", BH.deathTallyFrame, "TOP", 0, 0)
BH.deathTallyTitle:SetText("M+ Death Tally")
BH.deathTallyTitle:SetTextColor(1.0, 0.82, 0.0, 1)

-- Pool of row FontStrings, lazily created/reused as group size changes.
-- Font and position are (re)applied every display update since font size is
-- user-configurable and rows are recycled across different group sizes.
BH.deathTallyRows = {}
local function GetDeathTallyRow(index)
    local row = BH.deathTallyRows[index]
    if not row then
        row = BH.deathTallyFrame:CreateFontString(nil, "OVERLAY")
        BH.deathTallyRows[index] = row
    end
    return row
end

-- Resolve an "aarrggbb" hex color string for a class file token (e.g. "WARRIOR").
-- Falls back to opaque white if unavailable.
local function GetDeathTallyNameColorHex(classFile)
    if classFile and C_ClassColor and C_ClassColor.GetClassColor then
        local color = C_ClassColor.GetClassColor(classFile)
        if color and color.GenerateHexColor then
            return color:GenerateHexColor()
        end
    end
    return "ffffffff"
end

-- Builds the "Name" or "Name-Realm" display string per the hide-realm setting.
local function FormatDeathTallyName(entry)
    if entry.realm and entry.realm ~= "" and not (BH.settings and BH.settings.deathTallyHideRealm) then
        return entry.name .. "-" .. entry.realm
    end
    return entry.name
end

-- Draws one row (name colored by class if enabled, count colored red if > 0)
-- and anchors it below the previous row (or the title for the first row).
local function DrawDeathTallyRow(index, rowFontSize, classColorEnabled, prevAnchor, displayName, classFile, count)
    local row = GetDeathTallyRow(index)
    row:SetFont("Fonts\\FRIZQT__.TTF", rowFontSize, "OUTLINE")
    row:ClearAllPoints()
    row:SetPoint("TOP", prevAnchor, "BOTTOM", 0, -3)
    local nameColor = classColorEnabled and GetDeathTallyNameColorHex(classFile) or "ffffffff"
    local countColor = count > 0 and "ffff5555" or "ffffffff"
    row:SetText(("|c%s%s|r: |c%s%d|r"):format(nameColor, displayName, countColor, count))
    row:Show()
    return row
end

-- Redraws the row list from deathTallyOrder/deathTallyData and resizes the frame.
function BH:UpdateDeathTallyDisplay()
    if not self.deathTallyFrame then return end

    local titleFontSize = (self.settings and self.settings.deathTallyTitleFontSize) or 13
    local rowFontSize   = (self.settings and self.settings.deathTallyRowFontSize) or 12
    self.deathTallyTitle:SetFont("Fonts\\FRIZQT__.TTF", titleFontSize, "OUTLINE")
    local classColorEnabled = not self.settings or self.settings.deathTallyClassColorNames ~= false

    if self.unlockMode then
        local previewEntries = {
            { displayName = "Tankname", classFile = "WARRIOR", count = 0 },
            { displayName = "Healyou",  classFile = "PRIEST",  count = 1 },
            { displayName = "Dpsalot",  classFile = "MAGE",    count = 3 },
        }
        local anchor = self.deathTallyTitle
        for i, e in ipairs(previewEntries) do
            anchor = DrawDeathTallyRow(i, rowFontSize, classColorEnabled, anchor, e.displayName, e.classFile, e.count)
        end
        for i = #previewEntries + 1, #self.deathTallyRows do
            self.deathTallyRows[i]:Hide()
        end
        self.deathTallyFrame:SetHeight(titleFontSize + 12 + #previewEntries * (rowFontSize + 6))
        self.deathTallyFrame:Show()
        self.deathTallyFrame:EnableMouse(true)
        return
    end

    if not self.settings or not self.settings.deathTallyEnabled or deathTallyManuallyClosed then
        self.deathTallyFrame:Hide()
        return
    end

    local shown = 0
    local anchor = self.deathTallyTitle
    for _, guid in ipairs(deathTallyOrder) do
        local entry = deathTallyData[guid]
        if entry then
            shown = shown + 1
            anchor = DrawDeathTallyRow(shown, rowFontSize, classColorEnabled, anchor,
                FormatDeathTallyName(entry), entry.classFile, entry.count)
        end
    end
    for i = shown + 1, #self.deathTallyRows do
        self.deathTallyRows[i]:Hide()
    end

    if shown == 0 then
        self.deathTallyFrame:Hide()
        return
    end

    self.deathTallyFrame:SetHeight(titleFontSize + 12 + shown * (rowFontSize + 6))
    self.deathTallyFrame:Show()
    local locked = self.settings and self.settings.deathTallyLocked
    self.deathTallyFrame:EnableMouse(not locked)
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

-- Adds any currently-present group member not yet tracked, at 0 deaths.
-- wasDead is seeded from their CURRENT state (not false) so a member who is
-- already dead/ghost at sync time (e.g. reload-mid-key, or joining mid-wipe)
-- isn't miscounted as a fresh death on the next poll.
-- Does NOT touch existing entries/counts — safe to call any time roster changes.
function BH:SyncDeathTallyRoster()
    for _, unit in ipairs(GetGroupUnits()) do
        if UnitExists(unit) and UnitIsPlayer(unit) then
            local guid = UnitGUID(unit)
            if guid and not deathTallyData[guid] then
                local name, realm = UnitName(unit)
                local _, classFile = UnitClass(unit)
                if name then
                    deathTallyData[guid] = {
                        name = name, realm = realm, classFile = classFile,
                        count = 0, wasDead = UnitIsDeadOrGhost(unit) and true or false,
                    }
                    table.insert(deathTallyOrder, guid)
                end
            end
        end
    end
end

-- Rebuilds the tally from the current party/raid roster with all counts at 0.
function BH:ResetDeathTally()
    wipe(deathTallyData)
    wipe(deathTallyOrder)
    deathTallyManuallyClosed = false
    self:SyncDeathTallyRoster()
    self:UpdateDeathTallyDisplay()
end

function BH:StartDeathTallyTracking()
    deathTallyActive = true
    self:ResetDeathTally()
    if self.deathTallyTicker then self.deathTallyTicker:Play() end
end

function BH:StopDeathTallyTracking()
    deathTallyActive = false
    if self.deathTallyTicker then self.deathTallyTicker:Stop() end
    -- Leave the frame showing the final tally as a summary; it will be reset
    -- and re-shown on the next CHALLENGE_MODE_START rather than hidden now.
end

-- Polling tick (every 0.5s while active): picks up roster changes, then
-- edge-detects each tracked member's UnitIsDeadOrGhost false→true transition.
function BH:PollDeathTally()
    if not deathTallyActive then return end
    self:SyncDeathTallyRoster()

    local changed = false
    for _, unit in ipairs(GetGroupUnits()) do
        if UnitExists(unit) then
            local guid = UnitGUID(unit)
            local entry = guid and deathTallyData[guid]
            if entry then
                local isDead = UnitIsDeadOrGhost(unit) and true or false
                if isDead and not entry.wasDead then
                    entry.count = entry.count + 1
                    changed = true
                end
                entry.wasDead = isDead
            end
        end
    end

    if changed then self:UpdateDeathTallyDisplay() end
end

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

-- Tracks which class buff spellIDs showed buttons on the previous UpdateButtons
-- pass. Used to fire per-buff sound alerts once per "buff becomes missing" transition.
-- Indexed by spellID: classBuffWasNeeded[spellID] = true when the buff was showing.
local classBuffWasNeeded = {}

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
        if not deathTallyActive then
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
-- Set while a rebuild is being held off mid-click (see the guard in
-- BH:UpdateButtons). _updateButtonsDeferrals caps how many times in a row a
-- rebuild may be postponed, so updates can never stall indefinitely.
local _updateButtonsHoverRetry = false
local _updateButtonsDeferrals = 0

function BH:ScheduleUpdateButtons()
    if _updateButtonsPending then return end
    _updateButtonsPending = true
    C_Timer.After(0.2, function()
        _updateButtonsPending = false
        BH:UpdateButtons()
    end)
end

-- Can the player use this item yet? File scope so both the class-buff pass and
-- the consumable pass can share it.
local function MeetsLevelRequirement(itemID)
    local playerLevel = UnitLevel("player")
    local _, _, _, _, minLevel = C_Item.GetItemInfo(itemID)
    -- If item info not loaded yet, assume we can use it (will recheck on next update)
    if not minLevel then return true end
    return playerLevel >= minLevel
end

-- Play the per-buff alert sound for any class buff whose button has just
-- appeared, and forget the ones that no longer need it.
--
-- Takes the set of spellIDs that produced a button this pass. Split out of
-- UpdateButtons because it is edge detection over a set, not button building,
-- and the reasoning about secret auras below deserves to be findable.
function BH:FireClassBuffSounds(spellIDsThisPass)
    -- Class buff sound alert: play once per spellID when its button first appears.
    --
    -- Skipped entirely while aura data is secret. At the moment combat starts,
    -- auras stop being readable a fraction before InCombatLockdown() trips, so a
    -- pass can land in that window, read every buff as missing, and fire alerts
    -- for buffs the player actually has -- which is exactly what it sounded
    -- like: the alerts all going off as a pull began.
    --
    -- The tracking table is left untouched as well, not just the sounds. Marking
    -- everything as "was needed" from an unreadable pass would overwrite the
    -- real pre-combat state, and the next readable pass would then treat buffs
    -- that never went anywhere as freshly missing.
    if not BH.Secrets.AurasAreSecret() then
        local s = self.settings
        for spellID, _ in pairs(spellIDsThisPass) do
            if not classBuffWasNeeded[spellID] then
                classBuffWasNeeded[spellID] = true
                local snd = s and s.classBuffSounds and s.classBuffSounds[spellID]
                if snd and snd ~= "None" and not BH.suppressBuffSounds then
                    PlaySQSound(snd)
                end
            end
        end
        -- Clear tracking for spells no longer showing buttons
        for spellID in pairs(classBuffWasNeeded) do
            if not spellIDsThisPass[spellID] then
                classBuffWasNeeded[spellID] = nil
            end
        end
    end
end

-- Append every class-buff button for this pass: group buffs, self buffs, tank
-- buffs, weapon imbues, Paladin auras, Lightsmith rites and pet summons.
--
-- The largest single piece of what used to be UpdateButtons. Its parameters are
-- deliberately named the same as the locals it used to close over, so the body
-- moved across unchanged -- 385 lines of per-class special cases is exactly the
-- code you do not want to be hand-editing while relocating it.
--
-- Returns the button index it reached, plus the two flags that decide whether
-- the pet and combat-buff frames are shown.
function BH:CollectClassBuffButtons(id, addedItems, class, classBuff_spellIDs_this_pass)
    local hasPetButton = false   -- true if any pet summon button is created this pass
    local hasCombatBuff = false  -- true if any group-wide buff button is created this pass
    local info = BH.classBuffs and BH.classBuffs[class]
    if info then
        if info.auraCheck and info.auras then
            -- Auras cannot be changed in M+ (aura mastery doesn't swap the aura) - skip entirely
            -- Also skip while dead/ghost: the aura persists but the API can't read
            -- player buffs in that state, which would cause a false alert + sound.
            if BH.challengeModeActive or UnitIsDeadOrGhost("player") then
                -- do nothing
            else
            -- Paladin aura logic: scan group paladins to see who has which aura
            local paladinCount = CountClassInGroup("PALADIN")

            local specID = PlayerUtil and PlayerUtil.GetCurrentSpecID and PlayerUtil.GetCurrentSpecID()
            local isHolyPaladin = (specID == 65) -- 65 = Holy Paladin

            -- Check which auras I (the player) have personally activated.
            -- Use GetUnitAuraBySpellID("player", ...) rather than GetPlayerAuraBySpellID —
            -- the latter uses the PLAYER_AURAS filtered system which does not track
            -- passive toggle auras like Devotion Aura in M+. GetUnitAuraBySpellID checks
            -- the full buff list on the unit (same API used for other paladins below).
            local myActiveCount = 0
            local myHasDevotion = false
            local myActiveAuras = {}   -- spellID -> true for auras I have up right now
            for _, auraInfo in ipairs(info.auras) do
                local auraData = BH.Secrets.GetAuraBySpellID("player", auraInfo.spellID)
                local source = BH.Secrets.SafeAuraSourceUnit(auraData)
                if auraData and (not source or UnitIsUnit(source, "player")) then
                    myActiveCount = myActiveCount + 1
                    myActiveAuras[auraInfo.spellID] = true
                    if auraInfo.spellID == 465 then
                        myHasDevotion = true
                    end
                end
            end

            -- Holy Paladins need the Devotion Aura option even when covered by another
            -- paladin, because they may want to activate it for Aura Mastery. So only hide
            -- buttons for Holy if Devotion Aura is already active; hide for other specs as
            -- soon as any aura is active.
            local shouldHide = (isHolyPaladin and myHasDevotion) or (not isHolyPaladin and myActiveCount > 0)

            if not shouldHide then
                -- No blocking aura active - figure out what to show
                -- Check which auras are covered by other paladins in the group
                local coveredByOthers = {}
                local groupSize = GetNumGroupMembers()
                if groupSize > 0 then
                    local isRaid = IsInRaid()
                    for i = 1, groupSize do
                        local unit = isRaid and ("raid" .. i) or ("party" .. i)
                        if not UnitIsUnit(unit, "player") and UnitExists(unit) then
                            local _, unitClass = UnitClass(unit)
                            if unitClass == "PALADIN" then
                                for _, auraInfo in ipairs(info.auras) do
                                    local auraData = BH.Secrets.GetAuraBySpellID(unit, auraInfo.spellID)
                                    local source = BH.Secrets.SafeAuraSourceUnit(auraData)
                                    if source and UnitIsUnit(source, unit) then
                                        coveredByOthers[auraInfo.spellID] = true
                                    end
                                end
                            end
                        end
                    end
                end

                -- Never offer an aura the player already has up. shouldHide above is
                -- an all-or-nothing gate and for Holy it only trips on Devotion, so
                -- without this a Holy Paladin running Concentration Aura was still
                -- shown a button for the Concentration Aura they already had active.
                local showAuras = {}
                if paladinCount >= 2 then
                    -- 2+ paladins: show uncovered auras; for Holy Paladins also always
                    -- include Devotion Aura so it's available for Aura Mastery
                    for _, auraInfo in ipairs(info.auras) do
                        if self:IsEnabled(auraInfo.spellID) and not myActiveAuras[auraInfo.spellID] then
                            local forceForHoly = isHolyPaladin and (auraInfo.spellID == 465)
                            if forceForHoly or not coveredByOthers[auraInfo.spellID] then
                                table.insert(showAuras, auraInfo)
                            end
                        end
                    end
                else
                    -- Solo paladin: show all enabled auras so player can pick
                    for _, auraInfo in ipairs(info.auras) do
                        if self:IsEnabled(auraInfo.spellID) and not myActiveAuras[auraInfo.spellID] then
                            table.insert(showAuras, auraInfo)
                        end
                    end
                end

                for _, auraInfo in ipairs(showAuras) do
                    local icon = GetSpellIcon(auraInfo.spellID)
                    if icon then
                        self.buttons[id] = CreateButton(id, icon, "Cast aura", "spell", auraInfo.spellID, auraInfo.label, nil, nil)
                        classBuff_spellIDs_this_pass[auraInfo.spellID] = true
                        id = id + 1
                    end
                end
            end
            end -- challengeModeActive else

            -- Lightsmith weapon imbue buttons (Rite of Sanctification / Rite of Adjuration)
            -- Lightsmith is a Holy *and* Protection hero tree, and the two Rites are a
            -- choice node inside it, so this gates on knowing the spell and never on
            -- spec. The old `specID == 65` check hid the button from every Protection
            -- Lightsmith paladin. The oil block below keys off the same two spell IDs
            -- and must stay in agreement, or a Rite user gets an oil button competing
            -- for the same main-hand slot.
            -- Not shown in M+ (can't be cast mid-key), not shown while dead.
            if not BH.challengeModeActive and not UnitIsDeadOrGhost("player") then
                local paladinRites = info.weaponImbues or {}
                for _, rite in ipairs(paladinRites) do
                    if rite.spellID and BH.PlayerKnowsSpell(rite.spellID) and self:IsEnabled(rite.spellID) then
                        local hasMH, mhExpiration = GetMainHandEnchantInfo()
                        local needsRefresh = self:NeedsRefresh(rite.spellID, hasMH and mhExpiration or nil)
                        if needsRefresh then
                            local icon = GetSpellIcon(rite.spellID)
                            local spellName = C_Spell.GetSpellName(rite.spellID)
                            if icon and spellName then
                                -- Use a macro so the weapon enchant cursor auto-targets slot 16 (MH)
                                local macroText = "/cast " .. spellName .. "\n/use 16"
                                self.buttons[id] = CreateButton(id, icon, "Apply imbue", "macro", macroText, rite.label, nil, hasMH and mhExpiration or nil)
                                classBuff_spellIDs_this_pass[rite.spellID] = true
                                id = id + 1
                            end
                        end
                        break  -- only one Rite can be known at a time (choice node)
                    end
                end
            end
        else
            -- Pet summoning is always available, even during M+
            do
                local petBuffList = info.spellID and { info } or info
                for _, buffInfo in ipairs(petBuffList) do
                    if buffInfo.petCheck and buffInfo.spellID and self:IsEnabled(buffInfo.spellID) then
                        local specIndex = GetSpecialization()
                        local currentSpecID = specIndex and select(1, GetSpecializationInfo(specIndex))
                        local isMMHunter = (class == "HUNTER") and (currentSpecID == 254)
                        local hasUnbreakableBond = BH.PlayerKnowsSpell(1223323)
                        local skipForMM = isMMHunter and not hasUnbreakableBond
                        if not skipForMM and BH.PlayerKnowsSpell(buffInfo.spellID) and not UnitExists("pet") then
                            local icon = GetSpellIcon(buffInfo.spellID)
                            if icon and (not buffInfo.callPetCheck or icon ~= 132161) then
                                local label = buffInfo.label
                                if buffInfo.callPetCheck and label then
                                    local slot = tonumber(label:match("%d+"))
                                    if slot and C_StableInfo and C_StableInfo.GetStablePetInfo then
                                        local petInfo = C_StableInfo.GetStablePetInfo(slot)
                                        if petInfo and petInfo.name and petInfo.name ~= "" then
                                            label = petInfo.name
                                        end
                                    end
                                end
                                local petBtn = CreateButton(id, icon, "Summon pet", "spell", buffInfo.spellID, label, nil, nil)
                                petBtn.isPetButton = true
                                petBtn:SetParent(BH.petFrame)  -- non-secure frame: Show/Hide allowed in combat
                                self.buttons[id] = petBtn
                                hasPetButton = true
                                classBuff_spellIDs_this_pass[buffInfo.spellID] = true
                                id = id + 1
                            end
                        end
                    end
                end
            end

            -- Normal class buff handling: skip in M+ (buttons not usable mid-key)
            if not BH.challengeModeActive then
            local buffList = info.spellID and { info } or info

            -- Earth Shield button logic (priority-based, max 2 buttons):
            --   Group button: tank unbuffed → target tank (always, even if player is healer);
            --                 else unbuffed other healer → target that healer (never targets self).
            --   Self button:  shown when Elemental Orbit is talented + self-ES missing,
            --                 OR player is healer (no EO) + self-ES missing (group button
            --                 never targets the player themselves, so self needs its own button).
            -- Mark as handled so the tankBuff/selfBuff entries are skipped below.
            local earthShieldHandled = false
            if class == "SHAMAN" and BH.PlayerKnowsSpell(974) and self:IsEnabled(974) then
                earthShieldHandled = true
                local esIcon = GetSpellIcon(974)
                local esSpellName = C_Spell.GetSpellName(974)
                local checkIDs = { 974, 383648 }

                local groupSize = GetNumGroupMembers()
                local playerRole = UnitGroupRolesAssigned("player")
                local playerIsHealer = (playerRole == "HEALER")
                local hasElementalOrbit = BH.PlayerKnowsSpell(ELEMENTAL_ORBIT_SPELL_ID)
                -- Therazane's Resilience: ES has no charges and lasts 60 min → duration-based refresh applies
                local hasTherazanesResilience = BH.PlayerKnowsSpell(THERAZANES_RESILIENCE_SPELL_ID)

                -- ── Group button ──────────────────────────────────────────────
                -- Without EO (1 ES max): suppress if the player's one ES is already
                -- on a group member — no point showing another target button.
                -- NOTE: PlayerHasBuffOnGroupMember skips the player unit, so having
                -- ES on yourself does NOT suppress this button. Self-ES and group-ES
                -- are tracked independently.
                -- With EO (2 ES max): never suppress — player can have self + group.
                --   FindUnbuffedTank then determines if the tank still needs it.
                local esOnGroupMember = PlayerHasBuffOnGroupMember(checkIDs)
                local suppressGroupButton = (not hasElementalOrbit) and esOnGroupMember
                if not suppressGroupButton then
                    local tankName, tankAllBuffed, lowestExpires = FindUnbuffedTank(checkIDs)
                    local needsGroupButton = false
                    if not tankAllBuffed and tankName then
                        -- Tank is missing ES entirely
                        needsGroupButton = true
                    elseif hasTherazanesResilience and tankAllBuffed and tankName and lowestExpires then
                        -- Tank has ES but it may be expiring soon (only relevant with 60-min duration talent)
                        needsGroupButton = self:NeedsRefresh(974, lowestExpires)
                    end
                    if needsGroupButton and esIcon then
                        self.buttons[id] = CreateButton(id, esIcon, "Cast on " .. tankName, "macro",
                            "/cast [@" .. tankName .. "] " .. (esSpellName or ""), "Earth Shield", tankName, nil)
                        classBuff_spellIDs_this_pass[974] = true
                        id = id + 1
                    end
                end

                -- ── Self button ───────────────────────────────────────────────
                -- Show if: Elemental Orbit talented + self-ES missing
                --       OR player is the healer (no EO) + self-ES missing
                --       OR solo (groupSize == 0) + self-ES missing
                -- Note: without EO only one ES can be active, but we still show the self
                -- button so the player can choose to move it to themselves if desired.
                local needsSelfButton = hasElementalOrbit or playerIsHealer or (groupSize == 0)
                if needsSelfButton then
                    local hasSelfES = false
                    local selfESExpiration = nil
                    for _, checkID in ipairs(checkIDs) do
                        -- Check both APIs for maximum reliability across aura types.
                        local auraData = C_UnitAuras.GetUnitAuraBySpellID("player", checkID)
                                      or C_UnitAuras.GetPlayerAuraBySpellID(checkID)
                        if auraData then
                            hasSelfES = true
                            selfESExpiration = auraData.expirationTime
                            break
                        end
                    end
                    -- Show button if: ES missing entirely, OR Therazane's is active and duration is low
                    local showSelfButton = not hasSelfES
                    if hasSelfES and hasTherazanesResilience then
                        showSelfButton = self:NeedsRefresh(974, selfESExpiration)
                    end
                    if showSelfButton and esIcon then
                        self.buttons[id] = CreateButton(id, esIcon, "Cast on self", "macro",
                            "/cast [@player] " .. (esSpellName or ""), "Earth Shield", "Self", nil)
                        classBuff_spellIDs_this_pass[974] = true
                        id = id + 1
                    end
                end
            elseif class == "SHAMAN" then
                earthShieldHandled = true  -- not known/enabled; skip tankBuff/selfBuff entries
            end

            for _, buffInfo in ipairs(buffList) do
                if buffInfo.spellID and self:IsEnabled(buffInfo.spellID) then
                    if buffInfo.earthShield and earthShieldHandled then
                        -- Already handled in multi-shaman Earth Shield batch above
                    elseif buffInfo.healthstoneCheck then
                        -- Warlocks make their own, so they get a button rather
                        -- than the text reminder everyone else gets. Which cast
                        -- depends on whether they are alone -- see
                        -- BH.HealthstoneAction. buffInfo.spellID stays the config
                        -- key so the enable toggle and sound follow the entry
                        -- rather than the spell being offered.
                        local hsID, hsLabel = BH.HealthstoneAction()
                        if hsID and not BH.HasHealthstone() then
                            local icon = GetSpellIcon(hsID)
                            if icon then
                                self.buttons[id] = CreateButton(id, icon, "Make healthstones",
                                    "spell", hsID, hsLabel, nil, nil)
                                classBuff_spellIDs_this_pass[buffInfo.spellID] = true
                                id = id + 1
                            end
                        end
                    elseif buffInfo.weaponRune then
                        -- Death Knight runeforge: a permanent enchant, so this
                        -- reads the equipped weapon rather than an aura or a
                        -- temporary imbue. See WeaponNeedsRune.
                        --
                        -- The action is whichever is useful where the player is
                        -- standing -- the runeforge itself, or Death Gate to
                        -- reach one. buffInfo.spellID stays the config key so
                        -- the enable toggle and sound follow the entry, not the
                        -- spell that happens to be offered.
                        local needsRune, slotLabel = WeaponNeedsRune()
                        local actionID, actionLabel = RuneforgeAction()
                        if needsRune and actionID then
                            local icon = GetSpellIcon(actionID)
                            if icon then
                                self.buttons[id] = CreateButton(id, icon, "Runeforge your weapon",
                                    "spell", actionID, actionLabel, slotLabel, nil)
                                classBuff_spellIDs_this_pass[buffInfo.spellID] = true
                                id = id + 1
                            end
                        end
                    elseif buffInfo.weaponImbue then
                        -- Weapon imbue check (Shaman): show if spell is known but MH enchant is missing or expiring
                        if BH.PlayerKnowsSpell(buffInfo.spellID) then
                            local hasMH, mhExpiration = GetMainHandEnchantInfo()
                            local needsRefresh = self:NeedsRefresh(buffInfo.spellID, hasMH and mhExpiration or nil)
                            if needsRefresh then
                                local icon = GetSpellIcon(buffInfo.spellID)
                                if icon then
                                    self.buttons[id] = CreateButton(id, icon, "Apply imbue", "spell", buffInfo.spellID, buffInfo.label, nil, hasMH and mhExpiration or nil)
                                    classBuff_spellIDs_this_pass[buffInfo.spellID] = true
                                    id = id + 1
                                end
                            end
                        end
                    elseif buffInfo.tankBuff then
                        -- Tank-targeted buff (e.g. Earth Shield): show if spell is known and a tank needs it
                        if BH.PlayerKnowsSpell(buffInfo.spellID) then
                            local checkIDs = buffInfo.buffVariants or { buffInfo.spellID }
                            local tankName, allBuffed, lowestExpires = FindUnbuffedTank(checkIDs)
                            if not allBuffed and tankName then
                                -- Tank is completely missing the buff
                                local icon = GetSpellIcon(buffInfo.spellID)
                                if icon then
                                    local spellName = C_Spell.GetSpellName(buffInfo.spellID)
                                    self.buttons[id] = CreateButton(id, icon, "Cast on " .. tankName, "macro",
                                        "/cast [@" .. tankName .. "] " .. (spellName or ""), buffInfo.label, buffInfo.header, nil)
                                    classBuff_spellIDs_this_pass[buffInfo.spellID] = true
                                    id = id + 1
                                end
                            elseif allBuffed and lowestExpires and tankName then
                                -- All tanks have it, but check min duration
                                local needsRefresh = self:NeedsRefresh(buffInfo.spellID, lowestExpires)
                                if needsRefresh then
                                    local icon = GetSpellIcon(buffInfo.spellID)
                                    if icon then
                                        local spellName = C_Spell.GetSpellName(buffInfo.spellID)
                                        self.buttons[id] = CreateButton(id, icon, "Cast on " .. tankName, "macro",
                                            "/cast [@" .. tankName .. "] " .. (spellName or ""), buffInfo.label, buffInfo.header, lowestExpires)
                                        classBuff_spellIDs_this_pass[buffInfo.spellID] = true
                                        id = id + 1
                                    end
                                end
                            end
                        end
                    elseif buffInfo.selfBuff then
                        -- Self-buff check (e.g. Rogue poisons, Earth Shield self): show if spell is known but buff is missing or expiring
                        -- Use UnitHasBuff("player") rather than PlayerHasBuff: the latter uses
                        -- GetPlayerAuraBySpellID which doesn't detect toggle/stance auras like
                        -- Lightning Shield or Water Shield (same issue as Devotion Aura on paladins).
                        if BH.PlayerKnowsSpell(buffInfo.spellID) then
                            local checkIDs = buffInfo.buffVariants or { buffInfo.spellID }
                            local hasBuff, buffExpiration = UnitHasBuff("player", checkIDs)
                            -- When buff is active: use expiration time, or 0 if nil (permanent/charge-based
                            -- auras like Lightning Shield return nil expiration, not 0).
                            -- When buff is missing: pass nil so NeedsRefresh knows it's absent.
                            local expArg = hasBuff and (buffExpiration or 0) or nil
                            local needsRefresh = self:NeedsRefresh(buffInfo.spellID, expArg)
                            if needsRefresh then
                                local icon = GetSpellIcon(buffInfo.spellID)
                                if icon then
                                    self.buttons[id] = CreateButton(id, icon, "Apply buff", "spell", buffInfo.spellID, buffInfo.label, buffInfo.header, expArg)
                                    classBuff_spellIDs_this_pass[buffInfo.spellID] = true
                                    id = id + 1
                                end
                            end
                        end
                    elseif buffInfo.petCheck then
                        -- handled above; always available even in M+
                    elseif buffInfo.healerOnly then
                        -- Healer-only buff: find first unbuffed healer
                        local healerName, allBuffed = FindUnbuffedHealer(buffInfo.spellID)
                        if not allBuffed and healerName then
                            local icon = GetSpellIcon(buffInfo.spellID)
                            if icon then
                                local spellName = C_Spell.GetSpellName(buffInfo.spellID)
                                self.buttons[id] = CreateButton(id, icon, "Cast on " .. healerName, "macro",
                                    "/cast [@" .. healerName .. "] " .. (spellName or ""), nil, nil, nil)
                                classBuff_spellIDs_this_pass[buffInfo.spellID] = true
                                id = id+1
                            end
                        end
                    else
                        -- Check all group/raid members for the buff
                        local checkIDs = buffInfo.buffVariants or buffInfo.spellID
                        local needsBuff = GroupNeedsBuff(checkIDs)
                        if needsBuff then
                            local castID = buffInfo.castSpellID or buffInfo.spellID
                            local icon = GetSpellIcon(castID)
                            if icon then
                                local cbBtn = CreateButton(id, icon, "Cast buff", "spell", castID, nil, nil, nil)
                                cbBtn.isCombatBuff = true
                                cbBtn:SetParent(BH.combatBuffFrame)  -- stays visible in combat
                                -- Mirror the pet-button behaviour: hide once the buff lands on the
                                -- player, reappear if the player loses it (e.g. dies mid-fight).
                                -- RegisterStateDriver runs in WoW's secure env – never blocked.
                                -- Only register the state driver when the player doesn't
                                -- already have the buff.  If the player has it (button shown
                                -- because a group member is missing it), skip the driver so
                                -- the button stays visible in combat instead of hiding the
                                -- moment combat starts just because [buff:X] is already true.
                                local playerHasBuff = UnitHasBuff("player", buffInfo.buffVariants or buffInfo.spellID)
                                local buffName = C_Spell.GetSpellName(castID)
                                -- buffName can be "" (truthy in Lua) when spell data isn't cached yet,
                                -- which would produce "[combat,buff:]hide;show" — an empty aura name.
                                -- Also, the state-driver conditional parser uses ":" as its own
                                -- key/value delimiter, so names containing a colon (e.g. Priest's
                                -- "Power Word: Fortitude") break parsing with "Unknown macro option:
                                -- buff" — confirmed via in-game testing. Skip the auto-hide driver
                                -- for those names; the button just won't self-hide mid-combat once
                                -- buffed (it still gets removed on the next normal refresh).
                                if buffName and buffName ~= "" and not buffName:find(":", 1, true)
                                    and not playerHasBuff then
                                    RegisterStateDriver(cbBtn, "visibility",
                                        "[combat,buff:" .. buffName .. "]hide;show")
                                end
                                self.buttons[id] = cbBtn
                                hasCombatBuff = true
                                classBuff_spellIDs_this_pass[buffInfo.spellID] = true
                                id = id+1
                            end
                        end
                    end
                end
            end
            end  -- not challengeModeActive
        end
    end
    return id, hasPetButton, hasCombatBuff
end

-- Append the food, flask and oil buttons for this pass.
--
-- Takes the next free button index and the set of items already added, and
-- returns the index it reached. Threading `id` through the return rather than
-- sharing an upvalue is what lets this live outside UpdateButtons at all.
--
-- Each of the three walks the configured list and looks the item up in the bag
-- snapshot; see BH:RebuildBagCache for why that is not a bag walk.
function BH:CollectConsumableButtons(id, addedItems, class)
    -- Food, flask and augment rune are the same thing mechanically: an item in
    -- the bags that applies a timed buff. Only the buff lookup and the button
    -- caption differ, so they run through one loop rather than three
    -- near-identical blocks. (Oil stays separate below -- it applies to weapon
    -- slots and can produce two buttons.)
    --
    -- Each walks the configured list and looks the item up in the bag snapshot,
    -- so the work is proportional to how many consumables are configured rather
    -- than to how full the player's bags are -- and this runs on every
    -- UNIT_AURA. See BH:RebuildBagCache.
    --
    -- Side effect worth knowing: buttons appear in configured order rather than
    -- bag order, which is at least stable when items move around.
    local simpleConsumables = {
        { key = "food",        caption = "Use food",         hasBuff = HasFoodBuff },
        { key = "flask",       caption = "Use flask",        hasBuff = HasFlaskBuff },
        { key = "augmentRune", caption = "Use augment rune", hasBuff = HasAugmentRuneBuff },
    }

    for _, cat in ipairs(simpleConsumables) do
        local list = BH.consumables and BH.consumables[cat.key]
        if list then
            local hasBuff, expiration = cat.hasBuff()
            for _, itemID in ipairs(list) do
                local entry = not addedItems[itemID] and BH:GetBagEntry(itemID)
                if entry and self:IsEnabled(itemID) and MeetsLevelRequirement(itemID) then
                    -- (expiration or 0) rather than plain expiration: a
                    -- permanent buff -- hearty food, for instance -- reports no
                    -- expiration, and "hasBuff and nil or nil" collapses to nil,
                    -- which NeedsRefresh reads as the buff being absent.
                    local exp = hasBuff and (expiration or 0) or nil
                    if self:NeedsRefresh(itemID, exp) then
                        local icon = C_Item.GetItemIconByID(itemID)
                        self.buttons[id] = CreateButton(id, icon, cat.caption, "item", itemID,
                            nil, nil, exp, entry.link, entry.quality, entry.count)
                        addedItems[itemID] = true
                        id = id + 1
                    end
                end
            end
        end
    end

    -- oil: check for specific item IDs in bags, separate MH and OH buttons
    -- Skip oil buttons for any paladin with a Lightsmith Rite talent -- the Rite occupies
    -- the same main-hand enchant slot an oil would, so offering both competes for one slot.
    -- Gated on knowing the spell, not on spec: Lightsmith is Holy and Protection both.
    local hasLightsmithRite = false
    if class == "PALADIN" then
        hasLightsmithRite = BH.PlayerKnowsSpell(433568) or BH.PlayerKnowsSpell(433583)
    end
    if not hasLightsmithRite and BH.consumables and BH.consumables.oil then
        local hasMH, mhExpiration = GetMainHandEnchantInfo()
        local hasOH, ohExpiration = GetOffHandEnchantInfo()
        local hasOHWeapon = HasOffHandWeapon()
        
        -- Configured list rather than a bag walk; see the food block above.
        for _, itemID in ipairs(BH.consumables.oil) do
            local entry = BH:GetBagEntry(itemID)
            if entry and self:IsEnabled(itemID) and MeetsLevelRequirement(itemID) then
                local icon = C_Item.GetItemIconByID(itemID)
                -- Main hand oil button (show if missing or below min duration)
                local needsMH = self:NeedsRefresh(itemID, hasMH and mhExpiration or nil)
                if needsMH and not addedItems[itemID .. "_MH"] then
                    self.buttons[id] = CreateButton(id, icon, "Apply oil (MH)", "oil",
                        {itemID = itemID, slot = 16}, nil, "MH", hasMH and mhExpiration or nil,
                        entry.link, entry.quality, entry.count)
                    addedItems[itemID .. "_MH"] = true
                    id = id+1
                end
                -- Off hand oil button (show if missing or below min duration)
                if hasOHWeapon then
                    local needsOH = self:NeedsRefresh(itemID, hasOH and ohExpiration or nil)
                    if needsOH and not addedItems[itemID .. "_OH"] then
                        self.buttons[id] = CreateButton(id, icon, "Apply oil (OH)", "oil",
                            {itemID = itemID, slot = 17}, nil, "OH", hasOH and ohExpiration or nil,
                            entry.link, entry.quality, entry.count)
                        addedItems[itemID .. "_OH"] = true
                        id = id+1
                    end
                end
            end
        end
    end
    return id
end

-- Position the buttons built this pass, and size the frame around them.
--
-- Split out of UpdateButtons purely to make that function readable: this is
-- ~110 lines of pure geometry that touches nothing but self.buttons and the
-- layout settings, so it had no business sitting inline among the code that
-- decides which buttons should exist.
function BH:LayoutButtons(numButtons)
    local size = (self.settings and self.settings.buttonSize) or 36
    local spacing = (self.settings and self.settings.buttonSpacing) or 5
    local labelHeight = 26
    local headerHeight = 12

    local grow = (self.settings and self.settings.growDirection) or "RIGHT"
    local layout = (self.settings and self.settings.layoutDirection) or "HORIZONTAL"
    
    -- Check if any button has a header (for consistent alignment)
    local anyHasHeader = false
    for i=1,numButtons do
        if self.buttons[i].header then
            anyHasHeader = true
            break
        end
    end
    
    -- Calculate total size for centering/outward
    local totalWidth = numButtons * size + (numButtons - 1) * spacing
    local totalBtnHeight = size + labelHeight + (anyHasHeader and headerHeight or 0)
    -- Vertical layout: label is beside icon, so row height is just icon + header
    local vertBtnHeight = size + (anyHasHeader and headerHeight or 0)
    local totalHeight = numButtons * totalBtnHeight + (numButtons - 1) * spacing
    local totalVertHeight = numButtons * vertBtnHeight + (numButtons - 1) * spacing
    
    for i=1,numButtons do
        local btn = self.buttons[i]
        local hasHeader = btn.header ~= nil
        
        if layout == "VERTICAL" then
            -- Vertical: icon is the button, label text floats to the right
            btn:SetSize(size, size + (anyHasHeader and headerHeight or 0))
            btn.icon:SetSize(size, size)
            local iconOffset = anyHasHeader and -headerHeight or 0
            btn.icon:ClearAllPoints()
            btn.icon:SetPoint("TOPLEFT", btn, "TOPLEFT", 0, iconOffset)
            if hasHeader then
                btn.header:ClearAllPoints()
                btn.header:SetPoint("BOTTOM", btn.icon, "TOP", 0, 1)
                btn.header:SetWidth(0)  -- unconstrained
            end
            btn.label:ClearAllPoints()
            btn.label:SetPoint("LEFT", btn.icon, "RIGHT", 4, 0)
            btn.label:SetWidth(80)
            btn.label:SetJustifyH("LEFT")
        else
            -- Horizontal: icon on top, label below (original behavior)
            btn:SetSize(size, totalBtnHeight)
            btn.icon:SetSize(size, size)
            local iconOffset = anyHasHeader and -headerHeight or 0
            btn.icon:ClearAllPoints()
            btn.icon:SetPoint("TOP", btn, "TOP", 0, iconOffset)
            if hasHeader then
                btn.header:ClearAllPoints()
                btn.header:SetPoint("TOP", btn, "TOP", 0, 0)
                btn.header:SetWidth(0)  -- unconstrained
            end
            btn.label:ClearAllPoints()
            btn.label:SetPoint("TOP", btn.icon, "BOTTOM", (self.settings and self.settings.buttonLabelOffsetX) or 0, (self.settings and self.settings.buttonLabelOffsetY) or -2)
            btn.label:SetWidth(size)
            btn.label:SetJustifyH("CENTER")
        end
        
        -- Show/hide label based on setting
        if BH.settings.showLabelText ~= false then
            btn.label:Show()
        else
            btn.label:Hide()
        end
        
        -- Position buttons inside the frame based on grow direction
        btn:ClearAllPoints()
        local idx = i - 1
        
        if layout == "VERTICAL" then
            local yStep = vertBtnHeight + spacing
            if grow == "UP" then
                btn:SetPoint("BOTTOMLEFT", self.frame, "BOTTOMLEFT", 0, idx * yStep)
            elseif grow == "OUTWARD" then
                local yOfs = totalVertHeight / 2 - idx * yStep - vertBtnHeight / 2
                btn:SetPoint("LEFT", self.frame, "LEFT", 0, yOfs)
            else -- DOWN (default)
                btn:SetPoint("TOPLEFT", self.frame, "TOPLEFT", 0, -(idx * yStep))
            end
        else
            local xStep = size + spacing
            if grow == "LEFT" then
                btn:SetPoint("TOPRIGHT", self.frame, "TOPRIGHT", -(idx * xStep), 0)
            elseif grow == "OUTWARD" then
                local xOfs = -totalWidth / 2 + idx * xStep + size / 2
                btn:SetPoint("TOP", self.frame, "TOP", xOfs, 0)
            else -- RIGHT (default)
                btn:SetPoint("TOPLEFT", self.frame, "TOPLEFT", idx * xStep, 0)
            end
        end
        btn:Show()
    end

    -- Resize the frame to encompass all buttons so the drag handle stays clear
    if numButtons > 0 then
        if layout == "VERTICAL" then
            self.frame:SetSize(size, totalVertHeight)
        else
            self.frame:SetSize(totalWidth, totalBtnHeight)
        end
    else
        self.frame:SetSize(1, 1)
    end
end

function BH:UpdateButtons()
    if not IsLoggedIn() then return end  -- avoid running early when API is incomplete
    if InCombatLockdown() then
        -- Secure buttons cannot be created or changed under lockdown, but the
        -- plain reminder frames can be, and refusing to update them here is
        -- what made Beacon and Earth Shield disappear for the whole pull.
        self:UpdateAllReminders()
        return
    end

    -- Don't tear the buttons down in the middle of a click.
    --
    -- This function is driven by UNIT_AURA, which fires for every unit in the
    -- group on every aura change, so in a group it runs more or less constantly
    -- on its 0.2s debounce. The teardown below hides, unanchors and reparents
    -- every button; if that lands between the player's mouse-down and mouse-up
    -- the click is swallowed and the spell never goes off. Worse, buttons are
    -- recycled from a pool in order, so the frame under the cursor can come
    -- back as a different action entirely.
    --
    -- The window that matters is only while a mouse button is actually held.
    -- Deferring on hover alone is wrong: after clicking a button the cursor
    -- naturally stays on it, so the rebuild never ran and the button the player
    -- just used sat there stale until they moved the mouse away.
    --
    -- The retry count is capped as a backstop, so a stuck mouse button or an
    -- input state we did not anticipate can never stall updates indefinitely.
    if not self.unlockMode and IsMouseButtonDown and IsMouseButtonDown()
        and _updateButtonsDeferrals < 6 then
        for _, btn in ipairs(self.buttons) do
            if btn:IsShown() and btn:IsMouseOver() then
                if not _updateButtonsHoverRetry then
                    _updateButtonsHoverRetry = true
                    _updateButtonsDeferrals = _updateButtonsDeferrals + 1
                    C_Timer.After(0.1, function()
                        _updateButtonsHoverRetry = false
                        BH:UpdateButtons()
                    end)
                end
                return
            end
        end
    end
    _updateButtonsDeferrals = 0

    -- clear existing buttons - return to pool so frames are reused next UpdateButtons call
    for i,btn in ipairs(self.buttons) do
        btn:Hide()
        btn:ClearAllPoints()
        btn:SetScript("OnUpdate", nil)
        -- Stop any glow before the frame goes back in the pool: it would
        -- otherwise still be glowing when reused for a different reminder.
        ns.Glow.Hide(btn)
        btn.expirationTime = nil
        btn.isCombatBuff = nil
        UnregisterStateDriver(btn, "visibility")  -- remove any per-button combat-buff state driver
        btn:SetParent(nil)
        table.insert(SQ_BUTTON_POOL, btn)
    end
    self.buttons = {}
    -- Clean up dummy preview buttons
    if self.unlockDummyBtns then
        for _, db in ipairs(self.unlockDummyBtns) do db:Hide(); db:SetParent(nil) end
        self.unlockDummyBtns = nil
    end

    local id = 1
    local addedItems = {}  -- track items already added to avoid duplicates
    -- Class buffs first, so they land in the centre of the row.
    -- Show only when someone in the group is missing the buff
    -- Track which spellIDs generated buttons this pass (for per-buff sound alerts)
    local classBuff_spellIDs_this_pass = {}
    local _, class = UnitClass("player")
    local hasPetButton, hasCombatBuff
    id, hasPetButton, hasCombatBuff =
        self:CollectClassBuffButtons(id, addedItems, class, classBuff_spellIDs_this_pass)

    self:FireClassBuffSounds(classBuff_spellIDs_this_pass)

    -- Symbiotic Relationship button, food/flask/oil consumable buttons, and reminder
    -- frames only show when in a valid instance (or preview mode), not in open world.
    if ShouldShowButtons() then

    -- Symbiotic Relationship button for Druids with the talent
    -- Guardian Druid: cast on healer | Restoration Druid: cast on tank
    if class == "DRUID" and BH.PlayerKnowsSpell(SYMBIOTIC_CAST_SPELL_ID) then
        -- Check if player already has the buff
        local hasBuff = C_UnitAuras.GetPlayerAuraBySpellID(SYMBIOTIC_AURA_SPELL_ID)
        if not hasBuff then
            local specID = PlayerUtil and PlayerUtil.GetCurrentSpecID and PlayerUtil.GetCurrentSpecID()
            local targetRole = nil
            if specID == 104 then       -- Guardian
                targetRole = "HEALER"
            elseif specID == 105 then   -- Restoration
                targetRole = "TANK"
            end
            if targetRole then
                -- Find a group member with the matching role
                local targetName = nil
                local groupSize = GetNumGroupMembers()
                local isRaid = IsInRaid()
                for i = 1, groupSize do
                    local unit = isRaid and ("raid" .. i) or ("party" .. i)
                    if UnitExists(unit) and not UnitIsUnit(unit, "player")
                        and not UnitIsDeadOrGhost(unit) and UnitIsConnected(unit) then
                        if UnitGroupRolesAssigned(unit) == targetRole then
                            targetName = UnitName(unit)
                            break
                        end
                    end
                end
                if targetName then
                    local icon = GetSpellIcon(SYMBIOTIC_CAST_SPELL_ID)
                    if icon then
                        local spellName = C_Spell.GetSpellName(SYMBIOTIC_CAST_SPELL_ID)
                        self.buttons[id] = CreateButton(id, icon, "Cast on " .. targetName, "macro",
                            "/cast [@" .. targetName .. "] " .. (spellName or ""), nil, nil, nil)
                        id = id + 1
                    end
                end
            end
        end
    end

    -- Emerald Coach's Whistle button – show if trinket is equipped and coaching needs refreshing
    do
        local hasWhistle = GetInventoryItemID("player", 13) == COACH_WHISTLE_ITEM_ID
                        or GetInventoryItemID("player", 14) == COACH_WHISTLE_ITEM_ID
        local coachExp = hasWhistle and GetCoachedAllyExpiration()
        local needsCoach = hasWhistle and self:NeedsRefresh(COACH_WHISTLE_ITEM_ID, coachExp)
        if needsCoach then
            -- Find a real player party member to coach (prefer DAMAGER, then HEALER, then TANK)
            local targetName = nil
            local groupSize = GetNumGroupMembers()
            local isRaid = IsInRaid()
            for _, role in ipairs({"DAMAGER", "HEALER", "TANK"}) do
                for i = 1, groupSize do
                    local unit = isRaid and ("raid" .. i) or ("party" .. i)
                    if UnitExists(unit) and not UnitIsUnit(unit, "player")
                        and UnitIsPlayer(unit)
                        and not UnitIsDeadOrGhost(unit) and UnitIsConnected(unit) then
                        if UnitGroupRolesAssigned(unit) == role then
                            targetName = UnitName(unit)
                            break
                        end
                    end
                end
                if targetName then break end
            end
            if targetName then
                local icon = C_Item.GetItemIconByID(COACH_WHISTLE_ITEM_ID)
                if icon then
                    self.buttons[id] = CreateButton(id, icon, "Coach: " .. targetName, "macro",
                        "/use [@" .. targetName .. "] Emerald Coach's Whistle", nil, nil, nil)
                    id = id + 1
                end
            end
        end
    end

    id = self:CollectConsumableButtons(id, addedItems, class)

    else
        -- Not in a valid instance: hide instance-only reminder frames
        if self.beaconReminderFrame then self.beaconReminderFrame:Hide() end
        if self.earthShieldReminderFrame then self.earthShieldReminderFrame:Hide() end
        if self.symbioticReminderFrame then self.symbioticReminderFrame:Hide() end
    end -- ShouldShowButtons

    self:LayoutButtons(id - 1)

    -- show/hide main frame depending on buttons
    if self.unlockMode then
        -- In preview mode, hide any real buttons and show 3 dummy non-interactable buttons
        for i, btn in ipairs(self.buttons) do
            -- Unregister any secure state drivers that might override Hide()
            UnregisterStateDriver(btn, "visibility")
            btn:Hide()
            btn:SetParent(nil)
        end
        self.buttons = {}
        -- Also hide the overlay frames (combat buff, pet) so they don't show
        -- orphaned buttons that might not have been fully reparented
        if BH.petFrame then BH.petFrame:Hide() end
        if BH.combatBuffFrame then BH.combatBuffFrame:Hide() end
        local size = (self.settings and self.settings.buttonSize) or 36
        local spacing = (self.settings and self.settings.buttonSpacing) or 5
        local layout = (self.settings and self.settings.layoutDirection) or "HORIZONTAL"
        local grow = (self.settings and self.settings.growDirection) or "RIGHT"
        local showLabel = (self.settings and self.settings.showLabelText ~= false)
        local dummyIcons = {
            "Interface\\Icons\\INV_Misc_QuestionMark",
            "Interface\\Icons\\INV_Misc_Gear_01",
            "Interface\\Icons\\Spell_Nature_Rejuvenation",
        }
        -- Clean up old dummy buttons
        if self.unlockDummyBtns then
            for _, db in ipairs(self.unlockDummyBtns) do db:Hide(); db:SetParent(nil) end
        end
        -- Held in a local as well as on self: the other branches of this function
        -- clear self.unlockDummyBtns to nil, so only the local is known non-nil here.
        local dummyBtns = {}
        self.unlockDummyBtns = dummyBtns
        local labelHeight = showLabel and 14 or 0
        local btnHeight = size + labelHeight
        for i = 1, 3 do
            local db = CreateFrame("Frame", nil, self.frame)
            db:SetSize(size, btnHeight)
            db:SetFrameStrata("MEDIUM")
            db.icon = db:CreateTexture(nil, "ARTWORK")
            db.icon:SetSize(size, size)
            db.icon:SetPoint("TOP", db, "TOP", 0, 0)
            db.icon:SetTexture(dummyIcons[i])
            db.icon:SetDesaturated(true)
            db.icon:SetAlpha(0.5)
            if showLabel then
                db.label = db:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                db.label:SetPoint("TOP", db.icon, "BOTTOM", 0, -2)
                db.label:SetWidth(size)
                db.label:SetJustifyH("CENTER")
                db.label:SetText("Preview")
                db.label:SetTextColor(0.6, 0.6, 0.6)
            end
            local idx = i - 1
            db:ClearAllPoints()
            if layout == "VERTICAL" then
                local yStep = btnHeight + spacing
                if grow == "UP" then
                    db:SetPoint("BOTTOMLEFT", self.frame, "BOTTOMLEFT", 0, idx * yStep)
                else
                    db:SetPoint("TOPLEFT", self.frame, "TOPLEFT", 0, -(idx * yStep))
                end
            else
                local xStep = size + spacing
                if grow == "LEFT" then
                    db:SetPoint("TOPRIGHT", self.frame, "TOPRIGHT", -(idx * xStep), 0)
                else
                    db:SetPoint("TOPLEFT", self.frame, "TOPLEFT", idx * xStep, 0)
                end
            end
            db:Show()
            table.insert(dummyBtns, db)
        end
        if layout == "VERTICAL" then
            self.frame:SetSize(size, 3 * btnHeight + 2 * spacing)
        else
            self.frame:SetSize(3 * size + 2 * spacing, btnHeight)
        end
        self.frame:Show()
    elseif id == 1 then
        -- No buttons and not previewing - clean up and hide
        if self.unlockDummyBtns then
            for _, db in ipairs(self.unlockDummyBtns) do db:Hide(); db:SetParent(nil) end
            self.unlockDummyBtns = nil
        end
        self.frame:Hide()
        BH.petFrame:Hide()
        BH.combatBuffFrame:Hide()
    else
        -- Real buttons exist - clean up dummies
        if self.unlockDummyBtns then
            for _, db in ipairs(self.unlockDummyBtns) do db:Hide(); db:SetParent(nil) end
            self.unlockDummyBtns = nil
        end
        self.frame:Show()
        if hasPetButton then BH.petFrame:Show() else BH.petFrame:Hide() end
        if hasCombatBuff then BH.combatBuffFrame:Show() else BH.combatBuffFrame:Hide() end
    end

    -- The green tint on this frame is applied by SetAllFramesPreview along
    -- with every other movable frame. It used to be duplicated here, which
    -- meant two overlay textures stacked on the same frame.

    self:UpdateAllReminders()
end

-- Hide the reminders that are not worth showing in combat. There is no matching
-- "show" call: on the way out of combat UpdateAllReminders re-evaluates every
-- frame on its merits, which is the same path used everywhere else.
function BH:HideCombatUnsafeReminders()
    for _, def in ipairs(BH.REMINDERS) do
        if not def.combatSafe then
            local frame = self[def.key .. "ReminderFrame"]
            if frame then frame:Hide() end
        end
    end
end

-- Whether a reminder frame should take the mouse. Every reminder's show path
-- goes through this rather than repeating `unlockMode or not locked` eleven
-- times, which is what let the pet reminder quietly disagree with the other ten.
--
-- The combat clause is the BigWigs click-through pattern: now that combat-safe
-- reminders stay up during a pull, a 340px banner sitting over the action bars
-- must not be able to swallow a click, and there is nothing useful to click it
-- for mid-fight anyway.
function BH:ReminderMouseEnabled(locked)
    if self.unlockMode then return true end   -- dragging is the whole point
    if locked then return false end
    if InCombatLockdown() then return false end
    return true
end

-- Every plain (non-secure) reminder frame, refreshed in one place.
--
-- Split out of UpdateButtons because UpdateButtons returns early under
-- InCombatLockdown -- it has to, it owns the secure buttons -- and that early
-- return was taking the reminder frames down with it. These frames have no
-- secure children, so they can be updated freely in combat; each individual
-- Update*Reminder decides for itself whether it is combat-safe, via
-- ShouldShowReminders versus ShouldShowButtons.
-- Clear a reminder the moment the player casts the thing it is asking for.
--
-- Needed because the three combat-safe reminders detect *absence* of a buff,
-- and in combat auras are secret: applying the buff is invisible to us, so the
-- reminder would sit there for the rest of the fight. The player's own cast is
-- not an aura read, so it still gets through, and it is decisive -- if you just
-- cast Earth Shield, you no longer need reminding to cast Earth Shield.
--
-- Optimistic by design. If the cast was wasted (wrong target, immediately
-- dispelled) the next readable pass puts the reminder straight back.
function BH:OnReminderSpellcast(spellID)
    -- Only the player's own cast reaches here, and that spellID is readable --
    -- but launder it anyway so a future secret one degrades to "no match"
    -- rather than throwing on the comparison below.
    local id = BH.Secrets.SafeNumber(spellID, nil)
    if not id then return end

    for _, beaconID in ipairs(BEACON_AURA_IDS) do
        if id == beaconID then
            local needed = self.beaconsNeededLast or 1
            self.beaconsBelieved = math.min(needed, (self.beaconsBelieved or 0) + 1)
            self:UpdateBeaconReminder()
            return
        end
    end

    for _, esID in ipairs(ES_AURA_IDS) do
        if id == esID then
            local needed = self.esNeededLast or 1
            self.esBelieved = math.min(needed, (self.esBelieved or 0) + 1)
            self:UpdateEarthShieldReminder()
            return
        end
    end

    if id == SYMBIOTIC_CAST_SPELL_ID then
        if self.symbioticReminderFrame and not self.unlockMode then
            self.symbioticReminderFrame:Hide()
        end
    end
end

-- How many of the tracked units are still alive and present.
local function CountLivingTracked(guids)
    if not guids or #guids == 0 then return 0 end
    local wanted = {}
    for _, guid in ipairs(guids) do wanted[guid] = true end
    local n = 0
    for _, unit in ipairs(GetGroupUnits()) do
        if UnitExists(unit) and not UnitIsDeadOrGhost(unit) then
            local guid = UnitGUID(unit)
            if guid and wanted[guid] then n = n + 1 end
        end
    end
    return n
end

-- Bring a combat-safe reminder back when its buff is lost while auras are secret.
--
-- OnReminderSpellcast covers the buff being applied. This covers the other
-- direction, which is the harder half: once auras are unreadable we cannot see
-- a beacon or Earth Shield fall off, so without this the reminder would stay
-- hidden for the rest of the fight after one cast.
--
-- The readable signal we do have is death. A beacon or Earth Shield is lost
-- when its target dies, and UnitIsDeadOrGhost stays readable when the aura does
-- not -- the same reasoning the M+ Death Tally uses. So each readable pass
-- records which GUIDs carry the buff, and this checks whether enough of them
-- are still standing.
--
-- What this still cannot see: Earth Shield running out of charges, a dispel, or
-- Symbiotic Relationship expiring on its timer. There is no readable signal for
-- any of those while auras are secret.
function BH:PollBlindReminderLoss()
    if not InCombatLockdown() then return end
    if not BH.Secrets.AurasAreSecret() then return end
    if self.unlockMode then return end

    local changed = false

    -- The clamp on *AliveLast below matters: a battle rez brings the unit back
    -- but not the beacon, so the tracked count must only ever fall.
    -- Beacons. Note this counts *drops*, not absolutes: a beacon cast while
    -- blind lands on a unit we cannot identify, so it never joins beaconedGUIDs
    -- and an absolute comparison would read as "still missing" and re-show the
    -- reminder the instant it was correctly hidden. Only an actual fall in the
    -- number of living tracked units means a beacon was lost.
    if self.beaconedGUIDs and #self.beaconedGUIDs > 0 then
        local aliveNow  = CountLivingTracked(self.beaconedGUIDs)
        local alivePrev = self.beaconedAliveLast or aliveNow
        if aliveNow < alivePrev then
            self.beaconsBelieved = math.max(0, (self.beaconsBelieved or 0) - (alivePrev - aliveNow))
            changed = true
        end
        self.beaconedAliveLast = math.min(alivePrev, aliveNow)
    end

    if self.esGUIDs and #self.esGUIDs > 0 then
        local aliveNow  = CountLivingTracked(self.esGUIDs)
        local alivePrev = self.esAliveLast or aliveNow
        if aliveNow < alivePrev then
            self.esBelieved = math.max(0, (self.esBelieved or 0) - (alivePrev - aliveNow))
            changed = true
        end
        self.esAliveLast = math.min(alivePrev, aliveNow)
    end

    -- Let the normal update path decide what to show; it reads the same
    -- believed counts, so there is one place that owns the decision.
    if changed then
        self:UpdateBeaconReminder()
        self:UpdateEarthShieldReminder()
    end
end

-- Ticker for the above. Same AnimationGroup idiom as the Battle Res Counter and
-- Death Tally -- cheaper than an OnUpdate, and the handler bails immediately
-- unless we are actually blind, so out of combat this costs a function call
-- every half second.
do
    -- Deliberately NOT parented to BH.frame: that frame is hidden on entering
    -- combat, and an AnimationGroup on a hidden frame stops running -- which
    -- would kill this ticker at exactly the moment it becomes useful. This host
    -- is an empty frame that draws nothing and is never hidden.
    local host = CreateFrame("Frame", nil, UIParent)
    host:SetSize(1, 1)
    host:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 0, 0)
    host:Show()
    BH.tickerHost = host

    local ticker = host:CreateAnimationGroup()
    ticker:SetLooping("REPEAT")
    ticker:SetScript("OnLoop", function() BH:PollBlindReminderLoss() end)
    local anim = ticker:CreateAnimation()
    anim:SetDuration(0.5)
    ticker:Play()
    BH.blindReminderTicker = ticker
end

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

function BH:UpdateBagReminder()
    -- Oil is suppressed for Holy Paladins running a Lightsmith rite, since the
    -- imbue replaces oils entirely for them. Handled by IsEnabled on the items
    -- themselves rather than here, so it applies wherever the list is read.
    local frame = self:ReminderGate(BH.REMINDERS_BY_KEY.bags)
    if not frame then return end

    local missing = MissingBagCategories()
    if #missing == 0 then
        frame:Hide()
        return
    end

    if self.bagsReminderText then
        self.bagsReminderText:SetText("NO " .. JoinMissing(missing) .. " IN BAGS")
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



-- ============================================================================
-- Raid Tools Module

-- World marker colors (indices 1-8, matching Blizzard raid marker order)
local WORLD_MARKER_COLORS = {
    [1] = { 1.00, 0.82, 0.00 },  -- Star (Yellow)
    [2] = { 1.00, 0.49, 0.04 },  -- Circle (Orange)
    [3] = { 0.58, 0.51, 0.79 },  -- Diamond (Purple)
    [4] = { 0.12, 1.00, 0.00 },  -- Triangle (Green)
    [5] = { 0.78, 0.78, 0.78 },  -- Moon (Silver)
    [6] = { 0.00, 0.44, 0.87 },  -- Square (Blue)
    [7] = { 0.77, 0.12, 0.23 },  -- Cross (Red)
    [8] = { 1.00, 1.00, 1.00 },  -- Skull (White)
}

-- Target marker icon textures (indices 1-8)
local TARGET_MARKER_TEXTURES = {
    [1] = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_1", -- Star
    [2] = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_2", -- Circle
    [3] = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_3", -- Diamond
    [4] = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_4", -- Triangle
    [5] = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_5", -- Moon
    [6] = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_6", -- Square
    [7] = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_7", -- Cross
    [8] = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_8", -- Skull
}

local function IsLeaderOrAssist()
    if not IsInGroup() then return false end
    if IsInRaid() then
        return UnitIsGroupLeader("player") or UnitIsGroupAssistant("player")
    end
    return UnitIsGroupLeader("player")
end

function BH:UpdateRaidToolsVisibility()
    if InCombatLockdown() then return end

    local enabled = self.settings and self.settings.raidToolsEnabled
    local preview = self.unlockMode

    if self.markersFrame then
        local inGroup = IsInGroup() or IsInRaid()
        if (enabled and inGroup and (self.settings.raidToolsShowMarkers ~= false)) or preview then
            self.markersFrame:Show()
        else
            self.markersFrame:Hide()
        end
    end
    if self.pullReadyFrame then
        -- In a raid, ready check and pull timer require leader/assist.
        -- In a 5-man party, any member can use ready check.
        local canUse
        if IsInRaid() then
            canUse = IsLeaderOrAssist()
        else
            canUse = IsInGroup()
        end
        if (enabled and canUse and (self.settings.raidToolsShowPullReady ~= false)) or preview then
            self.pullReadyFrame:Show()
        else
            self.pullReadyFrame:Hide()
        end
    end

    -- Preview mode overlays
    if preview then
        -- One call now covers every movable frame: tint, mouse, movable, show.
        -- See MOVABLE_FRAMES for the list and why it is a list.
        self:UpdateFrameLock()
        self:SetAllFramesPreview(true)

        -- Role CC has two toggles rather than one enabled key, so it decides
        -- for itself whether there is anything to preview.
        self:UpdateRoleCCFrame()

        -- Repair shows a sample percentage so the frame is not empty.
        if self.repairReminderFrame and self.repairReminderFrame:IsShown() and self.repairReminderText then
            self.repairReminderText:SetText("REPAIR (15%)")
        end

        -- Frames that draw their own sample content in preview. Showing the
        -- frame is not enough for these -- the death tally would sit there
        -- empty without its placeholder names.
        self:UpdateDeathTallyDisplay()
        if self.UpdateBresCounter then self:UpdateBresCounter() end

        -- Show CDM group previews.
        --
        -- pcall because the unlock control is shown immediately below, and it
        -- is the only way back out of unlock mode: an error raised here would
        -- skip it, leaving the player unlocked with no Done button and no
        -- visible cause. SetUnlockMode has already set self.unlockMode = true by
        -- this point, so its own `if self.unlockMode == on then return end`
        -- guard makes a second attempt a no-op -- the mode sticks until a
        -- reload. Losing the green boxes for one group beats losing the exit.
        if self.cdm and self.cdm.ShowPreview then
            local ok, err = pcall(self.cdm.ShowPreview, self.cdm)
            if not ok then
                print("|cffff6666Squizzumables:|r could not draw the Cooldown Manager "
                    .. "drag regions: " .. tostring(err))
            end
        end

        -- Show the unlock control. It is free-floating and remembers where it
        -- was left: it used to be re-anchored to the options panel every time,
        -- which meant it jumped back beside the panel on each toggle and could
        -- not be parked somewhere out of the way.
        if self.previewControlFrame then
            self:LoadUnlockControlPosition()
            self.previewControlFrame:Show()
        end
    else
        -- Leaving preview: drop every tint, then let each frame's own updater
        -- decide whether it should still be on screen and whether its lock
        -- allows dragging. SetAllFramesPreview(false) only clears the overlays;
        -- it deliberately does not hide or show anything, because that is the
        -- updaters' job.
        self:SetAllFramesPreview(false)

        if self.bresCounterFrame and not bresTrackingActive then
            self.bresCounterFrame:Hide()
        end
        if self.deathTallyFrame then
            self:UpdateDeathTallyDisplay()
        end

        -- Restore per-frame mouse state from each frame's own lock setting.
        -- Driven from the registry rather than one block per reminder.
        for _, def in ipairs(BH.REMINDERS) do
            local frame = self[def.key .. "ReminderFrame"]
            if frame then
                local locked = self.settings and self.settings[def.key .. "ReminderLocked"]
                frame:EnableMouse(self:ReminderMouseEnabled(locked))
            end
        end
        if self.bresCounterFrame then
            local locked = self.settings and self.settings.bresCounterLocked
            self.bresCounterFrame:EnableMouse(not locked)
        end

        -- Re-evaluate anything preview may have shown or relabelled.
        self:UpdateAllReminders()
        if self.cdm and self.cdm.HidePreview then
            self.cdm:HidePreview()
        end

        self:UpdateFrameLock()
        -- Drag handles follow their frame's lock again.
        if self.markersDragHandle then
            if self.settings and self.settings.raidToolsMarkersLocked then
                self.markersDragHandle:Hide()
            else
                self.markersDragHandle:Show()
            end
        end
        if self.pullReadyDragHandle then
            if self.settings and self.settings.raidToolsPullReadyLocked then
                self.pullReadyDragHandle:Hide()
            else
                self.pullReadyDragHandle:Show()
            end
        end
        -- Hide preview control frame
        if self.previewControlFrame then self.previewControlFrame:Hide() end
    end
end

function BH:UpdateMarkersLayout()
    local mf = self.markersFrame
    if not mf then return end

    local s = self.settings or {}
    local layout = s.raidToolsMarkersLayout or "HORIZONTAL"
    local grow   = s.raidToolsMarkersGrow or "LEFT"

    local markerSize    = 20
    local markerSpacing = 2
    local pad           = 4
    local numBtns       = 9 -- 8 markers + 1 clear per row

    local allBtns = {
        { btns = self.rtWorldMarkerBtns,   clear = self.rtWorldClearBtn },
        { btns = self.rtTargetMarkerBtns,  clear = self.rtTargetClearBtn },
    }

    if layout == "VERTICAL" then
        -- Vertical: each row becomes a column
        -- grow UP: columns go upward from anchor, grow DOWN: columns go downward
        local colWidth  = markerSize + markerSpacing
        local frameW    = 2 * markerSize + markerSpacing + pad * 2
        local frameH    = numBtns * markerSize + (numBtns - 1) * markerSpacing + pad * 2
        mf:SetSize(frameW, frameH)

        for rowIdx, row in ipairs(allBtns) do
            local colOff = pad + (rowIdx - 1) * colWidth
            for i = 1, 8 do
                local btn = row.btns[i]
                if btn then
                    btn:ClearAllPoints()
                    local idx = i
                    if grow == "UP" then idx = 10 - i end  -- reverse order for UP (slots 2-9, clear at 1)
                    btn:SetPoint("TOPLEFT", mf, "TOPLEFT", colOff, -(pad + (idx - 1) * (markerSize + markerSpacing)))
                end
            end
            if row.clear then
                row.clear:ClearAllPoints()
                local clearIdx = 9
                if grow == "UP" then clearIdx = 1 end  -- clear at top for UP (first slot)
                row.clear:SetPoint("TOPLEFT", mf, "TOPLEFT", colOff, -(pad + (clearIdx - 1) * (markerSize + markerSpacing)))
            end
        end
    else
        -- Horizontal
        local rowHeight = markerSize + markerSpacing
        local frameW    = numBtns * markerSize + (numBtns - 1) * markerSpacing + pad * 2
        local frameH    = 2 * markerSize + markerSpacing + pad * 2
        mf:SetSize(frameW, frameH)

        local reversed = (grow == "RIGHT")

        for rowIdx, row in ipairs(allBtns) do
            local rowOff = -(pad + (rowIdx - 1) * rowHeight)
            for i = 1, 8 do
                local btn = row.btns[i]
                if btn then
                    btn:ClearAllPoints()
                    local idx = i
                    if reversed then idx = 10 - i end  -- reverse button order (slots 2-9, clear at 1)
                    btn:SetPoint("TOPLEFT", mf, "TOPLEFT", pad + (idx - 1) * (markerSize + markerSpacing), rowOff)
                end
            end
            if row.clear then
                row.clear:ClearAllPoints()
                local clearIdx = 9
                if reversed then clearIdx = 1 end  -- clear at start for reversed
                row.clear:SetPoint("TOPLEFT", mf, "TOPLEFT", pad + (clearIdx - 1) * (markerSize + markerSpacing), rowOff)
            end
        end
    end

    -- Update drag handle position
    if self.markersDragHandle then
        self.markersDragHandle:ClearAllPoints()
        self.markersDragHandle:SetPoint("BOTTOMLEFT", mf, "TOPLEFT", 0, 2)
    end
end

function BH:CreateRaidToolsFrame()
    if self.markersFrame then return end

    local markerSize = 20
    local markerSpacing = 2
    local pad = 4
    -- 9 buttons per row (8 markers + 1 clear), 2 rows (world + target)
    local rowWidth = 9 * markerSize + 8 * markerSpacing
    local frameWidth = rowWidth + pad * 2
    local frameHeight = 2 * markerSize + markerSpacing + pad * 2

    -- ========================================================================
    -- MARKERS FRAME (world markers + target markers)
    -- ========================================================================
    local mf = CreateFrame("Frame", "SQUIZZUMABLESMarkers", UIParent, "SecureFrameTemplate,BackdropTemplate")
    mf:SetSize(frameWidth, frameHeight)
    mf:SetPoint("BOTTOMRIGHT", UIParent, "CENTER", 0, 0)
    mf:SetFrameStrata("MEDIUM")
    mf:SetMovable(true)
    mf:SetClampedToScreen(true)
    mf:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeSize = 1,
    })
    mf:SetBackdropColor(0.05, 0.05, 0.05, 0.85)
    mf:SetBackdropBorderColor(SQ_COLORS.border[1], SQ_COLORS.border[2], SQ_COLORS.border[3], 0.6)
    mf:EnableMouse(true)
    mf:RegisterForDrag("LeftButton")
    mf:SetScript("OnDragStart", function()
        if not (BH.settings and BH.settings.raidToolsMarkersLocked) or BH.unlockMode then
            mf:StartMoving()
            mf:SetUserPlaced(false)
        end
    end)
    mf:SetScript("OnDragStop", function()
        mf:StopMovingOrSizing()
        BH:SaveMarkersPosition()
    end)
    mf:Hide()
    self.markersFrame = mf

    -- Drag handle for markers frame
    local mfDrag = CreateFrame("Frame", nil, mf, "BackdropTemplate")
    mfDrag:SetSize(20, 12)
    mfDrag:SetPoint("BOTTOMLEFT", mf, "TOPLEFT", 0, 2)
    mfDrag:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeSize = 1,
    })
    mfDrag:SetBackdropColor(0.7, 0.7, 0.7, 0.4)
    mfDrag:SetBackdropBorderColor(0.8, 0.8, 0.8, 1.0)
    mfDrag:EnableMouse(true)
    mfDrag:RegisterForDrag("LeftButton")
    mfDrag:SetScript("OnDragStart", function()
        if not (BH.settings and BH.settings.raidToolsMarkersLocked) or BH.unlockMode then
            mf:StartMoving()
            mf:SetUserPlaced(false)
        end
    end)
    mfDrag:SetScript("OnDragStop", function()
        mf:StopMovingOrSizing()
        BH:SaveMarkersPosition()
    end)
    if self.settings and self.settings.raidToolsMarkersLocked then
        mfDrag:Hide()
    end
    self.markersDragHandle = mfDrag

    -- World marker index mapping (Cell addon order)
    local worldMarkerIndices = {5, 6, 3, 2, 7, 1, 4, 8}

    -- World marker buttons (top row)
    self.rtWorldMarkerBtns = {}
    for i = 1, 8 do
        local btn = CreateFrame("Button", "SQUIZZUMABLESWorldMarker" .. i, mf, "SecureActionButtonTemplate, BackdropTemplate")
        btn:SetSize(markerSize, markerSize)
        local c = WORLD_MARKER_COLORS[i]
        btn:SetAttribute("type", "worldmarker")
        btn:SetAttribute("marker", worldMarkerIndices[i])
        btn:RegisterForClicks(SQ_GetClickEdge("Left"))
        btn:SetBackdrop({
            bgFile = "Interface\\BUTTONS\\WHITE8X8",
            edgeFile = "Interface\\BUTTONS\\WHITE8X8",
            edgeSize = 1,
        })
        btn:SetBackdropColor(c[1], c[2], c[3], 0.35)
        btn:SetBackdropBorderColor(0, 0, 0, 0)
        local tex = btn:CreateTexture(nil, "ARTWORK")
        tex:SetSize(markerSize - 4, markerSize - 4)
        tex:SetPoint("CENTER")
        tex:SetColorTexture(c[1], c[2], c[3], 0.8)
        btn.colorTex = tex
        btn:SetScript("OnEnter", function(self) self:SetBackdropColor(c[1], c[2], c[3], 0.6) end)
        btn:SetScript("OnLeave", function(self) self:SetBackdropColor(c[1], c[2], c[3], 0.35) end)
        btn:SetPoint("TOPLEFT", mf, "TOPLEFT", pad + (i - 1) * (markerSize + markerSpacing), -pad)
        self.rtWorldMarkerBtns[i] = btn
    end

    -- Clear-all world marker button
    local clearWM = CreateFrame("Button", "SQUIZZUMABLESWorldMarkerClear", mf, "SecureActionButtonTemplate, BackdropTemplate")
    clearWM:SetSize(markerSize, markerSize)
    clearWM:SetAttribute("type", "worldmarker")
    clearWM:SetAttribute("action", "clear")
    clearWM:RegisterForClicks(SQ_GetClickEdge("Left"))
    clearWM:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeSize = 1,
    })
    clearWM:SetBackdropColor(0.1, 0.1, 0.1, 0.7)
    clearWM:SetBackdropBorderColor(0, 0, 0, 0)
    local clearWMTex = clearWM:CreateTexture(nil, "ARTWORK")
    clearWMTex:SetSize(markerSize - 4, markerSize - 4)
    clearWMTex:SetPoint("CENTER")
    clearWMTex:SetTexture("Interface\\RAIDFRAME\\ReadyCheck-NotReady")
    clearWMTex:SetVertexColor(1, 0.3, 0.3)
    clearWM:SetScript("OnEnter", function(self) self:SetBackdropColor(0.4, 0.1, 0.1, 0.7) end)
    clearWM:SetScript("OnLeave", function(self) self:SetBackdropColor(0.1, 0.1, 0.1, 0.7) end)
    clearWM:SetPoint("TOPLEFT", mf, "TOPLEFT", pad + 8 * (markerSize + markerSpacing), -pad)
    self.rtWorldClearBtn = clearWM

    -- Target marker buttons (bottom row)
    self.rtTargetMarkerBtns = {}
    for i = 1, 8 do
        local btn = CreateFrame("Button", "SQUIZZUMABLESTargetMarker" .. i, mf, "SecureActionButtonTemplate, BackdropTemplate")
        btn:SetSize(markerSize, markerSize)
        btn:SetAttribute("type1", "raidtarget")
        btn:SetAttribute("action1", "toggle")
        btn:SetAttribute("marker", i)
        btn:RegisterForClicks(SQ_GetClickEdge())
        btn:SetBackdrop({
            bgFile = "Interface\\BUTTONS\\WHITE8X8",
            edgeFile = "Interface\\BUTTONS\\WHITE8X8",
            edgeSize = 1,
        })
        btn:SetBackdropColor(0.1, 0.1, 0.1, 0.7)
        btn:SetBackdropBorderColor(0, 0, 0, 0)
        local icon = btn:CreateTexture(nil, "ARTWORK")
        icon:SetSize(markerSize - 4, markerSize - 4)
        icon:SetPoint("CENTER")
        icon:SetTexture(TARGET_MARKER_TEXTURES[i])
        btn:SetScript("OnEnter", function(self) self:SetBackdropColor(0.3, 0.3, 0.3, 0.7) end)
        btn:SetScript("OnLeave", function(self) self:SetBackdropColor(0.1, 0.1, 0.1, 0.7) end)
        btn:SetPoint("TOPLEFT", mf, "TOPLEFT", pad + (i - 1) * (markerSize + markerSpacing), -(pad + markerSize + markerSpacing))
        self.rtTargetMarkerBtns[i] = btn
    end

    -- Clear-all target marker button (matches SquizzUI: type=raidtarget, action=clear-all)
    local clearTM = CreateFrame("Button", "SQUIZZUMABLESTargetMarkerClear", mf, "SecureActionButtonTemplate, BackdropTemplate")
    clearTM:SetSize(markerSize, markerSize)
    clearTM:SetAttribute("type", "raidtarget")
    clearTM:SetAttribute("action", "clear-all")
    clearTM:RegisterForClicks(SQ_GetClickEdge())
    clearTM:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeSize = 1,
    })
    clearTM:SetBackdropColor(0.1, 0.1, 0.1, 0.7)
    clearTM:SetBackdropBorderColor(0, 0, 0, 0)
    local clearTMTex = clearTM:CreateTexture(nil, "ARTWORK")
    clearTMTex:SetSize(markerSize - 4, markerSize - 4)
    clearTMTex:SetPoint("CENTER")
    clearTMTex:SetTexture("Interface\\RAIDFRAME\\ReadyCheck-NotReady")
    clearTMTex:SetVertexColor(1, 0.3, 0.3)
    clearTM:SetScript("OnEnter", function(self) self:SetBackdropColor(0.4, 0.1, 0.1, 0.7) end)
    clearTM:SetScript("OnLeave", function(self) self:SetBackdropColor(0.1, 0.1, 0.1, 0.7) end)
    clearTM:SetPoint("TOPLEFT", mf, "TOPLEFT", pad + 8 * (markerSize + markerSpacing), -(pad + markerSize + markerSpacing))
    self.rtTargetClearBtn = clearTM

    -- Apply markers layout from settings
    self:UpdateMarkersLayout()



    -- ========================================================================
    -- PULL/READY FRAME (ready check + pull timer) - vertical layout
    -- ========================================================================
    local btnWidth = 90
    local btnHeight = 22
    local btnSpacing = 2
    local prPad = 4
    local prWidth = btnWidth + prPad * 2
    local prHeight = 2 * btnHeight + btnSpacing + prPad * 2

    local prf = CreateFrame("Frame", "SQUIZZUMABLESPullReady", UIParent, "SecureFrameTemplate,BackdropTemplate")
    prf:SetSize(prWidth, prHeight)
    prf:SetPoint("RIGHT", mf, "LEFT", -2, 0)
    prf:SetFrameStrata("MEDIUM")
    prf:SetMovable(true)
    prf:SetClampedToScreen(true)
    prf:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeSize = 1,
    })
    prf:SetBackdropColor(0.05, 0.05, 0.05, 0.85)
    prf:SetBackdropBorderColor(SQ_COLORS.border[1], SQ_COLORS.border[2], SQ_COLORS.border[3], 0.6)
    prf:EnableMouse(true)
    prf:RegisterForDrag("LeftButton")
    prf:SetScript("OnDragStart", function()
        if not (BH.settings and BH.settings.raidToolsPullReadyLocked) or BH.unlockMode then
            prf:StartMoving()
            prf:SetUserPlaced(false)
        end
    end)
    prf:SetScript("OnDragStop", function()
        prf:StopMovingOrSizing()
        BH:SavePullReadyPosition()
    end)
    prf:Hide()
    self.pullReadyFrame = prf

    -- Drag handle for pull/ready frame
    local prfDrag = CreateFrame("Frame", nil, prf, "BackdropTemplate")
    prfDrag:SetSize(20, 12)
    prfDrag:SetPoint("BOTTOMLEFT", prf, "TOPLEFT", 0, 2)
    prfDrag:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeSize = 1,
    })
    prfDrag:SetBackdropColor(0.7, 0.7, 0.7, 0.4)
    prfDrag:SetBackdropBorderColor(0.8, 0.8, 0.8, 1.0)
    prfDrag:EnableMouse(true)
    prfDrag:RegisterForDrag("LeftButton")
    prfDrag:SetScript("OnDragStart", function()
        if not (BH.settings and BH.settings.raidToolsPullReadyLocked) or BH.unlockMode then
            prf:StartMoving()
            prf:SetUserPlaced(false)
        end
    end)
    prfDrag:SetScript("OnDragStop", function()
        prf:StopMovingOrSizing()
        BH:SavePullReadyPosition()
    end)
    if self.settings and self.settings.raidToolsPullReadyLocked then
        prfDrag:Hide()
    end
    self.pullReadyDragHandle = prfDrag

    -- Ready Check button
    -- Plain button + OnClick → DoReadyCheck() matches SquizzUI exactly.
    -- DoReadyCheck() is a protected function but is callable from a hardware-event
    -- OnClick handler (player physically clicking the button).
    local readyBtn = CreateFrame("Button", "SQUIZZUMABLESReadyCheck", prf, "BackdropTemplate")
    readyBtn:SetSize(btnWidth, btnHeight)
    readyBtn:RegisterForClicks("LeftButtonDown")
    readyBtn:SetScript("OnClick", function(self, button)
        if button == "LeftButton" then
            DoReadyCheck()
        end
    end)
    readyBtn:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeSize = 1,
    })
    readyBtn:SetBackdropColor(SQ_COLORS.control[1], SQ_COLORS.control[2], SQ_COLORS.control[3], 1)
    do local ar, ag, ab = ns.GetAccentColor("dim"); readyBtn:SetBackdropBorderColor(ar, ag, ab, 0.6) end
    local readyLabel = readyBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    readyLabel:SetPoint("CENTER")
    readyLabel:SetText("Ready Check")
    ns.ApplyAccent(readyLabel, "text")
    readyBtn:SetScript("OnEnter", function(self)
        self:SetBackdropColor(SQ_COLORS.controlHi[1], SQ_COLORS.controlHi[2], SQ_COLORS.controlHi[3], 1)
        do local ar, ag, ab = ns.GetAccentColor(); self:SetBackdropBorderColor(ar, ag, ab, 1) end
    end)
    readyBtn:SetScript("OnLeave", function(self)
        self:SetBackdropColor(SQ_COLORS.control[1], SQ_COLORS.control[2], SQ_COLORS.control[3], 1)
        do local ar, ag, ab = ns.GetAccentColor("dim"); self:SetBackdropBorderColor(ar, ag, ab, 0.6) end
    end)
    readyBtn:SetPoint("TOPLEFT", prf, "TOPLEFT", prPad, -prPad)
    self.rtReadyBtn = readyBtn

    -- Pull Timer button
    local pullBtn = CreateFrame("Button", "SQUIZZUMABLESPullTimer", prf, "BackdropTemplate")
    pullBtn:SetSize(btnWidth, btnHeight)
    pullBtn:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeSize = 1,
    })
    pullBtn:SetBackdropColor(SQ_COLORS.control[1], SQ_COLORS.control[2], SQ_COLORS.control[3], 1)
    do local ar, ag, ab = ns.GetAccentColor("dim"); pullBtn:SetBackdropBorderColor(ar, ag, ab, 0.6) end
    pullBtn.label = pullBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    pullBtn.label:SetPoint("CENTER")
    local pullDuration = (self.settings and self.settings.raidToolsPullTimer) or 10
    pullBtn.label:SetText("Pull " .. pullDuration .. "s")
    ns.ApplyAccent(pullBtn.label, "text")
    pullBtn:SetScript("OnEnter", function(self)
        self:SetBackdropColor(SQ_COLORS.controlHi[1], SQ_COLORS.controlHi[2], SQ_COLORS.controlHi[3], 1)
        do local ar, ag, ab = ns.GetAccentColor(); self:SetBackdropBorderColor(ar, ag, ab, 1) end
    end)
    pullBtn:SetScript("OnLeave", function(self)
        self:SetBackdropColor(SQ_COLORS.control[1], SQ_COLORS.control[2], SQ_COLORS.control[3], 1)
        do local ar, ag, ab = ns.GetAccentColor("dim"); self:SetBackdropBorderColor(ar, ag, ab, 0.6) end
    end)
    self.rtPullActive = false
    pullBtn:SetScript("OnClick", function()
        if IsLeaderOrAssist() then
            if BH.rtPullActive then
                C_PartyInfo.DoCountdown(0)
                BH.rtPullActive = false
                local d = (BH.settings and BH.settings.raidToolsPullTimer) or 10
                pullBtn.label:SetText("Pull " .. d .. "s")
            else
                local d = (BH.settings and BH.settings.raidToolsPullTimer) or 10
                C_PartyInfo.DoCountdown(d)
                BH.rtPullActive = true
                pullBtn.label:SetText("Cancel")
                C_Timer.After(d, function()
                    BH.rtPullActive = false
                    if BH.rtPullBtn then
                        local dur = (BH.settings and BH.settings.raidToolsPullTimer) or 10
                        BH.rtPullBtn.label:SetText("Pull " .. dur .. "s")
                    end
                end)
            end
        end
    end)
    pullBtn:SetPoint("TOPLEFT", readyBtn, "BOTTOMLEFT", 0, -btnSpacing)
    self.rtPullBtn = pullBtn

    -- Apply saved scale to frames
    local mScale = (self.settings and self.settings.raidToolsMarkersScale) or 1.0
    local prScale = (self.settings and self.settings.raidToolsPullReadyScale) or 1.0
    mf:SetScale(mScale)
    prf:SetScale(prScale)

    -- ========================================================================
    -- PREVIEW CONTROL FRAME (close/lock buttons - shown during preview mode)
    -- ========================================================================
    local pcf = CreateFrame("Frame", "SQUIZZUMABLESPreviewControl", UIParent, "BackdropTemplate")
    pcf:SetSize(160, 60)
    pcf:SetPoint("TOPLEFT", UIParent, "CENTER", 0, 0)
    pcf:SetFrameStrata("DIALOG")
    pcf:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeSize = 1,
    })
    pcf:SetBackdropColor(0.05, 0.05, 0.05, 0.9)
    pcf:SetBackdropBorderColor(SQ_COLORS.border[1], SQ_COLORS.border[2], SQ_COLORS.border[3], 0.8)
    pcf:EnableMouse(true)
    pcf:SetMovable(true)
    pcf:SetClampedToScreen(true)
    pcf:RegisterForDrag("LeftButton")
    pcf:SetScript("OnDragStart", function() pcf:StartMoving() end)
    pcf:SetScript("OnDragStop", function()
        pcf:StopMovingOrSizing()
        BH:SaveUnlockControlPosition()
    end)

    local pcfTitle = pcf:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    pcfTitle:SetPoint("TOP", pcf, "TOP", 0, -6)
    pcfTitle:SetText("Frames Unlocked")
    pcfTitle:SetTextColor(0.1, 0.8, 0.1)

    local lockBtn = CreateSQButton(pcf, "Lock All", 68, 22)
    lockBtn:SetPoint("BOTTOMLEFT", pcf, "BOTTOMLEFT", 6, 6)
    lockBtn:SetScript("OnClick", function()
        -- Driven off the registries rather than a hand-written list.
        --
        -- It was a hand-written list, and it had fallen behind by five: the
        -- Coach's Whistle, pet, role CC, augment rune and healthstone frames
        -- were never in it, so "Lock All" quietly left them unlocked. Nothing
        -- announced that -- the button said it had locked everything.
        for _, def in ipairs(BH.REMINDERS) do
            BH.settings[def.key .. "ReminderLocked"] = true
        end
        BH.settings.raidToolsMarkersLocked = true
        BH.settings.raidToolsPullReadyLocked = true
        BH.settings.bresCounterLocked = true
        BH.settings.deathTallyLocked = true
        -- No kelAlertLocked here: the Kelert image has no lock setting any
        -- more. It never takes the mouse outside Unlock Frames, so there is
        -- nothing for Lock All to switch off. Do not reintroduce the key --
        -- writing a setting nothing reads is how the bag reminder's toggle
        -- went quietly dead.
        BH.settings.frameLocked = true
        BH:SaveSettings()
        -- Lock CDM groups
        if BH.cdm and BH.cdm.LockAll then
            BH.cdm:LockAll()
        end

        -- Apply to the live frames, from the same list preview mode uses, so a
        -- frame can never be previewable but not lockable.
        for _, def in ipairs(BH.MOVABLE_FRAMES or {}) do
            local f = BH[def.field]
            if f then
                f:SetMovable(false)
                f:EnableMouse(false)
            end
        end
        if BH.kelAlertFrame then
            BH.kelAlertFrame:SetMovable(false)
            BH.kelAlertFrame:EnableMouse(false)
        end
        BH:UpdateFrameLock()
        -- Options panel checkboxes used to be pushed one by one here. Every
        -- lock is a declarative row now and reads its own value back, so the
        -- RefreshAll below covers them -- including any added later.
        ns.Rows.RefreshAll()
        print("Squizzumables: All frames locked")
        -- Locking everything means the player is finished positioning, so leave
        -- unlock mode too. Otherwise the locks appear to do nothing, because
        -- unlock mode overrides them.
        BH:SetUnlockMode(false)
    end)

    local closeBtn = CreateSQButton(pcf, "Done", 68, 22)
    closeBtn:SetPoint("BOTTOMRIGHT", pcf, "BOTTOMRIGHT", -6, 6)
    closeBtn:SetScript("OnClick", function()
        BH:SetUnlockMode(false)
    end)

    pcf:Hide()
    self.previewControlFrame = pcf

end

-- === Instance Sound Detection ===
local INSTANCE_SOUNDS = {
    { instanceID = 1209, difficultyID = 23, soundID = 46004 },  -- Skyreach Mythic
}

function BH:CheckInstanceSound()
    if not self.settings or not self.settings.skyreachSoundEnabled then return end
    ---@diagnostic disable-next-line: undefined-global
    local _, _, difficultyID, _, _, _, _, instanceID = GetInstanceInfo()
    for _, entry in ipairs(INSTANCE_SOUNDS) do
        if instanceID == entry.instanceID and difficultyID == entry.difficultyID then
            ---@diagnostic disable-next-line: undefined-global
            PlaySound(entry.soundID, "Master")
            return
        end
    end
end

-- ============================================================================
-- Feast Announce
-- ============================================================================
-- Item IDs whose "on-use" spell should trigger the feast announce.
-- GetItemSpell() is used at login to resolve the matching spell ID automatically.
-- If auto-detection misses a feast, add its spellID manually to SQ_FEAST_SPELL_OVERRIDES.
local SQ_FEAST_ITEM_IDS = {
    242273,  -- Blooming Feast
    242745,  -- Hearty Blooming Feast
    255846,  -- Harandar Celebration
    266996,  -- Hearty Harandar Celebration
    242272,  -- Quel'dorei Medley
    242744,  -- Hearty Quel'dorei Medley
    255845,  -- Silvermoon Parade
    266985,  -- Hearty Silvermoon Parade
}
-- Manual overrides: [spellID] = "Display Name"
local SQ_FEAST_SPELL_OVERRIDES = {
    -- [999999] = "Some Other Feast",
}
-- Populated at login
local feastSpellLookup = {}

local function BuildFeastSpellLookup()
    wipe(feastSpellLookup)
    for spellID, name in pairs(SQ_FEAST_SPELL_OVERRIDES) do
        feastSpellLookup[spellID] = name
    end
    for _, itemID in ipairs(SQ_FEAST_ITEM_IDS) do
        local itemName = C_Item.GetItemNameByID(itemID)
        local _, spellID = C_Item.GetItemSpell(itemID)
        if spellID and itemName then
            feastSpellLookup[spellID] = itemName
        else
            -- Item data not cached yet; request a load from server so
            -- GET_ITEM_INFO_RECEIVED fires and we can rebuild the lookup.
            C_Item.RequestLoadItemDataByID(itemID)
        end
    end
end

-- Per-spellID throttle: castGUID is a secret value in 12.0 and cannot be used
-- as a table index. Use a timestamp instead to prevent double-firing.
local feastAnnounceCooldowns = {}

--- Returns the best channel string for the current group state.
--- channelDB must be a table with keys: solo, party, instance, raid.
function BH:GetAnnounceChannel(channelDB)
    if not channelDB then return "NONE" end
    if IsPartyLFG() or IsInGroup(LE_PARTY_CATEGORY_INSTANCE) or IsInRaid(LE_PARTY_CATEGORY_INSTANCE) then
        return channelDB.instance or "INSTANCE_CHAT"
    elseif IsInRaid(LE_PARTY_CATEGORY_HOME) then
        return channelDB.raid or "RAID"
    elseif IsInGroup(LE_PARTY_CATEGORY_HOME) then
        return channelDB.party or "PARTY"
    end
    return channelDB.solo or "NONE"
end

function BH:OnFeastSpellcast(unit, castGUID, spellID)
    if unit ~= "player" then return end  -- party spellID is fully secret in 12.0+, only player's own is comparable
    if not (self.settings and self.settings.feastAnnounceEnabled) then return end
    if BH.challengeModeActive then return end
    -- spellID is a secret value in 12.0 and cannot be used as a table key.
    -- Use == comparison (allowed) to find a match without indexing.
    local feastName = nil
    for id, name in pairs(feastSpellLookup) do
        if id == spellID then
            feastName = name
            break
        end
    end
    if not feastName then return end
    -- Resolve channel from per-context table (WindTools-style)
    local chanDB = (self.settings and type(self.settings.feastAnnounceChannel) == "table")
        and self.settings.feastAnnounceChannel
        or BH.defaultSettings.feastAnnounceChannel
    local channel = BH:GetAnnounceChannel(chanDB)
    if channel == "NONE" then return end
    -- Use feastName as cooldown key (safe string, not a secret value)
    local now = GetTime()
    if feastAnnounceCooldowns[feastName] and (now - feastAnnounceCooldowns[feastName]) < 10 then return end
    feastAnnounceCooldowns[feastName] = now
    local customText = self.settings and self.settings.feastAnnounceText
    local msg
    if customText and customText ~= "" then
        msg = customText:gsub("{feast}", feastName)
    else
        msg = "Fresh off the Barbie, no Crocs were harmed in the making of this " .. feastName .. "... I think."
    end
    C_ChatInfo.SendChatMessage(msg, channel)
    -- Broadcast to other Squizzumables users so they can play a sound alert.
    -- The echo back to ourselves also triggers our own sound via CHAT_MSG_ADDON.
    C_ChatInfo.SendAddonMessage("SQ_FEAST", feastName, channel)
end

function BH:OnFeastAddonMessage(feastName)
    -- Mark the cooldown so our party-watch handler doesn't double-announce
    -- when the feast caster also has the addon and already announced.
    feastAnnounceCooldowns[feastName] = GetTime()
    if BH.challengeModeActive then return end
    local snd = self.settings and self.settings.feastAlertSound or "None"
    if snd and snd ~= "None" then
        PlaySQSound(snd)
    end
end

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
        BuildFeastSpellLookup()
        C_Timer.After(2, BuildFeastSpellLookup)
        -- Build consumable buff spell ID cache (food/flask detection in HasFoodBuff/HasFlaskBuff).
        -- Retry after 2s in case item data hasn't fully loaded on the first pass.
        BuildConsumableBuffCache()
        C_Timer.After(2, BuildConsumableBuffCache)
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
        -- AddAuraSound is protected and refused in combat, so a registration
        -- that arrived mid-fight was postponed rather than attempted.
        if BH.FlushQueuedAuraSoundRegistrations then
            BH:FlushQueuedAuraSoundRegistrations()
        end
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
        for _, feastItemID in ipairs(SQ_FEAST_ITEM_IDS) do
            if feastItemID == arg1 then
                BuildFeastSpellLookup()
                break
            end
        end
    elseif event == "BAG_UPDATE_DELAYED" or event == "PLAYER_EQUIPMENT_CHANGED" or event == "GROUP_ROSTER_UPDATE" or event == "UNIT_PET" then
        -- Bag contents changed: drop the snapshot. Marked rather than
        -- rebuilt so several events in a row cost one scan, and the scan
        -- happens on the next read rather than on the event.
        if event == "BAG_UPDATE_DELAYED" then
            BH:MarkBagCacheStale()
            BuildFeastSpellLookup()  -- pick up feast items added to bags mid-session
        end
        BH:UpdateButtons()
        if event == "GROUP_ROSTER_UPDATE" then
            BH:UpdateRaidToolsVisibility()
            BH:RefreshRoleCCWatchList()
            -- Pick up members who joined after tracking started (e.g. replaced a
            -- dropped player) so their combat-log deaths can be attributed —
            -- combat log gives destGUID only, so a never-seen GUID can't be
            -- resolved to a name without first seeing them via a unit token.
            if deathTallyActive then
                BH:SyncDeathTallyRoster()
                BH:UpdateDeathTallyDisplay()
            end
        end
    elseif event == "UNIT_AURA" then
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
        BH:OnSpecChanged()
    elseif event == "UPDATE_INVENTORY_DURABILITY" then
        BH:UpdateRepairReminder()
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        local castGUID, spellID = ...
        if arg1 == "player" then
            BH:OnFeastSpellcast(arg1, castGUID, spellID)
            BH:OnReminderSpellcast(spellID)
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
SLASH_SQUIZZUMABLES1 = '/sq'
SlashCmdList['SQUIZZUMABLES'] = function(msg)
    if msg == 'reset' then
        BH.frame:ClearAllPoints()
        BH.frame:SetPoint('CENTER')
        print(addonName.." frame reset to center")
    elseif msg == 'config' then
        BH:CreateOptionsPanel()
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
        for _ in pairs(feastSpellLookup) do count = count + 1 end
        print("  feastSpellLookup entries:", count)
        for _, name in pairs(feastSpellLookup) do
            print("    feast:", name)
        end
        print("  Item lookup test:")
        for _, itemID in ipairs(SQ_FEAST_ITEM_IDS) do
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
    elseif msg == "cotank" then
        if BH.PrintCoTankDiagnostics then
            BH:PrintCoTankDiagnostics()
        else
            print(addonName .. ": Co-tank module not loaded.")
        end
    elseif msg == "cdmbuff" then
        if BH.cdm and BH.cdm.PrintBuffDiagnostics then
            BH.cdm:PrintBuffDiagnostics()
        else
            print(addonName .. ": Cooldown Manager module not loaded.")
        end
    elseif msg == "buffsounds" then
        if BH.PrintBuffSoundDiagnostics then
            BH:PrintBuffSoundDiagnostics()
        else
            print(addonName .. ": Spell alerts module not loaded.")
        end
    elseif msg == "notes" then
        if BH.ShowReleaseNotes then BH.ShowReleaseNotes() end
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
        print("  /ginvite <name> - guild invite a player")
    end
end

-- /squizz shortcut to open config directly; /squizz CDMS opens hidden CDM Sounds tab
SLASH_SQUIZZUMABLESCONFIG1 = '/squizz'
SlashCmdList['SQUIZZUMABLESCONFIG'] = function(msg)
    BH:CreateOptionsPanel()
    if msg and msg:upper() == "CDMS" then
        if BH.switchTab then BH.switchTab("cdmsounds") end
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
