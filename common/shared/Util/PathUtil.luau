local Log = require(script.Parent.Log)

local log = Log.new("PathUtil")

local PathUtil = {}

local DEFAULT_CORNER_RADIUS = 1.75
local DEFAULT_SAMPLES_PER_CORNER = 10

-- Safety cap on the product of forks: 5 two-way forks are already 32 routes, and
-- each one costs a full smoothing pass.
local MAX_ROUTES = 32

-- Counts the server publishes on the nodes folder so the client knows when
-- replication finished. See `PublishNodeCounts` / `WaitForNodes`.
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
	A child of Nodes is one of two things:

	  Part            a point on the path
	  Folder / Model  a whole segment, with its own numbered points inside

	Two children with the SAME name are alternatives for the same step: that is how
	a map declares a fork.
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
	Two alternatives for the same step share a name, so the order `GetChildren`
	returns them in is the only remaining criterion, and it is not guaranteed to
	match between server and client.

	That matters because the route index crosses the network: the server draws a
	number at spawn and the client builds the routes itself and indexes by it. With
	swapped indices the enemy would appear walking one side of the fork while the
	server simulates the other.

	Comparing positions solves it: both sides read the same replicated Parts, so
	they always reach the same order.
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
	How many points the nodes folder describes, including those inside fork
	segments.
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
	Publishes the nodes folder's size for the client to check. Called by the server
	after cloning the map's nodes.
]=]
function PathUtil.PublishNodeCounts(nodesFolder)
	nodesFolder:SetAttribute(NODE_COUNT_ATTRIBUTE, #nodesFolder:GetChildren())
	nodesFolder:SetAttribute(POINT_COUNT_ATTRIBUTE, PathUtil.CountPoints(nodesFolder))
end

--[=[
	Waits for the whole nodes folder to reach the client.

	Waiting for one specific node is not enough: a forked step has two children with
	the same name, each a Folder with its own points. Building routes too early
	would give a one-sided fork or a truncated segment, and since the result is
	cached, the mistake would last the whole round.

	Checking counts instead of listening to a signal makes the wait immune to the
	order replication delivers things in: while a piece is missing, the loop goes on.

	Returns `false` on timeout, so the caller does not cache an incomplete path.
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

	log:StudioWarn("the map nodes did not finish replicating in time.")
	return false
end

--[=[
	Every route the nodes folder describes, one per combination of forks.

	Each returned route has the same shape as a map with no forks (a plain
	polyline), so the rest of the game keeps treating "a path" as it always did.
	Choosing a route becomes an index.

		{
			positions = { Vector3, ... },   -- the raw nodes, for the curves
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
		log:StudioWarn(string.format(
			"%d possible routes, above the cap of %d. Using only the first alternative at each fork.",
			total, MAX_ROUTES))
		total = 1
	end

	-- Each alternative is expanded once and reused across routes. The sort is what
	-- makes a route index mean the same thing on both sides of the network.
	--
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

		-- Mixed-radix decomposition: each step consumes one "digit" of the index.
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
	The path's nodes flattened into one list, each with the distance walked from the
	first node to it.

	This is what the `Farthest` priority uses to measure an enemy's progress: its
	nearest node says how much of the path it has walked, wherever the tower is. It
	comes from the routes already built, so segments and forks are already expanded
	in order by `BuildRoutes`.

	Routes on a forked map share their start, and the same node appears in several
	of them. It enters the list once, with the smallest distance among its routes,
	so two enemies on different branches stay comparable and the result does not
	depend on route order.

	Distance along the path, not a straight line to the first node: on a map that
	loops back near the spawn, a straight line would say the enemy went backward.
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
	How much of the path has been walked by whoever is at `position`: the distance
	from the first node to the node nearest to it. `nil` if the list is empty.
]=]
function PathUtil.GetNodeProgress(nodes, position : Vector3) : number?
	local best = nil
	local bestDistance = math.huge

	for _, node in nodes do
		-- Squared comparison: it only finds the smallest, and the root does not change order.
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
