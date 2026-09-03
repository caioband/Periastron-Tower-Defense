-- Este modulo vive em ServerScriptService.Config, entao o caminho ate o config
-- compartilhado precisa ser absoluto (antes era `script.Parent.Parent`, quando
-- ele ficava dentro de ReplicatedStorage.Shared.Config).
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SharedConfig = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("SharedConfig")
local CrateConfig = require(SharedConfig:WaitForChild("CrateConfig"))
local DeckConfig = require(SharedConfig:WaitForChild("DeckConfig"))

return {
	--[[
		O nome do ProfileStore. **Trocar isto zera todo mundo**: os perfis antigos
		continuam no DataStore com a chave velha, e ninguem mais os le -- todo jogador
		entra com o `Template` daqui de baixo.

		As duas places leem esta mesma linha (o `DataService` do Lobby e o da Game),
		entao elas nunca podem apontar para stores diferentes: seria o mesmo jogador
		com dois perfis, um em cada place.
	]]
	PROFILE_KEY = "DEV_ENV_KEY_1",
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
		XP de uma run cheia, escalado pela fracao de waves sobrevividas e pelo
		`WinXpMultiplier` da dificuldade.

		**Coins e shards nao passam mais por aqui.** Eles eram uma base vezes um
		multiplicador por dificuldade, e o valor que interessa -- quanto o Nightmare
		paga -- so aparecia depois da conta. Hoje cada preset traz o numero cheio em
		`Difficulty.Presets[...].WinCash` e `.WinShards`, e mudar quanto uma
		dificuldade paga e trocar esse numero.
	]]
	BASE_WINNING_XP = 200,

	-- Shards so comecam a cair depois desta fracao da run, e dai crescem por uma
	-- curva em vez de linearmente: e a moeda cara, entao quase todo o ganho vem de
	-- chegar perto do fim. Com 0.5 e curva 2, largar na metade rende zero e chegar
	-- a 80% da run rende ~36% do total.
	SHARD_WAVE_THRESHOLD = 0.5,
	SHARD_CURVE = 2,

	--[[
		Quanto dos coins uma **derrota** paga: um quinto do que as mesmas waves
		pagariam numa vitoria.

		Perder nao rende shard nenhum, por mais longe que o jogador tenha chegado --
		isso nao e um numero, e uma regra, e mora no `computeReward`. Os coins ficam
		porque a partida perdida ainda foi tempo jogado; so nao pode competir com
		terminar a run.
	]]
	LOSS_CASH_MULTIPLIER = 0.2,

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
