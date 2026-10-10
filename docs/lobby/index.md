# Index

The book of everything the player has discovered (`StarterGui.Index`): units, enemies, weathers, and maps, one page each.

**Runs in:** Lobby (UI) · Game and Lobby (discovery)
**Code:** [`IndexController`](../../Lobby/src/Controllers/IndexController/init.luau), [`IndexCatalog`](../../Lobby/src/Controllers/IndexController/IndexCatalog.luau), [`IndexModelView`](../../Lobby/src/Controllers/IndexController/IndexModelView.luau), [`IndexService`](../../common/server/Services/IndexService.luau), [`IndexConfig`](../../common/shared/Config/SharedConfig/IndexConfig.luau)

## Discovery

The profile stores `Data.Index = { Units, Enemies, Weathers, Maps }`, each `{ [key] = true }`.
Only `IndexService` writes it, and discovery is forever: a sold unit stays discovered.

Only keys the Index can show are written (`IndexConfig.isKnown`): the same sets the pages list (`UnitStats` units with a rarity, `Mob.Entities`, `WeatherConfig.Indicator.Icons`, `MapConfig.MAPS`).
A key with no page could never be clicked, and would keep the HUD badge lit forever.
That happened with the tutorial map, which `MapService` loads and `MapConfig` leaves out on purpose; profiles that already hold it keep the key, but `isNew` and `hasNew` ignore unknown keys.

| Category | Key | Discovered when | Who calls |
| --- | --- | --- | --- |
| `Units` | `UnitStats` name | the player obtains the unit (crate, summon), or already owns it when the profile loads | `CrateService`, `SummoningService`, `IndexService` |
| `Enemies` | `Mob.Entities` name | the enemy spawns in a match the player is in | `MobService` (Game) |
| `Weathers` | `Assets.Weathers` name | the weather goes live in the player's match; the warning alone does not count | `WeatherRoundService` (Game), on `WeatherStarted` |
| `Maps` | `MapConfig.MAPS` key | the player enters the map | `MapService` (Game) |

## New

`Data.IndexSeen` has the same shape and holds what the player has **clicked** in the book.
A discovered key missing there is new (`IndexConfig.isNew`): it lights the item's `New` label and the HUD's `Index` badge (`IndexConfig.hasNew`, in `HUDBadgeController`).

Clicking a new item fires `IndexSeen(category, key)`.
The server writes it only if the key is discovered and not seen yet, so a forged click changes nothing.
The client hides the item's label at once and waits for the replica for everything else.

A player whose profile predates the Index sees their owned units as new the first time: they were synced into `Index` without ever being clicked.

## The book

It opens from `HUD.HUDLeft.Wrapper.Index` through `ProximityPanel`, with no map spot: the same `OpenShop` animation, blur, hidden HUD, and X as the contracts board, but no teleport.

| Piece | What it is |
| --- | --- |
| `ItemsContainer.ItemsScrolling` | Template for a page. Each category gets its own clone, built the first time the page is shown and kept until the ScreenGui resets (respawn) |
| `ItemsScrolling.Wrapper` | Template for an item, with `ItemButton` and its `Icon`, `ViewportFrame`, `New`, and `LockedIMG` |
| `NextPreviousButtons` | Turns pages in a loop (last to first and back); the label shows `page/total` |
| `PreviewContainer.PreviewItem` | The selected item: `ViewportFrame` for units and enemies, `Icon` for weathers and maps |
| `PreviewContainer.Description` | The description, written by [`RichTextController`](../common/rich-text.md) into `DescriptionText` (any GuiObject; a frame filling `Description` is created when Studio has none) |
| `MarkersContainer` | One bookmark per category, named like it (`Units`, `Enemies`, `Weathers`, `Maps`); a click opens that page. The open category's bookmark turns transparent and takes no clicks, keeping its slot in the `UIListLayout` |
| `CurrentSection` | The open category's bookmark. Both arts (here and in the container) are `SECTION_IMAGES` in `IndexController` |
| `a`, `ExpandedPreview` | Not wired yet |

Changing category with the book open (a bookmark or Next/Previous) plays one of the page-turn sounds in `SECTION_SOUNDS`, at random and never the same twice in a row.
The controller builds them in `SoundService.IndexSFX` and plays them through `MusicController:PlaySFX`, so the settings' SFX volume and mute apply.
Opening the book plays nothing.

How each category draws its item:

| Category | Discovered | Locked |
| --- | --- | --- |
| Units | `CardConfig.IndexImages[unit].Unlocked` in `Icon` | the `Locked` art, button black, padlock |
| Enemies | the model in `ViewportFrame`, walking and spinning | the same model all black, button black, padlock |
| Weathers | `WeatherConfig.Indicator.Icons` in `Icon` | no picture, button black, padlock |
| Maps | `MapConfig.MAPS[map].IndexImage` (falls back to `Image`) in `Icon`; the preview shows `Image`, the map picker's picture | no picture, button black, padlock |

A unit without `IndexImages` art falls back to its model, like an enemy.
Locked items take no clicks and do not grow on hover.

Opening a page selects its first discovered item, without marking it seen.
The preview shows units idling (`Idle`) and enemies walking (`Walk`, then `SlowWalk`/`FastWalk`, then the generic `Entities.Walk`), both spinning.
Only the current page's models animate and spin, and only while the book is open.

## The catalog

`IndexCatalog` lists each page from the configs that already describe the content, and builds the descriptions:

| Category | Order | Description |
| --- | --- | --- |
| Units | rarity, then cost | rarity and class, a hand-written behavior line (`UNIT_BEHAVIOR`), cost and range |
| Enemies | difficulty (Easy to Nightmare), boss last, then health | difficulty, base HP, speed band, element and resistances, gimmicks |
| Weathers | name | `WeatherConfig.Indicator.Details` |
| Maps | wins required | wins required, and the weathers in `WeatherConfig.MapPools` |

### Description text

The description is `RichTextController` markup, written all at once (preset `Instant`), white with a dark outline in the page counter's font.
Key words carry a color: the unit's rarity (`RarityConfig`, lightened) and type (the weather indicator's type colors), cash, range, HP, speed, the difficulty, effects like bleed, burn, frost, and stun, and the weather lines through `WeatherConfig.MarkupDetail`, the same coloring as the in-match indicator.

The size is measured by `IndexController` (`_fitDescriptionSize`): the largest size whose text, wrapped with `TextService`, fits the box.
`Fit` does not suit it, because it treats a sentence as one line split into rows and the description is several paragraphs.
The box only has its real size on screen, so the description is drawn when the book opens, after the open animation settles.

Unit names follow the card art where it differs from the key (`Rocket` is the Rocketeer, `Sword` the Gladiator).
Enemy names split the key at its capitals; an optional `DisplayName` in `Mob.Entities` overrides that.
A new unit needs a line in `UNIT_BEHAVIOR` and a pair in `CardConfig.IndexImages`; nothing else in the Index changes.
