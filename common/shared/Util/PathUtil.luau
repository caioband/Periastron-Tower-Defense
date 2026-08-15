local PathUtil = {}

local DEFAULT_CORNER_RADIUS = 1.75
local DEFAULT_SAMPLES_PER_CORNER = 10

-- Teto de seguranca para o produto das bifurcacoes: com 5 forks de 2 lados ja
-- sao 32 rotas, e cada uma custa uma suavizacao inteira.
local MAX_ROUTES = 32

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

	-- Cada alternativa e expandida uma vez so e reaproveitada entre as rotas.
	local expanded = {}
	for _, key in stepOrder do
		expanded[key] = {}
		for index, alternative in steps[key] do
			expanded[key][index] = expandStep(alternative)
		end
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
