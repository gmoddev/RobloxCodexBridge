
-- updateScript: Update existing script source code

local Codex = script:FindFirstAncestor("Codex")
local Log = require(Codex.Log)
local helpers = require(script.Parent.helpers)

return function(self, params: { uniqueId: string, content: string }): { status: string, path: string?, error: string? }
	local script = self.tree:getInstance(params.uniqueId)
	if not script or not script:IsDescendantOf(game) then
		-- Clean up stale tree entry if instance was deleted outside of agent
		if script and not script:IsDescendantOf(game) then
			self.tree:removeByInstance(script)
		end
		return {
			status = "failed",
			error = string.format("Script not found: %s", params.uniqueId),
		}
	end

	if not script:IsA("LuaSourceContainer") then
		return {
			status = "failed",
			error = string.format("Instance is not a script: %s", params.uniqueId),
		}
	end

	script.Source = params.content

	Log.info(string.format("[StudioActions] Updated script: %s", script.Name))

	return {
		status = "completed",
		path = helpers.getInstancePath(script),
	}
end
