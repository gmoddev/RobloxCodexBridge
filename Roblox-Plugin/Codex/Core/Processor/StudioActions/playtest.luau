
-- playtest: Run the game in sandboxed play mode and capture all logs.
--
-- Uses StudioTestService:ExecutePlayModeAsync for sandboxed play (state reverts after stop).
-- Injects a __PlaytestStopper__ Script into Workspace that captures logs and calls EndTest
-- after the timeout. EndTest properly ends the play session and returns Studio to edit mode.
--
-- When `params.captureFrames` is set, also injects a __PlaytestCaptureLocal__ LocalScript
-- that calls CaptureService:CaptureScreenshot() N times during play. Frame contentIds
-- (`rbxtemp://...`) are routed back to the stopper Script via a RemoteEvent and packed
-- into the EndTest returnValue. After EndTest, this action renders each contentId to
-- a base64 RGBA buffer (single-tile when maxWidth ≤ 1024) and returns them as `frames`.

local HttpService = game:GetService("HttpService")

local Codex = script:FindFirstAncestor("Codex")
local Log = require(Codex.Log)
local HttpCore = require(Codex.Net.HttpCore)
local renderContentId = require(script.Parent.renderContentId)

local MAX_LOGS = 200

type CaptureFramesParams = {
	count: number,
	intervalMs: number,
	stabilizationMs: number,
	maxWidth: number?,
	-- Phase 2: when supplied, plugin uploads each frame as raw RGBA bytes to the
	-- corresponding pre-signed Convex URL and returns `frameStorageIds` instead
	-- of inline `frames`. Old plugins silently ignore this field.
	frameUploadUrls: { string }?,
}

type PlaytestFrame = {
	width: number,
	height: number,
	data: string?,
	tiles: { { x: number, y: number, width: number, height: number, data: string } }?,
}

type PlaytestFrameRef = {
	storageId: string,
	width: number,
	height: number,
}

type PlaytestLogEntry = {
	type: string,
	message: string,
	context: string?,
}

return function(
	_self,
	params: {
		timeout: number?,
		serverScript: string?,
		localScript: string?,
		captureFrames: CaptureFramesParams?,
	}
): {
	status: string,
	errors: {
		{
			scriptPath: string,
			lineNumber: number?,
			message: string,
		}
	}?,
	messages: { string }?,
	-- Chronological log emitted by new plugin versions; preserves cross-type
	-- ordering (an error and its stack lines stay grouped) that the separate
	-- `errors`/`messages` arrays lose. Consumers should prefer this when
	-- present and fall back to the split arrays for old-plugin compatibility.
	logs: { PlaytestLogEntry }?,
	duration: number?,
	frames: { PlaytestFrame }?,
	frameStorageIds: { PlaytestFrameRef }?,
	captureComplete: boolean?,
	captureWallMs: number?,
	captureStartedBySignal: boolean?,
	error: string?,
}
	local timeout = math.min(params.timeout or 10, 60) -- Cap at 60 seconds
	local capture = params.captureFrames

	Log.info(
		"[playtest] Starting play mode for",
		timeout,
		capture and string.format("seconds (capture: %dx)", capture.count) or "seconds..."
	)

	-- Clean up any existing stopper script
	local existingStopper = game.Workspace:FindFirstChild("__PlaytestStopper__")
	if existingStopper then
		existingStopper:Destroy()
	end

	-- Build the stopper Script source. When capture is enabled, the stopper
	-- creates a RemoteEvent in ReplicatedStorage that the capture LocalScript
	-- fires per-frame. The stopper waits for either captureDone or the capture
	-- budget to elapse before calling EndTest, so we never tear down play mode
	-- mid-capture and lose pending frames.
	local stopperSource
	if capture then
		stopperSource = string.format(
			[[
local LogService = game:GetService("LogService")
local StudioTestService = game:GetService("StudioTestService")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MAX_LOGS = %d
local timeout = %d
local stabilizationMs = %d
local frameIntervalMs = %d
local frameCount = %d

local function classifyLogType(messageType)
	if messageType == Enum.MessageType.MessageError then
		return "error"
	elseif messageType == Enum.MessageType.MessageWarning then
		return "warn"
	elseif messageType == Enum.MessageType.MessageInfo then
		return "info"
	elseif messageType == Enum.MessageType.MessageOutput then
		return "print"
	else
		return "unknown"
	end
end

local startedAt = tick()

local messages = {}
local errors = {}
local logs = {}
-- Frames arrive sequence-indexed. The capture loop is sequential (each
-- screenshot waits for its callback before scheduling the next), so callbacks
-- normally arrive in order — but the index lets us defensively compact a
-- sparse table if any frames go missing (FireServer drop, render failure).
local frameContentIdsByIndex = {}
local maxFrameIndex = 0
local captureDone = false
local captureWallMs = 0
local captureStartedBySignal = false

local connection = LogService.MessageOut:Connect(function(message, messageType)
	if string.find(message, "[playtest]", 1, true) then
		return
	end
	if string.find(message, "__PlaytestStopper__", 1, true) then
		return
	end
	if string.find(message, "__PlaytestCaptureLocal__", 1, true) then
		return
	end
	if string.find(message, "__PlaytestCaptureLogs__", 1, true) then
		return
	end

	if #logs < MAX_LOGS then
		table.insert(logs, { type = classifyLogType(messageType), message = message, context = "server" })
	end

	if messageType == Enum.MessageType.MessageError or messageType == Enum.MessageType.MessageWarning then
		if #errors < MAX_LOGS then
			table.insert(errors, message)
		end
	elseif messageType == Enum.MessageType.MessageInfo or messageType == Enum.MessageType.MessageOutput then
		if #messages < MAX_LOGS then
			table.insert(messages, message)
		end
	end
end)

-- Cross-context channel: instances created in ReplicatedStorage on the client
-- aren't visible to the server under FilteringEnabled, so we use a RemoteEvent.
local channel = Instance.new("RemoteEvent")
channel.Name = "__PlaytestCaptureChannel__"
channel.Parent = ReplicatedStorage

-- Same-client BindableEvent: the agent's user LocalScript fires "start" when
-- the mechanic begins and "stop" when it ends, so the capture LocalScript can
-- align its screenshot window with the actual action instead of a fixed
-- stabilization delay. BindableEvents replicate as instances but Fire/Event
-- stay client-local — both injected LocalScripts see the same instance.
local captureSignal = Instance.new("BindableEvent")
captureSignal.Name = "__PlaytestCaptureSignal__"
captureSignal.Parent = ReplicatedStorage

channel.OnServerEvent:Connect(function(_player, payload)
	if type(payload) ~= "table" then return end
	if payload.kind == "frame" and type(payload.id) == "string" then
		if type(payload.index) == "number" then
			frameContentIdsByIndex[payload.index] = payload.id
			if payload.index > maxFrameIndex then
				maxFrameIndex = payload.index
			end
		end
	elseif payload.kind == "done" then
		captureDone = true
		if type(payload.captureWallMs) == "number" then
			captureWallMs = payload.captureWallMs
		end
		if payload.startedBySignal == true then
			captureStartedBySignal = true
		end
	elseif payload.kind == "log" and type(payload.message) == "string" then
		if #logs < MAX_LOGS then
			local msg = payload.message
			if #msg > 4000 then
				msg = string.sub(msg, 1, 4000) .. "… [truncated]"
			end
			table.insert(logs, {
				type = (type(payload.type) == "string") and payload.type or "unknown",
				message = msg,
				context = "client",
			})
		end
	end
end)

-- Baseline validation window (preserves non-capture timing semantics).
task.wait(timeout)

-- Top up to capture budget if the LocalScript hasn't finished yet. Budget
-- covers startup (LocalScripts only begin running after player spawn, ~1-2s)
-- + stabilization + per-frame wall time (under sequential capture, cadence
-- is max(callback_latency, intervalMs); we budget intervalMs + ~250ms typical
-- callback overhead) + safety.
local STARTUP_MARGIN_MS = 3000
local PER_FRAME_OVERHEAD_MS = 250
local SAFETY_MS = 2000
local captureBudgetMs =
	STARTUP_MARGIN_MS
	+ stabilizationMs
	+ frameCount * (frameIntervalMs + PER_FRAME_OVERHEAD_MS)
	+ SAFETY_MS
local elapsedMs = (tick() - startedAt) * 1000
local remainingMs = math.max(0, captureBudgetMs - elapsedMs)
local extraStart = tick()
while not captureDone and (tick() - extraStart) * 1000 < remainingMs do
	task.wait(0.05)
end

-- Let any in-flight client log FireServer deliveries land before we stop listening.
task.wait(0.25)

connection:Disconnect()

-- Sparse → dense ordered list. Skips holes (frames whose callbacks never
-- fired or never made it to FireServer); the consumer sees a contiguous
-- array and `frameContentIds.length` reflects what actually arrived.
local frameContentIds = {}
for i = 1, maxFrameIndex do
	if frameContentIdsByIndex[i] then
		table.insert(frameContentIds, frameContentIdsByIndex[i])
	end
end

local returnData = HttpService:JSONEncode({
	errors = errors,
	messages = messages,
	logs = logs,
	frameContentIds = frameContentIds,
	captureComplete = captureDone,
	captureWallMs = captureWallMs,
	captureStartedBySignal = captureStartedBySignal,
})

StudioTestService:EndTest({
	returnValue = returnData,
})
]],
			MAX_LOGS,
			timeout,
			capture.stabilizationMs,
			capture.intervalMs,
			capture.count
		)
	else
		stopperSource = string.format(
			[[
local LogService = game:GetService("LogService")
local StudioTestService = game:GetService("StudioTestService")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MAX_LOGS = %d
local timeout = %d

local function classifyLogType(messageType)
	if messageType == Enum.MessageType.MessageError then
		return "error"
	elseif messageType == Enum.MessageType.MessageWarning then
		return "warn"
	elseif messageType == Enum.MessageType.MessageInfo then
		return "info"
	elseif messageType == Enum.MessageType.MessageOutput then
		return "print"
	else
		return "unknown"
	end
end

local messages = {}
local errors = {}
local logs = {}

-- Capture all log output
local connection = LogService.MessageOut:Connect(function(message, messageType)
	-- Skip our own log messages
	if string.find(message, "[playtest]", 1, true) then
		return
	end
	if string.find(message, "__PlaytestStopper__", 1, true) then
		return
	end
	if string.find(message, "__PlaytestCaptureLogs__", 1, true) then
		return
	end

	if #logs < MAX_LOGS then
		table.insert(logs, { type = classifyLogType(messageType), message = message, context = "server" })
	end

	if messageType == Enum.MessageType.MessageError or messageType == Enum.MessageType.MessageWarning then
		if #errors < MAX_LOGS then
			table.insert(errors, message)
		end
	elseif messageType == Enum.MessageType.MessageInfo or messageType == Enum.MessageType.MessageOutput then
		if #messages < MAX_LOGS then
			table.insert(messages, message)
		end
	end
end)

-- Cross-context channel for client-side log forwarding. The capture-path
-- stopper creates this too; non-capture playtests need it so the injected
-- __PlaytestCaptureLogs__ LocalScript has somewhere to FireServer.
local channel = Instance.new("RemoteEvent")
channel.Name = "__PlaytestCaptureChannel__"
channel.Parent = ReplicatedStorage

channel.OnServerEvent:Connect(function(_player, payload)
	if type(payload) ~= "table" then return end
	if payload.kind == "log" and type(payload.message) == "string" then
		if #logs < MAX_LOGS then
			local msg = payload.message
			if #msg > 4000 then
				msg = string.sub(msg, 1, 4000) .. "… [truncated]"
			end
			table.insert(logs, {
				type = (type(payload.type) == "string") and payload.type or "unknown",
				message = msg,
				context = "client",
			})
		end
	end
end)

-- Wait for the timeout
task.wait(timeout)

-- Let any in-flight client log FireServer deliveries land before stopping.
task.wait(0.25)

-- Disconnect log capture
connection:Disconnect()

-- Build return data
local returnData = HttpService:JSONEncode({
	errors = errors,
	messages = messages,
	logs = logs,
})

-- End the play session — this properly returns Studio to edit mode
StudioTestService:EndTest({
	returnValue = returnData,
})
]],
			MAX_LOGS,
			timeout
		)
	end

	local stopperScript = Instance.new("Script")
	stopperScript.Name = "__PlaytestStopper__"
	stopperScript.Source = stopperSource

	-- CRITICAL: stopper must be parented BEFORE ExecutePlayModeAsync
	-- ExecutePlayModeAsync copies the edit datamodel at the moment it starts
	stopperScript.Parent = game.Workspace

	local injectedInstances = { stopperScript }

	local function destroyIfPresent(parent: Instance, name: string)
		local existing = parent:FindFirstChild(name)
		if existing then
			existing:Destroy()
		end
	end

	-- Always inject the client log forwarder so client-side LocalScript output
	-- (errors, prints, stack lines) reaches the server-side stopper. Injected
	-- regardless of params.localScript so user-authored LocalScripts already in
	-- the project (e.g. StarterPlayerScripts, StarterCharacterScripts) are
	-- covered too.
	do
		local sps = game:GetService("StarterPlayer").StarterPlayerScripts
		destroyIfPresent(sps, "__PlaytestCaptureLogs__")
		local logForwarder = Instance.new("LocalScript")
		logForwarder.Name = "__PlaytestCaptureLogs__"
		logForwarder.Source = [[
local LogService = game:GetService("LogService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local channel = ReplicatedStorage:WaitForChild("__PlaytestCaptureChannel__", 10)
if not channel then
	return
end

local function classify(messageType)
	if messageType == Enum.MessageType.MessageError then
		return "error"
	elseif messageType == Enum.MessageType.MessageWarning then
		return "warn"
	elseif messageType == Enum.MessageType.MessageInfo then
		return "info"
	elseif messageType == Enum.MessageType.MessageOutput then
		return "print"
	else
		return "unknown"
	end
end

LogService.MessageOut:Connect(function(message, messageType)
	if string.find(message, "[playtest]", 1, true) then
		return
	end
	if string.find(message, "__PlaytestStopper__", 1, true) then
		return
	end
	if string.find(message, "__PlaytestCaptureLocal__", 1, true) then
		return
	end
	if string.find(message, "__PlaytestCaptureLogs__", 1, true) then
		return
	end
	pcall(function()
		channel:FireServer({ kind = "log", type = classify(messageType), message = message })
	end)
end)
]]
		logForwarder.Parent = sps
		table.insert(injectedInstances, logForwarder)
		Log.info("[playtest] Injected __PlaytestCaptureLogs__")
	end

	if params.serverScript then
		local sss = game:GetService("ServerScriptService")
		destroyIfPresent(sss, "__PlaytestUserServerScript__")
		local s = Instance.new("Script")
		s.Name = "__PlaytestUserServerScript__"
		s.Source = params.serverScript
		s.Parent = sss
		table.insert(injectedInstances, s)
		Log.info("[playtest] Injected __PlaytestUserServerScript__")
	end

	if params.localScript then
		-- StarterPlayerScripts is always a default child of StarterPlayer in Studio.
		-- Do NOT parent a LocalScript directly to StarterPlayer — it only runs from
		-- StarterPlayerScripts, StarterCharacterScripts, or a Player's PlayerScripts.
		local sps = game:GetService("StarterPlayer").StarterPlayerScripts
		destroyIfPresent(sps, "__PlaytestUserLocalScript__")
		local ls = Instance.new("LocalScript")
		ls.Name = "__PlaytestUserLocalScript__"
		ls.Source = params.localScript
		ls.Parent = sps
		table.insert(injectedInstances, ls)
		Log.info("[playtest] Injected __PlaytestUserLocalScript__")
	end

	if capture then
		local sps = game:GetService("StarterPlayer").StarterPlayerScripts
		destroyIfPresent(sps, "__PlaytestCaptureLocal__")
		local cl = Instance.new("LocalScript")
		cl.Name = "__PlaytestCaptureLocal__"
		cl.Source = string.format(
			[[
local CaptureService = game:GetService("CaptureService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local stabilizationMs = %d
local frameIntervalMs = %d
local frameCount = %d
local PER_FRAME_TIMEOUT_MS = 1000
local READINESS_TIMEOUT_S = 10
local CAPTURE_START_WAIT_MS = 2000
local CAPTURE_CAMERA_ZOOM_DISTANCE = 10

local channel = ReplicatedStorage:WaitForChild("__PlaytestCaptureChannel__", 10)
if not channel then
	return
end

-- Capture sync signal. Connect early so a "start"/"stop" fired by the agent's
-- user LocalScript before our readiness gate completes is buffered into flags
-- rather than lost (BindableEvent doesn't queue without a connection).
local captureSignal = ReplicatedStorage:WaitForChild("__PlaytestCaptureSignal__", 10)
local startReceived = false
local stopReceived = false
local signalConnection
if captureSignal then
	signalConnection = captureSignal.Event:Connect(function(kind)
		if kind == "start" then
			startReceived = true
		elseif kind == "stop" then
			stopReceived = true
		end
	end)
end

-- Capture-readiness gate. Without this the loop opens its window during the
-- post-spawn camera/viewport churn and CaptureScreenshot returns black
-- contentIds — the "frames 4–15 black" pattern from
-- investigation/playtest-gif-cadence-drift-frame-sequencing-2026-05-09.
-- Wait for: character + humanoid + HRP loaded, CurrentCamera focused on
-- the humanoid, then two render frames so Studio has actually painted.
local player = Players.LocalPlayer
local character = player.Character or player.CharacterAdded:Wait()
local humanoid = character:WaitForChild("Humanoid", READINESS_TIMEOUT_S)
character:WaitForChild("HumanoidRootPart", READINESS_TIMEOUT_S)

local readyDeadline = os.clock() + READINESS_TIMEOUT_S
while os.clock() < readyDeadline do
	local camera = workspace.CurrentCamera
	if camera and humanoid and camera.CameraSubject == humanoid then
		break
	end
	RunService.RenderStepped:Wait()
end
RunService.RenderStepped:Wait()
RunService.RenderStepped:Wait()

-- After readiness, wait for the agent to fire "start" on the capture signal
-- (synchronizes capture window with the mechanic). If no signal arrives within
-- CAPTURE_START_WAIT_MS, fall back to the legacy stabilization-based timing
-- so non-signal-aware playtest scripts still produce GIFs.
local startWaitDeadline = os.clock() + (CAPTURE_START_WAIT_MS / 1000)
while not startReceived and not stopReceived and os.clock() < startWaitDeadline do
	task.wait()
end

-- Fallback stabilization wait: poll for late captureStart so signals
-- that land after CAPTURE_START_WAIT_MS (e.g. when the agent's
-- localScript prologue ran long — `task.wait(2)` + WaitForChild churn
-- routinely fires captureStart at T~2.5s) still drive the capture
-- window. Without the poll, this used to be a blocking task.wait that
-- ignored late signals; a short captureStart→captureStop window then
-- landed entirely inside the wait, leaving stopReceived=true when the
-- frame loop opened → break on iteration 1 → 0 frames → no GIF.
-- See: docs/investigations/playtest-gif-banner-plan-mode-and-errors-2026-05-18.md
-- in Codex-ui (Issue 2 follow-up — Case B timing race).
if not startReceived then
	local stabDeadline = os.clock() + (stabilizationMs / 1000)
	while not startReceived and not stopReceived and os.clock() < stabDeadline do
		task.wait()
	end
end
-- Snapshot AFTER the polling wait so telemetry reflects late signals —
-- the agent-side log will correctly read `sync=signal` when a late
-- captureStart saved the run, instead of falsely `sync=fallback`.
local startedBySignal = startReceived

-- Capture-time camera zoom: clamp Player.CameraMin/MaxZoomDistance to the
-- same value so Roblox's Custom camera snaps to a fixed close distance for
-- the duration of capture. Saved bounds are restored after the loop. Skipped
-- if the game uses a Scriptable camera (player zoom bounds don't apply).
local savedMinZoom, savedMaxZoom
local zoomApplied = false
local function setZoomBounds(targetMin, targetMax)
	-- Roblox enforces min <= max at write time; pick set order to never
	-- transiently violate that.
	if targetMin > player.CameraMaxZoomDistance then
		player.CameraMaxZoomDistance = targetMax
		player.CameraMinZoomDistance = targetMin
	else
		player.CameraMinZoomDistance = targetMin
		player.CameraMaxZoomDistance = targetMax
	end
end
if not stopReceived then
	local ok = pcall(function()
		savedMinZoom = player.CameraMinZoomDistance
		savedMaxZoom = player.CameraMaxZoomDistance
		setZoomBounds(CAPTURE_CAMERA_ZOOM_DISTANCE, CAPTURE_CAMERA_ZOOM_DISTANCE)
	end)
	if ok then
		zoomApplied = true
		-- Two render ticks so the camera controller honors the new clamp
		-- before the first screenshot lands.
		RunService.RenderStepped:Wait()
		RunService.RenderStepped:Wait()
	else
		savedMinZoom = nil
		savedMaxZoom = nil
	end
end

-- Sequential capture: CaptureService can't accept concurrent screenshot
-- requests — firing faster than Studio can service them silently drops
-- callbacks. Wait for each callback before the next request, but skip the
-- post-callback inter-frame wait when we're already behind schedule. Cadence
-- becomes max(callback_latency, frameIntervalMs) — never faster than Studio
-- can sustain (no overrun), never slower than callback alone (no
-- callback+intervalMs pile-up).
local startedAt = os.clock()

for i = 1, frameCount do
	-- Early-exit on "stop" — when the agent fires capture stop, we end the
	-- loop rather than waste frames on the post-action stationary tail.
	if stopReceived then
		break
	end

	local id = nil
	local done = false

	local ok = pcall(function()
		CaptureService:CaptureScreenshot(function(contentId)
			id = contentId
			done = true
		end)
	end)

	if ok then
		-- Frame-grain poll (~16 ms) instead of task.wait(0.05) (~50 ms):
		-- shaves the per-frame floor on instant callbacks.
		local waitStart = os.clock()
		while not done and (os.clock() - waitStart) < (PER_FRAME_TIMEOUT_MS / 1000) do
			task.wait()
		end

		if done and id then
			pcall(function()
				channel:FireServer({ kind = "frame", index = i, id = id })
			end)
		end
	end

	if i < frameCount and not stopReceived then
		local nextAt = startedAt + (i * frameIntervalMs / 1000)
		local delta = nextAt - os.clock()
		if delta > 0 then
			task.wait(delta)
		end
	end
end

-- Restore the saved zoom bounds. Runs on every exit path (loop completion,
-- early "stop", per-frame failures) so the player view isn't left clamped.
if zoomApplied then
	pcall(function()
		setZoomBounds(savedMinZoom, savedMaxZoom)
	end)
end

if signalConnection then
	signalConnection:Disconnect()
end

local elapsedMs = (os.clock() - startedAt) * 1000
pcall(function()
	channel:FireServer({
		kind = "done",
		captureWallMs = elapsedMs,
		startedBySignal = startedBySignal,
	})
end)
]],
			capture.stabilizationMs,
			capture.intervalMs,
			capture.count
		)
		cl.Parent = sps
		table.insert(injectedInstances, cl)
		Log.info("[playtest] Injected __PlaytestCaptureLocal__")
	end

	-- Start play mode (blocking until EndTest is called)
	local startTime = os.clock()
	local StudioTestService = game:GetService("StudioTestService")

	-- Outer budget covers Studio entry + teardown around the validation window.
	-- When capture is enabled, also reserve time for the capture loop (stabilization
	-- + frames) and for edit-mode rendering of each contentId after EndTest.
	local timeoutSeconds = timeout + 50
	if capture then
		local captureSeconds = math.ceil((capture.stabilizationMs + capture.count * capture.intervalMs) / 1000) + 2
		local renderSeconds = math.ceil(capture.count * 0.3) + 1 -- ~300ms per frame edit-mode render
		timeoutSeconds = math.max(timeout, captureSeconds) + 50 + renderSeconds
	end

	local success, resultOrError = pcall(function()
		return StudioTestService:ExecutePlayModeAsync({
			timeoutSeconds = timeoutSeconds,
		})
	end)

	local duration = (os.clock() - startTime) * 1000 -- Convert to ms

	-- Clean up all injected instances from the edit datamodel. Runs on both the
	-- success and failure paths; the play datamodel is discarded automatically.
	for _, inst in ipairs(injectedInstances) do
		if inst and inst.Parent then
			inst:Destroy()
		end
	end

	-- If play mode exited significantly earlier than the timeout, a user-provided
	-- script likely called StudioTestService:EndTest — which also drops captured
	-- log output (their EndTest call overrides ours). Surface it in plugin logs.
	if success and (params.serverScript or params.localScript) and duration < timeout * 1000 * 0.9 then
		Log.warn(
			string.format(
				"[playtest] Play exited early (%dms < %ds timeout). "
					.. "User script may have called StudioTestService:EndTest — log output is lost.",
				duration,
				timeout
			)
		)
	end

	if not success then
		Log.warn("[playtest] ExecutePlayModeAsync failed:", tostring(resultOrError))
		return {
			status = "failed",
			error = string.format("Play mode failed: %s", tostring(resultOrError)),
		}
	end

	-- Parse the returnValue from EndTest
	local errors = {}
	local messages = {}
	local logs: { PlaytestLogEntry } = {}
	local frameContentIds: { string } = {}
	local captureComplete = false
	local captureWallMs: number? = nil
	local captureStartedBySignal: boolean? = nil

	if resultOrError and resultOrError.returnValue then
		local parseSuccess, parsed = pcall(function()
			return HttpService:JSONDecode(resultOrError.returnValue)
		end)

		if parseSuccess and parsed then
			-- Parse error messages to extract script path and line number
			if parsed.errors then
				for _, errorMsg in ipairs(parsed.errors) do
					local scriptPath = "Unknown"
					local lineNumber = nil

					-- Parse "ServerScriptService.GameManager:5: error message".
					-- Character class includes "_" so paths like "__PlaytestUserServerScript__"
					-- or user-named scripts like "GameManager_v2" are not dropped to "Unknown".
					local pathMatch = string.match(errorMsg, "([%w%._]+):%d+:")
					if pathMatch then
						scriptPath = string.gsub(pathMatch, "%.", "/")
					end

					local lineMatch = string.match(errorMsg, ":(%d+):")
					if lineMatch then
						lineNumber = tonumber(lineMatch)
					end

					table.insert(errors, {
						scriptPath = scriptPath,
						lineNumber = lineNumber,
						message = errorMsg,
					})
				end
			end

			if parsed.messages then
				messages = parsed.messages
			end

			if parsed.logs and type(parsed.logs) == "table" then
				for _, entry in ipairs(parsed.logs) do
					if type(entry) == "table" and type(entry.type) == "string" and type(entry.message) == "string" then
						local context = (type(entry.context) == "string") and entry.context or nil
						table.insert(logs, { type = entry.type, message = entry.message, context = context })
					end
				end
			end

			if parsed.frameContentIds and type(parsed.frameContentIds) == "table" then
				frameContentIds = parsed.frameContentIds
			end

			if parsed.captureComplete == true then
				captureComplete = true
			end

			if type(parsed.captureWallMs) == "number" and parsed.captureWallMs > 0 then
				captureWallMs = parsed.captureWallMs
			end

			if parsed.captureStartedBySignal == true then
				captureStartedBySignal = true
			elseif parsed.captureStartedBySignal == false then
				captureStartedBySignal = false
			end
		end
	end

	-- Render captured frames edit-side. `rbxtemp://` IDs from the play datamodel
	-- remain resolvable via AssetService:CreateEditableImageAsync after EndTest.
	-- A failed render skips that frame and continues — never errors the playtest.
	--
	-- Two paths, dispatched on `capture.frameUploadUrls`:
	--   • New (direct upload): render each contentId → raw RGBA buffer → task.spawn
	--     a binary POST to Convex. Returns `frameStorageIds`, no inline frames.
	--     Uploads run in parallel with subsequent renders; we join with a bounded
	--     budget before returning.
	--   • Legacy (in-band): render → base64 → inline `frames` array. Unchanged.
	local frames: { PlaytestFrame }? = nil
	local frameStorageIds: { PlaytestFrameRef }? = nil

	if capture and #frameContentIds > 0 then
		local maxWidth = capture.maxWidth or 1024
		local uploadUrls = capture.frameUploadUrls

		if uploadUrls and #uploadUrls > 0 then
			local results: { PlaytestFrameRef? } = {}
			local pending = 0

			for i, id in ipairs(frameContentIds) do
				local uploadUrl = uploadUrls[i]
				if not uploadUrl then
					Log.warn(
						"[playtest] Missing uploadUrl for frame",
						i,
						"(uploadUrls len:",
						#uploadUrls,
						"contentIds len:",
						#frameContentIds,
						")"
					)
				else
					local renderOk, rendered = pcall(renderContentId.renderToBuffer, id, maxWidth)
					if not renderOk or not rendered then
						-- Multi-tile (portrait viewport with outH > 1024) is an unsupported
						-- aspect for the direct-upload transport — surface it loudly so the
						-- "empty manifest" symptom is greppable. Other render failures keep
						-- the warn level.
						local renderErr = tostring(rendered)
						if string.find(renderErr, "multi%-tile") then
							Log.error(
								"[playtest] Frame render rejected (multi-tile aspect) for index",
								i,
								"— direct-upload transport requires single-tile (outW ≤ 1024 AND outH ≤ 1024);",
								"frame dropped, GIF will be sparse. Cause:",
								renderErr
							)
						else
							Log.warn("[playtest] Frame render failed for index", i, ":", renderErr)
						end
					else
						pending += 1
						local frameIndex = i
						local rgbaBuffer = rendered.rawBuffer
						local frameWidth = rendered.width
						local frameHeight = rendered.height
						task.spawn(function()
							local res = HttpCore.uploadBinary(uploadUrl, rgbaBuffer, "application/octet-stream")
							if res.ok and res.storageId then
								results[frameIndex] = {
									storageId = res.storageId,
									width = frameWidth,
									height = frameHeight,
								}
							else
								Log.warn(
									"[playtest] Frame upload failed for index",
									frameIndex,
									":",
									res.error or "unknown"
								)
							end
							pending -= 1
						end)
					end
				end
			end

			-- Bounded join. 30s is generous: 20 frames × 3 MB / ~1.5 s parallel = a few
			-- seconds in practice; cap protects against a stuck Convex.
			local UPLOAD_BUDGET_SECONDS = 30
			local waitStart = os.clock()
			while pending > 0 and (os.clock() - waitStart) < UPLOAD_BUDGET_SECONDS do
				task.wait(0.1)
			end
			if pending > 0 then
				Log.warn(
					"[playtest] Upload budget exhausted with",
					pending,
					"uploads still pending — emitting partial manifest"
				)
			end

			-- Compact in original frame order, skipping failed/missing slots.
			frameStorageIds = {}
			for i = 1, #frameContentIds do
				local ref = results[i]
				if ref then
					table.insert(frameStorageIds :: any, ref)
				end
			end
		else
			frames = {}
			for i, id in ipairs(frameContentIds) do
				local renderOk, rendered = pcall(renderContentId.render, id, maxWidth)
				if renderOk and rendered then
					table.insert(frames :: any, rendered)
				else
					Log.warn("[playtest] Frame render failed for index", i, ":", tostring(rendered))
				end
			end
		end
	end

	local capturedCount = 0
	local transport = "none"
	if frameStorageIds then
		capturedCount = #frameStorageIds
		transport = "direct-upload"
	elseif frames then
		capturedCount = #frames
		transport = "in-band"
	end

	Log.info(
		"[playtest] Play mode complete:",
		#errors,
		"errors,",
		#messages,
		"messages,",
		string.format("%.2fms", duration),
		capture
				and string.format(
					"(frames: %d/%d, transport: %s, complete: %s, captureWallMs: %s)",
					capturedCount,
					capture.count,
					transport,
					tostring(captureComplete),
					captureWallMs and string.format("%.0f", captureWallMs) or "?"
				)
			or ""
	)

	if capture then
		return {
			status = "completed",
			errors = errors,
			messages = messages,
			logs = logs,
			duration = duration,
			frames = frames,
			frameStorageIds = frameStorageIds,
			captureComplete = captureComplete,
			captureWallMs = captureWallMs,
			captureStartedBySignal = captureStartedBySignal,
		}
	end

	return {
		status = "completed",
		errors = errors,
		messages = messages,
		logs = logs,
		duration = duration,
	}
end
