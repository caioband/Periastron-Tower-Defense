local Signal = {}
Signal.__index = Signal

function Signal.new()
	return setmetatable({ handlers = {} }, Signal)
end

function Signal:Connect(fn)
	local handler = { fn = fn, connected = true }
	table.insert(self.handlers, handler)
	return {
		Disconnect = function()
			handler.connected = false
			local index = table.find(self.handlers, handler)
			if index then
				table.remove(self.handlers, index)
			end
		end,
	}
end

function Signal:Fire(...)
	for _, handler in table.clone(self.handlers) do
		if handler.connected then
			task.spawn(handler.fn, ...)
		end
	end
end

return Signal
