local Codex = script:FindFirstAncestor("Codex")
local Log = require(Codex.Log)

local PropertyConverter = {}

-- Coerce a JSON-shaped value into the given Roblox datatype.
-- Returns nil if `value`'s shape doesn't match any known form for `targetType` —
-- callers should fall back to name-based heuristics in that case.
--
-- Note: does NOT take a propertyName argument by design. The whole point of
-- reflection-based dispatch is that the target type is the authority; pulling
-- the property name in here would invite name-leakage back into supposedly
-- name-agnostic coercion. Each branch starts with a `type(value)` guard so the
-- helper can safely accept any valueType.
local function coerceByTargetType(targetType: string, value: any): any?
	if targetType == "Color3" then
		if type(value) == "table" and #value == 3 then
			if value[1] > 1 or value[2] > 1 or value[3] > 1 then
				return Color3.fromRGB(value[1], value[2], value[3])
			end
			return Color3.new(value[1], value[2], value[3])
		end
	elseif targetType == "Vector3" then
		if type(value) == "table" and #value == 3 then
			return Vector3.new(value[1], value[2], value[3])
		end
	elseif targetType == "Vector2" then
		if type(value) == "table" and #value == 2 then
			return Vector2.new(value[1], value[2])
		end
	elseif targetType == "NumberRange" then
		if type(value) == "table" then
			if #value == 2 then
				return NumberRange.new(value[1], value[2])
			end
			if value.Min and value.Max then
				return NumberRange.new(value.Min, value.Max)
			end
		end
	elseif targetType == "NumberSequence" then
		if type(value) == "number" then
			return NumberSequence.new(value)
		end
		if type(value) == "table" and #value == 2 and type(value[1]) == "number" then
			return NumberSequence.new(value[1], value[2])
		end
		-- {t, v} keypoint form handled by Stage 1 in convertPropertyValue.
	elseif targetType == "ColorSequence" then
		if type(value) == "table" then
			-- [r, g, b] → single-keypoint sequence
			if #value == 3 and type(value[1]) == "number" then
				local c = if value[1] > 1
						or value[2] > 1
						or value[3] > 1
					then Color3.fromRGB(value[1], value[2], value[3])
					else Color3.new(value[1], value[2], value[3])
				return ColorSequence.new(c)
			end
			-- {{r,g,b}, {r,g,b}, ...} legacy array-of-arrays form
			if #value >= 2 and type(value[1]) == "table" and value[1].t == nil and #value[1] == 3 then
				local keypoints = {}
				for i, c in ipairs(value) do
					local time = (i - 1) / math.max(1, #value - 1)
					local color = if c[1] > 1
							or c[2] > 1
							or c[3] > 1
						then Color3.fromRGB(c[1], c[2], c[3])
						else Color3.new(c[1], c[2], c[3])
					table.insert(keypoints, ColorSequenceKeypoint.new(time, color))
				end
				return ColorSequence.new(keypoints)
			end
		end
		-- {t, c} keypoint form handled by Stage 1 in convertPropertyValue.
	elseif targetType == "UDim" then
		if type(value) == "table" and #value == 2 then
			return UDim.new(value[1], value[2])
		end
	elseif targetType == "UDim2" then
		if
			type(value) == "table"
			and type(value.X) == "table"
			and type(value.Y) == "table"
			and #value.X == 2
			and #value.Y == 2
		then
			return UDim2.new(value.X[1], value.X[2], value.Y[1], value.Y[2])
		end
	elseif targetType == "Rect" then
		if
			type(value) == "table"
			and type(value.Min) == "table"
			and type(value.Max) == "table"
			and #value.Min == 2
			and #value.Max == 2
		then
			return Rect.new(value.Min[1], value.Min[2], value.Max[1], value.Max[2])
		end
	elseif targetType == "CFrame" then
		if type(value) == "table" and type(value.Position) == "table" and #value.Position == 3 then
			local pos = value.Position
			if
				type(value.Orientation) == "table"
				and #value.Orientation == 3
				and type(value.Orientation[1]) == "number"
			then
				-- Euler angles (degrees)
				local o = value.Orientation
				return CFrame.new(pos[1], pos[2], pos[3])
					* CFrame.Angles(math.rad(o[1]), math.rad(o[2]), math.rad(o[3]))
			elseif type(value.Orientation) == "table" and type(value.Orientation[1]) == "table" then
				-- 3x3 matrix
				local o = value.Orientation
				return CFrame.new(
					pos[1],
					pos[2],
					pos[3],
					o[1][1],
					o[1][2],
					o[1][3],
					o[2][1],
					o[2][2],
					o[2][3],
					o[3][1],
					o[3][2],
					o[3][3]
				)
			end
			-- Position-only
			return CFrame.new(pos[1], pos[2], pos[3])
		end
	elseif targetType == "BrickColor" then
		if type(value) == "string" then
			local ok, bc = pcall(BrickColor.new, value)
			if ok then
				return bc
			end
		end
		if type(value) == "table" and #value == 3 then
			return BrickColor.new(Color3.fromRGB(value[1], value[2], value[3]))
		end
	end
	return nil
end

-- Convert property value from new API format to Roblox value
-- The new API format uses flat arrays for most properties and nested objects for complex types
-- Examples: Color: [100, 200, 100], Size: [8, 1, 8], CFrame: { Position: [0, 5, 0] }
-- Also supports simple properties: Anchored: true, Transparency: 0.5, Name: "Part1"
--
-- The optional `instance` argument enables reflection-based dispatch: when
-- present, the property's existing typeof drives coercion (via
-- coerceByTargetType) before falling back to the name-based heuristics that
-- callers without an instance still depend on.
function PropertyConverter.convertPropertyValue(propertyName: string, value: any, instance: Instance?): any?
	-- Handle nil values
	if value == nil then
		Log.trace("[convertPropertyValue]", propertyName, "is nil, returning nil")
		return nil
	end

	local valueType = type(value)
	Log.trace("[convertPropertyValue]", propertyName, "type:", valueType)

	-- Boolean/number scalars: no datatype coercion ever applies. Short-circuit
	-- so reflection and name-based stages only have to consider strings/tables.
	if valueType == "boolean" or valueType == "number" then
		Log.trace("[convertPropertyValue]", propertyName, "is scalar, returning as-is:", value)
		return value
	end

	-- Stage 1: name-agnostic value-shape detection.
	-- Explicit ColorSequence/NumberSequence keypoint arrays always become the
	-- matching sequence type regardless of property name or reflected target
	-- type. Kept here so reflection-based dispatch never overrides an explicit
	-- keypoint form.
	if valueType == "table" and #value >= 2 and type(value[1]) == "table" then
		-- ColorSequence keypoints: [{t: 0, c: [R,G,B]}, ...]
		if value[1].t ~= nil and value[1].c ~= nil then
			Log.trace("[convertPropertyValue]", propertyName, "detected as ColorSequence keypoints, length:", #value)
			local keypoints = {}
			for _, kp in ipairs(value) do
				local c = kp.c
				local color = if c[1] > 1
						or c[2] > 1
						or c[3] > 1
					then Color3.fromRGB(c[1], c[2], c[3])
					else Color3.new(c[1], c[2], c[3])
				table.insert(keypoints, ColorSequenceKeypoint.new(kp.t, color))
			end
			return ColorSequence.new(keypoints)
		end

		-- NumberSequence keypoints: [{t: 0, v: 0.5, e: 0}, ...]
		if value[1].t ~= nil and value[1].v ~= nil then
			Log.trace("[convertPropertyValue]", propertyName, "detected as NumberSequence keypoints, length:", #value)
			local keypoints = {}
			for _, kp in ipairs(value) do
				table.insert(keypoints, NumberSequenceKeypoint.new(kp.t, kp.v, kp.e or 0))
			end
			return NumberSequence.new(keypoints)
		end
	end

	-- Stage 2: reflection-based dispatch.
	-- Runs for strings AND tables. Roblox returns each property's default
	-- (correctly typed) before user assignment, so this works at create-time
	-- too. pcall in case the property doesn't exist on the instance — on
	-- failure, fall through to the name-based path so behavior is at worst
	-- identical to today.
	if instance ~= nil and (valueType == "string" or valueType == "table") then
		local probeOk, existing = pcall(function()
			return (instance :: any)[propertyName]
		end)
		if probeOk then
			local targetType = typeof(existing)
			local coerced = coerceByTargetType(targetType, value)
			if coerced ~= nil then
				Log.trace(
					"[convertPropertyValue]",
					propertyName,
					"dispatched via reflection — targetType:",
					targetType
				)
				return coerced
			end
			-- coerceByTargetType returned nil → fall through to name-based.
		end
	end

	-- Stage 3: existing name-based heuristics (unchanged).

	-- Handle string values that might be special types (BEFORE simple type check)
	if valueType == "string" then
		-- Check if this is a BrickColor property
		if propertyName == "BrickColor" or propertyName:find("BrickColor") then
			Log.trace(
				"[convertPropertyValue]",
				propertyName,
				"detected as BrickColor string, converting to BrickColor.new"
			)
			local success, brickColor = pcall(function()
				return BrickColor.new(value)
			end)
			if success then
				return brickColor
			else
				Log.warn("[convertPropertyValue]", propertyName, "failed to convert to BrickColor:", value)
				return value -- Return as-is and let caller handle error
			end
		end

		-- Check if this is an Enum property (Material, Shape, etc.)
		-- Try to parse "EnumType.Value" format or just "Value" format
		if value:find("%.") then
			-- Format: "Material.Plastic" or "PartType.Ball"
			local enumType, enumValue = value:match("^([^%.]+)%.(.+)$")
			if enumType and enumValue then
				local success, enumItem = pcall(function()
					return Enum[enumType][enumValue]
				end)
				if success then
					Log.trace("[convertPropertyValue]", propertyName, "converted enum string to EnumItem:", value)
					return enumItem
				end
			end
		end
	end

	-- Handle strings that didn't match a special-type branch above.
	-- (Boolean/number already returned at the top of this function.)
	if valueType == "string" then
		Log.trace("[convertPropertyValue]", propertyName, "is plain string, returning as-is:", value)
		return value
	end

	-- Handle array/table types
	if valueType == "table" then
		-- Check if it's an array (has numeric indices)
		local isArray = #value > 0

		if isArray then
			local len = #value
			Log.trace(
				"[convertPropertyValue]",
				propertyName,
				"is array with length:",
				len,
				"values:",
				value[1],
				value[2],
				value[3]
			)

			-- Keypoint detection moved to Stage 1 (above), so the array branch
			-- starts directly with the name-based heuristics.

			-- IMPORTANT: Check for Color properties FIRST before checking array length
			-- This prevents Color arrays from being incorrectly converted to Vector3
			if propertyName == "Color" or propertyName:find("Color") then
				-- Check if this is a ColorSequence (array of color arrays)
				-- vs a simple Color3 (array of 3 numbers)
				if len >= 2 and type(value[1]) == "table" then
					-- ColorSequence: array of RGB arrays (legacy format without time)
					Log.trace(
						"[convertPropertyValue]",
						propertyName,
						"detected as ColorSequence (array of color arrays), length:",
						len
					)
					local keypoints = {}
					for i, colorArray in ipairs(value) do
						-- Calculate time position (0 to 1)
						local time = (i - 1) / math.max(1, len - 1)
						-- Convert RGB array to Color3
						local color = if colorArray[1] > 1
								or colorArray[2] > 1
								or colorArray[3] > 1
							then Color3.fromRGB(colorArray[1], colorArray[2], colorArray[3])
							else Color3.new(colorArray[1], colorArray[2], colorArray[3])
						table.insert(keypoints, ColorSequenceKeypoint.new(time, color))
					end
					return ColorSequence.new(keypoints)
				elseif len == 3 then
					-- Single Color3: array of 3 numbers
					-- Assume RGB format if values are > 1
					if value[1] > 1 or value[2] > 1 or value[3] > 1 then
						Log.trace(
							"[convertPropertyValue]",
							propertyName,
							"detected as RGB Color (values > 1), converting to Color3.fromRGB:",
							value[1],
							value[2],
							value[3]
						)
						return Color3.fromRGB(value[1], value[2], value[3])
					else
						Log.trace(
							"[convertPropertyValue]",
							propertyName,
							"detected as normalized Color (values <= 1), converting to Color3.new:",
							value[1],
							value[2],
							value[3]
						)
						return Color3.new(value[1], value[2], value[3])
					end
				end
			end

			-- Vector3 properties (Size, Position, Rotation, Velocity, etc.) - 3 element arrays
			if len == 3 then
				Log.trace(
					"[convertPropertyValue]",
					propertyName,
					"detected as Vector3 (3 elements):",
					value[1],
					value[2],
					value[3]
				)
				return Vector3.new(value[1], value[2], value[3])
			end

			-- 2-element arrays: could be NumberSequence, NumberRange, UDim, or Vector2
			if len == 2 then
				-- UDim properties: CornerRadius, Padding*, or names containing "UDim"
				-- UDim has [Scale, Offset] format
				if
					propertyName == "CornerRadius"
					or propertyName == "Padding"
					or propertyName:find("^Padding")
					or propertyName:find("Udim")
					or propertyName:find("UDim")
				then
					Log.trace(
						"[convertPropertyValue]",
						propertyName,
						"detected as UDim (2 elements):",
						value[1],
						value[2]
					)
					return UDim.new(value[1], value[2])
				end

				-- NumberSequence properties (e.g., ParticleEmitter Transparency, Size)
				if propertyName == "Transparency" or propertyName == "Size" or propertyName:find("Transparency") then
					Log.trace(
						"[convertPropertyValue]",
						propertyName,
						"detected as NumberSequence (2 elements):",
						value[1],
						value[2]
					)
					return NumberSequence.new(value[1], value[2])
				end

				-- NumberRange properties (e.g., ParticleEmitter Lifetime, Speed)
				if
					propertyName == "Lifetime"
					or propertyName == "Speed"
					or propertyName == "Rotation"
					or propertyName == "RotSpeed"
				then
					Log.trace(
						"[convertPropertyValue]",
						propertyName,
						"detected as NumberRange (2 elements):",
						value[1],
						value[2]
					)
					return NumberRange.new(value[1], value[2])
				end

				-- Default to Vector2 for other 2-element arrays
				Log.trace(
					"[convertPropertyValue]",
					propertyName,
					"detected as Vector2 (2 elements):",
					value[1],
					value[2]
				)
				return Vector2.new(value[1], value[2])
			end

			-- For other array lengths, return as-is and let Roblox handle it
			-- This allows for future extensibility without code changes
			Log.trace(
				"[convertPropertyValue]",
				propertyName,
				"array length",
				len,
				"- returning as-is, will attempt direct assignment"
			)
			return value
		else
			-- Handle nested objects (like CFrame with Position, UDim2, etc.)
			Log.trace("[convertPropertyValue]", propertyName, "is nested object/table")

			-- UDim2 → {X: [Scale, Offset], Y: [Scale, Offset]}
			if value.X and value.Y and type(value.X) == "table" and type(value.Y) == "table" then
				local x = value.X
				local y = value.Y
				if #x == 2 and #y == 2 then
					Log.trace(
						"[convertPropertyValue]",
						propertyName,
						"detected as UDim2:",
						"X[",
						x[1],
						x[2],
						"] Y[",
						y[1],
						y[2],
						"]"
					)
					return UDim2.new(x[1], x[2], y[1], y[2])
				end
			end

			-- Rect → {Min: [X, Y], Max: [X, Y]}
			if value.Min and value.Max and type(value.Min) == "table" and type(value.Max) == "table" then
				if #value.Min == 2 and #value.Max == 2 then
					Log.trace(
						"[convertPropertyValue]",
						propertyName,
						"detected as Rect:",
						"Min[",
						value.Min[1],
						value.Min[2],
						"] Max[",
						value.Max[1],
						value.Max[2],
						"]"
					)
					return Rect.new(value.Min[1], value.Min[2], value.Max[1], value.Max[2])
				end
			end

			if propertyName == "CFrame" then
				-- CFrame with Position and Orientation (PascalCase keys per Roblox API standard)
				if value.Position and value.Orientation then
					local pos = value.Position
					local orient = value.Orientation

					-- Check if Orientation is Euler angles (3 numbers) or matrix (3x3 array)
					if #pos == 3 and #orient == 3 and type(orient[1]) == "number" then
						-- Euler angles format (degrees)
						Log.trace(
							"[convertPropertyValue]",
							propertyName,
							"detected as CFrame with Position and Orientation (Euler):",
							"pos[",
							pos[1],
							pos[2],
							pos[3],
							"]",
							"orient[",
							orient[1],
							orient[2],
							orient[3],
							"]"
						)
						-- Convert Euler angles from degrees to radians and create CFrame
						return CFrame.new(pos[1], pos[2], pos[3])
							* CFrame.Angles(math.rad(orient[1]), math.rad(orient[2]), math.rad(orient[3]))
					elseif #pos == 3 and type(orient[1]) == "table" then
						-- Matrix format (3x3)
						Log.trace(
							"[convertPropertyValue]",
							propertyName,
							"detected as CFrame with Position and Orientation (matrix)"
						)
						return CFrame.new(
							pos[1],
							pos[2],
							pos[3],
							orient[1][1],
							orient[1][2],
							orient[1][3],
							orient[2][1],
							orient[2][2],
							orient[2][3],
							orient[3][1],
							orient[3][2],
							orient[3][3]
						)
					end
				end
				-- Simple CFrame with just Position
				if value.Position then
					local pos = value.Position
					if #pos == 3 then
						Log.trace(
							"[convertPropertyValue]",
							propertyName,
							"detected as simple CFrame (Position only):",
							pos[1],
							pos[2],
							pos[3]
						)
						return CFrame.new(pos[1], pos[2], pos[3])
					end
				end
			end

			-- For other nested objects, return as-is and let Roblox handle it
			-- This allows the system to be permissive for properties we haven't explicitly coded
			Log.trace(
				"[convertPropertyValue]",
				propertyName,
				"nested object - returning as-is, will attempt direct assignment"
			)
			return value
		end
	end

	-- For any other type, return as-is and let the property assignment try
	-- This makes the system permissive and non-restrictive
	Log.trace(
		"[convertPropertyValue]",
		propertyName,
		"type",
		valueType,
		"- returning as-is, will attempt direct assignment"
	)
	return value
end

return PropertyConverter
