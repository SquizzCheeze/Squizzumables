-- Core/Cursor.lua
-- Rings around the mouse cursor -- a centre dot, a plain ring, your global
-- cooldown and your cast filling round it -- and an optional trail, solid or
-- rainbow. Replaces the Ultimate Mouse Cursor addon for the user; none of its
-- code or art is reused (it ships no licence). The images are ours, generated
-- by .claude/make-cursor.ps1 into Media/Cursor.
--
-- WHY THE RINGS ARE COOLDOWN FRAMES FED DURATION OBJECTS
--
-- Your GCD and cast timings are numbers the game can hide from addons in
-- combat, and a Cooldown refuses hidden numbers (see "Secret aspects gate
-- cooldown setters" in CLAUDE.md). Duration OBJECTS are not secrets: the GCD
-- comes from C_Spell.GetSpellCooldownDuration -- exactly how the CDM proxies
-- draw every sweep -- and the cast from UnitCastingDuration /
-- UnitChannelDuration / UnitEmpoweredChannelDuration, which SquizzFrames' cast
-- bars use. The engine animates both; this file never reads a time.
--
-- The ring image is the cooldown's SWIPE texture, so the sweep is cut to the
-- ring's shape, and SetReverse(true) makes it fill as time passes rather than
-- empty.
--
-- COST
--
-- One OnUpdate, shown only while the feature is on: it moves one frame to the
-- cursor and, with the trail on, fades a fixed pool of textures. Nothing is
-- allocated per frame -- the pool is built once, colours come back as plain
-- returns -- so it adds no garbage for the collector (the AddonPulse readings
-- of 2026-10-02 are why that matters here).

local addonName, ns = ...
ns.BH = ns.BH or {}
local BH = ns.BH

-- Every name below needs its ".png": WoW only finds .blp/.tga without an
-- extension. Left off (V1.93's first build) nothing drew but the cooldown's
-- plain white square sweep.
local MEDIA = "Interface\\AddOns\\Squizzumables\\Media\\Cursor\\"
local GCD_SPELL = 61304          -- the global cooldown's own spell

-- Sizes at 100%, in UIParent units.
local RING_SIZE  = 56
local GCD_SIZE   = 40            -- inside the ring
local CAST_SIZE  = 74            -- outside it
local TRAIL_SIZE = 16            -- one particle, at its birth

local TRAIL_POOL = 120           -- particles; the oldest is reused past this
local TRAIL_MAX_PER_FRAME = 10   -- caps the fill-in on a very fast flick
local TRAIL_JUMP = 400           -- a move longer than this is a jump, not a stroke

local Cursor = {}
BH.Cursor = Cursor

local root, dot, ring, gcd, cast, castTrack
local trailFrame, driver
-- The trail: one texture per slot, and its state in parallel arrays (seconds
-- lived, lifespan -- 0 when idle -- and size at birth).
local pool, ages, lives, bases = {}, {}, {}, {}
local poolNext, active = 1, 0
local lastX, lastY
local casting = false

-- ============================================================================
-- Colour
-- ============================================================================

-- HSV with full saturation and value: hue 0..1 round the colour wheel.
local function Hue(h)
    h = (h % 1) * 6
    local i = math.floor(h)
    local f = h - i
    if i == 0 then return 1, f, 0
    elseif i == 1 then return 1 - f, 1, 0
    elseif i == 2 then return 0, 1, f
    elseif i == 3 then return 0, 1 - f, 1
    elseif i == 4 then return f, 0, 1
    end
    return 1, 0, 1 - f
end

local function ClassRGB()
    -- C_ClassColor rather than indexing RAID_CLASS_COLORS, as the CDM does: a
    -- function call is safe on a value that might be secret, a table key is not.
    local _, class = UnitClass("player")
    local c = class and C_ClassColor and C_ClassColor.GetClassColor and C_ClassColor.GetClassColor(class)
    if c then return c.r, c.g, c.b end
    return 1, 1, 1
end

-- The rainbow's position now. Speed 100% goes round the wheel every 4s.
local function RainbowHue()
    local s = BH.settings
    return GetTime() * 0.25 * ((s and s.cursorRainbowSpeed or 100) / 100)
end

-- `mode` "custom" | "class" | "rainbow"; `c` the custom colour table.
local function ModeRGB(mode, c, hueOffset)
    if mode == "class" then return ClassRGB() end
    if mode == "rainbow" then return Hue(RainbowHue() + (hueOffset or 0)) end
    c = c or {}
    return c.r or 1, c.g or 1, c.b or 1
end

-- The rings in one colour. Run once on a settings change and every frame
-- while that colour is the rainbow.
local function PaintRings(r, g, b)
    dot:SetVertexColor(r, g, b, 1)
    ring:SetVertexColor(r, g, b, 1)
    gcd:SetSwipeColor(r, g, b, 1)
    cast:SetSwipeColor(r, g, b, 1)
    castTrack:SetVertexColor(r, g, b, 0.25)
end

-- ============================================================================
-- Frames
-- ============================================================================

local function RingCooldown(size)
    local cd = CreateFrame("Cooldown", nil, root)
    cd:SetPoint("CENTER")
    cd:SetSize(size, size)
    cd:SetSwipeTexture(MEDIA .. "ring.png", 1, 1, 1, 1)
    cd:SetDrawSwipe(true)
    cd:SetDrawEdge(false)
    cd:SetDrawBling(false)
    cd:SetHideCountdownNumbers(true)
    cd:SetReverse(true)
    -- Other cooldown addons (OmniCC and the like) put countdown text on every
    -- Cooldown they find; this one is a ring, not a button.
    cd.noCooldownCount = true
    return cd
end

local function Build()
    if root then return end

    root = CreateFrame("Frame", "SquizzumablesCursor", UIParent)
    root:SetSize(1, 1)
    root:EnableMouse(false)
    root:Hide()

    ring = root:CreateTexture(nil, "ARTWORK")
    ring:SetTexture(MEDIA .. "ring.png")
    ring:SetPoint("CENTER")

    dot = root:CreateTexture(nil, "OVERLAY")
    dot:SetTexture(MEDIA .. "dot.png")
    dot:SetPoint("CENTER")

    gcd = RingCooldown(GCD_SIZE)

    castTrack = root:CreateTexture(nil, "BACKGROUND")
    castTrack:SetTexture(MEDIA .. "ring.png")
    castTrack:SetPoint("CENTER")
    castTrack:Hide()
    cast = RingCooldown(CAST_SIZE)

    -- The trail lives on its own frame so it can keep fading after the rings
    -- hide (leaving combat with Only In Combat on), and sits under them.
    trailFrame = CreateFrame("Frame", nil, UIParent)
    trailFrame:SetAllPoints(UIParent)
    trailFrame:EnableMouse(false)
    for i = 1, TRAIL_POOL do
        local t = trailFrame:CreateTexture(nil, "ARTWORK")
        t:SetTexture(MEDIA .. "soft.png")
        t:SetBlendMode("ADD")
        t:Hide()
        pool[i], ages[i], lives[i], bases[i] = t, 0, 0, 0
    end

    driver = CreateFrame("Frame")
    driver:Hide()
end

-- ============================================================================
-- Trail
-- ============================================================================

local function Spawn(x, y)
    local s = BH.settings
    local i = poolNext
    local t = pool[i]
    poolNext = i % TRAIL_POOL + 1
    if lives[i] == 0 then active = active + 1 end
    local base = TRAIL_SIZE * (s.cursorTrailSize or 100) / 100
    ages[i], lives[i], bases[i] = 0, s.cursorTrailLength or 0.5, base
    -- Each particle keeps the colour it was born with, so a rainbow runs
    -- along the trail instead of the whole trail changing at once.
    t:SetVertexColor(ModeRGB(s.cursorTrailColorMode, s.cursorTrailColor))
    t:ClearAllPoints()
    t:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x, y)
    t:SetSize(base, base)
    t:SetAlpha((s.cursorOpacity or 100) / 100)
    t:Show()
end

local function FadeTrail(elapsed)
    local opacity = (BH.settings.cursorOpacity or 100) / 100
    for i = 1, TRAIL_POOL do
        local life = lives[i]
        if life > 0 then
            local age = ages[i] + elapsed
            ages[i] = age
            local p = age / life
            local t = pool[i]
            if p >= 1 then
                lives[i] = 0
                active = active - 1
                t:Hide()
            else
                local size = bases[i] * (1 - 0.6 * p)
                t:SetSize(size, size)
                t:SetAlpha(opacity * (1 - p))
            end
        end
    end
end

-- Lay particles along the stroke since the last frame, spaced by size, so a
-- quick flick draws a line rather than a few separate dots.
local function StrokeTrail(x, y)
    local s = BH.settings
    if not lastX then lastX, lastY = x, y return end
    local dx, dy = x - lastX, y - lastY
    local dist = math.sqrt(dx * dx + dy * dy)
    if dist > TRAIL_JUMP then lastX, lastY = x, y return end
    local spacing = math.max(2, TRAIL_SIZE * (s.cursorTrailSize or 100) / 100 * 0.3)
    if dist < spacing then return end
    local n = math.min(math.floor(dist / spacing), TRAIL_MAX_PER_FRAME)
    for i = 1, n do
        Spawn(lastX + dx * i / n, lastY + dy * i / n)
    end
    lastX, lastY = x, y
end

local function ClearTrail()
    for i = 1, TRAIL_POOL do
        lives[i] = 0
        pool[i]:Hide()
    end
    active = 0
    lastX, lastY = nil, nil
end

-- ============================================================================
-- Rings
-- ============================================================================

local function UpdateGCD()
    if not (root and BH.settings.cursorGCD) then return end
    local dur = C_Spell.GetSpellCooldownDuration and C_Spell.GetSpellCooldownDuration(GCD_SPELL)
    gcd:SetCooldown(0, 0)
    if dur then gcd:SetCooldownFromDurationObject(dur) end
end

-- Same lookup order as SquizzFrames' cast bar (CastBar.lua): a cast, else a
-- channel, empowered or not. Only the NAME is tested, and only for nil, which
-- is safe on a secret string.
local function UpdateCast()
    if not root then return end
    local dur, _
    local name = UnitCastingInfo("player")
    if name then
        dur = UnitCastingDuration and UnitCastingDuration("player")
    else
        local isEmpowered
        name, _, _, _, _, _, _, _, isEmpowered = UnitChannelInfo("player")
        if name then
            if isEmpowered and UnitEmpoweredChannelDuration then
                dur = UnitEmpoweredChannelDuration("player")
            else
                dur = UnitChannelDuration and UnitChannelDuration("player")
            end
        end
    end
    -- A truth test, not `name ~= nil`: comparing a secret string throws.
    casting = (name and dur and BH.settings.cursorCast) and true or false
    cast:SetCooldown(0, 0)
    if casting then cast:SetCooldownFromDurationObject(dur) end
    cast:SetShown(casting)
    castTrack:SetShown(casting)
end

-- ============================================================================
-- Per frame
-- ============================================================================

local function ShouldShowRings()
    local s = BH.settings
    if s.cursorCombatOnly and not InCombatLockdown() then return false end
    -- The real cursor is hidden while you turn the camera with a mouse button
    -- held; rings left floating where it was would look like a bug.
    if IsMouselooking() then return false end
    return true
end

local function OnUpdate(_, elapsed)
    local s = BH.settings
    local show = ShouldShowRings()
    if show then
        local scale = UIParent:GetEffectiveScale()
        local cx, cy = GetCursorPosition()
        local x, y = cx / scale, cy / scale
        root:ClearAllPoints()
        root:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x, y)
        root:Show()
        if s.cursorColorMode == "rainbow" then PaintRings(Hue(RainbowHue())) end
        if s.cursorTrail then StrokeTrail(x, y) end
    else
        root:Hide()
        lastX, lastY = nil, nil
    end
    if active > 0 then FadeTrail(elapsed) end
end

-- ============================================================================
-- Settings
-- ============================================================================

--- Rebuild sizes, colours and visibility from settings. Called from the
--- options panel, at login and on every profile switch.
function BH:ApplyCursor()
    local s = self.settings
    if not s then return end
    if not s.cursorEnabled then
        if driver then driver:SetScript("OnUpdate", nil) driver:Hide() end
        if root then root:Hide() ClearTrail() end
        return
    end
    Build()

    local k = (s.cursorSize or 100) / 100
    ring:SetSize(RING_SIZE * k, RING_SIZE * k)
    ring:SetShown(s.cursorRing and true or false)
    local d = s.cursorDotSize or 8
    dot:SetSize(d * k, d * k)
    dot:SetShown(s.cursorDot and true or false)
    gcd:SetSize(GCD_SIZE * k, GCD_SIZE * k)
    gcd:SetShown(s.cursorGCD and true or false)
    cast:SetSize(CAST_SIZE * k, CAST_SIZE * k)
    castTrack:SetSize(CAST_SIZE * k, CAST_SIZE * k)

    local strata = s.cursorStrata or "HIGH"
    root:SetFrameStrata(strata)
    trailFrame:SetFrameStrata(strata)
    trailFrame:SetFrameLevel(math.max(0, root:GetFrameLevel() - 1))
    root:SetAlpha((s.cursorOpacity or 100) / 100)

    PaintRings(ModeRGB(s.cursorColorMode, s.cursorColor))
    if not s.cursorTrail then ClearTrail() end

    UpdateGCD()
    UpdateCast()
    driver:SetScript("OnUpdate", OnUpdate)
    driver:Show()
end

-- ============================================================================
-- Events
-- ============================================================================

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("SPELL_UPDATE_COOLDOWN")
for _, e in ipairs({
    "UNIT_SPELLCAST_START", "UNIT_SPELLCAST_STOP", "UNIT_SPELLCAST_FAILED",
    "UNIT_SPELLCAST_INTERRUPTED", "UNIT_SPELLCAST_DELAYED",
    "UNIT_SPELLCAST_CHANNEL_START", "UNIT_SPELLCAST_CHANNEL_STOP", "UNIT_SPELLCAST_CHANNEL_UPDATE",
    "UNIT_SPELLCAST_EMPOWER_START", "UNIT_SPELLCAST_EMPOWER_STOP", "UNIT_SPELLCAST_EMPOWER_UPDATE",
}) do
    ev:RegisterUnitEvent(e, "player")
end

ev:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        C_Timer.After(1, function() BH:ApplyCursor() end)
        return
    end
    local s = BH.settings
    if not (root and s and s.cursorEnabled) then return end
    if event == "SPELL_UPDATE_COOLDOWN" then
        UpdateGCD()
    else
        UpdateCast()
    end
end)

-- ============================================================================
-- Options page
-- ============================================================================

local COLOR_MODES = {
    { text = "Custom colour", value = "custom" },
    { text = "Class colour",  value = "class" },
    { text = "Rainbow",       value = "rainbow" },
}
local STRATAS = {
    { text = "Medium",  value = "MEDIUM" },
    { text = "High",    value = "HIGH" },
    { text = "Dialog",  value = "DIALOG" },
    { text = "Tooltip (above everything)", value = "TOOLTIP" },
}

function BH:BuildCursorTab(parent)
    local Rows = ns.Rows
    local pages = ns.SubTabs.Create(parent, {
        { key = "cursor", label = "Cursor" },
        { key = "rings",  label = "Rings" },
        { key = "trail",  label = "Trail" },
    })

    local function Set(key, v)
        BH.settings[key] = v
        BH:SaveSettings()
        BH:ApplyCursor()
    end
    local function Off() return not BH.settings.cursorEnabled end
    local function Check(label, key, tooltip, disabled)
        return { type = "check", label = label, tooltip = tooltip,
            get = function() return BH.settings[key] and true or false end,
            set = function(v) Set(key, v) end,
            disabled = disabled or Off }
    end
    local function Slider(label, key, min, max, step, default, tooltip, disabled)
        return { type = "slider", label = label, width = 300, min = min, max = max, step = step, tooltip = tooltip,
            get = function() return BH.settings[key] or default end,
            set = function(v) Set(key, v) end,
            disabled = disabled or Off }
    end
    local function Dropdown(label, key, items, default, tooltip, disabled)
        return { type = "dropdown", label = label, width = 200, items = items, tooltip = tooltip,
            get = function() return BH.settings[key] or default end,
            set = function(v) Set(key, v) end,
            disabled = disabled or Off }
    end
    local function Color(label, key, tooltip, disabled)
        return { type = "color", label = label, tooltip = tooltip,
            get = function()
                local c = BH.settings[key] or {}
                return c.r or 1, c.g or 1, c.b or 1
            end,
            set = function(r, g, b) Set(key, { r = r, g = g, b = b }) end,
            disabled = disabled }
    end

    -- Cursor
    local content = pages.cursor
    Rows.currentSection = content.section
    local y = -14
    y = y - Rows.Add(content, y, {
        type = "check", label = "Enable Mouse Cursor",
        tooltip = "Rings around your mouse cursor: a centre dot, a ring, your global cooldown and your cast "
            .. "filling round it, and an optional trail.",
        get = function() return BH.settings.cursorEnabled and true or false end,
        set = function(v) Set("cursorEnabled", v) end,
    })
    y = y - Rows.Add(content, y, Slider("Size", "cursorSize", 50, 200, 5, 100,
        "Size of everything around the cursor, as a percentage."))
    y = y - Rows.Add(content, y, Slider("Opacity", "cursorOpacity", 10, 100, 5, 100,
        "How see-through the rings and the trail are."))
    y = y - Rows.Add(content, y, Dropdown("Colour", "cursorColorMode", COLOR_MODES, "custom",
        "Colour of the dot and rings. Rainbow cycles through the colour wheel."))
    y = y - Rows.Add(content, y, Color("Custom Colour", "cursorColor", "Used when Colour is Custom colour.",
        function() return Off() or BH.settings.cursorColorMode ~= "custom" end))
    y = y - Rows.Add(content, y, Slider("Rainbow Speed", "cursorRainbowSpeed", 10, 400, 10, 100,
        "How fast Rainbow goes round the colour wheel, for the rings and the trail. At 100% once every 4 seconds.",
        function() return Off() or (BH.settings.cursorColorMode ~= "rainbow" and BH.settings.cursorTrailColorMode ~= "rainbow") end))
    y = y - Rows.Add(content, y, Check("Only In Combat", "cursorCombatOnly",
        "Show the rings only while you are in combat."))
    y = y - Rows.Add(content, y, Dropdown("Frame Strata", "cursorStrata", STRATAS, "HIGH",
        "How far in front of other frames the rings sit. Tooltip puts them above every window."))
    content:SetHeight(math.abs(y) + 20)

    -- Rings
    content = pages.rings
    Rows.currentSection = content.section
    y = -14
    y = y - Rows.Add(content, y, Check("Centre Dot", "cursorDot", "A dot at the cursor's tip."))
    y = y - Rows.Add(content, y, Slider("Dot Size", "cursorDotSize", 2, 30, 1, 8, "Size of the centre dot.",
        function() return Off() or not BH.settings.cursorDot end))
    y = y - Rows.Add(content, y, Check("Ring", "cursorRing", "A plain ring around the cursor."))
    y = y - Rows.Add(content, y, Check("Global Cooldown", "cursorGCD",
        "A ring inside the main one that fills as your global cooldown runs."))
    y = y - Rows.Add(content, y, Check("Cast", "cursorCast",
        "A ring outside the main one that fills as you cast or channel."))
    content:SetHeight(math.abs(y) + 20)

    -- Trail
    content = pages.trail
    Rows.currentSection = content.section
    y = -14
    local function TrailOff() return Off() or not BH.settings.cursorTrail end
    y = y - Rows.Add(content, y, Check("Show Trail", "cursorTrail",
        "A fading trail behind the cursor as it moves. Shown only while the rings are."))
    y = y - Rows.Add(content, y, Dropdown("Trail Colour", "cursorTrailColorMode", COLOR_MODES, "rainbow",
        "Rainbow runs through the colour wheel along the trail.", TrailOff))
    y = y - Rows.Add(content, y, Color("Custom Trail Colour", "cursorTrailColor", "Used when Trail Colour is Custom colour.",
        function() return TrailOff() or BH.settings.cursorTrailColorMode ~= "custom" end))
    y = y - Rows.Add(content, y, Slider("Trail Length", "cursorTrailLength", 0.1, 2, 0.1, 0.5,
        "How long, in seconds, the trail takes to fade.", TrailOff))
    y = y - Rows.Add(content, y, Slider("Trail Size", "cursorTrailSize", 25, 300, 5, 100,
        "Width of the trail, as a percentage.", TrailOff))
    content:SetHeight(math.abs(y) + 20)
end
