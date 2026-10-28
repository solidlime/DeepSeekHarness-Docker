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

## アクセス制御（本構成の既定）

**守りはネットワーク境界だけ**。LAN 内に置き、ルーターでポート転送をしない。
その前提で、dsh のセッション cookie は**注入しない**。

以前は `bootstrap.js` が共有シークレットから署名 cookie を作って全リクエストに
入れていた。これは「URL かシークレットを知っている人が全員通る」方式で、
端末の識別も個別失効もできなかったため廃止した（経緯と代替案は
[`docs/access-control.md`](docs/access-control.md)）。

いまの `bootstrap.js` は `Caddyfile` の `# ==== dsh bootstrap ====` 以降を
毎起動で書き換え、次の 2 行だけを入れる:

```
header_up Host {http.request.hostport}
header_up Cookie ""
```

`Host` は trusted-host (`DSH_TRUSTED_HOST`, 既定 `nas:3080`) と一致させるため。
`Cookie ""` はクライアントが古い `dsh-auth-*` を送ってきても落とすため
（端末によって通る・通らないが分かれるのを防ぐ）。鍵は使わないので、
`.credentials.yaml` が読めることだけ起動確認に使っている。

**別の authority で使いたいとき**は `DSH_TRUSTED_HOST` を変える
（`192.168.1.x:3080` だと Host 検査で 403 になる）。
初回アクセス時にトークンを求められた場合の取り出し方:

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

## 設定は UI で入れる（イメージはバニラ）

イメージには **dsh 本体と実行環境（node / pnpm / caddy / chromium）だけ**を入れる。
プリセット（人格）、`AGENTS.md`、プラグインの一覧は**焼き込まない**。設定も拡張も
`$DSH_HOME` 配下に UI から入れたものがそのまま残る（`/root` ごと永続化しているため）。

| 中身 | 場所 |
| --- | --- |
| プロファイル（plugin 一覧・patch） | `$DSH_HOME/profiles/web/` |
| 運用ルール・人格 | `$DSH_HOME/AGENTS.md` |
| ブラウザの実体 | `$DSH_HOME/browsers/` |

- entrypoint はプロファイルが空のときだけ雛形の `package.json` を作る。既にあれば触らない。
- イメージを更新しても設定とプラグインは引き継がれる。
- どうしても初期化したいときは、そのディレクトリを自分で消してから起動する。

### preset（人格）を書くときの規則

- preset は `cordis.patch.yml` の**トップレベル配列のエントリ**として書く。
  `presets:` のような専用キーは存在せず、書いても静かに無視される（実測）。
- 人格は `persona.prefix` に入れる。

## ds-bot のボットへ人格を配る（`scripts/sync-bots.js`）

ds-bot の各ボットは**作成時の `instructions` を固定で持ち、preset とは連動しない**。
そのため pi 側の人格を変えても ds-bot には伝わらない。`scripts/sync-bots.js` が橋渡しをする。

```sh
# コンテナ内で実行（persona は pi 側の AGENTS.md を置いておく）
docker cp ~/.agents/AGENTS.md dsh:/root/.dsh/source/persona/AGENTS.md
docker exec dsh node /root/.dsh/source/sync-bots.js           # 差分表示だけ
docker exec dsh node /root/.dsh/source/sync-bots.js --apply   # 書き込む
```

- 出来上がる `instructions` は **`AGENTS.md`（ペルソナ本体）+ preset の `persona.prefix`（役割差分）**。
  人格は 1 か所（pi 側の `~/.agents/AGENTS.md`）で管理し、ds-bot はそれを受け取るだけになる。
- ボット名から preset を引く（`Herta` → `herta`、`人形#009（探索）` → `herta-009`、`ルアン・メェイ` → `ruan-mei`）。
  **名前は変えない**ので、何度流しても同じ結果になる（冪等）。
- cookie は `.credentials.yaml` のブラウザセッション鍵から自分で作る。
  ポートに閉じた API（`127.0.0.1:3081`）を叩くだけなので、外に資格情報を出さない。
- ボットを**新規作成**したときは、先に preset 名で作っておけば次回の同期で拾われる。
- `scripts/` は repo に置いてあるが、コンテナへは手動で置く（イメージには入らない）。

## モデル（LiteLLM ゲートウェイ）

dsh のモデルは、 NAS で動いている LiteLLM（`nas:4000`）に相乗りする。
モデルの実体・使用額・追加は LiteLLM 側の管理（`litellm-admin` スキル）。

| 項目 | 値 |
| --- | --- |
| 設定場所 | `$DSH_HOME/settings.yaml` の ns `llm-pi-ai`（UI の Models 画面） |
| 旧場所 | profile の `cordis.patch.yml` の `- id: llm-pi-ai`（起動時に settings.yaml へ移行される） |
| 接続先 | `DSH_LITELLM_URL`（既定 `http://192.168.176.1:4000/v1`） |
| 鍵 | `DSH_LITELLM_KEY`（`.env` で渡す） |
| 既定モデル | `agent-default-model` で `General` |

- `192.168.176.1` は NAS の **docker bridge gateway**（= ホスト自身）。
  dsh コンテナから `nas:4000` は解決できても届かない（ネットワーク分離）。
  ホスト IP が違う環境では `.env` の `DSH_LITELLM_URL` で上書きする。
- LiteLLM のモデル名（`Orchestrator` / `Advisor` / `Plan` / `Fixer` /
  `Designer` / `Explore` / `Librarian` / `General` / `Free`）をそのまま
  `models:` に並べている。LiteLLM 側で増やしたらここにも足す。
- **鍵は `.credentials.yaml` の `refs:` に入れる**。`records:` と間違えると
  `credential key "X" must be "<scope>/<id>"` で dsh が起動しない。
  この登録は `docker-entrypoint.sh` が起動時にやるので、手で書かなくてよい。
- 画像入力は未対応（`input:` 未指定 = テキストのみ）。

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

## プラグイン（右サイドバーと UI 拡張）

`dsh-better-sidebar` と `@linxin666/dsh-web-all` をプロファイルに載せている。
右サイドバーのタブ（Files / Git / New terminal / Tasks / Side Chat / Browser view /
More tools）はブラウザ側のツールバーとして描画される。**初期タブが未選択だと
パネルが空（「Start」だけ）になる**ので、開いた直後に中身が無いように見える。

プラグインの右サイドバーは「表示されない」のではなく、dsh 本体の右バー
(`--trusted-host` と同じ DSH 0.2.1 の docking surface) に同居している。
レイアウトがおかしいと感じたらまずブラウザをハードリロードする
(プラグインのクライアントチャンクはキャッシュされる)。

### モバイル（スマホ・タブレット）

上流の CSS はスマホ幅を想定していない。実測した崩れは次の 4 つ：

- 設定モーダルが `948px` 固定で 390px の画面にはみ出し、2 カラムのまま
  ラベルが 1 文字ずつ折り返されて操作不能になる
- 左サイドバーが `100vh` 基準で下端のアイコンが画面外に落ちる
- 右サイドバーの開閉ボタンが存在しない
- ヘッダのロゴ（クジラ）が会話本文に被る

`dsh-mobile-upgrade` がこれらをまとめて直す。`docker-entrypoint.sh` が
プロファイルに未導入のときだけ `dsh plugin --profile web add` を呼ぶ。
以前は自前の `dsh/mobile-fix.css` を `index.html` に差し込んでいたが、
上流の DOM が変わるたびに追従が必要で実機で直りきらなかったため廃止した。

## ライセンス / 帰属

本リポジトリは dsh の配布物ではなく、実行環境の構成のみを含む。
dsh 本体のライセンスは上流に従う。
