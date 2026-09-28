local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Me = require(Vendor.Me)
local Log = require(Shared.Util.Log)

local Framework = Me.new()
local log = Log.new("ServerRestartService")

--[[
	The warning that the server is about to restart.

	The engine itself warns: `game.ServerRestartScheduled` fires on the server when
	Roblox schedules this server's end, whether because the developer published an
	update or for Roblox maintenance, moderation, or memory. The event carries
	**when** (`restartTime`, a `DateTime`) and **why** (`source`, an
	`Enum.CloseReason`).

	The event only exists on the server, so this service relays it to clients as
	`ServerRestartScheduled` (reason name + seconds left), and
	`ServerRestartController` writes the sentence on screen.

	**Seconds left, not the time of day.** `restartTime` is UTC and the client clock
	is not reliable: a machine with the wrong time would show "restart in 3 hours".
	The math is done here, against the server clock, and redone on every send: a
	player who joins two minutes later gets two minutes less.

	It lives in `common/` because the restart takes down both places.

	See docs/common/screen-warnings.md.
]]

local ServerRestartService = {
	Services = {}
}

-- The `Enum.CloseReason` name the engine sent, and the restart instant in
-- Unix time. Both nil while nothing is scheduled.
ServerRestartService.Source = nil :: string?
ServerRestartService.RestartTime = nil :: number?
ServerRestartService.Scheduled = false

--[[ INTERNAL ]]

--[=[
	Splits `restartTime` and `source` out of what the engine sent.

	The argument order is read from the value, not the position, on purpose: the
	documented signature is `(restartTime, source, attributes)`, but the event is new
	and has already been documented in swapped order. Checking `typeof` costs nothing
	and survives both; what must not happen is showing the time in place of the
	reason.
]=]
local function readSchedule(...) : (DateTime?, EnumItem?)
	local packed = table.pack(...)

	local restartTime : DateTime? = nil
	local source : EnumItem? = nil

	for index = 1, packed.n do
		local value = packed[index]
		local kind = typeof(value)

		if kind == "DateTime" then
			restartTime = value
		elseif kind == "EnumItem" and (value :: EnumItem).EnumType == Enum.CloseReason then
			source = value
		end
	end

	return restartTime, source
end

--[=[
	How many seconds are left until the restart, or nil if the engine did not say when.
]=]
function ServerRestartService:GetRemaining() : number?
	if not self.RestartTime then
		return nil
	end

	return math.max(self.RestartTime - DateTime.now().UnixTimestamp, 0)
end

--[=[
	Sends the warning to one player. With nothing scheduled, sends nothing.
]=]
function ServerRestartService:Send(player : Player)
	if not self.Scheduled then return end

	Framework:Fire("ServerRestartScheduled", player, self.Source, self:GetRemaining())
end

--[=[
	Stores the schedule and warns everyone already on the server.

	Public because this is what Cmdr's `restartwarning` needs to rehearse the warning
	without actually taking the server down.
]=]
function ServerRestartService:Schedule(source : string?, restartTime : number?)
	self.Scheduled = true
	self.Source = source
	self.RestartTime = restartTime

	for _, player in Players:GetPlayers() do
		self:Send(player)
	end
end

--[[ LIFECYCLE ]]

function ServerRestartService:construct()
	-- Players who join after the schedule (or before their Interface exists) ask
	-- for the pending warning.
	Framework:Listen("RequestServerRestart", function(player : Player)
		self:Send(player)
	end)

	-- On an engine version that does not have the event yet, reading the property is
	-- an error, not nil. The `pcall` keeps the rest of the service up: Cmdr's
	-- `restartwarning` still rehearses the warning.
	local ok, scheduled = pcall(function()
		return (game :: any).ServerRestartScheduled
	end)

	if not ok or typeof(scheduled) ~= "RBXScriptSignal" then
		log:Warn("game.ServerRestartScheduled does not exist in this engine version.")
		return
	end

	scheduled:Connect(function(...)
		local restartTime, source = readSchedule(...)

		self:Schedule(source and source.Name, restartTime and restartTime.UnixTimestamp)
	end)
end

function ServerRestartService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service)
	end

	self:construct()
end

function ServerRestartService:init()
	-- The event identifier is created on the server: without this empty `Listen`,
	-- the client's `Listen` would wait ten seconds for an event nobody registered,
	-- and take the rest of the controller down with it.
	Framework:Listen("ServerRestartScheduled", function() end)
end

return ServerRestartService
