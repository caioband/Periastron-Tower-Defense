local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)

local Me = require(Vendor.Me)

local Framework = Me.new()

local WarningConfig = SharedConfig.WarningConfig
local Config = WarningConfig.Restart

--[[
	"WARNING! SERVER RESTART FOR GAME UPDATE IN 2 MINUTES".

	O servidor manda `ServerRestartScheduled` com o nome do `Enum.CloseReason` e
	quantos segundos faltam; daqui sai a frase, e quem a anima no
	`Interface.WeatherWarning` é o `WarningController`.

	**O prazo é ancorado no relógio local.** O que chega é "faltam N segundos", não
	um horário: a partir daí o controller conta com `os.clock()`, que é monótono e
	não depende de a máquina do jogador estar com a hora certa.

	**O aviso volta.** Um restart costuma ser marcado com minutos de antecedência, e
	uma frase de oito segundos no meio de uma wave se perde. As marcas de
	`Config.Reminders` (5min, 2min, 1min, 30s, 10s) trazem o aviso de volta com o
	número novo, e é a última delas que o jogador realmente lê.

	Fica em `common/` porque o restart derruba as duas places.
]]

local ServerRestartController = {
	Controllers = {
		WarningController = {}
	}
}

-- Instante do restart no relógio local (`os.clock`), ou nil se o servidor não
-- soube dizer quando.
ServerRestartController.Deadline = nil :: number?
ServerRestartController.Source = nil :: string?

-- Um agendamento por sessão: os `task.delay` das marcas só valem enquanto ninguém
-- tiver reagendado por cima.
ServerRestartController.Session = 0

--[[ INTERNAL ]]

--[=[
	A frase, com o tempo que falta agora — e não o que faltava quando o aviso foi
	agendado.
]=]
function ServerRestartController:_text() : string
	local source = WarningConfig.GetRestartSource(self.Source)

	local deadline = self.Deadline
	if not deadline then
		return string.format(Config.TextNow, source)
	end

	local remaining = deadline - os.clock()
	if remaining <= Config.NowThreshold then
		return string.format(Config.TextNow, source)
	end

	return string.format(Config.Text, source, WarningConfig.FormatDuration(remaining))
end

--[=[
	Põe o aviso na tela, se a sessão ainda for a atual.
]=]
function ServerRestartController:_announce(session : number)
	if self.Session ~= session then return end

	local warning = self.Controllers.WarningController
	if not warning then return end

	warning:Show(self:_text(), {
		Priority = WarningConfig.Priority.Restart,
		Hold = Config.Hold,
	})
end

--[[ API ]]

--[=[
	Registra o restart e avisa o jogador — agora e a cada marca de `Reminders` que
	ainda couber.

	`remaining` é em segundos, contados a partir de agora. Marca que cairia em cima
	do aviso anterior é descartada: dois avisos seguidos com o mesmo número na tela
	só cortariam a animação um do outro.
]=]
function ServerRestartController:Schedule(source : string?, remaining : number?)
	self.Session += 1
	local session = self.Session

	self.Source = source
	self.Deadline = if remaining then os.clock() + math.max(remaining, 0) else nil

	self:_announce(session)

	if not remaining then return end

	for _, mark in Config.Reminders do
		local delay = remaining - mark
		if delay <= Config.Hold then continue end

		task.delay(delay, function()
			self:_announce(session)
		end)
	end
end

--[[ CICLO DE VIDA ]]

function ServerRestartController:construct()
	Framework:Listen("ServerRestartScheduled", function(source : string?, remaining : number?)
		self:Schedule(
			if typeof(source) == "string" then source else nil,
			tonumber(remaining)
		)
	end)

	-- Quem entra depois de o restart ja estar marcado precisa saber.
	Framework:Fire("RequestServerRestart")
end

function ServerRestartController:start()
end

function ServerRestartController:init()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	self:construct()
end

return ServerRestartController
