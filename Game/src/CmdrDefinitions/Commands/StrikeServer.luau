local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Me = require(Vendor:WaitForChild("Me"))

local Framework = Me.new()

--[[
	Names of the unit types actually on the map now, without repeats. It is what the
	error message needs to say: autocomplete offers the whole catalog, but only what
	is placed can be hit.
]]
local function placedNames(ThunderService) : string
	local unitService = ThunderService.Services.UnitService
	local units = unitService and unitService.PlacedUnits
	if not units or #units == 0 then
		return ""
	end

	local seen, names = {}, {}
	for _, entry in units do
		if not seen[entry.unitName] then
			seen[entry.unitName] = true
			table.insert(names, entry.unitName)
		end
	end
	table.sort(names)

	return table.concat(names, ", ")
end

return function(_context, unitName : string?)
	local ThunderService = Framework:Get("ThunderService", false, true)

	-- Forces a hit on a unit, bypassing the pity roll.
	local entry = ThunderService:strikeUnit(unitName)
	if entry then
		local owner = Players:GetPlayerByUserId(entry.ownerUserId)
		return string.format("Lightning hit %s%s.", entry.unitName, owner and (" (" .. owner.Name .. ")") or "")
	end

	local placed = placedNames(ThunderService)
	if placed == "" then
		return "There is no unit placed on the map to hit."
	end

	if unitName then
		return string.format("No '%s' is placed on the map. Placed right now: %s.", unitName, placed)
	end

	return "Could not pick a unit to hit."
end
