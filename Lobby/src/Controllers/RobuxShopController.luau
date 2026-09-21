local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Configs = Shared:WaitForChild("Config")
local Util = Shared:WaitForChild("Util")

local Maid = require(Vendor.Maid)
local Me = require(Vendor.Me)

local SharedConfig = require(Configs.SharedConfig)
local ButtonUtil = require(Util.ButtonUtil)
local ProximityPanel = require(Util.ProximityPanel)

local RobuxShopConfig = SharedConfig.RobuxShopConfig
local GamepassConfig = SharedConfig.GamepassConfig

local Framework = Me.new()

local GUI = RobuxShopConfig.Gui

--[[ CONSTANTS ]]

--[=[
	O nome do pedido ao `InterfaceController`: enquanto a loja esta aberta, a tela e
	so dela.

	Proprio, e nao o `"Shop"` das outras lojas: uma GUI so volta quando o **ultimo**
	pedido sai, e dividir o nome faria uma devolver a tela que a outra pediu.
]=]
local HIDE_REASON = "RobuxShop"

--[=[
	O botao da HUD que abre a loja: `HUD.HUDLeft.Wrapper.RobuxShop`, vizinho do
	`Contracts` na coluna da esquerda.

	**Esta loja nao tem lugar no mapa.** As outras duas abrem por proximidade e o
	botao da HUD so leva o jogador ate la; aqui o botao *e* a porta -- ver o
	`ProximityPanel` sem `GetReference`.

	O crescer e o afundar do botao continuam sendo do `HUDButtonController`, que anima
	as duas colunas. Daqui sai so o clique.
]=]
local HUD_UI_NAME = "HUD"
local HUD_FRAME_NAME = "HUDLeft"
local HUD_BUTTON_NAME = "RobuxShop"

local WAIT_TIMEOUT = 10

-- O `UIScale` que o `ButtonUtil` precisa para dar peso ao botao. As linhas foram
-- autoradas sem ele, e criar um aqui nao atrapalha quem ja tenha o seu.
local SCALE_NAME = "BuyScale"

-- O botao da pass que o jogador ja tem fica meio apagado, e nao escondido: a arte da
-- linha foi desenhada com ele no lugar. O mesmo numero do CLAIM ja resgatado.
local DISABLED_TRANSPARENCY = 0.55

--[=[
	A loja de Robux do lobby: `StarterGui.ShopUI.RobuxShop`.

	Seis gamepasses e tres packs de coins, cada um num `BUY`. **Este controller nao
	credita nada**: ele abre o prompt da Roblox e para por ai. A pass vira beneficio
	quando o `MonetizationService` reconfere o perfil (`RecalibratePasses`), e o pack
	vira coins quando o recibo chega no `RobuxShopService` -- os dois no servidor, os
	dois voltando para ca pela replica.

	O `OWNED` e a leitura do mesmo perfil: `Data.Gamepasses` diz o que este jogador ja
	tem, e a linha correspondente apaga o botao. Cancelar o prompt nao muda nada, que e
	o certo -- nada aqui e escrito no clique.

	**A `ShopUI` e dividida com as outras duas lojas.** As tres sao irmas dentro dela e
	nenhuma manda no `Enabled` sozinha: quem diz qual painel esta na tela e o `Visible`
	do wrapper de cada uma (ver o `CanDisable` no `construct`).
]=]
local RobuxShopController = {
	Controllers = {
		DataController = {},
		InterfaceController = {},

		-- As outras duas lojas da mesma `ScreenGui`. So para saber se alguma esta
		-- aberta antes de apagar a ScreenGui das tres -- ver o `CanDisable`.
		ShopController = {},
		RoundCardShopController = {},

		-- O selo `New` do botao da HUD, que volta cinco minutos depois de cada
		-- abertura. Ver o `BeforeOpen` no `construct`.
		HUDBadgeController = {},
	},
}

--[[ INTERNAL ]]

--- O `Data` da replica, ou nil enquanto ela nao chegou.
function RobuxShopController:_profile()
	local replica = self.Replica

	return replica and replica.Data or nil
end

--- Se este jogador tem a pass. Sem perfil vale "nao tem", e nao erro.
function RobuxShopController:_owns(key : string) : boolean
	local profile = self:_profile()

	return profile ~= nil and GamepassConfig.owns(profile, key)
end

--[=[
	Liga uma linha da vitrine pelo nome dela.

	A busca e em profundidade a partir do painel: as linhas moram em duas
	`ScrollingFrame` de **mesmo nome** (as passes numa, os packs na outra), entao o
	caminho ate a lista nao distingue uma da outra -- mas `GP1` e `DEVPROD1` sao unicos
	na tela toda.
]=]
function RobuxShopController:_bindRow(panel : GuiObject, frameName : string, maid, onClick : () -> ())
	local row = panel:FindFirstChild(frameName, true)
	local button = row and row:FindFirstChild(GUI.Buy, true)

	if not button or not button:IsA("GuiButton") then
		warn(`[RobuxShopController]: nao achei {frameName}.{GUI.Buy} em {GUI.ScreenGui}.{GUI.Wrapper} -- essa linha nao compra nada.`)
		return nil
	end

	if not button:FindFirstChildWhichIsA("UIScale") then
		local scale = Instance.new("UIScale")
		scale.Name = SCALE_NAME
		scale.Parent = button
	end

	local label = button:FindFirstChildWhichIsA("TextLabel")

	maid:GiveTask(button.Activated:Connect(onClick))
	ButtonUtil.bindFeedback(button, maid)

	return {
		Button = button,
		Label = label,

		-- A transparencia autorada, lida uma vez: e para ela que o botao volta quando
		-- a linha esta a venda.
		Image = button:IsA("ImageButton") and button.ImageTransparency or 0,
		Text = label and label.TextTransparency or 0,
	}
end

--[=[
	O conteudo numa copia nova da `ShopUI`: as seis passes e os tres packs.

	O painel em si (moldura, animacao, borrao, tela) e do `ProximityPanel`, e o `maid`
	daqui e o dele -- uma copia nova desliga os cliques da anterior.
]=]
function RobuxShopController:_onBind(panel : GuiObject, maid)
	self.Rows = {}

	for _, entry in RobuxShopConfig.PASSES do
		self.Rows[entry.Frame] = self:_bindRow(panel, entry.Frame, maid, function()
			self:_promptPass(entry.Pass)
		end)
	end

	for _, pack in RobuxShopConfig.PACKS do
		self.Rows[pack.Frame] = self:_bindRow(panel, pack.Frame, maid, function()
			self:_promptPack(pack)
		end)
	end

	self:_render()
end

--[=[
	O botao conforme o perfil: apagado e sem clique para a pass que o jogador ja tem.

	Pack de coins nunca passa por aqui -- ele pode ser comprado de novo quantas vezes
	quiser, e o botao dele fica sempre como foi autorado.
]=]
function RobuxShopController:_writeOwned(entry, owned : boolean)
	local button = entry.Button

	button.Active = not owned
	button.AutoButtonColor = not owned

	if button:IsA("ImageButton") then
		button.ImageTransparency = if owned then DISABLED_TRANSPARENCY else entry.Image
	end

	local label = entry.Label
	if label then
		label.Text = if owned then RobuxShopConfig.OWNED_TEXT else RobuxShopConfig.BUY_TEXT
		label.TextTransparency = if owned then DISABLED_TRANSPARENCY else entry.Text
	end
end

function RobuxShopController:_render()
	for _, pass in RobuxShopConfig.PASSES do
		local entry = self.Rows[pass.Frame]

		if entry then
			self:_writeOwned(entry, self:_owns(pass.Pass))
		end
	end
end

--[=[
	Abre o prompt de uma gamepass.

	So abre o que ainda da para comprar: o botao ja esta apagado, e isto e a mesma
	conferencia do outro lado do clique -- um prompt de pass que o jogador ja tem so
	diria a ele o que a linha ja dizia.
]=]
function RobuxShopController:_promptPass(key : string)
	local pass = GamepassConfig.PASSES[key]

	if not pass then
		warn(`[RobuxShopController]: a pass '{key}' nao esta no GamepassConfig.`)
		return
	end

	if self:_owns(key) then
		return
	end

	MarketplaceService:PromptGamePassPurchase(Players.LocalPlayer, pass.Id)
end

--[=[
	Abre o prompt de um pack de coins.

	Sem debounce, como o reroll: `PromptProductPurchase` nao empilha janelas. E sem
	credito nenhum aqui -- quem paga e o recibo, no `RobuxShopService`.
]=]
function RobuxShopController:_promptPack(pack)
	MarketplaceService:PromptProductPurchase(Players.LocalPlayer, pack.ProductId)
end

--[=[
	Liga o botao da HUD, que abre a loja.

	Maid proprio: a `HUD` e a `ShopUI` sao `ScreenGui` diferentes e a engine as refaz
	em momentos diferentes, entao o bind de uma nao pode desconectar o da outra.
]=]
function RobuxShopController:_bindHud(screenGui : ScreenGui)
	local hudFrame = screenGui:WaitForChild(HUD_FRAME_NAME, WAIT_TIMEOUT)
	local button = hudFrame and hudFrame:FindFirstChild(HUD_BUTTON_NAME, true)

	if not button or not button:IsA("GuiButton") then
		if not self.WarnedButton then
			self.WarnedButton = true
			warn(`[RobuxShopController]: nao achei {HUD_UI_NAME}.{HUD_FRAME_NAME}.{HUD_BUTTON_NAME}.`)
		end

		return
	end

	self.HudMaid:DoCleaning()
	self.HudMaid:GiveTask(button.Activated:Connect(function()
		self:Toggle()
	end))
end

--- A HUD, pelo botao que abre a loja. A `ShopUI` e seguida pelo `ProximityPanel`.
function RobuxShopController:_observeUI()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	local function onChild(child : Instance)
		if child:IsA("ScreenGui") and child.Name == HUD_UI_NAME then
			self:_bindHud(child)
		end
	end

	self.Maid:GiveTask(playerGui.ChildAdded:Connect(onChild))

	for _, child in playerGui:GetChildren() do
		task.spawn(onChild, child)
	end
end

--[=[
	Segue o perfil: a pass comprada no meio da sessao chega aqui pela replica, porque
	o `MonetizationService` reconfere e reescreve `Data.Gamepasses` assim que o prompt
	fecha. E por isso que a linha vira `OWNED` sozinha, com a loja aberta.
]=]
function RobuxShopController:_watchProfile()
	task.spawn(function()
		local replica = self.Controllers.DataController:GetReplica()
		self.Replica = replica

		self:_render()

		local connection = replica:OnChange(function(_action, path)
			local key = path[1]
			if key ~= nil and key ~= "Gamepasses" then
				return
			end

			self:_render()
		end)

		self.Maid:GiveTask(function()
			connection:Disconnect()
		end)
	end)
end

--[[ EXTERNAL ]]

function RobuxShopController:IsOpen() : boolean
	return self.Proximity ~= nil and self.Proximity:IsOpen()
end

function RobuxShopController:Open()
	if self.Proximity then
		self.Proximity:Open()
	end
end

function RobuxShopController:Close()
	if self.Proximity then
		self.Proximity:Close()
	end
end

function RobuxShopController:Toggle()
	if self.Proximity then
		self.Proximity:Toggle()
	end
end

function RobuxShopController:construct()
	--[[
		O painel: a moldura, a `OpenShop`, o borrao e o pedido de tela. **Sem
		`GetReference`** -- esta loja nao tem ponto no mapa, entao nada mede distancia
		e ela vive do botao da HUD e do X.
	]]
	self.Proximity = ProximityPanel.new({
		Name = "RobuxShopController",
		ScreenGui = GUI.ScreenGui,
		Wrapper = GUI.Wrapper,
		Panel = GUI.Panel,
		Animation = RobuxShopConfig.OPEN_ANIMATION,
		HideReason = HIDE_REASON,
		InterfaceController = self.Controllers.InterfaceController,

		-- A `ShopUI` e dividida com a loja de caixas e a de cartas: fechar esta com
		-- uma delas aberta nao pode apagar a ScreenGui das tres.
		CanDisable = function()
			local crateShop = self.Controllers.ShopController
			local cardShop = self.Controllers.RoundCardShopController

			return not ((crateShop and crateShop:IsOpen()) or (cardShop and cardShop:IsOpen()))
		end,

		OnBind = function(_screenGui, _wrapper, panel, maid)
			self:_onBind(panel, maid)
		end,

		-- O perfil pode ter mudado com a loja fechada (uma pass comprada na pagina do
		-- jogo, por exemplo): a vitrine entra ja com o que vale agora.
		BeforeOpen = function()
			self:_render()

			-- A loja foi aberta: o selo apaga e o relogio dele recomeca.
			local badges = self.Controllers.HUDBadgeController
			if badges then
				badges:NoteSeen(HUD_BUTTON_NAME)
			end
		end,
	})

	self.Maid:GiveTask(function()
		self.Proximity:Destroy()
	end)

	self.Proximity:Start()

	self:_observeUI()
	self:_watchProfile()
end

function RobuxShopController:start()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	self:construct()
end

function RobuxShopController:init()
	self.Maid = Maid.new()

	-- O clique do botao da HUD, que a engine refaz a cada respawn.
	self.HudMaid = Maid.new()
	self.Maid:GiveTask(self.HudMaid)

	-- [nome da linha] = { Button, Label, Image, Text }
	self.Rows = {}

	self.Replica = nil
	self.Proximity = nil
	self.WarnedButton = false
end

return RobuxShopController
