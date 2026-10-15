-- Group/RoleCCAlert.lua
-- The role CC alert: one frame that lights up when a group member in a
-- watched role (healer, tank) is crowd-controlled.
--
-- Moved out of Squizzumables.lua unchanged in 2.0 phase 2 (the split), apart
-- from its sound going through BH:PlaySound, the core's public wrapper for the
-- private PlaySQSound it used to call. Everything here is reached at runtime
-- through BH (UNIT_AURA, the unlock/preview path, the options window).

local addonName, ns = ...
local BH = ns.BH


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
        BH:PlaySound(self.settings.healerCCAlertSound or "None")
    end
    self:UpdateRoleCCFrame()
end


-- Any watched member currently CC'd? Used by the preview/refresh path.
function BH:AnyRoleCCActive()
    local healer, tank = ActiveCCRoles()
    return healer or tank
end
