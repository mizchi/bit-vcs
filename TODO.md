# TODO (Active Only)

最終整理日: 2026-02-15
方針: 完了ログは一旦外し、未完了タスクのみ管理する。

## P0: Git compatibility / 計測

- [x] `t5326-multi-pack-bitmaps.sh` を解消する（2026-02-15: `SHIM_CMDS="multi-pack-index pack-objects index-pack repack" SHIM_STRICT=1` で `success 357 / failed 0`）
- [x] `t5327-multi-pack-bitmaps-rev.sh` を解消する（2026-02-15: `SHIM_CMDS="multi-pack-index pack-objects index-pack repack" SHIM_STRICT=1` で `success 314 / failed 0`）
- [x] `t5334-incremental-multi-pack-index.sh` を解消する（2026-02-15: `SHIM_CMDS="multi-pack-index pack-objects index-pack repack" SHIM_STRICT=1` で `success 16 / failed 0`）
- [ ] multi-pack-index の崩れを修正する
  - bitmap/rev 生成検証
  - `rev-list --test-bitmap`
  - incremental layer/relink
- [ ] allowlist/full の全流し再計測を実施する（長時間ジョブ）

## P1: Agent runtime

- [ ] Process agent signal handling: タイムアウト/キャンセル時のクリーンアップ改善
- [ ] Agent output capture: ProcessAgentRunner の per-agent stdout 取得

## P2: Git互換の残タスク（方針未対応）

- [ ] `t5540-http-push-webdav.sh`
- [ ] `t9001-send-email.sh`
- [ ] `--help` 移植（全サブコマンドの usage テキスト）

## P3: プラットフォーム/将来タスク

- [ ] Moonix integration: ToolEnvironment <-> AgentRuntime（moonix release 待ち）
- [ ] bit mount: ファイルシステムにマウントする機能
- [ ] bit mcp: MCP 対応
- [ ] gitconfig サポート
- [ ] BIT~ 環境変数の対応
- [ ] `.bitignore` 対応
- [ ] `.bit` 対応
- [ ] bit jj: jj 相当の対応
