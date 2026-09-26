local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Me = require(Vendor.Me)

local Framework = Me.new()

--[[
	Edição de perfil pelos comandos de admin (`cash`, `shards`, `units`), com o
	jogador em qualquer lugar: neste servidor, em outro, ou offline.

	Uma edição é uma **operação**: `{ Key, Field, Action, Amount }` — mexe em
	`Data[Key][Field]`, um número. Hoje são duas chaves: `Stats` (Cash e Shards) e
	`Units` (quantas de cada unidade).

	**Por onde ela vai.**
	  1. O jogador está neste servidor → `DataService:Update`, na hora, e a replica
	     avisa o cliente como em qualquer outra escrita.
	  2. O perfil tem sessão aberta em outro servidor → `MessageAsync`. O servidor de
	     lá recebe em segundos (o `DataService` registra o `MessageHandler`), aplica e
	     salva. Sessão de servidor que caiu também cai aqui: a mensagem espera o
	     jogador entrar de novo.
	  3. Sem sessão → a mesma mensagem, e em seguida uma sessão curta aberta **só para
	     consumi-la**: aplica, salva e fecha.

	**Por que o caso 3 também vai por mensagem.** Entre ver "sem sessão" e abrir a
	nossa há uma fresta; se o jogador entrar nela, quem ganha o perfil é quem
	consome a mensagem — ela é aplicada uma vez só (o ProfileStore marca como
	processada) e nunca se perde. E, se a nossa sessão curta tomar o perfil de um
	servidor que acabou de abrir, o `DataService` de lá expulsa o jogador (ver o
	`OnSessionEnd` dele) em vez de deixá-lo jogando sem salvar.
]]

local MESSAGE_KIND = "AdminEdit"

-- Quanto a sessão curta do caso 3 espera o perfil antes de desistir. Desistir não
-- perde nada: a mensagem já está no perfil e será aplicada na próxima sessão.
local OFFLINE_SESSION_TIMEOUT = 15

-- O que cada chave aceita, e se o zero sai da tabela.
local KEYS = {
	-- Moeda zerada continua no perfil como `0`: é o formato do template.
	Stats = { Fields = { Cash = true, Shards = true }, DropZero = false },

	-- Unidade zerada sai da tabela: é assim que o perfil de quem nunca teve a
	-- unidade se parece, e o `DeckConfig` lê os dois casos pelo mesmo `or 0`.
	Units = { Fields = nil, DropZero = true },
}

local ProfileEditService = {
	Services = {
		DataService = {},
	}
}

--[[ INTERNAL ]]

--[=[
	O valor depois da operação. Nunca negativo: `remove` grande demais é engano de
	quem digitou, não um pedido para dever.
]=]
local function applyAction(action : string, current : number, amount : number) : number
	if action == "set" then
		return math.max(amount, 0)
	elseif action == "remove" then
		return math.max(current - amount, 0)
	end

	return math.max(current + amount, 0)
end

--[=[
	Aplica a operação numa tabela `{ [Field] = número }` e devolve
	`(tabela, anterior, novo)`. É a única conta: os três caminhos passam por aqui.
]=]
local function editTable(tbl : { [string] : number }?, op) : ({ [string] : number }, number, number)
	tbl = if typeof(tbl) == "table" then tbl else {}

	local previous = tonumber(tbl[op.Field]) or 0
	local updated = applyAction(op.Action, previous, op.Amount)

	if updated == 0 and KEYS[op.Key].DropZero then
		tbl[op.Field] = nil
	else
		tbl[op.Field] = updated
	end

	return tbl, previous, updated
end

local function validate(op) : string?
	local rule = KEYS[op.Key]
	if not rule then
		return `'{op.Key}' is not an editable key.`
	end
	if rule.Fields and not rule.Fields[op.Field] then
		return `'{op.Field}' is not editable in {op.Key}.`
	end
	if op.Action ~= "set" and op.Action ~= "add" and op.Action ~= "remove" then
		return `unknown action '{op.Action}'.`
	end
	if typeof(op.Amount) ~= "number" then
		return "amount must be a number."
	end

	return nil
end

local function displayName(userId : number) : string
	local player = Players:GetPlayerByUserId(userId)
	if player then
		return player.Name
	end

	local ok, name = pcall(Players.GetNameFromUserIdAsync, Players, userId)

	return if ok and name then name else `#{userId}`
end

--[=[
	Caso 3: abre o perfil só para consumir as mensagens pendentes, e fecha.

	Enquanto a sessão curta está aberta, a chave fica marcada no `DataService`
	(`OfflineSessions`): o ProfileStore recusa abrir a mesma chave duas vezes no
	mesmo servidor, e o jogador que entrar **aqui** nesse meio-tempo espera ela
	fechar em vez de ficar sem perfil.
]=]
function ProfileEditService:_consumeOffline(userId : number, nonce : string) : (number?, number?)
	local dataService = self.Services.DataService
	local store = dataService.Packages.ProfileManager
	local profileKey = "Player_" .. userId

	--[[
		O jogador pode ter entrado **aqui** enquanto a mensagem viajava. A conferência
		e a marca vêm juntas, sem ceder a thread entre elas: quem entrar depois disto
		espera a marca sair (`DataService:CreatePlayer`), e quem entrou antes já
		abriu (ou está abrindo) a sessão dele, que consome a mensagem sozinha. Abrir a
		nossa por cima faria o ProfileStore devolver `nil` para a dele.
	]]
	if Players:GetPlayerByUserId(userId) then
		return nil, nil
	end

	dataService.OfflineSessions[userId] = true

	local previous, updated

	local ok, err = pcall(function()
		local deadline = os.clock() + OFFLINE_SESSION_TIMEOUT
		local session = store:StartSessionAsync(profileKey, {
			Cancel = function()
				return os.clock() > deadline
			end,
		})
		if not session then
			return
		end

		session:MessageHandler(function(message, processed)
			local p, u = self:ApplyMessage(session.Data, message, processed)
			if typeof(message) == "table" and message.Nonce == nonce then
				previous, updated = p, u
			end
		end)

		session:EndSession()
	end)

	dataService.OfflineSessions[userId] = nil

	if not ok then
		warn(`[ProfileEditService]: sessao curta de {profileKey} falhou: {err}`)
	end

	return previous, updated
end

--[[ API ]]

--[=[
	O `MessageHandler` que os `DataService` registram em toda sessão, e o da sessão
	curta do caso 3. Aplica a mensagem de edição direto em `data` e a marca como
	processada. Mensagem de outro tipo passa reto e fica para quem a entender.

	Devolve `(anterior, novo)` quando aplicou.
]=]
function ProfileEditService:ApplyMessage(data : any, message : any, processed : () -> ()) : (number?, number?)
	if typeof(message) ~= "table" or message.Kind ~= MESSAGE_KIND then
		return nil, nil
	end

	local op = message.Op
	if typeof(op) ~= "table" or validate(op) then
		warn(`[ProfileEditService]: mensagem de edicao invalida descartada.`)
		processed()
		return nil, nil
	end

	local tbl, previous, updated = editTable(data[op.Key], op)
	data[op.Key] = tbl

	processed()

	return previous, updated
end

--[=[
	Igual ao `ApplyMessage`, mas para o perfil aberto neste servidor: passa pelo
	`DataService:Update`, que é o que avisa a replica (e o cliente).
]=]
function ProfileEditService:ApplyMessageToPlayer(player : Player, message : any, processed : () -> ())
	if typeof(message) ~= "table" or message.Kind ~= MESSAGE_KIND then
		return
	end

	local op = message.Op
	if typeof(op) ~= "table" or validate(op) then
		warn(`[ProfileEditService]: mensagem de edicao invalida descartada.`)
		processed()
		return
	end

	self.Services.DataService:Update(player, op.Key, function(current)
		return (editTable(current, op))
	end)

	processed()
end

--[=[
	Aplica a operação no perfil de `userId`, onde quer que ele esteja, e devolve a
	linha que o console imprime.
]=]
function ProfileEditService:Edit(userId : number, op) : string
	local problem = validate(op)
	if problem then
		return problem
	end

	local dataService = self.Services.DataService
	if not dataService then
		return "DataService unavailable."
	end

	local label = `{op.Key}.{op.Field}`

	-- 1. Neste servidor.
	local player = Players:GetPlayerByUserId(userId)
	if player then
		if not (dataService.Profiles and dataService.Profiles[player]) then
			return `{player.Name}: profile still loading, try again.`
		end

		local previous, updated = 0, 0
		dataService:Update(player, op.Key, function(current)
			local tbl
			tbl, previous, updated = editTable(current, op)
			return tbl
		end)

		return `{player.Name} {label} {previous} -> {updated}`
	end

	local name = displayName(userId)
	local store = dataService.Packages.ProfileManager
	local profileKey = "Player_" .. userId

	local okRead, snapshot = pcall(store.GetAsync, store, profileKey)
	if not okRead then
		return `{name}: failed to read profile ({snapshot}).`
	end
	if not snapshot then
		return `{name}: has no profile in this store (never played?). Nothing changed.`
	end

	local nonce = HttpService:GenerateGUID(false)
	local message = { Kind = MESSAGE_KIND, Op = op, Nonce = nonce }

	local okSend, sent = pcall(store.MessageAsync, store, profileKey, message)
	if not okSend or not sent then
		return `{name}: failed to send the edit ({okSend and "store closing" or sent}).`
	end

	-- 2. Sessão aberta em outro servidor (ou de um servidor que caiu).
	if snapshot.Session then
		return `{name} {label}: {op.Action} {op.Amount} sent to their server (online elsewhere; applies in a few seconds, or on next join).`
	end

	-- 3. Sem sessão.
	local previous, updated = self:_consumeOffline(userId, nonce)
	if updated then
		return `{name} {label} {previous} -> {updated} (offline, saved)`
	end

	return `{name} {label}: {op.Action} {op.Amount} queued (profile busy; applies on next join).`
end

--[=[
	O que os comandos do Cmdr chamam: a operação para cada `userId`, uma linha por
	jogador. Em série de propósito — cada um pode esperar o DataStore, e em
	paralelo um `all` dispararia todas as leituras de uma vez.
]=]
function ProfileEditService:RunCommand(userIds : { number }, op) : string
	if #userIds == 0 then
		return "Nobody matched."
	end

	local lines = {}
	for _, userId in userIds do
		table.insert(lines, self:Edit(userId, table.clone(op)))
	end

	return table.concat(lines, "\n")
end

--[[ CICLO DE VIDA ]]

function ProfileEditService:start()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service, false, true)
	end
end

function ProfileEditService:init()
end

return ProfileEditService
