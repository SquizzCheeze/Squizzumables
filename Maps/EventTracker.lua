-- Maps/EventTracker.lua
-- A strip of the world events going on now and coming up next, each with its
-- icon, name and time left (or time until it starts) over a thin bar, and a
-- tick once its rewards are claimed. Hover for Blizzard's own tooltip; click
-- to open the map at it; right-click to set or clear Blizzard's own reminder.
--
-- Built entirely on Blizzard's event scheduler (C_EventScheduler, the same
-- list as the map's Events tab), so new events appear without an update and
-- nothing here keeps timetables. WindTools' Event Tracker was looked at for
-- the idea only; its weekly-quest list is its own hand-gathered quest IDs and
-- is not reproduced.
--
-- Placed in Edit Mode (dragged through a frame laid over it). Waits while
-- WindTools' Event Tracker is on.

local addonName, ns = ...
local BH = ns.BH

local ET = {}
ns.EventTracker = ET

local function Elv()
    local elv = _G["ElvUI"]
    return C_AddOns.IsAddOnLoaded("ElvUI") and type(elv) == "table" and elv[1] or nil
end

local function WTTracker()
    if not C_AddOns.IsAddOnLoaded("ElvUI_WindTools") or BH.IS_FOREVER then return nil end
    local E = Elv()
    local wt = E and E.db and E.db.WT and E.db.WT.maps
    return wt and type(wt.eventTracker) == "table" and wt.eventTracker or nil
end

function ET.ElvUIOn()
    local t = WTTracker()
    return t and t.enable and true or false
end

local settingsView = setmetatable({}, { __index = function(_, k)
    local s = BH.settings
    local v = s and s[k]
    if v == nil and BH.defaultSettings then v = BH.defaultSettings[k] end
    return v
end })
local function Settings() return settingsView end
local function Active()
    return BH.settings and BH.settings.etEnabled and not ET.ElvUIOn() and C_EventScheduler ~= nil
end
local function Apply() if ET.Apply then ET.Apply() end end

local OUTLINES = {
    { text = "None", value = "NONE" }, { text = "Shadow", value = "SHADOW" },
    { text = "Outline", value = "OUTLINE" }, { text = "Thick outline", value = "THICKOUTLINE" },
}
local function Fonts() return BH:BuildFontDropdownItems() end

-- ============================================================================
-- Settings
-- ============================================================================

ET.SETTINGS = ns.Settings.Describe({
    master = "etEnabled",
    apply = Apply,
    pages = {
        { key = "general", label = "General", rows = {
            { key = "etEnabled", type = "check", default = false, label = "Show World Events",
              tip = "The events going on now and coming up next, from the game's own event list (the map's "
                .. "Events tab). Placed in Edit Mode.\n\nWaits while WindTools' Event Tracker is on "
                .. "(WindTools > Maps > Event Tracker).",
              apply = function(v)
                  if v and ET.ElvUIOn() then
                      print("|cff33cc99Squizzumables:|r WindTools' Event Tracker is still on. Turn it off there "
                          .. "and this takes over.")
                  end
              end },
            { key = "etUpcoming", type = "check", default = true, label = "Show Upcoming Events",
              tip = "The next time each event starts, as well as those running now." },
            { key = "etHideDone", type = "check", default = false, label = "Hide Events You've Done",
              tip = "Once their rewards are claimed. Otherwise they stay, greyed, with a tick." },
            { key = "etMax", type = "slider", default = 6, min = 1, max = 12, step = 1, label = "Most Shown" },
            { type = "header", label = "LAYOUT" },
            { key = "etPerRow", type = "slider", default = 1, min = 1, max = 6, step = 1, label = "Per Row" },
            { key = "etWidth", type = "slider", default = 177, min = 80, max = 400, step = 1, label = "Width" },
            { key = "etHeight", type = "slider", default = 26, min = 16, max = 60, step = 1, label = "Height" },
            { key = "etSpacing", type = "slider", default = 2, min = 0, max = 20, step = 1, label = "Spacing" },
            { key = "etBackdrop", type = "check", default = true, label = "Background" },
            { type = "header", label = "TEXT" },
            { key = "etFont", type = "dropdown", default = "__default", items = Fonts, label = "Font" },
            { key = "etSize", type = "slider", default = 11, min = 6, max = 24, step = 1, label = "Size" },
            { key = "etOutline", type = "dropdown", default = "OUTLINE", items = OUTLINES, label = "Outline" },
        } },
    },
})

function BH:BuildEventTrackerTab(parent)
    ns.Settings.Build(ET.SETTINGS, parent)
end

-- ============================================================================
-- Helpers
-- ============================================================================

local function ResolveFont(name)
    if name and name ~= "__default" then
        local lsm = LibStub and LibStub("LibSharedMedia-3.0", true)
        local path = lsm and lsm:Fetch("font", name, true)
        if path then return path end
    end
    return STANDARD_TEXT_FONT
end

local function SetFont(fs, s)
    local outline = s.etOutline or "OUTLINE"
    fs:SetFont(ResolveFont(s.etFont), s.etSize or 11,
        (outline == "OUTLINE" or outline == "THICKOUTLINE") and outline or "")
    local shadow = outline == "SHADOW"
    fs:SetShadowOffset(shadow and 1 or 0, shadow and -1 or 0)
    fs:SetShadowColor(0, 0, 0, shadow and 1 or 0)
end

local function Clock(seconds)
    seconds = math.max(0, math.floor(seconds))
    if seconds >= 3600 then
        return ("%dh %02dm"):format(math.floor(seconds / 3600), math.floor(seconds % 3600 / 60))
    end
    return ("%d:%02d"):format(math.floor(seconds / 60), seconds % 60)
end

local function Accent()
    if ns.Theme and ns.Theme.RGBA then
        local r, g, b = ns.Theme.RGBA("accent")
        return r, g, b
    end
    return 0.2, 0.8, 0.6
end

-- ============================================================================
-- The list
-- ============================================================================

-- Now-running events first (soonest to end first), then the next start of
-- each other event (soonest first), one entry per event.
local function Collect()
    local s = Settings()
    local list, seen = {}, {}
    local now = time()
    local scheduled = C_EventScheduler.GetScheduledEvents() or {}
    -- A running event's own entry carries no times; its scheduled entry does.
    local running = {}
    for _, e in ipairs(scheduled) do
        if e.startTime <= now and e.endTime > now then running[e.areaPoiID] = e end
    end
    for _, e in ipairs(C_EventScheduler.GetOngoingEvents() or {}) do
        if not (s.etHideDone and e.rewardsClaimed) then
            local info = C_AreaPoiInfo.GetAreaPOIInfo(nil, e.areaPoiID)
            if info and info.name then
                if e.displayInfo and e.displayInfo.overrideAtlas then info.atlasName = e.displayInfo.overrideAtlas end
                seen[info.name] = true
                local sched = running[e.areaPoiID]
                local left = C_AreaPoiInfo.GetAreaPOISecondsLeft and C_AreaPoiInfo.GetAreaPOISecondsLeft(e.areaPoiID)
                local endTime = (sched and sched.endTime) or (left and left > 0 and now + left) or nil
                list[#list + 1] = { ongoing = true, info = info, event = e,
                                    startTime = sched and sched.startTime, endTime = endTime }
            end
        end
    end
    if s.etUpcoming ~= false then
        for _, e in ipairs(scheduled) do
            if e.endTime > now and not (s.etHideDone and e.rewardsClaimed) then
                local info = C_AreaPoiInfo.GetAreaPOIInfo(nil, e.areaPoiID)
                if info and info.name and not seen[info.name] then
                    seen[info.name] = true
                    if e.displayInfo and e.displayInfo.overrideAtlas then info.atlasName = e.displayInfo.overrideAtlas end
                    list[#list + 1] = { ongoing = e.startTime <= now, info = info, event = e,
                                        startTime = e.startTime, endTime = e.endTime }
                end
            end
        end
    end
    table.sort(list, function(a, b)
        if a.ongoing ~= b.ongoing then return a.ongoing end
        if a.ongoing then return (a.endTime or math.huge) < (b.endTime or math.huge) end
        return (a.startTime or 0) < (b.startTime or 0)
    end)
    return list
end

-- ============================================================================
-- Frames
-- ============================================================================

local holder, mover
local tiles = {}

local function SavePosition()
    local left, top = holder:GetLeft(), holder:GetTop()
    if not left then return end
    BH.settings.etPosition = { point = "TOPLEFT", relPoint = "TOPLEFT",
        x = math.floor(left + 0.5), y = math.floor(top - UIParent:GetHeight() + 0.5) }
    BH:SaveSettings()
end

local function TileTooltip(tile)
    local d = tile.data
    if not d then return end
    local info = d.info
    if d.ongoing and d.endTime then
        info.secondsLeft = d.endTime - time()
        info.forceHideTimer = false
    else
        info.secondsLeft = nil
        info.forceHideTimer = true
    end
    if AreaPoiUtil and AreaPoiUtil.TryShowTooltip then
        AreaPoiUtil.TryShowTooltip(tile, "ANCHOR_BOTTOMLEFT", info)
    else
        GameTooltip:SetOwner(tile, "ANCHOR_BOTTOMLEFT")
        GameTooltip:SetText(info.name or "")
        GameTooltip:Show()
    end
    if not d.ongoing and d.startTime then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(d.event.hasReminder and "Right-click to clear the reminder."
            or "Right-click for a reminder when it starts.", 0.6, 0.6, 0.6)
        GameTooltip:Show()
    elseif d.ongoing then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Click to show it on the map.", 0.6, 0.6, 0.6)
        GameTooltip:Show()
    end
end

local function TileClick(tile, button)
    local d = tile.data
    if not d then return end
    local e = d.event
    if button == "RightButton" then
        if d.ongoing or not e.eventKey then return end
        if e.hasReminder then
            C_EventScheduler.ClearReminder(e.eventKey)
        else
            C_EventScheduler.SetReminder(e.eventKey)
        end
        C_EventScheduler.RequestEvents()
    elseif d.ongoing and OpenMapToEventPoi then
        OpenMapToEventPoi(e.areaPoiID)
    end
end

local function NewTile()
    local t = CreateFrame("Button", nil, holder, "BackdropTemplate")
    t:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    t.icon = t:CreateTexture(nil, "ARTWORK")
    t.name = t:CreateFontString(nil, "OVERLAY")
    t.name:SetJustifyH("LEFT")
    t.name:SetWordWrap(false)
    t.time = t:CreateFontString(nil, "OVERLAY")
    t.time:SetJustifyH("RIGHT")
    t.bar = CreateFrame("StatusBar", nil, t)
    t.bar:SetStatusBarTexture("Interface\\Buttons\\WHITE8x8")
    t.bar:SetMinMaxValues(0, 1)
    t.barBg = t.bar:CreateTexture(nil, "BACKGROUND")
    t.barBg:SetAllPoints()
    t.barBg:SetColorTexture(0, 0, 0, 0.5)
    t.done = t:CreateTexture(nil, "OVERLAY")
    t.done:SetAtlas("common-icon-checkmark")
    t.done:SetSize(14, 14)
    t:SetScript("OnEnter", TileTooltip)
    t:SetScript("OnLeave", function() GameTooltip:Hide() end)
    t:SetScript("OnClick", TileClick)
    return t
end

local function StyleTile(t, s)
    local h = s.etHeight or 26
    t:SetSize(s.etWidth or 177, h)
    if s.etBackdrop ~= false then
        t:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8",
                        edgeSize = 1 })
        t:SetBackdropColor(0.06, 0.06, 0.06, 0.8)
        t:SetBackdropBorderColor(0, 0, 0, 1)
    else
        t:SetBackdrop(nil)
    end
    local iconSize = h - 6
    t.icon:ClearAllPoints()
    t.icon:SetPoint("LEFT", 3, 1)
    t.icon:SetSize(iconSize, iconSize)
    t.time:ClearAllPoints()
    t.time:SetPoint("RIGHT", -4, 1)
    t.name:ClearAllPoints()
    t.name:SetPoint("LEFT", t.icon, "RIGHT", 4, 0)
    t.name:SetPoint("RIGHT", t.time, "LEFT", -4, 0)
    SetFont(t.name, s)
    SetFont(t.time, s)
    t.bar:ClearAllPoints()
    t.bar:SetPoint("BOTTOMLEFT", 1, 1)
    t.bar:SetPoint("BOTTOMRIGHT", -1, 1)
    t.bar:SetHeight(2)
    t.done:ClearAllPoints()
    t.done:SetPoint("CENTER", t.icon, "BOTTOMRIGHT", -2, 2)
end

-- Text and bar, every second.
local function Tick(t)
    local d = t.data
    if not d then return end
    local now = time()
    local r, g, b = Accent()
    if d.ongoing and d.endTime then
        local left = d.endTime - now
        t.time:SetText(Clock(left))
        t.time:SetTextColor(r, g, b)
        local total = (d.startTime and d.endTime - d.startTime) or (d.event and d.event.duration) or 0
        t.bar:SetValue(total > 0 and left / total or 1)
        t.bar:SetStatusBarColor(r, g, b)
        t.bar:Show()
    elseif d.ongoing then
        t.time:SetText("Now")
        t.time:SetTextColor(r, g, b)
        t.bar:Hide()
    elseif d.startTime then
        t.time:SetText("in " .. Clock(d.startTime - now))
        t.time:SetTextColor(0.8, 0.8, 0.8)
        -- Fills over the last hour before it starts.
        local until_ = d.startTime - now
        t.bar:SetValue(1 - math.min(until_, 3600) / 3600)
        t.bar:SetStatusBarColor(0.5, 0.5, 0.5)
        t.bar:Show()
    end
end

local function Build()
    if holder then return end
    holder = CreateFrame("Frame", "SquizzumablesEventTracker", UIParent)
    holder:SetMovable(true)
    holder:SetClampedToScreen(true)
    holder:SetSize(177, 26)

    mover = CreateFrame("Frame", "SquizzumablesEventTrackerMover", UIParent)
    mover:SetAllPoints(holder)
    mover:SetFrameStrata("HIGH")
    mover:RegisterForDrag("LeftButton")
    mover:SetScript("OnDragStart", function()
        if InCombatLockdown() or not BH.unlockMode then return end
        BH:GridStartMoving(holder)
    end)
    mover:SetScript("OnDragStop", function()
        BH:GridStopMoving(holder)
        SavePosition()
        Apply()
    end)
    mover:Hide()
    BH.eventTrackerMover = mover

    local elapsed = 0
    holder:SetScript("OnUpdate", function(_, dt)
        elapsed = elapsed + dt
        if elapsed < 1 then return end
        elapsed = 0
        local refresh
        for _, t in ipairs(tiles) do
            if t:IsShown() then
                Tick(t)
                local d = t.data
                if d and ((d.endTime and d.endTime <= time()) or (not d.ongoing and d.startTime and d.startTime <= time())) then
                    refresh = true
                end
            end
        end
        if refresh then ET.Refresh() end
    end)
end

function ET.Nudge(dx, dy)
    local s = BH.settings
    if not s then return end
    local pos = s.etPosition
    if not pos then
        SavePosition()
        pos = s.etPosition
        if not pos then return end
    end
    s.etPosition = { point = pos.point, relPoint = pos.relPoint, x = (pos.x or 0) + dx, y = (pos.y or 0) + dy }
    BH:SaveSettings()
    Apply()
end

function ET.Refresh()
    if not holder then return end
    if not Active() then
        holder:Hide()
        return
    end
    local s = Settings()
    local list = C_EventScheduler.HasData() and Collect() or {}
    local max = s.etMax or 6
    local perRow = math.max(1, s.etPerRow or 1)
    local w, h, gap = s.etWidth or 177, s.etHeight or 26, s.etSpacing or 2
    local shown = math.min(#list, max)
    for i = 1, shown do
        local t = tiles[i]
        if not t then
            t = NewTile()
            tiles[i] = t
        end
        StyleTile(t, s)
        local d = list[i]
        t.data = d
        local claimed = d.event and d.event.rewardsClaimed
        if d.info.atlasName then
            t.icon:SetAtlas(d.info.atlasName)
        else
            t.icon:SetTexture(134400)
        end
        t.icon:SetDesaturated(claimed and true or false)
        t.name:SetText(d.info.name)
        if claimed then
            t.name:SetTextColor(0.5, 0.5, 0.5)
        elseif d.ongoing then
            t.name:SetTextColor(1, 1, 1)
        else
            t.name:SetTextColor(0.75, 0.75, 0.75)
        end
        t.done:SetShown(claimed and true or false)
        local col, row = (i - 1) % perRow, math.floor((i - 1) / perRow)
        t:ClearAllPoints()
        t:SetPoint("TOPLEFT", holder, "TOPLEFT", col * (w + gap), -row * (h + gap))
        Tick(t)
        t:Show()
    end
    for i = shown + 1, #tiles do
        tiles[i]:Hide()
        tiles[i].data = nil
    end
    local cols = math.min(perRow, math.max(shown, 1))
    local rows = math.max(1, math.ceil(shown / perRow))
    holder:SetSize(cols * w + (cols - 1) * gap, rows * h + (rows - 1) * gap)
    -- Visible while unlocked even with nothing to show, so it can be placed.
    holder:SetShown(shown > 0 or BH.unlockMode)
end

function ET.Apply()
    if not Active() then
        if holder then holder:Hide() end
        if mover then mover:Hide() end
        return
    end
    Build()
    local s = Settings()
    holder:ClearAllPoints()
    local pos = s.etPosition
    if pos then
        holder:SetPoint(pos.point, UIParent, pos.relPoint or pos.point, pos.x or 0, pos.y or 0)
    elseif _G.SquizzumablesDataTextPanel and _G.SquizzumablesDataTextPanel:IsShown() then
        holder:SetPoint("TOPLEFT", _G.SquizzumablesDataTextPanel, "BOTTOMLEFT", 0, -2)
    else
        holder:SetPoint("TOPLEFT", Minimap, "BOTTOMLEFT", 0, -26)
    end
    C_EventScheduler.RequestEvents()
    ET.Refresh()
    mover:SetShown(BH.unlockMode and true or false)
    mover:EnableMouse(BH.unlockMode and true or false)
end

-- ============================================================================
-- WindTools' Event Tracker, copied once per profile
-- ============================================================================

local function Seed()
    local s = BH.settings
    if not s or s.etSeededFromWT then return end
    local t = WTTracker()
    if not t then return end
    s.etSeededFromWT = true
    if t.enable then s.etEnabled = true end
    local st = t.style
    if type(st) == "table" then
        if tonumber(st.trackerWidth) then s.etWidth = tonumber(st.trackerWidth) end
        if tonumber(st.trackerHeight) then s.etHeight = tonumber(st.trackerHeight) end
        if tonumber(st.trackerHorizontalSpacing) then s.etSpacing = tonumber(st.trackerHorizontalSpacing) end
        if st.backdrop ~= nil then s.etBackdrop = st.backdrop and true or false end
    end
    local lsm = LibStub and LibStub("LibSharedMedia-3.0", true)
    if type(t.font) == "table" and type(t.font.name) == "string" and lsm and lsm:IsValid("font", t.font.name) then
        s.etFont = t.font.name
    end
    BH:SaveSettings()
end

function BH:ApplyEventTracker()
    Seed()
    ET.Apply()
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("ZONE_CHANGED_NEW_AREA")
if C_EventScheduler then ev:RegisterEvent("EVENT_SCHEDULER_UPDATE") end
ev:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        BH:ApplyEventTracker()
    elseif event == "EVENT_SCHEDULER_UPDATE" then
        ET.Refresh()
    elseif Active() then
        C_EventScheduler.RequestEvents()
    end
end)

-- The list only changes when asked for; ask once a minute while shown.
C_Timer.NewTicker(60, function()
    if Active() and holder and holder:IsShown() then C_EventScheduler.RequestEvents() end
end)
