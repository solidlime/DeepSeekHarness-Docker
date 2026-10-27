# DeepSeek Harness (dsh) NAS 常駐コンテナ

[`@deepseek-ai/dsh`](https://www.npmjs.com/package/@deepseek-ai/dsh) v0.2.0-rc.2 を
NAS 上で常駐させ、LAN 内のブラウザから使うための Docker 構成。
dsh 本体はループバックにしかバインドできない設計なので、前段の Caddy が外部
(:3080) を受け持つ。`docker compose up -d` だけで常駐し、再起動しても
初回ログインのクッキーが生き続ける。

**dsh はイメージに焼かず、初回起動時に永続ボリュームへインストールする。**
これをやるとイメージが数十 MB に収まり、pull とビルドが一桁秒で終わる。
インストール先は `$DSH_HOME/runtime`（= `/root/.dsh/runtime`）で、`/root` ごと
永続化しているので**コンテナを作り直しても npm install は走らない**。

## 外部アクセスの仕組み

| 層 | 挙動 |
| --- | --- |
| dsh (`--profile web`) | `--host 0.0.0.0` は**明示的に拒否される**（RCE 露出防止の設計）。使えるのは 127.0.0.1 バインドのみ → コンテナ内 `127.0.0.1:3081` |
| Caddy | `:3080`（= 0.0.0.0）で受け、`127.0.0.1:3081` へ reverse_proxy。`header_up Host {http.request.hostport}` でクライアントの Host を**ポート込みで**保持して転送 |
| bootstrap.js | dsh を起動し、起動トークンを拾って**認証済み cookie を Caddy に注入**する（後述） |
| docker-entrypoint.sh | 初回だけ `$DSH_HOME/runtime` へ `npm install`。manifest の sha256 を保存し、`package.json` が変わったか `DSH_RUNTIME_REFRESH=1` のときだけ入れ直す |
| dsh の Host 検証 | `--trusted-host <authority>` に一致する Host だけ受け付ける。既定は `nas:3080`（`DSH_TRUSTED_HOST` で変更可） |

Caddy の `header_up Host` が無いと、Host が `127.0.0.1:3081` になって
dsh の `--trusted-host` 検証に落ちる。必ず残すこと。

**`{host}` ではなく `{http.request.hostport}` を使うこと。** Caddy の `{host}` は
ポートを落とすので、`header_up Host {host}` だと dsh には `nas` が届き、
trusted host の `nas:3080` と一致しない。症状は UI の「Reconnecting...」と
プラグイン一覧の「Could not read all plugins, possibly due to a network problem」
（WebSocket `/api/remote.mux` が 403）。ドキュメント本体とクッキー発行は
Host 検査を通ってしまうので、画面上は「繋がっていないだけ」に見えるのが厄介。

## トークンとクッキーの挙動（実測済み）

- dsh は起動のたびに新しいトークンを発行し、stdout に
  `dsh web: http://127.0.0.1:PORT/?token=...` を出す。ログで確認できる。
- トークン付き URL でログインすると 303 → 以降はクッキーで 200。
- クッキーは `DSH_HOME` 配下の secret で署名される。**プロセスを再起動しても
  旧クッキーは有効**（実測: 新しいトークン発行後も旧クッキーで 200）。
- したがって `DSH_HOME` をボリューム永続化すれば、トークン入力は初回の一度だけ。
  本構成は `/root` ごと `/volume1/docker/dsh/root` に永続化している。

## どの端末からでも認証なしで使う（本構成の既定動作）

トークンを毎回コピーするのは面倒なので、**このイメージは認証済み cookie を
自動で Caddy に注入する**。仕組みは `bootstrap.js`:

1. dsh の起動ログから `?token=...` を拾う（トークンが出た直後にだけ動く）。
2. `DSH_HOME/.credentials.yaml` の署名鍵で、**期限 10000 年**のセッション cookie を
   自分で生成する（dsh の `sessionCookie()` と同じ形式）。
3. `Caddyfile` の `# ==== dsh bootstrap ====` 以降を書き換え、
   `header_up Cookie "dsh-auth-...=v1...."` を入れる。

Caddy は設定ファイルの変更を自動リロードするので、**再起動のたびに新しい cookie が
無停止で反映される**。ブラウザの cookie は不要で、どの端末・どのブラウザからも
`http://nas:3080/` を開くだけでログイン画面を経ずに入れる。

**注意点**

- cookie の authority は `DSH_TRUSTED_HOST`（既定 `nas:3080`）で固定される。
  `192.168.1.x:3080` など別の authority でアクセスすると Host 検査で 403 になる。
  LAN の別名で使いたいときは `DSH_TRUSTED_HOST` にその authority を足し、
  同じ端末で 1 度だけトークン URL を踏んで cookie を発行させること。
- cookie は署名鍵が漏れれば誰でも偽造できる。LAN 内専用の前提を崩すなら
  この注入を無効化し（Caddyfile から `header_up Cookie` 行を消す）、
  トークン URL 運用に戻すこと。

注入に失敗しても dsh は動く（自動的にトークン URL 運用に戻るだけ）。
失敗は `docker compose logs dsh | grep bootstrap` で確認する。

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
  起動時インストールもローカルの `package.json` を `$DSH_RUNTIME` に置いて
  hoisted で入れる方式にしている。
- **dsh を更新したいときは `DSH_RUNTIME_REFRESH=1`。** `latest` は初回の
  インストール時にしか解決されない（再起動では変わらない）。
  ローカルインストール（`package.json` + `allowScripts`）で組む。
  `allowScripts` を落とすと postinstall が走らず PTY が壊れる。
- node-pty は prebuilt で PTY が動く（ネイティブビルド不要）。`python3` は
  ビルドが必要になった場合の保険として入れている。
- `socat` はベースイメージに無い。プロキシは Caddy で行う。

## 更新

dsh 本体は起動時に永続ボリュームへ入るので、**イメージの更新と dsh の更新は別**。

```sh
# イメージ（Caddy・Node・起動スクリプト）だけ更新。数秒で終わる。
docker compose pull && docker compose up -d

# ついでに dsh 本体も最新へ（初回と同じく数分の npm install が走る）
DSH_RUNTIME_REFRESH=1 docker compose up -d --force-recreate
```

`DSH_RUNTIME_REFRESH=1` は一度きりなので、終わったら `0` に戻す
（`.env` に入れると毎回インストールしてしまう）。

## エージェントプリセット（人格の移植）

`dsh/presets/` をイメージに焼き込み、**初回起動時にだけ** profile と `$DSH_HOME` へ配る。

| 焼き込み先 | 配り先 | 中身 |
| --- | --- | --- |
| `dsh/presets/cordis.patch.yml` | `$DSH_HOME/profiles/web/cordis.patch.yml` | 8 体の preset（ヘルタ・人形#001/#002/#009/#011/#042/#057・ルアン・メェイ） |
| `dsh/presets/AGENTS.md` | `$DSH_HOME/AGENTS.md` | 運用ルールのみ（人格は preset 側の `persona.prefix`） |

既にファイルがあれば**触らない**（ユーザーが UI から足したプラグイン設定を潰さないため）。
入れ直すときは `DSH_PROFILE_RESET=1` で起動する。

- preset は `cordis.patch.yml` の**トップレベル配列のエントリ**として書く。
  `presets:` のような専用キーは存在せず、書いても静かに無視される（実測）。
- 人格は `persona.prefix` に入れる。`AGENTS.md` に人格を書くと preset 切り替えと二重になる。

## 既知の制約

- **amd64 のみ**を想定。node-pty の prebuilt と本イメージの検証は amd64 で行った。
- 複数の authority（例: `nas:3080` と `192.168.1.10:3080` の両方）を許可したい
  場合、`DSH_TRUSTED_HOST` にカンマ区切りで渡しても効かない（`--trusted-host` の
  1引数として扱われ、`is not a bare host[:port] authority` で起動時に落ちる）。
  `docker-entrypoint.sh` の `dsh` 呼び出しに `--trusted-host` を増やすこと。
- `--trusted-host` に載っていない authority でアクセスすると、ドキュメントは
  返るが API が 403 になる（例: IP 直アクセス `http://192.168.1.10:3080/`）。
  ホスト名を固定して使うか、上記の通り `--trusted-host` に追加する。
- dsh は 127.0.0.1 バインド専用なので、コンテナ内ヘルスチェックは Caddy 経由
  (`127.0.0.1:3080`) で行う。Host ヘッダを明示している。

## ライセンス / 帰属

本リポジトリは dsh の配布物ではなく、実行環境の構成のみを含む。
dsh 本体のライセンスは上流に従う。
