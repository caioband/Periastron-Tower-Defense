-- NOTA: este modulo NAO e carregado pelo framework. O Me:Load() do servidor so
-- varre ServerScriptService.Services, e este arquivo e filho do script Server.
-- Alem disso ele requer `Configs.Shared`, que nao existe (o modulo certo e
-- `Configs.SharedConfig`), entao ele erraria caso fosse requerido.
-- Mantido aqui por fidelidade ao conteudo original da place.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Vendor = Shared:WaitForChild("Vendor")

local Configs = Shared:WaitForChild("Config")

local SharedConfig = require(Configs.Shared)
local ServerConfig = require(Configs.Server)

local Maid = require(Vendor.Maid)
local Promise = require(Packages.Promise)
local Warp = require(Vendor.Warp)
local Me = require(Vendor.Me)

local Framework = Me.new()

local ExampleService = {
	Services = {}
}

function ExampleService:construct()

end

function ExampleService:start()

end

function ExampleService:init()
	for Service, _ in self.Services do
		self.Services[Service] = Framework:Get(Service)
	end

	self:construct()
end

return ExampleService
