--!native
local Codex = script:FindFirstAncestor("Codex")

local Types = require(Codex.Types)
local Log = require(Codex.Log)
local UniqueIdHelpers = require(Codex.Util.UniqueIdHelpers)

-- Root services walked on slow-path uniqueId resolution and during
-- populate. Mirrors the list seeded in Tree:registerServices.
local STANDARD_SERVICE_NAMES = {
	"Workspace",
	"StarterPlayer",
	"ServerScriptService",
	"StarterGui",
	"ServerStorage",
	"ReplicatedStorage",
	"StarterPack",
	"ReplicatedFirst",
}

local Tree = {}
Tree.__index = Tree

function Tree.new()
	local self = {
		instanceMap = {},
		metaMap = {},
		idMap = {},
		timestampMap = {},
	}

	setmetatable(self, Tree)

	-- Register all Roblox services immediately with VM-compatible IDs
	self:registerServices()

	return self
end

function Tree:registerServices()
	-- Predefined service IDs matching VM (from storage.ts)
	local services = {
		{ name = "Workspace", id = "ws1" },
		{ name = "StarterPlayer", id = "sp1" },
		{ name = "ServerScriptService", id = "sss" },
		{ name = "StarterGui", id = "sg1" },
		{ name = "ServerStorage", id = "ss1" },
		{ name = "ReplicatedStorage", id = "rs1" },
		{ name = "StarterPack", id = "spk" },
		{ name = "ReplicatedFirst", id = "rf1" },
	}

	for _, svc in ipairs(services) do
		local success, service = pcall(game.GetService, game, svc.name)
		if success and service then
			-- Remove any existing mapping for this service (in case it has a different ID)
			local existingId = self:getId(service)
			if existingId then
				self:removeById(existingId)
				Log.debug("[Tree] Removed old ID mapping for", svc.name, "- old ID:", existingId)
			end

			self:insertInstance(service, svc.id, {})
			UniqueIdHelpers.setUniqueId(service, svc.id)
			Log.debug("[Tree] Registered service:", svc.name, "with ID:", svc.id)
		end
	end

	-- Register child services under StarterPlayer
	local starterPlayer = game:GetService("StarterPlayer")
	local childServices = {
		{ parent = starterPlayer, name = "StarterPlayerScripts", id = "sps" },
		{ parent = starterPlayer, name = "StarterCharacterScripts", id = "scs" },
	}

	for _, child in ipairs(childServices) do
		local instance = child.parent:FindFirstChild(child.name)
		if instance then
			-- Remove any existing mapping for this instance (in case it has a different ID)
			local existingId = self:getId(instance)
			if existingId then
				self:removeById(existingId)
				Log.debug("[Tree] Removed old ID mapping for", child.name, "- old ID:", existingId)
			end

			self:insertInstance(instance, child.id, {})
			UniqueIdHelpers.setUniqueId(instance, child.id)
			Log.debug("[Tree] Registered child service:", child.name, "with ID:", child.id)
		end
	end

	-- Register default Workspace instances so agents can see and interact with them
	local workspace = game:GetService("Workspace")
	local defaultWorkspaceInstances = {
		{ name = "Camera", className = "Camera", id = "default_camera" },
		{ name = "Terrain", className = "Terrain", id = "default_terrain" },
		{ name = "SpawnLocation", className = "SpawnLocation", id = "default_spawnlocation" },
		{ name = "Baseplate", className = "Part", id = "default_baseplate" },
	}

	for _, obj in ipairs(defaultWorkspaceInstances) do
		local instance = workspace:FindFirstChild(obj.name)
		-- Verify it matches expected class
		if instance and instance:IsA(obj.className) then
			-- Check if it already has a uniqueId (e.g., from previous sync or user creation)
			local existingId = UniqueIdHelpers.getUniqueId(instance)
			if not existingId then
				-- Assign stable default ID
				self:insertInstance(instance, obj.id, {})
				UniqueIdHelpers.setUniqueId(instance, obj.id)
				Log.debug("[Tree] Registered default Workspace instance:", obj.name, "with ID:", obj.id)
			else
				-- Already has ID, just register in Tree
				self:insertInstance(instance, existingId, {})
				Log.debug("[Tree] Registered existing Workspace instance:", obj.name, "with ID:", existingId)
			end
		end
	end

	-- Register known default children of Workspace instances
	local spawnLocation = workspace:FindFirstChild("SpawnLocation")
	if spawnLocation then
		local decal = spawnLocation:FindFirstChild("Decal")
		if decal and decal:IsA("Decal") then
			local existingId = UniqueIdHelpers.getUniqueId(decal)
			if not existingId then
				self:insertInstance(decal, "default_spawn_decal", {})
				UniqueIdHelpers.setUniqueId(decal, "default_spawn_decal")
				Log.debug("[Tree] Registered SpawnLocation.Decal with ID: default_spawn_decal")
			else
				self:insertInstance(decal, existingId, {})
				Log.debug("[Tree] Registered existing SpawnLocation.Decal with ID:", existingId)
			end
		end
	end

	local baseplate = workspace:FindFirstChild("Baseplate")
	if baseplate then
		-- Baseplate often has a Texture child
		local texture = baseplate:FindFirstChild("Texture")
		if texture and texture:IsA("Texture") then
			local existingId = UniqueIdHelpers.getUniqueId(texture)
			if not existingId then
				self:insertInstance(texture, "default_baseplate_texture", {})
				UniqueIdHelpers.setUniqueId(texture, "default_baseplate_texture")
				Log.debug("[Tree] Registered Baseplate.Texture with ID: default_baseplate_texture")
			else
				self:insertInstance(texture, existingId, {})
				Log.debug("[Tree] Registered existing Baseplate.Texture with ID:", existingId)
			end
		end
	end

	-- Register additional game services for agent interaction
	local additionalGameServices = {
		{ name = "Players", id = "ply" },
		{ name = "Lighting", id = "lit" },
		{ name = "Teams", id = "tms" },
		{ name = "SoundService", id = "snd" },
		{ name = "CollectionService", id = "col" },
	}

	for _, svc in ipairs(additionalGameServices) do
		local success, service = pcall(game.GetService, game, svc.name)
		if success and service then
			-- Check if it already has a uniqueId
			local existingId = UniqueIdHelpers.getUniqueId(service)
			if not existingId then
				self:insertInstance(service, svc.id, {})
				UniqueIdHelpers.setUniqueId(service, svc.id)
				Log.debug("[Tree] Registered game service:", svc.name, "with ID:", svc.id)
			else
				-- Already has ID, just register in Tree
				self:insertInstance(service, existingId, {})
				Log.debug("[Tree] Registered existing game service:", svc.name, "with ID:", existingId)
			end
		end
	end
end

function Tree:insertInstance(instance: Instance, uniqueId: Types.Ref, meta: Types.Meta, timestamp: number?)
	-- uniqueId is Types.Ref (string) - the unique identifier for this instance

	Log.debug(
		"[Tree.insertInstance] BEGIN - Instance:",
		instance:GetFullName(),
		"UniqueId:",
		uniqueId,
		"ClassName:",
		instance.ClassName
	)

	-- Ensure any existing mappings for this instance or ID are cleared if re-inserting/updating implicitly
	local existing_id_for_instance = self.idMap[instance]
	if existing_id_for_instance and existing_id_for_instance ~= uniqueId then
		Log.debug("[Tree.insertInstance] Clearing old ID mapping:", existing_id_for_instance, "-> new:", uniqueId)
		self.instanceMap[existing_id_for_instance] = nil -- Clear old ID from instanceMap
		self.metaMap[existing_id_for_instance] = nil -- Clear old meta
	end

	local existing_instance_for_id = self.instanceMap[uniqueId]
	if existing_instance_for_id and existing_instance_for_id ~= instance then
		Log.debug(
			"[Tree.insertInstance] Replacing existing instance for ID:",
			uniqueId,
			"Old:",
			existing_instance_for_id:GetFullName(),
			"New:",
			instance:GetFullName()
		)
		self.idMap[existing_instance_for_id] = nil -- Clear old instance from idMap
	end

	Log.trace("[Tree.insertInstance] Storing instance:", instance:GetFullName(), "with uniqueId:", uniqueId)
	self.instanceMap[uniqueId] = instance
	self.idMap[instance] = uniqueId

	self:insertMeta(uniqueId, meta)
	-- Store timestamp if provided
	if timestamp then
		self:setTimestamp(uniqueId, timestamp)
	end

	Log.debug("[Tree.insertInstance] SUCCESS - Registered:", instance:GetFullName(), "with ID:", uniqueId)
end

function Tree:updateInstance(uniqueId: Types.Ref, instance: Instance, timestamp: number?)
	-- uniqueId is Types.Ref (string)
	local old_instance = self.instanceMap[uniqueId]

	if not old_instance then
		Log.warn(
			"[Tree.updateInstance] No old instance found for ID:",
			uniqueId,
			"while trying to update to:",
			instance:GetFullName(),
			". This might be an add disguised as update or a new ID."
		)
		-- To be safe, if it's not found, maybe this should be an insert? Or log and skip.
		-- For now, we'll proceed assuming the intent is to map this new instance to this ID.
	end

	if old_instance then
		self.idMap[old_instance] = nil -- Remove old instance's reverse mapping
	end

	self.instanceMap[uniqueId] = instance
	self.idMap[instance] = uniqueId
	-- Update timestamp if provided
	if timestamp then
		self:setTimestamp(uniqueId, timestamp)
	end
end

function Tree:getId(instance: Instance): Types.Ref?
	-- Retrieve the stored uniqueId string for the instance
	if instance == game then
		Log.warn("[Tree.getId DEBUG FOR GAME] Trying to get ID for game instance.")
		local mappedId = self.idMap[instance]
		Log.warn("[Tree.getId DEBUG FOR GAME] ID from self.idMap[game]:", mappedId or "nil")
	end

	return self.idMap[instance]
end

-- Walk descendants of standard root services for an instance whose
-- CodexUniqueID attribute matches uniqueId. Used as the slow-path
-- fallback in getInstance when instanceMap misses, so any id glob can
-- see (glob reads the attribute live) is also resolvable by the read
-- endpoints (which only check instanceMap).
function Tree:_findInstanceByAttributeWalk(uniqueId: Types.Ref): Instance?
	for _, serviceName in ipairs(STANDARD_SERVICE_NAMES) do
		local ok, service = pcall(game.GetService, game, serviceName)
		if not ok or not service then
			continue
		end
		for _, descendant in ipairs(service:GetDescendants()) do
			if UniqueIdHelpers.getUniqueId(descendant) == uniqueId then
				return descendant
			end
		end
	end
	return nil
end

function Tree:getInstance(uniqueId: Types.Ref): Instance?
	-- uniqueId is Types.Ref (string)
	if uniqueId == "YWZmcnZiOTI4dXQ0NGE1enNkeGc0Nmp4L3Jvb3Q=" then -- PROJECT_ROOT_ID_PLACEHOLDER
		Log.warn("[Tree.getInstance DEBUG FOR GAME ID] Trying to get instance for root project ID string:", uniqueId)
		local foundInstance = self.instanceMap[uniqueId]
		Log.warn(
			"[Tree.getInstance DEBUG FOR GAME ID] Found instance:",
			foundInstance,
			(foundInstance == game and "(it IS game)" or "(it IS NOT game)")
		)
	end

	Log.trace("[Tree.getInstance] Looking up instance with uniqueId:", uniqueId)
	local instance = self.instanceMap[uniqueId]

	if instance then
		Log.debug("[Tree.getInstance] FOUND - UniqueId:", uniqueId, "-> Instance:", instance:GetFullName())
		return instance
	end

	-- Slow path: instanceMap miss can happen when an instance has the
	-- CodexUniqueID attribute stamped but never made it into the
	-- map — duplicate-id collision dropped during populate, missed
	-- Watcher event, etc. Walk and self-heal so subsequent reads hit
	-- the fast path.
	local recovered = self:_findInstanceByAttributeWalk(uniqueId)
	if recovered then
		Log.warn(
			"[Tree.getInstance] map miss but attribute walk recovered:",
			uniqueId,
			"->",
			recovered:GetFullName(),
			"(registering for fast-path)"
		)
		self:insertInstance(recovered, uniqueId, {})
		return recovered
	end

	Log.warn("[Tree.getInstance] NOT FOUND - UniqueId:", uniqueId, "not in Tree (attribute walk also missed)")
	return nil
end

function Tree:removeByInstance(instance: Instance): Types.Ref?
	local uniqueId = self.idMap[instance]

	if not uniqueId then
		return nil
	end

	self.instanceMap[uniqueId] = nil
	self.idMap[instance] = nil

	self:removeMeta(uniqueId)
	self:removeTimestamp(uniqueId)

	return uniqueId
end

function Tree:removeById(uniqueId: Types.Ref): Instance?
	-- uniqueId is Types.Ref (string)
	Log.debug("[Tree.removeById] BEGIN - Attempting to remove uniqueId:", uniqueId)

	local instance = self.instanceMap[uniqueId]

	if not instance then
		Log.warn("[Tree.removeById] FAILED - UniqueId not found in Tree:", uniqueId)
		return nil
	end

	Log.debug("[Tree.removeById] Found instance:", instance:GetFullName(), "- removing from Tree")

	self.instanceMap[uniqueId] = nil
	self.idMap[instance] = nil

	self:removeMeta(uniqueId)
	self:removeTimestamp(uniqueId)

	Log.debug("[Tree.removeById] SUCCESS - Removed:", instance:GetFullName(), "with ID:", uniqueId)

	return instance
end

function Tree:insertMeta(uniqueId: Types.Ref, meta: Types.Meta)
	self.metaMap[uniqueId] = meta
end

function Tree:getMeta(uniqueId: Types.Ref): Types.Meta?
	return self.metaMap[uniqueId]
end

function Tree:updateMeta(uniqueId: Types.Ref, meta: Types.Meta)
	local old = self.metaMap[uniqueId]

	if not old then
		return
	end

	self.metaMap[uniqueId] = meta
end

function Tree:removeMeta(uniqueId: Types.Ref): Types.Meta?
	local meta = self.metaMap[uniqueId]
	self.metaMap[uniqueId] = nil
	return meta
end

function Tree:changeInstanceId(instance: Instance, oldId: Types.Ref, newId: Types.Ref)
	if oldId == newId then
		Log.debug("[Tree:changeInstanceId] No change needed, IDs are the same:", oldId)
		return -- No change needed
	end

	Log.debug("[Tree:changeInstanceId] Updating ID for instance:", instance:GetFullName())
	Log.debug("  - Old ID:", oldId)
	Log.debug("  - New ID:", newId)

	-- Check if the instance provided is indeed currently mapped to oldId
	if self.idMap[instance] ~= oldId then
		Log.warn(
			string.format(
				"[Tree:changeInstanceId] Instance '%s' current ID '%s' does not match expected old ID '%s'. Proceeding cautiously.",
				instance:GetFullName(),
				self.idMap[instance] or "nil",
				oldId
			)
		)
	end

	-- Remove old ID mapping
	self.instanceMap[oldId] = nil

	-- Update instance to new ID mapping
	self.idMap[instance] = newId
	self.instanceMap[newId] = instance

	-- Move meta
	local meta = self.metaMap[oldId]
	self.metaMap[oldId] = nil
	if meta then
		self.metaMap[newId] = meta
	end

	-- Move timestamp
	local ts = self.timestampMap[oldId]
	self.timestampMap[oldId] = nil
	if ts then
		self.timestampMap[newId] = ts
	end

	Log.debug("[Tree:changeInstanceId] Successfully updated ID mapping for:", instance:GetFullName())
end

-- Timestamp specific methods
function Tree:setTimestamp(uniqueId: Types.Ref, timestamp: number)
	self.timestampMap[uniqueId] = timestamp
end

function Tree:getTimestamp(uniqueId: Types.Ref): number?
	return self.timestampMap[uniqueId]
end

function Tree:removeTimestamp(uniqueId: Types.Ref): number?
	local ts = self.timestampMap[uniqueId]
	self.timestampMap[uniqueId] = nil
	return ts
end

-- Method to be called by Watcher when a tracked instance changes
function Tree:notifyInstanceChanged(instance: Instance, property: string)
	Log.trace(
		string.format(
			"[Tree.notifyInstanceChanged] Received notification for instance: %s, property: %s",
			instance:GetFullName(),
			property
		)
	)
	-- Check if this instance is actually tracked by the tree
	if self.idMap[instance] then
		Log.trace("[Tree.notifyInstanceChanged] Instance is tracked.")
	else
		Log.trace("[Tree.notifyInstanceChanged] Instance is NOT tracked. No action taken.")
	end
end

function Tree:moveInstance(instance: Instance, newId: Types.Ref?, preserveExistingMapping: boolean?)
	-- This method handles moving an instance while preserving its ID mapping
	-- If preserveExistingMapping is true, we keep the existing ID instead of using newId

	local existingId = self:getId(instance)

	if preserveExistingMapping and existingId then
		-- Instance is being moved but should keep its existing ID
		Log.debug("[Tree:moveInstance] Preserving existing ID for moved instance:", instance:GetFullName())

		return existingId
	elseif newId then
		-- Standard move with new ID
		if existingId then
			-- Remove old mapping
			self:removeByInstance(instance)
		end

		-- Insert with new ID
		self.instanceMap[newId] = instance
		self.idMap[instance] = newId

		Log.debug("[Tree:moveInstance] Moved instance to new ID:", newId)
		return newId
	else
		Log.warn("[Tree:moveInstance] No ID provided and preserveExistingMapping not set")
		return existingId
	end
end

function Tree:updateIdMapping(clientTemporaryIdString: string, newServerIdString: string)
	Log.info(
		"[Tree.updateIdMapping] Attempting to update ID mapping. Old/Client ID:",
		clientTemporaryIdString,
		"New/Server ID:",
		newServerIdString
	)

	-- CORRUPTION PREVENTION: Validate that the server ID is not a path
	if newServerIdString and (string.find(newServerIdString, "/") or string.len(newServerIdString) > 10) then
		Log.error(
			"[Tree.updateIdMapping] CORRUPTION DETECTED: Server returned path as ID instead of uniqueId!",
			"ServerID:",
			newServerIdString,
			"ClientID:",
			clientTemporaryIdString
		)
		Log.error("[Tree.updateIdMapping] This indicates a backend bug - server should return uniqueId, not path")
		Log.error("[Tree.updateIdMapping] Refusing to update mapping to prevent Tree corruption")
		return -- Refuse to corrupt the Tree with path-based IDs
	end

	local instance = self.instanceMap[clientTemporaryIdString]

	if instance then
		Log.trace("[Tree.updateIdMapping] Instance found for client ID:", instance:GetFullName())

		-- Clear old mappings
		self.instanceMap[clientTemporaryIdString] = nil

		-- If meta and timestamp maps use string IDs directly, update them here.
		-- Tree now uses string IDs directly.
		-- For simplicity and assuming string IDs are primary keys for these maps now:
		local oldMeta = self.metaMap[clientTemporaryIdString]
		if oldMeta then
			self.metaMap[clientTemporaryIdString] = nil
			self.metaMap[newServerIdString] = oldMeta
			Log.trace("[Tree.updateIdMapping] Transferred meta to new server ID.")
		end

		local oldTimestamp = self.timestampMap[clientTemporaryIdString]
		if oldTimestamp then
			self.timestampMap[clientTemporaryIdString] = nil
			self.timestampMap[newServerIdString] = oldTimestamp
			Log.trace("[Tree.updateIdMapping] Transferred timestamp to new server ID.")
		end

		-- Set new mappings
		self.instanceMap[newServerIdString] = instance
		self.idMap[instance] = newServerIdString

		Log.info(
			"[Tree.updateIdMapping] Successfully updated ID for instance:",
			instance:GetFullName(),
			"New ID:",
			newServerIdString
		)
	else
		Log.warn(
			"[Tree.updateIdMapping] No instance found for clientTemporaryIdString:",
			clientTemporaryIdString,
			"Cannot update to newServerIdString:",
			newServerIdString
		)
	end
end

-- Reset Tree to completely clean state for reconnection
function Tree:resetState()
	Log.debug("[Tree:resetState] Resetting Tree to clean state...")

	-- Clear all mappings
	self.instanceMap = {}
	self.idMap = {}
	self.metaMap = {}
	self.timestampMap = {}

	-- Re-register services after reset
	self:registerServices()

	Log.debug("[Tree:resetState] Tree state reset completed, services re-registered")
end

-- Populate Tree with all existing instances from registered root services
-- This is used when connecting to an existing project to make all instances discoverable
function Tree:populateExistingInstances(rootInstances: { Instance })
	local generateUniqueId = require(script.Parent.Parent.Helpers.generateUniqueId)

	-- Use GetDescendants() for efficient single-pass traversal
	-- This is much faster than recursive GetChildren() calls
	local allInstances = {}
	for _, rootInstance in ipairs(rootInstances) do
		local descendants = rootInstance:GetDescendants()
		for _, instance in ipairs(descendants) do
			table.insert(allInstances, instance)
		end
	end

	-- Performance optimization: Process instances in batches with yielding
	-- to prevent Studio freezing on low-end machines with large projects
	local BATCH_SIZE = 250 -- Yield every N instances to keep Studio responsive

	-- Register all instances with periodic yielding
	for i, instance in ipairs(allInstances) do
		-- Check if instance already has a uniqueId (from previous sync or Watcher)
		local existingId = UniqueIdHelpers.getUniqueId(instance)

		if existingId then
			local mapped = self.instanceMap[existingId]
			if not mapped then
				self:insertInstance(instance, existingId, {})
			elseif mapped ~= instance then
				-- Two instances claim the same CodexUniqueID — typical
				-- causes are model copy/paste, asset import, or undo +
				-- re-create. Without re-stamping, this instance would be
				-- glob-visible (its attribute is set) but unreadable
				-- (instanceMap already maps the id to `mapped`).
				local newId = generateUniqueId()
				Log.warn(
					"[Tree.populateExistingInstances] Duplicate CodexUniqueID collision",
					"id=" .. existingId,
					"kept=" .. mapped:GetFullName(),
					"re-stamped=" .. instance:GetFullName(),
					"newId=" .. newId
				)
				UniqueIdHelpers.setUniqueId(instance, newId)
				self:insertInstance(instance, newId, {})
			end
			-- mapped == instance: already registered, nothing to do.
		else
			-- Generate new ID for instances without one
			local newId = generateUniqueId()
			UniqueIdHelpers.setUniqueId(instance, newId)
			self:insertInstance(instance, newId, {})
		end

		-- Yield periodically to prevent Studio freeze
		if i % BATCH_SIZE == 0 then
			task.wait() -- Brief yield to allow Studio to process events
		end
	end
end

return Tree
