local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)
local GameClock = require(Shared:WaitForChild("Util"):WaitForChild("GameClock"))
local Me = require(Vendor.Me)
local Framework = Me.new()

local ROTATION_SPEED = 8
local NO_TARGET_RESET_DELAY = 1.5

local Unit = {}
Unit.__index = Unit

function Unit:createAOE()
end

function Unit:loadAnimations()
	self.loadedAnimations = {}

	local animationController = self.model:FindFirstChildWhichIsA("AnimationController") or Instance.new("AnimationController")
	animationController.Parent = self.model

	local animator = animationController:FindFirstChildWhichIsA("Animator") or Instance.new("Animator", animationController)

	for _, animation : Animation in self.model:GetChildren() do
		if not animation:IsA("Animation") then continue end

		local track = animator:LoadAnimation(animation)

		--[=[
			A `Idle` desce para `Movement`, qualquer que seja a prioridade com que ela
			foi exportada.

			Ela e a **pose de base**: toca em laco a partida inteira e tudo o mais e um
			gesto por cima dela. Duas tracks na mesma prioridade nao se substituem --
			elas se misturam por peso --, entao uma unidade com a `Idle` e a `Attack`
			as duas em `Action` bate com meio golpe e meia pose parada. O Berserker e o
			Archer sao exportados assim; o Sword e o Subspace Tripminer, que ja vem com
			a `Idle` em `Movement`, sao o comportamento certo que os outros copiam
			daqui.

			A regra e so rebaixar a `Idle`, e nao promover o golpe: assim a prioridade
			que quem animou escreveu em cada gesto continua valendo entre eles (a
			`MoneyWave` do Entrepreneur, o `Slash2` do Slasher), e nao ha um segundo
			lugar onde a arte da unidade e decidida.
		]=]
		if animation.Name == "Idle" then
			track.Priority = Enum.AnimationPriority.Movement

			-- A pose de base toca a partida inteira, entao ela e sempre em laco --
			-- mesmo exportada sem o `Loop` ligado, como a do Archmage veio.
			track.Looped = true
		end

		self.loadedAnimations[animation.Name] = track
	end
end

--[=[
	Poe as animacoes da unidade na velocidade da partida.

	O `GameClock` acelera as esperas, e nao as `AnimationTrack`. Sem esta varredura
	duas coisas ficam para tras da escala: a `Idle`, que e tocada uma unica vez no
	`Unit.new` e nunca mais e tocada por ninguem -- ela passaria a partida inteira
	no 1x --, e o golpe que ja estava no ar quando o jogador trocou de degrau, que
	continuaria no ritmo antigo enquanto o `GameClock.Wait` do windup ja encolheu.

	A varredura e a lista toda de proposito, e nao so a track do golpe: a
	`MoneyWave` do Entrepreneur corre no mesmo tempo de partida que a wave que a
	pagou.

	`AdjustSpeed` numa track parada e inofensivo -- a velocidade fica guardada e
	vale quando ela tocar --, entao nao ha o que filtrar aqui.

	O `animationSpeeds` entra como **produto**, e nao como substituto: a track do
	golpe pode ja estar comprimida para caber no cooldown (ver o
	`playAttackVisual`), e escrever so a escala da partida por cima apagaria a
	compressao na primeira troca de degrau.

	O par disto do lado dos mobs e o `MobController:applyTimeScale`.
]=]
function Unit:applyTimeScale(scale : number)
	self.timeScale = scale

	if not self.loadedAnimations then return end

	for name, track in self.loadedAnimations do
		track:AdjustSpeed(scale * (self.animationSpeeds[name] or 1))
	end
end

function Unit:playSound(soundName, cutAfter)
	if not self.model then return nil end
	local soundsFolder = self.model:FindFirstChild("Sounds")
	if not soundsFolder then return nil end
	local template = soundsFolder:FindFirstChild(soundName)
	if not template or not template:IsA("Sound") then return nil end

	local parent = self.model.PrimaryPart or self.model:FindFirstChildWhichIsA("BasePart")
	if not parent then return nil end

	local sound = template:Clone()
	sound.Parent = parent
	sound:Play()

	if cutAfter then
		task.delay(cutAfter, function()
			if sound and sound.Parent then
				sound:Stop()
				sound:Destroy()
			end
		end)
	else
		sound.Ended:Once(function()
			if sound and sound.Parent then sound:Destroy() end
		end)
		task.delay(15, function()
			if sound and sound.Parent then sound:Destroy() end
		end)
	end

	return sound
end

--[=[
	De onde o projetil sai: o `RootPart` da unidade.

	Era o pivo do modelo **mais dois studs**, e os dois studs eram o problema. As
	unidades tem pouco mais de dois studs de altura inteira (o `HumanoidRootPart`
	fica no meio do torso, a cerca de um stud do chao), entao somar dois punha a
	flecha nascendo acima da cabeca do boneco, no ar. Some do pivo do modelo por
	seguranca tambem: `GetPivot` responde pelo `WorldPivot`, que so coincide com o
	root enquanto o `PrimaryPart` estiver certo -- e um modelo que perca o
	`PrimaryPart` passa a responder pelo centro da caixa delimitadora, que muda de
	altura conforme a pose da animacao.

	Nao ha offset nenhum aqui de proposito: o lugar de nascer mais alto (na ponta do
	arco, na boca do cano) e uma peca no modelo, e nao um numero somado no codigo
	que vale para todas as unidades ao mesmo tempo.
]=]
function Unit:projectileOrigin() : Vector3?
	local model = self.model
	if not model or not model.Parent then return nil end

	local root = model.PrimaryPart or model:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		root = model:FindFirstChildWhichIsA("BasePart")
	end

	return if root then root.Position else model:GetPivot().Position
end

function Unit:playAttackVisual(target : Model?, stepIndex : number?, swingWindow : number?)
	if not self.model or not self.model.Parent then return end

	local sequence = self.attackConfig and self.attackConfig.AttackSequence
	local step = nil
	if sequence and #sequence > 0 then
		if stepIndex and sequence[stepIndex] then
			self.attackSequenceIndex = stepIndex
		else
			self.attackSequenceIndex = ((self.attackSequenceIndex or 0) % #sequence) + 1
		end
		step = sequence[self.attackSequenceIndex]
	end

	local animName = step and step.Animation or "Attack"
	local hitTime = step and step.HitTime or 0

	-- O golpe que acerta varias vezes dentro da mesma animacao, cada acerto no seu
	-- instante. Ver o `HitTimes` no `UnitAttackConfig`.
	local hitTimes = step and step.HitTimes

	local track = self.loadedAnimations[animName]
	if track and sequence then
		for _, otherStep in sequence do
			local otherTrack = self.loadedAnimations[otherStep.Animation]
			if otherTrack and otherTrack ~= track and otherTrack.IsPlaying then
				otherTrack:Stop(0.1)
			end
		end
	end

	--[[
		A velocidade da partida entra na animacao e nas esperas daqui.

		Quem decide quando o dano sai e o servidor (`UnitService:executeAttack`), e
		la o windup e o intervalo entre golpes ja correm no relogio acelerado. Este
		lado desenha o mesmo ataque: sem a escala, no 2x a torre bateria duas vezes
		enquanto o boneco ainda termina o primeiro golpe.

		Na Lobby a escala e sempre 1 -- nao existe `SpeedService` la --, entao isto
		nao muda nada para as unidades do menu.

		A escala e lida de novo aqui, e nao herdada do `self.timeScale`, porque uma
		track recem-tocada volta ao 1x: o `applyTimeScale` so reage a *mudanca* de
		escala, e nao veria um golpe que comecou com a escala parada. Por isso o
		`AdjustSpeed` explicito la embaixo, mesmo com a varredura por quadro ligada.

		E quando a leitura daqui chega antes da do quadro, quem responde e a
		varredura inteira, e nao so a track do golpe: adiantar o `self.timeScale`
		sozinho calaria a comparacao do `RenderStepped` e deixaria a `Idle` e a
		`MoneyWave` presas na escala velha para sempre.
	]]
	local timeScale = GameClock.GetScale()
	if timeScale ~= self.timeScale then
		self:applyTimeScale(timeScale)
	end

	--[=[
		A animacao cabe dentro do golpe.

		Uma animacao mais longa que o cooldown e o que tirava o boneco do lugar: o
		pedido seguinte chegava com a track ainda no ar, o `Play` daqui nao
		reiniciava o que ja estava tocando, e o golpe saia sem gesto nenhum -- um
		tiro com animacao, o proximo sem, alternando. O Rocket e o caso mais visivel
		(2,667s de animacao para 2,5s de cooldown), e o Azure, o Archer e o `Slash1`
		do Slasher estao na mesma situacao.

		A saida nao e encurtar a animacao no arquivo nem mexer no `Cooldown` -- que e
		numero de balanceamento e nao de arte --, e sim **tocar a animacao mais
		rapido** exatamente o tanto que falta para ela caber. O gesto inteiro
		aparece, so que espremido no tempo que a unidade tem.

		A janela vem do servidor ja com clima, upgrade, carta e carga dentro, e nao
		do `stats.Cooldown` daqui: uma carta de `AttackSpeed` encurta o cooldown, e a
		animacao tem que encurtar junto ou a dessincronizacao volta com a carta em
		campo. Sem a janela (uma unidade que ainda nao recebeu o campo), o fator e 1
		e o comportamento e o de antes.

		`track.Length` e zero enquanto a animacao nao terminou de carregar; a
		comparacao com a janela ja recusa esse caso sozinha.
	]=]
	local fit = 1
	if track and swingWindow and swingWindow > 0 and track.Length > swingWindow then
		fit = track.Length / swingWindow
	end

	if track then
		self.animationSpeeds[animName] = fit
	end

	--[[
		O golpe reinicia a track mesmo com ela tocando.

		Com a compressao acima a sobra e de milissegundos -- o suficiente para o
		pedido seguinte chegar antes de a track fechar, por jitter de rede, e o
		gesto ser pulado de novo. Reiniciar fecha essa fresta, e para quem ja cabia
		no cooldown (Sword, Slingshot, Subspace Tripminer) nao muda nada: a track ja
		tinha terminado quando o pedido chega.

		Como todo golpe passou a ser um golpe novo, o `SwingSound` volta a tocar em
		todos eles -- antes o Azure perdia o som do Periastron um tiro sim, um nao,
		pelo mesmo motivo que perdia o gesto.

		Quem volta o gesto para o comeco e o `TimePosition`, e nao um `Play`: `Play`
		numa track que ja esta tocando nao faz nada. Tambem nao e um `Stop(0)`
		seguido de `Play`, como no `playFarmVisual` -- aquilo tira a track do ar por
		um instante e o boneco pisca para a `Idle` antes de voltar.
	]]
	if track then
		if track.IsPlaying then
			track.TimePosition = 0
		else
			track:Play()
		end

		track:AdjustSpeed(timeScale * fit)
	end

	if step and step.SwingSound then
		self:playSound(step.SwingSound)
	end

	local lastTargetPos = (target and target.Parent) and target:GetPivot().Position or nil

	local function fireHit()
		if not self.model or not self.model.Parent then return end
		self:playSound("Lunge")
		local projController = Framework:Get("ProjectileController")
		local stats = self.stats
		local liveTarget = (target and target.Parent) and target or nil
		if liveTarget then
			lastTargetPos = liveTarget:GetPivot().Position
		end
		if projController and stats and stats.Projectile then
			if not liveTarget and not lastTargetPos then return end
			local startPos = self:projectileOrigin()
			if not startPos then return end
			local launchSound = self:playSound("Launch")
			self:playSound("Shot", 2)
			projController:Fire(startPos, liveTarget, stats.Projectile, function(impactPos)
				if launchSound and launchSound.Parent then
					launchSound:Stop()
					launchSound:Destroy()
				end
				local vfx = Framework:Get("VFXController")
				if vfx then
					vfx:Trigger(self.name, "OnAttack", { unitModel = self.model, mobModel = liveTarget, position = impactPos })
				end
			end, lastTargetPos)
		elseif liveTarget then
			local vfx = Framework:Get("VFXController")
			if vfx then
				vfx:Trigger(self.name, "OnAttack", { unitModel = self.model, mobModel = liveTarget })
			end
		end
	end

	local function scheduleHits()
		local totalHits = self.stats.Hits or 1
		local interval = self.stats.HitInterval or 0
		fireHit()
		for i = 2, totalHits do
			GameClock.Delay(interval * (i - 1), fireHit)
		end
	end

	if hitTimes then
		--[[
			Um `fireHit` por instante da lista, e nao o `scheduleHits`: os acertos
			deste golpe tem tempos proprios, e nao o espacamento regular do
			`HitInterval`. Quem conta e a lista, e nao o `stats.Hits` -- os dois tem
			que continuar iguais, mas quem manda aqui e a coreografia da animacao.

			Os instantes sao divididos pelo `fit` pelo mesmo motivo que a track e
			tocada multiplicada por ele: com a animacao espremida para caber na janela
			do golpe, o marcador `Hit` chega antes, e o acerto tem que chegar junto. O
			servidor divide pelo mesmo fator (`UnitService:executeAttack`), a partir do
			`Duration` do config -- que e a copia do `track.Length` lido aqui.
		]]
		for _, at in ipairs(hitTimes) do
			GameClock.Delay(at / fit, fireHit)
		end
	elseif hitTime > 0 then
		GameClock.Delay(hitTime, scheduleHits)
	elseif track then
		local fired = false
		local function once()
			if fired then return end
			fired = true
			scheduleHits()
		end
		local markerConn
		markerConn = track:GetMarkerReachedSignal("Hit"):Connect(function()
			markerConn:Disconnect()
			once()
		end)
		local safetyDelay = track.Length > 0 and track.Length or (self.stats.Cooldown or 3)
		GameClock.Delay(safetyDelay, function()
			markerConn:Disconnect()
			once()
		end)
	else
		scheduleHits()
	end
end

function Unit:playFarmVisual()
	if not self.model or not self.model.Parent then return end
	if not self.loadedAnimations then return end
	local track = self.loadedAnimations.MoneyWave or self.loadedAnimations.Money or self.loadedAnimations.money
	if not track then return end
	if track.IsPlaying then
		track:Stop(0)
	end
	track:Play()
	track:AdjustSpeed(self.timeScale)
end

function Unit:setCF()
	local mob = self.target :: Model
	local currentPosition = self.defaultCF.Position + Vector3.new(0, self.heightOffset or 0, 0)

	if mob and mob.Parent then
		self.noTargetSince = nil
		local cf = mob:GetPivot()
		local lookTarget = Vector3.new(cf.Position.X, currentPosition.Y, cf.Position.Z)
		self.targetLookCF = CFrame.lookAt(currentPosition, lookTarget)
	else
		if not self.noTargetSince then
			self.noTargetSince = os.clock()
		end
		if os.clock() - self.noTargetSince >= NO_TARGET_RESET_DELAY then
			self.targetLookCF = CFrame.new(currentPosition) * self.defaultCF.Rotation
		end
	end
end

function Unit:setTarget(mob : Model)
	self.target = mob
	self:setCF()
end

function Unit:findTargets()
end

function Unit.new(name : string, model : Model)
	local self = setmetatable({}, Unit)
	self.name = name
	self.unitId = model:GetAttribute("UnitID")
	self.isOwner = false
	self.model = model
	self.defaultCF = model:GetPivot()
	self.heightOffset = 0
	self.attackSequenceIndex = 0
	self.targetLookCF = model:GetPivot()
	self.noTargetSince = nil
	self.timeScale = GameClock.GetScale()

	-- Velocidade propria de cada track, por nome, multiplicada pela escala da
	-- partida no `applyTimeScale`. Hoje so a do golpe sai de 1 (ver o
	-- `playAttackVisual`).
	self.animationSpeeds = {}

	self.parameters = {
		availableToAttack = true,
	}

	self.stats = SharedConfig.UnitStats[name] or {
		Damage = 10,
		Range = 10,
		Cooldown = 1,
		AttackType = "Single"
	}

	self.attackConfig = SharedConfig.UnitAttackConfig and SharedConfig.UnitAttackConfig[name]

	self:loadAnimations()
	self.loadedAnimations.Idle:Play()

	-- Uma unidade colocada com a partida ja no 2x nasce no ritmo certo, sem esperar
	-- a proxima troca de degrau para ser varrida.
	self:applyTimeScale(self.timeScale)

	self.rotationConn = RunService.RenderStepped:Connect(function(dt)
		if not self.model or not self.model.Parent then return end

		--[[
			A escala e lida a cada quadro em vez de empurrada pelo `SpeedController`:
			e uma comparacao, e em troca a unidade nao depende da ordem em que os
			controllers ligam nem de quem avisou quem. Mesmo arranjo do
			`MobController:startMovementLoop`, e pelo mesmo motivo.
		]]
		local scale = GameClock.GetScale()
		if scale ~= self.timeScale then
			self:applyTimeScale(scale)
		end

		local currentCF = self.model:GetPivot()
		local smoothed = currentCF:Lerp(self.targetLookCF, math.min(1, dt * ROTATION_SPEED))
		self.model:PivotTo(smoothed)
	end)

	return self
end

function Unit:Destroy()
	if self.rotationConn then
		self.rotationConn:Disconnect()
		self.rotationConn = nil
	end
	if self.loadedAnimations then
		for _, track in self.loadedAnimations do
			if track then
				track:Stop()
				track:Destroy()
			end
		end
		self.loadedAnimations = nil
	end
	self.target = nil
	self.model = nil
end

return Unit
