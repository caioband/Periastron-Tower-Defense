local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")

local Vendor = ReplicatedStorage:WaitForChild("Vendor")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Me = require(Shared.Me)
local Warp = require(Vendor.Warp)

local Framework = Me.new()
