--[[
	Os numeros de cada unidade.

	Duas regras seguram esta tabela, e vale conferi-las antes de mexer:

	1. Dano por segundo dividido pelo custo. E o que decide se uma unidade vale a
	   pena, e o teto e 15 por 100 de caixa. O Slasher ficava em 26,7 — quase tres
	   vezes o segundo colocado — e por isso encher o mapa de Slasher era a jogada
	   otima em qualquer dificuldade. A escada por raridade nao vale mais: Slasher
	   5,9 e Slingshot 5,2 contra Sword 10,0, Epic ~11 e Legendary 11 a 14.

	2. Alcance como eixo de diferenciacao. Cinco das sete unidades tinham alcance
	   3, o que tornava posicionamento irrelevante — todas precisavam colar no
	   caminho. As faixas agora sao curto (4 a 6), medio (10) e longo (12), e o
	   alcance longo e do Slingshot, que nao tem area nem dano alto.

	DPS = Damage * Hits / Cooldown.

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

	`Slow`, `Stun`, `Burn` e `Frost` sao o que o golpe **deixa** no inimigo, alem do
	dano. Hoje deixam o Electro (o tranco do choque) e o Frostione (os acumulos de
	gelo); o `Burn` espera uma unidade `Fire`:

	| Campo | O que e |
	| --- | --- |
	| `Slow` | `{ Amount, Duration }` -- `Amount` e a fracao de velocidade tirada (0.3 e "anda 30% mais devagar") |
	| `Stun` | `{ Duration }` -- o inimigo para **de vez** por tantos segundos |
	| `Burn` | `{ Damage, Ticks, Interval }` -- tantos tiques de tanto dano, de tantos em tantos segundos |
	| `Frost` | `{ Slow, Duration, FreezeStacks, FreezeDuration, Radius, MaxRadius }` -- um acumulo por acerto, contado **por unidade**; com qualquer acumulo o inimigo fica `Slow` mais lento, o acerto de uma unidade renova so o prazo dos dela, e `FreezeStacks` de uma mesma unidade o congelam por `FreezeDuration` e zeram a conta de todas. `Radius` (ate `MaxRadius` no nivel maximo) da o mesmo acumulo, sem dano, a quem estiver em volta do alvo |

	`Slow` e `Stun` nao sao a mesma coisa em intensidades diferentes: a lentidao mexe
	na velocidade do inimigo, o tranco tira ele do laco de movimento. Os dois cabem no
	mesmo golpe (nenhuma unidade de hoje declara os dois), e e por serem coisas
	diferentes que o tranco pode ser tao curto: parado e parado, e um terco de segundo
	disso ja e um pedaco de caminho que o inimigo nao andou.

	Quem os executa e o `MobService` (`ApplySlow`, `StunMob`, `ApplyBurn`), que e o
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
		ciclo, ou 28,8 de DPS com a corrente cheia -- 9,6 por 100 de caixa, dentro do
		teto da regra 1. Contra um alvo sozinho sao 7,2 de DPS, 2,4 por 100: ai ela e
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
		Cost = 300,
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

		**`Cooldown = 5.9` e a animacao mais a recuperacao**: 2,9s de gesto e 3s
		parado depois dele. O cooldown desta tabela sempre contou do inicio de um
		golpe ao inicio do seguinte, entao "3 segundos depois de terminar a
		animacao" e a soma dos dois -- nao ha um campo de recuperacao separado, e a
		janela de 5,9s e a mesma que o `swingWindow` manda para o cliente encaixar a
		animacao. Mexeu a animacao, o 2,9 muda aqui e o `Duration` muda la.

		**Cada acerto e uma area de raio 3, e cada um bate menos que o anterior**
		(`HitFalloff = 0.1`): 35, 32, 28 e 26 de dano. A queda e por golpe e nao por
		alvo -- quem esta na area do segundo golpe leva os mesmos 32 que todo mundo
		que estiver la --, e e o que impede que quatro areas seguidas sejam
		simplesmente quatro vezes o golpe: o combo vale 3,44 golpes cheios, e nao 4.

		O raio 3 e maior que o do Rocket (2), e de proposito: o Rocket explode a 12
		de alcance e este precisa de um inimigo a 6 para bater. A area e o que o
		alcance curto compra.

		Os quatro acertos somam 121 de dano por ciclo, ou 20,5 de DPS -- **5,1 por
		100 de caixa contra um alvo so**, que e de longe o pior da tabela e esta
		certo: e a mesma casa do Rocket (4,4), a outra lendaria de area, e pela mesma
		razao. A regra 1 la de cima mede alvo unico e nao mede area, entao ela cobra
		das duas o preco de uma coisa que elas nao vendem. O numero que vale para
		esta unidade e o de grupo: tres inimigos dentro do raio sao 15,4 por 100, na
		linha do teto de 15 -- ela paga o custo cheio quando acerta a roda inteira, e
		e ruim contra um alvo sozinho.

		O que ela vende nao e o DPS medio: sao 121 de dano em area concentrados em
		2,9s e uma janela de 3s em que ela nao faz nada, entao ela limpa o que estiver
		junto e deixa passar a fila que vier atras. E a lendaria de alcance curto ao
		lado do Azure -- os dois so machucam quem chega perto --, e o que os separa e
		o ritmo e o alvo: o Azure bate de pouco em pouco num inimigo, este limpa a
		roda toda de uma vez e para.
	]=]
	["Berserker"] = {
		Rarity = "Legendary",
		Class = "Melee",
		Cost = 400,
		Damage = 35,
		Range = 6,
		Cooldown = 5.9,
		AttackType = "MultiShot",

		-- Sem uso nesta unidade: os intervalos saem das diferencas do `HitTimes`
		-- (ver `UnitAttackConfig`). Fica em 0 para a linha nao mentir.
		HitInterval = 0,
		Hits = 4,
		AOE = { Radius = 3 },
		HitFalloff = 0.1,
		RangeStats = {
			Increment = 1,
			Max = 10,
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
		rapido fecha os quatro acumulos em 3s, e o mesmo alvo passa perto de metade do
		tempo parado.
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
			congelam o inimigo por `FreezeDuration` segundos e zeram a conta de todas.

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
			Radius = 2,
			MaxRadius = 4,
		},

		RangeStats = {
			Increment = 1,
			Max = 14,
		},
	},

	["Entrepreneur"] = {
		Rarity = "Epic",
		Class = "Melee",
		Cost = 200,
		Damage = 0,
		Range = 6,
		Cooldown = 2,
		AttackType = "SingleShot",
		HitInterval = 0,
		Hits = 1,
		Farm = {
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
				Bonus = 0.15,
				BonusPerUpgrade = 0.05,
			},
		},
	},

	--[[ RARE ]]

	-- O maior alcance da tabela e o que ela vende: um tiro a cada 1,6 s e o menor
	-- dano por tiro, a 4,6 de DPS por 100 de caixa.
	["Slingshot"] = {
		Rarity = "Rare",
		Class = "Ranged",
		Cost = 150,
		Damage = 11,
		Range = 12,
		Cooldown = 1.4,
		AttackType = "SingleShot",
		HitInterval = 0,
		Hits = 1,
		Projectile = { Asset = "Bullet", Speed = 75 },
		RangeStats = {
			Increment = 1,
			Max = 20,
		},
	},

	--[[
		O Slingshot com outro boneco: mesma familia (Ranged de tiro unico e projetil
		`Bullet`), so que o arco puxa mais devagar e bate mais forte.

		**Os numeros sao provisorios** e existem para a unidade entrar em jogo
		coerente, nao para fechar balanceamento. Duas coisas neles nao sao chute e
		vale saber antes de mexer:

		- `Cooldown = 2` e a duracao da animacao `Attack` do modelo (2,00s). Com um
		  cooldown menor a unidade pediria um golpe novo antes de o boneco terminar o
		  anterior, e o `playAttackVisual` nao reinicia uma track que ja esta tocando
		  -- a flecha sairia sem o gesto acompanhar.
		- 16 de dano em 2s da 8,0 de DPS, ou 5,3 por 100 de caixa: a mesma faixa do
		  Slingshot (5,2), bem abaixo do teto de 15 da regra 1 la de cima.

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
		Cooldown = 2,
		AttackType = "SingleShot",
		HitInterval = 0,
		Hits = 1,
		Projectile = { Asset = "Bullet", Speed = 75, Subtype = "Piercing", PierceFalloff = 0.1 },
		RangeStats = {
			Increment = 1,
			Max = 20,
		},
	},

	--[[ COMMON ]]

	-- O golpe pesado e lento, contra o Slasher que e rapido e fraco.
	["Sword"] = {
		Rarity = "Common",
		Class = "Melee",
		Cost = 175,
		Damage = 35,
		Range = 4,
		Cooldown = 2,
		AttackType = "SingleShot",
		HitInterval = 0,
		Hits = 1
	},

	--[[
		A unidade de entrada: continua custando 100 porque e o que o jogador compra
		na wave 1.

		5 de dano a cada 0,85 s da 5,9 de DPS, ou 5,9 por 100 de caixa -- longe do
		teto de 15 da regra 1, e agora **acima** do Slingshot (5,2) e do Archer (5,3),
		que sao Rare e custam 150. A escada por raridade ja nao valia (ver a regra 1
		la em cima), e o que separa os tres continua sendo o alcance: ela precisa
		colar no caminho para bater, e eles nao.

		O alcance sobe ate 8 com upgrade (`RangeStats`), e isso e o mais perto que
		uma Melee chega da faixa media da regra 2. O teto e 8 de proposito: em 10 ela
		alcancaria o mesmo que as unidades de tiro medio sem ter deixado de ser
		corpo a corpo em nada.
	]]
	["Slasher"] = {
		Rarity = "Common",
		Class = "Melee",
		Cost = 100,
		Damage = 5,
		Range = 5,
		Cooldown = 0.85,
		AttackType = "MultiShot",
		HitInterval = 0,
		Hits = 1,
		RangeStats = {
			Increment = 1,
			Max = 8,
		},
	},
}

return UnitStats
