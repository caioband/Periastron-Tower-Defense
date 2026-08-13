type Shared = {

}

local Shared : Shared = {}
for _, module in script:GetChildren() do
	local requiredInfo = require(module)

	Shared[module.Name] = requiredInfo
end
return Shared :: Shared
