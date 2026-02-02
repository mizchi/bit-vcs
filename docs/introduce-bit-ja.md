# bit - AI サンドボックスのための Git 実装

## What's this

git 互換の blob 操作 + 独自の拡張を施した VCS です。

Rust で git を書き直した gitoxide の MoonBit 版のような位置づけですが、AI 用のサンドボックスとして設計しています。

MoonBit で書いていますが、バイナリを Mac/Linux 向けに配布しています。

```bash
curl -fsSL https://raw.githubusercontent.com/mizchi/bit/main/install.sh | bash
```

> **Warning**: 実験的な実装です。本番環境では使わないでください。最悪の場合、データが破損する可能性があります。

## Why bit

- **WASI サンドボックス / インメモリ対応**: バックエンドに任意のストレージを持てます。ブラウザ上や WASM 環境で動作可能
- **サブディレクトリチェックアウト**: svn などにあった機能。モノレポの一部だけを独立したリポジトリとして扱える
- **bit/x/fs**: Git blob をバックエンドにした仮想ファイルシステム
- **bit/x/kv**: P2P 同期可能な分散 KV ストア

## Subdirectory Clone

大規模なモノレポで、一部のディレクトリ以下だけほしい時があります。いまの git は sparse-checkout や `--depth=1` の shallow clone などがありますが、任意のサブディレクトリをルートにとって解決することができません。

```
modules/
  foo/
  bar/
```

git だとこの `foo` だけをルートディレクトリとして取り出すことはできません。hg や svn ならできたんですが...

というわけで、まずこれを実装しました。

```bash
# mizchi/bit の src/x/fs だけを取り出す
$ bit clone mizchi/bit:src/x/fs
$ cd fs
$ ls
fs.mbt  types.mbt  ...
```

GitHub の URL をそのまま貼り付けることもできます。

```bash
# ブラウザで開いてる URL をそのままコピペ (tree はサブディレクトリ)
$ bit clone https://github.com/user/repo/tree/main/packages/core

# blob は単一ファイル取得
$ bit clone https://github.com/user/repo/blob/main/README.md
```

クローン先はパス末尾の名前になります。必要なら `bit clone <src> <dest>` で明示的に指定できます。

これは双方向に動作します。つまり、`fs` で編集して `bit push` すると、元のリポジトリに変更が反映されます。

```bash
cd fs
echo "// new code" >> fs.mbt
bit add .
bit commit -m "update"
bit push origin main  # 元の mizchi/bit に push される
```

### 親リポジトリとの共存

git から見たときは submodule と同じく embedded repository として認識されるので、親リポジトリから操作して不整合を起こすことはありません。

```bash
# 親リポジトリで git add すると
$ git add fs
warning: adding embedded git repository: fs
```

ただし、bit で checkout したディレクトリの内部で git コマンドを使って操作した場合の挙動は十分に検証できていません。初期化時に pre-commit hook を注入して操作を止めるようにしていますが、完全に不整合を排除できるかは未検証です。不整合を避けたいなら、AI に渡す環境では `git` を `bit` にエイリアスするのが安全でしょう。

## 実験的な機能: bit/x/fs

Git の blob をそのままファイルシステムのバックエンドに使う仮想ファイルシステムです。

```moonbit
let fs = Fs::from_commit(fs, ".git", commit_id)
let content = fs.read_file(fs, "src/main.mbt")  // blob を遅延読み込み
```

Nix のようにハッシュ値で任意の状態を復元できます。この FS 内ならどのような操作を加えても、任意の時点にロールバックすることができます。

最近だと AI エージェント自体がスナップショット機能を持っていることがありますが、これを Git プロトコルのレベルで保証します。つまり、エージェントのメモリ外にある永続化されたストレージとして使えます。

また、WASM/WASI で動くように設計しているので、これを AI 用のサンドボックスとして使うコーディングエージェントを今実装しているところです。

この FS 内部では blob の解決を遅延できるように設計しているので、大規模なリポジトリでも必要な部分だけを読み込む、といった使い方ができます。

## 実験的な機能: bit/x/kv

Git blob を特定の P2P ノード間で共有することを想定した KV ストアです。ブロックチェーンから着想しています。

```moonbit
let db = Kv::init(fs, fs, git_dir, node_id)
db.set(fs, fs, "users/alice/profile", value, ts)
db.sync_with_peer(fs, fs, peer_url)  // Gossip protocol で同期
```

何に使うかというと、多数の AI エージェントに特定の状態を基準にタスクを並列化させたとき、そのエージェント間で状態を高速に同期させる想定です。

## アイデア段階: bit/x/collab

GitHub/GitLab に依存しない、Git ネイティブなコラボレーション機能です。Pull Request や Issue を Git オブジェクトとして `_collab` ブランチに保存し、通常の fetch/push で同期します。

```moonbit
let collab = Collab::init(fs, fs, git_dir)
let pr = collab.create_pr(fs, fs, "Fix bug", "...",
  source_branch, target_branch, author, ts)
```

ほとんど実装されていません。アイデアだけです。

## 制限

実装した範囲では git 本体のテストは多く通っていますが、テストに含まれていない未実装のコマンドが多数あるのを認識しています。

### 未対応のコマンド

- **インタラクティブ系**: `bit add -p` や `bit rebase -i`。対応できてないというより、抽象が思いついていません
- **GPG 署名**: 未実装

### パフォーマンス

- `bit clone` は git の約 1.8 倍遅いです
- MoonBit がマルチスレッド対応してないため、packfile のデコーディングがボトルネックになっています

## リンク

- GitHub: https://github.com/mizchi/bit
- MoonBit: https://www.moonbitlang.com/
