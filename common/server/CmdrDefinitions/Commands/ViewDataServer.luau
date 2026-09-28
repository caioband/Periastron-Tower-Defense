local ServerScriptService = game:GetService("ServerScriptService")

local ServerConfig = require(ServerScriptService:WaitForChild("Config"))
local ProfileStore = require(ServerScriptService:WaitForChild("Vendor"):WaitForChild("ProfileStore"))

--[[
	`viewdata`: reads a player's saved profile without opening a session.

	It is `ProfileStore:GetAsync` (read mode): it does not lock the profile, saves
	nothing, and works with the player off the server. It is for looking at an old
	store (`PROD_KEY_1`, after the `PROFILE_KEY` change) or an old version by date:
	the DataStore keeps each key's versions for a while (today, 30 days), and
	`VersionQuery` fetches the last one saved up to the requested date.

	The answer goes to the Cmdr console and, in full, to the server log (F9 →
	Server), which is easier to copy.
]]

local MAX_DEPTH = 12

local function parseDate(text : string) : number?
	local y, m, d, rest = string.match(text, "^(%d%d%d%d)%-(%d%d?)%-(%d%d?)(.*)$")
	if not y then
		return nil
	end

	local hour, minute = 23, 59
	if rest ~= "" then
		local h, mi = string.match(rest, "^[T ](%d%d?):(%d%d)$")
		if not h then
			return nil
		end
		hour, minute = tonumber(h), tonumber(mi)
	end

	local ok, dateTime = pcall(DateTime.fromUniversalTime, tonumber(y), tonumber(m), tonumber(d), hour, minute, 59)
	return ok and dateTime.UnixTimestampMillis or nil
end

local function formatTime(seconds : number?) : string
	if not seconds or seconds == 0 then
		return "?"
	end
	return DateTime.fromUnixTimestamp(seconds):FormatUniversalTime("YYYY-MM-DD HH:mm", "en-us") .. " UTC"
end

local function formatMillis(millis : number?) : string
	return millis and formatTime(millis // 1000) or "?"
end

-- Readable dump, keys sorted, so two versions can be compared by eye.
local function dump(value : any, indent : string, depth : number, out : { string })
	if typeof(value) ~= "table" then
		table.insert(out, typeof(value) == "string" and string.format("%q", value) or tostring(value))
		return
	end

	if next(value) == nil then
		table.insert(out, "{}")
		return
	end

	if depth >= MAX_DEPTH then
		table.insert(out, "{...}")
		return
	end

	local keys = {}
	for key in value do
		table.insert(keys, key)
	end
	table.sort(keys, function(a, b)
		if typeof(a) == typeof(b) and (typeof(a) == "number" or typeof(a) == "string") then
			return a < b
		end
		return typeof(a) < typeof(b)
	end)

	local inner = indent .. "  "
	table.insert(out, "{\n")
	for _, key in keys do
		table.insert(out, inner .. tostring(key) .. " = ")
		dump(value[key], inner, depth + 1, out)
		table.insert(out, "\n")
	end
	table.insert(out, indent .. "}")
end

return function(_context, userId : number, storeName : string?, dateText : string?)
	if not storeName or storeName == "" or string.lower(storeName) == "current" then
		storeName = ServerConfig.Data.PROFILE_KEY
	end

	local maxDate
	if dateText and dateText ~= "" then
		maxDate = parseDate(dateText)
		if not maxDate then
			return `Invalid date "{dateText}". Use YYYY-MM-DD or YYYY-MM-DDTHH:MM (UTC).`
		end
	end

	local profileKey = "Player_" .. userId
	local ok, profile = pcall(function()
		-- Empty template: this is a read, and what matters is what is saved, not what
		-- today's template would be missing. Inside the pcall because `New` errors on
		-- an invalid store name (empty or over 50 characters).
		local store = ProfileStore.New(storeName, {})

		if maxDate then
			return store:VersionQuery(profileKey, Enum.SortDirection.Descending, nil, maxDate):NextAsync()
		end
		return store:GetAsync(profileKey)
	end)

	if not ok then
		return `Failed to read {storeName}/{profileKey}: {profile}`
	end
	if not profile then
		local when = maxDate and ` up to {formatMillis(maxDate)}` or ""
		return `No saved profile for {profileKey} in store "{storeName}"{when}.`
	end

	local keyInfo = profile.KeyInfo
	local header = table.concat({
		`Store: {storeName}   Key: {profileKey}`,
		`Version saved: {formatMillis(keyInfo and keyInfo.UpdatedTime)}   (version id: {keyInfo and keyInfo.Version or "?"})`,
		`Profile created: {formatTime(profile.FirstSessionTime)}   Sessions: {profile.SessionLoadCount}`,
	}, "\n")

	local out = {}
	dump(profile.Data, "", 0, out)
	local body = table.concat(out)

	-- Deliberately a raw `print` and not `Log`: this is output an admin asked for,
	-- and it must reach the server log (F9 > Server) in live servers too.
	print(`[viewdata]\n{header}\n{body}`)

	return `{header}\n{body}`
end
