
-- RecordingManager: Manages ChangeHistoryService recordings for agent execution sessions
-- Supports multiple recordings within the same session by using sessionId + timestamp as unique identifier

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local Codex = script:FindFirstAncestor("Codex")
local Log = require(Codex.Log)

export type RecordingManager = {
	currentRecordingId: string?,
	beginRecording: (self: RecordingManager, sessionId: string?) -> boolean,
	finishRecording: (self: RecordingManager) -> (),
	isRecording: (self: RecordingManager) -> boolean,
}

local RecordingManager = {}
RecordingManager.__index = RecordingManager

function RecordingManager.new(): RecordingManager
	local self = setmetatable({}, RecordingManager)

	self.currentRecordingId = nil

	return self
end

-- Begin recording for an agent execution session or individual action
-- @param sessionId - Optional identifier for this recording (defaults to "recording")
-- Returns: true if recording started successfully, false if failed
-- Note: Automatically finishes previous recording if one is active (supports multiple recordings in same session)
function RecordingManager:beginRecording(sessionId: string?): boolean
	-- If already recording, finish the previous one first (supports multiple recordings in same session)
	if self.currentRecordingId then
		Log.info("[RecordingManager] Auto-finishing previous recording before starting new one")
		self:finishRecording()
	end

	-- Create unique ID: sessionId + timestamp
	local baseId = sessionId or "recording"
	local uniqueId = baseId .. "_" .. tostring(os.time())
	local displayName = "AI Agent Changes"

	-- TryBeginRecording returns identifier or nil if fails
	local identifier = ChangeHistoryService:TryBeginRecording(uniqueId, displayName)

	if identifier == nil then
		Log.warn("[RecordingManager] Failed to begin recording:", uniqueId)
		Log.warn("[RecordingManager] Possible reasons: user in playtest, or Studio state incompatible")
		return false
	end

	self.currentRecordingId = identifier

	Log.info("[RecordingManager] Started recording:", uniqueId, "identifier:", identifier)
	return true
end

-- Finish the current recording session
-- Commits the recording to the undo stack
function RecordingManager:finishRecording()
	if not self.currentRecordingId then
		Log.warn("[RecordingManager] No recording in progress to finish")
		return
	end

	local identifier = self.currentRecordingId

	-- FinishRecording with Commit operation to save to undo stack
	ChangeHistoryService:FinishRecording(identifier, Enum.FinishRecordingOperation.Commit)

	Log.info("[RecordingManager] Finished recording identifier:", identifier)

	-- Clear current state
	self.currentRecordingId = nil
end

-- Check if currently recording
function RecordingManager:isRecording(): boolean
	return self.currentRecordingId ~= nil
end

return RecordingManager
