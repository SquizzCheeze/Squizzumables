-- Maps/MinimapButtons.lua
-- The addon icons that sit round the minimap, gathered into one bar you place
-- in Edit Mode: LibDBIcon buttons (most addons) and other addons' own named
-- minimap buttons, each squared off with a 1px border, laid out in rows, the
-- bar optionally shown only on mouseover. Blizzard's own minimap pieces are
-- left where they are (the Minimap page places those).
--
-- The replacement for WindTools' Minimap Buttons, whose code was read for
-- behaviour only. Waits while WindTools' is on. Turning this off needs a
-- /reload to give the buttons back to the minimap.
--
-- A gathered button is an addon's plain (non-secure) frame. Its own code keeps
-- trying to put it back round the minimap (LibDBIcon on every refresh and
-- drag), so its ClearAllPoints / SetPoint are replaced on that one frame by
-- no-ops and the bar places it through the real methods.

local addonName, ns = ...
local BH = ns.BH

local MB = {}
ns.MinimapButtons = MB

local settingsView = setmetatable({}, { __index = function(_, k)
    local s = BH.settings
    local v = s and s[k]
    if v == nil and BH.defaultSettings then v = BH.defaultSettings[k] end
    return v
end })
local function Settings() return settingsView end

-- WindTools keeps this switch in its private (per-character) settings.
function MB.WindToolsOn()
    if not C_AddOns.IsAddOnLoaded("ElvUI_WindTools") then return false end
    local elv = _G["ElvUI"]
    local E = type(elv) == "table" and elv[1]
    local p = E and E.private and E.private.WT and E.private.WT.maps and E.private.WT.maps.minimapButtons
    return type(p) == "table" and p.enable and true or false
end

local function Active() return BH.settings and BH.settings.mbEnabled and not MB.WindToolsOn() and Minimap ~= nil end
local function Apply() if MB.Apply then MB.Apply() end end

-- ============================================================================
-- Settings
-- ============================================================================

local reloadAsked
MB.SETTINGS = ns.Settings.Describe({
    master = "mbEnabled",
    apply = Apply,
    pages = {
        { key = "general", label = "General", rows = {
            { key = "mbEnabled", type = "check", default = false, label = "Gather Minimap Buttons",
              tip = "Every addon's minimap icon in one bar you place in Edit Mode, instead of round the minimap.\n\n"
                .. "Waits while WindTools' Minimap Buttons is on (WindTools > Maps > Minimap Buttons, then /reload).",
              apply = function(v)
                  if v and MB.WindToolsOn() then
                      print("|cff33cc99Squizzumables:|r WindTools' Minimap Buttons is still on. Turn it off in "
                          .. "WindTools, /reload, and this takes over.")
                  elseif not v and MB.gathered and not reloadAsked then
                      reloadAsked = true
                      print("|cff33cc99Squizzumables:|r the buttons go back round the minimap after a /reload.")
                  end
              end },
            { key = "mbSize", type = "slider", default = 28, min = 16, max = 48, step = 1, label = "Button Size" },
            { key = "mbSpacing", type = "slider", default = 2, min = 0, max = 12, step = 1, label = "Spacing" },
            { key = "mbPerRow", type = "slider", default = 6, min = 1, max = 20, step = 1, label = "Buttons per Row",
              tip = "Per column when the bar runs down." },
            { key = "mbVertical", type = "check", default = false, label = "Run Down Instead of Across" },
            { key = "mbBackdrop", type = "check", default = true, label = "Bar Background" },
            { key = "mbMouseOver", type = "check", default = false, label = "Show Only on Mouseover" },
            { type = "header", label = "LEAVE ON THE MINIMAP" },
            { key = "mbIgnore", type = "editbox", default = "", label = "Buttons to Leave Alone",
              tip = "Part of a button's name, commas between several (for example: Questie, TomTom). "
                .. "Names are the frame names, which /fstack shows. Needs a /reload to give one back." },
        } },
    },
})

function BH:BuildMinimapButtonsTab(parent)
    ns.Settings.Build(MB.SETTINGS, parent)
end

-- ============================================================================
-- Which buttons
-- ============================================================================

-- Blizzard's own pieces and the minimap's frames.
local BLIZZARD = {
    GameTimeFrame = true, TimeManagerClockButton = true, QueueStatusButton = true,
    ExpansionLandingPageMinimapButton = true, GarrisonLandingPageMinimapButton = true,
    AddonCompartmentFrame = true, HelpOpenTicketButton = true, HelpOpenWebTicketButton = true,
}
-- Name starts: map pins and markers from gathering / guide addons, which are
-- buttons on the minimap but belong where they are.
local PIN_STARTS = {
    "Minimap", "MiniMap", "Archy", "GatherMatePin", "GatherNote", "GuildInstance", "HandyNotesPin", "MinimMap",
    "Spy_MapNoteList_mini", "ZGVMarker", "poiMinimap", "GuildMap3Mini", "NauticusMiniIcon", "WestPointer",
    "Cork", "DugisArrowMinimapPoint", "TTMinimapButton", "QuestieFrame", "RXPGuides",
}
local PIN_PARTS = { "Pin", "Node", "Note", "POI" }

-- The frame-art textures LibDBIcon and most hand-made buttons carry.
local ART_IDS = { [136430] = true, [136467] = true, [136477] = true }
local ART_WORDS = { "trackingborder", "minimap%-background", "zoombutton%-highlight", "minimapbutton%-border" }

local function UserIgnored(name)
    local list = Settings().mbIgnore
    if type(list) ~= "string" or list == "" then return false end
    local lower = name:lower()
    for part in list:gmatch("[^,]+") do
        part = strtrim(part):lower()
        if part ~= "" and lower:find(part, 1, true) then return true end
    end
    return false
end

local function Wanted(frame)
    if not frame.GetName or (frame.IsForbidden and frame:IsForbidden()) then return false end
    if frame.IsProtected and frame:IsProtected() then return false end
    local name = frame:GetName()
    if not name or BLIZZARD[name] then return false end
    if not frame:IsObjectType("Button") then return false end
    -- Ours is a minimap icon like any addon's.
    if name ~= "SquizzumablesMinimapButton" then
        if name:find("^Squizzumables") or name:find("^SquizzFrames") then return false end
        for _, s in ipairs(PIN_STARTS) do
            if name:sub(1, #s) == s then return false end
        end
        if not name:find("^LibDBIcon") then
            for _, p in ipairs(PIN_PARTS) do
                if name:find(p, 1, true) then return false end
            end
        end
    end
    if UserIgnored(name) then return false end
    -- Something the size of a panel is not an icon.
    local w, h = frame:GetSize()
    if (w or 0) > 64 or (h or 0) > 64 then return false end
    return true
end

-- ============================================================================
-- The bar
-- ============================================================================

local bar, mover
local buttons = {}   -- gathered, in the order found
local taken = {}     -- button -> { SetPoint, ClearAllPoints }
local DEFAULT_POS = nil  -- nil: beside the minimap until placed

local function SavePosition()
    local left, top = bar:GetLeft(), bar:GetTop()
    if not left then return end
    BH.settings.mbPosition = { point = "TOPLEFT", relPoint = "TOPLEFT",
        x = math.floor(left + 0.5), y = math.floor(top - UIParent:GetHeight() + 0.5) }
    BH:SaveSettings()
end

function MB.Nudge(dx, dy)
    local s = BH.settings
    if not s then return end
    if not s.mbPosition then SavePosition() end
    local pos = s.mbPosition
    if not pos then return end
    s.mbPosition = { point = pos.point, relPoint = pos.relPoint, x = (pos.x or 0) + dx, y = (pos.y or 0) + dy }
    BH:SaveSettings()
    Apply()
end

local fadeElapsed = 0
local function FadeTick(_, dt)
    fadeElapsed = fadeElapsed + dt
    if fadeElapsed < 0.1 then return end
    fadeElapsed = 0
    local want = (BH.unlockMode or bar:IsMouseOver(4, -4, -4, 4)) and 1 or 0
    local a = bar:GetAlpha()
    if a ~= want then bar:SetAlpha(want > a and math.min(1, a + 0.34) or math.max(0, a - 0.34)) end
end

local function Build()
    if bar then return end
    bar = CreateFrame("Frame", "SquizzumablesMinimapButtonBar", UIParent)
    bar:SetMovable(true)
    bar:SetClampedToScreen(true)
    bar:SetFrameStrata("MEDIUM")
    bar:SetFrameLevel(10)
    bar:SetSize(30, 30)

    mover = CreateFrame("Frame", "SquizzumablesMinimapButtonMover", UIParent)
    mover:SetAllPoints(bar)
    mover:SetFrameStrata("HIGH")
    mover:RegisterForDrag("LeftButton")
    mover:SetScript("OnDragStart", function()
        if InCombatLockdown() or not BH.unlockMode then return end
        BH:GridStartMoving(bar)
    end)
    mover:SetScript("OnDragStop", function()
        BH:GridStopMoving(bar)
        SavePosition()
        Apply()
    end)
    mover:Hide()
    BH.minimapButtonMover = mover
end

-- ============================================================================
-- One button
-- ============================================================================

local function IsArt(r)
    local id = r.GetTextureFileID and r:GetTextureFileID()
    if id and ART_IDS[id] then return true end
    local path = r.GetTextureFilePath and r:GetTextureFilePath()
    if type(path) == "string" then
        path = path:lower()
        for _, w in ipairs(ART_WORDS) do
            if path:find(w) then return true end
        end
    end
    return false
end

-- The button's picture: LibDBIcon's .icon, a hand-made button's Icon, or the
-- one texture left once the frame art is set aside.
local function FindIcon(btn)
    local name = btn:GetName()
    local icon = btn.icon or btn.Icon or (name and (_G[name .. "Icon"] or _G[name .. "IconTexture"]))
    if icon and icon.IsObjectType and icon:IsObjectType("Texture") then return icon end
    -- A real icon file first, then whatever sits on the ARTWORK layer, then
    -- anything that is not frame art.
    local hl = btn:GetHighlightTexture()
    local artwork, other
    for _, r in ipairs({ btn:GetRegions() }) do
        if r:IsObjectType("Texture") and r ~= hl and r:GetDrawLayer() ~= "HIGHLIGHT" and not IsArt(r) then
            local path = r.GetTextureFilePath and r:GetTextureFilePath()
            if type(path) == "string" and path:lower():find("interface[/\\]icons[/\\]") then return r end
            if not artwork and r:GetDrawLayer() == "ARTWORK" then artwork = r end
            other = other or r
        end
    end
    return artwork or other
end

local CROP = { 0.08, 0.92, 0.08, 0.92 }

-- LibDBIcon nudges the picture's corners on press and release; keep it
-- cropped unless the addon set coordinates of its own.
local function KeepCropped(icon)
    local busy
    hooksecurefunc(icon, "SetTexCoord", function(self, a, b, c, d)
        if busy then return end
        if d == nil then return end
        local full = a <= 0.06 and b >= 0.94 and c <= 0.06 and d >= 0.94
        if full then
            busy = true
            self:SetTexCoord(CROP[1], CROP[2], CROP[3], CROP[4])
            busy = false
        end
    end)
end

local function Take(btn)
    if taken[btn] then return end
    local SK = ns.Skins
    -- The real placement methods, kept for the bar; the button's own copies
    -- stop it being put back round the minimap.
    taken[btn] = { SetPoint = btn.SetPoint, ClearAllPoints = btn.ClearAllPoints, SetParent = btn.SetParent }
    local noop = function() end
    btn.SetPoint = noop
    btn.ClearAllPoints = noop
    btn:SetScript("OnDragStart", nil)
    btn:SetScript("OnDragStop", nil)
    btn:SetScale(1)

    local icon = FindIcon(btn)
    for _, r in ipairs({ btn:GetRegions() }) do
        if r:IsObjectType("Texture") and r ~= icon then
            if r == btn:GetHighlightTexture() then
                r:SetColorTexture(1, 1, 1, 0.2)
            else
                -- Rings, dark discs and glows the addon drew round its
                -- picture: on a square tile they only dim it.
                r:SetAlpha(0)
            end
        end
    end
    if btn.GetPushedTexture and btn:GetPushedTexture() then btn:GetPushedTexture():SetAlpha(0) end
    if icon then
        icon:ClearAllPoints()
        icon:SetPoint("TOPLEFT", btn, "TOPLEFT", 1, -1)
        icon:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -1, 1)
        local l, r, t, b = icon:GetTexCoord()
        if l and l <= 0.06 and r >= 0.94 then icon:SetTexCoord(CROP[1], CROP[2], CROP[3], CROP[4]) end
        KeepCropped(icon)
        local hl = btn:GetHighlightTexture()
        if hl then hl:SetAllPoints(icon) end
    end
    if SK and SK.Backdrop then
        SK.Backdrop(btn, "button")
        if SK.Hover then SK.Hover(btn) end
    end
    -- Shown and hidden by its addon (LibDBIcon's per-addon hide): re-lay.
    btn:HookScript("OnShow", function() MB.Layout() end)
    btn:HookScript("OnHide", function() MB.Layout() end)
    buttons[#buttons + 1] = btn
    MB.gathered = true
end

local function Collect(parent)
    if not parent or not parent.GetChildren then return end
    for _, child in ipairs({ parent:GetChildren() }) do
        if not taken[child] and Wanted(child) then Take(child) end
    end
end

function MB.Scan()
    if not Active() then return end
    Build()
    Collect(Minimap)
    Collect(_G.MinimapBackdrop)
    Collect(_G.MinimapCluster)
    local dbi = LibStub and LibStub("LibDBIcon-1.0", true)
    -- name -> button, every LibDBIcon icon made so far.
    if dbi and type(dbi.objects) == "table" then
        for _, btn in pairs(dbi.objects) do
            if not taken[btn] and Wanted(btn) then Take(btn) end
        end
    end
    MB.Layout()
end

-- ============================================================================
-- Layout
-- ============================================================================

local function SortName(btn)
    local n = btn:GetName() or ""
    return (n:gsub("^LibDBIcon10_", "")):lower()
end

function MB.Layout()
    if not bar or not Active() then return end
    local s = Settings()
    local size, gap = s.mbSize or 28, s.mbSpacing or 2
    local perRow = math.max(1, s.mbPerRow or 6)
    local pad = s.mbBackdrop ~= false and 3 or 0

    local shown = {}
    for _, btn in ipairs(buttons) do
        if btn:IsShown() then shown[#shown + 1] = btn end
    end
    table.sort(shown, function(a, b) return SortName(a) < SortName(b) end)

    for i, btn in ipairs(shown) do
        local m = taken[btn]
        m.SetParent(btn, bar)
        btn:SetFrameStrata(bar:GetFrameStrata())
        btn:SetFrameLevel(bar:GetFrameLevel() + 2)
        btn:SetSize(size, size)
        local slot, line = (i - 1) % perRow, math.floor((i - 1) / perRow)
        local x, y
        if s.mbVertical then x, y = line, slot else x, y = slot, line end
        m.ClearAllPoints(btn)
        m.SetPoint(btn, "TOPLEFT", bar, "TOPLEFT", pad + x * (size + gap), -(pad + y * (size + gap)))
    end

    local n = #shown
    local across = math.min(perRow, math.max(n, 1))
    local down = math.max(1, math.ceil(n / perRow))
    if s.mbVertical then across, down = down, across end
    bar:SetSize(pad * 2 + across * size + (across - 1) * gap, pad * 2 + down * size + (down - 1) * gap)
    bar:SetShown(n > 0 or BH.unlockMode)
end

-- ============================================================================
-- Apply
-- ============================================================================

function MB.Apply()
    if not Active() then
        if bar then bar:Hide() end
        if mover then mover:Hide() end
        return
    end
    Build()
    local s = Settings()
    local SK = ns.Skins

    bar:ClearAllPoints()
    local pos = s.mbPosition or DEFAULT_POS
    if pos then
        bar:SetPoint(pos.point, UIParent, pos.relPoint or pos.point, pos.x or 0, pos.y or 0)
    else
        bar:SetPoint("TOPRIGHT", Minimap, "TOPLEFT", -6, 0)
    end
    if SK and SK.Backdrop then
        local b = SK.Backdrop(bar, "panel")
        if b then b:SetShown(s.mbBackdrop ~= false) end
    end

    if s.mbMouseOver then
        bar:SetScript("OnUpdate", FadeTick)
    else
        bar:SetScript("OnUpdate", nil)
        bar:SetAlpha(1)
    end

    MB.Scan()
    mover:SetShown(BH.unlockMode and true or false)
    mover:EnableMouse(BH.unlockMode and true or false)
end

function BH:ApplyMinimapButtons()
    MB.Apply()
end

-- ============================================================================
-- Events: buttons appear as their addons load, some well after login.
-- ============================================================================

-- /sqmb: what each gathered button is drawing, to tell a button the bar
-- dims from one its own addon dims on purpose.
SLASH_SQUIZZMB1 = "/sqmb"
SlashCmdList.SQUIZZMB = function()
    local out = "|cff33cc99Squizzumables:|r "
    if #buttons == 0 then print(out .. "no minimap buttons gathered.") return end
    for _, btn in ipairs(buttons) do
        local icon = FindIcon(btn)
        local r, g, b, a = 1, 1, 1, 1
        if icon then r, g, b, a = icon:GetVertexColor() end
        local extra = 0
        for _, rg in ipairs({ btn:GetRegions() }) do
            if rg ~= icon and rg:IsObjectType("Texture") and rg:IsShown() and rg:GetAlpha() > 0
                and rg:GetDrawLayer() ~= "HIGHLIGHT" then
                extra = extra + 1
            end
        end
        local kids = 0
        for _, k in ipairs({ btn:GetChildren() }) do
            if k:IsShown() and not (ns.Skins and ns.Skins.GetBackdrop and ns.Skins.GetBackdrop(btn) == k) then kids = kids + 1 end
        end
        print(out .. string.format("%s  alpha %.2f  icon %s rgb %.2f %.2f %.2f a %.2f%s  other textures %d  child frames %d",
            btn:GetName() or "?", btn:GetAlpha(), icon and "yes" or "NONE", r, g, b, a,
            (icon and icon.IsDesaturated and icon:IsDesaturated()) and " grey" or "", extra, kids))
    end
end

local pending
local function Soon()
    if pending then return end
    pending = true
    C_Timer.After(0.5, function()
        pending = false
        MB.Scan()
    end)
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("ADDON_LOADED")
ev:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        MB.Apply()
        for _, t in ipairs({ 2, 5, 15 }) do C_Timer.After(t, MB.Scan) end
        local dbi = LibStub and LibStub("LibDBIcon-1.0", true)
        if dbi and dbi.RegisterCallback then
            dbi.RegisterCallback(MB, "LibDBIcon_IconCreated", Soon)
        end
    elseif BH.settings then
        Soon()
    end
end)
