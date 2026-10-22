--!strict
local Config = require(script.Parent.Config)
local Catalog = require(script.Parent.Catalog)
local Serializer = require(script.Parent.Serializer)

type Record = Serializer.Record

local MapRules = {}

local MATERIAL_SET = {}
for _, name in Config.MATERIALS do
	MATERIAL_SET[name] = true
end

local SHAPE_SET = {}
for _, name in Config.SHAPES do
	SHAPE_SET[name] = true
end

MapRules.MATERIAL_SET = MATERIAL_SET

local function finite(n: any): boolean
	return typeof(n) == "number" and n == n and n > -math.huge and n < math.huge
end

MapRules.finite = finite

local function readVector(t: any): Vector3?
	if typeof(t) ~= "table" then
		return nil
	end
	local x, y, z = t[1], t[2], t[3]
	if not (finite(x) and finite(y) and finite(z)) then
		return nil
	end
	return Vector3.new(x, y, z)
end

MapRules.readVector = readVector

function MapRules.inBounds(p: Vector3): boolean
	return math.abs(p.X) <= Config.BOUNDS_HALF_XZ
		and math.abs(p.Z) <= Config.BOUNDS_HALF_XZ
		and p.Y >= Config.BOUNDS_MIN_Y
		and p.Y <= Config.BOUNDS_MAX_Y
end

local function clampVector(v: Vector3, lo: Vector3, hi: Vector3): Vector3
	return Vector3.new(math.clamp(v.X, lo.X, hi.X), math.clamp(v.Y, lo.Y, hi.Y), math.clamp(v.Z, lo.Z, hi.Z))
end

function MapRules.validId(id: any): boolean
	return typeof(id) == "string" and #id >= 1 and #id <= 24 and string.match(id, "[^%w_%-]") == nil
end

function MapRules.sanitizeName(name: any): string?
	if typeof(name) ~= "string" then
		return nil
	end
	local trimmed = string.gsub(string.gsub(name, "[%c]", ""), "^%s*(.-)%s*$", "%1")
	if #trimmed == 0 then
		return nil
	end
	return string.sub(trimmed, 1, Config.MAX_NAME_LENGTH)
end

function MapRules.sanitizeRecord(raw: any): (boolean, string?, Record?)
	if typeof(raw) ~= "table" then
		return false, "Malformed object.", nil
	end
	if not MapRules.validId(raw.id) then
		return false, "Invalid object id.", nil
	end
	local def = Catalog.get(raw.t)
	if not def then
		return false, "Unknown object type.", nil
	end

	local p = readVector(raw.p)
	if not p then
		return false, "Invalid position.", nil
	end
	if not MapRules.inBounds(p) then
		return false, "Outside the build area.", nil
	end

	local r = readVector(raw.r) or Vector3.zero
	if not def.rotatable then
		r = Vector3.zero
	elseif def.yawOnly then
		r = Vector3.new(0, r.Y, 0)
	end

	local rec: Record = {
		id = raw.id,
		t = def.id,
		p = Serializer.vec(p),
		r = {
			Serializer.normalizeAngle(r.X),
			Serializer.normalizeAngle(r.Y),
			Serializer.normalizeAngle(r.Z),
		},
	}

	if def.kind == "Part" then
		local default = def.size :: Vector3
		local s = readVector(raw.s) or default
		if not def.resizable then
			s = default
		else
			s = clampVector(s, def.minSize or default, def.maxSize or default)
			if def.uniform then
				local m = math.max(s.X, s.Y, s.Z)
				s = clampVector(Vector3.new(m, m, m), def.minSize or default, def.maxSize or default)
			end
		end
		rec.s = Serializer.vec(s)
	end

	if def.scalable and finite(raw.sc) then
		local sc = Serializer.round(math.clamp(raw.sc, def.minScale or 1, def.maxScale or 1), 100)
		if math.abs(sc - 1) > 1e-3 then
			rec.sc = sc
		end
	end

	if def.allowColor and typeof(raw.c) == "string" and #raw.c == 6 and string.match(raw.c, "[^%x]") == nil then
		rec.c = string.upper(raw.c)
	end

	if def.allowMaterial and typeof(raw.m) == "string" and MATERIAL_SET[raw.m] then
		rec.m = raw.m
	end

	if def.allowTransparency and finite(raw.tr) then
		local tr = Serializer.round(math.clamp(raw.tr, 0, 0.95), 100)
		if tr > 0 then
			rec.tr = tr
		end
	end

	if def.allowShape and typeof(raw.sh) == "string" and SHAPE_SET[raw.sh] and raw.sh ~= "Block" then
		rec.sh = raw.sh
	end

	if raw.lk == true then
		rec.lk = true
	end

	return true, nil, rec
end

return MapRules
