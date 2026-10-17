--[[ LibSquizzTheme-1.0

    One theme shared by SquizzFrames and Squizzumables. Each addon embeds a
    copy; LibStub runs the newest, so both addons always draw from the SAME
    palette and the SAME choice of preset. Picking a preset in either addon
    changes both (user decision, SquizzFrames 2.0 design, 2026-10-16).

    WHAT IT HOLDS
      * The palette: every colour the addons' own chrome draws with, by name
        (options window, Edit Mode boxes, in-game panels). Colours a player
        sets for a frame (health bars, indicators, glows) are NOT theme values.
      * Five presets: Squizz Gold (default), Dark Glass, Class Colour, Rainbow,
        Minimal. A preset overrides BASE key by key, plus an accent MODE:
        fixed (the preset's accent), class (the player's class colour) or
        rainbow (cycles).

    THE CHOICE IS ACCOUNT-WIDE, AND STORED TWICE
      A library cannot own SavedVariables, so each addon hands it its own SV
      ROOT table with lib:Attach(root, seed, priority) and the choice is
      written into every attached root as root.sharedTheme = {preset, at, seed}.
      Whichever addon is installed alone keeps working, and two copies that
      disagree are settled the same way every time:
        * a real pick (at > 0, GetServerTime) beats any seed; newest pick wins;
        * with no pick anywhere, the highest-priority SEED wins. A seed is an
          addon's pre-2.0 choice, offered at attach time, so updating changes
          nobody's look: Squizzumables (priority 2) seeds its profile's
          preset, SquizzFrames (priority 1) seeds class colour, so with both
          installed Squizzumables' choice carries over.
      Once settled, the winner is written back into every attached root.

    RULES
      * lib.colors is ONE table for the session, never replaced, only refilled
        (callers alias it and keep reading it).
      * Only the accent repaints live. Every other colour is read when its
        frame is made, so lib:NeedsReload(from, to) says when a switch needs a
        /reload to show fully.
      * Change both copies byte-identically AND bump MINOR, or the two addons
        silently run whichever copy loaded first (same rule as LibSquizzGrid).
]]

local MAJOR, MINOR = "LibSquizzTheme-1.0", 1
local lib = LibStub:NewLibrary(MAJOR, MINOR)
if not lib then return end

-- State that must survive a newer copy replacing this one.
lib.colors = lib.colors or {}
lib.stores = lib.stores or {}       -- [root] = { seed = fn, priority = n }
lib.callbacks = lib.callbacks or {} -- [fn] = true
lib.choice = lib.choice             -- { preset, at, seed } or nil before any Attach

-- Squizz Gold: Squizzumables' look before 2.0, value for value.
local BASE = {
    -- Options window.
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

    -- In-game panels: the world marker, target marker and pre-combat frames.
    panel          = { 0.05, 0.05, 0.05, 0.85 },
    panelSolid     = { 0.05, 0.05, 0.05, 0.90 },
    panelButton    = { 0.10, 0.10, 0.10, 0.70 },
    panelButtonHi  = { 0.30, 0.30, 0.30, 0.70 },
    panelButtonBad = { 0.40, 0.10, 0.10, 0.70 },  -- a clear button, hovered
    panelBadIcon   = { 1, 0.30, 0.30, 1 },        -- the clear button's icon
    handle         = { 0.70, 0.70, 0.70, 0.40 },  -- drag handle
    handleBorder   = { 0.80, 0.80, 0.80, 1 },
    panelTitle     = { 0.10, 0.80, 0.10, 1 },     -- pre-combat frame title

    -- Reminder buttons' text.
    btnHeader   = { 0.20, 0.80, 1, 1 },           -- light blue
    btnTimer    = { 1, 1, 0, 1 },                 -- yellow
    btnText     = { 1, 1, 1, 1 },
    btnBadge    = { 1, 0.82, 0.20, 1 },           -- hearty food badge

    -- Cooldown Manager bars: the track behind a bar's fill.
    barBg       = { 0, 0, 0, 0.5 },

    -- Status: battle res counter, death tally.
    good        = { 0.20, 0.90, 0.20, 1 },
    warning     = { 1.0, 0.50, 0.0, 1 },
    critical    = { 0.90, 0.20, 0.20, 1 },
    highlight   = { 1.0, 0.82, 0.0, 1 },          -- counter / tally titles
}

-- Dark Glass: see-through panels with thin light borders and a cool accent.
local DARK_GLASS = {
    bg          = { 0.04, 0.05, 0.07, 0.80 },
    titleBar    = { 0.08, 0.10, 0.14, 0.85 },
    border      = { 0.55, 0.62, 0.72, 0.45 },
    accent      = { 0.40, 0.72, 0.95, 1 },
    accentDim   = { 0.28, 0.50, 0.68, 0.6 },
    control     = { 0.12, 0.14, 0.18, 0.75 },
    controlHi   = { 0.20, 0.24, 0.30, 0.85 },
    section     = { 0.20, 0.24, 0.30, 0.35 },
    tabActive   = { 0.14, 0.17, 0.22, 0.85 },
    tabInactive = { 0.05, 0.06, 0.09, 0.75 },
    panel          = { 0.04, 0.06, 0.09, 0.55 },
    panelSolid     = { 0.04, 0.06, 0.09, 0.65 },
    panelButton    = { 0.10, 0.13, 0.18, 0.50 },
    panelButtonHi  = { 0.25, 0.32, 0.42, 0.60 },
    handleBorder   = { 0.60, 0.70, 0.80, 0.60 },
    barBg       = { 0, 0, 0, 0.35 },
}

-- Minimal: no panels behind the in-game frames -- icons and text only -- and a
-- quiet light-grey accent. The options window stays readable, just flatter.
local MINIMAL = {
    accent      = { 0.85, 0.85, 0.85, 1 },
    accentDim   = { 0.55, 0.55, 0.55, 0.6 },
    border      = { 0.18, 0.18, 0.20, 1 },
    section     = { 0.12, 0.12, 0.14, 0.3 },
    panel          = { 0, 0, 0, 0 },
    panelSolid     = { 0, 0, 0, 0 },
    panelButton    = { 0, 0, 0, 0 },
    panelButtonHi  = { 0.30, 0.30, 0.30, 0.40 },
    barBg       = { 0, 0, 0, 0.2 },
}

-- `colors` overrides BASE key by key. Two presets with the same `colors` table
-- (nil included) differ only in the accent, which repaints live.
lib.PRESETS = {
    squizz_gold  = { name = "Squizz Gold",  accent = "fixed",
                     tip = "The default: dark panels and a warm gold accent." },
    dark_glass   = { name = "Dark Glass",   accent = "fixed", colors = DARK_GLASS,
                     tip = "See-through panels with thin light borders and a cool blue accent." },
    class_colour = { name = "Class Colour", accent = "class",
                     tip = "Squizz Gold's panels, with the accent in your class colour." },
    rainbow      = { name = "Rainbow",      accent = "rainbow",
                     tip = "Squizz Gold's panels, with an accent that slowly cycles through the colours." },
    minimal      = { name = "Minimal",      accent = "fixed", colors = MINIMAL,
                     tip = "No panels behind the frames in the game -- just icons and text -- and a quiet grey accent." },
}
lib.ORDER = { "squizz_gold", "dark_glass", "class_colour", "rainbow", "minimal" }
lib.DEFAULT_PRESET = "squizz_gold"

local function Fill(preset)
    local colors = lib.colors
    local over = (preset and preset.colors) or {}
    for key, c in pairs(BASE) do
        local src = over[key] or c
        local dst = colors[key]
        if not dst then
            dst = {}
            colors[key] = dst
        end
        dst[1], dst[2], dst[3], dst[4] = src[1], src[2], src[3], src[4] or 1
    end
end

--- The active preset's key.
function lib:PresetKey()
    local key = lib.choice and lib.choice.preset
    if key and lib.PRESETS[key] then return key end
    return lib.DEFAULT_PRESET
end

function lib:Preset()
    return lib.PRESETS[lib:PresetKey()] or lib.PRESETS[lib.DEFAULT_PRESET]
end

--- "fixed", "class" or "rainbow".
function lib:AccentMode()
    return lib:Preset().accent or "fixed"
end

-- Rainbow: once round the colour wheel every RAINBOW_PERIOD seconds, soft
-- enough (saturation below 1) to sit on the dark panels like the gold does.
local RAINBOW_PERIOD = 8
function lib:RainbowRGB()
    local h = (GetTime() / RAINBOW_PERIOD) % 1 * 6
    local s, v = 0.65, 1
    local i = math.floor(h)
    local f = h - i
    local p, q, t = v * (1 - s), v * (1 - s * f), v * (1 - s * (1 - f))
    if i == 0 then return v, t, p
    elseif i == 1 then return q, v, p
    elseif i == 2 then return p, v, t
    elseif i == 3 then return p, q, v
    elseif i == 4 then return t, p, v
    end
    return v, p, q
end

--- r, g, b of the accent as the active preset draws it right now: the
--- preset's fixed accent, the player's class colour, or the rainbow's
--- current point.
function lib:AccentRGB()
    local mode = lib:AccentMode()
    if mode == "class" then
        local _, class = UnitClass("player")
        local c = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
        if c then return c.r, c.g, c.b end
    elseif mode == "rainbow" then
        return lib:RainbowRGB()
    end
    local a = lib.colors.accent
    return a[1], a[2], a[3]
end

--- Does going from preset `from` to `to` change anything besides the accent?
function lib:NeedsReload(from, to)
    local a, b = lib.PRESETS[from], lib.PRESETS[to]
    return (a and a.colors) ~= (b and b.colors)
end

--- r, g, b, a of a theme colour. An unknown key is a bug, so it shows as
--- magenta rather than failing.
function lib:RGBA(key)
    local c = lib.colors[key]
    if not c then return 1, 0, 1, 1 end
    return c[1], c[2], c[3], c[4]
end

--- fn() runs after every change of preset, in every addon that registered.
function lib:RegisterCallback(fn)
    lib.callbacks[fn] = true
end

local function Notify()
    for fn in pairs(lib.callbacks) do
        local ok, err = pcall(fn)
        if not ok and geterrorhandler then geterrorhandler()(err) end
    end
end

-- Which of two records wins: a real pick beats a seed, the newer pick beats
-- the older, and between seeds the higher priority wins.
local function Better(a, b)
    if not b then return a end
    if not a then return b end
    local at, bt = a.at or 0, b.at or 0
    if at > 0 or bt > 0 then
        return (at >= bt) and a or b
    end
    return ((a.seed or 0) >= (b.seed or 0)) and a or b
end

local function Valid(rec)
    return type(rec) == "table" and type(rec.preset) == "string" and lib.PRESETS[rec.preset] ~= nil
end

local function Copy(rec)
    return { preset = rec.preset, at = rec.at or 0, seed = rec.seed or 0 }
end

-- Settle the choice across every attached root and write the winner back.
local function Resolve()
    local best
    for root, info in pairs(lib.stores) do
        if Valid(root.sharedTheme) then
            best = Better(best, root.sharedTheme)
        else
            local key = info.seed and info.seed()
            if key and lib.PRESETS[key] then
                best = Better(best, { preset = key, at = 0, seed = info.priority or 0 })
            end
        end
    end
    best = best and Copy(best) or { preset = lib.DEFAULT_PRESET, at = 0, seed = 0 }
    for root in pairs(lib.stores) do
        root.sharedTheme = Copy(best)
    end
    local changed = not lib.choice or lib.choice.preset ~= best.preset
    lib.choice = best
    Fill(lib:Preset())
    if changed then Notify() end
end

--- Hand the library an addon's SavedVariables ROOT (account-wide, never a
--- profile). seed() returns that addon's pre-2.0 preset key, or nil; it is
--- only consulted while no shared choice has been stored yet.
function lib:Attach(root, seed, priority)
    if type(root) ~= "table" then return end
    lib.stores[root] = { seed = seed, priority = priority or 0 }
    Resolve()
end

--- The player picked a preset: record it in every attached root and repaint.
function lib:SetPreset(key)
    if not lib.PRESETS[key] then return end
    local rec = { preset = key, at = (GetServerTime and GetServerTime()) or time(), seed = 0 }
    for root in pairs(lib.stores) do
        root.sharedTheme = Copy(rec)
    end
    local changed = not lib.choice or lib.choice.preset ~= key
    lib.choice = rec
    Fill(lib:Preset())
    if changed then Notify() end
end

Fill(lib:Preset())
