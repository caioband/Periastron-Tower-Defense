local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Me = require(Vendor.Me)
local Framework = Me.new()

local MusicController = {}

function MusicController:playMusic(Name : string)
	local MusicGroup = game.SoundService:FindFirstChild("Music")
	if not MusicGroup then return end
	local Music = MusicGroup:FindFirstChild(Name) :: Sound
	if Music and Music:IsA("Sound") then
		Music.Looped = true
		Music:Play()

		print("Playing:", Name)
	end
end

function MusicController:OnLoadingComplete()
	print("Request!")
	Framework:Fire("RequestMapMusic")
end

function MusicController:construct()
	Framework:Listen("PlayMapMusic", function(Name : string)
		self:playMusic(Name)
	end)
end

function MusicController:start()
end

function MusicController:init()
	self:construct()
end

return MusicController
