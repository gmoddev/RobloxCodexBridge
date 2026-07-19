import { createServer } from "node:http";
import { randomUUID } from "node:crypto";

const DefaultHost = "127.0.0.1";
const DefaultPort = 17315;
const DefaultSessionId = "local";
const DefaultPendingRequestTimeoutMs = 30_000;
const DefaultCompletedResultRetentionMs = 5 * 60_000;
const DefaultStudioTimeoutMs = 10_000;
const DefaultMaxBodyBytes = 10 * 1024 * 1024;
const DefaultMaxQueuedRequests = 1_000;

const SupportedTools = [
  "list",
  "glob",
  "readInstance",
  "readScript",
  "readGuiTree",
  "serialize",
  "captureScreenshot",
  "playtest",
];

const Sessions = new Map();

function GetEnvString(Name, Fallback = "") {
  const Value = process.env[Name];
  if (typeof Value !== "string" || Value.trim() === "") {
    return Fallback;
  }
  return Value.trim();
}

function GetEnvNumber(Name, Fallback) {
  const Value = process.env[Name];
  if (typeof Value !== "string" || Value.trim() === "") {
    return Fallback;
  }

  const Parsed = Number(Value);
  return Number.isFinite(Parsed) && Parsed > 0 ? Parsed : Fallback;
}

const Host = GetEnvString("CODEX_BRIDGE_HOST", DefaultHost);
const Port = GetEnvNumber("CODEX_BRIDGE_PORT", DefaultPort);
const BridgeToken = GetEnvString("CODEX_BRIDGE_TOKEN");
const PendingRequestTimeoutMs = GetEnvNumber("CODEX_BRIDGE_PENDING_REQUEST_TIMEOUT_MS", DefaultPendingRequestTimeoutMs);
const CompletedResultRetentionMs = GetEnvNumber(
  "CODEX_BRIDGE_COMPLETED_RESULT_RETENTION_MS",
  DefaultCompletedResultRetentionMs,
);
const StudioTimeoutMs = GetEnvNumber("CODEX_BRIDGE_STUDIO_TIMEOUT_MS", DefaultStudioTimeoutMs);
const MaxBodyBytes = GetEnvNumber("CODEX_BRIDGE_MAX_BODY_BYTES", DefaultMaxBodyBytes);
const MaxQueuedRequests = GetEnvNumber("CODEX_BRIDGE_MAX_QUEUED_REQUESTS", DefaultMaxQueuedRequests);

function Now() {
  return Date.now();
}

function NewSession(SessionId) {
  const Timestamp = Now();
  return {
    SessionId,
    CreatedAt: Timestamp,
    UpdatedAt: Timestamp,
    StudioConnected: false,
    PluginVersion: null,
    SupportedTools: [...SupportedTools],
    PendingRequests: new Map(),
    PendingOrder: [],
    CompletedResults: new Map(),
    StudioWaiters: [],
  };
}

function GetSession(SessionId = DefaultSessionId) {
  const NormalizedSessionId = typeof SessionId === "string" && SessionId.trim() !== "" ? SessionId.trim() : DefaultSessionId;
  let Session = Sessions.get(NormalizedSessionId);
  if (!Session) {
    Session = NewSession(NormalizedSessionId);
    Sessions.set(NormalizedSessionId, Session);
  }
  return Session;
}

function SessionIdFromRequest(Request, Body) {
  const HeaderSessionId = Request.headers["x-codexbridge-session"];
  if (typeof HeaderSessionId === "string" && HeaderSessionId.trim() !== "") {
    return HeaderSessionId.trim();
  }
  if (Body && typeof Body === "object") {
    return Body.SessionId || Body.sessionId || DefaultSessionId;
  }
  return DefaultSessionId;
}

function IsStudioAlive(Session) {
  return Session.StudioConnected && Session.LastHeartbeatAt && Now() - Session.LastHeartbeatAt <= StudioTimeoutMs;
}

function RefreshStudioState(Session) {
  if (Session.StudioConnected && !IsStudioAlive(Session)) {
    Session.StudioConnected = false;
    Session.UpdatedAt = Now();
  }
}

function SendJson(Response, StatusCode, Payload, Headers = {}) {
  const Body = JSON.stringify(Payload);
  Response.writeHead(StatusCode, {
    "Content-Type": "application/json; charset=utf-8",
    "Content-Length": Buffer.byteLength(Body),
    "Cache-Control": "no-store",
    ...Headers,
  });
  Response.end(Body);
}

function SendNoContent(Response) {
  Response.writeHead(204, { "Cache-Control": "no-store" });
  Response.end();
}

function SendError(Response, StatusCode, Message, Extra = {}) {
  SendJson(Response, StatusCode, {
    Status: "failed",
    Error: Message,
    ...Extra,
  });
}

function RequireToken(Request, Response) {
  if (!BridgeToken) {
    return true;
  }

  const HeaderToken = Request.headers["x-codexbridge-token"];
  const Authorization = Request.headers.authorization;
  const BearerToken =
    typeof Authorization === "string" && Authorization.startsWith("Bearer ") ? Authorization.slice("Bearer ".length) : undefined;

  if (HeaderToken === BridgeToken || BearerToken === BridgeToken) {
    return true;
  }

  SendError(Response, 401, "Invalid or missing CodexBridge token.");
  return false;
}

async function ReadJsonBody(Request) {
  return new Promise((Resolve, Reject) => {
    const Chunks = [];
    let Size = 0;

    Request.on("data", (Chunk) => {
      Size += Chunk.length;
      if (Size > MaxBodyBytes) {
        Reject(new Error(`Request body exceeds ${MaxBodyBytes} bytes.`));
        Request.destroy();
        return;
      }
      Chunks.push(Chunk);
    });

    Request.on("error", Reject);

    Request.on("end", () => {
      const Text = Buffer.concat(Chunks).toString("utf8");
      if (Text.trim() === "") {
        Resolve({});
        return;
      }

      try {
        Resolve(JSON.parse(Text));
      } catch (ErrorValue) {
        Reject(new Error(`Invalid JSON body: ${ErrorValue instanceof Error ? ErrorValue.message : String(ErrorValue)}`));
      }
    });
  });
}

function CompactRequest(Request) {
  return {
    requestId: Request.requestId,
    toolName: Request.toolName,
    params: Request.params ?? {},
    timestamp: Request.timestamp,
    source: Request.source,
  };
}

function PopPendingRequests(Session, Limit = 25) {
  const Requests = [];

  while (Requests.length < Limit && Session.PendingOrder.length > 0) {
    const RequestId = Session.PendingOrder.shift();
    const RequestEnvelope = Session.PendingRequests.get(RequestId);
    if (!RequestEnvelope) {
      continue;
    }

    RequestEnvelope.DeliveredAt = Now();
    Requests.push(CompactRequest(RequestEnvelope));
  }

  return Requests;
}

function ResolveStudioWaiters(Session) {
  if (Session.StudioWaiters.length === 0 || Session.PendingOrder.length === 0) {
    return;
  }

  const Waiters = Session.StudioWaiters.splice(0);
  for (const Waiter of Waiters) {
    clearTimeout(Waiter.Timeout);
    const Requests = PopPendingRequests(Session, Waiter.Limit);
    SendJson(Waiter.Response, 200, { requests: Requests });
  }
}

function CleanupSession(Session) {
  const Timestamp = Now();

  for (const [RequestId, RequestEnvelope] of Session.PendingRequests) {
    const ExpiresAt = RequestEnvelope.ExpiresAt ?? RequestEnvelope.QueuedAt + PendingRequestTimeoutMs;
    if (Timestamp > ExpiresAt) {
      Session.PendingRequests.delete(RequestId);
      Session.CompletedResults.set(RequestId, {
        RequestId,
        CompletedAt: Timestamp,
        Result: {
          status: "failed",
          errorCategory: "studio_request_timed_out",
          error: `Timed out waiting for Studio to complete ${RequestEnvelope.toolName}.`,
          retryable: true,
        },
      });
    }
  }

  Session.PendingOrder = Session.PendingOrder.filter((RequestId) => Session.PendingRequests.has(RequestId));

  for (const [RequestId, ResultEnvelope] of Session.CompletedResults) {
    if (Timestamp - ResultEnvelope.CompletedAt > CompletedResultRetentionMs) {
      Session.CompletedResults.delete(RequestId);
    }
  }

  RefreshStudioState(Session);
}

function CleanupAllSessions() {
  for (const Session of Sessions.values()) {
    CleanupSession(Session);
  }
}

function SessionStatus(Session) {
  CleanupSession(Session);
  const StudioConnected = IsStudioAlive(Session);
  return {
    Status: StudioConnected ? "ready" : "waiting_for_studio",
    SessionId: Session.SessionId,
    StudioConnected,
    PluginVersion: Session.PluginVersion,
    SupportedTools: Session.SupportedTools,
    PendingRequestCount: Session.PendingRequests.size,
    CompletedResultCount: Session.CompletedResults.size,
    LastHeartbeatAt: Session.LastHeartbeatAt ?? null,
    Warnings: StudioConnected ? [] : ["No Roblox Studio plugin is connected to this CodexBridge session."],
  };
}

function HandleSession(Request, Response, Url) {
  const SessionId = Url.searchParams.get("sessionId") || Request.headers["x-codexbridge-session"] || DefaultSessionId;
  const Session = GetSession(SessionId);
  SendJson(Response, 200, SessionStatus(Session));
}

async function HandleRegister(Request, Response) {
  const Body = await ReadJsonBody(Request);
  const Session = GetSession(SessionIdFromRequest(Request, Body));
  const Timestamp = Now();

  Session.StudioConnected = true;
  Session.PluginVersion = Body.PluginVersion || Body.pluginVersion || null;
  Session.SupportedTools =
    Array.isArray(Body.SupportedTools) && Body.SupportedTools.length > 0
      ? Body.SupportedTools.map((Tool) => String(Tool))
      : [...SupportedTools];
  Session.StartedAt = Body.StartedAt || Body.startedAt || Timestamp;
  Session.LastHeartbeatAt = Timestamp;
  Session.UpdatedAt = Timestamp;

  SendJson(Response, 200, {
    Status: "registered",
    SessionId: Session.SessionId,
    PollPath: "/v1/studio/poll",
    StreamPath: "/v1/studio/stream",
    ResultPath: "/v1/studio/result",
  });
}

async function HandleHeartbeat(Request, Response) {
  const Body = await ReadJsonBody(Request);
  const Session = GetSession(SessionIdFromRequest(Request, Body));
  Session.StudioConnected = true;
  Session.LastHeartbeatAt = Now();
  Session.UpdatedAt = Session.LastHeartbeatAt;
  SendJson(Response, 200, {
    Status: "ok",
    SessionId: Session.SessionId,
    Now: Session.LastHeartbeatAt,
  });
}

async function HandleStudioRequest(Request, Response) {
  const Body = await ReadJsonBody(Request);
  const Session = GetSession(SessionIdFromRequest(Request, Body));
  CleanupSession(Session);

  if (!IsStudioAlive(Session)) {
    SendError(Response, 409, "Studio is not connected.", {
      SessionId: Session.SessionId,
      ErrorCategory: "studio_disconnected",
      Retryable: true,
    });
    return;
  }

  if (Session.PendingRequests.size >= MaxQueuedRequests) {
    SendError(Response, 429, `Too many queued Studio requests for session ${Session.SessionId}.`);
    return;
  }

  const RequestId = typeof Body.requestId === "string" && Body.requestId.trim() !== "" ? Body.requestId.trim() : randomUUID();
  const ToolName = typeof Body.toolName === "string" && Body.toolName.trim() !== "" ? Body.toolName.trim() : undefined;
  if (!ToolName) {
    SendError(Response, 400, "toolName must be a non-empty string.");
    return;
  }

  const Timestamp = typeof Body.timestamp === "number" ? Body.timestamp : Now();
  const Params = Body.params && typeof Body.params === "object" && !Array.isArray(Body.params) ? Body.params : {};
  const PlaytestTimeoutMs =
    ToolName === "playtest"
      ? Math.min(Math.max(Number(Params.timeout) || 10, 1), 90) * 1000 + 60_000
      : PendingRequestTimeoutMs;
  const RequestEnvelope = {
    requestId: RequestId,
    toolName: ToolName,
    params: Params,
    timestamp: Timestamp,
    source: Body.source || "unknown",
    QueuedAt: Now(),
    ExpiresAt: Now() + PlaytestTimeoutMs,
  };

  Session.PendingRequests.set(RequestId, RequestEnvelope);
  Session.PendingOrder.push(RequestId);
  Session.UpdatedAt = Now();
  ResolveStudioWaiters(Session);

  SendJson(Response, 202, {
    Status: "queued",
    RequestId,
  });
}

function HandlePoll(Request, Response, Url) {
  const Session = GetSession(Url.searchParams.get("sessionId") || Request.headers["x-codexbridge-session"] || DefaultSessionId);
  const Limit = Math.min(GetPositiveQueryNumber(Url, "limit", 25), 100);
  const TimeoutMs = Math.min(GetPositiveQueryNumber(Url, "timeoutMs", 0), 30_000);
  const Timestamp = Now();

  Session.StudioConnected = true;
  Session.LastHeartbeatAt = Timestamp;
  Session.UpdatedAt = Timestamp;
  CleanupSession(Session);

  const Requests = PopPendingRequests(Session, Limit);
  if (Requests.length > 0 || TimeoutMs <= 0) {
    SendJson(Response, 200, { requests: Requests });
    return;
  }

  const Waiter = {
    Response,
    Limit,
    Timeout: setTimeout(() => {
      Session.StudioWaiters = Session.StudioWaiters.filter((Entry) => Entry !== Waiter);
      SendJson(Response, 200, { requests: [] });
    }, TimeoutMs),
  };
  Session.StudioWaiters.push(Waiter);
}

function GetPositiveQueryNumber(Url, Name, Fallback) {
  const RawValue = Url.searchParams.get(Name);
  if (RawValue === null || RawValue.trim() === "") {
    return Fallback;
  }
  const Parsed = Number(RawValue);
  return Number.isFinite(Parsed) && Parsed >= 0 ? Parsed : Fallback;
}

async function HandleResultPost(Request, Response) {
  const Body = await ReadJsonBody(Request);
  const Session = GetSession(SessionIdFromRequest(Request, Body));
  const RequestId = Body.requestId || Body.RequestId;
  if (typeof RequestId !== "string" || RequestId.trim() === "") {
    SendError(Response, 400, "requestId must be a non-empty string.");
    return;
  }

  const Result = Body.result ?? Body.Result;
  if (Result === undefined) {
    SendError(Response, 400, "result is required.");
    return;
  }

  Session.PendingRequests.delete(RequestId);
  Session.PendingOrder = Session.PendingOrder.filter((Entry) => Entry !== RequestId);
  Session.CompletedResults.set(RequestId, {
    RequestId,
    CompletedAt: Now(),
    Result,
  });
  Session.LastHeartbeatAt = Now();
  Session.StudioConnected = true;
  Session.UpdatedAt = Session.LastHeartbeatAt;

  SendJson(Response, 200, {
    Status: "stored",
    RequestId,
  });
}

function HandleResultGet(Request, Response, Url, RequestIdFromPath) {
  const RequestId = RequestIdFromPath || Url.searchParams.get("requestId");
  if (!RequestId) {
    SendError(Response, 400, "requestId is required.");
    return;
  }

  const Session = GetSession(Url.searchParams.get("sessionId") || Request.headers["x-codexbridge-session"] || DefaultSessionId);
  CleanupSession(Session);

  const ResultEnvelope = Session.CompletedResults.get(RequestId);
  if (ResultEnvelope) {
    SendJson(Response, 200, {
      Status: "completed",
      RequestId,
      Result: ResultEnvelope.Result,
    });
    return;
  }

  if (Session.PendingRequests.has(RequestId)) {
    SendJson(Response, 202, {
      Status: "pending",
      RequestId,
    });
    return;
  }

  SendJson(Response, 404, {
    Status: "not_found",
    RequestId,
  });
}

function HandleStream(Response) {
  SendError(Response, 501, "Streaming transport is not implemented yet. Use /v1/studio/poll.");
}

async function HandleRequest(Request, Response) {
  if (!RequireToken(Request, Response)) {
    return;
  }

  const Url = new URL(Request.url ?? "/", `http://${Host}:${Port}`);
  const Method = Request.method ?? "GET";

  try {
    if (Method === "GET" && Url.pathname === "/health") {
      SendJson(Response, 200, { Status: "ok", Name: "CodexBridge", Now: Now() });
      return;
    }

    if (Method === "GET" && Url.pathname === "/v1/session") {
      HandleSession(Request, Response, Url);
      return;
    }

    if (Method === "POST" && Url.pathname === "/v1/studio/register") {
      await HandleRegister(Request, Response);
      return;
    }

    if (Method === "POST" && Url.pathname === "/v1/studio/heartbeat") {
      await HandleHeartbeat(Request, Response);
      return;
    }

    if (Method === "POST" && Url.pathname === "/v1/studio/request") {
      await HandleStudioRequest(Request, Response);
      return;
    }

    if (Method === "GET" && Url.pathname === "/v1/studio/poll") {
      HandlePoll(Request, Response, Url);
      return;
    }

    if (Method === "POST" && Url.pathname === "/v1/studio/result") {
      await HandleResultPost(Request, Response);
      return;
    }

    if (Method === "GET" && Url.pathname.startsWith("/v1/studio/result/")) {
      const RequestId = decodeURIComponent(Url.pathname.slice("/v1/studio/result/".length));
      HandleResultGet(Request, Response, Url, RequestId);
      return;
    }

    if (Method === "GET" && Url.pathname === "/v1/studio/result") {
      HandleResultGet(Request, Response, Url);
      return;
    }

    if (Method === "GET" && Url.pathname === "/v1/studio/stream") {
      HandleStream(Response);
      return;
    }

    if (Method === "OPTIONS") {
      SendNoContent(Response);
      return;
    }

    SendError(Response, 404, `No route for ${Method} ${Url.pathname}.`);
  } catch (ErrorValue) {
    SendError(Response, 500, ErrorValue instanceof Error ? ErrorValue.message : String(ErrorValue));
  }
}

setInterval(CleanupAllSessions, 5_000).unref();

const Server = createServer((Request, Response) => {
  void HandleRequest(Request, Response);
});

Server.on("clientError", (_ErrorValue, Socket) => {
  Socket.end("HTTP/1.1 400 Bad Request\r\n\r\n");
});

Server.listen(Port, Host, () => {
  console.error(`CodexBridge listener running at http://${Host}:${Port}`);
});
