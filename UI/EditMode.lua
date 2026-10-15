-- UI/EditMode.lua
-- The 2.0 mover (phase 3 step 4): one look and one set of behaviours for every
-- frame the player can place -- reminder buttons, text reminders, raid tools,
-- battle res, death tally, callouts, target distance and the Cooldown Manager
-- groups. Replaced two copies of the old green boxes (user decision: "one Edit
-- Mode for everything ... no more green boxes", box colour = the theme accent).
--
-- What a frame gets while unlocked:
--   * a box in the theme's accent: a faint fill and an edge, its name above it
--   * hover lights the box up
--   * a click selects it: thicker, brighter edge, the name turns white
--   * the selected frame nudges with the arrow keys, 1px or 10px with Shift
--   * selecting a frame shows its settings in the options window, if that is
--     open (it finds the row through the settings search, which already knows
--     the page and sub-tab every row lives on, and flashes it)
--
-- Dragging is untouched: each frame keeps its own drag handling, and the box
-- takes no mouse at all -- it only draws, and listens through HookScript.
--
-- Usage:
--   ns.EditMode.Show(frame, label, {
--       find  = "Enable Beacon Reminder",   -- settings row to show on select
--       nudge = function(dx, dy) ... end,   -- move by dx, dy and save
--   })
--   ns.EditMode.Hide(frame)

local addonName, ns = ...

local EditMode = {}
ns.EditMode = EditMode

local EDGE = "Interface\\BUTTONS\\WHITE8X8"

local selected          -- the frame the arrow keys move
local keys              -- the keyboard catcher, made on first select

-- ----------------------------------------------------------------------------
-- Painting
-- ----------------------------------------------------------------------------

-- Fill and edge alpha, and edge size, per state.
local LOOK = {
    idle     = { fill = 0.06, edge = 0.55, size = 1 },
    hover    = { fill = 0.14, edge = 0.95, size = 1 },
    selected = { fill = 0.20, edge = 1.00, size = 2 },
}

local function Paint(frame)
    local m = frame.sqMover
    if not m then return end
    local state = (frame == selected and "selected") or (m.hover and "hover") or "idle"
    local look = LOOK[state]
    local r, g, b = ns.GetAccentColor()
    if m.edgeSize ~= look.size then
        m.edgeSize = look.size
        m.box:SetBackdrop({ bgFile = EDGE, edgeFile = EDGE, edgeSize = look.size })
    end
    m.box:SetBackdropColor(r, g, b, look.fill)
    m.box:SetBackdropBorderColor(r, g, b, look.edge)
    if state == "selected" then
        m.label:SetTextColor(1, 1, 1)
    else
        m.label:SetTextColor(r, g, b)
    end
end

-- ----------------------------------------------------------------------------
-- Selection and the arrow keys
-- ----------------------------------------------------------------------------

local function Keys()
    if keys then return keys end
    keys = CreateFrame("Frame", nil, UIParent)
    keys:Hide()
    keys:SetScript("OnKeyDown", function(self, key)
        local frame = selected
        local m = frame and frame.sqMover
        local step = IsShiftKeyDown() and 10 or 1
        local dx, dy = 0, 0
        if key == "LEFT" then dx = -step
        elseif key == "RIGHT" then dx = step
        elseif key == "UP" then dy = step
        elseif key == "DOWN" then dy = -step
        end
        -- Arrow keys stop here while something is selected; every other key
        -- goes on to the game as normal. Not touched in combat, where this is
        -- not allowed -- and nothing is unlocked in combat anyway.
        local handled = (dx ~= 0 or dy ~= 0) and m and m.opts.nudge
        if not InCombatLockdown() then self:SetPropagateKeyboardInput(not handled) end
        if handled then m.opts.nudge(dx, dy) end
    end)
    return keys
end

--- Select `frame` (nil clears it). Shows its settings when the window is open.
function EditMode.Select(frame)
    local old = selected
    selected = frame
    if old and old ~= frame then Paint(old) end
    if frame then Paint(frame) end

    local k = Keys()
    if frame and not InCombatLockdown() then
        k:EnableKeyboard(true)
        k:Show()
    else
        k:EnableKeyboard(false)
        k:Hide()
    end

    local m = frame and frame.sqMover
    local find = m and m.opts.find
    local panel = _G.SQUIZZUMABLESOptions
    if find and panel and panel:IsShown() and ns.Rows and ns.Rows.Search then
        local hit = ns.Rows.Search(find, 1)[1]
        if hit then ns.Rows.JumpTo(hit.entry) end
    end
end

function EditMode.Selected() return selected end

-- ----------------------------------------------------------------------------
-- The box
-- ----------------------------------------------------------------------------

--- Give `frame` its mover box and name. `opts` as in the header.
function EditMode.Show(frame, label, opts)
    if not frame then return end
    local m = frame.sqMover
    if not m then
        m = {}
        frame.sqMover = m

        local box = CreateFrame("Frame", nil, frame, "BackdropTemplate")
        box:SetAllPoints(frame)
        box:EnableMouse(false)
        m.box = box

        -- Own frame, so it can sit above the boxes: they overlap each other
        -- freely, and a name at the frame's own level disappears under
        -- whatever is stacked on top of it.
        --
        -- HIGH at the top of its levels, not TOOLTIP as the old labels were:
        -- the options window (DIALOG) can stay open while frames are
        -- unlocked now, and TOOLTIP drew every name over it (user screenshot
        -- 2026-10-16). It ignores the frame's scale too -- a reminder at 200%
        -- had a name twice the size -- and takes the UI's own scale instead.
        local holder = CreateFrame("Frame", nil, frame)
        holder:SetFrameStrata("HIGH")
        holder:SetFrameLevel(9000)
        holder:SetIgnoreParentScale(true)
        holder:SetScale(UIParent:GetEffectiveScale())
        holder:SetPoint("BOTTOMLEFT", frame, "TOPLEFT", 0, 3)
        holder:SetSize(260, 14)
        local fs = holder:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetPoint("BOTTOMLEFT", holder, "BOTTOMLEFT", 0, 0)
        fs:SetJustifyH("LEFT")
        m.holder, m.label = holder, fs

        -- Hooked once, and inert whenever the box is not showing.
        frame:HookScript("OnEnter", function(self)
            local mm = self.sqMover
            if mm and mm.active then mm.hover = true; Paint(self) end
        end)
        frame:HookScript("OnLeave", function(self)
            local mm = self.sqMover
            if mm and mm.active then mm.hover = false; Paint(self) end
        end)
        frame:HookScript("OnMouseDown", function(self, button)
            local mm = self.sqMover
            if mm and mm.active and button == "LeftButton" then EditMode.Select(self) end
        end)
    end
    m.opts = opts or {}
    m.active = true
    m.edgeSize = nil
    -- Above the frame's own content (the marker buttons, the reminder icons):
    -- it takes no mouse, so being on top costs nothing.
    m.box:SetFrameLevel(frame:GetFrameLevel() + 20)
    m.label:SetText(label or "")
    m.box:Show()
    m.holder:SetScale(UIParent:GetEffectiveScale())   -- the UI scale may have changed
    m.holder:Show()
    Paint(frame)
end

--- Take the box away. Deselects the frame if it was selected.
function EditMode.Hide(frame)
    local m = frame and frame.sqMover
    if not m then return end
    m.active, m.hover = false, false
    m.box:Hide()
    m.holder:Hide()
    if selected == frame then EditMode.Select(nil) end
end

-- ----------------------------------------------------------------------------
-- Following Blizzard's Edit Mode
-- ----------------------------------------------------------------------------

-- User decision 2026-10-16: opening Blizzard's Edit Mode (Esc > Edit Mode)
-- unlocks our frames too, and closing it locks them -- one place to move
-- everything. Only what this opened is closed again: frames already unlocked
-- with Unlock Frames stay unlocked when Blizzard's Edit Mode closes.
--
-- EventRegistry's EditMode.Enter / EditMode.Exit are Blizzard's own
-- notifications; listening calls nothing on EditModeManagerFrame, so nothing of
-- ours runs inside Edit Mode's code (touching that frame taints it).
-- Settings > Unlock With Blizzard's Edit Mode (followBlizzardEditMode) turns
-- it off.
local unlockedForBlizzard = false

if EventRegistry and EventRegistry.RegisterCallback then
    EventRegistry:RegisterCallback("EditMode.Enter", function()
        local BH = ns.BH
        if not (BH and BH.SetUnlockMode and BH.settings) then return end
        if BH.settings.followBlizzardEditMode == false or BH.unlockMode then return end
        BH:SetUnlockMode(true, false, true)
        unlockedForBlizzard = BH.unlockMode and true or false
    end, EditMode)
    EventRegistry:RegisterCallback("EditMode.Exit", function()
        local BH = ns.BH
        if not unlockedForBlizzard then return end
        unlockedForBlizzard = false
        if BH and BH.unlockMode then BH:SetUnlockMode(false, false, true) end
    end, EditMode)
end

--- Repaint every box (the accent changed).
function EditMode.Refresh(frames)
    for _, frame in ipairs(frames or {}) do
        if frame.sqMover and frame.sqMover.active then Paint(frame) end
    end
end
