local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Assets = Shared:WaitForChild("Assets")

local GameClock = require(Shared:WaitForChild("Util"):WaitForChild("GameClock"))

local Me = require(Vendor.Me)
local Framework = Me.new()

-- Usado so quando o servidor nao mandar a duracao (versao antiga do evento).
local THROW_DURATION = 0.35
local THROW_HEIGHT = 4

--[[
	Quanto o modelo estourado fica no mapa antes de sumir.

	Tempo real de proposito, e o unico do arquivo: o que resta na tela sao
	`ParticleEmitter`s, e particula nao anda no relogio da partida -- acelerar a
	limpeza deles cortaria a fumaca pela metade no 3x.
]]
local EXPLOSION_LIFETIME = 5

local TripmineController = {
	Controllers = {
		UnitPlacementController = {},
		MusicController = {}
	},
	Mines = {},
	MinesByUnit = {},

	--[[
		Os arremessos em andamento: `[mineId] = { conn, endCF }`. Uma entrada so
		existe enquanto a mina esta no ar.
	]]
	Arcs = {},
}

--[=[
	Encerra o arremesso de uma mina, se ele ainda estiver correndo, e poe o modelo
	no lugar de descanso dela.

	Existe por causa da corrida entre o voo e a explosao. O servidor arma a mina
	quando ela pousa e o cliente gasta o mesmo `throwTime` desenhando o arco, entao
	no caso normal o voo ja acabou quando o `TripmineTriggered` chega. Mas os dois
	relogios nao viram ao mesmo tempo: trocar a velocidade da partida com uma mina
	no ar so chega neste cliente uma viagem de rede depois, e nesse intervalo o arco
	dele anda mais devagar que o cronometro do servidor.

	Sem isto, a explosao dessa mina sairia **no meio do ar**, no ponto onde o arco
	estivesse -- e as particulas ficam onde foram emitidas. Acertar a posicao antes
	de emitir custa uma linha e tira a rede da conta.
]=]
function TripmineController:endArc(mineId, snap : boolean?)
	local arc = self.Arcs[mineId]
	if not arc then return end

	self.Arcs[mineId] = nil

	if arc.conn.Connected then
		arc.conn:Disconnect()
	end

	if snap then
		local mine = self.Mines[mineId]
		if mine and mine.Parent then
			mine:PivotTo(arc.endCF)
		end
	end
end

function TripmineController:getTemplate()
	if not self.template then
		local vfxFolder = Assets:FindFirstChild("VFX")
		self.template = vfxFolder and vfxFolder:FindFirstChild("SubspaceTripmine")
	end
	return self.template
end

function TripmineController:getUnitModel(unitId)
	local placement = self.Controllers.UnitPlacementController
	local class = placement and placement.classesById and placement.classesById[unitId]
	return class and class.model or nil
end

function TripmineController:playTriggerSound(parent)
	-- A Key faz o papel do ActiveSound antigo: só uma mina soando por vez.
	self.Controllers.MusicController:PlaySFX("SubspaceTripmineSFX", {
		Parent = parent,
		Key = "SubspaceTripmine",
	})
end

--[=[
	O arco da mina, do arremesso ate o chao.

	O relogio e o da **partida**, e nao `os.clock()`: o servidor arma a mina
	`throwTime` de tempo de partida depois de solta-la, e este voo tem que terminar
	no mesmo instante. Com o relogio de tela, no 3x o windup e a animacao do
	arremesso encolhiam para um terco enquanto a mina continuava levando os mesmos
	0,35s reais no ar -- ela ficava boiando enquanto o resto da partida corria, e
	o gatilho ligava com o modelo ainda a caminho.

	Ler o relogio a cada quadro (em vez de converter para segundos reais na
	chamada) e o que faz a troca de velocidade **no meio do voo** valer: acelerar a
	partida com uma mina no ar encurta o que falta dela, do mesmo jeito que o
	`GameClock.Wait` faz do lado do servidor.
]=]
function TripmineController:throwMine(mineId, mineModel, startCF, endCF, throwTime)
	mineModel:PivotTo(startCF)

	local duration = math.max(throwTime or THROW_DURATION, 1e-3)
	local startedAt = GameClock.Now()
	local spin = math.random() * math.pi * 2

	local conn
	conn = RunService.RenderStepped:Connect(function()
		if not mineModel.Parent then
			self:endArc(mineId)
			return
		end
		local alpha = math.min(1, (GameClock.Now() - startedAt) / duration)
		local height = math.sin(alpha * math.pi) * THROW_HEIGHT
		local cf = startCF:Lerp(endCF, alpha) + Vector3.new(0, height, 0)
		mineModel:PivotTo(cf * CFrame.Angles(spin * alpha, 0, 0))
		if alpha >= 1 then
			self:endArc(mineId)
			mineModel:PivotTo(endCF)
		end
	end)

	self.Arcs[mineId] = { conn = conn, endCF = endCF }
end

function TripmineController:spawnMine(unitId, mineId, mineCF, throwTime)
	local template = self:getTemplate()
	if not template then return end

	local mine = template:Clone()
	mine.Name = "SubspaceTripmine_" .. mineId
	mine.Parent = workspace.CurrentCamera

	self.Mines[mineId] = mine
	self.MinesByUnit[unitId] = self.MinesByUnit[unitId] or {}
	self.MinesByUnit[unitId][mineId] = true

	local unitModel = self:getUnitModel(unitId)
	local startCF = mineCF
	if unitModel and unitModel.Parent then
		startCF = CFrame.new(unitModel:GetPivot().Position + Vector3.new(0, 2, 0))
	end

	self:throwMine(mineId, mine, startCF, mineCF, throwTime)
end

function TripmineController:triggerMine(unitId, mineId)
	-- A mina explode no chao, e nao onde o arco estiver: se ele ainda corria, ele
	-- termina aqui e o modelo vai para o lugar de descanso antes de emitir.
	self:endArc(mineId, true)

	local mine = self.Mines[mineId]
	self.Mines[mineId] = nil
	if self.MinesByUnit[unitId] then
		self.MinesByUnit[unitId][mineId] = nil
	end
	if not mine or not mine.Parent then return end

	local root = mine.PrimaryPart or mine:FindFirstChildWhichIsA("BasePart")
	if root then
		for _, descendant in mine:GetDescendants() do
			if descendant:IsA("ParticleEmitter") then
				descendant:Emit(descendant:GetAttribute("EmitCount") or 15)
			elseif descendant:IsA("BasePart") then
				descendant.Transparency = 1
			end
		end
		if root:IsA("BasePart") then
			root.Transparency = 1
		end
		self:playTriggerSound(root)
	end

	task.delay(EXPLOSION_LIFETIME, function()
		if mine and mine.Parent then
			mine:Destroy()
		end
	end)
end

function TripmineController:clearUnitMines(unitId)
	local mines = self.MinesByUnit[unitId]
	if not mines then return end
	for mineId in mines do
		-- Sem `snap`: o modelo esta indo embora, nao ha lugar de descanso para ele.
		self:endArc(mineId)

		local mine = self.Mines[mineId]
		self.Mines[mineId] = nil
		if mine and mine.Parent then
			mine:Destroy()
		end
	end
	self.MinesByUnit[unitId] = nil
end

function TripmineController:construct()
	Framework:Listen("TripmineThrown", function(unitId, mineId, mineCF, throwTime)
		self:spawnMine(unitId, mineId, mineCF, throwTime)
	end)

	Framework:Listen("TripmineTriggered", function(unitId, mineId)
		self:triggerMine(unitId, mineId)
	end)

	Framework:Listen("RemoveUnit", function(unitId)
		self:clearUnitMines(unitId)
	end)
end

function TripmineController:start()
end

function TripmineController:init()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end
	self:construct()
end

return TripmineController
