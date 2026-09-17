local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)

local Me = require(Vendor.Me)

local CmdrConfig = SharedConfig.Cmdr

local Framework = Me.new()

local CmdrController = {
	Controllers = {},
}

function CmdrController:construct()
	local Cmdr = require(ReplicatedStorage:WaitForChild("CmdrClient")) :: any
	self.Cmdr = Cmdr

	Cmdr:SetActivationKeys(CmdrConfig.ACTIVATION_KEYS)
	Cmdr:SetPlaceName(CmdrConfig.PLACE_NAME)

	--[=[
		A lista de admins NAO e replicada: quem decide e o servidor.

		Isto aqui e cosmetico -- so esconde o console de quem nao e admin. A
		permissao de verdade e revalidada pelo hook BeforeRun do CmdrService a
		cada comando, entao mesmo que um exploiter force SetEnabled(true) ele nao
		consegue rodar nada.

		Ate a resposta do servidor chegar o console fica desabilitado.
	]=]
	Cmdr:SetEnabled(false)

	local accessible : { [string]: boolean } = {}

	--[=[
		Comandos com `ClientRun` (o `help`, por exemplo) rodam inteiros no cliente
		e nunca passam pelo BeforeRun do servidor. Sem nenhum hook no cliente, o
		Cmdr bloqueia esses comandos fora do Studio ("no BeforeRun hook is
		configured"), entao o hook daqui e o que libera o `help` em jogo.
	]=]
	Cmdr.Registry:RegisterHook("BeforeRun", function(context)
		if not accessible[context.Name] then
			return "You do not have permission to run this command."
		end

		return nil
	end)

	Framework:Listen("CmdrAccess", function(commandNames : { string })
		accessible = {}

		for _, commandName in commandNames do
			accessible[commandName] = true
		end

		self:HideInaccessibleCommands(accessible)
		Cmdr:SetEnabled(next(accessible) ~= nil)
	end)

	Framework:Fire("RequestCmdrAccess")
end

--[=[
	Tira do registro LOCAL os comandos que o jogador nao pode rodar, e com isso eles
	somem do `help`, do autocomplete e do tipo `command` (que leem o registro).

	Mexe nos campos internos do Registry do Cmdr (`Commands` e `CommandsArray`),
	porque ele nao tem API para desregistrar. So afeta este cliente: o servidor
	continua com tudo registrado e validando no BeforeRun.
]=]
function CmdrController:HideInaccessibleCommands(accessible : { [string]: boolean })
	local Registry = self.Cmdr.Registry

	for index = #Registry.CommandsArray, 1, -1 do
		if not accessible[Registry.CommandsArray[index].Name] then
			table.remove(Registry.CommandsArray, index)
		end
	end

	-- `Commands` tem uma entrada por nome e por alias, todas apontando para o objeto.
	for key, commandObject in Registry.Commands do
		if not accessible[commandObject.Name] then
			Registry.Commands[key] = nil
		end
	end
end

function CmdrController:start()

end

function CmdrController:init()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	self:construct()
end

return CmdrController
