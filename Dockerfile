FROM node:24-bookworm-slim

# dsh のバージョンは固定しない。package.json が dist-tag `latest` を指し、
# ビルドのたびに npm レジストリの最新を解決する（更新は再ビルド＝CI で入る）。

# python3/make/g++: node-pty 等のビルド保険（prebuilt が使えなかった場合に備える）
# ca-certificates/curl: Caddy リポジトリ取得用
# tini: PID 1 としてゾンビ回収とシグナル転送を行う
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      python3 make g++ ca-certificates curl gnupg tini \
 && rm -rf /var/lib/apt/lists/*

# Caddy 公式 apt リポジトリ（curl | sh は使わない。鍵は gpg --dearmor で配置する）
RUN curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/gpg.key \
      | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg \
 && curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt \
      > /etc/apt/sources.list.d/caddy-stable.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends caddy \
 && rm -rf /var/lib/apt/lists/*

# dsh は peer 依存の解決に失敗するため npm install -g は使わない。
# ローカルの package.json + allowScripts でインストールする。
# .npmrc は作らない・持ち込まない（legacy-peer-deps / global-style があると install が壊れる）。
WORKDIR /opt/dsh
COPY package.json /opt/dsh/package.json
RUN npm install --install-strategy=hoisted --no-legacy-peer-deps --no-fund --no-audit

RUN ln -s /opt/dsh/node_modules/.bin/dsh /usr/local/bin/dsh \
 && node -p "'dsh runtime: ' + require('/opt/dsh/node_modules/@deepseek-ai/dsh/package.json').version"

ENV DSH_HOME=/root/.dsh

# dsh の作業ディレクトリ。/root ごとボリューム永続化する前提。
WORKDIR /root/workspace

COPY Caddyfile /etc/caddy/Caddyfile
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

EXPOSE 3080

ENTRYPOINT ["tini", "--", "/usr/local/bin/docker-entrypoint.sh"]
