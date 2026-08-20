-- Core/EncounterTimeline.lua
-- Push Squizzumables' own timers onto Blizzard's encounter timeline.
--
-- Why only the write side is used here
-- -----------------------------------
-- The read side of C_EncounterTimeline reports which ability a boss is about to
-- cast, and the obvious feature to build on it is "play my sound when <ability>
-- is coming". That is not implementable, and it is worth writing down why so it
-- does not get attempted again.
--
-- Of EncounterTimelineEventInfo, only `id`, `source`, `duration` and
-- `maxQueueDuration` are readable. `spellID`, `spellName`, `iconFileID`,
-- `severity` and `isApproximate` are secret values: they can be passed straight
-- to a display function, but comparing one throws. So an addon can draw a bar
-- for an incoming ability, and cannot find out which ability it is.
--
-- BigWigs hits the same wall. Its current Midnight modules identify timeline
-- events by rounding `duration` to the nearest second and looking that up in a
-- hand-built per-boss, per-difficulty table -- see BigWigs_MidnightLairs. That
-- is the only method available, and it is a per-patch maintenance treadmill for
-- every boss in the game. Not something to take on here.
--
-- The write side has no such problem: a script event carries our own spell ID,
-- our own name and our own duration, so nothing about it is secret. That is
-- what this file does.
--
-- Being a good neighbour: our events report as
-- Enum.EncounterTimelineEventSource.Script (1), and BigWigs' Timeline plugin
-- explicitly skips that source, so these do not show up as duplicate BigWigs
-- bars.

local addonName, ns = ...
ns.BH = ns.BH or {}
local BH = ns.BH

local Timeline = {}
BH.Timeline = Timeline
ns.Timeline = Timeline

-- key -> eventID, so a timer started twice replaces itself rather than
-- stacking. Blizzard hands back an opaque EncounterTimelineEventID; treat it as
-- a token and never do arithmetic on it.
local active = {}

-- ============================================================================
-- Availability
-- ============================================================================

-- The namespace exists on every 12.0+ client, but the feature can be
-- unavailable (content that has no timeline) or available-but-switched-off by
-- the player. Both are normal, neither is an error.
function Timeline.IsAvailable()
    return C_EncounterTimeline ~= nil
        and C_EncounterTimeline.AddScriptEvent ~= nil
        and C_EncounterTimeline.IsFeatureAvailable ~= nil
        and C_EncounterTimeline.IsFeatureAvailable() == true
end

function Timeline.IsUsable()
    if not Timeline.IsAvailable() then return false end
    if C_EncounterTimeline.IsFeatureEnabled then
        return C_EncounterTimeline.IsFeatureEnabled() == true
    end
    return true
end

-- The two CVars IsFeatureEnabled is gated on, from Blizzard's own
-- EncounterTimelineConstants (EncounterTimelineVisibilityCVars). The timeline
-- one only takes effect while the master one is on -- Blizzard's options panel
-- greys it out otherwise -- so report them in that order.
local VISIBILITY_CVARS = {
    { cvar = "combatWarningsEnabled",    label = "Enable Boss Warnings" },
    { cvar = "encounterTimelineEnabled", label = "Boss Ability Timeline" },
}

--- Nil when the timeline is usable, otherwise a sentence saying what to switch
--- on. Blizzard's API only reports a flat false, which is a dead end for anyone
--- trying to work out why nothing appears.
function Timeline.WhyUnusable()
    if not C_EncounterTimeline then
        return "this client has no encounter timeline."
    end
    if not (C_EncounterTimeline.IsFeatureAvailable and C_EncounterTimeline.IsFeatureAvailable()) then
        return "the encounter timeline is not available here."
    end
    if Timeline.IsUsable() then return nil end

    if C_CVar and C_CVar.GetCVarBool then
        for _, entry in ipairs(VISIBILITY_CVARS) do
            local ok, on = pcall(C_CVar.GetCVarBool, entry.cvar)
            if ok and on == false then
                return string.format(
                    "'%s' is turned off in Options > Gameplay > Combat, under Combat Warnings.",
                    entry.label)
            end
        end
    end
    return "the encounter timeline is switched off in Blizzard's settings "
        .. "(Options > Gameplay > Combat, under Combat Warnings)."
end

-- Master switch plus the per-timer switch, both defaulting on.
local function Wanted(settingKey)
    local s = BH.settings
    if not s then return false end
    if s.timelineTimers == false then return false end
    if settingKey and s[settingKey] == false then return false end
    return true
end

-- ============================================================================
-- Helpers
-- ============================================================================

-- Severity is an optional field with a documented default of Medium. Resolve it
-- by name so a renamed or reordered enum degrades to "omit the field" rather
-- than passing a wrong number.
local function ResolveSeverity(name)
    if not name then return nil end
    local e = Enum and Enum.EncounterEventSeverity
    if not e then return nil end
    return e[name]
end

-- iconFileID must be a numeric file ID, not a texture path. Deriving it from a
-- spell is the only way to get one without hardcoding numbers that shift
-- between builds.
local function IconFromSpell(spellID)
    if not spellID then return nil end
    if C_Spell and C_Spell.GetSpellTexture then
        local tex = C_Spell.GetSpellTexture(spellID)
        if type(tex) == "number" then return tex end
    end
    return nil
end

-- ============================================================================
-- Public API
-- ============================================================================

--- Put a timer on the encounter timeline.
--  key                unique string; starting the same key again replaces the old event
--  spec.duration      seconds (required, > 0)
--  spec.name          display name, overrides whatever spellID would name it
--  spec.spellID       spell this represents, 0 if it is not really a spell
--  spec.iconSpell     spell to take the icon from, when spellID is 0
--  spec.iconFileID    explicit file ID, wins over iconSpell
--  spec.severity      "Low" / "Medium" / "High", omitted if the enum is missing
--  spec.maxQueueDuration, spec.paused  passed through
--  spec.setting       settings key that must not be false for this to fire
--
--  Returns the event ID, or nil plus a reason. Never raises: this is called
--  from click handlers where a failure must not take the button down with it.
function Timeline.Add(key, spec)
    if type(key) ~= "string" or type(spec) ~= "table" then return nil, "bad arguments" end
    if not Timeline.IsUsable() then return nil, Timeline.WhyUnusable() end
    if not Wanted(spec.setting) then return nil, "turned off in settings" end

    local duration = tonumber(spec.duration)
    if not duration or duration <= 0 then return nil, "no duration" end

    -- Replace rather than stack.
    Timeline.Cancel(key)

    local request = {
        spellID          = spec.spellID or 0,
        iconFileID       = spec.iconFileID or IconFromSpell(spec.iconSpell or spec.spellID) or 0,
        duration         = duration,
        maxQueueDuration = spec.maxQueueDuration or 0,
    }
    if spec.name then request.overrideName = spec.name end
    if spec.paused then request.paused = true end
    local sev = ResolveSeverity(spec.severity)
    if sev then request.severity = sev end

    local ok, eventID = pcall(C_EncounterTimeline.AddScriptEvent, request)
    if not ok or eventID == nil then
        return nil, "AddScriptEvent rejected the request"
    end

    active[key] = eventID
    return eventID
end

--- Remove a timer early. Silent if it was never started.
function Timeline.Cancel(key)
    local eventID = active[key]
    if eventID == nil then return false end
    active[key] = nil
    if C_EncounterTimeline and C_EncounterTimeline.CancelScriptEvent then
        pcall(C_EncounterTimeline.CancelScriptEvent, eventID)
    end
    return true
end

--- Run a timer out now, so it finishes the way it would have naturally.
function Timeline.Finish(key)
    local eventID = active[key]
    if eventID == nil then return false end
    active[key] = nil
    if C_EncounterTimeline and C_EncounterTimeline.FinishScriptEvent then
        pcall(C_EncounterTimeline.FinishScriptEvent, eventID)
    end
    return true
end

function Timeline.Pause(key)
    local eventID = active[key]
    if eventID == nil then return false end
    if C_EncounterTimeline and C_EncounterTimeline.PauseScriptEvent then
        pcall(C_EncounterTimeline.PauseScriptEvent, eventID)
    end
    return true
end

function Timeline.Resume(key)
    local eventID = active[key]
    if eventID == nil then return false end
    if C_EncounterTimeline and C_EncounterTimeline.ResumeScriptEvent then
        pcall(C_EncounterTimeline.ResumeScriptEvent, eventID)
    end
    return true
end

--- Drop every timer we own. Deliberately per-key rather than
--- CancelAllScriptEvents, which would also kill script events belonging to
--- other addons.
function Timeline.CancelAll()
    for key in pairs(active) do Timeline.Cancel(key) end
end

function Timeline.IsActive(key)
    return active[key] ~= nil
end

--- Seconds left on one of our timers, or nil. GetEventTimeRemaining is on the
--- readable side of the API, so this does not need secret handling.
function Timeline.TimeRemaining(key)
    local eventID = active[key]
    if eventID == nil then return nil end
    if not (C_EncounterTimeline and C_EncounterTimeline.GetEventTimeRemaining) then return nil end
    local ok, remaining = pcall(C_EncounterTimeline.GetEventTimeRemaining, eventID)
    if ok and type(remaining) == "number" then return remaining end
    return nil
end

-- ============================================================================
-- Named timers
--
-- Each entry is what a caller elsewhere in the addon passes to Start(), so the
-- icon and naming decisions live in one place instead of at every call site.
-- ============================================================================

Timeline.TIMERS = {
    -- Hourglass icon borrowed from Time Warp; overrideName means the spell's
    -- own name never shows, so this is purely a texture choice.
    pull = {
        name      = "Pull",
        iconSpell = 80353,
        severity  = "High",
        setting   = "timelinePullTimer",
    },
}

--- Start one of the named timers above.
function Timeline.Start(name, duration, overrides)
    local def = Timeline.TIMERS[name]
    if not def then return nil, "unknown timer '" .. tostring(name) .. "'" end
    local spec = {}
    for k, v in pairs(def) do spec[k] = v end
    if overrides then for k, v in pairs(overrides) do spec[k] = v end end
    spec.duration = duration
    return Timeline.Add(name, spec)
end

function Timeline.Stop(name)
    return Timeline.Cancel(name)
end

-- ============================================================================
-- Diagnostics -- /sq timeline
--
-- Reports whether the timeline is usable and, if not, which switch is off, then
-- fires a real 15s event so the display can be eyeballed.
--
-- A pull timer is pre-combat by definition, so whether a script event shows
-- outside an encounter decides if it is worth anything. Blizzard's
-- EncounterTimelineMixin:EvaluateVisibility settles it in our favour: under the
-- default "InEncounter" visibility it still returns true when
-- HasVisibleEvents() is true, and the comment there is explicit --
-- "Accommodating respawn timers and the like without having to fake the
-- in-encounter state. Also works for custom events." So a script event shows
-- itself, and the pull timer defaults on.
-- ============================================================================

function Timeline.PrintDiagnostics()
    local function say(fmt, ...)
        print("|cff33ff99Squizzumables|r: " .. string.format(fmt, ...))
    end

    if not C_EncounterTimeline then
        say("C_EncounterTimeline does not exist on this client.")
        return
    end

    say("IsFeatureAvailable: %s", tostring(C_EncounterTimeline.IsFeatureAvailable
        and C_EncounterTimeline.IsFeatureAvailable()))
    say("IsFeatureEnabled:   %s", tostring(C_EncounterTimeline.IsFeatureEnabled
        and C_EncounterTimeline.IsFeatureEnabled()))
    say("HasAnyEvents:       %s", tostring(C_EncounterTimeline.HasAnyEvents
        and C_EncounterTimeline.HasAnyEvents()))

    -- IsFeatureEnabled only ever reports a flat false, so show the CVars behind
    -- it rather than leaving the player to guess which switch is the problem.
    if C_CVar and C_CVar.GetCVarBool then
        for _, entry in ipairs(VISIBILITY_CVARS) do
            local ok, on = pcall(C_CVar.GetCVarBool, entry.cvar)
            say("  CVar %-24s %s   (%s)", entry.cvar,
                ok and tostring(on) or "unreadable", entry.label)
        end
    end

    local why = Timeline.WhyUnusable()
    if why then say("Not usable right now: %s", why) end

    local s = BH.settings or {}
    say("Setting timelineTimers: %s, timelinePullTimer: %s",
        tostring(s.timelineTimers ~= false), tostring(s.timelinePullTimer ~= false))

    local count = 0
    for _ in pairs(active) do count = count + 1 end
    say("Timers we currently own: %d", count)

    -- Fire a 15s test event. If the settings gate refuses it, retry past that
    -- gate so the diagnostic reports the API's answer rather than our own.
    local id, err = Timeline.Add("diagnostic", {
        duration  = 15,
        name      = "Squizzumables test",
        iconSpell = 80353,
        severity  = "High",
    })
    if not id and err == "turned off in settings" and BH.settings then
        local saved = BH.settings.timelineTimers
        BH.settings.timelineTimers = true
        id, err = Timeline.Add("diagnostic", {
            duration  = 15,
            name      = "Squizzumables test",
            iconSpell = 80353,
            severity  = "High",
        })
        BH.settings.timelineTimers = saved
    end

    if id then
        say("Added a 15s test event. If you can see it on the timeline right now, "
            .. "script events display outside encounters.")
        C_Timer.After(16, function() Timeline.Cancel("diagnostic") end)
    else
        say("Could not add a test event: %s", tostring(err))
    end
end

-- ============================================================================
-- Housekeeping
-- ============================================================================

local watcher = CreateFrame("Frame")
watcher:RegisterEvent("PLAYER_LEAVING_WORLD")
watcher:SetScript("OnEvent", function()
    -- A zone change invalidates anything we had running; leaving them behind
    -- would strand entries on the next zone's timeline.
    Timeline.CancelAll()
end)
