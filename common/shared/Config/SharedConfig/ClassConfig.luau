--[[
	A cara de cada classe de unidade.

	A **taxonomia** não nasce aqui: quem lista as classes é `WeatherConfig.ClassList`,
	e quem diz a classe de cada unidade é `UnitStats[nome].Class` (uma string, ou uma
	lista quando a unidade for de dois tipos). Este módulo é só o outro lado disso —
	o que o jogador vê quando a classe precisa aparecer na tela.

	Hoje quem lê é o `ClassIcon` do card de upgrade (`ToggleTower`).

	Classe nova é uma linha em `Icons` e uma em `WeatherConfig.ClassList`; unidade
	sem classe (`Azure`, que ainda não foi classificada) simplesmente não tem ícone,
	e quem desenha esconde o label em vez de mostrar um quadrado vazio.
]]

local WeatherConfig = require(script.Parent.WeatherConfig)

local ClassConfig = {}

--[[
	Ícone de cada classe. As chaves são as de `WeatherConfig.ClassList`.

	`Electric` é o raio: a arte veio nomeada "Lightning", mas o nome da classe no
	jogo é `Electric` e é ele que manda aqui, senão a unidade teria uma classe para
	o clima e outra para o card.
]]
ClassConfig.Icons = {
	Melee = "rbxassetid://121357932673042",
	Ranged = "rbxassetid://88082629531610",
	Magic = "rbxassetid://92693595243994",
	Fire = "rbxassetid://88305366355775",
	Ice = "rbxassetid://133728117619416",
	Electric = "rbxassetid://80013469031768",
}

--[=[
	A classe que representa a unidade, ou `nil` se ela não tiver nenhuma.

	Unidade de dois tipos tem um ícone só, e o escolhido é o **primeiro** da lista em
	`UnitStats`: é uma casa só na tela, e quem escreve o config é quem sabe qual dos
	dois é o principal.
]=]
function ClassConfig.GetPrimary(unitName : string?) : string?
	return WeatherConfig.GetClasses(unitName)[1]
end

--[=[
	O `rbxassetid` da classe da unidade, ou `nil` — unidade sem classe, ou classe
	sem arte ainda.
]=]
function ClassConfig.GetIcon(unitName : string?) : string?
	local class = ClassConfig.GetPrimary(unitName)

	return class and ClassConfig.Icons[class]
end

return ClassConfig
