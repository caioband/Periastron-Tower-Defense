--!strict
export type Limiter = {
	rate: number,
	burst: number,
	buckets: { [number]: { tokens: number, stamp: number } },
	allow: (self: Limiter, userId: number, cost: number?) -> boolean,
	clear: (self: Limiter, userId: number) -> (),
}

local RateLimiter = {}
RateLimiter.__index = RateLimiter

function RateLimiter.new(rate: number, burst: number): Limiter
	return setmetatable({ rate = rate, burst = burst, buckets = {} }, RateLimiter) :: any
end

function RateLimiter.allow(self: Limiter, userId: number, cost: number?): boolean
	local now = os.clock()
	local bucket = self.buckets[userId]
	if not bucket then
		bucket = { tokens = self.burst, stamp = now }
		self.buckets[userId] = bucket
	end
	bucket.tokens = math.min(self.burst, bucket.tokens + (now - bucket.stamp) * self.rate)
	bucket.stamp = now
	local price = cost or 1
	if bucket.tokens < price then
		return false
	end
	bucket.tokens -= price
	return true
end

function RateLimiter.clear(self: Limiter, userId: number)
	self.buckets[userId] = nil
end

return RateLimiter
