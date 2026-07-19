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
- Ask before any future write or destructive Studio action.
- Do not log secrets or large script bodies unnecessarily.
- Respect tool limits such as `MaxDepth`, `MaxNodes`, `MaxResults`, and line ranges.

## Common Flow

1. Call `GetStudioSession` to confirm the local bridge and Studio connection status.
2. For UI work, call `ReadGuiTree` with `RootUniqueId` omitted to inspect `StarterGui` (`sg1`).
3. For scripts, use `ListInstances` or `GlobInstances` to find the script, then `ReadScript`.
4. For requested runtime verification, call `RunStudioTests` and summarize its `Summary`, `Errors`, and relevant `Logs`.
5. If a result is truncated, narrow the root, lower the scope, or reduce the playtest duration before retrying.
