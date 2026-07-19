
-- StudioActionService: Connects Roblox Studio to the local CodexBridge listener.
-- Responsible for registering the Studio session, polling for action requests,
-- executing existing StudioActions handlers, and posting results back locally.

local HttpService = game:GetService("HttpService")
local Codex = script:FindFirstAncestor("Codex")

local Config = require(Codex.Config)
local Log = require(Codex.Log)
local manifest = require(Codex.manifest)

export type StudioActionServiceConfig = {
	pollInterval: number?,
	maxPollInterval: number?,
	idleGracePolls: number?,
	backoffFactor: number?,
	bridgePollTimeoutMs: number?,
}

local DEFAULT_SESSION_ID = "local"
local DEFAULT_BRIDGE_HOST = "127.0.0.1"
local DEFAULT_BRIDGE_PORT = 17315
local DEFAULT_POLL_TIMEOUT_MS = 5000

local SUPPORTED_TOOLS = {
	"list",
	"glob",
	"readInstance",
	"readScript",
	"readGuiTree",
	"serialize",
	"captureScreenshot",
	"playtest",
}

local StudioActionService = {}
StudioActionService.__index = StudioActionService

local function NormalizeBaseUrl(Host: string, Port: number): string
	local CleanHost = Host
	if CleanHost == "" then
		CleanHost = DEFAULT_BRIDGE_HOST
	end

	if string.sub(CleanHost, 1, 7) == "http://" or string.sub(CleanHost, 1, 8) == "https://" then
		local TrimmedHost = string.gsub(CleanHost, "/+$", "")
		return TrimmedHost
	end

	return string.format("http://%s:%d", CleanHost, Port)
end

local function EncodeQuery(Params: { [string]: any }): string
	local Parts = {}
	for Key, Value in Params do
		if Value ~= nil then
			table.insert(Parts, HttpService:UrlEncode(tostring(Key)) .. "=" .. HttpService:UrlEncode(tostring(Value)))
		end
	end
	return table.concat(Parts, "&")
end

function StudioActionService.new(config: StudioActionServiceConfig?)
	local self = setmetatable({}, StudioActionService)

	local ConfigValue = config or {}
	self.pollInterval = ConfigValue.pollInterval or 1.0
	self.maxPollInterval = ConfigValue.maxPollInterval or 5.0
	self.idleGracePolls = ConfigValue.idleGracePolls or 20
	self.backoffFactor = ConfigValue.backoffFactor or 2
	self.bridgePollTimeoutMs = ConfigValue.bridgePollTimeoutMs or DEFAULT_POLL_TIMEOUT_MS
	self.currentInterval = self.pollInterval
	self.consecutiveEmptyPolls = 0
	self.isPolling = false
	self.isRegistered = false
	self.sessionId = DEFAULT_SESSION_ID
	self.bridgeUrl = NormalizeBaseUrl(DEFAULT_BRIDGE_HOST, DEFAULT_BRIDGE_PORT)
	self.bridgeToken = ""
	self.actionHandlers = nil
	self.__onActionComplete = nil
	self.__onSessionEnded = nil

	return self
end

function StudioActionService:_refreshBridgeConfig()
	local Host = Config:get("CodexBridgeHost") or DEFAULT_BRIDGE_HOST
	local Port = Config:get("CodexBridgePort") or DEFAULT_BRIDGE_PORT
	local SessionId = Config:get("CodexBridgeSessionId") or DEFAULT_SESSION_ID
	local Token = Config:get("CodexBridgeToken") or ""

	if type(Host) ~= "string" then
		Host = DEFAULT_BRIDGE_HOST
	end
	if type(Port) ~= "number" then
		Port = DEFAULT_BRIDGE_PORT
	end
	if type(SessionId) ~= "string" or SessionId == "" then
		SessionId = DEFAULT_SESSION_ID
	end
	if type(Token) ~= "string" then
		Token = ""
	end

	self.sessionId = SessionId
	self.bridgeUrl = NormalizeBaseUrl(Host, Port)
	self.bridgeToken = Token
end

function StudioActionService:_buildUrl(Path: string, QueryParams: { [string]: any }?): string
	local Url = self.bridgeUrl .. "/" .. string.gsub(Path, "^/+", "")
	if QueryParams then
		local Query = EncodeQuery(QueryParams)
		if Query ~= "" then
			Url ..= "?" .. Query
		end
	end
	return Url
end

function StudioActionService:_request(
	Method: string,
	Path: string,
	Body: any?,
	QueryParams: { [string]: any }?
): { Success: boolean, StatusCode: number, StatusMessage: string, Body: string }?
	local EncodedBody: string? = nil
	if Body ~= nil then
		local EncodeSuccess, EncodeResult = pcall(HttpService.JSONEncode, HttpService, Body)
		if not EncodeSuccess then
			Log.warn("[StudioActionService] Failed to encode request body:", EncodeResult)
			return nil
		end
		EncodedBody = EncodeResult
	end

	local Headers = {
		["Content-Type"] = "application/json",
		["X-CodexBridge-Session"] = self.sessionId,
	}

	if self.bridgeToken ~= "" then
		Headers["X-CodexBridge-Token"] = self.bridgeToken
	end

	local RequestOptions: { [string]: any } = {
		Url = self:_buildUrl(Path, QueryParams),
		Method = Method,
		Headers = Headers,
	}

	if EncodedBody then
		RequestOptions.Body = EncodedBody
	end

	Log.trace("[StudioActionService] " .. Method .. " " .. RequestOptions.Url)

	local Success, Response = pcall(HttpService.RequestAsync, HttpService, RequestOptions)
	if not Success then
		Log.warn("[StudioActionService] CodexBridge request failed:", Response)
		return nil
	end

	return Response
end

function StudioActionService:_decodeBody(Response): any?
	if not Response or not Response.Body or Response.Body == "" then
		return nil
	end

	local DecodeSuccess, Decoded = pcall(HttpService.JSONDecode, HttpService, Response.Body)
	if not DecodeSuccess then
		Log.warn("[StudioActionService] Failed to decode CodexBridge response:", Decoded)
		return nil
	end

	return Decoded
end

function StudioActionService:_registerSession(): boolean
	local Response = self:_request("POST", "v1/studio/register", {
		SessionId = self.sessionId,
		PluginVersion = manifest.package.version,
		SupportedTools = SUPPORTED_TOOLS,
		StartedAt = math.floor(os.clock() * 1000),
	}, nil)

	if not Response or not Response.Success then
		Log.warn(
			"[StudioActionService] Failed to register with CodexBridge:",
			Response and Response.StatusCode or "no response"
		)
		return false
	end

	self.isRegistered = true
	Log.info("[StudioActionService] Registered with CodexBridge session:", self.sessionId)
	return true
end

-- Backwards-compatible public entry point. The old projectId argument is no
-- longer used as the default session key; CodexBridge defaults to "local".
function StudioActionService:startPolling(_projectId: string, actionHandlers: any)
	if self.isPolling then
		Log.warn("[StudioActionService] Already polling, ignoring start request")
		return
	end

	self:_refreshBridgeConfig()
	self.actionHandlers = actionHandlers
	self.isPolling = true
	self.isRegistered = false
	self.currentInterval = self.pollInterval
	self.consecutiveEmptyPolls = 0

	Log.info("[StudioActionService] Connecting to CodexBridge:", self.bridgeUrl, "session:", self.sessionId)

	task.spawn(function()
		self:_pollLoop()
	end)
end

function StudioActionService:stopPolling()
	if not self.isPolling then
		return
	end

	Log.info("[StudioActionService] Stopping CodexBridge polling")
	self.isPolling = false
	self.isRegistered = false
	self.actionHandlers = nil
end

function StudioActionService:onActionComplete(callback: (toolName: string, path: string?, timestamp: number) -> ())
	self.__onActionComplete = callback
end

function StudioActionService:onSessionEnded(callback: (reason: string) -> ())
	self.__onSessionEnded = callback
end

function StudioActionService:_pollLoop()
	while self.isPolling do
		local Success, Result = pcall(function()
			return self:_poll()
		end)

		local HadActivity = false
		if not Success then
			Log.warn("[StudioActionService] Poll error:", Result)
			self.isRegistered = false
		else
			HadActivity = Result == true
		end

		self:_updatePollInterval(HadActivity)
		task.wait(self.currentInterval)
	end

	Log.info("[StudioActionService] Poll loop ended")
end

function StudioActionService:_updatePollInterval(hadActivity: boolean)
	if hadActivity then
		if self.currentInterval ~= self.pollInterval then
			Log.info("[StudioActionService] Activity detected, resetting poll interval to base")
		end
		self.consecutiveEmptyPolls = 0
		self.currentInterval = self.pollInterval
		return
	end

	self.consecutiveEmptyPolls += 1

	if self.consecutiveEmptyPolls <= self.idleGracePolls then
		self.currentInterval = self.pollInterval
		return
	end

	if self.currentInterval < self.maxPollInterval then
		local NextInterval = self.currentInterval * self.backoffFactor
		if NextInterval > self.maxPollInterval then
			NextInterval = self.maxPollInterval
		end
		self.currentInterval = NextInterval
		Log.info(
			string.format(
				"[StudioActionService] Idle backoff: poll interval now %.1fs (empty polls: %d)",
				self.currentInterval,
				self.consecutiveEmptyPolls
			)
		)
	end
end

function StudioActionService:_poll(): boolean
	if not self.actionHandlers then
		return false
	end

	if not self.isRegistered and not self:_registerSession() then
		return false
	end

	local Response = self:_request("GET", "v1/studio/poll", nil, {
		sessionId = self.sessionId,
		timeoutMs = self.bridgePollTimeoutMs,
	})

	if not Response then
		self.isRegistered = false
		return false
	end

	if Response.StatusCode == 401 then
		self.isRegistered = false
		Log.warn("[StudioActionService] CodexBridge rejected token")
		return false
	end

	if Response.StatusCode == 404 then
		self.isRegistered = false
		Log.warn("[StudioActionService] CodexBridge poll route not found")
		return false
	end

	if not Response.Success then
		Log.warn("[StudioActionService] CodexBridge poll failed:", Response.StatusCode, Response.StatusMessage)
		return false
	end

	local Decoded = self:_decodeBody(Response)
	if type(Decoded) ~= "table" then
		return false
	end

	local Requests = Decoded.requests or Decoded.Requests
	if type(Requests) ~= "table" or #Requests == 0 then
		return false
	end

	Log.info(string.format("[StudioActionService] Received %d CodexBridge request(s)", #Requests))

	for _, Request in ipairs(Requests) do
		self:_executeRequest(Request)
	end

	return true
end

function StudioActionService:_executeRequest(request: {
	requestId: string,
	toolName: string,
	params: { [string]: any },
	timestamp: number,
})
	Log.info(string.format("[StudioActionService] Executing request %s: tool=%s", request.requestId, request.toolName))

	local Success, Result = pcall(function()
		local Handler = self.actionHandlers[request.toolName]
		if not Handler then
			error(string.format("No handler found for tool: %s", request.toolName))
		end
		return Handler(self.actionHandlers, request.params or {})
	end)

	local ResultPayload
	if Success then
		ResultPayload = Result
		Log.info(string.format("[StudioActionService] Request %s completed successfully", request.requestId))

		if ResultPayload.status == "completed" and self.__onActionComplete then
			self.__onActionComplete(request.toolName, ResultPayload.path, request.timestamp)
		end
	else
		ResultPayload = {
			status = "failed",
			error = tostring(Result),
		}
		Log.warn(string.format("[StudioActionService] Request %s failed: %s", request.requestId, tostring(Result)))
	end

	self:_postResult(request.requestId, ResultPayload)
end

function StudioActionService:_postResult(requestId: string, result: { [string]: any })
	local Response = self:_request("POST", "v1/studio/result", {
		requestId = requestId,
		result = result,
		sessionId = self.sessionId,
	}, nil)

	if not Response then
		Log.warn("[StudioActionService] Failed to post result to CodexBridge:", requestId)
		return
	end

	if Response.Success then
		Log.trace("[StudioActionService] Result posted to CodexBridge:", requestId)
	else
		Log.warn(
			"[StudioActionService] CodexBridge result post failed:",
			Response.StatusCode,
			Response.StatusMessage,
			"request:",
			requestId
		)
	end
end

return StudioActionService
