type Shared = {
	Data : typeof(require(script.Data)),
	Mob : typeof(require(script.Mob)),
	Wave : typeof(require(script.Wave)),
	Difficulty : typeof(require(script.Difficulty)),
	Summon : typeof(require(script.Summon)),
	Cmdr : typeof(require(script.Cmdr)),
}

local Shared : Shared = {}
for _, module in script:GetChildren() do
	local requiredInfo = require(module)

	Shared[module.Name] = requiredInfo
end
return Shared :: Shared
