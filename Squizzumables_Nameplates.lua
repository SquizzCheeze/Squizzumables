-- Squizzumables_Nameplates.lua
-- A row of the enemy's dispellable buffs on their nameplate, glowing.
--
-- WHY IT IS BUILT THIS WAY
--
-- Whether a SPECIFIC aura can be purged is read from aura data, and enemy aura
-- data is secret in instanced content -- exactly where this matters. So nothing
-- here ever asks about one aura. The GROUP is the filter instead: the client
-- evaluates the filter string C-side (DISPELLABLE), so every button the group
-- shows is dispellable by construction, and the glow belongs to the group
-- rather than to any aura in it. This is EllesmereUI's nameplate approach, and
-- the reason theirs survives instanced PvP.
--
-- The same rule rules two things out, rather than them being oversights:
--   * a per-spell allow/block list -- spell-ID candidate filters are compared
--     in Lua against aura data, so they match nothing on enemies in instances
--   * splitting Magic from Enrage -- same problem, dispel type is aura data
--
-- CONTAINERS AND PLATES
--
-- Nameplates appear and vanish constantly, in combat, and a container can only
-- safely be created out of combat -- so they are pooled at login and attached
-- to plates as those come and go, which is how EllesmereUI does it too. The
-- host frame is never reparented: it stays a child of UIParent and is anchored
-- to the plate, so nothing of the client's aura machinery is moved between
-- frame trees.
--
-- PLATER AND OTHER NAMEPLATE ADDONS
--
-- Anchoring goes through whatever the plate actually has, in Plater's own
-- documented order (namePlate.unitFrame, then .healthBar). Blizzard's own plate
-- is the fallback. Nothing here writes to another addon's frames.

local addonName, ns = ...
ns.BH = ns.BH or {}
local BH = ns.BH

local NP = {}
BH.Nameplates = NP

local GROUP_KEY   = "sqpurge"
local REBUILD_WAIT = 0.5   -- settings debounce, so a slider drag rebuilds once

-- Offensive dispels, for "only when I can purge". Enrage removals included:
-- the DISPELLABLE filter counts helpful enrages on enemies.
local OFFENSIVE_DISPELS = {
    370,    -- Purge (shaman)
    30449,  -- Spellsteal (mage)
    528,    -- Dispel Magic (priest)
    32375,  -- Mass Dispel (priest)
    278326, -- Consume Magic (demon hunter)
    19801,  -- Tranquilizing Shot (hunter)
    2908,   -- Soothe (druid)
    5938,   -- Shiv (rogue)
}

-- [plate] = { host, container }, one set per nameplate, PARENTED INTO THE
-- PLATE and kept for the session.
--
-- Not a floating pool anchored to the plate, which is what 1.78 tried first
-- and why nothing rendered: a nameplate is a restricted region, anchoring into
-- one from outside gives our frame those restrictions, and the client's layout
-- then cannot place the icons -- the buttons existed and were simply never
-- positioned. `Frame:GetLeft(): Can't measure restricted regions` on our own
-- host was the tell. Plater parents its aura containers to the plate's
-- unitFrame and EllesmereUI parents its bundles into the plate, for the same
-- reason. Blizzard recycles a fixed set of plate frames, so this settles after
-- a few pulls.
local entries = {}

-- [plate] = unit token, tracked from the nameplate events themselves.
--
-- NOT read back off the plate: `plate.namePlateUnitToken` is empty on this
-- client (every plate reported "nil" in 1.78 testing), so the refresh pass
-- treated every plate as unitless and hid the row it had just attached --
-- rows existed, none were ever showing. The events carry the unit, so they are
-- the source of truth.
local plateUnits = {}
local built, rebuildTimer = false, nil
local lastError
-- Diagnostics only: how many attaches have been attempted, and why the last
-- plate was passed over. "Nothing on screen" has several causes that look
-- identical in game, and these are what tell them apart.
local attachCount, lastSkip = 0, nil
-- The /sq nameplates test row: one container on the screen rather than a plate.
local testRows, testWanted = {}, nil

-- ============================================================================
-- Capability and gating
-- ============================================================================

local function S()
    return BH.settings or {}
end

local function ContainersAvailable()
    return BH.cdm and BH.cdm.native and BH.cdm.native:IsAvailable() and true or false
end

-- Does this character have the spell?
--
-- Through C_SpellBook: IsPlayerSpell is deprecated. IsSpellKnownOrInSpellBook
-- is preferred over IsSpellKnown because it counts a spell replaced by an
-- override -- a talent that upgrades one of these would otherwise read as
-- not known at all.
local function HasSpell(id)
    local sb = C_SpellBook
    if not sb then return false end
    if sb.IsSpellKnownOrInSpellBook then
        return sb.IsSpellKnownOrInSpellBook(id) and true or false
    end
    if sb.IsSpellKnown then
        return sb.IsSpellKnown(id) and true or false
    end
    return false
end

local function CanPurge()
    for _, id in ipairs(OFFENSIVE_DISPELS) do
        if HasSpell(id) then return true end
    end
    return false
end

--- Should the row be showing at all right now?
function NP:Active()
    local s = S()
    if not s.npPurgeEnabled then return false end
    if not ContainersAvailable() then return false end
    if s.npPurgeOnlyWhenCapable ~= false and not CanPurge() then return false end
    if s.npPurgeCombatOnly and not InCombatLockdown() then return false end
    if s.npPurgeInstanceOnly and not IsInInstance() then return false end
    return true
end

-- ============================================================================
-- Filters
--
-- Built from AuraUtil.AuraFilters rather than written out, because the token
-- set moves between builds (NOT_CANCELABLE was removed in favour of a "!"
-- prefix) and IsValidFilterString rejects anything it does not know.
-- ============================================================================

--- The string is evaluated C-side (`C_UnitAuras.IsAuraFilteredOutByInstanceID`),
--- so it works on auras we could never read ourselves -- which is the whole
--- reason the narrowing lives here rather than in a candidate filter.
---
--- These three tokens are exactly EllesmereUI's `BuffFilterGlow`, which solves
--- this same problem on this client version. DISPELLABLE is the enemy-purge
--- token: "dispellable regardless of whether the player's raid can dispel
--- them", and its sibling RAID_PLAYER_DISPELLABLE's description names helpful
--- enrages on enemies, so enrages are in scope for it too.
local function FilterString()
    local F = (AuraUtil and AuraUtil.AuraFilters) or {}
    local parts = { F.Helpful or "HELPFUL", F.IncludeNameplateOnly or "INCLUDE_NAME_PLATE_ONLY" }
    if F.Dispellable then parts[#parts + 1] = F.Dispellable end
    return table.concat(parts, "|")
end

--- No candidate filter at all while the client has the DISPELLABLE token: the
--- filter string above has already narrowed C-side, and every candidate filter
--- reads a field the client REDACTS for an enemy's auras. This is
--- EllesmereUI's `BuffCand` exactly, stale-client fallback included, and its
--- comments record the same finding independently.
---
--- Everything tried on the candidate side matched nothing against a live
--- enemy: `isStealable` (means Spellstealable, so Magic-only),
--- `includeDispelTypes` with Magic, and the same with "Enrage". That last one
--- cannot work in any case -- an enrage carries NO `dispelName`, so an include
--- test rejects it and only an exclude test would keep it, which is why
--- EllesmereUI splits its row with `excludeDispelTypes = { Magic = true }`
--- rather than including an "Enrage" that does not exist.
---
--- The spellID filters are separately impossible here anyway:
--- `CanApplyIdentityCandidateFilters` drops `includeSpellIDs`/`excludeSpellIDs`
--- for a helpful aura on a unit we cannot assist.
local function Candidates()
    local F = (AuraUtil and AuraUtil.AuraFilters) or {}
    if F.Dispellable then return nil end
    return { isStealable = true }
end

-- ============================================================================
-- Button look
-- ============================================================================

local FONT = "Fonts\\FRIZQT__.TTF"

local function ShapeFiles(shape)
    local files = BH.cdm and BH.cdm.shared and BH.cdm.shared.SHAPE_FILE
    local fill = files and files[shape or "none"]
    if not fill then return nil, nil end
    return fill, (fill:gsub("%.png$", "_glow.png"))
end

-- Everything the initializer needs, snapshotted when a row is built: an aura
-- button may not be touched after it is created, so a settings change rebuilds
-- the rows rather than restyling them.
local function Snapshot()
    local s = S()
    local shape = s.npPurgeShape or "none"
    local fill, glowArt = ShapeFiles(shape)
    local gc = s.npPurgeGlowColor or {}
    local bc = s.npPurgeBorderColor or { 0, 0, 0, 0.9 }
    return {
        size       = s.npPurgeIconSize or 26,
        spacing    = s.npPurgeSpacing or 2,
        perRow     = s.npPurgePerRow or 3,
        maxIcons   = s.npPurgeMaxIcons or 3,
        zoom       = s.npPurgeZoom or 0.07,
        shapeFill  = fill,
        glowArt    = glowArt,
        border     = s.npPurgeBorder ~= false,
        borderColor = { bc[1] or 0, bc[2] or 0, bc[3] or 0, bc[4] or 0.9 },
        showDuration = s.npPurgeShowDuration ~= false,
        durationSize = s.npPurgeDurationSize or 12,
        showStacks = s.npPurgeShowStacks ~= false,
        stackSize  = s.npPurgeStackSize or 11,
        glow       = s.npPurgeGlow ~= false,
        glowStyle  = s.npPurgeGlowStyle or "halo",
        glowColor  = { gc.r or 1, gc.g or 0.82, gc.b or 0 },
        vertical   = (s.npPurgeAnchor == "LEFT" or s.npPurgeAnchor == "RIGHT"),
    }
end

-- Set when the initializer below fails, and printed by /sq nameplates.
--
-- Worth the plumbing: an error inside initializeFrame aborts the engine's
-- whole frame batch, and what is left behind is frames that exist but were
-- never given an icon, a size or a registration -- which on screen is
-- indistinguishable from "no aura matched".
local lastInitError

--- `probe` adds the diagnostic readout used by the test rows only.
local function MakeInitializer(style, probe)
    return function(button)
        local ok, err = pcall(function()
        -- Sized here, always: a group's layout options feed the engine's
        -- anchoring maths only, NOT the button's rendered size. A button left
        -- unsized is zero-sized and nothing appears, which is exactly how the
        -- Co-Tank tracker failed before it was removed in 1.75.
        button:SetSize(style.size, style.size)
        if button.SetMouseClickEnabled then button:SetMouseClickEnabled(false) end
        -- No tooltips on these: a mouse-enabled frame over a nameplate gets in
        -- the way of clicking the target underneath it.
        if button.SetMouseMotionEnabled then button:SetMouseMotionEnabled(false) end

        -- SetAllPoints with NO argument throughout: it anchors to the parent
        -- without naming it. The button is a forbidden object, and Plater's own
        -- nameplate aura buttons avoid pointing at it explicitly too (its
        -- commented-out attempts at exactly that are still in its source).
        local icon = button:CreateTexture(nil, "ARTWORK")
        icon:SetAllPoints()
        icon:SetTexCoord(style.zoom, 1 - style.zoom, style.zoom, 1 - style.zoom)

        if style.shapeFill then
            local mask = button:CreateMaskTexture()
            mask:SetAllPoints(icon)
            mask:SetTexture(style.shapeFill, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
            icon:AddMaskTexture(mask)
        end

        local cooldown = CreateFrame("Cooldown", nil, button, "CooldownFrameTemplate")
        cooldown:SetAllPoints()
        cooldown:SetDrawEdge(false)
        cooldown:SetDrawBling(false)
        cooldown:SetReverse(true)
        -- The engine drives this cooldown and draws no countdown of its own;
        -- the time is the duration text below.
        cooldown:SetHideCountdownNumbers(true)
        if cooldown.SetUseAuraDisplayTime then cooldown:SetUseAuraDisplayTime(true) end
        -- Colour passed explicitly: the swipe texture is tinted by it, and the
        -- widget takes the two together.
        if style.shapeFill then cooldown:SetSwipeTexture(style.shapeFill, 0, 0, 0, 0.8) end

        if style.border then
            local c = style.borderColor
            if style.shapeFill then
                local rim = button:CreateTexture(nil, "BACKGROUND", nil, -8)
                rim:SetTexture(style.shapeFill)
                rim:SetPoint("TOPLEFT", icon, "TOPLEFT", -1, 1)
                rim:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", 1, -1)
                rim:SetVertexColor(c[1], c[2], c[3], c[4])
            else
                local edge = CreateFrame("Frame", nil, button, "BackdropTemplate")
                edge:SetPoint("TOPLEFT", button, "TOPLEFT", -1, 1)
                edge:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", 1, -1)
                edge:SetBackdrop({ edgeFile = "Interface\\BUTTONS\\WHITE8X8", edgeSize = 1 })
                edge:SetBackdropBorderColor(c[1], c[2], c[3], c[4])
            end
        end

        -- Text carrier above the cooldown: a font string created on a Cooldown
        -- renders under its swipe.
        --
        -- No frame levels are set anywhere in here, and none are read. Reading
        -- one off a frame inside a forbidden button's subtree is refused, and
        -- an error in this function aborts the engine's whole frame batch --
        -- leaving icons that exist with nothing drawn on them. Creation order
        -- already stacks these correctly, which is why Plater sets none either.
        local textHost = CreateFrame("Frame", nil, button)
        textHost:SetAllPoints()

        local duration = textHost:CreateFontString(nil, "OVERLAY")
        duration:SetFont(FONT, style.durationSize, "OUTLINE")
        duration:SetPoint("CENTER", textHost, "CENTER", 0, 0)
        duration:SetAlpha(style.showDuration and 1 or 0)

        local stacks = textHost:CreateFontString(nil, "OVERLAY")
        stacks:SetFont(FONT, style.stackSize, "OUTLINE")
        stacks:SetPoint("BOTTOMRIGHT", textHost, "BOTTOMRIGHT", -1, 1)
        stacks:SetAlpha(style.showStacks and 1 or 0)

        -- Registration last, and each one guarded: an error inside any of them
        -- aborts the engine's whole frame batch, not just this button.
        pcall(button.SetIcon, button, icon)
        pcall(button.SetDurationCooldown, button, cooldown)
        if not pcall(button.SetApplicationCount, button, stacks, {}) then
            pcall(button.SetApplicationCount, button, stacks)
        end
        pcall(button.SetDurationText, button, duration, {})

        -- Test rows only. These two are filled in by the CLIENT from the aura
        -- it assigned, so they answer what we are not allowed to ask: the text
        -- prints the dispel type ("Magic", "Curse", "none"), and the border is
        -- registered to appear ONLY on a stealable aura. A stealable border
        -- here, on a buff that `candidateFilters.isStealable` refused to match,
        -- would mean the field is readable to the client and the candidate
        -- filter is being dropped rather than failing.
        --
        -- showWhenHelpful defaults to FALSE and every aura in this row is
        -- helpful, so both options must set it or nothing ever draws.
        if probe then
            local textureStyles = Enum and Enum.CustomAuraButtonDispelTypeTextureStyle
            local stealFilters = Enum and Enum.CustomAuraButtonDispelTypeStealableFilter

            -- Every key spelled out, including None, because the client writes
            -- an EMPTY STRING when an aura has no dispel type and no map is
            -- supplied (`ApplyDispelTypeText` -> `fontString:SetText("")`), and
            -- falls back to `AuraUtil.SetAuraSymbol` when it has one. Both can
            -- render as nothing, so a blank icon said nothing either way -- the
            -- first cut of this probe was unreadable for that reason.
            local dispelText = textHost:CreateFontString(nil, "OVERLAY")
            dispelText:SetFont(FONT, 11, "OUTLINE")
            dispelText:SetPoint("TOP", textHost, "TOP", 0, -1)
            if not pcall(button.SetDispelTypeText, button, dispelText, {
                showWhenHelpful = true,
                showWithoutDispelType = true,
                customDispelTextMap = {
                    Magic = "MAGIC", Curse = "CURSE", Disease = "DISEASE",
                    Poison = "POISON", Bleed = "BLEED", Enrage = "ENRAGE",
                    None = "NO TYPE",
                },
            }) then
                lastInitError = "SetDispelTypeText refused"
                dispelText:SetText("REFUSED")
            end

            if textureStyles and stealFilters then
                local stealMark = button:CreateTexture(nil, "OVERLAY")
                stealMark:SetAllPoints()
                pcall(button.AddDispelTypeTexture, button, stealMark, {
                    showWhenHelpful = true,
                    showWithoutDispelType = true,
                    style = textureStyles.Border,
                    stealableFilter = stealFilters.Stealable,
                })
            end
        end

        -- The glow belongs to the group: everything here is dispellable, so it
        -- rides the button's own visibility and never reads an aura.
        --
        -- Always the self-drawn glow (sqGlowSelfOnly). Blizzard's alert cannot
        -- be built inside an aura button's subtree -- the button carries secret
        -- aspects and the alert template's OnHide handler is refused there,
        -- logging "Cannot assign script handler for 'onhide'" once per button.
        -- Ours is textures plus an animation group, which is legal.
        if style.glow and ns.Glow then
            local glowHost = CreateFrame("Frame", nil, button)
            glowHost:SetAllPoints()
            glowHost.sqGlowColor = style.glowColor
            glowHost.sqGlowSelfOnly = true
            -- Halo needs this shape's art; "classic" (and a square icon, which
            -- has no halo art) uses Blizzard's alert texture, drawn by us.
            if style.glowStyle == "halo" and style.glowArt then
                ns.Glow.SetShape(glowHost, { halo = style.glowArt })
            end
            ns.Glow.Show(glowHost)
        end
        end)
        if not ok then lastInitError = tostring(err) end
    end
end

-- ============================================================================
-- Rows: one container per nameplate
-- ============================================================================

-- The frame our row lives inside: Plater's own unitFrame when Plater is
-- running, Blizzard's otherwise, and the bare plate as a last resort. Parented,
-- not anchored -- see the note on `entries`.
local function PlateHost(plate)
    return plate.unitFrame or plate.UnitFrame or plate
end

local function NewEntry(plate, style)
    local host = CreateFrame("Frame", nil, PlateHost(plate))
    host:SetSize(1, 1)
    host:Hide()

    local ok, container = pcall(CreateFrame, "AuraContainer", nil, host, "CustomAuraContainerTemplate")
    if not ok or not container or type(container.AddAuraGroup) ~= "function" then
        lastError = ok and "AuraContainer unavailable" or tostring(container)
        return nil
    end
    container:SetPoint("CENTER", host, "CENTER", 0, 0)
    container:SetSize(1, 1)

    -- Flow layout: one line per `perRow`, growing right and down for a
    -- horizontal row, down and right for a vertical column. The container
    -- resizes itself to its contents and is anchored by its centre, so the row
    -- stays centred on the plate as buffs come and go.
    local axis = AnchorUtil and AnchorUtil.FlowLayoutAxis
    if axis then
        pcall(container.SetFlowLayoutAxis, container,
            style.vertical and axis.Vertical or axis.Horizontal)
    end
    pcall(container.SetFlowLayoutAnchorPoint, container, "TOPLEFT")
    pcall(container.SetFlowLayoutGrowthDirection, container, 1, -1)
    local step = style.size + style.spacing
    pcall(container.SetFlowLayoutMaximumLineSize, container, math.max(1, style.perRow) * step)

    local added = pcall(container.AddAuraGroup, container, GROUP_KEY, FilterString(), {
        maxFrameCount = style.maxIcons,
        candidateFilters = Candidates(),
        initializeFrame = MakeInitializer(style),
        layout = {
            elementSpacing = style.spacing,
            lineSpacing    = style.spacing,
            elementWidth   = style.size,
            elementHeight  = style.size,
        },
    })
    if not added then
        lastError = "AddAuraGroup failed"
        pcall(container.Hide, container)
        return nil
    end

    return { host = host, container = container }
end

-- Switch every row off. The frames stay where they are -- they belong to their
-- plate now, and nothing can free them anyway.
local function HideAll()
    for _, entry in pairs(entries) do
        pcall(entry.container.SetEnabled, entry.container, false)
        entry.host:Hide()
    end
end

-- ============================================================================
-- Attaching to plates
-- ============================================================================

-- Plater's documented attach point first (its own comment names unitFrame and
-- healthBar), then Blizzard's, then the plate itself.
local function AnchorTarget(plate)
    local uf = plate.unitFrame
    if uf then return uf.healthBar or uf end
    local buf = plate.UnitFrame
    if buf then return buf.healthBar or buf end
    return plate
end

local ANCHORS = {
    TOP    = { "BOTTOM", "TOP" },
    BOTTOM = { "TOP", "BOTTOM" },
    LEFT   = { "RIGHT", "LEFT" },
    RIGHT  = { "LEFT", "RIGHT" },
}

local function PlaceHost(host, plate)
    local s = S()
    local a = ANCHORS[s.npPurgeAnchor or "TOP"] or ANCHORS.TOP
    host:ClearAllPoints()
    host:SetPoint(a[1], AnchorTarget(plate), a[2],
        s.npPurgeOffsetX or 0, s.npPurgeOffsetY or 4)
end

local function ShouldShowFor(unit)
    if not UnitExists(unit) then lastSkip = "unit does not exist"; return false end
    if UnitIsFriend("player", unit) then lastSkip = "friendly unit"; return false end
    if not UnitCanAttack("player", unit) then lastSkip = "cannot attack"; return false end
    if S().npPurgeTargetOnly and not UnitIsUnit(unit, "target") then
        lastSkip = "not the target (target-only is on)"
        return false
    end
    return true
end

local function Detach(plate)
    local entry = entries[plate]
    if not entry then return end
    pcall(entry.container.SetEnabled, entry.container, false)
    entry.host:Hide()
end

local function Attach(unit)
    local plate = C_NamePlate and C_NamePlate.GetNamePlateForUnit(unit)
    if not plate then
        lastSkip = "no nameplate frame for " .. tostring(unit)
        return
    end
    if not NP:Active() then
        lastSkip = "module not active"
        Detach(plate)
        return
    end
    if not ShouldShowFor(unit) then
        Detach(plate)
        return
    end
    local entry = entries[plate]
    if not entry then
        -- First sighting of this plate. Containers are not safely creatable
        -- mid-combat, so a plate first seen in a fight goes without until the
        -- fight ends; Blizzard recycles a fixed set of plates, so this stops
        -- happening after a few pulls.
        if InCombatLockdown() then
            lastSkip = "new plate first seen in combat"
            return
        end
        entry = NewEntry(plate, Snapshot())
        if not entry then
            lastSkip = "could not build a row for this plate"
            return
        end
        entries[plate] = entry
    end
    PlaceHost(entry.host, plate)
    entry.host:Show()

    -- One pcall per call, not one around all four: sharing one meant a refused
    -- SetUnit silently skipped the enable, the show and the refresh, and
    -- recorded nothing -- the row was simply absent with no explanation.
    local c = entry.container
    local function Try(what, fn, ...)
        local ok, err = pcall(fn, ...)
        if not ok then lastError = what .. ": " .. tostring(err) end
        return ok
    end
    Try("SetUnit", c.SetUnit, c, unit)
    Try("SetEnabled", c.SetEnabled, c, true)
    Try("Show", c.Show, c)
    Try("UpdateAllAuras", c.UpdateAllAuras, c)
    attachCount = attachCount + 1
end

--- Re-evaluate every visible plate. Used when a gate changes (combat, zone,
--- target, settings) rather than when one plate appears.
function NP:RefreshAll()
    for plate, unit in pairs(plateUnits) do
        if unit then Attach(unit) else Detach(plate) end
    end
end

-- ============================================================================
-- Build / rebuild
-- ============================================================================

--- Start the rows, or rebuild them after a settings change.
---
--- Rebuild rather than restyle: a button's look is fixed when it is created,
--- and it may not be touched afterwards. Out of combat only, and debounced,
--- because every rebuild strands the previous rows for the session -- WoW never
--- frees a frame, so a slider drag must not rebuild once per tick.
function NP:Rebuild()
    if InCombatLockdown() then return end
    HideAll()
    if not self:Active() then return end
    -- The old rows are switched off and forgotten rather than reused: their
    -- buttons were built to the previous settings and cannot be restyled.
    -- Each plate builds a fresh one the next time it is seen.
    wipe(entries)
    built = true
    self:RefreshAll()
end

--- Called from the options panel on any change.
function NP:ApplySettings()
    if rebuildTimer then rebuildTimer:Cancel() end
    rebuildTimer = C_Timer.NewTimer(REBUILD_WAIT, function()
        rebuildTimer = nil
        NP:Rebuild()
    end)
end

--- /sq nameplates test -- one row in the middle of the screen, bound to your
--- target, built exactly like the nameplate ones.
---
--- This separates the two things that look identical in game: "the filter
--- matched nothing" and "the icons were built but never drawn where I can see
--- them". Parented to UIParent, so none of the nameplate's restrictions apply
--- -- if icons appear here and not on a plate, the filter is right and the
--- problem is the plate.
---
--- Creating a container is not combat-legal, but the mob only gains the buff
--- once the fight is on -- so switching this on has to survive the wait. The
--- rows build themselves at the next lull and stay up, and the marker behind
--- each one means an empty row can be told apart from one never built.
---
--- Three rows rather than one, because each removes a different suspect and a
--- single pull answers all of them at once.
---
--- Rounds one and two tested the wrong thing. The buff in question is an
--- ENRAGE -- removed by Tranquilizing Shot or Soothe -- and an enrage is
--- neither stealable (that is Spellsteal, which is Magic-only) nor carries a
--- dispel type. So isStealable, DISPELLABLE and includeDispelTypes=Magic were
--- all matching nothing correctly. Round three goes after enrages:
---   all    the control, and the one that matters: its probe prints the dispel
---          type the client assigns, which tells us what an enrage even looks
---          like from here -- "Enrage", blank, or nothing at all.
---   enrage a candidate filter on an Enrage dispel type. Note the client's own
---          list (AuraUtil.DispellableDebuffTypes, and DEBUFF_DISPLAY_INFO)
---          runs Magic/Curse/Disease/Poison/Bleed/None with no Enrage in it,
---          so this is a guess that the field carries it anyway.
---   both   Magic or Enrage together: what the live filter would ship as, so a
---          hit here means the feature is done.
local TEST_VARIANTS = {
    { key = "all",       label = "HELPFUL (control -- prints dispel type)" },
    { key = "important", label = "+ IMPORTANT (curated enemy buffs)" },
    { key = "live",      label = "+ DISPELLABLE (what the plates use)" },
}

local function TestFilter(key)
    local F = (AuraUtil and AuraUtil.AuraFilters) or {}
    if key == "all" then return F.Helpful or "HELPFUL" end
    if key == "important" then
        return (F.Helpful or "HELPFUL") .. "|" .. (F.IncludeNameplateOnly or "INCLUDE_NAME_PLATE_ONLY")
            .. (F.Important and ("|" .. F.Important) or "")
    end
    return FilterString()
end

local function TestCandidates()
    return nil
end

local function BuildTestRow(def, index)
    local host = CreateFrame("Frame", nil, UIParent)
    host:SetSize(300, 40)
    host:SetPoint("CENTER", UIParent, "CENTER", 0, 210 - (index - 1) * 58)
    host:SetFrameStrata("HIGH")

    local bg = host:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 0.45)
    local label = host:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    label:SetPoint("BOTTOM", host, "TOP", 0, 2)
    label:SetText(def.key .. ":  " .. def.label)

    local ok, container = pcall(CreateFrame, "AuraContainer", nil, host, "CustomAuraContainerTemplate")
    if not ok or not container then
        print("|cff00ccffSquizzumables|r: test container failed: " .. tostring(container))
        return nil
    end
    container:SetPoint("CENTER", host, "CENTER", 0, 0)
    container:SetSize(1, 1)
    if not pcall(container.AddAuraGroup, container, GROUP_KEY, TestFilter(def.key), {
        maxFrameCount = 8,
        candidateFilters = TestCandidates(),
        initializeFrame = MakeInitializer(Snapshot(), true),
        layout = { elementSpacing = 2, elementWidth = 32, elementHeight = 32 },
    }) then
        print("|cff00ccffSquizzumables|r: test group '" .. def.key .. "' was refused.")
        return nil
    end

    pcall(container.SetUnit, container, "target")
    pcall(container.SetEnabled, container, true)
    return { host = host, container = container }
end

local function EnsureTestRows()
    if not testWanted then return true end
    if InCombatLockdown() or not ContainersAvailable() then return false end
    for index, def in ipairs(TEST_VARIANTS) do
        if not testRows[def.key] then
            testRows[def.key] = BuildTestRow(def, index)
        end
        local entry = testRows[def.key]
        if entry then entry.host:Show() end
    end
    return true
end

--- Rebinding is safe in combat; only the build is not.
local function BindTestRows()
    for _, entry in pairs(testRows) do
        pcall(entry.container.SetUnit, entry.container, "target")
        pcall(entry.container.UpdateAllAuras, entry.container)
    end
end

function NP:TestRow()
    testWanted = true
    if not EnsureTestRows() then
        print("|cff00ccffSquizzumables|r: test rows queued -- they build the moment you leave")
        print("  combat and stay up for the next pull. Nothing else to do.")
        return
    end
    BindTestRows()
    print("|cff00ccffSquizzumables|r: three test rows above the middle of your screen, each")
    print("  bound to your target. Pull, then read which boxes fill -- whichever of the")
    print("  lower two shows the purgeable buff is the filter the nameplates will use.")
    print("  /sq nameplates testoff to remove them.")
end

function NP:TestRowOff()
    testWanted = nil
    for _, entry in pairs(testRows) do
        pcall(entry.container.SetEnabled, entry.container, false)
        entry.host:Hide()
    end
    print("|cff00ccffSquizzumables|r: test rows hidden.")
end

-- /sq nameplates -- unlisted; see CLAUDE.md.
function NP:PrintDiagnostics()
    local s = S()
    local filter = FilterString()
    local shown = 0
    for _, entry in pairs(entries) do
        if entry.host:IsShown() then shown = shown + 1 end
    end
    print("|cff00ccffSquizzumables|r nameplate purge glow:")
    print(("  enabled: %s   active now: %s   containers available: %s")
        :format(tostring(s.npPurgeEnabled and true or false), tostring(self:Active()),
            tostring(ContainersAvailable())))
    -- Listed from the table rather than written out, so the two cannot drift.
    -- Nil is the NORMAL answer now (the filter string does the narrowing), so
    -- this has to survive it rather than index it.
    local names = {}
    for key, value in pairs(Candidates() or {}) do
        names[#names + 1] = key .. "=" .. tostring(value)
    end
    table.sort(names)
    if #names == 0 then names[1] = "none (filter string narrows C-side)" end
    print(("  can purge: %s   filter: %s   candidates: %s")
        :format(tostring(CanPurge()), filter, table.concat(names, ", ")))
    local rows = 0
    for _ in pairs(entries) do rows = rows + 1 end
    print(("  rows built: %d, showing: %d, built: %s   attach attempts: %d")
        :format(rows, shown, tostring(built), attachCount))
    print(("  last skip: %s   last error: %s")
        :format(lastSkip or "none", lastError or "none"))
    -- The one that matters when rows attach but nothing draws: an error while
    -- an icon was being built leaves frames with no icon and no registration.
    print(("  last icon-build error: %s"):format(lastInitError or "none"))

    -- What the plates themselves look like right now, and what we would anchor
    -- to on each. Under Plater that should name Plater's own health bar.
    --
    -- The group's frame count is the question that matters when everything
    -- above reads healthy: 0 means the client matched no aura for this unit
    -- (filter or unit), while frames that exist but are invisible or sized 0
    -- means the icons are being drawn somewhere we cannot see.
    local plates = (C_NamePlate and C_NamePlate.GetNamePlates()) or {}
    print(("  nameplates on screen: %d"):format(#plates))
    for i, plate in ipairs(plates) do
        if i > 4 then
            print("    (more not listed)")
            break
        end
        local unit = plateUnits[plate]
        local target = AnchorTarget(plate)
        local kind = (plate.unitFrame and "Plater/other unitFrame")
            or (plate.UnitFrame and "Blizzard UnitFrame")
            or "plate itself"
        local entry = entries[plate]
        print(("    [%s] %s   anchor: %s   row: %s")
            :format(tostring(unit), kind,
                tostring(target and target.GetName and target:GetName() or "unnamed frame"),
                entry and (entry.host:IsShown() and "showing" or "built, hidden") or "none"))

        if entry then
            local c = entry.container
            local okCount, count = pcall(c.GetAuraGroupFrameCount, c, GROUP_KEY)
            -- The container's size is the giveaway: the client grows it to fit
            -- whatever it laid out, so anything larger than 1x1 means icons
            -- were actually placed. Measured through pcall -- everything on a
            -- nameplate is a restricted region.
            local okSize, w, h = pcall(c.GetSize, c)
            print(("      container: visible %s   group frames: %s   size: %s")
                :format(tostring(c:IsVisible()), okCount and tostring(count) or "unreadable",
                    okSize and ("%.0fx%.0f"):format(w or 0, h or 0) or "restricted"))
            -- The buttons themselves are deliberately never touched here. An
            -- aura button is a FORBIDDEN object: calling anything on one from
            -- addon code errors outright ("Attempt to access forbidden object
            -- from code tainted by an AddOn"), which is what an earlier
            -- version of this diagnostic did to itself. The group's frame
            -- count above is a container call, and is all we may ask.
        end
    end
end

-- ============================================================================
-- Settings tab
-- ============================================================================

local ANCHOR_ITEMS = {
    { text = "Above the health bar",  value = "TOP" },
    { text = "Below the health bar",  value = "BOTTOM" },
    { text = "Left of the health bar", value = "LEFT" },
    { text = "Right of the health bar", value = "RIGHT" },
}

local GLOW_ITEMS = {
    { text = "Halo",    value = "halo" },
    { text = "Classic", value = "game" },
}

-- Same shapes the Cooldown Manager icons offer, drawn from the same art.
local SHAPE_ITEMS = {
    { text = "Square",  value = "none" },
    { text = "Round",   value = "round" },
    { text = "Diamond", value = "diamond" },
    { text = "Hexagon", value = "hexagon" },
    { text = "Shield",  value = "shield" },
    { text = "Heart",   value = "heart" },
    { text = "Star",    value = "star" },
}

-- Every row writes the setting, saves, and asks the module to rebuild. The
-- rebuild is debounced, so dragging a slider rebuilds once at the end.
local function Set(key, value)
    BH.settings[key] = value
    BH:SaveSettings()
    NP:ApplySettings()
end

local function Off()
    return not (BH.settings and BH.settings.npPurgeEnabled)
end

function BH:BuildNameplatesTab(parent)
    local pages = ns.SubTabs.Create(parent, {
        { key = "general",    label = "General" },
        { key = "appearance", label = "Appearance" },
    })

    local content = pages.general
    ns.Rows.currentSection = content.section
    local y = -14

    y = y - ns.Rows.Add(content, y, {
        type = "text",
        label = "Shows the buffs on an enemy's nameplate that can be dispelled or stolen, with a glow. "
             .. "The game decides what qualifies, so it keeps working in instances where addons cannot read enemy auras.",
    })

    y = y - ns.Rows.Add(content, y, {
        type = "check",
        label = "Enable Purge Glow",
        tooltip = "Show dispellable and stealable buffs on enemy nameplates.",
        get = function() return BH.settings.npPurgeEnabled and true or false end,
        set = function(v) Set("npPurgeEnabled", v) end,
    })

    y = y - ns.Rows.Add(content, y, {
        type = "check",
        label = "Only when I can purge",
        tooltip = "Only show the row on a character with an offensive dispel -- Purge, Spellsteal, Dispel Magic, "
               .. "Consume Magic, Tranquilizing Shot, Soothe or Shiv. Untick to show it on every character.",
        get = function() return BH.settings.npPurgeOnlyWhenCapable ~= false end,
        set = function(v) Set("npPurgeOnlyWhenCapable", v) end,
        disabled = Off,
    })

    y = y - ns.Rows.Add(content, y, {
        type = "check",
        label = "Target's nameplate only",
        tooltip = "Only show the row on your current target, instead of every enemy nameplate.",
        get = function() return BH.settings.npPurgeTargetOnly and true or false end,
        set = function(v) Set("npPurgeTargetOnly", v) end,
        disabled = Off,
    })

    y = y - ns.Rows.Add(content, y, {
        type = "check",
        label = "In combat only",
        get = function() return BH.settings.npPurgeCombatOnly and true or false end,
        set = function(v) Set("npPurgeCombatOnly", v) end,
        tooltip = "Hide the row outside combat.",
        disabled = Off,
    })

    y = y - ns.Rows.Add(content, y, {
        type = "check",
        label = "In instances only",
        tooltip = "Only show the row in a dungeon, raid, delve, scenario or battleground.",
        get = function() return BH.settings.npPurgeInstanceOnly and true or false end,
        set = function(v) Set("npPurgeInstanceOnly", v) end,
        disabled = Off,
    })

    y = y - ns.Rows.Add(content, y, { type = "divider" })
    y = y - ns.Rows.Add(content, y, { type = "header", label = "POSITION" })

    y = y - ns.Rows.Add(content, y, {
        type = "dropdown",
        label = "Anchor",
        tooltip = "Where the row sits relative to the nameplate's health bar. Works with Plater and other "
               .. "nameplate addons: it attaches to whichever health bar the plate actually has.",
        items = ANCHOR_ITEMS,
        get = function() return BH.settings.npPurgeAnchor or "TOP" end,
        set = function(v) Set("npPurgeAnchor", v) end,
        disabled = Off,
    })

    y = y - ns.Rows.Add(content, y, {
        type = "slider", label = "Horizontal Offset", min = -100, max = 100, step = 1,
        tooltip = "Nudge the row sideways.",
        get = function() return BH.settings.npPurgeOffsetX or 0 end,
        set = function(v) Set("npPurgeOffsetX", v) end,
        disabled = Off,
    })

    y = y - ns.Rows.Add(content, y, {
        type = "slider", label = "Vertical Offset", min = -100, max = 100, step = 1,
        tooltip = "Nudge the row up or down.",
        get = function() return BH.settings.npPurgeOffsetY or 4 end,
        set = function(v) Set("npPurgeOffsetY", v) end,
        disabled = Off,
    })

    content:SetHeight(math.abs(y) + 20)

    -- ===== Appearance =====
    content = pages.appearance
    ns.Rows.currentSection = content.section
    y = -14

    y = y - ns.Rows.Add(content, y, {
        type = "slider", label = "Max Icons", min = 1, max = 8, step = 1,
        tooltip = "How many dispellable buffs to show per nameplate.",
        get = function() return BH.settings.npPurgeMaxIcons or 3 end,
        set = function(v) Set("npPurgeMaxIcons", v) end,
        disabled = Off,
    })

    y = y - ns.Rows.Add(content, y, {
        type = "slider", label = "Icon Size", min = 12, max = 48, step = 1,
        get = function() return BH.settings.npPurgeIconSize or 26 end,
        set = function(v) Set("npPurgeIconSize", v) end,
        tooltip = "Width and height of each icon.",
        disabled = Off,
    })

    y = y - ns.Rows.Add(content, y, {
        type = "slider", label = "Spacing", min = 0, max = 12, step = 1,
        get = function() return BH.settings.npPurgeSpacing or 2 end,
        set = function(v) Set("npPurgeSpacing", v) end,
        tooltip = "Gap between icons.",
        disabled = Off,
    })

    y = y - ns.Rows.Add(content, y, {
        type = "slider", label = "Per Row", min = 1, max = 8, step = 1,
        get = function() return BH.settings.npPurgePerRow or 3 end,
        set = function(v) Set("npPurgePerRow", v) end,
        tooltip = "How many icons before wrapping to another line.",
        disabled = Off,
    })

    y = y - ns.Rows.Add(content, y, {
        type = "dropdown",
        label = "Icon Shape",
        tooltip = "Cuts each icon, its sweep and its border to a shape, using the same art as the Cooldown Manager icons.",
        items = SHAPE_ITEMS,
        get = function() return BH.settings.npPurgeShape or "none" end,
        set = function(v) Set("npPurgeShape", v) end,
        disabled = Off,
    })

    y = y - ns.Rows.Add(content, y, {
        type = "check",
        label = "Icon Border",
        get = function() return BH.settings.npPurgeBorder ~= false end,
        set = function(v) Set("npPurgeBorder", v) end,
        tooltip = "Draw a thin border around each icon.",
        disabled = Off,
    })

    y = y - ns.Rows.Add(content, y, {
        type = "color",
        label = "Border Colour",
        get = function()
            local c = BH.settings.npPurgeBorderColor or { 0, 0, 0, 0.9 }
            return c[1], c[2], c[3]
        end,
        set = function(r, g, b)
            local c = BH.settings.npPurgeBorderColor or {}
            Set("npPurgeBorderColor", { r, g, b, c[4] or 0.9 })
        end,
        disabled = Off,
    })

    y = y - ns.Rows.Add(content, y, { type = "divider" })
    y = y - ns.Rows.Add(content, y, { type = "header", label = "TEXT" })

    y = y - ns.Rows.Add(content, y, {
        type = "check",
        label = "Show Timer",
        tooltip = "Show the remaining time on each icon.",
        get = function() return BH.settings.npPurgeShowDuration ~= false end,
        set = function(v) Set("npPurgeShowDuration", v) end,
        disabled = Off,
    })

    y = y - ns.Rows.Add(content, y, {
        type = "slider", label = "Timer Size", min = 6, max = 24, step = 1,
        get = function() return BH.settings.npPurgeDurationSize or 12 end,
        set = function(v) Set("npPurgeDurationSize", v) end,
        disabled = Off,
    })

    y = y - ns.Rows.Add(content, y, {
        type = "check",
        label = "Show Stacks",
        tooltip = "Show the stack count on each icon.",
        get = function() return BH.settings.npPurgeShowStacks ~= false end,
        set = function(v) Set("npPurgeShowStacks", v) end,
        disabled = Off,
    })

    y = y - ns.Rows.Add(content, y, {
        type = "slider", label = "Stack Size", min = 6, max = 24, step = 1,
        get = function() return BH.settings.npPurgeStackSize or 11 end,
        set = function(v) Set("npPurgeStackSize", v) end,
        disabled = Off,
    })

    y = y - ns.Rows.Add(content, y, { type = "divider" })
    y = y - ns.Rows.Add(content, y, { type = "header", label = "GLOW" })

    y = y - ns.Rows.Add(content, y, {
        type = "check",
        label = "Glow the icons",
        tooltip = "Every icon in this row is dispellable, so the glow is on the row rather than on any one aura.",
        get = function() return BH.settings.npPurgeGlow ~= false end,
        set = function(v) Set("npPurgeGlow", v) end,
        disabled = Off,
    })

    y = y - ns.Rows.Add(content, y, {
        type = "dropdown",
        label = "Glow Style",
        tooltip = "Halo follows the icon's shape. Classic uses the game's older glow artwork. Both are drawn by "
               .. "this addon: the game's own animated action-button glow cannot be used on these icons. A square "
               .. "icon has no halo art, so it shows Classic either way.",
        items = GLOW_ITEMS,
        get = function() return BH.settings.npPurgeGlowStyle or "halo" end,
        set = function(v) Set("npPurgeGlowStyle", v) end,
        disabled = Off,
    })

    y = y - ns.Rows.Add(content, y, {
        type = "color",
        label = "Glow Colour",
        get = function()
            local c = BH.settings.npPurgeGlowColor or {}
            return c.r or 1, c.g or 0.82, c.b or 0
        end,
        set = function(r, g, b) Set("npPurgeGlowColor", { r = r, g = g, b = b }) end,
        disabled = Off,
    })

    content:SetHeight(math.abs(y) + 20)
    ns.Rows.currentSection = nil
end

-- ============================================================================
-- Events
-- ============================================================================

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("NAME_PLATE_UNIT_ADDED")
ev:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
ev:RegisterEvent("PLAYER_TARGET_CHANGED")
ev:RegisterEvent("PLAYER_REGEN_ENABLED")
ev:RegisterEvent("PLAYER_REGEN_DISABLED")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("SPELLS_CHANGED")

ev:SetScript("OnEvent", function(_, event, arg1)
    if event == "PLAYER_LOGIN" then
        -- After the client has settled, and never during a loading screen:
        -- this creates frames and loads Blizzard_AuraContainer.
        C_Timer.After(4, function() NP:Rebuild() end)

    elseif event == "NAME_PLATE_UNIT_ADDED" then
        local plate = C_NamePlate and C_NamePlate.GetNamePlateForUnit(arg1)
        if plate then plateUnits[plate] = arg1 end
        if built then Attach(arg1) end

    elseif event == "NAME_PLATE_UNIT_REMOVED" then
        local plate = C_NamePlate and C_NamePlate.GetNamePlateForUnit(arg1)
        if plate then
            plateUnits[plate] = nil
            Detach(plate)
        else
            -- The plate may already be gone by the time this arrives, so the
            -- unit is looked up the other way round.
            for p, u in pairs(plateUnits) do
                if u == arg1 then
                    plateUnits[p] = nil
                    Detach(p)
                end
            end
        end

    elseif event == "PLAYER_TARGET_CHANGED" then
        -- Only mode that cares, but cheap enough either way.
        if built and S().npPurgeTargetOnly then NP:RefreshAll() end
        BindTestRows()

    elseif event == "PLAYER_REGEN_ENABLED" or event == "PLAYER_REGEN_DISABLED" then
        if not built then
            if event == "PLAYER_REGEN_ENABLED" then NP:Rebuild() end
        elseif S().npPurgeCombatOnly then
            NP:RefreshAll()
        end
        if event == "PLAYER_REGEN_ENABLED" and testWanted then
            EnsureTestRows()
        end

    elseif event == "PLAYER_ENTERING_WORLD" then
        if built then NP:RefreshAll() end

    elseif event == "SPELLS_CHANGED" then
        -- Purge capability follows the spellbook, so a spec or talent change
        -- can switch the whole feature on or off.
        if built then NP:RefreshAll() end
    end
end)
