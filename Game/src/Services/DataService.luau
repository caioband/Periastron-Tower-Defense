local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local ServerVendor = ServerScriptService:WaitForChild("Vendor")
local ServerConfigs = ServerScriptService:WaitForChild("Config")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)
local ServerConfig = require(ServerConfigs)

local Maid = require(Vendor.Maid)
local Promise = require(Packages.Promise)
local Warp = require(Vendor.Warp)
local Me = require(Vendor.Me)
local Signal = require(Packages.Signal)

local ProfileStore = require(ServerVendor.ProfileStore)
local Replica = require(ServerVendor.ReplicaServer)

local Framework = Me.new()

local DataService = {
	Signals = {
		PlayerDataLoaded = Signal.new()
	}
}

local function copyTemplateValue(value)
	if typeof(value) ~= "table" then
		return value
	end

	local copy = {}
	for key, childValue in value do
		copy[key] = copyTemplateValue(childValue)
	end

	return copy
end

local function reconcileTemplate(data, template)
	for key, templateValue in template do
		if data[key] == nil then
			data[key] = copyTemplateValue(templateValue)
		elseif typeof(data[key]) == "table" and typeof(templateValue) == "table" then
			reconcileTemplate(data[key], templateValue)
		end
	end
end

--[=[
	O perfil foi tomado por outro servidor (ou a sessão caiu) com o jogador ainda
	aqui. Daqui em diante nada do que ele fizesse seria salvo — o perfil já não é
	deste servidor —, então ele sai, com o aviso para entrar de novo.

	Quem costuma tomar é a sessão curta do `ProfileEditService` (comando de admin
	num jogador que acabou de entrar) ou o jogador entrando em outro servidor antes
	de este soltar o perfil.
]=]
local SESSION_LOST_MESSAGE = "Your data was opened somewhere else. Please rejoin."

-- Quanto o `CreatePlayer` espera a sessão curta do `ProfileEditService` soltar a
-- chave antes de tentar mesmo assim.
local OFFLINE_SESSION_WAIT = 20

function DataService:construct()
	self.Profiles = {}

	-- `{ [UserId] = true }` enquanto o `ProfileEditService` segura o perfil de alguém
	-- que não está no servidor. Ver `CreatePlayer`.
	self.OfflineSessions = {}
	self.BeforeRelease = self.BeforeRelease or {}
	self.Packages = {
		ReplicaToken = Replica.Token("PlayerData"),
		ProfileManager = ProfileStore.New(
			ServerConfig.Data.PROFILE_KEY,
			ServerConfig.Data.Template
		)
	}
	return true
end

function DataService:CreatePlayer(Player : Player)
	local profileKey = "Player_" .. Player.UserId

	--[[
		O ProfileStore recusa abrir a mesma chave duas vezes no mesmo servidor: se um
		comando de admin está com o perfil deste jogador aberto numa sessão curta,
		espera ela fechar (é questão de segundos).
	]]
	local deadline = os.clock() + OFFLINE_SESSION_WAIT
	while self.OfflineSessions[Player.UserId] and os.clock() < deadline do
		task.wait(0.1)
	end

	local Session = self.Packages.ProfileManager:StartSessionAsync(profileKey) :: typeof(ProfileStore.New():StartSessionAsync())

	-- Saiu enquanto o perfil carregava: solta na hora, senão a sessão fica presa
	-- até o servidor fechar e o jogador não entra em outro.
	if Session ~= nil and Player.Parent ~= Players then
		Session:EndSession()
		return
	end

	if Session ~= nil then
		reconcileTemplate(Session.Data, ServerConfig.Data.Template)

		local ReplicaProfile = Replica.New({
			Token = self.Packages.ReplicaToken,
			Player = Player,
			Data = Session.Data,
			Tags = {
				Player = Player
			},
		})

		ReplicaProfile:Replicate()
		ReplicaProfile:FireAllClients()

		local entry = {
			Profile = ReplicaProfile,
			Session = Session,

			-- `true` quando quem fecha é o `Destroy` (saída normal), para o
			-- `OnSessionEnd` não confundir com perfil tomado.
			Releasing = false,
		}
		self.Profiles[Player] = entry

		Session.OnSessionEnd:Connect(function()
			if entry.Releasing or self.Profiles[Player] ~= entry then
				return
			end

			-- No desligamento o próprio ProfileStore fecha todas as sessões; aí quem
			-- solta o jogador é o `BindToClose`, com os callbacks de saída rodando.
			if ProfileStore.IsClosing then
				return
			end

			warn(string.format("[DataService]: a sessao de %s acabou com ele no servidor; expulsando.", Player.Name))

			self.Profiles[Player] = nil
			entry.Profile:Destroy()
			Player:Kick(SESSION_LOST_MESSAGE)
		end)

		--[[
			Edições de admin que chegam por mensagem (`ProfileEditService`): as que
			estavam esperando no perfil e as que chegarem com ele aberto. Com espera
			no `Get` porque o service pode ainda não ter subido na primeira leva.
		]]
		Session:MessageHandler(function(message, processed)
			local editor = Framework:Get("ProfileEditService", false, true)
			if self.Profiles[Player] == entry then
				editor:ApplyMessageToPlayer(Player, message, processed)
			end
		end)

		print("Player User data has been loaded", self.Profiles[Player])
		self.Signals.PlayerDataLoaded:Fire(Player)
	end
end


function DataService:Get(Player : Player, callbackFunc)
	if self.Profiles[Player] then
		callbackFunc(self.Profiles[Player].Profile.Data)
		return
	end

	local waitConnection
	waitConnection = self.Signals.PlayerDataLoaded:Connect(function(player)
		if player == Player then
			waitConnection:Disconnect()
			waitConnection = nil
			callbackFunc(self.Profiles[Player].Profile.Data)
		end
	end)

	task.delay(ServerConfig.Data.MAX_DATA_TIME_OUT, function()
		if waitConnection ~= nil then
			waitConnection:Disconnect()
			waitConnection = nil
		end
	end)
end

--[=[
	Registra algo para acontecer com o perfil ainda aberto, no instante anterior
	ao fechamento da sessao -- por exemplo creditar a recompensa de quem sai no
	meio de um round.

	Todo caminho de saida passa pelo `Destroy`: o `PlayerRemoving` de quem sai
	sozinho e o `BindToClose` do desligamento do servidor. Registrar aqui cobre os
	dois de uma vez e, principalmente, nao depende da ordem em que os services
	conectaram o proprio `PlayerRemoving` -- um credito feito depois do
	`EndSession` seria escrito num perfil ja fechado e se perderia.

	`order` (0 por padrao) e para quem precisa **ler** o perfil depois de todo
	mundo que ainda escreve nele: rodam do menor para o maior, e na ordem de
	registro dentro do mesmo numero. O `LeaderboardService` usa 1 para pegar o
	perfil ja com a recompensa de saida e o tempo final dentro -- sem isso, a ordem
	dependeria de qual service subiu primeiro.
]=]
function DataService:OnBeforeRelease(callback : (Player) -> (), order : number?)
	if not self.BeforeRelease then
		self.BeforeRelease = {}
	end

	table.insert(self.BeforeRelease, {
		Callback = callback,
		Order = order or 0,
		Index = #self.BeforeRelease + 1,
	})

	table.sort(self.BeforeRelease, function(a, b)
		if a.Order ~= b.Order then
			return a.Order < b.Order
		end

		return a.Index < b.Index
	end)
end

function DataService:Destroy(Player : Player)
	local entry = self.Profiles[Player]
	if not entry then return end

	-- Um pcall por callback: erro em qualquer um deles nao pode impedir a sessao
	-- de fechar, senao o perfil fica preso e o jogador nao entra em outro servidor.
	for _, hook in self.BeforeRelease or {} do
		local ok, err = pcall(hook.Callback, Player)
		if not ok then
			warn(string.format("[DataService]: callback de saida falhou para %s: %s", Player.Name, tostring(err)))
		end
	end

	entry.Releasing = true
	entry.Session:EndSession()
	entry.Profile:Destroy()
	self.Profiles[Player] = nil
end

function DataService:Update(Player : Player, Key : string, callbackFunc)
	if not self.Profiles[Player] then
		warn(string.format("Attempted to update data for %s, but profile is not loaded!", Player.Name))
		return
	end

	local replicaProfile = self.Profiles[Player].Profile
	local currentData = replicaProfile.Data[Key]

	local editedData = callbackFunc(currentData)
	if editedData == nil then
		warn(string.format("Update callback for %s returned nil; keeping existing data.", Key))
		return currentData
	end

	replicaProfile:Set({Key}, editedData)
	return editedData
end

function DataService:Save(Player : Player)
	local entry = self.Profiles[Player]
	if not entry then return false end
	local ok = pcall(function()
		entry.Session:Save()
	end)
	return ok
end

function DataService:init()
	self:construct()

	local serverMaid = Maid.new()
	for _, player in Players:GetPlayers() do
		self:CreatePlayer(player)
	end

	serverMaid:GiveTask(Players.PlayerAdded:Connect(function(player)
		self:CreatePlayer(player)
	end))

	serverMaid:GiveTask(Players.PlayerRemoving:Connect(function(player)
		self:Destroy(player)
	end))

	game:BindToClose(function()
		for _, player in Players:GetPlayers() do
			task.spawn(function()
				self:Destroy(player)
			end)
		end
		task.wait(2)
		serverMaid:DoCleaning()
	end)

	Framework:Listen("Loaded", function(Player : Player)
		Player:AddTag("ClientReady")
	end)
end

function DataService:start()

end

return DataService
