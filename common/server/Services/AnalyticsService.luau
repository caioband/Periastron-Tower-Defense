local ServerScriptService = game:GetService("ServerScriptService")
local Analytics = game:GetService("AnalyticsService")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local ServerConfigs = ServerScriptService:WaitForChild("Config")

local ServerConfig = require(ServerConfigs)
local Log = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Util"):WaitForChild("Log"))

local log = Log.new("AnalyticsService")

local Config = ServerConfig.Analytics

--[[
	The only place in the game that talks to Roblox's `AnalyticsService`.

	Anything that wants to measure something calls in here (`:LogFunnelStep` for the
	onboarding funnel and `:LogEvent` for a standalone event), and no other file
	needs to know the API exists or repeat the guards it requires.

	**Three guards, all living here:**

	  1. **Studio and unpublished places.** Roblox does not accept analytics events
	     from Studio or from a loose `.rbxl` (`PlaceId == 0`), and accepts none from
	     the client. Instead of swallowing the call, it becomes a Studio-only debug
	     log with the step number and name: that is how the whole script is checked
	     in Studio, where the dashboard does not exist.
	  2. **`pcall` on every engine call**, as `TutorialService`'s `TeleportAsync`
	     already does. Telemetry that breaks a tutorial step is worse than no
	     telemetry.
	  3. **Repetition.** Roblox already counts only the first time of each step per
	     user; the in-memory guard avoids the call and, above all, keeps the output
	     honest: a step logged twice in Studio would be a bug to hunt that does not
	     exist.

	The `AnalyticsService` from `Framework:Get` is **this** module; Roblox's is the
	`Analytics` at the top of the file, and it is the one with the `Log...` methods.

	See docs/common/tutorial.md.
]]

local AnalyticsService = {}

-- [UserId] = { [step name] = true }. Only what this server already sent.
AnalyticsService.Sent = {}

--[[ INTERNAL ]]

--[=[
	Does this place send real events?

	`PlaceId == 0` is a file that was never published: Roblox would have nowhere to
	attach the data.
]=]
function AnalyticsService:enabled() : boolean
	return not RunService:IsStudio() and game.PlaceId ~= 0
end

--[=[
	The step number, by list order.
]=]
function AnalyticsService:stepNumber(stepName : string) : number?
	for index, name in Config.Funnel.Onboarding do
		if name == stepName then
			return index
		end
	end

	return nil
end

--[=[
	The three keys Roblox accepts in `customFields`, in the order the fields arrive.
	More than three are dropped: a fourth does not exist in the API.
]=]
local FIELD_KEYS = {
	Enum.AnalyticsCustomFieldKeys.CustomField01,
	Enum.AnalyticsCustomFieldKeys.CustomField02,
	Enum.AnalyticsCustomFieldKeys.CustomField03,
}

function AnalyticsService:fields(values : { string }?) : { [any] : string }?
	if not values or #values == 0 then
		return nil
	end

	local fields = {}

	for index, value in values do
		local key = FIELD_KEYS[index]
		if not key then break end

		fields[key] = tostring(value)
	end

	return fields
end

--[[ API ]]

--[=[
	An onboarding funnel step, by its name in
	`ServerConfig.Analytics.Funnel.Onboarding`.

	A name not in the list becomes no step at all: it warns in the output and stops
	there. Sending a made-up number would be worse: the dashboard would gain a step
	nobody knows the origin of.
]=]
function AnalyticsService:LogFunnelStep(player : Player, stepName : string)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then return end

	local step = self:stepNumber(stepName)
	if not step then
		log:StudioWarn(`step "{stepName}" is not in Config.Analytics.Funnel.Onboarding; nothing was logged.`)

		return
	end

	local sent = self.Sent[player.UserId]
	if not sent then
		sent = {}
		self.Sent[player.UserId] = sent
	end

	if sent[stepName] then return end
	sent[stepName] = true

	if not self:enabled() then
		log:Debug(`(studio) step {step} "{stepName}" for {player.Name}.`)

		return
	end

	local success, err = pcall(function()
		Analytics:LogOnboardingFunnelStepEvent(player, step, stepName)
	end)

	if not success then
		log:Warn(`step {step} "{stepName}" for {player.Name} failed: {err}`)

		return
	end

	log:Debug(`step {step} "{stepName}" for {player.Name}.`)
end

--[=[
	A standalone event: what the funnel cannot say.

	`value` is the number Roblox sums (its default is 1), and `fields` is a list of up
	to three strings, which go into `CustomField01..03`.
]=]
function AnalyticsService:LogEvent(player : Player, eventName : string, value : number?, fields : { string }?)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then return end

	local amount = value or 1
	local custom = self:fields(fields)

	if not self:enabled() then
		log:Debug(`(studio) event "{eventName}" = {amount} for {player.Name}.`)

		return
	end

	local success, err = pcall(function()
		Analytics:LogCustomEvent(player, eventName, amount, custom)
	end)

	if not success then
		log:Warn(`event "{eventName}" for {player.Name} failed: {err}`)

		return
	end

	log:Debug(`event "{eventName}" = {amount} for {player.Name}.`)
end

--[[ LIFECYCLE ]]

function AnalyticsService:construct()
	-- What was already sent only matters while the player is in the room: a player who
	-- leaves and returns lands on another server, and Roblox knows what they already did.
	Players.PlayerRemoving:Connect(function(player : Player)
		self.Sent[player.UserId] = nil
	end)
end

function AnalyticsService:start()
	self:construct()
end

function AnalyticsService:init()
end

return AnalyticsService
