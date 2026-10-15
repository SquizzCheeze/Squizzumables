-- Cooldowns/TextAndShapes.lua
-- Text placement (the nine positions the keybind, charge count and cooldown
-- countdown share), the group bar background, and icon shapes: masking our
-- proxies (ApplyIconShape) and Blizzard's borrowed buff frames
-- (ApplyShapeToBorrowedChild / UnshapeAllBorrowed).
--
-- Moved out of Squizzumables_CDM.lua unchanged in 2.0 phase 2 (the split).
-- That file still calls these at runtime, so it keeps a forwarder for each
-- and this file fills in the table they forward to (cdmModule.textAndShapes,
-- bottom of this file). Nothing calls into this file while loading.

local addonName, ns = ...
local BH = ns.BH

local cdmModule = BH.cdm
local shared    = cdmModule.shared

local DEFAULT_ICON_ZOOM = shared.DEFAULT_ICON_ZOOM

-- Borrowed frames currently masked to a group's icon shape, so they can be put
-- back square when we let go of them. WEAK KEYS: Blizzard pools these item
-- frames and we must never be the reason one stays alive.
local shapedBorrowed = setmetatable({}, { __mode = "k" })

-- Assigned below (they were forward-declared in Squizzumables_CDM.lua).
local ApplyBarBackground
local ApplyShapeToBorrowedChild

-- ============================================================================
-- Text placement, shared by the keybind, the charge count and the cooldown
-- countdown so all three offer the same nine positions and the same offsets.
-- ============================================================================

-- Moved to UI/Widgets.lua when the co-tank tracker wanted the same nine
-- positions. One list rather than two that can drift apart.
local TEXT_POSITION_ITEMS = ns.TEXT_POSITION_ITEMS

-- A backdrop behind the whole group, distinct from the per-icon background.
--
-- Sized to the container plus padding, so it grows and shrinks with the row --
-- including as a Hide Until Active group packs down.
ApplyBarBackground = function(group, groupData)
    if not group or not group.container then return end
    local on = groupData.barBgEnabled and true or false
    if not on then
        if group.barBg then group.barBg:Hide() end
        return
    end
    if not group.barBg then
        local t = group.container:CreateTexture(nil, "BACKGROUND", nil, -1)
        group.barBg = t
    end
    local c = groupData.barBgColor or { 0, 0, 0, 0.4 }
    local pad = groupData.barBgPadding or 2
    group.barBg:ClearAllPoints()
    group.barBg:SetPoint("TOPLEFT", group.container, "TOPLEFT", -pad, pad)
    group.barBg:SetPoint("BOTTOMRIGHT", group.container, "BOTTOMRIGHT", pad, -pad)
    group.barBg:SetColorTexture(c[1], c[2], c[3], c[4])
    group.barBg:Show()
end

-- Anchor point to itself, so a corner tucks into that corner and the offsets
-- read the same way whichever corner is chosen.
local PlaceText = ns.PlaceText

-- Blizzard's countdown numbers live on a font string the C widget creates, with
-- no accessor for it, so it has to be found among the regions. Cached per
-- widget; best-effort by nature, and the position option simply does nothing if
-- a future build stops exposing it rather than erroring.
-- The countdown FontString may not exist until a cooldown first runs, so a
-- miss is retried a second later rather than remembered forever. It used to
-- be cached as "none" on the first look, and the options preview styles its
-- icons just before starting their mock cooldown -- which would have left
-- the countdown's size, colour and placement unapplied for good. The retry is
-- throttled because the region scan allocates a table.
local function CooldownCountdownText(cd)
    if not cd then return nil end
    if cd._sqCountdownFS then return cd._sqCountdownFS end
    local now = GetTime()
    if cd._sqCountdownRetry and now < cd._sqCountdownRetry then return nil end
    for _, region in ipairs({ cd:GetRegions() }) do
        if region:GetObjectType() == "FontString" then
            cd._sqCountdownFS = region
            return region
        end
    end
    cd._sqCountdownRetry = now + 1
    return nil
end

-- Icon shapes. The shape list, its art and the mask handling live in
-- UI/Shapes.lua (ns.Shapes), shared with the reminder buttons since 1.78; what
-- each image does for a proxy -- mask, swipe, border -- is described there.
local ICON_SHAPES = ns.Shapes.LIST
local SHAPE_FILE  = ns.Shapes.FILE
local SHAPE_GLOW  = ns.Shapes.GLOW
-- For GetBuffPlaceholder, which sits above this point in the file.
cdmModule.shapeFiles = SHAPE_FILE

-- What a square swipe goes back to after a shape. A white square tinted by the
-- swipe colour draws the same as the template's own swipe. Only ever set on a
-- proxy that has been shaped, so one that never was is left exactly as built.
local SQUARE_SWIPE = "Interface\\Buttons\\WHITE8X8"

local function ApplyIconShape(proxy, shape)
    -- Icon and background cut to the shape, or put back square. The mask
    -- handling is shared with the reminder buttons; see ns.Shapes.SetMask.
    ns.Shapes.SetMask(proxy, shape, proxy.Icon, proxy.Bg)
    local file = SHAPE_FILE[shape]

    if file then
        -- Below the background and the icon, so only the rim that sticks out
        -- past them shows. Sized, tinted and shown by ApplyProxyVisuals.
        if not proxy.ShapeBorder then
            proxy.ShapeBorder = proxy:CreateTexture(nil, "BACKGROUND", nil, -8)
        end
        proxy.ShapeBorder:SetTexture(file)
    elseif proxy.ShapeBorder then
        proxy.ShapeBorder:Hide()
    end

    local cd = proxy.Cooldown
    if cd and (file or proxy._sqShapedSwipe) then
        cd:SetSwipeTexture(file or SQUARE_SWIPE)
        -- The edge is the bright line riding the sweep, and it is drawn out to
        -- the frame's own square. Round has a circular edge for exactly this;
        -- every other shape would have the line poking out past its outline,
        -- so they go without.
        if cd.SetUseCircularEdge then cd:SetUseCircularEdge(shape == "round") end
        cd:SetDrawEdge(file == nil or shape == "round")
        if file then proxy._sqShapedSwipe = true end
    end

    -- Both glows follow the shape: Blizzard's alert still plays, with its art
    -- swapped for animated sheets in this shape (see ns.Glow, ApplyAlertArt).
    -- A glow already running switches at once.
    --
    -- Square falls back to art of its own rather than to Blizzard's, which is
    -- what lets the proc glow take a colour on EVERY shape: Blizzard's art is a
    -- fixed gold that cannot be tinted, so a square icon was the one shape
    -- whose proc colour could not be chosen. See Shapes.SQUARE_GLOW.
    local glowArt = SHAPE_GLOW[shape] or ns.Shapes.SQUARE_GLOW
    ns.Glow.SetShape(proxy.ProcGlow, glowArt)
    ns.Glow.SetShape(proxy.GlowFrame, glowArt)
    ns.Glow.SetShape(proxy.ActiveGlow, glowArt)
end

-- The icon texture and cooldown of a frame we did NOT build.
--
-- Blizzard's own accessor first: CooldownViewerItemMixin:GetIconTexture returns
-- self.Icon, and the buff-bar mixin overrides it with its own. Some item types
-- wrap the texture in a frame, which is why EllesmereUI reaches through
-- frame.Icon.Icon -- same dance here. Returns nil rather than guessing if
-- nothing that accepts a mask turns up.
local function BorrowedIconRegions(child)
    if not child then return nil end
    local icon = child.Icon
    if not icon and child.GetIconTexture then
        local ok, tex = pcall(child.GetIconTexture, child)
        if ok then icon = tex end
    end
    if icon and not icon.AddMaskTexture and icon.Icon then icon = icon.Icon end
    if icon and not icon.AddMaskTexture then icon = nil end
    local cd = child.Cooldown or (child.GetCooldownFrame and child:GetCooldownFrame())
    return icon, cd
end

-- Cut a BORROWED frame to the group's icon shape -- Blizzard's own CDM item, or
-- one of our placeholders, whichever is standing in the slot.
--
-- ApplyIconShape above does this for a proxy, but reaches proxy.Icon / proxy.Bg
-- / proxy.ShapeBorder by name, which a Blizzard item does not have.
--
-- MASKING A FRAME WE DO NOT OWN IS SANCTIONED. AddMaskTexture and
-- RemoveMaskTexture are ordinary region writes, the same class as the font
-- string ApplyKeybindText already puts on these very children. EllesmereUI has
-- masked Blizzard's CDM items -- buff-viewer frames included -- all along
-- (EllesmereUICdmHooks.lua, _AC.SetMask + ApplyExtra, taking frame.Icon and
-- frame.Cooldown straight off the item). The belief that they could not be
-- masked is what left a single group drawing some icons round and some square,
-- decided only by whether an entry happened to get one of our cells -- which is
-- exactly what a user saw on a Death Knight's buff row (2026-09-20).
--
-- No ShapeBorder: that is a proxy-only texture, created at its own sublevel and
-- sized and tinted by ApplyProxyVisuals, with nothing on a Blizzard item to
-- hang it on. Mask and swipe only -- which is what decides the silhouette.
--
-- Passing nil for `shape` is the UNDO, and it is what puts a pooled frame back
-- square before Blizzard gets it again (see ReleaseAll). ns.Shapes.SetMask
-- removes before it adds, so re-applying can never stack two masks.
ApplyShapeToBorrowedChild = function(child, shape, zoom)
    local icon, cd = BorrowedIconRegions(child)
    if not icon then return end
    if shape == "none" then shape = nil end

    -- ICON ZOOM, which a borrowed frame never had.
    --
    -- The art on a spell icon is a square that runs edge to edge, corners and
    -- all, so a round mask cuts straight through the square border baked into
    -- the image. Cropping the outer fraction of the texture is what makes a
    -- shaped icon look deliberate rather than clipped -- the proxy path has
    -- always done it (ApplyProxyVisuals) and so has the placeholder path
    -- (GetBuffPlaceholder), but Blizzard's own frames were left at full coords.
    --
    -- That is also the whole reason the Icon Zoom slider looked broken on the
    -- buff groups (user report 2026-09-20): those groups draw borrowed frames,
    -- and the setting only ever reached proxies and placeholders. It was doing
    -- nothing because nothing was reading it here.
    --
    -- Reset to full coords on the unwind, not left cropped: Blizzard's
    -- RefreshSpellTexture sets the texture but never the coords, so a frame
    -- handed back would keep our crop until it happened to be rebuilt.
    if zoom == nil then zoom = DEFAULT_ICON_ZOOM end
    if shape or child._sqZoomed then
        local z = shape and zoom or 0
        pcall(icon.SetTexCoord, icon, z, 1 - z, z, 1 - z)
        child._sqZoomed = shape and true or nil
    end

    -- BLIZZARD ALREADY MASKS THIS ICON, AND MASKS INTERSECT.
    --
    -- Every CDM item template ships its own MaskTexture -- the rounded square
    -- UI-HUD-CoolDownManager-Mask, setAllPoints, permanently applied to Icon
    -- (CooldownViewer.xml, the <MaskedTextures> block on each item template).
    -- Adding ours does not replace it: the two COMBINE, and the icon comes out
    -- as the intersection -- mostly Blizzard's rounded square, with our circle
    -- biting only where it is tighter.
    --
    -- That is exactly what was seen (2026-09-20): icons still square while the
    -- swipe went round. The swipe looked right because it is not masked at all
    -- -- we substitute its texture outright, so it never meets Blizzard's mask.
    --
    -- So Blizzard's mask comes OFF while ours is on, and goes back when we let
    -- the frame go. They are anonymous XML regions with no parentKey, so they
    -- are found by walking the frame's regions once, then cached per frame.
    local blizz = child._sqBlizzMasks
    if not blizz then
        blizz = {}
        -- Blizzard's SQUARE ICON BORDER, which no mask can ever reach.
        --
        -- Each item template also carries an OVERLAY texture atlassed
        -- UI-HUD-CoolDownManager-IconOverlay, anchored deliberately OUTSIDE the
        -- frame (TOPLEFT -8,7 to BOTTOMRIGHT 8,-7 on the buff-icon template)
        -- and pointedly NOT listed in its <MaskedTextures> -- only Icon is. So
        -- it is not masked by Blizzard's own mask, and it cannot be masked by
        -- ours either: it draws a square outline sitting outside our circle,
        -- which is what was still visible once the icon itself went round
        -- (user report 2026-09-20).
        --
        -- Nothing for it but to hide the texture while a shape is on, and show
        -- it again on the unwind. It is anonymous -- no parentKey -- so it is
        -- found by atlas on the frame's own regions, once, and cached.
        local overlays = {}
        local ok, regions = pcall(function() return { child:GetRegions() } end)
        if ok and regions then
            for _, r in ipairs(regions) do
                local okT, t = pcall(r.GetObjectType, r)
                if okT and t == "MaskTexture" then
                    blizz[#blizz + 1] = r
                elseif okT and t == "Texture" then
                    local okA, atlas = pcall(r.GetAtlas, r)
                    if okA and type(atlas) == "string"
                       and atlas:find("IconOverlay", 1, true) then
                        overlays[#overlays + 1] = r
                    end
                end
            end
        end
        child._sqBlizzMasks = blizz
        child._sqBlizzOverlays = overlays
    end
    for _, o in ipairs(child._sqBlizzOverlays or {}) do
        pcall(o.SetShown, o, not shape)
    end
    for _, m in ipairs(blizz) do
        -- Remove first in BOTH directions: AddMaskTexture is additive, so a
        -- repeated unwind would otherwise stack Blizzard's own mask twice.
        pcall(icon.RemoveMaskTexture, icon, m)
        if not shape then pcall(icon.AddMaskTexture, icon, m) end
    end

    local file = ns.Shapes.SetMask(child, shape, icon)

    -- RE-POINT THE MASK EVERY PASS, AND TO THE FRAME RATHER THAN THE ICON.
    --
    -- ns.Shapes.SetMask anchors the mask once, at creation, to the first region
    -- it is handed (`if not m then ... m:SetAllPoints((...)) end`). That is fine
    -- for a proxy, whose Icon is SetAllPoints on the proxy itself, so the two
    -- rects can never diverge. It is wrong here: these are Blizzard's POOLED
    -- item frames, which it resizes and re-anchors as it reuses them, and which
    -- this layout also resizes to the group's iconSize. A mask left on the rect
    -- the icon happened to have when we first saw it then covers only part of
    -- the icon, and the shape gets cut off flat where the mask runs out -- seen
    -- as a straight left edge on an otherwise round icon (user report
    -- 2026-09-20: Bone Shield and Death and Decay, the two borrowed frames in
    -- a row whose other icons are our own cells and were correctly round).
    --
    -- The frame is the stable rect: we have just set its size, and the shape is
    -- meant to describe the SLOT, not whatever sub-rect the art occupies inside
    -- it. EllesmereUI anchors to a button-sized host for the same reason, and
    -- re-points on every apply rather than only at creation.
    local mask = child._sqMask
    if mask and file then
        mask:ClearAllPoints()
        mask:SetAllPoints(child)
    end

    -- Only ever touched on a frame we have actually shaped, so one that never
    -- was keeps whatever swipe Blizzard gave it.
    if cd and (file or child._sqShapedSwipe) then
        pcall(cd.SetSwipeTexture, cd, file or SQUARE_SWIPE)
        if cd.SetUseCircularEdge then
            pcall(cd.SetUseCircularEdge, cd, shape == "round")
        end
        if cd.SetDrawEdge then
            pcall(cd.SetDrawEdge, cd, file == nil or shape == "round")
        end
        child._sqShapedSwipe = file and true or nil
    end

    shapedBorrowed[child] = file and true or nil
end

-- Put every borrowed frame back square. Called when this module lets go of
-- them; without it the shape rides along to Blizzard's own bar.
local function UnshapeAllBorrowed()
    for child in pairs(shapedBorrowed) do
        ApplyShapeToBorrowedChild(child, nil)
    end
    wipe(shapedBorrowed)
end

-- What Squizzumables_CDM.lua's forwarders call (see the header).
local textAndShapes = cdmModule.textAndShapes
textAndShapes.ApplyBarBackground        = ApplyBarBackground
textAndShapes.ApplyShapeToBorrowedChild = ApplyShapeToBorrowedChild
textAndShapes.CooldownCountdownText     = CooldownCountdownText
textAndShapes.ApplyIconShape            = ApplyIconShape
textAndShapes.UnshapeAllBorrowed        = UnshapeAllBorrowed
