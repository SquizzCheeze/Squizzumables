-- Squizzumables: rotation helper probe (/sq rotprobe) -- a TEMPORARY diagnostic.
--
-- Answers one question before any feature is built on it: what can an addon
-- still read about Blizzard's rotation helper and the player's spells while
-- the 12.1.5 restrictions are up? The generated API docs say (build 70448):
--
--   C_AssistedCombat.GetNextCastSpell   no secret return -> readable?
--   SPELL_ACTIVATION_OVERLAY_GLOW_SHOW   spellID payload not flagged secret
--   C_Spell.IsSpellUsable / IsSpellInRange   not flagged secret
--   C_Spell.GetSpellCooldown             SecretWhenCooldownsRestricted
--   GetSpellCooldownDuration -> curve -> SetAlpha   "show only when ready",
--       decided engine-side, if SetAlpha takes the curve's (secret) result
--   UnitHealthPercent(curve) -> SetAlpha   "light a defensive below X%"
--
-- Docs are not measurements, so this counts what each call actually returns
-- (plain / secret / nil / error), bucketed by the restrictions in force at the
-- time (C_RestrictedActions) plus the instance type. Turn it on, play through
-- open world, dungeon trash, a boss and a key, then /reload: the counts are in
-- SquizzumablesDB.rotProbe and /sq rotprobe report prints them.
--
-- Everything is inert until switched on. Nothing here touches a Blizzard
-- frame: the only thing written is the alpha of our own hidden texture.
--
-- Unlisted like every diagnostic (see CLAUDE.md). REMOVE this file and its
-- .toc line once the rotation feature is built or abandoned.

local addonName, ns = ...
local BH = ns and ns.BH
if not BH then return end

local Probe = {}
BH.RotProbe = Probe

local SAMPLE_INTERVAL = 0.2   -- in combat or under a restriction
local IDLE_INTERVAL = 2       -- otherwise: a baseline, not worth 5 a second
local MAX_ERRORS = 12

local RESTRICTIONS = {"Combat", "Encounter", "ChallengeMode", "PvPMatch", "Map"}

local function IsSecret(v) return BH.Secrets.IsSecret(v) end

-- "secret" / "nil" / "plain". The secret test comes first: it is the one
-- check that is always safe on a secret.
local function Classify(v)
    if IsSecret(v) then return "secret" end
    if v == nil then return "nil" end
    return "plain"
end

local function DB()
    local root = _G.SquizzumablesDB
    if type(root) ~= "table" then return nil end
    root.rotProbe = root.rotProbe or {}
    local db = root.rotProbe
    db.contexts = db.contexts or {}
    db.errors = db.errors or {}
    db.extras = db.extras or {}
    return db
end

-- Which restrictions are in force, plus the instance type: "party: Combat+ChallengeMode".
local function ContextKey()
    local parts = {}
    local RA, types = C_RestrictedActions, Enum and Enum.AddOnRestrictionType
    if RA and RA.IsAddOnRestrictionActive and types then
        for _, name in ipairs(RESTRICTIONS) do
            local t = types[name]
            if t ~= nil and RA.IsAddOnRestrictionActive(t) then parts[#parts + 1] = name end
        end
    end
    if #parts == 0 and InCombatLockdown() then parts[1] = "lockdown only" end
    local _, instanceType = GetInstanceInfo()
    local where = (type(instanceType) == "string" and instanceType ~= "") and instanceType or "?"
    if #parts == 0 then return where .. ": no restriction", false end
    return where .. ": " .. table.concat(parts, "+"), true
end

local function Bump(c, field)
    c[field] = (c[field] or 0) + 1
end

local function NoteError(db, where, err)
    if #db.errors >= MAX_ERRORS then return end
    local msg = where .. ": " .. tostring(err)
    for _, e in ipairs(db.errors) do if e == msg then return end end
    db.errors[#db.errors + 1] = msg
end

-----------------------------------------------------------------------
-- What gets probed
-----------------------------------------------------------------------

local spells = {}       -- rotation spells + /sq rotprobe add
local probeTex          -- our own hidden texture; only its alpha is ever set
local readyCurve, healthCurve

local function RebuildSpellList()
    wipe(spells)
    local seen = {}
    local ok, list = pcall(C_AssistedCombat.GetRotationSpells)
    if ok and type(list) == "table" then
        for _, id in ipairs(list) do
            if not IsSecret(id) and not seen[id] then
                seen[id] = true
                spells[#spells + 1] = id
            end
        end
    end
    local db = DB()
    for _, id in ipairs(db and db.extras or {}) do
        if not seen[id] then
            seen[id] = true
            spells[#spells + 1] = id
        end
    end
end

local function EnsureProbeObjects()
    if probeTex then return end
    local holder = CreateFrame("Frame", nil, UIParent)
    holder:Hide()
    probeTex = holder:CreateTexture(nil, "ARTWORK")
    if C_CurveUtil and C_CurveUtil.CreateCurve then
        -- Remaining cooldown -> alpha: 1 when ready, 0.3 while cooling.
        readyCurve = C_CurveUtil.CreateCurve()
        readyCurve:SetType(Enum.LuaCurveType.Step)
        readyCurve:AddPoint(0, 1)
        readyCurve:AddPoint(0.05, 0.3)
        readyCurve:AddPoint(100000, 0.3)
        -- Health -> alpha: lit at or below half. Covers both a 0-1 and a
        -- 0-100 scale, since which one the curve sees is part of the question.
        healthCurve = C_CurveUtil.CreateCurve()
        healthCurve:SetType(Enum.LuaCurveType.Step)
        healthCurve:AddPoint(0, 1)
        healthCurve:AddPoint(0.5, 0.3)
        healthCurve:AddPoint(50, 0.3)
    end
end

-- Hand a (possibly secret) value to SetAlpha on our texture.
local function TryAlpha(c, field, value)
    if not IsSecret(value) and value == nil then return end
    local ok = pcall(probeTex.SetAlpha, probeTex, value)
    Bump(c, field .. (ok and ".ok" or ".refused"))
end

-----------------------------------------------------------------------
-- Sampling
-----------------------------------------------------------------------

local function SampleNext(db, c)
    for _, visible in ipairs({false, true}) do
        local field = visible and "nextVisibleButton" or "nextSpell"
        local ok, id = pcall(C_AssistedCombat.GetNextCastSpell, visible)
        if not ok then
            Bump(c, field .. ".error")
            NoteError(db, field, id)
        else
            local kind = Classify(id)
            Bump(c, field .. "." .. kind)
            if kind == "plain" and not visible then
                c.distinctNext = c.distinctNext or {}
                c.distinctNext[id] = true
            end
        end
    end
end

local function SampleSpell(db, c, id)
    local ok, info = pcall(C_Spell.GetSpellCooldown, id)
    if not ok then
        NoteError(db, "GetSpellCooldown", info)
    elseif not IsSecret(info) and info then
        Bump(c, "cooldownStart." .. Classify(info.startTime))
    end

    local okU, usable = pcall(C_Spell.IsSpellUsable, id)
    if okU then Bump(c, "usable." .. Classify(usable)) else NoteError(db, "IsSpellUsable", usable) end

    if UnitExists("target") then
        local okR, inRange = pcall(C_Spell.IsSpellInRange, id, "target")
        if okR then Bump(c, "inRange." .. Classify(inRange)) else NoteError(db, "IsSpellInRange", inRange) end
    end

    local okD, dur = pcall(C_Spell.GetSpellCooldownDuration, id)
    if not okD then
        NoteError(db, "GetSpellCooldownDuration", dur)
        return
    end
    if not dur then
        Bump(c, "duration.none")
        return
    end
    local okS, hasSecret = pcall(dur.HasSecretValues, dur)
    local secretDur = okS and hasSecret == true
    Bump(c, "duration." .. (secretDur and "secretValues" or "plainValues"))

    local okZ, zero = pcall(dur.IsZero, dur)
    if okZ then Bump(c, "durationIsZero." .. Classify(zero)) else NoteError(db, "IsZero", zero) end

    if readyCurve then
        local okE, result = pcall(dur.EvaluateRemainingDuration, dur, readyCurve)
        if not okE then
            Bump(c, "readyCurve.error")
            NoteError(db, "EvaluateRemainingDuration", result)
        else
            Bump(c, "readyCurve." .. Classify(result))
            -- The question that matters: does SetAlpha take it while the
            -- duration itself is secret?
            TryAlpha(c, secretDur and "readyAlpha(secret duration)" or "readyAlpha(plain duration)", result)
        end
    end
end

local function SampleHealth(db, c)
    if not (healthCurve and UnitHealthPercent) then return end
    local ok, value = pcall(UnitHealthPercent, "player", true, healthCurve)
    if not ok then
        Bump(c, "healthCurve.error")
        NoteError(db, "UnitHealthPercent", value)
        return
    end
    Bump(c, "healthCurve." .. Classify(value))
    TryAlpha(c, "healthAlpha", value)
end

local function Sample()
    local db = DB()
    if not db then return end
    local key, restricted = ContextKey()
    local c = db.contexts[key]
    if not c then
        c = {}
        db.contexts[key] = c
    end
    Bump(c, "samples")
    SampleNext(db, c)
    for _, id in ipairs(spells) do SampleSpell(db, c, id) end
    SampleHealth(db, c)
    return restricted
end

local driver = CreateFrame("Frame")
driver:Hide()
local wait = 0
driver:SetScript("OnUpdate", function(_, elapsed)
    wait = wait - elapsed
    if wait > 0 then return end
    local restricted = Sample()
    wait = (restricted or InCombatLockdown()) and SAMPLE_INTERVAL or IDLE_INTERVAL
end)

-- Proc glows: does the payload arrive readable under each restriction?
local events = CreateFrame("Frame")
events:SetScript("OnEvent", function(_, event, spellID)
    local db = DB()
    if not db then return end
    if event == "SPELLS_CHANGED" or event == "PLAYER_SPECIALIZATION_CHANGED" then
        RebuildSpellList()
        return
    end
    local key = ContextKey()
    local c = db.contexts[key] or {}
    db.contexts[key] = c
    local field = event == "SPELL_ACTIVATION_OVERLAY_GLOW_SHOW" and "procShow" or "procHide"
    local kind = Classify(spellID)
    Bump(c, field .. "." .. kind)
    if kind == "plain" and field == "procShow" then
        local ok, on = pcall(C_SpellActivationOverlay.IsSpellOverlayed, spellID)
        if ok then Bump(c, "isOverlayed." .. Classify(on)) else NoteError(db, "IsSpellOverlayed", on) end
    end
end)

-----------------------------------------------------------------------
-- On / off / report
-----------------------------------------------------------------------

local function SetRunning(on)
    if on then
        EnsureProbeObjects()
        RebuildSpellList()
        events:RegisterEvent("SPELL_ACTIVATION_OVERLAY_GLOW_SHOW")
        events:RegisterEvent("SPELL_ACTIVATION_OVERLAY_GLOW_HIDE")
        events:RegisterEvent("SPELLS_CHANGED")
        events:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
        wait = 0
        driver:Show()
    else
        events:UnregisterAllEvents()
        driver:Hide()
    end
end

local function Count(t)
    local n = 0
    for _ in pairs(t or {}) do n = n + 1 end
    return n
end

-- One line per measurement, "kind=count" pairs in a fixed order.
local GROUPS = {
    {"nextSpell", "Blizzard's next spell"},
    {"nextVisibleButton", "  ...as Blizzard's highlight asks"},
    {"procShow", "Proc glow shown (spellID)"},
    {"isOverlayed", "  IsSpellOverlayed"},
    {"usable", "IsSpellUsable"},
    {"inRange", "IsSpellInRange"},
    {"cooldownStart", "GetSpellCooldown start"},
    {"duration", "Cooldown duration object"},
    {"durationIsZero", "  duration:IsZero()"},
    {"readyCurve", "  remaining -> curve"},
    {"readyAlpha(secret duration)", "  SetAlpha(curve), secret duration"},
    {"readyAlpha(plain duration)", "  SetAlpha(curve), plain duration"},
    {"healthCurve", "Health % -> curve"},
    {"healthAlpha", "  SetAlpha(health curve)"},
}
local KINDS = {"plain", "secret", "nil", "error", "ok", "refused", "secretValues", "plainValues", "none"}

function Probe:Report()
    local db = DB()
    if not db then return end
    print("|cFF33CC99" .. addonName .. " rotprobe|r -- " .. (db.on and "RUNNING" or "off")
        .. ", " .. #spells .. " spells probed")
    local okA, avail, reason = pcall(C_AssistedCombat.IsAvailable)
    if okA then
        print("  Rotation helper available: " .. tostring(avail)
            .. ((reason and reason ~= "") and (" (" .. tostring(reason) .. ")") or ""))
    end
    local keys = {}
    for k in pairs(db.contexts) do keys[#keys + 1] = k end
    table.sort(keys)
    if #keys == 0 then print("  Nothing recorded yet.") end
    for _, key in ipairs(keys) do
        local c = db.contexts[key]
        print("|cFFFFD100" .. key .. "|r  (" .. (c.samples or 0) .. " samples, "
            .. Count(c.distinctNext) .. " different next spells)")
        for _, g in ipairs(GROUPS) do
            local bits = {}
            for _, kind in ipairs(KINDS) do
                local n = c[g[1] .. "." .. kind]
                if n then bits[#bits + 1] = kind .. "=" .. n end
            end
            if #bits > 0 then print("    " .. g[2] .. ": " .. table.concat(bits, "  ")) end
        end
    end
    for _, e in ipairs(db.errors) do print("|cFFFF5555  error|r " .. e) end
    print("  -- end of report --")
end

function Probe:Command(arg)
    local db = DB()
    if not db then
        print(addonName .. ": rotprobe: SavedVariables not loaded yet.")
        return
    end
    arg = (arg or ""):lower()
    local id = tonumber(arg:match("^add%s+(%d+)$") or "")
    local rid = tonumber(arg:match("^remove%s+(%d+)$") or "")
    if arg == "on" then
        db.on = true
        db.started = db.started or time()
        SetRunning(true)
        print("|cFF33CC99" .. addonName .. " rotprobe|r on (" .. #spells .. " spells). Play normally --"
            .. " open world, dungeon trash, a boss, a key -- then /reload and /sq rotprobe report.")
    elseif arg == "off" then
        db.on = false
        SetRunning(false)
        print(addonName .. ": rotprobe off. Counts kept; /sq rotprobe report.")
    elseif arg == "clear" then
        wipe(db.contexts)
        wipe(db.errors)
        db.started = nil
        print(addonName .. ": rotprobe counts cleared.")
    elseif id then
        table.insert(db.extras, id)
        RebuildSpellList()
        print(addonName .. ": rotprobe also probes spell " .. id .. ".")
    elseif rid then
        for i = #db.extras, 1, -1 do
            if db.extras[i] == rid then table.remove(db.extras, i) end
        end
        RebuildSpellList()
        print(addonName .. ": rotprobe no longer probes spell " .. rid .. ".")
    elseif arg == "report" then
        self:Report()
    else
        print(addonName .. ": /sq rotprobe on | off | report | clear | add <spellID> | remove <spellID>")
    end
end

-- Keep running across a /reload once switched on: a dungeon is rarely done in
-- one UI session, and asking for "/sq rotprobe on" again after every reload
-- is how a diagnostic misses the part that mattered.
local login = CreateFrame("Frame")
login:RegisterEvent("PLAYER_LOGIN")
login:SetScript("OnEvent", function()
    local db = DB()
    if db and db.on then SetRunning(true) end
end)
