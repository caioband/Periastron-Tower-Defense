--[[
	The part of Cmdr the client needs: purely cosmetic, safe to replicate.

	Permission rules (ADMIN_USER_IDS, GROUP_ID, ALLOW_IN_STUDIO) live in
	`ServerScriptService.Config.Cmdr` and are not replicated. The client learns
	whether it is an admin by asking the server through `RequestCmdrAccess`.
]]

return {
	-- Client side console settings.
	ACTIVATION_KEYS = {
		Enum.KeyCode.F2,
	},

	PLACE_NAME = "Periastron Tower Defense",
}
