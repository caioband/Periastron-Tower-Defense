local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)

local Me = require(Vendor.Me)

local Framework = Me.new()

local WeatherConfig = SharedConfig.WeatherConfig
local RoundConfig = WeatherConfig.Round

local IS_STUDIO = RunService:IsStudio()

local function roundPrint(...)
	if not IS_STUDIO then return end
	print("[WeatherRoundService]", ...)
end

--[[
	O clima como evento de partida.

	O `WeatherService` (em `common/`) sabe ligar e desligar um clima; ele não sabe
	nada de waves. Este service é a outra metade: ele decide **se**, **qual** e
	**quando**, dentro do round.

	O ciclo de uma wave que começa:

		1. o clima que já estava no ar sai, se a duração dele acabou;
		2. o clima que estava agendado para esta wave entra;
		3. não havendo nada agendado nem no ar, joga-se um dado — e passando, um
		   clima do pool do mapa é escolhido e **avisado** para `LeadWaves` waves
		   à frente.

	O aviso é o ponto do sistema. O clima nunca cai de surpresa: o jogador vê três
	waves antes qual clima vem, e é isso que transforma o clima de azar em decisão
	— dá tempo de vender o que vai ficar inútil e posicionar o que vai brilhar.

	Um clima só é agendado se couber dentro da partida: `wave + LeadWaves` acima do
	total de waves do preset não vira aviso nenhum, porque seria um aviso de algo
	que não vai acontecer.

	Só um clima por vez, e o dado nem é jogado enquanto houver um agendado ou no
	ar. Dois avisos sobrepostos na tela e dois conjuntos de multiplicadores
	compondo seriam ilegíveis dos dois lados.
]]

--[[
	Nada aqui empurra o clima para o combate.

	O `UnitService` le o clima do `WeatherService` a cada quadro e o `MobService`
	confere se ele mudou no mesmo lugar, entao ligar o clima e o unico passo: os
	efeitos entram sozinhos. E o que faz o comando `weather` produzir exatamente a
	mesma partida que este service produz.
]]

local WeatherRoundService = {
	Services = {
		WeatherService = {},
		MapService = {},
		WaveService = {},
		DifficultyService = {}
	}
}

-- Clima no ar por decisão deste service, e a última wave em que ele vale.
WeatherRoundService.Active = nil :: string?
WeatherRoundService.ActiveUntilWave = nil :: number?

-- Clima avisado e ainda não aplicado, e a wave em que ele entra.
WeatherRoundService.Scheduled = nil :: string?
WeatherRoundService.ScheduledWave = nil :: number?

-- Até que wave o céu fica limpo à força. Ver `Suppress` (carta Weather Report).
WeatherRoundService.SuppressedUntilWave = nil :: number?

--[[ ESCOLHA ]]

--[=[
	O nome do mapa carregado.

	Vem do `MapService`, que é quem clonou a pasta — não dá para descobrir isso
	olhando o `workspace.Map`, porque o Model clonado se chama "Map" em todos eles.
]=]
function WeatherRoundService:GetMapName() : string?
	local mapService = self.Services.MapService
	return mapService and mapService.CurrentMapName or nil
end

--[=[
	Um clima do pool do mapa atual, ou nil quando o mapa não tem pool.

	O sorteio é uniforme dentro do pool. Um clima que não existir em
	`Assets.Weathers` é descartado aqui em vez de falhar lá na frente: o pool é
	config escrito à mão e um nome trocado é o erro mais provável dele.
]=]
function WeatherRoundService:PickWeather() : string?
	local mapName = self:GetMapName()
	local pool = WeatherConfig.GetPool(mapName)
	if #pool == 0 then
		return nil
	end

	local weatherService = self.Services.WeatherService
	local candidates = {}

	for _, name in pool do
		if not weatherService or weatherService:GetWeather(name) then
			table.insert(candidates, name)
		else
			warn(string.format("[WeatherRoundService]: o pool de '%s' pede o clima '%s', que nao existe em Assets.Weathers.",
				tostring(mapName), name))
		end
	end

	if #candidates == 0 then
		return nil
	end

	return candidates[math.random(1, #candidates)]
end

--[=[
	A chance de aviso por wave. Vem do preset de dificuldade; `WeatherConfig.Round`
	cobre preset sem o campo.
]=]
function WeatherRoundService:GetChance() : number
	local preset = self.Services.DifficultyService and self.Services.DifficultyService:GetSelected()
	return (preset and preset.WeatherChance) or RoundConfig.Chance or 0
end

--[[ AVISO ]]

--[=[
	Manda o aviso para todo mundo.

	`wavesAhead` vai calculado do servidor de propósito: é o que o texto mostra, e
	deixar o cliente subtrair sozinho abriria espaço para ele mostrar um número
	diferente do que o servidor vai cumprir.
]=]
function WeatherRoundService:broadcastWarning(weatherName : string, wavesAhead : number)
	for _, player in Players:GetPlayers() do
		Framework:Fire("WeatherWarning", player, weatherName, wavesAhead)
	end
end

--[[ CICLO ]]

--[=[
	Tira o clima que este service ligou.

	Só mexe no que é dele: um clima ligado na mão pelo comando `weather` não é
	desligado aqui, porque o `Active` dele está vazio.
]=]
function WeatherRoundService:ClearActive()
	if not self.Active then return end

	local previous = self.Active
	self.Active = nil
	self.ActiveUntilWave = nil

	local weatherService = self.Services.WeatherService
	if weatherService then
		weatherService:Clear(RoundConfig.TransitionTime)
	end

	roundPrint(string.format("'%s' saiu.", previous))
end

function WeatherRoundService:applyScheduled(waveNumber : number)
	local weatherName = self.Scheduled
	if not weatherName then return end

	self.Scheduled = nil
	self.ScheduledWave = nil

	local weatherService = self.Services.WeatherService
	if not weatherService then return end

	local ok, message = weatherService:Apply(weatherName, RoundConfig.TransitionTime)
	if not ok then
		warn(string.format("[WeatherRoundService]: nao consegui aplicar '%s' (%s).", weatherName, tostring(message)))
		return
	end

	self.Active = weatherName
	self.ActiveUntilWave = waveNumber + math.max(1, RoundConfig.Duration or 1) - 1

	roundPrint(string.format("'%s' entrou na wave %d, ate a %d.", weatherName, waveNumber, self.ActiveUntilWave))
end

--[=[
	O passo de uma wave. Chamado pelo sinal `WaveStarted` do `WaveService`.

	A ordem importa: o clima velho sai e o novo entra **antes** do dado, para o
	dado enxergar o estado desta wave e não o da anterior.
]=]
--[=[
	Se o céu está limpo à força nesta wave.
]=]
function WeatherRoundService:IsSuppressed(waveNumber : number?) : boolean
	if not self.SuppressedUntilWave then return false end

	local waveService = self.Services.WaveService
	local wave = waveNumber or (waveService and waveService.WaveCount) or 0

	return wave <= self.SuppressedUntilWave
end

--[=[
	Tira o clima do céu e segura o próximo por `waves` waves. Quem chama é o
	`CardShopService` (carta Weather Report).

	`Clear` do `WeatherService` direto, e não o `ClearActive` daqui: o `ClearActive`
	só desliga o que **este** service ligou, e a carta promete tirar a weather —
	inclusive a que veio pelo comando `weather`. O `ClearActive` vai junto para o
	estado interno não continuar achando que tem clima no ar.

	O aviso que já estava na tela **não** é cancelado: o clima avisado continua
	agendado e entra na primeira wave depois da janela. Cancelar seria fazer o
	jogador pagar por um aviso que ele viu e depois não aconteceu; adiar é o que a
	carta diz que faz.

	A janela é contada da wave que está no ar: comprada no meio da wave 5 com
	`waves = 1`, ela cobre o resto da 5 e a 6 inteira, e a 7 volta ao normal.
]=]
function WeatherRoundService:Suppress(waves : number?) : boolean
	local waveService = self.Services.WaveService
	local current = (waveService and waveService.WaveCount) or 0
	local span = math.max(1, waves or 1)

	self.SuppressedUntilWave = math.max(self.SuppressedUntilWave or 0, current + span)

	local hadWeather = false
	local weatherService = self.Services.WeatherService

	if weatherService and weatherService:GetCurrent() then
		hadWeather = true
		weatherService:Clear(RoundConfig.TransitionTime)
	end

	self:ClearActive()

	roundPrint(string.format("ceu limpo a forca ate a wave %d.", self.SuppressedUntilWave))

	return hadWeather
end

function WeatherRoundService:OnWaveStarted(waveNumber : number, _preset, maxWaves : number)
	--[[
		Janela do Weather Report: nada entra e nada é sorteado. O `ClearActive` cobre
		o clima que tenha sido ligado depois da compra (o comando `weather`, por
		exemplo) — enquanto a janela vale, o céu volta a limpar a cada wave.
	]]
	if self:IsSuppressed(waveNumber) then
		self:ClearActive()
		return
	end

	if self.ActiveUntilWave and waveNumber > self.ActiveUntilWave then
		self:ClearActive()
	end

	if self.ScheduledWave and waveNumber >= self.ScheduledWave then
		self:applyScheduled(waveNumber)
	end

	-- Um clima de cada vez: nem no ar, nem agendado.
	if self.Active or self.Scheduled then return end

	local lead = math.max(1, RoundConfig.LeadWaves or 1)
	local targetWave = waveNumber + lead

	-- Aviso de algo que não caberia na partida não é aviso, é ruído.
	if maxWaves and targetWave > maxWaves then return end

	if math.random() >= self:GetChance() then return end

	local weatherName = self:PickWeather()
	if not weatherName then return end

	self.Scheduled = weatherName
	self.ScheduledWave = targetWave

	self:broadcastWarning(weatherName, lead)
	roundPrint(string.format("wave %d: '%s' avisado para a wave %d.", waveNumber, weatherName, targetWave))
end

--[=[
	Zera junto com o round: nada de um clima do round anterior continuar no ar, e
	nada de um agendamento cair numa partida que nem começou.
]=]
function WeatherRoundService:ResetRound()
	self.Scheduled = nil
	self.ScheduledWave = nil
	self.SuppressedUntilWave = nil
	self:ClearActive()
end

--[[ API ]]

-- O clima que este service colocou no ar, ou nil. É o que o combate consulta.
function WeatherRoundService:GetActive() : string?
	return self.Active
end

function WeatherRoundService:GetScheduled() : (string?, number?)
	return self.Scheduled, self.ScheduledWave
end

--[[ CICLO DE VIDA ]]

function WeatherRoundService:construct()
	local waveService = self.Services.WaveService
	if not waveService or not waveService.Signals or not waveService.Signals.WaveStarted then
		warn("[WeatherRoundService]: WaveService sem o sinal WaveStarted; o clima nao vai entrar sozinho.")
		return
	end

	waveService.Signals.WaveStarted:Connect(function(waveNumber, preset, maxWaves)
		self:OnWaveStarted(waveNumber, preset, maxWaves)
	end)

	-- Quem entra no meio da partida precisa saber o que vem, se ainda vier.
	Framework:Listen("RequestWeatherWarning", function(player : Player)
		if not self.Scheduled or not self.ScheduledWave then return end

		local waveService = self.Services.WaveService
		local current = waveService and waveService.WaveCount or 0
		local wavesAhead = self.ScheduledWave - current
		if wavesAhead <= 0 then return end

		Framework:Fire("WeatherWarning", player, self.Scheduled, wavesAhead)
	end)
end

function WeatherRoundService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service)
	end

	self:construct()
end

function WeatherRoundService:init()
	Framework:Listen("WeatherWarning", function() end)
end

return WeatherRoundService
