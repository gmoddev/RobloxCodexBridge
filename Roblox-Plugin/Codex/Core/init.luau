--!strict

--[[
	Core/init.luau
	
	Thin orchestrator that creates managers, wires signals, and provides public API.
	This module has been refactored to delegate most functionality to specialized managers
	while maintaining the same external interface.
	
	Primary responsibilities:
	- Initialize and coordinate managers (ProjectManager, SyncCoordinator)
	- Provide public API surface for external code
	- Handle lightweight operations like callbacks and status management
	- Handle manual sync and full sync operations
	- Orchestrate the startup sequence (project → sync)
]]

local ScriptEditorService = game:GetService("ScriptEditorService")

local Codex = script:FindFirstAncestor("Codex")

local Promise = require(Codex.Packages.Promise)

local Config = require(Codex.Config)
local Log = require(Codex.Log)
local Util = require(Codex.Util)
local Types = require(Codex.Types)
local Watcher = require(Codex.Watcher)

local Processor = require(script.Processor)
local Changes = require(script.Changes)
local Tree = require(script.Tree)
local Error = require(script.Error)
local ProjectApi = require(script.Parent.Net.ProjectApi)

local StudioActionService = require(script.Parent.Services.StudioActionService)
local RecordingManager = require(script.Parent.Services.RecordingManager)
local StudioActions = require(script.Processor.StudioActions)

local Core = {
	Status = {
		Disconnected = 0,
		Connecting = 1,
		Connected = 2,
		Disconnecting = 3,
	},
}
Core.__index = Core

function Core.new(pluginArg, projectId: string?)
	local self = setmetatable({}, Core)

	self.plugin = pluginArg
	self.rootInstances = {}
	self.connections = {}
	self.status = Core.Status.Disconnected -- Start disconnected
	-- Initialize lastSync far in the past so initial local events are not debounce-skipped
	self.lastSync = 0
	self.lastLocalChangeTime = os.clock() -- Initialize time of last local change

	-- Initialize core components
	self.tree = Tree.new()
	self.processor = Processor.new(self.tree, ProjectApi)
	self.watcher = Watcher.new(self.tree)
	self.studioActionService = StudioActionService.new({ pollInterval = 1.0 })

	-- Project monitoring for detecting project switches
	self.lastKnownProjectId = nil
	self.projectCheckInterval = 30 -- Check every 30 seconds
	self.isMonitoringProject = false

	self.__prompt = function(_message: string, _changes: Types.Changes?): boolean
		return true
	end
	self.__ready = function(_project: Types.Project) end
	self.__message = function(_messageType: string, _messageData: any) end -- User-facing messages
	self.__studioAction = function(_toolName: string, _path: string?, _timestamp: number) end

	self:__handleOpenInEditor(Config:get("OpenInEditor"))

	-- Set initial project ID if provided
	if projectId and self.plugin then
		self.plugin:SetSetting("PROJECT_ID", projectId)
	end

	table.insert(
		self.connections,
		Config:onChanged("OpenInEditor", function(enabled)
			self:__handleOpenInEditor(enabled)
		end)
	)

	return self
end

-- Helper method to get current project ID from plugin settings
function Core:getProjectId(): string
	if self.plugin then
		return self.plugin:GetSetting("PROJECT_ID") or ""
	end
	return ""
end

function Core:run(): Promise.Promise
	Log.info("[Core] Starting Studio direct action mode")

	return Promise.new(function(_, reject)
		self.status = Core.Status.Connected

		-- Get project ID from plugin settings
		local actualProjectId = self:getProjectId()
		if not actualProjectId or actualProjectId == "" then
			return reject(Error.new(Error.Disconnected, "No project ID found in plugin settings"))
		end

		local actualProjectName = actualProjectId
		Log.debug("[Core] Using local CodexBridge session:", actualProjectId)

		-- Create minimal project properties
		local projectProperties = {
			name = actualProjectName,
			id = actualProjectId,
			rootRefs = {}, -- Will be populated below
			placeIds = {},
		}

		self.project = projectProperties

		-- Register standard Roblox services in tree
		Log.info("[Core] Registering standard Roblox services")

		local standardServices = {
			"Workspace",
			"ReplicatedStorage",
			"ReplicatedFirst",
			"ServerScriptService",
			"ServerStorage",
			"StarterGui",
			"StarterPack",
			"StarterPlayer",
		}

		for _, serviceName in ipairs(standardServices) do
			local service = game:GetService(serviceName)
			if service then
				-- Get service ID from tree (already registered by Tree.new())
				local serviceId = self.tree:getId(service)
				if serviceId then
					table.insert(projectProperties.rootRefs, serviceId)
					table.insert(self.rootInstances, service)
					Log.debug("[Core] Added service to rootRefs:", serviceName, "with ID:", serviceId)
				else
					Log.warn("[Core] Service not found in tree:", serviceName)
				end
			end
		end

		Log.info("[Core] Registered", #self.rootInstances, "root services")

		-- Populate Tree with all existing instances from the project
		-- This is critical for connecting to existing large projects
		Log.info("[Core] Populating Tree with existing project instances...")
		self.tree:populateExistingInstances(self.rootInstances)
		Log.info("[Core] Tree population completed")

		-- Call ready callback
		self.__ready(projectProperties)

		-- Start Watcher for automatic ID tagging of Studio-created instances
		Log.info("[Core] Starting Watcher for automatic ID tagging")
		self.watcher:start(self.rootInstances)

		-- First-time setup: trigger script permission modal
		self:__triggerScriptPermission()

		-- Start Studio action polling service for direct execution
		Log.info("[Core] Starting Studio action service for project:", actualProjectId)
		local studioActions = StudioActions.new(self.tree)

		-- Initialize RecordingManager and inject it into StudioActions for rollback support
		self.recordingManager = RecordingManager.new()
		studioActions.recordingManager = self.recordingManager
		Log.info("[Core] RecordingManager injected into StudioActions for rollback support")

		-- Register callback for action completion notifications
		self.studioActionService:onActionComplete(function(toolName, path, timestamp)
			self.__studioAction(toolName, path, timestamp)
		end)

		-- Register callback for bridge-side session end.
		self.studioActionService:onSessionEnded(function(reason)
			self.__message("bridge_disconnected", { reason = reason })
		end)

		self.studioActionService:startPolling(actualProjectId, studioActions)

		-- Keep the promise alive indefinitely until stop() is called
		return Promise.new(function() end)
	end)
end

function Core:stop()
	Log.info("[Core] Stopping Codex core")

	self.status = Core.Status.Disconnecting

	-- Stop project monitoring
	self.isMonitoringProject = false

	-- Stop Watcher ID tagging
	self.watcher:stop()

	-- Stop Studio action polling
	self.studioActionService:stopPolling()

	-- Finish any ongoing recording on shutdown
	if self.recordingManager and self.recordingManager:isRecording() then
		Log.info("[Core] Finishing ongoing recording on shutdown")
		self.recordingManager:finishRecording()
	end

	-- Clean up connection state to prevent corruption on reconnect
	self:cleanupConnectionState()

	-- Clean up connections
	Util.clean(self.connections)
end

-- Clean up all connection state to prepare for clean reconnection
function Core:cleanupConnectionState()
	Log.debug("[Core] Starting connection state cleanup...")

	-- Reset Tree state to clean slate
	if self.tree and self.tree.resetState then
		Log.debug("[Core] Resetting Tree state...")
		self.tree:resetState()
	end

	-- Clear root instances array
	self.rootInstances = {}

	-- Clear project reference
	self.project = nil

	Log.info("[Core] Connection state cleanup completed")
end

function Core:onPrompt(callback: (message: string, changes: Types.Changes?) -> boolean)
	self.__prompt = function(message, changes)
		if self.status == Core.Status.Disconnecting then
			return false
		end

		return callback(message, changes)
	end
end

function Core:onReady(callback: (project: Types.Project) -> ())
	self.__ready = function(project)
		if self.status == Core.Status.Disconnecting then
			return
		end

		return callback(project)
	end
end

function Core:onMessage(callback: (messageType: string, messageData: any) -> ())
	self.__message = function(messageType, messageData)
		if self.status == Core.Status.Disconnecting then
			return
		end

		return callback(messageType, messageData)
	end
end

function Core:onStudioAction(callback: (toolName: string, path: string?, timestamp: number) -> ())
	self.__studioAction = function(toolName, path, timestamp)
		if self.status == Core.Status.Disconnecting then
			return
		end

		return callback(toolName, path, timestamp)
	end
end

-- Project switching was part of the old remote browser workflow. CodexBridge is
-- local-session based, so this monitor must stay disabled or it will compare
-- the local session id against unrelated remote project ids and disconnect.
function Core:startProjectMonitoring(projectId: string, projectName: string, initialPromptCount: number?)
	Log.debug(
		string.format(
			"[Core] Project monitoring disabled for CodexBridge session %s (%s)",
			projectName or projectId,
			projectId
		)
	)
	self.lastKnownProjectId = projectId
	self.lastKnownProjectName = projectName or projectId
	self.lastKnownPromptCount = initialPromptCount or 0
	self.isMonitoringProject = false
end

function Core.wasExitGraceful(err: Error.Error)
	return err == Error.GameId or err == Error.PlaceIds or err == Error.TooManyChanges or err == Error.Terminated
end

-- Internal functions

function Core:__verifyProject(project: Types.Project, initial: boolean?): Promise.Promise
	if not self:__shouldPrompt(initial) then
		return Promise.resolve()
	end

	if project.gameId and project.gameId ~= game.GameId then
		local err = Error.new(Error.GameId, game.GameId, project.gameId)

		if not self.__prompt(err.message) then
			return Promise.reject(err)
		end
	end

	if #project.placeIds > 0 and not table.find(project.placeIds, game.PlaceId) then
		local err = Error.new(Error.PlaceIds, game.PlaceId, project.placeIds)

		if not self.__prompt(err.message) then
			return Promise.reject(err)
		end
	end

	-- Version check might need adjustment based on Codex backend versioning
	-- if not SemVer.parse(project.version):isCompatible(SemVer.parse(manifest.package.version)) then
	-- 	local err = Error.new(Error.Version, manifest.package.version, project.version)
	-- 	return Promise.reject(err)
	-- end

	return Promise.resolve()
end

function Core:__verifyChanges(changes: Types.Changes, initial: boolean?): Promise.Promise
	if not self:__shouldPrompt(initial) then
		return Promise.resolve()
	end

	local totalChanges = Changes.Total(changes)
	if totalChanges > Config:get("ChangesThreshold") then
		-- Count changes by operation type for error message
		local changesList = changes:getChanges()
		local writeCount = 0
		local deleteCount = 0
		local moveCount = 0

		for _, change in ipairs(changesList) do
			if change.op == "write" or change.op == "createInstance" or change.op == "toolboxImport" then
				writeCount = writeCount + 1
			elseif change.op == "delete" or change.op == "deleteInstance" then
				deleteCount = deleteCount + 1
			elseif change.op == "move" then
				moveCount = moveCount + 1
			end
		end

		local err = Error.new(Error.TooManyChanges, writeCount, moveCount, deleteCount)

		if not self.__prompt(err.message, changes) then
			return Promise.reject(err)
		end
	end

	return Promise.resolve()
end

-- Syncback loop moved to SyncCoordinator.luau

function Core:__handleOpenInEditor(enabled: boolean)
	if not enabled then
		self:__cleanConnection("openInEditor")
		return
	end

	self.connections["openInEditor"] = ScriptEditorService.TextDocumentDidOpen:Connect(function(document)
		if self.status ~= Core.Status.Connected then
			return
		end
		if document:IsCommandBar() then
			return
		end

		local id = self.tree:getId(document:GetScript())
		if not id then
			return
		end

		local line = document:GetSelectionStart()

		-- Open document in external editor
		ProjectApi.open(id, line)
			:andThen(function()
				document:CloseAsync()
			end)
			:catch(function(err)
				Log.debug("Failed to open document in editor:", err)
			end)
	end)
end

function Core:__cleanConnection(id: string)
	local connection = self.connections[id]
	if connection then
		connection:Disconnect()
		self.connections[id] = nil
	end
end

function Core:__shouldPrompt(initial: boolean?): boolean
	local mode = Config:get("DisplayPrompts")
	if mode == "Always" then
		return true
	elseif mode == "Initial" and initial then
		return true
	else
		return false
	end
end

function Core:__triggerScriptPermission()
	Log.info("[Core] __triggerScriptPermission: checking if first-time setup is needed")

	local alreadyDone = self.plugin:GetSetting("HELLO_Codex_DONE_V2")
	if alreadyDone then
		Log.info("[Core] __triggerScriptPermission: already completed, skipping (HELLO_Codex_DONE_V2 =", tostring(alreadyDone), ")")
		return
	end

	Log.info("[Core] __triggerScriptPermission: first-time setup detected, creating HelloCodex script to trigger permission modal")

	local success, err = pcall(function()
		local sss = game:GetService("ServerScriptService")
		Log.info("[Core] __triggerScriptPermission: got ServerScriptService, creating Script instance")

		local helloScript = Instance.new("Script")
		helloScript.Name = "HelloCodex"
		helloScript.Source = '-- Welcome to Codex!\nprint("Hello from Codex!")'
		Log.info("[Core] __triggerScriptPermission: setting parent to ServerScriptService (this triggers the permission modal)")
		helloScript.Parent = sss

		Log.info("[Core] __triggerScriptPermission: script parented successfully, destroying it now")
		helloScript:Destroy()
	end)

	if success then
		Log.info("[Core] __triggerScriptPermission: permission modal triggered and HelloCodex script cleaned up successfully")
	else
		Log.warn("[Core] __triggerScriptPermission: failed (user may have denied permission):", tostring(err))
	end

	Log.info("[Core] __triggerScriptPermission: marking HELLO_Codex_DONE_V2 = true in plugin settings")
	self.plugin:SetSetting("HELLO_Codex_DONE_V2", true)
end

function Core:onChange(instance: Instance)
	Log.info("Instance changed in Studio:", instance:GetFullName())
	if not self.ready or not self.tree then
		Log.warn("[Core:onChange] Called when Core not ready or tree not available. Aborting.")
		return
	end
	-- TODO: Implement actual logic for onChange if needed
end

-- Add new handler for peerClientDisconnected event
function Core:handlePeerClientDisconnected(eventData)
	Log.info("[Core] Peer client disconnected event received:", eventData)
	-- Example: Update UI or internal state to reflect the disconnection.
	-- self:updateConnectionStatusIndicator("Web UI disconnected: " .. (eventData.disconnectedUserId or "Unknown User"))

	-- TODO: If peerDisconnected notifications are needed, implement using self.__message instead
end

function Core:updateProjectId(newProjectId: string)
	self.projectManager:updateProjectId(newProjectId)
end

return Core
