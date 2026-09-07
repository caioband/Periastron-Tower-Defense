local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Configs = Shared:WaitForChild("Config")

local Maid = require(Vendor.Maid)
local Me = require(Vendor.Me)

local SharedConfig = require(Configs.SharedConfig)
local ShopConfig = SharedConfig.ShopConfig

local Framework = Me.new()

--[[ CONSTANTS ]]

--[=[
	Os quatro momentos da visita, na ordem em que eles acontecem.

	`GREETING` e `LEAVING` sao gestos com fim -- eles tocam uma vez e caem sozinhos no
	estado de descanso seguinte. `AWAY` e `ATTENDING` sao as duas poses em que o
	vendedor fica parado esperando alguma coisa, e por isso sao as unicas em loop.
]=]
local AWAY = "Away"
local GREETING = "Greeting"
local ATTENDING = "Attending"
local LEAVING = "Leaving"

--[=[
	O vendedor da loja da lobby: ele descansa sozinho, levanta quando ve o jogador
	chegando, atende no balcao e se despede -- bem ou mal, conforme o jogador tenha
	levado alguma coisa.

	**Ele mede a distancia contra o `ShopPartReference`, e nao contra o proprio
	corpo.** E o mesmo centro que o `ShopController` usa para abrir a loja, so que num
	raio maior (`KEEPER_APPROACH_RADIUS` contra `OPEN_RADIUS`). Dois raios
	concentricos garantem a ordem da cena: nao existe chegar ao balcao sem ter cruzado
	o raio de fora antes, entao a loja nunca abre com o vendedor ainda sentado.

	Tudo aqui e **cliente**. O modelo e do servidor e esta ancorado, entao tocar as
	animacoes daqui as mantem locais: cada jogador ve o vendedor atendendo a ele
	proprio, em vez de ver o vendedor levantar porque um estranho do outro lado da
	lobby passou perto.

	O `ShopController` nao sabe que este controller existe. A conversa e de mao unica,
	pelo `PurchaseResult` dele.
]=]
local ShopKeeperController = {
	Controllers = {
		ShopController = {},
	},
}

--[[ INTERNAL ]]

--[=[
	O modelo do vendedor, cacheado ate ele sair do mundo.

	Procurado em profundidade sob o mapa pelo mesmo motivo que os marcadores da loja
	(ver `ShopController:_getMapPart`): quem agrupa o modelo e o artista, e o codigo
	so tem o nome dele. Sair do mundo joga fora os tracks junto -- eles pertencem ao
	`Animator` daquele modelo, e o do mapa seguinte e outro.
]=]
function ShopKeeperController:_getModel() : Model?
	local cached = self.Model
	if cached and cached.Parent then
		return cached
	end

	if cached then
		self.Tracks = {}
		self.CurrentTrack = nil
	end

	local map = workspace:FindFirstChild(ShopConfig.REFERENCE_PARENT_NAME)
	local model = map and map:FindFirstChild(ShopConfig.KEEPER_MODEL_NAME, true)

	if model and not model:IsA("Model") then
		model = nil
	end

	if not model then
		if not self.WarnedMissing then
			self.WarnedMissing = true
			warn(`[ShopKeeperController]: no {ShopConfig.KEEPER_MODEL_NAME} under Workspace.{ShopConfig.REFERENCE_PARENT_NAME}.`)
		end

		self.Model = nil
		return nil
	end

	self.Model = model
	return model
end

--[=[
	O `AnimationTrack` de uma das animacoes do vendedor, carregado na primeira vez que
	ele precisa dela.

	Ele nao tem `Humanoid`: quem carrega e o `Animator` do `AnimationController`
	autorado no modelo. Uma animacao que nao esta la avisa uma vez e devolve nil, e a
	maquina de estados segue sem o gesto em vez de parar a visita inteira.
]=]
function ShopKeeperController:_getTrack(animationName : string) : AnimationTrack?
	local track = self.Tracks[animationName]
	if track then
		return track
	end

	local model = self:_getModel()
	if not model then
		return nil
	end

	local animator = model:FindFirstChildWhichIsA("Animator", true)
	local animation = model:FindFirstChild(animationName)

	if not animator or not animation or not animation:IsA("Animation") then
		if not self.WarnedTracks[animationName] then
			self.WarnedTracks[animationName] = true
			warn(`[ShopKeeperController]: no {animationName} (or no Animator) under {model:GetFullName()}.`)
		end

		return nil
	end

	track = animator:LoadAnimation(animation)
	self.Tracks[animationName] = track

	return track
end

--[=[
	Troca a animacao que esta tocando pela desta, com crossfade.

	O track anterior e parado na mao: sem `Humanoid` nao ha ninguem resolvendo
	prioridade por cima, entao dois tracks tocando ao mesmo tempo somariam as duas
	poses num vendedor torto.
]=]
function ShopKeeperController:_play(animationName : string, looped : boolean) : AnimationTrack?
	local track = self:_getTrack(animationName)
	if not track then
		return nil
	end

	local fade = ShopConfig.KEEPER_FADE_TIME

	if self.CurrentTrack and self.CurrentTrack ~= track then
		self.CurrentTrack:Stop(fade)
	end

	track.Looped = looped
	track:Play(fade)

	self.CurrentTrack = track
	return track
end

--[=[
	Toca um gesto uma vez e, quando ele acaba, entra no estado de descanso seguinte.

	O encadeamento vive no `ChainMaid`, que o `_setState` limpa antes de qualquer
	troca. E o que impede o jogador que vai embora no meio do `GetUp` de ver o
	vendedor sentar no balcao um segundo depois de ja ter se despedido dele: o
	`Stopped` do gesto abandonado morre junto com o estado que o pediu.

	Sem o track (animacao faltando no modelo), o estado seguinte entra na hora -- o
	vendedor perde o gesto, mas nao trava no meio da visita.
]=]
function ShopKeeperController:_playThen(animationName : string, nextState : string)
	local track = self:_play(animationName, false)

	if not track then
		self:_setState(nextState)
		return
	end

	local finished = false

	local function advance()
		if finished then
			return
		end

		finished = true
		self:_setState(nextState)
	end

	self.ChainMaid:GiveTask(track.Stopped:Connect(advance))

	--[[
		O `Stopped` manda no ritmo; o teto so existe para o caso de ele nunca chegar,
		que e o que acontece com um `Animation` cujo asset nao carregou -- ele nao toca,
		nao para, e o vendedor ficaria parado no meio do gesto para sempre.

		A thread nao e cancelada, so desarmada: `task.cancel` numa que ja terminou
		reclama, e um `advance` que nao faz nada custa menos que o pcall em volta.
	]]
	task.delay(ShopConfig.KEEPER_GESTURE_TIMEOUT, advance)

	self.ChainMaid:GiveTask(function()
		finished = true
	end)
end

--[=[
	A unica porta de entrada da maquina de estados.
]=]
function ShopKeeperController:_setState(state : string)
	if state == self.State then
		return
	end

	self.State = state
	self.ChainMaid:DoCleaning()

	if state == AWAY then
		self:_play(ShopConfig.KEEPER_IDLE_ANIMATION, true)
	elseif state == GREETING then
		self:_playThen(ShopConfig.KEEPER_GET_UP_ANIMATION, ATTENDING)
	elseif state == ATTENDING then
		self:_play(ShopConfig.KEEPER_ATTEND_ANIMATION, true)
	elseif state == LEAVING then
		--[[
			A despedida sai do que a visita rendeu, e a visita e o que aconteceu desde
			que o jogador cruzou o raio -- nao a sessao inteira. Quem comprou ontem e
			voltou hoje so para olhar leva o `ByeByeEvil` igual.
		]]
		local farewell = self.Sold
			and ShopConfig.KEEPER_FAREWELL_SOLD_ANIMATION
			or ShopConfig.KEEPER_FAREWELL_EMPTY_ANIMATION

		self:_playThen(farewell, AWAY)
	end
end

--[=[
	Garante que a pose de descanso esta mesmo tocando.

	O `_setState` pede a pose uma vez so, e ela e a coisa certa a fazer para um gesto
	-- mas um modelo que ainda nao carregou no boot faria essa unica tentativa cair no
	vazio, e o vendedor ficaria congelado ate a proxima travessia de raio. Um mapa
	trocado faz o mesmo, jogando os tracks do modelo antigo fora.

	Como os dois estados de descanso sao loops, "a pose nao esta tocando" e sempre um
	erro, e um que da para consertar sozinho no proximo tick.
]=]
function ShopKeeperController:_ensureResting()
	if self.State ~= AWAY and self.State ~= ATTENDING then
		return
	end

	-- Revalida o modelo antes de olhar para o track: e o `_getModel` que joga fora os
	-- tracks de um modelo que saiu do mundo, e um track orfao ainda responde que esta
	-- tocando.
	self:_getModel()

	if self.CurrentTrack and self.CurrentTrack.IsPlaying then
		return
	end

	local resting = self.State == AWAY
		and ShopConfig.KEEPER_IDLE_ANIMATION
		or ShopConfig.KEEPER_ATTEND_ANIMATION

	self:_play(resting, true)
end

--[=[
	Entrou ou saiu do raio de aproximacao.

	So a **travessia** age, do mesmo jeito que a proximidade da loja: parado dentro do
	raio o vendedor fica no `IdleBench`, sem repetir o `GetUp` a cada meio segundo.
]=]
function ShopKeeperController:_update()
	self:_ensureResting()

	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")

	local shop = self.Controllers.ShopController
	local position = root and shop and shop:GetReferencePosition()

	local near = false
	if position and root then
		near = (root.Position - position).Magnitude <= ShopConfig.KEEPER_APPROACH_RADIUS
	end

	if near == self.PlayerNear then
		return
	end

	self.PlayerNear = near

	if near then
		-- A visita comeca zerada: o vendedor lembra do que o jogador levou **desta**
		-- vez, e nao da compra da visita passada.
		self.Sold = false
		self:_setState(GREETING)
	else
		self:_setState(LEAVING)
	end
end

function ShopKeeperController:_watch()
	self.Maid:GiveTask(RunService.Heartbeat:Connect(function(deltaTime : number)
		self.Clock += deltaTime

		if self.Clock < ShopConfig.PROXIMITY_INTERVAL then
			return
		end

		self.Clock = 0
		self:_update()
	end))
end

--[[ LIFECYCLE ]]

function ShopKeeperController:construct()
	--[[
		Uma compra que deu certo em qualquer momento da visita ja garante a despedida
		boa. Nao importa se a loja fechou entre a compra e a saida: comprar e ir embora
		pelo raio continua sendo a mesma visita.
	]]
	local shop = self.Controllers.ShopController

	if shop then
		self.Maid:GiveTask(shop.Signals.PurchaseResult:Connect(function(_itemId : string, success : boolean)
			if success then
				self.Sold = true
			end
		end))
	end

	-- Descansando desde o primeiro segundo: e assim que o jogador que acabou de
	-- entrar encontra o vendedor, do outro lado da praca.
	self:_setState(AWAY)
	self:_watch()
end

function ShopKeeperController:start()
	self.Maid = Maid.new()
	self.ChainMaid = Maid.new()
	self.Maid:GiveTask(self.ChainMaid)

	self.Model = nil
	self.Tracks = {}
	self.CurrentTrack = nil

	self.WarnedMissing = false
	self.WarnedTracks = {}

	self.State = nil
	self.PlayerNear = false
	self.Sold = false
	self.Clock = 0

	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	self:construct()
end

return ShopKeeperController
