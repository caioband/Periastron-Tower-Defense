local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")

local Vendor = ReplicatedStorage:WaitForChild("Vendor")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Me = require(Shared.Me)
local Warp = require(Vendor.Warp)

local Framework = Me.new()

require(script.Satchel)

task.delay(1.2, function()
	Framework:Fire("Loaded", true)
end)
