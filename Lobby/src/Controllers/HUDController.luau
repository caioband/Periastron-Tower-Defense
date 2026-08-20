local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ContentProvider = game:GetService("ContentProvider")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Configs = Shared:WaitForChild("Config")
local Util = Shared:WaitForChild("Util")

local Maid = require(Vendor.Maid)
local Me = require(Vendor.Me)

local SharedConfig = require(Configs.SharedConfig)
local UIUtil = require(Util.UIUtil)

local LevelConfig = SharedConfig.LevelConfig

local Framework = Me.new()

--[[ CONSTANTS ]]
local HUD_UI_NAME = "HUD"
local MIDDLE_NAME = "HUDMiddle"

local LEVEL_NAME = "Level"
local EXP_NAME = "ExpAmount"
local BAR_CONTAINER_NAME = "ProgressBarContainer"
local BAR_IMAGE_NAME = "EXPImage"

local COIN_NAME = "CoinAmount"
local COIN_TEXT_NAME = "CoinAmountText"
local SHARD_NAME = "ShardAmount"
local SHARD_TEXT_NAME = "ShardAmountText"

local WAIT_TIMEOUT = 10

local LEVEL_FORMAT = "LEVEL %d"
local MAX_EXP_TEXT = "MAX"

-- ScreenGui so para segurar as imagens da barra em memoria. Fica desligada e
-- com ResetOnSpawn falso: o HUD e recriado a cada respawn, o cache nao.
local CACHE_GUI_NAME = "HUDImageCache"

--[=[
	Escreve os dados do perfil no StarterGui.HUD.HUDMiddle: nivel, XP, coins e shards.

	Nivel e progresso saem do XP acumulado (`SharedConfig.LevelConfig`) — o perfil nao
	guarda nivel. A barra nao e uma barra: e um ImageLabel unico que troca de arte
	conforme a faixa de progresso, e as cinco artes sao baixadas e mantidas em cache
	assim que o jogador entra, para a primeira troca nao aparecer em branco.

	O HUD tem `ResetOnSpawn` ligado, entao o bind roda de novo para cada copia nova
	que a engine coloca na PlayerGui.
]=]
local HUDController = {
	Controllers = {
		DataController = {},
	},
}

--[[ INTERNAL ]]

--[=[
	Baixa as artes da barra e as segura em memoria. `PreloadAsync` sozinho so garante
	o download; o que impede o descarte depois e ter um ImageLabel vivo apontando para
	cada uma — por isso o cache e feito de instancias, e nao de uma lista de ids.

	`emptyImage` e a barra vazia que veio autorada na GUI, que tambem volta a ser usada
	quando o progresso zera num level up.
]=]
function HUDController:_cacheImages(emptyImage : string?)
	if self.CacheGui then
		return
	end

	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	local cacheGui = Instance.new("ScreenGui")
	cacheGui.Name = CACHE_GUI_NAME
	cacheGui.Enabled = false
	cacheGui.ResetOnSpawn = false
	cacheGui.Parent = playerGui

	self.CacheGui = cacheGui
	self.Maid:GiveTask(cacheGui)

	local images = LevelConfig:GetBarImages()
	if emptyImage and emptyImage ~= "" then
		table.insert(images, 1, emptyImage)
	end

	local holders = {}
	for index, image in images do
		local holder = Instance.new("ImageLabel")
		holder.Name = tostring(index)
		holder.Image = image
		holder.BackgroundTransparency = 1
		holder.ImageTransparency = 1
		holder.Size = UDim2.fromOffset(1, 1)
		holder.Visible = false
		holder.Parent = cacheGui

		table.insert(holders, holder)
	end

	task.spawn(function()
		local ok, err = pcall(function()
			ContentProvider:PreloadAsync(holders)
		end)

		if not ok then
			warn(`[HUDController]: preload da barra de XP falhou — {err}`)
		end
	end)
end

--[=[
	Os stats do perfil, ou nil enquanto a replica nao chegou.
]=]
function HUDController:_getStats()
	local replica = self.Replica
	return replica and replica.Data and replica.Data.Stats
end

function HUDController:_setBarImage(image : string)
	local bar = self.Bar
	if not bar or not image or bar.Image == image then
		return
	end

	bar.Image = image
end

--[=[
	Reescreve os quatro campos a partir da replica. Chamado no bind e a cada escrita
	em `Stats`; sem replica ainda, mostra o estado zerado em vez do texto autorado.
]=]
function HUDController:_refresh()
	if not self.Middle or not self.Middle.Parent then
		return
	end

	local stats = self:_getStats()
	local state = LevelConfig:Resolve(stats and stats.XP or 0)

	self.State = state

	if self.LevelLabel then
		self.LevelLabel.Text = string.format(LEVEL_FORMAT, state.Level)
	end

	if self.ExpLabel then
		self.ExpLabel.Text = if state.IsMax
			then MAX_EXP_TEXT
			else `{UIUtil.formatCommas(state.XP)}/{UIUtil.formatCommas(state.Required)}`
	end

	self:_setBarImage(LevelConfig:GetBarImage(state.Progress) or self.EmptyBarImage)

	if self.CoinLabel then
		self.CoinLabel.Text = UIUtil.formatCommas(stats and stats.Cash or 0)
	end

	if self.ShardLabel then
		self.ShardLabel.Text = UIUtil.formatCommas(stats and stats.Shards or 0)
	end
end

--[=[
	Segura a replica do jogador e reescreve o HUD a cada mudanca. Igual ao contador do
	ShopController: o DataService escreve a chave `Stats` inteira, mas o listener e o
	`OnChange` para que qualquer escrita mais funda (`Stats.XP`, ...) tambem conte.
]=]
function HUDController:_watchStats()
	task.spawn(function()
		local replica = self.Controllers.DataController:GetReplica()
		self.Replica = replica

		self:_refresh()

		local connection = replica:OnChange(function(_action, path)
			if path[1] ~= nil and path[1] ~= "Stats" then
				return
			end

			self:_refresh()
		end)

		self.Maid:GiveTask(function()
			connection:Disconnect()
		end)
	end)
end

--[=[
	Liga a uma copia do HUD. Roda de novo a cada respawn (`ResetOnSpawn`).
]=]
function HUDController:_bindUI(screenGui : ScreenGui)
	local middle = screenGui:WaitForChild(MIDDLE_NAME, WAIT_TIMEOUT)
	local barContainer = middle and middle:WaitForChild(BAR_CONTAINER_NAME, WAIT_TIMEOUT)
	local bar = barContainer and barContainer:WaitForChild(BAR_IMAGE_NAME, WAIT_TIMEOUT)

	if not middle or not bar or not bar:IsA("ImageLabel") then
		warn(`[HUDController]: nao achei {HUD_UI_NAME}.{MIDDLE_NAME}.{BAR_CONTAINER_NAME}.{BAR_IMAGE_NAME}.`)
		return
	end

	local coin = middle:FindFirstChild(COIN_NAME)
	local shard = middle:FindFirstChild(SHARD_NAME)

	self.ScreenGui = screenGui
	self.Middle = middle
	self.Bar = bar
	self.LevelLabel = middle:FindFirstChild(LEVEL_NAME)
	self.ExpLabel = middle:FindFirstChild(EXP_NAME)
	self.CoinLabel = coin and coin:FindFirstChild(COIN_TEXT_NAME)
	self.ShardLabel = shard and shard:FindFirstChild(SHARD_TEXT_NAME)

	-- A barra vazia e a arte que veio autorada na GUI: o id dela nao mora no config,
	-- e lido daqui. So da primeira copia, que e a unica garantidamente intocada — e
	-- e ela tambem que dispara o cache, que vale para a sessao inteira.
	if not self.EmptyBarImage then
		self.EmptyBarImage = bar.Image
		self:_cacheImages(self.EmptyBarImage)
	end

	self:_refresh()
end

function HUDController:_observeUI()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	local function onChild(child : Instance)
		if child:IsA("ScreenGui") and child.Name == HUD_UI_NAME then
			self:_bindUI(child)
		end
	end

	self.Maid:GiveTask(playerGui.ChildAdded:Connect(onChild))

	for _, child in playerGui:GetChildren() do
		task.spawn(onChild, child)
	end
end

--[[ EXTERNAL ]]

--[=[
	Nivel e progresso do jogador local, do jeito que o HUD esta mostrando.
]=]
function HUDController:GetLevelState()
	return self.State or LevelConfig:Resolve(0)
end

--[=[
	Reescreve o HUD na mao. So e preciso para quem mexe no perfil sem passar pela
	replica — a replica ja atualiza sozinha.
]=]
function HUDController:Refresh()
	self:_refresh()
end

function HUDController:start()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	self:_observeUI()
	self:_watchStats()
end

function HUDController:init()
	self.Maid = Maid.new()
	self.EmptyBarImage = nil
end

return HUDController
