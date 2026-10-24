local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Me = require(Vendor.Me)
local Log = require(Shared.Util.Log)

local Framework = Me.new()
local log = Log.new("MapCutsceneService")

--[=[
	The cutscenes a map plays around its match.

	- **Intro**: before the first round. `WaveService` calls `PlayIntro` between the
	  map being ready and the difficulty vote, and waits until every player finished
	  watching. Once per server; a play-again round goes straight to the vote.
	- **Outro**: when a player chooses to go back to the Lobby from the results
	  screen of a **won** match. `WaveService:sendToLobby` calls `PlayOutro` for that
	  player alone and teleports when it returns. Once per player: a teleport that
	  failed and is asked again goes straight out.

	The baked scenes live in `ServerStorage.Cutscenes`, which does not replicate. The
	ones this match needs are cloned into `ReplicatedStorage.Cutscenes`, so a player
	never downloads the scenes of other maps. The intro's clone goes away after it;
	the outro's is cloned when the match ends (anyone may leave from then on) and
	stays. `DescendantCount` tells the client when a clone finished arriving.

	Each playing is a session with a token, and the client answers with it: two
	sessions can run at once (two players leaving together).

	See docs/game/map-cutscenes.md.
]=]

-- Map key (folder in `ServerStorage.Maps`) -> baked scenes in `ServerStorage.Cutscenes`.
local MAP_CUTSCENES = {
	AutumnValley = {
		Intro = "Cutscene1_Perieperifall",
		Outro = "Cutscene2_Part4",
	},
}

-- How long, on top of the scene's own length, a client has to load it and finish:
-- the loading screen, the replication of the scene, and a slow frame or two.
local LOAD_MARGIN = 45

local SOURCE_FOLDER = "Cutscenes"
local REPLICATED_FOLDER = "Cutscenes"
local DESCENDANT_COUNT = "DescendantCount"

local MapCutsceneService = {
	Services = {
		WaveService = {},
	},

	IntroPlayed = false,

	-- How the last match ended (`WaveService.Signals.MatchFinished`): the outro only
	-- plays after a win. A play-again round overwrites it when it ends.
	MatchWon = false,

	-- token -> { SceneName, Pending = { [Player]: true }, EndBlack }
	Sessions = {} :: { [string]: { SceneName: string, Pending: { [Player]: true }, EndBlack: boolean } },

	-- Players who already watched the outro, or are watching it now.
	OutroStarted = {} :: { [Player]: true },
}

--[[ INTERNAL ]]

function MapCutsceneService:getScenes()
	local mapService = Framework:Get("MapService")
	if not mapService then return nil end

	-- A community map is not one of the game's maps and has no story.
	if mapService.IsCommunityMatch and mapService:IsCommunityMatch() then return nil end

	return MAP_CUTSCENES[mapService.CurrentMapName]
end

function MapCutsceneService:getSource(sceneName: string): Instance?
	local sources = ServerStorage:FindFirstChild(SOURCE_FOLDER)
	local source = sources and sources:FindFirstChild(sceneName)
	if not source then
		log:StudioWarn(`no baked cutscene '{sceneName}' in ServerStorage.{SOURCE_FOLDER}; it is skipped. Run CutsceneFormat.BakeEclipseAll().`)
		return nil
	end

	if type(source:GetAttribute("Duration")) ~= "number" then
		log:StudioWarn(`cutscene '{sceneName}' has no Duration attribute; bake it again.`)
		return nil
	end

	return source
end

--- The scene's clone in `ReplicatedStorage.Cutscenes`, made now if it is not there.
function MapCutsceneService:replicate(source: Instance): Instance
	local folder = ReplicatedStorage:FindFirstChild(REPLICATED_FOLDER)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = REPLICATED_FOLDER
		folder.Parent = ReplicatedStorage
	end

	local existing = folder:FindFirstChild(source.Name)
	if existing then
		return existing
	end

	local clone = source:Clone()
	clone:SetAttribute(DESCENDANT_COUNT, #clone:GetDescendants())
	clone.Parent = folder

	return clone
end

--[[
	Plays a scene for these players and returns when all of them answered or left,
	or when the scene's length plus `LOAD_MARGIN` runs out.
--]]
function MapCutsceneService:playFor(players: { Player }, source: Instance, endBlack: boolean)
	local token = HttpService:GenerateGUID(false)
	local session = { SceneName = source.Name, Pending = {}, EndBlack = endBlack }
	self.Sessions[token] = session

	for _, player in players do
		if not player.Parent then continue end

		session.Pending[player] = true
		Framework:Fire("PlayMapCutscene", player, source.Name, token, endBlack)
	end

	local deadline = os.clock() + (source:GetAttribute("Duration") :: number) + LOAD_MARGIN
	while next(session.Pending) ~= nil and os.clock() < deadline do
		task.wait(0.25)
	end

	if next(session.Pending) ~= nil then
		log:Debug(`cutscene '{source.Name}' timed out waiting for a client.`)
	end

	self.Sessions[token] = nil
end

--[[ API ]]

--[=[
	Plays this map's intro for everyone in the match and returns when all of them
	finished. Returns at once when the map has none or it already played.
]=]
function MapCutsceneService:PlayIntro()
	if self.IntroPlayed then return end
	self.IntroPlayed = true

	local scenes = self:getScenes()
	local source = scenes and scenes.Intro and self:getSource(scenes.Intro)
	if not source then return end

	local replicated = self:replicate(source)
	self:playFor(Players:GetPlayers(), source, false)

	-- Nobody needs it anymore: the intro plays once per server.
	if scenes.Outro ~= scenes.Intro then
		replicated:Destroy()
	end
end

--[=[
	Plays this map's outro for one player on their way to the Lobby, and answers
	whether the caller should go on with the teleport: `false` only when the outro
	is already playing for them (a second click), so the first request teleports.
]=]
function MapCutsceneService:PlayOutro(player: Player): boolean
	-- The story goes on only after a win; a loss goes straight back to the Lobby.
	if not self.MatchWon then return true end

	local scenes = self:getScenes()
	if not scenes or not scenes.Outro then return true end

	if self.OutroStarted[player] then
		-- Watching it now: the request that started it will teleport.
		for _, session in self.Sessions do
			if session.Pending[player] then return false end
		end
		return true
	end

	self.OutroStarted[player] = true

	local source = self:getSource(scenes.Outro)
	if not source then return true end

	-- Ends on black: the teleport is next, and the results screen must not flash back.
	self:replicate(source)
	self:playFor({ player }, source, true)

	return true
end

--[[ LIFECYCLE ]]

function MapCutsceneService:construct()
	Framework:Listen("MapCutsceneFinished", function(player: Player, token: any)
		local session = type(token) == "string" and self.Sessions[token]
		if session then
			session.Pending[player] = nil
		end
	end)

	--[[
		Warp drops an event that reaches a client before its `Listen` exists, and the
		round can get here while the client is still loading its controllers. So the
		client also asks, once it listens, and gets every cutscene it is still owed.
		The token keeps it from playing one twice.
	]]
	Framework:Listen("RequestMapCutscene", function(player: Player)
		for token, session in self.Sessions do
			if session.Pending[player] then
				Framework:Fire("PlayMapCutscene", player, session.SceneName, token, session.EndBlack)
			end
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		for _, session in self.Sessions do
			session.Pending[player] = nil
		end
		self.OutroStarted[player] = nil
	end)

	-- From the end of the match on, anyone may leave: the outro arrives before the click.
	-- Only a won match has one.
	local waveService = self.Services.WaveService
	if waveService and waveService.Signals and waveService.Signals.MatchFinished then
		waveService.Signals.MatchFinished:Connect(function(won: boolean)
			self.MatchWon = won == true
			if not self.MatchWon then return end

			local scenes = self:getScenes()
			local source = scenes and scenes.Outro and self:getSource(scenes.Outro)
			if source then
				self:replicate(source)
			end
		end)
	end
end

function MapCutsceneService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service)
	end

	self:construct()
end

function MapCutsceneService:init()
	-- Only the server fires it; the empty Listen creates the event. See docs/architecture/me-framework.md.
	Framework:Listen("PlayMapCutscene", function() end)
end

return MapCutsceneService
