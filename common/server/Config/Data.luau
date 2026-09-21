-- Este modulo vive em ServerScriptService.Config, entao o caminho ate o config
-- compartilhado precisa ser absoluto (antes era `script.Parent.Parent`, quando
-- ele ficava dentro de ReplicatedStorage.Shared.Config).
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SharedConfig = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("SharedConfig")
local ContractConfig = require(SharedConfig:WaitForChild("ContractConfig"))
local CrateConfig = require(SharedConfig:WaitForChild("CrateConfig"))
local DeckConfig = require(SharedConfig:WaitForChild("DeckConfig"))
local IndexConfig = require(SharedConfig:WaitForChild("IndexConfig"))
local RoundCardShopConfig = require(SharedConfig:WaitForChild("RoundCardShopConfig"))

return {
	--[[
		O nome do ProfileStore. **Trocar isto zera todo mundo**: os perfis antigos
		continuam no DataStore com a chave velha, e ninguem mais os le -- todo jogador
		entra com o `Template` daqui de baixo.

		As duas places leem esta mesma linha (o `DataService` do Lobby e o da Game),
		entao elas nunca podem apontar para stores diferentes: seria o mesmo jogador
		com dois perfis, um em cada place.
	]]
	PROFILE_KEY = "PROD_KEY_1",
	Template = {
		Stats = {
			Wins = 0,

			--[[
				As vitorias **por dificuldade**, `{ [dificuldade] = quantas }` -- o que
				destrava as dificuldades de cima (ver `SharedConfig.DifficultyUnlockConfig`).

				Separado do `Wins` acima, que continua sendo o total e e o que os mapas e o
				leaderstats leem. Um total nao serve para o cadeado: quem tem 20 vitorias no
				Easy nao mostrou nada sobre o Hard.

				Nasce **vazia**, e nao com uma chave por preset: a lista de dificuldades vive
				no config do servidor (`Config.Difficulty.Order`) e repeti-la aqui seria a
				mesma lista em dois lugares, esperando para se desencontrar. Quem escreve e o
				`WaveService`, que cria a chave da dificuldade vencida na hora; quem le trata
				chave ausente como zero. Perfil antigo ganha a tabela pelo reconcile do
				DataService, entao nao precisa migracao -- e ganha vazia: as vitorias de antes
				desta chave nao tem dificuldade registrada e nao ha de onde tira-la.
			]]
			DifficultyWins = {},

			Cash = 0,

			-- Moeda premium. Perfis antigos ganham a chave pelo reconcile do
			-- DataService, entao nao precisa migracao.
			Shards = 0,
			XP = 0,

			--[[
				Contadores que existem para as leaderboards do lobby
				(`Config.Leaderboard`). Nenhum deles muda o jogo: so contam.

				  - `BoxesOpened`   -- caixas abertas de verdade (`CrateService:OpenCrate`);
				                       o `unbox` do Cmdr so mostra a animacao e nao conta.
				  - `MatchesPlayed` -- partidas em que o jogador ficou pelo menos
				                       `MIN_MATCH_SECONDS` (`MatchStatsService`, Game).
				  - `TimeInMatches` -- segundos dentro de um round rodando (idem).
				  - `TimePlayed`    -- segundos com o perfil aberto, nas duas places
				                       (`PlaytimeService`).

				Os tempos sao em **segundos** inteiros; o `DD:HH:MM` e so da tela.

				Nascem em zero para todo mundo, inclusive para quem ja jogava: o perfil
				nunca guardou nada disso, entao nao ha de onde tirar o passado. Perfil
				antigo ganha as chaves pelo reconcile do DataService.

				**`CoinsEarned` (o total de coins ganhos, a MOST COINS) nao esta aqui de
				proposito.** Para ele existe um passado aproximado: o saldo de hoje e o
				minimo que o jogador ja ganhou. Se o template trouxesse a chave, o
				reconcile a poria em zero e ninguem saberia mais quem era perfil antigo.
				Sem ela, o `CurrencyService` ve a chave faltando quando o perfil carrega
				e a cria com o `Cash` atual -- em perfil novo, isso e zero. Quem soma e
				o `WaveService:grantReward`; estorno de loja e o Cmdr nao contam.
			]]
			BoxesOpened = 0,
			MatchesPlayed = 0,
			TimeInMatches = 0,
			TimePlayed = 0,
		},

		Inventory = {
			-- { [Rarity] = amount } for every rarity in CrateConfig.RARITIES
			Crates = CrateConfig.createEmptyCrates(),
		},

		--[[
			A garantia das raridades altas no unboxing: `{ [caixa] = { [raridade] =
			aberturas seguidas sem ela } }`. Nasce vazio e cada caixa ganha a conta dela
			na primeira abertura. Ver `ServerScriptService.Config.Crate.PITY_RARITIES`.
		]]
		Pity = {},

		PurchaseHistory = {},

		--[[
			As gamepasses que o jogador tem, `{ [chave] = true }` -- a chave do
			`SharedConfig.GamepassConfig`, e nao o id numerico da Roblox.

			**Nao e credito, e uma copia.** O `MonetizationService` reescreve a tabela
			inteira a cada entrada, a partir do que a Roblox responde: uma pass
			reembolsada some daqui no proximo login, e nenhum beneficio fica preso no
			perfil. Ela existe so para o resto do jogo nao ter de perguntar a Roblox a
			cada caixa aberta e a cada fim de round.

			Perfil antigo ganha a chave pelo reconcile, entao nao precisa migracao.
		]]
		Gamepasses = {},

		--[[
			O que o jogador ja descobriu, por categoria (`{ [chave] = true }`).

			Estrutura e regras em `SharedConfig.IndexConfig`; quem escreve e o
			`IndexService`. Categoria nova la entra nos perfis antigos pelo reconcile,
			entao nao precisa migracao -- foi por isso que a chave ja nasceu aqui.
		]]
		Index = IndexConfig.createEmpty(),
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

		--[[
			As cartas de round que o jogador destravou, `{ [Id] = true }` — o `Id` do
			`SharedConfig.RoundCardConfig`.

			**Não é inventário, é a pool dele.** Destravar não dá carta nenhuma na mão:
			ele diz que aquela carta pode sair no sorteio da oferta de round, e cada uso
			dentro da partida continua sendo comprado com o caixa da partida. Quem
			escreve é o `RoundCardShopService` (Lobby), na compra na loja de cartas; quem
			lê é o `_pool` do `CardShopService` (Game).

			Nasce com o kit inicial (`RoundCardShopConfig.STARTER_CARDS`), senão a oferta
			de round nunca abriria para quem acabou de chegar. Perfil antigo ganha a chave
			pelo reconcile do DataService — e a ganha **vazia**, porque o reconcile copia o
			template só onde ele falta; quem preenche o que falta nele é o
			`RoundCardStarterService`, que roda em toda abertura de perfil nas duas places.
		]]
		RoundCards = RoundCardShopConfig.createEmpty(),

		--[[
			O reroll pago da loja de cartas: `{ Index, Rolls, Cards }` — o bloco de quatro
			horas, quantos rerolls foram comprados nele e **as cartas sorteadas**.

			As cartas são gravadas, e não recalculadas: o sorteio do reroll varre só o
			que falta ao jogador destravar, e essa lista encolhe quando ele compra. Uma
			prateleira derivada dela se remontaria a cada compra — a vaga vendida se
			encheria com uma carta nova em vez de ficar `SOLD`. Ver o comentário do
			`RoundCardShopConfig.createEmptyRoll`.

			Vale até a rotação virar. Nada apaga o registro velho — ele deixa de valer
			sozinho quando o número do bloco muda.
		]]
		RoundCardRoll = RoundCardShopConfig.createEmptyRoll(),

		--[[
			Os contratos do quadro do lobby, por periodo:
			`{ Hourly|Daily|Weekly = { Period, Slots = { { Id, Params, Progress, Claimed, Seen? } } } }`.

			`Period` e o numero do periodo em que os slots foram sorteados
			(`ContractConfig.periodOf`); quando o de agora e outro, o `ContractService`
			sorteia de novo. `Params` e o que o `Random` do contrato tirou (mapa,
			dificuldade, classe), e `Seen` so existe nos de `Mode = "Distinct"` (os dias do
			login). Estrutura e regras em `SharedConfig.ContractConfig`.

			Nasce com `Period = -1`, que nao e periodo nenhum: o primeiro carregamento ja
			sorteia os tres. Perfil antigo ganha a chave pelo reconcile.
		]]
		Contracts = ContractConfig.createEmpty(),

		-- Quantas cartas cabem no deck. Fica no perfil porque é para crescer com o
		-- jogador; o `DeckConfig.DEFAULT_CARD_LIMIT` é só o valor de partida, e o
		-- reconcile do DataService dá a chave para quem é de antes dela.
		CardLimit = DeckConfig.DEFAULT_CARD_LIMIT,

		--[[
			O assunto "tutorial" está encerrado para este jogador?

			`false` é a única coisa que faz a oferta aparecer no lobby, e ela some por
			**dois** caminhos: vencendo as 5 waves do mapa Tutorial, ou **recusando** a
			oferta. Recusar é uma resposta, não um adiamento — quem disse "não" não é
			perguntado de novo a cada entrada.

			Por consequência, **abandonar a partida no meio deixa a chave em `false`**:
			quem aceitou e saiu antes do fim é perguntado de novo e recomeça da wave 1.
			É de propósito: o estado de meia partida (unidades no mapa, carta comprada,
			clima ativo) não existe em lugar nenhum, e voltar para a wave 3 com o mapa
			vazio seria pior que recomeçar.

			Perfil antigo ganha a chave pelo reconcile do DataService — e ganha
			`false`, porque não há como saber quem já passou por um tutorial que não
			existia. Quem já joga há meses recebe a oferta uma vez, e a primeira
			resposta encerra.
		]]
		Tutorial = false,
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

	--[[
		Quanto tempo dentro de um round para ele contar em `Stats.MatchesPlayed` --
		o "(3min+)" da leaderboard. Sem o piso, entrar e sair da partida seria o
		jeito mais rapido de subir nela.

		E o tempo **do jogador** no round, e nao a duracao do round: quem entra no
		meio conta a partir de quando entrou. Vale para vitoria, derrota e saida no
		meio. O `TimeInMatches` soma o tempo inteiro, ate das partidas curtas.
	]]
	MIN_MATCH_SECONDS = 180,
}
