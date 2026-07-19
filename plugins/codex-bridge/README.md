# CodexBridge Plugin

This is a Codex plugin, not a Roblox Studio plugin. It bridges Codex to a running Roblox Studio plugin through a read-first MCP server and a local CodexBridge listener.

CodexBridge is shared as an experimental local developer tool derived from the lemonade.gg plugin codebase. The goal is to use this as a practical starting point for Codex-to-Studio integration while a separate standalone plugin is developed over time.

## Setup

Full setup docs live in the repository root at `docs/CodexBridgeSetupGuide.md`.

Start the local CodexBridge listener from the plugin root:

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
- `CODEX_BRIDGE_RESULT_TIMEOUT_MS`: defaults to `30000`.
- `CODEX_BRIDGE_RESULT_POLL_MS`: defaults to `1000`.
- `CODEX_BRIDGE_HTTP_TIMEOUT_MS`: defaults to `20000`.
- `CODEX_BRIDGE_PORT`: local listener port, defaults to `17315`.
- `CODEX_BRIDGE_HOST`: local listener host, defaults to `127.0.0.1`.
- `CODEX_BRIDGE_TOKEN`: optional loopback auth token. If set on the listener, set it for the MCP server too.

## Local Listener

The listener is implemented at `bridge/Server.mjs`.

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

The server sends existing Studio action names to the local bridge (`list`, `glob`, `readInstance`, `readScript`, `readGuiTree`, `serialize`, `captureScreenshot`) while exposing PascalCase tool names and inputs to Codex.

## Module Shape Rule

When syncing or inspecting source, preserve folder-backed module shape:

```text
SomeModule/
  init.luau
  Child.luau
```

Flattening that into `SomeModule.luau` can hide or disconnect children that are only visible in Studio.
