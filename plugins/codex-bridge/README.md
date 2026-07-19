# CodexBridge Plugin

This is a Codex plugin, not a Roblox Studio plugin. It bridges Codex to a running Roblox Studio plugin through an inspect-and-test MCP server and a local CodexBridge listener.

CodexBridge is shared as an experimental local developer tool derived from the lemonade.gg plugin codebase. The goal is to use this as a practical starting point for Codex-to-Studio integration while a separate standalone plugin is developed over time.

## Setup

Full setup docs live in the repository root at `docs/CodexBridgeSetupGuide.md`.

The MCP server starts the local CodexBridge listener automatically and reuses a compatible listener if one is already running. A separate terminal is not required.

For listener-only development or diagnostics, it can still be started manually from the plugin root:

```powershell
node bridge/Server.mjs
```

Then configure the MCP server to target it:

```powershell
$env:CODEX_BRIDGE_URL = "http://127.0.0.1:17315"
```

Optional environment variables:

- `CODEX_BRIDGE_URL`: defaults to `http://127.0.0.1:17315`.
- `CODEX_BRIDGE_REQUEST_PATH`: defaults to `v1/studio/request`.
- `CODEX_BRIDGE_RESULT_TEMPLATE`: defaults to `v1/studio/result/{RequestId}`.
- `CODEX_BRIDGE_RESULT_TIMEOUT_MS`: optional global result timeout override. Read tools default to `30000`; `RunStudioTests` defaults to its play duration plus 60 seconds.
- `CODEX_BRIDGE_RESULT_POLL_MS`: defaults to `1000`.
- `CODEX_BRIDGE_HTTP_TIMEOUT_MS`: defaults to `20000`.
- `CODEX_BRIDGE_PORT`: local listener port, defaults to `17315`.
- `CODEX_BRIDGE_HOST`: local listener host, defaults to `127.0.0.1`.
- `CODEX_BRIDGE_TOKEN`: optional loopback auth token. If set on the listener, set it for the MCP server too.
- `CODEX_BRIDGE_AUTOSTART`: defaults to `true`; set to `false` to manage the listener manually.
- `CODEX_BRIDGE_STARTUP_TIMEOUT_MS`: defaults to `5000`.

## Local Listener

The listener is implemented at `bridge/Server.mjs` and is supervised by `mcp/server/Server.mjs` during normal use.

Implemented endpoints:

- `GET /health`
- `GET /v1/session`
- `POST /v1/studio/register`
- `POST /v1/studio/heartbeat`
- `POST /v1/studio/request`
- `GET /v1/studio/poll`
- `POST /v1/studio/result`
- `GET /v1/studio/result/{RequestId}`
- `GET /v1/studio/result?requestId={RequestId}`

The streaming endpoint is reserved for the next phase:

- `GET /v1/studio/stream`

## Tools

Read-only MCP tools:

- `GetStudioSession`
- `ListInstances`
- `GlobInstances`
- `ReadInstance`
- `ReadScript`
- `ReadGuiTree`
- `SerializeInstance`
- `CaptureScreenshot`

Execution MCP tools:

- `RunStudioTests`: enters a bounded Studio play session, executes the project's game scripts, and returns captured server/client output.

The server sends existing Studio action names to the local bridge (`list`, `glob`, `readInstance`, `readScript`, `readGuiTree`, `serialize`, `captureScreenshot`, `playtest`) while exposing PascalCase tool names and inputs to Codex.

Example requests:

```text
@codex run the Studio test and show me the output
@codex run a 15 second Studio playtest and summarize errors
@codex check the current Studio session, then run tests
```

## Module Shape Rule

When syncing or inspecting source, preserve folder-backed module shape:

```text
SomeModule/
  init.luau
  Child.luau
```

Flattening that into `SomeModule.luau` can hide or disconnect children that are only visible in Studio.
