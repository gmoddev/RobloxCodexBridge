--!strict
local HttpCore = require(script.Parent.HttpCore)
local HttpService = game:GetService("HttpService")

-- Require Log module
local Codex = script:FindFirstAncestor("Codex")
local Log = require(Codex.Log)
local manifest = require(Codex.manifest)

-- Minimal fast-path setter for JSONL project structure on connect
local function setProjectStructureFast(projectId: string, jsonl: string)
	if not projectId or projectId == "" then
		Log.warn("[ProjectApi.setProjectStructureFast] Missing projectId, skipping.")
		return { Success = false, StatusCode = 400, Body = "Missing projectId" }
	end

	local path = "setProjectStructureFast"
	local fullUrl = HttpCore.API_BASE_PATH .. "/" .. path

	local body = {
		projectId = projectId,
		projectStructure = jsonl,
	}

	return HttpCore.request("POST", path, body, {
		["X-Override-URL"] = fullUrl,
	})
end


local function open(id, line)
	local url = HttpCore.API_BASE_PATH .. "/open"

	HttpCore.request("POST", "open", { ref = id, line = line }, {
		["X-Override-URL"] = url,
	})
end

local function currentProject()
	if HttpCore.USER_ID == 0 then
		Log.warn("[ProjectApi.currentProject] Cannot fetch, user not signed into Studio.")
		-- Return a simulated error structure
		return {
			Success = false,
			StatusCode = 401,
			StatusMessage = "Unauthorized: Studio user not signed in",
			Body = "",
		}
	end

	local pluginVersion = manifest.package.version
	local path = "getProjectDetails?pluginVersion=" .. pluginVersion
	local projectUrl = HttpCore.API_BASE_PATH .. "/" .. path
	local body = { userId = tostring(HttpCore.USER_ID) }

	Log.info(
		"[ProjectApi.currentProject] Calling POST to " .. projectUrl .. " for userId: " .. tostring(HttpCore.USER_ID)
	)

	-- Use pcall because this might fail if the backend isn't running or network issues occur
	local ok, res = pcall(HttpCore.request, "POST", path, body, {
		["X-Override-URL"] = projectUrl,
	})

	if not ok then
		Log.error("[ProjectApi.currentProject] Request pcall failed:", res) -- res contains the error message
		-- Return a simulated error structure
		return {
			Success = false,
			StatusCode = 500,
			StatusMessage = "Internal Server Error: pcall failed",
			Body = tostring(res),
		}
	end

	Log.info(
		"[ProjectApi.currentProject] Response received. Success: "
			.. tostring(res.Success)
			.. ", StatusCode: "
			.. tostring(res.StatusCode)
	)
	return res
end

-- Get user's current project ID and name for monitoring project switches
-- Returns { error = nil, project = {id, name, promptCount} | nil } on a definitive
-- response from the backend (200 with project, or 404 no-project). Returns
-- { error = "<reason>", project = nil } for network/transport errors so callers
-- can distinguish "user closed project" from "request failed".
local function getUserCurrentProject()
	if HttpCore.USER_ID == 0 then
		Log.warn("[ProjectApi.getUserCurrentProject] Cannot fetch, user not signed into Studio.")
		return { error = "unauthenticated", project = nil }
	end

	local pluginVersion = manifest.package.version
	-- Removed lightweight=true to fetch full details including promptCount
	local path = "getProjectDetails?pluginVersion=" .. pluginVersion
	local url = HttpCore.API_BASE_PATH .. "/" .. path

	Log.debug("[ProjectApi.getUserCurrentProject] Checking user's current project via GET " .. url)

	local ok, res = pcall(HttpCore.request, "GET", path, nil, {
		["X-Override-URL"] = url,
	})

	if not ok then
		Log.warn("[ProjectApi.getUserCurrentProject] Request failed:", res)
		return { error = "pcall_failed", project = nil }
	end

	if res.StatusCode == 200 and res.Body ~= "" then
		local ok2, decoded = pcall(HttpService.JSONDecode, HttpService, res.Body)

		-- Support both full project document (from standard getProjectDetails)
		-- and legacy/lightweight wrapper if backend behavior varies
		if ok2 and decoded then
			local id = decoded._id or decoded.currentProjectId

			if id then
				Log.debug("[ProjectApi.getUserCurrentProject] Current project:", id)
				return {
					error = nil,
					project = {
						id = id,
						name = decoded.name or decoded.currentProjectName or id,
						promptCount = decoded.promptCount or 0,
					},
				}
			end
		end
		-- 200 but no parseable id: treat as transient backend issue, not a project change
		Log.warn("[ProjectApi.getUserCurrentProject] 200 response without parseable project id")
		return { error = "bad_response", project = nil }
	elseif res.StatusCode == 404 then
		-- No project currently active - this is a definitive answer from the backend
		Log.debug("[ProjectApi.getUserCurrentProject] No project currently active")
		return { error = nil, project = nil }
	else
		Log.warn("[ProjectApi.getUserCurrentProject] Unexpected response:", res.StatusCode)
		return { error = "http_" .. tostring(res.StatusCode), project = nil }
	end
end

-- New function to explicitly check for the current project ID (with forced refresh)
local function checkCurrentProject(forceRefresh) -- KEEPING forceRefresh param for now, though backend might not use it for this path
	if HttpCore.USER_ID == 0 then
		Log.warn("[ProjectApi.checkCurrentProject] Cannot fetch, user not signed into Studio.")
		return nil -- This function returns projectId directly or nil
	end

	local path = "getProjectDetails" -- CORRECT path
	local projectUrl = HttpCore.API_BASE_PATH .. "/" .. path
	local body = { userId = tostring(HttpCore.USER_ID) } -- Body for getProjectDetails

	Log.info(
		"[ProjectApi.checkCurrentProject] Calling POST to "
			.. projectUrl
			.. " for userId: "
			.. tostring(HttpCore.USER_ID)
			.. (forceRefresh and " (forceRefresh was true)" or "")
	)

	local ok, res = pcall(HttpCore.request, "POST", path, body, { -- CHANGED to POST, added body
		["X-Override-URL"] = projectUrl,
		["Cache-Control"] = "no-cache", -- Keep Cache-Control as it was
	})

	if not ok or not res.Success or res.StatusCode ~= 200 or res.Body == "" then
		-- 404 is a valid response (no project open), don't log warning
		if res and res.StatusCode == 404 then
			Log.debug("[ProjectApi.checkCurrentProject] No project currently open (404)")
		else
			local statusCode = res and res.StatusCode or "pcall error"
			local errorBody = res and res.Body or ""
			Log.warn(
				"[ProjectApi.checkCurrentProject] Failed to get current project details: "
					.. tostring(statusCode)
					.. (errorBody ~= "" and (" - " .. errorBody) or "")
			)
		end
		return nil
	end

	local ok2, decoded = pcall(HttpService.JSONDecode, HttpService, res.Body)
	-- EXPECTING _id FROM THIS RESPONSE NOW
	if not ok2 or not decoded or not decoded._id then -- CHANGED to expect _id
		Log.warn("[ProjectApi.checkCurrentProject] Failed to decode project _id from response. Body: " .. res.Body)
		return nil
	end

	Log.info("[ProjectApi.checkCurrentProject] Current project _id: " .. decoded._id)
	return decoded._id -- RETURN _id
end

-- Ping machine to trigger Fly autostart via Convex proxy
local function pingMachine(projectId: string)
	if not projectId or projectId == "" then
		Log.warn("[ProjectApi.pingMachine] Missing projectId")
		return {
			success = false,
			pinged = false,
			error = "Missing projectId",
		}
	end

	local path = "api/machines/ping"
	local fullUrl = HttpCore.API_BASE_PATH .. "/" .. path
	local body = {
		projectId = projectId,
	}

	Log.debug("[ProjectApi.pingMachine] Pinging machine for projectId:", projectId)

	local res = HttpCore.request("POST", path, body, {
		["X-Override-URL"] = fullUrl,
	})

	if not res or not res.Success or res.StatusCode ~= 200 then
		Log.warn("[ProjectApi.pingMachine] Request failed:", res and res.StatusCode or "no response")
		return {
			success = false,
			pinged = false,
			error = "Request failed",
		}
	end

	local ok, decoded = pcall(HttpService.JSONDecode, HttpService, res.Body)
	if not ok or not decoded then
		Log.warn("[ProjectApi.pingMachine] Failed to decode response")
		return {
			success = false,
			pinged = false,
			error = "Failed to decode response",
		}
	end

	Log.debug("[ProjectApi.pingMachine] Ping result:", decoded.pinged and "success" or "failed")

	return decoded
end

-- Check if the plugin version is allowed (not outdated)
-- Returns { allowed: boolean, minVersion: string?, message: string? }
local function checkPluginVersion(pluginVersion: string)
	if not pluginVersion or pluginVersion == "" then
		Log.warn("[ProjectApi.checkPluginVersion] Missing pluginVersion")
		return {
			allowed = false,
			message = "Missing plugin version",
		}
	end

	local path = "api/plugins/checkVersion"
	local fullUrl = HttpCore.API_BASE_PATH .. "/" .. path
	local body = {
		pluginVersion = pluginVersion,
	}

	Log.debug("[ProjectApi.checkPluginVersion] Checking version:", pluginVersion)

	local ok, res = pcall(HttpCore.request, "POST", path, body, {
		["X-Override-URL"] = fullUrl,
	})

	if not ok then
		Log.warn("[ProjectApi.checkPluginVersion] Request failed:", res)
		-- Allow connection on network error to avoid blocking users when backend is down
		return {
			allowed = true,
			message = "Version check unavailable",
		}
	end

	if res.StatusCode == 200 and res.Body ~= "" then
		local ok2, decoded = pcall(HttpService.JSONDecode, HttpService, res.Body)
		if ok2 and decoded then
			Log.debug(
				"[ProjectApi.checkPluginVersion] Version check result:",
				decoded.allowed and "allowed" or "not allowed"
			)
			return {
				allowed = decoded.allowed == true,
				minVersion = decoded.minVersion,
				latestVersion = decoded.latestVersion,
				message = decoded.message,
			}
		end
	end

	-- Allow connection if we can't parse the response
	Log.warn("[ProjectApi.checkPluginVersion] Unexpected response:", res.StatusCode)
	return {
		allowed = true,
		message = "Version check response error",
	}
end

-- Check machine status from Fly.io via Convex
local function checkMachineStatus(projectId: string)
	if not projectId or projectId == "" then
		Log.warn("[ProjectApi.checkMachineStatus] Missing projectId")
		return {
			success = false,
			isReady = false,
			error = "Missing projectId",
		}
	end

	local path = "api/machines/status"
	local fullUrl = HttpCore.API_BASE_PATH .. "/" .. path
	local body = {
		projectId = projectId,
	}

	Log.debug("[ProjectApi.checkMachineStatus] Checking machine status for projectId:", projectId)

	local res = HttpCore.request("POST", path, body, {
		["X-Override-URL"] = fullUrl,
	})

	if not res or not res.Success or res.StatusCode ~= 200 then
		Log.warn("[ProjectApi.checkMachineStatus] Request failed:", res and res.StatusCode or "no response")
		return {
			success = false,
			isReady = false,
			error = "Request failed",
		}
	end

	local ok, decoded = pcall(HttpService.JSONDecode, HttpService, res.Body)
	if not ok or not decoded then
		Log.warn("[ProjectApi.checkMachineStatus] Failed to decode response")
		return {
			success = false,
			isReady = false,
			error = "Failed to decode response",
		}
	end

	if decoded.success == false then
		local errorMsg = decoded.error or "Unknown error from backend"
		Log.warn("[ProjectApi.checkMachineStatus] Backend returned error:", errorMsg)
		return {
			success = false,
			isReady = false,
			error = errorMsg,
		}
	end

	Log.debug(
		"[ProjectApi.checkMachineStatus] Machine status:",
		decoded.isReady and "ready" or "not ready",
		"state:",
		decoded.status and decoded.status.state or "unknown"
	)

	return decoded
end

-- New function to post studio logs

local ProjectApi = {
	open = open,
	currentProject = currentProject,
	getUserCurrentProject = getUserCurrentProject,
	checkCurrentProject = checkCurrentProject,
	setProjectStructureFast = setProjectStructureFast,
	pingMachine = pingMachine,
	checkMachineStatus = checkMachineStatus,
	checkPluginVersion = checkPluginVersion,
}

return ProjectApi
