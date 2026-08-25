--[[
	O que o posicionamento pergunta sobre o caminho.

	Mora aqui, e nao em cada lado, porque a pergunta e feita duas vezes: o cliente
	faz para pintar o fantasma de verde ou vermelho, o servidor faz para aceitar
	ou recusar. Se as duas contas divergirem o jogador ve fantasma verde e a
	unidade nao nasce -- ou pior, o contrario.
]]
local Players = game:GetService("Players")

local PlacementUtil = {}

--[[
	Quanto de ar acima do caminho ainda conta como caminho.

	Ate existir, o unico teste era a caixa da propria unidade encostando no
	trilho, e o trilho e fino (25 cm) e fica rente ao chao. Qualquer coisa que
	levantasse a unidade um palmo -- a beirada de uma ponte, uma pedra sobre a
	trilha, um degrau -- tirava o caminho de dentro da caixa e a torre passava a
	valer em cima dele.

	Quatro studs e a altura do mob mais alto do jogo (o Redcliff Champion, 3,35)
	com folga: e o espaco que o caminho de fato ocupa enquanto a wave passa.
]]
PlacementUtil.PathClearance = 4

--[[
	O grupo de colisao do fantasma.

	Fica aqui, e nao em cada lado, porque os dois usam: o `CollisionService`
	(servidor) registra o grupo e o declara nao-colidivel com todo o resto, e o
	`UnitPlacementController` (cliente) poe as parts do fantasma nele. Grupo so
	existe se o servidor registrar, entao os dois precisam falar o mesmo nome.

	> Nada mais pode entrar neste grupo. As perguntas de posicionamento
	> (`GetPartsInPart` e companhia) sao feitas com `OverlapParams` no grupo
	> `Default`, e part de um grupo nao-colidivel com `Default` fica **invisivel**
	> para elas -- geometria de mapa aqui dentro seria terreno que o fantasma
	> atravessa sem nunca ficar vermelho. O fantasma pode porque ele e justamente o
	> que ninguem deve enxergar.
]]
PlacementUtil.GhostCollisionGroup = "PlacementGhost"

--[[
	O grupo de colisao dos personagens de jogador.

	Existe pelo mesmo motivo do de cima, e o par entre os dois e o ponto: fantasma e
	personagem nao se colidem. O `CollisionService` (servidor) registra os dois e
	declara o par, e e ele tambem quem poe **toda BasePart** de cada personagem aqui
	dentro -- corpo, acessorio e o que mais nascer no modelo depois.

	Ao contrario do grupo do fantasma, este colide com todo o resto normalmente:
	personagem continua batendo no mapa, nos outros personagens e nas unidades
	posicionadas. So o fantasma fica de fora.

	> Isto **nao** tira o personagem das perguntas de posicionamento. O
	> `FindBlockingCharacter` consulta com `OverlapParams` no grupo `Default`, e o
	> que vale ali e a colidibilidade entre o grupo do params e o da part: como este
	> grupo colide com `Default`, o personagem continua aparecendo na consulta e
	> continua bloqueando o lugar.
]]
PlacementUtil.CharacterCollisionGroup = "Character"

--[=[
	A caixa que testa o caminho: o volume da propria unidade mais a coluna de
	`PathClearance` studs debaixo dela.

	Devolve `CFrame, Vector3` para alimentar o mesmo `GetPartsInPart` dos dois
	lados -- a rotacao vem junto porque a unidade pode ter sido girada antes de
	ser largada.
]=]
function PlacementUtil.PathProbe(cf : CFrame, size : Vector3) : (CFrame, Vector3)
	local clearance = PlacementUtil.PathClearance

	return cf * CFrame.new(0, -clearance / 2, 0),
		Vector3.new(size.X, size.Y + clearance, size.Z)
end

--[=[
	O personagem de jogador que estiver dentro da caixa da unidade, ou `nil` se o
	lugar estiver livre.

	So personagem de jogador, de proposito. Mob e unidade ja colocada tambem tem
	Humanoid, mas nenhum dos dois entra aqui: a unidade ja e barrada pela distancia
	minima entre torres, e o mob nao existe como modelo no servidor -- quem clona os
	mobs e o `MobController`, no cliente. Bloquear mob so de um lado deixaria o
	fantasma vermelho num lugar que o servidor aceitaria, que e exatamente a
	divergencia que este modulo existe para evitar.

	A caixa e a bounding box cheia da unidade, a mesma dos dois lados: o fantasma e
	desenhado a 80% do tamanho, mas quem vai ocupar o chao e a unidade inteira.

	Acessorio nao conta. Chapeu e asa saem metros fora do corpo e sao parts
	consultaveis como qualquer outra -- sem essa excecao, o jogador veria o
	posicionamento recusado por um lugar que, na tela, esta vazio.
]=]
function PlacementUtil.FindBlockingCharacter(cf : CFrame, size : Vector3) : Model?
	local characters = {}

	for _, player in Players:GetPlayers() do
		local character = player.Character
		if character then
			table.insert(characters, character)
		end
	end

	if #characters == 0 then return nil end

	local overlapParams = OverlapParams.new()
	overlapParams.FilterType = Enum.RaycastFilterType.Include
	overlapParams.FilterDescendantsInstances = characters

	for _, part in workspace:GetPartBoundsInBox(cf, size, overlapParams) do
		if part:FindFirstAncestorOfClass("Accessory") then continue end

		for _, character in characters do
			if part:IsDescendantOf(character) then
				return character
			end
		end
	end

	return nil
end

return PlacementUtil
