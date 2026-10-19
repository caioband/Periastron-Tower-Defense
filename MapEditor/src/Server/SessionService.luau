--!strict
--[[
	Authoritative edit sessions, one per player.

	The map table is the source of truth; Instances in the session folder are a
	projection of it, rebuilt from trusted templates. Records are stored in plot
	local space; the plot origin (a pure translation) is applied when building
	Instances, so two builders never overlap and saved coordinates do not depend
	on which plot a player got.
]]
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("MapEditor")
local Config = require(Shared.Config)
local Catalog = require(Shared.Catalog)
local Serializer = require(Shared.Serializer)
local RouteModel = require(Shared.RouteModel)
local MapRules = require(Shared.MapRules)
local Factory = require(Shared.InstanceFactory)

type Map = Serializer.Map
type Record = Serializer.Record

export type Session = {
	player: Player,
	plotIndex: number,
	origin: CFrame,
	map: Map,
	folder: Folder,
	objectsFolder: Folder,
	floor: BasePart?,
	instances: { [string]: Instance },
	dirty: boolean,
	savedOnce: boolean,
	mode: string,
	lastSave: number,
	lastLoad: number,
	busy: boolean,
	push: (kind: string, data: any) -> (),
}

local SessionService = {}
SessionService.sessions = {} :: { [Player]: Session }

local plots: { [number]: Player } = {}
local root: Folder

local function templates(): Instance
	return Shared:WaitForChild("Templates")
end

function SessionService.init()
	local existing = workspace:FindFirstChild("MapEditor")
	if existing then
		existing:Destroy()
	end
	root = Instance.new("Folder")
	root.Name = "MapEditor"
	root.Parent = workspace
	local sessions = Instance.new("Folder")
	sessions.Name = "Sessions"
	sessions.Parent = root
end

function SessionService.get(player: Player): Session?
	return SessionService.sessions[player]
end

local function allocatePlot(player: Player): number
	local index = 0
	while plots[index] do
		index += 1
	end
	plots[index] = player
	return index
end

local function buildFloor(origin: CFrame, parent: Instance): BasePart
	local floor = Instance.new("Part")
	floor.Name = "PlotFloor"
	floor.Size = Config.PLOT_FLOOR_SIZE
	floor.CFrame = origin * CFrame.new(0, -Config.PLOT_FLOOR_SIZE.Y / 2, 0)
	floor.Anchored = true
	floor.Color = Color3.fromHex("3A3F45")
	floor.Material = Enum.Material.SmoothPlastic
	floor.TopSurface = Enum.SurfaceType.Smooth
	floor:SetAttribute("EditorFloor", true)
	floor.Parent = parent
	return floor
end

function SessionService.routeJson(map: Map): string
	return HttpService:JSONEncode(map.route)
end

function SessionService.syncRoute(session: Session)
	session.folder:SetAttribute("Route", SessionService.routeJson(session.map))
end

function SessionService.syncMeta(session: Session)
	session.folder:SetAttribute("MapId", session.map.id)
	session.folder:SetAttribute("MapName", session.map.name)
	session.folder:SetAttribute("Dirty", session.dirty)
	session.folder:SetAttribute("Mode", session.mode)
end

local function syncInstance(session: Session, id: string)
	local rec = session.map.objects[id]
	local inst = session.instances[id]

	if not rec then
		if inst then
			inst:Destroy()
			session.instances[id] = nil
		end
		return
	end

	if inst and Factory.needsRebuild(inst, rec) then
		inst:Destroy()
		inst = nil
		session.instances[id] = nil
	end

	if inst then
		Factory.apply(inst, rec, session.origin, false)
		return
	end

	local built = Factory.build(rec, templates(), session.origin, false)
	if not built then
		warn("[MapEditor] Could not build " .. rec.t .. " (" .. id .. ")")
		return
	end
	built.Parent = session.objectsFolder
	session.instances[id] = built
end

function SessionService.enter(player: Player, push: (string, any) -> ()): Session
	local existing = SessionService.sessions[player]
	if existing then
		return existing
	end

	local plotIndex = allocatePlot(player)
	local origin = CFrame.new(plotIndex * Config.PLOT_SPACING, 0, 0)

	local folder = Instance.new("Folder")
	folder.Name = tostring(player.UserId)
	folder:SetAttribute("OriginX", origin.X)
	folder:SetAttribute("PlotIndex", plotIndex)

	local objectsFolder = Instance.new("Folder")
	objectsFolder.Name = "Objects"
	objectsFolder.Parent = folder

	local floor: BasePart? = nil
	local baseplate = workspace:FindFirstChild("Baseplate")
	if plotIndex > 0 or not baseplate then
		floor = buildFloor(origin, folder)
	end

	local session: Session = {
		player = player,
		plotIndex = plotIndex,
		origin = origin,
		map = Serializer.blankMap(player.UserId),
		folder = folder,
		objectsFolder = objectsFolder,
		floor = floor,
		instances = {},
		dirty = false,
		savedOnce = false,
		mode = "Build",
		lastSave = 0,
		lastLoad = 0,
		busy = false,
		push = push,
	}

	SessionService.syncRoute(session)
	SessionService.syncMeta(session)
	folder.Parent = root:FindFirstChild("Sessions")
	SessionService.sessions[player] = session
	return session
end

function SessionService.exit(player: Player)
	local session = SessionService.sessions[player]
	if not session then
		return
	end
	SessionService.sessions[player] = nil
	plots[session.plotIndex] = nil
	session.folder:Destroy()
end

export type ApplyResult = { records: { [string]: Record | boolean }, route: Serializer.Route, pruned: { string } }

function SessionService.applyOps(session: Session, ops: any): (boolean, string?, ApplyResult?)
	if session.mode ~= "Build" then
		return false, "Stop the playtest before editing.", nil
	end
	if session.busy then
		return false, "Please wait for the map to finish loading.", nil
	end
	if typeof(ops) ~= "table" or #ops == 0 then
		return false, "Nothing to apply.", nil
	end
	if #ops > Config.MAX_OPS_PER_REQUEST then
		return false, "Too many changes at once.", nil
	end

	local objects = table.clone(session.map.objects)
	local route = session.map.route
	local touched: { [string]: boolean } = {}
	local routeExplicit = false
	local count = 0
	for _ in objects do
		count += 1
	end

	for index, op in ops do
		if typeof(op) ~= "table" then
			return false, "Malformed change.", nil
		end

		if op.op == "put" then
			local ok, err, rec = MapRules.sanitizeRecord(op.rec)
			if not ok or not rec then
				return false, string.format("Change %d: %s", index, err or "invalid"), nil
			end
			local existing = objects[rec.id]
			if existing and existing.t ~= rec.t then
				return false, "An object cannot change type.", nil
			end
			if not existing then
				count += 1
				if count > Config.MAX_OBJECTS then
					return false, string.format("Object limit reached (%d).", Config.MAX_OBJECTS), nil
				end
			end
			local def = Catalog.get(rec.t) :: Catalog.Def
			local limit = Catalog.limit(def)
			if limit then
				local others = 0
				for otherId, other in objects do
					if other.t == rec.t and otherId ~= rec.id then
						others += 1
					end
				end
				if others >= limit then
					if limit == 1 then
						return false, string.format("The map already has a %s.", def.name), nil
					end
					return false, string.format("A map can have at most %d %ss.", limit, def.name), nil
				end
			end
			objects[rec.id] = rec
			touched[rec.id] = true
		elseif op.op == "del" then
			local id = op.id
			if typeof(id) ~= "string" or not objects[id] then
				return false, "That object no longer exists.", nil
			end
			if objects[id].lk then
				return false, "Unlock the object before deleting it.", nil
			end
			objects[id] = nil
			count -= 1
			touched[id] = true
		elseif op.op == "route" then
			local ok, err, clean = RouteModel.sanitize(op.route)
			if not ok or not clean then
				return false, err, nil
			end
			route = clean
			routeExplicit = true
		else
			return false, "Unknown change type.", nil
		end
	end

	if routeExplicit then
		local strictOk, strictErr = RouteModel.validate(route, objects)
		if not strictOk then
			return false, strictErr, nil
		end
	end

	local prunedRoute, pruned = RouteModel.prune(route, objects)
	local valid, routeErr = RouteModel.validate(prunedRoute, objects)
	if not valid then
		return false, routeErr, nil
	end

	session.map.objects = objects
	session.map.route = prunedRoute
	session.map.modified = os.time()
	session.dirty = true

	local records: { [string]: Record | boolean } = {}
	for id in touched do
		syncInstance(session, id)
		records[id] = objects[id] or false
	end
	SessionService.syncRoute(session)
	SessionService.syncMeta(session)

	return true, nil, { records = records, route = prunedRoute, pruned = pruned }
end

function SessionService.sanitizeMap(map: Map): (Map, { string })
	local warnings = {}
	local clean: { [string]: Record } = {}
	local seenLimited: { [string]: number } = {}
	local unknown, invalid, extra, total = 0, 0, 0, 0

	local ids = {}
	for id in map.objects do
		table.insert(ids, id)
	end
	table.sort(ids)

	for _, id in ids do
		local raw = map.objects[id]
		if not Catalog.get(raw and raw.t) then
			unknown += 1
			continue
		end
		local ok, _, rec = MapRules.sanitizeRecord(raw)
		if not ok or not rec then
			invalid += 1
			continue
		end
		local def = Catalog.get(rec.t) :: Catalog.Def
		local limit = Catalog.limit(def)
		if limit then
			local seen = seenLimited[def.id] or 0
			if seen >= limit then
				extra += 1
				continue
			end
			seenLimited[def.id] = seen + 1
		end
		total += 1
		if total > Config.MAX_OBJECTS then
			continue
		end
		clean[rec.id] = rec
	end

	if unknown > 0 then
		table.insert(warnings, string.format("%d object(s) of removed catalog types were skipped.", unknown))
	end
	if invalid > 0 then
		table.insert(warnings, string.format("%d invalid object(s) were skipped.", invalid))
	end
	if extra > 0 then
		table.insert(warnings, string.format("%d duplicate unique marker(s) were skipped.", extra))
	end
	if total > Config.MAX_OBJECTS then
		table.insert(warnings, string.format("Only the first %d objects were loaded.", Config.MAX_OBJECTS))
	end

	local okRoute, _, route = RouteModel.sanitize(map.route)
	local pruned: { string } = {}
	local finalRoute = RouteModel.empty()
	if okRoute and route then
		finalRoute, pruned = RouteModel.prune(route, clean)
		local valid, err = RouteModel.validate(finalRoute, clean)
		if not valid then
			table.insert(warnings, "Route reset: " .. tostring(err))
			finalRoute = RouteModel.empty()
		end
	else
		table.insert(warnings, "Route data was malformed and was reset.")
	end
	if #pruned > 0 then
		table.insert(warnings, string.format("%d route reference(s) to missing waypoints were removed.", #pruned))
	end

	map.objects = clean
	map.route = finalRoute
	return map, warnings
end

function SessionService.pushSnapshot(session: Session)
	local list = {}
	for _, rec in session.map.objects do
		table.insert(list, rec)
	end
	session.push("SnapshotBegin", {
		id = session.map.id,
		name = session.map.name,
		route = session.map.route,
		total = #list,
		originX = session.origin.X,
		dirty = session.dirty,
	})
	for i = 1, #list, Config.SNAPSHOT_CHUNK do
		session.push("SnapshotChunk", table.move(list, i, math.min(i + Config.SNAPSHOT_CHUNK - 1, #list), 1, {}))
	end
	session.push("SnapshotEnd", { total = #list })
end

function SessionService.replaceMap(session: Session, map: Map): { string }
	session.busy = true
	local clean, warnings = SessionService.sanitizeMap(map)

	for id, inst in session.instances do
		inst:Destroy()
		session.instances[id] = nil
	end

	session.map = clean
	session.dirty = false

	local built = 0
	for id in clean.objects do
		syncInstance(session, id)
		built += 1
		if built % Config.BUILD_CHUNK == 0 then
			task.wait()
			if SessionService.sessions[session.player] ~= session then
				return warnings
			end
		end
	end

	SessionService.syncRoute(session)
	SessionService.syncMeta(session)
	session.busy = false
	SessionService.pushSnapshot(session)
	return warnings
end

function SessionService.objectWorldPosition(session: Session, id: string): Vector3?
	local rec = session.map.objects[id]
	if not rec then
		return nil
	end
	return session.origin * Serializer.toVector(rec.p)
end

return SessionService
