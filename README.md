# Periastron Tower Defense

A Roblox tower defense game made of two places: the **Lobby**, where players build their deck, open crates, and pick a map, and the **Game** ("Main Game"), where they play the match.
Both places are published to two experiences, Production and QA (see [Environments](docs/common/environments.md)).
A third place, the **AFK** place, is being set up (see [AFK place](docs/afk/README.md)).
A fourth, the **Map Editor**, is where players build their own maps (see [Map Editor place](docs/mapeditor/README.md)).
This monorepo holds every place; code they share lives at the root.

```text
common/     first-party code shared by every place
vendor/     third-party libraries that do not come from Wally
Game/       the "Periastron TD: Main Game" place (only what is specific to it)
Lobby/      the "Periastron Tower Defense" lobby place (only what is specific to it)
Afk/        the AFK place (only what is specific to it)
MapEditor/  the Map Editor place (only what is specific to it)
docs/       documentation
```

## Development setup

### Requirements

| Tool | Version | What it is for |
| --- | --- | --- |
| [Roblox Studio](https://create.roblox.com/) | latest | Opening, testing, and publishing the places |
| [Aftman](https://github.com/LPGhatguy/aftman) | 0.3 or later | Installs the pinned versions of the tools below |
| [Rojo](https://rojo.space/) | **7.6.1** (pinned in `aftman.toml`) | Syncs the code in this repository into Studio |
| [Wally](https://wally.run/) | **0.3.2** (pinned in `aftman.toml`) | Installs the Luau packages each place depends on |
| [Git](https://git-scm.com/) | any | Cloning the repository |

You also need edit access to the experiences on Roblox, so that you can open the places in Studio.

### 1. Install Aftman

Download the release for your system from the [Aftman releases page](https://github.com/LPGhatguy/aftman/releases), then run it once so that it installs itself and adds its `bin` folder to your `PATH`:

```bash
./aftman self-install
```

Open a new terminal afterwards so the new `PATH` takes effect.

### 2. Clone and install the tools

```bash
git clone <repository url>
cd Periastron-Tower-Defense
aftman install
```

`aftman install` downloads Rojo 7.6.1 and Wally 0.3.2 as listed in `aftman.toml`.
The first time, it asks you to trust each tool; answer yes.
The root `aftman.toml` lets you run `rojo` and `wally` from the root and from inside `Game/`, `Lobby/`, and `Afk/`.

Check the versions:

```bash
rojo --version    # Rojo 7.6.1
wally --version   # wally 0.3.2
```

### 3. Install the packages

Each place has its own `wally.toml` and its own `Packages/` folder, so install each one:

```bash
cd Game  && wally install && cd ..
cd Lobby && wally install && cd ..
cd Afk   && wally install && cd ..
cd MapEditor && wally install && cd ..
```

Git ignores `Packages/`.
Without it, the Rojo project points at a missing folder and the sync fails.
Run `wally install` again whenever a `wally.toml` changes.

### 4. Install the Rojo plugin in Studio

The Studio plugin must match the CLI version:

```bash
rojo plugin install
```

Restart Studio so it loads the plugin.
If you already had the plugin from the Creator Store, remove it first so that you do not run two versions.

### 5. Open the place and connect

Rojo only syncs code.
Models, maps, GUIs, sounds, and the other content live only in the published places, so always open the real place from Studio (**File > Open from Roblox**), never a blank baseplate.
Use the QA places for day-to-day work:

| Place | QA place id | Production place id | Serve from |
| --- | --- | --- | --- |
| Lobby | `80434020174775` | `132304466547289` | `Lobby/` |
| Main Game | `131924395601623` | `109030368179494` | `Game/` |
| AFK | not published yet | not published yet | `Afk/` |
| Map Editor | `131485363672766` | not published yet | `MapEditor/` |

Start the server from the matching folder:

```bash
cd Lobby && rojo serve
```

In Studio, open the Rojo plugin and select **Connect**.
The default port is `34872`.

To work on two places at the same time, give the second server another port and set the same port in that Studio window's Rojo plugin:

```bash
cd Game && rojo serve --port 34873
```

### 6. Check that it works

Press **Play**.
When the client finishes loading, the Output shows a line like this:

```text
[Periastron] client loaded: Lobby, QA environment, place version 0
```

If a place misbehaves after you move files around, see [Setup](docs/architecture/setup.md) for how to confirm that every service loaded.

### Building a place file

To build a place file instead of serving it:

```bash
cd Game && rojo build -o Game.rbxl
```

Git ignores `.rbxl` and `.rbxlx` files.
A built file contains only the code, not the content of the published place.

### Editor support (optional)

For autocomplete and type checking in VS Code, install the [Luau Language Server](https://marketplace.visualstudio.com/items?itemName=JohnnyMorganz.luau-lsp) extension and generate a sourcemap for the place you are working on:

```bash
cd Game && rojo sourcemap --watch -o sourcemap.json
```

Git ignores `sourcemap.json`.

## Documentation

All documentation is in [`docs/`](docs/README.md):

- [Repository overview](docs/architecture/overview.md) and [setup](docs/architecture/setup.md)
- [Game place](docs/game/README.md), [Lobby place](docs/lobby/README.md), [AFK place](docs/afk/README.md), and [Map Editor place](docs/mapeditor/README.md)
- [Shared systems](docs/common/README.md)
- [Conventions](docs/architecture/conventions.md) for code, comments, logs, and docs
