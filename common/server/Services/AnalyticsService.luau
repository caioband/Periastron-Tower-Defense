local ServerScriptService = game:GetService("ServerScriptService")
local Analytics = game:GetService("AnalyticsService")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local ServerConfigs = ServerScriptService:WaitForChild("Config")

local ServerConfig = require(ServerConfigs)

local Config = ServerConfig.Analytics

--[[
	O único lugar do jogo que fala com a `AnalyticsService` da Roblox.

	Quem quer medir alguma coisa chama daqui — `:LogFunnelStep` para o funil de
	onboarding e `:LogEvent` para um evento avulso —, e nenhum outro arquivo
	precisa saber que a API existe, nem repetir as guardas que ela pede.

	**Três guardas, e todas moram aqui:**

	  1. **Studio e place não publicada.** A Roblox não aceita evento de analytics
	     vindo do Studio nem de um `.rbxl` solto (`PlaceId == 0`), e não aceita
	     nenhum vindo do cliente. Em vez de engolir a chamada, ela vira um `print`
	     com o número e o nome do passo: é assim que o roteiro inteiro se confere
	     no Studio, onde o painel não existe.
	  2. **`pcall` em toda chamada da engine**, como o `TeleportAsync` do
	     `TutorialService` já faz. Telemetria que derruba o passo do tutorial é
	     pior que telemetria nenhuma.
	  3. **Repetição.** A Roblox já conta só a primeira vez de cada passo por
	     usuário; a guarda em memória evita a chamada e, principalmente, deixa o
	     output honesto — passo impresso duas vezes no Studio seria um bug para
	     caçar que não existe.

	O `AnalyticsService` do `Framework:Get` é **este** módulo; a da Roblox é a
	`Analytics` do topo do arquivo, e é ela quem tem os `Log...`.
]]

local AnalyticsService = {}

-- [UserId] = { [nome do passo] = true }. Só o que este servidor já mandou.
AnalyticsService.Sent = {}

--[[ INTERNAL ]]

--[=[
	Esta place manda evento de verdade?

	`PlaceId == 0` é o arquivo que nunca foi publicado — a Roblox não teria onde
	pendurar o dado.
]=]
function AnalyticsService:enabled() : boolean
	return not RunService:IsStudio() and game.PlaceId ~= 0
end

--[=[
	O número do passo, pela ordem da lista.
]=]
function AnalyticsService:stepNumber(stepName : string) : number?
	for index, name in Config.Funnel.Onboarding do
		if name == stepName then
			return index
		end
	end

	return nil
end

--[=[
	As três chaves que a Roblox aceita em `customFields`, na ordem em que os campos
	chegam. Mais de três é descartado — o quarto não existe na API.
]=]
local FIELD_KEYS = {
	Enum.AnalyticsCustomFieldKeys.CustomField01,
	Enum.AnalyticsCustomFieldKeys.CustomField02,
	Enum.AnalyticsCustomFieldKeys.CustomField03,
}

function AnalyticsService:fields(values : { string }?) : { [any] : string }?
	if not values or #values == 0 then
		return nil
	end

	local fields = {}

	for index, value in values do
		local key = FIELD_KEYS[index]
		if not key then break end

		fields[key] = tostring(value)
	end

	return fields
end

--[[ API ]]

--[=[
	Um passo do funil de onboarding, pelo nome que ele tem em
	`ServerConfig.Analytics.Funnel.Onboarding`.

	Nome fora da lista não vira passo nenhum: avisa no output e para por aí. Mandar
	um número inventado seria pior — o painel passaria a ter um passo que ninguém
	sabe de onde veio.
]=]
function AnalyticsService:LogFunnelStep(player : Player, stepName : string)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then return end

	local step = self:stepNumber(stepName)
	if not step then
		warn(`[AnalyticsService]: o passo "{stepName}" nao esta em Config.Analytics.Funnel.Onboarding; nada foi registrado.`)

		return
	end

	local sent = self.Sent[player.UserId]
	if not sent then
		sent = {}
		self.Sent[player.UserId] = sent
	end

	if sent[stepName] then return end
	sent[stepName] = true

	if not self:enabled() then
		print(`[AnalyticsService]: (studio) passo {step} "{stepName}" de {player.Name}.`)

		return
	end

	local success, err = pcall(function()
		Analytics:LogOnboardingFunnelStepEvent(player, step, stepName)
	end)

	if not success then
		warn(`[AnalyticsService]: o passo {step} "{stepName}" de {player.Name} nao foi: {err}`)

		return
	end

	print(`[AnalyticsService]: passo {step} "{stepName}" de {player.Name}.`)
end

--[=[
	Um evento avulso — o que o funil não sabe dizer.

	`value` é o número que a Roblox soma (o padrão dela é 1), e `fields` é uma
	lista de até três textos, que entram nos `CustomField01..03`.
]=]
function AnalyticsService:LogEvent(player : Player, eventName : string, value : number?, fields : { string }?)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then return end

	local amount = value or 1
	local custom = self:fields(fields)

	if not self:enabled() then
		print(`[AnalyticsService]: (studio) evento "{eventName}" = {amount} de {player.Name}.`)

		return
	end

	local success, err = pcall(function()
		Analytics:LogCustomEvent(player, eventName, amount, custom)
	end)

	if not success then
		warn(`[AnalyticsService]: o evento "{eventName}" de {player.Name} nao foi: {err}`)

		return
	end

	print(`[AnalyticsService]: evento "{eventName}" = {amount} de {player.Name}.`)
end

--[[ CICLO DE VIDA ]]

function AnalyticsService:construct()
	-- O que já foi mandado só interessa enquanto o jogador está na sala: quem sai e
	-- volta cai noutro servidor, e a Roblox é quem sabe o que ele já fez.
	Players.PlayerRemoving:Connect(function(player : Player)
		self.Sent[player.UserId] = nil
	end)
end

function AnalyticsService:start()
	self:construct()
end

function AnalyticsService:init()
end

return AnalyticsService
