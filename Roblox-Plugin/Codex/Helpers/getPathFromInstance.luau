
local Codex = script:FindFirstAncestor("Codex")
local Tree = require(Codex.Core.Tree) -- Assuming Tree type definition is accessible
-- local Types = require(Codex.Types) -- For Ref type if needed -- Removed unused variable

-- Recursively builds the path from a known ancestor down to the target instance
local function buildPath(targetInstance: Instance, currentInstance: Instance, currentPath: string): string?
	if currentInstance == targetInstance then
		return currentPath
	end

	for _, child in ipairs(currentInstance:GetChildren()) do
		local childPath = currentPath .. "/" .. child.Name
		local result = buildPath(targetInstance, child, childPath)
		if result then
			return result
		end
	end

	return nil
end

-- Walks up the tree to find an ancestor with a known Ref in the Tree manager,
-- then constructs the relative path.
local function getPathFromInstance(instance: Instance, _tree: typeof(Tree.new())): string?
	-- Walk up to the DataModel, gathering names
	if not instance or instance == game then
		return nil
	end

	local segments = {}
	local current = instance

	while current and current ~= game do
		table.insert(segments, 1, current.Name)
		current = current.Parent
	end

	if #segments == 0 then
		return nil
	end

	-- Historically we stripped the first path segment assuming it represented the DataModel (e.g. "Place1").
	-- However the loop above never includes `game` itself, so the first segment is actually the root *service*
	-- (Workspace, StarterPlayer, ReplicatedStorage, ...). Stripping it caused paths like
	-- "StarterPlayerScripts/foo.lua" where the correct path should be "StarterPlayer/StarterPlayerScripts/foo.lua".
	-- Only strip the very first segment if it exactly matches the DataModel name; otherwise leave it intact.
	if #segments > 1 and segments[1] == game.Name then
		table.remove(segments, 1)
	end

	local path = table.concat(segments, "/")

	-- Path is already rooted at the Roblox service (e.g. "ServerScriptService/...")
	-- so send it verbatim without any "src/" prefix

	-- No longer auto-adding extensions to script files

	return path
end

return getPathFromInstance
