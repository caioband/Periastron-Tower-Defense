--[[
	Single source of truth for the maps a lobby group can pick.

	The key of each entry is the map *name*, and it has to match the folder inside
	`ServerStorage.Maps` in the Game place -- that is the name `MapService:LoadMap`
	takes, and it is what the portal hands over when the group leaves the lobby.

	The map folders live in ServerStorage precisely so they do not replicate: the
	client only ever sees the one map the server cloned into `workspace.Map`. That
	means this config is the *only* thing the lobby can read about maps, so an
	entry missing here is a map the lobby cannot offer.

	`DisplayName` is the only part players read, so it is free to differ from the
	key -- which is not. `Image` is what the map template in `ChooseMaps` and the
	portal billboard show.

	`Music` e o nome da faixa em `SoundService.SharedSounds.Musics`, e so precisa
	existir quando ela **nao** se chama igual a chave. O `MapService` manda este
	nome para o `MusicController`, que procura o Sound por nome exato -- e era ai
	que o `SnowyCastle` ficava mudo: a faixa dele se chama "Snowy Castle", com
	espaco. Sem o campo, vale a chave.

	`WinsRequired` e quantas vitorias o jogador precisa ter para escolher o mapa, e
	ele faz **duas** coisas: tranca o mapa e ordena a lista. Nao ha campo de ordem
	separado de proposito -- a lista e crescente por exigencia, e um campo a parte
	seria a mesma regra escrita duas vezes, esperando para se desencontrar. Mapa novo
	com 7 vitorias entra sozinho entre a Cave e o Volcano, sem renumerar nada.

	Zero (ou sem o campo) e um mapa livre: o Farm e o unico hoje, e e por onde todo
	jogador novo comeca.

	Nada aqui e sigiloso. O cliente le para desenhar o cadeado antes de perguntar
	nada, e o `PortalService` confere a mesma coisa com o mesmo config quando o grupo
	e aberto -- ver `isUnlocked`.
]]

local module = {}

module.MAPS = {
	["Farm"] = {
		DisplayName = "Farm",
		WinsRequired = 0,
		Image = "rbxassetid://91827512669644",
	},

	-- A pasta em `ServerStorage.Maps` se chama "Desert", com um S so, e a chave tem
	-- de bater com ela -- era "Dessert" e por isso este mapa nunca era sorteado nem
	-- carregado. O `DisplayName` continua sendo coisa a parte.
	["Desert"] = {
		DisplayName = "Dessert",
		WinsRequired = 2,
		Image = "rbxassetid://115008998327555",
	},

	["Snowy"] = {
		DisplayName = "Snowy",
		WinsRequired = 3,
		Image = "rbxassetid://110763146643497",
	},

	["SnowyCastle"] = {
		DisplayName = "Snowy Castle",
		-- A faixa no Package tem espaco no nome; a chave e a pasta do mapa, nao.
		Music = "Snowy Castle",
		WinsRequired = 4,
		Image = "rbxassetid://82438762834917",
	},

	-- A pasta em `ServerStorage.Maps` se chama "Mountain", no singular, e a chave
	-- tem de bater com ela ou o `LoadMap` nao acha o mapa. O plural fica so no
	-- nome que o jogador ve.
	["Mountain"] = {
		DisplayName = "Mountains",
		WinsRequired = 5,
		Image = "rbxassetid://111816748733146",
	},

	["Cave"] = {
		DisplayName = "Cave",
		WinsRequired = 6,
		Image = "rbxassetid://90052719869168",
	},

	["Volcano"] = {
		DisplayName = "Volcano",
		WinsRequired = 8,
		Image = "rbxassetid://102911300807811",
	},

	-- Beach, Swamp e Pale Garden estao sem faixa em `SharedSounds.Musics` por
	-- enquanto: a partida fica sem musica ate ela existir.
	["Beach"] = {
		DisplayName = "Beach",
		WinsRequired = 11,
		Image = "rbxassetid://98956022122852",
	},

	["Swamp"] = {
		DisplayName = "Swamp",
		WinsRequired = 13,
		Image = "rbxassetid://115839585540675",
	},

	-- A pasta em `ServerStorage.Maps` tem espaco no nome, e a chave tambem.
	["Pale Garden"] = {
		DisplayName = "Pale Garden",
		WinsRequired = 16,
		Image = "rbxassetid://119383142532337",
	},
}

--[=[
	A Part que cada pasta de mapa traz na raiz com o billboard da vida da base, e o
	nome do TextLabel de dentro dela onde o numero e escrito.

	Os dois nomes moram aqui porque os dois lados precisam do mesmo: o `MapService`
	clona a Part para dentro de `workspace.Map` (sem isso o cliente nao a veria, ja
	que os mapas nao replicam) e o `BaseHealthController` acha o label la para
	escrever a vida a cada `UpdateBaseHealth`.
]=]
module.BASE_HEALTH_PART = "BaseHP"
module.BASE_HEALTH_LABEL = "Value"

--[=[
	Returns the canonical map name for the passed string (case insensitive),
	or nil when the map does not exist.
]=]
function module.resolveMap(mapName : string?) : string?
	if typeof(mapName) ~= "string" then
		return nil
	end

	if module.MAPS[mapName] then
		return mapName
	end

	local lowered = string.lower(mapName)
	for name in module.MAPS do
		if string.lower(name) == lowered then
			return name
		end
	end

	return nil
end

--[=[
	Image of a map, or an empty string when the map does not exist.
]=]
function module.getImage(mapName : string?) : string
	local resolvedMap = module.resolveMap(mapName)
	if not resolvedMap then
		return ""
	end

	return module.MAPS[resolvedMap].Image or ""
end

--[=[
	Quantas vitorias o mapa pede. Mapa que nao existe pede zero: quem chama ja tratou
	o nome invalido, e devolver um numero alto aqui trancaria a lista por engano.
]=]
function module.getWinsRequired(mapName : string?) : number
	local resolvedMap = module.resolveMap(mapName)
	if not resolvedMap then
		return 0
	end

	local required = module.MAPS[resolvedMap].WinsRequired

	return typeof(required) == "number" and math.max(math.floor(required), 0) or 0
end

--[=[
	Se este jogador ja pode escolher o mapa.

	E a mesma conta nas duas pontas: o `ChooseMapsController` desenha o cadeado com
	ela e o `PortalService` recusa o grupo com ela. Sem `wins` (perfil ainda
	carregando) vale zero -- so o que e livre aparece livre, e nunca o contrario.
]=]
function module.isUnlocked(mapName : string?, wins : number?) : boolean
	local owned = typeof(wins) == "number" and math.floor(wins) or 0

	return owned >= module.getWinsRequired(mapName)
end

--[=[
	Quantas vitorias ainda faltam para o mapa abrir, ou zero quando ele ja esta
	aberto. E o numero que o texto do cadeado escreve.
]=]
function module.winsMissing(mapName : string?, wins : number?) : number
	local owned = typeof(wins) == "number" and math.floor(wins) or 0

	return math.max(module.getWinsRequired(mapName) - owned, 0)
end

--[=[
	Map names for UI iteration, in the order the picker shows them: crescente por
	`WinsRequired`, e alfabetica pela chave entre mapas que pedem o mesmo.

	O desempate existe so para a ordem ser **estavel** -- duas telas montadas a partir
	do mesmo config listam igual, e a lista nao muda de uma abertura para a outra.
]=]
--[=[
	A faixa do mapa em `SoundService.SharedSounds.Musics`.

	Cai na propria chave quando o mapa nao declara `Music` -- que e o caso da
	maioria, onde os dois nomes ja batem. Mapa desconhecido devolve nil, e o
	`MusicController` nao tem o que tocar.
]=]
function module.getMusic(mapName : string?) : string?
	local resolved = module.resolveMap(mapName)
	if not resolved then
		return nil
	end

	local entry = module.MAPS[resolved]
	local track = entry and entry.Music

	return typeof(track) == "string" and track or resolved
end

function module.getOrderedMaps() : { string }
	local ordered = {}
	for name in module.MAPS do
		table.insert(ordered, name)
	end

	table.sort(ordered, function(a, b)
		local requiredA, requiredB = module.getWinsRequired(a), module.getWinsRequired(b)

		if requiredA ~= requiredB then
			return requiredA < requiredB
		end

		return a < b
	end)

	return ordered
end

return module
