local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Me = require(Vendor:WaitForChild("Me"))

local Framework = Me.new()

-- Online on this server, on another one, or offline: `ProfileEditService`
-- picks the path.
return function(_context, action : string, userIds : { number }, amount : number)
	local ProfileEditService = Framework:Get("ProfileEditService", false, true)

	return ProfileEditService:RunCommand(userIds, {
		Key = "Stats",
		Field = "Cash",
		Action = action,
		Amount = amount,
	})
end
