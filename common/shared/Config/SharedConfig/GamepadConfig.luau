local GamepadConfig = {}

GamepadConfig.CURSOR_TOGGLE_KEY = Enum.KeyCode.DPadDown
GamepadConfig.BACK_KEY = Enum.KeyCode.ButtonB

GamepadConfig.WORLD_ACTION_KEY = Enum.KeyCode.ButtonR2

GamepadConfig.TOWER_UPGRADE_KEY = Enum.KeyCode.ButtonB
GamepadConfig.TOWER_SELL_KEY = Enum.KeyCode.ButtonX
GamepadConfig.TOWER_PRIORITY_KEY = Enum.KeyCode.ButtonY

GamepadConfig.PLACE_ROTATE_KEY = Enum.KeyCode.ButtonY
GamepadConfig.PLACE_CANCEL_KEY = Enum.KeyCode.ButtonB

GamepadConfig.CARD_PREVIOUS_KEY = Enum.KeyCode.ButtonL1
GamepadConfig.CARD_NEXT_KEY = Enum.KeyCode.ButtonR1

GamepadConfig.AIM_ASSIST_RADIUS = 0.12

GamepadConfig.AUTO_CURSOR_ON_PANEL = true
GamepadConfig.POLL_INTERVAL = 0.1

GamepadConfig.BLOCKING_HIDE_REASONS = { "Cutscene", "PortalCountdown" }

GamepadConfig.SHOW_HINTS = true
GamepadConfig.HINTS_DISPLAY_ORDER = 50
GamepadConfig.HINT_HEIGHT = 36

GamepadConfig.SHOW_RETICLE = true
GamepadConfig.RETICLE_SIZE = 14

GamepadConfig.PANELS = {
	{ Controller = "DialogController", Back = false },
	{ Controller = "SettingsController" },
	{ Controller = "CodeController" },
	{ Controller = "RichTextLabController" },
	{ Controller = "ChooseMapsController" },
	{ Controller = "ContractController" },
	{ Controller = "CrateUIController" },
	{ Controller = "DeckController" },
	{ Controller = "ShopController" },
	{ Controller = "RoundCardShopController" },
	{ Controller = "RobuxShopController" },
	{ Controller = "RuneShopController" },
	{ Controller = "IndexController" },
	{ Controller = "GiftController", CloseMethod = "CloseAll" },
}

GamepadConfig.QUICK_BINDS = {
	{ Key = Enum.KeyCode.DPadLeft, Controller = "DeckController", Method = "Toggle", Label = "Deck" },
	{ Key = Enum.KeyCode.DPadRight, Controller = "SettingsController", Method = "Toggle", Label = "Settings" },
}

return GamepadConfig