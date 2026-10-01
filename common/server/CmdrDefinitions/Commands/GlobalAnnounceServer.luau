local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Me = require(Vendor:WaitForChild("Me"))

local Framework = Me.new()

return function(context, message : string)
	local executor = context.Executor
	if not executor then
		return "A player has to run this command."
	end

	local AnnouncementService = Framework:Get("AnnouncementService", false, true)

	local _, result = AnnouncementService:Broadcast(executor.Name, executor.UserId, message)

	return result
end