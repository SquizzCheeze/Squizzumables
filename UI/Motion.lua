-- UI/Motion.lua
-- 2.0 motion (phase 4, design doc "Motion"): short fades and pops so things
-- arrive and leave rather than blinking, built on the game's own animation
-- groups, which keep running in combat. Settings > Misc > Reduce motion
-- (reduceMotion) turns every one of them into an instant change.
--
--   Motion.Appear(frame, seconds, fromScale?)   fade in (and grow from fromScale)
--   Motion.FadeOut(frame, seconds, done)       fade out, then done() -- which hides
--   Motion.CancelFade(frame)                   stop a fade-out that is under way
--   Motion.WrapShowHide(frame, opts)           a frame whose Show/Hide do both
--
-- Alpha animations end where the frame's own alpha is, so an alert drawn at
-- 70% opacity fades in to 70%, not to 100%.

local addonName, ns = ...

local Motion = {}
ns.Motion = Motion

function Motion.Reduced()
    local BH = ns.BH
    local s = BH and BH.settings
    return s and s.reduceMotion and true or false
end

-- A frame's animation group for `kind`, made once.
local function Group(frame, kind)
    frame.sqMotion = frame.sqMotion or {}
    local g = frame.sqMotion[kind]
    if not g then
        g = frame:CreateAnimationGroup()
        frame.sqMotion[kind] = g
    end
    return g
end

--- Fade `frame` in over `seconds`, growing from `fromScale` (e.g. 0.9) to full
--- size when given. Call after the frame is shown.
function Motion.Appear(frame, seconds, fromScale)
    if Motion.Reduced() or not frame then return end
    local g = Group(frame, "appear")
    if not g.alpha then
        g.alpha = g:CreateAnimation("Alpha")
        g.scale = g:CreateAnimation("Scale")
        g.scale:SetOrigin("CENTER", 0, 0)
    end
    g:Stop()
    g.alpha:SetFromAlpha(0)
    g.alpha:SetToAlpha(frame:GetAlpha())
    g.alpha:SetDuration(seconds)
    local s = fromScale or 1
    g.scale:SetScaleFrom(s, s)
    g.scale:SetScaleTo(1, 1)
    g.scale:SetDuration(seconds)
    g:Play()
end

--- Fade `frame` out over `seconds`, then call `done` (which normally hides
--- it). Instant with Reduce motion on, or when the frame is not showing.
function Motion.FadeOut(frame, seconds, done)
    if Motion.Reduced() or not (frame and frame:IsShown()) then
        if done then done() end
        return
    end
    local g = Group(frame, "fade")
    if not g.alpha then
        g.alpha = g:CreateAnimation("Alpha")
        -- Not SetToFinalAlpha: that would leave the frame at 0 for its next
        -- showing. `done` hides it inside OnFinished, before the frame's own
        -- alpha can draw again.
        g:SetScript("OnFinished", function(self)
            local cb = self.done
            self.done = nil
            if cb then cb() end
        end)
    end
    local appear = frame.sqMotion.appear
    if appear then appear:Stop() end
    g:Stop()
    g.alpha:SetFromAlpha(frame:GetAlpha())
    g.alpha:SetToAlpha(0)
    g.alpha:SetDuration(seconds)
    g.done = done
    g:Play()
end

function Motion.Fading(frame)
    local g = frame and frame.sqMotion and frame.sqMotion.fade
    return g and g:IsPlaying() and true or false
end

function Motion.CancelFade(frame)
    local g = frame and frame.sqMotion and frame.sqMotion.fade
    if g then
        g.done = nil
        g:Stop()
    end
end

--- Give `frame` an animated Show/Hide/SetShown: `opts.appear` seconds in
--- (growing from `opts.fromScale`), `opts.fade` seconds out. For our own plain
--- frames only -- never a secure one. Callers keep calling Show/Hide as
--- before; a Hide while already fading out is ignored, so an updater calling
--- it on every pass does not restart the fade, and a Show cancels a fade-out.
function Motion.WrapShowHide(frame, opts)
    local show, hide = frame.Show, frame.Hide
    frame.Show = function(self)
        local wasShown = self:IsShown() and not Motion.Fading(self)
        Motion.CancelFade(self)
        show(self)
        if not wasShown then Motion.Appear(self, opts.appear, opts.fromScale) end
    end
    frame.Hide = function(self)
        if not self:IsShown() or Motion.Fading(self) then return end
        Motion.FadeOut(self, opts.fade, function() hide(self) end)
    end
    frame.SetShown = function(self, on)
        if on then self:Show() else self:Hide() end
    end
    -- The real ones, for code that must hide this instant.
    frame.sqHideNow = function(self)
        Motion.CancelFade(self)
        hide(self)
    end
end
