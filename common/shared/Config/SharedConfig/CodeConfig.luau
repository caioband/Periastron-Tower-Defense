--[[
	The codes panel: `StarterGui.SharedUIs.CodesGUI`, opened from the `Code` button
	on the settings panel.

	Only what the client shows lives here: UI names, texts, and colors. The codes
	themselves, their rewards, and the group are server only, in
	`ServerScriptService.Config.Codes`. See docs/common/codes.md.
]]

local CodeConfig = {}

--[=[
	The UI path. `Panel` is the art the open animation grows (see `ProximityPanel`);
	`Redeem` sits next to it in `Wrapper`, so `CodeController` makes it follow the
	art's scale.
]=]
CodeConfig.Gui = {
	Folder = "SharedUIs",
	ScreenGui = "CodesGUI",
	Wrapper = "CodesContainer",
	Panel = "Codes",

	-- Inside `Panel`: the feedback line and the box the player types in.
	Feedback = "Text",
	Input = "TextBox",

	-- Inside `Wrapper`: the button, and the label authored inside it that
	-- `RichTextController` writes the gold text into.
	Redeem = "Redeem",
	RedeemLabel = "RedeemText",
}

CodeConfig.OPEN_ANIMATION = "OpenShop"

-- The button's text. `[gold]` is the shiny gold alias (`RichTextConfig.Aliases`).
CodeConfig.REDEEM_MARKUP = "[gold]REDEEM[/gold]"

CodeConfig.REDEEM_TEXT_OPTIONS = {
	Font = "rbxasset://fonts/families/PressStart2P.json",
	-- `LayoutTimeout` covers the open animation: the size is measured once the box
	-- stops growing.
	Fit = { TextRatio = 0.7, MaxRows = 1, LayoutTimeout = 3 },
	Stroke = { Thickness = 0.06, Color = Color3.fromRGB(90, 50, 0) },
	Align = Enum.HorizontalAlignment.Center,
	VerticalAlign = Enum.VerticalAlignment.Center,
}

-- The feedback line's color per outcome. The neutral one is whatever the label
-- carries in Studio, read when the screen binds.
CodeConfig.SUCCESS_COLOR = Color3.fromRGB(90, 230, 110)
CodeConfig.ERROR_COLOR = Color3.fromRGB(255, 80, 80)

-- How each reward reads on the success line (`RichText` markup on a `TextLabel`).
CodeConfig.REWARD_COLORS = {
	Cash = "#FFD54A",
	Shards = "#7FD8FF",
	Crates = "#FFFFFF",
}

CodeConfig.SUCCESS_TITLE = "Code redeemed!"

--[=[
	Why a redemption failed, as `CodeService` names it, and the line the player
	reads. A reason missing here shows `Unknown`.
]=]
CodeConfig.Messages = {
	Empty = "Type a code first.",
	Invalid = "Invalid code.",
	Expired = "This code has expired.",
	AlreadyRedeemed = "You already redeemed this code.",
	NotInGroup = "Join our group to redeem codes!",
	GroupCheckFailed = "Could not check your group. Try again.",
	Cooldown = "Slow down! Try again in a moment.",
	NotLoaded = "Your data is still loading. Try again.",
	Busy = "Hold on, still redeeming.",
	Timeout = "No answer from the server. Try again.",
	Unknown = "Something went wrong. Try again.",
}

-- The client's own wait between attempts. The server enforces its own
-- (`Config.Codes.ATTEMPT_COOLDOWN`); this one only saves a round trip.
CodeConfig.CLIENT_COOLDOWN = 2

-- How long the client waits for an answer before freeing the button.
CodeConfig.REQUEST_TIMEOUT = 15

CodeConfig.CLICK_SOUND = "UIClick"

-- The success sound: the shop purchase's `Coins`, the same as a contract claim.
CodeConfig.SUCCESS_SOUND = "Coins"
CodeConfig.SUCCESS_SOUND_KEY = "CodeRedeem"

return CodeConfig
