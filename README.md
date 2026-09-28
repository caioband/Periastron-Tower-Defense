# Periastron Tower Defense

A Roblox tower defense game made of two places in one universe: the **Lobby**, where players build their deck, open crates, and pick a map, and the **Game** ("Main Game"), where they play the match.
This monorepo holds both places; code they share lives at the root.

```text
common/     first-party code shared by both places
vendor/     third-party libraries that do not come from Wally
Game/       the "Periastron TD: Main Game" place (only what is specific to it)
Lobby/      the "Periastron Tower Defense" lobby place (only what is specific to it)
docs/       documentation
```

## Quick start

```bash
aftman install                           # rojo 7.6.1 + wally
cd Game  && wally install && rojo serve  # or
cd Lobby && wally install && rojo serve
```

## Documentation

All documentation is in [`docs/`](docs/README.md):

- [Repository overview](docs/architecture/overview.md) and [setup](docs/architecture/setup.md)
- [Game place](docs/game/README.md) and [Lobby place](docs/lobby/README.md)
- [Shared systems](docs/common/README.md)
- [Conventions](docs/architecture/conventions.md) for code, comments, logs, and docs
