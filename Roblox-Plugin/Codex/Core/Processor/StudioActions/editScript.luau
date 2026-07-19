--!strict
-- editScript: Edit existing script by replacing specific text

local Codex = script:FindFirstAncestor("Codex")
local Log = require(Codex.Log)
local helpers = require(script.Parent.helpers)

return function(
	self,
	params: {
		uniqueId: string,
		old_string: string,
		new_string: string,
		replace_all: boolean?,
	}
): { status: string, path: string?, replacements: number?, error: string? }
	-- 1. Find script by uniqueId
	local scriptInstance = self.tree:getInstance(params.uniqueId)
	if not scriptInstance or not scriptInstance:IsDescendantOf(game) then
		-- Clean up stale tree entry if instance was deleted outside of agent
		if scriptInstance and not scriptInstance:IsDescendantOf(game) then
			self.tree:removeByInstance(scriptInstance)
		end
		return {
			status = "failed",
			error = string.format("Script not found: %s", params.uniqueId),
		}
	end

	-- 2. Verify it's a script
	if not scriptInstance:IsA("LuaSourceContainer") then
		return {
			status = "failed",
			error = string.format("Instance is not a script: %s", params.uniqueId),
		}
	end

	-- 3. Get current content
	local content = scriptInstance.Source

	-- 4. Validate old_string exists
	local firstMatch = string.find(content, params.old_string, 1, true)
	if not firstMatch then
		return {
			status = "failed",
			error = "old_string not found in script content",
		}
	end

	-- 5. Check uniqueness (unless replace_all)
	local replace_all = params.replace_all or false
	if not replace_all then
		local secondMatch = string.find(content, params.old_string, firstMatch + 1, true)
		if secondMatch then
			return {
				status = "failed",
				error = "old_string appears multiple times. Use replace_all=true or provide more context to make it unique.",
			}
		end
	end

	-- 6. Perform replacement
	local newContent: string
	local replacements: number

	if replace_all then
		-- Use gsub for global replacement
		-- Note: gsub treats the pattern specially, so we need to escape magic chars for literal matching
		local escapedOld = string.gsub(params.old_string, "[%(%)%.%%%+%-%*%?%[%]%^%$]", "%%%1")
		local escapedNew = string.gsub(params.new_string, "%%", "%%%%")
		newContent, replacements = string.gsub(content, escapedOld, escapedNew)
	else
		-- Single replacement using string manipulation
		local before = string.sub(content, 1, firstMatch - 1)
		local after = string.sub(content, firstMatch + #params.old_string)
		newContent = before .. params.new_string .. after
		replacements = 1
	end

	-- 7. Update script
	scriptInstance.Source = newContent

	Log.info(string.format("[StudioActions] Edited script: %s (%d replacements)", scriptInstance.Name, replacements))

	return {
		status = "completed",
		path = helpers.getInstancePath(scriptInstance),
		replacements = replacements,
	}
end
