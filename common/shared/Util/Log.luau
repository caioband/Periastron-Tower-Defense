local RunService = game:GetService("RunService")

--[[
	The single way first-party code writes to the Output. Works on the server and
	the client, in both places.

		local log = Log.new("MapService")

		log:Debug("loaded", mapName)            -- print, Studio only
		log:StudioWarn("map has no SpawnLocation") -- warn, Studio only
		log:Warn("teleport failed:", err)       -- warn, always
		log:StudioWarnOnce(key, "...")          -- the same, at most once per key
		log:WarnOnce(key, "...")

	Arguments are passed through like `print`/`warn` do; format the message with
	string interpolation or `string.format` before calling.

	`Warn` is for the cases a live server must report: data and persistence,
	monetization, teleports, and server failures that switch a feature off for
	real players. Anything that only tells the person building the game that
	something is missing or misconfigured is `StudioWarn`; anything that is just
	information is `Debug`. See docs/common/logging.md.

	It is a Util and not a Service of the `Me` framework because Services only
	exist on the server, and because Roblox already has a built-in `LogService`.
]]

local IS_STUDIO = RunService:IsStudio()

export type Logger = {
	Tag : string,
	Debug : (self : Logger, ...any) -> (),
	StudioWarn : (self : Logger, ...any) -> (),
	Warn : (self : Logger, ...any) -> (),
	StudioWarnOnce : (self : Logger, key : any, ...any) -> (),
	WarnOnce : (self : Logger, key : any, ...any) -> (),
}

local Logger = {}
Logger.__index = Logger

local Log = {}

-- Keys already reported by the *Once variants, per tag. Shared by every logger
-- with the same tag, so two modules creating `Log.new("X")` do not repeat each
-- other's warnings.
local seen : { [string] : { [any] : boolean } } = {}

function Log.new(tag : string) : Logger
	seen[tag] = seen[tag] or {}
	return (setmetatable({ Tag = `[{tag}]`, _seen = seen[tag] }, Logger) :: any) :: Logger
end

--- Whether this session is running in Studio, for code that gates more than a log line.
function Log.IsStudio() : boolean
	return IS_STUDIO
end

function Logger:Debug(... : any)
	if not IS_STUDIO then return end
	print(self.Tag, ...)
end

function Logger:StudioWarn(... : any)
	if not IS_STUDIO then return end
	warn(self.Tag, ...)
end

function Logger:Warn(... : any)
	warn(self.Tag, ...)
end

local function firstTime(self : any, key : any) : boolean
	if self._seen[key] then return false end
	self._seen[key] = true
	return true
end

function Logger:StudioWarnOnce(key : any, ... : any)
	if not IS_STUDIO then return end
	if not firstTime(self, key) then return end
	warn(self.Tag, ...)
end

function Logger:WarnOnce(key : any, ... : any)
	if not firstTime(self, key) then return end
	warn(self.Tag, ...)
end

return Log
