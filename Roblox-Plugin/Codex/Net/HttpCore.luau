

local HttpService = game:GetService("HttpService")
local plugin = script:FindFirstAncestorWhichIsA("Plugin")
local StudioService = game:GetService("StudioService")

-- Require Log module
local Codex = script:FindFirstAncestor("Codex")
local Log = require(Codex.Log)

-- Default to the production Codex backend URL
local PRODUCTION_BACKEND_URL = "https://actions.Codex.gg" -- SET TO PRODUCTION HTTP ACTIONS URL
-- local PRODUCTION_BACKEND_URL = "https://patient-mink-231.convex.site" -- SET TO DEVELOPMENT HTTP ACTIONS URL
-- local PRODUCTION_BACKEND_URL = "https://decisive-spaniel-943.convex.site" -- SET TO DEVELOPMENT HTTP ACTIONS URL

-- More robust determination of CodexBackendUrl
local devOverrideUrlSetting = plugin:GetSetting("BACKEND_URL")
local CodexBackendUrl = PRODUCTION_BACKEND_URL -- Default

if type(devOverrideUrlSetting) == "string" and devOverrideUrlSetting ~= "" then
	CodexBackendUrl = devOverrideUrlSetting -- Use override only if it's a non-empty string
	Log.info("[HttpCore] Using development backend URL override: " .. CodexBackendUrl)
elseif devOverrideUrlSetting ~= nil then -- CORRECTED: Changed elif to elseif
	if type(devOverrideUrlSetting) ~= "string" or devOverrideUrlSetting == "" then
		Log.debug(
			"[HttpCore] Invalid BACKEND_URL setting. Type: ",
			typeof(devOverrideUrlSetting),
			", Value: ",
			tostring(devOverrideUrlSetting),
			". Using PRODUCTION_BACKEND_URL."
		)
	end
	-- If it was nil, or a valid non-empty string, those cases are handled.
end

local API_BASE_PATH = CodexBackendUrl

-- Capture the authenticated Studio user once; returns 0 if not signed in (rare)
local USER_ID = StudioService:GetUserId()

-- Generate a unique client ID for this plugin session
local function generateClientId(): string
	return "plugin_"
		.. tostring(USER_ID)
		.. "_"
		.. tostring(math.floor(tick() * 1000))
		.. "_"
		.. HttpService:GenerateGUID(false):gsub("-", ""):sub(1, 8)
end

-- Store the client ID persistently for this session
local CLIENT_ID = plugin:GetSetting("CLIENT_ID")
if not CLIENT_ID or CLIENT_ID == "" then
	CLIENT_ID = generateClientId()
	plugin:SetSetting("CLIENT_ID", CLIENT_ID)
	Log.info("[HttpCore] Generated new CLIENT_ID: " .. CLIENT_ID)
else
	Log.info("[HttpCore] Using existing CLIENT_ID: " .. CLIENT_ID)
end

local function getKeys(tbl: { [any]: any }?)
	local keys = {}
	if type(tbl) == "table" then
		for k, _ in pairs(tbl) do
			table.insert(keys, tostring(k)) -- Ensure keys are strings for table.concat
		end
	end
	return keys
end

local function request(
	method: string,
	path: string,
	body: any?,
	extraHeaders: { [string]: string }?,
	compress: boolean?
)
	local headers = {
		["Content-Type"] = "application/json",
		-- Always tell backend which Roblox account is running the plugin
		["X-User-Id"] = tostring(USER_ID),
	}

	if extraHeaders then
		for k, v in extraHeaders do
			headers[k] = v
		end
	end

	-- Default URL uses the centralized API base path
	local url = string.format("%s/%s", API_BASE_PATH, path)

	-- Check for URL override in headers (still useful for potentially hitting non-Codex endpoints if needed)
	if extraHeaders and extraHeaders["X-Override-URL"] then
		url = extraHeaders["X-Override-URL"]
		-- Remove from headers to avoid sending it to the server
		headers["X-Override-URL"] = nil
	end

	-- Log all requests consistently (trace level to reduce noise)
	Log.trace(
		string.format("[HttpCore] Sending %s request to %s. Body is %s", method, url, body and "PRESENT" or "NIL")
	)
	Log.trace(string.format("[HttpCore] Headers: X-User-Id=%s", headers["X-User-Id"] or "nil"))

	local encodedBodyJson
	local jsonEncodeSuccess = true

	if body then
		jsonEncodeSuccess, encodedBodyJson = pcall(HttpService.JSONEncode, HttpService, body)
		if not jsonEncodeSuccess then
			Log.error(
				"[HttpCore FATAL] HttpService:JSONEncode FAILED for path: ",
				path,
				" Error: ",
				tostring(encodedBodyJson)
			) -- encodedBodyJson is error here
			-- Optionally, log the body itself if it's not too large or complex, or parts of it
			if type(body) == "table" and body.changes and type(body.changes) == "table" then
				Log.error("[HttpCore FATAL] JSONEncode FAILED. Number of changes in body: ", #body.changes)
			elseif type(body) == "table" then
				Log.error("[HttpCore FATAL] JSONEncode FAILED. Body keys: ", table.concat(getKeys(body), ", ")) -- Helper needed for getKeys
			end
			return nil -- Exit early if JSON encoding fails, as the request can't be made
		end
		Log.trace("[HttpCore] Successfully JSONEncoded body for path: ", path)
	else
		encodedBodyJson = nil
	end

	-- Timeout wrapper: Prevent hanging when network is disconnected
	-- Note: Convex long polling can take up to 25 seconds, batch push .rbxm can take up to 180s for very large services (10K+ instances)
	local TIMEOUT_SECONDS = path == "batch-push-rbxm" and 180 or 20
	local requestCompleted = false
	local pcallSuccess, res

	task.spawn(function()
		local requestOptions: { [string]: any } = {
			Url = url,
			Method = method,
			Headers = headers,
			Body = encodedBodyJson,
		}
		-- Opt-in gzip compression of the request body. The receiver detects
		-- whether the body is gzipped by inspecting the magic bytes (0x1f 0x8b),
		-- not by the Content-Encoding header — Roblox silently skips Compress
		-- below an internal size threshold, so the header would lie.
		if compress and encodedBodyJson then
			requestOptions.Compress = Enum.HttpCompression.Gzip
		end
		pcallSuccess, res = pcall(HttpService.RequestAsync, HttpService, requestOptions)
		requestCompleted = true
	end)

	-- Wait for request to complete or timeout
	local startTime = os.clock()
	while not requestCompleted and (os.clock() - startTime) < TIMEOUT_SECONDS do
		task.wait(0.1)
	end

	-- Check if request timed out
	if not requestCompleted then
		Log.warn("[HttpCore] Request timed out after", TIMEOUT_SECONDS, "seconds for path:", path)
		return {
			Success = false,
			StatusCode = -1,
			StatusMessage = "Request timed out - network may be disconnected",
			Body = "",
		}
	end

	if not pcallSuccess then
		Log.warn("[HttpCore] pcall to HttpService.RequestAsync FAILED. Error: ", tostring(res)) -- 'res' here is the error message
	elseif res then
		Log.trace(
			string.format(
				"[HttpCore] Response Success: %s, StatusCode: %s",
				tostring(res.Success),
				tostring(res.StatusCode)
			)
		)
		if type(res.Body) == "string" and #res.Body < 2000 then -- Log short bodies
			Log.trace("[HttpCore] Response Body: ", res.Body)
		else
			Log.trace("[HttpCore] Response Body: (Too long to log fully or not a string)")
		end
	else
		Log.warn("[HttpCore] pcall to HttpService.RequestAsync succeeded but 'res' object is nil. This is unexpected.")
	end

	-- Defensive formatting for logging
	local statusCodeNum = (res and res.StatusCode and tonumber(res.StatusCode)) or -1

	-- Log response details for debugging
	if statusCodeNum >= 400 then
		-- 404 is a valid response (no project open), use debug level instead of warn
		if statusCodeNum == 404 then
			Log.debug(string.format("[HttpCore] Response %d: %s", statusCodeNum, res.Body or ""))
		else
			Log.warn(string.format("[HttpCore] Error response %d: %s", statusCodeNum, res.Body or ""))
		end
	else
		Log.trace(string.format("[HttpCore] Response %d received", statusCodeNum))
	end

	return res
end

-- Binary POST helper for pre-signed Convex storage upload URLs.
-- Bypasses the JSON-encoding path entirely: Body is the raw buffer payload,
-- Content-Type is caller-supplied (typically "application/octet-stream").
-- 10 s timeout, one retry on failure with 500 ms backoff. Returns the parsed
-- { storageId } from Convex on success.
local function uploadBinary(
	url: string,
	bodyBuffer: buffer,
	contentType: string
): { ok: boolean, storageId: string?, error: string? }
	local TIMEOUT_SECONDS = 10
	local RETRY_BACKOFF_SECONDS = 0.5

	local function attempt(): { ok: boolean, storageId: string?, error: string? }
		local requestCompleted = false
		local pcallSuccess: boolean = false
		local res: any = nil

		task.spawn(function()
			pcallSuccess, res = pcall(HttpService.RequestAsync, HttpService, {
				Url = url,
				Method = "POST",
				Headers = { ["Content-Type"] = contentType },
				Body = buffer.tostring(bodyBuffer),
			})
			requestCompleted = true
		end)

		local startTime = os.clock()
		while not requestCompleted and (os.clock() - startTime) < TIMEOUT_SECONDS do
			task.wait(0.05)
		end

		if not requestCompleted then
			return { ok = false, error = "timeout after " .. tostring(TIMEOUT_SECONDS) .. "s" }
		end
		if not pcallSuccess then
			return { ok = false, error = "RequestAsync error: " .. tostring(res) }
		end
		if not res or not res.Success then
			return {
				ok = false,
				error = string.format(
					"HTTP %s: %s",
					tostring(res and res.StatusCode or "?"),
					tostring(res and res.Body or "")
				),
			}
		end

		local parseOk, parsed = pcall(HttpService.JSONDecode, HttpService, res.Body)
		if not parseOk or type(parsed) ~= "table" or type(parsed.storageId) ~= "string" then
			return { ok = false, error = "invalid response body: " .. tostring(res.Body) }
		end
		return { ok = true, storageId = parsed.storageId }
	end

	local result = attempt()
	if result.ok then
		return result
	end

	Log.warn("[HttpCore.uploadBinary] First attempt failed: " .. tostring(result.error) .. " — retrying once")
	task.wait(RETRY_BACKOFF_SECONDS)
	return attempt()
end

local HttpCore = {
	request = request,
	uploadBinary = uploadBinary,
	CLIENT_ID = CLIENT_ID,
	USER_ID = USER_ID,
	API_BASE_PATH = API_BASE_PATH,
	getPlugin = function()
		return plugin
	end,
}

return HttpCore
