--!strict
-- importRbxm: Import .rbxm binary data into Studio
-- Uses SerializationService:DeserializeInstancesAsync to recreate instances
-- Unlike importAsset, this does NOT strip scripts — .rbxm files are trusted developer content

local Codex = script:FindFirstAncestor("Codex")
local Log = require(Codex.Log)
local helpers = require(script.Parent.helpers)

local SerializationService = game:GetService("SerializationService")

-- Base64 decoder (Roblox has no built-in base64 decode)
local B64_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64_LOOKUP = {} :: { [number]: number }
for i = 1, #B64_CHARS do
	B64_LOOKUP[string.byte(B64_CHARS, i)] = i - 1
end
B64_LOOKUP[string.byte("=")] = 0

local function base64Decode(input: string): string
	local output = {}
	local i = 1
	local len = #input

	while i <= len do
		local b1 = B64_LOOKUP[string.byte(input, i)] or 0
		local b2 = B64_LOOKUP[string.byte(input, i + 1)] or 0
		local b3 = B64_LOOKUP[string.byte(input, i + 2)] or 0
		local b4 = B64_LOOKUP[string.byte(input, i + 3)] or 0

		local n = b1 * 262144 + b2 * 4096 + b3 * 64 + b4

		table.insert(output, string.char(
			math.floor(n / 65536) % 256,
			math.floor(n / 256) % 256,
			n % 256
		))

		i += 4
	end

	-- Handle padding
	local result = table.concat(output)
	if string.sub(input, -2) == "==" then
		result = string.sub(result, 1, #result - 2)
	elseif string.sub(input, -1) == "=" then
		result = string.sub(result, 1, #result - 1)
	end

	return result
end

return function(
	self,
	params: {
		parentId: string,
		rbxmBase64: string,
		name: string,
	}
): {
	status: string,
	uniqueId: string?,
	path: string?,
	robloxClass: string?,
	childCount: number?,
	error: string?,
}
	Log.info("[StudioActions.importRbxm] BEGIN - Importing", params.name)

	-- 1. Find parent instance
	local parent = self.tree:getInstance(params.parentId)
	if not parent then
		return {
			status = "failed",
			error = string.format("Parent instance not found: %s", params.parentId),
		}
	end

	-- 2. Decode base64 to binary string
	local decodeSuccess, rbxmData = pcall(function()
		return base64Decode(params.rbxmBase64)
	end)

	if not decodeSuccess or not rbxmData then
		return {
			status = "failed",
			error = string.format("Failed to decode base64: %s", tostring(rbxmData)),
		}
	end

	Log.info(string.format("[StudioActions.importRbxm] Decoded buffer size: %d bytes", #rbxmData))

	-- 3. Deserialize .rbxm buffer into instances
	local deserializeSuccess, instances = pcall(function()
		return SerializationService:DeserializeInstancesAsync(buffer.fromstring(rbxmData))
	end)

	if not deserializeSuccess then
		return {
			status = "failed",
			error = string.format("Failed to deserialize .rbxm: %s", tostring(instances)),
		}
	end

	if not instances or #instances == 0 then
		return {
			status = "failed",
			error = "Deserialization returned no instances",
		}
	end

	Log.info(string.format("[StudioActions.importRbxm] Deserialized %d root instance(s)", #instances))

	-- 4. Handle single vs multiple root instances
	local rootInstance
	if #instances == 1 then
		rootInstance = instances[1]
	else
		-- Multiple root instances - wrap in a Folder
		local folder = Instance.new("Folder")
		folder.Name = params.name
		for _, inst in ipairs(instances) do
			inst.Parent = folder
		end
		rootInstance = folder
	end

	-- 5. Rename and parent
	rootInstance.Name = params.name
	rootInstance.Parent = parent

	-- 6. Register root instance with Tree
	local uniqueId = helpers.registerNewInstance(self.tree, rootInstance)

	-- 7. Register ALL descendants with Tree (including scripts — no stripping for libraries)
	for _, descendant in rootInstance:GetDescendants() do
		helpers.registerNewInstance(self.tree, descendant)
	end

	local childCount = #rootInstance:GetDescendants()
	local path = helpers.getInstancePath(rootInstance)

	Log.info(string.format(
		"[StudioActions.importRbxm] SUCCESS - Imported %s at %s (%d descendants)",
		params.name, path, childCount
	))

	return {
		status = "completed",
		uniqueId = uniqueId,
		path = path,
		robloxClass = rootInstance.ClassName,
		childCount = childCount > 0 and childCount or nil,
	}
end
