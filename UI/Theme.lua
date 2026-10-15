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
-- Rainbow, Minimal. Only the two that exist today are defined yet -- the
-- player's choice between them was the old useClassColorAccent checkbox. The
-- others need their own palettes and the theme picker (phase 3).

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

local PRESETS = {
    squizz_gold  = { name = "Squizz Gold",  accent = "fixed" },
    class_colour = { name = "Class Colour", accent = "class" },
}
Theme.PRESETS = PRESETS
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

--- "fixed" or "class".
function Theme.AccentMode()
    return Theme.Preset().accent or "fixed"
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
    if ns.RefreshAccentColors then ns.RefreshAccentColors() end
end
