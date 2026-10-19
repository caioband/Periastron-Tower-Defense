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
	Bg = Color3.fromHex("161A1F"),
	Bg2 = Color3.fromHex("20262D"),
	Button = Color3.fromHex("2A313A"),
	ButtonOn = Color3.fromHex("34C6E6"),
	Stroke = Color3.fromHex("3A434E"),
	Text = Color3.fromHex("F2F5F7"),
	TextDark = Color3.fromHex("0F1215"),
	Muted = Color3.fromHex("9AA5B1"),
	Accent = Color3.fromHex("34C6E6"),
	Danger = Color3.fromHex("E5484D"),
	Warn = Color3.fromHex("F5A524"),
	Ok = Color3.fromHex("46C267"),
}
UI.THEME = THEME

local actions = nil
local gui, launcher, topBar, testBar, catalogPanel, inspectorPanel, inspectorScroll
local validationPanel, validationList, validationHeader, toastHolder, modalLayer, helpPanel
local tooltip, statusLabel, hintLabel, testStats, towerButton, selectionRect
local itemsFrame, searchBox, categoryHolder, recentRow
local toolButtons = {}
local toggleButtons = {}
local currentCategory = "All"
local tooltipText = nil
local inspectorKey = nil

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
	return new("UICorner", { CornerRadius = UDim.new(0, r or 8) })
end

local function stroke(color, transparency)
	return new("UIStroke", { Color = color or THEME.Stroke, Transparency = transparency or 0.3, ApplyStrokeMode = Enum.ApplyStrokeMode.Border })
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

local function panel(props)
	local frame = new("Frame", {
		BackgroundColor3 = THEME.Bg,
		BackgroundTransparency = 0.08,
		BorderSizePixel = 0,
		Active = true,
	}, { corner(10), stroke() })
	for k, v in props do
		if k ~= "Parent" then
			frame[k] = v
		end
	end
	frame.Parent = props.Parent
	return frame
end

local function setTooltip(target, text)
	target.MouseEnter:Connect(function()
		tooltipText = text
	end)
	target.MouseLeave:Connect(function()
		if tooltipText == text then
			tooltipText = nil
		end
	end)
end

local function button(text, props)
	local b = new("TextButton", {
		Text = text,
		Font = Enum.Font.GothamMedium,
		TextSize = 13,
		TextColor3 = THEME.Text,
		BackgroundColor3 = THEME.Button,
		BorderSizePixel = 0,
		AutoButtonColor = true,
		Size = UDim2.fromOffset(60, 30),
	}, { corner(6) })
	for k, v in props or {} do
		if k == "Tooltip" then
			setTooltip(b, v)
		elseif k == "OnClick" then
			b.Activated:Connect(v)
		elseif k ~= "Parent" then
			b[k] = v
		end
	end
	if props and props.Parent then
		b.Parent = props.Parent
	end
	return b
end

local function text(content, props)
	local l = new("TextLabel", {
		Text = content,
		Font = Enum.Font.Gotham,
		TextSize = 13,
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
		Font = Enum.Font.Gotham,
		TextSize = 13,
		TextColor3 = THEME.Text,
		PlaceholderColor3 = THEME.Muted,
		BackgroundColor3 = THEME.Bg2,
		BorderSizePixel = 0,
		ClearTextOnFocus = false,
		Size = UDim2.new(1, 0, 0, 26),
		Text = "",
	}, { corner(6), new("UIPadding", { PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 6) }) })
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

local function separator(parent, order)
	new("Frame", { Size = UDim2.fromOffset(1, 24), BackgroundColor3 = THEME.Stroke, BorderSizePixel = 0, LayoutOrder = order, Parent = parent })
end

local function setOn(b, on)
	b.BackgroundColor3 = on and THEME.ButtonOn or THEME.Button
	b.TextColor3 = on and THEME.TextDark or THEME.Text
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
	local color = THEME.Accent
	if kind == "error" then
		color = THEME.Danger
	elseif kind == "warn" then
		color = THEME.Warn
	elseif kind == "ok" then
		color = THEME.Ok
	end
	local frame = new("Frame", {
		BackgroundColor3 = THEME.Bg,
		BackgroundTransparency = 0.05,
		Size = UDim2.fromOffset(0, 32),
		AutomaticSize = Enum.AutomaticSize.X,
		Parent = toastHolder,
	}, { corner(8), stroke(color, 0), padding(8) })
	text(message, { AutomaticSize = Enum.AutomaticSize.X, Size = UDim2.fromOffset(0, 16), TextColor3 = THEME.Text, Parent = frame })
	task.delay(3.5, function()
		if frame.Parent then
			TweenService:Create(frame, TweenInfo.new(0.3), { BackgroundTransparency = 1 }):Play()
			task.wait(0.3)
			frame:Destroy()
		end
	end)
	while #toastHolder:GetChildren() > 6 do
		for _, child in toastHolder:GetChildren() do
			if child:IsA("Frame") then
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
	text(title, { Font = Enum.Font.GothamBold, TextSize = 16, Size = UDim2.new(1, -40, 0, 22), Parent = box })
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
		text(entry.name .. (current and "  (open)" or ""), { Font = Enum.Font.GothamBold, Size = UDim2.new(1, -250, 0, 18), TextTruncate = Enum.TextTruncate.AtEnd, Parent = row })
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
		text("Developer: Peri map format", { Font = Enum.Font.GothamBold, Parent = dev })
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
		local b = button(prefix .. issue.msg, {
			Size = UDim2.new(1, -8, 0, 26),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextColor3 = color,
			Font = Enum.Font.Gotham,
			LayoutOrder = order,
			TextTruncate = Enum.TextTruncate.AtEnd,
			OnClick = function()
				actions.focusIssue(issue)
			end,
			Parent = validationList,
		})
		new("UIPadding", { PaddingLeft = UDim.new(0, 8), Parent = b })
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

local function catalogCell(name, order, onClick, buildPreview, favouriteId, onDelete)
	local cell = new("TextButton", {
		Text = "",
		AutoButtonColor = true,
		BackgroundColor3 = THEME.Bg2,
		BorderSizePixel = 0,
		LayoutOrder = order,
		Parent = itemsFrame,
	}, { corner(8) })
	local viewport = new("ViewportFrame", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -8, 0, 54),
		Position = UDim2.fromOffset(4, 4),
		Ambient = Color3.fromRGB(170, 170, 170),
		LightColor = Color3.new(1, 1, 1),
		Parent = cell,
	})
	text(name, { TextSize = 11, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Center, Position = UDim2.new(0, 2, 0, 58), Size = UDim2.new(1, -4, 0, 26), Parent = cell })
	cell.Activated:Connect(onClick)
	if favouriteId then
		local star = button(State.favourites[favouriteId] and "*" or "+", {
			Size = UDim2.fromOffset(18, 18),
			Position = UDim2.new(1, -20, 0, 2),
			TextSize = 14,
			BackgroundTransparency = 0.4,
			TextColor3 = State.favourites[favouriteId] and THEME.Warn or THEME.Muted,
			Tooltip = "Favourite",
			Parent = cell,
		})
		star.Activated:Connect(function()
			State.toggleFavourite(favouriteId)
		end)
	end
	if onDelete then
		button("x", { Size = UDim2.fromOffset(18, 18), Position = UDim2.new(1, -20, 0, 2), TextSize = 12, BackgroundColor3 = THEME.Danger, Tooltip = "Delete prefab", OnClick = onDelete, Parent = cell })
	end
	task.defer(buildPreview, viewport)
	return cell
end

function UI.refreshCatalog()
	if not itemsFrame then
		return
	end
	for _, child in itemsFrame:GetChildren() do
		if not child:IsA("UIGridLayout") then
			child:Destroy()
		end
	end
	for name, b in categoryHolder:GetChildren() do
		if b:IsA("TextButton") then
			setOn(b, b.Name == currentCategory)
		end
	end

	local query = string.lower(searchBox.Text)
	local order = 0

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
			end)
		end
		if order == 0 then
			text("Select objects and use 'Save Prefab' in the inspector.", { TextWrapped = true, TextColor3 = THEME.Muted, Size = UDim2.new(1, 0, 0, 40), Parent = itemsFrame })
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
		end, def.id)
		local tip = def.name
		if def.description ~= "" then
			tip ..= ": " .. def.description
		end
		setTooltip(cell, tip)
	end
end

function UI.refreshRecent()
	if not recentRow then
		return
	end
	for _, child in recentRow:GetChildren() do
		if child:IsA("TextButton") then
			child:Destroy()
		end
	end
	for i, typeId in State.recent do
		local def = Catalog.get(typeId)
		if def then
			button(def.name, { AutomaticSize = Enum.AutomaticSize.X, Size = UDim2.fromOffset(0, 22), TextSize = 11, LayoutOrder = i, OnClick = function()
				actions.selectCatalog(typeId)
			end, Parent = recentRow }, nil)
		end
	end
end

function UI.setCategory(category)
	currentCategory = category
	UI.refreshCatalog()
end

-- Inspector ------------------------------------------------------------------

local function section(title, order)
	text(title, { Font = Enum.Font.GothamBold, TextColor3 = THEME.Accent, LayoutOrder = order, Parent = inspectorScroll })
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
		text(string.format("%d objects selected", #State.selection), { Font = Enum.Font.GothamBold, TextSize = 15, LayoutOrder = 1, Parent = inspectorScroll })
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

	text(def.name, { Font = Enum.Font.GothamBold, TextSize = 15, LayoutOrder = 1, Parent = inspectorScroll })
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
	for tool, b in toolButtons do
		setOn(b, State.tool == tool)
	end
	local grid = toggleButtons.grid
	grid.Text = State.gridOn and ("Grid " .. State.gridSize()) or "Grid off"
	setOn(grid, State.gridOn)
	toggleButtons.rot.Text = "Rot " .. State.rotStep() .. ""
	setOn(toggleButtons.snapY, State.snapY)
	setOn(toggleButtons.align, State.alignSurface)
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
	local x, y = math.min(a.X, b.X), math.min(a.Y, b.Y) - inset.Y
	selectionRect.Position = UDim2.fromOffset(x, y)
	selectionRect.Size = UDim2.fromOffset(math.abs(a.X - b.X), math.abs(a.Y - b.Y))
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
			tooltip.Text = tooltipText
			tooltip.Position = UDim2.fromOffset(mouse.X + 14, mouse.Y - inset.Y + 18)
			tooltip.Visible = true
		else
			tooltip.Visible = false
		end
	end
end

-- Construction ---------------------------------------------------------------

local HELP = {
	"Camera: W A S D move, Space / C up and down, hold Right Mouse to look, Shift = faster, wheel = zoom",
	"Left click: place the chosen object, or select. Shift + click adds to the selection. Drag on empty space to box select",
	"Esc or right click: cancel placement / clear selection",
	"Q / E rotate, Shift + Q / E tilt. G toggles grid snapping",
	"1 Select   2 Move   3 Rotate   4 Scale  (drag the handles)",
	"Ctrl+Z undo, Ctrl+Y redo, Ctrl+D duplicate, Ctrl+C / Ctrl+V copy and paste, Delete removes",
	"L lock / unlock, F focus the selection, Ctrl+S save, H this help",
	"Routes: place an Enemy Spawn and a Base, then Waypoints in order. Select a waypoint to insert after it or add a fork branch",
	"Test runs your map with the real Peri route and tower rules; Validate lists what would break",
}

function UI.init(handlers)
	actions = handlers
	local playerGui = player:WaitForChild("PlayerGui")
	local existing = playerGui:FindFirstChild("MapEditorUI")
	if existing then
		existing:Destroy()
	end

	gui = new("ScreenGui", { Name = "MapEditorUI", ResetOnSpawn = false, IgnoreGuiInset = false, ZIndexBehavior = Enum.ZIndexBehavior.Sibling, DisplayOrder = 10, Parent = playerGui })

	local scale = new("UIScale", { Parent = gui })
	local function rescale()
		local viewport = workspace.CurrentCamera.ViewportSize
		scale.Scale = math.clamp(math.min(viewport.X / 1180, viewport.Y / 720), 0.65, 1)
	end
	workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(rescale)
	rescale()

	launcher = button("MAP EDITOR", { Size = UDim2.fromOffset(140, 40), AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -12), Font = Enum.Font.GothamBold, TextSize = 15, BackgroundColor3 = THEME.Accent, TextColor3 = THEME.TextDark, Tooltip = "Open the map editor", OnClick = function()
		actions.enter()
	end, Parent = gui })

	topBar = panel({ Name = "TopBar", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 6), Size = UDim2.fromOffset(0, 42), AutomaticSize = Enum.AutomaticSize.X, Visible = false, Parent = gui })
	padding(5).Parent = topBar
	list(Enum.FillDirection.Horizontal, 4).Parent = topBar
	local order = 0
	local function nextOrder()
		order += 1
		return order
	end

	button("Test", { Size = UDim2.fromOffset(50, 32), BackgroundColor3 = THEME.Ok, TextColor3 = THEME.TextDark, Font = Enum.Font.GothamBold, LayoutOrder = nextOrder(), Tooltip = "Playtest this map", OnClick = function()
		actions.startTest()
	end, Parent = topBar })
	separator(topBar, nextOrder())
	for i, tool in { "Select", "Move", "Rotate", "Scale" } do
		toolButtons[tool] = button(tool, { Size = UDim2.fromOffset(52, 32), LayoutOrder = nextOrder(), Tooltip = string.format("%s tool (%d)", tool, i), OnClick = function()
			actions.setTool(tool)
		end, Parent = topBar })
	end
	separator(topBar, nextOrder())
	button("Undo", { Size = UDim2.fromOffset(44, 32), LayoutOrder = nextOrder(), Tooltip = "Undo (Ctrl+Z)", OnClick = function()
		actions.undo()
	end, Parent = topBar })
	button("Redo", { Size = UDim2.fromOffset(44, 32), LayoutOrder = nextOrder(), Tooltip = "Redo (Ctrl+Y)", OnClick = function()
		actions.redo()
	end, Parent = topBar })
	separator(topBar, nextOrder())
	button("-", { Size = UDim2.fromOffset(20, 32), LayoutOrder = nextOrder(), Tooltip = "Smaller grid", OnClick = function()
		actions.cycleGrid(-1)
	end, Parent = topBar })
	toggleButtons.grid = button("Grid", { Size = UDim2.fromOffset(60, 32), LayoutOrder = nextOrder(), Tooltip = "Grid snapping (G)", OnClick = function()
		actions.toggleGrid()
	end, Parent = topBar })
	button("+", { Size = UDim2.fromOffset(20, 32), LayoutOrder = nextOrder(), Tooltip = "Larger grid", OnClick = function()
		actions.cycleGrid(1)
	end, Parent = topBar })
	toggleButtons.rot = button("Rot", { Size = UDim2.fromOffset(52, 32), LayoutOrder = nextOrder(), Tooltip = "Rotation step", OnClick = function()
		actions.cycleRot()
	end, Parent = topBar })
	toggleButtons.snapY = button("Snap Y", { Size = UDim2.fromOffset(52, 32), LayoutOrder = nextOrder(), Tooltip = "Snap height to the grid", OnClick = function()
		actions.toggleSnapY()
	end, Parent = topBar })
	toggleButtons.align = button("Align", { Size = UDim2.fromOffset(46, 32), LayoutOrder = nextOrder(), Tooltip = "Align new objects to the surface", OnClick = function()
		actions.toggleAlign()
	end, Parent = topBar })
	separator(topBar, nextOrder())
	button("Validate", { Size = UDim2.fromOffset(60, 32), LayoutOrder = nextOrder(), Tooltip = "Check the map for problems", OnClick = function()
		actions.validate()
	end, Parent = topBar })
	button("Maps", { Size = UDim2.fromOffset(46, 32), LayoutOrder = nextOrder(), Tooltip = "New, load, rename, copy, delete", OnClick = function()
		actions.openMaps()
	end, Parent = topBar })
	button("Save", { Size = UDim2.fromOffset(46, 32), LayoutOrder = nextOrder(), BackgroundColor3 = THEME.Accent, TextColor3 = THEME.TextDark, Tooltip = "Save (Ctrl+S)", OnClick = function()
		actions.save()
	end, Parent = topBar })
	button("?", { Size = UDim2.fromOffset(24, 32), LayoutOrder = nextOrder(), Tooltip = "Controls (H)", OnClick = function()
		UI.toggleHelp()
	end, Parent = topBar })
	button("Exit", { Size = UDim2.fromOffset(40, 32), LayoutOrder = nextOrder(), BackgroundColor3 = THEME.Danger, Tooltip = "Leave the editor", OnClick = function()
		actions.exit()
	end, Parent = topBar })

	testBar = panel({ Name = "TestBar", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 6), Size = UDim2.fromOffset(0, 42), AutomaticSize = Enum.AutomaticSize.X, Visible = false, Parent = gui })
	padding(5).Parent = testBar
	list(Enum.FillDirection.Horizontal, 6).Parent = testBar
	button("Stop Test", { Size = UDim2.fromOffset(84, 32), BackgroundColor3 = THEME.Danger, Font = Enum.Font.GothamBold, LayoutOrder = 1, OnClick = function()
		actions.stopTest()
	end, Parent = testBar })
	button("Spawn Wave", { Size = UDim2.fromOffset(92, 32), LayoutOrder = 2, Tooltip = "Send a test wave along every route", OnClick = function()
		actions.spawnWave()
	end, Parent = testBar })
	towerButton = button("Towers: off", { Size = UDim2.fromOffset(96, 32), LayoutOrder = 3, Tooltip = "Click the map to place test towers (Peri placement rules)", OnClick = function()
		actions.toggleTowerMode()
	end, Parent = testBar })
	testStats = text("", { Size = UDim2.fromOffset(470, 32), TextSize = 12, LayoutOrder = 4, Parent = testBar })

	catalogPanel = panel({ Name = "Catalog", Position = UDim2.fromOffset(8, 56), Size = UDim2.new(0, 252, 1, -64), Visible = false, Parent = gui })
	padding(8).Parent = catalogPanel
	statusLabel = text("", { Font = Enum.Font.GothamBold, TextSize = 13, Size = UDim2.new(1, 0, 0, 20), TextTruncate = Enum.TextTruncate.AtEnd, Parent = catalogPanel })
	searchBox = input({ PlaceholderText = "Search objects...", Position = UDim2.fromOffset(0, 24), Parent = catalogPanel })
	searchBox:GetPropertyChangedSignal("Text"):Connect(function()
		UI.refreshCatalog()
	end)
	categoryHolder = new("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 56), Size = UDim2.new(1, 0, 0, 100), Parent = catalogPanel }, {
		new("UIGridLayout", { CellSize = UDim2.new(0.333, -4, 0, 22), CellPadding = UDim2.fromOffset(4, 4), SortOrder = Enum.SortOrder.LayoutOrder }),
	})
	local categories = { "All", "Favourites" }
	for _, c in Catalog.CATEGORIES do
		table.insert(categories, c)
	end
	for i, c in categories do
		button(c, { Name = c, TextSize = 11, LayoutOrder = i, TextTruncate = Enum.TextTruncate.AtEnd, OnClick = function()
			if c == "Prefabs" then
				actions.loadPrefabs()
			end
			UI.setCategory(c)
		end, Parent = categoryHolder })
	end
	text("Recent", { TextColor3 = THEME.Muted, TextSize = 11, Position = UDim2.fromOffset(0, 160), Size = UDim2.new(1, 0, 0, 14), Parent = catalogPanel })
	recentRow = new("ScrollingFrame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 176), Size = UDim2.new(1, 0, 0, 28), CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.X, ScrollBarThickness = 3, ScrollingDirection = Enum.ScrollingDirection.X, BorderSizePixel = 0, Parent = catalogPanel }, { list(Enum.FillDirection.Horizontal, 4) })
	itemsFrame = new("ScrollingFrame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 210), Size = UDim2.new(1, 0, 1, -210), CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollBarThickness = 5, BorderSizePixel = 0, Parent = catalogPanel }, {
		new("UIGridLayout", { CellSize = UDim2.fromOffset(74, 88), CellPadding = UDim2.fromOffset(4, 4), SortOrder = Enum.SortOrder.LayoutOrder }),
	})

	inspectorPanel = panel({ Name = "Inspector", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -8, 0, 56), Size = UDim2.new(0, 262, 1, -64), Visible = false, Parent = gui })
	inspectorScroll = new("ScrollingFrame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollBarThickness = 5, BorderSizePixel = 0, Parent = inspectorPanel }, { list(nil, 6), padding(10) })

	validationPanel = panel({ Name = "Validation", AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -10), Size = UDim2.fromOffset(560, 170), Visible = false, Parent = gui })
	padding(8).Parent = validationPanel
	validationHeader = text("Validation", { Font = Enum.Font.GothamBold, Size = UDim2.new(1, -36, 0, 20), Parent = validationPanel })
	button("X", { Size = UDim2.fromOffset(28, 22), Position = UDim2.new(1, -28, 0, 0), OnClick = function()
		validationPanel.Visible = false
	end, Parent = validationPanel })
	validationList = new("ScrollingFrame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 26), Size = UDim2.new(1, 0, 1, -26), CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollBarThickness = 5, BorderSizePixel = 0, Parent = validationPanel }, { list(nil, 4) })

	toastHolder = new("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 56), Size = UDim2.fromOffset(600, 240), Parent = gui }, { list(nil, 6, Enum.HorizontalAlignment.Center) })
	local holderLayout = toastHolder:FindFirstChildOfClass("UIListLayout")
	holderLayout.VerticalAlignment = Enum.VerticalAlignment.Top

	hintLabel = text("", { AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -190), Size = UDim2.fromOffset(600, 22), TextXAlignment = Enum.TextXAlignment.Center, TextStrokeTransparency = 0.4, Font = Enum.Font.GothamMedium, Visible = false, Parent = gui })

	selectionRect = new("Frame", { BackgroundColor3 = THEME.Accent, BackgroundTransparency = 0.85, BorderSizePixel = 0, Visible = false, Parent = gui }, { stroke(THEME.Accent, 0) })

	helpPanel = panel({ Name = "Help", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(620, 330), Visible = false, Parent = gui })
	padding(14).Parent = helpPanel
	list(nil, 8).Parent = helpPanel
	text("Map Editor controls", { Font = Enum.Font.GothamBold, TextSize = 16, LayoutOrder = 0, Parent = helpPanel })
	for i, line in HELP do
		text(line, { TextWrapped = true, AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = i, Parent = helpPanel })
	end

	modalLayer = new("Frame", { BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.45, Size = UDim2.fromScale(1, 1), Visible = false, Active = true, ZIndex = 50, Parent = gui })

	tooltip = text("", { AutomaticSize = Enum.AutomaticSize.XY, Size = UDim2.fromOffset(0, 0), BackgroundTransparency = 0.05, BackgroundColor3 = THEME.Bg, TextSize = 12, ZIndex = 100, Visible = false, Parent = gui })
	corner(6).Parent = tooltip
	padding(6).Parent = tooltip

	UI.refreshToolbar()
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
		if obj:IsDescendantOf(gui) and obj.Visible and (obj:IsA("GuiButton") or obj:IsA("TextBox") or (obj:IsA("Frame") and obj.Active) or obj:IsA("ScrollingFrame")) then
			return true
		end
	end
	return false
end

return UI
