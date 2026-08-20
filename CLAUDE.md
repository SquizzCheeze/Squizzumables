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
- `changelog.txt` is maintained by hand; check it for recent behavioral history/root-cause notes
  before assuming something is a fresh bug — many past fixes have detailed root-cause writeups
  there worth reading first.
- Useful in-game slash commands while developing: `/sq config` (options panel), `/sq reset` (reset
  main frame position), `/sq reload` (recompute buttons), `/sq feast` and `/sq debug` (diagnostic
  dumps), `/squizz` (open config directly; `/squizz CDMS` opens the hidden CDM Sounds tab),
  `/ginvite <name>` (guild invite helper).

## File layout and load order

Load order is defined in `Squizzumables.toc` and matters — later files assume earlier ones already
initialized `BH`:

1. `Libs/LibStub/LibStub.lua`, `Libs/LibSharedMedia-3.0/LibSharedMedia-3.0.lua` — third-party libs, don't edit.
2. `Squizzumables_Config.lua` — static data only: consumable item IDs (food/flask/oil) and
   per-class buff definitions (`BH.defaults`). Update this file each expansion/season when
   consumable item IDs rotate.
3. `Squizzumables.lua` — the core: default settings (`BH.defaultSettings`), the profile system,
   the main consumable/buff reminder frame, the entire options/settings UI (all tabs), most of the
   standalone reminder frames (repair, symbiotic, pet, battle-res, food/flask/oil "empty bag"
   reminders, healer CC), raid tools (pull timer/markers), dungeon callouts, feast announce, and
   the event dispatcher + slash commands at the bottom.
4. `Squizzumables_CDM.lua` — Cooldown Manager proxy module (`BH.cdm`).
5. `Squizzumables_SpellAlerts.lua` — "Just For Kel" custom spell-triggered image/sound alerts.

All modules share a single global table `BH` (each file does `local BH = BH` or
`if not BH then BH = {} end`) — this is the addon's namespace; there is no `require`/module
system. Feature-specific submodules attach themselves as `BH.cdm`, etc. `SquizzumablesDB` is the
single `SavedVariables` table (declared in the `.toc`), containing all persisted profiles.

Files are large (`Squizzumables.lua` is ~9000 lines); within a file, sections are marked with
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

**Consumable/buff reminder core** (`Squizzumables.lua`): on `PLAYER_LOGIN` and periodic
bag/aura/equipment events, scans configured item IDs in `BH.defaults.consumables` and buff spell
IDs in `BH.defaults.classBuffs` against current bags/auras/weapon enchants and renders
clickable reminder buttons. Class buff entries support flags like `petCheck`, `selfBuff`,
`tankBuff`, `weaponImbue`, `auraCheck`, and `buffVariants` (mutually-exclusive/equivalent buff
IDs) — follow the existing per-class entry shape in `Squizzumables_Config.lua` when adding new
class/spec handling rather than inventing a new flag scheme.

**Consumable data churn**: item/spell IDs in `Squizzumables_Config.lua` (`consumables.food`,
`.flask`, `.oil`, and `classBuffs`) are expansion/season-specific and go stale when Blizzard
rotates seasonal items — check `changelog.txt` for the most recent update pattern before adding
new IDs.
