-- Tweaks/MailContacts.lua
-- A list beside the mail window's Send tab: your other characters, online
-- friends, guild members and favourites. Click a name to address the letter
-- to them; right-click to add or remove a favourite (or forget an alt).
--
-- Settings live on the Tweaks page (twMail, twMailPage). Your characters and
-- favourites are account-wide (SquizzumablesDB.mailAlts / .mailFavorites).
-- WindTools' lists are copied over once (SquizzumablesDB.mailSeededFromWT),
-- and the list waits while WindTools' own Contacts is on. Written from what
-- WindTools' feature does, never from its code.

local addonName, ns = ...
local BH = ns.BH

local MC = {}
ns.MailContacts = MC

local ROWS = 14
local ROW_H = 20

local function Settings() return BH.settings or {} end

local function WT()
    if not C_AddOns.IsAddOnLoaded("ElvUI_WindTools") then return nil end
    local elv = _G["ElvUI"]
    local E = type(elv) == "table" and elv[1]
    return E
end

local function WTDoes()
    local E = WT()
    local db = E and E.db and E.db.WT and E.db.WT.item and E.db.WT.item.contacts
    return type(db) == "table" and db.enable and true or false
end

local function Active()
    return Settings().twMail and not WTDoes()
end

-- ============================================================================
-- Storage
-- ============================================================================

local function DB()
    if not SquizzumablesDB then return nil end
    SquizzumablesDB.mailAlts = SquizzumablesDB.mailAlts or {}
    SquizzumablesDB.mailFavorites = SquizzumablesDB.mailFavorites or {}
    return SquizzumablesDB
end

local MY_REALM

-- Realm names as the mail box wants them ("Moon Guard" -> "MoonGuard").
local function Norm(realm)
    return type(realm) == "string" and (realm:gsub("[%s%-]", "")) or realm
end

local function SeedFromWT()
    local db = DB()
    if not db or db.mailSeededFromWT then return end
    local E = WT()
    local g = E and E.global and E.global.WT and E.global.WT.item and E.global.WT.item.contacts
    if type(g) ~= "table" then return end
    db.mailSeededFromWT = true
    for realm, factions in pairs(type(g.alts) == "table" and g.alts or {}) do
        for faction, chars in pairs(type(factions) == "table" and factions or {}) do
            for name, class in pairs(type(chars) == "table" and chars or {}) do
                if type(name) == "string" and name ~= UNKNOWNOBJECT then
                    local key = "wt:" .. name .. "-" .. Norm(realm)
                    db.mailAlts[key] = db.mailAlts[key] or { name = name, realm = Norm(realm), class = class, faction = faction }
                end
            end
        end
    end
    for full, on in pairs(type(g.favorites) == "table" and g.favorites or {}) do
        local name, realm
        if type(full) == "string" then name, realm = full:match("^([^%-]+)%-(.+)$") end
        if on and name then db.mailFavorites[name .. "-" .. Norm(realm)] = true end
    end
end

-- An empty realm (WindTools stored some that way on WoW Forever) is ours.
-- WoW Forever reports no realm name at all (GetRealmName() is ""), so there
-- every stored realm counts as ours too: it has one realm to mail on.
local function RealmOf(realm)
    if realm == nil or realm == "" or MY_REALM == nil or MY_REALM == "" or BH.IS_FOREVER then
        return MY_REALM or ""
    end
    return Norm(realm)
end

-- The character's whole name. On WoW Forever UnitName's second return is the
-- SURNAME, and both halves make the name ("Squizz Snagsizzler").
local function MyName()
    local name, surname = UnitName("player")
    if not name or name == UNKNOWNOBJECT then return nil end
    -- On retail the second return is a realm, and only for other realms'
    -- players, never for "player"; Forever is the client with surnames.
    if BH.IS_FOREVER and type(surname) == "string" and surname ~= "" and surname ~= MY_REALM
        and Constants and Constants.CharacterNameSeparatorConsts then
        return name .. Constants.CharacterNameSeparatorConsts.CHARACTERNAME_SURNAME_SEPARATOR .. surname
    end
    return name
end

-- One key per person: name and realm, case-insensitive.
local function PersonKey(name, realm)
    return (name or ""):lower() .. "-" .. RealmOf(realm):lower()
end

-- This character, keyed by GUID (on WoW Forever a name can repeat).
local function RecordMe()
    local db, guid = DB(), UnitGUID("player")
    if not (db and guid) then return end
    local name = MyName()
    if not name then return end
    local _, class = UnitClass("player")
    db.mailAlts[guid] = { name = name, realm = MY_REALM, class = class, faction = UnitFactionGroup("player") }
    -- Every copy WindTools made of this character (with and without a realm)
    -- is now the same one.
    local me = PersonKey(name, MY_REALM)
    for key, a in pairs(db.mailAlts) do
        if key ~= guid and type(key) == "string" and key:find("^wt:") and PersonKey(a.name, a.realm) == me then
            db.mailAlts[key] = nil
        end
    end
end

-- ============================================================================
-- Lists
-- ============================================================================

local function SplitName(full)
    if type(full) ~= "string" then return nil end
    local name, realm = full:match("^([^%-]+)%-(.+)$")
    return name or full, Norm(realm) or MY_REALM
end

local function ClassOf(localized)
    for file, l in pairs(LOCALIZED_CLASS_NAMES_MALE or {}) do if l == localized then return file end end
    for file, l in pairs(LOCALIZED_CLASS_NAMES_FEMALE or {}) do if l == localized then return file end end
    return nil
end

local function Alts()
    local out, db = {}, DB()
    local guid = UnitGUID("player")
    local myName = MyName()
    -- One row per person, never this character. A GUID entry (recorded by
    -- us) wins over a copy taken from WindTools.
    local seen = {}
    if myName then seen[PersonKey(myName, MY_REALM)] = "me" end
    local keys = {}
    for key in pairs(db and db.mailAlts or {}) do keys[#keys + 1] = key end
    table.sort(keys, function(a, b)
        local wa, wb = a:find("^wt:") ~= nil, b:find("^wt:") ~= nil
        if wa ~= wb then return wb end
        return a < b
    end)
    for _, key in ipairs(keys) do
        local a = db.mailAlts[key]
        local pk = a and a.name and PersonKey(a.name, a.realm)
        if pk and key ~= guid and not seen[pk] then
            seen[pk] = true
            out[#out + 1] = { name = a.name, realm = RealmOf(a.realm), class = a.class, faction = a.faction, alt = key }
        end
    end
    return out
end

local function Friends()
    local out, seen = {}, {}
    for i = 1, C_FriendList.GetNumOnlineFriends() or 0 do
        local info = C_FriendList.GetFriendInfoByIndex(i)
        if info and info.connected and info.name then
            local name, realm = SplitName(info.name)
            out[#out + 1] = { name = name, realm = realm, class = ClassOf(info.className) }
            seen[name .. "-" .. realm] = true
        end
    end
    local myFaction = UnitFactionGroup("player")
    local _, online = BNGetNumFriends()
    for i = 1, online or 0 do
        local acct = C_BattleNet.GetFriendAccountInfo(i)
        for j = 1, (acct and C_BattleNet.GetFriendNumGameAccounts(i)) or 0 do
            local g = C_BattleNet.GetFriendGameAccountInfo(i, j)
            local realm = g and Norm(g.realmName)
            if g and g.isOnline and g.clientProgram == BNET_CLIENT_WOW and g.wowProjectID == WOW_PROJECT_ID
                and g.characterName and realm and (not g.factionName or g.factionName == myFaction)
                and not seen[g.characterName .. "-" .. realm] then
                seen[g.characterName .. "-" .. realm] = true
                out[#out + 1] = { name = g.characterName, realm = realm, class = ClassOf(g.className),
                    bnet = acct.accountName }
            end
        end
    end
    return out
end

local function Guild()
    local out = {}
    if not IsInGuild() then return out end
    local me = MyName()
    for i = 1, GetNumGuildMembers() or 0 do
        local full, _, _, _, _, _, _, _, _, _, class = GetGuildRosterInfo(i)
        local name, realm = SplitName(full)
        if name and not (name == me and RealmOf(realm) == RealmOf(MY_REALM)) then
            out[#out + 1] = { name = name, realm = realm, class = class }
        end
    end
    return out
end

local function Favourites()
    local out, db = {}, DB()
    for full in pairs(db and db.mailFavorites or {}) do
        local name, realm = SplitName(full)
        if name then out[#out + 1] = { name = name, realm = realm, fav = full } end
    end
    return out
end

local CATEGORIES = {
    { key = "ALTS", label = "Alts", build = Alts },
    { key = "FRIENDS", label = "Friends", build = Friends },
    { key = "GUILD", label = "Guild", build = Guild },
    { key = "FAVORITE", label = "Favs", build = Favourites },
}

-- ============================================================================
-- The frame
-- ============================================================================

local frame, toggle
local list, page, category = {}, 1, nil

local function Pages() return math.max(1, math.ceil(#list / ROWS)) end

local function Address(entry)
    local box = _G.SendMailNameEditBox
    if not box then return end
    local target = entry.name
    if RealmOf(entry.realm) ~= RealmOf(MY_REALM) then target = target .. "-" .. RealmOf(entry.realm) end
    box:SetText(target)
    box:SetCursorPosition(#target)
end

local function Draw()
    if not frame then return end
    page = math.max(1, math.min(page, Pages()))
    for i = 1, ROWS do
        local row, entry = frame.rows[i], list[(page - 1) * ROWS + i]
        row.entry = entry
        if entry then
            local c = entry.class and C_ClassColor.GetClassColor(entry.class)
            row.text:SetText(entry.name)
            if c then row.text:SetTextColor(c.r, c.g, c.b) else row.text:SetTextColor(1, 1, 1) end
            row:Show()
        else
            row:Hide()
        end
    end
    frame.pageText:SetText(#list == 0 and "Nobody here" or (page .. " / " .. Pages()))
    frame.prev:SetEnabled(page > 1)
    frame.next:SetEnabled(page < Pages())
    for _, tab in ipairs(frame.tabs) do
        local r, g, b = ns.Theme.RGBA(tab.key == category and "accent" or "textDim")
        tab.text:SetTextColor(r, g, b)
    end
end

local function SortByName(a, b)
    if a.name == b.name then return (a.realm or "") < (b.realm or "") end
    return a.name < b.name
end

function MC.Show(key)
    category = key or category or Settings().twMailPage or "ALTS"
    list = {}
    for _, c in ipairs(CATEGORIES) do
        if c.key == category then list = c.build() end
    end
    table.sort(list, SortByName)
    page = 1
    Draw()
end

local function Menu(row)
    local e = row.entry
    if not (e and MenuUtil and MenuUtil.CreateContextMenu) then return end
    MenuUtil.CreateContextMenu(row, function(_, root)
        root:CreateTitle(e.name .. (RealmOf(e.realm) ~= RealmOf(MY_REALM) and ("-" .. RealmOf(e.realm)) or ""))
        local db = DB()
        if not db then return end
        local full = e.name .. "-" .. (e.realm or MY_REALM)
        if db.mailFavorites[full] then
            root:CreateButton("Remove From Favourites", function()
                db.mailFavorites[full] = nil
                MC.Show()
            end)
        else
            root:CreateButton("Add To Favourites", function() db.mailFavorites[full] = true end)
        end
        if e.alt then
            root:CreateButton("Forget This Character", function()
                -- Every stored copy of them, not just the one the row shows.
                local pk = PersonKey(e.name, e.realm)
                for key, a in pairs(db.mailAlts) do
                    if a.name and PersonKey(a.name, a.realm) == pk then db.mailAlts[key] = nil end
                end
                MC.Show()
            end)
        end
    end)
end

local function Tooltip(row)
    local e = row.entry
    if not e then return end
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:SetText(e.name)
    if e.realm then GameTooltip:AddDoubleLine("Realm", e.realm, 1, 1, 1, 1, 1, 1) end
    if e.bnet then GameTooltip:AddDoubleLine("Battle.net", e.bnet, 1, 1, 1, 0.51, 0.77, 1) end
    if e.faction then GameTooltip:AddDoubleLine("Faction", e.faction, 1, 1, 1, 1, 1, 1) end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Click: send to them. Right-click: favourites.", 0.7, 0.7, 0.7)
    GameTooltip:Show()
end

local function SmallButton(parent, label, w)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(w, 18)
    b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.text:SetPoint("CENTER")
    b.text:SetText(label)
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.08)
    return b
end

local function Build()
    if frame or not _G.SendMailFrame then return end
    frame = CreateFrame("Frame", "SquizzumablesMailContacts", _G.SendMailFrame, "BackdropTemplate")
    frame:SetPoint("TOPLEFT", _G.MailFrame, "TOPRIGHT", 3, 0)
    frame:SetPoint("BOTTOMLEFT", _G.MailFrame, "BOTTOMRIGHT", 3, 0)
    frame:SetWidth(156)
    frame:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
    frame:SetBackdropColor(0.06, 0.06, 0.06, 0.9)
    frame:SetBackdropBorderColor(0, 0, 0, 1)
    frame:EnableMouse(true)
    frame:EnableMouseWheel(true)
    frame:SetScript("OnMouseWheel", function(_, delta)
        page = page - delta
        Draw()
    end)

    frame.tabs = {}
    for i, c in ipairs(CATEGORIES) do
        local tab = SmallButton(frame, c.label, 36)
        tab.key = c.key
        tab:SetPoint("TOPLEFT", frame, "TOPLEFT", 4 + (i - 1) * 37, -6)
        tab:SetScript("OnClick", function() MC.Show(c.key) end)
        frame.tabs[i] = tab
    end

    frame.rows = {}
    for i = 1, ROWS do
        local row = CreateFrame("Button", nil, frame)
        row:SetSize(146, ROW_H)
        row:SetPoint("TOP", frame, "TOP", 0, -30 - (i - 1) * (ROW_H + 2))
        row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        local bg = row:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(1, 1, 1, 0.04)
        local hl = row:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(1, 1, 1, 0.1)
        row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.text:SetPoint("LEFT", 6, 0)
        row.text:SetPoint("RIGHT", -6, 0)
        row.text:SetJustifyH("LEFT")
        row:SetScript("OnClick", function(_, mouse)
            if not row.entry then return end
            if mouse == "RightButton" then Menu(row) else Address(row.entry) end
        end)
        row:SetScript("OnEnter", Tooltip)
        row:SetScript("OnLeave", GameTooltip_Hide)
        frame.rows[i] = row
    end

    frame.prev = SmallButton(frame, "<", 20)
    frame.prev:SetPoint("BOTTOMLEFT", 6, 6)
    frame.prev:SetScript("OnClick", function() page = page - 1; Draw() end)
    frame.next = SmallButton(frame, ">", 20)
    frame.next:SetPoint("BOTTOMRIGHT", -6, 6)
    frame.next:SetScript("OnClick", function() page = page + 1; Draw() end)
    frame.pageText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.pageText:SetPoint("BOTTOM", 0, 10)

    -- Opens and closes the list; the choice is kept (twMailHidden).
    toggle = SmallButton(_G.SendMailFrame, "Contacts", 64)
    toggle:SetPoint("BOTTOMRIGHT", _G.MailFrame, "BOTTOMRIGHT", -8, 30)
    toggle:SetFrameLevel(_G.SendMailFrame:GetFrameLevel() + 10)
    toggle:SetScript("OnClick", function()
        local s = BH.settings
        if not s then return end
        s.twMailHidden = frame:IsShown() and true or nil
        BH:SaveSettings()
        frame:SetShown(not s.twMailHidden)
    end)

    _G.SendMailFrame:HookScript("OnShow", function() MC.Apply() end)
end

function MC.Apply()
    if not Active() then
        if frame then frame:Hide() end
        if toggle then toggle:Hide() end
        return
    end
    Build()
    if not frame then return end
    toggle:Show()
    local open = not Settings().twMailHidden
    frame:SetShown(open)
    if open and _G.SendMailFrame:IsVisible() then
        category = nil
        MC.Show()
    end
end

-- ============================================================================
-- Events
-- ============================================================================

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("MAIL_SHOW")
ev:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        MY_REALM = GetNormalizedRealmName() or GetRealmName()
        SeedFromWT()
        RecordMe()
    else
        if not MY_REALM or MY_REALM == "" then MY_REALM = GetNormalizedRealmName() or GetRealmName() end
        -- ElvUI may set up after our login handler; the name is not always
        -- known at login on a fresh character either.
        SeedFromWT()
        RecordMe()
        MC.Apply()
    end
end)
