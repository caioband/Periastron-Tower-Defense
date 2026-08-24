-- Este modulo vive em ServerScriptService.Config, entao o caminho ate o config
-- compartilhado precisa ser absoluto (antes era `script.Parent.Parent`, quando
-- ele ficava dentro de ReplicatedStorage.Shared.Config).
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SharedConfig = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("SharedConfig")
local CrateConfig = require(SharedConfig:WaitForChild("CrateConfig"))
local DeckConfig = require(SharedConfig:WaitForChild("DeckConfig"))

return {
	PROFILE_KEY = "profi555",
	Template = {
		Stats = {
			Wins = 0,
			Cash = 0,

			-- Moeda premium. Perfis antigos ganham a chave pelo reconcile do
			-- DataService, entao nao precisa migracao.
			Shards = 0,
			XP = 0,
		},

		Inventory = {
			-- { [Rarity] = amount } for every rarity in CrateConfig.RARITIES
			Crates = CrateConfig.createEmptyCrates(),
		},

		PurchaseHistory = {},
		Index = {},
		--[[
			O que o jogador novo ja tem. So Common e Rare: antes ele comecava com
			duas Rocket e duas Subspace Tripminer, ou seja, com o topo da tabela na
			mao e nada a conquistar na primeira hora.
		]]
		Units = {
			["Slasher"] = 3,
			["Sword"] = 2,
			["Slingshot"] = 1,
		},

		--[[
			As cartas do deck, um nome por carta e com repetição: duas Slasher
			equipadas são dois "Slasher" aqui. Ver `SharedConfig.DeckConfig`.
		]]
		EquippedUnits = {},

		-- Quantas cartas cabem no deck. Fica no perfil porque é para crescer com o
		-- jogador; o `DeckConfig.DEFAULT_CARD_LIMIT` é só o valor de partida, e o
		-- reconcile do DataService dá a chave para quem é de antes dela.
		CardLimit = DeckConfig.DEFAULT_CARD_LIMIT,
	},

	STARTING_CASH = 500,

	--[[
		Recompensa de fim de partida. Os tres sao escalados pela fracao de waves
		sobrevividas e pelos multiplicadores da dificuldade.
	]]
	BASE_WINNING_CASH = 1000,
	BASE_WINNING_SHARDS = 60,
	BASE_WINNING_XP = 200,

	-- Shards so comecam a cair depois desta fracao da run, e dai crescem por uma
	-- curva em vez de linearmente: e a moeda cara, entao quase todo o ganho vem de
	-- chegar perto do fim. Com 0.5 e curva 2, largar na metade rende zero e chegar
	-- a 80% da run rende ~36% do total.
	SHARD_WAVE_THRESHOLD = 0.5,
	SHARD_CURVE = 2,

	-- Fallback: o numero de waves de verdade vem do `MaxWaves` da dificuldade
	-- (Config/Difficulty.luau). Isto so vale se um preset nao definir o campo, e
	-- e multiplo de 9 como os presets, para cair na wave do chefe.
	MAX_WAVES = 18,
	--[[
		Caixa por ponto de dano, e so pelo dano que de fato entrou (ver
		`MobService:DamageMob`). Antes era 1 por ponto do valor cheio do golpe, o
		que pagava o excedente: um tiro de 70 num inimigo de 5 de vida rendia 70.
		Isso fazia o dano ser dois tercos da economia da partida e crescer junto
		com a vida dos inimigos, entao quanto mais dificil o preset, mais rico o
		jogador ficava. O que sobrou dessa renda foi para as recompensas de morte,
		em `Config.Wave`.

		A taxa caiu de 0,3 para 0,15 junto com a planilha de waves: sao muito mais
		inimigos por wave do que antes, entao o mesmo 0,3 por ponto dobraria a
		renda de dano.
	]]
	CASH_PER_DAMAGE = 0.15,

	-- So valem quando o inimigo nao traz `Reward` — as waves sempre trazem.
	CASH_PER_KILL_MIN = 6,
	CASH_PER_KILL_MAX = 12,
	MAX_DATA_TIME_OUT = 20,
}
