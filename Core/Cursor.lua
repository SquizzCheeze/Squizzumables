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

-- Particles; the oldest is reused past this. 300 covers a 3s linger at full
-- density on a fast mouse; the fade loop only runs while any are alive.
local TRAIL_POOL = 300

-- Trail looks: the image, and how it blends. A glow ADDs, so overlapping
-- particles brighten into a ribbon; dots and rings draw solid.
-- Sparkle is the glow image with motion: each piece drifts off, falls and
-- twinkles as it fades. Star/heart/diamond reuse the CDM icon-shape images
-- (UI/Shapes.lua, ours); the duck is ours too (make-cursor.ps1) and `faces`
-- the way the cursor travels. Custom takes any atlas name or file path the
-- player types (cursorTrailTexture), an idea from Frogski's Cursor Trail --
-- whose code is not reused (no licence).
local SHAPES = "Interface\\AddOns\\Squizzumables\\Media\\Shapes\\"
local TRAIL_STYLES = {
    glow    = { file = MEDIA .. "soft.png", blend = "ADD" },
    sparkle = { file = MEDIA .. "soft.png", blend = "ADD", moves = true },
    dot     = { file = MEDIA .. "dot.png",  blend = "BLEND" },
    ring    = { file = MEDIA .. "ring.png", blend = "BLEND" },
    star    = { file = SHAPES .. "star.png",    blend = "BLEND" },
    heart   = { file = SHAPES .. "heart.png",   blend = "BLEND" },
    diamond = { file = SHAPES .. "diamond.png", blend = "BLEND" },
    duck    = { file = MEDIA .. "duck.png", blend = "BLEND", faces = true },
    custom  = { custom = true, blend = "ADD" },
}

-- The trail's colour palette (Trail Colour = Palette): up to this many
-- colours, flowing over time or running head to tail along the trail.
local PALETTE_MAX = 6
local TRAIL_MAX_PER_FRAME = 20   -- caps the fill-in on a very fast flick
local TRAIL_JUMP = 400           -- a move longer than this is a jump, not a stroke

-- Moving particles (sparkle and the click burst), in UIParent units/second.
local GRAVITY = 70
local DRAG = 2.5                 -- fraction of speed lost per second
local SPARKLE_SPEED = 30
local BURST_COUNT = 14
local BURST_SPEED = 170
local BURST_LIFE = 0.6

-- Shake to find: this many quick left-right reversals, each stroke at least
-- SHAKE_STROKE long and within SHAKE_GAP of the last, starts the locator.
local SHAKE_REVERSALS = 4
local SHAKE_STROKE = 40
local SHAKE_GAP = 0.3
local SHAKE_COOLDOWN = 1.5
local LOCATOR_TIME = 0.6
local LOCATOR_FROM = 5           -- times the ring's size it starts at

local Cursor = {}
BH.Cursor = Cursor

local root, dot, ring, healthRing, locator, gcd, cast, castTrack
local trailFrame, driver
-- The trail: one texture per slot, and its state in parallel arrays: seconds
-- lived, lifespan (0 when idle), size at birth, position, velocity, twinkle.
local pool, ages, lives, bases = {}, {}, {}, {}
local pxs, pys, vxs, vys, twinkles = {}, {}, {}, {}, {}
local poolNext, active = 1, 0
local trailStyle                 -- the TRAIL_STYLES key the pool is drawn in
local trailLook                  -- style|texture|blend the pool was last drawn with
local facingLeft = false         -- the duck's facing, from the last stroke
local lastX, lastY
local casting = false
-- Set from PLAYER_REGEN_*, not InCombatLockdown(): that still reads false
-- inside PLAYER_REGEN_DISABLED itself, which is when the colour must change.
local inCombat = false
local shakeX, shakeDir, shakeCount, shakeLast, strokeLen, shakeReady = nil, 0, 0, 0, 0, 0
local locT                       -- seconds into the locator, nil when idle

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

-- The trail palette's colour at `f`. With `wrap` (flowing over time) f loops
-- 0..1 through every colour and back to the first; without (head to tail)
-- f=0 is the first colour and f=1 the last. Plain returns, no tables built.
local function PaletteRGB(f, wrap)
    local s = BH.settings
    local pal = s.cursorTrailPalette or {}
    local n = math.max(2, math.min(PALETTE_MAX, s.cursorTrailPaletteCount or 3))
    local x
    if wrap then x = (f % 1) * n else x = math.max(0, math.min(1, f)) * (n - 1) end
    local i = math.floor(x)
    local frac = x - i
    if not wrap and i >= n - 1 then i, frac = n - 2, 1 end
    local j = i + 2
    if j > n then j = 1 end
    local a, b = pal[i + 1] or {}, pal[j] or {}
    local ar, ag, ab = a.r or 1, a.g or 1, a.b or 1
    return ar + ((b.r or 1) - ar) * frac, ag + ((b.g or 1) - ag) * frac, ab + ((b.b or 1) - ab) * frac
end

-- Palette colours run head to tail along the trail (recoloured by age as each
-- piece fades) rather than flowing over time.
local function PaletteAlongTrail()
    local s = BH.settings
    return s.cursorTrailColorMode == "palette" and s.cursorTrailPaletteFlow == "trail"
end

-- `mode` "custom" | "class" | "rainbow" | "palette" (trail only); `c` the
-- custom colour table.
local function ModeRGB(mode, c, hueOffset)
    if mode == "class" then return ClassRGB() end
    if mode == "rainbow" then return Hue(RainbowHue() + (hueOffset or 0)) end
    if mode == "palette" then
        if PaletteAlongTrail() then return PaletteRGB(0, false) end
        return PaletteRGB(RainbowHue() + (hueOffset or 0), true)
    end
    c = c or {}
    return c.r or 1, c.g or 1, c.b or 1
end

-- The rings' colour mode and custom colour right now: the combat colour while
-- in combat, when that is on. Returns what ModeRGB takes.
local function RingColor()
    local s = BH.settings
    if s.cursorCombatColor and inCombat then
        return s.cursorCombatColorMode or "class", s.cursorCombatCustomColor
    end
    return s.cursorColorMode, s.cursorColor
end

-- The rings in one colour. Run once on a settings change and every frame
-- while that colour is the rainbow.
local function PaintRings(r, g, b)
    dot:SetVertexColor(r, g, b, 1)
    ring:SetVertexColor(r, g, b, 1)
    locator:SetVertexColor(r, g, b, 1)
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

    -- The health warning: the same ring drawn over the plain one, coloured
    -- AND faded by your health (UpdateHealth), so it works over any ring
    -- colour, rainbow included.
    healthRing = root:CreateTexture(nil, "ARTWORK", nil, 2)
    healthRing:SetTexture(MEDIA .. "ring.png")
    healthRing:SetPoint("CENTER")
    healthRing:Hide()

    dot = root:CreateTexture(nil, "OVERLAY")
    dot:SetTexture(MEDIA .. "dot.png")
    dot:SetPoint("CENTER")

    locator = root:CreateTexture(nil, "OVERLAY", nil, 1)
    locator:SetTexture(MEDIA .. "ring.png")
    locator:SetPoint("CENTER")
    locator:Hide()

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
        t:Hide()
        pool[i], ages[i], lives[i], bases[i] = t, 0, 0, 0
        pxs[i], pys[i], vxs[i], vys[i], twinkles[i] = 0, 0, 0, 0, false
    end

    driver = CreateFrame("Frame")
    driver:Hide()
end

-- ============================================================================
-- Trail
-- ============================================================================

-- One particle at x, y. `vx`/`vy` give it motion (0 for a still trail),
-- `twinkle` a flicker as it fades; `hueOffset` shifts a rainbow colour, which
-- is how a click burst spreads round the colour wheel.
local function Spawn(x, y, life, vx, vy, twinkle, hueOffset)
    local s = BH.settings
    local i = poolNext
    local t = pool[i]
    poolNext = i % TRAIL_POOL + 1
    if lives[i] == 0 then active = active + 1 end
    local base = TRAIL_SIZE * (s.cursorTrailSize or 100) / 100
    ages[i], lives[i], bases[i] = 0, life, base
    pxs[i], pys[i], vxs[i], vys[i], twinkles[i] = x, y, vx, vy, twinkle
    -- Each particle keeps the colour it was born with, so a rainbow runs
    -- along the trail instead of the whole trail changing at once.
    t:SetVertexColor(ModeRGB(s.cursorTrailColorMode, s.cursorTrailColor, hueOffset))
    -- A shape that faces the way it travels (the duck) is mirrored when the
    -- cursor last moved left. Only file textures get here; an atlas keeps the
    -- coords SetAtlas gave it.
    local style = TRAIL_STYLES[trailStyle]
    if style and style.faces then
        if facingLeft then t:SetTexCoord(1, 0, 0, 1) else t:SetTexCoord(0, 1, 0, 1) end
    end
    t:ClearAllPoints()
    t:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x, y)
    t:SetSize(base, base * (s.cursorTrailHeight or 100) / 100)
    t:SetAlpha((s.cursorOpacity or 100) / 100 * (s.cursorTrailOpacity or 100) / 100)
    t:Show()
end

local function FadeTrail(elapsed)
    local s = BH.settings
    local opacity = (s.cursorOpacity or 100) / 100 * (s.cursorTrailOpacity or 100) / 100
    local shrink = (s.cursorTrailShrink or 60) / 100
    local hRatio = (s.cursorTrailHeight or 100) / 100
    local alongTrail = PaletteAlongTrail()
    local drag = math.max(0, 1 - DRAG * elapsed)
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
                local vx, vy = vxs[i], vys[i]
                if vx ~= 0 or vy ~= 0 then
                    vx, vy = vx * drag, vy * drag - GRAVITY * elapsed
                    vxs[i], vys[i] = vx, vy
                    pxs[i], pys[i] = pxs[i] + vx * elapsed, pys[i] + vy * elapsed
                    t:ClearAllPoints()
                    t:SetPoint("CENTER", UIParent, "BOTTOMLEFT", pxs[i], pys[i])
                end
                local size = bases[i] * (1 - shrink * p)
                t:SetSize(size, size * hRatio)
                -- Palette along the trail: a piece's age is how far back down
                -- the trail it is, so the head wears the first colour and the
                -- tail the last.
                if alongTrail then t:SetVertexColor(PaletteRGB(p, false)) end
                local a = opacity * (1 - p)
                if twinkles[i] then a = a * (0.55 + 0.45 * math.sin(age * 25 + i)) end
                t:SetAlpha(a)
            end
        end
    end
end

-- A ring of particles flying out from x, y on a click.
local function Burst(x, y)
    for n = 1, BURST_COUNT do
        local angle = (n / BURST_COUNT + math.random() * 0.05) * 2 * math.pi
        local speed = BURST_SPEED * (0.75 + math.random() * 0.5)
        Spawn(x, y, BURST_LIFE, math.cos(angle) * speed, math.sin(angle) * speed, true, n / BURST_COUNT)
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
    -- Density 100% puts particles 30% of their width apart; double it halves
    -- the gap.
    local spacing = math.max(1, TRAIL_SIZE * (s.cursorTrailSize or 100) / 100 * 0.3
        * 100 / (s.cursorTrailDensity or 100))
    if dist < spacing then return end
    local n = math.min(math.floor(dist / spacing), TRAIL_MAX_PER_FRAME)
    local life = s.cursorTrailLength or 0.5
    local moves = TRAIL_STYLES[trailStyle] and TRAIL_STYLES[trailStyle].moves
    -- Facing follows horizontal travel; a purely vertical move keeps it.
    if dx < -0.5 then facingLeft = true elseif dx > 0.5 then facingLeft = false end
    -- Laid down offset from the cursor (Trail Offset X/Y); the stroke itself
    -- is still measured from the cursor.
    local ox, oy = s.cursorTrailOffsetX or 0, s.cursorTrailOffsetY or 0
    for i = 1, n do
        local vx, vy = 0, 0
        if moves then
            -- Off in a random direction, a little upward so it arcs as it falls.
            local angle = math.random() * 2 * math.pi
            local speed = SPARKLE_SPEED * (0.5 + math.random())
            vx, vy = math.cos(angle) * speed, math.sin(angle) * speed + SPARKLE_SPEED * 0.6
        end
        Spawn(lastX + dx * i / n + ox, lastY + dy * i / n + oy, life, vx, vy, moves and true or false)
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
-- Health warning
--
-- Your health is secret in combat, so it is never read. A colour curve goes
-- INTO UnitHealthPercent and the engine evaluates it, returning a (secret)
-- colour that SetVertexColor accepts -- the route SquizzFrames' health
-- gradient proved in combat (memory: secret-safe value-driven colour).
-- Curve:Evaluate itself is AllowedWhenUntainted and cannot be used.
--
-- The curve drives ALPHA as well as colour: clear above the threshold,
-- fading in amber below it, red near death.
-- ============================================================================

local healthCurve, healthCurveAt

-- Called through pcall, so even the method lookup on a colour that may be
-- secret happens where an error is caught.
---@return number r, number g, number b, number a
local function UnpackColor(c) return c:GetRGBA() end

local function HealthCurve(start)
    if healthCurve and healthCurveAt == start then return healthCurve end
    if not (C_CurveUtil and C_CurveUtil.CreateColorCurve and CreateColor) then return nil end
    local ok, curve = pcall(C_CurveUtil.CreateColorCurve)
    if not ok or not curve then return nil end
    if curve.SetType and Enum.LuaCurveType then pcall(curve.SetType, curve, Enum.LuaCurveType.Linear) end
    local added = pcall(function()
        curve:AddPoint(0.0, CreateColor(1, 0.12, 0.12, 1))
        curve:AddPoint(start * 0.35, CreateColor(1, 0.12, 0.12, 1))
        curve:AddPoint(start * 0.7, CreateColor(1, 0.6, 0, 1))
        curve:AddPoint(start, CreateColor(1, 0.6, 0, 0))
        if start < 0.99 then curve:AddPoint(1.0, CreateColor(1, 0.6, 0, 0)) end
    end)
    if not added then return nil end
    healthCurve, healthCurveAt = curve, start
    return curve
end

-- On UNIT_HEALTH / UNIT_MAXHEALTH, never per frame.
local function UpdateHealth()
    if not healthRing then return end
    local s = BH.settings
    if not (s.cursorHealthColor and s.cursorRing and UnitHealthPercent) then healthRing:Hide() return end
    local curve = HealthCurve((s.cursorHealthStart or 70) / 100)
    local ok, col = false, nil
    if curve then ok, col = pcall(UnitHealthPercent, "player", true, curve) end
    -- GetRGBA reads fields off what may be a secret, so it is tried, not
    -- assumed; any failure just leaves the warning off.
    local okRGB, r, g, b, a = false, nil, nil, nil, nil
    if ok and col then okRGB, r, g, b, a = pcall(UnpackColor, col) end
    if okRGB and pcall(healthRing.SetVertexColor, healthRing, r, g, b, a) then
        healthRing:Show()
    else
        healthRing:Hide()
    end
end

-- ============================================================================
-- Shake to find
-- ============================================================================

-- Fed the cursor's x every frame it moves. Counts left-right reversals of a
-- long enough stroke in quick succession; ordinary mousing never gets four.
local function DetectShake(x, now)
    if not shakeX then shakeX = x return end
    local dx = x - shakeX
    shakeX = x
    if dx > -1 and dx < 1 then return end
    local dir = dx > 0 and 1 or -1
    if dir == shakeDir then
        strokeLen = strokeLen + math.abs(dx)
        return
    end
    local longEnough = strokeLen >= SHAKE_STROKE
    if longEnough and now - shakeLast <= SHAKE_GAP then
        shakeCount = shakeCount + 1
    else
        shakeCount = longEnough and 1 or 0
    end
    shakeLast, shakeDir, strokeLen = now, dir, math.abs(dx)
    if shakeCount >= SHAKE_REVERSALS and now >= shakeReady then
        shakeCount, shakeReady, locT = 0, now + SHAKE_COOLDOWN, 0
    end
end

-- A big ring shrinking onto the cursor.
local function AnimateLocator(elapsed)
    locT = locT + elapsed
    local p = locT / LOCATOR_TIME
    if p >= 1 then
        locT = nil
        locator:Hide()
        return
    end
    local base = RING_SIZE * (BH.settings.cursorSize or 100) / 100
    local size = base * (1 + (LOCATOR_FROM - 1) * (1 - p) * (1 - p))
    locator:SetSize(size, size)
    locator:SetAlpha(1 - p * p)
    locator:Show()
end

-- ============================================================================
-- Per frame
-- ============================================================================

local function ShouldShowRings()
    local s = BH.settings
    if s.cursorCombatOnly and not InCombatLockdown() then return false end
    -- The real cursor is hidden while you turn the camera with a mouse button
    -- held, and frozen where it was. The rings stay there by default (user
    -- request: they should not vanish on right-click); hiding them is opt-in.
    if s.cursorHideMouselook and IsMouselooking() then return false end
    return true
end

local function OnUpdate(_, elapsed)
    local s = BH.settings
    local show = ShouldShowRings()
    if show then
        if IsMouselooking() then
            -- Turning the camera: hold the rings where the cursor was rather
            -- than trust GetCursorPosition while the cursor is hidden, and lay
            -- no trail.
            lastX, lastY, shakeX = nil, nil, nil
        else
            local scale = UIParent:GetEffectiveScale()
            local cx, cy = GetCursorPosition()
            local x, y = cx / scale, cy / scale
            root:ClearAllPoints()
            root:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x, y)
            if s.cursorTrail then StrokeTrail(x, y) end
            if s.cursorShakeFind then DetectShake(x, GetTime()) end
        end
        root:Show()
        if RingColor() == "rainbow" then PaintRings(Hue(RainbowHue())) end
        if locT then AnimateLocator(elapsed) end
    else
        root:Hide()
        lastX, lastY, shakeX, locT = nil, nil, nil, nil
        locator:Hide()
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
    healthRing:SetSize(RING_SIZE * k, RING_SIZE * k)
    inCombat = InCombatLockdown() and true or false
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

    PaintRings(ModeRGB(RingColor()))
    UpdateHealth()
    if not (s.cursorTrail or s.cursorClickBurst) then ClearTrail() end
    -- The pool is redrawn only when its look changes: style, the custom
    -- texture's name, or the blending.
    local styleKey = TRAIL_STYLES[s.cursorTrailStyle] and s.cursorTrailStyle or "glow"
    local style = TRAIL_STYLES[styleKey]
    local blend = (s.cursorTrailBlend == "glow" and "ADD")
        or (s.cursorTrailBlend == "solid" and "BLEND") or style.blend
    local custom = style.custom and strtrim(s.cursorTrailTexture or "") or ""
    local look = styleKey .. "|" .. custom .. "|" .. blend
    if look ~= trailLook then
        -- A custom name is tried as an atlas first, then as a file path;
        -- empty falls back to the soft glow so the trail never vanishes.
        local atlas = custom ~= "" and C_Texture and C_Texture.GetAtlasInfo
            and C_Texture.GetAtlasInfo(custom) and custom or nil
        local file = (not style.custom and style.file)
            or (custom ~= "" and custom) or (MEDIA .. "soft.png")
        for i = 1, TRAIL_POOL do
            local t = pool[i]
            if atlas then
                t:SetAtlas(atlas)
            else
                t:SetTexture(file)
                t:SetTexCoord(0, 1, 0, 1)
            end
            t:SetBlendMode(blend)
        end
        trailStyle, trailLook = styleKey, look
    end

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
ev:RegisterUnitEvent("UNIT_HEALTH", "player")
ev:RegisterUnitEvent("UNIT_MAXHEALTH", "player")
ev:RegisterEvent("PLAYER_REGEN_DISABLED")
ev:RegisterEvent("PLAYER_REGEN_ENABLED")
ev:RegisterEvent("GLOBAL_MOUSE_DOWN")

ev:SetScript("OnEvent", function(_, event, arg1)
    if event == "PLAYER_LOGIN" then
        C_Timer.After(1, function() BH:ApplyCursor() end)
        return
    end
    local s = BH.settings
    if not (root and s and s.cursorEnabled) then return end
    if event == "SPELL_UPDATE_COOLDOWN" then
        UpdateGCD()
    elseif event == "UNIT_HEALTH" or event == "UNIT_MAXHEALTH" then
        UpdateHealth()
    elseif event == "PLAYER_REGEN_DISABLED" or event == "PLAYER_REGEN_ENABLED" then
        inCombat = (event == "PLAYER_REGEN_DISABLED")
        PaintRings(ModeRGB(RingColor()))
    elseif event == "GLOBAL_MOUSE_DOWN" then
        -- Left button only: right-click also turns the camera, and a burst on
        -- every camera turn would be noise.
        if arg1 == "LeftButton" and s.cursorClickBurst and root:IsShown() and not IsMouselooking() then
            local scale = UIParent:GetEffectiveScale()
            local cx, cy = GetCursorPosition()
            Burst(cx / scale, cy / scale)
        end
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
-- The trail also offers Palette (several colours of your own).
local TRAIL_COLOR_MODES = {
    { text = "Custom colour", value = "custom" },
    { text = "Class colour",  value = "class" },
    { text = "Rainbow",       value = "rainbow" },
    { text = "Palette",       value = "palette" },
}
local PALETTE_FLOWS = {
    { text = "Flows over time",           value = "time" },
    { text = "Along the trail, head to tail", value = "trail" },
}
local TRAIL_STYLE_ITEMS = {
    { text = "Soft glow",   value = "glow" },
    { text = "Sparkle",     value = "sparkle" },
    { text = "Solid dots",  value = "dot" },
    { text = "Rings",       value = "ring" },
    { text = "Stars",       value = "star" },
    { text = "Hearts",      value = "heart" },
    { text = "Diamonds",    value = "diamond" },
    { text = "Ducks",       value = "duck" },
    { text = "Your own texture", value = "custom" },
}
local TRAIL_BLENDS = {
    { text = "The style's own", value = "style" },
    { text = "Glow (bright, adds up)", value = "glow" },
    { text = "Solid",           value = "solid" },
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
        { key = "trailcolour", label = "Trail Colour" },
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
    y = y - Rows.Add(content, y, Check("Different Colour In Combat", "cursorCombatColor",
        "Switch the rings to a second colour while you are in combat."))
    local function CombatOff() return Off() or not BH.settings.cursorCombatColor end
    y = y - Rows.Add(content, y, Dropdown("Combat Colour", "cursorCombatColorMode", COLOR_MODES, "class",
        "The rings' colour while you are in combat.", CombatOff))
    y = y - Rows.Add(content, y, Color("Custom Combat Colour", "cursorCombatCustomColor",
        "Used when Combat Colour is Custom colour.",
        function() return CombatOff() or BH.settings.cursorCombatColorMode ~= "custom" end))
    y = y - Rows.Add(content, y, Slider("Rainbow Speed", "cursorRainbowSpeed", 10, 400, 10, 100,
        "How fast Rainbow goes round the colour wheel, wherever it is used. At 100% once every 4 seconds."))
    y = y - Rows.Add(content, y, Check("Only In Combat", "cursorCombatOnly",
        "Show the rings only while you are in combat."))
    y = y - Rows.Add(content, y, Check("Shake To Find Cursor", "cursorShakeFind",
        "Shake the mouse quickly left and right and a big ring shrinks onto the cursor, to find it in a busy fight."))
    y = y - Rows.Add(content, y, Check("Hide While Turning The Camera", "cursorHideMouselook",
        "Hide the rings while you hold a mouse button to turn the camera. Off, they stay where the "
            .. "cursor was, which is where it comes back when you let go."))
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
    y = y - Rows.Add(content, y, Check("Ring Warns On Low Health", "cursorHealthColor",
        "The ring turns amber and then red as your health drops, over whatever colour it already is. "
            .. "Works in combat.",
        function() return Off() or not BH.settings.cursorRing end))
    y = y - Rows.Add(content, y, Slider("Warn Below (% health)", "cursorHealthStart", 20, 100, 5, 70,
        "The health at which the warning starts to show. It is fully amber a little below this and red near death.",
        function() return Off() or not (BH.settings.cursorRing and BH.settings.cursorHealthColor) end))
    y = y - Rows.Add(content, y, Check("Global Cooldown", "cursorGCD",
        "A ring inside the main one that fills as your global cooldown runs."))
    y = y - Rows.Add(content, y, Check("Cast", "cursorCast",
        "A ring outside the main one that fills as you cast or channel."))
    content:SetHeight(math.abs(y) + 20)

    -- Trail
    content = pages.trail
    Rows.currentSection = content.section
    y = -14
    -- The click burst is drawn from the trail's particles, so the look below
    -- (colour, style, opacity, shrink, size) applies to both; only Linger
    -- Time and Density are the trail's alone.
    local function TrailOff() return Off() or not BH.settings.cursorTrail end
    local function ParticlesOff() return Off() or not (BH.settings.cursorTrail or BH.settings.cursorClickBurst) end
    y = y - Rows.Add(content, y, Check("Show Trail", "cursorTrail",
        "A fading trail behind the cursor as it moves. Shown only while the rings are."))
    y = y - Rows.Add(content, y, Check("Click Burst", "cursorClickBurst",
        "A burst of particles flies out from the cursor when you left-click. It uses the look set below; "
            .. "with a rainbow colour it spreads round the colour wheel. Works with the trail off."))
    y = y - Rows.Add(content, y, Dropdown("Trail Style", "cursorTrailStyle", TRAIL_STYLE_ITEMS, "glow",
        "Soft glow blends into a bright ribbon; sparkle drifts, falls and twinkles like sparks; dots, rings, "
            .. "stars, hearts and diamonds draw each piece on its own; ducks face the way you move the mouse. "
            .. "Your own texture uses the name typed below.", ParticlesOff))
    y = y - Rows.Add(content, y, {
        type = "editbox", label = "Your Own Texture (atlas name or file path)", width = 300,
        tooltip = "Any of the game's atlas names, for example \"titleprestige-starglow\" or "
            .. "\"bags-glow-flash\", or a texture file path. Press Enter to apply. Used when Trail Style is "
            .. "Your own texture; an empty box falls back to the soft glow.",
        get = function() return BH.settings.cursorTrailTexture or "" end,
        set = function(v) Set("cursorTrailTexture", strtrim(v or "")) end,
        disabled = function() return ParticlesOff() or BH.settings.cursorTrailStyle ~= "custom" end,
    })
    y = y - Rows.Add(content, y, Dropdown("Blending", "cursorTrailBlend", TRAIL_BLENDS, "style",
        "Glow adds the pieces' light together, so overlaps go bright; solid draws them as they are. "
            .. "By default each style uses whichever suits it.", ParticlesOff))
    y = y - Rows.Add(content, y, Slider("Linger Time", "cursorTrailLength", 0.1, 3, 0.1, 0.5,
        "How long, in seconds, the trail lingers before it has faded away.", TrailOff))
    y = y - Rows.Add(content, y, Slider("Trail Opacity", "cursorTrailOpacity", 10, 100, 5, 100,
        "How see-through the trail is, on top of the overall Opacity on the Cursor tab.", ParticlesOff))
    y = y - Rows.Add(content, y, Slider("Shrink As It Fades", "cursorTrailShrink", 0, 100, 5, 60,
        "How much each piece shrinks as it fades. 0% keeps it full size to the end; 100% shrinks it to nothing.",
        ParticlesOff))
    y = y - Rows.Add(content, y, Slider("Density", "cursorTrailDensity", 25, 400, 25, 100,
        "How close together the pieces are. Low makes a dotted line, high a smooth ribbon.", TrailOff))
    y = y - Rows.Add(content, y, Slider("Trail Size", "cursorTrailSize", 25, 300, 5, 100,
        "Width of each piece, as a percentage.", ParticlesOff))
    y = y - Rows.Add(content, y, Slider("Trail Height", "cursorTrailHeight", 25, 400, 5, 100,
        "Height of each piece as a percentage of its width. 100% keeps it in proportion; other values "
            .. "stretch or squash it.", ParticlesOff))
    y = y - Rows.Add(content, y, Slider("Trail Offset X", "cursorTrailOffsetX", -60, 60, 1, 0,
        "Moves the trail left or right of the cursor.", TrailOff))
    y = y - Rows.Add(content, y, Slider("Trail Offset Y", "cursorTrailOffsetY", -60, 60, 1, 0,
        "Moves the trail above or below the cursor.", TrailOff))
    content:SetHeight(math.abs(y) + 20)

    -- Trail colour
    content = pages.trailcolour
    Rows.currentSection = content.section
    y = -14
    y = y - Rows.Add(content, y, Dropdown("Trail Colour", "cursorTrailColorMode", TRAIL_COLOR_MODES, "rainbow",
        "Rainbow runs through the colour wheel along the trail. Palette uses colours you choose below.",
        ParticlesOff))
    y = y - Rows.Add(content, y, Color("Custom Trail Colour", "cursorTrailColor", "Used when Trail Colour is Custom colour.",
        function() return ParticlesOff() or BH.settings.cursorTrailColorMode ~= "custom" end))
    local function PaletteOff() return ParticlesOff() or BH.settings.cursorTrailColorMode ~= "palette" end
    y = y - Rows.Add(content, y, Dropdown("Palette Flow", "cursorTrailPaletteFlow", PALETTE_FLOWS, "time",
        "Flows over time: the trail cycles through your colours, at the Rainbow Speed on the Cursor tab. "
            .. "Along the trail: the head of the trail is your first colour and the tail your last.",
        PaletteOff))
    y = y - Rows.Add(content, y, Slider("Palette Colours Used", "cursorTrailPaletteCount", 2, PALETTE_MAX, 1, 3,
        "How many of the colours below the palette uses, from the first.", PaletteOff))
    for i = 1, PALETTE_MAX do
        y = y - Rows.Add(content, y, {
            type = "color", label = "Palette Colour " .. i,
            tooltip = "Colour " .. i .. " of the trail palette.",
            get = function()
                local c = (BH.settings.cursorTrailPalette or {})[i] or {}
                return c.r or 1, c.g or 1, c.b or 1
            end,
            set = function(r, g, b)
                local pal = BH.settings.cursorTrailPalette or {}
                pal[i] = { r = r, g = g, b = b }
                Set("cursorTrailPalette", pal)
            end,
            disabled = function() return PaletteOff() or i > (BH.settings.cursorTrailPaletteCount or 3) end,
        })
    end
    content:SetHeight(math.abs(y) + 20)
end
