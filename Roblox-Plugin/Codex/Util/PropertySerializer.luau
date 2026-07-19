
-- PropertySerializer: Converts Roblox property values to server API format
-- This is the REVERSE of PropertyConverter (which converts server → Roblox)
-- Used when pushing property changes from Studio to the server

local Codex = script:FindFirstAncestor("Codex")
local Log = require(Codex.Log)

local PropertySerializer = {}

-- Helper: Recursively clean values for JSON serialization
-- Recursively processes nested tables
local function cleanBuffers(value: any): any
	-- Recursively clean tables
	if type(value) == "table" then
		local cleaned = {}
		for k, v in pairs(value) do
			-- Clean both keys and values
			local cleanedKey = cleanBuffers(k)
			local cleanedValue = cleanBuffers(v)
			cleaned[cleanedKey] = cleanedValue
		end
		return cleaned
	end

	-- Return other types as-is
	return value
end

-- Convert Roblox property value to server API PropertyValue format
-- The server API format uses:
-- - Flat arrays for vectors and colors: [R, G, B], [X, Y, Z]
-- - Nested objects for complex types: {Position: [X, Y, Z]}
-- - Simple types: boolean, string, number
function PropertySerializer.serializePropertyValue(propertyName: string, instance: Instance, propertyValue: any): any?
	-- Handle nil values
	if propertyValue == nil then
		Log.trace("[PropertySerializer]", propertyName, "is nil, returning nil")
		return nil
	end

	local valueType = typeof(propertyValue)
	Log.trace("[PropertySerializer]", propertyName, "type:", valueType, "value:", tostring(propertyValue))

	-- Simple types pass through directly
	if valueType == "boolean" or valueType == "string" or valueType == "number" then
		Log.trace("[PropertySerializer]", propertyName, "is simple type, returning as-is:", propertyValue)
		return propertyValue
	end

	-- Color3 → [R, G, B] array (0-255 range)
	if valueType == "Color3" then
		local color = propertyValue :: Color3
		local rgb = { math.floor(color.R * 255), math.floor(color.G * 255), math.floor(color.B * 255) }
		Log.trace("[PropertySerializer]", propertyName, "Color3 →", rgb[1], rgb[2], rgb[3])
		return cleanBuffers(rgb)
	end

	-- Vector3 → [X, Y, Z] array
	if valueType == "Vector3" then
		local vec = propertyValue :: Vector3
		local arr = { vec.X, vec.Y, vec.Z }
		Log.trace("[PropertySerializer]", propertyName, "Vector3 →", arr[1], arr[2], arr[3])
		return cleanBuffers(arr)
	end

	-- Vector2 → [X, Y] array
	if valueType == "Vector2" then
		local vec = propertyValue :: Vector2
		local arr = { vec.X, vec.Y }
		Log.trace("[PropertySerializer]", propertyName, "Vector2 →", arr[1], arr[2])
		return cleanBuffers(arr)
	end

	-- CFrame → {Position: [X, Y, Z], Orientation: [X, Y, Z]}
	if valueType == "CFrame" then
		local cf = propertyValue :: CFrame
		local orientation = instance:IsA("BasePart") and (instance :: BasePart).Orientation or Vector3.new(0, 0, 0)
		local serialized = {
			Position = { cf.Position.X, cf.Position.Y, cf.Position.Z },
			Orientation = { orientation.X, orientation.Y, orientation.Z },
		}
		Log.trace(
			"[PropertySerializer]",
			propertyName,
			"CFrame → Position:",
			serialized.Position,
			"Orientation:",
			serialized.Orientation
		)
		return cleanBuffers(serialized)
	end

	-- EnumItem → string name
	if valueType == "EnumItem" then
		local enumValue = (propertyValue :: any).Name
		Log.trace("[PropertySerializer]", propertyName, "EnumItem →", enumValue)
		return enumValue
	end

	-- BrickColor → string name
	if valueType == "BrickColor" then
		local brickColor = propertyValue :: BrickColor
		Log.trace("[PropertySerializer]", propertyName, "BrickColor →", brickColor.Name)
		return brickColor.Name
	end

	-- UDim2 → nested object {X: {Scale, Offset}, Y: {Scale, Offset}}
	if valueType == "UDim2" then
		local udim = propertyValue :: UDim2
		local serialized = {
			X = { udim.X.Scale, udim.X.Offset },
			Y = { udim.Y.Scale, udim.Y.Offset },
		}
		Log.trace("[PropertySerializer]", propertyName, "UDim2 → X:", serialized.X, "Y:", serialized.Y)
		return cleanBuffers(serialized)
	end

	-- UDim → [Scale, Offset] array
	if valueType == "UDim" then
		local udim = propertyValue :: UDim
		local arr = { udim.Scale, udim.Offset }
		Log.trace("[PropertySerializer]", propertyName, "UDim →", arr[1], arr[2])
		return cleanBuffers(arr)
	end

	-- NumberRange → [Min, Max] array
	if valueType == "NumberRange" then
		local range = propertyValue :: NumberRange
		local arr = { range.Min, range.Max }
		Log.trace("[PropertySerializer]", propertyName, "NumberRange →", arr[1], arr[2])
		return cleanBuffers(arr)
	end

	-- ColorSequence → array of keypoint objects [{t, c: [R,G,B]}, ...]
	if valueType == "ColorSequence" then
		local seq = propertyValue :: ColorSequence
		local keypoints = {}
		for _, kp in ipairs(seq.Keypoints) do
			table.insert(keypoints, {
				t = kp.Time,
				c = { math.floor(kp.Value.R * 255), math.floor(kp.Value.G * 255), math.floor(kp.Value.B * 255) },
			})
		end
		Log.trace("[PropertySerializer]", propertyName, "ColorSequence →", #keypoints, "keypoints")
		return cleanBuffers(keypoints)
	end

	-- NumberSequence → array of keypoint objects [{t, v, e}, ...]
	if valueType == "NumberSequence" then
		local seq = propertyValue :: NumberSequence
		local keypoints = {}
		for _, kp in ipairs(seq.Keypoints) do
			table.insert(keypoints, {
				t = kp.Time,
				v = kp.Value,
				e = kp.Envelope,
			})
		end
		Log.trace("[PropertySerializer]", propertyName, "NumberSequence →", #keypoints, "keypoints")
		return cleanBuffers(keypoints)
	end

	-- Rect → {Min: [X, Y], Max: [X, Y]}
	if valueType == "Rect" then
		local rect = propertyValue :: Rect
		local serialized = {
			Min = { rect.Min.X, rect.Min.Y },
			Max = { rect.Max.X, rect.Max.Y },
		}
		Log.trace("[PropertySerializer]", propertyName, "Rect →", serialized)
		return cleanBuffers(serialized)
	end

	-- Skip Attributes
	if propertyName == "Attributes" then
		Log.trace("[PropertySerializer]", propertyName, "is Attributes, returning nil")
		return nil
	end

	-- For unsupported types, log warning and return nil
	Log.warn("[PropertySerializer]", propertyName, "has unsupported type:", valueType, "- skipping serialization")
	return nil
end

-- Serialize a table of attributes (key-value pairs)
-- Attributes are always simple types: string, number, boolean
function PropertySerializer.serializeAttributes(attributes: { [string]: any }): { [string]: any }
	local serialized = {}
	for name, value in pairs(attributes) do
		-- Attributes are always simple types, just copy them
		serialized[name] = value
	end
	return serialized
end

return PropertySerializer
