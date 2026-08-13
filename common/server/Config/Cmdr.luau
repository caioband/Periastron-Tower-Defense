--[[
	Regras de permissão do Cmdr (admin console) — SOMENTE SERVIDOR.

	Esta lista nunca chega ao cliente. O `CmdrService:IsAdmin()` é a única fonte
	de verdade: ele roda no hook `BeforeRun` de todo comando e também responde ao
	evento `RequestCmdrAccess` que o `CmdrController` dispara só para decidir se
	mostra o console (cosmético).

	As configurações que o cliente precisa (tecla de ativação e nome da place)
	ficam em `ReplicatedStorage.Shared.Config.SharedConfig.Cmdr`.
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
}
