local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local RobloxBadges = game:GetService("BadgeService")

local ServerConfig = require(ServerScriptService:WaitForChild("Config"))

--[[
	Entrega os badges da Roblox listados em `ServerConfig.Badges`. É a única porta:
	quem quiser dar um badge chama `BadgeService:Award(player, "Nome")` e não fala
	com a API da Roblox direto.

	**Por que perguntar antes de dar.** `AwardBadge` num badge que o jogador já tem
	não quebra nada, mas gasta a mesma cota; o `UserHasBadgeAsync` é barato e a
	maioria das chamadas é de quem já ganhou. A resposta fica guardada pela sessão,
	então o mesmo badge não é consultado duas vezes para o mesmo jogador.

	**Retry.** A API de badges falha de vez em quando sob carga; cada chamada tenta
	`MAX_ATTEMPTS` vezes antes de desistir com um `warn`.

	**Studio.** A Roblox não entrega badge no Studio, então `Award` não faz nada lá.

	`Award` pode esperar (é uma chamada de rede); quem não quer esperar chama dentro
	de um `task.spawn`.
]]

local MAX_ATTEMPTS = 3
local RETRY_DELAY = 2

local BadgeService = {
	Services = {}
}

--[[ INTERNAL ]]

local function withRetry(label : string, callback : () -> any) : (boolean, any)
	local ok, result
	for attempt = 1, MAX_ATTEMPTS do
		ok, result = pcall(callback)
		if ok then
			return true, result
		end
		if attempt < MAX_ATTEMPTS then
			task.wait(RETRY_DELAY)
		end
	end

	warn(`[BadgeService]: {label} falhou {MAX_ATTEMPTS}x: {result}`)
	return false, result
end

--[[ API ]]

--[=[
	Dá o badge `name` (a chave em `ServerConfig.Badges`) ao jogador, se ele ainda
	não tiver. Devolve `true` se o jogador termina com o badge — seja porque ganhou
	agora, seja porque já tinha.
]=]
function BadgeService:Award(player : Player, name : string) : boolean
	local badgeId = ServerConfig.Badges[name]
	if not badgeId then
		warn(`[BadgeService]: badge "{name}" não existe em ServerConfig.Badges.`)
		return false
	end

	if RunService:IsStudio() then
		return false
	end

	local owned = self.Owned[player]
	if not owned then
		owned = {}
		self.Owned[player] = owned
	end
	if owned[badgeId] then
		return true
	end

	local okHas, hasBadge = withRetry(`UserHasBadgeAsync({name})`, function()
		return RobloxBadges:UserHasBadgeAsync(player.UserId, badgeId)
	end)
	if not okHas then
		return false
	end

	-- O jogador pode ter saído durante a consulta.
	if player.Parent ~= Players then
		return false
	end

	if not hasBadge then
		local okAward, awarded = withRetry(`AwardBadge({name})`, function()
			return RobloxBadges:AwardBadge(player.UserId, badgeId)
		end)
		if not okAward or not awarded then
			return false
		end
	end

	-- Só grava se a sessão do jogador ainda for a mesma tabela (não saiu no meio).
	if self.Owned[player] == owned then
		owned[badgeId] = true
	end

	return true
end

--[[ CICLO DE VIDA ]]

function BadgeService:construct()
	Players.PlayerRemoving:Connect(function(player : Player)
		self.Owned[player] = nil
	end)
end

function BadgeService:start()
end

function BadgeService:init()
	-- [Player] = { [badgeId] = true }: o que já se sabe que o jogador tem.
	self.Owned = {}

	self:construct()
end

return BadgeService
