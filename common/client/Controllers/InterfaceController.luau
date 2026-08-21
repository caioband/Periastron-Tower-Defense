local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Maid = require(Vendor.Maid)
local Me = require(Vendor.Me)

local Framework = Me.new()

--[[ CONSTANTS ]]

-- ScreenGui com este atributo nunca é escondida. É para a GUI que só existe
-- justamente enquanto tudo está escondido — o flash branco do portal, que nasce no
-- meio da cutscene e é o que cobre o teleporte.
local IGNORE_ATTRIBUTE = "IgnoreInterfaceHide"

--[[
	Quem manda no que fica na tela.

	Cada dono de UI continua ligando e desligando a própria `ScreenGui` como sempre;
	o que passa por aqui é o "some com o resto": o painel de mapas quer a tela só
	para ele, a cutscene quer a tela limpa. São **pedidos com nome**
	(`Hide("Cutscene")`), e não um interruptor global, porque os dois se sobrepõem —
	o painel pode estar aberto quando a cena começa, e cada um sai do seu jeito.

	Uma GUI fica escondida enquanto **algum** pedido a esconder, e volta ao que o
	dono dela queria quando o último sai. "O que o dono queria" é lido ao vivo: se
	alguém liga uma GUI escondida no meio de um pedido, o valor é guardado e ela
	continua desligada — e quando o pedido sair é esse valor novo que volta, não o de
	antes.

	O que nós mesmos escrevemos nunca entra nessa conta: ver `_write`, que é onde o
	eco da própria escrita é separado do dono da GUI.

		InterfaceController:Hide("ChooseMaps", { Except = { "ChooseMaps" } })
		InterfaceController:Show("ChooseMaps")

	`HideCore` leva junto a interface da própria Roblox (chat, playerlist, mochila e
	a topbar), que é o que a cutscene precisa e o painel não.
]]
local InterfaceController = {
	Controllers = {},
}

--[[ INTERNAL ]]

--[=[
	Escreve no `Enabled` de uma GUI marcando o aviso que essa escrita vai gerar, para
	ele não voltar como se fosse o dono da GUI mexendo nela.

	É contagem, e não uma flag ligada e desligada em volta da escrita: o `Changed` de
	uma propriedade chega no fim do frame (`SignalBehavior.Deferred`, o padrão), muito
	depois de a flag ter sido baixada. Era isso que fazia o `false` que nós forçamos
	ser guardado como o estado que o dono queria — e aí não havia mais a que voltar.

	A escrita que não muda nada não gera aviso nenhum, então também não conta.
]=]
function InterfaceController:_write(screenGui : LayerCollector, enabled : boolean)
	local entry = self.Tracked[screenGui]
	if not entry or screenGui.Enabled == enabled then
		return
	end

	entry.Pending += 1
	screenGui.Enabled = enabled
end

--[=[
	Se algum pedido em curso esconde esta GUI. Um pedido esconde tudo o que não está
	no `Except` dele.
]=]
function InterfaceController:_shouldHide(screenGui : LayerCollector) : boolean
	if screenGui:GetAttribute(IGNORE_ATTRIBUTE) == true then
		return false
	end

	for _, request in self.Requests do
		if not (request.Except and request.Except[screenGui.Name]) then
			return true
		end
	end

	return false
end

function InterfaceController:_apply(screenGui : LayerCollector)
	local entry = self.Tracked[screenGui]
	if not entry then
		return
	end

	if self:_shouldHide(screenGui) then
		self:_write(screenGui, false)
	else
		self:_write(screenGui, entry.Desired)
	end
end

function InterfaceController:_applyAll()
	for screenGui, _ in self.Tracked do
		self:_apply(screenGui)
	end
end

--[=[
	Se algum pedido em curso pede a interface da Roblox junto.
]=]
function InterfaceController:_wantsCoreHidden() : boolean
	for _, request in self.Requests do
		if request.HideCore then
			return true
		end
	end

	return false
end

--[=[
	Liga e desliga a interface da própria Roblox. O estado de antes é guardado por
	tipo na primeira vez que ela sai — a mochila, por exemplo, já vem desligada pelo
	Satchel, e devolvê-la ligada traria de volta a mochila stock por cima da dele.
]=]
function InterfaceController:_applyCore()
	local hide = self:_wantsCoreHidden()
	if hide == self.CoreHidden then
		return
	end

	self.CoreHidden = hide

	if hide then
		if not self.CoreStates then
			self.CoreStates = {}

			for _, coreType in Enum.CoreGuiType:GetEnumItems() do
				if coreType ~= Enum.CoreGuiType.All then
					self.CoreStates[coreType] = StarterGui:GetCoreGuiEnabled(coreType)
				end
			end
		end

		StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.All, false)
	elseif self.CoreStates then
		for coreType, enabled in self.CoreStates do
			StarterGui:SetCoreGuiEnabled(coreType, enabled)
		end
	end

	-- A topbar não é um CoreGuiType: some por SetCore, que pode nem existir ainda.
	pcall(function()
		StarterGui:SetCore("TopbarEnabled", not hide)
	end)
end

--[=[
	Passa a acompanhar uma GUI. O `Desired` nasce do valor que ela tinha ao chegar e é
	reescrito toda vez que alguém que não seja nós mexe no `Enabled` dela.
]=]
function InterfaceController:_track(screenGui : LayerCollector)
	if self.Tracked[screenGui] then
		return
	end

	local entry = { Desired = screenGui.Enabled, Pending = 0 }
	self.Tracked[screenGui] = entry

	-- A conexão morre com a GUI, não com o controller: as ScreenGuis com
	-- `ResetOnSpawn` são refeitas a cada respawn, e guardá-las todas no Maid deixaria
	-- uma conexão por vida de personagem para trás.
	entry.Connection = screenGui:GetPropertyChangedSignal("Enabled"):Connect(function()
		-- Aviso de escrita nossa: um por `_write`, na ordem em que saíram.
		if entry.Pending > 0 then
			entry.Pending -= 1
			return
		end

		entry.Desired = screenGui.Enabled
		self:_apply(screenGui)
	end)

	self:_apply(screenGui)
end

function InterfaceController:_untrack(screenGui : Instance)
	local entry = self.Tracked[screenGui]
	if not entry then
		return
	end

	entry.Connection:Disconnect()

	self.Tracked[screenGui] = nil
end

function InterfaceController:_observeGuis()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	local function onChild(child : Instance)
		if child:IsA("LayerCollector") then
			self:_track(child)
		end
	end

	self.Maid:GiveTask(playerGui.ChildAdded:Connect(onChild))
	self.Maid:GiveTask(playerGui.ChildRemoved:Connect(function(child : Instance)
		self:_untrack(child)
	end))

	self.Maid:GiveTask(function()
		for screenGui, _ in self.Tracked do
			self:_untrack(screenGui)
		end
	end)

	for _, child in playerGui:GetChildren() do
		onChild(child)
	end
end

--[[ EXTERNAL ]]

--[=[
	Esconde as GUIs até o `Show` do mesmo `reason`. Pedir duas vezes com o mesmo nome
	só troca as opções — não empilha, então um `Show` sempre desfaz.

	- `Except` : nomes de `ScreenGui` que este pedido deixa em paz.
	- `HideCore` : leva junto chat, playerlist, mochila e topbar.
]=]
function InterfaceController:Hide(reason : string, options : { Except : { string }?, HideCore : boolean? }?)
	local except = nil

	if options and options.Except then
		except = {}
		for _, name in options.Except do
			except[name] = true
		end
	end

	self.Requests[reason] = {
		Except = except,
		HideCore = options and options.HideCore == true,
	}

	self:_applyAll()
	self:_applyCore()
end

--[=[
	Desfaz o pedido deste `reason`. As GUIs que nenhum outro pedido esconde voltam ao
	que o dono delas queria.
]=]
function InterfaceController:Show(reason : string)
	if not self.Requests[reason] then
		return
	end

	self.Requests[reason] = nil

	self:_applyAll()
	self:_applyCore()
end

--[=[
	Se há algum pedido em curso, ou se há um com este nome.
]=]
function InterfaceController:IsHidden(reason : string?) : boolean
	if reason then
		return self.Requests[reason] ~= nil
	end

	return next(self.Requests) ~= nil
end

function InterfaceController:construct()
	self:_observeGuis()
end

function InterfaceController:start()

end

function InterfaceController:init()
	self.Maid = Maid.new()

	self.Requests = {}
	self.Tracked = {}
	self.CoreHidden = false
	self.CoreStates = nil

	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller, false, true)
	end

	self:construct()
end

return InterfaceController
