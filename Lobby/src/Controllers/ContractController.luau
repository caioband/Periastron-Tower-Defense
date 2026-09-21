local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Configs = Shared:WaitForChild("Config")
local Util = Shared:WaitForChild("Util")

local Maid = require(Vendor.Maid)
local Me = require(Vendor.Me)

local SharedConfig = require(Configs.SharedConfig)
local ButtonUtil = require(Util.ButtonUtil)
local ProximityPanel = require(Util.ProximityPanel)
local UIUtil = require(Util.UIUtil)

local ContractConfig = SharedConfig.ContractConfig
local CrateConfig = SharedConfig.CrateConfig

local Framework = Me.new()

local BOARD = ContractConfig.Board

--[[ CONSTANTS ]]

--[=[
	O caminho da UI: `Contracts.Frame.MainBoard.ScrollingFrame`, com um par
	cabecalho + frame por periodo. O cabecalho traz o `Timer`; o frame traz o
	`TaskFrame` autorado, que e o **molde** das linhas daquela secao -- cada secao
	tem a arte dela, entao o molde e por secao, e nao um so.
]=]
local GUI = {
	ScreenGui = "Contracts",
	Wrapper = "Frame",
	Panel = "MainBoard",
	List = "ScrollingFrame",

	Sections = {
		Hourly = { Header = "Hourly", Frame = "HourlyFrame" },
		Daily = { Header = "Daily", Frame = "DailyFrame" },
		Weekly = { Header = "Weekly", Frame = "WeeklyFrame" },
	},

	Timer = "Timer",
	Template = "TaskFrame",
	Task = "Task",
	Claim = "ClaimButton",
	Paper = "TaskPaper",
	Rewards = "RewardsContainer",

	-- O carimbo do `TaskPaper`, escondido ate o slot ser resgatado.
	Claimed = "Claimed",

	Coin = "CoinAmount",
	CoinText = "CoinAmountText",
	Shard = "ShardAmount",
	ShardText = "ShardAmountText",

	-- O texto generico das recompensas que nao sao coin nem shard (as caixas). Um
	-- por caixa: o autorado leva a primeira, e clones dele levam as outras.
	Other = "OtherReward",
}

--[=[
	O botao da HUD que leva o jogador ate o quadro: `HUD.HUDLeft.Wrapper.Contracts`,
	a coluna da esquerda. O nome e procurado em profundidade dentro da coluna, como
	nas lojas, entao mexer nos wrappers no Studio nao quebra o bind.

	Aqui mora so o clique. O crescer e o afundar do botao sao do `HUDButtonController`,
	que anima todo `GuiButton` das duas colunas.
]=]
local HUD_UI_NAME = "HUD"
local HUD_FRAME_NAME = "HUDLeft"
local HUD_BUTTON_NAME = "Contracts"

local CHARACTER_ROOT = "HumanoidRootPart"

local WAIT_TIMEOUT = 10

local ROW_PREFIX = "Contract_"
local OTHER_CLONE_PREFIX = "OtherReward_"

local HIDE_REASON = "Contracts"

local CLAIM_TEXT = "CLAIM"
local CLAIMED_TEXT = "CLAIMED"

-- O botao de quem ainda nao pode resgatar (incompleto ou ja resgatado) fica meio
-- apagado, e nao escondido: a arte da linha foi desenhada com ele no lugar.
local DISABLED_TRANSPARENCY = 0.55

-- A arte do botao pronto para resgatar. Fora disso ele volta para a imagem autorada
-- no `ClaimButton` do molde.
local CLAIM_READY_IMAGE = "rbxassetid://87113976488534"

-- O som do resgate: o `Coins` da compra da loja, em `SoundService.BuySFX`.
local CLAIM_SOUND = "Coins"
local CLAIM_SOUND_KEY = "ContractClaim"

local TIMER_INTERVAL = 1

--[=[
	O quadro de contratos do lobby: `StarterGui.Contracts`.

	Abre quando o jogador chega na `Workspace.ContractsBoard.TargetPart` e fecha
	quando ele sai -- o mesmo painel das lojas, pelo `ProximityPanel`.

	**Este controller nao decide nada.** Os contratos, o progresso e o "ja resgatado"
	chegam pela replica do perfil (`Data.Contracts`), e o CLAIM manda so "o slot N do
	periodo X". Quem sorteia, conta e paga e o `ContractService`; o botao acender aqui
	e so a leitura do mesmo perfil, e o servidor confere de novo.

	A contagem de cada secao sai da hora do servidor (`GetServerTimeNow`) e do
	`ContractConfig`, e nao de um numero que o servidor mande: a virada e em hora
	fixa, e as duas pontas chegam no mesmo instante sem combinar nada.
]=]
local ContractController = {
	Controllers = {
		DataController = {},
		InterfaceController = {},
		MusicController = {},

		-- O selo `New` do botao da HUD: quem o apaga e o quadro abrir. Ver o
		-- `BeforeOpen` no `construct`.
		HUDBadgeController = {},
	},
}

--[[ INTERNAL ]]

local function formatAmount(value : number) : string
	return UIUtil.formatCommas(math.floor(value))
end

--- O `Contracts` da replica, ou nil enquanto ela nao chegou.
function ContractController:_contracts()
	local replica = self.Replica
	local data = replica and replica.Data

	return data and data.Contracts or nil
end

function ContractController:_board() : BasePart?
	local model = workspace:FindFirstChild(BOARD.Model)
	local target = model and model:FindFirstChild(BOARD.Target, true)

	if target and target:IsA("BasePart") then
		return target
	end

	if not self.WarnedBoard then
		self.WarnedBoard = true
		warn(`[ContractController]: no {BOARD.Model}.{BOARD.Target} in Workspace -- the board never opens.`)
	end

	return nil
end

--[=[
	Escreve as recompensas no `RewardsContainer` da linha. Coin e shard sao os dois
	autorados, e somem quando o contrato nao paga aquela moeda; cada caixa e uma
	linha de texto (`8x Fragmented Crate`), na ordem do `CrateConfig`.
]=]
local function writeRewards(row : Instance, rewards)
	local container = row:FindFirstChild(GUI.Rewards, true)
	if not container then return end

	local coin = container:FindFirstChild(GUI.Coin)
	if coin and coin:IsA("GuiObject") then
		local cash = rewards.Cash or 0
		coin.Visible = cash > 0
		coin.LayoutOrder = 1

		local label = coin:FindFirstChild(GUI.CoinText)
		if label and label:IsA("TextLabel") then
			label.Text = formatAmount(cash)
		end
	end

	local shard = container:FindFirstChild(GUI.Shard)
	if shard and shard:IsA("GuiObject") then
		local shards = rewards.Shards or 0
		shard.Visible = shards > 0
		shard.LayoutOrder = 2

		local label = shard:FindFirstChild(GUI.ShardText)
		if label and label:IsA("TextLabel") then
			label.Text = formatAmount(shards)
		end
	end

	-- Os clones de uma escrita anterior saem antes: a linha e reaproveitada.
	for _, child in container:GetChildren() do
		if string.sub(child.Name, 1, #OTHER_CLONE_PREFIX) == OTHER_CLONE_PREFIX then
			child:Destroy()
		end
	end

	local other = container:FindFirstChild(GUI.Other)
	if not other or not other:IsA("TextLabel") then return end

	local lines = {}
	for _, tier in CrateConfig.getOrderedRarities() do
		local amount = rewards.Crates and rewards.Crates[tier]
		if amount and amount > 0 then
			local crate = CrateConfig.CRATES[tier]
			table.insert(lines, string.format("%dx %s", amount, crate and crate.DisplayName or tier))
		end
	end

	other.Visible = #lines > 0

	for index, text in lines do
		local label = other
		if index > 1 then
			label = other:Clone()
			label.Name = OTHER_CLONE_PREFIX .. index
			label.Parent = container
		end

		label.Text = text
		label.LayoutOrder = 2 + index
	end
end

--[=[
	O botao conforme o slot: aceso, e com a arte de pronto (`CLAIM_READY_IMAGE`), so
	quando da para resgatar. A imagem e a transparencia autoradas ficam guardadas na
	primeira vez, para o botao voltar a elas.
]=]
local function writeClaim(entry, complete : boolean, claimed : boolean)
	local button = entry.Claim
	if not button then return end

	local canClaim = complete and not claimed
	button.Active = canClaim
	button.AutoButtonColor = canClaim

	if button:IsA("ImageButton") then
		button.Image = if canClaim then CLAIM_READY_IMAGE else entry.ClaimImageId
		button.ImageTransparency = if canClaim then entry.ClaimImage else DISABLED_TRANSPARENCY
	end

	local label = entry.ClaimLabel
	if label then
		label.Text = if claimed then CLAIMED_TEXT else CLAIM_TEXT
		label.TextTransparency = if canClaim then entry.ClaimText else DISABLED_TRANSPARENCY
	end

	if entry.ClaimedFrame then
		entry.ClaimedFrame.Visible = claimed
	end
end

--[=[
	Uma linha por slot. As linhas sao clones do molde da secao e sao reaproveitadas
	entre escritas; as que sobram (um periodo com menos slots, que nao acontece hoje)
	ficam escondidas.
]=]
function ContractController:_renderSection(kind : string)
	local section = self.Sections[kind]
	if not section or not section.Template then return end

	local contracts = self:_contracts()
	local bucket = contracts and contracts[kind]
	local slots = bucket and bucket.Slots or {}

	for index, slot in slots do
		local definition = ContractConfig.get(slot.Id)
		local entry = section.Rows[index]

		if not entry then
			local row = section.Template:Clone()
			row.Name = ROW_PREFIX .. index
			row.LayoutOrder = index
			row.Parent = section.Frame

			local claim = row:FindFirstChild(GUI.Claim, true)
			local claimLabel = claim and claim:FindFirstChildWhichIsA("TextLabel")

			-- O carimbo mora no `TaskPaper`, mas a busca e pela linha inteira: cada
			-- secao aninha o papel do jeito dela.
			local claimedFrame = row:FindFirstChild(GUI.Claimed, true)

			entry = {
				Row = row,
				Task = row:FindFirstChild(GUI.Task, true),
				Claim = claim,
				ClaimLabel = claimLabel,
				ClaimedFrame = claimedFrame and claimedFrame:IsA("GuiObject") and claimedFrame or nil,
				ClaimImage = claim and claim:IsA("ImageButton") and claim.ImageTransparency or 0,
				ClaimImageId = claim and claim:IsA("ImageButton") and claim.Image or "",
				ClaimText = claimLabel and claimLabel.TextTransparency or 0,
			}

			if claim and claim:IsA("GuiButton") then
				self.RowMaid:GiveTask(claim.Activated:Connect(function()
					self:_requestClaim(kind, index)
				end))

				ButtonUtil.bindFeedback(claim, self.RowMaid)
			end

			section.Rows[index] = entry
		end

		entry.Row.Visible = definition ~= nil

		if definition then
			if entry.Task and entry.Task:IsA("TextLabel") then
				entry.Task.Text = ContractConfig.describe(definition, slot)
			end

			-- O slot traz a recompensa quando ela acompanha a dificuldade sorteada.
			writeRewards(entry.Row, slot.Rewards or definition.Rewards or {})
			writeClaim(entry, ContractConfig.isComplete(definition, slot), slot.Claimed == true)
		end
	end

	for index = #slots + 1, #section.Rows do
		section.Rows[index].Row.Visible = false
	end
end

function ContractController:_render()
	for _, kind in ContractConfig.KIND_ORDER do
		self:_renderSection(kind)
	end
end

function ContractController:_updateTimers()
	local now = workspace:GetServerTimeNow()

	for kind, section in self.Sections do
		local label = section.Timer
		if label and label.Parent then
			local period = ContractConfig.periodOf(kind, now)
			label.Text = ContractConfig.formatRemaining(ContractConfig.endsAt(kind, period) - now)
		end
	end
end

--[=[
	O pedido de resgate. So sai com o botao aceso, mas o servidor confere tudo de
	novo -- o que chega aqui e um clique, e nao uma decisao.
]=]
function ContractController:_requestClaim(kind : string, index : number)
	local contracts = self:_contracts()
	local slot = contracts and contracts[kind] and contracts[kind].Slots[index]
	local definition = slot and ContractConfig.get(slot.Id)

	if not definition or slot.Claimed or not ContractConfig.isComplete(definition, slot) then
		return
	end

	Framework:Fire("ClaimContract", kind, index)
end

--[=[
	Abre o prompt do reroll da aba, no produto que a contagem do perfil manda
	(`ContractConfig.rerollProduct`).

	O cliente **abre** a compra e nao credita nada: quem rerola e o recibo, no
	`ContractService`, e a aba nova chega pela replica. Cancelar o prompt nao faz nada.
	Sem debounce, como o reroll da loja de cartas: `PromptProductPurchase` nao empilha
	janelas.
]=]
function ContractController:_promptReroll(kind : string)
	local contracts = self:_contracts()
	if not contracts then return end

	local bucket = contracts[kind]
	local productId = ContractConfig.rerollProduct(kind, bucket and bucket.Rerolls)
	if not productId then return end

	MarketplaceService:PromptProductPurchase(Players.LocalPlayer, productId)
end

--[=[
	O conteudo numa copia nova da `Contracts`: acha as tres secoes e tira o molde de
	cada uma da tela. O painel em si (moldura, animacao, borrao, proximidade) e do
	`ProximityPanel`.
]=]
function ContractController:_onBind(panel : GuiObject)
	local list = panel:WaitForChild(GUI.List, 10)

	if not list then
		warn(`[ContractController]: could not find {GUI.ScreenGui}.{GUI.Wrapper}.{GUI.Panel}.{GUI.List}.`)
		return
	end

	self.RowMaid:DoCleaning()
	self.Sections = {}

	for kind, names in GUI.Sections do
		local frame = list:FindFirstChild(names.Frame)
		local header = list:FindFirstChild(names.Header)
		local template = frame and frame:FindFirstChild(GUI.Template)

		if not template then
			warn(`[ContractController]: no {names.Frame}.{GUI.Template} in {GUI.List} -- the {kind} section stays empty.`)
		else
			-- O molde sai da tela e fica so como fonte das linhas.
			template.Parent = nil
		end

		local timer = header and header:FindFirstChild(GUI.Timer)

		-- O dado de reroll do cabecalho. O clique vive no `RowMaid`, como os das
		-- linhas: uma copia nova da `Contracts` liga os botoes dela.
		local reroll = header and header:FindFirstChild(ContractConfig.Reroll.Button)
		if reroll and reroll:IsA("GuiButton") then
			self.RowMaid:GiveTask(reroll.Activated:Connect(function()
				self:_promptReroll(kind)
			end))

			ButtonUtil.bindFeedback(reroll, self.RowMaid)
		elseif header then
			warn(`[ContractController]: no {ContractConfig.Reroll.Button} in {names.Header} -- the {kind} reroll does nothing.`)
		end

		self.Sections[kind] = {
			Frame = frame,
			Template = template,
			Timer = timer and timer:IsA("TextLabel") and timer or nil,
			Rows = {},
		}
	end

	self:_render()
	self:_updateTimers()
end

--[=[
	Liga o botao da HUD, que leva o jogador ate o quadro.

	Maid proprio: a `HUD` e a `Contracts` sao `ScreenGui` diferentes e a engine as
	refaz em momentos diferentes (a HUD a cada respawn), entao o bind de uma nao pode
	desconectar o da outra -- a `Contracts` e seguida pelo `ProximityPanel`.
]=]
function ContractController:_bindHud(screenGui : ScreenGui)
	local hudFrame = screenGui:WaitForChild(HUD_FRAME_NAME, WAIT_TIMEOUT)
	local button = hudFrame and UIUtil.waitForDescendant(hudFrame, HUD_BUTTON_NAME, WAIT_TIMEOUT)

	if not button or not button:IsA("GuiButton") then
		if not self.WarnedButton then
			self.WarnedButton = true
			warn(`[ContractController]: nao achei {HUD_UI_NAME}.{HUD_FRAME_NAME}.{HUD_BUTTON_NAME}.`)
		end

		return
	end

	self.HudMaid:DoCleaning()
	self.HudMaid:GiveTask(button.Activated:Connect(function()
		self:TeleportToBoard()
	end))
end

--- A HUD, pelo botao que leva ate o quadro.
function ContractController:_observeUI()
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

function ContractController:_watchProfile()
	task.spawn(function()
		local replica = self.Controllers.DataController:GetReplica()
		self.Replica = replica

		self:_render()

		local connection = replica:OnChange(function(_action, path)
			local key = path[1]
			if key ~= nil and key ~= "Contracts" then
				return
			end

			self:_render()
		end)

		self.Maid:GiveTask(function()
			connection:Disconnect()
		end)
	end)
end

function ContractController:_watchTimers()
	local clock = 0

	self.Maid:GiveTask(RunService.Heartbeat:Connect(function(deltaTime : number)
		clock += deltaTime
		if clock < TIMER_INTERVAL then return end

		clock = 0
		self:_updateTimers()
	end))
end

--[[ EXTERNAL ]]

function ContractController:IsOpen() : boolean
	return self.Proximity ~= nil and self.Proximity:IsOpen()
end

function ContractController:Open()
	if self.Proximity then
		self.Proximity:Open()
	end
end

function ContractController:Close()
	if self.Proximity then
		self.Proximity:Close()
	end
end

function ContractController:Toggle()
	if self.Proximity then
		self.Proximity:Toggle()
	end
end

--[=[
	Larga o jogador em cima da `TargetPart` do quadro.

	O cliente e dono do proprio personagem, entao mover aqui basta: o servidor ve a
	posicao nova pela replicacao de sempre.

	O pouso e **dentro** do raio, porque a peca do pouso e a propria referencia. Ainda
	assim a abertura e na mao, pelo `EnterRange`: a medida so roda a cada
	`ProximityInterval`, e assim o quadro abre junto com o teleporte -- com a entrada
	marcada, para andar embora fechar do mesmo jeito.
]=]
function ContractController:TeleportToBoard() : boolean
	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild(CHARACTER_ROOT)

	if not root then
		return false
	end

	local target = self:_board()
	if not target then
		return false
	end

	character:PivotTo(target.CFrame * CFrame.new(0, target.Size.Y / 2 + BOARD.TeleportHeightOffset, 0))

	-- Sem isto o jogador mantem a velocidade que tinha e escorrega para fora do quadro.
	root.AssemblyLinearVelocity = Vector3.zero

	if self.Proximity then
		self.Proximity:EnterRange()
	end

	return true
end

function ContractController:construct()
	Framework:Listen("ContractClaimResult", function(_kind, _index, success : boolean, reason : string?)
		if success then
			local music = self.Controllers.MusicController
			if music then
				music:PlaySFX(CLAIM_SOUND, { Key = CLAIM_SOUND_KEY })
			end
		elseif reason then
			warn(`[ContractController]: claim refused ({reason}).`)
		end
	end)

	local music = self.Controllers.MusicController
	if music then
		music:PreloadSFX({ CLAIM_SOUND })
	end

	self.Proximity = ProximityPanel.new({
		Name = "ContractController",
		ScreenGui = GUI.ScreenGui,
		Wrapper = GUI.Wrapper,
		Panel = GUI.Panel,
		Animation = BOARD.Animation,
		HideReason = HIDE_REASON,
		GetReference = function()
			local target = self:_board()
			return target and target.Position or nil
		end,
		Radius = BOARD.OpenRadius,
		Interval = BOARD.ProximityInterval,
		InterfaceController = self.Controllers.InterfaceController,

		OnBind = function(_screenGui, _wrapper, panel)
			self:_onBind(panel)
		end,

		BeforeOpen = function()
			self:_render()
			self:_updateTimers()

			--[[
				O quadro foi lido: o selo de "os contratos resetaram" se encerra aqui. O de
				claim pendente **nao** -- aquele sai quando o contrato for claimado, e quem o
				apaga e o proprio perfil.
			]]
			local badges = self.Controllers.HUDBadgeController
			if badges then
				badges:NoteSeen(HUD_BUTTON_NAME)
			end
		end,
	})

	self.Maid:GiveTask(function()
		self.Proximity:Destroy()
	end)

	self.Proximity:Start()

	self:_observeUI()
	self:_watchProfile()
	self:_watchTimers()
end

function ContractController:start()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	self:construct()
end

function ContractController:init()
	self.Maid = Maid.new()

	-- As linhas desenhadas e os cliques delas, por copia da `Contracts`.
	self.RowMaid = Maid.new()
	self.Maid:GiveTask(self.RowMaid)

	-- [kind] = { Frame, Template, Timer, Rows = { { Row, Task, Claim, ... } } }
	self.Sections = {}

	-- O clique do botao da HUD, que a engine refaz a cada respawn.
	self.HudMaid = Maid.new()
	self.Maid:GiveTask(self.HudMaid)

	self.Replica = nil
	self.Proximity = nil
	self.WarnedBoard = false
	self.WarnedButton = false
end

return ContractController
