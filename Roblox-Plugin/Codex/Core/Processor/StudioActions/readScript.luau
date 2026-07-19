
-- readScript: Retrieve script source code

local Codex = script:FindFirstAncestor("Codex")
local UniqueIdHelpers = require(Codex.Util.UniqueIdHelpers)
local helpers = require(script.Parent.helpers)

return function(
	self,
	params: {
		uniqueId: string,
		startLine: number?,
		endLine: number?,
	}
): {
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
	local script = self.tree:getInstance(params.uniqueId)
	if not script or not script:IsDescendantOf(game) then
		-- Clean up stale tree entry if instance was deleted outside of agent
		if script and not script:IsDescendantOf(game) then
			self.tree:removeByInstance(script)
		end
		return {
			status = "failed",
			error = string.format("Script not found: %s", params.uniqueId),
		}
	end

	if not script:IsA("LuaSourceContainer") then
		return {
			status = "failed",
			error = string.format("Instance is not a script: %s", params.uniqueId),
		}
	end

	local parentId = script.Parent and UniqueIdHelpers.getUniqueId(script.Parent) or nil
	local fullSource = script.Source
	local path = helpers.getInstancePath(script)

	-- Count total lines
	local totalLines = 1
	for _ in fullSource:gmatch("\n") do
		totalLines = totalLines + 1
	end

	-- If no startLine/endLine, return full content (backward compatible)
	if not params.startLine and not params.endLine then
		return {
			status = "completed",
			content = fullSource,
			robloxClass = script.ClassName,
			uniqueId = params.uniqueId,
			parentId = parentId,
			path = path,
			totalLines = totalLines,
		}
	end

	-- Validate line range
	local startLine = params.startLine or 1
	local endLine = params.endLine or totalLines

	if startLine < 1 then
		startLine = 1
	end
	if startLine > totalLines then
		return {
			status = "failed",
			error = string.format("startLine %d exceeds total lines %d", startLine, totalLines),
		}
	end
	if endLine < startLine then
		return {
			status = "failed",
			error = string.format("endLine %d must be >= startLine %d", endLine, startLine),
		}
	end
	if endLine > totalLines then
		endLine = totalLines
	end

	-- Extract line range
	local lines: { string } = {}
	local lineNum = 0
	for line in (fullSource .. "\n"):gmatch("([^\n]*)\n") do
		lineNum = lineNum + 1
		if lineNum > endLine then
			break
		end
		if lineNum >= startLine then
			table.insert(lines, line)
		end
	end

	return {
		status = "completed",
		content = table.concat(lines, "\n"),
		robloxClass = script.ClassName,
		uniqueId = params.uniqueId,
		parentId = parentId,
		path = path,
		totalLines = totalLines,
		startLine = startLine,
		endLine = endLine,
	}
end
