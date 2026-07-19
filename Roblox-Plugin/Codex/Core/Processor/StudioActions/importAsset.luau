
-- importAsset: Import Roblox Toolbox asset by ID

local Codex = script:FindFirstAncestor("Codex")
local Log = require(Codex.Log)
local helpers = require(script.Parent.helpers)

return function(
	self,
	params: {
		parentId: string,
		assetId: number,
		name: string,
	}
): {
	status: string,
	uniqueId: string?,
	path: string?,
	robloxClass: string?,
	childCount: number?,
	error: string?,
}
	local parent = self.tree:getInstance(params.parentId)
	if not parent then
		return {
			status = "failed",
			error = string.format("Parent instance not found: %s", params.parentId),
		}
	end

	-- Load asset from Toolbox using game:GetObjects (more reliable than InsertService:LoadAsset)
	-- GetObjects works for public assets regardless of ownership, while LoadAsset requires same owner
	local success, result = pcall(function()
		return game:GetObjects("rbxassetid://" .. params.assetId)
	end)

	if not success then
		return {
			status = "failed",
			error = string.format("Failed to load asset %d: %s", params.assetId, tostring(result)),
		}
	end

	local instances = result
	if not instances or #instances == 0 then
		return {
			status = "failed",
			error = "Asset returned no instances",
		}
	end

	-- Get root instance (handle single instance or multiple instances)
	local rootInstance
	if #instances == 1 then
		rootInstance = instances[1]
	else
		-- Multiple instances - wrap in a Model
		local model = Instance.new("Model")
		model.Name = params.name
		for _, inst in ipairs(instances) do
			inst.Parent = model
		end
		rootInstance = model
	end

	if not rootInstance then
		return {
			status = "failed",
			error = "Failed to get root instance from asset",
		}
	end

	-- Rename and reparent
	rootInstance.Name = params.name
	rootInstance.Parent = parent

	-- Register instance with Tree tracking (generates uniqueId, sets attribute, registers in Tree)
	local uniqueId = helpers.registerNewInstance(self.tree, rootInstance)

	-- Filter out and delete scripts from imported assets (protect users / leave coding to Codex)
	local scriptsRemoved = 0
	for _, descendant in rootInstance:GetDescendants() do
		if descendant:IsA("LuaSourceContainer") then
			-- Delete scripts (Script, LocalScript, ModuleScript)
			descendant:Destroy()
			scriptsRemoved = scriptsRemoved + 1
		else
			-- Register non-script instances so agent can interact with imported asset parts
			helpers.registerNewInstance(self.tree, descendant)
		end
	end

	if scriptsRemoved > 0 then
		Log.warn(string.format("[StudioActions] Removed %d script(s) from imported asset for security", scriptsRemoved))
	end

	-- Count children
	local childCount = #rootInstance:GetDescendants()

	-- No cleanup needed - GetObjects returns instances directly (no wrapper to destroy)

	Log.info(string.format("[StudioActions] Imported asset %d: %s", params.assetId, params.name))

	return {
		status = "completed",
		uniqueId = uniqueId,
		path = helpers.getInstancePath(rootInstance),
		robloxClass = rootInstance.ClassName,
		childCount = childCount > 0 and childCount or nil,
	}
end
