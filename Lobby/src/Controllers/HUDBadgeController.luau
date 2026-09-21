local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")
local Util = Shared:WaitForChild("Util")

local SharedConfig = require(Configs.SharedConfig)

local UIUtil = require(Util.UIUtil)

local Maid = require(Vendor.Maid)
local Me = require(Vendor.Me)

local Framework = Me.new()

local ContractConfig = SharedConfig.ContractConfig
local RoundCardShopConfig = SharedConfig.RoundCardShopConfig

--[[ CONSTANTS ]]

local HUD_UI_NAME = "HUD"

-- O nome da label dentro de cada botão. É a mesma em todos: quem desenha um botão
-- novo com selo só precisa repetir o nome.
local BADGE_NAME = "New"

local WAIT_TIMEOUT = 10

--[[
	Quanto tempo depois de a loja de Robux ser aberta o selo dela volta.

	É o único selo que não responde a um fato do perfil: ele é um lembrete, e o que o
	traz de volta é o relógio.
]]
local ROBUX_SECONDS = 300

-- De quanto em quanto tempo o bloco da loja de cartas é conferido. O bloco dura
-- quatro horas, então cinco segundos de atraso não são vistos por ninguém.
local ROTATION_INTERVAL = 5

--[=[
	Os cinco botões que têm selo, e em qual coluna cada um mora. O `Key` é o nome do
	botão **e** a chave do selo — é o que o `NoteSeen` recebe.

	**O `HUDFrame.Shop` não está aqui de propósito**: a loja de caixas não tem
	novidade a anunciar (a prateleira dela é a mesma sempre), e por isso o botão dela
	nem tem a label `New` desenhada.
]=]
local BADGES = {
	{ Key = "Contracts", Column = "HUDLeft" },
	{ Key = "RobuxShop", Column = "HUDLeft" },
	{ Key = "Backpack", Column = "HUDFrame" },
	{ Key = "Deck", Column = "HUDFrame" },
	{ Key = "CardShop", Column = "HUDFrame" },
}

--[=[
	Os selos `New` dos botões das duas colunas do `StarterGui.HUD`.

	Cada botão tem uma label `New` dentro dele, e este controller é o único que
	escreve no `Visible` dela. Uma regra por botão:

	  - **Contracts** — algum contrato pronto para ser claimado, **ou** os contratos
	    resetaram (o `Period` de um dos períodos virou). O claim pendente é estado, e
	    não novidade: o selo insiste até o contrato ser claimado, mesmo que o jogador
	    já tenha aberto o quadro. O "resetou" apaga quando o quadro abre;
	  - **RobuxShop** — volta a cada cinco minutos depois de cada abertura, e está
	    aceso desde a chegada de quem ainda não abriu a loja nesta visita;
	  - **Backpack** — alguma caixa nova entrou no inventário. Apaga quando a mochila
	    é aberta;
	  - **Deck** — alguma unit que o jogador não tinha entrou no perfil. Apaga quando
	    o loadout é aberto;
	  - **CardShop** — o bloco de quatro horas da vitrine virou. Apaga quando a loja
	    abre.

	**O que apaga quase todos os selos é abrir o painel** (`NoteSeen`, chamado por
	cada painel no instante em que ele entra): ali a abertura já aconteceu, e o
	jogador já viu o que havia de novo — a caixa na prateleira, a carta no loadout, o
	quadro sorteado de novo, a vitrine trocada. O que chegar **depois** da olhada
	acende outra vez, pelo mesmo `OnChange`.

	A exceção é o claim pendente dos contratos: aquele é estado, e não novidade. Ele
	insiste até o contrato ser claimado, mesmo com o quadro já aberto, e quem o apaga
	é o perfil.

	**O estado é da visita ao lobby**, e mora só aqui: nada disso vai para o perfil.
	Voltar de uma partida é uma visita nova, e o que ainda valer acende de novo — o
	que não é perda, porque as três fontes de novidade de verdade (caixa comprada,
	caixa aberta, contrato claimado) acontecem **dentro** do lobby, na frente do
	jogador.

	A HUD é `ResetOnSpawn`, então a engine a troca a cada respawn: o bind roda de novo
	na cópia nova e o estado é reescrito nela.
]=]
local HUDBadgeController = {
	Controllers = {
		DataController = {},
	},
}

-- `[Key] = a label New daquele botão`, na cópia de agora da HUD.
HUDBadgeController.Labels = {}

--[[ INTERNAL ]]

--- As contagens de uma tabela do perfil (`{ [chave] = número }`), copiadas.
local function countsOf(source : any) : { [string] : number }
	local counts = {}

	if typeof(source) ~= "table" then
		return counts
	end

	for key, value in source do
		local amount = tonumber(value)

		if typeof(key) == "string" and amount then
			counts[key] = amount
		end
	end

	return counts
end

--- O `Period` de cada tipo de contrato, `{ Hourly|Daily|Weekly = número }`.
local function periodsOf(source : any) : { [string] : number }
	local periods = {}

	if typeof(source) ~= "table" then
		return periods
	end

	for kind, section in source do
		local period = typeof(section) == "table" and tonumber(section.Period)

		if typeof(kind) == "string" and period then
			periods[kind] = period
		end
	end

	return periods
end

--- O `Data` da replica, ou nil enquanto ela não chegou.
function HUDBadgeController:_data() : any
	local replica = self.Replica

	return replica and replica.Data or nil
end

--[=[
	Algum contrato pronto para ser claimado?

	Lido do perfil a cada refresh, e não guardado: é estado, e o claim o desfaz pelo
	mesmo `OnChange` que traria qualquer outra mudança.
]=]
function HUDBadgeController:_hasClaimable() : boolean
	local data = self:_data()
	local contracts = data and data.Contracts

	if typeof(contracts) ~= "table" then
		return false
	end

	for _, section in contracts do
		local slots = typeof(section) == "table" and section.Slots

		if typeof(slots) == "table" then
			for _, slot in slots do
				if typeof(slot) == "table" and not slot.Claimed then
					local definition = ContractConfig.get(slot.Id)

					if definition and ContractConfig.isComplete(definition, slot) then
						return true
					end
				end
			end
		end
	end

	return false
end

--- O selo deste botão tem de estar aceso agora?
function HUDBadgeController:_isOn(key : string) : boolean
	if key == "Contracts" then
		return self.ContractsReset or self:_hasClaimable()
	elseif key == "RobuxShop" then
		return self.RobuxDue
	elseif key == "Backpack" then
		return next(self.NewCrates) ~= nil
	elseif key == "Deck" then
		return next(self.NewUnits) ~= nil
	elseif key == "CardShop" then
		return self.CardShopReset
	end

	return false
end

--- Escreve o estado nas labels da cópia de agora da HUD.
function HUDBadgeController:_refresh()
	for key, label in self.Labels do
		label.Visible = self:_isOn(key)
	end
end

--[=[
	Liga a uma cópia da HUD: acha as cinco labels e escreve o estado nelas.

	Um botão que não esteja nessa cópia só fica de fora; os outros continuam
	funcionando. O aviso é por chave, e não por cópia: a HUD nasce de novo a cada
	respawn e o output encheria.
]=]
function HUDBadgeController:_bindHud(screenGui : ScreenGui)
	--[[
		A cópia da vez. As buscas abaixo esperam, e o respawn pode trocar a HUD no meio
		delas: a que voltar de uma cópia velha confere o número antes de escrever, em vez
		de guardar uma label que já foi para o lixo.
	]]
	self.HudToken += 1
	local token = self.HudToken

	self.Labels = {}

	for _, entry in BADGES do
		task.spawn(function()
			local column = screenGui:WaitForChild(entry.Column, WAIT_TIMEOUT)
			if not column then
				self:_warnOnce(entry.Key, `não achei {HUD_UI_NAME}.{entry.Column}`)

				return
			end

			--[[
				O botão está dentro de um `Wrapper`, e o `WaitForChild` só olha filhos
				diretos: é o mesmo `waitForDescendant` que os controllers dos painéis usam
				para achar o botão deles, e pelo mesmo motivo — mexer nos wrappers no Studio
				não pode quebrar o bind.
			]]
			local button = UIUtil.waitForDescendant(column, entry.Key, WAIT_TIMEOUT)
			if not button or not button:IsA("GuiButton") then
				self:_warnOnce(entry.Key, `não achei o botão {entry.Key} em {entry.Column}`)

				return
			end

			local label = button:WaitForChild(BADGE_NAME, WAIT_TIMEOUT)
			if not label or not label:IsA("GuiObject") then
				self:_warnOnce(entry.Key, `o botão {entry.Key} não tem a label {BADGE_NAME}`)

				return
			end

			if self.HudToken ~= token then return end

			self.Labels[entry.Key] = label
			label.Visible = self:_isOn(entry.Key)
		end)
	end
end

function HUDBadgeController:_warnOnce(key : string, message : string)
	if self.Warned[key] then return end

	self.Warned[key] = true
	warn(`[HUDBadgeController]: {message}; esse selo não vai acender.`)
end

function HUDBadgeController:_observeUI()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	local function onChild(child : Instance)
		if child:IsA("ScreenGui") and child.Name == HUD_UI_NAME then
			self:_bindHud(child)
		end
	end

	self.Maid:GiveTask(playerGui.ChildAdded:Connect(onChild))

	for _, child in playerGui:GetChildren() do
		task.spawn(onChild, child)
	end
end

--[=[
	O retrato do perfil na chegada.

	**Nada do que o jogador já tem é novidade**: o selo é sobre o que mudou enquanto
	ele está aqui. Por isso o retrato é tirado antes de o primeiro `OnChange` chegar, e
	as comparações são sempre contra ele.
]=]
function HUDBadgeController:_snapshot()
	local data = self:_data()

	self.Crates = countsOf(data and data.Inventory and data.Inventory.Crates)
	self.Units = countsOf(data and data.Units)
	self.Periods = periodsOf(data and data.Contracts)
end

--[=[
	O perfil mudou: o que subiu acende um selo, o que foi gasto apaga.

	Uma passada só, e nenhuma pergunta sobre **qual** caminho mudou: o `OnChange` da
	replica chega para qualquer escrita, e comparar o perfil inteiro com o retrato é
	mais barato que acertar um caminho por fonte — e não erra a escrita que vem por
	outro caminho que o esperado.
]=]
function HUDBadgeController:_onProfileChanged()
	local data = self:_data()
	if not data then return end

	--[[
		Caixa que entrou é novidade; caixa daquela raridade que acabou sai da conta,
		senão o selo insistiria por uma caixa que não está mais lá. As duas coisas saem
		da mesma comparação porque são a mesma conta em direções opostas.

		Quem apaga o selo de verdade é a mochila ser aberta (`NoteSeen`); isto aqui é só
		não deixar novidade órfã para trás.
	]]
	local crates = countsOf(data.Inventory and data.Inventory.Crates)
	for rarity, amount in crates do
		local before = self.Crates[rarity] or 0

		if amount > before then
			self.NewCrates[rarity] = true
		elseif amount < before then
			self.NewCrates[rarity] = nil
		end
	end
	self.Crates = crates

	--[[
		Só unit que ele **não tinha** conta: a terceira Slasher de uma caixa não muda
		nada no loadout que ele já conhece.
	]]
	local units = countsOf(data.Units)
	for name, amount in units do
		if amount > 0 and (self.Units[name] or 0) <= 0 then
			self.NewUnits[name] = true
		end
	end
	self.Units = units

	--[[
		O período dos contratos virou: o quadro tem contrato novo. É o `Period` do
		perfil, e não o relógio, porque o que interessa é o sorteio **já gravado** —
		selo aceso em quadro que ainda não trocou mandaria o jogador para um quadro
		igual ao que ele viu.
	]]
	local periods = periodsOf(data.Contracts)
	for kind, period in periods do
		local before = self.Periods[kind]

		if before ~= nil and period ~= before then
			self.ContractsReset = true
		end
	end
	self.Periods = periods

	self:_refresh()
end

function HUDBadgeController:_watchProfile()
	task.spawn(function()
		local replica = self.Controllers.DataController:GetReplica()
		self.Replica = replica

		self:_snapshot()
		self:_refresh()

		local connection = replica:OnChange(function()
			self:_onProfileChanged()
		end)

		self.Maid:GiveTask(function()
			connection:Disconnect()
		end)
	end)
end

--[=[
	A virada do bloco da vitrine de cartas.

	O bloco é conta de relógio (`RoundCardShopConfig.rotationIndex`), então conferir o
	número aqui dispensa depender do estoque que o servidor manda: o selo é sobre a
	vitrine ter trocado, e ela troca na mesma hora para todo mundo.
]=]
function HUDBadgeController:_watchRotation()
	self.Rotation = RoundCardShopConfig.rotationIndex()

	local clock = 0

	self.Maid:GiveTask(RunService.Heartbeat:Connect(function(deltaTime : number)
		clock += deltaTime
		if clock < ROTATION_INTERVAL then return end

		clock = 0

		local index = RoundCardShopConfig.rotationIndex()
		if index == self.Rotation then return end

		self.Rotation = index
		self.CardShopReset = true

		self:_refresh()
	end))
end

--[[ EXTERNAL ]]

--[=[
	O painel deste botão foi aberto.

	Quem chama é o painel de cada um dos cinco, no instante em que ele abre — o
	`BeforeOpen` nos três que são `ProximityPanel`, o `_setOpen` na mochila e no
	loadout, que abrem pelo próprio botão. Abrir é o que apaga o selo: o jogador já
	viu a novidade, e insistir depois disso só ensina a ignorar o ponto vermelho.

	O que **entrar depois** da olhada acende de novo sozinho — as novidades da mochila
	e do loadout são zeradas aqui, e não desligadas, então a próxima caixa ou a
	próxima unit repõe o selo pelo mesmo `OnChange` que o acendeu da primeira vez.
]=]
function HUDBadgeController:NoteSeen(key : string)
	if key == "Contracts" then
		-- O claim pendente não é apagado por ter sido visto: ele sai quando o contrato
		-- for claimado, pelo próprio perfil.
		self.ContractsReset = false
	elseif key == "Backpack" then
		table.clear(self.NewCrates)
	elseif key == "Deck" then
		table.clear(self.NewUnits)
	elseif key == "CardShop" then
		self.CardShopReset = false
	elseif key == "RobuxShop" then
		self.RobuxDue = false

		-- O token mata o prazo da abertura anterior: quem abre duas vezes em um minuto
		-- espera cinco minutos da **última**, e não vê o selo voltar no meio.
		self.RobuxToken += 1
		local token = self.RobuxToken

		task.delay(ROBUX_SECONDS, function()
			if self.RobuxToken ~= token then return end

			self.RobuxDue = true

			self:_refresh()
		end)
	else
		return
	end

	self:_refresh()
end

function HUDBadgeController:start()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	self:_observeUI()
	self:_watchProfile()
	self:_watchRotation()
end

function HUDBadgeController:init()
	self.Maid = Maid.new()

	-- Sobe a cada cópia da HUD. Ver `_bindHud`.
	self.HudToken = 0

	self.Replica = nil

	-- O retrato do perfil na chegada: nada do que já está aqui é novidade.
	self.Crates = {}
	self.Units = {}
	self.Periods = {}

	-- As novidades de agora, por raridade e por unit.
	self.NewCrates = {}
	self.NewUnits = {}

	self.ContractsReset = false
	self.CardShopReset = false

	-- A loja de Robux começa acesa: quem acabou de chegar não a abriu nesta visita.
	self.RobuxDue = true
	self.RobuxToken = 0

	self.Rotation = nil

	-- O aviso de peça que falta é por chave, e não por cópia da HUD.
	self.Warned = {}
end

return HUDBadgeController
