-- UI/Theme.lua
-- The theme: every colour the addon draws with, by name (2.0, phase 1).
--
-- Since 2.0.x the palette, the presets and the CHOICE live in LibSquizzTheme-1.0
-- (Libs/), shared with SquizzFrames: one theme covers both addons and picking a
-- preset in either changes both (SquizzFrames 2.0 design, user decision
-- 2026-10-16). This file keeps the ns.Theme API the rest of the addon already
-- calls, as a thin layer over the library, plus the one thing that is ours:
-- the rainbow ticker, which only repaints OUR options window.
--
-- Rules carried over:
--   * Theme.colors is ONE table for the whole session (the library's).
--     Widgets.lua aliases it as SQ_COLORS; a preset change refills it in place.
--   * The accent is a MODE: fixed, class or rainbow (Theme.AccentMode()).
--
-- The choice is ACCOUNT-WIDE now (SquizzumablesDB.sharedTheme, written by the
-- library), not per profile. The profile's old theme.preset /
-- useClassColorAccent are still written on every pick so an exported profile
-- keeps its look in an older copy of the addon, and are read ONCE, as the seed
-- the library uses when no shared choice exists yet -- see Theme.Attach.

local addonName, ns = ...

local LST = LibStub("LibSquizzTheme-1.0")

local Theme = {}
ns.Theme = Theme

Theme.PRESETS = LST.PRESETS
Theme.ORDER = LST.ORDER
Theme.DEFAULT_PRESET = LST.DEFAULT_PRESET
Theme.colors = LST.colors

local function Settings()
    local BH = ns.BH
    return BH and BH.settings
end

function Theme.PresetKey()   return LST:PresetKey() end
function Theme.Preset()      return LST:Preset() end
function Theme.AccentMode()  return LST:AccentMode() end
function Theme.RainbowRGB()  return LST:RainbowRGB() end
function Theme.NeedsReload(from, to) return LST:NeedsReload(from, to) end
---@return number r, number g, number b, number a
function Theme.RGBA(key)     return LST:RGBA(key) end

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

--- Join the shared theme. Called once, after the settings have loaded and
--- migrated, so the seed below can read this profile's pre-2.0.x choice.
--- A brand-new install offers no seed: it has never chosen anything, and
--- offering the default would override SquizzFrames' existing look.
function Theme.Attach(isNewInstall)
    LST:Attach(SquizzumablesDB, function()
        local s = Settings()
        if not s then return nil end
        local key = type(s.theme) == "table" and s.theme.preset
        if key and LST.PRESETS[key] then return key end
        if s.useClassColorAccent then return "class_colour" end
        if isNewInstall then return nil end
        return LST.DEFAULT_PRESET
    end, 2)
end

--- Switch preset (in BOTH addons), refill the palette and repaint what follows
--- the accent. Also keeps the profile's old keys in step for exports.
function Theme.SetPreset(key)
    if not LST.PRESETS[key] then return end
    local s = Settings()
    if s then
        s.theme = type(s.theme) == "table" and s.theme or {}
        s.theme.preset = key
        s.useClassColorAccent = (key == "class_colour")
    end
    LST:SetPreset(key)
    Theme.Apply()
end

--- Repaint from the active preset (profile load, preset change, or a change
--- made in SquizzFrames, which reaches us through the callback below).
function Theme.Apply()
    UpdateRainbowTicker()
    if ns.RefreshAccentColors then ns.RefreshAccentColors() end
end

LST:RegisterCallback(Theme.Apply)
