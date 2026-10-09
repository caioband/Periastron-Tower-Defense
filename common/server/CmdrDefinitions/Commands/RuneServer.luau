local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Me = require(Vendor:WaitForChild("Me"))

local Framework = Me.new()

--[[
	Grants a rune without charging, through the same `RuneService:Grant` the shop
	uses, so the refusals are the shop's. `seconds` shortens the duration to watch a
	rune run out (in the shop's list and in the match reward) without waiting
	25 minutes.
]]
return function(_context, players : { Player }, rune : string, tier : number, seconds : number?)
	local RuneService = Framework:Get("RuneService", false, true)

	local lines = {}

	for _, player in players do
		if tier <= 0 then
			local cleared = RuneService:Clear(player, rune)
			table.insert(lines, `{player.Name}: {if cleared then "removed" else "not loaded"}`)
			continue
		end

		local ok, result = RuneService:Grant(player, rune, tier, seconds)
		table.insert(lines, `{player.Name}: {if ok then result else "refused (" .. tostring(result) .. ")"}`)
	end

	return table.concat(lines, "\n")
end
