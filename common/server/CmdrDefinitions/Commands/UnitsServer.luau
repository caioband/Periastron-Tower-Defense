local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs:WaitForChild("SharedConfig"))
local Me = require(Vendor:WaitForChild("Me"))

local Framework = Me.new()

local UnitStats = SharedConfig.UnitStats

--[[
	O inventário de unidades do perfil (`Units`), que é outra coisa do deck.

	`Units` é **quantas de cada uma o jogador tem**; `EquippedUnits` é quais delas
	estão nos slots. Este comando mexe só no primeiro, e de propósito: o
	`DeckConfig.sanitize` roda a cada leitura do deck e já corta o `Amount` de cada
	slot pelo que a pessoa possui, então tirar unidade daqui esvazia o slot sozinho,
	sem ninguém precisar reescrever o deck.

	Mora no `common/` porque as duas places têm `DataService` e as duas leem o
	`Units`: o Lobby para montar o deck, a Game para as cartas da partida.

	⚠️ **Na Game, o round que já começou não muda.** As cartas da partida são
	fotografadas do perfil no `UnitService:initPlayerCards`, que roda no começo do
	round — dar unidade no meio de uma wave só aparece no round seguinte (ou depois
	de um `ResetRound`). No Lobby o efeito é imediato: o deck lê o perfil a cada
	mudança da replica.
]]

--[=[
	O nome canônico da unidade, aceitando diferença de maiúsculas.

	O tipo `unitName` só recusa string vazia — o autocomplete oferece a lista certa,
	mas nada impede digitar `slasher` na mão. Resolver aqui evita um "não existe"
	para um nome que existe, e a resposta do comando devolve a grafia oficial.
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

	-- Online neste servidor, em outro ou offline: quem decide o caminho é o
	-- `ProfileEditService`. Unidade zerada sai da tabela (ver `KEYS` lá).
	return ProfileEditService:RunCommand(userIds, {
		Key = "Units",
		Field = unitName,
		Action = action,
		Amount = math.max(0, math.floor(amount or 1)),
	})
end
