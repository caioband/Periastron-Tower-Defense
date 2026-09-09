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

	**Ele sorteia da pool de cada alvo**, e não do catálogo: as cartas que aquele
	jogador destravou na loja de cartas do lobby. Quem não destravou nenhuma não
	recebe oferta, e é por isso que o comando pode não abrir nada mesmo com alvos
	válidos — para dar carta a alguém, o caminho é o perfil (`Data.RoundCards`), e não
	este comando.

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

	--[[
		`Open` só devolve true quando **alguém** recebeu oferta. Os dois motivos para não
		receber são diferentes, e o de baixo é o comum: nenhum dos alvos destravou carta
		nenhuma. O outro (catálogo sem efeito registrado) já sai como aviso no output do
		servidor quando isso acontece.
	]]
	if not CardShopService:Open(targets) then
		return "Nothing to offer: no target has any round card unlocked (see the lobby card shop)."
	end

	local names = {}
	for _, player in targets do
		table.insert(names, player.Name)
	end

	return string.format("Round card shop opened for %s.", table.concat(names, ", "))
end
