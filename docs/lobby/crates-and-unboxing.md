# Crates and unboxing

Crates are bought in the [shop](shop.md), kept in the backpack, and opened with an unboxing the whole Lobby can see.

**Runs in:** Lobby
**Code:** [`CrateService`](../../Lobby/src/Services/CrateService.luau), [`CrateController`](../../Lobby/src/Controllers/CrateController.luau), [`CrateUIController`](../../Lobby/src/Controllers/CrateUIController.luau), [`CratePityController`](../../Lobby/src/Controllers/CratePityController.luau), [`UnboxingController`](../../Lobby/src/Controllers/UnboxingController.luau), [`CrateConfig`](../../common/shared/Config/SharedConfig/CrateConfig.luau), [`Config.Crate`](../../common/server/Config/Crate.luau)

## Crate names

| Tier | Name (`DisplayName`) | `Key` |
| --- | --- | --- |
| `Common` | Crate of Beginnings | `CrateOfBeginnings` |
| `Rare` | Crate of Nature | `CrateOfNature` |
| `Epic` | Fragmented Crate | `FragmentedCrate` |
| `Legendary` | Legendary Crate | `LegendaryCrate` |

**The table key is the tier, and the name belongs to the crate.**
`CrateConfig.CRATES` is still indexed by `Common`/`Rare`/`Epic`/`Legendary`, which links the crate to `RarityConfig`, the drop pool, and the profile's `Inventory.Crates`; changing that would need a profile migration.
What the player reads is `DisplayName`.

`Key` is the crate's code name and it is **the same in three places**: the model in `Assets.CratesModel` that the unboxing spawns, its container in `ShopUI`, and the item `Id` in `ShopConfig`.
`CrateConfig.getModelName` returns the `Key`.
The backpack icon also comes from `CrateConfig` (`Image`), written by `CrateController` into each `cratetemplate`'s `crateimg`.

## Odds

The published odds are the **real** chances, including crate upgrades (`Crate.GetDisplayOdds`).
`POOLS` are the chances after the crate stops upgrading, not the chance of buying that crate and getting that rarity: a Crate of Beginnings becomes a Crate of Nature in 10% of openings (and can keep going), so the Common pool only applies in 90% of them.

| Crate | Common | Rare | Epic | Legendary | Cosmic |
| --- | ---: | ---: | ---: | ---: | ---: |
| Crate of Beginnings | 85.99% | 10% | 3% | **1%** (0.64% in the raw pool) | 0.014% (hidden) |
| Crate of Nature | 38.25% | 40.45% | 16.89% | 4.27% | 0.14% |
| Fragmented Crate | — | 43% | 44.6% | 11.48% | 0.92% |
| Legendary Crate | — | 20% | 40% | 40% | — |

The Beginnings row is the **target** (86 / 10 / 3 / 1), and its pool is worked backward from it, which is why `POOLS` has odd numbers.
Its Cosmic comes only from upgrades, so Common gives up the 0.014%.
For the target to hold, the Beginnings → Nature upgrade is **10%**.
Changing `UPGRADES` or any other pool changes the published Beginnings odds, and the math must be redone.

The `Luck` [game pass](../common/gamepasses.md#luck-lifts-the-top-and-leaves-the-bottom-alone) raises Epic and up; the published odds stay those of a player without the pass.

### Units excluded from crates

The **Azure no longer drops from any crate**.
It still exists: players who own it keep it, and it stays in decks, the summon banner (`Summon`), stats, and balance.
`EXCLUDED_UNITS` in `ServerScriptService.Config.Crate` controls this: **a drop rule, not a unit property**.
Its `Rarity` in `UnitStats` stays `Legendary`, which the card, color, and price read; `getUnitsOfRarity` still returns the honest tier list, and the draw filters.

Published odds are per *rarity*, so they do not change: removing the Azure only makes Legendary drops land on the other Legendary units (Berserker and Electro).

⚠️ Emptying a whole rarity through the list would make the draw **drop a tier** and hand out a weaker unit, with a warning (the same path as Cosmic, which has no units).

## Guarantee (pity)

Cosmic, Legendary, and Epic (`CrateConfig.PITY_RARITIES`) have a guarantee with **one count per rarity, shared by every crate**: the profile's `Pity` counts how many openings in a row, of any crate, came out without that rarity.
When the count reaches its limit, the next opening delivers it, whatever the crate; the count resets whenever the rarity comes out.

| Rarity | Limit (`CrateConfig.PITY_THRESHOLDS`) |
| --- | ---: |
| Cosmic | 450 |
| Legendary | 125 |
| Epic | 25 |

- **The crates' odds do not change**: the guarantee only decides the rarity of the opening that comes due (`RollCrate`'s `forcedRarity`), so a due Cosmic comes out of any crate, the Crate of Beginnings included.
- **The counts are independent**: pulling Cosmic does not reset Legendary's, and pulling Legendary does not reset Epic's. The guarantee delivers **exactly** its rarity: a due Epic comes out as Epic even from a Legendary Crate opening that could have given a Legendary.
- **Priority is the list order** (Cosmic, Legendary, Epic): if several come due together, the rarest comes out and the others wait for the next openings.
- The limits are in `SharedConfig.CrateConfig`, not with the odds on the server, because they are not chances: the backpack shows them as they are.
- `CrateService` applies it in `OpenCrate`; Cmdr's `unbox` touches no count.

**The profile shape changed.** It is `Pity = { Legendary = 37, Cosmic = 210 }`; profiles from before still hold one table per crate (`{ Common = { Legendary = 80 }, ... }`).
`CrateConfig.readPity` reads both, and for the old one each rarity starts from its **highest** crate count, so nobody loses progress; the next opening rewrites it in the new shape.

### The backpack's pity list

`crateui.Frame.Rectangle.Pity` shows **one row per rarity**, rarest on top, cloned from the authored `RarityContainer` (`CratePityController`), reading `count/limit`.
The bar's fill and the rarity name take the rarity's color from `RarityConfig`.

- **The counts come from the replica** (`Data.Pity`), so the bars move with each opening.
- **It redraws on every opening of the panel**, besides every profile change, and a bind that a newer `crateui` copy overtook gives up, so the rows never land in a discarded copy.

## The unboxing is for the whole Lobby

`CrateService` **broadcasts each opening to every client**, with the opener in the packet (`_broadcastUnboxing`), one `Fire` per player.
`owner` separates the two views:

| | Opener | Watchers |
| --- | --- | --- |
| Crate flying, growing, shaking, and bursting | yes | yes |
| Burst VFX and rarity aura | yes | yes |
| Unit spinning with its idle | yes | yes |
| **The reel (the roulette billboard)** | yes | **no** |
| **Name and rarity above the unit's head** | yes | **no** |

Watchers get the scene; the **written result** belongs to whoever paid for the crate.

**The crate spawns at the owner's character**, not at the watcher's feet: every `_getRoot` takes the player.
Each client resolves the spot on its own, so it can differ slightly between screens (other players' positions are interpolated).

### The reel spins even when hidden

On a screen that is not the owner's, the reel's `BillboardGui` is never enabled, but the reel is still built and spun behind it.
**The reel's spin times the whole opening**: its `Completed` releases the swell, which releases the burst, which releases the unit, and it chains one upgrade stage into the next.
A second timing path for watchers would drift the day someone changed a `TweenInfo`.
One path, and both screens finish at the same instant; Roblox does not render a disabled `BillboardGui`, so the cost is only creating the entries.

### The simultaneous cap does not apply to your own

`MAX_ACTIVE_UNBOXINGS` (5) counts everyone's crates, and so does the spacing (`MIN_CRATE_SPACING`, 6 studs).
**The player's own opening bypasses the cap**: missing someone else's scene costs nothing, missing the crate you just spent is the one case that matters.

### The revealed unit's idle

Models in `Assets.Units` are `Motor6D` rigs **with no `Humanoid`**; in a match, `Shared.Classes.Unit` creates an `AnimationController` to play them.
The reveal does the same (and reuses a `Humanoid` if a model ever has one).
The track starts only **after** the unit is parented to the Workspace, because an `Animator` outside the DataModel is not evaluated.

## Usage

The `setcrates` and `unbox` [admin commands](../common/admin-commands.md) set a player's crates and play an opening for the whole server.
Openings from `unbox` do not count toward `BoxesOpened` or contracts.

## Known issues

- `Shared.Classes.Unit` calls `Framework:Get("ProjectileController")` and `Framework:Get("VFXController")`, which do not exist in the Lobby and return `nil` there (they exist in the Game).
