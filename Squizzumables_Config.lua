-- Squizzumables_Config.lua
-- Default configuration for Squizzumables addon.
-- These are loaded if no user settings exist.

local addonName, ns = ...
ns.BH = ns.BH or {}
local BH = ns.BH

-- Default consumables and buffs (Midnight 12.0)
BH.defaults = {
    consumables = {
        food = {
            -- Midnight Regular Foods
            255846,  -- Harandar Celebration
            255847,  -- Impossibly Royal Roast
            242275,  -- Royal Roast
            255848,  -- Flora Frenzy
            242274,  -- Champion's Bento
            255845,  -- Silvermoon Parade
            242273,  -- Blooming Feast
            242272,  -- Quel'dorei Medley
            242277,  -- Crimson Calamari
            -- Midnight Hearty Foods (persist through death)
            266996,  -- Hearty Harandar Celebration
            268679,  -- Hearty Impossibly Royal Roast
            242747,  -- Hearty Royal Roast
            268680,  -- Hearty Flora Frenzy
            242746,  -- Hearty Champion's Bento
            266985,  -- Hearty Silvermoon Parade
            242745,  -- Hearty Blooming Feast
            242744,  -- Hearty Quel'dorei Medley
            242749,  -- Hearty Crimson Calamari
        },
        flask = {
            -- Midnight Flasks (1 hour, persist through death)
            241327,  -- Flask of the Shattered Sun R1
            241326,  -- Flask of the Shattered Sun R2
            241323,  -- Flask of the Magisters R1
            241322,  -- Flask of the Magisters R2
            241321,  -- Flask of Thalassian Resistance R1
            241320,  -- Flask of Thalassian Resistance R2
            241324,  -- Flask of the Blood Knights R1
            241325,  -- Flask of the Blood Knights R2
        },
        oil = {
            -- Midnight Weapon Oils/Buffs
            243733,  -- Thalassian Phoenix Oil (Rank 1)
            243734,  -- Thalassian Phoenix Oil (Rank 2) - same spellID, different itemID
            237370,  -- Refulgent Whetstone (Rank 1)
            237371,  -- Refulgent Whetstone (Rank 2) - same spellID, different itemID
        },
        augmentRune = {
            -- Augment runes: a flask-shaped consumable (bag item, applies a
            -- long buff) rather than anything new, so it rides the same
            -- machinery as food and flask.
            259085,  -- Void-Touched Augment Rune (Midnight)
            243191,  -- Ethereal Augment Rune (The War Within)
        }
    },
    classBuffs = {
        -- Only classes that can cast a raid-wide buff are included
        -- The addon automatically checks your class and only shows your buff
        PRIEST = { spellID = 21562 },     -- Power Word: Fortitude (Stamina)
        MAGE = {
            { spellID = 1459 },                               -- Arcane Intellect (Intellect)
            { spellID = 31687, petCheck = true, label = "Water Ele" },  -- Summon Water Elemental
        },
        WARRIOR = { spellID = 6673 },     -- Battle Shout (Attack Power)
        DEATHKNIGHT = {
            -- Death Knights are the one class with a *permanent* weapon enchant
            -- rather than a temporary imbue, so this cannot use weaponImbue:
            -- GetWeaponEnchantInfo only reports temporary enchants and never
            -- sees a runeforge. weaponRune reads the enchant ID out of the
            -- equipped weapon's item link instead.
            --
            -- The button casts Death Gate, because runeforging needs a
            -- runeforge and the one in Acherus is the reliable way to reach
            -- one. Applying the rune itself is not something a button can do.
            { spellID = 50977, weaponRune = true, label = "Runeforge" },  -- Death Gate
        },
        DRUID = { spellID = 1126 },       -- Mark of the Wild (Versatility)
        EVOKER = {
            { spellID = 381748, castSpellID = 364342, buffVariants = {  -- Blessing of the Bronze
                381748, -- Evoker (Hover)
                381732, -- Death Knight (Death's Advance)
                381746, -- Druid (Dash/Tiger Dash)
                381749, -- Hunter (Aspect of the Cheetah)
                381750, -- Mage (Blink/Shimmer)
                381751, -- Monk (Roll/Chi Torpedo)
                381752, -- Paladin (Divine Steed)
                381753, -- Priest (Leap of Faith)
                381754, -- Rogue (Sprint)
                381756, -- Shaman (Gust of Wind/Spirit Walk)
                381741, -- Demon Hunter (Fel Rush/Infernal Strike)
                381757, -- Warlock (Demonic Circle: Teleport)
                381758, -- Warrior (Heroic Leap)
                432649, -- Death Knight (variant)
                432655, -- Demon Hunter (variant)
                432658, -- Druid (variant)
                432659, -- Evoker (variant)
                432660, -- Hunter (variant)
                432661, -- Mage (variant)
                432662, -- Monk (variant)
                432663, -- Paladin (variant)
                432664, -- Priest (variant)
                432665, -- Rogue (variant)
                432652, -- Shaman (variant)
                432667, -- Warlock (variant)
                432668, -- Warrior (variant)
            }},
            { spellID = 369459, healerOnly = true },        -- Source of Magic (Healer only)
        },
        ROGUE = {
            -- Lethal Poisons (player should have one active)
            { spellID = 2823, selfBuff = true, buffVariants = { 2823, 8679, 315584, 381664 } },     -- Deadly Poison
            { spellID = 8679, selfBuff = true, buffVariants = { 2823, 8679, 315584, 381664 } },     -- Wound Poison
            { spellID = 315584, selfBuff = true, buffVariants = { 2823, 8679, 315584, 381664 } },   -- Instant Poison
            { spellID = 381664, selfBuff = true, buffVariants = { 2823, 8679, 315584, 381664 } },   -- Amplifying Poison
            -- Non-Lethal Poisons (player should have one active)
            { spellID = 3408, selfBuff = true, buffVariants = { 3408, 5761, 381637 } },              -- Crippling Poison
            { spellID = 5761, selfBuff = true, buffVariants = { 3408, 5761, 381637 } },              -- Numbing Poison
            { spellID = 381637, selfBuff = true, buffVariants = { 3408, 5761, 381637 } },            -- Atrophic Poison
        },
        WARLOCK = {
            { spellID = 688, petCheck = true, label = "Imp" },          -- Summon Imp
            { spellID = 697, petCheck = true, label = "Voidwalker" },   -- Summon Voidwalker
            { spellID = 712, petCheck = true, label = "Sayaad" },       -- Summon Sayaad
            { spellID = 691, petCheck = true, label = "Felhunter" },    -- Summon Felhunter
            { spellID = 30146, petCheck = true, label = "Felguard" },   -- Summon Felguard (Demonology)
            -- Warlocks are the only source of healthstones, so rather than
            -- telling them one is missing they get the button to make it: Create
            -- Healthstone alone, Create Soulwell in a group so it serves everyone.
            -- Everyone else gets the text reminder instead.
            { spellID = 6201, healthstoneCheck = true, label = "Healthstone" },  -- Create Healthstone (swaps to Soulwell in a group)
        },
        HUNTER = {
            { spellID = 883, petCheck = true, callPetCheck = true, label = "Pet 1" },    -- Call Pet 1
            { spellID = 83242, petCheck = true, callPetCheck = true, label = "Pet 2" },  -- Call Pet 2
            { spellID = 83243, petCheck = true, callPetCheck = true, label = "Pet 3" },  -- Call Pet 3
            { spellID = 83244, petCheck = true, callPetCheck = true, label = "Pet 4" },  -- Call Pet 4
            { spellID = 83245, petCheck = true, callPetCheck = true, label = "Pet 5" },  -- Call Pet 5
        },
        SHAMAN = {
            { spellID = 462854 },                                                           -- Skyfury (Critical Strike)
            -- Earth Shield (cast spell 974, aura can be 974 or 383648)
            -- With the Elemental Orbit talent, Earth Shield lasts 1 hour (no charges).
            -- earthShield flag enables multi-shaman logic: 1 shaman = Tank+Self only,
            -- 2+ shamans = show buttons for all unbuffed party/raid members.
            { spellID = 974, tankBuff = true, earthShield = true, label = "Earth Shield", header = "Tank", buffVariants = { 974, 383648 } },   -- Earth Shield on Tank
            { spellID = 974, selfBuff = true, earthShield = true, label = "Earth Shield", header = "Self", buffVariants = { 974, 383648 } },    -- Earth Shield on Self
            -- Personal Shields (mutually exclusive self buffs)
            { spellID = 52127, selfBuff = true, label = "Water Shield", buffVariants = { 52127, 192106 } },        -- Water Shield
            { spellID = 192106, selfBuff = true, label = "Lightning Shield", buffVariants = { 52127, 192106 } },   -- Lightning Shield
            -- Weapon Imbues (MH only, detected via weapon enchant not player aura)
            { spellID = 33757, weaponImbue = true, label = "Windfury" },      -- Windfury Weapon
            { spellID = 318038, weaponImbue = true, label = "Flametongue" },  -- Flametongue Weapon
            { spellID = 382021, weaponImbue = true, label = "Earthliving" },  -- Earthliving Weapon (Resto)
        },
        PALADIN = {
            auraCheck = true,
            auras = {
                { spellID = 465 },      -- Devotion Aura
                { spellID = 317920, label = "Conc Aura" },    -- Concentration Aura
            },
            -- Weapon imbues for Holy Paladin (Lightsmith hero talents, mutually exclusive)
            -- Only one can be known at a time; replaces oils for Holy spec.
            weaponImbues = {
                { spellID = 433568, label = "Rite of Sanctification" },  -- +5% armor, +2% primary stat (enchant 7143)
                { spellID = 433583, label = "Rite of Adjuration" },       -- +3% Stamina, Holy Power burst heal (enchant 7144)
            },
        },
    }
}