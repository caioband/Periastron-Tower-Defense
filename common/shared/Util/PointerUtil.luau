--[=[
	O ponteiro do jogador, sem assumir que existe um mouse.

	Tudo que mira no mundo -- o fantasma da unidade, a selecao de uma torre ja
	colocada, o hover de mob -- lia `UserInputService:GetMouseLocation()` direto e
	so aceitava `Enum.UserInputType.MouseButton1`. Num celular nenhum dos dois
	existe: sem mouse aquela chamada nao acompanha nada (fica em (0,0) ou congelada
	no ultimo ponto tocado) e o toque chega como `Enum.UserInputType.Touch`, entao
	o clique simplesmente nunca acontecia.

	Aqui os dois aparelhos ficam atras da mesma porta:
	  - `getScreenPosition()` devolve o mouse no PC e o ultimo toque no celular;
	  - `onPointerAction()` chama de volta no clique (PC) ou no toque curto
	    (celular), sempre com a posicao na tela.

	Modulo de cliente: no servidor `UserInputService` nem existe, e por isso todo
	acesso a ele passa pela guarda de `RunService:IsClient()`.
]=]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local UserInputService = RunService:IsClient() and game:GetService("UserInputService") or nil
local GuiService = RunService:IsClient() and game:GetService("GuiService") or nil

local PointerUtil = {}

--[[
	`InputObject.Position` e `Camera:ViewportPointToRay` nao contam a altura do
	mesmo lugar.

	A posicao de uma entrada vem no espaco da interface, que comeca embaixo da
	barra superior do Roblox. O raio da camera comeca no topo real da janela --
	o 3D e desenhado por tras da barra tambem. Entre os dois ha a GuiInset, uns
	36px de diferenca vertical, e e por isso que o toque cai perto mas nao em cima
	do dedo. `GetMouseLocation()` ja vem no espaco do raio, e por isso o mouse
	sempre foi exato.

	Em vez de somar 36 na mao (o valor muda com a barra escondida, com tela cheia e
	entre aparelhos) a diferenca e medida: uma moldura de tamanho zero num ScreenGui
	com `IgnoreGuiInset` fica, por definicao, no canto de cima da janela inteira.
	Onde quer que o Roblox diga que ela esta, aquilo e a origem do espaco do raio --
	subtrair isso de uma posicao de entrada da a coordenada certa, sem depender de
	qual das duas convencoes a engine usa hoje.
]]
local viewportOrigin : Frame? = nil

local function getViewportOriginOffset() : Vector2
	if not UserInputService then return Vector2.zero end

	if not viewportOrigin or not viewportOrigin.Parent then
		local playerGui = Players.LocalPlayer and Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
		if not playerGui then return Vector2.zero end

		local screenGui = Instance.new("ScreenGui")
		screenGui.Name = "PointerViewportOrigin"
		screenGui.IgnoreGuiInset = true
		screenGui.ResetOnSpawn = false
		screenGui.DisplayOrder = -1000

		local marker = Instance.new("Frame")
		marker.Name = "Origin"
		marker.Size = UDim2.fromOffset(0, 0)
		marker.Position = UDim2.fromOffset(0, 0)
		marker.BackgroundTransparency = 1
		marker.BorderSizePixel = 0
		-- Nao intercepta nada: e uma regua, nao um elemento de interface.
		marker.Active = false
		marker.Parent = screenGui

		screenGui.Parent = playerGui
		viewportOrigin = marker
	end

	return viewportOrigin.AbsolutePosition
end

--[=[
	Leva a posicao de um `InputObject` para a coordenada que o raio da camera
	espera. Sem isso o toque mira acima de onde o dedo encostou.
]=]
local function toViewportPoint(position : Vector2) : Vector2
	return position - getViewportOriginOffset()
end

--[=[
	A posicao de um `InputObject` no espaco que o raio da camera espera.

	Publica porque nem todo mundo consome toque pelo `onPointerAction`: o
	posicionamento no celular escuta o toque cru pelo `ContextActionService` (ele
	precisa do arrasto, e nao so do tap) e precisa da mesma conversao para mirar no
	lugar certo.

	Cuidado ao misturar os dois espacos: `Camera:WorldToViewportPoint` responde
	**neste** espaco, e `PlayerGui:GetGuiObjectsAtPosition` responde no **outro**, o
	da interface -- que e o de `InputObject.Position`, antes desta conversao.
]=]
function PointerUtil.toViewportPoint(position : Vector2) : Vector2
	return toViewportPoint(position)
end

--[[
	Um toque so vira "acao" se o dedo mal andou e saiu rapido. Arrastar a tela e
	como o jogador gira a camera no celular, e um arrasto nao pode virar um clique
	no mundo -- senao toda vez que ele olhasse em volta a unidade pularia de lugar.
]]
local TAP_MAX_MOVEMENT = 20
local TAP_MAX_DURATION = 0.6

local lastTouchPosition : Vector2? = nil

local function trackTouch(input : InputObject)
	if input.UserInputType ~= Enum.UserInputType.Touch then return end
	lastTouchPosition = toViewportPoint(Vector2.new(input.Position.X, input.Position.Y))
end

if UserInputService then
	-- A regua e montada aqui, no boot do cliente, e nao no primeiro toque: uma
	-- moldura recem-criada so ganha AbsolutePosition depois que a interface e
	-- desenhada, e nesse frame a medida sairia zerada.
	getViewportOriginOffset()

	-- Sem filtrar por `gameProcessedEvent`: aqui e so "onde o dedo esta", e quem
	-- consome a posicao e que decide se aquele toque valia alguma coisa.
	UserInputService.InputBegan:Connect(trackTouch)
	UserInputService.InputChanged:Connect(trackTouch)
end

--[=[
	Verdadeiro num aparelho que so tem toque.

	Um PC de tela sensivel ao toque continua contando como PC: o mouse dele
	funciona e e o que o jogador tem na mao, entao nao ha motivo para trocar a
	interface debaixo dele.
]=]
function PointerUtil.isTouchOnly() : boolean
	if not UserInputService then return false end
	return UserInputService.TouchEnabled and not UserInputService.MouseEnabled
end

--[=[
	Verdadeiro so num PC: teclado e mouse de verdade, e nao um console.

	E o teste que decide se vale anunciar um atalho de teclado na interface, e por
	isso ele e feito pelo lado positivo. Perguntar `not isTouchOnly()` nao serve:
	num console nao ha toque nem mouse, entao aquela pergunta responde "nao e so
	toque" -- e o jogador de controle acabaria lendo um "[E]" que ele nao tem como
	apertar.

	Tablet com teclado bluetooth tambem fica de fora. A tecla ate funcionaria la,
	mas a interface daquele aparelho e a de toque, e nao e no meio de um botao
	`TextScaled` que se descobre a excecao.
]=]
function PointerUtil.isPC() : boolean
	if not UserInputService then return false end
	if GuiService and GuiService:IsTenFootInterface() then return false end

	return UserInputService.KeyboardEnabled and UserInputService.MouseEnabled
end

--[=[
	Onde o ponteiro esta na tela, na mesma coordenada que
	`Camera:ViewportPointToRay` espera.

	No celular devolve `nil` enquanto o jogador nao tiver encostado na tela nenhuma
	vez: antes do primeiro toque nao existe "onde o dedo esta", e quem chama precisa
	decidir o que fazer com esse vazio em vez de mirar em (0,0) -- que e o canto da
	tela e daria um raycast valido, so que no lugar errado.
]=]
function PointerUtil.getScreenPosition() : Vector2?
	if not UserInputService then return nil end

	if UserInputService.MouseEnabled then
		return UserInputService:GetMouseLocation()
	end

	return lastTouchPosition
end

--[=[
	Chama `callback(screenPosition)` quando o jogador aponta para o mundo.

	No PC e o botao esquerdo descendo, exatamente como era antes -- inclusive a
	posicao vem de `GetMouseLocation()`, e nao de `input.Position`, para nao trocar
	a coordenada que o resto do codigo ja usava.

	No celular e um toque curto e parado, medido por TAP_MAX_MOVEMENT e
	TAP_MAX_DURATION. Arrastar nao chama nada, e o jogador continua podendo girar a
	camera com a unidade em mao.

	Toques que a interface ja consumiu sao ignorados nos dois casos, entao apertar
	um botao da HUD nao dispara tambem o que estiver no mundo atras dele.

	Devolve a funcao que desliga tudo, pronta para entregar ao Maid.
]=]
function PointerUtil.onPointerAction(callback : (Vector2) -> ()) : () -> ()
	if not UserInputService then
		return function() end
	end

	local connections = {}
	local touchStartPosition : Vector2? = nil
	local touchStartClock = 0

	table.insert(connections, UserInputService.InputBegan:Connect(function(input, processed)
		if processed then return end

		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			callback(UserInputService:GetMouseLocation())
		elseif input.UserInputType == Enum.UserInputType.Touch then
			touchStartPosition = toViewportPoint(Vector2.new(input.Position.X, input.Position.Y))
			touchStartClock = os.clock()
		end
	end))

	table.insert(connections, UserInputService.InputEnded:Connect(function(input, processed)
		if input.UserInputType ~= Enum.UserInputType.Touch then return end

		-- Limpo antes de qualquer saida: um toque que nao virou acao nao pode
		-- deixar a posicao inicial para tras e ser aproveitado pelo proximo.
		local startPosition = touchStartPosition
		touchStartPosition = nil

		if processed or not startPosition then return end
		if os.clock() - touchStartClock > TAP_MAX_DURATION then return end

		local endPosition = toViewportPoint(Vector2.new(input.Position.X, input.Position.Y))
		if (endPosition - startPosition).Magnitude > TAP_MAX_MOVEMENT then return end

		callback(endPosition)
	end))

	return function()
		for _, connection in connections do
			connection:Disconnect()
		end
		table.clear(connections)
	end
end

return PointerUtil
