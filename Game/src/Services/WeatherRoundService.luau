local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)

local Me = require(Vendor.Me)
local Signal = require(Packages.Signal)

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

		1. o clima que a carta Weather Report apagou na wave passada volta, se ainda
		   tiver prazo (ver `SkipCurrentWave`);
		2. o clima que já estava no ar sai, se a duração dele acabou;
		3. o clima que estava agendado para esta wave entra;
		4. não havendo nada agendado nem no ar, joga-se um dado — e passando, um
		   clima do pool do mapa é escolhido e **avisado** para `LeadWaves` waves
		   à frente.

	O passo 1 vem antes do 2 porque os dois se encontram no mesmo caso: a carta
	usada na última wave de um clima não tem o que repor, e é o passo 2 que fecha a
	conta — o mesmo fim que qualquer clima tem.

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
	},

	Signals = {
		--[[
			(weatherName) -- um clima do round entrou no ar. So o que entra de verdade:
			o aviso nao conta, e o clima que a carta Weather Report apagou e volta na wave
			seguinte tambem nao (e o mesmo clima). Quem escuta e o
			`ContractTrackerService` ("Experience Weathers 60 times").
		]]
		WeatherStarted = Signal.new(),
	},
}

-- Clima no ar por decisão deste service, e a última wave em que ele vale.
WeatherRoundService.Active = nil :: string?
WeatherRoundService.ActiveUntilWave = nil :: number?

-- Clima avisado e ainda não aplicado, e a wave em que ele entra.
WeatherRoundService.Scheduled = nil :: string?
WeatherRoundService.ScheduledWave = nil :: number?

-- A wave cujo clima a carta Weather Report apagou. Ver `SkipCurrentWave`.
WeatherRoundService.SkippedWave = nil :: number?

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
	--[[
		A wave-alvo vai junto do "faltam quantas".

		O aviso na tela usa o número pronto, e é por isso que ele existe; o indicador
		do HUD, que responde a um clique **depois** — uma, duas waves depois —, precisa
		refazer a conta com a wave de agora, e para isso ele precisa do alvo. Contar
		sozinho a partir do `wavesAhead` daria errado justamente quando importa: este
		aviso e o `SetWave` da mesma wave saem em eventos diferentes, e a ordem em que
		eles chegam ao cliente não é garantida.
	]]
	for _, player in Players:GetPlayers() do
		Framework:Fire("WeatherWarning", player, weatherName, wavesAhead, self.ScheduledWave)
	end
end

--[=[
	Diz aos clientes ate que wave o clima de agora vale.

	`ActiveUntilWave` e uma wave-alvo, e e ela que viaja — nao o "faltam quantas". O
	painel do indicador e aberto **depois**, uma ou duas waves depois, e refaz a conta
	com a wave de agora; mandar o numero pronto daria um painel dizendo "ENDS IN 4
	WAVES" na ultima wave do clima.

	O **nome vai junto** porque este aviso e o `WeatherChanged` sao eventos diferentes
	e a ordem entre eles nao e garantida: e o nome que diz ao cliente se o prazo que
	chegou e do clima que ele esta vendo.

	Ceu limpo manda os dois `nil`, para o cliente nao ficar com o prazo do clima que
	acabou de sair.

	`player` restringe a um jogador so — e o que o pedido de quem entra no meio da
	partida precisa.
]=]
function WeatherRoundService:broadcastDuration(player : Player?)
	local weatherName = self.Active
	local untilWave = weatherName and self.ActiveUntilWave or nil

	if player then
		Framework:Fire("WeatherDuration", player, weatherName, untilWave)
		return
	end

	for _, target in Players:GetPlayers() do
		Framework:Fire("WeatherDuration", target, weatherName, untilWave)
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

	self:broadcastDuration()

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

	self:broadcastDuration()

	roundPrint(string.format("'%s' entrou na wave %d, ate a %d.", weatherName, waveNumber, self.ActiveUntilWave))

	self.Signals.WeatherStarted:Fire(weatherName)
end

--[=[
	Poe de volta no céu o clima que a carta apagou, quando ele ainda tinha wave pela
	frente.

	Falhar aqui derruba o `Active`: o clima não está no céu e continuar contando as
	waves dele faria o service prometer um fim para uma coisa que não começou -- e,
	pior, segurar o sorteio do próximo até essa data.
]=]
function WeatherRoundService:resumeActive(waveNumber : number)
	local weatherName = self.Active
	if not weatherName then return end

	local weatherService = self.Services.WeatherService
	if not weatherService then return end

	local ok, message = weatherService:Apply(weatherName, RoundConfig.TransitionTime)
	if not ok then
		warn(string.format("[WeatherRoundService]: nao consegui repor '%s' (%s).", weatherName, tostring(message)))

		self.Active = nil
		self.ActiveUntilWave = nil
		self:broadcastDuration()
		return
	end

	self:broadcastDuration()

	roundPrint(string.format("'%s' voltou na wave %d, ate a %d.", weatherName, waveNumber, self.ActiveUntilWave or waveNumber))
end

--[=[
	Tira o clima do céu **nesta wave, e só nesta**. Quem chama é o `CardShopService`
	(carta Weather Report).

	A carta é um guarda-chuva para uma wave, e não um cancelamento do clima: uma
	tempestade de três waves comprada na primeira continua nas outras duas, e o
	jogador que quiser as três limpas compra três cartas. Comprada na última wave
	dela, o clima simplesmente acaba ali -- não há o que voltar.

	Por isso o `Active` e o `ActiveUntilWave` **não** são zerados, e o `ClearActive`
	não é chamado: o `Clear` do `WeatherService` tira o clima do céu agora, e o
	`OnWaveStarted` da wave seguinte o repõe pelo `resumeActive` se ainda houver
	prazo. Zerar o estado aqui seria apagar justamente a memória de que ele tem que
	voltar.

	Céu limpo devolve `false` e nada acontece: não há wave de clima para pular.

	O aviso de um clima agendado também não é tocado -- ele entra na wave dele, como
	entraria. A carta fala sobre a wave que está no ar, e não sobre o futuro.
]=]
function WeatherRoundService:SkipCurrentWave() : boolean
	local weatherService = self.Services.WeatherService
	if not weatherService or not weatherService:GetCurrent() then
		roundPrint("Weather Report usado com o ceu ja limpo: nada a pular.")
		return false
	end

	local waveService = self.Services.WaveService
	local current = (waveService and waveService.WaveCount) or 0

	self.SkippedWave = current

	weatherService:Clear(RoundConfig.TransitionTime)

	if self.Active and self.ActiveUntilWave and current < self.ActiveUntilWave then
		roundPrint(string.format("'%s' pulou a wave %d; volta na %d, ate a %d.",
			self.Active, current, current + 1, self.ActiveUntilWave))
	else
		roundPrint(string.format("ceu limpo na wave %d.", current))
	end

	return true
end

--[=[
	O passo de uma wave. Chamado pelo sinal `WaveStarted` do `WaveService`.

	A ordem importa: o clima velho sai e o novo entra **antes** do dado, para o
	dado enxergar o estado desta wave e não o da anterior.
]=]
function WeatherRoundService:OnWaveStarted(waveNumber : number, _preset, maxWaves : number)
	--[[
		A wave que o Weather Report apagou ficou para trás.

		O clima volta **antes** do teste de prazo logo abaixo, e não depois: se a wave
		pulada era a última dele, `waveNumber` já passou do `ActiveUntilWave`, o
		`resumeActive` não roda e é o `ClearActive` que fecha a conta -- que é o fim
		normal de qualquer clima, e não um caso à parte da carta.
	]]
	if self.SkippedWave and waveNumber > self.SkippedWave then
		self.SkippedWave = nil

		if self.ActiveUntilWave and waveNumber <= self.ActiveUntilWave then
			self:resumeActive(waveNumber)
		end
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
	self.SkippedWave = nil
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

		Framework:Fire("WeatherWarning", player, self.Scheduled, wavesAhead, self.ScheduledWave)
	end)

	-- Quem entra no meio de uma tempestade precisa do prazo dela. Ceu limpo responde
	-- com `nil`, que e a resposta certa e nao um silencio.
	Framework:Listen("RequestWeatherDuration", function(player : Player)
		self:broadcastDuration(player)
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
	Framework:Listen("WeatherDuration", function() end)
end

return WeatherRoundService
