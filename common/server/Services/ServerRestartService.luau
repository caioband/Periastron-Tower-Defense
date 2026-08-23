local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Me = require(Vendor.Me)

local Framework = Me.new()

--[[
	O aviso de que o servidor vai reiniciar.

	Quem avisa é a própria engine: `game.ServerRestartScheduled` dispara no servidor
	quando a Roblox marca o fim deste servidor — seja porque o desenvolvedor
	publicou uma atualização, seja por manutenção, moderação ou memória da própria
	Roblox. O evento traz **quando** (`restartTime`, um `DateTime`) e **por que**
	(`source`, um `Enum.CloseReason`).

	O evento só existe no servidor, então este service o repassa para os clientes
	como `ServerRestartScheduled` (nome do motivo + segundos que faltam) e o
	`ServerRestartController` escreve a frase na tela.

	**Segundos que faltam, e não o horário.** O `restartTime` é UTC e o relógio do
	cliente não é confiável — máquina com a hora errada mostraria "restart em 3
	horas". A conta é feita aqui, contra o relógio do servidor, e refeita a cada
	envio: quem entra dois minutos depois recebe dois minutos a menos.

	Fica em `common/` porque o restart derruba as duas places.
]]

local ServerRestartService = {
	Services = {}
}

-- Nome do `Enum.CloseReason` que a engine mandou, e o instante do restart em
-- tempo Unix. Ambos nil enquanto nada estiver agendado.
ServerRestartService.Source = nil :: string?
ServerRestartService.RestartTime = nil :: number?
ServerRestartService.Scheduled = false

--[[ INTERNAL ]]

--[=[
	Separa `restartTime` e `source` do que a engine mandou.

	A ordem dos argumentos é lida do valor, e não da posição, de propósito: a
	assinatura documentada é `(restartTime, source, attributes)`, mas o evento é
	novo e já apareceu documentado na ordem trocada. Olhar o `typeof` custa nada e
	sobrevive às duas — o que não dá é mostrar a hora no lugar do motivo.
]=]
local function readSchedule(...) : (DateTime?, EnumItem?)
	local packed = table.pack(...)

	local restartTime : DateTime? = nil
	local source : EnumItem? = nil

	for index = 1, packed.n do
		local value = packed[index]
		local kind = typeof(value)

		if kind == "DateTime" then
			restartTime = value
		elseif kind == "EnumItem" and (value :: EnumItem).EnumType == Enum.CloseReason then
			source = value
		end
	end

	return restartTime, source
end

--[=[
	Quantos segundos faltam para o restart, ou nil se a engine não disse quando.
]=]
function ServerRestartService:GetRemaining() : number?
	if not self.RestartTime then
		return nil
	end

	return math.max(self.RestartTime - DateTime.now().UnixTimestamp, 0)
end

--[=[
	Manda o aviso para um jogador. Sem nada agendado, não manda nada.
]=]
function ServerRestartService:Send(player : Player)
	if not self.Scheduled then return end

	Framework:Fire("ServerRestartScheduled", player, self.Source, self:GetRemaining())
end

--[=[
	Guarda o agendamento e avisa quem já está no servidor.

	Público porque é isto que o `restartwarning` do Cmdr precisa para ensaiar o aviso sem
	derrubar o servidor de verdade.
]=]
function ServerRestartService:Schedule(source : string?, restartTime : number?)
	self.Scheduled = true
	self.Source = source
	self.RestartTime = restartTime

	for _, player in Players:GetPlayers() do
		self:Send(player)
	end
end

--[[ CICLO DE VIDA ]]

function ServerRestartService:construct()
	-- Quem entra depois do agendamento (ou antes de a Interface dele existir) pede
	-- o aviso pendente.
	Framework:Listen("RequestServerRestart", function(player : Player)
		self:Send(player)
	end)

	-- Numa versão da engine que ainda não tenha o evento, ler a propriedade é erro,
	-- e não nil. O `pcall` deixa o resto do service de pé — o `restartwarning` do
	-- Cmdr continua ensaiando o aviso.
	local ok, scheduled = pcall(function()
		return (game :: any).ServerRestartScheduled
	end)

	if not ok or typeof(scheduled) ~= "RBXScriptSignal" then
		warn("[ServerRestartService]: game.ServerRestartScheduled nao existe nesta versao da engine.")
		return
	end

	scheduled:Connect(function(...)
		local restartTime, source = readSchedule(...)

		self:Schedule(source and source.Name, restartTime and restartTime.UnixTimestamp)
	end)
end

function ServerRestartService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service)
	end

	self:construct()
end

function ServerRestartService:init()
	-- O identificador do evento nasce no servidor: sem este `Listen` vazio, o
	-- `Listen` do cliente ficaria dez segundos esperando um evento que ninguém
	-- registrou e levaria junto o resto do controller.
	Framework:Listen("ServerRestartScheduled", function() end)
end

return ServerRestartService
