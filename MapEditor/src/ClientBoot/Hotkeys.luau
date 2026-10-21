local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local State = require(script.Parent.State)
local UI = require(script.Parent.UI)
local Pointer = require(script.Parent.Pointer)

local player = Players.LocalPlayer

local Hotkeys = {}

local panel = nil

function Hotkeys.init()
	local gui = player:WaitForChild("PlayerGui"):WaitForChild("MapEditorUI")
	panel = gui:WaitForChild("Hotkeys")
	panel.Visible = false
end

function Hotkeys.update()
	if not panel then
		return
	end
	local show = State.active
		and State.mode == "Build"
		and #State.selection == 0
		and not UI.modalOpen()
		and not Pointer.isTouch()
		and UserInputService.KeyboardEnabled
	if panel.Visible ~= show then
		panel.Visible = show
	end
end

function Hotkeys.hide()
	if panel then
		panel.Visible = false
	end
end

return Hotkeys