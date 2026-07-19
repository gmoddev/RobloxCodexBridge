
local LogConfig = require(script.Parent.LogConfig)
local Codex = script:FindFirstAncestor("Codex")

local Util = require(Codex.Util)

local function format(...: any): string
	local args = ""

	for _, arg in { ... } do
		args ..= " " .. Util.stringify(arg)
	end

	return args
end

local Log = {
	Level = {
		Off = 0,
		Error = 1,
		Warn = 2,
		Info = 3,
		Debug = 4,
		Trace = 5,
	},
	__level = 4, -- Default to Debug level (3=Info, 4=Debug, 5=Trace)
	__errorReporter = nil :: ((level: string, message: string, stackTrace: string?) -> ())?,
}

function Log.__setLevel(level: string)
	local num = Log.Level[level]

	if not num then
		Log.error("Invalid log level:", level)
	end

	Log.__level = num
end

-- Public function to set log level (same as __setLevel but public)
function Log.setLevel(level: string)
	Log.__setLevel(level)
end

-- Public function to enable/disable all logging
function Log.setEnabled(enabled: boolean)
	if enabled then
		Log.__level = Log.Level.Info -- Default to Info level when enabled
	else
		Log.__level = Log.Level.Off -- Completely silent when disabled
	end
end

-- Set error reporter callback for sending logs to backend
function Log.setErrorReporter(callback: (level: string, message: string, stackTrace: string?) -> ())
	Log.__errorReporter = callback
end

function Log.trace(...: any)
	if LogConfig.ENABLE_LOGS and Log.__level >= Log.Level.Trace then
		print("TRACE:" .. format(...))
	end
end

function Log.debug(...: any)
	if LogConfig.ENABLE_LOGS and Log.__level >= Log.Level.Debug then
		print("DEBUG:" .. format(...))
	end
end

function Log.info(...: any)
	if LogConfig.ENABLE_LOGS and Log.__level >= Log.Level.Info then
		print("INFO:" .. format(...))
	end
end

function Log.warn(...: any)
	local message = format(...)

	-- Always output to studio if log level allows OR if we're sending to remote
	-- This ensures developers can debug locally even when logs are sent to backend
	if (LogConfig.ENABLE_LOGS and Log.__level >= Log.Level.Warn) or Log.__errorReporter then
		warn("WARN:" .. message)
	end

	-- Additionally report warning to backend if reporter is configured
	if Log.__errorReporter then
		local stackTrace = debug.traceback("", 2)
		task.spawn(function()
			pcall(Log.__errorReporter, "warn", message, stackTrace)
		end)
	end
end

function Log.error(...: any)
	local message = format(...)

	-- First, report error to backend if reporter is configured
	-- Must happen BEFORE error() throws to ensure remote logging works
	if Log.__errorReporter then
		-- Get stack trace
		local stackTrace = debug.traceback("", 2)
		-- Call reporter directly (not in task.spawn) to ensure it executes before error throws
		pcall(Log.__errorReporter, "error", message, stackTrace)
	end

	-- Then output to studio if log level allows OR if we're sending to remote
	-- This ensures developers can debug locally even when logs are sent to backend
	if (LogConfig.ENABLE_LOGS and Log.__level >= Log.Level.Error) or Log.__errorReporter then
		error("ERROR:" .. message, 0)
	end
end

return Log
