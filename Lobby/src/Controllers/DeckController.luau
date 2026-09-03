local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Configs = Shared:WaitForChild("Config")
local Util = Shared:WaitForChild("Util")

local Maid = require(Vendor.Maid)
local Me = require(Vendor.Me)
local Signal = require(Packages.Signal)

local SharedConfig = require(Configs.SharedConfig)
local UIUtil = require(Util.UIUtil)

local CardConfig = SharedConfig.CardConfig
local ClassConfig = SharedConfig.ClassConfig
local DeckConfig = SharedConfig.DeckConfig
local RarityConfig = SharedConfig.RarityConfig
local UnitStats = SharedConfig.UnitStats
local UpgradeConfig = SharedConfig.UnitUpgradeConfig

local Framework = Me.new()

--[[ CONSTANTS ]]
local HUD_UI_NAME = "HUD"
local HUD_FRAME_NAME = "HUDFrame"
local HUD_BUTTON_NAME = "Deck"

local CARD_UI_NAME = "CardUI"
local INVENTORY_NAME = "Inventory"
local LIST_NAME = "ScrollingFrame"
local EQUIPPED_NAME = "EquippedCards"
local SELECTION_NAME = "SelectionPanel"
local CONTAINER_NAME = "Container"
local CLOSE_NAME = "Close"
local ERROR_NAME = "ErrorLabel"
local LIMIT_NAME = "CardsLimit"

local WRAPPER_NAME = "CardWrapper"
local CARD_NAME = "Card"
local EMPTY_CARD_NAME = "EmptyCard"
local LOCKED_FRAME_NAME = "LockedFrame"
local LOCK_TEXT_NAME = "LockText"
local UNIT_NAME_NAME = "UnitName"
local COUNT_NAME = "Count"
local BUTTON_NAME = "Button"

local EQUIP_TOGGLE_NAME = "EquipToggle"
local CLASS_ICON_NAME = "ClassIcon"
local DAMAGE_NAME = "DamagePerSecond"
local COOLDOWN_NAME = "AttackSpeed"
local RANGE_NAME = "Range"

local WAIT_TIMEOUT = 10

--[[
	O texto do slot travado. O `%d` e o nivel que ele pede
	(`DeckConfig.SLOT_UNLOCK_LEVELS`); a frase e a que o designer deixou autorada no
	`LockText`, com o `X` no lugar do numero.
]]
local LOCK_TEXT_FORMAT = "Unlocked at Level %d"

local OPEN_INFO = TweenInfo.new(0.32, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local CLOSE_INFO = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

-- A entrada das cartas: a posição estica (Back) e a opacidade só acompanha, mais
-- curta, porque transparência com overshoot passaria de 0 e piscaria.
local INTRO_MOVE_TIME = 0.42
local INTRO_FADE_TIME = 0.28
local INTRO_STAGGER = 0.035

-- Teto do atraso acumulado: com inventário grande, a última carta não pode
-- demorar meio minuto para entrar.
local INTRO_MAX_DELAY = 0.9

-- De onde toda carta vem na abertura. É a posição dentro do próprio wrapper — o
-- wrapper é quem o UIGridLayout coloca no lugar, então animar a carta não briga
-- com a grade.
local INTRO_FROM_POSITION = UDim2.fromScale(0, 0)

-- A carta que viaja entre o inventário e o deck. O clone voa por cima de tudo,
-- então o ZIndex é bem acima dos painéis (que estão em 1) -- o HUD é
-- `ZIndexBehavior.Sibling`, então isso basta.
local FLIGHT_INFO = TweenInfo.new(0.8, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut)
local FLIGHT_ZINDEX = 50
local FLIGHT_NAME = "FlyingCard"

-- Quando a lista se reacomoda (uma unidade acabou e a linha dela saiu), o wrapper
-- pula direto para a célula nova e é a carta de dentro que faz o caminho.
local SLIDE_INFO = TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

-- O EquipToggle é só o estado "pode equipar", e a cor dele vem autorada na GUI.
-- Quando não há o que equipar o botão some, em vez de virar um "desequipar".
local EQUIP_TEXT = "Equip"

-- O som de toda carta clicada, em SoundService.SharedSounds.SFX.
local CARD_SOUND = "CardFlip"

local LIMIT_FORMAT = "%d/%d"
local LIMIT_ERROR = "Your deck is full — %d/%d cards."
local COPIES_ERROR = "You have no spare %s cards."
local ERROR_DURATION = 3

--[[ HELPERS ]]

--[=[
	Número com no máximo `decimals` casas e sem zeros sobrando: 12.00 -> "12".
	Mesmo formato do card de upgrade do Game (`ToggleTower`).
]=]
local function formatNumber(value : number, decimals : number?) : string
	local text = string.format("%." .. (decimals or 0) .. "f", value)

	if text:find("%.") then
		text = text:gsub("0+$", "")
		text = text:gsub("%.$", "")
	end

	return text
end

local function formatStat(value : number) : string
	if value >= 1000 then
		return UIUtil.formatAbbreviated(math.floor(value + 0.5))
	end

	return formatNumber(value, 1)
end

--[=[
	Dano por golpe da unidade sem upgrade nenhum, ou a renda por wave quando ela é
	uma Farm — que não ataca. É o mesmo texto que o card de upgrade mostra em
	partida, só que no nível 0 e sem clima: no lobby não existe nem um nem outro.
]=]
local function formatDamageOrIncome(unitName : string) : string
	local stats = UnitStats[unitName]
	local farm = stats and stats.Farm

	if farm then
		return "$" .. UIUtil.formatAbbreviated(farm.Income or 0) .. " INCOME"
	end

	return formatStat(UpgradeConfig:GetDamage(unitName, 0)) .. " DMG"
end

--[=[
	Onde a unidade fica na lista do inventário: da raridade mais alta para a mais
	baixa, e alfabética dentro da faixa. É uma ordem que só depende do nome, então
	dá para saber onde uma carta vai cair antes de ela existir.
]=]
local function sortByRarity(a : string, b : string) : boolean
	local orderA = RarityConfig.getOrder(UnitStats[a].Rarity) or 0
	local orderB = RarityConfig.getOrder(UnitStats[b].Rarity) or 0

	if orderA ~= orderB then
		return orderA > orderB
	end

	return a < b
end

--[=[
	As transparências que a carta tem **antes** de qualquer animação mexer nela,
	uma entrada por objeto — a carta, os textos, os contornos.

	É lido do próprio objeto, e não de uma tabela de valores fixos, porque o alvo
	do fade é "o que o designer deixou": um contorno que veio meio apagado volta
	meio apagado.

	Só vale se for chamado antes da primeira animação. Carta do inventário é
	clonada e lida na hora; carta de slot é lida uma vez, no bind.
]=]
local function captureFades(card : GuiObject)
	local fades = {}

	local function add(object : Instance)
		local goal = nil

		if object:IsA("UIStroke") then
			goal = { Transparency = object.Transparency }
		elseif object:IsA("ImageLabel") or object:IsA("ImageButton") then
			goal = {
				BackgroundTransparency = object.BackgroundTransparency,
				ImageTransparency = object.ImageTransparency,
			}
		elseif object:IsA("TextLabel") or object:IsA("TextButton") then
			goal = {
				BackgroundTransparency = object.BackgroundTransparency,
				TextTransparency = object.TextTransparency,
				TextStrokeTransparency = object.TextStrokeTransparency,
			}
		elseif object:IsA("GuiObject") then
			goal = { BackgroundTransparency = object.BackgroundTransparency }
		end

		if goal then
			table.insert(fades, { Object = object, Goal = goal })
		end
	end

	add(card)
	for _, descendant in card:GetDescendants() do
		add(descendant)
	end

	return fades
end

--[=[
	Tudo o que a animação de entrada precisa saber sobre uma carta: onde ela
	descansa e quão opaca ela é quando está parada.
]=]
local function captureIntro(card : GuiObject)
	return {
		Card = card,
		Position = card.Position,
		Fades = captureFades(card),
	}
end

--[=[
	Coloca a carta no estado de saída: no canto do wrapper e invisível.
]=]
local function applyIntroStart(entry)
	entry.Card.Position = INTRO_FROM_POSITION

	for _, fade in entry.Fades do
		for property, _ in fade.Goal do
			fade.Object[property] = 1
		end
	end
end

--[=[
	Coloca a carta no estado final na hora, sem animar. É o que vale quando a
	lista é redesenhada com o painel já aberto — equipar uma carta não pode fazer
	a tela inteira entrar de novo.
]=]
local function applyIntroEnd(entry)
	entry.Card.Position = entry.Position

	for _, fade in entry.Fades do
		for property, value in fade.Goal do
			fade.Object[property] = value
		end
	end
end

--[=[
	Dono do `StarterGui.HUD.CardUI`: o inventário de unidades, o deck equipado e o
	painel de detalhe.

	O botão `HUDFrame.Deck` abre e fecha (o mesmo botão com o painel aberto
	fecha), e a abertura é um tween do `UIScale` de 0 até a escala que veio
	autorada.

	**Uma carta por clique.** Quem põe carta no deck é o `EquipToggle`, com a
	unidade selecionada — a carta do inventário só **mostra**, ela não equipa. O botão
	some quando não sobra cópia no inventário, e tirar carta é só clicando na carta do
	próprio deck. Toda troca é uma carta clonada que voa até o destino.

	**No PC existe um atalho:** o botão direito numa carta do inventário seleciona e
	já equipa, sem a ida ao `EquipToggle`. É o mesmo caminho de equipar, com as
	mesmas checagens — o que muda é só quantos cliques custa.

	**O lado de onde a carta saiu muda na hora; o lado onde ela vai cair espera o
	pouso.** Os dois são desenhados separadamente (`_renderInventory` e
	`_renderSlots`), e cada um fica parado enquanto houver carta voando para ele —
	é o que segura o `EmptyCard` visível, ou a carta fora da lista, até ela chegar.

	Clicar em rajada é para funcionar: cada clique solta mais uma carta, e o que
	decide se ele vale é o `Projected` — o deck contando o que ainda está no ar,
	que é o que o servidor já gravou, e não o que a tela está mostrando.

	Nada aqui decide o que o jogador tem: o inventário, o deck e o limite saem da
	replica do perfil (`Units`, `EquippedUnits`, `CardLimit`), e o clique só pede a
	troca ao `DeckService`.

	O HUD tem `ResetOnSpawn` ligado, então o bind roda de novo a cada respawn.
]=]
local DeckController = {
	Controllers = {
		DataController = {},
		MusicController = {},
	},

	Signals = {
		-- (isOpen : boolean)
		OpenChanged = Signal.new(),

		-- (unitName : string?) — a carta que o painel de detalhe está mostrando.
		SelectionChanged = Signal.new(),
	},
}

--[[ INTERNAL ]]

function DeckController:_playTween(object : Instance, info : TweenInfo, goal : { [string]: any }, maid) : Tween
	local tween = TweenService:Create(object, info, goal)
	local owner = maid or self.TweenMaid

	owner:GiveTask(function()
		tween:Cancel()
	end)

	tween:Play()

	return tween
end

--[=[
	O inventário do perfil (`{[nome] = quantidade}`), ou uma tabela vazia enquanto
	a replica não chegou.
]=]
function DeckController:_getUnits() : { [string]: number }
	local replica = self.Replica

	return replica and replica.Data and replica.Data.Units or {}
end

function DeckController:_getLimit() : number
	local replica = self.Replica
	local data = replica and replica.Data

	return DeckConfig.resolveLimit(data and data.CardLimit)
end

--[=[
	Quantos slots o jogador tem hoje.

	Sai do `Stats.XP` da replica pelo mesmo `DeckConfig` que o servidor usa, entao os
	dois chegam ao mesmo numero sem trocar nada -- o cliente conta junto so para
	desenhar o cadeado e recusar o clique antes da resposta. Quem decide continua
	sendo o `DeckService`.

	Tres enquanto a replica nao chegou, que e o que todo jogador tem.
]=]
function DeckController:_getUnlocked() : number
	local replica = self.Replica
	local data = replica and replica.Data

	if not data then
		return DeckConfig.unlockedSlots(1)
	end

	return DeckConfig.unlockedFor(data)
end

function DeckController:_getEquipped() : DeckConfig.Deck
	local replica = self.Replica
	local raw = replica and replica.Data and replica.Data.EquippedUnits

	return DeckConfig.sanitize(raw, self:_getUnits(), self:_getLimit(), self:_getUnlocked())
end

--[=[
	As unidades que têm linha na lista do inventário, na ordem em que elas aparecem.

	Unidade com todas as cópias equipadas some daqui — é o que apaga a carta do
	inventário quando o jogador equipa a última —, **a não ser** que ela tenha uma
	carta voltando do deck: aí a linha continua, escondida, guardando o lugar onde a
	carta vai pousar. Unidade que sumiu do `UnitStats` (renomeada, cortada) fica de
	fora de qualquer jeito: o card não teria número nenhum para mostrar.
]=]
function DeckController:_sortedUnits(
	units : { [string]: number },
	tally : { [string]: number },
	incoming : { [string]: number }?
) : { string }
	local names = {}

	for unitName, count in units do
		if not DeckConfig.exists(unitName) then
			if not self.WarnedMissing[unitName] then
				self.WarnedMissing[unitName] = true
				warn(`[DeckController]: o perfil tem "{unitName}", que não está no UnitStats.`)
			end

			continue
		end

		local remaining = (count or 0) - (tally[unitName] or 0)
		if remaining <= 0 and not (incoming and incoming[unitName]) then
			continue
		end

		table.insert(names, unitName)
	end

	table.sort(names, sortByRarity)

	return names
end

--[=[
	A arte da carta da unidade.

	O `Card` é um ImageLabel e a arte dele é a **carta inteira** — moldura,
	ilustração e fundo numa imagem só —, então trocar de unidade é trocar a imagem.
	Os ids ficam em `SharedConfig.CardConfig`, os mesmos que a hotbar do Game usa.

	Unidade sem id fica com a arte que a GUI trouxe autorada: carta com a arte
	errada é melhor do que carta em branco no meio do inventário. O `EmptyCard` do
	slot livre tem arte própria e não passa por aqui.
]=]
local function writeCardImage(card : GuiObject, unitName : string)
	if not card:IsA("ImageLabel") and not card:IsA("ImageButton") then
		return
	end

	local image = CardConfig.GetImage(unitName)
	if not image then
		return
	end

	card.Image = image
end

--[=[
	A identidade da carta: de que unidade ela é.

	A arte, o nome e o contorno na cor da raridade — o nome é o único lugar da carta
	onde a raridade cabe, e sem ele o inventário inteiro é roxo.

	Nada disso muda enquanto a carta for daquela unidade, então a linha do inventário
	só escreve isso quando nasce. A carta de slot passa por aqui a cada redesenho,
	porque ela é fixa e troca de unidade conforme o deck muda.
]=]
local function writeCardName(card : GuiObject, unitName : string)
	card:SetAttribute("Unit", unitName)
	writeCardImage(card, unitName)

	local nameLabel = card:FindFirstChild(UNIT_NAME_NAME)
	if not nameLabel or not nameLabel:IsA("TextLabel") then
		return
	end

	nameLabel.Text = unitName
	nameLabel.Visible = true

	local stroke = nameLabel:FindFirstChildOfClass("UIStroke")
	local stats = UnitStats[unitName]
	local color = stats and RarityConfig.getColor(stats.Rarity)

	if stroke and color then
		stroke.Color = color
	end
end

--[=[
	O contador da carta. É o que de fato muda de um redesenho para o outro.
]=]
local function writeCardCount(card : GuiObject, count : number?)
	local countHolder = card:FindFirstChild(COUNT_NAME)
	local countLabel = countHolder and countHolder:FindFirstChild(COUNT_NAME)

	if countLabel and countLabel:IsA("TextLabel") then
		countLabel.Text = `{count or 0}x`
	end
end

--[=[
	Escreve uma carta inteira e liga o clique dela. É o caminho das cartas dos slots,
	que são instâncias fixas e trocam de unidade conforme o deck muda.
]=]
function DeckController:_fillCard(card : GuiObject, unitName : string, count : number, onClick : (() -> ())?, maid)
	writeCardName(card, unitName)
	writeCardCount(card, count)

	local button = card:FindFirstChild(BUTTON_NAME)
	if button and button:IsA("GuiButton") and onClick and maid then
		maid:GiveTask(button.Activated:Connect(onClick))
	end
end


--[=[
	Onde a carta que sai do deck vai pousar: a linha daquela unidade no inventário.

	Ela é saída normal do `_renderInventory` — a unidade que tem carta a caminho
	sempre ganha uma linha, escondida se ela não tinha nenhuma cópia sobrando.

	Só espera um frame quando a linha acabou de nascer: o `UIGridLayout` posiciona o
	wrapper novo no fim do frame, e sem essa espera a carta voaria para onde ele
	*estava*. Linha que já existia não move, então a viagem começa na hora.
]=]
function DeckController:_inventoryTarget(unitName : string, isNew : boolean) : GuiObject?
	if isNew then
		task.wait()
	end

	local entry = self.InventoryByUnit[unitName]

	return entry and entry.Card or nil
end

--[=[
	A posição (centro) e o tamanho de uma carta em escala do `CardUI`, que é onde o
	clone que viaja mora. Sair do absoluto é o que permite voar entre a lista com
	rolagem e o quadro do deck, que não têm nada em comum além do painel.
]=]
function DeckController:_rectToScale(card : GuiObject) : (UDim2, UDim2)
	local cardUI = self.CardUI
	local size = cardUI.AbsoluteSize

	if size.X <= 0 or size.Y <= 0 then
		return UDim2.fromScale(0.5, 0.5), UDim2.fromScale(0.2, 0.2)
	end

	local center = card.AbsolutePosition + card.AbsoluteSize / 2
	local offset = center - cardUI.AbsolutePosition

	return UDim2.fromScale(offset.X / size.X, offset.Y / size.Y),
		UDim2.fromScale(card.AbsoluteSize.X / size.X, card.AbsoluteSize.Y / size.Y)
end

--[=[
	Corta a animação de abertura e põe toda carta no lugar de uma vez.

	Quem clica antes de a entrada terminar não pode ver a carta voar para onde o
	destino *ainda estava chegando* — nem sair de uma carta pela metade da opacidade.
]=]
function DeckController:_finishIntro()
	self.AnimMaid:DoCleaning()

	for _, entry in self.InventoryEntries do
		if entry.Intro then
			applyIntroEnd(entry.Intro)
		end
	end

	for _, slot in self.Slots do
		applyIntroEnd(slot.CardIntro)
		applyIntroEnd(slot.EmptyIntro)
	end
end

--[=[
	Deixa o clone com cara de carta que viaja.

	O contador sai: quantas cartas existem de cada lado é conversa das cartas que
	estão paradas, e o número da origem já nasce velho no instante em que o clone
	sai — mais ainda com várias viagens no ar ao mesmo tempo.

	O nome **e a arte** são reescritos porque a origem pode estar escondida e ainda
	mostrando outra unidade: é o caso do slot que só vai ser preenchido quando a
	carta anterior pousar. Sem isso, a carta que voa sai com a cara da unidade
	errada.
]=]
function DeckController:_dressClone(clone : GuiObject, unitName : string)
	clone.Name = FLIGHT_NAME
	clone.AnchorPoint = Vector2.new(0.5, 0.5)
	clone.ZIndex = FLIGHT_ZINDEX
	clone.Visible = true

	local countHolder = clone:FindFirstChild(COUNT_NAME)
	if countHolder then
		countHolder:Destroy()
	end

	writeCardImage(clone, unitName)

	local nameLabel = clone:FindFirstChild(UNIT_NAME_NAME)
	local stats = UnitStats[unitName]

	if nameLabel and nameLabel:IsA("TextLabel") then
		nameLabel.Text = unitName
		nameLabel.Visible = true

		local stroke = nameLabel:FindFirstChildOfClass("UIStroke")
		local color = stats and RarityConfig.getColor(stats.Rarity)

		if stroke and color then
			stroke.Color = color
		end
	end

	-- O clone é enfeite: o botão dele não pode equipar nada.
	for _, descendant in clone:GetDescendants() do
		if descendant:IsA("GuiButton") then
			descendant.Interactable = false
			descendant.Active = false
			descendant.Selectable = false
		end
	end
end

--[=[
	Solta o clone que viaja de `sourceCard` até `targetCard`. Quem já registrou a
	viagem é o pedido — aqui só se preenche o clone e o tween dela.
]=]
function DeckController:_launchFlight(flight, sourceCard : GuiObject?, targetCard : GuiObject?)
	-- Entre registrar a viagem e chegar aqui existe um frame (o que o
	-- `_inventoryTarget` cede), e nele o painel pode ter fechado ou o jogador
	-- renascido — os dois encerram tudo o que estava no ar. Sem esta guarda, o
	-- clone nasceria para uma viagem que ninguém mais acompanha.
	if not table.find(self.Flights, flight) then
		return
	end

	local cardUI = self.CardUI

	if not cardUI or not cardUI.Parent or not sourceCard or not targetCard then
		self:_endFlight(flight)
		return
	end

	self:_finishIntro()
	self:_playCardSound()

	local clone = sourceCard:Clone()
	self:_dressClone(clone, flight.Unit)

	local fromPosition, fromSize = self:_rectToScale(sourceCard)
	local toPosition, toSize = self:_rectToScale(targetCard)

	clone.Position = fromPosition
	clone.Size = fromSize
	clone.Rotation = sourceCard.Rotation
	clone.Parent = cardUI

	flight.Clone = clone

	local tween = TweenService:Create(clone, FLIGHT_INFO, {
		Position = toPosition,
		Size = toSize,
		Rotation = targetCard.Rotation,
	})

	flight.Tween = tween

	tween.Completed:Connect(function(state : Enum.PlaybackState)
		-- Cancelado é o caminho de quem já encerrou a viagem (fechar o painel, um
		-- respawn, uma recusa do servidor): quem faz o pouso valer é só o tween que
		-- chegou ao fim.
		if state ~= Enum.PlaybackState.Completed then
			return
		end

		self:_endFlight(flight)
	end)

	tween:Play()
end

--[=[
	Registra uma viagem. Enquanto houver **alguma** no ar, a tela não é
	redesenhada: é isso que segura cada slot no estado antigo até a carta dele
	pousar, mesmo com outras cartas saindo no meio do caminho.
]=]
function DeckController:_addFlight(flight)
	table.insert(self.Flights, flight)
end

--[=[
	Fim de uma viagem: o clone some e a tela é redesenhada. O lado que estava
	esperando esta carta só é liberado se ela era a última a caminho dele — é aí que
	o slot troca `EmptyCard` por `Card`, ou que a carta reaparece no inventário.

	`silent` só encerra, sem redesenhar: é para quem vai redesenhar por conta
	própria depois de encerrar todas.
]=]
function DeckController:_endFlight(flight, silent : boolean?)
	local index = table.find(self.Flights, flight)
	if not index then
		return
	end

	table.remove(self.Flights, index)

	if flight.Tween then
		flight.Tween:Cancel()
		flight.Tween = nil
	end

	if flight.Clone then
		flight.Clone:Destroy()
		flight.Clone = nil
	end

	if not silent then
		self:_render()
	end
end

function DeckController:_endAllFlights()
	while #self.Flights > 0 do
		self:_endFlight(self.Flights[#self.Flights], true)
	end
end

--[=[
	Mexe no deck que o cliente acredita ser o verdadeiro (`Projected`): o que a
	replica diz mais o que já foi pedido e ainda está no ar.

	É contra ele que os cliques são validados e é dele que sai o slot de destino —
	a tela pode estar dois cliques atrasada, mas o que o servidor já gravou não
	está. O `_render` do último pouso ressincroniza tudo com o perfil.
]=]
function DeckController:_project(action : string, unitName : string)
	if action == "Equip" then
		DeckConfig.addCard(self.Projected, unitName, self:_getUnlocked())
	else
		DeckConfig.removeCard(self.Projected, unitName)
	end
end

--[=[
	Desfaz o que `_project` fez. É o caminho da recusa do servidor.
]=]
function DeckController:_unproject(action : string, unitName : string)
	self:_project(if action == "Equip" then "Unequip" else "Equip", unitName)
end

--[=[
	Quantas cartas de cada unidade estão voando na direção desta ação — `"Equip"`
	para quem vai ao deck, `"Unequip"` para quem volta ao inventário.

	O que espera o pouso é a carta, não o painel: com uma carta indo para o deck e
	outra voltando para o inventário ao mesmo tempo, cada uma segura só o próprio
	slot (ou a própria linha da lista), e todo o resto dos dois lados continua
	respondendo na hora.
]=]
function DeckController:_incomingUnits(action : string) : { [string]: number }
	local counts = {}

	for _, flight in self.Flights do
		if flight.Action == action then
			counts[flight.Unit] = (counts[flight.Unit] or 0) + 1
		end
	end

	return counts
end

--[=[
	O deck do jeito que os **slots** têm direito de mostrar: o `Projected` sem as
	cartas que ainda estão voando para lá, para o slot só mudar quando a carta dele
	chegar. Sem carta no ar, é o `Projected`.
]=]
function DeckController:_landedDeck() : DeckConfig.Deck
	local deck = DeckConfig.copy(self.Projected)

	for _, flight in self.Flights do
		if flight.Action == "Equip" then
			DeckConfig.removeCard(deck, flight.Unit)
		end
	end

	return deck
end

--[=[
	Quantas cartas de cada unidade o **inventário** tem direito de considerar
	equipadas: as do `Projected` mais as que ainda estão voltando, que só saem da
	conta quando pousam.
]=]
function DeckController:_landedTally() : { [string]: number }
	local tally = DeckConfig.tally(self.Projected)

	for _, flight in self.Flights do
		if flight.Action == "Unequip" then
			tally[flight.Unit] = (tally[flight.Unit] or 0) + 1
		end
	end

	return tally
end

--[=[
	Manda equipar **uma** carta da unidade e solta a que viaja até o slot dela.

	As checagens daqui são as mesmas do `DeckService`, só que para o aviso sair na
	hora, sem ida e volta. Quem decide de verdade continua sendo o servidor — se
	ele recusar, a viagem é desfeita em `DeckCardResult`.
]=]
function DeckController:_requestEquip(unitName : string)
	if not self.CardUI then
		return
	end

	local units = self:_getUnits()
	local projected = self.Projected
	local owned = units[unitName] or 0

	if DeckConfig.countOf(projected, unitName) >= owned then
		self:_showError(string.format(COPIES_ERROR, unitName))
		return
	end

	local total = DeckConfig.total(projected)
	if total >= self.Limit then
		self:_showError(string.format(LIMIT_ERROR, total, self.Limit))
		return
	end

	-- Cópia de quem já está no deck vai para o slot dele; unidade nova, para o
	-- primeiro livre — que não é necessariamente o próximo da fila, já que um slot
	-- no meio pode ter esvaziado, e nunca é um que o nível ainda não abriu.
	local slotIndex = DeckConfig.slotIndexOf(projected, unitName)
		or DeckConfig.firstFreeSlot(projected, self:_getUnlocked())

	local slot = slotIndex and self.Slots[slotIndex]
	if not slot then
		-- Não sobrou slot destravado: ou o deck já tem uma unidade diferente em cada
		-- um, ou os que faltam ainda pedem nível.
		self:_showError()
		return
	end

	local source = self.InventoryByUnit[unitName]
	if not source then
		return
	end

	Framework:Fire("RequestEquipCard", unitName)

	local flight = { Action = "Equip", Unit = unitName }
	self:_addFlight(flight)
	self:_project("Equip", unitName)

	-- O clone sai antes do redesenho: a carta de origem pode ser justamente a que
	-- vai sumir da lista (era a última cópia), e depois não haveria de onde clonar
	-- nem de onde medir a posição de partida.
	self:_launchFlight(flight, source.Card, slot.Card)

	-- O lado de origem — o inventário — muda na hora. Os slots ficam parados: é
	-- para lá que a carta está indo.
	self:_render()
end

--[=[
	Manda tirar **uma** carta da unidade e solta a que viaja de volta para o
	inventário. Se a unidade estava com todas as cópias no deck, a carta de destino
	é criada escondida antes da viagem.
]=]
function DeckController:_requestUnequip(unitName : string)
	if not self.CardUI then
		return
	end

	local slotIndex = DeckConfig.slotIndexOf(self.Projected, unitName)
	local slot = slotIndex and self.Slots[slotIndex]

	if not slot then
		return
	end

	Framework:Fire("RequestUnequipCard", unitName)

	-- A viagem é registrada antes do `_render`: é ela que diz ao inventário que tem
	-- carta chegando, e portanto que a linha de destino tem que existir.
	local flight = { Action = "Unequip", Unit = unitName }
	self:_addFlight(flight)
	self:_project("Unequip", unitName)

	-- Se a unidade estava com todas as cópias no deck, a linha dela vai nascer agora
	-- e o layout precisa de um frame; se ela já estava na lista, não precisa.
	local isNew = self.InventoryByUnit[unitName] == nil

	-- O lado de origem — os slots — muda na hora. O inventário fica parado: é para
	-- lá que a carta está indo.
	self:_render()

	-- Clonar depois do redesenho não é problema: o `_dressClone` reescreve o nome e
	-- devolve a visibilidade, e a posição do slot não muda com o conteúdo dele.
	local destination = self:_inventoryTarget(unitName, isNew)
	self:_launchFlight(flight, slot.Card, destination)
end

--[=[
	Redesenha o inventário, os seis slots e o contador a partir da replica.

	Roda a cada escrita do servidor em `Units`, `EquippedUnits` ou `CardLimit`, no
	bind, a cada clique e a cada pouso. Quem decide o que de fato é redesenhado são
	os dois lados: cada um se recusa a mudar enquanto houver carta voando para ele.
	Com o painel aberto as cartas nascem prontas (`applyIntroEnd`); a animação de
	entrada é só da abertura.
]=]
function DeckController:_render()
	if not self.CardUI or not self.CardUI.Parent or not self.Template then
		return
	end

	local units = self:_getUnits()

	-- Sem nada no ar, o que o cliente acha e o que o perfil diz voltam a ser a
	-- mesma coisa. Com carta voando, o `Projected` é quem manda: ele já tem o que
	-- a replica pode ainda não ter recebido.
	if #self.Flights == 0 then
		self.Projected = DeckConfig.copy(self:_getEquipped())
	end

	self.Limit = self:_getLimit()

	self:_renderInventory(units)
	self:_renderSlots()

	-- A unidade selecionada pode ter saído do perfil no meio do caminho.
	if self.SelectedUnit and (units[self.SelectedUnit] or 0) <= 0 then
		self.SelectedUnit = nil
		self.Signals.SelectionChanged:Fire(nil)
	end

	self:_renderSelection()
end

--[=[
	Reconstrói a lista do inventário.

	A unidade que tem carta voando **para cá** fica com o número de antes, e entra
	escondida se ela não tinha carta nenhuma na lista — é isso que segura o pouso.
	Todo o resto da lista é do jeito que está agora: carta que saiu daqui some na
	hora, porque este é o lado de origem dela.
]=]
--[=[
	Cria a linha de uma unidade na lista.

	O que não muda enquanto a linha existir é escrito aqui, uma vez só: o nome, a cor
	da raridade e o clique. Carta escondida não recebe entrada, então a conexão pode
	ficar ligada mesmo quando a linha está só guardando o lugar de um pouso.
]=]
function DeckController:_createInventoryEntry(unitName : string)
	local wrapper = self.Template:Clone()
	local card = wrapper:FindFirstChild(CARD_NAME)

	if not card or not card:IsA("GuiObject") then
		wrapper:Destroy()
		return nil
	end

	wrapper.Name = unitName

	local entry = {
		Unit = unitName,
		Wrapper = wrapper,
		Card = card,

		-- Lido do clone intocado: é o valor "pré-runtime" que o fade tem que devolver
		-- no fim.
		Intro = captureIntro(card),
		Maid = Maid.new(),
	}

	entry.Maid:GiveTask(wrapper)
	entry.Maid:GiveTask(function()
		self:_cancelSlide(entry)
	end)

	writeCardName(card, unitName)

	local button = card:FindFirstChild(BUTTON_NAME)
	if button and button:IsA("GuiButton") then
		-- Carta do inventário só mostra: quem equipa é o `EquipToggle`, com a carta
		-- selecionada.
		entry.Maid:GiveTask(button.Activated:Connect(function()
			self:Select(unitName)
		end))

		-- O atalho de quem tem mouse: o botão direito seleciona **e** equipa, sem
		-- passar pelo `EquipToggle`. `MouseButton2Click` só existe para o botão
		-- direito de verdade, então toque e gamepad continuam no clique normal, que é
		-- só seleção. O equipar é o mesmo `_requestEquip` do toggle -- os mesmos
		-- tetos, o mesmo aviso quando não dá, a mesma carta voando para o slot livre.
		entry.Maid:GiveTask(button.MouseButton2Click:Connect(function()
			self:Select(unitName)
			self:_requestEquip(unitName)
		end))
	end

	-- Linha que nasce com o painel já aberto entra pronta: a animação de entrada é
	-- só da abertura.
	if self.IsOpenState then
		applyIntroEnd(entry.Intro)
	end

	wrapper.Parent = self.List

	return entry
end

--[=[
	Apaga todas as linhas. Só no bind e no fim da vida do controller — o redesenho
	normal tira uma por uma.
]=]
function DeckController:_clearInventory()
	for _, entry in self.InventoryByUnit do
		entry.Maid:DoCleaning()
	end

	self.InventoryEntries = {}
	self.InventoryByUnit = {}
end

--[=[
	Onde a célula de índice `index` fica dentro da lista, em pixels.

	A conta é a do próprio `UIGridLayout` (célula + espaçamento, preenchendo na
	horizontal), e serve para saber de quanto uma linha andou **sem** ter que esperar
	o layout recalcular: ler `AbsolutePosition` logo depois de mexer no `LayoutOrder`
	ainda devolve o valor velho, e esperar um frame faria a carta piscar na posição
	nova antes de voltar para animar.

	Só vale para a grade como ela está montada (alinhada no topo à esquerda). Se o
	alinhamento mudar, a última linha incompleta sai um pouco fora — o resto continua.
]=]
function DeckController:_cellOffset(index : number) : Vector2
	local grid = self.Grid
	local list = self.List

	if not grid or not list then
		return Vector2.zero
	end

	local cell = grid.AbsoluteCellSize
	local size = list.AbsoluteSize
	local padding = grid.CellPadding

	local padX = padding.X.Scale * size.X + padding.X.Offset
	local padY = padding.Y.Scale * size.Y + padding.Y.Offset

	local columns = grid.FillDirectionMaxCells

	-- Zero quer dizer "quantas couberem": a conta é a mesma que o layout faz.
	if columns <= 0 then
		columns = math.max(1, math.floor((size.X + padX) / math.max(cell.X + padX, 1)))
	end

	local slot = index - 1

	return Vector2.new(
		(slot % columns) * (cell.X + padX),
		math.floor(slot / columns) * (cell.Y + padY)
	)
end

function DeckController:_cancelSlide(entry)
	if entry.SlideTween then
		entry.SlideTween:Cancel()
		entry.SlideTween = nil
	end
end

--[=[
	Leva a carta da célula antiga para a nova.

	O wrapper já está na célula nova — quem o coloca lá é o `UIGridLayout`, e isso é
	instantâneo. O que se faz aqui é deslocar a carta de dentro pela diferença entre
	as duas células, de modo que ela continue **exatamente onde estava** na tela, e
	daí trazê-la de volta ao repouso animando.

	O deslocamento é em pixels somado à posição em escala que a carta tem autorada,
	então o alvo do tween é sempre a posição de repouso dela.
]=]
function DeckController:_slideCard(entry, fromIndex : number, toIndex : number)
	if not self.IsOpenState or not entry.Card.Visible then
		return
	end

	local offset = self:_cellOffset(fromIndex) - self:_cellOffset(toIndex)

	if offset.Magnitude < 0.5 then
		return
	end

	self:_cancelSlide(entry)

	local resting = entry.Intro.Position

	entry.Card.Position = resting + UDim2.fromOffset(offset.X, offset.Y)

	local tween = TweenService:Create(entry.Card, SLIDE_INFO, { Position = resting })
	entry.SlideTween = tween

	tween.Completed:Connect(function()
		if entry.SlideTween == tween then
			entry.SlideTween = nil
		end
	end)

	tween:Play()
end

function DeckController:_renderInventory(units : { [string]: number }?)
	units = units or self:_getUnits()

	-- Contagem "pousada": a carta que está voando para cá ainda conta como
	-- equipada, então a linha dela fica com o número antigo (ou fora da lista) até
	-- o pouso. Quem não tem carta no ar usa o número de agora.
	local landed = self:_landedTally()
	local incoming = self:_incomingUnits("Unequip")
	local names = self:_sortedUnits(units, landed, incoming)

	local wanted = {}
	for _, unitName in names do
		wanted[unitName] = true
	end

	--[[
		A lista é atualizada no lugar, e não refeita.

		Recriar todo wrapper a cada redesenho fazia o inventário piscar a cada pouso:
		as cartas eram destruídas e clonadas de novo, e o `AutomaticCanvasSize` da
		rolagem recalculava junto. Agora só sai quem não tem mais o que mostrar, só
		entra quem ainda não estava lá, e quem fica leva apenas o contador novo.
	]]
	for unitName, entry in self.InventoryByUnit do
		if not wanted[unitName] then
			entry.Maid:DoCleaning()
			self.InventoryByUnit[unitName] = nil
		end
	end

	self.InventoryEntries = {}

	for index, unitName in names do
		local entry = self.InventoryByUnit[unitName]

		if not entry then
			entry = self:_createInventoryEntry(unitName)

			if not entry then
				continue
			end

			self.InventoryByUnit[unitName] = entry
		end

		local remaining = (units[unitName] or 0) - (landed[unitName] or 0)

		-- Unidade sem cópia sobrando mas com carta a caminho: a linha continua,
		-- escondida, só para a grade guardar o espaço onde ela vai pousar.
		entry.Card.Visible = remaining > 0
		writeCardCount(entry.Card, remaining)

		-- O LayoutOrder é a ordem da lista: é o que faz a linha que nasce no meio de
		-- um desequipar abrir o buraco no lugar certo, e não no fim da grade.
		local previousIndex = entry.Index

		entry.Index = index
		entry.Wrapper.LayoutOrder = index

		-- Linha que mudou de célula porque outra saiu da lista: o wrapper vai direto,
		-- a carta faz o caminho. Linha recém-criada não tem de onde vir.
		if previousIndex and previousIndex ~= index then
			self:_slideCard(entry, previousIndex, index)
		end

		table.insert(self.InventoryEntries, entry)
	end
end

--[=[
	Reescreve os seis slots e o contador de cartas.

	O slot que tem carta voando **para cá** fica com o número de antes, e continua
	mostrando o `EmptyCard` se ele estava vazio — é isso que segura o pouso. Os
	outros cinco mudam na hora.

	Cada slot mostra **uma** de três coisas: a carta, a carta apagada (livre) ou a
	capa de travado, com o nível que ele pede. O deck que chega aqui já veio limpo
	pelo `sanitize`, então um slot travado nunca tem ocupante — a checagem do nível é
	sobre o que desenhar, e não sobre o que existe.
]=]
function DeckController:_renderSlots()
	self.SlotMaid:DoCleaning()

	local deck = self:_landedDeck()
	local unlocked = self:_getUnlocked()

	for index, slot in self.Slots do
		-- O slot é fixo: o que manda é a posição no deck, não a ordem de quem entrou.
		local occupant = deck[index]

		if typeof(occupant) ~= "table" then
			occupant = nil
		end

		local locked = index > unlocked

		if slot.Locked then
			slot.Locked.Visible = locked
		end

		if locked then
			-- O nível vem do config, e não do texto autorado: mudar a régua de
			-- desbloqueio é uma linha no `DeckConfig` e nada aqui.
			if slot.LockText then
				slot.LockText.Text = string.format(LOCK_TEXT_FORMAT, DeckConfig.slotUnlockLevel(index))
			end

			--[[
				A carta apagada fica **por baixo** da capa: o slot travado é um slot vazio
				que ainda não abriu, e sem ela o cadeado ficaria num buraco no meio da
				fileira em vez de sobre a moldura de um slot.

				A ordem na tela é a da árvore (`ZIndexBehavior.Sibling`), e o
				`LockedFrame` vem depois da `EmptyCard` e ainda por cima com `ZIndex`
				maior — a capa cobre a carta apagada, e não o contrário.
			]]
			slot.Card.Visible = false
			slot.Empty.Visible = true
			slot.Card:SetAttribute("Unit", nil)

			continue
		end

		-- Slot ocupado mostra a carta, slot livre mostra a carta apagada. Os dois
		-- nunca aparecem juntos.
		slot.Card.Visible = occupant ~= nil
		slot.Empty.Visible = occupant == nil

		if occupant then
			local unitName = occupant.Unit

			self:_fillCard(slot.Card, unitName, occupant.Amount, function()
				self:Select(unitName)
				self:_requestUnequip(unitName)
			end, self.SlotMaid)
		else
			slot.Card:SetAttribute("Unit", nil)
		end
	end

	-- O contador é do deck, então ele anda junto com os slots: cai na hora quando
	-- uma carta sai, sobe quando a que está voando chega.
	if self.LimitLabel then
		self.LimitLabel.Text = string.format(LIMIT_FORMAT, DeckConfig.total(deck), self.Limit)
	end
end

--[=[
	O som de carta virando. Toca quando uma carta **muda de lado** — sai do inventário
	para o deck, ou volta —, e não no clique: selecionar uma carta não move nada.

	Sai junto com o clone, e não no pouso: o som é a resposta ao clique.
]=]
function DeckController:_playCardSound()
	local music = self.Controllers.MusicController

	if music then
		music:PlaySFX(CARD_SOUND)
	end
end

--[=[
	Se ainda sobra cópia da unidade no inventário para pôr no deck.

	Lê o `Projected`, e não o que está desenhado: a carta que ainda está no ar já
	está gravada no perfil, e contar pela tela deixaria o jogador equipar a mesma
	cópia duas vezes.
]=]
function DeckController:_hasSpare(unitName : string) : boolean
	local owned = self:_getUnits()[unitName] or 0

	return owned - DeckConfig.countOf(self.Projected, unitName) > 0
end

--[=[
	O botão de equipar: uma carta da unidade selecionada por clique, e o **único**
	jeito de pôr carta no deck — a carta do inventário só seleciona.

	Ele **some** quando não sobra cópia no inventário, ou seja, quando a unidade está
	inteira no deck e não há mais o que equipar. Não existe estado de desequipar aqui:
	para tirar carta, clica-se na carta do próprio deck.

	A cor e o texto são reescritos junto com a visibilidade para o botão nunca
	depender de como a cópia da GUI chegou.
]=]
function DeckController:_renderEquipToggle(unitName : string)
	local toggle = self.EquipToggle
	if not toggle then
		return
	end

	toggle.Visible = self:_hasSpare(unitName)

	if not toggle.Visible then
		return
	end

	if self.EquipColor then
		toggle.ImageColor3 = self.EquipColor
	end

	if self.EquipLabel then
		self.EquipLabel.Text = EQUIP_TEXT
	end

	if self.EquipStrokeObject and self.EquipStroke then
		self.EquipStrokeObject.Color = self.EquipStroke
	end
end

--[=[
	Escreve o painel de detalhe da carta selecionada. Sem seleção ele some — é o
	estado em que o painel abre.
]=]
function DeckController:_renderSelection()
	local container = self.Container
	if not container then
		return
	end

	local unitName = self.SelectedUnit
	local stats = unitName and UnitStats[unitName]

	if not stats then
		container.Visible = false
		return
	end

	local card = container:FindFirstChild(CARD_NAME)

	if card then
		writeCardImage(card, unitName)
	end

	local nameLabel = card and card:FindFirstChild(UNIT_NAME_NAME)
	if nameLabel and nameLabel:IsA("TextLabel") then
		nameLabel.Text = unitName
		nameLabel.Visible = true

		local stroke = nameLabel:FindFirstChildOfClass("UIStroke")
		local color = RarityConfig.getColor(stats.Rarity)

		if stroke and color then
			stroke.Color = color
		end
	end

	local damage = container:FindFirstChild(DAMAGE_NAME)
	if damage and damage:IsA("TextLabel") then
		damage.Text = formatDamageOrIncome(unitName)
	end

	local cooldown = container:FindFirstChild(COOLDOWN_NAME)
	if cooldown and cooldown:IsA("TextLabel") then
		cooldown.Text = formatNumber(UpgradeConfig:GetCooldown(unitName, 0), 2) .. " COOLDOWN"
	end

	local range = container:FindFirstChild(RANGE_NAME)
	if range and range:IsA("TextLabel") then
		range.Text = formatStat(UpgradeConfig:GetRange(unitName, 0)) .. " RANGE"
	end

	-- Unidade sem classe (ou classe sem arte ainda) esconde o ícone em vez de
	-- mostrar um quadrado vazio — mesma regra do card de upgrade do Game.
	local classIcon = container:FindFirstChild(CLASS_ICON_NAME)
	if classIcon and classIcon:IsA("ImageLabel") then
		local image = ClassConfig.GetIcon(unitName)

		classIcon.Image = image or ""
		classIcon.Visible = image ~= nil
	end

	self:_renderEquipToggle(unitName)

	container.Visible = true
end

--[=[
	A entrada das cartas: todas saem do canto do wrapper, transparentes, e caem no
	lugar uma depois da outra.

	Os dois lados de um slot (a carta e a carta vazia) entram juntos, com o mesmo
	atraso: só um dos dois está visível, e dar um atraso a cada um abriria um
	buraco na ordem.

	O atraso vai no próprio `TweenInfo`, e não num `task.delay`: enquanto ele não
	vence, o tween não escreve nada e a carta fica parada onde `applyIntroStart` a
	deixou.
]=]
function DeckController:_playIntro()
	self.AnimMaid:DoCleaning()

	-- A entrada reposiciona toda carta: um deslize da lista que ainda estivesse
	-- correndo brigaria com ela pela mesma propriedade.
	for _, entry in self.InventoryEntries do
		self:_cancelSlide(entry)
	end

	local groups = {}

	for _, entry in self.InventoryEntries do
		if entry.Intro then
			table.insert(groups, { entry.Intro })
		end
	end

	for _, slot in self.Slots do
		table.insert(groups, { slot.CardIntro, slot.EmptyIntro })
	end

	for _, group in groups do
		for _, entry in group do
			applyIntroStart(entry)
		end
	end

	for index, group in groups do
		local delay = math.min((index - 1) * INTRO_STAGGER, INTRO_MAX_DELAY)
		local moveInfo = TweenInfo.new(INTRO_MOVE_TIME, Enum.EasingStyle.Back, Enum.EasingDirection.Out, 0, false, delay)
		local fadeInfo = TweenInfo.new(INTRO_FADE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, 0, false, delay)

		for _, entry in group do
			self:_playTween(entry.Card, moveInfo, { Position = entry.Position }, self.AnimMaid)

			for _, fade in entry.Fades do
				self:_playTween(fade.Object, fadeInfo, fade.Goal, self.AnimMaid)
			end
		end
	end
end

function DeckController:_hideError()
	self.ErrorToken += 1

	if self.ErrorLabel then
		self.ErrorLabel.Visible = false
	end
end

--[=[
	Acende o aviso vermelho por alguns segundos. Sem texto, volta o que veio
	autorado na GUI — que é o caso do deck sem slot livre.
]=]
function DeckController:_showError(message : string?)
	local label = self.ErrorLabel
	if not label then
		return
	end

	label.Text = message or self.DefaultError

	self.ErrorToken += 1
	local token = self.ErrorToken

	label.Visible = true

	task.delay(ERROR_DURATION, function()
		if self.ErrorToken ~= token or not label.Parent then
			return
		end

		label.Visible = false
	end)
end

--[=[
	A mensagem de cada recusa do servidor. Só chega aqui o que a checagem do
	cliente deixou passar — replica atrasada, ou duas abas do mesmo jogador.
]=]
function DeckController:_errorMessage(reason : string?, unitName : string) : string?
	if reason == "LimitReached" then
		return string.format(LIMIT_ERROR, self.Limit, self.Limit)
	end

	if reason == "NoCopies" or reason == "NotOwned" then
		return string.format(COPIES_ERROR, unitName)
	end

	-- "NoSlot" cai no texto autorado; o resto não é coisa que o jogador provoque.
	if reason ~= "NoSlot" then
		warn(`[DeckController]: o servidor recusou "{unitName}" — {tostring(reason)}.`)
	end

	return nil
end

function DeckController:_setOpen(open : boolean)
	local cardUI = self.CardUI
	if not cardUI or not cardUI.Parent or not self.Scale then
		return
	end

	if open == self.IsOpenState then
		return
	end

	self.IsOpenState = open
	self.TweenMaid:DoCleaning()

	if open then
		-- O painel abre sem carta selecionada, então o detalhe começa fechado.
		self.SelectedUnit = nil
		self:_render()
		self.Signals.SelectionChanged:Fire(nil)

		cardUI.Visible = true
		self.Scale.Scale = 0

		self:_playTween(self.Scale, OPEN_INFO, { Scale = self.ShownScale })
		self:_playIntro()
	else
		self.AnimMaid:DoCleaning()
		self:_hideError()

		-- Fechar com carta no ar não perde nada: a troca já está gravada no perfil, e
		-- o pouso vira o redesenho que acontece agora.
		if #self.Flights > 0 then
			self:_endAllFlights()
			self:_render()
		end

		local tween = self:_playTween(self.Scale, CLOSE_INFO, { Scale = 0 })
		tween.Completed:Once(function(state : Enum.PlaybackState)
			-- Reaberto no meio do fecha: quem manda no painel agora é o outro tween.
			if state == Enum.PlaybackState.Completed and not self.IsOpenState then
				cardUI.Visible = false
			end
		end)
	end

	self.Signals.OpenChanged:Fire(open)
end

--[=[
	Liga a uma cópia do CardUI. Roda de novo a cada respawn (`ResetOnSpawn`).
]=]
function DeckController:_bindUI(screenGui : ScreenGui)
	local cardUI = screenGui:WaitForChild(CARD_UI_NAME, WAIT_TIMEOUT)
	local inventory = cardUI and cardUI:WaitForChild(INVENTORY_NAME, WAIT_TIMEOUT)
	local list = inventory and inventory:WaitForChild(LIST_NAME, WAIT_TIMEOUT)
	local equippedFrame = cardUI and cardUI:WaitForChild(EQUIPPED_NAME, WAIT_TIMEOUT)
	local selection = cardUI and cardUI:WaitForChild(SELECTION_NAME, WAIT_TIMEOUT)
	local container = selection and selection:WaitForChild(CONTAINER_NAME, WAIT_TIMEOUT)
	local template = list and list:FindFirstChild(WRAPPER_NAME)

	if not cardUI or not list or not equippedFrame or not container or not template then
		warn(`[DeckController]: não achei a estrutura de {HUD_UI_NAME}.{CARD_UI_NAME}.`)
		return
	end

	self:_endAllFlights()

	self.UIMaid:DoCleaning()
	self:_clearInventory()
	self.SlotMaid:DoCleaning()
	self.TweenMaid:DoCleaning()
	self.AnimMaid:DoCleaning()

	self.CardUI = cardUI
	self.List = list

	-- A grade da lista: é dela que sai a conta de quanto uma linha andou quando a
	-- lista se reacomoda (ver `_cellOffset`).
	self.Grid = list:FindFirstChildOfClass("UIGridLayout")
	self.Container = container
	local limitLabel = cardUI:FindFirstChild(LIMIT_NAME)
	self.LimitLabel = if limitLabel and limitLabel:IsA("TextLabel") then limitLabel else nil

	local scale = cardUI:FindFirstChildOfClass("UIScale")
	if not scale then
		scale = Instance.new("UIScale")
		scale.Parent = cardUI
	end

	self.Scale = scale

	-- A escala "aberto" é a que o designer deixou na Studio, lida antes de
	-- qualquer animação mexer no valor.
	self.ShownScale = if scale.Scale > 0 then scale.Scale else 1

	-- O wrapper autorado é o molde, não uma carta: a lista inteira vem do
	-- inventário do perfil. O molde vive fora da DataModel e morre com o bind,
	-- senão cada respawn deixaria uma cópia para trás.
	self.Template = template:Clone()
	self.UIMaid:GiveTask(self.Template)

	for _, child in list:GetChildren() do
		if child.Name == WRAPPER_NAME then
			child:Destroy()
		end
	end

	self.InventoryEntries = {}
	self.InventoryByUnit = {}

	self.Slots = {}
	for _, wrapper in equippedFrame:GetChildren() do
		if not wrapper:IsA("GuiObject") or wrapper.Name ~= WRAPPER_NAME then
			continue
		end

		local card = wrapper:FindFirstChild(CARD_NAME)
		local emptyCard = wrapper:FindFirstChild(EMPTY_CARD_NAME)

		if not card or not emptyCard then
			warn(`[DeckController]: {WRAPPER_NAME} sem {CARD_NAME} ou {EMPTY_CARD_NAME}.`)
			continue
		end

		-- A capa do slot travado. Opcional de proposito: sem ela o slot travado so
		-- deixa de aceitar carta, em vez de o painel inteiro parar de desenhar.
		local lockedFrame = wrapper:FindFirstChild(LOCKED_FRAME_NAME)
		local lockText = lockedFrame and lockedFrame:FindFirstChild(LOCK_TEXT_NAME, true)

		if not lockedFrame then
			warn(`[DeckController]: {WRAPPER_NAME} sem {LOCKED_FRAME_NAME} -- o slot travado nao mostra cadeado.`)
		end

		-- A carta vazia é a mesma carta, apagada: ela segue a inclinação que o
		-- designer deu à carta cheia do slot (-4 ou 4), senão o slot livre entorta
		-- para o lado errado.
		emptyCard.Rotation = card.Rotation

		-- Os seis wrappers vêm todos com LayoutOrder 0, e aí a ordem na tela é a
		-- ordem na Explorer. Carimbar o índice deixa o primeiro slot sempre no
		-- primeiro lugar, e sem mudar nada do que o designer montou.
		wrapper.LayoutOrder = #self.Slots + 1

		table.insert(self.Slots, {
			Wrapper = wrapper,
			Card = card,
			Empty = emptyCard,
			Locked = lockedFrame,
			LockText = if lockText and lockText:IsA("TextLabel") then lockText else nil,
			CardIntro = captureIntro(card),
			EmptyIntro = captureIntro(emptyCard),
		})
	end

	if #self.Slots ~= DeckConfig.MAX_SLOTS then
		warn(`[DeckController]: {EQUIPPED_NAME} tem {#self.Slots} slots e o DeckConfig espera {DeckConfig.MAX_SLOTS}.`)
	end

	local toggle = container:FindFirstChild(EQUIP_TOGGLE_NAME)
	local toggleLabel = toggle and toggle:FindFirstChildWhichIsA("TextLabel")

	self.EquipToggle = toggle
	self.EquipLabel = toggleLabel
	self.EquipStrokeObject = toggleLabel and toggleLabel:FindFirstChildOfClass("UIStroke")

	-- O estado autorado é o "pode equipar": guardado da primeira cópia, que é a
	-- única garantidamente intocada.
	if not self.EquipColor and toggle then
		self.EquipColor = toggle.ImageColor3
		self.EquipStroke = self.EquipStrokeObject and self.EquipStrokeObject.Color
	end

	if toggle and toggle:IsA("GuiButton") then
		self.UIMaid:GiveTask(toggle.Activated:Connect(function()
			self:EquipSelected()
		end))
	end

	self.ErrorLabel = cardUI:FindFirstChild(ERROR_NAME)

	if self.ErrorLabel and not self.DefaultError then
		self.DefaultError = self.ErrorLabel.Text
	end

	local errorButton = self.ErrorLabel and self.ErrorLabel:FindFirstChild(BUTTON_NAME)
	if errorButton and errorButton:IsA("GuiButton") then
		self.UIMaid:GiveTask(errorButton.Activated:Connect(function()
			self:_hideError()
		end))
	end

	-- O `Close` já foi um TextLabel com um `Button` dentro e hoje é o botão em si:
	-- os dois formatos servem.
	local close = cardUI:FindFirstChild(CLOSE_NAME)
	local closeButton = if close and close:IsA("GuiButton")
		then close
		else close and close:FindFirstChild(BUTTON_NAME)

	if closeButton and closeButton:IsA("GuiButton") then
		self.UIMaid:GiveTask(closeButton.Activated:Connect(function()
			self:Close()
		end))
	end

	-- Cópia nova é respawn: o painel volta fechado e sem seleção.
	self.IsOpenState = false
	self.SelectedUnit = nil
	self:_hideError()

	cardUI.Visible = false
	scale.Scale = 0
	container.Visible = false

	self:_render()
end

--[=[
	Liga o botão do HUD. Ele mora dentro de um wrapper, então é procurado pelo nome
	em qualquer profundidade do frame — e quem anima o hover e o clique dele é o
	HUDButtonController, que cuida de todos os botões de lá.
]=]
function DeckController:_bindHud(screenGui : ScreenGui)
	local hudFrame = screenGui:WaitForChild(HUD_FRAME_NAME, WAIT_TIMEOUT)
	local button = hudFrame and UIUtil.waitForDescendant(hudFrame, HUD_BUTTON_NAME, WAIT_TIMEOUT)

	if not button or not button:IsA("GuiButton") then
		warn(`[DeckController]: não achei {HUD_UI_NAME}.{HUD_FRAME_NAME}.{HUD_BUTTON_NAME}.`)
		return
	end

	self.HudMaid:DoCleaning()
	self.HudMaid:GiveTask(button.Activated:Connect(function()
		-- O mesmo botão fecha o que ele abriu.
		self:Toggle()
	end))
end

function DeckController:_observeUI()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	local function onChild(child : Instance)
		if not child:IsA("ScreenGui") or child.Name ~= HUD_UI_NAME then
			return
		end

		self:_bindUI(child)
		self:_bindHud(child)
	end

	self.Maid:GiveTask(playerGui.ChildAdded:Connect(onChild))

	for _, child in playerGui:GetChildren() do
		task.spawn(onChild, child)
	end
end

--[=[
	Segura a replica do perfil e redesenha a cada escrita em `Units`,
	`EquippedUnits` ou `CardLimit`. É por aqui que o resultado de um equipar chega —
	o clique não mexe na tela sozinho.
]=]
function DeckController:_watchData()
	task.spawn(function()
		local replica = self.Controllers.DataController:GetReplica()
		self.Replica = replica

		self:_render()

		local connection = replica:OnChange(function(_action, path)
			local key = path[1]

			-- `Stats` entra na lista por causa do XP: os slots 4, 5 e 6 abrem por
			-- nivel, e sem isto um level-up so apareceria no painel na proxima vez que
			-- o jogador mexesse no deck.
			if key ~= nil
				and key ~= "Units"
				and key ~= "EquippedUnits"
				and key ~= "CardLimit"
				and key ~= "Stats"
			then
				return
			end

			self:_render()
		end)

		self.Maid:GiveTask(function()
			connection:Disconnect()
		end)
	end)
end

--[[ EXTERNAL ]]

function DeckController:IsOpen() : boolean
	return self.IsOpenState == true
end

function DeckController:Open()
	self:_setOpen(true)
end

function DeckController:Close()
	self:_setOpen(false)
end

function DeckController:Toggle()
	self:_setOpen(not self.IsOpenState)
end

--[=[
	A carta que o painel de detalhe mostra. `nil` fecha o painel.
]=]
function DeckController:Select(unitName : string?)
	if unitName ~= nil and not DeckConfig.exists(unitName) then
		return
	end

	if self.SelectedUnit == unitName then
		return
	end

	self.SelectedUnit = unitName
	self:_renderSelection()
	self.Signals.SelectionChanged:Fire(unitName)
end

--[=[
	O que o `EquipToggle` faz: põe uma carta da unidade selecionada no deck.

	Não faz nada sem cópia sobrando — nesse estado o botão está invisível, então isto
	só vale para quem chamar o método na mão.
]=]
function DeckController:EquipSelected()
	local unitName = self.SelectedUnit
	if not unitName or not self:_hasSpare(unitName) then
		return
	end

	self:_requestEquip(unitName)
end

function DeckController:construct()
	self:_observeUI()
	self:_watchData()

	Framework:Listen("DeckCardResult", function(unitName : string, action : string, success : boolean, reason : string?)
		if success then
			return
		end

		-- A viagem mais nova daquela carta é a que não aconteceu: ela some no meio
		-- do caminho e a tela volta ao que o perfil diz.
		for index = #self.Flights, 1, -1 do
			local flight = self.Flights[index]

			if flight.Unit == unitName and flight.Action == action then
				self:_unproject(action, unitName)
				self:_endFlight(flight)
				break
			end
		end

		self:_showError(self:_errorMessage(reason, unitName))
	end)
end

function DeckController:start()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	self:construct()
end

function DeckController:init()
	self.Maid = Maid.new()
	self.UIMaid = Maid.new()

	-- Cada linha do inventário tem o próprio maid (ela entra e sai da lista sozinha,
	-- ver `_renderInventory`); os slots são instâncias fixas e cabem num maid só.
	-- Separados porque os dois lados são redesenhados em momentos diferentes, e
	-- limpar um não pode desligar os botões do outro.
	self.SlotMaid = Maid.new()

	self.TweenMaid = Maid.new()
	self.AnimMaid = Maid.new()
	self.HudMaid = Maid.new()

	self.Maid:GiveTask(self.UIMaid)
	self.Maid:GiveTask(function()
		self:_clearInventory()
	end)
	self.Maid:GiveTask(self.SlotMaid)
	self.Maid:GiveTask(self.TweenMaid)
	self.Maid:GiveTask(self.AnimMaid)
	self.Maid:GiveTask(self.HudMaid)

	self.IsOpenState = false
	self.SelectedUnit = nil

	self.Slots = {}
	self.InventoryEntries = {}
	self.InventoryByUnit = {}
	self.Limit = DeckConfig.DEFAULT_CARD_LIMIT

	-- As cartas que estão no ar agora. Enquanto houver alguma, a tela não é
	-- redesenhada -- mas clicar continua valendo, e cada clique solta mais uma.
	self.Flights = {}

	-- O deck contando o que ainda está no ar. Ver `_project`.
	self.Projected = DeckConfig.empty()

	-- Nomes de unidade do perfil que não existem mais, para o aviso sair uma vez só.
	self.WarnedMissing = {}

	self.ErrorToken = 0
end

return DeckController
