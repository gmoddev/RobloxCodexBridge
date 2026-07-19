local Codex = script:FindFirstAncestor("Codex")
local Log = require(Codex.Log)
local UniqueIdHelpers = require(Codex.Util.UniqueIdHelpers)
local Helpers = require(script.Parent.Helpers)

local MoveProcessor = {}
MoveProcessor.__index = MoveProcessor

function MoveProcessor.new(parent)
	return setmetatable({
		parent = parent,
		tree = parent.tree,
		ProjectApi = parent.ProjectApi,
	}, MoveProcessor)
end

-- Helper: Extract fields from Change format for processor logic
local function extractFieldsFromChange(change: any): any
	local name = change.name or (change.path and change.path:match("[^/]+$")) or "Unknown"

	-- uniqueId is already a string (Types.Ref)
	local id = change.uniqueId

	-- parentId is already a string (Types.Ref)
	local parent = change.parentId

	return {
		id = id,
		name = name,
		class = change.robloxClass,
		parent = parent,
		path = change.path, -- This is the NEW path (destination)
		oldPath = change.oldPath, -- This is the OLD path (source)
		uniqueId = change.uniqueId,
	}
end

function MoveProcessor:applyMove(change: any, initial: boolean?)
	-- Extract fields from Change format
	local moveSnapshot = extractFieldsFromChange(change)

	Log.debug("[MoveProcessor] Apply move has loaded")
	Log.debug("[MoveProcessor] Full moveSnapshot received:", {
		id = moveSnapshot.id,
		name = moveSnapshot.name,
		class = moveSnapshot.class,
		parent = moveSnapshot.parent,
		path = moveSnapshot.path,
		uniqueId = moveSnapshot.uniqueId,
	})

	-- ID is already a string (Types.Ref)
	local internalSnapshotId = moveSnapshot.id

	local id_str = internalSnapshotId
	Log.debug("[MoveProcessor] Final ID string:", id_str)

	Log.debug(("[WriteProcessor:applyMove] Processing move for ID: %s"):format(id_str))

	-- Pre-operation check: ensure Tree is in a consistent state
	if not self.tree or not self.tree.getInstance then
		Log.error("[MoveProcessor] Tree is not available or corrupted")
		Log.debug("[MoveProcessor] FAILED - Tree corruption detected")
		return
	end

	-- Find the instance to move by ID
	local instance = self.tree:getInstance(internalSnapshotId)

	-- Use consistent path + uniqueId lookup strategy (no fallbacks)
	-- Important: We must search for the instance at its CURRENT (old) location, not the destination
	if not instance and moveSnapshot.uniqueId then
		Log.debug("[MoveProcessor] Tree lookup failed, using path + uniqueId lookup")
		local searchPath = moveSnapshot.oldPath or moveSnapshot.path -- Prefer oldPath for searching
		local targetUniqueId = moveSnapshot.uniqueId

		Log.debug("[MoveProcessor] Searching for uniqueId:", targetUniqueId, "at oldPath:", searchPath)

		for _, inst in ipairs(game:GetDescendants()) do
			if UniqueIdHelpers.getUniqueId(inst) == targetUniqueId then
				instance = inst
				Log.debug("[MoveProcessor] FOUND instance for move:", inst:GetFullName(), "(" .. inst.ClassName .. ")")
				break
			end
		end
	end

	-- Deterministic path lookup when uniqueId mapping is absent; use oldPath if available
	if not instance and (moveSnapshot.oldPath or moveSnapshot.path) then
		local searchPath = moveSnapshot.oldPath or moveSnapshot.path
		Log.debug("[MoveProcessor] Path-only lookup for:", searchPath)
		local function resolveByPath(p: string)
			local firstSlash = string.find(p, "/")
			local serviceName = if firstSlash then string.sub(p, 1, firstSlash - 1) else p
			local current = game:FindFirstChild(serviceName)
			if not current then
				return nil
			end
			if firstSlash then
				local rest = string.sub(p, firstSlash + 1)
				for segment in string.gmatch(rest, "[^/]+") do
					current = current:FindFirstChild(segment)
					if not current then
						return nil
					end
				end
			end
			return current
		end

		local byPath = resolveByPath(searchPath)
		if byPath then
			instance = byPath
			Log.debug("[MoveProcessor] FOUND by path:", byPath:GetFullName())
		end
	end

	if not instance then
		Log.warn(
			"[MoveProcessor] Gracefully skipping move - instance not found. ID: %s, path: %s, uniqueId: %s",
			id_str,
			moveSnapshot.path or "nil",
			moveSnapshot.uniqueId or "nil"
		)
		Log.debug("[MoveProcessor] Gracefully skipped - No instance found")
		return nil
	end

	Log.debug("[MoveProcessor] SUCCESS - Found instance:", instance:GetFullName())
	Log.debug(("[WriteProcessor:applyMove] Found instance to move: %s"):format(instance:GetFullName()))

	-- Get new parent and name from move snapshot
	local newParent = nil
	local newName = moveSnapshot.name or instance.Name

	Log.debug("[MoveProcessor] Target name:", newName)

	-- Check if this is a rename (same parent directory) or actual move
	local sourceParentPath = ""
	if moveSnapshot.sourcePath then
		local sourceParts = {}
		for part in moveSnapshot.sourcePath:gmatch("[^/]+") do
			table.insert(sourceParts, part)
		end
		if #sourceParts > 1 then
			sourceParentPath = table.concat(sourceParts, "/", 1, #sourceParts - 1)
		end
	end

	local destParentPath = ""
	if moveSnapshot.destinationPath or moveSnapshot.path then
		local destParts = {}
		local destPath = moveSnapshot.destinationPath or moveSnapshot.path
		for part in destPath:gmatch("[^/]+") do
			table.insert(destParts, part)
		end
		if #destParts > 1 then
			destParentPath = table.concat(destParts, "/", 1, #destParts - 1)
		end
	end

	Log.debug("[MoveProcessor] Source parent path:", sourceParentPath)
	Log.debug("[MoveProcessor] Dest parent path:", destParentPath)
	Log.debug(
		"DEBUG MoveProcessor: sourceParentPath=",
		sourceParentPath,
		"destParentPath=",
		destParentPath,
		"are equal?",
		sourceParentPath == destParentPath
	)

	if sourceParentPath == destParentPath and sourceParentPath ~= "" then
		-- Same parent directory = rename operation, keep current parent
		newParent = instance.Parent
		Log.debug(
			"[MoveProcessor] Rename detected, keeping current parent:",
			newParent and newParent:GetFullName() or "nil"
		)
	elseif moveSnapshot.parent then
		Log.debug("DEBUG MoveProcessor: Received parent ID:", moveSnapshot.parent, "type:", type(moveSnapshot.parent))
		Log.debug("[MoveProcessor] Looking for parent by:", moveSnapshot.parent, "type:", type(moveSnapshot.parent))

		-- Parent is a string ID (Types.Ref)
		newParent = self.tree:getInstance(moveSnapshot.parent)
		Log.debug(
			"[MoveProcessor DEBUG] Parent lookup by ID result:",
			newParent and newParent:GetFullName() or "NOT_FOUND"
		)

		if not newParent then
			Log.warn(
				"[MoveProcessor] Gracefully skipping move - parent instance not found. Parent ID:",
				moveSnapshot.parent,
				"Instance ID:",
				id_str
			)
			Log.debug("[MoveProcessor] Gracefully skipped - Parent not found for:", moveSnapshot.parent)
			return nil
		end
	elseif destParentPath ~= "" and destParentPath ~= sourceParentPath then
		-- Resolve parent from destination path when parent ID not provided but paths differ
		Log.debug("[MoveProcessor] Resolving parent from destParentPath:", destParentPath)

		local function resolveByPath(p: string)
			local firstSlash = string.find(p, "/")
			local serviceName = if firstSlash then string.sub(p, 1, firstSlash - 1) else p
			local current = game:FindFirstChild(serviceName)
			if not current then
				return nil
			end
			if firstSlash then
				local rest = string.sub(p, firstSlash + 1)
				for segment in string.gmatch(rest, "[^/]+") do
					current = current:FindFirstChild(segment)
					if not current then
						return nil
					end
				end
			end
			return current
		end

		newParent = resolveByPath(destParentPath)
		if not newParent then
			Log.warn("[MoveProcessor] Gracefully skipping move - failed to resolve parent from path:", destParentPath)
			Log.debug("[MoveProcessor] Gracefully skipped - Parent path resolution failed")
			return nil
		end
		Log.debug("[MoveProcessor] Resolved parent from path:", newParent:GetFullName())
	else
		-- Keep current parent if no new parent specified
		newParent = instance.Parent
		Log.debug(
			"[MoveProcessor DEBUG] No parent specified, keeping current:",
			newParent and newParent:GetFullName() or "nil"
		)
	end

	Log.debug("DEBUG MoveProcessor: Final resolved parent:", newParent and newParent:GetFullName() or "nil")
	Log.debug(("[WriteProcessor:applyMove] Target parent: %s"):format(newParent and newParent:GetFullName() or "nil"))
	Log.debug("[MoveProcessor] Final target parent:", newParent and newParent:GetFullName() or "nil")

	-- Pause watcher during the move operation
	if self.parent.watcher then
		Log.debug("[MoveProcessor] Using watcher pause for move operation")
		self.parent.watcher:pause(function()
			-- Update instance name if changed
			if newName and newName ~= instance.Name then
				Log.debug(("[WriteProcessor:applyMove] Updating name from %s to %s"):format(instance.Name, newName))
				Log.debug("[MoveProcessor] Updating name:", instance.Name, "->", newName)
				instance.Name = newName
			end

			-- Move to new parent if different
			if newParent and newParent ~= instance.Parent then
				Log.debug(
					("[WriteProcessor:applyMove] Moving from %s to %s"):format(
						instance.Parent and instance.Parent:GetFullName() or "nil",
						newParent:GetFullName()
					)
				)
				Log.debug("[MoveProcessor] Moving from:", instance.Parent and instance.Parent:GetFullName() or "nil")
				Log.debug("[MoveProcessor] Moving to:", newParent:GetFullName())

				-- Update tree mapping BEFORE the move to preserve ID
				if self.tree.moveInstance then
					Log.debug("[MoveProcessor] Updating tree mapping before move")
					self.tree:moveInstance(instance, internalSnapshotId, true) -- preserveExistingMapping = true
				end

				instance.Parent = newParent
				Log.debug("[MoveProcessor] Move completed - new parent:", instance.Parent:GetFullName())
			else
				Log.debug("[MoveProcessor] No parent change needed")
			end

			Log.debug(("[WriteProcessor:applyMove] Successfully moved %s"):format(instance:GetFullName()))
		end)
	else
		Log.warn("[WriteProcessor:applyMove] No watcher available - move may cause ID mapping issues")
		Log.debug("[MoveProcessor] No watcher available, performing direct move")

		-- Update instance name if changed
		if newName and newName ~= instance.Name then
			Log.debug(("[WriteProcessor:applyMove] Updating name from %s to %s"):format(instance.Name, newName))
			Log.debug("[MoveProcessor] Updating name:", instance.Name, "->", newName)
			instance.Name = newName
		end

		-- Move to new parent if different
		if newParent and newParent ~= instance.Parent then
			Log.debug(
				("[WriteProcessor:applyMove] Moving from %s to %s"):format(
					instance.Parent and instance.Parent:GetFullName() or "nil",
					newParent:GetFullName()
				)
			)
			Log.debug("[MoveProcessor] Moving from:", instance.Parent and instance.Parent:GetFullName() or "nil")
			Log.debug("[MoveProcessor] Moving to:", newParent:GetFullName())

			-- Update tree mapping BEFORE the move to preserve ID
			if self.tree.moveInstance then
				Log.debug("[MoveProcessor] Updating tree mapping before move")
				self.tree:moveInstance(instance, internalSnapshotId, true) -- preserveExistingMapping = true
			end

			instance.Parent = newParent
			Log.debug("[MoveProcessor] Move completed - new parent:", instance.Parent:GetFullName())
		else
			Log.debug("[MoveProcessor] No parent change needed")
		end

		Log.debug(("[WriteProcessor:applyMove] Successfully moved %s"):format(instance:GetFullName()))
	end

	-- Verify that the ID mapping is preserved after the move
	local verifyId = self.tree:getId(instance)
	if verifyId then
		local verifyIdStr = verifyId
		if verifyIdStr == id_str then
			Log.debug(
				("[WriteProcessor:applyMove] ID mapping preserved successfully for: %s"):format(instance:GetFullName())
			)
			Log.debug("[MoveProcessor] ID mapping preserved successfully")
		else
			Log.error(
				("[WriteProcessor:applyMove] ID mapping corruption detected! Expected: %s, Got: %s for: %s"):format(
					id_str,
					verifyIdStr,
					instance:GetFullName()
				)
			)
			Log.error("[MoveProcessor] This indicates Tree state corruption - reconnection may be required")
			Log.debug("[MoveProcessor] ERROR - ID mapping changed! Expected:", id_str, "Got:", verifyIdStr)

			-- For clean operation, we don't attempt repairs - this should not happen with proper state cleanup
			return
		end
	else
		Log.error(("[WriteProcessor:applyMove] Lost ID mapping for moved instance: %s"):format(instance:GetFullName()))
		Log.debug("[MoveProcessor] ERROR - Lost ID mapping for:", instance:GetFullName())
	end

	-- Move completed - ID-based sync will handle database updates
	if not initial then
		Helpers.setWaypoint("Move", instance.Name)
	end

	Log.debug("[MoveProcessor] === MOVE OPERATION COMPLETED ===")
end

return MoveProcessor
