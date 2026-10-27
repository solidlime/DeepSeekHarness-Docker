# アクセス制御の見直し（#11 設計メモ）

## 決定（実装済み・2026-10-28 改訂）

**共有 cookie を Caddy が全リクエストに注入する方式に戻した。**
守りは**ネットワーク境界のみ**（LAN 内に置く・ポート転送しない）。

dsh 自身は cookie の無いリクエストに 401 を返し、その解除には
「起動時に表示されるトークン URL」が必要。だがその URL は起動ログにも
`docker logs` にも残らず、各端末で漏らす（実害：スマホから一切開けない）。
端末ごとの一度きり認証は、トークンを配る手段が無い以上成立しない。

`bootstrap.js` が Caddyfile に入れるのは次の 2 行（cookie は毎起動で作り直す）:

```
header_up Host {http.request.hostport}
header_up Cookie "dsh-auth-<hash>=v1.<payload>.<sig>"
```

クライアントが古い `dsh-auth-*` を送ってきても**こちらで置き換える**ので、
残骸の cookie を持つ端末と持たない端末で差が出ない。

## なぜ「知っていれば通る」を許容するか

LAN 内にしか口が無いなら、知っていても入れない場所からは届かない。
別ネットワーク（VPN 含む）から使いたくなった時点で、初めて以下が必要になる：

- **推奨:** リバースプロキシ前方認証（Authelia / Authentik など）。dsh の cookie より前で塞ぐ。
- mTLS（クライアント証明書）。

クライアント証明書 / TLS / IdP のいずれかを入れれば、共有 cookie は不要になる。

**パスキー（WebAuthn）は現時点で不可**: https か localhost でしか登録できない。
TLS を先に入れる必要がある。

## 旧方式（廃止・2026-10-28）

cookie を注入せず、各端末が初回だけトークン URL を踏む方式。
セキュリティ上は良かったが、トークン URL を配る経路が無く実用にならなかった。

`docker-entrypoint.sh` の `bootstrap.js` が、共有シークレット
(`/root/.dsh/.credentials.yaml` の `browser-session.secret`) から
HMAC 署名付きセッション cookie を生成し、Caddy が全リクエストに注入する。

- 長所: 端末を問わず開けば使える。設定ゼロ。
- 短所: **URL またはシークレットを知っていれば誰でも通る**。端末の識別も失効もできない。
  シークレットが漏れたら全端末が同時に無効になる（ローテーションしかない）。

cookie の形式（実測）:

```
name  = "dsh-auth-" + base64url(sha256(authority))
value = "v1." + base64url(payload) + "." + base64url(hmacSHA256(secret, payload))
payload = {"version":1,"authority":"nas:3080","issuedAt":<ms>,"expiresAt":<ms>}
```

`--trusted-host` と authority が一致しないと 403 になるため、`nas:3080` 固定で運用している。

## 目標（将来パスキーに移す場合）

1. 端末ごとに資格情報を持つ（1 台の漏洩が他端末に波及しない）
2. 端末の追加・失効ができる
3. スマホ・タブレット・PC のどれでも、初回だけ登録すれば以後は生体認証 1 回で入れる

## 選択肢

### A. リバースプロキシに認証レイヤを置く（推奨）

dsh の手前に認証プロキシを挟み、WebAuthn（パスキー）でログインさせる。
dsh 側は今までどおり `dsh-auth` cookie を受け取るので、Caddy の注入処理は
「認証プロキシが正当なヘッダを付けたリクエストにだけ注入する」形へ縮小する。

- 例: `tinyauth`（単一バイナリ・軽量・WebAuthn 対応）、`Authelia`、`Authentik`
- 長所: dsh 本体に手を入れない。失効はユーザー DB から消すだけ。
- 短所: コンテナが 1 つ増える。初回登録フローの導線設計が必要。

### B. mTLS（端末証明書）

各端末にクライアント証明書を配る。Caddy で `client_auth` を要求する。

- 長所: 実装が最小。コンテナ追加なし。
- 短所: スマホへの証明書インストールが面倒。パスキーより UX が悪い。

### C. dsh 本体の認証を外部 IdP に委ねる

dsh のセッション機能を外部 OIDC に接続する。

- 長所: 将来 dsh が公式対応すれば最短。
- 短所: 現行 0.2.1-rc.4 に外部 IdP 連携の口が見当たらない（未確認）。上流待ちになる。

## 推奨: A（tinyauth + Caddy forward_auth）

```
ブラウザ → Caddy(:3080)
             ├─ /auth/*        → tinyauth（WebAuthn ログイン）
             └─ それ以外        → forward_auth で tinyauth に確認
                                   ├ 401 → ログインページへ
                                   └ 200 → dsh(:3081) へ。Caddy が dsh-auth cookie を注入
```

作業量の目安:

1. `tinyauth` サービスを compose に追加（ユーザー登録は初回のみ）
2. Caddyfile に `forward_auth` とログイン導線を追加
3. `bootstrap.js` の cookie 注入を「forward_auth 通過後のみ」に限定
4. README の「どの端末からでも認証なしで使う」節を書き換え

## 残っている決定事項

- **既存端末の移行**: 全端末で再登録が要る。移行期間を設けるか一斉に切り替えるか。
- **認証の適用範囲**: dsh 全体か、`/api/*` だけか。右上の UI だけ守っても意味が薄い。
- **バックアップ経路**: パスキーを失った端末の復旧手段（回復コードを置くか）。
- **LAN 外公開**: 現状 LAN 前提。公開するなら TLS が必須で、WebAuthn も
  `https://` か `localhost` でしか動かない（`http://nas:3080` では**登録できない**）。
  → **この点が最大の障害**。まず HTTPS 化（Caddy の内部 CA か自己署名 + 端末への信頼導入）を
  決めないと、パスキーは動かない。
