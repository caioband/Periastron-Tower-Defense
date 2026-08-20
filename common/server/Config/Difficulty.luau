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
		WinCashMultiplier = 0.5,
		WinShardMultiplier = 0.5,
		WinXpMultiplier = 0.75,
		SpawnDelayMultiplier = 1.25,
		StartingCash = 750,
		BaseHealth = 180,
		MobDamage = 15,
		IntermissionTime = 60,
		WaveInterval = 10,
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
		WinCashMultiplier = 1,
		WinShardMultiplier = 1,
		WinXpMultiplier = 1,
		SpawnDelayMultiplier = 1.1,
		StartingCash = 500,
		BaseHealth = 140,
		MobDamage = 20,
		IntermissionTime = 60,
		WaveInterval = 8,
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
		WinCashMultiplier = 1.75,
		WinShardMultiplier = 2,
		WinXpMultiplier = 1.4,
		SpawnDelayMultiplier = 1,
		StartingCash = 400,
		BaseHealth = 125,
		MobDamage = 25,
		IntermissionTime = 45,
		WaveInterval = 6,
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
		WinCashMultiplier = 2.75,
		WinShardMultiplier = 2.5,
		WinXpMultiplier = 1.8,
		SpawnDelayMultiplier = 0.9,
		StartingCash = 350,
		BaseHealth = 100,
		MobDamage = 25,
		IntermissionTime = 40,
		WaveInterval = 5,
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
		WinCashMultiplier = 4,
		WinShardMultiplier = 3,
		WinXpMultiplier = 2.5,
		SpawnDelayMultiplier = 0.8,
		StartingCash = 300,
		BaseHealth = 75,
		MobDamage = 25,
		IntermissionTime = 30,
		WaveInterval = 4,
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
