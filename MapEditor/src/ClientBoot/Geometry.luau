local Geometry = {}

function Geometry.partExtents(part)
	local half = part.Size / 2
	local cf = part.CFrame
	local extent = Vector3.new(
		math.abs(cf.RightVector.X) * half.X + math.abs(cf.UpVector.X) * half.Y + math.abs(cf.LookVector.X) * half.Z,
		math.abs(cf.RightVector.Y) * half.X + math.abs(cf.UpVector.Y) * half.Y + math.abs(cf.LookVector.Y) * half.Z,
		math.abs(cf.RightVector.Z) * half.X + math.abs(cf.UpVector.Z) * half.Y + math.abs(cf.LookVector.Z) * half.Z
	)
	return cf.Position - extent, cf.Position + extent
end

function Geometry.bounds(instances)
	local minV, maxV = nil, nil
	local function include(part)
		local lo, hi = Geometry.partExtents(part)
		minV = minV and minV:Min(lo) or lo
		maxV = maxV and maxV:Max(hi) or hi
	end
	for _, inst in instances do
		if inst:IsA("BasePart") then
			include(inst)
		end
		for _, d in inst:GetDescendants() do
			if d:IsA("BasePart") then
				include(d)
			end
		end
	end
	return minV, maxV
end

function Geometry.localCorners(container, pivot)
	local corners = {}
	local function add(part)
		local half = part.Size / 2
		for _, sx in { -1, 1 } do
			for _, sy in { -1, 1 } do
				for _, sz in { -1, 1 } do
					local world = part.CFrame:PointToWorldSpace(Vector3.new(half.X * sx, half.Y * sy, half.Z * sz))
					table.insert(corners, pivot:PointToObjectSpace(world))
				end
			end
		end
	end
	if container:IsA("BasePart") then
		add(container)
	end
	for _, d in container:GetDescendants() do
		if d:IsA("BasePart") then
			add(d)
		end
	end
	return corners
end

function Geometry.snap(value, step)
	return math.round(value / step) * step
end

function Geometry.alignToNormal(normal)
	local axis = Vector3.yAxis:Cross(normal)
	if axis.Magnitude < 1e-4 then
		if normal.Y < 0 then
			return CFrame.Angles(math.pi, 0, 0)
		end
		return CFrame.identity
	end
	local angle = math.acos(math.clamp(Vector3.yAxis:Dot(normal), -1, 1))
	return CFrame.fromAxisAngle(axis.Unit, angle)
end

return Geometry
