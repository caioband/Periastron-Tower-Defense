# Weather

`WeatherService` turns a weather model on or off: it clones the model into the Workspace, fits each part to the loaded map, and hands its lighting to `LightingService`.
`WeatherController` plays the weather's sound on each client.
The match rules (when weather happens and what it does to units) are in [Weather in a match](../game/weather-in-match.md).

**Runs in:** Game · Lobby
**Code:** [`WeatherService`](../../common/server/Services/WeatherService.luau), [`WeatherController`](../../common/client/Controllers/WeatherController.luau), [`WeatherConfig`](../../common/shared/Config/SharedConfig/WeatherConfig.luau)

## How it works

A weather is a Model in `ReplicatedStorage.Shared.Assets.Weathers`, with a **tag** saying how each of its parts fits the map:

```text
Assets.Weathers
├── Snow      (Model, tag "AreaWeather")
│   ├── Part      (the ParticleEmitters)
│   └── Lighting  (Folder: a preset, same format as Assets.Lighting)
├── Thunder   (Model, tag "SkyWeather")
└── Rain      (Model, tags "AreaWeather" + "SkyWeather")
    ├── Part      (tag "SkyWeather": the cloud layer)
    ├── Part      (tag "AreaWeather": the rain over the playable area)
    └── Lighting  (Folder)
```

`WeatherService` clones the Model into `workspace.Weather`, fits **each part** to the loaded map's box, and passes the `Lighting` folder to [`LightingService`](lighting.md), so a weather change uses the same interpolated transition as any other lighting change.

| Tag | What it does to the `Part` |
| --- | --- |
| `AreaWeather` | becomes the whole box: `Size` and `Position` |
| `SkyWeather` | takes the box's X and Z size, centered on X/Z, with Y at the top of the box plus `SkyHeightOffset`; the part's height stays as authored, since it is the layer's thickness |

**A weather can be both kinds.**
Rain has a cloud layer in the sky and rain falling in the playable area, and each measures a different box (the sky measures the whole map; the area measures only `Terrain` and `Path`).
The Model carries both tags and **each part carries its own**; the two parts in `Rain` are both named `Part`, and the tag tells them apart.
Each kind of box is measured at most once.

A single-kind weather needs no tags on its parts: the Model's tag applies to all of them.
In a two-kind weather, a part without a tag is refused with a warning and the rest of the weather still enters.

The map box is the map's `BoundingBox` part (see [Maps](../game/maps.md#bounding-box)).
The sky offset comes from `WeatherConfig.SkyHeightOffset` (20), and a Model can override it with a `HeightOffset` attribute.
The Thunder particles have `Drag = 12` against `Accel.Y = -15`, a terminal speed of about 1.2 studs/s, so the layer barely falls and stays where the offset puts it.

The weather is server-authoritative: the clone lives in `workspace.Weather` and replicates to everyone, one weather at a time.
Every BasePart in the clone becomes intangible (`CanCollide`, `CanQuery`, and `CanTouch` off): the assets ship with `CanCollide = true`, and a part stretched over the map would become an invisible wall and pollute the footstep raycast and the placement check.

`Clear` restores the lighting from before the **first** weather, not the previous weather: switching from Snow to Thunder and then off returns to the map's lighting.

### Sound

Particles and lighting reach the client by themselves (the first through `workspace.Weather`, the second through `LightingApplied`).
Sound is local to each client, and `WeatherController` handles it by listening to the `WeatherChanged` event that `Apply` and `Clear` broadcast.

- **Ambience:** while a weather is on, its loop from `WeatherConfig.Ambience` plays through [`MusicController`](audio.md), fading in and out.
  Today only `Thunder` has one (`Thunderstorm`, 2 s fade).
  Switching between two weathers with ambience crossfades them.
  The ambience is forced to `Looped = true` (the asset is not looped) and only stops through `StopSFX(AmbienceKey, fade)`.
- **Lightning strikes:** each strike plays its own clone of `Thunder` with `FadeOut = 1` and no `Key`, so two strikes in a row overlap instead of cutting each other.
  The sound is created **inside the bolt's tip attachment**, so it is 3D and comes from the impact point.
  `VFXController` calls `WeatherController:PlayStrikeSound` because it owns the anchor; the audio policy (which sound, which fade, which volume) stays in `WeatherController`.
  `StrikeVolume` exists because the asset has `RollOffMinDistance = 10` and the tower defense camera sits far from the ground.
  The sound clone dies with the beam, which is destroyed after `Duration + Cleanup`.

On the client, `WeatherController:GetCurrent()` is the current weather.

## Usage

```lua
local WeatherService = Framework:Get("WeatherService")

WeatherService:Apply("Snow")        -- default transition time
WeatherService:Apply("Thunder", 4)  -- over 4 s
WeatherService:Clear()              -- off, and restore the lighting from before
```

`Apply` and `Clear` return `(ok, message)`; the message is what the `weather` [admin command](admin-commands.md) prints.

```text
weather <weather|off> [seconds]
```

## Configuration

| Key | Value | Effect |
| --- | --- | --- |
| `WeatherConfig.Tags.Area` / `Tags.Sky` | `"AreaWeather"` / `"SkyWeather"` | How a part fits the map |
| `WeatherConfig.SkyHeightOffset` | `20` | Studs above the box top for sky parts; overridden by the Model's `HeightOffset` attribute |
| `WeatherConfig.Ambience` | `Thunder = { Sound = "Thunderstorm", Fade = 2 }` | Ambient loop per weather |
| `WeatherConfig.AmbienceKey` | `"WeatherAmbience"` | `MusicController` key of the ambient loop |
| `WeatherConfig.Thunder.StrikeVolume` | `1` | Volume multiplier for strikes |
| `WeatherConfig.BoundsPartName`, `BoundsFolders`, `MaxPartFootprint` | see [Maps](../game/maps.md#configuration) | How the map box is found or measured |

## Studio setup

- A weather is a Model in `Assets.Weathers` tagged `AreaWeather`, `SkyWeather`, or both.
- In a two-kind weather, tag every part.
- An optional `Lighting` folder inside the Model is applied as a lighting preset.
