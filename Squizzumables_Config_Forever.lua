-- Squizzumables_Config_Forever.lua
-- WoW Forever: the consumable and class buff lists, replacing the retail ones in
-- Squizzumables_Config.lua. Loaded right after it, so the settings load picks
-- these up as if they were the defaults.
--
-- Read from the game's own data tables for build 1.60.1.70790 (wago.tools DB2
-- exports). What is different here:
--   * ranks     a spell has one ID per rank, and each rank is its own aura ID.
--               SPELL_RANKS answers "does the player know any rank" (see
--               BH.PlayerKnowsSpell), and buffVariants finds any rank on a unit.
--               Buttons cast by name, which gets the highest rank known. An
--               entry's spellID is its lowest rank, and stays the config key
--   * poisons   are bag items that enchant a weapon, not spells that leave an
--               aura, so they ride the oil list and ROGUE has no class buffs
--   * flasks    Petrification is left out: it stops you acting, so it is nothing
--               to be reminded about
--   * no augment runes, and no elixirs yet

local addonName, ns = ...
local BH = ns.BH
if not BH.IS_FOREVER then return end

-- The ranks of each class buff, lowest first.
local RANKS = {
    [1243]  = { 1243, 1244, 1245, 2791, 10937, 10938 },              -- Power Word: Fortitude
    [1459]  = { 1459, 1460, 1461, 10156, 10157 },                    -- Arcane Intellect
    [6673]  = { 6673, 5242, 6192, 11549, 11550, 11551, 25289 },      -- Battle Shout
    [1126]  = { 1126, 5232, 6756, 5234, 8907, 9884, 9885 },          -- Mark of the Wild
    [324]   = { 324, 325, 905, 945, 8134, 10431, 10432 },            -- Lightning Shield
    [8017]  = { 8017, 8018, 8019, 10399, 16314, 16315, 16316 },      -- Rockbiter Weapon
    [8024]  = { 8024, 8027, 8030, 16339, 16341, 16342 },             -- Flametongue Weapon
    [8033]  = { 8033, 8038, 10456, 16355, 16356 },                   -- Frostbrand Weapon
    [8232]  = { 8232, 8235, 10486, 16362 },                          -- Windfury Weapon
    [465]   = { 465, 10290, 643, 10291, 1032, 10292, 10293 },        -- Devotion Aura
    [7294]  = { 7294, 10298, 10299, 10300, 10301 },                  -- Retribution Aura
    [6201]  = { 6201, 6202, 5699, 11729, 11730 },                    -- Create Healthstone
    [13165] = { 13165, 14318, 14319, 14320, 14321, 14322, 25296 },   -- Aspect of the Hawk
    [20043] = { 20043, 20190 },                                      -- Aspect of the Wild
}
BH.SPELL_RANKS = RANKS

-- A buff's ranks plus the group version, which leaves a different aura.
local function WithGroupBuff(key, ...)
    local list = { ... }
    for _, id in ipairs(RANKS[key]) do list[#list + 1] = id end
    return list
end

-- Minor, Lesser, Healthstone, Greater, Major, each with its two improved versions.
BH.FOREVER_HEALTHSTONE_ITEMS = {
    5512, 19004, 19005, 5511, 19006, 19007, 5509, 19008, 19009,
    5510, 19010, 19011, 9421, 19012, 19013,
}

BH.defaults.consumables = {
    food = {
        -- Every item whose spell says it leaves you Well Fed.
        724,  -- Goretusk Liver Pie
        733,  -- Westfall Stew
        787,  -- Slitherskin Mackerel
        1017,  -- Seasoned Wolf Kabob
        1082,  -- Redridge Goulash
        2680,  -- Spiced Wolf Meat
        2681,  -- Roasted Boar Meat
        2682,  -- Cooked Crab Claw
        2683,  -- Crab Cake
        2684,  -- Coyote Steak
        2685,  -- Succulent Pork Ribs
        2687,  -- Dry Pork Ribs
        2888,  -- Beer Basted Boar Ribs
        3220,  -- Blood Sausage
        3662,  -- Crocolisk Steak
        3663,  -- Murloc Fin Soup
        3664,  -- Crocolisk Gumbo
        3665,  -- Curiously Tasty Omelet
        3666,  -- Gooey Spider Cake
        3726,  -- Big Bear Steak
        3727,  -- Hot Lion Chops
        3728,  -- Tasty Lion Steak
        3729,  -- Soothing Turtle Bisque
        4457,  -- Barbecued Buzzard Wing
        4592,  -- Longjaw Mud Snapper
        4593,  -- Bristle Whisker Catfish
        4594,  -- Rockscale Cod
        5095,  -- Rainbow Fin Albacore
        5472,  -- Kaldorei Spider Kabob
        5474,  -- Roasted Kodo Meat
        5476,  -- Fillet of Frenzy
        5477,  -- Strider Stew
        5479,  -- Crispy Lizard Tail
        5480,  -- Lean Venison
        5527,  -- Goblin Deviled Clams
        6038,  -- Giant Clam Scorcho
        6290,  -- Brilliant Smallfish
        6316,  -- Loch Frenzy Delight
        6887,  -- Spotted Yellowtail
        6888,  -- Herb Baked Egg
        6890,  -- Smoked Bear Meat
        7806,  -- Lollipop
        7807,  -- Candy Bar
        7808,  -- Chocolate Square
        8364,  -- Mithril Head Trout
        8957,  -- Spinefin Halibut
        10841,  -- Goldthorn Tea
        11584,  -- Cactus Apple Surprise
        12209,  -- Lean Wolf Steak
        12210,  -- Roast Raptor
        12212,  -- Jungle Stew
        12213,  -- Carrion Surprise
        12214,  -- Mystery Stew
        12215,  -- Heavy Kodo Stew
        12216,  -- Spiced Chili Crab
        12218,  -- Monster Omelet
        12224,  -- Crispy Bat Wing
        13851,  -- Hot Wolf Ribs
        13927,  -- Cooked Glossy Mightfish
        13928,  -- Grilled Squid
        13929,  -- Hot Smoked Bass
        13930,  -- Filet of Redgill
        13931,  -- Nightfin Soup
        13932,  -- Poached Sunscale Salmon
        13933,  -- Lobster Stew
        13934,  -- Mightfish Steak
        13935,  -- Baked Salmon
        16971,  -- Clamlette Surprise
        17197,  -- Gingerbread Cookie
        17198,  -- Egg Nog
        17222,  -- Spider Sausage
        18045,  -- Tender Wolf Steak
        18254,  -- Runn Tum Tuber Surprise
        20074,  -- Heavy Crocolisk Stew
        20452,  -- Smoked Desert Dumplings
        20516,  -- Bobbing Apple
        21023,  -- Dirge's Kickin' Chimaerok Chops
        21072,  -- Smoked Sagefish
        21217,  -- Sagefish Delight
        21254,  -- Winter Veil Cookie
        206177,  -- Pine Nut Butter
        249865,  -- Peace Tea
        249866,  -- Royal Tea
        249867,  -- Root Tea
        249868,  -- Triage Tea
        249869,  -- Sunny Tea
        249870,  -- Sage's Tea
        249871,  -- Venomous Smoothie
        249872,  -- Slimy Smoothie
        249873,  -- Mrrggl Smrrthle
        249874,  -- Calcified Smoothie
        249875,  -- Spicy Smoothie
        249876,  -- Wicked Smoothie
        250065,  -- Savory Stag Sliders
        250066,  -- Soaring Pamplona
        250067,  -- Bat Hachee
        250068,  -- Savory Turtle Stew
        250069,  -- Flank au Poivre
        250070,  -- Bear Bruscitti
        250071,  -- Steaming Stag Steak
        250072,  -- Swiftstrike Steak
        250073,  -- Raging Raptor Ribs
        250074,  -- Bear Brisket
        250075,  -- Prehistoric Pulled Raptor
        250076,  -- Raptor Rouladen
        250077,  -- Twice-Spiced Raptor Slice
        250078,  -- Giant Scrambled Eggs
        250079,  -- Tasty Raptor Bites
        250080,  -- Breakfast Omelette
        263509,  -- Skywall Souffle
        263512,  -- Pincer Bites
        267341,  -- Sweetpaw Jam
        268912,  -- Expiring Crab Cake
        268913,  -- Expiring Crocolisk Steak
        274971,  -- Briny Seafood Stew
        274976,  -- Plain Ol' Paletusk
        277950,  -- Wastewanderer Rations
        286152,  -- Plated Armorfish
        287973,  -- Tender Wolf Steak
        287974,  -- Grilled Squid
    },
    flask = {
        13510,   -- Flask of the Titans
        13511,   -- Flask of Distilled Wisdom
        13512,   -- Flask of Supreme Power
        13513,   -- Flask of Chromatic Resistance
        274273,  -- Flask of Natural Accuracy
        274274,  -- Flask of Natural Aggression
        274275,  -- Flask of Natural Precision
        274276,  -- Flask of Natural Swiftness
    },
    oil = {
        -- Sharpening stones
        2862, 2863, 2871, 7964, 12404, 18262, 23122, 287978, 287980,
        -- Weightstones
        3239, 3240, 3241, 7965, 12643,
        -- Oils
        3824,    -- Shadow Oil
        3829,    -- Frost Oil
        20744, 20746, 20750, 20749, 23123, 287979,  -- Wizard Oils
        20745, 20747, 20748,                        -- Mana Oils
        -- Rogue poisons
        6947, 6949, 6950, 8926, 8927, 8928,         -- Instant Poison
        2892, 2893, 8984, 8985, 20844,              -- Deadly Poison
        10918, 10920, 10921, 10922,                 -- Wound Poison
        3775, 3776,                                 -- Crippling Poison
        5237, 6951, 9186,                           -- Mind-numbing Poison
    },
    augmentRune = {},
}

BH.defaults.classBuffs = {
    PRIEST = { spellID = 1243, buffVariants = WithGroupBuff(1243, 21562, 21564) },  -- Power Word: Fortitude, Prayer of Fortitude
    MAGE = { spellID = 1459, buffVariants = WithGroupBuff(1459, 23028) },           -- Arcane Intellect, Arcane Brilliance
    WARRIOR = { spellID = 6673, buffVariants = RANKS[6673] },                       -- Battle Shout
    DRUID = { spellID = 1126, buffVariants = WithGroupBuff(1126, 21849, 21850) },   -- Mark of the Wild, Gift of the Wild
    WARLOCK = {
        { spellID = 688, petCheck = true, label = "Imp" },          -- Summon Imp
        { spellID = 697, petCheck = true, label = "Voidwalker" },   -- Summon Voidwalker
        { spellID = 712, petCheck = true, label = "Succubus" },     -- Summon Succubus
        { spellID = 691, petCheck = true, label = "Felhunter" },    -- Summon Felhunter
        { spellID = 6201, healthstoneCheck = true, label = "Healthstone" },  -- Create Healthstone
    },
    HUNTER = {
        -- One Call Pet here, so no stable slots and none of callPetCheck's icon test.
        { spellID = 883, petCheck = true, label = "Pet" },  -- Call Pet
        -- Only one aspect can be up at a time: while none is, every known and
        -- enabled one gets a button, so the player picks.
        { spellID = 13165, aspect = true, label = "Hawk" },     -- Aspect of the Hawk
        { spellID = 13163, aspect = true, label = "Monkey" },   -- Aspect of the Monkey
        { spellID = 20043, aspect = true, label = "Wild" },     -- Aspect of the Wild
        { spellID = 13161, aspect = true, label = "Beast" },    -- Aspect of the Beast
        { spellID = 5118, aspect = true, label = "Cheetah" },   -- Aspect of the Cheetah
        { spellID = 13159, aspect = true, label = "Pack" },     -- Aspect of the Pack
    },
    SHAMAN = {
        { spellID = 324, selfBuff = true, label = "Lightning Shield", buffVariants = RANKS[324] },
        { spellID = 8017, weaponImbue = true, label = "Rockbiter" },
        { spellID = 8024, weaponImbue = true, label = "Flametongue" },
        { spellID = 8033, weaponImbue = true, label = "Frostbrand" },
        { spellID = 8232, weaponImbue = true, label = "Windfury" },
    },
    PALADIN = {
        auraCheck = true,
        auras = {
            { spellID = 465 },                          -- Devotion Aura
            { spellID = 7294, label = "Ret Aura" },     -- Retribution Aura
            { spellID = 19746, label = "Conc Aura" },   -- Concentration Aura
        },
    },
}
