local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Me = require(Vendor.Me)
local Log = require(Shared:WaitForChild("Util"):WaitForChild("Log"))

local Framework = Me.new()
local log = Log.new("MapCutsceneController")

--[=[
	Plays a map cutscene (the intro before the first round, the outro on the way to
	the Lobby) when `MapCutsceneService` asks, and answers when it is over: the
	server holds the difficulty vote, or the teleport, until then.

	Before playing it waits for two things: the scene to finish replicating (the
	server clones it into `ReplicatedStorage.Cutscenes` only when needed, and its
	parts arrive over several frames; `DescendantCount` says how many to expect), and
	the loading screen to leave, or the first seconds would play behind it.

	The scene plays `STAGE_OFFSET` away from where it was authored: far from every map,
	so nothing of the match shows up behind the camera. It always answers, even when
	the scene fails, because the server is waiting for it.

	A scene whose `PlayerRig` attribute names one of its rigs plays with that rig
	dressed as this player: clothing, body colors, face, and accessories, with the
	rig's own costume taken off (`CutsceneController:dressScene`, `ReplaceCostume`).
	The scene in ReplicatedStorage is dressed before playing, so the stage cloned
	from it comes out dressed, and undressed after.

	The outro arrives with `endBlack`: the screen fades to black in the scene's last
	`END_FADE` seconds and stays black, so the results screen does not flash back
	before the teleport. A failed teleport (`LobbyTeleportFailed`) takes it away.

	See docs/game/map-cutscenes.md.
]=]

local REPLICATED_FOLDER = "Cutscenes"
local DESCENDANT_COUNT = "DescendantCount"
local PLAYER_RIG = "PlayerRig"
local LOADING_SCREEN = "LoadingScreen"

local STAGE_OFFSET = Vector3.new(6000, 0, 6000)

-- How long each wait gives up after; the server has its own, longer, deadline.
local REPLICATION_TIMEOUT = 30
local LOADING_TIMEOUT = 60

-- The black screen at the end of an outro: over everything, the cutscene included.
local END_FADE = 0.5
local END_COVER_NAME = "CutsceneEndCover"
local END_COVER_DISPLAY_ORDER = 1000

local MapCutsceneController = {
	Controllers = {
		CutsceneController = {},
	},

	-- Tokens already played: the server can send the same cutscene twice (its push
	-- and the answer to `RequestMapCutscene`).
	Played = {} :: { [string]: true },

	EndCover = nil :: ScreenGui?,
}

--[[
	A black screen that fades in starting `delay` seconds from now and stays until
	`removeEndCover`.
--]]
function MapCutsceneController:showEndCover(delay: number)
	self:removeEndCover()

	local cover = Instance.new("ScreenGui")
	cover.Name = END_COVER_NAME
	cover.IgnoreGuiInset = true
	cover.ResetOnSpawn = false
	cover.DisplayOrder = END_COVER_DISPLAY_ORDER
	cover:SetAttribute("IgnoreInterfaceHide", true)

	local frame = Instance.new("Frame")
	frame.Size = UDim2.fromScale(1, 1)
	frame.BackgroundColor3 = Color3.new()
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel = 0
	frame.Parent = cover

	cover.Parent = PlayerGui
	self.EndCover = cover

	task.delay(delay, function()
		if frame.Parent then
			TweenService:Create(frame, TweenInfo.new(END_FADE), { BackgroundTransparency = 0 }):Play()
		end
	end)
end

function MapCutsceneController:removeEndCover()
	if self.EndCover then
		self.EndCover:Destroy()
		self.EndCover = nil
	end
end

function MapCutsceneController:awaitScene(sceneName: string): Instance?
	local folder = ReplicatedStorage:WaitForChild(REPLICATED_FOLDER, REPLICATION_TIMEOUT)
	local scene = folder and folder:WaitForChild(sceneName, REPLICATION_TIMEOUT)
	if not scene then return nil end

	local expected = scene:GetAttribute(DESCENDANT_COUNT)
	local deadline = os.clock() + REPLICATION_TIMEOUT

	while type(expected) == "number" and #scene:GetDescendants() < expected do
		if os.clock() > deadline or not scene.Parent then
			return nil
		end
		task.wait(0.1)
	end

	return scene
end

function MapCutsceneController:awaitLoadingScreen()
	local deadline = os.clock() + LOADING_TIMEOUT
	while PlayerGui:FindFirstChild(LOADING_SCREEN) and os.clock() < deadline do
		task.wait(0.1)
	end
end

function MapCutsceneController:play(sceneName: string, token: string, endBlack: boolean)
	local cutscenes = self.Controllers.CutsceneController

	local scene = self:awaitScene(sceneName)
	if not scene then
		log:StudioWarn(`cutscene '{sceneName}' did not finish replicating; skipped.`)

		if endBlack then
			self:showEndCover(0)
		end
	elseif cutscenes then
		self:awaitLoadingScreen()

		local playerRig = scene:GetAttribute(PLAYER_RIG)
		local undress = if type(playerRig) == "string"
			then cutscenes:dressScene(scene, Player, playerRig, { ReplaceCostume = true })
			else nil

		local reference = cutscenes:readSceneReference(scene)
		local origin = reference and reference + STAGE_OFFSET

		local duration = cutscenes:playCutscene(scene, origin)

		-- Black before the scene lets go of the screen, not after.
		if endBlack then
			self:showEndCover(math.max(0, (duration or 0) - END_FADE))
		end

		if duration then
			task.wait(duration)
		end

		if undress then
			undress()
		end
	end

	Framework:Fire("MapCutsceneFinished", token)
end

function MapCutsceneController:construct()
	Framework:Listen("PlayMapCutscene", function(sceneName: any, token: any, endBlack: any)
		if type(sceneName) ~= "string" or type(token) ~= "string" then return end
		if self.Played[token] then return end
		self.Played[token] = true

		task.spawn(function()
			self:play(sceneName, token, endBlack == true)
		end)
	end)

	-- The teleport did not leave: the results screen (and its Lobby button) is back.
	Framework:Listen("LobbyTeleportFailed", function()
		self:removeEndCover()
	end)

	-- In case the server's push arrived before the Listen above existed.
	Framework:Fire("RequestMapCutscene")
end

function MapCutsceneController:start()
end

function MapCutsceneController:init()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	self:construct()
end

return MapCutsceneController
