local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Configs = Shared:WaitForChild("Config")

local Me = require(Vendor.Me)
local Log = require(Shared:WaitForChild("Util"):WaitForChild("Log"))
local SharedConfig = require(Configs.SharedConfig)

local Framework = Me.new()
local log = Log.new("LobbyMusicController")

local EventCurrencyConfig = SharedConfig.EventCurrencyConfig

--[[
	Lobby music.

	It plays everything in `SoundService.SharedSounds.Musics.Lobby` in an endless
	queue: it fades in, and each track that ends gives way to the next with a
	transition. A new track in the game is just a matter of dropping the Sound in the
	folder: there is no name list here.

	**Event priority.** While the event is on (`EventCurrencyConfig.Enabled`), the
	`EVENT_TRACK` plays first on join and returns after every `EVENT_EVERY` other
	tracks, which rotate in a shuffled order. With the event off, `EVENT_TRACK` is
	left out and the queue is a plain shuffle of the rest.

	MusicController plays; this controller only resolves *what* to play. The rule of
	never repeating the track that just ended lives there, in `_advancePlaylist`, because
	it applies to any queue.

	See docs/common/audio.md.
]]

local FOLDER = "Lobby"
local FADE = 2

-- The event's lobby track, by Sound name inside `FOLDER`.
local EVENT_TRACK = "Halloween"

-- How many other tracks play between two plays of `EVENT_TRACK`.
local EVENT_EVERY = 1

-- HALLOWEEN EVENT OFF, but its music stays: the priority no longer follows
-- `EventCurrencyConfig.Enabled`. Swap back to it when the event currency returns.
-- local EVENT_MUSIC = EventCurrencyConfig.Enabled
local EVENT_MUSIC = true

local LobbyMusicController = {
	Controllers = {
		MusicController = {},
	},
}

-- Names of the folder's Sounds, including subfolders.
function LobbyMusicController:getTrackNames(): { string }
	local music = self.Controllers.MusicController

	local musics = music:GetFolder()
	if not musics then
		return {}
	end

	local folder = musics:FindFirstChild(FOLDER)
	if not folder then
		log:StudioWarn(`SoundService.SharedSounds.Musics.{FOLDER} does not exist.`)
		return {}
	end

	local names = {}
	for _, inst in folder:GetDescendants() do
		if inst:IsA("Sound") then
			table.insert(names, inst.Name)
		end
	end

	return names
end

local function shuffle(list : { string })
	for i = #list, 2, -1 do
		local j = math.random(i)
		list[i], list[j] = list[j], list[i]
	end
end

--[=[
	The event queue: `EVENT_TRACK` first, then `EVENT_EVERY` of the others, then
	`EVENT_TRACK` again, until every other track has had its turn. The others are
	shuffled once here; the queue itself loops in this order.
]=]
local function eventQueue(others : { string }) : { string }
	local queue = { EVENT_TRACK }

	for index, name in others do
		table.insert(queue, name)

		if index % EVENT_EVERY == 0 and index < #others then
			table.insert(queue, EVENT_TRACK)
		end
	end

	return queue
end

function LobbyMusicController:play()
	local names = self:getTrackNames()
	if #names == 0 then
		log:StudioWarn(`no music in SoundService.SharedSounds.Musics.{FOLDER}.`)
		return
	end

	local hasEventTrack = table.find(names, EVENT_TRACK) ~= nil

	local others = {}
	for _, name in names do
		if name ~= EVENT_TRACK then
			table.insert(others, name)
		end
	end

	if EVENT_MUSIC and hasEventTrack then
		shuffle(others)

		self.Controllers.MusicController:PlayPlaylist(eventQueue(others), {
			Shuffle = false,
			Loop = true,
			Fade = FADE,
		})

		return
	end

	if EVENT_MUSIC and not hasEventTrack then
		log:StudioWarn(`the event is on but there is no {EVENT_TRACK} in Musics.{FOLDER}; playing the normal queue.`)
	end

	if #others == 0 then
		log:StudioWarn(`only {EVENT_TRACK} is in Musics.{FOLDER} and the event is off; nothing to play.`)
		return
	end

	--[[
		Shuffle already shuffles on entry, so the first track is any of them, and it
		reshuffles every loop. Loop keeps the queue alive while the player is in the Lobby.
	]]
	self.Controllers.MusicController:PlayPlaylist(others, {
		Shuffle = true,
		Loop = true,
		Fade = FADE,
	})
end

function LobbyMusicController:construct()
	--[[
		Off the start thread: `GetFolder` waits for the folder to appear, and it is not
		worth holding up the other controllers' loading for that.
	]]
	task.spawn(function()
		self:play()
	end)
end

--[[
	In `start`, not `init`: Me runs the `init`s while still requiring modules, and
	`Framework:Get` returns nil for anything not yet in the list. When the `start`s run,
	everything is loaded.
]]
function LobbyMusicController:start()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller)
	end

	self:construct()
end

function LobbyMusicController:init() end

return LobbyMusicController