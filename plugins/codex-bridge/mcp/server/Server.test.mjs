import Assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createServer } from "node:net";
import Test from "node:test";
import { fileURLToPath } from "node:url";

const McpServerPath = fileURLToPath(new URL("./Server.mjs", import.meta.url));
const ListenerServerPath = fileURLToPath(new URL("../../bridge/Server.mjs", import.meta.url));

function GetFreePort() {
  return new Promise((Resolve, Reject) => {
    const Server = createServer();
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

function SpawnMcpServer(BaseUrl) {
  return spawn(process.execPath, [McpServerPath], {
    env: {
      ...process.env,
      CODEX_BRIDGE_AUTOSTART: "true",
      CODEX_BRIDGE_STARTUP_TIMEOUT_MS: "3000",
      CODEX_BRIDGE_TOKEN: "",
      CODEX_BRIDGE_URL: BaseUrl,
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
