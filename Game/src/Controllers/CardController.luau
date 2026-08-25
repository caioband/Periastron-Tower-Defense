local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)

local DeckConfig = SharedConfig.DeckConfig

local Me = require(Vendor.Me)

local Framework = Me.new()

-- O som de carta escolhida, em SoundService.SharedSounds.SFX.
local CARD_SOUND = "CardFlip"

--[=[
	A ponte entre o deck do perfil e a hotbar da partida.

	Aqui nao se desenha nada: quem desenha e o componente `Card`
	(`UILibraryController/Components/Card.luau`), que clona o `CardWrapper` autorado
	no `TowerContainer` e acomoda as cartas no arco. Este controller decide **o
	que** aparece, **quantas** cartas cada uma tem e **qual esta escolhida**.

	- a lista de cartas e o deck montado no lobby (`EquippedUnits`), na ordem dos
	  slots e sem os buracos -- ver `DeckConfig.resolve`/`unitList` e o README do
	  Game;
	- a quantidade de cada carta vem do servidor (`UpdateCardCounts`), que tambem
	  sai do deck;
	- a carta escolhida cresce e apaga as outras, entao toda troca de `Equipped`
	  avisa o componente -- e e nela que o `CardFlip` toca.
]=]
local CardController = {
	Controllers = {
		DataController = {},
		MusicController = {},
		UnitPlacementController = {},
		UILibraryController = {},
	},

	CardCounts = {},
	Cash = 0,
	Equipped = nil,
}

--[[ INTERNAL ]]

function CardController:_component(func : string, ...)
	self.Controllers.UILibraryController:doComponent("Card", func, ...)
end

--[=[
	Guarda qual unidade esta na mao e conta para a hotbar, que cresce essa carta e
	apaga as outras. E o unico caminho para mexer no `Equipped` -- assim a tela
	nunca discorda do que o `UnitPlacementController` esta mostrando no chao.

	O som toca so quando uma carta **entra** na mao: largar a unidade e o mesmo
	caminho com `nil`, e ai nao ha carta nenhuma para virar.
]=]
function CardController:_setEquipped(unitName : string?)
	if self.Equipped == unitName then
		return
	end

	self.Equipped = unitName
	self:_component("setSelected", unitName)

	if unitName then
		self:_playCardSound()
	end
end

--[=[
	O som de carta virando, o mesmo do painel de deck no lobby
	(`SoundService.SharedSounds.SFX`).
]=]
function CardController:_playCardSound()
	local music = self.Controllers.MusicController

	if music then
		music:PlaySFX(CARD_SOUND)
	end
end

--[=[
	Um clique numa carta.

	Clicar na carta que ja esta na mao larga a unidade; clicar em outra troca. Sem
	unidade sobrando na carta, nao acontece nada -- a carta ja esta apagada na tela
	por conta do proprio contador.
]=]
function CardController:_onCardActivated(unitName : string)
	if (self.CardCounts[unitName] or 0) <= 0 then
		return
	end

	if self.Equipped == unitName then
		self:_setEquipped(nil)
		self.Controllers.UnitPlacementController:unequip()

		return
	end

	if self.Equipped then
		self.Controllers.UnitPlacementController:unequip()
	end

	self.Controllers.UnitPlacementController:visualize(unitName)
	self:_setEquipped(unitName)
end

--[=[
	Redesenha a hotbar a partir do perfil. Roda no boot e a cada escrita do
	servidor em `Units`, `EquippedUnits` ou `CardLimit`.

	Quem nunca montou deck recebe um automatico, o mesmo que o `UnitService` monta
	do outro lado: as duas pontas leem o mesmo perfil pelas mesmas funcoes, entao a
	hotbar e as contagens sempre falam da mesma coisa.
]=]
function CardController:_render()
	local replica = self.Controllers.DataController:GetReplica()
	local profile = replica and replica.Data

	if not profile then
		return
	end

	local hotbar = DeckConfig.unitList(DeckConfig.resolve(profile))

	self:_component("set", hotbar, self.CardCounts, function(unitName : string)
		self:_onCardActivated(unitName)
	end)

	-- O deck mudou debaixo da unidade que estava na mao: se ela nao esta mais no
	-- deck, a mao esvazia; se continua, a hotbar precisa saber que ela e o vertice.
	if self.Equipped and not table.find(hotbar, self.Equipped) then
		self.Equipped = nil
		self.Controllers.UnitPlacementController:unequip()
	end

	self:_component("setSelected", self.Equipped)
end

--[[ EXTERNAL ]]

--[=[
	Chamado pelo `UnitPlacementController` quando a unidade sai da mao por fora da
	hotbar -- depois de colocar, ao cancelar, ao trocar de round.
]=]
function CardController:setUnequipState()
	self:_setEquipped(nil)
end

function CardController:construct()
	for _, key in { "Units", "EquippedUnits", "CardLimit" } do
		self.Controllers.DataController:OnConnectChange({ key }, function()
			self:_render()
		end)
	end

	Framework:Listen("UpdateCardCounts", function(unitName : string, count : number)
		self.CardCounts[unitName] = count
		self:_component("setCount", unitName, count)
	end)
	Framework:Fire("RequestCardCounts")

	-- O dinheiro da sessao decide se a carta aparece em vermelho (sem grana).
	Framework:Listen("UpdateCash", function(amount : number)
		self.Cash = amount or 0
		self:_component("setCash", self.Cash)
	end)
	Framework:Fire("RequestCash")

	--[[
		O clima pode mexer no preco de colocar (a chuva desconta 25% do Ice), e o
		preco esta escrito na carta: sem isto o jogador veria o valor antigo ate a
		hotbar ser redesenhada por outro motivo.

		O `task.defer` e pelo mesmo motivo do `WeatherFeedbackController`: quem guarda
		o clima atual e o `WeatherController`, que escuta o mesmo evento, e a ordem
		entre os dois nao e garantida. Um passo de espera e o suficiente para o
		`GetCurrent` ja responder o clima novo.
	]]
	Framework:Listen("WeatherChanged", function()
		task.defer(function()
			self:_component("refreshWeather")
		end)
	end)

	task.spawn(function()
		self:_render()
	end)
end

function CardController:start()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller)
	end

	self:construct()
end

function CardController:init()

end

return CardController
