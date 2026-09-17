local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.SharedConfig)

local Config = SharedConfig.RichTextConfig

--[[
	O backend que fala HyperText.

	Este é o único arquivo do jogo que sabe que o HyperText existe. Ele traduz duas
	coisas: as opções neutras do `RichTextController` para os markups da biblioteca,
	e os aliases de `RichTextConfig` para as tags dela.

	**O require é tarde e dentro de um pcall** de propósito. O `Me:Load()` requer
	todo descendente de `Controllers` num laço sem proteção: um erro no require do
	vendor aqui em cima derrubaria o boot do cliente inteiro, e o preço de um render
	de texto não pode ser a tela do jogador. Falhando, `Load()` devolve `false` e o
	controller desce para o backend seguinte.

	Sobre o vendor: `ReplicatedStorage.Shared.Vendor.HyperText`, v4.2.0, MIT — a
	licença e o commit de origem estão no `Attribution.luau` ao lado dele.
]]

local Backend = {
	Name = "HyperText"
}

local HyperText = nil :: any

--[=[
	Valor neutro virando valor do HyperText, para o que não tem a mesma unidade dos
	dois lados. É o `Converter` da tabela de aliases.
]=]
local Converters = {
	--[[
		Caractere por segundo (como se pensa em máquina de escrever) vira segundo
		por caractere (como o HyperText conta). Zero ou menos é "tudo de uma vez",
		que lá é intervalo zero.
	]]
	Speed = function(value : string) : string?
		local speed = tonumber(value)
		if not speed then
			return nil
		end

		if speed <= 0 then
			return "0"
		end

		return string.format("%.4f", 1 / speed)
	end,
}

--[[ INTERNAL ]]

--[=[
	Valor de alias indo para dentro de uma tag.

	`<` e `>` sairiam da tag e virariam outra; `%` estragaria o `string.format`.
	Nada disso aparece num valor legítimo (uma cor, um número, um id), então cortar
	é mais honesto que escapar.
]=]
local function sanitize(value : string) : string
	return (string.gsub(value, "[<>%%]", ""))
end

--[=[
	Id de som como o HyperText quer: URI. Aceita número porque é assim que id de
	asset viaja no config do jogo.
]=]
local function toSoundURI(sound : string | number) : string
	if type(sound) == "number" then
		return `rbxassetid://{sound}`
	end

	return sound
end

--[[ API DO BACKEND ]]

--[=[
	Carrega a biblioteca. `false` quando ela não está lá ou não carrega — o
	controller trata isso e desce para o backend seguinte.
]=]
function Backend.Load() : boolean
	if HyperText then
		return true
	end

	local folder = Vendor:FindFirstChild("HyperText")
	local main = folder and folder:FindFirstChild("Main")
	if not main or not main:IsA("ModuleScript") then
		return false
	end

	local success, result = pcall(require, main)
	if not success then
		warn(`[RichTextController]: o HyperText nao carregou: {result}`)

		return false
	end

	HyperText = result

	return true
end

--[=[
	Um alias virando tag do HyperText. `nil` quando o nome não é alias — aí o
	controller devolve o colchete ao texto como texto comum.
]=]
function Backend.Tag(name : string, value : string?, closing : boolean) : string?
	local alias = Config.Aliases[name]
	local dialect = alias and alias.HyperText
	if not dialect then
		return nil
	end

	if closing then
		return dialect.Close or ""
	end

	local open = dialect.Open
	if not string.find(open, "%%s") then
		return open
	end

	local raw = value or alias.Default
	if not raw then
		warn(`[RichTextController]: o alias "{name}" precisa de um valor: [{name}=...].`)

		return ""
	end

	if alias.Converter then
		local converter = Converters[alias.Converter]
		local converted = converter and converter(raw)

		if not converted then
			warn(`[RichTextController]: valor invalido em [{name}={raw}].`)

			return ""
		end

		raw = converted
	end

	return string.format(open, sanitize(raw))
end

--[=[
	O objeto de render do container.

	Container que é TextLabel tem o próprio texto apagado: o HyperText desenha
	**dentro** do container, e o texto autorado no Studio ficaria por baixo do
	render, sobrando na tela. O label continua servindo de moldura (tamanho,
	posição, âncora) — é dele que o designer cuida.
]=]
function Backend.Create(container : GuiObject) : any
	if container:IsA("TextLabel") or container:IsA("TextButton") or container:IsA("TextBox") then
		container.Text = ""
	end

	local success, result = pcall(HyperText.new, container)
	if not success then
		warn(`[RichTextController]: nao consegui criar o render em {container:GetFullName()}: {result}`)

		return nil
	end

	return result
end

--[=[
	Opções neutras virando markups padrão do objeto.

	Só entra no dicionário o que foi pedido: `newMarkups()` nasce todo vazio e o
	`UpdateDefaultMarkups` mescla, então o que não vier aqui continua no padrão da
	biblioteca em vez de ser zerado.
]=]
function Backend.Apply(object : any, options : any)
	local markups = HyperText.newMarkups()

	if options.Size then
		markups.size.value = options.Size
	end

	if options.Color then
		markups.color.value = options.Color
	end

	if options.Font then
		markups.font.value = options.Font
	end

	if options.Weight then
		markups.weight.value = options.Weight
	end

	if options.Italic ~= nil then
		markups.italic.value = options.Italic
	end

	if options.Transparency then
		markups.trans.value = options.Transparency
	end

	if options.Speed then
		markups.interval.value = if options.Speed > 0 then 1 / options.Speed else 0
	end

	if options.Sound then
		markups.soundId.value = toSoundURI(options.Sound)
		markups.soundId.attributes.volume = options.SoundVolume
	end

	if options.Anim then
		-- "none" é a ausência da animação de entrada, e ausência no HyperText se
		-- escreve deletando o markup — que é opcional justamente para isso.
		markups.anim.value = if options.Anim == "none" then HyperText.DELETE else options.Anim
		markups.anim.attributes.dur = options.AnimDuration
		markups.anim.attributes.loop = options.AnimLoop
	end

	if options.Stroke then
		markups.stroke.value = true
		markups.stroke.attributes.thickness = options.Stroke.Thickness
		markups.stroke.attributes.color = options.Stroke.Color
		markups.stroke.attributes.trans = options.Stroke.Transparency
	end

	if options.Shadow then
		markups.shadow.value = true
		markups.shadow.attributes.color = options.Shadow.Color
		markups.shadow.attributes.offset = options.Shadow.Offset
	end

	if options.Align then
		markups.horizontalAlignment.value = options.Align
	end

	if options.VerticalAlign then
		markups.verticalAlignment.value = options.VerticalAlign
	end

	if options.ZIndex then
		markups.ZIndex.value = options.ZIndex
	end

	-- Um valor recusado (cor onde ele espera número, fonte que não existe) derruba
	-- a thread de quem chamou, e quem chamou é uma tela do jogo. Vira warn.
	local success, result = pcall(object.UpdateDefaultMarkups, object, markups)
	if not success then
		warn(`[RichTextController]: opcoes recusadas pelo HyperText: {result}`)
	end
end

--[=[
	Renderiza.

	O aviso do container sem tamanho é nosso, não da lib: ela simplesmente não
	desenha nada quando o container mede zero (tela desligada, frame que ainda não
	passou pelo layout), e um render que não acontece **e não reclama** é meia hora
	de procurar defeito no lugar errado.
]=]
function Backend.Render(object : any, text : string, options : any)
	local container = object._container
	if container and container.AbsoluteSize.Magnitude == 0 then
		warn(`[RichTextController]: {container:GetFullName()} mede zero na tela; o texto nao foi desenhado.`)
	end

	object:Render(text, options.Yield, options.Wrapped)
end

function Backend.Skip(object : any)
	object:CompleteRender()
end

function Backend.Pause(object : any)
	object:PauseRender()
end

function Backend.Resume(object : any)
	object:ResumeRender()
end

function Backend.Clear(object : any, instant : boolean?)
	object:Clear(instant)
end

function Backend.Destroy(object : any)
	object:Destroy()
end

function Backend.IsRendering(object : any) : boolean
	return object.rendering
end

function Backend.GetText(object : any) : string?
	return object:GetPlainText()
end

function Backend.OnFinished(object : any, callback : (skipped : boolean) -> ()) : () -> ()
	local connection = object.onRenderEnded:Connect(callback)

	return function()
		connection:Disconnect()
	end
end

function Backend.OnEvent(object : any, callback : (name : string) -> ()) : () -> ()
	local connection = object.renderEvent:Connect(callback)

	return function()
		connection:Disconnect()
	end
end

return Backend
