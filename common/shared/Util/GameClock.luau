local RunService = game:GetService("RunService")

--[[
	O relogio da partida: o mesmo `os.clock()` de sempre, so que andando na
	velocidade que o jogador escolheu no botao `Interface.Speed`.

	A ideia e nao ter uma regra de "x2" espalhada por cada duracao do jogo. Todo o
	gameplay ja comparava instantes contra `os.clock()` -- `StunnedUntil`,
	`lastAttack`, `expiresAt` da carga --, entao basta trocar a fonte do "agora"
	por uma que corre mais rapido para que cooldown, atordoamento, buff e cadencia
	de spawn encolham juntos, sem tocar em nenhum numero de config.

	**O relogio comeca em `os.clock()`, de proposito.** Muito codigo faz
	`now - (entry.lastAttack or 0)`, contando com um numero grande de um lado e
	zero do outro para dizer "nunca atacou, pode atacar ja". Um relogio comecando
	em zero faria a unidade recem-colocada esperar o primeiro cooldown a mais.

	**Cada maquina tem o seu.** O servidor e cada cliente carregam uma copia deste
	modulo, e o `SpeedService` mantem as escalas iguais avisando todo mundo a cada
	troca. E por isso que o cliente tambem precisa dele: quem move o modelo do mob
	na tela e o `MobController`, e ele tem que andar no mesmo ritmo da distancia
	que o servidor esta somando.

	**O que NAO passa por aqui.** O que e tempo de tela, e nao de partida: o
	intervalo antes da wave (que tem o proprio botao de Ready), as setas do
	caminho, o tempo de VFX e as telas de resultado. Acelerar aquilo nao e
	acelerar a partida, e so tirar do jogador o tempo de ler.
]]

local GameClock = {}

-- Menor escala aceita. `Wait` espera o relogio passar de um instante; com escala
-- zero esse instante nunca chega e a espera vira um travamento.
local MIN_SCALE = 0.01

local scale = 1
local now = os.clock()

RunService.Heartbeat:Connect(function(dt : number)
	now += dt * scale
end)

--[[ API ]]

--- O "agora" da partida, no lugar de `os.clock()`.
function GameClock.Now() : number
	return now
end

function GameClock.GetScale() : number
	return scale
end

function GameClock.SetScale(newScale : number?)
	scale = math.max(MIN_SCALE, newScale or 1)
end

--- O `dt` de um Heartbeat convertido para tempo de partida.
function GameClock.Scaled(dt : number) : number
	return dt * scale
end

--[=[
	`task.wait`, em tempo de partida.

	A espera e refeita a cada quadro contra o relogio, e nao convertida para
	segundos reais na chamada: trocar a velocidade no meio de uma espera de 3s
	encurta o que falta dela, em vez de so valer da proxima em diante.

	Cede pelo menos um quadro, como o `task.wait()`.
]=]
function GameClock.Wait(duration : number?) : number
	local deadline = now + (duration or 0)

	repeat
		RunService.Heartbeat:Wait()
	until now >= deadline

	return now
end

--- `task.delay`, em tempo de partida.
function GameClock.Delay(duration : number?, callback : () -> ()) : thread
	return task.spawn(function()
		GameClock.Wait(duration)
		callback()
	end)
end

return GameClock
