# Documentation and code conventions

How we write docs, code comments, and log messages in this repository.
Everything is in American English.

## Language and tone

- Write in American English: *color*, *behavior*, *center*, *canceled*, *gray*.
- Address the reader as "you", in the present tense and active voice.
- Prefer short sentences. Say what the system does before saying why.
- Follow the [Google developer documentation style guide](https://developers.google.com/style) when this page does not cover something.

## Markdown

- One H1 per file, and it matches the page title.
- Headings use sentence case: `## How the shop picks cards`, not `## How The Shop Picks Cards`.
- Put identifiers in backticks: files, instances, services, config keys, attributes, tags, and commands.
- Use relative links between pages, for example `[Lighting](../common/lighting.md)`.
- Use tables for configuration keys and for anything with more than two parallel attributes.
- Always tag code blocks with a language: `lua`, `text`, `json`, or `bash`.
- Write one sentence per line (semantic line breaks).
  Rendered output is the same, and diffs show exactly which sentence changed.

## Where a page goes

The docs follow the code:

| Code lives in | Page lives in |
| --- | --- |
| `common/` | `docs/common/` |
| `Game/src/` | `docs/game/` |
| `Lobby/src/` | `docs/lobby/` |
| `Afk/src/` | `docs/afk/` |
| `MapEditor/src/` | `docs/mapeditor/` |
| Repository layout, Rojo, the `Me` framework, config, vendored libraries | `docs/architecture/` |

When a system is split between `common/` and a place, the page in `docs/common/` describes the shared core and the place page describes only what is specific to that place.
Both pages link to each other.

## System page template

```markdown
# <System name>

<One or two sentences: what it does and who uses it.>

**Runs in:** Game · Lobby
**Code:** [`LightingService`](../../common/server/Services/LightingService.luau), [`LightingController`](../../common/client/Controllers/LightingController.luau)

## How it works
## Configuration
## Usage
## Studio setup
## Design notes
## Known issues
```

- **How it works** describes the current behavior.
- **Configuration** is a table with the key, its default, and its effect.
- **Usage** holds the API and short examples.
- **Studio setup** lists what must be authored in Studio: instances, tags, and attributes.
- **Design notes** explains *why* a decision was made, in a few sentences.
  Do not narrate history ("before, X used to..."); git already records it.
- **Known issues** lists bugs and cleanup that are known and not fixed yet.

Leave out any section that has nothing to say.

## Code comments

- Every module starts with a short `--[[ ]]` header: what the module is responsible for, its contract, and the traps a reader must know about.
- Long explanations of a system belong in `docs/`.
  The header links to the page: `See docs/game/weather-in-match.md.`
- A comment explains *why*. Do not repeat what the code already says.
- Keep comments next to the code they explain, and update them in the same change.

## Log messages

All first-party code writes to the Output through [`Log`](../common/logging.md).
Do not call `print` or `warn` directly.

| Method | When it prints | Use it for |
| --- | --- | --- |
| `log:Debug(...)` | Studio only | Information: what happened, values used to tune something. |
| `log:Info(...)` | Always | A public line every player's console shows on purpose, such as the client boot line. Rare. |
| `log:StudioWarn(...)` | Studio only | Something missing or misconfigured that the person building the game must fix. |
| `log:Warn(...)` | Always | Problems a live server must report (see below). |
| `log:StudioWarnOnce(key, ...)` / `log:WarnOnce(key, ...)` | Once per key | The same, for checks that run many times. |

Use `log:Warn` only for:

1. Data and persistence failures: ProfileStore, DataStore, OrderedDataStore, `MessageAsync`, lost sessions.
2. Monetization: receipts, game passes, and `MarketplaceService`.
3. Failed teleports.
4. Server failures that switch a feature off for real players, such as a missing dependency service or no map to load.

Client code never needs `log:Warn`: a warning in a player's client only shows in that player's console, where nobody on the team can see it.

Write messages as lowercase sentence fragments without the tag; `Log` adds the `[Module]` prefix.
Name the thing that is wrong and what happens because of it:

```lua
log:StudioWarn(`map '{name}' has no SpawnLocation; no spawn fallback.`)
```

The one exception is the `viewdata` Cmdr command, which prints with a raw `print` because an admin asked for that output and it must reach the server log in live servers.

## Glossary

Use these terms consistently in docs, comments, and messages.

| Portuguese | English |
| --- | --- |
| unidade, torre | unit |
| mob, inimigo | enemy (`mob` only when naming code, such as `MobService`) |
| carta | card |
| carta de round | round card |
| caixa | crate |
| loja | shop |
| vitrine | stock |
| clima | weather |
| raio | lightning bolt (weather), radius (geometry) |
| atordoar, atordoamento | stun |
| congelar | freeze |
| cadência | attack speed |
| alcance | range |
| dano | damage |
| partida | match |
| round, wave | round, wave |
| posicionar | place |
| fantasma (posicionamento) | ghost |
| caminho | path |
| destaque | highlight |
| seta de indicação | indicator arrow |
| fala, caixa de fala | dialog line, dialog box |
| selo `New` | `New` badge |
| perfil | profile |
| Fácil, Médio, Difícil, Impossível, Nightmare | Easy, Medium, Hard, Impossible, Nightmare |
