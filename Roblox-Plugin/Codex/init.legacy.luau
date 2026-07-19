

--[[
Not_Lowest + Lemonade (https://lemonade.gg)

Codex is a bridge between Codex and Roblox
]]

-- =============================================================================
-- LOGGING CONTROL - Controlled by LogConfig.luau module
-- =============================================================================

local RunService = game:GetService("RunService")

if RunService:IsRunning() then
	return
end

local Config = require(script.Config)
local Log = require(script.Log)
local LogConfig = require(script.LogConfig)
local App = require(script.App)
local HttpCore = require(script.Net.HttpCore)
local manifest = require(script.manifest)

Config.load()

-- Apply logging control
if LogConfig.ENABLE_LOGS then
	Log.__setLevel(Config:get("LogLevel"))
else
	Log.__setLevel("Off") -- Silence all Log.* calls too
end

-- Set up error reporter to send logs to Convex
-- Add recursion guard to prevent infinite loops
local isReportingError = false

Log.setErrorReporter(function(level: string, message: string, stackTrace: string?)
	-- Prevent infinite recursion if error reporter itself fails
	if isReportingError then
		return
	end

	-- Don't try to report HTTP errors remotely (they'll fail anyway)
	if string.find(message, "HttpCore") or string.find(message, "Http requests are not enabled") then
		return
	end

	-- Get current PROJECT_ID from plugin settings
	local currentProjectId = plugin:GetSetting("PROJECT_ID")

	-- Only send if we have a valid project ID
	if not currentProjectId or currentProjectId == "" then
		return
	end

	-- Send error log to Convex asynchronously
	task.spawn(function()
		-- Set recursion guard
		isReportingError = true

		local success, result = pcall(function()
			return HttpCore.request("POST", "api/plugins/logError", {
				projectId = currentProjectId,
				level = level,
				message = message,
				stackTrace = stackTrace,
				pluginVersion = manifest.package.version,
			})
		end)

		-- Clear recursion guard
		isReportingError = false

		if not success then
			-- Silently fail - don't create infinite error loop
			warn("[ErrorReporter] Failed to send error log:", result)
		end
	end)
end)

-- App.new() -- Defer App.new() until PROJECT_ID is confirmed

-- Only listen for LogLevel changes if logs are enabled
if LogConfig.ENABLE_LOGS then
	Config:onChanged("LogLevel", function(level)
		Log.__setLevel(level)
	end)
end

-- Roblox Services

Log.info("Codex plugin initialized")

-- Clear any stored PROJECT_ID on startup - user must manually connect
plugin:SetSetting("PROJECT_ID", "")

-- Brief wait for services to be fully ready, then initialize App
task.wait(1)
App.new()
