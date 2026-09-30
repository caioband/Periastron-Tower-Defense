local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Me = require(Vendor:WaitForChild("Me"))

local Framework = Me.new()

--[[
	The profile's level, which is `Stats.XP` read through `LevelConfig`: there is no
	level on the profile to write. `ProfileEditService` does the math in levels and
	writes the XP at the start of the resulting level (see its `editLevel`), on
	whichever server holds the profile, so the same rule applies online, elsewhere,
	or offline.

	Everything that depends on level (deck slots, difficulty unlocks, the HUD bar,
	the HIGHEST LEVEL leaderboard) reads the XP, so it all follows on its own.
]]

return function(_context, action : string, userIds : { number }, amount : number)
	local ProfileEditService = Framework:Get("ProfileEditService", false, true)

	return ProfileEditService:RunCommand(userIds, {
		Key = "Stats",
		Field = "Level",
		Action = action,
		Amount = math.max(0, math.floor(amount)),
	})
end
