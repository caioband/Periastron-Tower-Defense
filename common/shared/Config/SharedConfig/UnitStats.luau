--[[
	Os numeros de cada unidade.

	Duas regras seguram esta tabela, e vale conferi-las antes de mexer:

	1. Dano por segundo dividido pelo custo. E o que decide se uma unidade vale a
	   pena, e o teto e 15 por 100 de caixa. O Slasher ficava em 26,7 — quase tres
	   vezes o segundo colocado — e por isso encher o mapa de Slasher era a jogada
	   otima em qualquer dificuldade. A escada por raridade nao vale mais: Slasher
	   6,5 e Slingshot 4,2 contra Sword 8,8, Epic ~11 e Legendary 11 a 14.

	2. Alcance como eixo de diferenciacao. Cinco das sete unidades tinham alcance
	   3, o que tornava posicionamento irrelevante — todas precisavam colar no
	   caminho. As faixas agora sao curto (4 a 6), medio (10) e longo (12), e o
	   alcance longo e do Slingshot, que nao tem area nem dano alto.

	DPS = Damage * Hits / Cooldown.

	`RangeStats` e como o alcance cresce com o upgrade, e aceita duas formas. A reta
	e `{ Increment, Max }`: soma `Increment` por nivel ate o teto. A outra e
	`{ Levels = { ... } }`, um alcance por nivel (indice = nivel + 1), para as
	unidades cujo alcance sobe em degraus desiguais -- o Sword fica em 4 ate o nivel
	3 e so entao vai a 5, e isso nao cabe num incremento fixo. Com `Levels`, o
	`Range` acima tem que ser o primeiro item da lista: e ele que o resto do codigo
	le como alcance de nivel 0. Quem faz a conta e o `UnitUpgradeConfig:GetRange`.

	`Class` e o tipo da unidade para efeito de clima: "Melee", "Ranged", "Magic",
	"Fire", "Ice" ou "Electric" (a lista vive em `WeatherConfig.ClassList`). Aceita
	uma lista quando a unidade for de dois tipos — `Class = {"Melee", "Fire"}`. E o
	unico lugar onde a classe e escrita; quem le e o `WeatherConfig`.

	`Projectile` e a unidade que atira em vez de bater. Ele e lido pelas duas pontas
	— o cliente desenha o voo, o servidor resolve quem levou dano —, e por isso mora
	aqui e nao num config de tela:

	| Campo | O que e |
	| --- | --- |
	| `Asset` | o nome do modelo em `Assets.Projectiles` |
	| `Speed` | studs por segundo do voo |
	| `Subtype` | `"Piercing"` faz a flecha atravessar; sem ele, o tiro para no alvo |
	| `PierceWidth` | studs de folga da linha que acerta; sem ele, 2 |
	| `PierceFalloff` | quanto do dano a flecha perde a cada corpo furado, de 0 a 1 |
	| `PierceRange` | ate onde o desenho segue depois do disparo; sem ele, 24 |

	**Atravessar muda o alvo do golpe, e nao o numero dele.** Um `Piercing` acerta
	cada inimigo na linha que sai da unidade e vai ate o alcance dela, inclusive quem
	esta atras do alvo. `PierceWidth` e a unica coisa entre "pega quem a linha corta
	de raspao" e "limpa a fileira do lado".

	`Slow`, `Stun`, `Burn`, `Bleed` e `Frost` sao o que o golpe **deixa** no inimigo,
	alem do dano. Hoje deixam o Electro (o tranco do choque), o Frostione (os acumulos
	de gelo), o Pyre (a queimadura) e o Slasher (o sangramento):

	| Campo | O que e |
	| --- | --- |
	| `Slow` | `{ Amount, Duration }` -- `Amount` e a fracao de velocidade tirada (0.3 e "anda 30% mais devagar") |
	| `Stun` | `{ Duration }` -- o inimigo para **de vez** por tantos segundos |
	| `Burn` | `{ Damage, Ticks, Interval }` -- tantos tiques de tanto dano, de tantos em tantos segundos. Nao acumula: acerto em quem ja queima nao soma dano nem renova o prazo |
	| `Bleed` | `{ Damage, Ticks, Interval, Vulnerability }` -- igual ao `Burn`, com prazo proprio (sangrar e queimar convivem no mesmo alvo) e sem a carta de fogo. `Vulnerability` e o quanto **todo** dano que entrar no alvo vale a mais enquanto ele sangra (1.3 e "+30%"), de qualquer fonte; sem o campo, 1 |
	| `Frost` | `{ Slow, Duration, FreezeStacks, FreezeDuration, FreezeImmunity, Radius, MaxRadius }` -- um acumulo por acerto, contado **por unidade**; com qualquer acumulo o inimigo fica `Slow` mais lento, o acerto de uma unidade renova so o prazo dos dela, e `FreezeStacks` de uma mesma unidade o congelam por `FreezeDuration` e zeram a conta de todas. Descongelado, ele ainda passa `FreezeImmunity` segundos sem aceitar acumulo nenhum. `Radius` (ate `MaxRadius` no nivel maximo) da o mesmo acumulo, sem dano, a quem estiver em volta do alvo |

	`Slow` e `Stun` nao sao a mesma coisa em intensidades diferentes: a lentidao mexe
	na velocidade do inimigo, o tranco tira ele do laco de movimento. Os dois cabem no
	mesmo golpe (nenhuma unidade de hoje declara os dois), e e por serem coisas
	diferentes que o tranco pode ser tao curto: parado e parado, e um terco de segundo
	disso ja e um pedaco de caminho que o inimigo nao andou.

	Quem os executa e o `MobService` (`ApplySlow`, `StunMob`, `ApplyBurn`, `ApplyBleed`), que e o
	dono do estado do inimigo; quem os dispara e o `UnitService:creditDamage`, depois
	de o dano ter entrado. As cartas de round Chill Out e Fire Hazard multiplicam
	exatamente estes numeros.

	`Chain` e o golpe que **salta** de inimigo para inimigo. Ele nao usa o alvo como
	area nem como linha: o primeiro e o alvo mirado, e da fica pulando para o vizinho
	mais proximo que ainda nao foi tocado, ate `Targets` inimigos.

	| Campo | O que e |
	| --- | --- |
	| `Targets` | quantos inimigos o raio toca no total, contando o primeiro |
	| `Radius` | studs que o salto alcanca **a partir de cada inimigo**, e nao da unidade |

	O `Radius` sair de cada inimigo e o que separa o salto da area: um raio de 4 saltos
	acompanha a fila do caminho e chega bem alem do alcance da unidade, enquanto uma
	area do mesmo tamanho so pegaria quem esta amontoado. Quem enfileira melhor os
	inimigos ganha mais com a unidade, que e a mesma ideia do `Piercing` -- so que sem
	linha reta, entao a curva do caminho nao corta o golpe pela metade.

	**Nao ha queda por inimigo**, ao contrario do `PierceFalloff`: o quarto inimigo da
	corrente leva o mesmo que o primeiro. Isso e de proposito e e caro, entao o preco
	esta no `Targets` e no `Cooldown` -- e la que se mexe se a unidade ficar forte
	demais, e nao numa queda que ela nao tem.

	`HitFalloff` e a mesma ideia da queda da flecha, so que entre os **golpes** de um
	ataque so, e nao entre os alvos de um golpe: ele e a perda de um golpe para o
	**seguinte**, e nao contra o dano cheio. Com 0.1, o combo vale 100%, 90%, 81% e
	72,9%. Vale para qualquer unidade de varios `Hits` (hoje so o Berserker
	declara), e independe de como os golpes sao espacados -- `HitInterval` ou
	`HitTimes`. Composto e com piso de 1, como o `PierceFalloff`; sem o campo, todos
	os golpes do ciclo valem igual.

	`PierceFalloff` e o que impede que atravessar seja de graca. Ele e **composto**:
	com 0.1, o segundo inimigo leva 90% do primeiro, o terceiro 90% do segundo. Nunca
	chega a zero de proposito -- uma flecha que furou dez corpos ainda machuca um
	pouco -- e o resultado e arredondado com piso de 1, para o fim da fila nao virar
	um "0" flutuando na tela. Sem o campo, a flecha atravessa sem perder nada.
]]

local UnitStats = {
	--[[ COSMIC ]]

	--[=[
		Tres ataques em sequencia, e so depois o cooldown: `Meteor`, `Lightning` e
		`Teleport`, na ordem do `AttackSequence` do `UnitAttackConfig`, que liga o
		encadeamento com `ChainSequence`. Entre o comeco de um passo e o do seguinte a
		espera e o `ChainDelay` de la (5s); o `Cooldown` conta depois da animacao do
		ultimo. Sem inimigo no alcance, a sequencia espera no passo em que parou.

		`Damage` e o do meteoro, e e o que o card mostra. O raio usa o dele
		(`Combo.Lightning.Damage`), e os dois crescem com o mesmo multiplicador de
		upgrade, carta e carga (`UnitService:getDamage`).

		| Campo | O que e |
		| --- | --- |
		| `Combo.Meteor` | `{ Damage, Radius, MaxRadius, FallTime, Height }` -- nasce `Height` studs acima da unidade no `HitTime` do passo, cai em `FallTime` segundos ate onde o alvo estava quando o passo comecou, e explode em `Radius` (ate `MaxRadius` no nivel maximo) |
		| `Combo.Lightning` | `{ Damage, Interval, Width }` -- linha reta ate o alcance, travada na direcao do alvo no `HitTime`; quem estiver nela leva `Damage` a cada `Interval` segundos ate o `HitEnd` do passo |
		| `Combo.Teleport` | `{}` -- o alvo volta para o node anterior do caminho, ou para o comeco se ainda nao passou do primeiro (`MobService:TeleportMobBack`) |

		O DPS do card sai de `Damage / Cooldown` e nao conta o raio nem a sequencia: e
		so uma referencia.
	]=]
	["Archmage"] = {
		Rarity = "Cosmic",
		Class = "Magic",
		Cost = 800,
		Damage = 120,
		Range = 15,
		Cooldown = 8,
		AttackType = "SingleShot",
		HitInterval = 0,
		Hits = 1,
		Combo = {
			Meteor = { Damage = 120, Radius = 8, MaxRadius = 10, FallTime = 1, Height = 15 },
			Lightning = { Damage = 25, Interval = 0.1, Width = 2 },
			Teleport = {},
		},
	},

	--[[ LEGENDARY ]]

	-- A mais forte em dano bruto, e de alcance curto: quatro golpes por ciclo, mas
	-- so contra quem chega perto.
	["Azure"] = {
		Rarity = "Legendary",
		-- Sem `Class` de proposito: ela ainda nao foi classificada. Assim ela leva
		-- so o que o clima faz com `All` e nao entra em nenhuma regra por tipo.

		Cost = 250,
		Damage = 17,
		Range = 6,
		Cooldown = 2,
		AttackType = "MultiShot",
		HitInterval = 0.25,
		Hits = 4,
		RangeStats = {
			Increment = 1,
			Max = 10,
		},
	},

	--[=[
		O raio que salta: um golpe a cada 2,5s que toca quatro inimigos e para cada um
		deles no lugar por um instante.

		**Ela vende alcance de golpe, e nao dano por alvo.** 4 x 18 sao 72 de dano por
		ciclo, ou 28,8 de DPS com a corrente cheia -- 8,2 por 100 de caixa, dentro do
		teto da regra 1. Contra um alvo sozinho sao 7,2 de DPS, 2,1 por 100: ai ela e
		das piores da tabela -- e esta certo, porque sozinha ela nao faz nada do que faz.

		Em cima disso vem o tranco: 0,3s parado num ciclo de 2,5s no nivel 0 (12% do
		caminho que os quatro andariam), subindo ate 0,5s no maximo (20%). Ela nao
		deixa lentidao nenhuma: o inimigo para e volta a andar no ritmo de sempre.

		Os numeros que importam sao o `Targets` e o `Cooldown`, e o `Stun.Duration` e o
		que os separa de um controle: subir o tranco para perto do ciclo inteiro vira
		"a fila anda quando o Electro deixa", que e outra unidade -- quem para inimigo
		de verdade e o Time Stop, que custa uma carta.

		**O cooldown e fixo; o upgrade compra dano, alcance e tranco.** Sem
		`CooldownMultiplier` no `UnitUpgradeConfig`, os 2,5s valem em todo nivel, e o
		tranco sobe em linha reta:

		| Nivel  | 0    | 1    | 2    | 3    | 4    | 5    |
		| Tranco | 0,30 | 0,34 | 0,38 | 0,42 | 0,46 | 0,50 |

		Os 2,5s ainda cabem na animacao `Attack`, que dura 1,67s.

		Alcance medio (10), como o Subspace Tripminer: ela precisa alcancar a fila para
		o salto ter de onde sair, mas o salto ja e o que a leva mais longe -- somar
		alcance longo por cima seria pagar duas vezes pela mesma coisa.
	]=]
	["Electro"] = {
		Rarity = "Legendary",
		Class = "Electric",
		Cost = 350,
		Damage = 18,
		Range = 10,
		Cooldown = 2.5,
		AttackType = "SingleShot",
		HitInterval = 0,
		Hits = 1,

		-- Quatro inimigos no total (o alvo e mais tres saltos), sem perda de dano
		-- entre eles. Ver o `Chain` no cabecalho.
		Chain = { Targets = 4, Radius = 8 },

		--[[
			O tranco do choque, e a unica coisa que o golpe deixa: cada elo da corrente
			para de vez por um instante e depois volta a andar no ritmo de sempre.

			O tranco cresce com o upgrade: `Duration` no nivel 0 (0,3s) ate
			`MaxDuration` no nivel maximo (0,5s), em linha reta -- ver
			`UnitUpgradeConfig:GetStunDuration`. Unidade sem `MaxDuration` para sempre
			o mesmo tanto.

			**Sem `Slow` de proposito.** Ela nao e uma unidade de controle, e o campo
			existe (ver o `Stun` e o `Slow` no cabecalho) justamente para os dois nao
			serem confundidos: lentidao mexe na velocidade, tranco tira o inimigo do
			laco. Quem executa e o `MobService:StunMob`, o mesmo `StunnedUntil` do Time
			Stop.
		]]
		Stun = { Duration = 0.3, MaxDuration = 0.5 },

		RangeStats = {
			Increment = 1,
			Max = 14,
		},
	},

	--[[
		Area em alcance longo: o raio da explosao cabe folgado dentro do alcance, que
		ja foi 3 e fazia a unidade explodir uma area que ela nao enxergava.

		Ela passou a dividir a faixa longa (12) com o Slingshot e o Archer, e isso e
		de proposito: os tres alcancam o mesmo tanto e se separam pelo que fazem la --
		o Slingshot cutuca barato, o Archer bate mais forte e mais devagar, e este
		explode. Vale reler a regra 2 la de cima antes de mexer nos tres juntos: o
		alcance so diferencia enquanto as faixas continuarem distintas.
	]]
	["Rocket"] = {
		Rarity = "Legendary",
		Class = "Ranged",
		Cost = 450,
		Damage = 50,
		Range = 12,
		Cooldown = 2.5,
		AttackType = "SingleShot",
		HitInterval = 0,
		Hits = 1,
		Projectile = { Asset = "Rocket", Speed = 55 },
		AOE = { Radius = 2 },

		RangeStats = {
			Increment = 1,
			Max = 15,
		},
	},

	--[=[
		O combo em quatro tempos: o unico golpe da tabela cujos acertos nao sao
		espacados por `HitInterval`.

		Os quatro acertos saem nos marcadores `Hit` da animacao `Attack` (0,4333s,
		1,2667s, 2,3833s e 2,5667s), que estao escritos no `UnitAttackConfig` como
		`HitTimes` -- os intervalos entre eles sao desiguais de proposito (0,83s,
		1,12s e 0,18s), e e a coreografia da animacao que manda: os dois ultimos quase
		se encostam, e sao o par rapido que fecha o combo. **O `Hits = 4` daqui tem
		que continuar batendo com o tamanho daquela lista**: quem cobra o dano conta
		pela lista, mas o DPS do card sai deste numero.

		**`Cooldown = 6` e a animacao mais a recuperacao**: 2,9s de gesto e 3,1s
		parado depois dele. O cooldown desta tabela sempre contou do inicio de um
		golpe ao inicio do seguinte, entao "parado depois de terminar a animacao" e a
		soma dos dois -- nao ha um campo de recuperacao separado, e a janela de 6s e
		a mesma que o `swingWindow` manda para o cliente encaixar a animacao. Mexeu a
		animacao, o 2,9 muda aqui e o `Duration` muda la. O `Cooldowns` do
		`UnitUpgradeConfig` desce ate 4,8s no nivel maximo, e mesmo la sobra quase o
		dobro da animacao.

		**Cada acerto e uma area de raio 3, e cada um bate menos que o anterior**
		(`HitFalloff = 0.1`): 39, 35, 32 e 28 de dano. A queda e por golpe e nao por
		alvo -- quem esta na area do segundo golpe leva os mesmos 35 que todo mundo
		que estiver la --, e e o que impede que quatro areas seguidas sejam
		simplesmente quatro vezes o golpe: o combo vale 3,44 golpes cheios, e nao 4.

		O raio 3 e menor que o alcance dela (7), de proposito, e maior que o do
		Rocket (2): o Rocket explode a 12 de alcance e este precisa de um inimigo a 7
		para bater. A area e o que o alcance curto compra.

		**O `Damage` desta tabela e por golpe, e nao por ciclo.** Os quatro acertos
		somam 134 de dano, ou 22,3 de DPS -- 5,6 por 100 de caixa contra um alvo so,
		que e de longe o pior da tabela e esta certo: e a mesma casa do Rocket (4,4),
		a outra lendaria de area, e pela mesma razao. A regra 1 la de cima mede alvo
		unico e nao mede area, entao ela cobra das duas o preco de uma coisa que elas
		nao vendem. O numero que vale para esta unidade e o de grupo: tres inimigos
		dentro do raio sao 16,7 por 100, no teto de 15 -- ela paga o custo cheio
		quando acerta a roda inteira, e e ruim contra um alvo sozinho.

		O que ela vende nao e o DPS medio: sao 134 de dano em area concentrados em
		2,9s e uma janela de 3,1s em que ela nao faz nada, entao ela limpa o que
		estiver junto e deixa passar a fila que vier atras. E a lendaria de alcance
		curto ao lado do Azure -- os dois so machucam quem chega perto --, e o que os
		separa e o ritmo e o alvo: o Azure bate de pouco em pouco num inimigo, este
		limpa a roda toda de uma vez e para.

		**Todo golpe deixa o alvo sangrando**: 4 de dano por segundo, 5 tiques
		(`MobService:ApplyBleed`). Como o do Slasher, ele **nao acumula nem renova** --
		dos quatro acertos do combo so o primeiro abre o corte, os outros tres caem em
		quem ja esta sangrando e valem so o dano do golpe. Sao 20 de dano por alvo a
		cada ciclo, e eles correm enquanto a unidade esta na recuperacao dos 3,1s.

		O corte abre o alvo do mesmo tanto que o do Slasher (`Vulnerability = 1.3`):
		enquanto o inimigo sangra, todo dano que entra nele vale 30% a mais, venha de
		onde vier -- inclusive dos golpes seguintes do proprio combo e dos tiques do
		sangramento. E o que faz os 5 segundos depois da area valerem para o time
		inteiro, e nao so para esta unidade. Um Slasher e um Berserker no mesmo alvo
		nao dobram nada: quem abriu o corte primeiro manda ate o prazo vencer.
	]=]
	["Berserker"] = {
		Rarity = "Legendary",
		Class = "Melee",
		Cost = 400,
		Damage = 39,
		Range = 7,
		Cooldown = 6,
		AttackType = "MultiShot",

		-- Sem uso nesta unidade: os intervalos saem das diferencas do `HitTimes`
		-- (ver `UnitAttackConfig`). Fica em 0 para a linha nao mentir.
		HitInterval = 0,
		Hits = 4,
		AOE = { Radius = 3 },
		HitFalloff = 0.1,
		Bleed = { Damage = 4, Ticks = 5, Interval = 1, Vulnerability = 1.3 },
		RangeStats = {
			Increment = 1,
			Max = 11,
		},
	},

	--[[ EPIC ]]

	["Subspace Tripminer"] = {
		Rarity = "Epic",
		Class = "Magic",
		Cost = 350,
		-- O servidor arredonda o dano cobrado: no nivel 0 a mina tira 38.
		Damage = 37.5,
		Range = 10,
		-- O do nivel 0; o upgrade desce ate 3s no maximo (ver o `UnitUpgradeConfig`).
		Cooldown = 5,
		AttackType = "SingleShot",
		HitInterval = 0,
		Hits = 1,
		Tripmine = {
			BaseLimit = 3,
			LimitPerUpgrade = 1,
			-- Teto das minas no mapa: 3, 4, 5 e dai para em 6 nos niveis 3 a 5.
			MaxLimit = 6,
			TriggerRadius = 2.5,
			AOE = { Radius = 6 },

			--[[
				Quanto a mina leva no ar, do fim do arremesso ate o chao.

				E tempo de partida, como o resto: acelerado, ela voa mais rapido junto
				com todo o resto. E o unico numero desta tabela que os dois lados usam
				para a mesma coisa -- o servidor **so arma a mina quando ela pousa**, e
				o cliente gasta exatamente este tempo desenhando o arco. Mexer aqui move
				os dois juntos; separa-los poria a mina explodindo com o modelo ainda no
				ar (ou o contrario).
			]]
			ThrowTime = 0.35,

			--[[
				Carregamento da mina depois de pousar.

				Ela arma assim que toca o chao, mas explode com so `StartDamage` do dano
				(0.35 = 35%) e sobe em linha reta ate 100% em `Time` segundos. Pisada aos
				2.5s, tira 67.5%. Tempo de partida, como o `ThrowTime`: no 3x carrega tres
				vezes mais rapido.
			]]
			Charge = {
				Time = 5,
				StartDamage = 0.35,
			},
		},
		RangeStats = {
			Increment = 1,
			Max = 12,
		},
	},

	--[[
		Gelo de alvo unico: o tiro e o do Slingshot (sem area), e o que ela vende e o
		controle, e nao o dano. Cada acerto deixa um acumulo de `Frost`; com qualquer
		acumulo o inimigo anda 30% mais devagar, e no quarto ele congela por 3s.

		Por isso o DPS por caixa fica abaixo do das outras Epic (regra 1): 10 a cada 1s
		da 10 de DPS, ou 5 por 100 de caixa. O resto do preco e o congelamento: tiro
		rapido fecha os quatro acumulos em 3s, congela por 3s, e o inimigo ainda passa
		2s imune antes de poder acumular de novo -- perto de um terco do tempo parado,
		e nunca preso de vez, por mais rapida que a unidade fique.
	]]
	["Frostione"] = {
		Rarity = "Epic",
		Class = "Ice",
		Cost = 200,
		Damage = 10,
		Range = 10,
		Cooldown = 1,
		AttackType = "SingleShot",
		HitInterval = 0,
		Hits = 1,
		Projectile = { Asset = "FrostioneProjectile", Speed = 60 },

		--[[
			Os acumulos de gelo (ver o `MobService:ApplyFrost`).

			Os acumulos sao contados **por unidade**: cada Frostione tem a conta dela no
			inimigo, e o acerto dela so renova o prazo dos dela. `Duration` e quanto
			eles duram sem acerto novo. `FreezeStacks` acumulos de uma mesma unidade
			congelam o inimigo por `FreezeDuration` segundos e zeram a conta de todas, e
			por mais `FreezeImmunity` segundos depois do degelo ele nao aceita acumulo
			nenhum: sem essa folga a Frostione refaz os quatro e prende o mesmo inimigo
			para sempre quando o cooldown dela fica curto.

			`Slow` e a lentidao, uma so, enquanto qualquer Frostione tiver acumulo no
			inimigo -- a carta Chill Out multiplica este numero.

			`Radius` e a area em volta do alvo: todo inimigo nela ganha um acumulo da
			mesma unidade, como se tivesse levado o tiro, mas sem dano -- o dano
			continua so no alvo. Sobe em linha reta ate `MaxRadius` no nivel maximo
			(`UnitUpgradeConfig:GetFrostRadius`).
		]]
		Frost = {
			Slow = 0.3,
			Duration = 4,
			FreezeStacks = 4,
			FreezeDuration = 3,
			FreezeImmunity = 2,
			Radius = 2,
			MaxRadius = 4,
		},

		RangeStats = {
			Increment = 1,
			Max = 14,
		},
	},

	--[[
		A unidade que nao ataca: ela paga caixa no fim de cada wave e faz quem esta
		em volta render mais.

		As duas coisas crescem com o upgrade, e por caminhos diferentes. A renda e
		uma escada na mao (`Incomes`, no `UnitUpgradeConfig`) que dobra e sobra do
		nivel 0 ao 5 -- 60 a 225 --, com um salto de 50% no ultimo degrau contra os
		25% dos outros: o nivel maximo dela e o unico investimento de economia da
		tabela. A aura sobe 5 pontos por nivel e **para em 30%** (`Aura.MaxBonus`),
		entao os niveis 4 e 5 dao o mesmo bonus e o que o ultimo compra e a renda e
		o raio.

		O raio e o `Range` (ver o `Aura` abaixo), e vai de 4 a 8 em degraus
		desiguais -- e a unica unidade cujo alcance dobra com o upgrade, porque nela
		alcance nao e mira, e quantas torres cabem debaixo da aura.
	]]
	["Entrepreneur"] = {
		Rarity = "Epic",
		Class = "Melee",
		Cost = 200,
		Damage = 0,
		Range = 4,
		Cooldown = 2,
		AttackType = "SingleShot",
		HitInterval = 0,
		Hits = 1,
		Farm = {
			-- O do nivel 0; a escada inteira e o `Incomes` do `UnitUpgradeConfig`, e
			-- quem faz a conta para os dois lados e o `GetIncome`.
			Income = 60,

			--[[
				A aura: toda unidade aliada dentro do alcance do Entrepreneur leva
				`Bonus` a mais de caixa em cima do que ela ganhar por dano e por morte.
				Vale para qualquer dono -- a torre do vizinho tambem rende mais perto
				da minha farm, e quem recebe e sempre o dono da torre.

				O raio nao esta escrito aqui de proposito: ele e o `Range` acima, lido
				pelo `UnitUpgradeConfig:GetRange`, que e exatamente o circulo que o
				jogador ve ao selecionar a farm. Mexer no `Range` move a aura e o
				circulo juntos, e nao ha como um mentir sobre o outro.

				`Bonus` e uma fracao somavel: 0.15 e "+15%", e duas farms cobrindo a
				mesma torre valem 30%. `BonusPerUpgrade` e quanto cada nivel soma --
				somado, e nao multiplicado como a renda, porque porcentagem que cresce
				em passo redondo (15, 20, 25...) e o que o card consegue mostrar sem
				casa decimal.

				Quem faz a conta e o `UnitUpgradeConfig:GetAuraBonus`, para o servidor
				e o card nunca discordarem.
			]]
			Aura = {
				Bonus = 0.10,
				BonusPerUpgrade = 0.05,

				--[[
					O teto da aura, e o que faz os niveis 4 e 5 darem os mesmos 30%.

					Sem ele a conta seguiria reta ate 35% no maximo, e duas farms
					encostadas fechariam 70% em cima de cada torre -- o bonus e somavel
					entre farms (ver o `Bonus` acima), entao o que limita o empilhamento
					e este numero e nao o numero de farms. O ultimo upgrade nao fica
					vazio por causa disso: ele compra o salto de renda (150 -> 225) e
					mais um stud de raio.
				]]
				MaxBonus = 0.30,
			},
		},
		RangeStats = {
			Levels = { 4, 5, 5, 6, 7, 8 },
		},
	},

	--[[ RARE ]]

	--[[
		A barata de longe: 7 de dano a cada 1,15 s, a 6,1 de DPS -- 3,5 por 100 de
		caixa, o pior da tabela e de proposito. Ela nao mata nada sozinha; o que ela
		vende e cutucar sem parar de longe, e no nivel maximo o ciclo cai para 0,77 s
		e o dano quase quadruplica (26).

		**O cooldown ja nao e mais curto que o windup do tiro** (0,7 s no
		`UnitAttackConfig`) nos primeiros niveis, mas volta a ficar perto dele no
		topo, e por isso o passo dela continua escrito como `HitTimes` + `Duration`,
		e nao como `HitTime`: com 0,77 s de ciclo contra 1,25 s de animacao, as duas
		pontas espremem o instante junto com o gesto. Ver o comentario dela la.

		O alcance sobe em degraus ate 16 (`RangeStats.Levels`) -- a faixa longa da
		regra 2, que ela divide com o Archer (12 na base tambem, 17 no maximo).
	]]
	["Slingshot"] = {
		Rarity = "Rare",
		Class = "Ranged",
		Cost = 175,
		Damage = 7,
		Range = 12,
		Cooldown = 1.15,
		AttackType = "SingleShot",
		HitInterval = 0,
		Hits = 1,
		Projectile = { Asset = "Bullet", Speed = 75 },
		RangeStats = {
			Levels = { 12, 13, 14, 15, 15, 16 },
		},
	},

	--[[
		O Slingshot com outro boneco: mesma familia (Ranged de tiro unico e projetil
		`Bullet`), so que o arco puxa mais devagar e bate mais forte.

		**Os numeros sao provisorios** e existem para a unidade entrar em jogo
		coerente, nao para fechar balanceamento. Duas coisas neles nao sao chute e
		vale saber antes de mexer:

		- **2,00s e o piso do cooldown**, e e a duracao da animacao `Attack` do
		  modelo. O `Cooldowns` do `UnitUpgradeConfig` desce de 3,5s ate exatamente
		  esse numero no nivel maximo e nao passa dele: com um cooldown menor a
		  unidade pediria um golpe novo antes de o boneco terminar o anterior, e o
		  `playAttackVisual` nao reinicia uma track que ja esta tocando -- a flecha
		  sairia sem o gesto acompanhar.
		- 16 de dano em 3,5s da 4,6 de DPS, ou 3,0 por 100 de caixa: na mesma casa do
		  Slingshot (3,5), que e a outra Rare de tiro, e bem abaixo do teto de 15 da
		  regra 1 la de cima. No nivel maximo sao 22,5 de DPS.

		**A flecha atravessa** (`Projectile.Subtype = "Piercing"`), e e isso que separa
		o Archer do Slingshot agora que os dois tem o mesmo alcance: o tiro deixa de
		valer por alvo e passa a valer por **fila**. Contra um inimigo sozinho ele
		continua sendo os mesmos 8,0 de DPS; contra a fileira que anda em coluna pelo
		caminho, ele cobra de cada um que estiver na linha, e por isso o lugar onde a
		unidade e posta passa a importar mais que o numero dela.

		`PierceFalloff = 0.1` e o freio disso. Cada corpo furado tira 10% do que o
		anterior levou, entao os 16 de dano saem 16, 14, 13, 12, 10, 9, 9, 8: oito
		inimigos em linha somam 91 de dano, e nao os 128 de oito tiros cheios. Sem a
		queda, um Archer bem posto num mapa que enfileira estouraria o teto de 15 por
		100 de caixa da regra 1 la de cima sozinho; com ela, alinhar mais inimigos
		continua valendo a pena e para de escalar reto.

		Contra um alvo so ele passa a valer o dobro do que valia ao subir de nivel --
		o dano quase triplica (16 a 45) enquanto o ciclo cai quase pela metade (3,5s a
		2s) --, e contra fila ele escala junto com os dois. E por isso que o
		`Cooldowns` dele para nos 2s da animacao: e o unico teto que a unidade tem.

		Se ele ainda virar escolha obvia em algum mapa, os botoes a girar sao o
		`Damage` e o `PierceFalloff`, nesta ordem -- o subtipo e a identidade da
		unidade, e nao um numero de balanceamento.
	]]
	["Archer"] = {
		Rarity = "Rare",
		Class = "Ranged",
		Cost = 150,
		Damage = 16,
		Range = 12,
		Cooldown = 3.5,
		AttackType = "SingleShot",
		HitInterval = 0,
		Hits = 1,
		Projectile = { Asset = "Bullet", Speed = 75, Subtype = "Piercing", PierceFalloff = 0.1 },
		RangeStats = {
			Increment = 1,
			Max = 17,
		},
	},

	--[[
		A primeira unidade `Fire`: tiro unico com projetil, e o acerto deixa o alvo
		queimando -- 3 de dano a cada 0,5s por 10s, 60 no total, pelo
		`MobService:ApplyBurn`.

		**A queimadura nao acumula**, venha de quem vier: acerto em quem ja queima so
		da o dano do tiro, sem somar tique nem renovar o prazo. Por isso o valor dela
		esta em **espalhar** o fogo, e nao em insistir no mesmo alvo.

		**Os numeros de custo, alcance e cooldown sao provisorios.** O que nao e
		chute: `Cooldown = 2,1` fica logo acima da animacao `Attack` (2,033s), pelo
		mesmo motivo do Archer; 15 de dano em 2,1s da 7,1 de DPS no tiro, e com a
		queimadura inteira (6 de DPS) chega a 13,1 -- 8,8 por 100 de caixa, abaixo do
		teto de 15 da regra 1 la de cima.

		A queimadura nao cresce com upgrade, clima nem carta de dano: so a carta Fire
		Hazard mexe nela.
	]]
	["Pyre"] = {
		Rarity = "Rare",
		Class = "Fire",
		Cost = 150,
		Damage = 15,
		Range = 10,
		Cooldown = 2.1,
		AttackType = "SingleShot",
		HitInterval = 0,
		Hits = 1,
		Projectile = { Asset = "PyreProjectile", Speed = 60 },

		--[[
			O tiro estoura onde cai: quem estiver a 3 studs da mira leva o dano cheio
			**e** pega fogo, porque a queimadura sai do `creditDamage` e ele roda uma
			vez por alvo atingido.

			E o que separa o Pyre do Rocket, que tem area de 2 e nao deixa nada: aqui a
			area nao e o golpe, e o que espalha a queimadura. Numa fila apertada um tiro
			so acende quatro inimigos, e cada um queima por conta propria pelos 10s --
			o `BurningUntil` e por mob, e a regra de nao acumular continua valendo por
			inimigo, nao por tiro.

			Sem queda por alvo, de proposito: a area e pequena (3 contra os 6 da
			tripmine) e o cooldown e longo. Se precisar segurar, o lugar e o raio.
		]]
		AOE = { Radius = 3 },

		Burn = { Damage = 3, Ticks = 20, Interval = 0.5 },
		RangeStats = {
			Increment = 1,
			Max = 14,
		},
	},

	--[[ COMMON ]]

	--[[
		O golpe pesado e lento, contra o Slasher que e rapido e fraco.

		35 de dano a cada 2 s da 17,5 de DPS, ou 8,8 por 100 de caixa: o melhor
		aproveitamento das duas Common, e o preco disso e o alcance -- ela so alcanca
		4, e o upgrade so a leva a 5 (`RangeStats.Levels`), do nivel 3 para cima. E a
		unidade que precisa colar no caminho mais que qualquer outra.
	]]
	["Sword"] = {
		Rarity = "Common",
		Class = "Melee",
		Cost = 200,
		Damage = 35,
		Range = 4,
		Cooldown = 2,
		AttackType = "SingleShot",
		HitInterval = 0,
		Hits = 1,
		RangeStats = {
			Levels = { 4, 4, 4, 5, 5, 5 },
		},
	},

	--[[
		A unidade de entrada: 90 de caixa, o menor preco da tabela, porque e o que o
		jogador compra na wave 1.

		5 de dano a cada 0,85 s da 5,9 de DPS, ou 6,5 por 100 de caixa -- longe do
		teto de 15 da regra 1, e **acima** do Slingshot (4,2) e do Archer (5,3), que
		sao Rare e custam mais. A escada por raridade ja nao valia (ver a regra 1 la
		em cima), e o que separa os tres continua sendo o alcance: ela precisa colar
		no caminho para bater, e eles nao.

		O alcance sobe em degraus ate 6 (`RangeStats.Levels`), e para ai de proposito:
		na faixa media ela alcancaria o mesmo que as unidades de tiro sem ter deixado
		de ser corpo a corpo em nada.
	]]
	--[[
		Cada golpe deixa o alvo sangrando: 1 de dano por segundo, 5 tiques. Como a
		queimadura, **nao acumula nem renova** -- golpe em quem ja sangra so da o dano
		do golpe. Upgrade, clima e carta nao mexem no sangramento.

		O corte tambem abre o alvo: enquanto ele sangra, todo dano que entrar nele vale
		30% a mais (`Vulnerability`), venha de onde vier. Isso vale muito mais no time
		do que na unidade -- os 5 tiques de 1 sao troco perto de 30% do que as outras
		torres despejam no mesmo alvo --, e e de proposito: o Slasher e a unidade de
		entrada, e o que ela faz de melhor e marcar o alvo para os outros.
	]]
	["Slasher"] = {
		Rarity = "Common",
		Class = "Melee",
		Cost = 90,
		Damage = 5,
		Range = 4,
		Cooldown = 0.85,
		AttackType = "MultiShot",
		HitInterval = 0,
		Hits = 1,
		Bleed = { Damage = 1, Ticks = 5, Interval = 1, Vulnerability = 1.3 },
		RangeStats = {
			Levels = { 4, 5, 5, 5, 6, 6 },
		},
	},
}

return UnitStats
