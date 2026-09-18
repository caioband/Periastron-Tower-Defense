local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Players = game:GetService("Players")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")
local ServerConfigs = ServerScriptService:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)
local ServerConfig = require(ServerConfigs)

local Me = require(Vendor.Me)
local Signal = require(Packages.Signal)

local CrateConfig = SharedConfig.CrateConfig
local RarityConfig = SharedConfig.RarityConfig
local GamepassConfig = SharedConfig.GamepassConfig

local RANDOM = Random.new()

local TutorialConfig = SharedConfig.TutorialConfig
local UnitStats = SharedConfig.UnitStats

local Framework = Me.new()

local CrateService = {
	Services = {
		DataService = {},
		IndexService = {},
		ContractService = {},
	},

	Signals = {
		-- (Player, rarity : string, amount : number, delta : number)
		CrateAmountChanged = Signal.new(),
	},
}

local function clampAmount(amount : number?) : number
	if typeof(amount) ~= "number" or amount ~= amount then
		return 0
	end

	return math.clamp(math.floor(amount), 0, CrateConfig.MAX_CRATES_PER_RARITY)
end

--[=[
	Reads the crates of a player straight from the loaded profile.
	Returns nil when the profile is not loaded yet -- use :GetCrates for the async version.
]=]
function CrateService:PeekCrates(Player : Player) : { [string]: number }?
	local profiles = self.Services.DataService.Profiles
	local profile = profiles and profiles[Player]
	if not profile then
		return nil
	end

	local inventory = profile.Profile.Data.Inventory
	return inventory and inventory.Crates or nil
end

--[=[
	Async read that waits for the profile to be loaded.
]=]
function CrateService:GetCrates(Player : Player, callbackFunc : ({ [string]: number }) -> ())
	self.Services.DataService:Get(Player, function(data)
		data.Inventory = data.Inventory or {}
		data.Inventory.Crates = data.Inventory.Crates or CrateConfig.createEmptyCrates()

		callbackFunc(data.Inventory.Crates)
	end)
end

--[=[
	Sets the crate amount of a single rarity to an absolute value.
	Returns the applied amount, or nil when it failed (bad rarity / profile not loaded).
]=]
function CrateService:SetCrates(Player : Player, rarity : string, amount : number) : number?
	local resolvedRarity = CrateConfig.resolveRarity(rarity)
	if not resolvedRarity then
		warn(string.format("[CrateService]: %q is not a valid crate rarity.", tostring(rarity)))
		return nil
	end

	local DataService = self.Services.DataService
	if not DataService.Update then
		warn("[CrateService]: DataService is not ready yet, ignoring crate change.")
		return nil
	end

	local targetAmount = clampAmount(amount)
	local previousAmount

	local inventory = DataService:Update(Player, "Inventory", function(currentInventory)
		currentInventory = currentInventory or {}
		currentInventory.Crates = currentInventory.Crates or CrateConfig.createEmptyCrates()

		previousAmount = currentInventory.Crates[resolvedRarity] or 0
		currentInventory.Crates[resolvedRarity] = targetAmount

		return currentInventory
	end)

	if not inventory then
		return nil
	end

	self.Signals.CrateAmountChanged:Fire(Player, resolvedRarity, targetAmount, targetAmount - previousAmount)
	return targetAmount
end

--[=[
	Adds (or removes, with a negative amount) crates of a rarity.
	Returns the resulting amount, or nil when it failed.
]=]
function CrateService:GiveCrates(Player : Player, rarity : string, amount : number?) : number?
	local resolvedRarity = CrateConfig.resolveRarity(rarity)
	if not resolvedRarity then
		warn(string.format("[CrateService]: %q is not a valid crate rarity.", tostring(rarity)))
		return nil
	end

	local delta = typeof(amount) == "number" and math.floor(amount) or 1
	local crates = self:PeekCrates(Player)
	local currentAmount = crates and crates[resolvedRarity] or 0

	return self:SetCrates(Player, resolvedRarity, currentAmount + delta)
end

--[=[
	Rolls the upgrade chain of a crate and returns the crate whose pool applies, plus
	every step it went through (empty when it did not evolve).

	The client replays that list one spin per step, so the order matters.
	Bounded by the number of tiers so a config with a loop in it cannot hang us.
]=]
function CrateService:_rollCrateUpgrade(crateRarity : string) : (string, { string })
	local CrateOdds = ServerConfig.Crate

	local current = crateRarity
	local upgrades = {}

	for _ = 1, #RarityConfig.ORDER do
		local upgrade = CrateOdds.UPGRADES[current]
		if not upgrade or RANDOM:NextNumber(0, 100) >= upgrade.Chance then
			break
		end

		current = upgrade.To
		table.insert(upgrades, current)

		if not CrateOdds.CHAIN_UPGRADES then
			break
		end
	end

	return current, upgrades
end

--[=[
	Rolls a unit rarity out of a crate's pool. Returns nil when the crate has no pool.

	`profile` e o perfil de quem abriu, e ele so serve para a sorte: a gamepass
	`+30% Luck` multiplica o peso das raridades de Epic para cima (ver
	`GamepassConfig.LUCK_MIN_RARITY`). Sem perfil -- ou sem a pass -- o multiplicador
	e 1 e a conta sai exatamente como saia antes.

	**A sorte levanta as de cima e nao mexe nas de baixo**, e isso ja basta: o sorteio
	normaliza pela soma dos pesos, entao subir Epic+ empurra Common e Rare para baixo
	sozinho. Mexer nos dois lados seria dois numeros para manter em sincronia.

	Ela tambem nao passa a chance publicada para tras: o `GetDisplayOdds` da loja
	continua sendo o pool cru, que e o que o jogador **sem** pass recebe. Uma pass que
	melhora o que ela promete nao torna o numero da loja mentira.
]=]
--[=[
	Marca a próxima caixa deste jogador com uma raridade.

	É de uso único e não é acumulável: marcar duas vezes continua valendo para uma
	caixa só. Vale enquanto ele estiver no servidor — não é gravada no perfil,
	porque ela é de um passo de tutorial e não de uma promessa do jogo.
]=]
function CrateService:ForceRarity(Player : Player, rarity : string)
	local resolved = RarityConfig.resolveRarity and RarityConfig.resolveRarity(rarity) or rarity
	if not resolved then return end

	self.ForcedRarity = self.ForcedRarity or {}
	self.ForcedRarity[Player.UserId] = resolved

	print(`[CrateService]: proxima caixa de {Player.Name} vem {resolved} (tutorial).`)
end

--[=[
	Lê e apaga a marca da próxima caixa, se houver.
]=]
function CrateService:ConsumeForcedRarity(Player : Player) : string?
	local forced = self.ForcedRarity and self.ForcedRarity[Player.UserId]

	if forced and self.ForcedRarity then
		self.ForcedRarity[Player.UserId] = nil
	end

	return forced
end

--[=[
	A garantia de quem está começando: dentro das primeiras caixas da vida do
	perfil, uma sai Epic ou melhor.

	A conta é o `Stats.BoxesOpened`, que já existe e já conta abertura de verdade —
	nenhuma chave nova. A garantia só entra na **última** das primeiras caixas
	(a terceira, hoje) e só se nenhuma Epic tiver saído antes: quem teve sorte na
	primeira não gasta a garantia, e quem não teve sai das três com uma.
]=]
function CrateService:_guaranteedRarity(profile : any) : string?
	local guarantee = TutorialConfig.CrateGuarantee
	if not guarantee then
		return nil
	end

	local stats = typeof(profile) == "table" and profile.Stats or nil
	local opened = (typeof(stats) == "table" and tonumber(stats.BoxesOpened)) or 0

	-- Esta abertura é a de número `opened + 1`.
	if opened + 1 ~= guarantee.Crates then
		return nil
	end

	local units = typeof(profile) == "table" and profile.Units or nil
	if typeof(units) == "table" then
		local floor = table.find(RarityConfig.ORDER, guarantee.Rarity)

		for unitName in units do
			local rarity = UnitStats[unitName] and UnitStats[unitName].Rarity
			local index = rarity and table.find(RarityConfig.ORDER, rarity)

			if index and floor and index >= floor then
				return nil
			end
		end
	end

	return guarantee.Rarity
end

function CrateService:_rollRarity(crateRarity : string, profile : any) : string?
	local guaranteed = self:_guaranteedRarity(profile)
	if guaranteed then
		print(`[CrateService]: garantia de inicio: {guaranteed} nesta abertura.`)

		return guaranteed
	end

	local pool = ServerConfig.Crate.POOLS[crateRarity]
	if not pool then
		warn(string.format("[CrateService]: crate %q has no pool in ServerConfig.Crate.", tostring(crateRarity)))
		return nil
	end

	local luck = GamepassConfig.luckMultiplier(profile)

	local function weightOf(rarity : string) : number
		local weight = pool[rarity] or 0

		if GamepassConfig.isLuckyRarity(rarity) then
			return weight * luck
		end

		return weight
	end

	local total = 0
	for _, rarity in RarityConfig.ORDER do
		total += weightOf(rarity)
	end

	if total <= 0 then
		return nil
	end

	local roll = RANDOM:NextNumber(0, total)
	local cumulative = 0

	for _, rarity in RarityConfig.ORDER do
		cumulative += weightOf(rarity)
		if roll < cumulative then
			return rarity
		end
	end

	return RarityConfig.ORDER[1]
end

--[=[
	As units de um tier que uma caixa pode realmente entregar.

	`RarityConfig.getUnitsOfRarity` continua sendo a lista honesta do tier -- é ela que
	a carta, o deck e o balanceamento leem. O drop é que é menor: `EXCLUDED_UNITS`
	tira daqui quem existe no jogo mas não sai mais de caixa (ver ServerConfig.Crate).
]=]
local function unboxableUnitsOfRarity(rarity : string) : { string }
	local excluded = ServerConfig.Crate.EXCLUDED_UNITS or {}
	local units = {}

	for _, unitName in RarityConfig.getUnitsOfRarity(rarity) do
		if not excluded[unitName] then
			table.insert(units, unitName)
		end
	end

	return units
end

--[=[
	Picks the unit the player actually gets, among the units of that rarity a crate
	can still give.

	A tier with nothing left to give -- porque nenhuma unit foi marcada com ele
	(Cosmic, as it stands) ou porque as que havia estão fora do drop -- walks down to
	the closest tier that has one, so a roll never comes back empty-handed.
]=]
function CrateService:_rollUnit(rarity : string) : (string?, string?)
	local currentRarity : string? = rarity

	while currentRarity do
		local units = unboxableUnitsOfRarity(currentRarity)
		if #units > 0 then
			if currentRarity ~= rarity then
				warn(string.format(
					"[CrateService]: no unit of rarity %q can drop from a crate, dropping a %s one instead.",
					rarity,
					currentRarity
				))
			end

			return units[RANDOM:NextInteger(1, #units)], currentRarity
		end

		currentRarity = RarityConfig.getLowerRarity(currentRarity)
	end

	warn("[CrateService]: no unit is left in the crate pool at any rarity.")
	return nil, nil
end

--[=[
	A raridade que esta garantida na proxima abertura desta caixa, ou nil.

	Le as contas do `Pity` do perfil contra o limite de cada raridade
	(`Crate.GetPityThreshold`), na ordem de `Crate.PITY_RARITIES`: se Cosmic e
	Legendary venceram juntas, sai Cosmic agora e a Legendary continua vencida para a
	abertura seguinte.
]=]
function CrateService:_dueRarity(crateRarity : string, profile : any) : string?
	local CrateOdds = ServerConfig.Crate
	local counters = profile and profile.Pity and profile.Pity[crateRarity]
	if typeof(counters) ~= "table" then
		return nil
	end

	for _, rarity in CrateOdds.PITY_RARITIES do
		local threshold = CrateOdds.GetPityThreshold(crateRarity, rarity)
		if threshold and (tonumber(counters[rarity]) or 0) >= threshold then
			return rarity
		end
	end

	return nil
end

--[=[
	Atualiza as contas da garantia depois de uma abertura: zera a da raridade que saiu
	e soma um nas outras.

	`gotRarity` e a raridade da unit que o jogador de fato recebeu -- a mesma do
	resultado --, e nao a sorteada: um tier sem unit nenhuma desce um degrau no
	`_rollUnit`, e essa abertura nao entregou o tier de cima.

	Caixa sem chance de uma raridade nao guarda conta dela: nao ha limite, e um
	numero crescendo para sempre no perfil nao serviria para nada.
]=]
function CrateService:_recordPity(Player : Player, crateRarity : string, gotRarity : string?)
	local CrateOdds = ServerConfig.Crate

	self.Services.DataService:Update(Player, "Pity", function(pity)
		pity = typeof(pity) == "table" and pity or {}

		local counters = typeof(pity[crateRarity]) == "table" and pity[crateRarity] or {}

		for _, rarity in CrateOdds.PITY_RARITIES do
			if not CrateOdds.GetPityThreshold(crateRarity, rarity) then
				counters[rarity] = nil
			elseif gotRarity == rarity then
				counters[rarity] = 0
			else
				counters[rarity] = (tonumber(counters[rarity]) or 0) + 1
			end
		end

		pity[crateRarity] = counters
		return pity
	end)
end

export type UnboxingResult = {
	-- The crate the player opened.
	Crate : string,
	-- Every crate it evolved into, in order. Empty when it did not.
	Upgrades : { string },
	Rarity : string,
	Unit : string?,
}

--[=[
	Runs a crate opening end to end: upgrade chain, rarity out of the resulting pool,
	then a unit of that rarity. Pure roll -- nothing is written or sent.

	`profile` e de quem esta abrindo, e so a sorte o le (ver `_rollRarity`). Sem ele o
	sorteio e o do jogador sem gamepass nenhuma -- e o que faz o `unbox` do Cmdr rolar
	a caixa "de fabrica" quando ninguem passa um perfil.

	`forcedRarity` e a garantia (ver `_dueRarity`): vindo, ela passa por cima do
	sorteio da raridade. A evolucao continua rolando -- o carretel mostra a caixa
	evoluindo do mesmo jeito --, so a raridade entregue e que ja estava decidida.
]=]
function CrateService:RollCrate(rarity : string, profile : any, forcedRarity : string?) : UnboxingResult?
	local resolvedRarity = CrateConfig.resolveRarity(rarity)
	if not resolvedRarity then
		warn(string.format("[CrateService]: %q is not a valid crate rarity.", tostring(rarity)))
		return nil
	end

	local poolCrate, upgrades = self:_rollCrateUpgrade(resolvedRarity)

	local rolledRarity = forcedRarity or self:_rollRarity(poolCrate, profile)
	if not rolledRarity then
		return nil
	end

	-- The unit may come from a lower tier when the rolled one has no unit yet, and the
	-- result reports the tier the player actually got.
	local unit, unitRarity = self:_rollUnit(rolledRarity)

	return {
		Crate = resolvedRarity,
		Upgrades = upgrades,
		Rarity = unitRarity or rolledRarity,
		Unit = unit,
	}
end

--[=[
	O perfil aberto do jogador, ou nil enquanto ele nao carregou.

	Quem le e a sorte do sorteio: sem perfil a caixa rola sem gamepass, que e o pior
	caso para o jogador e o unico seguro para o jogo -- inventar uma pass que ele
	talvez nao tenha e dar o beneficio de graca.
]=]
function CrateService:_profileOf(Player : Player) : any
	local DataService = self.Services.DataService
	local profiles = DataService and DataService.Profiles
	local entry = profiles and profiles[Player]

	return entry and entry.Profile.Data or nil
end

--[=[
	Manda a abertura para o lobby inteiro, e não só para quem abriu.

	`Owner` viaja junto porque é dele o personagem na frente do qual a caixa nasce, em
	todas as telas -- e é o que separa quem abriu de quem está só assistindo: só a tela
	do dono mostra o carretel e o nome da unidade, o resto vê a caixa e o prêmio.

	Um `Fire` por jogador é como o resto do projeto transmite (`MobService`): o `Me`
	só expõe o envio para um cliente de cada vez.
]=]
function CrateService:_broadcastUnboxing(Owner : Player, result : UnboxingResult)
	for _, player in Players:GetPlayers() do
		Framework:Fire("PlayUnboxing", player, result, Owner)
	end
end

--[=[
	Rolls a crate and plays the unboxing on every client (crate model in front of
	`Player` + the reel above it landing on the rolled rarity).

	It does NOT spend the crate and does NOT give the unit -- it is the "show me" entry
	point, used by the cmdr command. :OpenCrate is the one the player drives.
]=]
function CrateService:PlayUnboxing(Player : Player, rarity : string) : UnboxingResult?
	local result = self:RollCrate(rarity, self:_profileOf(Player))
	if not result then
		return nil
	end

	self:_broadcastUnboxing(Player, result)
	return result
end

--[=[
	Opens one crate the player owns: spends it, rolls it, gives the unit and plays the
	unboxing. Returns nil when the player owns none of that rarity.

	The check and the decrement happen inside a single :Update callback, which does not
	yield -- two clicks landing back to back cannot both spend the same last crate.
]=]
function CrateService:OpenCrate(Player : Player, rarity : string) : UnboxingResult?
	local resolvedRarity = CrateConfig.resolveRarity(rarity)
	if not resolvedRarity then
		warn(string.format("[CrateService]: %q is not a valid crate rarity.", tostring(rarity)))
		return nil
	end

	local DataService = self.Services.DataService
	if not DataService.Update then
		warn("[CrateService]: DataService is not ready yet, ignoring crate opening.")
		return nil
	end

	local spent = false
	local remaining = 0

	DataService:Update(Player, "Inventory", function(currentInventory)
		currentInventory = currentInventory or {}
		currentInventory.Crates = currentInventory.Crates or CrateConfig.createEmptyCrates()

		local owned = currentInventory.Crates[resolvedRarity] or 0
		if owned <= 0 then
			return currentInventory
		end

		remaining = owned - 1
		currentInventory.Crates[resolvedRarity] = remaining
		spent = true

		return currentInventory
	end)

	if not spent then
		return nil
	end

	self.Signals.CrateAmountChanged:Fire(Player, resolvedRarity, remaining, -1)

	--[[
		A garantia: se alguma raridade venceu a conta desta caixa, ela ja esta decidida
		antes do sorteio (`_dueRarity`). As contas so andam depois de o roll dar certo:
		abertura que falhou devolve a caixa e nao conta.

		Nada entre ler as contas e escreve-las cede a thread, entao dois cliques
		seguidos nao leem a mesma conta antes de ela andar.
	]]
	local profile = self:_profileOf(Player)

	--[[
		A raridade que o tutorial deixou marcada para a próxima caixa deste jogador
		passa na frente da garantia normal, e é **consumida** aqui: uma marca, uma
		caixa. Quem a põe é o `TutorialService`, no servidor, quando abre o passo do
		lobby — o cliente não pede raridade nenhuma, e por isso não há o que forjar.
	]]
	local dueRarity = self:ConsumeForcedRarity(Player) or self:_dueRarity(resolvedRarity, profile)

	local result = self:RollCrate(resolvedRarity, profile, dueRarity)
	if not result then
		-- The roll is what failed, so hand the crate back instead of eating it.
		self:GiveCrates(Player, resolvedRarity, 1)
		return nil
	end

	self:_recordPity(Player, resolvedRarity, result.Rarity)

	-- A MOST BOXES OPENED conta daqui: so a caixa gasta e rolada de verdade. O
	-- `PlayUnboxing` (o `unbox` do Cmdr) nao passa por aqui e nao conta.
	DataService:Update(Player, "Stats", function(stats)
		stats.BoxesOpened = (tonumber(stats.BoxesOpened) or 0) + 1
		return stats
	end)

	if result.Unit then
		DataService:Update(Player, "Units", function(units)
			units = units or {}
			units[result.Unit] = (units[result.Unit] or 0) + 1
			return units
		end)

		-- Obter e o gatilho do Index: a unit entra no catalogo na primeira copia, e
		-- fica la mesmo que ele venda todas depois.
		local IndexService = self.Services.IndexService
		if IndexService then
			IndexService:UnlockUnit(Player, result.Unit)
		end

		-- "Unbox 2 Legendary Cards": a raridade e a da unidade que saiu, de qualquer
		-- caixa. O summon nao passa por aqui e nao conta.
		local ContractService = self.Services.ContractService
		if ContractService then
			ContractService:Record(Player, SharedConfig.ContractConfig.Events.Unbox, 1, { Rarity = result.Rarity })
		end
	end

	self:_broadcastUnboxing(Player, result)
	return result
end

function CrateService:construct()
	Framework:Listen("RequestOpenCrate", function(Player : Player, rarity : string)
		self:OpenCrate(Player, rarity)
	end)
end

function CrateService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service, false, true)
	end

	self:construct()
end

function CrateService:init()
	-- The client connects to "PlayUnboxing" during its own init, but the server would
	-- only create the event when it first fires it -- and Warp complains that it "is
	-- taking too long to retrieve". Declared here like the other server-only events.
	Framework:Listen("PlayUnboxing", function() end)
end

return CrateService
