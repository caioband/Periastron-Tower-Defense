--[[
	A vida base de cada inimigo. O que chega no mob e a vida daqui multiplicada
	pela dificuldade e pela wave: `HealthMultiplier * HealthGrowth^(wave-1)`, ver
	`MobService:SpawnWave`.

	Estes numeros sao os da planilha do Dificil (`Config.Wave`): a coluna de vida
	total por wave dela foi calculada com eles, entao mexer aqui desloca a curva
	inteira. A variedade de vida entre os tipos e de proposito — o Squire e fragil
	e rapido, o Guard e gordo e lento — e a mistura de tipos por wave e o que faz a
	curva subir, nao o tamanho de um inimigo so.
]]

local Mob = {}

--[[
	Velocidade de referencia, em studs por segundo. A velocidade que o mob recebe e
	`BaseSpeed * SpeedMultiplier do inimigo * SpeedMultiplier do preset *
	SpeedGrowth^(wave-1)`, com teto no `SpeedGrowthCap` — ver `MobService:SpawnWave`
	e `Config.Difficulty`.
]]
Mob.BaseSpeed = 4

Mob.Entities = {
	Traveler = {
		Health = 5,
		SpeedMultiplier = 1,
	},

	RedcliffPawn = {
		Health = 10,
		SpeedMultiplier = 1,
	},

	RedcliffSquire = {
		Health = 6,
		SpeedMultiplier = 1.5,
	},

	RedcliffGuard = {
		Health = 20,
		SpeedMultiplier = 1 / 1.75,
	},

	WallSmasher = {
		Health = 15,
		SpeedMultiplier = 1,
		Gimmicks = {
			{ Type = "PerTurnSpeedMultiplier", Amount = 0.3, MaxStacks = 5 },
		},
	},

	CourageBearer = {
		Health = 15,
		SpeedMultiplier = 2.5,
		Gimmicks = {
			{ Type = "PerTurnSpeedMultiplier", Amount = -0.15, MaxStacks = 5 },
		},
	},

	WingedSquire = {
		Health = 40,
		SpeedMultiplier = 1.5,
	},

	RedcliffEnforcer = {
		Health = 120,
		SpeedMultiplier = 1 / 1.75,
	},

	RedcliffChampion = {
		Health = 900,
		SpeedMultiplier = 1 / 2,
		Gimmicks = {
			--[[
				O golpe de assinatura do Redcliff Champion: na metade da vida ele para,
				bate, e uma unidade aleatoria fica atordoada.

				`ModelSet = "Hard"` porque o chefe do elenco Astral tem o dele (o
				`HealthThresholdRush`, logo abaixo), e os dois disparavam no mesmo 50%:
				o Sentinel tocava `Attack` e `Rush` juntos e ficava parado 1,3s
				justamente quando o arranque comecava. **Um chefe, um golpe.**
			]]
			{
				Type = "HealthThresholdStunRandomUnit",
				ModelSet = "Hard",
				Threshold = 0.5,
				StunDuration = 15,
				AnimTime = 1.3,
				Once = true,
			},

			--[[
				O arranque do Astral Sentinel: na metade da vida ele toca o `Rush` e
				dispara.

				`MarkerTime` e onde cai o marcador `Action` dentro da animacao —
				0,5667s dos 3,25s de `rbxassetid://98921075157550`, medido do asset
				publicado. Quem conta o tempo e o servidor, e nao o marcador de
				verdade no cliente: o buff e de partida, entao ele tem de sair igual
				para todo mundo na sala e nao pode depender de um cliente avisar que a
				animacao chegou la. O cliente toca a mesma animacao no mesmo instante,
				entao o arranque cai no quadro certo na tela.

				**Se o `Rush` for reexportado, este numero tem de ser remedido** — e o
				unico lugar onde o codigo sabe de cor uma coisa que mora no asset.
			]]
			{
				Type = "HealthThresholdRush",
				ModelSet = "Easy",
				Threshold = 0.5,
				Animation = "Rush",
				MarkerTime = 0.5667,

				-- `RushScale = 1 + Amount`, entao 1 e velocidade dobrada.
				Amount = 1,

				Duration = 3,
				Once = true,
			},
		},
	},
}

--[[
	Qual boneco cada inimigo veste, por dificuldade.

	Os modelos vivem em `Assets.Entities.Difficulties.<conjunto>`, e cada conjunto e
	um **reskin por slot**: a lista de entidades acima continua sendo a verdade —
	mesma vida, mesma velocidade, mesmos gimmicks — e o conjunto so diz que modelo
	desenhar no lugar de cada uma. Trocar de dificuldade nao muda a partida, muda o
	elenco.

	As chaves sao nomes de entidade e os valores sao nomes de modelo. O que nao
	estiver na tabela usa o proprio nome da entidade, que e o caso da maioria do
	`Hard`.

	`Hard` e o fallback: dificuldade sem `ModelSet` (ou com um que nao exista na
	pasta) cai nele, e por isso ele e o unico conjunto que **precisa** ter os nove.
]]
Mob.DefaultModelSet = "Hard"

Mob.ModelSets = {
	-- Identidade, menos o alado: a entidade se chama `WingedSquire` desde a
	-- planilha e o modelo se chama `WingedRedcliff`. Enquanto os dois nomes
	-- existirem, e esta linha que os liga -- sem ela o `FindFirstChild` falha e o
	-- inimigo nasce vestido de outro.
	Hard = {
		WingedSquire = "WingedRedcliff",
	},

	--[[
		O elenco Astral, oito modelos para nove slots.

		A ordem sai da regua que o `Weakest`/`Strongest` desenha no Workspace: os
		modelos estao enfileirados do mais fraco ao mais forte, e a fila casa degrau
		por degrau com o `SPAWN_ORDER` do `Config.Wave`.

		Sobra um slot, e quem repete e o `AstralAdventurer`, no Enforcer. A conta e de
		leitura de tela: o Enforcer e o Champion aparecem juntos na ultima wave, entao
		dar o modelo do chefe ao Enforcer tiraria do chefe o unico momento em que ele
		tem que ser inconfundivel. Repetir o degrau de baixo custa dois elites
		parecidos; repetir o de cima custaria o chefe.
	]]
	Easy = {
		Traveler = "AstralInitiate",
		RedcliffPawn = "AstralWizard",
		RedcliffSquire = "AstralKnight",
		RedcliffGuard = "AstralGuardia",
		WallSmasher = "AstralNecromancer",
		CourageBearer = "AstralSentry",
		WingedSquire = "AstralAdventurer",
		RedcliffEnforcer = "AstralAdventurer",
		RedcliffChampion = "AstralSentinel",
	},
}

--[=[
	Os gimmicks de `entityName` que valem no conjunto `setName`.

	Gimmick sem `ModelSet` vale em todo lugar; com `ModelSet`, ele so sai no conjunto
	que o nomeia. E o que deixa **cada inimigo de cada elenco ter o seu golpe**: o
	Astral Sentinel arranca, o Redcliff Champion atordoa uma torre, e nenhum dos dois
	faz o do outro.

	Atencao ao que o nome diz: o filtro e por **conjunto de modelos**, e nao por
	dificuldade. `ModelSet = "Hard"` alcanca Medium, Hard, Impossible, Nightmare e o
	Tutorial -- todos os presets que vestem o elenco Redcliff.

	Para um inimigo **trocar** de golpe entre os elencos, e preciso escopar os dois
	lados: um gimmick `Easy` novo convive com um gimmick sem `ModelSet` em vez de
	substitui-lo. E o que os dois do chefe fazem aqui embaixo.

	Isto **afrouxa** a regra de que trocar de dificuldade so troca o elenco, e por
	isso a excecao e declarada numa chave visivel em vez de sair de um `if` em
	algum handler. Quem le a entidade ve quais gimmicks nao valem em todo lugar.
]=]
function Mob.GetGimmicks(setName : string?, entityName : string)
	local entity = Mob.Entities[entityName]
	if not entity or not entity.Gimmicks then return {} end

	local set = setName or Mob.DefaultModelSet
	local allowed = {}

	for _, gimmick in entity.Gimmicks do
		if gimmick.ModelSet == nil or gimmick.ModelSet == set then
			table.insert(allowed, gimmick)
		end
	end

	return allowed
end

--[=[
	O modelo que `entityName` veste no conjunto `setName`.

	Conjunto desconhecido cai no padrao, e entidade sem entrada no conjunto usa o
	proprio nome. Nunca devolve nil: quem chama esta escolhendo um filho de uma
	pasta, e um nome errado la vira um aviso, nao um erro.
]=]
function Mob.GetModelName(setName : string?, entityName : string) : string
	local set = Mob.ModelSets[setName or ""] or Mob.ModelSets[Mob.DefaultModelSet]
	return (set and set[entityName]) or entityName
end

return Mob
