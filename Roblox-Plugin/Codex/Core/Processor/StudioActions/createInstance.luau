
-- createInstance: Create non-script instances (Folder, Part, RemoteEvent, etc.)

local Codex = script:FindFirstAncestor("Codex")
local Log = require(Codex.Log)
local helpers = require(script.Parent.helpers)
local PropertyConverter = require(Codex.Core.Processor.Write.PropertyConverter)

return function(
	self,
	params: {
		parentId: string,
		robloxClass: string,
		name: string,
		attributes: { [string]: any }?,
		properties: { [string]: any }?,
	}
): {
	status: string,
	uniqueId: string?,
	path: string?,
	error: string?,
	failedProperties: { { key: string, error: string } }?,
}
	local parent = self.tree:getInstance(params.parentId)
	if not parent then
		return {
			status = "failed",
			error = string.format("Parent instance not found: %s", params.parentId),
		}
	end

	-- Create instance
	local success, instance = pcall(function()
		return Instance.new(params.robloxClass)
	end)

	if not success then
		return {
			status = "failed",
			error = string.format("Invalid Roblox class: %s", params.robloxClass),
		}
	end

	instance.Name = params.name

	-- Set attributes (wrapped in pcall to handle unsupported attribute types gracefully)
	if params.attributes then
		for key, value in pairs(params.attributes) do
			local attrSuccess, attrErr = pcall(function()
				instance:SetAttribute(key, value)
			end)
			if not attrSuccess then
				Log.warn(
					string.format(
						"[StudioActions] Failed to set attribute %s on %s: %s",
						key,
						params.name,
						tostring(attrErr)
					)
				)
			end
		end
	end

	-- Set properties (using PropertyConverter for comprehensive type support)
	-- With auto-correct: if a property fails to set, try setting it as an attribute instead.
	-- LLMs sometimes put attribute values in the properties field instead of attributes.
	local failedProperties = {}
	if params.properties then
		for key, value in pairs(params.properties) do
			local success, err = pcall(function()
				local convertedValue = PropertyConverter.convertPropertyValue(key, value, instance)
				instance[key] = convertedValue
			end)
			if not success then
				-- Auto-correct: try setting as attribute instead of property
				local attrSuccess, _attrErr = pcall(function()
					instance:SetAttribute(key, value)
				end)
				if attrSuccess then
					Log.info(
						string.format(
							"[StudioActions] Auto-corrected: set '%s' as attribute instead of property on %s",
							key,
							params.name
						)
					)
				else
					Log.warn(string.format("[StudioActions] Failed to set property %s: %s", key, tostring(err)))
					table.insert(failedProperties, { key = key, error = tostring(err) })
				end
			end
		end
	end

	-- Parent to Studio
	instance.Parent = parent

	-- Register instance with Tree tracking (generates uniqueId, sets attribute, registers in Tree)
	local uniqueId = helpers.registerNewInstance(self.tree, instance)

	Log.info(string.format("[StudioActions] Created %s: %s", params.robloxClass, params.name))

	return {
		status = "completed",
		uniqueId = uniqueId,
		path = helpers.getInstancePath(instance),
		failedProperties = #failedProperties > 0 and failedProperties or nil,
	}
end
