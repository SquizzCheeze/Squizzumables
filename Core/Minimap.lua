-- Core/Minimap.lua
-- Minimap button and addon-compartment entry.
--
-- Written rather than taken from LibDBIcon, which would mean vendoring both
-- LibDataBroker-1.1 and LibDBIcon-1.0 to get one draggable icon. The whole of
-- what those provide that matters here is "remember where round the minimap the
-- player put it", which is one number.
--
-- The compartment entry needs no code at all beyond a global function: Blizzard
-- reads AddonCompartmentFunc and IconTexture straight out of the .toc (see
-- Blizzard_Minimap/AddonCompartment.lua), so the addon appears in that menu
-- whether or not the minimap button is shown.

local addonName, ns = ...
ns.BH = ns.BH or {}
local BH = ns.BH

local ICON = "Interface\\Icons\\INV_Misc_Food_15"
local BUTTON_SIZE = 31
local ICON_SIZE   = 20

-- Distance from the minimap centre. Minimap is circular for most players and
-- square for some; 80 sits on the edge of the default round one.
local ORBIT_RADIUS = 80

local button

--- Place the button at `angle` degrees around the minimap.
local function PositionButton(angle)
    if not button then return end
    local rad = math.rad(angle)
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER",
        math.cos(rad) * ORBIT_RADIUS,
        math.sin(rad) * ORBIT_RADIUS)
end

--- Angle from the minimap centre to the cursor, so dragging feels like the
--- button is being slid around the rim rather than followed.
local function AngleToCursor()
    local mx, my = Minimap:GetCenter()
    local scale = Minimap:GetEffectiveScale()
    local cx, cy = GetCursorPosition()
    cx, cy = cx / scale, cy / scale
    return math.deg(math.atan2(cy - my, cx - mx))
end

function BH:UpdateMinimapButton()
    if not button then return end
    local show = not (self.settings and self.settings.minimapButtonHidden)
    button:SetShown(show)
    PositionButton((self.settings and self.settings.minimapButtonAngle) or 200)
end

-- The compartment entry. Named globals because the .toc references them by
-- name; Blizzard calls them with (addonName, buttonFrame).
function Squizzumables_OnAddonCompartmentClick(_, mouseButton)
    if mouseButton == "RightButton" then
        BH:SetUnlockMode(not BH.unlockMode)
    else
        BH:CreateOptionsPanel()
    end
end

function Squizzumables_OnAddonCompartmentEnter(_, frame)
    GameTooltip:SetOwner(frame, "ANCHOR_LEFT")
    GameTooltip:AddLine("Squizzumables")
    GameTooltip:AddLine("Left-click: settings", 1, 1, 1)
    GameTooltip:AddLine("Right-click: unlock frames", 1, 1, 1)
    GameTooltip:Show()
end

function Squizzumables_OnAddonCompartmentLeave()
    GameTooltip:Hide()
end

local function CreateMinimapButton()
    if button then return button end

    button = CreateFrame("Button", "SquizzumablesMinimapButton", Minimap)
    button:SetSize(BUTTON_SIZE, BUTTON_SIZE)
    button:SetFrameStrata("MEDIUM")
    button:SetFrameLevel(8)
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    button:RegisterForDrag("LeftButton")
    button:SetMovable(true)

    local overlay = button:CreateTexture(nil, "OVERLAY")
    overlay:SetSize(53, 53)
    overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    overlay:SetPoint("TOPLEFT")

    local bg = button:CreateTexture(nil, "BACKGROUND")
    bg:SetSize(20, 20)
    bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    bg:SetPoint("TOPLEFT", 7, -5)

    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetSize(ICON_SIZE, ICON_SIZE)
    icon:SetTexture(ICON)
    icon:SetPoint("TOPLEFT", 7, -6)
    -- Trim the icon's built-in border so it sits inside the ring cleanly.
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

    button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    button:SetScript("OnClick", function(_, mouseButton)
        if mouseButton == "RightButton" then
            BH:SetUnlockMode(not BH.unlockMode)
        else
            BH:CreateOptionsPanel()
        end
    end)

    button:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", function()
            local angle = AngleToCursor()
            BH.settings.minimapButtonAngle = angle
            PositionButton(angle)
        end)
    end)
    button:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
        BH:SaveSettings()
    end)

    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("Squizzumables")
        GameTooltip:AddLine("Left-click: settings", 1, 1, 1)
        GameTooltip:AddLine("Right-click: unlock frames", 1, 1, 1)
        GameTooltip:AddLine("Drag: move around the minimap", 1, 1, 1)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)

    return button
end

-- Built at login, after settings are loaded so the saved angle is available.
local loader = CreateFrame("Frame")
loader:RegisterEvent("PLAYER_LOGIN")
loader:SetScript("OnEvent", function()
    CreateMinimapButton()
    BH:UpdateMinimapButton()
end)
