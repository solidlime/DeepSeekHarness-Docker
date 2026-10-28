#!/bin/sh
set -e

# DSH_HOME が無いと初回起動時に dsh が落ちるので先に作る。
mkdir -p "$DSH_HOME"

# bind mount は umask 0022 で 755 になり、dsh は mode 0600 以外の
# .credentials.yaml を検出して起動を拒否する
# （credentials-local: <path> is readable beyond its owner (mode 755)）。
# ホスト側のパーミッションに依存しないよう、起動のたびに締め直す。
CRED="$DSH_HOME/.credentials.yaml"
if [ -f "$CRED" ]; then
	chmod 600 "$CRED"

	# LiteLLM のマスターキーを credentials の refs: に名前で登録する。
	# .credentials.yaml には records:（<scope>/<id> → レコード）と
	# refs:（名前 → 値）の 2 種類のセクションがあり、llm-pi-ai の
	# apiKeyEnv が引くのは refs: のほう。records: に書くと
	# 'credential key "X" must be "<scope>/<id>"' で起動が失敗する。
	# 値が空や壊れた（バックスラッシュ 1文字）場合は書かない。Portainer が
	# 未設定の ${DSH_LITELLM_KEY:-} をバックスラッシュに化けさせ、その値で
	# refs: を上書きして LiteLLM が 401 になった。キーはこのファイルを正とする。
	case "$DSH_LITELLM_KEY" in
	'') echo "bootstrap: DSH_LITELLM_KEY is empty, leaving $CRED as is" ;;
	'\\') echo "bootstrap: DSH_LITELLM_KEY is a stray backslash, leaving $CRED as is" ;;
	*)
		if grep -q '^  DSH_LITELLM_KEY:' "$CRED"; then
			awk -v k="$DSH_LITELLM_KEY" '/^  DSH_LITELLM_KEY:/{print "  DSH_LITELLM_KEY: " k; next} {print}' \
				"$CRED" > "$CRED.tmp"
		elif grep -q '^refs:' "$CRED"; then
			awk -v k="$DSH_LITELLM_KEY" '/^refs:/{print; print "  DSH_LITELLM_KEY: " k; next} {print}' \
				"$CRED" > "$CRED.tmp"
		else
			awk -v k="$DSH_LITELLM_KEY" '{print} /^version:/{print "refs:"; print "  DSH_LITELLM_KEY: " k}' \
				"$CRED" > "$CRED.tmp"
		fi
		mv "$CRED.tmp" "$CRED"
		chmod 600 "$CRED"
		echo "bootstrap: registered DSH_LITELLM_KEY in $CRED"
		esac
fi

# --- dsh のインストール（初回だけ）---------------------------------------
# イメージに dsh を焼くと数百 MB になり pull が毎回遅い。実体は永続ボリューム
# ($DSH_RUNTIME = $DSH_HOME/runtime) に置き、2 回目以降のコンテナ再作成では
# 丸ごとスキップする。更新したいときは DSH_RUNTIME_REFRESH=1 で起動する。
mkdir -p "$DSH_RUNTIME"

# manifest が変わったとき（package.json の更新）は入れ直す。
MANIFEST_SUM=$(sha256sum /opt/dsh/manifest/package.json | cut -d' ' -f1)
if [ "$DSH_RUNTIME_REFRESH" = "1" ] || [ ! -x "$DSH_RUNTIME/node_modules/.bin/dsh" ] \
	|| [ "$(cat "$DSH_RUNTIME/.manifest-sha256" 2>/dev/null)" != "$MANIFEST_SUM" ]; then
	echo "bootstrap: installing dsh into $DSH_RUNTIME (this takes a few minutes on first run)"
	cp /opt/dsh/manifest/package.json "$DSH_RUNTIME/package.json"
	cd "$DSH_RUNTIME"
	# 依存解決は peer 依存の都合で global では壊れるので、ローカルに hoisted で入れる。
	npm install --install-strategy=hoisted --no-legacy-peer-deps --no-fund --no-audit
	printf '%s' "$MANIFEST_SUM" > "$DSH_RUNTIME/.manifest-sha256"
	node -p "'bootstrap: dsh runtime ready: ' + require('$DSH_RUNTIME/node_modules/@deepseek-ai/dsh/package.json').version"
else
	echo "bootstrap: reusing dsh runtime at $DSH_RUNTIME"
fi

export PATH="$DSH_RUNTIME/node_modules/.bin:$PATH"

# 人格 preset と運用ルールを初回だけ配る。
# profile が既にあるなら（= 一度起動済みなら）ユーザーの編集を尊重して触らない。
# 入れ直したいときは DSH_PROFILE_RESET=1 で起動する。
PROFILE_DIR="$DSH_HOME/profiles/web"
mkdir -p "$PROFILE_DIR"
if [ "$DSH_PROFILE_RESET" = "1" ] || [ ! -s "$PROFILE_DIR/cordis.patch.yml" ]; then
	cp /opt/dsh/presets/cordis.patch.yml "$PROFILE_DIR/cordis.patch.yml"
	echo "bootstrap: installed agent presets into $PROFILE_DIR"
fi

# dsh-plugin add はプロファイル側の pnpm-workspace.yaml でビルドスクリプトを
# 許可する。無いと dsh-web-all（cloudflared/ssh2/cpu-features）の初回 add が
# ERR_PNPM_IGNORED_BUILDS で半端に終わり、bundles に載らず黙って効かなくなる。
# 既存があれば触らない（ユーザーの編集を尊重）。
if [ ! -s "$PROFILE_DIR/pnpm-workspace.yaml" ]; then
	cp /opt/dsh/presets/pnpm-workspace.yaml "$PROFILE_DIR/pnpm-workspace.yaml"
	echo "bootstrap: installed pnpm-workspace.yaml into $PROFILE_DIR"
fi
if [ "$DSH_PROFILE_RESET" = "1" ] || [ ! -s "$DSH_HOME/AGENTS.md" ]; then
	cp /opt/dsh/presets/AGENTS.md "$DSH_HOME/AGENTS.md"
	echo "bootstrap: installed AGENTS.md into $DSH_HOME"
fi

# --- Chromium（ブラウザビューの実体）----------------------------------
# dsh-plugin-browser は PUPPETEER_EXECUTABLE_PATH の Chrome を起動し、その
# 画面を screencast で右サイドバーに配信する。イメージに焼くと pull が
# 300MB 近く重くなるので、永続ボリュームに初回だけ入れて使い回す。
# apt の依存パッケージはコンテナ再作成で消えるので毎回入れる。
CHROME_ROOT="$DSH_HOME/browsers"
find_chrome() {
	find "$CHROME_ROOT" -name chrome -type f -perm -u+x 2>/dev/null | head -1
}
CHROME_BIN="$(find_chrome)"
if [ -z "$CHROME_BIN" ]; then
	echo "bootstrap: installing chrome into $CHROME_ROOT"
	npx --yes @puppeteer/browsers install chrome@stable --path "$CHROME_ROOT" \
		> /tmp/chrome-install.log 2>&1 || echo "bootstrap: chrome install failed"
	CHROME_BIN="$(find_chrome)"
fi
if [ -n "$CHROME_BIN" ]; then
	apt-get update -qq >> /tmp/chrome-install.log 2>&1 \
		&& apt-get install -y -qq --no-install-recommends \
		libglib2.0-0 libnss3 libatk1.0-0 libatk-bridge2.0-0 libcups2 libdrm2 \
		libxkbcommon0 libxcomposite1 libxdamage1 libxfixes3 libxrandr2 \
		libgbm1 libpango-1.0-0 libcairo2 libasound2 libnspr4 libx11-xcb1 \
		unzip >> /tmp/chrome-install.log 2>&1 \
		|| echo "bootstrap: chrome deps install failed"
	# コンテナでは SUID sandbox が使えないのでラッパーで無効化する。
	printf '#!/bin/sh\nexec %s --no-sandbox --disable-setuid-sandbox --disable-dev-shm-usage "$@"\n' \
		"$CHROME_BIN" > /usr/bin/chromium
	chmod +x /usr/bin/chromium
	export PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium
	echo "bootstrap: chrome ready: $CHROME_BIN"
else
	echo "bootstrap: chrome unavailable, browser view stays disabled"
fi

cd /root/workspace

# モバイル崩れの応急処置 CSS を <link> で読ませる。
# dsh 本体の index.html は $DSH_RUNTIME 側にあり、npm install で入れ替わるので
# イメージに焼けない。毎回ここで差し込む。冪等（既に在れば何もしない）。
# 上流が直ったら dsh/mobile-fix.css とこのブロックを消せばよい。
MOBILE_FIX_HTML="$DSH_RUNTIME/node_modules/@deepseek-ai/dsh-web-frontend/dist/index.html"
if [ -f "$MOBILE_FIX_HTML" ] && ! grep -q 'dsh-mobile-fix.css' "$MOBILE_FIX_HTML"; then
	node -e '
		const fs = require("node:fs");
		const p = process.argv[1];
		const tag = "    <link rel=\"stylesheet\" href=\"/dsh-mobile-fix.css\" />\n";
		fs.writeFileSync(p, fs.readFileSync(p, "utf8").replace("</head>", tag + "  </head>"));
	' "$MOBILE_FIX_HTML"
	echo "bootstrap: injected mobile-fix stylesheet into index.html"
fi

# Caddyfile は毎回イメージ同梱の種から作り直す（コンテナ内なので永続化不要）。
# cookie 行は bootstrap.js が起動時に書き足す。
cp /etc/caddy/Caddyfile.dsh /etc/caddy/Caddyfile

# 前面 (:3080) は Caddy が受け持ち、dsh は 0.0.0.0 bind を拒否して
# 127.0.0.1 専用で動くため、両者を同時に走らせる必要がある。
# Caddy は設定ファイルの変更を自動でリロードするので、
# bootstrap.js が後から cookie 行を書き込めば無停止で反映される。
caddy run --config /etc/caddy/Caddyfile --adapter caddyfile &

# Caddy は cookie 行を書く前に起動している必要がある。:3080 の listen を
# 軽く待つ（待たないと初回リクエストがコネクション拒否になり得る）。
i=0
while [ $i -lt 50 ]; do
	if curl -sS -o /dev/null --max-time 1 -H "Host: 127.0.0.1:3080" http://127.0.0.1:3080/ 2>/dev/null; then
		break
	fi
	i=$((i + 1))
	sleep 0.1
done

# 起動トークンを Caddy に注入しつつ dsh を前面で動かす。
exec node /usr/local/bin/bootstrap.js
