local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Me = require(Vendor:WaitForChild("Me"))

local Framework = Me.new()

-- Online neste servidor, em outro ou offline: quem decide o caminho é o
-- `ProfileEditService`.
return function(_context, action : string, userIds : { number }, amount : number)
	local ProfileEditService = Framework:Get("ProfileEditService", false, true)

	return ProfileEditService:RunCommand(userIds, {
		Key = "Stats",
		Field = "Shards",
		Action = action,
		Amount = amount,
	})
end
