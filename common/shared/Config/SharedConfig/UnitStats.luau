--[[
	Os numeros de cada unidade.

	Duas regras seguram esta tabela, e vale conferi-las antes de mexer:

	1. Dano por segundo dividido pelo custo. E o que decide se uma unidade vale a
	   pena, e o teto e 15 por 100 de caixa. O Slasher ficava em 26,7 — quase tres
	   vezes o segundo colocado — e por isso encher o mapa de Slasher era a jogada
	   otima em qualquer dificuldade. A escada por raridade nao vale mais: Slasher
	   3,5 e Slingshot 4,6 contra Sword ~10, Epic ~11 e Legendary 11 a 14.

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

	`PierceFalloff` e o que impede que atravessar seja de graca. Ele e **composto**:
	com 0.1, o segundo inimigo leva 90% do primeiro, o terceiro 90% do segundo. Nunca
	chega a zero de proposito -- uma flecha que furou dez corpos ainda machuca um
	pouco -- e o resultado e arredondado com piso de 1, para o fim da fila nao virar
	um "0" flutuando na tela. Sem o campo, a flecha atravessa sem perder nada.
]]

local UnitStats = {
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

	--[[ EPIC ]]

	["Subspace Tripminer"] = {
		Rarity = "Epic",
		Class = "Magic",
		Cost = 350,
		Damage = 75,
		Range = 10,
		Cooldown = 3,
		AttackType = "SingleShot",
		HitInterval = 0,
		Hits = 1,
		Tripmine = {
			BaseLimit = 3,
			LimitPerUpgrade = 1,
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

	-- A unidade de entrada: continua custando 100 porque e o que o jogador compra
	-- na wave 1, e o dano por golpe e o preco de bater a cada 0,85 s: 3,5 de DPS
	-- por 100 de caixa, abaixo do Slingshot, que e Rare e custa mais.
	["Slasher"] = {
		Rarity = "Common",
		Class = "Melee",
		Cost = 100,
		Damage = 3,
		Range = 5,
		Cooldown = 0.85,
		AttackType = "MultiShot",
		HitInterval = 0,
		Hits = 1
	},
}

return UnitStats
