-- Use HashLib's Base64 implementation
local Codex = script:FindFirstAncestor("Codex")
local HashLib = require(Codex.Packages.hashlib)

return {
	decode = HashLib.base64_decode,
	encode = HashLib.base64_encode,
}
