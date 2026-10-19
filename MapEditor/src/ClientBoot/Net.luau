local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("MapEditor")
local remotes = Shared:WaitForChild("Remotes")
local Request = remotes:WaitForChild("Request")
local Push = remotes:WaitForChild("Push")

local Net = {}
local listeners = {}

function Net.request(action, payload)
	local success, result = pcall(Request.InvokeServer, Request, action, payload)
	if not success then
		return { ok = false, err = "Connection problem. Try again." }
	end
	if typeof(result) ~= "table" then
		return { ok = false, err = "Unexpected server response." }
	end
	return result
end

function Net.on(kind, fn)
	listeners[kind] = listeners[kind] or {}
	table.insert(listeners[kind], fn)
end

Push.OnClientEvent:Connect(function(kind, data)
	for _, fn in listeners[kind] or {} do
		task.spawn(fn, data)
	end
end)

return Net
