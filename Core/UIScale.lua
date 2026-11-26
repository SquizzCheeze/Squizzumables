-- Core/UIScale.lua
-- The whole interface's scale, set the way ElvUI sets it: UIParent:SetScale
-- straight from a saved number, so it can go below the game's own 0.64 floor
-- (the Graphics > UI Scale slider stops there). 768 / the screen's physical
-- height is "pixel perfect": one UI unit is one screen pixel, so 1px borders
-- come out even on every edge. At 1080p that is 0.7111.
--
-- Account-wide (SquizzumablesDB.uiScale), like ElvUI's own setting: a scale
-- belongs to the screen, not to a character or a profile.
--
-- WHILE ELVUI IS LOADED IT STAYS IN CHARGE. Two addons calling SetScale on
-- UIParent fight each other, and ElvUI's pixel maths (E.mult) is worked out
-- from ITS value, so overriding it would put ElvUI's own borders a fraction
-- off. Instead we copy ElvUI's value at every login and grey the controls out.
-- The first copy also switches the setting on, so the day ElvUI is turned off
-- the scale carries straight over and no frame moves.
--
-- ElvUI's behaviour copied here (ElvUI/Game/Shared/General/PixelPerfect.lua):
-- the scale waits for combat to end, and is put back on UI_SCALE_CHANGED,
-- which is when the client re-applies its own CVar scale to UIParent.

local addonName, ns = ...
ns.BH = ns.BH or {}
local BH = ns.BH

local UIScale = {}
ns.UIScale = UIScale

-- ElvUI's slider range (its soft limits) and its preset buttons.
UIScale.MIN, UIScale.MAX = 0.40, 1.15
UIScale.PRESETS = {
    { label = "Small",  value = 0.6 },
    { label = "Medium", value = 0.7 },
    { label = "Large",  value = 0.8 },
}

local function Clamp(v)
    return math.max(UIScale.MIN, math.min(UIScale.MAX, v))
end

function UIScale.DB()
    if not SquizzumablesDB then return nil end
    SquizzumablesDB.uiScale = SquizzumablesDB.uiScale or {}
    return SquizzumablesDB.uiScale
end

-- 768 / physical height, the same sum as ElvUI's PixelBestSize.
function UIScale.PixelPerfect()
    local _, height = GetPhysicalScreenSize()
    if not height or height <= 0 then return 0.7111 end
    return Clamp(768 / height)
end

function UIScale.ElvUIActive()
    return C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("ElvUI") and true or false
end

-- ElvUI's current scale, or nil. E.global already has ElvUI's defaults merged
-- in, so a player who never touched the setting still reads ElvUI's 0.64.
function UIScale.ElvUIValue()
    local elv = _G["ElvUI"]
    local E = type(elv) == "table" and elv[1]
    local general = E and E.global and E.global.general
    local v = general and tonumber(general.UIScale)
    if v and v > 0 then return v end
    return nil
end

-- True when this addon is the one setting the scale.
function UIScale.Managing()
    local db = UIScale.DB()
    return db ~= nil and db.enabled == true and not UIScale.ElvUIActive()
end

local waiter = CreateFrame("Frame")
waiter:Hide()

function UIScale.Apply()
    if not UIScale.Managing() then return end
    local db = UIScale.DB()
    if not db or not db.value then return end
    if InCombatLockdown() then
        waiter:RegisterEvent("PLAYER_REGEN_ENABLED")
        return
    end
    UIParent:SetScale(Clamp(db.value))
end

-- From the options slider: store at once, but apply only when the mouse is
-- let go. Rescaling UIParent mid-drag moves the slider out from under the
-- cursor (ElvUI waits for the button too).
function UIScale.SetValue(v)
    local db = UIScale.DB()
    if not db or not tonumber(v) then return end
    db.value = Clamp(tonumber(v))
    if IsMouseButtonDown() then
        waiter:Show()
    else
        UIScale.Apply()
    end
end

waiter:SetScript("OnUpdate", function(self)
    if IsMouseButtonDown() then return end
    self:Hide()
    UIScale.Apply()
end)

StaticPopupDialogs["SQUIZZUMABLES_UISCALE_RELOAD"] = {
    text = "The game's own UI scale comes back after a reload. Reload now?",
    button1 = "Reload",
    button2 = "Later",
    OnAccept = function() ReloadUI() end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

function UIScale.SetEnabled(on)
    local db = UIScale.DB()
    if not db then return end
    db.enabled = on and true or false
    if db.enabled then
        if not db.value then db.value = UIScale.PixelPerfect() end
        UIScale.Apply()
    else
        -- The client only re-applies its CVar scale on its own events, so
        -- the cleanest way back is a reload rather than guessing its value.
        StaticPopup_Show("SQUIZZUMABLES_UISCALE_RELOAD")
    end
end

waiter:RegisterEvent("PLAYER_LOGIN")
waiter:RegisterEvent("UI_SCALE_CHANGED")
waiter:RegisterEvent("DISPLAY_SIZE_CHANGED")
waiter:SetScript("OnEvent", function(self, event)
    if event == "PLAYER_REGEN_ENABLED" then
        self:UnregisterEvent("PLAYER_REGEN_ENABLED")
        UIScale.Apply()
        return
    end
    if event == "PLAYER_LOGIN" then
        local db = UIScale.DB()
        if not db then return end
        if UIScale.ElvUIActive() then
            local v = UIScale.ElvUIValue()
            if v then
                db.value = Clamp(v)
                if db.enabled == nil then db.enabled = true end
            end
            return
        end
        if not db.value then db.value = UIScale.PixelPerfect() end
    end
    UIScale.Apply()
end)
