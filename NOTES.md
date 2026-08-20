# Squizzumables — findings and open threads

What is left of the v1.60 modernization roadmap after the work landed.

The roadmap proper — the bug list, the refactor plan, the settings-UI redesign and the release
checklists — is gone, because it now describes code that exists. What that work *did* is in
`changelog.txt`; how the result is put together, and the constraints it has to respect, is in
`CLAUDE.md`.

What is kept here is the part that is not derivable from the code: things that were investigated
and found to be impossible, things that were built and reverted, and things still on the table.
The point of the file is that nobody spends another day rediscovering any of it.

The two reference addons cited throughout ship in this same AddOns folder:

- **ClickableRaidBuffs** (`../ClickableRaidBuffs`) — Funki, v7.8.14. ~15k lines across 90 files.
  Same core job as us: missing raid buffs, consumables, temporary enchants, clickable.
- **EllesmereUI** (`../EllesmereUI*`) — Ellesmere, v8.9.4. A 22-addon UI suite; relevant here for
  its options framework, profile system and settings UX.

---

## Contents

1. [Do not re-attempt](#do-not-re-attempt)
2. [Built and reverted](#built-and-reverted)
3. [Candidates not built](#candidates-not-built)
4. [Open questions / judgment calls](#open-questions--judgment-calls)
5. [Still open for a later version](#still-open-for-a-later-version)
6. [Appendix — Reference addon file map](#appendix--reference-addon-file-map)

---

## Do not re-attempt

Two other dead ends are documented in `CLAUDE.md` rather than here, because they constrain how
new code must be written and so belong where they will be read first: **secret aura values**
(12.1.0+ — comparing or doing arithmetic on an aura field throws, so everything goes through
`BH.Secrets`) and **death/combat-log detection** (`COMBAT_LOG_EVENT_UNFILTERED` is gone and
`UNIT_DIED` is unreliable off-screen, so the M+ Death Tally polls instead).

The third is below, and is the longest because it was the closest to being worth doing.

### Encounter timeline: per-ability boss alerts (researched and built 2026-08-20, v1.60)

Shipped: `Core/EncounterTimeline.lua`, the pull timer mirror, `/sq timeline`.

#### Why the combat log is not an option

`COMBAT_LOG_EVENT` and `COMBAT_LOG_EVENT_UNFILTERED` **error when an addon registers them** on
12.0+, and `CombatLogGetCurrentEventInfo()` returns secret values. The replacement,
`COMBAT_LOG_MESSAGE`, delivers a preformatted string in a `|K` protection wrapper plus colours —
for rendering a combat log, not for logic. No spell ID. Detecting a boss cast from the combat log
is not merely expensive now, it is impossible.

That left `C_EncounterTimeline`, which is what BigWigs' Midnight modules use and which the user
confirmed runs for dungeon bosses as well as raid.

#### The read side does not support per-ability alerts — corrected finding

An earlier draft of this section said to key alerts off `spellID` because it is locale-proof.
**That was wrong**, and it was written from the API annotations alone without checking a live
consumer. Reading BigWigs' actual code settled it:

```lua
-- BigWigs_Plugins/Timeline.lua
function plugin:ENCOUNTER_TIMELINE_EVENT_ADDED(_, eventInfo)
    -- Not Secret
    local source = eventInfo.source
    local eventId = eventInfo.id
    local duration = eventInfo.duration
    local maxQueueDuration = eventInfo.maxQueueDuration

    -- Secret
    --local spellId = eventInfo.spellID
    local spellName = eventInfo.spellName
    local icon = eventInfo.iconFileID
    -- local severity = eventInfo.severity
```

Only `id`, `source`, `duration` and `maxQueueDuration` are readable. `spellID`, `spellName`,
`iconFileID`, `icons`, `severity` and `isApproximate` are secret: they can be handed straight to a
display function — BigWigs passes `spellName` and `icon` into its bar — but comparing one throws.

So an addon can draw a bar for an incoming ability and cannot find out which ability it is. This
is consistent with the stated intent behind removing CLEU: stop addons making decisions off
combat information.

How BigWigs works around it, in `BigWigs_MidnightLairs/Nymrissa.lua`:

```lua
local durationRounded = self:RoundNumber(duration, 0)
if durationRounded == 3 then ...
elseif durationRounded == 27 then barInfo = self:AlluringBubble()
elseif durationRounded == 33 or durationRounded == 20 or durationRounded == 51 ... then
```

They identify the ability by rounding its duration to the nearest second and looking it up in a
hand-built table, per boss, per difficulty, with a fallback "[B]" backup bar for every duration
they have not catalogued yet. That is the only method available.

**Conclusion: "attach my sound to boss ability X" is not implementable** without taking on that
same per-boss, per-difficulty, per-patch duration table for every dungeon and raid in the game.
That is a boss-mod's whole job, and it is not a fight worth picking here — BigWigs already does
it, and does it well. Do not revisit this unless Blizzard un-secrets `spellID`.

#### The write side works, and is what shipped

`AddScriptEvent(request)` puts our own event on the timeline, with `Cancel`, `Pause`, `Resume`,
`Finish` alongside it. Nothing about it is secret, because every field is ours:

| Field | |
|---|---|
| `spellID` | `0` when the timer is not really a spell |
| `iconFileID` | numeric file ID, **not** a path — derive with `C_Spell.GetSpellTexture(id)` |
| `duration` | seconds |
| `maxQueueDuration?` | default 0 |
| `overrideName?` | display name, which is how a `spellID` of 0 still reads sensibly |
| `severity?` | `Enum.EncounterEventSeverity`, default Medium |
| `paused?` | default false |

Good-neighbour note: our events report as `Enum.EncounterTimelineEventSource.Script` (`1`), and
BigWigs' Timeline plugin explicitly skips that source, so they do not double up as BigWigs bars.

Enum values confirmed from BigWigs' inline comments:
`EncounterTimelineEventState` Active=0, Paused=1, Finished=2, Canceled=3;
`EncounterTimelineEventSource` Encounter=0, Script=1, EditMode=2.

`AddEditModeEvents()` generates fake events, so the read side is testable solo if it is ever
needed.

#### What was built

`Core/EncounterTimeline.lua` — `BH.Timeline`:

- `IsAvailable()` / `IsUsable()` — gate on `IsFeatureAvailable()` and `IsFeatureEnabled()` rather
  than assuming coverage.
- `Add(key, spec)` / `Cancel` / `Finish` / `Pause` / `Resume` / `CancelAll` / `IsActive` /
  `TimeRemaining` — keyed by string, so starting the same timer twice replaces it. Every API call
  is wrapped, because `Add` runs from click handlers where a throw would take the button with it.
  `CancelAll` iterates our own keys rather than calling `CancelAllScriptEvents`, which would also
  kill other addons' events.
- `TIMERS` table + `Start(name, duration)` — icon and naming decisions in one place.
- Cancels everything on `PLAYER_LEAVING_WORLD` so timers do not strand across a zone change.

Pull timer mirror: driven by `START_PLAYER_COUNTDOWN` and `CANCEL_PLAYER_COUNTDOWN`, **not** by hooking our own Raid Tools button — the event fires for a pull
started by anyone in the group, which is the common case. Payload args (`initiatedBy`,
`timeRemaining`, `totalTime`) go through `BH.Secrets.SafeNumber` before being compared.

#### Answered: script events do show outside an encounter

This was left open, then settled by reading Blizzard's own source (shipped with the
`ketho.wow-api` VS Code extension under
`Annotations/FrameXML/Annotations/AddOns/Blizzard_EncounterTimeline/`, which is worth remembering
as a local copy of the real client Lua):

```lua
function EncounterTimelineMixin:EvaluateVisibility()
    ...
    elseif visibility == Enum.EncounterEventsVisibility.InEncounter then
        if C_InstanceEncounter.IsEncounterInProgress() and ... then
            return true;
        elseif C_EncounterTimeline.HasVisibleEvents() or self:HasEventFrames() then
            -- Accommodating respawn timers and the like without having to fake the
            -- in-encounter state. Also works for custom events.
            return true;
```

Under the default `InEncounter` visibility the timeline still shows itself when there are visible
events, and the comment names custom events explicitly. A script event therefore pulls the
timeline into view on its own, so the pull timer stays on by default.

#### What gates IsFeatureEnabled

`IsFeatureAvailable` can be true while `IsFeatureEnabled` is false, which is a dead end from the
API alone — it reports a flat boolean with no reason. The gate is two CVars, from Blizzard's
`EncounterTimelineVisibilityCVars`:

| CVar | Options checkbox |
|---|---|
| `combatWarningsEnabled` | Enable Boss Warnings (master) |
| `encounterTimelineEnabled` | Boss Ability Timeline |

Both live in Options > Gameplay > Combat, under Combat Warnings, and the timeline one is greyed
out while the master is off (`CanEnableBossWarningFeatures` requires both). `BH.Timeline`
therefore has `WhyUnusable()`, which reads the CVars and returns a sentence naming the checkbox to
turn on; `Add()` returns it as its error and `/sq timeline` prints it.

#### Event registration gotcha

There is no `STOP_PLAYER_COUNTDOWN` on retail. It appears in EXBoss, whose registration wrapper
swallows unknown events; a direct `frame:RegisterEvent` throws "Attempt to register unknown event"
at login. Only `START_PLAYER_COUNTDOWN` and `CANCEL_PLAYER_COUNTDOWN` exist here, which is the
pair BigWigs registers.

---

## Built and reverted

**Masque skinning** (`../ClickableRaidBuffs/UI/Masque.lua`, 95 lines). Attempted and backed out.
Our buttons are icon + label + header in one frame, so Masque skins the whole thing: the border
wraps the label area with the icon stranded in a corner, under every skin. Making it work needs
the icon moved into its own child frame and that child handed to Masque instead — a restructure
of a button layout that currently works, for a purely cosmetic gain. Deferred deliberately.

Our own `UI/Glow.lua` has the same shape of problem and solved it, because we own the texture:
passing `anchorTo` glows one child region instead of the whole frame. If Masque is ever revisited,
that is the precedent to follow.

---

## Candidates not built

From ClickableRaidBuffs' module list, still in our problem domain and still unaddressed:

| Feature | Reference | Notes |
|---|---|---|
| **Trinket equipped check** | `Modules/Trinkets.lua` (712) | Commented out in their own `.toc`, but the idea — empty trinket slot warning — is sound. |
| **Ignore / exclusion list** | `Modules/Exclusions.lua` (186) + `Options/Tabs/Ignore_Tab.lua` (1,670) | We have per-item enable but no global "never remind me about X". |

Loose ends from the API sweep that were never closed:

| Item | Current | Should be |
|---|---|---|
| `.toc` interface versions | one, `120100` | CRB lists four, Ellesmere five. Matters the moment a PTR build bumps the number. |
| `.toc` category | absent | `## Category` |
| Spec API | mixed: `GetSpecialization()` 4× in `Squizzumables.lua` and 2× in `Squizzumables_CDM.lua`, `PlayerUtil.GetCurrentSpecID()` 7× | pick one |
| Localization | none | AceLocale or Ellesmere's `EllesmereUI_Locale.lua`. Even English-only `L["..."]` wrapping makes translation a later drop-in. |
| Pre-12.1 client failsafe | none | Ellesmere's `EUI_CLIENT_BLOCKED` guard as line 1 of every file (`../EllesmereUI/EllesmereUI_ClientGate.lua`) — relevant given the PTR/retail junction |

---

## Open questions / judgment calls

**Ace3.** CRB embeds ~40 Ace3 files. AceDB-3.0 would have solved the defaults/profiles/migration
problem outright and AceConfig much of the settings UI. Against: it is a large dependency, our
profile system already works including the per-spec override AceDB does *not* provide out of the
box, and Ellesmere deliberately went the other way — their `EllesmereUI_Lite.lua` is a 543-line
"lightweight addon framework (replaces Ace3)". Settled for now as: no Ace3, but AceDB's
recursive-defaults idea was taken (`ApplyDefaults` + the numbered `MIGRATIONS` list). Revisit only
if the hand-rolled options panel becomes the bottleneck again.

**Media size.** `Media/` is 2.7 MB, almost all of it the 15 `duckrun_*.png` frames. Fine for a
personal addon; if this ever goes on CurseForge, converting to BLP would cut the download
substantially. Now that Kelerts lets players add their own alerts, a second frame set would double
this — worth doing before that happens rather than after.

---

## Still open for a later version


- More timers on the timeline once the above is answered: flask/food expiry, Coach's Whistle
  window, Earth Shield and Beacon durations. The appeal is that these land where the player is
  already looking, styled and positioned by Blizzard, with no frame of ours to draw, position,
  scale, lock or save.
- `C_CombatAudioAlert.SpeakText(text, category, allowOverlap)` makes the client speak, and
  `IsEnabled()` reports whether the system is on. An alternative to sound files anywhere in the
  addon, not just here, and it inherits the player's accessibility settings.
---

## Appendix — Reference addon file map

Files worth reading directly, with what to take from each.

### ClickableRaidBuffs (`../ClickableRaidBuffs`)

| File | Lines | Take |
|---|---|---|
| `Core/Compat.lua` | 130 | `IsSecret`, `HasAnySecret`, `SafeNumber`, `ReadSpellCooldown` |
| `Core/SecretsHelper.lua` | 92 | `SafeAuraSpellID` / `Name` / `Expiration` / `SourceUnit` |
| `Core/GateCheck.lua` + `Gates/*` | ~400 | composable visibility predicates |
| `Core/UpdateBus.lua` | ~560 | dirty flags, coalescing, per-source rate limits |
| `Core/BagScan.lua` | — | cached bag snapshot |
| `Core/RaidBuffsScan.lua:37` | — | `PlayerKnowsSpell` fallback chain |
| `Core/ProfileIO.lua`, `Core/CustomSpellIO.lua` | — | import/export strings |
| `Options/OptionElements.lua:346` | 1,029 | `beginFlow` / `beginGrid` / `beginTriple` layout contexts |
| `Options/Panel.lua` | 718 | resizable panel, `RegisterSection`, saved window state |
| `Options/ToggleSwitch.lua`, `NumberSelect.lua`, `ScrollBar.lua` | 725 | widget kit |
| `Modules/Healthstone.lua`, `AugmentRune.lua`, `DKWeaponEnchantCheck.lua` | 971 | feature gaps |
| `Modules/ContentTypes.lua` | 394 | per-difficulty gating |
| `Modules/CustomSpells.lua` | 814 | user-defined reminders |
| `UI/Masque.lua` | 95 | Masque integration |
| `Data/*_Table.lua` | 15 files | data fully separated from logic |

### EllesmereUI (`../EllesmereUI`, `../EllesmereUIOptions`)

| File | Lines | Take |
|---|---|---|
| `EllesmereUI_GlobalSearch.lua` | 922 | fuzzy settings search + deep-link jump |
| `EUI_UnlockMode.lua` | 12,870 | global unlock mode (concept; do not copy wholesale) |
| `EllesmereUI_Migration.lua` | — | versioned one-time DB migrations |
| `EllesmereUI_Lite.lua` | 543 | lightweight framework instead of Ace3 |
| `EllesmereUI_ClientGate.lua` | 83 | per-file pre-12.1 failsafe |
| `EllesmereUI_Profiles.lua` | 5,328 | profiles + LibDeflate import/export |
| `EllesmereUI_PatchNotesPopup.lua` | — | in-game changelog |
| `EllesmereUI_FirstInstall.lua` | — | first-run wizard |
| `EllesmereUI_Visibility.lua` | 624 | centralised visibility conditions |
| `EllesmereUIOptions/EllesmereUI_Widgets.lua:357` | 8,724 | `TagOptionRow`, search registration |
| `EllesmereUIOptions/EUI_QoL_BattleRes_Options.lua` | ~250 | **the clearest example of the declarative row style** |
