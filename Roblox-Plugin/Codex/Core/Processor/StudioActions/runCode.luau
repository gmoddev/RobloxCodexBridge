
-- runCode: Execute arbitrary Luau code in Studio Edit context
--
-- Uses loadstring to compile and execute code directly in the plugin context.
-- Unlike runTests which starts a full game simulation (RunService:Run()),
-- this executes code immediately in Edit mode — useful for querying game state,
-- checking properties, running calculations, etc.

local LogService = game:GetService("LogService")

local Codex = script:FindFirstAncestor("Codex")
local Log = require(Codex.Log)

return function(
	_self,
	params: { code: string, timeout: number? }
): {
	status: string,
	output: { string }?,
	returnValue: string?,
	error: string?,
	duration: number?,
}
	local timeout = math.min(params.timeout or 10, 30) -- Cap at 30 seconds
	local output: { string } = {}

	if not params.code or params.code == "" then
		return {
			status = "failed",
			error = "Missing required field: code",
		}
	end

	Log.info("[runCode] Compiling code (" .. #params.code .. " chars)...")

	-- Compile the code
	local fn, compileErr = loadstring(params.code)
	if not fn then
		return {
			status = "failed",
			error = "Compilation error: " .. tostring(compileErr),
		}
	end

	-- Connect to LogService to capture print() output
	-- NOTE: Do NOT call Log.* inside this callback - it causes infinite recursion
	local connection = LogService.MessageOut:Connect(function(message, messageType)
		-- Skip our own log messages to prevent recursion
		if string.find(message, "[runCode]", 1, true) then
			return
		end

		if
			messageType == Enum.MessageType.MessageInfo
			or messageType == Enum.MessageType.MessageOutput
		then
			table.insert(output, message)
		end
	end)

	Log.info("[runCode] Executing code with timeout", timeout, "seconds...")

	local startTime = os.clock()
	local completed = false
	local returnValue: string? = nil
	local execError: string? = nil

	-- Execute in a spawned thread so we can enforce timeout
	local execThread = task.spawn(function()
		local success, result = pcall(fn)
		if success then
			if result ~= nil then
				returnValue = tostring(result)
			end
		else
			execError = tostring(result)
		end
		completed = true
	end)

	-- Wait for completion or timeout
	local elapsed = 0
	while not completed and elapsed < timeout do
		task.wait(0.1)
		elapsed = (os.clock() - startTime)
	end

	-- If timed out, cancel the thread
	if not completed then
		if execThread then
			task.cancel(execThread)
		end
		connection:Disconnect()
		local duration = (os.clock() - startTime) * 1000

		Log.warn("[runCode] Execution timed out after", timeout, "seconds")

		return {
			status = "failed",
			output = output,
			error = string.format("Execution timed out after %ds", timeout),
			duration = duration,
		}
	end

	-- Brief wait to let any remaining print() messages be delivered via LogService
	task.wait(0.05)

	local duration = (os.clock() - startTime) * 1000

	-- Cleanup
	connection:Disconnect()

	if execError then
		Log.info("[runCode] Execution failed:", execError)
		return {
			status = "failed",
			output = output,
			error = execError,
			duration = duration,
		}
	end

	Log.info(
		"[runCode] Execution complete:",
		#output,
		"output lines,",
		string.format("%.2fms", duration)
	)

	return {
		status = "completed",
		output = output,
		returnValue = returnValue,
		duration = duration,
	}
end
