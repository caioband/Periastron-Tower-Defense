local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Configs = Shared:WaitForChild("Config")
local Assets = Shared:WaitForChild("Assets")
local Utils = Shared:WaitForChild("Util")

local UIAssets = Assets:WaitForChild("UI")

local SharedConfig = require(Configs.SharedConfig)
local PointerUtil = require(Utils.PointerUtil)
local UIUtil = require(Utils.UIUtil)

local Maid = require(Vendor.Maid)
local Me = require(Vendor.Me)
local Log = require(Shared:WaitForChild("Util"):WaitForChild("Log"))

local Framework = Me.new()
local log = Log.new("RoundCardShopController")

local RoundCardConfig = SharedConfig.RoundCardConfig

local GUI = RoundCardConfig.Gui
local ANIM = RoundCardConfig.Animation
local USE = RoundCardConfig.Use
local TARGETING = RoundCardConfig.Targeting

local WAIT_TIMEOUT = 60

-- The card sound, the same as the deck panel's and the hotbar's.
local CARD_SOUND = "CardFlip"

-- The gesture keyframe marker's **parameters** (see `_playUseVisual`). They come from
-- config because the server looks for the same word when checking `EffectDelay`.
local MARKERS = RoundCardConfig.Markers

local CHARACTER_ROOT = "HumanoidRootPart"

--[[
	How far an area card's ring must move for the preview to be redone, in studs.

	The preview is a sweep over every unit on the map, and a still cursor sends the same
	point sixty times a second. A tenth of a stud is smaller than any movement that changes
	who is inside the ring, and it cuts the whole sweep on frames where the player did not
	move their hand.
]]
local PREVIEW_STEP = 0.1

-- The longest the player may stay anchored waiting for the animation to finish.
-- It is a safety net, not the gesture's duration: see the `task.delay` at the end of
-- `_playUseVisual`.
local ANCHOR_TIMEOUT = 8

--[=[
	The round card shop, on the screen side.

	`CardShopService` decides **when** it opens, **which** cards come out, and **whether**
	the purchase counts. Only the drawing comes from here: the button sliding in from the
	edge, the full-screen darkening, the three cards falling, and the bought card landing
	in the hotbar.

	An offer's path:

		1. the server sends `RoundCardState` with a `token` and three card ids; the
		   `RCSFrame` button slides in from the right and sways at the edge;
		2. a click on `CardShop` retracts the button itself, darkens the screen, dims the
		   hotbar, and draws the three cards, one every `CardStagger`;
		3. a click on a card requests the purchase and retracts the shop right away; the
		   card only enters the hotbar when `RoundCardBought` confirms;
		4. a click (or tap) **outside** the cards plays their entrance backward and closes
		   the shop; the button does **not** come back: it was spent on the opening click,
		   and only the next offer (another `token`, on the next shop wave) brings it back
		   to the edge;
		5. a click on the hotbar card requests the use: right away if the card is
		   instant, or after **aiming** if it asks for a target. The card disappears when
		   `RoundCardUsed` confirms, which is also when the user's character makes its
		   gesture, if it has a `Visual` in the config. The gesture belongs to the
		   **room**: the animation replicates on its own, and sound and particles reach the
		   other screens through `RoundCardVisual` (see `_playRemoteUseVisual`).

	## Aiming

	Not every card acts on its own. `RoundCardConfig`'s `Use` says what it asks for
	before acting: nothing (`Instant`), a tower (`Unit`), a spot (`Area`), or both in
	sequence (`Move`, which is Zippers). When it asks for a target, the hotbar click does
	not become a request: it enters aiming, and the **next** click, the one that chooses,
	becomes the request.

	**A card being aimed is a card in hand**, and the hotbar draws it as it draws an
	equipped unit: it grows and its neighbors dim (`Card:setSelectedRound`). There is no
	panel or cancel button: the notice is the card itself, just as there is no notice
	when the player puts a unit in hand. Giving up is clicking it again, like dropping the
	unit; on PC Esc works too.

	While aiming lasts, clicks in the world belong to the card: `UnitPlacementController`
	drops the whole hand (the ghost, the selected tower, and the equipped unit card) and
	stops selecting towers. Without that the same click would do both, and an equipped
	unit's ghost would compete for the same point on the map. It returns to normal when
	aiming ends, however it ends: confirmed, canceled, or with the card leaving the hand
	underneath it.

	Giving up costs nothing: the card is only spent when the server confirms the use, and
	choosing a spot and then changing your mind is not using the card. The server checks
	the target, as everything else: the choice comes from here, not the permission.

	**Nothing is drawn on its own authority.** The card does not enter the deck on the
	click nor leave it on use: both wait for the server's confirmation, which holds the
	money and the stock. If refused, the `RoundCardState` that follows returns the screen
	to what the server knows: the card does not appear in the hotbar, and the edge button
	stays retracted: it is spent on opening, not on purchase.

	**The card is a clone of the authored template**, and the template is taken off the
	screen the first time it is needed (as `Components/Card` does with the hotbar's
	`CardWrapper`). The target transparencies are read from each freshly made clone,
	before any animation: "back to the original" is literal, and repainting in Studio is
	enough.

	See docs/game/round-card-shop.md.
]=]
local RoundCardShopController = {
	Controllers = {
		MusicController = {},
		UILibraryController = {},
		VFXController = {},

		-- The one that knows whether a tutorial step requires a purchase. See the
		-- click-outside `_dismissShop`.
		TutorialStepController = {},

		-- The one that knows which tower is under the pointer, and that locks clicks in the
		-- world while a card asks for a target. See `_beginTargeting`.
		UnitPlacementController = {},

		-- The one that draws buffs and debuffs over units. It shows, over each tower's head,
		-- what the card being aimed would do to it.
		WeatherFeedbackController = {},

		-- The one with the list of areas already on the ground. It says whether the ring
		-- under the cursor touches this player's area. See `_updateTargeting`.
		CardModifierController = {},
	},
}

--[[ INTERNAL ]]

--[=[
	The two halves of a card's reveal, from `UIUtil`: `captureFades` reads what the
	designer left on the untouched clone and `applyFades` takes everything from
	transparent to there.

	They live in `UIUtil` because the **Lobby card shop** draws the same card the same way
	(see the Lobby's `RoundCardShopController`): a second copy here would be the same
	property sweep to maintain in two places.

	This wrapper is only the curve. The entrance arrives decelerating (`CardDirection`,
	which is `Out`) and the exit leaves accelerating (`In`): without that the cards'
	disappearance would drag at the start and look like a freeze, not a response to the
	click.
]=]
local captureFades = UIUtil.captureFades

local function applyFades(fades, progress : number, time : number?, direction : Enum.EasingDirection?)
	local info = time and TweenInfo.new(time, ANIM.CardEasing, direction or ANIM.CardDirection)

	UIUtil.applyFades(fades, progress, info)
end

function RoundCardShopController:_playSound(name : string)
	local music = self.Controllers.MusicController
	if music then
		music:PlaySFX(name)
	end
end

--[=[
	Talks to the hotbar.

	The `Card` component (`UILibraryController/Components/Card.luau`) draws the player's
	hand, and handles the arc, scale, and row order, including round cards once they come
	in through `addRound`. Only three orders come from here: add, remove, and hide.
]=]
function RoundCardShopController:_deck(func : string, ...)
	local library = self.Controllers.UILibraryController
	if not library then return end

	library:doComponent("Card", func, ...)
end

--[[ THE EDGE BUTTON ]]

--- Where `RCSFrame` sits when it is off screen.
function RoundCardShopController:_hiddenPosition() : UDim2
	local base = self.BasePosition

	return UDim2.new(ANIM.HiddenX, base.X.Offset, base.Y.Scale, base.Y.Offset)
end

--[=[
	Puts the button on screen: it starts at `HiddenX` and runs to the authored X.

	`Circular` arrives slowly at the end: that gives the snap against the edge, instead of
	the button stopping dead.
]=]
function RoundCardShopController:_showFrame()
	local frame = self.Frame
	if not frame or self.FrameShown then return end

	self.FrameShown = true
	self.FrameToken += 1
	local token = self.FrameToken

	self.FrameMaid:DoCleaning()

	frame.Position = self:_hiddenPosition()
	frame.Visible = true

	local tween = TweenService:Create(
		frame,
		TweenInfo.new(ANIM.SlideIn, ANIM.SlideEasing, Enum.EasingDirection.Out),
		{ Position = self.BasePosition }
	)

	self.FrameMaid:GiveTask(function()
		tween:Cancel()
	end)

	-- The sway only starts with the button already snapped to the edge: swaying during the
	-- entrance would fight the slide itself and make the button arrive crooked.
	tween.Completed:Connect(function(state : Enum.PlaybackState)
		if state ~= Enum.PlaybackState.Completed or self.FrameToken ~= token then return end

		self:_startIdle()
	end)

	tween:Play()
end

--- Retracts the button off screen and disables it when it finishes leaving.
function RoundCardShopController:_hideFrame()
	local frame = self.Frame
	if not frame or not self.FrameShown then return end

	self.FrameShown = false
	self.FrameToken += 1
	local token = self.FrameToken

	self.FrameMaid:DoCleaning()
	self:_stopIdle()

	local tween = TweenService:Create(
		frame,
		TweenInfo.new(ANIM.SlideOut, ANIM.SlideEasing, Enum.EasingDirection.In),
		{ Position = self:_hiddenPosition() }
	)

	self.FrameMaid:GiveTask(function()
		tween:Cancel()
	end)

	tween.Completed:Connect(function(state : Enum.PlaybackState)
		-- A new offer during the exit wins: the button on screen now is its button, and
		-- disabling here would erase a shop that just opened.
		if state ~= Enum.PlaybackState.Completed or self.FrameToken ~= token then return end

		frame.Visible = false
	end)

	tween:Play()
end

--[=[
	Makes the button sway while nobody clicks it.

	There are two movements at once: it rises `IdleLift` pixels and swings between
	`+IdleSwing` and `-IdleSwing` degrees, forever. The endless back-and-forth is a single
	tween, with `repeatCount = -1` and `reverses = true`; `swingIn` exists because the sway
	starts in the middle (at the authored rotation) and the loop must start from one of
	the ends, or the first pass would come out halved.

	**The return height and rotation are read from Studio**, not written here: they are
	the `ButtonPosition` / `ButtonRotation` the bind stored before any animation played.
]=]
function RoundCardShopController:_startIdle()
	local button = self.Button
	if not button then return end

	self.IdleMaid:DoCleaning()

	local base = self.ButtonPosition
	local rotation = self.ButtonRotation

	local lift = TweenService:Create(
		button,
		TweenInfo.new(ANIM.IdleLiftTime, ANIM.IdleEasing, Enum.EasingDirection.Out),
		{ Position = UDim2.new(base.X.Scale, base.X.Offset, base.Y.Scale, base.Y.Offset - ANIM.IdleLift) }
	)

	local swingIn = TweenService:Create(
		button,
		TweenInfo.new(ANIM.IdleSwingTime / 2, ANIM.IdleEasing, Enum.EasingDirection.Out),
		{ Rotation = rotation + ANIM.IdleSwing }
	)

	local swing = TweenService:Create(
		button,
		TweenInfo.new(ANIM.IdleSwingTime, ANIM.IdleEasing, Enum.EasingDirection.InOut, -1, true),
		{ Rotation = rotation - ANIM.IdleSwing }
	)

	self.IdleMaid:GiveTask(function()
		lift:Cancel()
		swingIn:Cancel()
		swing:Cancel()
	end)

	self.IdleMaid:GiveTask(swingIn.Completed:Connect(function(state : Enum.PlaybackState)
		if state ~= Enum.PlaybackState.Completed then return end

		swing:Play()
	end))

	lift:Play()
	swingIn:Play()
end

--[=[
	Stops the sway and returns the button to its authored state.

	The return is a tween, not an abrupt write: the button may be at any point of the
	swing at click time, and cutting to zero rotation on the same frame would jolt right
	at the click's response.
]=]
function RoundCardShopController:_stopIdle()
	local button = self.Button
	if not button then return end

	self.IdleMaid:DoCleaning()

	local tween = TweenService:Create(
		button,
		TweenInfo.new(ANIM.IdleReturn, ANIM.CardEasing, Enum.EasingDirection.Out),
		{ Position = self.ButtonPosition, Rotation = self.ButtonRotation }
	)

	self.IdleMaid:GiveTask(function()
		tween:Cancel()
	end)

	tween:Play()
end

--[[ THE PLAYER'S HOTBAR ]]

--[=[
	Dims (or restores) the player's cards while the shop is open.

	The `Card` component itself hides them, not a `Visible` written from here: each
	wrapper's `Visible` already has an owner there (a card with no units left stays off
	screen on its own), and hiding from outside would light back up, on leaving the shop,
	a card the deck had dropped.

	It hides from inside, not through `TowerContainer`'s `Visible`: `DifficultyController`
	owns the container (the hotbar only appears once the difficulty is decided), and two
	hands on the same switch would end with the hotbar vanishing mid-match.
]=]
function RoundCardShopController:_setDeckHidden(hidden : boolean)
	self:_deck("setHidden", hidden)
end

--[[ THE SHOP CARDS ]]

--[=[
	A card's template, taken off the screen the first time someone needs it.

	The `CardWrapper` authored in the row is not a card: it is the drawing of one. It
	leaves too, so what stays on screen is always what the server drew.
]=]
function RoundCardShopController:_template() : Frame?
	if self.Template then
		return self.Template
	end

	local authored = self.Row and self.Row:FindFirstChild(GUI.Wrapper)
	if not authored then
		log:StudioWarn(`could not find the authored {GUI.Wrapper} in {GUI.Row}.`)
		return nil
	end

	self.Template = authored:Clone()
	authored:Destroy()

	return self.Template
end

--[=[
	Writes a card's texts and art on the clone. `showPrice` is false for a card already
	paid for and on its way to the hotbar.
]=]
function RoundCardShopController:_writeCard(card : GuiObject, definition, showPrice : boolean, priceOverride : number?)
	local title = card:FindFirstChild(GUI.Title)
	if title and title:IsA("TextLabel") then
		title.Text = definition.Title or definition.Id
	end

	local description = card:FindFirstChild(GUI.Description)
	if description and description:IsA("TextLabel") then
		description.Text = definition.Description or ""
	end

	local price = card:FindFirstChild(GUI.Price)
	if price then
		price.Visible = showPrice

		local label = price:FindFirstChild(GUI.PriceLabel)
		if label and label:IsA("TextLabel") then
			label.Text = "$" .. tostring(priceOverride or definition.Price or 0)
		end
	end

	-- A card without its own art keeps the template's authored art: a card with the wrong
	-- art beats an invisible card.
	local image = definition.Image
	if not image and definition.Tower then
		image = SharedConfig.CardConfig.GetImage(definition.Params.Unit)
	end

	if image and (card:IsA("ImageLabel") or card:IsA("ImageButton")) then
		card.Image = image
	end
end

--[=[
	Removes the cards in the row. The purchased one was already cloned before this.

	`DismissToken` goes up too: an exit in progress must not keep touching cards that were
	just destroyed, and the new offer that arrives when the wave turns with the shop open
	does exactly that.
]=]
function RoundCardShopController:_clearRow()
	self.CardEntries = {}
	self.Dismissing = false
	self.DismissToken += 1

	self.RowMaid:DoCleaning()
end

--[=[
	Draws the offer's three cards.

	Each card has two halves, in this order: it **drops** from `DropOffset` heights above
	its place while its image fades in (`CardDrop`), and only when that ends does the
	content (title, description, price, outlines, shadow) go from 1 to the authored value
	(`CardReveal`).

	The three do not go out together: the second starts `CardStagger` after the first, and
	the third `CardStagger` after the second. The delay is a `task.delay` kept in the
	row's maid, so closing the shop midway cancels whatever has not started.
]=]
function RoundCardShopController:_renderCards()
	local row = self.Row
	local offer = self.Offer
	if not row or not offer then return end

	local template = self:_template()
	if not template then return end

	self:_clearRow()

	for index, cardId in offer.cards do
		local definition = RoundCardConfig.Get(cardId)
		if not definition then
			log:StudioWarn(`the offer brought card '{tostring(cardId)}', which is not in the config.`)
			continue
		end

		local wrapper = template:Clone()
		wrapper.Name = cardId
		wrapper.LayoutOrder = index

		local card = wrapper:FindFirstChild(GUI.Card)
		if not card or not card:IsA("GuiObject") then
			wrapper:Destroy()
			continue
		end

		self:_writeCard(card, definition, true, offer.prices and offer.prices[cardId])
		
		--[[
			Read from the untouched clone: this is where the animation's second half takes
			everything back. It must come **before** any transparency write, or the target
			would be the hidden state.
		]]
		local fades = captureFades(card)
		local basePosition = card.Position

		--[[
			What the exit needs to know to play this same animation backward: where the card
			lives, where the transparencies return to, and what is still in flight (the
			entrance delay and the drop tween) and needs canceling.
		]]
		local entry = {
			Wrapper = wrapper,
			Card = card,
			Fades = fades,
			BasePosition = basePosition,
			Ready = false,
		}

		table.insert(self.CardEntries, entry)

		-- Starting state: the card above its place, the image and content
		-- transparent.
		card.Position = UDim2.new(
			basePosition.X.Scale, basePosition.X.Offset,
			basePosition.Y.Scale - ANIM.DropOffset, basePosition.Y.Offset
		)

		if card:IsA("ImageLabel") or card:IsA("ImageButton") then
			card.ImageTransparency = 1
		end

		applyFades(fades, 0)

		wrapper.Parent = row
		self.RowMaid:GiveTask(wrapper)

		--[[
			The card only accepts clicks after it starts falling. It exists on screen from
			`Parent` on, transparent and out of place, and without this the third card
			(which only comes in a second later) could be bought while there is nothing for
			the player to see.
		]]
		if card:IsA("GuiButton") then
			self.RowMaid:GiveTask(card.Activated:Connect(function()
				if not entry.Ready or self.Dismissing then return end

				self:_buy(cardId)
			end))

			--[[
				The mark of a click that **was** on a card.

				`UserInputService` listens for the click-outside, and it sees **every** click,
				including one that landed on a card. This mark is what tells it that input
				already had an owner; see `InputBegan` in `_openShop`.
			]]
			self.RowMaid:GiveTask(card.InputBegan:Connect(function(input : InputObject)
				self.CardInput = input
			end))
		end

		local delayed = task.delay((index - 1) * ANIM.CardStagger, function()
			if not wrapper.Parent then return end

			entry.Ready = true

			local dropInfo = TweenInfo.new(ANIM.CardDrop, ANIM.CardEasing, ANIM.CardDirection)
			local goal : { [string] : any } = { Position = basePosition }

			if card:IsA("ImageLabel") or card:IsA("ImageButton") then
				goal.ImageTransparency = 0
			end

			local drop = TweenService:Create(card, dropInfo, goal)
			entry.Drop = drop

			drop.Completed:Connect(function(state : Enum.PlaybackState)
				if state ~= Enum.PlaybackState.Completed or not wrapper.Parent then return end

				applyFades(fades, 1, ANIM.CardReveal)
			end)

			drop:Play()
		end)

		entry.Delayed = delayed

		self.RowMaid:GiveTask(function()
			pcall(task.cancel, delayed)
		end)
	end
end

--[[ OPEN AND CLOSE ]]

--[=[
	Opens the shop tab: the edge button retracts, the screen darkens, the hotbar dims, and
	when the darkening ends the cards start falling.

	The cards only come in after the background on purpose: they fall against the dark,
	and drawing them during the fade would have them appear over the match.

	The button leaves with the opening and **does not come back for this offer**. It is a
	shop wave's invitation, and the click is the answer: leaving without buying is still a
	choice, not a mistake to undo. `OpenedToken` keeps that: the edge only lights again
	with a different `token`, that is, on the difficulty's next shop wave.
]=]
function RoundCardShopController:_openShop()
	local background = self.Background
	if not background or self.ShopOpen or not self.Offer then return end

	self.ShopOpen = true
	self.OpenToken += 1
	local token = self.OpenToken

	self.OpenedToken = self.Offer.token

	self:_hideFrame()
	self:_setDeckHidden(true)
	self:_clearRow()

	--[=[
		A click (or tap) outside the cards undoes the offer on screen.

		`UserInputService` listens, not the darkening. The background looks like the
		natural owner (it covers the screen), but it only receives clicks nobody else
		wanted: **any** `ScreenGui` with a higher `DisplayOrder` (the HUD, the hotbar
		container) eats the click first, and there the shop would stay open with no way out
		except buying. `UserInputService` sees the click regardless of who consumed it, and
		the shop is modal: a click on nothing and a click on anything else close the same.

		What does **not** close is a click on one of the three cards, and `CardInput` says
		so: the card marks its own `InputObject`, and the check goes out in a `task.defer`
		because the order between the two handlers of the same event is not promised
		anywhere: one frame later both have run. Comparing input objects avoids measuring
		rectangles on screen, and measuring would be worse: the math between
		`InputObject.Position` and `AbsolutePosition` changes with the screen's
		`IgnoreGuiInset` and with the top bar on mobile.
	]=]
	self.ShopMaid:GiveTask(UserInputService.InputBegan:Connect(function(input : InputObject)
		if input.UserInputType ~= Enum.UserInputType.MouseButton1
			and input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end

		task.defer(function()
			if input == self.CardInput then return end

			-- The tutorial may be requiring a purchase: while it does, a click outside
			-- does not close the shop.
			local tutorial = self.Controllers.TutorialStepController
			if tutorial and not tutorial:AllowsShopDismiss() then return end

			self:_dismissShop()
		end)
	end))

	background.BackgroundTransparency = 1
	background.Visible = true

	local tween = TweenService:Create(
		background,
		TweenInfo.new(ANIM.BackgroundFade, ANIM.CardEasing, ANIM.CardDirection),
		{ BackgroundTransparency = self.BackgroundTarget }
	)

	tween.Completed:Connect(function(state : Enum.PlaybackState)
		if state ~= Enum.PlaybackState.Completed or self.OpenToken ~= token then return end

		self:_renderCards()
	end)

	tween:Play()
end

--[=[
	Closes the tab and restores the hotbar.

	Without `fade`, the darkening disappears immediately: that is what a purchase needs:
	it already has its own animation (the edge button retracting), and a second fade on
	top would only delay the player's return to the match.

	With `fade`, the darkening leaves over `fade` seconds. It is the path of a click
	outside the cards, where there was no purchase: there the screen goes away on its own,
	and cutting the dark at once would look like an error instead of a retreat.
]=]
function RoundCardShopController:_closeShop(fade : number?)
	if not self.ShopOpen then return end

	self.ShopOpen = false
	self.OpenToken += 1
	local token = self.OpenToken

	self.ShopMaid:DoCleaning()
	self:_clearRow()

	local background = self.Background
	if background then
		if fade then
			local tween = TweenService:Create(
				background,
				TweenInfo.new(fade, ANIM.CardEasing, Enum.EasingDirection.In),
				{ BackgroundTransparency = 1 }
			)

			-- Reopening during the fade wins: the darkening on screen now is the new shop's, and
			-- disabling it here would erase a tab that just opened.
			tween.Completed:Connect(function(state : Enum.PlaybackState)
				if state ~= Enum.PlaybackState.Completed or self.OpenToken ~= token then return end

				background.Visible = false
				background.BackgroundTransparency = self.BackgroundTarget
			end)

			tween:Play()
		else
			background.Visible = false
			background.BackgroundTransparency = self.BackgroundTarget
		end
	end

	-- The hotbar comes back. This shop hid it when opening, and with it closing there is
	-- nothing left over the hand.
	self:_setDeckHidden(false)
end

--[=[
	Plays the cards' entrance backward and calls `onFinished` when the last one ends.

	The order mirrors the entrance: the content goes back to transparent (`CardReveal`)
	and only then does the card rise, fading its image (`CardDrop`); if both halves went
	together, the text would float alone in the air after the card had already risen.

	A card still falling enters the exit the same way: the delay that has not started is
	canceled and the drop in progress is cut, so it rises from where it was, instead of
	continuing down while the rest vanishes.
]=]
function RoundCardShopController:_dismissCards(onFinished : (() -> ())?)
	self.DismissToken += 1
	local token = self.DismissToken
	self.Dismissing = true

	local longest = 0

	for index, entry in self.CardEntries do
		local stagger = (index - 1) * ANIM.CardExitStagger
		longest = math.max(longest, stagger + ANIM.CardReveal + ANIM.CardDrop)

		local dismiss = task.delay(stagger, function()
			local card = entry.Card
			if self.DismissToken ~= token or not card.Parent then return end

			entry.Ready = false

			if entry.Delayed then
				pcall(task.cancel, entry.Delayed)
			end

			if entry.Drop then
				entry.Drop:Cancel()
			end

			applyFades(entry.Fades, 0, ANIM.CardReveal, Enum.EasingDirection.In)

			task.wait(ANIM.CardReveal)
			if self.DismissToken ~= token or not card.Parent then return end

			local base = entry.BasePosition
			local goal : { [string] : any } = {
				Position = UDim2.new(
					base.X.Scale, base.X.Offset,
					base.Y.Scale - ANIM.DropOffset, base.Y.Offset
				),
			}

			if card:IsA("ImageLabel") or card:IsA("ImageButton") then
				goal.ImageTransparency = 1
			end

			TweenService:Create(
				card,
				TweenInfo.new(ANIM.CardDrop, ANIM.CardEasing, Enum.EasingDirection.In),
				goal
			):Play()
		end)

		self.RowMaid:GiveTask(function()
			pcall(task.cancel, dismiss)
		end)
	end

	--[[
		This is the only delay that does **not** go in the row's maid: it closes the shop,
		and closing the shop clears the maid: it would cancel itself mid-call, and the
		hotbar would never come back. `DismissToken` already does the job: a new offer that
		arrives early knocks this end down when it wakes.
	]]
	task.delay(longest, function()
		if self.DismissToken ~= token then return end

		self.Dismissing = false

		if onFinished then
			onFinished()
		end
	end)
end

--[=[
	The exit without purchase: the cards vanish backward and the darkening fades.

	The button does **not** come back, on purpose: it was spent on the click that opened
	the shop, and the next offer brings it back; see `OpenedToken` in `_openShop`. The
	offer itself stays up on the server (a purchase or the round turning removes it), so
	the card stays buyable if the state is redrawn some other way; what ended was the
	invitation at the edge.
]=]
function RoundCardShopController:_dismissShop()
	if not self.ShopOpen or self.Dismissing then return end

	self:_dismissCards(function()
		self:_closeShop(ANIM.BackgroundFadeOut)
	end)
end

--[[ BUY AND USE ]]

--[=[
	Requests the purchase of a card.

	Without money, the click does not become a request: the server would refuse anyway (it
	holds the real cash), and what is avoided is the shop closing and reopening on its own
	because of a click that was never going to work.

	When it goes through, the shop retracts **right away**: it is the click's response, and
	it cannot wait for the network. The card, however, only enters the hotbar when
	`RoundCardBought` confirms: the server holds the stock.
]=]
--[=[
	This offer's card on screen, or `nil` if it is not on the table now.

	The wrappers are named by the card's `Id` when the rotation is built, so finding one
	is looking inside the row; there is no registry to maintain.

	It exists for code that needs to **point at** a card: today `TutorialStepController`,
	which asks the highlight to hug the one the step requires buying.
]=]
function RoundCardShopController:GetOfferCard(cardId : string) : GuiObject?
	local row = self.Row
	local wrapper = row and row:FindFirstChild(cardId)

	return if wrapper and wrapper:IsA("GuiObject") then wrapper else nil
end

function RoundCardShopController:_buy(cardId : string)
	local offer = self.Offer
	if not offer then return end

	local definition = RoundCardConfig.Get(cardId)
	if not definition then return end

	local price = (offer.prices and offer.prices[cardId]) or definition.Price or 0
	if self.Cash < price then return end

	Framework:Fire("BuyRoundCard", offer.token, cardId)

	self:_playSound(CARD_SOUND)

	self.Offer = nil
	self:_closeShop()
	self:_hideFrame()
end

--[=[
	Puts the card the server confirmed into the hotbar.

	Only the **appearance** comes from here: a clone of the same shop template, at hotbar
	size and without the price plate (in the deck the card is already paid for). What it
	does in the hand is the `Card` component's: from `addRound` on it is a hotbar card like
	any other: it falls into the arc, grows on hover, gets pushed by its neighbors, and dims
	when another card is selected.
]=]
function RoundCardShopController:_addToDeck(uid : string, cardId : string)
	if typeof(uid) ~= "string" or self.DeckCards[uid] then return end

	local template = self:_template()
	if not template then return end

	local definition = RoundCardConfig.Get(cardId)
	if not definition then return end

	local wrapper = template:Clone()
	wrapper.Name = "RoundCard_" .. cardId
	wrapper.Size = RoundCardConfig.DeckCardSize

	local card = wrapper:FindFirstChild(GUI.Card)
	if not card or not card:IsA("GuiObject") then
		wrapper:Destroy()
		return
	end

	self:_writeCard(card, definition, false)

	self.DeckCards[uid] = true

	self:_deck("addRound", uid, wrapper, function()
		self:_requestUse(uid, cardId)
	end)
end

--[=[
	A click on a hotbar card.

	An instant card becomes a request right away. A card that asks for a target enters
	aiming, and only becomes a request on the next click, the one that chooses the tower or
	the spot.

	Clicking again on the card **already** aiming gives it up. It is the natural pair of
	the click that started it: someone who clicked by mistake looks in the same place to
	undo it, not for a cancel button.
]=]
function RoundCardShopController:_requestUse(uid : string, cardId : string)
	-- The tutorial may be saving this card for its step. It is interface courtesy:
	-- `TutorialMatchService` does the real refusing.
	local tutorial = self.Controllers.TutorialStepController
	if tutorial and not tutorial:AllowsCardUse(cardId) then
		return
	end

	if self.UsePending[uid] then return end

	if self.Targeting and self.Targeting.Uid == uid then
		self:_cancelTargeting()
		return
	end

	local use = RoundCardConfig.GetUse(cardId)

	if use == USE.Place then
		self:_beginTargeting(uid, cardId, use)
		self:_beginPlacePlacement()
		return
	end


	if use == USE.Instant then
		self:_sendUse(uid, nil)
		return
	end

	self:_beginTargeting(uid, cardId, use)
end

--[=[
	Sends the use to the server.

	`target` is what aiming chose (the tower, the spot, or both), and it goes as a table
	because the server checks field by field against the card's type.

	**One use per card, and the server spends it.** The local latch exists so a double
	click does not become two requests: the second would be refused, but the first would
	already have removed the card, and the player would see an error in the log for
	something they did not do wrong.
]=]
function RoundCardShopController:_sendUse(uid : string, target : any?)
	if self.UsePending[uid] then return end
	self.UsePending[uid] = true

	self:_stopTargeting()

	Framework:Fire("UseRoundCard", uid, target)
	self:_playSound(CARD_SOUND)
end

--[=[
	Removes from the hotbar the card the server counted as used (or lost). The component
	makes the card drop out and closes the slot.
]=]
function RoundCardShopController:_removeFromDeck(uid : string)
	if not self.DeckCards[uid] then return end

	self.DeckCards[uid] = nil
	self.UsePending[uid] = nil

	--[[
		The card that was aiming left the hand: either the server spent it, or it refused
		and returned the state. Either way there is nothing left to aim, and an orphaned aim
		would leave the player's click locked on a target that goes nowhere.
	]]
	if self.Targeting and self.Targeting.Uid == uid then
		self:_stopTargeting()
	end

	self:_deck("removeRound", uid)
end

--[=[
	The gesture of using the card: the animation on the user's character, and the sound
	and particles it fires.

	**The animation keeps time.** The config's `Marker` is a single keyframe marker, and
	its **parameter** separates the two halves: `Sound` plays the sound, `VFX` bursts the
	particles. Reanimating the card in Moon Animator re-marks both without going through
	here, which a `task.delay` with the time written in code would not do.

	The VFX clone is created **now**, on use, not at the marker: hung on the
	`HumanoidRootPart` it follows the player, and doing it mid-animation would risk the
	burst frame arriving before the asset is in place. In exchange, whoever hangs it owes
	the burst **or** the cleanup, which is why an animation that ends without passing the
	marker takes the clone with it.

	This is the **user's** gesture, on their screen: the server sends `RoundCardUsed` only
	to them. Watchers receive `RoundCardVisual` and land in `_playRemoteUseVisual` just
	below, which is the missing half on the others' screens; the animation and the lock
	already arrive there on their own.
]=]
function RoundCardShopController:_playUseVisual(cardId : any)
	local definition = RoundCardConfig.Get(cardId)
	local visual = definition and definition.Visual
	if not visual then return end

	local character = Player.Character
	local root = character and character:FindFirstChild(CHARACTER_ROOT)
	if not root or not root:IsA("BasePart") then return end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
	if not animator or not visual.Animation then
		log:StudioWarn(`card '{tostring(cardId)}' has a Visual, but the character has no Animator (or the AnimationId is missing).`)
		return
	end

	local vfx = self.Controllers.VFXController
	local clone = vfx and vfx:AttachAsset(visual.VFX, root)

	--[[
		The `Animation` stays loose on purpose: the track itself keeps it alive, and both go
		away together when the animation ends and nothing else points at it. Destroying it
		here would pull the reference out from under the track just created from it.
	]]
	local animation = Instance.new("Animation")
	animation.AnimationId = visual.Animation

	local track = animator:LoadAnimation(animation)

	--[[
		`Action` so the gesture plays over the character's idle. The priority comes baked in
		the asset, and one exported as `Idle` or `Core` would tie with the animation the
		default `Animate` is already playing: the card would be used and the model would do
		nothing.
	]]
	track.Priority = Enum.AnimationPriority.Action

	local maid = Maid.new()
	local emitted = false

	--[[
		The player locks in place while the gesture happens: the card stops time, and a
		character walking under its own pose would give away that nothing stopped.
		Anchoring the `HumanoidRootPart` is enough: the rest of the body hangs from it.

		The previous state is read, not assumed: it could already be anchored for another
		reason, and restoring a hand-written `false` would unlock what was not ours to
		unlock.
	]]
	local wasAnchored = root.Anchored
	root.Anchored = true

	--[=[
		The gesture's end, wherever it comes from: unlocks the player, collects what is left,
		and disconnects the listeners.

		It is a single function on purpose. There are three possible ends (the animation
		finished, the animation was cut, the animation never played) and the player **must**
		be unlocked in all three. Leaving `Anchored = false` on one path only would be the
		way for their match to end right there.
	]=]
	local done = false
	local function finish()
		if done then return end
		done = true

		-- The character may have died meanwhile: the part is no longer anywhere,
		-- and the next `Character` comes with its own, unanchored `HumanoidRootPart`.
		if root.Parent then
			root.Anchored = wasAnchored
		end

		if not emitted and clone and clone.Parent then
			clone:Destroy()
		end

		maid:DoCleaning()
	end

	maid:GiveTask(track:GetMarkerReachedSignal(visual.Marker):Connect(function(parameter : string?)
		if parameter == MARKERS.Sound then
			local sound = visual.Sound and SoundService:FindFirstChild(visual.Sound)
			if sound and sound:IsA("Sound") then
				sound:Play()
			end
		elseif parameter == MARKERS.VFX then
			emitted = true

			-- From here on the clone's lifetime belongs to the asset itself: the module takes the
			-- deadline from its particles' lifetime.
			if vfx then
				vfx:EmitAttached(clone)
			end
		end
	end))

	-- The normal end: the animation finished, the player walks again.
	maid:GiveTask(track.Stopped:Connect(finish))

	track:Play()

	--[=[
		The safety net.

		An animation that does not load (wrong id, asset without permission) never plays
		and therefore never **stops**: `Stopped` does not come, and without a maximum
		deadline the player would stay anchored in place until they died. Stuck for a few
		seconds is a bug; stuck forever ends their match.

		The deadline is generous on purpose: it only needs to be longer than the longest
		animation a card may ever have, and never cut a legitimate gesture. It is also not
		canceled when the animation ends first: waking and seeing that `done` already
		happened costs nothing, and canceling the thread from inside itself would kill it
		mid-cleanup.
	]=]
	task.delay(ANCHOR_TIMEOUT, finish)
end

--[=[
	The same gesture, seen from outside: the sound and particles of a card **another**
	player used, on their character.

	Two halves arrive here on their own and are not redone. The **animation** plays on the
	user's character, and the `Animator` replicates it to everyone: loading it again here
	would put two identical tracks on the same body. The **lock** is the same case: the
	owner anchors the `HumanoidRootPart` they control, and the character stops walking on
	every screen as a consequence. What does not cross is the sound (which is local) and
	the VFX (which is a clone made on the client), and that is all this path does.

	**The clock here is the config, not the marker.** The keyframe marker only reaches
	whoever loaded the track, and this screen loaded none: it is watching a replicated
	animation. `SoundDelay` and `EffectDelay` are copies of the two markers' instants, and
	`CardShopService` checks them against the real animation on startup: it is the same
	number the server uses to time the freeze, so the particles land on the frame the
	enemies stop, here as there.

	The clone is created now and not at the burst, for the same reason as the owner's
	gesture: hung on the root it follows the player, and creating it at the last instant
	would risk the asset arriving late.
]=]
function RoundCardShopController:_playRemoteUseVisual(cardId : any, user : Player?)
	if not user or user == Player then return end

	local definition = RoundCardConfig.Get(cardId)
	local visual = definition and definition.Visual
	if not visual then return end

	local character = user.Character
	local root = character and character:FindFirstChild(CHARACTER_ROOT)
	if not root or not root:IsA("BasePart") then return end

	--[[
		The sound belongs to the **room**, not the character: it plays in `SoundService`,
		with no position. The card freezes everyone's enemies, and a sound fading with
		distance would say the effect is over there, not here.

		That is why it does not depend on the clone or the character staying up: the user
		may die mid-gesture, and the freeze happens anyway.
	]]
	if visual.Sound then
		task.delay(visual.SoundDelay or visual.EffectDelay or 0, function()
			local sound = SoundService:FindFirstChild(visual.Sound)
			if sound and sound:IsA("Sound") then
				sound:Play()
			end
		end)
	end

	local vfx = self.Controllers.VFXController
	local clone = vfx and vfx:AttachAsset(visual.VFX, root)
	if not clone then return end

	task.delay(visual.EffectDelay or 0, function()
		-- The character may have left the scene during the wait, and the clone goes with
		-- it: there is nowhere to burst, and nothing to clean up.
		if not clone.Parent then return end

		vfx:EmitAttached(clone)
	end)
end

--[[ AIMING ]]

--[=[
	The ring that follows the pointer while the card asks for a spot.

	It is the same model as a selected tower's range circle, on purpose: the player
	already learned that drawing means "this area". The scale comes from the diameter of
	the part inside it, the same way `UnitPlacementController` does it: that way changing
	the ring in Studio does not leave the radius lying.
]=]
function RoundCardShopController:_buildRing(radius : number, color : Color3?) : Model?
	local template : Instance? = UIAssets
	for _, name in TARGETING.RingAsset do
		template = template and template:FindFirstChild(name)
	end

	if not template or not template:IsA("Model") then
		log:StudioWarn(`could not find ring {table.concat(TARGETING.RingAsset, ".")} in Assets.UI; targeting has no circle.`)
		return nil
	end

	local ring = template:Clone()
	local part = ring:FindFirstChild(TARGETING.RingPart)

	if part and part:IsA("BasePart") and part.Size.X > 0 then
		ring:ScaleTo(ring:GetScale() * (radius * 2) / part.Size.X)
	end

	for _, descendant in ring:GetDescendants() do
		if descendant:IsA("BasePart") then
			--[[
				`Anchored` for the same reason as the ground ring (see
				`CardModifierController:_drawZones`): the Workspace simulates what hangs from
				the Camera, and a loose Part falls and vanishes on its own. This ring is
				repositioned every frame, so the fall would be less visible, and harder to
				find.
			]]
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
		end
	end

	if color then
		self:_paintRing(ring, color)
	end

	ring.Parent = workspace.CurrentCamera
	self.TargetMaid:GiveTask(ring)

	return ring
end

--[=[
	Paints the aiming ring.

	It is a separate function because the area ring's color **changes mid-aim**: it turns
	red where the spot is taken by another area of the same player and back to green when
	the cursor leaves it (see `_updateTargeting`).

	The requested color is stored on the Model itself, and painting bails out when it did
	not change: walking the ring's descendants sixty times a second to write the same color
	is work that does not show on screen.
]=]
function RoundCardShopController:_paintRing(ring : Model, color : Color3)
	if ring:GetAttribute("PaintedColor") == color then return end
	ring:SetAttribute("PaintedColor", color)

	for _, descendant in ring:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Color = color
		end
	end
end

--[=[
	Is this spot taken by another area of the **same player**?

	It only applies to `Use.Area`: Zippers' second step also moves over the ground, but
	the tower's ghost decides its destination, and neither it nor the tower draws any area.

	`CardModifierController` answers, by the same math the server does in
	`FindZoneOverlap`. Without it (the list has not arrived yet), the spot counts as free:
	the server checks again, and locking the card over a controller that did not start
	would be worse than a refused click.

	It is asked in both places that need the answer (the ring's color, every frame, and the
	click) instead of the click reusing the last drawn frame: on mobile the first tap **is**
	the first frame where "where the finger is" exists, and there is no previous frame to
	consult.
]=]
function RoundCardShopController:_blockedAt(cardId : string, ground : Vector3?) : boolean
	if not ground then return false end

	local modifiers = self.Controllers.CardModifierController
	if not modifiers then return false end

	return modifiers:FindZoneOverlap(ground, RoundCardConfig.GetRadius(cardId)) ~= nil
end

--[=[
	The ground under the pointer.

	Returns the world point, or nil when the ray touches nothing (the sky, the edge of the
	map). `UnitPlacementController` casts the ray, and it already filters the player's own
	character: it walks around the map and would hide the ground behind it.
]=]
function RoundCardShopController:_groundAt(screenPosition : Vector2) : Vector3?
	local placement = self.Controllers.UnitPlacementController
	if not placement then return nil end

	local hit = placement:raycastFromPointer(screenPosition)

	return hit and hit.Position or nil
end

--[=[
	The modifiers this card **would** create if used now, for the preview.

	They are the same `RoundCardConfig` records the server would put on the field, with the
	zone already filled with the map point under the cursor, and being the same list is on
	purpose: the function that draws the feedback is the same one that draws the real
	effect, so what the player reads before releasing the card is exactly what they will
	see afterward.

	The records are **copied** before getting the zone: the config's are the card's
	declaration, and writing the cursor position into them would make that card's next use
	start with the previous aim's zone.

	A card without `Modifiers` (Zippers, the Staff of Healing) returns nil: there is no buff
	or debuff to anticipate, and its aiming keeps only the ring and the highlight.
]=]
function RoundCardShopController:_previewRecords(cardId : string, position : Vector3?)
	local definition = RoundCardConfig.Get(cardId)
	local records = definition and definition.Params and definition.Params.Modifiers

	if not records or #records == 0 then
		return nil
	end

	local preview = {}

	for _, record in records do
		local copy = table.clone(record)

		if record.Zone then
			-- A record that asks for a zone and has no point yet would become a global
			-- buff in the preview, the opposite of what an area staff promises.
			if not position then
				return nil
			end

			copy.Zone = { Position = position, Radius = RoundCardConfig.GetRadius(cardId) }
		end

		table.insert(preview, copy)
	end

	return preview
end

--- Drops the preview, if one is up.
function RoundCardShopController:_clearPreview()
	local feedback = self.Controllers.WeatherFeedbackController
	if feedback then
		feedback:ClearPreview()
	end

	if self.Targeting then
		self.Targeting.PreviewAt = nil
		self.Targeting.PreviewUnit = nil
	end
end

--[=[
	Highlights the tower under the pointer while the card waits for one.

	The highlight is moved, not redrawn: sweeping the pointer over a row of towers would
	create and destroy a Highlight per frame.
]=]
function RoundCardShopController:_hoverUnit(unitModel : Model?)
	if self.HoverModel == unitModel then return end

	self.HoverModel = unitModel
	self.HoverMaid:DoCleaning()

	if not unitModel then return end

	--[[
		A card that changes stats gets no highlight of its own: `WeatherFeedbackController`
		paints the tower under the pointer for it, with **this same yellow**
		(`Targeting.Colors.Unit`) plus icons for what it will feel. Two Highlights on the same
		model would leave the two colors fighting, and its one says more.

		The highlight here is left for cards with nothing to anticipate: Zippers, which only
		moves the tower.
	]]
	if self.Targeting and self.Targeting.PreviewRecords then
		return
	end

	local highlight = Instance.new("Highlight")
	highlight.Name = "RoundCardHover"
	highlight.FillColor = TARGETING.Colors.Unit
	highlight.OutlineColor = TARGETING.Colors.Unit
	highlight.FillTransparency = 0.65
	highlight.OutlineTransparency = 0.1
	highlight.Parent = unitModel

	self.HoverMaid:GiveTask(highlight)
end

--[=[
	Starts aiming for a card that asks for a target.

	While it lasts, clicks in the world belong to the card: `UnitPlacementController` stops
	selecting towers (or the same click would do both) and resumes when aiming ends,
	however it ends.

	`Move` (Zippers) is the two steps in sequence: first the tower, then the destination.
	It is not a third mode: it **is** the other two, one after the other, which is why
	`Stage` rules what the screen draws, not the card's `Use`.
]=]
function RoundCardShopController:_beginTargeting(uid : string, cardId : string, use : string)
	self:_stopTargeting()

	local stage = if use == USE.Move then USE.Unit else use

	self.Targeting = {
		Uid = uid,
		CardId = cardId,
		Use = use,
		Stage = stage,
	}

	--[[
		The lock goes up now and only drops on the frame after aiming ends; see
		`_stopTargeting`. The token keeps a previous aim's drop from unlocking this one,
		which just started.
	]]
	self.LockToken += 1

	local placement = self.Controllers.UnitPlacementController
	if placement then
		placement:setPointerLocked(true)
	end

	--[[
		The card is now **in hand**, and the hotbar draws it as it draws an equipped unit
		card: it grows and the others dim. It is the only sign that aiming is open: there is
		no panel or cancel button, just as there is none when the player puts a unit in hand.

		`onCleared` is the case where the hand changes from outside: the player clicked a
		unit card, and that round card's aim has no owner anymore.
	]]
	self:_deck("setSelectedRound", uid, function()
		self:_stopTargeting()
	end)

	self:_playSound(CARD_SOUND)

	--[[
		The preview list is built once here, and what changes every frame is only the zone's
		position inside it. A card without a modifier (Zippers) keeps nil, and its aiming
		anticipates nothing: there is nothing to anticipate.
	]]
	self.Targeting.PreviewRecords = self:_previewRecords(cardId, Vector3.zero)

	if stage == USE.Area then
		self.Targeting.Ring = self:_buildRing(RoundCardConfig.GetRadius(cardId), TARGETING.Colors.Area)
	end

	self.TargetMaid:GiveTask(RunService.RenderStepped:Connect(function()
		self:_updateTargeting()
	end))

	self.TargetMaid:GiveTask(PointerUtil.onPointerAction(function(screenPosition : Vector2)
		self:_confirmTarget(screenPosition)
	end))

	--[=[
		Giving up by keyboard.

		The right button is left out on purpose: it does not exist on mobile, and on PC it
		is the camera: someone turning the view to find where to put the ring would cancel
		the card by accident. The exit that works on any device is clicking the card again,
		which is how an equipped unit is dropped (see `_requestUse`).

		`gameProcessedEvent` is **not** filtered for Esc on purpose: it may arrive marked as
		processed (Roblox uses the same key), and an aim you cannot leave is worse than one
		that leaves once too often.
	]=]
	self.TargetMaid:GiveTask(UserInputService.InputBegan:Connect(function(input : InputObject)
		if input.KeyCode == Enum.KeyCode.Escape then
			self:_cancelTargeting()
		end
	end))
end

--- Redraws what aiming shows, on the frame: the ring on the ground or the tower highlight.
function RoundCardShopController:_updateTargeting()
	local targeting = self.Targeting
	if not targeting then return end

	--[[
		Zippers' second step is drawn by `UnitPlacementController`: the ghost, the range
		ring, and the painted path are its own. Nothing else comes from here while it is up,
		or there would be two drawings competing for the same pointer.
	]]
	if targeting.Placement then return end

	local screenPosition = PointerUtil.getScreenPosition()

	-- On mobile, before the first tap, "where the finger is" does not exist: aiming
	-- waits instead of drawing in the corner of the screen.
	if not screenPosition then return end

	local feedback = self.Controllers.WeatherFeedbackController

	if targeting.Stage == USE.Unit then
		local placement = self.Controllers.UnitPlacementController
		local unitModel = placement and placement:getUnitAtPointer(screenPosition) or nil

		self:_hoverUnit(unitModel)

		--[[
			The tower under the pointer shows, over its own head, what the card would do to
			it. Only on a tower change: while the pointer stays on the same one, there is
			nothing new to draw.
		]]
		if feedback and targeting.PreviewUnit ~= unitModel then
			targeting.PreviewUnit = unitModel

			feedback:SetPreview(if unitModel then targeting.PreviewRecords else nil, unitModel)
		end

		return
	end

	local ground = self:_groundAt(screenPosition)
	if not ground then return end

	-- Red where the ring would touch an area this player already drew. See
	-- `_blockedAt`, which the click asks again.
	local blocked = targeting.Stage == USE.Area and self:_blockedAt(targeting.CardId, ground)

	--[[
		The ring follows the ground under the cursor. It may not exist (missing asset), and
		the preview still applies: the point decides where the card lands, not its drawing.
	]]
	local ring = targeting.Ring
	if ring and ring.Parent then
		ring:PivotTo(CFrame.new(ground.X, ground.Y + ring:GetExtentsSize().Y / 2, ground.Z))
		self:_paintRing(ring, if blocked then TARGETING.Colors.Blocked else TARGETING.Colors.Area)
	end

	--[[
		Every tower the ring reaches lights up with what it will feel, and goes dark when the
		ring leaves it. That is what makes "where to put the staff" a decision made by
		looking at the map, not by reading the card's description.

		`PREVIEW_STEP` is the brake: a still cursor sends the same point sixty times a
		second, and each preview is a sweep over every tower. Movement smaller than it does
		not change who is inside the ring.
	]]
	if not feedback then return end

	local records = targeting.PreviewRecords
	if not records then return end

	local last = targeting.PreviewAt
	if last and (last - ground).Magnitude <= PREVIEW_STEP then return end

	targeting.PreviewAt = ground

	--[[
		The zone is rewritten **in place**, not rebuilt: the list was cloned once at the
		start of aiming (see `_beginTargeting`), and rebuilding it every frame would allocate
		a copy of the whole card sixty times a second to change three numbers.
	]]
	for _, record in records do
		if record.Zone then
			record.Zone.Position = ground
		end
	end

	feedback:SetPreview(records)
end

--[=[
	The click that chooses.

	A click that hits nothing (the sky, a spot with no ground) does **not** cancel: it just
	does not count. Canceling there would make a crooked click cost the card, and the exit
	already has its own doors (clicking the card again, and Esc).
]=]
function RoundCardShopController:_confirmTarget(screenPosition : Vector2)
	local targeting = self.Targeting
	if not targeting then return end

	-- The ghost itself confirms Zippers' destination, through `_beginMovePlacement`'s
	-- `OnConfirm`. This click is the same one, and would count twice.
	if targeting.Placement then return end

	if targeting.Stage == USE.Unit then
		local placement = self.Controllers.UnitPlacementController
		if not placement then return end

		local unitModel, unitId = placement:getUnitAtPointer(screenPosition)
		if not unitModel or not unitId then return end

		if targeting.Use == USE.Unit then
			self:_sendUse(targeting.Uid, { UnitId = unitId })
			return
		end

		-- The chosen tower: Zippers' second step is the whole placement,
		-- not a ring on the ground. See `_beginMovePlacement`.
		targeting.UnitId = unitId
		targeting.Stage = USE.Move

		self:_hoverUnit(nil)
		self:_clearPreview()

		self:_beginMovePlacement(unitModel, unitId)
		return
	end

	local ground = self:_groundAt(screenPosition)
	if not ground then return end

	--[[
		A click on red does not count, and does not cancel: the same rule as the click on
		the sky just above. The card stays in hand and aiming open, and the player moves the
		cursor out of the area already on the ground.

		The server checks this again on its own (see `CardShopService:_checkTarget`). Here it
		is feedback, not the rule: what is at stake is the round trip of a click already
		known to be refused.
	]]
	if targeting.Stage == USE.Area and self:_blockedAt(targeting.CardId, ground) then
		return
	end

	self:_sendUse(targeting.Uid, { Position = ground })
end

--[=[
	Zippers' second step: choosing where the tower goes.

	It **is** a unit placement, not an aim that looks like one.
	`UnitPlacementController:visualize` draws it and decides whether the spot works, the
	same one that drops a new tower: the player sees their own tower's model in half-tone,
	green where it can go and red where it cannot, with its range ring and the painted
	path, and on mobile the same double tap.

	Reusing that, instead of repeating the checks here, is the point: Zippers' destination
	goes through the same rules as a new placement (off the path, unobstructed, away from
	other towers, nobody on top), and a second copy of those rules would diverge from the
	first the day one of them changed, which is the same reason `PlacementUtil` exists
	between client and server.

	**The tower itself leaves the math** (`IgnoreModel`): it is still standing at the old
	spot during the choice, and without this it would obstruct its own destination. That is
	what `UnitService:isSpotFree`'s `ignoreEntry` already does on the server side.

	**Rotation counts**, as in any placement: R rotates the ghost and the angle travels with
	the destination. The ghost starts at the tower's current rotation, so someone who only
	wants to move it need not do anything, and someone who wants to turn the tower to the
	other side of the path can, without selling and rebuying.
]=]
function RoundCardShopController:_beginMovePlacement(unitModel : Model, unitId : string)
	local targeting = self.Targeting
	if not targeting then return end

	local placement = self.Controllers.UnitPlacementController
	if not placement then return end

	local uid = targeting.Uid
	local unitName = unitModel.Name
	local pivot = unitModel:GetPivot()
	local _, yaw = pivot:ToEulerAnglesYXZ()

	placement:visualize(unitName, {
		IgnoreModel = unitModel,
		Range = placement:getUnitRange(unitName, unitModel:GetAttribute("Upgrades") or 0, pivot.Position, unitId),
		Rotation = math.deg(yaw),

		--[[
			It sends the CFrame the ghost validated, split into point and angle.

			The point is the CFrame's, not the ground under the cursor: that is already the
			height at which the unit rests, measured the same way `PlaceUnit` measures for a
			new tower. The angle is only Y, in radians, because it is the only one the ghost
			rotates: sending the whole CFrame would give the client twelve numbers to lie
			with where one is enough.
		]]
		OnConfirm = function(cf : CFrame)
			local _, spin = cf:ToEulerAnglesYXZ()

			self:_sendUse(uid, { UnitId = unitId, Position = cf.Position, Rotation = spin })
		end,

		OnCancel = function()
			self:_cancelTargeting()
		end,
	})

	--[[
		The step only becomes "placement" if the ghost actually came up.

		`visualize` gives up silently in two cases (a ghost is already up, or the model is
		not in `Assets.Units`), and marking the step before knowing that would leave the card
		in limbo: nothing drawn on screen, the click with no owner (`_confirmTarget` would
		already have left through the `Placement` door) and only Esc as a way out. With no
		ghost, aiming is undone and the card returns whole to the hand: it is only spent when
		the server confirms.
	]]
	targeting.Placement = placement.isPlacing == true

	if not targeting.Placement then
		self:_cancelTargeting()
	end
end

--[[
	Endless shop towers: clicking the card in the hotbar brings up the unit ghost, exactly
	like a deck card. Confirming sends the spot to the server as this card's use.
]]
function RoundCardShopController:_beginPlacePlacement()
	local targeting = self.Targeting
	if not targeting then return end

	local placement = self.Controllers.UnitPlacementController
	if not placement then return end

	local definition = RoundCardConfig.Get(targeting.CardId)
	local unitName = definition and definition.Params and definition.Params.Unit
	if not unitName then
		self:_cancelTargeting()
		return
	end

	local uid = targeting.Uid

	placement:visualize(unitName, {
		OnConfirm = function(cf : CFrame)
			local _, spin = cf:ToEulerAnglesYXZ()

			self:_sendUse(uid, { Position = cf.Position, Rotation = spin })
		end,

		OnCancel = function()
			self:_cancelTargeting()
		end,
	})

	targeting.Placement = placement.isPlacing == true

	if not targeting.Placement then
		self:_cancelTargeting()
	end
end



--- Collects what aiming drew and returns clicks to placement.
function RoundCardShopController:_stopTargeting()
	if not self.Targeting then return end

	local hadPlacement = self.Targeting.Placement == true

	self.Targeting = nil

	self.TargetMaid:DoCleaning()
	self:_hoverUnit(nil)

	-- Units go back to showing what they are actually feeling.
	self:_clearPreview()

	-- The card leaves the hand: it returns to normal size and its neighbors light back up.
	self:_deck("setSelectedRound", nil)

	local placement = self.Controllers.UnitPlacementController
	if not placement then return end

	--[[
		Zippers' ghost drops along with aiming, whatever the exit: the confirmed destination,
		Esc, the card clicked again, or the card the server took out of the hand. `unequip`
		on an empty hand does nothing, but the check avoids knocking down a ghost that is not
		ours.
	]]
	if hadPlacement then
		placement:unequip()
	end

	--[=[
		The click lock drops on the **next frame**, not now.

		The click that chose the target is the same `InputBegan` `UnitPlacementController`
		listens to for selecting towers, and the two are separate listeners on the same
		event: their order is not promised anywhere. Unlocking here, midway through
		processing that click, the placement handler could run afterward, and then the same
		click that spent the card would open the chosen tower's upgrade card.

		One frame of delay solves it because it is always after **all** of that input's
		listeners. It is the same remedy as the shop's click-outside, which compares the
		`InputObject` in a `task.defer` for the same reason.

		The token is the race on the other side: a new card aimed on the same frame the
		previous one ended must not be unlocked by the previous one's drop.
	]=]
	self.LockToken += 1
	local token = self.LockToken

	task.defer(function()
		if self.LockToken ~= token then return end

		placement:setPointerLocked(false)
	end)
end

--[=[
	Gives up aiming. The card **stays in hand**: it is only spent when the server confirms
	the use, and giving up choosing a spot is not using the card.
]=]
function RoundCardShopController:_cancelTargeting()
	self:_stopTargeting()
end

--[[ SERVER STATE ]]

--[=[
	The shop's whole state, as the server sees it: the open offer and the cards in hand.

	It rebuilds the screen of a player who joined mid-match, who reloaded the interface,
	and who had a purchase refused. That is why the hotbar is reconciled both ways: what
	the server has and is not on screen comes in, and what is on screen and the server
	does not have leaves.
]=]
function RoundCardShopController:_applyState(state)
	if typeof(state) ~= "table" then return end

	local owned = {}
	for _, entry in (state.owned or {}) do
		if typeof(entry) == "table" and typeof(entry.Uid) == "string" then
			owned[entry.Uid] = entry.Id
			self:_addToDeck(entry.Uid, entry.Id)

			--[[
				The card is still in the server's hand, so the use that was in flight did not
				happen: it was refused (the chosen tower was sold meanwhile, the spot did not
				work) and the latch must come off, or that card would never respond to a click
				again.

				The price is a narrow race: a state arriving for another reason (the shop
				opening on a new wave) between the request and the confirmation releases the
				latch early, and a double click right then becomes a second request, which the
				server refuses with a log line. A dead card in hand is much worse than that.
			]]
			self.UsePending[entry.Uid] = nil
		end
	end

	for uid, _ in self.DeckCards do
		if not owned[uid] then
			self:_removeFromDeck(uid)
		end
	end

	local offer = if state.token and state.cards then { token = state.token, cards = state.cards, prices = state.prices or {} } else nil
	local sameOffer = self.Offer and offer and self.Offer.token == offer.token

	self.Offer = offer

	if not offer then
		self:_closeShop()
		self:_hideFrame()
		return
	end

	--[[
		The button only lights for an offer this player has not opened yet.

		It is two refusals in one. With the tab open it is retracted on purpose, and a state
		arriving from the server meanwhile must not bring it back over the darkening. And
		once the shop is opened, that offer's `token` is marked in `OpenedToken`: the states
		the server resends later (a refused purchase, a refused use, the interface reloading)
		redraw the hotbar without making the invitation again. A different `token` lights the
		edge: the difficulty's next shop wave.
	]]
	if not self.ShopOpen and offer.token ~= self.OpenedToken then
		self:_showFrame()
	end

	-- A new offer with the tab already open (the wave turned while the player looked at the
	-- cards): the cards on screen belong to the old offer and must be redrawn, and
	-- it is this offer, not the previous one, the tab is spending.
	if self.ShopOpen and not sameOffer then
		self.OpenedToken = offer.token

		self:_renderCards()
	end
end

--[[ BIND ]]

function RoundCardShopController:_bind() : boolean
	local screen = PlayerGui:WaitForChild(GUI.ScreenGui, WAIT_TIMEOUT)
	if not screen then
		log:StudioWarn(`could not find {GUI.ScreenGui}.`)
		return false
	end

	local frame = screen:WaitForChild(GUI.Frame, WAIT_TIMEOUT)
	local background = screen:WaitForChild(GUI.Background, WAIT_TIMEOUT)

	if not frame or not background then
		log:StudioWarn(`{GUI.ScreenGui} has no {GUI.Frame} and {GUI.Background}.`)
		return false
	end

	self.Frame = frame
	self.BasePosition = frame.Position
	self.Background = background
	self.BackgroundTarget = background.BackgroundTransparency
	self.Row = background:WaitForChild(GUI.Row, WAIT_TIMEOUT)

	frame.Visible = false
	frame.Position = self:_hiddenPosition()
	background.Visible = false

	--[[
		The darkening starts eating input: that keeps a click made with the shop open from
		going through the screen and becoming a tower placed on the ground behind it.
		`UserInputService` **listens** for the click outside (see `_openShop`); this is only
		the barrier. It only applies while visible: closed, it eats nobody's clicks.
	]]
	background.Active = true

	local button = frame:FindFirstChild(GUI.Button)
	if button and button:IsA("GuiButton") then
		self.Button = button

		-- Read before any animation plays: this is where the sway returns to.
		self.ButtonPosition = button.Position
		self.ButtonRotation = button.Rotation

		button.Activated:Connect(function()
			if self.ShopOpen then
				self:_dismissShop()
				return
			end

			self:_openShop()
		end)
	else
		log:StudioWarn(`{GUI.Frame} has no {GUI.Button} button.`)
	end

	return true
end

--[[ LIFECYCLE ]]

function RoundCardShopController:construct()
	--[[
		The `Listen`s go in before the bind because the bind waits for the GUI to replicate:
		a state arriving during that wait would be lost, and the shop would only reappear on
		the next shop wave.
	]]
	Framework:Listen("RoundCardState", function(state)
		self:_applyState(state)
	end)

	Framework:Listen("RoundCardBought", function(payload)
		if typeof(payload) ~= "table" then return end

		self.Offer = nil
		self:_closeShop()
		self:_hideFrame()
		self:_addToDeck(payload.uid, payload.id)
	end)

	Framework:Listen("RoundCardUsed", function(payload)
		if typeof(payload) ~= "table" then return end

		self:_removeFromDeck(payload.uid)

		-- The gesture goes out on confirmation, not on the click: the server spends the card,
		-- and a refused use must not leave the character posing.
		self:_playUseVisual(payload.id)
	end)

	-- The same card, used by someone else. The server only sends this to those who did **not**
	-- use it; the user is already in `RoundCardUsed` above.
	Framework:Listen("RoundCardVisual", function(payload)
		if typeof(payload) ~= "table" then return end

		self:_playRemoteUseVisual(payload.id, payload.user)
	end)

	--[[
		Safety net: the round restarted with aiming open. Without this the player's click
		would stay locked in the placement of a match that already ended.
	]]
	Framework:Listen("RoundRestarted", function()
		self:_stopTargeting()
	end)

	-- The price is written on the card and match cash pays it: without this the
	-- click would become a request the server refuses.
	Framework:Listen("UpdateCash", function(amount : number)
		self.Cash = amount or 0
	end)
	Framework:Fire("RequestCash")

	task.spawn(function()
		if not self:_bind() then
			return
		end

		-- The offer already open when this client loaded, and the cards
		-- it had already bought.
		Framework:Fire("RequestRoundCardState")
	end)
end

function RoundCardShopController:start()
	for Controller, _ in self.Controllers do
		self.Controllers[Controller] = Framework:Get(Controller)
	end
end

function RoundCardShopController:init()
	self.Offer = nil
	self.Cash = 0
	self.ShopOpen = false
	self.FrameShown = false
	self.Dismissing = false
	self.OpenToken = 0
	self.FrameToken = 0
	self.DismissToken = 0

	-- Goes up on every lock and unlock of clicks in the world. See `_stopTargeting`.
	self.LockToken = 0

	-- The `token` of the offer the player already opened: the button does not offer itself
	-- twice for the same one. Nil until the match's first shop.
	self.OpenedToken = nil

	-- [uid] = the Maid of the wrapper in the hotbar.
	self.DeckCards = {}
	self.UsePending = {}

	-- The three cards on screen, in the order they fell: the exit staggers by it.
	self.CardEntries = {}

	--[[
		A target-asking card's aim: which card, at what step, and what it has chosen so
		far. Nil when nobody is aiming.
	]]
	self.Targeting = nil

	self.RowMaid = Maid.new()
	self.FrameMaid = Maid.new()
	self.ShopMaid = Maid.new()
	self.IdleMaid = Maid.new()

	-- What aiming drew (the ring, the listeners) and the highlight of the tower under the pointer.
	-- Separate because the highlight changes per tower, and the rest only at the end of aiming.
	self.TargetMaid = Maid.new()
	self.HoverMaid = Maid.new()

	self:construct()
end

return RoundCardShopController
