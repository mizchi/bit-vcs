# ci-notify

GitHub Actions の集計結果から、失敗時のみ Issue を作成するための汎用 TypeScript 通知ツールです。

## 前提

- Node.js + pnpm
- 実行時に GitHub API token を利用可能なこと（`GITHUB_TOKEN` または `GH_TOKEN`）

## 使い方

```bash
pnpm --dir tools/ci-notify install
pnpm --dir tools/ci-notify run notify -- \
  --summary compat-random-summary.md \
  --repo "owner/repo" \
  --run-id "$GITHUB_RUN_ID" \
  --run-attempt "$GITHUB_RUN_ATTEMPT" \
  --run-url "$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID" \
  --matrix "sharded results" \
  --workflow "Git Compat Randomized" \
  --issue-title "Git Compat Randomized failed" \
  --labels "ci,automated-report" \
  --require-token
```

### オプション

- `--summary` : 集計結果ファイル（Markdown）
- `--repo` : `owner/repo`
- `--issue-title` : 重複回避用にタイトルは固定して再利用しやすくしています（デフォルト: ワークフロー名）
- `--labels` : カンマ区切り
- `--matrix` : 任意の実行識別子（集計本文に表示）
- `--dedupe` / `--no-dedupe` : 同名の既存オープンIssueを更新（デフォルト: 有効）
- `--dry-run` : GitHub APIを呼ばず内容を表示のみ
- `--require-token` : トークン必須化

### 集計サマリの拡張

`tools/aggregate-git-compat-random.sh` は failure 区間に以下を出します。

- shard / run_id / seed
- seed_source
- 再実行コマンド（`bash tools/run-git-compat-random.sh ...`）
- 実行したテスト一覧（`tests`）
- 失敗時ログパス
