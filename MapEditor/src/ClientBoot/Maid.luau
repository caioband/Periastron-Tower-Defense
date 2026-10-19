local Maid = {}
Maid.__index = Maid

function Maid.new()
	return setmetatable({ tasks = {} }, Maid)
end

function Maid:Give(task_)
	table.insert(self.tasks, task_)
	return task_
end

function Maid:Clean()
	local tasks = self.tasks
	self.tasks = {}
	for _, t in tasks do
		if typeof(t) == "RBXScriptConnection" then
			t:Disconnect()
		elseif typeof(t) == "Instance" then
			t:Destroy()
		elseif type(t) == "function" then
			t()
		elseif type(t) == "table" and t.Disconnect then
			t:Disconnect()
		end
	end
end

return Maid
