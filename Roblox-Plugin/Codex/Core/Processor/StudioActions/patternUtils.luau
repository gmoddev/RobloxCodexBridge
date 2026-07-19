--!strict
-- Pattern matching utilities for glob-style patterns
-- Converts glob patterns to Lua patterns and provides matching functionality

local patternUtils = {}

-- Escape special Lua pattern characters
local function escapeLuaPattern(str: string): string
	-- Escape all Lua pattern special characters except those we'll handle specially
	return (str:gsub("[%(%)%.%%%+%-%*%?%[%]%^%$]", "%%%1"))
end

-- Convert glob pattern to Lua pattern
-- Glob: * (any chars), ** (recursive), ? (single char), [abc] (char class)
function patternUtils.globToLuaPattern(globPattern: string): string
	-- First, escape all special Lua pattern chars
	local pattern = escapeLuaPattern(globPattern)

	-- Now convert glob wildcards to Lua patterns
	-- ** = match any path segments (including /)
	pattern = pattern:gsub("%%%*%%%*", ".-")

	-- * = match any characters except /
	pattern = pattern:gsub("%%%*", "[^/]*")

	-- ? = match single character except /
	pattern = pattern:gsub("%%%?", "[^/]")

	-- Character classes [abc] are already valid in Lua patterns
	-- Unescape the brackets for character classes
	pattern = pattern:gsub("%%%[", "[")
	pattern = pattern:gsub("%%%]", "]")

	-- Anchor pattern to match full string
	return "^" .. pattern .. "$"
end

-- Check if a string matches a glob pattern
function patternUtils.matchGlob(str: string, globPattern: string): boolean
	local luaPattern = patternUtils.globToLuaPattern(globPattern)
	return str:match(luaPattern) ~= nil
end

-- Known sub-folder names that live one level below a service root.
-- These allow shorthand patterns like "StarterPlayerScripts/*" to match
-- the full path "StarterPlayer/StarterPlayerScripts/...".
local SERVICE_SUBFOLDERS: { [string]: boolean } = {
	StarterPlayerScripts = true,
	StarterCharacterScripts = true,
}

-- Check if path matches pattern (handles both full paths and name-only)
-- Pattern "GameManager" should match "ServerScriptService/GameManager"
-- Pattern "*/GameManager" should match "ServerScriptService/GameManager"
-- Pattern "**/*Manager" should match any instance ending with "Manager" anywhere
-- Pattern "**/ServerScriptService/**" should match "ServerScriptService/GameManager"
-- Pattern "StarterPlayerScripts/*" should match "StarterPlayer/StarterPlayerScripts/..."
function patternUtils.matchPath(path: string, globPattern: string): boolean
	-- Direct match
	if patternUtils.matchGlob(path, globPattern) then
		return true
	end

	-- Bug 1 fix: patterns starting with **/ fail on root-level service paths
	-- because the generated Lua pattern requires a "/" before the service name.
	-- Instance paths start at the service root (e.g. "ServerScriptService/X"),
	-- so we also try matching without the **/ prefix.
	if globPattern:sub(1, 3) == "**/" then
		local withoutPrefix = globPattern:sub(4)
		if patternUtils.matchGlob(path, withoutPrefix) then
			return true
		end
	end

	-- Bug 2 fix: shorthand sub-folder patterns like "StarterPlayerScripts/*"
	-- should match "StarterPlayer/StarterPlayerScripts/..." by prepending "**/".
	local firstSegment = globPattern:match("^([^/]+)/")
	if firstSegment and SERVICE_SUBFOLDERS[firstSegment] then
		if patternUtils.matchGlob(path, "**/" .. globPattern) then
			return true
		end
	end

	-- If pattern has no path separator, try matching just the name
	if not globPattern:match("/") then
		local name = path:match("([^/]+)$") or path
		if patternUtils.matchGlob(name, globPattern) then
			return true
		end
	end

	return false
end

-- Check if instance name matches pattern (case-sensitive by default)
function patternUtils.matchName(name: string, pattern: string, ignoreCase: boolean?): boolean
	local compareName = name
	local comparePattern = pattern

	if ignoreCase then
		compareName = compareName:lower()
		comparePattern = comparePattern:lower()
	end

	return patternUtils.matchGlob(compareName, comparePattern)
end

return patternUtils
