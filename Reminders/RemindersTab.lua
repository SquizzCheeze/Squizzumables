-- Reminders/RemindersTab.lua
-- The Reminders options page: one section per text reminder, built from its
-- BH.REMINDERS entry (AddReminderSection), plus the feast announce and the
-- role CC alert settings.
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

-- Build one reminder's block of options from its BH.REMINDERS entry: section
-- header, enable toggle, any reminder-specific rows, scale, lock, divider.
-- Returns the vertical space used.
--
-- The scale and lock rows grey out when the reminder is disabled -- something
-- the hand-written version had no mechanism for.
function BH:AddReminderSection(content, y, key, skipDivider)
    local def = BH.REMINDERS_BY_KEY[key]
    if not def then return 0 end

    local Rows       = ns.Rows
    local enabledKey = def.enabledKey or (key .. "ReminderEnabled")
    local scaleKey   = key .. "ReminderScale"
    local lockedKey  = key .. "ReminderLocked"
    local frameKey   = key .. "ReminderFrame"
    local updateFn   = "Update" .. BH.ReminderBaseName(key) .. "Reminder"

    local function isOff() return BH.settings and BH.settings[enabledKey] == false end
    local function runUpdate() if BH[updateFn] then BH[updateFn](BH) end end

    local rows = {
        { type = "header", label = def.sectionHeader, tooltip = def.tooltip },
        { type = "check",  label = def.enableLabel,   tooltip = def.tooltip,
          get = function() return BH.settings and BH.settings[enabledKey] ~= false end,
          set = function(v) BH.settings[enabledKey] = v; BH:SaveSettings() end,
          after = runUpdate },
    }

    -- Reminder-specific rows sit between the enable toggle and the scale.
    if def.extraRows then
        for _, extra in ipairs(def.extraRows) do rows[#rows + 1] = extra end
    end

    rows[#rows + 1] = {
        type = "slider", label = def.scaleLabel, width = 300, min = 50, max = 200, step = 5,
        tooltip = "Size of the on-screen reminder, as a percentage.",
        disabled = isOff,
        get = function() return (BH.settings and BH.settings[scaleKey] or 1.0) * 100 end,
        set = function(v, userInput)
            BH.settings[scaleKey] = v / 100
            BH:SaveSettings()
            local f = BH[frameKey]
            if userInput and f then f:SetScale(v / 100) end
        end,
    }
    rows[#rows + 1] = {
        type = "check", label = def.lockLabel,
        tooltip = "Stops the reminder being dragged. Use Preview on the Settings tab to reposition it.",
        disabled = isOff,
        get = function() return BH.settings and BH.settings[lockedKey] or false end,
        set = function(v)
            BH.settings[lockedKey] = v
            BH:SaveSettings()
            local f = BH[frameKey]
            if f then f:SetMovable(not v); f:EnableMouse(not v) end
        end,
    }
    -- The section that ends a group omits its trailing divider, because the
    -- next block (Instance Sounds, Feast Announce) opens with its own.
    if not skipDivider then
        rows[#rows + 1] = { type = "divider" }
    end

    return Rows.AddAll(content, y, rows)
end

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

    local content = pages.class
    ns.Rows.currentSection = content.section

    local yOffset = -14
    local leftPad = 14

    -- The one Class Reminder (2.0, user request 2026-10-16): Beacon, Earth
    -- Shield, Symbiotic and No Pet each belong to one class, so they share one
    -- frame -- one position, scale and lock -- and each keeps its own on/off.
    -- No Pet's settings came over from Class Buffs. The lock also writes the
    -- four old <key>ReminderLocked, which the reminders' own code still reads.
    yOffset = yOffset - ns.Rows.AddAll(content, yOffset, {
        { type = "header", label = "CLASS REMINDER" },
        { type = "text",
          label = "Beacon, Earth Shield, Symbiotic Relationship and No Pet each belong to one class, so "
              .. "they share one frame: one place on screen, one size and one lock. Turn each on or off "
              .. "below." },
        { type = "slider", label = "Class Reminder Scale", width = 300, min = 50, max = 300, step = 5,
          tooltip = "Size of the class reminder, as a percentage.",
          get = function() return (BH.settings.classReminderScale or 1.0) * 100 end,
          set = function(v, userInput)
              BH.settings.classReminderScale = v / 100
              BH:SaveSettings()
              if userInput and BH.classReminderFrame then BH.classReminderFrame:SetScale(v / 100) end
          end },
        { type = "check", label = "Lock Class Reminder",
          tooltip = "Stops the class reminder being dragged. Unlock Frames overrides this while you are "
                 .. "positioning things.",
          get = function() return BH.settings.classReminderLocked and true or false end,
          set = function(v)
              BH.settings.classReminderLocked = v
              for _, key in ipairs(BH.CLASS_REMINDER_KEYS) do
                  BH.settings[key .. "ReminderLocked"] = v
                  local f = BH[key .. "ReminderFrame"]
                  if f then f:EnableMouse(BH:ReminderMouseEnabled(v)) end
              end
              BH:SaveSettings()
          end },
        { type = "divider" },
    })

    -- Each class's own on/off (and any rows of its own, between).
    for _, key in ipairs(BH.CLASS_REMINDER_KEYS) do
        local def = BH.REMINDERS_BY_KEY[key]
        local enabledKey = def.enabledKey or (key .. "ReminderEnabled")
        local updateFn = "Update" .. BH.ReminderBaseName(key) .. "Reminder"
        local rows = {
            { type = "check", label = def.enableLabel, tooltip = def.tooltip,
              get = function() return BH.settings and BH.settings[enabledKey] ~= false end,
              set = function(v) BH.settings[enabledKey] = v; BH:SaveSettings() end,
              after = function() if BH[updateFn] then BH[updateFn](BH) end end },
        }
        for _, extra in ipairs(def.extraRows or {}) do rows[#rows + 1] = extra end
        yOffset = yOffset - ns.Rows.AddAll(content, yOffset, rows)
    end

    -- Sub-tab boundary.
    content:SetHeight(math.abs(yOffset) + 20)
    content = pages.repair
    ns.Rows.currentSection = content.section
    yOffset = -14

    -- Not a class reminder: anyone's gear wears out. Its own sub-tab, frame,
    -- position, scale and lock.
    yOffset = yOffset - self:AddReminderSection(content, yOffset, "repair", true)

    -- Sub-tab boundary.
    content:SetHeight(math.abs(yOffset) + 20)
    content = pages.sounds
    ns.Rows.currentSection = content.section
    yOffset = -14

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "check",
        label = "Play Sound on Skyreach (Mythic)",
        tooltip = "Plays a sound when you enter The Everbloom on Mythic difficulty, as a reminder about the Skyreach affix pull.",
        get = function() return BH.settings.skyreachSoundEnabled and true or false end,
        set = function(v)
            BH.settings.skyreachSoundEnabled = v
            BH:SaveSettings()
        end,
    })

    -- Sub-tab boundary.
    content:SetHeight(math.abs(yOffset) + 20)
    content = pages.bags
    ns.Rows.currentSection = content.section
    yOffset = -14

    local consumNote = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    consumNote:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    consumNote:SetWidth(380)
    consumNote:SetJustifyH("LEFT")
    consumNote:SetText("One reminder naming whichever of these you have none of, plus a separate healthstone reminder. Untick a category to stop it being mentioned.")
    consumNote:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])
    yOffset = yOffset - 28

    -- One section for the combined frame (enable / scale / lock / position),
    -- then the per-category watch toggles that decide what it can mention.
    yOffset = yOffset - self:AddReminderSection(content, yOffset, "bags", true)

    for _, cat in ipairs({
        { key = "food",        label = "Watch food" },
        { key = "flask",       label = "Watch flasks" },
        { key = "oil",         label = "Watch weapon oils" },
        { key = "augmentRune", label = "Watch augment runes" },
    }) do
        yOffset = yOffset - ns.Rows.Add(content, yOffset, {
            type = "check",
            indent = 28,
            label = cat.label,
            tooltip = "Include this in the bag reminder when you have none of it.",
            get = function() return BH.settings[cat.key .. "ReminderEnabled"] ~= false end,
            set = function(v)
                BH.settings[cat.key .. "ReminderEnabled"] = v
                BH:SaveSettings()
                BH:UpdateBagReminder()
            end,
            disabled = function() return BH.settings.bagsReminderEnabled == false end,
        })
    end

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "slider",
        indent = 28,
        label = "Warn when running low (0 = off)",
        width = 300, min = 0, max = 10, step = 1,
        tooltip = "Also show the bag reminder when you have this many or fewer of a watched consumable left, "
            .. "e.g. \"LOW ON FLASK (1 LEFT)\". Having none is still shown first.",
        get = function() return BH.settings.bagsLowThreshold or 1 end,
        set = function(v)
            BH.settings.bagsLowThreshold = v
            BH:SaveSettings()
            BH:UpdateBagReminder()
        end,
        disabled = function() return BH.settings.bagsReminderEnabled == false end,
    })

    yOffset = yOffset - self:AddReminderSection(content, yOffset, "healthstone", true)

    -- === Feast Announce ===
    -- Sub-tab boundary.
    content:SetHeight(math.abs(yOffset) + 20)
    content = pages.feast
    ns.Rows.currentSection = content.section
    yOffset = -14

    local feastNote = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    feastNote:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    feastNote:SetWidth(380)
    feastNote:SetJustifyH("LEFT")
    feastNote:SetText("Announces in group chat when you or anyone in the party places a feast. Custom message applies to your own feasts; party feasts use the caster's name.")
    feastNote:SetTextColor(SQ_COLORS.textDim[1], SQ_COLORS.textDim[2], SQ_COLORS.textDim[3])
    -- By its wrapped height: a fixed 28 fitted two lines, and it wraps to three.
    yOffset = yOffset - (math.ceil(feastNote:GetStringHeight() or 28) + 10)

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "check",
        label = "Enable Feast Announce",
        tooltip = "Announces to chat when you drop a feast, and alerts other Squizzumables users in your group with a sound.",
        get = function() return BH.settings.feastAnnounceEnabled ~= false end,
        set = function(v)
            BH.settings.feastAnnounceEnabled = v
            BH:SaveSettings()
        end,
    })

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
    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "sound",
        label = "Alert sound (plays when a feast is placed)",
        tooltip = "Sound played to you and to other Squizzumables users in the group when a feast is dropped.",
        get = function() return BH.settings.feastAlertSound or "None" end,
        set = function(value)
            BH.settings.feastAlertSound = value
            BH:SaveSettings()
        end,
        disabled = function() return BH.settings.feastAnnounceEnabled == false end,
    })

    -- === Healer CC Alert ===
    -- Sub-tab boundary.
    content:SetHeight(math.abs(yOffset) + 20)
    content = pages.cc
    ns.Rows.currentSection = content.section
    yOffset = -14
    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "text",
        label = "Plays a sound and shows an alert when a watched party or raid member is crowd controlled. Pick which roles to watch.",
    })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "check",
        label = "Alert when healer is CC'd",
        tooltip = "Watch group healers and raise the alert when one is crowd controlled.",
        get = function() return BH.settings.healerCCAlertEnabled == true end,
        set = function(v)
            BH.settings.healerCCAlertEnabled = v
            BH:SaveSettings()
            BH:RefreshRoleCCWatchList()
            BH:UpdateRoleCCFrame()
        end,
    })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "check",
        label = "Alert when tank is CC'd",
        tooltip = "Watch group tanks and raise the alert when one is crowd controlled. Shares the frame and sound with the healer alert; the label names whichever role is affected.",
        get = function() return BH.settings.roleCCAlertTank == true end,
        set = function(v)
            BH.settings.roleCCAlertTank = v
            BH:SaveSettings()
            BH:RefreshRoleCCWatchList()
            BH:UpdateRoleCCFrame()
        end,
    })

    -- Everything below only matters once at least one role is being watched.
    local function noRoleWatched()
        return not (BH.settings.healerCCAlertEnabled or BH.settings.roleCCAlertTank)
    end

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "check",
        label = "Lock Position",
        tooltip = "Stops the role CC alert being dragged.",
        get = function() return BH.settings.healerCCReminderLocked == true end,
        set = function(v)
            BH.settings.healerCCReminderLocked = v
            BH:SaveSettings()
            if BH.healerCCReminderFrame then
                BH.healerCCReminderFrame:SetMovable(not v)
                BH.healerCCReminderFrame:EnableMouse(BH:ReminderMouseEnabled(v))
            end
        end,
        disabled = noRoleWatched,
    })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "slider",
        label = "Scale",
        width = 200, min = 50, max = 200, step = 5,
        tooltip = "Size of the role CC alert, as a percentage.",
        get = function() return (BH.settings.healerCCReminderScale or 1.0) * 100 end,
        set = function(val)
            BH.settings.healerCCReminderScale = val / 100
            BH:SaveSettings()
            if BH.healerCCReminderFrame then BH.healerCCReminderFrame:SetScale(val / 100) end
        end,
        disabled = noRoleWatched,
    })

    yOffset = yOffset - ns.Rows.Add(content, yOffset, {
        type = "sound",
        label = "Alert sound",
        tooltip = "Sound played when a watched healer or tank is crowd controlled.",
        get = function() return BH.settings.healerCCAlertSound or "None" end,
        set = function(value)
            BH.settings.healerCCAlertSound = value
            BH:SaveSettings()
        end,
        disabled = noRoleWatched,
    })

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
