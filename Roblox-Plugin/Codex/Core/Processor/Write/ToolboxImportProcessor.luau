local Selection = game:GetService("Selection")

local Codex = script:FindFirstAncestor("Codex")
local Log = require(Codex.Log)
local UniqueIdHelpers = require(Codex.Util.UniqueIdHelpers)

local ToolboxImportProcessor = {}
ToolboxImportProcessor.__index = ToolboxImportProcessor

function ToolboxImportProcessor.new(writeProcessor)
	return setmetatable({
		writeProcessor = writeProcessor,
	}, ToolboxImportProcessor)
end

-- Simple path → Instance navigator (service-rooted, e.g. "ReplicatedStorage/_Assets")
local function getOrCreatePath(destinationPath: string): Instance?
	local parts = {}
	for part in destinationPath:gmatch("[^/]+") do
		table.insert(parts, part)
	end

	if #parts == 0 then
		return nil
	end

	local current: Instance
	local serviceName = parts[1]
	local ok, svc = pcall(function()
		return game:GetService(serviceName)
	end)
	if not ok or not svc then
		Log.warn("[ToolboxImport] Unknown service:", serviceName)
		return nil
	end
	current = svc

	for i = 2, #parts do
		local name = parts[i]
		local child = current:FindFirstChild(name)
		if not child then
			local folder = Instance.new("Folder")
			folder.Name = name
			folder.Parent = current
			-- DO NOT mark as server-created - if the folder doesn't exist, the VM needs to know about it
			-- If the VM already sent an mkdir for this folder, it will be ignored as a duplicate
			child = folder
			Log.info("[ToolboxImport] Created folder:", child:GetFullName())
		end
		current = child
	end

	return current
end

local function sanitizeModel(root: Instance)
	for _, inst in ipairs(root:GetDescendants()) do
		if inst:IsA("Script") or inst:IsA("LocalScript") or inst:IsA("ModuleScript") then
			inst:Destroy()
		end
	end
end

-- Import asset using game:GetObjects (more reliable than InsertService)
local function insertByGetObjects(assetId: number, parent: Instance?)
	parent = parent or workspace
	local ok, arr = pcall(game.GetObjects, game, "rbxassetid://" .. assetId)
	if not ok or not arr or #arr == 0 then
		return nil, "getobjects_failed"
	end

	local inst
	if #arr == 1 then
		inst = arr[1]
	else
		local folder = Instance.new("Folder")
		folder.Name = "Imported_" .. assetId
		-- DO NOT mark as server-created - let Watcher detect and push to VM
		for _, obj in ipairs(arr) do
			obj.Parent = folder
		end
		inst = folder
	end

	inst.Parent = parent
	Selection:Set({ inst })
	return inst
end

-- payload = { assetId: number, destinationPath: string, name: string, uniqueId: string? }
function ToolboxImportProcessor:processToolboxImportEvent(payload): boolean
	local assetId = tonumber(payload.assetId)
	local destPath = (payload.destinationPath :: string) or "ReplicatedStorage/_Assets"
	local inputName = (payload.name :: string) or "ImportedAsset"
	local uniqueId = payload.uniqueId

	if not assetId or assetId <= 0 then
		Log.error("[ToolboxImport] Invalid assetId:", payload.assetId)
		return false
	end

	-- Use provided name as-is; do not append assetId to the name
	local finalName = inputName

	local parent = getOrCreatePath(destPath)
	if not parent then
		Log.error("[ToolboxImport] Destination path not found:", destPath)
		return false
	end

	-- Check if an instance with this uniqueId already exists by scanning the DataModel
	-- We can't use tree.getInstance() because we're not registering in the tree anymore
	if uniqueId then
		for _, inst in ipairs(game:GetDescendants()) do
			local existingUid = UniqueIdHelpers.getUniqueId(inst)
			if existingUid == uniqueId then
				Log.info(
					"[ToolboxImport] Instance with uniqueId already exists:",
					uniqueId,
					"->",
					inst:GetFullName(),
					"- skipping import"
				)
				return true
			end
		end
	end

	Log.info("[ToolboxImport] Loading asset via GetObjects:", assetId)
	local root, err = insertByGetObjects(assetId, parent)

	if not root then
		Log.error("[ToolboxImport] GetObjects failed:", err)
		return false
	end

	-- Sanitize the imported model (remove scripts)
	sanitizeModel(root)

	-- Set the name directly without checking for duplicates
	root.Name = finalName

	-- Assign uniqueId if provided (from VM sync)
	if uniqueId then
		UniqueIdHelpers.setUniqueId(root, uniqueId)
		-- DO NOT mark as server-created for toolbox imports
		-- The VM only knows the assetId, not the actual structure that was imported
		-- We need the Watcher to detect this and push back the discovered structure

		-- DO NOT register in tree here - this causes Watcher Add events to be misdetected as moves!
		-- The normal flow (Watcher → ReadProcessor → tree registration) will handle it correctly
		Log.info("[ToolboxImport] Assigned uniqueId to imported asset:", uniqueId)
	end

	-- Persist assetId on the root model for traceability without encoding it in the name
	pcall(function()
		root:SetAttribute("assetId", tostring(assetId))
	end)

	Log.info("[ToolboxImport] Imported asset:", assetId, "→", root:GetFullName())
	return true
end

return ToolboxImportProcessor
