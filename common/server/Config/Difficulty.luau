--[[
	Os presets de dificuldade.

	A planilha de waves em `Config.Wave` cuida da composicao — quantos inimigos e
	de que tipo — e cada preset so escala o tamanho dela: `HealthMultiplier`,
	`AmountMultiplier` e `BossAmountMultiplier` engordam a wave sem mudar o que vem
	dentro. Ate o Medio o numero de bosses fica em 1; do Dificil para cima os tres
	crescem juntos, ate 6,75x de vida, 5,25x de inimigos e 9x de bosses no topo.

	A progressao tem duas fontes, e elas se somam. Alem do tamanho da wave, o
	`HealthGrowth` cuida da vida de cada mob e compoe por wave — a vida de um mob
	na wave N e `HealthMultiplier * HealthGrowth^(N-1)`. Quanto mais dura a
	dificuldade, mais rapido esse juro corre: 1,5% por wave no Facil e 5% no
	Nightmare, o que na ultima wave de cada preset da 1,2x no Facil e 5,2x no
	Nightmare.

	O expoente e por wave, entao presets longos acumulam mais: e de proposito, mas
	e tambem o que explode rapido se alguem subir esses numeros. Uma referencia:
	este mesmo campo ja esteve em 1,08 e fazia a ultima wave do preset do topo ter
	inimigos 44x mais gordos que os da primeira.

	A velocidade segue a mesma ideia com numeros bem menores: `SpeedMultiplier` e o
	piso do preset, `SpeedGrowth` e o quanto ela sobe por wave e `SpeedGrowthCap` e
	o teto que esse acumulo pode alcancar. O teto existe porque velocidade quebra
	mais rapido que vida: mob rapido demais atravessa o alcance da torre entre um
	tiro e o proximo, e alguns inimigos ainda multiplicam a propria velocidade por
	conta (o Wall Smasher ganha 30% a cada curva, ate cinco vezes).

	`BaseHealth` dividido por `MobDamage` e quantos vazamentos o jogador aguenta:
	12 no Facil, 7 no Medio, 5 no Dificil, 4 no Impossivel e 3 no Nightmare.

	`WinCash` e `WinShards` sao o premio de **uma run completa**, ja em moeda e nao
	em multiplicador -- quanto o Nightmare paga se le direto na tabela, sem precisar
	multiplicar por uma base em outro arquivo. Quem sai antes do fim leva a parte
	proporcional (ver `WaveService.computeReward`): coins sao lineares na fracao de
	waves, e shards so entram depois da metade da run e dai por uma curva, entao a
	moeda cara fica com quem chega perto do fim. O XP e o unico que continua sendo
	base vezes multiplicador (`Data.BASE_WINNING_XP` vezes `WinXpMultiplier`).

		| Dificuldade | Coins | Shards |
		| Easy        |   100 |      1 |
		| Medium      |   225 |      2 |
		| Hard        |   450 |      3 |
		| Impossible  |   685 |      4 |
		| Nightmare   |   900 |      5 |

	`WeatherChance` e a chance, por wave, de sair um aviso de clima — o clima em si
	cai tres waves depois (ver `WeatherConfig.Round`). O dado so e jogado quando nao
	houver nenhum clima agendado nem no ar, entao o numero nao e "quantas waves tem
	clima": e a pressa com que o proximo aparece depois que o anterior sai. Nos
	valores de hoje, no Facil sai um a cada ~10 waves de intervalo livre e no
	Nightmare a cada ~2,5 — o que, somado aos presets serem mais longos la em cima,
	e o que faz a dificuldade mudar tambem o quanto o mapa e imprevisivel.
]]

local Difficulty = {}

Difficulty.Default = "Medium"

Difficulty.Order = {
	"Easy",
	"Medium",
	"Hard",
	"Impossible",
	"Nightmare",
}

Difficulty.Presets = {
	--[[
		O tutorial.

		**Fora do `Order` de propósito**: ele não é uma dificuldade que se vota, é a
		que a partida de tutorial impõe. O `Difficulty.Get` acha qualquer preset da
		tabela, então ficar fora da lista de votação não o torna inalcançável.

		Os números são de uma partida que o jogador **tem** de ganhar: mob com um
		terço da vida, metade da quantidade, base com 500 de vida e dano de mob em 5
		— perder aqui exigiria esforço. `StartingCash` cobre o deck inteiro do
		tutorial (Archer 150 x2 + Slasher 90 = 390) com folga, porque o jogador
		coloca uma unidade na wave 1 e as outras duas na wave 5, e ficar sem dinheiro
		no meio de um roteiro é o único jeito de ele travar.

		`WeatherChance = 0` porque o clima do tutorial é roteirizado: quem o liga, na
		wave 3, é o `TutorialMatchService` — não o sorteio.

		`WinCash`/`WinShards` são o prêmio da run completa, e a conta do
		`computeReward` chega neles inteiros quando as 5 waves são vencidas: 50 coins
		e 1 shard, como pedido.
	]]
	Tutorial = {
		--[[
			As cinco waves são as cinco **primeiras** linhas da tabela, e não a tabela
			inteira comprimida em cinco — ver `TableRows` no `Config.Wave`. Sem isto a
			wave 2 do tutorial vinha com doze inimigos, incluindo Guard e Pawn.
		]]
		TableRows = 5,

		--[[
			A wave 5 é só o chefe, e um chefe fraco.

			`BossWaveOnly` tira a escolta (ver `Config.Wave.GetSpawns`): a primeira vez
			que alguém vê um chefe não deve ser no meio de dez inimigos comuns.

			`BossHealthMultiplier` é por cima do `HealthMultiplier`, e o número é
			pequeno de propósito: 900 de vida do Champion × 0.35 da dificuldade × 0.15
			daqui dá cerca de 47, que três torres derrubam. O chefe continua sendo ele
			— mesma lentidão, mesmo gimmick, mesma barra —, só não é uma parede.
		]]
		BossWaveOnly = true,
		BossHealthMultiplier = 0.15,

		--[[
			A wave 3 é a do clima: ela chega com o céu virado e o jogador aprendendo a
			usar a carta que o limpa. Metade dos inimigos, porque a lição já é duas.
		]]
		WaveAmountScale = { [3] = 0.5 },

		WeatherChance = 0,
		HealthMultiplier = 0.35,
		HealthGrowth = 1.01,
		SpeedMultiplier = 0.85,
		SpeedGrowth = 1,
		SpeedGrowthCap = 1,
		AmountMultiplier = 0.5,
		BossAmountMultiplier = 1,
		RewardMultiplier = 1.5,
		WinCash = 50,
		WinShards = 1,
		WinXpMultiplier = 0.5,
		SpawnDelayMultiplier = 1.4,
		StartingCash = 500,
		BaseHealth = 500,

		--[[
			A base do tutorial não morre.

			Zero dano por inimigo que escapa é o jeito de dizer "vida infinita" que
			deixa a barra **cheia** na tela, e não um número absurdo escrito nela: quem
			está aprendendo a colocar a primeira torre não deve descobrir o que é perder
			antes de descobrir o que é jogar.

			É zero, e não um `BaseHealth` gigante, porque a conta é a mesma de sempre
			(`MobService:mobEscaped`) e continua valendo — nenhum caminho novo, nenhuma
			exceção espalhada pelo código. O `or` que lê este campo trata o zero como
			valor, e não como ausência, então ele chega inteiro lá.
		]]
		MobDamage = 0,

		IntermissionTime = 45,
		WaveInterval = 1.5,
		MaxWaves = 5,
	},

	Easy = {
		WeatherChance = 0.10,
		HealthMultiplier = 0.5,
		HealthGrowth = 1.015,
		SpeedMultiplier = 0.9,
		SpeedGrowth = 1.004,
		SpeedGrowthCap = 1.15,
		AmountMultiplier = 0.7,
		BossAmountMultiplier = 1,
		RewardMultiplier = 1.35,
		WinCash = 100,
		WinShards = 1,
		WinXpMultiplier = 0.75,
		SpawnDelayMultiplier = 1.25,
		StartingCash = 750,
		BaseHealth = 180,
		MobDamage = 15,
		IntermissionTime = 60,
		WaveInterval = 1.25,
		MaxWaves = 15,
	},

	Medium = {
		WeatherChance = 0.15,
		HealthMultiplier = 1.2,
		HealthGrowth = 1.022,
		SpeedMultiplier = 1,
		SpeedGrowth = 1.006,
		SpeedGrowthCap = 1.25,
		AmountMultiplier = 1.5,
		BossAmountMultiplier = 1,
		RewardMultiplier = 1.1,
		WinCash = 225,
		WinShards = 2,
		WinXpMultiplier = 1,
		SpawnDelayMultiplier = 1.1,
		StartingCash = 500,
		BaseHealth = 140,
		MobDamage = 20,
		IntermissionTime = 60,
		WaveInterval = 1.25,
		MaxWaves = 20,
	},

	Hard = {
		WeatherChance = 0.22,
		HealthMultiplier = 2,
		HealthGrowth = 1.03,
		SpeedMultiplier = 1.1,
		SpeedGrowth = 1.008,
		SpeedGrowthCap = 1.35,
		AmountMultiplier = 2,
		BossAmountMultiplier = 2,
		RewardMultiplier = 1,
		WinCash = 450,
		WinShards = 3,
		WinXpMultiplier = 1.4,
		SpawnDelayMultiplier = 1,
		StartingCash = 400,
		BaseHealth = 125,
		MobDamage = 25,
		IntermissionTime = 45,
		WaveInterval = 1.25,
		MaxWaves = 25,
	},

	Impossible = {
		WeatherChance = 0.30,
		HealthMultiplier = 3.625,
		HealthGrowth = 1.04,
		SpeedMultiplier = 1.2,
		SpeedGrowth = 1.01,
		SpeedGrowthCap = 1.5,
		AmountMultiplier = 3.25,
		BossAmountMultiplier = 5,
		RewardMultiplier = 0.85,
		WinCash = 685,
		WinShards = 4,
		WinXpMultiplier = 1.8,
		SpawnDelayMultiplier = 0.9,
		StartingCash = 350,
		BaseHealth = 100,
		MobDamage = 25,
		IntermissionTime = 40,
		WaveInterval = 1.25,
		MaxWaves = 30,
	},

	Nightmare = {
		WeatherChance = 0.40,
		HealthMultiplier = 6.75,
		HealthGrowth = 1.05,
		SpeedMultiplier = 1.35,
		SpeedGrowth = 1.012,
		SpeedGrowthCap = 1.7,
		AmountMultiplier = 5.25,
		BossAmountMultiplier = 9,
		RewardMultiplier = 0.7,
		WinCash = 900,
		WinShards = 5,
		WinXpMultiplier = 2.5,
		SpawnDelayMultiplier = 0.8,
		StartingCash = 300,
		BaseHealth = 75,
		MobDamage = 25,
		IntermissionTime = 30,
		WaveInterval = 1.25,
		MaxWaves = 35,
	},
}

for name, preset in Difficulty.Presets do
	preset.Name = name
end

function Difficulty.Exists(name : string?)
	return typeof(name) == "string" and Difficulty.Presets[name] ~= nil
end

function Difficulty.Get(name : string?)
	if Difficulty.Exists(name) then
		return Difficulty.Presets[name]
	end

	return Difficulty.Presets[Difficulty.Default]
end

return Difficulty
