local PathUtil = {}

local DEFAULT_CORNER_RADIUS = 1.75
local DEFAULT_SAMPLES_PER_CORNER = 10

-- Teto de seguranca para o produto das bifurcacoes: com 5 forks de 2 lados ja
-- sao 32 rotas, e cada uma custa uma suavizacao inteira.
local MAX_ROUTES = 32

-- Contagens que o servidor publica na pasta de nodes para o cliente saber
-- quando a replicacao terminou. Ver `PublishNodeCounts` / `WaitForNodes`.
local NODE_COUNT_ATTRIBUTE = "NodeCount"
local POINT_COUNT_ATTRIBUTE = "PointCount"
local DEFAULT_WAIT_TIMEOUT = 10

function PathUtil.GetSortedNodes(nodesFolder)
	local nodes = {}
	for _, n in nodesFolder:GetChildren() do
		table.insert(nodes, n)
	end
	table.sort(nodes, function(a, b)
		return (tonumber(a.Name) or math.huge) < (tonumber(b.Name) or math.huge)
	end)
	return nodes
end

--[[
	Um filho de Nodes e uma de duas coisas:

	  Part            um ponto do caminho
	  Folder / Model  um trecho inteiro, com os proprios pontos numerados dentro

	Dois filhos com o MESMO nome sao alternativas do mesmo passo — e assim que o
	mapa declara uma bifurcacao.
]]
local function expandStep(instance) : { Vector3 }
	if instance:IsA("BasePart") then
		return { instance.Position }
	end

	local positions = {}
	for _, node in PathUtil.GetSortedNodes(instance) do
		if node:IsA("BasePart") then
			table.insert(positions, node.Position)
		end
	end

	return positions
end

--[[
	Duas alternativas do mesmo passo tem o mesmo nome, entao a ordem em que
	`GetChildren` as devolve e o unico criterio que sobra — e essa ordem nao e
	garantida entre servidor e cliente.

	Isso importa porque o indice da rota atravessa a rede: o servidor sorteia um
	numero no spawn e o cliente monta as rotas por conta propria e indexa por ele.
	Com os indices trocados o mob apareceria andando por um lado da bifurcacao
	enquanto o servidor o simula pelo outro.

	Comparar as proprias posicoes resolve: os dois lados leem as mesmas Parts
	replicadas, entao chegam sempre a mesma ordem.
]]
local function comparePositions(a : Vector3, b : Vector3) : boolean
	if a.X ~= b.X then return a.X < b.X end
	if a.Y ~= b.Y then return a.Y < b.Y end
	return a.Z < b.Z
end

local function compareAlternatives(a : { Vector3 }, b : { Vector3 }) : boolean
	for i = 1, math.min(#a, #b) do
		if a[i] ~= b[i] then
			return comparePositions(a[i], b[i])
		end
	end
	return #a < #b
end

--[=[
	Quantos pontos a pasta de nodes descreve, contando os que estao dentro dos
	trechos de bifurcacao.
]=]
function PathUtil.CountPoints(nodesFolder) : number
	local count = 0
	for _, child in nodesFolder:GetChildren() do
		if child:IsA("BasePart") then
			count += 1
		else
			for _, descendant in child:GetDescendants() do
				if descendant:IsA("BasePart") then
					count += 1
				end
			end
		end
	end
	return count
end

--[=[
	Publica o tamanho da pasta de nodes para o cliente conferir. Chamado pelo
	servidor depois de clonar os nodes do mapa.
]=]
function PathUtil.PublishNodeCounts(nodesFolder)
	nodesFolder:SetAttribute(NODE_COUNT_ATTRIBUTE, #nodesFolder:GetChildren())
	nodesFolder:SetAttribute(POINT_COUNT_ATTRIBUTE, PathUtil.CountPoints(nodesFolder))
end

--[=[
	Espera a pasta de nodes chegar inteira no cliente.

	Esperar por um node especifico nao basta: um passo com bifurcacao tem dois
	filhos de mesmo nome, e cada um e um Folder com os proprios pontos dentro.
	Montar as rotas cedo demais daria uma bifurcacao com um lado so, ou um trecho
	truncado — e como o resultado fica em cache, o erro duraria o round inteiro.

	Conferir contagem em vez de escutar um sinal deixa a espera imune a ordem em
	que a replicacao entrega as coisas: enquanto faltar peca, o loop continua.

	Devolve `false` se estourar o tempo, para quem chamou nao cachear um caminho
	incompleto.
]=]
function PathUtil.WaitForNodes(nodesFolder, timeout : number?) : boolean
	local deadline = os.clock() + (timeout or DEFAULT_WAIT_TIMEOUT)

	repeat
		local nodeCount = nodesFolder:GetAttribute(NODE_COUNT_ATTRIBUTE)
		local pointCount = nodesFolder:GetAttribute(POINT_COUNT_ATTRIBUTE)

		if nodeCount and pointCount
			and #nodesFolder:GetChildren() >= nodeCount
			and PathUtil.CountPoints(nodesFolder) >= pointCount
		then
			return true
		end

		task.wait()
	until os.clock() >= deadline

	warn("[PathUtil]: os nodes do mapa nao chegaram completos a tempo.")
	return false
end

--[=[
	Todas as rotas que a pasta de nodes descreve, uma por combinacao de
	bifurcacoes.

	Cada rota devolvida tem o mesmo formato de um mapa sem bifurcacao nenhuma —
	uma polilinha simples — entao todo o resto do jogo continua tratando "um
	caminho" como sempre tratou. A escolha de qual rota seguir vira um indice.

		{
			positions = { Vector3, ... },   -- os nodes crus, para as curvas
			smooth    = { points, length, cumulative },
		}
]=]
function PathUtil.BuildRoutes(nodesFolder, cornerRadius, samplesPerCorner)
	local steps = {}
	local stepOrder = {}

	for _, child in nodesFolder:GetChildren() do
		if not steps[child.Name] then
			steps[child.Name] = {}
			table.insert(stepOrder, child.Name)
		end
		table.insert(steps[child.Name], child)
	end

	table.sort(stepOrder, function(a, b)
		return (tonumber(a) or math.huge) < (tonumber(b) or math.huge)
	end)

	local total = 1
	for _, key in stepOrder do
		total *= #steps[key]
	end

	if total > MAX_ROUTES then
		warn(string.format(
			"[PathUtil]: %d rotas possiveis, acima do teto de %d. Usando so a primeira alternativa de cada passo.",
			total, MAX_ROUTES))
		total = 1
	end

	-- Cada alternativa e expandida uma vez so e reaproveitada entre as rotas. A
	-- ordenacao e o que faz o indice da rota significar a mesma coisa nos dois
	-- lados da rede.
	local expanded = {}
	for _, key in stepOrder do
		expanded[key] = {}
		for index, alternative in steps[key] do
			expanded[key][index] = expandStep(alternative)
		end
		table.sort(expanded[key], compareAlternatives)
	end

	local routes = {}
	for routeIndex = 1, math.max(1, total) do
		local positions = {}
		local remaining = routeIndex - 1

		-- Decomposicao em base mista: cada passo consome um "digito" do indice.
		for _, key in stepOrder do
			local alternatives = expanded[key]
			local count = total > 1 and #alternatives or 1
			local choice = (remaining % count) + 1
			remaining //= count

			for _, position in alternatives[choice] do
				table.insert(positions, position)
			end
		end

		table.insert(routes, {
			positions = positions,
			smooth = PathUtil.BuildSmoothPathFromPositions(positions, cornerRadius, samplesPerCorner),
		})
	end

	return routes
end

function PathUtil.BuildSmoothPath(nodesFolder, cornerRadius, samplesPerCorner)
	return PathUtil.BuildRoutes(nodesFolder, cornerRadius, samplesPerCorner)[1].smooth
end

function PathUtil.BuildSmoothPathFromPositions(positions, cornerRadius, samplesPerCorner)
	cornerRadius = cornerRadius or DEFAULT_CORNER_RADIUS
	samplesPerCorner = samplesPerCorner or DEFAULT_SAMPLES_PER_CORNER

	local count = #positions
	if count < 2 then
		return { points = positions, length = 0, cumulative = { 0 } }
	end

	local raw = {}
	table.insert(raw, positions[1])

	for i = 2, count - 1 do
		local cur = positions[i]
		local toPrev = positions[i - 1] - cur
		local toNext = positions[i + 1] - cur
		local lenPrev = toPrev.Magnitude
		local lenNext = toNext.Magnitude

		if lenPrev < 1e-4 or lenNext < 1e-4 then
			table.insert(raw, cur)
		else
			local r = math.min(cornerRadius, lenPrev * 0.5, lenNext * 0.5)
			local a = cur + toPrev.Unit * r
			local c = cur + toNext.Unit * r

			table.insert(raw, a)
			for s = 1, samplesPerCorner do
				local t = s / (samplesPerCorner + 1)
				local u = 1 - t
				local p = (u * u) * a + (2 * u * t) * cur + (t * t) * c
				table.insert(raw, p)
			end
			table.insert(raw, c)
		end
	end

	table.insert(raw, positions[count])

	local points = { raw[1] }
	for i = 2, #raw do
		if (raw[i] - points[#points]).Magnitude > 1e-4 then
			table.insert(points, raw[i])
		end
	end

	local cumulative = { 0 }
	local total = 0
	for i = 2, #points do
		total += (points[i] - points[i - 1]).Magnitude
		cumulative[i] = total
	end

	return { points = points, length = total, cumulative = cumulative }
end

--[=[
	Os nodes do caminho achatados numa lista so, cada um com a distancia
	percorrida do primeiro node ate ele.

	E o que a prioridade `Farthest` usa para medir o avanco de um mob: o node mais
	perto dele diz o quanto do caminho ele ja andou, independente de onde a torre
	esta. Sai das rotas ja montadas, entao os subnodes (as pastas de trecho) e as
	bifurcacoes ja vieram expandidos na ordem certa pelo `BuildRoutes`.

	As rotas de um mapa com bifurcacao compartilham o comeco, e o mesmo node
	aparece em varias delas. Ele entra na lista uma vez so, com a menor distancia
	entre as rotas em que aparece -- assim dois mobs em ramos diferentes continuam
	comparaveis, e o resultado nao depende da ordem em que as rotas foram geradas.

	Distancia pelo caminho, e nao em linha reta ate o primeiro node: num mapa que
	volta perto do spawn a linha reta diria que o mob recuou.
]=]
function PathUtil.BuildNodeDistances(routes)
	local nodes = {}
	local byKey = {}

	for _, route in routes do
		local positions = route.positions
		local traveled = 0

		for index, position in positions do
			if index > 1 then
				traveled += (position - positions[index - 1]).Magnitude
			end

			local key = string.format("%.3f/%.3f/%.3f", position.X, position.Y, position.Z)
			local existing = byKey[key]

			if existing then
				if traveled < existing.distance then
					existing.distance = traveled
				end
			else
				local node = { position = position, distance = traveled }
				byKey[key] = node
				table.insert(nodes, node)
			end
		end
	end

	return nodes
end

--[=[
	O quanto do caminho ja foi andado por quem esta em `position`: a distancia do
	primeiro node ate o node mais perto dela. `nil` se a lista estiver vazia.
]=]
function PathUtil.GetNodeProgress(nodes, position : Vector3) : number?
	local best = nil
	local bestDistance = math.huge

	for _, node in nodes do
		-- Comparacao ao quadrado: e so para achar o menor, e a raiz nao muda a ordem.
		local offset = node.position - position
		local squared = offset:Dot(offset)

		if squared < bestDistance then
			bestDistance = squared
			best = node
		end
	end

	return best and best.distance
end

function PathUtil.GetPositionAtDistance(smooth, distance)
	local points = smooth.points
	local cumulative = smooth.cumulative
	if #points == 0 then return nil end
	if #points == 1 then return points[1] end
	if distance <= 0 then return points[1] end
	if distance >= smooth.length then return points[#points] end

	for i = 2, #points do
		if cumulative[i] >= distance then
			local segLen = cumulative[i] - cumulative[i - 1]
			local progress = segLen > 0 and (distance - cumulative[i - 1]) / segLen or 0
			return points[i - 1]:Lerp(points[i], progress)
		end
	end
	return points[#points]
end

return PathUtil
