local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TeleportService = game:GetService("TeleportService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Me = require(Vendor.Me)
local Log = require(Shared.Util.Log)
local Environment = require(Shared.Util.Environment)

local Framework = Me.new()
local log = Log.new("MapEditorTeleportService")

--[[ CONSTANTS ]]

--[=[
	The prompt that sends the player to the Map Editor (build mode):
	`Workspace.Map.BuildPortals.MapEditorAccess.ProximityPrompt`, authored in the
	Lobby map.

	Only the Lobby has it, so the names live here and not in `SharedConfig`, which
	is in the `Shared` Package every place receives.
]=]
local MAP_NAME = "Map"
local FOLDER_NAME = "BuildPortals"
local PART_NAME = "MapEditorAccess"
local PROMPT_NAME = "ProximityPrompt"

local WAIT_TIMEOUT = 30

-- Seconds before the same player can trigger the teleport again: covers the time a
-- teleport takes to leave, and a failed one can be retried after it.
local TELEPORT_COOLDOWN = 10

--[=[
	Sends the player to the Map Editor of **this** environment when they trigger the
	prompt by the build portals: a QA Lobby goes to the QA editor, Production to
	Production. The id comes from `Environment.GetPlaceId("MapEditor")`, never from
	the prompt or a hard-coded number.

	The prompt is off where the editor cannot be reached: an environment without a
	Map Editor (`Environment.HasPlace("MapEditor")` false), or where community maps
	are disabled (`CommunityMapService:IsEnabled()`, the same switch as the Edit
	button).

	Each trigger reserves a new private server of the editor for the player alone
	(`ShouldReserveServer`), so nobody else builds alongside them. Unlike the Edit
	button (`CommunityMapService:Edit`), no map is opened.

	See docs/lobby/map-editor-access.md.
]=]
local MapEditorTeleportService = {
	Services = {
		-- Whether community maps (and so the editor) are open in this universe.
		CommunityMapService = {},
	},

	-- [Player] = true while a teleport is in flight or cooling down.
	Leaving = {},
}

--[[ INTERNAL ]]

function MapEditorTeleportService:_teleport(player : Player)
	if self.Leaving[player] then return end
	self.Leaving[player] = true

	local placeId = Environment.GetPlaceId("MapEditor")

	-- Public on purpose: which environment this server resolved and where the
	-- player is going, readable from a live server's console.
	log:Info(`sending {player.Name} to a private server of the {Environment.Describe()} Map Editor ({placeId}) from universe {game.GameId}`)

	local options = Instance.new("TeleportOptions")
	options.ShouldReserveServer = true

	local ok, err = pcall(function()
		return TeleportService:TeleportAsync(placeId, { player }, options)
	end)

	if not ok then
		log:Warn(`could not send {player.Name} to the Map Editor {placeId}: {err}`)
	end

	task.delay(TELEPORT_COOLDOWN, function()
		self.Leaving[player] = nil
	end)
end

--- The authored prompt, or nil when the map does not have it.
local function findPrompt() : ProximityPrompt?
	local map = workspace:WaitForChild(MAP_NAME, WAIT_TIMEOUT)
	local folder = map and map:WaitForChild(FOLDER_NAME, WAIT_TIMEOUT)
	local part = folder and folder:WaitForChild(PART_NAME, WAIT_TIMEOUT)
	local prompt = part and part:WaitForChild(PROMPT_NAME, WAIT_TIMEOUT)

	if prompt and prompt:IsA("ProximityPrompt") then
		return prompt
	end

	return nil
end

--[[ LIFECYCLE ]]

function MapEditorTeleportService:construct()
	local prompt = findPrompt()
	if not prompt then
		log:Warn(`could not find Workspace.{MAP_NAME}.{FOLDER_NAME}.{PART_NAME}.{PROMPT_NAME}; nobody can go to the Map Editor from here.`)
		return
	end

	if not Environment.HasPlace("MapEditor") then
		prompt.Enabled = false
		log:Warn(`{Environment.Describe()} has no Map Editor in EnvironmentConfig; the Map Editor prompt is off.`)
		return
	end

	local communityMaps = self.Services.CommunityMapService
	if not communityMaps or not communityMaps:IsEnabled() then
		prompt.Enabled = false
		log:Info(`community maps are disabled in {Environment.Describe()}; the Map Editor prompt is off.`)
		return
	end

	prompt.Triggered:Connect(function(player : Player)
		-- Teleports do not work in Studio.
		if RunService:IsStudio() then
			log:StudioWarn(`{player.Name} triggered the Map Editor teleport; teleports do not work in Studio.`)
			return
		end

		-- `TeleportAsync` yields: keep it off the prompt's thread.
		task.spawn(self._teleport, self, player)
	end)
end

function MapEditorTeleportService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service, false, true)
	end

	-- `findPrompt` yields on the map; keep it off the loader.
	task.spawn(self.construct, self)
end

function MapEditorTeleportService:init()
	Players.PlayerRemoving:Connect(function(player : Player)
		self.Leaving[player] = nil
	end)
end

return MapEditorTeleportService
