local Codex = script:FindFirstAncestor("Codex")
local Types = require(Codex.Types)
local Log = require(Codex.Log)
local Dom = require(Codex.Dom)
local generateRef = require(Codex.Helpers.generateRef)
local UniqueIdHelpers = require(Codex.Util.UniqueIdHelpers)

local Helpers = require(script.Parent.Helpers)
local PropertyConverter = require(script.Parent.PropertyConverter)

local AdditionProcessor = {}
AdditionProcessor.__index = AdditionProcessor

function AdditionProcessor.new(parent)
	return setmetatable({
		parent = parent,
		tree = parent.tree,
		ProjectApi = parent.ProjectApi,
	}, AdditionProcessor)
end

-- Helper: Extract fields from Change format for processor logic
-- Change format uses {op, uniqueId, robloxClass, path, content, parentId, properties, attributes, ...}
-- Processor needs: id (string), name (string), class (string), parent (string), etc.
local function extractFieldsFromChange(change: any): any
	-- Extract name from path (last component)
	local name = change.path and change.path:match("[^/]+$") or change.hierarchicalName or "Unknown"

	-- Use uniqueId directly (already a string)
	local id = change.uniqueId

	-- Use parentId directly if present (already a string)
	local parent = change.parentId

	-- Extract properties and convert to Roblox values
	local properties = {}
	if change.properties then
		for propName, propValue in pairs(change.properties) do
			local convertedValue = PropertyConverter.convertPropertyValue(propName, propValue)
			if convertedValue ~= nil then
				properties[propName] = convertedValue
			end
		end
	end

	-- Extract attributes (simple key-value pairs)
	local attributes = {}
	if change.attributes then
		for attrName, attrValue in pairs(change.attributes) do
			attributes[attrName] = attrValue
		end
	end

	return {
		id = id, -- string (Types.Ref)
		name = name, -- string
		class = change.robloxClass, -- string
		parent = parent, -- string (Types.Ref) or nil
		path = change.path, -- string
		content = change.content, -- string or nil
		uniqueId = change.uniqueId, -- string (12-char or 3-char)
		properties = properties, -- converted properties from new API format
		attributes = attributes, -- attributes from new API format
		meta = {}, -- empty (not in Change format)
		timestamp = nil, -- not in Change format
		children = {}, -- empty (not in Change format)
	}
end

function AdditionProcessor:applyAddition(
	change: any, -- WriteChange or CreateInstanceChange
	initial: boolean?,
	skipExisting: boolean?
): Instance?
	Log.debug("[AdditionProcessor] applyAddition called with change:", change)
	-- Extract fields from Change format
	local snapshot = extractFieldsFromChange(change)
	Log.debug("[AdditionProcessor] snapshot:", snapshot)
	-- Ensure non-script instance additions are always handled here (never via UpdateProcessor)
	-- This function already creates instances; no change needed other than being the authoritative path.
	-- Skip structural project items that shouldn't be created as Roblox instances
	local shouldSkip = Helpers.STRUCTURAL_ITEMS[snapshot.name]
	if shouldSkip then
		if type(shouldSkip) == "function" then
			shouldSkip = shouldSkip(snapshot)
		end
		if shouldSkip then
			Log.info(
				"[WriteProcessor] Skipping structural project item:",
				snapshot.name,
				"Path:",
				snapshot.path or "N/A"
			)
			return
		end
	end

	-- snapshot.id and snapshot.parent are already strings (Types.Ref)
	local internalSnapshotId: Types.Ref = snapshot.id
	local internalSnapshotParent: Types.Ref? = snapshot.parent

	-- TIMESTAMP CHECK
	local newTimestamp = snapshot.timestamp
	local existingTimestamp = self.tree:getTimestamp(internalSnapshotId)
	if newTimestamp and existingTimestamp and newTimestamp <= existingTimestamp then
		Log.trace(
			string.format(
				"[WriteProcessor:applyAddition] Skipping ADDITION for %s (ID: %s), incoming timestamp (%s) is not newer than existing (%s).",
				snapshot.name or "N/A",
				internalSnapshotId,
				tostring(newTimestamp),
				tostring(existingTimestamp)
			)
		)
		return self.tree:getInstance(internalSnapshotId) -- Return existing instance if any
	end

	-- FAST-PATH: If snapshot.uniqueId maps to an existing instance in Tree, treat as update
	-- New sync format: 12-char base32 IDs (e.g., "YGVJ457VATGG")
	-- Legacy: 3-char service IDs (e.g., "sss", "rs1")
	if
		snapshot.uniqueId
		and type(snapshot.uniqueId) == "string"
		and (#snapshot.uniqueId == 12 or #snapshot.uniqueId == 3)
	then
		local existingInst = self.tree.getByUniqueId and self.tree:getByUniqueId(snapshot.uniqueId)
		if existingInst then
			Log.debug(
				"[AdditionProcessor DEDUP] Tree contains uniqueId:",
				snapshot.uniqueId,
				"->",
				existingInst:GetFullName(),
				"- treating as update"
			)
			-- Delegate to UpdateProcessor to handle content and property updates
			local updatePayload = {
				id = snapshot.id,
				uniqueId = snapshot.uniqueId,
				name = snapshot.name,
				class = snapshot.class,
				path = snapshot.path,
				properties = snapshot.properties,
				attributes = snapshot.attributes,
				meta = snapshot.meta,
				content = snapshot.content, -- Include content for script updates
			}
			return self.parent:applyUpdate(internalSnapshotId, updatePayload, initial)
		end
	end

	-- Also check under resolved parent by name+class as a fallback (already implemented below)

	-- FAST-PATH: If we already have an instance mapped for this ID, avoid duplicating.
	local already = self.tree:getInstance(internalSnapshotId)

	-- CRITICAL FIX: If this is a server response for a file we created locally,
	-- we need to preserve our local Base64 path-based ID instead of using the server's hash ID
	if already then
		-- Get the existing local ID for this instance
		local existingLocalId = self.tree:getId(already)

		if existingLocalId then
			-- Check if the existing ID looks like a Base64 path (our local ID)
			-- and the server ID looks like a hash (server's ID)
			local isExistingIdBase64Path = existingLocalId:match("^[A-Za-z0-9+/]+=*$") and #existingLocalId > 20
			local isServerIdHash = not internalSnapshotId:match("^[A-Za-z0-9+/]+=*$") or #internalSnapshotId < 20

			if isExistingIdBase64Path and isServerIdHash then
				Log.warn("[WriteProcessor:applyAddition] PRESERVING local Base64 path ID instead of server hash ID")
				Log.warn("[WriteProcessor:applyAddition] Local ID (Base64 path):", existingLocalId)
				Log.warn("[WriteProcessor:applyAddition] Server ID (hash):", internalSnapshotId)

				-- Use the existing local ID instead of the server ID
				internalSnapshotId = existingLocalId

				-- Store server ID in metadata for reference if needed
				if snapshot.meta then
					snapshot.meta.serverHashId = internalSnapshotId
				else
					snapshot.meta = { serverHashId = internalSnapshotId }
				end
			end
		end

		Log.debug("[applyAddition] Instance already exists for ID. Treating as an update to apply properties.")
		-- Create a change-like payload from the incoming AddedSnapshot for UpdateProcessor
		-- NOTE: UpdateProcessor expects a change object with 'path' field for name extraction
		local updatePayload = {
			id = snapshot.id, -- Must be the Ref
			uniqueId = snapshot.uniqueId,
			name = snapshot.name,
			class = snapshot.class,
			path = snapshot.path, -- Required for UpdateProcessor.extractFieldsFromChange
			properties = snapshot.properties,
			meta = snapshot.meta,
			content = snapshot.content, -- ADDED: Include content for script updates
			-- Note: children are not part of SnapshotUpdate, they are handled by separate additions/removals
		}
		return self.parent:applyUpdate(internalSnapshotId, updatePayload, initial)
	end

	-- From here, use internalSnapshotId and internalSnapshotParent
	assert(
		internalSnapshotId and type(internalSnapshotId) == "string",
		"[applyAddition] internalSnapshotId is not a valid string."
	)
	assert(
		internalSnapshotParent == nil or type(internalSnapshotParent) == "string",
		"[applyAddition] internalSnapshotParent is not nil or a valid string."
	)

	local id_str = internalSnapshotId
	local parent_str = internalSnapshotParent or "nil"

	Log.trace(("[WriteProcessor DEBUG] Applying ADDITION for: %s (%s) with ID: %s Target Parent Ref: %s"):format(
		snapshot.name or "N/A",
		snapshot.class or "N/A",
		id_str, -- Log as string
		parent_str -- Log as string
	))

	Log.trace("[WriteProcessor DETAIL] snapshot.parent type:", typeof(snapshot.parent), "value:", snapshot.parent)
	Log.trace(
		"[WriteProcessor DETAIL] internalSnapshotParent type:",
		typeof(internalSnapshotParent),
		"value:",
		internalSnapshotParent
	)

	local parent = nil
	if internalSnapshotParent then
		-- DEBUG: Log what we're trying to resolve
		Log.info("[WriteProcessor DEBUG] Resolving parent ID:", internalSnapshotParent, "for instance:", snapshot.name)
		Log.debug("[AdditionProcessor] Looking for parent with ID:", internalSnapshotParent)

		-- CRITICAL FIX: Check if this is ROOT_DATAMODEL_ID and directly use game
		if internalSnapshotParent == "ROOT_DATAMODEL_ID" then
			Log.info("[WriteProcessor FIX] Detected ROOT_DATAMODEL_ID, using game as parent")
			parent = game
		else
			parent = self.tree:getInstance(internalSnapshotParent)
		end

		-- CRITICAL FIX: If parent ID exists but parent cannot be found in tree,
		-- and this is NOT a top-level service creation, skip the child
		-- This prevents creating children of deleted parents (e.g., when server optimizes create+delete)
		if not parent and snapshot.path then
			local pathParts = string.split(snapshot.path, "/")
			local isTopLevelService = #pathParts == 1 -- Top-level service paths have only one component

			if not isTopLevelService then
				Log.debug(
					"[AdditionProcessor] Parent",
					internalSnapshotParent,
					"not found in tree for non-service child:",
					snapshot.name,
					"- assuming parent was deleted. Skipping child creation."
				)
				return nil
			end
		end

		-- If parent not found in tree, check if this is a service based on the path
		if not parent and snapshot.path then
			-- DEBUG: More detailed logging
			Log.warn(
				"[WriteProcessor DEBUG] Failed to resolve parent ID:",
				internalSnapshotParent,
				"for instance:",
				snapshot.name,
				"Path:",
				snapshot.path
			)

			-- DEBUG: Let's check what's in the tree for services
			local workspaceId = self.tree:getId(game.Workspace)
			if workspaceId then
				Log.info("[WriteProcessor DEBUG] Workspace is registered in tree with ID:", workspaceId)
			else
				Log.warn("[WriteProcessor DEBUG] Workspace is NOT registered in tree!")
			end

			-- Extract service name from path (e.g., "src/Workspace/file.lua" -> "Workspace" or "Workspace/file.lua" -> "Workspace")
			local pathParts = string.split(snapshot.path, "/")
			local serviceName = nil

			if #pathParts >= 2 and pathParts[1] == "src" then
				-- Normalized path: src/ServiceName/file
				serviceName = pathParts[2]
			elseif #pathParts >= 1 then
				-- Denormalized path: ServiceName/file or just ServiceName
				serviceName = pathParts[1]
			end

			if serviceName then
				Log.info("[WriteProcessor] Attempting to resolve service from path. Service name:", serviceName)
				Log.debug("[AdditionProcessor] Extracted service name:", serviceName)
				Log.debug("[AdditionProcessor] Looking in SERVICE_MAPPING for:", serviceName)

				-- Try to find the service instance
				local serviceInstance = Helpers.SERVICE_MAPPING[serviceName]
				if serviceInstance then
					Log.info(
						"[WriteProcessor] Found service instance for:",
						serviceName,
						"Instance:",
						serviceInstance:GetFullName()
					)
					Log.debug("[AdditionProcessor] SUCCESS: Found service:", serviceInstance:GetFullName())

					-- NEW LOGIC: Attempt to resolve nested parent paths (e.g. StarterPlayerScripts)
					local targetParentInstance = serviceInstance
					if snapshot.path then
						local nestedPathParts = string.split(snapshot.path, "/")
						-- Remove the root service name (e.g. "StarterPlayer")
						table.remove(nestedPathParts, 1)
						-- Remove the filename (last part) to get the parent path
						if #nestedPathParts > 1 then
							table.remove(nestedPathParts, #nestedPathParts)
						end

						if #nestedPathParts > 0 then
							Log.info(
								"[AdditionProcessor FIX] Traversing path parts:",
								table.concat(nestedPathParts, "/")
							)
							-- Walk down the hierarchy to find (or verify) the desired parent instance
							local current = serviceInstance
							for _, partName in ipairs(nestedPathParts) do
								Log.info(
									"[AdditionProcessor FIX] Looking for child:",
									partName,
									"in",
									current:GetFullName()
								)
								local nextChild = current:FindFirstChild(partName)
								if not nextChild then
									Log.warn(
										"[AdditionProcessor FIX] Child not found:",
										partName,
										"in",
										current:GetFullName()
									)
									current = nil
									break -- Stop traversal on first missing segment
								end
								current = nextChild
								Log.info("[AdditionProcessor FIX] Found child:", current:GetFullName())
							end
							if current then
								targetParentInstance = current
								Log.info(
									"[AdditionProcessor FIX] Resolved nested parent instance:",
									current:GetFullName()
								)
							else
								Log.warn(
									"[AdditionProcessor FIX] Could not resolve nested parent beyond service for path:",
									snapshot.path,
									"- Skipping child creation to prevent inconsistency."
								)
								-- CRITICAL FIX: Don't use service as fallback parent when nested traversal fails
								-- This prevents children of deleted parents from being parented to root service
								return nil
							end
						else
							Log.info("[AdditionProcessor FIX] No nested path parts, using service as parent")
						end
					end

					parent = targetParentInstance

					-- Register the **resolved** parent Instance (service or nested folder) with the provided database ID
					if internalSnapshotParent then
						Log.info(
							"[WriteProcessor] Registering parent in tree with database ID:",
							internalSnapshotParent
						)
						self.tree:insertInstance(
							targetParentInstance,
							internalSnapshotParent,
							{ isService = (targetParentInstance == serviceInstance) }
						)
					end
				else
					Log.warn("[WriteProcessor] Could not find service instance for:", serviceName)
					Log.debug("[AdditionProcessor] FAILED: Service not found in SERVICE_MAPPING:", serviceName)
				end
			else
				Log.warn("[WriteProcessor] Could not extract service name from path:", snapshot.path)
				Log.debug("[AdditionProcessor] FAILED: Could not extract service name from path:", snapshot.path)
			end
		elseif not parent then
			Log.warn(
				"[WriteProcessor DEBUG] Failed to resolve parent ID:",
				internalSnapshotParent,
				"for instance:",
				snapshot.name
			)
		end
	end

	-- NO FALLBACKS - backend must provide proper parent information

	-- Final parent check
	if parent then
		Log.info("[WriteProcessor DEBUG] Resolved parent to:", parent:GetFullName(), "for instance:", snapshot.name)
		Log.debug("[AdditionProcessor] FINAL SUCCESS: Parent found:", parent:GetFullName())
	else
		-- Parent is nil after all resolution attempts - skip this instance gracefully
		-- This can happen if the parent service/folder doesn't exist yet or was deleted
		Log.warn(
			"[WriteProcessor] Skipping instance with nil parent:",
			snapshot.name,
			"(Class:",
			snapshot.class or "Unknown",
			") - parent will be resolved when service/folder is synced"
		)
		Log.debug("[AdditionProcessor] Gracefully skipping instance with nil parent:", snapshot.name)
		-- Return nil to skip this instance without breaking sync
		return nil
	end

	local instance
	-- Defensive deduplication: if a matching instance already exists under the resolved parent,
	-- treat it as an update instead of creating a new one.
	-- New sync format: 12-char base32 IDs (e.g., "YGVJ457VATGG")
	-- Legacy: 3-char service IDs (e.g., "sss", "rs1")
	if parent then
		if
			snapshot.uniqueId
			and type(snapshot.uniqueId) == "string"
			and (#snapshot.uniqueId == 12 or #snapshot.uniqueId == 3)
		then
			for _, child in ipairs(parent:GetChildren()) do
				if child:IsA(snapshot.class) then
					local uid = UniqueIdHelpers.getUniqueId(child)
					if uid == snapshot.uniqueId then
						Log.debug(
							"[AdditionProcessor DEDUP] Found existing instance by uniqueId:",
							snapshot.uniqueId,
							"->",
							child:GetFullName(),
							"- treating as update"
						)
						-- Delegate to UpdateProcessor to handle content and property updates
						local updatePayload = {
							id = snapshot.id,
							uniqueId = snapshot.uniqueId,
							name = snapshot.name,
							class = snapshot.class,
							path = snapshot.path,
							properties = snapshot.properties,
							attributes = snapshot.attributes,
							meta = snapshot.meta,
							content = snapshot.content, -- Include content for script updates
						}
						return self.parent:applyUpdate(internalSnapshotId, updatePayload, initial)
					end
				end
			end
		end
		if not instance then
			local existingByName = parent:FindFirstChild(snapshot.name)
			if existingByName and existingByName:IsA(snapshot.class) then
				Log.debug(
					"[AdditionProcessor DEDUP] Found existing instance by name+class:",
					snapshot.name,
					"->",
					existingByName:GetFullName(),
					"- treating as update"
				)
				-- Delegate to UpdateProcessor to handle content and property updates
				local updatePayload = {
					id = snapshot.id,
					uniqueId = snapshot.uniqueId,
					name = snapshot.name,
					class = snapshot.class,
					path = snapshot.path,
					properties = snapshot.properties,
					attributes = snapshot.attributes,
					meta = snapshot.meta,
					content = snapshot.content, -- Include content for script updates
				}
				return self.parent:applyUpdate(internalSnapshotId, updatePayload, initial)
			end
		end
	end

	if Dom.isCreatable(snapshot.class) then
		if not instance then
			instance = Instance.new(snapshot.class)
		end

		-- DEBUG: Log uniqueId values at AdditionProcessor level
		Log.debug("[AdditionProcessor] snapshot.uniqueId:", snapshot.uniqueId, "type:", type(snapshot.uniqueId))
		Log.debug("[AdditionProcessor] snapshot.id (nodeId):", id_str)
		Log.debug("[AdditionProcessor] snapshot.name:", snapshot.name)
		Log.debug("[AdditionProcessor] snapshot.class:", snapshot.class)
		Log.debug("[AdditionProcessor] snapshot.path:", snapshot.path)

		-- Enforce VM uniqueId authority: set or correct attribute to match snapshot.uniqueId when provided
		local ok, _ = pcall(function()
			local incomingUid = nil
			-- New sync format: 12-char base32 IDs (e.g., "YGVJ457VATGG")
			-- Legacy: 3-char service IDs (e.g., "sss", "rs1")
			if
				snapshot.uniqueId
				and type(snapshot.uniqueId) == "string"
				and (string.len(snapshot.uniqueId) == 12 or string.len(snapshot.uniqueId) == 3)
			then
				incomingUid = snapshot.uniqueId
			end
			if incomingUid then
				local currentUid = UniqueIdHelpers.getUniqueId(instance)
				if currentUid ~= incomingUid then
					Log.debug(
						"[AdditionProcessor] Enforcing uniqueId attribute:",
						currentUid or "(none)",
						"->",
						incomingUid
					)
					UniqueIdHelpers.setUniqueId(instance, incomingUid)
				end
				-- Mark as server-created to prevent sync echo
				instance:SetAttribute("_serverCreated", true)
			end
		end)
		if not ok then
			Log.warn("[AdditionProcessor] Failed to set uniqueId attribute on instance", snapshot.name)
		end
	else
		-- Handle Roblox services that already exist and can't be created
		instance = Helpers.SERVICE_MAPPING[snapshot.name]
		if instance then
			Log.trace("[WriteProcessor] Using existing service for:", snapshot.name, "Class:", instance.ClassName)
			-- Mark service as server-created to prevent sync echo
			instance:SetAttribute("_serverCreated", true)

			-- Services are already parented to game and cannot be reparented
			-- Register the service in the tree and skip the normal parenting flow
			local serviceTimestamp = snapshot.timestamp or os.clock() * 1000
			self.tree:insertInstance(instance, internalSnapshotId, snapshot.meta, serviceTimestamp)

			-- Apply properties from new API format (already converted to Roblox values)
			if snapshot.properties then
				if next(snapshot.properties) then
					Log.debug(
						"[AdditionProcessor] Applying properties to service",
						snapshot.name,
						":",
						snapshot.properties
					)
				end
				for property, value in snapshot.properties do
					-- Properties are already converted to Roblox values by extractFieldsFromChange
					local success, err = pcall(function()
						instance[property] = value
					end)
					if not success then
						Log.warn(
							"[AdditionProcessor] Failed to set property",
							property,
							"on service",
							snapshot.name,
							"Error:",
							err
						)
						-- Fallback: try using Dom.writeProperty
						local writeSuccess, reason = Dom.writeProperty(instance, property, value)
						if not writeSuccess then
							Log.warn(
								"[AdditionProcessor] Dom.writeProperty also failed for",
								property,
								"Reason:",
								reason.kind
							)
						end
					else
						Log.debug(
							"[AdditionProcessor] Set property",
							property,
							"=",
							tostring(value),
							"on service",
							snapshot.name
						)
					end
				end
			end

			-- Apply attributes from new API format
			if snapshot.attributes then
				if next(snapshot.attributes) then
					Log.debug(
						"[AdditionProcessor] Applying attributes to service",
						snapshot.name,
						":",
						snapshot.attributes
					)
				end
				for attrName, attrValue in snapshot.attributes do
					-- Use Helpers.applyAttribute to handle special attributes like _PrimaryPartUniqueId
					local success, err = Helpers.applyAttribute(instance, attrName, attrValue, self.tree)
					if not success then
						Log.warn(
							"[AdditionProcessor] Failed to set attribute",
							attrName,
							"on service",
							snapshot.name,
							"Error:",
							err
						)
					else
						Log.debug(
							"[AdditionProcessor] Set attribute",
							attrName,
							"=",
							tostring(attrValue),
							"on service",
							snapshot.name
						)
					end
				end
			end

			Log.trace("[WriteProcessor] Service handling complete for:", snapshot.name)
			return instance
		else
			Log.trace(
				"[WriteProcessor] Class not creatable and no service mapping for:",
				snapshot.class,
				"Name:",
				snapshot.name
			)
		end
	end

	if not instance then
		Log.warn("[WriteProcessor] Could not create or find instance for:", snapshot.name, "Class:", snapshot.class)
		return nil
	end

	if skipExisting then
		local existingInstance = parent:FindFirstChild(snapshot.name)
		if existingInstance and existingInstance:IsA(snapshot.class) then
			return existingInstance
		end
	end

	if not parent then
		-- Trust server ordering: parents should be sent before children.
		-- If parent is missing, skip this instance gracefully - it will be handled when parent arrives.
		Log.warn(
			"[WriteProcessor] Gracefully skipping instance:",
			snapshot.name,
			"(parent not found) - will sync when parent becomes available"
		)
		-- Return nil to skip without breaking sync flow
		return nil
	end

	if skipExisting then
		local existingInstance = parent:FindFirstChild(snapshot.name)
		if existingInstance and existingInstance:IsA(snapshot.class) then
			return existingInstance
		end
	end

	-- Retain the exact filename (including extension) from the snapshot.
	-- Stripping the extension caused divergences between Studio names and server paths,
	-- breaking two-way sync and leading to duplicate instances on reconnect.

	-- Pause watcher to prevent circular change detection during WriteProcessor operations
	if self.parent.watcher then
		self.parent.watcher:pause(function()
			Log.trace(
				"[WriteProcessor PRE-NAME] Keeping original snapshot.name: '",
				snapshot.name,
				"' Current instance.Name: '",
				instance.Name,
				"'"
			)
			instance.Name = snapshot.name
			Log.trace("[WriteProcessor DEBUG] Set instance Name to:", instance.Name)

			-- Apply properties from new API format (already converted to Roblox values)
			if next(snapshot.properties) then
				Log.debug("[AdditionProcessor] Applying properties to", instance.Name, ":", snapshot.properties)
			end
			for property, value in snapshot.properties do
				-- Properties are already converted to Roblox values by extractFieldsFromChange
				-- Try to set the property directly
				local success, err = pcall(function()
					instance[property] = value
				end)

				if not success then
					Log.warn("[AdditionProcessor] Failed to set property", property, "on", instance.Name, "Error:", err)
					-- Fallback: try using Dom.writeProperty if direct assignment failed
					local writeSuccess, reason = Dom.writeProperty(instance, property, value)
					if not writeSuccess then
						Log.warn(
							"[AdditionProcessor] Dom.writeProperty also failed for",
							property,
							"Reason:",
							reason.kind
						)
					end
				else
					Log.debug("[AdditionProcessor] Set property", property, "=", tostring(value), "on", instance.Name)
				end
			end

			-- Apply attributes from new API format
			if next(snapshot.attributes) then
				Log.debug("[AdditionProcessor] Applying attributes to", instance.Name, ":", snapshot.attributes)
			end
			for attrName, attrValue in snapshot.attributes do
				-- Use Helpers.applyAttribute to handle special attributes like _PrimaryPartUniqueId
				local success, err = Helpers.applyAttribute(instance, attrName, attrValue, self.tree)

				if not success then
					Log.warn(
						"[AdditionProcessor] Failed to set attribute",
						attrName,
						"on",
						instance.Name,
						"Error:",
						err
					)
				else
					Log.debug(
						"[AdditionProcessor] Set attribute",
						attrName,
						"=",
						tostring(attrValue),
						"on",
						instance.Name
					)
				end
			end
		end)
	else
		Log.trace(
			"[WriteProcessor PRE-NAME] Keeping original snapshot.name: '",
			snapshot.name,
			"' Current instance.Name: '",
			instance.Name,
			"'"
		)
		instance.Name = snapshot.name
		Log.trace("[WriteProcessor DEBUG] Set instance Name to:", instance.Name)

		-- Apply properties from new API format (already converted to Roblox values)
		if next(snapshot.properties) then
			Log.debug("[AdditionProcessor] Applying properties to", instance.Name, ":", snapshot.properties)
		end
		for property, value in snapshot.properties do
			-- Properties are already converted to Roblox values by extractFieldsFromChange
			-- Try to set the property directly
			local success, err = pcall(function()
				instance[property] = value
			end)

			if not success then
				Log.warn("[AdditionProcessor] Failed to set property", property, "on", instance.Name, "Error:", err)
				-- Fallback: try using Dom.writeProperty if direct assignment failed
				local writeSuccess, reason = Dom.writeProperty(instance, property, value)
				if not writeSuccess then
					Log.warn("[AdditionProcessor] Dom.writeProperty also failed for", property, "Reason:", reason.kind)
				end
			else
				Log.debug("[AdditionProcessor] Set property", property, "=", tostring(value), "on", instance.Name)
			end
		end

		-- Apply attributes from new API format
		if next(snapshot.attributes) then
			Log.debug("[AdditionProcessor] Applying attributes to", instance.Name, ":", snapshot.attributes)
		end
		for attrName, attrValue in snapshot.attributes do
			-- Use Helpers.applyAttribute to handle special attributes like _PrimaryPartUniqueId
			local success, err = Helpers.applyAttribute(instance, attrName, attrValue, self.tree)

			if not success then
				Log.warn("[AdditionProcessor] Failed to set attribute", attrName, "on", instance.Name, "Error:", err)
			else
				Log.debug("[AdditionProcessor] Set attribute", attrName, "=", tostring(attrValue), "on", instance.Name)
			end
		end
	end

	local parentingSuccess = false

	if not instance then
		Log.warn("[WriteProcessor CRITICAL] Instance is nil before parenting.")
		return
	end

	-- Pause watcher for parenting operation
	if self.parent.watcher then
		self.parent.watcher:pause(function()
			Log.trace(
				"[WriteProcessor PRE-PARENT] instance.Name: '",
				instance.Name,
				"', target parent.Name: '",
				parent.Name,
				"', target parent.ClassName: '",
				parent.ClassName,
				"'"
			)
			Log.trace(
				"[WriteProcessor DEBUG] Attempting to set Parent via pcall:",
				instance:GetFullName(),
				"->",
				parent:GetFullName()
			)
			local success, err = pcall(function()
				instance.Parent = parent -- *** CRITICAL: Parenting wrapped in pcall ***
			end)

			if not success then
				Log.error(
					"[WriteProcessor CRITICAL] pcall FAILED during Parent assignment for",
					instance:GetFullName(),
					"Error:",
					err
				)
			else
				Log.trace("[WriteProcessor DEBUG] pcall SUCCEEDED for Parent assignment.")
				-- Check if it actually worked *after* pcall
				if instance.Parent ~= parent then
					Log.error(
						"[WriteProcessor CRITICAL] PARENT ASSIGNMENT FAILED (checked *after* pcall) for",
						instance:GetFullName(),
						"Expected parent:",
						parent:GetFullName(),
						"Actual parent:",
						instance.Parent and instance.Parent:GetFullName() or "NIL"
					)
				else
					Log.trace(
						"[WriteProcessor POST-PARENT] instance.Name: '",
						instance.Name,
						"', actual instance.Parent.Name: '",
						instance.Parent and instance.Parent.Name or "NIL",
						"', actual instance.Parent.ClassName: '",
						instance.Parent and instance.Parent.ClassName or "NIL",
						"'"
					)
					Log.trace(
						"[WriteProcessor DEBUG] Parent assignment verification: SUCCESS.",
						parent.Name .. "." .. instance.Name,
						"is now child of",
						parent.Name
					)
					parentingSuccess = true
				end
			end
		end)
	else
		Log.trace(
			"[WriteProcessor PRE-PARENT] instance.Name: '",
			instance.Name,
			"', target parent.Name: '",
			parent.Name,
			"', target parent.ClassName: '",
			parent.ClassName,
			"'"
		)
		Log.trace(
			"[WriteProcessor DEBUG] Attempting to set Parent via pcall:",
			instance:GetFullName(),
			"->",
			parent:GetFullName()
		)
		local success, err = pcall(function()
			instance.Parent = parent -- *** CRITICAL: Parenting wrapped in pcall ***
		end)

		if not success then
			Log.error(
				"[WriteProcessor CRITICAL] pcall FAILED during Parent assignment for",
				instance:GetFullName(),
				"Error:",
				err
			)
		else
			Log.trace("[WriteProcessor DEBUG] pcall SUCCEEDED for Parent assignment.")
			-- Check if it actually worked *after* pcall
			if instance.Parent ~= parent then
				Log.error(
					"[WriteProcessor CRITICAL] PARENT ASSIGNMENT FAILED (checked *after* pcall) for",
					instance:GetFullName(),
					"Expected parent:",
					parent:GetFullName(),
					"Actual parent:",
					instance.Parent and instance.Parent:GetFullName() or "NIL"
				)
			else
				Log.trace(
					"[WriteProcessor POST-PARENT] instance.Name: '",
					instance.Name,
					"', actual instance.Parent.Name: '",
					instance.Parent and instance.Parent.Name or "NIL",
					"', actual instance.Parent.ClassName: '",
					instance.Parent and instance.Parent.ClassName or "NIL",
					"'"
				)
				Log.trace(
					"[WriteProcessor DEBUG] Parent assignment verification: SUCCESS.",
					parent.Name .. "." .. instance.Name,
					"is now child of",
					parent.Name
				)
				parentingSuccess = true
			end
		end
	end

	if not parentingSuccess then
		Log.error("[WriteProcessor CRITICAL] Failed to parent instance after pcall.")
		Log.error("[WriteProcessor CRITICAL] Instance:", instance.Name, "Target Parent:", parent.Name)
		return
	end

	Log.trace(
		"[WriteProcessor POST-PARENT] instance.Name: '",
		instance.Name,
		"', actual instance.Parent.Name: '",
		instance.Parent.Name,
		"', actual instance.Parent.ClassName: '",
		instance.Parent.ClassName,
		"'"
	)

	Log.trace(
		"[WriteProcessor DEBUG] Parent assignment verification: SUCCESS.",
		parent.Name .. "." .. instance.Name,
		"is now child of",
		parent.Name
	)

	-- Set content/source for script instances
	Log.trace("[WriteProcessor CONTENT DEBUG] snapshot.content exists:", snapshot.content ~= nil)
	Log.trace("[WriteProcessor CONTENT DEBUG] snapshot.class:", snapshot.class)
	if snapshot.content then
		Log.trace("[WriteProcessor CONTENT DEBUG] Content length:", string.len(snapshot.content))
		Log.trace("[WriteProcessor CONTENT DEBUG] Content preview:", string.sub(snapshot.content, 1, 50))
	end

	if
		snapshot.content
		and (snapshot.class == "ModuleScript" or snapshot.class == "Script" or snapshot.class == "LocalScript")
	then
		-- Pause watcher for content/source setting
		if self.parent.watcher then
			self.parent.watcher:pause(function()
				Log.trace(
					"[WriteProcessor CONTENT] Setting Source for",
					instance.Name,
					"Length:",
					string.len(snapshot.content)
				)
				local contentSuccess, contentErr = pcall(function()
					instance.Source = snapshot.content
				end)
				if contentSuccess then
					Log.trace("[WriteProcessor CONTENT] Successfully set Source for", instance.Name)
				else
					Log.error(
						"[WriteProcessor CONTENT ERROR] Failed to set Source for",
						instance.Name,
						"Error:",
						contentErr
					)
				end
			end)
		else
			Log.trace(
				"[WriteProcessor CONTENT] Setting Source for",
				instance.Name,
				"Length:",
				string.len(snapshot.content)
			)
			local contentSuccess, contentErr = pcall(function()
				instance.Source = snapshot.content
			end)
			if contentSuccess then
				Log.trace("[WriteProcessor CONTENT] Successfully set Source for", instance.Name)
			else
				Log.error(
					"[WriteProcessor CONTENT ERROR] Failed to set Source for",
					instance.Name,
					"Error:",
					contentErr
				)
			end
		end
	elseif snapshot.content then
		Log.trace("[WriteProcessor CONTENT] Skipping Source set for non-script class:", snapshot.class)
	end

	-- 6. Update Internal Tree Map
	-- Only insert into tree if parenting seemed successful (avoids tracking detached instances)
	if parentingSuccess then
		-- Store metadata
		if not snapshot.meta then
			snapshot.meta = {}
		end

		Log.trace(
			"[WriteProcessor] Storing instance in tree:",
			instance:GetFullName(),
			"ID:",
			internalSnapshotId,
			"Timestamp:",
			newTimestamp
		)

		self.tree:insertInstance(instance, internalSnapshotId, snapshot.meta, newTimestamp)

		-- Verification logs AFTER insertInstance
		local verifyInstance = self.tree:getInstance(internalSnapshotId)
		local verifyIdByInstance = self.tree:getId(instance)
		local verifyIdStrByInstance = verifyIdByInstance or "nil"

		Log.trace(
			("[WriteProcessor TRACE POST-INSERT] Verification: getInstance(id) found: %s. getId(instance) returned: %s. Expected ID: %s"):format(
				verifyInstance and verifyInstance:GetFullName() or "NIL",
				verifyIdStrByInstance,
				internalSnapshotId
			)
		)
		if verifyInstance ~= instance then
			Log.warn(
				"[WriteProcessor WARN POST-INSERT] MISMATCH: getInstance(id) did NOT return the original instance!"
			)
		end
		if verifyIdStrByInstance ~= internalSnapshotId then
			Log.warn("[WriteProcessor WARN POST-INSERT] MISMATCH: getId(instance) did NOT return the original ID!")
		end
	else
		Log.warn("[WriteProcessor WARNING] Skipping tree map insert due to parenting failure.")
	end

	-- 7. Recurse for Children (if any were included in this add snapshot)
	-- Only recurse if parenting was successful, otherwise children have no valid parent
	if parentingSuccess then
		if snapshot.children then
			for _, child in snapshot.children do
				-- Ensure child has proper ID field for tree registration
				if not child.id and child.name then
					-- Generate ID if missing (shouldn't happen from server, but safety check)
					local childIdStr = generateRef()
					child.id = childIdStr
					Log.warn("[WriteProcessor] Child snapshot missing ID, generated:", childIdStr, "for", child.name)
				elseif child.id and type(child.id) == "string" then
					-- ID exists as string, keep it as-is for applyAddition to handle
					Log.trace("[WriteProcessor] Processing child with ID:", child.id, "Name:", child.name)
				end

				child.parent = internalSnapshotId
				self:applyAddition(child, initial)
			end
		else
			Log.trace("[WriteProcessor DEBUG] No snapshot.children field found, skipping child recursion.")
		end
	else
		Log.warn("[WriteProcessor WARNING] Skipping child recursion due to parent failure.")
	end

	if not initial then
		-- Only set waypoint if the core operation succeeded
		if parentingSuccess then
			Helpers.setWaypoint("Add", instance.Name)
		end
	end

	-- Final log based on parenting success
	if parentingSuccess then
		Log.trace("[WriteProcessor IMPLEMENTATION] Addition SUCCESSFUL for:", snapshot.name)
		Log.debug(
			"[AdditionProcessor DEBUG] FINAL SUCCESS: Instance created and parented:",
			snapshot.name,
			"->",
			instance:GetFullName()
		)
	else
		Log.error("[WriteProcessor IMPLEMENTATION] Addition FAILED for:", snapshot.name, "(Parenting issue)")
		Log.debug("[AdditionProcessor] FINAL FAILURE: Parenting failed for:", snapshot.name)
	end
	return instance
end

return AdditionProcessor
