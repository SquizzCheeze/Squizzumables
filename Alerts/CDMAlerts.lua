-- Alerts/CDMAlerts.lua
-- The CDM Alerts tab: buff images (painting, placing, the preview and move
-- handle, Blizzard's spell-overlay hook), cooldown alert images, the player's
-- own buffs from the spellbook, and the tab itself -- one grid of buffs and
-- Essential/Utility cooldowns with one editor (sounds, image controls).
--
-- Moved out of Squizzumables_SpellAlerts.lua unchanged in 2.0 phase 2; see
-- Alerts/Kelerts.lua for how the Alerts/ files share names. The images and the
-- editor share mutable state (the image being moved, the preview frame, the
-- selection), so they stay in one file.

local addonName, ns = ...
local BH = ns.BH

local SQ_COLORS        = ns.SQ_COLORS
local CreateSQButton   = ns.CreateSQButton
local CreateSQEditBox  = ns.CreateSQEditBox
local CreateSQSlider   = ns.CreateSQSlider
local CreateSQCheckbox = ns.CreateSQCheckbox
local CreateSQDropdown = ns.CreateSQDropdown

local A = ns.Alerts

local KEL_MEDIA_PATH       = A.KEL_MEDIA_PATH
local ShowAlert            = A.ShowAlert
local AllAlerts            = A.AllAlerts
local CurrentAlert         = A.CurrentAlert
local TriggerActive        = A.TriggerActive
local FRESH_TRIGGER_WINDOW = A.FRESH_TRIGGER_WINDOW
local TriggerAge           = A.TriggerAge

local BuffSounds           = A.BuffSounds
local aliasOwner           = A.aliasOwner
local cdmOwnIDs            = A.cdmOwnIDs
local AddAlias             = A.AddAlias
local SeedAliases          = A.SeedAliases
local MergedInto           = A.MergedInto
local AuraIDsFor           = A.AuraIDsFor
local ScanCDMBuffs         = A.ScanCDMBuffs
local UnmergeSeparateBuffs = A.UnmergeSeparateBuffs

-- ============================================================================
-- Buff images (V1.95)
--
-- The image half of a custom Kelert, which reading the aura could never do in
-- combat. Each buff in the grid can carry an image that is on screen exactly
-- while that buff is up -- different buffs, different images. The aura
-- engine shows and hides it (BH.cdm.native:BuildBuffImage), so it works in
-- combat; nothing here reads the aura.
--
-- Stored on the same entry as the buff's sounds, BuffSounds()[spellID]:
--   image        a BUNDLED_IMAGES key ("vignette", "flames_u", ...) |
--                "custom" | nil
--   imageTexture custom: a game atlas name, a texture path, or a file name in
--                the addon's Media folder
--   imageFrames/imageCols/imageRows/imageFrameW/imageFrameH/imageFps/imageLoop
--                custom only: the texture is a FLIPBOOK sheet when imageFrames
--                > 1 (frame size in pixels; 0 = work it out, atlases only)
--   imageColor   { r, g, b } tint (the glow is white, so this is its colour)
--   imageAlpha   0..1
--   imageFill    true = over the whole screen, behind the interface;
--                false = imageSize square at its own position
--   imageSize    pixels, when not filling the screen
--   imageHeight  height as a % of imageSize (default 100) -- the "( )" arcs
--                want taller than wide to frame a character
--   imageX/Y     its own position, offset from the screen's centre
--   imageStacks  0/nil = shown whole; N = revealed as the buff stacks, whole
--                at N stacks (imageReveal "right" = left to right, "up" =
--                bottom to top). A buff that does not stack shows nothing.
--
-- ANIMATION IS A FLIPBOOK, never a texture swap. The lust alert animates by
-- SetTexture-ing the next numbered file every frame; that cannot work here,
-- because nothing on the engine's button may be touched after it is built.
-- A FlipBook animation is set up ONCE, inside initializeFrame, and the client
-- steps through the sheet itself. A child frame of ours restarts it on every
-- show (OnShow), so a buff re-applied later does not come back frozen on
-- whatever frame it stopped at -- whether that restart is needed at all, and
-- whether the client allows it once the aura is secret, is UNVERIFIED; it is
-- pcall'd so a refusal costs nothing.
-- ============================================================================

local ALERTS = KEL_MEDIA_PATH .. "Alerts\\"
local VIGNETTE = ALERTS .. "vignette.png"

-- The flame sheets' layout, as .claude/make-flames.ps1 draws them: 32 frames
-- of 512x256, 4 columns x 8 rows, on 2048x2048. Change both together.
local FLAME_SHEET = { frames = 32, cols = 4, rows = 8, w = 512, h = 256, fps = 16, loop = true }
-- "( )" arcs round a centre: 32 frames of 256x256, 8 columns x 4 rows, on
-- 2048x1024 (make-flames.ps1's MakeArcs).
local ARC_SHEET = { frames = 32, cols = 8, rows = 4, w = 256, h = 256, fps = 16, loop = true }

-- The arcs come in five thicknesses (imageThickness 1-5, default 3), each its
-- own sheet. A thicker sheet draws a smaller ellipse to make room for its
-- flames (rx = 0.47 - thick, ry = 0.53 - thick, in make-flames.ps1), so the
-- frame is scaled by ellipse(3) / ellipse(n) to keep the arc's centre line
-- where the player placed it: thickness changes the fire, not the framing.
local ARC_LEVELS = {}
do
    local thick = { 0.05, 0.09, 0.13, 0.17, 0.21 }   -- must match make-flames.ps1
    for n, t in ipairs(thick) do
        ARC_LEVELS[n] = {
            file = ALERTS .. (n == 3 and "flames_arcs.png" or ("flames_arcs_" .. n .. ".png")),
            sw = (0.47 - 0.13) / (0.47 - t),
            sh = (0.53 - 0.13) / (0.53 - t),
        }
    end
end

-- Images that ship with the addon, offered in the editor's Image dropdown.
local BUNDLED_IMAGES = {
    vignette      = { file = VIGNETTE },
    flames_u      = { file = ALERTS .. "flames_u.png",      sheet = FLAME_SHEET, blend = "ADD" },
    flames_sides  = { file = ALERTS .. "flames_sides.png",  sheet = FLAME_SHEET, blend = "ADD" },
    flames_bottom = { file = ALERTS .. "flames_bottom.png", sheet = FLAME_SHEET, blend = "ADD" },
    flames_ring   = { file = ALERTS .. "flames_ring.png",   sheet = FLAME_SHEET, blend = "ADD" },
    -- placed: framed round something (your character), not the screen's edge
    flames_arcs   = { file = ALERTS .. "flames_arcs.png",   sheet = ARC_SHEET,   blend = "ADD", placed = true,
                      levels = ARC_LEVELS, height = 150 },
    -- .claude/make-auras.ps1. The animated four share the arcs' sheet layout;
    -- the last four are still images. `height` is the Height % a placed image
    -- starts at when picked (the ( ) shapes want taller than wide).
    lightning_arcs = { file = ALERTS .. "aura_lightning.png", sheet = ARC_SHEET, blend = "ADD", placed = true, height = 150 },
    frost_arcs     = { file = ALERTS .. "aura_frost.png",     sheet = ARC_SHEET, blend = "ADD", placed = true, height = 150 },
    heartbeat      = { file = ALERTS .. "aura_heart.png",     sheet = ARC_SHEET, blend = "ADD", placed = true },
    arcane_orbit   = { file = ALERTS .. "aura_arcane.png",    sheet = ARC_SHEET, blend = "ADD", placed = true },
    angel_wings    = { file = ALERTS .. "aura_wings.png",     placed = true },   -- opaque feathers: BLEND
    shield_bubble  = { file = ALERTS .. "aura_bubble.png",    blend = "ADD", placed = true },
    sunburst       = { file = ALERTS .. "aura_sunburst.png",  blend = "ADD", placed = true },
    rune_circle    = { file = ALERTS .. "aura_runes.png",     blend = "ADD", placed = true },
}
BH.KEL_BUNDLED_IMAGES = BUNDLED_IMAGES

local imageHosts = {}     -- [spellID] = our frame the image is placed by (reused)
local builtImageSig = {}  -- [spellID] = signature of the image last built
local imagesPending = false

-- What to draw: atlas or file, the flipbook layout if it animates, and the
-- blend mode.
-- The thickness level of an image that has them, or nil.
local function ImageLevel(entry)
    local bundled = BUNDLED_IMAGES[entry.image]
    local levels = bundled and bundled.levels
    if not levels then return nil end
    return levels[tonumber(entry.imageThickness) or 3] or levels[3]
end

local function ImageSource(entry)
    local bundled = BUNDLED_IMAGES[entry.image]
    if bundled then
        local lv = ImageLevel(entry)
        return nil, lv and lv.file or bundled.file, bundled.sheet, bundled.blend or "BLEND"
    end
    local name = strtrim(tostring(entry.imageTexture or ""))
    if name == "" then return nil, VIGNETTE, nil, "BLEND" end
    local sheet
    local frames = tonumber(entry.imageFrames) or 1
    if frames > 1 then
        sheet = {
            frames = frames,
            cols = math.max(1, tonumber(entry.imageCols) or 1),
            rows = math.max(1, tonumber(entry.imageRows) or 1),
            w = tonumber(entry.imageFrameW) or 0,
            h = tonumber(entry.imageFrameH) or 0,
            fps = math.max(1, tonumber(entry.imageFps) or 12),
            loop = entry.imageLoop ~= false,
        }
    end
    if C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(name) then return name, nil, sheet, "BLEND" end
    if name:find("[\\/]") then return nil, name, sheet, "BLEND" end
    return nil, KEL_MEDIA_PATH .. name, sheet, "BLEND"
end

-- Paint `tex`, and if the image is a flipbook give it (or reconfigure) its
-- animation and play it. Returns the animation group, or nil for a still.
local function PaintImage(tex, entry)
    local atlas, file, sheet, blend = ImageSource(entry)
    if atlas then tex:SetAtlas(atlas) else tex:SetTexture(file) end
    tex:SetBlendMode(blend)
    local c = entry.imageColor or {}
    tex:SetVertexColor(c.r or 1, c.g or 1, c.b or 1, entry.imageAlpha or 0.8)

    local ag = tex._sqAnim
    if not sheet then
        if ag then ag:Stop() end
        if not atlas then tex:SetTexCoord(0, 1, 0, 1) end
        return nil
    end
    if not ag then
        ag = tex:CreateAnimationGroup()
        ag._sqFlip = ag:CreateAnimation("FlipBook")
        tex._sqAnim = ag
    end
    local fb = ag._sqFlip
    ag:Stop()
    fb:SetFlipBookFrameWidth(sheet.w)
    fb:SetFlipBookFrameHeight(sheet.h)
    fb:SetFlipBookRows(sheet.rows)
    fb:SetFlipBookColumns(sheet.cols)
    fb:SetFlipBookFrames(sheet.frames)
    fb:SetDuration(sheet.frames / sheet.fps)
    ag:SetLooping(sheet.loop and "REPEAT" or "NONE")
    ag:Play()
    return ag
end

-- Place a frame where an image for `entry` goes: the whole screen, behind the
-- interface, or a square at the image's OWN position (imageX/imageY, offset
-- from the screen's centre). Its own, not the lust alert's: each buff's image
-- is placed independently (user decision 2026-10-05), with the editor's Move
-- button.
--
-- BOTH at BACKGROUND strata: behind every interface window, in front of the
-- game world. Placed images were HIGH, which drew the ( ) arcs over the
-- spellbook and the world map (user screenshots 2026-10-09); framing the
-- character never needs to beat a window. (The Move handle raises itself to
-- DIALOG while it is out, so it can still be grabbed.)
local function PlaceImageFrame(f, entry)
    f:ClearAllPoints()
    f:SetFrameStrata("BACKGROUND")
    if entry.imageFill ~= false then
        f:SetAllPoints(UIParent)
    else
        local size = entry.imageSize or 200
        local lv = ImageLevel(entry)
        f:SetSize(size * (lv and lv.sw or 1), size * (entry.imageHeight or 100) / 100 * (lv and lv.sh or 1))
        f:SetPoint("CENTER", UIParent, "CENTER", entry.imageX or 0, entry.imageY or 0)
    end
end

local function ImageSignature(entry)
    local c = entry.imageColor or {}
    return table.concat({
        tostring(entry.image), tostring(entry.imageTexture),
        table.concat({ tostring(entry.imageFrames), tostring(entry.imageCols), tostring(entry.imageRows),
            tostring(entry.imageFrameW), tostring(entry.imageFrameH), tostring(entry.imageFps),
            tostring(entry.imageLoop) }, ","),
        ("%.3f,%.3f,%.3f,%.3f"):format(c.r or 1, c.g or 1, c.b or 1, entry.imageAlpha or 0.8),
        tostring(entry.imageFill ~= false), tostring(entry.imageSize or 200), tostring(entry.imageHeight or 100),
        tostring(entry.imageThickness or 3), tostring(entry.imageStacks or 0), tostring(entry.imageReveal or "right"),
        entry.imageFill == false and (tostring(entry.imageX or 0) .. "," .. tostring(entry.imageY or 0)) or "",
    }, "|")
end

--- Build every buff image from settings. Only images whose settings changed
--- are rebuilt: an aura container can never be destroyed, only switched off,
--- so rebuilding them all on every edit would leak one per image per edit.
--- In combat, the work waits for combat to end (containers are built out of
--- combat only).
-- ----------------------------------------------------------------------------
-- Blizzard's proc art ("spell alerts", SpellActivationOverlayFrame) is hidden
-- for any buff that has one of OUR images (user request 2026-10-05: Demonic
-- Core's sits where the ( ) arcs go). Only those: every other proc still
-- shows, and clearing the image brings Blizzard's back.
--
-- How: a hook on the frame's ShowOverlay, which every show goes through, sets
-- each of that spell's overlay TEXTURES to alpha 0 -- or back to 1, since the
-- overlays are pooled and the next spell to get one must not inherit our 0.
-- The texture, not the overlay: Blizzard's fade-in/out animations drive the
-- overlay frame's own alpha and would undo it. Plain, unprotected frame, and
-- the event's spell ID is not secret, so this works in combat. The game's
-- "spell alert" sound still plays (it is played in the same function, before
-- the overlay is shown, and cannot be cut without replacing Blizzard's code).
-- ----------------------------------------------------------------------------
local function OverlayHidden(spellID)
    if not spellID then return false end
    SeedAliases()
    -- Blizzard's alert may carry any of the buff's aura IDs -- or belong to a
    -- buff merged into another icon ("Also show for"), which answers for it.
    local merged = MergedInto()
    local owner = aliasOwner[spellID] or spellID
    local entry = BuffSounds()[merged[spellID] or 0] or BuffSounds()[merged[owner] or 0]
        or BuffSounds()[spellID] or BuffSounds()[aliasOwner[spellID] or 0]
    if type(entry) == "table" then return entry.image ~= nil end
    -- A KNOWN ID with no image is a buff of its own, not an unknown alias:
    -- name-matching it would hide the art of a different buff that merely
    -- shares a name, and learn it as an alias -- re-merging the two Howl of
    -- the Pack Leader buffs (471878 / 472325, 2026-10-08).
    if aliasOwner[spellID] ~= nil or cdmOwnIDs[spellID] then return false end
    -- Not an ID we know: match by NAME against the buffs given an image, and
    -- learn the ID. Blizzard's alert names exactly the ID the game uses, which
    -- the Cooldown Manager does not always list (Infusion of Light alerts
    -- under 458213 as well as 54149), so the image starts matching it too.
    local name = BH.Secrets.SafeString(C_Spell.GetSpellName(spellID), nil)
    if not name then return false end
    for gridID, e in pairs(BuffSounds()) do
        local id = tonumber(gridID)
        if id and type(e) == "table" and e.image
           and BH.Secrets.SafeString(C_Spell.GetSpellName(id), nil) == name then
            AddAlias(id, spellID)
            return true
        end
    end
    return false
end

local function ApplyOverlayHiding(frame, spellID)
    -- A spell ID that has gone secret cannot index a table (it raises), so
    -- the per-buff match cannot be made for it. Leave that overlay alone --
    -- "hide all" does not come through here at all (see below).
    if spellID == nil or BH.Secrets.IsSecret(spellID) then return end
    local list = frame.overlaysInUse and frame.overlaysInUse[spellID]
    if not list then return end
    local hide = OverlayHidden(spellID)
    for _, overlay in pairs(list) do
        -- Alpha 0 AND hidden: alpha alone still let the first proc of a
        -- session flash (user screenshots 2026-10-06). A spot check 0.05s
        -- after a SHOW found the texture's alpha back at 1 -- Blizzard's
        -- update resets it -- while Hide() held, and the flash was gone. So
        -- the Hide() is what does the work. Blizzard never shows or hides the texture itself --
        -- only the overlay frame round it -- so a hidden texture stays hidden
        -- until we show it again for a spell that is not hidden (the
        -- overlays are pooled).
        if overlay.texture then
            overlay.texture:SetAlpha(hide and 0 or 1)
            overlay.texture:SetShown(not hide)
        end
    end
end

-- "Hide all" hides Blizzard's whole alert frame instead of matching spells:
-- every overlay is drawn inside it, so nothing shows, not even for a frame,
-- and no spell ID is needed. Matching per spell left alerts up for seconds
-- (user report 2026-10-06) -- most likely spell IDs reaching the hook secret
-- in combat. Only re-shown if WE hid it, and kept hidden if anything shows it.
local hiddenByUs = false
local function ApplyHideAll()
    local frame = _G.SpellActivationOverlayFrame
    if not frame then return end
    if BH.settings and BH.settings.kelHideBlizzardAlerts then
        hiddenByUs = true
        frame:Hide()
    elseif hiddenByUs then
        hiddenByUs = false
        frame:Show()
    end
end

-- How often each hook has fired, for /sq buffimages: an alert hidden only
-- after a lag means neither caught the show (user report 2026-10-06).
local overlayHookCounts = { showOverlay = 0, overlayOnShow = 0 }
BH.BlizzardOverlayHookCounts = overlayHookCounts

-- Timeline of the last 40 spell-alert events and hook runs, for
-- /sq buffimages: stacked buffs' art still hid late (user report
-- 2026-10-06), and only the order and timing of these says why.
local overlayLog = {}
BH.BlizzardOverlayLog = overlayLog
local function LogOverlay(what, spellID, extra)
    local id = (spellID ~= nil and not BH.Secrets.IsSecret(spellID)) and tostring(spellID) or "secret"
    table.insert(overlayLog, ("%.2f %s %s%s"):format(GetTime(), what, id, extra or ""))
    if #overlayLog > 40 then table.remove(overlayLog, 1) end
end
do
    local f = CreateFrame("Frame")
    f:RegisterEvent("SPELL_ACTIVATION_OVERLAY_SHOW")
    f:RegisterEvent("SPELL_ACTIVATION_OVERLAY_HIDE")
    f:SetScript("OnEvent", function(_, event, spellID)
        LogOverlay(event == "SPELL_ACTIVATION_OVERLAY_SHOW" and "event SHOW" or "event HIDE", spellID)
    end)
end

-- Hook 1, at FILE LOAD: every overlay is a SpellActivationOverlayTemplate
-- frame, whose mixin's OnShow runs as it appears -- after spellID is set on
-- it. Mixin() copies methods into each frame as it is CREATED, and the pool
-- creates them on first use, so hooking the mixin table now (before any
-- proc) puts the check into every overlay Blizzard will ever make. Unlike
-- the instance hook below, this cannot miss because it was installed late.
if _G.SpellActivationOverlayTextureMixin and _G.SpellActivationOverlayTextureMixin.OnShow then
    hooksecurefunc(_G.SpellActivationOverlayTextureMixin, "OnShow", function(overlay)
        overlayHookCounts.overlayOnShow = overlayHookCounts.overlayOnShow + 1
        local parent = overlay:GetParent()
        if parent and overlay.spellID ~= nil then
            local ok, err = pcall(ApplyOverlayHiding, parent, overlay.spellID)
            LogOverlay("hook OnShow", overlay.spellID, ok and (" alpha " .. tostring(overlay.texture and overlay.texture:GetAlpha()))
                or (" ERROR " .. tostring(err)))
        end
    end)
end

local overlayHooked = false
local function HookBlizzardOverlay()
    local frame = _G.SpellActivationOverlayFrame
    if overlayHooked or not (frame and frame.ShowOverlay) then return end
    overlayHooked = true
    hooksecurefunc(frame, "ShowOverlay", function(self, spellID)
        overlayHookCounts.showOverlay = overlayHookCounts.showOverlay + 1
        -- Hide all, applied here as well: the first proc of a session can
        -- come before the first RefreshOverlayHiding.
        if BH.settings and BH.settings.kelHideBlizzardAlerts and self:IsShown() then ApplyHideAll() end
        local ok, err = pcall(ApplyOverlayHiding, self, spellID)
        LogOverlay("hook ShowOverlay", spellID, ok and (" hide=" .. tostring(select(2, pcall(OverlayHidden, spellID))))
            or (" ERROR " .. tostring(err)))
    end)
    hooksecurefunc(frame, "Show", function(self)
        if BH.settings and BH.settings.kelHideBlizzardAlerts then self:Hide() end
    end)
end
-- Installed at FILE LOAD, not on the first image refresh: that refresh runs a
-- moment after login, and a proc in between showed Blizzard's art until its
-- next refresh -- the sub-second flash on the first proc of a session (user
-- report 2026-10-06; /sq buffimages showed an "event SHOW" with no hook run).
-- Blizzard_FrameXML is loaded before any addon, so the frame exists now.
HookBlizzardOverlay()

-- Re-apply to whatever is on screen right now, after an image was set or
-- cleared (otherwise it would only take effect on the next proc).
local function RefreshOverlayHiding()
    HookBlizzardOverlay()
    ApplyHideAll()
    local frame = _G.SpellActivationOverlayFrame
    if not (frame and frame.overlaysInUse) then return end
    for spellID in pairs(frame.overlaysInUse) do
        pcall(ApplyOverlayHiding, frame, spellID)
    end
end
BH.BlizzardOverlayHidden = OverlayHidden

function BH:RefreshBuffImages()
    RefreshOverlayHiding()
    local native = self.cdm and self.cdm.native
    if not (native and native.BuildBuffImage) then return end
    if InCombatLockdown() then imagesPending = true return end
    imagesPending = false

    local wanted = {}
    for spellID, entry in pairs(BuffSounds()) do
        local id = tonumber(spellID)
        if id and type(entry) == "table" and entry.image then
            wanted[id] = entry
        end
    end
    for id in pairs(builtImageSig) do
        if not wanted[id] then
            native:ReleaseBuffImage(id)
            builtImageSig[id] = nil
            if imageHosts[id] then imageHosts[id]:Hide() end
        end
    end
    ScanCDMBuffs()   -- fresh aura ID aliases
    for id, entry in pairs(wanted) do
        -- The aura IDs are part of the signature, so an alias the CDM only
        -- reports later (talents loading after login) rebuilds the image.
        local auraIDs = AuraIDsFor(id)
        local idList = {}
        for a in pairs(auraIDs) do idList[#idList + 1] = a end
        table.sort(idList)
        local sig = ImageSignature(entry) .. "|" .. table.concat(idList, ",")
        if builtImageSig[id] ~= sig then
            local host = imageHosts[id]
            if not host then
                host = CreateFrame("Frame", nil, UIParent)
                host:EnableMouse(false)
                imageHosts[id] = host
            end
            PlaceImageFrame(host, entry)
            host:Show()
            local ok = native:BuildBuffImage(id, auraIDs, host, function(button, watcher)
                -- Reveal by stacks (imageStacks = stacks for the full image):
                -- the engine drives a StatusBar from the aura's stack count
                -- (SetApplicationBar), and that bar is used only as a WINDOW.
                -- Its fill texture is invisible; a clipping frame sits exactly
                -- on it, so as the fill grows with stacks it uncovers the
                -- image behind it -- anchored to the whole button, so the
                -- image itself never moves or crops its texcoords and the
                -- flipbook keeps playing. "( )" arcs at 2 stacks: 1 stack
                -- shows the left arc, 2 both. The stack count is secret in
                -- combat; we never read it, the engine sizes the fill.
                local parent = button
                local stacks = tonumber(entry.imageStacks) or 0
                if stacks > 0 and button.SetApplicationBar then
                    local bar = CreateFrame("StatusBar", nil, button)
                    bar:SetAllPoints(button)
                    bar:SetOrientation(entry.imageReveal == "up" and "VERTICAL" or "HORIZONTAL")
                    bar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
                    bar:GetStatusBarTexture():SetAlpha(0)
                    button:SetApplicationBar(bar, { maxApplications = stacks })
                    local clip = CreateFrame("Frame", nil, bar)
                    clip:SetAllPoints(bar:GetStatusBarTexture())
                    clip:SetClipsChildren(true)
                    parent = clip
                end
                local tex = parent:CreateTexture(nil, "ARTWORK")
                tex:SetAllPoints(button)
                local ag = PaintImage(tex, entry)
                if ag and watcher then
                    -- Restart the flipbook each time the engine shows the
                    -- button again (see the section header). `watcher` is
                    -- our own child frame of the button (BuildBuffImage).
                    watcher.onShow = function() ag:Restart() end
                end
            end)
            builtImageSig[id] = ok and sig or nil
        end
    end
end

-- For controls that fire continuously while dragged (colour picker, sliders):
-- one rebuild after the dragging stops, not one per step, since every rebuild
-- strands a container.
local imageRefreshTimer
function BH:RefreshBuffImagesSoon()
    if imageRefreshTimer then imageRefreshTimer:Cancel() end
    imageRefreshTimer = C_Timer.NewTimer(0.4, function()
        imageRefreshTimer = nil
        BH:RefreshBuffImages()
    end)
end

-- /sq buffimages -- unlisted; see CLAUDE.md. Every link from setting to
-- screen, so "nothing shows" can be pinned to one of them: is the engine
-- there, did the image build, did the engine make its button, and -- the
-- usual one -- is the configured ID really the ID of the aura on you? The
-- buff grid lists CAST spell IDs; the slot matches AURA IDs. The aura list
-- needs to be run out of combat (aura data is hidden in it).
local function PrintBuffImageDiagnosticsBody()
    local P = function(s) print("  " .. s) end
    print("|cFF00FF00Squizzumables buff images|r")
    local native = BH.cdm and BH.cdm.native
    if not native then P("CDM aura module not loaded -- images cannot build.") return end
    P(("aura engine available: %s   in combat: %s   images waiting for combat to end: %s")
        :format(tostring(native:IsAvailable()), tostring(InCombatLockdown()), tostring(imagesPending)))
    P("last engine error: " .. tostring(native.lastError or "none"))

    local configured = {}
    for spellID, entry in pairs(BuffSounds()) do
        local id = tonumber(spellID)
        if id and type(entry) == "table" and entry.image then
            configured[id] = true
            local name = C_Spell.GetSpellName and C_Spell.GetSpellName(id)
            local c, info = native:BuffImageInfo(id)
            P(("%s (%d): image=%s  built=%s  container=%s  buttons made=%s")
                :format(tostring(BH.Secrets.SafeString(name, "?")), id, tostring(entry.image),
                    builtImageSig[id] and "yes" or "NO",
                    c and (c:IsVisible() and "visible" or "hidden") or "none",
                    info and tostring(info.inits) or "-"))
            -- The engine showing the button is what puts the image up. 0 shows
            -- with the buff on = the aura never matched the slot.
            if info then
                P(("    engine showed the image %d time(s), hid it %d time(s)")
                    :format(info.shows or 0, info.hides or 0))
            end
            local host = imageHosts[id]
            if host then
                P(("    host: shown=%s  size=%dx%d  strata=%s")
                    :format(tostring(host:IsShown()), host:GetWidth(), host:GetHeight(), host:GetFrameStrata()))
            end
        end
    end
    if not next(configured) then P("no buff has an image set") end

    -- Blizzard's own proc art: hidden for a spell with one of our images. If
    -- it still shows, its ID here differs from the aura's.
    local sao = _G.SpellActivationOverlayFrame
    local shown = {}
    for id in pairs(sao and sao.overlaysInUse or {}) do
        if BH.Secrets.IsSecret(id) then
            shown[#shown + 1] = "(spell ID secret -- cannot match per buff)"
        else
            shown[#shown + 1] = ("%s (%s)%s"):format(tostring(BH.Secrets.SafeString(C_Spell.GetSpellName(id), "?")),
                tostring(id), BH.BlizzardOverlayHidden(id) and " hidden" or "")
        end
    end
    P("Blizzard spell alerts on screen: " .. (#shown > 0 and table.concat(shown, ", ") or "none"))
    P(("Blizzard alert frame shown: %s   hide all: %s"):format(tostring(sao and sao:IsShown()),
        tostring(BH.settings.kelHideBlizzardAlerts == true)))
    local hc = BH.BlizzardOverlayHookCounts or {}
    P(("alert hooks fired: ShowOverlay %d, overlay OnShow %d")
        :format(hc.showOverlay or 0, hc.overlayOnShow or 0))
    local log = BH.BlizzardOverlayLog or {}
    P(("alert timeline (game time, last %d, oldest first; now %.2f):"):format(#log, GetTime()))
    for _, line in ipairs(log) do P("    " .. line) end

    if InCombatLockdown() then
        P("buffs on you: run this again OUT of combat -- the game hides aura data in combat")
        return
    end
    P("buffs on you now (name: aura ID) -- an image needs the AURA ID:")
    local n = 0
    for i = 1, 60 do
        local ok, a = pcall(C_UnitAuras.GetAuraDataByIndex, "player", i, "HELPFUL")
        if not ok or not a then break end
        local id = BH.Secrets.SafeNumber(a.spellId, nil)
        local nm = BH.Secrets.SafeString(a.name, "?")
        n = n + 1
        P(("    %s: %s%s"):format(tostring(nm), tostring(id or "hidden"),
            (id and configured[id]) and "  <- has an image" or ""))
    end
    if n == 0 then P("    none") end
end

function BH:PrintBuffImageDiagnostics()
    local ok, err = pcall(PrintBuffImageDiagnosticsBody)
    if not ok then print("  |cffff4444diagnostics failed:|r " .. tostring(err)) end
    print("  -- end of buffimages --")
end

-- A built image's state, for the editor: "active", "waiting" (combat) or nil.
function BH.BuffImageState(spellID)
    if builtImageSig[tonumber(spellID)] then return "active" end
    if imagesPending then return "waiting" end
    return nil
end

do
    local ev = CreateFrame("Frame")
    ev:RegisterEvent("PLAYER_REGEN_ENABLED")
    -- The Cooldown Manager's lists (the source of the aura ID aliases) are not
    -- ready at login and change with talents and spec, so they are re-read a
    -- few seconds after each of these. AddAlias queues the rebuild when the
    -- scan turns up something new; an unchanged scan costs nothing.
    ev:RegisterEvent("PLAYER_ENTERING_WORLD")
    ev:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
    ev:RegisterEvent("TRAIT_CONFIG_UPDATED")
    local scanQueued = false
    ev:SetScript("OnEvent", function(_, event)
        if event == "PLAYER_REGEN_ENABLED" then
            if imagesPending then BH:RefreshBuffImages() end
            return
        end
        if scanQueued then return end
        scanQueued = true
        C_Timer.After(3, function()
            scanQueued = false
            -- The full list, not just the scan: building it also undoes stale
            -- name-folds (UnmergeSeparateBuffs) before any image is rebuilt.
            BH.GetKnownBuffSpells()
        end)
    end)
end

-- The Test button: the image as it will look, for a few seconds. A plain
-- frame of ours -- the real one only ever shows for a real buff or cooldown.
-- The same frame is the Move handle (BH:MoveImage), so what you drag is
-- exactly what will show. Shared by Buff Alerts and Cooldown Alerts.
local previewFrame, previewTimer
-- The image being placed with Move, or nil:
--   { key = any, entry = fn() -> its writable entry, done = fn() after a drop }
local moving

local function PreviewFrame()
    if previewFrame then return previewFrame end
    local f = CreateFrame("Frame", nil, UIParent)
    f:EnableMouse(false)
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f.tex = f:CreateTexture(nil, "ARTWORK")
    f.tex:SetAllPoints()
    -- Shown only while moving: a box and a label, so a faint image -- or one
    -- the colour of the scene behind it -- can still be found and grabbed.
    f.box = f:CreateTexture(nil, "BACKGROUND")
    f.box:SetAllPoints()
    f.box:SetColorTexture(0.1, 0.4, 0.8, 0.25)
    f.label = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.label:SetPoint("CENTER")
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) BH:GridStartMoving(self) end)
    f:SetScript("OnDragStop", function(self)
        BH:GridStopMoving(self)
        local entry = moving and moving.entry()
        if not entry then return end
        -- Saved as an offset from the screen's centre. Both centres are read
        -- in UIParent's space (this frame is its child at scale 1).
        local fx, fy = self:GetCenter()
        local ux, uy = UIParent:GetCenter()
        if fx and ux then
            entry.imageX = math.floor(fx - ux + 0.5)
            entry.imageY = math.floor(fy - uy + 0.5)
            BH:SaveSettings()
            if moving.done then moving.done() end
        end
    end)
    previewFrame = f
    return f
end

--- Show an image entry for a few seconds, as it will look.
function BH:PreviewImage(entry)
    if not (entry and entry.image) or moving then return end
    local f = PreviewFrame()
    PlaceImageFrame(f, entry)
    PaintImage(f.tex, entry)
    f.box:Hide()
    f.label:SetText("")
    f:Show()
    if previewTimer then previewTimer:Cancel() end
    previewTimer = C_Timer.NewTimer(3, function()
        f:Hide()
        if f.tex._sqAnim then f.tex._sqAnim:Stop() end
        previewTimer = nil
    end)
end

function BH:PreviewBuffImage(spellID)
    BH:PreviewImage(BuffSounds()[tonumber(spellID)])
end

--- Start or finish placing an image by dragging it. Each image has its own
--- position, independent of every other image and of the lust alert. `key`
--- names it (calling again with the same key is Done); `entryFn` returns its
--- writable entry; `done` runs after each drop.
function BH:MoveImage(key, entryFn, done)
    local f = PreviewFrame()
    if moving then
        -- Done (or switching to another image): put the handle away.
        local wasSame = moving.key == key
        moving = nil
        f:EnableMouse(false)
        f:Hide()
        if wasSame then return end
    end
    local entry = entryFn and entryFn()
    if not (entry and entry.image) or entry.imageFill ~= false then return end
    if previewTimer then previewTimer:Cancel(); previewTimer = nil end
    moving = { key = key, entry = entryFn, done = done }
    PlaceImageFrame(f, entry)
    -- Above everything while being placed, whatever the image sits at.
    f:SetFrameStrata("DIALOG")
    PaintImage(f.tex, entry)
    f.box:Show()
    f.label:SetText("Drag me")
    f:EnableMouse(true)
    f:Show()
end

function BH.MovingImage(key) return moving ~= nil and moving.key == key end

--- Put the Move handle away, whichever image it belongs to.
function BH.StopMovingImage()
    if moving then BH:MoveImage(moving.key) end
end

local function BuffMoveKey(spellID) return "buff:" .. tostring(tonumber(spellID)) end

function BH:MoveBuffImage(spellID)
    local id = tonumber(spellID)
    BH:MoveImage(BuffMoveKey(id), function() return id and BuffSounds()[id] end,
        function() BH:RefreshBuffImages() end)
end

function BH.MovingBuffImage(spellID) return BH.MovingImage(BuffMoveKey(spellID)) end

-- Re-place the Move handle from its image's current settings, after the size,
-- height, thickness or position changed while it is out. Through
-- PlaceImageFrame, so the handle is always exactly what will show.
local function RefitMoveHandle()
    local entry = moving and previewFrame and moving.entry()
    if not entry then return end
    PlaceImageFrame(previewFrame, entry)
    previewFrame:SetFrameStrata("DIALOG")
end

-- ============================================================================
-- Cooldown Alerts images (2.0)
--
-- A cooldown's alert can carry an image as well as a sound, shown when its
-- event fires (PlayAlertsFor in Squizzumables_CDM.lua). Unlike a buff image
-- this needs no aura engine: Blizzard's Cooldown Manager tells us the moment
-- the event happens, in combat too, and showing a plain frame of our own is
-- always allowed. So the image is painted on the spot, with the same
-- PaintImage / PlaceImageFrame as everything else, and nothing is built ahead.
--
-- alert.imageShowFor: seconds (default 2), or "next" = until this spell's next
-- event of another kind, so a "Ready" image stays up until the spell is used.
-- Any new event for the spell ends its other images, timed or not.
-- ============================================================================
local CD_IMAGE_FADE = 0.3
local cdImageFrames = {}   -- [spellID .. ":" .. when] = frame, reused

local function StopCooldownImage(f)
    f.fade:Stop()
    f:Hide()
    if f.tex._sqAnim then f.tex._sqAnim:Stop() end
end

local function CooldownImageFrame(key)
    local f = cdImageFrames[key]
    if f then return f end
    f = CreateFrame("Frame", nil, UIParent)
    f:EnableMouse(false)
    f.tex = f:CreateTexture(nil, "ARTWORK")
    f.tex:SetAllPoints()
    f.fade = f:CreateAnimationGroup()
    local a = f.fade:CreateAnimation("Alpha")
    a:SetFromAlpha(1)
    a:SetToAlpha(0)
    a:SetDuration(CD_IMAGE_FADE)
    f.fade:SetScript("OnFinished", function() StopCooldownImage(f) end)
    f:Hide()
    cdImageFrames[key] = f
    return f
end

local function EndCooldownImage(f)
    if f.timer then f.timer:Cancel(); f.timer = nil end
    if f:IsShown() and not f.fade:IsPlaying() then f.fade:Play() end
end

function BH:ShowCooldownImage(spellID, alert)
    if not (alert and alert.image) then return end
    local f = CooldownImageFrame(spellID .. ":" .. tostring(alert.when))
    f.spellID, f.when = spellID, alert.when
    if f.timer then f.timer:Cancel(); f.timer = nil end
    f.fade:Stop()
    f:SetAlpha(1)
    PlaceImageFrame(f, alert)
    PaintImage(f.tex, alert)
    f:Show()
    if alert.imageShowFor ~= "next" then
        f.timer = C_Timer.NewTimer(tonumber(alert.imageShowFor) or 2, function()
            f.timer = nil
            EndCooldownImage(f)
        end)
    end
end

function BH:CooldownImageEvent(spellID, when)
    for _, f in pairs(cdImageFrames) do
        if f.spellID == spellID and f.when ~= when and f:IsShown() then EndCooldownImage(f) end
    end
end

--- Put every cooldown image away at once (loading screens, spec changes,
--- where an "until the next event" image could otherwise be left behind).
function BH:HideCooldownImages()
    for _, f in pairs(cdImageFrames) do
        if f.timer then f.timer:Cancel(); f.timer = nil end
        StopCooldownImage(f)
    end
end

do
    local f = CreateFrame("Frame")
    f:RegisterEvent("PLAYER_ENTERING_WORLD")
    f:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
    f:SetScript("OnEvent", function(_, event, unit)
        if event == "PLAYER_SPECIALIZATION_CHANGED" and unit and unit ~= "player" then return end
        BH:HideCooldownImages()
    end)
end

-- ============================================================================
-- The player's own buffs, from the spellbook
--
-- Built from the spellbook rather than from Blizzard's Cooldown Manager
-- categories, which is what frees this from the CDM entirely: AddAuraSound
-- takes a raw spell ID and does not care whether Blizzard filed the spell in a
-- viewer. isOffSpec is exactly "not in the spec and talents you have selected",
-- so the list maintains itself across every respec with nothing hardcoded.
--
-- IsSelfBuff narrows it to spells that put an aura on the player, which is what
-- an aura sound can actually fire on. It is not perfect -- a spell whose cast ID
-- differs from the ID of the aura it applies will register a sound that never
-- plays (Blessing of Freedom is 61107 to cast and 92824 as the buff) -- which is
-- why the tab also takes a spell ID by hand.
--
-- Since 2026-10-05 the CDM's buff categories are merged in as well (see
-- ScanCDMBuffs): the spellbook skips passives, and plenty of buffs come from
-- them (Demonic Core). The spellbook still comes first, so the list works with
-- the Cooldown Manager switched off; the CDM only adds to it.
-- ============================================================================

-- Spells the walk below misses, added by hand.
--
-- IsSelfBuff is the filter, and it does not agree that everything which puts an
-- aura on you is a self-buff. Tyr's Deliverance (200654) is the case that found
-- this: a Holy Paladin cooldown that visibly buffs the paladin, absent from
-- IsSelfBuff and absent from all four of Blizzard's cooldown categories even
-- with allowUnlearned. There is no data source that knows about it, so the list
-- is the honest answer rather than a workaround for one.
--
-- Gated on class, not on IsSpellKnown. These are *aura* IDs, and an aura is not
-- a known spell -- IsSpellKnown answers about things you can cast, so it can
-- return false for an ID you visibly have on you, which is what kept this list
-- from showing up at all on the first attempt.
--
-- Add entries when a buff that should obviously be in the grid is not.
local BUFF_SOUND_EXTRAS = {
    { spellID = 200654, class = "PALADIN" },  -- Tyr's Deliverance
}

function BH.GetKnownBuffSpells()
    local out = {}
    if not (C_SpellBook and C_SpellBook.GetNumSpellBookSkillLines) then return out end

    local seen = {}
    local bank = Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player or 0
    local numLines = C_SpellBook.GetNumSpellBookSkillLines() or 0

    for lineIndex = 1, numLines do
        local lineInfo = C_SpellBook.GetSpellBookSkillLineInfo(lineIndex)
        if lineInfo and lineInfo.numSpellBookItems then
            local first = (lineInfo.itemIndexOffset or 0) + 1
            local last  = (lineInfo.itemIndexOffset or 0) + lineInfo.numSpellBookItems
            for slot = first, last do
                local info = C_SpellBook.GetSpellBookItemInfo(slot, bank)
                -- isOffSpec covers the whole "current spec and talents" question.
                -- Passives cannot be alerted on usefully, and a flyout is a
                -- container rather than a spell.
                if info and not info.isPassive and not info.isOffSpec then
                    local spellID = info.spellID or info.actionID
                    if spellID and not seen[spellID] then
                        local isBuff = C_Spell.IsSelfBuff and C_Spell.IsSelfBuff(spellID)
                        if isBuff then
                            seen[spellID] = true
                            out[#out + 1] = {
                                spellID = spellID,
                                name    = info.name or C_Spell.GetSpellName(spellID),
                                icon    = info.iconID or C_Spell.GetSpellTexture(spellID),
                            }
                        end
                    end
                end
            end
        end
    end

    -- What the Cooldown Manager tracks as buffs: passives and procs the
    -- spellbook walk cannot see (user report 2026-10-05: buffs in the CDM
    -- missing from this list). A buff already listed under the same NAME --
    -- the spellbook's cast ID against the CDM's aura ID, Burning Rush style --
    -- is not listed twice; its aura IDs are folded into the existing icon, so
    -- that icon now matches either.
    --
    -- Only into a SPELLBOOK entry, and only once each. Two Cooldown Manager
    -- buffs that share a name are genuinely different buffs (Howl of the Pack
    -- Leader has two, user report 2026-10-08) and folding one into the other
    -- made a single icon that answered for both, so an image could not be
    -- given to just one. byName holds spellbook names only, and a name is
    -- used up by the first fold.
    local byName = {}
    for _, e in ipairs(out) do
        local nm = BH.Secrets.SafeString(e.name, nil)
        if nm then byName[nm] = e.spellID end
    end
    local separate = {}   -- CDM entries listed as icons of their own
    for _, cdmID in ipairs(ScanCDMBuffs()) do
        if not seen[cdmID] then
            seen[cdmID] = true
            local name = BH.Secrets.SafeString(C_Spell.GetSpellName(cdmID), nil)
            local existing = name and byName[name]
            if existing then
                byName[name] = nil
                for auraID in pairs(AuraIDsFor(cdmID)) do AddAlias(existing, auraID) end
            else
                separate[#separate + 1] = cdmID
                out[#out + 1] = {
                    spellID = cdmID,
                    name    = name or ("Spell " .. cdmID),
                    icon    = C_Spell.GetSpellTexture(cdmID),
                }
            end
        end
    end
    UnmergeSeparateBuffs(separate)

    local _, playerClass = UnitClass("player")
    for _, extra in ipairs(BUFF_SOUND_EXTRAS) do
        if not seen[extra.spellID] and (not extra.class or extra.class == playerClass) then
            seen[extra.spellID] = true
            out[#out + 1] = {
                spellID = extra.spellID,
                name    = C_Spell.GetSpellName(extra.spellID) or ("Spell " .. extra.spellID),
                icon    = C_Spell.GetSpellTexture(extra.spellID),
            }
        end
    end

    table.sort(out, function(a, b)
        return (a.name or ""):lower() < (b.name or ""):lower()
    end)
    return out
end

-- ============================================================================
-- Buff sounds UI
-- ============================================================================

-- Which icon the editor below the grid is editing.
local selectedBuffSpellID
-- ...or, since 2.0, which cooldown (CDM Alerts lists both in one grid). Held
-- as the spell ID (or cooldownID) and resolved against the live grid on every
-- rebuild, since the grid's entry tables are rebuilt each time.
local selectedCDKey
local selectedCD

local function CooldownMoveKey(cd) return "cd:" .. tostring(cd.spellID or cd.cooldownID) end

function BH.SelectBuffSpell(spellID)
    -- A Move handle belongs to the buff it was opened for; picking another
    -- buff puts it away rather than leaving it to move the wrong image.
    if moving and moving.key ~= BuffMoveKey(spellID) then BH.StopMovingImage() end
    selectedBuffSpellID = tonumber(spellID)
    selectedCDKey, selectedCD = nil, nil
end

function BH.SelectCooldown(cd)
    if moving and moving.key ~= CooldownMoveKey(cd) then BH.StopMovingImage() end
    selectedCDKey, selectedCD = cd.spellID or cd.cooldownID, cd
    selectedBuffSpellID = nil
end

-- This spec's Essential and Utility cooldowns, one entry per spell (a spell
-- can sit in two viewers; its other cooldownIDs ride along as `siblings`, so
-- the events offered can be the union of what each supports).
local function CooldownGridEntries()
    local out = { cooldown = {}, utility = {} }
    local cdm = BH.cdm
    if not (cdm and cdm.GetAvailableCooldowns) then return out end
    local bySpell = {}
    for _, info in pairs(cdm:GetAvailableCooldowns() or {}) do
        local list = out[info.viewerType or "cooldown"]
        if list then
            local sid = info.spellID
            local e = sid and bySpell[sid]
            if e then
                e.siblings = e.siblings or {}
                e.siblings[#e.siblings + 1] = info.cooldownID
            else
                e = { cooldownID = info.cooldownID, spellID = sid, name = info.name, icon = info.icon }
                if sid then bySpell[sid] = e end
                list[#list + 1] = e
            end
        end
    end
    for _, list in pairs(out) do
        table.sort(list, function(a, b) return (a.name or "") < (b.name or "") end)
    end
    return out
end

-- Every spell the grid should show: this spec's own buffs, plus anything
-- already configured that is not among them.
--
-- The second half matters because a spell ID added by hand -- or one kept from
-- a spec you have since left -- would otherwise vanish from the UI while its
-- sound carried on playing, which is the worst of both.
local function BuffGridEntries()
    local entries = BH.GetKnownBuffSpells()
    local seen = {}
    for _, e in ipairs(entries) do seen[e.spellID] = true end

    local extra = {}
    for spellID in pairs(BH.BuffSounds()) do
        local id = tonumber(spellID)
        if id and not seen[id] then
            extra[#extra + 1] = {
                spellID = id,
                name    = C_Spell.GetSpellName(id) or ("Spell " .. id),
                icon    = C_Spell.GetSpellTexture(id),
                manual  = true,
            }
        end
    end
    table.sort(extra, function(a, b) return (a.name or ""):lower() < (b.name or ""):lower() end)
    for _, e in ipairs(extra) do entries[#entries + 1] = e end
    -- Buffs merged into another icon ("Also show for") are not icons of
    -- their own.
    local merged = MergedInto()
    if next(merged) then
        local kept = {}
        for _, e in ipairs(entries) do
            if not merged[e.spellID] then kept[#kept + 1] = e end
        end
        entries = kept
    end
    return entries
end
BH.BuffGridEntries = BuffGridEntries

local BUFF_ICON_SIZE = 30
local BUFF_ICON_GAP  = 4
local BUFF_PER_ROW   = 10

-- One icon in the grid. Three states worth telling apart at a glance:
-- selected, set up (has a sound or an image), and neither. A configured icon
-- keeps an accent border once the selection moves on, or there is no way to
-- see what is already set up without clicking every icon in turn.
local function GridIcon(grid, x, y, info, selected, configured, onClick, tipLines)
    local btn = CreateFrame("Button", nil, grid, "BackdropTemplate")
    btn:SetSize(BUFF_ICON_SIZE, BUFF_ICON_SIZE)
    btn:SetPoint("TOPLEFT", grid, "TOPLEFT", x, y)

    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints()
    icon:SetTexture(info.icon)
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

    ns.ApplySQBackdrop(btn, { 0, 0, 0, 0 }, SQ_COLORS.border)
    if selected then
        local r, g, b = ns.GetAccentColor()
        btn:SetBackdropBorderColor(r, g, b, 1)
    elseif configured then
        local r, g, b = ns.GetAccentColor("dim")
        btn:SetBackdropBorderColor(r, g, b, 0.8)
    else
        btn:SetBackdropBorderColor(SQ_COLORS.border[1], SQ_COLORS.border[2], SQ_COLORS.border[3], 1)
        icon:SetDesaturated(true)
        icon:SetAlpha(0.7)
    end

    btn:SetScript("OnClick", onClick)
    btn:SetScript("OnEnter", function(s)
        GameTooltip:SetOwner(s, "ANCHOR_RIGHT")
        GameTooltip:SetText(BH.Secrets.SafeString(info.name, nil) or ("Spell " .. tostring(info.spellID)))
        GameTooltip:AddLine("Spell ID " .. tostring(info.spellID), 0.7, 0.7, 0.7, false)
        for _, line in ipairs(tipLines) do GameTooltip:AddLine(line, 0.7, 0.7, 0.7, true) end
        if configured then GameTooltip:AddLine("Has a sound or an image.", 0.7, 0.7, 0.7, true) end
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

-- The CDM Alerts grid (2.0): your buffs, then this spec's Essential and
-- Utility cooldowns, in one grid with one selection, so a buff and a cooldown
-- open the same editor (user decision 2026-10-15).
function BH:RebuildBuffSoundGrid()
    local grid = self.kelBuffGrid
    if not grid then return end

    for _, child in ipairs({ grid:GetChildren() }) do
        child:Hide()
        child:SetParent(nil)
    end
    for _, region in ipairs({ grid:GetRegions() }) do
        region:Hide()
        region:SetParent(nil)
    end

    local entries = BuffGridEntries()
    local cds = CooldownGridEntries()

    -- Resolve the cooldown selection against this build; drop any selection
    -- this spec no longer offers, so the editor below never describes a spell
    -- missing from the grid above it.
    selectedCD = nil
    if selectedCDKey then
        for _, list in pairs(cds) do
            for _, cd in ipairs(list) do
                if (cd.spellID or cd.cooldownID) == selectedCDKey then selectedCD = cd end
            end
        end
        if not selectedCD then selectedCDKey = nil end
    end
    if not selectedCD then
        local stillPresent = false
        for _, e in ipairs(entries) do
            if e.spellID == selectedBuffSpellID then stillPresent = true break end
        end
        if not stillPresent then
            selectedBuffSpellID = entries[1] and entries[1].spellID or nil
            if not selectedBuffSpellID then
                local first = cds.cooldown[1] or cds.utility[1]
                if first then selectedCDKey, selectedCD = first.spellID or first.cooldownID, first end
            end
        end
    end

    local y = 0
    local function Section(label, list, draw)
        if #list == 0 then return end
        local hdr = grid:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        hdr:SetPoint("TOPLEFT", grid, "TOPLEFT", 0, y)
        hdr:SetText(label)
        ns.ApplyAccent(hdr, "text")
        y = y - 16
        local rows = 0
        for i, item in ipairs(list) do
            local col = (i - 1) % BUFF_PER_ROW
            local row = math.floor((i - 1) / BUFF_PER_ROW)
            rows = row + 1
            draw(item, col * (BUFF_ICON_SIZE + BUFF_ICON_GAP), y - row * (BUFF_ICON_SIZE + BUFF_ICON_GAP))
        end
        y = y - rows * (BUFF_ICON_SIZE + BUFF_ICON_GAP) - 6
    end

    local store = BH.BuffSounds()
    Section("BUFFS", entries, function(entry, x, iy)
        GridIcon(grid, x, iy, entry, entry.spellID == selectedBuffSpellID, store[entry.spellID] ~= nil,
            function()
                BH.SelectBuffSpell(entry.spellID)
                BH:RebuildBuffSoundGrid()
                BH:RebuildBuffSoundEditor()
            end,
            entry.manual and { "Added by spell ID." } or {})
    end)

    local function DrawCooldown(cd, x, iy)
        local list = BH.cdm and BH.cdm.AlertListFor and BH.cdm.AlertListFor(cd.cooldownID, false)
        GridIcon(grid, x, iy, cd, selectedCD == cd, list ~= nil and #list > 0,
            function()
                BH.SelectCooldown(cd)
                BH:RebuildBuffSoundGrid()
                BH:RebuildBuffSoundEditor()
            end, {})
    end
    Section("ESSENTIAL", cds.cooldown, DrawCooldown)
    Section("UTILITY", cds.utility, DrawCooldown)

    if y == 0 then
        local none = grid:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        none:SetPoint("TOPLEFT", grid, "TOPLEFT", 0, 0)
        none:SetText("No buffs or cooldowns found for this spec.")
        none:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])
        y = -20
    end
    grid:SetHeight(math.abs(y))
end

-- The image controls, shared by every alert that can show an image: Buff
-- Alerts (a buff's entry) and Cooldown Alerts (one alert of a cooldown). One
-- copy, so the two pages cannot drift apart (2.0). The entry is anything
-- PaintImage / PlaceImageFrame understand; `o` says where it lives:
--   entry()        the entry as stored, or nil (read only)
--   edit()         the entry, created if missing (for writing)
--   changed(rb)    save and rebuild the image; rb = rebuild the editor too
--   soon()         rebuild the image soon (drag-continuous controls; the
--                  caller has already saved)
--   rebuild()      rebuild the editor
--   test()         show it for a few seconds
--   state()        optional: "active" | "waiting" | other, shown by Test
--   moving()/move() the Move handle: is it out / toggle it
--   stacks         offer Reveal by Stacks (buffs only); spellID for its max
--   imageTip       the Image dropdown's tooltip
-- Returns the new y.
local function BuildImageControls(editor, y, o)
    local entry = o.entry()
    local spellID = o.spellID
    local Entry, Changed = o.edit, o.changed

    local imgLbl = editor:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    imgLbl:SetPoint("TOPLEFT", editor, "TOPLEFT", 0, y - 4)
    imgLbl:SetWidth(60)
    imgLbl:SetJustifyH("LEFT")
    imgLbl:SetText("Image:")
    imgLbl:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])

    local imgDrop = CreateSQDropdown(editor, "", 200, {
        { text = "None",                      value = "none" },
        { text = "Screen edge glow",          value = "vignette" },
        { text = "Flames: bottom and sides",  value = "flames_u" },
        { text = "Flames: both sides",        value = "flames_sides" },
        { text = "Flames: bottom",            value = "flames_bottom" },
        { text = "Flames: all round",         value = "flames_ring" },
        { text = "Flames: ( ) arcs",          value = "flames_arcs" },
        { text = "Lightning: ( ) arcs",       value = "lightning_arcs" },
        { text = "Frost: ( ) arcs",           value = "frost_arcs" },
        { text = "Heartbeat",                 value = "heartbeat" },
        { text = "Arcane orbit",              value = "arcane_orbit" },
        { text = "Angel wings (still)",       value = "angel_wings" },
        { text = "Shield bubble (still)",     value = "shield_bubble" },
        { text = "Sunburst (still)",          value = "sunburst" },
        { text = "Rune circle (still)",       value = "rune_circle" },
        { text = "Your own texture",          value = "custom" },
    }, function(val)
        local e = Entry()
        local before = BUNDLED_IMAGES[e.image or ""]
        e.image = (val ~= "none") and val or nil
        -- These frame something, so they start placed (centre of the screen,
        -- where a third-person character usually stands) -- the first time
        -- only: a later re-pick keeps the player's placement. The Height %
        -- follows the shape (the ( ) arcs taller than wide, the rest square)
        -- when coming from a different one, since a heart at the arcs' 150%
        -- is just a squashed heart; re-picking the same one keeps it.
        local b = BUNDLED_IMAGES[val]
        if b and b.placed then
            if e.imageFill == nil then
                e.imageFill = false
                e.imageSize = e.imageSize or 260
            end
            if before ~= b then e.imageHeight = b.height or 100 end
        end
        Changed(true)
    end)
    imgDrop:SetPoint("TOPLEFT", editor, "TOPLEFT", 64, y)
    imgDrop:SetSelectedValue((entry and entry.image) or "none")
    ns.Rows.AddTooltip(imgDrop, "Image", o.imageTip)

    if entry and entry.image then
        local test = CreateSQButton(editor, "Test", 46, 22)
        test:SetPoint("LEFT", imgDrop.btn, "RIGHT", 6, 0)
        test:SetScript("OnClick", function() o.test() end)
        ns.Rows.AddTooltip(test, "Test", "Show the image for a few seconds, as it will look.")

        -- Buff images are built ahead of time by the aura engine, so whether
        -- that happened is worth showing. Cooldown images are drawn on the
        -- spot and have no such state.
        if o.state then
            local state = editor:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            state:SetPoint("LEFT", test, "RIGHT", 6, 0)
            local st = o.state()
            if st == "active" then
                state:SetText("active")
                state:SetTextColor(0.4, 0.8, 0.4)
            elseif st == "waiting" then
                state:SetText("after combat")
                state:SetTextColor(1, 0.8, 0.3)
            else
                state:SetText("not built")
                state:SetTextColor(SQ_COLORS.danger[1], SQ_COLORS.danger[2], SQ_COLORS.danger[3])
            end
        end
    end
    y = y - 30

    -- Controls only one kind of alert has, straight under the Image row
    -- (Cooldown Alerts' "Show for").
    if entry and entry.image and o.afterImage then y = o.afterImage(editor, y) end

    if entry and entry.image then
        if entry.image == "custom" then
            local texLbl = editor:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            texLbl:SetPoint("TOPLEFT", editor, "TOPLEFT", 0, y - 4)
            texLbl:SetText("Texture:")
            texLbl:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])
            local texEdit = CreateSQEditBox(editor, 200, 20, { maxLetters = 200 })
            texEdit:SetPoint("TOPLEFT", editor, "TOPLEFT", 64, y)
            texEdit:SetText(entry.imageTexture or "")
            local function SaveTex(box)
                Entry().imageTexture = strtrim(box:GetText() or "")
                Changed(false)
            end
            texEdit:SetScript("OnEnterPressed", function(box) box:ClearFocus(); SaveTex(box) end)
            texEdit.onFocusLost = SaveTex
            ns.Rows.AddTooltip(texEdit, "Texture",
                "A game atlas name (for example \"bags-glow-flash\"), a texture path, or the name of an image "
                .. "file in Squizzumables' Media folder. Press Enter to apply. Empty uses the screen edge glow.")
            y = y - 28

            -- Flipbook: the texture is a sheet of frames in a grid, played by
            -- the game. A numbered sequence (name_001.png ...) can be packed
            -- into one with .claude/make-flipbook.ps1, which prints the values
            -- to enter here.
            local function NumBox(label, key, default, x, width, tip)
                local l = editor:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                l:SetPoint("TOPLEFT", editor, "TOPLEFT", x, y - 4)
                l:SetText(label)
                l:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])
                local box = CreateSQEditBox(editor, width, 20, { numeric = true, justifyH = "CENTER", maxLetters = 4 })
                box:SetPoint("LEFT", l, "RIGHT", 4, 0)
                box:SetText(tostring(entry[key] or default))
                local function Save(b)
                    Entry()[key] = tonumber(b:GetText()) or default
                    Changed(false)
                end
                box:SetScript("OnEnterPressed", function(b) b:ClearFocus(); Save(b) end)
                box.onFocusLost = Save
                ns.Rows.AddTooltip(box, label, tip)
            end
            NumBox("Frames", "imageFrames", 1, 0, 30,
                "How many frames the sheet holds. 1 is a still image; more makes it a flipbook animation.")
            NumBox("Cols", "imageCols", 1, 86, 26, "How many frames across the sheet.")
            NumBox("Rows", "imageRows", 1, 158, 26, "How many frames down the sheet.")
            NumBox("FPS", "imageFps", 12, 232, 26, "Frames per second.")
            y = y - 26
            NumBox("Frame W", "imageFrameW", 0, 0, 36,
                "Width of one frame in the sheet, in pixels. 0 works it out for a game atlas; give it for your own file.")
            NumBox("H", "imageFrameH", 0, 98, 36, "Height of one frame in the sheet, in pixels.")
            local loopCb = CreateSQCheckbox(editor, "Loop", function(checked)
                Entry().imageLoop = checked
                Changed(false)
            end)
            loopCb:SetPoint("TOPLEFT", editor, "TOPLEFT", 190, y + 2)
            loopCb:SetChecked(entry.imageLoop ~= false)
            ns.Rows.AddTooltip(loopCb, "Loop", "Repeat the animation for as long as the image is up, instead of playing it once.")
            y = y - 30
        end

        local c = entry.imageColor or {}
        local picker = ns.CreateSQColorPicker(editor, "Colour", c.r or 1, c.g or 1, c.b or 1, 1,
            function(r, g, b)
                Entry().imageColor = { r = r, g = g, b = b }
                BH:SaveSettings()
                o.soon()
            end)
        picker:SetPoint("TOPLEFT", editor, "TOPLEFT", 0, y)
        ns.Rows.AddTooltip(picker, "Colour", "Tint for the image. The screen edge glow is white, so this is its colour.")

        local fillCb = CreateSQCheckbox(editor, "Fill the screen", function(checked)
            Entry().imageFill = checked
            if checked and o.moving() then o.move() end
            Changed(true)
        end)
        fillCb:SetPoint("TOPLEFT", editor, "TOPLEFT", 190, y)
        fillCb:SetChecked(entry.imageFill ~= false)
        ns.Rows.AddTooltip(fillCb, "Fill the screen",
            "Stretch the image over the whole screen, behind your interface -- right for an edge glow. Unticked, "
            .. "it is a square with its own position and size; place it with Move. Either way it stays behind "
            .. "your interface windows.")
        y = y - 30

        local alpha = CreateSQSlider(editor, "Opacity %", 200, 5, 100, 5)
        alpha:SetValue(math.floor((entry.imageAlpha or 0.8) * 100 + 0.5))
        alpha:SetAfterValueChanged(function(v)
            Entry().imageAlpha = v / 100
            BH:SaveSettings()
            o.soon()
        end)
        alpha:SetPoint("TOPLEFT", editor, "TOPLEFT", 0, y)
        y = y - 46

        if o.stacks then
            local stacks = CreateSQSlider(editor, "Reveal by Stacks", 200, 0, 10, 1)
            stacks:SetValue(tonumber(entry.imageStacks) or 0)
            stacks:SetAfterValueChanged(function(v)
                local e = Entry()
                local wasOn = (tonumber(e.imageStacks) or 0) > 0
                e.imageStacks = v > 0 and v or nil
                BH:SaveSettings()
                o.soon()
                -- The direction control only exists while this is on.
                if wasOn ~= (v > 0) then o.rebuild() end
            end)
            stacks:SetPoint("TOPLEFT", editor, "TOPLEFT", 0, y)

            -- How far this buff stacks, from the game: the highest
            -- GetSpellMaxCumulativeAuraApplications over every aura ID the icon
            -- matches (the grid ID can be the TALENT -- Infusion of Light 53576 --
            -- while the stacking lives on the buff, 54149). Secret while aura data
            -- is restricted, i.e. in combat; the editor is used out of it.
            -- Returns 0 for many stacking buffs: Infusion of Light (all three IDs) and
            -- Divine Purpose read 0 in game, 2026-10-06 -- their stacks come from
            -- talents. 0 shows nothing rather than a misleading "Does not stack".
            local maxStacks = 0
            if C_Spell.GetSpellMaxCumulativeAuraApplications then
                for auraID in pairs(AuraIDsFor(spellID)) do
                    local ok, n = pcall(C_Spell.GetSpellMaxCumulativeAuraApplications, auraID)
                    n = ok and BH.Secrets.SafeNumber(n, 0) or 0
                    if n > maxStacks then maxStacks = n end
                end
            end
            local maxLbl = editor:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            maxLbl:SetPoint("TOPLEFT", stacks, "TOPRIGHT", 12, -14)
            maxLbl:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])
            if maxStacks > 1 then
                maxLbl:SetText(("Stacks to %d"):format(maxStacks))
                local match = CreateSQButton(editor, "Match", 54, 20)
                match:SetPoint("LEFT", maxLbl, "RIGHT", 6, 0)
                match:SetScript("OnClick", function()
                    Entry().imageStacks = math.min(maxStacks, 10)
                    BH:SaveSettings()
                    o.changed(false)
                    o.rebuild()
                end)
                ns.Rows.AddTooltip(match, "Match", "Set Reveal by Stacks to this buff's most stacks, so the image is "
                    .. "whole at full stacks.")
            else
                maxLbl:SetText(maxStacks == 1 and "Does not stack" or "")
            end
            ns.Rows.AddTooltip(stacks, "Reveal by Stacks",
                "For a buff that stacks: uncover the image a piece at a time as the stacks build, whole at this many "
                .. "stacks. 2 with the ( ) arcs shows the left arc at 1 stack and both at 2. 0 shows the whole image "
                .. "whenever the buff is up. A buff that does not stack shows nothing with this on. Test shows the "
                .. "whole image.")
            y = y - 46

            if (tonumber(entry.imageStacks) or 0) > 0 then
                local dirLbl = editor:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                dirLbl:SetPoint("TOPLEFT", editor, "TOPLEFT", 0, y - 4)
                dirLbl:SetText("Reveal:")
                dirLbl:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])
                local dirDrop = CreateSQDropdown(editor, "", 160, {
                    { text = "Left to right", value = "right" },
                    { text = "Bottom to top", value = "up" },
                }, function(val)
                    Entry().imageReveal = val
                    BH:SaveSettings()
                    o.changed(false)
                end)
                dirDrop:SetPoint("TOPLEFT", editor, "TOPLEFT", 64, y)
                dirDrop:SetSelectedValue(entry.imageReveal or "right")
                y = y - 30
            end
        end

        if entry.imageFill == false then
            local size = CreateSQSlider(editor, "Size", 200, 50, 800, 10)
            size:SetValue(entry.imageSize or 200)
            size:SetAfterValueChanged(function(v)
                Entry().imageSize = v
                BH:SaveSettings()
                o.soon()
                -- Resize the Move handle too, if it is out.
                RefitMoveHandle()
            end)
            size:SetPoint("TOPLEFT", editor, "TOPLEFT", 0, y)
            ns.Rows.AddTooltip(size, "Size", "Width of the image, in pixels.")
            y = y - 46

            local height = CreateSQSlider(editor, "Height %", 200, 25, 300, 5)
            height:SetValue(entry.imageHeight or 100)
            height:SetAfterValueChanged(function(v)
                Entry().imageHeight = v
                BH:SaveSettings()
                o.soon()
                RefitMoveHandle()
            end)
            height:SetPoint("TOPLEFT", editor, "TOPLEFT", 0, y)
            ns.Rows.AddTooltip(height, "Height %",
                "Height as a percentage of the width: 100 is square, higher is taller. The ( ) arcs frame a "
                .. "character best somewhere around 150.")
            y = y - 46

            local bundled = BUNDLED_IMAGES[entry.image]
            if bundled and bundled.levels then
                local thick = CreateSQSlider(editor, "Flame Thickness", 200, 1, #bundled.levels, 1)
                thick:SetValue(tonumber(entry.imageThickness) or 3)
                thick:SetAfterValueChanged(function(v)
                    Entry().imageThickness = v
                    BH:SaveSettings()
                    o.soon()
                    if o.moving() and previewFrame then
                        RefitMoveHandle()
                        PaintImage(previewFrame.tex, Entry())
                    end
                end)
                thick:SetPoint("TOPLEFT", editor, "TOPLEFT", 0, y)
                ns.Rows.AddTooltip(thick, "Flame Thickness",
                    "How thick the fire is, from 1 (a thin line of flame) to 5. The arcs stay where you placed "
                    .. "them; only the flames grow or shrink. Press Test to see it.")
                y = y - 46
            end

            local move = CreateSQButton(editor, o.moving() and "Done" or "Move", 70, 22)
            move:SetPoint("TOPLEFT", editor, "TOPLEFT", 0, y)
            move:SetScript("OnClick", function()
                o.move()
                o.rebuild()
            end)
            ns.Rows.AddTooltip(move, "Move",
                "Show this image as a box you can drag into place, then click Done. Each image has its own "
                .. "position, separate from the others and from the lust alert.")

            local centre = CreateSQButton(editor, "Centre", 70, 22)
            centre:SetPoint("LEFT", move, "RIGHT", 6, 0)
            centre:SetScript("OnClick", function()
                local e = Entry()
                e.imageX, e.imageY = 0, 0
                BH:SaveSettings()
                o.changed(false)
                -- Snap the Move handle along with it, if it is out.
                RefitMoveHandle()
            end)
            ns.Rows.AddTooltip(centre, "Centre",
                "Put the image back in the middle of the screen -- where your character stands in third person, "
                .. "so a good start before nudging it with Move.")
            y = y - 30
        end
    end
    return y
end
BH.BuildImageControls = BuildImageControls

-- ============================================================================
-- The cooldown half of CDM Alerts (2.0)
--
-- Laid out like the buff editor on purpose (user decision 2026-10-15: one tab,
-- click a buff or a cooldown, same options): a sound row per event, then the
-- same image controls. A cooldown's events are Ready and On cooldown (what
-- Blizzard's GetValidAlertTypes offers for it). The data stays where cooldown
-- alerts always lived -- a per-spec list of { type, when, sound } entries,
-- BH.cdm.AlertListFor -- and the image rides on the entry of the event it is
-- shown on ("Show on"), so PlayAlertsFor fires sound and image together.
-- ============================================================================
local CD_WHENS = { "available", "start" }
local CD_WHEN_LABEL = { available = "Ready:", start = "On cooldown:" }
local CD_WHEN_NAME  = { available = "Ready", start = "On cooldown" }

-- The events this cooldown can raise, in display order.
local function CooldownWhens(cd)
    local allowed, any = {}, false
    local ids = { cd.cooldownID }
    for _, s in ipairs(cd.siblings or {}) do ids[#ids + 1] = s end
    local map = (BH.cdm and BH.cdm.AlertEventToWhen) or {}
    for _, id in ipairs(ids) do
        local types = C_CooldownViewer and C_CooldownViewer.GetValidAlertTypes
            and C_CooldownViewer.GetValidAlertTypes(id)
        if types and #types > 0 then
            any = true
            for _, ev in ipairs(types) do
                local w = map[ev]
                if w then allowed[w] = true end
            end
        end
    end
    if not any then allowed.available, allowed.start = true, true end
    local out = {}
    for _, w in ipairs(CD_WHENS) do if allowed[w] then out[#out + 1] = w end end
    return out
end

local function CooldownAlert(cd, when, create)
    local list = BH.cdm.AlertListFor(cd.cooldownID, create)
    if not list then return nil end
    for _, a in ipairs(list) do
        if a.when == when then return a end
    end
    if create then
        local a = { type = "Sound", when = when, sound = "None" }
        list[#list + 1] = a
        return a
    end
end

-- The entry carrying this cooldown's image, if any.
local function CooldownImageAlert(cd)
    local list = BH.cdm.AlertListFor(cd.cooldownID, false)
    for _, a in ipairs(list or {}) do
        if a.image then return a end
    end
end

-- Drop entries left with neither a sound nor an image, and an emptied list.
local function PruneCooldownAlerts(cd)
    local list, store, key = BH.cdm.AlertListFor(cd.cooldownID, false)
    if not list then return end
    for i = #list, 1, -1 do
        local a = list[i]
        if (not a.sound or a.sound == "None") and not a.image then table.remove(list, i) end
    end
    if #list == 0 then store[key] = nil end
end

-- Move every image field from one entry to another ("Show on" changed).
local function MoveImageFields(from, to)
    for k, v in pairs(from) do
        if type(k) == "string" and k:sub(1, 5) == "image" then
            to[k] = v
            from[k] = nil
        end
    end
end

local function BuildCooldownEditor(editor, cd)
    local y = 0
    local name = BH.Secrets.SafeString(cd.name, nil) or ("Spell " .. tostring(cd.spellID))

    local title = editor:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", editor, "TOPLEFT", 0, y)
    title:SetText(name .. "  (" .. tostring(cd.spellID or cd.cooldownID) .. ")")
    ns.ApplyAccent(title, "text")
    y = y - 22

    local whens = CooldownWhens(cd)
    local function Refresh()
        PruneCooldownAlerts(cd)
        BH:RebuildBuffSoundGrid()
        BH:RebuildBuffSoundEditor()
    end

    -- One sound row per event, like the buff's Applied / Removed rows.
    for _, when in ipairs(whens) do
        local lbl = editor:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        lbl:SetPoint("TOPLEFT", editor, "TOPLEFT", 0, y - 4)
        lbl:SetWidth(76)
        lbl:SetJustifyH("LEFT")
        lbl:SetText(CD_WHEN_LABEL[when])
        lbl:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])

        local drop = CreateSQDropdown(editor, "", 184, BH:BuildSoundDropdownItems(), function(val)
            CooldownAlert(cd, when, true).sound = val
            Refresh()
        end)
        drop:SetPoint("TOPLEFT", editor, "TOPLEFT", 80, y)
        local a = CooldownAlert(cd, when, false)
        drop:SetSelectedValue((a and a.sound) or "None")
        ns.Rows.AddTooltip(drop, CD_WHEN_NAME[when],
            when == "available"
                and "Played when this ability comes off cooldown and is ready to use."
                or "Played when this ability goes on cooldown.")

        local test = CreateSQButton(editor, "Test", 46, 22)
        test:SetPoint("LEFT", drop.btn, "RIGHT", 6, 0)
        test:SetScript("OnClick", function()
            local cur = CooldownAlert(cd, when, false)
            if cur and cur.sound and cur.sound ~= "None" then BH:PlaySound(cur.sound) end
        end)
        y = y - 28
    end

    local list = BH.cdm.AlertListFor(cd.cooldownID, false)
    if list and #list > 0 then
        local rm = CreateSQButton(editor, "Remove", 68, 22, SQ_COLORS.danger)
        rm:SetPoint("TOPLEFT", editor, "TOPLEFT", 80, y)
        rm:SetScript("OnClick", function()
            local _, store, key = BH.cdm.AlertListFor(cd.cooldownID, false)
            if store then store[key] = nil end
            BH.StopMovingImage()
            BH:RebuildBuffSoundGrid()
            BH:RebuildBuffSoundEditor()
        end)
        ns.Rows.AddTooltip(rm, "Remove", "Clear this cooldown's sounds and image.")
        y = y - 30
    else
        y = y - 2
    end

    -- ── IMAGE ─────────────────────────────────────────────────────────────
    local moveKey = CooldownMoveKey(cd)
    local held = CooldownImageAlert(cd)
    local showOn = (held and held.when) or whens[1] or "available"
    local function Get() return CooldownImageAlert(cd) end
    local function Edit() return CooldownImageAlert(cd) or CooldownAlert(cd, showOn, true) end

    y = BuildImageControls(editor, y, {
        entry   = Get,
        edit    = Edit,
        -- Cooldown alerts live in SquizzumablesDB.cdmData and are drawn on the
        -- spot when they fire, so there is nothing to rebuild but the page.
        changed = function(rebuildEditor)
            PruneCooldownAlerts(cd)
            BH:RebuildBuffSoundGrid()
            if rebuildEditor then BH:RebuildBuffSoundEditor() end
        end,
        soon    = function() end,
        rebuild = function() BH:RebuildBuffSoundEditor() end,
        test    = function() BH:PreviewImage(Get()) end,
        moving  = function() return BH.MovingImage(moveKey) end,
        move    = function() BH:MoveImage(moveKey, Get) end,
        afterImage = function(ed, iy)
            if #whens > 1 then
                local onLbl = ed:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                onLbl:SetPoint("TOPLEFT", ed, "TOPLEFT", 0, iy - 4)
                onLbl:SetText("Show on:")
                onLbl:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])
                local items = {}
                for _, w in ipairs(whens) do items[#items + 1] = { text = CD_WHEN_NAME[w], value = w } end
                local onDrop = CreateSQDropdown(ed, "", 200, items, function(val)
                    local from = CooldownImageAlert(cd)
                    if from and from.when ~= val then
                        MoveImageFields(from, CooldownAlert(cd, val, true))
                        PruneCooldownAlerts(cd)
                        BH:RebuildBuffSoundEditor()
                    end
                end)
                onDrop:SetPoint("TOPLEFT", ed, "TOPLEFT", 64, iy)
                onDrop:SetSelectedValue(showOn)
                ns.Rows.AddTooltip(onDrop, "Show on",
                    "Which moment brings the image up: the ability becoming ready, or going on cooldown.")
                iy = iy - 30
            end

            local forLbl = ed:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            forLbl:SetPoint("TOPLEFT", ed, "TOPLEFT", 0, iy - 4)
            forLbl:SetText("Show for:")
            forLbl:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])
            local forDrop = CreateSQDropdown(ed, "", 200, {
                { text = "1 second",             value = 1 },
                { text = "2 seconds",            value = 2 },
                { text = "3 seconds",            value = 3 },
                { text = "5 seconds",            value = 5 },
                { text = "10 seconds",           value = 10 },
                { text = "Until the next event", value = "next" },
            }, function(val)
                local e = Get()
                if e then e.imageShowFor = val end
            end)
            forDrop:SetPoint("TOPLEFT", ed, "TOPLEFT", 64, iy)
            forDrop:SetSelectedValue((held and held.imageShowFor) or 2)
            ns.Rows.AddTooltip(forDrop, "Show for",
                "How long the image stays up. Until the next event keeps it until this spell does something "
                .. "else: a Ready image stays until you use the spell, an On cooldown image until it is ready "
                .. "again. It fades out either way.")
            return iy - 30
        end,
        imageTip = "An image on screen when this ability becomes ready or goes on cooldown, in combat too: "
            .. "the Cooldown Manager tells Squizzumables the moment it happens. Screen edge glow is a coloured "
            .. "vignette round the edge of the screen; the Flames are animated fire along the edges you pick. "
            .. "The ( ) arcs and the shapes below them are placed rather than full screen: size and move them "
            .. "to frame your character. Those marked (still) do not animate.",
    })
    return y
end

-- Size the editor and the page around it. The grid above can grow (more
-- cooldowns, another spec), so the page height is measured from the grid's
-- real bottom rather than fixed when the tab was built.
local function FinishEditor(self, editor, y)
    editor:SetHeight(math.abs(y) + 4)
    if self.kelBuffPage and self.kelBuffGridTop and self.kelBuffGrid then
        self.kelBuffPage:SetHeight(self.kelBuffGridTop + self.kelBuffGrid:GetHeight() + 40
            + editor:GetHeight() + 32)
    end
end

function BH:RebuildBuffSoundEditor()
    local editor = self.kelBuffEditor
    if not editor then return end

    for _, child in ipairs({ editor:GetChildren() }) do
        child:Hide()
        child:SetParent(nil)
    end
    for _, region in ipairs({ editor:GetRegions() }) do
        region:Hide()
        region:SetParent(nil)
    end

    -- A cooldown picked in the grid: the same layout, its own events.
    if selectedCD and BH.cdm and BH.cdm.AlertListFor then
        FinishEditor(self, editor, BuildCooldownEditor(editor, selectedCD))
        return
    end

    local spellID = selectedBuffSpellID
    if not spellID then editor:SetHeight(1) return end

    local store = BH.BuffSounds()
    local entry = store[spellID]
    local name  = C_Spell.GetSpellName(spellID) or ("Spell " .. spellID)
    local y     = 0

    local title = editor:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", editor, "TOPLEFT", 0, y)
    title:SetText(tostring(BH.Secrets.SafeString(name, "?")) .. "  (" .. spellID .. ")")
    ns.ApplyAccent(title, "text")
    y = y - 22

    -- Two triggers, one row each. Choosing "None" clears that half rather than
    -- needing its own delete; the Remove button clears the spell outright.
    local function SoundRow(label, field, tooltip)
        local lbl = editor:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        lbl:SetPoint("TOPLEFT", editor, "TOPLEFT", 0, y - 4)
        lbl:SetWidth(60)
        lbl:SetJustifyH("LEFT")
        lbl:SetText(label)
        lbl:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])

        local drop = CreateSQDropdown(editor, "", 200, BH:BuildSoundDropdownItems(), function(val)
            local s = BH.BuffSounds()
            s[spellID] = s[spellID] or { channel = "Master" }
            s[spellID][field] = (val ~= "None") and val or nil
            BH:SaveSettings()
            BH:RefreshAuraSoundRegistrations("sound changed")
            BH:RebuildBuffSoundGrid()
            BH:RebuildBuffSoundEditor()
        end)
        drop:SetPoint("TOPLEFT", editor, "TOPLEFT", 64, y)
        drop:SetSelectedValue((entry and entry[field]) or "None")
        ns.Rows.AddTooltip(drop, label, tooltip)

        local test = CreateSQButton(editor, "Test", 46, 22)
        test:SetPoint("LEFT", drop.btn, "RIGHT", 6, 0)
        test:SetScript("OnClick", function()
            local e = BH.BuffSounds()[spellID]
            BH:PlaySound(e and e[field] or "None", (e and e.channel) or "Master")
        end)

        -- Whether the client took the registration. A refusal is otherwise
        -- indistinguishable from a sound that simply has not fired yet.
        if entry and entry[field] then
            local state = editor:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            state:SetPoint("LEFT", test, "RIGHT", 6, 0)
            if BH.BuffSoundRegistered(spellID, field) then
                state:SetText("active")
                state:SetTextColor(0.4, 0.8, 0.4)
            else
                state:SetText("not registered")
                state:SetTextColor(SQ_COLORS.danger[1], SQ_COLORS.danger[2], SQ_COLORS.danger[3])
            end
        end
        y = y - 28
    end

    SoundRow("Applied:", "added",
        "Played when this buff lands on you. The game plays it, which is why it still works in combat.")
    SoundRow("Removed:", "removed",
        "Played when this buff drops off you. Also played by the game, which is the only reliable way to know an aura has ended.")

    local chanLbl = editor:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    chanLbl:SetPoint("TOPLEFT", editor, "TOPLEFT", 0, y - 4)
    chanLbl:SetText("Channel:")
    chanLbl:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])

    local chanDrop = CreateSQDropdown(editor, "", 130, {
        { text = "Master",   value = "Master"   },
        { text = "SFX",      value = "SFX"      },
        { text = "Music",    value = "Music"    },
        { text = "Ambience", value = "Ambience" },
        { text = "Dialog",   value = "Dialog"   },
    }, function(val)
        local s = BH.BuffSounds()
        s[spellID] = s[spellID] or {}
        s[spellID].channel = val
        BH:SaveSettings()
        BH:RefreshAuraSoundRegistrations("channel changed")
    end)
    chanDrop:SetPoint("TOPLEFT", editor, "TOPLEFT", 64, y)
    chanDrop:SetSelectedValue((entry and entry.channel) or "Master")
    ns.Rows.AddTooltip(chanDrop, "Sound channel",
        "Which audio channel these play on. Master ignores your in-game sound sliders.")

    if entry then
        local rm = CreateSQButton(editor, "Remove", 68, 22, SQ_COLORS.danger)
        rm:SetPoint("LEFT", chanDrop.btn, "RIGHT", 8, 0)
        rm:SetScript("OnClick", function()
            BH.BuffSounds()[spellID] = nil
            BH:SaveSettings()
            BH:RefreshAuraSoundRegistrations("buff sound removed")
            BH:RebuildBuffSoundGrid()
            BH:RebuildBuffSoundEditor()
        end)
        ns.Rows.AddTooltip(rm, "Remove", "Clear this spell's sounds and image.")
    end
    y = y - 30

    -- ── IMAGE ─────────────────────────────────────────────────────────────
    -- Shown while the buff is up, by the game's aura engine, so it works in
    -- combat (see "Buff images" above).
    local function Entry()
        local s = BH.BuffSounds()
        s[spellID] = s[spellID] or { channel = "Master" }
        return s[spellID]
    end
    local function Changed(rebuildEditor)
        BH:SaveSettings()
        BH:RefreshBuffImages()
        BH:RebuildBuffSoundGrid()
        if rebuildEditor then BH:RebuildBuffSoundEditor() end
    end

    -- "Also show for": other buffs with this one's NAME, each a tick box that
    -- folds it into this icon (see MergedInto). Only same-name buffs are
    -- offered: that is the case the game cannot group for us, and offering
    -- every buff would be a list of dozens.
    do
        local myName = BH.Secrets.SafeString(C_Spell.GetSpellName(spellID), nil)
        local mergedMap = MergedInto()
        local own = (BH.BuffSounds()[spellID] or {}).mergedIDs or {}
        local candidates = {}
        if myName then
            local listed = {}
            for _, e in ipairs(BuffGridEntries()) do listed[e.spellID] = true end
            for m in pairs(own) do listed[tonumber(m)] = true end
            for id in pairs(listed) do
                if id ~= spellID and (mergedMap[id] == nil or mergedMap[id] == spellID)
                   and BH.Secrets.SafeString(C_Spell.GetSpellName(id), nil) == myName then
                    candidates[#candidates + 1] = id
                end
            end
            table.sort(candidates)
        end
        if #candidates > 0 then
            local lbl = editor:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            lbl:SetPoint("TOPLEFT", editor, "TOPLEFT", 0, y - 4)
            lbl:SetText("Also show for:")
            lbl:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])
            ns.Rows.AddTooltip(lbl, "Also show for",
                "Other buffs with the same name. Tick one to make this icon answer for it too -- its image and "
                .. "sounds, and hiding Blizzard's art -- and it leaves the list. Whatever it had set up of its own "
                .. "is replaced by this icon's. Untick to make it its own icon again.")
            local x = 84
            for _, id in ipairs(candidates) do
                local cb = CreateSQCheckbox(editor, tostring(id), function(checked)
                    local e = Entry()
                    e.mergedIDs = type(e.mergedIDs) == "table" and e.mergedIDs or {}
                    if checked then
                        e.mergedIDs[id] = true
                        -- Its own settings would fight this icon's: one image
                        -- for the group, not two drawn on top of each other.
                        BH.BuffSounds()[id] = nil
                    else
                        e.mergedIDs[id] = nil
                        if not next(e.mergedIDs) then e.mergedIDs = nil end
                    end
                    BH:SaveSettings()
                    BH:RefreshAuraSoundRegistrations("buffs merged")
                    BH:RebuildBuffSoundGrid()
                    BH:RebuildBuffSoundEditor()
                end)
                cb:SetPoint("TOPLEFT", editor, "TOPLEFT", x, y)
                cb:SetChecked(own[id] == true)
                ns.Rows.AddTooltip(cb, ("Spell %d"):format(id),
                    "Tick to have this icon's image and sounds show for this buff too.")
                x = x + 96
                if x > 300 then x = 84; y = y - 24 end
            end
            y = y - 30
        end
    end

    y = BuildImageControls(editor, y, {
        spellID  = spellID,
        stacks   = true,
        entry    = function() return BH.BuffSounds()[spellID] end,
        edit     = Entry,
        changed  = Changed,
        soon     = function() BH:RefreshBuffImagesSoon() end,
        rebuild  = function() BH:RebuildBuffSoundEditor() end,
        test     = function() BH:PreviewBuffImage(spellID) end,
        state    = function() return BH.BuffImageState(spellID) end,
        moving   = function() return BH.MovingBuffImage(spellID) end,
        move     = function() BH:MoveBuffImage(spellID) end,
        imageTip = "An image on screen for exactly as long as this buff is up, in combat too -- the game's aura engine "
            .. "shows and hides it. Each buff can have its own. Screen edge glow is a coloured vignette round the "
            .. "edge of the screen; the Flames are animated fire along the edges you pick (leave the colour white "
            .. "for natural fire, or tint them). The ( ) arcs and the shapes below them are placed rather than "
            .. "full screen: size and move them to frame your character. Those marked (still) do not animate.",
    })

    FinishEditor(self, editor, y)
end

-- Previous trigger state, per alert id, for edge detection.
local alertWasActive = {}

-- Returns a writable randomSounds table for the alert being edited, creating
-- one if missing. Existing profiles that predate this feature get the default
-- settings' (shared) empty table filled in by the generic deep-merge in
-- LoadSettings — writing into that shared table directly would corrupt the
-- default for every other profile and every other alert, so swap in a fresh
-- table on first write.
local function GetOrCreateRandomSoundsTable()
    local alert = CurrentAlert()
    local rs = alert.randomSounds
    if type(rs) ~= "table" or rs == BH.defaultSettings.alerts.lust.randomSounds then
        rs = {}
        alert.randomSounds = rs
    end
    return rs
end


-- Edge-detect the image alerts.
--
-- Only built-ins reach here now. A user-made alert on an arbitrary aura used to
-- run through this too, and could not work: the trigger reads the aura, and the
-- client hides nearly every aura in combat. Those became buff sounds, which the
-- client plays without us reading anything. What is left is the lust alert,
-- watchable the old way because its debuffs stay readable -- and therefore the
-- only alert that can still carry an image.
function BH:CheckKelAlerts(unit)
    if unit ~= "player" then return end
    if not self.settings then return end

    for id, alert in pairs(AllAlerts()) do
        if type(alert) == "table" and alert.enabled ~= false then
            local now = TriggerActive(alert)
            if now and not alertWasActive[id] and not BH.playerZoning then
                -- Only for a freshly applied aura -- see TriggerAge. nil means
                -- the age is unknowable, and fires as it always did.
                local age = TriggerAge(alert)
                if age == nil or age <= FRESH_TRIGGER_WINDOW then
                    ShowAlert(alert)
                end
            end
            alertWasActive[id] = now
        else
            -- A disabled alert resets. Switching one on while its trigger is
            -- already up used to fire it straight away; with the freshness
            -- check it only does so if that aura is new. The Test button is
            -- the way to check an alert is wired up.
            alertWasActive[id] = false
        end
    end
end

-- For Alerts/KelTab.lua.
A.GetOrCreateRandomSoundsTable = GetOrCreateRandomSoundsTable
