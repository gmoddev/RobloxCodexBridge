local Codex = script:FindFirstAncestor("Codex")

local Types = require(Codex.Types)
local Dom = require(Codex.Dom)
local Log = require(Codex.Log)
local Config = require(Codex.Config)

local equals = require(Codex.Helpers.equals)
local getPathFromInstance = require(Codex.Helpers.getPathFromInstance)
local getClassName = require(Codex.Helpers.getClassName)
local generateUniqueId = require(Codex.Helpers.generateUniqueId)
local UniqueIdHelpers = require(Codex.Util.UniqueIdHelpers)
local PropertySerializer = require(Codex.Util.PropertySerializer)

local Error = require(script.Parent.Parent.Error)

local ROOT_REF = "ROOT_DATAMODEL_ID"

-- Determines if an instance represents a "file" that should be synced to the database.
-- Currently, files are limited to Script-type objects that carry Lua source content.
local function isScriptRelated(instance: Instance): boolean
	return instance.ClassName == "Script" or instance.ClassName == "ModuleScript" or instance.ClassName == "LocalScript"
end

-- Map service names to predictable uniqueIds (must match VM initialization)
local function getServiceUniqueId(serviceName: string): string?
	local serviceIds = {
		Workspace = "ws1",
		StarterPlayer = "sp1",
		StarterPlayerScripts = "sps",
		StarterCharacterScripts = "scs",
		ServerScriptService = "sss",
		StarterGui = "sg1",
		ServerStorage = "ss1",
		ReplicatedStorage = "rs1",
		StarterPack = "spk",
		ReplicatedFirst = "rf1",
		SoundService = "snd",
	}
	return serviceIds[serviceName]
end

-- Helper: Convert internal snapshot to Change format (per sync-service-api.md)
-- This eliminates the need for fake snapshots and ensures spec compliance
local function snapshotToChange(snapshot: any, operationType: string): any?
	if not snapshot then
		return nil
	end

	-- Get parent ID if present (already a string)
	local parentId = snapshot.parent

	if operationType == "add" then
		-- Determine if this is a script (write op) or non-script (createInstance op)
		local isScript = isScriptRelated({ ClassName = snapshot.class })

		if isScript then
			-- Write operation with isNew=true
			return {
				op = "write",
				path = snapshot.filePath or snapshot.path,
				uniqueId = snapshot.uniqueId or snapshot.id,
				robloxClass = snapshot.class,
				content = snapshot.content or "",
				isNew = true,
				parentId = parentId,
				source = "plugin",
			}
		else
			-- CreateInstance operation
			local change = {
				op = "createInstance",
				path = snapshot.filePath or snapshot.path,
				uniqueId = snapshot.uniqueId or snapshot.id,
				robloxClass = snapshot.class,
				parentId = parentId,
				hierarchicalName = snapshot.name,
				properties = snapshot.properties,
				attributes = snapshot.attributes,
				source = "plugin",
			}

			-- Log properties count for debugging
			local propCount = 0
			if snapshot.properties then
				for _ in pairs(snapshot.properties) do
					propCount = propCount + 1
				end
			end
			Log.debug(
				"[ReadProcessor] createInstance with",
				propCount,
				"properties for:",
				snapshot.name,
				"class:",
				snapshot.class
			)

			return change
		end
	elseif operationType == "update" then
		-- Write operation with isNew=false
		return {
			op = "write",
			path = snapshot.filePath or snapshot.path,
			uniqueId = snapshot.uniqueId or snapshot.id,
			robloxClass = snapshot.class,
			content = snapshot.content or "",
			isNew = false,
			source = "plugin",
		}
	elseif operationType == "move" then
		-- Move operation
		Log.info("[MOVE DEBUG snapshotToChange] Converting move snapshot to Change format")
		Log.info(
			"[MOVE DEBUG snapshotToChange] snapshot.oldParent:",
			snapshot.oldParent and tostring(snapshot.oldParent) or "NIL"
		)
		Log.info(
			"[MOVE DEBUG snapshotToChange] snapshot.parent (new):",
			snapshot.parent and tostring(snapshot.parent) or "NIL"
		)

		local oldParentId = snapshot.oldParent
		if oldParentId then
			Log.info("[MOVE DEBUG snapshotToChange] Extracted oldParentId:", oldParentId)
		else
			Log.warn("[MOVE DEBUG snapshotToChange] snapshot.oldParent is NIL!")
		end

		local change = {
			op = "move",
			path = snapshot.destinationPath or snapshot.path,
			oldPath = snapshot.sourcePath or snapshot.oldPath,
			uniqueId = snapshot.uniqueId or snapshot.id,
			parentId = parentId,
			oldParentId = oldParentId,
			name = snapshot.name,
			source = "plugin",
		}

		Log.info("[MOVE DEBUG snapshotToChange] Final change.oldParentId:", change.oldParentId or "NIL")
		Log.info("[MOVE DEBUG snapshotToChange] Final change.parentId:", change.parentId or "NIL")

		return change
	elseif operationType == "updateInstance" then
		-- UpdateInstance operation (property/attribute changes)
		return {
			op = "updateInstance",
			path = snapshot.filePath or snapshot.path,
			uniqueId = snapshot.uniqueId or snapshot.id,
			robloxClass = snapshot.class,
			properties = snapshot.properties,
			attributes = snapshot.attributes,
			source = "plugin",
		}
	end

	return nil
end

-- Helper: Determine if properties should be synced for an instance
local function shouldSyncProperties(instance: Instance, property: string?): boolean
	-- 0. Filter internal metadata changes
	if property == "Attributes" then
		return false
	end

	-- 1. Always allow hierarchy-affecting changes so the JSONL stays correct.
	if property == "Parent" or property == "Name" then
		return true
	end

	-- 2. Scripts (and other LuaSourceContainers) always sync their properties/content.
	if isScriptRelated(instance) or instance:IsA("LuaSourceContainer") then
		return true
	end

	-- 3. Filter noisy, read-only GUI layout properties universally.
	if property then
		local readOnlyGuiProperties = {
			"AbsolutePosition",
			"AbsoluteSize",
			"AbsoluteCanvasSize",
			"AbsoluteWindowSize",
		}
		for _, readOnlyProp in ipairs(readOnlyGuiProperties) do
			if property == readOnlyProp then
				return false
			end
		end
	end

	-- 4. For Parts we sync all properties (they carry visual state).
	if instance:IsA("Part") then
		return true
	end

	-- 5. For other instance classes, only sync attributes that diverge from default values.
	if property and not Dom.getDefaultProperties(instance.ClassName)[property] then
		return false
	end

	return Config:get("SyncbackProperties")
end

-- Helper: Collect properties and attributes from an instance
-- Returns two tables: properties (serialized for server API) and attributes (filtered)
local function collectPropertiesAndAttributes(instance: Instance): ({ [string]: any }, { [string]: any })
	local properties = {}
	local attributes = {}

	-- Collect attributes separately from properties
	-- Filter out internal metadata attributes that should not be synced
	for name, value in pairs(instance:GetAttributes()) do
		-- Skip internal plugin metadata attributes
		if not UniqueIdHelpers.isInternalUniqueIdAttribute(name) then
			attributes[name] = value
		end
	end

	local sourcePropertyName = getClassName(instance)

	if instance:GetAttribute("Source") then
		properties[sourcePropertyName] = {
			String = instance:GetAttribute("Source"),
		}
	elseif instance:IsA("LuaSourceContainer") then
		properties[sourcePropertyName] = {
			String = instance.Source,
		}
	end

	-- Sync properties if applicable
	if shouldSyncProperties(instance) then
		for property, default in Dom.getDefaultProperties(instance.ClassName) do
			local readSuccess, instanceValue = Dom.readProperty(instance, property)

			if not readSuccess then
				local err = Error.new(Error.ReadFailed, property, instance, instanceValue.kind)
				Log.warn(err)
				continue
			end

			local _, defaultValue = Dom.EncodedValue.decode(default)

			if not equals(instanceValue, defaultValue) then
				-- skip Attributes as they are synced separately
				if property == "Attributes" then
					continue
				end
				-- Use PropertySerializer to convert directly to server API format
				local serializedValue = PropertySerializer.serializePropertyValue(property, instance, instanceValue)

				if serializedValue == nil then
					Log.warn(
						"[ReadProcessor] Failed to serialize property:",
						property,
						"for instance:",
						instance:GetFullName()
					)
					continue
				end

				properties[property] = serializedValue
			end
		end
	end

	return properties, attributes
end

local ReadProcessor = {}
ReadProcessor.__index = ReadProcessor

function ReadProcessor.new(tree)
	return setmetatable({
		tree = tree,
	}, ReadProcessor)
end

function ReadProcessor:onAdd(instance: Instance, __parentId: Types.Ref?): Types.AddedSnapshot?
	Log.trace("[DEBUG READ] === ReadProcessor:onAdd CALLED ===")
	Log.trace("[DEBUG READ] Instance:", instance:GetFullName(), "Class:", instance.ClassName)
	Log.info("[ReadProcessor.onAdd] Processing instance:", instance:GetFullName())
	Log.debug("[ReadProcessor] NEW INSTANCE DETECTED:", instance:GetFullName(), "Class:", instance.ClassName)

	-- Previous versions skipped non-script instances entirely, which prevented the JSONL hierarchy
	-- from reflecting objects like Parts, Models, Folders, etc. To keep the project structure fully
	-- up-to-date we now ALWAYS build a snapshot, even for non-script instances. Back-end logic will
	-- ignore `content`-less nodes when deciding whether to store separate file rows, so the existing
	-- "scripts-only" persistence contract remains intact.

	-- Use or assign the persistent uniqueId attribute (with backwards compatibility)
	local uid, wasMigrated = UniqueIdHelpers.getUniqueId(instance)
	if not uid then
		uid = generateUniqueId()
		UniqueIdHelpers.setUniqueId(instance, uid)
	end
	if wasMigrated then
		Log.info("[ReadProcessor.onAdd] Migrated legacy uniqueId for:", instance:GetFullName())
	end

	-- Prepare uniqueId for Tree registration after uniqueness is guaranteed

	Log.info("[ReadProcessor.onAdd] Using uniqueId:", uid, "for instance:", instance:GetFullName())

	-- If the tree already contains this instance, skip processing
	local existingId = self.tree:getId(instance)
	if existingId then
		Log.debug("[ReadProcessor] Instance already exists in tree, skipping ADD:", instance:GetFullName())
		Log.debug("  - existingId:", existingId)
		Log.trace("Instance already exists. Skipping..")
		return nil
	end

	Log.debug("[ReadProcessor] Instance NOT in tree, processing as ADD:", instance:GetFullName())

	-- Determine parent reference for snapshot parenting
	local parentInstance = instance.Parent
	local parentId

	if __parentId then
		parentId = __parentId
	else
		if parentInstance then
			-- First try to get parent ID from tree
			parentId = self.tree:getId(parentInstance)

			-- If not in tree yet (e.g., during toolbox import batch processing),
			-- try to get the uniqueId from the parent's attribute
			if not parentId then
				local parentUniqueId = UniqueIdHelpers.getUniqueId(parentInstance)
				if parentUniqueId then
					parentId = parentUniqueId
					Log.debug(
						"[ReadProcessor] Parent not in tree yet, using uniqueId attribute:",
						parentUniqueId,
						"for parent:",
						parentInstance:GetFullName()
					)
				else
					-- CRITICAL FIX: If parent instance exists but has no uniqueId, generate one
					-- This prevents falling back to ROOT_DATAMODEL_ID for children of non-service instances
					local generatedParentUid = generateUniqueId()
					UniqueIdHelpers.setUniqueId(parentInstance, generatedParentUid)
					parentId = generatedParentUid
					Log.warn(
						"[ReadProcessor] Parent missing uniqueId attribute, generated:",
						generatedParentUid,
						"for parent:",
						parentInstance:GetFullName()
					)
				end
			else
				-- Parent IS in tree, but ensure it has a uniqueId attribute
				-- This handles cases where parent was registered in tree but lacks uniqueId
				local parentUniqueId = UniqueIdHelpers.getUniqueId(parentInstance)
				if not parentUniqueId then
					-- Generate and set uniqueId for parent
					local generatedParentUid = generateUniqueId()
					UniqueIdHelpers.setUniqueId(parentInstance, generatedParentUid)
					Log.warn(
						"[ReadProcessor] Parent in tree but missing uniqueId, generated:",
						generatedParentUid,
						"for parent:",
						parentInstance:GetFullName()
					)
				end
			end
		else
			-- Parent is nil (instance is at root level, likely a service)
			parentId = ROOT_REF
		end
	end

	-- Resolve relative path for file system representation
	local relativePath = getPathFromInstance(instance, self.tree)
	Log.trace("[DEBUG READ] getPathFromInstance returned:", relativePath or "nil")
	Log.info("[ReadProcessor.onAdd] Instance:", instance:GetFullName(), "Calculated relativePath:", relativePath)
	-- Verification log: ensure we can see when path resolution fails for toolbox inserts
	Log.trace("[VERIFY Read.onAdd] relativePath:", relativePath or "nil", "instance:", instance:GetFullName())

	if not relativePath then
		Log.trace("[DEBUG READ] PATH IS NIL - RETURNING NIL SNAPSHOT")
		Log.warn(
			"[ReadProcessor.onAdd] Could not determine file path for added instance:",
			instance:GetFullName(),
			"Skipping..."
		)
		-- Extra verification details to diagnose why path is nil
		local parentName = "(nil)"
		local okParent = pcall(function()
			parentName = instance.Parent and instance.Parent:GetFullName() or "(nil)"
		end)
		local parentInTree = false
		if instance.Parent then
			parentInTree = (self.tree:getId(instance.Parent) ~= nil)
		end
		Log.trace("[VERIFY Read.onAdd] path=nil, parent:", parentName, "ok:", okParent, "parentInTree:", parentInTree)
		return nil
	end

	-- Collect properties and attributes using centralized helper
	local properties, attributes = collectPropertiesAndAttributes(instance)
	local children = {}

	-- Do not recurse here; callers (e.g. full sync) will traverse the tree.

	local snapshotName = instance.Name

	-- Debug logging
	Log.info(
		"[ReadProcessor.onAdd] Creating snapshot - Instance name:",
		instance.Name,
		"Class:",
		instance.ClassName,
		"RelativePath:",
		relativePath
	)

	-- Extract content for script instances to ensure it syncs to web
	local content = nil
	if instance:IsA("LuaSourceContainer") then
		content = instance.Source
		Log.info(
			"[ReadProcessor.onAdd] Extracted script content for:",
			instance:GetFullName(),
			"Length:",
			string.len(content or "")
		)
		Log.debug(
			"[ReadProcessor DEBUG] Script content extracted - Name:",
			instance.Name,
			"Length:",
			string.len(content or "")
		)
	end

	-- Return snapshot WITH the persistent uniqueId
	local addedData = {
		id = uid, -- 3-char uniqueId used as primary identifier
		uniqueId = uid, -- propagate for database writes
		filePath = relativePath,
		parent = parentId,
		name = snapshotName,
		class = instance.ClassName,
		properties = properties,
		attributes = attributes, -- Include attributes separately from properties
		children = children,
		meta = {},
		content = content, -- Include content field for scripts
	}

	Log.info(
		"[ReadProcessor.onAdd] Instance:",
		instance:GetFullName(),
		"Final addedData.name:",
		addedData.name,
		"Path:",
		relativePath
	)

	local finalSnapshot = addedData
	Log.info(
		"[ReadProcessor.onAdd] Snapshot prepared - Name:",
		finalSnapshot.name,
		"Path:",
		finalSnapshot.filePath,
		"Children count:",
		#finalSnapshot.children
	)

	-- Final logging
	Log.info(
		"[ReadProcessor.onAdd] Final snapshot - Name:",
		finalSnapshot.name,
		"Path:",
		finalSnapshot.filePath or "nil",
		"Class:",
		finalSnapshot.class,
		"Has children:",
		#finalSnapshot.children > 0
	)

	-- File name is already present in snapshot.name; no need to call :withName on raw table

	-- Convert internal snapshot to Change format before returning
	local change = snapshotToChange(finalSnapshot, "add")
	Log.debug("[ReadProcessor] Converted to Change format - op:", change and change.op or "nil")
	Log.debug("[ReadProcessor] onAdd returning Change for:", instance:GetFullName())
	Log.debug("  - change.name:", finalSnapshot.name)
	Log.debug("  - change.op:", change.op)
	Log.debug("  - change.path:", change.path)
	Log.debug("  - change.parent:", change.parent)
	Log.debug("  - change.parentId:", change.parentId)
	Log.debug("  - change.class:", change.class)
	Log.debug("  - change.id:", change.id)
	Log.debug("  - change.content length:", change.content and string.len(change.content) or "nil")
	Log.debug("  - change is nil:", change == nil)
	return change
end

function ReadProcessor:onChange(
	instance: Instance,
	property: string?,
	oldPath: string?,
	oldParentId: any?
): Types.Change?
	Log.trace("Detected change of", instance, property)

	local id = self.tree:getId(instance)

	-- Recovery: if the Tree mapping is missing, try to rebuild it from the
	-- instance's persistent uniqueId attribute so content edits don't get dropped.
	if not id then
		local uidAttr = UniqueIdHelpers.getUniqueId(instance)
		if uidAttr and typeof(uidAttr) == "string" and (#uidAttr == 3 or #uidAttr == 12) then
			self.tree:insertInstance(instance, uidAttr, {})
			id = uidAttr
			Log.debug("[ReadProcessor] Recovered missing Tree ID via uniqueId for:", instance:GetFullName())
		end
	end

	if not id then
		Log.warn("[ReadProcessor:onChange] Unknown instance. Skipping..")
		return nil
	end

	if property and not shouldSyncProperties(instance, property) then
		Log.trace("Instance does not pass sync filter. Skipping..")
		return nil
	end

	-- For parent or name changes, rely on persistent ID and let the server resolve
	-- the correct path/name using the updated instance hierarchy.
	if property == "Parent" or property == "Name" then
		Log.debug(
			"[ReadProcessor DEBUG] RENAME/MOVE DETECTED:",
			instance:GetFullName(),
			"Property:",
			property,
			"New name:",
			instance.Name
		)

		-- Use the uniqueId from the instance attribute instead of the Tree's ID
		local uniqueId = UniqueIdHelpers.getUniqueId(instance)
		if not uniqueId then
			-- Fallback to Tree ID if uniqueId attribute is missing (shouldn't happen)
			Log.warn("[ReadProcessor.onChange] Instance missing uniqueId attribute:", instance:GetFullName())
			uniqueId = id
		end

		Log.debug("[ReadProcessor] Using uniqueId:", uniqueId, "for rename/move")

		-- Create internal snapshot (plain table) based on the operation
		local snapshot = {
			id = id,
			name = instance.Name,
			class = instance.ClassName,
			uniqueId = uniqueId,
		}

		if property == "Parent" then
			Log.debug("[ReadProcessor] Created move snapshot for Parent change")
		else
			Log.debug("[ReadProcessor] Created move snapshot for Name change (rename)")
		end

		-- Ensure uniqueId is set on the snapshot for downstream processing
		snapshot.uniqueId = uniqueId

		-- Re-calculate the relative file system path (this will be NEW path if moved/renamed)
		local relativePath = getPathFromInstance(instance, self.tree)
		if relativePath then
			-- Include both `filePath` (legacy) and `path` (explicit) so downstream
			-- HttpSync can forward the updated location to the backend.
			snapshot.filePath = relativePath
			snapshot.path = relativePath
		end

		-- For RENAMES, calculate the old path from parent + old name
		-- The old name is NOT available from the instance (it's already updated), so we need to reconstruct it
		-- For now, we'll use the oldPath parameter if provided by the caller (from onChange event context)
		if property == "Name" then
			local parentInstance = instance.Parent
			if parentInstance then
				local parentUniqueId = UniqueIdHelpers.getUniqueId(parentInstance)
				if not parentUniqueId then
					-- Try to use predictable service ID first
					local serviceId = getServiceUniqueId(parentInstance.Name)
					if serviceId then
						parentUniqueId = serviceId
						UniqueIdHelpers.setUniqueId(parentInstance, serviceId)
					else
						-- Fallback to random ID for non-service folders
						parentUniqueId = generateUniqueId()
						UniqueIdHelpers.setUniqueId(parentInstance, parentUniqueId)
					end
				end
				-- Set parent ID (already a string)
				snapshot.parent = parentUniqueId
				snapshot.oldParent = parentUniqueId -- Same parent for rename
			end

			-- For renames, we need the old path - use the oldPath parameter if provided
			-- The Watcher should capture the old name before the change and pass it here
			if oldPath then
				Log.info("[RENAME DEBUG ReadProcessor] Using provided oldPath:", oldPath)
				snapshot.sourcePath = oldPath
				snapshot.oldPath = oldPath
			else
				-- If oldPath not provided, we can't determine it (name already changed)
				Log.debug(
					"[RENAME DEBUG ReadProcessor] No oldPath provided for rename:",
					instance:GetFullName(),
					"- VM may not be able to find directory to rename"
				)
			end
		end

		-- If this event is a *move* (Parent changed) also attach the new parent Ref.
		if property == "Parent" then
			Log.info(
				"[MOVE DEBUG ReadProcessor] Processing Parent change for:",
				instance:GetFullName(),
				"oldPath param:",
				oldPath or "NIL",
				"oldParentId param:",
				oldParentId and tostring(oldParentId) or "NIL"
			)

			-- Use OLD path provided by SyncCoordinator (captured from oldParentContainer in Remove event)
			if oldPath then
				Log.info("[MOVE DEBUG ReadProcessor] ✓ Using cached old path:", oldPath)
				snapshot.sourcePath = oldPath
				snapshot.oldPath = oldPath
			else
				Log.warn(
					"[MOVE DEBUG ReadProcessor] ✗ No old path provided for move:",
					instance:GetFullName(),
					"- move may fail!"
				)
				-- Set to nil - the move may fail or be invalid without oldPath
				snapshot.sourcePath = nil
				snapshot.oldPath = nil
			end

			-- Store oldParentId in snapshot for snapshotToChange conversion
			if oldParentId then
				snapshot.oldParent = oldParentId
				Log.info("[MOVE DEBUG ReadProcessor] Stored oldParentId in snapshot")
			end

			local parentInstance = instance.Parent
			local parentId
			if parentInstance then
				-- Try to fetch from tree first
				parentId = self.tree:getId(parentInstance)
				-- If the parent is missing from the tree (e.g. service folder was never referenced),
				-- fall back to the parent's uniqueId attribute and register it on-the-fly so we never
				-- send ROOT_REF ("unset") for legit moves.
				if not parentId then
					local parentUid = UniqueIdHelpers.getUniqueId(parentInstance)
					if not parentUid then
						-- Try to use predictable service ID first
						local serviceId = getServiceUniqueId(parentInstance.Name)
						if serviceId then
							parentUid = serviceId
							UniqueIdHelpers.setUniqueId(parentInstance, serviceId)
						else
							-- Fallback to random ID for non-service folders
							parentUid = generateUniqueId()
							UniqueIdHelpers.setUniqueId(parentInstance, parentUid)
						end
					end
					parentId = parentUid
					-- Register parent in tree to keep hierarchy consistent
					self.tree:insertInstance(parentInstance, parentId, {})
				end
			end

			if not parentId then
				parentId = ROOT_REF
			end

			-- Set NEW parent directly on snapshot (plain table, no methods)
			snapshot.parent = parentId
			-- Recompute relative path now that parent insertion is ensured (this is the NEW path)
			relativePath = getPathFromInstance(instance, self.tree)
			if relativePath then
				snapshot.destinationPath = relativePath -- NEW path after move
				snapshot.filePath = relativePath
				snapshot.path = relativePath
				Log.info("[MOVE DEBUG ReadProcessor] NEW path computed:", relativePath)
			end
		end

		-- Flag this snapshot so downstream sync processing can treat it as a rename move
		snapshot.isRename = (property == "Name")

		Log.debug("[ReadProcessor] Created rename/move snapshot:")
		Log.debug("  - uniqueId:", snapshot.uniqueId)
		Log.debug("  - name:", snapshot.name)
		Log.debug("  - path:", snapshot.path)
		Log.debug("  - oldPath:", snapshot.oldPath or "NIL")
		Log.debug("  - isRename:", snapshot.isRename)
		Log.debug("  - class:", snapshot.class)

		-- Convert to Change format before returning
		-- Both Parent and Name changes should use "move" operation
		local change = snapshotToChange(snapshot, "move")
		Log.debug("[ReadProcessor] Converted rename/move to Change format - op:", change and change.op or "nil")

		if change then
			Log.info(
				"[MOVE/RENAME DEBUG ReadProcessor] ✓ FINAL CHANGE created - op:",
				change.op,
				"oldPath:",
				change.oldPath or "NIL",
				"path (new):",
				change.path or "NIL",
				"uniqueId:",
				change.uniqueId or "NIL",
				"property:",
				property
			)
		end

		return change
	end

	-- Get the file path for this instance
	local relativePath = getPathFromInstance(instance, self.tree)

	-- Always include the persistent uniqueId so the backend can resolve the node
	local uidAttrForUpdate = UniqueIdHelpers.getUniqueId(instance)
	if not uidAttrForUpdate then
		Log.warn("[ReadProcessor.onChange] Instance missing uniqueId attribute:", instance:GetFullName())
		return nil
	end

	-- For script content changes, use the old "write" operation flow
	if property == "Source" or getClassName(instance) == property then
		if instance:IsA("LuaSourceContainer") then
			-- Create internal snapshot (plain table)
			local snapshot = {
				id = id,
				name = instance.Name,
				class = instance.ClassName,
				path = relativePath,
				filePath = relativePath,
				uniqueId = uidAttrForUpdate,
				content = instance.Source,
				properties = {
					[property] = {
						String = instance.Source,
					},
				},
			}

			-- Convert to Change format as "update" (write with isNew=false)
			local change = snapshotToChange(snapshot, "update")
			Log.debug(
				"[ReadProcessor] Converted script content change to Change format - op:",
				change and change.op or "nil"
			)
			return change
		end
	end

	-- For all other property changes (including Parts), use updateInstance operation
	-- This handles: Color, Size, Position, Anchored, Transparency, custom attributes, etc.

	Log.debug(
		"[ReadProcessor.onChange] Processing property/attribute change for updateInstance - instance:",
		instance:GetFullName(),
		"property:",
		property or "nil"
	)

	-- Determine if this is a property or attribute change
	local isAttribute = false
	local propertyValue = nil

	-- Check if it's an attribute first
	local attributeValue = instance:GetAttribute(property or "")
	if attributeValue ~= nil then
		isAttribute = true
		propertyValue = attributeValue
		Log.debug("[ReadProcessor.onChange] Detected attribute change:", property, "=", tostring(attributeValue))
	else
		-- Try to read as property
		local success, value = pcall(function()
			return (instance :: any)[property]
		end)

		if success and value ~= nil then
			propertyValue = value
			Log.debug("[ReadProcessor.onChange] Detected property change:", property, "=", tostring(value))
		else
			Log.warn(
				"[ReadProcessor.onChange] Could not read property/attribute:",
				property,
				"from instance:",
				instance:GetFullName()
			)
			return nil
		end
	end

	-- Build the updateInstance snapshot
	local snapshot = {
		id = id,
		name = instance.Name,
		class = instance.ClassName,
		path = relativePath,
		filePath = relativePath,
		uniqueId = uidAttrForUpdate,
	}

	if isAttribute then
		-- Attribute change - attributes are always simple types
		snapshot.attributes = {
			[property] = propertyValue,
		}
		Log.debug("[ReadProcessor.onChange] Created updateInstance snapshot with attributes:", snapshot.attributes)
	else
		-- Property change - serialize using PropertySerializer
		local serializedValue = PropertySerializer.serializePropertyValue(property, instance, propertyValue)

		if serializedValue ~= nil then
			snapshot.properties = {
				[property] = serializedValue,
			}
			Log.debug("[ReadProcessor.onChange] Created updateInstance snapshot with properties:", snapshot.properties)
		else
			Log.warn("[ReadProcessor.onChange] Failed to serialize property:", property, "- skipping")
			return nil
		end
	end

	-- Convert to Change format as "updateInstance"
	local change = snapshotToChange(snapshot, "updateInstance")
	Log.debug(
		"[ReadProcessor] Converted property/attribute change to updateInstance format - op:",
		change and change.op or "nil"
	)
	return change
end

function ReadProcessor:onRemove(instance: Instance): Types.Ref?
	Log.trace("Detected removal of", instance)

	local id = self.tree:getId(instance)

	if not id then
		-- Check if the instance has a uniqueId attribute - it might be a valid instance
		-- that wasn't in the Tree due to reconnection or other Tree population issues
		-- New sync format: 12-char base32 IDs (e.g., "YGVJ457VATGG")
		-- Legacy: 3-char service IDs (e.g., "sss", "rs1")
		local uniqueId = UniqueIdHelpers.getUniqueId(instance)
		if uniqueId and typeof(uniqueId) == "string" and (#uniqueId == 12 or #uniqueId == 3) then
			-- Register in Tree
			id = uniqueId
			self.tree:insertInstance(instance, id, {})
			Log.info("Recovered unknown instance during removal:", instance:GetFullName(), "with uniqueId:", uniqueId)
		else
			Log.trace("Unknown instance without valid uniqueId. Skipping..")
			return nil
		end
	end

	-- Get the uniqueId from the instance attribute for consistent removal processing
	local uniqueId = UniqueIdHelpers.getUniqueId(instance)
	if not uniqueId then
		Log.warn("[ReadProcessor.onRemove] Instance missing uniqueId attribute:", instance:GetFullName())
		-- Fallback to using the ID directly (already a string)
		uniqueId = id
	end

	-- Remove from tree since we're not using move detection
	self.tree:removeById(id)

	-- Return the 3-character uniqueId string instead of the Tree ID
	return uniqueId
end

-- Public API: delegates to the local helper function
function ReadProcessor.shouldSyncProperties(instance: Instance, property: string?): boolean
	return shouldSyncProperties(instance, property)
end

-- Build a structure-only BFS snapshot suitable for bulk import (no heavy properties/content)
function ReadProcessor:buildSubtreeSnapshotBfs(
	root: Instance
): { nodesByLevel: { [number]: { [number]: any } }, flat: { [number]: any } }
	local nodesByLevel = {}
	local flat = {}

	local queue = { root }
	local level = 1
	local visited = {}

	while #queue > 0 do
		local nextLevel = {}
		nodesByLevel[level] = {}

		for _, inst in ipairs(queue) do
			if not visited[inst] then
				visited[inst] = true
				local path = getPathFromInstance(inst, self.tree)
				if path then
					local parentPath
					local slash = string.find(path, "/[^/]*$")
					if slash then
						parentPath = string.sub(path, 1, slash - 1)
					end

					local uid = UniqueIdHelpers.getUniqueId(inst)
					if not uid then
						uid = generateUniqueId()
						UniqueIdHelpers.setUniqueId(inst, uid)
					end

					-- Get parent's uniqueId for proper hierarchy
					local parentUniqueId = nil
					if inst.Parent and inst.Parent ~= game then
						parentUniqueId = UniqueIdHelpers.getUniqueId(inst.Parent)
						if not parentUniqueId then
							-- Try to use predictable service ID first
							local serviceId = getServiceUniqueId(inst.Parent.Name)
							if serviceId then
								parentUniqueId = serviceId
								UniqueIdHelpers.setUniqueId(inst.Parent, serviceId)
							else
								-- Fallback to random ID for non-service folders
								parentUniqueId = generateUniqueId()
								UniqueIdHelpers.setUniqueId(inst.Parent, parentUniqueId)
							end
						end
					end

					-- Extract script content for bulk import
					local content = nil
					if inst:IsA("LuaSourceContainer") then
						content = inst.Source
					end

					-- Collect properties and attributes using centralized helper
					local properties, attributes = collectPropertiesAndAttributes(inst)

					local node = {
						name = inst.Name,
						class = inst.ClassName,
						path = path,
						parentPath = parentPath,
						uniqueId = uid,
						parentId = parentUniqueId, -- CRITICAL: Include parentId for hierarchy
						content = content, -- Include script content for bulk import
						properties = properties,
						attributes = attributes,
					}
					table.insert(nodesByLevel[level], node)
					table.insert(flat, node)
				end

				for _, child in ipairs(inst:GetChildren()) do
					table.insert(nextLevel, child)
				end
			end
		end

		queue = nextLevel
		level += 1
	end

	return { nodesByLevel = nodesByLevel, flat = flat }
end

return ReadProcessor
