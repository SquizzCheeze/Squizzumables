-- Maps/WorldMap.lua
-- The world map: the small (map and quest log) window's scale, fading while
-- you move to the strength you choose, no dark backdrop behind the full-size
-- map, and Blizzard's own player and cursor coordinates switched on.
--
-- ElvUI's and WindTools' world map code was read for behaviour only. The
-- fade is our own driver rather than a hook into Blizzard's movement fader:
-- ElvUI records that calling the map's methods from such hooks taints it, so
-- the map is simply taken off Blizzard's fader and faded here.
--
-- Revealing unexplored areas: WindTools' data for it is Leatrix Maps', so ours
-- is generated from the game's own map tables (Maps/RevealData_*.lua, one
-- per client). The unexplored areas are drawn in textures of our own, on
-- Blizzard's exploration pin, laid out exactly as Blizzard lays out the
-- explored ones; Blizzard's own textures and their pool are never touched.
--
-- Works on retail and WoW Forever. Waits while ElvUI's or WindTools' world
-- map module is on.

local addonName, ns = ...
local BH = ns.BH

local WM = {}
ns.WorldMap = WM

local function Elv()
    local elv = _G["ElvUI"]
    return C_AddOns.IsAddOnLoaded("ElvUI") and type(elv) == "table" and elv[1] or nil
end

function WM.ElvUIOn()
    local E = Elv()
    if not (E and E.private) then return false end
    if E.private.general and E.private.general.worldMap then return true end
    local wt = E.private.WT and E.private.WT.maps and E.private.WT.maps.worldMap
    return (C_AddOns.IsAddOnLoaded("ElvUI_WindTools") and type(wt) == "table" and wt.enable) and true or false
end

local settingsView = setmetatable({}, { __index = function(_, k)
    local s = BH.settings
    local v = s and s[k]
    if v == nil and BH.defaultSettings then v = BH.defaultSettings[k] end
    return v
end })
local function Settings() return settingsView end
local function Map() return _G.WorldMapFrame end
local function Active() return BH.settings and BH.settings.wmEnabled and not WM.ElvUIOn() and Map() ~= nil end
local function Apply() if WM.Apply then WM.Apply() end end

local function CVarOn(name)
    local ok, v = pcall(C_CVar.GetCVarBool, name)
    return ok and v and true or false
end
local function SetCVarOn(name, on)
    pcall(C_CVar.SetCVar, name, on and "1" or "0")
end

-- ============================================================================
-- Settings
-- ============================================================================

local reloadAsked
WM.SETTINGS = ns.Settings.Describe({
    master = "wmEnabled",
    apply = Apply,
    pages = {
        { key = "general", label = "General", rows = {
            { key = "wmEnabled", type = "check", default = false, label = "Restyle the World Map",
              tip = "Scale, fading while you move and coordinates for the world map.\n\nWaits while ElvUI's world map "
                .. "(ElvUI > General > World Map) or WindTools' (WindTools > Maps > World Map) is on; untick them "
                .. "and /reload.",
              apply = function(v)
                  if v and WM.ElvUIOn() then
                      print("|cff33cc99Squizzumables:|r ElvUI's or WindTools' world map is still on. Turn it off "
                          .. "there, /reload, and this takes over.")
                  elseif not v and WM.styled and not reloadAsked then
                      reloadAsked = true
                      print("|cff33cc99Squizzumables:|r the world map is back to Blizzard's after a /reload.")
                  end
              end },
            { key = "wmScale", type = "slider", default = 1, min = 0.5, max = 2, step = 0.01, label = "Scale",
              tip = "The map and quest log window. The full-size map always shows at its normal size." },
            { key = "wmNoBlackout", type = "check", default = true, label = "No Dark Backdrop",
              tip = "Blizzard darkens the screen behind the full-size map and blocks clicks there." },
            { type = "header", label = "FADING" },
            { key = "wmFade", type = "check", default = true, label = "Fade While You Move",
              tip = "Not while the mouse is over the map." },
            { key = "wmFadeAlpha", type = "slider", default = 0.2, min = 0, max = 1, step = 0.05,
              label = "Opacity While Moving", when = function(s) return s.wmFade end },
            { key = "wmFadeTime", type = "slider", default = 0.2, min = 0, max = 2, step = 0.05,
              label = "Fade Time (Seconds)", when = function(s) return s.wmFade end },
            { type = "header", label = "COORDINATES" },
            { key = "wmPlayerCoords", type = "check", label = "Your Coordinates",
              tip = "Blizzard's own, at the bottom left of the map. The same as the game's setting.",
              read = function() return CVarOn("worldMapShowPlayerCoords") end,
              write = function(v) SetCVarOn("worldMapShowPlayerCoords", v) end },
            { key = "wmCursorCoords", type = "check", label = "Cursor Coordinates",
              tip = "Where the mouse is over the map. The same as the game's setting.",
              read = function() return CVarOn("worldMapShowCursorCoords") end,
              write = function(v) SetCVarOn("worldMapShowCursorCoords", v) end },
            { type = "header", label = "UNEXPLORED AREAS" },
            { key = "wmReveal", type = "check", default = true, label = "Show Unexplored Areas",
              tip = "Lifts the fog from the parts of each zone you haven't been to yet." },
            { key = "wmRevealTint", type = "check", default = false, label = "Tint Them",
              tip = "So you can still tell which parts you haven't explored.",
              when = function(s) return s.wmReveal end },
            { key = "wmRevealColor", type = "color", default = { r = 0.6, g = 0.6, b = 0.6 }, label = "Tint Colour",
              when = function(s) return s.wmReveal and s.wmRevealTint end },
            { key = "wmRevealAlpha", type = "slider", default = 1, min = 0.1, max = 1, step = 0.05,
              label = "Their Opacity", when = function(s) return s.wmReveal end },
        } },
    },
})

function BH:BuildWorldMapTab(parent)
    ns.Settings.Build(WM.SETTINGS, parent)
end

-- ============================================================================
-- Fading
-- ============================================================================

local fader = CreateFrame("Frame")
fader:Hide()
local current, target, from, elapsedFade, fadeTime = 1, 1, 1, 0, 0.2

local function Target()
    local map = Map()
    local s = Settings()
    if not map then return 1 end
    if not (Active() and s.wmFade) then return 1 end
    if IsPlayerMoving() and not map:IsMouseOver() then return s.wmFadeAlpha or 0.2 end
    return 1
end

local tick = 0
fader:SetScript("OnUpdate", function(_, elapsed)
    local map = Map()
    if not map or not map:IsShown() then
        fader:Hide()
        return
    end
    tick = tick + elapsed
    if tick >= 0.05 then
        tick = 0
        local t = Target()
        if t ~= target then
            target, from, elapsedFade = t, current, 0
            fadeTime = Settings().wmFadeTime or 0.2
        end
    end
    if current ~= target then
        elapsedFade = elapsedFade + elapsed
        local p = fadeTime > 0 and math.min(elapsedFade / fadeTime, 1) or 1
        current = from + (target - from) * p
        map:SetAlpha(current)
    end
end)

local function StartFader()
    local map = Map()
    if not map then return end
    if PlayerMovementFrameFader and PlayerMovementFrameFader.RemoveFrame then
        PlayerMovementFrameFader.RemoveFrame(map)
    end
    current = map:GetAlpha()
    target = current
    fader:Show()
end

-- ============================================================================
-- Scale and backdrop
-- ============================================================================

local function Place()
    local map = Map()
    if not (map and Active()) or InCombatLockdown() then return end
    local maximized = map.IsMaximized and map:IsMaximized()
    map:SetScale(maximized and 1 or (Settings().wmScale or 1))
    local blackout = map.BlackoutFrame
    if blackout then
        local clear = Settings().wmNoBlackout ~= false
        if blackout.Blackout then blackout.Blackout:SetAlpha(clear and 0 or 1) end
        blackout:EnableMouse(not clear)
    end
end

-- ============================================================================
-- Unexplored areas
-- ============================================================================

-- ns.RevealData[artID] holds strings; each is parsed once, on first use.
local parsed = {}
local function Areas(artID)
    local list = parsed[artID]
    if list then return list end
    list = {}
    local raw = ns.RevealData and ns.RevealData[artID]
    for _, line in ipairs(raw or {}) do
        local w, h, x, y, ids = line:match("^(%d+):(%d+):(%d+):(%d+):(.+)$")
        if w then
            local files = {}
            for id in ids:gmatch("%d+") do files[#files + 1] = tonumber(id) end
            list[#list + 1] = { key = w .. ":" .. h .. ":" .. x .. ":" .. y, w = tonumber(w), h = tonumber(h),
                                x = tonumber(x), y = tonumber(y), files = files }
        end
    end
    parsed[artID] = list
    return list
end

local pools = {}

local function ClearReveal(pin)
    local pool = pools[pin]
    if pool then pool:ReleaseAll() end
end

-- The last tile of a row or column is cut from a power-of-two file, as
-- Blizzard's own exploration pin does.
local function FileSize(pixels)
    local size = 16
    while size < pixels do size = size * 2 end
    return size
end

local function Reveal(pin)
    ClearReveal(pin)
    local s = Settings()
    if not (Active() and s.wmReveal) then return end
    local map = pin.GetMap and pin:GetMap()
    if not map then return end
    local mapID = map:GetMapID()
    if not mapID then return end
    local artID = C_Map.GetMapArtID(mapID)
    local areas = artID and Areas(artID)
    if not areas or #areas == 0 then return end

    local layers = C_Map.GetMapArtLayers(mapID)
    local layer = layers and layers[map:GetCanvasContainer():GetCurrentLayerIndex()]
    if not layer then return end
    local tileW, tileH = layer.tileWidth, layer.tileHeight

    local explored = {}
    for _, info in ipairs(C_MapExplorationInfo.GetExploredMapTextures(mapID) or {}) do
        explored[info.textureWidth .. ":" .. info.textureHeight .. ":" .. info.offsetX .. ":" .. info.offsetY] = true
    end

    local drawLayer, subLevel = "ARTWORK", 0
    if pin.dataProvider and pin.dataProvider.GetDrawLayer then
        drawLayer, subLevel = pin.dataProvider:GetDrawLayer()
    end
    local pool = pools[pin]
    if not pool then
        pool = CreateTexturePool(pin, drawLayer, subLevel)
        pools[pin] = pool
    end
    local tint, c = s.wmRevealTint, s.wmRevealColor or { r = 0.6, g = 0.6, b = 0.6 }
    local alpha = s.wmRevealAlpha or 1

    for _, a in ipairs(areas) do
        if not explored[a.key] then
            local wide, tall = math.ceil(a.w / tileW), math.ceil(a.h / tileH)
            for j = 1, tall do
                local ph, fh = tileH, tileH
                if j == tall then
                    ph = a.h % tileH
                    if ph == 0 then ph = tileH end
                    fh = FileSize(ph)
                end
                for k = 1, wide do
                    local file = a.files[(j - 1) * wide + k]
                    if file then
                        local pw, fw = tileW, tileW
                        if k == wide then
                            pw = a.w % tileW
                            if pw == 0 then pw = tileW end
                            fw = FileSize(pw)
                        end
                        local tex = pool:Acquire()
                        map:AddMaskableTexture(tex)
                        tex:SetDrawLayer(drawLayer, subLevel)
                        tex:SetSize(pw, ph)
                        tex:SetTexCoord(0, pw / fw, 0, ph / fh)
                        tex:ClearAllPoints()
                        tex:SetPoint("TOPLEFT", a.x + tileW * (k - 1), -(a.y + tileH * (j - 1)))
                        tex:SetTexture(file, nil, nil, "TRILINEAR")
                        if tint then
                            tex:SetVertexColor(c.r, c.g, c.b)
                        else
                            tex:SetVertexColor(1, 1, 1)
                        end
                        tex:SetAlpha(alpha)
                        tex:Show()
                    end
                end
            end
        end
    end
end

local hookedPins = {}
local function ForEachPin(fn)
    local map = Map()
    if not (map and map.EnumeratePinsByTemplate) then return end
    for pin in map:EnumeratePinsByTemplate("MapExplorationPinTemplate") do fn(pin) end
end

local function HookPins()
    ForEachPin(function(pin)
        if hookedPins[pin] then return end
        hookedPins[pin] = true
        hooksecurefunc(pin, "RefreshOverlays", Reveal)
        hooksecurefunc(pin, "RemoveAllData", ClearReveal)
    end)
end

-- ============================================================================
-- Apply
-- ============================================================================

local hooked
local function Hook()
    local map = Map()
    if hooked or not map then return end
    hooked = true
    map:HookScript("OnShow", function()
        if not Active() then return end
        -- Blizzard adds the map to its own fader on every show; take it off again
        -- once that has run.
        C_Timer.After(0, function()
            if Active() and Settings().wmFade then StartFader() end
        end)
        Place()
    end)
    map:HookScript("OnHide", function() fader:Hide() end)
    if EventRegistry then
        EventRegistry:RegisterCallback("WorldMapMinimized", Place, WM)
        EventRegistry:RegisterCallback("WorldMapMaximized", Place, WM)
    end
end

function WM.Apply()
    if not Active() then return end
    Hook()
    WM.styled = true
    Place()
    HookPins()
    ForEachPin(Reveal)
    local map = Map()
    if map and map:IsShown() then
        if Settings().wmFade then
            StartFader()
        else
            fader:Hide()
            map:SetAlpha(1)
        end
    end
end

-- ============================================================================
-- ElvUI's and WindTools' world map, copied once per profile
-- ============================================================================

local function Seed()
    local s = BH.settings
    if not s or s.wmSeededFromElvUI then return end
    local E = Elv()
    if not (E and E.global and E.private) then return end
    s.wmSeededFromElvUI = true
    if WM.ElvUIOn() then s.wmEnabled = true end
    local g = E.global.general
    if type(g) == "table" then
        if g.fadeMapWhenMoving ~= nil then s.wmFade = g.fadeMapWhenMoving and true or false end
        if tonumber(g.mapAlphaWhenMoving) then s.wmFadeAlpha = tonumber(g.mapAlphaWhenMoving) end
        if tonumber(g.fadeMapDuration) then s.wmFadeTime = tonumber(g.fadeMapDuration) end
        if g.smallerWorldMap ~= nil then s.wmNoBlackout = g.smallerWorldMap and true or false end
        local c = g.WorldMapCoordinates
        if E.private.general and E.private.general.worldMap and type(c) == "table" and c.enable then
            SetCVarOn("worldMapShowPlayerCoords", true)
            SetCVarOn("worldMapShowCursorCoords", true)
        end
    end
    local wt = E.private.WT and E.private.WT.maps and E.private.WT.maps.worldMap
    if C_AddOns.IsAddOnLoaded("ElvUI_WindTools") and type(wt) == "table" and wt.enable
        and type(wt.scale) == "table" and wt.scale.enable and tonumber(wt.scale.size) then
        s.wmScale = tonumber(wt.scale.size)
    end
    BH:SaveSettings()
end

-- WindTools' reveal settings: their own flag, as the first copy shipped
-- without them and has already run on existing profiles.
local function SeedReveal()
    local s = BH.settings
    if not s or s.wmRevealSeededFromWT then return end
    local E = Elv()
    if not (E and E.private) then return end
    s.wmRevealSeededFromWT = true
    local wt = E.private.WT and E.private.WT.maps and E.private.WT.maps.worldMap
    if not (C_AddOns.IsAddOnLoaded("ElvUI_WindTools") and type(wt) == "table" and type(wt.reveal) == "table") then
        BH:SaveSettings()
        return
    end
    local r = wt.reveal
    -- Its own switch only: WindTools' world map has to be off for ours to run.
    if r.enable ~= nil then s.wmReveal = r.enable and true or false end
    if r.useColor ~= nil then s.wmRevealTint = r.useColor and true or false end
    if type(r.color) == "table" and tonumber(r.color.r) then
        s.wmRevealColor = { r = tonumber(r.color.r), g = tonumber(r.color.g) or 1, b = tonumber(r.color.b) or 1 }
        if tonumber(r.color.a) then s.wmRevealAlpha = tonumber(r.color.a) end
    end
    BH:SaveSettings()
end

function BH:ApplyWorldMap()
    Seed()
    SeedReveal()
    WM.Apply()
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_REGEN_ENABLED")
ev:SetScript("OnEvent", function(_, event, arg)
    if event == "ADDON_LOADED" and arg ~= "Blizzard_WorldMap" then return end
    BH:ApplyWorldMap()
end)
