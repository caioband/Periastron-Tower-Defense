local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Me = require(Vendor:WaitForChild("Me"))

local Framework = Me.new()

--[[
	Makes the card shop appear right away, without waiting for the right wave.

	It is the same `Open` that `WaveStarted` calls every X waves (see
	`RoundCardConfig.Intervals`): the three cards are drawn again and the previous
	offer of anyone with the shop open loses validity: the `Token` goes up, and a late
	click on the old shop buys nothing from the new one.

	**It draws from each target's pool**, not the catalog: the cards that player
	unlocked in the Lobby card shop. A player who unlocked none gets no offer, which
	is why the command may open nothing even with valid targets. To give someone
	cards, the way is the profile (`Data.RoundCards`), not this command.

	Only Game has the shop: `CardShopService` does not exist in the Lobby, and there
	a yielding `Framework:Get` would wait forever.
]]
return function(_context, players : { Player }?)
	local CardShopService = Framework:Get("CardShopService", false, true)

	local targets = players
	if not targets or #targets == 0 then
		targets = Players:GetPlayers()
	end

	if #targets == 0 then
		return "Nobody matched."
	end

	--[[
		`Open` only returns true when **someone** got an offer. The two reasons for not
		getting one differ, and the one below is the common one: none of the targets
		unlocked any card. The other (a catalog with no registered effect) already shows
		as a warning in the server output when it happens.
	]]
	if not CardShopService:Open(targets) then
		return "Nothing to offer: no target has any round card unlocked (see the lobby card shop)."
	end

	local names = {}
	for _, player in targets do
		table.insert(names, player.Name)
	end

	return string.format("Round card shop opened for %s.", table.concat(names, ", "))
end
