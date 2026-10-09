# Lobby place

The Lobby place, "Periastron Tower Defense": where players arrive, manage their deck, open crates, shop, take contracts, and enter portals to a match.

For the repository layout and what is shared between the places, see [Repository overview](../architecture/overview.md).

## What is specific to this place

| Folder | Mounted at | Contents |
| --- | --- | --- |
| `src/ClientBoot/` | `StarterPlayerScripts.Client` | Entry LocalScript |
| `src/Controllers/` | `Client.Controllers.Lobby` | ChooseMaps, Contract, Crate, CratePity, CrateUI, Deck, FriendInvite, HUD, HUDBadge, HUDButton, Index, LobbyMusic, NextEvent, PlayButton, Portal, RobuxShop, RoundCardShop, RuneShop, Shop, ShopKeeper, UILibrary, Unboxing |
| `src/Services/` | `ServerScriptService.Services.Lobby` | AfkTeleport, Crate, Deck, FriendInvite, Leaderstats, Portal, RoundCardShop, RuneShop, Shop, Summoning, WelcomeBadge |
| `src/CmdrDefinitions/Commands/` | `ServerScriptService.CmdrDefinitions.Commands.Lobby` | `friendinvite`, `friendinvitestats`, `setcrates`, `unbox` |
| `src/CmdrDefinitions/Types/` | `ServerScriptService.CmdrDefinitions.Types.Lobby` | `crateRarity` |

## Pages

| Page | What it covers |
| --- | --- |
| [HUD](hud.md) | Level, XP, currencies, column buttons, `New` badges, leaderstats, the welcome badge |
| [Maps panel](maps-panel.md) | Choosing the map and the win locks |
| [Deck](deck.md) | The loadout: inventory, equipped cards, slot unlocks |
| [Index](index.md) | The book of discovered units, enemies, weathers, and maps |
| [Crates and unboxing](crates-and-unboxing.md) | Crate names, odds, and the shared unboxing |
| [Crate shop](shop.md) | The crate shop and the shopkeeper |
| [Card shop](round-card-shop.md) | Unlocking round cards with shards |
| [Rune shop](rune-shop.md) | Buying temporary buffs with shards |
| [Friend invite suggestion](friend-invite.md) | The "your friend is online" notification and the `friendinvite` command |
| [Next event sign](next-event.md) | `Workspace.NEXTEVENT`: the next Roblox event's name, countdown, and RSVP prompt |

Systems that also run here are documented in [common](../common/README.md): [contracts](../common/contracts.md), [game passes and the Robux shop](../common/gamepasses.md), [leaderboards](../common/leaderboards.md), [runes](../common/runes.md), [the proximity panel](../common/proximity-panel.md), and [the tutorial](../common/tutorial.md).

## Outside the repository

| Item | Why |
| --- | --- |
| `ReplicatedStorage.Shared.Assets` | Models, parts, and animations: content, not code |
| `StarterGui.HUD`, `StarterGui.crateui`, `StarterGui.ShopUI`, and the other ScreenGuis | GUI instances; to version them, export as `.rbxmx` |
| `ReplicatedStorage.CascadeRuntimeEngine` | The paid Cascade UI runtime |
| `ReplicatedStorage.CascadeAnimations` | Animations saved by the Cascade plugin (`OpenShop`) |
| `StarterPlayerScripts.PlayerModule`, `StarterCharacterScripts.Animate` | Stock Roblox code |
| `ServerStorage.Lunar_VFX_Scripts` | Third-party asset readme |

⚠️ `ReplicatedStorage.Shared` has a **PackageLink** (it is a Roblox Package).
Syncing over it marks the package as modified in Studio.
