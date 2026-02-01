# moongit TODO

## テスト結果サマリー (2026-01-30)

### allowlist テスト (strict モード) ✅
- 成功: 3876 / 3966
- 失敗: 0
- broken: 4 (GPG等の前提条件不足)

**strict モード:** `SHIM_CMDS="pack-objects index-pack upload-pack receive-pack" SHIM_STRICT=1`
moongit が処理するコマンドでフォールバックなしで全テスト通過

### 含まれるテスト

- basic / init (t0000, t0001)
- plumbing commands (t1007, t1300, t1400, t1401, t1403, t1500)
- checkout / switch (t2006, t2014, t2060)
- ls-files / ls-tree (t3000-t3005, t3100-t3105)
- branch (t3200-t3205)
- diff (t4000-t4008, t4010, t4017)
- rev-list / log (t6000-t6006)
- porcelain commands (t7001, t7004, t7005, t7007, t7010, t7060, t7102, t7500, t7508)
- pack / idx (t5306-t5313)
- fetch / push / refs (t5501-t5546)
- clone (t5600-t5612)
- protocol v1/v2 (t5700-t5750)

---

## コマンド互換性調査 (2026-01-30)

git test suite で厳密テスト（SHIM_STRICT=1）した結果：

### ✅ 完全動作（git 互換）
- `receive-pack`, `upload-pack`, `pack-objects`, `index-pack`
- `hash-object`, `cat-file`, `show-ref`, `update-ref`, `symbolic-ref`, `rev-parse`
- `status`, `add`, `commit`, `log`, `diff`
- `checkout`, `switch`, `reset`, `merge`, `tag`
- `remote`, `fetch`, `pull`, `push`

### ⚠️ 部分的に動作（一部テスト失敗）
| コマンド | 状態 | 備考 |
|---------|------|------|
| init | 47/102 失敗 | --bare 対応済み、template/shared/separate-git-dir 未対応 |
| config | 36/102 失敗 | 多くのオプション未対応 |
| show | t0000 通過 | `--pretty=raw` のみ対応、他フォーマット未対応 |
| write-tree | git 互換 ✅ | `--prefix` 対応、tree ID 一致問題修正 |
| ls-files | 2/92 失敗 | |
| ls-tree | 1/92 失敗 | |

### 現在の SHIM_CMDS（strict モード）
```
receive-pack upload-pack pack-objects index-pack
```
上記 4 コマンドのみ moongit で処理、他は real git にフォールバック

### 修正内容
- `init`: `--bare`、`-b`/`--initial-branch`、reinit 対応
- `show`: `--pretty=raw` 対応
- `write-tree`: `--prefix` オプション対応、tree ID 一致問題修正
  - tree mode を "040000" → "40000" に修正（git 互換）
  - tree エントリのソート順を git 互換に修正
  - 既存オブジェクトのスキップ（読み取り専用ファイル対応）

---

## 完了した項目

### ✅ Protocol v2 filter/packfile-uris 対応 (2026-02-01)

**修正済み:**
- `src/cmd/bit/pack_objects.mbt`: `--filter` オプション対応 (blob:none, blob:limit, tree:depth)
- `src/cmd/bit/handlers_remote.mbt`: `GIT_CONFIG_OVERRIDES` 環境変数からの設定読み込み
- `src/lib/upload_pack.mbt`: filter spec のパースと適用

**テスト結果:**
- t5702-protocol-v2.sh テスト 42 (filter): パス
- t5702-protocol-v2.sh テスト 60 (packfile-uris): パス

### ✅ `-h` オプション対応

**修正済み:** `src/cmd/moongit/handlers_remote.mbt`
- `receive-pack -h` → usage を stdout に出力、exit code 129
- `upload-pack -h` → usage を stdout に出力、exit code 129

### ✅ git-shim `-c` オプション修正

**修正済み:** `tools/git-shim/bin/git`
- `git branch -c` が config オプションとして誤認識される問題を修正
- サブコマンド検出後のみ `-c` 検証を行うように変更

### ✅ CRC32 バグ修正 (2026-02-01)

**修正済み:** pack ファイルの CRC32 計算が正しく動作するよう修正

### ✅ index-pack SHA1 collision detection 対応 (2026-02-01)

**修正済み:** pack 解析時に SHA1 collision を検出して失敗するよう修正

---

## 修正が必要な項目 (allowlist 外)

### 中優先度: index-pack SHA1 collision detection

**失敗テスト:** t5300-pack-object.sh (allowlist 外)
- `not ok 53 - make sure index-pack detects the SHA1 collision`

**原因:**
moongit の index-pack が SHA1 collision を検出していない

**修正箇所:**
- `src/lib/pack_index.mbt` または関連ファイル

**状況:** 対応済み (2026-02-01)

---

### 中優先度: index-pack outside sha256 repository

**失敗テスト:** t5300-pack-object.sh (allowlist 外)
- `not ok 59 - index-pack outside of a sha256 repository`

**原因:**
sha256 フォーマットの pack ファイルを repository 外で処理できない

**状況:** 対応済み (2026-02-01)

---

### 低優先度: fetch deepen-since with commit-graph

**失敗テスト:** t5500-fetch-pack.sh (allowlist 外)
- 1件失敗 (deepen-since + commit-graph 関連)

**状況:** 対応済み (2026-02-01)

---

## 次のステップ

1. [x] `receive-pack -h` と `upload-pack -h` の実装
2. [x] strict モードでの allowlist テスト実行 (3216 テスト通過)
3. [x] git-shim `-c` オプション修正
4. [x] Protocol v2 filter/packfile-uris 対応
5. [x] SHA1 collision detection の実装
6. [x] sha256 pack 対応の確認 (2026-02-01)
7. [ ] allowlist に更にテストを追加

---

## 新機能: Git-Native PR システム (src/x/pr)

**計画ファイル:** `~/.claude/plans/lexical-beaming-valley.md`

GitHub/GitLab に依存しない、Git ネイティブな Pull Request システム。
専用ブランチ `_prs` に全 PR データを Git オブジェクト（blob/tree）として保存し、標準の fetch/push で同期。

### 実装ステップ

- [ ] **Step 1: 基盤 (types.mbt, format.mbt)**
  - 型定義 (PullRequest, PrComment, PrReview, PrState, ReviewVerdict)
  - Git スタイルテキストのシリアライズ/パース

- [ ] **Step 2: PR 操作 (pr.mbt)**
  - PrSystem 構造体
  - create, get, list, close

- [ ] **Step 3: コメント・レビュー (comment.mbt, review.mbt)**
  - add_comment, list_comments
  - submit_review, is_approved

- [ ] **Step 4: マージ (merge.mbt)**
  - can_merge, merge_pr
  - 既存の src/lib/merge.mbt を活用

- [ ] **Step 5: 同期 (sync.mbt)**
  - push, fetch
  - conflict resolution

### ファイル構成

```
src/x/pr/
├── moon.pkg.json
├── types.mbt          # 型定義
├── format.mbt         # シリアライズ/デシリアライズ
├── pr.mbt             # PrSystem, create/list/show/close
├── comment.mbt        # コメント操作
├── review.mbt         # レビュー操作
├── merge.mbt          # PR マージ
├── sync.mbt           # fetch/push 同期
└── pr_test.mbt        # テスト
```

### 検証方法

```bash
moon check
moon test --target native -p mizchi/git/x/pr
```
