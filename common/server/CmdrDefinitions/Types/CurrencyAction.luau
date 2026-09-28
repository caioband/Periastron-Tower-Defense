--[[
	cmdr type "currencyAction": `set`, `add`, or `remove`.

	It is the first argument of the currency commands (`cash`, `shards`,
	`roundcash`), and it exists as a type for tab completion: three separate
	commands per operation would be nine commands to remember.

	`units` uses the same type: it does not touch currency, but the operation is the
	same ("put this many", "add this many", "take this many"), and an identical enum
	under another name would only give two lists to keep in sync.

	Cmdr's own `MakeEnumType` does fuzzy matching: `a` already resolves to `add`.
]]

local ACTIONS = { "set", "add", "remove" }

return function(registry)
	registry:RegisterType("currencyAction", registry.Cmdr.Util.MakeEnumType("CurrencyAction", ACTIONS))
end
