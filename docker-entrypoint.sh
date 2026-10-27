#!/bin/sh
set -e

# DSH_HOME が無いと初回起動時に dsh が落ちるので先に作る。
mkdir -p "$DSH_HOME"

# bind mount は umask 0022 で 755 になり、dsh は mode 0600 以外の
# .credentials.yaml を検出して起動を拒否する
# （credentials-local: <path> is readable beyond its owner (mode 755)）。
# ホスト側のパーミッションに依存しないよう、起動のたびに締め直す。
if [ -f "$DSH_HOME/.credentials.yaml" ]; then
	chmod 600 "$DSH_HOME/.credentials.yaml"
fi

# --- dsh のインストール（初回だけ）---------------------------------------
# イメージに dsh を焼くと数百 MB になり pull が毎回遅い。実体は永続ボリューム
# ($DSH_RUNTIME = $DSH_HOME/runtime) に置き、2 回目以降のコンテナ再作成では
# 丸ごとスキップする。更新したいときは DSH_RUNTIME_REFRESH=1 で起動する。
mkdir -p "$DSH_RUNTIME"

# manifest が変わったとき（package.json の更新）は入れ直す。
MANIFEST_SUM=$(sha256sum /opt/dsh/package.json | cut -d' ' -f1)
if [ "$DSH_RUNTIME_REFRESH" = "1" ] || [ ! -x "$DSH_RUNTIME/node_modules/.bin/dsh" ] \
	|| [ "$(cat "$DSH_RUNTIME/.manifest-sha256" 2>/dev/null)" != "$MANIFEST_SUM" ]; then
	echo "bootstrap: installing dsh into $DSH_RUNTIME (this takes a few minutes on first run)"
	cp /opt/dsh/package.json "$DSH_RUNTIME/package.json"
	cd "$DSH_RUNTIME"
	# 依存解決は peer 依存の都合で global では壊れるので、ローカルに hoisted で入れる。
	npm install --install-strategy=hoisted --no-legacy-peer-deps --no-fund --no-audit
	printf '%s' "$MANIFEST_SUM" > "$DSH_RUNTIME/.manifest-sha256"
	node -p "'bootstrap: dsh runtime ready: ' + require('$DSH_RUNTIME/node_modules/@deepseek-ai/dsh/package.json').version"
else
	echo "bootstrap: reusing dsh runtime at $DSH_RUNTIME"
fi

export PATH="$DSH_RUNTIME/node_modules/.bin:$PATH"
cd /root/workspace

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
