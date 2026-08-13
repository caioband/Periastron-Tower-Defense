local PathUtil = {}

local DEFAULT_CORNER_RADIUS = 1.75
local DEFAULT_SAMPLES_PER_CORNER = 10

function PathUtil.GetSortedNodes(nodesFolder)
	local nodes = {}
	for _, n in nodesFolder:GetChildren() do
		table.insert(nodes, n)
	end
	table.sort(nodes, function(a, b)
		return tonumber(a.Name) < tonumber(b.Name)
	end)
	return nodes
end

function PathUtil.BuildSmoothPath(nodesFolder, cornerRadius, samplesPerCorner)
	cornerRadius = cornerRadius or DEFAULT_CORNER_RADIUS
	samplesPerCorner = samplesPerCorner or DEFAULT_SAMPLES_PER_CORNER

	local nodes = PathUtil.GetSortedNodes(nodesFolder)
	local positions = {}
	for _, n in ipairs(nodes) do
		table.insert(positions, n.Position)
	end

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
