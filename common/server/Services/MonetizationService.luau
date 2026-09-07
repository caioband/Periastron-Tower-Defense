local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")
local MarketplaceService = game:GetService("MarketplaceService")

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

local GamepassConfig = SharedConfig.GamepassConfig

local Framework = Me.new()

--[[
	Compras e gamepasses.

	As duas metades nao se parecem: uma compra de developer product e um **evento**
	que precisa ser creditado uma vez so (o `ProcessReceipt` e o `PurchaseHistory`
	cuidam disso), e uma gamepass e um **estado** que o jogador tem ou nao tem hoje.

	Por isso a pass nunca vira credito no perfil. O que fica gravado em
	`Data.Gamepasses` e uma copia do que a Roblox respondeu, reescrita inteira a cada
	entrada: quem leu antes nao precisa perguntar de novo, e uma pass reembolsada some
	sozinha no proximo login em vez de deixar um beneficio orfao. Quem consome sao as
	funcoes do `SharedConfig.GamepassConfig`, das duas pontas, sempre a partir do
	perfil.
]]
local MonetizationService = {
	Services = {
		DataService = {},
	}
}

function MonetizationService:construct()
	self.Callbacks = {}

	self:_watchPasses()

	MarketplaceService.ProcessReceipt = function(receiptInfo)
		local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
		if not player then
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end

		local profileLoaded = false
		self.Services.DataService:Get(player, function()
			profileLoaded = true
		end)
		if not profileLoaded then
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end

		local purchaseKey = "P_" .. tostring(receiptInfo.PurchaseId)

		local alreadyGranted = false
		self.Services.DataService:Update(player, "PurchaseHistory", function(history)
			history = history or {}
			alreadyGranted = history[purchaseKey] == true
			return history
		end)
		if alreadyGranted then
			return Enum.ProductPurchaseDecision.PurchaseGranted
		end

		local callback = self.Callbacks[tostring(receiptInfo.ProductId)]
		if not callback then
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end

		local granted = false
		local ok = pcall(function()
			granted = callback(player, receiptInfo) ~= false
		end)
		if not ok or not granted then
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end

		self.Services.DataService:Update(player, "PurchaseHistory", function(history)
			history = history or {}
			history[purchaseKey] = true
			return history
		end)

		if not self.Services.DataService:Save(player) then
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end

		return Enum.ProductPurchaseDecision.PurchaseGranted
	end
end

function MonetizationService:RegisterProduct(productId, callback)
	self.Callbacks[tostring(productId)] = callback
end

function MonetizationService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service, false, true)
	end

	self:construct()
end

--[=[
	Quem manda conferir as passes: a entrada de cada jogador, e a compra de uma pass
	no meio da sessao.

	O `PromptGamePassPurchaseFinished` e o que faz a pass valer **na hora**. Sem ele o
	jogador compraria o 2x Coins e so veria efeito no proximo login, o que parece a
	compra nao ter funcionado -- e o suporte que responde por isso.

	A conferencia da entrada espera o perfil (`DataService:Get`) porque ela escreve
	nele; num fio proprio, porque sao chamadas web e nada mais precisa esperar por
	elas.
]=]
function MonetizationService:_watchPasses()
	local function recalibrate(player : Player)
		self.Services.DataService:Get(player, function()
			task.spawn(function()
				self:RecalibratePasses(player)
			end)
		end)
	end

	for _, player in Players:GetPlayers() do
		recalibrate(player)
	end

	Players.PlayerAdded:Connect(recalibrate)

	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player : Player, gamePassId : number, purchased : boolean)
		if not purchased or not GamepassConfig.keyOfId(gamePassId) then
			return
		end

		task.spawn(function()
			self:RecalibratePasses(player)
		end)
	end)
end

--[=[
	Pergunta a Roblox uma pass so. Devolve `nil` -- e nao `false` -- quando a chamada
	falhou.

	A diferenca importa: `false` e "ele nao tem", e apaga o beneficio; `nil` e "nao deu
	para saber", e o `RecalibratePasses` mantem o que ja estava gravado. Uma queda da
	API nao pode tirar do jogador o que ele comprou.
]=]
function MonetizationService:_ownsPass(Player : Player, gamePassId : number) : boolean?
	local ok, owns = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(Player.UserId, gamePassId)
	end)

	if not ok then
		warn(string.format(
			"[MonetizationService]: nao deu para conferir a pass %d de %s (%s); mantendo o que o perfil ja diz.",
			gamePassId, Player.Name, tostring(owns)))
		return nil
	end

	return owns == true
end

--[=[
	Reescreve `Data.Gamepasses` com o que a Roblox responde agora, e publica no
	`Player` os atributos das passes que precisam ser vistas pelos **outros**.

	Roda uma pass por vez porque `UserOwnsGamePassAsync` e uma chamada web por pass --
	sao poucas, e elas rodam num fio proprio (ver `construct`), entao ninguem espera
	por isto.

	O atributo existe porque o perfil replica so para o dono: o rotulo do VIP tem de
	aparecer na mensagem dele na tela de todo mundo, e um atributo de `Player` replica
	para a sala inteira. Continua sendo o servidor quem escreve -- o cliente so le.
]=]
function MonetizationService:RecalibratePasses(Player : Player)
	local DataService = self.Services.DataService
	if not DataService or not DataService.Update then
		warn("[MonetizationService]: DataService indisponivel, nao da para conferir as passes.")
		return
	end

	--[[
		As respostas sao colhidas **antes** do `Update`, e nao dentro dele: o callback
		do `Update` nao pode ceder o fio (duas escritas simultaneas veriam o mesmo
		estado inicial), e cada `UserOwnsGamePassAsync` cede.
	]]
	local answers = {}
	for key, pass in GamepassConfig.PASSES do
		answers[key] = self:_ownsPass(Player, pass.Id)
	end

	-- Cada pergunta e uma chamada web, e o jogador pode ter saido no meio delas: sem
	-- isto o `Update` so avisaria que o perfil sumiu, uma linha por saida.
	if not DataService.Profiles or not DataService.Profiles[Player] then
		return
	end

	local owned

	DataService:Update(Player, "Gamepasses", function(current)
		current = typeof(current) == "table" and current or {}
		owned = {}

		for key in GamepassConfig.PASSES do
			local answer = answers[key]

			-- `nil` e "a chamada falhou": vale o que o perfil ja dizia.
			if answer == nil then
				owned[key] = current[key] == true or nil
			elseif answer then
				owned[key] = true
			end
		end

		return owned
	end)

	if not owned then
		return
	end

	for key, pass in GamepassConfig.PASSES do
		if pass.ChatTag then
			Player:SetAttribute(GamepassConfig.attributeName(key), owned[key] == true)
		end
	end
end

function MonetizationService:init()

end

return MonetizationService
