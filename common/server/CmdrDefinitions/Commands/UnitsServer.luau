local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs:WaitForChild("SharedConfig"))
local Me = require(Vendor:WaitForChild("Me"))

local Framework = Me.new()

local UnitStats = SharedConfig.UnitStats

--[[
	The profile's unit inventory (`Units`), which is not the deck.

	`Units` is **how many of each the player owns**; `EquippedUnits` is which are in
	the slots. This command touches only the first, on purpose: `DeckConfig.sanitize`
	runs on every deck read and already caps each slot's `Amount` at what the player
	owns, so removing units here empties the slot on its own, without anyone
	rewriting the deck.

	It lives in `common/` because both places have `DataService` and both read
	`Units`: the Lobby to build the deck, Game for the match cards.

	⚠️ **In Game, a round already in progress does not change.** Match cards are a
	snapshot of the profile taken in `UnitService:initPlayerCards`, which runs at
	round start: giving units mid-wave only shows on the next round (or after a
	`ResetRound`). In the Lobby the effect is immediate: the deck reads the profile
	on every replica change.
]]

--[=[
	The unit's canonical name, ignoring case differences.

	The `unitName` type only rejects an empty string: autocomplete offers the right
	list, but nothing stops typing `slasher` by hand. Resolving here avoids a "does
	not exist" for a name that exists, and the command's answer returns the official
	spelling.
]=]
local function resolveUnitName(text : string) : string?
	if UnitStats[text] then
		return text
	end

	local lowered = string.lower(text)
	for unitName in UnitStats do
		if string.lower(unitName) == lowered then
			return unitName
		end
	end

	return nil
end

local function knownNames() : string
	local names = {}
	for unitName in UnitStats do
		table.insert(names, unitName)
	end
	table.sort(names)

	return table.concat(names, ", ")
end

return function(_context, action : string, userIds : { number }, unitText : string, amount : number?)
	local ProfileEditService = Framework:Get("ProfileEditService", false, true)

	local unitName = resolveUnitName(unitText)
	if not unitName then
		return string.format("There is no unit called '%s'. Known units: %s.", unitText, knownNames())
	end

	-- Online on this server, on another one, or offline: `ProfileEditService`
	-- picks the path. A unit at zero leaves the table (see `KEYS` there).
	return ProfileEditService:RunCommand(userIds, {
		Key = "Units",
		Field = unitName,
		Action = action,
		Amount = math.max(0, math.floor(amount or 1)),
	})
end
