# Squizzumables Modernization Roadmap

Written 2026-08-20, against v1.59. Target for the first round of work: **v1.60**.

This document is the output of a full read of `Squizzumables.lua` (9,406 lines),
`Squizzumables_CDM.lua` (2,291), `Squizzumables_SpellAlerts.lua` (730) and
`Squizzumables_Config.lua` (146), compared against two mature reference addons in the
same problem domain that ship in this AddOns folder:

- **ClickableRaidBuffs** (`../ClickableRaidBuffs`) — Funki, v7.8.14. ~15k lines across 90
  files. Same core job as us: missing raid buffs, consumables, temporary enchants, clickable.
- **EllesmereUI** (`../EllesmereUI*`) — Ellesmere, v8.9.4. A 22-addon UI suite; relevant here
  for its options framework, profile system and settings UX.

Line references below are to the files as they stood at v1.59 and will drift as work lands.

---

## Table of contents

1. [Part 1 — Confirmed bugs](#part-1--confirmed-bugs)
2. [Part 2 — Structural cleanup](#part-2--structural-cleanup)
3. [Part 3 — Settings UI](#part-3--settings-ui)
4. [Part 4 — Modernization: the secrets API](#part-4--modernization-the-secrets-api)
5. [Part 5 — Missing features](#part-5--missing-features)
6. [Part 6 — Release plan](#part-6--release-plan)
7. [Appendix — Reference addon file map](#appendix--reference-addon-file-map)

---

## Part 1 — Confirmed bugs

These are independent of any refactor and should land first.

### 1.1 `PROFILE_POSITION_KEYS` is missing five keys

`Squizzumables.lua:145` declares 13 position keys. `POSITION_PAIRS` (`:662`) declares 14
frames, and 16 distinct `*Position` keys exist in the saved-variables table.

Missing from `PROFILE_POSITION_KEYS`:

- `flaskReminderPosition`
- `oilReminderPosition`
- `healerCCReminderPosition`
- `calloutsFramePosition`
- `raidToolsPosition` (legacy; migrated away in `LoadMarkersPosition`, but still written)

`BH:SaveToProfile` (`:250`) and `BH:LoadFromProfile` (`:268`) both iterate only that list.
`LoadFromProfile` also nils keys that the incoming profile does not define — so the five
missing frames are neither saved to, restored from, nor cleared on a profile switch. They
silently retain the *previous* profile's anchor.

**Fix:** derive the list rather than maintaining a parallel one.

```lua
local PROFILE_POSITION_KEYS = { "framePosition", "calloutsFramePosition" }
for _, pair in ipairs(POSITION_PAIRS) do
    PROFILE_POSITION_KEYS[#PROFILE_POSITION_KEYS + 1] = pair[2]
end
```

Note `POSITION_PAIRS` is defined at `:662`, after `PROFILE_POSITION_KEYS` at `:145` — the
declaration needs to move, or the derivation needs to happen after both.

### 1.2 Profile popups call an incomplete set of position loaders

`StaticPopupDialogs["SQUIZZUMABLES_NEW_PROFILE"].OnAccept` (`:1637`) and
`["SQUIZZUMABLES_DELETE_PROFILE"].OnAccept` (`:1667`) each hand-call 9 loaders:

```
LoadFramePosition, LoadMarkersPosition, LoadPullReadyPosition,
LoadBeaconReminderPosition, LoadEarthShieldReminderPosition,
LoadRepairReminderPosition, LoadSymbioticReminderPosition,
LoadBresCounterPosition, LoadDeathTallyPosition
```

Never called: `LoadCoachWhistleReminderPosition`, `LoadPetReminderPosition`,
`LoadFoodReminderPosition`, `LoadFlaskReminderPosition`, `LoadOilReminderPosition`,
`LoadHealerCCReminderPosition`, `LoadKelAlertPosition`, `LoadCalloutsFramePosition`.

**Fix:** one `BH:LoadAllFramePositions()` that loops `POSITION_PAIRS` plus the two
one-offs, called from both popups and from `PLAYER_LOGIN`. This also removes ~45 lines of
`PLAYER_LOGIN` boilerplate (see §2.1).

### 1.3 Options-panel list rows leak frames permanently

WoW frames are never garbage collected. `SetParent(nil)` orphans them; it does not free them.

Three functions create fresh frames on every call and abandon the old ones:

| Function | Line | Frames per call |
|---|---|---|
| `BH:RefreshItemList` | `:4591` | ~50–150 (headers, drop zones, item rows, coach rows) |
| `BH:RefreshClassBuffList` | `:3609` | ~5–20 |
| `BH:RefreshCustomSoundsList` | `:3370` | 1 per custom sound |

`RefreshItemList` is called from `CreateOptionsPanel` (`:1288` and `:1608`), so every
`/sq config` after the first leaks a full set.

**Fix:** the same pooling pattern already used for the main buttons (`SQ_BUTTON_POOL`,
`CreateButton` at `:5032`). Keep the row tables, hide + recycle instead of re-creating.
Consider a small generic `BH.CreatePool(factory)` helper since three call sites want it.

### 1.4 Per-frame closure allocation in the button timer

`Squizzumables.lua:5163`:

```lua
btn:SetScript("OnUpdate", function(self, elapsed)
    local ok, remaining = pcall(function()          -- new closure every frame
        if not self.expirationTime or self.expirationTime == 0 then return nil end
        return self.expirationTime - GetTime()
    end)
```

This allocates one closure per button per frame — roughly 360/sec with six buttons up — and
runs a full `pcall` to format a string that only changes once a second.

**Fix:** two changes.

1. Throttle with an elapsed accumulator (0.1s is plenty for an `M:SS` readout).
2. Drop the `pcall` in favour of `issecretvalue` (see [Part 4](#part-4--modernization-the-secrets-api)) —
   check the field once, then do the arithmetic freely.

### 1.5 Empty `OnUpdate` handler

`Squizzumables.lua:9109`:

```lua
-- onupdate to update any countdowns
BH.frame:SetScript("OnUpdate", function(self, elapsed)
    -- update tooltips or text if needed later
end)
```

Runs every frame for the whole session and does nothing. Delete.

### 1.6 Bag scans stop at bag 4, missing the reagent bag

Nine hardcoded `for bag = 0, 4` loops:

`:4191` (`FindItemInBags`), `:4901` (`CountItemInBags`), `:7038`, `:7067`, `:7103` (inside
`UpdateButtons`), `:7757` (`UpdateFoodReminder`), `:7809` (`UpdateFlaskReminder`),
`:7878` (`UpdateOilReminder`), `:9174` (`/sq debug`).

**Fix:** `for bag = BACKPACK_CONTAINER, NUM_BAG_SLOTS + NUM_REAGENTBAG_SLOTS do`. Best done
as part of §2.3 (single cached bag snapshot) so there is one loop left to fix.

### 1.7 `IsSpellKnown` misses talent-granted and overridden spells

16 raw `IsSpellKnown` calls in `Squizzumables.lua` (`:6656`, `:6684`, `:6686`, `:6724`,
`:6733`, `:6735`, `:6807`, `:6821`, `:6854`, `:6959`, `:7095`, `:7412`, `:7417`, `:7482`,
`:7609`, `:7867`).

`IsSpellKnown` returns false for spells granted by talents and for base spells that a talent
has overridden. Two call sites already hedge (`:6684`, `:7412` add `or IsPlayerSpell(...)`),
the other 14 do not — so a reminder can silently never fire for a given talent build.

CRB's chain, `../ClickableRaidBuffs/Core/RaidBuffsScan.lua:37`:

```lua
local function PlayerKnowsSpell(id)
  if not id then return false end
  if C_SpellBook and C_SpellBook.IsSpellKnown then
    local ok = C_SpellBook.IsSpellKnown(id)
    if ok ~= nil then return ok end
  end
  if IsPlayerSpell and IsPlayerSpell(id) then return true end
  if IsSpellKnownOrOverridesKnown and IsSpellKnownOrOverridesKnown(id) then return true end
  if IsSpellKnown and IsSpellKnown(id) then return true end
  return false
end
```

**Fix:** add `BH.PlayerKnowsSpell` and replace all 16 call sites.

### 1.8 Combat-relevant reminders are hidden during combat

`PLAYER_REGEN_DISABLED` (`:8978`) explicitly hides Beacon, EarthShield, Repair, Symbiotic,
Food, Flask and Oil reminder frames. They are only re-evaluated from `BH:UpdateButtons`
(`:7362` calls `UpdateBeaconReminder`), which returns early on `InCombatLockdown()` (`:6502`).

Net effect: Beacon of Light / Beacon of Faith and Earth Shield reminders — the two that
matter most mid-pull — vanish the instant combat starts and do not return until it ends.

These are plain non-secure `Frame` objects (`:5711`, `:5738`). Only `BH.frame`, which parents
the `SecureActionButtonTemplate` buttons, actually has to hide in combat.

**Fix:** split reminder updates out of `UpdateButtons` into `BH:UpdateAllReminders()`, let
that run in combat, and stop hiding the plain frames on `PLAYER_REGEN_DISABLED`. Keep the
`EnableMouse(false)` treatment already used for the brez counter so they stay click-through.

---

## Part 2 — Structural cleanup

Ranked by lines removed per unit of risk.

### 2.1 The text-reminder subsystem: ~1,470 lines to ~250

Ten reminders — Beacon, EarthShield, Repair, Symbiotic, CoachWhistle, Pet, Food, Flask, Oil,
HealerCC — each duplicate the same four blocks:

| Block | Lines | Span |
|---|---|---|
| Frame + fontstring construction | 270 | `:5711`–`:5977` |
| `BH:UpdateXReminder()` | 526 | `:7381`–`:7907` |
| Options tab build (label / enable / scale / lock) | 576 | `:2794`–`:3370` |
| `BH:RefreshTextRemindersTab` if-chain | 104 | `:3744`–`:3848` |
| **Total** | **~1,476** | |

Plus 34 distinct `self.tr*` widget handles, 30 distinct `BH.settings.*Reminder*` keys, and
~45 lines of scale/position boilerplate in the `PLAYER_LOGIN` handler (`:8899`–`:8940`).

Every construction detail is data. Only the "should this show right now" predicate is bespoke.

```lua
BH.REMINDERS = {
    {
        key       = "beacon",
        label     = "Beacon Reminder (Holy Paladin)",  -- options tab header
        text      = "REMEMBER YOUR BEACON",
        color     = { 1, 0.82, 0 },
        size      = { 280, 50 },
        defaultY  = 200,
        class     = "PALADIN",
        spec      = 65,
        gates     = { "instance", "group", "alive" },
        shouldShow = function() ... end,               -- the only hand-written part
    },
    ...
}
```

Then:

- `CreateReminderFrame(def)` — replaces the 270 lines of construction, and registers the
  frame under `BH[def.key .. "ReminderFrame"]` so existing references keep working.
- `BH:UpdateReminder(def)` — runs the shared class/spec/gate checks, then `def.shouldShow`.
  Replaces the 526 lines.
- One loop in `BuildTextRemindersTab` — replaces the 576 lines.
- `RefreshTextRemindersTab` disappears entirely once the widget kit reads through
  `getValue` (see [Part 3](#part-3--settings-ui)).

The settings keys stay exactly as they are (`beaconReminderEnabled`, `beaconReminderScale`,
`beaconReminderLocked`, `beaconReminderPosition`) so no DB migration is needed — they are
already perfectly regular, derived from `key`.

**This is the single biggest win in the codebase and it is mechanical, low-risk work.**

### 2.2 `BH:UpdateButtons()` is 881 lines

`:6500`–`:7381`. It does, in one function body:

- pool recycling and preview-dummy cleanup
- class-buff evaluation branching for every class in `BH.classBuffs`
- weapon-imbue / weapon-enchant handling
- pet and Call Pet handling
- consumable bag scanning for food, flask, oil
- button layout and anchoring
- per-buff sound dispatch via `classBuffWasNeeded` transitions

The internal `-- ===` comment banners already mark the seams. Suggested split:

| New function | Responsibility |
|---|---|
| `CollectClassBuffButtons(out)` | append descriptors, no frame work |
| `CollectConsumableButtons(out)` | ditto |
| `CollectPetButtons(out)` | ditto |
| `LayoutButtons(list)` | positioning / anchoring only |
| `FireBuffSounds(list)` | `classBuffWasNeeded` edge detection |

Descriptors are plain tables; `CreateButton` (`:5032`) already takes 11 positional arguments
and would be much clearer taking one descriptor table instead.

### 2.3 Collapse nine ad-hoc bag loops into one cached snapshot

See §1.6 for the list. `UpdateButtons` can perform 30+ full 5-bag walks per invocation, and
it is invoked (0.2s debounce) on every `UNIT_AURA` — which is registered for *all* units
(`:8875`), so in a 20-man raid that is a continuous firehose.

CRB's approach: `../ClickableRaidBuffs/Core/BagScan.lua` scans once, into a cache, driven by
a `bagsDirty` flag set on `BAG_UPDATE_DELAYED` and consumed by the update bus
(`../ClickableRaidBuffs/Core/UpdateBus.lua`). Their bus additionally rate-limits bag and
roster scans independently (`bagRefreshSeconds` / `raidRefreshSeconds`, default 5s each) and
coalesces everything through a single armed `C_Timer.After`.

We do not need the full bus, but we do want:

- `BH.bagCache` — `{ [itemID] = { count = n, link = ..., quality = ... } }`
- rebuilt on `BAG_UPDATE_DELAYED` / `PLAYER_ENTERING_WORLD`, not on aura churn
- `FindItemInBags` / `CountItemInBags` become table lookups

### 2.4 Namespace hygiene

Currently global:

- `BH` — the addon namespace itself, a two-letter generic name (`Squizzumables.lua:8`)
- `CreateSQButton` (`:920`), `CreateSQSlider` (`:951`), `CreateSQCheckbox` (`:1022`),
  `CreateSQColorPicker` (`:1074`), `CreateSQDropdown` (`:1131`), `CreateSQDivider` (`:1269`)
- `_G.SQ_COLORS` (`:903`)

Also `local addonName = "Squizzumables"` (`:7`) is hardcoded where `...` provides it.

Both reference addons use the private vararg namespace, which is per-addon and invisible to
everyone else:

```lua
local addonName, ns = ...
```

**Fix:** `local addonName, ns = ...` in every file; `ns.BH = ns.BH or {}` (or just make `ns`
*be* the namespace). Move the six widget constructors onto `ns.UI`. Keep a single
`_G.Squizzumables = ns` if an external entry point is ever wanted.

Risk: `Squizzumables_CDM.lua` and `Squizzumables_SpellAlerts.lua` both do `local BH = BH` at
the top and rely on `_G.SQ_COLORS`. Both need updating in the same commit.

### 2.5 Split the single 9,406-line file

Proposed layout, load order explicit in the `.toc` as today:

```
Core/       Namespace.lua   Secrets.lua   Bags.lua   Events.lua
            Profiles.lua    Migration.lua
Data/       Consumables.lua ClassBuffs.lua Reminders.lua
Features/   Buttons.lua     Reminders.lua  RaidTools.lua  Callouts.lua
            DeathTally.lua  BattleRes.lua  Feast.lua      GuildInvite.lua
            SpellAlerts.lua CDM.lua
UI/         Theme.lua       Widgets.lua    Panel.lua
UI/Tabs/    Settings.lua    Items.lua      ClassBuffs.lua  RaidTools.lua
            Reminders.lua   Sounds.lua     Callouts.lua    Kelerts.lua
            CDM.lua         CDMSounds.lua
```

This should be its own release with nothing else in it — it touches every line and any bug
introduced alongside a behaviour change becomes very hard to bisect without git history.

### 2.6 Generic defaults merge and versioned migrations

`BH:LoadSettings` (`:489`) does:

- a shallow key fill from `BH.defaultSettings` (`:534`)
- one hand-written deep-merge, for `kelLustAlert` only (`:541`)
- a bespoke string-to-table migration for `feastAnnounceChannel` (`:549`)
- three ad-hoc boolean flags: `kelLustMigrated`, `kelLustMigrated2`, `kelLustMigrated3`

Any future nested default silently fails to backfill for existing users, which is exactly the
class of bug that produced `kelLustMigrated2` and `3`.

**Fix:**

```lua
local function ApplyDefaults(tbl, defaults)
    for k, v in pairs(defaults) do
        if type(v) == "table" then
            if type(tbl[k]) ~= "table" then tbl[k] = {} end
            ApplyDefaults(tbl[k], v)
        elseif tbl[k] == nil then
            tbl[k] = v
        end
    end
    return tbl
end
```

plus a single `SquizzumablesDB.dbVersion` integer and an ordered migration table:

```lua
local MIGRATIONS = {
    [2] = function(db) --[[ feastAnnounceChannel string -> table ]] end,
    [3] = function(db) --[[ kelLust defaults ]] end,
}
```

Ellesmere does exactly this in `../EllesmereUI/EllesmereUI_Migration.lua`, running before any
child addon initialises.

---

## Part 3 — Settings UI

### Current state

- 460x600 panel (`:1298`) with **10 tabs** that wrap onto two rows (`CreateTab` at `:1524`
  has explicit wrap logic because they do not fit)
- every tab hand-laid-out with `yOffset = yOffset - 34` arithmetic
- per-tab `RefreshXTab()` that must be manually kept in sync with 34+ stored widget handles
- `SwitchTab` (`:1506`) is 20 hand-written lines that must be edited to add a tab
- no tooltips, no disabled/dependent-option handling, no search

### What both reference addons do instead

**Declarative rows with get/set closures.** From
`../EllesmereUIOptions/EUI_QoL_BattleRes_Options.lua:157`:

```lua
row, h = W:DualRow(parent, y,
  { type="dropdown", text="Border Size",
    values=BORDER_VALUES, order=BORDER_ORDER,
    getValue=function() return Cfg("borderSize") or "thin" end,
    setValue=function(v) Set("borderSize", v); Refresh() end,
    disabled=function() return Cfg("visibility") == "NEVER" end,
    disabledTooltip="BattleRes Icon" },
  { type="slider", text="Icon Zoom", min=0, max=20, step=0.5,
    getValue=function() return Cfg("iconZoom") or 11 end,
    setValue=function(v) Set("iconZoom", v); Refresh() end })
y = y - h
```

Three consequences that map directly onto our pain points:

1. **The row returns its own height** (`h`), so no manual `yOffset` bookkeeping and no
   drift when a widget's size changes.
2. **`getValue` means the widget reads live state on refresh.** `EllesmereUI.RegisterWidgetRefresh(fn)`
   collects them; refresh becomes one loop. **`RefreshTextRemindersTab`, `RefreshSettingsTab`,
   `RefreshRaidToolsTab` and friends disappear**, along with all 34 `self.tr*` handles.
3. **`disabled=function()`** gives greyed-out dependent options for free — e.g. the scale
   slider greyed when its reminder is off. We currently have no dependency handling at all.

CRB has the layout-context flavour of the same idea in
`../ClickableRaidBuffs/Options/OptionElements.lua:346` — `beginFlow`, `beginGrid`,
`beginTriple`, each returning a `ctx` with `ctx:_place(cell)` that tracks `y` and resizes the
holder. `beginTriple` additionally reflows on `OnSizeChanged`, which is what makes their
panel resizable.

### Recommendations

**3.1 Bigger panel, sidebar nav instead of wrapped tabs.**
CRB uses 820x620 with `SetResizeBounds` (`../ClickableRaidBuffs/Options/Panel.lua:76`).
A left sidebar of categories with sub-items scales past 10 entries; a wrapping tab strip does
not, and our two-row tab bar is the visible symptom of that. This also gives room to merge
the "CDM" and hidden "CDM Sounds" tabs into one category with two pages.

**3.2 Fuzzy settings search.**
`../EllesmereUI/EllesmereUI_GlobalSearch.lua` is 922 lines but the core is ~80:

- `EllesmereUI._RegisterSearchEntry(label, tooltip, module, page, section, ...)` (`:23`),
  called by the row builder as each row is constructed
- `FuzzyScore(haystack, needle)` (`:64`) — substring match scores `10000 - index`, otherwise
  a subsequence walk rewarding consecutive runs, rejecting matches whose span exceeds
  `#needle + 8`
- a jump-to-result that switches page, restores any page-internal selector, and flashes the row

With 10 tabs and ~100 settings this is the highest-leverage UX addition available, and it
falls out almost free once rows are built through a common helper (3.0).

**3.3 One global Unlock Mode, replacing nine "Lock X" checkboxes.**
`../EllesmereUI/EUI_UnlockMode.lua`. A single toggle shows every draggable frame as a labelled
placeholder you can drag; exiting locks everything. This deletes nine checkboxes and nine
settings keys, and is strictly better than hunting for the right lock box in a scrolling tab.

We already have most of the machinery: `BH.previewMode` and `BH:RefreshAllReminderFrames`
(`:7907`) already force-show every enabled reminder for repositioning. Unlock Mode is that,
generalised to all frames and promoted out of the options panel.

**3.4 Profile import/export strings.**
CRB: `../ClickableRaidBuffs/Core/ProfileIO.lua` and `Core/CustomSpellIO.lua`.
Ellesmere ships LibDeflate for it (`../EllesmereUI/Libs/LibDeflate/`).
Serialize + deflate + base64 into a shareable string. For an addon with per-character and
per-spec profiles this is a frequently requested feature and it is self-contained.

**3.5 Per-widget tooltips.** We have essentially none. Both reference addons attach one to
every row, and Ellesmere's search index uses tooltip text as a secondary match field — so
this and 3.2 reinforce each other.

**3.6 In-game changelog popup on version bump.**
`../EllesmereUI/EllesmereUI_PatchNotesPopup.lua`. We already maintain a detailed
`changelog.txt` by hand with real root-cause writeups; surfacing the top entry once per new
version costs almost nothing and makes the addon feel maintained.

**3.7 First-run setup.**
`../EllesmereUI/EllesmereUI_FirstInstall.lua`. Detect class and role, apply a sensible preset,
done — instead of dropping a new user into 10 tabs with no guidance.

---

## Part 4 — Modernization: the secrets API

**This is the most important technical finding in the review.**

There is a first-class API for detecting secret values, and `Squizzumables.lua` does not use
it at all — it uses 20 `pcall`s instead. `Squizzumables_CDM.lua` already uses `issecretvalue`
in 15 places, so the codebase is internally inconsistent on its single hardest constraint.

### The API

From `../ClickableRaidBuffs/Core/Compat.lua:31`:

```lua
function ns.Compat.IsSecret(value)
  if issecretvalue and issecretvalue(value) then return true end
  if issecrettable and issecrettable(value) then return true end
  return false
end

function ns.Compat.HasAnySecret(...)
  if hasanysecretvalues then return hasanysecretvalues(...) end
  ...
end
```

And from `../ClickableRaidBuffs/Core/SecretsHelper.lua:8`:

```lua
local ShouldAurasBeSecret = C_Secrets and C_Secrets.ShouldAurasBeSecret
```

So the available primitives are:

| Primitive | Use |
|---|---|
| `issecretvalue(v)` | is this scalar secret |
| `issecrettable(v)` | is this table secret |
| `hasanysecretvalues(...)` | vararg form, one call |
| `C_Secrets.ShouldAurasBeSecret()` | are we in a secret-aura context at all |

CRB then builds typed accessors on top — `SafeAuraSpellID`, `SafeAuraName`,
`SafeAuraExpiration`, `SafeAuraSourceUnit` (`Core/SecretsHelper.lua:31`–`:88`). Each checks
the table, then the field, then the type, and returns `nil` rather than throwing. Callers do a
plain nil check. `SafeAuraExpiration` additionally normalises `0` and an `infinite` flag to
`math.huge`, which removes a whole class of "permanent buff shows 0:00" bug.

### Why this beats `pcall`

`pcall` around a comparison does work, and the guidance currently in `CLAUDE.md` is correct.
But:

- it allocates a closure at each call site (see §1.4 — one per button *per frame*)
- it is far more expensive than a predicate check
- it must be applied at **every** downstream comparison, including ones several calls away,
  which is exactly how the live `UnitHasBuff` crash documented in `changelog.txt` v1.58 got
  through

`issecretvalue` is checked **once**, where the field is read. After that the local is known
safe and can be compared and arithmetic'd freely.

### Work items

1. Add `Core/Secrets.lua` mirroring CRB's `SecretsHelper` — `BH.Secrets.IsSecret`,
   `.SafeAuraSpellID`, `.SafeAuraName`, `.SafeAuraExpiration`, `.SafeAuraSourceUnit`,
   `.AurasAreSecret`.
2. Convert these call sites off `pcall`:
   - `UnitHasBuff` (`:5290`) — the `auraData.spellId == id` fallback scan
   - `BH:NeedsRefresh` (`:853`) — `expirationTime - GetTime()`
   - `ForEachPlayerBuff` (`:5626`)
   - the button timer `OnUpdate` (`:5163`)
   - `Squizzumables_SpellAlerts.lua` (currently zero secret handling — check
     `HasLustDebuff` at `:198` and `BH:CheckKelAlerts` at `:234`)
3. Normalise `Squizzumables_CDM.lua`'s 15 inline `issecretvalue` checks onto the same helper.
4. **Update `CLAUDE.md`.** The current rule ("wrap every comparison in `pcall`") should
   become "read aura fields through `BH.Secrets.SafeAura*`, which returns nil instead of
   throwing". This is guidance we will be following for years; it should point at the cheap
   correct pattern.

### Other API modernization

| Item | Current | Should be |
|---|---|---|
| `.toc` interface versions | `## Interface: 120100` | CRB lists `120001 120005 120007 120100`; Ellesmere lists five |
| `.toc` icon | absent | `## IconTexture: Interface\AddOns\Squizzumables\Media\...` |
| `.toc` category | absent | `## Category` |
| Spec API | `GetSpecialization()` at `:410`, `:1767`, `:2156`, `:6681`; `PlayerUtil.GetCurrentSpecID()` at `:7396` | pick one |
| Minimap button | none | LibDataBroker + LibDBIcon (CRB: `Core/MinimapButton.lua`) |
| Addon compartment | none | `## AddonCompartmentFunc` |
| Localization | none | AceLocale or Ellesmere's `EllesmereUI_Locale.lua`; even English-only `L["..."]` wrapping makes translation a later drop-in |
| Pre-12.1 client failsafe | none | Ellesmere's `EUI_CLIENT_BLOCKED` guard as line 1 of every file (`../EllesmereUI/EllesmereUI_ClientGate.lua`) — relevant given the PTR/retail junction |

---

## Part 5 — Missing features

From CRB's module list, in our problem domain, not currently covered:

| Feature | Reference | Notes |
|---|---|---|
| **Healthstone** | `Modules/Healthstone.lua` (474 lines) | Warlock creates, everyone should carry. Handles Soulwell too. Obvious fit. |
| **Augment Rune** | `Modules/AugmentRune.lua` (385) | Standard raid consumable; we already do food/flask/oil. |
| **DK weapon runes** | `Modules/DKWeaponEnchantCheck.lua` (112) | DK is the one class with a permanent weapon enchant, and `Squizzumables_Config.lua` has **no `DEATHKNIGHT` entry at all**. |
| **Trinket equipped check** | `Modules/Trinkets.lua` (712) | Commented out in their `.toc`, but the idea — empty trinket slot warning — is sound. |
| **Ignore / exclusion list** | `Modules/Exclusions.lua` (186) + `Options/Tabs/Ignore_Tab.lua` (1,670) | We have per-item enable but no global "never remind me about X". |
| **Content-type gating** | `Modules/ContentTypes.lua` (394) | Per-difficulty enable: normal/heroic/mythic dungeon, M+, LFR/normal/heroic/mythic raid, timewalking, scenario, delve, world. We have one `IsInValidInstance()` (`:6413`) plus a hardcoded M+ suppression. |
| **User-defined custom reminders** | `Modules/CustomSpells.lua` (814) + `Options/Tabs/CustomSpells.lua` (2,551) | Arbitrary spell or item to reminder button. **Our "Just For Kel" is the same machinery pointed at one use case** — generalising it is the biggest single feature win available. |
| **Masque skinning** | `UI/Masque.lua` (95) | 95 lines for instant visual integration with the user's existing UI. |
| **Glow effects** | `UI/Glow.lua` (195), LibCustomGlow | Pulsing glow on urgent buttons. Cheap way to make it pop. |

### The gate system, worth stealing regardless

`../ClickableRaidBuffs/Core/GateCheck.lua` plus 16 files in `Gates/`. Each visibility
condition is a registered predicate:

```lua
ns.RegisterGate("level", function(ctx, data)
  return ns.Gate_Level(data and data.minLevel, ctx.playerLevel)
end)
```

A displayable declares `gates = { "level", "group", "instance", "alive" }` and
`ns.PassesGates(data, playerLevel, inInstance, rested)` evaluates them against a shared
`ctx` built once (`instanceType`, `difficultyID`, `isPvP`, `isArena`, `isBattleground`).

Available gates: `level`, `group`, `instance`, `rested`, `death`, `vehicle`, `noPet`,
`mounted`, `warlockSacrifice`, `range`, `mineOnly`, `map`, `healer`, `pvp`, `arenaStarted`,
plus a training-dummy bypass.

Compare ours: `ShouldShowButtons()` (`:6448`) plus every one of the ten `Update*Reminder`
functions re-implementing its own class / spec / group / instance / alive checks inline.
If §2.1 lands, adding a `gates` field to each reminder record is nearly free and removes most
of the remaining per-reminder bespoke code.

---

## Part 6 — Release plan

### v1.60 — bugs and safety (no architecture change)  ✅ DONE (untested in-game)

- [x] §1.1 Derive `PROFILE_POSITION_KEYS` from `POSITION_PAIRS`
- [x] §1.2 `BH:LoadAllFramePositions()`, called from both profile popups and `PLAYER_LOGIN`
- [x] §1.5 Delete the empty `OnUpdate` at `:9109`
- [x] §1.7 Add `BH.PlayerKnowsSpell`, replace 16 `IsSpellKnown` call sites
- [x] §4 Add `Squizzumables_Secrets.lua`; convert `Squizzumables.lua` off `pcall`; update `CLAUDE.md`
- [x] §1.4 Throttle the button timer `OnUpdate`, drop the per-frame closure
- [x] §1.3 Pool the three config-panel list refreshers
- [x] §1.6 Include the reagent bag in all bag scans

### v1.61 — the refactor that unlocks everything else

- [ ] §2.4 `local addonName, ns = ...`; move `CreateSQ*` and `SQ_COLORS` onto `ns.UI`
- [ ] §2.5 Split into files (own release, nothing else in it)
- [ ] §2.1 Reminder registry — ~1,200 lines removed
- [ ] §2.2 Break up `UpdateButtons`
- [ ] §2.3 Cached bag snapshot
- [ ] §1.8 Let plain reminder frames live through combat
- [ ] §2.6 Recursive defaults merge + `dbVersion` migrations
- [ ] Tank in CC alert — generalise the Healer CC alert into a role CC alert with
      per-role toggles (see "Role CC alert" below). Sequenced here because §2.1 turns it
      into a data entry instead of a fresh copy-paste of the whole reminder block.

### v1.62 — the UI

- [ ] §3.0 Declarative widget kit: `getValue` / `setValue` / `disabled`, self-registering refresh
- [ ] Delete `RefreshSettingsTab`, `RefreshRaidToolsTab`, `RefreshTextRemindersTab`, and the 34 `self.tr*` handles
- [ ] §3.1 Larger panel with sidebar navigation
- [ ] §3.3 Global Unlock Mode, replacing nine per-frame lock checkboxes
- [ ] §3.5 Tooltips on every row
- [ ] §3.2 Fuzzy settings search

### v1.63+ — features

- [ ] §5 Healthstone, augment rune, DK weapon runes
- [ ] §5 Gate system + content-type gating
- [ ] §5 Generalize Kelerts into user-defined custom reminders
- [ ] §3.4 Profile import/export strings
- [ ] §5 Masque support, LibCustomGlow
- [ ] §4 Minimap button / LibDataBroker, addon compartment
- [ ] §3.6 In-game changelog popup
- [ ] §3.7 First-run setup

---

## Open questions / judgment calls

**Ace3.** CRB embeds ~40 Ace3 files. AceDB-3.0 would solve §2.6 (defaults, profiles,
migrations) outright and AceConfig would solve much of Part 3. Against: it is a large
dependency, our profile system already works including the per-spec override that AceDB does
*not* provide out of the box, and Ellesmere deliberately went the other way — their
`EllesmereUI_Lite.lua` is a 543-line "lightweight addon framework (replaces Ace3)". Leaning
toward: no Ace3, but steal AceDB's recursive-defaults idea (§2.6).

**The file split (§2.5).** Mechanical but touches every line. Worth noting this repo is
**not a git repository** — there is no history to bisect against if something breaks. Strong
argument for either (a) doing the split entirely alone in its own release, or (b) running
`git init` first. Recommend (b) regardless.

**Media size.** `Media/` is 2.7 MB, almost all of it the 15 `duckrun_*.png` frames. Fine for
a personal addon; if this ever goes on CurseForge, converting to BLP would cut the download
substantially.

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

---

## Role CC alert (requested)

Requests have come in for a "Tank in CC" alert alongside the existing "Healer in CC" one.

The existing feature is already almost role-agnostic. The only role-specific pieces are:

- `BH:RefreshHealerWatchList` (`Squizzumables.lua`) filters on
  `UnitGroupRolesAssigned(unit) == "HEALER"` — one line
- the frame's hardcoded `"HEALER IN CC"` text
- the settings key prefix `healerCC*`

Everything else — `healerWatchUnits`, `healerCCActive`, `BH:CheckHealerCC`, the
`UnitHasCCDebuff` scan, the frame, the sound dispatch — works for any role unchanged.

**Recommended shape: one alert, per-role toggles.** Rather than a second parallel frame with
its own enable/scale/lock/position settings, make it a single "Role CC Alert" with two
checkboxes (Healer, Tank) and text that reflects what is actually CC'd:

- Healer only CC'd → `HEALER IN CC`
- Tank only CC'd → `TANK IN CC`
- both → `HEALER + TANK IN CC`

Rationale: two frames means two more scale sliders, two more lock checkboxes and two more
saved positions in a settings tab that is already the most crowded one — for an alert the
player will almost never see both halves of at once. One frame that names the role is less
code and less UI.

**Migration:** keep the existing `healerCC*` settings keys and add `roleCCAlertTank`
(default off) so existing users are unaffected and see no behaviour change until they opt in.
Rename the visible label from "Healer CC Alert" to "Role CC Alert".

**Sequencing:** do this immediately after §2.1. Built today it is another ~200-line
copy-paste of the reminder block that §2.1 then has to migrate; built after §2.1 it is a
`gates`/`shouldShow` entry plus a role filter.
