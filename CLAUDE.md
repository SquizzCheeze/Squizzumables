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
- Linting is done via the **WoW Lua Language Server** (`tradeskillmaster.wowlua-ls`), which is what
  produces the diagnostics in the editor — every message's `source` reads `wowlua_ls`. It has the
  WoW API stubbed in already, so no annotations extension is needed for the check to pass; the
  `ketho.wow-api` extension is still worth having for hovers and for the FrameXML source it ships
  (see "Researching the WoW API").

  **`.wowluarc.json` is the only lint config.** It sets `library: ["Libs/"]` (which is what excludes
  LibStub/LibSharedMedia from the check) and the `globals.read` / `globals.write` allowlists. New
  globals go there and nowhere else. Verified load-bearing by moving it aside: the check went from
  12 files/0 warnings to 14 files/3 warnings.

  `sumneko.lua` may also be installed. It is **not** the server serving these results, and it is
  switched off for this workspace by the one `Lua.diagnostics.enable: false` line in
  `.vscode/settings.json`. There used to be a `.luarc.json` plus a `Lua.*` block in that settings
  file carrying a second copy of the globals list for sumneko; the two copies drifted, so both were
  deleted. Do not reintroduce a second config — if sumneko diagnostics are wanted, they need their
  own globals list and it will drift again.

- **There IS a CLI lint. Use it — it is the real gate.** The extension ships a headless binary with
  a `check` subcommand:

      "$HOME/.vscode/extensions/tradeskillmaster.wowlua-ls-<ver>/server/win32-x64/wowlua_ls.exe" \
          check "C:/World of Warcraft/_retail_/Interface/AddOns/Squizzumables"

  Several versions are usually installed side by side; take the highest. It checks the whole addon
  in ~3s, defaults to `--severity warning`, and takes `--severity hint` for the full set (there are
  ~85 hints, mostly `shadowed-local` on `self` and unused `addonName` locals — noise, not defects).
  Other subcommands: `evaluate <file>` (tree + types + diagnostics for one file), `test-query`,
  `doc`, `profile`.

  **It reads the files from disk, so it is accurate immediately after a shell or tool edit** — no
  window reload, none of the staleness described below.

  Two gotchas found the hard way:
  - **`---@cast` takes no trailing comment.** Unlike sumneko, this server parses the rest of the
    line as the type name, so `---@cast x number  some note` yields
    `undefined-doc-name: undefined type 'number  some note'` **and** silently fails to apply the
    cast, so whatever `type-mismatch` it was meant to silence comes back. Put the comment on its
    own line above. `---@param` on a local function is the other tool for these.
  - Type-mismatch warnings here are usually inference, not bugs: a param whose type LLS widened
    from a union (`number|string|table`) that the code narrows by testing a *different* variable
    (e.g. `if actionType == "item" then` narrowing `actionValue`). LLS cannot follow that. Annotate
    or cast; do not restructure working code to satisfy it.

- There is no Lua interpreter here, so four standalone checks in `.claude/` stand in for the
  parse. They are much faster than the CLI and catch the corruption classes below that a type
  checker passes happily; run all four after any bulk edit, then the CLI check:

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

  **A grep audit lies in two specific ways, and both produced confidently wrong findings in 1.86.**
  Asked whether any options setting was dead, two sweeps of this file each reported one — and
  neither was real:

  - **A key at END OF LINE.** `groupData\.showKeybind[^A-Za-z0-9_]` never matches
    `local want = groupData and groupData.showKeybind`, because there is no trailing character.
    It scored zero reads and looked like a dead control. Always allow end of line:
    `([^A-Za-z0-9_]|$)`.
  - **Table-driven writes.** Grepping `groupData%.<key> = ` misses every setting written as
    `groupData[def.key] = value`, which is how the five visibility conditions and all three text
    placements are set. They looked like honoured-but-unreachable features with no UI at all; they
    have had controls the whole time.

  A static audit cannot be trusted while settings are reached through indirection. The check that
  actually held was set-based: extract the old function verbatim first, then diff the SET OF
  SETTING KEYS before and after (58 to 58, nothing missing either direction). Do that before
  claiming anything is dead, and before claiming a refactor dropped nothing.

  Validate a new check against a known-bad file *and* a known-good one. Note that the corruption
  can hit the test as easily as the code: bash `printf` and Perl both read `\226` as octal, so a
  control file has to be written with explicit `chr(92)` to contain a real backslash.

  **Do not trust `mcp__ide__getDiagnostics` after editing files from the shell** — or from Read /
  Edit / Write, which are equally external to the editor. The language server serves a cached
  result and does not rescan on an external write, so it reports the previous version of the file,
  including a clean bill of health for code that no longer exists. `touch` does not invalidate it
  and neither does re-querying a single URI; only the user reloading the VS Code window does. The
  tell is that the reported line numbers no longer land on the constructs named in the message;
  check one before believing any of it.

  **Run `wowlua_ls.exe check` instead of asking the user to reload.** It is the same server reading
  the same config off disk, it answers in seconds, and it is never stale. Reserve
  `getDiagnostics` for files edited through the editor itself.

- `changelog.txt` is maintained by hand and holds **only the version currently being built** —
  the packager ships it verbatim, so anything older in it gets reposted to CurseForge as the new
  version's release notes. Shipped versions move to `CHANGELOG-ARCHIVE.txt`, which is in the
  `.pkgmeta` ignore list and never ships. **Grep the archive, not `changelog.txt`**, for recent
  behavioral history/root-cause notes before assuming something is a fresh bug — many past fixes
  have detailed root-cause writeups there worth reading first.
- **`/sqstackdiag` is a temporary diagnostic — delete it once the question is answered.**
  `Squizzumables_StackDiag.lua` (2026-09-01) exists to attribute a BugSack entry reading
  "8x C stack overflow" with no stack and an empty Locals block. That blankness is expected, not a
  BugSack fault: `grabError` stores the error object *before* calling `GetErrorStack`, and
  `debugstack()` needs stack space a C stack overflow has already consumed — so the message
  survives and the attribution does not.

  It answers "was our code on the stack" rather than "who errored", by wrapping every reachable
  repeating entry point in `xpcall` and catching at our own boundary, where the label is still
  known. `/sqstackdiag on | off | report | clear`; inert until switched on. `report` also lists
  what it managed to wrap, because otherwise "caught nothing" cannot be told apart from "nothing
  was being watched". Ported from the identical diagnostic written for SquizzFrames (2026-08-29),
  which cleared *that* addon — both being cleared points at a shared third party, the same shape
  as the GBankManager callout case.

  Removing it means the file, its `.toc` line, **and** the `cdmModule.eventFrame` export in
  `Squizzumables_CDM.lua`, which exists only so this can reach that handler.

- **The diagnostics are unlisted, and CLAUDE.md is the only place they are written down.** The
  `/sq` help output prints only the player-facing commands (`config`, `reset`, `raidtools`,
  `unlock`, `reload`, `notes`, `/ginvite`). Every diagnostic below still works exactly as before —
  it is just not advertised, because they are support tools and listing them invites players to
  run dumps they cannot read. Ask for one by name when a bug report needs it. When adding a new
  diagnostic, wire the handler and **do not** add it to the help block, the changelog or
  `RELEASE_NOTES`; add it here instead.

- Useful in-game slash commands while developing: `/sq config` (options panel), `/sq reset` (reset
  main frame position), `/sq reload` (recompute buttons), `/sq unlock` (toggle unlock mode),
  `/sq raidtools`, `/sq notes` (reopen the release notes), and the unlisted diagnostic dumps
  `/sq welcome` (replay the first-run popup), `/sq feast`,
  `/sq debug`, `/sq dk`, `/sq timeline`, `/sq auras` (aura secrecy state),
  `/sq auras <spellID>` (per-spell secrecy: run it with the aura up, once out of combat and once
  in, when an alert fires in one and not the other), `/sq cdm` (CDM
  sound wiring) and `/sq buffsounds` (which `AddAuraSound` registrations the client accepted, what
  it refused, and which call site asked for the last rebuild — run this first on any
  blocked-call report about buff sounds), `/sq cdmtaint` (whether this addon has tainted
  Blizzard's Cooldown Manager — the first thing to run on any report of errors that come from
  Blizzard's own code and name Squizzumables; see the taint-spread note under "Taint safety" for
  why nothing else can answer that) and `/sq cdmbuff` (per tracked-buff frame: whether
  `IsActive` answers or is secret, whether `auraInstanceID` is usable, whether `GetAuraDuration`
  yields anything, and whether the swipe mirror and a proxy exist — this is what finally settled
  the 1.69 buff-swipe hunt after several wrong guesses) and `/sq cdmnative` (the native buff
  slots: whether Blizzard_AuraContainer loaded, and per group how many slots registered and how many
  buttons the engine actually built — slots but no buttons means the engine never created them,
  buttons but nothing on screen points at sizing or anchoring), `/sq nameplates` (the purge row:
  per plate its unit, anchor and row state, plus the filter, the candidate filters, the container's
  size — anything above 1x1 means icons were actually laid out — and the last init error) and
  `/sq nameplates test` / `testoff` (three rows on UIParent bound to your target, each a different
  narrowing, with a client-filled dispel-type readout; see the Nameplate purge glow section for why
  this exists and how to read it). **Both nameplate commands answer "module not loaded" right now**
  — that feature is disabled, see its section below.
  `/squizz` opens config directly and `/squizz <TabID>` jumps to a named page.
  `/ginvite <name>` is the guild invite helper.

### Researching the WoW API

**Gethe/wow-ui-source `live` is the bible. Fetch it; do not answer from the local extension or
from memory.**

    https://github.com/Gethe/wow-ui-source        (branch: live)
    https://raw.githubusercontent.com/Gethe/wow-ui-source/live/Interface/AddOns/<Blizzard_Addon>/<File>.lua

It is an automated mirror of the shipped client's own UI code and generated API documentation,
committed per build — the commit messages are literally `12.1.0 (69587)`. So it is both the real
client code *and* current to within days. Check the top commit on
`https://github.com/Gethe/wow-ui-source/commits/live` when the answer depends on how recent the
data is.

The two paths worth knowing:

    Interface/AddOns/Blizzard_APIDocumentationGenerated/<Namespace>Documentation.lua   -- signatures,
        structures, and the restriction flags (HasRestrictions, SecretArguments, MayReturnNothing)
    Interface/AddOns/Blizzard_<AddonName>/<File>.lua                                   -- the real
        behaviour: which CVar gates a feature, when a frame shows itself, what a flat `false` means

**The locally installed `ketho.wow-api` extension is a convenience, not a source of truth — it
lags.** It is fine for editor hovers and for a fast first grep to find *which file* answers a
question. Confirm anything load-bearing against Gethe before acting on it. Checked 2026-09-06, the
installed 0.22.3 copy was wrong about `Blizzard_CooldownViewer` in four ways that each changed a
conclusion: `Enum.CooldownViewerCategory` had 4 categories where live has 9, the hidden
pseudo-categories were named `HiddenSpell`/`HiddenAura` where live has `HiddenActive = -1` /
`HiddenPassive = -2`, `CooldownViewerCooldown.spellID` was non-nilable where live marks it
nilable, and `CooldownViewerMixin:RefreshData` took no arguments where live takes
`(cooldownIDs, forceSet)`.

warcraft.wiki.gg is community-written and has been wrong here in ways that changed conclusions:
for `C_EncounterTimeline` it listed 7 functions where the real API has 33, omitted the entire
write side of the namespace, and claimed a structure field had been removed that still exists.
Use it for prose explanation if helpful, never as the basis for a decision.

Last resort, and only for behaviour Gethe cannot show: a *currently maintained* addon running on
*current* content. Be careful which — an addon folder for a previous expansion is not evidence
about this one. Reading `LittleWigs_TheWarWithin` (11.x modules, 11.x content) once led to the
wrong conclusion that `COMBAT_LOG_EVENT_UNFILTERED` still worked, when the giveaway was that no
Midnight pack existed at all. Check the `.toc` interface version before treating an addon as
current.

## Releasing

Published to CurseForge (project `1483099`) and GitHub Releases by
`BigWigsMods/packager`, driven from `.github/workflows/release.yml` and configured by
`.pkgmeta`. Ordinary commits publish nothing; a tag publishes.

    # bump ## Version in the .toc, add a changelog.txt section, commit
    git tag -a v1.61 -m "Squizzumables 1.61"
    git push --tags

**The tag must be annotated (`-a`).** `git describe` ignores lightweight tags, so the packager
falls back to the commit hash and ships an "alpha" build named after it instead of a version.

**A tagged version is closed.** Nothing more goes onto that version number, and the `.toc`,
`changelog.txt` and `RELEASE_NOTES` all stay at the shipped number until there is real work to
ship — do not pre-bump after a release. The *next* change opens the next version, as its first
step:

1. move the shipped section out of `changelog.txt` into the top of `CHANGELOG-ARCHIVE.txt`, so
   `changelog.txt` holds only the version being built (the packager ships it verbatim)
2. bump `## Version` in `Squizzumables.toc`
3. start the new `changelog.txt` section
4. add the matching `RELEASE_NOTES` key in `Core/Welcome.lua` — it is keyed on the `.toc`
   Version string, so a bump without one means an empty update popup

Then make the change. `git tag -l` tells you which state you are in: if the `.toc` version is
already tagged, it is closed and step 1 applies.

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
    `Squizzumables_CDMAuras.lua` loads straight after it — the native buff slots (`BH.cdm.native`),
    fed through `cdmModule.shared`. A separate file partly to keep the CDM main chunk clear of Lua
    5.1's 200-local limit.
13. `Squizzumables_SpellAlerts.lua` — "Kelerts", the user-defined spell alerts (full-screen image
    + sound on an aura), and the M+ Death Tally.

The `.toc` also carries `UI/SubTabs.lua` (after Widgets, before Rows), `Core/TargetDistance.lua`
(after Welcome), `UI/CDMPreview.lua` (straight after `Squizzumables_CDMAuras.lua` — see "CDM options
preview" below) and `Squizzumables_StackDiag.lua` (last, and temporary — see above), none of which
the numbered list above describes.

**`UI/SubTabs.lua` has two constructors and they are not interchangeable.** `Create` builds a
strip plus **one ScrollFrame per page**, for a top-level tab. `CreateInline` (1.86) builds a strip
plus **plain show/hide frames** and no scroller at all, for a third level inside a page that is
already a scroll child — a ScrollFrame nested in a ScrollFrame scrolls badly and swallows the
wheel. Instead the HOST's height follows whichever section is showing (`SetPageHeight(key, h)`
after filling one), so the outer scroller scrolls just the open section rather than the sum of all
of them. A caller that sets the host height itself afterwards will fight the widget and cut the
taller sections off.

Each group's CDM settings use it: one page per group, sections Layout / Appearance / Text /
Behaviour / Visibility, plus Buffs on groups that hold them (`GROUP_SECTIONS` in
`Squizzumables_CDM.lua`). `BH:BuildGroupSection`'s `tabbed` argument picks between that and the old
stacked column; **both layouts run the same six builder functions**, so they cannot drift apart.

**Custom Icons is tabbed too since 1.89** (user request), and that needed a layout change, not
just `tabbed = true`. That page lays out by a running `yOffset`, and a tabbed group's height follows
its selected sub-tab — so a group cannot sit at a fixed offset. `RebuildCDMPage` builds each custom
group into its **own host frame** stacked under the previous one, and everything after the groups
(Available Cooldowns, Refresh) into a **tail frame** anchored below the last host: from that point
`content` IS the tail and `yOffset` restarts at 0. `ResizeCustomPage` sums hosts + tail into the
page height, from each host's `OnSizeChanged` and once directly at the end (a frame not yet shown
may not fire it). The stacked column is still what `tabbed = false` builds; nothing calls it today.

⚠ **A control that only applies to cooldown icons must be HIDDEN on the built-in buff groups**, not
merely inert there (1.88). `ApplyProxyVisuals`' `isCooldownType` gates Show While Active, Proc Glow
and Dim When Unusable — a tracked buff has no proc highlight, no "can you cast this", and already
draws its own duration. All three were still offered on Buffs and Buff Bars, and a user ticked Show
While Active there instead of on Essential, which reads exactly like the feature being broken and
cost a session of diagnosis. `buffOnlyGroup` in `BuildGroupBehaviourSection` skips them; custom
groups keep them, since a custom group can mix cooldowns and buffs. Each row closes its own
`yOffset` so a hidden one leaves no gap.

⚠ **The selected section is remembered OUTSIDE the widget** (`cdmGroupTab`, keyed by group name).
`ClearCDMPage` reparents every child of a page away on each rebuild, and a rebuild happens whenever
any setting on it changes — so a widget-held selection would snap back to the first tab on every
click. Any future nested-tab page needs the same treatment.

**CDM options preview (`UI/CDMPreview.lua`, 1.89).** A true-size picture of each group: pinned
above each built-in sub-tab (`Preview.AttachToSubTab`, which re-anchors that page's scroller below
the pane), and under each custom group's heading (`Preview.PlaceInline`, fixed height). Rules that
are load-bearing:

- **It draws with the real code, never a copy.** Everything comes through `cdmModule.PreviewKit`,
  assembled at the very END of `Squizzumables_CDM.lua` — several of its members are forward-declared
  locals assigned further up, and a table captures the value at assignment, so building it earlier
  captures nils. Icons are `CreateProxyIcon` + `ApplyProxyVisuals`; buffs are `GetBuffPlaceholder`;
  placement is `cdmModule.Grid`. `cdmModule:PreviewMembers(groupName)` lists what a group would show,
  in order.
- **`ApplyProxyVisuals(proxy, groupData, preview)`** — the third argument skips everything that
  reads live state: the real proc (`SyncProcGlow`), the usable tint and the whole cooldown/aura
  pass. That pass **fires the CDM sound alerts**, so a preview icon must never reach it. The preview
  mocks state itself: icon 1 procced, icon 2 on a repeating 12s cooldown, icon 3 with stacks.
- **`group.previewLook`** makes `GetBuffPlaceholder` draw a slot as a live buff (bar at 65%, "12s").
  The preview hands it a fake group table (`{ container = host, placeholders = {} }`) and sets the
  flag per placeholder, so one row can show live and inactive slots side by side.
- **Glow frames are pinned to MEDIUM strata** (`RaiseGlowFrame`, fixed strata AND level 300), which
  would draw a preview's glows under the DIALOG-strata options window. `LiftToStrata` unpins and
  re-pins them to the pane's strata — preview icons only. The pane's button and scroll bars sit at
  level 400 to stay above those glows.
- **Always 1:1, never scaled to fit** (user request). The host takes
  `UIParent:GetEffectiveScale() / pane:GetEffectiveScale()`; a group that does not fit scrolls in a
  `ScrollFrame` that runs to the pane's bottom edge, UNDER the button row, with the button overlaid.
  The canvas carries `FOOTER_H` of extra height so an overflowing group's last row can scroll clear
  of the button. The wheel is captured only while something overflows, so otherwise it still
  scrolls the page.
- **Inline panes are cached per group** (`inlinePanes`) and reparented on each rebuild:
  `ClearCDMPage` orphans every child it finds and a frame cannot be destroyed, so a pane built per
  rebuild would leak.
- It redraws every 0.25s while visible — which is why no settings control needs to know it exists.

The pane's **Blizzard CDM Settings** button toggles `CooldownViewerSettings` through Blizzard's own
`ShowUIPanel` / `HideUIPanel` (what `/cdm` from CooldownManagerCentered calls), refusing in combat.
Blizzard's window has no strata of its own (MEDIUM) and ours is DIALOG, so it is lifted to DIALOG
while open and restored from an `OnHide` hook — nothing about it changes outside this button.

**Group geometry is shared: `cdmModule.Grid` (1.89).** `Grid.Icons(count, groupData, vertical)` /
`Grid.IconSlot(g, i)` and `Grid.Bars` / `Grid.BarSlot` are the only copy of the icon-grid and
bar-stack maths; `LayoutGroup`, `LayoutBorrowedBuffIcons` and the preview all call them. Before
1.89 the two layout passes each carried their own copy and they had drifted: **the borrowed Buffs
layout ignored the Orientation dropdown it offered** (always horizontal). It honours it now, which
moved anyone who had once picked Vertical there.

⚠ **`Squizzumables_CDM.lua` is ~21 locals short of Lua's 200-per-chunk limit** (179 top-level names
at 1.89, counted as `local` names plus `local function`s at column 0). New shared helpers go in ONE
table (`Grid` is the example: one local however much it holds) or on `cdmModule`; new UI goes in its
own file, as `CDMPreview.lua` does.

**One group per cooldown — enforced in `Reconcile`, not in `AssignToGroup`.** A built-in member has
`assignments[cdID] == nil`: it sits in Essential/Utility by default. `AssignToGroup` only clears the
PREVIOUS assignment's group, so moving a default member into a custom group left it in the built-in
group's `members` too. Both groups laid out the one shared proxy (proxies are keyed by cooldownID),
the custom group placed it last and kept it, and the built-in group kept its slot — an empty gap
(user screenshot, fixed 1.89). `Reconcile` now drops each cooldown from every group except its
assignment before placing it, which covers every route a cooldown can move by.

**Blizzard's Cooldown Manager decides WHAT exists; Squizzumables decides WHERE.** A spell the
player removes from Blizzard's bars is not discovered at all (see `BlizzardFilteredIDs` for why the
hidden list cannot be read taint-free), so it cannot be put in a custom group; re-enabling it in
Blizzard's settings brings it back into whatever group it was assigned to. Users have tried
"disable in Blizzard, then assign to custom" — that is the expected no-op, not a bug.

**`Squizzumables_Nameplates.lua` is on disk but NOT loaded**: its `.toc` line is commented out
(`#Squizzumables_Nameplates.lua`). It is a real file with real code, so grep will find it and the
linter still checks it — do not be misled into thinking it runs. See the Nameplate purge glow
section for why it is parked and what to restore to revive it.

All modules share one table `BH`, the addon's namespace; there is no `require`/module system.

**`BH` is NOT a global.** It lives on `ns`, the per-addon private table passed as the second
vararg. Every file opens with:

    local addonName, ns = ...
    local BH = ns.BH

`Squizzumables.lua` seeds it (`ns.BH = ns.BH or {}`); every later file just binds it. It used to
be a global and was moved because a two-letter name in `_G` invites a collision — the comment at
the top of `Squizzumables.lua` says so.

**`local BH = BH` reads nil and the linter will not save you.** A file opening that way gets nil,
falls through whatever `if not BH then return end` guard it has, and loads to no effect — no
error, no output, the feature simply does not exist. `wowlua_ls` accepts bare `BH` as a defined
global and reports nothing, verified by feeding it a file containing exactly that line (an
unrelated made-up name *is* reported, so this is specific to `BH`). This is written down because
this exact mistake shipped `/sqstackdiag` as a file that loaded and did nothing.

Feature-specific submodules attach themselves as `BH.cdm`, etc. `ns` also carries `ns.Rows`,
`ns.Glow`, `ns.SQ_COLORS` and the widget constructors. `SquizzumablesDB` is the single
`SavedVariables` table (declared in the `.toc`), containing all persisted profiles.

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

**A profile does not hold everything, and the split is deliberate.** `SaveToProfile` copies exactly
five things — `settings`, `disabled`, `minDuration`, `customItems`, and the
`PROFILE_POSITION_KEYS` anchors. Anything else has to be added there, to `LoadFromProfile`, **and**
to `Core/ProfileIO.lua`'s export/import payload, or it silently will not travel; the CDM layout was
missing from all three until 1.70, so "save to profile" captured none of it.

**CDM group layout lives ON the profile (`profile.cdmGroups`), not in a runtime copy.** That is
different from everything else here: `LoadFromProfile` copies settings *out* of the profile into
`SquizzumablesDB`, but groups are read live through `BH:GetActiveProfile().cdmGroups`, so
`SaveToProfile`/`LoadFromProfile` need no group plumbing at all and a switch takes effect by
itself. Groups are shared across every spec and character on that profile — one layout, styled
once, with a second profile being how you get a different one.

Assignments and free icons stay per spec in `SquizzumablesDB.cdmData[classID_specIndex]` and
**cannot** move onto the profile: both are keyed by `cooldownID`, which is a per-class, per-spec
number, so sharing them would map one class's spells onto whatever shared an ID on another. Group
*names* are the thing that crosses over. `GetSpecData()` returns a cached **view** stitching the
two together, which is what lets the ~35 `specData.groups[...]` call sites stay untouched; it is
keyed on table identity, so never give it a name-string key "for clarity" — that reintroduces a
per-call string allocation on the reconcile ticker.

Per-spec CDM **sound alerts** are still outside profiles. Keyed by spellID, so they *could* move
without the cooldownID problem; nobody has asked yet.

Any new profile-switch path must call `BH.cdm:OnProfileChanged()` — it invalidates that view,
rebuilds, and refreshes the settings tab, whose rows hold direct references to the old group
tables and would otherwise write into the profile just left. Four paths call it today:
`SwitchProfile`, the spec-change handler, profile delete, and "Reset from Default".

**Options panel**: hand-rolled (no Ace3/Blizzard `Settings` framework abstraction beyond basic
registration) — see the "Options Panel" / "Main Options Panel" / per-feature "Settings Tab"
sections in `Squizzumables.lua`. Each feature area (raid tools, text reminders, sounds, class
buffs, dungeon callouts, CDM) has its own tab-building function.

**`StaticPopup`: the edit box is `dialog:GetEditBox()`, NOT `dialog.editBox`.** The old field no
longer exists on 12.x, so reading it raises inside the popup's own callback — and an error there
produces no visible feedback at all, so the symptom is that the accept button *does nothing*.
That is how New Profile was broken (fixed 1.83), and Avatar hit the identical bug first. Use the
defensive form, since only the last of these is current:

    local editBox = dialog.GetEditBox and dialog:GetEditBox() or dialog.EditBox or dialog.editBox

Note `EditBoxOnEnterPressed` receives the **edit box**, not the dialog, so route both it and
`OnAccept` through one shared handler rather than having Enter reach back into `OnAccept` — the
old code did that and was broken by the same change. More generally: when a button appears
inert, suspect an error swallowed inside its handler before suspecting the logic behind it.

**Taint safety** is a first-order design constraint, not an afterthought — WoW's combat lockdown
model forbids addons from mutating protected/secure frames during combat:
- The CDM module (`Squizzumables_CDM.lua`) **never reparents** Blizzard's Cooldown Viewer frames.
  For cooldown-type entries (Essential/Utility) it reads their state via `hooksecurefunc` on
  read-only callbacks (`OnActiveStateChanged`, `OnUnitAuraAddedEvent`, etc.) and drives its own
  proxy icon frames. Container/layout mutations are queued when `InCombatLockdown()` is true and
  flushed on `PLAYER_REGEN_ENABLED`.

  **Tracked buffs are the exception, and deliberately so: the Buffs group displays Blizzard's own
  item frames, re-anchored.** It does write to them — `SetPoint` and `SetSize`, nothing else —
  while leaving them parented to Blizzard's viewer, which is what keeps it taint-free.

  This is not a shortcut; a proxy icon **cannot** show a buff's cooldown sweep in combat, and
  1.69 proved it three ways. The duration is secret so it cannot be read. It cannot be fetched
  either: with a perfectly readable `auraInstanceID` and unit, `C_UnitAuras.GetAuraDuration` still
  hard-errors on a restricted unit. And catching the duration object in flight (hooking
  `SetCooldown` on the Blizzard item) only works if the hook is installed before Blizzard uses the
  frame — which pooling makes unreliable, since a buff applied mid-fight lands on a freshly
  acquired frame.

  **A fourth way, learned in 1.86, and it is a RULE rather than a quirk: secrets carry an ASPECT,
  and a setter accepts one only if the aspect matches.** In the generated docs
  (`FrameAPICooldownDocumentation.lua`) `SetCooldown`, `SetCooldownDuration`,
  `SetCooldownFromExpirationTime` and `SetCooldownUNIX` all read
  `SecretArguments = "AllowedWhenTainted"` **with**
  `SecretArgumentsAddAspect = { Enum.SecretAspect.Cooldown }`. So "allowed when tainted" is not
  blanket permission: a secret whose aspect is *Aura* handed to one of those arguments is refused,
  with

      bad argument #1 to 'SetCooldown' … Secret values are only allowed during untainted
      execution for this argument.

  once per refresh — ~114 errors a fight when it was hooked to a cooldown item's widget.
  Blizzard's own active icons cache `auraData.expirationTime - auraData.duration`, so their
  numbers are Aura-aspect and can be neither read nor **forwarded**. `SetCooldownFromDurationObject`
  is the exception and the reason the buff mirror works: it takes a `LuaDurationObject`, which is an
  opaque handle rather than a secret, so no aspect test applies. That asymmetry is the whole story
  of why Blizzard hands a BUFF item a duration object (mirrorable) and a COOLDOWN item plain
  numbers (not).

  Do not reach for `SetCooldownFromExpirationTime` as a way around it; it carries the identical
  flags. Check `SecretArgumentsAddAspect` in the generated docs before assuming any setter will
  take a value that came from an aura.

  Borrowing sidesteps all of it: Blizzard keeps driving cooldown, icon, stacks and active state
  C-side, exactly as for its own bars. `LayoutBorrowedBuffIcons` owns only the anchors, and
  re-applies them from the 0.2s poll because Blizzard re-anchors on its own layout passes and the
  pool hands out frames mid-fight. `hideUntilActive` comes free — Blizzard hides an inactive
  tracked buff itself. EllesmereUI works the same way, and that is why its swipes never break in
  combat: they *are* Blizzard's swipes.

  Consequences worth knowing before "improving" this: the buff viewers must be exempt from
  "Hide Blizzard's Cooldown Manager" (their children inherit the viewer's alpha and position), and
  per-group border/zoom/background styling does not apply to buff icons, because they are
  Blizzard's icons. `cdmProxyBuffIcons` restores the old proxy path for anyone who wants the
  styling and can live without combat sweeps.

  **As of 1.76 there is a third path, and it is the default: native buffs
  (`Squizzumables_CDMAuras.lua`, `cdmNativeBuffs`, "Draw Buffs Ourselves").** Blizzard_AuraContainer
  (12.1) lets us build every piece of a buff button — icon, cooldown, font strings, status bar — and
  hand them to the client, which writes the live values in C-side. So the look is ours and the sweep
  still works in combat. One `AddAuraSlot` per tracked buff; the button is anchored (inside
  `initializeFrame`, the only legal moment) to a host frame on a **cell** of ours, and the cell takes
  the buff's slot in `LayoutBorrowedBuffIcons`. Blizzard's frame for the buff still decides whether
  it is up — `IsShown` stays readable in combat — so packing, placeholders and the unlock mock are
  unchanged; that frame is parked off screen by `ParkBorrowedFrame`, never hidden, because the sound
  alerts read it — **and, since 1.80, held at alpha 0, which is the part that actually works.**
  Parking alone does not: Blizzard shows and re-anchors its own frame the instant the aura goes
  active, and any correction of ours necessarily lands a frame later, so the bar appeared in
  Blizzard's position every time the buff came up. On a fast-toggling buff (one that is only up
  while moving) that reads as a second bar flickering behind the cooldown bars — reported
  2026-09-16, and a `SetPoint`/`ClearAllPoints` re-park hook did **not** fix it, which is the
  evidence for this note. Alpha survives any amount of re-anchoring. `HoldBorrowedParked` installs
  both hooks; `UnparkBorrowedFrame` clears the flag and restores alpha the moment the layout uses
  the frame as a real slot again, which matters because `hooksecurefunc` cannot be undone — an
  ungated hook would strand a frame invisible and offscreen forever once it stopped being ours. Things that will break it if forgotten, most of them from SquizzFrames' CLAUDE.md:
  no calls on an aura button outside `initializeFrame`; style a font string before registering it
  (an unstyled one hard-errors and aborts the whole batch); host anchored before `AddAuraSlot`; slots
  declared before `SetUnit`; containers only out of combat; do **not** define
  `CustomAuraButtonTemplate` (live Blizzard ships it with mixins; SquizzFrames' empty copy is
  PTR-era); never a HARMFUL slot on the player, because spell-ID candidate filters are ignored for a
  harmful aura on an assistable unit and it would show every debuff. Style changes restyle our pieces
  only; a rebuild happens only when the set of buffs changes, because containers can never be freed.
  A buff whose Blizzard item is up with `totemData` and no `auraInstanceID` (totem-style: no aura
  for a slot to show) cannot be drawn natively — an `AddAuraSlot` of ours has nothing to bind to and
  would render empty — so `ItemDrivenByTotem` diverts it every layout pass, and any slot that failed
  to build stays on the borrowed path entirely.
  **On a BAR group it is no longer handed back to Blizzard's frame (1.82).** Blizzard's own bar
  already holds the right fill whatever drives it, so the slot takes a placeholder bar of OURS and
  mirrors `child.Bar`'s min/max/value and countdown onto it (`CanMirrorBlizzardBar` /
  `MirrorBlizzardBar` / `MirrorBlizzardBarText` in `Squizzumables_CDM.lua`). That means we never have
  to know what drives the bar, which covers Consecration, Death and Decay and every other ground
  effect with no totem API at all. It is EllesmereUI's approach —
  `EllesmereUICdmBuffBars.lua`, *"reads min/max/value from Blizzard's Bar, zero duration
  computation"* — and worth reading there before changing any of it. Icon groups keep the old
  behaviour: `child.Bar` is nil on those children, confirmed via `/sq cdmbuff`, which reports a
  `Bar=` field per entry for exactly this. Guarded end to end: anything unmirrorable falls through to
  Blizzard's frame, so the worst case is the pre-1.82 look rather than a broken bar. **Do not gate on
  `cooldownInfo.hasAura`:** Blizzard's own viewer code never reads it, so it is evidence of nothing,
  and gating on it is the likely reason the first in-game test drew every buff on Blizzard's frames.
  Discovery keeps a buff that duplicates an Essential/Utility entry (by spell or name) out of the
  registry; those still get slots, through `DiscoverCooldowns`' second return (`buffExtras`), or they
  stay Blizzard frames in a row of ours — that was the second test's "some work, some don't". Only
  `cooldown`/`utility` are the cooldown side of that divide: `buffbar` was too until 1.76 (a
  `~= "buff"` test written before bars were split out), which dropped any buff icon sharing a name
  with a tracked bar. `/sq cdmnative` lists every Blizzard buff item not drawn by us, by name.
- **"Show While Active" (1.86) puts an ENGINE-DRAWN OVERLAY on an Essential/Utility icon**
  (`Native:SyncActiveOverlays` in `Squizzumables_CDMAuras.lua`, `groupData.showActiveBuff`, off by
  default). While the ability's own buff is on the player, a one-slot `HELPFUL` AuraContainer
  bound to `"player"` — `includeSpellIDs` = the entry's aura IDs — draws the aura's icon, swipe and
  countdown C-side over the proxy, and the engine shows the button only while the buff is up. The
  proxy keeps drawing its real cooldown underneath the whole time, so when the overlay goes there is
  nothing to switch back: the cooldown is simply what is left.

  Two earlier attempts are worth not repeating. Looking the aura up (the Tracked Buffs twin's
  `auraInstanceID`, then `GetPlayerAuraBySpellID`) cannot work in combat — the instance id is secret
  and the lookup answers nothing. Mirroring Blizzard's own cooldown item, which *does* draw this
  natively (`CooldownViewerCooldownItemMixin:CheckCacheCooldownValuesFromAura` gives a self buff
  precedence over the spell's cooldown until it is gone), fails on the aspect rule above. Handing
  the slot to the engine is the only route, and it is what EllesmereUI does for the same problem —
  read `EllesmereUICdmFakeActive.lua` ("engine-slot driver") before changing any of it.

  Gated on `entry.selfAura` at BUILD time as well as display time, because Blizzard would just as
  happily draw a TARGET aura's duration there — Lay on Hands with Empyreal Ward talented, which is
  exactly the regression V1.81 removed this behaviour for. The "is it running" signal for the glow
  and the un-greying is **`cooldownUseAuraDisplayTime`** on Blizzard's item frame: it is assigned
  from plain `true`/`false` literals rather than derived from the aura, so unlike everything else
  there it is never secret and stays readable in combat. `_sqActiveNow` caches it per proxy.

  The overlay glow is a THIRD glow host (`proxy.ActiveGlow`, beside `GlowFrame` and `ProcGlow`):
  `ActionButtonSpellAlertManager` keys by frame, and this one is held for a whole buff duration so
  it overlaps the other two routinely. Passing `anchorTo` to `ns.Glow.Show`/`Set` forces the
  self-drawn halo tier, and `sqGlowColor` (`groupData.activeGlowColor`, default teal) keeps it from
  looking like the proc glow — which is the entire point of it being separate.

  **`selfAura` is NOT consulted for an equip-slot entry** (1.87). A trinket has no spell to carry
  that flag, so `false` there says nothing about where its buff lands, and Blizzard does not consult
  it either — `CooldownViewerItemDataMixin:GetAuraData` scans `player` then `target` regardless.
  Honouring it kept trinkets out of this display entirely. `ShowActiveAllowed` is the one gate.
- **EQUIP-SLOT ENTRIES (trinkets) ARE NOT SPELLS, AND THE SLOT WINS** (1.87, four bugs in a row).
  Everything cooldown-shaped in `Squizzumables_CDM.lua` used to branch on `not proxy.spellID` to
  mean "this is an item". That is wrong and every symptom points elsewhere:
  - **A trinket entry can carry BOTH `spellID` and `equipSlot`.** The spell is its use effect, which
    has no cooldown of its own, so the spell path answered "ready" forever: no swipe, never greyed
    out, while Blizzard's own icon was perfect. Blizzard's `ShouldDisplaySpellCooldown` tests
    `isOnGCD and self:GetEquipSlot()`, which only makes sense if both are set. `EquipSlotCooldown`
    is now the first test in `UpdateProxyCooldown` and in the desaturation pass.
  - **Item cooldowns stay READABLE in combat.** `GetInventoryItemCooldown`/`C_Item.GetItemCooldown`
    carry no secret-return flag in the generated docs, unlike `GetSpellCooldown`
    (`SecretWhenCooldownsRestricted`). Don't assume the spell rules apply.
  - **Nothing fires when an item cooldown ENDS.** `BAG_UPDATE_COOLDOWN` fires as it starts. The
    swipe runs out on its own while the icon stays greyed until some unrelated refresh, so
    `UpdateProxyCooldown` schedules one `C_Timer` per end time.
  - **The Essential entry may not know its own buff.** Blizzard fills `linkedSpellIDs` on the
    TRACKED equip-slot entry (the buff bar's) — *"only doing linked spells for now because that's
    what items like trinkets will always use"*. Discovery therefore merges every buff entry's aura
    IDs on the same slot, plus `C_Item.GetItemSpell` of the equipped item, into the cooldown entry's
    `auraIDs`. (The reported trinket, Vile Vial of Volatile Venom, turned out to use one ID for
    both, so this was belt and braces — but the asymmetry is real in Blizzard's source.)
  - **`ApplyUsableTint` skips them**: `IsSpellUsable` on a use effect answers for the spell.
  `/sq cdmnative` has an "Equip-slot entries" section listing slot, type, spellID, `selfAura`,
  aura IDs and the running state, plus a "Show While Active overlays" section. Read it first.
- When adding new features that touch frames, action buttons, or secure state, check
  `InCombatLockdown()` and queue mutations rather than assuming they'll succeed mid-combat.

**Protected calls fail silently, differently per player, and mostly in M+.** Both 1.64 bugs were
this, reported by a user and not reproducible locally, because whether an execution path is
tainted depends on what else has run first. Three things learned the hard way:

- **`HasRestrictions = true` in the API docs means *protected*.** `C_UnitAuras.AddAuraSound`
  carries it. Calling it from a chain that began at the chat edit box — typing `/squizz`, which
  runs `CreateOptionsPanel` → `RefreshJustForKelTab` → the registration — trips
  `ADDON_ACTION_BLOCKED`. The fix is a `C_Timer.After(0)`, which runs with none of that lineage.
  Check that flag before building on any new API.

- **`HasRestrictions` says nothing about taint SPREAD, and no absence of it makes a call safe.**
  Two different mechanisms, and conflating them cost 1.70 through 1.72. The flag governs whether a
  *protected call is refused*. Taint spread is separate and happens by *execution*: call any
  Blizzard Lua function and it runs on your stack, so every table it writes is tainted by you from
  then on, permanently, with no error at the time and nothing in any traceback pointing at you.

  1.70 called `viewer:GetCooldownIDs()` to read the player's Cooldown Manager filter. That runs
  `CooldownViewerSettings`' data provider, which calls `CheckBuildDisplayData()` and rebuilds
  `displayData` — the Cooldown Manager's spine — while tainted. Every Blizzard path that later read
  it then ran tainted too. One Mythic+ session produced thousands of errors inside Blizzard's own
  `CheckAuraAddedAlertTriggers`, `RefreshTotemData`, `GetUnitAuras`, `CacheChargeValues` and
  `ShouldDisplaySpellCooldown`, all blamed on this addon, none with any of our frames in the stack.
  It survived reloads because we re-tainted within seconds of login.

  Four rules fall out, and the first three were violated:
  - **Prefer the `C_` API to a frame method.** `C_CooldownViewer.GetCooldownViewerCategorySet` is
    a C call and taints nothing; `viewer:GetCooldownIDs()` is Lua and taints everything it touches.
    Reading a Blizzard table field directly is likewise free — an accessor that only does
    `return self.x` is a taint risk for no benefit, so read `x`.
  - **A `CallbackRegistry` runs every handler for one event in a single call chain.** Registering
    on `EventRegistry` for an event Blizzard also listens to means our handler taints the
    execution and *Blizzard's* handlers for the same event then run tainted. 1.70 registered on
    `CooldownViewerSettings.OnDataChanged` — twice. Note this is **not** true of
    `hooksecurefunc`, which saves and restores taint around the hook; that is why the item-frame
    hooks in `Squizzumables_CDM.lua` measure clean. Safe mechanism, unsafe mechanism, and they
    look alike.
  - **Reading the source cannot answer this, so measure.** Gethe gives signatures and behaviour and
    was right about both; taint is a runtime property documented nowhere. `issecurevariable(tbl,
    key)` returns `isSecure, taintingAddon` and settles it in one run — that is what
    `/sq cdmtaint` (`cdmModule:PrintTaintDiagnostics`) exists for. Run it after a reload *and*
    after some play; the first report from it was clean because the taint took seconds to
    re-establish. Note the diagnostic must itself read only plain fields, or it causes what it
    measures.
  - **When a Blizzard Lua call is the only way to compute something, look for where Blizzard
    already computed it.** Blizzard's own code runs on a clean stack and leaves results lying on
    frames as plain fields, and reading those costs nothing. This is what makes the Cooldown
    Manager filter obtainable at all: `CooldownViewerMixin:RefreshLayout` calls `GetCooldownIDs()`
    itself, acquires one pooled item frame per entry, sets `itemFrame.layoutIndex = i`, and
    `RefreshData` then writes each frame's `cooldownID`. So `cooldownID` + `layoutIndex` across
    `viewer.itemFramePool:EnumerateActive()` **is** the filtered, ordered list — membership, order
    and equip-slot entries included — for two plain field reads. `BlizzardFilteredIDs` in
    `Squizzumables_CDM.lua` does exactly that, and the long note above it carries the three
    details that make it correct: hidden-but-acquired frames are *not* released (so enumerate the
    pool, never the shown children), `GetItemCount` pads to a minimum of 2 (surplus frames get
    `ClearCooldownID`, so test `cooldownID` rather than trusting `layoutIndex` to be dense), and
    the pool is lazy (empty means "not built yet", not "everything is hidden").

  The wrong turn worth knowing: the comment justifying the 1.70 call cited the missing
  `HasRestrictions` flag as prior verification, and a later paragraph called the taint risk "real
  but unevidenced". It was unevidenced because nobody had measured. **An absence of evidence got
  written down as reassurance**, and then survived three rounds of debugging as settled fact.

  The second wrong turn: on finding the cause, 1.73 initially **deleted the feature** rather than
  re-implementing it, even though the removal note itself said reading the pool was the way to do
  it. "This mechanism is unsafe" is not "this feature is impossible" — separate the two before
  throwing work away. EllesmereUI's CDM (`EllesmereUICooldownManager`, current on 12.1) calls
  `GetCooldownIDs` zero times and gets perfect filtering, which is what prompted the user to ask
  why we could not.
- **`C_Timer.After(0)` clears call-lineage taint, not combat lockdown.** The timer still fires in
  combat, so a protected call inside it is still refused — which is how `AddAuraSound` kept
  throwing `ADDON_ACTION_BLOCKED` from inside the deferral that was supposed to fix it (1.66).
  Protected work triggered by a settings change must *also* be queued when `InCombatLockdown()`
  and flushed on `PLAYER_REGEN_ENABLED`, the pattern the CDM module already uses
  (`BH:FlushQueuedAuraSoundRegistrations`).
- **A `pcall` around a protected call hides the failure and makes it look cosmetic.** It was not:
  the unregister ran, the re-register was blocked, and every buff sound stayed off until relog.
  If a `pcall` wraps something protected, make the failure *visible* in the UI rather than
  swallowing it. Note the `pcall` does not even catch it: a refusal raises `ADDON_ACTION_BLOCKED`,
  which is a client event and not a Lua error, so the `pcall` returns `ok == true` and only the
  missing return value tells you anything.

- **Neither guard is sufficient. Make the operation recoverable instead.** 1.67 took an
  `ADDON_ACTION_BLOCKED` on `AddAuraSound` from inside the `C_Timer.After(0)` deferral, **out of
  combat** — the traceback ran through `RunRegistration` past its `InCombatLockdown()` check, so
  both the lineage fix (1.63) and the combat-queue fix (1.66) were in place and working, and the
  call was refused anyway. Reported from LFR, with combat, mid-fight group churn and Blizzard's
  vote-kick popups all active. No root cause was ever established, and chasing one is what burned
  1.64.

  What made it damaging was the sequencing, not the refusal: `ApplyAuraSoundRegistrations` tears
  every registration down before rebuilding, so a refused rebuild left the player with **no buff
  sounds until relog**. The fix is a bounded retry (5 attempts, 3s apart) so a transient refusal
  recovers on its own, plus `BH.auraSoundRefusal` and `/sq buffsounds` to make it visible.

  Generalise this: for anything protected that runs on a tear-down-then-rebuild shape, assume the
  rebuild half can be refused for reasons you will not be able to explain, and make it retry.
  **The traceback cannot tell you who asked for the work** — the stack ends at the `C_Timer`
  closure — which is why the call sites now pass a trigger label that `/sq buffsounds` prints.
- **A `SecureActionButtonTemplate` is the fix for taint, not a victim of it. Do not "simplify" one
  away.** 1.64 replaced the dungeon callouts' secure macro button with a plain Button calling
  `SendChatMessage`, on the reasoning that removing the secure button removed the protected
  surface. Exactly backwards, and it shipped a regression: `SendChatMessage` carries
  `HasRestrictions` too (plus `RestrictedForMacroChatMessages`), and from a plain `OnClick` in a
  key it was refused — `ADDON_ACTION_BLOCKED` on a *real mouse click*, which normally permits a
  protected call. Reverted in 1.65.

  **Being blocked on a hardware click is the diagnostic**: it means the execution path is tainted,
  and a secure button is the sanctioned way to act from a tainted addon. Reach for one when an
  action is refused, do not remove one. Blizzard does block addon-initiated `SAY`/`YELL` inside
  instances, which is a separate and real restriction, and why callouts no longer offer them.

  **Resolved (2026-08-24): it was another addon.** Callout buttons doing nothing in M+ on one
  player's client was **GBankManager** tainting the game's chat-send chain, fixed by that player
  removing it. Nothing in this addon was at fault. Their BugGrabber stack read `SecureTemplates ->
  RunMacroText -> SendText -> SendChatMessage -> blocked`, attributed to GBankManager — our
  callout button's exact path. The button fired, the macro ran, the chat send at the end was
  refused, and *every* addon's secure chat macro was broken on that client.

  **Read the full traceback before theorising: taint blame names the addon that poisoned the
  path, not the one walking down it.** This is also why 1.64 achieved nothing — it swapped the
  secure macro for a direct `SendChatMessage`, but `SendChatMessage` was the poisoned endpoint, so
  both routes ended at the same blocked call while breaking clients that had been working.

  A `/sq taint` diagnostic written to chase this found nothing and was removed in 1.66. It ran
  `issecurevariable` over variables the addon *owns*, which all report "tainted by Squizzumables"
  — taint marks ownership, not corruption. If this is ever needed again, check the **protected
  globals in the path** (`SendChatMessage`, `RunMacroText`) instead; that names the foreign addon
  in one line. `/console taintLog 1` was a dead end: the CVar exists but writes nothing without a
  full client restart.

**Secret aura values (client 12.1.0+)**: as of 12.1.0, `C_UnitAuras.GetAuraDataByIndex` **throws**
a taint error ("Auras cannot be accessed when secret") instead of returning `nil` when auras are
secret — which happens in combat, encounters, M+, and PvP, i.e. exactly when these reminders most
need to work. Worse, the fields on a successfully-returned aura table can *themselves* be secret:
assigning/storing/passing one is fine, but *comparing* it (`==`, `<`, `>`) or doing arithmetic on
it (`-`, `+`) throws — `attempt to compare field 'spellId' (a secret number value, while execution
tainted by 'Squizzumables')`. That was a live user crash on retail (v1.58, `UnitHasBuff`'s
`auraData.spellId == id` fallback scan).

**The secret probe must come FIRST — before *any* other test on the value.** It is not only `==`,
`<`, `>` and arithmetic that throw. **A bare truthiness test or a `~= nil` comparison on a secret
is a hard error too**, so this is wrong:

    if ok and active ~= nil and not BH.Secrets.IsSecret(active) then   -- throws on a secret
    active = gotState and state or false                              -- throws on a secret

and this is right:

    if ok and not BH.Secrets.IsSecret(active) and active ~= nil then

Both of those wrong forms were live in `Squizzumables_CDM.lua`, in `ScanBlizzardBuffState` and
`CooldownAuraActive` — the guard threw in exactly the case it was written to handle, taking the
whole buff scan down with it, which is why tracked buffs only appeared once combat ended.
`type(v)` is safe to call first; nothing else is. Confirmed against EllesmereUI, whose code
carries the same rule as a comment: *"Secret probes come FIRST everywhere: even a boolean or
`~= nil` test on a secret is a hard error."*

**Widget setters take secrets natively — pass them through instead of resolving them.**
`FontString:SetText`, `StatusBar:SetValue` and the `Cooldown` setters all accept a secret value
without complaint. The `Safe*` accessors return `nil` for a secret, which is correct when the
value is about to be *compared*, and wrong when it is only being handed to a widget: that turns a
displayable value into a blank. Resolve for logic, pass through for display.

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

⚠ **Do NOT sanitise a value you only need to pass along.** The `Safe*` accessors return `nil` for an
unreadable value *by design* — that is what makes the result safe to compare — so laundering a
secret you were only ever going to hand to a widget setter destroys it instead of protecting it.
A secret survives `SetText`, `SetValue`, `SetMinMaxValues` and `SetTexture` untouched, because the
widget consumes it C-side and it never enters Lua.

The tell is a value that renders as nothing while everything around it works. A mirrored buff bar's
fill animated correctly while its countdown stayed permanently blank, because the text went through
`SafeString` first (user report 2026-09-17). The fix is to go from getter to setter **in one
expression** — `dest:SetText(src:GetText())`, no intermediate local, nothing to inspect — which is
what `MirrorBlizzardBarText` does and why it does it that way.

So the rule splits on what you intend to do with the value: **comparing, measuring or slicing it →
`Safe*` accessor. Forwarding it to a widget → raw, in one expression.** Note that string operations
are the same hazard class as arithmetic: `#s`, `s:sub()` and even `s ~= ""` all throw on a secret
string, which is why the CDM text builders track presence with plain booleans from nil-checks and
only ever concatenate.

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

**Nameplate purge glow — BUILT BUT DISABLED, NOT SHIPPED.** The `.toc` line is commented out so
the module never loads, and the Nameplates options tab is unwired; the file, its settings defaults
and its diagnostics all stay on disk for the revisit. It was pulled from 1.78 because the feature
could not be verified: on the test target the row stayed empty under every filter, **and Plater's
own purge display failed identically on that same buff**, so the blocker is that the client does
not flag it dispellable rather than anything in this code. Everything below is the research, and it
is correct as far as it was taken — the filter string is the same one EllesmereUI ships. To revive
it: uncomment the `.toc` line, restore the tab button/frame/pages entry in `CreateOptionsPanel`,
and re-verify against a target whose buff Plater's purge highlight actually fires on.

What it does (`Squizzumables_Nameplates.lua`, `BH.Nameplates`, `npPurge*` settings, off by
default): a row of the enemy's purgeable buffs per nameplate, through the same AuraContainer API as
the native CDM buffs. **The group is the filter, never the aura.** Whether a specific aura is
purgeable is aura data, and enemy aura data is secret in instanced content — so the narrowing is
declared to the client and every button the group shows is purgeable by construction; the glow
belongs to the group. The narrowing is the filter string `HELPFUL|INCLUDE_NAME_PLATE_ONLY|DISPELLABLE`
and **no candidate filter at all**.

**That is EllesmereUI's `BuffFilterGlow` exactly, and its `BuffCand` returns nil whenever the
DISPELLABLE token exists** — read `EllesmereUINameplates/EUI_Nameplates_AuraContainers.lua` before
touching this, it is the same feature solved on the same client build and its comments record the
same findings independently. **Use no candidate filter here.** Every candidate filter reads a field
the client redacts for an enemy's auras, which is why `isStealable`, `includeDispelTypes = Magic`
and `includeDispelTypes = Enrage` all matched nothing on a live target. The last cannot work in any
case: **an enrage carries no `dispelName`**, so an include test rejects it and only an exclude test
keeps it — Plater's `includeDispelTypes["Enrage"] = true` notwithstanding.

Filter strings are built from `AuraUtil.AuraFilters` rather than written out (`NOT_CANCELABLE` was
removed in favour of a `!` prefix, and `IsValidFilterString` rejects unknown tokens). There is no
token that means "purgeable" as such: `DISPELLABLE` is the closest and the one both we and
EllesmereUI use, and the nearest other candidate, `IMPORTANT`, is the opposite case — helpful auras
shown on enemy nameplates *even when non-stealable*.

**Five narrowings were tried and every one matched nothing**, tested on a hunter with Tranquilizing
Shot available against an absorb shield that hunter could remove: `isStealable` (means
*Spellstealable*, so Magic-only), `DISPELLABLE`, `RAID_PLAYER_DISPELLABLE`, `includeDispelTypes =
{ Magic = true }` and `includeDispelTypes = { Enrage = true }`. A plain `HELPFUL` group on the same
target filled normally, so the container, the icons, the layout and the glow were never at fault.
**Plater's own purge display failed on that same buff too**, which is what finally identified the
cause as the client not flagging it rather than any addon's filter. The tell throughout was that
rows attached and showed, `initializeFrame` never errored, and the container stayed sized `1x1` —
nothing had been laid out, because nothing matched.

**Do not reach for a candidate filter to narrow enemy auras.** The mechanism is not inherently
blocked — `AuraContainerUtil.DoesAuraPassCandidateFilters` runs in *Blizzard's* untainted Lua,
where reading a secret is legal — but enemy aura data is redacted there in restricted content, so
the fields those filters read come back empty and the filter matches nothing. EllesmereUI records
the same finding independently and returns nil from `BuffCand` whenever `DISPELLABLE` exists.
Separately, the **spellID** filters are gated outright: `CanApplyIdentityCandidateFilters` drops
`includeSpellIDs`/`excludeSpellIDs` for a helpful aura on a unit the player cannot assist, so a
per-spell list is impossible here no matter what. Read
`Blizzard_AuraContainer/Blizzard_AuraContainerUtil.lua` before theorising about what a container
will and will not match.

**The process lesson, which cost most of the session: establish what the target aura actually is
before choosing a filter for it.** Three rounds of in-game testing went to filters picked from
guesses about the buff — stealable, then dispel-typed, then an enrage — each guess wrong, so each
test proved nothing. The client will answer directly: `SetDispelTypeText` and `AddDispelTypeTexture`
are filled in by the client from the assigned aura, reporting dispel type and stealable state on
auras we are never allowed to read ourselves. That is what the probe in `/sq nameplates test`
exists for, and it would have settled this in one pull. Pass an explicit `customDispelTextMap`
covering every key including `None` — without one the client writes an empty string for an aura
with no dispel type (`ApplyDispelTypeText` → `fontString:SetText("")`), which is indistinguishable
from the registration having failed.

Structure: one container per plate, held in `entries[plate]` — the host frame is **parented into
the plate, never anchored across into it from outside**, because anchoring into a restricted
nameplate region makes our own frame restricted and any later measurement fails with "Can't measure
restricted regions". The host resolves `plate.unitFrame` (Plater's documented attach point), then
`plate.UnitFrame`, then the bare plate, so it rides whatever nameplate addon is running. Containers
cannot be created in combat, so `Rebuild` only runs out of combat, and `plateUnits[plate]` tracks
the unit token from `NAME_PLATE_UNIT_ADDED`/`REMOVED` — `plate.namePlateUnitToken` reads nil.
Buttons are sized inside `initializeFrame` (the Co-Tank lesson), and a settings change rebuilds
rather than restyles, because a button may not be touched after creation.

**Blizzard's spell-alert glow cannot be used anywhere inside an aura button's subtree**: the button
carries secret aspects, so the alert template's `OnHide` handler is refused —
`Cannot assign script handler for 'onhide' (blocked by secret aspects)`, once per button, which is
what 15 of them looked like in 1.78 testing. `ns.Glow`'s `sqGlowSelfOnly` forces the self-drawn
tier (textures plus an animation group, no script handlers) and is the only glow legal there;
`sqGlowColor` gives that frame its own colour without dragging every other glow in the addon with
it. Both flags live in `UI/Glow.lua` and are inert unless a frame sets them, which is why they
stayed in when the feature was parked.

`/sq nameplates test` builds **three** rows on `UIParent` bound to your target — each a different
narrowing, stacked and labelled — and `testoff` removes them. It exists because "the filter matched
nothing" and "icons were built somewhere invisible" look identical in game: parented to the screen,
these rows have none of the nameplate's restrictions, so icons there with none on a plate indicts
the plate, and empty boxes indict the filter. Each row is built with the real initializer plus the
dispel-type probe. It queues itself if run in combat and builds at the next lull, because a
container cannot be created in combat while the mob only gains its buff once the fight is on —
that mismatch is why the first cut of this command was useless. `/sq nameplates` reports the rest.

**A CDM glow spills past its icon, so it competes with the neighbours.** `RaiseGlowFrame` keeps the
glow frames at MEDIUM with a frame level of 300, fixed with `SetFixedFrameStrata`/
`SetFixedFrameLevel` (a child otherwise follows its parent, and `PositionFreeIcon` re-asserts
MEDIUM on every free icon). The level beats an ordinary neighbour — SquizzFrames' resource bar
border sits at bar level + 4 — while higher strata still cover it. 1.77 used the HIGH strata
instead and that drew glows over the open world map, which is what MEDIUM-plus-level avoids.

**`PLAYER_SPECIALIZATION_CHANGED` fires for group members too** — its payload is a unit, and the
game sends it whenever a party or raid member's spec info arrives (someone joining, a roster
refresh). Both handlers registered it with plain `RegisterEvent` and never checked the unit, so
the CDM ran `ReleaseAll` for other people's specs; in combat Reconcile refuses to rebuild, and the
whole Cooldown Manager vanished for the rest of any fight in which the group changed (fixed 1.77).
Both handlers now require `unit == "player"`, and the CDM defers any teardown to
`PLAYER_REGEN_ENABLED`. The check is in the handlers rather than a `RegisterUnitEvent`, which is
unverified for this event — if it did not apply, your own spec change would stop arriving. More
generally: **nothing may tear the CDM down in combat**, because nothing can put it back until
combat ends.

**Sounds: bundled vs custom, and where the files live** (`Squizzumables.lua`, "LibSharedMedia-3.0
helper"). Bundled sounds are `SQ_BUNDLED_SOUNDS`, shipped in `Media\Sounds\` (OGG or MP3 — the
client plays both; `ChemicalX.mp3` is the author's own recording). **Only ship audio the project
owns or may redistribute**: anything in that list is in the CurseForge zip.

Custom (user) sounds live in **`Interface\AddOns\SquizzumablesMedia\Sounds\`** since 1.89 — a sibling
folder with no `.toc`, so it is not an addon and no updater installed it, which is the point: an
addon update REPLACES `Squizzumables\`, and custom files kept in `Media\Sounds\` were deleted on
every update. An entry carries `dir = "media"`; one without it predates the move, still resolves
to the old folder (`CustomSoundPath`), and is flagged "(old folder)" in the list.

Addons get no file-exists or directory API, so the Sounds tab finds a typed file by PLAYING
candidates (`FindCustomSound`: new folder then old, `.ogg` then `.mp3`, any folder part stripped)
until `PlaySoundFile` reports `willPlay`. **Confirmed in game (1.89): `willPlay` is false for a
missing file, and a file copied in while the game runs is found after `/reload` — no restart.**
With game sound switched off `willPlay` is false for everything, so that case is checked first
(`Sound_EnableAllSound`) and reported rather than read as "missing". The old Add handler appended
`.ogg` to any other name, which is what had silently blocked MP3.

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

**Blizzard's two buff categories are drawn differently, and so are ours.** Category 2
(`BuffIconCooldownViewer`) is square icons and feeds the `Buffs` group; category 3
(`BuffBarCooldownViewer`) is tracked *bars* — a fill, a spell name and a timer — and feeds
`Buff Bars`, a separate built-in group added in 1.74. Both were folded into `Buffs` before that
and laid out on the icon grid, which sized each bar down to `iconSize` square and made it
unreadable. Two things keep them apart and both are needed: `DISCOVER_CATEGORIES` gives category 3
the `viewerType` `"buffbar"`, and `BORROW_VIEWERS` says which Blizzard viewer each group borrows
from — without the second, the layout pass walks *both* buff viewers for *any* borrowing group and
each group shows everything. A custom group falls back to both viewers on purpose, since the
player assigned to it explicitly. `groupData.isBarGroup` selects the stacking layout and swaps the
Icon Size / Per Row sliders for Bar Width / Bar Height; it is re-stamped by `EnsureBuiltinGroups`
on every reconcile because profiles predating 1.74 do not have it.

**The CDM group frames are a public anchor API.** `Squizzumables_GetCDMGroupFrame(name)` (and
`BH.cdm:GetGroupFrame(name)`) returns a cooldown group's container — `"Essential"`, `"Utility"`,
`"Buffs"`, `"Buff Bars"`, or a custom group's name. Other addons anchor to these, so **the frames are created
once per session and reused**, never rebuilt on `ReleaseAll` or a spec change: WoW cannot destroy
a frame, so a second `CreateFrame` under the same name leaves the first alive and orphaned and
anything anchored to it silently stops tracking. `containerCache` in `Squizzumables_CDM.lua` is
what guarantees that; do not clear it. The `SQZ_CDMGroup_<name>` globals still exist but the
accessor is the supported contract. `Squizzumables_GetCDMGroupNames()` lists the names that
currently resolve (SquizzFrames builds its Attach To lists from it).

**The other direction works too: a group can anchor to ANOTHER addon's frame.** `groupData.anchorTo`
is a group name or `"frame:<GlobalName>"`, resolved through `_G` in `PositionGroup`.
`cdmModule.EXTERNAL_ANCHORS` is only what the dropdown offers (SquizzFrames' frames by default;
`Squizzumables_RegisterAnchorTarget(name, label)` adds more), and the options' frame-name box takes
anything else. ⚠ Two addons can each hold half of a loop the other cannot see (SquizzFrames' cast
bar on Utility, Utility on that cast bar), and WoW raises a hard error on the cycle. So both sides
walk the TARGET's live anchor chain before anchoring — `cdmModule.AnchorDependsOn` here,
`CastBar.DependsOn` in SquizzFrames — and whichever is placed second backs off. A missing frame
(the other addon builds late) retries `PositionGroup` every 2s, ten times.

Note this is *not* a mirror of Blizzard's viewers. The module proxies rather than reparenting, so
`EssentialCooldownViewer` is a separate frame at its own position — and with "Hide Blizzard's
Cooldown Manager" on it is parked at -10000, which would drag anything anchored to it offscreen.

**CDM icon shapes** (`ApplyIconShape` in `Squizzumables_CDM.lua`): each shape is one
white-on-transparent PNG in `Media/Shapes/`, generated by `.claude/make-shapes.ps1` (run it with
`-SheetPath` for a preview), and that one image is used three ways — the icon's mask, the
cooldown's swipe texture, and the border, drawn as the same shape behind the icon grown by the
border thickness and tinted. So a new shape is a path in the script plus one line in
`ICON_SHAPES`; it must fill its square edge to edge and be centred or the rim comes out lopsided.
Shapes were applied to proxy icons only until 1.85, on the belief that Blizzard's own frames could
not be masked. **That was wrong, and it cost a long session.** It is a limit of what this addon had
implemented, not of the API: `AddMaskTexture`/`RemoveMaskTexture` work perfectly well on a
borrowed CDM item frame's icon, and `SetSwipeTexture`/`SetUseCircularEdge` on its cooldown.
EllesmereUI has masked Blizzard's CDM frames — buff-viewer frames included — the whole time
(`EllesmereUICdmHooks.lua`, `_AC.SetMask` and `ApplyExtra`; it takes `frame.Icon` and
`frame.Cooldown` straight off Blizzard's item). Our own `ApplyKeybindText` already writes regions
onto borrowed children for the same reason: these are ordinary region writes, not protected calls.

The practical consequence, which is what the user actually saw: a group mixing our cells with
borrowed Blizzard frames drew some icons in the chosen shape and some square, because only one of
the two renderers carried the shape. Style whatever frame is in the slot, rather than only the
frames we own — that is how EllesmereUI avoids the split entirely, and how their "Always Show
Buffs" placeholders are built to mirror a real icon so one styling pass covers both.

Masking a pooled Blizzard frame does need unwinding: it must be un-masked when handed back, or the
shape leaks onto Blizzard's own bar. `ns.Shapes.SetMask(owner, nil, regions...)` is the off switch,
and it removes before it adds, so re-applying can never stack two masks.

Each shape also has glow art, because Blizzard's proc glow (`ActionButtonSpellAlertManager`) is a
pair of square flipbooks with no mask or shape option. `<name>_proc_start.png` and
`<name>_proc_loop.png` are 30-frame sheets on Blizzard's own 6x5 grid (84px frames on 512), and
`ApplyAlertArt` in `UI/Glow.lua` swaps them into Blizzard's alert after every `ShowAlert` —
Blizzard still owns showing, timing and the burst-to-loop hand-over. This is Masque's approach
(`Masque/Core/Regions/SpellAlert.lua`). It is safe because Blizzard creates the alert frame once
per button and never pools it, so art set on our `ProcGlow` frame cannot leak onto the real
action bars. `<name>_glow.png` is a static halo for the self-drawn fallback tier. Shapes are set
per frame with `Glow.SetShape` from `ApplyIconShape`. The generator's `GlowScale` and sheet
constants must match `SHAPED_SCALE` and `SHEET_*` in Glow.lua.

**Square has its own glow art too, since 1.88 — `Shapes.SQUARE_GLOW`, deliberately NOT in
`Shapes.GLOW`.** Blizzard's art is a fixed gold that cannot be tinted, so while square fell back to
it, square was the one shape whose proc colour could not be chosen; that is what
`groupData.procGlowColor` (per group, default Blizzard's gold) needed. It stays out of the `GLOW`
table because the reminder buttons index that table directly and their square glow is meant to stay
Blizzard's — only `ApplyIconShape` asks for the square art, by name. Square's `square.png` fill is
generated but unused: square needs no mask, swipe or border image, which is what square *means*
here. **A glow is tinted when it STARTS**, so a colour change must restart a running one — and the
restart has to happen *before* `SyncProcGlow`, which lights it straight back up if it should still
be lit. After it, the icon stays dark until the next proc.

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

**A TEMPORARY WEAPON ENCHANT FIRES NEITHER OF THE OBVIOUS EVENTS.** Rogue poisons, weapon oils
and sharpening stones put no aura on the player (so `UNIT_AURA` never fires) and consume nothing
from bags once applied (so `BAG_UPDATE_DELAYED` never fires either). `UNIT_INVENTORY_CHANGED` is
the one that does, and it was registered nowhere until 1.84 — so those reminders cleared only
when some unrelated event wandered past. In a group that was usually another member's
`UNIT_AURA`, which is exactly why the bug read as "instant in a raid, seconds-long solo" and hid
for so long. Rogue poisons are also *spells*, so the player's own `UNIT_SPELLCAST_SUCCEEDED` is
the earliest signal of all and is routed to the same debounced `ScheduleUpdateButtons`.

The lesson generalises: before assuming a reminder's *detection* is broken, check that something
actually tells it to look. The detection half here (`HasFlaskBuff`, the `GetWeaponEnchantInfo`
readers, the bag cache) was unchanged since the 1.59 baseline and was never at fault.

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

**Know the real limit of this feature before promising anything from it.** Aura secrecy is
per-spell, not a global combat switch, and Blizzard keeps only a *very short allowlist* of auras
readable in combat. The lust debuffs (`LUST_DEBUFF_IDS`) are on it, which is why the built-in
alert works in a real pull. Almost nothing else is: measured on retail 2026-08-21, Tyr's
Deliverance (200654) reported `ShouldSpellAuraBeSecret` false out of combat and **true** the
moment combat started, with `GetUnitAuraBySpellID` returning nil while the buff was visibly up —
in the open world, no instance required.

So a user-added Kelert on an arbitrary buff cannot *see* its aura in combat. Don't debug that as
if it were a wiring problem — `/sq auras <spellID>`, run twice with the aura up (once out of
combat, once in), settles it in one step. Note the predicate is context-dependent, so it cannot
be usefully checked when the player configures the alert: out of combat it answers false for
spells that are secret in combat.

**The sound half of that is solved; the image half is not.** `C_UnitAuras.AddAuraSound(trigger,
sound)` (12.1, and the replacement for the now-removed `AddPrivateAuraAppliedSound`) inverts who
does the watching: hand the client a spellID and a **file path** up front, and it plays the sound
on application. No value crosses into addon code, so secrecy has nothing to withhold. Verified on
retail against Tyr's Deliverance — secret, unreadable, sound still played in combat, from the
addon's own `Media\Sounds\` file. `Enum.UnitAuraSoundTrigger` is `Added = 0`,
`ApplicationsIncreased = 1`, `Removed = 2`; `RemoveAuraSound(auraSoundID)` unregisters.

`BH:RefreshAuraSoundRegistrations` (in `Squizzumables_SpellAlerts.lua`) rebuilds every
registration wholesale from settings, and is called at login (after the LSM registration, which is
what resolves a media name to a path), from `BH:RefreshJustForKelTab` (every edit routes through
it), and on profile switch. An alert qualifies only with a single spell ID, one fixed sound, no
random pool and no sound loop — the reasons are in the comment there, and they are the API's
constraints rather than preferences. The built-in lust alert is excluded automatically because it
has no `trigger.spellID`.

**What it does not buy is the image.** The client plays a sound and reports nothing back, so a
delegated alert has no callback and cannot show the full-screen texture. Sound survives combat;
the picture still needs a readable aura. `Removed = 2` is also worth remembering as the one
trustworthy source of aura-*removal* alerts — the absence-guard problem above exists because
unreadable and absent look identical to us, and they do not look identical to the client.

**Consumable data churn**: item/spell IDs in `Squizzumables_Config.lua` (`consumables.food`,
`.flask`, `.oil`, and `classBuffs`) are expansion/season-specific and go stale when Blizzard
rotates seasonal items — check `CHANGELOG-ARCHIVE.txt` for the most recent update pattern before
adding new IDs.
