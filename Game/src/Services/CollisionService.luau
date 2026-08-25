local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PhysicsService = game:GetService("PhysicsService")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Utils = Shared:WaitForChild("Util")

local PlacementUtil = require(Utils.PlacementUtil)

local Me = require(Vendor.Me)

local Framework = Me.new()

--[[
	Como as parts participam de colisão e de consulta.

	Duas coisas moram aqui: os grupos de colisão da place — o do fantasma do
	posicionamento e o dos personagens de jogador, e o par entre os dois é o motivo
	de o segundo existir (o fantasma não empurra ninguém, e ninguém empurra o
	fantasma) — e o `CanQuery` dos acessórios, que sai por um motivo vizinho, logo
	abaixo.

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

	**Por que o personagem também precisa de grupo.** O fantasma já não colidia com
	`Default`, onde o personagem vivia — mas isso valia por tabela, e não por
	contrato: era consequência da volta que declara o fantasma não-colidível com
	tudo. Com um grupo próprio, "personagem não esbarra no fantasma" vira um par
	nomeado, e toda BasePart dos dois lados está nele. Do resto o personagem
	continua participando igual: mapa, unidades posicionadas e os outros
	personagens.

	**Por que o acessório sai das consultas.** Grupo de colisão resolve física, e
	acessório nunca foi problema de física — o problema dele é ser uma part
	*consultável* que sai metros fora do corpo. Chapéu e asa entravam nos
	`GetPartsInPart` do posicionamento e recusavam lugares que, na tela, estão
	vazios. Toda part de todo acessório de todo personagem perde o `CanQuery`, e a
	regra passa a valer para qualquer consulta do jogo — não só para as que se
	lembrarem de filtrar acessório na mão.

	Nenhuma consulta de hoje precisa enxergar acessório: o `FindBlockingCharacter`
	já os pulava de propósito, e o resto (chão dos passos, mira nos mobs, alcance
	das unidades) nunca olhou para eles.
]]

local CollisionService = {
	Services = {}
}

--[[ API ]]

--[=[
	Registra os grupos e declara o fantasma não-colidível com todos eles —
	inclusive `Default`, onde vive o resto do jogo, o dos personagens e ele mesmo,
	para dois fantasmas não se esbarrarem.

	Grupo novo nasce colidindo com todos os existentes, então a volta é por cima da
	lista inteira — e é por isso que o grupo do personagem é registrado **antes**
	dela. Registrar um grupo depois da volta o deixaria de fora, colidindo com o
	fantasma; é o que aconteceria com qualquer grupo novo que apareça daqui em
	diante, e esta função é onde olhar quando isso acontecer.
]=]
function CollisionService:RegisterGroups()
	local ghost = PlacementUtil.GhostCollisionGroup

	for _, group in { PlacementUtil.CharacterCollisionGroup, ghost } do
		if not PhysicsService:IsCollisionGroupRegistered(group) then
			PhysicsService:RegisterCollisionGroup(group)
		end
	end

	-- `name` minusculo: e assim que `GetRegisteredCollisionGroups` devolve.
	for _, registered in PhysicsService:GetRegisteredCollisionGroups() do
		PhysicsService:CollisionGroupSetCollidable(ghost, registered.name, false)
	end
end

--[=[
	Prepara as parts do personagem: **toda BasePart** entra no grupo dele, e a que
	for de acessório perde o `CanQuery` junto.

	`FindFirstAncestorOfClass("Accessory")` é a mesma pergunta que o
	`FindBlockingCharacter` faz para pular acessório — a diferença é que aqui ela é
	feita uma vez, na part, em vez de a cada consulta.

	`DescendantAdded` fica ligado porque o personagem não chega pronto: os
	acessórios entram depois do `CharacterAdded` (é o que o
	`CharacterAppearanceLoaded` anuncia), e uma ferramenta equipada no meio da
	partida também vira BasePart dentro do modelo. Sem o sinal, o chapéu ficaria no
	`Default`, esbarrando no fantasma e aparecendo nas consultas — que é justamente
	o caso que motivou os dois. O sinal chega depois de a part já estar no lugar,
	então a pergunta pela ancestralidade responde certo.

	A conexão morre junto com o personagem: o respawn destrói o modelo antigo, e
	`Destroy` desliga os sinais dele.
]=]
function CollisionService:ApplyCharacterParts(character : Model)
	local group = PlacementUtil.CharacterCollisionGroup

	local function apply(instance : Instance)
		if not instance:IsA("BasePart") then return end

		instance.CollisionGroup = group

		if instance:FindFirstAncestorOfClass("Accessory") then
			instance.CanQuery = false
		end
	end

	for _, descendant in character:GetDescendants() do
		apply(descendant)
	end

	character.DescendantAdded:Connect(apply)
end

--[=[
	Liga o de cima em quem já está no servidor e em quem chegar depois.

	`player.Character` é lido junto com o `CharacterAdded` de propósito: o service
	pode subir com o personagem já no Workspace (recarga do Studio, um `start`
	depois do primeiro spawn), e aí o sinal sozinho só pegaria o próximo respawn.
]=]
function CollisionService:trackPlayer(player : Player)
	player.CharacterAdded:Connect(function(character)
		self:ApplyCharacterParts(character)
	end)

	local character = player.Character
	if character then
		self:ApplyCharacterParts(character)
	end
end

--[[ CICLO DE VIDA ]]

function CollisionService:construct()
	local ok, err = pcall(function()
		self:RegisterGroups()
	end)

	if not ok then
		-- O fantasma nao fica sem defesa: o `CanCollide = false` e a maquina de
		-- estado desligada seguem valendo no cliente. Mas o motivo tem que aparecer,
		-- porque o sintoma (fantasma empurrando o jogador) e longe daqui.
		warn(`[CollisionService]: nao consegui registrar os grupos de colisao: {err}`)
		return
	end

	--[[
		So depois do registro: `CollisionGroup` com nome nao registrado estoura, e
		estourar aqui deixaria o personagem pela metade -- parte no grupo novo, parte
		no `Default`.
	]]
	for _, player in Players:GetPlayers() do
		self:trackPlayer(player)
	end

	Players.PlayerAdded:Connect(function(player)
		self:trackPlayer(player)
	end)
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
