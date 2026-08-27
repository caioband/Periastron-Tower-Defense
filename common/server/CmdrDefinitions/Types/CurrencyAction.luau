--[[
	cmdr type "currencyAction": `set`, `add` ou `remove`.

	É o primeiro argumento dos comandos de moeda (`cash`, `shards`, `roundcash`),
	e existe como tipo para o tab completar — três comandos separados por operação
	seriam nove comandos para lembrar.

	O `units` usa o mesmo tipo: ele não mexe em moeda, mas a operação é a mesma
	("põe tanto", "soma tanto", "tira tanto") e um enum idêntico com outro nome só
	daria duas listas para manter iguais.

	O `MakeEnumType` do próprio Cmdr faz a busca difusa: `a` já resolve para `add`.
]]

local ACTIONS = { "set", "add", "remove" }

return function(registry)
	registry:RegisterType("currencyAction", registry.Cmdr.Util.MakeEnumType("CurrencyAction", ACTIONS))
end
