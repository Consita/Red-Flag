# Red Flag

**Know who you're dealing with — before you group up.**

A private player and guild blacklist for World of Warcraft **TBC Anniversary**. Keep your own list
with notes, and get a private warning the moment a flagged player whispers you, invites you, or ends
up in your group.

## No public shaming
Red Flag is a **personal tool, not a pillory**.
- It **never posts anything** in say, yell, party, raid, guild or any other chat channel.
- It **never whispers or notifies** a flagged player – they won't know they are on your list.
- Warnings are **only visible to you**: a chat message in your own chat window, a popup and/or a light sound.
- Your list and notes are stored **only on your computer** and are never sent anywhere.

## Features
- **Players and guilds** – blacklist individual players or entire guilds.
- **Tracked by GUID** – renamed characters stay flagged, and you get a chat notice when a flagged
  player changes their name. Players added by name get their GUID filled in the first time you see them.
- **Personal notes** – one note per player/guild, shown in warnings and tooltips.
- **Account-wide** – your list is available on every character of your account.
- **Warnings** when a blacklisted player (or a member of a blacklisted guild) whispers you, invites you,
  is in your group or raid, or is invited by you – as a chat message, popup and/or sound
  (soft ding, map ping or raid warning), each individually switchable.
- **Tooltips** show your notes on blacklisted players.
- **Backups** – a backup is written on every logout/reload and restored automatically if your list
  ever fails to load; `/rf restore` brings back missing entries.

## Installation
- **CurseForge app:** search for *Red Flag*.
- **Manually:** download `RedFlag-x.y-bc.zip` from the latest
  [release](https://github.com/Consita/Red-Flag/releases) and extract it into
  `World of Warcraft\_anniversary_\Interface\AddOns\` (you should end up with an `AddOns\RedFlag` folder).

Requires [Ace3](https://www.curseforge.com/wow/addons/ace3).

## Commands
| Command | |
|---|---|
| `/rf` | Open the Red Flag window |
| `/rf add [Name-Realm]` | Add a player (or your target) |
| `/rf addguild [Guild]` | Add a guild (or your target's guild) |
| `/rf remove Name-Realm` | Remove a player |
| `/rf test` | Show a test warning |
| `/rf restore` | Restore missing entries from your backup |
| `/rf settings` | Open the settings |

## For addon authors
Red Flag offers a small, stable interface (`RedFlagAPI`, version 1) that lets other addons show
additional lists in the Red Flag window. It is documented at the end of [Core.lua](Core.lua).
