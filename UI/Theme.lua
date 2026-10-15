-- UI/Theme.lua
-- The theme: every colour the addon draws with, by name (2.0, phase 1).
--
-- Before 2.0 the options window drew from one palette (SQ_COLORS, in
-- Widgets.lua) while the frames in the game -- reminder buttons, the marker and
-- pull timer frames, the battle res counter -- carried their colours as bare
-- numbers, each file its own. A theme has to reach all of them or a preset
-- would restyle half the addon, so everything that is part of the LOOK now
-- comes from here. Colours that carry a fixed meaning the player sets
-- elsewhere (a glow's tint, an alert image's colour) are not theme values.
--
-- Three rules:
--   * Theme.colors is ONE table for the whole session. Widgets.lua aliases it
--     as SQ_COLORS, so every existing SQ_COLORS.x read keeps working; a preset
--     change refills it in place rather than replacing it.
--   * Every value here is exactly what the code used before (squizz_gold is
--     today's look), so this file changes nothing on screen. Near-duplicate
--     greys stay separate keys for now; the options window is rebuilt in
--     phase 3, which is where they get folded together.
--   * The accent is not a colour here but a MODE: fixed (the preset's
--     accent), or class (the player's class colour). ns.GetAccentColor asks
--     Theme.AccentMode(); Rainbow will be a third mode.
--
-- Presets (design doc): Squizz Gold (default), Dark Glass, Class Colour,
-- Rainbow, Minimal, chosen with the Theme dropdown on the Settings page (2.0
-- phase 3), which replaced the useClassColorAccent checkbox.

local addonName, ns = ...

local Theme = {}
ns.Theme = Theme

-- Squizz Gold: today's look, value for value.
local BASE = {
    -- Options window (was SQ_COLORS in Widgets.lua).
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
-- (nil included) differ only in the accent, which repaints live; any other
-- difference needs a reload -- see Theme.NeedsReload.
local PRESETS = {
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
Theme.PRESETS = PRESETS
Theme.ORDER = { "squizz_gold", "dark_glass", "class_colour", "rainbow", "minimal" }
Theme.DEFAULT_PRESET = "squizz_gold"

-- The live palette. Never replaced, only refilled (see the header).
Theme.colors = {}

local function Fill(preset)
    local colors = Theme.colors
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
Fill(PRESETS[Theme.DEFAULT_PRESET])

local function Settings()
    local BH = ns.BH
    return BH and BH.settings
end

--- The active preset's key. A profile that has never chosen one reads its old
--- class-colour checkbox, so nothing changes for anyone until they pick.
function Theme.PresetKey()
    local s = Settings()
    if not s then return Theme.DEFAULT_PRESET end
    local key = type(s.theme) == "table" and s.theme.preset
    if key and PRESETS[key] then return key end
    return s.useClassColorAccent and "class_colour" or Theme.DEFAULT_PRESET
end

function Theme.Preset()
    return PRESETS[Theme.PresetKey()] or PRESETS[Theme.DEFAULT_PRESET]
end

--- "fixed", "class" or "rainbow".
function Theme.AccentMode()
    return Theme.Preset().accent or "fixed"
end

-- Rainbow: once round the colour wheel every RAINBOW_PERIOD seconds, soft
-- enough (saturation below 1) to sit on the dark panels like the gold does.
local RAINBOW_PERIOD = 8
function Theme.RainbowRGB()
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

-- The rainbow accent repaints the registered accent regions ten times a
-- second, and only while the options window is open: those regions are almost
-- all in it, and nothing else needs the cycle badly enough to pay for it.
local rainbowTicker
local function UpdateRainbowTicker()
    local want = Theme.AccentMode() == "rainbow"
    if want and not rainbowTicker then
        rainbowTicker = C_Timer.NewTicker(0.1, function()
            local panel = _G.SQUIZZUMABLESOptions
            if panel and panel:IsShown() and ns.RefreshAccentColors then
                ns.RefreshAccentColors()
            end
        end)
    elseif not want and rainbowTicker then
        rainbowTicker:Cancel()
        rainbowTicker = nil
    end
end

--- Does going from preset `from` to `to` change anything besides the accent?
--- Only accent regions repaint live; every other colour is read when its frame
--- is made, so that part of a switch shows after a /reload.
function Theme.NeedsReload(from, to)
    local a, b = PRESETS[from], PRESETS[to]
    return (a and a.colors) ~= (b and b.colors)
end

--- r, g, b, a of a theme colour, for SetTextColor(Theme.RGBA("good")) and the
--- like. An unknown key is a bug, so it shows as magenta rather than failing.
function Theme.RGBA(key)
    local c = Theme.colors[key]
    if not c then return 1, 0, 1, 1 end
    return c[1], c[2], c[3], c[4]
end

--- Switch preset, refill the palette and repaint what follows the accent.
--- Also keeps the old checkbox key in step, so a profile exported to an older
--- copy of the addon keeps its look.
function Theme.SetPreset(key)
    local s = Settings()
    if not (s and PRESETS[key]) then return end
    s.theme = type(s.theme) == "table" and s.theme or {}
    s.theme.preset = key
    s.useClassColorAccent = (key == "class_colour")
    Theme.Apply()
end

--- Refill the palette from the active preset (profile load, preset change).
function Theme.Apply()
    Fill(Theme.Preset())
    UpdateRainbowTicker()
    if ns.RefreshAccentColors then ns.RefreshAccentColors() end
end
