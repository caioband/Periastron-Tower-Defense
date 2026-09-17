local UnitStats = require(script.Parent.UnitStats)
local WeatherConfig = require(script.Parent.WeatherConfig)

--[[
	Como cada unidade cresce de nivel em nivel.

	O caminho normal e a formula: `BaseCost * CostMultiplier ^ nivel` para o preco,
	`Damage * DamageMultiplier ^ nivel` para o dano, `Cooldown * CooldownMultiplier ^
	nivel` para a cadencia. E o que a `Default` faz, e e o que a maioria das unidades
	usa -- uma progressao geometrica cabe em tres numeros e nao tem como ficar
	dessincronizada de si mesma.

	Algumas unidades, porem, tem escadas **desenhadas na mao**, e progressao
	geometrica nenhuma passa por todos os degraus delas. Para essas ha dois campos
	opcionais:

	| Campo | O que e |
	| --- | --- |
	| `Costs` | o preco de cada upgrade, um por nivel comprado (indice = nivel atual + 1). Manda no `BaseCost`/`CostMultiplier` |
	| `Cooldowns` | o cooldown de cada nivel (indice = nivel + 1), do 0 ao maximo. Manda no `CooldownMultiplier`, e o item 1 tem que ser o `Cooldown` do `UnitStats` |

	Hoje o Slasher, o Sword, o Slingshot e o Archer usam `Costs`, porque a escada de
	preco deles foi desenhada por wave e nao por formula: os saltos sao desiguais de
	proposito. `Cooldowns` so o Slingshot usa -- os 0,55s ate 0,32s dele nao sao
	geometricos.

	A regra para escolher e simples: **se a formula reproduz a tabela exatamente, use
	a formula**. Ela documenta a intencao (o alvo do nivel maximo) e continua valendo
	se o `MaxUpgrades` mudar; a lista nao. O alcance tem a mesma escolha, e ela mora
	no `RangeStats` do `UnitStats`.
]]
local UnitUpgradeConfig = {
	MaxUpgrades = 5,
}

UnitUpgradeConfig.Default = {
	BaseCost = 100,
	CostMultiplier = 1.6,
	DamageMultiplier = 1.25,
	CooldownMultiplier = 1,
}

UnitUpgradeConfig.Units = {
	["Azure"] = {
		BaseCost = 100,
		CostMultiplier = 1.6,
		DamageMultiplier = 1.25,
	},
	--[[
		Dano e cooldown param em alvos fixos no nivel maximo, pela mesma conta do
		Slasher logo abaixo: a raiz `MaxUpgrades`-esima de alvo/base, para o topo cair
		exatamente em 115 de dano e 3s de cooldown.

		| Nivel    | 0  | 1    | 2    | 3    | 4    | 5  |
		| Dano     | 38 | 47   | 59   | 73   | 92   | 115 |
		| Cooldown | 5  | 4,51 | 4,08 | 3,68 | 3,32 | 3  |
	]]
	["Subspace Tripminer"] = {
		BaseCost = 100,
		CostMultiplier = 1.6,
		DamageMultiplier = (115 / UnitStats["Subspace Tripminer"].Damage) ^ (1 / UnitUpgradeConfig.MaxUpgrades),
		CooldownMultiplier = (3 / UnitStats["Subspace Tripminer"].Cooldown) ^ (1 / UnitUpgradeConfig.MaxUpgrades),
	},
	["Entrepreneur"] = {
		BaseCost = 100,
		CostMultiplier = 1.6,
		DamageMultiplier = 1.25,
	},
	--[[
		| Nivel    | 0    | 1    | 2    | 3    | 4    | 5    |
		| Dano     | 35   | 44   | 55   | 68   | 85   | 107  |
		| Cooldown | 2,00 | 1,80 | 1,62 | 1,46 | 1,31 | 1,18 |
		| DPS      | 17,5 | 24,4 | 34,0 | 46,6 | 64,8 | 90,6 |

		O dano e a cadencia saem da formula; so o preco e escada na mao (`Costs`).
		Com os 200 de colocacao do `UnitStats`, leva-la ao maximo custa 2.090.
	]]
	["Sword"] = {
		Costs = { 165, 250, 325, 450, 700 },
		DamageMultiplier = 1.25,
		CooldownMultiplier = 0.9,
	},
	--[[
		Sem `CooldownMultiplier`, ao contrario do Sword e do Slasher: os 3s parados
		depois do combo sao a identidade do Berserker, e upgrade nele compra dano, e
		nao cadencia. Ver o comentario dele no `UnitStats`.

		A escada de preco e a do Rocket, e nao a do Azure: as duas sao lendarias, mas
		esta comeca em 400 de caixa e sobe so em dano, entao o upgrade dela tem que
		custar como o da outra lendaria cara.
	]]
	["Berserker"] = {
		BaseCost = 150,
		CostMultiplier = 1.7,
		DamageMultiplier = 1.25,
	},
	--[[
		O dano do Slasher vai de **5 (base) a 9 (nivel maximo)**, e o multiplicador e
		a raiz `MaxUpgrades`-esima de 9/5 -- escrito como conta, e nao como 1.12475,
		para o topo cair exatamente em 9 e continuar caindo se o teto de upgrades
		mudar. A escada que sai disso, ja arredondada como o servidor arredonda:

		| Nivel    | 0    | 1    | 2    | 3    | 4    | 5    |
		| Dano     | 5    | 6    | 6    | 7    | 8    | 9    |
		| Cooldown | 0,85 | 0,77 | 0,69 | 0,62 | 0,56 | 0,50 |
		| DPS      | 5,9  | 7,8  | 8,7  | 11,3 | 14,3 | 17,9 |

		**O nivel 2 repete o dano, e nao ha como nao repetir**: sao cinco degraus
		para quatro pontos de dano. Ele nao e um nivel morto porque o
		`CooldownMultiplier` corta 10% do intervalo em todo nivel -- o DPS sobe de
		5,9 a 17,9 sem nenhum degrau parado.

		So o preco e escada na mao (`Costs`). Com os 90 de colocacao do `UnitStats`,
		leva-la ao maximo custa 1.534.
	]]
	["Slasher"] = {
		Costs = { 100, 144, 230, 370, 600 },
		DamageMultiplier = (9 / UnitStats.Slasher.Damage) ^ (1 / UnitUpgradeConfig.MaxUpgrades),
		CooldownMultiplier = 0.9,
	},
	--[=[
		A unica unidade com `Cooldowns` na mao: os degraus dela nao sao geometricos, e
		nenhum multiplicador unico passa pelos seis.

		| Nivel    | 0    | 1    | 2    | 3    | 4    | 5    |
		| Dano     | 4    | 5    | 6    | 7    | 9    | 10   |
		| Cooldown | 0,55 | 0,52 | 0,46 | 0,41 | 0,35 | 0,32 |
		| DPS      | 7,3  | 9,6  | 13,0 | 17,1 | 25,7 | 31,3 |

		**`1.21` nao e o alvo do nivel maximo escrito como raiz**, ao contrario do
		Slasher e do Frostione: `(10/4) ^ (1/5)` daria 1,2011 e o nivel 4 cairia em
		8,3 -- um 8 onde a tabela pede 9. A faixa que arredonda para os seis numeros e
		estreita (1,2075 a 1,2126), e 1,21 esta dentro dela. Mexeu qualquer degrau,
		refaca a conta: nao ha folga aqui.

		Com os 175 de colocacao do `UnitStats`, leva-la ao maximo custa 1.725.
	]=]
	["Slingshot"] = {
		Costs = { 130, 210, 285, 375, 550 },
		DamageMultiplier = 1.21,
		Cooldowns = { 0.55, 0.52, 0.46, 0.41, 0.35, 0.32 },
	},
	--[[
		O dano do tiro vai de 15 a 25 no nivel maximo, pela mesma conta do Slasher: a
		raiz `MaxUpgrades`-esima de alvo/base. So o tiro cresce: a queimadura e fixa.

		| Nivel | 0  | 1  | 2  | 3  | 4  | 5  |
		| Dano  | 15 | 17 | 18 | 20 | 23 | 25 |
	]]
	["Pyre"] = {
		BaseCost = 100,
		CostMultiplier = 1.6,
		DamageMultiplier = (25 / UnitStats["Pyre"].Damage) ^ (1 / UnitUpgradeConfig.MaxUpgrades),
	},
	--[[
		| Nivel    | 0    | 1    | 2    | 3    | 4    | 5    |
		| Dano     | 16   | 20   | 25   | 31   | 39   | 49   |
		| Cooldown | 2,00 | 2,00 | 2,00 | 2,00 | 2,00 | 2,00 |
		| DPS      | 8,0  | 10,0 | 12,5 | 15,5 | 19,5 | 24,5 |

		Sem `CooldownMultiplier` de proposito, ao contrario do Slingshot de que ele e
		uma variacao: os 2s sao a duracao da animacao `Attack` (ver o comentario dele
		no `UnitStats`), e upgrade nele compra dano e alcance, nao cadencia. E o que
		separa os dois agora -- um cutuca cada vez mais rapido, o outro bate cada vez
		mais forte no mesmo ritmo.

		Com os 150 de colocacao do `UnitStats`, leva-lo ao maximo custa 1.835.
	]]
	["Archer"] = {
		Costs = { 125, 235, 300, 425, 600 },
		DamageMultiplier = 1.25,
	},
	["Rocket"] = {
		BaseCost = 150,
		CostMultiplier = 1.7,
		DamageMultiplier = 1.3,
	},

	--[[
		Sem `CooldownMultiplier`, como o Berserker: os 2,5s entre dois raios valem em
		todo nivel. Cadencia nela nao compra so dano -- compra tranco, em quatro
		inimigos de uma vez --, e quanto mais perto um raio do outro, mais a fila anda
		em soquinhos. Upgrade nesta unidade compra dano, alcance e a duracao do tranco
		(ver `GetStunDuration` e o comentario dela no `UnitStats`).

		A escada de preco e a das outras duas lendarias caras -- ela custa 300 de
		caixa para entrar em campo, entao o upgrade nao pode custar como o de uma
		unidade de 100.
	]]
	["Electro"] = {
		BaseCost = 150,
		CostMultiplier = 1.7,
		DamageMultiplier = 1.25,
	},
	--[[
		O upgrade compra dano e cadencia ate alvos fixos no nivel maximo: 14 de dano
		(10 -> 14) e cooldown pela metade (1s -> 0,5s), o que da 28 de DPS no topo.
		Mesma conta do Slasher logo abaixo: a raiz `MaxUpgrades`-esima de alvo/base,
		para o topo cair exatamente nos alvos. Lentidao e congelamento nao crescem --
		mas tiro mais rapido fecha os quatro acumulos mais cedo, entao o congelamento
		fica mais frequente com o nivel.

		| Nivel    | 0    | 1    | 2    | 3    | 4    | 5    |
		| Dano     | 10   | 11   | 11   | 12   | 13   | 14   |
		| Cooldown | 1,00 | 0,87 | 0,76 | 0,66 | 0,57 | 0,50 |
		| DPS      | 10,0 | 12,6 | 14,5 | 18,2 | 22,6 | 28,0 |
	]]
	["Frostione"] = {
		BaseCost = 100,
		CostMultiplier = 1.6,
		DamageMultiplier = (14 / UnitStats["Frostione"].Damage) ^ (1 / UnitUpgradeConfig.MaxUpgrades),
		CooldownMultiplier = (0.5 / UnitStats["Frostione"].Cooldown) ^ (1 / UnitUpgradeConfig.MaxUpgrades),
	},
	--[[
		+15% de dano por nivel, nos tres ataques. O cooldown do fim da sequencia desce
		de 8s ate 6,5s no nivel maximo, pela mesma conta do Slasher: a raiz
		`MaxUpgrades`-esima de alvo/base. O raio do meteoro cresce a parte
		(`GetMeteorRadius`).
	]]
	["Archmage"] = {
		BaseCost = 300,
		CostMultiplier = 1.7,
		DamageMultiplier = 1.15,
		CooldownMultiplier = (6.5 / UnitStats["Archmage"].Cooldown) ^ (1 / UnitUpgradeConfig.MaxUpgrades),
	},
}

--[[
	O clima entra por aqui, e não em cada chamador.

	Todos os getters abaixo aceitam um `weather` opcional no fim — o nome do Model
	de clima que está no ar. Passando nil (ou um clima sem efeito para aquela
	unidade), o número devolvido é exatamente o de antes, então quem não se importa
	com clima não precisa mudar nada.

	Concentrar a conta aqui é o que faz o servidor e o cliente concordarem: o
	alcance que o `UnitService` usa para procurar alvo, o círculo que o
	`UnitPlacementController` desenha no chão e o número que o card mostra saem
	todos da mesma função. Se o clima entrasse só no combate, o jogador veria um
	círculo que não corresponde ao que a unidade alcança.

	Quem tem os multiplicadores é o `WeatherConfig`; aqui só se aplica.
]]
local function weatherMultiplier(weather, unitName, stat)
	if not weather then return 1 end
	return WeatherConfig.GetUnitMultiplier(weather, unitName, stat)
end

function UnitUpgradeConfig:GetUnitData(unitName)
	return self.Units[unitName] or self.Default
end

--[=[
	O que custa o **proximo** upgrade, saindo de `currentLevel`.

	Com `Costs` na unidade, e o item `currentLevel + 1` da lista; sem ele, a formula
	geometrica de sempre. Ver o cabecalho do arquivo para quando usar cada uma.
]=]
function UnitUpgradeConfig:GetCost(unitName, currentLevel)
	local data = self:GetUnitData(unitName)
	local ladder = data.Costs

	if ladder then
		-- O clamp existe para um nivel fora da lista nao devolver nil e virar erro de
		-- aritmetica no card: quem chama aqui ja checou o `IsMaxed`, mas o preco de um
		-- nivel que nao existe tem que ser um numero.
		return ladder[math.clamp((currentLevel or 0) + 1, 1, #ladder)]
	end

	return math.floor(data.BaseCost * (data.CostMultiplier ^ currentLevel) + 0.5)
end

--[=[
	O que custa **colocar** a unidade no mapa, com o clima do momento.

	É o `UnitStats[nome].Cost` vezes o multiplicador de `Cost` do clima (a chuva
	desconta 25% do Ice). Sem clima, ou com um clima que não mexe em preço, devolve o
	número da tabela sem tocar em nada.

	Existe pelo mesmo motivo dos outros getters: o servidor cobra por aqui e o card
	da hotbar mostra por aqui, então não há como o jogador ver um preço e pagar
	outro.

	> **A venda não segue o desconto.** O `GetInvested` continua somando o preço de
	> tabela, e é ele que os dois lados usam para o valor de venda — o servidor
	> guarda no `entry.invested` o preço cheio, mesmo tendo cobrado menos. Fazer o
	> contrário obrigaria o cliente a saber quanto foi pago em cada unidade (o
	> `invested` não é replicado), e o desconto viraria uma divergência entre o que o
	> card promete de volta e o que a venda dá. Na prática o desconto continua sendo
	> só vantagem: comprar por 75 e vender por 50 nunca é lucro.
]=]
function UnitUpgradeConfig:GetPlaceCost(unitName, weather)
	local stats = UnitStats[unitName]
	local cost = stats and stats.Cost or 0

	return math.floor(cost * weatherMultiplier(weather, unitName, "Cost") + 0.5)
end

function UnitUpgradeConfig:GetDamageMultiplier(unitName, level, weather)
	local data = self:GetUnitData(unitName)
	return (data.DamageMultiplier ^ level) * weatherMultiplier(weather, unitName, "Damage")
end

function UnitUpgradeConfig:GetRange(unitName, level, weather)
	local stats = UnitStats[unitName]
	if not stats then return 10 end

	local baseRange = stats.Range or 10
	local rangeStats = stats.RangeStats

	local range = baseRange
	if rangeStats and rangeStats.Levels then
		-- Alcance por nivel, para as escadas que nao sao uma reta (ver o `RangeStats`
		-- no cabecalho do `UnitStats`).
		local levels = rangeStats.Levels
		range = levels[math.clamp((level or 0) + 1, 1, #levels)]
	elseif rangeStats then
		local increased = baseRange + ((level or 0) * (rangeStats.Increment or 0))
		range = math.min(increased, math.max(rangeStats.Max or increased, baseRange))
	end

	-- Depois do teto de upgrade, de propósito: o clima corta o alcance que a
	-- unidade tem, não o que ela poderia ter.
	return range * weatherMultiplier(weather, unitName, "Range")
end

--[=[
	Cooldown entre ataques.

	A velocidade de ataque do clima entra como divisão: um multiplicador de 1.3 é
	"bate 30% mais rápido", ou seja, o mesmo ciclo em 1/1.3 do tempo.
]=]
function UnitUpgradeConfig:GetCooldown(unitName, level, weather)
	local stats = UnitStats[unitName]
	local baseCooldown = stats and stats.Cooldown or 1
	local data = self:GetUnitData(unitName)
	local ladder = data.Cooldowns

	local cooldown
	if ladder then
		cooldown = ladder[math.clamp((level or 0) + 1, 1, #ladder)]
	else
		cooldown = baseCooldown * ((data.CooldownMultiplier or 1) ^ (level or 0))
	end

	local attackSpeed = weatherMultiplier(weather, unitName, "AttackSpeed")
	if attackSpeed <= 0 then return cooldown end

	return cooldown / attackSpeed
end

--[=[
	Quanto tempo o golpe da unidade para o inimigo, no nivel dado. Zero para quem nao
	atordoa.

	`Stun.Duration` e o do nivel 0; com `Stun.MaxDuration`, o tranco sobe em linha
	reta ate ele no nivel maximo. Sem clima, como a aura: o clima de raio tem o
	tranco proprio dele (`WeatherConfig.Thunder`), e nao mexe no das unidades.
]=]
function UnitUpgradeConfig:GetStunDuration(unitName, level)
	local stats = UnitStats[unitName]
	local stun = stats and stats.Stun

	if not stun then
		return 0
	end

	local base = stun.Duration or 0
	local top = stun.MaxDuration or base
	local progress = math.clamp((level or 0) / self.MaxUpgrades, 0, 1)

	return base + (top - base) * progress
end

--[=[
	O raio da area de gelo que o acerto espalha em volta do alvo, no nivel dado. Zero
	para quem nao tem `Frost` ou nao declara `Radius`.

	Mesma escada do `GetStunDuration` logo acima: `Frost.Radius` no nivel 0 e
	`Frost.MaxRadius` no maximo, em linha reta. Sem `MaxRadius` o raio nao cresce.
]=]
function UnitUpgradeConfig:GetFrostRadius(unitName, level)
	local stats = UnitStats[unitName]
	local frost = stats and stats.Frost

	if not frost or not frost.Radius then
		return 0
	end

	local base = frost.Radius
	local top = frost.MaxRadius or base
	local progress = math.clamp((level or 0) / self.MaxUpgrades, 0, 1)

	return base + (top - base) * progress
end

--[=[
	O raio da explosao do meteoro do Archmage no nivel dado. Mesma escada do
	`GetFrostRadius` logo acima: `Combo.Meteor.Radius` no nivel 0 e `MaxRadius` no
	maximo, em linha reta. Zero para quem nao tem meteoro.
]=]
function UnitUpgradeConfig:GetMeteorRadius(unitName, level)
	local stats = UnitStats[unitName]
	local meteor = stats and stats.Combo and stats.Combo.Meteor

	if not meteor or not meteor.Radius then
		return 0
	end

	local base = meteor.Radius
	local top = meteor.MaxRadius or base
	local progress = math.clamp((level or 0) / self.MaxUpgrades, 0, 1)

	return base + (top - base) * progress
end

--[=[
	O bônus de caixa da aura de uma farm no nível dado, como fração somável: 0.15 é
	"+15%". Unidade sem aura devolve 0.

	Não aceita `weather` de propósito, ao contrário dos getters acima. O bônus é
	economia, e economia não anda com o clima — é a mesma regra do `Farm.Income`,
	que o `payFarmUnits` paga sem clima justamente para a seca não virar bônus de
	caixa. O **raio** da aura continua sendo o `GetRange`, esse sim com clima,
	porque é o círculo que o jogador vê desenhado no chão.
]=]
function UnitUpgradeConfig:GetAuraBonus(unitName, level)
	local stats = UnitStats[unitName]
	local aura = stats and stats.Farm and stats.Farm.Aura

	if not aura then
		return 0
	end

	return (aura.Bonus or 0) + (aura.BonusPerUpgrade or 0) * (level or 0)
end

--[=[
	Dano por golpe no nivel dado, com o mesmo arredondamento que o servidor usa
	em `UnitService:executeAttack` — o card tem que mostrar o numero que vai de
	fato entrar no mob.
]=]
function UnitUpgradeConfig:GetDamage(unitName, level, weather)
	local stats = UnitStats[unitName]
	local baseDamage = stats and stats.Damage or 0
	return math.floor(baseDamage * self:GetDamageMultiplier(unitName, level or 0, weather) + 0.5)
end

--[=[
	Dano por segundo: todos os golpes de um ciclo de ataque divididos pelo cooldown.
]=]
function UnitUpgradeConfig:GetDPS(unitName, level, weather)
	local stats = UnitStats[unitName]
	local cooldown = self:GetCooldown(unitName, level, weather)
	if cooldown <= 0 then return 0 end
	return self:GetDamage(unitName, level, weather) * ((stats and stats.Hits) or 1) / cooldown
end

--[=[
	Total de caixa investido na unidade: o custo de colocacao mais o custo de cada
	upgrade ja comprado. Serve para o cliente calcular o valor de venda sem precisar
	do `entry.invested` do servidor — as duas contas seguem a mesma tabela.

	Sem clima de propósito, nos dois sentidos: o que se investiu não muda porque
	começou a nevar, e o desconto de colocação da chuva (`GetPlaceCost`) também não
	entra aqui — ver o comentário de lá.
]=]
function UnitUpgradeConfig:GetInvested(unitName, level)
	local stats = UnitStats[unitName]
	local total = stats and stats.Cost or 0

	for currentLevel = 0, (level or 0) - 1 do
		total += self:GetCost(unitName, currentLevel)
	end

	return total
end

function UnitUpgradeConfig:IsMaxed(level)
	return (level or 0) >= self.MaxUpgrades
end

return UnitUpgradeConfig
