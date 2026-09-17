local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")

local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)

local Config = SharedConfig.RichTextConfig

--[[
	O backend de reserva: texto puro num TextLabel.

	Ele existe para dois trabalhos.

	O primeiro é ser a rede de segurança. Se o vendor sair do sync, quebrar num
	update da engine ou errar o require, o controller desce para cá e a frase
	aparece — sem tremor, sem cor, sem máquina de escrever, mas aparece. Aviso de
	restart de servidor que some porque uma biblioteca de texto quebrou é um
	estrago grande para uma causa pequena.

	O segundo é ser a prova de que a troca de tecnologia funciona. Dois backends
	obrigam a interface a ser de verdade: o que o `RichTextController` sabe fazer é
	o que os dois sabem responder. O terceiro backend, se vier, entra pela mesma
	porta.

	**O que ele não faz.** Efeito nenhum: os aliases viram vazio (menos `[br]`, que
	vira quebra de linha de verdade). `[event=...]` não dispara — `OnEvent` aqui
	nunca chama de volta, e quem sincroniza fala com câmera precisa ter um caminho
	que não dependa só dele. `OnFinished` chama assim que o texto entra, porque aqui
	não existe digitação para esperar.
]]

local Backend = {
	Name = "Plain"
}

local LABEL_NAME = "RichTextPlain"

--[[ INTERNAL ]]

--[=[
	O TextLabel onde escrever.

	Container que já é um objeto de texto é o próprio label — é o caso comum, e
	respeitar o que o designer autorou (fonte, tamanho, âncora) vale mais que
	qualquer coisa que a gente escolhesse. Container que é Frame ganha um label
	preenchendo ele, criado uma vez e reusado.
]=]
local function resolveLabel(container : GuiObject) : TextLabel | TextButton | TextBox
	if container:IsA("TextLabel") or container:IsA("TextButton") or container:IsA("TextBox") then
		return container
	end

	local existing = container:FindFirstChild(LABEL_NAME)
	if existing and existing:IsA("TextLabel") then
		return existing
	end

	local label = Instance.new("TextLabel")
	label.Name = LABEL_NAME
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.TextWrapped = true
	label.TextScaled = false
	label.Text = ""
	label.Parent = container

	return label
end

--[[ API DO BACKEND ]]

--[=[
	Não carrega nada, então não falha nunca. É o que faz dele o último da fila em
	`RichTextConfig.Backends`.
]=]
function Backend.Load() : boolean
	return true
end

--[=[
	Alias conhecido some; `[br]` vira quebra de linha. Nome que não é alias devolve
	`nil` e volta a ser texto comum, igual nos outros backends — a regra de o que é
	tag e o que é colchete solto tem de ser a mesma nos dois, senão o texto muda de
	sentido quando a reserva entra.
]=]
function Backend.Tag(name : string, _value : string?, _closing : boolean) : string?
	if not Config.Aliases[name] then
		return nil
	end

	if name == "br" then
		return "\n"
	end

	return ""
end

function Backend.Create(container : GuiObject) : any
	return {
		Container = container,
		Label = resolveLabel(container),
		Text = "",
		Finished = {},
	}
end

--[=[
	As opções que sobrevivem sem efeito nenhum: cor, tamanho, fonte, alinhamento.

	Só aplica o que foi pedido — o que o designer deixou no label continua valendo
	para o resto.
]=]
function Backend.Apply(object : any, options : any)
	local label = object.Label

	if options.Size then
		label.TextSize = options.Size
	end

	if options.Color then
		label.TextColor3 = options.Color
	end

	if options.Transparency then
		label.TextTransparency = options.Transparency
	end

	if options.Font then
		local success, font = pcall(
			Font.new,
			options.Font,
			options.Weight or Enum.FontWeight.Regular,
			if options.Italic then Enum.FontStyle.Italic else Enum.FontStyle.Normal
		)

		if success then
			label.FontFace = font
		end
	end

	if options.Align then
		label.TextXAlignment = Enum.TextXAlignment[options.Align.Name]
	end

	if options.VerticalAlign then
		label.TextYAlignment = Enum.TextYAlignment[options.VerticalAlign.Name]
	end

	if options.ZIndex then
		label.ZIndex = options.ZIndex
	end

	if options.Wrapped ~= nil then
		label.TextWrapped = options.Wrapped
	end
end

--[=[
	Escreve tudo de uma vez.

	A tag crua de biblioteca (o `<...>` que quem tem pressa escreve direto) sai aqui
	também: no HyperText ela vira efeito, e o que vira efeito lá não pode virar
	rabisco na tela aqui.
]=]
function Backend.Render(object : any, text : string, _options : any)
	local plain = (string.gsub(text, "<[^<>]->", ""))

	object.Text = plain
	object.Label.Text = plain

	for _, callback in object.Finished do
		task.spawn(callback, false)
	end
end

function Backend.Skip(_object : any)
end

function Backend.Pause(_object : any)
end

function Backend.Resume(_object : any)
end

function Backend.Clear(object : any, _instant : boolean?)
	object.Text = ""
	object.Label.Text = ""
end

function Backend.Destroy(object : any)
	table.clear(object.Finished)

	if object.Label.Name == LABEL_NAME then
		object.Label:Destroy()
	else
		object.Label.Text = ""
	end
end

--[=[
	Nunca está escrevendo: o texto aparece inteiro dentro do `Render`.
]=]
function Backend.IsRendering(_object : any) : boolean
	return false
end

function Backend.GetText(object : any) : string?
	return object.Text
end

function Backend.OnFinished(object : any, callback : (skipped : boolean) -> ()) : () -> ()
	table.insert(object.Finished, callback)

	return function()
		local index = table.find(object.Finished, callback)
		if index then
			table.remove(object.Finished, index)
		end
	end
end

--[=[
	Não dispara nada: sem digitação, não existe "a frase chegou no meio". Devolve a
	função de desconectar mesmo assim para quem chama não precisar saber em que
	backend está.
]=]
function Backend.OnEvent(_object : any, _callback : (name : string) -> ()) : () -> ()
	return function() end
end

return Backend
