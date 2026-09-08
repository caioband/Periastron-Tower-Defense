--[[
	O Index do jogador: o que ele ja descobriu no jogo.

	Uma categoria por tipo de coisa colecionavel, e cada uma guarda so
	`{ [chave] = true }` no perfil. A chave e a mesma que o resto do jogo ja usa --
	o nome da unit no `UnitStats`, o nome do mapa no `MapConfig` --, entao
	descobrir nao duplica dado nenhum: o Index diz **se** o jogador conhece a
	coisa, e quem a descreve continua sendo o config dela.

	## Quem escreve

	So o `IndexService` (servidor). Cada categoria tem um gatilho:

	| Categoria | Descobre quando |
	| --- | --- |
	| `Units` | o jogador **obtem** a unit (caixa, invocacao) |
	| `Maps` | o jogador **joga** o mapa pela primeira vez |
	| `Enemies` | ainda nao tem gatilho -- a categoria existe e fica vazia |

	`Enemies` esta aqui de proposito mesmo sem quem a preencha: o perfil ja nasce
	com a chave, entao no dia em que o gatilho existir nenhum perfil precisa de
	migracao -- e o reconcile do `DataService` ja resolve os antigos.

	## Quem le

	O cliente, pela replica. O unboxing e o primeiro: a unit que o jogador ainda
	nao descobriu aparece preta no carretel.

	Descobrir **nao** e ter. O Index e memoria: uma unit vendida (ou um mapa que o
	jogador nao pode mais escolher) continua descoberta, porque ele ja a viu. Quem
	responde "tem agora" e o `Units` do perfil, e nao esta tabela.
]]

local IndexConfig = {}

--- As categorias, na ordem em que uma UI de index as mostraria.
IndexConfig.CATEGORIES = {
	"Units",
	"Maps",
	"Enemies",
}

--[[ API ]]

--[=[
	O Index de um perfil novo: uma categoria vazia por linha de `CATEGORIES`.

	E o que o `Data.Template` guarda. Categoria nova aqui entra sozinha nos perfis
	antigos pelo reconcile do `DataService`.
]=]
function IndexConfig.createEmpty() : { [string]: { [string]: boolean } }
	local index = {}

	for _, category in IndexConfig.CATEGORIES do
		index[category] = {}
	end

	return index
end

--- Se o nome e uma categoria de verdade. O que vem de fora passa por aqui.
function IndexConfig.isCategory(category : any) : boolean
	if typeof(category) ~= "string" then return false end

	for _, known in IndexConfig.CATEGORIES do
		if known == category then
			return true
		end
	end

	return false
end

--[=[
	As descobertas de uma categoria: `{ [chave] = true }`.

	Perfil que ainda nao carregou (ou categoria que nao existe) vale como vazio, e
	nao como erro -- e o mesmo acordo do `GamepassConfig.ownedOf`: enquanto o dado
	nao chegou, o jogador conta como quem ainda nao descobriu nada, que e o estado
	que a UI sabe desenhar.
]=]
function IndexConfig.entriesOf(profile : any, category : string) : { [string]: boolean }
	local index = typeof(profile) == "table" and profile.Index
	local entries = typeof(index) == "table" and index[category]

	return typeof(entries) == "table" and entries or {}
end

--- Se o perfil ja descobriu esta chave.
function IndexConfig.has(profile : any, category : string, key : any) : boolean
	if typeof(key) ~= "string" then return false end

	return IndexConfig.entriesOf(profile, category)[key] == true
end

--- Quantas coisas o perfil descobriu numa categoria.
function IndexConfig.count(profile : any, category : string) : number
	local total = 0

	for _, discovered in IndexConfig.entriesOf(profile, category) do
		if discovered then
			total += 1
		end
	end

	return total
end

return IndexConfig
