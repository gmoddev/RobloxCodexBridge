local HttpService = game:GetService("HttpService")

local Codex = script:FindFirstAncestor("Codex")
local Types = require(Codex.Types)
local Log = require(Codex.Log)
local Dom = require(Codex.Dom)
local Error = require(Codex.Core.Error)
local UniqueIdHelpers = require(Codex.Util.UniqueIdHelpers)
local Helpers = require(script.Parent.Helpers)
local PropertyConverter = require(script.Parent.PropertyConverter)

local UpdateProcessor = {}
UpdateProcessor.__index = UpdateProcessor

function UpdateProcessor.new(parent)
	return setmetatable({
		parent = parent,
		tree = parent.tree,
		ProjectApi = parent.ProjectApi,
	}, UpdateProcessor)
end

-- Helper: Extract fields from Change format for processor logic
-- Extracts name from path when available, with defensive fallback to change.name field
local function extractFieldsFromChange(change: any): any
	local name = change.path and change.path:match("[^/]+$") or change.name or "Unknown"

	-- Use uniqueId directly (already a string)
	local id = change.uniqueId

	-- Extract and convert properties from new API format
	local properties = {}
	if change.properties then
		for propName, propValue in pairs(change.properties) do
			local convertedValue = PropertyConverter.convertPropertyValue(propName, propValue)
			if convertedValue ~= nil then
				properties[propName] = convertedValue
			end
		end
	end

	-- Extract attributes from new API format
	local attributes = {}
	if change.attributes then
		for attrName, attrValue in pairs(change.attributes) do
			attributes[attrName] = attrValue
		end
	end

	return {
		id = id,
		name = name,
		class = change.robloxClass or change.class, -- Support both field names
		path = change.path,
		content = change.content,
		uniqueId = change.uniqueId,
		properties = properties,
		attributes = attributes,
		meta = {},
	}
end

function UpdateProcessor:applyUpdate(change: any, initial: boolean?): Instance?
	Log.debug("[UpdateProcessor] applyUpdate called:", change)
	-- Handle updateInstance operation (update attributes/properties)
	if change.op == "updateInstance" then
		return self:applyInstanceUpdate(change, initial)
	end

	-- Extract fields from Change format (for write operations)
	local snapshot = extractFieldsFromChange(change)
	Log.debug("[UpdateProcessor] snapshot:", snapshot)
	local id = snapshot.id

	Log.debug("[UpdateProcessor] applyUpdate called:", {
		id = id,
		name = snapshot.name,
		class = snapshot.class,
		contentExists = snapshot.content ~= nil,
		contentLength = snapshot.content and string.len(snapshot.content) or nil,
	})

	-- TIMESTAMP CHECK
	local newTimestamp = snapshot.timestamp
	local existingTimestamp = self.tree:getTimestamp(id)
	Log.debug("[UpdateProcessor] Timestamp check:")
	Log.debug("  - newTimestamp:", newTimestamp or "nil")
	Log.debug("  - existingTimestamp:", existingTimestamp or "nil")
	Log.debug(
		"  - will skip update:",
		(newTimestamp and existingTimestamp and newTimestamp <= existingTimestamp) and "YES" or "NO"
	)

	if newTimestamp and existingTimestamp and newTimestamp <= existingTimestamp then
		Log.debug("[UpdateProcessor] SKIPPING UPDATE due to timestamp check!")
		Log.trace(
			string.format(
				"[WriteProcessor:applyUpdate] Skipping UPDATE for %s (ID: %s), incoming timestamp (%s) is not newer than existing (%s).",
				snapshot.name or "N/A",
				id,
				tostring(newTimestamp),
				tostring(existingTimestamp)
			)
		)
		return self.tree:getInstance(id) -- Return existing instance if any
	end

	Log.debug("[UpdateProcessor] Timestamp check passed, continuing with update...")

	-- ID is already a string (Types.Ref)
	local internalId: Types.Ref = id
	Log.debug("[UpdateProcessor] Using ID:", internalId)

	Log.debug("[UpdateProcessor] Looking up instance by uniqueId (prioritizing tree)")

	local targetUniqueId = snapshot.uniqueId
	local targetPath = snapshot.path
	local instance = nil

	-- PRIORITY 1: Look up by ID in tree (most reliable, handles name changes)
	instance = self.tree:getInstance(internalId)
	if instance then
		Log.debug("  - FOUND instance in tree:", instance:GetFullName(), "(" .. instance.ClassName .. ")")

		-- Verify the uniqueId matches (should always be true if tree is consistent)
		local existingUniqueId = UniqueIdHelpers.getUniqueId(instance)
		if existingUniqueId and existingUniqueId ~= targetUniqueId then
			Log.warn(
				"[UpdateProcessor] Tree instance has mismatched uniqueId! Expected:",
				targetUniqueId,
				"Got:",
				existingUniqueId
			)
		end
	end

	-- PRIORITY 2: Search by uniqueId + path if not found in tree
	if not instance and targetPath and targetUniqueId then
		Log.debug("  - Not in tree, searching for path:", targetPath, "AND uniqueId:", targetUniqueId)
		for _, inst in ipairs(game:GetDescendants()) do
			if UniqueIdHelpers.getUniqueId(inst) == targetUniqueId then
				local instancePath = inst:GetFullName():gsub("^game%.", ""):gsub("%.([^%.]+)$", "/%1"):gsub("%.", "/")
				if instancePath == targetPath then
					instance = inst
					Log.debug("  - FOUND instance by path search:", inst:GetFullName(), "(" .. inst.ClassName .. ")")
					break
				end
			end
		end
	end

	if not instance and targetPath and targetUniqueId then
		Log.debug("  - NO INSTANCE FOUND with path:", targetPath, "AND uniqueId:", targetUniqueId)
		Log.debug("  - Checking if any instance exists at path (ignoring uniqueId)...")
		for _, inst in ipairs(game:GetDescendants()) do
			local instancePath = inst:GetFullName():gsub("^game%.", ""):gsub("%.([^%.]+)$", "/%1"):gsub("%.", "/")
			if instancePath == targetPath then
				local existingUniqueId = UniqueIdHelpers.getUniqueId(inst)
				Log.debug(
					"  - FOUND instance at path:",
					inst:GetFullName(),
					"with uniqueId:",
					existingUniqueId or "(none)"
				)

				-- FIX: If instance exists at path but has wrong/missing uniqueId, update it
				if not existingUniqueId or existingUniqueId ~= targetUniqueId then
					Log.info(
						"[UpdateProcessor] Updating uniqueId for instance at path:",
						targetPath,
						"from:",
						existingUniqueId or "(none)",
						"to:",
						targetUniqueId
					)
					UniqueIdHelpers.setUniqueId(inst, targetUniqueId)
					instance = inst

					-- Also update the tree mapping
					self.tree:insertInstance(inst, internalId, {}, nil)
					break
				end
			end
		end
	end

	if not instance then
		Log.debug("[UpdateProcessor] INSTANCE NOT FOUND - treating as new creation and delegating to AdditionProcessor")
		Log.warn("[WriteProcessor] Failed to update instance: instance is nil. ID:", internalId)

		-- Convert the SnapshotUpdate into an AddedSnapshot format for AdditionProcessor
		-- The update snapshot should already have most fields we need
		local addedSnapshot = {
			id = id,
			name = snapshot.name,
			class = snapshot.class,
			parent = snapshot.parent,
			properties = snapshot.properties,
			content = snapshot.content,
			meta = snapshot.meta,
		}

		-- Validate required fields for AddedSnapshot
		if not addedSnapshot.name or not addedSnapshot.class or not addedSnapshot.parent then
			Log.warn(
				"[UpdateProcessor] Gracefully skipping incomplete update - missing required fields.",
				"ID:",
				id,
				"Name:",
				addedSnapshot.name or "nil",
				"Class:",
				addedSnapshot.class or "nil",
				"ParentRef:",
				addedSnapshot.parent or "nil"
			)
			-- Return nil to skip without breaking sync flow
			return nil
		end

		Log.debug(
			"[UpdateProcessor] Converting update to addition. Delegating to AdditionProcessor for:",
			addedSnapshot.name
		)
		instance = self.parent:applyAddition(addedSnapshot, initial)

		if not instance then
			Log.warn(
				"[UpdateProcessor] Gracefully skipping - AdditionProcessor could not create instance for:",
				addedSnapshot.name
			)
			-- Return nil to skip without breaking sync flow
			return nil
		end

		Log.debug("[UpdateProcessor] Successfully created instance via AdditionProcessor:", instance:GetFullName())
	end

	-- UPDATE: If the instance is parented and the snapshot indicates a rename, apply it here
	if instance.Parent and snapshot.name and snapshot.name ~= instance.Name then
		Log.debug(
			"[WriteProcessor:applyUpdate] Detected name change for instance. Old:",
			instance.Name,
			"New:",
			snapshot.name
		)

		-- Pause watcher during rename
		if self.parent.watcher then
			self.parent.watcher:pause(function()
				instance.Name = snapshot.name
			end)
		else
			instance.Name = snapshot.name
		end

		Log.trace("[WriteProcessor:applyUpdate] Applied name change. Instance is now:", instance.Name)
	end

	-- Apply property updates from new API format (already converted to Roblox values)
	if snapshot.properties and next(snapshot.properties) then
		Log.debug("[UpdateProcessor] Applying properties to", instance.Name, ":", snapshot.properties)

		-- Track if we processed Source/JSON for Parts (to avoid re-processing individual properties)
		local processedPartViaSource = false

		for property, value in snapshot.properties do
			-- Properties are already converted to Roblox values by extractFieldsFromChange
			-- Try direct assignment first
			local decodedValue = value

			-- Handle Source property for Parts - Parts don't have Source properties, but Source contains Part JSON data
			if property == "Source" and snapshot.class == "Part" then
				processedPartViaSource = true
				-- decodedValue should contain the JSON string, parse it to get Part properties
				local parseSuccess, partData = pcall(function()
					return HttpService:JSONDecode(decodedValue)
				end)

				if parseSuccess and partData then
					-- Define read-only properties that shouldn't be set
					local readOnlyProperties = {
						"Assembly",
						"Attributes",
						"Tags",
						"Origin", -- Skip Origin - we use its data in CFrame processing but don't set it directly
						"AssemblyAngularVelocity",
						"AssemblyCenterOfMass",
						"AssemblyLinearVelocity",
						"AssemblyMass",
						"AssemblyRootPart",
						"CenterOfMass",
						"CurrentPhysicalProperties",
						"ExtentsCFrame",
						"ExtentsSize",
						"Mass",
						"ReceiveAge",
						"ResizeIncrement",
						"ResizeableFaces",
						"Position",
						"Orientation",
						"Rotation", -- These conflict with CFrame
					}

					-- Function to apply Part properties with proper error handling
					local function applyPartProperties()
						local appliedCount = 0
						local skippedCount = 0
						local failedCount = 0

						-- Check network ownership first (variables used for debugging/future use)
						-- local canSetNetworkOwnership, ownershipReason = instance:CanSetNetworkOwnership()
						-- local currentOwner = instance:GetNetworkOwner()

						-- Apply each Part property from the JSON
						for propName, propValue in pairs(partData) do
							-- Skip read-only properties and complex structures
							local shouldSkip = false
							for _, readOnlyProp in ipairs(readOnlyProperties) do
								if propName == readOnlyProp then
									shouldSkip = true
									break
								end
							end

							if shouldSkip then
								skippedCount = skippedCount + 1
								continue
							end

							local applySuccess, applyErr = pcall(function()
								if propName == "CFrame" and type(propValue) == "table" and propValue.Position then
									-- Handle CFrame specially - prefer Origin.Position over CFrame.Position if available
									local pos = propValue.Position
									local orient = propValue.Orientation or { 0, 0, 0 }

									-- Log current position before change
									local currentCFrame = instance.CFrame

									-- Check if Origin data exists and intelligently choose between Origin and CFrame
									if partData.Origin and partData.Origin.Position then
										local originPos = partData.Origin.Position
										local originOrient = partData.Origin.Orientation or { 0, 0, 0 }
										local cframePos = propValue.Position
										local currentPos = currentCFrame.Position

										-- Determine which position is the fresh edit by comparing to current Studio position
										local originMatchesCurrent = math.abs(originPos[2] - currentPos.Y) < 0.01
										local cframeMatchesCurrent = math.abs(cframePos[2] - currentPos.Y) < 0.01

										if originMatchesCurrent and not cframeMatchesCurrent then
											-- CFrame differs, Origin matches current - CFrame is the fresh edit
											pos = propValue.Position
											orient = propValue.Orientation or { 0, 0, 0 }
										else
											-- Default to Origin position (covers all other cases)
											pos = originPos
											orient = originOrient
										end
									end

									local newCFrame = CFrame.new(pos[1], pos[2], pos[3])
										* CFrame.Angles(math.rad(orient[1]), math.rad(orient[2]), math.rad(orient[3]))
									instance.CFrame = newCFrame

									-- Verify the change took effect and add delayed verification
									local finalCFrame = instance.CFrame
									if finalCFrame.Position ~= newCFrame.Position then
										Log.warn("[WriteProcessor] CFrame position mismatch after setting")
									end

									-- Add delayed verification to catch async overrides
									task.spawn(function()
										task.wait(0.1) -- Wait 100ms
										local delayedCFrame = instance.CFrame
										if delayedCFrame.Position.Y ~= newCFrame.Position.Y then
											Log.warn("[WriteProcessor] CFrame position changed after 100ms delay")
										end
									end)
								elseif propName == "Size" and type(propValue) == "table" then
									local newSize = Vector3.new(propValue[1], propValue[2], propValue[3])
									instance.Size = newSize
								elseif propName == "Color" and type(propValue) == "table" then
									local newColor =
										Color3.new(propValue[1] / 255, propValue[2] / 255, propValue[3] / 255)
									instance.Color = newColor
								elseif propName == "Material" and type(propValue) == "string" then
									local materialEnum = Enum.Material[propValue]
									if materialEnum then
										instance.Material = materialEnum
									else
										error("Invalid Material: " .. tostring(propValue))
									end
								elseif propName == "Shape" and type(propValue) == "string" then
									local shapeEnum = Enum.PartType[propValue]
									if shapeEnum then
										instance.Shape = shapeEnum
									else
										error("Invalid Shape: " .. tostring(propValue))
									end
								elseif propName == "BrickColor" and type(propValue) == "string" then
									-- Only set BrickColor if Color wasn't already set (avoid conflicts)
									if not partData.Color then
										local brickColorSuccess, brickColor = pcall(function()
											return BrickColor.new(propValue)
										end)
										if brickColorSuccess then
											instance.BrickColor = brickColor
										else
											error("Invalid BrickColor: " .. tostring(propValue))
										end
									end
								elseif propName == "CustomPhysicalProperties" then
									-- CustomPhysicalProperties expects PhysicalProperties object or nil, not boolean
									if type(propValue) == "boolean" and not propValue then
										instance.CustomPhysicalProperties = nil
									end
								-- Handle simple property types (boolean, number, string)
								elseif
									type(propValue) == "boolean"
									or type(propValue) == "number"
									or type(propValue) == "string"
								then
									instance[propName] = propValue
								end
							end)

							if applySuccess then
								appliedCount = appliedCount + 1
							else
								failedCount = failedCount + 1
								Log.warn(
									"[WriteProcessor UPDATE] Failed to apply Part property",
									propName,
									"Value:",
									propValue,
									"Error:",
									applyErr
								)
							end
						end

						return appliedCount > 0
					end

					-- Apply properties with or without watcher pause
					local applyResult
					if self.parent.watcher then
						self.parent.watcher:pause(function()
							applyResult = applyPartProperties()
						end)
					else
						applyResult = applyPartProperties()
					end

					if applyResult then
						Log.debug("[WriteProcessor UPDATE] Part properties applied successfully")
					else
						Log.warn("[WriteProcessor UPDATE] No Part properties were successfully applied")
					end
				else
					Log.error(
						"[WriteProcessor UPDATE] Failed to parse Part JSON from Source property. Error:",
						partData
					)
				end

				-- Skip normal property handling since we've processed the Part data
				continue
			end

			-- Skip all Part properties ONLY if they were already handled via JSON Source property
			-- If properties come directly (not via Source), we should still apply them
			if instance:IsA("Part") and processedPartViaSource then
				local partJsonProperties = {
					"CFrame",
					"Size",
					"Color",
					"BrickColor",
					"Material",
					"MaterialVariant",
					"Reflectance",
					"Transparency",
					"CastShadow",
					"Archivable",
					"Locked",
					"EnableFluidForces",
					"CanCollide",
					"CanTouch",
					"CollisionGroup",
					"Anchored",
					"CustomPhysicalProperties",
					"Massless",
					"RootPriority",
					"Shape",
				}

				local shouldSkip = false
				for _, jsonProp in ipairs(partJsonProperties) do
					if property == jsonProp then
						shouldSkip = true
						break
					end
				end

				if shouldSkip then
					Log.debug("[UpdateProcessor] Skipping Part property (already processed via Source):", property)
					continue
				end
			end

			-- Pause watcher during property writes
			if self.parent.watcher then
				self.parent.watcher:pause(function()
					-- Try direct assignment first (for converted values)
					local success, err = pcall(function()
						instance[property] = decodedValue
					end)

					if not success then
						Log.warn(
							"[UpdateProcessor] Failed to set property",
							property,
							"on",
							instance.Name,
							"Error:",
							err
						)
						-- Fallback: try using Dom.writeProperty
						local writeSuccess, reason = Dom.writeProperty(instance, property, decodedValue)
						if not writeSuccess then
							local writeErr = Error.new(Error.WriteFailed, property, instance, reason.kind)
							Log.warn(writeErr)
						end
					else
						Log.debug(
							"[UpdateProcessor] Set property",
							property,
							"=",
							tostring(decodedValue),
							"on",
							instance.Name
						)
					end
				end)
			else
				-- Try direct assignment first (for converted values)
				local success, err = pcall(function()
					instance[property] = decodedValue
				end)

				if not success then
					Log.warn("[UpdateProcessor] Failed to set property", property, "on", instance.Name, "Error:", err)
					-- Fallback: try using Dom.writeProperty
					local writeSuccess, reason = Dom.writeProperty(instance, property, decodedValue)
					if not writeSuccess then
						local writeErr = Error.new(Error.WriteFailed, property, instance, reason.kind)
						Log.warn(writeErr)
					end
				else
					Log.debug(
						"[UpdateProcessor] Set property",
						property,
						"=",
						tostring(decodedValue),
						"on",
						instance.Name
					)
				end
			end
		end
	end

	-- Apply attribute updates from new API format
	if snapshot.attributes and next(snapshot.attributes) then
		Log.debug("[UpdateProcessor] Applying attributes to", instance.Name, ":", snapshot.attributes)

		for attrName, attrValue in snapshot.attributes do
			if self.parent.watcher then
				self.parent.watcher:pause(function()
					-- Use Helpers.applyAttribute to handle special attributes like _PrimaryPartUniqueId
					local success, err = Helpers.applyAttribute(instance, attrName, attrValue, self.tree)

					if success then
						Log.debug(
							"[UpdateProcessor] Set attribute",
							attrName,
							"=",
							tostring(attrValue),
							"on",
							instance.Name
						)
					else
						Log.warn(
							"[UpdateProcessor] Failed to set attribute",
							attrName,
							"on",
							instance.Name,
							"Error:",
							err
						)
					end
				end)
			else
				-- Use Helpers.applyAttribute to handle special attributes like _PrimaryPartUniqueId
				local success, err = Helpers.applyAttribute(instance, attrName, attrValue, self.tree)

				if success then
					Log.debug(
						"[UpdateProcessor] Set attribute",
						attrName,
						"=",
						tostring(attrValue),
						"on",
						instance.Name
					)
				else
					Log.warn("[UpdateProcessor] Failed to set attribute", attrName, "on", instance.Name, "Error:", err)
				end
			end
		end
	end

	-- Handle content updates for script instances
	Log.debug("[UpdateProcessor] Checking content update conditions:")
	Log.debug("  - snapshot.content exists:", snapshot.content ~= nil)
	Log.debug("  - snapshot.content length:", snapshot.content and string.len(snapshot.content) or "nil")
	Log.debug("  - snapshot.class:", snapshot.class or "nil")
	Log.debug("  - instance found:", instance ~= nil)
	Log.debug("  - instance name:", instance and instance.Name or "nil")
	Log.debug("  - instance class:", instance and instance.ClassName or "nil")

	if
		snapshot.content
		and (snapshot.class == "ModuleScript" or snapshot.class == "Script" or snapshot.class == "LocalScript")
	then
		Log.debug("[UpdateProcessor] ✅ Conditions met - updating script content")
		Log.trace("[WriteProcessor UPDATE] Setting Source for", instance.Name, "Length:", string.len(snapshot.content))

		-- Pause watcher during source update
		if self.parent.watcher then
			self.parent.watcher:pause(function()
				local contentSuccess, contentErr = pcall(function()
					-- Use Dom.writeProperty so ScriptEditorService.UpdateSourceAsync is employed,
					-- refreshing any open script editors immediately.
					return Dom.writeProperty(instance, "Source", snapshot.content)
				end)
				if contentSuccess then
					Log.trace(
						"[WriteProcessor UPDATE] Successfully updated Source via Dom.writeProperty for",
						instance.Name
					)
				else
					Log.error(
						"[WriteProcessor UPDATE ERROR] Failed to set Source for",
						instance.Name,
						"Error:",
						contentErr
					)
				end
			end)
		else
			local contentSuccess, contentErr = pcall(function()
				return Dom.writeProperty(instance, "Source", snapshot.content)
			end)
			if contentSuccess then
				Log.trace(
					"[WriteProcessor UPDATE] Successfully updated Source via Dom.writeProperty for",
					instance.Name
				)
			else
				Log.error("[WriteProcessor UPDATE ERROR] Failed to set Source for", instance.Name, "Error:", contentErr)
			end
		end
	-- Skip Part content updates - Parts are handled via Source property above
	elseif snapshot.content and snapshot.class == "Part" then
		Log.trace("[WriteProcessor UPDATE] Skipping Part content processing - handled via Source property")
	elseif snapshot.content then
		Log.trace("[WriteProcessor UPDATE] Skipping Source set for non-script/non-Part class:", snapshot.class)
	end

	-- Update the tree with new metadata and timestamp
	if snapshot.meta then
		self.tree:updateMeta(internalId, snapshot.meta)
	end
	if newTimestamp then
		self.tree:setTimestamp(internalId, newTimestamp)
	end

	if not initial then
		Helpers.setWaypoint("Update", instance.Name)
	end

	Log.trace("[WriteProcessor] Update successful for:", instance.Name)
	return instance
end

-- Apply updateInstance operation (update attributes/properties without content changes)
function UpdateProcessor:applyInstanceUpdate(change: any, initial: boolean?): Instance?
	Log.debug("[UpdateProcessor] applyInstanceUpdate called for:", change.path or "unknown")

	-- Find the instance by path and uniqueId
	local targetPath = change.path
	local targetUniqueId = change.uniqueId

	if not targetPath or not targetUniqueId then
		Log.warn("[UpdateProcessor:applyInstanceUpdate] Missing path or uniqueId")
		return nil
	end

	-- Search for instance
	local instance = nil
	for _, inst in ipairs(game:GetDescendants()) do
		if UniqueIdHelpers.getUniqueId(inst) == targetUniqueId then
			local instancePath = inst:GetFullName():gsub("^game%.", ""):gsub("%.([^%.]+)$", "/%1"):gsub("%.", "/")
			if instancePath == targetPath then
				instance = inst
				Log.debug("[UpdateProcessor:applyInstanceUpdate] Found instance:", inst:GetFullName())
				break
			end
		end
	end

	if not instance then
		Log.warn("[UpdateProcessor:applyInstanceUpdate] Instance not found for path:", targetPath)
		return nil
	end

	-- Apply attribute updates
	if change.attributes then
		-- Count attributes properly (dictionary, not array)
		local attrCount = 0
		for _ in pairs(change.attributes) do
			attrCount = attrCount + 1
		end
		Log.debug("[UpdateProcessor:applyInstanceUpdate] Applying", attrCount, "attribute updates")

		for attrName, attrValue in pairs(change.attributes) do
			-- Use Helpers.applyAttribute to handle special attributes like _PrimaryPartUniqueId
			local success, err = Helpers.applyAttribute(instance, attrName, attrValue, self.tree)

			if success then
				Log.trace("[UpdateProcessor:applyInstanceUpdate] Set attribute:", attrName, "=", tostring(attrValue))
			else
				Log.warn("[UpdateProcessor:applyInstanceUpdate] Failed to set attribute:", attrName, "Error:", err)
			end
		end
	end

	-- Apply property updates
	if change.properties then
		-- Count properties properly (dictionary, not array)
		local propCount = 0
		for _ in pairs(change.properties) do
			propCount = propCount + 1
		end
		Log.debug("[UpdateProcessor:applyInstanceUpdate] Applying", propCount, "property updates")

		for propName, propValue in pairs(change.properties) do
			-- Convert property value from server format to Roblox value
			local convertedValue = PropertyConverter.convertPropertyValue(propName, propValue)

			if convertedValue ~= nil then
				local success, err = pcall(function()
					instance[propName] = convertedValue
				end)

				if success then
					Log.trace(
						"[UpdateProcessor:applyInstanceUpdate] Set property:",
						propName,
						"=",
						tostring(convertedValue)
					)
				else
					Log.warn("[UpdateProcessor:applyInstanceUpdate] Failed to set property:", propName, "Error:", err)
				end
			else
				Log.trace("[UpdateProcessor:applyInstanceUpdate] Skipping property with nil value:", propName)
			end
		end
	end

	if not initial then
		Helpers.setWaypoint("Update Instance", instance.Name)
	end

	Log.debug("[UpdateProcessor:applyInstanceUpdate] Successfully updated:", instance:GetFullName())
	return instance
end

return UpdateProcessor
