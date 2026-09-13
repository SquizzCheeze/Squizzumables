-- UI/Glow.lua
-- One way to make a button glow, with a fallback ladder behind it.
--
-- Written rather than taken from LibCustomGlow, which is ~700 lines to vendor
-- for an effect the client already draws on every action button. What that
-- library really buys is choice of style; this needs one style that matches
-- what the player already sees elsewhere in their UI.
--
-- Three tiers, best first:
--
--   1. ActionButtonSpellAlertManager:ShowAlert / HideAlert -- the current API,
--      and what Blizzard's own action buttons use.
--   2. ActionButton_ShowOverlayGlow -- deprecated, and the Lua server warns on
--      it, but still present on some builds. Kept only as a bridge.
--   3. A plain pulsing texture of our own, so the feature degrades to something
--      rather than nothing if both disappear.
--
-- A frame given a shape (Glow.SetShape -- the CDM does this for a shaped icon)
-- stays on tier 1 with Blizzard's art swapped for flipbooks in its shape (see
-- ApplyAlertArt), falls back to a shaped halo on tier 3, and skips tier 2,
-- which is square art with nothing to swap.
--
-- The CDM module previously called the deprecated function directly, which is
-- where the two deprecation warnings in the editor came from.

local addonName, ns = ...

local Glow = {}
ns.Glow = Glow

-- Tier 3 support: a texture we draw and animate ourselves.
local FALLBACK_TEXTURE = "Interface\\SpellActivationOverlay\\IconAlert"

-- `anchorTo` is the region the ring should surround. Passing one matters when
-- the frame is bigger than the thing being highlighted. The reminder buttons
-- (icon + label + header in one frame) used to pass their icon; since 1.78
-- they glow a frame of their own sized over the icon instead, which is what
-- lets them have the proc animation that anchorTo rules out.
--
-- Drawn at ARTWORK rather than OVERLAY on purpose. The icon is BACKGROUND and
-- the timer, stack count and label are OVERLAY on the same frame, so ARTWORK
-- puts the ring above the icon and beneath the text without moving anything.
local function EnsureFallback(frame, anchorTo)
    if frame.sqGlowFallback then return frame.sqGlowFallback end

    -- Texture and anchors are ApplyArt's job, not set here: they depend on the
    -- frame's shape, which can change between one glow and the next.
    local glow = frame:CreateTexture(nil, anchorTo and "ARTWORK" or "OVERLAY")
    glow:SetBlendMode("ADD")
    glow:Hide()

    local anim = glow:CreateAnimationGroup()
    anim:SetLooping("BOUNCE")
    local pulse = anim:CreateAnimation("Alpha")
    pulse:SetFromAlpha(0.35)
    pulse:SetToAlpha(1.0)
    pulse:SetDuration(0.6)

    frame.sqGlowFallback = glow
    frame.sqGlowFallbackAnim = anim
    frame.sqGlowPulseAnim = pulse
    return glow
end

-- The player's glow colour. Tints every glow of ours, and the shaped
-- flipbooks that replace Blizzard's art; Blizzard's own square glow keeps its
-- art's colour, as it always has.
--- `frame.sqGlowColor` overrides the shared setting for one frame, which is
--- what lets the nameplate purge glow carry its own colour without every other
--- glow in the addon following it.
local function GlowColor(frame)
    local own = frame and frame.sqGlowColor
    if own then return own.r or own[1] or 1, own.g or own[2] or 0.82, own.b or own[3] or 0 end
    local s = (ns.BH and ns.BH.settings) or {}
    local c = s.glowColor or {}
    return c.r or 1, c.g or 0.82, c.b or 0.0
end

-- Shaped art is drawn this much larger than the frame. The generator
-- (.claude/make-shapes.ps1, GlowScale) leaves the same margin around the shape,
-- which is what puts the glow's outline on the icon's edge -- change one and
-- the other has to follow. It is also the ratio Blizzard's own alert frame
-- uses, so shaped and square glows match in size.
local SHAPED_SCALE = 1.4

-- Tier 3 texture and placement, set every time a self-drawn glow starts.
-- Cheap, since that only happens on a transition.
local function ApplyArt(frame, anchorTo)
    local glow = frame.sqGlowFallback
    if not glow then return end
    local target = anchorTo or frame
    local art = frame.sqGlowShape
    glow:ClearAllPoints()
    if art and art.halo then
        glow:SetTexture(art.halo)
        glow:SetTexCoord(0, 1, 0, 1)
        local w, h = target:GetSize()
        glow:SetPoint("CENTER", target, "CENTER", 0, 0)
        glow:SetSize((w or 0) * SHAPED_SCALE, (h or 0) * SHAPED_SCALE)
    else
        glow:SetTexture(FALLBACK_TEXTURE)
        glow:SetTexCoord(0.00781250, 0.50781250, 0.27734375, 0.52734375)
        -- Padded outwards: the art has a lot of empty margin, so drawn at
        -- exactly the target size the visible ring sits inside it rather
        -- than around it.
        glow:SetPoint("TOPLEFT", target, "TOPLEFT", -6, 6)
        glow:SetPoint("BOTTOMRIGHT", target, "BOTTOMRIGHT", 6, -6)
    end
end

-- Colour, speed and whether it pulses at all, read from settings every time a
-- glow starts rather than captured when the texture is built. The textures
-- live on pooled button frames and outlive any number of settings changes, so
-- baking the style in at creation would leave older buttons on the old look
-- until a reload.
local function ApplyStyle(frame)
    local glow = frame.sqGlowFallback
    local anim = frame.sqGlowFallbackAnim
    if not glow then return end

    local s = (ns.BH and ns.BH.settings) or {}
    local r, g, b = GlowColor(frame)
    glow:SetVertexColor(r, g, b, 1)

    if not anim then return end
    if s.glowPulse == false then
        -- Held at full brightness rather than hidden: "do not pulse" means a
        -- steady ring, not no ring.
        anim:Stop()
        glow:SetAlpha(1)
        return
    end

    local pulse = frame.sqGlowPulseAnim
    if pulse then
        pulse:SetDuration(s.glowPulseSpeed or 0.6)
        pulse:SetFromAlpha(s.glowMinAlpha or 0.35)
    end
    anim:Play()
end

-- ============================================================================
-- Shaped flipbooks on Blizzard's alert (tier 1)
--
-- Blizzard's alert (ActionButtonSpellAlertTemplate) is a burst flipbook,
-- ProcStartFlipbook driven by the ProcStartAnim group, handing over to a
-- looping one, ProcLoopFlipbook in the ProcLoop group. Both are square atlases
-- with no mask and no shape option. So a shaped frame keeps the alert --
-- Blizzard still owns showing, hiding, timing and the burst-to-loop hand-over
-- -- and only the art is replaced: each texture gets a sheet of our own and
-- each flipbook animation is told that sheet's grid. This is Masque's approach
-- for its round and hexagon skins (Masque/Core/Regions/SpellAlert.lua).
--
-- Safe to write to: GetAlertFrame creates the alert once per button, stores it
-- on the button as SpellActivationAlert and never pools it. The frames we glow
-- are our own -- the CDM's glow frames and each reminder button's glowHost --
-- so art set here cannot reach a real action button.
-- And these are widget calls on regions, not Blizzard Lua running on our stack,
-- so nothing of Blizzard's is left tainted by them.
--
-- Applied after every ShowAlert rather than once, so nothing Blizzard does on a
-- show can leave a shaped frame on square art.
-- ============================================================================

-- The generator's sheet layout ($SheetFrame and friends in make-shapes.ps1).
-- Blizzard's own grid: 30 frames, 6 rows of 5. 84px frames on a 512 sheet.
local SHEET_FRAME  = 84
local SHEET_ROWS   = 6
local SHEET_COLS   = 5
local SHEET_FRAMES = 30

-- Blizzard's art, for putting a frame back when its shape is cleared. From
-- ActionButtonSpellAlertTemplate in Blizzard_ActionBar/Shared/
-- ActionButtonSpellAlerts.xml.
local BLIZZ_LOOP_ATLAS  = "UI-HUD-ActionBar-Proc-Loop-Flipbook"
local BLIZZ_START_ATLAS = "UI-HUD-ActionBar-Proc-Start-Flipbook"
local BLIZZ_START_SIZE  = 150

-- The FlipBook animation inside one of the alert's animation groups. The
-- groups also hold Alpha animations, so it is found by type, not by position.
---@return FlipBook?
local function FlipBookOf(group)
    if not group then return nil end
    for _, a in ipairs({ group:GetAnimations() }) do
        if a:GetObjectType() == "FlipBook" then return a end
    end
    return nil
end

-- A frame size of 0 means "work it out from the atlas", which is what
-- Blizzard's own sheets rely on and what putting them back restores.
---@param anim FlipBook?
local function SetGrid(anim, frameSize)
    if not anim then return end
    anim:SetFlipBookFrameWidth(frameSize)
    anim:SetFlipBookFrameHeight(frameSize)
    anim:SetFlipBookRows(SHEET_ROWS)
    anim:SetFlipBookColumns(SHEET_COLS)
    anim:SetFlipBookFrames(SHEET_FRAMES)
end

local function ApplyAlertArt(frame)
    local alert = frame.SpellActivationAlert
    if not alert then return end
    local loopTex  = alert.ProcLoopFlipbook
    local startTex = alert.ProcStartFlipbook
    if not (loopTex and startTex) then return end
    local loopAnim  = FlipBookOf(alert.ProcLoop)
    local startAnim = FlipBookOf(alert.ProcStartAnim)

    local art = frame.sqGlowShape
    if art and art.loop and art.start then
        -- Remember Blizzard's blend modes the first time, to put them back.
        if not alert._sqShaped then
            alert._sqLoopBlend  = alert._sqLoopBlend  or loopTex:GetBlendMode()
            alert._sqStartBlend = alert._sqStartBlend or startTex:GetBlendMode()
        end
        local r, g, b = GlowColor(frame)

        loopTex:SetTexture(art.loop)
        loopTex:SetBlendMode("ADD")
        loopTex:SetVertexColor(r, g, b)
        SetGrid(loopAnim, SHEET_FRAME)

        -- Blizzard's burst is a fixed 150px centred on the button, much larger
        -- than the alert; ours is drawn to the alert's own 1.4x like the loop,
        -- so the two line up on the icon's edge.
        startTex:SetTexture(art.start)
        startTex:SetBlendMode("ADD")
        startTex:SetVertexColor(r, g, b)
        startTex:ClearAllPoints()
        startTex:SetAllPoints(alert)
        SetGrid(startAnim, SHEET_FRAME)

        alert._sqShaped = true
    elseif alert._sqShaped then
        loopTex:SetAtlas(BLIZZ_LOOP_ATLAS)
        loopTex:SetBlendMode(alert._sqLoopBlend or "BLEND")
        loopTex:SetVertexColor(1, 1, 1)
        SetGrid(loopAnim, 0)

        startTex:SetAtlas(BLIZZ_START_ATLAS)
        startTex:SetBlendMode(alert._sqStartBlend or "BLEND")
        startTex:SetVertexColor(1, 1, 1)
        startTex:ClearAllPoints()
        startTex:SetPoint("CENTER")
        startTex:SetSize(BLIZZ_START_SIZE, BLIZZ_START_SIZE)
        SetGrid(startAnim, 0)

        alert._sqShaped = nil
    end
end

--- Start the glow. `anchorTo` restricts it to one region of the frame; without
--- it the whole frame is ringed, which is what the square CDM icons want.
---
--- Passing anchorTo also forces the self-drawn glow: Blizzard's alert frames
--- size themselves to the frame they are given and cannot be told to cover
--- part of it.
---
--- `skipBirth` suppresses the one-shot spawn animation and starts straight on
--- the loop, which is what Blizzard does when it is re-syncing a glow that was
--- already running rather than reacting to a fresh proc. Tier 1 only; the
--- self-drawn fallback has no birth animation to skip.
function Glow.Show(frame, anchorTo, skipBirth)
    if not frame or frame.sqGlowing then return end
    frame.sqGlowing = true

    -- `sqGlowSelfOnly` is for a frame that MAY NOT have Blizzard's alert at
    -- all. Inside an aura-container button's subtree the alert template cannot
    -- be created: the button carries secret aspects, so assigning the
    -- template's OnHide handler there is refused --
    -- "Cannot assign script handler for 'onhide' (blocked by secret aspects)",
    -- once per button, which is what the nameplate purge glow produced in 1.78
    -- testing. The self-drawn glow is textures plus an animation group, with no
    -- script handler anywhere, so it is legal in that subtree.
    if anchorTo or frame.sqGlowSelfOnly then
        local glow = EnsureFallback(frame, anchorTo)
        ApplyArt(frame, anchorTo)
        glow:Show()
        ApplyStyle(frame)
        frame.sqGlowTier = 3
        return
    end

    if ActionButtonSpellAlertManager and ActionButtonSpellAlertManager.ShowAlert then
        local ok = pcall(ActionButtonSpellAlertManager.ShowAlert, ActionButtonSpellAlertManager,
                         frame, skipBirth)
        if ok then
            ApplyAlertArt(frame)
            frame.sqGlowTier = 1
            return
        end
    end

    if ActionButton_ShowOverlayGlow and not frame.sqGlowShape then
        local ok = pcall(ActionButton_ShowOverlayGlow, frame)
        if ok then
            frame.sqGlowTier = 2
            return
        end
    end

    local glow = EnsureFallback(frame)
    ApplyArt(frame)
    glow:Show()
    ApplyStyle(frame)
    frame.sqGlowTier = 3
end

--- Stop it. Uses whichever tier actually started it, since a button can outlive
--- a UI reload where the available APIs changed.
function Glow.Hide(frame)
    if not frame or not frame.sqGlowing then return end
    frame.sqGlowing = nil

    local tier = frame.sqGlowTier
    frame.sqGlowTier = nil

    if tier == 1 and ActionButtonSpellAlertManager and ActionButtonSpellAlertManager.HideAlert then
        pcall(ActionButtonSpellAlertManager.HideAlert, ActionButtonSpellAlertManager, frame)
        return
    end
    if tier == 2 and ActionButton_HideOverlayGlow then
        pcall(ActionButton_HideOverlayGlow, frame)
        return
    end
    if frame.sqGlowFallback then
        frame.sqGlowFallbackAnim:Stop()
        frame.sqGlowFallback:Hide()
    end
end

--- Show or hide in one call, which is what most callers actually want.
function Glow.Set(frame, on, anchorTo, skipBirth)
    if on then Glow.Show(frame, anchorTo, skipBirth) else Glow.Hide(frame) end
end

--- Re-size the tier 1 alert art to match the frame.
---
--- ActionButtonSpellAlertManager builds its alert frame once, at 1.4x whatever
--- the button measured at that instant, and never revisits it -- Blizzard's
--- action buttons are a fixed size, so nothing there ever needed it to. Our CDM
--- icons resize from a slider, and without this the glow keeps the dimensions
--- the icon had the first time it ever glowed. The shaped flipbooks are
--- anchored to the alert, so they follow it.
---
--- The tier 3 shaped halo is sized when it starts, so it is re-sized here too.
function Glow.Resize(frame)
    if not frame then return end
    local w, h = frame:GetSize()
    if not (w and h and w > 0 and h > 0) then return end
    local alert = frame.SpellActivationAlert
    if alert then
        alert:SetSize(w * 1.4, h * 1.4)
    end
    if frame.sqGlowShape and frame.sqGlowFallback then
        frame.sqGlowFallback:SetSize(w * SHAPED_SCALE, h * SHAPED_SCALE)
    end
end

--- Give a frame shaped glow art, or nil for the normal glow. `art` is a table
--- of texture paths: `start` and `loop` (the tier 1 flipbook sheets) and `halo`
--- (the tier 3 fallback). The same table must be passed each time for the
--- same shape; it is compared by identity.
---
--- A glow already running is restarted so it changes over at once rather than
--- when it next ends -- a proc glow can last a whole fight. The restart passes
--- no anchorTo, so this is for whole-frame glows: the CDM icons, and the
--- glowHost frame each reminder button sizes over its icon.
function Glow.SetShape(frame, art)
    if not frame or frame.sqGlowShape == art then return end
    frame.sqGlowShape = art
    if frame.sqGlowing then
        Glow.Hide(frame)
        Glow.Show(frame, nil, true)
    end
end
