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
	| `Damages` | o dano de cada nivel (indice = nivel + 1), do 0 ao maximo. Manda no `DamageMultiplier`, e o item 1 tem que ser o `Damage` do `UnitStats` |
	| `Cooldowns` | o cooldown de cada nivel (indice = nivel + 1), do 0 ao maximo. Manda no `CooldownMultiplier`, e o item 1 tem que ser o `Cooldown` do `UnitStats` |
	| `Incomes` | a renda por wave de uma farm em cada nivel (indice = nivel + 1). Manda no `Farm.Income` x `DamageMultiplier`, e o item 1 tem que ser o `Farm.Income` do `UnitStats` |

	Hoje dez unidades usam `Costs`, porque a escada de preco delas foi desenhada
	por wave e nao por formula: os saltos sao desiguais de proposito. `Cooldowns` o
	Slingshot, o Archer e o Berserker usam -- nenhuma das tres desce em razao fixa
	--, `Damages` o Archer e o Berserker, e `Incomes` so o Entrepreneur, que e a
	unica farm.

	**`Damages` e o ultimo recurso, e nao a saida facil.** A escada de dano passa por
	um arredondamento, entao uma tabela desenhada a mao quase sempre ainda cabe numa
	razao: e so procurar o intervalo de multiplicadores em que os seis numeros
	arredondam certo, como o Slingshot faz com 1.304. So quando esse intervalo e
	vazio -- os degraus do Archer e do Berserker se cruzam e nenhum numero serve para
	os seis -- e que a lista entra.

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
		-- Com os 350 de colocacao do `UnitStats`, leva-la ao maximo custa 2.565.
		Costs = { 225, 300, 425, 550, 715 },
		DamageMultiplier = (115 / UnitStats["Subspace Tripminer"].Damage) ^ (1 / UnitUpgradeConfig.MaxUpgrades),
		CooldownMultiplier = (3 / UnitStats["Subspace Tripminer"].Cooldown) ^ (1 / UnitUpgradeConfig.MaxUpgrades),
	},
	--[=[
		| Nivel   | 0    | 1    | 2    | 3    | 4    | 5    |
		| Renda   | 60   | 75   | 95   | 120  | 150  | 225  |
		| Aura    | 10%  | 15%  | 20%  | 25%  | 30%  | 30%  |
		| Alcance | 4    | 5    | 5    | 6    | 7    | 8    |

		A renda e escada na mao (`Incomes`) porque os degraus dela nao sao uma razao
		so: os quatro primeiros ficam perto de 1,25, e o ultimo e 1,5. Esse salto e o
		ponto da unidade -- o nivel 5 dela custa 675 e devolve 75 a mais por wave, e e
		a unica compra da tabela que se paga em nove waves em vez de matar alguma
		coisa.

		A aura e o alcance moram no `UnitStats` (`Farm.Aura` e `RangeStats.Levels`),
		e nao aqui, porque sao numeros da unidade e nao da escada de upgrade.

		Com os 200 de colocacao do `UnitStats`, leva-la ao maximo custa 2.050.
	]=]
	["Entrepreneur"] = {
		Costs = { 150, 250, 325, 450, 675 },
		Incomes = { 60, 75, 95, 120, 150, 225 },

		--[[
			Inerte, e mantido so porque o `GetDamageMultiplier` e chamado para toda
			unidade: o `Damage` dela e 0, e a renda deixou de sair daqui quando ganhou
			o `Incomes` acima. Mexer neste numero nao muda nada em jogo.
		]]
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
	--[=[
		| Nivel    | 0    | 1    | 2    | 3    | 4    | 5    |
		| Dano     | 39   | 48   | 65   | 98   | 115  | 135  |
		| Cooldown | 6,00 | 5,80 | 5,50 | 5,25 | 5,10 | 4,80 |
		| Alcance  | 7    | 8    | 9    | 10   | 11   | 11   |
		| DPS      | 6,5  | 8,3  | 11,8 | 18,7 | 22,5 | 28,1 |

		**O DPS da tabela acima e por golpe, e nao o que a unidade despeja.** Ela bate
		quatro vezes por ciclo com `HitFalloff` de 10% (ver o comentario dela no
		`UnitStats`), entao o combo vale 3,44 golpes cheios e o DPS de verdade e
		3,44x o da linha: 22,3 no nivel 0 e 96,7 no maximo. A linha esta aqui na forma
		`Dano / Cooldown` so para poder ser comparada com o resto da tabela, que e de
		um golpe so.

		Dano e cadencia sao escadas na mao, e nenhuma das duas cabe numa razao. O
		cooldown desce em passos desiguais -- 0,20, 0,30, 0,25, 0,15 e 0,30 --, que
		sao os degraus de quanto a recuperacao depois do combo encurta; a animacao
		(2,9s) nao muda, e por isso mesmo no nivel 5 sobram 1,9s de espera.

		**O dano tem um degrau que nenhuma razao imita: o terceiro upgrade.** De 65
		para 98 sao +51% de uma vez, contra +17% do seguinte e +35% do anterior -- a
		faixa de multiplicadores que arredondaria para os seis numeros e vazia por
		larga margem (o nivel 3 pediria 1,357 e o nivel 5 nao aceita mais que 1,244).
		Esse salto e o ponto da escada: o nivel 3 e onde a unidade deixa de ser cara
		e passa a valer o preco, e e la que a decisao de subi-la ou vender esta.

		Ela deixou de ser a lendaria que so sobe em dano: agora o upgrade compra
		cadencia e alcance tambem (7 a 11, pelo `RangeStats` do `UnitStats`), e e o
		alcance que muda mais a unidade -- a 11 ela cobre um pedaco de caminho em vez
		de um ponto.

		Com os 400 de colocacao do `UnitStats`, leva-la ao maximo custa 4.130.
	]=]
	["Berserker"] = {
		Costs = { 325, 480, 650, 875, 1400 },
		Damages = { 39, 48, 65, 98, 115, 135 },
		Cooldowns = { 6, 5.8, 5.5, 5.25, 5.1, 4.8 },
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
		| Nivel    | 0    | 1    | 2    | 3    | 4    | 5    |
		| Dano     | 7    | 9    | 12   | 16   | 20   | 26   |
		| Cooldown | 1,15 | 1,05 | 0,93 | 0,87 | 0,82 | 0,77 |
		| Alcance  | 12   | 13   | 14   | 15   | 15   | 16   |
		| DPS      | 6,1  | 8,6  | 12,9 | 18,4 | 24,4 | 33,8 |

		O cooldown e escada na mao (`Cooldowns`) porque os degraus dela nao sao
		geometricos: a queda e de 0,10, 0,12, 0,06, 0,05 e 0,05, forte no comeco e
		quase parada no fim -- o que o upgrade compra nesta unidade, dos niveis 3
		para cima, e dano e nao cadencia.

		**`1.304` nao e o alvo do nivel maximo escrito como raiz**, ao contrario do
		Slasher e do Frostione: `(26/7) ^ (1/5)` daria 1,3001 e o nivel 3 cairia em
		15,4 -- um 15 onde a tabela pede 16. A faixa que arredonda para os seis
		numeros e estreitissima (1,3034 a 1,3051), e 1.304 esta dentro dela. Mexeu
		qualquer degrau, refaca a conta: nao ha folga nenhuma aqui, e se a faixa
		fechar a saida e um `Damages` na mao, como o do Archer e o do Berserker.

		Com os 175 de colocacao do `UnitStats`, leva-la ao maximo custa 1.725.
	]=]
	["Slingshot"] = {
		Costs = { 130, 210, 285, 375, 550 },
		DamageMultiplier = 1.304,
		Cooldowns = { 1.15, 1.05, 0.93, 0.87, 0.82, 0.77 },
	},
	--[[
		O dano do tiro vai de 15 a 25 no nivel maximo, pela mesma conta do Slasher: a
		raiz `MaxUpgrades`-esima de alvo/base. So o tiro cresce: a queimadura e fixa.

		| Nivel | 0  | 1  | 2  | 3  | 4  | 5  |
		| Dano  | 15 | 17 | 18 | 20 | 23 | 25 |
	]]
	["Pyre"] = {
		-- Com os 150 de colocacao do `UnitStats`, leva-lo ao maximo custa 1.560.
		Costs = { 100, 185, 250, 375, 500 },
		DamageMultiplier = (25 / UnitStats["Pyre"].Damage) ^ (1 / UnitUpgradeConfig.MaxUpgrades),
	},
	--[=[
		| Nivel    | 0    | 1    | 2    | 3    | 4    | 5    |
		| Dano     | 16   | 20   | 25   | 31   | 37   | 45   |
		| Cooldown | 3,50 | 3,20 | 2,90 | 2,60 | 2,30 | 2,00 |
		| Alcance  | 12   | 13   | 14   | 15   | 16   | 17   |
		| DPS      | 4,6  | 6,3  | 8,7  | 12,0 | 16,1 | 22,5 |

		Dano e cadencia sao escadas na mao. O cooldown desce **0,30s certos por
		nivel** -- uma reta, e reta nenhuma e uma razao --, e para exatamente nos
		2,00s da animacao `Attack` no nivel maximo: e o piso da unidade, e esta
		escrito assim para ninguem baixar sem mexer na animacao junto (ver o
		comentario dele no `UnitStats`).

		O dano precisa de `Damages` porque os degraus se cruzam: para o nivel 3 cair
		em 31 o multiplicador teria que ser pelo menos 1,2399, e para o nivel 4 cair
		em 37 teria que ser menos de 1,2373. Nao ha numero entre os dois, entao a
		lista e a unica forma -- e e exatamente o caso que o cabecalho do arquivo
		descreve.

		O Archer e o Slingshot deixaram de se separar pelo ritmo: agora os dois
		ganham dano e cadencia com o upgrade, e o que os distingue e a flecha
		atravessar (o Slingshot cutuca um alvo, o Archer cobra a fila) e o alcance
		maximo -- 17 contra 16.

		Com os 150 de colocacao do `UnitStats`, leva-lo ao maximo custa 1.835.
	]=]
	["Archer"] = {
		Costs = { 125, 235, 300, 425, 600 },
		Damages = { 16, 20, 25, 31, 37, 45 },
		Cooldowns = { 3.5, 3.2, 2.9, 2.6, 2.3, 2 },
	},
	--[[
		A escada de preco e na mao (`Costs`), e nao a formula de antes: o salto do
		nivel 1 para o 2 e menor que o do 0 para o 1 (250 para 400 contra 450 para
		250), e razao nenhuma anda para tras. O desenho e por wave -- o primeiro
		upgrade e barato de proposito, para quem gastou 450 na colocacao nao ficar uma
		wave inteira sem poder mexer na torre --, e o peso todo esta no ultimo degrau:
		1.500, mais do que os tres primeiros juntos.

		Com os 450 de colocacao do `UnitStats`, leva-lo ao maximo custa 4.090.
	]]
	["Rocket"] = {
		Costs = { 250, 400, 650, 840, 1500 },
		DamageMultiplier = 1.3,
	},

	--[[
		Sem `CooldownMultiplier`, como o Berserker: os 2,5s entre dois raios valem em
		todo nivel. Cadencia nela nao compra so dano -- compra tranco, em quatro
		inimigos de uma vez --, e quanto mais perto um raio do outro, mais a fila anda
		em soquinhos. Upgrade nesta unidade compra dano, alcance e a duracao do tranco
		(ver `GetStunDuration` e o comentario dela no `UnitStats`).

		A escada de preco e na mao (`Costs`), pelo mesmo desenho do Rocket logo acima:
		o primeiro upgrade e o barato (225 contra os 350 da colocacao) e o ultimo e o
		caro (1.300). Ela custa 350 de caixa para entrar em campo, entao o upgrade nao
		pode custar como o de uma unidade de 100.

		Com os 350 de colocacao do `UnitStats`, leva-la ao maximo custa 3.770.
	]]
	["Electro"] = {
		Costs = { 225, 450, 635, 810, 1300 },
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
		-- Com os 200 de colocacao do `UnitStats`, leva-la ao maximo custa 2.015.
		Costs = { 135, 250, 345, 470, 615 },
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

--[=[
	O quanto o dano base da unidade cresce ate `level`, **como fator** e nao como
	dano pronto.

	Ser um fator e o que mantem as duas pontas com o mesmo arredondamento: o
	servidor (`UnitService:getDamage`) e o card (`formatDamageOrIncome`) multiplicam
	o `UnitStats.Damage` por este numero junto com carta, carga e clima, e so entao
	arredondam, uma vez so. Devolver o dano ja pronto arredondaria duas vezes.

	Com `Damages` na unidade, o fator e o item da escada dividido pelo dano base --
	por isso o item 1 tem que ser o proprio `Damage` do `UnitStats`, senao o nivel 0
	nao sai 1. Sem ela, a razao geometrica de sempre.
]=]
function UnitUpgradeConfig:GetDamageMultiplier(unitName, level, weather)
	local data = self:GetUnitData(unitName)
	local ladder = data.Damages

	local multiplier
	if ladder then
		local stats = UnitStats[unitName]
		local baseDamage = stats and stats.Damage or 0
		local stepDamage = ladder[math.clamp((level or 0) + 1, 1, #ladder)]

		-- Dano base zero nao tem fator possivel (o Entrepreneur e o caso), e cair na
		-- divisao devolveria `nan` para o card. Nenhuma farm declara `Damages`; o
		-- ramo existe para que declarar uma nao quebre a tela.
		multiplier = if baseDamage > 0 then stepDamage / baseDamage else 1
	else
		multiplier = data.DamageMultiplier ^ level
	end

	return multiplier * weatherMultiplier(weather, unitName, "Damage")
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

	`Aura.MaxBonus` é o teto, e ele existe porque o bônus **soma entre farms**: duas
	cobrindo a mesma torre valem o dobro, então o que segura o empilhamento é este
	número e não a quantidade de farms. Sem o campo, a conta sobe reta e não para.

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

	local bonus = (aura.Bonus or 0) + (aura.BonusPerUpgrade or 0) * (level or 0)

	if aura.MaxBonus then
		return math.min(bonus, aura.MaxBonus)
	end

	return bonus
end

--[=[
	A renda por wave de uma farm no nível dado, **sem arredondar** e sem carta. Zero
	para quem não é farm.

	Devolver o número cru é de propósito: quem chama multiplica pela carta de
	`Income` e arredonda uma vez só no fim (o `payFarmUnits` no servidor, o
	`formatDamageOrIncome` no card). Arredondar aqui arredondaria duas vezes e o card
	prometeria um caixa diferente do que cai na conta.

	Com `Incomes` na unidade, é o item `level + 1` da lista; sem ele, é o
	`Farm.Income` crescendo pelo `DamageMultiplier`, que era como a renda subia antes
	de qualquer farm ter escada própria.

	Sem `weather` pela mesma razão do `GetAuraBonus` logo acima: renda é economia, e
	economia não anda com o clima.
]=]
function UnitUpgradeConfig:GetIncome(unitName, level)
	local stats = UnitStats[unitName]
	local farm = stats and stats.Farm

	if not farm then
		return 0
	end

	local ladder = self:GetUnitData(unitName).Incomes

	if ladder then
		return ladder[math.clamp((level or 0) + 1, 1, #ladder)]
	end

	return (farm.Income or 0) * self:GetDamageMultiplier(unitName, level or 0)
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
