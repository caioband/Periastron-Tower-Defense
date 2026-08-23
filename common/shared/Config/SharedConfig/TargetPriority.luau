--[[
	Prioridade de alvo de uma unidade — o que o botao `Priority` do card gira.

	Fica em Config, e nao em Util, porque os dois lados precisam da mesma lista e
	dos mesmos nomes: o cliente manda para o servidor o modo que quer, o servidor
	confere se existe. A conta de escolher alvo (`IsBetter`) tambem sai daqui pelo
	mesmo motivo — o servidor decide quem leva o dano e o cliente so gira a
	unidade para o alvo; se as duas contas discordassem, a torre bateria num mob
	olhando para outro.
]]
local TargetPriority = {}

TargetPriority.Default = "Closest"

-- A ordem do ciclo do botao: um clique anda uma casa e volta ao inicio no fim.
TargetPriority.Order = { "Closest", "Farthest", "Weakest", "Strongest" }

-- O que sai escrito no botao. Curto porque o label e TextScaled num botao baixo.
TargetPriority.Labels = {
	Closest = "CLOSEST",
	Farthest = "FARTHEST",
	Weakest = "WEAKEST",
	Strongest = "STRONGEST",
}

function TargetPriority.Exists(mode : string?) : boolean
	return mode ~= nil and TargetPriority.Labels[mode] ~= nil
end

--[=[
	O modo, ja peneirado: qualquer coisa que nao seja um dos quatro vira o padrao.
	Serve tanto para o que chega do cliente quanto para unidade antiga que ainda
	nao tem prioridade nenhuma guardada.
]=]
function TargetPriority.Get(mode : string?) : string
	if TargetPriority.Exists(mode) then
		return mode :: string
	end

	return TargetPriority.Default
end

function TargetPriority.Next(mode : string?) : string
	local current = TargetPriority.Get(mode)
	local index = table.find(TargetPriority.Order, current) or 1

	return TargetPriority.Order[(index % #TargetPriority.Order) + 1]
end

function TargetPriority.Label(mode : string?) : string
	return TargetPriority.Labels[TargetPriority.Get(mode)]
end

--[=[
	Se o modo precisa saber o avanco do mob pelo caminho.

	So o `Farthest`. Serve para quem monta os candidatos nao pagar a varredura de
	nodes nos outros tres modos, que so olham distancia e vida.
]=]
function TargetPriority.UsesPathProgress(mode : string?) : boolean
	return TargetPriority.Get(mode) == "Farthest"
end

export type Candidate = { distance : number, health : number, progress : number? }

--[=[
	Se `candidate` toma o lugar de `best`. Os dois ja passaram pelo teste de
	alcance — aqui so se compara quem interessa mais.

	Distancia desempata todo modo: com dois mobs de vida igual no `Weakest`, a
	unidade fica com o que esta mais perto em vez de trocar de alvo a cada
	varredura conforme a ordem da tabela muda.
]=]
function TargetPriority.IsBetter(mode : string?, candidate : Candidate, best : Candidate?) : boolean
	if not best then
		return true
	end

	local resolved = TargetPriority.Get(mode)

	if resolved == "Farthest" then
		--[[
			"Mais longe" e do comeco do caminho, nao da torre: quem ja andou mais
			leva o tiro primeiro, porque e ele que esta prestes a chegar na base.
			Antes valia a distancia ate a propria unidade, e o alvo escolhido era o
			mob na beirada do alcance -- muitas vezes um que tinha acabado de nascer,
			enquanto o que estava quase saindo do outro lado passava batido.

			O avanco vem do node mais perto do mob (`PathUtil.GetNodeProgress`), e nao
			existe quando o caminho ainda nao chegou inteiro no cliente. Sem ele, a
			regra antiga vale: dos dois lados, o mais distante da torre.
		]]
		if candidate.progress and best.progress then
			if candidate.progress ~= best.progress then
				return candidate.progress > best.progress
			end
		elseif candidate.distance ~= best.distance then
			return candidate.distance > best.distance
		end
	elseif resolved == "Weakest" then
		if candidate.health ~= best.health then
			return candidate.health < best.health
		end
	elseif resolved == "Strongest" then
		if candidate.health ~= best.health then
			return candidate.health > best.health
		end
	end

	return candidate.distance < best.distance
end

return TargetPriority
