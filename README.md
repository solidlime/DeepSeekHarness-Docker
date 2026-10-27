# DeepSeek Harness (dsh) NAS 常駐コンテナ

[`@deepseek-ai/dsh`](https://www.npmjs.com/package/@deepseek-ai/dsh) v0.2.0-rc.2 を
NAS 上で常駐させ、LAN 内のブラウザから使うための Docker 構成。
dsh 本体はループバックにしかバインドできない設計なので、前段の Caddy が外部
(:3080) を受け持つ。`docker compose up -d` だけで常駐し、再起動しても
初回ログインのクッキーが生き続ける。

## 外部アクセスの仕組み

| 層 | 挙動 |
| --- | --- |
| dsh (`--profile web`) | `--host 0.0.0.0` は**明示的に拒否される**（RCE 露出防止の設計）。使えるのは 127.0.0.1 バインドのみ → コンテナ内 `127.0.0.1:3081` |
| Caddy | `:3080`（= 0.0.0.0）で受け、`127.0.0.1:3081` へ reverse_proxy。`header_up Host {host}` でクライアントの Host を保持して転送 |
| dsh の Host 検証 | `--trusted-host <authority>` に一致する Host だけ受け付ける。既定は `nas:3080`（`DSH_TRUSTED_HOST` で変更可） |

Caddy の `header_up Host {host}` が無いと、Host が `127.0.0.1:3081` になって
dsh の `--trusted-host` 検証に落ちる。必ず残すこと。

## トークンとクッキーの挙動（実測済み）

- dsh は起動のたびに新しいトークンを発行し、stdout に
  `dsh web: http://127.0.0.1:PORT/?token=...` を出す。ログで確認できる。
- トークン付き URL でログインすると 303 → 以降はクッキーで 200。
- クッキーは `DSH_HOME` 配下の secret で署名される。**プロセスを再起動しても
  旧クッキーは有効**（実測: 新しいトークン発行後も旧クッキーで 200）。
- したがって `DSH_HOME` をボリューム永続化すれば、トークン入力は初回の一度だけ。
  本構成は `/root` ごと `/volume1/docker/dsh/root` に永続化している。

初回トークンはホスト側で次を実行して取り出す:

```sh
docker compose logs dsh | grep -o 'http://[^ ]*token=[^ ]*'
```

## セットアップ

```sh
cp .env.example .env
# 必要なら .env を編集（DSH_TRUSTED_HOST はブラウザで叩く authority と完全一致）
docker compose up -d
```

`DSH_TRUSTED_HOST` は「ブラウザのアドレスバーに入れるホスト:ポート」と
完全一致させる。例: `http://nas:3080/` で使うなら `nas:3080`。

## 落とし穴

- **`.credentials.yaml` は mode 0600 でないと起動拒否される。**
  `credentials-local: <path> is readable beyond its owner (mode 755); run "chmod 600 <path>" before starting again`
  bind mount は umask 0022 で 755 になるため、entrypoint が起動のたびに
  `chmod 600` で締め直している。ホスト側で手動 chmod しても、コンテナが
  書き直せば戻るので entrypoint 側の処理を消さないこと。
- **`.npmrc` を持ち込むな。** `legacy-peer-deps=true` や `global-style=true` が
  あると dsh のインストールが `npm error invariant` で壊れる。本リポジトリは
  `.npmrc` を作らず、Docker ビルド時も COPY しない。
- **`npm install -g @deepseek-ai/dsh` は使うな。** peer 依存の解決に失敗する。
  ローカルインストール（`package.json` + `allowScripts`）で組む。
  `allowScripts` を落とすと postinstall が走らず PTY が壊れる。
- node-pty は prebuilt で PTY が動く（ネイティブビルド不要）。`python3` は
  ビルドが必要になった場合の保険として入れている。
- `socat` はベースイメージに無い。プロキシは Caddy で行う。

## 更新

```sh
docker compose pull && docker compose up -d
```

dsh 本体のバージョンを上げる場合は `package.json` の
`"@deepseek-ai/dsh"` を書き換えてイメージをビルドし直す
（Dockerfile の `ARG DSH_VERSION` と CI の smoke test の期待値も合わせる）。

## 既知の制約

- **amd64 のみ**を想定。node-pty の prebuilt と本イメージの検証は amd64 で行った。
- 複数の authority（例: `nas:3080` と `192.168.1.10:3080` の両方）を許可したい
  場合、`DSH_TRUSTED_HOST` にカンマ区切りで渡しても効かない。
  `docker-entrypoint.sh` の `dsh` 呼び出しに `--trusted-host` を増やすか、
  Caddy 側で `header_up Host` を単一の authority に固定して対応する。
- dsh は 127.0.0.1 バインド専用なので、コンテナ内ヘルスチェックは Caddy 経由
  (`127.0.0.1:3080`) で行う。Host ヘッダを明示している。

## ライセンス / 帰属

本リポジトリは dsh の配布物ではなく、実行環境の構成のみを含む。
dsh 本体のライセンスは上流に従う。
