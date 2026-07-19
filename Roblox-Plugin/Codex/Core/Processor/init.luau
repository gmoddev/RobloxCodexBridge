local Codex = script:FindFirstAncestor("Codex")

local Dom = require(Codex.Dom)
local Log = require(Codex.Log)
local Types = require(Codex.Types)

local equals = require(Codex.Helpers.equals)

local Error = require(script.Parent.Error)
local Changes = require(script.Parent.Changes)

-- All processors
local ReadProcessor = require(script.Read)
local WriteProcessor = require(script.Write)

-- Map snapshot paths under `src/` to real Roblox services
local STANDARD_MAPPINGS = {
	["Workspace"] = game.Workspace,
	["ReplicatedStorage"] = game.ReplicatedStorage,
	["ReplicatedFirst"] = game.ReplicatedFirst,
	["StarterPlayer"] = game.StarterPlayer,
	["StarterGui"] = game.StarterGui,
	["StarterPack"] = game.StarterPack,
	["ServerScriptService"] = game.ServerScriptService,
	["ServerStorage"] = game.ServerStorage,
}

local Processor = {}
Processor.__index = Processor

function Processor.new(tree, client)
	local self = {
		tree = tree,
		read = ReadProcessor.new(tree),
		write = WriteProcessor.new(tree, client),
	}

	return setmetatable(self, Processor)
end

-- Simple hydrate that matches existing instances to snapshot IDs
function Processor:hydrate(snapshot: Types.Snapshot, instance: Instance)
	-- Store the instance with the server-provided ID
	self.tree:insertInstance(instance, snapshot.id, snapshot.meta)

	local children = instance:GetChildren()
	local hydrated = table.create(#children, false)

	-- Match snapshot children to Studio children
	for _, snapshotChild in snapshot.children do
		for index, child in children do
			if hydrated[index] then
				continue
			end

			-- Try exact name/class matching
			if child.Name == snapshotChild.name and child.ClassName == snapshotChild.class then
				self:hydrate(snapshotChild, child)
				hydrated[index] = true
				break
			end

			-- Handle service mapping where snapshot has "Folder" but service has specific class
			if child.Name == snapshotChild.name and snapshotChild.class == "Folder" then
				local expectedService = STANDARD_MAPPINGS[snapshotChild.name]
				if expectedService and child == expectedService then
					self:hydrate(snapshotChild, child)
					hydrated[index] = true
					break
				end
			end

			-- Special case: if this is the "src" folder, hydrate services inside it
			if snapshotChild.name == "src" and snapshotChild.children then
				Log.debug("[Processor:hydrate] Found src folder, hydrating services inside it")
				for _, serviceSnapshot in ipairs(snapshotChild.children) do
					local serviceInstance = STANDARD_MAPPINGS[serviceSnapshot.name]
					if serviceInstance then
						Log.debug("[Processor:hydrate] Hydrating service:", serviceSnapshot.name)
						self:hydrate(serviceSnapshot, serviceInstance)
					end
				end
				hydrated[index] = true -- Mark src as processed
				break
			end
		end
	end
end

-- Modified init function - skip DOM comparison to prevent uniqueId regeneration
function Processor:init(snapshot: Types.Snapshot, initialSyncPriority: string): Types.Changes
	Log.trace("Hydrating initial snapshot..")

	self:hydrate(snapshot, game) -- Primary hydration: links existing Studio instances to snapshot IDs in self.tree

	if initialSyncPriority == "None" then
		Log.warn("[Processor:init] No valid sync priority specified")
		return Changes.new("Processor-empty")
	end

	-- REMOVED: DOM comparison logic that was causing uniqueId regeneration
	-- The hydrated snapshot data from the server doesn't contain uniqueId attributes,
	-- so comparing it with Studio instances (which do have uniqueId) always shows differences
	-- and causes unnecessary uniqueId regeneration.
	--
	-- Instead, JSONL comparison should happen at the ProjectManager level by comparing
	-- the locally generated JSONL with the projectStructure stored in the database.
	--
	-- For now, we skip all diffing during initialization to preserve existing uniqueId values.

	Log.trace("[Processor:init] Skipping DOM comparison to preserve uniqueId attributes")
	return Changes.new("Processor-empty")
end

-- Modified diff function (closer to original Codex logic)
function Processor:diff(snapshot: Types.Snapshot, parentRef: Types.Ref, clientPriority: boolean): Types.Changes
	local instance = self.tree:getInstance(snapshot.id)

	local changes = Changes.new("Processor-diff")

	if not instance then
		-- Add using the parent snapshot's Ref
		changes:add(snapshot, parentRef)
		-- Recursively diff children (if any exist in the snapshot being added)
		-- Pass the *new* snapshot's ID as the parent ref for its children
		for _, childSnap in ipairs(snapshot.children or {}) do
			Log.debug("[Processor] *** CALLING changes:join FROM PROCESSOR ADD CASE ***")
			changes:join(self:diff(childSnap, snapshot.id, clientPriority))
		end
		Log.debug(
			string.format(
				"[Processor:diff] END (ADD case) for snapshot: %s Changes: %d total",
				snapshot.name,
				#changes:getChanges()
			)
		)
		return changes
	end

	-- Instance exists, check for class mismatch
	if instance.ClassName ~= snapshot.class then
		Log.debug(
			string.format("[Processor:diff] Class mismatch (%s vs %s) -> REPLACE", instance.ClassName, snapshot.class)
		)
		changes:remove(instance)
		-- Add the new snapshot using the parent snapshot's Ref
		changes:add(snapshot, parentRef)
		-- Recursively diff children of the *new* snapshot
		-- Pass the *new* snapshot's ID as the parent ref for its children
		for _, childSnap in ipairs(snapshot.children or {}) do
			Log.debug("[Processor] *** CALLING changes:join FROM PROCESSOR REPLACE CASE ***")
			changes:join(self:diff(childSnap, snapshot.id, clientPriority))
		end
		Log.debug(
			string.format(
				"[Processor:diff] END (REPLACE class case) for snapshot: %s Changes: %d total",
				snapshot.name,
				#changes:getChanges()
			)
		)
		return changes
	end

	-- Handle property updates (logic remains similar)
	local propertyChangesCount = 0

	-- Previously we skipped property updates for visual instances during initial sync.
	-- That optimisation is no longer required now that only script files are stored in the DB.
	if not clientPriority or ReadProcessor.shouldSyncProperties(instance) then
		local updatedProperties = {}

		--[[ Removed outdated HelloWorld debug traces below
				if snapshot.name == "HelloWorld" then
			if LogConfig.ENABLE_LOGS then
				Log.trace(
					"[Processor:diff TRACE] HelloWorld - Checking properties. ClientPriority:",
					clientPriority,
					"ShouldSync:",
					ReadProcessor.shouldSyncProperties(instance)
				)
			end
		end
		]]
		for property, default in Dom.getDefaultProperties(instance.ClassName) do
			local value = snapshot.properties[property]

			if value then
				local readSuccess, instanceValue = Dom.readProperty(instance, property)

				if not readSuccess then
					local err = Error.new(
						Error.ReadFailed,
						property,
						instance,
						(instanceValue and instanceValue.kind) or "unknown"
					)
					Log.warn(err)
					continue
				end

				local decodeSuccess, snapshotValue = Dom.EncodedValue.decode(value)

				if not decodeSuccess then
					local err = Error.new(Error.DecodeFailed, property, value)
					Log.warn(err)
					continue
				end

				if not equals(instanceValue, snapshotValue) then
					updatedProperties[property] = value
				end
			else
				local readSuccess, instanceValue = Dom.readProperty(instance, property)

				if not readSuccess then
					local err = Error.new(
						Error.ReadFailed,
						property,
						instance,
						(instanceValue and instanceValue.kind) or "unknown"
					)
					Log.warn(err)
					continue
				end

				local _, defaultValue = Dom.EncodedValue.decode(default)

				if not equals(instanceValue, defaultValue) then
					local encodeSuccess, encodedDefault = Dom.EncodedValue.encode(defaultValue, next(default))
					if encodeSuccess then
						updatedProperties[property] = encodedDefault
					else
						Log.warn("Failed to encode default value for property:", property)
					end
				end
			end
		end

		-- Handle content comparison for script instances

		if
			snapshot.content
			and (
				instance.ClassName == "ModuleScript"
				or instance.ClassName == "Script"
				or instance.ClassName == "LocalScript"
			)
		then
			-- Direct content comparison in event-driven architecture
			local contentNeedsUpdate = false
			local studioContent = instance.Source or ""
			local serverContent = snapshot.content

			if studioContent ~= serverContent then
				contentNeedsUpdate = true
			end

			if contentNeedsUpdate then
				-- Add Source to updated properties so it gets included in the update
				updatedProperties.Source = snapshot.content
			end
		end

		-- Create update if we have property changes (including Source/content changes)
		if next(updatedProperties) then
			propertyChangesCount = 0
			for _ in pairs(updatedProperties) do
				propertyChangesCount = propertyChangesCount + 1
			end
			Log.debug("[Processor:diff] Detected " .. propertyChangesCount .. " property updates.")
			changes:update({
				id = snapshot.id,
				properties = updatedProperties,
				meta = snapshot.meta.meshSource and snapshot.meta or nil,
			})
		end
	end -- Close the elseif condition

	-- Handle children diff (closer to original Codex logic)
	local instanceChildren = instance:GetChildren() -- Get actual children from the existing Studio instance
	local snapshotChildrenMap = {} -- Map Ref (string) -> SnapshotChild
	local snapshotChildrenRefs = {} -- Set of Refs (string) present in snapshot children
	for _, childSnap in ipairs(snapshot.children or {}) do
		local childRefStr = childSnap.id
		snapshotChildrenMap[childRefStr] = childSnap
		snapshotChildrenRefs[childRefStr] = true
	end

	Log.debug("[Processor:diff] Snapshot children count:", #snapshot.children)
	Log.debug("[Processor:diff] Actual Studio children count:", #instanceChildren)

	-- Iterate Studio children to find removals and recursively diff existing children
	local removalsDetected = 0
	for _, childInst in ipairs(instanceChildren) do
		local childId = self.tree:getId(childInst)
		if childId then
			local childIdStr = childId
			local childSnap = snapshotChildrenMap[childIdStr]
			if childSnap then
				-- Child exists in both: Recursively diff
				Log.debug("[Processor:diff] Diffing matching child:", childInst:GetFullName())
				Log.debug("[Processor] *** CALLING changes:join FROM PROCESSOR CHILD DIFF ***")
				changes:join(self:diff(childSnap, snapshot.id, clientPriority))
				snapshotChildrenRefs[childIdStr] = nil -- Mark as processed
			else
				-- Child in Studio (and tree) but not in snapshot: Remove
				Log.debug("[Processor:diff] REMOVE detected (tracked child not in snapshot):", childInst:GetFullName())
				changes:remove(childId)
				removalsDetected = removalsDetected + 1
			end
		else
			-- Child in Studio but not tracked by tree: Remove if configured
			if not clientPriority then
				Log.debug("[Processor:diff] REMOVE detected (untracked instance):", childInst:GetFullName())
				changes:remove(childInst) -- Remove the instance itself
				removalsDetected = removalsDetected + 1
			end
		end
	end
	Log.debug("[Processor:diff] Removals detected in Studio pass:", removalsDetected)

	-- Iterate remaining snapshot children (those not matched with Studio children) to find additions
	local additionsDetected = 0
	for childRefStr, _ in pairs(snapshotChildrenRefs) do
		local childSnap = snapshotChildrenMap[childRefStr]
		if childSnap then -- Should always be true here
			Log.debug("[Processor:diff] ADD detected (snapshot child not in Studio/tree):", childSnap.name)
			changes:add(childSnap, snapshot.id) -- Add with current snapshot ID as parent
			additionsDetected = additionsDetected + 1
			-- Recursively diff grandchildren (needed if adding a Folder with contents)
			for _, grandChildSnap in ipairs(childSnap.children or {}) do
				Log.debug("[Processor] *** CALLING changes:join FROM PROCESSOR GRANDCHILD DIFF ***")
				changes:join(self:diff(grandChildSnap, childSnap.id, clientPriority))
			end
		end
	end
	Log.debug("[Processor:diff] Additions detected in Snapshot pass:", additionsDetected)

	Log.debug(
		string.format(
			"[Processor:diff] END (Update/Children case) for snapshot: %s Changes: %d total",
			snapshot.name,
			#changes:getChanges()
		)
	)

	return changes
end

function Processor:reverseChanges(changes: Types.Changes): Types.Changes
	Log.trace("Reversing changes..")

	local reversed = Changes.new("Processor-reversed")
	local changesList = changes:getChanges()

	-- Reverse operations by iterating unified changes
	for _, change in changesList do
		if (change.op == "write" and change.isNew) or change.op == "createInstance" or change.op == "toolboxImport" then
			-- Reverse addition/createInstance/toolboxImport: create delete operation
			reversed:remove(change.uniqueId)
		elseif change.op == "write" and not change.isNew then
			-- Reverse update: read current state and create update back
			local id = change.uniqueId
			local instance = self.tree:getInstance(id)

			if instance then
				local read = self.read:onChange(instance)
				if read then
					reversed:update(read)
				end
			end
		elseif change.op == "delete" or change.op == "deleteInstance" then
			-- Reverse removal: re-add the instance
			local id = change.uniqueId
			local instance = self.tree:getInstance(id)

			if instance then
				local read = self.read:onAdd(instance)
				if read then
					reversed:add(read)
				end
			end
		elseif change.op == "move" then
			-- Reverse move: create move back to original location
			local id = change.uniqueId
			local instance = self.tree:getInstance(id)

			if instance then
				-- Create reversed move as plain Change object
				local reversedMove = {
					op = "move",
					uniqueId = id,
					name = change.name or instance.Name,
					robloxClass = instance.ClassName,
					path = change.oldPath, -- Swap paths for reversal
					oldPath = change.path,
					source = "reversal",
				}

				reversed:move(reversedMove)
			end
		end
	end

	return reversed
end

return Processor
