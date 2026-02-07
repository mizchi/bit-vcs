# moonix Agent Integration Design

## Overview

`ToolEnvironment` trait を moonix の `AgentRuntime` で実装し、
エージェントの実行環境を sandbox + snapshot/rollback 付きに移行する。

## Architecture

```
mizchi/bit/x/agent/llm/
  tool_env.mbt          # ToolEnvironment trait (already exists)
  tools.mbt             # Tool registry (already exists)
  runner.mbt            # Agent runner (already exists)

mizchi/moonix/src/ai/bit-agent-adapter/  (NEW)
  adapter.mbt           # MoonixToolEnvironment: impl ToolEnvironment for AgentRuntime
```

## ToolEnvironment <-> AgentRuntime Mapping

| ToolEnvironment method | AgentRuntime equivalent |
|----------------------|------------------------|
| `read_file(path)` | `runtime.read_file(abs_path)` -> String |
| `write_file(path, content)` | `runtime.write_file(abs_path, content.to_bytes())` |
| `remove_file(path)` | `runtime.remove(abs_path)` |
| `list_directory(path)` | `runtime.readdir(abs_path)` -> join entries |
| `list_files_recursive(path, depth)` | recursive readdir with depth limit |
| `search_text(pattern, path, glob, max)` | in-memory grep over fs |
| `run_command(cmd, wd, timeout)` | `runtime.spawn_process(cmd, args)` + effect log |

## Key Benefits

1. **Snapshot per step**: Auto-snapshot after each write_file
2. **Rollback on error**: If verification fails, rollback to last good state
3. **Effect log**: All run_command calls recorded with full audit trail
4. **Capability control**: Restrict agent to specific paths/commands
5. **Fork for exploration**: Try multiple approaches on branches

## Implementation Steps

1. Add `mizchi/bit` as dependency in moonix (or vice versa)
2. Create `MoonixToolEnvironment` struct wrapping `AgentRuntime`
3. Implement `ToolEnvironment` trait methods
4. Wire into `create_tool_registry` via existing DI pattern
5. Add snapshot-on-write and rollback-on-error middleware

## search_text Implementation Note

moonix has no built-in ripgrep. Two options:
- A: Host delegation via `runtime.spawn_process("rg", args)` (practical)
- B: In-memory regex search over all files (pure, slower)

Recommend A with B as fallback for pure WASM environments.

## run_command Implementation Note

Shell execution requires host delegation:
```moonbit
impl ToolEnvironment for MoonixToolEnvironment with run_command(self, cmd, wd, timeout) {
  // Capability check
  // Record effect
  // Delegate to host shell
  // Return stdout
}
```

Effect log records the command, exit code, and duration for audit.
