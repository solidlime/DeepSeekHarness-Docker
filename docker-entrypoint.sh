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

# Caddy をバックグラウンドに置く理由: 前面 (:3080) を Caddy が受け持ち、
# dsh は 0.0.0.0 bind を拒否して 127.0.0.1 専用で動くため、
# 両者を同時に走らせる必要がある。dsh を exec して PID 1 相当の
# シグナルと終了コードは dsh に委ねる（tini が孤児を回収する）。
caddy run --config /etc/caddy/Caddyfile --adapter caddyfile &

exec dsh --profile web \
	--host 127.0.0.1 \
	--port 3081 \
	--trusted-host "${DSH_TRUSTED_HOST:-nas:3080}" \
	--no-open
