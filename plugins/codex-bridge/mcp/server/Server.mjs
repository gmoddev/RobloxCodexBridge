import { randomUUID } from "node:crypto";
import { readFile } from "node:fs/promises";
import readline from "node:readline";

const PluginManifestUrl = new URL("../../.codex-plugin/plugin.json", import.meta.url);
const PluginManifest = JSON.parse(await readFile(PluginManifestUrl, "utf8"));

const ServerName = "CodexBridge Studio";
const ServerVersion = PluginManifest.version;
const JsonRpcError = {
  MethodNotFound: -32601,
  InvalidParams: -32602,
  InternalError: -32603,
};

const DefaultBridgeUrl = "http://127.0.0.1:17315";
const DefaultRequestPath = "v1/studio/request";
const DefaultResultTemplate = "v1/studio/result/{RequestId}";
const SupportedTools = [
  "GetStudioSession",
  "ListInstances",
  "GlobInstances",
  "ReadInstance",
  "ReadScript",
  "ReadGuiTree",
  "SerializeInstance",
  "CaptureScreenshot",
];

const StudioToolMap = {
  ListInstances: "list",
  GlobInstances: "glob",
  ReadInstance: "readInstance",
  ReadScript: "readScript",
  ReadGuiTree: "readGuiTree",
  SerializeInstance: "serialize",
  CaptureScreenshot: "captureScreenshot",
};

function Send(Message) {
  process.stdout.write(`${JSON.stringify(Message)}\n`);
}

function SendResult(Id, Result) {
  Send({ jsonrpc: "2.0", id: Id, result: Result });
}

function SendError(Id, Code, Message) {
  Send({ jsonrpc: "2.0", id: Id, error: { code: Code, message: Message } });
}

function GetEnvString(Name, Fallback = "") {
  const Value = process.env[Name];
  if (typeof Value !== "string" || Value.trim() === "") {
    return Fallback;
  }
  return Value.trim();
}

function GetEnvNumber(Name, Fallback) {
  const RawValue = process.env[Name];
  if (typeof RawValue !== "string" || RawValue.trim() === "") {
    return Fallback;
  }

  const Parsed = Number(RawValue);
  return Number.isFinite(Parsed) && Parsed > 0 ? Parsed : Fallback;
}

function BridgeBaseUrl() {
  return GetEnvString("CODEX_BRIDGE_URL", DefaultBridgeUrl).replace(/\/+$/, "");
}

function BridgeHeaders(ExtraHeaders = {}) {
  const Token = GetEnvString("CODEX_BRIDGE_TOKEN");
  return CompactObject({
    "X-CodexBridge-Token": Token || undefined,
    ...ExtraHeaders,
  });
}

function JoinUrl(PathValue) {
  const CleanPath = String(PathValue ?? "").replace(/^\/+/, "");
  return `${BridgeBaseUrl()}/${CleanPath}`;
}

function RequireObject(Value, Name) {
  if (typeof Value !== "object" || Value === null || Array.isArray(Value)) {
    throw new Error(`${Name} must be an object.`);
  }
  return Value;
}

function RequireString(Value, Name) {
  if (typeof Value !== "string" || Value.trim() === "") {
    throw new Error(`${Name} must be a non-empty string.`);
  }
  return Value.trim();
}

function OptionalInteger(Value, Name, Minimum, Maximum) {
  if (Value === undefined || Value === null) {
    return undefined;
  }
  if (!Number.isInteger(Value)) {
    throw new Error(`${Name} must be an integer.`);
  }
  if (Value < Minimum || Value > Maximum) {
    throw new Error(`${Name} must be between ${Minimum} and ${Maximum}.`);
  }
  return Value;
}

function OptionalBoolean(Value, Name) {
  if (Value === undefined || Value === null) {
    return undefined;
  }
  if (typeof Value !== "boolean") {
    throw new Error(`${Name} must be a boolean.`);
  }
  return Value;
}

function OptionalString(Value, Name) {
  if (Value === undefined || Value === null) {
    return undefined;
  }
  if (typeof Value !== "string") {
    throw new Error(`${Name} must be a string.`);
  }
  return Value;
}

function CompactObject(Value) {
  const Result = {};
  for (const [Key, Entry] of Object.entries(Value)) {
    if (Entry !== undefined) {
      Result[Key] = Entry;
    }
  }
  return Result;
}

function TextResult(Value) {
  return {
    content: [
      {
        type: "text",
        text: typeof Value === "string" ? Value : JSON.stringify(Value, null, 2),
      },
    ],
  };
}

function JsonTool(
  Name,
  Title,
  Description,
  Properties = {},
  Required = [],
  ExtraAnnotations = {},
) {
  return {
    name: Name,
    title: Title,
    description: Description,
    inputSchema: {
      type: "object",
      properties: Properties,
      required: Required,
      additionalProperties: false,
    },
    annotations: {
      readOnlyHint: true,
      destructiveHint: false,
      idempotentHint: false,
      openWorldHint: true,
      ...ExtraAnnotations,
    },
  };
}

function Tools() {
  const UniqueIdProperty = {
    type: "string",
    minLength: 1,
    description: "Live Studio CodexUniqueID. StarterGui is usually sg1.",
  };
  const SessionProperties = {
    SessionId: {
      type: "string",
      description: "Optional CodexBridge session id. Defaults to CODEX_BRIDGE_SESSION_ID.",
    },
  };

  return [
    JsonTool(
      "GetStudioSession",
      "Get Studio Session",
      "Check CodexBridge context and report whether the MCP bridge can target a live Studio session.",
      SessionProperties,
      [],
      { idempotentHint: true },
    ),
    JsonTool(
      "ListInstances",
      "List Instances",
      "List live Studio services or children under a CodexUniqueID using the bridge list action.",
      {
        ...SessionProperties,
        UniqueId: UniqueIdProperty,
        MaxDepth: {
          type: "integer",
          minimum: 1,
          maximum: 20,
          default: 1,
        },
        MaxResults: {
          type: "integer",
          minimum: 1,
          maximum: 500,
          default: 500,
        },
      },
    ),
    JsonTool(
      "GlobInstances",
      "Glob Instances",
      "Search live Studio instances by glob pattern and optional class filter.",
      {
        ...SessionProperties,
        Pattern: {
          type: "string",
          minLength: 1,
        },
        ClassFilter: {
          type: "string",
        },
        MaxResults: {
          type: "integer",
          minimum: 1,
          maximum: 500,
          default: 100,
        },
      },
      ["Pattern"],
    ),
    JsonTool(
      "ReadInstance",
      "Read Instance",
      "Read live Studio metadata, attributes, and selected properties for a known CodexUniqueID.",
      {
        ...SessionProperties,
        UniqueId: UniqueIdProperty,
      },
      ["UniqueId"],
    ),
    JsonTool(
      "ReadScript",
      "Read Script",
      "Read source from a live Script, LocalScript, or ModuleScript by CodexUniqueID.",
      {
        ...SessionProperties,
        UniqueId: UniqueIdProperty,
        StartLine: {
          type: "integer",
          minimum: 1,
        },
        EndLine: {
          type: "integer",
          minimum: 1,
        },
      },
      ["UniqueId"],
    ),
    JsonTool(
      "ReadGuiTree",
      "Read GUI Tree",
      "Read a bounded PascalCase GUI hierarchy from live Studio. Defaults to StarterGui (sg1).",
      {
        ...SessionProperties,
        RootUniqueId: {
          type: "string",
          description: "Root CodexUniqueID. Defaults to sg1 for StarterGui.",
        },
        MaxDepth: {
          type: "integer",
          minimum: 1,
          maximum: 20,
          default: 6,
        },
        MaxNodes: {
          type: "integer",
          minimum: 1,
          maximum: 1000,
          default: 500,
        },
        IncludeAbsolute: {
          type: "boolean",
          default: false,
        },
        IncludeText: {
          type: "boolean",
          default: true,
        },
        IncludeImages: {
          type: "boolean",
          default: true,
        },
        IncludeLayout: {
          type: "boolean",
          default: true,
        },
      },
    ),
    JsonTool(
      "SerializeInstance",
      "Serialize Instance",
      "Capture a serialized live Studio instance subtree for diagnostics or rollback planning.",
      {
        ...SessionProperties,
        UniqueId: UniqueIdProperty,
      },
      ["UniqueId"],
    ),
    JsonTool(
      "CaptureScreenshot",
      "Capture Screenshot",
      "Capture a Studio viewport screenshot through the existing bridge screenshot action.",
      {
        ...SessionProperties,
        TemplateName: {
          type: "string",
        },
        MaxWidth: {
          type: "integer",
          minimum: 64,
          maximum: 4096,
          default: 1024,
        },
      },
    ),
  ];
}

async function HttpJson(Method, PathValue, Body, Headers = {}) {
  const AbortControllerInstance = new AbortController();
  const TimeoutMs = GetEnvNumber("CODEX_BRIDGE_HTTP_TIMEOUT_MS", 20000);
  const Timeout = setTimeout(() => AbortControllerInstance.abort(), TimeoutMs);

  try {
    const Response = await fetch(JoinUrl(PathValue), {
      method: Method,
      headers: CompactObject({
        "Content-Type": Body === undefined ? undefined : "application/json",
        ...Headers,
      }),
      body: Body === undefined ? undefined : JSON.stringify(Body),
      signal: AbortControllerInstance.signal,
    });

    const Text = await Response.text();
    let Json = undefined;
    if (Text.trim() !== "") {
      try {
        Json = JSON.parse(Text);
      } catch {
        Json = { RawBody: Text };
      }
    }

    return {
      Ok: Response.ok,
      Status: Response.status,
      StatusText: Response.statusText,
      Json,
      Text,
    };
  } finally {
    clearTimeout(Timeout);
  }
}

function ResolveSessionId(Arguments) {
  return OptionalString(Arguments.SessionId, "SessionId") || GetEnvString("CODEX_BRIDGE_SESSION_ID");
}

async function GetStudioSession(Arguments) {
  const Args = RequireObject(Arguments ?? {}, "arguments");
  const SessionId = ResolveSessionId(Args);
  const Headers = BridgeHeaders({
    "X-CodexBridge-Session": SessionId,
  });

  let SessionResponse;
  try {
    SessionResponse = await HttpJson("GET", "v1/session", undefined, Headers);
  } catch (ErrorValue) {
    return TextResult({
      Status: "bridge_unavailable",
      BridgeUrl: BridgeBaseUrl(),
      SessionId: SessionId || null,
      StudioConnected: false,
      SupportedTools,
      RequestPath: GetEnvString("CODEX_BRIDGE_REQUEST_PATH", DefaultRequestPath),
      ResultTemplate: GetEnvString("CODEX_BRIDGE_RESULT_TEMPLATE", DefaultResultTemplate),
      Warnings: [
        `CodexBridge listener did not respond: ${ErrorValue instanceof Error ? ErrorValue.message : String(ErrorValue)}`,
      ],
    });
  }

  const Body = typeof SessionResponse.Json === "object" && SessionResponse.Json !== null ? SessionResponse.Json : {};

  return TextResult({
    Status: SessionResponse.Ok ? Body.Status || Body.status || "ready" : "bridge_unavailable",
    BridgeUrl: BridgeBaseUrl(),
    SessionId: Body.SessionId || Body.sessionId || SessionId || null,
    StudioConnected: Body.StudioConnected ?? Body.studioConnected ?? SessionResponse.Ok,
    PluginVersion: Body.PluginVersion || Body.pluginVersion || null,
    SupportedTools,
    RequestPath: GetEnvString("CODEX_BRIDGE_REQUEST_PATH", DefaultRequestPath),
    ResultTemplate: GetEnvString("CODEX_BRIDGE_RESULT_TEMPLATE", DefaultResultTemplate),
    Warnings: Body.Warnings || Body.warnings || [],
  });
}

function NormalizeStudioParams(ToolName, Arguments) {
  const Args = RequireObject(Arguments ?? {}, "arguments");

  switch (ToolName) {
    case "ListInstances":
      return CompactObject({
        uniqueId: OptionalString(Args.UniqueId, "UniqueId"),
        maxDepth: OptionalInteger(Args.MaxDepth, "MaxDepth", 1, 20),
        maxResults: OptionalInteger(Args.MaxResults, "MaxResults", 1, 500),
      });
    case "GlobInstances":
      return CompactObject({
        pattern: RequireString(Args.Pattern, "Pattern"),
        classFilter: OptionalString(Args.ClassFilter, "ClassFilter"),
        maxResults: OptionalInteger(Args.MaxResults, "MaxResults", 1, 500),
      });
    case "ReadInstance":
    case "SerializeInstance":
      return {
        uniqueId: RequireString(Args.UniqueId, "UniqueId"),
      };
    case "ReadScript":
      return CompactObject({
        uniqueId: RequireString(Args.UniqueId, "UniqueId"),
        startLine: OptionalInteger(Args.StartLine, "StartLine", 1, 1_000_000),
        endLine: OptionalInteger(Args.EndLine, "EndLine", 1, 1_000_000),
      });
    case "ReadGuiTree":
      return CompactObject({
        RootUniqueId: OptionalString(Args.RootUniqueId, "RootUniqueId"),
        MaxDepth: OptionalInteger(Args.MaxDepth, "MaxDepth", 1, 20),
        MaxNodes: OptionalInteger(Args.MaxNodes, "MaxNodes", 1, 1000),
        IncludeAbsolute: OptionalBoolean(Args.IncludeAbsolute, "IncludeAbsolute"),
        IncludeText: OptionalBoolean(Args.IncludeText, "IncludeText"),
        IncludeImages: OptionalBoolean(Args.IncludeImages, "IncludeImages"),
        IncludeLayout: OptionalBoolean(Args.IncludeLayout, "IncludeLayout"),
      });
    case "CaptureScreenshot":
      return CompactObject({
        templateName: OptionalString(Args.TemplateName, "TemplateName"),
        maxWidth: OptionalInteger(Args.MaxWidth, "MaxWidth", 64, 4096),
      });
    default:
      throw new Error(`Unsupported Studio tool: ${ToolName}`);
  }
}

function ExtractImmediateResult(ResponseJson) {
  if (typeof ResponseJson !== "object" || ResponseJson === null) {
    return undefined;
  }

  if (ResponseJson.result !== undefined) {
    return ResponseJson.result;
  }
  if (ResponseJson.Result !== undefined) {
    return ResponseJson.Result;
  }
  if (ResponseJson.status === "completed" || ResponseJson.status === "failed") {
    return ResponseJson;
  }
  if (ResponseJson.Status === "completed" || ResponseJson.Status === "failed") {
    return ResponseJson;
  }

  return undefined;
}

function ExtractRequestId(ResponseJson, FallbackRequestId) {
  if (typeof ResponseJson !== "object" || ResponseJson === null) {
    return FallbackRequestId;
  }

  return ResponseJson.requestId || ResponseJson.RequestId || FallbackRequestId;
}

async function PollStudioResult(RequestId, Headers) {
  const TimeoutMs = GetEnvNumber("CODEX_BRIDGE_RESULT_TIMEOUT_MS", 30000);
  const PollMs = GetEnvNumber("CODEX_BRIDGE_RESULT_POLL_MS", 1000);
  const StartedAt = Date.now();
  const Template = GetEnvString("CODEX_BRIDGE_RESULT_TEMPLATE", DefaultResultTemplate);
  const EncodedRequestId = encodeURIComponent(RequestId);
  const Paths = [
    Template.replace("{RequestId}", EncodedRequestId),
    `v1/studio/result/${EncodedRequestId}`,
    `v1/studio/result?requestId=${EncodedRequestId}`,
  ];
  const UniquePaths = [...new Set(Paths)];
  let LastStatus = "not-polled";

  while (Date.now() - StartedAt <= TimeoutMs) {
    for (const PathValue of UniquePaths) {
      const Response = await HttpJson("GET", PathValue, undefined, Headers);
      LastStatus = `http-${Response.Status}`;
      if (Response.Status === 202 || Response.Status === 204 || Response.Status === 404) {
        continue;
      }

      const ImmediateResult = ExtractImmediateResult(Response.Json);
      if (Response.Ok && ImmediateResult !== undefined) {
        return ImmediateResult;
      }
    }

    await new Promise((Resolve) => setTimeout(Resolve, PollMs));
  }

  return {
    status: "pending",
    requestId: RequestId,
    error: `Timed out waiting ${TimeoutMs}ms for Studio result (${LastStatus}).`,
  };
}

async function CallStudioAction(ToolName, Arguments) {
  const Args = RequireObject(Arguments ?? {}, "arguments");
  const SessionId = ResolveSessionId(Args);

  const RequestId = `codex_${Date.now()}_${randomUUID().replaceAll("-", "").slice(0, 12)}`;
  const ActionName = StudioToolMap[ToolName];
  const Params = NormalizeStudioParams(ToolName, Args);
  const RequestPath = GetEnvString("CODEX_BRIDGE_REQUEST_PATH", DefaultRequestPath);
  const Headers = BridgeHeaders({
    "X-CodexBridge-Session": SessionId,
  });
  const Body = CompactObject({
    requestId: RequestId,
    toolName: ActionName,
    params: Params,
    sessionId: SessionId,
    timestamp: Date.now(),
    source: "codex-mcp",
  });

  const Response = await HttpJson("POST", RequestPath, Body, Headers);
  if (!Response.Ok) {
    return TextResult({
      status: "failed",
      requestId: RequestId,
      toolName: ToolName,
      actionName: ActionName,
      bridgeStatus: Response.Status,
      error: Response.Json?.RawBody || Response.Text || Response.StatusText,
    });
  }

  const ImmediateResult = ExtractImmediateResult(Response.Json);
  if (ImmediateResult !== undefined) {
    return TextResult(ImmediateResult);
  }

  const QueuedRequestId = ExtractRequestId(Response.Json, RequestId);
  const Result = await PollStudioResult(QueuedRequestId, Headers);
  return TextResult(Result);
}

async function HandleToolCall(Id, Params) {
  const Name = RequireString(Params?.name, "name");
  const Arguments = Params?.arguments ?? {};

  if (Name === "GetStudioSession") {
    SendResult(Id, await GetStudioSession(Arguments));
    return;
  }

  if (!Object.hasOwn(StudioToolMap, Name)) {
    throw new Error(`Unknown tool: ${Name}`);
  }

  SendResult(Id, await CallStudioAction(Name, Arguments));
}

async function HandleRequest(Message) {
  const { id: Id, method: Method, params: Params } = Message;

  if (Method === "initialize") {
    SendResult(Id, {
      protocolVersion: Params?.protocolVersion ?? "2025-11-25",
      capabilities: { tools: {} },
      serverInfo: {
        name: ServerName,
        version: ServerVersion,
      },
    });
    return;
  }

  if (Method === "notifications/initialized" || Id === undefined || Id === null) {
    return;
  }

  if (Method === "tools/list") {
    SendResult(Id, { tools: Tools() });
    return;
  }

  if (Method === "tools/call") {
    try {
      await HandleToolCall(Id, Params);
    } catch (ErrorValue) {
      SendError(
        Id,
        JsonRpcError.InvalidParams,
        ErrorValue instanceof Error ? ErrorValue.message : String(ErrorValue),
      );
    }
    return;
  }

  SendError(Id, JsonRpcError.MethodNotFound, `Method not found: ${Method}`);
}

const Reader = readline.createInterface({
  input: process.stdin,
  crlfDelay: Infinity,
});

Reader.on("line", async (Line) => {
  if (Line.trim() === "") {
    return;
  }

  let Message;
  try {
    Message = JSON.parse(Line);
  } catch (ErrorValue) {
    SendError(null, JsonRpcError.InvalidParams, `Invalid JSON: ${String(ErrorValue)}`);
    return;
  }

  try {
    await HandleRequest(Message);
  } catch (ErrorValue) {
    SendError(
      Message.id ?? null,
      JsonRpcError.InternalError,
      ErrorValue instanceof Error ? ErrorValue.message : String(ErrorValue),
    );
  }
});
