local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)

local Me = require(Vendor.Me)
local Signal = require(Packages.Signal)

local DeckConfig = SharedConfig.DeckConfig

local Framework = Me.new()

--[=[
	Quem escreve o deck do jogador (`EquippedUnits` no perfil).

	O deck é um array de slots (ver `SharedConfig.DeckConfig`): o slot de cada
	unidade é fixo, e tirar a última carta de uma esvazia o slot dela sem mexer nos
	outros.

	O cliente só manda um nome de unidade e diz "equipa uma" ou "tira uma"; quem
	decide se a carta pode entrar — se a unidade existe, se sobrou cópia no
	inventário, se ainda há slot **destravado** livre, se o `CardLimit` deixa — é
	aqui, contra o perfil. O `DeckController` desenha a partir da replica, então o
	que ele mostra é sempre o que este service gravou.

	Os três slots de cima são de todo mundo; o quarto, o quinto e o sexto abrem por
	nível (`DeckConfig.SLOT_UNLOCK_LEVELS`). O nível sai do `Stats.XP` do próprio
	perfil, então não há nada a receber do cliente: ele calcula o mesmo número com o
	mesmo config só para desenhar antes da resposta.

	A leitura, a decisão e a escrita acontecem dentro de um `:Update` só, que não
	cede a thread: dois cliques colados não passam do limite.
]=]
local DeckService = {
	Services = {
		DataService = {},
	},

	Signals = {
		-- (Player, deck : DeckConfig.Deck)
		DeckChanged = Signal.new(),
	},
}

--[[ INTERNAL ]]

--[=[
	O perfil carregado do jogador, ou `nil` enquanto ele não chegou.
]=]
function DeckService:_getData(Player : Player)
	local profiles = self.Services.DataService.Profiles
	local profile = profiles and profiles[Player]

	return profile and profile.Profile.Data or nil
end

--[=[
	O caminho comum de equipar e desequipar: valida o que dá para validar fora da
	escrita, roda `decide` dentro do `:Update` e avisa quem escuta.

	`decide(deck, data)` recebe o deck já limpo e devolve `nil` quando a carta entrou
	(ou saiu), ou o motivo da recusa. Mexer nos slots é com ele.
]=]
function DeckService:_write(Player : Player, unitName : string?, decide) : (boolean, string?)
	if not DeckConfig.exists(unitName) then
		warn(string.format("[DeckService]: %s pediu %q, que não é uma unidade.", Player.Name, tostring(unitName)))
		return false, "UnknownUnit"
	end

	local DataService = self.Services.DataService
	local data = self:_getData(Player)

	if not data or not DataService.Update then
		warn(string.format("[DeckService]: %s ainda não tem perfil carregado.", Player.Name))
		return false, "NotLoaded"
	end

	local reason : string? = nil

	DataService:Update(Player, "EquippedUnits", function(current)
		local deck = DeckConfig.sanitize(current, data.Units, data.CardLimit, DeckConfig.unlockedFor(data))

		-- Mesmo recusando, o que a limpeza tirou vale a escrita: é a chance de o
		-- perfil velho se acertar com o UnitStats de hoje (e de virar slots, se ele
		-- ainda estiver no formato antigo).
		reason = decide(deck, data)

		return deck
	end)

	if reason then
		return false, reason
	end

	self.Signals.DeckChanged:Fire(Player, self:GetEquipped(Player))

	return true
end

--[[ EXTERNAL ]]

--[=[
	Quantas cartas cabem no deck deste jogador.
]=]
function DeckService:GetLimit(Player : Player) : number
	local data = self:_getData(Player)

	return DeckConfig.resolveLimit(data and data.CardLimit)
end

--[=[
	O deck do jogador, já limpo. `nil` enquanto o perfil não carregou.
]=]
function DeckService:GetEquipped(Player : Player) : DeckConfig.Deck?
	local data = self:_getData(Player)
	if not data then
		return nil
	end

	return DeckConfig.sanitize(data.EquippedUnits, data.Units, data.CardLimit, DeckConfig.unlockedFor(data))
end

--[=[
	Quantos slots o jogador tem hoje, dos `DeckConfig.MAX_SLOTS`. Zero quando o
	perfil ainda não carregou -- que é diferente dos três de partida.
]=]
function DeckService:GetUnlockedSlots(Player : Player) : number
	local data = self:_getData(Player)

	return if data then DeckConfig.unlockedFor(data) else 0
end

--[=[
	Põe **uma** carta da unidade no deck.

	Recusa com "NoCopies" (todas as que ele tem já estão equipadas), "LimitReached"
	(o `CardLimit` estourou) ou "NoSlot" (não sobrou slot destravado, seja porque o
	jogador já tem uma unidade diferente em cada um ou porque os que faltam ainda
	pedem nível).
]=]
function DeckService:Equip(Player : Player, unitName : string?) : (boolean, string?)
	return self:_write(Player, unitName, function(deck, data)
		local owned = data.Units and data.Units[unitName] or 0
		if owned <= 0 then
			return "NotOwned"
		end

		if DeckConfig.countOf(deck, unitName) >= owned then
			return "NoCopies"
		end

		if DeckConfig.total(deck) >= DeckConfig.resolveLimit(data.CardLimit) then
			return "LimitReached"
		end

		-- Falha só quando a unidade é nova no deck e não há slot destravado livre:
		-- cópia de quem já está lá vai para o slot dele, travado ou não -- e o slot
		-- dela nunca é travado, porque o `sanitize` acima já tirou de lá.
		if not DeckConfig.addCard(deck, unitName, DeckConfig.unlockedFor(data)) then
			return "NoSlot"
		end

		return nil
	end)
end

--[=[
	Tira **uma** carta da unidade do deck. Recusa com "NotEquipped".
]=]
function DeckService:Unequip(Player : Player, unitName : string?) : (boolean, string?)
	return self:_write(Player, unitName, function(deck)
		-- O slot só é liberado quando a última carta sai, e os outros não se mexem.
		if not DeckConfig.removeCard(deck, unitName) then
			return "NotEquipped"
		end

		return nil
	end)
end

--[=[
	Muda quantas cartas cabem no deck. É por aqui que uma recompensa ou um comando
	sobe o teto -- o deck é limpo em seguida, para um teto menor não deixar carta
	sobrando.
]=]
function DeckService:SetLimit(Player : Player, limit : number) : boolean
	local DataService = self.Services.DataService
	local data = self:_getData(Player)

	if not data or not DataService.Update then
		return false
	end

	local resolved = DeckConfig.resolveLimit(limit)

	DataService:Update(Player, "CardLimit", function()
		return resolved
	end)

	DataService:Update(Player, "EquippedUnits", function(current)
		return DeckConfig.sanitize(current, data.Units, resolved, DeckConfig.unlockedFor(data))
	end)

	self.Signals.DeckChanged:Fire(Player, self:GetEquipped(Player))

	return true
end

function DeckService:construct()
	Framework:Listen("RequestEquipCard", function(Player : Player, unitName : string)
		local success, reason = self:Equip(Player, unitName)

		Framework:Fire("DeckCardResult", Player, unitName, "Equip", success, reason)
	end)

	Framework:Listen("RequestUnequipCard", function(Player : Player, unitName : string)
		local success, reason = self:Unequip(Player, unitName)

		Framework:Fire("DeckCardResult", Player, unitName, "Unequip", success, reason)
	end)
end

function DeckService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service, false, true)
	end

	self:construct()
end

function DeckService:init()
	-- O cliente escuta este evento no próprio init, e o identificador do Warp
	-- nasce no servidor: sem este Listen vazio ele espera dez segundos e o resto
	-- do controller para junto (ver README, "Evento novo do servidor...").
	Framework:Listen("DeckCardResult", function() end)
end

return DeckService
