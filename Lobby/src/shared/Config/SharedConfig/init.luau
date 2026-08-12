type Shared = {
	UnitStats : typeof(require(script.UnitStats)),
	SellValue : number,
	SellRefundRatio : number,
}

local Shared : Shared = {
	SellValue = 50,
	SellRefundRatio = 0.5,
	MobReward = { Min = 2, Max = 5 },
	ArrowConfig = {
		Speed = 80,
		Count = 2,
		Stagger = 1,
		YOffset = 0.2,
		Buffer = 0.6,
	},
}
for _, module in script:GetChildren() do
	local requiredInfo = require(module)

	Shared[module.Name] = requiredInfo
end
return Shared :: Shared
