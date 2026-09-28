local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Me = require(Vendor.Me)
local Warp = require(Vendor.Warp)
local Log = require(Shared.Util.Log)
local Environment = require(Shared.Util.Environment)

local log = Log.new("Periastron")

local Framework = Me.new()

require(script.Satchel)

task.delay(1.2, function()
	Framework:Fire("Loaded", true)

	-- Public on purpose: a tester reads from any player's console which build and
	-- which environment they are in. See docs/common/environments.md.
	if not game:IsLoaded() then
		game.Loaded:Wait()
	end

	log:Info(`client loaded: Lobby, {Environment.Describe()} environment, place version {game.PlaceVersion}`)
end)
