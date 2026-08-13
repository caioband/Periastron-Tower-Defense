--[[
	Parte do Cmdr que o cliente precisa — puramente cosmética, pode ser replicada.

	As regras de permissão (ADMIN_USER_IDS, GROUP_ID, ALLOW_IN_STUDIO) ficam em
	`ServerScriptService.Config.Cmdr` e não são replicadas. O cliente descobre se
	é admin perguntando ao servidor pelo evento `RequestCmdrAccess`.
]]

return {
	-- Client side console settings.
	ACTIVATION_KEYS = {
		Enum.KeyCode.F2,
	},

	PLACE_NAME = "Periastron Tower Defense",
}
