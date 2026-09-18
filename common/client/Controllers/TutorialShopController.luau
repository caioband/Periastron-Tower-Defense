local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)

local Me = require(Vendor.Me)

local Framework = Me.new()

local Config = SharedConfig.TutorialConfig

--[[
	O empurrãozinho da loja, no lobby, para quem acabou de vencer o tutorial.

	O servidor manda `TutorialShopPrompt` quando o jogador cai no lobby vindo de uma
	partida de tutorial vencida — o sinal é o bilhete do teleporte, não o perfil.
	Daqui saem a fala e o destaque no botão da loja, e os dois somem quando a compra
	acontece (`TutorialShopDone`).

	**Nada disto sobrevive a um logout**, de propósito: é um empurrão, e empurrão que
	persegue o jogador entre sessões vira cobrança.

	Fica em `common/` porque o `HighlightController` e a caixa de fala são de lá — e
	porque o dia em que a Game quiser apontar algo assim, o caminho já existe.
]]

local TutorialShopController = {
	Controllers = {
		DialogController = {},
		HighlightController = {},
	}
}

TutorialShopController.Active = false

--[[ INTERNAL ]]

--[=[
	Aponta a loja: fala e destaque.

	A fala entra **sem** esconder a UI e sem borrão, como os passos da partida: o
	jogador precisa enxergar (e clicar) o botão que está sendo apontado.
]=]
function TutorialShopController:show()
	if self.Active then return end

	self.Active = true

	local shop = Config.Shop

	local dialog = self.Controllers.DialogController
	if dialog and shop.Lines then
		dialog:Play(shop.Lines, {
			HideUI = false,
			Blur = false,
			Duck = false,
			Auto = true,
		})
	end

	local highlight = self.Controllers.HighlightController
	if not highlight then return end

	local target = highlight:Find(shop.Highlight)
	if not target then
		warn(`[TutorialShopController]: nao achei "{shop.Highlight}" na PlayerGui.`)

		return
	end

	highlight:Show(target)
end

function TutorialShopController:hide()
	if not self.Active then return end

	self.Active = false

	local highlight = self.Controllers.HighlightController
	if highlight then
		highlight:Hide()
	end
end

--[[ CICLO DE VIDA ]]

function TutorialShopController:construct()
	Framework:Listen("TutorialShopPrompt", function()
		self:show()
	end)

	Framework:Listen("TutorialShopDone", function()
		self:hide()
	end)
end

function TutorialShopController:start()
end

function TutorialShopController:init()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	self:construct()
end

return TutorialShopController
