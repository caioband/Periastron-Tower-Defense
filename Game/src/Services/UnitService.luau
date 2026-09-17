local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")
local ServerConfigs = ServerScriptService:WaitForChild("Config")
local Assets = Shared:WaitForChild("Assets")
local Units = Assets:WaitForChild("Units")

local SharedConfig = require(Configs.SharedConfig)
local TargetPriority = SharedConfig.TargetPriority
local DeckConfig = SharedConfig.DeckConfig
local CardModifier = SharedConfig.CardModifier
local ServerConfig = require(ServerConfigs)
local PathUtil = require(Shared:WaitForChild("Util"):WaitForChild("PathUtil"))
local PlacementUtil = require(Shared:WaitForChild("Util"):WaitForChild("PlacementUtil"))
local GameClock = require(Shared:WaitForChild("Util"):WaitForChild("GameClock"))

local Warp = require(Vendor.Warp)
local Me = require(Vendor.Me)
local Signal = require(Packages.Signal)

local Framework = Me.new()

local TARGET_SCANS_PER_FRAME = 8

-- Um efeito de dinheiro por unidade a cada tanto. Ver `playAuraVFX`.
local AURA_VFX_COOLDOWN = 0.35

local MAX_PLACE_DISTANCE = 2048

--[[
	A largura, em studs, do risco que um projetil `Piercing` deixa, quando a
	unidade nao diz outra em `Projectile.PierceWidth`.

	Nao e a espessura da flecha: e a folga que decide quem estava "no caminho". Dois
	studs pegam o mob que a linha corta de raspao -- eles tem cerca de dois de
	largura -- sem transformar a flecha num cone que limpa a fileira do lado.
]]
local PIERCE_WIDTH = 2

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

--[[
	O multiplicador de quem nao esta sob carta nenhuma.

	Uma tabela so, compartilhada por todas as unidades enquanto a lista de
	modificadores estiver vazia -- que e o comeco de toda partida. Sem ela cada
	unidade ganharia uma tabela de "tudo 1" por quadro, e a partida sem carta
	nenhuma pagaria por um sistema que ela nao esta usando.

	Ela nunca e escrita: quem tem modificador ganha uma tabela propria em
	`refreshCardModifiers`.
]]
local NO_CARD_MULTIPLIERS = {
	Damage = 1,
	AttackSpeed = 1,
	Range = 1,
	Income = 1,
	HitIncome = 1,

	-- `Cleave` nao e numero: e a tabela de numeros do corte, ou nada. Ver
	-- `CardModifier.FlagValue`.
	Cleave = nil,
}

local UnitService = {
	Services = {
		MobService = {},
		DataService = {},
		WaveService = {},
		WeatherService = {},
		CardModifierService = {},
	},

	Signals = {
		--[[
			(player, unitName) -- uma unidade entrou no mapa. Quem escuta e o
			`ContractTrackerService`, para o "win with only Fire units": ele guarda as
			classes de tudo que o jogador colocou na partida, inclusive o que foi vendido
			depois.
		]]
		UnitPlaced = Signal.new(),
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

	--[[
		O campo como o `CardModifier` o enxerga: a lista de unidades (para as
		condicoes de vizinhanca e para o Abrakadabra) e a fracao de vida da base
		(para o No Pain, No Gain).

		Reaproveitada em vez de refeita: ela e remontada todo quadro, e a lista de
		dentro e limpa com `table.clear` para o array nao ser realocado sessenta
		vezes por segundo.
	]]
	CardWorld = { Units = {}, BaseHealthRatio = 1 },

	-- Os modificadores valendo neste quadro, lidos do `CardModifierService`.
	CardModifiers = {},
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
	Esta unidade cabe neste CFrame?

	Sao as tres recusas do posicionamento, na ordem em que elas ficam caras: em cima
	do caminho, perto demais de outra unidade, em cima de um jogador.

	Existe como funcao propria porque agora ha **dois** caminhos que colocam uma
	unidade num lugar: o `PlaceUnit` de sempre e o Zippers, que a arrasta de um lugar
	para outro. Duas copias da mesma conferencia acabariam divergindo, e a divergencia
	que aparece e a pior possivel -- uma carta que poe a torre em cima do caminho.

	`ignoreEntry` e a propria unidade, quando ela esta se mudando: sem isso o Zippers
	sempre recusaria, porque a torre estaria perto demais dela mesma.

	`label` so entra no log de posicionamento, que so existe no Studio.
]=]
function UnitService:isSpotFree(cf : CFrame, unitName : string, label : string?, ignoreEntry : any?) : boolean
	local position = cf.Position
	local unitSizeX = self.UnitSizes[unitName] or 2

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
		placementPrint(label, unitName, "recusado: em cima do caminho", formatVector(position),
			"caixa de teste", formatVector(probeSize),
			string.format("%d part(s) de Grid, primeira: %s em %s", #gridParts, gridParts[1]:GetFullName(), formatVector(gridParts[1].Position)))
		return false
	end

	for _, entry in ipairs(self.PlacedUnits) do
		if entry == ignoreEntry then continue end

		local otherSizeX = self.UnitSizes[entry.unitName] or 2
		local minDist = (unitSizeX + otherSizeX) / 2
		local posA = Vector3.new(position.X, 0, position.Z)
		local posB = Vector3.new(entry.cf.Position.X, 0, entry.cf.Position.Z)
		local dist = (posA - posB).Magnitude
		if dist < minDist then
			placementPrint(label, unitName, "recusado: perto demais de outra unidade",
				formatVector(position), string.format("%s a %.2f studs (minimo %.2f)", entry.unitName, dist, minDist))
			return false
		end
	end

	--[[
		Ninguem nasce dentro de um jogador.

		E aqui que a regra vale de verdade: o cliente pinta o fantasma de vermelho
		para o jogador enxergar, mas quem aceita ou recusa e o servidor -- um cliente
		adulterado manda o CFrame que quiser.
	]]
	local blockingCharacter = PlacementUtil.FindBlockingCharacter(cf, checkSize)
	if blockingCharacter then
		placementPrint(label, unitName, "recusado: em cima de um personagem",
			formatVector(position), "personagem", blockingCharacter:GetFullName())
		return false
	end

	return true
end

--[=[
	Muda uma unidade ja colocada de lugar. E o Zippers, e e a unica carta que mexe
	no tabuleiro em vez de nos numeros.

	O destino passa pelas **mesmas** conferencias do `PlaceUnit`: fora do caminho,
	longe das outras torres, sem ninguem em cima. Um destino recusado devolve `nil` e
	um motivo, e quem chamou nao gasta a carta -- errar o lugar nao pode custar a
	compra.

	`rotation` e o giro em radianos no eixo Y, opcional; sem ele a torre fica com o
	que ja tinha. Ele entra na conferencia junto com o ponto, e nao depois: a caixa
	que o `isSpotFree` testa e a do modelo **girado**, que e a mesma que o fantasma
	do cliente pintou de verde.

	Na tela a unidade e tirada e reposta (`RemoveUnit` + `ReplicateUnit`) em vez de
	deslizar ate o destino. O `unitId` continua o mesmo, entao o card, a prioridade e
	o placar de dano dela sobrevivem a viagem; o que se perde e so a animacao de
	mudanca, e o caminho de reposicionamento e o mesmo que ja replica toda unidade
	desde sempre.

	O alvo do momento e derrubado junto: mirar do lugar velho depois de ter mudado
	de lugar faria a torre atirar em quem ela ja nao alcanca.
]=]
function UnitService:MoveUnit(unitId : any, position : any, rotation : number?)
	local entry = self.UnitsById[unitId]
	if not entry then
		return nil, "unidade nao existe"
	end

	if typeof(position) ~= "Vector3" then
		return nil, "destino invalido"
	end

	if position.X ~= position.X or position.Y ~= position.Y or position.Z ~= position.Z then
		return nil, "destino NaN"
	end

	if position.Magnitude > MAX_PLACE_DISTANCE then
		return nil, "destino longe demais"
	end

	--[[
		O giro vem do fantasma, como num posicionamento novo: quem move uma torre
		escolhe um lugar **e** uma direcao, e o R do teclado gira o fantasma do
		Zippers pelo mesmo caminho que gira o de uma torre que acabou de ser comprada.

		Sem giro no pedido a torre fica com o que ja tinha. Isso nao e so
		retrocompatibilidade: e o que mantem honesto o caso em que o cliente nao teve
		fantasma nenhum para girar.

		A altura ja veio no `position`, medida no cliente pelo mesmo CFrame que o
		`PlaceUnit` valida.
	]]
	local spin = if rotation then CFrame.Angles(0, rotation, 0) else (entry.cf - entry.cf.Position)
	local cf = CFrame.new(position) * spin

	if not self:isSpotFree(cf, entry.unitName, "Zippers", entry) then
		return nil, "destino ocupado"
	end

	entry.cf = cf
	entry.targetMobId = nil

	--[[
		O cliente derruba o placar de dano da unidade junto com o modelo dela (ver o
		`RemoveUnit` no `UnitPlacementController`), e o lote so manda quem esta sujo:
		sem isto o card mostraria zero ate a torre bater de novo.
	]]
	self.DamageDirty[entry.unitId] = true

	-- A mina ja armada continua onde caiu: ela e do mapa a partir do arremesso, e
	-- nao da torre. So os arremessos seguintes saem do lugar novo.
	for _, plr in ipairs(Players:GetPlayers()) do
		Framework:Fire("RemoveUnit", plr, entry.unitId)
		Framework:Fire("ReplicateUnit", plr, entry.unitName, cf, entry.ownerUserId, entry.unitId, entry.upgrades or 0, entry.priority)
	end

	return entry
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

--[[ CARTAS DE ROUND ]]

--[=[
	Refaz, uma vez por quadro, o que as cartas de round estao fazendo com cada
	unidade.

	**Uma vez por quadro, e nao por pergunta.** O combate pergunta dano, cadencia e
	alcance de cada unidade a cada quadro, e duas das condicoes do `CardModifier`
	(o Iceolated e o Ice to Meet You) varrem a vizinhanca inteira para responder --
	perguntar por unidade e por estatistica multiplicaria essa varredura por cinco.
	Aqui a conta e feita uma vez e guardada em `entry.CardMult`, e o resto do quadro
	so le a tabela.

	O descritor de cada unidade tambem e reaproveitado (`entry.CardDescriptor`): a
	posicao e reescrita, e nao a tabela refeita. Sem isso seriam algumas dezenas de
	tabelas por quadro so para dizer ao `CardModifier` coisas que ele ja podia ler.

	Sem carta nenhuma no campo, todo mundo aponta para o `NO_CARD_MULTIPLIERS` e a
	funcao sai pelo caminho curto -- que e a partida inteira ate a primeira loja.
]=]
function UnitService:refreshCardModifiers()
	local service = self.Services.CardModifierService
	local modifiers = service and service:GetActive() or nil

	self.CardModifiers = modifiers

	if not modifiers or #modifiers == 0 then
		for _, entry in self.PlacedUnits do
			entry.CardMult = NO_CARD_MULTIPLIERS
		end

		return
	end

	local world = self.CardWorld
	table.clear(world.Units)

	local mobService = self.Services.MobService
	local maxHealth = mobService and mobService.MaxBaseHealth or 0
	world.BaseHealthRatio = if maxHealth > 0 then (mobService.BaseHealth or 0) / maxHealth else 1

	for _, entry in self.PlacedUnits do
		local descriptor = entry.CardDescriptor

		if not descriptor then
			descriptor = { UnitId = entry.unitId, UnitName = entry.unitName }
			entry.CardDescriptor = descriptor
		end

		-- A posicao muda quando o Zippers move a torre; o resto do descritor e fixo
		-- pela vida da unidade.
		descriptor.Position = entry.cf.Position

		table.insert(world.Units, descriptor)
	end

	for _, entry in self.PlacedUnits do
		local descriptor = entry.CardDescriptor
		local values = entry.CardMult

		-- A tabela compartilhada nao pode ser escrita: quem sai do caminho curto
		-- ganha a sua.
		if not values or values == NO_CARD_MULTIPLIERS then
			values = {}
			entry.CardMult = values
		end

		values.Damage = CardModifier.Multiplier(modifiers, "Damage", descriptor, world)
		values.AttackSpeed = CardModifier.Multiplier(modifiers, "AttackSpeed", descriptor, world)
		values.Range = CardModifier.Multiplier(modifiers, "Range", descriptor, world)
		values.Income = CardModifier.Multiplier(modifiers, "Income", descriptor, world)
		values.HitIncome = CardModifier.Multiplier(modifiers, "HitIncome", descriptor, world)
		values.Cleave = CardModifier.FlagValue(modifiers, "Cleave", descriptor, world)
	end
end

--[=[
	O multiplicador de carta de uma unidade, do quadro corrente.

	Unidade que ainda nao passou por um `refreshCardModifiers` -- uma colocada neste
	mesmo quadro, antes de o combate rodar -- vale 1 em tudo. E o valor certo para a
	fresta: ela entra no proximo quadro, e um multiplicador vazio nunca inventa um
	bonus que o jogador nao comprou.
]=]
function UnitService:cardMultiplier(entry, stat : string) : number
	local values = entry and entry.CardMult

	return (values and values[stat]) or 1
end

--[=[
	O mesmo, para o que nao e numero: hoje so o corte do Cleave It To Me.

	Devolve a tabela de numeros daquele comportamento (quantos corpos, quanto o de
	tras perde, a largura do risco) ou `nil` quando ele nao esta ligado -- e por isso
	quem chama pode testar o retorno como um sim-ou-nao.
]=]
function UnitService:cardFlag(entry, flag : string)
	local values = entry and entry.CardMult

	return values and values[flag] or nil
end

--[=[
	O alcance de uma unidade: o da tabela, com o clima, vezes o que as cartas
	fizeram com ele.

	Existe para que nao haja duas contas de alcance no arquivo. O combate mira por
	ele, a mina cai por ele, a aura da farm cobre por ele -- e o cliente desenha o
	circulo pela mesma multiplicacao, do outro lado (`CardModifierController`).
]=]
function UnitService:getRange(entry, weather : string?) : number
	local base = SharedConfig.UnitUpgradeConfig:GetRange(entry.unitName, entry.upgrades or 0, weather)

	return base * self:cardMultiplier(entry, "Range")
end

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
	em vez de empilhar: dois raios seguidos na mesma unidade dao o prazo inteiro de
	buff a partir do segundo, nao 50% em cima de 50%.
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
	VFX proprio (`Effects.Snow.Freeze.Asset`, o `IcedVFX`) e o raio nao. Sem `source` — o gimmick
	de mob — o cliente so desenha o realce.
]=]
function UnitService:StunUnit(entry, duration : number, source : string?)
	if not entry then return end

	--[[
		O Staff of Healing deixa a unidade imune por alguns segundos. A recusa e aqui,
		e nao em cada coisa que atordoa: o raio, o congelamento da neve e o gimmick de
		mob passam todos por esta funcao, e um teste por chamador acabaria com um
		deles esquecido -- que e justamente o que o jogador leria como "a carta nao
		funcionou".
	]]
	if GameClock.Now() < (entry.StunImmuneUntil or 0) then return end

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

--[=[
	Tira o atordoamento de quem esta no circulo e deixa essas unidades imunes por
	`immunity` segundos. E o Staff of Healing.

	Devolve quantas unidades o circulo pegou -- inclusive as que nao estavam
	atordoadas, porque a imunidade vale para elas do mesmo jeito: a carta e tanto o
	remedio quanto o guarda-chuva, e quem a joga em cima de um canto do mapa antes
	do raio cair fez a jogada certa.

	A distancia e medida no plano, como o resto do que e circulo neste jogo: o anel
	que o jogador viu na tela e um desenho no chao.
]=]
function UnitService:CleanseUnits(position : Vector3, radius : number, immunity : number) : number
	if typeof(position) ~= "Vector3" then return 0 end

	local center = Vector3.new(position.X, 0, position.Z)
	local until_ = GameClock.Now() + math.max(0, immunity or 0)
	local touched = 0

	for _, entry in self.PlacedUnits do
		local at = entry.cf.Position
		if (Vector3.new(at.X, 0, at.Z) - center).Magnitude > radius then continue end

		touched += 1

		-- O prazo maior manda: um segundo cajado em cima do primeiro estende a
		-- imunidade, e nunca a encurta.
		entry.StunImmuneUntil = math.max(entry.StunImmuneUntil or 0, until_)

		local wasStunned = (entry.StunnedUntil or 0) > GameClock.Now()
		entry.StunnedUntil = 0

		--[[
			O cliente precisa saber, e nao so por causa do realce amarelo: o
			congelamento da neve tem uma aura de particulas que fica no ar pelo prazo
			inteiro dele, e ela nao tem como adivinhar que o prazo acabou mais cedo.
		]]
		if wasStunned then
			for _, plr in ipairs(Players:GetPlayers()) do
				Framework:Fire("UnitCleansed", plr, entry.unitId)
			end
		end
	end

	return touched
end

function UnitService:construct()
	Framework:Listen("ReplicateUnit", function() end)
	Framework:Listen("RemoveUnit", function() end)
	Framework:Listen("UnitStunned", function() end)
	Framework:Listen("UnitCharged", function() end)
	Framework:Listen("UnitCleansed", function() end)
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
	Framework:Listen("ChainLightning", function() end)
	Framework:Listen("ArchmageMeteor", function() end)
	Framework:Listen("ArchmageLightning", function() end)

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

		local isValid = self:isSpotFree(cf, unitName, player.Name)

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

			self.Signals.UnitPlaced:Fire(player, unitName)
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
		local radius = self:getRange(source, weather)

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
	--[[
		O `HitIncome` do anel do Robux Royalty entra como **escala** do premio, e nao
		somado ao bonus da aura: a aura e uma fracao que se acumula entre farms
		(15% + 15% = 30%), e a carta e um multiplicador em cima do que sobrou. Somar
		os dois faria "1.1x" virar "+10 pontos percentuais", que e outro numero.
	]]

	-- Onde o alvo estava **antes** do dano, para quem espalha gelo em volta dele (o
	-- `Frost.Radius`): um alvo que morre com o tiro ja nao tem posicao para dar
	-- depois, e a area tem que sair mesmo assim.
	local unitStats = SharedConfig.UnitStats[entry.unitName]
	local frostCenter = unitStats and unitStats.Frost and unitStats.Frost.Radius
		and self.Services.MobService:getMobPosition(mobId)

	local dealt = self.Services.MobService:DamageMob(
		mobId, damage, entry.ownerUserId, auraBonus, self:cardMultiplier(entry, "HitIncome")
	)
	self:addDamageDone(entry, dealt)

	-- Golpe que nao encostou em ninguem (o mob ja estava morto) nao rende nem
	-- efeito: o `DamageMob` devolve 0 e nao pagou nada.
	if dealt > 0 and auraBonus > 0 then
		self:playAuraVFX(entry)
	end

	--[[
		O que o golpe **deixa** no inimigo, alem do dano: a lentidao do gelo e a
		queimadura do fogo. Os dois sao declarados na propria unidade
		(`UnitStats[nome].Slow` / `.Burn`) e executados pelo `MobService`, que e quem
		e dono do estado do inimigo.

		So depois de o dano ter entrado: um golpe que nao encostou em ninguem nao
		congela nem queima ninguem.

		> Hoje deixam alguma coisa o Electro -- o tranco logo abaixo, que entra em
		> **cada elo** da corrente, porque este caminho e o mesmo para qualquer alvo que
		> tenha levado dano -- e o Frostione, com os acumulos de gelo, que usam a
		> lentidao por dentro. A queimadura e do Pyre, e a carta Fire Hazard multiplica
		> os tiques dela.
	]]
	if dealt > 0 then
		local stats = SharedConfig.UnitStats[entry.unitName]

		local slow = stats and stats.Slow
		if slow then
			self.Services.MobService:ApplySlow(mobId, slow.Amount, slow.Duration)
		end

		local burn = stats and stats.Burn
		if burn then
			self.Services.MobService:ApplyBurn(mobId, burn.Damage, burn.Ticks, burn.Interval, entry.ownerUserId)
		end

		local bleed = stats and stats.Bleed
		if bleed then
			self.Services.MobService:ApplyBleed(mobId, bleed.Damage, bleed.Ticks, bleed.Interval, entry.ownerUserId)
		end

		--[[
			O tranco: o inimigo para de vez por um instante, e so depois volta a andar
			(lento, se o golpe tambem deixou `Slow` -- nenhum deixa hoje). E o mesmo
			`StunnedUntil` do Time Stop, aplicado a um mob so.

			Vem **depois** da lentidao de proposito, e a ordem importa: o `ApplySlow` nao
			avisa a tela enquanto o mob esta parado, entao lentidao primeiro e tranco
			depois deixa as duas pontas contando a mesma historia. Ao contrario, o aviso
			de velocidade nova sairia por cima do "parou".
		]]
		-- O tempo e o do nivel da unidade (o tranco cresce com o upgrade), e o dono vai
		-- junto: o atordoamento conta para os contratos dele.
		local stunDuration = SharedConfig.UnitUpgradeConfig:GetStunDuration(entry.unitName, entry.upgrades or 0)
		if stunDuration > 0 then
			self.Services.MobService:StunMob(mobId, stunDuration, entry.ownerUserId)
		end

		-- Os acumulos de gelo do Frostione: lentidao enquanto durarem, congelamento no
		-- ultimo. O `unitId` vai junto porque a conta e de cada unidade, e nao do
		-- inimigo. Ver o `MobService:ApplyFrost`.
		local frost = stats and stats.Frost
		if frost then
			local mobService = self.Services.MobService
			mobService:ApplyFrost(mobId, frost, entry.ownerUserId, entry.unitId)

			--[[
				A area de gelo em volta do alvo: quem estiver nela ganha um acumulo da
				mesma unidade, como se tivesse levado o tiro, mas sem dano -- o dano e so
				do alvo. O raio cresce com o nivel (`GetFrostRadius`).

				O centro e a posicao do alvo **antes** do dano (`frostCenter`, la em
				cima): o alvo pode ter morrido com este tiro, e a area sai do mesmo jeito.
				Ele fica de fora da lista porque ja levou o acumulo dele logo acima.
			]]
			local radius = SharedConfig.UnitUpgradeConfig:GetFrostRadius(entry.unitName, entry.upgrades or 0)
			if frostCenter and radius > 0 then
				for _, nearbyId in mobService:GetMobsInRadius(frostCenter, radius) do
					if nearbyId ~= mobId then
						mobService:ApplyFrost(nearbyId, frost, entry.ownerUserId, entry.unitId)
					end
				end
			end
		end
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

	--[[
		As cartas antes de tudo: o dano, a cadencia e o alcance lidos daqui para baixo
		saem ja com o que elas fizeram. Uma leitura por quadro, como o clima -- ver
		`refreshCardModifiers`.
	]]
	self:refreshCardModifiers()

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
			and now - (entry.lastAttack or 0) >= self:getAttackDelay(entry, now, weather)
		then
			local unitPosition = entry.cf.Position
			local range = self:getRange(entry, weather)

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
	Quanto a unidade espera, desde o ultimo golpe, para dar o proximo.

	Quase sempre e o cooldown. A excecao e a sequencia encadeada (`ChainSequence` no
	`UnitAttackConfig`, o Archmage): no meio dela a espera e o `ChainDelay` contado
	do comeco do passo que acabou de sair -- ou a `Duration` da animacao dele, se for
	maior, para nenhum passo cortar o anterior --, e depois do ultimo passo e a
	animacao dele **mais** o cooldown: o cooldown conta do fim da sequencia, e nao do
	comeco do ultimo passo.

	A sequencia sem inimigo no alcance nao anda: o `stepCombat` so ataca com alvo, e
	o `attackStep` fica onde parou ate aparecer um.
]=]
function UnitService:getAttackDelay(entry, now : number, weather : string?) : number
	local attackConfig = SharedConfig.UnitAttackConfig and SharedConfig.UnitAttackConfig[entry.unitName]
	local sequence = attackConfig and attackConfig.ChainSequence and attackConfig.AttackSequence
	local current = entry.attackStep or 0

	if not sequence or #sequence == 0 or current == 0 then
		return self:getCooldown(entry, now, weather)
	end

	local step = sequence[current]
	local animation = step and step.Duration or 0

	if current < #sequence then
		return math.max(animation, attackConfig.ChainDelay or 0)
	end

	return animation + self:getCooldown(entry, now, weather)
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

	--[[
		A carta entra como divisao, igual ao clima: 1.15 e "bate 15% mais rapido", ou
		seja, o mesmo ciclo em 1/1.15 do tempo. E aqui, e nao no `UnitUpgradeConfig`,
		pelo mesmo motivo da carga do raio -- o config so conhece numeros que valem
		para todo mundo, e uma carta vale para quem ela escolheu.
	]]
	local cards = self:cardMultiplier(entry, "AttackSpeed")
	if cards > 0 then
		cooldown /= cards
	end

	local charge = self:chargeMultiplier(entry, "AttackSpeed", now)
	if charge <= 0 then return cooldown end

	return cooldown / charge
end

-- Dano por golpe, com o mesmo arredondamento do config.
function UnitService:getDamage(entry, stats, weather : string?) : number
	local base = stats.Damage or 0
	local multiplier = SharedConfig.UnitUpgradeConfig:GetDamageMultiplier(entry.unitName, entry.upgrades or 0, weather)
	local charge = self:chargeMultiplier(entry, "Damage", GameClock.Now())
	local cards = self:cardMultiplier(entry, "Damage")

	return math.floor(base * multiplier * charge * cards + 0.5)
end

function UnitService:getMineLimit(entry, tripmineConfig)
	local limit = (tripmineConfig.BaseLimit or 3) + (entry.upgrades or 0) * (tripmineConfig.LimitPerUpgrade or 1)

	-- `MaxLimit` e o teto: os upgrades seguintes continuam valendo pelo dano.
	return math.min(limit, tripmineConfig.MaxLimit or math.huge)
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
	local range = self:getRange(entry, weather)

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
		Framework:Fire("UnitSwing", plr, entry.unitId, entry.unitName, false, 1, cooldown)
	end

	--[[
		A mina sai da mao no fim do windup e **so arma quando pousa**.

		Sao dois instantes, e nao um: antes, a mina entrava em `entry.mines` no mesmo
		quadro em que o cliente comecava a desenhar o arco, entao ela passava o voo
		inteiro armada e invisivel no destino -- um mob que cruzasse o ponto nessa
		janela via a explosao sair de um lugar onde ainda nao havia mina nenhuma.

		O `ThrowTime` vai junto no evento em vez de o cliente ler do config: assim os
		dois lados gastam o mesmo numero por construcao, e o arco termina exatamente
		no quadro em que o gatilho liga.

		As duas esperas sao de partida (`GameClock`), como o cooldown e o windup: no
		3x a mina e arremessada e pousa tres vezes mais rapido, junto com o resto.
	]]
	local throwTime = config.ThrowTime or 0

	GameClock.Delay(windup, function()
		if not self.UnitsById[entry.unitId] then
			entry.pendingMines = math.max(0, (entry.pendingMines or 1) - 1)
			return
		end

		for _, plr in ipairs(Players:GetPlayers()) do
			Framework:Fire("TripmineThrown", plr, entry.unitId, mineId, mineCF, throwTime)
		end

		GameClock.Delay(throwTime, function()
			-- A vaga so e liberada aqui: a mina no ar ja conta para o limite, senao o
			-- cooldown de 3s contra windup mais voo deixaria plantar acima dele.
			entry.pendingMines = math.max(0, (entry.pendingMines or 1) - 1)

			if not self.UnitsById[entry.unitId] then return end

			-- `armedAt` comeca o carregamento: ver `Tripmine.Charge` e `mineChargeFactor`.
			entry.mines[mineId] = { position = position, cf = mineCF, armedAt = GameClock.Now() }
		end)
	end)
end

--[=[
	Quanto do dano uma mina entrega agora: `StartDamage` no pouso, subindo em linha
	reta ate 1 em `Charge.Time` segundos. Sem `Charge` no config a mina sai cheia.
]=]
local function mineChargeFactor(mine, config, now : number) : number
	local charge = config.Charge
	if not charge or (charge.Time or 0) <= 0 then return 1 end

	local start = math.clamp(charge.StartDamage or 1, 0, 1)
	local progress = math.clamp((now - (mine.armedAt or now)) / charge.Time, 0, 1)

	return start + (1 - start) * progress
end

function UnitService:stepTripmines(now, weather : string?)
	local mobService = self.Services.MobService
	if mobService.ActiveMobCount == 0 then return end

	for _, entry in ipairs(self.PlacedUnits) do
		local stats = SharedConfig.UnitStats[entry.unitName]
		local config = stats and stats.Tripmine
		if config and entry.mines then
			for mineId, mine in entry.mines do
				--[[
					O trecho que o mob andou neste quadro, e nao onde ele esta parado.

					Um mob anda `CurrentSpeed * dt` por quadro, e acelerado esse passo
					passa do diametro do gatilho: no 3x com o servidor a 30Hz, o inimigo
					mais rapido do Nightmare da quase 6 studs de uma vez e atravessaria os
					5 studs de gatilho da mina sem nunca ser visto parado dentro dela. Com
					o segmento, a mina explode pela distancia -- e nao pela sorte de o
					quadro cair em cima dela.
				]]
				local triggeredBy = mobService:GetMobCrossing(mine.position, config.TriggerRadius or 2.5)
				if triggeredBy then
					entry.mines[mineId] = nil
					local fullDamage = self:getDamage(entry, stats, weather)
					local damage = math.floor(fullDamage * mineChargeFactor(mine, config, now) + 0.5)
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
	--[[
		A renda e paga no fim da wave, fora do laco de combate: sem esta leitura ela
		sairia com o que as cartas estavam fazendo no ultimo quadro em que alguem
		atacou -- que pode ter sido antes de o anel do cajado ser desenhado.
	]]
	self:refreshCardModifiers()

	for _, entry in ipairs(self.PlacedUnits) do
		local stats = SharedConfig.UnitStats[entry.unitName]
		local farm = stats and stats.Farm
		if farm then
			local player = Players:GetPlayerByUserId(entry.ownerUserId)
			if player then
				--[[
					Sem clima de proposito: a renda da fazenda nao e dano, e o corte de
					30% da tempestade de areia mexeria na economia da partida em vez de
					no combate — que e o que os climas foram feitos para fazer.

					A **carta**, essa sim, entra: o anel do Robux Royalty e uma carta de
					economia, e recusa-la aqui seria recusar a coisa que ela faz.
				]]
				local income = (farm.Income or 0)
					* SharedConfig.UnitUpgradeConfig:GetDamageMultiplier(entry.unitName, entry.upgrades or 0)
					* self:cardMultiplier(entry, "Income")

				local amount = math.floor(income + 0.5)
				self.Services.MobService:addCash(player, amount)
				for _, plr in ipairs(Players:GetPlayers()) do
					Framework:Fire("FarmPayout", plr, entry.unitId, amount)
				end
			end
		end
	end
end

--[=[
	Um passo de sequencia com `Combo` (o Archmage): o ataque daquele passo, com os
	numeros de `UnitStats[nome].Combo[step.Combo]`.

	Os tempos sao os do passo (`HitTime`, `HitEnd`), no relogio da partida. A janela
	desses passos e a `Duration` da animacao (`getAttackDelay`), maior ou igual a
	ela, entao nenhum e espremido: os marcadores valem como estao.

	O alvo e quem a unidade mirava quando o passo comecou -- e dele que sai a posicao
	do meteoro, a direcao do raio e quem e teleportado.
]=]
function UnitService:executeCombo(entry, unitStats, step, targetId, weather : string?)
	local combo = unitStats.Combo and unitStats.Combo[step.Combo]
	local mobService = self.Services.MobService
	if not combo or not mobService then return end

	local unitId = entry.unitId
	local unitName = entry.unitName
	local unitPosition = entry.cf.Position

	-- Congelados no comeco do passo, pelo mesmo motivo do golpe comum: um clima ou
	-- uma carta que entre no meio nao muda o passo que ja comecou.
	local auraBonus = self:getAuraBonus(entry, weather)
	local damage = combo.Damage and self:getDamage(entry, combo, weather) or 0
	local range = self:getRange(entry, weather)

	-- Onde o alvo estava quando o passo comecou: e para la que o meteoro cai.
	local aimPos = targetId and mobService:getMobPosition(targetId)

	local function showHits(hits)
		if #hits == 0 then return end
		for _, plr in ipairs(Players:GetPlayers()) do
			Framework:Fire("AttackVisual", plr, unitId, unitName, hits[1].mobId, hits)
		end
	end

	task.spawn(function()
		GameClock.Wait(step.HitTime or 0)

		if step.Combo == "Meteor" then
			if not aimPos then return end

			local fallTime = combo.FallTime or 1
			for _, plr in ipairs(Players:GetPlayers()) do
				Framework:Fire("ArchmageMeteor", plr, unitId, aimPos, fallTime, combo.Height or 15)
			end

			-- O dano entra no impacto, junto com a explosao que o cliente toca.
			GameClock.Wait(fallTime)

			local radius = SharedConfig.UnitUpgradeConfig:GetMeteorRadius(unitName, entry.upgrades or 0)
			local hits = {}
			for _, mobId in mobService:GetMobsInRadius(aimPos, radius) do
				self:creditDamage(entry, mobId, damage, auraBonus)
				table.insert(hits, { mobId = mobId, damage = damage })
			end
			showHits(hits)
		elseif step.Combo == "Lightning" then
			-- A linha trava aqui, no inicio do dano: onde o alvo esta agora, ou onde ele
			-- estava no comeco do passo se ja morreu.
			local through = (targetId and mobService:getMobPosition(targetId)) or aimPos
			if not through then return end

			local window = math.max(0, (step.HitEnd or step.HitTime or 0) - (step.HitTime or 0))
			local interval = math.max(0.05, combo.Interval or 0.1)
			local ticks = math.max(1, math.floor(window / interval + 1e-6))

			for _, plr in ipairs(Players:GetPlayers()) do
				Framework:Fire("ArchmageLightning", plr, unitId, through, window)
			end

			for tick = 1, ticks do
				-- Quem estiver na linha **neste** tique: inimigo que entra na reta no
				-- meio do raio tambem leva.
				local hits = {}
				for _, mobId in mobService:GetMobsAlongLine(unitPosition, through, range, combo.Width or PIERCE_WIDTH) do
					self:creditDamage(entry, mobId, damage, auraBonus)
					table.insert(hits, { mobId = mobId, damage = damage })
				end
				showHits(hits)

				if tick < ticks then
					GameClock.Wait(interval)
				end
			end
		elseif step.Combo == "Teleport" then
			if targetId and mobService.ActiveMobs[targetId] then
				mobService:TeleportMobBack(targetId)
			end
		end
	end)
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

	--[[
		O projetil que atravessa: o golpe deixa de ser "o alvo" e passa a ser a linha
		ate ele. Quem estiver nela leva o mesmo dano, inclusive quem vem atras do
		alvo -- a flecha nao para no primeiro.
	]]
	local projectile = unitStats.Projectile
	local pierce = projectile and projectile.Subtype == "Piercing" and projectile or nil

	--[[
		O raio que salta: o golpe deixa de ser "o alvo" e passa a ser a corrente que
		sai dele. Quem monta a corrente e o `MobService`, que e o dono da posicao de
		todo mundo -- aqui so se cobra o dano de cada elo e se manda o desenho.
	]]
	local chain = unitStats.Chain

	--[[
		O corte que a carta Cleave It To Me liga no corpo a corpo, com os numeros dela
		dentro. Congelado aqui junto com o dano, e nao relido a cada acerto, pelo mesmo
		motivo: um MultiShot leva quase um segundo, e a carta pode vencer no meio dele.

		So vale para quem nao tem area, projetil nem corrente -- os tres ja acertam mais
		de um alvo por conta propria, e somar o corte por cima seria a mesma unidade
		cobrando duas vezes pela mesma ideia.
	]]
	local cleave = (not aoe and not projectile and not chain) and self:cardFlag(entry, "Cleave") or nil

	local range = self:getRange(entry, weather)
	local totalHits = unitStats.Hits or 1

	local attackConfig = SharedConfig.UnitAttackConfig and SharedConfig.UnitAttackConfig[unitName]
	local sequence = attackConfig and attackConfig.AttackSequence
	local stepIndex = 1
	local step = nil
	local windup = 0
	if sequence and #sequence > 0 then
		stepIndex = ((entry.attackStep or 0) % #sequence) + 1
		entry.attackStep = stepIndex
		step = sequence[stepIndex]
		windup = step.HitTime or 0
	end

	--[[
		A janela do golpe vai junto com o pedido: quanto tempo de partida a unidade
		tem antes de poder atacar de novo.

		So o servidor sabe esse numero -- o da tabela ja passado pelo clima, pelo
		upgrade, pela carta e pela carga --, e o cliente precisa dele para caber a
		animacao dentro do golpe (ver o `Unit:playAttackVisual`). Mandar o
		`stats.Cooldown` cru nao serviria: uma carta de `AttackSpeed` encurta o
		ciclo e a animacao tem que encurtar junto.
	]]
	local swingWindow = self:getCooldown(entry, GameClock.Now(), weather)

	--[[
		O passo com `Combo` (o Archmage) tem caminho proprio, e sai daqui antes de
		tudo o que e do golpe comum -- area, projetil, corrente, combo de acertos.

		A janela dele e a `Duration` da animacao, e nao o cooldown: numa sequencia
		encadeada o cooldown so vale depois do ultimo passo (`getAttackDelay`), e a
		animacao tem que tocar inteira, sem espremer, para os marcadores continuarem
		batendo com os tempos do servidor.
	]]
	if step and step.Combo then
		swingWindow = step.Duration or swingWindow

		for _, plr in ipairs(Players:GetPlayers()) do
			Framework:Fire("UnitSwing", plr, unitId, unitName, initialMobId, stepIndex, swingWindow)
		end

		self:executeCombo(entry, unitStats, step, initialMobId, weather)
		return
	end

	--[=[
		O golpe que acerta varias vezes dentro da mesma animacao, cada acerto no seu
		instante (`HitTimes`, no `UnitAttackConfig`) em vez de espacado por
		`HitInterval`. Quem tem isso hoje e o Berserker, e o combo dele nao cabe no
		intervalo regular: 0,83s do primeiro acerto para o segundo e 1,30s do segundo
		para o terceiro.

		Com a lista no passo, e ela quem manda no numero de acertos -- o `Hits` do
		`UnitStats` continua existindo para o DPS do card, e os dois tem que
		continuar iguais (ver o comentario de la).

		O `squeeze` e o mesmo encolhimento que o cliente faz na animacao quando ela
		nao cabe na janela do golpe (`Unit:playAttackVisual`): as duas pontas dividem
		pelo mesmo fator, entao o acerto continua caindo no frame do marcador mesmo
		com uma carta de `AttackSpeed` apertando o ciclo. Sem ele, o ultimo acerto do
		Berserker (2,5667s) sairia depois de o golpe seguinte ja ter comecado assim
		que a janela descesse dos 2,9s da animacao. No caso normal -- janela maior que
		a animacao -- o fator e 1 e os instantes sao os da tabela.
	]=]
	local schedule = nil
	if step and step.HitTimes and #step.HitTimes > 0 then
		local duration = step.Duration or 0
		local squeeze = (swingWindow > 0 and duration > swingWindow) and (duration / swingWindow) or 1

		schedule = table.create(#step.HitTimes)
		for index, at in ipairs(step.HitTimes) do
			schedule[index] = at / squeeze
		end

		totalHits = #schedule
		windup = schedule[1]
	end

	--[=[
		Quanto cada golpe do MESMO ataque vale, em fracao do dano cheio.

		A queda e por **golpe**, e nao por alvo: a do `PierceFalloff` desconta a cada
		corpo que a flecha fura dentro de um tiro so, esta desconta a cada batida do
		combo, e quem esta na area do golpe 2 leva o mesmo que quem esta na area do
		golpe 1. As duas se compoem sem conflito -- a queda do combo entra como base
		da queda da linha --, so que nenhuma unidade de hoje declara as duas.

		O `HitFalloff` do `UnitStats` e a perda de um golpe para o **seguinte**, e nao
		a perda contra o dano cheio: com 0.1, o combo vale 100%, 90%, 81%, 72,9%...
		Composta pelo mesmo motivo da flecha -- assim ela nunca chega a zero, enquanto
		descontar 10 pontos percentuais de cada vez faria o 11o golpe nao machucar e o
		12o curar o inimigo.

		O dano so e arredondado la embaixo, na hora de cobrar, e nao a cada degrau da
		queda: arredondar em cada um acumularia o erro do arredondamento ao longo do
		combo. O piso de 1 e o mesmo do resto do arquivo -- acertou, tirou vida.
	]=]
	local hitFalloff = math.clamp(unitStats.HitFalloff or 0, 0, 1)

	for _, plr in ipairs(Players:GetPlayers()) do
		Framework:Fire("UnitSwing", plr, unitId, unitName, initialMobId, stepIndex, swingWindow)
	end

	task.spawn(function()
		if windup > 0 then
			GameClock.Wait(windup)
		end

		for i = 1, totalHits do
			-- O dano deste golpe: o congelado la em cima, menos o que os golpes
			-- anteriores do mesmo ataque ja tiraram (ver o `hitFalloff`).
			local hitDamage = damage
			if hitFalloff > 0 and i > 1 then
				hitDamage = math.max(1, math.floor(damage * (1 - hitFalloff) ^ (i - 1) + 0.5))
			end

			local resolvedMobId = initialMobId
			-- O alvo morreu entre dois golpes do mesmo ataque: o substituto sai pela
			-- mesma prioridade, senao o golpe 2 iria para o mais perto enquanto o
			-- golpe 1 foi para o mais forte.
			if resolvedMobId and not self.Services.MobService.ActiveMobs[resolvedMobId] then
				resolvedMobId = self.Services.MobService:GetBestMobInRange(unitPosition, range, entry.priority)
			end

			local predictedPos = resolvedMobId and self.Services.MobService:PredictPosition(resolvedMobId)

			local hits = {}
			if chain and resolvedMobId then
				--[=[
					A corrente: o alvo mirado e os saltos a partir dele.

					Todos levam o **mesmo** dano -- esta e a unica forma de acertar varios
					alvos do arquivo que nao tem queda nenhuma (a flecha tem o
					`PierceFalloff`, o corte tem o `Falloff`, o combo tem o `HitFalloff`).
					Ver o `Chain` no `UnitStats`: o preco disso esta no `Targets` e no
					cooldown longo, e e la que se mexe.

					O tranco nao aparece aqui: ele e o `Stun` da unidade, aplicado pelo
					`creditDamage` a cada elo -- o mesmo caminho de qualquer coisa que um
					golpe deixe no inimigo. O que este bloco manda para o cliente e so o
					desenho, e o `stun` vai junto porque o realce amarelo do inimigo dura
					exatamente o tempo em que ele esta parado.
				]=]
				local mobService = self.Services.MobService
				local targets = mobService:GetChainTargets(resolvedMobId, chain.Targets, chain.Radius)

				-- O mesmo tempo que o `creditDamage` aplica, no nivel desta unidade.
				local arc = {
					unitId = unitId,
					origin = unitPosition,
					stun = SharedConfig.UnitUpgradeConfig:GetStunDuration(entry.unitName, entry.upgrades or 0),
					targets = {},
				}

				for _, targetId in targets do
					--[[
						A posicao **antes** do dano: o golpe pode derrubar o inimigo, e o mob
						removido ja nao tem posicao para dar. Sem isto o raio ficaria sem a
						ponta justamente naquele que ele matou.
					]]
					table.insert(arc.targets, {
						mobId = targetId,
						position = mobService:getMobPosition(targetId),
					})

					self:creditDamage(entry, targetId, hitDamage, auraBonus)
					table.insert(hits, { mobId = targetId, damage = hitDamage })
				end

				--[[
					O raio sai daqui, e nao do cliente: esta linha roda no instante do
					marcador `Hit` (o `HitTime` do `UnitAttackConfig` e o windup deste
					`task.spawn`), e a corrente que ele desenha e a mesma que acabou de
					cobrar dano. Deixar o cliente escolher os alvos poria o desenho em
					inimigos que nao levaram nada.
				]]
				for _, plr in ipairs(Players:GetPlayers()) do
					Framework:Fire("ChainLightning", plr, arc)
				end
			elseif aoe then
				local aoeCenter = predictedPos or unitPosition
				local mobsInRadius = self.Services.MobService:GetMobsInRadius(aoeCenter, aoe.Radius)
				for _, targetId in ipairs(mobsInRadius) do
					self:creditDamage(entry, targetId, hitDamage, auraBonus)
					table.insert(hits, { mobId = targetId, damage = hitDamage })
				end
				if #hits == 0 and resolvedMobId then
					self:creditDamage(entry, resolvedMobId, hitDamage, auraBonus)
					table.insert(hits, { mobId = resolvedMobId, damage = hitDamage })
				end
			elseif pierce and resolvedMobId then
				--[[
					A linha sai da unidade, passa por onde o alvo vai estar e segue ate
					o **alcance** dela -- e nao ate o alvo. Parar no alvo faria a flecha
					atravessar e nao machucar ninguem do outro lado, que e justamente o
					que a unidade vende.

					A mira e a posicao prevista, a mesma que o cliente usou para desenhar
					o tiro: mirar em onde o mob esta agora poria a linha atras dele. Sem
					previsao (o mob nasceu neste quadro e ainda nao tem caminho andado),
					nao ha linha para tracar e o golpe cai no alvo unico, la embaixo.
				]]
				local along = predictedPos and self.Services.MobService:GetMobsAlongLine(
					unitPosition, predictedPos, range, pierce.PierceWidth or PIERCE_WIDTH
				) or {}

				--[[
					A flecha vai perdendo forca a cada corpo que fura.

					A queda e **composta**, e nao subtraida do dano cheio: com 10%, o
					segundo inimigo leva 90% do primeiro, o terceiro 90% do segundo, e
					assim por diante. Composta ela nunca chega a zero -- uma flecha que
					atravessou dez inimigos ainda machuca um pouco --, enquanto descontar
					10 pontos percentuais de cada vez faria o 11o levar nada e o 12o
					levar dano negativo.

					O arredondamento e o mesmo do `getDamage`, e o piso de 1 existe para
					o fim da fila nao virar um "0" flutuando na tela: acertou, tirou vida.
				]]
				local falloff = math.clamp(pierce.PierceFalloff or 0, 0, 1)

				for index, targetId in ipairs(along) do
					local scaled = hitDamage
					if falloff > 0 and index > 1 then
						scaled = math.max(1, math.floor(hitDamage * (1 - falloff) ^ (index - 1) + 0.5))
					end

					self:creditDamage(entry, targetId, scaled, auraBonus)
					table.insert(hits, { mobId = targetId, damage = scaled })
				end

				-- O alvo saiu da linha entre a mira e o disparo (ele virou uma esquina
				-- durante o windup): ele levou o tiro do mesmo jeito, senao o golpe
				-- inteiro se perderia por causa de uma curva.
				if #hits == 0 then
					self:creditDamage(entry, resolvedMobId, hitDamage, auraBonus)
					table.insert(hits, { mobId = resolvedMobId, damage = hitDamage })
				end
			elseif cleave and resolvedMobId and predictedPos then
				--[[
					O corte do Cleave It To Me: o golpe deixa de valer por alvo e passa a
					valer pela **fila**, como a flecha do Archer -- mas curto. A linha sai da
					unidade, passa por onde o alvo vai estar e para no alcance dela, e so os
					`Targets` primeiros da fila levam.

					O teto existe porque corpo a corpo nao e projetil: "quem esta atras do
					alvo" sao um ou dois inimigos colados, e nao a coluna inteira. Sem ele um
					Sword bem posto num mapa que enfileira limparia a wave sozinho.
				]]
				local line = self.Services.MobService:GetMobsAlongLine(
					unitPosition, predictedPos, range, cleave.Width or PIERCE_WIDTH
				)

				local falloff = math.clamp(cleave.Falloff or 0, 0, 1)
				local limit = math.max(1, cleave.Targets or 1)

				for index, targetId in ipairs(line) do
					if index > limit then break end

					local scaled = hitDamage
					if falloff > 0 and index > 1 then
						-- O mesmo arredondamento e o mesmo piso de 1 da flecha: acertou,
						-- tirou vida, e o fim da fila nao vira um "0" flutuando na tela.
						scaled = math.max(1, math.floor(hitDamage * (1 - falloff) ^ (index - 1) + 0.5))
					end

					self:creditDamage(entry, targetId, scaled, auraBonus)
					table.insert(hits, { mobId = targetId, damage = scaled })
				end

				-- O alvo saiu da linha entre a mira e o golpe: ele leva assim mesmo, senao
				-- uma curva no caminho anularia o ataque inteiro.
				if #hits == 0 then
					self:creditDamage(entry, resolvedMobId, hitDamage, auraBonus)
					table.insert(hits, { mobId = resolvedMobId, damage = hitDamage })
				end
			elseif resolvedMobId then
				self:creditDamage(entry, resolvedMobId, hitDamage, auraBonus)
				table.insert(hits, { mobId = resolvedMobId, damage = hitDamage })
			end

			local visualMobId = resolvedMobId or initialMobId
			if visualMobId then
				for _, plr in ipairs(Players:GetPlayers()) do
					Framework:Fire("AttackVisual", plr, unitId, unitName, visualMobId, hits)
				end
			end

			if i < totalHits then
				-- Com `HitTimes`, o intervalo e a distancia entre dois instantes da
				-- lista; sem ela, o `HitInterval` regular do `UnitStats`.
				GameClock.Wait(schedule and (schedule[i + 1] - schedule[i]) or unitStats.HitInterval)
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
