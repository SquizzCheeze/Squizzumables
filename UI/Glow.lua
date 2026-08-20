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
-- The CDM module previously called the deprecated function directly, which is
-- where the two deprecation warnings in the editor came from.

local addonName, ns = ...

local Glow = {}
ns.Glow = Glow

-- Tier 3 support: a texture we draw and animate ourselves.
local FALLBACK_TEXTURE = "Interface\\SpellActivationOverlay\\IconAlert"

-- `anchorTo` is the region the ring should surround. Passing one matters when
-- the frame is bigger than the thing being highlighted: the reminder buttons
-- are icon + label + header in one frame, so a glow drawn to the frame boxes
-- the text instead of ringing the icon.
--
-- Drawn at ARTWORK rather than OVERLAY on purpose. The icon is BACKGROUND and
-- the timer, stack count and label are OVERLAY on the same frame, so ARTWORK
-- puts the ring above the icon and beneath the text without moving anything.
local function EnsureFallback(frame, anchorTo)
    if frame.sqGlowFallback then return frame.sqGlowFallback end

    local glow = frame:CreateTexture(nil, anchorTo and "ARTWORK" or "OVERLAY")
    glow:SetTexture(FALLBACK_TEXTURE)
    glow:SetTexCoord(0.00781250, 0.50781250, 0.27734375, 0.52734375)
    glow:SetBlendMode("ADD")
    -- Padded outwards: the art has a lot of empty margin, so drawn at exactly
    -- the target size the visible ring sits inside it rather than around it.
    local target = anchorTo or frame
    glow:SetPoint("TOPLEFT", target, "TOPLEFT", -6, 6)
    glow:SetPoint("BOTTOMRIGHT", target, "BOTTOMRIGHT", 6, -6)
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
    local c = s.glowColor or {}
    glow:SetVertexColor(c.r or 1, c.g or 0.82, c.b or 0.0, 1)

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

--- Start the glow. `anchorTo` restricts it to one region of the frame; without
--- it the whole frame is ringed, which is what the square CDM icons want.
---
--- Passing anchorTo also forces the self-drawn glow: Blizzard's alert frames
--- size themselves to the frame they are given and cannot be told to cover
--- part of it.
function Glow.Show(frame, anchorTo)
    if not frame or frame.sqGlowing then return end
    frame.sqGlowing = true

    if anchorTo then
        local glow = EnsureFallback(frame, anchorTo)
        glow:Show()
        ApplyStyle(frame)
        frame.sqGlowTier = 3
        return
    end

    if ActionButtonSpellAlertManager and ActionButtonSpellAlertManager.ShowAlert then
        local ok = pcall(ActionButtonSpellAlertManager.ShowAlert, ActionButtonSpellAlertManager, frame)
        if ok then
            frame.sqGlowTier = 1
            return
        end
    end

    if ActionButton_ShowOverlayGlow then
        local ok = pcall(ActionButton_ShowOverlayGlow, frame)
        if ok then
            frame.sqGlowTier = 2
            return
        end
    end

    local glow = EnsureFallback(frame)
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
function Glow.Set(frame, on, anchorTo)
    if on then Glow.Show(frame, anchorTo) else Glow.Hide(frame) end
end
