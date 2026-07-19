
-- updateInstance: Modify instance attributes/properties

local Codex = script:FindFirstAncestor("Codex")
local Log = require(Codex.Log)
local UniqueIdHelpers = require(Codex.Util.UniqueIdHelpers)
local helpers = require(script.Parent.helpers)
local WriteHelpers = require(Codex.Core.Processor.Write.Helpers)
local PropertyConverter = require(Codex.Core.Processor.Write.PropertyConverter)

return function(
	self,
	params: {
		uniqueId: string,
		attributes: { [string]: any }?,
		properties: { [string]: any }?,
	}
): { status: string, path: string?, error: string? }
	if not params.attributes and not params.properties then
		return {
			status = "failed",
			error = "At least one of attributes or properties is required",
		}
	end

	local instance = self.tree:getInstance(params.uniqueId)
	if not instance then
		return {
			status = "failed",
			error = string.format("Instance not found: %s", params.uniqueId),
		}
	end

	-- Update attributes (use WriteHelpers.applyAttribute to handle special attributes like _PrimaryPartUniqueId)
	if params.attributes then
		local attrCount = 0
		for _ in pairs(params.attributes) do
			attrCount += 1
		end
		Log.info(
			string.format(
				"[updateInstance] Updating %d attribute(s) on %s (uniqueId: %s)",
				attrCount,
				instance.Name,
				params.uniqueId
			)
		)
		for key, value in pairs(params.attributes) do
			Log.info(string.format("[updateInstance] Applying attribute: %s = %s", key, tostring(value)))
			local success, err = WriteHelpers.applyAttribute(instance, key, value, self.tree)
			if not success then
				Log.warn(
					string.format(
						"[updateInstance] Failed to apply attribute '%s' to %s: %s",
						key,
						instance.Name,
						err or "unknown error"
					)
				)
			else
				Log.info(string.format("[updateInstance] Successfully applied attribute: %s", key))
			end
		end
	end

	-- Update properties (using PropertyConverter for comprehensive type support)
	-- Track properties that failed to set (not auto-correctable)
	local failedProperties = {}
	if params.properties then
		for key, value in pairs(params.properties) do
			-- Handle Model-specific properties that require method calls
			if instance:IsA("Model") then
				local model = instance :: Model
				local modelHandled = false

				if key == "Scale" then
					local scaleSuccess, scaleErr = pcall(function()
						model:ScaleTo(value)
					end)
					if not scaleSuccess then
						Log.warn(
							string.format(
								"[updateInstance] Failed to ScaleTo(%s): %s",
								tostring(value),
								tostring(scaleErr)
							)
						)
						table.insert(failedProperties, { key = key, error = tostring(scaleErr) })
					end
					modelHandled = true
				elseif key == "PrimaryPart" then
					-- Agent may pass PrimaryPart as a uniqueId string or {UniqueId: "..."} table
					local ppUniqueId = if type(value) == "table" then value.UniqueId else value
					if type(ppUniqueId) == "string" then
						local attrSuccess, attrErr =
							WriteHelpers.applyAttribute(instance, "_PrimaryPartUniqueId", ppUniqueId, self.tree)
						if not attrSuccess then
							Log.warn(string.format("[updateInstance] Failed to set PrimaryPart: %s", tostring(attrErr)))
							table.insert(failedProperties, { key = key, error = tostring(attrErr) })
						end
					else
						table.insert(
							failedProperties,
							{ key = key, error = "PrimaryPart requires a uniqueId string or {UniqueId: string}" }
						)
					end
					modelHandled = true
				elseif key == "Pivot" or key == "CFrame" then
					local pos = if type(value) == "table" and value.Position then value.Position else value
					if type(pos) == "table" and #pos == 3 then
						local pivotSuccess, pivotErr = pcall(function()
							model:PivotTo(CFrame.new(pos[1], pos[2], pos[3]))
						end)
						if not pivotSuccess then
							Log.warn(string.format("[updateInstance] Failed to PivotTo: %s", tostring(pivotErr)))
							table.insert(failedProperties, { key = key, error = tostring(pivotErr) })
						end
					else
						table.insert(
							failedProperties,
							{ key = key, error = "Pivot/CFrame requires {Position: [x,y,z]} or [x,y,z]" }
						)
					end
					modelHandled = true
				end

				if modelHandled then
					continue
				end
			end

			local success, err = pcall(function()
				local convertedValue = PropertyConverter.convertPropertyValue(key, value, instance)
				instance[key] = convertedValue
			end)
			if not success then
				-- Check if this key is an existing attribute that was misplaced in properties.
				-- LLMs sometimes put attribute values in the properties field instead of attributes.
				local existingAttr = instance:GetAttribute(key)
				if existingAttr ~= nil then
					-- Auto-correct: set as attribute instead of property
					local attrSuccess, attrErr = pcall(function()
						instance:SetAttribute(key, value)
					end)
					if attrSuccess then
						Log.info(
							string.format(
								"[StudioActions] Auto-corrected: set '%s' as attribute instead of property on %s",
								key,
								instance.Name
							)
						)
					else
						Log.warn(
							string.format(
								"[StudioActions] Failed to auto-correct '%s' as attribute: %s",
								key,
								tostring(attrErr)
							)
						)
						table.insert(failedProperties, { key = key, error = tostring(attrErr) })
					end
				else
					Log.warn(string.format("[StudioActions] Failed to set property %s: %s", key, tostring(err)))
					table.insert(failedProperties, { key = key, error = tostring(err) })
				end
			end
		end
	end

	Log.info(string.format("[StudioActions] Updated instance: %s", instance.Name))

	-- Read back current properties and attributes for confirmation
	local currentProperties = {}
	local hasCurrentProperties = false
	pcall(function()
		if instance:IsA("BasePart") then
			currentProperties.Color = { instance.Color.R * 255, instance.Color.G * 255, instance.Color.B * 255 }
			currentProperties.Size = { instance.Size.X, instance.Size.Y, instance.Size.Z }
			currentProperties.Anchored = instance.Anchored
			currentProperties.CFrame =
				{ Position = { instance.CFrame.Position.X, instance.CFrame.Position.Y, instance.CFrame.Position.Z } }
			hasCurrentProperties = true
		elseif instance:IsA("Model") then
			local model = instance :: Model
			currentProperties.Scale = model:GetScale()
			local extents = model:GetExtentsSize()
			currentProperties.ExtentsSize = { extents.X, extents.Y, extents.Z }
			local pivot = model:GetPivot()
			currentProperties.Pivot = { Position = { pivot.Position.X, pivot.Position.Y, pivot.Position.Z } }
			hasCurrentProperties = true
		end
	end)

	local currentAttributes = {}
	local hasCurrentAttributes = false
	for attr, value in pairs(instance:GetAttributes()) do
		if not UniqueIdHelpers.isInternalUniqueIdAttribute(attr) then
			currentAttributes[attr] = value
			hasCurrentAttributes = true
		end
	end

	return {
		status = "completed",
		path = helpers.getInstancePath(instance),
		failedProperties = #failedProperties > 0 and failedProperties or nil,
		properties = hasCurrentProperties and currentProperties or nil,
		attributes = hasCurrentAttributes and currentAttributes or nil,
	}
end
