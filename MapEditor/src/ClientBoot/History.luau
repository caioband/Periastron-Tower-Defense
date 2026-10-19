local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("MapEditor").Config)

local History = {}
History.undoStack = {}
History.redoStack = {}

function History.push(entry)
	table.insert(History.undoStack, entry)
	while #History.undoStack > Config.HISTORY_LIMIT do
		table.remove(History.undoStack, 1)
	end
	table.clear(History.redoStack)
end

function History.peekUndo()
	return History.undoStack[#History.undoStack]
end

function History.peekRedo()
	return History.redoStack[#History.redoStack]
end

function History.moveToRedo()
	local entry = table.remove(History.undoStack)
	if entry then
		table.insert(History.redoStack, entry)
	end
	return entry
end

function History.moveToUndo()
	local entry = table.remove(History.redoStack)
	if entry then
		table.insert(History.undoStack, entry)
	end
	return entry
end

function History.clear()
	table.clear(History.undoStack)
	table.clear(History.redoStack)
end

return History
