import { randomUUID } from "node:crypto";
import { spawn } from "node:child_process";
import { readFile } from "node:fs/promises";
import readline from "node:readline";
import { fileURLToPath } from "node:url";

const PluginManifestUrl = new URL("../../.codex-plugin/plugin.json", import.meta.url);
const ListenerServerUrl = new URL("../../bridge/Server.mjs", import.meta.url);
const PluginManifest = JSON.parse(await readFile(PluginManifestUrl, "utf8"));

const ServerName = "CodexBridge Studio";
const ServerVersion = PluginManifest.version;
const JsonRpcError = {
  MethodNotFound: -32601,
  InvalidParams: -32602,
  InternalError: -32603,
  BridgeUnavailable: -32001,
  StudioDisconnected: -32002,
  StudioRequestTimedOut: -32003,
  StudioActionFailed: -32004,
};

const ErrorCategory = {
  InvalidToolArguments: "invalid_tool_arguments",
  BridgeUnavailable: "bridge_unavailable",
  StudioDisconnected: "studio_disconnected",
  StudioRequestTimedOut: "studio_request_timed_out",
  StudioActionFailed: "studio_action_failed",
  InternalMcpFailure: "internal_mcp_failure",
};

const ErrorCodeByCategory = {
  [ErrorCategory.InvalidToolArguments]: JsonRpcError.InvalidParams,
  [ErrorCategory.BridgeUnavailable]: JsonRpcError.BridgeUnavailable,
  [ErrorCategory.StudioDisconnected]: JsonRpcError.StudioDisconnected,
  [ErrorCategory.StudioRequestTimedOut]: JsonRpcError.StudioRequestTimedOut,
  [ErrorCategory.StudioActionFailed]: JsonRpcError.StudioActionFailed,
  [ErrorCategory.InternalMcpFailure]: JsonRpcError.InternalError,
};

class McpToolError extends Error {
  constructor(Category, Message, Retryable = false, Data = {}) {
    super(Message);
    this.name = "McpToolError";
    this.Category = Category;
    this.Code = ErrorCodeByCategory[Category] ?? JsonRpcError.InternalError;
    this.Retryable = Retryable;
    this.Data = Data;
  }
}

const DefaultBridgeUrl = "http://127.0.0.1:17315";
const DefaultRequestPath = "v1/studio/request";
const DefaultResultTemplate = "v1/studio/result/{RequestId}";
const DefaultListenerStartupTimeoutMs = 5_000;
const ListenerHealthTimeoutMs = 500;
const LoopbackHosts = new Set(["127.0.0.1", "localhost", "::1", "[::1]"]);
const SupportedTools = [
  "GetStudioSession",
  "ListInstances",
  "GlobInstances",
  "ReadInstance",
  "ReadScript",
  "ReadGuiTree",
  "SerializeInstance",
  "CaptureScreenshot",
  "RunStudioTests",
  "RunInputScenario",
];

const StudioToolMap = {
  ListInstances: "list",
  GlobInstances: "glob",
  ReadInstance: "readInstance",
  ReadScript: "readScript",
  ReadGuiTree: "readGuiTree",
  SerializeInstance: "serialize",
  CaptureScreenshot: "captureScreenshot",
  RunStudioTests: "playtest",
  RunInputScenario: "playtest",
};

const InputScenarioStepKinds = [
  "WaitForPlayer",
  "WaitForCharacter",
  "WaitForPath",
  "Wait",
  "Key",
  "MouseMove",
  "MouseButton",
  "TextInput",
  "PointerAction",
  "InputBindingFire",
  "AssertPathExists",
  "AssertAttribute",
  "AssertProperty",
  "AssertLogContains",
];
const InputScenarioAssertionKinds = [
  "AssertPathExists",
  "AssertAttribute",
  "AssertProperty",
  "AssertLogContains",
];
const InputScenarioMouseButtons = ["MouseButton1", "MouseButton2", "MouseButton3"];
const MaxInputScenarioSteps = 100;
const MaxInputScenarioAssertions = 50;
const MaxInputScenarioSourceLength = 200_000;

let OwnedListenerProcess;
let ListenerEnsurePromise;

function Send(Message) {
  process.stdout.write(`${JSON.stringify(Message)}\n`);
}

function SendResult(Id, Result) {
  Send({ jsonrpc: "2.0", id: Id, result: Result });
}

function SendError(Id, Code, Message, Data) {
  Send({
    jsonrpc: "2.0",
    id: Id,
    error: CompactObject({
      code: Code,
      message: Message,
      data: Data,
    }),
  });
}

function InvalidToolArguments(Message, Data = {}) {
  return new McpToolError(ErrorCategory.InvalidToolArguments, Message, false, Data);
}

function NormalizeToolError(ErrorValue) {
  if (ErrorValue instanceof McpToolError) {
    return ErrorValue;
  }
  return new McpToolError(
    ErrorCategory.InternalMcpFailure,
    ErrorValue instanceof Error ? ErrorValue.message : String(ErrorValue),
    false,
  );
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

function GetEnvBoolean(Name, Fallback) {
  const RawValue = process.env[Name];
  if (typeof RawValue !== "string" || RawValue.trim() === "") {
    return Fallback;
  }

  const Normalized = RawValue.trim().toLowerCase();
  if (["1", "true", "yes", "on"].includes(Normalized)) {
    return true;
  }
  if (["0", "false", "no", "off"].includes(Normalized)) {
    return false;
  }
  return Fallback;
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

function Delay(DurationMs) {
  return new Promise((Resolve) => setTimeout(Resolve, DurationMs));
}

async function IsBridgeListenerHealthy() {
  const AbortControllerInstance = new AbortController();
  const Timeout = setTimeout(() => AbortControllerInstance.abort(), ListenerHealthTimeoutMs);

  try {
    const Response = await fetch(JoinUrl("health"), {
      headers: BridgeHeaders(),
      signal: AbortControllerInstance.signal,
    });
    const Body = await Response.json().catch(() => undefined);
    return Response.ok && Body?.Status === "ok" && Body?.Name === "CodexBridge";
  } catch {
    return false;
  } finally {
    clearTimeout(Timeout);
  }
}

function StopOwnedListener() {
  const ListenerProcess = OwnedListenerProcess;
  OwnedListenerProcess = undefined;

  if (ListenerProcess && ListenerProcess.exitCode === null && !ListenerProcess.killed) {
    ListenerProcess.kill();
  }
}

async function StartBridgeListener() {
  if (await IsBridgeListenerHealthy()) {
    return true;
  }

  if (!GetEnvBoolean("CODEX_BRIDGE_AUTOSTART", true)) {
    return false;
  }

  let BridgeUrl;
  try {
    BridgeUrl = new URL(BridgeBaseUrl());
  } catch {
    console.error(`CodexBridge listener autostart skipped because CODEX_BRIDGE_URL is invalid: ${BridgeBaseUrl()}`);
    return false;
  }

  if (BridgeUrl.protocol !== "http:" || !LoopbackHosts.has(BridgeUrl.hostname)) {
    console.error(`CodexBridge listener autostart skipped for non-loopback URL: ${BridgeBaseUrl()}`);
    return false;
  }

  const ListenerHost = BridgeUrl.hostname.replace(/^\[|\]$/g, "");
  const ListenerProcess = spawn(process.execPath, [fileURLToPath(ListenerServerUrl)], {
    env: {
      ...process.env,
      CODEX_BRIDGE_HOST: ListenerHost,
      CODEX_BRIDGE_PORT: BridgeUrl.port || "80",
    },
    stdio: ["ignore", "ignore", "inherit"],
    windowsHide: true,
  });
  OwnedListenerProcess = ListenerProcess;

  let SpawnError;
  ListenerProcess.once("error", (ErrorValue) => {
    SpawnError = ErrorValue;
  });
  ListenerProcess.once("exit", () => {
    if (OwnedListenerProcess === ListenerProcess) {
      OwnedListenerProcess = undefined;
    }
  });

  const StartupTimeoutMs = GetEnvNumber("CODEX_BRIDGE_STARTUP_TIMEOUT_MS", DefaultListenerStartupTimeoutMs);
  const Deadline = Date.now() + StartupTimeoutMs;

  while (Date.now() < Deadline) {
    if (await IsBridgeListenerHealthy()) {
      console.error(`CodexBridge MCP started the local listener at ${BridgeBaseUrl()}`);
      return true;
    }
    if (SpawnError) {
      throw SpawnError;
    }
    if (ListenerProcess.exitCode !== null) {
      if (await IsBridgeListenerHealthy()) {
        return true;
      }
      throw new Error(`CodexBridge listener exited during startup with code ${ListenerProcess.exitCode}.`);
    }
    await Delay(50);
  }

  if (OwnedListenerProcess === ListenerProcess) {
    StopOwnedListener();
  }
  throw new Error(`Timed out waiting ${StartupTimeoutMs}ms for the CodexBridge listener.`);
}

async function EnsureBridgeListener() {
  if (!ListenerEnsurePromise) {
    ListenerEnsurePromise = StartBridgeListener()
      .catch((ErrorValue) => {
        console.error(
          `CodexBridge listener autostart failed: ${ErrorValue instanceof Error ? ErrorValue.message : String(ErrorValue)}`,
        );
        return false;
      })
      .finally(() => {
        ListenerEnsurePromise = undefined;
      });
  }

  return ListenerEnsurePromise;
}

function RequireObject(Value, Name) {
  if (typeof Value !== "object" || Value === null || Array.isArray(Value)) {
    throw InvalidToolArguments(`${Name} must be an object.`, { Argument: Name });
  }
  return Value;
}

function RequireString(Value, Name) {
  if (typeof Value !== "string" || Value.trim() === "") {
    throw InvalidToolArguments(`${Name} must be a non-empty string.`, { Argument: Name });
  }
  return Value.trim();
}

function OptionalInteger(Value, Name, Minimum, Maximum) {
  if (Value === undefined || Value === null) {
    return undefined;
  }
  if (!Number.isInteger(Value)) {
    throw InvalidToolArguments(`${Name} must be an integer.`, { Argument: Name });
  }
  if (Value < Minimum || Value > Maximum) {
    throw InvalidToolArguments(`${Name} must be between ${Minimum} and ${Maximum}.`, { Argument: Name });
  }
  return Value;
}

function OptionalBoolean(Value, Name) {
  if (Value === undefined || Value === null) {
    return undefined;
  }
  if (typeof Value !== "boolean") {
    throw InvalidToolArguments(`${Name} must be a boolean.`, { Argument: Name });
  }
  return Value;
}

function OptionalString(Value, Name) {
  if (Value === undefined || Value === null) {
    return undefined;
  }
  if (typeof Value !== "string") {
    throw InvalidToolArguments(`${Name} must be a string.`, { Argument: Name });
  }
  return Value;
}

function OptionalBoundedString(Value, Name, MaximumLength) {
  const StringValue = OptionalString(Value, Name);
  if (StringValue !== undefined && StringValue.length > MaximumLength) {
    throw InvalidToolArguments(`${Name} must not exceed ${MaximumLength} characters.`, { Argument: Name });
  }
  return StringValue;
}

function OptionalEnum(Value, Name, AllowedValues) {
  const StringValue = OptionalString(Value, Name);
  if (StringValue !== undefined && !AllowedValues.includes(StringValue)) {
    throw InvalidToolArguments(`${Name} must be one of: ${AllowedValues.join(", ")}.`, { Argument: Name });
  }
  return StringValue;
}

function RequireArray(Value, Name, MinimumLength, MaximumLength) {
  if (!Array.isArray(Value)) {
    throw InvalidToolArguments(`${Name} must be an array.`, { Argument: Name });
  }
  if (Value.length < MinimumLength || Value.length > MaximumLength) {
    throw InvalidToolArguments(
      `${Name} must contain between ${MinimumLength} and ${MaximumLength} entries.`,
      { Argument: Name },
    );
  }
  return Value;
}

function OptionalArray(Value, Name, MaximumLength) {
  if (Value === undefined || Value === null) {
    return [];
  }
  return RequireArray(Value, Name, 0, MaximumLength);
}

function RequireFiniteNumber(Value, Name, Minimum, Maximum) {
  if (typeof Value !== "number" || !Number.isFinite(Value)) {
    throw InvalidToolArguments(`${Name} must be a finite number.`, { Argument: Name });
  }
  if (Value < Minimum || Value > Maximum) {
    throw InvalidToolArguments(`${Name} must be between ${Minimum} and ${Maximum}.`, { Argument: Name });
  }
  return Value;
}

function RequireInputScenarioIdentifier(Value, Name) {
  const Identifier = RequireString(Value, Name);
  if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(Identifier)) {
    throw InvalidToolArguments(`${Name} must be a Roblox enum/property identifier.`, { Argument: Name });
  }
  return Identifier;
}

function RequireInputScenarioPath(Value, Name) {
  const PathValue = RequireString(Value, Name);
  if (PathValue.length > 500) {
    throw InvalidToolArguments(`${Name} must not exceed 500 characters.`, { Argument: Name });
  }
  return PathValue;
}

function LuaString(Value) {
  return `"${String(Value)
    .replace(/\\/g, "\\\\")
    .replace(/"/g, '\\"')
    .replace(/\r/g, "\\r")
    .replace(/\n/g, "\\n")
    .replace(/\t/g, "\\t")}"`;
}

function LuaNumber(Value, Name, Minimum = -1_000_000, Maximum = 1_000_000) {
  return String(RequireFiniteNumber(Value, Name, Minimum, Maximum));
}

function LuaBoolean(Value, Name) {
  if (typeof Value !== "boolean") {
    throw InvalidToolArguments(`${Name} must be a boolean.`, { Argument: Name });
  }
  return Value ? "true" : "false";
}

function LuaVector2(Value, Name) {
  const VectorValue = RequireObject(Value, Name);
  return `Vector2.new(${LuaNumber(VectorValue.X, `${Name}.X`)}, ${LuaNumber(VectorValue.Y, `${Name}.Y`)})`;
}

function LuaVector3(Value, Name) {
  const VectorValue = RequireObject(Value, Name);
  return `Vector3.new(${LuaNumber(VectorValue.X, `${Name}.X`)}, ${LuaNumber(VectorValue.Y, `${Name}.Y`)}, ${LuaNumber(VectorValue.Z, `${Name}.Z`)})`;
}

function LuaExpectedValue(Value, Name) {
  if (typeof Value === "boolean") {
    return LuaBoolean(Value, Name);
  }
  if (typeof Value === "number") {
    return LuaNumber(Value, Name);
  }
  if (typeof Value === "string") {
    return LuaString(Value);
  }
  if (typeof Value === "object" && Value !== null && !Array.isArray(Value)) {
    if (Object.hasOwn(Value, "Z")) {
      return LuaVector3(Value, Name);
    }
    if (Object.hasOwn(Value, "X") && Object.hasOwn(Value, "Y")) {
      return LuaVector2(Value, Name);
    }
  }

  throw InvalidToolArguments(
    `${Name} must be a boolean, number, string, Vector2 object, or Vector3 object.`,
    { Argument: Name },
  );
}

function NormalizeInputScenarioSmokeName(Args) {
  const SmokeTestName = RequireString(Args.SmokeTestName, "SmokeTestName");
  if (SmokeTestName.length > 64 || !/^[A-Za-z0-9_-]+$/.test(SmokeTestName)) {
    throw InvalidToolArguments(
      "SmokeTestName may contain only letters, numbers, underscores, and hyphens, up to 64 characters.",
      { Argument: "SmokeTestName" },
    );
  }
  return SmokeTestName;
}

function CompileInputScenarioStep(RawStep, PathLabel) {
  const Step = RequireObject(RawStep, PathLabel);
  const Kind = OptionalEnum(Step.Kind, `${PathLabel}.Kind`, InputScenarioStepKinds);
  if (!Kind) {
    throw InvalidToolArguments(`${PathLabel}.Kind is required.`, { Argument: `${PathLabel}.Kind` });
  }

  switch (Kind) {
    case "WaitForPlayer":
      return "WaitForPlayer()";
    case "WaitForCharacter":
      return `WaitForCharacter(${LuaNumber(Step.TimeoutSeconds ?? 10, `${PathLabel}.TimeoutSeconds`, 0.1, 60)})`;
    case "WaitForPath":
      return `ResolvePath(${LuaString(RequireInputScenarioPath(Step.Path, `${PathLabel}.Path`))}, ${LuaNumber(
        Step.TimeoutSeconds ?? 5,
        `${PathLabel}.TimeoutSeconds`,
        0,
        60,
      )})`;
    case "Wait":
      return `task.wait(${LuaNumber(Step.Seconds, `${PathLabel}.Seconds`, 0, 60)})`;
    case "Key":
      return `SendKey(Enum.KeyCode.${RequireInputScenarioIdentifier(
        Step.KeyCode,
        `${PathLabel}.KeyCode`,
      )}, ${LuaBoolean(Step.IsPressed, `${PathLabel}.IsPressed`)}, ${LuaBoolean(
        Step.IsRepeatedKey ?? false,
        `${PathLabel}.IsRepeatedKey`,
      )})`;
    case "MouseMove":
      return `SendMousePosition(${LuaVector2(Step.Position, `${PathLabel}.Position`)})`;
    case "MouseButton":
      return `SendMouseButton(${LuaVector2(Step.Position, `${PathLabel}.Position`)}, Enum.UserInputType.${OptionalEnum(
        Step.Button,
        `${PathLabel}.Button`,
        InputScenarioMouseButtons,
      ) ?? "MouseButton1"}, ${LuaBoolean(Step.IsDown, `${PathLabel}.IsDown`)}, ${LuaNumber(
        Step.RepeatCount ?? 0,
        `${PathLabel}.RepeatCount`,
        0,
        10,
      )})`;
    case "TextInput":
      return `SendTextInput(${LuaString(RequireString(Step.Text, `${PathLabel}.Text`))})`;
    case "PointerAction": {
      const PointerParts = [];
      if (Step.Wheel !== undefined) {
        PointerParts.push(`Wheel = ${LuaNumber(Step.Wheel, `${PathLabel}.Wheel`, -10_000, 10_000)}`);
      }
      if (Step.Pan !== undefined) {
        PointerParts.push(`Pan = ${LuaVector2(Step.Pan, `${PathLabel}.Pan`)}`);
      }
      if (Step.Pinch !== undefined) {
        PointerParts.push(`Pinch = ${LuaNumber(Step.Pinch, `${PathLabel}.Pinch`, -10_000, 10_000)}`);
      }
      if (PointerParts.length === 0) {
        throw InvalidToolArguments(
          `${PathLabel} PointerAction requires Wheel, Pan, or Pinch.`,
          { Argument: PathLabel },
        );
      }
      return `SendPointerAction(${LuaVector2(Step.Position, `${PathLabel}.Position`)}, { ${PointerParts.join(", ")} })`;
    }
    case "InputBindingFire":
      return `FireInputBinding(${LuaString(RequireInputScenarioPath(Step.Path, `${PathLabel}.Path`))}, ${LuaExpectedValue(
        Step.State,
        `${PathLabel}.State`,
      )}, ${LuaNumber(Step.TimeoutSeconds ?? 5, `${PathLabel}.TimeoutSeconds`, 0, 60)})`;
    case "AssertPathExists":
      return `AssertPathExists(${LuaString(RequireInputScenarioPath(Step.Path, `${PathLabel}.Path`))}, ${LuaNumber(
        Step.TimeoutSeconds ?? 5,
        `${PathLabel}.TimeoutSeconds`,
        0,
        60,
      )})`;
    case "AssertAttribute":
      return `AssertAttribute(${LuaString(RequireInputScenarioPath(Step.Path, `${PathLabel}.Path`))}, ${LuaString(
        RequireString(Step.Attribute, `${PathLabel}.Attribute`),
      )}, ${LuaExpectedValue(Step.Equals, `${PathLabel}.Equals`)}, ${LuaNumber(
        Step.TimeoutSeconds ?? 5,
        `${PathLabel}.TimeoutSeconds`,
        0,
        60,
      )})`;
    case "AssertProperty":
      return `AssertProperty(${LuaString(RequireInputScenarioPath(Step.Path, `${PathLabel}.Path`))}, ${LuaString(
        RequireInputScenarioIdentifier(Step.Property, `${PathLabel}.Property`),
      )}, ${LuaExpectedValue(Step.Equals, `${PathLabel}.Equals`)}, ${LuaNumber(
        Step.TimeoutSeconds ?? 5,
        `${PathLabel}.TimeoutSeconds`,
        0,
        60,
      )})`;
    case "AssertLogContains":
      return `AssertLogContains(${LuaString(RequireString(Step.Text, `${PathLabel}.Text`))}, ${LuaNumber(
        Step.TimeoutSeconds ?? 2,
        `${PathLabel}.TimeoutSeconds`,
        0,
        60,
      )})`;
    default:
      throw new McpToolError(ErrorCategory.InternalMcpFailure, `Unhandled input scenario step kind: ${Kind}`);
  }
}

function CompileInputScenarioScript(SmokeTestName, Steps, Assertions) {
  const TestPrefix = `[CODEX_SMOKE:${SmokeTestName}]`;
  const AllSteps = [
    ...Steps.map((Step, Index) => ({ Step, Index: `Steps[${Index}]`, IsAssertion: false })),
    ...Assertions.map((Step, Index) => ({ Step, Index: `Assertions[${Index}]`, IsAssertion: true })),
  ];
  let HasAssertion = false;
  const StepLines = AllSteps.map(({ Step, Index, IsAssertion }) => {
    const StepObject = RequireObject(Step, Index);
    const Kind = RequireString(StepObject.Kind, `${Index}.Kind`);
    if (InputScenarioAssertionKinds.includes(Kind)) {
      HasAssertion = true;
    } else if (IsAssertion) {
      throw InvalidToolArguments(
        `${Index}.Kind must be an assertion kind: ${InputScenarioAssertionKinds.join(", ")}.`,
        { Argument: `${Index}.Kind` },
      );
    }
    return `\t${CompileInputScenarioStep(StepObject, Index)}`;
  });

  if (!HasAssertion) {
    throw InvalidToolArguments(
      "RunInputScenario requires at least one assertion step or assertion entry.",
      { Argument: "Assertions" },
    );
  }

  return `local TestPrefix = ${LuaString(TestPrefix)}
local Players = game:GetService("Players")
local LogService = game:GetService("LogService")
local UserInputService = game:GetService("UserInputService")

local Connections = {}
local TemporaryInstances = {}
local ObservedLogs = {}
local VirtualInput = nil

local function Pass(Message: string)
\tprint(TestPrefix, "PASS", Message)
end

local function Fail(Message: string)
\terror(string.format("%s FAIL %s", TestPrefix, Message), 0)
end

local function Expect(Condition: boolean, Message: string)
\tif Condition then
\t\tPass(Message)
\telse
\t\tFail(Message)
\tend
end

local function Cleanup()
\tfor _, Connection in ipairs(Connections) do
\t\tpcall(function()
\t\t\tConnection:Disconnect()
\t\tend)
\tend
\tfor _, InstanceValue in ipairs(TemporaryInstances) do
\t\tpcall(function()
\t\t\tif InstanceValue and InstanceValue.Parent then
\t\t\t\tInstanceValue:Destroy()
\t\t\tend
\t\tend)
\tend
end

table.insert(Connections, LogService.MessageOut:Connect(function(Message)
\tif #ObservedLogs < 300 then
\t\ttable.insert(ObservedLogs, tostring(Message))
\tend
end))

local function GetVirtualInput()
\tif VirtualInput then
\t\treturn VirtualInput
\tend
\tVirtualInput = UserInputService:CreateVirtualInput()
\tExpect(VirtualInput ~= nil, "VirtualInput is available")
\treturn VirtualInput
end

local function SendInput(Message: string, Callback)
\tlocal Ok, ErrorValue = pcall(Callback)
\tlocal Detail = ""
\tif not Ok then
\t\tDetail = ": " .. tostring(ErrorValue)
\tend
\tExpect(Ok, Message .. Detail)
end

local function SendKey(KeyCode: Enum.KeyCode, IsPressed: boolean, IsRepeatedKey: boolean)
\tSendInput("Key input sent", function()
\t\tGetVirtualInput():SendKey(IsPressed, KeyCode, IsRepeatedKey)
\tend)
end

local function SendMousePosition(Position: Vector2)
\tSendInput("Mouse position sent", function()
\t\tGetVirtualInput():SendMousePosition(Position)
\tend)
end

local function SendMouseButton(Position: Vector2, Button: Enum.UserInputType, IsDown: boolean, RepeatCount: number)
\tSendInput("Mouse button sent", function()
\t\tGetVirtualInput():SendMouseButton(Position, Button, IsDown, RepeatCount)
\tend)
end

local function SendTextInput(Text: string)
\tSendInput("Text input sent", function()
\t\tGetVirtualInput():SendTextInput(Text)
\tend)
end

local function SendPointerAction(Position: Vector2, PointerAction)
\tSendInput("Pointer action sent", function()
\t\tGetVirtualInput():SendPointerAction(Position, PointerAction)
\tend)
end

local function WaitForPlayer()
\tlocal Player = Players.LocalPlayer
\tExpect(Player ~= nil, "LocalPlayer is available")
\treturn Player
end

local function WaitForCharacter(TimeoutSeconds: number)
\tlocal Player = WaitForPlayer()
\tlocal Character = Player.Character
\tif Character then
\t\tPass("Character is available")
\t\treturn Character
\tend
\tlocal Deadline = os.clock() + TimeoutSeconds
\twhile os.clock() < Deadline do
\t\tCharacter = Player.Character
\t\tif Character then
\t\t\tPass("Character appeared")
\t\t\treturn Character
\t\tend
\t\ttask.wait(0.05)
\tend
\tFail("Character did not appear")
end

local function ResolvePath(Path: string, TimeoutSeconds: number)
\tlocal Segments = string.split(Path, ".")
\tExpect(#Segments > 0, "Path has segments")
\tlocal Current = nil
\tlocal ServiceOk, ServiceValue = pcall(function()
\t\treturn game:GetService(Segments[1])
\tend)
\tif ServiceOk then
\t\tCurrent = ServiceValue
\telse
\t\tCurrent = game:FindFirstChild(Segments[1])
\tend
\tExpect(Current ~= nil, "Path root exists: " .. Segments[1])
\tfor Index = 2, #Segments do
\t\tlocal Deadline = os.clock() + TimeoutSeconds
\t\tlocal Child = Current:FindFirstChild(Segments[Index])
\t\twhile not Child and os.clock() < Deadline do
\t\t\ttask.wait(0.05)
\t\t\tChild = Current:FindFirstChild(Segments[Index])
\t\tend
\t\tExpect(Child ~= nil, "Path segment exists: " .. Segments[Index])
\t\tCurrent = Child
\tend
\treturn Current
end

local function ValuesEqual(Actual, Expected)
\tif typeof(Actual) == "Vector2" and typeof(Expected) == "Vector2" then
\t\treturn (Actual - Expected).Magnitude < 0.001
\tend
\tif typeof(Actual) == "Vector3" and typeof(Expected) == "Vector3" then
\t\treturn (Actual - Expected).Magnitude < 0.001
\tend
\treturn Actual == Expected
end

local function AssertPathExists(Path: string, TimeoutSeconds: number)
\tResolvePath(Path, TimeoutSeconds)
\tPass("Path exists: " .. Path)
end

local function AssertAttribute(Path: string, Attribute: string, Expected, TimeoutSeconds: number)
\tlocal Target = ResolvePath(Path, TimeoutSeconds)
\tlocal Actual = Target:GetAttribute(Attribute)
\tExpect(ValuesEqual(Actual, Expected), "Attribute matched: " .. Path .. "." .. Attribute)
end

local function AssertProperty(Path: string, Property: string, Expected, TimeoutSeconds: number)
\tlocal Target = ResolvePath(Path, TimeoutSeconds)
\tlocal Ok, Actual = pcall(function()
\t\treturn Target[Property]
\tend)
\tExpect(Ok and ValuesEqual(Actual, Expected), "Property matched: " .. Path .. "." .. Property)
end

local function AssertLogContains(Text: string, TimeoutSeconds: number)
\tlocal Deadline = os.clock() + TimeoutSeconds
\trepeat
\t\tfor _, Message in ipairs(ObservedLogs) do
\t\t\tif string.find(Message, Text, 1, true) then
\t\t\t\tPass("Log contained: " .. Text)
\t\t\t\treturn
\t\t\tend
\t\tend
\t\ttask.wait(0.05)
\tuntil os.clock() >= Deadline
\tFail("Log did not contain: " .. Text)
end

local function FireInputBinding(Path: string, State, TimeoutSeconds: number)
\tlocal Target = ResolvePath(Path, TimeoutSeconds)
\tlocal Binding = Target
\tif Target:IsA("InputAction") then
\t\tBinding = Instance.new("InputBinding")
\t\tBinding.Name = "CodexScriptableBinding"
\t\tBinding.Type = Enum.InputBindingType.Scriptable
\t\tBinding.Parent = Target
\t\ttable.insert(TemporaryInstances, Binding)
\tend
\tExpect(Binding:IsA("InputBinding"), "InputBinding target is available")
\tlocal Ok, ErrorValue = pcall(function()
\t\tBinding:Fire(State)
\tend)
\tlocal Detail = ""
\tif not Ok then
\t\tDetail = ": " .. tostring(ErrorValue)
\tend
\tExpect(Ok, "InputBinding fired" .. Detail)
end

local Success, Result = pcall(function()
${StepLines.join("\n")}
end)

Cleanup()

if not Success then
\twarn(TestPrefix, "ERROR", Result)
\terror(Result, 0)
end

print(TestPrefix, "COMPLETE")
`;
}

function BuildInputScenarioParams(Args) {
  const SmokeTestName = NormalizeInputScenarioSmokeName(Args);
  const Steps = RequireArray(Args.Steps, "Steps", 1, MaxInputScenarioSteps);
  const Assertions = OptionalArray(Args.Assertions, "Assertions", MaxInputScenarioAssertions);
  const TemporaryLocalScript = CompileInputScenarioScript(SmokeTestName, Steps, Assertions);
  if (TemporaryLocalScript.length > MaxInputScenarioSourceLength) {
    throw InvalidToolArguments(
      `Generated TemporaryLocalScript must not exceed ${MaxInputScenarioSourceLength} characters.`,
      { Argument: "Steps" },
    );
  }

  return {
    timeout: OptionalInteger(Args.TimeoutSeconds, "TimeoutSeconds", 1, 90) ?? 10,
    maxLogs: OptionalInteger(Args.MaxLogs, "MaxLogs", 1, 2000) ?? 300,
    includeMessages: true,
    includeWarnings: true,
    includeErrors: true,
    compactResult: true,
    smokeTestName: SmokeTestName,
    localScript: TemporaryLocalScript,
    localScriptLocation:
      OptionalEnum(Args.TemporaryClientLocation, "TemporaryClientLocation", [
        "StarterPlayerScripts",
        "ReplicatedFirst",
      ]) ?? "StarterPlayerScripts",
  };
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
      "RunStudioTests",
      "Run Studio Tests",
      "Run the current Roblox project in a bounded Studio playtest and return captured server and client output.",
      {
        ...SessionProperties,
        TimeoutSeconds: {
          type: "integer",
          minimum: 1,
          maximum: 90,
          default: 10,
          description: "How long Studio should remain in play mode.",
        },
        MaxLogs: {
          type: "integer",
          minimum: 1,
          maximum: 2000,
          default: 300,
          description: "Maximum number of captured log entries to return.",
        },
        IncludeMessages: {
          type: "boolean",
          default: true,
        },
        IncludeWarnings: {
          type: "boolean",
          default: true,
        },
        IncludeErrors: {
          type: "boolean",
          default: true,
        },
        SmokeTestName: {
          type: "string",
          minLength: 1,
          maxLength: 64,
          pattern: "^[A-Za-z0-9_-]+$",
          description: "Unique smoke-test name used in the required [CODEX_SMOKE:<name>] log prefix.",
        },
        TemporaryServerScript: {
          type: "string",
          minLength: 1,
          maxLength: 200000,
          description: "Bounded server smoke code injected as ServerScriptService._TemporaryCODEXScript.",
        },
        TemporaryLocalScript: {
          type: "string",
          minLength: 1,
          maxLength: 200000,
          description: "Bounded client smoke code injected as _TemporaryCODEXScript for this playtest only.",
        },
        TemporaryClientLocation: {
          type: "string",
          enum: ["StarterPlayerScripts", "ReplicatedFirst"],
          default: "StarterPlayerScripts",
          description: "Use ReplicatedFirst only when initialization order is under test.",
        },
      },
      [],
      { readOnlyHint: false },
    ),
    JsonTool(
      "RunInputScenario",
      "Run Input Scenario",
      "Run a bounded Studio playtest with a generated temporary LocalScript that simulates input and checks assertions.",
      {
        ...SessionProperties,
        SmokeTestName: {
          type: "string",
          minLength: 1,
          maxLength: 64,
          pattern: "^[A-Za-z0-9_-]+$",
          description: "Unique smoke-test name used in the required [CODEX_SMOKE:<name>] log prefix.",
        },
        TimeoutSeconds: {
          type: "integer",
          minimum: 1,
          maximum: 90,
          default: 10,
          description: "How long Studio should remain in play mode.",
        },
        MaxLogs: {
          type: "integer",
          minimum: 1,
          maximum: 2000,
          default: 300,
          description: "Maximum number of captured log entries to return.",
        },
        TemporaryClientLocation: {
          type: "string",
          enum: ["StarterPlayerScripts", "ReplicatedFirst"],
          default: "StarterPlayerScripts",
          description: "Use ReplicatedFirst only when initialization order is under test.",
        },
        Steps: {
          type: "array",
          minItems: 1,
          maxItems: MaxInputScenarioSteps,
          description: "Bounded input and wait steps compiled into the temporary LocalScript.",
          items: {
            type: "object",
            properties: {
              Kind: {
                type: "string",
                enum: InputScenarioStepKinds,
              },
              Path: { type: "string" },
              TimeoutSeconds: { type: "number", minimum: 0, maximum: 60 },
              Seconds: { type: "number", minimum: 0, maximum: 60 },
              KeyCode: { type: "string" },
              IsPressed: { type: "boolean" },
              IsRepeatedKey: { type: "boolean" },
              Position: {
                type: "object",
                properties: {
                  X: { type: "number" },
                  Y: { type: "number" },
                },
                required: ["X", "Y"],
                additionalProperties: false,
              },
              Button: {
                type: "string",
                enum: InputScenarioMouseButtons,
              },
              IsDown: { type: "boolean" },
              RepeatCount: { type: "number", minimum: 0, maximum: 10 },
              Text: { type: "string" },
              Wheel: { type: "number" },
              Pan: {
                type: "object",
                properties: {
                  X: { type: "number" },
                  Y: { type: "number" },
                },
                required: ["X", "Y"],
                additionalProperties: false,
              },
              Pinch: { type: "number" },
              State: {},
              Attribute: { type: "string" },
              Property: { type: "string" },
              Equals: {},
            },
            required: ["Kind"],
            additionalProperties: false,
          },
        },
        Assertions: {
          type: "array",
          maxItems: MaxInputScenarioAssertions,
          description: "Optional assertion entries appended after Steps.",
          items: {
            type: "object",
            properties: {
              Kind: {
                type: "string",
                enum: InputScenarioAssertionKinds,
              },
              Path: { type: "string" },
              Attribute: { type: "string" },
              Property: { type: "string" },
              Equals: {},
              Text: { type: "string" },
              TimeoutSeconds: { type: "number", minimum: 0, maximum: 60 },
            },
            required: ["Kind"],
            additionalProperties: false,
          },
        },
      },
      ["SmokeTestName", "Steps"],
      { readOnlyHint: false },
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
  await EnsureBridgeListener();
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
    case "RunStudioTests":
      {
        const SmokeTestName = OptionalBoundedString(Args.SmokeTestName, "SmokeTestName", 64)?.trim();
        const TemporaryServerScript = OptionalBoundedString(
          Args.TemporaryServerScript,
          "TemporaryServerScript",
          200_000,
        );
        const TemporaryLocalScript = OptionalBoundedString(
          Args.TemporaryLocalScript,
          "TemporaryLocalScript",
          200_000,
        );
        const TemporaryClientLocation =
          OptionalEnum(Args.TemporaryClientLocation, "TemporaryClientLocation", [
            "StarterPlayerScripts",
            "ReplicatedFirst",
          ]) ?? "StarterPlayerScripts";

        if (SmokeTestName !== undefined && !/^[A-Za-z0-9_-]+$/.test(SmokeTestName)) {
          throw InvalidToolArguments(
            "SmokeTestName may contain only letters, numbers, underscores, and hyphens.",
            { Argument: "SmokeTestName" },
          );
        }
        if ((TemporaryServerScript !== undefined || TemporaryLocalScript !== undefined) && !SmokeTestName) {
          throw InvalidToolArguments(
            "SmokeTestName is required when a temporary smoke script is provided.",
            { Argument: "SmokeTestName" },
          );
        }
        if (SmokeTestName && TemporaryServerScript === undefined && TemporaryLocalScript === undefined) {
          throw InvalidToolArguments(
            "TemporaryServerScript or TemporaryLocalScript is required when SmokeTestName is provided.",
            { Argument: "SmokeTestName" },
          );
        }

        return {
          timeout: OptionalInteger(Args.TimeoutSeconds, "TimeoutSeconds", 1, 90) ?? 10,
          maxLogs: OptionalInteger(Args.MaxLogs, "MaxLogs", 1, 2000) ?? 300,
          includeMessages: SmokeTestName
            ? true
            : (OptionalBoolean(Args.IncludeMessages, "IncludeMessages") ?? true),
          includeWarnings: SmokeTestName
            ? true
            : (OptionalBoolean(Args.IncludeWarnings, "IncludeWarnings") ?? true),
          includeErrors: SmokeTestName ? true : (OptionalBoolean(Args.IncludeErrors, "IncludeErrors") ?? true),
          compactResult: true,
          smokeTestName: SmokeTestName,
          serverScript: TemporaryServerScript,
          localScript: TemporaryLocalScript,
          localScriptLocation: TemporaryClientLocation,
        };
      }
    case "RunInputScenario":
      return BuildInputScenarioParams(Args);
    default:
      throw new McpToolError(
        ErrorCategory.InternalMcpFailure,
        `Unsupported Studio tool normalization: ${ToolName}`,
      );
  }
}

function NormalizeStudioTestResult(Value, Arguments) {
  const Result = typeof Value === "object" && Value !== null ? Value : {};
  const MaxLogs = Arguments.MaxLogs ?? 300;
  const IsTemporarySmokeTest = typeof Arguments.SmokeTestName === "string" && Arguments.SmokeTestName !== "";
  const IncludeMessages = IsTemporarySmokeTest || (Arguments.IncludeMessages ?? true);
  const IncludeWarnings = IsTemporarySmokeTest || (Arguments.IncludeWarnings ?? true);
  const IncludeErrors = IsTemporarySmokeTest || (Arguments.IncludeErrors ?? true);
  const RawLogs = Array.isArray(Result.logs) ? Result.logs : Array.isArray(Result.Logs) ? Result.Logs : [];
  const RawErrors = Array.isArray(Result.errors) ? Result.errors : Array.isArray(Result.Errors) ? Result.Errors : [];
  const Logs = [];
  const Errors = [];
  const ErrorLogEntries = [];
  let LogErrorCount = 0;
  let WarningCount = 0;
  let MessageCount = 0;
  let Truncated = Result.truncated === true || Result.Truncated === true;

  function ClipMessage(ValueToClip) {
    const Message = String(ValueToClip ?? "");
    if (Message.length <= 8000) {
      return Message;
    }
    Truncated = true;
    return `${Message.slice(0, 8000)}... [truncated]`;
  }

  function ParseError(Message, Context) {
    const Text = String(Message);
    const Patterns = [
      /^\s*\[string\s+["'](.+?)["']\]:(\d+):/,
      /\bScript\s+["'](.+?)["']\s*,?\s*[Ll]ine\s+(\d+)\b/,
      /^\s*(.+?)\s*\([Ll]ine\s+(\d+)\)\s*:?/,
      /^\s*(.+?)\s*,\s*[Ll]ine\s+(\d+)\b/,
      /^\s*(.+?):(\d+):/,
    ];
    let Match;
    for (const Line of Text.split(/\r?\n/)) {
      Match = Patterns.map((Pattern) => Line.match(Pattern)).find(Boolean);
      if (Match) {
        break;
      }
    }
    return CompactObject({
      ScriptPath: Match?.[1]?.trim() || "Unknown",
      LineNumber: Match ? Number(Match[2]) : undefined,
      Message: Text,
      Context,
      Provenance: "message_fallback",
    });
  }

  function NormalizeStructuredError(RawError) {
    if (typeof RawError !== "object" || RawError === null) {
      return ParseError(ClipMessage(RawError));
    }

    const StudioPath = RawError.studioPath ?? RawError.StudioPath;
    const ScriptUniqueId = RawError.scriptUniqueId ?? RawError.ScriptUniqueId;
    const ScriptPath = RawError.scriptPath ?? RawError.ScriptPath ?? StudioPath;
    return CompactObject({
      ScriptPath: ScriptPath || "Unknown",
      StudioPath,
      ScriptUniqueId,
      LineNumber: RawError.lineNumber ?? RawError.LineNumber,
      Message: ClipMessage(RawError.message ?? RawError.Message),
      StackTrace: ClipMessage(RawError.stackTrace ?? RawError.StackTrace ?? ""),
      Context: RawError.context ?? RawError.Context,
      Provenance: StudioPath || ScriptUniqueId ? "studio" : "message_fallback",
    });
  }

  for (const RawEntry of RawLogs) {
    if (typeof RawEntry !== "object" || RawEntry === null) {
      continue;
    }

    const Level = String(RawEntry.type ?? RawEntry.Type ?? RawEntry.level ?? RawEntry.Level ?? "unknown").toLowerCase();
    const RawContext = RawEntry.context ?? RawEntry.Context;
    const Context = typeof RawContext === "string" ? RawContext : undefined;
    const Message = ClipMessage(RawEntry.message ?? RawEntry.Message);

    if (Level === "error") {
      LogErrorCount += 1;
      ErrorLogEntries.push({ Message, Context });
    } else if (Level === "warn" || Level === "warning") {
      WarningCount += 1;
    } else {
      MessageCount += 1;
    }

    const ShouldInclude =
      (Level === "error" && IncludeErrors) ||
      ((Level === "warn" || Level === "warning") && IncludeWarnings) ||
      (Level !== "error" && Level !== "warn" && Level !== "warning" && IncludeMessages);
    if (!ShouldInclude) {
      continue;
    }
    if (Logs.length >= MaxLogs) {
      Truncated = true;
      continue;
    }

    Logs.push(CompactObject({ Level: Level === "warning" ? "warn" : Level, Message, Context }));
  }

  if (IncludeErrors) {
    for (const RawError of RawErrors.slice(0, MaxLogs)) {
      Errors.push(NormalizeStructuredError(RawError));
    }
    if (Errors.length === 0) {
      for (const ErrorEntry of ErrorLogEntries.slice(0, MaxLogs)) {
        Errors.push(ParseError(ErrorEntry.Message, ErrorEntry.Context));
      }
    }
    Truncated ||= RawErrors.length > MaxLogs;
  }

  const Status = String(Result.status ?? Result.Status ?? "failed");
  const DurationMs = Number(Result.duration ?? Result.Duration ?? 0);
  const ErrorCount = Math.max(LogErrorCount, RawErrors.length);
  const RawTemporarySmokeTest = Result.temporarySmokeTest ?? Result.TemporarySmokeTest;
  let TemporarySmokeTest;

  if (IsTemporarySmokeTest || (typeof RawTemporarySmokeTest === "object" && RawTemporarySmokeTest !== null)) {
    const Name = Arguments.SmokeTestName ?? RawTemporarySmokeTest?.name ?? RawTemporarySmokeTest?.Name;
    const Prefix = `[CODEX_SMOKE:${Name}]`;
    const SmokeLogs = RawLogs.map((Entry) => ({
      Level: String(Entry?.type ?? Entry?.Type ?? Entry?.level ?? Entry?.Level ?? "unknown").toLowerCase(),
      Message: String(Entry?.message ?? Entry?.Message ?? ""),
    })).filter((Entry) => Entry.Message.includes(Prefix));
    const Completed = SmokeLogs.some((Entry) => /\bCOMPLETE\b/.test(Entry.Message));
    const PassedAssertions = SmokeLogs.filter((Entry) => /\bPASS\b/.test(Entry.Message)).length;
    const FailedAssertions = SmokeLogs.filter((Entry) => /\b(?:FAIL|ERROR)\b/.test(Entry.Message)).length;
    const CleanupVerified =
      RawTemporarySmokeTest?.cleanupVerified ?? RawTemporarySmokeTest?.CleanupVerified ?? false;

    TemporarySmokeTest = {
      Name,
      Prefix,
      Completed,
      PassedAssertions,
      FailedAssertions,
      CleanupVerified,
      Passed: Completed && FailedAssertions === 0 && CleanupVerified,
      ScriptName: RawTemporarySmokeTest?.scriptName ?? RawTemporarySmokeTest?.ScriptName ?? "_TemporaryCODEXScript",
      ServerInjected: RawTemporarySmokeTest?.serverInjected ?? RawTemporarySmokeTest?.ServerInjected ?? false,
      ClientInjected: RawTemporarySmokeTest?.clientInjected ?? RawTemporarySmokeTest?.ClientInjected ?? false,
      ClientLocation: RawTemporarySmokeTest?.clientLocation ?? RawTemporarySmokeTest?.ClientLocation,
    };
  }

  return CompactObject({
    Status,
    Summary: {
      Passed: Status === "completed" && ErrorCount === 0 && (TemporarySmokeTest?.Passed ?? true),
      ErrorCount,
      WarningCount,
      MessageCount,
      DurationMs: Number.isFinite(DurationMs) ? Math.round(DurationMs) : 0,
    },
    Logs,
    Errors: IncludeErrors ? Errors.slice(0, MaxLogs) : [],
    TemporarySmokeTest,
    Truncated,
    Error: Result.error ?? Result.Error,
  });
}

function FormatToolResult(ToolName, Result, Arguments) {
  return ToolName === "RunStudioTests" || ToolName === "RunInputScenario"
    ? NormalizeStudioTestResult(Result, Arguments)
    : Result;
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

async function PollStudioResult(RequestId, Headers, DefaultTimeoutMs = 30000) {
  const TimeoutMs = GetEnvNumber("CODEX_BRIDGE_RESULT_TIMEOUT_MS", DefaultTimeoutMs);
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
      let Response;
      try {
        Response = await HttpJson("GET", PathValue, undefined, Headers);
      } catch (ErrorValue) {
        throw new McpToolError(
          ErrorCategory.BridgeUnavailable,
          `CodexBridge listener did not respond while polling request ${RequestId}.`,
          true,
          {
            RequestId,
            BridgeUrl: BridgeBaseUrl(),
            Cause: ErrorValue instanceof Error ? ErrorValue.message : String(ErrorValue),
          },
        );
      }
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

  throw new McpToolError(
    ErrorCategory.StudioRequestTimedOut,
    `Timed out waiting ${TimeoutMs}ms for Studio request ${RequestId}.`,
    true,
    { RequestId, TimeoutMs, LastStatus },
  );
}

function RequireSuccessfulStudioResult(Result, ToolName, ActionName, RequestId) {
  if (typeof Result !== "object" || Result === null) {
    throw new McpToolError(
      ErrorCategory.InternalMcpFailure,
      `Studio returned an invalid result for ${ToolName}.`,
      false,
      { ToolName, ActionName, RequestId },
    );
  }

  const Status = String(Result.status ?? Result.Status ?? "");
  if (Status !== "failed") {
    return Result;
  }

  const Category = Result.errorCategory ?? Result.ErrorCategory;
  const Message = Result.error ?? Result.Error ?? `Studio action ${ActionName} failed.`;
  if (Category === ErrorCategory.StudioRequestTimedOut) {
    throw new McpToolError(ErrorCategory.StudioRequestTimedOut, Message, true, {
      ToolName,
      ActionName,
      RequestId,
    });
  }

  throw new McpToolError(
    ErrorCategory.StudioActionFailed,
    Message,
    Result.retryable ?? Result.Retryable ?? false,
    CompactObject({
      ToolName,
      ActionName,
      RequestId,
      StudioStackTrace: Result.stackTrace ?? Result.StackTrace,
    }),
  );
}

async function CallStudioAction(ToolName, Arguments) {
  const Args = RequireObject(Arguments ?? {}, "arguments");
  const ListenerReady = await EnsureBridgeListener();
  if (!ListenerReady) {
    throw new McpToolError(
      ErrorCategory.BridgeUnavailable,
      `CodexBridge listener is unavailable at ${BridgeBaseUrl()}.`,
      true,
      { BridgeUrl: BridgeBaseUrl() },
    );
  }
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

  let Response;
  try {
    Response = await HttpJson("POST", RequestPath, Body, Headers);
  } catch (ErrorValue) {
    throw new McpToolError(
      ErrorCategory.BridgeUnavailable,
      `CodexBridge listener did not respond at ${BridgeBaseUrl()}.`,
      true,
      {
        BridgeUrl: BridgeBaseUrl(),
        Cause: ErrorValue instanceof Error ? ErrorValue.message : String(ErrorValue),
      },
    );
  }
  if (!Response.Ok) {
    const ResponseCategory = Response.Json?.ErrorCategory ?? Response.Json?.errorCategory;
    const Message = Response.Json?.Error ?? Response.Json?.error ?? Response.Json?.RawBody ?? Response.Text;
    if (Response.Status === 409 || ResponseCategory === ErrorCategory.StudioDisconnected) {
      throw new McpToolError(
        ErrorCategory.StudioDisconnected,
        Message || "Roblox Studio is not connected to CodexBridge.",
        true,
        { ToolName, ActionName, RequestId, SessionId: SessionId || null },
      );
    }

    throw new McpToolError(
      ErrorCategory.BridgeUnavailable,
      Message || `CodexBridge listener returned HTTP ${Response.Status}.`,
      true,
      { ToolName, ActionName, RequestId, BridgeStatus: Response.Status },
    );
  }

  const ImmediateResult = ExtractImmediateResult(Response.Json);
  if (ImmediateResult !== undefined) {
    const Result = RequireSuccessfulStudioResult(ImmediateResult, ToolName, ActionName, RequestId);
    return TextResult(FormatToolResult(ToolName, Result, Args));
  }

  const QueuedRequestId = ExtractRequestId(Response.Json, RequestId);
  const DefaultTimeoutMs =
    ToolName === "RunStudioTests" || ToolName === "RunInputScenario" ? (Params.timeout + 60) * 1000 : 30000;
  const PolledResult = await PollStudioResult(QueuedRequestId, Headers, DefaultTimeoutMs);
  const Result = RequireSuccessfulStudioResult(PolledResult, ToolName, ActionName, QueuedRequestId);
  return TextResult(FormatToolResult(ToolName, Result, Args));
}

async function HandleToolCall(Id, Params) {
  const Name = RequireString(Params?.name, "name");
  const Arguments = Params?.arguments ?? {};

  if (Name === "GetStudioSession") {
    SendResult(Id, await GetStudioSession(Arguments));
    return;
  }

  if (!Object.hasOwn(StudioToolMap, Name)) {
    throw InvalidToolArguments(`Unknown tool: ${Name}`, { ToolName: Name });
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
      const ToolError = NormalizeToolError(ErrorValue);
      SendError(Id, ToolError.Code, ToolError.message, {
        Category: ToolError.Category,
        Retryable: ToolError.Retryable,
        ...ToolError.Data,
      });
    }
    return;
  }

  SendError(Id, JsonRpcError.MethodNotFound, `Method not found: ${Method}`);
}

await EnsureBridgeListener();

const Reader = readline.createInterface({
  input: process.stdin,
  crlfDelay: Infinity,
});

Reader.once("close", StopOwnedListener);
process.once("exit", StopOwnedListener);
process.once("SIGINT", () => {
  StopOwnedListener();
  process.exit(130);
});
process.once("SIGTERM", () => {
  StopOwnedListener();
  process.exit(143);
});

Reader.on("line", async (Line) => {
  if (Line.trim() === "") {
    return;
  }

  let Message;
  try {
    Message = JSON.parse(Line);
  } catch (ErrorValue) {
    SendError(null, JsonRpcError.InvalidParams, `Invalid JSON: ${String(ErrorValue)}`, {
      Category: ErrorCategory.InvalidToolArguments,
      Retryable: false,
    });
    return;
  }

  try {
    await HandleRequest(Message);
  } catch (ErrorValue) {
    const InternalError = NormalizeToolError(ErrorValue);
    SendError(
      Message.id ?? null,
      JsonRpcError.InternalError,
      InternalError.message,
      {
        Category: ErrorCategory.InternalMcpFailure,
        Retryable: false,
      },
    );
  }
});
