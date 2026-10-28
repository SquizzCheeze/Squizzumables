-- Cooldowns/ItemCategories.lua
-- Potions and Healthstones: the Cooldown Manager's SPELL-CATEGORY entries.
--
-- 12.1.5 (live build 70575) added a third kind of Cooldown Manager entry
-- beside spells and equip slots: `cooldownInfo.spellCategoryID`, one entry per
-- shared item cooldown -- combat potions (4), healing potions (30),
-- Healthstone (1711) and Demonic Healthstone (2566). Such an entry carries NO
-- spellID and NO equipSlot until the player drinks one, so everything here
-- that asked "spell or equip slot?" dropped it, and the potions Blizzard's own
-- bar showed never reached ours (user report 2026-10-28).
--
-- Blizzard's item (Blizzard_CooldownViewer/CooldownViewerItemData.lua, live)
-- learns the item from C_Spell.GetLastCategoryCooldownSource and draws a
-- hardcoded icon per category. That call is SecretWhenCooldownsRestricted, so
-- it cannot be relied on in combat. Item cooldowns can: C_Container's
-- GetItemCooldown carries no secret flag (see EquipSlotCooldown's note), and
-- every item in a category shares the one cooldown. So the cooldown is read
-- off any item of the category you carry, or the last one learned while it
-- was readable.
--
-- The proxy carries `spellCategory` (set in CreateProxyIcon) and takes the
-- equip-slot path everywhere: EquipSlotCooldown hands it to CategoryCooldown.

local addonName, ns = ...
local BH = ns.BH

local cdmModule = BH.cdm
if not cdmModule then return end

-- Icons are Blizzard's own choice per category (spellCategoryMetadataLookup).
-- Item lists: every quality of every Midnight item of the category, Fleeting
-- ones included. Only used to find one you carry; a missing ID costs nothing.
local CATEGORIES = {
    [4] = {
        name = "Combat Potion",
        icon = "Interface\\ICONS\\INV_POTION_114",
        items = {
            241309, 241308, 245897, 245898, 246134,   -- Light's Potential
            241289, 241288, 245902, 245903, 246128,   -- Potion of Recklessness
            241293, 241292, 245910, 245911, 246430,   -- Draught of Rampant Abandon
            241295, 241294, 245904, 245905, 246130,   -- Potion of Devoured Dreams
            271886, 271887, 274763, 274764, 274738,   -- Liquid Luster
        },
    },
    [30] = {
        name = "Health Potion",
        icon = "Interface\\ICONS\\INV_POTION_54",
        items = {
            241305, 241304, 245918, 245919, 246136,   -- Silvermoon Health Potion
            271883, 271884, 274773,                   -- Concentrated Silvermoon Health Potion
        },
    },
    [1711] = {
        name = "Healthstone",
        icon = "Interface\\ICONS\\Warlock_ Healthstone",
        items = { 5512 },
    },
    [2566] = {
        name = "Demonic Healthstone",
        icon = "Interface\\ICONS\\Warlock_ Bloodstone",
        items = { 224464 },
    },
}
cdmModule.ITEM_CATEGORIES = CATEGORIES

-- The last item seen starting each category's cooldown, learned whenever
-- GetLastCategoryCooldownSource is readable (out of combat, open world).
local learned = {}

-- The category behind a cooldownID, or nil for an ordinary entry.
function cdmModule.CategoryForCooldown(cdID)
    if not cdID or not (C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo) then
        return nil
    end
    local info = C_CooldownViewer.GetCooldownViewerCooldownInfo(cdID)
    ---@diagnostic disable-next-line: undefined-field
    local cat = info and BH.Secrets.SafeNumber(info.spellCategoryID, nil)
    if cat and cat ~= 0 then return cat end
    return nil
end

-- Name and icon for a category, falling back to a generic label for one this
-- table does not know (a future category still gets a readable row).
function cdmModule.CategoryLabel(cat)
    local c = cat and CATEGORIES[cat]
    if c then return c.name, c.icon end
    return cat and ("Item Cooldown " .. cat) or nil, "Interface\\ICONS\\INV_Misc_QuestionMark"
end

local function Count(itemID)
    local ok, n = pcall(C_Item.GetItemCount, itemID)
    n = ok and BH.Secrets.SafeNumber(n, 0) or 0
    return n > 0
end

local function ItemFor(cat)
    if C_Spell and C_Spell.GetLastCategoryCooldownSource then
        local ok, _, itemID = pcall(C_Spell.GetLastCategoryCooldownSource, cat)
        itemID = ok and BH.Secrets.SafeNumber(itemID, nil) or nil
        if itemID then learned[cat] = itemID end
    end
    if learned[cat] and Count(learned[cat]) then return learned[cat] end
    local c = CATEGORIES[cat]
    for _, id in ipairs(c and c.items or {}) do
        if Count(id) then return id end
    end
    -- Carrying none: the learned one may still answer for the category.
    return learned[cat]
end

-- Same contract as EquipSlotCooldown: start, duration, onCD, or nil when
-- there is nothing to read (no item of the category known yet -- shown ready,
-- as Blizzard's icon is).
function cdmModule.CategoryCooldown(proxy)
    local cat = proxy and proxy.spellCategory
    if not cat or not (C_Container and C_Container.GetItemCooldown) then return nil end
    local itemID = ItemFor(cat)
    if not itemID then return nil end
    local ok, start, duration, enable = pcall(C_Container.GetItemCooldown, itemID)
    if not ok then return nil end
    start = BH.Secrets.SafeNumber(start, nil)
    duration = BH.Secrets.SafeNumber(duration, nil)
    if not (start and duration) then return nil end
    -- enable false/0: a potion drunk in combat whose cooldown waits for combat
    -- to end. Blizzard draws nothing for it either.
    local enabled = not (enable == false or enable == 0)
    local onCD = enabled and duration > 1.5 and (start + duration) > GetTime()
    return start, duration, onCD
end
