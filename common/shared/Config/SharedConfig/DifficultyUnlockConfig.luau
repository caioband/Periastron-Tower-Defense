--[[
	O cadeado das dificuldades: quem pode votar em que.

	Facil e Medio nao aparecem na tabela -- **dificuldade sem entrada aqui e livre**,
	e e por onde todo jogador novo comeca. As tres de cima pedem uma de duas coisas,
	e basta **uma**:

		| Dificuldade | Vitorias            | ou Nivel |
		| Hard        | 4 no Medium         |        3 |
		| Impossible  | 4 no Hard           |        6 |
		| Nightmare   | 6 no Impossible     |       12 |

	As duas fontes existem porque medem coisas diferentes. As vitorias na dificuldade
	de baixo dizem que o jogador **da conta** dela -- e o caminho curto de quem esta
	jogando bem. O nivel e a rede: quem perde muito mas joga muito tambem chega,
	porque XP cai em derrota e em run abandonada (ver `WaveService.computeReward`), e
	so vitoria travaria o jogador ruim no Medium para sempre.

	`Wins` conta a **dificuldade de baixo**, e nao a que esta sendo destravada: nao ha
	como ganhar no Nightmare antes de ele abrir. Isso tambem faz a escada ser
	sequencial pelo lado das vitorias -- para as 6 do Impossible o jogador precisou
	antes destravar o Impossible -- enquanto o lado do nivel pode saltar degraus.

	As vitorias por dificuldade moram em `Stats.DifficultyWins` no perfil
	(`{ [dificuldade] = quantas }`), escrito so pelo `WaveService` no fim de uma run
	vencida. O nivel nao e guardado: sai do `Stats.XP` pelo `LevelConfig:Resolve`,
	igual ao HUD do lobby.

	Nada aqui e sigiloso, e por isso este arquivo esta no config compartilhado e nao
	junto dos presets (`ServerScriptService.Config.Difficulty`, onde estao as tabelas
	de escala das waves). E a mesma conta nas duas pontas, como nos mapas: o
	`DifficultyController` desenha o `Locked` com ela e o `DifficultyService` recusa o
	voto com ela. O cliente calcular junto e so o cadeado aparecer antes de perguntar
	nada ao servidor.
]]

local LevelConfig = require(script.Parent.LevelConfig)

local module = {}

--[=[
	A chave do perfil onde as vitorias por dificuldade ficam. Escrita aqui para o
	`WaveService` e a leitura deste modulo nao poderem se desencontrar.
]=]
module.WINS_KEY = "DifficultyWins"

export type Requirement = {
	Wins : number,
	WinsIn : string,
	Level : number,
}

module.REQUIREMENTS = {
	Hard = { Wins = 4, WinsIn = "Medium", Level = 3 },
	Impossible = { Wins = 4, WinsIn = "Hard", Level = 6 },
	Nightmare = { Wins = 6, WinsIn = "Impossible", Level = 12 },
} :: { [string] : Requirement }

--[[ API ]]

--[=[
	O que a dificuldade pede, ou nil quando ela e livre.
]=]
function module.getRequirement(difficultyName : string?) : Requirement?
	if typeof(difficultyName) ~= "string" then
		return nil
	end

	return module.REQUIREMENTS[difficultyName]
end

--[=[
	Quantas vitorias o jogador tem **naquela** dificuldade.

	Perfil que ainda nao chegou, ou chave que ainda nao existe, valem zero -- o
	mesmo chute dos mapas: com ele so o que e livre aparece livre, e nunca o
	contrario.
]=]
function module.winsIn(stats : { [string] : any }?, difficultyName : string?) : number
	if typeof(stats) ~= "table" or typeof(difficultyName) ~= "string" then
		return 0
	end

	local wins = stats[module.WINS_KEY]
	if typeof(wins) ~= "table" then
		return 0
	end

	return math.max(math.floor(tonumber(wins[difficultyName]) or 0), 0)
end

--[=[
	O nivel do perfil, derivado do XP acumulado. Sem perfil, nivel 1.
]=]
function module.levelOf(stats : { [string] : any }?) : number
	local xp = typeof(stats) == "table" and stats.XP or 0

	return LevelConfig:Resolve(xp).Level
end

--[=[
	Se este jogador ja pode escolher a dificuldade.

	Basta uma das duas exigencias. Dificuldade sem exigencia nenhuma esta sempre
	aberta, e nome desconhecido tambem passa: quem chama ja tratou o nome invalido
	(o `DifficultyConfig.Exists` do servidor), e trancar aqui esconderia botao por
	engano.
]=]
function module.isUnlocked(difficultyName : string?, stats : { [string] : any }?) : boolean
	local requirement = module.getRequirement(difficultyName)
	if not requirement then
		return true
	end

	if module.winsIn(stats, requirement.WinsIn) >= requirement.Wins then
		return true
	end

	return module.levelOf(stats) >= requirement.Level
end

--[=[
	Quantas vitorias ainda faltam pelo caminho das vitorias, ou zero quando a
	dificuldade ja abriu. E o numero que o texto do cadeado escreve.
]=]
function module.winsMissing(difficultyName : string?, stats : { [string] : any }?) : number
	local requirement = module.getRequirement(difficultyName)
	if not requirement or module.isUnlocked(difficultyName, stats) then
		return 0
	end

	return math.max(requirement.Wins - module.winsIn(stats, requirement.WinsIn), 0)
end

--[=[
	O texto do `Locked`: "4 more wins in Medium or Level 3".

	Sai vazio para dificuldade livre ou ja destravada -- nesses casos o frame nem
	esta na tela. Os dois caminhos aparecem juntos de proposito: o jogador precisa
	ver que existe uma saida que nao depende de vencer.
]=]
function module.lockText(difficultyName : string?, stats : { [string] : any }?) : string
	local requirement = module.getRequirement(difficultyName)
	if not requirement or module.isUnlocked(difficultyName, stats) then
		return ""
	end

	local missing = module.winsMissing(difficultyName, stats)

	return string.format(
		"%d more %s in %s or Level %d",
		missing,
		missing == 1 and "win" or "wins",
		requirement.WinsIn,
		requirement.Level)
end

return module
