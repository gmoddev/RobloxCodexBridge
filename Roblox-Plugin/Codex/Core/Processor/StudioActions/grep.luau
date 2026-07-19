
-- grep: Search script source code for text or Lua patterns
-- Optimized: Early exit, deferred path/ID, time-based yielding, maxMatchesPerScript

local Log = require(script.Parent.Parent.Parent.Parent.Log)
local Codex = script:FindFirstAncestor("Codex")
local UniqueIdHelpers = require(Codex.Util.UniqueIdHelpers)
local helpers = require(script.Parent.helpers)
local grepUtils = require(script.Parent.grepUtils)

return function(
	self,
	params: {
		query: string,
		isPattern: boolean?,
		ignoreCase: boolean?,
		maxResults: number?,
		maxMatchesPerScript: number?,
		scriptClassFilter: ("Script" | "LocalScript" | "ModuleScript")?,
		contextLines: number?,
	}
): {
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
	truncated: boolean?,
	error: string?,
}
	local query = params.query
	local isPattern = params.isPattern or false
	local ignoreCase = params.ignoreCase or false
	local maxResults = params.maxResults or 100
	local maxMatchesPerScript = params.maxMatchesPerScript or 5 -- Low default for MCP/agent
	local scriptClassFilter = params.scriptClassFilter
	local contextLines = math.clamp(params.contextLines or 3, 0, 10)

	-- Validate maxResults
	if maxResults < 1 or maxResults > 500 then
		return {
			status = "failed",
			error = "maxResults must be between 1 and 500",
		}
	end

	-- Validate query
	if query == "" then
		return {
			status = "failed",
			error = "Query cannot be empty",
		}
	end

	-- For plain text search, require at least 2 characters to avoid overly broad searches
	if not isPattern and #query < 2 then
		return {
			status = "failed",
			error = "Query must be at least 2 characters for plain text search",
		}
	end

	-- If using pattern, validate it's a valid Lua pattern
	if isPattern then
		local success, err = pcall(function()
			local _ = string.match("test", query)
		end)
		if not success then
			return {
				status = "failed",
				error = string.format("Invalid Lua pattern: %s", tostring(err)),
			}
		end

		-- Reject degenerate patterns that match everything (expensive and useless)
		local degeneratePatterns = {
			".*",
			".+",
			".",
			".-",
			".?",
			"^.*$",
			"^.+$",
		}
		for _, degenerate in ipairs(degeneratePatterns) do
			if query == degenerate then
				return {
					status = "failed",
					error = string.format(
						"Pattern '%s' is too general and would match everything. Use a more specific pattern, or use 'list' to find all scripts.",
						query
					),
				}
			end
		end
	end

	local matches = {}
	local scriptsProcessed = 0
	local scriptsWithMatches = 0

	-- Time-based yielding: yield every ~10ms to keep Studio responsive
	local YIELD_INTERVAL_MS = 0.010 -- 10ms
	local lastYieldTime = os.clock()

	Log.info(
		string.format(
			"[grep] START query='%s' isPattern=%s maxResults=%d maxMatchesPerScript=%d",
			query,
			tostring(isPattern),
			maxResults,
			maxMatchesPerScript
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

		-- Search descendants for scripts only
		for _, instance in ipairs(service:GetDescendants()) do
			-- Early exit if we have enough matches
			if #matches >= maxResults then
				break
			end

			-- Only search LuaSourceContainer instances (Script, LocalScript, ModuleScript)
			if instance:IsA("LuaSourceContainer") then
				-- Apply script class filter (cheap check first)
				if scriptClassFilter and instance.ClassName ~= scriptClassFilter then
					scriptsProcessed = scriptsProcessed + 1
					-- Time-based yield
					if os.clock() - lastYieldTime >= YIELD_INTERVAL_MS then
						task.wait()
						lastYieldTime = os.clock()
					end
					continue
				end

				scriptsProcessed = scriptsProcessed + 1

				-- Search script content BEFORE getting uniqueId/path (deferred expensive ops)
				local scriptMatches = grepUtils.search(instance, query, isPattern, ignoreCase, maxMatchesPerScript, contextLines)

				-- Only compute uniqueId and path if we have matches
				if scriptMatches and #scriptMatches > 0 then
					scriptsWithMatches = scriptsWithMatches + 1

					-- Now get uniqueId (deferred until after match confirmed)
					local uniqueId = UniqueIdHelpers.getUniqueId(instance)
					if not uniqueId then
						uniqueId = self.tree:getId(instance)
					end

					if uniqueId then
						-- Now compute path (deferred until after match confirmed)
						local path = helpers.getInstancePath(instance)

						for _, match in ipairs(scriptMatches) do
							if #matches >= maxResults then
								break
							end
							table.insert(matches, {
								name = instance.Name,
								uniqueId = uniqueId,
								robloxClass = instance.ClassName,
								path = path,
								lineNumber = match.lineNumber,
								matchText = match.matchText,
								contextBefore = match.contextBefore,
								contextAfter = match.contextAfter,
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
	end

	Log.info(
		string.format(
			"[grep] DONE scriptsProcessed=%d scriptsWithMatches=%d returning=%d",
			scriptsProcessed,
			scriptsWithMatches,
			#matches
		)
	)

	return {
		status = "completed",
		matches = matches,
		truncated = (#matches >= maxResults), -- Don't report exact totalFound, just truncated
	}
end
