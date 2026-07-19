
-- batchRollback: Execute multiple rollback operations atomically
-- Task 048 - LEMON-1052: Operation-based rollback with event sourcing
-- Processes all operations in order, returns per-operation success/failure

local Codex = script:FindFirstAncestor("Codex")
local Log = require(Codex.Log)
local helpers = require(script.Parent.helpers)
local UniqueIdHelpers = require(Codex.Util.UniqueIdHelpers)
local HttpService = game:GetService("HttpService")

-- Import sub-handlers for reuse
local WriteHelpers = require(Codex.Core.Processor.Write.Helpers)
local PropertyConverter = require(Codex.Core.Processor.Write.PropertyConverter)

-- Types for operations
type DeleteOp = {
	type: "delete",
	uniqueId: string,
	path: string,
}

type UpdateScriptOp = {
	type: "updateScript",
	uniqueId: string,
	path: string,
	content: string,
}

type CreateInstanceOp = {
	type: "createInstance",
	uniqueId: string,
	path: string,
	parentUniqueId: string,
	className: string,
	serialized: string,
	source: string?,
}

type MoveOp = {
	type: "move",
	uniqueId: string,
	newParentUniqueId: string,
	newName: string,
	originalPath: string,
}

type UpdateInstanceOp = {
	type: "updateInstance",
	uniqueId: string,
	path: string,
	properties: { [string]: any },
	attributes: { [string]: any },
}

type BatchOperation = DeleteOp | UpdateScriptOp | CreateInstanceOp | MoveOp | UpdateInstanceOp

type OperationResult = {
	type: string,
	uniqueId: string,
	success: boolean,
	error: string?,
}

-- Helper: Apply properties to an instance (from deserialize.luau)
local function applyProperties(instance: Instance, properties: { [string]: any })
	for propName, value in pairs(properties) do
		-- Handle Model-specific method-based properties
		if propName == "_ModelScale" and instance:IsA("Model") then
			local success, err = pcall(function()
				(instance :: Model):ScaleTo(value)
			end)
			if not success then
				Log.warn(string.format("[batchRollback] Failed to ScaleTo(%s): %s", tostring(value), tostring(err)))
			end
			continue
		end

		if propName == "_ModelPivot" and instance:IsA("Model") then
			if type(value) == "table" and #value == 3 then
				local success, err = pcall(function()
					(instance :: Model):PivotTo(CFrame.new(value[1], value[2], value[3]))
				end)
				if not success then
					Log.warn(string.format("[batchRollback] Failed to PivotTo: %s", tostring(err)))
				end
			else
				Log.warn(string.format("[batchRollback] Invalid _ModelPivot value: %s", tostring(value)))
			end
			continue
		end

		-- Generic property assignment
		local success, err = pcall(function()
			local convertedValue = PropertyConverter.convertPropertyValue(propName, value);
			(instance :: any)[propName] = convertedValue
		end)
		if not success then
			Log.warn(string.format("[batchRollback] Failed to set property %s: %s", propName, tostring(err)))
		end
	end
end

-- Helper: Apply attributes to an instance
local function applyAttributes(tree: any, instance: Instance, attributes: { [string]: any })
	for name, value in pairs(attributes) do
		if not UniqueIdHelpers.isInternalUniqueIdAttribute(name) then -- Don't modify internal attributes
			local success, err = WriteHelpers.applyAttribute(instance, name, value, tree)
			if not success then
				Log.warn(string.format("[batchRollback] Failed to set attribute %s: %s", name, tostring(err)))
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
				Log.warn("[batchRollback] Failed to create child:", childError)
			end
		end
	end

	return instance, nil
end

-- Execute delete operation
local function executeDelete(tree: any, op: DeleteOp): OperationResult
	local instance = tree:getInstance(op.uniqueId)

	if not instance then
		-- Idempotent: success even if not found
		Log.debug(string.format("[batchRollback] Delete: instance not found (idempotent success): %s", op.uniqueId))
		return {
			type = "delete",
			uniqueId = op.uniqueId,
			success = true,
		}
	end

	-- Remove from Tree before destroying
	tree:removeById(op.uniqueId)

	-- Destroy the instance
	instance:Destroy()

	Log.debug(string.format("[batchRollback] Delete: success - %s", op.path))
	return {
		type = "delete",
		uniqueId = op.uniqueId,
		success = true,
	}
end

-- Execute updateScript operation
local function executeUpdateScript(tree: any, op: UpdateScriptOp): OperationResult
	local scriptInstance = tree:getInstance(op.uniqueId)

	if not scriptInstance or not scriptInstance:IsDescendantOf(game) then
		-- Clean up stale tree entry if instance was deleted outside of agent
		if scriptInstance and not scriptInstance:IsDescendantOf(game) then
			tree:removeByInstance(scriptInstance)
		end
		return {
			type = "updateScript",
			uniqueId = op.uniqueId,
			success = false,
			error = string.format("Script not found: %s", op.uniqueId),
		}
	end

	if not scriptInstance:IsA("LuaSourceContainer") then
		return {
			type = "updateScript",
			uniqueId = op.uniqueId,
			success = false,
			error = string.format("Instance is not a script: %s", op.uniqueId),
		}
	end

	scriptInstance.Source = op.content

	Log.debug(string.format("[batchRollback] UpdateScript: success - %s", op.path))
	return {
		type = "updateScript",
		uniqueId = op.uniqueId,
		success = true,
	}
end

-- Execute createInstance operation (deserialize)
local function executeCreateInstance(tree: any, op: CreateInstanceOp): OperationResult
	local parent = tree:getInstance(op.parentUniqueId)

	if not parent then
		return {
			type = "createInstance",
			uniqueId = op.uniqueId,
			success = false,
			error = string.format("Parent not found: %s", op.parentUniqueId),
		}
	end

	-- Parse serialized data
	local success, data = pcall(function()
		return HttpService:JSONDecode(op.serialized)
	end)

	if not success then
		return {
			type = "createInstance",
			uniqueId = op.uniqueId,
			success = false,
			error = "Failed to parse serialized data",
		}
	end

	-- Override source if provided separately
	if op.source then
		data.source = op.source
	end

	-- Create instance tree with preserved uniqueId
	local instance, err = createInstanceTree(tree, parent, data, op.uniqueId)

	if not instance then
		return {
			type = "createInstance",
			uniqueId = op.uniqueId,
			success = false,
			error = err or "Failed to create instance",
		}
	end

	Log.debug(string.format("[batchRollback] CreateInstance: success - %s", op.path))
	return {
		type = "createInstance",
		uniqueId = op.uniqueId,
		success = true,
	}
end

-- Execute move operation
local function executeMove(tree: any, op: MoveOp): OperationResult
	local instance = tree:getInstance(op.uniqueId)

	if not instance then
		return {
			type = "move",
			uniqueId = op.uniqueId,
			success = false,
			error = string.format("Instance not found: %s", op.uniqueId),
		}
	end

	local newParent = tree:getInstance(op.newParentUniqueId)

	if not newParent then
		return {
			type = "move",
			uniqueId = op.uniqueId,
			success = false,
			error = string.format("New parent not found: %s", op.newParentUniqueId),
		}
	end

	-- Rename
	instance.Name = op.newName

	-- Move to new parent
	instance.Parent = newParent

	Log.debug(string.format("[batchRollback] Move: success - to %s", op.originalPath))
	return {
		type = "move",
		uniqueId = op.uniqueId,
		success = true,
	}
end

-- Execute updateInstance operation
local function executeUpdateInstance(tree: any, op: UpdateInstanceOp): OperationResult
	local instance = tree:getInstance(op.uniqueId)

	if not instance then
		return {
			type = "updateInstance",
			uniqueId = op.uniqueId,
			success = false,
			error = string.format("Instance not found: %s", op.uniqueId),
		}
	end

	-- Apply properties
	if op.properties then
		applyProperties(instance, op.properties)
	end

	-- Apply attributes
	if op.attributes then
		applyAttributes(tree, instance, op.attributes)
	end

	Log.debug(string.format("[batchRollback] UpdateInstance: success - %s", op.path))
	return {
		type = "updateInstance",
		uniqueId = op.uniqueId,
		success = true,
	}
end

-- Main handler
return function(
	self,
	params: {
		operations: { any },
		messageId: string,
	}
): {
	status: string,
	operationsExecuted: number?,
	operationsFailed: number?,
	results: { OperationResult }?,
	duration: number?,
	error: string?,
}
	local startTime = os.clock()

	Log.info(
		string.format(
			"[batchRollback] BEGIN - Processing %d operations for message %s",
			#params.operations,
			params.messageId
		)
	)

	local results: { OperationResult } = {}
	local executed = 0
	local failed = 0

	-- Process each operation in order
	for i, op in ipairs(params.operations) do
		local result: OperationResult

		local success, err = pcall(function()
			if op.type == "delete" then
				result = executeDelete(self.tree, op)
			elseif op.type == "updateScript" then
				result = executeUpdateScript(self.tree, op)
			elseif op.type == "createInstance" then
				result = executeCreateInstance(self.tree, op)
			elseif op.type == "move" then
				result = executeMove(self.tree, op)
			elseif op.type == "updateInstance" then
				result = executeUpdateInstance(self.tree, op)
			else
				result = {
					type = op.type or "unknown",
					uniqueId = op.uniqueId or "unknown",
					success = false,
					error = string.format("Unknown operation type: %s", tostring(op.type)),
				}
			end
		end)

		if not success then
			result = {
				type = op.type or "unknown",
				uniqueId = op.uniqueId or "unknown",
				success = false,
				error = tostring(err),
			}
		end

		table.insert(results, result)

		if result.success then
			executed = executed + 1
		else
			failed = failed + 1
			Log.warn(
				string.format(
					"[batchRollback] Operation %d failed: %s - %s",
					i,
					result.type,
					result.error or "unknown error"
				)
			)
		end
	end

	local duration = math.floor((os.clock() - startTime) * 1000)

	Log.info(
		string.format(
			"[batchRollback] COMPLETE - %d executed, %d failed, %dms for message %s",
			executed,
			failed,
			duration,
			params.messageId
		)
	)

	return {
		status = "completed",
		operationsExecuted = executed,
		operationsFailed = failed,
		results = results,
		duration = duration,
	}
end
