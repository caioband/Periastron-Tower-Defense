local ContentProvider = game:GetService("ContentProvider")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Signal = require(Packages.Signal)
local Me = require(Vendor.Me)
local Log = require(Shared:WaitForChild("Util"):WaitForChild("Log"))

local Framework = Me.new()
local log = Log.new("MusicController")

--[[
	Game audio, shared by both places. The SharedSounds Package separates the two
	uses, and the controller handles each the way it asks:

		SoundService.SharedSounds
		├── Musics   one track at a time, with fade/crossfade: :Play, :Transition
		└── SFX      short, overlapping effects:             :PlaySFX

	Both can have subfolders (Musics.Maps.Forest, SFX.UI.Click...): the lookup is
	recursive and uses only the Sound's name, so the name must be unique within the
	folder.

	Music plays the instance itself, not a clone: Sound:Play() on the client does not
	replicate, and this way the Volume/SoundGroup tuned in Studio still applies. The
	volume it had the first time the track plays becomes the "base" volume;
	everything the controller does (fade, master, mute, duck) is a multiplier on top.

		local Sound = Framework:Get("MusicController")
		Sound:Transition("Snowy", 2)
		Sound:PlaySFX("UnitPlace")

	A track's final volume = base * (the :Play override) * master * duck, or 0 when
	muted. Any change to these factors is reapplied to whatever is already playing.

	SFX is the opposite: always a clone, because two shots can play together and the
	original must not get stuck in a Play. The clone destroys itself at the end.

	It lives in common/ because Me scans Controllers.Common in both places; the
	module name must be unique between Common and the place's folder.

	See docs/common/audio.md.
--]]

local SHARED_SOUNDS = "SharedSounds"
local MUSICS_FOLDER = "Musics"
local SFX_FOLDER = "SFX"

-- Fade time when the caller does not say.
local DEFAULT_FADE = 1.5
local DEFAULT_VOLUME_FADE = 0.35

-- How long to wait for the folder before giving up and warning. It cannot be a
-- WaitForChild at the top of the file: that would block the whole client's Me:Load().
local FOLDER_TIMEOUT = 15

-- An SFX that never loaded does not fire Ended; without this the clone would stay
-- hanging on its parent forever.
local SFX_FALLBACK_LIFETIME = 15

export type PlayOptions = {
	Fade: number?, -- fade in, in seconds (0 = no fade)
	Volume: number?, -- multiplier on top of the Studio volume
	Looped: boolean?, -- default true
	Speed: number?, -- PlaybackSpeed
	StartTime: number?, -- TimePosition inicial
	Restart: boolean?, -- true = restart even if the track is already current
}

export type PlaylistOptions = {
	Shuffle: boolean?, -- shuffles the order (and reshuffles every loop)
	Loop: boolean?, -- default true; false makes the queue end in silence
	Fade: number?,
	Volume: number?,
}

export type SFXOptions = {
	Parent: Instance?, -- a Part/Attachment makes the sound 3D; default SoundService (2D)
	Volume: number?, -- multiplier on top of the Studio volume
	Speed: number?, -- PlaybackSpeed
	Looped: boolean?, -- requires Key or Cut to clean up afterward
	Cut: number?, -- cuts at N seconds, even if the track is longer
	Key: string?, -- only one live sound per key: the new one stops the previous
	Fade: number?, -- fade in, in seconds (0 = no fade)
	FadeOut: number?, -- fade at the end, finishing with the sound (or with Cut)
}

local MusicController = {}

-- Fired as (name, sound). TrackEnded only fires when the track ends on its
-- own; :Stop() does not count as an end.
MusicController.TrackChanged = Signal.new()
MusicController.TrackEnded = Signal.new()

MusicController.Current = nil :: Sound?
MusicController.CurrentName = nil :: string?

MusicController._Folders = {} :: { [string]: Instance }
MusicController._SFXMaster = 1
MusicController._ActiveSFX = {} :: { [string]: Sound } -- by Key
MusicController._Base = {} :: { [Sound]: number } -- original Studio volume
MusicController._Override = {} :: { [Sound]: number } -- :Play multiplier
MusicController._Fades = {} :: { [Sound]: Tween }
MusicController._Master = 1
MusicController._Duck = 1
MusicController._Muted = false
MusicController._EndedConn = nil :: RBXScriptConnection?
MusicController._Playlist = nil :: { string }?
MusicController._PlaylistIndex = 0
MusicController._PlaylistOptions = nil :: PlaylistOptions?

-- Track saved by PushTrack. nil = nothing saved; false = it was silent at push
-- time, so Pop returns to silence.
MusicController._PushedFrom = nil :: (string | boolean)?

--[[ FOLDERS ]]

-- Resolves SoundService.SharedSounds.<folder> only the first time it is needed.
function MusicController:_getFolder(folderName: string): Instance?
	local cached = self._Folders[folderName]
	if cached and cached.Parent then
		return cached
	end

	local sharedSounds = SoundService:WaitForChild(SHARED_SOUNDS, FOLDER_TIMEOUT)
	if not sharedSounds then
		log:StudioWarn(`SoundService.{SHARED_SOUNDS} did not show up.`)
		return nil
	end

	local folder = sharedSounds:WaitForChild(folderName, FOLDER_TIMEOUT)
	if not folder then
		log:StudioWarn(`SoundService.{SHARED_SOUNDS}.{folderName} did not show up.`)
		return nil
	end

	self._Folders[folderName] = folder
	return folder
end

function MusicController:GetFolder(): Instance?
	return self:_getFolder(MUSICS_FOLDER)
end

function MusicController:GetSFXFolder(): Instance?
	return self:_getFolder(SFX_FOLDER)
end

--[=[
	Downloads the SFX now, so their first `PlaySFX` does not wait for the audio.

	`Sound:Play()` on an asset that has not arrived yet does not fail: it **waits**,
	and plays when the download finishes. For a background effect that goes
	unnoticed, but for a sound that confirms an action (a shop purchase) the delay is
	the whole answer: the player clicks, the crate enters the inventory, and the
	sound arrives later.

	It returns nothing and does not block the caller: it runs on its own thread,
	because `PreloadAsync` yields. A name that does not exist warns and the others
	continue: preloading is an optimization, and failing at it must not stop the
	sound from playing later.
]=]
function MusicController:PreloadSFX(names: { string })
	task.spawn(function()
		local sounds = {}

		for _, name in names do
			local sound = self:GetSFX(name)

			if sound then
				table.insert(sounds, sound)
			else
				log:StudioWarn(`SFX "{name}" does not exist, so it cannot be preloaded.`)
			end
		end

		if #sounds == 0 then
			return
		end

		local ok, err = pcall(function()
			ContentProvider:PreloadAsync(sounds)
		end)

		if not ok then
			log:StudioWarn(`failed to preload SFX: {err}`)
			return
		end

		for _, sound in sounds do
			if not sound.IsLoaded then
				log:StudioWarn(`{sound.Name} ({sound.SoundId}) did not load; its first play may be late.`)
			end
		end
	end)
end

--[[
	What is at the root of SoundService, **outside the Package**: a loose Sound or a
	Sound inside a loose folder.

	The folder exists because a single-place sound sometimes has variants: the Lobby
	shop's `BuySFX` is a folder with `Coins` and `Shards`, one for each currency a
	crate can cost. A folder is the natural place for that, and without these two
	lookup levels it would leave the effect silent: `BuySFX` would find a `Folder`,
	which is not a `Sound`.

	**`SharedSounds` is left out of the sweep, and that is where it stops being
	recursive.** Going into it would find again what the folder lookup already
	covers, and a name repeated on both ends would depend on tree order. Among loose
	sounds the same rule applies as inside the Package: the name must be unique.
]]
function MusicController:_findLoose(name: string): Sound?
	local direct = SoundService:FindFirstChild(name)
	if direct and direct:IsA("Sound") then
		return direct
	end

	for _, child in SoundService:GetChildren() do
		if child.Name == SHARED_SOUNDS or not child:IsA("Folder") then
			continue
		end

		local sound = child:FindFirstChild(name)
		if sound and sound:IsA("Sound") then
			return sound
		end
	end

	return nil
end

--[[
	Finds the Sound by name inside the folder and, if it is not there, **at the
	SoundService root**.

	The root is the second place on purpose. `SharedSounds` is a Package, so adding a
	sound inside it is a package change both places load, and an effect only one place
	uses (`BuySFX`, from the Lobby shop) does not need that. The sound sits loose next
	to the Package and is still found by name like any other; see `_findLoose`.

	This does not make an exception to the rule that nothing reads `SoundService`
	directly: only this controller reads the root, and callers still ask by name.
]]
function MusicController:_find(folder: Instance?, name: string): Sound?
	if folder then
		local sound = folder:FindFirstChild(name, true)
		if sound and sound:IsA("Sound") then
			return sound
		end
	end

	return self:_findLoose(name)
end

-- Recursive lookup: the track may be in a subfolder of Musics.
function MusicController:GetTrack(name: string): Sound?
	return self:_find(self:GetFolder(), name)
end

function MusicController:GetSFX(name: string): Sound?
	return self:_find(self:GetSFXFolder(), name)
end

-- Names of everything that can play, useful for playlist/random.
function MusicController:GetTrackNames(): { string }
	local names = {}

	local folder = self:GetFolder()
	if not folder then
		return names
	end

	for _, inst in folder:GetDescendants() do
		if inst:IsA("Sound") then
			table.insert(names, inst.Name)
		end
	end

	return names
end

--[[ VOLUME ]]

function MusicController:_baseVolume(sound: Sound): number
	local base = self._Base[sound]
	if not base then
		base = sound.Volume
		self._Base[sound] = base
	end

	return base
end

function MusicController:_targetVolume(sound: Sound): number
	if self._Muted then
		return 0
	end

	return self:_baseVolume(sound) * (self._Override[sound] or 1) * self._Master * self._Duck
end

--[[
	Discards the fade running on the track. Important before playing again: a pending
	fade-out would call its :Stop on the track that just came back. A canceled tween
	does not run Completed as Completed, so the old fade's callback dies with it.
]]
function MusicController:_cancelFade(sound: Sound)
	local existing = self._Fades[sound]
	if existing then
		existing:Cancel()
		self._Fades[sound] = nil
	end
end

-- Cancelable fade: a new fade on the same Sound discards the previous one, or the
-- two fight over the property and the volume ends up anywhere.
function MusicController:_fade(sound: Sound, target: number, duration: number?, onComplete: (() -> ())?)
	self:_cancelFade(sound)

	local time = duration or 0
	if time <= 0 then
		sound.Volume = target
		if onComplete then
			onComplete()
		end
		return
	end

	local tween = TweenService:Create(sound, TweenInfo.new(time, Enum.EasingStyle.Linear), { Volume = target })
	self._Fades[sound] = tween

	tween.Completed:Connect(function(state)
		if self._Fades[sound] == tween then
			self._Fades[sound] = nil
		end
		if state == Enum.PlaybackState.Completed and onComplete then
			onComplete()
		end
	end)

	tween:Play()
end

-- Reapplies the volume of everything playing (after changing master/duck/mute).
function MusicController:_refreshVolumes(fade: number?)
	for sound in self._Base do
		if sound.Parent and (sound.IsPlaying or sound.IsPaused) then
			self:_fade(sound, self:_targetVolume(sound), fade)
		end
	end
end

--[[ PLAYBACK ]]

function MusicController:_clearEnded()
	if self._EndedConn then
		self._EndedConn:Disconnect()
		self._EndedConn = nil
	end
end

function MusicController:_setCurrent(sound: Sound?, name: string?)
	self.Current = sound
	self.CurrentName = name

	if sound and name then
		self.TrackChanged:Fire(name, sound)
	end
end

--[[
	Plays a track. If it is already current and playing, does nothing, unless
	Restart = true. That keeps the map from restarting its own music every time the
	server resends its name.
]]
function MusicController:Play(name: string, options: PlayOptions?): Sound?
	return self:_play(name, options, "user")
end

--[[
	`source` says who asked, and it decides what survives the switch:

		"user"      a manual :Play: it outranks everything, cancels the queue, and
		            drops the track saved by PushTrack
		"playlist"  the queue advancing itself, which must not cancel itself
		"push"/"pop" a temporary switch, which must not erase what it saved
]]
function MusicController:_play(name: string, options: PlayOptions?, source: string?): Sound?
	local opts: PlayOptions = options or {}

	local sound = self:GetTrack(name)
	if not sound then
		log:StudioWarn(`track "{name}" does not exist in {SHARED_SOUNDS}.{MUSICS_FOLDER}.`)
		return nil
	end

	if sound == self.Current and sound.IsPlaying and not opts.Restart then
		return sound
	end

	if source ~= "playlist" then
		self:_stopPlaylist()
	end

	if source == "user" then
		self._PushedFrom = nil
	end

	if self.Current and self.Current ~= sound then
		self:_stopSound(self.Current, opts.Fade or DEFAULT_FADE)
	end

	self:_clearEnded()
	self:_baseVolume(sound)
	self:_cancelFade(sound)
	self._Override[sound] = opts.Volume

	sound.Looped = if opts.Looped == nil then true else opts.Looped
	sound.PlaybackSpeed = opts.Speed or sound.PlaybackSpeed
	sound.TimePosition = opts.StartTime or 0

	local target = self:_targetVolume(sound)
	local fade = opts.Fade or 0
	sound.Volume = if fade > 0 then 0 else target
	sound:Play()

	if fade > 0 then
		self:_fade(sound, target, fade)
	end

	self._EndedConn = sound.Ended:Connect(function()
		if self.Current ~= sound then
			return
		end
		self.TrackEnded:Fire(name, sound)
		self:_advancePlaylist()
	end)

	self:_setCurrent(sound, name)
	return sound
end

--[[
	Switches tracks with a crossfade: the current one fades out while the new one
	fades in, over the same time. If nothing is playing, it is just a fade in.
]]
function MusicController:Transition(name: string, fadeTime: number?, options: PlayOptions?): Sound?
	local opts: PlayOptions = table.clone(options or {})
	opts.Fade = fadeTime or opts.Fade or DEFAULT_FADE

	local sound = self:GetTrack(name)
	if sound and sound == self.Current and sound.IsPlaying and not opts.Restart then
		return sound
	end

	return self:Play(name, opts)
end

--[[
	A temporary switch: saves the playing track and plays on top of it. That is the
	boss music case: :PopTrack brings back the previous one without the caller
	needing to remember which it was.

		Music:PushTrack("Boss")   -- a boss wave started
		Music:PopTrack()          -- next wave without a boss, the map's returns

	Repeated pushes do not stack: the second sees the track is already current and
	leaves without touching what was saved, so back-to-back boss waves still return
	to the right music. If nothing was playing at push time, Pop returns to silence.
]]
function MusicController:PushTrack(name: string, fadeTime: number?, options: PlayOptions?): Sound?
	if self.CurrentName == name then
		return self.Current
	end

	if self._PushedFrom == nil then
		self._PushedFrom = self.CurrentName or false
	end

	local opts: PlayOptions = table.clone(options or {})
	opts.Fade = fadeTime or opts.Fade or DEFAULT_FADE

	return self:_play(name, opts, "push")
end

function MusicController:PopTrack(fadeTime: number?): Sound?
	local previous = self._PushedFrom
	if previous == nil then
		return nil
	end

	self._PushedFrom = nil

	-- false: there was no music when the push happened.
	if type(previous) ~= "string" then
		self:Stop(fadeTime or DEFAULT_FADE)
		return nil
	end

	return self:_play(previous, { Fade = fadeTime or DEFAULT_FADE }, "pop")
end

function MusicController:IsPushed(): boolean
	return self._PushedFrom ~= nil
end

--[[
	Fade out + Stop. At the end it restores the Studio volume and drops that :Play's
	override: the instance is shared, so it must return exactly as it was (or the
	track comes back muted, or with another call's volume).
]]
function MusicController:_stopSound(sound: Sound, fadeTime: number?)
	local restore = self:_baseVolume(sound)

	-- Without a fade, _fade resolves immediately and the callback runs before returning.
	self:_fade(sound, 0, fadeTime, function()
		sound:Stop()
		sound.TimePosition = 0
		sound.Volume = restore
		self._Override[sound] = nil
	end)
end

-- Stops the current track. Without fadeTime, it cuts.
function MusicController:Stop(fadeTime: number?)
	self:_stopPlaylist()
	self:_clearEnded()
	self._PushedFrom = nil

	local current = self.Current
	if not current then
		return
	end

	self:_stopSound(current, fadeTime)
	self:_setCurrent(nil, nil)
end

-- Safety net: stops any track this controller has played.
function MusicController:StopAll(fadeTime: number?)
	self:_stopPlaylist()
	self:_clearEnded()
	self._PushedFrom = nil

	for sound in self._Base do
		if sound.Parent and (sound.IsPlaying or sound.IsPaused) then
			self:_stopSound(sound, fadeTime)
		end
	end

	self:_setCurrent(nil, nil)
end

-- Pauses while keeping the position; :Resume() continues where it stopped.
function MusicController:Pause(fadeTime: number?)
	local current = self.Current
	if not current or not current.IsPlaying then
		return
	end

	if fadeTime and fadeTime > 0 then
		self:_fade(current, 0, fadeTime, function()
			current:Pause()
		end)
	else
		current:Pause()
	end
end

function MusicController:Resume(fadeTime: number?)
	local current = self.Current
	if not current or current.IsPlaying then
		return
	end

	local target = self:_targetVolume(current)
	if fadeTime and fadeTime > 0 then
		current.Volume = 0
		current:Resume()
		self:_fade(current, target, fadeTime)
	else
		current.Volume = target
		current:Resume()
	end
end

function MusicController:TogglePause(fadeTime: number?)
	local current = self.Current
	if not current then
		return
	end

	if current.IsPlaying then
		self:Pause(fadeTime)
	else
		self:Resume(fadeTime)
	end
end

-- Restarts from the beginning without switching tracks.
function MusicController:Restart(fadeTime: number?)
	local current = self.Current
	if not current then
		return
	end

	self:_cancelFade(current)
	current.TimePosition = 0

	if not current.IsPlaying then
		current.Volume = if fadeTime and fadeTime > 0 then 0 else self:_targetVolume(current)
		current:Play()
	end

	if fadeTime and fadeTime > 0 then
		current.Volume = 0
		self:_fade(current, self:_targetVolume(current), fadeTime)
	end
end

function MusicController:Seek(timePosition: number)
	local current = self.Current
	if not current then
		return
	end

	current.TimePosition = math.clamp(timePosition, 0, current.TimeLength)
end

function MusicController:SetSpeed(speed: number)
	local current = self.Current
	if current then
		current.PlaybackSpeed = speed
	end
end

--[[ MASTER / MUTE / DUCK ]]

-- Overall music volume, 0 to 1, multiplied on top of the Studio volume.
function MusicController:SetVolume(scale: number, fadeTime: number?)
	self._Master = math.max(scale, 0)
	self:_refreshVolumes(fadeTime or DEFAULT_VOLUME_FADE)
end

function MusicController:GetVolume(): number
	return self._Master
end

function MusicController:Mute(fadeTime: number?)
	if self._Muted then
		return
	end

	self._Muted = true
	self:_refreshVolumes(fadeTime or DEFAULT_VOLUME_FADE)
end

function MusicController:Unmute(fadeTime: number?)
	if not self._Muted then
		return
	end

	self._Muted = false
	self:_refreshVolumes(fadeTime or DEFAULT_VOLUME_FADE)
end

function MusicController:ToggleMute(fadeTime: number?): boolean
	if self._Muted then
		self:Unmute(fadeTime)
	else
		self:Mute(fadeTime)
	end

	return self._Muted
end

function MusicController:IsMuted(): boolean
	return self._Muted
end

--[[
	Lowers the music temporarily without touching the volume the player chose: for a
	cutscene, dialog, boss spawn. :Unduck() restores it.
]]
function MusicController:Duck(scale: number, fadeTime: number?)
	self._Duck = math.clamp(scale, 0, 1)
	self:_refreshVolumes(fadeTime or DEFAULT_VOLUME_FADE)
end

function MusicController:Unduck(fadeTime: number?)
	self._Duck = 1
	self:_refreshVolumes(fadeTime or DEFAULT_VOLUME_FADE)
end

--[[ QUEUE ]]

function MusicController:_stopPlaylist()
	self._Playlist = nil
	self._PlaylistIndex = 0
	self._PlaylistOptions = nil
end

function MusicController:_advancePlaylist()
	local list = self._Playlist
	local opts = self._PlaylistOptions
	if not list or not opts then
		return
	end

	local index = self._PlaylistIndex + 1
	if index > #list then
		if opts.Loop == false then
			self:_stopPlaylist()
			self:_setCurrent(nil, nil)
			return
		end

		index = 1
		if opts.Shuffle then
			self:_shuffle(list)

			--[[
				The queue's wraparound is the only seam where the same track can play twice
				in a row: the new shuffle does not know which was last in the previous round
				and may draw exactly that one for position 1. With two or more tracks, it
				swaps places with any other.
			]]
			if #list > 1 and list[1] == self.CurrentName then
				local swap = math.random(2, #list)
				list[1], list[swap] = list[swap], list[1]
			end
		end
	end

	self._PlaylistIndex = index
	self:_play(list[index], {
		Fade = opts.Fade or DEFAULT_FADE,
		Volume = opts.Volume,
		Looped = false,
		Restart = true,
	}, "playlist")
end

function MusicController:_shuffle(list: { string })
	for i = #list, 2, -1 do
		local j = math.random(i)
		list[i], list[j] = list[j], list[i]
	end
end

--[[
	Plays a sequence of tracks, advancing on its own when each ends. Without `names`,
	it uses everything in Musics. Loop = false makes the queue end in silence;
	Shuffle reshuffles every loop.
]]
function MusicController:PlayPlaylist(names: { string }?, options: PlaylistOptions?)
	local opts: PlaylistOptions = options or {}
	local list = if names then table.clone(names) else self:GetTrackNames()

	if #list == 0 then
		log:StudioWarn("empty playlist.")
		return
	end

	if opts.Shuffle then
		self:_shuffle(list)
	end

	self._Playlist = list
	self._PlaylistOptions = opts
	self._PlaylistIndex = 0

	self:_advancePlaylist()
end

-- Skips to the next in the queue by hand.
function MusicController:Next()
	if not self._Playlist then
		return
	end

	self:_advancePlaylist()
end

-- A random track, no queue.
function MusicController:PlayRandom(names: { string }?, options: PlayOptions?): Sound?
	local list = names or self:GetTrackNames()
	if #list == 0 then
		return nil
	end

	return self:Play(list[math.random(#list)], options)
end

--[[ SFX ]]

--[[
	Plays an effect from SoundService.SharedSounds.SFX. Always on a clone that
	destroys itself when done: two identical effects can overlap without one cutting
	the other, and the original Sound never gets stuck playing.

		Sound:PlaySFX("UnitPlace")                                  -- 2D
		Sound:PlaySFX("Explosion", { Parent = mine.PrimaryPart })   -- 3D, in place
		Sound:PlaySFX("Beep", { Key = "Tripmine" })                 -- stops the previous

	With Looped, pass Key or Cut: without one of them nothing cleans up the clone.

		Sound:PlaySFX("Thunderstorm", { Looped = true, Key = "Weather", Fade = 2 })
		Sound:StopSFX("Weather", 2)                                 -- fades out
]]
function MusicController:PlaySFX(name: string, options: SFXOptions?): Sound?
	local opts: SFXOptions = options or {}

	local template = self:GetSFX(name)
	if not template then
		log:StudioWarn(`SFX "{name}" does not exist in {SHARED_SOUNDS}.{SFX_FOLDER} nor loose at the root of SoundService.`)
		return nil
	end

	if opts.Key then
		self:StopSFX(opts.Key)
	end

	local sound = template:Clone()
	local volume = template.Volume * (opts.Volume or 1) * self._SFXMaster
	local fadeIn = opts.Fade or 0
	local fadeOut = opts.FadeOut or 0

	sound.Volume = if fadeIn > 0 then 0 else volume
	sound.PlaybackSpeed = opts.Speed or template.PlaybackSpeed
	sound.Looped = if opts.Looped == nil then template.Looped else opts.Looped
	sound.Parent = opts.Parent or SoundService
	sound:Play()

	if fadeIn > 0 then
		self:_fade(sound, volume, fadeIn)
	end

	if opts.Key then
		self._ActiveSFX[opts.Key] = sound
	end

	local function cleanup()
		-- The fade dies too: a tween hanging on a destroyed Sound never finishes,
		-- and its entry in `_Fades` would keep holding the instance.
		self:_cancelFade(sound)

		if opts.Key and self._ActiveSFX[opts.Key] == sound then
			self._ActiveSFX[opts.Key] = nil
		end
		if sound.Parent then
			sound:Destroy()
		end
	end

	-- The end, with the fade when requested. Without FadeOut it is the usual hard cut.
	local function finish()
		if fadeOut > 0 and sound.Parent and sound.IsPlaying then
			self:_fade(sound, 0, fadeOut, cleanup)
		else
			cleanup()
		end
	end

	if opts.Cut then
		-- The fade ends together with the cut, not after it.
		task.delay(math.max(0, opts.Cut - fadeOut), finish)
	elseif not sound.Looped then
		-- Ended on its own: no tail left to smooth, so it is straight cleanup.
		sound.Ended:Once(cleanup)

		-- TimeLength is only reliable after the sound loads; 0 means it has not yet,
		-- so it falls back to the fixed time.
		local playFor = if sound.TimeLength > 0
			then sound.TimeLength / math.max(sound.PlaybackSpeed, 0.01)
			else SFX_FALLBACK_LIFETIME

		if fadeOut > 0 then
			task.delay(math.max(0, playFor - fadeOut), finish)
		end
		task.delay(playFor + 1, cleanup)
	end

	return sound
end

--[[
	Stops the SFX alive on that Key (usually the longer Looped one).

	`fadeTime` turns it off with a fade instead of cutting: that is what a looping
	ambience needs when leaving. `PlaySFX` calls it without a fade on purpose: when
	the same Key is reused, the new sound must replace the old one immediately.
]]
function MusicController:StopSFX(key: string, fadeTime: number?)
	local sound = self._ActiveSFX[key]
	if not sound then
		return
	end

	self._ActiveSFX[key] = nil

	if not sound.Parent then
		return
	end

	if fadeTime and fadeTime > 0 then
		self:_fade(sound, 0, fadeTime, function()
			if sound.Parent then
				sound:Stop()
				sound:Destroy()
			end
		end)
		return
	end

	self:_cancelFade(sound)
	sound:Stop()
	sound:Destroy()
end

-- Overall effects volume, separate from music. Applies to the next :PlaySFX calls.
function MusicController:SetSFXVolume(scale: number)
	self._SFXMaster = math.max(scale, 0)
end

function MusicController:GetSFXVolume(): number
	return self._SFXMaster
end

--[[ STATE ]]

function MusicController:IsPlaying(name: string?): boolean
	local current = self.Current
	if not current then
		return false
	end

	if name and self.CurrentName ~= name then
		return false
	end

	return current.IsPlaying
end

function MusicController:GetCurrent(): (string?, Sound?)
	return self.CurrentName, self.Current
end

--[[ COMPATIBILITY / EVENTS ]]

-- The old name, kept so existing callers do not break.
function MusicController:playMusic(name: string)
	self:Play(name, { Fade = DEFAULT_FADE })
end

-- Called by Game's LoadingController when the loading screen leaves.
function MusicController:OnLoadingComplete()
	Framework:Fire("RequestMapMusic")
end

function MusicController:construct()
	-- Only Game answers: MapService returns the loaded map's name.
	Framework:Listen("PlayMapMusic", function(name: string)
		if type(name) ~= "string" then
			return
		end
		self:Transition(name)
	end)
end

function MusicController:start() end

function MusicController:init()
	self:construct()
end

return MusicController
