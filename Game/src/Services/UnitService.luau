local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")
local ServerConfigs = ServerScriptService:WaitForChild("Config")
local Assets = Shared:WaitForChild("Assets")
local Units = Assets:WaitForChild("Units")

local SharedConfig = require(Configs.SharedConfig)
local TargetPriority = SharedConfig.TargetPriority
local DeckConfig = SharedConfig.DeckConfig
local ServerConfig = require(ServerConfigs)
local PathUtil = require(Shared:WaitForChild("Util"):WaitForChild("PathUtil"))
local PlacementUtil = require(Shared:WaitForChild("Util"):WaitForChild("PlacementUtil"))
local GameClock = require(Shared:WaitForChild("Util"):WaitForChild("GameClock"))

local Warp = require(Vendor.Warp)
local Me = require(Vendor.Me)

local Framework = Me.new()

local TARGET_SCANS_PER_FRAME = 8

-- Um efeito de dinheiro por unidade a cada tanto. Ver `playAuraVFX`.
local AURA_VFX_COOLDOWN = 0.35

local MAX_PLACE_DISTANCE = 2048

-- O total de dano por unidade so alimenta um label do card de upgrade, entao vai
-- em lote algumas vezes por segundo em vez de um evento por golpe.
local DAMAGE_FLUSH_INTERVAL = 0.25

-- Log de posicionamento: so no Studio, para nao poluir o console de producao.
local IS_STUDIO = RunService:IsStudio()

local function placementPrint(...)
	if not IS_STUDIO then return end
	print("[UnitService/Place]", ...)
end

local function formatVector(v : Vector3?)
	if not v then return "nil" end
	return string.format("(%.2f, %.2f, %.2f)", v.X, v.Y, v.Z)
end

local UnitService = {
	Services = {
		MobService = {},
		DataService = {},
		WaveService = {},
		WeatherService = {}
	},
	PlacedUnits = {},
	UnitsById = {},
	UnitSizes = {},
	UnitBounds = {},
	SessionCards = {},
	SessionCardMax = {},
	DamageDirty = {},
	LastDamageFlush = 0,

	-- As farms com aura que estao no mapa. Refeita todo quadro no `stepCombat`.
	AuraSources = {},
}

for _, model in Units:GetChildren() do
	local _, size = model:GetBoundingBox()
	UnitService.UnitSizes[model.Name] = size.X
	UnitService.UnitBounds[model.Name] = size
end

function UnitService:getCardCount(player, unitName)
	local cards = self.SessionCards[player.UserId]
	if not cards then return 0 end
	return cards[unitName] or 0
end

function UnitService:setCardCount(player, unitName, count)
	local cards = self.SessionCards[player.UserId]
	if not cards then return end
	cards[unitName] = count
	Framework:Fire("UpdateCardCounts", player, unitName, count)
end

function UnitService:decrementCardCount(player, unitName)
	local current = self:getCardCount(player, unitName)
	self:setCardCount(player, unitName, math.max(0, current - 1))
end

function UnitService:incrementCardCount(player, unitName)
	local current = self:getCardCount(player, unitName)
	local maxCards = self.SessionCardMax[player.UserId]
	local cap = maxCards and maxCards[unitName] or current
	self:setCardCount(player, unitName, math.min(cap, current + 1))
end

--[=[
	As cartas que o jogador leva para a partida saem do **deck** que ele montou no
	lobby (`EquippedUnits`), e nao do inventario inteiro: so entra unidade que esta
	num slot, e a quantidade de cada uma e o `Amount` daquele slot.

	Quem nunca montou deck recebe um automatico (`DeckConfig.resolve`), montado a
	partir do que ele tem — sem isso ele entraria na partida sem carta nenhuma, e o
	`getCardCount` recusaria toda colocacao.

	O cliente monta a hotbar a partir do mesmo perfil e das mesmas funcoes, entao os
	dois chegam ao mesmo deck sem precisar de evento novo.
]=]
function UnitService:initPlayerCards(player)
	self.Services.DataService:Get(player, function(profileData)
		local deck = DeckConfig.resolve(profileData)

		local cards = {}
		local cardMax = {}

		for unitName, amount in DeckConfig.tally(deck) do
			cards[unitName] = amount
			cardMax[unitName] = amount
		end

		self.SessionCards[player.UserId] = cards
		self.SessionCardMax[player.UserId] = cardMax

		for unitName, count in cards do
			Framework:Fire("UpdateCardCounts", player, unitName, count)
		end
	end)
end

--[=[
	Devolve o service ao estado de antes da partida: derruba tudo que foi colocado
	no mapa e recarrega as cartas de cada jogador a partir do perfil.

	Cada unidade sai por `RemoveUnit`, o mesmo evento da venda — entao os clientes
	limpam modelo, linha pontilhada, minas e selecao pelo caminho que ja existe.
]=]
function UnitService:ResetRound()
	for _, entry in ipairs(self.PlacedUnits) do
		for _, player in ipairs(Players:GetPlayers()) do
			Framework:Fire("RemoveUnit", player, entry.unitId)
		end
	end

	table.clear(self.PlacedUnits)
	table.clear(self.UnitsById)
	table.clear(self.DamageDirty)

	-- O mapa pode ter mudado entre rounds.
	self.GridParts = nil

	for _, player in ipairs(Players:GetPlayers()) do
		self:initPlayerCards(player)
	end
end

--[=[
	Parts do caminho do mapa em jogo.

	No servidor `GetTagged("Grid")` devolve tambem as parts dos mapas guardados em
	`ServerStorage.Maps` — sao 585 hoje, de seis mapas, contra a centena do mapa
	carregado. Elas nunca poderiam ser atingidas por um `GetPartsInPart` (nao estao
	no Workspace), entao o resultado da validacao nao muda; o que muda e nao montar
	uma lista de 585 entradas a cada tentativa de colocar uma unidade.

	O cache cai no ResetRound, junto com a possibilidade de o mapa ter mudado.
]=]
function UnitService:getGridParts()
	if self.GridParts then
		return self.GridParts
	end

	local mapRoot = workspace:FindFirstChild("Map")

	local parts = {}
	for _, part in CollectionService:GetTagged("Grid") do
		if part:IsA("BasePart") and part:IsDescendantOf(mapRoot or workspace) then
			table.insert(parts, part)
		end
	end

	-- Sem o mapa no Workspace a lista pode estar incompleta; nao guarda.
	if mapRoot then
		self.GridParts = parts
	end

	return parts
end

--[=[
	Credita dano a uma unidade. O valor e o que de fato entrou no mob (`DamageMob`
	devolve isso), nao o dano cheio do golpe — assim o `DmgDone` do card fecha com
	a vida que os mobs perderam.
]=]
function UnitService:addDamageDone(entry, amount)
	if not entry or not amount or amount <= 0 then return end

	entry.damageDone = (entry.damageDone or 0) + amount
	self.DamageDirty[entry.unitId] = true
end

--[=[
	Mapa unitId -> dano total, de todas as unidades no mapa. Vai junto do
	`ClientReady`, para quem entra no meio da partida ver o total de quem ja parou
	de atirar (o flush em lote so manda quem mudou desde o ultimo envio).
]=]
function UnitService:getDamageSnapshot()
	local snapshot = {}
	for _, entry in ipairs(self.PlacedUnits) do
		if (entry.damageDone or 0) > 0 then
			snapshot[entry.unitId] = entry.damageDone
		end
	end
	return snapshot
end

function UnitService:flushDamageDone()
	if next(self.DamageDirty) == nil then return end

	local batch = {}
	local hasEntries = false
	for unitId in self.DamageDirty do
		local entry = self.UnitsById[unitId]
		if entry then
			batch[unitId] = entry.damageDone or 0
			hasEntries = true
		end
	end
	table.clear(self.DamageDirty)

	if not hasEntries then return end

	for _, plr in ipairs(Players:GetPlayers()) do
		Framework:Fire("UnitDamageStats", plr, batch)
	end
end

--[[ CLIMA ]]

--[=[
	O clima no ar, lido do `WeatherService` a cada quadro de combate.

	Vem de la e nao do `WeatherRoundService` de proposito: o que interessa ao
	combate e o que esta no ceu, tenha entrado pelo round ou pelo comando `weather`
	— testar um clima na mao tem que produzir exatamente a partida que o round
	produziria.
]=]
function UnitService:GetWeather() : string?
	local weatherService = self.Services.WeatherService
	return weatherService and weatherService:GetCurrent() or nil
end

--[=[
	Multiplicador temporario de uma unidade (`Damage` ou `AttackSpeed`).

	Hoje so o raio do trovao carrega uma unidade `Electric`, mas o campo e generico:
	qualquer coisa que precise de um buff com prazo escreve `entry.Charge` e o
	combate ja o respeita.
]=]
function UnitService:chargeMultiplier(entry, stat : string, now : number) : number
	local charge = entry.Charge
	if not charge then return 1 end

	if now >= charge.expiresAt then
		entry.Charge = nil
		return 1
	end

	return charge[stat] or 1
end

--[=[
	Da a uma unidade um buff com prazo. Recarregar antes de acabar renova o prazo
	em vez de empilhar: dois raios seguidos na mesma unidade dao 10s de buff a
	partir do segundo, nao 50% em cima de 50%.
]=]
function UnitService:ChargeUnit(entry, damage : number?, attackSpeed : number?, duration : number)
	if not entry then return end

	entry.Charge = {
		Damage = damage or 1,
		AttackSpeed = attackSpeed or 1,
		expiresAt = GameClock.Now() + (duration or 0),
	}

	for _, plr in ipairs(Players:GetPlayers()) do
		Framework:Fire("UnitCharged", plr, entry.unitId, duration or 0)
	end
end

--[=[
	Atordoa uma unidade. O prazo maior manda — um chain de 5s nao pode encurtar um
	atordoamento de 20s que ja estava correndo.

	`source` e o clima que causou o atordoamento, e viaja junto para o cliente:
	parar de atacar e sempre o mesmo realce amarelo, mas o congelamento da neve tem
	VFX proprio (`Effects.Snow.Freeze.Asset`) e o raio nao. Sem `source` — o gimmick
	de mob — o cliente so desenha o realce.
]=]
function UnitService:StunUnit(entry, duration : number, source : string?)
	if not entry then return end

	local until_ = GameClock.Now() + (duration or 0)
	if (entry.StunnedUntil or 0) >= until_ then return end

	entry.StunnedUntil = until_

	for _, plr in ipairs(Players:GetPlayers()) do
		Framework:Fire("UnitStunned", plr, entry.unitId, duration or 0, source)
	end
end

--[=[
	As unidades que o clima pode atordoar.

	Quem e imune ao clima (Magic, nos climas de hoje) fica de fora — nao adianta
	sortear entre elas e depois desistir, porque isso desperdicaria o sorteio e
	faria o congelamento da neve falhar em silencio num mapa cheio de Magic.

	Sem `weatherName` devolve todas: e o caso do gimmick de mob, que atordoa sem ter
	nada a ver com clima.
]=]
function UnitService:GetStunnableUnits(weatherName : string?)
	if not weatherName then
		return self.PlacedUnits
	end

	local candidates = {}
	for _, entry in ipairs(self.PlacedUnits) do
		if not SharedConfig.WeatherConfig.IsImmune(weatherName, entry.unitName) then
			table.insert(candidates, entry)
		end
	end

	return candidates
end

--[=[
	Atordoa uma unidade sorteada. `weatherName` restringe o sorteio a quem nao e
	imune aquele clima.
]=]
function UnitService:StunRandomUnit(duration, weatherName : string?)
	local candidates = self:GetStunnableUnits(weatherName)
	if #candidates == 0 then return nil end

	local entry = candidates[math.random(1, #candidates)]
	self:StunUnit(entry, duration or 0, weatherName)

	return entry
end

function UnitService:construct()
	Framework:Listen("ReplicateUnit", function() end)
	Framework:Listen("RemoveUnit", function() end)
	Framework:Listen("UnitStunned", function() end)
	Framework:Listen("UnitCharged", function() end)
	Framework:Listen("UpdateCardCounts", function() end)
	Framework:Listen("RequestCardCounts", function(player)
		local cards = self.SessionCards[player.UserId]
		if not cards then return end
		for unitName, count in cards do
			Framework:Fire("UpdateCardCounts", player, unitName, count)
		end
	end)

	Framework:Listen("UnitUpgraded", function() end)
	Framework:Listen("UnitPriorityChanged", function() end)
	Framework:Listen("UnitDamageStats", function() end)
	Framework:Listen("UnitSwing", function() end)
	Framework:Listen("TripmineThrown", function() end)
	Framework:Listen("TripmineTriggered", function() end)
	Framework:Listen("FarmPayout", function() end)
	Framework:Listen("AuraBonusVFX", function() end)

	Framework:Listen("SellUnit", function(player, unitId)
		local foundIndex = nil
		for i, entry in ipairs(self.PlacedUnits) do
			if entry.unitId == unitId and entry.ownerUserId == player.UserId then
				foundIndex = i
				break
			end
		end

		if not foundIndex then return end

		local entry = self.PlacedUnits[foundIndex]
		table.remove(self.PlacedUnits, foundIndex)
		self.UnitsById[entry.unitId] = nil

		local refund = math.floor((entry.invested or 0) * SharedConfig.SellRefundRatio)

		for _, plr in ipairs(Players:GetPlayers()) do
			Framework:Fire("RemoveUnit", plr, entry.unitId)
		end

		self.Services.MobService:addCash(player, refund)
		self:incrementCardCount(player, entry.unitName)
	end)

	Framework:Listen("UpgradeUnit", function(player, unitId)
		local entry = self.UnitsById[unitId]
		if not entry or entry.ownerUserId ~= player.UserId then return end

		local currentLevel = entry.upgrades or 0
		if SharedConfig.UnitUpgradeConfig:IsMaxed(currentLevel) then return end

		local cost = SharedConfig.UnitUpgradeConfig:GetCost(entry.unitName, currentLevel)
		local currentCash = self.Services.MobService:getCash(player)
		if currentCash < cost then return end

		entry.upgrades = currentLevel + 1
		entry.invested = (entry.invested or 0) + cost
		self.Services.MobService:spendCash(player, cost)

		for _, plr in ipairs(Players:GetPlayers()) do
			Framework:Fire("UnitUpgraded", plr, unitId, entry.upgrades)
		end
	end)

	--[=[
		Troca a prioridade de alvo de uma unidade. O cliente manda o modo que quer
		(e nao "gira um") para o pedido nao depender de quem esta em dia com quem:
		dois cliques rapidos chegam como dois modos, e o segundo manda.
	]=]
	Framework:Listen("SetUnitPriority", function(player, unitId, priority)
		local entry = self.UnitsById[unitId]
		if not entry or entry.ownerUserId ~= player.UserId then return end
		if not TargetPriority.Exists(priority) then return end
		if entry.priority == priority then return end

		entry.priority = priority

		-- O alvo atual cai junto: sem isso a unidade so obedeceria a prioridade
		-- nova depois de o mob de agora sair do alcance.
		entry.targetMobId = nil

		for _, plr in ipairs(Players:GetPlayers()) do
			Framework:Fire("UnitPriorityChanged", plr, unitId, priority)
		end
	end)

	self.PlayersReady = {}
	Framework:Listen("ClientReady", function(player)
		self.PlayersReady[player.UserId] = true
		for _, entry in self.PlacedUnits do
			Framework:Fire("ReplicateUnit", player, entry.unitName, entry.cf, entry.ownerUserId, entry.unitId, entry.upgrades or 0, entry.priority)
		end
		local cards = self.SessionCards[player.UserId]
		if cards then
			for unitName, count in cards do
				Framework:Fire("UpdateCardCounts", player, unitName, count)
			end
		end

		local damageSnapshot = self:getDamageSnapshot()
		if next(damageSnapshot) ~= nil then
			Framework:Fire("UnitDamageStats", player, damageSnapshot)
		end
	end)

	Framework:Listen("PlaceUnit", function(player, unitName, cf)
		if typeof(unitName) ~= "string" or typeof(cf) ~= "CFrame" then
			placementPrint(player.Name, "recusado: argumentos invalidos", typeof(unitName), typeof(cf))
			return
		end

		local position = cf.Position
		if position.X ~= position.X or position.Y ~= position.Y or position.Z ~= position.Z then
			placementPrint(player.Name, unitName, "recusado: posicao NaN")
			return
		end
		if position.Magnitude > MAX_PLACE_DISTANCE then
			placementPrint(player.Name, unitName, "recusado: longe demais", formatVector(position),
				string.format("magnitude %.2f > %d", position.Magnitude, MAX_PLACE_DISTANCE))
			return
		end

		local stats = SharedConfig.UnitStats[unitName]
		if not stats then
			placementPrint(player.Name, unitName, "recusado: unidade sem stats no SharedConfig")
			return
		end

		--[[
			O preco com o clima do momento: a chuva desconta 25% do Ice. Sai do
			`GetPlaceCost` porque o card da hotbar mostra pela mesma funcao -- sem isso
			o jogador veria um preco e pagaria outro.
		]]
		local placeCost = SharedConfig.UnitUpgradeConfig:GetPlaceCost(unitName, self:GetWeather())
		local cash = self.Services.MobService:getCash(player)
		if cash < placeCost then
			placementPrint(player.Name, unitName, "recusado: sem dinheiro",
				string.format("tem %d, custa %d", cash, placeCost))
			return
		end

		local cardCount = self:getCardCount(player, unitName)
		if cardCount <= 0 then
			placementPrint(player.Name, unitName, "recusado: sem unidades no card", "count", cardCount)
			return
		end

		local unitSizeX = self.UnitSizes[unitName] or 2
		local isValid = true

		--[[
			A caixa de teste tem que ser a mesma que o cliente usa para pintar o
			fantasma de verde: a bounding box real do modelo, girada pelo CFrame que
			ele mandou. Uma caixa maior (ex.: um cubo de 6 studs de altura) desce
			abaixo do chao e encosta nos trilhos finos do caminho, recusando
			posicionamentos que o cliente ja tinha aprovado.

			O `PathProbe` estica essa caixa para baixo: so o volume da unidade nao
			basta, porque qualquer coisa que a levante acima do trilho tira o caminho
			de dentro da caixa. Ver `PlacementUtil.PathClearance`.
		]]
		local checkSize = self.UnitBounds[unitName] or Vector3.new(unitSizeX, 2, unitSizeX)
		local probeCF, probeSize = PlacementUtil.PathProbe(cf, checkSize)
		local overlapParams = OverlapParams.new()
		overlapParams.FilterType = Enum.RaycastFilterType.Include
		overlapParams.FilterDescendantsInstances = self:getGridParts()
		local gridProbe = Instance.new("Part")
		gridProbe.Size = probeSize
		gridProbe.Anchored = true
		gridProbe.CanCollide = false
		gridProbe.CanQuery = false
		gridProbe.CanTouch = false
		gridProbe.Transparency = 1
		gridProbe.CFrame = probeCF
		gridProbe.Parent = workspace
		local gridParts = workspace:GetPartsInPart(gridProbe, overlapParams)
		gridProbe:Destroy()
		if #gridParts > 0 then
			isValid = false
			placementPrint(player.Name, unitName, "recusado: em cima do caminho", formatVector(position),
				"caixa de teste", formatVector(probeSize),
				string.format("%d part(s) de Grid, primeira: %s em %s", #gridParts, gridParts[1]:GetFullName(), formatVector(gridParts[1].Position)))
		end

		if isValid then
			for _, entry in ipairs(self.PlacedUnits) do
				local otherSizeX = self.UnitSizes[entry.unitName] or 2
				local minDist = (unitSizeX + otherSizeX) / 2
				local posA = Vector3.new(cf.Position.X, 0, cf.Position.Z)
				local posB = Vector3.new(entry.cf.Position.X, 0, entry.cf.Position.Z)
				local dist = (posA - posB).Magnitude
				if dist < minDist then
					isValid = false
					placementPrint(player.Name, unitName, "recusado: perto demais de outra unidade",
						formatVector(position), string.format("%s a %.2f studs (minimo %.2f)", entry.unitName, dist, minDist))
					break
				end
			end
		end

		--[[
			Ninguem nasce dentro de um jogador.

			E aqui que a regra vale de verdade: o cliente pinta o fantasma de vermelho
			para o jogador enxergar, mas quem aceita ou recusa e este listener -- um
			cliente adulterado manda o CFrame que quiser.
		]]
		if isValid then
			local blockingCharacter = PlacementUtil.FindBlockingCharacter(cf, checkSize)
			if blockingCharacter then
				isValid = false
				placementPrint(player.Name, unitName, "recusado: em cima de um personagem",
					formatVector(position), "personagem", blockingCharacter:GetFullName())
			end
		end

		if isValid then
			local unitId = HttpService:GenerateGUID(false)
			--[[
				`invested` e o preco de **tabela**, e nao o que foi cobrado.

				E dele que sai o valor de venda, e o cliente calcula o mesmo numero pelo
				`GetInvested` sem saber quanto esta unidade custou de fato -- o
				`invested` nao e replicado. Guardar o preco com desconto faria o card
				prometer uma devolucao e a venda dar outra. O desconto continua sendo so
				vantagem: comprar por 75 e vender por 50 nunca e lucro.
			]]
			local sticker = SharedConfig.UnitUpgradeConfig:GetPlaceCost(unitName)

			local newEntry = { unitId = unitId, unitName = unitName, cf = cf, ownerUserId = player.UserId, upgrades = 0, invested = sticker, lastAttack = 0, priority = TargetPriority.Default }
			table.insert(self.PlacedUnits, newEntry)
			self.UnitsById[unitId] = newEntry

			self.Services.MobService:spendCash(player, placeCost)
			self:decrementCardCount(player, unitName)

			placementPrint(player.Name, unitName, "aceito", "CFrame recebido do cliente:", formatVector(position),
				"unitId", unitId)

			for _, plr in ipairs(Players:GetPlayers()) do
				Framework:Fire("ReplicateUnit", plr, unitName, cf, player.UserId, unitId, 0, newEntry.priority)
			end
		end
	end)

	RunService.Heartbeat:Connect(function()
		self:stepCombat()

		local now = os.clock()
		if now - self.LastDamageFlush >= DAMAGE_FLUSH_INTERVAL then
			self.LastDamageFlush = now
			self:flushDamageDone()
		end
	end)
end

--[[ AURA DO ENTREPRENEUR ]]

--[=[
	As farms com aura que estao no mapa agora, remontadas uma vez por quadro.

	Refeita em vez de mantida na colocacao e na venda porque o `stepCombat` ja varre
	a lista inteira todo quadro: um segundo laco pelo mesmo array nao se mede, e em
	troca nao existe estado para invalidar quando uma unidade entra, sai, e vendida
	ou o round recomeca.
]=]
function UnitService:collectAuraSources()
	table.clear(self.AuraSources)

	for _, entry in ipairs(self.PlacedUnits) do
		local stats = SharedConfig.UnitStats[entry.unitName]
		local farm = stats and stats.Farm

		if farm and farm.Aura then
			table.insert(self.AuraSources, entry)
		end
	end
end

--[=[
	Quanto a mais em caixa uma unidade leva por estar na aura de uma farm.

	Devolve uma fracao somavel -- 0.15 e "+15%" -- e auras que se sobrepoem somam:
	duas farms cobrindo a mesma torre valem as duas. Zero quer dizer "fora de todas".

	O dono nao entra na conta: a aura vale para qualquer unidade aliada, e quem
	recebe o dinheiro continua sendo o dono da unidade que bateu.

	O raio de cada farm e o alcance dela pelo `GetRange`, ou seja, o mesmo circulo
	que o jogador ve quando a seleciona -- inclusive o que o clima faz com ele.
]=]
function UnitService:getAuraBonus(entry, weather : string?) : number
	local sources = self.AuraSources
	if #sources == 0 then return 0 end

	local position = entry.cf.Position
	local bonus = 0

	for _, source in ipairs(sources) do
		-- Uma farm nao se banha na propria aura; ela nem causa dano, mas deixar a
		-- regra escrita evita surpresa se um dia uma farm atacar.
		if source == entry then continue end

		local level = source.upgrades or 0
		local radius = SharedConfig.UnitUpgradeConfig:GetRange(source.unitName, level, weather)

		if (source.cf.Position - position).Magnitude <= radius then
			bonus += SharedConfig.UnitUpgradeConfig:GetAuraBonus(source.unitName, level)
		end
	end

	return bonus
end

--[=[
	O dinheirinho saindo da unidade que acabou de render a mais.

	Estrangulado por unidade: um MultiShot sao quatro golpes e um AOE e uma chamada
	de dano por inimigo atingido, entao sem isto um Rocket dentro da aura mandaria
	dez efeitos no mesmo quadro para a mesma torre. Um a cada `AURA_VFX_COOLDOWN` e
	o bastante para o jogador entender que aquela torre esta rendendo.
]=]
function UnitService:playAuraVFX(entry)
	local now = os.clock()
	if now - (entry.lastAuraVFX or 0) < AURA_VFX_COOLDOWN then return end

	entry.lastAuraVFX = now

	for _, plr in ipairs(Players:GetPlayers()) do
		Framework:Fire("AuraBonusVFX", plr, entry.unitId)
	end
end

--[=[
	Aplica dano e credita quem bateu: o placar de dano da unidade, o caixa do dono
	(com o bonus da aura) e o efeito de dinheiro quando o bonus valeu.

	Passa por aqui todo dano que sai de uma unidade -- ataque normal, area e mina.
]=]
function UnitService:creditDamage(entry, mobId, damage : number, auraBonus : number) : number
	local dealt = self.Services.MobService:DamageMob(mobId, damage, entry.ownerUserId, auraBonus)
	self:addDamageDone(entry, dealt)

	-- Golpe que nao encostou em ninguem (o mob ja estava morto) nao rende nem
	-- efeito: o `DamageMob` devolve 0 e nao pagou nada.
	if dealt > 0 and auraBonus > 0 then
		self:playAuraVFX(entry)
	end

	return dealt
end

function UnitService:stepCombat()
	local units = self.PlacedUnits
	local count = #units
	if count == 0 then return end

	local mobService = self.Services.MobService
	if not mobService then return end

	-- Tempo de partida, e nao `os.clock()`: e o mesmo "agora" que gravou
	-- `lastAttack`, `StunnedUntil` e o prazo da carga, entao acelerar o relogio
	-- encurta os tres juntos sem tocar em nenhum numero do `UnitUpgradeConfig`.
	local now = GameClock.Now()
	local scansLeft = TARGET_SCANS_PER_FRAME

	-- Uma leitura por quadro, repassada para baixo: o clima nao muda no meio de um
	-- laco, e consultar por unidade so gastaria.
	local weather = self:GetWeather()

	self:collectAuraSources()
	self:stepTripmines(now, weather)

	for i = 1, count do
		local entry = units[i]
		local stats = SharedConfig.UnitStats[entry.unitName]

		--[[
			Unidade desligada pelo clima nao faz nada neste laco -- a chuva apaga o
			`Fire` inteiro. Nao e atordoamento: nao tem prazo, nao acende realce
			amarelo e nao pode ser encurtado; ela volta quando o clima sair.

			A renda da farm fica de fora porque quem paga e o `payFarmUnits`, e nao
			este laco. Nenhuma farm de hoje e de uma classe que algum clima desligue;
			no dia em que for, e la que a regra tem que ser repetida.
		]]
		if SharedConfig.WeatherConfig.IsDisabled(weather, entry.unitName) then continue end

		if stats and stats.Farm then continue end

		if stats and stats.Tripmine then
			if now >= (entry.StunnedUntil or 0) then
				self:stepTripminer(entry, stats, now, weather)
			end
			continue
		end

		if mobService.ActiveMobCount > 0
			and stats
			and now >= (entry.StunnedUntil or 0)
			and now - (entry.lastAttack or 0) >= self:getCooldown(entry, now, weather)
		then
			local unitPosition = entry.cf.Position
			local range = SharedConfig.UnitUpgradeConfig:GetRange(entry.unitName, entry.upgrades or 0, weather)

			local targetId = entry.targetMobId
			local targetValid = false
			if targetId and mobService.ActiveMobs[targetId] then
				local pos = mobService:getMobPosition(targetId)
				targetValid = pos ~= nil and (pos - unitPosition).Magnitude <= range
			end

			--[[
				A busca acontece a cada golpe, e nao so quando o alvo sai do alcance:
				prioridade e sobre quem esta em alcance AGORA. O mob mais fraco muda
				a cada batida, e o "mais forte" que acabou de entrar no alcance tem
				que roubar o alvo do que ja estava la.

				O orcamento de buscas por quadro continua mandando — estourou, a
				unidade fica com o alvo anterior se ele ainda serve e tenta de novo
				no proximo quadro.
			]]
			if scansLeft > 0 then
				scansLeft -= 1
				local bestId = mobService:GetBestMobInRange(unitPosition, range, entry.priority)
				if bestId then
					targetId = bestId
					targetValid = true
				elseif not targetValid then
					targetId = nil
				end
				entry.targetMobId = targetId
			elseif not targetValid then
				entry.targetMobId = nil
			end

			if targetValid then
				entry.lastAttack = now
				self:executeAttack(entry, stats, targetId, weather)
			end
		end
	end
end

--[=[
	Cooldown efetivo de uma unidade: o da tabela com o clima, dividido pela carga
	temporaria que ela esteja carregando.

	A carga entra por fora do `UnitUpgradeConfig` porque ela e estado de partida —
	uma unidade especifica que levou um raio ha 4 segundos — e o config so conhece
	numeros que valem para todo mundo.
]=]
function UnitService:getCooldown(entry, now : number, weather : string?) : number
	local cooldown = SharedConfig.UnitUpgradeConfig:GetCooldown(entry.unitName, entry.upgrades or 0, weather)

	local charge = self:chargeMultiplier(entry, "AttackSpeed", now)
	if charge <= 0 then return cooldown end

	return cooldown / charge
end

-- Dano por golpe, com o mesmo arredondamento do config.
function UnitService:getDamage(entry, stats, weather : string?) : number
	local base = stats.Damage or 0
	local multiplier = SharedConfig.UnitUpgradeConfig:GetDamageMultiplier(entry.unitName, entry.upgrades or 0, weather)
	local charge = self:chargeMultiplier(entry, "Damage", GameClock.Now())

	return math.floor(base * multiplier * charge + 0.5)
end

function UnitService:getMineLimit(entry, tripmineConfig)
	return (tripmineConfig.BaseLimit or 3) + (entry.upgrades or 0) * (tripmineConfig.LimitPerUpgrade or 1)
end

function UnitService:getActiveMineCount(entry)
	local total = entry.pendingMines or 0
	if entry.mines then
		for _ in entry.mines do
			total += 1
		end
	end
	return total
end

function UnitService:getRandomPathPointInRange(entry, weather : string?)
	local unitPosition = entry.cf.Position
	local range = SharedConfig.UnitUpgradeConfig:GetRange(entry.unitName, entry.upgrades or 0, weather)

	local step = 1
	local candidates = {}

	-- Varre todas as rotas: uma mina pode cair em qualquer lado da bifurcacao que
	-- estiver no alcance, e o gatilho ja testa todos os mobs independente da rota.
	for _, route in self.Services.MobService:getRoutes() do
		local routeSmooth = route.smooth
		if routeSmooth and routeSmooth.points and #routeSmooth.points >= 2 and routeSmooth.length > 0 then
			local d = 0
			while d <= routeSmooth.length do
				local p = PathUtil.GetPositionAtDistance(routeSmooth, d)
				if p then
					local flat = Vector3.new(p.X - unitPosition.X, 0, p.Z - unitPosition.Z)
					if flat.Magnitude <= range then
						table.insert(candidates, { smooth = routeSmooth, distance = d })
					end
				end
				d += step
			end
		end
	end

	if #candidates == 0 then return nil end

	local pick = candidates[math.random(1, #candidates)]
	local smooth = pick.smooth
	local distance = math.clamp(pick.distance + (math.random() - 0.5) * step, 0, smooth.length)

	local point = PathUtil.GetPositionAtDistance(smooth, distance)
	local ahead = PathUtil.GetPositionAtDistance(smooth, math.min(smooth.length, distance + 0.5))
	local direction = Vector3.new(ahead.X - point.X, 0, ahead.Z - point.Z)
	if direction.Magnitude < 0.001 then
		local behind = PathUtil.GetPositionAtDistance(smooth, math.max(0, distance - 0.5))
		direction = Vector3.new(point.X - behind.X, 0, point.Z - behind.Z)
	end

	local offset = Vector3.zero
	if direction.Magnitude > 0.001 then
		local perpendicular = direction.Unit:Cross(Vector3.yAxis)
		offset = perpendicular * ((math.random() - 0.5) * 2 * 1.5)
	end

	return point + offset + Vector3.new(0, 0.35, 0)
end

function UnitService:stepTripminer(entry, stats, now, weather : string?)
	local config = stats.Tripmine
	entry.mines = entry.mines or {}

	local cooldown = self:getCooldown(entry, now, weather)
	if now - (entry.lastAttack or 0) < cooldown then return end

	if self:getActiveMineCount(entry) >= self:getMineLimit(entry, config) then return end

	local position = self:getRandomPathPointInRange(entry, weather)
	if not position then return end

	entry.lastAttack = now
	entry.pendingMines = (entry.pendingMines or 0) + 1

	local attackConfig = SharedConfig.UnitAttackConfig and SharedConfig.UnitAttackConfig[entry.unitName]
	local sequence = attackConfig and attackConfig.AttackSequence
	local windup = sequence and sequence[1] and sequence[1].HitTime or 0

	local mineId = HttpService:GenerateGUID(false)
	local yaw = math.random() * math.pi * 2
	local mineCF = CFrame.new(position) * CFrame.Angles(0, yaw, 0)

	for _, plr in ipairs(Players:GetPlayers()) do
		Framework:Fire("UnitSwing", plr, entry.unitId, entry.unitName, false, 1)
	end

	GameClock.Delay(windup, function()
		entry.pendingMines = math.max(0, (entry.pendingMines or 1) - 1)
		if not self.UnitsById[entry.unitId] then return end
		entry.mines[mineId] = { position = position, cf = mineCF }
		for _, plr in ipairs(Players:GetPlayers()) do
			Framework:Fire("TripmineThrown", plr, entry.unitId, mineId, mineCF)
		end
	end)
end

function UnitService:stepTripmines(now, weather : string?)
	local mobService = self.Services.MobService
	if mobService.ActiveMobCount == 0 then return end

	for _, entry in ipairs(self.PlacedUnits) do
		local stats = SharedConfig.UnitStats[entry.unitName]
		local config = stats and stats.Tripmine
		if config and entry.mines then
			for mineId, mine in entry.mines do
				local triggeredBy = mobService:GetNearestMobInRange(mine.position, config.TriggerRadius or 2.5)
				if triggeredBy then
					entry.mines[mineId] = nil
					local damage = self:getDamage(entry, stats, weather)
					local radius = config.AOE and config.AOE.Radius or 6
					local mobsHit = mobService:GetMobsInRadius(mine.position, radius)

					-- A aura mede a distancia ate a UNIDADE, e nao ate a mina: quem
					-- precisa estar perto da farm e a torre, nao o lugar onde ela
					-- jogou o explosivo.
					local auraBonus = self:getAuraBonus(entry, weather)

					for _, mobId in ipairs(mobsHit) do
						self:creditDamage(entry, mobId, damage, auraBonus)
					end
					for _, plr in ipairs(Players:GetPlayers()) do
						Framework:Fire("TripmineTriggered", plr, entry.unitId, mineId)
					end
				end
			end
		end
	end
end

function UnitService:payFarmUnits()
	for _, entry in ipairs(self.PlacedUnits) do
		local stats = SharedConfig.UnitStats[entry.unitName]
		local farm = stats and stats.Farm
		if farm then
			local player = Players:GetPlayerByUserId(entry.ownerUserId)
			if player then
				-- Sem clima de proposito: a renda da fazenda nao e dano, e o corte de
				-- 30% da tempestade de areia mexeria na economia da partida em vez de
				-- no combate — que e o que os climas foram feitos para fazer.
				local amount = math.floor((farm.Income or 0) * SharedConfig.UnitUpgradeConfig:GetDamageMultiplier(entry.unitName, entry.upgrades or 0) + 0.5)
				self.Services.MobService:addCash(player, amount)
				for _, plr in ipairs(Players:GetPlayers()) do
					Framework:Fire("FarmPayout", plr, entry.unitId, amount)
				end
			end
		end
	end
end

function UnitService:executeAttack(entry, unitStats, initialMobId, weather : string?)
	local unitName = entry.unitName
	local unitId = entry.unitId
	local unitPosition = entry.cf.Position
	local upgradeLevel = entry.upgrades or 0

	--[[
		O dano e o alcance sao congelados aqui, no comeco do golpe, e nao relidos a
		cada acerto. Um MultiShot leva quase um segundo do primeiro ao ultimo hit, e
		um clima que entrasse no meio faria os quatro golpes do mesmo ciclo saírem
		com numeros diferentes.
	]]
	local damage = self:getDamage(entry, unitStats, weather)

	-- Congelado pelo mesmo motivo: a farm pode ser vendida entre o primeiro e o
	-- ultimo golpe de um MultiShot, e os quatro hits do mesmo ciclo tem que render
	-- igual.
	local auraBonus = self:getAuraBonus(entry, weather)

	local aoe = unitStats.AOE
	local range = SharedConfig.UnitUpgradeConfig:GetRange(unitName, upgradeLevel, weather)
	local totalHits = unitStats.Hits or 1

	local attackConfig = SharedConfig.UnitAttackConfig and SharedConfig.UnitAttackConfig[unitName]
	local sequence = attackConfig and attackConfig.AttackSequence
	local stepIndex = 1
	local windup = 0
	if sequence and #sequence > 0 then
		stepIndex = ((entry.attackStep or 0) % #sequence) + 1
		entry.attackStep = stepIndex
		windup = sequence[stepIndex].HitTime or 0
	end

	for _, plr in ipairs(Players:GetPlayers()) do
		Framework:Fire("UnitSwing", plr, unitId, unitName, initialMobId, stepIndex)
	end

	task.spawn(function()
		if windup > 0 then
			GameClock.Wait(windup)
		end

		for i = 1, totalHits do
			local resolvedMobId = initialMobId
			-- O alvo morreu entre dois golpes do mesmo ataque: o substituto sai pela
			-- mesma prioridade, senao o golpe 2 iria para o mais perto enquanto o
			-- golpe 1 foi para o mais forte.
			if resolvedMobId and not self.Services.MobService.ActiveMobs[resolvedMobId] then
				resolvedMobId = self.Services.MobService:GetBestMobInRange(unitPosition, range, entry.priority)
			end

			local predictedPos = resolvedMobId and self.Services.MobService:PredictPosition(resolvedMobId)

			local hits = {}
			if aoe then
				local aoeCenter = predictedPos or unitPosition
				local mobsInRadius = self.Services.MobService:GetMobsInRadius(aoeCenter, aoe.Radius)
				for _, targetId in ipairs(mobsInRadius) do
					self:creditDamage(entry, targetId, damage, auraBonus)
					table.insert(hits, { mobId = targetId, damage = damage })
				end
				if #hits == 0 and resolvedMobId then
					self:creditDamage(entry, resolvedMobId, damage, auraBonus)
					table.insert(hits, { mobId = resolvedMobId, damage = damage })
				end
			elseif resolvedMobId then
				self:creditDamage(entry, resolvedMobId, damage, auraBonus)
				table.insert(hits, { mobId = resolvedMobId, damage = damage })
			end

			local visualMobId = resolvedMobId or initialMobId
			if visualMobId then
				for _, plr in ipairs(Players:GetPlayers()) do
					Framework:Fire("AttackVisual", plr, unitId, unitName, visualMobId, hits)
				end
			end

			if i < totalHits then
				GameClock.Wait(unitStats.HitInterval)
			end
		end
	end)
end

function UnitService:getUnitNameById(unitId)
	local entry = self.UnitsById[unitId]
	return entry and entry.unitName or nil
end

function UnitService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service)
	end

	local waveService = self.Services.WaveService
	if waveService and waveService.Signals and waveService.Signals.Ended then
		waveService.Signals.Ended:Connect(function()
			if waveService.GameOver then return end
			self:payFarmUnits()
		end)
	end

	for _, player in ipairs(Players:GetPlayers()) do
		self:initPlayerCards(player)
	end

	Players.PlayerAdded:Connect(function(player)
		self:initPlayerCards(player)
	end)

	Players.PlayerRemoving:Connect(function(player)
		self.SessionCards[player.UserId] = nil
		self.SessionCardMax[player.UserId] = nil
	end)

	self:construct()
end

function UnitService:init()

end

return UnitService
