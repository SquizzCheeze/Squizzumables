-- Reminders/RemindersTab.lua
-- The Text Reminders options page: the class reminder, repair, instance
-- sounds, the bag and healthstone reminders, feast announce and the role CC
-- alert. Its settings are a settings description (TEXT_REMINDERS, below);
-- BuildTextRemindersTab draws each section between the few hand-built parts.
--
-- Moved out of Squizzumables.lua unchanged in 2.0 phase 2 (the split). It
-- reaches the core only through BH.

local addonName, ns = ...
local BH = ns.BH

local SQ_COLORS        = ns.SQ_COLORS
local CreateSQEditBox  = ns.CreateSQEditBox
local CreateSQDropdown = ns.CreateSQDropdown

-- ============================================================================
-- Text Reminders Settings Tab
-- ============================================================================

-- The page's settings, described once (UI/Settings.lua; 2.0 phase 3): each
-- row is the setting's default, its control and its search entry. The
-- defaults used to live in Squizzumables.lua's defaultSettings and again as
-- getter fallbacks here (Repair's threshold fell back to 20 against a real
-- default of 50). Labels and tooltips come from each reminder's BH.REMINDERS
-- entry, as AddReminderSection's did. Hand-built in BuildTextRemindersTab:
-- the page notes, the feast channel grid (a keyed set of dropdowns) and the
-- feast message box (it has a placeholder).
local R = BH.REMINDERS_BY_KEY

local function On(key) return function(s) return s[key] ~= false end end
local function Update(name) return function() if BH[name] then BH[name](BH) end end end

-- A reminder's scale and lock rows, as AddReminderSection made them: the
-- scale only re-scales on a drag of the slider, the lock stops the drag.
local function ScaleApply(frameKey)
    return function(v, userInput)
        local f = BH[frameKey]
        if userInput and f then f:SetScale(v) end
    end
end
local function LockApply(frameKey)
    return function(v)
        local f = BH[frameKey]
        if f then f:SetMovable(not v); f:EnableMouse(not v) end
    end
end
local SCALE_TIP = "Size of the on-screen reminder, as a percentage."
local LOCK_TIP  = "Stops the reminder being dragged. Use Preview on the Settings tab to reposition it."

local function RoleWatched(s) return s.healerCCAlertEnabled or s.roleCCAlertTank end

local TEXT_REMINDERS = ns.Settings.Describe({
    sections = {
        -- The one Class Reminder (2.0, user request 2026-10-16): Beacon, Earth
        -- Shield, Symbiotic and No Pet each belong to one class, so they share
        -- one frame -- one position, scale and lock -- and each keeps its own
        -- on/off. No Pet's settings came over from Class Buffs. The lock also
        -- writes the four old <key>ReminderLocked, which the reminders' own
        -- code still reads.
        class = {
            { type = "header", label = "CLASS REMINDER" },
            { type = "text",
              label = "Beacon, Earth Shield, Symbiotic Relationship and No Pet each belong to one class, so "
                  .. "they share one frame: one place on screen, one size and one lock. Turn each on or off "
                  .. "below." },
            { key = "classReminderScale", type = "slider", default = 1.0, scale = 100,
              min = 50, max = 300, step = 5,
              label = "Class Reminder Scale", tip = "Size of the class reminder, as a percentage.",
              apply = function(v, userInput)
                  if userInput and BH.classReminderFrame then BH.classReminderFrame:SetScale(v) end
              end },
            { key = "classReminderLocked", type = "check", default = false,
              label = "Lock Class Reminder",
              tip = "Stops the class reminder being dragged. Unlock Frames overrides this while you are "
                  .. "positioning things.",
              apply = function(v)
                  for _, key in ipairs(BH.CLASS_REMINDER_KEYS) do
                      BH.settings[key .. "ReminderLocked"] = v
                      local f = BH[key .. "ReminderFrame"]
                      if f then f:EnableMouse(BH:ReminderMouseEnabled(v)) end
                  end
              end },
            { type = "divider" },
            { key = "beaconReminderEnabled", type = "check", default = true,
              label = R.beacon.enableLabel, tip = R.beacon.tooltip, apply = Update("UpdateBeaconReminder") },
            { key = "earthShieldReminderEnabled", type = "check", default = true,
              label = R.earthShield.enableLabel, tip = R.earthShield.tooltip,
              apply = Update("UpdateEarthShieldReminder") },
            { key = "symbioticReminderEnabled", type = "check", default = true,
              label = R.symbiotic.enableLabel, tip = R.symbiotic.tooltip, apply = Update("UpdateSymbioticReminder") },
            { key = "petReminderEnabled", type = "check", default = true,
              label = R.pet.enableLabel, tip = R.pet.tooltip, apply = Update("UpdatePetReminder") },
        },

        -- Not a class reminder: anyone's gear wears out. Its own sub-tab,
        -- frame, position, scale and lock.
        repair = {
            { type = "header", label = R.repair.sectionHeader, tip = R.repair.tooltip },
            { key = "repairReminderEnabled", type = "check", default = true,
              label = R.repair.enableLabel, tip = R.repair.tooltip, apply = Update("UpdateRepairReminder") },
            { key = "repairReminderThreshold", type = "slider", default = 50, min = 0, max = 100, step = 1,
              label = "Durability Threshold (%)",
              tip = "Show the reminder once your most damaged equipped item falls below this percentage.",
              when = On("repairReminderEnabled"), apply = Update("UpdateRepairReminder") },
            { key = "repairReminderScale", type = "slider", default = 1.0, scale = 100, min = 50, max = 200, step = 5,
              label = R.repair.scaleLabel, tip = SCALE_TIP,
              when = On("repairReminderEnabled"), apply = ScaleApply("repairReminderFrame") },
            { key = "repairReminderLocked", type = "check", default = false,
              label = R.repair.lockLabel, tip = LOCK_TIP,
              when = On("repairReminderEnabled"), apply = LockApply("repairReminderFrame") },
        },

        sounds = {
            { key = "skyreachSoundEnabled", type = "check", default = true,
              label = "Play Sound on Skyreach (Mythic)",
              tip = "Plays a sound when you enter The Everbloom on Mythic difficulty, as a reminder about the "
                  .. "Skyreach affix pull." },
        },

        -- One section for the combined bag frame (enable / scale / lock /
        -- position), then the per-category watch toggles that decide what it
        -- can mention -- the four bag categories share one frame, so the old
        -- per-category *Enabled keys survive as watch toggles -- then the
        -- healthstone reminder.
        bags = {
            { type = "header", label = R.bags.sectionHeader, tip = R.bags.tooltip },
            { key = "bagsReminderEnabled", type = "check", default = true,
              label = R.bags.enableLabel, tip = R.bags.tooltip, apply = Update("UpdateBagReminder") },
            { key = "bagsReminderScale", type = "slider", default = 1.0, scale = 100, min = 50, max = 200, step = 5,
              label = R.bags.scaleLabel, tip = SCALE_TIP,
              when = On("bagsReminderEnabled"), apply = ScaleApply("bagsReminderFrame") },
            { key = "bagsReminderLocked", type = "check", default = false,
              label = R.bags.lockLabel, tip = LOCK_TIP,
              when = On("bagsReminderEnabled"), apply = LockApply("bagsReminderFrame") },
            { key = "foodReminderEnabled", type = "check", default = true, indent = 28,
              label = "Watch food", tip = "Include this in the bag reminder when you have none of it.",
              when = On("bagsReminderEnabled"), apply = Update("UpdateBagReminder") },
            { key = "flaskReminderEnabled", type = "check", default = true, indent = 28,
              label = "Watch flasks", tip = "Include this in the bag reminder when you have none of it.",
              when = On("bagsReminderEnabled"), apply = Update("UpdateBagReminder") },
            { key = "oilReminderEnabled", type = "check", default = true, indent = 28,
              label = "Watch weapon oils", tip = "Include this in the bag reminder when you have none of it.",
              when = On("bagsReminderEnabled"), apply = Update("UpdateBagReminder") },
            { key = "augmentRuneReminderEnabled", type = "check", default = true, indent = 28,
              label = "Watch augment runes", tip = "Include this in the bag reminder when you have none of it.",
              when = On("bagsReminderEnabled"), apply = Update("UpdateBagReminder") },
            { key = "bagsLowThreshold", type = "slider", default = 1, min = 0, max = 10, step = 1, indent = 28,
              label = "Warn when running low (0 = off)",
              tip = "Also show the bag reminder when you have this many or fewer of a watched consumable left, "
                  .. "e.g. \"LOW ON FLASK (1 LEFT)\". Having none is still shown first.",
              when = On("bagsReminderEnabled"), apply = Update("UpdateBagReminder") },
            { type = "header", label = R.healthstone.sectionHeader, tip = R.healthstone.tooltip },
            { key = "healthstoneReminderEnabled", type = "check", default = true,
              label = R.healthstone.enableLabel, tip = R.healthstone.tooltip,
              apply = Update("UpdateHealthstoneReminder") },
            { key = "healthstoneReminderScale", type = "slider", default = 1.0, scale = 100,
              min = 50, max = 200, step = 5,
              label = R.healthstone.scaleLabel, tip = SCALE_TIP,
              when = On("healthstoneReminderEnabled"), apply = ScaleApply("healthstoneReminderFrame") },
            { key = "healthstoneReminderLocked", type = "check", default = false,
              label = R.healthstone.lockLabel, tip = LOCK_TIP,
              when = On("healthstoneReminderEnabled"), apply = LockApply("healthstoneReminderFrame") },
        },

        feastEnable = {
            { key = "feastAnnounceEnabled", type = "check", default = true,
              label = "Enable Feast Announce",
              tip = "Announces to chat when you drop a feast, and alerts other Squizzumables users in your group "
                  .. "with a sound." },
        },
        feastSound = {
            { key = "feastAlertSound", type = "sound", default = "None",
              label = "Alert sound (plays when a feast is placed)",
              tip = "Sound played to you and to other Squizzumables users in the group when a feast is dropped.",
              when = On("feastAnnounceEnabled") },
        },

        -- Role CC alert. healerCCAlertEnabled is the long-standing key for
        -- healer tracking and is kept as-is so existing profiles are
        -- unaffected; roleCCAlertTank was added in 1.60 and defaults off, so
        -- nobody gets a new alert they did not ask for. Everything after the
        -- two roles only matters once one of them is being watched.
        cc = {
            { type = "text",
              label = "Plays a sound and shows an alert when a watched party or raid member is crowd controlled. "
                  .. "Pick which roles to watch." },
            { key = "healerCCAlertEnabled", type = "check", default = false,
              label = "Alert when healer is CC'd",
              tip = "Watch group healers and raise the alert when one is crowd controlled.",
              apply = function() BH:RefreshRoleCCWatchList(); BH:UpdateRoleCCFrame() end },
            { key = "roleCCAlertTank", type = "check", default = false,
              label = "Alert when tank is CC'd",
              tip = "Watch group tanks and raise the alert when one is crowd controlled. Shares the frame and "
                  .. "sound with the healer alert; the label names whichever role is affected.",
              apply = function() BH:RefreshRoleCCWatchList(); BH:UpdateRoleCCFrame() end },
            { key = "healerCCReminderLocked", type = "check", default = false,
              label = "Lock Position", tip = "Stops the role CC alert being dragged.",
              when = RoleWatched,
              apply = function(v)
                  if BH.healerCCReminderFrame then
                      BH.healerCCReminderFrame:SetMovable(not v)
                      BH.healerCCReminderFrame:EnableMouse(BH:ReminderMouseEnabled(v))
                  end
              end },
            { key = "healerCCReminderScale", type = "slider", default = 1.0, scale = 100,
              min = 50, max = 200, step = 5, width = 200,
              label = "Scale", tip = "Size of the role CC alert, as a percentage.",
              when = RoleWatched,
              apply = function(v)
                  if BH.healerCCReminderFrame then BH.healerCCReminderFrame:SetScale(v) end
              end },
            { key = "healerCCAlertSound", type = "sound", default = "None",
              label = "Alert sound", tip = "Sound played when a watched healer or tank is crowd controlled.",
              when = RoleWatched },
        },
    },
})

function BH:BuildTextRemindersTab(parent)
    -- Split by what the reminder is about rather than one long scroll. The
    -- dividers and section headings that used to separate these are gone: the
    -- sub-tab label says the same thing, and keeping both would name every
    -- section twice.
    local pages = ns.SubTabs.Create(parent, {
        { key = "class",  label = "Class" },
        { key = "repair", label = "Repair" },
        { key = "sounds", label = "Instance Sounds" },
        { key = "bags",   label = "Bags" },
        { key = "feast",  label = "Feast" },
        { key = "cc",     label = "Role CC" },
    })
    -- The preview column follows the open sub-tab (UI/PreviewColumn.lua).
    self.textReminderPages = pages

    local leftPad = 14
    local content, yOffset

    -- Size the sub-tab just finished and start the next.
    local function NextPage(key)
        if content then content:SetHeight(math.abs(yOffset) + 20) end
        content = pages[key]
        ns.Rows.currentSection = content.section
        yOffset = -14
    end

    NextPage("class")
    yOffset = ns.Settings.AddRows(TEXT_REMINDERS, "class", content, yOffset)

    NextPage("repair")
    yOffset = ns.Settings.AddRows(TEXT_REMINDERS, "repair", content, yOffset)

    NextPage("sounds")
    yOffset = ns.Settings.AddRows(TEXT_REMINDERS, "sounds", content, yOffset)

    NextPage("bags")
    local consumNote = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    consumNote:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    consumNote:SetWidth(380)
    consumNote:SetJustifyH("LEFT")
    consumNote:SetText("One reminder naming whichever of these you have none of, plus a separate healthstone reminder. Untick a category to stop it being mentioned.")
    consumNote:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])
    yOffset = yOffset - 28

    yOffset = ns.Settings.AddRows(TEXT_REMINDERS, "bags", content, yOffset)

    -- === Feast Announce ===
    NextPage("feast")
    local feastNote = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    feastNote:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    feastNote:SetWidth(380)
    feastNote:SetJustifyH("LEFT")
    feastNote:SetText("Announces in group chat when you or anyone in the party places a feast. Custom message applies to your own feasts; party feasts use the caster's name.")
    feastNote:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])
    -- By its wrapped height: a fixed 28 fitted two lines, and it wraps to three.
    yOffset = yOffset - (math.ceil(feastNote:GetStringHeight() or 28) + 10)

    yOffset = ns.Settings.AddRows(TEXT_REMINDERS, "feastEnable", content, yOffset)

    -- Per-context channel grid (Solo / In Party / In Instance / In Raid)
    local feastChanTitle = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    feastChanTitle:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    feastChanTitle:SetText("Channel")
    feastChanTitle:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])
    yOffset = yOffset - 22

    local feastChanItems = {
        { text = "None",         value = "NONE"          },
        { text = "Party",        value = "PARTY"         },
        { text = "Instance",     value = "INSTANCE_CHAT" },
        { text = "Raid",         value = "RAID"          },
        { text = "Raid Warning", value = "RAID_WARNING"  },
        { text = "Say",          value = "SAY"           },
        { text = "Yell",         value = "YELL"          },
    }

    local colW = 96
    local ddW  = 90
    local contexts = {
        { label = "Solo",        key = "solo",     col = 0 },
        { label = "In Party",    key = "party",    col = 1 },
        { label = "In Instance", key = "instance", col = 2 },
        { label = "In Raid",     key = "raid",     col = 3 },
    }
    self.trFeastChannelDDs = {}
    for _, ctx in ipairs(contexts) do
        local lbl = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        lbl:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad + ctx.col * colW, yOffset)
        lbl:SetText(ctx.label)
        lbl:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])
    end
    yOffset = yOffset - 20
    for _, ctx in ipairs(contexts) do
        local dd = CreateSQDropdown(content, "", ddW, feastChanItems, function(value)
            if type(BH.settings.feastAnnounceChannel) ~= "table" then
                BH.settings.feastAnnounceChannel = CopyTable(BH.defaultSettings.feastAnnounceChannel)
            end
            BH.settings.feastAnnounceChannel[ctx.key] = value
            BH:SaveSettings()
        end)
        local chanDB = BH.settings and type(BH.settings.feastAnnounceChannel) == "table"
            and BH.settings.feastAnnounceChannel
            or BH.defaultSettings.feastAnnounceChannel
        dd:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad + ctx.col * colW, yOffset + 2)
        dd:SetSelectedValue(chanDB[ctx.key] or "NONE")
        self.trFeastChannelDDs[ctx.key] = dd
        ns.Rows.AddTooltip(dd, "Feast channel: " .. ctx.label, "Which chat channel the feast announcement goes to when you are " .. ctx.label:lower() .. ". Set to None to stay silent in that situation.")
    end
    yOffset = yOffset - 30

    local feastTextLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    feastTextLabel:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    feastTextLabel:SetText("Your feast message (leave blank for default):")
    feastTextLabel:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])
    yOffset = yOffset - 20

    local feastTextEdit = CreateSQEditBox(content, 360, 20, { maxLetters = 255 })
    feastTextEdit:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    feastTextEdit:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    feastTextEdit.placeholder = feastTextEdit:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    -- 6 to match the widget's text inset for a box this wide, so the
    -- placeholder sits exactly where the real text will.
    feastTextEdit.placeholder:SetPoint("LEFT", feastTextEdit, "LEFT", 6, 0)
    feastTextEdit.placeholder:SetText("Fresh off the barbie, no crocs were harmed\226\128\166")
    feastTextEdit.placeholder:SetTextColor(0.4, 0.4, 0.4)
    feastTextEdit:SetScript("OnTextChanged", function(self)
        feastTextEdit.placeholder:SetShown(self:GetText() == "")
        BH.settings.feastAnnounceText = self:GetText()
        BH:SaveSettings()
    end)
    feastTextEdit:SetScript("OnShow", function(self)
        feastTextEdit.placeholder:SetShown(self:GetText() == "")
    end)
    self.trFeastAnnounceTextEdit = feastTextEdit
    yOffset = yOffset - 26

    -- Every placeholder the message takes (BH:ExpandPlaceholders), one per
    -- line with what it becomes. Stepped by the block's real height, so it
    -- can never run into the sound row below as the old two lines did.
    local feastTokens = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    feastTokens:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    feastTokens:SetWidth(380)
    feastTokens:SetJustifyH("LEFT")
    feastTokens:SetSpacing(2)
    feastTokens:SetText("|cffffffffPlaceholders you can use:|r\n"
        .. "|cffffffff{name}|r  the name of the character placing the feast\n"
        .. "|cffffffff{feast}|r  the feast's name\n"
        .. "|cffffffff{zone}|r  the dungeon, raid or zone you're in")
    feastTokens:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])
    yOffset = yOffset - (math.ceil(feastTokens:GetStringHeight() or 60) + 12)

    -- Sound alert when another Squizzumables user places a feast
    yOffset = ns.Settings.AddRows(TEXT_REMINDERS, "feastSound", content, yOffset)

    -- === Role CC Alert ===
    NextPage("cc")
    yOffset = ns.Settings.AddRows(TEXT_REMINDERS, "cc", content, yOffset)

    content:SetHeight(math.abs(yOffset) + 20)
    ns.Rows.currentSection = nil
end

function BH:RefreshTextRemindersTab()
    if not self.settings then return end
    -- Every migrated row syncs itself from its own get(); this only has to
    -- cover the two controls the declarative kit has no builder for -- the
    -- announce text box, and the per-context channel grid, which is a keyed
    -- set of dropdowns rather than one row.
    ns.Rows.RefreshAll()

    if self.trFeastAnnounceTextEdit then
        local txt = (self.settings.feastAnnounceText or "")
        self.trFeastAnnounceTextEdit:SetText(txt)
        self.trFeastAnnounceTextEdit.placeholder:SetShown(txt == "")
    end
    if self.trFeastChannelDDs then
        local chanDB = type(self.settings.feastAnnounceChannel) == "table"
            and self.settings.feastAnnounceChannel
            or BH.defaultSettings.feastAnnounceChannel
        for key, dd in pairs(self.trFeastChannelDDs) do
            dd:SetSelectedValue(chanDB[key] or "NONE")
        end
    end
end
