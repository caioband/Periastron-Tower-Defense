local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("MapEditor")
local Config = require(Shared.Config)
local Catalog = require(Shared.Catalog)
local Serializer = require(Shared.Serializer)
local RouteModel = require(Shared.RouteModel)
local MapRules = require(Shared.MapRules)
local Factory = require(Shared.InstanceFactory)
local PlacementUtil = require(Shared.PlacementUtil)

local State = require(script.Parent.State)
local Net = require(script.Parent.Net)
local History = require(script.Parent.History)
local BuildCamera = require(script.Parent.BuildCamera)
local Placement = require(script.Parent.Placement)
local Selection = require(script.Parent.Selection)
local Gizmos = require(script.Parent.Gizmos)
local RouteView = require(script.Parent.RouteView)
local Geometry = require(script.Parent.Geometry)
local UI = require(script.Parent.UI)
local Maid = require(script.Parent.Maid)
local Pointer = require(script.Parent.Pointer)
local MobileControls = require(script.Parent.MobileControls)
local Hotkeys = require(script.Parent.Hotkeys)

local player = Players.LocalPlayer

local Editor = {}
local maid = Maid.new()
local requestInFlight = false
local pendingSnapshot = nil
local boxStart = nil
local boxMoved = false
local towerGhost = nil
local excludeClock = 0
local savedOnce = false
local memoryWarned = false
local enteredAt = 0
local lastPlacementTap = nil

local BOX_THRESHOLD = 6
local TAP_CONFIRM_RADIUS = 36

local function shiftDown()
	return UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
end

-- Server pushes ---------------------------------------------------------------

Net.on("SnapshotBegin", function(data)
	pendingSnapshot = { id = data.id, name = data.name, route = data.route, objects = {} }
	State.origin = CFrame.new(data.originX, 0, 0)
	State.dirty = data.dirty
	State.loading = true
end)

Net.on("SnapshotChunk", function(list)
	if pendingSnapshot then
		for _, rec in list do
			pendingSnapshot.objects[rec.id] = rec
		end
	end
end)

Net.on("SnapshotEnd", function()
	if not pendingSnapshot then
		return
	end
	State.map = { id = pendingSnapshot.id, name = pendingSnapshot.name, objects = pendingSnapshot.objects, route = pendingSnapshot.route }
	pendingSnapshot = nil
	State.loading = false
	State.insertAfter = nil
	History.clear()
	State.setSelection({})
	State.emit("map")
end)

Net.on("Toast", function(data)
	UI.toast(data.text, data.kind)
end)

Net.on("Playtest", function(stats)
	if stats.state == "Stopped" then
		if State.mode == "Playtest" then
			Editor.leavePlaytestLocally()
		end
		UI.toast(string.format("Test ended: %d killed, %d leaked, base %d.", stats.killed or 0, stats.leaked or 0, stats.baseHealth or 0), "info")
	else
		UI.setPlaytestStats(stats)
	end
end)

-- Helpers ---------------------------------------------------------------------

local function refreshExcluded()
	local list = {}
	local route = RouteView.folder()
	if route then
		table.insert(list, route)
	end
	for _, name in { "EditorSelection", "EditorGizmoProxy" } do
		local inst = workspace.CurrentCamera:FindFirstChild(name)
		if inst then
			table.insert(list, inst)
		end
	end
	for id, rec in State.map.objects do
		local def = Catalog.get(rec.t)
		if def and (def.kind == "Marker" or def.editorTransparency ~= nil) then
			local inst = State.instanceFor(id)
			if inst then
				table.insert(list, inst)
			end
		end
	end
	Placement.excluded = list
end

local function copyRecord(rec)
	return Serializer.copy(rec)
end

local function restoreVisual(ids)
	for _, id in ids do
		local rec = State.map.objects[id]
		local inst = State.instanceFor(id)
		if rec and inst then
			Factory.apply(inst, rec, State.origin, false)
		end
	end
end

local function sendOps(ops)
	if requestInFlight then
		return { ok = false, err = "Still saving the last change..." }
	end
	requestInFlight = true
	local response = Net.request("Apply", { ops = ops })
	requestInFlight = false
	return response
end

function Editor.change(label, puts, dels, newRoute, options)
	puts = puts or {}
	dels = dels or {}
	if #puts == 0 and #dels == 0 and not newRoute then
		return false
	end

	local forward, inverseDels, inversePuts = {}, {}, {}
	for _, id in dels do
		local old = State.map.objects[id]
		if old then
			table.insert(forward, { op = "del", id = id })
			table.insert(inversePuts, { op = "put", rec = copyRecord(old) })
		end
	end
	for _, rec in puts do
		table.insert(forward, { op = "put", rec = rec })
		local old = State.map.objects[rec.id]
		if old then
			table.insert(inversePuts, { op = "put", rec = copyRecord(old) })
		else
			table.insert(inverseDels, { op = "del", id = rec.id })
		end
	end
	local inverse = {}
	for _, op in inverseDels do
		table.insert(inverse, op)
	end
	for _, op in inversePuts do
		table.insert(inverse, op)
	end
	if newRoute then
		table.insert(forward, { op = "route", route = newRoute })
		table.insert(inverse, { op = "route", route = RouteModel.clone(State.map.route) })
	end

	local response = sendOps(forward)
	if not response.ok then
		UI.toast(response.err or "Change rejected.", "error")
		local ids = {}
		for _, rec in puts do
			table.insert(ids, rec.id)
		end
		restoreVisual(ids)
		return false
	end

	State.applyRecords(response.data.records, response.data.route)
	State.dirty = true
	if not (options and options.noHistory) then
		History.push({ label = label, forward = forward, inverse = inverse })
	end
	if response.data.pruned and #response.data.pruned > 0 then
		UI.toast(string.format("%d waypoint(s) were removed from the route.", #response.data.pruned), "info")
	end
	return true, response.data
end

function Editor.undo()
	local entry = History.peekUndo()
	if not entry then
		UI.toast("Nothing to undo.", "info")
		return
	end
	Placement.cancel()
	Gizmos.cancel()
	local response = sendOps(entry.inverse)
	if not response.ok then
		UI.toast("Undo failed: " .. tostring(response.err), "error")
		return
	end
	History.moveToRedo()
	State.applyRecords(response.data.records, response.data.route)
	State.dirty = true
	UI.toast("Undo: " .. entry.label, "info")
end

function Editor.redo()
	local entry = History.peekRedo()
	if not entry then
		UI.toast("Nothing to redo.", "info")
		return
	end
	Placement.cancel()
	Gizmos.cancel()
	local response = sendOps(entry.forward)
	if not response.ok then
		UI.toast("Redo failed: " .. tostring(response.err), "error")
		return
	end
	History.moveToUndo()
	State.applyRecords(response.data.records, response.data.route)
	State.dirty = true
	UI.toast("Redo: " .. entry.label, "info")
end

local function editableIds(ids)
	local out, locked = {}, 0
	for _, id in ids do
		local rec = State.map.objects[id]
		if rec then
			if rec.lk then
				locked += 1
			else
				table.insert(out, id)
			end
		end
	end
	if locked > 0 then
		UI.toast(string.format("%d locked object(s) were skipped. Unlock with L.", locked), "warn")
	end
	return out
end

local function relativeRecords(ids)
	local recs = {}
	for _, id in ids do
		local rec = State.map.objects[id]
		if rec then
			table.insert(recs, rec)
		end
	end
	if #recs == 0 then
		return {}
	end
	local sum, minY = Vector3.zero, math.huge
	for _, rec in recs do
		local p = Serializer.toVector(rec.p)
		sum += p
		minY = math.min(minY, p.Y)
	end
	local center = sum / #recs
	local pivot = CFrame.new(center.X, minY, center.Z)
	local out = {}
	for i, rec in recs do
		local copy = copyRecord(rec)
		copy.id = "rel" .. i
		copy.lk = nil
		Serializer.setCFrame(copy, pivot:ToObjectSpace(Serializer.recordCFrame(rec)))
		table.insert(out, copy)
	end
	return out
end

local function selectionBounds(ids)
	local instances = {}
	for _, id in ids do
		local inst = State.instanceFor(id)
		if inst then
			table.insert(instances, inst)
		end
	end
	return Geometry.bounds(instances)
end

-- Selection actions ------------------------------------------------------------

function Editor.delete()
	local ids = editableIds(State.selection)
	if #ids == 0 then
		return
	end
	local route = RouteModel.clone(State.map.route)
	local routeChanged = false
	for _, id in ids do
		if RouteModel.remove(route, id) then
			routeChanged = true
		end
	end
	if Editor.change(string.format("Delete %d object(s)", #ids), {}, ids, routeChanged and route or nil) then
		State.clearSelection()
	end
end

function Editor.duplicate()
	local ids = State.selection
	if #ids == 0 then
		return
	end
	local offset = State.gridOn and math.max(State.gridSize(), 1) or 2
	local puts, skipped = {}, 0
	for _, id in ids do
		local rec = State.map.objects[id]
		local def = rec and Catalog.get(rec.t)
		if def then
			if Catalog.limit(def) then
				skipped += 1
			else
				local copy = copyRecord(rec)
				copy.id = Serializer.newId()
				copy.lk = nil
				copy.p = Serializer.vec(Serializer.toVector(rec.p) + Vector3.new(offset, 0, 0))
				table.insert(puts, copy)
			end
		end
	end
	if skipped > 0 then
		UI.toast("Spawns and the base were not duplicated; place them from the catalog.", "warn")
	end
	if #puts == 0 then
		return
	end
	if Editor.change(string.format("Duplicate %d object(s)", #puts), puts, {}) then
		local newIds = {}
		for _, rec in puts do
			table.insert(newIds, rec.id)
		end
		State.setSelection(newIds)
	end
end

function Editor.copy()
	if #State.selection == 0 then
		return
	end
	local items = {}
	for _, rec in relativeRecords(State.selection) do
		local def = Catalog.get(rec.t)
		if def and not Catalog.limit(def) then
			table.insert(items, rec)
		end
	end
	if #items == 0 then
		UI.toast("Spawns and the base cannot be copied.", "warn")
		return
	end
	State.clipboard = items
	if Pointer.isTouch() then
		UI.toast(string.format("Copied %d object(s). Tap Paste to place.", #items), "info")
	else
		UI.toast(string.format("Copied %d object(s). Ctrl+V to place.", #items), "info")
	end
end

function Editor.paste()
	if not State.clipboard or #State.clipboard == 0 then
		UI.toast("Clipboard is empty.", "info")
		return
	end
	State.clearSelection()
	Placement.begin(Serializer.copy(State.clipboard), { kind = "paste", label = "Paste" })
end

function Editor.toggleLock()
	local ids = State.selection
	if #ids == 0 then
		return
	end
	local anyUnlocked = false
	for _, id in ids do
		local rec = State.map.objects[id]
		if rec and not rec.lk then
			anyUnlocked = true
		end
	end
	local puts = {}
	for _, id in ids do
		local rec = State.map.objects[id]
		if rec then
			local copy = copyRecord(rec)
			copy.lk = anyUnlocked or nil
			table.insert(puts, copy)
		end
	end
	Editor.change(anyUnlocked and "Lock" or "Unlock", puts, {})
end

function Editor.rotateSelection(axis, degrees)
	local ids = editableIds(State.selection)
	if #ids == 0 then
		return
	end
	local primary = State.map.objects[State.primary()] or State.map.objects[ids[1]]
	local center = Serializer.toVector(primary.p)
	local turn = CFrame.new(center) * CFrame.fromAxisAngle(axis, math.rad(degrees)) * CFrame.new(-center)
	local puts = {}
	for _, id in ids do
		local rec = State.map.objects[id]
		local def = Catalog.get(rec.t)
		local copy = copyRecord(rec)
		local rotated = turn * Serializer.recordCFrame(rec)
		if def and (not def.rotatable or (def.yawOnly and axis ~= Vector3.yAxis)) then
			copy.p = Serializer.vec(rotated.Position)
		else
			Serializer.setCFrame(copy, rotated)
		end
		table.insert(puts, copy)
	end
	Editor.change("Rotate", puts, {})
end

function Editor.savePrefab()
	if #State.selection == 0 then
		return
	end
	local items = relativeRecords(State.selection)
	UI.prompt("Prefab name", "My Prefab", function(name)
		local response = Net.request("PrefabSave", { name = name, objects = items })
		if not response.ok then
			UI.toast(response.err, "error")
			return
		end
		State.prefabs = response.data.prefabs
		UI.toast("Prefab saved. Find it under Prefabs.", "ok")
		UI.refreshCatalog()
	end)
end

function Editor.focusSelection()
	local lo, hi = selectionBounds(State.selection)
	if lo then
		BuildCamera.focus((lo + hi) / 2, (hi - lo).Magnitude / 2)
	end
end

local SHAPE_CYCLE = { Block = "Ball", Ball = "Cylinder", Cylinder = "Wedge", Wedge = "CornerWedge", CornerWedge = "Block" }

function Editor.setProperty(field, value)
	local shared = field == "c" or field == "m"
	local ids = if shared then State.selection else { State.primary() }
	ids = editableIds(ids)
	local puts = {}
	for _, id in ids do
		local rec = State.map.objects[id]
		local def = rec and Catalog.get(rec.t)
		if not def then
			continue
		end
		local copy = copyRecord(rec)
		if field == "px" or field == "py" or field == "pz" then
			local index = field == "px" and 1 or field == "py" and 2 or 3
			copy.p[index] = value
			if not MapRules.inBounds(Serializer.toVector(copy.p)) then
				UI.toast("That position is outside the build area.", "warn")
				UI.refreshInspector(true)
				return
			end
		elseif field == "rx" or field == "ry" or field == "rz" then
			local index = field == "rx" and 1 or field == "ry" and 2 or 3
			copy.r[index] = Serializer.normalizeAngle(value)
		elseif field == "sx" or field == "sy" or field == "sz" then
			if not copy.s then
				continue
			end
			local index = field == "sx" and 1 or field == "sy" and 2 or 3
			local lo, hi = def.minSize, def.maxSize
			local axisMin = lo and ({ lo.X, lo.Y, lo.Z })[index] or 0.1
			local axisMax = hi and ({ hi.X, hi.Y, hi.Z })[index] or 512
			local clamped = math.clamp(value, axisMin, axisMax)
			if clamped ~= value then
				UI.toast(string.format("Size limited to %g - %g.", axisMin, axisMax), "warn")
			end
			if def.uniform then
				copy.s = { clamped, clamped, clamped }
			else
				copy.s[index] = clamped
			end
		elseif field == "sc" then
			copy.sc = math.clamp(value, def.minScale or 0.25, def.maxScale or math.huge)
		elseif field == "tr" then
			copy.tr = math.clamp(value, 0, 0.95)
		elseif field == "c" then
			if not def.allowColor then
				continue
			end
			copy.c = value
		elseif field == "m" then
			if not def.allowMaterial then
				continue
			end
			copy.m = value
		elseif field == "sh" then
			copy.sh = SHAPE_CYCLE[copy.sh or "Block"]
		end
		table.insert(puts, copy)
	end
	if #puts > 0 then
		Editor.change("Edit property", puts, {})
		UI.refreshInspector(true)
	end
end

-- Route actions ------------------------------------------------------------------

local function waypointDef()
	return Catalog.waypointFor(nil)
end

local function canFollow(refId, def)
	local refDef = refId and State.def(refId)
	if not refDef then
		return false
	end
	if refDef.role == Catalog.ROLE.EnemySpawn then
		return def.lane == nil or refDef.lane == def.lane
	end
	return refDef.role == Catalog.ROLE.Waypoint and refDef.lane == def.lane and RouteModel.contains(State.map.route, refId)
end

local function placeWaypoint(route, id, def, refId)
	local refDef = refId and State.def(refId)
	if refDef and refDef.role == Catalog.ROLE.EnemySpawn then
		if def.lane and refDef.lane == def.lane then
			RouteModel.insertLaneStart(route, def.lane, id)
			return
		elseif not def.lane then
			RouteModel.insertFirst(route, id)
			return
		end
	elseif refDef and refDef.role == Catalog.ROLE.Waypoint and refDef.lane == def.lane and RouteModel.contains(route, refId) then
		RouteModel.insertAfter(route, refId, id)
		return
	end
	if def.lane then
		RouteModel.appendLane(route, def.lane, id)
	else
		RouteModel.append(route, id)
	end
end

function Editor.routeAction(kind)
	local id = State.primary()
	local rec = id and State.map.objects[id]
	if not rec then
		return
	end
	local route = RouteModel.clone(State.map.route)

	if kind == "insertNext" then
		local def = Catalog.get(rec.t)
		local typeDef = if def and def.role == Catalog.ROLE.EnemySpawn then Catalog.waypointFor(def.lane) else def
		if not typeDef then
			return
		end
		State.insertAfter = id
		RouteView.markDirty()
		Editor.selectCatalog(typeDef.id, true)
		UI.toast("Placing " .. typeDef.name .. "s after the highlighted marker. Hold Shift to keep placing.", "info")
	elseif kind == "unlink" then
		RouteModel.remove(route, id)
		Editor.change("Unlink waypoint", {}, {}, route)
	elseif kind == "link" then
		local def = Catalog.get(rec.t)
		if def and def.lane then
			RouteModel.appendLane(route, def.lane, id)
		else
			RouteModel.append(route, id)
		end
		Editor.change("Link waypoint", {}, {}, route)
	elseif kind == "addBranch" then
		local s, a, i = RouteModel.find(route, id)
		if not (s and a and i) then
			UI.toast("Forks can only be added to the shared path (Waypoint C), not to lane A or B.", "warn")
			return
		end
		local step = route.steps[s]
		if #step.alts >= Config.MAX_ALTERNATIVES then
			UI.toast("A fork can have at most " .. Config.MAX_ALTERNATIVES .. " branches.", "warn")
			return
		end
		local target = s
		if #step.alts == 1 then
			local alt = step.alts[1]
			local before = table.move(alt, 1, i - 1, 1, {})
			local after = table.move(alt, i + 1, #alt, 1, {})
			local replacement = {}
			if #before > 0 then
				table.insert(replacement, { alts = { before } })
			end
			table.insert(replacement, { alts = { { id } } })
			target = s + #replacement - 1
			if #after > 0 then
				table.insert(replacement, { alts = { after } })
			end
			table.remove(route.steps, s)
			for k = #replacement, 1, -1 do
				table.insert(route.steps, s, replacement[k])
			end
		end
		local offset = State.gridOn and math.max(State.gridSize() * 2, 4) or 4
		local newRec = { id = Serializer.newId(), t = waypointDef().id, p = Serializer.vec(Serializer.toVector(rec.p) + Vector3.new(offset, 0, offset)), r = { 0, 0, 0 } }
		RouteModel.addBranch(route, target, { newRec.id })
		if Editor.change("Add branch", { newRec }, {}, route) then
			State.setSelection({ newRec.id })
			UI.toast("Branch added. Move its waypoint, then use 'Insert next' to extend it.", "info")
		end
	elseif kind == "removeBranch" then
		local s, a = RouteModel.find(route, id)
		if not (s and a) then
			return
		end
		local removed = RouteModel.removeBranch(route, s, a)
		local dels = {}
		for _, wid in removed do
			local wrec = State.map.objects[wid]
			if wrec and not wrec.lk then
				table.insert(dels, wid)
			end
		end
		if Editor.change("Remove branch", {}, dels, route) then
			State.clearSelection()
		end
	end
end

-- Placement -----------------------------------------------------------------------

function Editor.selectCatalog(typeId, keepInsert)
	local def = Catalog.get(typeId)
	if not def or State.mode ~= "Build" or os.clock() - enteredAt < 0.4 then
		return
	end
	local limit = Catalog.limit(def)
	if limit and State.countType(def.id) >= limit then
		if limit == 1 then
			UI.toast("The map already has a " .. def.name .. ". Select it to move it.", "warn")
		else
			UI.toast(string.format("A map can have at most %d %ss.", limit, def.name), "warn")
		end
		return
	end
	if def.role == Catalog.ROLE.Waypoint then
		if not keepInsert then
			local primary = State.primary()
			if primary and canFollow(primary, def) then
				State.insertAfter = primary
			else
				State.insertAfter = nil
			end
		end
		RouteView.markDirty()
	else
		State.insertAfter = nil
	end
	State.clearSelection()
	State.markRecent(typeId)
	refreshExcluded()
	Placement.begin({ Placement.singleItem(typeId) }, { kind = "catalog", typeId = typeId, label = "Place " .. def.name })
end

function Editor.selectPrefab(prefab)
	if State.mode ~= "Build" then
		return
	end
	State.clearSelection()
	refreshExcluded()
	Placement.begin(Serializer.copy(prefab.objects), { kind = "prefab", label = "Place " .. prefab.name })
end

local function confirmPlacement()
	local records, reason = Placement.confirm()
	if not records then
		UI.toast(reason, "warn")
		return
	end
	local info = Placement.info() or {}
	local newRoute = nil
	local nextInsert = State.insertAfter
	if info.kind == "catalog" then
		for _, rec in records do
			local def = Catalog.get(rec.t)
			if def and def.role == Catalog.ROLE.Waypoint then
				newRoute = newRoute or RouteModel.clone(State.map.route)
				placeWaypoint(newRoute, rec.id, def, nextInsert)
				if nextInsert then
					nextInsert = rec.id
				end
			end
		end
	end

	local ok = Editor.change(info.label or "Place", records, {}, newRoute)
	if not ok then
		return
	end
	if newRoute and State.insertAfter then
		State.insertAfter = nextInsert
	end
	RouteView.markDirty()

	local unique = false
	for _, rec in records do
		local def = Catalog.get(rec.t)
		if def and def.unique then
			unique = true
		end
	end

	local keepPlacing = shiftDown() or (Pointer.isTouch() and info.kind == "catalog")
	if unique or not keepPlacing then
		Placement.cancel()
		local ids = {}
		for _, rec in records do
			table.insert(ids, rec.id)
		end
		State.setSelection(ids)
	end
end

-- Playtest ------------------------------------------------------------------------

local function destroyTowerGhost()
	if towerGhost then
		towerGhost:Destroy()
		towerGhost = nil
	end
end

local function towerProbe()
	local mapRoot = workspace:FindFirstChild("Map")
	if not mapRoot then
		return nil
	end
	local camera = workspace.CurrentCamera
	local mouse = Pointer.location()
	local ray = camera:ViewportPointToRay(mouse.X, mouse.Y)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { mapRoot }
	local hit = workspace:Raycast(ray.Origin, ray.Direction * 3000, params)
	if not hit then
		return nil
	end
	local size = Config.PLAYTEST.TowerSize
	local cf = CFrame.new(hit.Position + Vector3.new(0, size.Y / 2, 0))
	local probeCF, probeSize = PlacementUtil.PathProbe(cf, size)
	local grid = {}
	for _, part in CollectionService:GetTagged(Config.PERI.GridTag) do
		if part:IsDescendantOf(mapRoot) then
			table.insert(grid, part)
		end
	end
	local overlap = OverlapParams.new()
	overlap.FilterType = Enum.RaycastFilterType.Include
	overlap.FilterDescendantsInstances = grid
	local onPath = #workspace:GetPartBoundsInBox(probeCF, probeSize, overlap) > 0
	return hit.Position, cf, not onPath
end

local function updateTowerGhost()
	if not State.towerMode or State.mode ~= "Playtest" then
		destroyTowerGhost()
		return
	end
	if not towerGhost then
		towerGhost = Instance.new("Part")
		towerGhost.Name = "EditorTowerGhost"
		towerGhost.Size = Config.PLAYTEST.TowerSize
		towerGhost.Anchored = true
		towerGhost.CanCollide = false
		towerGhost.CanQuery = false
		towerGhost.CanTouch = false
		towerGhost.Material = Enum.Material.Neon
		towerGhost.Transparency = 0.5
		towerGhost.Parent = workspace.CurrentCamera
	end
	local _, cf, free = towerProbe()
	if cf then
		towerGhost.CFrame = cf
		towerGhost.Color = free and UI.THEME.Ok or UI.THEME.Danger
		towerGhost.Transparency = 0.5
	else
		towerGhost.Transparency = 1
	end
end

local function placeTower()
	local position, _, free = towerProbe()
	if not position then
		UI.toast("Point at the map.", "warn")
		return
	end
	if not free then
		UI.toast("On the path: Peri refuses towers here.", "warn")
		return
	end
	local response = Net.request("PlaytestTower", { position = Serializer.vec(position) })
	if not response.ok then
		UI.toast(response.err, "warn")
	end
end

function Editor.leavePlaytestLocally()
	State.mode = "Build"
	State.towerMode = false
	destroyTowerGhost()
	UI.setTowerMode(false)
	UI.setMode("Build")
	RouteView.markDirty()
end

function Editor.startTest()
	Placement.cancel()
	Gizmos.cancel()
	UI.toast("Preparing playtest...", "info")
	local response = Net.request("PlaytestStart")
	if not response.ok then
		UI.toast(response.err, "error")
		if response.validation then
			UI.showValidation(response.validation)
		end
		return
	end
	State.mode = "Playtest"
	State.clearSelection()
	RouteView.markDirty()
	UI.setMode("Playtest")
	local data = response.data
	UI.setPlaytestStats(data.stats)
	UI.toast(string.format("Playtest running: %d route(s) (%s studs), %d Grid parts. Spawn a wave or place towers.", data.stats.routes, table.concat(data.lengths, " / "), data.gridParts), "ok")
	if data.validation and #data.validation.warnings > 0 then
		UI.toast(string.format("%d warning(s) - see Validate after the test.", #data.validation.warnings), "warn")
	end
end

function Editor.stopTest()
	local response = Net.request("PlaytestStop")
	if not response.ok then
		UI.toast(response.err, "error")
	end
	Editor.leavePlaytestLocally()
end

-- Maps ---------------------------------------------------------------------------

function Editor.save()
	if State.mode ~= "Build" then
		UI.toast("Stop the playtest before saving.", "warn")
		return
	end
	local response = Net.request("Save")
	if not response.ok then
		UI.toast(response.err, "error")
		return
	end
	savedOnce = true
	State.dirty = false
	local errors = response.data.validation and #response.data.validation.errors or 0
	if errors > 0 then
		UI.toast(string.format("Saved. %d blocking error(s) still need fixing before the map is playable.", errors), "warn")
	else
		UI.toast("Saved.", "ok")
	end
	if response.data.memoryStorage and not memoryWarned then
		memoryWarned = true
		UI.toast("DataStores are unavailable in this Studio session: saves last until the server stops.", "warn")
	end
	UI.refreshStatus()
end

function Editor.validate()
	local response = Net.request("Validate")
	if not response.ok then
		UI.toast(response.err, "error")
		return
	end
	State.validation = response.data
	UI.showValidation(response.data)
end

function Editor.focusIssue(issue)
	if issue.ids and #issue.ids > 0 then
		State.setSelection(issue.ids)
		Editor.focusSelection()
	elseif issue.at then
		BuildCamera.focus(State.toWorldPoint(Serializer.toVector(issue.at)), 10)
	end
end

function Editor.openMaps()
	local response = Net.request("List")
	if not response.ok then
		UI.toast(response.err, "error")
		return
	end
	UI.showMaps({ maps = response.data.maps, current = response.data.current, max = response.data.max, developer = State.developer })
end

local function withDiscard(action, payload, onOk)
	local response = Net.request(action, payload)
	if not response.ok and response.confirm then
		UI.confirm("You have unsaved changes. Discard them?", "Discard", function()
			payload.discard = true
			local second = Net.request(action, payload)
			if second.ok then
				onOk(second.data)
			else
				UI.toast(second.err, "error")
			end
		end)
		return
	end
	if not response.ok then
		UI.toast(response.err, "error")
		return
	end
	onOk(response.data)
end

function Editor.loadMap(id)
	Placement.cancel()
	withDiscard("Load", { id = id }, function(data)
		UI.closeModal()
		savedOnce = true
		State.map.name = data.name
		UI.toast("Loaded '" .. data.name .. "'.", "ok")
		for _, warning in data.warnings or {} do
			UI.toast(warning, "warn")
		end
	end)
end

function Editor.newMap(name)
	Placement.cancel()
	withDiscard("New", { name = name }, function(data)
		UI.closeModal()
		savedOnce = false
		UI.toast("New map '" .. data.name .. "'. Save to keep it.", "ok")
	end)
end

function Editor.renameMap(id, name)
	local response = Net.request("Rename", { id = id, name = name })
	if not response.ok then
		UI.toast(response.err, "error")
		return
	end
	if id == State.map.id then
		State.map.name = response.data.name
		UI.refreshStatus()
	end
	Editor.openMaps()
end

function Editor.duplicateMap(id, name)
	local response = Net.request("Duplicate", { id = id, name = name })
	if not response.ok then
		UI.toast(response.err, "error")
		return
	end
	UI.toast("Copied as '" .. response.data.name .. "'.", "ok")
	Editor.openMaps()
end

function Editor.deleteMap(id)
	local response = Net.request("Delete", { id = id })
	if not response.ok then
		UI.toast(response.err, "error")
		return
	end
	if id == State.map.id then
		savedOnce = false
		State.dirty = true
	end
	UI.toast("Map deleted.", "info")
	Editor.openMaps()
end

function Editor.openImport()
	local response = Net.request("ImportList")
	if not response.ok then
		UI.toast(response.err, "error")
		return
	end
	UI.showImport(response.data.names)
end

function Editor.importPeri(name)
	Placement.cancel()
	withDiscard("ImportPeri", { name = name }, function(data)
		UI.closeModal()
		savedOnce = false
		UI.toast(string.format("Imported '%s': %d objects, %d waypoints.", name, data.report.imported, data.report.waypoints), "ok")
		for _, line in data.report.skipped do
			UI.toast("Skipped: " .. line, "warn")
		end
		for _, warning in data.warnings or {} do
			UI.toast(warning, "warn")
		end
	end)
end

function Editor.exportPeri()
	UI.prompt("Export folder name", State.map.name, function(name)
		local response = Net.request("ExportPeri", { name = name })
		if not response.ok then
			UI.toast(response.err, "error")
			if response.validation then
				UI.showValidation(response.validation)
			end
			return
		end
		UI.toast("Exported to " .. response.data.path .. " (" .. response.data.report.objects .. " objects, " .. response.data.report.nodeSteps .. " node steps).", "ok")
	end)
end

function Editor.loadPrefabs()
	local response = Net.request("PrefabList")
	if response.ok then
		State.prefabs = response.data.prefabs
		UI.refreshCatalog()
	else
		UI.toast(response.err, "error")
	end
end

function Editor.deletePrefab(id)
	local response = Net.request("PrefabDelete", { id = id })
	if response.ok then
		State.prefabs = response.data.prefabs
		UI.refreshCatalog()
	else
		UI.toast(response.err, "error")
	end
end

-- Session ------------------------------------------------------------------------

local function onInputBegan(input, processed)
	if not State.active then
		return
	end
	local keyCode = input.KeyCode
	local ctrl = UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) or UserInputService:IsKeyDown(Enum.KeyCode.RightControl)
	local shift = shiftDown()

	if input.UserInputType == Enum.UserInputType.Keyboard then
		if UserInputService:GetFocusedTextBox() then
			return
		end
		if keyCode == Enum.KeyCode.Escape then
			if UI.modalOpen() then
				UI.closeModal()
			elseif State.towerMode then
				State.towerMode = false
				UI.setTowerMode(false)
			else
				State.insertAfter = nil
				RouteView.markDirty()
				State.clearSelection()
			end
			return
		end
		if processed or UI.modalOpen() then
			return
		end
		if State.mode ~= "Build" then
			if keyCode == Enum.KeyCode.T then
				Editor.toggleTowerMode()
			elseif keyCode == Enum.KeyCode.X and State.towerMode then
				State.towerMode = false
				UI.setTowerMode(false)
			end
			return
		end
		if keyCode == Enum.KeyCode.X and not ctrl then
			if Placement.isActive() then
				Placement.cancel()
			end
			return
		end
		if ctrl then
			if keyCode == Enum.KeyCode.Z then
				if shift then
					Editor.redo()
				else
					Editor.undo()
				end
			elseif keyCode == Enum.KeyCode.Y then
				Editor.redo()
			elseif keyCode == Enum.KeyCode.D then
				Editor.duplicate()
			elseif keyCode == Enum.KeyCode.C then
				Editor.copy()
			elseif keyCode == Enum.KeyCode.V then
				Editor.paste()
			elseif keyCode == Enum.KeyCode.S then
				Editor.save()
			end
			return
		end
		if keyCode == Enum.KeyCode.Delete or keyCode == Enum.KeyCode.Backspace then
			Editor.delete()
		elseif keyCode == Enum.KeyCode.Q or keyCode == Enum.KeyCode.E then
			local sign = keyCode == Enum.KeyCode.Q and -1 or 1
			local axis = shift and Vector3.xAxis or Vector3.yAxis
			if Placement.isActive() then
				Placement.rotate(axis, sign * State.rotStep())
			else
				Editor.rotateSelection(axis, sign * State.rotStep())
			end
		elseif keyCode == Enum.KeyCode.G then
			Editor.toggleGrid()
		elseif keyCode == Enum.KeyCode.One then
			Editor.setTool("Select")
		elseif keyCode == Enum.KeyCode.Two then
			Editor.setTool("Move")
		elseif keyCode == Enum.KeyCode.Three then
			Editor.setTool("Rotate")
		elseif keyCode == Enum.KeyCode.Four then
			Editor.setTool("Scale")
		elseif keyCode == Enum.KeyCode.L then
			Editor.toggleLock()
		elseif keyCode == Enum.KeyCode.F then
			Editor.focusSelection()
		elseif keyCode == Enum.KeyCode.H then
			UI.toggleHelp()
		end
		return
	end

	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		if processed or UI.modalOpen() or os.clock() - enteredAt < 0.4 then
			return
		end
		local mouse = Pointer.location()
		if UI.isOverGui(mouse) or Gizmos.hovering then
			return
		end
		if State.mode == "Playtest" then
			if State.towerMode then
				placeTower()
			end
			return
		end
		if Placement.isActive() then
			confirmPlacement()
			return
		end
		boxStart = mouse
		boxMoved = false
	end
end

local function onInputChanged(input)
	if boxStart and input.UserInputType == Enum.UserInputType.MouseMovement then
		local mouse = Pointer.location()
		if (mouse - boxStart).Magnitude > BOX_THRESHOLD then
			boxMoved = true
			UI.setSelectionRect(boxStart, mouse)
		end
	end
end

local function onInputEnded(input)
	if input.UserInputType == Enum.UserInputType.Touch then
		if Gizmos.isDragging() then
			Gizmos.finish()
		end
		return
	end
	if input.UserInputType ~= Enum.UserInputType.MouseButton1 then
		return
	end
	if Gizmos.isDragging() then
		Gizmos.finish()
	end
	if not boxStart then
		return
	end
	local start = boxStart
	boxStart = nil
	UI.setSelectionRect(nil)
	local shift = shiftDown()
	if boxMoved then
		local ids = Selection.boxSelect(start, Pointer.location())
		if shift then
			for _, id in State.selection do
				table.insert(ids, id)
			end
		end
		State.setSelection(ids)
		return
	end
	local id = Selection.pick(start)
	if id then
		if shift then
			State.toggleSelection(id)
		else
			State.setSelection({ id })
		end
	elseif not shift then
		State.clearSelection()
	end
end

local function onTap(position)
	if not State.active or UI.modalOpen() or os.clock() - enteredAt < 0.4 then
		return
	end
	if UI.isOverGui(position) or Gizmos.isDragging() then
		return
	end
	Pointer.setTouch(position)

	if State.mode == "Playtest" then
		if State.towerMode then
			placeTower()
		end
		return
	end

	if Placement.isActive() then
		if lastPlacementTap and (position - lastPlacementTap).Magnitude <= TAP_CONFIRM_RADIUS then
			lastPlacementTap = nil
			confirmPlacement()
		else
			lastPlacementTap = position
		end
		return
	end

	local multi = MobileControls.multiSelect()
	local id = Selection.pick(position)
	if id then
		if multi then
			State.toggleSelection(id)
		else
			State.setSelection({ id })
		end
	elseif not multi then
		State.insertAfter = nil
		RouteView.markDirty()
		State.clearSelection()
	end
end

local function frame(dt)
	if not State.active then
		return
	end
	local placing = Placement.isActive()
	local touch = Pointer.isTouch()
	Selection.render()
	Gizmos.update(placing)
	RouteView.update()
	UI.update()
	updateTowerGhost()
	MobileControls.update()
	Hotkeys.update()

	if State.mode == "Build" and not placing and not touch and not BuildCamera.isLooking() and not Gizmos.isDragging() then
		local mouse = Pointer.location()
		Selection.setHover(not UI.isOverGui(mouse) and Selection.pick(mouse) or nil)
	else
		Selection.setHover(nil)
	end

	if placing then
		excludeClock += dt
		if excludeClock > 0.5 then
			excludeClock = 0
			refreshExcluded()
		end
		local reason = Placement.reason()
		local base = if touch
			then "Tap to move  |  Tap it again or Place to confirm  |  Turn/Tilt to rotate"
			else "Click to place  |  Shift+Click to place more  |  Q/E rotate  |  Alt free place  |  X cancel"
		if Placement.isSnapped() then
			base = "Snapped to path  |  " .. base
		end
		if State.insertAfter then
			base = "Placing waypoints after the highlighted one  |  " .. base
		end
		if reason then
			UI.setHint(reason .. "   (" .. base .. ")", UI.THEME.Danger)
		else
			UI.setHint(base)
		end
	elseif State.towerMode and State.mode == "Playtest" then
		UI.setHint(if touch then "Tap the map to place a test tower" else "Click to place a test tower  |  X to stop")
	elseif State.loading then
		UI.setHint("Loading map...")
	else
		UI.setHint(nil)
	end
end

local function watchSession()
	task.spawn(function()
		local folder = nil
		local deadline = os.clock() + 10
		repeat
			folder = State.sessionFolder()
			if not folder then
				task.wait(0.1)
			end
		until folder or os.clock() > deadline or not State.active
		if not folder or not State.active then
			return
		end
		local function sync()
			local dirty = folder:GetAttribute("Dirty")
			if dirty ~= nil then
				State.dirty = dirty
			end
			local name = folder:GetAttribute("MapName")
			if name then
				State.map.name = name
			end
			UI.refreshStatus()
		end
		maid:Give(folder.AttributeChanged:Connect(sync))
		sync()
		local objects = folder:WaitForChild("Objects", 5)
		if objects then
			maid:Give(objects.ChildAdded:Connect(function()
				if Placement.isActive() then
					refreshExcluded()
				end
			end))
		end
	end)
end

function Editor.enter()
	if State.active then
		return
	end
	local response = Net.request("Enter")
	if not response.ok then
		UI.toast(response.err, "error")
		return
	end
	local data = response.data
	enteredAt = os.clock()
	State.active = true
	State.mode = "Build"
	State.loading = true
	State.origin = CFrame.new(data.originX, 0, 0)
	State.developer = data.developer == true
	State.memoryStorage = data.memoryStorage == true
	savedOnce = false
	lastPlacementTap = nil

	BuildCamera.enable(CFrame.lookAt(State.origin.Position + Vector3.new(-45, 50, 45), State.origin.Position))
	maid:Give(UserInputService.InputBegan:Connect(onInputBegan))
	maid:Give(UserInputService.InputChanged:Connect(onInputChanged))
	maid:Give(UserInputService.InputEnded:Connect(onInputEnded))
	maid:Give(RunService.RenderStepped:Connect(frame))
	maid:Give(BuildCamera.Tap:Connect(onTap))
	maid:Give(BuildCamera.RightClick:Connect(function()
		if Placement.isActive() then
			Placement.cancel()
		elseif State.towerMode then
			State.towerMode = false
			UI.setTowerMode(false)
		end
	end))
	watchSession()

	UI.setActive(true)
	MobileControls.setActive(true)
	UI.refreshStatus()
	RouteView.markDirty()
	if State.memoryStorage then
		memoryWarned = true
		UI.toast("DataStores are unavailable in this Studio session: saves last until the server stops.", "warn")
	end
	if MobileControls.isSupported() and Pointer.isTouch() then
		UI.toast("Map editor ready. Drag to look, two fingers to pan, pinch to zoom.", "info")
	else
		UI.toast("Map editor ready. Hotkeys are on the right.", "info")
	end
end

local function teardown()
	Placement.cancel()
	Gizmos.cancel()
	Gizmos.hide()
	Selection.clear()
	destroyTowerGhost()
	maid:Clean()
	BuildCamera.disable()
	MobileControls.setActive(false)
	Hotkeys.hide()
	State.active = false
	State.mode = "Build"
	State.towerMode = false
	State.selection = {}
	State.insertAfter = nil
	lastPlacementTap = nil
	History.clear()
	RouteView.markDirty()
	RouteView.update()
	UI.setActive(false)
end

function Editor.exit(force)
	if not State.active then
		return
	end
	if State.dirty and not savedOnce and not force then
		UI.confirm("This map has never been saved. Leave and lose it?", "Leave", function()
			Editor.exit(true)
		end)
		return
	end
	local response = Net.request("Exit")
	if not response.ok then
		UI.toast(response.err, "error")
		return
	end
	teardown()
end

function Editor.setTool(tool)
	if Placement.isActive() then
		Placement.cancel()
	end
	State.tool = tool
	UI.refreshToolbar()
end

function Editor.toggleGrid()
	State.gridOn = not State.gridOn
	UI.refreshToolbar()
end

function Editor.cycleGrid(direction)
	State.stepGrid(direction)
	UI.refreshToolbar()
end

function Editor.cycleRot()
	State.stepRot()
	UI.refreshToolbar()
end

function Editor.toggleSnapY()
	State.snapY = not State.snapY
	UI.refreshToolbar()
end

function Editor.toggleAlign()
	State.alignSurface = not State.alignSurface
	UI.refreshToolbar()
end

function Editor.toggleTowerMode()
	if State.mode ~= "Playtest" then
		return
	end
	State.towerMode = not State.towerMode
	UI.setTowerMode(State.towerMode)
end

function Editor.spawnWave()
	local response = Net.request("PlaytestWave")
	if not response.ok then
		UI.toast(response.err, "warn")
	end
end

function Editor.init()
	Catalog.registerAssets(Shared:WaitForChild("Templates"))
	Selection.init()
	RouteView.init()
	Gizmos.init(player:WaitForChild("PlayerGui"))

	Gizmos.Commit:Connect(function(label, records)
		Editor.change(label, records, {})
	end)

	BuildCamera.setTouchFilter(function()
		return Gizmos.isDragging() or Gizmos.hovering
	end)

	Placement.Changed:Connect(function(on)
		lastPlacementTap = nil
		if on then
			Pointer.centerTouch()
		end
	end)

	MobileControls.init({
		confirm = function()
			if Placement.isActive() then
				lastPlacementTap = nil
				confirmPlacement()
			end
		end,
		cancel = function()
			Placement.cancel()
		end,
		rotate = function(axis, sign)
			if Placement.isActive() then
				Placement.rotate(axis, sign * State.rotStep())
			else
				Editor.rotateSelection(axis, sign * State.rotStep())
			end
		end,
		delete = function()
			Editor.delete()
		end,
		duplicate = function()
			Editor.duplicate()
		end,
		copy = function()
			Editor.copy()
		end,
		paste = function()
			Editor.paste()
		end,
		deselect = function()
			State.insertAfter = nil
			RouteView.markDirty()
			State.clearSelection()
		end,
		exitTowerMode = function()
			State.towerMode = false
			UI.setTowerMode(false)
		end,
	})

	UI.init({
		enter = Editor.enter,
		exit = function()
			Editor.exit(false)
		end,
		setTool = Editor.setTool,
		undo = Editor.undo,
		redo = Editor.redo,
		toggleGrid = Editor.toggleGrid,
		cycleGrid = Editor.cycleGrid,
		cycleRot = Editor.cycleRot,
		toggleSnapY = Editor.toggleSnapY,
		toggleAlign = Editor.toggleAlign,
		validate = Editor.validate,
		openMaps = Editor.openMaps,
		save = Editor.save,
		startTest = Editor.startTest,
		stopTest = Editor.stopTest,
		spawnWave = Editor.spawnWave,
		toggleTowerMode = Editor.toggleTowerMode,
		selectCatalog = function(typeId)
			Editor.selectCatalog(typeId, false)
		end,
		selectPrefab = Editor.selectPrefab,
		loadPrefabs = Editor.loadPrefabs,
		deletePrefab = Editor.deletePrefab,
		duplicate = Editor.duplicate,
		delete = Editor.delete,
		copy = Editor.copy,
		paste = Editor.paste,
		toggleLock = Editor.toggleLock,
		savePrefab = Editor.savePrefab,
		focusSelection = Editor.focusSelection,
		setProperty = Editor.setProperty,
		routeAction = Editor.routeAction,
		loadMap = Editor.loadMap,
		newMap = Editor.newMap,
		renameMap = Editor.renameMap,
		duplicateMap = Editor.duplicateMap,
		deleteMap = Editor.deleteMap,
		openImport = Editor.openImport,
		importPeri = Editor.importPeri,
		exportPeri = Editor.exportPeri,
		focusIssue = Editor.focusIssue,
	})

	Hotkeys.init()

	State.Changed:Connect(function(what)
		if what == "map" then
			RouteView.markDirty()
			UI.refreshStatus()
			UI.refreshInspector(false)
			if Placement.isActive() then
				refreshExcluded()
			end
		elseif what == "selection" then
			UI.refreshInspector(true)
		elseif what == "recent" then
			UI.refreshRecent()
		elseif what == "favourites" then
			UI.refreshCatalog()
		end
	end)

	player.CharacterAdded:Connect(function(character)
		if not State.active then
			return
		end
		local cf = workspace.CurrentCamera.CFrame
		character:WaitForChild("HumanoidRootPart", 5)
		BuildCamera.disable()
		BuildCamera.enable(cf)
	end)
end

return Editor