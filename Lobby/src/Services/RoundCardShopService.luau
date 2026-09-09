local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)

local Me = require(Vendor.Me)
local Signal = require(Packages.Signal)

local RoundCardConfig = SharedConfig.RoundCardConfig
local RoundCardShopConfig = SharedConfig.RoundCardShopConfig

local Framework = Me.new()

--[=[
	A loja de cartas do lobby: quem sorteia a vitrine e quem cobra por ela.

	Ela vende **acesso** às cartas de round: a compra escreve o `Id` no `RoundCards`
	do perfil, e é essa tabela que a oferta de round da partida sorteia (ver o
	`_pool` do `CardShopService`). Regras e preços estão no
	`SharedConfig.RoundCardShopConfig` — daqui saem só o sorteio e a cobrança.

	**A vitrine é de cada jogador, e sai da hora.** As três cartas são recalculadas do
	bloco de quatro horas em que o relógio está mais o `UserId`
	(`RoundCardShopConfig.stockFor`), então um restart no meio do bloco não troca a
	oferta de ninguém e dois jogadores no mesmo lobby veem cartas diferentes. Nada disso
	é guardado em DataStore: a hora e o dono já respondem.

	O cliente nunca decide nada aqui. Ele pede a vitrine, desenha, e manda "quero a
	carta X" — e este service confere que X está na vitrine **da hora atual**, que o
	jogador ainda não a tem, e que os shards dão.

	**O reroll troca as três cartas daquele jogador.** A vitrine já é de cada um, então
	comprar o developer product (`REROLL_PRODUCT_ID`) só muda a origem delas: em vez de
	saírem do sorteio do bloco, passam a sair do perfil, até o bloco virar. As três cartas sorteadas ficam **gravadas** no `RoundCardRoll` do
	perfil, e é por isso que elas não mudam quando ele compra uma delas — ver o
	comentário do `createEmptyRoll`, que conta o que acontecia quando elas eram
	recalculadas.
]=]
local RoundCardShopService = {
	Services = {
		DataService = {},

		-- Para registrar o developer product do reroll. Quem chama o callback é o
		-- `ProcessReceipt` de lá.
		MonetizationService = {},
	},

	Signals = {
		-- (Player, cardId : string, price : number, remaining : number) -- `remaining`
		-- é o saldo de shards depois da cobrança.
		CardUnlocked = Signal.new(),

		-- (Player, rolls : number) -- o reroll foi creditado; `rolls` é o número dele
		-- dentro deste bloco de quatro horas.
		Rerolled = Signal.new(),
	},
}

--[[ INTERNAL ]]

--- O perfil aberto do jogador, ou nil enquanto ele não carregou.
function RoundCardShopService:_profileOf(player : Player) : any
	local dataService = self.Services.DataService
	local profiles = dataService and dataService.Profiles
	local entry = profiles and profiles[player]

	return entry and entry.Profile.Data or nil
end

--[=[
	As cartas que a loja pode vender: as do catálogo, na ordem em que ele as declara.

	A ordem importa porque o sorteio da vitrine é semeado: mudar a ordem das entradas
	no `RoundCardConfig` muda quais três cartas cada bloco de quatro horas oferece.
	Não é um problema — é só o que acontece quando o catálogo muda —, mas é a razão
	pela qual a pool é montada de uma vez e guardada, em vez de filtrada por jogador:
	a vitrine é a mesma para todo mundo.

	**Sem filtro de efeito.** O lobby não tem a tabela `Effects` (ela é do
	`CardShopService`, na Game), então uma carta cujo efeito não exista lá poderia ser
	vendida aqui e nunca sair no sorteio de round. Esse é o mesmo erro de config que a
	Game já avisa quando sobe, e é lá que ele tem de ser corrigido — silenciá-lo aqui
	só esconderia metade do sintoma.
]=]
function RoundCardShopService:_pool() : { any }
	if self.Pool then
		return self.Pool
	end

	local pool = {}
	for _, card in RoundCardConfig.Cards do
		table.insert(pool, card)
	end

	self.Pool = pool
	return pool
end

--[=[
	Devolve os shards cobrados por uma compra que não pôde ser entregue.

	Uma escrita própria, e não um `Update` de `Stats` de volta a mão em cada chamada,
	porque a cobrança e a devolução precisam ler o saldo no mesmo instante em que
	escrevem — o `Update` não cede o controle no meio, e é isso que impede duas
	compras simultâneas de gastarem o mesmo saldo.
]=]
function RoundCardShopService:_refund(player : Player, amount : number)
	self.Services.DataService:Update(player, "Stats", function(stats)
		stats = stats or {}

		local currency = RoundCardShopConfig.CURRENCY
		stats[currency] = (stats[currency] or 0) + amount

		return stats
	end)
end

--[=[
	Manda para o jogador a vitrine **dele** (a global, ou a que ele rerolou).

	Não manda nada enquanto o perfil não carregou: o `PlayerDataLoaded` empurra a
	vitrine assim que ele chega, e é melhor a loja abrir vazia por um segundo do que
	abrir com a prateleira errada e ficar nela.
]=]
function RoundCardShopService:_sendStock(player : Player)
	local stock = self:GetStockFor(player)
	if not stock then
		return false
	end

	Framework:Fire("RoundCardStock", player, stock)
	return true
end

--[=[
	As duas pools do reroll deste perfil: o que falta destravar, e o que ele já tem.

	O sorteio enche as vagas com a primeira e só completa com a segunda — é o que separa
	o reroll pago do sorteio do bloco, que mostra carta já destravada com o véu `SOLD`
	sem distinguir nada. Ver `REROLL_EXCLUDES_UNLOCKED` e `drawReroll`.
]=]
function RoundCardShopService:_rerollPools(profile : any) : ({ any }, { any })
	return RoundCardShopConfig.splitByUnlocked(profile, self:_pool())
end

--[=[
	Vira a vitrine quando o bloco de quatro horas acaba.

	O laço dorme até o próximo reset em vez de checar a cada segundo: o instante da
	troca é uma conta (`secondsUntilReset`), e não uma coisa a descobrir. O `+ 1` é
	folga para o `os.time()` já ter passado do limite quando ele acordar — acordar no
	segundo exato deixaria o `rotationIndex` ainda no bloco antigo e a espera se
	repetiria com zero de espera.

	Quem já está no lobby recebe a vitrine nova sem pedir nada: a loja pode estar
	aberta na frente dele na hora da troca, e um painel que continuasse mostrando as
	cartas velhas venderia o que a loja não vende mais (o servidor recusaria, e o
	jogador leria isso como um bug).
]=]
function RoundCardShopService:_watchRotation()
	task.spawn(function()
		while true do
			task.wait(RoundCardShopConfig.secondsUntilReset() + 1)

			local index = RoundCardShopConfig.rotationIndex()
			if self.Block and self.Block.Index == index then
				continue
			end

			self.Block = nil

			-- Quem ainda não carregou não perde nada: o `PlayerDataLoaded` manda a vitrine
			-- nova para ele assim que o perfil chegar.
			for _, player in Players:GetPlayers() do
				self:_sendStock(player)
			end
		end
	end)
end

--[[ API ]]

--[=[
	O bloco de quatro horas em que o relógio está: `{ Index, ResetsAt }`.

	É a única parte da loja que é de todo mundo. As cartas são de cada jogador (ver
	`GetStockFor`); o que eles compartilham é o instante em que todas viram.

	Guardado por bloco, e não por chamada: são duas divisões de `os.time()`, e o cache
	morre sozinho quando o índice muda.
]=]
function RoundCardShopService:GetBlock()
	local index = RoundCardShopConfig.rotationIndex()

	if self.Block and self.Block.Index == index then
		return self.Block
	end

	self.Block = {
		Index = index,
		ResetsAt = RoundCardShopConfig.resetsAt(),
	}

	return self.Block
end

--[=[
	A vitrine **deste** jogador: a global, ou a que ele rerolou neste bloco.

	As duas respostas são montadas na hora, e nenhuma é guardada. Montar é barato — um
	sorteio semeado de três cartas, ou a leitura do preço de três `Id` — e não há o que
	invalidar: o que poderia mudar entre duas chamadas (o que o jogador destravou) de
	propósito **não** entra em nenhuma das duas contas.
]=]
function RoundCardShopService:GetStockFor(player : Player)
	local block = self:GetBlock()

	local profile = self:_profileOf(player)

	--[[
		**Sem perfil não há resposta.** Perfil ainda carregando não é "este jogador não
		rerolou": é "ainda não dá para saber". A vitrine depende do `UserId` **e** do
		reroll gravado, então responder sem perfil é chutar as duas coisas.

		Foi exatamente esse o bug: o cliente pede a vitrine quando a `ShopUI` monta, o
		que acontece antes de o `StartSessionAsync` voltar. O servidor respondia a
		global, o cliente guardava, e nada mais corrigia -- a prateleira paga só voltava
		no reroll seguinte. Quem chama trata o nil esperando o perfil; ver o
		`RequestRoundCardStock` e o `PlayerDataLoaded` no `construct`.
	]]
	if not profile then
		return nil
	end

	local rolls = RoundCardShopConfig.rollsOf(profile, block.Index)

	--[[
		Sem reroll, a vitrine é o sorteio do bloco para **este** jogador -- recalculado,
		e não guardado. Ele é estável porque a pool é o catálogo inteiro: comprar uma
		carta não a tira do sorteio, ela só ganha o véu `SOLD`.
	]]
	if rolls <= 0 then
		return {
			Index = block.Index,
			ResetsAt = block.ResetsAt,
			Rolls = 0,
			Cards = RoundCardShopConfig.stockFor(block.Index, player.UserId, self:_pool()),
		}
	end

	--[[
		As cartas saem do perfil, e não de um sorteio refeito agora.

		É o que mantém a prateleira paga parada enquanto o jogador compra dela: o sorteio
		varre só o que falta destravar, então refazê-lo depois de uma compra encheria a
		vaga vendida com uma carta nova em vez de deixá-la `SOLD`.
	]]
	local cards = RoundCardShopConfig.entriesFor(
		RoundCardShopConfig.rolledCardsOf(profile, block.Index)
	)

	-- Prateleira gravada vazia (perfil de antes de ela ser gravada, ou cartas que
	-- sairam do catálogo) vale como não ter rerolado: o sorteio do bloco é o estado que
	-- a tela sempre sabe desenhar.
	if #cards == 0 then
		return {
			Index = block.Index,
			ResetsAt = block.ResetsAt,
			Rolls = 0,
			Cards = RoundCardShopConfig.stockFor(block.Index, player.UserId, self:_pool()),
		}
	end

	return {
		Index = block.Index,
		ResetsAt = block.ResetsAt,
		Rolls = rolls,
		Cards = cards,
	}
end

--[=[
	Destrava uma carta da vitrine para o jogador: cobra os shards e escreve o `Id` no
	`RoundCards` do perfil.

	Devolve true, ou false mais o motivo ("NotLoaded", "NotInStock", "AlreadyOwned",
	"NotEnoughCurrency", "GrantFailed"). Nenhum deles é erro de programa: são as
	maneiras de o pedido estar velho ou repetido — o clique duplo, a vitrine que virou
	entre o desenho e o clique, o evento mandado à mão.

	A conferência e a cobrança acontecem dentro de um único `:Update`, que não cede o
	controle: dois cliques seguidos não têm como gastar o mesmo saldo. E a **posse**
	é conferida de novo dentro da escrita do `RoundCards`, e não só antes da cobrança:
	sem isso, dois cliques no mesmo quadro cobrariam duas vezes pela mesma carta.
]=]
function RoundCardShopService:Purchase(player : Player, cardId : any) : (boolean, string?)
	local DataService = self.Services.DataService
	local profile = self:_profileOf(player)

	if not DataService or not DataService.Update or not profile then
		warn(string.format("[RoundCardShopService]: %s não tem perfil carregado; compra ignorada.", player.Name))
		return false, "NotLoaded"
	end

	--[[
		O preço sai da **vitrine deste jogador**, e não do `priceOf` direto: é ela que diz
		o que está à venda para ele agora, e cobrar por um `Id` qualquer venderia o
		catálogo inteiro a quem mandasse o evento na mão.

		`GetStockFor`, e não `GetStock`: quem rerolou está olhando para outra prateleira,
		e conferir contra a global recusaria justamente as cartas que ele pagou para ver.
	]]
	local stock = self:GetStockFor(player)

	-- O `profile` acima já garante que ela não é nil; a guarda é porque `GetStockFor`
	-- passou a poder devolver nil e um deref aqui derrubaria a compra inteira.
	if not stock then
		return false, "NotLoaded"
	end

	local price = nil

	for _, entry in stock.Cards do
		if entry.Id == cardId then
			price = entry.Price
			break
		end
	end

	if not price then
		warn(string.format("[RoundCardShopService]: %s pediu %q, que não está na vitrine dele agora.",
			player.Name, tostring(cardId)))
		return false, "NotInStock"
	end

	if RoundCardShopConfig.isUnlocked(profile, cardId) then
		return false, "AlreadyOwned"
	end

	local charged = false
	local remaining = 0

	DataService:Update(player, "Stats", function(stats)
		stats = stats or {}

		local currency = RoundCardShopConfig.CURRENCY
		local owned = stats[currency] or 0

		if owned < price then
			return stats
		end

		remaining = owned - price
		stats[currency] = remaining
		charged = true

		return stats
	end)

	if not charged then
		return false, "NotEnoughCurrency"
	end

	local granted = false

	DataService:Update(player, "RoundCards", function(unlocked)
		unlocked = typeof(unlocked) == "table" and unlocked or {}

		if unlocked[cardId] then
			return unlocked
		end

		unlocked[cardId] = true
		granted = true

		return unlocked
	end)

	if not granted then
		-- A carta já estava destravada quando a escrita chegou: dois cliques no mesmo
		-- quadro. O segundo devolve o que cobrou.
		self:_refund(player, price)
		return false, "GrantFailed"
	end

	self.Signals.CardUnlocked:Fire(player, cardId, price, remaining)
	return true
end

--[=[
	Credita um reroll: sobe o contador do bloco atual e manda a prateleira nova.

	Devolve `false` quando não deu para escrever no perfil — e é por isso que o retorno
	importa: quem chama é o `ProcessReceipt`, e um `false` faz o receipt voltar como
	`NotProcessedYet`. A Roblox então tenta de novo mais tarde, em vez de dar a compra
	por entregue sem ela ter acontecido. O jogador já foi cobrado; o que não pode é o
	dinheiro sumir sem prateleira.

	**Não cobra nada e não confere preço**: quem cobrou foi a Roblox. Aqui é só a
	entrega.

	O registro zera sozinho na virada do bloco, pelo `Index`: o `Update` reescreve os
	campos quando o que estava lá é de um bloco anterior, então a prateleira paga hoje
	não sobrevive à rotação de amanhã.
]=]
function RoundCardShopService:Reroll(player : Player) : boolean
	local DataService = self.Services.DataService

	if not DataService or not DataService.Update or not self:_profileOf(player) then
		warn(string.format("[RoundCardShopService]: %s não tem perfil carregado; o reroll não foi creditado.", player.Name))
		return false
	end

	local index = RoundCardShopConfig.rotationIndex()

	--[[
		O sorteio acontece **antes** do `Update`, e não dentro dele: o callback do
		`Update` não pode ceder o fio, e sortear ali dentro só esconderia o trabalho num
		lugar onde ele não pode crescer.

		A pool é lida do perfil de agora — as cartas que ele ainda não tem. Daí para a
		frente o resultado está gravado e não é mais recalculado.
	]]
	local locked, owned = self:_rerollPools(self:_profileOf(player))
	local cards = RoundCardShopConfig.drawReroll(locked, owned)

	if #cards == 0 then
		warn(string.format("[RoundCardShopService]: %s rerolou sem carta nenhuma para sortear.", player.Name))
		return false
	end

	local rolls = 0

	DataService:Update(player, "RoundCardRoll", function(roll)
		roll = typeof(roll) == "table" and roll or RoundCardShopConfig.createEmptyRoll()

		if roll.Index ~= index then
			roll.Index = index
			roll.Rolls = 0
		end

		rolls = math.max(math.floor(tonumber(roll.Rolls) or 0), 0) + 1

		roll.Rolls = rolls
		roll.Cards = cards

		return roll
	end)

	if rolls <= 0 then
		return false
	end

	self:_sendStock(player)
	self.Signals.Rerolled:Fire(player, rolls)

	return true
end

--[[ CICLO DE VIDA ]]

function RoundCardShopService:construct()
	--[[
		O cliente pede a vitrine quando liga a loja, em vez de o servidor mandar no
		join: a `ShopUI` é `ResetOnSpawn`, então o painel é reconstruído a cada respawn,
		e um envio único no join se perderia na primeira morte. O pedido também cobre o
		jogador que entrou antes de este service subir.
	]]
	--[[
		O pedido **espera o perfil**. O `DataService:Get` responde quando ele estiver
		carregado (e não trava este handler: ele agenda), então um pedido que chegou cedo
		demais é respondido tarde em vez de ser respondido errado.
	]]
	Framework:Listen("RequestRoundCardStock", function(player : Player)
		local dataService = self.Services.DataService

		if not dataService then
			return
		end

		dataService:Get(player, function()
			self:_sendStock(player)
		end)
	end)

	--[[
		E a vitrine também sai sozinha quando o perfil chega, sem ninguém pedir.

		São os dois lados da mesma corrida: o `Get` acima cobre o pedido que chegou antes
		do perfil, e isto cobre o pedido que se perdeu inteiro (o cliente pode ter ligado
		a loja antes de este service registrar o `Listen`, e o retry dele tem teto).
	]]
	local dataService = self.Services.DataService

	if dataService and dataService.Signals and dataService.Signals.PlayerDataLoaded then
		dataService.Signals.PlayerDataLoaded:Connect(function(player : Player)
			self:_sendStock(player)
		end)

		-- Quem já estava dentro quando este service subiu: o sinal deles já passou.
		for _, player in Players:GetPlayers() do
			self:_sendStock(player)
		end
	else
		warn("[RoundCardShopService]: sem PlayerDataLoaded; a vitrine só sai por pedido do cliente.")
	end

	Framework:Listen("RequestBuyRoundCard", function(player : Player, cardId : any)
		local success, reason = self:Purchase(player, cardId)

		Framework:Fire("RoundCardPurchaseResult", player, cardId, success, reason)
	end)

	--[[
		O reroll é vendido pela Roblox, e não por este service: o cliente abre o prompt do
		developer product e quem chega aqui é o **recibo**, pelo `ProcessReceipt` do
		`MonetizationService`.

		Não há evento de "quero rerolar" de propósito. Um pedido do cliente só poderia
		abrir o prompt (que o cliente já abre sozinho) ou creditar sem pagamento — e a
		única prova de que houve pagamento é o recibo.

		O `MonetizationService` cuida do resto do contrato: ele não credita o mesmo
		`PurchaseId` duas vezes (`PurchaseHistory`) e só confirma a compra depois de o
		perfil estar gravado em disco.
	]]
	local monetization = self.Services.MonetizationService

	if monetization then
		monetization:RegisterProduct(RoundCardShopConfig.REROLL_PRODUCT_ID, function(player : Player)
			return self:Reroll(player)
		end)
	else
		warn("[RoundCardShopService]: sem MonetizationService; o reroll da loja de cartas não vai ser creditado.")
	end

	self:_watchRotation()
end

function RoundCardShopService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service, false, true)
	end

	self:construct()
end

function RoundCardShopService:init()
	-- O cliente conecta nos dois durante o `init` dele, mas o servidor só criaria o
	-- evento na primeira vez que o disparasse -- e o Warp reclama que ele "is taking
	-- too long to retrieve". Declarados aqui como os outros eventos de servidor.
	Framework:Listen("RoundCardStock", function() end)
	Framework:Listen("RoundCardPurchaseResult", function() end)

	-- O bloco de quatro horas de agora, `{ Index, ResetsAt }`. As cartas não moram aqui:
	-- elas são de cada jogador (ver `GetStockFor`).
	self.Block = nil

	-- O catálogo à venda, montado uma vez. Ver `_pool`.
	self.Pool = nil
end

return RoundCardShopService
