local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local KeyframeSequenceProvider = game:GetService("KeyframeSequenceProvider")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)

local Me = require(Vendor.Me)

local Framework = Me.new()

local RoundCardConfig = SharedConfig.RoundCardConfig
local RoundCardShopConfig = SharedConfig.RoundCardShopConfig

--[[
	Quanto o `EffectDelay` pode se afastar do marcador da animacao antes de virar
	aviso, em segundos. Ver `_auditVisualDelays`.

	Nao e zero porque o numero do config e escrito a mao, arredondado do que o Moon
	Animator mostra: um milesimo de diferenca e transcricao, e nao desencontro.
]]
local EFFECT_DELAY_TOLERANCE = 0.05

--[=[
	A loja de cartas de round.

	De X em X waves (o intervalo e por dificuldade, ver `RoundCardConfig.Intervals`)
	cada jogador recebe uma oferta propria de tres cartas sorteadas. Comprar tira o
	dinheiro do caixa da partida (`MobService.SessionCash`, o mesmo que paga torre)
	e poe a carta na hotbar dele; usar gasta a carta e dispara o efeito.

	**Tudo que decide alguma coisa mora aqui.** O cliente nao sorteia, nao cobra e
	nao executa efeito nenhum -- ele manda "quero comprar a carta X da oferta com
	token T" e "quero usar a carta de id U", e o servidor confere as duas coisas
	contra o que ele mesmo guardou. Uma carta que o jogador nao tem, ou uma oferta
	que ja fechou, simplesmente nao produz nada.

	**A oferta e por jogador.** O caixa da partida e individual, entao um sorteio
	comum faria a mesma carta ser disputada entre pessoas que nao competem por
	dinheiro. Cada um sorteia o seu, compra o seu e usa o seu -- mas o **efeito** e
	da sala: o Time Stop para os inimigos de todo mundo.

	**E a pool tambem e por jogador.** O sorteio nao varre o catalogo: ele varre o que
	aquele jogador destravou na loja de cartas do lobby (`Data.RoundCards`, ver o
	`RoundCardShopService`). Antes ele varria o `RoundCardConfig.Cards` inteiro, ou
	seja, todo mundo tinha as vinte e tantas cartas na primeira partida -- e a loja do
	lobby nao teria o que vender.

	**A oferta fecha na compra.** Uma compra por abertura: e por isso que o
	`Offers[userId]` sai da tabela assim que a carta e paga, e nao so na tela do
	comprador.
]=]
local CardShopService = {
	Services = {
		WaveService = {},
		MobService = {},
		DifficultyService = {},
		SpeedService = {},
		WeatherRoundService = {},
		UnitService = {},
		CardModifierService = {},

		-- Para ler o `RoundCards` do perfil: e ele que diz quais cartas este jogador pode
		-- sortear. Ver o `_poolFor`.
		DataService = {},
	},

	--[[
		A oferta aberta de cada jogador: `[UserId] = { Token, Wave, Cards = { id } }`.
		Sai da tabela na compra, no fim do round e quando o jogador sai.
	]]
	Offers = {},

	--[[
		As cartas compradas e ainda nao usadas:
		`[UserId] = { [uid] = cardId }`.

		O `uid` existe porque a mesma carta pode ser comprada duas vezes em ofertas
		diferentes, e usar uma nao pode gastar a outra.
	]]
	Owned = {},

	--[[
		As cartas de prazo que estao descansando: `[UserId] = { [cardId] = Token }`.

		O numero e a **ultima** abertura em que a carta ainda esta fora do sorteio daquele
		jogador. Ver o `_rest`, que escreve, e o `_poolFor`, que le.
	]]
	Resting = {},

	--[[
		As cartas de uma vez so que este jogador ja tirou da mesa: `[UserId] = { [cardId] = true }`.

		Nao ha volta nesta tabela -- ela so e esvaziada no fim do round. Ver o `_isStacking`,
		que diz quem entra aqui, e o `_spend`, que escreve.
	]]
	Spent = {},

	-- Sobe a cada abertura. E o que faz um clique atrasado numa oferta velha nao
	-- comprar nada da nova.
	Token = 0,
}

--[[ EFEITOS ]]

--[=[
	O que cada carta faz, pelo nome que o `RoundCardConfig` declara em `Effect`.

	Cada funcao recebe quem usou, os `Params` da carta e o `context` do uso (o alvo
	escolhido, o `uid` da carta gasta e o `Id` dela), e devolve a frase que vai para
	o log do servidor. Nenhuma delas conhece a loja: sao chamadas nos services que ja
	sao donos daquele estado -- o congelamento e do `MobService`, o relogio e do
	`SpeedService`, o ceu e do `WeatherRoundService`, as regras de campo sao do
	`CardModifierService` e o tabuleiro e do `UnitService`.

	**Sao sete efeitos para vinte e tantas cartas**, e nao um por carta. Quase tudo
	que uma carta de round faz e deixar uma regra valendo no campo, e a regra tem
	gramatica propria (o `CardModifier`): dai o `Modifier`, que le a lista que a
	carta declarou e a entrega ao service. Carta nova que so mexa em numeros nao
	precisa de codigo nenhum -- ela e uma entrada no `RoundCardConfig` e mais nada.

	Carta com efeito que nao exista nesta tabela e descartada do sorteio com aviso
	(ver `_pool`), em vez de virar uma carta que o jogador paga e nao faz nada.
]=]
CardShopService.Effects = {
	--[=[
		O efeito de quase todo o catalogo: por as regras da carta no campo.

		Os registros vem do config; o que o **uso** acrescenta e o alvo (a zona onde o
		jogador desenhou o anel, ou a torre que ele escolheu) e o prazo. Quem guarda,
		poda e replica e o `CardModifierService`.
	]=]
	Modifier = function(self, player : Player, params, context)
		local service = self.Services.CardModifierService
		if not service then return "sem CardModifierService" end

		local records = params.Modifiers
		if typeof(records) ~= "table" or #records == 0 then
			return "a carta nao declarou modificador nenhum"
		end

		local target = context.Target

		local zone = nil
		if target and target.Position then
			zone = { Position = target.Position, Radius = RoundCardConfig.GetRadius(context.Card) }
		end

		local applied = service:Apply(records, {
			Uid = context.Uid,
			Card = context.Card,
			Duration = params.Duration,
			Zone = zone,
			UnitId = target and target.UnitId or nil,

			-- Para o proximo anel deste jogador saber que este lugar esta ocupado. Ver o
			-- `FindZoneOverlap`.
			OwnerUserId = player.UserId,
		})

		return string.format("%d regra(s) no campo%s", applied,
			params.Duration and string.format(" por %ss", tostring(params.Duration)) or " ate o fim do round")
	end,

	--[=[
		Caixa direto na mao de quem usou.

		E do caixa da **partida** (`roundcash`), o mesmo que paga torre e que pagou a
		propria carta -- e nao o `Cash` do perfil. Uma carta de round nao pode virar
		uma torneira de moeda de progressao.
	]=]
	GrantCash = function(self, player : Player, params)
		local mobService = self.Services.MobService
		if not mobService then return "sem MobService" end

		local amount = math.max(0, params.Amount or 0)
		mobService:addCash(player, amount)

		return string.format("%d de caixa para %s", amount, player.Name)
	end,

	--[=[
		O Staff of Healing: tira o atordoamento de quem esta no circulo e deixa essas
		unidades imunes por alguns segundos.

		Vale para as torres de **todo mundo** dentro do circulo, e nao so para as de
		quem usou. E a mesma regra do resto das cartas: quem paga e uma pessoa, mas o
		efeito e da sala.
	]=]
	Cleanse = function(self, player : Player, params, context)
		local unitService = self.Services.UnitService
		if not unitService then return "sem UnitService" end

		local target = context.Target
		if not target or not target.Position then return "sem area escolhida" end

		local radius = RoundCardConfig.GetRadius(context.Card)
		local touched = unitService:CleanseUnits(target.Position, radius, params.Immunity or 0)

		--[[
			O circulo no chao enquanto a imunidade dura.

			Ele entra pelo mesmo caminho das zonas dos cajados -- um modificador com
			`Zone`, guardado no `CardModifierService` -- e por isso ele nasce, e some,
			e reaparece para quem entrou no meio da partida sem nenhum desenho proprio.
			O modificador nao mexe em estatistica nenhuma: ele **e** o anel. Ver o
			`Modifiers` desta carta no `RoundCardConfig`.
		]]
		local modifiers = self.Services.CardModifierService
		if modifiers and params.Modifiers then
			modifiers:Apply(params.Modifiers, {
				Uid = context.Uid,
				Card = context.Card,
				Duration = params.Immunity,
				Zone = { Position = target.Position, Radius = radius },
				OwnerUserId = player.UserId,
			})
		end

		return string.format("%d unidade(s) curadas e imunes por %ss", touched, tostring(params.Immunity or 0))
	end,

	--[=[
		O Staff of Azure Ever Ice: a sala inteira mais lenta por alguns segundos.

		O clima e lido **no uso**, e nao na compra: comprar a carta e segurar ate a
		neve chegar e a jogada, e decidir o bonus na compra tiraria a decisao do
		jogador.
	]=]
	ChillEnemies = function(self, player : Player, params)
		local mobService = self.Services.MobService
		if not mobService then return "sem MobService" end

		local slow = params.Slow or 0.5
		local brittle = nil

		local weather = mobService:GetWeather()
		if params.Weather and weather == params.Weather then
			slow = params.WeatherSlow or slow
			brittle = params.WeatherBrittle
		end

		local chilled = mobService:ChillAll(slow, params.Duration, brittle)

		return string.format("%d inimigos a -%d%% por %ss%s", chilled, math.floor(slow * 100 + 0.5),
			tostring(params.Duration), brittle and " (quebradicos)" or "")
	end,

	--[=[
		O Zippers: a unidade escolhida muda de lugar.

		O destino passa pelas mesmas conferencias do `PlaceUnit`. Recusado, o efeito
		devolve o motivo -- mas a carta **ja foi gasta**, e por isso o destino e
		conferido antes, no `Use`: quando este efeito roda, o lugar ja tinha sido
		aceito.
	]=]
	MoveUnit = function(self, player : Player, params, context)
		local unitService = self.Services.UnitService
		if not unitService then return "sem UnitService" end

		local target = context.Target
		if not target or not target.UnitId or not target.Position then
			return "faltou a unidade ou o destino"
		end

		local entry, reason = unitService:MoveUnit(target.UnitId, target.Position, target.Rotation)
		if not entry then
			return string.format("mudanca recusada (%s)", tostring(reason))
		end

		return string.format("%s mudou de lugar", entry.unitName)
	end,

	TimeStop = function(self, player : Player, params)
		local mobService = self.Services.MobService
		if not mobService then return "sem MobService" end

		local duration = params.Duration or 4
		local frozen = mobService:FreezeAll(duration)

		return string.format("%d inimigos congelados por %ss", frozen, tostring(duration))
	end,

	TimeAcceleration = function(self, player : Player, params)
		local speedService = self.Services.SpeedService
		if not speedService then return "sem SpeedService" end

		local scale = params.Scale or 3
		local duration = params.Duration or 15

		speedService:SetOverride(scale, duration)

		return string.format("partida a %sx por %ss", tostring(scale), tostring(duration))
	end,

	--[[
		A carta pula o clima **desta** wave, e nao adia o clima inteiro: uma nevasca
		de tres waves comprada na primeira volta na segunda. Ver
		`WeatherRoundService:SkipCurrentWave`.

		Sem `Params`: nao ha mais numero de waves para ajustar, e a unica wave que a
		carta conhece e a que esta no ar.
	]]
	WeatherReport = function(self, player : Player)
		local weatherRound = self.Services.WeatherRoundService
		if not weatherRound then return "sem WeatherRoundService" end

		if not weatherRound:SkipCurrentWave() then
			return "nao havia clima no ar"
		end

		return "ceu limpo nesta wave"
	end,
}

--[[ INTERNAL ]]

--[=[
	As cartas que este servidor sabe executar: as do catalogo cujo `Effect` existe de
	fato.

	E o primeiro dos dois filtros do sorteio, e o unico que fala do **jogo**: uma carta
	sem efeito registrado nao pode sair para ninguem. O aviso sai uma vez por carta
	quebrada, e nao a cada sorteio: config escrito a mao erra nome, e uma carta que o
	jogador paga e nao faz nada e pior do que uma carta que nunca aparece.
]=]
function CardShopService:_pool()
	local pool = {}

	for _, card in RoundCardConfig.Cards do
		if self.Effects[card.Effect] then
			table.insert(pool, card)
			continue
		end

		if not self.WarnedEffects[card.Id] then
			self.WarnedEffects[card.Id] = true
			warn(string.format("[CardShopService]: a carta '%s' pede o efeito '%s', que nao existe em Effects.",
				card.Id, tostring(card.Effect)))
		end
	end

	return pool
end

--[=[
	A carta e de prazo?

	E a pergunta que decide quem descansa depois de usada, e a resposta e o proprio
	`Params.Duration`: a carta cujo efeito **vence sozinho** e uma janela, e a que nao
	tem prazo e uma decisao que vale o round inteiro.

	A regra e derivada do config, e nao uma lista escrita a mao, de proposito: carta
	nova com `Duration` ja nasce descansando, e uma carta que perde o prazo num ajuste
	de balanceamento para de descansar no mesmo commit. Uma lista paralela divergiria
	do catalogo no primeiro numero que alguem mexesse.
]=]
function CardShopService:_isTemporary(card) : boolean
	local duration = card and card.Params and card.Params.Duration

	return typeof(duration) == "number" and duration > 0
end

--[=[
	Poe a carta para descansar uma abertura na mao deste jogador.

	O prazo e escrito em **aberturas da loja**, e nao em waves ou em segundos: o que a
	regra promete e "nao sai na proxima oferta", e a proxima oferta e a proxima vez que
	o `Open` roda -- numa dificuldade de intervalo 6 isso e mais tempo do que numa de
	4, que e exatamente o certo, porque a oferta e o recurso escasso, e nao o relogio.

	`Token + 1` e a abertura seguinte a esta, e a comparacao do `_poolFor` e `<=`:
	usada depois da oferta da wave 4 (Token 1), a carta fica fora da wave 8 (Token 2) e
	volta na wave 12 (Token 3).

	Descansa **por jogador**, junto com a pool: quem usou o Time Stop nao o ve na
	proxima oferta, e quem nao usou continua podendo sortea-lo.
]=]
function CardShopService:_rest(player : Player, cardId : string)
	local resting = self.Resting[player.UserId]
	if not resting then
		resting = {}
		self.Resting[player.UserId] = resting
	end

	resting[cardId] = self.Token + 1
end

--[=[
	A carta empilha em cima de si mesma para sempre?

	Sao tres coisas ao mesmo tempo, e a resposta cai do proprio config:

	1. o efeito dela e uma **regra no campo** (`Effect = "Modifier"`) -- e a lista do
	   `CardModifierService` aceita duas copias do mesmo registro, que se multiplicam;
	2. ela **nao tem prazo**, entao a regra vale ate o fim do round;
	3. ela **nao desenha area**, entao o que ela muda e o mapa inteiro.

	As tres juntas sao o unico caso em que comprar a mesma carta de novo e sempre a
	melhor jogada possivel: o Overcharge duas vezes e 1.56x de dano em Electric, tres
	vezes e 1.95x, e nada no jogo freia isso. A que tem prazo se resolve sozinha (ela
	vence), a de area se resolve pelo chao (duas nao podem se tocar) e a que nao e
	`Modifier` nao empilha regra nenhuma -- o Money Bag da dinheiro, o Zippers move uma
	torre, o Weather Report limpa o ceu de uma wave.

	Quem responde sim sai do sorteio daquele jogador **na compra**, e nao volta nesta
	partida. Ver o `_spend`.
]=]
function CardShopService:_isStacking(card) : boolean
	if not card or card.Effect ~= "Modifier" then return false end
	if self:_isTemporary(card) then return false end

	local records = card.Params and card.Params.Modifiers
	if typeof(records) ~= "table" then return false end

	for _, record in records do
		if record.Zone then return false end
	end

	return true
end

--[=[
	Tira a carta da mesa deste jogador pelo resto da partida.

	Chamado na **compra**, e nao so no uso: a carta comprada e uma decisao ja tomada,
	mesmo que ela passe a wave inteira na hotbar. Sem isso o jogador guardaria tres
	copias do Overcharge na mao e as usaria de uma vez -- que e exatamente o
	empilhamento que a regra tira do jogo.

	Chamado tambem no uso, para o caso de uma carta ter chegado a mao por fora da loja
	(um comando de Cmdr, um presente). E barato, e escrever `true` duas vezes na mesma
	chave nao custa nada.

	Vale a partida, e nao o perfil: a proxima partida comeca com a mesa limpa, do mesmo
	jeito que o caixa e a hotbar. Ver o `ResetRound`.
]=]
function CardShopService:_spend(player : Player, cardId : string)
	local spent = self.Spent[player.UserId]
	if not spent then
		spent = {}
		self.Spent[player.UserId] = spent
	end

	spent[cardId] = true
end

--[=[
	As cartas que **este jogador** pode sortear: as de `_pool` que ele destravou na loja
	de cartas do lobby.

	O segundo filtro, e o unico que fala do **jogador**. O que ele destravou mora no
	`RoundCards` do perfil e e escrito la, no Lobby, pelo `RoundCardShopService` -- aqui
	so se le.

	Perfil que ainda nao carregou vale como vazio, e nao como catalogo inteiro: liberar
	tudo enquanto o dado nao chegou daria ao jogador uma oferta que ele nao pagou, e a
	primeira wave de loja e cedo o bastante para a corrida acontecer de verdade.

	Carta de prazo que ele acabou de usar fica de fora desta abertura (ver o `_rest`):
	ela esta destravada, mas descansando. Nao ha aviso na tela -- de uma oferta de tres
	cartas nao da para deduzir quais nao foram sorteadas, e a carta volta sozinha.

	Carta de uma vez so que ele ja comprou fica de fora **do resto da partida** (ver o
	`_spend`). Essa nao volta: a pool dele encolhe conforme ele monta a build, e e isso
	que faz cada uma dessas cartas ser uma escolha em vez de um numero para repetir.

	Pool vazia nao e erro: e o jogador que gastou os shards em outra coisa e nao tem
	carta nenhuma destravada. A oferta simplesmente nao abre para ele -- ver o `Open`.
]=]
function CardShopService:_poolFor(player : Player, pool : { any })
	local dataService = self.Services.DataService
	local profiles = dataService and dataService.Profiles
	local entry = profiles and profiles[player]
	local profile = entry and entry.Profile.Data or nil

	local unlocked = RoundCardShopConfig.unlockedOf(profile)
	local resting = self.Resting[player.UserId] or {}
	local spent = self.Spent[player.UserId] or {}
	local candidates = {}

	for _, card in pool do
		if not unlocked[card.Id] then continue end
		if spent[card.Id] then continue end

		-- O numero e a ultima abertura em que ela ainda descansa, e esta e a de agora.
		local restingUntil = resting[card.Id]
		if restingUntil and self.Token <= restingUntil then continue end

		table.insert(candidates, card)
	end

	return candidates
end

--[=[
	Confere o alvo que o cliente mandou contra o tipo de uso da carta. Devolve o
	alvo ja limpo, ou `nil` e o motivo.

	O cliente escolhe o alvo, e por isso **nada** do que ele manda entra sem passar
	por aqui: um `Id` de unidade que nao existe, um ponto a dez mil studs daqui, um
	`Vector3` que na verdade e uma string. Nenhum desses e erro de programa -- e o
	que chega de um cliente adulterado, e o que chega de um clique legitimo numa
	torre que foi vendida no mesmo quadro.

	O alvo devolvido e **remontado**, campo por campo, em vez de repassado: assim
	nada mais do que estas duas chaves atravessa para o efeito, por mais que o
	cliente tenha enfiado na tabela.

	A ultima conferencia de uma carta de area e o lugar estar livre das outras areas
	**deste jogador** (ver `CardModifierService:FindZoneOverlap`). Ela e feita aqui, e
	nao dentro do efeito, pelo mesmo motivo das outras: alvo recusado nao gasta a
	carta, e o jogador volta para a mira com ela ainda na mao.
]=]
function CardShopService:_checkTarget(player : Player, card, target : any)
	local use = RoundCardConfig.GetUse(card.Id)

	if use == RoundCardConfig.Use.Instant then
		return {}
	end

	if typeof(target) ~= "table" then
		return nil, "sem alvo"
	end

	local checked = {}

	if use == RoundCardConfig.Use.Unit or use == RoundCardConfig.Use.Move then
		local unitService = self.Services.UnitService
		if not unitService then
			return nil, "sem UnitService"
		end

		if typeof(target.UnitId) ~= "string" or not unitService.UnitsById[target.UnitId] then
			return nil, "unidade fora do mapa"
		end

		checked.UnitId = target.UnitId
	end

	if use == RoundCardConfig.Use.Area or use == RoundCardConfig.Use.Move then
		local position = target.Position

		if typeof(position) ~= "Vector3" then
			return nil, "sem posicao"
		end

		-- NaN passa por qualquer comparacao de tamanho, entao ele e pego pelo unico
		-- teste que ele nao passa: ser igual a si mesmo.
		if position.X ~= position.X or position.Y ~= position.Y or position.Z ~= position.Z then
			return nil, "posicao NaN"
		end

		if position.Magnitude > RoundCardConfig.Targeting.MaxDistance then
			return nil, "posicao longe demais"
		end

		checked.Position = position
	end

	--[[
		O giro que o jogador escolheu no fantasma, em radianos, so no eixo Y -- as
		torres ficam de pe, e o posicionamento nunca ofereceu outro eixo.

		Ele e **opcional**: um cliente que nao mande nada continua valendo, e a torre
		fica com o giro que ja tinha. O que nao vale e mandar lixo, e por isso o
		numero passa pelos mesmos tres testes da posicao -- ser numero, nao ser NaN e
		nao ser infinito -- antes de ser dobrado para uma volta.
	]]
	if use == RoundCardConfig.Use.Move and target.Rotation ~= nil then
		local rotation = target.Rotation

		if typeof(rotation) ~= "number" or rotation ~= rotation or math.abs(rotation) == math.huge then
			return nil, "giro invalido"
		end

		checked.Rotation = rotation % (2 * math.pi)
	end

	--[[
		Area encostando em area, so no `Use.Area`: o `Move` tambem manda uma posicao, mas
		ela e o destino de uma torre, e nao um anel -- quem confere aquilo e o
		`PlacementUtil`, pelas regras de posicionamento.

		O cliente ja pinta a mira de vermelho aqui e nao deixa confirmar, entao chegar
		neste ramo e cliente adulterado ou corrida de verdade: duas cartas de area usadas
		no mesmo quadro, a segunda em cima da primeira.
	]]
	if use == RoundCardConfig.Use.Area then
		local modifiers = self.Services.CardModifierService
		local overlap = modifiers and modifiers:FindZoneOverlap(
			player.UserId,
			checked.Position,
			RoundCardConfig.GetRadius(card.Id)
		)

		if overlap then
			return nil, string.format("area encostando na do %s", tostring(overlap.Card))
		end
	end

	return checked
end

--- A dificuldade em uso, pelo nome. E ela que decide o intervalo da loja.
function CardShopService:_difficultyName() : string?
	local waveService = self.Services.WaveService
	local preset = (waveService and waveService.Difficulty)
		or (self.Services.DifficultyService and self.Services.DifficultyService:GetSelected())

	return preset and preset.Name
end

--- As cartas que este jogador tem na mao, como lista de `{ Uid, Id }`.
function CardShopService:_ownedList(player : Player)
	local owned = self.Owned[player.UserId]
	if not owned then return {} end

	local list = {}
	for uid, cardId in owned do
		table.insert(list, { Uid = uid, Id = cardId })
	end

	return list
end

--[=[
	O estado da loja como este jogador o ve: a oferta aberta dele (se houver) e as
	cartas que ele ja comprou e ainda nao usou.

	As duas coisas juntas de proposito: e este pacote que reconstroi a tela inteira
	de quem acabou de carregar a interface, e nao so a parte que mudou.
]=]
function CardShopService:_sendState(player : Player)
	local offer = self.Offers[player.UserId]

	Framework:Fire("RoundCardState", player, {
		token = offer and offer.Token or nil,
		wave = offer and offer.Wave or nil,
		cards = offer and offer.Cards or nil,
		owned = self:_ownedList(player),
	})
end

--[=[
	Abre uma oferta para estes jogadores. Sem lista, para a sala inteira.

	Cada um sorteia o seu, da **pool dele** (as cartas que ele destravou no lobby), mas
	o `Token` e o mesmo da abertura: e ele que invalida de uma vez as ofertas
	anteriores, inclusive as de quem nao comprou nada na rodada passada.

	Jogador sem carta destravada nao recebe oferta, e a dele e **apagada** em vez de
	deixada como estava: sem isso ele ficaria com a oferta da wave de loja anterior na
	tela, e o `Token` novo faria cada clique nela ser recusado como "oferta vencida".

	Devolve true quando pelo menos um jogador recebeu oferta.
]=]
function CardShopService:Open(players : { Player }?, waveNumber : number?)
	local pool = self:_pool()
	if #pool == 0 then
		warn("[CardShopService]: nenhuma carta com efeito registrado; a loja nao abriu.")
		return false
	end

	local waveService = self.Services.WaveService
	local wave = waveNumber or (waveService and waveService.WaveCount) or 0

	self.Token += 1

	local opened = false

	for _, player in (players or Players:GetPlayers()) do
		local candidates = self:_poolFor(player, pool)

		if #candidates == 0 then
			self.Offers[player.UserId] = nil
			self:_sendState(player)

			continue
		end

		local drawn = RoundCardConfig.Draw(RoundCardConfig.DrawCount, candidates)

		local cards = {}
		for _, card in drawn do
			table.insert(cards, card.Id)
		end

		self.Offers[player.UserId] = {
			Token = self.Token,
			Wave = wave,
			Cards = cards,
		}

		self:_sendState(player)
		opened = true
	end

	return opened
end

--[[ API ]]

--[=[
	A compra. Devolve a carta comprada e o `uid` dela, ou nil e o motivo.

	As quatro conferencias sao as quatro maneiras de o pedido estar velho ou
	torto: oferta que nao existe, oferta de outra abertura, carta que nao estava
	naquela oferta e dinheiro que nao da. Nenhuma delas e erro de programa -- e o
	que chega quando o jogador clica duas vezes rapido, quando duas abas de loja
	se cruzam ou quando alguem manda o evento na mao.
]=]
function CardShopService:Buy(player : Player, token : any, cardId : any)
	local offer = self.Offers[player.UserId]
	if not offer then
		return nil, "sem oferta aberta"
	end

	if offer.Token ~= token then
		return nil, "oferta vencida"
	end

	if not table.find(offer.Cards, cardId) then
		return nil, "carta fora da oferta"
	end

	local card = RoundCardConfig.Get(cardId)
	if not card then
		return nil, "carta desconhecida"
	end

	local mobService = self.Services.MobService
	if not mobService then
		return nil, "sem MobService"
	end

	local price = math.max(0, card.Price or 0)
	if mobService:getCash(player) < price then
		return nil, "dinheiro insuficiente"
	end

	mobService:spendCash(player, price)

	local uid = HttpService:GenerateGUID(false)
	local owned = self.Owned[player.UserId]
	if not owned then
		owned = {}
		self.Owned[player.UserId] = owned
	end
	owned[uid] = card.Id

	--[[
		A carta que empilha sai da mesa dele aqui, na compra: dai para a frente ela nao e
		mais sorteada nesta partida, tenha sido usada ou nao. Ver o `_isStacking`.
	]]
	if self:_isStacking(card) then
		self:_spend(player, card.Id)
	end

	-- Uma compra por abertura: a oferta fecha para quem comprou.
	self.Offers[player.UserId] = nil

	Framework:Fire("RoundCardBought", player, {
		token = token,
		id = card.Id,
		uid = uid,
	})

	print(string.format("[CardShopService]: %s comprou '%s' por %d.", player.Name, card.Id, price))

	return card, uid
end

--[=[
	O uso. A carta e gasta **antes** do efeito rodar: se o efeito estourar, a carta
	nao volta para a mao do jogador com o estado da sala ja meio mexido.

	**O efeito espera o gesto.** Carta com `Visual.EffectDelay` roda o efeito aquele
	tanto de segundos depois, que e o instante do marcador `VFX` da animacao: o
	congelamento cai junto com o estouro das particulas, e nao no clique. O que **nao**
	espera e nada disso: a carta sai da mao e o `RoundCardUsed` e disparado na hora,
	senao o jogador clicaria de novo achando que o primeiro clique nao pegou.

	O atraso e daqui, e nao do cliente que esta tocando a animacao. Ele e quem tem o
	marcador na mao, mas quem executa efeito e o servidor -- deixar o cliente dizer
	"agora" seria deixa-lo escolher a hora de congelar a sala inteira.

	Devolve a carta usada, ou nil e o motivo.
]=]
function CardShopService:Use(player : Player, uid : any, target : any)
	local owned = self.Owned[player.UserId]
	local cardId = owned and owned[uid]

	if not cardId then
		return nil, "carta nao esta com o jogador"
	end

	local card = RoundCardConfig.Get(cardId)
	if not card then
		owned[uid] = nil
		return nil, "carta desconhecida"
	end

	local effect = self.Effects[card.Effect]
	if not effect then
		return nil, "carta sem efeito"
	end

	--[[
		O alvo e conferido **antes** de a carta sair da mao. Errar o lugar -- clicar
		no ceu, escolher uma torre que acabou de ser vendida -- devolve a mira ao
		jogador com a carta ainda na hotbar; so um alvo aceito gasta a compra.

		E a unica coisa que e conferida antes: o resto (o efeito estourar, por
		exemplo) acontece com a carta ja gasta, de proposito, para o estado da sala
		nunca ficar meio mexido com a carta de volta na mao.
	]]
	local checked, reason = self:_checkTarget(player, card, target)
	if not checked then
		return nil, reason
	end

	owned[uid] = nil

	--[[
		A carta de prazo sai do sorteio dele por uma abertura, e e aqui que isso e
		marcado -- no **uso**, e nao na compra. Comprar e guardar na hotbar nao gastou
		janela nenhuma; o que a regra cobra e ter tido o efeito no campo.

		A que empilha ja saiu da mesa na compra, e e remarcada aqui so pelo caminho de
		fora da loja: uma carta que chegou a mao sem passar pelo `Buy` nunca viu o
		`_spend`.
	]]
	if self:_isTemporary(card) then
		self:_rest(player, card.Id)
	elseif self:_isStacking(card) then
		self:_spend(player, card.Id)
	end

	Framework:Fire("RoundCardUsed", player, {
		uid = uid,
		id = card.Id,
	})

	--[[
		O gesto vai para a sala inteira, e nao so para quem pagou.

		`RoundCardUsed` continua sendo particular porque ele mexe na **mao** de quem
		usou (tira a carta do deck dele), e isso nao e da conta de mais ninguem. O que
		e da conta de todo mundo e a cena: o Time Stop congela os inimigos da sala, e
		ate agora so o dono ouvia e via isso acontecer.

		Sai so para os outros: quem usou ja recebeu o `RoundCardUsed`, e e ele que
		dispara o gesto completo na tela dele -- animacao, trava e o marcador da
		propria animacao no comando. Mandar os dois para a mesma pessoa faria o som
		tocar duas vezes.

		A animacao em si nao viaja aqui: ela toca no personagem de quem usou, e o
		`Animator` replica isso sozinho para todo mundo. O que falta nas outras telas,
		e o que este evento leva, e o som e as particulas.
	]]
	if card.Visual then
		for _, plr in Players:GetPlayers() do
			if plr ~= player then
				Framework:Fire("RoundCardVisual", plr, {
					id = card.Id,
					user = player,
				})
			end
		end
	end

	local context = { Uid = uid, Card = card.Id, Target = checked }

	local function run()
		local ok, result = pcall(effect, self, player, card.Params or {}, context)

		if not ok then
			warn(string.format("[CardShopService]: o efeito de '%s' estourou (%s).", card.Id, tostring(result)))
			return
		end

		print(string.format("[CardShopService]: %s usou '%s' -- %s.", player.Name, card.Id, tostring(result)))

		--[[
			O estouro na torre que a carta pegou.

			Junto com o efeito, e nao no clique: carta com `EffectDelay` entra depois do
			gesto, e o estouro tem que cair com ela. E depois do efeito ter dado certo --
			um efeito que estourou nao encostou em torre nenhuma, e o estouro estaria
			prometendo uma coisa que nao aconteceu.

			Fica aqui, e nao dentro de cada efeito, porque quem sabe que a carta tinha
			uma torre por alvo e o alvo dela: um efeito novo de alvo unico ja nasce com
			o estouro sem escrever nada.

			Vai para **todos**: a carta e comprada por uma pessoa, mas a sala inteira ve
			a torre reagir.
		]]
		if checked.UnitId then
			for _, plr in Players:GetPlayers() do
				Framework:Fire("RoundCardApplied", plr, checked.UnitId)
			end
		end
	end

	--[[
		Tempo real, e nao `GameClock`: o gesto e uma animacao tocando no personagem, e
		ela nao acelera com a partida. Passar pelo relogio acelerado faria o efeito
		entrar antes do estouro justamente quando o jogo esta a 3x.
	]]
	local delay = card.Visual and card.Visual.EffectDelay

	if delay and delay > 0 then
		task.delay(delay, run)
	else
		run()
	end

	return card
end

--[=[
	Zera junto com o round. As cartas sao de partida: nao ha o que carregar para a
	proxima, nem oferta aberta que sobreviva a tela de resultado.
]=]
function CardShopService:ResetRound()
	table.clear(self.Offers)
	table.clear(self.Owned)

	-- O descanso e contado em aberturas desta partida, e a mesa e desta partida: a
	-- proxima comeca do zero, com o catalogo inteiro de volta na pool de cada um.
	table.clear(self.Resting)
	table.clear(self.Spent)

	-- As regras que as cartas deixaram no campo saem junto: um anel de cajado nao
	-- pode sobreviver a tela de resultado.
	local modifiers = self.Services.CardModifierService
	if modifiers then
		modifiers:ResetRound()
	end

	for _, player in Players:GetPlayers() do
		self:_sendState(player)
	end
end

--[[ CICLO DE VIDA ]]

--[=[
	Confere se o `EffectDelay` e o `SoundDelay` das cartas ainda batem com a animacao
	delas.

	Os numeros no config sao **copias** dos instantes dos marcadores `VFX` e `Sound`,
	e copia envelhece: reanimar a carta no Moon Animator move os marcadores e deixa o
	efeito entrando fora do gesto -- sem erro nenhum no log, so torto na tela. E o
	mesmo tipo de desencontro silencioso que os nomes dos botoes de dificuldade ja
	causaram, e a resposta e a mesma: conferir na subida e avisar.

	Os dois numeros valem para **quem nao esta tocando a animacao**: o `EffectDelay`
	cronometra o efeito aqui no servidor, e os dois cronometram o som e as particulas
	na tela de quem esta assistindo o gesto de outro jogador (o marcador so chega em
	quem carregou a track). Um desvio aqui sai como o som da sala fora do gesto do
	dono, e por isso os dois sao conferidos e nao so um.

	**So avisa.** Ele nao corrige o numero com o que baixou: cronometrar o efeito da
	sala por uma chamada web que pode falhar ou demorar seria pior do que o desvio
	que ele pega. Falha de download tambem passa calada -- o jogo nao depende dela.
]=]
function CardShopService:_auditVisualDelays()
	--[[
		Cada linha e "o campo do config" contra "o parametro do marcador que ele
		copia". Um `Visual` que declare so um dos dois e conferido so nele: o
		`SoundDelay` nao e obrigatorio, uma carta que nao toca som nao precisa dele.
	]]
	local MIRRORED = {
		{ Field = "EffectDelay", Parameter = RoundCardConfig.Markers.VFX, What = "aplica o efeito" },
		{ Field = "SoundDelay", Parameter = RoundCardConfig.Markers.Sound, What = "toca o som" },
	}

	for _, card in RoundCardConfig.Cards do
		local visual = card.Visual
		if not visual or not visual.Animation then continue end

		local ok, sequence = pcall(function()
			return KeyframeSequenceProvider:GetKeyframeSequenceAsync(visual.Animation)
		end)

		if not ok or not sequence then continue end

		for _, mirrored in MIRRORED do
			local copied = visual[mirrored.Field]
			if not copied then continue end

			local markedAt = nil
			for _, keyframe in sequence:GetKeyframes() do
				for _, marker in keyframe:GetMarkers() do
					if marker.Name == visual.Marker and marker.Value == mirrored.Parameter then
						markedAt = keyframe.Time
					end
				end
			end

			if not markedAt then
				warn(string.format(
					"[CardShopService]: a animacao de '%s' nao tem marcador '%s' com o parametro '%s'; o %s vai entrar em %.3fs sem nada acontecendo na tela.",
					card.Id, tostring(visual.Marker), mirrored.Parameter, mirrored.Field, copied))
				continue
			end

			if math.abs(markedAt - copied) > EFFECT_DELAY_TOLERANCE then
				warn(string.format(
					"[CardShopService]: '%s' %s em %.3fs, mas o marcador '%s' da animacao esta em %.3fs. Acerte o %s no RoundCardConfig.",
					card.Id, mirrored.What, copied, mirrored.Parameter, markedAt, mirrored.Field))
			end
		end
	end
end

function CardShopService:construct()
	-- Num fio proprio: ele baixa as animacoes das cartas, e a loja nao tem por que
	-- esperar isso para existir.
	task.spawn(function()
		self:_auditVisualDelays()
	end)

	local waveService = self.Services.WaveService

	if waveService and waveService.Signals and waveService.Signals.WaveStarted then
		waveService.Signals.WaveStarted:Connect(function(waveNumber, preset)
			if not RoundCardConfig.IsShopWave(waveNumber, preset and preset.Name) then return end

			self:Open(nil, waveNumber)
		end)
	else
		warn("[CardShopService]: WaveService sem o sinal WaveStarted; a loja nao vai abrir sozinha.")
	end

	Framework:Listen("BuyRoundCard", function(player : Player, token : any, cardId : any)
		local card, reason = self:Buy(player, token, cardId)

		if not card then
			-- O cliente ja tinha recolhido a loja no clique; o estado devolve a
			-- verdade para a tela dele.
			self:_sendState(player)

			print(string.format("[CardShopService]: compra de %s recusada (%s).", player.Name, tostring(reason)))
		end
	end)

	Framework:Listen("UseRoundCard", function(player : Player, uid : any, target : any)
		local card, reason = self:Use(player, uid, target)

		if not card then
			self:_sendState(player)

			print(string.format("[CardShopService]: uso de %s recusado (%s).", player.Name, tostring(reason)))
		end
	end)

	--[[
		O cliente pergunta quando termina de ligar a interface. Sem isso, quem
		recarrega a GUI no meio de uma oferta aberta so a veria na proxima abertura
		-- e as cartas ja compradas sumiriam da hotbar dele.
	]]
	Framework:Listen("RequestRoundCardState", function(player : Player)
		self:_sendState(player)
	end)

	Players.PlayerRemoving:Connect(function(player : Player)
		self.Offers[player.UserId] = nil
		self.Owned[player.UserId] = nil
		self.Resting[player.UserId] = nil
		self.Spent[player.UserId] = nil
	end)
end

function CardShopService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service)
	end

	self:construct()
end

function CardShopService:init()
	self.WarnedEffects = {}

	-- So o servidor dispara estes; sem o Listen vazio o cliente ficaria dez
	-- segundos esperando o identificador aparecer (ver o README da raiz).
	Framework:Listen("RoundCardState", function() end)
	Framework:Listen("RoundCardBought", function() end)
	Framework:Listen("RoundCardUsed", function() end)
	Framework:Listen("RoundCardVisual", function() end)
	Framework:Listen("RoundCardApplied", function() end)
end

return CardShopService
