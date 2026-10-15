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
-- Row types: check, slider, dropdown (items), color ({r,g,b}), editbox
-- (trimmed), palette (one table of colours, `size` rows, the first
-- s[countKey] of them in use), button (onClick; not a setting). `when`
-- receives BH.settings and says when the row APPLIES; the row greys out
-- otherwise.

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
    for _, page in ipairs(desc.pages) do
        for _, row in ipairs(page.rows) do Register(row) end
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

-- The Rows spec for one description row.
local function Spec(desc, row)
    local key = row.key
    local function Set(v)
        BH.settings[key] = v
        BH:SaveSettings()
        if desc.apply then desc.apply() end
    end
    local spec = {
        type = row.type, label = row.label, tooltip = row.tip,
        width = row.width or WIDTH[row.type],
        disabled = Disabled(desc, row),
    }
    local t = row.type
    if t == "check" then
        spec.get = function() return BH.settings[key] and true or false end
        spec.set = Set
    elseif t == "slider" then
        spec.min, spec.max, spec.step = row.min, row.max, row.step
        spec.get = function() return BH.settings[key] or row.default end
        spec.set = Set
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
function Settings.Build(desc, parent)
    local Rows = ns.Rows
    local tabs = {}
    for i, page in ipairs(desc.pages) do tabs[i] = { key = page.key, label = page.label } end
    local pages = ns.SubTabs.Create(parent, tabs)

    for _, page in ipairs(desc.pages) do
        local content = pages[page.key]
        Rows.currentSection = content.section
        local y = -14
        for _, row in ipairs(page.rows) do
            if row.type == "palette" then
                y = AddPalette(content, y, desc, row)
            else
                y = y - Rows.Add(content, y, Spec(desc, row))
            end
        end
        content:SetHeight(math.abs(y) + 20)
    end
    return pages
end
