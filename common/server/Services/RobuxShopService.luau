local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)

local Me = require(Vendor.Me)

local RobuxShopConfig = SharedConfig.RobuxShopConfig

local Framework = Me.new()

--[[
	Quem paga os packs de coins da loja de Robux (`StarterGui.ShopUI.RobuxShop`).

	A vitrine e do `RobuxShopController`, e ela nao credita nada: o clique so abre o
	prompt. O que chega aqui e o **recibo**, pelo `MonetizationService`, que ja cuidou
	do que um recibo tem de ter -- o perfil aberto, o `PurchaseHistory` para o mesmo
	`PurchaseId` nao pagar duas vezes, e o save antes de dizer `PurchaseGranted`.
	Devolver `false` daqui e "nao deu para creditar agora": o recibo volta como
	`NotProcessedYet` e a Roblox tenta de novo.

	Mora em `common/` porque um recibo pendente volta **onde o jogador estiver**, e ele
	pode ter ido para a partida antes de ele ser processado -- e a mesma razao dos
	rerolls dos contratos. As gamepasses da mesma loja nao passam por aqui: pass e
	estado, e quem confere e o `MonetizationService:RecalibratePasses`.

	O deposito e so no `Stats.Cash`. O `Stats.CoinsEarned` (a board MOST COINS) fica de
	fora de proposito: ela e o que o jogador ganhou jogando, e nao o que ele comprou.
]]
local RobuxShopService = {
	Services = {
		CurrencyService = {},
		MonetizationService = {},
	},
}

--[[ EXTERNAL ]]

--[=[
	Deposita um pack no saldo. `false` quando nao deu -- perfil que ainda nao abriu, o
	jogador que saiu no meio --, e ai o recibo volta mais tarde.
]=]
function RobuxShopService:Grant(player : Player, pack) : boolean
	local currency = self.Services.CurrencyService

	if not currency then
		warn("[RobuxShopService]: sem CurrencyService; o pack nao pode ser creditado agora.")
		return false
	end

	local _, updated, reason = currency:Apply(player, "Cash", "add", pack.Coins)

	if not updated then
		warn(string.format(
			"[RobuxShopService]: nao deu para creditar %d coins a %s (%s); o recibo volta.",
			pack.Coins, player.Name, tostring(reason)))
		return false
	end

	return true
end

function RobuxShopService:construct()
	local monetization = self.Services.MonetizationService

	if not monetization then
		warn("[RobuxShopService]: sem MonetizationService; os packs de coins nao vao ser creditados.")
		return
	end

	for _, pack in RobuxShopConfig.PACKS do
		monetization:RegisterProduct(pack.ProductId, function(player : Player)
			return self:Grant(player, pack)
		end)
	end
end

function RobuxShopService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service, false, true)
	end

	self:construct()
end

function RobuxShopService:init()

end

return RobuxShopService
