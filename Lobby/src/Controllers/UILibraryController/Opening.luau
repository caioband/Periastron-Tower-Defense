local Spring = require(game.ReplicatedStorage.Shared.Vendor.Spring)
return {
	["Shop"] = {
		OpeningAnimation = function(Frame : Frame)
			Frame.Position = UDim2.fromScale(0.5, 0.9)

			Spring.target(Frame, .65, 4, {
				Position = UDim2.fromScale(0.5, 0.5)
			})

			Frame.Visible = true
		end,

		ClosingAnimation = function(Frame : Frame)
			Frame.Position = UDim2.fromScale(0.5, 0.5)

			Spring.target(Frame, .65, 4, {
				Position = UDim2.fromScale(0.5, 1.5)
			})

			return task.delay(.2, function()
				Frame.Visible = false
			end)
		end,
	},
}
