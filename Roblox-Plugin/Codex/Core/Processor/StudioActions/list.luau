--!strict
-- list: Browse Studio hierarchy and children across instances and scripts
-- Optimized: Skip heavy folders, maxResults limit

local Codex = script:FindFirstAncestor("Codex")
local Log = require(Codex.Log)
local UniqueIdHelpers = require(Codex.Util.UniqueIdHelpers)
local helpers = require(script.Parent.helpers)

-- Folders to skip (typically large dependency trees)
local SKIP_FOLDERS: { [string]: boolean } = {
	Packages = true, -- Wally dependencies
	_Index = true, -- Wally internal index
	node_modules = true, -- Just in case
}

local MAX_RESULTS = 500 -- Prevent unbounded results

return function(
	self,
	params: { uniqueId: string?, maxDepth: number?, maxResults: number? }
): {
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
	truncated: boolean?,
	error: string?,
}
	Log.info(
		"[StudioActions.list] BEGIN - uniqueId:",
		params.uniqueId or "nil (listing services)",
		"maxDepth:",
		params.maxDepth or 1
	)

	local maxDepth = params.maxDepth or 1
	local maxResults = math.min(params.maxResults or MAX_RESULTS, MAX_RESULTS)

	if maxDepth < 1 then
		return {
			status = "failed",
			error = "maxDepth must be greater than 0",
		}
	end

	local root
	if params.uniqueId then
		root = self.tree:getInstance(params.uniqueId)
		if not root then
			Log.warn("[StudioActions.list] Instance not found in Tree:", params.uniqueId)
			return {
				status = "failed",
				error = string.format("Instance not found: %s", params.uniqueId),
			}
		end
		Log.debug("[StudioActions.list] Listing children of:", root:GetFullName())
	else
		-- List all service folders
		root = game
		Log.debug("[StudioActions.list] Listing all top-level services")
	end

	local children = {}
	local truncated = false

	local function collectChildren(instance: Instance, depth: number)
		if depth > maxDepth then
			return
		end

		-- Early exit if we have enough results
		if #children >= maxResults then
			truncated = true
			return
		end

		for _, child in ipairs(instance:GetChildren()) do
			-- Early exit if we have enough results
			if #children >= maxResults then
				truncated = true
				return
			end

			-- Skip heavy folders (but still show them, just don't recurse into them)
			local isSkippedFolder = SKIP_FOLDERS[child.Name]

			local uniqueId = UniqueIdHelpers.getUniqueId(child)
			if not uniqueId then
				-- Try to get ID from tree (handles service folders and other tracked instances)
				uniqueId = self.tree:getId(child)
			end

			if uniqueId then
				table.insert(children, {
					name = child.Name,
					uniqueId = uniqueId,
					robloxClass = child.ClassName,
					path = helpers.getInstancePath(child),
					hasChildren = #child:GetChildren() > 0,
					depth = depth, -- Add depth field for tree formatting
				})

				-- Only recurse if not a skipped folder and within depth
				if depth < maxDepth and not isSkippedFolder then
					collectChildren(child, depth + 1)
				end
			else
				-- Skip instances without uniqueId (built-in services, etc.)
				Log.trace(
					"[StudioActions.list] Skipping instance (no uniqueId):",
					child:GetFullName(),
					"ClassName:",
					child.ClassName
				)
			end
		end
	end

	collectChildren(root, 1)

	Log.info(string.format("[StudioActions.list] DONE returning=%d truncated=%s", #children, tostring(truncated)))

	return {
		status = "completed",
		children = children,
		truncated = truncated,
	}
end
