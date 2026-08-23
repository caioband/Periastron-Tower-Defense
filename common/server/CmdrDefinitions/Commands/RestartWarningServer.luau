local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")
local Me = require(Vendor:WaitForChild("Me"))

local Framework = Me.new()

local DEFAULT_SECONDS = 300

--[[
	O restart de verdade não dá para ensaiar: `game.ServerRestartScheduled` é a
	engine que dispara, e a única forma de vê-lo é publicar uma atualização. Este
	comando entra pelo mesmo `Schedule` que o evento usa, então o que aparece na
	tela é exatamente o que apareceria no dia — só que sem ninguém ser derrubado.
]]
return function(_context, source : string, seconds : number?)
	local ServerRestartService = Framework:Get("ServerRestartService", false, true)

	local remaining = math.max(seconds or DEFAULT_SECONDS, 0)

	ServerRestartService:Schedule(source, DateTime.now().UnixTimestamp + remaining)

	return string.format("Restart warning sent: %s in %d seconds (nothing was actually scheduled).", source, remaining)
end
