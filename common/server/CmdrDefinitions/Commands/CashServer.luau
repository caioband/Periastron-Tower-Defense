local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Me = require(Vendor:WaitForChild("Me"))

local Framework = Me.new()

return function(_context, action : string, players : { Player }, amount : number)
	local CurrencyService = Framework:Get("CurrencyService", false, true)

	return CurrencyService:RunCommand("Cash", action, players, amount)
end
