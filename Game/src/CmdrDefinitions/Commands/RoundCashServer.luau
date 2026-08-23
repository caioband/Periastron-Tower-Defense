local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Me = require(Vendor:WaitForChild("Me"))

local Framework = Me.new()

--[[
	O dinheiro da partida, que é outra coisa do `cash`.

	Este vive no `MobService.SessionCash`: nasce com o `StartingCash` da dificuldade,
	é o que paga as torres e morre com o round, sem nunca passar pelo perfil. Por isso
	o comando mora na Game — o `MobService` não existe no Lobby, e no Lobby o
	`Framework:Get` com yield esperaria para sempre.

	A conta passa pelo `addCash`/`spendCash` do service, e não por uma escrita direta
	na tabela, porque são eles que disparam o `UpdateCash` para o cliente: sem isso o
	contador na tela continuaria mostrando o valor antigo até a próxima kill.
]]
return function(_context, action : string, players : { Player }, amount : number)
	local MobService = Framework:Get("MobService", false, true)

	if #players == 0 then
		return "Nobody matched."
	end

	local done = {}

	for _, player in players do
		local previous = MobService:getCash(player)

		local target
		if action == "set" then
			target = math.max(amount, 0)
		elseif action == "remove" then
			target = math.max(previous - amount, 0)
		else
			target = math.max(previous + amount, 0)
		end

		local delta = target - previous
		if delta > 0 then
			MobService:addCash(player, delta)
		elseif delta < 0 then
			MobService:spendCash(player, -delta)
		end

		table.insert(done, string.format("%s %d -> %d", player.Name, previous, MobService:getCash(player)))
	end

	return string.format("%s roundcash: %s", action, table.concat(done, ", "))
end
