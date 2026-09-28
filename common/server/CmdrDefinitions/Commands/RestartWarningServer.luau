local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Me = require(Vendor:WaitForChild("Me"))

local Framework = Me.new()

local DEFAULT_SECONDS = 300

--[[
	The real restart cannot be rehearsed: the engine fires
	`game.ServerRestartScheduled`, and the only way to see it is to publish an
	update. This command goes through the same `Schedule` the event uses, so what
	shows on screen is exactly what would show on the day, without anyone being
	kicked.
]]
return function(_context, source : string, seconds : number?)
	local ServerRestartService = Framework:Get("ServerRestartService", false, true)

	local remaining = math.max(seconds or DEFAULT_SECONDS, 0)

	ServerRestartService:Schedule(source, DateTime.now().UnixTimestamp + remaining)

	return string.format("Restart warning sent: %s in %d seconds (nothing was actually scheduled).", source, remaining)
end
