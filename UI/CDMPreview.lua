local addonName, ns = ...

-- ============================================================================
-- CDM options preview (V1.89)
-- ============================================================================
-- A 1:1 picture of a cooldown group, at the top of its sub-tab on the
-- Cooldowns page and inline under each group on Custom Icons.
--
-- THE RULE: it is drawn by the real code, never a copy. Icons are built by
-- CreateProxyIcon and styled by ApplyProxyVisuals (in preview mode, which
-- skips live state and the sound alerts); buffs use the real placeholders from
-- GetBuffPlaceholder; placement is cdmModule.Grid, the same maths the groups
-- on screen use. All of it comes through cdmModule.PreviewKit, assembled at
-- the end of Squizzumables_CDM.lua. A preview carrying its own copy of any of
-- this would start lying the first time the real one changed.
--
-- What it cannot show is live state, so that is mocked: one icon procced,
-- one on a running cooldown, one with stacks, and the buffs drawn as they look
-- while up. It redraws four times a second while visible, which is what makes
-- every setting on the page show up without each control having to know the
-- preview exists.
--
-- 1:1 means the icons match the size they are on screen, whatever the options
-- window's own scale is: the host frame is scaled by UIParent's effective scale
-- over the pane's. A group too big for the pane is scaled down to fit, and the
-- pane says so.
-- ============================================================================

local BH = ns.BH

local Preview = {}
ns.CDMPreview = Preview

local SQ_COLORS = ns.SQ_COLORS

local SAMPLE_ICON   = 134400   -- INV_Misc_QuestionMark
local SAMPLE_COUNT  = 4        -- stand-ins shown for an empty group
local PAD           = 10
local TITLE_H       = 18
local MAX_PINNED_H  = 190      -- the pinned pane never eats more of the tab than this
local INLINE_H      = 110      -- inline panes have a fixed height: the page lays out once
local GLOW_MARGIN   = 12       -- room for a glow or text spilling past the icons
local REFRESH_EVERY = 0.25

-- Custom Icons panes, kept per group across rebuilds: the page's rebuild
-- orphans every child it finds, and a frame cannot be destroyed, so a pane
-- built per rebuild would simply leak.
local inlinePanes = {}

-- ----------------------------------------------------------------------------
-- Helpers
-- ----------------------------------------------------------------------------

local function Kit()
    local cdm = BH.cdm
    return cdm and cdm.PreviewKit, cdm
end

-- The real icons pin their glow frames to MEDIUM strata (RaiseGlowFrame), which
-- would draw the preview's glows UNDER the options window. Lift them to the
-- pane's strata -- preview icons only; the real ones are untouched.
local function LiftToStrata(proxy, strata)
    proxy:SetFrameStrata(strata)
    for _, key in ipairs({ "GlowFrame", "ProcGlow", "ActiveGlow" }) do
        local f = proxy[key]
        if f then
            f:SetFixedFrameStrata(false)
            f:SetFrameStrata(strata)
            f:SetFixedFrameStrata(true)
        end
    end
end

-- One icon, the same way the icon grid colours it: desaturation follows the
-- group's two grey-out options against the mock "is this one on cooldown".
local function ApplyMockDesaturation(icon, gd, onCD)
    if gd.desaturateOnCooldown then
        icon:SetDesaturated(onCD)
    elseif gd.desaturateReady then
        icon:SetDesaturated(not onCD)
    else
        icon:SetDesaturated(false)
    end
end

-- A running cooldown on the mock "icon 2", restarted whenever it finishes so
-- the sweep and countdown are always there to look at. Our own Cooldown frame
-- and plain numbers, so no secret-aspect rules apply.
local MOCK_CD = 12
local function StartMockCooldown(cd)
    cd:SetCooldown(GetTime(), MOCK_CD)
end

-- ----------------------------------------------------------------------------
-- Drawing
-- ----------------------------------------------------------------------------

local function HideAllIcons(pane)
    for _, proxy in pairs(pane.proxies) do proxy:Hide() end
end

local function DrawProxyIcons(pane, kit, cdm, gd, items, g)
    local strata = pane:GetFrameStrata()
    local used = {}
    for i, item in ipairs(items) do
        local key = item.cdID or ("sample" .. i)
        local proxy = pane.proxies[key]
        if not proxy then
            proxy = kit.CreateProxyIcon(item.cdID, item.spellID, g.size, item.equipSlot)
            proxy:SetParent(pane.host)
            -- No mouse: the preview is a picture, and a tooltip on it would
            -- only get in the way of the controls around it.
            proxy:EnableMouse(false)
            pane.proxies[key] = proxy
        end
        used[key] = true
        LiftToStrata(proxy, strata)
        proxy.viewerType = item.viewerType or "cooldown"
        if item.sample then
            proxy.Icon:SetTexture(SAMPLE_ICON)
            proxy._iconSet = true
        end

        proxy:SetSize(g.size, g.size)
        proxy.Icon:SetAllPoints()
        proxy.Cooldown:SetAllPoints()
        proxy:ClearAllPoints()
        local point, relPoint, x, y = cdm.Grid.IconSlot(g, i)
        proxy:SetPoint(point, pane.host, relPoint, x, y)

        -- Tooltip setup inside ApplyProxyVisuals enables the mouse; switched
        -- straight back off after it.
        kit.ApplyProxyVisuals(proxy, gd, true)
        proxy:EnableMouse(false)

        -- Mock state. Icon 1 procced, icon 2 on cooldown, icon 3 with stacks.
        local isCooldownType = proxy.viewerType ~= "buff"
        kit.SetProcGlow(proxy, i == 1 and isCooldownType and gd.procGlow ~= false, true)

        local onCD = (i == 2)
        if onCD then
            if not proxy._sqPreviewCD then
                proxy._sqPreviewCD = true
                proxy.Cooldown:SetScript("OnCooldownDone", StartMockCooldown)
                StartMockCooldown(proxy.Cooldown)
            end
        elseif proxy._sqPreviewCD then
            proxy._sqPreviewCD = nil
            proxy.Cooldown:SetScript("OnCooldownDone", nil)
            proxy.Cooldown:Clear()
        end
        ApplyMockDesaturation(proxy.Icon, gd, onCD)

        if proxy.Count then
            proxy.Count:SetText((i == 3 and gd.showCount ~= false) and "2" or "")
        end
        -- A stand-in has no spell to find a key for; show where the keybind
        -- would sit rather than nothing.
        if item.sample and proxy._sqKeybind and gd.showKeybind then
            proxy._sqKeybind:SetText("Q")
        end
        proxy:Show()
    end
    for key, proxy in pairs(pane.proxies) do
        if not used[key] then proxy:Hide() end
    end
end

local function DrawPlaceholders(pane, kit, cdm, gd, items, g, isBar)
    local strata = pane:GetFrameStrata()
    local group = pane.group
    local slots = {}
    -- With Always Show Buffs on, half the row is drawn as up and half as
    -- held-but-inactive, so both looks are visible. Otherwise every slot is
    -- drawn as up, which is all the real row ever shows.
    local liveCount = gd.showInactiveBuffs and math.max(1, math.ceil(#items / 2)) or #items
    for i, item in ipairs(items) do
        -- Negative stand-in IDs can never collide with a real cooldownID.
        local cdID = item.cdID or -i
        group.previewLook = (i <= liveCount)
        local ph = cdm:GetBuffPlaceholder(group, cdID, gd)
        group.previewLook = nil
        ph:SetFrameStrata(strata)
        if item.sample and not ph._iconSet then
            ph.Icon:SetTexture(SAMPLE_ICON)
        end
        ph:ClearAllPoints()
        if isBar then
            ph:SetSize(g.width, g.barH)
            local point, relPoint, x, y = cdm.Grid.BarSlot(g, i)
            ph:SetPoint(point, pane.host, relPoint, x, y)
        else
            ph:SetSize(g.size, g.size)
            local point, relPoint, x, y = cdm.Grid.IconSlot(g, i)
            ph:SetPoint(point, pane.host, relPoint, x, y)
            kit.ApplyShapeToBorrowedChild(ph, gd.iconShape or "none",
                gd.iconZoom or kit.DEFAULT_ICON_ZOOM)
        end
        kit.ApplyKeybindText(ph, item.spellID, gd)
        slots[#slots + 1] = ph
    end
    cdm:ReleaseUnusedPlaceholders(group, slots)
end

-- ----------------------------------------------------------------------------
-- Refresh
-- ----------------------------------------------------------------------------

function Preview.Refresh(pane)
    local kit, cdm = Kit()
    if not kit or not pane:IsVisible() then return end
    local width = pane:GetWidth()
    if not width or width <= 0 then return end

    local specData = kit.GetSpecData()
    local gd = specData and specData.groups and specData.groups[pane.groupName]
    if not gd then
        HideAllIcons(pane)
        pane.host:Hide()
        pane.note:SetText("Nothing to preview for this spec yet.")
        return
    end
    pane.host:Show()

    local members = cdm:PreviewMembers(pane.groupName)
    local items = members.items
    local sample = (#items == 0)
    if sample then
        items = {}
        for i = 1, SAMPLE_COUNT do items[i] = { sample = true } end
    end

    -- Bars only for a borrowed bar group: LayoutGroup lays proxy icons on the
    -- icon grid whatever isBarGroup says, and the borrowed pass is the one that
    -- stacks bars. Orientation likewise only reaches proxy groups.
    local isBar = members.borrowed and gd.isBarGroup and true or false
    local g
    if isBar then
        g = cdm.Grid.Bars(#items, gd)
    else
        g = cdm.Grid.Icons(#items, gd, (not members.borrowed) and gd.orientation == "vertical")
    end

    if members.borrowed then
        HideAllIcons(pane)
        DrawPlaceholders(pane, kit, cdm, gd, items, g, isBar)
    else
        cdm:ReleaseUnusedPlaceholders(pane.group, {})
        DrawProxyIcons(pane, kit, cdm, gd, items, g)
    end

    pane.host:SetSize(g.width, g.height)
    kit.ApplyBarBackground(pane.group, gd)

    -- Scale: true size first, then shrink to fit if it must.
    local trueScale = UIParent:GetEffectiveScale() / pane:GetEffectiveScale()
    local needW = (g.width + GLOW_MARGIN * 2) * trueScale
    local needH = (g.height + GLOW_MARGIN * 2) * trueScale
    local availW = width - PAD * 2
    local maxH = (pane.fixedHeight or MAX_PINNED_H) - TITLE_H - PAD * 2
    local fit = math.min(1, availW / needW, maxH / needH)
    pane.host:SetScale(trueScale * fit)

    if not pane.fixedHeight then
        local h = math.floor(TITLE_H + PAD * 2 + needH * fit + 0.5)
        if math.abs((pane:GetHeight() or 0) - h) >= 1 then pane:SetHeight(h) end
    end

    local notes = {}
    if fit < 0.999 then
        notes[#notes + 1] = ("Scaled to %d%% to fit"):format(math.floor(fit * 100 + 0.5))
    else
        notes[#notes + 1] = "Actual size"
    end
    if sample then notes[#notes + 1] = "no spells in this group yet" end
    if gd.enabled == false then notes[#notes + 1] = "group is switched off" end
    pane.note:SetText(table.concat(notes, " - "))
    -- Switched off draws nothing in game; dimmed here rather than blank, so
    -- the settings can still be seen doing something.
    pane.host:SetAlpha(gd.enabled == false and 0.35 or 1)
end

-- ----------------------------------------------------------------------------
-- Construction
-- ----------------------------------------------------------------------------

local function CreatePane(parent, groupName)
    local pane = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    pane.groupName = groupName
    pane:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeSize = 1,
    })
    pane:SetBackdropColor(0.03, 0.03, 0.04, 0.85)
    local b = SQ_COLORS and SQ_COLORS.border or { 0.3, 0.3, 0.35 }
    pane:SetBackdropBorderColor(b[1], b[2], b[3], 0.7)
    pane:SetHeight(INLINE_H)
    -- The glow frames are lifted to the pane's strata and ride high levels;
    -- clipping keeps a big glow from spilling over the settings below.
    pane:SetClipsChildren(true)

    local title = pane:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    title:SetPoint("TOPLEFT", pane, "TOPLEFT", PAD, -5)
    title:SetText("PREVIEW")
    if ns.ApplyAccent then ns.ApplyAccent(title, "text") end

    local note = pane:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    note:SetPoint("TOPRIGHT", pane, "TOPRIGHT", -PAD, -5)
    note:SetPoint("LEFT", title, "RIGHT", 12, 0)
    note:SetJustifyH("RIGHT")
    note:SetWordWrap(false)
    note:SetTextColor(0.55, 0.55, 0.55)
    pane.note = note

    -- The area below the title, at scale 1; the host centres in it. Offsets on
    -- the host itself would be in its own (scaled) units, so it takes none.
    local holder = CreateFrame("Frame", nil, pane)
    holder:SetPoint("TOPLEFT", pane, "TOPLEFT", PAD, -(TITLE_H + 2))
    holder:SetPoint("BOTTOMRIGHT", pane, "BOTTOMRIGHT", -PAD, PAD - 2)

    local host = CreateFrame("Frame", nil, holder)
    host:SetPoint("CENTER", holder, "CENTER")
    host:SetSize(1, 1)
    pane.host = host

    -- Stands in for a real group table wherever the kit wants one: the
    -- placeholders and the bar background hang off group.container.
    pane.group = { container = host, placeholders = {} }
    pane.proxies = {}

    local elapsed = 0
    pane:SetScript("OnUpdate", function(self, dt)
        elapsed = elapsed + dt
        if elapsed < REFRESH_EVERY then return end
        elapsed = 0
        Preview.Refresh(self)
    end)
    pane:SetScript("OnShow", function(self)
        elapsed = 0
        Preview.Refresh(self)
    end)
    -- Width is only known once laid out; the first real pass happens then.
    pane:SetScript("OnSizeChanged", function(self) Preview.Refresh(self) end)
    return pane
end

-- Pinned at the top of a Cooldowns sub-tab (SubTabs.Create page), between the
-- tab strip and the page's scroller. The scroller is re-anchored below the
-- pane, so the settings scroll underneath a preview that stays put, and the
-- pane's height -- which follows the group -- moves the scroller with it.
function Preview.AttachToSubTab(page, groupName)
    local scroller = page and page.scroller
    if not scroller or page._sqPreview then return end
    local _, strip, relPoint, x, y = scroller:GetPoint(1)
    if not strip then return end
    local parent = scroller:GetParent()

    local pane = CreatePane(parent, groupName)
    pane:SetPoint("TOPLEFT", strip, relPoint or "BOTTOMLEFT", (x or 0) + 12, y or -4)
    pane:SetPoint("TOPRIGHT", strip, "BOTTOMRIGHT", -34, y or -4)
    scroller:SetPoint("TOPLEFT", pane, "BOTTOMLEFT", -12, -6)

    pane:SetShown(scroller:IsShown())
    scroller:HookScript("OnShow", function() pane:Show() end)
    scroller:HookScript("OnHide", function() pane:Hide() end)
    page._sqPreview = pane
    return pane
end

-- Inline under a group's heading on Custom Icons. Fixed height, because that
-- page is laid out once by running offsets; a group too big for it is scaled
-- to fit, like any other. Returns the offset below the pane.
function Preview.PlaceInline(content, groupName, leftPad, yOffset)
    local pane = inlinePanes[groupName]
    if not pane then
        pane = CreatePane(content, groupName)
        pane.fixedHeight = INLINE_H
        inlinePanes[groupName] = pane
    else
        pane:SetParent(content)
    end
    pane:ClearAllPoints()
    pane:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad + 10, yOffset)
    pane:SetPoint("TOPRIGHT", content, "TOPRIGHT", -10, yOffset)
    pane:SetHeight(INLINE_H)
    pane:Show()
    return yOffset - INLINE_H - 10
end
