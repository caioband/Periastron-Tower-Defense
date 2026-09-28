# Audio

All game audio goes through `MusicController`, which finds a `Sound` by name anywhere under `SoundService.SharedSounds`.
Nothing else reads the root of `SoundService` directly.

**Runs in:** Game · Lobby (client)
**Code:** [`MusicController`](../../common/client/Controllers/MusicController.luau), [`LobbyMusicController`](../../Lobby/src/Controllers/LobbyMusicController.luau)

## How it works

`SoundService.SharedSounds` is a Roblox Package (not managed by Rojo) with two folders, and the controller treats each the way it needs:

```text
SoundService.SharedSounds
├── Musics   one track at a time, with fade and crossfade   (:Play, :Transition)
└── SFX      short, overlapping effects                     (:PlaySFX)
```

Both can have subfolders (`Musics.Maps.Forest`, `SFX.UI.Click`, …): the search is recursive and uses only the Sound's name, so names must be unique within each folder.

**Music plays the original instance**, not a clone: `Sound:Play()` on the client does not replicate, and this keeps the Volume and SoundGroup set in Studio.
The volume the track had the first time it played becomes its **base**; everything the controller does (fade, master, mute, duck) multiplies on top.
Final volume = base × (the `:Play` override) × master × duck, or 0 when muted.
Any change to those factors reapplies to what is already playing.

**SFX always play a clone** that destroys itself at the end, so two identical effects can overlap.
An SFX that never loads never fires `Ended`, so a fallback lifetime (15 s) removes the clone anyway.

`Fade` and `FadeOut` work for SFX too.
`FadeOut` ends **with** the sound (or with its `Cut`), not after it: on a 3.63 s clip with `FadeOut = 1`, the fade starts at 2.63 s.
`StopSFX` without a time still cuts immediately, which is what `PlaySFX` uses when the same `Key` is reused, so the new sound starts at once.

The folder lookup waits up to 15 s (`FOLDER_TIMEOUT`) and then warns; it cannot be a top-level `WaitForChild`, which would block the whole client `Me:Load()`.

## Usage

```lua
local Sound = Framework:Get("MusicController")

Sound:Transition("Snowy", 2)                              -- music crossfade
Sound:Duck(0.3)                                           -- lower for a cutscene; :Unduck() restores
Sound:PlaySFX("UnitPlace")                                -- 2D effect
Sound:PlaySFX("SubspaceTripmineSFX", { Parent = root,     -- 3D, and the Key stops
                                       Key = "Tripmine" })--   the previous sound with the same key
Sound:PlaySFX("Thunderstorm", { Looped = true,            -- ambience: fades in
                                Key = "WeatherAmbience",
                                Fade = 2 })
Sound:StopSFX("WeatherAmbience", 2)                       -- and fades out
Sound:PlaySFX("Thunder", { FadeOut = 1 })                 -- smoothed tail at the end
```

| Group | Methods |
| --- | --- |
| Music | `Play`, `Transition`, `PushTrack` / `PopTrack` / `IsPushed`, `Stop`, `StopAll`, `Pause`, `Resume`, `TogglePause`, `Restart`, `Seek`, `SetSpeed`, `GetCurrent`, `IsPlaying` |
| Playlists | `PlayPlaylist(names, { Shuffle, Loop, Fade, Volume })`, `Next`, `PlayRandom` |
| Volume | `SetVolume`, `GetVolume`, `Mute`, `Unmute`, `ToggleMute`, `IsMuted`, `Duck`, `Unduck` |
| SFX | `PlaySFX(name, options)`, `StopSFX(key, fade)`, `PreloadSFX(names)`, `SetSFXVolume`, `GetSFXVolume` |
| Lookup | `GetTrack`, `GetSFX`, `GetTrackNames`, `GetFolder`, `GetSFXFolder` |

`PlayOptions`: `Fade`, `Volume`, `Looped` (default `true`), `Speed`, `StartTime`, `Restart`.
`SFXOptions`: `Parent` (a Part or Attachment makes it 3D; default `SoundService`, 2D), `Key`, `Fade`, `FadeOut`, `Looped`, `Volume`, and more; see the exported types in the module.

In the Lobby, `LobbyMusicController` plays the tracks in `SharedSounds.Musics.<folder>`.
In matches, map music comes from each map's `Music` in `MapConfig`, and weather ambience from [`WeatherController`](weather.md#sound).
