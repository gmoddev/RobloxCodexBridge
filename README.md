# CodexBridge For Roblox Studio

CodexBridge is an experimental local bridge that lets Codex inspect a live Roblox Studio session. It is made of two parts:

- A Roblox Studio plugin in `Roblox-Plugin/` that can see the live DataModel, scripts, GUI trees, screenshots, and Studio-only objects.
- A Codex plugin in `plugins/codex-bridge/` that exposes read-first MCP tools to Codex through a local listener.

The local route looks like this:

```text
Codex MCP server -> local CodexBridge listener -> Roblox Studio plugin
```

CodexBridge is shared as an experimental local developer tool derived from the lemonade.gg plugin codebase. The goal is to use this as a practical starting point for Codex-to-Studio integration while a separate standalone plugin is developed over time.

## Repository Layout

```text
Roblox-Plugin/
  Codex.rbxmx              # Roblox Studio plugin model
  Codex/                   # Source tree for the Studio plugin

plugins/codex-bridge/
  .codex-plugin/plugin.json
  .mcp.json                # Codex MCP server config
  bridge/Server.mjs        # Local HTTP listener
  mcp/server/Server.mjs    # Codex-facing MCP server
  skills/                  # Codex skill instructions

.agents/plugins/marketplace.json
                           # Local Codex plugin marketplace entry
```

## What It Can Do

The Codex-facing toolset includes read-first inspection tools:

- `GetStudioSession`
- `ListInstances`
- `GlobInstances`
- `ReadInstance`
- `ReadScript`
- `ReadGuiTree`
- `SerializeInstance`
- `CaptureScreenshot`

It also includes `RunStudioTests`, an explicit execution tool that starts a bounded Studio playtest and captures server and client output. It does not expose arbitrary `RunCode` access.

When existing tests cannot cover a runtime behavior, `RunStudioTests` can inject a reserved `_TemporaryCODEXScript` into `ServerScriptService`, `StarterPlayerScripts`, or explicitly `ReplicatedFirst`. The bridge owns cleanup, reports structured assertion markers, and requires a final clean run through the bundled skill workflow.

For input binding checks, `RunInputScenario` compiles declarative keyboard, mouse, text, pointer, and Input Action System steps into a temporary LocalScript, then routes through the same bounded `RunStudioTests` playtest path.

The bridge is useful when filesystem source alone is not enough, such as inspecting live GUI hierarchy, children under script instances, Studio-assigned attributes, inserted assets, screenshots, or runtime-only Studio state.

## Requirements

- Roblox Studio
- Node.js 18 or newer
- ChatGPT/Codex desktop app with plugin support
- Local HTTP access from Roblox Studio to `127.0.0.1`

Roblox Studio may ask for HTTP permission when the plugin connects to localhost. Allow access to `127.0.0.1`.

## Install The Roblox Studio Plugin

1. Open Roblox Studio.
2. Install or import `Roblox-Plugin/Codex.rbxmx`.
3. Open the plugin from the Studio toolbar.
4. Leave the default bridge settings unless you changed the listener:

```text
CodexBridgeHost = 127.0.0.1
CodexBridgePort = 17315
CodexBridgeSessionId = local
CodexBridgeToken = ""
```

## Local Listener Startup

The Codex MCP server starts the local listener automatically. No separate terminal or manual Node command is required during normal use. If a compatible listener is already running, the MCP server reuses it instead of starting another one.

For listener-only development or diagnostics, it can still be started manually from this repository root:

```powershell
cd plugins/codex-bridge
node bridge/Server.mjs
```

Expected output:

```text
CodexBridge listener running at http://127.0.0.1:17315
```

Set `CODEX_BRIDGE_AUTOSTART=false` on the MCP server when intentionally managing the listener yourself.

Optional listener environment variables:

```powershell
$env:CODEX_BRIDGE_HOST = "127.0.0.1"
$env:CODEX_BRIDGE_PORT = "17315"
$env:CODEX_BRIDGE_TOKEN = ""
$env:CODEX_BRIDGE_MAX_BODY_BYTES = "10485760"
$env:CODEX_BRIDGE_AUTOSTART = "true"
$env:CODEX_BRIDGE_STARTUP_TIMEOUT_MS = "5000"
```

Use `127.0.0.1` for normal local operation. Binding the listener to another host can expose the bridge outside the local machine.

## Verify The Listener

In another terminal:

```powershell
Invoke-RestMethod http://127.0.0.1:17315/health
```

Expected shape:

```text
Status Name        Now
------ ----        ---
ok     CodexBridge ...
```

Then check the Studio session:

```powershell
Invoke-RestMethod http://127.0.0.1:17315/v1/session
```

Before Studio connects:

```json
{
  "Status": "waiting_for_studio",
  "SessionId": "local",
  "StudioConnected": false
}
```

After pressing connect in the Roblox Studio plugin:

```json
{
  "Status": "ready",
  "SessionId": "local",
  "StudioConnected": true
}
```

## Install The Codex Plugin

This repo includes a local Codex marketplace file at `.agents/plugins/marketplace.json`. In the ChatGPT/Codex desktop app:

1. Restart the app after cloning or changing the marketplace file.
2. Open Codex or Work mode.
3. Open **Plugins**.
4. Select the repo marketplace.
5. Install **CodexBridge**.
6. Start a new task before using the plugin.

The plugin loads from `plugins/codex-bridge/` and uses `plugins/codex-bridge/.mcp.json` to start the MCP server.

For Codex CLI, add this repo as a marketplace source:

```powershell
codex plugin marketplace add .
```

Then open `/plugins`, install `codex-bridge`, and start a new session.

## Basic End-To-End Test

1. Open Roblox Studio and press the plugin connect button.
2. In Codex, ask:

```text
Use CodexBridge and call GetStudioSession.
```

A healthy result should include:

```json
{
  "Status": "ready",
  "StudioConnected": true
}
```

Then try:

```text
Use CodexBridge to list the children of Workspace.
```

The root Workspace id is usually `ws1`.

To capture runtime output, ask:

```text
Use CodexBridge to run a 10 second Studio test and summarize any errors or warnings.
```

`RunStudioTests` enters Studio play mode and executes the project's game scripts. Play-mode state is discarded when the test ends.

To test a binding through simulated player input, ask:

```text
Use CodexBridge to run an input scenario for the E interact binding.
```

## Module Shape Rule

Preserve folder-backed ModuleScript shape:

```text
SomeModule/
  init.luau
  Child.luau
```

Flattening that into:

```text
SomeModule.luau
```

can hide or disconnect children that are visible in Studio but not represented by a single source file.

## Troubleshooting

`bridge_unavailable`

- Confirm `CODEX_BRIDGE_URL` uses the same loopback host and port as the Studio plugin.
- Confirm `CODEX_BRIDGE_AUTOSTART` is not disabled.
- Start `node bridge/Server.mjs` only as a manual diagnostic fallback.
- Check firewall or local security prompts.

`waiting_for_studio`

- The listener is running, but Studio has not registered.
- Open Roblox Studio and press connect in the plugin.
- Confirm Studio HTTP requests to localhost are allowed.

`401 Invalid or missing CodexBridge token`

- `CODEX_BRIDGE_TOKEN` is set somewhere.
- Use the same token in the listener, Codex MCP environment, and Studio plugin settings.

Tool calls time out

- Confirm Studio is still open and polling.
- Check Roblox Studio Output for plugin warnings.
- Increase `CODEX_BRIDGE_RESULT_TIMEOUT_MS` for large trees, screenshots, or unusually slow playtests.

Deep `ListInstances` calls return empty

- Use smaller `MaxDepth` values and walk child nodes in chunks. The bridge can handle this more reliably for large trees.
