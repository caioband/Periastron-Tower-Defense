local UnitAttackConfig = {

	--[[
		AttackSequence: ordered list of attack steps that cycle on each attack.
		  Animation  - name of the Animation child on the unit model to play
		  HitTime    - seconds into the animation when the hit fires to the server
		              (set to 0 to fire immediately on swing start)
		  HitTimes   - lista de instantes, no lugar do `HitTime`, quando o golpe
		              acerta mais de uma vez dentro da MESMA animacao
		  Duration   - a duracao da animacao, em segundos; so faz falta junto do
		              `HitTimes` (ver abaixo)
		The sequence loops back to step 1 after the last step.
	--]]

	--[=[
		`HitTimes` e o golpe que acerta varias vezes **em tempos proprios**, e nao o
		`Hits`/`HitInterval` do `UnitStats`, que espaca os acertos de forma igual a
		partir do windup.

		Os dois nao se misturam: com `HitTimes` no passo, o numero de acertos e o
		tamanho da lista e os intervalos saem das diferencas dela -- o `HitTime`, o
		`Hits` e o `HitInterval` daquela unidade ficam de fora do calculo. O `Hits`
		do `UnitStats` continua tendo que bater com `#HitTimes`, porque e ele que o
		`GetDPS` usa para o numero que o card mostra.

		Os instantes sao os dos marcadores `Hit` da animacao, copiados na mao -- a
		mesma regra do `HitTime` do Archer logo abaixo, e pelo mesmo motivo: quem
		cobra o dano e o servidor, que nao tem `AnimationTrack` para escutar. Mexeu
		o marcador, mexe aqui junto.

		`Duration` e a duracao da animacao, e existe para o servidor **espremer os
		acertos junto com o gesto**. O cliente ja encolhe a animacao quando ela nao
		cabe na janela do golpe (ver `Unit:playAttackVisual`); sem o mesmo fator
		aqui, uma unidade acelerada por carta acertaria no tempo antigo enquanto o
		boneco corre no novo -- e o ultimo acerto sairia depois de o golpe seguinte
		ja ter comecado. Com a janela maior que a animacao, que e o caso normal, o
		fator e 1 e os instantes sao os da lista.
	]=]

	["Azure"] = {
		AttackSequence = {
			{ Animation = "Attack", HitTime = 1, SwingSound = "AzurePeriastron" },
		},
	},

	["Entrepreneur"] = {
		AttackSequence = {
			{ Animation = "Attack", HitTime = 0.5 },
		},
	},

	["Subspace Tripminer"] = {
		AttackSequence = {
			{ Animation = "Attack", HitTime = 1.15 },
		},
	},


	["Slingshot"] = {
		AttackSequence = {
			{ Animation = "Attack", HitTime = 0.7 },
		},
	},

	--[[
		1,017s e o frame do marcador `Hit` da animacao `Attack` do Archer -- o
		instante em que quem animou disse que a flecha sai do arco.

		**O numero fica escrito aqui mesmo com o marcador existindo**, e nao em
		`HitTime = 0` para o `Unit:playAttackVisual` escutar a track. Quem cobra o
		dano e o servidor (`UnitService:executeAttack`), que le este campo como
		windup e nao tem `AnimationTrack` nenhuma para escutar: com zero aqui, o dano
		sairia no instante do pedido enquanto o boneco ainda puxa a corda. O ramo do
		marcador la e so um fallback de cliente para unidade sem `HitTime`.

		Ou seja: o marcador e a **fonte** do numero, e este campo e a copia que as
		duas pontas obedecem. Mexeu o marcador, mexe aqui junto.
	]]
	["Archer"] = {
		AttackSequence = {
			{ Animation = "Attack", HitTime = 1.017 },
		},
	},

	--[=[
		Quatro golpes numa animacao so, e nao quatro animacoes: os instantes sao os
		marcadores `Hit` da `Attack` do Berserker (0,4333s, 1,2667s, 2,3833s e
		2,5667s de uma animacao de 2,9s).

		Os intervalos entre eles nao sao nem de longe iguais -- 0,83s, depois 1,12s,
		depois 0,18s --, e e por isso que a unidade nao cabia no `Hits`/`HitInterval`:
		aquilo espaca os acertos de forma regular, e o combate do boneco tem ritmo
		proprio. Os dois ultimos quase se encostam de proposito: e o par rapido que
		fecha o combo. O `Cooldown = 5.9` do `UnitStats` conta a animacao inteira mais
		os 3s de recuperacao, entao o quarto acerto cai bem dentro da janela do golpe.
	]=]
	["Berserker"] = {
		AttackSequence = {
			{ Animation = "Attack", HitTimes = { 0.4333, 1.2667, 2.3833, 2.5667 }, Duration = 2.9 },
		},
	},

	["Sword"] = {
		AttackSequence = {
			{ Animation = "Attack", HitTime = 1 },
		},
	},

	["Slasher"] = {
		AttackSequence = {
			{ Animation = "Slash1", HitTime = 0.1 },
			{ Animation = "Slash2", HitTime = 0.1 },
		},

	},

	["Rocket"] = {
		AttackSequence = {
			{ Animation = "Attack", HitTime = 1.5 },
		},
	},
}

return UnitAttackConfig
