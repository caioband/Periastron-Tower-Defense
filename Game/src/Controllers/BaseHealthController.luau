local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)

local Me = require(Vendor.Me)
local Log = require(Shared:WaitForChild("Util"):WaitForChild("Log"))

local Framework = Me.new()
local log = Log.new("BaseHealthController")

local MapConfig = SharedConfig.MapConfig

--[[ CONSTANTS ]]

-- The name of the clone `MapService` puts in the Workspace. It is the same on every
-- map: what it clones there is the folder's `Content.Map`, and all are called "Map".
local MAP_NAME = "Map"

local WAIT_TIMEOUT = 60
local POLL_STEP = 0.1

--[[
	The base health number, on the billboard each map carries.

	The `BaseHP` Part lives at the root of the map folder, in `ServerStorage.Maps`, and
	`MapService` clones it into `workspace.Map` with the rest; without that the client
	would not even see it, because maps do not replicate. From there it is just text:
	`MobService`'s `UpdateBaseHealth` arrives with the current health and it goes into
	the TextLabel.

	The value is requested once, as soon as the label appears (`RequestBaseHealth`),
	because the event only fires when health changes: a player who joins and has not
	seen any enemy escape would be looking at the text authored in the GUI.

	Nothing here decides any health: `MobService` removes it, on the server, when an
	enemy reaches the end of the path. This controller only displays.

	See docs/game/maps.md.
]]

local BaseHealthController = {}

--[[ INTERNAL ]]

--[=[
	The billboard's TextLabel.

	Looked up by the name `MapConfig` gives, falling back to the Part's first
	TextLabel: the path inside the billboard is the designer's business, and
	reorganizing the `Frame` there must not erase the number here.
]=]
local function findLabel(part : Instance) : TextLabel?
	local fallback = nil

	for _, descendant in part:GetDescendants() do
		if not descendant:IsA("TextLabel") then
			continue
		end

		if descendant.Name == MapConfig.BASE_HEALTH_LABEL then
			return descendant
		end

		fallback = fallback or descendant
	end

	return fallback
end

--[=[
	Waits for the map to arrive and returns the label inside `BaseHP`.

	The Part replicates before its children, so finding the Part does not mean the
	billboard is built. `WaitForChild` only works for a fixed name and what we look
	for here is any TextLabel, so the way is to search again for a few frames. It is a
	one-time cost, at boot.
]=]
function BaseHealthController:_resolveLabel() : TextLabel?
	local mapRoot = workspace:WaitForChild(MAP_NAME, WAIT_TIMEOUT)
	if not mapRoot then
		log:StudioWarn(`workspace.{MAP_NAME} did not arrive; the base health stays as the authored text.`)
		return nil
	end

	local part = mapRoot:WaitForChild(MapConfig.BASE_HEALTH_PART, WAIT_TIMEOUT)
	if not part then
		log:StudioWarn(`the loaded map has no "{MapConfig.BASE_HEALTH_PART}" Part.`)
		return nil
	end

	local deadline = os.clock() + WAIT_TIMEOUT

	repeat
		local label = findLabel(part)
		if label then
			return label
		end

		task.wait(POLL_STEP)
	until os.clock() >= deadline

	log:StudioWarn(`the "{MapConfig.BASE_HEALTH_PART}" Part has no TextLabel inside.`)

	return nil
end

--[=[
	Writes the health to the label. It stays quiet while either is missing: the label
	may arrive after the first event, and the event after the label.
]=]
function BaseHealthController:_write()
	local label = self.Label

	if not label or not label.Parent or not self.Current then
		return
	end

	label.Text = tostring(math.max(0, math.floor(self.Current)))
end

--[[ LIFECYCLE ]]

function BaseHealthController:construct()
	-- Connected before looking for the label: the lookup yields, and a leak in the
	-- middle of it would be a lost number.
	Framework:Listen("UpdateBaseHealth", function(current : number, max : number)
		self.Current = tonumber(current) or self.Current

		-- The maximum does not show on the label (it shows only the current number), but
		-- code asking for the **fraction** needs it: the No Pain, No Gain card only applies
		-- below 20% base health, and the card must show the same bonus the server is
		-- granting.
		self.Max = tonumber(max) or self.Max

		self:_write()
	end)

	self.Label = self:_resolveLabel()
	if not self.Label then
		return
	end

	self:_write()

	-- The first value. If an `UpdateBaseHealth` arrived while the map loaded, this
	-- request only confirms what is already written.
	Framework:Fire("RequestBaseHealth")
end

--[=[
	Base health as a fraction from 0 to 1, or `nil` until the first `UpdateBaseHealth`
	arrives.

	`nil` on purpose, not 1: `CardModifier` reads it, and "I don't know yet" must differ
	from "it is full": the difference decides whether a last-minute bonus shows on the
	card.
]=]
function BaseHealthController:GetHealthRatio() : number?
	if not self.Current or not self.Max or self.Max <= 0 then
		return nil
	end

	return math.clamp(self.Current / self.Max, 0, 1)
end

function BaseHealthController:start()

end

function BaseHealthController:init()
	self:construct()
end

return BaseHealthController
