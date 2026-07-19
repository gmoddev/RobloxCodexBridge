local ChangeHistoryService = game:GetService("ChangeHistoryService")

local Codex = script:FindFirstAncestor("Codex")
local Types = require(Codex.Types)
local Log = require(Codex.Log)

-- Import operation modules
local AdditionProcessor = require(script.AdditionProcessor)
local UpdateProcessor = require(script.UpdateProcessor)
local RemovalProcessor = require(script.RemovalProcessor)
local MoveProcessor = require(script.MoveProcessor)
local ToolboxImportProcessor = require(script:FindFirstChild("ToolboxImportProcessor"))

local function setWaypoint(action: string, name: string?)
	name = name and ` "{name}"` or ""
	ChangeHistoryService:SetWaypoint(`Codex: {action}{name} [{DateTime.now():FormatLocalTime("LTS", "en-us")}]`)
end

-- Removed getPhase() function - no longer using phase-based ordering
-- Changes are now processed in temporal order as received from server

local WriteProcessor = {}
WriteProcessor.__index = WriteProcessor

function WriteProcessor.new(tree, ProjectApi)
	local self = setmetatable({
		tree = tree,
		ProjectApi = ProjectApi,
		watcher = nil, -- Will be set by Core after construction
	}, WriteProcessor)

	-- Initialize operation processors with self reference
	self.additionProcessor = AdditionProcessor.new(self)
	self.updateProcessor = UpdateProcessor.new(self)
	self.removalProcessor = RemovalProcessor.new(self)
	self.moveProcessor = MoveProcessor.new(self)
	self.toolboxImportProcessor = if ToolboxImportProcessor then ToolboxImportProcessor.new(self) else nil

	return self
end

function WriteProcessor:applyChanges(changes: Types.Changes, initial: boolean?)
	setWaypoint("Sync")

	-- Get unified changes array and process in temporal order
	local changesList = changes:getChanges()

	Log.trace("[WriteProcessor] Processing", #changesList, "unified changes in temporal order")

	-- Process changes in exact order received from server (temporal order)
	-- This preserves rollback semantics: create → edit → delete → create (rollback)
	for _, change in changesList do
		-- Route to appropriate processor based on operation type
		if change.op == "write" then
			if change.isNew then
				-- New file creation
				self.additionProcessor:applyAddition(change, initial)
			else
				-- Update existing file
				self.updateProcessor:applyUpdate(change, initial)
			end
		elseif change.op == "createInstance" then
			-- Create instance
			self.additionProcessor:applyAddition(change, initial)
		elseif change.op == "updateInstance" then
			-- Update instance attributes/properties
			self.updateProcessor:applyUpdate(change, initial)
		elseif change.op == "move" then
			-- Move/rename
			self.moveProcessor:applyMove(change, initial)
		elseif change.op == "delete" or change.op == "deleteInstance" then
			-- Delete
			self.removalProcessor:applyRemoval(change, initial)
		else
			Log.warn("[WriteProcessor] Unknown operation type:", change.op)
		end
	end

	if initial then
		setWaypoint("Initial Sync")
	end

	Log.trace("[WriteProcessor] Finished applying", #changesList, "unified changes in temporal order")
end

-- Delegate methods to operation processors for backward compatibility
function WriteProcessor:applyAddition(
	snapshot: Types.AddedSnapshot,
	initial: boolean?,
	skipExisting: boolean?
): Instance?
	return self.additionProcessor:applyAddition(snapshot, initial, skipExisting)
end

function WriteProcessor:applyUpdate(_id: Types.Ref, snapshotUpdate: Types.SnapshotUpdate, initial: boolean?)
	return self.updateProcessor:applyUpdate(snapshotUpdate, initial)
end

function WriteProcessor:applyRemoval(object: Types.Ref | Instance, initial: boolean?): Instance?
	return self.removalProcessor:applyRemoval(object, initial)
end

function WriteProcessor:applyMove(moveSnapshot: Types.MoveSnapshot, initial: boolean?)
	return self.moveProcessor:applyMove(moveSnapshot, initial)
end

-- Add toolbox import processing method
function WriteProcessor:processToolboxImportEvent(eventPayload): boolean
	if not self.toolboxImportProcessor then
		Log.warn("[WriteProcessor] ToolboxImportProcessor not available")
		return false
	end
	return self.toolboxImportProcessor:processToolboxImportEvent(eventPayload)
end

return WriteProcessor
