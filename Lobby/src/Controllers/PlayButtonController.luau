local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")
local Util = Shared:WaitForChild("Util")

local SharedConfig = require(Configs.SharedConfig)

local ButtonUtil = require(Util.ButtonUtil)
local MarkerUtil = require(Util.MarkerUtil)

local Maid = require(Vendor.Maid)
local Me = require(Vendor.Me)

local PortalConfig = SharedConfig.PortalConfig

local Framework = Me.new()

--[[ CONSTANTS ]]
local HUD_UI_NAME = "HUD"
local MIDDLE_NAME = "HUDMiddle"
local BUTTON_NAME = "PlayButton"

local MAP_FOLDER_NAME = "Map"

local WAIT_TIMEOUT = 10

--[=[
	O botão de jogar do `StarterGui.HUD.HUDMiddle`: ele leva o jogador até os portais,
	que é onde a partida começa de verdade.

	O crescer e o afundar são do `ButtonUtil`, o mesmo gesto dos botões de compra das
	duas lojas — e não o do `HUDButtonController`, que é dos ícones da coluna do
	`HUDFrame` e desliza para fora dela. Este botão está no meio da tela e não tem
	coluna de onde sair, então o que sobra dele é a escala, no `UIScale` autorado
	dentro do botão.

	O pouso é o `PortalsTpPart` do mapa, achado em profundidade sob `Workspace.Map`
	como qualquer outro marcador. Chegar lá é tudo o que o botão faz: quem abre o
	painel de mapas é o `PortalController`, por proximidade, do mesmo jeito que abriria
	se o jogador tivesse ido a pé.

	O HUD tem `ResetOnSpawn` ligado, então o bind roda de novo a cada cópia nova que a
	engine coloca na PlayerGui.
]=]
local PlayButtonController = {
	Controllers = {},
}

--[[ INTERNAL ]]

function PlayButtonController:_bindHud(screenGui : ScreenGui)
	local middle = screenGui:WaitForChild(MIDDLE_NAME, WAIT_TIMEOUT)
	local button = middle and middle:WaitForChild(BUTTON_NAME, WAIT_TIMEOUT)

	if not button or not button:IsA("GuiButton") then
		warn(`[PlayButtonController]: não achei {HUD_UI_NAME}.{MIDDLE_NAME}.{BUTTON_NAME}.`)
		return
	end

	self.HudMaid:DoCleaning()

	ButtonUtil.bindFeedback(button, self.HudMaid)

	self.HudMaid:GiveTask(button.Activated:Connect(function()
		self:TeleportToPortals()
	end))
end

function PlayButtonController:_observeUI()
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

--[[ EXTERNAL ]]

--[=[
	Larga o jogador em cima do marcador que fica na entrada dos portais.

	O cliente é dono do próprio personagem, então mover ele aqui basta — o servidor vê
	a posição nova pela replicação de sempre, igual ao `ShopController:TeleportToShop`.

	Devolve `false` quando não deu: personagem ainda não carregou, ou o mapa está sem o
	marcador. Nos dois casos o botão só não faz nada — o aviso do marcador que falta
	sai uma vez por nome, pelo `MarkerUtil`.
]=]
function PlayButtonController:TeleportToPortals() : boolean
	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")

	if not root then
		return false
	end

	local part = MarkerUtil.find(
		MAP_FOLDER_NAME,
		PortalConfig.PLAY_TELEPORT_PART_NAME,
		self.MapParts,
		self.WarnedParts,
		"PlayButtonController"
	)

	local pivot = MarkerUtil.pivotOf(part)
	if not pivot then
		return false
	end

	local halfHeight = MarkerUtil.halfHeightOf(part)

	character:PivotTo(pivot * CFrame.new(0, halfHeight + PortalConfig.PLAY_TELEPORT_HEIGHT_OFFSET, 0))

	-- Sem isto o jogador leva junto a velocidade que tinha e escorrega do marcador.
	root.AssemblyLinearVelocity = Vector3.zero

	return true
end

function PlayButtonController:start()
	self:_observeUI()
end

function PlayButtonController:init()
	self.Maid = Maid.new()
	self.HudMaid = Maid.new()

	self.Maid:GiveTask(self.HudMaid)

	self.MapParts = {}
	self.WarnedParts = {}

	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end
end

return PlayButtonController
