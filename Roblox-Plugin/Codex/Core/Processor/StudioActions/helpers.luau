--!strict
-- Shared helper functions for Studio action handlers

local Codex = script:FindFirstAncestor("Codex")
local generateUniqueId = require(Codex.Helpers.generateUniqueId)
local UniqueIdHelpers = require(Codex.Util.UniqueIdHelpers)

local helpers = {}

-- Get hierarchical path for instance (e.g., "ServerScriptService/GameManager")
function helpers.getInstancePath(instance: Instance): string
	local parts = {}
	local current = instance

	while current and current.Parent do
		table.insert(parts, 1, current.Name)
		current = current.Parent

		-- Stop at service folders
		if current == game then
			break
		end
	end

	return table.concat(parts, "/")
end

-- Generate a unique ID using the plugin's standard helper
function helpers.generateUniqueId(): string
	return generateUniqueId()
end

-- Register a newly created instance with Tree tracking
-- This helper ensures instances are properly tracked after creation
-- Call this after parenting the instance to Studio
function helpers.registerNewInstance(tree: any, instance: Instance): string
	-- Generate unique ID
	local uniqueId = generateUniqueId()

	-- Set attribute on instance
	UniqueIdHelpers.setUniqueId(instance, uniqueId)

	-- Register in Tree for subsequent operations
	tree:insertInstance(instance, uniqueId, {})

	return uniqueId
end

return helpers
