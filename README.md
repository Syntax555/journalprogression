# Journal: Progression

A World of Warcraft 3.3.5a addon that adds a **Progression** tab to the
[Journal](https://github.com/buildthehomelab/wow-mod-forever-journal) (mod-forever-journal), for realms
running [mod-individual-progression](https://github.com/Grimfeather/mod-individual-progression).

It shows the progression stage your character is at and, in order, everything to do there to reach the
next one:

- **Levels**: reach 60, then 70 once Outland opens, then 80 once Northrend opens.
- **Attunements and keys**, with their full quest chains in the order you do them, including earlier
  quests: the Drakefire Amulet for Onyxia, the Tempest Key and the Trials of the Naaru for The Eye, the
  Cudgel of Kar'desh for Serpentshrine Cavern, the Vials of Eternity for Mount Hyjal, the Medallion of
  Karabor for the Black Temple, and the rest.
- **Reputation** a step needs, such as Hydraxian Waterlords for Molten Core's runes, Argent Dawn for
  Naxxramas, and The Violet Eye for the Nightbane chain.
- **Each raid's bosses** in order, down to the one whose kill moves you to the next stage.
- **A gear check** before the first raid of each expansion: a suggested average item level, your own,
  and the slots worth upgrading first.

Every quest shows who gives it and where. Click a step for its objectives and a button that flags the
quest giver or the raid entrance on your map. Shift-click a quest or item to link it in chat.

Open it with `/progression`, or from the Journal's tabs (between Raids and Quests).

## Screenshots

<img width="1442" height="1005" alt="image" src="https://github.com/user-attachments/assets/b4be045c-99c3-4d87-9d64-338ee64bfec4" />
<details>
<summary>View more screenshots</summary>
<img width="978" height="839" alt="image" src="https://github.com/user-attachments/assets/b819b412-cc08-4ae1-9f38-d46db10d924a" />
<img width="972" height="836" alt="image" src="https://github.com/user-attachments/assets/20cfbf5f-7d44-4d8f-9452-1d65c7733359" />
</details>



## What each step shows

| Status | Meaning |
| --- | --- |
| **Next** | The first step still to do. It's highlighted, so you always know where to go. |
| Done | Turned in, in your bags, reached or killed. |
| Not needed now | A step you went past: a later step that waited for it is done. |
| Ready to turn in / In your quest log | From your own quest log. |
| First: *quest* | An earlier step comes first. |
| Needs level *N* / Needs *faction*: *standing* | You don't meet the quest's requirements yet. |
| Opens at stage *N* | Your progression stage keeps it locked. |
| In your bank: carry it | You own the key or amulet, but the realm checks your bags when you enter. |
| Killed this lockout | A boss you've killed since the last raid reset. |
| Optional / Recommended | Not needed to move on: bosses after the milestone, shortcuts and the gear check. |

Steps for the other faction are hidden. The Aldor and Scryers routes both show until you start one;
after that only your side's steps show. **Hide steps I've done** removes finished steps from the list.

## Stages

The stage you're at opens by default, and the tab switches to the next stage as soon as you reach it.
The list on the left has every stage, grouped by expansion, so you can look back or plan ahead.

| Stage | What moves you on |
| --- | --- |
| 0 | Ragnaros, Molten Core |
| 1 | Onyxia, Onyxia's Lair (40 player) |
| 2 | Nefarian, Blackwing Lair |
| 3 | Ringing the Scarab Gong in Silithus |
| 4 | Lieutenant General Nokhor, the war in Silithus |
| 5 | C'Thun, Temple of Ahn'Qiraj |
| 6 | Kel'Thuzad, Naxxramas (40 player) |
| 7 | Into the Breach, at the Dark Portal |
| 8 | Prince Malchezaar, Karazhan |
| 9 | Kael'thas Sunstrider, The Eye |
| 10 | Illidan Stormrage, Black Temple |
| 12 | Kil'jaeden, Sunwell Plateau |
| 13 | Kel'Thuzad, Naxxramas |
| 14 | Yogg-Saron, Ulduar |
| 15 | Anub'arak, Trial of the Crusader |
| 16 | The Lich King, Icecrown Citadel |
| 17 | Halion, The Ruby Sanctum |

## Requirements

- **The Journal**: the [Journal addon](https://github.com/Syntax555/wow-mod-forever-journal/releases/latest/download/Journal-latest.zip)
  on your client and the mod-forever-journal module on the realm. The tab gets your stage, quest givers,
  quest states, objectives, map flags, and raid bosses and lockouts from it.
- **mod-individual-progression** on the realm. Without it, the tab says the realm doesn't track
  progression.
- **[DragonUI](https://github.com/Syntax555/DragonUI)** (optional), for the item level used by the gear
  check and its GearScore.

The [Playerbots Portable server](https://github.com/Syntax555/mod-playerbots-portable/releases/latest)
includes both modules.

## mod-playerbots-portable fork

This fork is maintained for
[Playerbots Portable](https://github.com/Syntax555/mod-playerbots-portable) on its `main` branch.
Its steps follow that server's
[Individual Progression fork](https://github.com/Syntax555/mod-individual-progression) and managed
profile, where every character earns each stage itself. The tab only reads what the realm reports:
it cannot grant a stage, an attunement, an item or access.

## Installation

1. Download [JournalProgression-latest.zip](https://github.com/Syntax555/journalprogression/releases/latest/download/JournalProgression-latest.zip)
   from this fork's [Latest release](https://github.com/Syntax555/journalprogression/releases/latest),
   and the matching [Journal-latest.zip](https://github.com/Syntax555/wow-mod-forever-journal/releases/latest/download/Journal-latest.zip).
2. Close WoW completely. Extract both into `Interface/AddOns/`, so that
   `Interface/AddOns/Journal/Journal.toc` and
   `Interface/AddOns/JournalProgression/JournalProgression.toc` exist. Replace older folders of the
   same names; your settings in `WTF/` are kept.
3. Start WoW. A `/reload` isn't enough the first time, because the game only finds new addons when it
   starts.

Repeat these steps to update. The packaged `SOURCE_REVISION.txt` identifies the installed commit.

## DragonUI

With DragonUI installed, the gear check uses DragonUI's average item level, so it matches the number
in its character panel, and shows its GearScore beside it. Without DragonUI, the tab works out the
average item level itself.

The Progression micro button needs a DragonUI with `DragonUI.RegisterMicroButton`, which the
Playerbots Portable DragonUI does not provide. Without it there's no button; `/progression` and the
Journal's tab work as usual.

## Customising the steps

The steps live in `Tiers.lua`. It's plain data with its format described at the top, so you can change
a note, a suggested item level, or a step for your realm without touching the code. The quest chains
were worked out from AzerothCore's quest tables (each quest's prerequisites and follow-ups), with
mod-individual-progression's own quests and changes added by hand.

The suggested item levels are rules of thumb:

| Before | Item level | Typically from |
| --- | --- | --- |
| Molten Core | 55 | Level 60 dungeon blues (Blackrock Depths, Stratholme, Scholomance, Blackrock Spire) |
| Karazhan | 110 | Outland level 70 dungeon blues and quest rewards |
| Naxxramas (level 80) | 180 | Northrend level 80 dungeon blues and crafted gear |

## Things to know

- **Reputation** is read by faction name, so on a non-English client the reputation steps rely on what
  the realm reports for each quest.
- **Raid bosses** before the final one show as killed only for the current lockout, since that's all
  the realm keeps.
- **Realm settings** aren't visible to an addon. The steps assume mod-individual-progression's
  defaults, which the Playerbots Portable profile keeps: dousing Molten Core's runes by hand
  (`MoltenCore.ManualRuneHandling`) and opening the last boss of Serpentshrine Cavern and The Eye
  after the others (`RequireAllBosses`). If your realm changes them, edit `Tiers.lua` to match.
- **Journal updates:** the tab uses the Journal's widgets and data functions, so a large Journal
  update may need a matching update here.

## Credits

- [mod-forever-journal](https://github.com/buildthehomelab/wow-mod-forever-journal), the Journal this
  tab lives in.
- [mod-individual-progression](https://github.com/Grimfeather/mod-individual-progression), the
  progression stages, their attunements and the quests it adds.
- [AzerothCore](https://www.azerothcore.org/) for the quest data the chains were built from.
- [DragonUI](https://github.com/NeticSoul/DragonUI) by NeticSoul, for the item level, GearScore and
  micro menu.
