# Periastron Tower Defense documentation

Periastron Tower Defense is a Roblox tower defense game made of two places in one universe: the **Lobby**, where players build their deck, open crates, and pick a map, and the **Game** ("Main Game"), where they play the match.

## Where to start

- New to the repository? Start with the [development setup](../README.md#development-setup) in the root README, then read [Repository overview](architecture/overview.md).
- Writing code or docs? Follow the [Conventions](architecture/conventions.md).
- Looking for a system? Use the index below; pages live where the code lives.

## Architecture

| Page | What it covers |
| --- | --- |
| [Repository overview](architecture/overview.md) | Layout, how shared code is mounted, Rojo pitfalls, differences between places |
| [Setup](architecture/setup.md) | Checking the load after structural changes (installing is in the root README) |
| [The `Me` framework](architecture/me-framework.md) | Loading Services and Controllers, lifecycle, network events |
| [Configuration](architecture/configuration.md) | Server-only and replicated config |
| [Vendored libraries](architecture/vendor.md) | Third-party code, Wally packages, the `vfx` runtime and its local patch |
| [Conventions](architecture/conventions.md) | Documentation, comments, log messages, glossary |

## Places

- [Game place](game/README.md): maps, units, enemies, placement, the match UI, round cards, weather in a match, rewards, and the tutorial match.
- [Lobby place](lobby/README.md): HUD, maps panel, deck, crates, and shops.
- [AFK place](afk/README.md): the AFK area, with its timer, coin rewards, and the button back to the Lobby.
- [Map Editor place](mapeditor/README.md): the standalone map builder, with route validation, playtests, and export to the Game's map format.

## Shared systems

[Shared systems](common/README.md) run in every place: admin commands, audio, badges, contracts, controls, data, dialog, footsteps, game passes, interface visibility, leaderboards, lighting, logging, proximity panels, rich text, screen warnings, tutorial, UI guidance, and weather.
