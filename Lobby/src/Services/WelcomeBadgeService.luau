local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Me = require(Vendor.Me)

local Framework = Me.new()

--[[
	O badge `Welcome`: a primeira vez que o jogador entra no jogo.

	"Primeira vez" é o próprio badge quem guarda — a Roblox sabe se o jogador já tem,
	e o `BadgeService` pergunta antes de dar. Por isso isto roda em toda entrada, e
	não depende de nenhuma marca no perfil (que zera quando a `PROFILE_KEY` muda).

	**Por que no `PlayerAdded` e não no `PlayerDataLoaded`.** O badge não depende do
	perfil; esperar por ele só atrasaria o badge para quem cai com o perfil travado
	em outra sessão.

	**Por que fica só na Lobby.** A Game nunca é a primeira place que o jogador vê:
	ele sempre passa pelo lobby antes.
]]

local BADGE_NAME = "Welcome"

local WelcomeBadgeService = {
	Services = {
		BadgeService = {}
	}
}

--[[ CICLO DE VIDA ]]

function WelcomeBadgeService:construct()
	local badgeService = self.Services.BadgeService
	if not badgeService then
		warn("[WelcomeBadgeService]: sem BadgeService; o badge de boas-vindas não sai.")
		return
	end

	local function award(player : Player)
		badgeService:Award(player, BADGE_NAME)
	end

	Players.PlayerAdded:Connect(function(player : Player)
		task.spawn(award, player)
	end)

	-- Quem entrou antes do `PlayerAdded` estar ligado.
	for _, player in Players:GetPlayers() do
		task.spawn(award, player)
	end
end

function WelcomeBadgeService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service, false, true)
	end

	self:construct()
end

function WelcomeBadgeService:init()
end

return WelcomeBadgeService
