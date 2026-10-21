local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("MapEditor")
local Config = require(Shared.Config)
local Catalog = require(Shared.Catalog)
local Serializer = require(Shared.Serializer)
local RouteModel = require(Shared.RouteModel)
local Factory = require(Shared.InstanceFactory)

local State = require(script.Parent.State)
local Geometry = require(script.Parent.Geometry)

local player = Players.LocalPlayer

local UI = {}

local THEME = {
	Bg = Color3.fromHex("3D221D"),
	Bg2 = Color3.fromHex("251411"),
	Button = Color3.fromHex("59322B"),
	ButtonOn = Color3.fromHex("DA912B"),
	Stroke = Color3.fromHex("DA912B"),
	Edge = Color3.fromHex("251411"),
	Text = Color3.fromHex("F3DDB6"),
	TextDark = Color3.fromHex("251411"),
	Muted = Color3.fromHex("B08A6A"),
	Accent = Color3.fromHex("DA912B"),
	Danger = Color3.fromHex("C8372D"),
	Warn = Color3.fromHex("E9A23B"),
	Ok = Color3.fromHex("4FC24A"),
}
UI.THEME = THEME

local PIXEL_FONT = Enum.Font.Arcade

local actions = nil
local gui, launcher, topBar, testBar, catalogPanel, inspectorPanel, inspectorScroll
local validationPanel, validationList, validationHeader, toastHolder, modalLayer, helpPanel
local tooltip, statusLabel, hintLabel, testStats, towerButton, selectionRect
local itemsFrame, searchBox, categoryHolder, recentRow, gridLabel
local settingsHolder = nil
local uiScale = nil
local toolButtons = {}
local toggleButtons = {}
local tabSkins = {}
local currentCategory = "All"
local tooltipText = nil
local inspectorKey = nil

local MOVE_PRESETS = { 0.01, 0.1, 0.25, 1, 4, 10, 50 }
local ROTATE_PRESETS = { 1, 5, 15, 45, 90 }
local RESIZE_PRESETS = { 0.01, 0.1, 0.25, 0.5, 1, 4, 10 }
local SCALE_PRESETS = { 0.01, 0.05, 0.1, 0.25, 0.5, 1 }

local function currentScale()
	if uiScale and uiScale.Scale > 0 then
		return uiScale.Scale
	end
	return 1
end

local function formatNumber(value)
	local s = string.format("%.3f", value)
	s = s:gsub("0+$", "")
	s = s:gsub("%.$", "")
	return s
end

local function new(class, props, children)
	local inst = Instance.new(class)
	local parent = nil
	for k, v in props or {} do
		if k == "Parent" then
			parent = v
		else
			inst[k] = v
		end
	end
	for _, child in children or {} do
		child.Parent = inst
	end
	if parent then
		inst.Parent = parent
	end
	return inst
end

local function corner(r)
	return new("UICorner", { CornerRadius = UDim.new(0, r or 4) })
end

local function stroke(color, transparency, thickness)
	return new("UIStroke", { Color = color or THEME.Stroke, Transparency = transparency or 0, Thickness = thickness or 2, ApplyStrokeMode = Enum.ApplyStrokeMode.Border })
end

local function padding(px)
	local u = UDim.new(0, px)
	return new("UIPadding", { PaddingTop = u, PaddingBottom = u, PaddingLeft = u, PaddingRight = u })
end

local function list(direction, gap, hAlign)
	return new("UIListLayout", {
		FillDirection = direction or Enum.FillDirection.Vertical,
		Padding = UDim.new(0, gap or 4),
		SortOrder = Enum.SortOrder.LayoutOrder,
		HorizontalAlignment = hAlign or Enum.HorizontalAlignment.Left,
		VerticalAlignment = Enum.VerticalAlignment.Center,
	})
end

local SPRITE = {
	button = { "rbxassetid://128217385897821", Rect.new(12, 6, 156, 48) },
	buttonOn = { "rbxassetid://102211384096278", Rect.new(18, 12, 162, 54) },
	panel = { "rbxassetid://89677039349224", Rect.new(18, 18, 150, 126) },
}
UI.SPRITE = SPRITE
local SLICE_SCALE = 1 / 3
local DANGER_TINT = Color3.fromRGB(255, 120, 105)

local function slice(img, key)
	local s = SPRITE[key]
	img.Image = s[1]
	img.ScaleType = Enum.ScaleType.Slice
	img.SliceCenter = s[2]
	img.SliceScale = SLICE_SCALE
	img.ResampleMode = Enum.ResamplerMode.Pixelated
	img.BackgroundTransparency = 1
	img.BorderSizePixel = 0
	return img
end

local function panel(props)
	local frame = slice(new("ImageLabel", { Active = true }), "panel")
	for k, v in props do
		if k ~= "Parent" then
			frame[k] = v
		end
	end
	frame.Parent = props.Parent
	return frame
end

local function setTooltip(target, content)
	target.MouseEnter:Connect(function()
		tooltipText = content
	end)
	target.MouseLeave:Connect(function()
		if tooltipText == content then
			tooltipText = nil
		end
	end)
end

local SYNCED = { "Text", "TextColor3", "TextSize", "Font", "TextXAlignment", "TextTruncate", "TextWrapped", "TextScaled", "BackgroundColor3" }

local function dress(b)
	if b:GetAttribute("Dressed") then
		return b
	end
	b:SetAttribute("Dressed", true)
	for _, c in b:GetChildren() do
		if c:IsA("UICorner") or c:IsA("UIStroke") then
			c:Destroy()
		end
	end
	b.BackgroundTransparency = 1
	b.BorderSizePixel = 0
	b.AutoButtonColor = false
	local skinImg = b:FindFirstChild("Skin") or new("ImageLabel", { Name = "Skin", Size = UDim2.fromScale(1, 1), Parent = b })
	skinImg.ZIndex = b.ZIndex
	local label = b:FindFirstChild("Label") or new("TextLabel", { Name = "Label", BackgroundTransparency = 1, Position = UDim2.fromOffset(5, 0), Size = UDim2.new(1, -10, 1, 0), Parent = b })
	label.ZIndex = b.ZIndex + 1
	local hovered = false
	local function sync()
		local c = b.BackgroundColor3
		local primary = c == THEME.Accent or c == THEME.ButtonOn or c == THEME.Ok
		local danger = c == THEME.Danger
		slice(skinImg, (primary or hovered) and "buttonOn" or "button")
		skinImg.ImageColor3 = danger and DANGER_TINT or Color3.new(1, 1, 1)
		label.Text = b.Text
		label.TextColor3 = if b.TextColor3 == THEME.TextDark then THEME.Text else b.TextColor3
		label.TextSize = b.TextSize
		label.Font = b.Font
		label.TextXAlignment = b.TextXAlignment
		label.TextTruncate = b.TextTruncate
		label.TextWrapped = b.TextWrapped
		label.TextScaled = b.TextScaled
		b.TextTransparency = 1
	end
	for _, prop in SYNCED do
		b:GetPropertyChangedSignal(prop):Connect(sync)
	end
	b.MouseEnter:Connect(function()
		hovered = true
		sync()
	end)
	b.MouseLeave:Connect(function()
		hovered = false
		sync()
	end)
	sync()
	return b
end

local function button(label, props)
	local b = new("TextButton", {
		Text = label,
		Font = PIXEL_FONT,
		TextSize = 14,
		TextColor3 = THEME.Text,
		BackgroundColor3 = THEME.Button,
		Size = UDim2.fromOffset(60, 30),
	})
	for k, v in props or {} do
		if k == "Tooltip" then
			setTooltip(b, v)
		elseif k == "OnClick" then
			b.Activated:Connect(v)
		elseif k ~= "Parent" then
			b[k] = v
		end
	end
	dress(b)
	if props and props.Parent then
		b.Parent = props.Parent
	end
	return b
end

local function text(content, props)
	local l = new("TextLabel", {
		Text = content,
		Font = PIXEL_FONT,
		TextSize = 14,
		TextColor3 = THEME.Text,
		BackgroundTransparency = 1,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, 0, 0, 18),
	})
	for k, v in props or {} do
		if k ~= "Parent" then
			l[k] = v
		end
	end
	if props and props.Parent then
		l.Parent = props.Parent
	end
	return l
end

local function input(props)
	local box = new("TextBox", {
		Font = PIXEL_FONT,
		TextSize = 14,
		TextColor3 = THEME.Text,
		PlaceholderColor3 = THEME.Muted,
		BackgroundColor3 = THEME.Bg2,
		BorderSizePixel = 0,
		ClearTextOnFocus = false,
		Size = UDim2.new(1, 0, 0, 26),
		Text = "",
	}, { corner(2), stroke(THEME.Button, 0, 2), new("UIPadding", { PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 6) }) })
	for k, v in props or {} do
		if k ~= "Parent" then
			box[k] = v
		end
	end
	if props and props.Parent then
		box.Parent = props.Parent
	end
	return box
end

local function setOn(b, on)
	b.BackgroundColor3 = on and THEME.ButtonOn or THEME.Button
	b.TextColor3 = on and THEME.TextDark or THEME.Text
end

local templates

local function skin(b)
	local baseSize, basePos = b.Size, b.Position
	local normal = b.Image
	local hover = b:GetAttribute("Hover")
	local active = b:GetAttribute("Active")
	local hoverGrow = b:GetAttribute("HoverGrow") or 0
	local activeGrow = b:GetAttribute("ActiveGrow") or 0
	local state = { hovered = false, active = false }
	local function apply()
		local image, grow = normal, 0
		if state.active and active then
			image, grow = active, activeGrow
		elseif state.hovered and hover then
			image, grow = hover, hoverGrow
		end
		b.Image = image
		b.Size = baseSize + UDim2.fromOffset(grow * 2, grow * 2)
		local ap = b.AnchorPoint
		b.Position = basePos + UDim2.fromOffset(-grow * (1 - 2 * ap.X), -grow * (1 - 2 * ap.Y))
	end
	b.MouseEnter:Connect(function()
		state.hovered = true
		apply()
	end)
	b.MouseLeave:Connect(function()
		state.hovered = false
		apply()
	end)
	function state.set(on)
		state.active = on and true or false
		apply()
	end
	apply()
	return state
end

local function tabWidget(label, parent, order, onClick, tip)
	local holder = templates.Tab:Clone()
	holder.Name = label
	holder.Visible = true
	holder.LayoutOrder = order or 0
	holder.Label.Text = label
	local b = holder.Tab
	local look = skin(b)
	b.Activated:Connect(onClick)
	setTooltip(b, tip or label)
	holder.Parent = parent
	return holder, look
end

local function fitPreview(viewport, model)
	local lo, hi = Geometry.bounds({ model })
	if not lo then
		return
	end
	local center = (lo + hi) / 2
	local radius = math.max((hi - lo).Magnitude / 2, 0.5)
	local camera = new("Camera", { FieldOfView = 40, Parent = viewport })
	local dir = Vector3.new(1, 0.8, 1).Unit
	camera.CFrame = CFrame.lookAt(center + dir * radius * 2.6, center)
	viewport.CurrentCamera = camera
end

local function previewForRecords(viewport, records)
	local templates = Shared:FindFirstChild("Templates")
	if not templates then
		return
	end
	local model = Instance.new("Model")
	for _, rec in records do
		local inst = Factory.build(rec, templates, CFrame.identity, false)
		if inst then
			for _, d in inst:GetDescendants() do
				if d:IsA("BillboardGui") then
					d:Destroy()
				end
			end
			inst.Parent = model
		end
	end
	model.Parent = viewport
	fitPreview(viewport, model)
end

-- Toasts, modals, prompts ---------------------------------------------------

function UI.toast(message, kind)
	if not toastHolder then
		return
	end
	local color = THEME.Text
	if kind == "error" then
		color = THEME.Danger
	elseif kind == "warn" then
		color = THEME.Warn
	elseif kind == "ok" then
		color = THEME.Ok
	end
	local frame = slice(new("ImageLabel", {
		Name = "Toast",
		Size = UDim2.fromOffset(0, 30),
		AutomaticSize = Enum.AutomaticSize.X,
	}, { new("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10) }) }), kind == "ok" and "buttonOn" or "button")
	if kind == "error" then
		frame.ImageColor3 = DANGER_TINT
	end
	local label = text(message, { AutomaticSize = Enum.AutomaticSize.X, Size = UDim2.new(0, 0, 1, 0), TextColor3 = kind == "error" and THEME.Text or color, Parent = frame })
	frame.Parent = toastHolder
	task.delay(3.5, function()
		if frame.Parent then
			TweenService:Create(frame, TweenInfo.new(0.3), { ImageTransparency = 1 }):Play()
			TweenService:Create(label, TweenInfo.new(0.3), { TextTransparency = 1 }):Play()
			task.wait(0.3)
			frame:Destroy()
		end
	end)
	while #toastHolder:GetChildren() > 6 do
		for _, child in toastHolder:GetChildren() do
			if child:IsA("ImageLabel") then
				child:Destroy()
				break
			end
		end
	end
end

local function openModal(width, height, title)
	modalLayer:ClearAllChildren()
	modalLayer.Visible = true
	local box = panel({ Size = UDim2.fromOffset(width, height), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Parent = modalLayer })
	padding(12).Parent = box
	text(title, { Font = PIXEL_FONT, TextSize = 16, Size = UDim2.new(1, -40, 0, 22), Parent = box })
	button("X", { Size = UDim2.fromOffset(28, 24), Position = UDim2.new(1, -28, 0, 0), OnClick = function()
		UI.closeModal()
	end, Parent = box })
	local body = new("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 32), Size = UDim2.new(1, 0, 1, -32), Parent = box })
	return body
end

function UI.closeModal()
	if modalLayer then
		modalLayer.Visible = false
		modalLayer:ClearAllChildren()
	end
end

function UI.modalOpen()
	return modalLayer and modalLayer.Visible
end

function UI.confirm(message, yesText, onYes)
	local body = openModal(380, 160, "Confirm")
	text(message, { TextWrapped = true, Size = UDim2.new(1, 0, 0, 60), TextYAlignment = Enum.TextYAlignment.Top, Parent = body })
	button(yesText or "Yes", { Size = UDim2.fromOffset(120, 30), Position = UDim2.new(1, -250, 1, -30), BackgroundColor3 = THEME.Danger, OnClick = function()
		UI.closeModal()
		onYes()
	end, Parent = body })
	button("Cancel", { Size = UDim2.fromOffset(120, 30), Position = UDim2.new(1, -120, 1, -30), OnClick = function()
		UI.closeModal()
	end, Parent = body })
end

function UI.prompt(title, default, onSubmit)
	local body = openModal(380, 150, title)
	local box = input({ Text = default or "", PlaceholderText = "Name", Parent = body })
	local function submit()
		local value = box.Text
		UI.closeModal()
		onSubmit(value)
	end
	box.FocusLost:Connect(function(enter)
		if enter then
			submit()
		end
	end)
	button("OK", { Size = UDim2.fromOffset(120, 30), Position = UDim2.new(1, -250, 1, -30), BackgroundColor3 = THEME.Accent, TextColor3 = THEME.TextDark, OnClick = submit, Parent = body })
	button("Cancel", { Size = UDim2.fromOffset(120, 30), Position = UDim2.new(1, -120, 1, -30), OnClick = function()
		UI.closeModal()
	end, Parent = body })
	task.defer(function()
		box:CaptureFocus()
	end)
end

-- Settings -------------------------------------------------------------------

local function stepBlock(body, order, title, hint, presets, getValue, setValue)
	text(title, { Font = PIXEL_FONT, TextColor3 = THEME.Accent, LayoutOrder = order, Parent = body })

	local row = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 26), LayoutOrder = order + 1, Parent = body })
	local box = input({ Text = formatNumber(getValue()), Size = UDim2.new(0, 110, 1, 0), Parent = row })
	text(hint, { Position = UDim2.fromOffset(118, 0), Size = UDim2.new(1, -118, 1, 0), TextColor3 = THEME.Muted, TextSize = 12, Parent = row })

	local function commit(value)
		if setValue(value) then
			UI.refreshToolbar()
			UI.openSettings()
		else
			box.Text = formatNumber(getValue())
			UI.toast("Enter a number.", "warn")
		end
	end

	box.FocusLost:Connect(function()
		local parsed = tonumber(box.Text)
		if parsed and math.abs(parsed - getValue()) < 1e-9 then
			box.Text = formatNumber(getValue())
			return
		end
		commit(parsed)
	end)

	local presetRow = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 26), LayoutOrder = order + 2, Parent = body }, { list(Enum.FillDirection.Horizontal, 4) })
	local current = getValue()
	for i, preset in presets do
		local on = math.abs(preset - current) < 1e-9
		button(formatNumber(preset), {
			Size = UDim2.new(1 / #presets, -4, 1, 0),
			TextSize = 12,
			LayoutOrder = i,
			BackgroundColor3 = on and THEME.ButtonOn or THEME.Button,
			TextColor3 = on and THEME.TextDark or THEME.Text,
			OnClick = function()
				commit(preset)
			end,
			Parent = presetRow,
		})
	end
end

local function rangeHint(unit, limits)
	return string.format("%s  (%s - %s)", unit, formatNumber(limits.min), formatNumber(limits.max))
end

function UI.openSettings()
	local body = openModal(440, 480, "Settings")
	local layout = list(nil, 6)
	layout.VerticalAlignment = Enum.VerticalAlignment.Top
	layout.Parent = body

	stepBlock(body, 1, "Move step", rangeHint("studs", State.GRID_LIMITS), MOVE_PRESETS, function()
		return State.gridStep
	end, State.setGridStep)

	stepBlock(body, 10, "Rotation step", rangeHint("degrees", State.ROT_LIMITS), ROTATE_PRESETS, function()
		return State.rotDegrees
	end, State.setRotStep)

	stepBlock(body, 20, "Resize step", rangeHint("studs", State.RESIZE_LIMITS), RESIZE_PRESETS, function()
		return State.resizeStuds
	end, State.setResizeStep)

	stepBlock(body, 30, "Scale step", rangeHint("x", State.SCALE_LIMITS), SCALE_PRESETS, function()
		return State.scaleFactor
	end, State.setScaleStep)

	text("Move: placing and the Move tool. Resize: part sizes with the Scale tool. Scale: model size with the Scale tool, no upper limit. Snapping follows the grid toggle (G).", {
		TextWrapped = true,
		AutomaticSize = Enum.AutomaticSize.Y,
		TextColor3 = THEME.Muted,
		TextSize = 12,
		LayoutOrder = 40,
		Parent = body,
	})
end

-- Maps manager ---------------------------------------------------------------

function UI.showMaps(data)
	local maps = data.maps or {}
	local body = openModal(520, 470, string.format("My Maps (%d/%d)", #maps, data.max or Config.MAX_MAPS_PER_PLAYER))

	local newRow = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 30), Parent = body })
	local nameBox = input({ PlaceholderText = "New map name", Size = UDim2.new(1, -110, 1, 0), Parent = newRow })
	button("New Map", { Size = UDim2.fromOffset(100, 30), Position = UDim2.new(1, -100, 0, 0), BackgroundColor3 = THEME.Accent, TextColor3 = THEME.TextDark, OnClick = function()
		actions.newMap(nameBox.Text ~= "" and nameBox.Text or "Untitled Map")
	end, Parent = newRow })

	local scroll = new("ScrollingFrame", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, 40),
		Size = UDim2.new(1, 0, 1, data.developer and -120 or -44),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 6,
		BorderSizePixel = 0,
		Parent = body,
	}, { list(nil, 6) })

	if #maps == 0 then
		text("No saved maps yet. Build something and press Save.", { TextColor3 = THEME.Muted, Parent = scroll })
	end

	for i, entry in maps do
		local row = new("Frame", { BackgroundColor3 = THEME.Bg2, Size = UDim2.new(1, -8, 0, 52), LayoutOrder = i, Parent = scroll }, { corner(8), padding(8) })
		local current = entry.id == data.current
		text(entry.name .. (current and "  (open)" or ""), { Font = PIXEL_FONT, Size = UDim2.new(1, -250, 0, 18), TextTruncate = Enum.TextTruncate.AtEnd, Parent = row })
		text(string.format("%d objects  |  %s", entry.count, os.date("%d %b %Y %H:%M", entry.modified)), { TextColor3 = THEME.Muted, TextSize = 12, Position = UDim2.fromOffset(0, 18), Size = UDim2.new(1, -250, 0, 16), Parent = row })
		local holder = new("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.fromScale(1, 0.5), Size = UDim2.fromOffset(244, 28), Parent = row }, { list(Enum.FillDirection.Horizontal, 4, Enum.HorizontalAlignment.Right) })
		button("Load", { Size = UDim2.fromOffset(56, 28), LayoutOrder = 1, BackgroundColor3 = THEME.Accent, TextColor3 = THEME.TextDark, OnClick = function()
			actions.loadMap(entry.id)
		end, Parent = holder })
		button("Rename", { Size = UDim2.fromOffset(62, 28), LayoutOrder = 2, OnClick = function()
			UI.prompt("Rename map", entry.name, function(value)
				actions.renameMap(entry.id, value)
			end)
		end, Parent = holder })
		button("Copy", { Size = UDim2.fromOffset(52, 28), LayoutOrder = 3, OnClick = function()
			actions.duplicateMap(entry.id, entry.name .. " copy")
		end, Parent = holder })
		button("Delete", { Size = UDim2.fromOffset(58, 28), LayoutOrder = 4, BackgroundColor3 = THEME.Danger, OnClick = function()
			UI.confirm("Delete '" .. entry.name .. "' permanently?", "Delete", function()
				actions.deleteMap(entry.id)
			end)
		end, Parent = holder })
	end

	if data.developer then
		local dev = new("Frame", { BackgroundColor3 = THEME.Bg2, AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0, 70), Parent = body }, { corner(8), padding(8) })
		text("Developer: Peri map format", { Font = PIXEL_FONT, Parent = dev })
		local row = new("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 24), Size = UDim2.new(1, 0, 0, 28), Parent = dev }, { list(Enum.FillDirection.Horizontal, 6) })
		button("Import Peri folder...", { Size = UDim2.fromOffset(160, 28), LayoutOrder = 1, OnClick = function()
			actions.openImport()
		end, Parent = row })
		button("Export current to Peri format", { Size = UDim2.fromOffset(220, 28), LayoutOrder = 2, OnClick = function()
			actions.exportPeri()
		end, Parent = row })
	end
end

function UI.showImport(names)
	local body = openModal(360, 320, "Import from ServerStorage.MapEditorImports")
	local scroll = new("ScrollingFrame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), AutomaticCanvasSize = Enum.AutomaticSize.Y, CanvasSize = UDim2.new(), ScrollBarThickness = 6, BorderSizePixel = 0, Parent = body }, { list(nil, 6) })
	if #names == 0 then
		text("No folders found. Put Peri-format map folders in ServerStorage.MapEditorImports.", { TextWrapped = true, Size = UDim2.new(1, 0, 0, 40), TextColor3 = THEME.Muted, Parent = scroll })
	end
	for i, name in names do
		button(name, { Size = UDim2.new(1, -8, 0, 30), LayoutOrder = i, OnClick = function()
			actions.importPeri(name)
		end, Parent = scroll })
	end
end

-- Validation -----------------------------------------------------------------

function UI.showValidation(result)
	if not validationPanel then
		return
	end
	for _, child in validationList:GetChildren() do
		if not child:IsA("UIListLayout") then
			child:Destroy()
		end
	end
	if not result then
		validationPanel.Visible = false
		return
	end
	validationPanel.Visible = true
	local routeInfo = ""
	if result.routes and result.routes > 0 then
		routeInfo = string.format("  |  %d route(s), %s studs", result.routes, table.concat(result.lengths or {}, " / "))
	end
	validationHeader.Text = string.format("Validation: %d error(s), %d warning(s)%s", #result.errors, #result.warnings, routeInfo)
	validationHeader.TextColor3 = #result.errors > 0 and THEME.Danger or (#result.warnings > 0 and THEME.Warn or THEME.Ok)

	local order = 0
	local function row(issue, color, prefix)
		order += 1
		button(prefix .. issue.msg, {
			Size = UDim2.new(1, -8, 0, 26),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextColor3 = color,
			Font = PIXEL_FONT,
			LayoutOrder = order,
			TextTruncate = Enum.TextTruncate.AtEnd,
			OnClick = function()
				actions.focusIssue(issue)
			end,
			Parent = validationList,
		})
	end
	for _, issue in result.errors do
		row(issue, THEME.Danger, "Error: ")
	end
	for _, issue in result.warnings do
		row(issue, THEME.Warn, "Warning: ")
	end
	if #result.errors == 0 and #result.warnings == 0 then
		text("No problems found. The map is ready to test.", { TextColor3 = THEME.Ok, Parent = validationList })
	end
end

-- Catalog --------------------------------------------------------------------

local slotLooks = {}

local function catalogCell(name, order, onClick, buildPreview, favouriteId, onDelete, selected)
	local cell = templates.Slot:Clone()
	cell.Name = name
	cell.Visible = true
	cell.LayoutOrder = order
	cell.Label.Text = name
	local slot = cell.Slot
	local look = skin(slot)
	look.set(selected)
	if favouriteId ~= nil then
		slotLooks[favouriteId] = look
	end
	slot.Activated:Connect(onClick)
	local fav = cell.Favourite
	if favouriteId then
		local on = State.favourites[favouriteId] and true or false
		if on then
			fav.Image = fav:GetAttribute("On") or fav.Image
		end
		setTooltip(fav, on and "Remove from favourites" or "Add to favourites")
		fav.Activated:Connect(function()
			State.toggleFavourite(favouriteId)
		end)
	else
		fav.Visible = false
	end
	local del = cell.Delete
	if onDelete then
		del.Visible = true
		setTooltip(del, "Delete prefab")
		del.Activated:Connect(onDelete)
	else
		del.Visible = false
	end
	cell.Parent = itemsFrame
	task.defer(buildPreview, cell.Preview)
	return slot
end

local function emptyNote(message)
	local note = new("TextLabel", {
		Text = message,
		Font = PIXEL_FONT,
		TextScaled = true,
		TextWrapped = true,
		TextColor3 = THEME.Muted,
		BackgroundTransparency = 1,
		LayoutOrder = 0,
	}, { new("UITextSizeConstraint", { MaxTextSize = 8, MinTextSize = 4 }) })
	note.Parent = itemsFrame
	return note
end

function UI.refreshCatalog()
	if not itemsFrame then
		return
	end
	for _, child in itemsFrame:GetChildren() do
		if not child:IsA("UIGridLayout") and not child:IsA("UIPadding") then
			child:Destroy()
		end
	end
	table.clear(slotLooks)
	for name, look in tabSkins do
		look.set(name == currentCategory)
	end

	local query = string.lower(searchBox.Text)
	local order = 0
	local lastUsed = State.recent and State.recent[1]

	if currentCategory == "Prefabs" then
		for _, prefab in State.prefabs do
			if query ~= "" and not string.find(string.lower(prefab.name), query, 1, true) then
				continue
			end
			order += 1
			catalogCell(prefab.name, order, function()
				actions.selectPrefab(prefab)
			end, function(viewport)
				previewForRecords(viewport, prefab.objects)
			end, nil, function()
				UI.confirm("Delete prefab '" .. prefab.name .. "'?", "Delete", function()
					actions.deletePrefab(prefab.id)
				end)
			end, false)
		end
		if order == 0 then
			emptyNote("Select objects and use Save Prefab in the inspector.")
		end
		return
	end

	for _, def in Catalog.visible() do
		if currentCategory == "Favourites" then
			if not State.favourites[def.id] then
				continue
			end
		elseif currentCategory ~= "All" and def.category ~= currentCategory then
			continue
		end
		if query ~= "" and not string.find(string.lower(def.name), query, 1, true) and not string.find(string.lower(def.category), query, 1, true) then
			continue
		end
		order += 1
		local cell = catalogCell(def.name, order, function()
			actions.selectCatalog(def.id)
		end, function(viewport)
			local item = { id = "preview", t = def.id, p = { 0, 0, 0 }, r = { 0, 0, 0 } }
			if def.kind == "Part" and def.size then
				item.s = Serializer.vec(def.size)
			end
			previewForRecords(viewport, { item })
		end, def.id, nil, def.id == lastUsed)
		local tip = def.name
		if def.description ~= "" then
			tip ..= ": " .. def.description
		end
		setTooltip(cell, tip)
	end
	if order == 0 and currentCategory == "Favourites" then
		emptyNote("Click the + on an item to favourite it.")
	end
end

function UI.refreshRecent()
	if not recentRow then
		return
	end
	for _, child in recentRow:GetChildren() do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end
	for i, typeId in State.recent do
		local def = Catalog.get(typeId)
		if def then
			tabWidget(def.name, recentRow, i, function()
				actions.selectCatalog(typeId)
			end, def.name)
		end
	end
	local lastUsed = State.recent and State.recent[1]
	for typeId, look in slotLooks do
		look.set(typeId == lastUsed)
	end
end

function UI.setCategory(category)
	currentCategory = category
	UI.refreshCatalog()
end

-- Inspector ------------------------------------------------------------------

local function section(title, order)
	text(title, { Font = PIXEL_FONT, TextColor3 = THEME.Accent, LayoutOrder = order, Parent = inspectorScroll })
end

local function numberRow(order, label, fields, values, enabled)
	local row = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 26), LayoutOrder = order, Parent = inspectorScroll })
	text(label, { Size = UDim2.fromOffset(62, 26), TextColor3 = THEME.Muted, Parent = row })
	local width = 1 / #fields
	for i, field in fields do
		local value = values[i]
		local formatted = if typeof(value) == "number" then tostring(Serializer.round(value, 1000)) else ""
		local box = input({
			Text = formatted,
			Size = UDim2.new(width, -4, 1, 0),
			Position = UDim2.new(width * (i - 1), 0, 0, 0),
			TextEditable = enabled[i] ~= false,
			TextColor3 = enabled[i] ~= false and THEME.Text or THEME.Muted,
		})
		local holder = new("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(64, 0), Size = UDim2.new(1, -64, 1, 0), Parent = row })
		box.Parent = holder
		box.FocusLost:Connect(function()
			local parsed = tonumber(box.Text)
			if parsed == nil or parsed ~= parsed or math.abs(parsed) == math.huge then
				box.Text = formatted
				if box.Text ~= formatted then
					UI.toast("Enter a number.", "warn")
				end
				return
			end
			if tostring(parsed) ~= formatted then
				actions.setProperty(field, parsed)
			end
		end)
	end
end

local function actionRow(order, buttons)
	local row = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 28), LayoutOrder = order, Parent = inspectorScroll }, { list(Enum.FillDirection.Horizontal, 4) })
	for i, spec in buttons do
		button(spec[1], { Size = UDim2.new(1 / #buttons, -4, 1, 0), LayoutOrder = i, OnClick = spec[2], BackgroundColor3 = spec[3] or THEME.Button, Tooltip = spec[4], Parent = row })
	end
end

local function palette(order, current)
	local grid = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 52), LayoutOrder = order, Parent = inspectorScroll }, {
		new("UIGridLayout", { CellSize = UDim2.fromOffset(20, 20), CellPadding = UDim2.fromOffset(4, 4), SortOrder = Enum.SortOrder.LayoutOrder }),
	})
	for i, hex in Config.COLORS do
		local swatch = new("TextButton", { Text = "", BackgroundColor3 = Color3.fromHex(hex), LayoutOrder = i, AutoButtonColor = true, Parent = grid }, { corner(4) })
		if current and string.upper(current) == hex then
			stroke(THEME.Text, 0).Parent = swatch
		end
		swatch.Activated:Connect(function()
			actions.setProperty("c", hex)
		end)
	end
end

local function materialPicker(order, current)
	local holder = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 28), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = order, Parent = inspectorScroll }, { list(nil, 4) })
	local toggle = button("Material: " .. (current or "Default"), { Size = UDim2.new(1, 0, 0, 26), LayoutOrder = 1, Parent = holder })
	local options = new("ScrollingFrame", { Visible = false, BackgroundColor3 = THEME.Bg2, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 140), CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollBarThickness = 5, LayoutOrder = 2, Parent = holder }, { list(nil, 2), corner(6) })
	for i, name in Config.MATERIALS do
		button(name, { Size = UDim2.new(1, -6, 0, 22), TextSize = 12, LayoutOrder = i, BackgroundColor3 = name == current and THEME.ButtonOn or THEME.Button, TextColor3 = name == current and THEME.TextDark or THEME.Text, OnClick = function()
			actions.setProperty("m", name)
		end, Parent = options })
	end
	toggle.Activated:Connect(function()
		options.Visible = not options.Visible
	end)
end

local function spawnSection(order, id)
	section("Lane", order)
	local letter = RouteModel.spawnLane(State.record(id))
	local _, lane = RouteModel.laneFor(State.map.route, letter)
	local shared = RouteModel.waypointCount({ steps = State.map.route.steps })
	local info = string.format("Lane %s: %d Waypoint %s. Then %d shared Waypoint C, then the base.", letter, lane and #lane.ids or 0, letter, shared)
	text(info, { TextWrapped = true, AutomaticSize = Enum.AutomaticSize.Y, TextColor3 = THEME.Muted, TextSize = 12, LayoutOrder = order + 1, Parent = inspectorScroll })
	actionRow(order + 2, {
		{ "Build lane " .. letter, function()
			actions.routeAction("insertNext")
		end, nil, "Place Waypoint " .. letter .. "s starting right after this spawn" },
	})
end

local function routeSection(order, id)
	section("Route", order)
	local laneIndex, laneI = RouteModel.findLane(State.map.route, id)
	if laneIndex then
		local lane = State.map.route.lanes[laneIndex]
		local letter = lane.lane
		text(string.format("Lane %s, point %d", letter, laneI), { TextColor3 = THEME.Muted, LayoutOrder = order + 1, Parent = inspectorScroll })
		actionRow(order + 2, {
			{ "Insert next", function()
				actions.routeAction("insertNext")
			end, nil, "Place new waypoints right after this one" },
			{ "Unlink", function()
				actions.routeAction("unlink")
			end, nil, "Remove from the lane but keep the marker" },
		})
		return
	end
	local s, a, i = RouteModel.find(State.map.route, id)
	if s then
		local step = State.map.route.steps[s]
		local where = #step.alts > 1 and string.format("Fork %d, branch %d, point %d", s, a, i) or string.format("Step %d, point %d", s, i)
		text(where, { TextColor3 = THEME.Muted, LayoutOrder = order + 1, Parent = inspectorScroll })
		actionRow(order + 2, {
			{ "Insert next", function()
				actions.routeAction("insertNext")
			end, nil, "Place new waypoints right after this one" },
			{ "Add branch", function()
				actions.routeAction("addBranch")
			end, nil, "Create an alternative path for this section (a fork)" },
		})
		local row = {
			{ "Unlink", function()
				actions.routeAction("unlink")
			end, nil, "Remove from the route but keep the marker" },
		}
		if #step.alts > 1 then
			table.insert(row, { "Remove branch", function()
				actions.routeAction("removeBranch")
			end, THEME.Danger, "Delete this whole branch" })
		end
		actionRow(order + 3, row)
	else
		text("Not connected to the route.", { TextColor3 = THEME.Warn, LayoutOrder = order + 1, Parent = inspectorScroll })
		actionRow(order + 2, {
			{ "Link at end", function()
				actions.routeAction("link")
			end, nil, "Append to the end of the route" },
		})
	end
end

local function inspectorSignature()
	local parts = { State.mode, tostring(#State.selection) }
	for _, id in State.selection do
		local rec = State.map.objects[id]
		table.insert(parts, id)
		if rec then
			table.insert(parts, table.concat(rec.p, ",") .. "|" .. table.concat(rec.r, ",") .. "|" .. table.concat(rec.s or {}, ",") .. "|" .. tostring(rec.sc) .. tostring(rec.c) .. tostring(rec.m) .. tostring(rec.tr) .. tostring(rec.sh) .. tostring(rec.lk))
			local s, a, i = RouteModel.find(State.map.route, id)
			local l, li = RouteModel.findLane(State.map.route, id)
			local laneCounts = {}
			for _, lane in State.map.route.lanes or {} do
				table.insert(laneCounts, lane.lane .. #lane.ids)
			end
			table.insert(parts, tostring(s) .. tostring(a) .. tostring(i) .. tostring(l) .. tostring(li) .. table.concat(laneCounts) .. tostring(RouteModel.waypointCount({ steps = State.map.route.steps })))
		end
	end
	return table.concat(parts, ";")
end

function UI.refreshInspector(force)
	if not inspectorPanel then
		return
	end
	if #State.selection == 0 or State.mode ~= "Build" or not State.active then
		inspectorPanel.Visible = false
		inspectorKey = nil
		return
	end
	local key = inspectorSignature()
	if not force and key == inspectorKey then
		return
	end
	if not force and UserInputService:GetFocusedTextBox() and UserInputService:GetFocusedTextBox():IsDescendantOf(inspectorPanel) then
		return
	end
	inspectorKey = key
	inspectorPanel.Visible = true

	for _, child in inspectorScroll:GetChildren() do
		if not child:IsA("UIListLayout") and not child:IsA("UIPadding") then
			child:Destroy()
		end
	end

	if #State.selection > 1 then
		local anyColor, anyMaterial, anyLocked = false, false, false
		for _, id in State.selection do
			local def = State.def(id)
			local rec = State.record(id)
			if def and def.allowColor then
				anyColor = true
			end
			if def and def.allowMaterial then
				anyMaterial = true
			end
			if rec and rec.lk then
				anyLocked = true
			end
		end
		text(string.format("%d objects selected", #State.selection), { Font = PIXEL_FONT, TextSize = 15, LayoutOrder = 1, Parent = inspectorScroll })
		actionRow(2, { { "Duplicate", actions.duplicate, nil, "Ctrl+D" }, { "Copy", actions.copy, nil, "Ctrl+C" }, { "Delete", actions.delete, THEME.Danger, "Delete" } })
		actionRow(3, { { anyLocked and "Unlock all" or "Lock all", actions.toggleLock, nil, "L" }, { "Save Prefab", actions.savePrefab, nil, "Save the selection as a reusable prefab" } })
		if anyColor then
			section("Colour", 10)
			palette(11, nil)
		end
		if anyMaterial then
			materialPicker(12, nil)
		end
		return
	end

	local id = State.selection[1]
	local rec = State.record(id)
	local def = State.def(id)
	if not rec or not def then
		return
	end

	text(def.name, { Font = PIXEL_FONT, TextSize = 15, LayoutOrder = 1, Parent = inspectorScroll })
	text("id " .. id .. (rec.lk and "  |  LOCKED" or ""), { TextSize = 11, TextColor3 = rec.lk and THEME.Danger or THEME.Muted, LayoutOrder = 2, Parent = inspectorScroll })

	section("Transform", 10)
	local editable = not rec.lk
	numberRow(11, "Position", { "px", "py", "pz" }, rec.p, { editable, editable, editable })
	if def.rotatable then
		local full = editable and not def.yawOnly
		numberRow(12, "Rotation", { "rx", "ry", "rz" }, rec.r, { full, editable, full })
	end
	if def.kind == "Part" and def.resizable and rec.s then
		numberRow(13, "Size", { "sx", "sy", "sz" }, rec.s, { editable, editable, editable })
	end
	if def.scalable then
		numberRow(14, "Scale", { "sc" }, { rec.sc or 1 }, { editable })
	end

	if def.allowColor or def.allowMaterial or def.allowTransparency or def.allowShape then
		section("Appearance", 20)
		if def.allowColor then
			palette(21, rec.c)
		end
		if def.allowMaterial then
			materialPicker(22, rec.m)
		end
		if def.allowTransparency then
			numberRow(23, "Transp.", { "tr" }, { rec.tr or 0 }, { editable })
		end
		if def.allowShape then
			actionRow(24, { { "Shape: " .. (rec.sh or "Block"), function()
				actions.setProperty("sh", nil)
			end, nil, "Cycle shape" } })
		end
	end

	section("Gameplay", 30)
	local facts = {}
	if def.periFolder == "Path" and def.role ~= Catalog.ROLE.NoBuild then
		table.insert(facts, "Enemy path: towers can't be placed on it.")
	elseif def.role == Catalog.ROLE.NoBuild then
		table.insert(facts, "Blocks tower placement. Invisible in game.")
	elseif def.periFolder then
		table.insert(facts, def.towerPlaceable and "Towers can be placed on it." or "Not meant for towers.")
	end
	if def.blocksPath then
		table.insert(facts, "Blocks enemy routes (checked by Validate).")
	end
	if def.description ~= "" then
		table.insert(facts, def.description)
	end
	for i, fact in facts do
		text(fact, { TextWrapped = true, AutomaticSize = Enum.AutomaticSize.Y, TextColor3 = THEME.Muted, TextSize = 12, LayoutOrder = 30 + i, Parent = inspectorScroll })
	end

	if def.role == Catalog.ROLE.Waypoint then
		routeSection(40, id)
	elseif def.role == Catalog.ROLE.EnemySpawn then
		spawnSection(40, id)
	end

	section("Actions", 50)
	actionRow(51, { { "Duplicate", actions.duplicate, nil, "Ctrl+D" }, { "Copy", actions.copy, nil, "Ctrl+C" }, { "Delete", actions.delete, THEME.Danger, "Delete" } })
	actionRow(52, { { rec.lk and "Unlock" or "Lock", actions.toggleLock, nil, "L" }, { "Focus", actions.focusSelection, nil, "F" }, { "Prefab", actions.savePrefab, nil, "Save as prefab" } })
end

-- Toolbar / status -----------------------------------------------------------

function UI.refreshToolbar()
	if not topBar then
		return
	end
	for tool, look in toolButtons do
		look.set(State.tool == tool)
	end
	if gridLabel then
		gridLabel.Text = State.gridOn and formatNumber(State.gridSize()) or "OFF"
		gridLabel.TextColor3 = State.gridOn and THEME.Text or THEME.Muted
	end
	toggleButtons.snapY.set(State.snapY)
	toggleButtons.align.set(State.alignSurface)
end

function UI.refreshStatus()
	if not statusLabel then
		return
	end
	local name = State.map.name ~= "" and State.map.name or "Untitled Map"
	local dirty = State.dirty and "  *" or ""
	statusLabel.Text = string.format("%s%s  |  %d objects%s", name, dirty, State.objectCount(), State.memoryStorage and "  |  memory" or "")
end

function UI.setHint(message, color)
	if hintLabel then
		hintLabel.Text = message or ""
		hintLabel.Visible = message ~= nil and message ~= ""
		hintLabel.TextColor3 = color or THEME.Text
	end
end

function UI.setSelectionRect(a, b)
	if not selectionRect then
		return
	end
	if not a then
		selectionRect.Visible = false
		return
	end
	local inset = game:GetService("GuiService"):GetGuiInset()
	local s = currentScale()
	local x, y = math.min(a.X, b.X), math.min(a.Y, b.Y) - inset.Y
	selectionRect.Position = UDim2.fromOffset(x / s, y / s)
	selectionRect.Size = UDim2.fromOffset(math.abs(a.X - b.X) / s, math.abs(a.Y - b.Y) / s)
	selectionRect.Visible = true
end

function UI.setPlaytestStats(stats)
	if not testStats then
		return
	end
	if stats.state ~= "Running" then
		return
	end
	testStats.Text = string.format("Base %d/%d   Enemies %d   Killed %d   Leaked %d   Towers %d/%d   Routes %d",
		stats.baseHealth, stats.maxHealth, stats.alive, stats.killed, stats.leaked, stats.towers, stats.maxTowers, stats.routes)
end

function UI.setTowerMode(on)
	if towerButton then
		towerButton.Text = on and "Towers: ON" or "Towers: off"
		setOn(towerButton, on)
	end
end

function UI.setMode(mode)
	if not gui then
		return
	end
	local building = mode == "Build" and State.active
	topBar.Visible = building
	catalogPanel.Visible = building
	settingsHolder.Visible = building
	testBar.Visible = mode == "Playtest" and State.active
	if not building then
		inspectorPanel.Visible = false
		validationPanel.Visible = false
	end
	UI.refreshInspector(true)
end

function UI.setActive(active)
	if not gui then
		return
	end
	launcher.Visible = not active
	if not active then
		topBar.Visible = false
		testBar.Visible = false
		catalogPanel.Visible = false
		inspectorPanel.Visible = false
		validationPanel.Visible = false
		helpPanel.Visible = false
		settingsHolder.Visible = false
		UI.closeModal()
		UI.setHint(nil)
	else
		UI.setMode(State.mode)
	end
end

function UI.toggleHelp()
	helpPanel.Visible = not helpPanel.Visible
end

function UI.update()
	if tooltip then
		if tooltipText then
			local mouse = UserInputService:GetMouseLocation()
			local inset = game:GetService("GuiService"):GetGuiInset()
			local s = currentScale()
			tooltip.Text = if typeof(tooltipText) == "function" then tooltipText() else tooltipText
			tooltip.Position = UDim2.fromOffset((mouse.X + 14) / s, (mouse.Y - inset.Y + 18) / s)
			tooltip.Visible = true
		else
			tooltip.Visible = false
		end
	end
end

-- Construction ---------------------------------------------------------------

local DYNAMIC_TIPS = {
	RotStep = function()
		return "Rotation step: " .. formatNumber(State.rotStep()) .. " (click to change, exact values in Settings)"
	end,
	Grid = function()
		return State.gridOn and ("Move step " .. formatNumber(State.gridSize()) .. " studs (G or click to turn off)") or "Grid off (G or click to turn on)"
	end,
}

local function bindToolbar()
	for _, b in topBar:GetChildren() do
		if not b:IsA("ImageButton") then
			continue
		end
		local look = skin(b)
		local tool = b:GetAttribute("Tool")
		local action = b:GetAttribute("Action")
		local toggle = b:GetAttribute("Toggle")
		if tool then
			toolButtons[tool] = look
			b.Activated:Connect(function()
				actions.setTool(tool)
			end)
		elseif action == "cycleGrid" then
			local arg = b:GetAttribute("Arg") or 1
			b.Activated:Connect(function()
				State.stepGrid(arg)
				UI.refreshToolbar()
			end)
		elseif action == "cycleRot" then
			b.Activated:Connect(function()
				State.stepRot()
				UI.refreshToolbar()
				UI.toast("Rotation step: " .. formatNumber(State.rotStep()) .. " degrees", "info")
			end)
		elseif action then
			local arg = b:GetAttribute("Arg")
			b.Activated:Connect(function()
				local fn = actions[action]
				if not fn then
					warn("[MapEditor UI] no action named " .. action)
					return
				end
				if arg ~= nil then
					fn(arg)
				else
					fn()
				end
			end)
		end
		if toggle then
			toggleButtons[toggle] = look
		end
	end
	gridLabel.Activated:Connect(function()
		actions.toggleGrid()
	end)
end

local function bindCatalog()
	searchBox:GetPropertyChangedSignal("Text"):Connect(function()
		UI.refreshCatalog()
	end)
	local wanted = { "All", "Favourites" }
	for _, c in Catalog.CATEGORIES do
		table.insert(wanted, c)
	end
	for i, c in wanted do
		local holder = categoryHolder:FindFirstChild(c)
		local look
		local function choose()
			if c == "Prefabs" then
				actions.loadPrefabs()
			end
			UI.setCategory(c)
		end
		if holder and holder:FindFirstChild("Tab") then
			look = skin(holder.Tab)
			holder.Tab.Activated:Connect(choose)
		else
			holder, look = tabWidget(c, categoryHolder, i, choose, c)
		end
		tabSkins[c] = look
	end
end

function UI.init(handlers)
	actions = handlers
	local playerGui = player:WaitForChild("PlayerGui")
	gui = playerGui:WaitForChild("MapEditorUI")
	templates = gui:WaitForChild("Templates")

	local scale = gui:FindFirstChildOfClass("UIScale") or new("UIScale", { Parent = gui })
	uiScale = scale
	local function rescale()
		local viewport = workspace.CurrentCamera.ViewportSize
		scale.Scale = math.clamp(math.min(viewport.X / 1000, viewport.Y / 600), 0.6, 1.6)
	end
	workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(rescale)
	rescale()

	launcher = gui:WaitForChild("Launcher")
	topBar = gui:WaitForChild("TopBar")
	testBar = gui:WaitForChild("TestBar")
	catalogPanel = gui:WaitForChild("Catalog")
	inspectorPanel = gui:WaitForChild("Inspector")
	inspectorScroll = inspectorPanel:WaitForChild("Scroll")
	validationPanel = gui:WaitForChild("Validation")
	validationHeader = validationPanel:WaitForChild("Header")
	validationList = validationPanel:WaitForChild("List")
	toastHolder = gui:WaitForChild("Toasts")
	hintLabel = gui:WaitForChild("Hint")
	selectionRect = gui:WaitForChild("SelectionRect")
	helpPanel = gui:WaitForChild("Help")
	modalLayer = gui:WaitForChild("Modal")
	tooltip = gui:WaitForChild("Tooltip")
	settingsHolder = gui:WaitForChild("Settings")
	statusLabel = catalogPanel:WaitForChild("Status")
	searchBox = catalogPanel:WaitForChild("Search")
	categoryHolder = catalogPanel:WaitForChild("Categories")
	recentRow = catalogPanel:WaitForChild("Recent")
	itemsFrame = catalogPanel:WaitForChild("Items")
	gridLabel = topBar:WaitForChild("Grid")
	testStats = testBar:WaitForChild("Stats")
	towerButton = testBar:WaitForChild("Towers")

	for name, fn in DYNAMIC_TIPS do
		local target = topBar:FindFirstChild(name)
		if target then
			setTooltip(target, fn)
		end
	end
	for _, d in gui:GetDescendants() do
		if d:IsA("GuiObject") and not d:IsDescendantOf(templates) and not DYNAMIC_TIPS[d.Name] then
			local tip = d:GetAttribute("Tooltip")
			if tip then
				setTooltip(d, tip)
			end
		end
	end

	launcher.Activated:Connect(function()
		actions.enter()
	end)
	bindToolbar()
	bindCatalog()

	settingsHolder:WaitForChild("Open").Activated:Connect(function()
		UI.openSettings()
	end)
	testBar:WaitForChild("StopTest").Activated:Connect(function()
		actions.stopTest()
	end)
	testBar:WaitForChild("SpawnWave").Activated:Connect(function()
		actions.spawnWave()
	end)
	towerButton.Activated:Connect(function()
		actions.toggleTowerMode()
	end)
	validationPanel:WaitForChild("Close").Activated:Connect(function()
		validationPanel.Visible = false
	end)
	for _, d in gui:GetDescendants() do
		if d:IsA("TextButton") and d ~= gridLabel and not d:IsDescendantOf(templates) then
			dress(d)
		end
	end

	launcher.Visible = true
	for _, hidden in { topBar, testBar, catalogPanel, inspectorPanel, validationPanel, helpPanel, modalLayer, tooltip, hintLabel, selectionRect, settingsHolder } do
		hidden.Visible = false
	end

	UI.refreshToolbar()
	UI.refreshRecent()
	UI.refreshCatalog()
	UI.refreshStatus()
end

function UI.isOverGui(position)
	if not gui then
		return false
	end
	local inset = game:GetService("GuiService"):GetGuiInset()
	local objects = player.PlayerGui:GetGuiObjectsAtPosition(position.X, position.Y - inset.Y)
	for _, obj in objects do
		if obj:IsDescendantOf(gui) and obj.Visible and (obj:IsA("GuiButton") or obj:IsA("TextBox") or ((obj:IsA("Frame") or obj:IsA("ImageLabel")) and obj.Active) or obj:IsA("ScrollingFrame")) then
			return true
		end
	end
	return false
end

return UI