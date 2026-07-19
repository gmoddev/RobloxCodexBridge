
-- deserialize: Recreate instance from serialized data during rollback
-- Used by operation-based rollback system (Task 048 - LEMON-1052)
-- Recreates instance, properties, attributes, script source, and all descendants

local Codex = script:FindFirstAncestor("Codex")
local Log = require(Codex.Log)
local helpers = require(script.Parent.helpers)
local UniqueIdHelpers = require(Codex.Util.UniqueIdHelpers)
local WriteHelpers = require(Codex.Core.Processor.Write.Helpers)
local PropertyConverter = require(Codex.Core.Processor.Write.PropertyConverter)

local function applyProperties(instance: Instance, properties: { [string]: any })
	for propName, value in pairs(properties) do
		local success, err = pcall(function()
			local convertedValue = PropertyConverter.convertPropertyValue(propName, value, instance);
			(instance :: any)[propName] = convertedValue
		end)
		if not success then
			Log.warn(
				string.format("[StudioActions.deserialize] Failed to set property %s: %s", propName, tostring(err))
			)
		end
	end
end

local function applyAttributes(tree: any, instance: Instance, attributes: { [string]: any })
	for name, value in pairs(attributes) do
		if not UniqueIdHelpers.isInternalUniqueIdAttribute(name) then
			local success, err = WriteHelpers.applyAttribute(instance, name, value, tree)
			if not success then
				Log.warn(
					string.format("[StudioActions.deserialize] Failed to set attribute %s: %s", name, tostring(err))
				)
			end
		end
	end
end

-- Recursively create instance tree from serialized data
local function createInstanceTree(
	tree: any,
	parent: Instance,
	data: {
		className: string,
		name: string,
		uniqueId: string?,
		properties: { [string]: any }?,
		attributes: { [string]: any }?,
		source: string?,
		children: { any }?,
	},
	preserveUniqueId: string?
): (Instance?, string?)
	-- Create the instance
	local success, instance = pcall(function()
		return Instance.new(data.className)
	end)

	if not success or not instance then
		return nil, string.format("Failed to create instance of class: %s", data.className)
	end

	instance.Name = data.name

	-- Apply properties
	if data.properties then
		applyProperties(instance, data.properties)
	end

	-- Apply attributes
	if data.attributes then
		applyAttributes(tree, instance, data.attributes)
	end

	-- Apply script source
	if data.source and instance:IsA("LuaSourceContainer") then
		pcall(function()
			(instance :: any).Source = data.source
		end)
	end

	-- Parent to Studio
	instance.Parent = parent

	-- Register with Tree
	-- Use preserved uniqueId if provided (for root instance), otherwise generate new
	local uniqueId: string
	if preserveUniqueId then
		uniqueId = preserveUniqueId
		UniqueIdHelpers.setUniqueId(instance, uniqueId)
		tree:insertInstance(instance, uniqueId, {})
	else
		uniqueId = helpers.registerNewInstance(tree, instance)
	end

	-- Recursively create children
	if data.children then
		for _, childData in ipairs(data.children) do
			local childInstance, childError = createInstanceTree(tree, instance, childData, nil)
			if not childInstance then
				Log.warn("[StudioActions.deserialize] Failed to create child:", childError)
				-- Continue with other children instead of failing entirely
			end
		end
	end

	return instance, nil
end

-- Main handler
return function(
	self,
	params: {
		parentUniqueId: string,
		className: string,
		serialized: string, -- JSON-encoded serialized data
		uniqueId: string?, -- Optional: preserve original uniqueId
	}
): {
	status: string,
	uniqueId: string?,
	path: string?,
	className: string?,
	childCount: number?,
	error: string?,
}
	Log.info(
		string.format(
			"[StudioActions.deserialize] BEGIN - Creating %s under parent %s",
			params.className,
			params.parentUniqueId
		)
	)

	-- Find parent
	local parent = self.tree:getInstance(params.parentUniqueId)
	if not parent then
		Log.warn("[StudioActions.deserialize] Parent not found:", params.parentUniqueId)
		return {
			status = "failed",
			error = string.format("Parent instance not found: %s", params.parentUniqueId),
		}
	end

	-- Parse serialized data
	local HttpService = game:GetService("HttpService")
	local success, data = pcall(function()
		return HttpService:JSONDecode(params.serialized)
	end)

	if not success then
		Log.error("[StudioActions.deserialize] Failed to parse JSON:", data)
		return {
			status = "failed",
			error = "Failed to parse serialized data",
		}
	end

	-- Validate data matches expected class
	if data.className ~= params.className then
		Log.warn(
			string.format(
				"[StudioActions.deserialize] Class mismatch: expected %s, got %s",
				params.className,
				data.className
			)
		)
		-- Continue anyway - trust the serialized data
	end

	-- Create the instance tree
	local instance, err = createInstanceTree(self.tree, parent, data, params.uniqueId)

	if not instance then
		Log.error("[StudioActions.deserialize] Failed to create instance:", err)
		return {
			status = "failed",
			error = err or "Failed to create instance",
		}
	end

	-- Count descendants
	local childCount = #instance:GetDescendants()

	local path = helpers.getInstancePath(instance)
	local uniqueId = UniqueIdHelpers.getUniqueId(instance)

	Log.info(
		string.format(
			"[StudioActions.deserialize] SUCCESS - Created %s at %s with %d descendants",
			params.className,
			path,
			childCount
		)
	)

	return {
		status = "completed",
		uniqueId = uniqueId,
		path = path,
		className = instance.ClassName,
		childCount = childCount,
	}
end
