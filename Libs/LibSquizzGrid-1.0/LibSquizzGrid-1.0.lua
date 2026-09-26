--[[ LibSquizzGrid-1.0

    One alignment grid and one snap engine shared by SquizzFrames and
    Squizzumables. Each addon embeds a copy; LibStub runs the newest, so both
    addons draw the SAME grid, show the SAME toolbar, and each one's frames can
    snap to the other's.

    WHAT IT DOES
      * A full-screen grid, shown while ANY client addon is in its move mode
        (SquizzFrames' Edit Mode, Squizzumables' unlock mode). Lines every
        GRID_SPACING UI units, laid out outward FROM the screen centre so the
        two centre lines are always on it, drawn brighter. Always the player's
        class colour (user request 2026-09-26).
      * A small toolbar at the top of the screen: [Grid: Off/Dimmed/Bright]
        and [Snap: On/Off]. No keyboard modifier -- a button only (user's
        choice). Snap is OFF by default.
      * With Snap on, a dragged frame's CENTRE snaps only to the screen's
        centre lines, and its EDGES to the screen edges and to the nearest
        other frame's edges (flush or butted up against it). Grid lines are
        visual only. Catch within SNAP_RANGE, hold until BREAK_RANGE. A guide
        line marks each axis that snapped. (V1 snapped everything to
        everything, grid included, and was far too sensitive -- see
        SnapFrameDelta.)

    DESIGN REFERENCES (studied, not copied)
      Blizzard's EditModeMagnetismManager (Blizzard_EditMode/Shared/
      EditModeUtil.lua): the target set and the 8px range. It cannot be reused
      -- it calls Edit Mode methods on the dragged frame, and touching
      EditModeManagerFrame taints it (LibEditMode's own source says so).
      EllesmereUI's unlock mode: the centre-out grid and guide lines. Its
      licence is all-rights-reserved; nothing here is its code.

    COORDINATES
      Everything is measured in UIParent units: a frame's GetLeft() etc. are in
      its OWN scaled space, so each is multiplied by
      frame:GetEffectiveScale() / UIParent:GetEffectiveScale(). Mixing the two
      is a bug SquizzFrames has hit three times; it is exact at scale 1.0 and
      drifts at any other scale, so it hides in normal testing.

    API
      lib:SetStorage(tbl)          persist settings into tbl (write-through to
                                   every addon's table; first one read wins)
      lib:Activate(owner)          owner entered move mode (grid + toolbar)
      lib:Deactivate(owner)        owner left it
      lib:RegisterTarget(frame)    frame others may snap to (weak; only used
                                   while it is visible)
      lib:IsSnapping()
      lib:SnapFrameDelta(frame)    dx, dy (UIParent units) that would snap the
                                   frame as it sits now; draws guides. 0,0 when
                                   snapping is off or nothing is in range.
      lib:ClearGuides()
      lib:StartMoving(frame)       drop-in for frame:StartMoving(): the plain
      lib:StopMoving(frame)        engine drag with Snap off, a snapping drag
                                   with it on (anchored CENTER to UIParent's
                                   CENTER, so GetPoint/GetCenter savers both
                                   round-trip)
]]

local MAJOR, MINOR = "LibSquizzGrid-1.0", 2
local lib = LibStub:NewLibrary(MAJOR, MINOR)
if not lib then return end

local GRID_SPACING = 32
local SNAP_RANGE   = 6
local ALPHA = {
    dimmed = { line = 0.18, centre = 0.45 },
    bright = { line = 0.35, centre = 0.80 },
}
local MODES = { "off", "dimmed", "bright" }
local MODE_TEXT = { off = "Off", dimmed = "Dimmed", bright = "Bright" }

lib.storages = lib.storages or {}
lib.owners   = lib.owners or {}
lib.targets  = lib.targets or setmetatable({}, { __mode = "k" })
lib.state    = lib.state or { gridMode = "dimmed", snap = false }

local issecret = issecretvalue or function() return false end

-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------

local function Save()
    for tbl in pairs(lib.storages) do
        tbl.gridMode = lib.state.gridMode
        tbl.snap = lib.state.snap
    end
end

function lib:SetStorage(tbl)
    if type(tbl) ~= "table" then return end
    -- The first storage that already holds settings wins, so two addons with
    -- different saved values settle on one rather than fighting.
    if not self.storageLoaded and tbl.gridMode ~= nil then
        self.state.gridMode = tbl.gridMode
        self.state.snap = tbl.snap == true
        self.storageLoaded = true
    end
    self.storages[tbl] = true
    Save()
    if self.RefreshToolbar then self:RefreshToolbar() end
end

function lib:IsSnapping()
    return self.state.snap == true
end

-- ---------------------------------------------------------------------------
-- Geometry
-- ---------------------------------------------------------------------------

local function UIScaleOf(f)
    local ue = UIParent:GetEffectiveScale()
    local fe = f:GetEffectiveScale()
    if not (ue and fe) or ue == 0 then return 1 end
    return fe / ue
end

-- A frame's rect in UIParent units, or nil when it has none (never anchored)
-- or any side reads secret.
local function RectOf(f)
    local ok, l, b, w, h = pcall(f.GetRect, f)
    if not ok or l == nil or b == nil or w == nil or h == nil then return nil end
    if issecret(l) or issecret(b) or issecret(w) or issecret(h) then return nil end
    local k = UIScaleOf(f)
    l, b, w, h = l * k, b * k, w * k, h * k
    return l, l + w, b, b + h -- left, right, bottom, top
end
lib.RectOf = RectOf

-- Does `frame`'s anchor chain lead to `onto`? A target riding the dragged
-- frame (a cast bar on its unit frame, a mover pinned to it) moves with it, so
-- snapping to it would chase its own tail.
local function DependsOn(frame, onto)
    local queue, seen, head = { frame }, { [frame] = true }, 1
    while queue[head] and head <= 64 do
        local f = queue[head]
        head = head + 1
        if f == onto then return true end
        local okN, n = pcall(f.GetNumPoints, f)
        for i = 1, (okN and n) or 0 do
            local ok, _, rel = pcall(f.GetPoint, f, i)
            if ok and rel == nil and f.GetParent then rel = f:GetParent() end
            if ok and type(rel) == "table" and not seen[rel] then
                seen[rel] = true
                queue[#queue + 1] = rel
            end
        end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Grid overlay
-- ---------------------------------------------------------------------------

local function ClassColour()
    local _, class = UnitClass("player")
    local c = (C_ClassColor and class and C_ClassColor.GetClassColor(class))
        or (class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class])
    if c then return c.r, c.g, c.b end
    return 1, 1, 1
end

-- One physical pixel, in UIParent units.
local function PixelSize()
    local _, ph = GetPhysicalScreenSize()
    local ue = UIParent:GetEffectiveScale()
    if not ph or ph == 0 or not ue or ue == 0 then return 1 end
    return 768 / ph / ue
end

local function NewLine(parent, layer, sub)
    local t = parent:CreateTexture(nil, layer, nil, sub)
    if t.SetSnapToPixelGrid then
        t:SetSnapToPixelGrid(false)
        t:SetTexelSnappingBias(0)
    end
    return t
end

local function EnsureGrid()
    if lib.grid then return lib.grid end
    local g = CreateFrame("Frame", nil, UIParent)
    g:SetAllPoints(UIParent)
    g:SetFrameStrata("BACKGROUND")
    g:SetFrameLevel(1)
    g:EnableMouse(false)
    g:Hide()
    g.lines = {}
    g:RegisterEvent("UI_SCALE_CHANGED")
    g:RegisterEvent("DISPLAY_SIZE_CHANGED")
    g:SetScript("OnEvent", function(self) if self:IsShown() then lib:RebuildGrid() end end)
    lib.grid = g
    return g
end

function lib:RebuildGrid()
    local g = EnsureGrid()
    for _, t in ipairs(g.lines) do t:Hide() end
    local mode = self.state.gridMode
    if mode == "off" then g:Hide() return end

    local a = ALPHA[mode] or ALPHA.dimmed
    local r, gg, b = ClassColour()
    local w, h = UIParent:GetWidth(), UIParent:GetHeight()
    local px = PixelSize()
    local cx, cy = w / 2, h / 2
    local n = 0

    local function Line(vertical, pos, isCentre)
        n = n + 1
        local t = g.lines[n]
        if not t then
            t = NewLine(g, "BACKGROUND", -7)
            g.lines[n] = t
        end
        t:ClearAllPoints()
        if vertical then
            t:SetSize(isCentre and px * 2 or px, h)
            t:SetPoint("BOTTOM", UIParent, "BOTTOMLEFT", pos, 0)
        else
            t:SetSize(w, isCentre and px * 2 or px)
            t:SetPoint("LEFT", UIParent, "BOTTOMLEFT", 0, pos)
        end
        t:SetColorTexture(r, gg, b, isCentre and a.centre or a.line)
        t:Show()
    end

    Line(true, cx, true)
    Line(false, cy, true)
    local x = cx - GRID_SPACING
    while x > 0 do Line(true, x); x = x - GRID_SPACING end
    x = cx + GRID_SPACING
    while x < w do Line(true, x); x = x + GRID_SPACING end
    local y = cy - GRID_SPACING
    while y > 0 do Line(false, y); y = y - GRID_SPACING end
    y = cy + GRID_SPACING
    while y < h do Line(false, y); y = y + GRID_SPACING end
    g:Show()
end

-- ---------------------------------------------------------------------------
-- Toolbar
-- ---------------------------------------------------------------------------

local function StyleButton(btn, text)
    local r, g, b = ClassColour()
    btn.label:SetText(text)
    btn.label:SetTextColor(r, g, b)
    btn:SetBackdropBorderColor(r, g, b, 0.9)
end

local function NewButton(parent, width)
    local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    btn:SetSize(width, 22)
    btn:SetBackdrop({ bgFile = "Interface\\BUTTONS\\WHITE8X8", edgeFile = "Interface\\BUTTONS\\WHITE8X8", edgeSize = 1 })
    btn:SetBackdropColor(0.08, 0.08, 0.08, 0.92)
    btn.label = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    btn.label:SetPoint("CENTER")
    btn:SetScript("OnEnter", function(self) self:SetBackdropColor(0.16, 0.16, 0.16, 0.95) end)
    btn:SetScript("OnLeave", function(self) self:SetBackdropColor(0.08, 0.08, 0.08, 0.92) end)
    return btn
end

local function EnsureToolbar()
    if lib.toolbar then return lib.toolbar end
    local bar = CreateFrame("Frame", nil, UIParent)
    bar:SetSize(232, 22)
    bar:SetPoint("TOP", UIParent, "TOP", 0, -6)
    bar:SetFrameStrata("FULLSCREEN_DIALOG")
    bar:Hide()

    local gridBtn = NewButton(bar, 120)
    gridBtn:SetPoint("LEFT", bar, "LEFT", 0, 0)
    gridBtn:SetScript("OnClick", function()
        local cur = lib.state.gridMode
        local nextMode = "dimmed"
        for i, m in ipairs(MODES) do
            if m == cur then nextMode = MODES[(i % #MODES) + 1] break end
        end
        lib.state.gridMode = nextMode
        Save()
        lib:RebuildGrid()
        lib:RefreshToolbar()
    end)

    local snapBtn = NewButton(bar, 106)
    snapBtn:SetPoint("LEFT", gridBtn, "RIGHT", 6, 0)
    snapBtn:SetScript("OnClick", function()
        lib.state.snap = not lib.state.snap
        Save()
        lib:RefreshToolbar()
    end)

    bar.gridBtn, bar.snapBtn = gridBtn, snapBtn
    lib.toolbar = bar
    return bar
end

function lib:RefreshToolbar()
    local bar = self.toolbar
    if not bar then return end
    StyleButton(bar.gridBtn, "Grid: " .. (MODE_TEXT[self.state.gridMode] or "Dimmed"))
    StyleButton(bar.snapBtn, "Snap: " .. (self.state.snap and "On" or "Off"))
end

-- ---------------------------------------------------------------------------
-- Move-mode owners
-- ---------------------------------------------------------------------------

local function AnyOwner()
    return next(lib.owners) ~= nil
end

function lib:Activate(owner)
    self.owners[owner or "?"] = true
    EnsureToolbar()
    self:RefreshToolbar()
    self.toolbar:Show()
    self:RebuildGrid()
end

function lib:Deactivate(owner)
    self.owners[owner or "?"] = nil
    if AnyOwner() then return end
    if self.toolbar then self.toolbar:Hide() end
    if self.grid then self.grid:Hide() end
    self:ClearGuides()
end

function lib:RegisterTarget(frame)
    if frame then self.targets[frame] = true end
end

function lib:UnregisterTarget(frame)
    if frame then self.targets[frame] = nil end
end

-- ---------------------------------------------------------------------------
-- Snapping
-- ---------------------------------------------------------------------------

local function EnsureGuides()
    if lib.guides then return lib.guides end
    local host = CreateFrame("Frame", nil, UIParent)
    host:SetAllPoints(UIParent)
    host:SetFrameStrata("FULLSCREEN_DIALOG")
    host:EnableMouse(false)
    local v = NewLine(host, "OVERLAY", 7)
    local h = NewLine(host, "OVERLAY", 7)
    v:Hide(); h:Hide()
    lib.guides = { host = host, v = v, h = h }
    return lib.guides
end

local function ShowGuide(vertical, pos)
    local gd = EnsureGuides()
    local t = vertical and gd.v or gd.h
    local r, g, b = ClassColour()
    local px = PixelSize() * 2
    t:ClearAllPoints()
    if vertical then
        t:SetSize(px, UIParent:GetHeight())
        t:SetPoint("BOTTOM", UIParent, "BOTTOMLEFT", pos, 0)
    else
        t:SetSize(UIParent:GetWidth(), px)
        t:SetPoint("LEFT", UIParent, "BOTTOMLEFT", 0, pos)
    end
    t:SetColorTexture(r, g, b, 1)
    t:Show()
end

function lib:ClearGuides()
    if self.guides then
        self.guides.v:Hide()
        self.guides.h:Hide()
    end
    -- Also the end of a drag (every mover calls this on stop), so any held
    -- snap is let go: the next drag must earn its snaps fresh.
    self.lockX, self.lockY = nil, nil
end

-- WHAT SNAPS TO WHAT (V2, 2026-09-26). V1 offered every grid line, every
-- frame's three lines and the screen to each of the dragged frame's three
-- lines, within 8px: with lines every 32px that is half of all positions, so a
-- frame could barely move without catching on something (user report). Now:
--
--   the frame's CENTRE  -> the screen's centre line on that axis, nothing else
--   the frame's EDGES   -> the screen edges, and the NEAREST other frame's
--                          edges: same edge (flush) or opposite edge (butted
--                          up against it). Only the nearest frame -- aligning
--                          with something across the screen is noise.
--   grid lines          -> visual only
--
-- Catch within SNAP_RANGE; once caught, hold until the pointer is BREAK_RANGE
-- away (hysteresis), so a frame does not flick between two close targets.
local BREAK_RANGE = SNAP_RANGE * 2

-- The visible registered frame nearest `frame`, by edge-to-edge distance
-- (0 when overlapping). Excludes the frame itself and anything riding it.
local function NearestTarget(frame, l, r, b, t)
    local best, bestD
    for target in pairs(lib.targets) do
        if target ~= frame and target.IsVisible and target:IsVisible()
           and not DependsOn(target, frame) then
            local tl, tr, tb, tt = RectOf(target)
            if tl then
                local gx = (r < tl and tl - r) or (l > tr and l - tr) or 0
                local gy = (t < tb and tb - t) or (b > tt and b - tt) or 0
                local d = gx * gx + gy * gy
                if not bestD or d < bestD then best, bestD = { tl, tr, tb, tt }, d end
            end
        end
    end
    return best
end

-- One axis. `pts` are the dragged frame's { low, centre, high } on it;
-- `centre` the screen centre, `lo/hi` the screen edges, `near` the nearest
-- frame's { low, high } or nil. `lock` is the snap currently held on this axis
-- ({ idx = which point, at = where }). Returns delta, guide position, lock.
local function SolveAxis(pts, centre, lo, hi, near, lock)
    -- Held: stay put until the pointer has pulled BREAK_RANGE away.
    if lock then
        local d = lock.at - pts[lock.idx]
        if (d < 0 and -d or d) <= BREAK_RANGE then return d, lock.at, lock end
    end

    local best, bestAbs, bestAt, bestIdx = 0, SNAP_RANGE, nil, nil
    local function Try(idx, target)
        local d = target - pts[idx]
        local ad = d < 0 and -d or d
        if ad < bestAbs then best, bestAbs, bestAt, bestIdx = d, ad, target, idx end
    end

    Try(2, centre)              -- centre -> centre line only
    Try(1, lo); Try(3, hi)      -- edges -> screen edges
    if near then                -- edges -> nearest frame, flush or butted
        Try(1, near[1]); Try(1, near[2])
        Try(3, near[1]); Try(3, near[2])
    end

    if not bestAt then return 0, nil, nil end
    return best, bestAt, { idx = bestIdx, at = bestAt }
end

function lib:SnapFrameDelta(frame)
    -- Only while some addon is in its move mode. CDM groups, for one, can be
    -- dragged at any time; with Snap left on they would otherwise snap with
    -- no grid on screen to explain why.
    if not self.state.snap or not frame or not AnyOwner() then self:ClearGuides() return 0, 0 end
    local l, r, b, t = RectOf(frame)
    if not l then self:ClearGuides() return 0, 0 end

    -- A lock belongs to one frame; a different frame starts clean.
    if self.lockFrame ~= frame then
        self.lockX, self.lockY, self.lockFrame = nil, nil, frame
    end

    local w, h = UIParent:GetWidth(), UIParent:GetHeight()
    local near = NearestTarget(frame, l, r, b, t)

    local dx, atX, lockX = SolveAxis({ l, (l + r) / 2, r }, w / 2, 0, w,
        near and { near[1], near[2] }, self.lockX)
    local dy, atY, lockY = SolveAxis({ b, (b + t) / 2, t }, h / 2, 0, h,
        near and { near[3], near[4] }, self.lockY)
    self.lockX, self.lockY = lockX, lockY

    local gd = EnsureGuides()
    if atX then ShowGuide(true, atX) else gd.v:Hide() end
    if atY then ShowGuide(false, atY) else gd.h:Hide() end
    return dx, dy
end

-- ---------------------------------------------------------------------------
-- Drop-in drag for frames that used frame:StartMoving()
-- ---------------------------------------------------------------------------

local driver = lib.driver or CreateFrame("Frame")
lib.driver = driver
driver:Hide()

local function PlaceCentre(f, cxUI, cyUI)
    local k = UIScaleOf(f)
    local w, h = UIParent:GetWidth(), UIParent:GetHeight()
    f:ClearAllPoints()
    f:SetPoint("CENTER", UIParent, "CENTER", (cxUI - w / 2) / k, (cyUI - h / 2) / k)
end

driver:SetScript("OnUpdate", function(self)
    local d = lib.drag
    if not d then self:Hide() return end
    if not IsMouseButtonDown("LeftButton") or InCombatLockdown() then
        lib:StopMoving(d.frame)
        return
    end
    local ue = UIParent:GetEffectiveScale()
    local mx, my = GetCursorPosition()
    mx, my = mx / ue, my / ue
    local cx, cy = mx + d.offX, my + d.offY

    -- Keep a clamped frame on screen, as StartMoving would.
    if d.frame:IsClampedToScreen() then
        local w, h = UIParent:GetWidth(), UIParent:GetHeight()
        cx = math.max(d.halfW, math.min(w - d.halfW, cx))
        cy = math.max(d.halfH, math.min(h - d.halfH, cy))
    end

    PlaceCentre(d.frame, cx, cy)
    local sdx, sdy = lib:SnapFrameDelta(d.frame)
    if sdx ~= 0 or sdy ~= 0 then PlaceCentre(d.frame, cx + sdx, cy + sdy) end
end)

function lib:StartMoving(frame)
    if not frame then return end
    -- The plain engine drag -- exactly the old behaviour -- whenever snapping
    -- is off or no addon is in its move mode (see SnapFrameDelta).
    if not self.state.snap or not AnyOwner() then
        frame:StartMoving()
        return
    end
    local l, r, b, t = RectOf(frame)
    if not l then frame:StartMoving() return end
    local ue = UIParent:GetEffectiveScale()
    local mx, my = GetCursorPosition()
    mx, my = mx / ue, my / ue
    self.drag = {
        frame = frame,
        offX = (l + r) / 2 - mx, offY = (b + t) / 2 - my,
        halfW = (r - l) / 2, halfH = (t - b) / 2,
    }
    driver:Show()
end

function lib:StopMoving(frame)
    local d = self.drag
    if d and d.frame == frame then
        self.drag = nil
        driver:Hide()
        self:ClearGuides()
        return
    end
    if frame then frame:StopMovingOrSizing() end
end
