local RunService = game:GetService("RunService")

local GameClock = {}

local MIN_SCALE = 0.01

local scale = 1
local now = os.clock()

local heap = {}
local size = 0
local sequence = 0
local ready = {}

local function before(a, b) : boolean
	if a.deadline ~= b.deadline then
		return a.deadline < b.deadline
	end
	return a.order < b.order
end

local function push(deadline : number, thread : thread)
	sequence += 1
	size += 1

	local entry = { deadline = deadline, order = sequence, thread = thread }
	local index = size

	while index > 1 do
		local parent = index // 2
		if before(heap[parent], entry) then
			break
		end
		heap[index] = heap[parent]
		index = parent
	end

	heap[index] = entry
end

local function pop()
	local top = heap[1]
	local last = heap[size]
	heap[size] = nil
	size -= 1

	if size > 0 then
		local index = 1
		while true do
			local child = index * 2
			if child > size then
				break
			end
			if child < size and before(heap[child + 1], heap[child]) then
				child += 1
			end
			if before(last, heap[child]) then
				break
			end
			heap[index] = heap[child]
			index = child
		end
		heap[index] = last
	end

	return top
end

RunService.Heartbeat:Connect(function(dt : number)
	now += dt * scale

	local count = 0
	while size > 0 and heap[1].deadline <= now do
		count += 1
		ready[count] = pop().thread
	end

	for index = 1, count do
		local thread = ready[index]
		ready[index] = nil

		if coroutine.status(thread) == "suspended" then
			task.spawn(thread)
		end
	end
end)

function GameClock.Now() : number
	return now
end

function GameClock.GetScale() : number
	return scale
end

function GameClock.SetScale(newScale : number?)
	scale = math.max(MIN_SCALE, newScale or 1)
end

function GameClock.Scaled(dt : number) : number
	return dt * scale
end

function GameClock.Wait(duration : number?) : number
	push(now + (duration or 0), coroutine.running())
	coroutine.yield()
	return now
end

function GameClock.Delay(duration : number?, callback : () -> ()) : thread
	local thread = coroutine.create(callback)
	push(now + (duration or 0), thread)
	return thread
end

return GameClock