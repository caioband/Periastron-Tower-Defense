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

	Framework:Listen("CmdrAccess", function(isAdmin : boolean)
		Cmdr:SetEnabled(isAdmin == true)
	end)

	Framework:Fire("RequestCmdrAccess")
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
