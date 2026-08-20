# Squizzumables

A World of Warcraft addon that reminds you to apply the things you keep forgetting — food,
flasks, weapon oils, augment runes and class buffs — and gives you a clickable button to fix each
one without opening your bags.

Retail only, built for **Midnight (12.0+)**.

![Interface](https://img.shields.io/badge/Interface-120100-blue)

## What it does

**Consumable and buff reminders.** Scans your bags, auras and weapon enchants and shows a button
for anything missing. Click the button to eat, drink, apply or cast it. Buttons appear in the
order you configure them, not the order things happen to sit in your bags.

**Class buffs.** Per-class buff tracking with the awkward cases handled — buff variants that count
as equivalent, self-only buffs, tank buffs, weapon imbues, pet checks, Paladin auras, Death Knight
runeforging, Shaman Earth Shield, Druid Symbiotic Relationship.

**Text reminders.** Large, movable banners for the things a button cannot fix: repair, no
healthstone, no pet, missing beacons, a healer or tank in crowd control. Each one knows when it is
relevant, so you only see it where it matters.

**Raid tools.** Pull timer (mirrored onto Blizzard's encounter timeline), ready check, raid target
markers, battle-res counter, Mythic+ death tally, feast announcements.

**Cooldown Manager sounds.** Attach your own sound to any spell in Blizzard's Cooldown Manager,
firing when it becomes available, when its buff goes up, or when the buff drops.

**Kelerts.** Full-screen image and sound alerts on any buff or debuff you name. Ships with one
watching every Bloodlust-type exhaustion debuff at once.

**Quality of life.** Profiles with per-character and per-spec assignment, import/export strings,
per-difficulty "Show in" gating, button glow, minimap button and addon compartment entry, and a
settings panel with search and tooltips on every option.

## Installing

Drop the `Squizzumables` folder into:

    World of Warcraft/_retail_/Interface/AddOns/

Then `/reload` or restart the client.

## Commands

| Command | Does |
|---|---|
| `/sq config` or `/squizz` | Open the options panel |
| `/sq unlock` | Unlock every frame for dragging |
| `/sq reset` | Reset the main frame to centre |
| `/sq reload` | Recompute the buttons |
| `/sq notes` | Reopen the release notes |
| `/ginvite <name>` | Guild invite helper |

`/sq feast`, `/sq auras`, `/sq cdm`, `/sq timeline`, `/sq dk` and `/sq debug` print diagnostics.

## Contributing

There is no build step — edit the `.lua` files and `/reload` in game. `CLAUDE.md` documents the
architecture and, more usefully, the constraints: secret aura values, taint safety, and the APIs
that no longer work on 12.1+. `NOTES.md` records what was investigated and found impossible, so
it does not get attempted twice. `changelog.txt` carries root-cause writeups for past fixes.
