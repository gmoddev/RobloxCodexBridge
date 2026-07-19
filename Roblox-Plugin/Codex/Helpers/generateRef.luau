
local Codex = script:FindFirstAncestor("Codex")

local Types = require(Codex.Types)
local hashlib = require(Codex.Packages.hashlib)

return function(): Types.Ref
	-- Generate a random UUID-like ID using hashlib
	local randomInput = tostring(math.random()) .. tostring(os.clock()) .. tostring(tick())
	local hash = hashlib.sha256(randomInput)

	-- Take first 22 characters for a shorter, cleaner ID
	local id = string.sub(hash, 1, 22)

	-- Return string directly (Types.Ref is string)
	return id
end
