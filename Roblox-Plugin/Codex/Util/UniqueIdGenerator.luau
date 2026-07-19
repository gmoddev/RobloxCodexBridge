
--[[
	Generate unique instance IDs using base32 alphabet (12 characters)
	Follows vm-file-representation.md spec for consistent ID generation

	Base32 alphabet (uppercase): ABCDEFGHIJKLMNOPQRSTUVWXYZ234567
	Length: 12 characters
	Format: @{12-char-base32} (e.g., @Q2J7XWFZ4M8N)

	This is equivalent to nanoid with base32 alphabet on the server side.
]]

local HttpService = game:GetService("HttpService")

-- Base32 alphabet (uppercase) - same as nanoid base32
local BASE32_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
local ID_LENGTH = 12

local UniqueIdGenerator = {}

--[[
	Generate a cryptographically random 12-character base32 ID
	Uses HttpService:GenerateGUID() as entropy source and maps to base32 alphabet

	This is the Lua/Roblox equivalent of nanoid with base32 alphabet.
]]
function UniqueIdGenerator.generate(): string
	-- Use GUID as entropy source (128 bits of randomness)
	local guid = HttpService:GenerateGUID(false) -- No curly braces

	-- Remove hyphens and convert to uppercase
	local cleanGuid = string.upper(string.gsub(guid, "-", ""))

	-- Map hex characters to base32 alphabet indices
	-- We'll use the hex GUID as a source of randomness
	local result = ""
	local alphabetLen = #BASE32_ALPHABET

	for i = 1, ID_LENGTH do
		-- Take groups of hex digits and map to base32
		-- Each hex char is 0-15, we need 0-31 for base32
		local hexIndex = ((i - 1) * 2) + 1
		local hex1 = cleanGuid:sub(hexIndex, hexIndex)
		local hex2 = cleanGuid:sub(hexIndex + 1, hexIndex + 1)

		-- Convert hex pair to number (0-255)
		local value = tonumber(hex1 .. hex2, 16) or 0

		-- Map to base32 alphabet (0-31)
		local index = (value % alphabetLen) + 1
		result = result .. BASE32_ALPHABET:sub(index, index)
	end

	return result
end

--[[
	Validate uniqueId format
	Valid format: 12 uppercase alphanumeric base32 characters
]]
function UniqueIdGenerator.isValid(id: string): boolean
	if type(id) ~= "string" then
		return false
	end

	if #id ~= ID_LENGTH then
		return false
	end

	-- Check each character is in base32 alphabet
	for i = 1, #id do
		local char = id:sub(i, i)
		if not string.find(BASE32_ALPHABET, char, 1, true) then
			return false
		end
	end

	return true
end

--[[
	Reserved service IDs (3-character, predefined)
	These are short, human-readable IDs for top-level Roblox services
]]
UniqueIdGenerator.RESERVED_SERVICE_IDS = {
	ws1 = "Workspace",
	sp1 = "StarterPlayer",
	sss = "ServerScriptService",
	sg1 = "StarterGui",
	ss1 = "ServerStorage",
	rs1 = "ReplicatedStorage",
	spk = "StarterPack",
	rf1 = "ReplicatedFirst",
	sps = "StarterPlayerScripts",
	scs = "StarterCharacterScripts",
}

--[[
	Check if an ID is a reserved service ID
]]
function UniqueIdGenerator.isReservedServiceId(id: string): boolean
	return UniqueIdGenerator.RESERVED_SERVICE_IDS[id] ~= nil
end

return UniqueIdGenerator
