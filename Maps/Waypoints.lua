-- Maps/Waypoints.lua
-- Blizzard's map pin and the arrow that guides you to it: the pin tracked as
-- soon as you place it, middle-click on it to clear it, the arrow shown at any
-- distance, the distance in your font and colour (with or without "yds", the
-- full number past 1,000), and /way taking coordinates as guide sites write
-- them ("/way 45.2 67.1" for the zone you are in, "/way #2248 45.2, 67.1").
--
-- WindTools' Super Tracker was read for behaviour only. Blizzard's own /way
-- (its map pin command) wants "mapID x y"; ours accepts more and hands
-- anything it doesn't understand back to Blizzard's. Left alone while TomTom
-- is loaded, which has its own /way.
--
-- Works on retail and WoW Forever. Waits while WindTools' Super Tracker is on.

local addonName, ns = ...
local BH = ns.BH

local WP = {}
ns.Waypoints = WP

local function Elv()
    local elv = _G["ElvUI"]
    return C_AddOns.IsAddOnLoaded("ElvUI") and type(elv) == "table" and elv[1] or nil
end

local function WTSuperTracker()
    if not C_AddOns.IsAddOnLoaded("ElvUI_WindTools") then return nil end
    local E = Elv()
    local wt = E and E.private and E.private.WT and E.private.WT.maps
    return wt and type(wt.superTracker) == "table" and wt.superTracker or nil
end

function WP.ElvUIOn()
    local st = WTSuperTracker()
    return st and st.enable and true or false
end

local settingsView = setmetatable({}, { __index = function(_, k)
    local s = BH.settings
    local v = s and s[k]
    if v == nil and BH.defaultSettings then v = BH.defaultSettings[k] end
    return v
end })
local function Settings() return settingsView end
local function Active() return BH.settings and BH.settings.wpEnabled and not WP.ElvUIOn() end
local function Apply() if WP.Apply then WP.Apply() end end

local OUTLINES = {
    { text = "None", value = "NONE" }, { text = "Shadow", value = "SHADOW" },
    { text = "Outline", value = "OUTLINE" }, { text = "Thick outline", value = "THICKOUTLINE" },
}
local function Fonts() return BH:BuildFontDropdownItems() end
local function Styled(s) return s.wpText end

-- ============================================================================
-- Settings
-- ============================================================================

local reloadAsked
WP.SETTINGS = ns.Settings.Describe({
    master = "wpEnabled",
    apply = Apply,
    pages = {
        { key = "general", label = "General", rows = {
            { key = "wpEnabled", type = "check", default = false, label = "Improve Map Pins",
              tip = "Blizzard's map pin and the arrow that guides you to it.\n\nWaits while WindTools' Super "
                .. "Tracker is on (WindTools > Maps > Super Tracker, then /reload).",
              apply = function(v)
                  if v and WP.ElvUIOn() then
                      print("|cff33cc99Squizzumables:|r WindTools' Super Tracker is still on. Turn it off there, "
                          .. "/reload, and this takes over.")
                  elseif not v and WP.styled and not reloadAsked then
                      reloadAsked = true
                      print("|cff33cc99Squizzumables:|r the map pin arrow is back to Blizzard's after a /reload.")
                  end
              end },
            { key = "wpAutoTrack", type = "check", default = true, label = "Track a Pin as Soon as You Place It",
              tip = "So the arrow appears straight away, without clicking the pin again." },
            { key = "wpMiddleClear", type = "check", default = true, label = "Middle-Click a Pin to Remove It" },
            { key = "wpAnyDistance", type = "check", default = false, label = "Show the Arrow at Any Distance",
              tip = "Blizzard hides it while the pin is more than 1,000 yards away." },
            { key = "wpWay", type = "check", default = true, label = "/way Takes Guide-Site Coordinates",
              tip = "\"/way 45.2 67.1\" for the zone you're in, \"/way #2248 45.2, 67.1\" for another, with or "
                .. "without commas, and a note after the numbers is ignored. Not while TomTom is loaded." },
            { type = "header", label = "DISTANCE" },
            { key = "wpText", type = "check", default = true, label = "Style the Distance",
              tip = "Under the arrow." },
            { key = "wpNoUnit", type = "check", default = true, label = "Number Only (No \"yds\")", when = Styled },
            { key = "wpFullNumber", type = "check", default = true, label = "Full Number Past 1,000",
              tip = "1234 instead of 1.2K.", when = Styled },
            { key = "wpFont", type = "dropdown", default = "__default", items = Fonts, label = "Font", when = Styled },
            { key = "wpSize", type = "slider", default = 14, min = 6, max = 30, step = 1, label = "Size",
              when = Styled },
            { key = "wpOutline", type = "dropdown", default = "OUTLINE", items = OUTLINES, label = "Outline",
              when = Styled },
            { key = "wpColor", type = "color", default = { r = 1, g = 1, b = 1 }, label = "Colour", when = Styled },
        } },
    },
})

function BH:BuildWaypointsTab(parent)
    ns.Settings.Build(WP.SETTINGS, parent)
end

-- ============================================================================
-- Distance text
-- ============================================================================

local function ResolveFont(name)
    if name and name ~= "__default" then
        local lsm = LibStub and LibStub("LibSharedMedia-3.0", true)
        local path = lsm and lsm:Fetch("font", name, true)
        if path then return path end
    end
    return STANDARD_TEXT_FONT
end

local origFont, origSize, origFlags
local function StyleText()
    local frame = _G.SuperTrackedFrame
    local fs = frame and frame.DistanceText
    if not fs then return end
    if not origFont then origFont, origSize, origFlags = fs:GetFont() end
    local s = Settings()
    if Active() and s.wpText then
        local outline = s.wpOutline or "OUTLINE"
        fs:SetFont(ResolveFont(s.wpFont), s.wpSize or 14,
            (outline == "OUTLINE" or outline == "THICKOUTLINE") and outline or "")
        local shadow = outline == "SHADOW"
        fs:SetShadowOffset(shadow and 1 or 0, shadow and -1 or 0)
        fs:SetShadowColor(0, 0, 0, shadow and 1 or 0)
        local c = s.wpColor or { r = 1, g = 1, b = 1 }
        fs:SetTextColor(c.r, c.g, c.b)
    elseif origFont and origSize then
        fs:SetFont(origFont, origSize, origFlags or "")
    end
end

local rewriting
local function OnDistanceText(fs)
    if rewriting or not Active() then return end
    local s = Settings()
    if not s.wpText then return end
    local d = C_Navigation and C_Navigation.GetDistance and C_Navigation.GetDistance()
    if not canaccessvalue(d) then return end
    if type(d) ~= "number" then return end
    d = math.floor(d + 0.5)
    local num = (d < 1000 or s.wpFullNumber ~= false) and tostring(d) or AbbreviateNumbers(d)
    local text = s.wpNoUnit ~= false and num or (IN_GAME_NAVIGATION_RANGE or "%s yds"):format(num)
    rewriting = true
    fs:SetText(text)
    rewriting = false
end

-- ============================================================================
-- The arrow past 1,000 yards
-- ============================================================================

local origAlpha
local function AnyDistance()
    local frame = _G.SuperTrackedFrame
    if not (frame and frame.GetTargetAlphaBaseValue) then return end
    if Active() and Settings().wpAnyDistance then
        if origAlpha then return end
        origAlpha = frame.GetTargetAlphaBaseValue
        local orig = origAlpha
        frame.GetTargetAlphaBaseValue = function(self)
            local d = C_Navigation.GetDistance()
            if canaccessvalue(d) and type(d) == "number" and d > 999 then return 1 end
            return orig(self)
        end
    elseif origAlpha then
        -- Mixin copied the method onto the frame, so put Blizzard's back.
        frame.GetTargetAlphaBaseValue = origAlpha
        origAlpha = nil
    end
end

-- ============================================================================
-- Pins on the map
-- ============================================================================

local hookedPins = {}
local function HookPins()
    local map = _G.WorldMapFrame
    if not (map and map.EnumeratePinsByTemplate) then return end
    for pin in map:EnumeratePinsByTemplate("WaypointLocationPinTemplate") do
        if not hookedPins[pin] then
            hookedPins[pin] = true
            hooksecurefunc(pin, "OnMouseClickAction", function(_, button)
                if button == "MiddleButton" and Active() and Settings().wpMiddleClear then
                    C_Map.ClearUserWaypoint()
                end
            end)
        end
    end
end

-- ============================================================================
-- /way
-- ============================================================================

-- Accepts "[#mapID] x y [note]", with commas or spaces. Returns nothing when
-- the text isn't coordinates, so Blizzard's own command can try it.
local function Parse(msg)
    msg = (msg or ""):gsub(",", " "):gsub("^%s+", "")
    local mapID
    local hash = msg:match("^#(%d+)%s+")
    if hash then
        mapID = tonumber(hash)
        msg = msg:gsub("^#%d+%s+", "")
    end
    local a, b, c = msg:match("^([%d%.]+)%s+([%d%.]+)%s*([%d%.]*)")
    if not a then return end
    local wholeFirst = not a:find(".", 1, true)
    a, b, c = tonumber(a), tonumber(b), tonumber(c)
    if not (a and b) then return end
    if c and not mapID and wholeFirst then
        -- "mapID x y" (three numbers, the first whole), as Blizzard copies its pins.
        mapID, a, b = a, b, c
    end
    mapID = mapID or C_Map.GetBestMapForUnit("player")
    if not mapID or a > 100 or b > 100 then return end
    return mapID, a / 100, b / 100
end

local origWay
local function Way(msg)
    if Active() and Settings().wpWay then
        local mapID, x, y = Parse(msg)
        if mapID then
            if not C_Map.CanSetUserWaypointOnMap(mapID) then
                print("|cff33cc99Squizzumables:|r a pin can't be placed on that map.")
                return
            end
            C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(mapID, x, y))
            C_SuperTrack.SetSuperTrackedUserWaypoint(true)
            local info = C_Map.GetMapInfo(mapID)
            print(("|cff33cc99Squizzumables:|r pin placed in %s at %.1f, %.1f."):format(
                info and info.name or "?", x * 100, y * 100))
            return
        end
    end
    if origWay then origWay(msg) end
end

local function HookWay()
    if origWay or C_AddOns.IsAddOnLoaded("TomTom") then return end
    origWay = SlashCmdList.MAPPIN
    if origWay then SlashCmdList.MAPPIN = Way end
end

-- ============================================================================
-- Apply
-- ============================================================================

local hooked
local function Hook()
    local frame = _G.SuperTrackedFrame
    if hooked or not frame then return end
    hooked = true
    if frame.DistanceText then hooksecurefunc(frame.DistanceText, "SetText", OnDistanceText) end
    local map = _G.WorldMapFrame
    if map then map:HookScript("OnShow", HookPins) end
end

function WP.Apply()
    if not Active() then
        AnyDistance()
        return
    end
    WP.styled = true
    Hook()
    HookPins()
    HookWay()
    StyleText()
    AnyDistance()
    local frame = _G.SuperTrackedFrame
    if frame and frame.DistanceText and frame.DistanceText:IsShown() then
        OnDistanceText(frame.DistanceText)
    end
end

-- ============================================================================
-- WindTools' Super Tracker, copied once per profile
-- ============================================================================

local function MapOutline(o)
    if o == "OUTLINE" or o == "THICKOUTLINE" or o == "NONE" or o == "SHADOW" then return o end
    if type(o) == "string" and o:find("OUTLINE") then return "OUTLINE" end
    return nil
end

local function Seed()
    local s = BH.settings
    if not s or s.wpSeededFromWT then return end
    local st = WTSuperTracker()
    if not st then return end
    s.wpSeededFromWT = true
    if st.enable then s.wpEnabled = true end
    if st.autoTrackWaypoint ~= nil then s.wpAutoTrack = st.autoTrackWaypoint and true or false end
    if st.middleClickToClear ~= nil then s.wpMiddleClear = st.middleClickToClear and true or false end
    if st.noLimit ~= nil then s.wpAnyDistance = st.noLimit and true or false end
    if st.noUnit ~= nil then s.wpNoUnit = st.noUnit and true or false end
    local dt = st.distanceText
    if type(dt) == "table" then
        if dt.enable ~= nil then s.wpText = dt.enable and true or false end
        local lsm = LibStub and LibStub("LibSharedMedia-3.0", true)
        if type(dt.name) == "string" and lsm and lsm:IsValid("font", dt.name) then s.wpFont = dt.name end
        if tonumber(dt.size) then s.wpSize = tonumber(dt.size) end
        s.wpOutline = MapOutline(dt.style) or s.wpOutline
        if type(dt.color) == "table" and tonumber(dt.color.r) then
            s.wpColor = { r = tonumber(dt.color.r), g = tonumber(dt.color.g) or 1, b = tonumber(dt.color.b) or 1 }
        end
    end
    if type(st.waypointParse) == "table" and st.waypointParse.enable ~= nil then
        s.wpWay = st.waypointParse.enable and true or false
    end
    BH:SaveSettings()
end

function BH:ApplyWaypoints()
    Seed()
    WP.Apply()
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("USER_WAYPOINT_UPDATED")
ev:SetScript("OnEvent", function(_, event, arg)
    if event == "USER_WAYPOINT_UPDATED" then
        if Active() and Settings().wpAutoTrack and C_Map.HasUserWaypoint() then
            C_Timer.After(0.1, function()
                if C_Map.HasUserWaypoint() then C_SuperTrack.SetSuperTrackedUserWaypoint(true) end
            end)
        end
        return
    end
    if event == "ADDON_LOADED" and arg ~= "Blizzard_QuestNavigation" and arg ~= "Blizzard_WorldMap" then return end
    BH:ApplyWaypoints()
end)
