
local Codex = script:FindFirstAncestor("Codex")
local App = Codex.App

local Types = require(Codex.Types)
local Theme = require(App.Theme)

local function s(len: number): string
	return len > 1 and "s" or ""
end

local function getCategory(op: string, isNew: boolean?): string
	if op == "write" then
		return isNew and "addition" or "update"
	elseif op == "delete" or op == "deleteInstance" then
		return "removal"
	elseif op == "createInstance" or op == "mkdir" then
		return "addition"
	elseif op == "move" or op == "updateInstance" then
		return "update"
	else
		return "update"
	end
end

local function hex(kind: string): string
	local colorValue = Theme.Colors.Diff[kind]

	-- Handle both Fusion Value objects and direct Color3 values
	local color
	if typeof(colorValue) == "Color3" then
		-- Direct Color3 value
		color = colorValue
	elseif colorValue and typeof(colorValue.peek) == "function" then
		-- Fusion Value with peek method
		color = colorValue:peek()
	else
		-- Fallback to a default color if something goes wrong
		warn(
			"[describeChanges] Could not get color for kind:",
			kind,
			"using fallback. ColorValue type:",
			typeof(colorValue)
		)
		color = Color3.fromRGB(128, 128, 128) -- Gray fallback
	end

	return "#" .. color:ToHex()
end

return function(changes: Types.Changes): string
	-- Count unified changes by operation type
	local changesList = changes:getChanges()
	local additions = 0
	local updates = 0
	local removals = 0

	for _, change in ipairs(changesList) do
		local category = getCategory(change.op, change.isNew)

		if category == "addition" then
			additions += 1
		elseif category == "update" then
			updates += 1
		elseif category == "removal" then
			removals += 1
		else
			-- Unknown operation, log warning but don't break UI
			warn("[describeChanges] Unknown category for operation:", change.op)
		end
	end

	local text = "There will be "

	if additions > 0 then
		text ..= `<font color="{hex("Add")}">{additions} addition{s(additions)}</font>`

		if updates > 0 or removals > 0 then
			text ..= ", "
		end
	end

	if updates > 0 then
		text ..= `<font color="{hex("Update")}">{updates} update{s(updates)}</font>`

		if removals > 0 then
			text ..= ", "
		end
	end

	if removals > 0 then
		text ..= `<font color="{hex("Remove")}">{removals} removal{s(removals)}</font>`
	end

	text ..= " applied compared to the server"

	return text
end
