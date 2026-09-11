local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Configs = Shared:WaitForChild("Config")
local ServerConfigs = ServerScriptService:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)
local ServerConfig = require(ServerConfigs)

local Me = require(Vendor.Me)

local Framework = Me.new()

local ContractConfig = SharedConfig.ContractConfig
local CrateConfig = SharedConfig.CrateConfig
local MapConfig = SharedConfig.MapConfig
local UnitStats = SharedConfig.UnitStats
local WeatherConfig = SharedConfig.WeatherConfig
local UnlockConfig = SharedConfig.DifficultyUnlockConfig

local DIFFICULTY_ORDER = ServerConfig.Difficulty.Order
local RANDOM = ContractConfig.RANDOM

--[[
	Os contratos do jogador: sorteio, progresso, resgate e pagamento.

	Mora em `common` porque as duas places mexem neles. A **Game** e onde quase tudo
	conta (vitoria, kill, dano, clima...), pelo `ContractTrackerService`; a **Lobby**
	conta as caixas (`CrateService`) e e onde o quadro esta, e portanto o resgate. O
	login conta nas duas. E as duas precisam sortear: a hora pode virar com o
	jogador no meio de uma partida.

	**O sorteio e por jogador, e so acontece na virada.** A cada tick, e quando o
	perfil carrega, cada periodo e comparado com o de agora; se mudou, os slots
	daquele periodo sao sorteados de novo (ver `_draw`). Contrato nao resgatado se
	perde junto -- e por isso nao ha nada a limpar.

	**O progresso vai em lote.** `Record` so anota numa fila por jogador; o `Flush`
	escreve tudo numa passada (`Update` de `Contracts`), a cada `FLUSH_INTERVAL`, no
	resgate e na saida. Uma escrita por evento replicaria o `Contracts` inteiro a
	cada inimigo morto. Cada entrada da fila lembra o periodo e o `Id` do slot, entao
	o progresso de um contrato que venceu no meio do lote nao cai no que o substituiu.

	**O resgate e do servidor.** O cliente manda so "o slot N do periodo X"; quem
	confere que ele esta completo e ainda nao foi pago e este service. Marcar como
	pago e pagar acontecem em sequencia, sem nada que ceda no meio, entao dois
	cliques nao pagam duas vezes.
]]

-- De quanto em quanto tempo a fila e escrita, as viradas conferidas e o login
-- marcado.
local FLUSH_INTERVAL = 2

-- Depois de quem ainda escreve progresso na saida (o `ContractTrackerService`, com a
-- ultima leitura da partida). Ver `DataService:OnBeforeRelease`.
local RELEASE_ORDER = 1

local ContractService = {
	Services = {
		DataService = {},
	},

	-- [Player] = { ["Kind|Index"] = { Kind, Index, Period, Id, Mode, Value, Seen } }
	Pending = {},
}

--[[ INTERNAL ]]

local function now() : number
	return workspace:GetServerTimeNow()
end

local function dayIndex() : number
	return math.floor(now() / 86400)
end

local function difficultyRank(name : string?) : number
	return name and table.find(DIFFICULTY_ORDER, name) or 0
end

local function shuffle(list : { any }, rng : Random)
	for i = #list, 2, -1 do
		local j = rng:NextInteger(1, i)
		list[i], list[j] = list[j], list[i]
	end
end

function ContractService:_profileOf(player : Player) : any
	local dataService = self.Services.DataService
	local profiles = dataService and dataService.Profiles
	local entry = profiles and profiles[player]

	return entry and entry.Profile.Data or nil
end

--[[ SORTEIO ]]

--- Os mapas que o jogador ja pode escolher.
local function unlockedMaps(profile) : { string }
	local wins = profile.Stats and profile.Stats.Wins or 0
	local maps = {}

	for _, map in MapConfig.getOrderedMaps() do
		if MapConfig.isUnlocked(map, wins) then
			table.insert(maps, map)
		end
	end

	return maps
end

--- As dificuldades que o jogador ja pode votar.
local function unlockedDifficulties(profile) : { string }
	local difficulties = {}

	for _, name in DIFFICULTY_ORDER do
		if UnlockConfig.isUnlocked(name, profile.Stats) then
			table.insert(difficulties, name)
		end
	end

	return difficulties
end

--[=[
	As classes das unidades que o jogador tem. "Win with only Fire" para quem nao
	tem unidade Fire nao teria como ser feito; sem unidade nenhuma, qualquer classe.
]=]
local function ownedClasses(profile) : { string }
	local seen = {}
	local classes = {}

	for unitName, amount in (profile.Units or {}) do
		if (tonumber(amount) or 0) <= 0 then continue end

		for _, class in WeatherConfig.GetClasses(unitName) do
			if not seen[class] then
				seen[class] = true
				table.insert(classes, class)
			end
		end
	end

	if #classes == 0 then
		return table.clone(WeatherConfig.ClassList)
	end

	return classes
end

local function ownsUnitWith(profile, stat : string) : boolean
	for unitName, amount in (profile.Units or {}) do
		local stats = UnitStats[unitName]
		if (tonumber(amount) or 0) > 0 and typeof(stats) == "table" and stats[stat] ~= nil then
			return true
		end
	end

	return false
end

--[=[
	Se o contrato pode sair para este jogador: mapa e dificuldade fixos precisam
	estar abertos, e o `NeedsUnitStat` precisa de uma unidade que o tenha.
]=]
local function isAvailable(definition, profile) : boolean
	local map = definition.Map
	if map and map ~= RANDOM and not MapConfig.isUnlocked(map, profile.Stats and profile.Stats.Wins or 0) then
		return false
	end

	local difficulty = definition.Difficulty
	if difficulty and difficulty ~= RANDOM and not UnlockConfig.isUnlocked(difficulty, profile.Stats) then
		return false
	end

	if definition.NeedsUnitStat and not ownsUnitWith(profile, definition.NeedsUnitStat) then
		return false
	end

	return true
end

--- O que o `Random` de cada campo tira, entre o que este jogador ja abriu.
local function rollParams(definition, profile, rng : Random) : { [string] : string }
	local params = {}

	local function pick(list : { string }) : string?
		if #list == 0 then return nil end
		return list[rng:NextInteger(1, #list)]
	end

	if definition.Map == RANDOM then
		params.Map = pick(unlockedMaps(profile)) or "Farm"
	end

	if definition.Difficulty == RANDOM then
		params.Difficulty = pick(unlockedDifficulties(profile)) or DIFFICULTY_ORDER[1]
	end

	if definition.Class == RANDOM then
		params.Class = pick(ownedClasses(profile))
	end

	return params
end

--[=[
	Os slots de um periodo novo.

	A urna e a lista do periodo filtrada pelo que o jogador pode fazer. Os contratos
	do periodo anterior (`previous`) vao para o fim: o sorteio tira primeiro dos
	novos, e so completa com repetidos quando nao sobram novos suficientes. Se nem
	assim fecha a conta (um jogador com quase tudo trancado), completa com o que o
	filtro tinha tirado, para a secao nunca aparecer com buraco.
]=]
function ContractService:_draw(kind : string, previous : { any }, profile, rng : Random) : { any }
	local count = ContractConfig.KINDS[kind].Count
	local list = ContractConfig.Contracts[kind]

	local wasThere = {}
	for _, slot in previous do
		if slot.Id then
			wasThere[slot.Id] = true
		end
	end

	local fresh, repeated, locked = {}, {}, {}
	for _, definition in list do
		if not isAvailable(definition, profile) then
			table.insert(locked, definition)
		elseif wasThere[definition.Id] then
			table.insert(repeated, definition)
		else
			table.insert(fresh, definition)
		end
	end

	shuffle(fresh, rng)
	shuffle(repeated, rng)
	shuffle(locked, rng)

	local slots = {}
	for _, group in { fresh, repeated, locked } do
		for _, definition in group do
			if #slots >= count then break end

			table.insert(slots, {
				Id = definition.Id,
				Params = rollParams(definition, profile, rng),
				Progress = 0,
				Claimed = false,
			})
		end
	end

	return slots
end

--[=[
	Sorteia de novo cada periodo que virou. Uma escrita so para os tres, e nenhuma
	quando nada virou -- que e o caso de quase todo tick.
]=]
function ContractService:_ensurePeriods(player : Player)
	local profile = self:_profileOf(player)
	if not profile then return end

	local contracts = profile.Contracts
	local time = now()

	local stale = {}
	for _, kind in ContractConfig.KIND_ORDER do
		local bucket = contracts and contracts[kind]
		local period = ContractConfig.periodOf(kind, time)

		if not bucket or bucket.Period ~= period then
			stale[kind] = period
		end
	end

	if next(stale) == nil then return end

	local rng = Random.new()

	self.Services.DataService:Update(player, "Contracts", function(current)
		current = typeof(current) == "table" and current or ContractConfig.createEmpty()

		for kind, period in stale do
			local bucket = current[kind]
			local previous = typeof(bucket) == "table" and bucket.Slots or {}

			current[kind] = {
				Period = period,
				Slots = self:_draw(kind, previous, profile, rng),
			}
		end

		return current
	end)
end

--[[ PROGRESSO ]]

--[=[
	Se o evento serve para este slot. Cada campo do contrato e uma condicao sobre o
	contexto; campo que o contrato nao tem nao filtra nada.
]=]
local function matches(definition, slot, context) : boolean
	if definition.Map then
		if context.Map ~= ContractConfig.resolve(definition, slot, "Map") then
			return false
		end
	end

	if definition.Difficulty then
		if context.Difficulty ~= ContractConfig.resolve(definition, slot, "Difficulty") then
			return false
		end
	end

	if definition.MinDifficulty then
		if difficultyRank(context.Difficulty) < difficultyRank(definition.MinDifficulty) then
			return false
		end
	end

	if definition.FullHealth and not context.FullHealth then
		return false
	end

	if definition.WithFriends and not context.WithFriends then
		return false
	end

	-- "Only X units": `CommonClasses` e o que **toda** unidade colocada tem em comum.
	if definition.Class then
		local class = ContractConfig.resolve(definition, slot, "Class")
		if not (class and context.CommonClasses and context.CommonClasses[class]) then
			return false
		end
	end

	if definition.Rarity and context.Rarity ~= definition.Rarity then
		return false
	end

	return true
end

--[=[
	Anota um evento para os contratos do jogador que ele serve. Nao escreve nada: a
	escrita e do `Flush`.

	`value` e quanto somar (`Sum`), o valor a comparar (`Max`) ou o valor a marcar
	(`Distinct`). `context` carrega o que os filtros olham -- `Map`, `Difficulty`,
	`FullHealth`, `WithFriends`, `CommonClasses`, `Rarity`.
]=]
function ContractService:Record(player : Player, event : string, value : number, context : { [string] : any }?)
	local profile = self:_profileOf(player)
	local contracts = profile and profile.Contracts
	if typeof(contracts) ~= "table" then return end

	context = context or {}

	for _, kind in ContractConfig.KIND_ORDER do
		local bucket = contracts[kind]
		if typeof(bucket) ~= "table" then continue end

		for index, slot in bucket.Slots or {} do
			local definition = ContractConfig.get(slot.Id)
			if not definition or definition.Event ~= event then continue end
			if slot.Claimed or (slot.Progress or 0) >= definition.Goal then continue end

			local mode = definition.Mode or "Sum"

			-- O dia de hoje ja marcado nao precisa passar pela fila de novo a cada tick.
			if mode == "Distinct" and slot.Seen and slot.Seen[tostring(value)] then continue end

			if not matches(definition, slot, context) then continue end

			local pending = self.Pending[player]
			if not pending then
				pending = {}
				self.Pending[player] = pending
			end

			local key = kind .. "|" .. index
			local entry = pending[key]

			if not entry or entry.Period ~= bucket.Period or entry.Id ~= slot.Id then
				entry = {
					Kind = kind,
					Index = index,
					Period = bucket.Period,
					Id = slot.Id,
					Mode = mode,
					Value = 0,
				}
				pending[key] = entry
			end

			if mode == "Max" then
				entry.Value = math.max(entry.Value, value)
			elseif mode == "Distinct" then
				entry.Seen = entry.Seen or {}
				entry.Seen[tostring(value)] = true
			else
				entry.Value += value
			end
		end
	end
end

--- Escreve a fila do jogador no perfil, numa passada so.
function ContractService:Flush(player : Player)
	local pending = self.Pending[player]
	if not pending or next(pending) == nil then return end

	self.Pending[player] = nil

	if not self:_profileOf(player) then return end

	self.Services.DataService:Update(player, "Contracts", function(contracts)
		for _, entry in pending do
			local bucket = contracts[entry.Kind]
			local slot = bucket and bucket.Period == entry.Period and bucket.Slots[entry.Index]

			if not slot or slot.Id ~= entry.Id or slot.Claimed then continue end

			local definition = ContractConfig.get(slot.Id)
			if not definition then continue end

			local progress = slot.Progress or 0

			if entry.Mode == "Max" then
				progress = math.max(progress, entry.Value)
			elseif entry.Mode == "Distinct" then
				slot.Seen = slot.Seen or {}

				for key in entry.Seen or {} do
					slot.Seen[key] = true
				end

				progress = 0
				for _ in slot.Seen do
					progress += 1
				end
			else
				progress += entry.Value
			end

			slot.Progress = math.min(definition.Goal, math.max(0, math.floor(progress)))
		end

		return contracts
	end)
end

--[[ RESGATE ]]

--[=[
	Paga a recompensa. Os coins entram tambem no `CoinsEarned` (a MOST COINS e o
	total ganho, e contrato e ganho). As caixas vao pelo `CrateService` quando ele
	existe -- ele avisa a tela da backpack --, e direto no inventario quando nao.
]=]
function ContractService:_grant(player : Player, rewards)
	local dataService = self.Services.DataService
	local cash = math.max(0, math.floor(rewards.Cash or 0))
	local shards = math.max(0, math.floor(rewards.Shards or 0))

	if cash > 0 or shards > 0 then
		dataService:Update(player, "Stats", function(stats)
			stats.Cash = (stats.Cash or 0) + cash
			stats.CoinsEarned = (tonumber(stats.CoinsEarned) or 0) + cash
			stats.Shards = (stats.Shards or 0) + shards
			return stats
		end)
	end

	if not rewards.Crates then return end

	local crateService = Framework:Get("CrateService")

	for rarity, amount in rewards.Crates do
		amount = math.max(0, math.floor(amount))
		if amount <= 0 then continue end

		if crateService and crateService.GiveCrates then
			crateService:GiveCrates(player, rarity, amount)
			continue
		end

		local resolved = CrateConfig.resolveRarity(rarity)
		if not resolved then
			warn(string.format("[ContractService]: %q nao e um tier de caixa; recompensa ignorada.", tostring(rarity)))
			continue
		end

		dataService:Update(player, "Inventory", function(inventory)
			inventory = inventory or {}
			inventory.Crates = inventory.Crates or CrateConfig.createEmptyCrates()
			inventory.Crates[resolved] = math.min(
				CrateConfig.MAX_CRATES_PER_RARITY,
				(inventory.Crates[resolved] or 0) + amount
			)
			return inventory
		end)
	end
end

--[=[
	O resgate de um slot. Devolve se pagou e, quando nao, o motivo: `NotLoaded`,
	`NoContract`, `NotComplete` ou `AlreadyClaimed`.

	A fila e escrita antes da conferencia: o evento que completou o contrato pode
	estar nela, e o jogador que viu o "CLAIM" acender nao pode ouvir "incompleto".
]=]
function ContractService:Claim(player : Player, kind : any, index : any) : (boolean, string?)
	if not ContractConfig.isKind(kind) or typeof(index) ~= "number" then
		return false, "NoContract"
	end

	if not self:_profileOf(player) then
		return false, "NotLoaded"
	end

	self:_ensurePeriods(player)
	self:Flush(player)

	local contracts = self:_profileOf(player).Contracts
	local bucket = contracts and contracts[kind]
	local slot = bucket and bucket.Slots[index]
	local definition = slot and ContractConfig.get(slot.Id)

	if not definition then
		return false, "NoContract"
	end

	if slot.Claimed then
		return false, "AlreadyClaimed"
	end

	if not ContractConfig.isComplete(definition, slot) then
		return false, "NotComplete"
	end

	self.Services.DataService:Update(player, "Contracts", function(current)
		current[kind].Slots[index].Claimed = true
		return current
	end)

	self:_grant(player, definition.Rewards or {})

	return true, nil
end

--[[ CICLO DE VIDA ]]

function ContractService:_tick(player : Player)
	self:_ensurePeriods(player)

	-- O login conta pelo dia em que o jogador esta online, e nao so pela entrada:
	-- quem atravessa a meia-noite jogando tambem marca o dia novo.
	self:Record(player, ContractConfig.Events.Login, dayIndex())
	self:Flush(player)
end

function ContractService:construct()
	local dataService = self.Services.DataService
	if not dataService then
		warn("[ContractService]: sem DataService; os contratos nao vao funcionar.")
		return
	end

	dataService.Signals.PlayerDataLoaded:Connect(function(player : Player)
		self:_tick(player)
	end)

	for _, player in Players:GetPlayers() do
		if self:_profileOf(player) then
			self:_tick(player)
		end
	end

	-- O que ficou na fila entra com o perfil ainda aberto, depois de quem escreve na
	-- saida.
	if dataService.OnBeforeRelease then
		dataService:OnBeforeRelease(function(player : Player)
			self:Flush(player)
			self.Pending[player] = nil
		end, RELEASE_ORDER)
	end

	Players.PlayerRemoving:Connect(function(player : Player)
		task.defer(function()
			self.Pending[player] = nil
		end)
	end)

	Framework:Listen("ClaimContract", function(player : Player, kind : any, index : any)
		local ok, reason = self:Claim(player, kind, index)
		Framework:Fire("ContractClaimResult", player, kind, index, ok, reason)
	end)

	task.spawn(function()
		while true do
			task.wait(FLUSH_INTERVAL)

			for _, player in Players:GetPlayers() do
				if self:_profileOf(player) then
					self:_tick(player)
				end
			end
		end
	end)
end

function ContractService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service, false, true)
	end

	self:construct()
end

function ContractService:init()
	-- So o servidor dispara este; sem o Listen vazio o cliente ficaria dez segundos
	-- esperando o identificador (ver o README da raiz).
	Framework:Listen("ContractClaimResult", function() end)
end

return ContractService
