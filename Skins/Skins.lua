-- Skins/Skins.lua
-- Our own skins for Blizzard's windows, replacing ElvUI's (and WindTools'
-- shadows on top). Off by default. The look follows ElvUI's: dark see-through
-- panels, 1px borders, flat buttons, tabs, boxes and scroll bars, and the
-- parchment gone. ElvUI was read for behaviour only; none of its code or art
-- is used (the arrow, cross and shadow images are ours, .tools\make-skin-media.ps1).
--
-- How it differs from ElvUI underneath, on purpose:
--
--   * Nothing is written into Blizzard's frames. ElvUI mixes BackdropTemplate
--     into them and keeps .backdrop / .IsSkinned on them; we draw our own
--     backdrop frames BEHIND theirs and keep everything in our own tables.
--     A field we write onto one of Blizzard's tables is tainted, and any of
--     Blizzard's code that later reads it runs tainted -- which is how skins
--     break things like the popups that confirm protected actions.
--   * Art is hidden with alpha, not by clearing it. Blizzard swaps textures
--     and atlases on every state change (a pressed button, a selected tab),
--     which brings cleared art straight back; an alpha of 0 survives that.
--   * The parchment remover sets the game's own Quest Text Contrast to its
--     dark setting, so Blizzard recolours the quest, gossip and book text
--     itself; ElvUI rewrites those colours with a dozen hooks.
--
-- Each window waits while ElvUI's skin for it is on, so the two never
-- stack; turn ElvUI's off (or ElvUI's whole skins module) to see ours. A skin
-- is applied once; taking one off needs a /reload.

local addonName, ns = ...
local BH = ns.BH

local SK = {}
ns.Skins = SK

local MEDIA = "Interface\\AddOns\\" .. addonName .. "\\Media\\Skins\\"
SK.ARROW = MEDIA .. "arrow.png"
SK.CLOSE = MEDIA .. "close.png"
SK.SHADOW = MEDIA .. "shadow.png"
local WHITE = "Interface\\Buttons\\WHITE8x8"
local ROTATION = { up = 0, down = math.pi, left = math.pi / 2, right = -math.pi / 2 }

local settingsView = setmetatable({}, { __index = function(_, k)
    local s = BH.settings
    local v = s and s[k]
    if v == nil and BH.defaultSettings then v = BH.defaultSettings[k] end
    return v
end })
local function Settings() return settingsView end

-- ============================================================================
-- ElvUI
-- ============================================================================

local function Elv()
    local elv = _G["ElvUI"]
    return C_AddOns.IsAddOnLoaded("ElvUI") and type(elv) == "table" and elv[1] or nil
end

local function ElvSkins()
    local E = Elv()
    local sk = E and E.private and E.private.skins
    return type(sk) == "table" and sk or nil
end

-- ElvUI's skin for this window is on (so ours waits).
local function ElvSkinOn(elvKey)
    local sk = ElvSkins()
    local b = sk and sk.blizzard
    return type(b) == "table" and b.enable and elvKey and b[elvKey] and true or false
end

-- ============================================================================
-- The windows (a batch at a time; each file fills in its `skin`)
-- ============================================================================

-- key, label, ElvUI's key, and the Blizzard addon it lives in when that loads
-- on demand (nil: already loaded with the game). `forever = false` marks a
-- window Forever does not have; `addon` may differ per client.
local FOREVER = BH.IS_FOREVER
SK.WINDOWS = {
    { key = "misc",     label = "Popups and Game Menu", elv = "misc" },
    { key = "gossip",   label = "Gossip and Books",                    elv = "gossip" },
    { key = "quest",    label = "Quest Windows",                       elv = "quest" },
    { key = "merchant", label = "Merchant",                            elv = "merchant" },
    { key = "mail",     label = "Mail",                                elv = "mail", addon = "Blizzard_MailFrame" },
    { key = "character", label = "Character, Reputation and Currency", elv = "character" },
    { key = "friends",  label = "Friends",                             elv = "friends" },
    { key = "lfg",      label = "Group Finder",                        elv = "lfg" },
    -- Forever has no PvP window: its PvP tab is in the character window.
    { key = "pvp",      label = "PvP",                                 elv = "pvp", addon = "Blizzard_PVPUI", forever = false },
    { key = "talents",  label = "Talents and Spellbook",               elv = "talent", addon = "Blizzard_PlayerSpells" },
    { key = "collections", label = "Collections",                      elv = "collections", addon = "Blizzard_Collections" },
    { key = "encounterjournal", label = "Dungeon Journal",             elv = "encounterjournal", addon = "Blizzard_EncounterJournal", forever = false },
    { key = "achievement", label = "Achievements",                     elv = "achievement", addon = "Blizzard_AchievementUI", forever = false },
    -- Batch 4: trade and items (Skins/Windows4.lua).
    { key = "auctionhouse", label = "Auction House",                   elv = "auctionhouse", addon = "Blizzard_AuctionHouseUI" },
    { key = "tradeskill", label = "Professions",                       elv = "tradeskill", addon = "Blizzard_Professions" },
    { key = "craftorders", label = "Crafting Orders",                  elv = "tradeskill", addon = "Blizzard_ProfessionsCustomerOrders" },
    { key = "profbook",   label = "Profession Book",                   elv = "spellbook", addon = "Blizzard_ProfessionsBook" },
    { key = "trainer",    label = "Trainers",                          elv = "trainer", addon = "Blizzard_TrainerUI" },
    { key = "loot",       label = "Loot and Rolls",                    elv = "loot" },
    { key = "bags",       label = "Bags and Bank",                     elv = "bags" },
    { key = "gbank",      label = "Guild Bank",                        elv = "gbank", addon = "Blizzard_GuildBankUI" },
    { key = "macro",      label = "Macros",                            elv = "macro", addon = "Blizzard_MacroUI" },
    -- Batch 5: people (Skins/Windows5.lua).
    { key = "communities", label = "Guild and Communities",            elv = "communities", addon = "Blizzard_Communities" },
    { key = "guild",      label = "Guild Invites",                     elv = "guild" },
    { key = "guildcontrol", label = "Guild Control",                   elv = "guildcontrol", addon = "Blizzard_GuildControlUI" },
    { key = "guildregistrar", label = "Guild Registrar",               elv = "guildregistrar" },
    { key = "petition",   label = "Petitions",                         elv = "petition" },
    { key = "tabard",     label = "Tabard Designer",                   elv = "tabard" },
    { key = "calendar",   label = "Calendar",                          elv = "calendar", addon = "Blizzard_Calendar" },
    { key = "timemanager", label = "Clock and Stopwatch",              elv = "timemanager", addon = "Blizzard_TimeManager" },
    { key = "inspect",    label = "Inspect",                           elv = "inspect", addon = "Blizzard_InspectUI" },
    { key = "trade",      label = "Trade",                             elv = "trade" },
    { key = "dressingroom", label = "Dressing Room",                   elv = "dressingroom" },
    { key = "nonraid",    label = "Raid Tab and Raid Info",            elv = "nonraid", addon = "Blizzard_RaidFrame" },
    { key = "raid",       label = "Raid Groups",                       elv = "raid", addon = "Blizzard_RaidUI" },
    { key = "channels",   label = "Chat Channels",                     elv = "channels", addon = "Blizzard_Channels" },
    -- Batch 6: settings, tools and the rest (Skins/Windows6.lua).
    { key = "blizzardOptions", label = "Settings and Chat Settings",   elv = "blizzardOptions", addon = "Blizzard_Settings_Shared" },
    { key = "binding",    label = "Click Casting",                     elv = "binding", addon = "Blizzard_ClickBindingUI" },
    { key = "addonManager", label = "Addon List",                      elv = "addonManager", addon = "Blizzard_AddOnList" },
    { key = "help",       label = "Help",                              elv = "help", addon = "Blizzard_HelpFrame" },
    { key = "gmChat",     label = "GM Chat",                           elv = "gmChat", addon = "Blizzard_GMChatUI" },
    { key = "debug",      label = "Lua Errors and Table Inspector",    elv = "debug", addon = "Blizzard_ScriptErrorsFrame" },
    { key = "eventLog",   label = "Event Trace",                       elv = "eventLog", addon = "Blizzard_EventTrace" },
    { key = "editor",     label = "Edit Mode",                         elv = "editor", addon = "Blizzard_EditMode" },
    { key = "deathRecap", label = "Death Recap",                       elv = "deathRecap", addon = "Blizzard_DeathRecap" },
    { key = "mirrorTimers", label = "Breath and Fatigue Bars",         elv = "mirrorTimers", addon = "Blizzard_MirrorTimer" },
    { key = "losscontrol", label = "Loss of Control",                  elv = "losscontrol" },
    { key = "alertframes", label = "Toasts",                           elv = "alertframes" },
    { key = "bgscore",    label = "Battleground Scores",               elv = "bgscore", addon = "Blizzard_PVPMatch" },
    { key = "weeklyRewards", label = "Great Vault",                    elv = "weeklyRewards", addon = "Blizzard_WeeklyRewards" },
    { key = "expansionLanding", label = "Expansion Landing Page",      elv = "expansionLanding", addon = "Blizzard_ExpansionLandingPage" },
    { key = "playerChoice", label = "Choices",                         elv = "playerChoice", addon = "Blizzard_PlayerChoice" },
    { key = "genericTrait", label = "Trait Trees",                     elv = "genericTrait", addon = "Blizzard_GenericTraitUI" },
    { key = "socket",     label = "Sockets",                           elv = "socket", addon = "Blizzard_ItemSocketingUI" },
    { key = "itemUpgrade", label = "Item Upgrades",                    elv = "itemUpgrade", addon = "Blizzard_ItemUpgradeUI" },
    { key = "itemInteraction", label = "Catalyst",                     elv = "itemInteraction", addon = "Blizzard_ItemInteractionUI" },
    { key = "scrapping",  label = "Scrapper",                          elv = "scrapping", addon = "Blizzard_ScrappingMachineUI" },
    { key = "barber",     label = "Barber",                            elv = "barber", addon = "Blizzard_BarbershopUI" },
    { key = "stable",     label = "Stable",                            elv = "stable", addon = "Blizzard_StableUI" },
    { key = "taxi",       label = "Flight Maps",                       elv = "taxi" },
    { key = "bmah",       label = "Black Market",                      elv = "bmah", addon = "Blizzard_BlackMarketUI" },
    { key = "transmogrify", label = "Transmog",                        elv = "transmogrify", addon = "Blizzard_Transmog" },
    { key = "housing",    label = "Housing",                           elv = "housing", addon = "Blizzard_HousingDashboard" },
    -- Older content: a general pass each.
    { key = "adventureMap", label = "Adventure Maps",                  elv = "adventureMap", addon = "Blizzard_AdventureMap" },
    { key = "alliedRaces", label = "Allied Races",                     elv = "alliedRaces", addon = "Blizzard_AlliedRacesUI" },
    { key = "animaDiversion", label = "Anima Diversion",               elv = "animaDiversion", addon = "Blizzard_AnimaDiversionUI" },
    { key = "archaeology", label = "Archaeology",                      elv = "archaeology", addon = "Blizzard_ArchaeologyUI" },
    { key = "artifact",   label = "Artifact Weapons",                  elv = "artifact", addon = "Blizzard_ArtifactUI" },
    { key = "azerite",    label = "Azerite Armour",                    elv = "azerite", addon = "Blizzard_AzeriteUI" },
    { key = "azeriteEssence", label = "Heart of Azeroth",              elv = "azeriteEssence", addon = "Blizzard_AzeriteEssenceUI" },
    { key = "azeriteRespec", label = "Azerite Reforge",                elv = "azeriteRespec", addon = "Blizzard_AzeriteRespecUI" },
    { key = "chromieTime", label = "Chromie Time",                     elv = "chromieTime", addon = "Blizzard_ChromieTimeUI" },
    { key = "contribution", label = "War Effort Contributions",        elv = "contribution", addon = "Blizzard_Contribution" },
    { key = "covenantPreview", label = "Covenant Preview",             elv = "covenantPreview", addon = "Blizzard_CovenantPreviewUI" },
    { key = "covenantRenown", label = "Covenant Renown",               elv = "covenantRenown", addon = "Blizzard_CovenantRenown" },
    { key = "covenantSanctum", label = "Covenant Sanctum",             elv = "covenantSanctum", addon = "Blizzard_CovenantSanctum" },
    { key = "garrison",   label = "Garrison Landing Page",             elv = "garrison", addon = "Blizzard_GarrisonUI" },
    { key = "islandQueue", label = "Island Expeditions",               elv = "islandQueue", addon = "Blizzard_IslandsQueueUI" },
    { key = "obliterum",  label = "Obliterum Forge",                   elv = "obliterum", addon = "Blizzard_ObliterumUI" },
    { key = "orderhall",  label = "Order Hall",                        elv = "orderhall", addon = "Blizzard_OrderHallUI" },
    { key = "runeforge",  label = "Runecarver",                        elv = "runeforge", addon = "Blizzard_RuneforgeUI" },
    { key = "soulbinds",  label = "Soulbinds",                         elv = "soulbinds", addon = "Blizzard_Soulbinds" },
    { key = "torghastLevelPicker", label = "Torghast Layers",          elv = "torghastLevelPicker", addon = "Blizzard_TorghastLevelPicker" },
    { key = "subscriptionInterstitial", label = "Subscription Offer",  elv = "subscriptionInterstitial", addon = "Blizzard_SubscriptionInterstitialUI" },
}
-- Windows this client does not have: retail-only ones flagged above, and any
-- whose Blizzard addon does not exist here at all.
for i = #SK.WINDOWS, 1, -1 do
    local w = SK.WINDOWS[i]
    local missing = w.addon and C_AddOns.DoesAddOnExist and not C_AddOns.DoesAddOnExist(w.addon)
    if (FOREVER and w.forever == false) or missing then table.remove(SK.WINDOWS, i) end
end
local byKey = {}
for _, w in ipairs(SK.WINDOWS) do byKey[w.key] = w end

function SK.Define(key, fn)
    local w = byKey[key]
    if not w then return end   -- a window this client does not have
    w.skin = fn
end

-- A part of a window that lives in another Blizzard addon, loaded later (the
-- Forever group finder, its statistics window): run once that addon is in,
-- if the window's skin is on.
function SK.DefineLate(key, addon, fn)
    local w = byKey[key]
    if not w or not addon then return end
    w.late = w.late or {}
    w.late[addon] = fn
end

local function WindowActive(w)
    local s = Settings()
    return s.skEnabled and s["sk_" .. w.key] ~= false and not ElvSkinOn(w.elv)
end

-- ============================================================================
-- Colours and sizes
-- ============================================================================

local function C(key, fallback)
    local c = Settings()[key]
    if type(c) ~= "table" then c = fallback end
    return c.r or 0, c.g or 0, c.b or 0
end

function SK.PanelRGBA()
    local r, g, b = C("skPanelColor", { r = 0.06, g = 0.06, b = 0.06 })
    return r, g, b, (Settings().skPanelAlpha or 80) / 100
end
function SK.ButtonRGBA()
    local r, g, b = C("skButtonColor", { r = 0.1, g = 0.1, b = 0.1 })
    return r, g, b, 1
end
function SK.BorderRGB() return C("skBorderColor", { r = 0, g = 0, b = 0 }) end
function SK.AccentRGB() return C("skAccentColor", { r = 0.09, g = 0.52, b = 0.82 }) end

-- One physical pixel in a frame's own units, so borders stay 1px sharp at any
-- UI scale.
function SK.Pixel(frame)
    local scale = frame and frame.GetEffectiveScale and frame:GetEffectiveScale() or UIParent:GetEffectiveScale()
    return PixelUtil.GetNearestPixelSize(1, scale, 1)
end

-- ============================================================================
-- Backdrops: our own frames, drawn behind the thing they dress
-- ============================================================================

local backdrops = setmetatable({}, { __mode = "k" })   -- owner -> backdrop
local painted = setmetatable({}, { __mode = "k" })     -- backdrop -> kind

local function Paint(b)
    local kind = painted[b]
    if type(kind) == "table" then
        b:SetBackdropColor(kind[1], kind[2], kind[3], kind[4] or 1)
    elseif kind == "panel" then
        b:SetBackdropColor(SK.PanelRGBA())
    elseif kind == "none" then
        b:SetBackdropColor(0, 0, 0, 0)
    else
        b:SetBackdropColor(SK.ButtonRGBA())
    end
    if not b.sqHover then b:SetBackdropBorderColor(SK.BorderRGB()) end
end

-- kind: "panel" (see-through, for windows), "button" (solid), "none"
-- (border only) or a fixed { r, g, b, a } background. Offsets are from the owner's corners: x1, y1 the top left,
-- x2, y2 the bottom right (outward is negative x1 / positive y1 and so on).
function SK.Backdrop(owner, kind, x1, y1, x2, y2)
    local b = backdrops[owner]
    if not b then
        local parent = (owner.IsObjectType and owner:IsObjectType("Texture")) and owner:GetParent() or owner
        b = CreateFrame("Frame", nil, parent, "BackdropTemplate")
        local level = parent:GetFrameLevel()
        b:SetFrameLevel(level > 0 and level - 1 or 0)
        local px = SK.Pixel(parent)
        b:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = px })
        backdrops[owner] = b
    end
    painted[b] = kind or "button"
    b:ClearAllPoints()
    b:SetPoint("TOPLEFT", owner, "TOPLEFT", x1 or 0, y1 or 0)
    b:SetPoint("BOTTOMRIGHT", owner, "BOTTOMRIGHT", x2 or 0, y2 or 0)
    Paint(b)
    return b
end

function SK.GetBackdrop(owner) return backdrops[owner] end

-- Repaint every backdrop (a colour setting changed).
function SK.Repaint()
    for b in pairs(painted) do Paint(b) end
end

-- Hover: the border takes the accent colour.
local function HoverOn(self)
    local b = backdrops[self]
    if not b or (self.IsEnabled and not self:IsEnabled()) then return end
    b.sqHover = true
    b:SetBackdropBorderColor(SK.AccentRGB())
end
local function HoverOff(self)
    local b = backdrops[self]
    if not b then return end
    b.sqHover = nil
    b:SetBackdropBorderColor(SK.BorderRGB())
end
function SK.Hover(frame)
    frame:HookScript("OnEnter", HoverOn)
    frame:HookScript("OnLeave", HoverOff)
    if frame.HasScript and frame:HasScript("OnDisable") then frame:HookScript("OnDisable", HoverOff) end
end

-- ============================================================================
-- Shadow: a soft dark edge outside a window (WindTools' look)
-- ============================================================================

local shadows = setmetatable({}, { __mode = "k" })     -- owner -> shadow frame
local shadowHosts = setmetatable({}, { __mode = "k" }) -- shadow frame -> true

function SK.Shadow(frame, size)
    if shadows[frame] then return shadows[frame] end
    size = size or 6
    local b = backdrops[frame] or frame
    local host = CreateFrame("Frame", nil, frame)
    host:SetFrameLevel(math.max(0, b:GetFrameLevel() - 1))
    local t = host:CreateTexture(nil, "BACKGROUND")
    t:SetTexture(SK.SHADOW)
    t:SetTextureSliceMargins(24, 24, 24, 24)
    t:SetTextureSliceMode(Enum.UITextureSliceMode.Stretched)
    t:SetPoint("TOPLEFT", b, "TOPLEFT", -size, size)
    t:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", size, -size)
    t:SetAlpha(0.7)
    shadows[frame] = host
    shadowHosts[host] = true
    host:SetShown(Settings().skShadow ~= false)
    return host
end

local function ApplyShadows()
    local on = Settings().skShadow ~= false
    for _, host in pairs(shadows) do host:SetShown(on) end
end

-- ============================================================================
-- Taking Blizzard's art away
-- ============================================================================

local function Hide(region)
    if region and region.SetAlpha then region:SetAlpha(0) end
end
SK.Hide = Hide

-- Every texture directly on a frame (not its children), plus the usual named
-- pieces. `keep` is a set of regions to leave alone.
function SK.Strip(frame, keep)
    if not frame then return end
    for _, r in ipairs({ frame:GetRegions() }) do
        if r:IsObjectType("Texture") and not (keep and keep[r]) then r:SetAlpha(0) end
    end
end

-- Blizzard's standard window furniture.
local FURNITURE = { "NineSlice", "Bg", "TopTileStreaks", "PortraitContainer", "portrait",
                    "Portrait", "PortraitOverlay", "ArtOverlayFrame", "BorderTexture", "TitleBg", "TopLeftCorner",
                    "TopRightCorner", "TopBorder", "BotLeftCorner", "BotRightCorner", "BottomBorder",
                    "LeftBorder", "RightBorder", "Border", "BorderFrame", "Overlay" }

function SK.Furniture(frame, keep)
    local name = frame:GetName()
    for _, k in ipairs(FURNITURE) do
        local r = frame[k] or (name and _G[name .. k])
        if not (keep and r and keep[r]) then Hide(r) end
    end
end

function SK.Inset(inset)
    if not inset then return end
    SK.Strip(inset)
    Hide(inset.NineSlice)
    Hide(inset.Bg)
end

-- ============================================================================
-- Controls
-- ============================================================================

local done = setmetatable({}, { __mode = "k" })
local function Once(frame)
    if not frame or done[frame] then return false end
    done[frame] = true
    return true
end
SK.Once = Once

local function HideStateTextures(btn)
    for _, getter in ipairs({ "GetNormalTexture", "GetPushedTexture", "GetHighlightTexture", "GetDisabledTexture" }) do
        local t = btn[getter] and btn[getter](btn)
        if t then t:SetAlpha(0) end
    end
end

-- A button set to another texture later still has to stay hidden.
local function KeepStateTexturesHidden(btn)
    for _, setter in ipairs({ "SetNormalTexture", "SetPushedTexture", "SetHighlightTexture", "SetDisabledTexture" }) do
        if btn[setter] then hooksecurefunc(btn, setter, HideStateTextures) end
    end
end

function SK.Button(btn, x1, y1, x2, y2)
    if not Once(btn) then return end
    local name = btn:GetName()
    for _, k in ipairs({ "Left", "Middle", "Right", "Center", "LeftSeparator", "RightSeparator", "TopLeft", "TopRight",
                         "BottomLeft", "BottomRight", "MiddleLeft", "MiddleRight", "TopMiddle", "BottomMiddle",
                         "MiddleMiddle", "Flash", "Background" }) do
        Hide(btn[k] or (name and _G[name .. k]))
    end
    HideStateTextures(btn)
    KeepStateTexturesHidden(btn)
    SK.Backdrop(btn, "button", x1 or 1, y1 or -1, x2 or -1, y2 or 1)
    SK.Hover(btn)
end

-- The cross in a window's corner.
function SK.Close(btn, size)
    if not Once(btn) then return end
    HideStateTextures(btn)
    KeepStateTexturesHidden(btn)
    local x = btn:CreateTexture(nil, "OVERLAY")
    x:SetTexture(SK.CLOSE)
    x:SetSize(size or 14, size or 14)
    x:SetPoint("CENTER")
    x:SetVertexColor(0.85, 0.85, 0.85)
    btn:HookScript("OnEnter", function() x:SetVertexColor(SK.AccentRGB()) end)
    btn:HookScript("OnLeave", function() x:SetVertexColor(0.85, 0.85, 0.85) end)
    btn:HookScript("OnDisable", function() x:SetVertexColor(0.4, 0.4, 0.4) end)
    btn:HookScript("OnEnable", function() x:SetVertexColor(0.85, 0.85, 0.85) end)
end

-- A small square button with an arrow (page buttons, scroll bar ends).
function SK.Arrow(btn, dir, size)
    if not Once(btn) then return end
    SK.Strip(btn)
    HideStateTextures(btn)
    KeepStateTexturesHidden(btn)
    for _, k in ipairs({ "Texture", "Overlay", "Back", "Arrow", "Icon" }) do
        local r = btn[k]
        if r and r.IsObjectType and r:IsObjectType("Texture") then r:SetAlpha(0) end
    end
    local a = btn:CreateTexture(nil, "OVERLAY")
    a:SetTexture(SK.ARROW)
    a:SetRotation(ROTATION[dir or "up"] or 0)
    a:SetSize(size or 12, size or 12)
    a:SetPoint("CENTER")
    a:SetVertexColor(0.9, 0.9, 0.9)
    local function State()
        if btn.IsEnabled and not btn:IsEnabled() then a:SetVertexColor(0.35, 0.35, 0.35) else a:SetVertexColor(0.9, 0.9, 0.9) end
    end
    btn:HookScript("OnEnable", State)
    btn:HookScript("OnDisable", State)
    btn:HookScript("OnEnter", function() if not btn.IsEnabled or btn:IsEnabled() then a:SetVertexColor(SK.AccentRGB()) end end)
    btn:HookScript("OnLeave", State)
    State()
    SK.Backdrop(btn, "button")
    SK.Hover(btn)
    return a
end

-- The red expand / shrink button in a window's corner
-- (MaximizeMinimizeButtonFrameTemplate): a flat box with our arrow, up to
-- grow and down to shrink, accent on hover.
function SK.MaxMin(frame)
    if not frame or not Once(frame) then return end
    SK.Strip(frame)
    for name, dir in pairs({ MaximizeButton = "up", MinimizeButton = "down" }) do
        local btn = frame[name]
        if btn then
            btn:ClearAllPoints()
            btn:SetPoint("CENTER")
            btn:SetSize(18, 18)
            btn:SetHitRectInsets(1, 1, 1, 1)
            SK.Arrow(btn, dir, 10)
        end
    end
end

-- Blizzard's newer scroll bars (WowTrimScrollBar, MinimalScrollBar).
function SK.ScrollBar(bar)
    if not bar or not Once(bar) then return end
    SK.Strip(bar)
    Hide(bar.Background)
    if bar.Back then SK.Arrow(bar.Back, "up", 10) end
    if bar.Forward then SK.Arrow(bar.Forward, "down", 10) end
    local track = bar.Track
    if track then
        SK.Strip(track)
        for _, k in ipairs({ "Begin", "Middle", "End" }) do Hide(track[k]) end
        SK.Backdrop(track, "panel")
    end
    local thumb = bar.GetThumb and bar:GetThumb() or (track and track.Thumb)
    if thumb then
        thumb:DisableDrawLayer("ARTWORK")
        thumb:DisableDrawLayer("BACKGROUND")
        local b = SK.Backdrop(thumb, "none", 1, 0, -1, 0)
        b:SetFrameLevel(thumb:GetFrameLevel() + 1)
        local r, g, bl = SK.AccentRGB()
        b:SetBackdropColor(r, g, bl, 0.35)
        thumb:HookScript("OnEnter", function() local r2, g2, b2 = SK.AccentRGB(); b:SetBackdropColor(r2, g2, b2, 0.75) end)
        thumb:HookScript("OnLeave", function() local r2, g2, b2 = SK.AccentRGB(); b:SetBackdropColor(r2, g2, b2, 0.35) end)
    end
end

-- Old-style scroll frames (ScrollFrameTemplate / UIPanelScrollFrameTemplate):
-- their bar is a WowTrimScrollBar in 12.x too, but kept on .ScrollBar.
function SK.ScrollFrame(sf)
    if not sf then return end
    SK.Strip(sf)
    if sf.ScrollBar then SK.ScrollBar(sf.ScrollBar) end
end

-- Tabs along the bottom of a window (PanelTabButtonTemplate and friends).
local tabs = setmetatable({}, { __mode = "k" })

local function PaintTab(tab)
    local b = backdrops[tab]
    if not b then return end
    -- TabSystem tabs say so; PanelTabButtons are disabled while selected.
    local selected
    if tab.isSelected ~= nil then selected = tab.isSelected else selected = tab.IsEnabled and not tab:IsEnabled() end
    if b.sqHover then return end
    if selected then
        -- As ElvUI: the selected tab is lifted with a light border; the
        -- accent is kept for hover.
        b:SetBackdropBorderColor(0.6, 0.6, 0.6)
    else
        b:SetBackdropBorderColor(SK.BorderRGB())
    end
end

-- Blizzard lifts the selected tab's text a few pixels to sit in its raised
-- art; on our flat tabs the text stays in the middle.
local textOwner = setmetatable({}, { __mode = "k" })
local centring = false
local function KeepCentred(text)
    if centring then return end
    local tab = textOwner[text]
    if not tab then return end
    centring = true
    text:ClearAllPoints()
    text:SetPoint("CENTER", tab, "CENTER", 0, 1)
    centring = false
end
local function CentreTabText(tab)
    local text = tab.Text or (tab:GetName() and _G[tab:GetName() .. "Text"]) or (tab.GetFontString and tab:GetFontString())
    if not text or textOwner[text] then return end
    textOwner[text] = tab
    hooksecurefunc(text, "SetPoint", KeepCentred)
    KeepCentred(text)
end

function SK.Tab(tab)
    if not Once(tab) then return end
    for _, k in ipairs({ "Left", "Middle", "Right", "LeftActive", "MiddleActive", "RightActive",
                         "LeftHighlight", "MiddleHighlight", "RightHighlight", "LeftDisabled", "MiddleDisabled",
                         "RightDisabled" }) do
        Hide(tab[k])
    end
    if tab.TabTextures then for _, t in ipairs(tab.TabTextures) do Hide(t) end end
    HideStateTextures(tab)
    if tab.squareMode then
        -- An icon tab (Forever's spellbook skill lines): the icon squared off.
        for _, k in ipairs({ "SquareBackground", "SquareBackgroundActive", "SquareBackgroundActiveGlow" }) do Hide(tab[k]) end
        local icon = tab.Icon
        if icon then
            if tab.IconMask and icon.RemoveMaskTexture then icon:RemoveMaskTexture(tab.IconMask) end
            icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            local px = SK.Pixel(tab)
            SK.Backdrop(tab, "button", 0, 0, 0, 0)
            backdrops[tab]:ClearAllPoints()
            backdrops[tab]:SetPoint("TOPLEFT", icon, "TOPLEFT", -px, px)
            backdrops[tab]:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", px, -px)
        else
            SK.Backdrop(tab, "button")
        end
    else
        SK.Backdrop(tab, "button", 3, -1, -3, 3)
        CentreTabText(tab)
    end
    tabs[tab] = true
    SK.Hover(tab)
    tab:HookScript("OnLeave", PaintTab)
    if tab.SetTabSelected then hooksecurefunc(tab, "SetTabSelected", PaintTab) end
    PaintTab(tab)
end

hooksecurefunc("PanelTemplates_SelectTab", function(tab) if tabs[tab] then PaintTab(tab) end end)
hooksecurefunc("PanelTemplates_DeselectTab", function(tab) if tabs[tab] then PaintTab(tab) end end)

-- ============================================================================
-- The general pass: Blizzard's standard controls, found anywhere in a window
-- ============================================================================

-- What a frame is, from the keys Blizzard's templates give it. Only shapes
-- that are unmistakable are named; anything else is left alone.
local function Kind(f)
    local ot = f:GetObjectType()
    if ot == "DropdownButton" then
        local w = f:GetWidth()
        if (f.Arrow or f.Background) and w > 0 and w <= 32 then return "arrowdropdown" end
        if f.Arrow or f.Background then return "dropdown" end
        return nil
    end
    if f.Back and f.Forward and f.Track then return "scrollbar" end
    if f.Slider and f.Back and f.Forward and ot == "Frame" then return "stepslider" end
    if ot == "Button" then
        local parent = f:GetParent()
        if parent and parent.CloseButton == f then return "close" end
        if f.TabTextures or f.LeftActive then return "tab" end
        if f.Left and f.Right and (f.Middle or f.Center) and f.GetFontString and f:GetFontString()
           and f.Left.IsObjectType and f.Left:IsObjectType("Texture") then
            return "button"
        end
        return nil
    end
    if ot == "CheckButton" then
        if f.GetCheckedTexture and f:GetCheckedTexture() and not (f.Icon or f.icon) and f:GetWidth() <= 34 then
            return "check"
        end
        return nil
    end
    if ot == "EditBox" then
        if (f.Left and f.Right) or f.NineSlice then return "editbox" end
        return nil
    end
    if ot == "Frame" and f.NineSlice and f.Bg and not f.CloseButton and not f.PortraitContainer then
        return "inset"
    end
end

-- Looked up when used: some of these are defined further down.
local SKIN = {
    dropdown = "Dropdown", arrowdropdown = "ArrowDropdown", scrollbar = "ScrollBar", close = "Close", tab = "Tab",
    button = "Button", check = "Check", editbox = "EditBox", inset = "AutoInset", stepslider = "StepSlider",
}
function SK.AutoInset(f) if Once(f) then SK.Inset(f) end end
function SK.RepaintTabs() for tab in pairs(tabs) do PaintTab(tab) end end

-- A TabSystem's tabs, including ones it adds later.
function SK.TabSystem(ts)
    if not ts or not Once(ts) then return end
    local function Skin()
        for _, tab in ipairs({ ts:GetChildren() }) do
            if tab.SetTabSelected then SK.Tab(tab) end
        end
    end
    if ts.AddTab then hooksecurefunc(ts, "AddTab", Skin) end
    Skin()
end

-- Bottom tabs sat snug under the window, one after another (ElvUI's layout:
-- Blizzard spaces them for its own wider tab art). Hidden tabs are skipped,
-- and the layout runs again whenever one is shown or hidden.
local tabLists = setmetatable({}, { __mode = "k" })   -- tab -> layout function

function SK.LayoutTabs(frame, list)
    if not frame or not list then return end
    local function Layout()
        local prev
        for _, tab in ipairs(list) do
            if tab:IsShown() then
                tab:ClearAllPoints()
                if prev then
                    tab:SetPoint("TOPLEFT", prev, "TOPRIGHT", -5, 0)
                else
                    tab:SetPoint("TOPLEFT", frame, "BOTTOMLEFT", -3, 0)
                end
                prev = tab
            end
        end
    end
    for _, tab in ipairs(list) do
        if not tabLists[tab] then
            tab:HookScript("OnShow", function() tabLists[tab]() end)
            tab:HookScript("OnHide", function() tabLists[tab]() end)
        end
        tabLists[tab] = Layout
    end
    Layout()
    return Layout
end

-- The same for numbered tabs: Name1, Name2, ... as far as they go.
function SK.NumberedTabs(frame, prefix)
    local list, i = {}, 1
    while _G[prefix .. i] do
        SK.Tab(_G[prefix .. i])
        list[#list + 1] = _G[prefix .. i]
        i = i + 1
    end
    return SK.LayoutTabs(frame, list), list
end

-- Big icon tabs down a window's right edge (LargeSideTabButtonTemplate:
-- Forever's character, collections and group finder, the social window).
local sideTabIcon = setmetatable({}, { __mode = "k" })

local function SideTabInterior(tab)
    local icon = tab.Icon
    if not icon then return end
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    icon:SetSize(30, 30)
end

function SK.SideTab(tab)
    if not tab or not Once(tab) then return end
    local icon = tab.Icon
    if not icon then return end
    if tab.Mask and icon.RemoveMaskTexture then icon:RemoveMaskTexture(tab.Mask) end
    Hide(tab.Background)
    tab:SetSize(36, 30)
    SideTabInterior(tab)
    sideTabIcon[tab] = icon
    -- Blizzard resets the icon's size whenever the tab is checked.
    if tab.UpdateIconInterior then hooksecurefunc(tab, "UpdateIconInterior", SideTabInterior) end
    if tab.SetChecked then hooksecurefunc(tab, "SetChecked", SideTabInterior) end
    local px = SK.Pixel(tab)
    SK.Backdrop(tab, "button")
    backdrops[tab]:ClearAllPoints()
    backdrops[tab]:SetPoint("TOPLEFT", icon, "TOPLEFT", -px, px)
    backdrops[tab]:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", px, -px)
    for _, k in ipairs({ "HighlightTexture", "SelectedTexture" }) do
        local t = tab[k]
        if t then
            t:SetColorTexture(1, 1, 1, 0.3)
            t:SetAllPoints(icon)
        end
    end
    if tab.SelectedTexture then tab.SelectedTexture:SetBlendMode("ADD") end
    if tab.TabGlow then
        tab.TabGlow:SetColorTexture(1, 0.8, 0.1, 0.5)
        tab.TabGlow:SetAllPoints(icon)
    end
    SK.Hover(tab)
end

-- Side tabs stacked down the outside of `frame`'s right edge.
function SK.LayoutSideTabs(frame, list)
    local prev
    for _, tab in ipairs(list or {}) do
        if tab:IsShown() then
            tab:ClearAllPoints()
            if prev then
                tab:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, -3)
            else
                tab:SetPoint("TOPLEFT", frame, "TOPRIGHT", 3, -1)
            end
            prev = tab
        end
    end
end

-- ColoredProgressBarTemplate (Forever's reputation and skill bars): its art
-- away, our track round the fill, and the fill flat in the colour Blizzard's
-- art had.
local BAR_COLOURS = {
    ["common-stat-bar-red"] = { 0.8, 0.15, 0.1 }, ["common-stat-bar-green"] = { 0.23, 1, 0 },
    ["common-stat-bar-blue"] = { 0.03, 0.43, 0.92 }, ["common-stat-bar-white"] = { 0.85, 0.85, 0.85 },
}
local BAR_BY_TYPE = { "common-stat-bar-red", "common-stat-bar-green", "common-stat-bar-blue", "common-stat-bar-white" }

local function FlatFill(fill, atlas)
    local c = BAR_COLOURS[atlas or ""]
    fill:SetTexture(WHITE)
    if c then fill:SetVertexColor(c[1], c[2], c[3]) end
end

function SK.ColoredBar(bar)
    if not bar or not Once(bar) then return end
    local fill = bar.Fill
    local atlas = fill and fill.GetAtlas and fill:GetAtlas()
    SK.Strip(bar)
    local px = SK.Pixel(bar)
    local b = SK.Backdrop(bar, "panel")
    b:ClearAllPoints()
    b:SetPoint("TOPLEFT", bar, "LEFT", -px, 8)
    b:SetPoint("BOTTOMRIGHT", bar, "RIGHT", px, -8)
    if fill then
        if bar.Mask and fill.RemoveMaskTexture then fill:RemoveMaskTexture(bar.Mask) end
        fill:SetAlpha(1)
        FlatFill(fill, atlas)
        fill:ClearAllPoints()
        fill:SetPoint("TOPLEFT", b, "TOPLEFT", px, -px)
        fill:SetPoint("BOTTOMLEFT", b, "BOTTOMLEFT", px, px)
        if bar.SetFillTextureByColorType then
            hooksecurefunc(bar, "SetFillTextureByColorType", function(self, colorType)
                FlatFill(self.Fill, BAR_BY_TYPE[colorType])
            end)
        end
    end
    if bar.FillArea then
        bar.FillArea:ClearAllPoints()
        bar.FillArea:SetPoint("TOPLEFT", b, "TOPLEFT", px, -px)
        bar.FillArea:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -px, px)
    end
end

-- Round option buttons (UIRadioButtonTemplate): a small flat square, the dot kept.
function SK.Radio(rb)
    if not rb or not Once(rb) then return end
    local checked = rb.GetCheckedTexture and rb:GetCheckedTexture()
    for _, r in ipairs({ rb:GetRegions() }) do
        if r:IsObjectType("Texture") and r ~= checked then r:SetAlpha(0) end
    end
    HideStateTextures(rb)
    if checked then
        checked:SetColorTexture(SK.AccentRGB())
        checked:ClearAllPoints()
        checked:SetPoint("TOPLEFT", 4, -4)
        checked:SetPoint("BOTTOMRIGHT", -4, 4)
    end
    SK.Backdrop(rb, "button", 2, -2, -2, 2)
    SK.Hover(rb)
end

-- Text on a frame itself (not its children) hidden: page buttons that say
-- "Prev" and "Next" beside the arrow.
function SK.HideTexts(frame)
    if not frame then return end
    for _, r in ipairs({ frame:GetRegions() }) do
        if r:IsObjectType("FontString") then r:SetAlpha(0) end
    end
end

-- A collapsible list header (ListHeaderTemplate and friends: reputation,
-- currency): the bar art goes and a flat panel takes its place; the +/- on its
-- right stays, as the plainer square plus and minus.
local inAtlas = false
local function HeaderPlusMinus(tex, atlas)
    if inAtlas then return end
    if atlas ~= "Options_ListExpand_Right" and atlas ~= "Options_ListExpand_Right_Expanded" then return end
    inAtlas = true
    tex:SetAtlas(atlas == "Options_ListExpand_Right" and "Soulbinds_Collection_CategoryHeader_Expand"
                 or "Soulbinds_Collection_CategoryHeader_Collapse", true)
    inAtlas = false
end

function SK.ListHeader(row)
    if not row or not Once(row) then return end
    local keep = {}
    for _, k in ipairs({ "Right", "HighlightRight", "StateIcon" }) do if row[k] then keep[row[k]] = true end end
    SK.Strip(row, keep)
    for _, k in ipairs({ "Right", "HighlightRight" }) do
        local t = row[k]
        if t and t.GetAtlas then
            HeaderPlusMinus(t, t:GetAtlas())
            hooksecurefunc(t, "SetAtlas", HeaderPlusMinus)
        end
    end
    SK.Backdrop(row, "panel", 0, -1, 0, 1)
end

-- Row highlight / selected textures flattened over a row.
function SK.RowHighlights(row, inside)
    local hl = row.GetHighlightTexture and row:GetHighlightTexture() or row.Highlight
    if hl and hl.SetColorTexture then
        hl:SetColorTexture(1, 1, 1, 0.15)
        if inside then hl:SetAllPoints(inside) end
    end
    local sel = row.Selected or row.SelectedTexture
    if sel and sel.SetColorTexture then
        local r, g, b = SK.AccentRGB()
        sel:SetColorTexture(r, g, b, 0.25)
        if inside then sel:SetAllPoints(inside) end
    end
end

-- Rows in a ScrollBox are made and reused as the list scrolls; `fn` runs on
-- each as it appears (once per row frame: fn should use SK.Once).
function SK.EachRow(scrollBox, fn)
    if not scrollBox or not scrollBox.ForEachFrame or not Once(scrollBox) then return end
    -- A list builds its view on first show; until then there is nothing to walk.
    local function Each(sb)
        if sb.GetView and not sb:GetView() then return end
        sb:ForEachFrame(fn)
    end
    hooksecurefunc(scrollBox, "Update", Each)
    Each(scrollBox)
end

-- NavBarTemplate (the dungeon journal's breadcrumb): flat buttons, the
-- home button included, and ones added later.
local function NavButton(btn)
    if not Once(btn) then return end
    for _, r in ipairs({ btn:GetRegions() }) do
        if r:IsObjectType("Texture") then r:SetAlpha(0) end
    end
    HideStateTextures(btn)
    for _, k in ipairs({ "arrowUp", "arrowDown", "selected", "Art" }) do Hide(btn[k]) end
    SK.Backdrop(btn, "button", 0, 0, 0, 0)
    SK.Hover(btn)
    if btn.MenuArrowButton then
        local m = btn.MenuArrowButton
        SK.Strip(m)
        HideStateTextures(m)
        Hide(m.Art)
        local a = m:CreateTexture(nil, "OVERLAY")
        a:SetTexture(SK.ARROW)
        a:SetRotation(ROTATION.down)
        a:SetSize(10, 10)
        a:SetPoint("CENTER")
    end
end

function SK.NavBar(bar)
    if not bar or not Once(bar) then return end
    SK.Strip(bar)
    Hide(bar.overlay)
    Hide(bar.InsetBorderBottomLeft)
    Hide(bar.InsetBorderBottomRight)
    Hide(bar.InsetBorderBottom)
    Hide(bar.InsetBorderLeft)
    Hide(bar.InsetBorderRight)
    if bar.overlay then SK.Strip(bar.overlay) end
    if bar.home then NavButton(bar.home) end
    if bar.overflow then NavButton(bar.overflow) end
    local function Each()
        for _, b in ipairs(bar.navList or {}) do NavButton(b) end
    end
    if NavBar_AddButton then
        hooksecurefunc("NavBar_AddButton", function(self) if self == bar then Each() end end)
    end
    Each()
end

-- Skin every recognised control under `root`. `skip` is a set of frames not
-- to touch or look inside.
function SK.Auto(root, skip, depth)
    if not root or depth == 0 then return end
    depth = depth or 10
    for _, child in ipairs({ root:GetChildren() }) do
        -- Forbidden frames (the trade window's money input) refuse every
        -- call, so neither they nor anything inside them can be touched.
        local forbidden = child.IsForbidden and child:IsForbidden()
        if not forbidden and not (skip and skip[child]) and not painted[child] and not shadowHosts[child] then
            local kind = Kind(child)
            if kind then SK[SKIN[kind]](child) end
            -- A control's own insides are its business.
            if kind ~= "scrollbar" and kind ~= "dropdown" and kind ~= "arrowdropdown" and kind ~= "button" and kind ~= "tab"
               and kind ~= "stepslider" then
                SK.Auto(child, skip, depth - 1)
            end
        end
    end
end

-- Ticks: a flat box, the tick kept.
function SK.Check(cb)
    if not Once(cb) then return end
    local checked = cb.GetCheckedTexture and cb:GetCheckedTexture()
    local disabledChecked = cb.GetDisabledCheckedTexture and cb:GetDisabledCheckedTexture()
    for _, r in ipairs({ cb:GetRegions() }) do
        if r:IsObjectType("Texture") and r ~= checked and r ~= disabledChecked then r:SetAlpha(0) end
    end
    HideStateTextures(cb)
    SK.Backdrop(cb, "button", 4, -4, -4, 4)
    SK.Hover(cb)
end

-- Text boxes (InputBoxTemplate's Left/Middle/Right, or a NineSlice).
function SK.EditBox(eb, x1, y1, x2, y2)
    -- Some boxes are forbidden to addons (the trade window's money input).
    if not eb or (eb.IsForbidden and eb:IsForbidden()) or not Once(eb) then return end
    local name = eb:GetName()
    for _, k in ipairs({ "Left", "Middle", "Right", "Mid", "LeftDisabled", "MiddleDisabled", "RightDisabled" }) do
        Hide(eb[k] or (name and _G[name .. k]))
    end
    Hide(eb.NineSlice)
    SK.Backdrop(eb, "button", x1 or -4, y1 or 0, x2 or 2, y2 or 0)
end

-- The gold / silver / copper boxes.
function SK.MoneyInput(frame)
    if not frame then return end
    for _, k in ipairs({ "gold", "silver", "copper" }) do
        if frame[k] then SK.EditBox(frame[k], -2, 0, -12, 0) end
    end
end

-- WowStyle1DropdownTemplate.
function SK.Dropdown(dd)
    if not Once(dd) then return end
    SK.Strip(dd)
    HideStateTextures(dd)
    KeepStateTexturesHidden(dd)
    Hide(dd.Background)
    Hide(dd.Arrow)
    SK.Backdrop(dd, "button", 0, -2, 0, 2)
    local a = dd:CreateTexture(nil, "OVERLAY")
    a:SetTexture(SK.ARROW)
    a:SetRotation(ROTATION.down)
    a:SetSize(12, 12)
    a:SetPoint("RIGHT", -6, 0)
    SK.Hover(dd)
end

-- A dropdown that is only an arrow (WowStyle1ArrowDropdownTemplate): a
-- small square with the arrow in the middle.
function SK.ArrowDropdown(dd)
    if not Once(dd) then return end
    SK.Strip(dd)
    HideStateTextures(dd)
    KeepStateTexturesHidden(dd)
    Hide(dd.Background)
    Hide(dd.Arrow)
    SK.Backdrop(dd, "button", 2, -2, -2, 2)
    local a = dd:CreateTexture(nil, "OVERLAY")
    a:SetTexture(SK.ARROW)
    a:SetRotation(ROTATION.down)
    a:SetSize(12, 12)
    a:SetPoint("CENTER")
    a:SetVertexColor(0.9, 0.9, 0.9)
    dd:HookScript("OnEnter", function() a:SetVertexColor(SK.AccentRGB()) end)
    dd:HookScript("OnLeave", function() a:SetVertexColor(0.9, 0.9, 0.9) end)
    SK.Hover(dd)
end

-- An icon cropped to its middle with a 1px border; returns the border frame.
function SK.Icon(tex, parentForBorder)
    if not tex then return end
    tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    if parentForBorder == false then return end
    local px = SK.Pixel(tex:GetParent())
    return SK.Backdrop(tex, "none", -px, px, px, -px)
end

-- Item quality on the border instead of Blizzard's IconBorder.
local function QualityBorder(iconBorder, border)
    if not iconBorder or not border then return end
    iconBorder:SetAlpha(0)
    local function Sync()
        if iconBorder:IsShown() then
            local r, g, b = iconBorder:GetVertexColor()
            border:SetBackdropBorderColor(r, g, b)
        else
            border:SetBackdropBorderColor(SK.BorderRGB())
        end
    end
    hooksecurefunc(iconBorder, "SetVertexColor", Sync)
    hooksecurefunc(iconBorder, "Show", Sync)
    hooksecurefunc(iconBorder, "Hide", Sync)
    hooksecurefunc(iconBorder, "SetShown", Sync)
    Sync()
end
SK.QualityBorder = QualityBorder

-- ItemButtonTemplate-style buttons: icon cropped, slot art gone, quality on
-- the border.
function SK.ItemButton(btn)
    if not Once(btn) then return end
    local icon = btn.icon or btn.Icon or (btn:GetName() and _G[btn:GetName() .. "IconTexture"])
    local normal = btn.GetNormalTexture and btn:GetNormalTexture()
    if normal then normal:SetAlpha(0) end
    if btn.SetNormalTexture then hooksecurefunc(btn, "SetNormalTexture", function(self)
        local t = self:GetNormalTexture()
        if t then t:SetAlpha(0) end
    end) end
    local push = btn.GetPushedTexture and btn:GetPushedTexture()
    if push then push:SetColorTexture(1, 1, 1, 0.2) end
    local hl = btn.GetHighlightTexture and btn:GetHighlightTexture()
    if hl then hl:SetColorTexture(1, 1, 1, 0.15) end
    Hide(btn.SlotTexture)
    if icon then
        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        icon:ClearAllPoints()
        local px = SK.Pixel(btn)
        icon:SetPoint("TOPLEFT", px, -px)
        icon:SetPoint("BOTTOMRIGHT", -px, px)
        if push then push:SetAllPoints(icon) end
        if hl then hl:SetAllPoints(icon) end
    end
    local b = SK.Backdrop(btn, "button")
    QualityBorder(btn.IconBorder, b)
    return b
end

-- An item slot with its own mask or empty-slot art (auction house, crafting,
-- socketing): the masks come off before the usual item button treatment.
function SK.Slot(btn)
    if not btn then return end
    local icon = btn.icon or btn.Icon
    for _, k in ipairs({ "IconMask", "CircleMask", "OutlineMask" }) do
        local m = btn[k]
        if m and icon and icon.RemoveMaskTexture then icon:RemoveMaskTexture(m) end
        Hide(m)
    end
    for _, k in ipairs({ "EmptyBackground", "SlotBackground", "CropFrame", "Background", "NameFrame" }) do Hide(btn[k]) end
    return SK.ItemButton(btn)
end

-- The pick-an-icon popup (macros, equipment sets, guild bank tabs): a flat
-- window, flat icon buttons, set beside the window it belongs to.
local function IconButton(button)
    if not Once(button) then return end
    local icon = button.Icon or button.icon
    SK.Strip(button, icon and { [icon] = true } or nil)
    HideStateTextures(button)
    if icon then
        local px = SK.Pixel(button)
        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        icon:ClearAllPoints()
        icon:SetPoint("TOPLEFT", px, -px)
        icon:SetPoint("BOTTOMRIGHT", -px, px)
    end
    local hl = button.GetHighlightTexture and button:GetHighlightTexture()
    if hl then hl:SetAlpha(1); hl:SetColorTexture(1, 1, 1, 0.3); if icon then hl:SetAllPoints(icon) end end
    local ck = button.GetCheckedTexture and button:GetCheckedTexture()
    if ck then ck:SetAlpha(1); ck:SetColorTexture(1, 1, 1, 0.3); if icon then ck:SetAllPoints(icon) end end
    SK.Backdrop(button, "button")
end
function SK.IconSelector(frame, beside)
    if not frame or not Once(frame) then return end
    local box = frame.BorderBox
    SK.Strip(frame)
    if box then
        SK.Strip(box)
        if box.IconTypeDropdown then SK.Dropdown(box.IconTypeDropdown) end
        local area = box.SelectedIconArea
        local sel = area and area.SelectedIconButton
        if sel then
            sel:DisableDrawLayer("BACKGROUND")
            SK.ItemButton(sel)
        end
    end
    SK.Backdrop(frame, "panel")
    SK.Shadow(frame)
    local cancel = frame.CancelButton or (box and box.CancelButton)
    local okay = frame.OkayButton or (box and box.OkayButton)
    if cancel then
        cancel:ClearAllPoints()
        cancel:SetPoint("BOTTOMRIGHT", frame, -4, 4)
        SK.Button(cancel)
    end
    if okay then
        okay:ClearAllPoints()
        if cancel then okay:SetPoint("RIGHT", cancel, "LEFT", -10, 0) end
        SK.Button(okay)
    end
    local eb = (box and box.IconSelectorEditBox) or frame.EditBox
    if eb then
        eb:DisableDrawLayer("BACKGROUND")
        SK.EditBox(eb)
    end
    local sel = frame.IconSelector
    if sel then
        SK.ScrollBar(sel.ScrollBar)
        SK.EachRow(sel.ScrollBox, IconButton)
    end
    -- Blizzard opens it overlapping its window; ElvUI's sits just beside.
    frame:HookScript("OnShow", function(self)
        local point, anchor, rel, x = self:GetPoint()
        if point and (x or 0) <= 0 then
            self:ClearAllPoints()
            self:SetPoint(point, beside or anchor, rel, point:find("LEFT") and 4 or -4, 0)
        end
    end)
end

-- Column headers over a table (auction house lists, crafting orders): each
-- a see-through box, a small gap between neighbours.
function SK.TableHeaders(container)
    if not container then return end
    local kids = { container:GetChildren() }
    for i, h in ipairs(kids) do
        local b = SK.GetBackdrop(h)
        if not b then
            h:DisableDrawLayer("BACKGROUND")
            b = SK.Backdrop(h, "panel")
            local hl = h.GetHighlightTexture and h:GetHighlightTexture()
            if hl then hl:SetColorTexture(1, 1, 1, 0.1); hl:SetAllPoints(b) end
        end
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", h, "TOPLEFT", 0, 0)
        b:SetPoint("BOTTOMRIGHT", h, "BOTTOMRIGHT", i < #kids and -5 or 0, -2)
    end
end

-- A slider with arrows either side (MinimalSliderWithSteppersTemplate, the
-- settings window's): a flat track, a thin thumb, gold up to the thumb.
function SK.StepSlider(frame)
    if not frame or not Once(frame) then return end
    SK.Strip(frame)
    local slider = frame.Slider
    if not slider then return end
    slider:DisableDrawLayer("ARTWORK")
    local thumb = slider.Thumb or (slider.GetThumbTexture and slider:GetThumbTexture())
    if thumb then
        thumb:SetTexture(WHITE)
        thumb:SetVertexColor(1, 1, 1, 0.9)
        thumb:SetSize(4, 12)
    end
    local b = SK.Backdrop(slider, "button", 10, -10, -10, 10)
    if thumb then
        local fill = b:CreateTexture(nil, "ARTWORK")
        fill:SetColorTexture(1, 0.8, 0, 0.5)
        local px = SK.Pixel(slider)
        fill:SetPoint("TOPLEFT", b, "TOPLEFT", px, -px)
        fill:SetPoint("BOTTOMLEFT", b, "BOTTOMLEFT", px, px)
        fill:SetPoint("RIGHT", thumb, "CENTER")
    end
end

-- Status bars: flat fill on a dark track.
function SK.StatusBar(bar, r, g, b)
    if not Once(bar) then return end
    SK.Strip(bar)
    for _, k in ipairs({ "BorderLeft", "BorderRight", "BorderMid", "Border", "BG", "Background", "LeftDivider", "RightDivider" }) do
        Hide(bar[k])
    end
    bar:SetStatusBarTexture(WHITE)
    if r then bar:SetStatusBarColor(r, g, b) end
    local px = SK.Pixel(bar)
    SK.Backdrop(bar, "panel", -px, px, px, -px)
end

-- A whole window: Blizzard's frame furniture away, our see-through panel and
-- shadow in, close button and inset done. Offsets as for Backdrop.
function SK.Window(frame, x1, y1, x2, y2, keep)
    if not frame or not Once(frame) then return end
    SK.Strip(frame, keep)
    SK.Furniture(frame, keep)
    SK.Inset(frame.Inset or (frame:GetName() and _G[frame:GetName() .. "Inset"]))
    local close = frame.CloseButton or (frame:GetName() and _G[frame:GetName() .. "CloseButton"])
    if close then SK.Close(close) end
    SK.Backdrop(frame, "panel", x1, y1, x2, y2)
    SK.Shadow(frame)
end

-- ============================================================================
-- Parchment remover: the game's own Quest Text Contrast, set dark
-- ============================================================================

local DARK = "4"

local function ParchmentActive()
    local s = Settings()
    if not (s.skEnabled and s.skParchment ~= false) then return false end
    -- Only where our quest or gossip skin is the one running.
    return WindowActive(byKey.quest) or WindowActive(byKey.gossip)
end
SK.ParchmentActive = ParchmentActive

local function ApplyParchment()
    local db = SquizzumablesDB
    if not db then return end
    local cur = GetCVar("questTextContrast")
    if ParchmentActive() then
        if cur ~= DARK then
            db.skContrastBefore = cur
            SetCVar("questTextContrast", DARK)
        end
    elseif db.skContrastBefore ~= nil then
        if cur == DARK then SetCVar("questTextContrast", db.skContrastBefore) end
        db.skContrastBefore = nil
    end
end

-- ============================================================================
-- Running the skins
-- ============================================================================

local ran = {}
-- Nothing runs before PLAYER_LOGIN: until then ElvUI may not be loaded, and
-- its skins would look off when they are not.
local loggedIn = false
local pendingCombat = false

local lateRan = {}

local function RunLate(w)
    if not w.late or not ran[w.key] then return end
    for addon, fn in pairs(w.late) do
        local id = w.key .. ":" .. addon
        if not lateRan[id] and C_AddOns.IsAddOnLoaded(addon) then
            lateRan[id] = true
            xpcall(fn, geterrorhandler())
        end
    end
end

local function RunWindow(w)
    if not ran[w.key] then
        if not w.skin or not WindowActive(w) then return end
        if w.addon and not C_AddOns.IsAddOnLoaded(w.addon) then return end
        ran[w.key] = true
        xpcall(w.skin, geterrorhandler())
    end
    RunLate(w)
end

function SK.Run()
    if not loggedIn then return end
    if InCombatLockdown() then
        pendingCombat = true
        return
    end
    for _, w in ipairs(SK.WINDOWS) do RunWindow(w) end
    ApplyParchment()
end

local warned
local function Changed()
    SK.Repaint()
    SK.RepaintTabs()
    ApplyShadows()
    -- Anything newly on goes on now; anything turned off needs a reload.
    local off = false
    for _, w in ipairs(SK.WINDOWS) do
        if ran[w.key] and not WindowActive(w) then off = true end
    end
    if off and not warned then
        warned = true
        print("|cff33cc99Squizzumables:|r a skin that is already on a window comes off after a /reload.")
    end
    SK.Run()
end

-- ============================================================================
-- Settings
-- ============================================================================

local function WindowRows()
    local rows = {
        { type = "text", label = "Each window waits while ElvUI's skin for it is on. Taking a skin off needs a /reload." },
    }
    for _, w in ipairs(SK.WINDOWS) do
        rows[#rows + 1] = { key = "sk_" .. w.key, type = "check", default = true, label = w.label,
                            when = function(s) return s.skEnabled end }
    end
    return rows
end

SK.SETTINGS = ns.Settings.Describe({
    master = "skEnabled",
    apply = Changed,
    pages = {
        { key = "general", label = "General", rows = {
            { key = "skEnabled", type = "check", default = false, label = "Skin Blizzard's Windows",
              tip = "Dark see-through windows with 1px borders and flat buttons, tabs and scroll bars, in place of ElvUI's skins.\n\n"
                  .. "Each window waits while ElvUI's skin for it is on. Taking a skin off needs a /reload." },
            { key = "skParchment", type = "check", default = true, label = "Remove the Parchment",
              tip = "Quest, gossip and book windows lose their parchment and use light text.\n\n"
                  .. "This sets the game's own Quest Text Contrast (Options > Accessibility) to its darkest setting, "
                  .. "so Blizzard recolours the text itself. Your old setting comes back if you turn this off." },
            { key = "skShadow", type = "check", default = true, label = "Soft Shadow Round Windows" },
            { type = "header", label = "COLOURS" },
            { key = "skPanelColor", type = "color", default = { r = 0.06, g = 0.06, b = 0.06 }, label = "Window Background" },
            { key = "skPanelAlpha", type = "slider", default = 80, min = 0, max = 100, step = 5, label = "Window Opacity" },
            { key = "skButtonColor", type = "color", default = { r = 0.1, g = 0.1, b = 0.1 }, label = "Button Background" },
            { key = "skBorderColor", type = "color", default = { r = 0, g = 0, b = 0 }, label = "Borders" },
            { key = "skAccentColor", type = "color", default = { r = 0.09, g = 0.52, b = 0.82 }, label = "Hover and Selected",
              tip = "The border of whatever is under the mouse, the selected tab and scroll bar thumbs." },
        } },
        { key = "windows", label = "Windows", rows = WindowRows() },
    },
})

function BH:BuildSkinsTab(parent)
    ns.Settings.Build(SK.SETTINGS, parent)
end

-- ============================================================================
-- ElvUI's (and WindTools') choices, copied once per profile
-- ============================================================================

local function Copy(c)
    if type(c) ~= "table" or not tonumber(c.r) then return nil end
    return { r = tonumber(c.r), g = tonumber(c.g) or 0, b = tonumber(c.b) or 0 }
end

function SK.Seed()
    if not loggedIn then return end
    local s = BH.settings
    if not s or s.skSeededFromElvUI then return end
    local E = Elv()
    local sk = ElvSkins()
    if not (E and sk) then return end
    s.skSeededFromElvUI = true
    local bl = type(sk.blizzard) == "table" and sk.blizzard or {}
    if bl.enable then s.skEnabled = true end
    for _, w in ipairs(SK.WINDOWS) do
        if bl[w.elv] == false then s["sk_" .. w.key] = false end
    end
    local wt = E.private.WT and E.private.WT.skins
    local wtParch = type(wt) == "table" and wt.enable and wt.removeParchment
    if sk.parchmentRemoverEnable ~= nil or wtParch ~= nil then
        s.skParchment = (sk.parchmentRemoverEnable or wtParch) and true or false
    end
    if type(wt) == "table" and wt.shadow ~= nil then s.skShadow = (wt.enable and wt.shadow) and true or false end
    local g = E.db and E.db.general
    if type(g) == "table" then
        local fade = Copy(g.backdropfadecolor)
        if fade then
            s.skPanelColor = fade
            local a = tonumber(g.backdropfadecolor.a)
            if a then s.skPanelAlpha = math.floor(a * 100 + 0.5) end
        end
        s.skButtonColor = Copy(g.backdropcolor) or s.skButtonColor
        s.skBorderColor = Copy(g.bordercolor) or s.skBorderColor
        s.skAccentColor = Copy(g.valuecolor) or s.skAccentColor
    end
    BH:SaveSettings()
end

-- ============================================================================
-- Events
-- ============================================================================

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_REGEN_ENABLED")
ev:SetScript("OnEvent", function(_, event, a1)
    if event == "PLAYER_LOGIN" then
        loggedIn = true
        SK.Seed()
        SK.Run()
    elseif event == "ADDON_LOADED" then
        if not (BH.settings and loggedIn) then return end
        for _, w in ipairs(SK.WINDOWS) do
            if w.addon == a1 or (w.late and w.late[a1]) then
                if InCombatLockdown() then pendingCombat = true else RunWindow(w) end
            end
        end
    elseif event == "PLAYER_REGEN_ENABLED" then
        if pendingCombat then
            pendingCombat = false
            SK.Run()
        end
    end
end)

-- A profile switch can change any of it.
function BH:ApplySkins()
    SK.Seed()
    Changed()
end
