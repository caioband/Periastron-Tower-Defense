local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TeleportService = game:GetService("TeleportService")

local Shared = ReplicatedStorage:WaitForChild("Shared")

local Log = require(Shared.Util.Log)
local Environment = require(Shared.Util.Environment)

local log = Log.new("AfkTeleportService")

--[[ CONSTANTS ]]

--[=[
	The prompt that sends the player to the AFK place:
	`Workspace["AFK Area"].teleport.ProximityPrompt`, authored in the Lobby map.

	Only the Lobby has it, so the names live here and not in `SharedConfig`, which
	is in the `Shared` Package every place receives.
]=]
local AREA_NAME = "AFK Area"
local PART_NAME = "teleport"
local PROMPT_NAME = "ProximityPrompt"

local WAIT_TIMEOUT = 30

-- Seconds before the same player can trigger the teleport again: covers the time a
-- teleport takes to leave, and a failed one can be retried after it.
local TELEPORT_COOLDOWN = 10

--[=[
	Sends the player to the AFK place of **this** environment when they trigger the
	prompt in the Lobby's AFK area: a QA Lobby goes to the QA AFK place, Production
	to Production. The id comes from `Environment.GetPlaceId("Afk")`, never from the
	prompt or a hard-coded number.

	An environment without an AFK place (`Environment.HasPlace("Afk")` false) turns
	the prompt off, so the player is never offered a teleport that cannot happen.

	The way back is `AfkAreaService` in the AFK place, which does the same with
	`GetPlaceId("Lobby")`.

	See docs/afk/afk-area.md.
]=]
local AfkTeleportService = {
	-- [Player] = true while a teleport is in flight or cooling down.
	Leaving = {},
}

--[[ INTERNAL ]]

function AfkTeleportService:_teleport(player : Player)
	if self.Leaving[player] then return end
	self.Leaving[player] = true

	local placeId = Environment.GetPlaceId("Afk")

	-- Public on purpose: which environment this server resolved and where the
	-- player is going, readable from a live server's console.
	log:Info(`sending {player.Name} to the {Environment.Describe()} AFK place ({placeId}) from universe {game.GameId}`)

	local ok, err = pcall(function()
		return TeleportService:TeleportAsync(placeId, { player })
	end)

	if not ok then
		log:Warn(`could not send {player.Name} to the AFK place {placeId}: {err}`)
	end

	task.delay(TELEPORT_COOLDOWN, function()
		self.Leaving[player] = nil
	end)
end

--- The authored prompt, or nil when the map does not have it.
local function findPrompt() : ProximityPrompt?
	local area = workspace:WaitForChild(AREA_NAME, WAIT_TIMEOUT)
	local part = area and area:WaitForChild(PART_NAME, WAIT_TIMEOUT)
	local prompt = part and part:WaitForChild(PROMPT_NAME, WAIT_TIMEOUT)

	if prompt and prompt:IsA("ProximityPrompt") then
		return prompt
	end

	return nil
end

--[[ LIFECYCLE ]]

function AfkTeleportService:construct()
	local prompt = findPrompt()
	if not prompt then
		log:Warn(`could not find Workspace.{AREA_NAME}.{PART_NAME}.{PROMPT_NAME}; nobody can go to the AFK place.`)
		return
	end

	if not Environment.HasPlace("Afk") then
		prompt.Enabled = false
		log:Warn(`{Environment.Describe()} has no AFK place in EnvironmentConfig; the AFK prompt is off.`)
		return
	end

	prompt.Triggered:Connect(function(player : Player)
		-- Teleports do not work in Studio.
		if RunService:IsStudio() then
			log:StudioWarn(`{player.Name} triggered the AFK teleport; teleports do not work in Studio.`)
			return
		end

		-- `TeleportAsync` yields: keep it off the prompt's thread.
		task.spawn(self._teleport, self, player)
	end)
end

function AfkTeleportService:start()
	-- `findPrompt` yields on the map; keep it off the loader.
	task.spawn(self.construct, self)
end

function AfkTeleportService:init()
	Players.PlayerRemoving:Connect(function(player : Player)
		self.Leaving[player] = nil
	end)
end

return AfkTeleportService
