# bit agent: LLM Coding Agent System

## Overview

`src/x/agent/llm/` は LLM ベースのコーディングエージェントシステム。
ファイル操作・コマンド実行をツールとして LLM に提供し、タスクを自律的に遂行する。

## Package Structure

```
src/x/agent/llm/
  runner.mbt          # エージェント実行 (build_system_prompt, run_llm_agent)
  tools.mbt           # ツール定義 + ToolRegistry 構築
  tool_env.mbt        # ToolEnvironment trait + NativeToolEnvironment
  loop_detect.mbt     # LoopTracker (連続呼び出し検出 + 進捗ヒューリスティック)
  coord.mbt           # CoordinationBackend trait + FileCoordinationBackend
  coord_kv.mbt        # KvStore trait + KvCoordinationBackend + BitKvAdapter
  orchestrator.mbt    # AgentRunner trait + 並列タスク分解・実行
```

## Core Traits

### ToolEnvironment

エージェントのファイル操作・コマンド実行を抽象化。

```
read_file(path) -> String
write_file(path, content) -> Unit
remove_file(path) -> Unit
list_directory(path) -> String
list_files_recursive(path, max_depth) -> String
search_text(pattern, path, glob, max_results) -> String
run_command(command, work_dir, timeout_ms) -> String
```

実装:
- `NativeToolEnvironment`: shell (`cat`, `printf`, `rg`, etc.) 経由
- `TestToolEnvironment`: in-memory Map (wbtest 用)

### CoordinationBackend

エージェント間の状態管理を抽象化。

```
init_session / init_agent / write_status / write_step / write_pid
write_branch / append_event / read_status / read_all_agents
read_events_since / cleanup
```

実装:
- `FileCoordinationBackend`: ファイルシステムベース (shell exec)
- `KvCoordinationBackend`: KvStore trait 経由 (git-backed KV)

### KvStore

KV ストアの抽象化 (`coord_kv.mbt` から `@kv` 依存を隔離)。

```
get_string(key) / set_string(key, value) / delete(key)
list(prefix) / list_recursive(prefix) / commit(message)
```

実装:
- `BitKvAdapter`: `@kv.Kv` をラップ (`bit_kv_store()` factory)

### AgentRunner

エージェントプロセスの実行方式を抽象化。

```
spawn_agent(config, log_file) -> String   # handle (PID or agent_id)
wait_all(session_dir, timeout, log) -> Unit
cancel_agent(handle) -> Unit
```

実装:
- `ProcessAgentRunner`: nohup でバックグラウンドプロセス spawn (並列)
- `InProcessAgentRunner`: run_llm_agent を直接呼び出し (逐次)
- `Cloudflare submit mode`: `POST /api/v1/jobs/submit` に subtask を投入
  - submit 後は `GET /api/v1/jobs/:job_id` を polling して `done|failed|cancelled` を監視

## System Prompt

`build_system_prompt` は 5 フェーズのワークフローを LLM に指示:

1. **Explore** - `list_files_recursive` 1回 + `search_text` でコード探索
2. **Plan** - 変更対象ファイルを特定、`read_file` で確認
3. **Implement** - `write_file` で変更 (必須)
4. **Verify** - `run_command` でテスト・型チェック
5. **Complete** - ツール呼び出し停止、サマリー出力

Anti-patterns セクションで禁止事項を明示:
- 同一パスへの `list_directory` 繰り返し
- `read_file` の同一ファイル再読み
- 探索だけで `write_file` を呼ばない

`detect_project_hints(work_dir)` で MoonBit プロジェクトを自動検出し、
`moon check --deny-warn` / `moon test` / `moon fmt` を案内。

## Tools (7 tools)

| Tool | 説明 |
|------|------|
| `read_file` | ファイル読み取り。変更前に必ず読む |
| `write_file` | ファイル書き込み (上書き)。進捗に必須 |
| `list_directory` | ディレクトリ一覧 (浅い)。控えめに使用 |
| `list_files_recursive` | 再帰ファイル一覧。最初に1回だけ |
| `search_text` | ripgrep 検索。コード発見の主要手段 |
| `run_command` | シェルコマンド実行。検証用 |
| `remove_file` | ファイル削除 |

全ツールは `tracked_handler` でラップされ、LoopTracker が監視。

## Loop Detection

`LoopTracker` は 2 種類の問題を検出:

### 1. 連続呼び出し検出

同一 `(tool_name, key_arg)` が `max_repeat` 回 (default 3) 連続 → ナッジメッセージを返却。
ハンドラ実行をスキップし、LLM にツール結果としてナッジを提示。

### 2. 進捗ヒューリスティック

`write_file` なしで `write_nudge_threshold` 回 (default 10) の read-only ツール呼び出し →
進捗ナッジを返却。`write_file` 呼び出しでカウンタリセット。

read-only ツール: `read_file`, `list_directory`, `list_files_recursive`, `search_text`

## Orchestrator

### Task Decomposition

`plan_subtasks` が LLM にファイルスコープ付きサブタスク分解を依頼:

```json
[
  {"task": "Add tests for A", "files": ["a_test.mbt"]},
  {"task": "Add tests for B", "files": ["b_test.mbt"]}
]
```

`validate_file_overlap` でファイル重複を検出。重複があれば single task にフォールバック。

### Execution Flow

1. Plan subtasks (LLM planner)
2. Validate file overlap
3. `exec_mode=cloudflare` の場合: Cloudflare orchestrator に subtask を submit し、job status を polling
4. Cloudflare payload には `static_check_only=true` / `execution_backend=deno-worker` を含め、静的検査は Cloudflare・実行は Deno Worker に委譲
5. それ以外: worktrees + coordination directory を作成
6. Spawn agents via AgentRunner (process or in-process)
7. Monitor progress (stall detection, error pattern detection)
8. Commit changes per worktree
9. Merge branches
10. Cleanup
11. Optional: create PR

`bit agent llm --orchestrate` の主なモード:

- `--exec-mode process` (default): 既存の並列プロセス実行
- `--exec-mode in-process`: bit プロセス内で逐次実行 (self-agent モード)
- `--exec-mode cloudflare --orchestrator-url <url>`: Cloudflare worker orchestrator へ投入（`cloudflare-static` / `cloudflare-static-deno` / `deno-remote` alias）

### Monitor Decisions

- `AllDone`: 全エージェント完了
- `CancelAgent`: 3 連続エラー or 5 分間進捗なし → kill + Cancelled
- `Continue`: 引き続き polling

## Dependency Graph

```
src/x/agent/llm/
  loop_detect.mbt    -> (none)           # pure
  tool_env.mbt       -> (none)           # pure trait
  tools.mbt          -> @ffi, @llmlib    # shell + LLM
  runner.mbt         -> @ffi, @llmlib    # shell + LLM
  coord.mbt          -> @strconv         # pure coordination
  coord_kv.mbt       -> @kv, @git, @lib  # via BitKvAdapter only
  orchestrator.mbt   -> @llmlib, @strconv
```

`@kv`/`@git`/`@lib` への依存は `BitKvAdapter` に隔離済み。
`coord_kv.mbt` から `BitKvAdapter` を分離すれば、パッケージ全体が独立可能。

## Test Coverage

38 tests (all native-only):

- `loop_detect_wbtest.mbt`: 連続検出、リセット、キー抽出、進捗ナッジ (9 tests)
- `runner_wbtest.mbt`: プロンプト構造、ワークフローフェーズ、アンチパターン (7 tests)
- `tools_wbtest.mbt`: ツール実行、説明ガイダンス (8 tests)
- `tool_env_wbtest.mbt`: TestToolEnvironment mock (11 tests)
- `coord_wbtest.mbt`: FileCoordinationBackend (tests)
- `coord_kv_wbtest.mbt`: KvCoordinationBackend (3 tests)

## Configuration

### LlmAgentConfig

```
work_dir, task, branch_name, target_branch
provider_name, model, max_steps
auto_commit, auto_pr, pr_title, verbose
coord_dir, agent_id
env : &ToolEnvironment?     # None = NativeToolEnvironment
coord : &CoordinationBackend?  # None = FileCoordinationBackend
```

### OrchestratorConfig

```
work_dir, task, provider_name, model
max_workers, max_runtime_sec, max_tool_calls, stop_file
target_branch, auto_pr, verbose
exec_mode : process | in-process | cloudflare
orchestrator_url, orchestrator_token
```

## Future: moonix Integration

`ToolEnvironment` を moonix の `AgentRuntime` で実装することで:

- Snapshot/rollback per step
- Capability-based security
- Effect log (全外部操作の監査証跡)
- Fork-based exploration (複数アプローチの並列試行)

See `docs/moonix-agent-integration.md`.
