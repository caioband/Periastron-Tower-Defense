local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Configs = Shared:WaitForChild("Config")
local Utils = Shared:WaitForChild("Util")

local SharedConfig = require(Configs.SharedConfig)
local GameClock = require(Utils.GameClock)

local Me = require(Vendor.Me)

local Framework = Me.new()

local CardModifier = SharedConfig.CardModifier

--[=[
	As regras que as cartas de round deixaram valendo no campo.

	Uma carta de round quase nunca faz uma coisa e acaba -- ela muda como a partida
	funciona dali em diante. O Trumpet acelera todo mundo, o Overcharge separa
	Electric do resto, o cajado desenha um anel onde a regra so vale la dentro e o
	Bloxy Cola dobra a cadencia de uma torre por dez segundos. Este service e a
	lista dessas regras: quem entra, quando sai e quem precisa saber.

	**A gramatica nao mora aqui.** Quem responde "este modificador vale para esta
	unidade, e quanto?" e o `CardModifier`, que e compartilhado justamente porque as
	duas pontas precisam da mesma resposta: o servidor cobra o dano por ele, e o
	circulo de alcance que o jogador ve na tela sai da mesma conta. Aqui so mora o
	**estado**: a lista viva, o prazo de cada um e a replicacao.

	## O prazo

	Modificador com `Duration` ganha um `ExpiresAt` no relogio da **partida**, e nao
	no real: os dez segundos do Bloxy Cola sao dez segundos de jogo, entao acelerar
	para 3x encurta o buff junto com todo o resto -- do mesmo jeito que o
	atordoamento, a carga do raio e o Time Stop.

	Sem `Duration` o modificador vale ate o fim do round. E o padrao de propriedade:
	um buff de campo comprado com o caixa da partida e uma decisao de build, e um
	prazo curto transformaria toda carta de regra numa versao pior das bebidas.

	## A replicacao

	O cliente recebe a lista inteira a cada mudanca, e nao um "entrou X". Sao poucos
	registros (uma partida cheia tem uma duzia), e a lista completa e o unico jeito
	de quem entra no meio da partida -- ou de quem recarrega a interface -- ver o
	mesmo campo que o servidor ve. O mesmo motivo do `_sendState` do `CardShopService`.

	Ele precisa dela para duas coisas: desenhar o anel dos cajados no chao e mostrar
	no card o alcance que a torre tem de verdade.
]=]
local CardModifierService = {
	Services = {
		MobService = {},
	},

	--[[
		Os modificadores valendo agora. E uma lista, e nao um dicionario por carta:
		duas copias da mesma carta empilham de proposito, e cada uso e um registro
		proprio com o `Uid` da compra que o gerou.
	]]
	Active = {},
}

--[[ INTERNAL ]]

--[=[
	Tira da lista o que ja venceu. Devolve `true` se alguma coisa saiu.

	Rodado na leitura, e nao num laco de Heartbeat: quem le e o combate, sessenta
	vezes por segundo, e um laco proprio so acordaria para descobrir que ninguem
	venceu. O preco disso e um buff que vence sem ninguem olhando ficar na lista
	ate a proxima leitura -- e como a leitura e o proprio combate, isso nunca dura
	mais que um quadro.
]=]
function CardModifierService:_prune() : boolean
	local now = GameClock.Now()
	local removed = false

	for index = #self.Active, 1, -1 do
		local modifier = self.Active[index]

		if modifier.ExpiresAt and now >= modifier.ExpiresAt then
			table.remove(self.Active, index)
			removed = true
		end
	end

	return removed
end

--[[ API ]]

--[=[
	A lista viva, ja sem o que venceu.

	Devolve a lista **de verdade**, e nao uma copia: ela e lida por unidade e por
	estatistica a cada quadro de combate, e copiar ali seria alocar algumas centenas
	de tabelas por segundo para nao mudar nada. Ninguem escreve nela por fora -- as
	unicas maos que mexem sao o `Apply` e o `Remove` daqui.
]=]
function CardModifierService:GetActive()
	if self:_prune() then
		self:_broadcast()
	end

	return self.Active
end

--[=[
	Poe uma lista de modificadores no campo.

	`records` sao os registros crus que a carta declarou no `RoundCardConfig`, e
	`options` e o que so o **uso** sabe:

	| Campo | O que e |
	| --- | --- |
	| `Uid` | o uid da carta usada; e por ele que o `Remove` a tira |
	| `Card` | o `Id` da carta, para o log e para a cor do anel na tela |
	| `Duration` | segundos de partida; sem isso, o registro dura o round |
	| `Zone` | `{ Position, Radius }`, para os registros marcados com `Zone = true` |
	| `UnitId` | a torre escolhida, para os registros marcados com `Target = true` |
	| `OwnerUserId` | quem usou a carta; e por ele que o `FindZoneOverlap` separa as areas |

	Os registros sao **copiados**, e nunca apontados: o do config e a declaracao da
	carta, e duas copias da mesma carta na mesma partida escreveriam alvo e prazo uma
	por cima da outra se as duas apontassem para a mesma tabela.
]=]
function CardModifierService:Apply(records, options) : number
	if typeof(records) ~= "table" then return 0 end

	options = options or {}

	local expiresAt = nil
	if options.Duration and options.Duration > 0 then
		expiresAt = GameClock.Now() + options.Duration
	end

	local added = 0

	for _, record in records do
		local modifier = {
			Uid = options.Uid,
			Card = options.Card,
			ExpiresAt = expiresAt,

			--[[
				Quem usou a carta. Ele nao muda o que o modificador faz -- o efeito e da sala,
				venha de quem vier --, e existe para uma pergunta so: se a proxima area **deste
				jogador** pode cair aqui. Ver o `FindZoneOverlap`.
			]]
			OwnerUserId = options.OwnerUserId,

			Stats = record.Stats,
			Flags = record.Flags,
			Classes = record.Classes,
			Exclude = record.Exclude,
			Farm = record.Farm,
			Condition = record.Condition,
			ConditionClass = record.ConditionClass,
			ConditionRadius = record.ConditionRadius,
			Scaling = record.Scaling,
			BaseHealthBelow = record.BaseHealthBelow,
		}

		--[[
			Os dois campos que so o uso preenche. Um registro que **pede** zona e nao
			recebe uma fica de fora: sem centro nem raio ele viraria um buff global, que
			e exatamente o oposto do que um cajado de area promete.
		]]
		if record.Zone then
			if not options.Zone then continue end
			modifier.Zone = { Position = options.Zone.Position, Radius = options.Zone.Radius }
		end

		if record.Target then
			if not options.UnitId then continue end
			modifier.UnitId = options.UnitId
		end

		table.insert(self.Active, modifier)
		added += 1
	end

	if added > 0 then
		self:_broadcast()
	end

	return added
end

--- Tira do campo tudo que veio de um uso. Serve para desfazer o que uma carta fez.
function CardModifierService:Remove(uid : any) : number
	local removed = 0

	for index = #self.Active, 1, -1 do
		if self.Active[index].Uid == uid then
			table.remove(self.Active, index)
			removed += 1
		end
	end

	if removed > 0 then
		self:_broadcast()
	end

	return removed
end

--[=[
	A area deste jogador que uma nova de raio `radius` em `position` encostaria, ou
	`nil` se o lugar esta livre.

	**Duas areas do mesmo jogador nao podem se tocar**: a conta e a distancia entre os
	centros contra a soma dos raios, que e o teste de dois circulos se cruzando. Sem
	ela, empilhar tres cajados no mesmo punhado de torres multiplicava os tres buffs
	no mesmo lugar, e a decisao que a carta vende -- *onde* desenhar o anel -- deixava
	de existir: o melhor lugar era sempre o lugar do anel anterior.

	**So as do proprio jogador contam.** Numa sala de quatro, negar o lugar por causa
	do cajado de outro jogador tiraria do mapa os poucos pontos que valem a pena para
	quem chegou depois, e a disputa por chao nao e o que a carta cobra. Cada um
	arruma o proprio tabuleiro.

	O `Y` sai da conta: o anel e um circulo no chao, e o mapa tem altura. Medir em
	tres dimensoes deixaria duas areas coladas passarem so porque uma esta numa rampa.

	Le pelo `GetActive`, e nao pela lista crua: uma zona que ja venceu -- os dez
	segundos do Staff of Healing -- nao segura mais lugar nenhum.
]=]
function CardModifierService:FindZoneOverlap(userId : number?, position : Vector3, radius : number)
	if typeof(position) ~= "Vector3" or typeof(radius) ~= "number" then return nil end

	for _, modifier in self:GetActive() do
		local zone = modifier.Zone
		if not zone or modifier.OwnerUserId ~= userId then continue end

		local delta = zone.Position - position
		local flat = math.sqrt(delta.X * delta.X + delta.Z * delta.Z)

		if flat < (zone.Radius or 0) + radius then
			return modifier
		end
	end

	return nil
end

--[=[
	O multiplicador de uma estatistica que nao e de unidade nenhuma -- a lentidao que
	o gelo deixa, a queimadura que o fogo deixa.

	Atalho para quem so tem a estatistica na mao (o `MobService`) e nao teria por que
	conhecer o `CardModifier`.
]=]
function CardModifierService:GetGlobal(stat : string) : number
	return CardModifier.Global(self:GetActive(), stat)
end

--[=[
	Zera junto com o round. As cartas sao de partida, e as regras que elas deixaram
	tambem: um anel de cajado nao pode sobreviver a tela de resultado.
]=]
function CardModifierService:ResetRound()
	if #self.Active == 0 then return end

	table.clear(self.Active)
	self:_broadcast()
end

--[[ REPLICACAO ]]

--- Manda a lista inteira para um jogador (ou para todos, sem `player`).
function CardModifierService:_broadcast(player : Player?)
	if player then
		Framework:Fire("RoundCardModifiers", player, self.Active)
		return
	end

	for _, plr in Players:GetPlayers() do
		Framework:Fire("RoundCardModifiers", plr, self.Active)
	end
end

--[[ CICLO DE VIDA ]]

function CardModifierService:construct()
	-- So o servidor dispara este; sem o Listen vazio o cliente ficaria dez segundos
	-- esperando o identificador aparecer (ver o README da raiz).
	Framework:Listen("RoundCardModifiers", function() end)

	--[[
		O cliente pergunta quando termina de ligar a interface. Sem isso, quem entra no
		meio da partida nao veria os aneis que ja estao no chao nem o alcance de verdade
		das torres -- e so descobriria os dois na proxima carta usada.
	]]
	Framework:Listen("RequestRoundCardModifiers", function(player : Player)
		self:_broadcast(player)
	end)
end

function CardModifierService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service)
	end

	self:construct()
end

function CardModifierService:init()
end

return CardModifierService
