--!strict
-- runTests: Execute game simulation and capture errors
--
-- Uses RunService to start the game (like pressing Play) and LogService.MessageOut
-- to capture all errors that occur during gameplay. This catches runtime errors
-- that only happen during actual gameplay (PlayerAdded, button clicks, etc.).

local RunService = game:GetService("RunService")
local LogService = game:GetService("LogService")

local Codex = script:FindFirstAncestor("Codex")
local Log = require(Codex.Log)

-- Parse line number from error message
-- Example: "ServerScriptService.GameManager:5: attempt to index nil"
local function extractLineNumber(errorMessage: string): number?
	local lineNum = string.match(errorMessage, ":(%d+):")
	return if lineNum then tonumber(lineNum) else nil
end

-- Parse script path from error message
-- Example: "ServerScriptService.GameManager:5: attempt to index nil" -> "ServerScriptService/GameManager"
local function extractScriptPath(errorMessage: string): string?
	-- Match pattern like "ServerScriptService.GameManager" before line number
	local scriptPath = string.match(errorMessage, "([%w%.]+):%d+:")
	if scriptPath then
		-- Convert dots to slashes for hierarchical path
		return string.gsub(scriptPath, "%.", "/")
	end
	return nil
end

export type TestError = {
	scriptPath: string,
	scriptUniqueId: string,
	lineNumber: number?,
	message: string,
	stackTrace: string?,
}

return function(
	_self,
	params: { timeout: number? }
): {
	status: string,
	totalTests: number?,
	passedTests: number?,
	failedTests: number?,
	errors: { TestError }?,
	messages: { string }?,
	duration: number?,
	error: string?,
}
	local timeout = math.min(params.timeout or 10, 30) -- Cap at 30 seconds
	local errors: { TestError } = {}
	local messages: { string } = {}

	Log.info("[runTests] Starting game simulation for", timeout, "seconds...")

	-- Connect to LogService to capture errors in real-time
	-- NOTE: Do NOT call Log.* inside this callback - it causes infinite recursion
	local connection = LogService.MessageOut:Connect(function(message, messageType)
		-- Skip our own log messages to prevent recursion
		if string.find(message, "[runTests]", 1, true) then
			return
		end

		if messageType == Enum.MessageType.MessageError or messageType == Enum.MessageType.MessageWarning then
			local scriptPath = extractScriptPath(message) or "Unknown"
			local lineNumber = extractLineNumber(message)
			local scriptUniqueId = ""

			table.insert(errors, {
				scriptPath = scriptPath,
				scriptUniqueId = scriptUniqueId,
				lineNumber = lineNumber,
				message = message,
				stackTrace = debug.traceback(),
			})
		elseif messageType == Enum.MessageType.MessageInfo or messageType == Enum.MessageType.MessageOutput then
			table.insert(messages, message)
		end
	end)

	-- Start game simulation
	local startTime = os.clock()
	local success, err = pcall(function()
		RunService:Run()
	end)

	if not success then
		connection:Disconnect()
		return {
			status = "failed",
			error = string.format("Failed to start game simulation: %s", tostring(err)),
		}
	end

	Log.info("[runTests] Game simulation started, waiting", timeout, "seconds...")

	-- Wait for timeout
	task.wait(timeout)

	-- Stop simulation
	local stopSuccess, stopErr = pcall(function()
		RunService:Stop()
	end)

	if not stopSuccess then
		Log.warn("[runTests] Warning: Failed to stop game:", tostring(stopErr))
	end

	local duration = (os.clock() - startTime) * 1000 -- Convert to ms

	-- Cleanup
	connection:Disconnect()

	Log.info(
		"[runTests] Simulation complete:",
		#errors,
		"errors,",
		#messages,
		"messages,",
		string.format("%.2fms", duration)
	)

	return {
		status = "completed",
		totalTests = 1, -- Always 1 full simulation
		passedTests = if #errors == 0 then 1 else 0,
		failedTests = if #errors > 0 then 1 else 0,
		errors = errors,
		messages = messages,
		duration = duration,
	}
end
