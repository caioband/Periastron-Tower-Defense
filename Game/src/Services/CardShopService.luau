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

--[[
	Quanto o `EffectDelay` pode se afastar do marcador da animacao antes de virar
	aviso, em segundos. Ver `_auditEffectDelays`.

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

		local entry, reason = unitService:MoveUnit(target.UnitId, target.Position)
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

	WeatherReport = function(self, player : Player, params)
		local weatherRound = self.Services.WeatherRoundService
		if not weatherRound then return "sem WeatherRoundService" end

		local waves = params.Waves or 1
		local hadWeather = weatherRound:Suppress(waves)

		return string.format("ceu limpo por %d wave(s)%s", waves,
			hadWeather and "" or " (nao havia clima no ar)")
	end,
}

--[[ INTERNAL ]]

--[=[
	As cartas que podem ser sorteadas: as do catalogo cujo `Effect` existe de fato.

	O aviso sai uma vez por carta quebrada, e nao a cada sorteio: config escrito a
	mao erra nome, e uma carta que o jogador paga e nao faz nada e pior do que uma
	carta que nunca aparece.
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
]=]
function CardShopService:_checkTarget(card, target : any)
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

	Cada um sorteia o seu, mas o `Token` e o mesmo da abertura: e ele que invalida
	de uma vez as ofertas anteriores, inclusive as de quem nao comprou nada na
	rodada passada.
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

	for _, player in (players or Players:GetPlayers()) do
		local drawn = RoundCardConfig.Draw(RoundCardConfig.DrawCount, pool)

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
	end

	return true
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
	local checked, reason = self:_checkTarget(card, target)
	if not checked then
		return nil, reason
	end

	owned[uid] = nil

	Framework:Fire("RoundCardUsed", player, {
		uid = uid,
		id = card.Id,
	})

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
	Confere se o `EffectDelay` das cartas ainda bate com a animacao delas.

	O numero no config e uma **copia** do instante do marcador `VFX`, e copia
	envelhece: reanimar a carta no Moon Animator move o marcador e deixa o efeito
	entrando fora do gesto -- sem erro nenhum no log, so torto na tela. E o mesmo tipo
	de desencontro silencioso que os nomes dos botoes de dificuldade ja causaram, e a
	resposta e a mesma: conferir na subida e avisar.

	**So avisa.** Ele nao corrige o numero com o que baixou: cronometrar o efeito da
	sala por uma chamada web que pode falhar ou demorar seria pior do que o desvio
	que ele pega. Falha de download tambem passa calada -- o jogo nao depende dela.
]=]
function CardShopService:_auditEffectDelays()
	for _, card in RoundCardConfig.Cards do
		local visual = card.Visual
		if not visual or not visual.Animation or not visual.EffectDelay then continue end

		local ok, sequence = pcall(function()
			return KeyframeSequenceProvider:GetKeyframeSequenceAsync(visual.Animation)
		end)

		if not ok or not sequence then continue end

		local markedAt = nil
		for _, keyframe in sequence:GetKeyframes() do
			for _, marker in keyframe:GetMarkers() do
				if marker.Name == visual.Marker and marker.Value == RoundCardConfig.Markers.VFX then
					markedAt = keyframe.Time
				end
			end
		end

		if not markedAt then
			warn(string.format(
				"[CardShopService]: a animacao de '%s' nao tem marcador '%s' com o parametro '%s'; o efeito vai entrar em %.3fs sem nada acontecendo na tela.",
				card.Id, tostring(visual.Marker), RoundCardConfig.Markers.VFX, visual.EffectDelay))
			continue
		end

		if math.abs(markedAt - visual.EffectDelay) > EFFECT_DELAY_TOLERANCE then
			warn(string.format(
				"[CardShopService]: '%s' aplica o efeito em %.3fs, mas o marcador '%s' da animacao esta em %.3fs. Acerte o EffectDelay no RoundCardConfig.",
				card.Id, visual.EffectDelay, RoundCardConfig.Markers.VFX, markedAt))
		end
	end
end

function CardShopService:construct()
	-- Num fio proprio: ele baixa as animacoes das cartas, e a loja nao tem por que
	-- esperar isso para existir.
	task.spawn(function()
		self:_auditEffectDelays()
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

	-- So o servidor dispara estes tres; sem o Listen vazio o cliente ficaria dez
	-- segundos esperando o identificador aparecer (ver o README da raiz).
	Framework:Listen("RoundCardState", function() end)
	Framework:Listen("RoundCardBought", function() end)
	Framework:Listen("RoundCardUsed", function() end)
	Framework:Listen("RoundCardApplied", function() end)
end

return CardShopService
