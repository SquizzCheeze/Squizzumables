-- Core/Gate.lua
-- One answer to "can I act right now?" (2.0, phase 1).
--
-- Before 2.0 every feature asked this itself, and almost always asked only
-- about combat. 12.1 has more than combat: Enum.AddOnRestrictionType lists
-- Combat, Encounter, ChallengeMode (a whole active Mythic+ key), PvPMatch,
-- Map and Chat, and auras can be hidden from addons outside all of them. The
-- 12.1.5 labyrinth (2026-10-14/15) broke three things at once for exactly this
-- reason: buff sounds refused, every reminder button shown, a GSE keybind lost.
--
-- What the Gate does NOT do is decide which restriction blocks which call.
-- That is not documented anywhere -- an Encounter refused AddAuraSound, while
-- secure reminder buttons kept working between Mythic+ pulls under
-- ChallengeMode for years -- so each caller still says which questions it
-- cares about. The Gate's job is that the questions are asked the same way
-- everywhere, and that work refused now is retried once the state changes,
-- instead of every feature growing its own retry timer.

local addonName, ns = ...
ns.BH = ns.BH or {}
local BH = ns.BH

local Gate = {}
BH.Gate = Gate

-- Non-combat restrictions worth waiting out, in the order reported. Chat is
-- left out: it governs addon messages, which nothing here gates on.
local RESTRICTIONS = { "Encounter", "ChallengeMode", "PvPMatch", "Map" }

local RA = C_RestrictedActions
local hasRestrictions = RA and RA.IsAddOnRestrictionActive
    and Enum and Enum.AddOnRestrictionType and true or false

--- Name of the first non-combat restriction in force, or nil.
---@return string?
function Gate.Restriction()
    if not hasRestrictions then return nil end
    local types = Enum.AddOnRestrictionType
    for _, name in ipairs(RESTRICTIONS) do
        local t = types[name]
        if t ~= nil and RA.IsAddOnRestrictionActive(t) then return name end
    end
end

function Gate.InCombat()
    return InCombatLockdown()
end

--- True while the client hides aura data from addons. Out of combat this is
--- the stuck state the labyrinth left behind: nothing about the aura can be
--- read, so "not found" must not be taken to mean "missing".
function Gate.AurasHidden()
    return BH.Secrets.AurasAreSecret()
end

--- Why protected work should wait right now: "Combat", a restriction name,
--- or nil when nothing stands in the way.
---@return string?
function Gate.Blocked()
    if InCombatLockdown() then return "Combat" end
    return Gate.Restriction()
end

-- ---------------------------------------------------------------------------
-- Change notification and deferred work
-- ---------------------------------------------------------------------------

local listeners = {}   -- [fn] = true
local deferred  = {}   -- [key] = { fn = fn, test = test }

--- Call fn() whenever combat or a restriction starts or ends. A frame after
--- the change, because the client reports every restriction as inactive WHILE
--- ADDON_RESTRICTION_STATE_CHANGED is being dispatched.
function Gate.OnChange(fn)
    listeners[fn] = true
end

--- Run fn now if test() returns nothing, otherwise hold it until a state
--- change finds test() clear. One pending entry per key: a second Defer with
--- the same key replaces the first, so a burst of requests runs once.
--- test defaults to Gate.Blocked. Returns true if fn ran now.
---@param key string
---@param fn function
---@param test? function
---@return boolean
function Gate.Defer(key, fn, test)
    test = test or Gate.Blocked
    if not test() then
        deferred[key] = nil
        fn()
        return true
    end
    deferred[key] = { fn = fn, test = test }
    return false
end

--- Is anything waiting under this key?
function Gate.IsDeferred(key)
    return deferred[key] ~= nil
end

local function Flush()
    -- Collect first: a flushed fn may Defer again, and adding keys to a table
    -- while pairs() walks it is undefined in Lua.
    local ready = {}
    for key, entry in pairs(deferred) do
        if not entry.test() then ready[#ready + 1] = key end
    end
    for _, key in ipairs(ready) do
        local entry = deferred[key]
        deferred[key] = nil
        if entry then entry.fn() end
    end
    for fn in pairs(listeners) do fn() end
end

local pending = false
local function Changed()
    if pending then return end
    pending = true
    C_Timer.After(0, function()
        pending = false
        Flush()
    end)
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_REGEN_ENABLED")
f:RegisterEvent("PLAYER_REGEN_DISABLED")
if hasRestrictions then
    f:RegisterEvent("ADDON_RESTRICTION_STATE_CHANGED")
end
f:SetScript("OnEvent", Changed)

--- One line for diagnostics (/sq buffsounds and friends).
function Gate.Describe()
    return ("combat: %s, restriction: %s, auras hidden: %s"):format(
        tostring(InCombatLockdown()), Gate.Restriction() or "none",
        tostring(Gate.AurasHidden()))
end
