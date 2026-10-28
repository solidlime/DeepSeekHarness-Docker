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
# unzip: entrypoint が初回起動時に Chrome を永続ボリュームへ展開する
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      python3 make g++ ca-certificates curl gnupg tini unzip \
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

# `dsh plugin` は残余引数をそのまま pnpm に転送するだけなので、pnpm が無いと
# プラグインはひとつも入らない。数 MB で毎回入れ直す理由も無いのでイメージに焼く。
# （dsh 本体は数百 MB なので引き続き起動時に永続ボリュームへ入れる）
RUN npm install -g pnpm@10 \
 && pnpm --version

# インストール手順を固定するための manifest。イメージにはこれだけ置き、
# 依存の実体は起動時に $DSH_RUNTIME へ入れる。
# .npmrc は作らない・持ち込まない（legacy-peer-deps / global-style があると install が壊れる）。
COPY package.json /opt/dsh/manifest/package.json

# プラグインの manifest。dsh 本体（$DSH_RUNTIME）とは別レイヤーで、
# profile 側（$DSH_HOME/profiles/web）に置く。ここを唯一の源にして
# 起動時に差分を同期する（名前を変えただけのパッケージ名なので manifest と
# profile の実体がずれる事故が起きやすい。二重管理はやめた）。
COPY dsh/profile-package.json /opt/dsh/presets/package.json

# dsh の作業ディレクトリ。/root ごとボリューム永続化する前提。
WORKDIR /root/workspace

# Caddyfile は「種」として置く。実体の /etc/caddy/Caddyfile は起動のたびに
# entrypoint が種から作り、bootstrap.js が cookie 行を足す。
# 人格 preset や AGENTS.md、プラグインの一覧は焼き込まない（バニラの dsh）。
# 設定・拡張はすべて UI から入れる。

COPY Caddyfile /etc/caddy/Caddyfile.dsh
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
COPY bootstrap.js /usr/local/bin/bootstrap.js
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

EXPOSE 3080

ENTRYPOINT ["tini", "--", "/usr/local/bin/docker-entrypoint.sh"]
