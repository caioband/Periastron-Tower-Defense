local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Me = require(Vendor:WaitForChild("Me"))

local Framework = Me.new()

--[[
	Faz a loja de cartas aparecer na hora, sem esperar a wave certa.

	É o mesmo `Open` que o `WaveStarted` chama de X em X waves (ver
	`RoundCardConfig.Intervals`): as três cartas são sorteadas de novo e a oferta
	anterior de quem estava com a loja aberta perde a validade — o `Token` sobe, e
	um clique atrasado na loja velha não compra nada da nova.

	Só a Game tem loja: o `CardShopService` não existe no Lobby, e lá o
	`Framework:Get` com yield esperaria para sempre.
]]
return function(_context, players : { Player }?)
	local CardShopService = Framework:Get("CardShopService", false, true)

	local targets = players
	if not targets or #targets == 0 then
		targets = Players:GetPlayers()
	end

	if #targets == 0 then
		return "Nobody matched."
	end

	if not CardShopService:Open(targets) then
		return "No round card has a registered effect; nothing to offer."
	end

	local names = {}
	for _, player in targets do
		table.insert(names, player.Name)
	end

	return string.format("Round card shop opened for %s.", table.concat(names, ", "))
end
