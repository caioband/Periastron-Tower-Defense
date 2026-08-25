local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)

local Me = require(Vendor.Me)

local Framework = Me.new()

local MapConfig = SharedConfig.MapConfig

--[[ CONSTANTES ]]

-- O nome do clone que o `MapService` poe no Workspace. E o mesmo em todos os mapas:
-- o que ele clona la e o `Content.Map` de dentro da pasta, e todos se chamam "Map".
local MAP_NAME = "Map"

local WAIT_TIMEOUT = 60
local POLL_STEP = 0.1

--[[
	O numero da vida da base, no billboard que cada mapa traz.

	A Part `BaseHP` mora na raiz da pasta do mapa, em `ServerStorage.Maps`, e o
	`MapService` a clona para dentro de `workspace.Map` junto com o resto -- sem isso
	o cliente nem a veria, porque mapa nao replica. Daqui para a frente e so escrita
	de texto: o `UpdateBaseHealth` do `MobService` chega com a vida de agora e ela vai
	para o TextLabel.

	O valor e pedido uma vez, assim que o label aparece (`RequestBaseHealth`), porque
	o evento so e disparado quando a vida muda -- quem entra e ainda nao viu nenhum
	inimigo escapar ficaria olhando o texto que veio autorado na GUI.

	Nada aqui decide vida nenhuma: quem tira e o `MobService`, no servidor, quando um
	inimigo chega ao fim do caminho. Este controller so mostra.
]]

local BaseHealthController = {}

--[[ INTERNO ]]

--[=[
	O TextLabel do billboard.

	Procurado pelo nome que o `MapConfig` diz e caindo no primeiro TextLabel que a
	Part tiver: o caminho dentro do billboard e coisa do designer, e reorganizar o
	`Frame` la nao pode apagar o numero aqui.
]=]
local function findLabel(part : Instance) : TextLabel?
	local fallback = nil

	for _, descendant in part:GetDescendants() do
		if not descendant:IsA("TextLabel") then
			continue
		end

		if descendant.Name == MapConfig.BASE_HEALTH_LABEL then
			return descendant
		end

		fallback = fallback or descendant
	end

	return fallback
end

--[=[
	Espera o mapa chegar e devolve o label de dentro da `BaseHP`.

	A Part replica antes dos filhos dela, entao achar a Part nao quer dizer que o
	billboard ja esteja montado. `WaitForChild` so serve para nome fixo e o que se
	procura aqui e um TextLabel qualquer, entao o jeito e reprocurar por alguns
	quadros. E custo de uma vez so, no boot.
]=]
function BaseHealthController:_resolveLabel() : TextLabel?
	local mapRoot = workspace:WaitForChild(MAP_NAME, WAIT_TIMEOUT)
	if not mapRoot then
		warn(`[BaseHealthController]: workspace.{MAP_NAME} nao chegou; a vida da base fica no texto autorado.`)
		return nil
	end

	local part = mapRoot:WaitForChild(MapConfig.BASE_HEALTH_PART, WAIT_TIMEOUT)
	if not part then
		warn(`[BaseHealthController]: o mapa carregado nao tem a Part "{MapConfig.BASE_HEALTH_PART}".`)
		return nil
	end

	local deadline = os.clock() + WAIT_TIMEOUT

	repeat
		local label = findLabel(part)
		if label then
			return label
		end

		task.wait(POLL_STEP)
	until os.clock() >= deadline

	warn(`[BaseHealthController]: a Part "{MapConfig.BASE_HEALTH_PART}" nao tem TextLabel nenhum dentro.`)

	return nil
end

--[=[
	Escreve a vida no label. Fica quieto enquanto faltar um dos dois -- o label pode
	chegar depois do primeiro evento, e o evento depois do label.
]=]
function BaseHealthController:_write()
	local label = self.Label

	if not label or not label.Parent or not self.Current then
		return
	end

	label.Text = tostring(math.max(0, math.floor(self.Current)))
end

--[[ CICLO DE VIDA ]]

function BaseHealthController:construct()
	-- Ligado antes de procurar o label: a procura cede a thread, e um vazamento no
	-- meio dela seria um numero perdido.
	Framework:Listen("UpdateBaseHealth", function(current : number, _max : number)
		self.Current = tonumber(current) or self.Current
		self:_write()
	end)

	self.Label = self:_resolveLabel()
	if not self.Label then
		return
	end

	self:_write()

	-- O primeiro valor. Se um `UpdateBaseHealth` chegou enquanto o mapa carregava,
	-- este pedido so confirma o que ja esta escrito.
	Framework:Fire("RequestBaseHealth")
end

function BaseHealthController:start()

end

function BaseHealthController:init()
	self:construct()
end

return BaseHealthController
