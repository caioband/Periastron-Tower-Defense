local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("MapEditor")
local Config = require(Shared.Config)
local Catalog = require(Shared.Catalog)
local RouteModel = require(Shared.RouteModel)
local Serializer = require(Shared.Serializer)

local State = require(script.Parent.State)

local RouteView = {}

local folder = nil
local dirty = true

local LINE = Color3.fromHex("34C6E6")
local FORK = Color3.fromHex("8C5B9F")
local LIFT = Vector3.new(0, 0.35, 0)
local LETTERS = { "a", "b", "c", "d" }
local LANE_COLORS = { A = Color3.fromHex("FF6B5E"), B = Color3.fromHex("F5A524") }

function RouteView.init()
	folder = Instance.new("Folder")
	folder.Name = "EditorRoute"
	folder.Parent = workspace.CurrentCamera
end

function RouteView.markDirty()
	dirty = true
end

function RouteView.folder()
	return folder
end

local function segment(a, b, color)
	local from, to = State.toWorldPoint(a) + LIFT, State.toWorldPoint(b) + LIFT
	local length = (to - from).Magnitude
	if length < 0.05 then
		return
	end
	local dir = (to - from).Unit
	local line = Instance.new("Part")
	line.Name = "Segment"
	line.Anchored = true
	line.CanCollide = false
	line.CanQuery = false
	line.CanTouch = false
	line.CastShadow = false
	line.Material = Enum.Material.Neon
	line.Color = color
	line.Size = Vector3.new(0.25, 0.25, length)
	line.CFrame = CFrame.lookAt(from, to) * CFrame.new(0, 0, -length / 2)
	line.Parent = folder

	if length > 3 then
		local tip = from + dir * (length * 0.55)
		for _, side in { -1, 1 } do
			local wing = Instance.new("Part")
			wing.Anchored = true
			wing.CanCollide = false
			wing.CanQuery = false
			wing.CanTouch = false
			wing.CastShadow = false
			wing.Material = Enum.Material.Neon
			wing.Color = color
			wing.Size = Vector3.new(0.2, 0.2, 1.1)
			local back = CFrame.lookAt(tip, tip - dir) * CFrame.Angles(0, math.rad(35 * side), 0)
			wing.CFrame = back * CFrame.new(0, 0, -0.55)
			wing.Parent = folder
		end
	end
end

local function tag(position, text, highlighted)
	local anchor = Instance.new("Part")
	anchor.Name = "Tag"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(0.1, 0.1, 0.1)
	anchor.CFrame = CFrame.new(State.toWorldPoint(position) + Vector3.new(0, 3.6, 0))

	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromOffset(46, 22)
	gui.AlwaysOnTop = true
	gui.MaxDistance = 220
	gui.LightInfluence = 0
	gui.Parent = anchor

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundColor3 = highlighted and Color3.fromHex("F5CD30") or Color3.fromHex("161A1F")
	label.BackgroundTransparency = 0.15
	label.TextColor3 = highlighted and Color3.fromHex("161A1F") or Color3.new(1, 1, 1)
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.Text = text
	label.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = label

	anchor.Parent = folder
end

function RouteView.update()
	if not folder or not dirty then
		return
	end
	dirty = false
	folder:ClearAllChildren()
	if not State.active or State.mode ~= "Build" then
		return
	end

	local map = State.map
	local spawns = RouteModel.spawns(map)
	local base = RouteModel.findRole(map, Catalog.ROLE.Base)
	local function point(rec)
		return RouteModel.nodePosition(rec)
	end

	local ends = {}
	for _, spawn in spawns do
		local previous = point(spawn)
		local letter = RouteModel.spawnLane(spawn)
		local color = LANE_COLORS[letter] or LINE
		if State.insertAfter == spawn.id then
			tag(Serializer.toVector(spawn.p) + Vector3.new(0, 1.5, 0), "Lane " .. letter, true)
		end
		local _, lane = RouteModel.laneFor(map.route, letter)
		if lane then
			for i, id in lane.ids do
				local rec = map.objects[id]
				if rec then
					local p = point(rec)
					segment(previous, p, color)
					previous = p
					tag(Serializer.toVector(rec.p), letter .. i, State.insertAfter == id)
				end
			end
		end
		table.insert(ends, previous)
	end

	local counter = 0
	for s, step in map.route.steps do
		local forked = #step.alts > 1
		local newEnds = {}
		local startCounter = counter
		local longest = 0
		for a, alt in step.alts do
			local previous = nil
			for i, id in alt do
				local rec = map.objects[id]
				if not rec then
					continue
				end
				local p = point(rec)
				local color = forked and FORK or LINE
				if previous then
					segment(previous, p, color)
				else
					for _, e in ends do
						segment(e, p, color)
					end
				end
				previous = p
				local text = if forked then string.format("C%d%s%d", startCounter + 1, LETTERS[a] or "?", i) else "C" .. tostring(startCounter + i)
				tag(Serializer.toVector(rec.p), text, State.insertAfter == id)
			end
			if previous then
				table.insert(newEnds, previous)
			end
			longest = math.max(longest, #alt)
		end
		counter = if forked then startCounter + 1 else startCounter + longest
		if #newEnds > 0 then
			ends = newEnds
		end
	end

	if base then
		for _, e in ends do
			segment(e, point(base), LINE)
		end
	end

	local _ = Config
end

return RouteView
