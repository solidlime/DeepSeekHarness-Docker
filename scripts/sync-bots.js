'use strict';
// ds-bot のボットに、pi 側の人格ファイルを配る。
//   instructions = ~/.agents/AGENTS.md（ペルソナ本体）+ preset の persona 差分
// 使い方: node /tmp/syncbots.js [--apply]
const { readFileSync, writeFileSync } = require('node:fs');
const { execFileSync } = require('node:child_process');
const { createHash, createHmac } = require('node:crypto');

const PATCH = '/root/.dsh/profiles/web/cordis.patch.yml';
const STATE = '/root/.dsh/bot/state.json';
const CREDENTIALS = '/root/.dsh/.credentials.yaml';
const PERSONA = process.env.PERSONA_FILE ?? '/root/.dsh/source/persona/AGENTS.md';

// dsh のブラウザセッション cookie を自分で作る（ポートに閉じた API 用）。
function sessionCookie() {
	const lines = readFileSync(CREDENTIALS, 'utf8').split('\n');
	const at = lines.findIndex(l => l.includes('client-connection/browser-session'));
	const raw = lines.slice(at, at + 8).join('\n').match(/secret:\s*([A-Za-z0-9_-]+)/)[1];
	const secret = Buffer.from(raw.replaceAll('-', '+').replaceAll('_', '/'), 'base64');
	const b64 = b => Buffer.from(b).toString('base64').replaceAll('+', '-').replaceAll('/', '_').replace(/=+$/, '');
	const authority = 'nas:3080';
	const name = `dsh-auth-${b64(createHash('sha256').update(authority).digest())}`;
	const now = Date.now();
	const body = b64(JSON.stringify({ version: 1, authority, issuedAt: now, expiresAt: now + 30 * 864e5 }));
	const sig = b64(createHmac('sha256', secret).update(body).digest());
	return `${name}=v1.${body}.${sig}`;
}

// preset の persona.prefix を拾う（YAML パーサを積まないための最小走査）。
function personas(text) {
	const lines = text.split('\n');
	const out = [];
	let cur;
	for (let i = 0; i < lines.length; i++) {
		const m = lines[i].match(/^ {4}- id: preset-(\S+)$/);
		if (m) { cur = { presetId: m[1], prefix: '' }; out.push(cur); continue; }
		if (cur === undefined || cur.prefix !== '') continue;
		if (/^ {10}- id: persona$/.test(lines[i])) {
			for (let j = i + 1; j < Math.min(i + 8, lines.length); j++) {
				const p = lines[j].match(/^ +prefix: (.+)$/);
				if (p !== null) { cur.prefix = p[1]; break; }
			}
		}
	}
	return new Map(out.filter(p => p.prefix !== '').map(p => [p.presetId, p.prefix]));
}

// 既存ボット名 -> preset。名前は作り直さず、instructions だけ合わせる。
function presetOf(botName) {
	if (botName === 'Herta') return 'herta';
	if (botName === 'ルアン・メェイ') return 'ruan-mei';
	const m = botName.match(/人形#(\d{3})/);
	return m === null ? undefined : `herta-${m[1]}`;
}

function api(endpoint, payload) {
	const body = JSON.stringify({ endpoint, payload });
	const res = execFileSync('curl', [
		'-sS', '-m', '60', '-X', 'POST', '-H', 'content-type: application/json',
		'-H', 'Host: nas:3080', '-H', `Cookie: ${sessionCookie()}`, '-d', body,
		'http://127.0.0.1:3081/api/bot',
	], { encoding: 'utf8' });
	let parsed;
	try { parsed = JSON.parse(res); } catch { throw new Error(`${endpoint}: not JSON: ${res.slice(0, 200)}`); }
	if (parsed.ok === false) throw new Error(`${endpoint}: ${JSON.stringify(parsed.error ?? parsed).slice(0, 300)}`);
	return parsed.result ?? parsed;
}

let base = '';
try { base = readFileSync(PERSONA, 'utf8').trim(); } catch { base = ''; }
if (base === '') { console.error(`persona file missing: ${PERSONA}`); process.exit(2); }

const apply = process.argv.includes('--apply');
const presets = personas(readFileSync(PATCH, 'utf8'));
const state = JSON.parse(readFileSync(STATE, 'utf8'));
const report = [];

for (const bot of Object.values(state.bots ?? {})) {
	const presetId = presetOf(bot.name);
	const suffix = presetId === undefined ? undefined : presets.get(presetId);
	if (suffix === undefined) { report.push(`? ${bot.name} (no preset)`); continue; }
	const instructions = `${base}\n\n---\n\n${suffix}`;
	if (bot.instructions === instructions) { report.push(`= ${bot.name}`); continue; }
	report.push(`~ ${bot.name} (${instructions.length} chars)`);
	if (apply) api('update-bot', { id: bot.id, instructions });
}

console.log(report.join('\n'));
if (apply) writeFileSync('/tmp/syncbots.done', new Date().toISOString());
