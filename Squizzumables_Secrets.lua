-- Squizzumables_Secrets.lua
-- Safe access to values the client may mark "secret".
--
-- Background (client 12.1.0+): aura data is secret in combat, encounters, M+ and
-- PvP — exactly when these reminders most need to work. Two separate things can
-- go wrong:
--
--   1. C_UnitAuras.GetAuraDataByIndex() *throws* ("Auras cannot be accessed when
--      secret") rather than returning nil.
--   2. Even when a call succeeds, individual fields of the returned table can be
--      secret. Assigning, storing or passing a secret value is fine; *comparing*
--      it (==, <, >) or doing arithmetic on it (-, +) throws:
--        "attempt to compare field 'spellId' (a secret number value, while
--         execution tainted by 'Squizzumables')"
--
-- The addon used to wrap every such operation in pcall. That works, but it costs
-- a closure allocation at each call site (including per-button, per-frame in the
-- countdown timer) and has to be repeated at every downstream comparison — which
-- is how the v1.58 UnitHasBuff crash got through.
--
-- The client exposes real predicates for this. Check once, where the value is
-- read, and the resulting local is safe to compare and do arithmetic on freely:
--
--   issecretvalue(v)                 is this scalar secret
--   issecrettable(v)                 is this table secret
--   hasanysecretvalues(...)          vararg form, one call
--   C_Secrets.ShouldAurasBeSecret()  are we in a secret-aura context at all
--
-- Use the SafeAura* accessors below when reading aura fields. They return nil
-- rather than throwing, so callers just do a nil check.

local addonName, ns = ...
ns.BH = ns.BH or {}
local BH = ns.BH

local Secrets = {}
BH.Secrets = Secrets

local issecretvalue = issecretvalue
local issecrettable = issecrettable
local hasanysecretvalues = hasanysecretvalues
local ShouldAurasBeSecret = C_Secrets and C_Secrets.ShouldAurasBeSecret

-- ============================================================================
-- Primitives
-- ============================================================================

-- True if the value cannot be safely compared or used in arithmetic.
function Secrets.IsSecret(value)
    if issecretvalue and issecretvalue(value) then return true end
    if issecrettable and issecrettable(value) then return true end
    return false
end

-- Vararg form. Prefers the client's built-in when present.
function Secrets.HasAnySecret(...)
    if hasanysecretvalues then return hasanysecretvalues(...) end
    for i = 1, select("#", ...) do
        if Secrets.IsSecret((select(i, ...))) then return true end
    end
    return false
end

-- True when the client is currently hiding aura data. Useful for skipping work
-- entirely rather than scanning and discarding everything.
function Secrets.AurasAreSecret()
    return ShouldAurasBeSecret and ShouldAurasBeSecret() or false
end

-- Return value if it is a usable (non-secret) number, else fallback.
function Secrets.SafeNumber(value, fallback)
    if type(value) ~= "number" then return fallback end
    if Secrets.IsSecret(value) then return fallback end
    return value
end

-- Return value if it is a usable (non-secret) string, else fallback.
function Secrets.SafeString(value, fallback)
    if type(value) ~= "string" then return fallback end
    if Secrets.IsSecret(value) then return fallback end
    return value
end

-- ============================================================================
-- Aura field accessors
--
-- Each one checks the table, then the field, then the type, and returns nil
-- rather than throwing. A nil result means "could not read" — which callers
-- should treat the same as "not present", since that is the safe direction for
-- a reminder addon (we would rather show a reminder we did not need than
-- suppress one the player did).
-- ============================================================================

-- Guard shared by every accessor: is this a table we can read fields off at all?
local function readable(aura)
    return aura ~= nil and type(aura) == "table" and not Secrets.IsSecret(aura)
end

function Secrets.SafeAuraSpellID(aura)
    if not readable(aura) then return nil end
    return Secrets.SafeNumber(aura.spellId, nil)
end

function Secrets.SafeAuraName(aura)
    if not readable(aura) then return nil end
    return Secrets.SafeString(aura.name, nil)
end

-- Expiration in GetTime() terms, or nil if it could not be read.
--
-- 0 is passed through unchanged, NOT normalised to math.huge. 0 is the client's
-- "permanent / no duration" marker and this addon's call sites already test for
-- it explicitly (BH:NeedsRefresh treats 0 as "never needs refreshing";
-- CreateButton treats `> 0` as "this button gets a countdown"). Returning
-- math.huge here would make CreateButton start a timer for permanent buffs and
-- try to format infinity.
function Secrets.SafeAuraExpiration(aura)
    if not readable(aura) then return nil end
    return Secrets.SafeNumber(aura.expirationTime, nil)
end

function Secrets.SafeAuraDuration(aura)
    if not readable(aura) then return nil end
    return Secrets.SafeNumber(aura.duration, nil)
end

function Secrets.SafeAuraSourceUnit(aura)
    if not readable(aura) then return nil end
    local v = aura.sourceUnit
    if v == nil or Secrets.IsSecret(v) then return nil end
    return v
end

function Secrets.SafeAuraStacks(aura)
    if not readable(aura) then return nil end
    return Secrets.SafeNumber(aura.applications, nil)
end

-- ============================================================================
-- Aura lookup wrappers
-- ============================================================================

-- Direct lookup by spell ID. Does not throw the way GetAuraDataByIndex does,
-- so this is always preferable when the spell ID is known up front.
-- filter defaults to "HELPFUL".
function Secrets.GetAuraBySpellID(unit, spellID, filter)
    if not unit or not spellID then return nil end
    if not (C_UnitAuras and C_UnitAuras.GetUnitAuraBySpellID) then return nil end
    local ok, aura = pcall(C_UnitAuras.GetUnitAuraBySpellID, unit, spellID, filter)
    if not ok then return nil end
    return aura
end

-- Scan by index. Only needed when looking for an arbitrary/unknown aura; prefer
-- GetAuraBySpellID whenever the spell ID is known.
--
-- func(auraData, index) is called for each aura; return true from it to stop.
-- A failed read ends the scan, matching the previous behaviour of treating a
-- throw the same as running off the end of the list.
function Secrets.ForEachAura(unit, filter, func)
    if not unit or not func then return end
    if not (C_UnitAuras and C_UnitAuras.GetAuraDataByIndex) then return end
    for i = 1, 40 do
        local ok, auraData = pcall(C_UnitAuras.GetAuraDataByIndex, unit, i, filter)
        if not ok or not auraData then return end
        if func(auraData, i) then return end
    end
end
