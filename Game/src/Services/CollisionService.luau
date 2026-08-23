local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PhysicsService = game:GetService("PhysicsService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Utils = Shared:WaitForChild("Util")

local PlacementUtil = require(Utils.PlacementUtil)

local Me = require(Vendor.Me)

local Framework = Me.new()

--[[
	Os grupos de colisão da place. Hoje, um só: o do fantasma do posicionamento.

	**Por que precisa de um service.** `RegisterCollisionGroup` só roda no servidor,
	e o fantasma é um modelo de cliente — o `UnitPlacementController` sabe pôr as
	parts no grupo, mas não sabe criá-lo. O registro replica para todo mundo, então
	basta acontecer uma vez, no boot.

	**Por que o fantasma precisa de grupo.** O rig da unidade é R6 e o Humanoid tem
	que ficar (sem ele o Highlight não renderiza em part transparente, que é como o
	jogador vê se dá para colocar ali). Só que Humanoid é quem manda na colisão de um
	personagem: ao avaliar um estado novo ele religa o `CanCollide` do torso, e o
	fantasma passa a empurrar o jogador. Desligar a máquina de estado resolve por
	tabela; o grupo resolve por definição — part num grupo que não colide com nada
	não colide com nada, dê o Humanoid o que der.

	O `UnitPlacementController` continua fazendo as duas coisas: as duas juntas custam
	uma linha cada e a segunda é o plano B se o registro daqui falhar.
]]

local CollisionService = {
	Services = {}
}

--[[ API ]]

--[=[
	Registra o grupo do fantasma e o declara não-colidível com todos os grupos —
	inclusive `Default`, onde vive o resto do jogo, e ele mesmo, para dois fantasmas
	não se esbarrarem.

	Grupo novo nasce colidindo com todos os existentes, então a volta é por cima da
	lista inteira. Grupo registrado **depois** deste não estaria coberto; hoje não
	existe nenhum outro, e o dia em que existir esta volta é onde olhar.
]=]
function CollisionService:RegisterGhostGroup()
	local group = PlacementUtil.GhostCollisionGroup

	if not PhysicsService:IsCollisionGroupRegistered(group) then
		PhysicsService:RegisterCollisionGroup(group)
	end

	-- `name` minusculo: e assim que `GetRegisteredCollisionGroups` devolve.
	for _, registered in PhysicsService:GetRegisteredCollisionGroups() do
		PhysicsService:CollisionGroupSetCollidable(group, registered.name, false)
	end
end

--[[ CICLO DE VIDA ]]

function CollisionService:construct()
	local ok, err = pcall(function()
		self:RegisterGhostGroup()
	end)

	if not ok then
		-- O fantasma nao fica sem defesa: o `CanCollide = false` e a maquina de
		-- estado desligada seguem valendo no cliente. Mas o motivo tem que aparecer,
		-- porque o sintoma (fantasma empurrando o jogador) e longe daqui.
		warn(`[CollisionService]: nao consegui registrar o grupo "{PlacementUtil.GhostCollisionGroup}": {err}`)
	end
end

function CollisionService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service)
	end
end

function CollisionService:init()
	self:construct()
end

return CollisionService
