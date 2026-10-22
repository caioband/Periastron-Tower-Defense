local RunService = game:GetService("RunService")

local log = {
	StudioWarn = function(_, message)
		if RunService:IsStudio() then
			warn("[PathUtil] " .. message)
		end
	end,
}

local PathUtil = {}

local DEFAULT_CORNER_RADIUS = 1.75
local DEFAULT_SAMPLES_PER_CORNER = 10

local MAX_ROUTES = 32

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

function PathUtil.PublishNodeCounts(nodesFolder)
	nodesFolder:SetAttribute(NODE_COUNT_ATTRIBUTE, #nodesFolder:GetChildren())
	nodesFolder:SetAttribute(POINT_COUNT_ATTRIBUTE, PathUtil.CountPoints(nodesFolder))
end

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

	log:StudioWarn("the map nodes did not finish replicating in time.")
	return false
end

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
		log:StudioWarn(string.format(
			"%d possible routes, above the cap of %d. Using only the first alternative at each fork.",
			total, MAX_ROUTES))
		total = 1
	end

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

function PathUtil.GetNodeProgress(nodes, position : Vector3) : number?
	local best = nil
	local bestDistance = math.huge

	for _, node in nodes do
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
