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
	--[[
		[UserId] = true. É a lista que manda: quem está aqui roda comando em
		qualquer servidor, publicado ou não.

		Os outros caminhos abaixo são atalhos, e nenhum deles vale sozinho num jogo
		publicado — `ALLOW_IN_STUDIO` só existe no Studio, e o dono é reconhecido pelo
		bloco de `CreatorType` do `CmdrService:IsAdmin`.
	]]
	ADMIN_USER_IDS = {
		[46871391] = true,   -- caioband
	},

	--[[
		Rank mínimo no grupo **dono da place** para valer como dono.

		Esta place pertence a um grupo, e não a uma pessoa: sem isto o
		`game.CreatorId` é o id do grupo, nunca o de um jogador, e o teste de dono não
		passava para ninguém — era por isso que os comandos não funcionavam em jogo,
		só no Studio.

		255 é o dono do grupo e mais ninguém. Baixe para o rank dos seus admins se
		quiser que a diretoria do grupo também rode comando.
	]]
	CREATOR_GROUP_MIN_RANK = 255,

	-- Grupo extra, sem relação com o dono da place. Deixe GROUP_ID nil para desligar.
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
