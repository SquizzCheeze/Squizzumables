-- Cooldowns/Discovery.lua
-- Which cooldowns exist: BlizzardFilteredIDs (the player's Cooldown Manager
-- filter, read without running any Blizzard Lua -- read its comment before
-- changing it) and DiscoverCooldowns, the pure C_CooldownViewer pass the
-- reconcile loop builds from.
--
-- Moved out of Squizzumables_CDM.lua unchanged in 2.0 phase 2 (the split).
-- That file still calls both functions (the event handler, the shared table),
-- so it keeps a forwarder for each and this file fills in the table they
-- forward to (cdmModule.discovery, bottom of this file). DISCOVER_CATEGORIES
-- stays there, since the event handler reads it too, and comes in through
-- cdmModule.shared. Nothing calls into this file while loading.

local addonName, ns = ...
local BH = ns.BH

local cdmModule = BH.cdm
local shared    = cdmModule.shared

local DISCOVER_CATEGORIES = shared.DISCOVER_CATEGORIES


-- The player's Cooldown Manager filter, read WITHOUT running any Blizzard Lua.
--
-- READ THIS BEFORE CHANGING IT. There is a way to get this list that looks far
-- more obvious and is catastrophic; it shipped in 1.70 and took three versions
-- to find.
--
-- What the player arranges in Blizzard's Cooldown Manager -- what is hidden,
-- what order things sit in, which trinkets they dragged onto a bar -- exists
-- only in a saved layout. No C_CooldownViewer function exposes it.
-- `GetCooldownViewerCategorySet` returns the raw default set for a category and
-- knows nothing about any of it: hidden entries are moved to the
-- pseudo-categories `HiddenActive` (-1) / `HiddenPassive` (-2), entries flagged
-- `HideByDefault` go the same way before the player has touched anything, and
-- equip-slot entries live in categories that have no viewer at all.
--
-- THE TRAP: `viewer:GetCooldownIDs()` returns exactly the list we want. It is
-- also Lua, so it runs on OUR stack --
-- `CooldownViewerSettings:GetDataProvider():GetOrderedCooldownIDsForCategory()`
-- and through it `CheckBuildDisplayData()`, which REBUILDS `displayData`. Every
-- table it writes is tainted by us from that moment. `/sq cdmtaint` measured it
-- on a live client:
--
--     data provider:    displayData<-Squizzumables
--     display data:     orderedCooldownIDs<-Squizzumables
--                       cooldownInfoByID<-Squizzumables
--                       defaultOrderedCooldownIDs<-Squizzumables
--     first item frame: cooldownID<-Squizzumables
--
-- Those tables are the Cooldown Manager's spine, so afterwards every Blizzard
-- path that read them ran tainted too. One Mythic+ session produced thousands
-- of errors inside Blizzard's own CheckAuraAddedAlertTriggers, RefreshTotemData,
-- GetUnitAuras, CacheChargeValues and ShouldDisplaySpellCooldown -- all their
-- code, all blamed on this addon, none with any of our frames in the traceback.
-- It survived reloads because we re-tainted within seconds of login.
--
-- The reasoning that let it ship: the comment here used to argue the call was
-- safe because no C_CooldownViewer function carries `HasRestrictions`. That flag
-- governs whether a PROTECTED CALL IS REFUSED. It says nothing about TAINT
-- SPREAD, which happens by execution. Two mechanisms, conflated, and the
-- conflation then cited as prior verification. Do not reason from flags here;
-- measure with /sq cdmtaint.
--
-- THE WAY THAT WORKS: do not ask for the list. Blizzard already asked, on its
-- own clean stack, and left the answer lying on the item frames.
--
--     function CooldownViewerMixin:RefreshLayout(cooldownIDs)
--         self.itemFramePool:ReleaseAll();
--         cooldownIDs = cooldownIDs or self:GetCooldownIDs();
--         for i = 1, self:GetItemCount(cooldownIDs) do
--             local itemFrame = self.itemFramePool:Acquire();
--             itemFrame.layoutIndex = i;
--
-- and `RefreshData` then sets each frame's `cooldownID` from `cooldownIDs[layoutIndex]`.
-- So `cooldownID` and `layoutIndex` on the pooled frames ARE the filtered,
-- ordered list -- membership, order, trinkets and all. Reading two plain fields
-- executes no Blizzard Lua and taints nothing. Confirmed against
-- Gethe/wow-ui-source live.
--
-- Three details that make this correct rather than nearly-correct:
--
-- 1. HIDDEN IS NOT RELEASED. A cooldown hidden by Blizzard's own "hide when
--    inactive" keeps its pool frame and is merely not shown; frames are only
--    released wholesale by the next RefreshLayout. So this must enumerate the
--    POOL, never the shown children -- `GetChildren()` or a `:IsShown()` filter
--    would silently drop every inactive cooldown, and only for players using
--    that Blizzard setting. An earlier attempt at this feature did exactly that.
--
-- 2. THE POOL IS PADDED. `GetItemCount` enforces `minimumItemCount = 2`, so a
--    category with fewer than two entries still acquires two frames. Blizzard
--    calls `ClearCooldownID()` on the surplus, so they read nil and skip
--    themselves -- which is why this tests `cooldownID` rather than trusting
--    `layoutIndex` to be dense.
--
-- 3. IT IS LAZY. The pool is empty until Blizzard has built the viewer, which
--    is well after our first discovery pass at login. An empty answer means
--    "not built yet", NOT "the player hid everything", so it falls back to the
--    raw category set. Nothing has to be hooked to recover: `CooldownSetSignature`
--    hashes this list too, so when the pool fills, the signature changes and the
--    standing 2s ticker's `CheckCooldownSetChanged` reconciles. The same path
--    covers the player editing Blizzard's Cooldown Manager options -- that
--    rebuilds the viewer, which changes this list, which changes the signature.
--
--    That costs up to two seconds on a settings edit, and a `hooksecurefunc` on
--    `itemFramePool.Acquire` would make it instant. Deliberately not done: it
--    puts our code inside Blizzard's RefreshLayout call chain, which is the
--    exact neighbourhood that cost 1.70 through 1.72, to save two seconds on a
--    screen the player is already looking at. `hooksecurefunc` is in fact the
--    safe mechanism -- it saves and restores taint around the hook, which is why
--    the item-frame hooks elsewhere in this file measure clean, and it is not
--    the same thing as inserting a closure into a `CallbackRegistry` that
--    Blizzard iterates in a plain loop. Safe and worth it are different
--    questions, and the answer to the second one here is no.
--
-- EllesmereUI reaches the same place from the other end: it re-anchors
-- Blizzard's item frames onto its own bars and parks the rest offscreen, so its
-- filtering is perfect because it never filters -- Blizzard decides which frames
-- exist and it only moves them. That also works, and it is what our Buffs group
-- does; the cost is that Blizzard's icons cannot carry our per-group border,
-- zoom, shape and text styling, which is why the cooldown groups proxy instead.
local function BlizzardFilteredIDs(viewerGlobal)
    local viewer = viewerGlobal and _G[viewerGlobal]
    if type(viewer) ~= "table" then return nil end

    local pool = viewer.itemFramePool
    if type(pool) ~= "table" or type(pool.EnumerateActive) ~= "function" then
        return nil
    end

    -- pcall only because EnumerateActive is Blizzard's iterator and the pool may
    -- not be initialised on an early login. Nothing inside the loop can throw:
    -- both reads are plain field access on a frame.
    local entries = {}
    local ok = pcall(function()
        for item in pool:EnumerateActive() do
            local cdID = item.cooldownID
            local index = item.layoutIndex
            if type(cdID) == "number" and type(index) == "number" then
                entries[#entries + 1] = { id = cdID, index = index }
            end
        end
    end)
    if not ok or #entries == 0 then return nil end

    -- By layoutIndex, which is the player's own arrangement. EnumerateActive
    -- walks a hash table, so its order is arbitrary and would reshuffle our
    -- icons on every pass without this.
    table.sort(entries, function(a, b) return a.index < b.index end)

    local ids, seen = {}, {}
    for _, entry in ipairs(entries) do
        if not seen[entry.id] then
            seen[entry.id] = true
            ids[#ids + 1] = entry.id
        end
    end
    return ids
end

-- Whether the last discovery pass managed to read the pool, per viewer.
-- Reported by /sq cdm: "our groups show more than Blizzard's bars" and "the
-- filter is being honoured but the player hid nothing" look identical on
-- screen, and only this tells them apart.
cdmModule.usedBlizzardFilter = {}

local function DiscoverCooldowns()
    local discovered = {}
    -- Buff entries dropped as duplicates of a cooldown (see below). Kept out of
    -- the registry, but returned: Blizzard still shows them on its buff bar,
    -- so the native buff slots need one for each or they stay Blizzard frames
    -- in the middle of a row of ours.
    local buffExtras = {}
    -- One ability, two categories.
    --
    -- The same ability is listed under a cooldown category for its cooldown and
    -- a buff category for the aura it applies, under DIFFERENT cooldownIDs AND
    -- different spellIDs -- Blessing of Freedom is 61107 in Utility and 92824
    -- in BuffIcon. Nothing keyed on either ID catches that, so the buff pass
    -- brought a second copy of half the Essential and Utility abilities into
    -- the Buffs group. Name is the only thing they share, which is why
    -- GetAvailableBuffCooldowns has always deduplicated on it too.
    --
    -- DISCOVER_CATEGORIES is ordered cooldowns first, so the cooldown-type
    -- entry wins and the buff duplicate is dropped: the cooldown item is the
    -- one that carries the cooldown fields, and a buff item leaves them nil
    -- forever.
    -- Only across the cooldown/buff divide, NEVER within a category.
    --
    -- A spec legitimately tracks several variants of one ability under the same
    -- name: a hunter has four separate "Howl of the Pack Leader" buff entries
    -- (cooldownIDs 9712, 9713, 9714, 169029). Deduplicating on name across the
    -- board collapsed all four into one and silently dropped most of the buffs
    -- the player was tracking. Only a buff entry that duplicates a
    -- cooldown-type entry is a real duplicate.
    --
    -- Only Essential and Utility are the cooldown side of that divide. This
    -- was `viewerType ~= "buff"` until 1.76, written before 1.74 split tracked
    -- bars out as "buffbar" -- which silently put the bars on the cooldown
    -- side too, so a buff icon sharing a name with a tracked bar was dropped
    -- as a "duplicate" of it.
    local seenCdSpell, seenCdName = {}, {}
    for _, viewerInfo in ipairs(DISCOVER_CATEGORIES) do
        local isCooldownType = (viewerInfo.viewerType == "cooldown"
                                or viewerInfo.viewerType == "utility")

        -- What Blizzard actually put on its own bar, read off the item frames.
        -- The raw category set only when the pool cannot answer, which means
        -- the viewer has not been built yet -- see the note above.
        local catIDs = BlizzardFilteredIDs(viewerInfo.viewer)
        cdmModule.usedBlizzardFilter[viewerInfo.viewer] = (catIDs ~= nil)
        if not catIDs then
            catIDs = C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCategorySet
                and C_CooldownViewer.GetCooldownViewerCategorySet(viewerInfo.category)
        end

        if catIDs then
            for orderIndex, cdID in ipairs(catIDs) do
                local info = C_CooldownViewer.GetCooldownViewerCooldownInfo(cdID)
                if info and info.isKnown then
                    -- spellID is nilable as of 12.1 and really is absent on the
                    -- equip-slot entries (a trinket is identified by its
                    -- inventory slot, not a spell), which the filtered list can
                    -- now hand us. Every use of it below is guarded because
                    -- `seenCdSpell[nil] = true` is not a silent no-op -- it is
                    -- a hard "table index is nil" error that would take the
                    -- whole discovery pass down.
                    local spellID   = info.spellID
                    -- equipSlot is real on 12.1 (Blizzard's own item mixin
                    -- drives a trinket's entire cooldown off it) but the
                    -- language server's bundled annotations predate it, the
                    -- same lag that makes them wrong about spellID being
                    -- non-nilable. Confirmed in Blizzard's generated docs on
                    -- Gethe/wow-ui-source live, 12.1.0 build 69587.
                    ---@diagnostic disable-next-line: undefined-field
                    local equipSlot = info.equipSlot
                    local name = spellID and C_Spell.GetSpellName
                        and C_Spell.GetSpellName(spellID)
                    name = BH.Secrets.SafeString(name, nil)
                    local isDuplicate = (not isCooldownType)
                        and ((spellID and seenCdSpell[spellID])
                             or (name and seenCdName[name]))
                    -- A cooldown-type entry is never a duplicate, so this is
                    -- exactly the old "recorded only when kept" behaviour.
                    if isCooldownType then
                        if spellID then seenCdSpell[spellID] = true end
                        if name then seenCdName[name] = true end
                    end

                    do
                        -- Which spell IDs might carry this cooldown's aura.
                        --
                        -- A tracked buff's aura is very often NOT info.spellID:
                        -- the API hands the alternatives over as overrideSpellID
                        -- and linkedSpellIDs. Reading only spellID is why buff
                        -- icons drew no duration swipe -- the aura lookup missed
                        -- and it fell through to a spell cooldown that a
                        -- buff-only entry does not have.
                        local auraIDs = {}
                        if spellID then auraIDs[#auraIDs + 1] = spellID end
                        if info.overrideSpellID then
                            auraIDs[#auraIDs + 1] = info.overrideSpellID
                        end
                        -- overrideTooltipSpellID deliberately NOT added here.
                        -- Blizzard's GetSpellID prefers it, but this list is
                        -- also what the tracked-buff duration lookup walks, and
                        -- a tooltip override is a display alias rather than a
                        -- promise that an aura exists under that ID. Widening
                        -- it risks the 1.69 buff swipe binding to the wrong
                        -- aura, for no gain: the override and linked IDs below
                        -- already cover the forms a proc actually fires on.
                        if type(info.linkedSpellIDs) == "table" then
                            for _, lid in ipairs(info.linkedSpellIDs) do
                                auraIDs[#auraIDs + 1] = lid
                            end
                        end

                        local record = {
                            cooldownID = cdID,
                            spellID = spellID,
                            equipSlot = equipSlot,
                            viewerType = viewerInfo.viewerType,
                            auraIDs = auraIDs,
                            hasAura = info.hasAura,
                            -- For the native buff slots: which unit the aura
                            -- sits on, and the tooltip override Blizzard's own
                            -- buff item matches as well (kept out of auraIDs
                            -- for the reason given above).
                            selfAura = info.selfAura,
                            tooltipSpellID = info.overrideTooltipSpellID,
                            -- Blizzard's own ordering, so the default
                            -- "assignment" sort lays a group out the way the
                            -- player arranged the matching Blizzard bar.
                            order = orderIndex,
                        }
                        if isDuplicate then
                            buffExtras[cdID] = record
                        else
                            discovered[cdID] = record
                        end
                    end
                end
            end
        end
    end

    -- A trinket's Essential/Utility entry may not know which aura it applies.
    --
    -- Blizzard fills linkedSpellIDs for the TRACKED equip-slot entry (the buff
    -- bar's), which is how the Vile Vial of Volatile Venom showed its buff there
    -- and nowhere on its Essential icon (user report 2026-09-22): "Show While
    -- Active" matches the aura by these IDs, and the Essential entry carried
    -- none that matched. So an equip-slot cooldown entry also takes the aura IDs
    -- of every buff entry on the same slot, plus the item's own use spell,
    -- which is usually the buff it applies.
    local trackedBySlot = {}
    local function CollectTracked(records)
        for _, r in pairs(records) do
            if r.equipSlot and (r.viewerType == "buff" or r.viewerType == "buffbar") then
                local ids = trackedBySlot[r.equipSlot] or {}
                trackedBySlot[r.equipSlot] = ids
                for _, id in ipairs(r.auraIDs) do ids[#ids + 1] = id end
            end
        end
    end
    CollectTracked(discovered)
    CollectTracked(buffExtras)
    for _, r in pairs(discovered) do
        if r.equipSlot and (r.viewerType == "cooldown" or r.viewerType == "utility") then
            local seen = {}
            for _, id in ipairs(r.auraIDs) do seen[id] = true end
            local function Add(id)
                id = BH.Secrets.SafeNumber(id, nil)
                if id and id > 0 and not seen[id] then
                    seen[id] = true
                    r.auraIDs[#r.auraIDs + 1] = id
                end
            end
            for _, id in ipairs(trackedBySlot[r.equipSlot] or {}) do Add(id) end
            local itemID = GetInventoryItemID("player", r.equipSlot)
            if itemID and C_Item and C_Item.GetItemSpell then
                local _, useSpellID = C_Item.GetItemSpell(itemID)
                Add(useSpellID)
            end
        end
    end
    return discovered, buffExtras
end

-- What Squizzumables_CDM.lua's forwarders call (see the header).
cdmModule.discovery.BlizzardFilteredIDs = BlizzardFilteredIDs
cdmModule.discovery.DiscoverCooldowns   = DiscoverCooldowns
