local Difficulty = require(script.Parent.Difficulty)

local Wave = {}

--[[
	A composicao de cada wave.

	A tabela abaixo e a planilha do Dificil (`Game/PTD - Hard Difficulty - Hard
	Difficulty - Redcliff Knights.csv`) transcrita: 25 waves desenhadas a mao, com
	a quantidade de cada inimigo por wave. E a fonte de verdade da composicao — o
	Dificil usa a planilha linha por linha, sem multiplicar quantidade nenhuma.

	A coluna de vida total da planilha, porem, e so o piso: a vida de cada inimigo
	ainda cresce com a wave (ver o item 3 abaixo), entao a wave 25 do Dificil pesa
	mais do que os 1.925 que a planilha soma.

	As outras dificuldades saem desta mesma tabela por duas vias, e so por elas:

	  1. A duracao. Cada preset tem o seu `MaxWaves`, e a wave N de um preset com M
	     waves le a posicao `1 + (N-1)/(M-1) * 24` da tabela. O Facil atravessa as
	     25 linhas em 15 waves (pulando composicoes), o Nightmare atravessa em 35
	     (interpolando entre linhas vizinhas). Nas pontas isso sempre bate: a wave 1
	     e a linha 1 e a ultima wave e a linha 25 — a do chefe.

	  2. Os multiplicadores do preset: `AmountMultiplier` na quantidade e
	     `RewardMultiplier` na caixa por morte.

	  3. A vida, que o MobService calcula a parte: `HealthMultiplier *
	     HealthGrowth^(wave-1)`. O crescimento e por wave, entao a mesma linha da
	     tabela pesa mais no fim da partida do que pesaria no comeco — e pesa mais
	     ainda nos presets duros, que crescem mais rapido.
]]

local BOSS_ENTITY = "RedcliffChampion"

--[[
	Ordem de spawn dentro de uma wave. O loop do MobService percorre as entradas em
	sequencia, entao esta lista decide quem entra primeiro: do mais fraco ao mais
	forte, com o chefe por ultimo.
]]
local SPAWN_ORDER = {
	"Traveler",
	"RedcliffPawn",
	"RedcliffSquire",
	"RedcliffGuard",
	"WallSmasher",
	"CourageBearer",
	"WingedSquire",
	"RedcliffEnforcer",
	"RedcliffChampion",
}

--[[
	Caixa por morte e intervalo entre um spawn e o proximo, por inimigo.

	As recompensas sao a fonte principal de renda (o pagamento por dano vale 0,15
	por ponto efetivo, ver `Config.Data`), e estao calibradas para o Dificil render
	cerca de 9.000 de caixa ao longo das 25 waves — o suficiente para umas dez
	unidades com melhorias, comecando dos 400 iniciais.
]]
local ENTITY_DATA = {
	Traveler = { Reward = 3, SpawnDelay = 0.35 },
	RedcliffPawn = { Reward = 5, SpawnDelay = 0.35 },
	RedcliffSquire = { Reward = 4, SpawnDelay = 0.3 },
	RedcliffGuard = { Reward = 9, SpawnDelay = 0.4 },
	WallSmasher = { Reward = 7, SpawnDelay = 0.32 },
	CourageBearer = { Reward = 7, SpawnDelay = 0.32 },
	WingedSquire = { Reward = 18, SpawnDelay = 0.32 },
	RedcliffEnforcer = { Reward = 45, SpawnDelay = 0.45 },
	RedcliffChampion = { Reward = 250, SpawnDelay = 1 },
}

--[[
	Quantidade de cada inimigo por wave, direto da planilha do Dificil. O chefe so
	aparece na ultima linha, e e o `BossAmountMultiplier` do preset que decide
	quantos dele entram de fato.
]]
local WAVE_TABLE = {
	{ Traveler = 4, RedcliffSquire = 2 },
	{ Traveler = 6, RedcliffSquire = 3 },
	{ Traveler = 8, RedcliffPawn = 2, RedcliffSquire = 4 },
	{ Traveler = 8, RedcliffPawn = 3, RedcliffSquire = 6 },
	{ Traveler = 6, RedcliffPawn = 4, RedcliffSquire = 6, RedcliffGuard = 2 },
	{ Traveler = 4, RedcliffPawn = 5, RedcliffSquire = 5, RedcliffGuard = 4 },
	{ Traveler = 5, RedcliffPawn = 6, RedcliffSquire = 5, RedcliffGuard = 5 },
	{ Traveler = 6, RedcliffPawn = 7, RedcliffSquire = 6, RedcliffGuard = 6 },
	{ Traveler = 7, RedcliffPawn = 8, RedcliffSquire = 7, RedcliffGuard = 7 },
	{ Traveler = 8, RedcliffPawn = 9, RedcliffSquire = 8, RedcliffGuard = 8 },
	{ Traveler = 6, RedcliffPawn = 9, RedcliffSquire = 8, RedcliffGuard = 7, WallSmasher = 1, CourageBearer = 2 },
	{ Traveler = 5, RedcliffPawn = 10, RedcliffSquire = 9, RedcliffGuard = 8, WallSmasher = 2, CourageBearer = 2 },
	{ Traveler = 4, RedcliffPawn = 11, RedcliffSquire = 9, RedcliffGuard = 9, WallSmasher = 2, CourageBearer = 3 },
	{ Traveler = 3, RedcliffPawn = 12, RedcliffSquire = 10, RedcliffGuard = 10, WallSmasher = 3, CourageBearer = 3 },
	{ Traveler = 2, RedcliffPawn = 12, RedcliffSquire = 11, RedcliffGuard = 11, WallSmasher = 4, CourageBearer = 3, WingedSquire = 1 },
	{ Traveler = 2, RedcliffPawn = 13, RedcliffSquire = 11, RedcliffGuard = 12, WallSmasher = 4, CourageBearer = 4, WingedSquire = 2 },
	{ Traveler = 1, RedcliffPawn = 14, RedcliffSquire = 12, RedcliffGuard = 13, WallSmasher = 5, CourageBearer = 4, WingedSquire = 2 },
	{ RedcliffPawn = 15, RedcliffSquire = 13, RedcliffGuard = 14, WallSmasher = 5, CourageBearer = 4, WingedSquire = 3, RedcliffEnforcer = 1 },
	{ RedcliffPawn = 15, RedcliffSquire = 13, RedcliffGuard = 14, WallSmasher = 6, CourageBearer = 5, WingedSquire = 3, RedcliffEnforcer = 1 },
	{ RedcliffPawn = 16, RedcliffSquire = 14, RedcliffGuard = 15, WallSmasher = 6, CourageBearer = 5, WingedSquire = 4, RedcliffEnforcer = 2 },
	{ RedcliffPawn = 16, RedcliffSquire = 14, RedcliffGuard = 15, WallSmasher = 5, CourageBearer = 4, WingedSquire = 3, RedcliffEnforcer = 2 },
	{ RedcliffPawn = 17, RedcliffSquire = 15, RedcliffGuard = 16, WallSmasher = 7, CourageBearer = 6, WingedSquire = 4, RedcliffEnforcer = 3 },
	{ RedcliffPawn = 17, RedcliffSquire = 15, RedcliffGuard = 16, WallSmasher = 6, CourageBearer = 5, WingedSquire = 4, RedcliffEnforcer = 3 },
	{ RedcliffPawn = 18, RedcliffSquire = 16, RedcliffGuard = 17, WallSmasher = 8, CourageBearer = 7, WingedSquire = 5, RedcliffEnforcer = 3 },
	{ RedcliffPawn = 9, RedcliffSquire = 10, RedcliffGuard = 12, WallSmasher = 2, CourageBearer = 3, WingedSquire = 5, RedcliffEnforcer = 3, RedcliffChampion = 1 },
}

local TABLE_LENGTH = #WAVE_TABLE

--[=[
	Onde a wave cai na tabela. Devolve um numero fracionario entre 1 e 25: a parte
	inteira e a linha, e a fracao e o quanto ela ja andou na direcao da proxima.
]=]
--[[
	O premio por wave concluida, pago a TODOS os jogadores da partida.

	E renda de time: nao depende de quem bateu, de quem matou nem de quem colocou
	unidade. Sai uma vez, quando a wave termina de verdade -- wave perdida (game
	over) nao paga.

	O premio e **acumulativo**: cada faixa diz quanto uma wave soma sobre a
	anterior, e o valor da wave N e a soma dos passos de todas as waves ate ela.
	Com as faixas de hoje: 25, 50, 75... ate 250 na wave 10, e daí de 50 em 50 --
	300 na 11, 1.250 na 30.

	`UpTo` e a ultima wave da faixa; a ultima entrada nao tem `UpTo` e vale dali em
	diante, o que importa porque o `MaxWaves` varia por dificuldade e o Nightmare
	vai ate a wave 35 (1.500 la).
]]
Wave.CASH_TIERS = {
	{ UpTo = 10, Step = 25 },
	{ Step = 50 },
}

--[=[
	Quanto a wave `waveNumber` paga a cada jogador. Wave invalida devolve 0.
]=]
function Wave.GetWaveCash(waveNumber : number?) : number
	if typeof(waveNumber) ~= "number" or waveNumber < 1 then
		return 0
	end

	local total = 0
	local from = 1

	for _, tier in Wave.CASH_TIERS do
		local last = math.min(tier.UpTo or waveNumber, waveNumber)
		if last < from then break end

		total += (last - from + 1) * (tier.Step or 0)
		from = last + 1

		if from > waveNumber then break end
	end

	return total
end

local function tablePosition(waveNumber : number, preset)
	local total = preset.MaxWaves or TABLE_LENGTH
	if total <= 1 then
		return TABLE_LENGTH
	end

	local clamped = math.clamp(waveNumber, 1, total)
	return 1 + ((clamped - 1) / (total - 1)) * (TABLE_LENGTH - 1)
end

--[=[
	Quantos inimigos deste tipo a wave traz, interpolando entre as duas linhas
	vizinhas da tabela. Zero significa que o tipo nao aparece nesta wave.
]=]
local function amountAt(entity : string, position : number, preset) : number
	local lower = math.clamp(math.floor(position), 1, TABLE_LENGTH)
	local upper = math.min(lower + 1, TABLE_LENGTH)
	local alpha = position - lower

	local from = WAVE_TABLE[lower][entity] or 0
	local to = WAVE_TABLE[upper][entity] or 0
	local interpolated = from + ((to - from) * alpha)

	return math.max(0, math.floor((interpolated * (preset.AmountMultiplier or 1)) + 0.5))
end

local function buildSpawnEntry(entity : string, amount : number, preset)
	local data = ENTITY_DATA[entity]
	return {
		Entity = entity,
		Amount = amount,
		Reward = math.max(1, math.floor((data.Reward * preset.RewardMultiplier) + 0.5)),
		SpawnDelay = math.max(0.05, data.SpawnDelay * preset.SpawnDelayMultiplier),
	}
end

--[=[
	Se a wave traz o chefe. O cliente nao ve esta config (ela e so de servidor),
	entao quem precisa saber recebe a resposta junto do evento `SetWave` — e a
	musica de boss depende disso.

	O chefe fecha a partida: e a ultima linha da tabela, e a ultima wave de
	qualquer preset cai nela.
]=]
function Wave.HasBoss(waveNumber : number, difficultyName : string?)
	local preset = Difficulty.Get(difficultyName)
	return waveNumber >= (preset.MaxWaves or TABLE_LENGTH)
end

--- Se a entidade e o chefe. Quem pergunta e o `MobService`, que conta os chefes que
--- cada jogador derrubou (o contrato "Defeat 70 bosses").
function Wave.IsBoss(entityName : string?) : boolean
	return entityName == BOSS_ENTITY
end

function Wave.GetSpawns(waveNumber : number, difficultyName : string?)
	local preset = Difficulty.Get(difficultyName)
	local position = tablePosition(waveNumber, preset)
	local spawns = {}

	for _, entity in SPAWN_ORDER do
		if entity == BOSS_ENTITY then
			continue
		end

		local amount = amountAt(entity, position, preset)
		if amount > 0 then
			table.insert(spawns, buildSpawnEntry(entity, amount, preset))
		end
	end

	if Wave.HasBoss(waveNumber, difficultyName) then
		local bossAmount = math.max(1, math.floor(((WAVE_TABLE[TABLE_LENGTH][BOSS_ENTITY] or 1)
			* (preset.BossAmountMultiplier or 1)) + 0.5))

		table.insert(spawns, buildSpawnEntry(BOSS_ENTITY, bossAmount, preset))
	end

	return spawns
end

return Wave
