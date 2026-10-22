--!strict
local Config = require(script.Parent.Config)
local Catalog = require(script.Parent.Catalog)
local Serializer = require(script.Parent.Serializer)

type Route = Serializer.Route
type Map = Serializer.Map

local RouteModel = {}

function RouteModel.empty(): Route
	return { steps = {} }
end

function RouteModel.clone(route: Route): Route
	return Serializer.copy(route)
end

function RouteModel.find(route: Route, id: string): (number?, number?, number?)
	for s, step in route.steps do
		for a, alt in step.alts do
			for i, nodeId in alt do
				if nodeId == id then
					return s, a, i
				end
			end
		end
	end
	return nil, nil, nil
end

--[[
	Lanes A and B: Enemy Spawn A + Waypoint A's, Enemy Spawn B + Waypoint B's
	(route.lanes = { { lane = "A" | "B", ids = { waypointIds } } }). Each lane
	only holds its own waypoint type. After the lanes come the shared steps
	(route.steps), which only hold Waypoint C's, then the base.

	With one spawn this is a plain route. With two, the Peri export puts both
	lanes in node step 1 as two same-named Folders, which Peri's
	PathUtil.BuildRoutes already treats as alternatives: two routes with two
	different starts, so no change to Peri is needed.
]]
local LANE_SET = { A = true, B = true }
function RouteModel.lanes(route: any): { any }
	if typeof(route.lanes) ~= "table" then
		route.lanes = {}
	end
	return route.lanes
end

function RouteModel.findLane(route: any, id: string): (number?, number?)
	for l, lane in route.lanes or {} do
		for i, nodeId in lane.ids do
			if nodeId == id then
				return l, i
			end
		end
	end
	return nil, nil
end

function RouteModel.laneFor(route: any, letter: string): (number?, any)
	for l, lane in route.lanes or {} do
		if lane.lane == letter then
			return l, lane
		end
	end
	return nil, nil
end

local function ensureLane(route: any, letter: string): any
	local _, lane = RouteModel.laneFor(route, letter)
	if not lane then
		lane = { lane = letter, ids = {} }
		table.insert(RouteModel.lanes(route), lane)
		table.sort(route.lanes, function(a, b)
			return a.lane < b.lane
		end)
	end
	return lane
end

function RouteModel.insertLaneStart(route: any, letter: string, id: string)
	table.insert(ensureLane(route, letter).ids, 1, id)
end

function RouteModel.appendLane(route: any, letter: string, id: string)
	table.insert(ensureLane(route, letter).ids, id)
end

function RouteModel.contains(route: Route, id: string): boolean
	return (RouteModel.find(route, id)) ~= nil or (RouteModel.findLane(route, id)) ~= nil
end

function RouteModel.append(route: Route, id: string)
	local last = route.steps[#route.steps]
	if last and #last.alts == 1 then
		table.insert(last.alts[1], id)
	else
		table.insert(route.steps, { alts = { { id } } })
	end
end

function RouteModel.insertAfter(route: Route, refId: string?, id: string)
	if refId then
		local l, li = RouteModel.findLane(route, refId)
		if l and li then
			table.insert((route :: any).lanes[l].ids, li + 1, id)
			return
		end
		local s, a, i = RouteModel.find(route, refId)
		if s and a and i then
			table.insert(route.steps[s].alts[a], i + 1, id)
			return
		end
	end
	RouteModel.append(route, id)
end

function RouteModel.insertFirst(route: Route, id: string)
	local first = route.steps[1]
	if first and #first.alts == 1 then
		table.insert(first.alts[1], 1, id)
	else
		table.insert(route.steps, 1, { alts = { { id } } })
	end
end

function RouteModel.addBranch(route: Route, stepIndex: number, ids: { string })
	local step = route.steps[stepIndex]
	if not step then
		return
	end
	table.insert(step.alts, table.clone(ids))
end

local function compact(route: Route)
	local laneList = (route :: any).lanes
	if typeof(laneList) == "table" then
		for l = #laneList, 1, -1 do
			if #laneList[l].ids == 0 then
				table.remove(laneList, l)
			end
		end
	end
	for s = #route.steps, 1, -1 do
		local step = route.steps[s]
		for a = #step.alts, 1, -1 do
			if #step.alts[a] == 0 then
				table.remove(step.alts, a)
			end
		end
		if #step.alts == 0 then
			table.remove(route.steps, s)
		end
	end

	local s = 1
	while s < #route.steps do
		local step, nextStep = route.steps[s], route.steps[s + 1]
		if #step.alts == 1 and #nextStep.alts == 1 then
			for _, id in nextStep.alts[1] do
				table.insert(step.alts[1], id)
			end
			table.remove(route.steps, s + 1)
		else
			s += 1
		end
	end
end

RouteModel.compact = compact

function RouteModel.remove(route: Route, id: string): boolean
	local l, li = RouteModel.findLane(route, id)
	if l and li then
		table.remove((route :: any).lanes[l].ids, li)
		compact(route)
		return true
	end
	local s, a, i = RouteModel.find(route, id)
	if not (s and a and i) then
		return false
	end
	table.remove(route.steps[s].alts[a], i)
	compact(route)
	return true
end

function RouteModel.removeBranch(route: Route, stepIndex: number, altIndex: number): { string }
	local step = route.steps[stepIndex]
	if not step or not step.alts[altIndex] then
		return {}
	end
	local removed = table.remove(step.alts, altIndex) :: { string }
	compact(route)
	return removed
end

function RouteModel.combinations(route: Route, spawnCount: number?): number
	local total = math.max(1, spawnCount or #((route :: any).lanes or {}))
	for _, step in route.steps do
		total *= math.max(1, #step.alts)
	end
	return total
end

function RouteModel.waypointCount(route: Route): number
	local n = 0
	for _, step in route.steps do
		for _, alt in step.alts do
			n += #alt
		end
	end
	for _, lane in (route :: any).lanes or {} do
		n += #lane.ids
	end
	return n
end

function RouteModel.sanitize(raw: any): (boolean, string?, Route?)
	if typeof(raw) ~= "table" or typeof(raw.steps) ~= "table" then
		return false, "Malformed route.", nil
	end
	if #raw.steps > Config.MAX_ROUTE_STEPS then
		return false, "Route has too many steps.", nil
	end
	local clean: Route = { steps = {} }
	for _, step in raw.steps do
		if typeof(step) ~= "table" or typeof(step.alts) ~= "table" then
			return false, "Malformed route step.", nil
		end
		if #step.alts > Config.MAX_ALTERNATIVES then
			return false, string.format("A fork can have at most %d branches.", Config.MAX_ALTERNATIVES), nil
		end
		local alts = {}
		for _, alt in step.alts do
			if typeof(alt) ~= "table" then
				return false, "Malformed route branch.", nil
			end
			local ids = {}
			for _, id in alt do
				if typeof(id) ~= "string" or #id > 24 then
					return false, "Malformed waypoint reference.", nil
				end
				table.insert(ids, id)
			end
			table.insert(alts, ids)
		end
		table.insert(clean.steps, { alts = alts })
	end

	if raw.lanes ~= nil then
		if typeof(raw.lanes) ~= "table" or #raw.lanes > Config.MAX_ENEMY_SPAWNS then
			return false, "Malformed lanes.", nil
		end
		local laneList = {}
		local seenLanes = {}
		for _, lane in raw.lanes do
			if typeof(lane) ~= "table" or not LANE_SET[lane.lane] or seenLanes[lane.lane] or typeof(lane.ids) ~= "table" then
				return false, "Malformed lane.", nil
			end
			seenLanes[lane.lane] = true
			local ids = {}
			for _, id in lane.ids do
				if typeof(id) ~= "string" or #id > 24 then
					return false, "Malformed waypoint reference.", nil
				end
				table.insert(ids, id)
			end
			table.insert(laneList, { lane = lane.lane, ids = ids })
		end
		table.sort(laneList, function(a, b)
			return a.lane < b.lane
		end)
		;(clean :: any).lanes = laneList
	end

	compact(clean)
	return true, nil, clean
end

function RouteModel.prune(route: Route, objects: { [string]: Serializer.Record }): (Route, { string })
	local pruned = {}
	local out = RouteModel.clone(route)
	for _, step in out.steps do
		for _, alt in step.alts do
			for i = #alt, 1, -1 do
				local rec = objects[alt[i]]
				local def = rec and Catalog.get(rec.t)
				if not def or def.role ~= Catalog.ROLE.Waypoint or def.lane ~= nil then
					table.insert(pruned, alt[i])
					table.remove(alt, i)
				end
			end
		end
	end
	local laneList = (out :: any).lanes
	if typeof(laneList) == "table" then
		for l = #laneList, 1, -1 do
			local lane = laneList[l]
			if not LANE_SET[lane.lane] then
				for _, id in lane.ids do
					table.insert(pruned, id)
				end
				table.remove(laneList, l)
			else
				for i = #lane.ids, 1, -1 do
					local rec = objects[lane.ids[i]]
					local def = rec and Catalog.get(rec.t)
					if not def or def.role ~= Catalog.ROLE.Waypoint or def.lane ~= lane.lane then
						table.insert(pruned, lane.ids[i])
						table.remove(lane.ids, i)
					end
				end
			end
		end
	end
	compact(out)
	return out, pruned
end

function RouteModel.validate(route: Route, objects: { [string]: Serializer.Record }): (boolean, string?)
	local seen = {}
	local seenLanes = {}
	for _, lane in (route :: any).lanes or {} do
		if not LANE_SET[lane.lane] or seenLanes[lane.lane] then
			return false, "Malformed lane."
		end
		seenLanes[lane.lane] = true
		for _, id in lane.ids do
			if seen[id] then
				return false, "A waypoint is used twice in the route."
			end
			seen[id] = true
			local rec = objects[id]
			local def = rec and Catalog.get(rec.t)
			if not def or def.role ~= Catalog.ROLE.Waypoint then
				return false, "The route references a missing waypoint."
			end
			if def.lane ~= lane.lane then
				return false, string.format("Lane %s can only contain Waypoint %s.", lane.lane, lane.lane)
			end
		end
	end
	for _, step in route.steps do
		for _, alt in step.alts do
			for _, id in alt do
				if seen[id] then
					return false, "A waypoint is used twice in the route."
				end
				seen[id] = true
				local rec = objects[id]
				local def = rec and Catalog.get(rec.t)
				if not def or def.role ~= Catalog.ROLE.Waypoint then
					return false, "The route references a missing waypoint."
				end
				if def.lane ~= nil then
					return false, "The shared path can only contain Waypoint C."
				end
			end
		end
	end
	local spawnCount = 0
	for _, rec in objects do
		local def = Catalog.get(rec.t)
		if def and def.role == Catalog.ROLE.EnemySpawn then
			spawnCount += 1
		end
	end
	if RouteModel.combinations(route, spawnCount) > Config.MAX_ROUTES then
		return false, string.format("Spawns and forks create more than %d possible routes.", Config.MAX_ROUTES)
	end
	return true, nil
end

function RouteModel.spawns(map: Map): { Serializer.Record }
	local list = {}
	for _, rec in map.objects do
		local def = Catalog.get(rec.t)
		if def and def.role == Catalog.ROLE.EnemySpawn then
			table.insert(list, rec)
		end
	end
	table.sort(list, function(a, b)
		local la = (Catalog.get(a.t) :: Catalog.Def).lane or "Z"
		local lb = (Catalog.get(b.t) :: Catalog.Def).lane or "Z"
		if la ~= lb then
			return la < lb
		end
		return a.id < b.id
	end)
	return list
end

function RouteModel.spawnLane(rec: Serializer.Record): string
	local def = Catalog.get(rec.t)
	return def and def.lane or "A"
end

function RouteModel.findRole(map: Map, role: string): Serializer.Record?
	for _, rec in map.objects do
		local def = Catalog.get(rec.t)
		if def and def.role == role then
			return rec
		end
	end
	return nil
end

local function nodePosition(rec: Serializer.Record): Vector3
	return Serializer.toVector(rec.p) + Vector3.new(0, Config.PERI.NodeSize.Y / 2, 0)
end

RouteModel.nodePosition = nodePosition

export type StepPositions = { { { position: Vector3, id: string } } }

function RouteModel.steps(map: Map): (StepPositions?, string?)
	local spawns = RouteModel.spawns(map)
	local base = RouteModel.findRole(map, Catalog.ROLE.Base)
	if #spawns == 0 then
		return nil, "Missing enemy spawn point."
	end
	if not base then
		return nil, "Missing base."
	end

	local laneAlts = {}
	for _, spawn in spawns do
		local points = { { position = nodePosition(spawn), id = spawn.id } }
		local _, lane = RouteModel.laneFor(map.route, RouteModel.spawnLane(spawn))
		if lane then
			for _, id in lane.ids do
				local rec = map.objects[id]
				if rec then
					table.insert(points, { position = nodePosition(rec), id = id })
				end
			end
		end
		table.insert(laneAlts, points)
	end

	local steps: StepPositions = {}
	if #laneAlts == 1 then
		for _, point in laneAlts[1] do
			table.insert(steps, { { point } })
		end
	else
		table.insert(steps, laneAlts)
	end

	for _, step in map.route.steps do
		local alts = {}
		for _, alt in step.alts do
			local points = {}
			for _, id in alt do
				local rec = map.objects[id]
				if rec then
					table.insert(points, { position = nodePosition(rec), id = id })
				end
			end
			if #points > 0 then
				table.insert(alts, points)
			end
		end

		if #alts == 1 then
			for _, point in alts[1] do
				table.insert(steps, { { point } })
			end
		elseif #alts > 1 then
			table.insert(steps, alts)
		end
	end

	table.insert(steps, { { { position = nodePosition(base), id = base.id } } })
	return steps, nil
end

return RouteModel
