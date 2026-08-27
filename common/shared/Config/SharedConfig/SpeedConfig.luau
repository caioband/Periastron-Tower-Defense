--[[
	As velocidades do botao `Interface.Speed` da partida.

	Uma escala por degrau, e a arte do botao que anuncia **a velocidade em que a
	partida esta agora** -- nao a proxima. Clicar avança um degrau e volta ao 1x
	depois do ultimo.

	Quem manda no valor em uso e o `SpeedService` (servidor); o `SpeedController`
	so desenha o degrau que o servidor mandou. As duas pontas leem esta tabela,
	entao velocidade nova e uma linha aqui -- o cliente ganha a arte e o servidor
	ganha a escala pelo mesmo `Steps`.
]]

local SpeedConfig = {}

--- Os degraus, na ordem do ciclo.
SpeedConfig.Steps = {
	{ Scale = 1, Image = "rbxassetid://132899761008925" },
	{ Scale = 1.5, Image = "rbxassetid://106089741438137" },
	{ Scale = 2, Image = "rbxassetid://122729764545333" },
}

SpeedConfig.DEFAULT_INDEX = 1

--[[ API ]]

--- O degrau do indice, ou o padrao quando o indice nao existe.
function SpeedConfig.Get(index : number?)
	return SpeedConfig.Steps[index or 0] or SpeedConfig.Steps[SpeedConfig.DEFAULT_INDEX]
end

function SpeedConfig.GetScale(index : number?) : number
	return SpeedConfig.Get(index).Scale
end

function SpeedConfig.GetImage(index : number?) : string
	return SpeedConfig.Get(index).Image
end

--[=[
	Se o indice e um degrau de verdade. O servidor pergunta isto antes de aceitar
	o que o cliente pediu: o pedido vem pela rede, entao pode vir qualquer coisa.
]=]
function SpeedConfig.IsValid(index : any) : boolean
	return typeof(index) == "number" and SpeedConfig.Steps[index] ~= nil
end

--- O proximo degrau do ciclo, dando a volta no fim.
function SpeedConfig.Next(index : number?) : number
	if not SpeedConfig.IsValid(index) then
		return SpeedConfig.DEFAULT_INDEX
	end

	local current : number = index :: number

	return (current % #SpeedConfig.Steps) + 1
end

return SpeedConfig
