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

const { spawn, spawnSync } = require('node:child_process');
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

// 端末ごとに初回トークン URL を踏ませる方式は廃止した。dsh は cookie の無い
// リクエストに 401 を返すが、そのトークン URL は起動ログに残らず、各端末で
// はぐれる（実際にスマホから開けない状態になった）。代わりに、共有 cookie を
// Caddy が全リクエストに注入する。守りは LAN 境界のみ（ポート転送しないこと）。
// 将来 パスキー/mTLS を入れる場合はこのブロックの前に差し込む。
function caddyfile(base, authority, cookie) {
	const head = base.split(MARKER)[0].trimEnd();
	const site = `:${authority.split(':')[1] ?? '3080'}`;
	const block = [
		MARKER,
		`# このセクションは bootstrap.js が起動のたびに書き換える（手で編集しない）。`,
		`# 守りは LAN 限定（ポート転送しないこと）。パスキー/mTLS はこのブロックの前に差し込む。`,
		site + ' {',
		'\treverse_proxy 127.0.0.1:3081 {',
		'\t\theader_up Host {http.request.hostport}',
		// クライアントの cookie は捨てて、こちらで作ったもので置き換える。
		// 残すと、古い cookie を持つ端末だけが 401 になる差が出る。
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
	// 共有 cookie を注入する（LAN 境界で守る）。クライアントの cookie は置き換える。
	assert.ok(cf.includes(`header_up Cookie "${c.name}=${c.value}"`), 'shared cookie must be injected');
	assert.ok(cf.includes('header_up Host {http.request.hostport}'));
	assert.strictEqual(cf.split(MARKER).length, 2, 'marker must appear once');
	console.log('selftest ok');
}

if (process.env.DSH_BOOTSTRAP_SELFTEST === '1') {
	selftest();
	process.exit(0);
}

// Caddyfile を書き換えただけでは反映されない。Caddy は起動時に一度読むだけで、
// ファイルの監視もしない（autosave.json に残った設定は「読んだ内容」の記録）。
// ここを忘れると、Caddyfile に正しい cookie が書いてあるのに全リクエストが 401 になる。
function reloadCaddy() {
	const r = spawnSync('caddy', ['reload', '--config', CADDYFILE, '--adapter', 'caddyfile'], { encoding: 'utf8' });
	if (r.status !== 0) {
		throw new Error(`caddy reload failed: ${(r.stderr || r.error?.message || '').trim()}`);
	}
}

function inject(authority, credentialsPath) {
	const cookie = sessionCookie(authority, readSecret(credentialsPath));
	writeCaddyfile(caddyfile(readFileSync(CADDYFILE_IN, 'utf8'), authority, cookie));
	reloadCaddy();
	console.log(`bootstrap: injected the shared auth cookie for ${authority} (LAN boundary only)`);
}

const authority = process.env.DSH_TRUSTED_HOST || 'nas:3080';
const credentialsPath = (process.env.DSH_HOME || '/root/.dsh') + '/.credentials.yaml';

// 通常起動（credentials が永続ボリュームに残っている）では dsh を待たずに注入する。
// dsh の起動ログを待つ方式だけだと、Caddy が先に空の Caddyfile で起動しているため
// 書き込みが反映されない（reload が要る）。先に確定させておけば順序の穴が消える。
let patched = false;
try {
	inject(authority, credentialsPath);
	patched = true;
} catch (err) {
	// 初回起動はここに来る（dsh が credentials.yaml を作る前）。下の watch で拾う。
	console.error(`bootstrap: pre-injection skipped: ${err.message}`);
}

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

function watch(chunk) {
	if (patched) return;
	const token = parseLaunchToken(chunk.toString());
	if (token === undefined) return;
	patched = true;
	try {
		inject(authority, credentialsPath);
	} catch (err) {
		// 注入に失敗しても dsh 自体は動く。トークン URL での初回ログインに戻るだけ。
		console.error(`bootstrap: cookie injection failed: ${err.message}`);
	}
}

const forward = (stream, out) => stream.on('data', (chunk) => { watch(chunk); out.write(chunk); });
forward(child.stdout, process.stdout);
forward(child.stderr, process.stderr);
const shutdown = (signal) => { child.kill(signal); };
process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
child.on('exit', (code, signal) => process.exit(signal === null ? (code ?? 1) : 1));
