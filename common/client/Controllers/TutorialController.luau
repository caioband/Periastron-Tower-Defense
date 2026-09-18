local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Player = Players.LocalPlayer

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)

local Me = require(Vendor.Me)

local Framework = Me.new()

local Config = SharedConfig.TutorialConfig

--[[
	A oferta de tutorial na tela.

	O servidor manda `TutorialPrompt` para quem tem `Tutorial = false` no perfil
	(ver `TutorialService`); daqui sai a fala, pela caixa de sempre:

		Hello, {nome em gradiente laranja}, welcome to Periastron Tower Defense
		Would you like to play a Tutorial?

	A segunda frase termina e só então os dois botões aparecem — a escolha depois da
	pergunta, não durante. Enquanto eles estão no ar, clicar no vazio não fecha a
	caixa: a resposta é do botão.

	**O que acontece depois é de quem quiser.** O controller responde ao servidor
	(`TutorialAnswered`) e chama quem se inscreveu:

		local Tutorial = Framework:Get("TutorialController")

		Tutorial:OnAnswer(function(accepted)
			if accepted then
				Camera:LookAtShop()
			end
		end)

	Os passos do tutorial ainda não existem; quando existirem, eles se penduram
	nesse gancho (no cliente) ou no `TutorialService:Start` (no servidor), e esta
	fala não muda de linha.

	**A resposta não mexe no perfil**, nem aceitando nem recusando. Quem escreve
	`Tutorial = true` é o fim do tutorial, que está por fazer.

	Fica em `common/` porque o controller é o mesmo nas duas places — quem decide
	que a oferta só faz sentido no lobby é o servidor.
]]

local TutorialController = {
	Controllers = {
		DialogController = {},
		RichTextController = {},
	}
}

TutorialController.Listeners = {}

-- Uma oferta por vez: o `task.delay` da entrada só vale se ninguém tiver
-- respondido (ou pedido outra) enquanto ele esperava.
TutorialController.Session = 0

--[[ INTERNAL ]]

--[=[
	As frases com o nome do jogador dentro.

	O nome passa pelo `:Escape()` porque é texto que o jogador escolheu: um colchete
	no nome não pode virar marcação, e um `<` não pode comer o resto da saudação.
]=]
function TutorialController:lines() : { string }
	local name = self.Controllers.RichTextController:Escape(Player.DisplayName)

	local lines = {}
	for index, line in Config.Lines do
		lines[index] = string.format(line, name)
	end

	return lines
end

--[=[
	A resposta: avisa o servidor, chama quem se inscreveu e fecha a caixa.

	Fecha **depois** de avisar, e não antes, para quem se inscreveu poder abrir
	outra fala em cima sem ela ser apagada pelo fechamento desta.
]=]
function TutorialController:answer(accepted : boolean)
	self.Session += 1

	Framework:Fire("TutorialAnswered", accepted)

	for _, listener in self.Listeners do
		task.spawn(listener, accepted)
	end

	self.Controllers.DialogController:Close()
end

--[[ API ]]

--[=[
	Põe a oferta na tela agora. O servidor chama isto pelo `TutorialPrompt`, e o
	`tutorial` do Cmdr entra pelo mesmo caminho.

	Devolve `false` quando a caixa de fala não existe nesta place.
]=]
function TutorialController:Prompt() : boolean
	local dialog = self.Controllers.DialogController

	self.Session += 1
	local session = self.Session

	local buttons = {}
	buttons[Config.Buttons.AcceptIndex] = {
		Text = Config.Buttons.AcceptText,
		Font = Config.Font,
		OnClick = function()
			if self.Session ~= session then return end

			self:answer(true)
		end,
	}
	buttons[Config.Buttons.DeclineIndex] = {
		Text = Config.Buttons.DeclineText,
		Font = Config.Font,
		OnClick = function()
			if self.Session ~= session then return end

			self:answer(false)
		end,
	}

	return dialog:Play(self:lines(), Config.Speech({
		Buttons = buttons,
		ButtonsAtEnd = true,
	}))
end

--[=[
	Chama de volta com a resposta do jogador (`true` aceitou, `false` recusou).
	Devolve a função que desinscreve.

	É o gancho para o tutorial de verdade, para uma câmera, para um som — o que
	quer que venha depois da pergunta.
]=]
function TutorialController:OnAnswer(callback : (accepted : boolean) -> ()) : () -> ()
	table.insert(self.Listeners, callback)

	return function()
		local index = table.find(self.Listeners, callback)
		if index then
			table.remove(self.Listeners, index)
		end
	end
end

--[[ CICLO DE VIDA ]]

function TutorialController:construct()
	Framework:Listen("TutorialPrompt", function()
		local session = self.Session

		-- O jogador acabou de cair no lobby: tem UI carregando, abertura e câmera
		-- acontecendo. Falar por cima disso é o mesmo que não falar.
		task.delay(Config.PromptDelay, function()
			if self.Session ~= session then return end

			self:Prompt()
		end)
	end)
end

function TutorialController:start()
end

function TutorialController:init()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	self:construct()
end

return TutorialController
