--[[
	Os buffs e debuffs que as cartas de round deixam no campo.

	Uma carta de round quase nunca faz uma coisa e acaba: ela **deixa uma regra
	valendo**. O Trumpet acelera todo mundo em 15%, o Overcharge separa Electric do
	resto, os cajados desenham um anel no chão onde a regra vale só lá dentro, e o
	Bloxy Cola vale para uma torre só, por dez segundos.

	Este módulo é a gramática dessas regras. Ele não guarda estado nenhum: quem tem
	a lista viva é o `CardModifierService` (servidor) e o `CardModifierController`
	(cliente, para desenhar o anel e mostrar o alcance certo no card). Aqui só mora
	a conta — dado um modificador, uma unidade e o resto do campo, ele vale? E
	quanto?

	Ele é compartilhado porque as duas pontas **precisam** dar a mesma resposta: o
	servidor cobra o dano com o multiplicador, e o círculo de alcance que o jogador
	vê na tela sai da mesma função. Duas contas em dois lugares foi exatamente o
	desencontro que o `UnitUpgradeConfig` já existe para evitar.

	## O que é um modificador

	Um registro plano (ele trafega na rede, então nada de função nem de metatable):

	| Campo | O que é |
	| --- | --- |
	| `Uid` | quem criou; é o `uid` da carta usada, e é por ele que a expiração o tira |
	| `Card` | o `Id` da carta, para log e para a cor do anel |
	| `Stats` | os multiplicadores: `{ Damage = 1.25 }` |
	| `Flags` | o que não é número: hoje só `Cleave` |
	| `Classes` | as classes que ele pega; sem isso, pega todas |
	| `Exclude` | inverte o `Classes`: vale para quem **não** é daquelas classes |
	| `Farm` | `true` só para unidade de renda, `false` só para quem não é |
	| `UnitId` | só aquela unidade |
	| `Zone` | `{ Position, Radius }` — só quem está dentro do anel |
	| `Condition` | uma pergunta sobre a **vizinhança** da unidade (ver abaixo) |
	| `Scaling` | multiplicador que cresce com quantas unidades de uma classe estão no mapa |
	| `BaseHealthBelow` | só vale enquanto a vida da base estiver abaixo desta fração |
	| `ExpiresAt` | o instante do `GameClock` em que ele morre; sem isso, dura o round |

	Uma carta pode criar **vários** registros, e é assim que ela faz duas coisas
	opostas de uma vez: o Overcharge é um `{ Classes = {"Electric"}, Damage = 1.25 }`
	mais um `{ Classes = {"Electric"}, Exclude = true, Damage = 0.89 }`. Escrever os
	dois lados como registros separados é o que permite que a mesma função responda
	pelos dois sem conhecer carta nenhuma.

	## As estatísticas

	Tudo é **multiplicador**, como no clima: 1.25 é "+25%", 0.8 é "-20%".

	| Stat | Onde entra |
	| --- | --- |
	| `Damage` | dano por golpe (`UnitService:getDamage`) |
	| `AttackSpeed` | acima de 1 é bater mais rápido; divide o cooldown |
	| `Range` | alcance, e junto com ele o círculo que o jogador vê |
	| `Income` | a renda da farm (`payFarmUnits`) |
	| `HitIncome` | o caixa que o dano e a morte pagam |
	| `Slow` | quanto a lentidão de uma unidade de gelo pesa |
	| `Burn` | quanto a queimadura cobra por tique |

	`Slow` e `Burn` são globais: eles não descrevem a torre, e sim o estado que ela
	deixou no inimigo. Quem os lê é o `MobService`, pelo `Global`.

	## As condições

	`Condition` é o que não dá para responder olhando só a unidade — ela precisa do
	resto do campo, que chega no `world`:

	- `Isolated`: nenhuma outra unidade dentro de `ConditionRadius`. É o Iceolated,
	  que premia a torre de gelo que ficou sozinha.
	- `NearClass`: existe pelo menos uma unidade da classe `ConditionClass` dentro
	  de `ConditionRadius`. É o outro lado do Ice to Meet You — quem está perto de
	  um gelo trabalha mais devagar.

	As duas medem no plano, ignorando o Y: duas torres em alturas diferentes do
	mesmo pedaço de mapa são vizinhas, e o degrau entre elas não é distância que o
	jogador enxergue.
]]

local UnitStats = require(script.Parent.UnitStats)
local WeatherConfig = require(script.Parent.WeatherConfig)

local CardModifier = {}

--[[
	Os nomes das estatísticas, num lugar só. Quem escreve carta no `RoundCardConfig`
	e quem lê multiplicador no service usam estas chaves — errar o nome de uma
	estatística é uma carta que não faz nada, e é o tipo de erro que não aparece no
	log.
]]
CardModifier.Stats = {
	Damage = "Damage",
	AttackSpeed = "AttackSpeed",
	Range = "Range",
	Income = "Income",
	HitIncome = "HitIncome",
	Slow = "Slow",
	Burn = "Burn",
}

--- O que não é número. Ver `CardModifier.Enabled`.
CardModifier.Flags = {
	Cleave = "Cleave",
}

CardModifier.Conditions = {
	Isolated = "Isolated",
	NearClass = "NearClass",
}

--[[ INTERNAL ]]

local function hasAnyClass(unitName : string?, classes : { string }) : boolean
	for _, class in classes do
		if WeatherConfig.HasClass(unitName, class) then
			return true
		end
	end

	return false
end

--- Unidade de renda (o Entrepreneur e quem vier depois dele).
local function isFarm(unitName : string?) : boolean
	local stats = unitName and UnitStats[unitName]

	return stats ~= nil and stats.Farm ~= nil
end

--[[
	Distância no plano. O Y fica de fora de propósito: o anel do cajado é um círculo
	desenhado no chão, e uma torre em cima de uma pedra dentro dele está dentro dele.
]]
local function flatDistance(a : Vector3, b : Vector3) : number
	return (Vector3.new(a.X, 0, a.Z) - Vector3.new(b.X, 0, b.Z)).Magnitude
end

--[[ API ]]

--[=[
	Quantas unidades do campo estão a até `radius` de `unit`, sem contar ela mesma.

	`className` restringe a contagem a uma classe; sem ele, conta qualquer unidade.
	`world.Units` é a lista de descritores (`{ UnitId, UnitName, Position }`) — sem
	ela não há vizinhança para medir e a resposta é zero, que é o que faz uma
	condição de proximidade simplesmente não valer em vez de estourar.
]=]
function CardModifier.CountNear(world, unit, radius : number, className : string?) : number
	local units = world and world.Units
	if not units or not unit.Position then
		return 0
	end

	local count = 0

	for _, other in units do
		if other.UnitId == unit.UnitId or not other.Position then
			continue
		end

		if className and not WeatherConfig.HasClass(other.UnitName, className) then
			continue
		end

		if flatDistance(other.Position, unit.Position) <= radius then
			count += 1
		end
	end

	return count
end

--- Quantas unidades da classe existem no mapa. É o que o Abrakadabra conta.
function CardModifier.CountClass(world, className : string?) : number
	local units = world and world.Units
	if not units then
		return 0
	end

	local count = 0

	for _, other in units do
		if not className or WeatherConfig.HasClass(other.UnitName, className) then
			count += 1
		end
	end

	return count
end

--[=[
	Este modificador vale para esta unidade?

	Os filtros são cumulativos e a ordem é do mais barato para o mais caro: comparar
	um id não custa nada, e varrer a vizinhança inteira custa — não há por que medir
	distância de uma unidade que já foi recusada pela classe.

	`ExpiresAt` **não** é conferido aqui. Quem tem relógio é o service, e ele poda a
	lista; conferir de novo por unidade e por estatística seria a mesma pergunta
	repetida algumas centenas de vezes por quadro.
]=]
function CardModifier.Applies(modifier, unit, world) : boolean
	if modifier.UnitId and modifier.UnitId ~= unit.UnitId then
		return false
	end

	if modifier.Classes then
		local matches = hasAnyClass(unit.UnitName, modifier.Classes)

		if modifier.Exclude then
			if matches then return false end
		elseif not matches then
			return false
		end
	end

	if modifier.Farm ~= nil and isFarm(unit.UnitName) ~= modifier.Farm then
		return false
	end

	local zone = modifier.Zone
	if zone then
		if not unit.Position or flatDistance(unit.Position, zone.Position) > (zone.Radius or 0) then
			return false
		end
	end

	--[[
		A vida da base é uma fração de 0 a 1. Sem ela na mão (um cliente que ainda
		não recebeu o primeiro `UpdateBaseHealth`) o modificador fica de fora: é
		melhor mostrar o número sem o bônus por um instante do que prometer um bônus
		que o servidor não está dando.
	]]
	if modifier.BaseHealthBelow then
		local ratio = world and world.BaseHealthRatio

		if not ratio or ratio >= modifier.BaseHealthBelow then
			return false
		end
	end

	local condition = modifier.Condition
	if condition == CardModifier.Conditions.Isolated then
		if CardModifier.CountNear(world, unit, modifier.ConditionRadius or 0) > 0 then
			return false
		end
	elseif condition == CardModifier.Conditions.NearClass then
		if CardModifier.CountNear(world, unit, modifier.ConditionRadius or 0, modifier.ConditionClass) <= 0 then
			return false
		end
	end

	return true
end

--[=[
	O multiplicador de uma estatística para uma unidade: o produto de tudo que se
	aplica a ela.

	Produto, e não substituição como no clima. São duas coisas diferentes: o clima é
	um só e escreve o número final por classe, enquanto as cartas são compradas uma
	a uma e **empilham** de propósito — quem gastou dois usos no mesmo tipo de torre
	tem que ver os dois valendo.

	`Scaling` entra aqui também, e é o que dá o Abrakadabra: em vez de um número
	fixo, o multiplicador é `1 + (unidades da classe) * Amount`.
]=]
function CardModifier.Multiplier(modifiers, stat : string, unit, world) : number
	if not modifiers then return 1 end

	local total = 1

	for _, modifier in modifiers do
		if not CardModifier.Applies(modifier, unit, world) then
			continue
		end

		local value = modifier.Stats and modifier.Stats[stat]
		if value then
			total *= value
		end

		local scaling = modifier.Scaling
		if scaling and scaling.Stat == stat then
			total *= 1 + CardModifier.CountClass(world, scaling.Class) * (scaling.Amount or 0)
		end
	end

	return total
end

--[=[
	Um `Flags` ligado para esta unidade.

	Existe separado do `Multiplier` porque nem tudo que uma carta faz é um número.
	"O corpo a corpo passa a acertar quem está atrás" não tem meio termo: ou o golpe
	pega o de trás ou não pega, e escrever isso como um multiplicador 1.0 seria uma
	mentira que a próxima pessoa a ler tentaria multiplicar.
]=]
function CardModifier.Enabled(modifiers, flag : string, unit, world) : boolean
	return CardModifier.FlagValue(modifiers, flag, unit, world) ~= nil
end

--[=[
	O **valor** de um `Flags` ligado para esta unidade, ou `nil`.

	O valor costuma ser a tabela de números que aquele comportamento precisa — o
	Cleave carrega quantos corpos o golpe pega, quanto o segundo perde e a largura
	do risco. Eles moram no modificador, e não numa constante do `UnitService`,
	porque quem os escolhe é a carta: uma segunda carta de corte com números
	próprios não devia ter que mexer no combate para existir.

	O **primeiro** que se aplica manda. Duas cartas de corte ao mesmo tempo é um
	caso que não existe hoje, e somar os números de duas seria inventar um terceiro
	comportamento que ninguém pediu.
]=]
function CardModifier.FlagValue(modifiers, flag : string, unit, world)
	if not modifiers then return nil end

	for _, modifier in modifiers do
		local value = modifier.Flags and modifier.Flags[flag]

		if value and CardModifier.Applies(modifier, unit, world) then
			return value
		end
	end

	return nil
end

--[=[
	O multiplicador de uma estatística que **não** é de nenhuma unidade em
	particular: a queimadura que já está no inimigo, a lentidão que já foi aplicada.

	Só entram os modificadores sem filtro nenhum. Um modificador de zona ou de
	classe descreve torres, e a queimadura no inimigo não sabe de qual torre ela
	veio — deixá-lo contar aqui faria um anel desenhado num canto do mapa mexer numa
	queimadura do outro.
]=]
function CardModifier.Global(modifiers, stat : string) : number
	if not modifiers then return 1 end

	local total = 1

	for _, modifier in modifiers do
		if modifier.UnitId or modifier.Classes or modifier.Zone or modifier.Condition or modifier.Farm ~= nil then
			continue
		end

		local value = modifier.Stats and modifier.Stats[stat]
		if value then
			total *= value
		end
	end

	return total
end

return CardModifier
