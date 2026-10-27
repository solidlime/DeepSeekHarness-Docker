'use strict';
// dsh を起動して、初回ログイン用トークンを Caddy に注入する。
//
// なぜ必要か: dsh のブラウザセッション cookie は authority に束縛され、
// その署名鍵は DSH_HOME/.credentials.yaml に永続化される。つまり鍵は固定で、
// 端末ごとに「一度だけ」トークン付き URL を踏めば cookie が発行される。
// トークン自体は起動のたびに変わる（プロセスメモリのみ）ので、
// 起動時に取り出して Caddyfile の header_up に書き込む。
//
// 副産物: dsh のログが親プロセスのパイプに流れるため、`docker logs` で見える。

const { spawn } = require('node:child_process');
const { readFileSync, writeFileSync, renameSync } = require('node:fs');
const { createHash, createHmac } = require('node:crypto');

const CADDYFILE = '/etc/caddy/Caddyfile';
const CADDYFILE_IN = '/etc/caddy/Caddyfile.dsh';
const MARKER = '# ==== dsh bootstrap ====';
// dsh は expiresAt - issuedAt が maxAgeMilliseconds（既定 30 日）を超えると
// その cookie を検証エラーで捨てる（decodeCookie の後の期間チェック）。
// 起動のたびに作り直すので、1回の寿命は 30 日未満なら十分。
const COOKIE_TTL_MS = 29 * 24 * 60 * 60 * 1000;

// 「The Web UI is available at http://nas:3080/?token=xxx」からトークンを取り出す。
function parseLaunchToken(text) {
	const m = text.match(/https?:\/\/[^\s?]*\/\?token=([A-Za-z0-9_-]{10,})/);
	return m === null ? undefined : m[1];
}

function readSecret(credentialsPath) {
	const raw = readFileSync(credentialsPath, 'utf8');
	const section = raw.slice(raw.indexOf('browser-session:'));
	const m = section.match(/secret:\s*([A-Za-z0-9_+/=-]+)/);
	if (m === null) throw new Error('browser-session secret not found');
	// dsh は secret を base64url で保存し、デコードした 32 バイトを HMAC 鍵にする
	// (canonicalSecret)。'base64' でデコードすると '-' と '_' が黙って捨てられて
	// 鍵が変わり、生成した cookie が dsh に 401 で蹴られる。
	const secret = Buffer.from(m[1], 'base64url');
	if (secret.byteLength !== 32) {
		throw new Error(`browser-session secret is ${secret.byteLength} bytes, expected 32`);
	}
	return secret;
}

// dsh の sessionCookie() と同じ形式。payload は JSON の base64url、
// 署名は base64url(HMAC-SHA256(secret, payload))。
function sessionCookie(authority, secret, now = Date.now()) {
	const b64 = (buf) => Buffer.from(buf).toString('base64')
		.replaceAll('+', '-').replaceAll('/', '_').replace(/=+$/u, '');
	const name = 'dsh-auth-' + b64(createHash('sha256').update(authority).digest());
	const issuedAt = now;
	const expiresAt = now + COOKIE_TTL_MS;
	const payload = b64(JSON.stringify({ version: 1, authority, issuedAt, expiresAt }));
	const sig = b64(createHmac('sha256', secret).update(payload).digest());
	return { name, value: `v1.${payload}.${sig}`, expiresAt };
}

// トークンではなく cookie を注入する理由: トークン URL へのリダイレクト方式だと
// （1）起動直後の注入では取りこぼす再起動がある、（2）Caddy の設定にトークンを
// 書くことになり curl で 401 を expect している healthcheck が壊れる。
function caddyfile(base, authority, cookie) {
	const head = base.split(MARKER)[0].trimEnd();
	const site = `:${authority.split(':')[1] ?? '3080'}`;
	const block = [
		MARKER,
		`# このセクションは bootstrap.js が起動のたびに書き換える（手で編集しない）。`,
		`# 全リクエストに認証済み cookie を注入するので、どの端末でもトークン URL は不要。`,
		`# 有効期限: ${new Date(cookie.expiresAt).toISOString()} (毎起動で更新)`,
		site + ' {',
		'\treverse_proxy 127.0.0.1:3081 {',
		'\t\theader_up Host {http.request.hostport}',
		`\t\theader_up Cookie "${cookie.name}=${cookie.value}"`,
		'\t}',
		'}',
		'',
	].join('\n');
	return head + '\n\n' + block;
}

function writeCaddyfile(content) {
	writeFileSync(CADDYFILE + '.tmp', content);
	renameSync(CADDYFILE + '.tmp', CADDYFILE);
}

function selftest() {
	const assert = require('node:assert');
	const tok = parseLaunchToken('The Web UI is available at http://nas:3080/?token=Ab3dEf6gHi9jKl');
	assert.strictEqual(tok, 'Ab3dEf6gHi9jKl');
	assert.strictEqual(parseLaunchToken('no url here'), undefined);
	const secret = Buffer.alloc(32, 7);
	// credentials.yaml の secret は base64url。往復して元の 32 バイトに戻ることを見る。
	assert.strictEqual(
		Buffer.from(secret.toString('base64url'), 'base64url').equals(secret), true,
	);
	const c = sessionCookie('nas:3080', secret, 1000);
	assert.match(c.name, /^dsh-auth-[A-Za-z0-9_-]{43}$/);
	assert.match(c.value, /^v1\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]{43}$/);
	let payload;
	try {
		payload = JSON.parse(Buffer.from(c.value.split('.')[1], 'base64').toString('utf8'));
	} catch {
		assert.fail('payload is not JSON');
	}
	assert.strictEqual(payload.authority, 'nas:3080');
	assert.strictEqual(payload.expiresAt - payload.issuedAt, COOKIE_TTL_MS);
	const cf = caddyfile('{"apps":{}}\n' + MARKER + '\n:3080 {\n\tfile_server\n}\n', 'nas:3080', c);
	assert.ok(cf.includes(`header_up Cookie "${c.name}=${c.value}"`));
	assert.strictEqual(cf.split(MARKER).length, 2, 'marker must appear once');
	console.log('selftest ok');
}

if (process.env.DSH_BOOTSTRAP_SELFTEST === '1') {
	selftest();
	process.exit(0);
}

const authority = process.env.DSH_TRUSTED_HOST || 'nas:3080';
const credentialsPath = (process.env.DSH_HOME || '/root/.dsh') + '/.credentials.yaml';

const child = spawn(
	'dsh',
	[
		'--profile', 'web',
		'--host', '127.0.0.1',
		'--port', '3081',
		'--trusted-host', authority,
		'--no-open',
	],
	{ stdio: ['inherit', 'pipe', 'pipe'] },
);

let patched = false;

function watch(chunk) {
	if (patched) return;
	const text = chunk.toString();
	const token = parseLaunchToken(text);
	if (token === undefined) {
		// 期限が来ていた cookie は起動時刻起点に延ばす価値がない（実質 10000 年なので無い）。
		return;
	}
	try {
		const cookie = sessionCookie(authority, readSecret(credentialsPath));
		writeCaddyfile(caddyfile(readFileSync(CADDYFILE_IN, 'utf8'), authority, cookie));
		patched = true;
		console.log(`bootstrap: injected session cookie for ${authority} (expires ${new Date(cookie.expiresAt).toISOString()})`);
	} catch (err) {
		// 注入に失敗しても dsh 自体は動く。トークン URL での初回ログインに戻るだけ。
		console.error(`bootstrap: cookie injection failed: ${err.message}`);
	}
}

const forward = (stream, out) => stream.on('data', (chunk) => { watch(chunk); out.write(chunk); });
forward(child.stdout, process.stdout);
forward(child.stderr, process.stderr);

// Caddy は dsh の起動より前に動いている必要がある（:3080 を先に確保する）ので、
// entrypoint 側で待ち受けてから起動済み。設定変更は自動リロードで反映される。
const shutdown = (signal) => { child.kill(signal); };
process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
child.on('exit', (code, signal) => process.exit(signal === null ? (code ?? 1) : 1));
