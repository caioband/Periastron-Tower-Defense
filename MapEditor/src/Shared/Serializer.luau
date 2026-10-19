--!strict
local HttpService = game:GetService("HttpService")

local Config = require(script.Parent.Config)

export type Record = {
	id: string,
	t: string,
	p: { number },
	r: { number },
	s: { number }?,
	sc: number?,
	c: string?,
	m: string?,
	tr: number?,
	sh: string?,
	lk: boolean?,
}

export type Route = { steps: { { alts: { { string } } } } }

export type Map = {
	v: number,
	id: string,
	name: string,
	owner: number,
	created: number,
	modified: number,
	objects: { [string]: Record },
	route: Route,
	settings: { [string]: any },
}

local Serializer = {}

local function round(n: number, step: number?): number
	local s = step or 1000
	return math.round(n * s) / s
end

function Serializer.round(n: number, step: number?): number
	return round(n, step)
end

function Serializer.vec(v: Vector3): { number }
	return { round(v.X), round(v.Y), round(v.Z) }
end

function Serializer.toVector(t: { number }): Vector3
	return Vector3.new(t[1], t[2], t[3])
end

local function normalizeAngle(deg: number): number
	local a = deg % 360
	if a > 180 then
		a -= 360
	end
	return round(a)
end

Serializer.normalizeAngle = normalizeAngle

function Serializer.recordCFrame(rec: Record): CFrame
	local p, r = rec.p, rec.r
	return CFrame.new(p[1], p[2], p[3]) * CFrame.fromOrientation(math.rad(r[1]), math.rad(r[2]), math.rad(r[3]))
end

function Serializer.setCFrame(rec: Record, cf: CFrame)
	local rx, ry, rz = cf:ToOrientation()
	rec.p = Serializer.vec(cf.Position)
	rec.r = { normalizeAngle(math.deg(rx)), normalizeAngle(math.deg(ry)), normalizeAngle(math.deg(rz)) }
end

function Serializer.copy<T>(value: T): T
	if typeof(value) ~= "table" then
		return value
	end
	local out = {}
	for k, v in value :: any do
		out[k] = Serializer.copy(v)
	end
	return out :: any
end

function Serializer.newId(): string
	local guid = HttpService:GenerateGUID(false):gsub("-", "")
	return string.sub(guid, 1, 12)
end

function Serializer.blankMap(owner: number, name: string?): Map
	local now = os.time()
	return {
		v = Config.SCHEMA_VERSION,
		id = Serializer.newId(),
		name = name or "Untitled Map",
		owner = owner,
		created = now,
		modified = now,
		objects = {},
		route = { steps = {} },
		settings = {},
	}
end

function Serializer.encodeMap(map: Map): { [string]: any }
	local list = {}
	for _, rec in map.objects do
		table.insert(list, rec)
	end
	table.sort(list, function(a, b)
		return a.id < b.id
	end)
	return {
		v = Config.SCHEMA_VERSION,
		id = map.id,
		name = map.name,
		owner = map.owner,
		created = map.created,
		modified = map.modified,
		objects = list,
		route = map.route,
		settings = map.settings,
	}
end

Serializer.MIGRATIONS = {} :: { [number]: (data: { [string]: any }) -> { [string]: any } }

function Serializer.decodeMap(data: any): (Map?, string?)
	if typeof(data) ~= "table" then
		return nil, "Map data is missing or malformed."
	end

	local version = typeof(data.v) == "number" and data.v or 0
	if version > Config.SCHEMA_VERSION then
		return nil, string.format("Map was saved with a newer editor (schema %d).", version)
	end

	while version < Config.SCHEMA_VERSION do
		local migrate = Serializer.MIGRATIONS[version]
		if not migrate then
			return nil, string.format("No migration from schema %d.", version)
		end
		data = migrate(data)
		version += 1
	end

	if typeof(data.id) ~= "string" or typeof(data.objects) ~= "table" then
		return nil, "Map data is missing required fields."
	end

	local objects = {}
	for _, rec in data.objects do
		if typeof(rec) == "table" and typeof(rec.id) == "string" then
			objects[rec.id] = rec
		end
	end

	return {
		v = Config.SCHEMA_VERSION,
		id = data.id,
		name = typeof(data.name) == "string" and data.name or "Untitled Map",
		owner = typeof(data.owner) == "number" and data.owner or 0,
		created = typeof(data.created) == "number" and data.created or os.time(),
		modified = typeof(data.modified) == "number" and data.modified or os.time(),
		objects = objects,
		route = typeof(data.route) == "table" and data.route or { steps = {} },
		settings = typeof(data.settings) == "table" and data.settings or {},
	}, nil
end

return Serializer
