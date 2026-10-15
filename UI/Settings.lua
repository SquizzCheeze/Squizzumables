-- UI/Settings.lua
-- Settings descriptions (2.0): each setting is described ONCE -- its key,
-- default, control, label, tooltip and when it applies -- and that one
-- description supplies all three things that used to be written separately
-- and could drift apart:
--
--   * the default, registered into BH.defaultSettings at load (so it is in
--     place before LoadSettings runs ApplyDefaults, and ProfileIO's export
--     diff sees it)
--   * the control, built as a Rows spec
--   * the search entry, which Rows registers from the label and tooltip
--
-- Piloted on the Cursor page (Core/Cursor.lua). The other pages move over one
-- at a time as they enter the phase-3 shell, so none is described twice.
--
-- A description:
--
--   ns.Settings.Describe({
--       master = "cursorEnabled",      -- optional: every other row greys out while it is off
--       apply  = function() ... end,   -- run after any change
--       pages  = {                     -- one sub-tab each
--           { key = "cursor", label = "Cursor", rows = {
--               { key = "cursorSize", type = "slider", default = 100,
--                 min = 50, max = 200, step = 5,
--                 label = "Size", tip = "Size of everything ...",
--                 when = function(s) return s.cursorDot end },  -- optional
--           } },
--       },
--   })
--
-- Row types: check, slider, dropdown (items, a list or a function), color
-- ({r,g,b}), editbox (trimmed), palette (one table of colours, `size` rows,
-- the first s[countKey] of them in use), button (onClick; not a setting), and
-- header / text / divider, which pass straight to Rows (label, indent, width).
-- `when` receives BH.settings and says when the row APPLIES; the row greys out
-- otherwise.
--
-- Per row, optionally:
--   apply = function(value, userInput) ... end
--       what changes once it is written -- runs before the save and the
--       page's own `apply`. For a row whose effect differs from the page's
--       (Raid Tools: visibility here, the marker layout there).
--   scale = 100
--       a slider showing value * scale while storing value (a scale of 1.0
--       shown as 100%).
--   show = function(stored) return shown end, store = function(shown) ... end
--       a slider whose number means something else on screen (Pulse depth:
--       stored as the alpha the glow fades TO, shown as how far it fades).
--   invert = true
--       a check that stores the opposite of what it shows (Show minimap
--       button = not minimapButtonHidden).
--
-- A page that is part described and part hand-built (Settings: the theme
-- picker and the profile manager are not settings) gives `sections` instead of
-- `pages` -- { name = { rows } } -- and draws each where it belongs with
-- Settings.AddRows(desc, name, content, y), which returns the new y.

local addonName, ns = ...
local BH = ns.BH

local Settings = {}
ns.Settings = Settings

local WIDTH = { slider = 300, dropdown = 200, editbox = 300 }

local function Register(row)
    if row.key == nil or row.default == nil then return end
    local defaults = BH.defaultSettings
    -- Described in two places is exactly what this module exists to prevent.
    assert(defaults[row.key] == nil, "Squizzumables: setting described twice: " .. row.key)
    defaults[row.key] = type(row.default) == "table" and CopyTable(row.default) or row.default
end

-- Register a page's defaults. Call at load, from the feature's own file.
function Settings.Describe(desc)
    for _, page in ipairs(desc.pages or {}) do
        for _, row in ipairs(page.rows) do Register(row) end
    end
    for _, rows in pairs(desc.sections or {}) do
        for _, row in ipairs(rows) do Register(row) end
    end
    return desc
end

local function Disabled(desc, row)
    local master, when = desc.master, row.when
    if row.key == master then return nil end
    return function()
        local s = BH.settings
        if master and not s[master] then return true end
        return when ~= nil and not when(s)
    end
end

-- Rows that are not settings: passed to Rows as they are.
local LAYOUT_ROWS = { header = true, text = true, divider = true }

-- The Rows spec for one description row.
local function Spec(desc, row)
    local key = row.key
    local t = row.type
    if LAYOUT_ROWS[t] then
        return { type = t, label = row.label, tooltip = row.tip, indent = row.indent, width = row.width }
    end
    local function Set(v, userInput)
        BH.settings[key] = v
        if row.apply then row.apply(v, userInput) end
        BH:SaveSettings()
        if desc.apply then desc.apply() end
    end
    local spec = {
        type = t, label = row.label, tooltip = row.tip,
        width = row.width or WIDTH[t],
        disabled = Disabled(desc, row),
    }
    if t == "check" then
        if row.invert then
            spec.get = function() return not BH.settings[key] end
            spec.set = function(v) Set(not v) end
        else
            spec.get = function() return BH.settings[key] and true or false end
            spec.set = Set
        end
    elseif t == "slider" then
        spec.min, spec.max, spec.step = row.min, row.max, row.step
        local scale = row.scale or 1
        local show = row.show or function(v) return v * scale end
        local store = row.store or function(v) return v / scale end
        spec.get = function() return show(BH.settings[key] or row.default) end
        spec.set = function(v, userInput) Set(store(v), userInput) end
    elseif t == "dropdown" then
        spec.items = row.items
        spec.get = function() return BH.settings[key] or row.default end
        spec.set = Set
    elseif t == "color" then
        spec.get = function()
            local c = BH.settings[key] or {}
            return c.r or 1, c.g or 1, c.b or 1
        end
        spec.set = function(r, g, b) Set({ r = r, g = g, b = b }) end
    elseif t == "editbox" then
        spec.get = function() return BH.settings[key] or "" end
        spec.set = function(v) Set(strtrim(v or "")) end
    elseif t == "button" then
        spec.height = row.height
        spec.onClick = row.onClick
    end
    return spec
end

-- One colour row per palette slot; slots past s[countKey] grey out.
local function AddPalette(content, y, desc, row)
    local Rows = ns.Rows
    local key = row.key
    local base = Disabled(desc, row)
    for i = 1, row.size do
        y = y - Rows.Add(content, y, {
            type = "color", label = row.label .. " " .. i,
            tooltip = row.tip:format(i),
            get = function()
                local c = (BH.settings[key] or {})[i] or {}
                return c.r or 1, c.g or 1, c.b or 1
            end,
            set = function(r, g, b)
                local pal = BH.settings[key] or {}
                pal[i] = { r = r, g = g, b = b }
                BH.settings[key] = pal
                BH:SaveSettings()
                if desc.apply then desc.apply() end
            end,
            disabled = function()
                return base() or i > (BH.settings[row.countKey] or row.size)
            end,
        })
    end
    return y
end

-- Build the page's sub-tabs and rows into `parent`. Returns the sub-tab pages.
-- Draw `rows` into `content` from `y` down; returns the new y.
local function AddRowList(desc, rows, content, y)
    local Rows = ns.Rows
    for _, row in ipairs(rows) do
        if row.type == "palette" then
            y = AddPalette(content, y, desc, row)
        else
            y = y - Rows.Add(content, y, Spec(desc, row))
        end
    end
    return y
end

function Settings.Build(desc, parent)
    local Rows = ns.Rows
    local tabs = {}
    for i, page in ipairs(desc.pages) do tabs[i] = { key = page.key, label = page.label } end
    local pages = ns.SubTabs.Create(parent, tabs)

    for _, page in ipairs(desc.pages) do
        local content = pages[page.key]
        Rows.currentSection = content.section
        local y = AddRowList(desc, page.rows, content, -14)
        content:SetHeight(math.abs(y) + 20)
    end
    return pages
end

--- One `sections` entry of a part-described page, drawn into `content` from
--- `y` down. Returns the new y.
function Settings.AddRows(desc, name, content, y)
    return AddRowList(desc, desc.sections[name], content, y)
end
