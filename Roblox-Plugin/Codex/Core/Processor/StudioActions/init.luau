--!strict
-- StudioActions: Orchestrates all Studio action tool handlers
-- Executes actions in Roblox Studio and returns results to agent
-- Includes operation-based rollback support via serialize/deserialize (Task 048)
--
-- Architecture: This class takes Tree as a dependency for efficient O(1) instance lookups,
-- following the same pattern as Processor, Watcher, and SyncCoordinator.

-- Import all handler modules
local createScriptHandler = require(script.createScript)
local updateScriptHandler = require(script.updateScript)
local editScriptHandler = require(script.editScript)
local readScriptHandler = require(script.readScript)
local createInstanceHandler = require(script.createInstance)
local updateInstanceHandler = require(script.updateInstance)
local readInstanceHandler = require(script.readInstance)
local readGuiTreeHandler = require(script.readGuiTree)
local moveHandler = require(script.move)
local deleteHandler = require(script.delete)
local listHandler = require(script.list)
local importAssetHandler = require(script.importAsset)
local globHandler = require(script.glob)
local grepHandler = require(script.grep)
local runTestsHandler = require(script.runTests)
local playtestHandler = require(script.playtest)

-- .rbxm import handler
local importRbxmHandler = require(script.importRbxm)

-- Run arbitrary Luau code handler
local runCodeHandler = require(script.runCode)

-- Screenshot capture handler
local captureScreenshotHandler = require(script.captureScreenshot)

-- Operation-based rollback handlers (Task 048 - LEMON-1052)
local serializeHandler = require(script.serialize)
local deserializeHandler = require(script.deserialize)
local batchRollbackHandler = require(script.batchRollback)

local StudioActions = {}
StudioActions.__index = StudioActions

-- Constructor: Takes Tree as dependency for efficient instance lookups
function StudioActions.new(tree)
	local self = setmetatable({}, StudioActions)

	self.tree = tree

	return self
end

-- 1. createScript: Create new Script/LocalScript/ModuleScript
function StudioActions:createScript(params: {
	parentId: string,
	robloxClass: string,
	content: string,
	name: string,
}): { status: string, uniqueId: string?, path: string?, error: string? }
	return createScriptHandler(self, params)
end

-- 2. updateScript: Update existing script source code
function StudioActions:updateScript(
	params: { uniqueId: string, content: string }
): { status: string, path: string?, error: string? }
	return updateScriptHandler(self, params)
end

-- 3. editScript: Edit existing script by replacing specific text
function StudioActions:editScript(params: {
	uniqueId: string,
	old_string: string,
	new_string: string,
	replace_all: boolean?,
}): { status: string, path: string?, replacements: number?, error: string? }
	return editScriptHandler(self, params)
end

-- 4. readScript: Retrieve script source code
function StudioActions:readScript(params: {
	uniqueId: string,
	startLine: number?,
	endLine: number?,
}): {
	status: string,
	content: string?,
	robloxClass: string?,
	uniqueId: string?,
	parentId: string?,
	path: string?,
	totalLines: number?,
	startLine: number?,
	endLine: number?,
	error: string?,
}
	return readScriptHandler(self, params)
end

-- 4. createInstance: Create non-script instances
function StudioActions:createInstance(params: {
	parentId: string,
	robloxClass: string,
	name: string,
	attributes: { [string]: any }?,
	properties: { [string]: any }?,
}): { status: string, uniqueId: string?, path: string?, error: string? }
	return createInstanceHandler(self, params)
end

-- 5. updateInstance: Modify instance attributes/properties
function StudioActions:updateInstance(params: {
	uniqueId: string,
	attributes: { [string]: any }?,
	properties: { [string]: any }?,
}): { status: string, path: string?, error: string? }
	return updateInstanceHandler(self, params)
end

-- 6. readInstance: Query instance metadata
function StudioActions:readInstance(params: { uniqueId: string }): {
	status: string,
	robloxClass: string?,
	uniqueId: string?,
	parentId: string?,
	path: string?,
	attributes: { [string]: any }?,
	properties: { [string]: any }?,
	error: string?,
}
	return readInstanceHandler(self, params)
end

-- 6b. readGuiTree: Query a bounded GUI hierarchy for Codex inspection
function StudioActions:readGuiTree(params: {
	rootUniqueId: string?,
	RootUniqueId: string?,
	maxDepth: number?,
	MaxDepth: number?,
	maxNodes: number?,
	MaxNodes: number?,
	includeAbsolute: boolean?,
	IncludeAbsolute: boolean?,
	includeText: boolean?,
	IncludeText: boolean?,
	includeImages: boolean?,
	IncludeImages: boolean?,
	includeLayout: boolean?,
	IncludeLayout: boolean?,
}): {
	status: string,
	Root: any?,
	NodeCount: number?,
	Truncated: boolean?,
	Warnings: { string }?,
	error: string?,
}
	return readGuiTreeHandler(self, params)
end

-- 7. move: Relocate or rename instance/script
function StudioActions:move(params: {
	uniqueId: string,
	newParentId: string,
	newName: string?,
}): { status: string, oldPath: string?, newPath: string?, error: string? }
	return moveHandler(self, params)
end

-- 8. delete: Remove instance/script
function StudioActions:delete(
	params: { uniqueId: string }
): { status: string, path: string?, robloxClass: string?, error: string? }
	return deleteHandler(self, params)
end

-- 9. list: Browse Studio hierarchy
function StudioActions:list(params: { uniqueId: string?, maxDepth: number? }): {
	status: string,
	children: {
		{
			name: string,
			uniqueId: string,
			robloxClass: string,
			path: string,
			hasChildren: boolean,
		}
	}?,
	error: string?,
}
	return listHandler(self, params)
end

-- 10. importAsset: Import Roblox Toolbox asset
function StudioActions:importAsset(params: {
	parentId: string,
	assetId: number,
	name: string,
}): {
	status: string,
	uniqueId: string?,
	path: string?,
	robloxClass: string?,
	childCount: number?,
	error: string?,
}
	return importAssetHandler(self, params)
end

-- 11. glob: Find instances matching glob pattern
function StudioActions:glob(params: {
	pattern: string,
	classFilter: string?,
	maxResults: number?,
}): {
	status: string,
	matches: {
		{
			name: string,
			uniqueId: string,
			robloxClass: string,
			path: string,
		}
	}?,
	totalFound: number?,
	truncated: boolean?,
	error: string?,
}
	return globHandler(self, params)
end

-- 12. grep: Search script source code for text or Lua patterns
function StudioActions:grep(params: {
	query: string,
	isPattern: boolean?,
	ignoreCase: boolean?,
	maxResults: number?,
	scriptClassFilter: ("Script" | "LocalScript" | "ModuleScript")?,
	contextLines: number?,
}): {
	status: string,
	matches: {
		{
			name: string,
			uniqueId: string,
			robloxClass: string,
			path: string,
			lineNumber: number,
			matchText: string,
			contextBefore: string?,
			contextAfter: string?,
		}
	}?,
	totalFound: number?,
	truncated: boolean?,
	error: string?,
}
	return grepHandler(self, params)
end

-- 13. runTests: Execute game simulation and capture errors
function StudioActions:runTests(params: { timeout: number? }): {
	status: string,
	totalTests: number?,
	passedTests: number?,
	failedTests: number?,
	errors: {
		{
			scriptPath: string,
			scriptUniqueId: string,
			lineNumber: number?,
			message: string,
			stackTrace: string?,
		}
	}?,
	messages: { string }?,
	duration: number?,
	error: string?,
}
	return runTestsHandler(self, params)
end

-- 17. importRbxm: Import .rbxm binary data (library packages)
function StudioActions:importRbxm(params: {
	parentId: string,
	rbxmBase64: string,
	name: string,
}): {
	status: string,
	uniqueId: string?,
	path: string?,
	robloxClass: string?,
	childCount: number?,
	error: string?,
}
	return importRbxmHandler(self, params)
end

-- 19. captureScreenshot: Capture Studio viewport screenshot
function StudioActions:captureScreenshot(params: {
	templateName: string?,
	maxWidth: number?,
}): {
	status: string,
	width: number?,
	height: number?,
	data: string?,
	error: string?,
}
	return captureScreenshotHandler(self, params)
end

-- 18. runCode: Execute arbitrary Luau code in Studio Edit context
function StudioActions:runCode(params: {
	code: string,
	timeout: number?,
}): {
	status: string,
	output: { string }?,
	returnValue: string?,
	error: string?,
	duration: number?,
}
	return runCodeHandler(self, params)
end

-- 20. playtest: Run game in sandboxed play mode and capture logs.
-- When `captureFrames` is set, also captures N frames during play and returns
-- them as `frames` (single-tile RGBA) for agent-side GIF assembly.
function StudioActions:playtest(params: {
	timeout: number?,
	serverScript: string?,
	localScript: string?,
	captureFrames: {
		count: number,
		intervalMs: number,
		stabilizationMs: number,
		maxWidth: number?,
	}?,
}): {
	status: string,
	errors: {
		{
			scriptPath: string,
			lineNumber: number?,
			message: string,
		}
	}?,
	messages: { string }?,
	duration: number?,
	frames: {
		{
			width: number,
			height: number,
			data: string?,
			tiles: { { x: number, y: number, width: number, height: number, data: string } }?,
		}
	}?,
	captureComplete: boolean?,
	captureWallMs: number?,
	captureStartedBySignal: boolean?,
	error: string?,
}
	return playtestHandler(self, params)
end

-- 14. serialize: Capture complete instance state for rollback undo (Task 048)
function StudioActions:serialize(params: { uniqueId: string }): {
	status: string,
	uniqueId: string?,
	className: string?,
	path: string?,
	parentPath: string?,
	parentUniqueId: string?,
	data: string?, -- JSON-encoded serialized tree
	source: string?, -- Script source (separate for convenience)
	error: string?,
}
	return serializeHandler(self, params)
end

-- 15. deserialize: Recreate instance from serialized data during rollback (Task 048)
function StudioActions:deserialize(
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
	return deserializeHandler(self, params)
end

-- 16. batchRollback: Execute multiple rollback operations atomically (Task 048)
function StudioActions:batchRollback(params: {
	operations: { any },
	messageId: string,
}): {
	status: string,
	operationsExecuted: number?,
	operationsFailed: number?,
	results: {
		{
			type: string,
			uniqueId: string,
			success: boolean,
			error: string?,
		}
	}?,
	duration: number?,
	error: string?,
}
	return batchRollbackHandler(self, params)
end

return StudioActions
