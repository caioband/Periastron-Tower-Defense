local TweenService = game:GetService("TweenService")

local UIUtil = {}

local SUFFIXES = {"", "K", "M", "B", "T", "Qa", "Qi"}

function UIUtil.formatAbbreviated(num: number): string
	if num < 1000 then return tostring(num) end

	local visibleIdx = math.floor(math.log10(num) / 3)
	local suffixIdx = math.clamp(visibleIdx + 1, 1, #SUFFIXES)
	local suffix = SUFFIXES[suffixIdx]

	local abbreviated = num / (10 ^ (visibleIdx * 3))

	if abbreviated % 1 == 0 then
		return string.format("%d%s", abbreviated, suffix)
	else
		return string.format("%.2f%s", abbreviated, suffix):gsub("%.?0+$", "")
	end
end

function UIUtil.formatCommas(num: number): string
	local formatted = tostring(num)
	local k

	while true do
		formatted, k = string.gsub(formatted, "^(-?%d+)(%d%d%d)", '%1,%2')
		if k == 0 then break end
	end

	return formatted
end

--[=[
	Waits for a descendant by name, at any depth. `WaitForChild` only looks at
	direct children, and GUIs change shape over time: a HUD button may be loose in
	the frame today and inside a wrapper tomorrow.

	Returns nil on timeout (10 s by default), like `WaitForChild` with a timeout.
]=]
function UIUtil.waitForDescendant(root: Instance, name: string, timeout: number?): Instance?
	local deadline = os.clock() + (timeout or 10)

	repeat
		local found = root:FindFirstChild(name, true)
		if found then
			return found
		end

		task.wait(0.05)
	until os.clock() >= deadline

	return root:FindFirstChild(name, true)
end

--[[ TRANSPARENCY ]]

--[=[
	Which transparency properties each piece has.

	`GuiObject.Transparency` is left out on purpose: it aliases
	`BackgroundTransparency`, and two tweens would fight over the same property.

	It lives here, not in the round shop controller, because **both** places draw
	the same card: the round shop reveals it mid-match (Game) and the Lobby card
	shop reveals the same art at the counter (Lobby). A second copy of the property
	list would be two lists to update.
]=]
function UIUtil.fadeProperties(object: Instance): { string }?
	if object:IsA("UIStroke") then
		return { "Transparency" }
	elseif object:IsA("ImageLabel") or object:IsA("ImageButton") then
		return { "BackgroundTransparency", "ImageTransparency" }
	elseif object:IsA("TextLabel") or object:IsA("TextButton") or object:IsA("TextBox") then
		return { "BackgroundTransparency", "TextTransparency", "TextStrokeTransparency" }
	elseif object:IsA("GuiObject") then
		return { "BackgroundTransparency" }
	end

	--[[
		`UIShadow` is not in the class list above because it is neither a
		`GuiObject` nor a `UIStroke`; it comes in here, along with any new UI
		component with its own `Transparency`.

		Only when `Transparency` is a **number**: a `UIGradient`'s is a
		`NumberSequence`, and tweening it as a number would break the card's whole
		gradient.
	]]
	local ok, value = pcall(function()
		return (object :: any).Transparency
	end)

	return if ok and typeof(value) == "number" then { "Transparency" } else nil
end

--[=[
	Every (piece, property) pair with the value the designer left, scanning the
	**descendants** of `root` (the caller handles `root` itself; on the card, the
	drop with the image fading in).

	It must read the untouched clone, **before** any transparency write: these
	are the values `applyFades(fades, 1)` restores, and capturing later would
	record the hidden state as the authored one.
]=]
function UIUtil.captureFades(root: Instance)
	local fades = {}

	for _, descendant in root:GetDescendants() do
		local properties = UIUtil.fadeProperties(descendant)
		if not properties then
			continue
		end

		local values = {}
		for _, property in properties do
			values[property] = (descendant :: any)[property]
		end

		table.insert(fades, { Object = descendant, Values = values })
	end

	return fades
end

--[=[
	Writes the transparency of every descendant at once.

	`progress` goes from 0 (fully transparent) to 1 (the authored values). Without
	`info` the value jumps; with `info` each piece tweens there, and the caller
	picks the curve (a card's entrance decelerates and its exit accelerates).
]=]
function UIUtil.applyFades(fades, progress: number, info: TweenInfo?)
	for _, fade in fades do
		local object = fade.Object :: any
		if not object.Parent then continue end

		local goal = {}
		for property, authored in fade.Values do
			goal[property] = 1 + (authored - 1) * progress
		end

		if not info then
			for property, value in goal do
				object[property] = value
			end
			continue
		end

		-- A property TweenService refuses jumps straight there instead of taking down the
		-- animation of the other pieces.
		local ok = pcall(function()
			TweenService:Create(object, info, goal):Play()
		end)

		if not ok then
			for property, value in goal do
				object[property] = value
			end
		end
	end
end

return UIUtil
