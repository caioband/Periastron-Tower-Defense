local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Me = require(Vendor:WaitForChild("Me"))

local Framework = Me.new()

return function(_context, action : string, players : { Player }, amount : number)
	local EventCurrencyService = Framework:Get("EventCurrencyService", false, true)

	if #players == 0 then
		return "Nobody matched."
	end

	local lines = {}
	for _, player in players do
		local previous, updated, err = EventCurrencyService:Apply(player, action, amount, "Cmdr")
		if err then
			table.insert(lines, `{player.Name}: {err}`)
		else
			table.insert(lines, `{player.Name} Stats.EventCurrency {previous} -> {updated}`)
		end
	end

	return table.concat(lines, "\n")
end
