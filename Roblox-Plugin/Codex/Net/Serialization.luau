
-- Require Log module
local Codex = script:FindFirstAncestor("Codex")
local Log = require(Codex.Log)
local Types = require(Codex.Types)

local function getKeys(tbl: { [any]: any }?)
	local keys = {}
	if type(tbl) == "table" then
		for k, _ in pairs(tbl) do
			table.insert(keys, tostring(k)) -- Ensure keys are strings for table.concat
		end
	end
	return keys
end

-- refToString is now a no-op since Types.Ref is already a string
local function refToString(uniqueId: Types.Ref)
	return uniqueId
end

-- cleanBufferObjects simplified - kept for API compatibility
-- Kept for API compatibility in case it's used elsewhere
local function cleanBufferObjects(obj)
	if type(obj) == "table" then
		local cleaned = {}
		for key, value in pairs(obj) do
			cleaned[key] = cleanBufferObjects(value)
		end
		return cleaned
	else
		return obj
	end
end

-- Simplified debug helper for data structure inspection
local function logDeepTable(tbl, prefix)
	prefix = prefix or ""
	if type(tbl) ~= "table" then
		Log.debug(prefix .. "Value: ", tbl)
		return
	end
	Log.debug(prefix .. "Table with keys: ", table.concat(getKeys(tbl), ", "))
end

local function isScriptClass(className: string?): boolean
	return className == "Script" or className == "ModuleScript" or className == "LocalScript"
end

local Serialization = {
	refToString = refToString,
	cleanBufferObjects = cleanBufferObjects,
	logDeepTable = logDeepTable,
	isScriptClass = isScriptClass,
	getKeys = getKeys,
}

return Serialization
