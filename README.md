# Squizzumables

A World of Warcraft addon that reminds you to apply the things you keep forgetting — food,
flasks, weapon oils, augment runes and class buffs — and gives you a clickable button to fix each
one without opening your bags. Plus raid tools, a fully restyled Cooldown Manager, and sound and
image alerts.

Retail only, built for **Midnight (12.0+)**.

![Interface](https://img.shields.io/badge/Interface-120100-blue)

**[Download on CurseForge](https://www.curseforge.com/projects/1483099)**

## What it does

**Consumable and buff reminders.** Scans your bags, buffs and weapon enchants and shows a button
for anything missing. Click it to eat, drink, apply or cast. Choose where reminders appear: open
world, each dungeon and raid difficulty, Mythic+. The bag reminder also warns when you're running
low ("LOW ON FLASK (1 LEFT)"), not only when you're out.

**Class buffs.** Per-class buff tracking with the awkward cases handled — buff variants that count
as the same, self-only and tank buffs, weapon imbues, rogue poisons, pets, Paladin auras and rites,
Death Knight runeforging, Earth Shield and more.

**Text reminders.** Large, movable banners for the things a button cannot fix: repair, no
healthstone, no pet, missing beacons, a healer or tank in crowd control. Each one knows when it is
relevant, so you only see it where it matters.

**Raid tools.** Pull timer (shown on Blizzard's encounter timeline), ready check, raid markers,
battle res counter, Mythic+ death tally, feast announcements and a target distance readout.
**Dungeon callouts**: your own buttons for each dungeon that send a message and play a sound —
they work in combat and in Mythic+. Feast messages and callouts can include `{name}`, `{zone}` and
(for feasts) `{feast}`, so one message reads right on every character.

**Cooldown Manager.** Blizzard's Essential, Utility, Buffs and Buff Bars groups, restyled: icon
shapes (round, diamond, hexagon, shield, heart, star), borders, zoom, panels, and text you can
place anywhere. Proc glow in a colour of your choice, Glow When Ready, grey out on cooldown, and
Show While Active to show an ability's buff time while it is running. Your own custom icon groups,
anchored to each other or to other addons' frames, a spell shown in two groups at once ("Also
in"), and an option to hide Blizzard's own bars.

**Sounds and alerts.** Attach your own sound to any Cooldown Manager spell — when it is ready,
when its buff goes up, or when it drops. Buff sounds that keep working in combat. A full-screen
image and sound alert on Bloodlust and the other lust effects, with bundled tracks. Your own
sounds (OGG or MP3) live in a folder that updates never touch.

**Quality of life.** Profiles per character and per spec with import/export strings, unlock mode
with an alignment grid and snapping (shared with SquizzFrames), a settings panel with search and
tooltips on every option, minimap button and addon compartment entry.

## Installing

Install from [CurseForge](https://www.curseforge.com/projects/1483099), or drop the
`Squizzumables` folder into:

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

## Support

If you enjoy using Squizzumables, consider supporting development on
[Ko-fi](https://ko-fi.com/squizz) ❤️

## More addons by Squizz

- **[SquizzFrames](https://www.curseforge.com/projects/1649203)** — party, raid, pet and unit frames with a full indicator system, click-casting and a tank tracker
- **[Squizzcap](https://www.curseforge.com/projects/1713974)** — what killed you, how hard it hit and how fast you went down, with every death of a key saved to look back on
- **[SquizzTalents](https://www.curseforge.com/projects/1705647)** — all your talent builds in one list, with a reminder when your build doesn't match the content
- **[DPS Report](https://www.curseforge.com/projects/1504877)** — a lightweight damage meter with spell breakdowns and an end-of-key MVP summary
- **[Avatar Continued](https://www.curseforge.com/projects/1533608)** — your character model on screen as part of your UI
- **[KSLBestDungeon](https://www.curseforge.com/projects/1599575)** — ranks Mythic+ dungeons by how many of your KeystoneLoot favorites drop there

## License

[MIT](LICENSE), covering the addon code.

Two exceptions, both bundled rather than written here:

- `Libs/LibStub` — public domain.
- `Libs/LibSharedMedia-3.0` — LGPL v2.1, by Elkano.

The audio and image files in `Media/` are not covered by the MIT grant.
