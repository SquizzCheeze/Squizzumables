# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Squizzumables is a World of Warcraft retail addon (Lua 5.1, WoW API). It reminds players to apply
food/flask/oil consumables and class buffs, provides raid tools (pull timer, markers), a Blizzard
Cooldown Manager (CDM) proxy, a custom spell-alert ("Just For Kel") system, and misc QoL reminders
(repair, battle res counter, pet reminders, etc). Targets WoW Midnight (12.0+).

There is no build system, package manager, or automated test suite — this is a plain addon
directory loaded directly by the WoW client from `Interface/AddOns/Squizzumables`.

This folder is dual-homed: it's junctioned into both the `_retail_` and `_ptr_` client
`Interface/AddOns` trees (one real directory, two reparse-point links), so PTR and retail always
run the exact same code — there is no separate "PTR branch" to keep in sync.

A party interrupt tracker module (`Squizzumables_InterruptTracker.lua`) existed through v1.53 but
was deleted in v1.54 — kick/interrupt detection is no longer reliably implementable given
Blizzard's API changes (tainted/secret cast and aura data in exactly the combat/M+ situations the
tracker needed to read). It's gone from disk and from `Squizzumables.toc`; don't reintroduce it
without a fundamentally different detection approach that doesn't depend on reading secret values.

## Development workflow

- There is no compile/build step. Edit the `.lua` files directly; changes take effect after
  `/reload` (or a relog) in-game.
- No test framework exists. Verification is manual, in-game, via slash commands (see below) and
  observing behavior in a dungeon/raid/party context.
- Linting is done via the Lua Language Server (see `.luarc.json` and `.vscode/settings.json`),
  which declares the Lua 5.1 runtime and the WoW API globals used across the addon (plus the
  `ketho.wow-api` annotations extension for full API types). There is no CLI lint command — this
  is editor-time diagnostics only.
- There is no Lua interpreter here, so four standalone checks in `.claude/` stand in for the
  parse the editor cannot run headlessly. Run all four after any bulk edit:

      perl .claude/check-backslashes.pl <files>   # lone backslashes: "Fonts\FRIZQT__.TTF"
      perl .claude/check-strings.pl     <files>   # unterminated strings / mangled escapes
      awk  -f .claude/check-balance.awk <files>   # per-function block balance
      perl .claude/check-toc.pl                   # every .toc entry exists on disk

  Each exists because a real bug got through the others. Structural checks pass happily on a
  broken string literal, and the backslash check passes happily on an escape that has been
  collapsed into a raw byte, which is how `"\226\128\148"` became one 0x96 and truncated a line.

  **In both `check-strings.pl` and `check-balance.awk`, strings are stripped BEFORE comments.**
  Reversing that makes any `" -- "` inside a string read as a comment marker and truncate the
  line; this codebase's diagnostics are full of them. That exact bug has been written twice.

  Validate a new check against a known-bad file *and* a known-good one. Note that the corruption
  can hit the test as easily as the code: bash `printf` and Perl both read `\226` as octal, so a
  control file has to be written with explicit `chr(92)` to contain a real backslash.

  **Do not trust `mcp__ide__getDiagnostics` after editing files from the shell.** The Lua Language
  Server serves a cached result and does not rescan on an external write, so it reports the
  previous version of the file — including a clean bill of health for code that no longer exists.
  `touch` does not invalidate it and neither does re-querying a single URI. The tell is that the
  reported line numbers no longer land on the constructs named in the message; check one before
  believing any of it. It is only trustworthy for files edited through the editor itself, so the
  four checks above are the real gate.

- `changelog.txt` is maintained by hand; check it for recent behavioral history/root-cause notes
  before assuming something is a fresh bug — many past fixes have detailed root-cause writeups
  there worth reading first.
- Useful in-game slash commands while developing: `/sq config` (options panel), `/sq reset` (reset
  main frame position), `/sq reload` (recompute buttons), `/sq unlock` (toggle unlock mode),
  `/sq raidtools`, `/sq notes` (reopen the release notes), and the diagnostic dumps `/sq feast`,
  `/sq debug`, `/sq dk`, `/sq timeline`, `/sq auras` (aura secrecy state) and `/sq cdm` (CDM
  sound wiring). `/squizz` opens config directly and `/squizz <TabID>` jumps to a named page.
  `/ginvite <name>` is the guild invite helper.

### Researching the WoW API

**Use the generated annotations as the source of truth, not the community wiki.**

    https://github.com/Ketho/vscode-wow-api
    Annotations/Core/Blizzard_APIDocumentationGenerated/<Namespace>Documentation.lua

Those files are produced from the client's own `Blizzard_APIDocumentation`, so they match what
the game actually exposes. Raw fetch, for example:

    https://raw.githubusercontent.com/Ketho/vscode-wow-api/master/Annotations/Core/
      Blizzard_APIDocumentationGenerated/EncounterTimelineDocumentation.lua

warcraft.wiki.gg is community-written and has been wrong here in ways that changed conclusions:
for `C_EncounterTimeline` it listed 7 functions where the real API has 33, omitted the entire
write side of the namespace, and claimed a structure field had been removed that still exists.
Use it for prose explanation if helpful, never as the basis for a decision.

Better still, when the question is about *behaviour* rather than a signature: the `ketho.wow-api`
VS Code extension ships Blizzard's actual FrameXML Lua, installed locally at

    C:\Users\<you>\.vscode\extensions\ketho.wow-api-<version>\Annotations\FrameXML\
      Annotations\AddOns\<Blizzard_AddonName>\

That is the real client code, so it answers questions the annotations cannot -- which CVar gates a
feature, when a frame decides to show itself, what a flat `false` return actually means. It
settled two encounter-timeline questions in one read (`Blizzard_EncounterTimeline/`,
`Blizzard_SettingsDefinitions_Frame/AdvancedOptions.lua`). Grep it before guessing or asking the
user to test something in-game.

Second-best evidence is a *currently maintained* addon running on *current* content. Be careful
which: an addon folder for a previous expansion is not evidence about this one. Reading
`LittleWigs_TheWarWithin` (11.x modules, 11.x content) once led to the wrong conclusion that
`COMBAT_LOG_EVENT_UNFILTERED` still worked, when the giveaway was that no Midnight pack existed
at all. Check the `.toc` interface version before treating an addon as current.


## Releasing

Published to CurseForge (project `1483099`) and GitHub Releases by
`BigWigsMods/packager`, driven from `.github/workflows/release.yml` and configured by
`.pkgmeta`. Ordinary commits publish nothing; a tag publishes.

    # bump ## Version in the .toc, add a changelog.txt section, commit
    git tag -a v1.61 -m "Squizzumables 1.61"
    git push --tags

**The tag must be annotated (`-a`).** `git describe` ignores lightweight tags, so the packager
falls back to the commit hash and ships an "alpha" build named after it instead of a version.

**Dry-run first via `workflow_dispatch`** (Actions -> Package and release -> Run workflow). It
passes `-d`, so nothing can reach CurseForge, and it attaches the built zip as an artifact for
inspection. Worth doing whenever `.pkgmeta` changes, because the ignore list is the easy thing to
get wrong and a bad upload cannot be taken back -- a CurseForge file is live to players the moment
it lands, and the version number is spent whether or not it was right.

Three things cost a night each and are not discoverable from a green checkmark:

- **`release.sh` skips a missing token silently and still exits 0.** The tell is the credential
  summary it prints around line 35: `CurseForge ID: 1483099 [token set]`. That suffix comes from
  `${cf_token:+ [token set]}`, so **no suffix means the token is empty** -- not that the line is
  merely terse. A green run with a GitHub release and nothing on CurseForge is this.

  **But confirm on the author dashboard before concluding it.** CurseForge's public file API
  (`https://www.curseforge.com/api/v1/mods/<id>/files`, and cfwidget) only lists files that have
  passed **approval** -- a freshly uploaded file sits in *pending* and is invisible there for a
  while. So "green run, GitHub release, nothing on the public API" is equally consistent with a
  perfectly successful upload. Found on SquizzFrames' first automated release (2026-08-21), where
  that reading produced a wrong "the token never arrived" call and a needless plan to delete the
  tag and re-release. The upload had worked.
- **`actions/upload-artifact` skips hidden paths by default**, and the packager builds into
  `.release/`. Without `include-hidden-files: true` the artifact comes back empty while the
  packager step stays green, which reads exactly like a build failure and is not one.
- **The secret is `CF_API_TOKEN`** (`CF_API_KEY` also works -- `release.sh` tries KEY first, then
  TOKEN, first non-empty wins). A misnamed secret is not an error in GitHub Actions; it silently
  interpolates to an empty string. `.github/workflows/release.yml` has a dry-run-only step that
  prints the *length* of both, which is how to tell "not reaching the job" from "reaching it and
  being rejected".

## File layout and load order

Load order is defined in `Squizzumables.toc` and matters — later files assume earlier ones already
initialized `BH`. `perl .claude/check-toc.pl` verifies every listed path exists on disk.

1. `Libs/LibStub/LibStub.lua`, `Libs/LibSharedMedia-3.0/LibSharedMedia-3.0.lua` — third-party libs, don't edit.
2. `Squizzumables_Config.lua` — static data only: consumable item IDs (food/flask/oil/augment rune)
   and per-class buff definitions (`BH.defaults`). Update this file each expansion/season when
   consumable item IDs rotate.
3. `Squizzumables_Secrets.lua` — `BH.Secrets`, the only sanctioned way to read an aura or any other
   possibly-secret value. See "Secret aura values" below; nothing should read those fields directly.
4. `UI/Widgets.lua` — the hand-rolled widget kit (`CreateSQButton`, `CreateSQCheckbox`,
   `CreateSQSlider`, `CreateSQDropdown`, `CreateSQColorPicker`, `CreateSQDivider`) plus
   `SQ_COLORS` and the accent-colour helpers. Everything here is exported on `ns`, and each
   consuming file pulls what it needs into file-locals at the top — follow that, do not add
   globals.
5. `UI/Rows.lua` — the declarative settings-row kit (`get`/`set`/`disabled`/`tooltip`,
   self-registering refresh) and `ns.Rows.AddTooltip`. Prefer this over hand-built rows.
6. `UI/Glow.lua` — `ns.Glow`, the three-tier button glow. Pass `anchorTo` to glow one child
   region rather than the whole button frame.
7. `Squizzumables.lua` — the core: default settings (`BH.defaultSettings`), the migration list,
   the profile system, the main consumable/buff reminder frame, the entire options/settings UI
   (all tabs), the text-reminder registry (`BH.REMINDERS`) and its gates, raid tools (pull
   timer/markers), dungeon callouts, feast announce, and the event dispatcher + slash commands at
   the bottom.
8. `Core/ProfileIO.lua` — profile import/export strings.
9. `Core/EncounterTimeline.lua` — `BH.Timeline`, the write side of `C_EncounterTimeline`.
10. `Core/Minimap.lua` — minimap button and addon compartment entry.
11. `Core/Welcome.lua` — first-run welcome and the per-version release notes popup. `RELEASE_NOTES`
    there is hand-maintained and keyed by the `.toc` Version string; update it alongside
    `changelog.txt`.
12. `Squizzumables_CDM.lua` — Cooldown Manager proxy module (`BH.cdm`).
13. `Squizzumables_SpellAlerts.lua` — "Kelerts", the user-defined spell alerts (full-screen image
    + sound on an aura), and the M+ Death Tally.

All modules share a single global table `BH` (each file does `local BH = BH` or
`if not BH then BH = {} end`) — this is the addon's namespace; there is no `require`/module
system. Feature-specific submodules attach themselves as `BH.cdm`, etc. The per-addon private
table is `ns` (the second vararg), used for `ns.Rows`, `ns.Glow`, `ns.SQ_COLORS` and the widget
constructors. `SquizzumablesDB` is the single `SavedVariables` table (declared in the `.toc`),
containing all persisted profiles.

Files are large (`Squizzumables.lua` is ~10,000 lines); within a file, sections are marked with
`-- ====...====` or `------...------` banner comments — use these (via grep) to jump to a feature
area rather than reading linearly.

## Architecture

**Profile system** (`Squizzumables.lua`, "Profile System" section): settings are stored in named
profiles under `SquizzumablesDB.profiles`, assigned per character (`charProfiles`) with an
optional per-spec override (`specProfiles`). `BH:GetActiveProfile()` /
`BH:SaveToProfile()` / `BH:LoadFromProfile()` move data between the active runtime settings and
the profile store. Frame positions are tracked separately via `PROFILE_POSITION_KEYS` since each
draggable frame persists its own anchor.

**Options panel**: hand-rolled (no Ace3/Blizzard `Settings` framework abstraction beyond basic
registration) — see the "Options Panel" / "Main Options Panel" / per-feature "Settings Tab"
sections in `Squizzumables.lua`. Each feature area (raid tools, text reminders, sounds, class
buffs, dungeon callouts, CDM) has its own tab-building function.

**Taint safety** is a first-order design constraint, not an afterthought — WoW's combat lockdown
model forbids addons from mutating protected/secure frames during combat:
- The CDM module (`Squizzumables_CDM.lua`) never reparents or writes into Blizzard's Cooldown
  Viewer frames; it only reads their state via `hooksecurefunc` on read-only callbacks
  (`OnActiveStateChanged`, `OnUnitAuraAddedEvent`, etc.) and drives its own proxy icon frames.
  Container/layout mutations are queued when `InCombatLockdown()` is true and flushed on
  `PLAYER_REGEN_ENABLED`.
- When adding new features that touch frames, action buttons, or secure state, check
  `InCombatLockdown()` and queue mutations rather than assuming they'll succeed mid-combat.

**Secret aura values (client 12.1.0+)**: as of 12.1.0, `C_UnitAuras.GetAuraDataByIndex` **throws**
a taint error ("Auras cannot be accessed when secret") instead of returning `nil` when auras are
secret — which happens in combat, encounters, M+, and PvP, i.e. exactly when these reminders most
need to work. Worse, the fields on a successfully-returned aura table can *themselves* be secret:
assigning/storing/passing one is fine, but *comparing* it (`==`, `<`, `>`) or doing arithmetic on
it (`-`, `+`) throws — `attempt to compare field 'spellId' (a secret number value, while execution
tainted by 'Squizzumables')`. That was a live user crash on retail (v1.58, `UnitHasBuff`'s
`auraData.spellId == id` fallback scan).

**Always go through `BH.Secrets` (`Squizzumables_Secrets.lua`). Never read an aura field directly,
and do not reach for `pcall`.**
  - `BH.Secrets.GetAuraBySpellID(unit, spellID, filter)` — direct lookup, preferred whenever the
    spell ID is known up front (this API does not throw the way the index scan does).
  - `BH.Secrets.ForEachAura(unit, filter, func)` — index scan, for when an arbitrary/unknown aura
    must be found (`ForEachPlayerBuff`, the class-buff fallback scan for protected/stance auras
    like Lightning Shield). Return `true` from `func` to stop. A failed read ends the scan.
  - `BH.Secrets.SafeAuraSpellID` / `SafeAuraName` / `SafeAuraExpiration` / `SafeAuraDuration` /
    `SafeAuraSourceUnit` / `SafeAuraStacks` — read one field. **Each returns `nil` when the value
    is unreadable, so the result is always safe to compare and do arithmetic on.** Treat `nil` as
    "not present"; that is the safe direction for a reminder addon.
  - `BH.Secrets.IsSecret(v)` / `HasAnySecret(...)` / `SafeNumber(v, fallback)` /
    `SafeString(v, fallback)` for non-aura values (the CDM module's cooldown start/duration,
    spell names and icons).
  - `BH.Secrets.AurasAreSecret()` wraps `C_Secrets.ShouldAurasBeSecret()` if you want to skip work
    entirely rather than scan and discard.

These are built on the client's real predicates — `issecretvalue`, `issecrettable`,
`hasanysecretvalues`, `C_Secrets.ShouldAurasBeSecret` — which is why the check happens **once**,
where the value is read, instead of at every downstream comparison. The addon previously wrapped
each comparison in `pcall`; that worked but allocated a closure at every call site (including
per-button per-frame in the countdown timer) and had to be repeated at every downstream operation,
which is how the v1.58 crash got through. If you find yourself adding a `pcall` around a
comparison, use a `Safe*` accessor instead.


**Alerts that fire on *absence* need an extra guard.** An unreadable value looks
identical to a missing one, so any alert whose trigger is "this is not there"
will fire spuriously the moment data goes secret — which is exactly when combat
starts. The class buff sounds did this: every alert went off at the start of a
pull for buffs the player actually had. The Cooldown Manager's "removed" and
"available" alerts had the same latent shape, since an unreadable cooldown reads
as "not on cooldown", i.e. as the ability becoming ready.

Alerts that fire on *presence* are safe — unreadable data just means they stay
quiet, which is the harmless direction.

So for anything that alerts on absence:
  - check `BH.Secrets.AurasAreSecret()` (or the relevant readability flag) and
    skip the whole comparison when it is true
  - leave the previous-state tracking table **untouched** as well, not just the
    sound. Recording state from an unreadable pass overwrites the real state,
    and the next readable pass then treats things that never moved as fresh
    transitions
  - remember `C_Secrets.ShouldAurasBeSecret` may not exist, in which case
    `AurasAreSecret()` answers "not secret" and protects nothing — keep a
    time-based suppression on `PLAYER_REGEN_DISABLED` as the fallback

`SafeAuraExpiration` deliberately passes `0` through unchanged rather than normalising it to
`math.huge`. `0` is the client's "permanent / no duration" marker and this addon's call sites test
for it explicitly (`BH:NeedsRefresh` treats `0` as "never needs refreshing"; `CreateButton` treats
`> 0` as "this button gets a countdown").

**Death/combat-log event lockdown (client 12.1.0+)**: `COMBAT_LOG_EVENT_UNFILTERED` has been
removed from the addon API entirely, and the plain `UNIT_DIED` game event does not reliably fire
for party/raid members who are off-screen — both ruled out for the M+ Death Tally
(`BH:PollDeathTally` in `Squizzumables.lua`). It instead polls `UnitIsDeadOrGhost(unit)` per group
member on a 0.5s `AnimationGroup` ticker (same "cheaper than `OnUpdate`" pattern the Battle Res
Counter uses) and edge-detects the false→true transition. **Don't reach for combat-log events or
`UNIT_DIED` for new features that need to detect a group member's death or combat state — poll
instead.**

**Cooldown Manager sound alerts** (`Squizzumables_CDM.lua`): five findings here cost a long
debugging session each; none are guessable from the API docs.

*Secrecy is itself information.* `C_Spell.GetSpellCooldown` returns secret `startTime`/`duration`
in combat, so an addon cannot compute whether a spell is ready — `duration == 0` throws. But
Blizzard's `CooldownViewerItemMixin` already computed it and cached the answer on the item frame
as `isOnActualCooldown` / `cooldownIsActive`. Those are derived from the secret timestamps *only
while a cooldown is running*; when the spell is ready there is nothing secret to derive from and
the field reads as a plain `false`. Observed in one pass, in combat:

    Hammer of Justice   (ready)       isOnActualCooldown = false
    Blessing of Freedom (on cooldown) isOnActualCooldown = SECRET

So **secret means "on cooldown"**, and the `SECRET → false` transition is exactly "now available".
Treating secret as "unreadable, give up" is what kept the available alert silent in combat for
weeks. The failure direction is safe: a value secret for some unrelated reason makes an alert
late, never spurious.

*A spell can live in two viewers at once.* Blessing of Freedom is `61107` in
`UtilityCooldownViewer` (tracks its cooldown) **and** `92824` in `BuffIconCooldownViewer` (tracks
the aura it applies). Only the cooldown-type viewers (Essential, Utility) populate the cooldown
fields; a buff item leaves them `nil` forever. Resolve a spell to its *cooldown-type* item before
reading cooldown state — `cdmModule.cooldownForSpell` exists for this.

*`cooldownID` is not a stable key; `spellID` is.* The same spell appears under different
cooldownIDs between category sets and between builds, so alerts saved against one silently stop
matching. Sound alerts are stored keyed by spellID (`AlertKey`), with a one-time
`MigrateSoundAlerts` folding legacy cooldownID keys over. That migration is **all-or-nothing on
purpose**: it is not idempotent, so writing a partial result back would let the next run migrate
its own output and remap alerts onto the wrong spell. EllesmereUI independently keys by spellID
for the same reason.

*Viewer items come from a frame pool, lazily.* Blizzard drives them from
`itemFramePool:EnumerateActive()` (see `CooldownViewerMixin:OnUpdate`), not `GetChildren()`, and
acquires them on its own schedule. A one-shot sweep at load hooks the buff viewers but misses
Essential/Utility. Re-sweep on a timer; it is idempotent via a per-frame tag. Read `cooldownID`
off the item inside any hook callback rather than closing over it — pooled frames get recycled
onto other cooldowns.

*A cooldown finishing is a clock event, not a state-change event.* Nothing fires when a timer
merely runs out, so the sound pass needs its own ticker. Driving it only from state-change hooks
meant transitions sat pending until something unrelated happened to call it — which presented as
"the sound plays when combat ends, or when some other spell's alert fires".

`hooksecurefunc` on `CooldownViewerItemMixin:TriggerAlertEvent` is also wired up and gives
Blizzard's own alert timing (it fires regardless of whether the player configured a Blizzard
alert, since the gating is inside the function). It is not the primary path — it appears not to
fire when the viewers are alpha-suppressed by another addon — so both it and the poll run, with
`ClaimAlert(spellID, when)` dropping whichever notices second inside 0.6s. Never let one path
suppress the other outright: whichever is favoured will eventually be the one that is broken.

**Encounter timeline** (`Core/EncounterTimeline.lua`, `BH.Timeline`): only the **write** side of
`C_EncounterTimeline` is usable. On the read side, `EncounterTimelineEventInfo` exposes just `id`,
`source`, `duration` and `maxQueueDuration` as readable values — `spellID`, `spellName`,
`iconFileID`, `icons`, `severity` and `isApproximate` are secret, so they can be passed to a
display function but not compared. **An addon can draw a bar for an incoming boss ability and
cannot find out which ability it is**, which rules out "play my sound when <ability> is coming".
BigWigs hits the same wall and works around it by rounding `duration` to the nearest second and
looking it up in a hand-built per-boss, per-difficulty table (see `BigWigs_MidnightLairs`) — a
per-patch treadmill this addon is not taking on. Don't reattempt per-ability timeline alerts
unless Blizzard un-secrets `spellID`.

The write side (`AddScriptEvent`) carries our own data, so nothing about it is secret; use
`BH.Timeline.Add`/`Start`/`Cancel` rather than calling the API directly, and note `iconFileID`
must be a numeric file ID (`C_Spell.GetSpellTexture(id)`), not a texture path. `/sq timeline`
reports feature availability and fires a test event.

**Consumable/buff reminder core** (`Squizzumables.lua`): on `PLAYER_LOGIN` and periodic
bag/aura/equipment events, scans configured item IDs in `BH.defaults.consumables` and buff spell
IDs in `BH.defaults.classBuffs` against current bags/auras/weapon enchants and renders
clickable reminder buttons. Class buff entries support flags like `petCheck`, `selfBuff`,
`tankBuff`, `weaponImbue`, `auraCheck`, and `buffVariants` (mutually-exclusive/equivalent buff
IDs) — follow the existing per-class entry shape in `Squizzumables_Config.lua` when adding new
class/spec handling rather than inventing a new flag scheme.

**Text reminder registry and gates** (`Squizzumables.lua`, "Text reminder registry"): every
standalone text reminder is one record in `BH.REMINDERS`. Frame construction, the options-tab
block, the settings keys and the saved anchor are all derived from `key`, so adding a reminder
means adding a record — not new frame code. Each record also declares `gates = { ... }`, naming
predicates in `BH.REMINDER_GATES` (`enabled`, `class`, `spec`, `notSpec`, `knows`, `buffEnabled`,
`equipped`, `visible`, `outOfCombat`, `group`, `realGroup`). `BH:ReminderGate(def)` runs them and
returns the frame, or nil once it has hidden it; each `Update<Name>Reminder` opens with that and
then contains only what is genuinely specific to it. **Put a new visibility condition in the gate
table, not inline** — the ten hand-written copies of these checks had drifted apart, and one of
them (the bag reminder's master toggle) had silently stopped being read at all. An unknown gate
name errors at load rather than passing quietly.

Two things sit outside the gate list. `healerCC` is `eventDriven` — driven by `BH:CheckRoleCC` off
`UNIT_AURA`, with no gates and no `shouldShow`. And `combatSafe` on a record is read by
`BH:HideCombatUnsafeReminders` on `PLAYER_REGEN_DISABLED`, which sweeps the reminders not worth
showing mid-fight off screen. The ones that stay up (Beacon, Earth Shield, Symbiotic, Coach
Whistle, pet, Healthstone) are the ones with it set. There is no matching "show" call — leaving
combat just runs `UpdateAllReminders`, so every frame is re-decided on its merits through the gates.

**Kelerts** (`Squizzumables_SpellAlerts.lua`): `settings.alerts` is a table of alert records
keyed by an internal id, each with its own `trigger`, image, sound and timing. `alerts.lust` is
flagged `builtin`: it cannot be renamed or deleted, and it is the only one with no `trigger.spellID`
because it watches all of `LUST_DEBUFF_IDS` at once. Everything else in the table is user-made.
`CurrentAlert()` is the tab's cursor and deliberately falls back rather than returning nil.
Triggers are *presence* checks through `BH.Secrets.GetAuraBySpellID`, so secret auras make an
alert quiet rather than spurious — see the absence-guard note above for why that direction matters.

**Consumable data churn**: item/spell IDs in `Squizzumables_Config.lua` (`consumables.food`,
`.flask`, `.oil`, and `classBuffs`) are expansion/season-specific and go stale when Blizzard
rotates seasonal items — check `changelog.txt` for the most recent update pattern before adding
new IDs.
