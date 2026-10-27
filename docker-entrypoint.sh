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

# Caddyfile.dsh が無い（初回）ときだけ、現行の Caddyfile から種を作る。
# 以降の実体は Caddyfile 側で、bootstrap.js が「:3080 { ... }」部分だけを
# 毎起動書き換える。種が空だと Caddy が起動できないので空ブロックを置く。
if [ ! -f /etc/caddy/Caddyfile.dsh ]; then
	cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.dsh
fi

# 前面 (:3080) は Caddy が受け持ち、dsh は 0.0.0.0 bind を拒否して
# 127.0.0.1 専用で動くため、両者を同時に走らせる必要がある。
# Caddy は設定ファイルの変更を自動でリロードするので、
# bootstrap.js が後から cookie 行を書き込めば無停止で反映される。
caddy run --config /etc/caddy/Caddyfile --adapter caddyfile &

# 起動トークンを Caddy に注入しつつ dsh を前面で動かす。
exec node /usr/local/bin/bootstrap.js
