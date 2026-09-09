local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Maid = require(Vendor.Maid)

--[[
	O peso de um botão de loja: ele cresce com o ponteiro em cima e afunda enquanto
	está apertado, no `UIScale` autorado dentro dele.

	Mora aqui porque as **duas** lojas do lobby têm o mesmo botão de comprar — a de
	caixas e a de cartas — e o toque delas tem de ser o mesmo gesto. Uma segunda
	cópia dos tempos e das curvas daria dois botões que se parecem e não se sentem
	iguais, e ninguém descobriria por qual dos dois arquivos passar quando a curva
	mudasse.

	Os tempos e a curva são os mesmos dos botões da HUD (ver o `HUDButtonController`):
	a entrada é circular, e a volta é um `Back` que passa um pouco do ponto e volta —
	é o que faz o botão parecer que tem peso em vez de só mudar de tamanho.
]]
local ButtonUtil = {}

--[=[
	O aperto é mais suave que o `0.9` da HUD de propósito. Lá o botão é um ícone
	quadrado e pequeno, e nas lojas ele é uma barra larga: o mesmo fator moveria as
	duas bordas muito mais longe, e a barra pareceria saltar em vez de afundar.
]=]
ButtonUtil.HOVER_SCALE = 1.05
ButtonUtil.PRESS_SCALE = 0.93

ButtonUtil.HOVER_INFO = TweenInfo.new(0.18, Enum.EasingStyle.Circular, Enum.EasingDirection.Out)
ButtonUtil.PRESS_INFO = TweenInfo.new(0.08, Enum.EasingStyle.Circular, Enum.EasingDirection.Out)
ButtonUtil.RELEASE_INFO = TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

--[=[
	Leva o `UIScale` para o tamanho que o estado do botão pede, cancelando o tween
	anterior.

	O alvo sai do estado inteiro, e não do evento que acabou de chegar: apertado vence
	pousado, que vence parado. Sem isso, soltar o clique com o mouse ainda em cima
	devolveria o botão ao tamanho normal em vez do tamanho de hover, e a próxima saída
	do mouse não teria nada para desfazer.

	`Tween:Cancel()` para o tween sem devolver a propriedade — a escala fica onde
	chegou e o tween novo parte dali, que é o que faz duas animações emendarem em vez
	de saltarem.
]=]
local function applyScale(maid, scale : UIScale, state, style)
	maid:DoCleaning()

	local target, info

	if state.Pressed then
		target, info = style.PressScale, style.PressInfo
	elseif state.Hovered then
		target, info = style.HoverScale, style.HoverInfo
	else
		target, info = 1, style.ReleaseInfo
	end

	local tween = TweenService:Create(scale, info, { Scale = target })

	maid:GiveTask(function()
		tween:Cancel()
	end)

	tween:Play()
end

--[=[
	Liga o crescer e o afundar de um botão. `maid` é quem desfaz tudo — o do bind do
	container ou da carta, para um `_render` novo desconectar o que ficou e cancelar o
	tween que estiver no meio.

	Sem `UIScale` autorado dentro do botão não há o que animar, e a função simplesmente
	não faz nada: um botão sem a peça continua clicável, e a loja não deixa de vender
	por causa de um detalhe de tato.

	O aperto e o soltar são `InputBegan`/`InputEnded`, e não `MouseButton1Down/Up`,
	porque a loja é jogada no celular também: filtrando `MouseButton1` **e** `Touch`, o
	mesmo par de eventos cobre o clique e o toque. Nenhum dos dois consome o input,
	então o `Activated` que faz a compra continua saindo normalmente.

	Duas coisas que o par de eventos sozinho não cobre:

	* **Soltar fora do botão.** Arrastar para fora e soltar lá não dispara o
	  `InputEnded` daqui, e a escala ficaria presa no apertado para sempre — por isso o
	  `MouseLeave` também desfaz o aperto.
	* **Toque não tem hover.** A Roblox manda `MouseEnter` no toque como se fosse um
	  mouse, então soltar o dedo devolveria o botão ao tamanho de hover por um quadro
	  antes do `MouseLeave` chegar. Um toque que termina limpa os dois estados de uma
	  vez.
]=]
function ButtonUtil.bindFeedback(button : GuiButton, maid, options : { [string] : any }?)
	local scale = button:FindFirstChildWhichIsA("UIScale")
	if not scale then
		return
	end

	options = options or {}

	local style = {
		HoverScale = options.HoverScale or ButtonUtil.HOVER_SCALE,
		PressScale = options.PressScale or ButtonUtil.PRESS_SCALE,
		HoverInfo = options.HoverInfo or ButtonUtil.HOVER_INFO,
		PressInfo = options.PressInfo or ButtonUtil.PRESS_INFO,
		ReleaseInfo = options.ReleaseInfo or ButtonUtil.RELEASE_INFO,
	}

	local state = { Hovered = false, Pressed = false }

	local tweenMaid = Maid.new()
	maid:GiveTask(tweenMaid)

	local function refresh()
		applyScale(tweenMaid, scale, state, style)
	end

	maid:GiveTask(button.MouseEnter:Connect(function()
		state.Hovered = true
		refresh()
	end))

	maid:GiveTask(button.MouseLeave:Connect(function()
		state.Hovered = false
		state.Pressed = false
		refresh()
	end))

	maid:GiveTask(button.InputBegan:Connect(function(input : InputObject)
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end

		state.Pressed = true
		refresh()
	end))

	maid:GiveTask(button.InputEnded:Connect(function(input : InputObject)
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end

		state.Pressed = false

		if input.UserInputType == Enum.UserInputType.Touch then
			state.Hovered = false
		end

		refresh()
	end))

	-- A escala autorada é a de parado. Um botão que ficou grande porque o painel fechou
	-- com o mouse em cima dele volta ao normal no bind seguinte.
	scale.Scale = 1
end

return ButtonUtil
