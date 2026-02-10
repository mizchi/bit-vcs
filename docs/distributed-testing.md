# Distributed Testing Guide

このドキュメントは `bit` の agent/orchestrator/Hub まわりを、
「分散システムとして壊れ方まで含めて」検証するための運用ガイド。

## 1. テスト層

1. Pure logic (高速)
- 目的: 判定ロジックの退行検出
- 対象: `src/x/agent/llm/*_wbtest.mbt`, `src/x/agent/agent_test.mbt`
- 例: 停滞検知、連続エラー検知、サブタスク競合検知

2. Coordination/State (中速)
- 目的: coordination dir の read/write 整合性検証
- 対象: `src/x/agent/llm/coord_wbtest.mbt`
- 例: event append の連番、status/step の round-trip

3. Hub/Sync contract (中速)
- 目的: PR/Issue/Review の表現と同期契約の検証
- 対象: `src/x/hub/*_test.mbt`, `src/x/hub/*_wbtest.mbt`, `src/x/hub/native/*_wbtest.mbt`

4. End-to-end simulation (重い)
- 目的: モック provider を含む agent loop の疎通
- 対象: `src/x/agent/llm/agent_e2e_wbtest.mbt`

## 2. 重要な不変条件 (Invariants)

1. Coordination event は追記され、既存 event を上書きしない
2. 同一サブタスク集合でファイル write-scope が衝突しない
3. agent 状態遷移は `pending -> running -> (done|failed|cancelled)` を保つ
4. 連続エラーや長時間停滞を検知したら `cancel` 判断へ遷移する
5. Hub の serialize/deserialize 往復で意味情報を失わない

## 3. 実行コマンド

```bash
# 分散系に絞った検証
just test-distributed

# 追加で全体回帰
just test
just check
```

## 4. 障害注入 (Fault Injection) の最小セット

1. 連続 error event を注入して cancel 判定を確認
2. step time を古くして stall 判定を確認
3. file scope を重複させて planner の single-task fallback を確認
4. hub sync で空/壊れた payload を入力してエラー経路を確認

## 5. 運用ルール

1. 新しい orchestrator 仕様を追加したら、最低 1 つは失敗系テストを同時追加
2. bugfix は「再現テスト (Red) -> 修正 (Green)」を必須にする
3. Cloudflare/外部 LLM 依存の E2E は別ジョブで分離し、ローカルではモック中心に回す
