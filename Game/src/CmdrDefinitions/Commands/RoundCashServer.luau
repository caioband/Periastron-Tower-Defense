local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Me = require(Vendor:WaitForChild("Me"))

local Framework = Me.new()

--[[
	Match money, which is not `cash`.

	This one lives in `MobService.SessionCash`: it starts with the difficulty's
	`StartingCash`, pays for towers, and dies with the round, never touching the
	profile. That is why the command lives in Game: `MobService` does not exist in the
	Lobby, and there a yielding `Framework:Get` would wait forever.

	The math goes through the service's `addCash`/`spendCash`, not a direct table
	write, because they fire `UpdateCash` to the client: without it the on-screen
	counter would keep showing the old value until the next kill.
]]
return function(_context, action : string, players : { Player }, amount : number)
	local MobService = Framework:Get("MobService", false, true)

	if #players == 0 then
		return "Nobody matched."
	end

	local done = {}

	for _, player in players do
		local previous = MobService:getCash(player)

		local target
		if action == "set" then
			target = math.max(amount, 0)
		elseif action == "remove" then
			target = math.max(previous - amount, 0)
		else
			target = math.max(previous + amount, 0)
		end

		local delta = target - previous
		if delta > 0 then
			MobService:addCash(player, delta)
		elseif delta < 0 then
			MobService:spendCash(player, -delta)
		end

		table.insert(done, string.format("%s %d -> %d", player.Name, previous, MobService:getCash(player)))
	end

	return string.format("%s roundcash: %s", action, table.concat(done, ", "))
end
