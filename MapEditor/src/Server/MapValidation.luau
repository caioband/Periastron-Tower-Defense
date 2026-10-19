--!strict
--[[
	Map validation against the real Peri movement model.

	Routes are not judged by waypoint connectivity: the map is exported to Peri's
	Nodes format and run through the same PathUtil.BuildRoutes MobService uses,
	then the smoothed polylines enemies actually walk are sampled and raycast
	against the built geometry:
	  - body ray between samples, against blocksPath objects  -> error
	  - ground ray under each sample, against map geometry    -> gap error
	  - ground hit that is not a Path piece                   -> warning (towers can stand on the route)
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("MapEditor")
local Config = require(Shared.Config)
local Catalog = require(Shared.Catalog)
local RouteModel = require(Shared.RouteModel)
local Serializer = require(Shared.Serializer)
local PathUtil = require(Shared.PathUtil)
local MapRules = require(Shared.MapRules)

local PeriMapAdapter = require(script.Parent.PeriMapAdapter)

type Session = any

export type Issue = { msg: string, ids: { string }, at: { number }? }
export type Result = {
	errors: { Issue },
	warnings: { Issue },
	routes: number,
	lengths: { number },
	objects: number,
}

local MapValidation = {}

local function vec(v: Vector3): { number }
	return Serializer.vec(v)
end

function MapValidation.run(session: Session): Result
	local map = session.map
	local origin: CFrame = session.origin
	local result: Result = { errors = {}, warnings = {}, routes = 0, lengths = {}, objects = 0 }

	local function err(msg: string, ids: { string }?, at: Vector3?)
		table.insert(result.errors, { msg = msg, ids = ids or {}, at = at and vec(at) or nil })
	end
	local function warnIssue(msg: string, ids: { string }?, at: Vector3?)
		table.insert(result.warnings, { msg = msg, ids = ids or {}, at = at and vec(at) or nil })
	end

	local spawns, base, playerSpawn = {}, nil, nil
	local hasPath, hasGround = false, false
	local blocking: { Instance } = {}
	local ground: { Instance } = {}
	local pathSet: { [Instance]: boolean } = {}
	local idOf: { [Instance]: string } = {}

	for id, rec in map.objects do
		result.objects += 1
		local def = Catalog.get(rec.t)
		if not def then
			err("Unknown object type: " .. tostring(rec.t), { id })
			continue
		end
		if not MapRules.inBounds(Serializer.toVector(rec.p)) then
			err(def.name .. " is outside the build area.", { id })
		end

		if def.role == Catalog.ROLE.EnemySpawn then
			table.insert(spawns, rec)
		elseif def.role == Catalog.ROLE.Base then
			base = rec
		elseif def.role == Catalog.ROLE.PlayerSpawn then
			playerSpawn = rec
		elseif def.role == Catalog.ROLE.Waypoint then
			if not RouteModel.contains(map.route, id) then
				warnIssue("Waypoint is not connected to the route.", { id })
			end
		end

		local inst = session.instances[id]
		if inst then
			idOf[inst] = id
			if def.blocksPath then
				table.insert(blocking, inst)
			end
			if def.periFolder and def.periFolder ~= "InvisWalls" and def.role ~= Catalog.ROLE.NoBuild then
				table.insert(ground, inst)
				if def.periFolder == "Path" then
					pathSet[inst] = true
				end
			end
		end

		if def.periFolder == "Path" and def.role ~= Catalog.ROLE.NoBuild then
			hasPath = true
		end
		if def.periFolder == "Locked" or (def.periFolder == "Terrain" and def.kind == "Part") then
			hasGround = true
		end
	end

	if result.objects > Config.MAX_OBJECTS then
		err(string.format("Too many objects (%d of %d).", result.objects, Config.MAX_OBJECTS))
	end
	local spawnLanes = {}
	for _, spawn in spawns do
		spawnLanes[RouteModel.spawnLane(spawn)] = true
	end
	for _, lane in map.route.lanes or {} do
		if #lane.ids > 0 and not spawnLanes[lane.lane] then
			warnIssue(string.format("Lane %s has %d Waypoint %s's but no Enemy Spawn %s; enemies won't use them.", lane.lane, #lane.ids, lane.lane, lane.lane), table.clone(lane.ids))
		end
	end

	if #spawns == 0 then
		err("Missing enemy spawn point.")
	elseif #spawns > Config.MAX_ENEMY_SPAWNS then
		err(string.format("At most %d enemy spawns are supported.", Config.MAX_ENEMY_SPAWNS))
	end
	if not base then
		err("Missing base (destination).")
	end
	if not playerSpawn then
		warnIssue("No player spawn: players will appear at the enemy spawn.")
	end
	if not hasGround then
		warnIssue("No ground pieces: the map has nothing for players to stand on outside the path.")
	end
	if not hasPath then
		warnIssue("No path pieces. Peri only refuses towers on Path pieces, so towers could be placed on the enemy route.")
	end

	if #spawns == 0 or not base then
		return result
	end

	for _, spawn in spawns do
		if (Serializer.toVector(spawn.p) - Serializer.toVector(base.p)).Magnitude < Config.VALIDATION.MinSpawnBaseDistance then
			err("An enemy spawn and the base are too close together.", { spawn.id, base.id })
		end
	end
	if #spawns == 2 and (Serializer.toVector(spawns[1].p) - Serializer.toVector(spawns[2].p)).Magnitude < Config.VALIDATION.MinSpawnBaseDistance then
		warnIssue("The two enemy spawns are almost on top of each other.", { spawns[1].id, spawns[2].id })
	end

	if RouteModel.combinations(map.route, #spawns) > Config.MAX_ROUTES then
		err(string.format("Forks create more than %d routes; Peri would use only the first branch of each fork.", Config.MAX_ROUTES))
		return result
	end

	local nodes = PeriMapAdapter.buildNodesFolder(map, origin)
	if not nodes then
		return result
	end
	local routes = PathUtil.BuildRoutes(nodes)
	nodes:Destroy()
	result.routes = #routes

	local bodyParams = RaycastParams.new()
	bodyParams.FilterType = Enum.RaycastFilterType.Include
	bodyParams.FilterDescendantsInstances = blocking

	local groundParams = RaycastParams.new()
	groundParams.FilterType = Enum.RaycastFilterType.Include
	groundParams.FilterDescendantsInstances = ground

	local step = Config.VALIDATION.SampleStep
	local up = Vector3.new(0, Config.VALIDATION.BodyHeight, 0)
	local probe = Vector3.new(0, -Config.VALIDATION.GroundProbe, 0)

	local blockedBy: { [string]: Vector3 } = {}
	local gapCount, gapAt = 0, nil :: Vector3?
	local unpavedCount, unpavedAt = 0, nil :: Vector3?
	local sampled: { [string]: boolean } = {}

	local function rootId(hit: Instance): string?
		local current: Instance? = hit
		while current do
			local id = idOf[current]
			if id then
				return id
			end
			current = current.Parent
		end
		return nil
	end

	local function isPath(hit: Instance): boolean
		local current: Instance? = hit
		while current do
			if pathSet[current] then
				return true
			end
			current = current.Parent
		end
		return false
	end

	for _, route in routes do
		local smooth = route.smooth
		table.insert(result.lengths, Serializer.round(smooth.length, 10))
		if smooth.length <= 0 then
			continue
		end

		local previous: Vector3? = nil
		local d = 0
		while true do
			local position = PathUtil.GetPositionAtDistance(smooth, d) :: Vector3
			local key = string.format("%.1f/%.1f/%.1f", position.X, position.Y, position.Z)

			if not sampled[key] then
				sampled[key] = true

				if previous and #blocking > 0 then
					local from = previous + up
					local to = position + up
					local hit = workspace:Raycast(from, to - from, bodyParams)
					if hit then
						local id = rootId(hit.Instance)
						if id and not blockedBy[id] then
							blockedBy[id] = hit.Position
						end
					end
				end

				local groundHit = workspace:Raycast(position + Vector3.new(0, 2, 0), probe, groundParams)
				if not groundHit then
					gapCount += 1
					gapAt = gapAt or position
				elseif not isPath(groundHit.Instance) then
					unpavedCount += 1
					unpavedAt = unpavedAt or position
				end
			end

			previous = position
			if d >= smooth.length then
				break
			end
			d = math.min(d + step, smooth.length)
		end
	end

	local function localPos(world: Vector3): Vector3
		return origin:PointToObjectSpace(world)
	end

	for id, at in blockedBy do
		local rec = map.objects[id]
		local def = rec and Catalog.get(rec.t)
		err(string.format("Enemy route passes through %s.", def and def.name or "an object"), { id }, localPos(at))
	end
	if gapCount > 0 and gapAt then
		err(string.format("Route crosses about %d stud(s) with no ground under it.", gapCount * step), {}, localPos(gapAt))
	end
	if unpavedCount > 0 and unpavedAt then
		warnIssue(string.format("About %d stud(s) of route are not on Path pieces; towers can be placed on the route there.", unpavedCount * step), {}, localPos(unpavedAt))
	end

	return result
end

return MapValidation
