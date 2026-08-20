local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)

local Me = require(Vendor.Me)

local Framework = Me.new()

local Config = SharedConfig.WeatherConfig

--[[
	Áudio do clima, no cliente.

	As partículas e a iluminação chegam sozinhas — as primeiras pela replicação do
	`workspace.Weather`, a segunda pelo `LightingApplied`. Som não: ele é local de
	cada cliente, e é o que este controller cuida.

	- **ambiente**: enquanto o clima estiver ligado, o loop de
	  `WeatherConfig.Ambience` toca ao fundo, entrando e saindo com fade.
	- **estouro**: cada raio toca um clone próprio, com fade no fim para a cauda não
	  cortar seca. Sem `Key`, de propósito — dois raios seguidos se sobrepõem em vez
	  de um derrubar o outro.

	O estouro é 3D: quem chama é o `VFXController`, passando o Attachment da ponta do
	raio como pai, então o som sai de onde o raio bateu em vez de tocar no ouvido de
	todo mundo igual. A política de áudio (qual som, qual fade) fica aqui; o
	`VFXController` só entrega a âncora.

	Fica em `common/` como o `WeatherService`.
]]

local WeatherController = {
	Controllers = {
		MusicController = {}
	}
}

WeatherController.Current = nil :: string?

--[=[
	O clima que este cliente esta vendo, ou nil.

	E a fonte de verdade do cliente para os efeitos de clima: o alcance que o
	`TargetingController` usa para procurar alvo, o circulo que o
	`UnitPlacementController` desenha e os numeros do card saem todos daqui, com os
	multiplicadores do `WeatherConfig` por cima. O servidor faz a mesma conta com o
	valor dele, entao os dois lados mostram o mesmo numero.

	Quem precisa reagir a troca (redesenhar um circulo, atualizar um label) escuta
	o proprio `WeatherChanged`; este metodo e so para ler o estado atual.
]=]
function WeatherController:GetCurrent() : string?
	return self.Current
end

--[[ AMBIENTE ]]

function WeatherController:_stopAmbience(fade: number?)
	local music = self.Controllers.MusicController
	if not music then return end

	music:StopSFX(Config.AmbienceKey, fade)
end

--[=[
	Troca o som de fundo para o do clima pedido. `nil` desliga.
]=]
function WeatherController:SetWeather(name: string?)
	if name == self.Current then
		return
	end

	local previous = self.Current
	self.Current = name

	local music = self.Controllers.MusicController
	if not music then return end

	local ambience = name and Config.Ambience[name]

	if not ambience then
		-- Clima novo sem ambiente (ou clima nenhum): sai com o fade do que estava.
		local outgoing = previous and Config.Ambience[previous]
		self:_stopAmbience(outgoing and outgoing.Fade)
		return
	end

	--[[
		O `PlaySFX` com Key já derruba o anterior, mas cortado. Parar antes com o
		fade do clima que sai faz a troca de um clima para outro cruzar em vez de
		estalar.
	]]
	local outgoing = previous and Config.Ambience[previous]
	if outgoing then
		self:_stopAmbience(outgoing.Fade)
	end

	music:PlaySFX(ambience.Sound, {
		-- O asset não vem em loop, e ambiente sem loop acabaria no meio do clima.
		Looped = true,
		Key = Config.AmbienceKey,
		Fade = ambience.Fade,
		Volume = ambience.Volume,
	})
end

--[[ ESTOURO ]]

--[=[
	Estouro de um raio.

	`parent` é o Attachment da ponta do raio; o Sound vira filho dele e sai do ponto
	de impacto. Sem `parent` o som cai para 2D — não deveria acontecer no fluxo
	normal, mas um estouro no ouvido é melhor do que estouro nenhum.
]=]
function WeatherController:PlayStrikeSound(parent: Instance?)
	local music = self.Controllers.MusicController
	if not music then return end

	local thunder = Config.Thunder
	if not thunder.StrikeSound then return end

	music:PlaySFX(thunder.StrikeSound, {
		Parent = parent,
		FadeOut = thunder.StrikeFadeOut,
		Volume = thunder.StrikeVolume,
	})
end

--[[ CICLO DE VIDA ]]

function WeatherController:construct()
	Framework:Listen("WeatherChanged", function(name: string?)
		self:SetWeather(if typeof(name) == "string" then name else nil)
	end)

	-- Com que clima este cliente entrou: quem chega no meio da tempestade precisa
	-- do ambiente tocando.
	Framework:Fire("RequestWeather")
end

function WeatherController:start() end

function WeatherController:init()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	self:construct()
end

return WeatherController
