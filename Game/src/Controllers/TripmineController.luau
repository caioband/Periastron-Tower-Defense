local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Assets = Shared:WaitForChild("Assets")

local GameClock = require(Shared:WaitForChild("Util"):WaitForChild("GameClock"))

local Me = require(Vendor.Me)
local Framework = Me.new()

-- Only used when the server does not send the duration (an old version of the event).
local THROW_DURATION = 0.35
local THROW_HEIGHT = 4

--[[
	How long the exploded model stays on the map before disappearing.

	Real time on purpose, the only real time in the file: what remains on screen is
	`ParticleEmitter`s, and particles do not run on the match clock; speeding up
	their cleanup would cut the smoke in half at 3x.
]]
local EXPLOSION_LIFETIME = 5

local TripmineController = {
	Controllers = {
		UnitPlacementController = {},
		MusicController = {},

		-- The "VFX" setting: off, the explosion keeps its sound and loses its particles.
		SettingsController = {},
	},
	Mines = {},
	MinesByUnit = {},

	--[[
		The throws in progress: `[mineId] = { conn, endCF }`. An entry only exists while
		the mine is in the air.
	]]
	Arcs = {},
}

--[=[
	Ends a mine's throw, if it is still running, and puts the model at its resting
	place.

	It exists because of the race between the flight and the explosion. The server
	arms the mine when it lands and the client spends the same `throwTime` drawing
	the arc, so normally the flight is over when `TripmineTriggered` arrives. But the
	two clocks do not switch at the same time: changing the match speed with a mine in
	the air only reaches this client one network trip later, and during that gap its
	arc runs slower than the server's timer.

	Without this, that mine's explosion would happen **in mid-air**, wherever the arc
	was, and particles stay where they were emitted. Fixing the position before
	emitting costs one line and takes the network out of the equation.
]=]
function TripmineController:endArc(mineId, snap : boolean?)
	local arc = self.Arcs[mineId]
	if not arc then return end

	self.Arcs[mineId] = nil

	if arc.conn.Connected then
		arc.conn:Disconnect()
	end

	if snap then
		local mine = self.Mines[mineId]
		if mine and mine.Parent then
			mine:PivotTo(arc.endCF)
		end
	end
end

function TripmineController:getTemplate()
	if not self.template then
		local vfxFolder = Assets:FindFirstChild("VFX")
		self.template = vfxFolder and vfxFolder:FindFirstChild("SubspaceTripmine")
	end
	return self.template
end

function TripmineController:getUnitModel(unitId)
	local placement = self.Controllers.UnitPlacementController
	local class = placement and placement.classesById and placement.classesById[unitId]
	return class and class.model or nil
end

function TripmineController:playTriggerSound(parent)
	-- The Key plays the role of the old ActiveSound: only one mine sounding at a time.
	self.Controllers.MusicController:PlaySFX("SubspaceTripmineSFX", {
		Parent = parent,
		Key = "SubspaceTripmine",
	})
end

--[=[
	The mine's arc, from the throw to the ground.

	The clock is the **match** clock, not `os.clock()`: the server arms the mine
	`throwTime` of match time after releasing it, and this flight must end at the same
	instant. With the screen clock, at 3x the windup and throw animation would shrink
	to a third while the mine still took the same 0.35 real seconds in the air: it
	would float while the rest of the match raced, and the trigger would arm with the
	model still on its way.

	Reading the clock every frame (instead of converting to real seconds at call time)
	is what makes a speed change **mid-flight** count: speeding up the match with a
	mine in the air shortens what is left of it, the same way `GameClock.Wait` does on
	the server side.
]=]
function TripmineController:throwMine(mineId, mineModel, startCF, endCF, throwTime)
	mineModel:PivotTo(startCF)

	local duration = math.max(throwTime or THROW_DURATION, 1e-3)
	local startedAt = GameClock.Now()
	local spin = math.random() * math.pi * 2

	local conn
	conn = RunService.RenderStepped:Connect(function()
		if not mineModel.Parent then
			self:endArc(mineId)
			return
		end
		local alpha = math.min(1, (GameClock.Now() - startedAt) / duration)
		local height = math.sin(alpha * math.pi) * THROW_HEIGHT
		local cf = startCF:Lerp(endCF, alpha) + Vector3.new(0, height, 0)
		mineModel:PivotTo(cf * CFrame.Angles(spin * alpha, 0, 0))
		if alpha >= 1 then
			self:endArc(mineId)
			mineModel:PivotTo(endCF)
		end
	end)

	self.Arcs[mineId] = { conn = conn, endCF = endCF }
end

function TripmineController:spawnMine(unitId, mineId, mineCF, throwTime)
	local template = self:getTemplate()
	if not template then return end

	local mine = template:Clone()
	mine.Name = "SubspaceTripmine_" .. mineId
	mine.Parent = workspace.CurrentCamera

	self.Mines[mineId] = mine
	self.MinesByUnit[unitId] = self.MinesByUnit[unitId] or {}
	self.MinesByUnit[unitId][mineId] = true

	local unitModel = self:getUnitModel(unitId)
	local startCF = mineCF
	if unitModel and unitModel.Parent then
		startCF = CFrame.new(unitModel:GetPivot().Position + Vector3.new(0, 2, 0))
	end

	self:throwMine(mineId, mine, startCF, mineCF, throwTime)
end

function TripmineController:triggerMine(unitId, mineId)
	-- The mine explodes on the ground, not wherever the arc is: if it was still
	-- running, it ends here and the model goes to its resting place before emitting.
	self:endArc(mineId, true)

	local mine = self.Mines[mineId]
	self.Mines[mineId] = nil
	if self.MinesByUnit[unitId] then
		self.MinesByUnit[unitId][mineId] = nil
	end
	if not mine or not mine.Parent then return end

	local root = mine.PrimaryPart or mine:FindFirstChildWhichIsA("BasePart")
	if root then
		local settings = self.Controllers.SettingsController
		local effects = settings == nil or settings:Get("VFX")

		for _, descendant in mine:GetDescendants() do
			if descendant:IsA("ParticleEmitter") and effects then
				descendant:Emit(descendant:GetAttribute("EmitCount") or 15)
			elseif descendant:IsA("BasePart") then
				descendant.Transparency = 1
			end
		end
		if root:IsA("BasePart") then
			root.Transparency = 1
		end
		self:playTriggerSound(root)
	end

	task.delay(EXPLOSION_LIFETIME, function()
		if mine and mine.Parent then
			mine:Destroy()
		end
	end)
end

function TripmineController:clearUnitMines(unitId)
	local mines = self.MinesByUnit[unitId]
	if not mines then return end
	for mineId in mines do
		-- No `snap`: the model is going away, there is no resting place for it.
		self:endArc(mineId)

		local mine = self.Mines[mineId]
		self.Mines[mineId] = nil
		if mine and mine.Parent then
			mine:Destroy()
		end
	end
	self.MinesByUnit[unitId] = nil
end

--[=[
	Removes every mine from the map: the end of the round.

	Mines live in `CurrentCamera`, which survives the round, and neither path that
	destroys them goes through the match end: a mine nobody stepped on never receives
	`TripmineTriggered`, and each tower's `RemoveUnit` only arrives at `ResetRound`,
	which is the **next** round starting. In between (the results screen) the finished
	round's mines would stay armed in the Camera.

	It does not replace `clearUnitMines`: that one is a tower leaving, this one is the
	whole round.
]=]
function TripmineController:clearAllMines()
	for mineId, mine in self.Mines do
		self:endArc(mineId)

		if mine and mine.Parent then
			mine:Destroy()
		end
	end

	table.clear(self.Mines)
	table.clear(self.MinesByUnit)

	--[[
		An arc whose mine already left the table by another path: the loop above did
		not go through it, and its flight would stay connected to `RenderStepped`.
	]]
	for mineId in self.Arcs do
		self:endArc(mineId)
	end
end

function TripmineController:construct()
	Framework:Listen("TripmineThrown", function(unitId, mineId, mineCF, throwTime)
		self:spawnMine(unitId, mineId, mineCF, throwTime)
	end)

	Framework:Listen("TripmineTriggered", function(unitId, mineId)
		self:triggerMine(unitId, mineId)
	end)

	Framework:Listen("RemoveUnit", function(unitId)
		self:clearUnitMines(unitId)
	end)

	--[[
		The round's end from both sides: `GameOver` is the base falling
		(`MobService:onGameOver`) and `Win` is the last wave cleared. Neither leaves a
		mine on the map.
	]]
	Framework:Listen("GameOver", function()
		self:clearAllMines()
	end)

	Framework:Listen("Win", function()
		self:clearAllMines()
	end)
end

function TripmineController:start()
end

function TripmineController:init()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end
	self:construct()
end

return TripmineController
