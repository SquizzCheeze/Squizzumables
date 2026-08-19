-- Squizzumables.lua
-- A simple WoW addon to check inventory for consumables (food, flask, oil) and
-- your class buffs (e.g. Fortitude for priests) and show clickable buttons in a
-- movable frame. Designed for Dragonflight/Midnight (12.0.1) but should work
-- with other retail versions.

local addonName = "Squizzumables"
if not BH then BH = {} end  -- Don't overwrite if config already set it up

-- Default settings for appearance
BH.defaultSettings = {
    buttonSize = 36,
    buttonSpacing = 5,
    frameLocked = false,
    anchorPoint = "LEFT",
    growDirection = "RIGHT",
    layoutDirection = "HORIZONTAL", -- HORIZONTAL or VERTICAL
    showLabelText = true,
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

    -- M+ Death Tally (per-player death counter, resets each key)
    deathTallyEnabled = true,
    deathTallyLocked = false,
    deathTallyScale = 1.0,
    deathTallyClassColorNames = true,
    deathTallyHideRealm = true,
    deathTallyTitleFontSize = 13,
    deathTallyRowFontSize = 12,

    -- Food/Flask/Oil "no items in bag" reminders
    foodReminderLocked = false,
    foodReminderScale = 1.0,
    foodReminderEnabled = true,
    flaskReminderLocked = false,
    flaskReminderScale = 1.0,
    flaskReminderEnabled = true,
    oilReminderLocked = false,
    oilReminderScale = 1.0,
    oilReminderEnabled = true,

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

    -- Healer CC sound alert
    healerCCAlertEnabled = false,
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

    -- Kelerts: spell alert frame
    kelAlertScale    = 1.0,
    kelAlertLocked   = false,
    -- Kelerts: lust alert
    kelLustAlert = {
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

}

-- ============================================================================
-- Shared helpers
-- ============================================================================

-- Does the player know this spell?
--
-- Plain IsSpellKnown() returns false for spells granted by a talent, and for a
-- base spell that a talent has overridden — so using it alone means a reminder
-- can silently never fire for a given talent build. Check the modern API first
-- and fall back through the older ones, which cover different cases:
--   C_SpellBook.IsSpellKnown      — current API, authoritative when it answers
--   IsPlayerSpell                 — includes talent-granted spells
--   IsSpellKnownOrOverridesKnown  — includes spells replaced by an override
--   IsSpellKnown                  — base spellbook only
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
    if C_SpellBook and C_SpellBook.IsSpellKnown then
        local known = C_SpellBook.IsSpellKnown(spellID)
        if known ~= nil then return known end
    end
    if IsPlayerSpell and IsPlayerSpell(spellID) then return true end
    if IsSpellKnownOrOverridesKnown and IsSpellKnownOrOverridesKnown(spellID) then return true end
    if IsSpellKnown and IsSpellKnown(spellID, false) then return true end
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
    { "foodReminderFrame",        "foodReminderPosition" },
    { "flaskReminderFrame",       "flaskReminderPosition" },
    { "oilReminderFrame",         "oilReminderPosition" },
    { "healerCCReminderFrame",    "healerCCReminderPosition" },
    { "deathTallyFrame",          "deathTallyPosition" },
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
            customItems = SquizzumablesDB.customItems and CopyTable(SquizzumablesDB.customItems) or { food = {}, flask = {}, oil = {} },
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
            customItems = { food = {}, flask = {}, oil = {} },
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
    profile.customItems = CopyTable(SquizzumablesDB.customItems or { food = {}, flask = {}, oil = {} })

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
    SquizzumablesDB.customItems = CopyTable(profile.customItems or { food = {}, flask = {}, oil = {} })

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
            customItems = { food = {}, flask = {}, oil = {} },
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
    if self.optionsPanel and self.optionsPanel:IsShown() then
        self:RefreshSettingsTab()
        self:RefreshItemList()
        self:RefreshRaidToolsTab()
        self:RefreshTextRemindersTab()
    end
end

-- Load settings
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
        SquizzumablesDB.customItems = { food = {}, flask = {}, oil = {} }
    end
    
    -- Load appearance settings with defaults
    local isNewInstall = not SquizzumablesDB.settings
    if not SquizzumablesDB.settings then
        SquizzumablesDB.settings = CopyTable(BH.defaultSettings)
    end
    self.settings = SquizzumablesDB.settings
    -- New installs already get current defaults directly — skip the one-time
    -- migrations below so they don't get retroactively "fixed" into old
    -- defaults (e.g. force-enabling the lust alert) that no longer apply.
    if isNewInstall then
        SquizzumablesDB.kelLustMigrated = true
        SquizzumablesDB.kelLustMigrated2 = true
        SquizzumablesDB.kelLustMigrated3 = true
    end
    -- Ensure all settings exist (top-level keys)
    for k, v in pairs(BH.defaultSettings) do
        if self.settings[k] == nil then
            self.settings[k] = type(v) == "table" and CopyTable(v) or v
        end
    end
    -- Deep-merge nested defaults for kelLustAlert (fill in missing sub-keys)
    if type(self.settings.kelLustAlert) == "table" then
        for k, v in pairs(BH.defaultSettings.kelLustAlert) do
            if self.settings.kelLustAlert[k] == nil then
                self.settings.kelLustAlert[k] = v
            end
        end
    end
    -- Migrate legacy feastAnnounceChannel: convert old string to per-context table
    if type(self.settings.feastAnnounceChannel) == "string" then
        local old = self.settings.feastAnnounceChannel
        self.settings.feastAnnounceChannel = CopyTable(BH.defaultSettings.feastAnnounceChannel)
        -- Preserve the user's old choice for party/instance if it was set deliberately
        if old == "INSTANCE_CHAT" then
            self.settings.feastAnnounceChannel.party    = "INSTANCE_CHAT"
            self.settings.feastAnnounceChannel.instance = "INSTANCE_CHAT"
        elseif old == "RAID" or old == "RAID_WARNING" then
            self.settings.feastAnnounceChannel.party    = old
            self.settings.feastAnnounceChannel.instance = old
            self.settings.feastAnnounceChannel.raid     = old
        end
    end
    -- Deep-merge nested defaults for feastAnnounceChannel (fill in missing sub-keys)
    if type(self.settings.feastAnnounceChannel) == "table" then
        for k, v in pairs(BH.defaultSettings.feastAnnounceChannel) do
            if self.settings.feastAnnounceChannel[k] == nil then
                self.settings.feastAnnounceChannel[k] = v
            end
        end
    end
    -- One-time migration v1: lust alert was shipped with enabled=false by mistake
    if not SquizzumablesDB.kelLustMigrated then
        if type(self.settings.kelLustAlert) == "table" and self.settings.kelLustAlert.enabled == false then
            self.settings.kelLustAlert.enabled = true
        end
        SquizzumablesDB.kelLustMigrated = true
    end
    -- One-time migration v2: lust alert sound was "None" by default; set to Raid Warning
    if not SquizzumablesDB.kelLustMigrated2 then
        if type(self.settings.kelLustAlert) == "table" and self.settings.kelLustAlert.sound == "None" then
            self.settings.kelLustAlert.sound = "__builtin_raidwarning"
        end
        SquizzumablesDB.kelLustMigrated2 = true
    end
    -- One-time migration v3: set duckrun as default texture/frames/fps/sound
    if not SquizzumablesDB.kelLustMigrated3 then
        if type(self.settings.kelLustAlert) == "table" then
            local la = self.settings.kelLustAlert
            if la.texture == "" or la.texture == nil then la.texture = "duckrun" end
            if (la.frameCount or 0) == 0 then la.frameCount = 15 end
            if (la.fps or 10) == 10 then la.fps = 30 end
            if la.sound == "None" or la.sound == "__builtin_raidwarning" or la.sound == nil then
                la.sound = "Squizzumables: Ducky"
            end
        end
        SquizzumablesDB.kelLustMigrated3 = true
    end
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
    if self.dragHandle then
        self:UpdateDragHandlePosition()
    end
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
    { "foodReminderFrame",        "foodReminderScale" },
    { "flaskReminderFrame",       "flaskReminderScale" },
    { "oilReminderFrame",         "oilReminderScale" },
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
    if self.previewMode then
        self.frame:SetMovable(true)
        if self.dragHandle then self.dragHandle:Show() end
        return
    end
    if self.settings and self.settings.frameLocked then
        self.frame:SetMovable(false)
        if self.dragHandle then
            self.dragHandle:Hide()
        end
    else
        self.frame:SetMovable(true)
        if self.dragHandle then
            self.dragHandle:Show()
        end
    end
end

-- Add a custom item to a category
function BH:AddCustomItem(category, itemID)
    if not self.customItems then
        self.customItems = { food = {}, flask = {}, oil = {} }
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
-- Options Panel (built-in, no external framework required)
-- ============================================================================

-- Color palette
local SQ_COLORS = {
    bg          = { 0.06, 0.06, 0.08, 0.96 },
    titleBar    = { 0.10, 0.10, 0.13, 1 },
    border      = { 0.25, 0.25, 0.30, 1 },
    accent      = { 0.78, 0.65, 0.30, 1 },     -- warm gold
    accentDim   = { 0.55, 0.45, 0.20, 0.6 },
    text        = { 0.90, 0.90, 0.90, 1 },
    textDim     = { 0.55, 0.55, 0.58, 1 },
    textBright  = { 1, 1, 1, 1 },
    control     = { 0.14, 0.14, 0.17, 1 },
    controlHi   = { 0.20, 0.20, 0.24, 1 },
    danger      = { 0.75, 0.25, 0.25, 1 },
    dangerDim   = { 0.55, 0.20, 0.20, 0.6 },
    section     = { 0.18, 0.18, 0.22, 0.5 },
    tabActive   = { 0.14, 0.14, 0.17, 1 },
    tabInactive = { 0.08, 0.08, 0.10, 1 },
}
-- Expose for module files
_G.SQ_COLORS = SQ_COLORS

-- Helper: create a thin-bordered backdrop on a frame
local function ApplySQBackdrop(frame, bgColor, borderColor)
    if not frame.SetBackdrop then
        Mixin(frame, BackdropTemplateMixin)
    end
    frame:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeSize = 1,
    })
    frame:SetBackdropColor(unpack(bgColor or SQ_COLORS.bg))
    frame:SetBackdropBorderColor(unpack(borderColor or SQ_COLORS.border))
end

-- Helper: styled button
function CreateSQButton(parent, text, width, height, color)
    color = color or SQ_COLORS.accent
    local dimColor = (color == SQ_COLORS.danger) and SQ_COLORS.dangerDim or SQ_COLORS.accentDim
    local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    btn:SetSize(width or 100, height or 26)
    btn:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeSize = 1,
    })
    btn:SetBackdropColor(SQ_COLORS.control[1], SQ_COLORS.control[2], SQ_COLORS.control[3], 1)
    btn:SetBackdropBorderColor(dimColor[1], dimColor[2], dimColor[3], dimColor[4])
    local label = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetPoint("CENTER")
    label:SetText(text)
    label:SetTextColor(color[1], color[2], color[3])
    btn.label = label
    btn:SetScript("OnEnter", function(self)
        self:SetBackdropColor(SQ_COLORS.controlHi[1], SQ_COLORS.controlHi[2], SQ_COLORS.controlHi[3], 1)
        self:SetBackdropBorderColor(color[1], color[2], color[3], 1)
    end)
    btn:SetScript("OnLeave", function(self)
        self:SetBackdropColor(SQ_COLORS.control[1], SQ_COLORS.control[2], SQ_COLORS.control[3], 1)
        self:SetBackdropBorderColor(dimColor[1], dimColor[2], dimColor[3], dimColor[4])
    end)
    btn.SetText = function(self, t) self.label:SetText(t) end
    btn.GetText = function(self) return self.label:GetText() end
    return btn
end

-- Helper: styled slider
function CreateSQSlider(parent, labelText, width, minVal, maxVal, step)
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(width, 40)

    local label = container:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("TOPLEFT", 0, 0)
    label:SetText(labelText)
    label:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])

    local valueText = container:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    valueText:SetPoint("TOPRIGHT", 0, 0)
    valueText:SetTextColor(SQ_COLORS.accent[1], SQ_COLORS.accent[2], SQ_COLORS.accent[3])

    -- Track background
    local track = CreateFrame("Frame", nil, container, "BackdropTemplate")
    track:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 0, -6)
    track:SetSize(width, 6)
    track:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeSize = 1,
    })
    track:SetBackdropColor(SQ_COLORS.control[1], SQ_COLORS.control[2], SQ_COLORS.control[3], 1)
    track:SetBackdropBorderColor(SQ_COLORS.border[1], SQ_COLORS.border[2], SQ_COLORS.border[3], 0.5)

    local slider = CreateFrame("Slider", nil, container, "BackdropTemplate")
    slider:SetPoint("TOPLEFT", track, "TOPLEFT", 0, 3)
    slider:SetPoint("BOTTOMRIGHT", track, "BOTTOMRIGHT", 0, -3)
    slider:SetMinMaxValues(minVal, maxVal)
    slider:SetValueStep(step)
    slider:SetObeyStepOnDrag(true)
    slider:SetOrientation("HORIZONTAL")

    -- Thumb
    local thumb = slider:CreateTexture(nil, "OVERLAY")
    thumb:SetSize(12, 14)
    thumb:SetColorTexture(SQ_COLORS.accent[1], SQ_COLORS.accent[2], SQ_COLORS.accent[3], 0.9)
    slider:SetThumbTexture(thumb)

    -- Fill bar
    local fill = slider:CreateTexture(nil, "ARTWORK")
    fill:SetHeight(4)
    fill:SetPoint("LEFT", track, "LEFT", 1, 0)
    fill:SetColorTexture(SQ_COLORS.accent[1], SQ_COLORS.accent[2], SQ_COLORS.accent[3], 0.35)

    slider:SetScript("OnValueChanged", function(self, value, userInput)
        value = math.floor(value / step + 0.5) * step
        valueText:SetText(tostring(math.floor(value)))
        -- Update fill width
        local range = maxVal - minVal
        if range > 0 then
            local pct = (value - minVal) / range
            fill:SetWidth(math.max(1, pct * width))
        end
        if self.onValueChanged then self.onValueChanged(value, userInput) end
    end)

    container.slider = slider
    container.SetValue = function(self, v)
        self.slider:SetValue(v)
    end
    container.GetValue = function(self)
        return self.slider:GetValue()
    end
    container.SetAfterValueChanged = function(self, fn)
        self.slider.onValueChanged = fn
    end
    return container
end

-- Helper: styled checkbox
function CreateSQCheckbox(parent, labelText, onChange)
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(250, 22)

    local box = CreateFrame("CheckButton", nil, container)
    box:SetSize(16, 16)
    box:SetPoint("LEFT", 0, 0)

    -- Box background
    local boxBG = box:CreateTexture(nil, "BACKGROUND")
    boxBG:SetAllPoints()
    boxBG:SetColorTexture(SQ_COLORS.control[1], SQ_COLORS.control[2], SQ_COLORS.control[3], 1)

    -- Box border
    local boxBorder = CreateFrame("Frame", nil, box, "BackdropTemplate")
    boxBorder:SetAllPoints()
    boxBorder:SetBackdrop({
        edgeFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeSize = 1,
    })
    boxBorder:SetBackdropBorderColor(SQ_COLORS.border[1], SQ_COLORS.border[2], SQ_COLORS.border[3], 0.8)

    -- Checkmark
    local check = box:CreateTexture(nil, "OVERLAY")
    check:SetSize(12, 12)
    check:SetPoint("CENTER")
    check:SetColorTexture(SQ_COLORS.accent[1], SQ_COLORS.accent[2], SQ_COLORS.accent[3], 0.9)
    box:SetCheckedTexture(check)

    local label = container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetPoint("LEFT", box, "RIGHT", 8, 0)
    label:SetText(labelText)
    label:SetTextColor(SQ_COLORS.text[1], SQ_COLORS.text[2], SQ_COLORS.text[3])

    box:SetScript("OnClick", function(self)
        if onChange then onChange(self:GetChecked()) end
    end)

    box:SetScript("OnEnter", function(self)
        boxBorder:SetBackdropBorderColor(SQ_COLORS.accent[1], SQ_COLORS.accent[2], SQ_COLORS.accent[3], 0.6)
    end)
    box:SetScript("OnLeave", function(self)
        boxBorder:SetBackdropBorderColor(SQ_COLORS.border[1], SQ_COLORS.border[2], SQ_COLORS.border[3], 0.8)
    end)

    container.checkbox = box
    container.SetChecked = function(self, v) self.checkbox:SetChecked(v) end
    container.GetChecked = function(self) return self.checkbox:GetChecked() end
    return container
end

-- Helper: styled color swatch (opens Blizzard ColorPickerFrame)
function CreateSQColorPicker(parent, labelText, r, g, b, a, onChange)
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(250, 22)

    local swatch = CreateFrame("Button", nil, container, "BackdropTemplate")
    swatch:SetSize(16, 16)
    swatch:SetPoint("LEFT", 0, 0)
    swatch:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeSize = 1,
    })
    swatch:SetBackdropColor(r or 0, g or 0, b or 0, 1)
    swatch:SetBackdropBorderColor(SQ_COLORS.border[1], SQ_COLORS.border[2], SQ_COLORS.border[3], 0.8)

    local label = container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetPoint("LEFT", swatch, "RIGHT", 8, 0)
    label:SetText(labelText)
    label:SetTextColor(SQ_COLORS.text[1], SQ_COLORS.text[2], SQ_COLORS.text[3])

    swatch:SetScript("OnClick", function()
        local info = {}
        info.r, info.g, info.b = r or 0, g or 0, b or 0
        info.opacity = a or 1
        info.hasOpacity = true
        info.swatchFunc = function()
            local cr, cg, cb = ColorPickerFrame:GetColorRGB()
            local ca = ColorPickerFrame:GetColorAlpha()
            swatch:SetBackdropColor(cr, cg, cb, 1)
            r, g, b, a = cr, cg, cb, ca
            if onChange then onChange(cr, cg, cb, ca) end
        end
        info.opacityFunc = info.swatchFunc
        info.cancelFunc = function(prev)
            swatch:SetBackdropColor(prev.r, prev.g, prev.b, 1)
            r, g, b, a = prev.r, prev.g, prev.b, prev.opacity
            if onChange then onChange(prev.r, prev.g, prev.b, prev.opacity) end
        end
        ColorPickerFrame:SetupColorPickerAndShow(info)
    end)

    swatch:SetScript("OnEnter", function(self)
        self:SetBackdropBorderColor(SQ_COLORS.accent[1], SQ_COLORS.accent[2], SQ_COLORS.accent[3], 0.6)
    end)
    swatch:SetScript("OnLeave", function(self)
        self:SetBackdropBorderColor(SQ_COLORS.border[1], SQ_COLORS.border[2], SQ_COLORS.border[3], 0.8)
    end)

    container.swatch = swatch
    container.SetColor = function(self, nr, ng, nb, na)
        r, g, b, a = nr, ng, nb, na
        self.swatch:SetBackdropColor(nr, ng, nb, 1)
    end
    return container
end

-- Helper: styled dropdown
function CreateSQDropdown(parent, labelText, width, items, onSelect)
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(width, 44)

    local label = container:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("TOPLEFT", 0, 0)
    label:SetText(labelText)
    label:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])

    local btn = CreateFrame("Button", nil, container, "BackdropTemplate")
    btn:SetSize(width, 24)
    btn:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 0, -4)
    btn:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeSize = 1,
    })
    btn:SetBackdropColor(SQ_COLORS.control[1], SQ_COLORS.control[2], SQ_COLORS.control[3], 1)
    btn:SetBackdropBorderColor(SQ_COLORS.border[1], SQ_COLORS.border[2], SQ_COLORS.border[3], 0.8)

    local selectedText = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    selectedText:SetPoint("LEFT", 8, 0)
    selectedText:SetTextColor(SQ_COLORS.text[1], SQ_COLORS.text[2], SQ_COLORS.text[3])

    local arrow = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    arrow:SetPoint("RIGHT", -8, 0)
    arrow:SetText("v")
    arrow:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])

    -- Dropdown menu frame
    local menu = CreateFrame("Frame", nil, btn, "BackdropTemplate")
    menu:SetPoint("TOPLEFT", btn, "BOTTOMLEFT", 0, -2)
    menu:SetWidth(width)
    menu:SetFrameStrata("FULLSCREEN_DIALOG")
    menu:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeSize = 1,
    })
    menu:SetBackdropColor(SQ_COLORS.bg[1], SQ_COLORS.bg[2], SQ_COLORS.bg[3], 0.98)
    menu:SetBackdropBorderColor(SQ_COLORS.border[1], SQ_COLORS.border[2], SQ_COLORS.border[3], 1)
    menu:Hide()

    local selectedValue = nil

    local function BuildMenu()
        -- Clear old children
        for _, child in pairs({menu:GetChildren()}) do child:Hide(); child:SetParent(nil) end

        -- Measure the widest label so the background fully encases all text.
        -- 4px left margin + 6px text pad + text + 8px right pad = text + 18px total extra.
        local scratch = menu:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        local maxTextW = 0
        for _, item in ipairs(items) do
            scratch:SetText(item.text)
            local tw = scratch:GetStringWidth()
            if tw > maxTextW then maxTextW = tw end
        end
        scratch:SetText("")
        local menuWidth = math.max(width, maxTextW + 18)
        menu:SetWidth(menuWidth)

        local y = -4
        for _, item in ipairs(items) do
            local opt = CreateFrame("Button", nil, menu)
            opt:SetSize(menuWidth - 8, 20)
            opt:SetPoint("TOPLEFT", menu, "TOPLEFT", 4, y)

            local optBG = opt:CreateTexture(nil, "BACKGROUND")
            optBG:SetAllPoints()
            optBG:SetColorTexture(0, 0, 0, 0)

            local optText = opt:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            optText:SetPoint("LEFT", 6, 0)
            optText:SetText(item.text)
            if item.value == selectedValue then
                optText:SetTextColor(SQ_COLORS.accent[1], SQ_COLORS.accent[2], SQ_COLORS.accent[3])
            else
                optText:SetTextColor(SQ_COLORS.text[1], SQ_COLORS.text[2], SQ_COLORS.text[3])
            end

            opt:SetScript("OnEnter", function() optBG:SetColorTexture(SQ_COLORS.controlHi[1], SQ_COLORS.controlHi[2], SQ_COLORS.controlHi[3], 1) end)
            opt:SetScript("OnLeave", function() optBG:SetColorTexture(0, 0, 0, 0) end)
            opt:SetScript("OnClick", function()
                selectedValue = item.value
                selectedText:SetText(item.text)
                menu:Hide()
                if onSelect then onSelect(item.value) end
            end)
            y = y - 20
        end
        menu:SetHeight(math.abs(y) + 4)
    end

    btn:SetScript("OnClick", function()
        if menu:IsShown() then
            menu:Hide()
        else
            BuildMenu()
            menu:Show()
        end
    end)
    btn:SetScript("OnEnter", function(self)
        self:SetBackdropBorderColor(SQ_COLORS.accent[1], SQ_COLORS.accent[2], SQ_COLORS.accent[3], 0.6)
    end)
    btn:SetScript("OnLeave", function(self)
        self:SetBackdropBorderColor(SQ_COLORS.border[1], SQ_COLORS.border[2], SQ_COLORS.border[3], 0.8)
    end)

    -- Close menu when clicking elsewhere
    local closer = CreateFrame("Button", nil, menu)
    closer:SetAllPoints(UIParent)
    closer:SetFrameStrata("FULLSCREEN")
    closer:SetScript("OnClick", function() menu:Hide(); closer:Hide() end)
    closer:Hide()
    menu:HookScript("OnShow", function() closer:Show() end)
    menu:HookScript("OnHide", function() closer:Hide() end)

    container.btn = btn
    container.label = label
    container.selectedText = selectedText
    container.SetSelectedValue = function(self, val)
        selectedValue = val
        for _, item in ipairs(items) do
            if item.value == val then
                selectedText:SetText(item.text)
                break
            end
        end
    end
    container.GetSelectedValue = function(self) return selectedValue end
    container.SetItems = function(self, newItems)
        items = newItems
    end
    return container
end

-- Helper: section divider line
function CreateSQDivider(parent, yOffset)
    local line = parent:CreateTexture(nil, "ARTWORK")
    line:SetHeight(1)
    line:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, yOffset)
    line:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, yOffset)
    line:SetColorTexture(SQ_COLORS.border[1], SQ_COLORS.border[2], SQ_COLORS.border[3], 0.3)
    return line
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
    panel:SetSize(460, 600)
    panel:SetPoint("CENTER")
    panel:SetFrameStrata("DIALOG")
    panel:SetMovable(true)
    panel:EnableMouse(true)
    ApplySQBackdrop(panel, SQ_COLORS.bg, SQ_COLORS.border)
    self.optionsPanel = panel

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

    -- Accent line under title
    local accentLine = titleBar:CreateTexture(nil, "OVERLAY")
    accentLine:SetHeight(1)
    accentLine:SetPoint("BOTTOMLEFT", titleBar, "BOTTOMLEFT", 0, 0)
    accentLine:SetPoint("BOTTOMRIGHT", titleBar, "BOTTOMRIGHT", 0, 0)
    accentLine:SetColorTexture(SQ_COLORS.accent[1], SQ_COLORS.accent[2], SQ_COLORS.accent[3], 0.4)

    -- Tab bar
    local tabBar = CreateFrame("Frame", nil, panel)
    tabBar:SetPoint("TOPLEFT", titleBar, "BOTTOMLEFT", 0, 0)
    tabBar:SetPoint("TOPRIGHT", titleBar, "BOTTOMRIGHT", 0, 0)

    local TAB_WIDTH = 110
    local TAB_HEIGHT = 28
    local TAB_PAD_LEFT = 12
    local TAB_GAP = 2
    local TAB_MAX_WIDTH = 460 - TAB_PAD_LEFT -- panel width minus left padding

    local tabCursorX = TAB_PAD_LEFT
    local tabCursorRow = 0

    local function CreateTab(text)
        -- Wrap to next row if this tab won't fit
        if tabCursorX + TAB_WIDTH > TAB_MAX_WIDTH + TAB_PAD_LEFT then
            tabCursorRow = tabCursorRow + 1
            tabCursorX = TAB_PAD_LEFT
        end

        local tab = CreateFrame("Button", nil, tabBar, "BackdropTemplate")
        tab:SetSize(TAB_WIDTH, TAB_HEIGHT)
        tab:SetPoint("TOPLEFT", tabBar, "TOPLEFT", tabCursorX, -(tabCursorRow * TAB_HEIGHT))
        tabCursorX = tabCursorX + TAB_WIDTH + TAB_GAP

        tab:SetBackdrop({ bgFile = "Interface\\BUTTONS\\WHITE8X8" })
        tab:SetBackdropColor(SQ_COLORS.tabInactive[1], SQ_COLORS.tabInactive[2], SQ_COLORS.tabInactive[3], 1)

        local tabLabel = tab:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        tabLabel:SetPoint("CENTER")
        tabLabel:SetText(text)
        tabLabel:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])
        tab.label = tabLabel

        -- Active underline
        local underline = tab:CreateTexture(nil, "OVERLAY")
        underline:SetHeight(2)
        underline:SetPoint("BOTTOMLEFT", tab, "BOTTOMLEFT", 0, 0)
        underline:SetPoint("BOTTOMRIGHT", tab, "BOTTOMRIGHT", 0, 0)
        underline:SetColorTexture(SQ_COLORS.accent[1], SQ_COLORS.accent[2], SQ_COLORS.accent[3], 1)
        underline:Hide()
        tab.underline = underline

        tab.SetActive = function(self, active)
            if active then
                self:SetBackdropColor(SQ_COLORS.tabActive[1], SQ_COLORS.tabActive[2], SQ_COLORS.tabActive[3], 1)
                self.label:SetTextColor(SQ_COLORS.textBright[1], SQ_COLORS.textBright[2], SQ_COLORS.textBright[3])
                self.underline:Show()
            else
                self:SetBackdropColor(SQ_COLORS.tabInactive[1], SQ_COLORS.tabInactive[2], SQ_COLORS.tabInactive[3], 1)
                self.label:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])
                self.underline:Hide()
            end
        end
        return tab
    end

    local settingsTabBtn = CreateTab("Settings")
    local itemsTabBtn = CreateTab("Items")
    local classBuffsTabBtn = CreateTab("Class Buffs")
    local raidToolsTabBtn = CreateTab("Raid Tools")
    local textRemindersTabBtn = CreateTab("Reminders")
    local cdmTabBtn = CreateTab("Cooldowns")
    local soundsTabBtn = CreateTab("Sounds")
    local calloutsTabBtn = CreateTab("Callouts")
    local kelTabBtn = CreateTab("Kelerts")
    local cdmSoundsTabBtn = CreateTab("CDM Sounds")
    cdmSoundsTabBtn:Hide()  -- hidden until /squizz CDMS

    -- Set tab bar height based on actual rows used
    tabBar:SetHeight((tabCursorRow + 1) * TAB_HEIGHT)

    -- Content area
    local contentArea = CreateFrame("Frame", nil, panel)
    contentArea:SetPoint("TOPLEFT", tabBar, "BOTTOMLEFT", 0, -1)
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
        cdmSoundsTabBtn:SetActive(active == "cdmsounds")
        if active == "settings" then settingsTab:Show() else settingsTab:Hide() end
        if active == "items" then itemsTab:Show() else itemsTab:Hide() end
        if active == "raidtools" then raidToolsTab:Show() else raidToolsTab:Hide() end
        if active == "reminders" then textRemindersTab:Show() else textRemindersTab:Hide() end
        if active == "cdm" then cdmTab:Show() else cdmTab:Hide() end
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
    soundsTabBtn:SetScript("OnClick", function() SwitchTab("sounds") end)
    classBuffsTabBtn:SetScript("OnClick", function() SwitchTab("classbuffs") end)
    calloutsTabBtn:SetScript("OnClick", function() SwitchTab("callouts") end)
    kelTabBtn:SetScript("OnClick", function() SwitchTab("kel") end)
    cdmSoundsTabBtn:SetScript("OnClick", function() SwitchTab("cdmsounds") end)
    self.switchTab = SwitchTab
    SwitchTab("settings")

    -- Build settings tab
    self:BuildSettingsTab(settingsTab)

    -- Build raid tools tab
    self:BuildRaidToolsTab(raidToolsTab)

    -- Build text reminders tab
    self:BuildTextRemindersTab(textRemindersTab)

    -- Build cooldown manager tab
    if self.BuildCDMTab then
        self:BuildCDMTab(cdmTab)
    end

    -- Build sounds tab
    self:BuildSoundsTab(soundsTab)

    -- Build class buffs tab
    self:BuildClassBuffsTab(classBuffsTab)

    -- Build callouts tab
    self:BuildCalloutsTab(calloutsTab)

    -- Build Just For Kel tab
    if self.BuildJustForKelTab then
        self:BuildJustForKelTab(kelTab)
    end

    -- Build CDM Sounds tab
    if self.BuildCDMSoundsTab then
        self:BuildCDMSoundsTab(cdmSoundsTab)
    end

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
            BH:RefreshSettingsTab()
            print("Squizzumables: Deleted profile '" .. data .. "', switched to Default.")
        end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

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
    profileSection:SetTextColor(SQ_COLORS.accent[1], SQ_COLORS.accent[2], SQ_COLORS.accent[3])
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
    sectionLabel:SetTextColor(SQ_COLORS.accent[1], SQ_COLORS.accent[2], SQ_COLORS.accent[3])
    yOffset = yOffset - 22

    -- Button Size
    local sizeSlider = CreateSQSlider(content, "Button Size", 300, 20, 64, 2)
    sizeSlider:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    sizeSlider:SetAfterValueChanged(function(value)
        BH.settings.buttonSize = value
        BH:SaveSettings()
        BH:UpdateButtons()
    end)
    self.sizeSlider = sizeSlider
    yOffset = yOffset - 50

    -- Button Spacing
    local spacingSlider = CreateSQSlider(content, "Button Spacing", 300, 5, 20, 1)
    spacingSlider:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    spacingSlider:SetAfterValueChanged(function(value)
        BH.settings.buttonSpacing = value
        BH:SaveSettings()
        BH:UpdateButtons()
    end)
    self.spacingSlider = spacingSlider
    yOffset = yOffset - 50

    -- Show Label Text
    local labelCheckbox = CreateSQCheckbox(content, "Show Label Text", function(checked)
        BH.settings.showLabelText = checked
        BH:SaveSettings()
        BH:UpdateButtons()
    end)
    labelCheckbox:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    self.labelCheckbox = labelCheckbox
    yOffset = yOffset - 30

    CreateSQDivider(content, yOffset)
    yOffset = yOffset - 14

    -- === Layout Section ===
    local layoutSection = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    layoutSection:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    layoutSection:SetText("LAYOUT")
    layoutSection:SetTextColor(SQ_COLORS.accent[1], SQ_COLORS.accent[2], SQ_COLORS.accent[3])
    yOffset = yOffset - 22

    -- Layout Direction
    local layoutDropdown = CreateSQDropdown(content, "Layout Direction", 160, {
        { text = "Horizontal", value = "HORIZONTAL" },
        { text = "Vertical", value = "VERTICAL" },
    }, function(value)
        BH.settings.layoutDirection = value
        BH:ValidateGrowDirection()
        BH:SaveSettings()
        if BH.growDropdown then
            BH.growDropdown:SetItems(BH:GetGrowItemsForLayout(value))
            BH.growDropdown:SetSelectedValue(BH.settings.growDirection)
        end
        BH:UpdateDragHandlePosition()
        BH:UpdateButtons()
    end)
    layoutDropdown:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    self.layoutDropdown = layoutDropdown
    yOffset = yOffset - 56

    -- Grow Direction
    local growDropdown = CreateSQDropdown(content, "Grow Direction", 160,
        BH:GetGrowItemsForLayout(BH.settings.layoutDirection or "HORIZONTAL"),
        function(value)
            BH.settings.growDirection = value
            BH:SaveSettings()
            BH:UpdateDragHandlePosition()
            BH:UpdateButtons()
        end)
    growDropdown:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    self.growDropdown = growDropdown
    yOffset = yOffset - 56

    -- Anchor Point
    local anchorDropdown = CreateSQDropdown(content, "Anchor Point", 160, {
        { text = "Top", value = "TOP" },
        { text = "Left", value = "LEFT" },
        { text = "Center", value = "CENTER" },
        { text = "Right", value = "RIGHT" },
        { text = "Bottom", value = "BOTTOM" },
    }, function(value)
        BH.settings.anchorPoint = value
        BH:SaveSettings()
        BH:UpdateButtons()
        BH:UpdateFrameAnchor()
    end)
    anchorDropdown:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    self.anchorDropdown = anchorDropdown
    yOffset = yOffset - 56

    -- Lock Frame
    local lockCheckbox = CreateSQCheckbox(content, "Lock Frame Position", function(checked)
        BH.settings.frameLocked = checked
        BH:SaveSettings()
        BH:UpdateFrameLock()
    end)
    lockCheckbox:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    self.lockCheckbox = lockCheckbox
    yOffset = yOffset - 34

    CreateSQDivider(content, yOffset)
    yOffset = yOffset - 14

    -- === Button Text Section ===
    local btnTextSection = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    btnTextSection:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    btnTextSection:SetText("BUTTON TEXT")
    btnTextSection:SetTextColor(SQ_COLORS.accent[1], SQ_COLORS.accent[2], SQ_COLORS.accent[3])
    yOffset = yOffset - 22

    -- Label font size
    local labelFontSlider = CreateSQSlider(content, "Label Font Size", 300, 6, 24, 1)
    labelFontSlider:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    labelFontSlider:SetAfterValueChanged(function(value)
        BH.settings.buttonLabelFontSize = value
        BH:SaveSettings()
        BH:UpdateButtons()
    end)
    self.labelFontSlider = labelFontSlider
    yOffset = yOffset - 50

    -- Timer font size
    local timerFontSlider = CreateSQSlider(content, "Timer Font Size", 300, 6, 24, 1)
    timerFontSlider:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    timerFontSlider:SetAfterValueChanged(function(value)
        BH.settings.buttonTimerFontSize = value
        BH:SaveSettings()
        BH:UpdateButtons()
    end)
    self.timerFontSlider = timerFontSlider
    yOffset = yOffset - 50

    -- Count font size
    local countFontSlider = CreateSQSlider(content, "Count Font Size", 300, 6, 24, 1)
    countFontSlider:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    countFontSlider:SetAfterValueChanged(function(value)
        BH.settings.buttonCountFontSize = value
        BH:SaveSettings()
        BH:UpdateButtons()
    end)
    self.countFontSlider = countFontSlider
    yOffset = yOffset - 50

    -- Header font size
    local headerFontSlider = CreateSQSlider(content, "Header Font Size (MH/OH)", 300, 6, 24, 1)
    headerFontSlider:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    headerFontSlider:SetAfterValueChanged(function(value)
        BH.settings.buttonHeaderFontSize = value
        BH:SaveSettings()
        BH:UpdateButtons()
    end)
    self.headerFontSlider = headerFontSlider
    yOffset = yOffset - 50

    -- Label X offset
    local labelOffXSlider = CreateSQSlider(content, "Label X Offset", 300, -20, 20, 1)
    labelOffXSlider:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    labelOffXSlider:SetAfterValueChanged(function(value)
        BH.settings.buttonLabelOffsetX = value
        BH:SaveSettings()
        BH:UpdateButtons()
    end)
    self.labelOffXSlider = labelOffXSlider
    yOffset = yOffset - 50

    -- Label Y offset
    local labelOffYSlider = CreateSQSlider(content, "Label Y Offset", 300, -20, 10, 1)
    labelOffYSlider:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    labelOffYSlider:SetAfterValueChanged(function(value)
        BH.settings.buttonLabelOffsetY = value
        BH:SaveSettings()
        BH:UpdateButtons()
    end)
    self.labelOffYSlider = labelOffYSlider
    yOffset = yOffset - 50

    CreateSQDivider(content, yOffset)
    yOffset = yOffset - 14

    -- === Preview & Reset Section ===
    local toolsSection = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    toolsSection:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    toolsSection:SetText("TOOLS")
    toolsSection:SetTextColor(SQ_COLORS.accent[1], SQ_COLORS.accent[2], SQ_COLORS.accent[3])
    yOffset = yOffset - 24

    -- Preview button
    local previewBtn = CreateSQButton(content, "Preview", 140, 26)
    previewBtn:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    previewBtn:SetScript("OnClick", function()
        BH.previewMode = not BH.previewMode
        if BH.previewMode then
            previewBtn:SetText("Hide Preview")
            print("Squizzumables: Preview mode ON - all frames visible")
        else
            previewBtn:SetText("Preview")
            print("Squizzumables: Preview mode OFF")
        end
        BH:UpdateButtons()
        BH:UpdateRaidToolsVisibility()
        BH:RefreshAllReminderFrames()
    end)
    self.previewBtn = previewBtn
    yOffset = yOffset - 36

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
        BH:UpdateDragHandlePosition()
        BH:RefreshSettingsTab()
        BH:UpdateButtons()
    end)
    yOffset = yOffset - 40

    -- === Misc ===
    CreateSQDivider(content, yOffset)
    yOffset = yOffset - 14

    local miscLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    miscLabel:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    miscLabel:SetText("MISC")
    miscLabel:SetTextColor(SQ_COLORS.accent[1], SQ_COLORS.accent[2], SQ_COLORS.accent[3])
    yOffset = yOffset - 22

    local guildInviteCB = CreateSQCheckbox(content, "Guild Invite on Right-Click", function(checked)
        BH.settings.guildInviteContextEnabled = (checked == true)
        BH:SaveSettings()
    end)
    guildInviteCB:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    self.guildInviteCB = guildInviteCB
    yOffset = yOffset - 28

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
    -- Profile dropdown
    if self.profileDropdown then
        local items = {}
        for _, name in ipairs(self:GetProfileList()) do
            table.insert(items, { text = name, value = name })
        end
        self.profileDropdown:SetItems(items)
        self.profileDropdown:SetSelectedValue(self:GetActiveProfileName())
    end
    -- Spec profile dropdown
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
        local currentSpecProfile = self:GetSpecProfile()
        self.specProfileDropdown:SetSelectedValue(currentSpecProfile or "")
    end
    if self.sizeSlider then
        self.sizeSlider:SetValue(self.settings.buttonSize or 36)
    end
    if self.spacingSlider then
        self.spacingSlider:SetValue(self.settings.buttonSpacing or 5)
    end
    if self.lockCheckbox then
        self.lockCheckbox:SetChecked(self.settings.frameLocked or false)
    end
    if self.labelCheckbox then
        self.labelCheckbox:SetChecked(self.settings.showLabelText ~= false)
    end
    if self.previewBtn then
        self.previewBtn:SetText(self.previewMode and "Hide Preview" or "Preview")
    end
    if self.anchorDropdown then
        self.anchorDropdown:SetSelectedValue(self.settings.anchorPoint or "LEFT")
    end
    if self.growDropdown then
        self.growDropdown:SetItems(self:GetGrowItemsForLayout(self.settings.layoutDirection or "HORIZONTAL"))
        self.growDropdown:SetSelectedValue(self.settings.growDirection or "RIGHT")
    end
    if self.layoutDropdown then
        self.layoutDropdown:SetSelectedValue(self.settings.layoutDirection or "HORIZONTAL")
    end
    if self.labelFontSlider then
        self.labelFontSlider:SetValue(self.settings.buttonLabelFontSize or 10)
    end
    if self.timerFontSlider then
        self.timerFontSlider:SetValue(self.settings.buttonTimerFontSize or 10)
    end
    if self.countFontSlider then
        self.countFontSlider:SetValue(self.settings.buttonCountFontSize or 10)
    end
    if self.headerFontSlider then
        self.headerFontSlider:SetValue(self.settings.buttonHeaderFontSize or 10)
    end
    if self.labelOffXSlider then
        self.labelOffXSlider:SetValue(self.settings.buttonLabelOffsetX or 0)
    end
    if self.labelOffYSlider then
        self.labelOffYSlider:SetValue(self.settings.buttonLabelOffsetY or -2)
    end
    if self.guildInviteCB then
        self.guildInviteCB:SetChecked(BH.settings.guildInviteContextEnabled ~= false)
    end

end

-- ============================================================================
-- Raid Tools Settings Tab
-- ============================================================================

function BH:BuildRaidToolsTab(parent)
    local scrollFrame = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    scrollFrame:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -22, 0)

    local content = CreateFrame("Frame", nil, scrollFrame)
    content:SetWidth(400)
    scrollFrame:SetScrollChild(content)

    local yOffset = -14
    local leftPad = 14

    -- === Module Toggle ===
    local sectionLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sectionLabel:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    sectionLabel:SetText("MODULE")
    sectionLabel:SetTextColor(SQ_COLORS.accent[1], SQ_COLORS.accent[2], SQ_COLORS.accent[3])
    yOffset = yOffset - 22

    local enableCheckbox = CreateSQCheckbox(content, "Enable Raid Tools", function(checked)
        BH.settings.raidToolsEnabled = checked
        BH:SaveSettings()
        BH:UpdateRaidToolsVisibility()
    end)
    enableCheckbox:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    self.rtEnableCheckbox = enableCheckbox
    yOffset = yOffset - 28

    local desc = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    desc:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    desc:SetWidth(380)
    desc:SetJustifyH("LEFT")
    desc:SetText("Two movable frames: a compact markers frame (world + target markers) and a pull/ready frame (ready check + pull timer). Only visible when you are the group leader or assistant.")
    desc:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])
    yOffset = yOffset - 42

    CreateSQDivider(content, yOffset)
    yOffset = yOffset - 14

    -- === Frames ===
    local framesLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    framesLabel:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    framesLabel:SetText("FRAMES")
    framesLabel:SetTextColor(SQ_COLORS.accent[1], SQ_COLORS.accent[2], SQ_COLORS.accent[3])
    yOffset = yOffset - 22

    local markersCheckbox = CreateSQCheckbox(content, "Show Markers Frame", function(checked)
        BH.settings.raidToolsShowMarkers = checked
        BH:SaveSettings()
        BH:UpdateRaidToolsVisibility()
    end)
    markersCheckbox:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    self.rtMarkersCheckbox = markersCheckbox
    yOffset = yOffset - 28

    local pullReadyCheckbox = CreateSQCheckbox(content, "Show Pull/Ready Frame", function(checked)
        BH.settings.raidToolsShowPullReady = checked
        BH:SaveSettings()
        BH:UpdateRaidToolsVisibility()
    end)
    pullReadyCheckbox:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    self.rtPullReadyCheckbox = pullReadyCheckbox
    yOffset = yOffset - 34

    CreateSQDivider(content, yOffset)
    yOffset = yOffset - 14

    -- === Markers Layout ===
    local layoutLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    layoutLabel:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    layoutLabel:SetText("MARKERS LAYOUT")
    layoutLabel:SetTextColor(SQ_COLORS.accent[1], SQ_COLORS.accent[2], SQ_COLORS.accent[3])
    yOffset = yOffset - 22

    local function GetMarkersGrowItems(layout)
        if layout == "VERTICAL" then
            return {
                { text = "Down", value = "DOWN" },
                { text = "Up",   value = "UP" },
            }
        else
            return {
                { text = "Left",  value = "LEFT" },
                { text = "Right", value = "RIGHT" },
            }
        end
    end

    local markersLayoutDropdown = CreateSQDropdown(content, "Layout Direction", 200, {
        { text = "Horizontal", value = "HORIZONTAL" },
        { text = "Vertical",   value = "VERTICAL" },
    }, function(value)
        BH.settings.raidToolsMarkersLayout = value
        -- Reset grow direction to first valid option for new layout
        local newGrow = (value == "VERTICAL") and "DOWN" or "LEFT"
        BH.settings.raidToolsMarkersGrow = newGrow
        BH:SaveSettings()
        if self.rtMarkersGrowDropdown then
            self.rtMarkersGrowDropdown:SetItems(GetMarkersGrowItems(value))
            self.rtMarkersGrowDropdown:SetSelectedValue(newGrow)
        end
        BH:UpdateMarkersLayout()
    end)
    markersLayoutDropdown:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    self.rtMarkersLayoutDropdown = markersLayoutDropdown
    yOffset = yOffset - 52

    local markersGrowDropdown = CreateSQDropdown(content, "Grow Direction", 200,
        GetMarkersGrowItems(BH.settings.raidToolsMarkersLayout or "HORIZONTAL"),
    function(value)
        BH.settings.raidToolsMarkersGrow = value
        BH:SaveSettings()
        BH:UpdateMarkersLayout()
    end)
    markersGrowDropdown:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    self.rtMarkersGrowDropdown = markersGrowDropdown
    yOffset = yOffset - 52

    CreateSQDivider(content, yOffset)
    yOffset = yOffset - 14

    -- === Pull Timer Settings ===
    local pullLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    pullLabel:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    pullLabel:SetText("PULL TIMER")
    pullLabel:SetTextColor(SQ_COLORS.accent[1], SQ_COLORS.accent[2], SQ_COLORS.accent[3])
    yOffset = yOffset - 22

    local pullSlider = CreateSQSlider(content, "Countdown Duration (seconds)", 300, 3, 30, 1)
    pullSlider:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    pullSlider:SetAfterValueChanged(function(value)
        BH.settings.raidToolsPullTimer = value
        BH:SaveSettings()
        if BH.rtPullBtn and not BH.rtPullActive then
            BH.rtPullBtn.label:SetText("Pull " .. value .. "s")
        end
    end)
    self.rtPullSlider = pullSlider
    yOffset = yOffset - 50

    CreateSQDivider(content, yOffset)
    yOffset = yOffset - 14

    -- === Scale Settings ===
    local scaleLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    scaleLabel:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    scaleLabel:SetText("SCALE")
    scaleLabel:SetTextColor(SQ_COLORS.accent[1], SQ_COLORS.accent[2], SQ_COLORS.accent[3])
    yOffset = yOffset - 22

    local markersScaleSlider = CreateSQSlider(content, "Markers Frame Scale", 300, 50, 200, 5)
    markersScaleSlider:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    markersScaleSlider:SetAfterValueChanged(function(value, userInput)
        BH.settings.raidToolsMarkersScale = value / 100
        BH:SaveSettings()
        if userInput and BH.markersFrame then
            BH.markersFrame:SetScale(value / 100)
        end
    end)
    self.rtMarkersScaleSlider = markersScaleSlider
    yOffset = yOffset - 50

    local prScaleSlider = CreateSQSlider(content, "Pull/Ready Frame Scale", 300, 50, 200, 5)
    prScaleSlider:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    prScaleSlider:SetAfterValueChanged(function(value, userInput)
        BH.settings.raidToolsPullReadyScale = value / 100
        BH:SaveSettings()
        if userInput and BH.pullReadyFrame then
            BH.pullReadyFrame:SetScale(value / 100)
        end
    end)
    self.rtPRScaleSlider = prScaleSlider
    yOffset = yOffset - 50

    CreateSQDivider(content, yOffset)
    yOffset = yOffset - 14

    -- === Battle Res Counter ===
    local bresLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    bresLabel:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    bresLabel:SetText("BATTLE RES COUNTER")
    bresLabel:SetTextColor(SQ_COLORS.accent[1], SQ_COLORS.accent[2], SQ_COLORS.accent[3])
    yOffset = yOffset - 22

    local bresCheckbox = CreateSQCheckbox(content, "Enable Battle Res Counter", function(checked)
        BH.settings.bresCounterEnabled = checked
        BH:SaveSettings()
        if not checked and BH.bresCounterFrame then
            BH.bresCounterFrame:Hide()
        end
    end)
    bresCheckbox:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    self.rtBresCheckbox = bresCheckbox
    yOffset = yOffset - 34

    local bresScaleSlider = CreateSQSlider(content, "Battle Res Counter Scale", 300, 50, 200, 5)
    bresScaleSlider:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    bresScaleSlider:SetAfterValueChanged(function(value, userInput)
        BH.settings.bresCounterScale = value / 100
        BH:SaveSettings()
        if userInput and BH.bresCounterFrame then
            BH.bresCounterFrame:SetScale(value / 100)
        end
    end)
    self.rtBresScaleSlider = bresScaleSlider
    yOffset = yOffset - 50

    local lockBresCheckbox = CreateSQCheckbox(content, "Lock Battle Res Counter", function(checked)
        BH.settings.bresCounterLocked = checked
        BH:SaveSettings()
        if BH.bresCounterFrame then
            BH.bresCounterFrame:SetMovable(not checked)
            BH.bresCounterFrame:EnableMouse(not checked)
        end
    end)
    lockBresCheckbox:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    self.rtLockBresCheckbox = lockBresCheckbox
    yOffset = yOffset - 34

    CreateSQDivider(content, yOffset)
    yOffset = yOffset - 14

    -- === Lock Settings ===
    local lockLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lockLabel:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    lockLabel:SetText("POSITION")
    lockLabel:SetTextColor(SQ_COLORS.accent[1], SQ_COLORS.accent[2], SQ_COLORS.accent[3])
    yOffset = yOffset - 22

    local lockMarkersCheckbox = CreateSQCheckbox(content, "Lock Markers Frame", function(checked)
        BH.settings.raidToolsMarkersLocked = checked
        BH:SaveSettings()
        if BH.markersFrame then
            BH.markersFrame:SetMovable(not checked)
        end
        if BH.markersDragHandle then
            if checked then BH.markersDragHandle:Hide() else BH.markersDragHandle:Show() end
        end
    end)
    lockMarkersCheckbox:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    self.rtLockMarkersCheckbox = lockMarkersCheckbox
    yOffset = yOffset - 28

    local lockPRCheckbox = CreateSQCheckbox(content, "Lock Pull/Ready Frame", function(checked)
        BH.settings.raidToolsPullReadyLocked = checked
        BH:SaveSettings()
        if BH.pullReadyFrame then
            BH.pullReadyFrame:SetMovable(not checked)
        end
        if BH.pullReadyDragHandle then
            if checked then BH.pullReadyDragHandle:Hide() else BH.pullReadyDragHandle:Show() end
        end
    end)
    lockPRCheckbox:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    self.rtLockPRCheckbox = lockPRCheckbox
    yOffset = yOffset - 34

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
            SquizzumablesDB.foodReminderPosition = nil
            SquizzumablesDB.flaskReminderPosition = nil
            SquizzumablesDB.oilReminderPosition = nil
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
        if BH.foodReminderFrame then
            BH.foodReminderFrame:ClearAllPoints()
            BH.foodReminderFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 240)
        end
        if BH.flaskReminderFrame then
            BH.flaskReminderFrame:ClearAllPoints()
            BH.flaskReminderFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 280)
        end
        if BH.oilReminderFrame then
            BH.oilReminderFrame:ClearAllPoints()
            BH.oilReminderFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 320)
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
end

function BH:RefreshRaidToolsTab()
    if not self.settings then return end
    if self.rtEnableCheckbox then
        self.rtEnableCheckbox:SetChecked(self.settings.raidToolsEnabled ~= false)
    end
    if self.rtMarkersCheckbox then
        self.rtMarkersCheckbox:SetChecked(self.settings.raidToolsShowMarkers ~= false)
    end
    if self.rtPullReadyCheckbox then
        self.rtPullReadyCheckbox:SetChecked(self.settings.raidToolsShowPullReady ~= false)
    end
    if self.rtPullSlider then
        self.rtPullSlider:SetValue(self.settings.raidToolsPullTimer or 10)
    end
    if self.rtMarkersScaleSlider then
        self.rtMarkersScaleSlider:SetValue((self.settings.raidToolsMarkersScale or 1.0) * 100)
    end
    if self.rtPRScaleSlider then
        self.rtPRScaleSlider:SetValue((self.settings.raidToolsPullReadyScale or 1.0) * 100)
    end
    if self.rtLockMarkersCheckbox then
        self.rtLockMarkersCheckbox:SetChecked(self.settings.raidToolsMarkersLocked or false)
    end
    if self.rtLockPRCheckbox then
        self.rtLockPRCheckbox:SetChecked(self.settings.raidToolsPullReadyLocked or false)
    end
    if self.rtMarkersLayoutDropdown then
        self.rtMarkersLayoutDropdown:SetSelectedValue(self.settings.raidToolsMarkersLayout or "HORIZONTAL")
    end
    if self.rtMarkersGrowDropdown then
        self.rtMarkersGrowDropdown:SetSelectedValue(self.settings.raidToolsMarkersGrow or "LEFT")
    end
    if self.rtBresCheckbox then
        self.rtBresCheckbox:SetChecked(self.settings.bresCounterEnabled ~= false)
    end
    if self.rtBresScaleSlider then
        self.rtBresScaleSlider:SetValue((self.settings.bresCounterScale or 1.0) * 100)
    end
    if self.rtLockBresCheckbox then
        self.rtLockBresCheckbox:SetChecked(self.settings.bresCounterLocked or false)
    end

end

-- ============================================================================
-- LibSharedMedia-3.0 helper (optional — gracefully absent if LSM not loaded)
-- ============================================================================

local CUSTOM_SOUNDS_PATH = "Interface\\AddOns\\Squizzumables\\Media\\Sounds\\"

-- Returns the LSM instance if any loaded addon has registered it, else nil.
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
-- Healer CC Alert
-- ============================================================================
local healerWatchUnits = {}  -- unit token → true for healers in the group
local healerCCActive   = {}  -- unit token → true when that healer has an active CC debuff

local function UnitHasCCDebuff(unit)
    -- Guard: unit must exist, be connected, and still be a valid group member.
    -- When a healer zones into an instance or goes out of range, UNIT_AURA
    -- fires during the transition but the unit is no longer reachable —
    -- reading auras in that window returns stale or garbage data and can
    -- trigger a false "HEALER IN CC" alert.
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

function BH:RefreshHealerWatchList()
    wipe(healerWatchUnits)
    wipe(healerCCActive)
    if not IsInGroup() then return end
    local isRaid = IsInRaid()
    local count  = GetNumGroupMembers()
    for i = 1, count do
        local unit = (isRaid and "raid" or "party") .. i
        -- Only track healers who exist AND are connected (not phased out,
        -- not in a different instance/zone).  This prevents the alert from
        -- firing on stale aura data during zone transitions.
        if UnitExists(unit) and not UnitIsUnit(unit, "player")
            and UnitIsConnected(unit)
        then
            if UnitGroupRolesAssigned(unit) == "HEALER" then
                healerWatchUnits[unit] = true
            end
        end
    end
end

function BH:CheckHealerCC(unit)
    if not self.settings or not self.settings.healerCCAlertEnabled then
        if self.healerCCReminderFrame then self.healerCCReminderFrame:Hide() end
        return
    end
    if not unit or not healerWatchUnits[unit] then return end

    -- Skip units that are offline, out of range, or in a different zone/
    -- instance.  UnitIsConnected returns false when the player has
    -- disconnected or phased out; UnitExists returns false when the unit
    -- token is no longer valid.  Checking both prevents false positives
    -- during zone transitions where UNIT_AURA fires with stale data.
    if not UnitExists(unit) or not UnitIsConnected(unit) then
        -- Clear any lingering CC state for this unit so the alert frame
        -- doesn't stay visible from a previous real CC that was never
        -- cleared (the healer zoned out before the CC wore off).
        if healerCCActive[unit] then
            healerCCActive[unit] = nil
            if self.healerCCReminderFrame then
                -- Re-evaluate: hide if no other healer is CC'd
                local anyCC = false
                for u in pairs(healerWatchUnits) do
                    if healerCCActive[u] then anyCC = true; break end
                end
                if not anyCC then self.healerCCReminderFrame:Hide() end
            end
        end
        return
    end

    local hasCC = UnitHasCCDebuff(unit)
    local hadCC = healerCCActive[unit]
    healerCCActive[unit] = hasCC or nil
    if hasCC and not hadCC then
        PlaySQSound(self.settings.healerCCAlertSound or "None")
    end
    -- Update the visual reminder: show if ANY watched healer is CC'd
    if self.healerCCReminderFrame then
        local anyCC = false
        for u in pairs(healerWatchUnits) do
            if healerCCActive[u] then anyCC = true; break end
        end
        if anyCC then
            local locked = self.settings and self.settings.healerCCReminderLocked
            self.healerCCReminderFrame:EnableMouse(self.previewMode or not locked)
            self.healerCCReminderFrame:Show()
        else
            self.healerCCReminderFrame:Hide()
        end
    end
end

-- ============================================================================
-- Text Reminders Settings Tab
-- ============================================================================

function BH:BuildTextRemindersTab(parent)
    local scrollFrame = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    scrollFrame:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -22, 0)

    local content = CreateFrame("Frame", nil, scrollFrame)
    content:SetWidth(400)
    scrollFrame:SetScrollChild(content)

    local yOffset = -14
    local leftPad = 14

    -- === Beacon Reminder (Holy Paladin) ===
    local beaconLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    beaconLabel:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    beaconLabel:SetText("BEACON REMINDER (HOLY PALADIN)")
    beaconLabel:SetTextColor(SQ_COLORS.accent[1], SQ_COLORS.accent[2], SQ_COLORS.accent[3])
    yOffset = yOffset - 22

    local enableBeaconCheckbox = CreateSQCheckbox(content, "Enable Beacon Reminder", function(checked)
        BH.settings.beaconReminderEnabled = checked
        BH:SaveSettings()
        BH:UpdateBeaconReminder()
    end)
    enableBeaconCheckbox:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    self.trEnableBeaconCheckbox = enableBeaconCheckbox
    yOffset = yOffset - 34

    local beaconScaleSlider = CreateSQSlider(content, "Beacon Reminder Scale", 300, 50, 200, 5)
    beaconScaleSlider:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    beaconScaleSlider:SetAfterValueChanged(function(value, userInput)
        BH.settings.beaconReminderScale = value / 100
        BH:SaveSettings()
        if userInput and BH.beaconReminderFrame then
            BH.beaconReminderFrame:SetScale(value / 100)
        end
    end)
    self.trBeaconScaleSlider = beaconScaleSlider
    yOffset = yOffset - 50

    local lockBeaconCheckbox = CreateSQCheckbox(content, "Lock Beacon Reminder", function(checked)
        BH.settings.beaconReminderLocked = checked
        BH:SaveSettings()
        if BH.beaconReminderFrame then
            BH.beaconReminderFrame:SetMovable(not checked)
            BH.beaconReminderFrame:EnableMouse(not checked)
        end
    end)
    lockBeaconCheckbox:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    self.trLockBeaconCheckbox = lockBeaconCheckbox
    yOffset = yOffset - 34

    -- === Earth Shield Reminder (Shaman) ===
    local esDivider = CreateSQDivider(content, yOffset)
    esDivider:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    yOffset = yOffset - 18

    local esLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    esLabel:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    esLabel:SetText("EARTH SHIELD REMINDER (SHAMAN)")
    esLabel:SetTextColor(SQ_COLORS.accent[1], SQ_COLORS.accent[2], SQ_COLORS.accent[3])
    yOffset = yOffset - 22

    local enableESCheckbox = CreateSQCheckbox(content, "Enable Earth Shield Reminder", function(checked)
        BH.settings.earthShieldReminderEnabled = checked
        BH:SaveSettings()
        BH:UpdateEarthShieldReminder()
    end)
    enableESCheckbox:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    self.trEnableESCheckbox = enableESCheckbox
    yOffset = yOffset - 34

    local esScaleSlider = CreateSQSlider(content, "Earth Shield Reminder Scale", 300, 50, 200, 5)
    esScaleSlider:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    esScaleSlider:SetAfterValueChanged(function(value, userInput)
        BH.settings.earthShieldReminderScale = value / 100
        BH:SaveSettings()
        if userInput and BH.earthShieldReminderFrame then
            BH.earthShieldReminderFrame:SetScale(value / 100)
        end
    end)
    self.trESScaleSlider = esScaleSlider
    yOffset = yOffset - 50

    local lockESCheckbox = CreateSQCheckbox(content, "Lock Earth Shield Reminder", function(checked)
        BH.settings.earthShieldReminderLocked = checked
        BH:SaveSettings()
        if BH.earthShieldReminderFrame then
            BH.earthShieldReminderFrame:SetMovable(not checked)
            BH.earthShieldReminderFrame:EnableMouse(not checked)
        end
    end)
    lockESCheckbox:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    self.trLockESCheckbox = lockESCheckbox
    yOffset = yOffset - 34

    -- === Symbiotic Relationship Reminder (Druid) ===
    local symDivider = CreateSQDivider(content, yOffset)
    symDivider:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    yOffset = yOffset - 18

    local symLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    symLabel:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    symLabel:SetText("SYMBIOTIC RELATIONSHIP REMINDER (DRUID)")
    symLabel:SetTextColor(SQ_COLORS.accent[1], SQ_COLORS.accent[2], SQ_COLORS.accent[3])
    yOffset = yOffset - 22

    local enableSymCheckbox = CreateSQCheckbox(content, "Enable Symbiotic Relationship Reminder", function(checked)
        BH.settings.symbioticReminderEnabled = checked
        BH:SaveSettings()
        BH:UpdateSymbioticReminder()
    end)
    enableSymCheckbox:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    self.trEnableSymCheckbox = enableSymCheckbox
    yOffset = yOffset - 34

    local symScaleSlider = CreateSQSlider(content, "Symbiotic Reminder Scale", 300, 50, 200, 5)
    symScaleSlider:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    symScaleSlider:SetAfterValueChanged(function(value, userInput)
        BH.settings.symbioticReminderScale = value / 100
        BH:SaveSettings()
        if userInput and BH.symbioticReminderFrame then
            BH.symbioticReminderFrame:SetScale(value / 100)
        end
    end)
    self.trSymScaleSlider = symScaleSlider
    yOffset = yOffset - 50

    local lockSymCheckbox = CreateSQCheckbox(content, "Lock Symbiotic Relationship Reminder", function(checked)
        BH.settings.symbioticReminderLocked = checked
        BH:SaveSettings()
        if BH.symbioticReminderFrame then
            BH.symbioticReminderFrame:SetMovable(not checked)
            BH.symbioticReminderFrame:EnableMouse(not checked)
        end
    end)
    lockSymCheckbox:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    self.trLockSymCheckbox = lockSymCheckbox
    yOffset = yOffset - 34

    -- === Repair Reminder ===
    local repairDivider = CreateSQDivider(content, yOffset)
    repairDivider:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    yOffset = yOffset - 18

    local repairLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    repairLabel:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    repairLabel:SetText("REPAIR REMINDER")
    repairLabel:SetTextColor(SQ_COLORS.accent[1], SQ_COLORS.accent[2], SQ_COLORS.accent[3])
    yOffset = yOffset - 22

    local repairCheckbox = CreateSQCheckbox(content, "Enable Repair Reminder", function(checked)
        BH.settings.repairReminderEnabled = checked
        BH:SaveSettings()
        BH:UpdateRepairReminder()
    end)
    repairCheckbox:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    self.trRepairCheckbox = repairCheckbox
    yOffset = yOffset - 34

    local repairThresholdSlider = CreateSQSlider(content, "Durability Threshold (%)", 300, 0, 100, 1)
    repairThresholdSlider:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    repairThresholdSlider:SetAfterValueChanged(function(value)
        BH.settings.repairReminderThreshold = value
        BH:SaveSettings()
        BH:UpdateRepairReminder()
    end)
    self.trRepairThresholdSlider = repairThresholdSlider
    yOffset = yOffset - 50

    local repairScaleSlider = CreateSQSlider(content, "Repair Reminder Scale", 300, 50, 200, 5)
    repairScaleSlider:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    repairScaleSlider:SetAfterValueChanged(function(value, userInput)
        BH.settings.repairReminderScale = value / 100
        BH:SaveSettings()
        if userInput and BH.repairReminderFrame then
            BH.repairReminderFrame:SetScale(value / 100)
        end
    end)
    self.trRepairScaleSlider = repairScaleSlider
    yOffset = yOffset - 50

    local lockRepairCheckbox = CreateSQCheckbox(content, "Lock Repair Reminder", function(checked)
        BH.settings.repairReminderLocked = checked
        BH:SaveSettings()
        if BH.repairReminderFrame then
            BH.repairReminderFrame:SetMovable(not checked)
            BH.repairReminderFrame:EnableMouse(not checked)
        end
    end)
    lockRepairCheckbox:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    self.trLockRepairCheckbox = lockRepairCheckbox
    yOffset = yOffset - 34

    -- === Instance Sound ===
    local instDivider = CreateSQDivider(content, yOffset)
    instDivider:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    yOffset = yOffset - 18

    local instLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    instLabel:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    instLabel:SetText("INSTANCE SOUND ALERTS")
    instLabel:SetTextColor(SQ_COLORS.accent[1], SQ_COLORS.accent[2], SQ_COLORS.accent[3])
    yOffset = yOffset - 22

    local skyreachCheckbox = CreateSQCheckbox(content, "Play Sound on Skyreach (Mythic)", function(checked)
        BH.settings.skyreachSoundEnabled = checked
        BH:SaveSettings()
    end)
    skyreachCheckbox:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    self.trSkyreachSoundCheckbox = skyreachCheckbox
    yOffset = yOffset - 34

    -- === Food/Flask/Oil Bag Reminders ===
    local consumDivider = CreateSQDivider(content, yOffset)
    consumDivider:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    yOffset = yOffset - 18

    local consumLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    consumLabel:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    consumLabel:SetText("CONSUMABLE BAG REMINDERS")
    consumLabel:SetTextColor(SQ_COLORS.accent[1], SQ_COLORS.accent[2], SQ_COLORS.accent[3])
    yOffset = yOffset - 16

    local consumNote = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    consumNote:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    consumNote:SetWidth(380)
    consumNote:SetJustifyH("LEFT")
    consumNote:SetText("Shows a reminder when you have no food/flask/oil in bags while in a dungeon or raid.")
    consumNote:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])
    yOffset = yOffset - 28

    -- Food reminder
    local foodLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    foodLabel:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    foodLabel:SetText("FOOD REMINDER")
    foodLabel:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])
    yOffset = yOffset - 18

    local enableFoodCheckbox = CreateSQCheckbox(content, "Enable Food Reminder", function(checked)
        BH.settings.foodReminderEnabled = checked
        BH:SaveSettings()
        BH:UpdateFoodReminder()
    end)
    enableFoodCheckbox:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    self.trEnableFoodCheckbox = enableFoodCheckbox
    yOffset = yOffset - 34

    local foodScaleSlider = CreateSQSlider(content, "Food Reminder Scale", 300, 50, 200, 5)
    foodScaleSlider:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    foodScaleSlider:SetAfterValueChanged(function(value, userInput)
        BH.settings.foodReminderScale = value / 100
        BH:SaveSettings()
        if userInput and BH.foodReminderFrame then BH.foodReminderFrame:SetScale(value / 100) end
    end)
    self.trFoodScaleSlider = foodScaleSlider
    yOffset = yOffset - 50

    local lockFoodCheckbox = CreateSQCheckbox(content, "Lock Food Reminder", function(checked)
        BH.settings.foodReminderLocked = checked
        BH:SaveSettings()
        if BH.foodReminderFrame then
            BH.foodReminderFrame:SetMovable(not checked)
            BH.foodReminderFrame:EnableMouse(not checked)
        end
    end)
    lockFoodCheckbox:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    self.trLockFoodCheckbox = lockFoodCheckbox
    yOffset = yOffset - 34

    -- Flask reminder
    local flaskRLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    flaskRLabel:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    flaskRLabel:SetText("FLASK REMINDER")
    flaskRLabel:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])
    yOffset = yOffset - 18

    local enableFlaskCheckbox = CreateSQCheckbox(content, "Enable Flask Reminder", function(checked)
        BH.settings.flaskReminderEnabled = checked
        BH:SaveSettings()
        BH:UpdateFlaskReminder()
    end)
    enableFlaskCheckbox:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    self.trEnableFlaskCheckbox = enableFlaskCheckbox
    yOffset = yOffset - 34

    local flaskScaleSlider = CreateSQSlider(content, "Flask Reminder Scale", 300, 50, 200, 5)
    flaskScaleSlider:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    flaskScaleSlider:SetAfterValueChanged(function(value, userInput)
        BH.settings.flaskReminderScale = value / 100
        BH:SaveSettings()
        if userInput and BH.flaskReminderFrame then BH.flaskReminderFrame:SetScale(value / 100) end
    end)
    self.trFlaskScaleSlider = flaskScaleSlider
    yOffset = yOffset - 50

    local lockFlaskCheckbox = CreateSQCheckbox(content, "Lock Flask Reminder", function(checked)
        BH.settings.flaskReminderLocked = checked
        BH:SaveSettings()
        if BH.flaskReminderFrame then
            BH.flaskReminderFrame:SetMovable(not checked)
            BH.flaskReminderFrame:EnableMouse(not checked)
        end
    end)
    lockFlaskCheckbox:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    self.trLockFlaskCheckbox = lockFlaskCheckbox
    yOffset = yOffset - 34

    -- Oil reminder
    local oilRLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    oilRLabel:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    oilRLabel:SetText("WEAPON OIL REMINDER")
    oilRLabel:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])
    yOffset = yOffset - 18

    local enableOilCheckbox = CreateSQCheckbox(content, "Enable Oil Reminder", function(checked)
        BH.settings.oilReminderEnabled = checked
        BH:SaveSettings()
        BH:UpdateOilReminder()
    end)
    enableOilCheckbox:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    self.trEnableOilCheckbox = enableOilCheckbox
    yOffset = yOffset - 34

    local oilScaleSlider = CreateSQSlider(content, "Oil Reminder Scale", 300, 50, 200, 5)
    oilScaleSlider:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    oilScaleSlider:SetAfterValueChanged(function(value, userInput)
        BH.settings.oilReminderScale = value / 100
        BH:SaveSettings()
        if userInput and BH.oilReminderFrame then BH.oilReminderFrame:SetScale(value / 100) end
    end)
    self.trOilScaleSlider = oilScaleSlider
    yOffset = yOffset - 50

    local lockOilCheckbox = CreateSQCheckbox(content, "Lock Oil Reminder", function(checked)
        BH.settings.oilReminderLocked = checked
        BH:SaveSettings()
        if BH.oilReminderFrame then
            BH.oilReminderFrame:SetMovable(not checked)
            BH.oilReminderFrame:EnableMouse(not checked)
        end
    end)
    lockOilCheckbox:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    self.trLockOilCheckbox = lockOilCheckbox
    yOffset = yOffset - 34

    -- === Feast Announce ===
    local feastDivider = CreateSQDivider(content, yOffset)
    feastDivider:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    yOffset = yOffset - 18

    local feastLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    feastLabel:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    feastLabel:SetText("FEAST ANNOUNCE")
    feastLabel:SetTextColor(SQ_COLORS.accent[1], SQ_COLORS.accent[2], SQ_COLORS.accent[3])
    yOffset = yOffset - 16

    local feastNote = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    feastNote:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    feastNote:SetWidth(380)
    feastNote:SetJustifyH("LEFT")
    feastNote:SetText("Announces in group chat when you or anyone in the party places a feast. Custom message applies to your own feasts; party feasts use the caster's name.")
    feastNote:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])
    yOffset = yOffset - 28

    local feastCheckbox = CreateSQCheckbox(content, "Enable Feast Announce", function(checked)
        BH.settings.feastAnnounceEnabled = checked
        BH:SaveSettings()
    end)
    feastCheckbox:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    self.trFeastAnnounceCheckbox = feastCheckbox
    yOffset = yOffset - 30

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
    end
    yOffset = yOffset - 30

    local feastTextLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    feastTextLabel:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    feastTextLabel:SetText("Your feast message (leave blank for default):")
    feastTextLabel:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])
    yOffset = yOffset - 20

    local feastTextEdit = CreateFrame("EditBox", nil, content, "InputBoxTemplate")
    feastTextEdit:SetSize(360, 20)
    feastTextEdit:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    feastTextEdit:SetAutoFocus(false)
    feastTextEdit:SetMaxLetters(255)
    feastTextEdit:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    feastTextEdit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    feastTextEdit.placeholder = feastTextEdit:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    feastTextEdit.placeholder:SetPoint("LEFT", feastTextEdit, "LEFT", 4, 0)
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
    local feastSoundLbl = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    feastSoundLbl:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    feastSoundLbl:SetText("Alert sound (plays when a feast is placed):")  -- sound on SQ_FEAST message or CLEU
    feastSoundLbl:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])
    yOffset = yOffset - 22

    local feastSoundDD = CreateSQDropdown(content, "", 220, BuildSoundDropdownItems(), function(value)
        BH.settings.feastAlertSound = value
        BH:SaveSettings()
    end)
    feastSoundDD:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    local curFeastSnd = BH.settings and BH.settings.feastAlertSound or "None"
    feastSoundDD:SetSelectedValue(curFeastSnd)
    self.trFeastAlertSoundDD = feastSoundDD

    local feastSoundPreviewBtn = CreateFrame("Button", nil, content)
    feastSoundPreviewBtn:SetSize(22, 22)
    feastSoundPreviewBtn:SetPoint("LEFT", feastSoundDD, "RIGHT", 6, 0)
    local fspNormal = feastSoundPreviewBtn:CreateTexture(nil, "BACKGROUND")
    fspNormal:SetAllPoints()
    fspNormal:SetTexture("Interface\\Common\\VoiceChat-Speaker")
    local fspHighlight = feastSoundPreviewBtn:CreateTexture(nil, "HIGHLIGHT")
    fspHighlight:SetAllPoints()
    fspHighlight:SetTexture("Interface\\Common\\VoiceChat-Speaker")
    fspHighlight:SetAlpha(0.6)
    feastSoundPreviewBtn:SetScript("OnEnter", function() fspNormal:SetAlpha(0.7) end)
    feastSoundPreviewBtn:SetScript("OnLeave", function() fspNormal:SetAlpha(1.0) end)
    feastSoundPreviewBtn:SetScript("OnClick", function()
        PlaySQSound(BH.settings and BH.settings.feastAlertSound or "None")
    end)
    yOffset = yOffset - 34

    -- === Healer CC Alert ===
    local healerCCDivider = CreateSQDivider(content, yOffset)
    healerCCDivider:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    yOffset = yOffset - 18

    local healerCCTitle = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    healerCCTitle:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    healerCCTitle:SetText("HEALER CC ALERT")
    healerCCTitle:SetTextColor(SQ_COLORS.accent[1], SQ_COLORS.accent[2], SQ_COLORS.accent[3])
    yOffset = yOffset - 18

    local healerCCNote = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    healerCCNote:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    healerCCNote:SetWidth(380)
    healerCCNote:SetJustifyH("LEFT")
    healerCCNote:SetWordWrap(true)
    healerCCNote:SetText("Plays a sound when a party or raid healer is crowd controlled.")
    healerCCNote:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])
    yOffset = yOffset - 28

    local healerCCCheckbox = CreateSQCheckbox(content, "Alert when healer is CC'd", function(checked)
        BH.settings.healerCCAlertEnabled = (checked == true)
        BH:SaveSettings()
    end)
    healerCCCheckbox:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    self.trHealerCCCheckbox = healerCCCheckbox
    yOffset = yOffset - 30

    local healerCCLockCheckbox = CreateSQCheckbox(content, "Lock Position", function(checked)
        BH.settings.healerCCReminderLocked = (checked == true)
        BH:SaveSettings()
        if BH.healerCCReminderFrame then
            BH.healerCCReminderFrame:SetMovable(not checked)
            BH.healerCCReminderFrame:EnableMouse(not checked)
        end
    end)
    healerCCLockCheckbox:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    self.trHealerCCLockCheckbox = healerCCLockCheckbox
    yOffset = yOffset - 30

    local healerCCScaleSlider = CreateSQSlider(content, "Scale", 200, 50, 200, 5)
    healerCCScaleSlider:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    healerCCScaleSlider:SetAfterValueChanged(function(val)
        BH.settings.healerCCReminderScale = val / 100
        BH:SaveSettings()
        if BH.healerCCReminderFrame then BH.healerCCReminderFrame:SetScale(val / 100) end
    end)
    self.trHealerCCScaleSlider = healerCCScaleSlider
    yOffset = yOffset - 50

    local healerCCSndLbl = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    healerCCSndLbl:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    healerCCSndLbl:SetText("Alert sound:")
    healerCCSndLbl:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])
    yOffset = yOffset - 22

    local healerCCSoundDD = CreateSQDropdown(content, "", 220, BuildSoundDropdownItems(), function(value)
        BH.settings.healerCCAlertSound = value
        BH:SaveSettings()
    end)
    healerCCSoundDD:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    healerCCSoundDD:SetSelectedValue(BH.settings and BH.settings.healerCCAlertSound or "None")
    self.trHealerCCSoundDD = healerCCSoundDD

    local hccPreviewBtn = CreateFrame("Button", nil, content)
    hccPreviewBtn:SetSize(22, 22)
    hccPreviewBtn:SetPoint("LEFT", healerCCSoundDD, "RIGHT", 6, 0)
    local hccNorm = hccPreviewBtn:CreateTexture(nil, "BACKGROUND")
    hccNorm:SetAllPoints()
    hccNorm:SetTexture("Interface\\Common\\VoiceChat-Speaker")
    local hccHi = hccPreviewBtn:CreateTexture(nil, "HIGHLIGHT")
    hccHi:SetAllPoints()
    hccHi:SetTexture("Interface\\Common\\VoiceChat-Speaker")
    hccHi:SetAlpha(0.6)
    hccPreviewBtn:SetScript("OnEnter", function() hccNorm:SetAlpha(0.7) end)
    hccPreviewBtn:SetScript("OnLeave", function() hccNorm:SetAlpha(1.0) end)
    hccPreviewBtn:SetScript("OnClick", function()
        PlaySQSound(BH.settings and BH.settings.healerCCAlertSound or "None")
    end)
    yOffset = yOffset - 34

    content:SetHeight(math.abs(yOffset) + 20)
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
    bundledTitle:SetTextColor(SQ_COLORS.accent[1], SQ_COLORS.accent[2], SQ_COLORS.accent[3])
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

        local previewBtn = CreateFrame("Button", nil, rowFrame)
        previewBtn:SetSize(22, 22)
        previewBtn:SetPoint("LEFT", rowFrame, "LEFT", 286, 0)
        local pNorm = previewBtn:CreateTexture(nil, "BACKGROUND")
        pNorm:SetAllPoints()
        pNorm:SetTexture("Interface\\Common\\VoiceChat-Speaker")
        local pHi = previewBtn:CreateTexture(nil, "HIGHLIGHT")
        pHi:SetAllPoints()
        pHi:SetTexture("Interface\\Common\\VoiceChat-Speaker")
        pHi:SetAlpha(0.6)
        previewBtn:SetScript("OnEnter", function() pNorm:SetAlpha(0.7) end)
        previewBtn:SetScript("OnLeave", function() pNorm:SetAlpha(1.0) end)
        local soundFile = entry.file
        previewBtn:SetScript("OnClick", function()
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
    csTitle:SetTextColor(SQ_COLORS.accent[1], SQ_COLORS.accent[2], SQ_COLORS.accent[3])
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
    local csNameEdit = CreateFrame("EditBox", nil, content, "InputBoxTemplate")
    csNameEdit:SetSize(150, 20)
    csNameEdit:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    csNameEdit:SetAutoFocus(false)
    csNameEdit:SetMaxLetters(64)
    csNameEdit:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    csNameEdit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    csNameEdit.placeholder = csNameEdit:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    csNameEdit.placeholder:SetPoint("LEFT", csNameEdit, "LEFT", 4, 0)
    csNameEdit.placeholder:SetText("e.g. My Alert")
    csNameEdit.placeholder:SetTextColor(0.4, 0.4, 0.4)
    csNameEdit:SetScript("OnTextChanged", function(self)
        csNameEdit.placeholder:SetShown(self:GetText() == "")
    end)
    csNameEdit:SetScript("OnShow", function(self)
        csNameEdit.placeholder:SetShown(self:GetText() == "")
    end)

    local csFileEdit = CreateFrame("EditBox", nil, content, "InputBoxTemplate")
    csFileEdit:SetSize(160, 20)
    csFileEdit:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad + 158, yOffset)
    csFileEdit:SetAutoFocus(false)
    csFileEdit:SetMaxLetters(128)
    csFileEdit:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    csFileEdit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    csFileEdit.placeholder = csFileEdit:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    csFileEdit.placeholder:SetPoint("LEFT", csFileEdit, "LEFT", 4, 0)
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
                -- Weapon imbues (e.g. Holy Paladin Rites from Lightsmith hero talents)
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
                        AddSpellRow(buffInfo.spellID, buffInfo.selfBuff or buffInfo.tankBuff or buffInfo.weaponImbue, CLASS_NAMES[playerClass] or playerClass)
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
          fs:SetTextColor(SQ_COLORS.accent[1], SQ_COLORS.accent[2], SQ_COLORS.accent[3])
          return fs
      end)
      petHdr:Show()
      petHdr:SetPoint("TOPLEFT", sc, "TOPLEFT", 0, yOffset)
      yOffset = yOffset - 22

      local petRow, petRowIsNew = self:AcquireWidget("classBuffRowCache", "petRow", function()
          local f = CreateFrame("Frame", nil, sc)
          f:SetSize(380, 80)
          return f
      end)
      petRow:Show()
      petRow:SetPoint("TOPLEFT", sc, "TOPLEFT", 0, yOffset)
      self.petReminderRow = petRow

      if not petRowIsNew then
          -- Re-sync only; a profile switch rewrites both settings.
          if self.trPetEnableCheckbox then
              self.trPetEnableCheckbox:SetChecked(BH.settings and BH.settings.petReminderEnabled ~= false)
          end
          if self.trPetScaleSlider then
              self.trPetScaleSlider:SetValue((BH.settings and BH.settings.petReminderScale or 1.0) * 100)
          end
          if self.trPetLockCheckbox then
              self.trPetLockCheckbox:SetChecked(BH.settings and BH.settings.petReminderLocked or false)
          end
          yOffset = yOffset - 84
          sc:SetHeight(math.abs(yOffset) + 20)
          return
      end

        local petEnableCb = CreateSQCheckbox(petRow, "Show \"NO PET\" text when pet is missing", function(val)
            BH.settings.petReminderEnabled = val
            BH:SaveSettings()
            BH:UpdatePetReminder()
        end)
        petEnableCb:SetPoint("TOPLEFT", petRow, "TOPLEFT", 0, 0)
        petEnableCb:SetChecked(BH.settings and BH.settings.petReminderEnabled ~= false)
        self.trPetEnableCheckbox = petEnableCb

        local petScaleSlider = CreateSQSlider(petRow, "Scale", 200, 50, 300, 5)
        petScaleSlider:SetAfterValueChanged(function(value, userInput)
            if not userInput then return end
            BH.settings.petReminderScale = value / 100
            if BH.petReminderFrame then BH.petReminderFrame:SetScale(value / 100) end
            BH:SaveSettings()
        end)
        petScaleSlider:SetValue((BH.settings and BH.settings.petReminderScale or 1.0) * 100)
        petScaleSlider:SetPoint("TOPLEFT", petRow, "TOPLEFT", 0, -28)
        self.trPetScaleSlider = petScaleSlider

        local petLockCb = CreateSQCheckbox(petRow, "Lock position", function(val)
            BH.settings.petReminderLocked = val
            if BH.petReminderFrame then BH.petReminderFrame:EnableMouse(not val) end
            BH:SaveSettings()
        end)
        petLockCb:SetPoint("TOPLEFT", petRow, "TOPLEFT", 0, -60)
        petLockCb:SetChecked(BH.settings and BH.settings.petReminderLocked or false)
        self.trPetLockCheckbox = petLockCb

        yOffset = yOffset - 84
        sc:SetHeight(math.abs(yOffset) + 20)
    end
end

function BH:RefreshTextRemindersTab()
    if not self.settings then return end
    if self.trBeaconScaleSlider then
        self.trBeaconScaleSlider:SetValue((self.settings.beaconReminderScale or 1.0) * 100)
    end
    if self.trEnableBeaconCheckbox then
        self.trEnableBeaconCheckbox:SetChecked(self.settings.beaconReminderEnabled ~= false)
    end
    if self.trLockBeaconCheckbox then
        self.trLockBeaconCheckbox:SetChecked(self.settings.beaconReminderLocked or false)
    end
    if self.trESScaleSlider then
        self.trESScaleSlider:SetValue((self.settings.earthShieldReminderScale or 1.0) * 100)
    end
    if self.trEnableESCheckbox then
        self.trEnableESCheckbox:SetChecked(self.settings.earthShieldReminderEnabled ~= false)
    end
    if self.trLockESCheckbox then
        self.trLockESCheckbox:SetChecked(self.settings.earthShieldReminderLocked or false)
    end
    if self.trSkyreachSoundCheckbox then
        self.trSkyreachSoundCheckbox:SetChecked(self.settings.skyreachSoundEnabled ~= false)
    end
    if self.trRepairCheckbox then
        self.trRepairCheckbox:SetChecked(self.settings.repairReminderEnabled ~= false)
    end
    if self.trRepairThresholdSlider then
        self.trRepairThresholdSlider:SetValue(self.settings.repairReminderThreshold or 20)
    end
    if self.trRepairScaleSlider then
        self.trRepairScaleSlider:SetValue((self.settings.repairReminderScale or 1.0) * 100)
    end
    if self.trLockRepairCheckbox then
        self.trLockRepairCheckbox:SetChecked(self.settings.repairReminderLocked or false)
    end
    if self.trEnableSymCheckbox then
        self.trEnableSymCheckbox:SetChecked(self.settings.symbioticReminderEnabled ~= false)
    end
    if self.trSymScaleSlider then
        self.trSymScaleSlider:SetValue((self.settings.symbioticReminderScale or 1.0) * 100)
    end
    if self.trLockSymCheckbox then
        self.trLockSymCheckbox:SetChecked(self.settings.symbioticReminderLocked or false)
    end
    if self.trEnableFoodCheckbox then
        self.trEnableFoodCheckbox:SetChecked(self.settings.foodReminderEnabled ~= false)
    end
    if self.trFoodScaleSlider then
        self.trFoodScaleSlider:SetValue((self.settings.foodReminderScale or 1.0) * 100)
    end
    if self.trLockFoodCheckbox then
        self.trLockFoodCheckbox:SetChecked(self.settings.foodReminderLocked or false)
    end
    if self.trEnableFlaskCheckbox then
        self.trEnableFlaskCheckbox:SetChecked(self.settings.flaskReminderEnabled ~= false)
    end
    if self.trFlaskScaleSlider then
        self.trFlaskScaleSlider:SetValue((self.settings.flaskReminderScale or 1.0) * 100)
    end
    if self.trLockFlaskCheckbox then
        self.trLockFlaskCheckbox:SetChecked(self.settings.flaskReminderLocked or false)
    end
    if self.trEnableOilCheckbox then
        self.trEnableOilCheckbox:SetChecked(self.settings.oilReminderEnabled ~= false)
    end
    if self.trOilScaleSlider then
        self.trOilScaleSlider:SetValue((self.settings.oilReminderScale or 1.0) * 100)
    end
    if self.trLockOilCheckbox then
        self.trLockOilCheckbox:SetChecked(self.settings.oilReminderLocked or false)
    end
    if self.trFeastAnnounceCheckbox then
        self.trFeastAnnounceCheckbox:SetChecked(self.settings.feastAnnounceEnabled ~= false)
    end
    if self.trFeastAnnounceTextEdit then
        local txt = (self.settings.feastAnnounceText or "")
        self.trFeastAnnounceTextEdit:SetText(txt)
        self.trFeastAnnounceTextEdit.placeholder:SetShown(txt == "")
    end
    if self.trFeastAlertSoundDD then
        self.trFeastAlertSoundDD:SetSelectedValue(self.settings.feastAlertSound or "None")
    end
    if self.trFeastChannelDDs then
        local chanDB = type(self.settings.feastAnnounceChannel) == "table"
            and self.settings.feastAnnounceChannel
            or BH.defaultSettings.feastAnnounceChannel
        for key, dd in pairs(self.trFeastChannelDDs) do
            dd:SetSelectedValue(chanDB[key] or "NONE")
        end
    end
    if self.trHealerCCCheckbox then
        self.trHealerCCCheckbox:SetChecked(self.settings.healerCCAlertEnabled == true)
    end
    if self.trHealerCCLockCheckbox then
        self.trHealerCCLockCheckbox:SetChecked(self.settings.healerCCReminderLocked == true)
    end
    if self.trHealerCCScaleSlider then
        self.trHealerCCScaleSlider:SetValue((self.settings.healerCCReminderScale or 1.0) * 100)
    end
    if self.trHealerCCSoundDD then
        self.trHealerCCSoundDD:SetSelectedValue(self.settings.healerCCAlertSound or "None")
    end
end

-- ============================================================
-- DUNGEON CALLOUTS — in-game button frame + config tab
-- ============================================================

local CALLOUT_CHANNEL_MAP = {
    INSTANCE     = "/instance",
    PARTY        = "/party",
    SAY          = "/say",
    YELL         = "/yell",
    RAID         = "/raid",
    RAID_WARNING = "/rw",
}
local CALLOUT_CHANNEL_ITEMS = {
    { text = "Instance",     value = "INSTANCE"     },
    { text = "Party",        value = "PARTY"        },
    { text = "Say",          value = "SAY"          },
    { text = "Yell",         value = "YELL"         },
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
    local callouts = self.settings and self.settings.dungeonCallouts
    if not callouts then f:Hide(); return end
    local _, _, _, _, _, _, _, instanceID = GetInstanceInfo()
    local matchedGroup = nil
    for _, group in ipairs(callouts) do
        if group.instanceID == instanceID then matchedGroup = group; break end
    end
    if not matchedGroup or not matchedGroup.buttons or #matchedGroup.buttons == 0 then
        f:Hide(); return
    end
    local BTN_H, BTN_W, GAP, TITLE_H = 24, 144, 2, 14
    local yOfs = -(TITLE_H + GAP)
    for _, callout in ipairs(matchedGroup.buttons) do
        -- SecureActionButtonTemplate handles the macro (chat message).
        -- HookScript("OnClick") appends an insecure hook that runs AFTER the
        -- secure handler completes — this is the documented safe pattern.
        -- (SetScript replaces the handler and taints; HookScript appends.)
        local btn = CreateFrame("Button", nil, f, "SecureActionButtonTemplate")
        btn:SetSize(BTN_W - 4, BTN_H)
        btn:SetPoint("TOPLEFT", f, "TOPLEFT", 2, yOfs)
        btn:RegisterForClicks("AnyDown", "AnyUp")
        local bg = btn:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(SQ_COLORS.control[1], SQ_COLORS.control[2], SQ_COLORS.control[3], 1)
        btn:SetHighlightTexture("Interface\\BUTTONS\\WHITE8X8")
        btn:GetHighlightTexture():SetVertexColor(SQ_COLORS.controlHi[1], SQ_COLORS.controlHi[2], SQ_COLORS.controlHi[3], 0.4)
        local slash = CALLOUT_CHANNEL_MAP[callout.channel] or "/instance"
        btn:SetAttribute("type", "macro")
        btn:SetAttribute("macrotext", slash .. " " .. (callout.message or ""))
        local lbl = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        lbl:SetAllPoints()
        lbl:SetText(callout.label or "Callout")
        lbl:SetTextColor(SQ_COLORS.accent[1], SQ_COLORS.accent[2], SQ_COLORS.accent[3])
        local sndName = callout.sound or "None"
        local calloutChannel = callout.channel or "INSTANCE"
        btn:HookScript("OnClick", function(_, _, down)
            if down then return end  -- only fire on button-up (macro fires on down)
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
    hdr:SetTextColor(SQ_COLORS.accent[1], SQ_COLORS.accent[2], SQ_COLORS.accent[3])
    yOffset = yOffset - 16

    local note = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    note:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    note:SetWidth(372)
    note:SetJustifyH("LEFT")
    note:SetText("Buttons appear automatically when you enter the matching dungeon. Clicking sends the message and plays the sound. Works in combat and M+.")
    note:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])
    yOffset = yOffset - 36

    local addBtn = CreateSQButton(content, "+ Add Current Dungeon", 190, 24)
    addBtn:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    addBtn:SetScript("OnClick", function()
        local dName, _, _, _, _, _, _, iID = GetInstanceInfo()
        if not iID or iID == 0 then return end
        BH.settings.dungeonCallouts = BH.settings.dungeonCallouts or {}
        for _, g in ipairs(BH.settings.dungeonCallouts) do
            if g.instanceID == iID then return end
        end
        table.insert(BH.settings.dungeonCallouts, { instanceID = iID, name = dName, buttons = {} })
        BH:SaveSettings()
        BH:RefreshCalloutsTab()
    end)
    addBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        local dName, _, _, _, _, _, _, iID = GetInstanceInfo()
        if iID and iID ~= 0 then
            GameTooltip:SetText("Current: " .. (dName or "?") .. " (ID: " .. tostring(iID) .. ")")
        else
            GameTooltip:SetText("Must be inside a dungeon or raid to add it.")
        end
        GameTooltip:Show()
    end)
    addBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
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
    local callouts = self.settings and self.settings.dungeonCallouts or {}

    for gIdx, group in ipairs(callouts) do
        local groupFrame = CreateFrame("Frame", nil, listFrame)
        groupFrame:SetPoint("TOPLEFT", listFrame, "TOPLEFT", 0, yOffset)
        groupFrame:SetWidth(400)
        local gy = 0

        -- Divider
        local div = CreateSQDivider(groupFrame, gy)
        div:SetPoint("TOPLEFT", groupFrame, "TOPLEFT", leftPad, gy)
        gy = gy - 18

        -- Group header + delete button
        local gLabel = groupFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        gLabel:SetPoint("TOPLEFT", groupFrame, "TOPLEFT", leftPad, gy)
        gLabel:SetText((group.name or "Unknown") .. "  |cff888888(ID: " .. tostring(group.instanceID or "?") .. ")|r")
        gLabel:SetTextColor(SQ_COLORS.textBright[1], SQ_COLORS.textBright[2], SQ_COLORS.textBright[3])

        local delGrpBtn = CreateSQButton(groupFrame, "Delete", 70, 20, SQ_COLORS.danger)
        delGrpBtn:SetPoint("TOPLEFT", groupFrame, "TOPLEFT", leftPad + W - 70, gy)
        local capturedGIdx = gIdx
        delGrpBtn:SetScript("OnClick", function()
            table.remove(BH.settings.dungeonCallouts, capturedGIdx)
            BH:SaveSettings()
            BH:UpdateCalloutsButtonFrame()
            BH:RefreshCalloutsTab()
        end)
        gy = gy - 26

        -- Per-callout rows
        for bIdx, callout in ipairs(group.buttons) do
            local rowFrame = CreateFrame("Frame", nil, groupFrame)
            rowFrame:SetPoint("TOPLEFT", groupFrame, "TOPLEFT", leftPad, gy)
            rowFrame:SetSize(W, 56)

            -- Row 1: [Label 86px] [Message 256px] [× 22px]
            local labelEdit = CreateFrame("EditBox", nil, rowFrame, "InputBoxTemplate")
            labelEdit:SetSize(86, 20)
            labelEdit:SetPoint("TOPLEFT", rowFrame, "TOPLEFT", 0, 0)
            labelEdit:SetAutoFocus(false)
            labelEdit:SetMaxLetters(32)
            labelEdit:SetText(callout.label or "")
            local labelPH = labelEdit:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            labelPH:SetPoint("LEFT", labelEdit, "LEFT", 4, 0)
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

            local msgEdit = CreateFrame("EditBox", nil, rowFrame, "InputBoxTemplate")
            msgEdit:SetSize(256, 20)
            msgEdit:SetPoint("TOPLEFT", rowFrame, "TOPLEFT", 92, 0)
            msgEdit:SetAutoFocus(false)
            msgEdit:SetMaxLetters(200)
            msgEdit:SetText(callout.message or "")
            local msgPH = msgEdit:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            msgPH:SetPoint("LEFT", msgEdit, "LEFT", 4, 0)
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
            local cg, cb = gIdx, bIdx
            delBtn:SetScript("OnClick", function()
                table.remove(BH.settings.dungeonCallouts[cg].buttons, cb)
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

        -- "Add Callout" button
        local addCBtn = CreateSQButton(groupFrame, "+ Add Callout", 120, 22)
        addCBtn:SetPoint("TOPLEFT", groupFrame, "TOPLEFT", leftPad, gy)
        local cgIdx = gIdx
        addCBtn:SetScript("OnClick", function()
            table.insert(BH.settings.dungeonCallouts[cgIdx].buttons, {
                label = "Callout", message = "", channel = "INSTANCE", sound = "None",
            })
            BH:SaveSettings(); BH:RefreshCalloutsTab()
        end)
        gy = gy - 30

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
    for bag = FIRST_BAG, LAST_BAG do
        for slot = 1, C_Container.GetContainerNumSlots(bag) do
            local bagItemID = C_Container.GetContainerItemID(bag, slot)
            if bagItemID == itemID then
                local itemLink = C_Container.GetContainerItemLink(bag, slot)
                local containerInfo = C_Container.GetContainerItemInfo(bag, slot)
                local craftingQuality = containerInfo and containerInfo.craftingQuality
                return itemLink, craftingQuality
            end
        end
    end
    return nil, nil
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
    check:SetColorTexture(SQ_COLORS.accent[1], SQ_COLORS.accent[2], SQ_COLORS.accent[3], 0.9)
    checkbox:SetCheckedTexture(check)

    checkbox:SetChecked(self:IsEnabled(itemID))
    checkbox:SetScript("OnClick", function(self)
        BH.disabled[itemID] = not self:GetChecked()
        BH:SaveSettings()
        BH:UpdateButtons()
    end)
    checkbox:SetScript("OnEnter", function()
        boxBorder:SetBackdropBorderColor(SQ_COLORS.accent[1], SQ_COLORS.accent[2], SQ_COLORS.accent[3], 0.6)
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
    
    local minEdit = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
    minEdit:SetPoint("LEFT", minLabel, "RIGHT", 2, 0)
    minEdit:SetSize(30, 18)
    minEdit:SetAutoFocus(false)
    minEdit:SetNumeric(true)
    minEdit:SetMaxLetters(2)
    minEdit:SetText(tostring(self:GetMinDuration(itemID)))
    minEdit:SetScript("OnEnterPressed", function(self)
        local value = tonumber(self:GetText()) or 0
        value = math.max(0, math.min(60, value))
        self:SetText(tostring(value))
        BH:SetMinDuration(itemID, value)
        BH:SaveSettings()
        BH:UpdateButtons()
        self:ClearFocus()
    end)
    minEdit:SetScript("OnEscapePressed", function(self)
        self:SetText(tostring(BH:GetMinDuration(itemID)))
        self:ClearFocus()
    end)
    minEdit:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Min minutes remaining")
        GameTooltip:AddLine("Show button when buff has less than this many minutes left.", 1, 1, 1, true)
        GameTooltip:AddLine("0 = only show when buff is missing", 0.7, 0.7, 0.7, true)
        GameTooltip:Show()
    end)
    minEdit:SetScript("OnLeave", function() GameTooltip:Hide() end)
    
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
            
            -- Try GetItemInfo to trigger cache request (returns nil if not cached)
            local name, _, _, _, _, _, _, _, _, itemTexture = GetItemInfo(itemID)
            if name then
                nameText:SetText(WithStatLabel(name))
                if itemTexture then
                    icon:SetTexture(itemTexture)
                end
            else
                -- Request item data and use callback
                local item = Item:CreateFromItemID(itemID)
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
        cbCheck:SetColorTexture(SQ_COLORS.accent[1], SQ_COLORS.accent[2], SQ_COLORS.accent[3], 0.9)
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

        local coachMinEdit = CreateFrame("EditBox", nil, coachMinRow, "InputBoxTemplate")
        coachMinEdit:SetPoint("LEFT", coachMinLbl, "RIGHT", 4, 0)
        coachMinEdit:SetSize(30, 18)
        coachMinEdit:SetAutoFocus(false)
        coachMinEdit:SetNumeric(true)
        coachMinEdit:SetMaxLetters(2)
        coachMinEdit:SetText(tostring(BH:GetMinDuration(COACH_WHISTLE_ITEM_ID)))
        coachMinEdit:SetScript("OnEnterPressed", function(self)
            local v = math.max(0, math.min(60, tonumber(self:GetText()) or 0))
            self:SetText(tostring(v))
            BH:SetMinDuration(COACH_WHISTLE_ITEM_ID, v)
            BH:SaveSettings()
            BH:UpdateButtons()
            self:ClearFocus()
        end)
        coachMinEdit:SetScript("OnEscapePressed", function(self)
            self:SetText(tostring(BH:GetMinDuration(COACH_WHISTLE_ITEM_ID)))
            self:ClearFocus()
        end)
        coachMinEdit:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText("Min minutes remaining")
            GameTooltip:AddLine("Re-show the button when the Coached buff has less than this many minutes left.", 1, 1, 1, true)
            GameTooltip:AddLine("0 = only show when no ally is coached yet", 0.7, 0.7, 0.7, true)
            GameTooltip:Show()
        end)
        coachMinEdit:SetScript("OnLeave", function() GameTooltip:Hide() end)
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
        clCheck:SetColorTexture(SQ_COLORS.accent[1], SQ_COLORS.accent[2], SQ_COLORS.accent[3], 0.9)
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
    local total = 0
    for bag = FIRST_BAG, LAST_BAG do
        for slot = 1, C_Container.GetContainerNumSlots(bag) do
            if C_Container.GetContainerItemID(bag, slot) == itemID then
                local info = C_Container.GetContainerItemInfo(bag, slot)
                total = total + (info and info.stackCount or 1)
            end
        end
    end
    return total
end

-- create main frame
BH.frame = CreateFrame("Frame", "SQUIZZUMABLESFrame", UIParent)
BH.frame:SetSize(50, 50)
BH.frame:SetPoint("CENTER")
BH.frame:SetMovable(true)

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

-- create drag handle bar on top of the frame
BH.dragHandle = CreateFrame("Frame", "SQUIZZUMABLESDragHandle", BH.frame, "BackdropTemplate")
BH.dragHandle:SetSize(20, 12)
BH.dragHandle:SetPoint("BOTTOMLEFT", BH.frame, "TOPLEFT", 0, 2)
BH.dragHandle:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Buttons\\WHITE8x8",
    edgeSize = 1,
})
BH.dragHandle:SetBackdropColor(0.7, 0.7, 0.7, 0.4)
BH.dragHandle:SetBackdropBorderColor(0.8, 0.8, 0.8, 1.0)
BH.dragHandle:EnableMouse(true)
BH.dragHandle:RegisterForDrag("LeftButton")
BH.dragHandle:SetScript("OnDragStart", function()
    BH.frame:StartMoving()
end)
BH.dragHandle:SetScript("OnDragStop", function()
    BH.frame:StopMovingOrSizing()
    BH:SaveFramePosition()
end)

-- Update drag handle position based on grow direction
function BH:UpdateDragHandlePosition()
    local grow = (self.settings and self.settings.growDirection) or "RIGHT"
    local layout = (self.settings and self.settings.layoutDirection) or "HORIZONTAL"
    self.dragHandle:ClearAllPoints()
    self.dragHandle:SetSize(20, 12)
    if grow == "UP" then
        self.dragHandle:SetPoint("TOPLEFT", self.frame, "BOTTOMLEFT", 0, -2)
    elseif grow == "LEFT" then
        self.dragHandle:SetPoint("BOTTOMRIGHT", self.frame, "TOPRIGHT", 0, 2)
    elseif grow == "OUTWARD" then
        self.dragHandle:SetPoint("BOTTOM", self.frame, "TOP", 0, 2)
    else -- DOWN, RIGHT
        self.dragHandle:SetPoint("BOTTOMLEFT", self.frame, "TOPLEFT", 0, 2)
    end
end

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
    btn.timer:SetText("")
    btn.timerElapsed = 0
    if btn.expirationTime and btn.expirationTime > 0 then
        btn:SetScript("OnUpdate", function(self, elapsed)
            -- The readout is whole seconds; refreshing it every frame is wasted
            -- work. Accumulate and update ~10x/sec instead.
            self.timerElapsed = self.timerElapsed + elapsed
            if self.timerElapsed < 0.1 then return end
            self.timerElapsed = 0

            local expiration = self.expirationTime
            if not expiration or expiration == 0 then
                self.timer:SetText("")
                return
            end
            local remaining = expiration - GetTime()
            if remaining <= 0 then
                self.timer:SetText("")
                self.expirationTime = nil
            elseif remaining < 60 then
                self.timer:SetText(string.format("%d", math.floor(remaining)))
            else
                local mins = math.floor(remaining / 60)
                local secs = math.floor(remaining % 60)
                self.timer:SetText(string.format("%d:%02d", mins, secs))
            end
        end)
    else
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

    btn:RegisterForClicks("AnyDown", "AnyUp")
    btn:SetFrameStrata("MEDIUM")  -- Below the options panel (DIALOG)
    btn:Enable()
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
                if auraData and auraData.sourceUnit and UnitIsUnit(auraData.sourceUnit, "player") then
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
    _consumableBuffCache = { food = {}, flask = {} }
    _consumableBuffNames = { food = {}, flask = {} }
    for _, category in ipairs({ "food", "flask" }) do
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

-- build button list
-- M+ active state
BH.challengeModeActive = false
BH.previewMode = false

-- Beacon reminder frame (movable frame for Holy Paladins)
BH.beaconReminderFrame = CreateFrame("Frame", "SQUIZZUMABLESBeaconReminder", UIParent)
BH.beaconReminderFrame:SetSize(280, 50)
BH.beaconReminderFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 200)
BH.beaconReminderFrame:SetFrameStrata("HIGH")
BH.beaconReminderFrame:SetMovable(true)
BH.beaconReminderFrame:SetClampedToScreen(true)
BH.beaconReminderFrame:EnableMouse(true)
BH.beaconReminderFrame:RegisterForDrag("LeftButton")
BH.beaconReminderFrame:SetScript("OnDragStart", function()
    if not (BH.settings and BH.settings.beaconReminderLocked) or BH.previewMode then
        BH.beaconReminderFrame:StartMoving()
        BH.beaconReminderFrame:SetUserPlaced(false)
    end
end)
BH.beaconReminderFrame:SetScript("OnDragStop", function()
    BH.beaconReminderFrame:StopMovingOrSizing()
    BH:SaveBeaconReminderPosition()
end)
BH.beaconReminderFrame:Hide()

BH.beaconReminderText = BH.beaconReminderFrame:CreateFontString(nil, "OVERLAY")
BH.beaconReminderText:SetFont("Fonts\\FRIZQT__.TTF", 24, "OUTLINE")
BH.beaconReminderText:SetPoint("CENTER", BH.beaconReminderFrame, "CENTER", 0, 0)
BH.beaconReminderText:SetText("REMEMBER YOUR BEACON")
BH.beaconReminderText:SetTextColor(1, 0.82, 0, 1)  -- Gold

-- Earth Shield reminder frame (movable frame for Restoration Shamans)
BH.earthShieldReminderFrame = CreateFrame("Frame", "SQUIZZUMABLESEarthShieldReminder", UIParent)
BH.earthShieldReminderFrame:SetSize(320, 50)
BH.earthShieldReminderFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 160)
BH.earthShieldReminderFrame:SetFrameStrata("HIGH")
BH.earthShieldReminderFrame:SetMovable(true)
BH.earthShieldReminderFrame:SetClampedToScreen(true)
BH.earthShieldReminderFrame:EnableMouse(true)
BH.earthShieldReminderFrame:RegisterForDrag("LeftButton")
BH.earthShieldReminderFrame:SetScript("OnDragStart", function()
    if not (BH.settings and BH.settings.earthShieldReminderLocked) or BH.previewMode then
        BH.earthShieldReminderFrame:StartMoving()
        BH.earthShieldReminderFrame:SetUserPlaced(false)
    end
end)
BH.earthShieldReminderFrame:SetScript("OnDragStop", function()
    BH.earthShieldReminderFrame:StopMovingOrSizing()
    BH:SaveEarthShieldReminderPosition()
end)
BH.earthShieldReminderFrame:Hide()

BH.earthShieldReminderText = BH.earthShieldReminderFrame:CreateFontString(nil, "OVERLAY")
BH.earthShieldReminderText:SetFont("Fonts\\FRIZQT__.TTF", 24, "OUTLINE")
BH.earthShieldReminderText:SetPoint("CENTER", BH.earthShieldReminderFrame, "CENTER", 0, 0)
BH.earthShieldReminderText:SetText("REMEMBER EARTH SHIELD")
BH.earthShieldReminderText:SetTextColor(0.00, 0.44, 0.87, 1)  -- Shaman blue

-- === Repair Reminder Frame ===
BH.repairReminderFrame = CreateFrame("Frame", "SquizzumablesRepairReminderFrame", UIParent)
BH.repairReminderFrame:SetSize(300, 40)
BH.repairReminderFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 120)
BH.repairReminderFrame:SetMovable(true)
BH.repairReminderFrame:SetClampedToScreen(true)
BH.repairReminderFrame:EnableMouse(true)
BH.repairReminderFrame:RegisterForDrag("LeftButton")
BH.repairReminderFrame:SetScript("OnDragStart", function()
    if not (BH.settings and BH.settings.repairReminderLocked) or BH.previewMode then
        BH.repairReminderFrame:StartMoving()
        BH.repairReminderFrame:SetUserPlaced(false)
    end
end)
BH.repairReminderFrame:SetScript("OnDragStop", function()
    BH.repairReminderFrame:StopMovingOrSizing()
    BH:SaveRepairReminderPosition()
end)
BH.repairReminderFrame:Hide()

BH.repairReminderText = BH.repairReminderFrame:CreateFontString(nil, "OVERLAY")
BH.repairReminderText:SetFont("Fonts\\FRIZQT__.TTF", 24, "OUTLINE")
BH.repairReminderText:SetPoint("CENTER", BH.repairReminderFrame, "CENTER", 0, 0)
BH.repairReminderText:SetText("REPAIR")
BH.repairReminderText:SetTextColor(0.9, 0.2, 0.2, 1)  -- Red for urgency

-- === Symbiotic Relationship Reminder (Druid) ===
BH.symbioticReminderFrame = CreateFrame("Frame", "SQUIZZUMABLESSymbioticReminder", UIParent)
BH.symbioticReminderFrame:SetSize(340, 50)
BH.symbioticReminderFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 80)
BH.symbioticReminderFrame:SetFrameStrata("HIGH")
BH.symbioticReminderFrame:SetMovable(true)
BH.symbioticReminderFrame:SetClampedToScreen(true)
BH.symbioticReminderFrame:EnableMouse(true)
BH.symbioticReminderFrame:RegisterForDrag("LeftButton")
BH.symbioticReminderFrame:SetScript("OnDragStart", function()
    if not (BH.settings and BH.settings.symbioticReminderLocked) or BH.previewMode then
        BH.symbioticReminderFrame:StartMoving()
        BH.symbioticReminderFrame:SetUserPlaced(false)
    end
end)
BH.symbioticReminderFrame:SetScript("OnDragStop", function()
    BH.symbioticReminderFrame:StopMovingOrSizing()
    BH:SaveSymbioticReminderPosition()
end)
BH.symbioticReminderFrame:Hide()

BH.symbioticReminderText = BH.symbioticReminderFrame:CreateFontString(nil, "OVERLAY")
BH.symbioticReminderText:SetFont("Fonts\\FRIZQT__.TTF", 24, "OUTLINE")
BH.symbioticReminderText:SetPoint("CENTER", BH.symbioticReminderFrame, "CENTER", 0, 0)
BH.symbioticReminderText:SetText("SYMBIOTIC RELATIONSHIP")
BH.symbioticReminderText:SetTextColor(0.2, 0.9, 0.2, 1)  -- Green

-- === Emerald Coach's Whistle Reminder ===
BH.coachWhistleReminderFrame = CreateFrame("Frame", "SQUIZZUMABLESCoachWhistleReminder", UIParent)
BH.coachWhistleReminderFrame:SetSize(340, 50)
BH.coachWhistleReminderFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
BH.coachWhistleReminderFrame:SetFrameStrata("HIGH")
BH.coachWhistleReminderFrame:SetMovable(true)
BH.coachWhistleReminderFrame:SetClampedToScreen(true)
BH.coachWhistleReminderFrame:EnableMouse(true)
BH.coachWhistleReminderFrame:RegisterForDrag("LeftButton")
BH.coachWhistleReminderFrame:SetScript("OnDragStart", function()
    if not (BH.settings and BH.settings.coachWhistleReminderLocked) or BH.previewMode then
        BH.coachWhistleReminderFrame:StartMoving()
        BH.coachWhistleReminderFrame:SetUserPlaced(false)
    end
end)
BH.coachWhistleReminderFrame:SetScript("OnDragStop", function()
    BH.coachWhistleReminderFrame:StopMovingOrSizing()
    BH:SaveCoachWhistleReminderPosition()
end)
BH.coachWhistleReminderFrame:Hide()

BH.coachWhistleReminderText = BH.coachWhistleReminderFrame:CreateFontString(nil, "OVERLAY")
BH.coachWhistleReminderText:SetFont("Fonts\\FRIZQT__.TTF", 24, "OUTLINE")
BH.coachWhistleReminderText:SetPoint("CENTER", BH.coachWhistleReminderFrame, "CENTER", 0, 0)
BH.coachWhistleReminderText:SetText("USE COACH'S WHISTLE")
BH.coachWhistleReminderText:SetTextColor(0.2, 0.9, 0.6, 1)  -- Teal/Emerald

-- === Hunter: No Pet Reminder ===
BH.petReminderFrame = CreateFrame("Frame", "SQUIZZUMABLESPetReminder", UIParent)
BH.petReminderFrame:SetSize(240, 50)
BH.petReminderFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
BH.petReminderFrame:SetFrameStrata("HIGH")
BH.petReminderFrame:SetMovable(true)
BH.petReminderFrame:SetClampedToScreen(true)
BH.petReminderFrame:EnableMouse(true)
BH.petReminderFrame:RegisterForDrag("LeftButton")
BH.petReminderFrame:SetScript("OnDragStart", function()
    if not (BH.settings and BH.settings.petReminderLocked) or BH.previewMode then
        BH.petReminderFrame:StartMoving()
        BH.petReminderFrame:SetUserPlaced(false)
    end
end)
BH.petReminderFrame:SetScript("OnDragStop", function()
    BH.petReminderFrame:StopMovingOrSizing()
    BH:SavePetReminderPosition()
end)
BH.petReminderFrame:Hide()

BH.petReminderText = BH.petReminderFrame:CreateFontString(nil, "OVERLAY")
BH.petReminderText:SetFont("Fonts\\FRIZQT__.TTF", 24, "OUTLINE")
BH.petReminderText:SetPoint("CENTER", BH.petReminderFrame, "CENTER", 0, 0)
BH.petReminderText:SetText("NO PET")
BH.petReminderText:SetTextColor(0.00, 0.78, 1.0, 1)  -- Hunter blue

-- === Food "No Items in Bag" Reminder ===
BH.foodReminderFrame = CreateFrame("Frame", "SQUIZZUMABLESFoodReminder", UIParent)
BH.foodReminderFrame:SetSize(280, 50)
BH.foodReminderFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 240)
BH.foodReminderFrame:SetFrameStrata("HIGH")
BH.foodReminderFrame:SetMovable(true)
BH.foodReminderFrame:SetClampedToScreen(true)
BH.foodReminderFrame:EnableMouse(true)
BH.foodReminderFrame:RegisterForDrag("LeftButton")
BH.foodReminderFrame:SetScript("OnDragStart", function()
    if not (BH.settings and BH.settings.foodReminderLocked) or BH.previewMode then
        BH.foodReminderFrame:StartMoving()
        BH.foodReminderFrame:SetUserPlaced(false)
    end
end)
BH.foodReminderFrame:SetScript("OnDragStop", function()
    BH.foodReminderFrame:StopMovingOrSizing()
    BH:SaveFoodReminderPosition()
end)
BH.foodReminderFrame:Hide()

BH.foodReminderText = BH.foodReminderFrame:CreateFontString(nil, "OVERLAY")
BH.foodReminderText:SetFont("Fonts\\FRIZQT__.TTF", 24, "OUTLINE")
BH.foodReminderText:SetPoint("CENTER", BH.foodReminderFrame, "CENTER", 0, 0)
BH.foodReminderText:SetText("NO FOOD IN BAGS")
BH.foodReminderText:SetTextColor(1, 0.55, 0.0, 1)  -- Orange

-- === Flask "No Items in Bag" Reminder ===
BH.flaskReminderFrame = CreateFrame("Frame", "SQUIZZUMABLESFlaskReminder", UIParent)
BH.flaskReminderFrame:SetSize(300, 50)
BH.flaskReminderFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 280)
BH.flaskReminderFrame:SetFrameStrata("HIGH")
BH.flaskReminderFrame:SetMovable(true)
BH.flaskReminderFrame:SetClampedToScreen(true)
BH.flaskReminderFrame:EnableMouse(true)
BH.flaskReminderFrame:RegisterForDrag("LeftButton")
BH.flaskReminderFrame:SetScript("OnDragStart", function()
    if not (BH.settings and BH.settings.flaskReminderLocked) or BH.previewMode then
        BH.flaskReminderFrame:StartMoving()
        BH.flaskReminderFrame:SetUserPlaced(false)
    end
end)
BH.flaskReminderFrame:SetScript("OnDragStop", function()
    BH.flaskReminderFrame:StopMovingOrSizing()
    BH:SaveFlaskReminderPosition()
end)
BH.flaskReminderFrame:Hide()

BH.flaskReminderText = BH.flaskReminderFrame:CreateFontString(nil, "OVERLAY")
BH.flaskReminderText:SetFont("Fonts\\FRIZQT__.TTF", 24, "OUTLINE")
BH.flaskReminderText:SetPoint("CENTER", BH.flaskReminderFrame, "CENTER", 0, 0)
BH.flaskReminderText:SetText("NO FLASK IN BAGS")
BH.flaskReminderText:SetTextColor(0.4, 0.8, 1.0, 1)  -- Light blue

-- === Oil "No Items in Bag" Reminder ===
BH.oilReminderFrame = CreateFrame("Frame", "SQUIZZUMABLESOilReminder", UIParent)
BH.oilReminderFrame:SetSize(300, 50)
BH.oilReminderFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 320)
BH.oilReminderFrame:SetFrameStrata("HIGH")
BH.oilReminderFrame:SetMovable(true)
BH.oilReminderFrame:SetClampedToScreen(true)
BH.oilReminderFrame:EnableMouse(true)
BH.oilReminderFrame:RegisterForDrag("LeftButton")
BH.oilReminderFrame:SetScript("OnDragStart", function()
    if not (BH.settings and BH.settings.oilReminderLocked) or BH.previewMode then
        BH.oilReminderFrame:StartMoving()
        BH.oilReminderFrame:SetUserPlaced(false)
    end
end)
BH.oilReminderFrame:SetScript("OnDragStop", function()
    BH.oilReminderFrame:StopMovingOrSizing()
    BH:SaveOilReminderPosition()
end)
BH.oilReminderFrame:Hide()

BH.oilReminderText = BH.oilReminderFrame:CreateFontString(nil, "OVERLAY")
BH.oilReminderText:SetFont("Fonts\\FRIZQT__.TTF", 24, "OUTLINE")
BH.oilReminderText:SetPoint("CENTER", BH.oilReminderFrame, "CENTER", 0, 0)
BH.oilReminderText:SetText("NO WEAPON OIL IN BAGS")
BH.oilReminderText:SetTextColor(0.5, 1.0, 0.5, 1)  -- Light green

-- === Healer CC Reminder ===
BH.healerCCReminderFrame = CreateFrame("Frame", "SQUIZZUMABLESHealerCCReminder", UIParent)
BH.healerCCReminderFrame:SetSize(280, 50)
BH.healerCCReminderFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 360)
BH.healerCCReminderFrame:SetFrameStrata("HIGH")
BH.healerCCReminderFrame:SetMovable(true)
BH.healerCCReminderFrame:SetClampedToScreen(true)
BH.healerCCReminderFrame:EnableMouse(true)
BH.healerCCReminderFrame:RegisterForDrag("LeftButton")
BH.healerCCReminderFrame:SetScript("OnDragStart", function()
    if not (BH.settings and BH.settings.healerCCReminderLocked) or BH.previewMode then
        BH.healerCCReminderFrame:StartMoving()
        BH.healerCCReminderFrame:SetUserPlaced(false)
    end
end)
BH.healerCCReminderFrame:SetScript("OnDragStop", function()
    BH.healerCCReminderFrame:StopMovingOrSizing()
    BH:SaveHealerCCReminderPosition()
end)
BH.healerCCReminderFrame:Hide()

BH.healerCCReminderText = BH.healerCCReminderFrame:CreateFontString(nil, "OVERLAY")
BH.healerCCReminderText:SetFont("Fonts\\FRIZQT__.TTF", 24, "OUTLINE")
BH.healerCCReminderText:SetPoint("CENTER", BH.healerCCReminderFrame, "CENTER", 0, 0)
BH.healerCCReminderText:SetText("HEALER IN CC")
BH.healerCCReminderText:SetTextColor(1.0, 0.2, 0.2, 1)  -- Red

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
    if not (BH.settings and BH.settings.bresCounterLocked) or BH.previewMode then
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
        if BH.previewMode then return end -- preview uses UpdateBresCounter() directly

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
    if self.previewMode then
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
    if not (BH.settings and BH.settings.deathTallyLocked) or BH.previewMode then
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

    if self.previewMode then
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
local function IsInValidInstance()
    local inInstance, instanceType = IsInInstance()
    
    -- Debug: uncomment to see what instance type you're in
    -- print("Squizzumables: inInstance=" .. tostring(inInstance) .. ", instanceType=" .. tostring(instanceType))
    
    -- party = 5-man dungeon (includes follower dungeons)
    -- raid = raid instance  
    -- scenario = delves and some special content (delves may report inInstance=false but instanceType=scenario)
    if instanceType == "party" or instanceType == "raid" or instanceType == "scenario" then
        return true
    end
    
    if not inInstance then return false end
    
    -- Fallback: Check if we're in a delve by map info
    local mapID = C_Map.GetBestMapForUnit("player")
    if mapID then
        local mapInfo = C_Map.GetMapInfo(mapID)
        if mapInfo and mapInfo.mapType == Enum.UIMapType.Dungeon then
            return true
        end
    end
    
    return false
end

-- Check if we should show buttons (valid instance, not in combat, M+ not active)
-- ============================================================================

-- Tracks which class buff spellIDs showed buttons on the previous UpdateButtons
-- pass. Used to fire per-buff sound alerts once per "buff becomes missing" transition.
-- Indexed by spellID: classBuffWasNeeded[spellID] = true when the buff was showing.
local classBuffWasNeeded = {}

local function ShouldShowButtons()
    -- Preview mode bypasses instance check
    if BH.previewMode then
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
    
    -- Hide during active M+.
    -- Belt-and-suspenders: also poll C_ChallengeMode directly so that a
    -- reload-while-in-M+ (where CHALLENGE_MODE_START never fires) is covered.
    if BH.challengeModeActive then
        return false
    end
    if C_ChallengeMode and C_ChallengeMode.IsChallengeModeActive
        and C_ChallengeMode.IsChallengeModeActive() then
        BH.challengeModeActive = true  -- re-sync flag
        -- Same reload-mid-key gap as above: start the death tally too if it
        -- somehow missed CHALLENGE_MODE_START (e.g. addon just loaded).
        if not deathTallyActive then
            BH:StartDeathTallyTracking()
        end
        return false
    end

    -- Hide in combat
    if InCombatLockdown() then
        return false
    end
    
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

function BH:UpdateButtons()
    if not IsLoggedIn() then return end  -- avoid running early when API is incomplete
    if InCombatLockdown() then return end -- cannot create/change secure buttons in combat

    -- Always update consumable bag reminders regardless of instance/zone
    self:UpdateFoodReminder()
    self:UpdateFlaskReminder()
    self:UpdateOilReminder()

    -- clear existing buttons - return to pool so frames are reused next UpdateButtons call
    for i,btn in ipairs(self.buttons) do
        btn:Hide()
        btn:ClearAllPoints()
        btn:SetScript("OnUpdate", nil)
        btn.expirationTime = nil
        btn.isCombatBuff = nil
        UnregisterStateDriver(btn, "visibility")  -- remove any per-button combat-buff state driver
        btn:SetParent(nil)
        table.insert(SQ_BUTTON_POOL, btn)
    end
    self.buttons = {}
    -- Clean up dummy preview buttons
    if self.previewDummyBtns then
        for _, db in ipairs(self.previewDummyBtns) do db:Hide(); db:SetParent(nil) end
        self.previewDummyBtns = nil
    end

    local id = 1
    local addedItems = {}  -- track items already added to avoid duplicates
    local hasPetButton = false  -- true if any pet summon button is created this pass
    local hasCombatBuff = false  -- true if any group-wide buff button is created this pass

    -- helper to check if item ID is in list
    local function HasItemInList(itemID, list)
        if not list then return false end
        for _, id in ipairs(list) do
            if id == itemID then return true end
        end
        return false
    end

    -- helper to check if player meets item level requirement
    local function MeetsLevelRequirement(itemID)
        local playerLevel = UnitLevel("player")
        local _, _, _, _, minLevel = C_Item.GetItemInfo(itemID)
        -- If item info not loaded yet, assume we can use it (will recheck on next update)
        if not minLevel then return true end
        return playerLevel >= minLevel
    end

    -- class buff(s) FIRST (will be in center)
    -- Show only when someone in the group is missing the buff
    -- Track which spellIDs generated buttons this pass (for per-buff sound alerts)
    local classBuff_spellIDs_this_pass = {}
    local _, class = UnitClass("player")
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
            for _, auraInfo in ipairs(info.auras) do
                local auraData = C_UnitAuras.GetUnitAuraBySpellID("player", auraInfo.spellID)
                if auraData and (not auraData.sourceUnit or UnitIsUnit(auraData.sourceUnit, "player")) then
                    myActiveCount = myActiveCount + 1
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
                                    local auraData = C_UnitAuras.GetUnitAuraBySpellID(unit, auraInfo.spellID)
                                    if auraData and auraData.sourceUnit and UnitIsUnit(auraData.sourceUnit, unit) then
                                        coveredByOthers[auraInfo.spellID] = true
                                    end
                                end
                            end
                        end
                    end
                end

                local showAuras = {}
                if paladinCount >= 2 then
                    -- 2+ paladins: show uncovered auras; for Holy Paladins also always
                    -- include Devotion Aura so it's available for Aura Mastery
                    for _, auraInfo in ipairs(info.auras) do
                        if self:IsEnabled(auraInfo.spellID) then
                            local forceForHoly = isHolyPaladin and (auraInfo.spellID == 465)
                            if forceForHoly or not coveredByOthers[auraInfo.spellID] then
                                table.insert(showAuras, auraInfo)
                            end
                        end
                    end
                else
                    -- Solo paladin: show all enabled auras so player can pick
                    for _, auraInfo in ipairs(info.auras) do
                        if self:IsEnabled(auraInfo.spellID) then
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

            -- Holy Paladin weapon imbue buttons (Rite of Sanctification / Rite of Adjuration)
            -- Lightsmith hero talents; mutually exclusive; replace oils for Holy spec.
            -- Not shown in M+ (can't be cast mid-key), not shown while dead.
            if not BH.challengeModeActive and not UnitIsDeadOrGhost("player") then
                local riteSpecID = PlayerUtil and PlayerUtil.GetCurrentSpecID and PlayerUtil.GetCurrentSpecID()
                if riteSpecID == 65 then  -- Holy Paladin
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
                            break  -- only one Rite can be known at a time (mutually exclusive talents)
                        end
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

    -- Class buff sound alert: play once per spellID when its button first appears
    do
        local s = self.settings
        for spellID, _ in pairs(classBuff_spellIDs_this_pass) do
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
            if not classBuff_spellIDs_this_pass[spellID] then
                classBuffWasNeeded[spellID] = nil
            end
        end
    end

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

    -- food: check for specific item IDs in bags
    -- Show if no food buff OR if buff time is below item's min duration
    local hasFoodBuff, foodExpiration = HasFoodBuff()
    if BH.consumables and BH.consumables.food then
        for bag = FIRST_BAG, LAST_BAG do
            for slot = 1, C_Container.GetContainerNumSlots(bag) do
                local itemID = C_Container.GetContainerItemID(bag, slot)
                if itemID and HasItemInList(itemID, BH.consumables.food) and not addedItems[itemID] and self:IsEnabled(itemID) and MeetsLevelRequirement(itemID) then
                    -- Check if needs refresh based on min duration setting
                    -- Guard against falsy-nil: food buffs with no expiration (hearty/permanent)
                    -- return nil from HasFoodBuff; nil is falsy so "x and nil or nil" = nil,
                    -- making NeedsRefresh think the buff is absent. Use (exp or 0) instead.
                    local foodExp = hasFoodBuff and (foodExpiration or 0) or nil
                    local needsRefresh = self:NeedsRefresh(itemID, foodExp)
                    if needsRefresh then
                        local icon = C_Item.GetItemIconByID(itemID)
                        local itemLink = C_Container.GetContainerItemLink(bag, slot)
                        local containerInfo = C_Container.GetContainerItemInfo(bag, slot)
                        local craftingQuality = containerInfo and containerInfo.craftingQuality
                        local bagCount = CountItemInBags(itemID)
                        self.buttons[id] = CreateButton(id, icon, "Use food", "item", itemID, nil, nil, foodExp, itemLink, craftingQuality, bagCount)
                        addedItems[itemID] = true
                        id = id+1
                    end
                end
            end
        end
    end

    -- flask: check for specific item IDs in bags
    -- Show if no flask buff OR if buff time is below item's min duration
    local hasFlaskBuff, flaskExpiration = HasFlaskBuff()
    if BH.consumables and BH.consumables.flask then
        for bag = FIRST_BAG, LAST_BAG do
            for slot = 1, C_Container.GetContainerNumSlots(bag) do
                local itemID = C_Container.GetContainerItemID(bag, slot)
                if itemID and HasItemInList(itemID, BH.consumables.flask) and not addedItems[itemID] and self:IsEnabled(itemID) and MeetsLevelRequirement(itemID) then
                    -- Check if needs refresh based on min duration setting
                    local flaskExp = hasFlaskBuff and (flaskExpiration or 0) or nil
                    local needsRefresh = self:NeedsRefresh(itemID, flaskExp)
                    if needsRefresh then
                        local icon = C_Item.GetItemIconByID(itemID)
                        local itemLink = C_Container.GetContainerItemLink(bag, slot)
                        local containerInfo = C_Container.GetContainerItemInfo(bag, slot)
                        local craftingQuality = containerInfo and containerInfo.craftingQuality
                        local bagCount = CountItemInBags(itemID)
                        self.buttons[id] = CreateButton(id, icon, "Use flask", "item", itemID, nil, nil, flaskExp, itemLink, craftingQuality, bagCount)
                        addedItems[itemID] = true
                        id = id+1
                    end
                end
            end
        end
    end

    -- oil: check for specific item IDs in bags, separate MH and OH buttons
    -- Skip oil buttons for Holy Paladins with a Lightsmith Rite talent (they use weapon imbues instead)
    local holyPaladinHasRite = false
    if class == "PALADIN" then
        local oilSpecID = PlayerUtil and PlayerUtil.GetCurrentSpecID and PlayerUtil.GetCurrentSpecID()
        if oilSpecID == 65 then  -- Holy Paladin
            holyPaladinHasRite = BH.PlayerKnowsSpell(433568) or BH.PlayerKnowsSpell(433583)
        end
    end
    if not holyPaladinHasRite and BH.consumables and BH.consumables.oil then
        local hasMH, mhExpiration = GetMainHandEnchantInfo()
        local hasOH, ohExpiration = GetOffHandEnchantInfo()
        local hasOHWeapon = HasOffHandWeapon()
        
        for bag = FIRST_BAG, LAST_BAG do
            for slot = 1, C_Container.GetContainerNumSlots(bag) do
                local itemID = C_Container.GetContainerItemID(bag, slot)
                if itemID and HasItemInList(itemID, BH.consumables.oil) and self:IsEnabled(itemID) and MeetsLevelRequirement(itemID) then
                    local icon = C_Item.GetItemIconByID(itemID)
                    local itemLink = C_Container.GetContainerItemLink(bag, slot)
                    local containerInfo = C_Container.GetContainerItemInfo(bag, slot)
                    local craftingQuality = containerInfo and containerInfo.craftingQuality
                    -- Main hand oil button (show if missing or below min duration)
                    local needsMH = self:NeedsRefresh(itemID, hasMH and mhExpiration or nil)
                    local oilCount = CountItemInBags(itemID)
                    if needsMH and not addedItems[itemID .. "_MH"] then
                        self.buttons[id] = CreateButton(id, icon, "Apply oil (MH)", "oil", {itemID = itemID, slot = 16}, nil, "MH", hasMH and mhExpiration or nil, itemLink, craftingQuality, oilCount)
                        addedItems[itemID .. "_MH"] = true
                        id = id+1
                    end
                    -- Off hand oil button (show if missing or below min duration)
                    if hasOHWeapon then
                        local needsOH = self:NeedsRefresh(itemID, hasOH and ohExpiration or nil)
                        if needsOH and not addedItems[itemID .. "_OH"] then
                            self.buttons[id] = CreateButton(id, icon, "Apply oil (OH)", "oil", {itemID = itemID, slot = 17}, nil, "OH", hasOH and ohExpiration or nil, itemLink, craftingQuality, oilCount)
                            addedItems[itemID .. "_OH"] = true
                            id = id+1
                        end
                    end
                end
            end
        end
    end

    else
        -- Not in a valid instance: hide instance-only reminder frames
        if self.beaconReminderFrame then self.beaconReminderFrame:Hide() end
        if self.earthShieldReminderFrame then self.earthShieldReminderFrame:Hide() end
        if self.symbioticReminderFrame then self.symbioticReminderFrame:Hide() end
    end -- ShouldShowButtons

    -- reposition buttons based on grow direction and layout direction
    local size = (self.settings and self.settings.buttonSize) or 36
    local spacing = (self.settings and self.settings.buttonSpacing) or 5
    local labelHeight = 26
    local headerHeight = 12
    local numButtons = id - 1
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

    -- show/hide main frame depending on buttons
    if self.previewMode then
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
        if self.previewDummyBtns then
            for _, db in ipairs(self.previewDummyBtns) do db:Hide(); db:SetParent(nil) end
        end
        self.previewDummyBtns = {}
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
            table.insert(self.previewDummyBtns, db)
        end
        if layout == "VERTICAL" then
            self.frame:SetSize(size, 3 * btnHeight + 2 * spacing)
        else
            self.frame:SetSize(3 * size + 2 * spacing, btnHeight)
        end
        self.frame:Show()
    elseif id == 1 then
        -- No buttons and not previewing - clean up and hide
        if self.previewDummyBtns then
            for _, db in ipairs(self.previewDummyBtns) do db:Hide(); db:SetParent(nil) end
            self.previewDummyBtns = nil
        end
        self.frame:Hide()
        BH.petFrame:Hide()
        BH.combatBuffFrame:Hide()
    else
        -- Real buttons exist - clean up dummies
        if self.previewDummyBtns then
            for _, db in ipairs(self.previewDummyBtns) do db:Hide(); db:SetParent(nil) end
            self.previewDummyBtns = nil
        end
        self.frame:Show()
        if hasPetButton then BH.petFrame:Show() else BH.petFrame:Hide() end
        if hasCombatBuff then BH.combatBuffFrame:Show() else BH.combatBuffFrame:Hide() end
    end

    -- Preview mode overlay on main buttons frame
    if self.previewMode then
        if not self.mainPreviewOverlay then
            local ov = self.frame:CreateTexture(nil, "OVERLAY")
            ov:SetAllPoints()
            ov:SetColorTexture(0.1, 0.8, 0.1, 0.15)
            self.mainPreviewOverlay = ov
        end
        self.mainPreviewOverlay:Show()
        -- Show main drag handle
        if self.dragHandle then self.dragHandle:Show() end
    else
        if self.mainPreviewOverlay then self.mainPreviewOverlay:Hide() end
    end

    -- Beacon reminder for Holy Paladins
    if ShouldShowButtons() then
        self:UpdateBeaconReminder()

        -- Earth Shield reminder for Shamans
        self:UpdateEarthShieldReminder()

        -- Repair reminder
        self:UpdateRepairReminder()

        -- Symbiotic Relationship reminder for Druids
        self:UpdateSymbioticReminder()
    end
    -- Coach's Whistle reminder called unconditionally so it hides when leaving instances
    self:UpdateCoachWhistleReminder()
    -- Hunter pet reminder
    self:UpdatePetReminder()
end

-- Update beacon reminder visibility for Holy Paladins
-- Shows big centered text when beacons are missing
function BH:UpdateBeaconReminder()
    if not self.beaconReminderFrame then return end

    if not (self.settings and self.settings.beaconReminderEnabled ~= false) then
        self.beaconReminderFrame:Hide()
        return
    end

    -- Only for Holy Paladins (spec index 1)
    local _, class = UnitClass("player")
    if class ~= "PALADIN" then
        self.beaconReminderFrame:Hide()
        return
    end

    ---@diagnostic disable-next-line: undefined-global
    local specID = PlayerUtil and PlayerUtil.GetCurrentSpecID and PlayerUtil.GetCurrentSpecID()
    if specID ~= 65 then -- 65 = Holy Paladin
        self.beaconReminderFrame:Hide()
        return
    end

    -- Follow the same visibility rules as the main frame
    if not ShouldShowButtons() then
        self.beaconReminderFrame:Hide()
        return
    end

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

    -- Count beacons sourced by the player on group members
    local myBeaconCount = 0
    local groupSize = GetNumGroupMembers()
    if groupSize > 0 then
        local isRaid = IsInRaid()
        for i = 1, groupSize do
            local unit = isRaid and ("raid" .. i) or ("party" .. i)
            if UnitExists(unit) and not UnitIsDeadOrGhost(unit) then
                for _, auraID in ipairs(BEACON_AURA_IDS) do
                    local auraData = C_UnitAuras.GetUnitAuraBySpellID(unit, auraID)
                    if auraData and auraData.sourceUnit and UnitIsUnit(auraData.sourceUnit, "player") then
                        myBeaconCount = myBeaconCount + 1
                        break -- only count one beacon per unit
                    end
                end
            end
        end
        -- Also check player (in raid, player is included; in party, check separately)
        if not isRaid then
            for _, auraID in ipairs(BEACON_AURA_IDS) do
                local auraData = C_UnitAuras.GetPlayerAuraBySpellID(auraID)
                if auraData and auraData.sourceUnit and UnitIsUnit(auraData.sourceUnit, "player") then
                    myBeaconCount = myBeaconCount + 1
                    break
                end
            end
        end
    else
        -- Solo - no group members to beacon
        self.beaconReminderFrame:Hide()
        return
    end

    if myBeaconCount < beaconsNeeded then
        self.beaconReminderFrame:Show()
        -- Enable/disable mouse based on lock
        local locked = self.settings and self.settings.beaconReminderLocked
        self.beaconReminderFrame:EnableMouse(self.previewMode or not locked)
    else
        self.beaconReminderFrame:Hide()
    end
end

-- Update Earth Shield reminder visibility for Restoration Shamans
-- Uses the same multi-shaman slot logic as the old button system
function BH:UpdateEarthShieldReminder()
    if not self.earthShieldReminderFrame then return end

    if not (self.settings and self.settings.earthShieldReminderEnabled ~= false) then
        self.earthShieldReminderFrame:Hide()
        return
    end

    -- Only for Shamans
    local _, class = UnitClass("player")
    if class ~= "SHAMAN" then
        self.earthShieldReminderFrame:Hide()
        return
    end

    -- Earth Shield must be known
    if not BH.PlayerKnowsSpell(974) then
        self.earthShieldReminderFrame:Hide()
        return
    end

    -- Earth Shield must be enabled in settings
    if not self:IsEnabled(974) then
        self.earthShieldReminderFrame:Hide()
        return
    end

    -- Follow the same visibility rules as the main frame
    if not ShouldShowButtons() then
        self.earthShieldReminderFrame:Hide()
        return
    end

    -- Must be in a group
    local groupSize = GetNumGroupMembers()
    if groupSize == 0 then
        self.earthShieldReminderFrame:Hide()
        return
    end

    -- Same logic as the old multi-shaman Earth Shield checks:
    -- Count how many Earth Shields the player has sourced (self + others)
    -- With Elemental Orbit the player can maintain ES on self + 1 other (max 2).
    -- Without Elemental Orbit the player can maintain 1 external ES (max 1).
    local myESCount = 0
    local hasSelfES = false

    -- Check if I have Earth Shield on myself (sourced by me = Elemental Orbit)
    for _, checkID in ipairs(ES_AURA_IDS) do
        local auraData = C_UnitAuras.GetPlayerAuraBySpellID(checkID)
        if auraData and auraData.sourceUnit and UnitIsUnit(auraData.sourceUnit, "player") then
            myESCount = myESCount + 1
            hasSelfES = true
            break
        end
    end

    -- Check group members for Earth Shields sourced by me
    local isRaid = IsInRaid()
    for i = 1, groupSize do
        local unit = isRaid and ("raid" .. i) or ("party" .. i)
        if not (isRaid and UnitIsUnit(unit, "player")) and UnitExists(unit) then
            for _, checkID in ipairs(ES_AURA_IDS) do
                local auraData = C_UnitAuras.GetUnitAuraBySpellID(unit, checkID)
                if auraData and auraData.sourceUnit and UnitIsUnit(auraData.sourceUnit, "player") then
                    myESCount = myESCount + 1
                    break
                end
            end
        end
    end

    -- Max slots: 2 with Elemental Orbit (self ES detected), 1 without
    local maxES = hasSelfES and 2 or 1

    if myESCount < maxES then
        self.earthShieldReminderFrame:Show()
        -- Enable/disable mouse based on lock
        local locked = self.settings and self.settings.earthShieldReminderLocked
        self.earthShieldReminderFrame:EnableMouse(self.previewMode or not locked)
    else
        self.earthShieldReminderFrame:Hide()
    end
end

-- Update repair reminder visibility
-- Shows big centered text when any equipped item's durability is below threshold
function BH:UpdateRepairReminder()
    if not self.repairReminderFrame then return end

    if not self.settings or not self.settings.repairReminderEnabled then
        self.repairReminderFrame:Hide()
        return
    end

    -- Hide during combat
    if InCombatLockdown() then
        self.repairReminderFrame:Hide()
        return
    end

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
        self.repairReminderFrame:EnableMouse(self.previewMode or not locked)
    else
        self.repairReminderFrame:Hide()
    end
end

-- Update Symbiotic Relationship reminder visibility for Druids
-- Shows big centered text when any party/raid member is missing the buff
function BH:UpdateSymbioticReminder()
    if not self.symbioticReminderFrame then return end

    if not (self.settings and self.settings.symbioticReminderEnabled ~= false) then
        self.symbioticReminderFrame:Hide()
        return
    end

    -- Only for Druids
    local _, class = UnitClass("player")
    if class ~= "DRUID" then
        self.symbioticReminderFrame:Hide()
        return
    end

    -- Symbiotic Relationship must be known (talent)
    if not BH.PlayerKnowsSpell(SYMBIOTIC_CAST_SPELL_ID) then
        self.symbioticReminderFrame:Hide()
        return
    end

    -- Follow the same visibility rules as the main frame
    if not ShouldShowButtons() then
        self.symbioticReminderFrame:Hide()
        return
    end

    -- Must be in a group
    local groupSize = GetNumGroupMembers()
    if groupSize == 0 then
        self.symbioticReminderFrame:Hide()
        return
    end

    -- Check if the player has the Symbiotic Relationship buff on themselves
    local auraData = C_UnitAuras.GetPlayerAuraBySpellID(SYMBIOTIC_AURA_SPELL_ID)
    if not auraData then
        local locked = self.settings and self.settings.symbioticReminderLocked
        self.symbioticReminderFrame:Show()
        self.symbioticReminderFrame:EnableMouse(self.previewMode or not locked)
    else
        self.symbioticReminderFrame:Hide()
    end
end

-- Update Emerald Coach's Whistle reminder visibility
function BH:UpdateCoachWhistleReminder()
    if not self.coachWhistleReminderFrame then return end

    if not (self.settings and self.settings.coachWhistleReminderEnabled ~= false) then
        self.coachWhistleReminderFrame:Hide()
        return
    end

    -- In preview mode, show regardless of group/buff state
    if self.previewMode then
        local locked = self.settings and self.settings.coachWhistleReminderLocked
        self.coachWhistleReminderFrame:Show()
        self.coachWhistleReminderFrame:EnableMouse(not locked)
        return
    end

    -- Trinket must be equipped
    local hasWhistle = GetInventoryItemID("player", 13) == COACH_WHISTLE_ITEM_ID
                    or GetInventoryItemID("player", 14) == COACH_WHISTLE_ITEM_ID
    if not hasWhistle then
        self.coachWhistleReminderFrame:Hide()
        return
    end

    if not ShouldShowButtons() then
        self.coachWhistleReminderFrame:Hide()
        return
    end

    -- Must have at least one real player group member (hides in solo delves with NPC companions)
    if not HasRealPlayerGroupMember() then
        self.coachWhistleReminderFrame:Hide()
        return
    end

    -- Show if coaching needs refreshing (buff missing or below min duration threshold)
    local coachExp = GetCoachedAllyExpiration()
    if not self:NeedsRefresh(COACH_WHISTLE_ITEM_ID, coachExp) then
        self.coachWhistleReminderFrame:Hide()
    else
        local locked = self.settings and self.settings.coachWhistleReminderLocked
        self.coachWhistleReminderFrame:Show()
        self.coachWhistleReminderFrame:EnableMouse(self.previewMode or not locked)
    end
end

-- Hunter: No Pet reminder
function BH:UpdatePetReminder()
    if not self.petReminderFrame then return end

    if not (self.settings and self.settings.petReminderEnabled ~= false) then
        self.petReminderFrame:Hide()
        return
    end

    -- Only for Hunters (class = HUNTER)
    local _, class = UnitClass("player")
    if class ~= "HUNTER" then
        self.petReminderFrame:Hide()
        return
    end

    -- Survival spec (255) does not use a pet — skip
    local specID = PlayerUtil and PlayerUtil.GetCurrentSpecID and PlayerUtil.GetCurrentSpecID()
    if specID == 255 then
        self.petReminderFrame:Hide()
        return
    end

    -- In preview mode always show
    if self.previewMode then
        self.petReminderFrame:Show()
        local locked = self.settings and self.settings.petReminderLocked
        self.petReminderFrame:EnableMouse(not locked)
        return
    end

    if not ShouldShowButtons() then
        self.petReminderFrame:Hide()
        return
    end

    -- Show when player has no active pet
    if UnitExists("pet") then
        self.petReminderFrame:Hide()
    else
        self.petReminderFrame:Show()
        local locked = self.settings and self.settings.petReminderLocked
        self.petReminderFrame:EnableMouse(self.previewMode or not locked)
    end
end

-- Update food "no items in bag" reminder
function BH:UpdateFoodReminder()
    if not self.foodReminderFrame then return end

    if not (self.settings and self.settings.foodReminderEnabled ~= false) then
        self.foodReminderFrame:Hide()
        return
    end

    -- Hide during combat
    if InCombatLockdown() then
        self.foodReminderFrame:Hide()
        return
    end

    -- Check if any enabled food items exist in bags
    if not self.consumables or not self.consumables.food then
        self.foodReminderFrame:Hide()
        return
    end

    local hasAnyEnabled = false
    local hasAnyInBags = false
    for _, itemID in ipairs(self.consumables.food) do
        if self:IsEnabled(itemID) then
            hasAnyEnabled = true
            for bag = FIRST_BAG, LAST_BAG do
                for slot = 1, C_Container.GetContainerNumSlots(bag) do
                    if C_Container.GetContainerItemID(bag, slot) == itemID then
                        hasAnyInBags = true
                        break
                    end
                end
                if hasAnyInBags then break end
            end
            if hasAnyInBags then break end
        end
    end

    if not hasAnyEnabled then
        self.foodReminderFrame:Hide()
        return
    end

    if not hasAnyInBags then
        local locked = self.settings and self.settings.foodReminderLocked
        self.foodReminderFrame:Show()
        self.foodReminderFrame:EnableMouse(self.previewMode or not locked)
    else
        self.foodReminderFrame:Hide()
    end
end

-- Update flask "no items in bag" reminder
function BH:UpdateFlaskReminder()
    if not self.flaskReminderFrame then return end

    if not (self.settings and self.settings.flaskReminderEnabled ~= false) then
        self.flaskReminderFrame:Hide()
        return
    end

    -- Hide during combat
    if InCombatLockdown() then
        self.flaskReminderFrame:Hide()
        return
    end

    if not self.consumables or not self.consumables.flask then
        self.flaskReminderFrame:Hide()
        return
    end

    local hasAnyEnabled = false
    local hasAnyInBags = false
    for _, itemID in ipairs(self.consumables.flask) do
        if self:IsEnabled(itemID) then
            hasAnyEnabled = true
            for bag = FIRST_BAG, LAST_BAG do
                for slot = 1, C_Container.GetContainerNumSlots(bag) do
                    if C_Container.GetContainerItemID(bag, slot) == itemID then
                        hasAnyInBags = true
                        break
                    end
                end
                if hasAnyInBags then break end
            end
            if hasAnyInBags then break end
        end
    end

    if not hasAnyEnabled then
        self.flaskReminderFrame:Hide()
        return
    end

    if not hasAnyInBags then
        local locked = self.settings and self.settings.flaskReminderLocked
        self.flaskReminderFrame:Show()
        self.flaskReminderFrame:EnableMouse(self.previewMode or not locked)
    else
        self.flaskReminderFrame:Hide()
    end
end

-- Update oil "no items in bag" reminder
function BH:UpdateOilReminder()
    if not self.oilReminderFrame then return end

    if not (self.settings and self.settings.oilReminderEnabled ~= false) then
        self.oilReminderFrame:Hide()
        return
    end

    -- Hide during combat
    if InCombatLockdown() then
        self.oilReminderFrame:Hide()
        return
    end

    -- Only show if there's a mainhand weapon equipped
    local mhItemID = GetInventoryItemID("player", 16)
    if not mhItemID then
        self.oilReminderFrame:Hide()
        return
    end

    if not self.consumables or not self.consumables.oil then
        self.oilReminderFrame:Hide()
        return
    end

    -- Suppress oil reminder for Holy Paladins with a Lightsmith Rite talented (weapon imbue replaces oil)
    local _, oilReminderClass = UnitClass("player")
    if oilReminderClass == "PALADIN" then
        local oilReminderSpecID = PlayerUtil and PlayerUtil.GetCurrentSpecID and PlayerUtil.GetCurrentSpecID()
        if oilReminderSpecID == 65 and (BH.PlayerKnowsSpell(433568) or BH.PlayerKnowsSpell(433583)) then
            self.oilReminderFrame:Hide()
            return
        end
    end

    local hasAnyEnabled = false
    local hasAnyInBags = false
    for _, itemID in ipairs(self.consumables.oil) do
        if self:IsEnabled(itemID) then
            hasAnyEnabled = true
            for bag = FIRST_BAG, LAST_BAG do
                for slot = 1, C_Container.GetContainerNumSlots(bag) do
                    if C_Container.GetContainerItemID(bag, slot) == itemID then
                        hasAnyInBags = true
                        break
                    end
                end
                if hasAnyInBags then break end
            end
            if hasAnyInBags then break end
        end
    end

    if not hasAnyEnabled then
        self.oilReminderFrame:Hide()
        return
    end

    if not hasAnyInBags then
        local locked = self.settings and self.settings.oilReminderLocked
        self.oilReminderFrame:Show()
        self.oilReminderFrame:EnableMouse(self.previewMode or not locked)
    else
        self.oilReminderFrame:Hide()
    end
end

-- Force-show or real-update all reminder frames depending on preview mode.
-- Call this whenever previewMode changes.
function BH:RefreshAllReminderFrames()
    if self.previewMode then
        -- Force-show all enabled reminder frames so they can be repositioned
        local function showIf(frame, settingKey, lockedKey)
            if not frame then return end
            if self.settings and self.settings[settingKey] == false then
                frame:Hide(); return
            end
            local locked = self.settings and self.settings[lockedKey]
            frame:EnableMouse(not locked)
            frame:Show()
        end
        showIf(self.beaconReminderFrame,    "beaconReminderEnabled",    "beaconReminderLocked")
        showIf(self.earthShieldReminderFrame,"earthShieldReminderEnabled","earthShieldReminderLocked")
        showIf(self.symbioticReminderFrame,  "symbioticReminderEnabled", "symbioticReminderLocked")
        showIf(self.coachWhistleReminderFrame,"coachWhistleReminderEnabled","coachWhistleReminderLocked")
        showIf(self.repairReminderFrame,     "repairReminderEnabled",    "repairReminderLocked")
        showIf(self.foodReminderFrame,       "foodReminderEnabled",      "foodReminderLocked")
        showIf(self.flaskReminderFrame,      "flaskReminderEnabled",     "flaskReminderLocked")
        showIf(self.oilReminderFrame,        "oilReminderEnabled",       "oilReminderLocked")
        showIf(self.healerCCReminderFrame,   "healerCCAlertEnabled",     "healerCCReminderLocked")
        -- Repair text preview
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
        self:UpdateFoodReminder()
        self:UpdateFlaskReminder()
        self:UpdateOilReminder()
        -- Healer CC: hide unless a healer actually has CC right now
        if self.healerCCReminderFrame then
            self.healerCCReminderFrame:Hide()
            local anyCC = false
            for u in pairs(healerWatchUnits) do
                if healerCCActive[u] then anyCC = true; break end
            end
            if anyCC then
                local locked = self.settings and self.settings.healerCCReminderLocked
                self.healerCCReminderFrame:EnableMouse(not locked)
                self.healerCCReminderFrame:Show()
            end
        end
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
    local preview = self.previewMode

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
        -- Unlock all frames for moving during preview
        self:UpdateFrameLock()
        -- Show drag handles regardless of lock
        if self.markersDragHandle then self.markersDragHandle:Show() end
        if self.pullReadyDragHandle then self.pullReadyDragHandle:Show() end
        -- Show green transparent overlay on main frame
        if self.frame and not self.mainPreviewOverlay then
            local ov = self.frame:CreateTexture(nil, "OVERLAY")
            ov:SetAllPoints()
            ov:SetColorTexture(0.1, 0.8, 0.1, 0.15)
            self.mainPreviewOverlay = ov
        end
        if self.mainPreviewOverlay then self.mainPreviewOverlay:Show() end
        -- Show green transparent overlay on markers frame
        if self.markersFrame and not self.markersPreviewOverlay then
            local ov = self.markersFrame:CreateTexture(nil, "OVERLAY")
            ov:SetAllPoints()
            ov:SetColorTexture(0.1, 0.8, 0.1, 0.15)
            self.markersPreviewOverlay = ov
        end
        if self.markersPreviewOverlay then self.markersPreviewOverlay:Show() end
        -- Show green transparent overlay on pull/ready frame
        if self.pullReadyFrame and not self.pullReadyPreviewOverlay then
            local ov = self.pullReadyFrame:CreateTexture(nil, "OVERLAY")
            ov:SetAllPoints()
            ov:SetColorTexture(0.1, 0.8, 0.1, 0.15)
            self.pullReadyPreviewOverlay = ov
        end
        if self.pullReadyPreviewOverlay then self.pullReadyPreviewOverlay:Show() end
        -- Show beacon reminder frame with overlay during preview
        if self.beaconReminderFrame then
            self.beaconReminderFrame:Show()
            self.beaconReminderFrame:EnableMouse(true)
            if not self.beaconPreviewOverlay then
                local ov = self.beaconReminderFrame:CreateTexture(nil, "OVERLAY")
                ov:SetAllPoints()
                ov:SetColorTexture(0.1, 0.8, 0.1, 0.15)
                self.beaconPreviewOverlay = ov
            end
            self.beaconPreviewOverlay:Show()
        end
        -- Show Earth Shield reminder frame with overlay during preview
        if self.earthShieldReminderFrame then
            self.earthShieldReminderFrame:Show()
            self.earthShieldReminderFrame:EnableMouse(true)
            if not self.earthShieldPreviewOverlay then
                local ov = self.earthShieldReminderFrame:CreateTexture(nil, "OVERLAY")
                ov:SetAllPoints()
                ov:SetColorTexture(0.1, 0.8, 0.1, 0.15)
                self.earthShieldPreviewOverlay = ov
            end
            self.earthShieldPreviewOverlay:Show()
        end
        -- Show Repair reminder frame with overlay during preview
        if self.repairReminderFrame then
            self.repairReminderFrame:Show()
            self.repairReminderFrame:EnableMouse(true)
            if not self.repairPreviewOverlay then
                local ov = self.repairReminderFrame:CreateTexture(nil, "OVERLAY")
                ov:SetAllPoints()
                ov:SetColorTexture(0.1, 0.8, 0.1, 0.15)
                self.repairPreviewOverlay = ov
            end
            self.repairPreviewOverlay:Show()
        end
        -- Show Symbiotic Relationship reminder frame with overlay during preview
        if self.symbioticReminderFrame then
            self.symbioticReminderFrame:Show()
            self.symbioticReminderFrame:EnableMouse(true)
            if not self.symbioticPreviewOverlay then
                local ov = self.symbioticReminderFrame:CreateTexture(nil, "OVERLAY")
                ov:SetAllPoints()
                ov:SetColorTexture(0.1, 0.8, 0.1, 0.15)
                self.symbioticPreviewOverlay = ov
            end
            self.symbioticPreviewOverlay:Show()
        end
        -- Show Bres counter frame with overlay during preview
        if self.bresCounterFrame then
            self:UpdateBresCounter()
            if not self.bresPreviewOverlay then
                local ov = self.bresCounterFrame:CreateTexture(nil, "OVERLAY")
                ov:SetAllPoints()
                ov:SetColorTexture(0.1, 0.8, 0.1, 0.15)
                self.bresPreviewOverlay = ov
            end
            self.bresPreviewOverlay:Show()
        end
        -- Show Death Tally frame with overlay during preview
        if self.deathTallyFrame then
            self:UpdateDeathTallyDisplay()
            if not self.deathTallyPreviewOverlay then
                local ov = self.deathTallyFrame:CreateTexture(nil, "OVERLAY")
                ov:SetAllPoints()
                ov:SetColorTexture(0.1, 0.8, 0.1, 0.15)
                self.deathTallyPreviewOverlay = ov
            end
            self.deathTallyPreviewOverlay:Show()
        end
        local consumReminders = {
            { frame = self.foodReminderFrame,  overlay = "foodPreviewOverlay"  },
            { frame = self.flaskReminderFrame, overlay = "flaskPreviewOverlay" },
            { frame = self.oilReminderFrame,   overlay = "oilPreviewOverlay"   },
        }
        for _, r in ipairs(consumReminders) do
            if r.frame then
                r.frame:Show()
                r.frame:EnableMouse(true)
                if not self[r.overlay] then
                    local ov = r.frame:CreateTexture(nil, "OVERLAY")
                    ov:SetAllPoints()
                    ov:SetColorTexture(0.1, 0.8, 0.1, 0.15)
                    self[r.overlay] = ov
                end
                self[r.overlay]:Show()
            end
        end

        -- Show CDM group previews
        if self.cdm and self.cdm.ShowPreview then
            self.cdm:ShowPreview()
        end

        -- Show preview control frame, anchor to options panel if available
        if self.previewControlFrame then
            if self.optionsPanel and self.optionsPanel:IsShown() then
                self.previewControlFrame:ClearAllPoints()
                self.previewControlFrame:SetPoint("TOPLEFT", self.optionsPanel, "TOPRIGHT", 4, 0)
            end
            self.previewControlFrame:Show()
        end
    else
        -- Hide overlays
        if self.mainPreviewOverlay then self.mainPreviewOverlay:Hide() end
        if self.markersPreviewOverlay then self.markersPreviewOverlay:Hide() end
        if self.pullReadyPreviewOverlay then self.pullReadyPreviewOverlay:Hide() end
        if self.beaconPreviewOverlay then self.beaconPreviewOverlay:Hide() end
        if self.earthShieldPreviewOverlay then self.earthShieldPreviewOverlay:Hide() end
        if self.repairPreviewOverlay then self.repairPreviewOverlay:Hide() end
        if self.symbioticPreviewOverlay then self.symbioticPreviewOverlay:Hide() end
        if self.bresPreviewOverlay then self.bresPreviewOverlay:Hide() end
        if self.bresCounterFrame and not bresTrackingActive then
            self.bresCounterFrame:Hide()
        end
        if self.deathTallyPreviewOverlay then self.deathTallyPreviewOverlay:Hide() end
        if self.deathTallyFrame then
            self:UpdateDeathTallyDisplay()
        end
        if self.foodPreviewOverlay then self.foodPreviewOverlay:Hide() end
        if self.flaskPreviewOverlay then self.flaskPreviewOverlay:Hide() end
        if self.oilPreviewOverlay then self.oilPreviewOverlay:Hide() end
        -- Restore reminder frames' mouse enable based on lock setting
        if self.beaconReminderFrame then
            local locked = self.settings and self.settings.beaconReminderLocked
            self.beaconReminderFrame:EnableMouse(not locked)
        end
        if self.earthShieldReminderFrame then
            local locked = self.settings and self.settings.earthShieldReminderLocked
            self.earthShieldReminderFrame:EnableMouse(not locked)
        end
        if self.repairReminderFrame then
            local locked = self.settings and self.settings.repairReminderLocked
            self.repairReminderFrame:EnableMouse(not locked)
        end
        if self.symbioticReminderFrame then
            local locked = self.settings and self.settings.symbioticReminderLocked
            self.symbioticReminderFrame:EnableMouse(not locked)
        end
        if self.foodReminderFrame then
            local locked = self.settings and self.settings.foodReminderLocked
            self.foodReminderFrame:EnableMouse(not locked)
        end
        if self.flaskReminderFrame then
            local locked = self.settings and self.settings.flaskReminderLocked
            self.flaskReminderFrame:EnableMouse(not locked)
        end
        if self.oilReminderFrame then
            local locked = self.settings and self.settings.oilReminderLocked
            self.oilReminderFrame:EnableMouse(not locked)
        end

        -- Restore bres counter mouse state based on lock
        if self.bresCounterFrame then
            local locked = self.settings and self.settings.bresCounterLocked
            self.bresCounterFrame:EnableMouse(not locked)
        end
        -- Re-evaluate repair reminder (may have been shown by preview)
        self:UpdateRepairReminder()
        -- Hide CDM group previews
        if self.cdm and self.cdm.HidePreview then
            self.cdm:HidePreview()
        end

        -- Restore beacon reminder - hide it (UpdateBeaconReminder will show if needed)

        -- Restore main frame lock state
        self:UpdateFrameLock()
        -- Restore drag handle visibility based on lock
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
        if not (BH.settings and BH.settings.raidToolsMarkersLocked) or BH.previewMode then
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
        if not (BH.settings and BH.settings.raidToolsMarkersLocked) or BH.previewMode then
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
        btn:RegisterForClicks("LeftButtonUp", "LeftButtonDown")
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
    clearWM:RegisterForClicks("LeftButtonUp", "LeftButtonDown")
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
        btn:RegisterForClicks("AnyDown", "AnyUp")
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
    clearTM:RegisterForClicks("AnyDown", "AnyUp")
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
        if not (BH.settings and BH.settings.raidToolsPullReadyLocked) or BH.previewMode then
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
        if not (BH.settings and BH.settings.raidToolsPullReadyLocked) or BH.previewMode then
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
    readyBtn:SetBackdropBorderColor(SQ_COLORS.accentDim[1], SQ_COLORS.accentDim[2], SQ_COLORS.accentDim[3], SQ_COLORS.accentDim[4])
    local readyLabel = readyBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    readyLabel:SetPoint("CENTER")
    readyLabel:SetText("Ready Check")
    readyLabel:SetTextColor(SQ_COLORS.accent[1], SQ_COLORS.accent[2], SQ_COLORS.accent[3])
    readyBtn:SetScript("OnEnter", function(self)
        self:SetBackdropColor(SQ_COLORS.controlHi[1], SQ_COLORS.controlHi[2], SQ_COLORS.controlHi[3], 1)
        self:SetBackdropBorderColor(SQ_COLORS.accent[1], SQ_COLORS.accent[2], SQ_COLORS.accent[3], 1)
    end)
    readyBtn:SetScript("OnLeave", function(self)
        self:SetBackdropColor(SQ_COLORS.control[1], SQ_COLORS.control[2], SQ_COLORS.control[3], 1)
        self:SetBackdropBorderColor(SQ_COLORS.accentDim[1], SQ_COLORS.accentDim[2], SQ_COLORS.accentDim[3], SQ_COLORS.accentDim[4])
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
    pullBtn:SetBackdropBorderColor(SQ_COLORS.accentDim[1], SQ_COLORS.accentDim[2], SQ_COLORS.accentDim[3], SQ_COLORS.accentDim[4])
    pullBtn.label = pullBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    pullBtn.label:SetPoint("CENTER")
    local pullDuration = (self.settings and self.settings.raidToolsPullTimer) or 10
    pullBtn.label:SetText("Pull " .. pullDuration .. "s")
    pullBtn.label:SetTextColor(SQ_COLORS.accent[1], SQ_COLORS.accent[2], SQ_COLORS.accent[3])
    pullBtn:SetScript("OnEnter", function(self)
        self:SetBackdropColor(SQ_COLORS.controlHi[1], SQ_COLORS.controlHi[2], SQ_COLORS.controlHi[3], 1)
        self:SetBackdropBorderColor(SQ_COLORS.accent[1], SQ_COLORS.accent[2], SQ_COLORS.accent[3], 1)
    end)
    pullBtn:SetScript("OnLeave", function(self)
        self:SetBackdropColor(SQ_COLORS.control[1], SQ_COLORS.control[2], SQ_COLORS.control[3], 1)
        self:SetBackdropBorderColor(SQ_COLORS.accentDim[1], SQ_COLORS.accentDim[2], SQ_COLORS.accentDim[3], SQ_COLORS.accentDim[4])
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
    pcf:SetScript("OnDragStop", function() pcf:StopMovingOrSizing() end)

    local pcfTitle = pcf:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    pcfTitle:SetPoint("TOP", pcf, "TOP", 0, -6)
    pcfTitle:SetText("Preview Mode")
    pcfTitle:SetTextColor(0.1, 0.8, 0.1)

    local lockBtn = CreateSQButton(pcf, "Lock All", 68, 22)
    lockBtn:SetPoint("BOTTOMLEFT", pcf, "BOTTOMLEFT", 6, 6)
    lockBtn:SetScript("OnClick", function()
        BH.settings.raidToolsMarkersLocked = true
        BH.settings.raidToolsPullReadyLocked = true
        BH.settings.beaconReminderLocked = true
        BH.settings.earthShieldReminderLocked = true
        BH.settings.repairReminderLocked = true
        BH.settings.symbioticReminderLocked = true
        BH.settings.bresCounterLocked = true
        BH.settings.deathTallyLocked = true
        BH.settings.frameLocked = true
        BH.settings.foodReminderLocked = true
        BH.settings.flaskReminderLocked = true
        BH.settings.oilReminderLocked = true
        BH:SaveSettings()
        -- Lock CDM groups
        if BH.cdm and BH.cdm.LockAll then
            BH.cdm:LockAll()
        end
        if BH.markersFrame then BH.markersFrame:SetMovable(false) end
        if BH.pullReadyFrame then BH.pullReadyFrame:SetMovable(false) end
        if BH.beaconReminderFrame then BH.beaconReminderFrame:SetMovable(false); BH.beaconReminderFrame:EnableMouse(false) end
        if BH.repairReminderFrame then BH.repairReminderFrame:SetMovable(false); BH.repairReminderFrame:EnableMouse(false) end
        if BH.symbioticReminderFrame then BH.symbioticReminderFrame:SetMovable(false); BH.symbioticReminderFrame:EnableMouse(false) end
        if BH.earthShieldReminderFrame then BH.earthShieldReminderFrame:SetMovable(false); BH.earthShieldReminderFrame:EnableMouse(false) end
        if BH.bresCounterFrame then BH.bresCounterFrame:SetMovable(false); BH.bresCounterFrame:EnableMouse(false) end
        if BH.deathTallyFrame then BH.deathTallyFrame:SetMovable(false); BH.deathTallyFrame:EnableMouse(false) end
        if BH.foodReminderFrame then BH.foodReminderFrame:SetMovable(false); BH.foodReminderFrame:EnableMouse(false) end
        if BH.flaskReminderFrame then BH.flaskReminderFrame:SetMovable(false); BH.flaskReminderFrame:EnableMouse(false) end
        if BH.oilReminderFrame then BH.oilReminderFrame:SetMovable(false); BH.oilReminderFrame:EnableMouse(false) end
        BH:UpdateFrameLock()
        -- Update options panel checkboxes if open
        if BH.rtLockMarkersCheckbox then BH.rtLockMarkersCheckbox:SetChecked(true) end
        if BH.rtLockPRCheckbox then BH.rtLockPRCheckbox:SetChecked(true) end
        if BH.rtLockBeaconCheckbox then BH.rtLockBeaconCheckbox:SetChecked(true) end
        if BH.trLockBeaconCheckbox then BH.trLockBeaconCheckbox:SetChecked(true) end
        if BH.trLockESCheckbox then BH.trLockESCheckbox:SetChecked(true) end
        if BH.trLockRepairCheckbox then BH.trLockRepairCheckbox:SetChecked(true) end
        if BH.trLockSymCheckbox then BH.trLockSymCheckbox:SetChecked(true) end
        if BH.rtLockBresCheckbox then BH.rtLockBresCheckbox:SetChecked(true) end
        if BH.kelLockDeathTallyCheckbox then BH.kelLockDeathTallyCheckbox:SetChecked(true) end
        if BH.itLockCheckbox then BH.itLockCheckbox:SetChecked(true) end
        if BH.lockCheckbox then BH.lockCheckbox:SetChecked(true) end
        if BH.trLockFoodCheckbox then BH.trLockFoodCheckbox:SetChecked(true) end
        if BH.trLockFlaskCheckbox then BH.trLockFlaskCheckbox:SetChecked(true) end
        if BH.trLockOilCheckbox then BH.trLockOilCheckbox:SetChecked(true) end
        print("Squizzumables: All frames locked")
    end)

    local closeBtn = CreateSQButton(pcf, "Close", 68, 22)
    closeBtn:SetPoint("BOTTOMRIGHT", pcf, "BOTTOMRIGHT", -6, 6)
    closeBtn:SetScript("OnClick", function()
        BH.previewMode = false
        if BH.previewBtn then BH.previewBtn:SetText("Preview") end
        BH:UpdateButtons()
        BH:UpdateRaidToolsVisibility()
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
    SendChatMessage(msg, channel)
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
BH.frame:RegisterEvent("CHAT_MSG_ADDON")  -- inter-addon feast alerts from other Squizzumables users
BH.frame:SetScript("OnEvent", function(self, event, arg1, ...)
    if event == "PLAYER_LOGIN" then
        BH:LoadSettings()
        -- Register user custom sounds into LSM before any UI is built
        RegisterCustomSoundsWithLSM()
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
        -- Entering combat: hide the main button frame (hides all non-pet buttons inside it).
        -- Pet buttons live on BH.petFrame (a plain non-secure Frame) so they stay visible.
        BH.frame:Hide()
        if BH.beaconReminderFrame then BH.beaconReminderFrame:Hide() end
        if BH.earthShieldReminderFrame then BH.earthShieldReminderFrame:Hide() end
        if BH.repairReminderFrame then BH.repairReminderFrame:Hide() end
        if BH.symbioticReminderFrame then BH.symbioticReminderFrame:Hide() end
        if BH.foodReminderFrame then BH.foodReminderFrame:Hide() end
        if BH.flaskReminderFrame then BH.flaskReminderFrame:Hide() end
        if BH.oilReminderFrame then BH.oilReminderFrame:Hide() end
        -- Brez counter stays visible in combat but disable mouse for click-through (BigWigs pattern)
        if BH.bresCounterFrame then BH.bresCounterFrame:EnableMouse(false) end
        if BH.deathTallyFrame then BH.deathTallyFrame:EnableMouse(false) end
    elseif event == "PLAYER_REGEN_ENABLED" then
        -- If a spec change fired during combat, apply it now that we're out.
        if BH.pendingSpecChange then
            BH:OnSpecChanged()
        end
        -- Use the debounced scheduler (0.2s delay) rather than immediate UpdateButtons:
        -- aura data (e.g. Lightning Shield, Water Shield) may not be fully settled the
        -- moment PLAYER_REGEN_ENABLED fires, causing false "buff missing" detections.
        BH:ScheduleUpdateButtons()
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
    elseif event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED_NEW_AREA" then
        -- Suppress buff sounds briefly after a loading screen: aura state is not
        -- restored immediately and would otherwise fire a false alert.
        BH.suppressBuffSounds = true
        C_Timer.After(3, function() BH.suppressBuffSounds = false end)
        -- Suppress lust alert during zone transition: UNIT_AURA fires as auras
        -- re-apply and would otherwise trigger a false lust alert.
        BH.playerZoning = true
        C_Timer.After(3, function() BH.playerZoning = false end)
        -- Zone change - check instance type and reset M+ state if not in dungeon
        local inInstance = IsInInstance()
        if not inInstance then
            BH.challengeModeActive = false
        else
            -- Entering instance - turn off preview mode, let normal behavior take over
            BH.previewMode = false
            if BH.previewBtn then
                BH.previewBtn:SetText("Preview")
            end
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
        BH:RefreshHealerWatchList()
    elseif event == "GET_ITEM_INFO_RECEIVED" then
        -- Rebuild feast lookup if this is a feast item whose data just arrived
        for _, feastItemID in ipairs(SQ_FEAST_ITEM_IDS) do
            if feastItemID == arg1 then
                BuildFeastSpellLookup()
                break
            end
        end
    elseif event == "BAG_UPDATE_DELAYED" or event == "PLAYER_EQUIPMENT_CHANGED" or event == "GROUP_ROSTER_UPDATE" or event == "UNIT_PET" then
        if event == "BAG_UPDATE_DELAYED" then
            BuildFeastSpellLookup()  -- pick up feast items added to bags mid-session
        end
        BH:UpdateButtons()
        if event == "GROUP_ROSTER_UPDATE" then
            BH:UpdateRaidToolsVisibility()
            BH:RefreshHealerWatchList()
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
        BH:CheckHealerCC(ccUnit)
        if BH.CheckKelAlerts then BH:CheckKelAlerts(ccUnit) end
    elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
        BH:OnSpecChanged()
    elseif event == "UPDATE_INVENTORY_DURABILITY" then
        BH:UpdateRepairReminder()
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        local castGUID, spellID = ...
        if arg1 == "player" then
            BH:OnFeastSpellcast(arg1, castGUID, spellID)
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
    elseif msg == 'debug' then
        -- Debug: show quality info for all consumable items in bags
        print(addonName.." Quality Debug:")
        for bag = FIRST_BAG, LAST_BAG do
            for slot = 1, C_Container.GetContainerNumSlots(bag) do
                local itemID = C_Container.GetContainerItemID(bag, slot)
                if itemID then
                    local itemLink = C_Container.GetContainerItemLink(bag, slot)
                    local containerInfo = C_Container.GetContainerItemInfo(bag, slot)
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
        print(addonName.." commands:")
        print("  /sq config - open options")
        print("  /sq reset - reset frame position")
        print("  /sq raidtools - toggle raid tools frame")
        print("  /sq reload - update buttons")
        print("  /sq feast - feast announce diagnostics")
        print("  /sq debug - show quality info")
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
