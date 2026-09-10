local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")
local ServerConfigs = ServerScriptService:WaitForChild("Config")

local ServerConfig = require(ServerConfigs)

local Me = require(Vendor.Me)

local SharedConfig = require(Configs.SharedConfig)

local DifficultyConfig = ServerConfig.Difficulty
local UnlockConfig = SharedConfig.DifficultyUnlockConfig

local Framework = Me.new()

local ALL_VOTED_GRACE = 2

-- Ate quando vale a pena esperar o cliente de quem acabou de entrar avisar que
-- carregou. Passou disso, ele nao vai mais avisar.
local CLIENT_READY_TIMEOUT = 60

local DifficultyService = {
	Services = {
		MobService = {},

		-- De onde saem as vitorias por dificuldade e o XP que destravam os presets de
		-- cima. Ver `isUnlockedFor`.
		DataService = {}
	},
	Votes = {},
	Selected = nil,
	SelectionActive = false
}

function DifficultyService:GetSelected()
	return DifficultyConfig.Get(self.Selected)
end

--[=[
	Se este jogador ja pode votar nesta dificuldade.

	E a mesma conta que o `DifficultyController` usa para desenhar o cadeado, com o
	mesmo config -- e aqui ela vale de verdade: o voto e um nome, e um nome e o que
	qualquer cliente pode mandar. Sem esta linha, o Nightmare abriria para quem nunca
	ganhou uma partida, e bastaria **um** desses votos para arrastar a sala inteira
	para la.

	Perfil que ainda nao carregou conta como zero vitoria e nivel 1: aparece trancado,
	que e o lado seguro, e a tela do jogador esta mostrando a mesma coisa pela mesma
	conta.
]=]
function DifficultyService:isUnlockedFor(player : Player, difficultyName : string?) : boolean
	local dataService = self.Services.DataService
	local profiles = dataService and dataService.Profiles
	local entry = profiles and profiles[player]
	local stats = entry and entry.Profile.Data.Stats

	return UnlockConfig.isUnlocked(difficultyName, typeof(stats) == "table" and stats or nil)
end

function DifficultyService:timeLeft()
	if not self.SelectionEndsAt then return 0 end
	return math.max(0, math.ceil(self.SelectionEndsAt - os.clock()))
end

function DifficultyService:tally()
	local counts = {}
	for _, name in DifficultyConfig.Order do
		counts[name] = 0
	end

	for _, name in self.Votes do
		if counts[name] then
			counts[name] += 1
		end
	end

	return counts
end

function DifficultyService:allVoted()
	local players = Players:GetPlayers()
	if #players == 0 then return false end

	for _, player in players do
		if not self.Votes[player.UserId] then
			return false
		end
	end

	return true
end

function DifficultyService:winner()
	local counts = self:tally()
	local best = nil
	local bestCount = 0

	for _, name in DifficultyConfig.Order do
		if counts[name] > bestCount then
			best = name
			bestCount = counts[name]
		end
	end

	return best or DifficultyConfig.Default
end

--[=[
	O estado como este jogador o ve: o voto e de cada um, o resto e do servidor.
	`locked` e o que diz se a partida ja comecou — enquanto for `nil` ninguem
	escolheu dificuldade nenhuma.
]=]
function DifficultyService:stateFor(player : Player, timeLeft : number?, counts : { [string] : number }?)
	return {
		active = self.SelectionActive == true,
		options = DifficultyConfig.Order,
		votes = counts or self:tally(),
		timeLeft = timeLeft,
		selected = self.Votes[player.UserId],
		locked = self.Selected,
	}
end

function DifficultyService:broadcastSelectionState(timeLeft)
	local counts = self:tally()
	for _, player in Players:GetPlayers() do
		Framework:Fire("DifficultySelection", player, self:stateFor(player, timeLeft, counts))
	end
end

--[=[
	Manda o estado atual para quem acabou de entrar. A votacao so fala enquanto
	esta aberta, entao sem isto quem cai num round que ja comecou nunca receberia
	um `DifficultySelection` — e a hotbar dele, que so aparece com a dificuldade
	decidida, ficaria escondida a partida inteira.

	Espera a tag `ClientReady` que o `DataService` poe quando o cliente avisa que
	carregou: antes dela o controller do outro lado ainda nem esta escutando.
]=]
function DifficultyService:syncPlayer(player : Player)
	local deadline = os.clock() + CLIENT_READY_TIMEOUT

	while not player:HasTag("ClientReady") do
		if os.clock() > deadline or not player:IsDescendantOf(Players) then
			return
		end
		task.wait(0.25)
	end

	Framework:Fire("DifficultySelection", player, self:stateFor(player, self:timeLeft()))
end

function DifficultyService:RunSelection(duration)
	self.Votes = {}
	self.Selected = nil
	self.SelectionActive = true
	self.SelectionEndsAt = os.clock() + duration

	self:broadcastSelectionState(self:timeLeft())

	local lastShown = nil
	local shortened = false
	while os.clock() < self.SelectionEndsAt do
		if not shortened and self:allVoted() then
			shortened = true
			self.SelectionEndsAt = math.min(self.SelectionEndsAt, os.clock() + ALL_VOTED_GRACE)
		end

		local remaining = self:timeLeft()
		if remaining ~= lastShown then
			lastShown = remaining
			self:broadcastSelectionState(remaining)
		end
		task.wait(0.2)
	end

	self.Selected = self:winner()
	self.SelectionActive = false
	self:broadcastSelectionState(0)

	local preset = self:GetSelected()

	local mobService = self.Services.MobService
	if mobService then
		mobService:ApplyDifficulty(preset)
	end

	for _, player in Players:GetPlayers() do
		Framework:Fire("DifficultyLocked", player, preset.Name)
	end

	return preset
end

--[=[
	Devolve o service ao estado de antes da votacao. A dificuldade escolhida cai
	junto: o proximo round vota de novo.
]=]
function DifficultyService:ResetRound()
	table.clear(self.Votes)
	self.Selected = nil
	self.SelectionActive = false
	self.SelectionEndsAt = nil

	self:broadcastSelectionState(0)
end

function DifficultyService:construct()
	Framework:Listen("SelectDifficulty", function(player, difficultyName)
		if not self.SelectionActive then return end
		if not DifficultyConfig.Exists(difficultyName) then return end

		if not self:isUnlockedFor(player, difficultyName) then
			warn(string.format(
				"[DifficultyService]: %s votou em %s, que ainda esta trancada para ele.",
				player.Name, difficultyName))
			return
		end

		if self.Votes[player.UserId] == difficultyName then
			self.Votes[player.UserId] = nil
		else
			self.Votes[player.UserId] = difficultyName
		end

		self:broadcastSelectionState(self:timeLeft())
	end)

	Players.PlayerAdded:Connect(function(player)
		task.spawn(function()
			self:syncPlayer(player)
		end)
	end)

	Players.PlayerRemoving:Connect(function(player)
		self.Votes[player.UserId] = nil
	end)
end

function DifficultyService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service)
	end

	self:construct()
end

function DifficultyService:init()
	Framework:Listen("DifficultySelection", function() end)
	Framework:Listen("DifficultyLocked", function() end)
end

return DifficultyService
