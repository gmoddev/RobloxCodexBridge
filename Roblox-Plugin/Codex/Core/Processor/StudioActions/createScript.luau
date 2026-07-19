
-- createScript: Create new Script/LocalScript/ModuleScript

local Codex = script:FindFirstAncestor("Codex")
local Log = require(Codex.Log)
local helpers = require(script.Parent.helpers)

return function(
	self,
	params: {
		parentId: string,
		robloxClass: string,
		content: string,
		name: string,
	}
): { status: string, uniqueId: string?, path: string?, error: string? }
	local parent = self.tree:getInstance(params.parentId)
	if not parent then
		return {
			status = "failed",
			error = string.format("Parent instance not found: %s", params.parentId),
		}
	end

	-- Create script instance
	local script
	if params.robloxClass == "Script" then
		script = Instance.new("Script")
	elseif params.robloxClass == "LocalScript" then
		script = Instance.new("LocalScript")
	elseif params.robloxClass == "ModuleScript" then
		script = Instance.new("ModuleScript")
	else
		return {
			status = "failed",
			error = string.format("Invalid robloxClass: %s", params.robloxClass),
		}
	end

	script.Name = params.name
	script.Source = params.content

	-- Parent to Studio
	script.Parent = parent

	-- Register instance with Tree tracking (generates uniqueId, sets attribute, registers in Tree)
	local uniqueId = helpers.registerNewInstance(self.tree, script)

	Log.info(string.format("[StudioActions] Created %s: %s", params.robloxClass, params.name))

	return {
		status = "completed",
		uniqueId = uniqueId,
		path = helpers.getInstancePath(script),
	}
end
