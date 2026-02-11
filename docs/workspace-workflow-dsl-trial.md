# Workspace Workflow DSL Trial

`bit workspace` 用に、同じ内容を 2 形式で表現した試作。

- Starlark: `docs/workspace-workflow-starlark-example.star`
- CUE: `docs/workspace-workflow-cue-example.cue`

## 目的

- ノード依存（workspace 層）とタスク依存（workflow 層）を分離する
- `timeout` / `retries` / `artifacts` を宣言的に持つ
- 将来の runner（local / playwright / cloudflare）を同一IRで扱う

## 形式ごとの意図

- Starlark:
  - 記述体験を簡潔にしやすい
  - evaluator 側で「許可された関数だけ」を公開しやすい
  - 生成系（テンプレート/マクロ）に向く
- CUE:
  - スキーマ制約を強く持てる
  - バリデーション主導で設定品質を担保しやすい
  - 最終的な IR へ正規化しやすい

## 実装時の最小制限（提案）

- DSL 評価中の I/O 禁止（filesystem/network/process）
- ループ/再帰は禁止か、実行回数上限を厳格化
- runner ごとの許可パラメータを schema で固定
- 実行は必ず `bit workspace flow` の IR 経由（直接 shell 実行させない）
