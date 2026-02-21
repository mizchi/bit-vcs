# bit-relay Protocol Specification (Draft)

## 1. 目的とスコープ

この仕様は、`bit hub sync` が利用する relay プロトコルを定義する。  
対象は以下。

- Relay サーバーの HTTP / WebSocket API
- `bit` クライアントの relay 利用方式（明示 relay URL と smart-http fallback）
- `hub.record` ペイロードの最小契約

Git smart-http 自体の仕様（`/info/refs`, pack protocol）は本仕様の対象外。

## 2. 用語

- `Room`: relay 内の論理チャネル。既定値は `main`。
- `Envelope`: relay で中継される 1 メッセージ。
- `Cursor`: room 内 envelope 配列の 0-based 位置を表す整数。
- `HubRecord`: `bit x/hub` が保持するレコード（テキストシリアライズ）。

## 3. URL とトランスポート選択

`bit hub sync` は以下の URL を受け付ける。

- `relay+http://host[:port]`
- `relay+https://host[:port]`
- `relay://host[:port]`（`http://` として扱う）
- `http://...` / `https://...`（smart-http を先に試行）

### 3.1 明示 relay

`relay+http(s)://...` または `relay://...` の場合、`bit` は relay API を直接利用する。

### 3.2 smart-http fallback

`http(s)://...` の場合、`bit` はまず smart-http push/fetch を試行する。  
その際に **ProtocolError かつメッセージに `HTTP 404` を含む場合のみ** relay にフォールバックする。

## 4. Envelope スキーマ

relay が保持・返却する envelope の JSON 形は以下。

```json
{
  "room": "main",
  "id": "msg-1",
  "sender": "alice",
  "topic": "notify",
  "payload": { "kind": "hub.record", "record": "..." },
  "signature": null
}
```

- `room`: string, required
- `id`: string, required
- `sender`: string, required
- `topic`: string, required
- `payload`: any JSON
- `signature`: string | null

## 5. HTTP API

### 5.1 `POST /api/v1/publish`

query parameter:

- `room` (optional, default `main`)
- `sender` (required)
- `topic` (optional, default `notify`)
- `id` (optional, default `${sender}-${Date.now()}`)
- `sig` (optional; envelope.signature に格納)

request body:

- JSON テキスト（`bit` からは object を送る）

response:

- `200 OK`

```json
{ "ok": true, "accepted": true, "cursor": 1 }
```

`accepted=false` は重複 ID による重複受信（idempotent）を意味する。

error:

- `400` + `{"ok":false,"error":"missing query: sender"}`
- `400` + `{"ok":false,"error":"unsupported topic: <topic>"}`
- `400` + `{"ok":false,"error":"invalid json payload"}`

### 重複判定

実装上、同一 room で同一 `id` の envelope は重複として拒否される（`accepted=false`）。

### 5.2 `GET /api/v1/poll`

query parameter:

- `room` (optional, default `main`)
- `after` (optional, default `0`, `after < 0` は `0` に正規化)
- `limit` (optional, default `100`, `limit <= 0` は `1` に正規化)

response:

- `200 OK`

```json
{
  "ok": true,
  "room": "main",
  "next_cursor": 1,
  "envelopes": [/* Envelope[] */]
}
```

`next_cursor = after + envelopes.length`。

### 5.3 `GET /health`

疎通確認用。

```json
{ "status": "ok", "service": "bit-relay" }
```

## 6. WebSocket API

endpoint:

- `GET /ws?room=<room>`
- `Upgrade: websocket` 必須（なければ `426`）

サーバー送信:

- 接続直後: `{"type":"ready"}`
- `publish` が `accepted=true` のとき:

```json
{
  "type": "notify",
  "room": "main",
  "cursor": 1,
  "envelope": { /* Envelope */ }
}
```

クライアント送信:

- `{"type":"ping"}` を送ると `{"type":"pong"}` が返る

## 7. `bit` クライアント契約

### 7.1 Push (`bit hub sync push`)

relay モード時:

1. `refs/notes/hub` を読み込む（なければ失敗）
2. `hub/` 配下レコード（削除 tombstone 含む）を列挙
3. 各 record を次で `POST /api/v1/publish`:
   - `room=main`
   - `sender=bit`
   - `topic=notify`
   - `id=<record.serialize() の blob-id(hex)>`
   - body:
     - `{"kind":"hub.record","record":"<serialized HubRecord>"}`
4. `accepted=true` 件数を集計

### 7.2 Fetch (`bit hub sync fetch`)

relay モード時:

1. ローカル cursor を `.git/hub/relay-cursor/<hash(remote_base_url)>` から読む（未存在は `0`）
2. `GET /api/v1/poll?room=main&after=<cursor>&limit=200`
3. envelope の `payload.kind == "hub.record"` のみ取り込み
4. `payload.record` を `HubRecord` として parse/merge
5. 変更があれば `refs/notes/hub` にコミット
6. `next_cursor` を保存

## 8. `hub.record` ペイロード

relay が中継する payload の `record` は、`bit` の `HubRecord::serialize()` 文字列である。  
ヘッダ + 空行 + body 形式。

例:

```text
version 1
key hub/issue/082e0cda/meta
kind hub.issue
clock node-a=1
timestamp 1770655267
node node-a
deleted 0

{"title":"relay-issue-1","body":"relay-body-1"}
```

## 9. 互換性メモ

- 現行 relay 実装は `topic=notify` のみ受理する。
- 認証・署名検証は未実装（`sig` は透過保存のみ）。
- relay は unknown envelope/payload field をそのまま保持・返却する。

## 10. Clone シグナリング（追加）

`bit clone` のデータ転送は peer-to-peer で行い、relay は peer 発見だけを担う。

- publish:
  - `topic=notify`
  - `payload.kind=bit.clone.announce.v1`
  - `payload.clone_url=<smart-http endpoint>`
  - `payload.repo=<optional repo label>`
- poll:
  - `GET /api/v1/poll` の `envelopes` から `payload.kind=bit.clone.announce.v1` を抽出
  - 同一 `sender` の複数 announce は最後の 1 件を有効とする

CLI:

- `bit hub sync clone-announce [<remote-url>] --url <clone-url> [--repo <repo>]`
- `bit hub sync clone-peers [<remote-url>] [--include-self]`
- `bit clone relay+http(s)://<relay-host> [--relay-sender <sender>] [--relay-repo <repo>]` は `clone-peers` と同じ発見ロジックで peer を 1 件選んで clone する
  - 既定は最初の peer
  - `BIT_RELAY_CLONE_SENDER=<sender>` を設定するとその sender を優先
  - `BIT_RELAY_CLONE_REPO=<repo>` または `--relay-repo` で repo 名一致 peer を優先（sender 指定があれば sender 優先）
- `bit fetch relay+http(s)://<relay-host> [--relay-sender <sender>] [--relay-repo <repo>]` も同じ発見ロジックで peer を 1 件選んで fetch する
  - `BIT_RELAY_FETCH_SENDER=<sender>` / `BIT_RELAY_FETCH_REPO=<repo>` で既定優先条件を指定できる
- `bit pull relay+http(s)://<relay-host> [--relay-sender <sender>] [--relay-repo <repo>]` も同じ発見ロジックで peer を 1 件選んで pull する
  - `BIT_RELAY_PULL_SENDER=<sender>` / `BIT_RELAY_PULL_REPO=<repo>` で既定優先条件を指定できる
- `bit push relay+http(s)://<relay-host> [--relay-sender <sender>] [--relay-repo <repo>]` も同じ発見ロジックで peer を 1 件選んで push する
  - `BIT_RELAY_PUSH_SENDER=<sender>` / `BIT_RELAY_PUSH_REPO=<repo>` で既定優先条件を指定できる

---

この仕様は現行実装（`bit` と `bit-relay`）に合わせた draft であり、将来の topic 拡張や認証追加で更新される。

## 11. ベンチマーク（k6）

- シナリオ: `tools/relay-k6-scenario.js`
- ローカル relay 起動付き実行:
  - `bash tools/bench-relay-k6.sh`
- 例（15秒、publish 120 req/s, poll 12 VU）:
  - `K6_BENCH_DURATION=15s K6_PUBLISH_RATE=120 K6_POLL_VUS=12 bash tools/bench-relay-k6.sh`
- 署名必須 relay（Cloudflare Worker など）で poll のみ測る場合:
  - `RELAY_BASE_URL=https://bit-relay.mizchi.workers.dev K6_PUBLISH_RATE=0 K6_POLL_VUS=20 bash tools/bench-relay-k6.sh`
- 署名必須 relay で publish も測る場合（ローカル signer 自動起動）:
  - `RELAY_BASE_URL=https://bit-relay.mizchi.workers.dev RELAY_SIGN_PRIVATE_KEY_FILE=~/.config/bit/relay-ed25519.pem K6_PUBLISH_RATE=80 K6_POLL_VUS=8 bash tools/bench-relay-k6.sh`
  - 必要に応じて `RELAY_SIGN_PUBLIC_KEY=<base64url>` で公開鍵を明示指定できる
