local TweenService = game:GetService("TweenService")

local UIUtil = {}

local SUFFIXES = {"", "K", "M", "B", "T", "Qa", "Qi"}

function UIUtil.formatAbbreviated(num: number): string
	if num < 1000 then return tostring(num) end

	local visibleIdx = math.floor(math.log10(num) / 3)
	local suffixIdx = math.clamp(visibleIdx + 1, 1, #SUFFIXES)
	local suffix = SUFFIXES[suffixIdx]

	local abbreviated = num / (10 ^ (visibleIdx * 3))

	if abbreviated % 1 == 0 then
		return string.format("%d%s", abbreviated, suffix)
	else
		return string.format("%.2f%s", abbreviated, suffix):gsub("%.?0+$", "")
	end
end

function UIUtil.formatCommas(num: number): string
	local formatted = tostring(num)
	local k

	while true do
		formatted, k = string.gsub(formatted, "^(-?%d+)(%d%d%d)", '%1,%2')
		if k == 0 then break end
	end

	return formatted
end

--[=[
	Espera um descendente pelo nome, em qualquer profundidade. O `WaitForChild` só
	olha filhos diretos, e a GUI muda de forma com o tempo — um botão do HUD pode
	estar solto no frame hoje e dentro de um wrapper amanhã.

	Devolve nil se estourar o tempo (10s por padrão), do mesmo jeito que o
	`WaitForChild` com timeout.
]=]
function UIUtil.waitForDescendant(root: Instance, name: string, timeout: number?): Instance?
	local deadline = os.clock() + (timeout or 10)

	repeat
		local found = root:FindFirstChild(name, true)
		if found then
			return found
		end

		task.wait(0.05)
	until os.clock() >= deadline

	return root:FindFirstChild(name, true)
end

--[[ TRANSPARÊNCIA ]]

--[=[
	Que propriedades de transparência cada peça tem.

	`GuiObject.Transparency` fica de fora de propósito: é apelido de
	`BackgroundTransparency`, e os dois tweens brigariam pela mesma propriedade.

	Mora aqui, e não no controller da loja de round, porque as **duas** places
	desenham a mesma carta: a loja de round revela a carta no meio da partida
	(`Game`) e a loja de cartas do lobby revela a mesma arte no balcão (`Lobby`).
	Uma segunda cópia da lista de propriedades só daria duas listas para atualizar
	no dia em que uma peça nova de UI ganhasse um `Transparency` próprio.
]=]
function UIUtil.fadeProperties(object: Instance): { string }?
	if object:IsA("UIStroke") then
		return { "Transparency" }
	elseif object:IsA("ImageLabel") or object:IsA("ImageButton") then
		return { "BackgroundTransparency", "ImageTransparency" }
	elseif object:IsA("TextLabel") or object:IsA("TextButton") or object:IsA("TextBox") then
		return { "BackgroundTransparency", "TextTransparency", "TextStrokeTransparency" }
	elseif object:IsA("GuiObject") then
		return { "BackgroundTransparency" }
	end

	--[[
		O `UIShadow` não aparece na lista de classes acima porque não é `GuiObject`
		nem `UIStroke`; ele entra por aqui, e junto com ele qualquer componente de UI
		novo que tenha um `Transparency` próprio.

		Só vale se o `Transparency` for **número**: o do `UIGradient` é uma
		`NumberSequence`, e tweenar aquilo como se fosse um número derrubaria o
		gradiente inteiro da carta.
	]]
	local ok, value = pcall(function()
		return (object :: any).Transparency
	end)

	return if ok and typeof(value) == "number" then { "Transparency" } else nil
end

--[=[
	Todo par (peça, propriedade) com o valor que o designer deixou, varrendo os
	**descendentes** de `root` — o próprio `root` fica de fora porque quem cuida
	dele é quem chamou (na carta, a queda com a imagem aparecendo).

	Tem de ser lido do clone intocado, **antes** de qualquer escrita de
	transparência: é para estes valores que o `applyFades(fades, 1)` leva tudo de
	volta, e capturar depois gravaria o estado escondido como se fosse o autorado.
]=]
function UIUtil.captureFades(root: Instance)
	local fades = {}

	for _, descendant in root:GetDescendants() do
		local properties = UIUtil.fadeProperties(descendant)
		if not properties then
			continue
		end

		local values = {}
		for _, property in properties do
			values[property] = (descendant :: any)[property]
		end

		table.insert(fades, { Object = descendant, Values = values })
	end

	return fades
end

--[=[
	Escreve a transparência de todos os descendentes de uma vez.

	`progress` é 0 (tudo transparente) a 1 (tudo no valor autorado). Sem `info` o
	valor salta; com `info` cada peça tweena até lá — e é quem chama que decide a
	curva, porque a entrada de uma carta chega desacelerando e a saída dela sai
	acelerando.
]=]
function UIUtil.applyFades(fades, progress: number, info: TweenInfo?)
	for _, fade in fades do
		local object = fade.Object :: any
		if not object.Parent then continue end

		local goal = {}
		for property, authored in fade.Values do
			goal[property] = 1 + (authored - 1) * progress
		end

		if not info then
			for property, value in goal do
				object[property] = value
			end
			continue
		end

		-- Propriedade que o TweenService recusa salta direto, em vez de derrubar a
		-- animação das outras peças junto.
		local ok = pcall(function()
			TweenService:Create(object, info, goal):Play()
		end)

		if not ok then
			for property, value in goal do
				object[property] = value
			end
		end
	end
end

return UIUtil
