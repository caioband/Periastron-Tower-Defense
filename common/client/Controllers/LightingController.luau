local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")
local Utils = Shared:WaitForChild("Util")

local SharedConfig = require(Configs.SharedConfig)
local LightingUtil = require(Utils.LightingUtil)

local Me = require(Vendor.Me)

local Framework = Me.new()

local Config = SharedConfig.LightingConfig

--[[
	Transição de Lighting, só no cliente.

	O `LightingService` troca o conteúdo do Lighting de uma vez — é o certo para o
	servidor, e é o que quem entra no meio da partida precisa receber. Aqui a troca
	vira transição: no aviso de que o preset mudou, o controller devolve as
	propriedades ao valor do preset anterior e interpola até o novo.

	De onde vem cada ponta:

	- **origem**: `self.applied`, o estado que este controller mesmo escreveu por
	  último. Não é lido do Lighting na hora — quando o aviso chega, o valor novo
	  já pode ter replicado por cima.
	- **destino**: a Folder do preset em `Assets.Lighting`, não a instância viva.
	  Mesma razão: a pasta é estável, a instância viva é o que vai ser sobrescrito.

	O que não interpola (boolean, string, EnumItem, sequences) é aplicado de uma
	vez — ligar entra no começo, desligar espera o fim, para um efeito aparecer
	junto com a transição e sumir depois dela.

	Instância só é interpolada se existir nos dois presets com o mesmo nome e a
	mesma classe. A que só existe no preset novo já chega no valor final pela
	replicação; a que só existia no antigo foi destruída pelo servidor. Na prática:
	usar os mesmos nomes entre presets é o que faz a transição ficar completa.

	Fica em `common/` porque as duas places usam.
]]

-- Quanto tempo esperar as instâncias do preset novo replicarem antes de desistir
-- de interpolá-las.
local CHILD_WAIT = 0.5

local IS_STUDIO = RunService:IsStudio()

local LightingController = {
	Controllers = {},
}

LightingController.currentPreset = nil :: string?

--[[
	Último estado que este controller escreveu:
	`{ Lighting = { prop -> valor }, Children = { nome -> { ClassName, Values } } }`
]]
LightingController.applied = nil :: any

LightingController._generation = 0
LightingController._connection = nil :: RBXScriptConnection?
LightingController._root = nil :: Folder?

-- Plano da transição em andamento, ou nil. Ver `_freeze` e `Skip`.
LightingController._plan = nil :: any

--[[ ESTADO ]]

function LightingController:_readLive()
	local state = {
		Lighting = LightingUtil.ReadInstance(Lighting),
		Children = {},
	}

	-- Nome repetido fica com o primeiro, igual ao que `FindFirstChild` devolve.
	-- Os mapas do jogo trazem dois filhos chamados `Atmosphere`, e as duas pontas
	-- da transição têm que concordar em qual delas estão falando.
	for _, child in Lighting:GetChildren() do
		if state.Children[child.Name] then continue end

		state.Children[child.Name] = {
			ClassName = child.ClassName,
			Values = LightingUtil.ReadInstance(child),
		}
	end

	return state
end

-- Assume o estado atual do Lighting como ponto de partida, sem transição.
function LightingController:_adopt(name: string?)
	self.currentPreset = name
	self.applied = self:_readLive()
end

--[[
	Onde `self.applied` guarda os valores desta instância. Filho é indexado por
	nome: a instância viva pode ter sido destruída e recriada pelo servidor entre
	uma transição e outra.
]]
function LightingController:_bucketFor(instance: Instance)
	if instance == Lighting then
		return self.applied.Lighting
	end

	local child = self.applied.Children[instance.Name]
	return child and child.Values
end

function LightingController:_getPreset(name: string): Folder?
	if not self._root then
		self._root = LightingUtil.GetPresetsRoot(false, 10)
	end

	local root = self._root
	if not root then return nil end

	local preset = root:FindFirstChild(name)
	if not preset or not preset:IsA("Folder") then
		return nil
	end

	return preset
end

--[[ PLANO ]]

--[[
	Compara origem e destino de uma instância e enche o plano:

	- `entries`: interpola quadro a quadro;
	- `immediate`: corte que vale desde já (o valor de origem das interpoláveis
	  entra por aqui também, porque é o que passa a estar escrito);
	- `deferred`: corte que só vale quando a transição acabar.
]]
function LightingController:_collect(instance: Instance, from, to, plan)
	for propertyName, target in to do
		local origin = from[propertyName]
		if origin == nil or origin == target then continue end

		local interpolate = LightingUtil.GetInterpolator(origin, target)

		if interpolate then
			local ok = pcall(function()
				(instance :: any)[propertyName] = origin
			end)

			if ok then
				table.insert(plan.entries, {
					instance = instance,
					property = propertyName,
					from = origin,
					to = target,
					lastValue = origin,
					interpolate = interpolate,
				})
			end
			continue
		end

		-- Corte: desligar espera o fim para o efeito ainda participar da transição;
		-- o resto (ligar, trocar textura) entra logo, senão não haveria o que ver.
		if target == false then
			pcall(function()
				(instance :: any)[propertyName] = origin
			end)
			table.insert(plan.deferred, { instance = instance, property = propertyName, value = target })
		else
			local ok = pcall(function()
				(instance :: any)[propertyName] = target
			end)

			if ok then
				table.insert(plan.immediate, { instance = instance, property = propertyName, value = target })
			end
		end
	end
end

--[[
	Instância viva de cada filho do preset, esperando a replicação chegar.

	Devolve `nil` se a geração ficou velha no meio da espera — outra troca começou
	e este plano não vale mais.
]]
function LightingController:_resolveChildren(preset: Folder, generation: number)
	local deadline = os.clock() + CHILD_WAIT

	while true do
		local resolved, missing = {}, nil
		local taken = {}

		for _, presetChild in preset:GetChildren() do
			-- Mesma regra do `_readLive`: nome repetido no preset fica com o
			-- primeiro, senão dois planos brigariam pela mesma instância viva.
			if taken[presetChild.Name] then continue end

			local live = Lighting:FindFirstChild(presetChild.Name)
			if live and live.ClassName == presetChild.ClassName then
				taken[presetChild.Name] = true
				resolved[presetChild] = live
			else
				missing = presetChild.Name
			end
		end

		if not missing or os.clock() >= deadline then
			if missing and IS_STUDIO then
				print(`[LightingController]: "{missing}" não apareceu no Lighting a tempo; entra sem transição.`)
			end
			return resolved
		end

		RunService.Heartbeat:Wait()

		if generation ~= self._generation then
			return nil
		end
	end
end

--[[ TRANSIÇÃO ]]

function LightingController:_stop()
	if self._connection then
		self._connection:Disconnect()
		self._connection = nil
	end
end

--[[
	Congela a transição em andamento onde ela está.

	Quem chama é a transição seguinte: a origem dela tem que ser o que está na tela
	agora, não o preset de onde a interrompida tinha saído — senão a troca começaria
	com um salto para trás.
]]
function LightingController:_freeze()
	local plan = self._plan
	if not plan then return end

	for _, entry in plan.entries do
		local bucket = self:_bucketFor(entry.instance)
		if bucket then
			bucket[entry.property] = entry.lastValue
		end
	end

	for _, entry in plan.immediate do
		local bucket = self:_bucketFor(entry.instance)
		if bucket then
			bucket[entry.property] = entry.value
		end
	end

	-- Quem estava saindo já tinha sido destruído pelo servidor; o fantasma some
	-- junto, e o registro dele sai do estado para a próxima troca não tentar
	-- despedir a mesma instância de novo.
	for _, ghost in plan.ghosts do
		self.applied.Children[ghost.Name] = nil
		ghost:Destroy()
	end

	self:_stop()
	self._plan = nil
end

--[[
	Fantasma de saída.

	A instância que só existia no preset antigo já foi destruída pelo servidor, então
	não há o que interpolar — a não ser recriar uma cópia local (não replica) com os
	valores de antes e levá-la até o neutro. Sem isto, metade da mudança visual de
	uma troca de mapa é um corte seco.
]]
function LightingController:_fadeOut(name: string, previous, plan)
	local target = Config:GetNeutral(previous.ClassName, previous.Values)
	if target == previous.Values then
		-- Classe sem neutro (Sky): não há meio-caminho, some de uma vez.
		return
	end

	local ok, ghost = pcall(Instance.new, previous.ClassName)
	if not ok or not ghost then return end

	ghost.Name = name
	for propertyName, value in previous.Values do
		pcall(function()
			(ghost :: any)[propertyName] = value
		end)
	end
	ghost.Parent = Lighting
	table.insert(plan.ghosts, ghost)

	self:_collect(ghost, previous.Values, target, plan)
end

function LightingController:_transition(toName: string, duration: number)
	self._generation += 1
	local generation = self._generation
	self:_freeze()

	local preset = self:_getPreset(toName)

	-- Sem preset para ler, sem estado anterior, ou corte pedido: o Lighting já está
	-- no valor final pela replicação, só falta registrar.
	if not preset or not self.applied or duration <= 0 then
		if not preset and IS_STUDIO then
			print(`[LightingController]: preset "{toName}" não está em Assets.Lighting; sem transição.`)
		end
		self:_adopt(toName)
		return
	end

	local plan = { entries = {}, immediate = {}, deferred = {}, ghosts = {} }

	-- O Lighting em si não depende de replicação de instância: volta para o valor
	-- antigo já, para não ficar um quadro com a cara nova.
	local lightingTarget = table.clone(self.applied.Lighting)
	for propertyName, value in LightingUtil.ReadPresetAttributes(preset) do
		lightingTarget[propertyName] = value
	end
	self:_collect(Lighting, self.applied.Lighting, lightingTarget, plan)

	local resolved = self:_resolveChildren(preset, generation)
	if not resolved or generation ~= self._generation then return end

	local targetNames = {}

	for presetChild, live in resolved do
		targetNames[presetChild.Name] = true

		local target = LightingUtil.ReadInstance(presetChild)
		local previous = self.applied.Children[presetChild.Name]

		if previous and previous.ClassName == presetChild.ClassName then
			-- Existe nos dois presets: interpola valor a valor.
			self:_collect(live, previous.Values, target, plan)
		else
			-- Só existe no preset novo. O servidor já a criou no valor final, então
			-- a entrada é começar do neutro e subir até ele.
			self:_collect(live, Config:GetNeutral(presetChild.ClassName, target), target, plan)
		end
	end

	for name, previous in self.applied.Children do
		if not targetNames[name] then
			self:_fadeOut(name, previous, plan)
		end
	end

	self._plan = plan

	local function finish()
		self:_stop()
		self._plan = nil

		for _, entry in plan.entries do
			pcall(function()
				(entry.instance :: any)[entry.property] = entry.to
			end)
		end

		for _, entry in plan.deferred do
			pcall(function()
				(entry.instance :: any)[entry.property] = entry.value
			end)
		end

		-- Antes do `_adopt`: o fantasma não pode entrar no estado como se fosse uma
		-- instância viva do preset novo.
		for _, ghost in plan.ghosts do
			ghost:Destroy()
		end

		self:_adopt(toName)
	end

	plan.finish = finish

	--[[
		Vale logar mesmo quando deu certo: entre dois presets de mapa a diferença
		costuma ser de uma ou duas propriedades, e "interpolou pouco" é
		indistinguível de "não interpolou" olhando a tela.
	]]
	if IS_STUDIO then
		print(string.format('[LightingController]: "%s" -> "%s" em %.4gs | %d propriedade(s) interpolando, %d corte(s) na entrada, %d no fim, %d saída(s) com fantasma',
			self.currentPreset or "?", toName, duration,
			#plan.entries, #plan.immediate, #plan.deferred, #plan.ghosts))
	end

	if #plan.entries == 0 then
		finish()
		return
	end

	local startedAt = os.clock()

	self._connection = RunService.RenderStepped:Connect(function()
		if generation ~= self._generation then
			self:_stop()
			return
		end

		local alpha = (os.clock() - startedAt) / duration
		if alpha >= 1 then
			finish()
			return
		end

		local eased = LightingUtil.Ease(alpha)
		for _, entry in plan.entries do
			local value = entry.interpolate(entry.from, entry.to, eased)
			entry.lastValue = value;
			(entry.instance :: any)[entry.property] = value
		end
	end)
end

--[[ API ]]

function LightingController:GetCurrent(): string?
	return self.currentPreset
end

-- Corta a transição em andamento e deixa tudo no valor final.
function LightingController:Skip()
	local plan = self._plan
	if plan and plan.finish then
		plan.finish()
	end
end

--[[ CICLO DE VIDA ]]

function LightingController:construct()
	Framework:Listen("LightingApplied", function(_previous, name, duration)
		if typeof(name) ~= "string" then return end

		-- `_transition` espera a replicação dos filhos, então cede a thread; sai da
		-- callback da rede para não segurar os outros eventos.
		task.spawn(function()
			self:_transition(name, tonumber(duration) or Config.Transition.Time)
		end)
	end)

	-- Com que preset este cliente começa. O Lighting dele já chegou replicado no
	-- estado certo; isto é só para a próxima troca ter de onde sair.
	Framework:Fire("RequestLighting")
end

function LightingController:start() end

function LightingController:init()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller)
	end

	-- Se a resposta do servidor demorar, o estado autorado da place já serve de
	-- origem — melhor que a primeira troca sair sem transição.
	self:_adopt(nil)
	self:construct()
end

return LightingController
