local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")
local Utils = Shared:WaitForChild("Util")

local SharedConfig = require(Configs.SharedConfig)
local LightingUtil = require(Utils.LightingUtil)

local Me = require(Vendor.Me)
local Log = require(Shared:WaitForChild("Util"):WaitForChild("Log"))

local Framework = Me.new()
local log = Log.new("LightingController")

local Config = SharedConfig.LightingConfig
local SettingsConfig = SharedConfig.SettingsConfig

--[[
	Lighting transitions, client only.

	`LightingService` swaps Lighting's contents all at once: that is right for the
	server, and it is what a player joining mid-match needs to receive. Here the swap
	becomes a transition: on the notification that the preset changed, the controller
	puts properties back to the previous preset's values and interpolates to the new
	one.

	Where each end comes from:

	- **source**: `self.applied`, the state this controller itself wrote last. It is
	  not read from Lighting at that moment: when the notification arrives, the new
	  value may already have replicated over it.
	- **target**: the preset Folder in `Assets.Lighting`, not the live instance. Same
	  reason: the folder is stable, and the live instance is what gets overwritten.

	What does not interpolate (booleans, strings, EnumItems, sequences) is applied
	at once: turning on happens at the start, turning off waits for the end, so an
	effect appears along with the transition and disappears after it.

	An instance is only interpolated if it exists in both presets with the same name
	and class. One that only exists in the new preset already arrives at its final
	value through replication; one that only existed in the old one was destroyed by
	the server. In practice: using the same names across presets is what makes the
	transition complete.

	The player's "Shadows" and "Post Effects" settings live here too, because this is
	who writes Lighting on the client: a setting that wrote on its own would be undone
	by the next transition. See `_write`.

	It lives in `common/` because both places use it.

	See docs/common/lighting.md.
]]

-- How long to wait for the new preset's instances to replicate before giving up
-- on interpolating them.
local CHILD_WAIT = 0.5

-- The classes the "Post Effects" setting turns off. See `_forced`.
local POST_EFFECTS = {}
for _, className in SettingsConfig.POST_EFFECT_CLASSES do
	POST_EFFECTS[className] = true
end

local LightingController = {
	Controllers = {},
}

LightingController.currentPreset = nil :: string?

--[[
	The last state this controller wrote:
	`{ Lighting = { prop -> value }, Children = { name -> { ClassName, Values } } }`
]]
LightingController.applied = nil :: any

LightingController._generation = 0
LightingController._connection = nil :: RBXScriptConnection?
LightingController._root = nil :: Folder?

-- The plan of the transition in progress, or nil. See `_freeze` and `Skip`.
LightingController._plan = nil :: any

--[[
	The player's settings (`SettingsController`): `false` forces shadows or the post
	effects off on this client. See `_forced`.
]]
LightingController._shadows = true
LightingController._postEffects = true

--[[
	What each forced property **should** be, per instance: the value the server or the
	preset wanted, kept while a setting writes something else on top.

	Strong keys, cleaned on `Destroying` (see `_watchSettings`): a weak-keyed table of
	Instances loses entries while the Instance is still alive, because its userdata is
	collected when no Lua code holds it, and a lost truth is an effect that never
	comes back on.
]]
LightingController._truth = {} :: { [Instance]: { [string]: any } }

--[[ SETTINGS ]]

--[=[
	The value a setting forces on this property, or nil when it is free.

	Shadows off forces `Lighting.GlobalShadows`; post effects off forces `Enabled` on
	the `SettingsConfig.POST_EFFECT_CLASSES`. What carries `KeepAttribute` is left
	alone: it belongs to another system (the panels' `UIBlur`).
]=]
function LightingController:_forced(instance: Instance, property: string): any
	if instance == Lighting then
		if property == "GlobalShadows" and not self._shadows then
			return false
		end

		return nil
	end

	if property == "Enabled" and not self._postEffects and POST_EFFECTS[instance.ClassName]
		and instance:GetAttribute(Config.KeepAttribute) ~= true then
		return false
	end

	return nil
end

--[=[
	**Every write this controller makes to Lighting goes through here.** A forced
	property keeps the value it was asked for as the truth and gets the forced one
	instead, so no transition frame shows the effect the player turned off. The truth
	is what `_readLive` reports and what comes back when the setting is turned on.
]=]
function LightingController:_write(instance: Instance, property: string, value: any)
	local forced = self:_forced(instance, property)

	if forced ~= nil then
		local truth = self._truth[instance]
		if not truth then
			truth = {}
			self._truth[instance] = truth
		end

		truth[property] = value
		value = forced
	end

	(instance :: any)[property] = value
end

--[=[
	Puts one property back under its setting after someone else wrote it: the server's
	replication, which does not go through `_write`. What arrived is the new truth.
]=]
function LightingController:_enforce(instance: Instance, property: string)
	local forced = self:_forced(instance, property)
	if forced == nil then return end

	local ok, value = pcall(function()
		return (instance :: any)[property]
	end)

	if not ok or value == forced then return end

	pcall(function()
		self:_write(instance, property, value)
	end)
end

function LightingController:_enforceAll()
	self:_enforce(Lighting, "GlobalShadows")

	for _, child in Lighting:GetChildren() do
		if POST_EFFECTS[child.ClassName] then
			self:_enforce(child, "Enabled")
		end
	end
end

--- Gives the truth back to every property no setting forces anymore.
function LightingController:_releaseAll()
	for instance, truth in self._truth do
		-- A ghost or an effect gone without `Destroying` reaching us: nothing to give back.
		if instance ~= Lighting and not instance.Parent then
			self._truth[instance] = nil
			continue
		end

		for property, value in truth do
			if self:_forced(instance, property) ~= nil then continue end

			truth[property] = nil

			if instance == Lighting or instance.Parent then
				pcall(function()
					(instance :: any)[property] = value
				end)
			end
		end

		if next(truth) == nil then
			self._truth[instance] = nil
		end
	end
end

--- Read values with the truth in place of what a setting forced.
function LightingController:_withTruth(instance: Instance, values: { [string]: any }): { [string]: any }
	local truth = self._truth[instance]
	if not truth then
		return values
	end

	for property, value in truth do
		if values[property] ~= nil then
			values[property] = value
		end
	end

	return values
end

--[=[
	Follows the settings and whatever the server writes over them. Replication does not
	go through `_write`, so each forced property is watched: shadows on `Lighting`,
	`Enabled` on each post effect, including the ones the next preset creates.
]=]
function LightingController:_watchSettings()
	local settings = Framework:Get("SettingsController", false, true)

	Lighting:GetPropertyChangedSignal("GlobalShadows"):Connect(function()
		self:_enforce(Lighting, "GlobalShadows")
	end)

	local function onChild(child: Instance)
		if not POST_EFFECTS[child.ClassName] then return end

		-- The connections die with the effect: the server destroys it on the next preset.
		child:GetPropertyChangedSignal("Enabled"):Connect(function()
			self:_enforce(child, "Enabled")
		end)

		child.Destroying:Connect(function()
			self._truth[child] = nil
		end)

		self:_enforce(child, "Enabled")
	end

	Lighting.ChildAdded:Connect(onChild)
	for _, child in Lighting:GetChildren() do
		onChild(child)
	end

	local function apply()
		self._shadows = settings:Get("Shadows")
		self._postEffects = settings:Get("PostEffects")

		self:_enforceAll()
		self:_releaseAll()
	end

	settings:Observe("Shadows", apply)
	settings:Observe("PostEffects", apply)
end

--[[ STATE ]]

function LightingController:_readLive()
	local state = {
		Lighting = self:_withTruth(Lighting, LightingUtil.ReadInstance(Lighting)),
		Children = {},
	}

	-- A repeated name keeps the first one, the same as `FindFirstChild` returns.
	-- The game's maps carry two children named `Atmosphere`, and both ends of the
	-- transition must agree on which one they are talking about.
	for _, child in Lighting:GetChildren() do
		--[[
			What is marked with `KeepAttribute` belongs to no preset: it belongs to
			another system that controls the effect on its own, today the `UIBlur` that
			the shop and `UILibraryController` turn on behind panels.

			Staying out of the state is what keeps a preset switch from treating it as
			an **outgoing** effect: it is not in the new preset, so `_fadeOut` would
			create a ghost of its size and take it to zero, a second blur on top of the
			one the panel is using. `LightingService` already skips these children in
			its sweep for the same reason.
		]]
		if child:GetAttribute(Config.KeepAttribute) == true then continue end

		if state.Children[child.Name] then continue end

		state.Children[child.Name] = {
			ClassName = child.ClassName,
			Values = self:_withTruth(child, LightingUtil.ReadInstance(child)),
		}
	end

	return state
end

-- Takes Lighting's current state as the starting point, without a transition.
function LightingController:_adopt(name: string?)
	self.currentPreset = name
	self.applied = self:_readLive()
end

--[[
	Where `self.applied` keeps this instance's values. Children are indexed by name:
	the live instance may have been destroyed and recreated by the server between one
	transition and the next.
]]
function LightingController:_bucketFor(instance: Instance)
	if instance == Lighting then
		return self.applied.Lighting
	end

	local child = self.applied.Children[instance.Name]
	return child and child.Values
end

function LightingController:_getPreset(name: string): Folder?
	if not self._root then
		self._root = LightingUtil.GetPresetsRoot(false, 10)
	end

	local root = self._root
	if not root then return nil end

	local preset = root:FindFirstChild(name)
	if not preset or not preset:IsA("Folder") then
		return nil
	end

	return preset
end

--[[ PLAN ]]

--[[
	Compares an instance's source and target and fills the plan:

	- `entries`: interpolates frame by frame;
	- `immediate`: a cut that applies right away (the source value of interpolable
	  properties goes here too, because it is what is now written);
	- `deferred`: a cut that only applies when the transition ends.
]]
function LightingController:_collect(instance: Instance, from, to, plan)
	for propertyName, target in to do
		local origin = from[propertyName]
		if origin == nil or origin == target then continue end

		local interpolate = LightingUtil.GetInterpolator(origin, target)

		if interpolate then
			local ok = pcall(function()
				self:_write(instance, propertyName, origin)
			end)

			if ok then
				table.insert(plan.entries, {
					instance = instance,
					property = propertyName,
					from = origin,
					to = target,
					lastValue = origin,
					interpolate = interpolate,
				})
			end
			continue
		end

		-- Cut: turning off waits for the end so the effect still takes part in the transition;
		-- the rest (turning on, swapping a texture) goes in right away, or there would be nothing to see.
		if target == false then
			pcall(function()
				self:_write(instance, propertyName, origin)
			end)
			table.insert(plan.deferred, { instance = instance, property = propertyName, value = target })
		else
			local ok = pcall(function()
				self:_write(instance, propertyName, target)
			end)

			if ok then
				table.insert(plan.immediate, { instance = instance, property = propertyName, value = target })
			end
		end
	end
end

--[[
	Each preset child's live instance, waiting for replication to arrive.

	Returns `nil` if the generation went stale during the wait: another switch
	started and this plan no longer applies.
]]
function LightingController:_resolveChildren(preset: Folder, generation: number)
	local deadline = os.clock() + CHILD_WAIT

	while true do
		local resolved, missing = {}, nil
		local taken = {}

		for _, presetChild in preset:GetChildren() do
			-- Same rule as `_readLive`: a repeated name in the preset keeps the first,
			-- or two plans would fight over the same live instance.
			if taken[presetChild.Name] then continue end

			local live = Lighting:FindFirstChild(presetChild.Name)
			if live and live.ClassName == presetChild.ClassName then
				taken[presetChild.Name] = true
				resolved[presetChild] = live
			else
				missing = presetChild.Name
			end
		end

		if not missing or os.clock() >= deadline then
			if missing then
				log:Debug(`"{missing}" did not show up in Lighting in time; it enters without a transition.`)
			end
			return resolved
		end

		RunService.Heartbeat:Wait()

		if generation ~= self._generation then
			return nil
		end
	end
end

--[[ TRANSITION ]]

function LightingController:_stop()
	if self._connection then
		self._connection:Disconnect()
		self._connection = nil
	end
end

--[[
	Freezes the transition in progress where it is.

	The next transition calls this: its source must be what is on screen now, not the
	preset the interrupted one started from, or the switch would begin with a jump
	backward.
]]
function LightingController:_freeze()
	local plan = self._plan
	if not plan then return end

	for _, entry in plan.entries do
		local bucket = self:_bucketFor(entry.instance)
		if bucket then
			bucket[entry.property] = entry.lastValue
		end
	end

	for _, entry in plan.immediate do
		local bucket = self:_bucketFor(entry.instance)
		if bucket then
			bucket[entry.property] = entry.value
		end
	end

	-- The outgoing instance was already destroyed by the server; the ghost goes with
	-- it, and its record leaves the state so the next switch does not try to say
	-- goodbye to the same instance again.
	for _, ghost in plan.ghosts do
		self.applied.Children[ghost.Name] = nil
		ghost:Destroy()
	end

	self:_stop()
	self._plan = nil
end

--[[
	Outgoing ghost.

	The instance that only existed in the old preset was already destroyed by the
	server, so there is nothing to interpolate, unless we recreate a local copy (it
	does not replicate) with the old values and take it to neutral. Without this,
	half the visual change of a map switch is a hard cut.
]]
function LightingController:_fadeOut(name: string, previous, plan)
	local target = Config:GetNeutral(previous.ClassName, previous.Values)
	if target == previous.Values then
		-- A class with no neutral (Sky): there is no halfway point, it disappears at once.
		return
	end

	local ok, ghost = pcall(Instance.new, previous.ClassName)
	if not ok or not ghost then return end

	ghost.Name = name
	for propertyName, value in previous.Values do
		pcall(function()
			self:_write(ghost, propertyName, value)
		end)
	end
	ghost.Parent = Lighting
	table.insert(plan.ghosts, ghost)

	self:_collect(ghost, previous.Values, target, plan)
end

function LightingController:_transition(toName: string, duration: number)
	self._generation += 1
	local generation = self._generation
	self:_freeze()

	local preset = self:_getPreset(toName)

	-- No preset to read, no previous state, or a cut requested: Lighting is already
	-- at the final value through replication; it only needs recording.
	if not preset or not self.applied or duration <= 0 then
		if not preset then
			log:Debug(`preset "{toName}" is not in Assets.Lighting; no transition.`)
		end
		self:_adopt(toName)
		return
	end

	local plan = { entries = {}, immediate = {}, deferred = {}, ghosts = {} }

	-- Lighting itself does not depend on instance replication: it goes back to the old
	-- value right away, so no frame shows the new look.
	local lightingTarget = table.clone(self.applied.Lighting)
	for propertyName, value in LightingUtil.ReadPresetAttributes(preset) do
		lightingTarget[propertyName] = value
	end
	self:_collect(Lighting, self.applied.Lighting, lightingTarget, plan)

	local resolved = self:_resolveChildren(preset, generation)
	if not resolved or generation ~= self._generation then return end

	local targetNames = {}

	for presetChild, live in resolved do
		targetNames[presetChild.Name] = true

		local target = LightingUtil.ReadInstance(presetChild)
		local previous = self.applied.Children[presetChild.Name]

		if previous and previous.ClassName == presetChild.ClassName then
			-- Exists in both presets: interpolate value by value.
			self:_collect(live, previous.Values, target, plan)
		else
			-- Only exists in the new preset. The server already created it at the final value,
			-- so the entrance starts from neutral and rises to it.
			self:_collect(live, Config:GetNeutral(presetChild.ClassName, target), target, plan)
		end
	end

	for name, previous in self.applied.Children do
		if not targetNames[name] then
			self:_fadeOut(name, previous, plan)
		end
	end

	self._plan = plan

	local function finish()
		self:_stop()
		self._plan = nil

		for _, entry in plan.entries do
			pcall(function()
				self:_write(entry.instance, entry.property, entry.to)
			end)
		end

		for _, entry in plan.deferred do
			pcall(function()
				self:_write(entry.instance, entry.property, entry.value)
			end)
		end

		-- Before `_adopt`: the ghost must not enter the state as if it were a live
		-- instance of the new preset.
		for _, ghost in plan.ghosts do
			ghost:Destroy()
		end

		self:_adopt(toName)
	end

	plan.finish = finish

	--[[
		Worth logging even when it went right: between two map presets the difference
		is usually one or two properties, and "interpolated a little" is
		indistinguishable from "did not interpolate" by looking at the screen.
	]]
	log:Debug(string.format('"%s" -> "%s" in %.4gs | %d propert(ies) tweening, %d cut(s) at the start, %d at the end, %d exit(s) with a ghost',
		self.currentPreset or "?", toName, duration,
		#plan.entries, #plan.immediate, #plan.deferred, #plan.ghosts))

	if #plan.entries == 0 then
		finish()
		return
	end

	local startedAt = os.clock()

	self._connection = RunService.RenderStepped:Connect(function()
		if generation ~= self._generation then
			self:_stop()
			return
		end

		local alpha = (os.clock() - startedAt) / duration
		if alpha >= 1 then
			finish()
			return
		end

		local eased = LightingUtil.Ease(alpha)
		for _, entry in plan.entries do
			local value = entry.interpolate(entry.from, entry.to, eased)
			entry.lastValue = value;
			(entry.instance :: any)[entry.property] = value
		end
	end)
end

--[[ API ]]

function LightingController:GetCurrent(): string?
	return self.currentPreset
end

-- Cuts the transition in progress and leaves everything at the final value.
function LightingController:Skip()
	local plan = self._plan
	if plan and plan.finish then
		plan.finish()
	end
end

--[[ LIFECYCLE ]]

function LightingController:construct()
	Framework:Listen("LightingApplied", function(_previous, name, duration)
		if typeof(name) ~= "string" then return end

		-- `_transition` waits for children to replicate, so it yields; it leaves the
		-- network callback so it does not hold up other events.
		task.spawn(function()
			self:_transition(name, tonumber(duration) or Config.Transition.Time)
		end)
	end)

	-- Which preset this client starts with. Its Lighting already arrived replicated in
	-- the right state; this is only so the next switch has somewhere to start from.
	Framework:Fire("RequestLighting")
end

function LightingController:start()
	self:_watchSettings()
end

function LightingController:init()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller)
	end

	-- If the server's answer takes long, the place's authored state already works as
	-- the source: better than the first switch going out without a transition.
	self:_adopt(nil)
	self:construct()
end

return LightingController
