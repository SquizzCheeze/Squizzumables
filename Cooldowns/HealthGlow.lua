-- Cooldowns/HealthGlow.lua
-- Low Health Glow (user request 2026-10-28): ring chosen icons in a group
-- while your health is below a threshold -- "you are low, pop a defensive or a
-- potion".
--
-- Your health is a SECRET in combat, so Lua can never ask "below 35%?" and
-- Show or Hide a glow on the answer. Instead the glow runs all the time on a
-- frame of its own, and the GAME decides whether it is visible:
--
--   a Step curve, 1 below the threshold and 0 above it
--   -> UnitHealthPercent("player", false, curve)   engine evaluates it
--   -> host:SetAlpha(result)                        AllowedWhenTainted
--
-- Nothing secret is read or compared in Lua. The same route as SquizzFrames'
-- health-gradient bars (curve into UnitHealthPercent, confirmed in combat) and
-- its party cooldowns (secret number into SetAlpha).
--
-- Its own host frame (proxy.HealthGlow), like ProcGlow and ActiveGlow, for the
-- reason given at their creation; and the SELF-DRAWN glow tier
-- (sqGlowSelfOnly), so it takes its own colour and Blizzard's alert code never
-- runs under a frame whose alpha is secret. The cost: no burst as it appears,
-- since the ring is already running underneath and simply fades in.
--
-- Settings live on the group (profile.cdmGroups): lowHealthGlow (on/off),
-- lowHealthPct (threshold), lowHealthGlowColor, and lowHealthIcons, a set of
-- cooldownIDs -- the icons in the group that should glow.

local addonName, ns = ...
local BH = ns.BH

local cdmModule = BH.cdm
if not cdmModule then return end

local HG = {}
cdmModule.healthGlow = HG

HG.DEFAULT_PCT   = 35
HG.DEFAULT_COLOR = { 1, 0.15, 0.15, 1 }

function HG.Pct(groupData)
    return (groupData and groupData.lowHealthPct) or HG.DEFAULT_PCT
end

HG.DEFAULT_BRIGHTNESS = 2
HG.MAX_BRIGHTNESS = 4
function HG.Brightness(groupData)
    local b = (groupData and groupData.lowHealthGlowBrightness) or HG.DEFAULT_BRIGHTNESS
    return math.max(1, math.min(HG.MAX_BRIGHTNESS, math.floor(b)))
end

function HG.Color(groupData)
    return (groupData and groupData.lowHealthGlowColor) or HG.DEFAULT_COLOR
end

-- One curve per threshold, built once. Step: each point holds until the next.
local curves = {}
local function CurveFor(pct)
    local c = curves[pct]
    if c then return c end
    if not (C_CurveUtil and C_CurveUtil.CreateCurve and Enum.LuaCurveType) then return nil end
    c = C_CurveUtil.CreateCurve()
    c:SetType(Enum.LuaCurveType.Step)
    c:AddPoint(0, 1)
    c:AddPoint(pct / 100, 0)
    curves[pct] = c
    return c
end

-- Proxies whose glow follows health, with their curve. Weak keys: a proxy
-- that is torn down simply drops out.
local live = setmetatable({}, { __mode = "k" })

local function IsDead()
    local ok, dead = pcall(UnitIsDeadOrGhost, "player")
    return ok and not BH.Secrets.IsSecret(dead) and dead or false
end

-- Never reads the result: it goes straight from the game to SetAlpha.
-- Actual health, not predicted -- an incoming heal does not mean you are safe.
local function Paint(proxy, host, curve)
    if proxy._sqOnCD or IsDead() then host:SetAlpha(0) return end
    local ok, v = pcall(UnitHealthPercent, "player", false, curve)
    if ok then
        host:SetAlpha(v)
    else
        host:SetAlpha(0)
    end
end

local function SameColor(a, b)
    return a and b and a[1] == b[1] and a[2] == b[2] and a[3] == b[3]
end

-- Called from ApplyProxyVisuals for every icon in a group, on every pass.
function HG.Apply(proxy, groupData, preview)
    local cdID = proxy and proxy.cooldownID
    local want = groupData and groupData.lowHealthGlow
        and proxy.viewerType ~= "buff" and proxy.viewerType ~= "buffbar"
        and cdID and groupData.lowHealthIcons and groupData.lowHealthIcons[cdID]
    local host = proxy and proxy.HealthGlow

    if not want then
        if host then
            for _, layer in ipairs(host.layers or { host }) do ns.Glow.Hide(layer) end
            if host.wash then host.wash.anim:Stop(); host.wash:Hide() end
            host:Hide()
        end
        if proxy then live[proxy] = nil end
        return
    end

    if not host then
        host = CreateFrame("Frame", nil, proxy)
        host:SetAllPoints()
        local raise = cdmModule.shared and cdmModule.shared.RaiseGlowFrame
        if raise then raise(host) end
        host.sqGlowSelfOnly = true
        proxy.HealthGlow = host
    end

    -- Brightness = how many copies of the ring are stacked. The ring is drawn
    -- additively, so each copy adds light (user request 2026-10-28: brighter).
    -- Copies are children of the host, so its secret alpha covers them all.
    host.layers = host.layers or { host }
    local count = HG.Brightness(groupData)
    for i = #host.layers + 1, count do
        local layer = CreateFrame("Frame", nil, host)
        layer:SetAllPoints()
        layer.sqGlowSelfOnly = true
        host.layers[i] = layer
    end

    local c = HG.Color(groupData)
    local shape = proxy.ProcGlow and proxy.ProcGlow.sqGlowShape
    for i, layer in ipairs(host.layers) do
        if i > count then
            ns.Glow.Hide(layer)
        else
            -- A glow is tinted as it starts, so a new colour restarts it.
            ---@diagnostic disable-next-line: undefined-field
            if not SameColor(layer.sqGlowColor, c) then
                layer.sqGlowColor = c
                ns.Glow.Hide(layer)
            end
            -- The icon's shape, as the other glows have it (TextAndShapes).
            ns.Glow.SetShape(layer, shape)
            ns.Glow.Show(layer)
            ns.Glow.Resize(layer)
        end
    end

    -- The ring sits mostly OUTSIDE the icon, so on a tight row it reads as
    -- being under the icons (user screenshot 2026-10-28). A pulsing wash of
    -- the same colour over the icon face puts the warning on top of it.
    -- Lives on the host, so the host's secret alpha shows and hides it too.
    local wash = host.wash
    if not wash then
        wash = host:CreateTexture(nil, "OVERLAY")
        wash:SetAllPoints(proxy.Icon or proxy)
        wash:SetTexture("Interface\\Buttons\\WHITE8X8")
        wash:SetBlendMode("ADD")
        local anim = wash:CreateAnimationGroup()
        anim:SetLooping("BOUNCE")
        local fade = anim:CreateAnimation("Alpha")
        fade:SetDuration(0.6)
        wash.fade = fade
        wash.anim = anim
        host.wash = wash
    end
    -- A shaped icon: follow its mask, so the wash does not fill the corners.
    local mask = proxy._sqMask
    if mask ~= wash.mask then
        if wash.mask then pcall(wash.RemoveMaskTexture, wash, wash.mask) end
        if mask and pcall(wash.AddMaskTexture, wash, mask) then
            wash.mask = mask
        else
            wash.mask = nil
        end
    end
    wash:SetVertexColor(c[1], c[2], c[3], 1)
    -- Brighter with the Brightness slider: 0.25-0.55 at 1, up to 0.4-0.85 at 4.
    wash.fade:SetFromAlpha(0.2 + 0.05 * count)
    wash.fade:SetToAlpha(math.min(0.85, 0.45 + 0.1 * count))
    wash:Show()
    if not wash.anim:IsPlaying() then wash.anim:Play() end
    host:Show()

    -- The options preview shows it lit, so the colour and the ticked icons
    -- can be seen without being hurt.
    if preview then
        live[proxy] = nil
        host:SetAlpha(1)
        return
    end

    local curve = CurveFor(HG.Pct(groupData))
    live[proxy] = curve
    if curve then Paint(proxy, host, curve) else host:SetAlpha(0) end
end

-- One icon, after its cooldown state (proxy._sqOnCD) was re-read in
-- ApplyProxyVisuals' greying pass.
function HG.Refresh(proxy)
    local curve = live[proxy]
    local host = proxy.HealthGlow
    if curve and host and host:IsShown() then Paint(proxy, host, curve) end
end

local function PaintAll()
    for proxy, curve in pairs(live) do
        local host = proxy.HealthGlow
        if host and host:IsShown() then Paint(proxy, host, curve) end
    end
end

local ev = CreateFrame("Frame")
ev:RegisterUnitEvent("UNIT_HEALTH", "player")
ev:RegisterUnitEvent("UNIT_MAXHEALTH", "player")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("PLAYER_DEAD")
ev:RegisterEvent("PLAYER_ALIVE")
ev:RegisterEvent("PLAYER_UNGHOST")
ev:SetScript("OnEvent", PaintAll)

-- /sq hpglow: settings, each glow frame's state, and how the curve answers.
-- Defensive end to end (it may run in combat): one pcall, a terminator line.
function HG.PrintDiagnostics()
    local S = BH.Secrets
    local function show(v)
        if S.IsSecret(v) then return "<secret>" end
        return tostring(v)
    end
    local ok, err = pcall(function()
        print("|cff33cc99Squizzumables|r Low Health Glow:")
        local specData = cdmModule.shared.GetSpecData and cdmModule.shared.GetSpecData()
        for name, gd in pairs(specData and specData.groups or {}) do
            if gd.lowHealthGlow or gd.lowHealthIcons then
                local n, ids = 0, {}
                for id in pairs(gd.lowHealthIcons or {}) do n = n + 1; ids[#ids + 1] = tostring(id) end
                print(("  group %s: on=%s pct=%s ticked=%d {%s}"):format(name,
                    tostring(gd.lowHealthGlow), tostring(HG.Pct(gd)), n, table.concat(ids, ",")))
            end
        end
        local frames = 0
        cdmModule.ForEachProxy(function(proxy, cdID, copyGroup)
            local h = proxy.HealthGlow
            if h then
                frames = frames + 1
                print(("  icon %s%s: hostShown=%s visible=%s glowing=%s tier=%s live=%s alpha=%s vt=%s")
                    :format(tostring(cdID), copyGroup and (" (copy in " .. copyGroup .. ")") or "",
                    tostring(h:IsShown()), tostring(h:IsVisible()), tostring(h.sqGlowing),
                    tostring(h.sqGlowTier), tostring(live[proxy] ~= nil), show(h:GetAlpha()),
                    tostring(proxy.viewerType)))
            end
        end)
        print(("  glow frames: %d, combat: %s"):format(frames, tostring(InCombatLockdown())))
        print("  health %: " .. show(UnitHealthPercent("player", false)))
        local pct = HG.DEFAULT_PCT
        for _, gd in pairs(specData and specData.groups or {}) do
            if gd.lowHealthGlow then pct = HG.Pct(gd) break end
        end
        local curve = CurveFor(pct)
        if curve then
            local parts = {}
            for _, x in ipairs({ 0.05, 0.2, pct / 100 - 0.01, pct / 100, pct / 100 + 0.01, 0.6, 1 }) do
                local okE, y = pcall(curve.Evaluate, curve, x)
                parts[#parts + 1] = ("%.2f->%s"):format(x, okE and show(y) or "err")
            end
            print(("  curve (%d%%): %s"):format(pct, table.concat(parts, "  ")))
            local okU, y = pcall(UnitHealthPercent, "player", false, curve)
            print("  curve at your health: " .. (okU and show(y) or ("error " .. tostring(y))))
        else
            print("  curve: could not be created")
        end
    end)
    if not ok then print("  error: " .. tostring(err)) end
    print("  -- end of hpglow --")
end

-- Label and icon for one member of a group, for the options checklist.
-- item: { cdID, spellID, equipSlot, spellCategory } (cdmModule:PreviewMembers).
function HG.MemberLabel(item)
    if item.spellCategory and cdmModule.CategoryLabel then
        return cdmModule.CategoryLabel(item.spellCategory)
    end
    if item.equipSlot then
        local itemID = GetInventoryItemID("player", item.equipSlot)
        local name = itemID and C_Item.GetItemNameByID(itemID)
        local icon = itemID and C_Item.GetItemIconByID(itemID)
        return name or ("Equip slot " .. item.equipSlot), icon
    end
    local name = item.spellID and C_Spell.GetSpellName(item.spellID)
    local icon = item.spellID and C_Spell.GetSpellTexture(item.spellID)
    if name and BH.Secrets.IsSecret(name) then name = nil end
    if icon and BH.Secrets.IsSecret(icon) then icon = nil end
    return name or ("Cooldown " .. tostring(item.cdID)), icon
end
