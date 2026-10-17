-- Reminders/Buttons.lua
-- The reminder-button engine: which consumable and class-buff buttons show
-- (CollectClassBuffButtons / CollectConsumableButtons), how they are laid out
-- (LayoutButtons), the rebuild itself (UpdateButtons), their sounds, and the
-- "blind" handling while auras are secret.
--
-- Moved out of Squizzumables.lua unchanged in 2.0 phase 2 (the split). The
-- core's private names it uses are published on BH where this code used to
-- sit, and re-declared below under the same names, so the moved code is
-- byte-identical. Its own state (the class-buff sound edges and the mid-click
-- deferral) moved here with it, since nothing else reads it. Called at
-- runtime through BH (BH:UpdateButtons from events and the debounced
-- BH:ScheduleUpdateButtons in the core).

local addonName, ns = ...
local BH = ns.BH

local BEACON_AURA_IDS                = BH.BEACON_AURA_IDS
local COACH_WHISTLE_ITEM_ID          = BH.COACH_WHISTLE_ITEM_ID
local ELEMENTAL_ORBIT_SPELL_ID       = BH.ELEMENTAL_ORBIT_SPELL_ID
local ES_AURA_IDS                    = BH.ES_AURA_IDS
local SYMBIOTIC_AURA_SPELL_ID        = BH.SYMBIOTIC_AURA_SPELL_ID
local SYMBIOTIC_CAST_SPELL_ID        = BH.SYMBIOTIC_CAST_SPELL_ID
local THERAZANES_RESILIENCE_SPELL_ID = BH.THERAZANES_RESILIENCE_SPELL_ID
local SQ_BUTTON_POOL                 = BH.SQ_BUTTON_POOL
local GetCoachedAllyExpiration       = BH.GetCoachedAllyExpiration
local GetGroupUnits                  = BH.GetGroupUnits
local RuneforgeAction                = BH.RuneforgeAction
local WeaponNeedsRune                = BH.WeaponNeedsRune
local CountClassInGroup              = BH.CountClassInGroup
local CreateButton                   = BH.CreateButton
local FindUnbuffedHealer             = BH.FindUnbuffedHealer
local FindUnbuffedTank               = BH.FindUnbuffedTank
local GetMainHandEnchantInfo         = BH.GetMainHandEnchantInfo
local GetOffHandEnchantInfo          = BH.GetOffHandEnchantInfo
local GetSpellIcon                   = BH.GetSpellIcon
local GroupNeedsBuff                 = BH.GroupNeedsBuff
local HasAugmentRuneBuff             = BH.HasAugmentRuneBuff
local HasFlaskBuff                   = BH.HasFlaskBuff
local HasFoodBuff                    = BH.HasFoodBuff
local HasOffHandWeapon               = BH.HasOffHandWeapon
local PlayerHasBuffOnGroupMember     = BH.PlayerHasBuffOnGroupMember
local ShouldShowButtons              = BH.ShouldShowButtons
local UnitHasBuff                    = BH.UnitHasBuff

-- The core's private sound player, through its public wrapper.
local function PlaySQSound(name, channel) BH:PlaySound(name, channel) end


-- Tracks which class buff spellIDs showed buttons on the previous UpdateButtons
-- pass. Used to fire per-buff sound alerts once per "buff becomes missing" transition.
-- Indexed by spellID: classBuffWasNeeded[spellID] = true when the buff was showing.
local classBuffWasNeeded = {}

-- Set while a rebuild is being held off mid-click (see the guard in
-- BH:UpdateButtons). _updateButtonsDeferrals caps how many times in a row a
-- rebuild may be postponed, so updates can never stall indefinitely.
local _updateButtonsHoverRetry = false
local _updateButtonsDeferrals = 0

-- Can the player use this item yet? File scope so both the class-buff pass and
-- the consumable pass can share it.
local function MeetsLevelRequirement(itemID)
    local playerLevel = UnitLevel("player")
    local _, _, _, _, minLevel = C_Item.GetItemInfo(itemID)
    -- If item info not loaded yet, assume we can use it (will recheck on next update)
    if not minLevel then return true end
    return playerLevel >= minLevel
end

-- Play the per-buff alert sound for any class buff whose button has just
-- appeared, and forget the ones that no longer need it.
--
-- Takes the set of spellIDs that produced a button this pass. Split out of
-- UpdateButtons because it is edge detection over a set, not button building,
-- and the reasoning about secret auras below deserves to be findable.
function BH:FireClassBuffSounds(spellIDsThisPass)
    -- Class buff sound alert: play once per spellID when its button first appears.
    --
    -- Skipped entirely while aura data is secret. At the moment combat starts,
    -- auras stop being readable a fraction before InCombatLockdown() trips, so a
    -- pass can land in that window, read every buff as missing, and fire alerts
    -- for buffs the player actually has -- which is exactly what it sounded
    -- like: the alerts all going off as a pull began.
    --
    -- The tracking table is left untouched as well, not just the sounds. Marking
    -- everything as "was needed" from an unreadable pass would overwrite the
    -- real pre-combat state, and the next readable pass would then treat buffs
    -- that never went anywhere as freshly missing.
    if not BH.Secrets.AurasAreSecret() then
        local s = self.settings
        for spellID, _ in pairs(spellIDsThisPass) do
            if not classBuffWasNeeded[spellID] then
                classBuffWasNeeded[spellID] = true
                local snd = s and s.classBuffSounds and s.classBuffSounds[spellID]
                if snd and snd ~= "None" and not BH.suppressBuffSounds then
                    PlaySQSound(snd)
                end
            end
        end
        -- Clear tracking for spells no longer showing buttons
        for spellID in pairs(classBuffWasNeeded) do
            if not spellIDsThisPass[spellID] then
                classBuffWasNeeded[spellID] = nil
            end
        end
    end
end

-- Append every class-buff button for this pass: group buffs, self buffs, tank
-- buffs, weapon imbues, Paladin auras, Lightsmith rites and pet summons.
--
-- The largest single piece of what used to be UpdateButtons. Its parameters are
-- deliberately named the same as the locals it used to close over, so the body
-- moved across unchanged -- 385 lines of per-class special cases is exactly the
-- code you do not want to be hand-editing while relocating it.
--
-- Returns the button index it reached, plus the two flags that decide whether
-- the pet and combat-buff frames are shown.
function BH:CollectClassBuffButtons(id, addedItems, class, classBuff_spellIDs_this_pass)
    local hasPetButton = false   -- true if any pet summon button is created this pass
    local hasCombatBuff = false  -- true if any group-wide buff button is created this pass
    local info = BH.classBuffs and BH.classBuffs[class]
    if info then
        if info.auraCheck and info.auras then
            -- Skip while dead/ghost: the aura persists but the API can't read
            -- player buffs in that state, which would cause a false alert + sound.
            -- Shown in M+ too since 2.1 (user request 2026-10-17): an aura can be
            -- cast between pulls, and these buttons only rebuild out of combat.
            if UnitIsDeadOrGhost("player") then
                -- do nothing
            else
            -- Paladin aura logic: scan group paladins to see who has which aura
            local paladinCount = CountClassInGroup("PALADIN")

            local specID = PlayerUtil and PlayerUtil.GetCurrentSpecID and PlayerUtil.GetCurrentSpecID()
            local isHolyPaladin = (specID == 65) -- 65 = Holy Paladin

            -- Check which auras I (the player) have personally activated.
            -- Use GetUnitAuraBySpellID("player", ...) rather than GetPlayerAuraBySpellID —
            -- the latter uses the PLAYER_AURAS filtered system which does not track
            -- passive toggle auras like Devotion Aura in M+. GetUnitAuraBySpellID checks
            -- the full buff list on the unit (same API used for other paladins below).
            local myActiveCount = 0
            local myHasDevotion = false
            local myActiveAuras = {}   -- spellID -> true for auras I have up right now
            for _, auraInfo in ipairs(info.auras) do
                local auraData = BH.Secrets.GetAuraBySpellID("player", auraInfo.spellID)
                local source = BH.Secrets.SafeAuraSourceUnit(auraData)
                if auraData and (not source or UnitIsUnit(source, "player")) then
                    myActiveCount = myActiveCount + 1
                    myActiveAuras[auraInfo.spellID] = true
                    if auraInfo.spellID == 465 then
                        myHasDevotion = true
                    end
                end
            end

            -- Holy Paladins need the Devotion Aura option even when covered by another
            -- paladin, because they may want to activate it for Aura Mastery. So only hide
            -- buttons for Holy if Devotion Aura is already active; hide for other specs as
            -- soon as any aura is active.
            local shouldHide = (isHolyPaladin and myHasDevotion) or (not isHolyPaladin and myActiveCount > 0)

            if not shouldHide then
                -- No blocking aura active - figure out what to show
                -- Check which auras are covered by other paladins in the group
                local coveredByOthers = {}
                local groupSize = GetNumGroupMembers()
                if groupSize > 0 then
                    local isRaid = IsInRaid()
                    for i = 1, groupSize do
                        local unit = isRaid and ("raid" .. i) or ("party" .. i)
                        if not UnitIsUnit(unit, "player") and UnitExists(unit) then
                            local _, unitClass = UnitClass(unit)
                            if unitClass == "PALADIN" then
                                for _, auraInfo in ipairs(info.auras) do
                                    local auraData = BH.Secrets.GetAuraBySpellID(unit, auraInfo.spellID)
                                    local source = BH.Secrets.SafeAuraSourceUnit(auraData)
                                    if source and UnitIsUnit(source, unit) then
                                        coveredByOthers[auraInfo.spellID] = true
                                    end
                                end
                            end
                        end
                    end
                end

                -- Never offer an aura the player already has up. shouldHide above is
                -- an all-or-nothing gate and for Holy it only trips on Devotion, so
                -- without this a Holy Paladin running Concentration Aura was still
                -- shown a button for the Concentration Aura they already had active.
                local showAuras = {}
                if paladinCount >= 2 then
                    -- 2+ paladins: show uncovered auras; for Holy Paladins also always
                    -- include Devotion Aura so it's available for Aura Mastery
                    for _, auraInfo in ipairs(info.auras) do
                        if self:IsEnabled(auraInfo.spellID) and not myActiveAuras[auraInfo.spellID] then
                            local forceForHoly = isHolyPaladin and (auraInfo.spellID == 465)
                            if forceForHoly or not coveredByOthers[auraInfo.spellID] then
                                table.insert(showAuras, auraInfo)
                            end
                        end
                    end
                else
                    -- Solo paladin: show all enabled auras so player can pick
                    for _, auraInfo in ipairs(info.auras) do
                        if self:IsEnabled(auraInfo.spellID) and not myActiveAuras[auraInfo.spellID] then
                            table.insert(showAuras, auraInfo)
                        end
                    end
                end

                for _, auraInfo in ipairs(showAuras) do
                    local icon = GetSpellIcon(auraInfo.spellID)
                    if icon then
                        self.buttons[id] = CreateButton(id, icon, "Cast aura", "spell", auraInfo.spellID, auraInfo.label, nil, nil)
                        classBuff_spellIDs_this_pass[auraInfo.spellID] = true
                        id = id + 1
                    end
                end
            end
            end -- dead or ghost else

            -- Lightsmith weapon imbue buttons (Rite of Sanctification / Rite of Adjuration)
            -- Lightsmith is a Holy *and* Protection hero tree, and the two Rites are a
            -- choice node inside it, so this gates on knowing the spell and never on
            -- spec. The old `specID == 65` check hid the button from every Protection
            -- Lightsmith paladin. The oil block below keys off the same two spell IDs
            -- and must stay in agreement, or a Rite user gets an oil button competing
            -- for the same main-hand slot.
            -- Not shown while dead. Shown in M+ since 2.1: a Rite can be cast between pulls.
            if not UnitIsDeadOrGhost("player") then
                local paladinRites = info.weaponImbues or {}
                for _, rite in ipairs(paladinRites) do
                    if rite.spellID and BH.PlayerKnowsSpell(rite.spellID) and self:IsEnabled(rite.spellID) then
                        local hasMH, mhExpiration = GetMainHandEnchantInfo()
                        local needsRefresh = self:NeedsRefresh(rite.spellID, hasMH and mhExpiration or nil)
                        if needsRefresh then
                            local icon = GetSpellIcon(rite.spellID)
                            local spellName = C_Spell.GetSpellName(rite.spellID)
                            if icon and spellName then
                                -- Use a macro so the weapon enchant cursor auto-targets slot 16 (MH)
                                local macroText = "/cast " .. spellName .. "\n/use 16"
                                self.buttons[id] = CreateButton(id, icon, "Apply imbue", "macro", macroText, rite.label, nil, hasMH and mhExpiration or nil)
                                classBuff_spellIDs_this_pass[rite.spellID] = true
                                id = id + 1
                            end
                        end
                        break  -- only one Rite can be known at a time (choice node)
                    end
                end
            end
        else
            -- Pet summoning is always available, even during M+
            do
                local petBuffList = info.spellID and { info } or info
                for _, buffInfo in ipairs(petBuffList) do
                    if buffInfo.petCheck and buffInfo.spellID and self:IsEnabled(buffInfo.spellID) then
                        local specIndex = GetSpecialization()
                        local currentSpecID = specIndex and select(1, GetSpecializationInfo(specIndex))
                        local isMMHunter = (class == "HUNTER") and (currentSpecID == 254)
                        local hasUnbreakableBond = BH.PlayerKnowsSpell(1223323)
                        local skipForMM = isMMHunter and not hasUnbreakableBond
                        if not skipForMM and BH.PlayerKnowsSpell(buffInfo.spellID) and not UnitExists("pet") then
                            local icon = GetSpellIcon(buffInfo.spellID)
                            if icon and (not buffInfo.callPetCheck or icon ~= 132161) then
                                local label = buffInfo.label
                                if buffInfo.callPetCheck and label then
                                    local slot = tonumber(label:match("%d+"))
                                    if slot and C_StableInfo and C_StableInfo.GetStablePetInfo then
                                        local petInfo = C_StableInfo.GetStablePetInfo(slot)
                                        if petInfo and petInfo.name and petInfo.name ~= "" then
                                            label = petInfo.name
                                        end
                                    end
                                end
                                local petBtn = CreateButton(id, icon, "Summon pet", "spell", buffInfo.spellID, label, nil, nil)
                                petBtn.isPetButton = true
                                petBtn:SetParent(BH.petFrame)  -- non-secure frame: Show/Hide allowed in combat
                                self.buttons[id] = petBtn
                                hasPetButton = true
                                classBuff_spellIDs_this_pass[buffInfo.spellID] = true
                                id = id + 1
                            end
                        end
                    end
                end
            end

            -- Normal class buff handling. Shown in M+ too since 2.1 (user request
            -- 2026-10-17): these were skipped for a whole key on the belief that
            -- they could not be used mid-key, but they can be cast between pulls,
            -- and the buttons only rebuild out of combat (see UpdateButtons). The
            -- group-wide ones stay out-of-combat only inside a key: see cbBtn below.
            do
            local buffList = info.spellID and { info } or info

            -- Earth Shield button logic (priority-based, max 2 buttons):
            --   Group button: tank unbuffed → target tank (always, even if player is healer);
            --                 else unbuffed other healer → target that healer (never targets self).
            --   Self button:  shown when Elemental Orbit is talented + self-ES missing,
            --                 OR player is healer (no EO) + self-ES missing (group button
            --                 never targets the player themselves, so self needs its own button).
            -- Mark as handled so the tankBuff/selfBuff entries are skipped below.
            local earthShieldHandled = false
            if class == "SHAMAN" and BH.PlayerKnowsSpell(974) and self:IsEnabled(974) then
                earthShieldHandled = true
                local esIcon = GetSpellIcon(974)
                local esSpellName = C_Spell.GetSpellName(974)
                local checkIDs = { 974, 383648 }

                local groupSize = GetNumGroupMembers()
                local playerRole = UnitGroupRolesAssigned("player")
                local playerIsHealer = (playerRole == "HEALER")
                local hasElementalOrbit = BH.PlayerKnowsSpell(ELEMENTAL_ORBIT_SPELL_ID)
                -- Therazane's Resilience: ES has no charges and lasts 60 min → duration-based refresh applies
                local hasTherazanesResilience = BH.PlayerKnowsSpell(THERAZANES_RESILIENCE_SPELL_ID)

                -- ── Group button ──────────────────────────────────────────────
                -- Without EO (1 ES max): suppress if the player's one ES is already
                -- on a group member — no point showing another target button.
                -- NOTE: PlayerHasBuffOnGroupMember skips the player unit, so having
                -- ES on yourself does NOT suppress this button. Self-ES and group-ES
                -- are tracked independently.
                -- With EO (2 ES max): never suppress — player can have self + group.
                --   FindUnbuffedTank then determines if the tank still needs it.
                local esOnGroupMember = PlayerHasBuffOnGroupMember(checkIDs)
                local suppressGroupButton = (not hasElementalOrbit) and esOnGroupMember
                if not suppressGroupButton then
                    local tankName, tankAllBuffed, lowestExpires = FindUnbuffedTank(checkIDs)
                    local needsGroupButton = false
                    if not tankAllBuffed and tankName then
                        -- Tank is missing ES entirely
                        needsGroupButton = true
                    elseif hasTherazanesResilience and tankAllBuffed and tankName and lowestExpires then
                        -- Tank has ES but it may be expiring soon (only relevant with 60-min duration talent)
                        needsGroupButton = self:NeedsRefresh(974, lowestExpires)
                    end
                    if needsGroupButton and esIcon then
                        self.buttons[id] = CreateButton(id, esIcon, "Cast on " .. tankName, "macro",
                            "/cast [@" .. tankName .. "] " .. (esSpellName or ""), "Earth Shield", tankName, nil)
                        classBuff_spellIDs_this_pass[974] = true
                        id = id + 1
                    end
                end

                -- ── Self button ───────────────────────────────────────────────
                -- Show if: Elemental Orbit talented + self-ES missing
                --       OR player is the healer (no EO) + self-ES missing
                --       OR solo (groupSize == 0) + self-ES missing
                -- Note: without EO only one ES can be active, but we still show the self
                -- button so the player can choose to move it to themselves if desired.
                local needsSelfButton = hasElementalOrbit or playerIsHealer or (groupSize == 0)
                if needsSelfButton then
                    local hasSelfES = false
                    local selfESExpiration = nil
                    for _, checkID in ipairs(checkIDs) do
                        -- Check both APIs for maximum reliability across aura types.
                        local auraData = C_UnitAuras.GetUnitAuraBySpellID("player", checkID)
                                      or C_UnitAuras.GetPlayerAuraBySpellID(checkID)
                        if auraData then
                            hasSelfES = true
                            selfESExpiration = auraData.expirationTime
                            break
                        end
                    end
                    -- Show button if: ES missing entirely, OR Therazane's is active and duration is low
                    local showSelfButton = not hasSelfES
                    if hasSelfES and hasTherazanesResilience then
                        showSelfButton = self:NeedsRefresh(974, selfESExpiration)
                    end
                    if showSelfButton and esIcon then
                        self.buttons[id] = CreateButton(id, esIcon, "Cast on self", "macro",
                            "/cast [@player] " .. (esSpellName or ""), "Earth Shield", "Self", nil)
                        classBuff_spellIDs_this_pass[974] = true
                        id = id + 1
                    end
                end
            elseif class == "SHAMAN" then
                earthShieldHandled = true  -- not known/enabled; skip tankBuff/selfBuff entries
            end

            -- Rogue poisons, one pass per poisonGroup. The old per-entry check
            -- treated a group as done once any one poison in it was up, which
            -- never asked an Assassination rogue for their second Lethal.
            --   Slots: Lethal 2 for Assassination or Dragon-Tempered Blades, else 1;
            --          Non-Lethal 2 with Dragon-Tempered Blades, else 1. Capped by
            --          how many poisons of that kind the player actually knows.
            --   While a group has a free slot, every known, enabled poison of that
            --   kind that is not already up gets a button, so the player picks.
            --   An active poison gets a button only when it is running low.
            -- Each poison is looked up on its own: a buffVariants list would
            -- answer "one of these is up" and could not be counted.
            if class == "ROGUE" then
                local DRAGON_TEMPERED_BLADES_SPELL_ID = 381801
                local isAssassination = self:GetCurrentSpecID() == 259
                local hasDragonTempered = BH.PlayerKnowsSpell(DRAGON_TEMPERED_BLADES_SPELL_ID)
                local poisonSlots = {
                    lethal = (isAssassination or hasDragonTempered) and 2 or 1,
                    nonLethal = hasDragonTempered and 2 or 1,
                }
                for _, group in ipairs({ "lethal", "nonLethal" }) do
                    local known, activeExpiration, activeCount = {}, {}, 0
                    for _, buffInfo in ipairs(buffList) do
                        if buffInfo.poisonGroup == group then
                            local hasBuff, expiration = UnitHasBuff("player", buffInfo.spellID)
                            if hasBuff then
                                -- nil expiration means permanent/unreadable: 0 never nags
                                activeExpiration[buffInfo.spellID] = expiration or 0
                                activeCount = activeCount + 1
                            end
                            if BH.PlayerKnowsSpell(buffInfo.spellID) then
                                known[#known + 1] = buffInfo
                            end
                        end
                    end
                    local needed = math.min(poisonSlots[group], #known)
                    for _, buffInfo in ipairs(known) do
                        local spellID = buffInfo.spellID
                        if self:IsEnabled(spellID) then
                            local expArg = activeExpiration[spellID]
                            local show
                            if expArg then
                                show = self:NeedsRefresh(spellID, expArg)
                            else
                                show = activeCount < needed
                            end
                            if show then
                                local icon = GetSpellIcon(spellID)
                                if icon then
                                    self.buttons[id] = CreateButton(id, icon, "Apply poison", "spell", spellID, buffInfo.label, buffInfo.header, expArg)
                                    classBuff_spellIDs_this_pass[spellID] = true
                                    id = id + 1
                                end
                            end
                        end
                    end
                end
            end

            for _, buffInfo in ipairs(buffList) do
                if buffInfo.spellID and self:IsEnabled(buffInfo.spellID) then
                    if buffInfo.poisonGroup then
                        -- Already handled in the rogue poison batch above
                    elseif buffInfo.earthShield and earthShieldHandled then
                        -- Already handled in multi-shaman Earth Shield batch above
                    elseif buffInfo.healthstoneCheck then
                        -- Warlocks make their own, so they get a button rather
                        -- than the text reminder everyone else gets. Which cast
                        -- depends on whether they are alone -- see
                        -- BH.HealthstoneAction. buffInfo.spellID stays the config
                        -- key so the enable toggle and sound follow the entry
                        -- rather than the spell being offered.
                        local hsID, hsLabel = BH.HealthstoneAction()
                        if hsID and not BH.HasHealthstone() then
                            local icon = GetSpellIcon(hsID)
                            if icon then
                                self.buttons[id] = CreateButton(id, icon, "Make healthstones",
                                    "spell", hsID, hsLabel, nil, nil)
                                classBuff_spellIDs_this_pass[buffInfo.spellID] = true
                                id = id + 1
                            end
                        end
                    elseif buffInfo.weaponRune then
                        -- Death Knight runeforge: a permanent enchant, so this
                        -- reads the equipped weapon rather than an aura or a
                        -- temporary imbue. See WeaponNeedsRune.
                        --
                        -- The action is whichever is useful where the player is
                        -- standing -- the runeforge itself, or Death Gate to
                        -- reach one. buffInfo.spellID stays the config key so
                        -- the enable toggle and sound follow the entry, not the
                        -- spell that happens to be offered.
                        local needsRune, slotLabel = WeaponNeedsRune()
                        local actionID, actionLabel = RuneforgeAction()
                        if needsRune and actionID then
                            local icon = GetSpellIcon(actionID)
                            if icon then
                                self.buttons[id] = CreateButton(id, icon, "Runeforge your weapon",
                                    "spell", actionID, actionLabel, slotLabel, nil)
                                classBuff_spellIDs_this_pass[buffInfo.spellID] = true
                                id = id + 1
                            end
                        end
                    elseif buffInfo.weaponImbue then
                        -- Weapon imbue check (Shaman): show if spell is known but MH enchant is missing or expiring
                        if BH.PlayerKnowsSpell(buffInfo.spellID) then
                            local hasMH, mhExpiration = GetMainHandEnchantInfo()
                            local needsRefresh = self:NeedsRefresh(buffInfo.spellID, hasMH and mhExpiration or nil)
                            if needsRefresh then
                                local icon = GetSpellIcon(buffInfo.spellID)
                                if icon then
                                    self.buttons[id] = CreateButton(id, icon, "Apply imbue", "spell", buffInfo.spellID, buffInfo.label, nil, hasMH and mhExpiration or nil)
                                    classBuff_spellIDs_this_pass[buffInfo.spellID] = true
                                    id = id + 1
                                end
                            end
                        end
                    elseif buffInfo.tankBuff then
                        -- Tank-targeted buff (e.g. Earth Shield): show if spell is known and a tank needs it
                        if BH.PlayerKnowsSpell(buffInfo.spellID) then
                            local checkIDs = buffInfo.buffVariants or { buffInfo.spellID }
                            local tankName, allBuffed, lowestExpires = FindUnbuffedTank(checkIDs)
                            if not allBuffed and tankName then
                                -- Tank is completely missing the buff
                                local icon = GetSpellIcon(buffInfo.spellID)
                                if icon then
                                    local spellName = C_Spell.GetSpellName(buffInfo.spellID)
                                    self.buttons[id] = CreateButton(id, icon, "Cast on " .. tankName, "macro",
                                        "/cast [@" .. tankName .. "] " .. (spellName or ""), buffInfo.label, buffInfo.header, nil)
                                    classBuff_spellIDs_this_pass[buffInfo.spellID] = true
                                    id = id + 1
                                end
                            elseif allBuffed and lowestExpires and tankName then
                                -- All tanks have it, but check min duration
                                local needsRefresh = self:NeedsRefresh(buffInfo.spellID, lowestExpires)
                                if needsRefresh then
                                    local icon = GetSpellIcon(buffInfo.spellID)
                                    if icon then
                                        local spellName = C_Spell.GetSpellName(buffInfo.spellID)
                                        self.buttons[id] = CreateButton(id, icon, "Cast on " .. tankName, "macro",
                                            "/cast [@" .. tankName .. "] " .. (spellName or ""), buffInfo.label, buffInfo.header, lowestExpires)
                                        classBuff_spellIDs_this_pass[buffInfo.spellID] = true
                                        id = id + 1
                                    end
                                end
                            end
                        end
                    elseif buffInfo.selfBuff then
                        -- Self-buff check (e.g. Water/Lightning Shield, Earth Shield self): show if spell is known but buff is missing or expiring
                        -- Use UnitHasBuff("player") rather than PlayerHasBuff: the latter uses
                        -- GetPlayerAuraBySpellID which doesn't detect toggle/stance auras like
                        -- Lightning Shield or Water Shield (same issue as Devotion Aura on paladins).
                        if BH.PlayerKnowsSpell(buffInfo.spellID) then
                            local checkIDs = buffInfo.buffVariants or { buffInfo.spellID }
                            local hasBuff, buffExpiration = UnitHasBuff("player", checkIDs)
                            -- When buff is active: use expiration time, or 0 if nil (permanent/charge-based
                            -- auras like Lightning Shield return nil expiration, not 0).
                            -- When buff is missing: pass nil so NeedsRefresh knows it's absent.
                            local expArg = hasBuff and (buffExpiration or 0) or nil
                            local needsRefresh = self:NeedsRefresh(buffInfo.spellID, expArg)
                            if needsRefresh then
                                local icon = GetSpellIcon(buffInfo.spellID)
                                if icon then
                                    self.buttons[id] = CreateButton(id, icon, "Apply buff", "spell", buffInfo.spellID, buffInfo.label, buffInfo.header, expArg)
                                    classBuff_spellIDs_this_pass[buffInfo.spellID] = true
                                    id = id + 1
                                end
                            end
                        end
                    elseif buffInfo.petCheck then
                        -- handled above; always available even in M+
                    elseif buffInfo.healerOnly then
                        -- Healer-only buff: find first unbuffed healer
                        local healerName, allBuffed = FindUnbuffedHealer(buffInfo.spellID)
                        if not allBuffed and healerName then
                            local icon = GetSpellIcon(buffInfo.spellID)
                            if icon then
                                local spellName = C_Spell.GetSpellName(buffInfo.spellID)
                                self.buttons[id] = CreateButton(id, icon, "Cast on " .. healerName, "macro",
                                    "/cast [@" .. healerName .. "] " .. (spellName or ""), nil, nil, nil)
                                classBuff_spellIDs_this_pass[buffInfo.spellID] = true
                                id = id+1
                            end
                        end
                    else
                        -- Check all group/raid members for the buff
                        local checkIDs = buffInfo.buffVariants or buffInfo.spellID
                        local needsBuff = GroupNeedsBuff(checkIDs)
                        if needsBuff then
                            local castID = buffInfo.castSpellID or buffInfo.spellID
                            local icon = GetSpellIcon(castID)
                            if icon then
                                local cbBtn = CreateButton(id, icon, "Cast buff", "spell", castID, nil, nil, nil)
                                -- Outside a key, group-wide buffs stay visible in combat
                                -- (rebuff someone who died mid-fight). Inside a key they
                                -- are out-of-combat only, like every other button here
                                -- (user request 2026-10-17): parented to BH.frame, which
                                -- hides on PLAYER_REGEN_DISABLED.
                                if BH.challengeModeActive then
                                    cbBtn:SetParent(BH.frame)
                                else
                                    cbBtn.isCombatBuff = true
                                    cbBtn:SetParent(BH.combatBuffFrame)  -- stays visible in combat
                                end
                                -- No in-combat auto-hide. This used to register a
                                -- "[combat,buff:<name>]hide;show" state driver, but "buff" is
                                -- not a macro option the game knows, for ANY name (not just ones
                                -- with a colon, as first thought): RegisterStateDriver threw
                                -- "Unknown macro option: buff" right here, after CreateButton had
                                -- shown the button but before it was stored in self.buttons. The
                                -- teardown never saw it again, so it stayed on screen until
                                -- /reload with the buff up, and the rest of the pass was lost
                                -- (user report 2026-10-17, Skyfury, solo). The button now simply
                                -- goes on the next out-of-combat refresh.
                                self.buttons[id] = cbBtn
                                if not BH.challengeModeActive then hasCombatBuff = true end
                                classBuff_spellIDs_this_pass[buffInfo.spellID] = true
                                id = id+1
                            end
                        end
                    end
                end
            end
            end  -- normal class buff handling
        end
    end
    return id, hasPetButton, hasCombatBuff
end

-- Append the food, flask and oil buttons for this pass.
--
-- Takes the next free button index and the set of items already added, and
-- returns the index it reached. Threading `id` through the return rather than
-- sharing an upvalue is what lets this live outside UpdateButtons at all.
--
-- Each of the three walks the configured list and looks the item up in the bag
-- snapshot; see BH:RebuildBagCache for why that is not a bag walk.
function BH:CollectConsumableButtons(id, addedItems, class)
    -- Food, flask and augment rune are the same thing mechanically: an item in
    -- the bags that applies a timed buff. Only the buff lookup and the button
    -- caption differ, so they run through one loop rather than three
    -- near-identical blocks. (Oil stays separate below -- it applies to weapon
    -- slots and can produce two buttons.)
    --
    -- Each walks the configured list and looks the item up in the bag snapshot,
    -- so the work is proportional to how many consumables are configured rather
    -- than to how full the player's bags are -- and this runs on every
    -- UNIT_AURA. See BH:RebuildBagCache.
    --
    -- Side effect worth knowing: buttons appear in configured order rather than
    -- bag order, which is at least stable when items move around.
    local simpleConsumables = {
        { key = "food",        caption = "Use food",         hasBuff = HasFoodBuff },
        { key = "flask",       caption = "Use flask",        hasBuff = HasFlaskBuff },
        { key = "augmentRune", caption = "Use augment rune", hasBuff = HasAugmentRuneBuff },
    }

    for _, cat in ipairs(simpleConsumables) do
        local list = BH.consumables and BH.consumables[cat.key]
        if list then
            local hasBuff, expiration = cat.hasBuff()
            for _, itemID in ipairs(list) do
                local entry = not addedItems[itemID] and BH:GetBagEntry(itemID)
                if entry and self:IsEnabled(itemID) and MeetsLevelRequirement(itemID) then
                    -- (expiration or 0) rather than plain expiration: a
                    -- permanent buff -- hearty food, for instance -- reports no
                    -- expiration, and "hasBuff and nil or nil" collapses to nil,
                    -- which NeedsRefresh reads as the buff being absent.
                    local exp = hasBuff and (expiration or 0) or nil
                    if self:NeedsRefresh(itemID, exp) then
                        local icon = C_Item.GetItemIconByID(itemID)
                        self.buttons[id] = CreateButton(id, icon, cat.caption, "item", itemID,
                            nil, nil, exp, entry.link, entry.quality, entry.count)
                        addedItems[itemID] = true
                        id = id + 1
                    end
                end
            end
        end
    end

    -- oil: check for specific item IDs in bags, separate MH and OH buttons
    -- Skip oil buttons for any paladin with a Lightsmith Rite talent -- the Rite occupies
    -- the same main-hand enchant slot an oil would, so offering both competes for one slot.
    -- Gated on knowing the spell, not on spec: Lightsmith is Holy and Protection both.
    local hasLightsmithRite = false
    if class == "PALADIN" then
        hasLightsmithRite = BH.PlayerKnowsSpell(433568) or BH.PlayerKnowsSpell(433583)
    end
    if not hasLightsmithRite and BH.consumables and BH.consumables.oil then
        local hasMH, mhExpiration = GetMainHandEnchantInfo()
        local hasOH, ohExpiration = GetOffHandEnchantInfo()
        local hasOHWeapon = HasOffHandWeapon()
        
        -- Configured list rather than a bag walk; see the food block above.
        for _, itemID in ipairs(BH.consumables.oil) do
            local entry = BH:GetBagEntry(itemID)
            if entry and self:IsEnabled(itemID) and MeetsLevelRequirement(itemID) then
                local icon = C_Item.GetItemIconByID(itemID)
                -- Main hand oil button (show if missing or below min duration)
                local needsMH = self:NeedsRefresh(itemID, hasMH and mhExpiration or nil)
                if needsMH and not addedItems[itemID .. "_MH"] then
                    self.buttons[id] = CreateButton(id, icon, "Apply oil (MH)", "oil",
                        {itemID = itemID, slot = 16}, nil, "MH", hasMH and mhExpiration or nil,
                        entry.link, entry.quality, entry.count)
                    addedItems[itemID .. "_MH"] = true
                    id = id+1
                end
                -- Off hand oil button (show if missing or below min duration)
                if hasOHWeapon then
                    local needsOH = self:NeedsRefresh(itemID, hasOH and ohExpiration or nil)
                    if needsOH and not addedItems[itemID .. "_OH"] then
                        self.buttons[id] = CreateButton(id, icon, "Apply oil (OH)", "oil",
                            {itemID = itemID, slot = 17}, nil, "OH", hasOH and ohExpiration or nil,
                            entry.link, entry.quality, entry.count)
                        addedItems[itemID .. "_OH"] = true
                        id = id+1
                    end
                end
            end
        end
    end
    return id
end

-- Position the buttons built this pass, and size the frame around them.
--
-- Split out of UpdateButtons purely to make that function readable: this is
-- ~110 lines of pure geometry that touches nothing but self.buttons and the
-- layout settings, so it had no business sitting inline among the code that
-- decides which buttons should exist.
function BH:LayoutButtons(numButtons, buttons, frame)
    -- The options preview lays out its sample buttons with this too, passing
    -- its own list and host frame; everything else uses the real ones.
    -- 2.0 motion: the real buttons fade in over 0.15s when they appear from
    -- none (UI/Motion.lua; instant with Reduce motion). Alpha only, and only
    -- out of combat: the frame parents the secure buttons. Not on every
    -- rebuild -- they are laid out again every few seconds -- only on the
    -- step from no buttons to some.
    if not buttons then
        local before = self.sqShownButtons or 0
        self.sqShownButtons = numButtons
        if before == 0 and numButtons > 0 and not InCombatLockdown() then
            ns.Motion.Appear(self.frame, 0.15)
        end
    end
    buttons = buttons or self.buttons
    frame = frame or self.frame
    local size = (self.settings and self.settings.buttonSize) or 36
    local spacing = (self.settings and self.settings.buttonSpacing) or 5
    local labelHeight = 26
    local headerHeight = 12

    local grow = (self.settings and self.settings.growDirection) or "RIGHT"
    local layout = (self.settings and self.settings.layoutDirection) or "HORIZONTAL"
    
    -- Check if any button has a header (for consistent alignment)
    local anyHasHeader = false
    for i=1,numButtons do
        if buttons[i].header then
            anyHasHeader = true
            break
        end
    end
    
    -- Calculate total size for centering/outward
    local totalWidth = numButtons * size + (numButtons - 1) * spacing
    local totalBtnHeight = size + labelHeight + (anyHasHeader and headerHeight or 0)
    -- Vertical layout: label is beside icon, so row height is just icon + header
    local vertBtnHeight = size + (anyHasHeader and headerHeight or 0)
    local totalHeight = numButtons * totalBtnHeight + (numButtons - 1) * spacing
    local totalVertHeight = numButtons * vertBtnHeight + (numButtons - 1) * spacing
    
    for i=1,numButtons do
        local btn = buttons[i]
        local hasHeader = btn.header ~= nil
        
        if layout == "VERTICAL" then
            -- Vertical: icon is the button; the label goes where Label Position says
            btn:SetSize(size, size + (anyHasHeader and headerHeight or 0))
            btn.icon:SetSize(size, size)
            local iconOffset = anyHasHeader and -headerHeight or 0
            btn.icon:ClearAllPoints()
            btn.icon:SetPoint("TOPLEFT", btn, "TOPLEFT", 0, iconOffset)
            if hasHeader then
                btn.header:ClearAllPoints()
                btn.header:SetPoint("BOTTOM", btn.icon, "TOP", 0, 1)
                btn.header:SetWidth(0)  -- unconstrained
            end
            BH.PlaceButtonLabel(btn, size, true)
        else
            -- Horizontal: icon on top; the label goes where Label Position says
            btn:SetSize(size, totalBtnHeight)
            btn.icon:SetSize(size, size)
            local iconOffset = anyHasHeader and -headerHeight or 0
            btn.icon:ClearAllPoints()
            btn.icon:SetPoint("TOP", btn, "TOP", 0, iconOffset)
            if hasHeader then
                btn.header:ClearAllPoints()
                btn.header:SetPoint("TOP", btn, "TOP", 0, 0)
                btn.header:SetWidth(0)  -- unconstrained
            end
            BH.PlaceButtonLabel(btn, size, false)
        end
        
        -- Show/hide label based on setting
        if BH.settings.showLabelText ~= false then
            btn.label:Show()
        else
            btn.label:Hide()
        end
        
        -- Position buttons inside the frame based on grow direction
        btn:ClearAllPoints()
        local idx = i - 1
        
        if layout == "VERTICAL" then
            local yStep = vertBtnHeight + spacing
            if grow == "UP" then
                btn:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, idx * yStep)
            elseif grow == "OUTWARD" then
                local yOfs = totalVertHeight / 2 - idx * yStep - vertBtnHeight / 2
                btn:SetPoint("LEFT", frame, "LEFT", 0, yOfs)
            else -- DOWN (default)
                btn:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -(idx * yStep))
            end
        else
            local xStep = size + spacing
            if grow == "LEFT" then
                btn:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -(idx * xStep), 0)
            elseif grow == "OUTWARD" then
                local xOfs = -totalWidth / 2 + idx * xStep + size / 2
                btn:SetPoint("TOP", frame, "TOP", xOfs, 0)
            else -- RIGHT (default)
                btn:SetPoint("TOPLEFT", frame, "TOPLEFT", idx * xStep, 0)
            end
        end
        btn:Show()
    end

    -- Resize the frame to encompass all buttons so the drag handle stays clear
    if numButtons > 0 then
        if layout == "VERTICAL" then
            frame:SetSize(size, totalVertHeight)
        else
            frame:SetSize(totalWidth, totalBtnHeight)
        end
    else
        frame:SetSize(1, 1)
    end
end

function BH:UpdateButtons()
    if not IsLoggedIn() then return end  -- avoid running early when API is incomplete
    if InCombatLockdown() then
        -- Secure buttons cannot be created or changed under lockdown, but the
        -- plain reminder frames can be, and refusing to update them here is
        -- what made Beacon and Earth Shield disappear for the whole pull.
        self:UpdateAllReminders()
        return
    end

    -- Same out of combat whenever the client is hiding auras. Every aura read
    -- comes back nil, nil counts as "missing", and the rebuild below then
    -- showed EVERY button at once (user report 2026-10-15, 12.1.5 labyrinth,
    -- surviving /reload, cured by relog -- so a client state left stuck, not
    -- the zone itself). Keep the last readable pass's buttons.
    --
    -- Deliberately NOT gated on the addon restrictions as well: ChallengeMode
    -- is active for a whole Mythic+ key, so that would freeze the buttons
    -- between pulls, where they have always worked.
    if BH.Gate.AurasHidden() then
        self:UpdateAllReminders()
        return
    end

    -- Don't tear the buttons down in the middle of a click.
    --
    -- This function is driven by UNIT_AURA, which fires for every unit in the
    -- group on every aura change, so in a group it runs more or less constantly
    -- on its 0.2s debounce. The teardown below hides, unanchors and reparents
    -- every button; if that lands between the player's mouse-down and mouse-up
    -- the click is swallowed and the spell never goes off. Worse, buttons are
    -- recycled from a pool in order, so the frame under the cursor can come
    -- back as a different action entirely.
    --
    -- The window that matters is only while a mouse button is actually held.
    -- Deferring on hover alone is wrong: after clicking a button the cursor
    -- naturally stays on it, so the rebuild never ran and the button the player
    -- just used sat there stale until they moved the mouse away.
    --
    -- The retry count is capped as a backstop, so a stuck mouse button or an
    -- input state we did not anticipate can never stall updates indefinitely.
    if not self.unlockMode and IsMouseButtonDown and IsMouseButtonDown()
        and _updateButtonsDeferrals < 6 then
        for _, btn in ipairs(self.buttons) do
            if btn:IsShown() and btn:IsMouseOver() then
                if not _updateButtonsHoverRetry then
                    _updateButtonsHoverRetry = true
                    _updateButtonsDeferrals = _updateButtonsDeferrals + 1
                    C_Timer.After(0.1, function()
                        _updateButtonsHoverRetry = false
                        BH:UpdateButtons()
                    end)
                end
                return
            end
        end
    end
    _updateButtonsDeferrals = 0

    -- clear existing buttons - return to pool so frames are reused next UpdateButtons call
    for i,btn in ipairs(self.buttons) do
        btn:Hide()
        btn:ClearAllPoints()
        btn:SetScript("OnUpdate", nil)
        -- Stop any glow before the frame goes back in the pool: it would
        -- otherwise still be glowing when reused for a different reminder.
        ns.Glow.Hide(btn.glowHost)
        btn.expirationTime = nil
        btn.isCombatBuff = nil
        UnregisterStateDriver(btn, "visibility")  -- remove any per-button combat-buff state driver
        btn:SetParent(nil)
        table.insert(SQ_BUTTON_POOL, btn)
    end
    self.buttons = {}
    -- Clean up dummy preview buttons
    if self.unlockDummyBtns then
        for _, db in ipairs(self.unlockDummyBtns) do db:Hide() end  -- pooled: hide, never orphan
        self.unlockDummyBtns = nil
    end

    local id = 1
    local addedItems = {}  -- track items already added to avoid duplicates
    -- Class buffs first, so they land in the centre of the row.
    -- Show only when someone in the group is missing the buff
    -- Track which spellIDs generated buttons this pass (for per-buff sound alerts)
    local classBuff_spellIDs_this_pass = {}
    local _, class = UnitClass("player")
    local hasPetButton, hasCombatBuff
    id, hasPetButton, hasCombatBuff =
        self:CollectClassBuffButtons(id, addedItems, class, classBuff_spellIDs_this_pass)

    self:FireClassBuffSounds(classBuff_spellIDs_this_pass)

    -- Symbiotic Relationship button, food/flask/oil consumable buttons, and reminder
    -- frames only show when in a valid instance (or preview mode), not in open world.
    if ShouldShowButtons() then

    -- Symbiotic Relationship button for Druids with the talent
    -- Guardian Druid: cast on healer | Restoration Druid: cast on tank
    if class == "DRUID" and BH.PlayerKnowsSpell(SYMBIOTIC_CAST_SPELL_ID) then
        -- Check if player already has the buff
        local hasBuff = C_UnitAuras.GetPlayerAuraBySpellID(SYMBIOTIC_AURA_SPELL_ID)
        if not hasBuff then
            local specID = PlayerUtil and PlayerUtil.GetCurrentSpecID and PlayerUtil.GetCurrentSpecID()
            local targetRole = nil
            if specID == 104 then       -- Guardian
                targetRole = "HEALER"
            elseif specID == 105 then   -- Restoration
                targetRole = "TANK"
            end
            if targetRole then
                -- Find a group member with the matching role
                local targetName = nil
                local groupSize = GetNumGroupMembers()
                local isRaid = IsInRaid()
                for i = 1, groupSize do
                    local unit = isRaid and ("raid" .. i) or ("party" .. i)
                    if UnitExists(unit) and not UnitIsUnit(unit, "player")
                        and not UnitIsDeadOrGhost(unit) and UnitIsConnected(unit) then
                        if UnitGroupRolesAssigned(unit) == targetRole then
                            targetName = UnitName(unit)
                            break
                        end
                    end
                end
                if targetName then
                    local icon = GetSpellIcon(SYMBIOTIC_CAST_SPELL_ID)
                    if icon then
                        local spellName = C_Spell.GetSpellName(SYMBIOTIC_CAST_SPELL_ID)
                        self.buttons[id] = CreateButton(id, icon, "Cast on " .. targetName, "macro",
                            "/cast [@" .. targetName .. "] " .. (spellName or ""), nil, nil, nil)
                        id = id + 1
                    end
                end
            end
        end
    end

    -- Emerald Coach's Whistle button – show if trinket is equipped and coaching needs refreshing
    do
        local hasWhistle = GetInventoryItemID("player", 13) == COACH_WHISTLE_ITEM_ID
                        or GetInventoryItemID("player", 14) == COACH_WHISTLE_ITEM_ID
        local coachExp = hasWhistle and GetCoachedAllyExpiration()
        local needsCoach = hasWhistle and self:NeedsRefresh(COACH_WHISTLE_ITEM_ID, coachExp)
        if needsCoach then
            -- Find a real player party member to coach (prefer DAMAGER, then HEALER, then TANK)
            local targetName = nil
            local groupSize = GetNumGroupMembers()
            local isRaid = IsInRaid()
            for _, role in ipairs({"DAMAGER", "HEALER", "TANK"}) do
                for i = 1, groupSize do
                    local unit = isRaid and ("raid" .. i) or ("party" .. i)
                    if UnitExists(unit) and not UnitIsUnit(unit, "player")
                        and UnitIsPlayer(unit)
                        and not UnitIsDeadOrGhost(unit) and UnitIsConnected(unit) then
                        if UnitGroupRolesAssigned(unit) == role then
                            targetName = UnitName(unit)
                            break
                        end
                    end
                end
                if targetName then break end
            end
            if targetName then
                local icon = C_Item.GetItemIconByID(COACH_WHISTLE_ITEM_ID)
                if icon then
                    self.buttons[id] = CreateButton(id, icon, "Coach: " .. targetName, "macro",
                        "/use [@" .. targetName .. "] Emerald Coach's Whistle", nil, nil, nil)
                    id = id + 1
                end
            end
        end
    end

    id = self:CollectConsumableButtons(id, addedItems, class)

    else
        -- Not in a valid instance: hide instance-only reminder frames
        if self.beaconReminderFrame then self.beaconReminderFrame:Hide() end
        if self.earthShieldReminderFrame then self.earthShieldReminderFrame:Hide() end
        if self.symbioticReminderFrame then self.symbioticReminderFrame:Hide() end
    end -- ShouldShowButtons

    self:LayoutButtons(id - 1)

    -- show/hide main frame depending on buttons
    if self.unlockMode then
        -- In preview mode, hide any real buttons and show 3 dummy non-interactable buttons
        for i, btn in ipairs(self.buttons) do
            -- Unregister any secure state drivers that might override Hide()
            UnregisterStateDriver(btn, "visibility")
            btn:Hide()
            btn:SetParent(nil)
        end
        self.buttons = {}
        -- Also hide the overlay frames (combat buff, pet) so they don't show
        -- orphaned buttons that might not have been fully reparented
        if BH.petFrame then BH.petFrame:Hide() end
        if BH.combatBuffFrame then BH.combatBuffFrame:Hide() end
        local size = (self.settings and self.settings.buttonSize) or 36
        local spacing = (self.settings and self.settings.buttonSpacing) or 5
        local layout = (self.settings and self.settings.layoutDirection) or "HORIZONTAL"
        local grow = (self.settings and self.settings.growDirection) or "RIGHT"
        local showLabel = (self.settings and self.settings.showLabelText ~= false)
        local dummyIcons = {
            "Interface\\Icons\\INV_Misc_QuestionMark",
            "Interface\\Icons\\INV_Misc_Gear_01",
            "Interface\\Icons\\Spell_Nature_Rejuvenation",
        }
        -- The three placeholders are created ONCE and reused. This branch runs
        -- on every UpdateButtons while unlocked, and UpdateButtons is driven
        -- by UNIT_AURA, so building fresh frames here (and orphaning the old
        -- ones with SetParent(nil) -- WoW never frees a frame) leaked three
        -- frames per rebuild, several times a second in a group.
        local pool = self.unlockDummyPool
        if not pool then
            pool = {}
            for i = 1, 3 do
                local db = CreateFrame("Frame", nil, self.frame)
                db:SetFrameStrata("MEDIUM")
                db.icon = db:CreateTexture(nil, "ARTWORK")
                db.icon:SetPoint("TOP", db, "TOP", 0, 0)
                db.icon:SetTexture(dummyIcons[i])
                db.icon:SetDesaturated(true)
                db.icon:SetAlpha(0.5)
                db.label = db:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                db.label:SetPoint("TOP", db.icon, "BOTTOM", 0, -2)
                db.label:SetJustifyH("CENTER")
                db.label:SetText("Preview")
                db.label:SetTextColor(0.6, 0.6, 0.6)
                pool[i] = db
            end
            self.unlockDummyPool = pool
        end
        self.unlockDummyBtns = pool
        local labelHeight = showLabel and 14 or 0
        local btnHeight = size + labelHeight
        for i = 1, 3 do
            local db = pool[i]
            db:SetSize(size, btnHeight)
            db.icon:SetSize(size, size)
            ns.Shapes.SetMask(db, (self.settings and self.settings.buttonIconShape) or "none", db.icon)
            db.label:SetWidth(size)
            db.label:SetShown(showLabel)
            local idx = i - 1
            db:ClearAllPoints()
            if layout == "VERTICAL" then
                local yStep = btnHeight + spacing
                if grow == "UP" then
                    db:SetPoint("BOTTOMLEFT", self.frame, "BOTTOMLEFT", 0, idx * yStep)
                else
                    db:SetPoint("TOPLEFT", self.frame, "TOPLEFT", 0, -(idx * yStep))
                end
            else
                local xStep = size + spacing
                if grow == "LEFT" then
                    db:SetPoint("TOPRIGHT", self.frame, "TOPRIGHT", -(idx * xStep), 0)
                else
                    db:SetPoint("TOPLEFT", self.frame, "TOPLEFT", idx * xStep, 0)
                end
            end
            db:Show()
        end
        if layout == "VERTICAL" then
            self.frame:SetSize(size, 3 * btnHeight + 2 * spacing)
        else
            self.frame:SetSize(3 * size + 2 * spacing, btnHeight)
        end
        self.frame:Show()
    elseif id == 1 then
        -- No buttons and not previewing - clean up and hide
        if self.unlockDummyBtns then
            for _, db in ipairs(self.unlockDummyBtns) do db:Hide() end  -- pooled: hide, never orphan
            self.unlockDummyBtns = nil
        end
        self.frame:Hide()
        BH.petFrame:Hide()
        BH.combatBuffFrame:Hide()
    else
        -- Real buttons exist - clean up dummies
        if self.unlockDummyBtns then
            for _, db in ipairs(self.unlockDummyBtns) do db:Hide() end  -- pooled: hide, never orphan
            self.unlockDummyBtns = nil
        end
        self.frame:Show()
        if hasPetButton then BH.petFrame:Show() else BH.petFrame:Hide() end
        if hasCombatBuff then BH.combatBuffFrame:Show() else BH.combatBuffFrame:Hide() end
    end

    -- The green tint on this frame is applied by SetAllFramesPreview along
    -- with every other movable frame. It used to be duplicated here, which
    -- meant two overlay textures stacked on the same frame.

    self:UpdateAllReminders()
end

-- Hide the reminders that are not worth showing in combat. There is no matching
-- "show" call: on the way out of combat UpdateAllReminders re-evaluates every
-- frame on its merits, which is the same path used everywhere else.
function BH:HideCombatUnsafeReminders()
    for _, def in ipairs(BH.REMINDERS) do
        if not def.combatSafe then
            local frame = self[def.key .. "ReminderFrame"]
            if frame then frame:Hide() end
        end
    end
end

-- Whether a reminder frame should take the mouse. Every reminder's show path
-- goes through this rather than repeating `unlockMode or not locked` eleven
-- times, which is what let the pet reminder quietly disagree with the other ten.
--
-- The combat clause is the BigWigs click-through pattern: now that combat-safe
-- reminders stay up during a pull, a 340px banner sitting over the action bars
-- must not be able to swallow a click, and there is nothing useful to click it
-- for mid-fight anyway.
function BH:ReminderMouseEnabled(locked)
    if self.unlockMode then return true end   -- dragging is the whole point
    if locked then return false end
    if InCombatLockdown() then return false end
    return true
end

-- Every plain (non-secure) reminder frame, refreshed in one place.
--
-- Split out of UpdateButtons because UpdateButtons returns early under
-- InCombatLockdown -- it has to, it owns the secure buttons -- and that early
-- return was taking the reminder frames down with it. These frames have no
-- secure children, so they can be updated freely in combat; each individual
-- Update*Reminder decides for itself whether it is combat-safe, via
-- ShouldShowReminders versus ShouldShowButtons.
-- Clear a reminder the moment the player casts the thing it is asking for.
--
-- Needed because the three combat-safe reminders detect *absence* of a buff,
-- and in combat auras are secret: applying the buff is invisible to us, so the
-- reminder would sit there for the rest of the fight. The player's own cast is
-- not an aura read, so it still gets through, and it is decisive -- if you just
-- cast Earth Shield, you no longer need reminding to cast Earth Shield.
--
-- Optimistic by design. If the cast was wasted (wrong target, immediately
-- dispelled) the next readable pass puts the reminder straight back.
function BH:OnReminderSpellcast(spellID)
    -- Only the player's own cast reaches here, and that spellID is readable --
    -- but launder it anyway so a future secret one degrades to "no match"
    -- rather than throwing on the comparison below.
    local id = BH.Secrets.SafeNumber(spellID, nil)
    if not id then return end

    for _, beaconID in ipairs(BEACON_AURA_IDS) do
        if id == beaconID then
            local needed = self.beaconsNeededLast or 1
            self.beaconsBelieved = math.min(needed, (self.beaconsBelieved or 0) + 1)
            self:UpdateBeaconReminder()
            return
        end
    end

    for _, esID in ipairs(ES_AURA_IDS) do
        if id == esID then
            local needed = self.esNeededLast or 1
            self.esBelieved = math.min(needed, (self.esBelieved or 0) + 1)
            self:UpdateEarthShieldReminder()
            return
        end
    end

    if id == SYMBIOTIC_CAST_SPELL_ID then
        if self.symbioticReminderFrame and not self.unlockMode then
            self.symbioticReminderFrame:Hide()
        end
    end
end

-- How many of the tracked units are still alive and present.
local function CountLivingTracked(guids)
    if not guids or #guids == 0 then return 0 end
    local wanted = {}
    for _, guid in ipairs(guids) do wanted[guid] = true end
    local n = 0
    for _, unit in ipairs(GetGroupUnits()) do
        if UnitExists(unit) and not UnitIsDeadOrGhost(unit) then
            local guid = UnitGUID(unit)
            if guid and wanted[guid] then n = n + 1 end
        end
    end
    return n
end

-- Bring a combat-safe reminder back when its buff is lost while auras are secret.
--
-- OnReminderSpellcast covers the buff being applied. This covers the other
-- direction, which is the harder half: once auras are unreadable we cannot see
-- a beacon or Earth Shield fall off, so without this the reminder would stay
-- hidden for the rest of the fight after one cast.
--
-- The readable signal we do have is death. A beacon or Earth Shield is lost
-- when its target dies, and UnitIsDeadOrGhost stays readable when the aura does
-- not -- the same reasoning the M+ Death Tally uses. So each readable pass
-- records which GUIDs carry the buff, and this checks whether enough of them
-- are still standing.
--
-- What this still cannot see: Earth Shield running out of charges, a dispel, or
-- Symbiotic Relationship expiring on its timer. There is no readable signal for
-- any of those while auras are secret.
function BH:PollBlindReminderLoss()
    if not InCombatLockdown() then return end
    if not BH.Secrets.AurasAreSecret() then return end
    if self.unlockMode then return end

    local changed = false

    -- The clamp on *AliveLast below matters: a battle rez brings the unit back
    -- but not the beacon, so the tracked count must only ever fall.
    -- Beacons. Note this counts *drops*, not absolutes: a beacon cast while
    -- blind lands on a unit we cannot identify, so it never joins beaconedGUIDs
    -- and an absolute comparison would read as "still missing" and re-show the
    -- reminder the instant it was correctly hidden. Only an actual fall in the
    -- number of living tracked units means a beacon was lost.
    if self.beaconedGUIDs and #self.beaconedGUIDs > 0 then
        local aliveNow  = CountLivingTracked(self.beaconedGUIDs)
        local alivePrev = self.beaconedAliveLast or aliveNow
        if aliveNow < alivePrev then
            self.beaconsBelieved = math.max(0, (self.beaconsBelieved or 0) - (alivePrev - aliveNow))
            changed = true
        end
        self.beaconedAliveLast = math.min(alivePrev, aliveNow)
    end

    if self.esGUIDs and #self.esGUIDs > 0 then
        local aliveNow  = CountLivingTracked(self.esGUIDs)
        local alivePrev = self.esAliveLast or aliveNow
        if aliveNow < alivePrev then
            self.esBelieved = math.max(0, (self.esBelieved or 0) - (alivePrev - aliveNow))
            changed = true
        end
        self.esAliveLast = math.min(alivePrev, aliveNow)
    end

    -- Let the normal update path decide what to show; it reads the same
    -- believed counts, so there is one place that owns the decision.
    if changed then
        self:UpdateBeaconReminder()
        self:UpdateEarthShieldReminder()
    end
end

-- Ticker for the above. Same AnimationGroup idiom as the Battle Res Counter and
-- Death Tally -- cheaper than an OnUpdate, and the handler bails immediately
-- unless we are actually blind, so out of combat this costs a function call
-- every half second.
do
    -- Deliberately NOT parented to BH.frame: that frame is hidden on entering
    -- combat, and an AnimationGroup on a hidden frame stops running -- which
    -- would kill this ticker at exactly the moment it becomes useful. This host
    -- is an empty frame that draws nothing and is never hidden.
    local host = CreateFrame("Frame", nil, UIParent)
    host:SetSize(1, 1)
    host:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 0, 0)
    host:Show()
    BH.tickerHost = host

    local ticker = host:CreateAnimationGroup()
    ticker:SetLooping("REPEAT")
    ticker:SetScript("OnLoop", function() BH:PollBlindReminderLoss() end)
    local anim = ticker:CreateAnimation()
    anim:SetDuration(0.5)
    ticker:Play()
    BH.blindReminderTicker = ticker
end
