--!strict
--[[
	Lightweight Watcher: Auto-tags new Studio instances with Codex unique IDs

	Simplified from old bidirectional sync architecture to only handle:
	- Detecting new instances created in Studio at any depth using DescendantAdded
	- Tagging them with CodexUniqueID attribute
	- Registering them in Tree for agent access

	This enables the agent to recognize Studio-created instances via list/read tools.
	Uses DescendantAdded event to catch instances at any nesting level automatically.
]]

local Codex = script:FindFirstAncestor("Codex")

local Log = require(Codex.Log)
local Types = require(Codex.Types)
local UniqueIdGenerator = require(Codex.Util.UniqueIdGenerator)
local UniqueIdHelpers = require(Codex.Util.UniqueIdHelpers)

type Watcher = typeof(setmetatable(
	{} :: {
		isActive: boolean,
		connections: { RBXScriptConnection },
		tree: Types.Tree,
	},
	{} :: WatcherImpl
))

type WatcherImpl = {
	__index: WatcherImpl,
	new: (tree: Types.Tree) -> Watcher,
	start: (self: Watcher, rootInstances: { Instance }) -> (),
	stop: (self: Watcher) -> (),
	__tagInstance: (self: Watcher, instance: Instance) -> (),
	__onInstanceAdded: (self: Watcher, instance: Instance) -> (),
}

local Watcher: WatcherImpl = {} :: WatcherImpl
Watcher.__index = Watcher

function Watcher.new(tree: Types.Tree)
	return setmetatable({
		isActive = false,
		connections = {},
		tree = tree,
	}, Watcher)
end

function Watcher:start(rootInstances)
	Log.info("[Watcher] Starting lightweight ID tagger for", #rootInstances, "root services")

	self.isActive = true

	-- Connect DescendantAdded to each root service (Workspace, ServerScriptService, etc.)
	-- DescendantAdded fires for ALL descendants at any depth, not just direct children
	for _, rootInstance in ipairs(rootInstances) do
		local connection = rootInstance.DescendantAdded:Connect(function(descendant)
			self:__onInstanceAdded(descendant)
		end)
		table.insert(self.connections, connection)
		Log.debug("[Watcher] Monitoring", rootInstance.Name, "for new instances at any depth")
	end

	Log.info("[Watcher] ID tagger active -", #self.connections, "services monitored")
end

function Watcher:stop()
	Log.info("[Watcher] Stopping ID tagger")

	for _, connection in self.connections do
		connection:Disconnect()
	end

	self.isActive = false
	self.connections = {}
end

-- Tag an instance and all its descendants with unique IDs (if not already tagged)
function Watcher:__tagInstance(instance: Instance)
	-- Skip CurrentCamera
	if instance == workspace.CurrentCamera then
		return
	end

	-- Check if already has unique ID
	local existingId = UniqueIdHelpers.getUniqueId(instance)
	if existingId then
		-- Studio duplication (Ctrl+D, copy/paste, Clone) carries the
		-- CodexUniqueID attribute over to the new instance. Detect that
		-- by checking whether this ID is already mapped to a different instance.
		local mappedInstance = self.tree:getInstance(existingId)
		if mappedInstance == instance or mappedInstance == nil then
			-- Either already registered to this instance, or not yet in the
			-- tree (e.g., initial Tree population happens elsewhere). Leave it.
			return
		end
		-- Collision: fall through to assign a fresh ID below.
	end

	-- Generate and set unique ID
	local uniqueId = UniqueIdGenerator.generate()
	UniqueIdHelpers.setUniqueId(instance, uniqueId)

	-- Register in tree
	self.tree:insertInstance(instance, uniqueId, {})

	Log.debug("[Watcher] Tagged", instance:GetFullName(), "with ID:", uniqueId)
end

-- Called when a new instance is added in Studio
-- Note: DescendantAdded fires for each descendant individually, so no need to loop through descendants
function Watcher:__onInstanceAdded(instance: Instance)
	if not self.isActive then
		return
	end

	Log.info("[Watcher] New instance detected:", instance:GetFullName())

	-- Tag the instance (DescendantAdded already fired for all descendants individually)
	self:__tagInstance(instance)
end

return Watcher
