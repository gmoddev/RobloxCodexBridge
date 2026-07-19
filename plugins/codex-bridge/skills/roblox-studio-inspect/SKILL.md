---
name: roblox-studio-inspect
description: Inspect and test live Roblox Studio projects through the CodexBridge MCP bridge. Use when users ask about live Studio hierarchy, GUI trees, script contents, Studio-only objects, screenshots, runtime output, playtests, or CodexUniqueID-based Roblox instances.
---

# Roblox Studio Inspect

Use this skill when a user asks Codex to inspect a live Roblox Studio project through CodexBridge.

## Core Rules

- Prefer the CodexBridge MCP read tools before inferring Studio state from local files.
- Use `ReadGuiTree` for UI inspection instead of manually calling `ListInstances` and `ReadInstance` for every GUI child.
- Use `ReadScript` when the target is a `Script`, `LocalScript`, or `ModuleScript`.
- Use `ReadInstance` for one known live instance.
- Use `ListInstances` for browsing direct children and shallow hierarchy.
- Use `GlobInstances` for searching live instances by name/path/class.
- Use `SerializeInstance` for debug snapshots or rollback planning, not routine UI inspection.
- Use `CaptureScreenshot` only when visual verification matters.
- Use `RunStudioTests` only when the user asks to run or test the project, enter play mode, or capture runtime output.

## Module Shape Rule

Treat these module representations as equivalent:

```text
Module.luau
Module/init.luau
```

Preserve `Module/init.luau` when the module has children.

Never rewrite:

```text
SomeModule/
  init.luau
  Child.luau
```

into:

```text
SomeModule.luau
```

That flattening can hide or disconnect children that Codex cannot see from source text alone.

## Naming Rule

Use PascalCase by default for new code, schema names, internal identifiers, and docs.

Allowed exceptions:

- Bridge wire fields that already exist, such as `uniqueId`, `requestId`, `toolName`, `parentId`, and `robloxClass`.
- MCP protocol and JSON Schema fields dictated by external tooling, such as `inputSchema`, `readOnlyHint`, and `jsonrpc`.
- Roblox API names and properties, such as `ClassName`, `GetChildren`, `AbsoluteSize`, and `Source`.
- The Luau idiom `self = setmetatable({}, ...)` on the Studio side.

If a public MCP input must be lower camel case for compatibility, convert it to PascalCase immediately inside the implementation.

## Safety

- Treat inspection tools as read-only. `RunStudioTests` executes project scripts in a temporary Studio play session.
- Do not use `RunCode` for normal inspection.
- Do not run a playtest automatically while performing routine inspection.
- Temporary smoke scripts are allowed only as part of an explicitly requested test or runtime verification. Do not use them for routine inspection.
- Ask before any other future write or destructive Studio action.
- Do not log secrets or large script bodies unnecessarily.
- Respect tool limits such as `MaxDepth`, `MaxNodes`, `MaxResults`, and line ranges.

## Runtime Verification Levels

Choose the least invasive level that covers the behavior:

1. **Existing tests available:** call `RunStudioTests` without temporary source. Do not inject another test harness.
2. **Simple runtime observation:** call `RunStudioTests` without temporary source and inspect the relevant logs, warnings, errors, or state.
3. **No existing hook covers the behavior:** use the `_TemporaryCODEXScript` workflow below.

Do not stop at "needs a Studio smoke test" when level 3 can safely verify the change.

## Temporary Smoke Tests

Use `RunStudioTests` with `SmokeTestName` and at least one of `TemporaryServerScript` or `TemporaryLocalScript`. The bridge creates an owned script named `_TemporaryCODEXScript`, runs it only for that bounded playtest, removes it from the edit DataModel, and reports cleanup in `TemporarySmokeTest`.

Approved locations:

- `TemporaryServerScript`: `ServerScriptService`.
- `TemporaryLocalScript`: `StarterPlayerScripts` by default.
- Set `TemporaryClientLocation` to `ReplicatedFirst` only when initialization order is specifically under test.

Every temporary script must:

- Print a unique prefix in the form `[CODEX_SMOKE:<SmokeTestName>]`.
- Use bounded assertions and bounded waits.
- Print `PASS` or `FAIL` for assertions.
- Print `[CODEX_SMOKE:<SmokeTestName>] COMPLETE` only after every assertion finishes.
- Avoid persistent DataStore writes, purchases, teleports, moderation actions, and external HTTP.
- Destroy or disable runtime objects and disconnect event connections it creates.
- Never call `StudioTestService:EndTest`; the bridge owns playtest termination and log capture.

Recommended server script pattern:

```luau
local TestPrefix = "[CODEX_SMOKE:InventoryCutlass]"

local function Pass(Message: string)
	print(TestPrefix, "PASS", Message)
end

local function Fail(Message: string)
	error(string.format("%s FAIL %s", TestPrefix, Message), 0)
end

local function Expect(Condition: boolean, Message: string)
	if Condition then
		Pass(Message)
	else
		Fail(Message)
	end
end

local Success, Result = pcall(function()
	local Players = game:GetService("Players")
	Expect(Players ~= nil, "Players service is available")
	return true
end)

if not Success then
	warn(TestPrefix, "ERROR", Result)
	error(Result, 0)
end

print(TestPrefix, "COMPLETE")
```

After the temporary run:

1. Require `TemporarySmokeTest.Completed`, `TemporarySmokeTest.Passed`, and `TemporarySmokeTest.CleanupVerified` to be true. Script execution by itself is not success.
2. Inspect logs containing the exact test prefix, plus all returned errors and warnings.
3. Call `GlobInstances` with pattern `**/_TemporaryCODEXScript`; no owned temporary instances should remain.
4. Run one final clean `RunStudioTests` call without `SmokeTestName` or temporary source.
5. Report both the temporary result and final clean-run result.

If cleanup is not verified, stop testing and report the remaining path. Do not inject another temporary script over it.

## Common Flow

1. Call `GetStudioSession` to confirm the local bridge and Studio connection status.
2. For UI work, call `ReadGuiTree` with `RootUniqueId` omitted to inspect `StarterGui` (`sg1`).
3. For scripts, use `ListInstances` or `GlobInstances` to find the script, then `ReadScript`.
4. For requested runtime verification, call `RunStudioTests` and summarize its `Summary`, `Errors`, and relevant `Logs`.
5. When no existing test covers a required behavior, follow the `_TemporaryCODEXScript` workflow and finish with a clean run.
6. If a result is truncated, narrow the root, lower the scope, or reduce the playtest duration before retrying.
