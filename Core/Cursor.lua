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
    shark   = { file = MEDIA .. "shark.png", blend = "BLEND", faces = true },   -- V1.98, cut-shark-silhouette.ps1
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
-- Shark bite (V1.98, user request 2026-10-11)
--
-- On a left click a shark surfaces under the cursor, chomps over its tip and
-- sinks again -- purely visual, the cursor itself is untouched. The art is a
-- 12-frame chomp the user supplied (AI-generated, cleared to ship), cut out of
-- a JPG by .claude/cut-shark.ps1 into Media/Cursor/shark_bite.png: 4 x 4 grid
-- of 256 x 256 frames, 12 used, wide open -> shut. Each frame's centre is the
-- mouth, so that is the point pinned to the click.
--
-- The rise and sink are drawn here, not in the art: the shark texture slides
-- up and down inside a CLIPPING frame whose bottom edge is the waterline, so
-- it emerges from the water rather than fading in. A flattened ring ripples
-- out at the waterline and a few droplets splash on the way up and down.
-- About 0.7 s in all, at the click point (not following the cursor).
-- ============================================================================
local Shark = {
    FRAMES = 12, COLS = 4, ROWS = 4,
    SIZE = 110,                          -- on screen at 100%, UIParent units
    RISE = 0.14, CHOMP = 0.30, SINK = 0.24,
    WATERLINE = -0.38,                   -- of the size, below the mouth
    SPLASH = 12,                         -- droplet pool
    t = nil,                             -- seconds into a bite, nil when none
    drops = {},                          -- { tex, age, life, x, y, vx, vy }
}

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
        -- Its own pace (Seconds Per Colour), not Rainbow Speed: a full lap is
        -- that many seconds per colour, so adding colours lengthens the cycle
        -- instead of speeding every step up (user request 2026-10-03).
        local s = BH.settings
        local n = math.max(2, math.min(PALETTE_MAX, s.cursorTrailPaletteCount or 3))
        local per = math.max(0.1, s.cursorTrailPaletteSeconds or 1.5)
        return PaletteRGB(GetTime() / (per * n) + (hueOffset or 0), true)
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

    -- Shark bite: a holder placed at the click, the clipping "above water"
    -- frame inside it, the shark texture in that, and the ripple and droplets
    -- on the holder (they belong at and above the waterline, unclipped).
    local f = CreateFrame("Frame", nil, UIParent)
    f:SetSize(1, 1)
    f:EnableMouse(false)
    f:Hide()
    Shark.frame = f
    local clip = CreateFrame("Frame", nil, f)
    clip:SetClipsChildren(true)
    Shark.clip = clip
    local tex = clip:CreateTexture(nil, "ARTWORK")
    -- NEAREST: it is pixel art; a smooth filter would blur it when scaled.
    tex:SetTexture(MEDIA .. "shark_bite.png", "CLAMP", "CLAMP", "NEAREST")
    Shark.tex = tex
    local ripple = f:CreateTexture(nil, "ARTWORK", nil, -1)
    ripple:SetTexture(MEDIA .. "ring.png")
    ripple:SetVertexColor(0.6, 0.85, 1)
    ripple:Hide()
    Shark.ripple = ripple
    for i = 1, Shark.SPLASH do
        local d = f:CreateTexture(nil, "OVERLAY")
        d:SetTexture(MEDIA .. "soft.png")
        d:SetBlendMode("ADD")
        d:SetVertexColor(0.65, 0.88, 1)
        d:Hide()
        Shark.drops[i] = { tex = d, age = 0, life = 0, x = 0, y = 0, vx = 0, vy = 0 }
    end
end

-- ============================================================================
-- Shark bite
-- ============================================================================

local function SharkFrame(n)
    n = n - 1
    local c, r = n % Shark.COLS, math.floor(n / Shark.COLS)
    Shark.tex:SetTexCoord(c / Shark.COLS, (c + 1) / Shark.COLS, r / Shark.ROWS, (r + 1) / Shark.ROWS)
end

-- A handful of droplets thrown up from the waterline.
local function SharkSplash(count)
    local S = Shark.size
    local n = 0
    for _, d in ipairs(Shark.drops) do
        if d.life == 0 then
            d.age, d.life = 0, 0.45 + math.random() * 0.2
            d.x = (math.random() - 0.5) * S * 0.7
            d.y = S * Shark.WATERLINE
            d.vx = (math.random() - 0.5) * 160
            d.vy = 110 + math.random() * 120
            local sz = 5 + math.random() * 6
            d.tex:SetSize(sz, sz)
            d.tex:Show()
            n = n + 1
            if n >= count then break end
        end
    end
end

-- Start a bite with the mouth at x, y (UIParent units). A new click mid-bite
-- starts over at the new spot.
-- `onTop`: the Test button's bite. It always happens over the open settings
-- window (DIALOG strata), which the player's Frame Strata -- HIGH by default --
-- sits under, so the test bite goes above everything and a real one goes back
-- to the setting.
local function StartBite(x, y, onTop)
    if not Shark.frame then return end
    local s = BH.settings
    local S = Shark.SIZE * (s.cursorSharkSize or 100) / 100
    Shark.size = S
    local f = Shark.frame
    f:SetFrameStrata(onTop and "TOOLTIP" or (s.cursorStrata or "HIGH"))
    f:ClearAllPoints()
    f:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x, y)
    f:SetAlpha((s.cursorOpacity or 100) / 100)
    -- Above the waterline only: the clip frame's bottom IS the waterline.
    Shark.clip:ClearAllPoints()
    Shark.clip:SetPoint("BOTTOMLEFT", f, "CENTER", -S, S * Shark.WATERLINE)
    Shark.clip:SetSize(S * 2, S * 2)
    Shark.tex:SetSize(S, S)
    Shark.ripple:ClearAllPoints()
    Shark.ripple:SetPoint("CENTER", f, "CENTER", 0, S * Shark.WATERLINE)
    Shark.t, Shark.sank = 0, false
    SharkFrame(1)
    f:Show()
    SharkSplash(6)
end

local function SmoothStep(p) return p * p * (3 - 2 * p) end

local function AnimateShark(elapsed)
    local t = Shark.t + elapsed
    Shark.t = t
    local S = Shark.size
    local rise, chomp, sink = Shark.RISE, Shark.CHOMP, Shark.SINK
    local total = rise + chomp + sink
    local off   -- the shark's drop below its full height, as a fraction of S
    if t < rise then
        off = 1 - SmoothStep(t / rise)
        SharkFrame(1)
    elseif t < rise + chomp then
        off = 0
        -- Frames 1..12 across the chomp: open, snapping shut, mouth closed.
        local u = (t - rise) / chomp
        SharkFrame(math.min(Shark.FRAMES, 1 + math.floor(u * Shark.FRAMES)))
    else
        if not Shark.sank then Shark.sank = true; SharkSplash(6) end
        off = SmoothStep(math.min(1, (t - rise - chomp) / sink))
        SharkFrame(Shark.FRAMES)
    end
    Shark.tex:ClearAllPoints()
    Shark.tex:SetPoint("CENTER", Shark.frame, "CENTER", 0, -off * S * 1.05)

    -- The ripple: a flattened ring spreading and fading over the whole bite.
    local p = math.min(1, t / total)
    local w = S * (0.55 + 0.9 * p)
    Shark.ripple:SetSize(w, w * 0.22)
    Shark.ripple:SetAlpha(0.8 * (1 - p))
    Shark.ripple:Show()

    -- Droplets: thrown up, pulled down hard, fading.
    local alive = false
    for _, d in ipairs(Shark.drops) do
        if d.life > 0 then
            d.age = d.age + elapsed
            if d.age >= d.life then
                d.life = 0
                d.tex:Hide()
            else
                alive = true
                d.vy = d.vy - 650 * elapsed
                d.x, d.y = d.x + d.vx * elapsed, d.y + d.vy * elapsed
                d.tex:ClearAllPoints()
                d.tex:SetPoint("CENTER", Shark.frame, "CENTER", d.x, d.y)
                d.tex:SetAlpha(1 - d.age / d.life)
            end
        end
    end

    if t >= total and not alive then
        Shark.t = nil
        Shark.ripple:Hide()
        Shark.frame:Hide()
    end
end

-- Was the click on the game world rather than on a window or button?
local function ClickedWorld()
    local foci = GetMouseFoci and GetMouseFoci()
    local first = foci and foci[1]
    return first == nil or first == WorldFrame
end

--- The options page's Test button: a bite where the mouse is now.
function BH:TestSharkBite()
    if not (self.settings and self.settings.cursorEnabled) then
        print("Squizzumables: turn on Enable Mouse Cursor first.")
        return
    end
    local scale = UIParent:GetEffectiveScale()
    local cx, cy = GetCursorPosition()
    StartBite(cx / scale, cy / scale, true)
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
        -- Placed from GetCursorPosition even while turning the camera: the
        -- hidden cursor still drifts a little as the camera turns, and rings
        -- held where it was pressed came back off the real cursor by that
        -- much (user report 2026-10-06). Turning lays no trail and is not a
        -- shake, though.
        local scale = UIParent:GetEffectiveScale()
        local cx, cy = GetCursorPosition()
        local x, y = cx / scale, cy / scale
        root:ClearAllPoints()
        root:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x, y)
        if IsMouselooking() then
            lastX, lastY, shakeX = nil, nil, nil
        else
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
    if Shark.t then AnimateShark(elapsed) end
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
    -- The shark sits with the trail, under the rings: the cursor's own dot
    -- and ring stay visible between its jaws.
    Shark.frame:SetFrameStrata(strata)
    Shark.frame:SetFrameLevel(math.max(0, root:GetFrameLevel() - 1))
    if not s.cursorSharkBite and Shark.t then
        Shark.t = nil
        Shark.frame:Hide()
    end
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
        if arg1 == "LeftButton" and s.cursorSharkBite and root:IsShown() and not IsMouselooking()
           and (not s.cursorSharkWorldOnly or ClickedWorld())
           and math.random(100) <= (s.cursorSharkChance or 100) then
            local scale = UIParent:GetEffectiveScale()
            local cx, cy = GetCursorPosition()
            StartBite(cx / scale, cy / scale)
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
    { text = "Sharks",      value = "shark" },
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

-- The page, described once (UI/Settings.lua, the 2.0 settings-description
-- pilot): each row below is the setting's default, its control and its search
-- entry. The defaults used to live in Squizzumables.lua's defaultSettings and
-- again as fallbacks in the page's helper calls.
--
-- `when` says when a row applies (it greys out otherwise); everything also
-- greys out while Enable Mouse Cursor is off.
local function TrailOn(s)     return s.cursorTrail end
-- The click burst is drawn from the trail's particles, so the trail's look
-- (colour, style, opacity, shrink, size) applies to both; only Linger Time,
-- Density and the offsets are the trail's alone.
local function ParticlesOn(s) return s.cursorTrail or s.cursorClickBurst end
local function SharkOn(s)     return s.cursorSharkBite end
local function CombatOn(s)    return s.cursorCombatColor end
local function PaletteOn(s)   return ParticlesOn(s) and s.cursorTrailColorMode == "palette" end

local CURSOR = ns.Settings.Describe({
    master = "cursorEnabled",
    apply = function() BH:ApplyCursor() end,
    pages = {
        { key = "cursor", label = "Cursor", rows = {
            -- Off by default, like the distance readout: it changes how the
            -- mouse looks, so it is asked for.
            { key = "cursorEnabled", type = "check", default = false,
              label = "Enable Mouse Cursor",
              tip = "Rings around your mouse cursor: a centre dot, a ring, your global cooldown and your cast "
                .. "filling round it, and an optional trail." },
            { key = "cursorSize", type = "slider", default = 100, min = 50, max = 200, step = 5,
              label = "Size", tip = "Size of everything around the cursor, as a percentage." },
            { key = "cursorOpacity", type = "slider", default = 100, min = 10, max = 100, step = 5,
              label = "Opacity", tip = "How see-through the rings and the trail are." },
            { key = "cursorColorMode", type = "dropdown", default = "custom", items = COLOR_MODES,
              label = "Colour", tip = "Colour of the dot and rings. Rainbow cycles through the colour wheel." },
            { key = "cursorColor", type = "color", default = { r = 1, g = 1, b = 1 },
              label = "Custom Colour", tip = "Used when Colour is Custom colour.",
              when = function(s) return s.cursorColorMode == "custom" end },
            { key = "cursorCombatColor", type = "check", default = false,
              label = "Different Colour In Combat",
              tip = "Switch the rings to a second colour while you are in combat." },
            { key = "cursorCombatColorMode", type = "dropdown", default = "class", items = COLOR_MODES,
              label = "Combat Colour", tip = "The rings' colour while you are in combat.", when = CombatOn },
            { key = "cursorCombatCustomColor", type = "color", default = { r = 1, g = 0.2, b = 0.2 },
              label = "Custom Combat Colour", tip = "Used when Combat Colour is Custom colour.",
              when = function(s) return CombatOn(s) and s.cursorCombatColorMode == "custom" end },
            { key = "cursorRainbowSpeed", type = "slider", default = 100, min = 10, max = 400, step = 10,
              label = "Rainbow Speed",
              tip = "How fast Rainbow goes round the colour wheel, for the rings and the trail. At 100% once every "
                .. "4 seconds. The trail palette has its own pace on the Trail Colour tab." },
            { key = "cursorCombatOnly", type = "check", default = false,
              label = "Only In Combat", tip = "Show the rings only while you are in combat." },
            { key = "cursorShakeFind", type = "check", default = true,
              label = "Shake To Find Cursor",
              tip = "Shake the mouse quickly left and right and a big ring shrinks onto the cursor, to find it "
                .. "in a busy fight." },
            { key = "cursorHideMouselook", type = "check", default = false,
              label = "Hide While Turning The Camera",
              tip = "Hide the rings while you hold a mouse button to turn the camera. Off, they stay where the "
                .. "cursor was, which is where it comes back when you let go." },
            { key = "cursorStrata", type = "dropdown", default = "HIGH", items = STRATAS,
              label = "Frame Strata",
              tip = "How far in front of other frames the rings sit. Tooltip puts them above every window." },
        } },

        { key = "rings", label = "Rings", rows = {
            { key = "cursorDot", type = "check", default = true,
              label = "Centre Dot", tip = "A dot at the cursor's tip." },
            { key = "cursorDotSize", type = "slider", default = 8, min = 2, max = 30, step = 1,
              label = "Dot Size", tip = "Size of the centre dot.",
              when = function(s) return s.cursorDot end },
            { key = "cursorRing", type = "check", default = true,
              label = "Ring", tip = "A plain ring around the cursor." },
            { key = "cursorHealthColor", type = "check", default = false,
              label = "Ring Warns On Low Health",
              tip = "The ring turns amber and then red as your health drops, over whatever colour it already is. "
                .. "Works in combat.",
              when = function(s) return s.cursorRing end },
            { key = "cursorHealthStart", type = "slider", default = 70, min = 20, max = 100, step = 5,
              label = "Warn Below (% health)",
              tip = "The health at which the warning starts to show. It is fully amber a little below this and "
                .. "red near death.",
              when = function(s) return s.cursorRing and s.cursorHealthColor end },
            { key = "cursorGCD", type = "check", default = true,
              label = "Global Cooldown", tip = "A ring inside the main one that fills as your global cooldown runs." },
            { key = "cursorCast", type = "check", default = true,
              label = "Cast", tip = "A ring outside the main one that fills as you cast or channel." },
        } },

        { key = "trail", label = "Trail", rows = {
            { key = "cursorTrail", type = "check", default = false,
              label = "Show Trail",
              tip = "A fading trail behind the cursor as it moves. Shown only while the rings are." },
            { key = "cursorClickBurst", type = "check", default = false,
              label = "Click Burst",
              tip = "A burst of particles flies out from the cursor when you left-click. It uses the look set "
                .. "below; with a rainbow colour it spreads round the colour wheel. Works with the trail off." },
            -- Shark Bite sits with Click Burst, the other left-click effect
            -- (user request 2026-10-11; it had a sub-tab of its own first).
            { key = "cursorSharkBite", type = "check", default = false,
              label = "Shark Bite",
              tip = "When you left-click, a shark surfaces under the cursor, chomps over it and sinks back into "
                .. "the water. Purely for fun: your cursor and your click work as normal." },
            { key = "cursorSharkChance", type = "slider", default = 100, min = 5, max = 100, step = 5,
              label = "Chance Per Click (%)",
              tip = "How often a left click brings the shark. 100% is every click; lower keeps it a surprise.",
              when = SharkOn },
            { key = "cursorSharkSize", type = "slider", default = 100, min = 50, max = 300, step = 10,
              label = "Shark Size", tip = "How big the shark is, as a percentage.", when = SharkOn },
            { key = "cursorSharkWorldOnly", type = "check", default = false,
              label = "Only When Clicking The Game World",
              tip = "Bite only on clicks in the game world -- not on windows, buttons or your action bars.",
              when = SharkOn },
            { type = "button", label = "Test Shark", width = 100, height = 22,
              tip = "A bite right now, where the mouse is.",
              onClick = function() BH:TestSharkBite() end },
            { key = "cursorTrailStyle", type = "dropdown", default = "glow", items = TRAIL_STYLE_ITEMS,
              label = "Trail Style",
              tip = "Soft glow blends into a bright ribbon; sparkle drifts, falls and twinkles like sparks; dots, "
                .. "rings, stars, hearts and diamonds draw each piece on its own; ducks and sharks face the way "
                .. "you move the mouse. Your own texture uses the name typed below.",
              when = ParticlesOn },
            { key = "cursorTrailTexture", type = "editbox", default = "",
              label = "Your Own Texture (atlas name or file path)",
              tip = "Any of the game's atlas names, for example \"titleprestige-starglow\" or "
                .. "\"bags-glow-flash\", or a texture file path. Press Enter to apply. Used when Trail Style is "
                .. "Your own texture; an empty box falls back to the soft glow.",
              when = function(s) return ParticlesOn(s) and s.cursorTrailStyle == "custom" end },
            { key = "cursorTrailBlend", type = "dropdown", default = "style", items = TRAIL_BLENDS,
              label = "Blending",
              tip = "Glow adds the pieces' light together, so overlaps go bright; solid draws them as they are. "
                .. "By default each style uses whichever suits it.",
              when = ParticlesOn },
            { key = "cursorTrailLength", type = "slider", default = 0.5, min = 0.1, max = 3, step = 0.1,
              label = "Linger Time",
              tip = "How long, in seconds, the trail lingers before it has faded away.", when = TrailOn },
            { key = "cursorTrailOpacity", type = "slider", default = 100, min = 10, max = 100, step = 5,
              label = "Trail Opacity",
              tip = "How see-through the trail is, on top of the overall Opacity on the Cursor tab.",
              when = ParticlesOn },
            { key = "cursorTrailShrink", type = "slider", default = 60, min = 0, max = 100, step = 5,
              label = "Shrink As It Fades",
              tip = "How much each piece shrinks as it fades. 0% keeps it full size to the end; 100% shrinks it "
                .. "to nothing.",
              when = ParticlesOn },
            { key = "cursorTrailDensity", type = "slider", default = 100, min = 25, max = 400, step = 25,
              label = "Density",
              tip = "How close together the pieces are. Low makes a dotted line, high a smooth ribbon.",
              when = TrailOn },
            { key = "cursorTrailSize", type = "slider", default = 100, min = 25, max = 500, step = 5,
              label = "Trail Size", tip = "Width of each piece, as a percentage.", when = ParticlesOn },
            { key = "cursorTrailHeight", type = "slider", default = 100, min = 25, max = 400, step = 5,
              label = "Trail Height",
              tip = "Height of each piece as a percentage of its width. 100% keeps it in proportion; other "
                .. "values stretch or squash it.",
              when = ParticlesOn },
            { key = "cursorTrailOffsetX", type = "slider", default = 0, min = -60, max = 60, step = 1,
              label = "Trail Offset X", tip = "Moves the trail left or right of the cursor.", when = TrailOn },
            { key = "cursorTrailOffsetY", type = "slider", default = 0, min = -60, max = 60, step = 1,
              label = "Trail Offset Y", tip = "Moves the trail above or below the cursor.", when = TrailOn },
        } },

        { key = "trailcolour", label = "Trail Colour", rows = {
            { key = "cursorTrailColorMode", type = "dropdown", default = "rainbow", items = TRAIL_COLOR_MODES,
              label = "Trail Colour",
              tip = "Rainbow runs through the colour wheel along the trail. Palette uses colours you choose below.",
              when = ParticlesOn },
            { key = "cursorTrailColor", type = "color", default = { r = 1, g = 1, b = 1 },
              label = "Custom Trail Colour", tip = "Used when Trail Colour is Custom colour.",
              when = function(s) return ParticlesOn(s) and s.cursorTrailColorMode == "custom" end },
            { key = "cursorTrailPaletteFlow", type = "dropdown", default = "time", items = PALETTE_FLOWS,
              label = "Palette Flow",
              tip = "Flows over time: the trail cycles through your colours, at the pace set below. "
                .. "Along the trail: the head of the trail is your first colour and the tail your last.",
              when = PaletteOn },
            { key = "cursorTrailPaletteSeconds", type = "slider", default = 1.5, min = 0.2, max = 10, step = 0.1,
              label = "Seconds Per Colour",
              tip = "How long the trail takes to blend from one palette colour to the next when it flows over "
                .. "time. A full cycle through every colour is this times the number of colours used.",
              when = function(s) return PaletteOn(s) and s.cursorTrailPaletteFlow ~= "trail" end },
            { key = "cursorTrailPaletteCount", type = "slider", default = 3, min = 2, max = PALETTE_MAX, step = 1,
              label = "Palette Colours Used",
              tip = "How many of the colours below the palette uses, from the first.", when = PaletteOn },
            { key = "cursorTrailPalette", type = "palette", size = PALETTE_MAX,
              countKey = "cursorTrailPaletteCount",
              label = "Palette Colour", tip = "Colour %d of the trail palette.", when = PaletteOn,
              default = {
                  { r = 1.00, g = 0.20, b = 0.20 },
                  { r = 1.00, g = 0.75, b = 0.10 },
                  { r = 0.20, g = 0.85, b = 1.00 },
                  { r = 0.25, g = 0.90, b = 0.30 },
                  { r = 0.65, g = 0.35, b = 1.00 },
                  { r = 1.00, g = 0.45, b = 0.80 },
              } },
        } },
    },
})

function BH:BuildCursorTab(parent)
    ns.Settings.Build(CURSOR, parent)
end
