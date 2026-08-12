
--[[
	Cmdr (admin console) configuration.

	Permission is always validated on the server through a BeforeRun hook, so this
	list only decides who is *allowed* to run commands -- never trust the client.
]]

return {
	-- [UserId] = true. The place owner (game.CreatorId) is always allowed.
	ADMIN_USER_IDS = {
		-- [1234567] = true,
	},

	-- Optional group check. Leave GROUP_ID as nil to disable it.
	GROUP_ID = nil :: number?,
	GROUP_MIN_RANK = 200,

	-- Anyone testing in Studio counts as an admin.
	ALLOW_IN_STUDIO = true,

	-- Built in cmdr command groups that get registered.
	DEFAULT_COMMAND_GROUPS = {
		"DefaultUtil",
		"DefaultAdmin",
		"DefaultDebug",
		"Help",
	},

	-- Client side console settings.
	ACTIVATION_KEYS = {
		Enum.KeyCode.F2,
	},

	PLACE_NAME = "Periastron Tower Defense",
}
