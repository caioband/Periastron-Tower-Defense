# Lighting

Lighting presets applied by the server and smoothly interpolated by each client.

**Runs in:** Game · Lobby
**Code:** [`LightingService`](../../common/server/Services/LightingService.luau), [`LightingController`](../../common/client/Controllers/LightingController.luau), [`LightingUtil`](../../common/shared/Util/LightingUtil.luau), [`LightingConfig`](../../common/shared/Config/SharedConfig/LightingConfig.luau)

## Presets

A preset is a Folder in `ReplicatedStorage.Shared.Assets.Lighting`.
The Folder's **attributes** are properties of `Lighting` itself; its **children** are the instances that go inside `Lighting`:

```text
Assets.Lighting
└── Blizzard              (Folder)  attributes: Ambient, Brightness, ClockTime, FogColor…
    ├── Atmosphere        (Atmosphere)
    ├── Sky               (Sky)
    └── ColorCorrection   (ColorCorrectionEffect)
```

## How it works

### Server

`LightingService` clones the Folder, clears `Lighting`, and moves the clone's contents in.
The cut is instant: the server is the source of truth, and a player joining mid-match must get the final state directly.

Two conveniences:

- A loose Folder inside `Lighting` is adopted as a preset when the server starts (this is how the Main Game keeps `FoggyLightning` and `BlizzardLightning`).
- Whatever is left becomes the `Default` preset (`LightingConfig.BaselineName`), so the first change has something to start from.

A child of `Lighting` with the `LightingKeep = true` attribute survives the clear, and **both** sides respect it: `LightingService` skips those children, and `LightingController` leaves them out of the state it reads for the transition.
Without the second half, an effect that belongs to no preset (the `UIBlur` the shop turns on behind its panel) would become an *exiting* effect on the next change, and a ghost of it would appear over the one the panel is using.

`Register(folder, name)` clones an outside Folder into `Assets.Lighting` so clients can read it; [maps](../game/maps.md#map-lighting) and [weather](weather.md) use it.

### Client

`LightingController` does the smoothing.
When a change is announced (`LightingApplied`), it resets the properties to the previous preset's values and interpolates to the new one: `number`, `Color3`, `Vector3`, `UDim`, `NumberRange`, `Rect`, and `CFrame`.
What cannot interpolate (boolean, string, `EnumItem`, sequences) is a cut: **turning on** happens at the start of the transition, **turning off** waits for the end, so the effect takes part in it.

- **The start is the state the controller wrote last**, not what `Lighting` holds at that moment: by the time the notice arrives, the new value may have replicated over it.
  The target comes from the preset Folder for the same reason.
- An interrupted transition freezes where it is and becomes the start of the next one.
- An instance that exists in both presets **with the same name and class** is interpolated value by value.
- An instance that exists on only one side **also fades in or out**: `LightingConfig.Neutral` says, per class, which values mean "this effect is doing nothing" (`BlurEffect.Size = 0`, `Atmosphere.Density = 0`, …).
  An entering instance starts at neutral and rises to the preset value; an exiting one is recreated as a local copy (the server already destroyed the original), falls to neutral, and is destroyed.
  A class without a neutral (`Sky`) still enters at once, which is right: a texture has no halfway.

This matters: switching maps changes *which* effects exist much more than the values of the ones that stay.
On today's map lightings, it is the difference between 1 and 7 properties interpolating on `Snowy -> Volcano`.

The property list per class is maintained by hand, because Roblox has no runtime reflection.
A class not in the list still enters `Lighting` normally; it is just not interpolated.
In Studio, the controller logs how many properties entered each transition, because "interpolated little" and "did not interpolate" look the same on screen.

## Usage

```lua
local LightingService = Framework:Get("LightingService")

LightingService:Apply("Blizzard")       -- default transition time
LightingService:Apply("Foggy", 4)       -- 4 s transition
LightingService:Apply("Foggy", 0)       -- no transition
```

`GetPreset(name)`, `GetCurrent()`, and `Register(folder, name)` complete the API.
The `lighting` and `lightinglist` [admin commands](admin-commands.md#lighting-and-weather-commands) apply and inspect presets in game.

## Configuration

| Key | Effect |
| --- | --- |
| `LightingConfig.Transition` | Default transition time and easing |
| `LightingConfig.Properties` | Interpolated properties per class |
| `LightingConfig.Neutral` | "Doing nothing" values per class, for fading effects in and out |
| `LightingConfig.PresetsPath` | Where presets live (`Shared.Assets.Lighting`) |
| `LightingConfig.BaselineName` | Name of the preset built from what `Lighting` had (`"Default"`) |
| `LightingConfig.DefaultPreset` | Preset applied on server start, if any |
| `LightingConfig.MapPrefix` | Prefix of map presets (`"Map_"`) |
| `LightingConfig.KeepAttribute` | Attribute that protects a `Lighting` child (`"LightingKeep"`) |
