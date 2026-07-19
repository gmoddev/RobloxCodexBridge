import Assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createServer as CreateHttpServer } from "node:http";
import { createServer as CreateNetServer } from "node:net";
import Test from "node:test";
import { fileURLToPath } from "node:url";

const McpServerPath = fileURLToPath(new URL("./Server.mjs", import.meta.url));
const ListenerServerPath = fileURLToPath(new URL("../../bridge/Server.mjs", import.meta.url));

function GetFreePort() {
  return new Promise((Resolve, Reject) => {
    const Server = CreateNetServer();
    Server.once("error", Reject);
    Server.listen(0, "127.0.0.1", () => {
      const Address = Server.address();
      const Port = typeof Address === "object" && Address ? Address.port : undefined;
      Server.close((ErrorValue) => {
        if (ErrorValue) {
          Reject(ErrorValue);
          return;
        }
        Resolve(Port);
      });
    });
  });
}

function Delay(DurationMs) {
  return new Promise((Resolve) => setTimeout(Resolve, DurationMs));
}

async function IsHealthy(BaseUrl) {
  try {
    const Response = await fetch(`${BaseUrl}/health`);
    return Response.ok;
  } catch {
    return false;
  }
}

async function WaitForHealth(BaseUrl, Expected, TimeoutMs = 5_000) {
  const Deadline = Date.now() + TimeoutMs;
  while (Date.now() < Deadline) {
    if ((await IsHealthy(BaseUrl)) === Expected) {
      return;
    }
    await Delay(50);
  }
  Assert.fail(`Listener health at ${BaseUrl} did not become ${Expected}.`);
}

function SpawnMcpServer(BaseUrl, ExtraEnvironment = {}) {
  return spawn(process.execPath, [McpServerPath], {
    env: {
      ...process.env,
      CODEX_BRIDGE_AUTOSTART: "true",
      CODEX_BRIDGE_STARTUP_TIMEOUT_MS: "3000",
      CODEX_BRIDGE_TOKEN: "",
      CODEX_BRIDGE_URL: BaseUrl,
      ...ExtraEnvironment,
    },
    stdio: ["pipe", "pipe", "ignore"],
    windowsHide: true,
  });
}

function SpawnListener(Port) {
  return spawn(process.execPath, [ListenerServerPath], {
    env: {
      ...process.env,
      CODEX_BRIDGE_HOST: "127.0.0.1",
      CODEX_BRIDGE_PORT: String(Port),
      CODEX_BRIDGE_TOKEN: "",
    },
    stdio: "ignore",
    windowsHide: true,
  });
}

function ReadLine(Stream, TimeoutMs = 5_000) {
  return new Promise((Resolve, Reject) => {
    let PendingText = "";
    const Timeout = setTimeout(() => Finish(new Error("Timed out waiting for MCP output.")), TimeoutMs);

    function Finish(ErrorValue, Line) {
      clearTimeout(Timeout);
      Stream.off("data", OnData);
      Stream.off("error", OnError);
      if (ErrorValue) {
        Reject(ErrorValue);
      } else {
        Resolve(Line);
      }
    }

    function OnData(Chunk) {
      PendingText += Chunk.toString("utf8");
      const NewlineIndex = PendingText.indexOf("\n");
      if (NewlineIndex >= 0) {
        Finish(undefined, PendingText.slice(0, NewlineIndex));
      }
    }

    function OnError(ErrorValue) {
      Finish(ErrorValue);
    }

    Stream.on("data", OnData);
    Stream.once("error", OnError);
  });
}

async function InitializeMcp(McpProcess) {
  const ResponseLine = ReadLine(McpProcess.stdout);
  McpProcess.stdin.write(
    `${JSON.stringify({ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-11-25" } })}\n`,
  );
  return JSON.parse(await ResponseLine);
}

async function CallTool(McpProcess, Name, Arguments = {}, Id = 2) {
  const ResponseLine = ReadLine(McpProcess.stdout);
  McpProcess.stdin.write(
    `${JSON.stringify({ jsonrpc: "2.0", id: Id, method: "tools/call", params: { name: Name, arguments: Arguments } })}\n`,
  );
  return JSON.parse(await ResponseLine);
}

function StartFakeBridge(Port, HandleRequest) {
  const Server = CreateHttpServer(async (Request, Response) => {
    if (Request.method === "GET" && Request.url === "/health") {
      const Body = JSON.stringify({ Status: "ok", Name: "CodexBridge" });
      Response.writeHead(200, { "Content-Type": "application/json" });
      Response.end(Body);
      return;
    }

    const Chunks = [];
    for await (const Chunk of Request) {
      Chunks.push(Chunk);
    }
    const RawBody = Buffer.concat(Chunks).toString("utf8");
    const ParsedBody = RawBody === "" ? undefined : JSON.parse(RawBody);
    const Result = await HandleRequest(Request, ParsedBody);
    const Body = Result.Body === undefined ? "" : JSON.stringify(Result.Body);
    Response.writeHead(Result.StatusCode, { "Content-Type": "application/json" });
    Response.end(Body);
  });

  return new Promise((Resolve, Reject) => {
    Server.once("error", Reject);
    Server.listen(Port, "127.0.0.1", () => Resolve(Server));
  });
}

function StopServer(Server) {
  return new Promise((Resolve, Reject) => {
    Server.close((ErrorValue) => {
      if (ErrorValue) {
        Reject(ErrorValue);
      } else {
        Resolve();
      }
    });
  });
}

function WaitForExit(ChildProcess, TimeoutMs = 5_000) {
  if (ChildProcess.exitCode !== null) {
    return Promise.resolve(ChildProcess.exitCode);
  }

  return new Promise((Resolve, Reject) => {
    const Timeout = setTimeout(() => {
      Reject(new Error("Timed out waiting for child process to exit."));
    }, TimeoutMs);
    ChildProcess.once("exit", (Code) => {
      clearTimeout(Timeout);
      Resolve(Code);
    });
  });
}

async function StopProcess(ChildProcess) {
  if (ChildProcess.exitCode !== null) {
    return;
  }
  ChildProcess.kill();
  await WaitForExit(ChildProcess);
}

Test("MCP autostarts and owns a local listener", { timeout: 15_000 }, async () => {
  const Port = await GetFreePort();
  const BaseUrl = `http://127.0.0.1:${Port}`;
  const McpProcess = SpawnMcpServer(BaseUrl);

  try {
    await WaitForHealth(BaseUrl, true);
    const InitializeResponse = await InitializeMcp(McpProcess);
    Assert.equal(InitializeResponse.result.serverInfo.name, "CodexBridge Studio");

    McpProcess.stdin.end();
    Assert.equal(await WaitForExit(McpProcess), 0);
    await WaitForHealth(BaseUrl, false);
  } finally {
    await StopProcess(McpProcess);
  }
});

Test("MCP reuses and does not stop an existing listener", { timeout: 15_000 }, async () => {
  const Port = await GetFreePort();
  const BaseUrl = `http://127.0.0.1:${Port}`;
  const ListenerProcess = SpawnListener(Port);
  let McpProcess;

  try {
    await WaitForHealth(BaseUrl, true);
    McpProcess = SpawnMcpServer(BaseUrl);
    const InitializeResponse = await InitializeMcp(McpProcess);
    Assert.equal(InitializeResponse.result.serverInfo.name, "CodexBridge Studio");

    McpProcess.stdin.end();
    Assert.equal(await WaitForExit(McpProcess), 0);
    Assert.equal(await IsHealthy(BaseUrl), true);
  } finally {
    if (McpProcess) {
      await StopProcess(McpProcess);
    }
    await StopProcess(ListenerProcess);
  }
});

Test("MCP distinguishes invalid arguments and disconnected Studio", { timeout: 15_000 }, async () => {
  const Port = await GetFreePort();
  const BaseUrl = `http://127.0.0.1:${Port}`;
  const McpProcess = SpawnMcpServer(BaseUrl);

  try {
    await WaitForHealth(BaseUrl, true);
    await InitializeMcp(McpProcess);

    const InvalidArgumentsResponse = await CallTool(McpProcess, "ReadScript", {}, 2);
    Assert.equal(InvalidArgumentsResponse.error.code, -32602);
    Assert.equal(InvalidArgumentsResponse.error.data.Category, "invalid_tool_arguments");
    Assert.equal(InvalidArgumentsResponse.error.data.Retryable, false);

    const DisconnectedResponse = await CallTool(McpProcess, "ReadScript", { UniqueId: "script-1" }, 3);
    Assert.equal(DisconnectedResponse.error.code, -32002);
    Assert.equal(DisconnectedResponse.error.data.Category, "studio_disconnected");
    Assert.equal(DisconnectedResponse.error.data.Retryable, true);
  } finally {
    await StopProcess(McpProcess);
  }
});

Test("MCP reports an unavailable listener separately", { timeout: 15_000 }, async () => {
  const Port = await GetFreePort();
  const BaseUrl = `http://127.0.0.1:${Port}`;
  const McpProcess = SpawnMcpServer(BaseUrl, { CODEX_BRIDGE_AUTOSTART: "false" });

  try {
    await InitializeMcp(McpProcess);
    const Response = await CallTool(McpProcess, "ReadScript", { UniqueId: "script-1" });
    Assert.equal(Response.error.code, -32001);
    Assert.equal(Response.error.data.Category, "bridge_unavailable");
    Assert.equal(Response.error.data.Retryable, true);
  } finally {
    await StopProcess(McpProcess);
  }
});

Test("MCP distinguishes Studio request timeout and action failure", { timeout: 15_000 }, async () => {
  const TimeoutPort = await GetFreePort();
  const TimeoutBaseUrl = `http://127.0.0.1:${TimeoutPort}`;
  const TimeoutBridge = await StartFakeBridge(TimeoutPort, (Request) => {
    if (Request.method === "POST") {
      return { StatusCode: 202, Body: { Status: "queued", RequestId: "timeout-request" } };
    }
    return { StatusCode: 202, Body: { Status: "pending", RequestId: "timeout-request" } };
  });
  const TimeoutMcp = SpawnMcpServer(TimeoutBaseUrl, { CODEX_BRIDGE_RESULT_TIMEOUT_MS: "100" });

  try {
    await InitializeMcp(TimeoutMcp);
    const TimeoutResponse = await CallTool(TimeoutMcp, "ReadScript", { UniqueId: "script-1" });
    Assert.equal(TimeoutResponse.error.code, -32003);
    Assert.equal(TimeoutResponse.error.data.Category, "studio_request_timed_out");
    Assert.equal(TimeoutResponse.error.data.Retryable, true);
  } finally {
    await StopProcess(TimeoutMcp);
    await StopServer(TimeoutBridge);
  }

  const FailurePort = await GetFreePort();
  const FailureBaseUrl = `http://127.0.0.1:${FailurePort}`;
  const FailureBridge = await StartFakeBridge(FailurePort, () => ({
    StatusCode: 200,
    Body: {
      result: {
        status: "failed",
        errorCategory: "studio_action_failed",
        error: "The Studio action rejected the request.",
      },
    },
  }));
  const FailureMcp = SpawnMcpServer(FailureBaseUrl);

  try {
    await InitializeMcp(FailureMcp);
    const FailureResponse = await CallTool(FailureMcp, "ReadScript", { UniqueId: "script-1" });
    Assert.equal(FailureResponse.error.code, -32004);
    Assert.equal(FailureResponse.error.data.Category, "studio_action_failed");
    Assert.equal(FailureResponse.error.data.Retryable, false);
  } finally {
    await StopProcess(FailureMcp);
    await StopServer(FailureBridge);
  }
});

Test("MCP reports malformed Studio results as internal failures", { timeout: 15_000 }, async () => {
  const Port = await GetFreePort();
  const BaseUrl = `http://127.0.0.1:${Port}`;
  const Bridge = await StartFakeBridge(Port, () => ({
    StatusCode: 200,
    Body: { result: "not-a-result-object" },
  }));
  const McpProcess = SpawnMcpServer(BaseUrl);

  try {
    await InitializeMcp(McpProcess);
    const Response = await CallTool(McpProcess, "ReadScript", { UniqueId: "script-1" });
    Assert.equal(Response.error.code, -32603);
    Assert.equal(Response.error.data.Category, "internal_mcp_failure");
    Assert.equal(Response.error.data.Retryable, false);
  } finally {
    await StopProcess(McpProcess);
    await StopServer(Bridge);
  }
});

Test("MCP preserves Studio error provenance and summarizes temporary smoke markers", { timeout: 15_000 }, async () => {
  const Port = await GetFreePort();
  const BaseUrl = `http://127.0.0.1:${Port}`;
  const Bridge = await StartFakeBridge(Port, () => ({
    StatusCode: 200,
    Body: {
      result: {
        status: "completed",
        duration: 42,
        logs: [
          { type: "print", message: "[CODEX_SMOKE:InventoryCutlass] PASS item granted", context: "server" },
          { type: "print", message: "[CODEX_SMOKE:InventoryCutlass] COMPLETE", context: "server" },
          {
            type: "error",
            message: "A script with spaces & punctuation failed",
            context: "server",
          },
        ],
        errors: [
          {
            scriptPath: "ServerScriptService.Combat Scripts.Cutlass: Runtime",
            studioPath: "ServerScriptService.Combat Scripts.Cutlass: Runtime",
            scriptUniqueId: "cutlass-script-id",
            lineNumber: 27,
            message: "A script with spaces & punctuation failed",
            stackTrace: "ServerScriptService.Combat Scripts.Cutlass: Runtime:27",
            context: "server",
          },
        ],
        temporarySmokeTest: {
          name: "InventoryCutlass",
          scriptName: "_TemporaryCODEXScript",
          serverInjected: true,
          clientInjected: false,
          cleanupVerified: true,
        },
      },
    },
  }));
  const McpProcess = SpawnMcpServer(BaseUrl);

  try {
    await InitializeMcp(McpProcess);
    const Response = await CallTool(McpProcess, "RunStudioTests", {
      SmokeTestName: "InventoryCutlass",
      TemporaryServerScript: "print('[CODEX_SMOKE:InventoryCutlass] COMPLETE')",
    });
    const Result = JSON.parse(Response.result.content[0].text);

    Assert.equal(Result.Errors[0].StudioPath, "ServerScriptService.Combat Scripts.Cutlass: Runtime");
    Assert.equal(Result.Errors[0].ScriptUniqueId, "cutlass-script-id");
    Assert.equal(Result.Errors[0].LineNumber, 27);
    Assert.equal(Result.Errors[0].Provenance, "studio");
    Assert.equal(Result.TemporarySmokeTest.Completed, true);
    Assert.equal(Result.TemporarySmokeTest.PassedAssertions, 1);
    Assert.equal(Result.TemporarySmokeTest.FailedAssertions, 0);
    Assert.equal(Result.TemporarySmokeTest.CleanupVerified, true);
    Assert.equal(Result.TemporarySmokeTest.Passed, true);
  } finally {
    await StopProcess(McpProcess);
    await StopServer(Bridge);
  }
});

Test("MCP fallback parser preserves paths with spaces and punctuation", { timeout: 15_000 }, async () => {
  const Port = await GetFreePort();
  const BaseUrl = `http://127.0.0.1:${Port}`;
  const Bridge = await StartFakeBridge(Port, () => ({
    StatusCode: 200,
    Body: {
      result: {
        status: "completed",
        logs: [
          {
            type: "error",
            message: "ServerScriptService.Combat Scripts.Cutlass: Runtime:27: fallback failure",
            context: "server",
          },
        ],
      },
    },
  }));
  const McpProcess = SpawnMcpServer(BaseUrl);

  try {
    await InitializeMcp(McpProcess);
    const Response = await CallTool(McpProcess, "RunStudioTests");
    const Result = JSON.parse(Response.result.content[0].text);
    Assert.equal(Result.Errors[0].ScriptPath, "ServerScriptService.Combat Scripts.Cutlass: Runtime");
    Assert.equal(Result.Errors[0].LineNumber, 27);
    Assert.equal(Result.Errors[0].Provenance, "message_fallback");
  } finally {
    await StopProcess(McpProcess);
    await StopServer(Bridge);
  }
});

Test("MCP fallback parser recognizes alternate Roblox stack formats", { timeout: 15_000 }, async () => {
  const Port = await GetFreePort();
  const BaseUrl = `http://127.0.0.1:${Port}`;
  const Bridge = await StartFakeBridge(Port, () => ({
    StatusCode: 200,
    Body: {
      result: {
        status: "completed",
        logs: [],
        errors: [
          "Runtime failure\nScript 'ServerScriptService.Inventory Systems.Loadout: v2', Line 17",
          '[string "ReplicatedStorage.Packages.Parser (legacy)"]:29: bad token',
          "StarterPlayer.StarterPlayerScripts.Client Boot (Line 8): unavailable",
        ],
      },
    },
  }));
  const McpProcess = SpawnMcpServer(BaseUrl);

  try {
    await InitializeMcp(McpProcess);
    const Response = await CallTool(McpProcess, "RunStudioTests");
    const Result = JSON.parse(Response.result.content[0].text);
    Assert.deepEqual(
      Result.Errors.map((ErrorValue) => [ErrorValue.ScriptPath, ErrorValue.LineNumber]),
      [
        ["ServerScriptService.Inventory Systems.Loadout: v2", 17],
        ["ReplicatedStorage.Packages.Parser (legacy)", 29],
        ["StarterPlayer.StarterPlayerScripts.Client Boot", 8],
      ],
    );
  } finally {
    await StopProcess(McpProcess);
    await StopServer(Bridge);
  }
});
