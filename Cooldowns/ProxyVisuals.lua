-- Cooldowns/ProxyVisuals.lua
-- How a cooldown icon looks and behaves from one moment to the next:
-- ApplyProxyVisuals (per-group style, keybind, proc glow, usable tint, the
-- cooldown/aura pass and Show While Active), FireCDSounds (alerts for
-- cooldowns outside any named group) and the /sq cdm sound diagnostics.
--
-- Moved out of Squizzumables_CDM.lua unchanged in 2.0 phase 2 (the split).
-- That file still calls both functions from UpdateAllProxyCooldowns, so it
-- keeps a two-line forwarder for each and this file fills in the table they
-- forward to (cdmModule.proxyVisuals, bottom of this file). Nothing calls
-- them while loading. The module's names used here come through
-- cdmModule.shared and are re-declared below under the same names, so the
-- moved code is byte-identical.

local addonName, ns = ...
local BH = ns.BH

local cdmModule = BH.cdm
local shared    = cdmModule.shared

local GetSpecData              = shared.GetSpecData
local GetSpecKey               = shared.GetSpecKey
local GetCDMSoundAlerts        = shared.GetCDMSoundAlerts
local DEFAULT_ALPHA            = shared.DEFAULT_ALPHA
local DEFAULT_BORDER_THICKNESS = shared.DEFAULT_BORDER_THICKNESS
local DEFAULT_BORDER_COLOR     = shared.DEFAULT_BORDER_COLOR
local DEFAULT_ICON_ZOOM        = shared.DEFAULT_ICON_ZOOM
local DEFAULT_BG_COLOR         = shared.DEFAULT_BG_COLOR
local BORROW_VIEWERS           = shared.BORROW_VIEWERS
local BUFF_VIEWERS             = shared.BUFF_VIEWERS
local DISCOVER_CATEGORIES      = shared.DISCOVER_CATEGORIES
local BlizzardFilteredIDs      = shared.BlizzardFilteredIDs
local SHAPE_FILE               = shared.SHAPE_FILE
local ApplyIconShape           = shared.ApplyIconShape
local PlaceText                = shared.PlaceText
local CooldownCountdownText    = shared.CooldownCountdownText
local ApplyKeybindText         = shared.ApplyKeybindText
local ResolveProxyTexture      = shared.ResolveProxyTexture
local ActiveGlowColor          = shared.ActiveGlowColor
local ProcGlowColor            = shared.ProcGlowColor
local SetProcGlow              = shared.SetProcGlow
local SyncProcGlow             = shared.SyncProcGlow
local ResizeSpellAlert         = shared.ResizeSpellAlert
local ApplyUsableTint          = shared.ApplyUsableTint
local EquipSlotCooldown        = shared.EquipSlotCooldown
local LiveSpellID              = shared.LiveSpellID
local SpellIDForCooldown       = shared.SpellIDForCooldown
local CooldownActiveFromViewer = shared.CooldownActiveFromViewer
local CooldownAuraActive       = shared.CooldownAuraActive
local CollectAlertsFor         = shared.CollectAlertsFor
local PlayAlertsFor            = shared.PlayAlertsFor

-- Apply per-group visual settings to a proxy frame.
--
-- `preview` (the options preview, UI/CDMPreview.lua) applies the STYLE only
-- and skips everything that reads live state: the real proc, the usable
-- tint, and the cooldown/aura pass -- which also fires the CDM sound alerts,
-- so a preview icon must never reach it. The preview mocks that state itself.
local function ApplyProxyVisuals(proxy, groupData, preview)
    if not proxy or not groupData then return end

    -- Fill in an icon that was not available when the proxy was built.
    --
    -- CreateProxyIcon reads the spell texture exactly once. If it came back nil
    -- or secret at that moment the icon stayed blank forever, and since the
    -- frame still takes up its slot the result is a correctly sized, correctly
    -- positioned group full of invisible icons -- which looks like a stray
    -- empty box floating next to the groups that did render. The buff
    -- categories are the ones that hit this, being discovered earlier in login
    -- than their spell data settles.
    if not proxy._iconSet and proxy.Icon and (proxy.spellID or proxy.equipSlot) then
        local tex = ResolveProxyTexture(proxy.spellID, proxy.equipSlot)
        if tex then
            proxy.Icon:SetTexture(tex)
            proxy._iconSet = true
        end
    end

    -- Blizzard parity: proc glow and the usable/range tint, both per group.
    --
    -- Cached on the proxy as well as applied, because the glow events arrive
    -- outside any layout pass and the handler has no group in hand -- resolving
    -- one there would mean repeating the assignment fallback for every icon on
    -- every proc.
    -- Cooldown-type entries only. Both of these live on
    -- CooldownViewerCooldownItemMixin, which is Essential and Utility;
    -- Blizzard's buff items inherit neither, so applying them to a tracked buff
    -- would not be parity but invention -- and a buff has no meaningful "can
    -- you cast this right now" to colour by in the first place.
    local isCooldownType = (proxy.viewerType ~= "buff")

    -- The proc glow's colour, through the same per-frame door the active glow
    -- uses below. A glow is tinted when it STARTS and a proc glow can last a
    -- whole fight, so a colour change has to restart it or it would not show
    -- until the next proc.
    --
    -- BEFORE SyncProcGlow, deliberately: that call re-lights a glow that should
    -- still be running, so the icon is dark for no frame at all. After it, the
    -- icon would stay dark until the next proc -- the very thing the restart is
    -- here to avoid.
    if proxy.ProcGlow then
        local c = ProcGlowColor(groupData)
        local prev = proxy.ProcGlow.sqGlowColor
        local changed = not prev or prev[1] ~= c[1] or prev[2] ~= c[2] or prev[3] ~= c[3]
        proxy.ProcGlow.sqGlowColor = c
        if changed then SetProcGlow(proxy, false) end
    end

    local procGlowOn = isCooldownType and (groupData.procGlow ~= false)
    proxy._procGlowAllowed = procGlowOn
    ResizeSpellAlert(proxy)
    if not preview then
        SyncProcGlow(proxy, procGlowOn)
    end

    proxy._usableTintAllowed = isCooldownType and (groupData.usableTint ~= false)
    if not preview then
        ApplyUsableTint(proxy, proxy._usableTintAllowed)
    end

    -- Cached here for the same reason as the two above: the duration pass runs
    -- per icon with no group in hand. Cooldown-type only -- a tracked buff
    -- already draws its aura's duration, so there is nothing for this to add.
    proxy._sqShowActiveBuff = isCooldownType and groupData.showActiveBuff or nil
    if not proxy._sqShowActiveBuff and proxy.ActiveGlow then
        ns.Glow.Set(proxy.ActiveGlow, false)
        proxy._sqActiveNow = nil
    end

    -- Its own colour, so it does not read as the proc glow. sqGlowColor is the
    -- per-frame override Glow.lua already honours (the nameplate purge glow
    -- uses the same door), so nothing else in the addon follows this.
    if proxy.ActiveGlow then
        local c = ActiveGlowColor(groupData)
        local prev = proxy.ActiveGlow.sqGlowColor
        local changed = not prev or prev[1] ~= c[1] or prev[2] ~= c[2] or prev[3] ~= c[3]
        proxy.ActiveGlow.sqGlowColor = c
        -- A glow is tinted when it STARTS, and this one is held for a whole
        -- buff, so without a restart a colour change would not show up until
        -- the next time the ability was used. The state sync further down
        -- brings it straight back on the same pass when it should be lit.
        if changed then ns.Glow.Set(proxy.ActiveGlow, false) end
    end

    -- Low Health Glow (Cooldowns/HealthGlow.lua): its own frame, its alpha
    -- set by the game from your health, so it works in combat.
    if cdmModule.healthGlow then
        cdmModule.healthGlow.Apply(proxy, groupData, preview)
    end

    -- Alpha
    local alpha = groupData.alpha or DEFAULT_ALPHA
    proxy:SetAlpha(alpha)

    -- Border visibility. A shaped icon draws its border as ShapeBorder (see
    -- ApplyIconShape), so the square one gives way to it; ShapeBorder itself
    -- is shown after the style block below, which is what creates it.
    local showBorder = groupData.showBorder ~= false
    local shape      = groupData.iconShape or "none"
    local shaped     = SHAPE_FILE[shape] ~= nil
    if proxy.Border then proxy.Border:SetShown(showBorder and not shaped) end

    ApplyKeybindText(proxy, proxy.spellID, groupData)

    -- Charge count: visibility, size, colour and placement. The colour is ours
    -- to set even while the number itself is secret (it only adds the Text
    -- aspect, not a colour one).
    if proxy.Count then
        proxy.Count:SetShown(groupData.showCount ~= false)
        proxy.Count:SetFont("Fonts\\FRIZQT__.TTF", groupData.countSize or 12, "OUTLINE")
        local cc = groupData.countColor or { 1, 1, 1, 1 }
        proxy.Count:SetTextColor(cc[1], cc[2], cc[3], cc[4] or 1)
        PlaceText(proxy.Count, proxy, groupData.countPosition or "BOTTOMRIGHT",
            groupData.countOffsetX or -1, groupData.countOffsetY or 1)
    end

    -- Cooldown countdown, when the widget exposes its font string: size and
    -- colour (V1.94, user request), then placement. Size 0 / no colour leave
    -- the game's own -- a size that scales with the icon, and white -- so a
    -- group nobody has touched looks exactly as before.
    if proxy.Cooldown then
        local cdText = CooldownCountdownText(proxy.Cooldown)
        if cdText then
            -- The game's own font and colour, captured before we first change
            -- them, so going back to 0 / clearing the colour restores them
            -- instead of leaving the last custom value stuck.
            if not cdText._sqDefaultFont then
                local font, fsize, flags = cdText:GetFont()
                cdText._sqDefaultFont = { font or "Fonts\\FRIZQT__.TTF", fsize or 14, flags or "OUTLINE" }
                cdText._sqDefaultColor = { cdText:GetTextColor() }
            end
            -- Touched only while a custom value is set, and restored ONCE when it
            -- is cleared: re-applying the captured default every pass would
            -- freeze whatever size the game had picked for the icon then.
            local d = cdText._sqDefaultFont
            local size = groupData.cooldownTextSize or 0
            if size > 0 then
                cdText:SetFont(d[1], size, d[3])
                cdText._sqSized = true
            elseif cdText._sqSized then
                cdText:SetFont(d[1], d[2], d[3])
                cdText._sqSized = nil
            end
            local tc = groupData.cooldownTextColor
            if tc then
                cdText:SetTextColor(tc[1], tc[2], tc[3], tc[4] or 1)
                cdText._sqColored = true
            elseif cdText._sqColored then
                local dc = cdText._sqDefaultColor
                cdText:SetTextColor(dc[1] or 1, dc[2] or 1, dc[3] or 1, dc[4] or 1)
                cdText._sqColored = nil
            end
        end
    end
    if proxy.Cooldown and groupData.cooldownTextPosition
       and groupData.cooldownTextPosition ~= "CENTER" then
        PlaceText(CooldownCountdownText(proxy.Cooldown), proxy,
            groupData.cooldownTextPosition,
            groupData.cooldownTextOffsetX or 0, groupData.cooldownTextOffsetY or 0)
    end

    -- Border thickness/colour, icon zoom and background.
    --
    -- ApplyProxyVisuals runs on every update pass, and SetBackdrop and
    -- SetTexCoord are far too heavy for that -- SetBackdrop rebuilds the
    -- backdrop's textures. So the style values are folded into a signature and
    -- the work only happens when one of them actually changed, which is when
    -- the player moves a slider. Any new style field must join the signature or
    -- editing it will appear to do nothing until a reload.
    local thickness = groupData.borderThickness or DEFAULT_BORDER_THICKNESS
    local zoom      = groupData.iconZoom or DEFAULT_ICON_ZOOM
    local bc        = groupData.borderColor or DEFAULT_BORDER_COLOR
    local bg        = groupData.bgColor or DEFAULT_BG_COLOR
    local bgOn      = groupData.bgEnabled and true or false
    local classCol  = groupData.borderClassColor and true or false
    -- Border Inside Icon (V1.95): drawn over the icon's own edge instead of
    -- grown outward, so the icons' visible width IS the group frame's width --
    -- which is what another addon matching that width (SquizzFrames'
    -- attach/match) measures. Outside, the outer border adds 2x thickness the
    -- frame does not report (user report 2026-10-04).
    local inside    = groupData.borderInside and true or false
    local grow      = inside and 0 or thickness

    -- Appended after format, not built into the format string: a value
    -- containing a % would otherwise be read as a directive.
    -- `or` on every channel: a colour saved without its alpha (the colour
    -- picker's old Cancel path did that) must not break the format -- it did,
    -- on every refresh (user report 2026-10-04).
    local sig = ("%d|%.3f|%.2f,%.2f,%.2f,%.2f|%s|%.2f,%.2f,%.2f,%.2f|%s"):format(
        thickness, zoom, bc[1] or 0, bc[2] or 0, bc[3] or 0, bc[4] or 1,
        tostring(classCol), bg[1] or 0, bg[2] or 0, bg[3] or 0, bg[4] or 1, tostring(bgOn))
        .. "|" .. shape .. "|" .. tostring(inside) .. "|" .. tostring(showBorder)

    if proxy._styleSig ~= sig then
        proxy._styleSig = sig

        -- Shape before the SetTexCoord below, and both inside this block.
        --
        -- Removing a mask registers but does not repaint on its own: the icon
        -- kept rendering round until something else touched the texture. That
        -- is why switching back to square appeared to change only one icon
        -- until an unrelated slider (border opacity) was nudged -- that changed
        -- the signature, which re-ran SetTexCoord, which forced the repaint.
        -- Running the mask change here means the SetTexCoord immediately after
        -- is the repaint.
        ApplyIconShape(proxy, shape)

        -- A shaped border is the shape drawn BEHIND the icon. Inside, it stays
        -- the icon's size and the MASK shrinks by the thickness instead, so the
        -- rim shows round the art without moving the icon itself -- several
        -- layout passes re-anchor proxy.Icon to the full frame, the mask they
        -- leave alone (it hangs off the icon). Outside, back to the full icon.
        local mask = proxy._sqMask
        if mask and proxy.Icon then
            mask:ClearAllPoints()
            local inset = (inside and shaped and showBorder) and thickness or 0
            mask:SetPoint("TOPLEFT", proxy.Icon, "TOPLEFT", inset, -inset)
            mask:SetPoint("BOTTOMRIGHT", proxy.Icon, "BOTTOMRIGHT", -inset, inset)
        end

        if proxy.Icon then
            proxy.Icon:SetTexCoord(zoom, 1 - zoom, zoom, 1 - zoom)
        end

        local r, g, b, a = bc[1], bc[2], bc[3], bc[4]
        if classCol then
            local _, class = UnitClass("player")
            local cc = class and C_ClassColor and C_ClassColor.GetClassColor
                and C_ClassColor.GetClassColor(class)
            if cc then r, g, b = cc.r, cc.g, cc.b end
        end

        if proxy.Border then
            proxy.Border:ClearAllPoints()
            proxy.Border:SetPoint("TOPLEFT", -grow, grow)
            proxy.Border:SetPoint("BOTTOMRIGHT", grow, -grow)
            proxy.Border:SetBackdrop({
                edgeFile = "Interface\\BUTTONS\\WHITE8X8",
                edgeSize = thickness,
            })
            proxy.Border:SetBackdropBorderColor(r, g, b, a)
        end

        -- The shaped border: the shape itself, grown by the thickness on
        -- every side and tinted, sitting behind the icon.
        if proxy.ShapeBorder then
            proxy.ShapeBorder:ClearAllPoints()
            proxy.ShapeBorder:SetPoint("TOPLEFT", -grow, grow)
            proxy.ShapeBorder:SetPoint("BOTTOMRIGHT", grow, -grow)
            proxy.ShapeBorder:SetVertexColor(r, g, b, a)
        end

        if proxy.Bg then
            proxy.Bg:SetColorTexture(bg[1], bg[2], bg[3], bg[4])
            proxy.Bg:SetShown(bgOn)
        end
    end

    if proxy.ShapeBorder then proxy.ShapeBorder:SetShown(showBorder and shaped) end

    -- Cooldown text visibility
    if proxy.Cooldown then
        proxy.Cooldown:SetHideCountdownNumbers(not (groupData.showCooldownText ~= false))
    end

    -- Desaturation: greyscale icon when spell is NOT on cooldown
    -- An equip-slot entry (a trinket) reads the item cooldown instead of the
    -- spell, and may have no spellID at all -- see EquipSlotCooldown.
    -- Potions and Healthstones (spellCategory) read their item cooldown the same way.
    local itemEntry = proxy.equipSlot or proxy.spellCategory
    if not preview and proxy.Icon and (proxy.spellID or itemEntry) then
        local onCD = false
        if itemEntry then
            local _, _, itemOnCD = EquipSlotCooldown(proxy)
            onCD = itemOnCD and true or false
        end
        -- LiveSpellID: this is the read that decides "grey it out", and on a
        -- talent-overridden spell the base ID reports permanently ready.
        local cdInfo = not itemEntry and C_Spell.GetSpellCooldown
            and C_Spell.GetSpellCooldown(LiveSpellID(proxy.spellID))
        if cdInfo then
            local start = cdInfo.startTime
            local dur = cdInfo.duration
            if start and dur then
                -- Ask the readable booleans, do not infer from the timestamps.
                --
                -- SpellCooldownInfo carries isActive and isOnGCD, and they stay
                -- readable when startTime/duration have gone secret. That is
                -- strictly better than deriving state from the numbers: it
                -- needs no secret arithmetic, and isOnGCD separates a real
                -- cooldown from the global, which no amount of inference from a
                -- secret duration can do -- every GCD used to read as "on
                -- cooldown".
                --
                -- isActive is not in the generated API docs, but it is present
                -- and is what EllesmereUI reads in four separate places, which
                -- is the evidence it works on a live 12.1 client. The old
                -- derivation is kept as a fallback for a client without it.
                if not BH.Secrets.IsSecret(cdInfo.isActive) and cdInfo.isActive ~= nil then
                    onCD = cdInfo.isActive and not cdInfo.isOnGCD
                elseif BH.Secrets.IsSecret(start) or BH.Secrets.IsSecret(dur) then
                    -- Secret means on cooldown, not "unreadable, give up": these
                    -- fields are only secret while there is something to derive
                    -- them from, so a ready spell reads plainly. Same fact the
                    -- CDM available alert depends on.
                    onCD = true
                elseif dur > 1.5 then
                    onCD = true
                end
            end
        end

        local hasAura, auraReadable = CooldownAuraActive(proxy.cooldownID, proxy.spellID)

        -- What "active" means depends on which kind of entry this is.
        --
        -- A tracked buff is interesting while its AURA is up; whether the spell
        -- that applies it happens to be on cooldown says nothing about whether
        -- to show it. Folding onCD in made every tracked buff active the moment
        -- combat started, because a secret cooldown now correctly reads as "on
        -- cooldown" -- so Hide Until Active showed the entire buff list instead
        -- of the two or three actually running.
        --
        -- CooldownAuraActive reads the Blizzard buff item's IsActive(), which
        -- is real aura state and keeps working in combat, so this stays correct
        -- there rather than falling back to a guess.
        local isActive
        if proxy.viewerType == "buff" then
            isActive = hasAura
        else
            isActive = onCD or hasAura
        end

        -- Two opposite options, and only one can win.
        --
        -- "On cooldown" is Blizzard's own behaviour and what most people mean by
        -- greying an icon out; "when ready" is the inverse, for a group used as
        -- a "these are up" display. They contradict each other, so the settings
        -- UI unticks one when the other is ticked -- but a profile written
        -- before that, or edited by hand, can still hold both. On cooldown wins
        -- there, because it is the one that matches the rest of the UI.
        --
        -- onCD rather than isActive: isActive folds in whether the buff is up,
        -- which for a tracked buff means the icon would grey out exactly when
        -- the buff was active. The question here is only "is the spell on
        -- cooldown".
        --
        -- Running beats on-cooldown. A big cooldown starts its own timer the
        -- moment it is cast, so without this exception the icon greys out at
        -- exactly the moment the ability is doing its work -- which is the
        -- opposite of what the setting is for.
        -- NOT folded in with hasAura, which was the second half of "it doesn't
        -- work in combat": CooldownAuraActive answers from the BUFF viewers,
        -- so for an Essential entry with no tracked-buff twin it reads false
        -- all fight and took the glow and the colour down with it.
        -- _sqActiveNow comes from Blizzard's own never-secret display flag.
        local runningNow = proxy._sqShowActiveBuff and proxy._sqActiveNow and true or false
        if groupData.desaturateOnCooldown then
            proxy.Icon:SetDesaturated(onCD and not runningNow and true or false)
        elseif groupData.desaturateReady then
            proxy.Icon:SetDesaturated(not isActive)
        else
            proxy.Icon:SetDesaturated(false)
        end

        -- Hide until active: only show when on cooldown or buff is active.
        -- Everything shows in unlock mode, so the group is positioned at its
        -- full extent rather than at whatever happens to be on cooldown.
        if groupData.hideUntilActive then
            proxy:SetShown(isActive or cdmModule.previewMode)
        end

        -- Detect state transitions this frame
        local justBecameReady  = not isActive and proxy._wasOnCD
        local justBecameActive = hasAura and not proxy._wasHasAura
        local justStartedCD    = isActive and not proxy._wasOnCD

        -- Held for as long as the ability is running, so this is a state sync
        -- rather than a transition -- Glow.Set is idempotent, and Show
        -- early-returns on an already-glowing frame, so this costs nothing on
        -- the passes where nothing changed.
        --
        -- The third argument is the anchor, and passing it is what forces the
        -- self-drawn halo instead of Blizzard's proc art (ns.Glow.Show). That
        -- is the whole point of a separate glow: "running" must not look like
        -- "procced".
        if proxy.ActiveGlow then
            ns.Glow.Set(proxy.ActiveGlow, runningNow and true or false,
                        proxy.ActiveGlow, true)
        end

        -- Glow when CD finishes (group setting).
        --
        -- Through ns.Glow rather than ActionButton_ShowOverlayGlow directly:
        -- that function is deprecated, and this routes to the modern
        -- ActionButtonSpellAlertManager where the client has it.
        if justBecameReady and groupData.glowOnReady then
            local target = proxy.GlowFrame or proxy
            ns.Glow.Show(target)
            proxy._glowShowing = true
            C_Timer.After(2, function()
                if proxy._glowShowing then
                    ns.Glow.Hide(target)
                    proxy._glowShowing = false
                end
            end)
        end

        -- Per-cooldown sound alerts (CDM Sounds tab settings)
        -- Absence-driven, so it needs the readability guard; the presence-driven
        -- transitions above are safe either way. Same rule as the tracker path.
        local justAuraRemoved = auraReadable and not hasAura and proxy._wasHasAura
        -- Not skipped when the Blizzard alert hook also covers this cooldown:
        -- both paths run and ClaimAlert drops whichever is second, so a
        -- cooldown the hook failed to attach to is still caught here.
        -- Through PlayAlertsFor (sound and image together), once per event.
        if (justBecameReady or justBecameActive or justStartedCD or justAuraRemoved)
           and proxy.cooldownID and not BH.suppressBuffSounds then
            local id = proxy.cooldownID
            if justBecameReady  then PlayAlertsFor(id, "available") end
            if justStartedCD    then PlayAlertsFor(id, "start") end
            if justBecameActive then
                PlayAlertsFor(id, "active")
                PlayAlertsFor(id, "applied")
            end
            if justAuraRemoved  then PlayAlertsFor(id, "removed") end
        end

        proxy._wasOnCD    = isActive
        -- Never record an unreadable aura pass over the real state.
        if auraReadable then proxy._wasHasAura = hasAura end
    end

    -- Tooltip setup
    if groupData.showTooltip ~= false then
        if not proxy._tooltipSetup then
            proxy._tooltipSetup = true
            proxy:EnableMouse(true)
            proxy:SetScript("OnEnter", function(self)
                if self.spellID then
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    GameTooltip:SetSpellByID(self.spellID)
                    GameTooltip:Show()
                end
            end)
            proxy:SetScript("OnLeave", function()
                GameTooltip:Hide()
            end)
        end
    end
end

-- Fire sound alerts for CDM spells that are NOT in a named group.
-- Spells IN a named group are already handled by ApplyProxyVisuals.
-- This covers free icons and spells configured in CDM Sounds but not placed in CDM.
local function FireCDSounds()
    local soundAlerts = GetCDMSoundAlerts()
    if not next(soundAlerts) then return end
    local specData = GetSpecData()
    for alertKey, alerts in pairs(soundAlerts) do
        repeat
            if not alerts or #alerts == 0 then break end

            -- Alerts are stored keyed by spellID (see MigrateSoundAlerts), so
            -- the key is not a cooldownID and must not be handed to
            -- GetCooldownViewerCooldownInfo. Doing that returned nil and broke
            -- out of the loop for every alert, which is what "tracked: no
            -- (never evaluated)" meant.
            --
            -- A legacy store that has not migrated yet still holds cooldownID
            -- keys, so both readings are tried.
            local spellID, cdID
            local asSpell = SpellIDForCooldown(alertKey)
            if asSpell then
                cdID, spellID = alertKey, asSpell        -- legacy cooldownID key
            else
                spellID = alertKey
                cdID    = cdmModule.cooldownForSpell[alertKey]
            end
            if not spellID then break end

            -- Deliberately NOT skipped when the Blizzard alert hook also covers
            -- this cooldown. Both paths run and ClaimAlert drops whichever is
            -- second, so a cooldown the hook silently failed to attach to is
            -- still caught here instead of going quiet.
            -- Skip if in a named group — ApplyProxyVisuals handles it there
            local assignment = cdID and specData and specData.assignments[cdID]
            if assignment and assignment ~= "FREE" then break end

            if not cdmModule.soundTrackers[alertKey] then
                cdmModule.soundTrackers[alertKey] = { spellID = spellID }
            end
            local tracker = cdmModule.soundTrackers[alertKey]
            -- Current cooldown state
            local onCD = false
            -- Blizzard's viewer item first. It holds the answer already worked
            -- out from values we are not allowed to compare, and it is the only
            -- source that survives combat -- /sq cdm reports
            -- "GetSpellCooldown secret? startTime: true, duration: true" there,
            -- which is why the "available" alert could never fire in combat
            -- from the API path no matter what drove the poll.
            local cdReadable
            onCD, cdReadable = CooldownActiveFromViewer(cdID, spellID)

            if not cdReadable then
                -- No viewer item (spell not in Blizzard's Cooldown Manager), or
                -- it gave us a secret. Fall back to the API, which works fine
                -- out of combat.
                cdReadable = true
                local cdInfo = C_Spell.GetSpellCooldown and C_Spell.GetSpellCooldown(LiveSpellID(tracker.spellID))
                if cdInfo then
                    local start, dur = cdInfo.startTime, cdInfo.duration
                    if start and dur then
                        if BH.Secrets.HasAnySecret(start, dur) then
                            cdReadable = false
                        elseif dur > 1.5 then
                            onCD = true
                        end
                    end
                end
            end
            local hasAura, auraReadable = CooldownAuraActive(cdID, tracker.spellID)
            local isActive = onCD or hasAura

            -- Each transition is gated on the readability of the thing it
            -- actually depends on, rather than one blanket bail-out.
            --
            -- This used to `break` whenever the cooldown was unreadable, which
            -- silenced every alert for that cooldown -- including the aura ones,
            -- which do not depend on the cooldown at all. In combat the
            -- cooldown is routinely unreadable, so in practice no CDM sound
            -- fired in combat at all.
            --
            -- The rule (see CLAUDE.md): alerts that fire on *presence* are safe
            -- when data is unreadable, because they simply stay quiet. Alerts
            -- that fire on *absence* are not, because unreadable looks exactly
            -- like gone.
            -- Aura readability only matters for a cooldown that actually has an
            -- aura dimension. Most utility cooldowns do not: they are a plain
            -- timer with no associated buff, so `isActive` is just `onCD` and
            -- whether auras happen to be secret is irrelevant to them.
            --
            -- Requiring auraReadable unconditionally is what broke "available"
            -- in combat. AurasAreSecret() is true in combat, and a non-buff
            -- cooldown is absent from knownBuffCooldowns, so CooldownAuraActive
            -- correctly reported "cannot tell" -- and that answer, about an aura
            -- the cooldown does not even have, vetoed the transition. The alert
            -- then sat pending until combat ended and auras became readable
            -- again, which is precisely the reported behaviour.
            local auraRelevant = cdmModule.knownBuffCooldowns[cdID]
                              or hasAura or tracker._wasHasAura
            local auraUsable   = auraReadable or not auraRelevant

            local justBecameActive = hasAura and not tracker._wasHasAura            -- presence
            local justStartedCD    = cdReadable and isActive and not tracker._wasOnCD  -- presence
            local justBecameReady  = cdReadable and auraUsable                      -- absence
                                     and not isActive and tracker._wasOnCD
            local justAuraRemoved  = auraReadable                                   -- absence
                                     and not hasAura and tracker._wasHasAura
            -- Through PlayAlertsFor (sound and image together), once per event.
            if (justBecameReady or justBecameActive or justStartedCD or justAuraRemoved)
               and not BH.suppressBuffSounds then
                if justBecameReady  then PlayAlertsFor(cdID, "available") end
                if justStartedCD    then PlayAlertsFor(cdID, "start") end
                if justBecameActive then
                    PlayAlertsFor(cdID, "active")
                    PlayAlertsFor(cdID, "applied")
                end
                if justAuraRemoved  then PlayAlertsFor(cdID, "removed") end
            end
            -- Only record state that was actually read. Writing back an
            -- unreadable pass overwrites the real state, and the next readable
            -- pass then sees a transition on something that never moved.
            if cdReadable then tracker._wasOnCD = isActive end
            if auraUsable then tracker._wasHasAura = hasAura end
        until true
    end
end

-- Diagnostics for the CDM sound alerts, reachable as /sq cdm.
--
-- The alert chain has several places it can quietly stop -- the Blizzard buff
-- viewers not existing, cooldown IDs not lining up between the viewer that
-- reports aura state and the one alerts were configured against, or an alert
-- being attached to a spell that is in a named group and therefore handled on a
-- different path. This prints each of those so a failure can be identified
-- rather than guessed at.
function cdmModule:PrintSoundDiagnostics()
    print("Squizzumables CDM sound diagnostics:")
    print("  CDM enabled:", tostring(BH.settings and BH.settings.cdmEnabled))
    print("  auras secret right now:", tostring(BH.Secrets.AurasAreSecret()))
    print("  in combat:", tostring(InCombatLockdown()))

    -- When the set was last seen to change, and when it was last rebuilt.
    --
    -- "the icons are stale" has two very different causes -- the change was
    -- never noticed (signature unchanged), or it was noticed and the rebuild
    -- did not happen or ran too early. A timestamp on each separates them,
    -- which guessing between them repeatedly did not.
    do
        local now = GetTime()
        local function ago(t)
            if not t then return "never" end
            return string.format("%.1fs ago", now - t)
        end
        print(string.format("  cooldown set last changed: %s | last reconcile: %s | spec key: %s",
            ago(cdmModule.lastSetChangeAt), ago(cdmModule.lastReconcileAt),
            tostring(GetSpecKey())))
    end

    -- Whether Blizzard's own filtering is being honoured, per viewer.
    --
    -- "our groups list more than Blizzard's bars" has two completely different
    -- causes -- the filter not being read at all, or being read correctly by a
    -- player who has hidden nothing -- and they look identical on screen. This
    -- is the only thing that separates them, so it is the first question on any
    -- report that a group is showing too much.
    --
    -- honoured=false is expected for a few seconds after login (the viewer pool
    -- is lazy) and a bug if it persists.
    -- Where each group thinks it is, versus where it actually is.
    --
    -- "I moved it and it went back" has at least three separate causes that look
    -- identical on screen: the drag never saved, the drag saved but something
    -- re-positioned the container, or the container is exactly where it should
    -- be and the ICONS are drawing somewhere else (which is possible for a
    -- borrowed group, because those are Blizzard's frames and only their anchors
    -- are ours). saved vs actual separates the first two; holds= separates the
    -- third, since a borrowed group with 0 frames is not re-anchoring anything.
    do
        print("  group positions (saved -> actual, borrowed groups show frame count):")
        -- Fetched here rather than assumed in scope: `specData` is a local in
        -- the reconcile paths, not in this one, and a bare read would be nil
        -- with no error -- reporting "saved=?,?" for every group and hiding the
        -- exact thing this is here to show.
        local posSpecData = GetSpecData()
        for groupName, group in pairs(cdmModule.groups) do
            local gd = posSpecData and posSpecData.groups[groupName]
            local sx, sy = "?", "?"
            if gd and gd.position then
                sx = string.format("%.0f", gd.position.x or 0)
                sy = string.format("%.0f", gd.position.y or 0)
            end
            local ax, ay = "?", "?"
            local shown = "hidden"
            if group.container then
                local cx, cy = group.container:GetCenter()
                local px, py = UIParent:GetCenter()
                if cx and px then
                    ax = string.format("%.0f", cx - px)
                    ay = string.format("%.0f", cy - py)
                end
                shown = group.container:IsShown() and "shown" or "hidden"
            end
            local kind = group.usesBlizzardIcons and "borrowed" or "proxy"
            local held = 0
            if group.usesBlizzardIcons then
                for _, viewerName in ipairs(BORROW_VIEWERS[groupName] or BUFF_VIEWERS) do
                    local viewer = _G[viewerName]
                    if viewer then
                        local ok, children = pcall(function() return { viewer:GetChildren() } end)
                        if ok and children then
                            for _, child in ipairs(children) do
                                if child and child.cooldownID and child:IsShown() then
                                    held = held + 1
                                end
                            end
                        end
                    end
                end
            else
                for _ in pairs(group.members or {}) do held = held + 1 end
            end
            print(string.format("      %-14s saved=%5s,%-6s actual=%5s,%-6s %-8s %-6s holds=%d%s",
                groupName, sx, sy, ax, ay, kind, shown, held,
                (gd and gd.isBarGroup) and " [bars]" or ""))
            if gd and gd.anchorTo and gd.anchorTo ~= "" then
                print(string.format("        anchored to %s (%s) -- its own saved position is ignored",
                    tostring(gd.anchorTo), tostring(gd.anchorPoint)))
            end
        end
    end

    do
        print("  Blizzard CDM filter (false = falling back to the raw category set):")
        for _, viewerInfo in ipairs(DISCOVER_CATEGORIES) do
            local used = cdmModule.usedBlizzardFilter[viewerInfo.viewer]
            local filtered = BlizzardFilteredIDs(viewerInfo.viewer)
            local raw = C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCategorySet
                and C_CooldownViewer.GetCooldownViewerCategorySet(viewerInfo.category)
            print(string.format("      %-24s honoured=%-5s shows %s of %s",
                viewerInfo.viewer, tostring(used and true or false),
                filtered and tostring(#filtered) or "?",
                raw and tostring(#raw) or "?"))
        end
    end

    do
        local hooked = 0
        for _ in pairs(cdmModule.hookDrivenCooldowns) do hooked = hooked + 1 end
        print(string.format("  cooldowns driven by Blizzard alert hook: %d", hooked))
        -- Name them: "is it hooked?" is the first question whenever an alert
        -- does not fire, and a bare count cannot answer it for one spell.
        for cdID in pairs(cdmModule.hookDrivenCooldowns) do
            local info = C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo
                       and C_CooldownViewer.GetCooldownViewerCooldownInfo(cdID)
            local spellID = info and info.spellID
            local name = spellID and C_Spell.GetSpellName(spellID)
            local nAlerts = #CollectAlertsFor(cdID)
            print(string.format("      [%s] %s -- %d sound alert(s) configured",
                tostring(cdID), BH.Secrets.SafeString(name, "?"), nAlerts))
        end
        print("    (these fire from Blizzard's own state machine and work in combat;")
        print("     anything not listed falls back to polling, which cannot see a")
        print("     cooldown come up in combat -- add it to Blizzard's Cooldown Manager)")
    end

    for _, viewerName in ipairs(BUFF_VIEWERS) do
        local viewer = _G[viewerName]
        local kids, active, withIsActive = 0, 0, 0
        local childIDs = {}
        if viewer then
            local ok, children = pcall(function() return { viewer:GetChildren() } end)
            if ok and children then
                for _, child in ipairs(children) do
                    if child and child.cooldownID then
                        kids = kids + 1
                        childIDs[#childIDs + 1] = tostring(child.cooldownID)
                        if child.IsActive then
                            withIsActive = withIsActive + 1
                            local gotState, state = pcall(child.IsActive, child)
                            if gotState and state then active = active + 1 end
                        end
                    end
                end
            end
        end
        print(string.format("  %s: %s, %d tracked child(ren), %d expose IsActive, %d active now",
            viewerName, viewer and "found" or "MISSING", kids, withIsActive, active))
        if #childIDs > 0 then
            print("      contains cooldownIDs: " .. table.concat(childIDs, ", "))
        end
    end

    local soundAlerts = GetCDMSoundAlerts()
    local specData = GetSpecData()
    local n = 0
    for alertKey, alerts in pairs(soundAlerts) do
        n = n + #alerts
        local tracker = cdmModule.soundTrackers[alertKey]
        -- Keys are spellIDs post-migration; resolve back to the live
        -- cooldownID for the viewer-state lookups below.
        local sid, cdID
        local asSpell = cdmModule.SpellIDForCooldown(alertKey)
        if asSpell then cdID, sid = alertKey, asSpell
        else sid, cdID = alertKey, cdmModule.cooldownForSpell[alertKey] end
        local spellName = sid and C_Spell.GetSpellName(sid)
        local assignment = specData and specData.assignments and specData.assignments[cdID]
        -- Report the two aura signals separately. The viewer only knows about
        -- cooldowns the player has chosen to show in it, so the case where a
        -- direct aura read disagrees with it is exactly what needs to be seen.
        local viewerSays = cdmModule.activeBuffCooldowns[cdID] and true or false
        local auraSays   = (sid and BH.Secrets.GetAuraBySpellID("player", sid)) and true or false
        print(string.format("  %s (spellID %s, live cooldownID %s): %d alert(s), group: %s, tracked: %s",
            tostring(BH.Secrets.SafeString(spellName, "?")),
            tostring(sid),
            tostring(cdID or "none"),
            #alerts,
            assignment or "FREE",
            tracker and "yes" or "no (never evaluated)"))
        do
            -- The question this whole block exists to answer: is this stored
            -- alert actually reachable, or filed under a cooldownID the live
            -- viewer no longer uses?
            local hookedByID    = cdmModule.hookDrivenCooldowns[cdID] and true or false
            local hookedBySpell = sid and cdmModule.hookDrivenSpellIDs[sid] and true or false
            print(string.format("      delivery -- hook by ID: %s, hook by spell: %s, else poll",
                tostring(hookedByID), tostring(hookedBySpell)))
            if not hookedByID and hookedBySpell then
                print("      note: stored under a stale cooldownID; matched by spellID instead")
            end
        end
        do
            -- Proof of why the poll cannot work in combat: report whether the
            -- cooldown fields we would have to compare are secret right now.
            -- Run this out of combat and in combat -- if these flip to true,
            -- any addon doing `spellCooldownInfo.duration == 0` throws there.
            local cdi = sid and C_Spell.GetSpellCooldown and C_Spell.GetSpellCooldown(sid)
            if cdi then
                print(string.format("      GetSpellCooldown secret? startTime: %s, duration: %s",
                    tostring(BH.Secrets.IsSecret(cdi.startTime)),
                    tostring(BH.Secrets.IsSecret(cdi.duration))))
            else
                print("      GetSpellCooldown returned nothing")
            end
            -- The alternative source: state Blizzard already computed and left
            -- on its own item frame. If this reads true/false rather than
            -- "unreadable", the available alert can work in combat.
            local vActive, vReadable = CooldownActiveFromViewer(cdID, sid)
            -- Report the cooldown-type item, which is the one actually
            -- consulted -- not whatever item the alert key happened to name.
            local cdItemID = sid and cdmModule.cooldownForSpell[sid]
            local item = cdItemID and cdmModule.viewerItems[cdItemID]
            print(string.format("      viewer item: %s, onCooldown: %s",
                item and ("yes (cooldownID " .. tostring(cdItemID) .. ")")
                    or "NO cooldown-type item (spell not in Essential/Utility CDM)",
                vReadable and tostring(vActive) or "unreadable"))
            if item then
                -- Break out each field: "unreadable" was conflating two very
                -- different causes -- the value being secret, versus Blizzard
                -- never having computed it for this item at all.
                local function describe(v)
                    if v == nil then return "nil (never set)" end
                    if BH.Secrets.IsSecret(v) then return "SECRET" end
                    return tostring(v)
                end
                print(string.format("        isOnActualCooldown=%s cooldownIsActive=%s",
                    describe(item.isOnActualCooldown), describe(item.cooldownIsActive)))
                print(string.format("        allowAvailableAlert=%s availableAlertTriggerTime=%s isOnGCD=%s",
                    describe(item.allowAvailableAlert), describe(item.availableAlertTriggerTime),
                    describe(item.isOnGCD)))
            end
        end
        print(string.format("      aura active now -- viewer: %s, direct read: %s",
            tostring(viewerSays), tostring(auraSays)))
        if tracker then
            print(string.format("      last seen -- hasAura: %s, active: %s",
                tostring(tracker._wasHasAura and true or false),
                tostring(tracker._wasOnCD and true or false)))
        end
        for _, alert in ipairs(alerts) do
            print(string.format("      when=%s type=%s sound=%s",
                tostring(alert.when), tostring(alert.type), tostring(alert.sound)))
        end
    end
    if n == 0 then
        print("  No sound alerts configured. Add one from /squizz CDMS.")
    end
end

-- What Squizzumables_CDM.lua's forwarders call (see the header).
cdmModule.proxyVisuals.ApplyProxyVisuals = ApplyProxyVisuals
cdmModule.proxyVisuals.FireCDSounds      = FireCDSounds
