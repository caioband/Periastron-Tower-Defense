local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Me = require(Vendor:WaitForChild("Me"))
local Environment = require(Shared.Util.Environment)

local Framework = Me.new()

local KICK_MESSAGE = "Your data was reset. Rejoin to start as a new player."
local KICK_DELAY = 1

--[[
	Starts a test profile over: everything back to `Data.Template`, as a new player.

	The reset happens when the session closes (`DataService:ResetOnRelease`), so the
	player is kicked right after: the services that read the profile on join (contracts,
	Index, leaderstats, deck) start clean on the next one, instead of running on top of
	data that changed under them. Only `PurchaseHistory` survives, so a replayed
	purchase receipt does not pay twice.

	Leaderboards are their own stores and keep the old scores. Real game passes come
	back on the next join, because `MonetizationService` asks Roblox again.

	QA and Studio only, even for admins: in Production this erases a real player.
	Players on this server only.
]]
return function(context, players : { Player }?)
	if not (Environment.IsQA() or RunService:IsStudio()) then
		return "datareset is a test command: QA and Studio only."
	end

	local DataService = Framework:Get("DataService", false, true)

	local targets = if players and #players > 0 then players else { context.Executor }
	local done = {}

	for _, player in targets do
		if DataService:ResetOnRelease(player) then
			table.insert(done, player)
		end
	end

	if #done == 0 then
		return "No loaded profile among the targets."
	end

	local names = {}
	for _, player in done do
		table.insert(names, player.Name)
	end

	-- A moment after the reply: kicking the executor at once would cut the answer off.
	task.delay(KICK_DELAY, function()
		for _, player in done do
			if player.Parent then
				player:Kick(KICK_MESSAGE)
			end
		end
	end)

	return `Data reset for {table.concat(names, ", ")}; kicking so they rejoin fresh.`
end
