--!strict
-- glob: Find instances matching glob pattern
-- Optimized: Early exit, deferred path computation, time-based yielding

local Log = require(script.Parent.Parent.Parent.Parent.Log)
local Codex = script:FindFirstAncestor("Codex")
local UniqueIdHelpers = require(Codex.Util.UniqueIdHelpers)
local helpers = require(script.Parent.helpers)
local patternUtils = require(script.Parent.patternUtils)

return function(
	self,
	params: {
		pattern: string,
		classFilter: string?,
		maxResults: number?,
		ignoreCase: boolean?,
	}
): {
	status: string,
	matches: {
		{
			name: string,
			uniqueId: string,
			robloxClass: string,
			parentPath: string,
		}
	}?,
	truncated: boolean?,
	error: string?,
}
	local pattern = params.pattern
	local classFilter = params.classFilter
	local maxResults = params.maxResults or 100
	local ignoreCase = if params.ignoreCase ~= nil then params.ignoreCase else true

	-- Validate maxResults
	if maxResults < 1 or maxResults > 500 then
		return {
			status = "failed",
			error = "maxResults must be between 1 and 500",
		}
	end

	-- Validate pattern (basic check)
	if pattern == "" then
		return {
			status = "failed",
			error = "Pattern cannot be empty",
		}
	end

	local matches = {}
	local instancesProcessed = 0

	-- Pre-compute lowercase pattern once (not per iteration)
	local patternToMatch = ignoreCase and pattern:lower() or pattern

	-- Time-based yielding: yield every ~10ms to keep Studio responsive
	local YIELD_INTERVAL_MS = 0.010 -- 10ms
	local lastYieldTime = os.clock()

	-- Helper to extract parentPath from full path
	local function getParentPath(path: string): string
		local slash = string.find(path, "/[^/]*$")
		if slash then
			return string.sub(path, 1, slash - 1)
		end
		return ""
	end

	Log.info(
		string.format(
			"[glob] START pattern='%s' classFilter=%s maxResults=%d",
			pattern,
			tostring(classFilter),
			maxResults
		)
	)

	-- Search all service folders
	local services = {
		game:GetService("Workspace"),
		game:GetService("ReplicatedStorage"),
		game:GetService("ReplicatedFirst"),
		game:GetService("ServerScriptService"),
		game:GetService("ServerStorage"),
		game:GetService("StarterGui"),
		game:GetService("StarterPack"),
		game:GetService("StarterPlayer"),
	}

	for _, service in ipairs(services) do
		-- Early exit if we have enough matches
		if #matches >= maxResults then
			break
		end

		-- Check service itself
		local serviceId = self.tree:getId(service)
		if serviceId then
			-- Apply class filter first (cheapest check)
			local classMatch = not classFilter or (service.ClassName == classFilter)

			if classMatch then
				-- Only compute path if class filter passes
				local servicePath = helpers.getInstancePath(service)
				local pathToMatch_service = ignoreCase and servicePath:lower() or servicePath

				if patternUtils.matchPath(pathToMatch_service, patternToMatch) then
					if #matches < maxResults then
						table.insert(matches, {
							name = service.Name,
							uniqueId = serviceId,
							robloxClass = service.ClassName,
							parentPath = getParentPath(servicePath),
						})
					end
				end
			end
		end

		-- Early exit if we have enough matches
		if #matches >= maxResults then
			break
		end

		-- Search descendants
		for _, instance in ipairs(service:GetDescendants()) do
			-- Early exit if we have enough matches
			if #matches >= maxResults then
				break
			end

			instancesProcessed = instancesProcessed + 1

			-- Apply class filter first (cheapest check)
			local classMatch = not classFilter or (instance.ClassName == classFilter)
			if not classMatch then
				-- Time-based yield
				if os.clock() - lastYieldTime >= YIELD_INTERVAL_MS then
					task.wait()
					lastYieldTime = os.clock()
				end
				continue
			end

			-- Get unique ID
			local uniqueId = UniqueIdHelpers.getUniqueId(instance)
			if not uniqueId then
				uniqueId = self.tree:getId(instance)
			end

			if uniqueId then
				-- Only compute path if we have a valid ID and class matches
				local path = helpers.getInstancePath(instance)
				local pathToMatch_inst = ignoreCase and path:lower() or path

				if patternUtils.matchPath(pathToMatch_inst, patternToMatch) then
					if #matches < maxResults then
						table.insert(matches, {
							name = instance.Name,
							uniqueId = uniqueId,
							robloxClass = instance.ClassName,
							parentPath = getParentPath(path),
						})
					end
				end
			end

			-- Time-based yield instead of count-based
			if os.clock() - lastYieldTime >= YIELD_INTERVAL_MS then
				task.wait()
				lastYieldTime = os.clock()
			end
		end
	end

	Log.info(string.format("[glob] DONE instancesProcessed=%d returning=%d", instancesProcessed, #matches))

	return {
		status = "completed",
		matches = matches,
		truncated = (#matches >= maxResults), -- Don't report exact totalFound, just truncated
	}
end
