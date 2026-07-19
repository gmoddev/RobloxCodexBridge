-- General structs

-- Changed from buffer to string: Server API uses string uniqueIds,
-- Lua tables can't use buffers as keys anyway (always converted to string)
export type Ref = string
export type ClassName = string

export type Properties = {
	[string]: any,
}

export type Meta = {
	meshSource: string?,
}

-- Other structs

export type WatcherEvent = {
	kind: "Added" | "Removed" | "Changed",
	instance: Instance,
	property: string?,
	oldParentContainer: Instance?, -- For Remove events during move: the parent container that fired ChildRemoved
}

export type RemovalPayload = {
	id: Ref,
	uniqueId: string,
	path: string,
	name: string,
}

export type Project = {
	name: string,
	version: string,
	gameId: number?,
	placeIds: { number },
	rootRefs: { Ref },
	promptCount: number?,
}

-- Messages

export type Message = SyncDetails | ExecuteCode | Disconnect
export type MessageKind = "SyncDetails" | "ExecuteCode" | "Disconnect"

export type SyncDetails = {
	SyncDetails: Project,
}

export type ExecuteCode = {
	code: string,
}

export type Disconnect = {
	message: string,
}

-- Change Types (based on sync-service-api.md)
-- Discriminated union based on 'op' field: write | delete | deleteInstance | createInstance |
-- updateInstance | move | mkdir | toolboxImport | bulkCreate
-- See sync-service-api.md for full specification of each operation type
export type Change = {
	-- Base fields (common to all operations)
	op: string, -- Discriminator: "write" | "delete" | "deleteInstance" | "createInstance" | "updateInstance" | "move" | "mkdir" | "toolboxImport" | "bulkCreate"
	path: string, -- Hierarchical path (e.g., "ServerScriptService/GameManager")
	uniqueId: string, -- Instance identifier (3 or 12 chars)
	source: ("agent" | "plugin")?, -- Change origin (in Poll responses)
	ts: number?, -- Server timestamp (only in Poll responses)

	-- Write operation fields (op: "write")
	robloxClass: string?, -- Script class name
	content: string?, -- File content
	isNew: boolean?, -- Whether this is a new file
	parentId: string?, -- Parent instance ID

	-- Move operation fields (op: "move")
	oldPath: string?, -- Previous path
	oldParentId: string?, -- Previous parent ID
	name: string?, -- New instance name

	-- CreateInstance operation fields (op: "createInstance")
	parentPath: string?, -- Parent hierarchical path
	hierarchicalName: string?, -- Instance name
	attributes: { [string]: string | number | boolean }?, -- Instance attributes
	properties: { [string]: any }?, -- Instance properties (supports nested)

	-- ToolboxImport operation fields (op: "toolboxImport")
	assetId: number?, -- Roblox asset ID
	destinationPath: string?, -- Parent path for import

	-- BulkCreate operation fields (op: "bulkCreate")
	childrenCount: number?, -- Number of children created
	parentName: string?, -- Parent node name
}

return nil
