--[[
	cmdr type "currencyAction": `set`, `add` ou `remove`.

	É o primeiro argumento dos comandos de moeda (`cash`, `shards`, `roundcash`),
	e existe como tipo para o tab completar — três comandos separados por operação
	seriam nove comandos para lembrar.

	O `MakeEnumType` do próprio Cmdr faz a busca difusa: `a` já resolve para `add`.
]]

local ACTIONS = { "set", "add", "remove" }

return function(registry)
	registry:RegisterType("currencyAction", registry.Cmdr.Util.MakeEnumType("CurrencyAction", ACTIONS))
end
