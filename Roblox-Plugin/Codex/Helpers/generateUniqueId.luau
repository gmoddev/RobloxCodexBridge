
--[[
	generateUniqueId.luau

	Generates a 12-character base62 unique ID as per sync-service-api.md spec.
	Uses cryptographically random data from Roblox's HttpService:GenerateGUID()
]]

local HttpService = game:GetService("HttpService")

-- Base62 alphabet: 0-9, A-Z, a-z
local BASE62_CHARS = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"

-- Convert a hex string to a base62 string of specified length
local function hexToBase62(hex: string, targetLength: number): string
	-- Convert hex to a large number (using chunks to avoid overflow)
	local result = ""

	-- Process hex in chunks and build base62 string
	for i = 1, targetLength do
		-- Use a portion of the hex as seed for this character
		local chunkStart = ((i - 1) * 4) % #hex + 1
		local chunk = string.sub(hex, chunkStart, chunkStart + 7)

		-- Convert chunk to number and mod by 62 to get valid base62 index
		local num = tonumber(chunk, 16) or 0
		local index = (num % 62) + 1

		result = result .. string.sub(BASE62_CHARS, index, index)
	end

	return result
end

-- Generate a 12-character base62 unique ID
return function(): string
	-- Generate a UUID without hyphens (32 hex characters)
	local uuid = HttpService:GenerateGUID(false):gsub("-", "")

	-- Convert to 12-character base62
	return hexToBase62(uuid, 12)
end
