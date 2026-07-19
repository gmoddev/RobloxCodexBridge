--!strict
--[[
	Changes.luau

	Unified change aggregator per sync-service-api.md specification.
	Produces Change[] format directly (no conversion needed).

	Refactored from legacy additions/updates/removals/moves format to unified format.
]]

local Codex = script:FindFirstAncestor("Codex")
local Log = require(Codex.Log)
local UniqueIdHelpers = require(Codex.Util.UniqueIdHelpers)

local Changes = {}
Changes.__index = Changes

-- Helper: Check if class is a script type
local function isScriptClass(className: string?): boolean
	if not className then
		return false
	end
	return className == "Script" or className == "LocalScript" or className == "ModuleScript"
end

-- Helper: Ensure ID is a string uniqueId
local function toUniqueIdString(id: any): string?
	if type(id) == "string" then
		return id
	elseif id == nil then
		return nil
	else
		Log.warn("[Changes] Unexpected ID type:", type(id))
		return tostring(id)
	end
end

function Changes.new(debugName: string?)
	local self = {
		changes = {} :: { any },
		debugName = debugName or "Changes",
	}

	return setmetatable(self, Changes)
end

-- Add a script/instance creation (accepts Change format: WriteChange or CreateInstanceChange)
function Changes:add(change: any)
	-- Validate it's the right operation type
	if not change or not change.op then
		Log.warn("[Changes:add] Missing op field")
		return
	end

	if change.op ~= "write" and change.op ~= "createInstance" then
		Log.warn("[Changes:add] Invalid op type:", change.op, "Expected: write or createInstance")
		return
	end

	if not change.uniqueId then
		Log.warn("[Changes:add] Missing uniqueId for", change.path or "unknown")
		return
	end

	-- Store the change directly (no conversion needed - already in Change format)
	self:_addChange(change)
	Log.trace("[Changes] Added", change.op, ":", change.path)
end

-- Update an existing script/instance (accepts Change format: WriteChange with isNew=false)
function Changes:update(change: any)
	-- Validate it's a write operation
	if not change or change.op ~= "write" then
		Log.warn("[Changes:update] Invalid op type:", change and change.op or "nil", "Expected: write")
		return
	end

	if change.isNew ~= false then
		Log.warn("[Changes:update] Expected isNew=false for update operation")
	end

	if not change.uniqueId then
		Log.warn("[Changes:update] Missing uniqueId for", change.path or "unknown")
		return
	end

	-- Store the change directly (no conversion needed - already in Change format)
	self:_addChange(change)
	Log.trace("[Changes] Added write (update):", change.path)
end

-- Remove a script/instance (delete or deleteInstance)
function Changes:remove(object: any)
	-- Handle both Ref (string) and object with id field
	local uniqueId = nil
	local path = nil
	local className = nil

	if type(object) == "string" then
		-- Simple Ref case
		uniqueId = toUniqueIdString(object)
	elseif type(object) == "table" then
		uniqueId = toUniqueIdString(object.id or object.uniqueId)
		path = object.path
		className = object.class
	elseif typeof(object) == "Instance" then
		-- Roblox Instance - get uniqueId from attribute
		uniqueId = UniqueIdHelpers.getUniqueId(object)
		path = object:GetFullName():gsub("^game%.", ""):gsub("%.([^%.]+)$", "/%1"):gsub("%.", "/")
		className = object.ClassName
	end

	if not uniqueId then
		Log.warn("[Changes:remove] Missing uniqueId for removal")
		return
	end

	-- Determine if it's a script or not
	local op = "delete" -- Default
	if className and not isScriptClass(className) then
		op = "deleteInstance"
	end

	local change = {
		op = op,
		path = path,
		uniqueId = uniqueId,
		source = "plugin",
	}
	self:_addChange(change)
	Log.trace("[Changes] Added", op, ":", path or uniqueId)
end

-- Move/rename an instance (accepts Change format: MoveChange)
function Changes:move(change: any)
	-- Validate it's a move operation
	if not change or change.op ~= "move" then
		Log.warn("[Changes:move] Invalid op type:", change and change.op or "nil", "Expected: move")
		return
	end

	if not change.uniqueId then
		Log.warn("[Changes:move] Missing uniqueId for", change.path or "unknown")
		return
	end

	-- Store the change directly (no conversion needed - already in Change format)
	self:_addChange(change)
	Log.trace("[Changes] Added move:", change.oldPath, "->", change.path)
end

-- Update instance attributes/properties (accepts Change format: UpdateInstanceChange)
function Changes:updateInstance(change: any)
	-- Validate it's an updateInstance operation
	if not change or change.op ~= "updateInstance" then
		Log.warn("[Changes:updateInstance] Invalid op type:", change and change.op or "nil", "Expected: updateInstance")
		return
	end

	if not change.uniqueId then
		Log.warn("[Changes:updateInstance] Missing uniqueId for", change.path or "unknown")
		return
	end

	-- Validate that at least one of attributes or properties is present
	if not change.attributes and not change.properties then
		Log.warn("[Changes:updateInstance] Missing both attributes and properties for", change.path or "unknown")
		return
	end

	-- Store the change directly (no conversion needed - already in Change format)
	self:_addChange(change)
	Log.trace("[Changes] Added updateInstance:", change.path)
end

-- Internal: Add a change to the list (no deduplication)
function Changes:_addChange(change: any)
	-- Simply append the change to the list
	table.insert(self.changes, change)
end

-- Join another Changes object into this one
function Changes:join(other: any, _check: boolean?)
	if not other or not other.changes then
		return
	end

	-- Simply append all changes from other (no deduplication)
	for _, change in other.changes do
		table.insert(self.changes, change)
	end
end

-- Get the raw changes array (for pushing to server)
function Changes:getChanges(): { any }
	return self.changes
end

-- Check if change list is empty
function Changes:isEmpty(): boolean
	return #self.changes == 0
end

-- Get total count of changes
function Changes:total(): number
	return #self.changes
end

-- Static method for total (legacy compatibility)
function Changes.Total(changes: any): number
	if changes.changes then
		return #changes.changes
	end
	-- Legacy format fallback (shouldn't happen)
	return 0
end

return Changes
