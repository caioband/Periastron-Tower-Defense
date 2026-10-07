local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Me = require(Vendor:WaitForChild("Me"))
local Environment = require(Shared.Util.Environment)

local Framework = Me.new()

--[[
	Undoes what `gift` leaves behind on a test profile.

	A gifted pass is a real record (`Data.GiftedPasses`): `RecalibratePasses` keeps
	it on every join, so a tester who got VIP from `gift` would own it for good.
	This command empties `GiftedPasses` and every `Data.Gifts` table, then asks
	Roblox again, so only passes actually bought remain.

	Clearing `Received` also forgets which gift ids were claimed: fine for test ids,
	which is why it is QA and Studio only. Players on this server only.
]]
return function(context, players : { Player }?)
	if not (Environment.IsQA() or RunService:IsStudio()) then
		return "giftreset is a test command: QA and Studio only."
	end

	local DataService = Framework:Get("DataService", false, true)
	local MonetizationService = Framework:Get("MonetizationService", false, true)

	local targets = if players and #players > 0 then players else { context.Executor }
	local done = {}

	for _, player in targets do
		if not (DataService.Profiles and DataService.Profiles[player]) then
			continue
		end

		DataService:Update(player, "GiftedPasses", function()
			return {}
		end)
		DataService:Update(player, "Gifts", function()
			return { Inbox = {}, Received = {}, Outgoing = {}, Unseen = {} }
		end)

		task.spawn(function()
			MonetizationService:RecalibratePasses(player)
		end)

		table.insert(done, player.Name)
	end

	if #done == 0 then
		return "No loaded profile among the targets."
	end

	return `Gifts cleared for {table.concat(done, ", ")}; passes re-checked with Roblox.`
end
