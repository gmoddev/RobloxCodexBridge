--!strict
-- Simple logging configuration - single source of truth

local LogConfig = {
	ENABLE_LOGS = false, -- Disabled by default for performance (logging is expensive in Roblox)
}

-- Function to toggle logging state
function LogConfig.setLogging(enabled: boolean)
	LogConfig.ENABLE_LOGS = enabled

	-- Also update Log module's level to make logs actually appear
	-- We need to do this because init.server.luau sets Log.__level = "Off" on startup
	local Log = require(script.Parent.Log)
	if enabled then
		Log.__setLevel("Info") -- Enable Info, Warn, Error logs when toggled on
	else
		Log.__setLevel("Off") -- Disable all logs when toggled off
	end
end

function LogConfig.getLogging(): boolean
	return LogConfig.ENABLE_LOGS
end

return LogConfig
