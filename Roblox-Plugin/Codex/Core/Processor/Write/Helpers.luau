local ChangeHistoryService = game:GetService("ChangeHistoryService")
local Codex = script:FindFirstAncestor("Codex")
local Dom = require(Codex.Dom)
local Log = require(Codex.Log)
local Error = require(Codex.Core.Error)
local Config = require(Codex.Config)
local equals = require(Codex.Helpers.equals)
local UniqueIdHelpers = require(Codex.Util.UniqueIdHelpers)

local MESH_RELOAD_PROPERTIES = { "MeshContent", "InitialSize" }

local Helpers = {}

function Helpers.setWaypoint(action: string, name: string?)
	name = name and ` "{name}"` or ""
	ChangeHistoryService:SetWaypoint(`Codex: {action}{name} [{DateTime.now():FormatLocalTime("LTS", "en-us")}]`)
end

function Helpers.loadMesh(path: string)
	local success, mesh = pcall(function()
		return game:GetObjects("rbxasset://Codex/" .. path)[1]
	end)

	if not success then
		local err = Error.new(Error.MeshLoadFailed, mesh)
		Log.warn(err)
		return nil
	end

	return mesh
end

function Helpers.shouldReloadMesh(mesh: MeshPart, properties: { [string]: any }?)
	if not properties then
		return false
	end

	for _, property in MESH_RELOAD_PROPERTIES do
		local value = properties[property]
		if not value then
			continue
		end

		local decodeSuccess, snapshotValue = Dom.EncodedValue.decode(value)
		if not decodeSuccess then
			local err = Error.new(Error.DecodeFailed, property, value)
			Log.warn(err)
			continue
		end

		property = property == "InitialSize" and "MeshSize" or property
		if not equals(mesh[property], snapshotValue) then
			return true
		end
	end

	return false
end

function Helpers.warnNotCreatable(class: string)
	local err = Error.new(Error.NotCreatable, class)

	if class == "PackageLink" and not Config:get("OverridePackages") then
		Log.info(err)
	else
		Log.warn(err)
	end
end

-- Service mapping for non-creatable Roblox services
Helpers.SERVICE_MAPPING = {
	["Workspace"] = game.Workspace,
	["ReplicatedStorage"] = game.ReplicatedStorage,
	["ReplicatedFirst"] = game.ReplicatedFirst,
	["StarterPlayer"] = game.StarterPlayer,
	["StarterGui"] = game.StarterGui,
	["StarterPack"] = game.StarterPack,
	["ServerScriptService"] = game.ServerScriptService,
	["ServerStorage"] = game.ServerStorage,
	["StarterCharacterScripts"] = game.StarterPlayer.StarterCharacterScripts,
	["StarterPlayerScripts"] = game.StarterPlayer.StarterPlayerScripts,
	["SoundService"] = game:GetService("SoundService"),
}

-- Structural items that shouldn't be created as Roblox instances
Helpers.STRUCTURAL_ITEMS = {
	["src"] = true,
	["wally.toml"] = true,
	["Packages"] = function(snapshot)
		-- Only skip if it's at root level (not a service child)
		return snapshot.path == "Packages"
	end,
}

-- Special attribute name that signals PrimaryPart should be updated
local PRIMARY_PART_UNIQUE_ID_ATTRIBUTE = "_PrimaryPartUniqueId"

-- Apply an attribute to an instance, handling special attributes like _PrimaryPartUniqueId
-- tree: optional Tree instance for efficient uniqueId lookup
-- Returns: (success: boolean, errorMessage: string?)
function Helpers.applyAttribute(instance: Instance, attrName: string, attrValue: any, tree: any?): (boolean, string?)
	-- Handle special _PrimaryPartUniqueId attribute for Models
	if attrName == PRIMARY_PART_UNIQUE_ID_ATTRIBUTE then
		Log.info(
			"[Helpers.applyAttribute] Processing _PrimaryPartUniqueId for:",
			instance:GetFullName(),
			"value:",
			attrValue
		)
		-- Only Models have PrimaryPart property
		if not instance:IsA("Model") then
			Log.warn(
				"[Helpers.applyAttribute] _PrimaryPartUniqueId attribute set on non-Model instance:",
				instance:GetFullName(),
				"ClassName:",
				instance.ClassName
			)
			return false, "Instance is not a Model"
		end

		-- Empty string means clear PrimaryPart
		if attrValue == "" or attrValue == nil then
			Log.debug("[Helpers.applyAttribute] Clearing PrimaryPart for Model:", instance:GetFullName())
			local success, err = pcall(function()
				(instance :: Model).PrimaryPart = nil
			end)
			if not success then
				Log.warn("[Helpers.applyAttribute] Failed to clear PrimaryPart:", err)
				return false, err
			end
			return true, nil
		end

		-- Find the BasePart with the matching uniqueId
		local targetUniqueId = attrValue
		local foundPart: BasePart? = nil

		-- Try Tree lookup first (O(1) if available)
		if tree and tree.getInstance then
			local treeInstance = tree:getInstance(targetUniqueId)
			if treeInstance and treeInstance:IsA("BasePart") and treeInstance:IsDescendantOf(instance) then
				foundPart = treeInstance :: BasePart
				Log.debug("[Helpers.applyAttribute] Found PrimaryPart via Tree lookup:", foundPart:GetFullName())
			end
		end

		-- Fallback: search descendants by uniqueId attribute
		if not foundPart then
			for _, descendant in ipairs(instance:GetDescendants()) do
				if descendant:IsA("BasePart") then
					local uid = UniqueIdHelpers.getUniqueId(descendant)
					if uid == targetUniqueId then
						foundPart = descendant :: BasePart
						break
					end
				end
			end
		end

		if not foundPart then
			Log.warn(
				"[Helpers.applyAttribute] Could not find BasePart with uniqueId:",
				targetUniqueId,
				"in Model:",
				instance:GetFullName()
			)
			return false, "BasePart with uniqueId not found"
		end

		-- Set the PrimaryPart property
		Log.info(
			"[Helpers.applyAttribute] Setting PrimaryPart for Model:",
			instance:GetFullName(),
			"to:",
			foundPart:GetFullName()
		)
		local success, err = pcall(function()
			(instance :: Model).PrimaryPart = foundPart
		end)

		if success then
			Log.info("[Helpers.applyAttribute] Successfully set PrimaryPart!")
		else
			Log.warn("[Helpers.applyAttribute] Failed to set PrimaryPart:", err)
		end

		if not success then
			Log.warn("[Helpers.applyAttribute] Failed to set PrimaryPart:", err)
			return false, err
		end

		Log.info(
			"[Helpers.applyAttribute] Successfully set PrimaryPart for",
			instance:GetFullName(),
			"to",
			foundPart:GetFullName()
		)
		return true, nil
	end

	-- Default behavior: set the attribute normally
	local success, err = pcall(function()
		instance:SetAttribute(attrName, attrValue)
	end)

	if not success then
		Log.warn("[Helpers.applyAttribute] Failed to set attribute", attrName, "on", instance.Name, "Error:", err)
		return false, err
	end

	return true, nil
end

return Helpers
