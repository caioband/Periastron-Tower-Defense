--[[
	A loja de cartas do lobby: `StarterGui.ShopUI.RCSS`.

	Ela vende **acesso** às cartas do `RoundCardConfig`, e não as cartas em si. A
	carta comprada aqui não vai para hotbar nenhuma: ela entra no `RoundCards` do
	perfil e, a partir daí, passa a poder ser sorteada na oferta de round dentro da
	partida (ver o `_pool` do `CardShopService`). Comprar é destravar; usar continua
	sendo comprar de novo, lá dentro, com o caixa da partida.

	**O catálogo inteiro deixou de ser sorteável.** Antes a oferta de round sorteava
	de `RoundCardConfig.Cards` direto, ou seja, o jogador já tinha as vinte e tantas
	cartas na primeira partida. Hoje a pool dele é o que ele destravou — e é isso que
	dá ao lobby uma loja com progressão em vez de uma vitrine decorativa.

	## A vitrine é de cada jogador, e rotativa

	Três cartas por bloco de quatro horas, **sorteadas por jogador**: dois amigos no
	mesmo lobby veem ofertas diferentes, e o que um deles pode destravar hoje não é o
	que o outro pode.

	O **relógio**, esse sim, é de todo mundo: o bloco de quatro horas sai de
	`os.time()` (`rotationIndex`) e cai sempre em 00:00, 04:00, 08:00… UTC. É por isso
	que o `ResetText` ("RESETS IN: 3:12:04") continua querendo dizer alguma coisa — as
	vitrines são pessoais, mas todas viram no mesmo instante.

	Ela não é **guardada** em lugar nenhum: as três cartas são recalculadas do bloco
	mais o `UserId` (`stockFor`). Um servidor que sobe no meio do bloco chega na mesma
	vitrine para cada jogador, e ninguém precisa de um DataStore para uma coisa que a
	hora e o dono já respondem.

	**Isso vale porque a pool não muda.** O sorteio da vitrine varre o catálogo
	inteiro, inclusive as cartas que o jogador já destravou — são elas que aparecem com
	o véu `SOLD`. Uma pool que encolhesse a cada compra faria a vitrine se remontar
	sozinha; é exatamente o que acontecia com o reroll, e por isso **ele** é gravado.
	Ver `createEmptyRoll`.

	## Quem decide o quê

	Sorteio da vitrine e cobrança são **do servidor** (`RoundCardShopService`, no
	Lobby). O cliente recebe as três cartas já sorteadas com o preço de cada uma,
	desenha, e manda "quero a carta X" — o servidor confere que X está na vitrine
	**da hora atual**, que o jogador ainda não a tem e que os shards dão.

	Este módulo é compartilhado porque as duas pontas leem as mesmas regras: o
	cliente para escrever preço e contagem na tela, o servidor para cobrar e para
	saber o que a vitrine é agora.
]]

local RoundCardConfig = require(script.Parent.RoundCardConfig)

local RoundCardShopConfig = {}

--[[ ONDE A LOJA MORA NA GUI ]]

--[=[
	Os nomes autorados, num lugar só.

	**A loja divide a `ScreenGui` com a de caixas.** `ShopUI` carrega os dois
	painéis como irmãos (`Frame` é a de caixas, `RCSS` é esta), então nenhum dos dois
	pode mandar no `Enabled` da ScreenGui sozinho: quem diz qual painel está na tela
	é o `Visible` do wrapper de cada um. Ver o `_setShopEnabled` dos dois
	controllers.
]=]
RoundCardShopConfig.Gui = {
	ScreenGui = "ShopUI",

	-- O wrapper (é dele o `UIAspectRatioConstraint`) e o painel desenhado dentro
	-- dele, que é quem a `OPEN_ANIMATION` anima.
	Wrapper = "RCSS",
	Panel = "ImageLabel",

	-- A fileira das três cartas, sob um `UIListLayout` horizontal.
	Row = "CardsContainer",

	--[[
		O molde de uma carta. O wrapper é quem entra no `UIListLayout` — é por isso que
		ele existe: a carta dentro dele anima posição e escala à vontade sem que o
		layout a arraste de volta para a vaga a cada quadro.

		O `CardWrapper` autorado na `CardsContainer` é o molde, e não a primeira carta:
		o controller o clona três vezes e destrói o original (ver `_template`).
	]]
	Wrapper_Card = "CardWrapper",
	Card = "Card",

	Title = "CardTitle",
	Description = "CardDescription",

	-- O botão de comprar e o número do preço dentro dele. O ícone da shard e a cor do
	-- contorno já estão autorados no botão: esta loja cobra numa moeda só.
	Buy = "Buy",
	BuyLabel = "TextLabel",

	-- O véu de "SOLD", aceso na carta que este jogador já destravou.
	Sold = "SoldFrame",

	--[=[
		Quanto falta para a vitrine trocar.

		**Procurado como filho direto do painel, e não em profundidade.** O nome é único
		na `RCSS` hoje, e a busca rasa é o que mantém isso barato de garantir: a legenda
		dentro do `RerollDice` se chama `Text`, e o dia em que alguém batizar outra label
		de `ResetText` em qualquer lugar do painel, a contagem continua indo para esta —
		e não para a que a ordem da árvore devolver primeiro.
	]=]
	ResetText = "ResetText",

	-- O dado que rerola a vitrine deste jogador, por Robux.
	Reroll = "RerollDice",
}

--[[
	A animação do painel, no `ReplicatedStorage.CascadeAnimations`.

	É a **mesma** `OpenShop` da loja de caixas, e de propósito: as duas são o mesmo
	gesto de balcão no mesmo lobby, e são dois painéis irmãos na mesma `ScreenGui`.
	Ela anima o `Scale` de um `UIScale` filho e o `ImageTransparency` do painel; o
	`UIScale` é criado pelo controller quando o painel não tem um autorado.
]]
RoundCardShopConfig.OPEN_ANIMATION = "OpenShop"

--[[ PROXIMIDADE ]]

--[=[
	Os marcadores da loja, procurados **em profundidade** sob
	`Workspace.<REFERENCE_PARENT_NAME>` — hoje os dois estão dentro do modelo da
	casa (`Map.Deco.Houses.CardShop`), e não soltos na raiz do mapa.

	É o mesmo par de peças da loja de caixas (referência + pouso) com outro nome, e o
	mesmo acordo em tudo, inclusive na distância: o pouso está a **18,8 studs** da
	referência, portanto fora do `OPEN_RADIUS`. Quem teleporta abre o painel na mão e
	marca a entrada — ver `RoundCardShopController:TeleportToShop`.
]=]
RoundCardShopConfig.REFERENCE_PARENT_NAME = "Map"
RoundCardShopConfig.REFERENCE_PART_NAME = "ShopCardPartReference"
RoundCardShopConfig.TELEPORT_PART_NAME = "ShopCardPartTeleport"

--[[
	Studs do marcador de referência, medidos contra a `HumanoidRootPart`.

	Os mesmos 5 da loja de caixas: é o balcão. A loja abre quando o jogador **chega**
	na vitrine, e não quando ele atravessa a praça na frente dela.

	**O `ShopCardPartTeleport` fica a 18,8 studs daqui, portanto fora deste raio.** O
	teleporte não depende da proximidade para abrir: ele abre a loja na mão e marca a
	entrada, para que andar embora feche do mesmo jeito.
]]
RoundCardShopConfig.OPEN_RADIUS = 5

-- De quanto em quanto tempo a distância é medida. O raio é largo o bastante para um
-- quinto de segundo ser imperceptível, e é mais barato que medir todo quadro.
RoundCardShopConfig.PROXIMITY_INTERVAL = 0.2

-- Studs acima do topo do marcador de pouso, para o personagem cair de pé em cima
-- dele em vez de meio enterrado.
RoundCardShopConfig.TELEPORT_HEIGHT_OFFSET = 3

--[[ A ROTAÇÃO ]]

--[=[
	Quanto tempo uma vitrine dura, em segundos.

	Quatro horas contadas do epoch, e não de quando o servidor subiu: os blocos caem
	sempre em 00:00, 04:00, 08:00… UTC, e é isso que faz todos os servidores
	concordarem sobre qual vitrine é a de agora sem trocar uma palavra.
]=]
RoundCardShopConfig.ROTATION_SECONDS = 4 * 60 * 60

--- Quantas cartas a vitrine mostra.
RoundCardShopConfig.STOCK_COUNT = 3

--[=[
	A semente do sorteio da vitrine, multiplicada pelo número do bloco.

	Um primo grande, para que blocos vizinhos não caiam em sequências vizinhas: com
	semente igual ao próprio índice, o `Random` de blocos consecutivos começa perto
	demais e a primeira carta da vitrine ficaria quase parada de quatro em quatro
	horas.
]=]
RoundCardShopConfig.ROTATION_SEED = 2654435761

--[=[
	A parcela do jogador na semente da vitrine. É ela que faz duas pessoas no mesmo
	bloco receberem cartas diferentes.

	**Tem de ser um multiplicador diferente do `ROTATION_SEED`.** Multiplicando os dois
	pela mesma constante, bloco e jogador viram intercambiáveis dentro da soma: a
	vitrine de alguém hoje seria a de outro alguém amanhã, e a rotação deixaria de
	parecer aleatória para quem joga com amigos. Foi um bug de verdade na primeira
	versão do reroll — ver o histórico no README.

	Pequeno de propósito: ele multiplica um `UserId`, que já é grande. Um primo grande
	dos dois lados só empurraria a soma para perto do limite de exatidão do ponto
	flutuante sem separar nada melhor.
]=]
RoundCardShopConfig.PLAYER_SEED = 40503

--[[ O REROLL ]]

--[=[
	O developer product que rerola a vitrine: "Reroll Card Shop", 14 Robux.

	A vitrine já é de cada um (ver o topo deste arquivo), então o reroll não precisa
	inventar nada: ele só troca as três cartas **daquele** jogador. O que ele muda é a
	origem delas — em vez de saírem do sorteio do bloco, passam a sair do que ficou
	gravado no perfil, até o bloco virar.

	A contagem do `ResetText` **não** muda com o reroll: ela é o relógio da rotação
	global, e é exatamente quando a prateleira rerolada expira e o jogador volta para a
	de todo mundo. Um reroll não compra tempo, compra cartas.
]=]
RoundCardShopConfig.REROLL_PRODUCT_ID = 3712166271

--[=[
	Se o reroll deve evitar cartas que o jogador já destravou.

	`true`, e é o ponto do produto: a vitrine normal mostra carta já destravada com o
	véu `SOLD`, mas um reroll **pago** que devolvesse três cartas que o jogador já tem
	seria dinheiro por nada.

	**É melhor esforço, e não uma proibição.** O sorteio enche as três vagas com o que
	falta destravar; se faltar menos que isso, ele completa com cartas já destravadas em
	vez de devolver uma prateleira de duas. Três vagas com uma `SOLD` é uma vitrine; duas
	cartas num painel de três é uma vitrine quebrada. Ver `drawReroll`.

	Quando não falta **nada**, o botão fica desligado antes do prompt (ver
	`_refreshReroll` no controller): a hora de impedir uma compra inútil é antes de a
	Roblox cobrar.
]=]
RoundCardShopConfig.REROLL_EXCLUDES_UNLOCKED = true

--[[ PREÇOS ]]

--[=[
	A faixa de preço da loja, em shards. Nenhum preço sai dela.

	Ela não decide preço nenhum — quem decide é a tabela `PRICES` abaixo. O que ela faz
	é **prender** o que estiver escrito lá: um `12` digitado por engano vira 8, e um
	`0` vira 4. A loja nunca chega ao jogador com um preço fora da escala combinada,
	por mais que alguém erre a tecla.

	4 a 8 contra o que uma run paga hoje (ver `WinShards` em `Config.Difficulty`: 1
	no Fácil, 5 no Nightmare): a carta mais barata é uma run de Nightmare, e a mais
	cara são quase duas. É de propósito que a escala seja essa — destravar uma carta é
	permanente, e o jogador tem vinte e tantas para colecionar.
]=]
RoundCardShopConfig.MIN_PRICE = 4
RoundCardShopConfig.MAX_PRICE = 8

--[=[
	**O preço de cada carta, em shards. É esta tabela que manda.**

	Uma linha por carta do `RoundCardConfig`, agrupadas pelo que custam. Mexer no preço
	de uma carta é mexer no número dela aqui, e mais nada — nenhuma outra parte do
	código calcula preço.

	A ordem dos grupos é a do custo, e não a do catálogo, porque a pergunta que se faz
	nesta tabela é quase sempre "o que custa 7?" e não "quanto custa a Trumpet?". Ver o
	preço de uma carta continua sendo um Ctrl+F pelo `Id`.

	## A escala

	Os números de hoje seguem o que a carta custa em caixa **dentro da partida** (o
	`Price` dela no `RoundCardConfig`, que vai de 150 a 500): o que é caro no round é
	caro para destravar. Não é uma regra que o código imponha — é só de onde a primeira
	versão desta tabela saiu, e qualquer número aqui pode ser mudado sozinho sem
	quebrar nada.

	A distribuição atual é um sino: uma carta em cada ponta e o miolo entre 5 e 7. Se a
	intenção for usar mais os extremos, é aqui que se faz.

	## Carta nova

	Carta que exista no `RoundCardConfig` e **não** esteja aqui não quebra a loja: ela
	cai no `priceOf`, que estica o custo de partida dela na faixa `MIN_PRICE..MAX_PRICE`
	e devolve um número plausível. Isso é uma rede, e não o caminho — carta nova merece
	uma linha aqui, decidida por quem está balanceando.

	Todo preço, escrito ou calculado, passa pela faixa acima antes de chegar à tela.
]=]
RoundCardShopConfig.PRICES = {
	-- A mais barata do catálogo. Ela não muda estatística nenhuma: só arrasta uma
	-- torre de lugar.
	Zippers = 4,

	TimeAcceleration = 5,
	Iceolated = 5,
	ChillOut = 5,
	FireHazard = 5,
	NoPainNoGain = 5,
	BloxyCola = 5,
	Bloxiade = 5,

	TimeStop = 6,
	WeatherReport = 6,
	Overcharge = 6,
	PunchLine = 6,
	Axecellent = 6,
	Abrakadabra = 6,
	IceToMeetYou = 6,
	StaffOfHealing = 6,

	MoneyBag = 7,
	Trumpet = 7,
	WattsUp = 7,
	CleaveItToMe = 7,
	AzureEverIce = 7,
	RobuxRoyaltyStaff = 7,
	WindsStaff = 7,

	-- O topo, sozinho: é a carta mais cara da partida (500 de caixa) com folga sobre a
	-- segunda.
	CelestialStaff = 8,
}

-- A moeda, como chave de `Data.Stats`. A loja de caixas cobra em duas (ver
-- `ShopConfig.CURRENCIES`); esta cobra numa só, e o ícone dela já está autorado
-- dentro do botão `Buy`.
RoundCardShopConfig.CURRENCY = "Shards"

--[[ TEXTO ]]

-- O número do preço no `Buy.TextLabel`. Só o número: o ícone da moeda está ao lado
-- dele, e repetir a palavra roubaria largura da única parte que muda de carta para
-- carta. O mesmo acordo do `ShopConfig.PRICE_FORMAT`.
RoundCardShopConfig.PRICE_FORMAT = "%s"

-- O `ResetText`, com a contagem já formatada em `h:mm:ss`.
RoundCardShopConfig.RESET_FORMAT = "RESETS IN: %s"

--[[ O QUE O JOGADOR NOVO JÁ TEM ]]

--[=[
	As cartas que um perfil novo nasce com destravadas.

	As três originais, e por dois motivos. O primeiro é que sem nenhuma carta a
	oferta de round **não abre**: um jogador novo veria a loja de round nunca
	aparecer e não teria como ligar isso a uma loja no lobby que ele ainda não
	visitou. O segundo é precedente — o `Units` do template já entrega Slasher,
	Sword e Slingshot pela mesma razão: o jogo se apresenta com um pouco de tudo e
	guarda o resto para ser conquistado.

	São as três instantâneas de sempre, que não pedem alvo nenhum: elas são o que a
	loja de round sempre foi antes de o catálogo crescer, então o jogador aprende o
	fluxo com as cartas que ele consegue usar sem aprender mira.

	Esvaziar esta lista fecha a oferta de round para quem nunca comprou nada — é uma
	linha, e é uma decisão de design, não um efeito colateral.
]=]
RoundCardShopConfig.STARTER_CARDS = {
	"TimeStop",
	"TimeAcceleration",
	"WeatherReport",
}

--[[ API ]]

--[=[
	O `RoundCards` de um perfil novo: `{ [Id da carta] = true }`.

	É o que o `Data.Template` guarda. Carta nova em `STARTER_CARDS` **não** entra nos
	perfis antigos: o reconcile do `DataService` só cria a chave que falta, e quem já
	tem um `RoundCards` fica com o dele. É o comportamento certo — a lista é o kit de
	quem chega, e não um presente retroativo.
]=]
function RoundCardShopConfig.createEmpty() : { [string]: boolean }
	local unlocked = {}

	for _, cardId in RoundCardShopConfig.STARTER_CARDS do
		if RoundCardConfig.Get(cardId) then
			unlocked[cardId] = true
		else
			warn(`[RoundCardShopConfig]: STARTER_CARDS cita '{cardId}', que não está no RoundCardConfig.`)
		end
	end

	return unlocked
end

--[=[
	O `RoundCardRoll` de um perfil novo: nenhum reroll, em bloco nenhum.

	`Cards` é a prateleira rerolada, **gravada**: os `Id` sorteados, na ordem em que a
	loja os mostra. `Index` diz a que bloco de quatro horas ela pertence e `Rolls` é o
	contador de rerolls comprados nele.

	## Por que a prateleira é gravada, e não recalculada

	A primeira versão não gravava nada: ela sorteava com uma semente feita de (bloco,
	jogador, nº de rerolls), e assim a prateleira se reconstruía igual em qualquer
	servidor sem ocupar espaço no perfil. **Isso estava errado**, e de um jeito
	explorável.

	O sorteio do reroll varre só o que o jogador ainda não tem
	(`REROLL_EXCLUDES_UNLOCKED`), e essa pool encolhe quando ele compra — inclusive
	quando ele compra uma carta da própria prateleira rerolada. Com a prateleira sendo
	recalculada, comprar uma das três a tirava da pool, o sorteio corria de novo e a
	vaga **se enchia com uma carta nova** em vez de ficar `SOLD`. Um reroll só dava
	acesso ao catálogo inteiro, uma compra de cada vez.

	A vitrine normal **não** tem esse problema mesmo sendo calculada: ela sorteia do
	catálogo inteiro, que não muda quando o jogador compra. É a pool do reroll que
	encolhe, e é por isso que só ele precisa ser gravado.

	Uma prateleira é um resultado, e não uma fórmula: a fórmula tinha um ingrediente que
	o próprio jogador mexe. Três strings no perfil resolvem isso e são mais simples do
	que qualquer semente.

	`Index = -1` e não `0` porque `0` é um bloco de verdade (1º de janeiro de 1970): o
	perfil novo tem de nascer sem reroll nenhum, e não com um reroll de um bloco que a
	aritmética pode reencontrar.
]=]
function RoundCardShopConfig.createEmptyRoll() : { Index : number, Rolls : number, Cards : { string } }
	return { Index = -1, Rolls = 0, Cards = {} }
end

--[=[
	Quantos rerolls este perfil comprou **no bloco `index`**.

	Zero quando o `RoundCardRoll` é de um bloco anterior: o reroll vale até a rotação
	virar, e a virada é o que devolve o jogador ao sorteio do bloco. Nada precisa apagar o
	registro velho — ele deixa de valer sozinho quando o número do bloco muda.
]=]
function RoundCardShopConfig.rollsOf(profile : any, index : number) : number
	local roll = typeof(profile) == "table" and profile.RoundCardRoll
	if typeof(roll) ~= "table" or roll.Index ~= index then
		return 0
	end

	return math.max(math.floor(tonumber(roll.Rolls) or 0), 0)
end

--[=[
	A prateleira que este perfil rerolou **no bloco `index`**: os `Id` gravados, na
	ordem.

	Vazia quando o `RoundCardRoll` é de um bloco anterior — o reroll vale até a rotação
	virar, e a virada é o que devolve o jogador ao sorteio do bloco novo. Nada precisa apagar o
	registro velho: ele deixa de valer sozinho quando o número do bloco muda.

	Devolve uma lista nova, e não a do perfil: quem chama monta a vitrine em cima dela e
	não pode acabar escrevendo no que está gravado.
]=]
function RoundCardShopConfig.rolledCardsOf(profile : any, index : number) : { string }
	local roll = typeof(profile) == "table" and profile.RoundCardRoll
	if typeof(roll) ~= "table" or roll.Index ~= index or typeof(roll.Cards) ~= "table" then
		return {}
	end

	local cards = {}
	for _, cardId in roll.Cards do
		if typeof(cardId) == "string" then
			table.insert(cards, cardId)
		end
	end

	return cards
end

--[=[
	Uma lista de `Id` virada em entradas de vitrine: `{ { Id, Price } }`.

	`Id` que não é carta nenhuma é descartado com aviso, em vez de virar uma vaga que a
	tela não sabe desenhar. Acontece quando uma carta sai do `RoundCardConfig` depois de
	já ter sido sorteada para alguém — a prateleira dele encolhe até a rotação virar, o
	que é melhor do que uma carta fantasma à venda.
]=]
function RoundCardShopConfig.entriesFor(cardIds : { string }) : { { Id : string, Price : number } }
	local entries = {}

	for _, cardId in cardIds do
		if RoundCardConfig.Get(cardId) then
			table.insert(entries, {
				Id = cardId,
				Price = RoundCardShopConfig.priceOf(cardId),
			})
		else
			warn(`[RoundCardShopConfig]: a prateleira guardou '{cardId}', que não está mais no catálogo.`)
		end
	end

	return entries
end

--[=[
	As cartas que este perfil destravou: `{ [Id] = true }`.

	Perfil que ainda não carregou vale como vazio, e não como erro — o mesmo acordo
	do `IndexConfig.entriesOf`: enquanto o dado não chegou, o jogador conta como quem
	não tem nada, que é o estado que a tela sabe desenhar.
]=]
function RoundCardShopConfig.unlockedOf(profile : any) : { [string]: boolean }
	local unlocked = typeof(profile) == "table" and profile.RoundCards

	return typeof(unlocked) == "table" and unlocked or {}
end

--- Se o perfil já destravou esta carta.
function RoundCardShopConfig.isUnlocked(profile : any, cardId : any) : boolean
	if typeof(cardId) ~= "string" then
		return false
	end

	return RoundCardShopConfig.unlockedOf(profile)[cardId] == true
end

--[=[
	O que a loja cobra por esta carta, em shards.

	**Primeiro a `PRICES`.** É ela quem decide; o resto desta função só existe para a
	carta que ainda não tem linha lá.

	O cálculo de reserva estica o custo de partida da carta na faixa
	`MIN_PRICE..MAX_PRICE` contra os extremos do **catálogo**, e não contra números
	escritos aqui: uma carta nova de 600 empurra o topo, e as outras continuam
	distribuídas entre 4 e 8 em vez de todas grudarem no teto. Catálogo de preço único
	(ou de uma carta só) cai no piso — sem faixa para esticar não há o que distinguir, e
	cobrar o teto de todas seria a loja mais cara possível por acidente.

	`Id` que não é carta nenhuma (ele chega da rede) vale o piso. As duas pontas chamam
	esta mesma função — o cliente para escrever o número no botão, o servidor para
	cobrar —, então o preço na tela é o preço cobrado porque é a mesma conta, e não
	porque alguém lembrou de atualizar os dois.
]=]
function RoundCardShopConfig.priceOf(cardId : any) : number
	local min = RoundCardShopConfig.MIN_PRICE
	local max = RoundCardShopConfig.MAX_PRICE

	local override = typeof(cardId) == "string" and RoundCardShopConfig.PRICES[cardId]
	if typeof(override) == "number" then
		return math.clamp(math.floor(override + 0.5), min, max)
	end

	local card = RoundCardConfig.Get(cardId)
	if not card then
		return min
	end

	local lowest, highest = math.huge, -math.huge
	for _, entry in RoundCardConfig.Cards do
		local price = tonumber(entry.Price) or 0

		lowest = math.min(lowest, price)
		highest = math.max(highest, price)
	end

	local price = tonumber(card.Price) or 0
	local span = highest - lowest

	if span <= 0 then
		return min
	end

	local scaled = min + ((price - lowest) / span) * (max - min)

	return math.clamp(math.floor(scaled + 0.5), min, max)
end

--[=[
	O número do bloco de quatro horas em que `now` cai.

	`now` é `os.time()` — segundos de UTC —, então o número é o mesmo em qualquer
	servidor no mesmo instante. É ele, e só ele, que decide qual vitrine está de pé.
]=]
function RoundCardShopConfig.rotationIndex(now : number?) : number
	local seconds = tonumber(now) or os.time()

	return math.floor(seconds / RoundCardShopConfig.ROTATION_SECONDS)
end

--- Quando o bloco atual acaba, em segundos de UTC.
function RoundCardShopConfig.resetsAt(now : number?) : number
	local index = RoundCardShopConfig.rotationIndex(now)

	return (index + 1) * RoundCardShopConfig.ROTATION_SECONDS
end

--- Quantos segundos faltam para a vitrine trocar. Nunca negativo.
function RoundCardShopConfig.secondsUntilReset(now : number?) : number
	local seconds = tonumber(now) or os.time()

	return math.max(RoundCardShopConfig.resetsAt(seconds) - seconds, 0)
end

--[=[
	A contagem como ela vai para o `ResetText`: `3:07:41`.

	Hora sem zero à esquerda e minuto e segundo com dois dígitos — é o que estava
	autorado no Studio (`RESETS IN: 4:00:00`), e a largura do texto não muda ao longo
	do bloco por causa disso.

	Sem tratamento de dias porque a rotação é de quatro horas: a contagem nunca passa
	de `3:59:59`.
]=]
function RoundCardShopConfig.formatCountdown(seconds : number?) : string
	local total = math.max(math.floor(tonumber(seconds) or 0), 0)

	local hours = total // 3600
	local minutes = (total % 3600) // 60

	return string.format("%d:%02d:%02d", hours, minutes, total % 60)
end

--[=[
	Sorteia uma vitrine a partir de uma semente. É o motor das duas: a global e a do
	reroll.

	O sorteio é o do `RoundCardConfig.Draw` — sem repetir e com peso, o mesmo da oferta
	de round —, só que com um `Random` semeado. Daí a reprodutibilidade: mesma semente,
	mesmas três cartas, em qualquer servidor e a qualquer momento.

	A semente entra dobrada em 2^31 porque `Random.new` aceita qualquer inteiro, mas os
	produtos que a alimentam passam de 2^53 em índices altos — e a partir dali eles
	deixam de ser exatos em ponto flutuante, o que faria dois servidores arredondarem a
	mesma conta para valores diferentes e sortearem vitrines diferentes.
]=]
local function drawStock(seed : number, pool : { any }?) : { { Id : string, Price : number } }
	local rng = Random.new(seed % 2147483647)

	local drawn = RoundCardConfig.Draw(RoundCardShopConfig.STOCK_COUNT, pool, rng)

	local stock = {}
	for _, card in drawn do
		table.insert(stock, {
			Id = card.Id,
			Price = RoundCardShopConfig.priceOf(card.Id),
		})
	end

	return stock
end

--[=[
	A vitrine de `userId` no bloco `index`: `STOCK_COUNT` cartas, sempre as mesmas para
	o mesmo par — e diferentes das de qualquer outro jogador no mesmo bloco.

	Reprodutível de propósito: é o que permite não guardar nada. Qualquer servidor, a
	qualquer momento do bloco, chega nas mesmas três cartas para aquela pessoa, então
	sair e voltar (ou cair em outro lobby) não troca a oferta debaixo dela.

	`pool` é a lista de cartas que a loja pode vender; sem ela, o catálogo inteiro. **Ela
	tem de ser a mesma entre duas chamadas** — o catálogo, e não o que falta ao jogador
	destravar. Ver o comentário sobre a pool no topo do arquivo.

	Devolve `{ { Id, Price } }`, na ordem em que a vitrine as mostra.
]=]
function RoundCardShopConfig.stockFor(
	index : number,
	userId : number,
	pool : { any }?
) : { { Id : string, Price : number } }
	local seed = (tonumber(index) or 0) * RoundCardShopConfig.ROTATION_SEED
		+ (tonumber(userId) or 0) * RoundCardShopConfig.PLAYER_SEED

	return drawStock(seed, pool)
end

--[=[
	Sorteia a prateleira de um reroll: `locked` primeiro, e `unlocked` só para completar.

	As três vagas são preenchidas com o que o jogador **ainda não tem**. Sobrando vaga —
	porque faltavam menos de três cartas —, o resto sai das que ele já tem, e essas
	chegam com o véu `SOLD`. É o "melhor esforço" do `REROLL_EXCLUDES_UNLOCKED`: três
	vagas com uma `SOLD` é uma vitrine, e duas cartas num painel de três é uma vitrine
	quebrada.

	As duas pools são disjuntas (é o que o `splitByUnlocked` garante), então os dois
	sorteios não têm como repetir uma carta entre si.

	Sem semente: o resultado é **gravado** no perfil (ver `createEmptyRoll`), então ele
	não precisa ser reproduzível — precisa ser imprevisível.
]=]
function RoundCardShopConfig.drawReroll(locked : { any }, unlocked : { any }?) : { string }
	local ids = {}

	for _, card in RoundCardConfig.Draw(RoundCardShopConfig.STOCK_COUNT, locked) do
		table.insert(ids, card.Id)
	end

	local missing = RoundCardShopConfig.STOCK_COUNT - #ids
	if missing <= 0 or typeof(unlocked) ~= "table" then
		return ids
	end

	for _, card in RoundCardConfig.Draw(missing, unlocked) do
		table.insert(ids, card.Id)
	end

	return ids
end

--[=[
	Parte uma pool em duas, pelo que este perfil já destravou: `locked, unlocked`.

	É o que o reroll usa — ele enche as vagas com `locked` e só completa com `unlocked`
	(ver `drawReroll`). As duas são disjuntas e juntas somam a pool de entrada, então
	nada se perde nem aparece duas vezes.

	Com `REROLL_EXCLUDES_UNLOCKED` desligado, tudo cai em `locked` e o reroll volta a
	sortear do catálogo inteiro sem distinguir nada.
]=]
function RoundCardShopConfig.splitByUnlocked(profile : any, pool : { any }) : ({ any }, { any })
	if not RoundCardShopConfig.REROLL_EXCLUDES_UNLOCKED then
		return pool, {}
	end

	local unlocked = RoundCardShopConfig.unlockedOf(profile)
	local locked, owned = {}, {}

	for _, card in pool do
		if unlocked[card.Id] then
			table.insert(owned, card)
		else
			table.insert(locked, card)
		end
	end

	return locked, owned
end

export type StockEntry = {
	Id : string,
	Price : number,
}

export type Stock = {
	-- O bloco de quatro horas a que esta vitrine pertence. É ele que o servidor
	-- confere na compra: um clique de uma vitrine que já virou não compra nada.
	Index : number,

	-- Quando ela troca, em segundos de UTC.
	ResetsAt : number,

	-- Quantos rerolls este jogador comprou neste bloco. Zero é a vitrine sorteada do
	-- bloco. O cliente compara `Index` **e** `Rolls` para saber se a prateleira mudou:
	-- um reroll não muda o bloco, e sem este número as cartas novas chegariam sem serem
	-- desenhadas.
	--
	-- Uma vitrine rerolada pode ter menos de `STOCK_COUNT` cartas, quando faltavam
	-- menos que isso para o jogador destravar.
	Rolls : number,

	Cards : { StockEntry },
}

return RoundCardShopConfig
