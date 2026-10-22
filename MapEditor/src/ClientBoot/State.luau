local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("MapEditor")
local Config = require(Shared.Config)
local Catalog = require(Shared.Catalog)

local Signal = require(script.Parent.Signal)

local player = Players.LocalPlayer

local State = {}

State.GRID_PRESETS = { 0.01, 0.05, 0.1, 0.25, 0.5, 1, 2, 4, 8, 16, 32, 50 }
State.ROT_PRESETS = { 1, 5, 15, 30, 45, 90 }
State.GRID_LIMITS = { min = 0.01, max = 512 }
State.ROT_LIMITS = { min = 0.01, max = 360 }
State.RESIZE_LIMITS = { min = 0.01, max = 512 }
State.SCALE_LIMITS = { min = 0.01, max = 10 }

State.active = false
State.mode = "Build"
State.origin = CFrame.identity
State.map = { id = "", name = "", objects = {}, route = { steps = {} } }
State.dirty = false
State.loading = false
State.selection = {}
State.tool = "Select"
State.gridIndex = Config.DEFAULT_GRID_INDEX
State.gridStep = Config.GRID_SIZES[Config.DEFAULT_GRID_INDEX] or 1
State.gridOn = true
State.snapY = false
State.alignSurface = false
State.rotIndex = Config.DEFAULT_ROTATION_INDEX
State.rotDegrees = Config.ROTATION_STEPS[Config.DEFAULT_ROTATION_INDEX] or 15
State.resizeStuds = State.gridStep
State.scaleFactor = 0.1
State.clipboard = nil
State.recent = {}
State.favourites = {}
State.prefabs = {}
State.developer = false
State.memoryStorage = false
State.insertAfter = nil
State.validation = nil

State.Changed = Signal.new()

function State.emit(what, ...)
	State.Changed:Fire(what, ...)
end

local function cleanStep(value, limits)
	if typeof(value) ~= "number" or value ~= value or math.abs(value) == math.huge then
		return nil
	end
	return math.clamp(math.round(value * 1000) / 1000, limits.min, limits.max)
end

function State.gridSize()
	return State.gridStep
end

function State.rotStep()
	return State.rotDegrees
end

function State.resizeStep()
	return State.resizeStuds
end

function State.scaleStep()
	return State.scaleFactor
end

function State.setGridStep(value)
	local step = cleanStep(value, State.GRID_LIMITS)
	if not step then
		return false
	end
	State.gridStep = step
	State.gridOn = true
	State.emit("settings")
	return true
end

function State.setRotStep(value)
	local step = cleanStep(value, State.ROT_LIMITS)
	if not step then
		return false
	end
	State.rotDegrees = step
	State.emit("settings")
	return true
end

function State.setResizeStep(value)
	local step = cleanStep(value, State.RESIZE_LIMITS)
	if not step then
		return false
	end
	State.resizeStuds = step
	State.emit("settings")
	return true
end

function State.setScaleStep(value)
	local step = cleanStep(value, State.SCALE_LIMITS)
	if not step then
		return false
	end
	State.scaleFactor = step
	State.emit("settings")
	return true
end

function State.stepGrid(direction)
	local current = State.gridStep
	local presets = State.GRID_PRESETS
	local pick = nil
	if direction > 0 then
		for _, preset in presets do
			if preset > current + 1e-6 then
				pick = preset
				break
			end
		end
		pick = pick or presets[#presets]
	else
		for i = #presets, 1, -1 do
			if presets[i] < current - 1e-6 then
				pick = presets[i]
				break
			end
		end
		pick = pick or presets[1]
	end
	State.gridStep = pick
	State.gridOn = true
	State.emit("settings")
end

function State.stepRot()
	local current = State.rotDegrees
	local presets = State.ROT_PRESETS
	local pick = presets[1]
	for _, preset in presets do
		if preset > current + 1e-6 then
			pick = preset
			break
		end
	end
	State.rotDegrees = pick
	State.emit("settings")
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