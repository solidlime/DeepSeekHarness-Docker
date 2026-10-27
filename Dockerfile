FROM node:24-bookworm-slim

# このイメージは「実行環境」だけを持つ。dsh 本体は入れない。
#
# なぜか: dsh の node_modules が数百 MB あり、毎回の pull が遅い。
# 代わりに初回起動時に永続ボリューム側 ($DSH_HOME/runtime) へ npm install し、
# 以降のコンテナ再作成ではインストールをスキップする。更新したいときだけ
# DSH_RUNTIME_REFRESH=1 で作り直す（README 参照）。
#
# イメージが小さくなるので、CI のビルドも pull も数秒で終わる。

# python3/make/g++: node-pty / koffi 等の prebuilt が使えなかった場合のビルド保険
# ca-certificates/curl/gnupg: Caddy リポジトリ取得と npm の TLS 用
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

ENV DSH_HOME=/root/.dsh
# 起動時インストールの実体。$DSH_HOME 配下なので /root を永続化すれば残る。
ENV DSH_RUNTIME=/root/.dsh/runtime

# インストール手順を固定するための manifest。イメージにはこれだけ置き、
# 依存の実体は起動時に $DSH_RUNTIME へ入れる。
# .npmrc は作らない・持ち込まない（legacy-peer-deps / global-style があると install が壊れる）。
COPY package.json /opt/dsh/package.json

# dsh の作業ディレクトリ。/root ごとボリューム永続化する前提。
WORKDIR /root/workspace

# Caddyfile は「種」として置く。実体の /etc/caddy/Caddyfile は起動のたびに
# entrypoint が種から作り、bootstrap.js が cookie 行を足す。
COPY Caddyfile /etc/caddy/Caddyfile.dsh
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
COPY bootstrap.js /usr/local/bin/bootstrap.js
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

EXPOSE 3080

ENTRYPOINT ["tini", "--", "/usr/local/bin/docker-entrypoint.sh"]
