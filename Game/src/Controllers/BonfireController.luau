local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Assets = Shared:WaitForChild("Assets")
local Utils = Shared:WaitForChild("Util")
local VFX = Assets:WaitForChild("VFX")

local SharedConfig = require(Shared:WaitForChild("Config"):WaitForChild("SharedConfig"))
local GameClock = require(Utils:WaitForChild("GameClock"))
local Log = require(Utils:WaitForChild("Log"))
local Me = require(Vendor.Me)

local Framework = Me.new()
local log = Log.new("BonfireController")

local UNIT_NAME = "Bonfire"

-- Everything below comes from `UnitAttackConfig["Bonfire"]`: stages, Tired, attachment.
local attackConfig = SharedConfig.UnitAttackConfig[UNIT_NAME]
local stages = attackConfig.BeamStages
local tired = attackConfig.Tired

-- How long a unit may be missing on this client before its state is forgotten. Zippers
-- removes and re-adds the same unitId in one step, and a unit's state event can also
-- land before its `ReplicateUnit`, so state is kept by unitId instead of by model.
local MISSING_GRACE = 3

local BonfireController = {
	Controllers = {
		UnitPlacementController = {},
		MobController = {},
	},

	-- unitId -> { state, stage, mobId, missingSince }: what the server last said.
	desired = {},

	-- unitId -> { class, model, state, stage, beam, ... }: what is on screen now.
	visuals = {},

	checkedTired = false,
}

local function stageDef(stage : number)
	return stages[stage] or stages[#stages]
end

local function playTrack(class, name : string, looped : boolean)
	local tracks = class.loadedAnimations
	local track = tracks and tracks[name]
	if not track then
		log:StudioWarn("Bonfire has no animation named", name)
		return nil
	end

	track.Looped = looped
	track.Priority = Enum.AnimationPriority.Action

	if not track.IsPlaying then
		track:Play(0.1)
	end

	-- A freshly played track returns to 1x, so the match speed goes back on (see
	-- `Unit:playAttackVisual`).
	local fit = class.animationSpeeds and class.animationSpeeds[name] or 1
	track:AdjustSpeed(GameClock.GetScale() * fit)

	return track
end

local function stopTrack(class, name : string, fade : number)
	local tracks = class.loadedAnimations
	local track = tracks and tracks[name]

	if track and track.IsPlaying then
		track:Stop(fade)
	end
end

local function findBeamAttachment(model : Model) : Attachment?
	local holder = model:FindFirstChild(attackConfig.BeamAttachment.Part)
	if not holder then return nil end

	for _, name in attackConfig.BeamAttachment.Names do
		local found = holder:FindFirstChild(name)
		if found and found:IsA("Attachment") then
			return found
		end
	end

	return nil
end

--[[
	Tells the developer, once, if the `Tired` animation is not the length the server
	waits for. The server cannot read it, so `Tired.Duration` is a copy.
]]
local function verifyTiredLength(track : AnimationTrack)
	task.spawn(function()
		local waited = 0
		while track.Length <= 0 and waited < 5 do
			waited += task.wait(0.25)
		end

		if track.Length > 0 and math.abs(track.Length - tired.Duration) > 0.05 then
			log:StudioWarn(string.format(
				"Tired animation is %.2fs but UnitAttackConfig Bonfire Tired.Duration is %.2fs. Set Duration = %.2f",
				track.Length, tired.Duration, track.Length
			))
		end
	end)
end

function BonfireController:getMob(mobId : any) : Model?
	if not mobId then return nil end

	local mobController = self.Controllers.MobController
	local spawned = mobController and mobController.SpawnedMobs
	local mob = spawned and spawned[mobId]

	if mob and mob.Parent then
		return mob
	end

	return nil
end

function BonfireController:buildBeam(visual, beamName : string)
	local template = VFX:FindFirstChild(beamName)
	if not template then
		log:StudioWarn("Bonfire beam model not found in Assets.VFX:", beamName)
		return
	end

	local beam = template:Clone()

	-- The templates ship unanchored and collidable.
	for _, descendant in beam:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
			descendant.Massless = true
		end
	end

	local start = beam:FindFirstChild("Start")
	local finish = beam:FindFirstChild("End")
	if not (start and finish) then
		log:StudioWarn(beamName, "needs a Start and an End part")
		beam:Destroy()
		return
	end

	-- Not parented yet: `updateBeam` parents it once both ends have a position, so it
	-- never flashes where the template sits.
	visual.beam = beam
	visual.beamName = beamName
	visual.start = start
	visual.finish = finish
end

function BonfireController:destroyBeam(visual)
	if visual.beam then
		visual.beam:Destroy()
	end

	visual.beam = nil
	visual.beamName = nil
	visual.start = nil
	visual.finish = nil
end

function BonfireController:enterStage(visual, stage : number)
	local class = visual.class
	local def = stageDef(stage)

	stopTrack(class, tired.Animation, 0.1)

	for _, other in stages do
		if other.Animation ~= def.Animation then
			stopTrack(class, other.Animation, 0.15)
		end
	end

	playTrack(class, def.Animation, true)

	if visual.beamName ~= def.Beam then
		self:destroyBeam(visual)
		self:buildBeam(visual, def.Beam)
	end

	visual.stage = stage
end

function BonfireController:leaveFire(visual)
	local class = visual.class

	for _, def in stages do
		stopTrack(class, def.Animation, 0.15)
	end

	self:destroyBeam(visual)
	visual.stage = 0
	visual.lastEnd = nil

	class:setTarget(nil)
end

function BonfireController:applyState(visual, want)
	local class = visual.class

	if want.state == "Fire" then
		if visual.state ~= "Fire" or visual.stage ~= want.stage then
			self:enterStage(visual, want.stage)
		end

		visual.state = "Fire"
		return
	end

	if visual.state == "Fire" then
		self:leaveFire(visual)
	end

	-- Charge-up reuses the first stage's animation (Attack). If Charge turns into Fire,
	-- `enterStage` finds it already playing and keeps it going.
	if want.state == "Charge" then
		if visual.state ~= "Charge" then
			stopTrack(class, tired.Animation, 0.1)
			playTrack(class, stages[1].Animation, true)
		end
	elseif visual.state == "Charge" then
		-- Charge ended without firing (the target left): back to Idle.
		stopTrack(class, stages[1].Animation, 0.15)
	end

	if want.state == "Tired" then
		if visual.state ~= "Tired" then
			local track = playTrack(class, tired.Animation, false)

			if track and not self.checkedTired then
				self.checkedTired = true
				verifyTiredLength(track)
			end
		end
	elseif visual.state == "Tired" then
		-- Tired finishing on its own drops back to the Idle that never stopped playing.
		stopTrack(class, tired.Animation, 0.2)
	end

	visual.state = want.state
end

local function getAimPosition(mob : Model) : Vector3
	for _, partName in attackConfig.BeamTargetParts do
		local part = mob:FindFirstChild(partName)
		if part and part:IsA("BasePart") then
			return part.Position + attackConfig.BeamEndOffset
		end
	end

	return mob:GetPivot().Position + attackConfig.BeamEndOffset
end


function BonfireController:updateBeam(visual, want)
	local class = visual.class
	local mob = self:getMob(want.mobId)

	-- Turns the tower to its target, every frame: with no TargetingController behind
	-- it (see the `skipTargeting` edit) nothing else keeps it facing a walking enemy.
	class:setTarget(mob)

	if not visual.beam then return end

	local attachment = visual.attachment
	if not attachment or not attachment.Parent then
		attachment = findBeamAttachment(visual.model)
		visual.attachment = attachment

		if not attachment then
			log:StudioWarn("Bonfire has no beam attachment inside", attackConfig.BeamAttachment.Part)
			return
		end
	end

	if mob then
		visual.lastEnd = getAimPosition(mob)
	end

	local endPosition = visual.lastEnd
	if not endPosition then return end

	local startPosition = attachment.WorldPosition

	if (endPosition - startPosition).Magnitude > 0.01 then
		visual.start.CFrame = CFrame.lookAt(startPosition, endPosition)
		visual.finish.CFrame = CFrame.lookAt(endPosition, startPosition)
	else
		visual.start.CFrame = CFrame.new(startPosition)
		visual.finish.CFrame = CFrame.new(endPosition)
	end

	if visual.beam.Parent == nil then
		visual.beam.Parent = workspace.CurrentCamera
	end
end

function BonfireController:createVisual(unitId : any, class)
	local visual = {
		class = class,
		model = class.model,
		attachment = findBeamAttachment(class.model),
		state = "Idle",
		stage = 0,
	}

	self.visuals[unitId] = visual

	return visual
end

function BonfireController:destroyVisual(unitId : any)
	local visual = self.visuals[unitId]
	if not visual then return end

	self:destroyBeam(visual)

	for _, def in stages do
		stopTrack(visual.class, def.Animation, 0)
	end
	stopTrack(visual.class, tired.Animation, 0)

	self.visuals[unitId] = nil
end

function BonfireController:update()
	local placement = self.Controllers.UnitPlacementController
	local classes = placement and placement.classesById
	if not classes then return end

	local now = os.clock()

	for unitId, want in self.desired do
		local class = classes[unitId]
		local model = class and class.model
		local alive = model ~= nil and model.Parent ~= nil
		local visual = self.visuals[unitId]

		if not alive then
			if visual then
				self:destroyVisual(unitId)
			end

			want.missingSince = want.missingSince or now
			if now - want.missingSince > MISSING_GRACE then
				self.desired[unitId] = nil
			end

			continue
		end

		want.missingSince = nil

		-- Same unitId, new model (Zippers): start over on the new one.
		if visual and visual.class ~= class then
			self:destroyVisual(unitId)
			visual = nil
		end

		visual = visual or self:createVisual(unitId, class)

		self:applyState(visual, want)

		if visual.state == "Fire" then
			self:updateBeam(visual, want)
		end
	end
end

function BonfireController:construct()
	Framework:Listen("BonfireState", function(unitId, state, stage, mobId)
		local want = self.desired[unitId]
		if not want then
			want = {}
			self.desired[unitId] = want
		end

		want.state = state
		want.stage = stage
		-- The server sends `false` for "no target": Warp does not carry nil.
		want.mobId = mobId or nil
	end)

	RunService.RenderStepped:Connect(function()
		self:update()
	end)
end

function BonfireController:start()
end

function BonfireController:init()
	for name, _ in self.Controllers do
		self.Controllers[name] = Framework:Get(name, false, true)
	end

	self:construct()
end

return BonfireController