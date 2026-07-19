
-- move: Relocate or rename any instance or script

local Codex = script:FindFirstAncestor("Codex")
local Log = require(Codex.Log)
local helpers = require(script.Parent.helpers)

return function(
	self,
	params: {
		uniqueId: string,
		newParentId: string,
		newName: string?,
	}
): { status: string, oldPath: string?, newPath: string?, error: string? }
	local instance = self.tree:getInstance(params.uniqueId)
	if not instance then
		return {
			status = "failed",
			error = string.format("Instance not found: %s", params.uniqueId),
		}
	end

	local oldPath = helpers.getInstancePath(instance)

	-- Rename if newName provided
	if params.newName then
		instance.Name = params.newName
	end

	-- Move to new parent
	local newParent = self.tree:getInstance(params.newParentId)
	if not newParent then
		return {
			status = "failed",
			error = string.format("New parent not found: %s", params.newParentId),
		}
	end

	instance.Parent = newParent

	local newPath = helpers.getInstancePath(instance)

	Log.info(string.format("[StudioActions] Moved/Renamed: %s -> %s", oldPath, newPath))

	return {
		status = "completed",
		oldPath = oldPath,
		newPath = newPath,
	}
end
