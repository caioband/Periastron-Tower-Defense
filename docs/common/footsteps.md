# Footsteps

`FootstepController` plays a footstep sound for the local character, chosen by the surface under the foot.

**Runs in:** Game · Lobby (client)
**Code:** [`FootstepController`](../../common/client/Controllers/FootstepController.luau), [`FootstepConfig`](../../common/shared/Config/SharedConfig/FootstepConfig.luau)

## How it works

There is no timer: an Animation Event (KeyframeMarker) named **`Step`** inside the Walk and Run animations sets the beat.
Any animation with that marker joins the system by itself; there is no list of animations in code.
The marker can carry `"Left"` or `"Right"` to pin the foot; without a value, the controller alternates.
Jumping and landing play their own sounds (`FootstepConfig.Jump`).

The surface does **not** come from `Material` (the game is built from studs, so Material says nothing).
It comes from the `Surface` attribute of the part a ray under the foot hits.
The attribute is also looked up on ancestors, so a whole Model can be marked at once:

```lua
part:SetAttribute("Surface", "Grass")   -- or on the Model that contains the parts
```

The sound ids for each surface are in `FootstepConfig.Surfaces`, with a list of variations per surface: one is drawn per step, never the same as the previous one.

A part without the attribute stays silent on purpose, so what is left to mark is noticeable instead of silently becoming grass.
In Studio, the controller warns once per unmarked part.

A step closer than `MinInterval` to the previous one is skipped.
If that happens often, it is a duplicated marker in the animation (or two tracks playing the same animation), not a sound problem.

## Configuration

| Key | Value | Effect |
| --- | --- | --- |
| `Attribute` | `"Surface"` | The attribute read from the part (or its ancestors) |
| `Default` | `nil` | Surface used for unmarked parts; `nil` keeps them silent |
| `RayLength` | `5` | Length of the ray under the foot |
| `Volume` / `PitchRange` | `0.5` / `{ 0.94, 1.06 }` | Base volume and random pitch |
| `MinInterval` | `0.1` | Minimum seconds between steps |
| `RollOffMin` / `RollOffMax` | `4` / `45` | 3D sound distance |
| `Surfaces` | per surface | Sound id variations |
| `Jump` | | Jump and landing sounds |

## Studio setup

- Add a `Step` KeyframeMarker to every walk and run animation.
- Set the `Surface` attribute on map parts or Models.
