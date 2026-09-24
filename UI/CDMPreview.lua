local addonName, ns = ...

-- ============================================================================
-- CDM options preview (V1.89)
-- ============================================================================
-- A 1:1 picture of a cooldown group, at the top of its sub-tab on the CDM
-- page and inline under each group on Custom Icons, with a button through to
-- Blizzard's own Cooldown Manager settings.
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
-- over the pane's. It is never scaled down: a group too big for the pane
-- scrolls inside it, with the title, note and button left where they are.
-- ============================================================================

local BH = ns.BH

local Preview = {}
ns.CDMPreview = Preview

local SQ_COLORS = ns.SQ_COLORS

local SAMPLE_ICON   = 134400   -- INV_Misc_QuestionMark
local SAMPLE_COUNT  = 4        -- stand-ins shown for an empty group
local PAD           = 10
local TITLE_H       = 18
local MAX_PINNED_H  = 210      -- the pinned pane never eats more of the tab than this
local INLINE_H      = 130      -- inline panes have a fixed height: the page lays out once
local BUTTON_H      = 20       -- the Blizzard CDM button along the bottom edge
local FOOTER_H      = BUTTON_H + 6
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

-- Opens (or closes) Blizzard's Cooldown Manager settings, so a group can be
-- edited there with its preview in view.
--
-- CooldownViewerSettings:ShowUIPanel / HideUIPanel are Blizzard's own paths
-- (CooldownViewerSettings.lua, TogglePanel; /cdm in CooldownManagerCentered
-- calls the same). Not in combat, as that addon also declines: the window
-- sits beside Edit Mode, which does not open mid-fight.
--
-- Blizzard's window has no strata of its own, so it is MEDIUM, and the
-- options window is DIALOG -- wherever the two overlap, Blizzard's would be
-- underneath ours. It is lifted to DIALOG while it is open and put back the
-- moment it closes, so outside this button nothing about it changes.
local blizzLiftedFrom
local blizzHideHooked = false
local function ToggleBlizzardCDMSettings()
    if InCombatLockdown() then
        print("|cff00ccffSquizzumables|r: Blizzard's Cooldown Manager settings can't be opened in combat.")
        return
    end
    if not CooldownViewerSettings and C_AddOns and C_AddOns.LoadAddOn then
        C_AddOns.LoadAddOn("Blizzard_CooldownViewer")
    end
    local settings = CooldownViewerSettings
    if not settings then return end

    if settings:IsShown() then
        HideUIPanel(settings)
        return
    end
    if not blizzHideHooked then
        blizzHideHooked = true
        settings:HookScript("OnHide", function(self)
            if blizzLiftedFrom then
                self:SetFrameStrata(blizzLiftedFrom)
                blizzLiftedFrom = nil
            end
        end)
    end
    settings:ShowUIPanel(false)
    if not blizzLiftedFrom then
        blizzLiftedFrom = settings:GetFrameStrata()
        settings:SetFrameStrata("DIALOG")
    end
    settings:Raise()
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

local BAR_W = 6          -- scroll bar thickness
local WHEEL_STEP = 24    -- pixels per mouse-wheel notch

-- Fit a view scroll bar to what is visible (viewLen) against what there is
-- (canvasLen). No overflow: hidden, and the view put back to its start.
local function UpdateScrollBar(bar, viewLen, canvasLen, apply)
    local range = canvasLen - viewLen
    if range < 1 then
        bar:SetMinMaxValues(0, 0)
        bar:SetValue(0)
        apply(0)
        bar:Hide()
        return false
    end
    bar:SetMinMaxValues(0, range)
    if bar:GetValue() > range then bar:SetValue(range) end
    local len = math.max(14, viewLen * viewLen / canvasLen)
    if bar.horizontal then
        bar.thumb:SetSize(len, BAR_W)
    else
        bar.thumb:SetSize(BAR_W, len)
    end
    bar:Show()
    return true
end

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
    -- stacks bars.
    local isBar = members.borrowed and gd.isBarGroup and true or false
    local g
    if isBar then
        g = cdm.Grid.Bars(#items, gd)
    else
        g = cdm.Grid.Icons(#items, gd, gd.orientation == "vertical")
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

    -- Always true size: the host takes UIParent's effective scale relative to
    -- the pane, and nothing shrinks it. What does not fit scrolls.
    local trueScale = UIParent:GetEffectiveScale() / pane:GetEffectiveScale()
    pane.host:SetScale(trueScale)
    local needW = (g.width + GLOW_MARGIN * 2) * trueScale
    local needH = (g.height + GLOW_MARGIN * 2) * trueScale

    -- A pinned pane grows with its group up to its cap; an inline one has a
    -- fixed height. The view's size is worked out here rather than read back,
    -- because a height set this pass is not laid out until the next frame.
    local chromeH = (TITLE_H + 2) + (PAD - 2 + FOOTER_H)
    local paneH = pane.fixedHeight
    if not paneH then
        paneH = math.floor(math.min(MAX_PINNED_H, chromeH + needH) + 0.5)
        if math.abs((pane:GetHeight() or 0) - paneH) >= 1 then pane:SetHeight(paneH) end
    end
    local viewW = width - PAD * 2
    local viewH = paneH - chromeH
    local canvasW = math.max(viewW, needW)
    local canvasH = math.max(viewH, needH)
    pane.canvas:SetSize(canvasW, canvasH)

    local view = pane.view
    local scrollsX = UpdateScrollBar(pane.hbar, viewW, canvasW,
        function(v) view:SetHorizontalScroll(v) end)
    local scrollsY = UpdateScrollBar(pane.vbar, viewH, canvasH,
        function(v) view:SetVerticalScroll(v) end)
    view:EnableMouseWheel(scrollsX or scrollsY)

    local notes = { "Actual size" }
    if scrollsX or scrollsY then notes[#notes + 1] = "scroll to see it all" end
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

-- A slim scroll bar for the view: a plain Slider whose thumb is sized to the
-- visible fraction. Hidden, and the view reset, when nothing overflows.
local function MakeScrollBar(pane, horizontal, apply)
    local bar = CreateFrame("Slider", nil, pane)
    bar:SetOrientation(horizontal and "HORIZONTAL" or "VERTICAL")
    bar:SetObeyStepOnDrag(false)
    local bg = bar:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(1, 1, 1, 0.08)
    local thumb = bar:CreateTexture(nil, "OVERLAY")
    thumb:SetColorTexture(0.65, 0.65, 0.7, 0.85)
    bar:SetThumbTexture(thumb)
    bar.thumb = thumb
    bar.horizontal = horizontal
    bar:SetMinMaxValues(0, 0)
    bar:SetValue(0)
    bar:SetScript("OnValueChanged", function(_, v) apply(v) end)
    bar:Hide()
    return bar
end

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

    -- The view: a ScrollFrame between the title line and the button row. The
    -- group is ALWAYS drawn at true size inside it -- never scaled to fit
    -- (user request 2026-09-24); a group bigger than the view scrolls, and
    -- only the view moves: the title, the note and the button stay put.
    --
    -- The canvas is the scroll child, at scale 1 and at least as big as the
    -- view; the host centres in it. Offsets on the host itself would be in its
    -- own (scaled) units, so it takes none.
    local view = CreateFrame("ScrollFrame", nil, pane)
    view:SetPoint("TOPLEFT", pane, "TOPLEFT", PAD, -(TITLE_H + 2))
    view:SetPoint("BOTTOMRIGHT", pane, "BOTTOMRIGHT", -PAD, PAD - 2 + FOOTER_H)
    local canvas = CreateFrame("Frame", nil, view)
    canvas:SetSize(1, 1)
    view:SetScrollChild(canvas)
    pane.view, pane.canvas = view, canvas

    pane.hbar = MakeScrollBar(pane, true, function(v) view:SetHorizontalScroll(v) end)
    pane.hbar:SetPoint("TOPLEFT", view, "BOTTOMLEFT", 0, -2)
    pane.hbar:SetPoint("TOPRIGHT", view, "BOTTOMRIGHT", 0, -2)
    pane.hbar:SetHeight(BAR_W)
    pane.vbar = MakeScrollBar(pane, false, function(v) view:SetVerticalScroll(v) end)
    pane.vbar:SetPoint("TOPLEFT", view, "TOPRIGHT", 2, 0)
    pane.vbar:SetPoint("BOTTOMLEFT", view, "BOTTOMRIGHT", 2, 0)
    pane.vbar:SetWidth(BAR_W)

    -- Wheel scrolls the view; Shift, or a view that only overflows sideways,
    -- scrolls horizontally. Only enabled while something overflows (Refresh),
    -- so otherwise the wheel still scrolls the settings page underneath.
    view:SetScript("OnMouseWheel", function(_, delta)
        local horiz = IsShiftKeyDown() or not pane.vbar:IsShown()
        local bar = horiz and pane.hbar or pane.vbar
        if bar:IsShown() then
            bar:SetValue(bar:GetValue() - delta * WHEEL_STEP)
        end
    end)
    view:EnableMouseWheel(false)

    -- Bottom left: straight to Blizzard's Cooldown Manager settings, which is
    -- where what a group CONTAINS is decided. Toggles, so the same button
    -- closes it again.
    local blizzBtn = ns.CreateSQButton(pane, "Blizzard CDM Settings", 150, BUTTON_H)
    blizzBtn:SetPoint("BOTTOMLEFT", pane, "BOTTOMLEFT", PAD - 4, 5)
    blizzBtn:SetScript("OnClick", ToggleBlizzardCDMSettings)
    if ns.Rows and ns.Rows.AddTooltip then
        ns.Rows.AddTooltip(blizzBtn, "Blizzard CDM Settings",
            "Opens Blizzard's Cooldown Manager settings, where you choose which spells "
         .. "each bar tracks. Changes show up in this preview as you make them. "
         .. "Click again to close it.")
    end

    local host = CreateFrame("Frame", nil, canvas)
    host:SetPoint("CENTER", canvas, "CENTER")
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
-- page is laid out once by running offsets; a group too big for it scrolls,
-- like any other. Returns the offset below the pane.
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
