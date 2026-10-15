-- Group/FeastAnnounce.lua
-- Feast announce: tells the group when you or a groupmate puts down a feast.
--
-- Moved out of Squizzumables.lua unchanged in 2.0 phase 2 (the split), apart
-- from its sound going through BH:PlaySound. The core's event handler and
-- /sq commands reach the lookup through BH (see the end of this file).

local addonName, ns = ...
local BH = ns.BH

-- ============================================================================
-- Feast Announce
-- ============================================================================
-- Item IDs whose "on-use" spell should trigger the feast announce.
-- GetItemSpell() is used at login to resolve the matching spell ID automatically.
-- If auto-detection misses a feast, add its spellID manually to SQ_FEAST_SPELL_OVERRIDES.
local SQ_FEAST_ITEM_IDS = {
    242273,  -- Blooming Feast
    242745,  -- Hearty Blooming Feast
    255846,  -- Harandar Celebration
    266996,  -- Hearty Harandar Celebration
    242272,  -- Quel'dorei Medley
    242744,  -- Hearty Quel'dorei Medley
    255845,  -- Silvermoon Parade
    266985,  -- Hearty Silvermoon Parade
}
-- Manual overrides: [spellID] = "Display Name"
local SQ_FEAST_SPELL_OVERRIDES = {
    -- [999999] = "Some Other Feast",
}
-- Populated at login
local feastSpellLookup = {}

local function BuildFeastSpellLookup()
    wipe(feastSpellLookup)
    for spellID, name in pairs(SQ_FEAST_SPELL_OVERRIDES) do
        feastSpellLookup[spellID] = name
    end
    for _, itemID in ipairs(SQ_FEAST_ITEM_IDS) do
        local itemName = C_Item.GetItemNameByID(itemID)
        local _, spellID = C_Item.GetItemSpell(itemID)
        if spellID and itemName then
            feastSpellLookup[spellID] = itemName
        else
            -- Item data not cached yet; request a load from server so
            -- GET_ITEM_INFO_RECEIVED fires and we can rebuild the lookup.
            C_Item.RequestLoadItemDataByID(itemID)
        end
    end
end

-- Per-spellID throttle: castGUID is a secret value in 12.0 and cannot be used
-- as a table index. Use a timestamp instead to prevent double-firing.
local feastAnnounceCooldowns = {}

--- Returns the best channel string for the current group state.
--- channelDB must be a table with keys: solo, party, instance, raid.
function BH:GetAnnounceChannel(channelDB)
    if not channelDB then return "NONE" end
    if IsPartyLFG() or IsInGroup(LE_PARTY_CATEGORY_INSTANCE) or IsInRaid(LE_PARTY_CATEGORY_INSTANCE) then
        return channelDB.instance or "INSTANCE_CHAT"
    elseif IsInRaid(LE_PARTY_CATEGORY_HOME) then
        return channelDB.raid or "RAID"
    elseif IsInGroup(LE_PARTY_CATEGORY_HOME) then
        return channelDB.party or "PARTY"
    end
    return channelDB.solo or "NONE"
end

-- Placeholders in the player's own announcement text, shared by the feast
-- message and callouts:
--   {name}  this character's name   -- one message reads right on every alt
--   {zone}  the dungeon/raid you are in, else the zone
-- plus per-announcement ones passed in `extra` (e.g. {feast}). Anything
-- else in braces is left exactly as typed: WoW chat already turns {skull},
-- {rt1} and friends into raid-marker icons, and those must survive.
-- A value the game hides (secret) falls back rather than failing the send.
function BH:ExpandPlaceholders(text, extra)
    if type(text) ~= "string" or not text:find("{", 1, true) then return text end
    local S = BH.Secrets
    return (text:gsub("{(%a+)}", function(key)
        local k = key:lower()
        if extra and extra[k] ~= nil then return tostring(extra[k]) end
        if k == "name" then
            return S.SafeString(UnitName("player"), nil) or "I"
        elseif k == "zone" then
            local inInstance = IsInInstance()
            local zone = inInstance and GetInstanceInfo() or GetRealZoneText()
            return S.SafeString(zone, nil) or ""
        end
        return nil -- not ours: keep "{key}" as typed
    end))
end

function BH:OnFeastSpellcast(unit, castGUID, spellID)
    if unit ~= "player" then return end  -- party spellID is fully secret in 12.0+, only player's own is comparable
    if not (self.settings and self.settings.feastAnnounceEnabled) then return end
    if BH.challengeModeActive then return end
    -- spellID is a secret value in 12.0 and cannot be used as a table key.
    -- Use == comparison (allowed) to find a match without indexing.
    local feastName = nil
    for id, name in pairs(feastSpellLookup) do
        if id == spellID then
            feastName = name
            break
        end
    end
    if not feastName then return end
    -- Resolve channel from per-context table (WindTools-style)
    local chanDB = (self.settings and type(self.settings.feastAnnounceChannel) == "table")
        and self.settings.feastAnnounceChannel
        or BH.defaultSettings.feastAnnounceChannel
    local channel = BH:GetAnnounceChannel(chanDB)
    if channel == "NONE" then return end
    -- Use feastName as cooldown key (safe string, not a secret value)
    local now = GetTime()
    if feastAnnounceCooldowns[feastName] and (now - feastAnnounceCooldowns[feastName]) < 10 then return end
    feastAnnounceCooldowns[feastName] = now
    local customText = self.settings and self.settings.feastAnnounceText
    local msg
    if customText and customText ~= "" then
        -- {name}, {zone} and {feast}: see BH:ExpandPlaceholders.
        msg = BH:ExpandPlaceholders(customText, { feast = feastName })
    else
        msg = "Fresh off the Barbie, no Crocs were harmed in the making of this " .. feastName .. "... I think."
    end
    C_ChatInfo.SendChatMessage(msg, channel)
    -- Broadcast to other Squizzumables users so they can play a sound alert.
    -- The echo back to ourselves also triggers our own sound via CHAT_MSG_ADDON.
    C_ChatInfo.SendAddonMessage("SQ_FEAST", feastName, channel)
end

function BH:OnFeastAddonMessage(feastName)
    -- Mark the cooldown so our party-watch handler doesn't double-announce
    -- when the feast caster also has the addon and already announced.
    feastAnnounceCooldowns[feastName] = GetTime()
    if BH.challengeModeActive then return end
    local snd = self.settings and self.settings.feastAlertSound or "None"
    if snd and snd ~= "None" then
        BH:PlaySound(snd)
    end
end

-- For the core's event handler and /sq diagnostics. feastSpellLookup is only
-- ever wiped and refilled, never replaced, so handing out the table is safe.
BH.FEAST_ITEM_IDS        = SQ_FEAST_ITEM_IDS
BH.feastSpellLookup      = feastSpellLookup
BH.BuildFeastSpellLookup = BuildFeastSpellLookup
