# Cutscenes

`CutsceneController` plays cutscenes authored in Moon Animator or Eclipse Animator, on the client, without any `AnimationId`.
`CutsceneFormat` reads both animators' files and packs them into a small blob.

**Runs in:** Game · Lobby
**Code:** [`CutsceneController`](../../common/client/Controllers/CutsceneController.luau), [`CutsceneFormat`](../../common/shared/Util/CutsceneFormat.luau)

## How it works

A scene is a Model.
`playCutscene(scene, origin)` puts the scene's reference (`SceneReferenceCFrame`) on `origin` and plays the scene from there.
While the scene plays, the controller does the following:

- the camera is `Scriptable` and the character controls are locked;
- the interface is hidden through [`InterfaceController`](interface-visibility.md);
- players' characters, billboards, and highlights are hidden locally.

Everything comes back when the scene ends.

Joints are animated by writing `Motor6D.C1` every frame, the same way the animators do in the editor.
The camera comes from the camera rig's `CamPart` joint, so it follows the scene wherever it plays.

`FrameReached(frame, lastFrame, asset)` fires once per scene frame.
The Lobby portal uses it to start its flash before the end.

### Moon Animator scenes (format 1)

The rigs and the save Folders (`1`, `2`, ...) sit at the root of the Model.
Rigs that are not in the Workspace are cloned in for the scene and destroyed after it.
A rig already in the Workspace is used in place, and its pose and pivot are restored afterward.
The Lobby's `EnterCutscene` works this way.

### Eclipse Animator scenes (format 2)

The whole scene plays on a **stage**: a clone of the Model, on this client only, moved so that its reference lands on `origin`.
The scenery, the rigs, and the camera rig move together, which keeps the authored framing.
The clone is destroyed at the end, and the original is never touched.

Each Pose in Eclipse is the joint's `Transform`.
The player turns it into C1 with `C1 = restC1 * Transform:Inverse()`, which puts every part where Roblox would.
A weapon that leaves a character's hand (`EclipseParented = false`) needs no special case.
Eclipse bakes it into the Transform, and the result lands on the `DetachedWorldCFrame` that Eclipse recorded, within 0.03 studs.

On top of the joints, an Eclipse scene plays the following:

| Feature | Source in Eclipse | What the player does |
| --- | --- | --- |
| FOV | `FovPart` pose: Y is the FOV minus 70 | Writes `Camera.FieldOfView` |
| Moving root | The rig's `CFrame` property track | Moves the whole rig with `PivotTo` |
| Screen Cover | The effect's property tracks | Shows a full-screen `Frame`: color, transparency, size, position, rotation |
| Camera Shake | `Strength` and `Speed` tracks | Adds noise to the camera: `Strength` × 0.2 studs and × 1.2° |
| Subtitles | The project's `EclipseEvents` | Shows text in a box, with speaker, font, colors, outline, and position |
| Lighting | The scene's `Lighting` folder | Takes over `Lighting` during the scene, then restores it |

The Screen Cover and the subtitles draw on a `CutsceneOverlay` ScreenGui marked `IgnoreInterfaceHide`.

## Usage

```lua
local CutsceneController = Framework:Get("CutsceneController")

-- By name, from ReplicatedStorage.Shared.Assets.Cutscenes, where it is built:
CutsceneController:playCutscene("EnterCutscene")

-- By instance, moved: the scene's reference lands on `origin`.
local duration = CutsceneController:playCutscene(sceneModel, origin)
```

`playCutscene` returns the duration in seconds, or `nil` when the scene cannot play.
`holdCamera = true` (third argument) leaves the camera on the last frame until `releaseCamera()` is called.

### Dressing a rig as the player

```lua
local undress = CutsceneController:dressScene(sceneModel, Players.LocalPlayer, "numsei1", { ReplaceCostume = true })
CutsceneController:playCutscene(sceneModel, origin)
-- ... when the scene is over:
undress()
```

`dressScene` copies the player's clothing, body colors, face, and accessories onto the named rig.
It does not swap any Part, so an R15 player on an R6 rig works.
Call it **before** `playCutscene`: an Eclipse stage is cloned from the dressed scene.

`ReplaceCostume = true` is for a rig authored as a character of its own:

- parts welded to the body that are not body parts (3D clothing, a hair Part) turn invisible;
- body parts hidden under that clothing show again;
- only the first Decal on the Head stays, carrying the player's face.

Parts moved by a Motor6D (a weapon in the hand) stay, because the scene animates them.
The Lobby portal does not use the option: its rig is a plain body.

A rig dressed this way also plays its **legs upright**.
Eclipse lets an animator spin a limb 180° in place and move it back.
A plain R6 leg is a box, so nothing showed under the rig's 3D clothing, but the player's Pants show up upside down.
`numsei1`'s left leg points against its torso from frame 2370 to the end.
When a leg of a dressed rig points against its torso (`UpVector` below −0.5 in torso space), the player turns it 180° about its own center.
It picks the axis that keeps the leg's front closest to the torso's front.
The box stays exactly where it was, and the texture faces up.
Welds and Motor6Ds hanging on that leg get the inverse turn, so accessories do not move.
Arms are left alone, because a raised arm points down for real.

## Studio setup

### Eclipse: from the animation place to a playable scene

1. Assemble the scene in `ServerStorage.CutsceneSources` of the place that will play it:

   ```text
   <Scene>                   Model, attribute EclipseProject = project name in Eclipse
   ├── SceneReferenceCFrame  Part, attribute AuthoredCFrame = its CFrame when assembled
   ├── Camera - <project>    the Eclipse camera rig, with AnimSaves/<project>
   ├── Rigs                  the actors, each with AnimSaves/<project>
   ├── Effects               Screen Cover / Camera Shake Models, with AnimSaves/<project>
   ├── Subtitles             copy of the project's EclipseSubtitles folder
   ├── Set                   scenery
   └── Lighting              preset folder (attributes + effects)
   ```

   Every rig and the camera must sit exactly where they were animated, relative to the reference.
   Move the Model as a whole, never a piece inside it.
   Do not delete `AuthoredCFrame`: the moving root tracks are stored relative to it.

2. Bake it from the command bar:

   ```lua
   print(require(game.ReplicatedStorage.Shared.Util.CutsceneFormat).BakeEclipseAll())
   ```

   Each scene in `ServerStorage.CutsceneSources` becomes a playable copy in `ServerStorage.Cutscenes`.
   The copy has no KeyframeSequences, effect Models, or subtitle folders.
   It gets a `SceneData` blob and a `Duration` attribute in seconds.
   `Cutscene1_Perieperifall` goes from 21,088 to 2,376 instances and a 196 KB blob.

   The bake refuses to write if the blob does not decode back to the same keys, or if the rotation round trip drifts.

3. Bake again after every change to the source.
   The source is never modified.

`ServerStorage["Eclipse Animator Saves"].EclipsePublish` is **not** a source.
Its KeyframeSequences carry no rig and no position.
They are what Eclipse uses to publish animations to Roblox.

### Moon Animator

Export into the scene Model, then bake with `CutsceneFormat.BakeAll(folder)`.
The save Folders become a `SceneData` blob.

## Design notes

- **No `AnimationId`.**
  Reading the save in runtime removes the upload, the first-play download, and the dependency on who owns the asset.
- **Keys are compressed at bake time.**
  Repeated keys that change nothing are dropped.
  An Eclipse rotation is stored as a quaternion, so each key takes 33 bytes instead of 51.
  The bake measures the round trip: the scenes in the Game drift 0.0000 studs, and sampling 74 thousand frames against the original KeyframeSequences differs by at most 0.0001 studs and 0.06°.
- **Easing goes on the destination key.**
  Eclipse and Roblox store a key's easing as the way *out* of it.
  The reader moves each one a key forward, so both formats sample the same way.
- **Bezier easing is solved by the player.**
  Eclipse's `Bezier` style is a CSS-style cubic curve with two control points (`BezierPoints`), and `TweenService:GetValue` refuses it.
  The reader stores it as `Bezier|x1,y1,x2,y2`, and `easeAlpha` solves the curve by bisection.
  Any other style `TweenService` refuses falls back to linear with a Studio warning.
  An error there used to stop the whole frame, which froze the camera when the final fade started.
- **Effects cannot freeze the scene.**
  The Screen Cover, Camera Shake, and subtitles run inside a `pcall`.
  If one of them fails, the camera and the actors keep playing.
- **Long blobs are split.**
  `SceneData` holds the first 100,000 characters, and its children (`Chunk002`, ...) hold the rest.

## Known issues

- Camera Shake is an approximation: Eclipse does not document its curve.
- Every subtitle entrance plays as a typewriter reveal with a fade, and every exit as a fade.
  Eclipse's presets (`Letter slide`, `Word spring`, ...) and per-word styles are not reproduced.
- Eclipse events with sounds or code are ignored.
  The scenes in the Game have none.
