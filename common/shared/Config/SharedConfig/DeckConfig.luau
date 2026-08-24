--[[
	O deck do jogador: como as cartas equipadas são guardadas e o que conta como
	uma lista válida.

	`EquippedUnits` é um array de **slots**, um por `CardWrapper` do
	`EquippedCards`, e cada posição é `{ Unit = nome, Amount = quantidade }` ou
	`false` quando o slot está vazio. O array é sempre denso (`MAX_SLOTS`
	posições), então ele sobrevive à ida e volta do DataStore sem virar dicionário.

	O slot é **fixo**: tirar a última carta de uma unidade esvazia o slot dela e
	não mexe em mais nada — quem está no slot 4 continua no slot 4. Era por isso que
	o formato antigo não servia: ele era um array de nomes com repetição, e o slot
	saía da ordem de primeira aparição, então uma unidade que acabava puxava todas as
	seguintes uma casa para trás.

	O formato antigo continua sendo lido (`sanitize` converte, agrupando na ordem em
	que os nomes aparecem), então perfil velho não precisa de migração.

	Os três números da tela saem daqui sem nenhum outro campo: o total de cartas é
	`total`, a quantidade de um slot é o `Amount` dele, e o `CardLimit` limita o
	total.
]]

local UnitStats = require(script.Parent.UnitStats)
local RarityConfig = require(script.Parent.RarityConfig)

local DeckConfig = {}

export type Slot = { Unit : string, Amount : number }
export type Deck = { Slot | false }

-- Quantos `CardWrapper` o `StarterGui.HUD.CardUI.EquippedCards` tem. É o teto de
-- unidades **diferentes** no deck, não de cartas.
DeckConfig.MAX_SLOTS = 6

-- Quantas cartas no total o jogador começa podendo equipar. Fica no perfil
-- (`CardLimit`), então subir o teto de um jogador é escrever nele -- este número
-- só vale para quem nunca teve a chave.
DeckConfig.DEFAULT_CARD_LIMIT = 15

--[=[
	Um deck vazio: `MAX_SLOTS` posições, todas livres.
]=]
function DeckConfig.empty() : Deck
	return table.create(DeckConfig.MAX_SLOTS, false)
end

--[=[
	Se o nome é de uma unidade que existe hoje no `UnitStats`.
]=]
function DeckConfig.exists(unitName : string?) : boolean
	return typeof(unitName) == "string" and UnitStats[unitName] ~= nil
end

--[=[
	O limite de cartas de um perfil, com o padrão para quem não tem a chave ainda.
]=]
function DeckConfig.resolveLimit(limit : number?) : number
	if typeof(limit) ~= "number" or limit < 0 then
		return DeckConfig.DEFAULT_CARD_LIMIT
	end

	return math.floor(limit)
end

--[=[
	Em que slot a unidade está, ou `nil` se ela não estiver no deck.
]=]
function DeckConfig.slotIndexOf(deck : Deck?, unitName : string?) : number?
	if typeof(deck) ~= "table" or unitName == nil then
		return nil
	end

	for index = 1, DeckConfig.MAX_SLOTS do
		local slot = deck[index]

		if typeof(slot) == "table" and slot.Unit == unitName then
			return index
		end
	end

	return nil
end

--[=[
	O primeiro slot livre, ou `nil` se o deck já tiver uma unidade em cada um.
]=]
function DeckConfig.firstFreeSlot(deck : Deck?) : number?
	if typeof(deck) ~= "table" then
		return nil
	end

	for index = 1, DeckConfig.MAX_SLOTS do
		if typeof(deck[index]) ~= "table" then
			return index
		end
	end

	return nil
end

--[=[
	Quantas cartas desta unidade estão equipadas.
]=]
function DeckConfig.countOf(deck : Deck?, unitName : string?) : number
	local index = DeckConfig.slotIndexOf(deck, unitName)

	return if index then (deck :: Deck)[index].Amount else 0
end

--[=[
	Quantas cartas o deck tem no total. É o número que o `CardLimit` limita.
]=]
function DeckConfig.total(deck : Deck?) : number
	if typeof(deck) ~= "table" then
		return 0
	end

	local total = 0
	for index = 1, DeckConfig.MAX_SLOTS do
		local slot = deck[index]

		if typeof(slot) == "table" then
			total += slot.Amount
		end
	end

	return total
end

--[=[
	Quantas cartas de cada unidade o deck tem: `{[nome] = quantidade}`.
]=]
function DeckConfig.tally(deck : Deck?) : { [string]: number }
	local counts = {}

	if typeof(deck) ~= "table" then
		return counts
	end

	for index = 1, DeckConfig.MAX_SLOTS do
		local slot = deck[index]

		if typeof(slot) == "table" then
			counts[slot.Unit] = (counts[slot.Unit] or 0) + slot.Amount
		end
	end

	return counts
end

--[=[
	Uma cópia que pode ser mexida sem tocar no original — os slots também são
	copiados, senão `addCard` mudaria o `Amount` dos dois.
]=]
function DeckConfig.copy(deck : Deck?) : Deck
	local copy = DeckConfig.empty()

	if typeof(deck) ~= "table" then
		return copy
	end

	for index = 1, DeckConfig.MAX_SLOTS do
		local slot = deck[index]

		if typeof(slot) == "table" then
			copy[index] = { Unit = slot.Unit, Amount = slot.Amount }
		end
	end

	return copy
end

--[=[
	Põe **uma** carta da unidade no deck: no slot dela se ela já tiver um, senão no
	primeiro livre. Devolve `false` quando não há slot livre.

	Não checa posse nem `CardLimit` — quem chama é que sabe desses dois.
]=]
function DeckConfig.addCard(deck : Deck, unitName : string) : boolean
	local index = DeckConfig.slotIndexOf(deck, unitName)

	if index then
		local slot = deck[index] :: Slot
		slot.Amount += 1

		return true
	end

	local free = DeckConfig.firstFreeSlot(deck)
	if not free then
		return false
	end

	deck[free] = { Unit = unitName, Amount = 1 }

	return true
end

--[=[
	Tira **uma** carta da unidade. O slot só é liberado quando a última sai, e os
	outros nunca se mexem. Devolve `false` se a unidade não estava no deck.
]=]
function DeckConfig.removeCard(deck : Deck, unitName : string) : boolean
	local index = DeckConfig.slotIndexOf(deck, unitName)
	if not index then
		return false
	end

	local slot = deck[index] :: Slot
	slot.Amount -= 1

	if slot.Amount <= 0 then
		deck[index] = false
	end

	return true
end

--[=[
	Converte o formato antigo — array de nomes com repetição — em slots, agrupando
	na ordem em que os nomes aparecem. É a única coisa que aquele formato dizia
	sobre slots.
]=]
local function fromLegacy(equipped : { string }) : { Slot }
	local order, counts = {}, {}

	for index = 1, #equipped do
		local unitName = equipped[index]
		if typeof(unitName) ~= "string" then
			continue
		end

		if not counts[unitName] then
			table.insert(order, unitName)
		end

		counts[unitName] = (counts[unitName] or 0) + 1
	end

	local slots = {}
	for _, unitName in order do
		table.insert(slots, { Unit = unitName, Amount = counts[unitName] })
	end

	return slots
end

--[=[
	O deck limpo: só unidade que existe, no máximo o que o jogador tem de cada uma,
	uma unidade por slot e no máximo `limit` cartas no total.

	`owned` é o `Units` do perfil (`{[nome] = quantidade}`); `nil` não filtra por
	posse. `limit` cai no padrão quando não vem.

	**Cada slot é limpo no lugar**: um slot que perde tudo vira `false` e os outros
	ficam onde estão.
]=]
function DeckConfig.sanitize(equipped : any, owned : { [string]: number }?, limit : number?) : Deck
	local deck = DeckConfig.empty()

	if typeof(equipped) ~= "table" then
		return deck
	end

	-- Perfil no formato antigo: um nome por carta, sem slot nenhum.
	if typeof(equipped[1]) == "string" then
		equipped = fromLegacy(equipped)
	end

	local maxCards = DeckConfig.resolveLimit(limit)
	local seen = {}
	local total = 0

	for index = 1, DeckConfig.MAX_SLOTS do
		local slot = equipped[index]
		if typeof(slot) ~= "table" then
			continue
		end

		local unitName = slot.Unit
		if not DeckConfig.exists(unitName) or seen[unitName] then
			continue
		end

		local amount = math.floor(tonumber(slot.Amount) or 0)

		if owned then
			amount = math.min(amount, owned[unitName] or 0)
		end

		-- O que estourar o limite é cortado, mas o slot não some por isso: só some
		-- quando não sobra carta nenhuma nele.
		amount = math.min(amount, maxCards - total)

		if amount <= 0 then
			continue
		end

		seen[unitName] = true
		total += amount
		deck[index] = { Unit = unitName, Amount = amount }
	end

	return deck
end

--[=[
	Um deck montado na hora a partir do inventário, para quem nunca montou o seu.

	Sem isto, um jogador que nunca abriu o painel do deck entraria na partida sem
	carta nenhuma — e ficaria travado, porque o deck é o que decide o que ele pode
	colocar no mapa.

	Pega as unidades mais raras primeiro (até encher os slots) e distribui as cartas
	em rodízio entre elas, respeitando o que ele tem de cada uma e o `limit`. O
	rodízio é para o deck automático não ser três cópias de uma só quando o jogador
	tem variedade.

	É **determinístico**: cliente e servidor chegam ao mesmo deck a partir do mesmo
	perfil, sem precisar combinar nada.
]=]
function DeckConfig.autoDeck(owned : { [string]: number }?, limit : number?) : Deck
	local deck = DeckConfig.empty()

	if typeof(owned) ~= "table" then
		return deck
	end

	local names = {}
	for unitName, amount in owned do
		if DeckConfig.exists(unitName) and (amount or 0) > 0 then
			table.insert(names, unitName)
		end
	end

	-- Da raridade mais alta para a mais baixa, alfabética dentro da faixa: a mesma
	-- ordem da lista do inventário.
	table.sort(names, function(a : string, b : string)
		local orderA = RarityConfig.getOrder(UnitStats[a].Rarity) or 0
		local orderB = RarityConfig.getOrder(UnitStats[b].Rarity) or 0

		if orderA ~= orderB then
			return orderA > orderB
		end

		return a < b
	end)

	local maxCards = DeckConfig.resolveLimit(limit)
	local chosen = {}

	for index = 1, math.min(#names, DeckConfig.MAX_SLOTS) do
		table.insert(chosen, { Unit = names[index], Amount = 0 })
	end

	local total = 0
	local added = true

	while added and total < maxCards do
		added = false

		for _, slot in chosen do
			if total >= maxCards then
				break
			end

			if slot.Amount < (owned[slot.Unit] or 0) then
				slot.Amount += 1
				total += 1
				added = true
			end
		end
	end

	local index = 0
	for _, slot in chosen do
		if slot.Amount > 0 then
			index += 1
			deck[index] = slot
		end
	end

	return deck
end

--[=[
	O deck que vale para uma partida: o que o jogador montou, ou um automático
	quando ele nunca montou nenhum. É o que o Game usa para saber o que ele pode
	colocar no mapa, e é chamado dos dois lados — servidor e cliente — para os dois
	chegarem à mesma hotbar.
]=]
function DeckConfig.resolve(profile : { EquippedUnits : any, Units : any, CardLimit : number? }?) : Deck
	if typeof(profile) ~= "table" then
		return DeckConfig.empty()
	end

	local owned = profile.Units
	local deck = DeckConfig.sanitize(profile.EquippedUnits, owned, profile.CardLimit)

	if DeckConfig.total(deck) > 0 then
		return deck
	end

	return DeckConfig.autoDeck(owned, profile.CardLimit)
end

--[=[
	Os nomes das unidades do deck, na ordem dos slots e sem os buracos. É a hotbar
	da partida: slot vazio não vira carta em branco no meio da mão.
]=]
function DeckConfig.unitList(deck : Deck?) : { string }
	local names = {}

	if typeof(deck) ~= "table" then
		return names
	end

	for index = 1, DeckConfig.MAX_SLOTS do
		local slot = deck[index]

		if typeof(slot) == "table" then
			table.insert(names, slot.Unit)
		end
	end

	return names
end

return DeckConfig
