local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("MapEditor")
local Config = require(Shared.Config)
local Catalog = require(Shared.Catalog)

local Signal = require(script.Parent.Signal)

local player = Players.LocalPlayer

local State = {}

State.active = false
State.mode = "Build"
State.origin = CFrame.identity
State.map = { id = "", name = "", objects = {}, route = { steps = {} } }
State.dirty = false
State.loading = false
State.selection = {}
State.tool = "Select"
State.gridIndex = Config.DEFAULT_GRID_INDEX
State.gridOn = true
State.snapY = false
State.alignSurface = false
State.rotIndex = Config.DEFAULT_ROTATION_INDEX
State.clipboard = nil
State.recent = {}
State.favourites = {}
State.prefabs = {}
State.developer = false
State.memoryStorage = false
State.insertAfter = nil
State.towerMode = false
State.validation = nil

State.Changed = Signal.new()

function State.emit(what, ...)
	State.Changed:Fire(what, ...)
end

function State.gridSize()
	return Config.GRID_SIZES[State.gridIndex]
end

function State.rotStep()
	return Config.ROTATION_STEPS[State.rotIndex]
end

function State.sessionFolder()
	local root = workspace:FindFirstChild("MapEditor")
	local sessions = root and root:FindFirstChild("Sessions")
	return sessions and sessions:FindFirstChild(tostring(player.UserId))
end

function State.objectsFolder()
	local folder = State.sessionFolder()
	return folder and folder:FindFirstChild("Objects")
end

function State.instanceFor(id)
	local objects = State.objectsFolder()
	return objects and objects:FindFirstChild(id)
end

function State.record(id)
	return State.map.objects[id]
end

function State.def(id)
	local rec = State.map.objects[id]
	return rec and Catalog.get(rec.t)
end

function State.isSelected(id)
	return table.find(State.selection, id) ~= nil
end

function State.setSelection(ids)
	local out, seen = {}, {}
	for _, id in ids do
		if not seen[id] and State.map.objects[id] then
			seen[id] = true
			table.insert(out, id)
		end
	end
	State.selection = out
	State.emit("selection")
end

function State.toggleSelection(id)
	local ids = table.clone(State.selection)
	local index = table.find(ids, id)
	if index then
		table.remove(ids, index)
	else
		table.insert(ids, id)
	end
	State.setSelection(ids)
end

function State.clearSelection()
	if #State.selection > 0 then
		State.setSelection({})
	end
end

function State.primary()
	return State.selection[#State.selection]
end

function State.applyRecords(records, route)
	for id, rec in records do
		if rec == false then
			State.map.objects[id] = nil
		else
			State.map.objects[id] = rec
		end
	end
	if route then
		State.map.route = route
	end
	local kept = {}
	for _, id in State.selection do
		if State.map.objects[id] then
			table.insert(kept, id)
		end
	end
	if #kept ~= #State.selection then
		State.selection = kept
		State.emit("selection")
	end
	if State.insertAfter and not State.map.objects[State.insertAfter] then
		State.insertAfter = nil
	end
	State.emit("map")
end

function State.toLocalCF(cf)
	return State.origin:ToObjectSpace(cf)
end

function State.toWorldCF(cf)
	return State.origin * cf
end

function State.toLocalPoint(v)
	return State.origin:PointToObjectSpace(v)
end

function State.toWorldPoint(v)
	return State.origin:PointToWorldSpace(v)
end

function State.countType(typeId)
	local n = 0
	for _, rec in State.map.objects do
		if rec.t == typeId then
			n += 1
		end
	end
	return n
end

function State.objectCount()
	local n = 0
	for _ in State.map.objects do
		n += 1
	end
	return n
end

function State.markRecent(typeId)
	local index = table.find(State.recent, typeId)
	if index then
		table.remove(State.recent, index)
	end
	table.insert(State.recent, 1, typeId)
	while #State.recent > 8 do
		table.remove(State.recent)
	end
	State.emit("recent")
end

function State.toggleFavourite(typeId)
	State.favourites[typeId] = not State.favourites[typeId] or nil
	State.emit("favourites")
end

return State
