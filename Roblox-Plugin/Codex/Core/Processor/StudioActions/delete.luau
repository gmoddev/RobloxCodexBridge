--!strict
-- delete: Remove any instance or script

local Codex = script:FindFirstAncestor("Codex")
local Log = require(Codex.Log)
local helpers = require(script.Parent.helpers)
local UniqueIdHelpers = require(Codex.Util.UniqueIdHelpers)

return function(
	self,
	params: { uniqueId: string }
): { status: string, path: string?, robloxClass: string?, error: string? }
	Log.info("[StudioActions.delete] BEGIN - Attempting to delete uniqueId:", params.uniqueId)

	-- Try to get instance from Tree
	local instance = self.tree:getInstance(params.uniqueId)

	if not instance then
		Log.warn("[StudioActions.delete] Instance not found in Tree, uniqueId:", params.uniqueId)
		Log.warn("[StudioActions.delete] Checking if instance exists in Studio by attribute...")

		-- Let's check if any instance in Studio has this uniqueId attribute
		-- This helps us diagnose if the instance exists but isn't in Tree
		local found = false
		for _, service in ipairs(game:GetChildren()) do
			if service:IsA("ServiceProvider") then
				for _, descendant in ipairs(service:GetDescendants()) do
					local id = UniqueIdHelpers.getUniqueId(descendant)
					if id == params.uniqueId then
						Log.error(
							"[StudioActions.delete] FOUND instance in Studio but NOT in Tree!",
							"Instance:",
							descendant:GetFullName(),
							"UniqueId:",
							id
						)
						found = true
						break
					end
				end
			end
			if found then
				break
			end
		end

		if not found then
			Log.warn("[StudioActions.delete] Instance not found anywhere in Studio either")
		end

		return {
			status = "failed",
			error = string.format("Instance not found: %s", params.uniqueId),
		}
	end

	Log.debug("[StudioActions.delete] Found instance in Tree:", instance:GetFullName())

	local path = helpers.getInstancePath(instance)
	local robloxClass = instance.ClassName

	-- Remove from Tree before destroying
	self.tree:removeById(params.uniqueId)

	-- Destroy the instance in Studio
	instance:Destroy()

	Log.info(string.format("[StudioActions.delete] SUCCESS - Deleted %s: %s", robloxClass, path))

	return {
		status = "completed",
		path = path,
		robloxClass = robloxClass,
	}
end
