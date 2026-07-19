local HttpService = game:GetService("HttpService")

local Codex = script:FindFirstAncestor("Codex")
local Types = require(Codex.Types)
local Log = require(Codex.Log)
local Dom = require(Codex.Dom)
local Error = require(Codex.Core.Error)
local UniqueIdHelpers = require(Codex.Util.UniqueIdHelpers)
local Helpers = require(script.Parent.Helpers)

local RemovalProcessor = {}
RemovalProcessor.__index = RemovalProcessor

function RemovalProcessor.new(parent)
	return setmetatable({
		parent = parent,
		tree = parent.tree,
		ProjectApi = parent.ProjectApi,
	}, RemovalProcessor)
end

function RemovalProcessor:applyRemoval(
	object: Types.Ref | Instance | Types.RemovalPayload,
	initial: boolean?
): Instance?
	local id_to_lookup: Types.Ref
	local original_object_for_log = object -- For logging the original input
	local id_str_for_logs: string -- For consistent logging of the ID string form

	if typeof(object) == "Instance" then
		Log.debug("[WriteProcessor:applyRemoval] Received Instance for removal:", object:GetFullName())
		local id_from_tree = self.tree:getId(object)
		if not id_from_tree then
			Log.warn(
				"[WriteProcessor:applyRemoval] Could not get ID from Tree for instance:",
				object:GetFullName(),
				". Cannot reliably remove by ID from tree if it was by Ref. Instance will be removed from hierarchy if possible."
			)
			-- Create a dummy ID string; this instance won't be found by ID in the tree if it wasn't there.
			-- The goal is to primarily remove the passed 'object' (Instance) from the hierarchy.
			-- Tree removal will be a no-op for this dummy ID.
			id_to_lookup = "FALLBACK_NO_ID_FOR_INSTANCE_" .. HttpService:GenerateGUID(false)
			id_str_for_logs = "ID_UNKNOWN_FROM_TREE"
		else
			id_to_lookup = id_from_tree
			id_str_for_logs = id_to_lookup
		end
	elseif type(object) == "string" then
		id_to_lookup = object
		id_str_for_logs = id_to_lookup
		Log.debug("[WriteProcessor:applyRemoval] Received string Ref for removal. ID:", id_str_for_logs)
	elseif type(object) == "table" and object.uniqueId and object.path then
		-- Change format with path + uniqueId info
		Log.debug("[RemovalProcessor DEBUG] Received Change with path:", object.path, "uniqueId:", object.uniqueId)
		-- Change format: uniqueId is already a string
		id_to_lookup = object.uniqueId
		id_str_for_logs = object.uniqueId
	else
		Log.error(
			"[WriteProcessor:applyRemoval] Invalid object type for removal. Expected Instance, string Ref, or RemovalPayload, got:",
			typeof(object),
			"Value:",
			object
		)
		return nil
	end

	-- <<< LOGGING FOR ID USED IN LOOKUP >>>
	Log.debug("[WriteProcessor:applyRemoval] Using ID for lookup:", id_str_for_logs)

	local instance: Instance?
	if typeof(object) == "Instance" then
		instance = object -- Already have the instance if input was an Instance
	elseif type(object) == "table" and object.uniqueId and object.path then
		-- Use consistent path + uniqueId lookup strategy (no fallbacks)
		Log.debug("[RemovalProcessor] Using path + uniqueId lookup for removal")
		local targetPath = object.path
		local targetUniqueId = object.uniqueId

		Log.debug("  - Searching for path:", targetPath, "AND uniqueId:", targetUniqueId)

		for _, inst in ipairs(game:GetDescendants()) do
			if UniqueIdHelpers.getUniqueId(inst) == targetUniqueId then
				local instancePath = inst:GetFullName():gsub("^game%.", ""):gsub("%.([^%.]+)$", "/%1"):gsub("%.", "/")
				if instancePath == targetPath then
					instance = inst
					Log.debug("  - FOUND instance for removal:", inst:GetFullName(), "(" .. inst.ClassName .. ")")
					break
				end
			end
		end

		if not instance then
			Log.debug("  - NO INSTANCE FOUND for removal with path:", targetPath, "AND uniqueId:", targetUniqueId)
		end
	else
		instance = self.tree:getInstance(id_to_lookup) -- Legacy tree lookup for string ID cases
	end

	local _instanceNameForLogs: string = instance and instance:GetFullName()
		or ("Ref (string form): " .. id_str_for_logs)

	if not instance then
		-- Gracefully skip removal if instance not found (may have been deleted already)
		Log.warn("[RemovalProcessor] Gracefully skipping removal - instance not found. ID:", id_str_for_logs)
		return nil
	end

	-- If we got here, 'instance' is valid (either passed directly or found by ID Ref).
	Log.debug(
		"[WriteProcessor:applyRemoval] Instance to be processed for removal:",
		instance:GetFullName(),
		"(Class:",
		instance.ClassName,
		") linked to ID (string form):",
		id_str_for_logs
	)

	-- Remove from tree map
	-- If original object was an Instance, remove by that Instance (handles if its ID changed or wasn't in tree correctly)
	-- If original object was a string ID (id_to_lookup should be this string)
	if typeof(original_object_for_log) == "Instance" then
		Log.debug(
			"[WriteProcessor:applyRemoval] Original object was Instance, removing from tree by instance:",
			instance:GetFullName()
		)
		self.tree:removeByInstance(instance) -- This uses the instance's current ID in the tree
	else
		Log.debug(
			"[WriteProcessor:applyRemoval] Original object was string ID, removing from tree by ID:",
			id_str_for_logs
		)
		self.tree:removeById(id_to_lookup)
	end

	if not Dom.isCreatable(instance.ClassName) then
		Log.warn(Error.new(Error.NotRemovable, instance.ClassName))
		Log.warn(
			("[WriteProcessor WARNING] Instance %s (%s) is not creatable (e.g., a service). Removed from Tree, but skipping removal from Studio hierarchy."):format(
				instance:GetFullName(),
				instance.ClassName
			)
		)
		if not initial then
			Helpers.setWaypoint("Remove (from Tree, service skipped)", instance.Name)
		end
		return instance -- Return the service instance, as it's still in the game
	end

	local removalSuccess = false -- Initialize removalSuccess for this specific instance removal operation

	-- Actual removal from Studio hierarchy
	if instance and instance.Parent then
		-- Pause watcher for removal operations
		if self.parent.watcher then
			self.parent.watcher:pause(function()
				local nilParentFunc = function()
					instance.Parent = nil
				end
				local success, _ = pcall(nilParentFunc)
				if not success then
					local destroyInstanceFunc = function()
						instance:Destroy()
					end
					local destroySuccess, _ = pcall(destroyInstanceFunc)
					if destroySuccess then
						removalSuccess = true -- Considered success if Destroy works
					end
				else
					removalSuccess = true
				end
			end)
		else
			local nilParentFunc = function()
				instance.Parent = nil
			end
			local success, _ = pcall(nilParentFunc)
			if not success then
				local destroyInstanceFunc = function()
					instance:Destroy()
				end
				local destroySuccess, _ = pcall(destroyInstanceFunc)
				if destroySuccess then
					removalSuccess = true -- Considered success if Destroy works
				end
			else
				removalSuccess = true
			end
		end
	else
		removalSuccess = true -- Considered success if already gone
	end

	if not initial then
		if removalSuccess then
			Helpers.setWaypoint("Remove", (instance :: Instance).Name)
		end
	end

	-- Removal status tracked in removalSuccess variable
	return instance
end

return RemovalProcessor
