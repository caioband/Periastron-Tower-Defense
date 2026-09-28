local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Me = require(Vendor.Me)
local Log = require(Shared:WaitForChild("Util"):WaitForChild("Log"))

local Framework = Me.new()
local log = Log.new("LobbyMusicController")

--[[
	Lobby music.

	It plays everything in `SoundService.SharedSounds.Musics.Lobby`, in random order and
	in an endless queue: it fades in, and each track that ends gives way to the next with
	a transition. A new track in the game is just a matter of dropping the Sound in the
	folder: there is no name list here.

	MusicController plays; this controller only resolves *what* to play. The rule of
	never repeating the track that just ended lives there, in `_advancePlaylist`, because
	it applies to any queue.

	See docs/common/audio.md.
]]

local FOLDER = "Lobby"
local FADE = 2

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

function LobbyMusicController:play()
	local names = self:getTrackNames()
	if #names == 0 then
		log:StudioWarn(`no music in SoundService.SharedSounds.Musics.{FOLDER}.`)
		return
	end

	--[[
		Shuffle already shuffles on entry, so the first track is any of them, and it
		reshuffles every loop. Loop keeps the queue alive while the player is in the Lobby.
	]]
	self.Controllers.MusicController:PlayPlaylist(names, {
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
