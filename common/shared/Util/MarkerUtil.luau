--[[
	Os marcadores que o mapa deixa para a UI: onde uma loja fica e onde ela larga o
	jogador.

	As duas lojas do lobby funcionam pelo mesmo par de peças — uma de referência, que
	é o centro do raio de abertura, e uma de pouso, onde o teleporte deixa o
	personagem. Este módulo é só como achar uma dessas peças e como ler onde ela está;
	o que fazer com isso continua sendo de cada controller.

	A busca é **em profundidade** dentro do mapa, e não nos filhos diretos: os
	marcadores vivem agrupados no modelo da loja a que pertencem (`Map.Shop`,
	`Map.Deco.Houses.CardShop`), e exigir que eles fiquem soltos na raiz do mapa faria
	o artista quebrar a loja só por organizar a árvore. O nome de cada marcador é
	único no mapa, então descer a árvore acha o mesmo part de sempre.
]]

local MarkerUtil = {}

--[=[
	Onde um marcador está, seja ele uma Part ou um Model.

	Devolve nil para qualquer outra coisa — e nil é a resposta certa, e não um erro:
	um marcador que virou Folder por acidente deixa a loja sem abrir, e não o jogo sem
	rodar.
]=]
function MarkerUtil.pivotOf(part : Instance?) : CFrame?
	if not part then
		return nil
	end

	if part:IsA("BasePart") then
		return part.CFrame
	elseif part:IsA("Model") then
		return part:GetPivot()
	end

	return nil
end

--[=[
	Meia altura do marcador, para o personagem pousar **em cima** dele em vez de meio
	enterrado. Zero para o que não tem altura própria.
]=]
function MarkerUtil.halfHeightOf(part : Instance?) : number
	if part and part:IsA("BasePart") then
		return part.Size.Y / 2
	end

	return 0
end

--[=[
	Acha um marcador sob `Workspace.<parentName>`, com cache e um aviso só por nome.

	`cache` é uma tabela do controller, por nome do marcador: a entrada é reaproveitada
	enquanto a peça estiver no mundo e refeita quando ela sair dele — uma troca de mapa
	reparenta tudo, e uma referência guardada para sempre apontaria para a peça de um
	mapa que já saiu.

	`warned` é a mesma coisa para os avisos: marcador que falta é erro de autoria, e
	repetir o aviso a cada respawn só enche o output. `source` é o nome que aparece no
	aviso, para o output dizer qual loja está sem a peça.
]=]
function MarkerUtil.find(
	parentName : string,
	partName : string,
	cache : { [string] : Instance? },
	warned : { [string] : boolean },
	source : string
) : Instance?
	local cached = cache[partName]
	if cached and cached.Parent then
		return cached
	end

	local map = workspace:FindFirstChild(parentName)
	local part = map and map:FindFirstChild(partName, true)

	if not part and not warned[partName] then
		warned[partName] = true
		warn(`[{source}]: no {partName} under Workspace.{parentName}.`)
	end

	cache[partName] = part
	return part
end

return MarkerUtil
