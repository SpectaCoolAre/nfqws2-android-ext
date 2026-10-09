#!/usr/bin/env node
/*
 * Contract tests between the WebUI and bin/nfqws2-ctl.
 *
 * The WebUI is a single file that parses the module's output and sends command
 * names and values back. Nothing in either file knows about the other, so a
 * rename on one side only shows up as a broken UI on a phone. These checks run
 * the *real* ctl in a sandbox and compare it against what index.html expects.
 */
'use strict';

const fs = require('fs');
const path = require('path');

const REPO = path.resolve(__dirname, '..', '..');
const INDEX = path.join(REPO, 'webroot', 'index.html');
const CTL = path.join(REPO, 'bin', 'nfqws2-ctl');

// The ctl output is produced by tests/run.sh (via tests/lib/dump-ctl.sh) and
// handed over as files: spawning a shell from Node is not portable — on this
// machine every child process is refused with EBUSY — and keeping the shell
// side in shell is simpler anyway.
const statusFile = process.argv[2];
const strategiesFile = process.argv[3];
if (!statusFile || !strategiesFile) {
  process.stdout.write(
    'test_contract.js needs the ctl output as files:\n' +
    '  node test_contract.js <json-status.txt> <list-strategies.txt>\n' +
    'Run it through tests/run.sh instead.\n');
  process.exit(2);
}

let pass = 0;
const failures = [];
let section = '';

function sect(name) { section = name; process.stdout.write(`\n== ${name}\n`); }
function ok(msg) { pass++; process.stdout.write(`   ok   ${msg}\n`); }
function fail(msg) { failures.push(`[${section}] ${msg}`); process.stdout.write(`   FAIL ${msg}\n`); }
function eq(expected, actual, msg) {
  if (expected === actual) ok(msg);
  else fail(`${msg} -- expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
}
function truthy(cond, msg) { cond ? ok(msg) : fail(msg); }
function empty(list, msg) { eq('', [...new Set(list)].sort().join(','), msg); }

const WEBROOT = path.join(REPO, 'webroot');
const html = fs.readFileSync(INDEX, 'utf8');
const ctlSrc = fs.readFileSync(CTL, 'utf8');

const jsSrcs = [...html.matchAll(/<script\s+src="([^"]+)"><\/script>/g)]
  .map(m => m[1])
  .filter(s => !/^https?:\/\//.test(s));
const scriptFiles = jsSrcs.map(s => fs.readFileSync(path.join(WEBROOT, s), 'utf8'));
const inlineScripts = [...html.matchAll(/<script(?![^>]*src)[^>]*>([\s\S]*?)<\/script>/g)].map(m => m[1]);
const script = [...scriptFiles, ...inlineScripts].join('\n');
const webrootSrc = html + '\n' + script;

// ── json-status is parseable and complete ─────────────────────────────────────
sect('json-status');

const raw = fs.readFileSync(statusFile, 'utf8');
const jsonText = raw.slice(raw.indexOf('{'), raw.lastIndexOf('}') + 1);
let status = null;
try {
  status = JSON.parse(jsonText);
  ok('the ctl output is valid JSON');
} catch (e) {
  fail(`the ctl output is not valid JSON: ${e.message}`);
}

if (status) {
  // Keys the script actually reads off the status object.
  const readKeys = new Set();
  for (const m of webrootSrc.matchAll(/\b(?:j|S)\.([a-z_]+)\b/g)) readKeys.add(m[1]);
  // The switch rows read their field through tables (SW, DEV_SW, LIMITS)
  // [key, label, status_key] or [key, label, hint, status_key]
  for (const m of webrootSrc.matchAll(/\['[A-Z0-9_]+'[^\]]*?,\s*'([a-z][a-z0-9_]*)'\]/g)) readKeys.add(m[1]);
  const keyMap = webrootSrc.match(/const KEY = \{([^}]*)\}/);
  if (keyMap) {
    for (const m of keyMap[1].matchAll(/:\s*'([a-z0-9_]+)'/g)) readKeys.add(m[1]);
  }

  const missing = [...readKeys].filter(k => !(k in status));
  empty(missing, `every status key the WebUI reads exists (${readKeys.size} keys checked)`);

  // And the other direction: nothing should be computed and shipped without a
  // consumer. `tls_strategies`/`udp_strategies` used to cost two norm_args
  // pipelines on every single call and were never displayed.
  const unread = Object.keys(status).filter(k => !readKeys.has(k));
  empty(unread, 'no field is emitted without being read');

  // `c` is the counts object in renderListFiles() or apps.js:
  // in lists.js: const c = S.counts || {}; and c[key] where key comes from LIST_FILES
  // in apps.js: (S.counts || {}).apps
  const countSrc = new Set([...webrootSrc.matchAll(/\b(?:counts|S\.counts)\.([a-z_]+)\b/g)].map(m => m[1]));
  for (const m of webrootSrc.matchAll(/\['([a-z_]+)',\s*'[a-z_]+\.list'/g)) {
    if (m[1] !== 'probe_hosts') countSrc.add(m[1]);
  }
  const counts = status.counts || {};
  const missingCounts = [...countSrc].filter(k => !(k in counts));
  empty(missingCounts, 'every counts key the WebUI reads exists');

  // The switch rows map config names to status keys
  const swRows = [...webrootSrc.matchAll(/\['([A-Z0-9_]+)'[^\]]*?,\s*'([a-z][a-z0-9_]*)'\]/g)];
  if (swRows.length > 0) {
    const mapped = [...new Set(swRows.map(m => m[2]))];
    const missingMapped = mapped.filter(k => !(k in status));
    empty(missingMapped, 'every switch maps to a status key that exists');
    truthy(mapped.length >= 5, `${mapped.length} switches are mapped`);
  } else if (keyMap) {
    const mapped = [...keyMap[1].matchAll(/:\s*'([a-z0-9_]+)'/g)].map(m => m[1]);
    const missingMapped = mapped.filter(k => !(k in status));
    empty(missingMapped, 'every switch maps to a status key that exists');
    truthy(mapped.length >= 5, `${mapped.length} switches are mapped`);
  } else {
    fail('the switch mapping was not found in the WebUI');
  }

  // Fields the WebUI compares or does arithmetic on must be numbers.
  const numeric = ['pkt_limit_out', 'pkt_limit_in', 'block_quic', 'autostart', 'watchdog',
    'ipv6', 'log_level', 'qdrop', 'queue', 'app_uids', 'uptime'];
  const notNumbers = numeric.filter(k => typeof status[k] !== 'number');
  empty(notNumbers, 'every field the WebUI compares numerically is a JSON number');

  truthy(typeof status.running === 'boolean', 'running is a boolean');
  truthy(typeof status.pid === 'string', 'pid is a string');
  truthy(typeof status.version === 'string', 'version is a string');
  truthy(typeof status.mode === 'string', 'mode is a string');
  truthy(Array.isArray(Object.values(status.counts).filter(v => typeof v !== 'number')) === false
    || Object.values(status.counts).every(v => typeof v === 'number'),
    'every counter is a number');

  // Version shown in the WebUI must match module.prop.
  const propVersion = (fs.readFileSync(path.join(REPO, 'module.prop'), 'utf8')
    .match(/^version=(.*)$/m) || [])[1];
  eq(propVersion, status.version, 'the reported version matches module.prop');
  truthy(/S\.version/.test(webrootSrc),
    'the WebUI shows the version from json-status, which matches module.prop');
}

// ── strategy list ─────────────────────────────────────────────────────────────
sect('strategies');

const strategies = fs.readFileSync(strategiesFile, 'utf8').trim().split('\n').filter(Boolean);
truthy(strategies.length > 5, `the ctl offers ${strategies.length} strategies`);
truthy(!strategies.includes('default'),
  'the ctl does not list "default" (the WebUI prepends it)');
truthy(/strategies\s*=\s*\[.*'default'/.test(webrootSrc),
  'the WebUI prepends "default" itself, matching the ctl');
truthy(/STRATEGY_GROUPS/.test(webrootSrc), 'the WebUI categorises strategies into groups');

// ── command vocabulary ────────────────────────────────────────────────────────
sect('commands the WebUI sends');

const ctlCommands = new Set(
  [...ctlSrc.matchAll(/^\s{2}([a-z][a-z0-9-]*)\)/gm)].map(m => m[1])
);
// Команды dns-* и hosts-* ctl передаёт в dns_ctl / hosts_ctl из lib/
for (const [prefix, fn, file] of [['dns', 'dns_ctl', 'dns.sh'], ['hosts', 'hosts_ctl', 'hosts.sh']]) {
  const lib = path.join(REPO, 'lib', file);
  if (!new RegExp('^\\s{2}' + prefix + '-\\*\\) ' + fn, 'm').test(ctlSrc) || !fs.existsSync(lib)) continue;
  const src = fs.readFileSync(lib, 'utf8');
  for (const m of src.matchAll(new RegExp('^\\s{4}(' + prefix + '-[a-z0-9-]+)\\)', 'gm'))) ctlCommands.add(m[1]);
}
truthy(ctlCommands.size > 20, `the ctl dispatches ${ctlCommands.size} commands`);

// ctl(['name', ...]) — the array form the WebUI uses for most calls.
const sent = new Set();
for (const m of webrootSrc.matchAll(/\bctl\(\s*\[\s*'([a-z0-9-]+)'/g)) sent.add(m[1]);
for (const m of webrootSrc.matchAll(/\bctlx\(\s*\[\s*'([a-z0-9-]+)'/g)) sent.add(m[1]);
for (const m of webrootSrc.matchAll(/withBusy\(\s*\[\s*'([a-z0-9-]+)'/g)) sent.add(m[1]);
empty([...sent].filter(c => !ctlCommands.has(c)),
  `every command the WebUI sends exists in the ctl (${sent.size} checked)`);

// ── set: parameters and their allowed values ──────────────────────────────────
sect('set');

const setParams = new Set();
for (const m of ctlSrc.matchAll(/^\s+([A-Z0-9_|]+)\)\s*case "\$3" in/gm)) {
  for (const p of m[1].split('|')) setParams.add(p);
}
truthy(setParams.size >= 8, `the ctl accepts ${setParams.size} settable parameters`);

const wanted = new Set();
for (const m of webrootSrc.matchAll(/setp\(\s*'([A-Z][A-Z0-9_]*)'/g)) wanted.add(m[1]);
for (const m of webrootSrc.matchAll(/set',\s*'([A-Z][A-Z0-9_]*)'/g)) wanted.add(m[1]);
for (const m of webrootSrc.matchAll(/'([A-Z][A-Z0-9_]*)',\s*this\.checked/g)) wanted.add(m[1]);
for (const m of webrootSrc.matchAll(/\['([A-Z][A-Z0-9_]*)',\s*'(?:[^']*)',\s*'(?:[a-z0-9_]+)'\]/g)) wanted.add(m[1]);
for (const m of webrootSrc.matchAll(/\['([A-Z][A-Z0-9_]*)',\s*'(?:[^']*)',\s*'(?:[^']*)',\s*'(?:[a-z0-9_]+)'\]/g)) wanted.add(m[1]);
empty([...wanted].filter(p => !setParams.has(p)),
  `every parameter the WebUI sets is allowed (${wanted.size} checked)`);

// The mode segmented control maps to set-mode.
const modes = (webrootSrc.match(/\['auto',\s*'list',\s*'all'\]/) || [])[0];
truthy(!!modes, 'the WebUI offers the auto/list/all modes');
truthy(/set-mode\)\s*case "\$2" in list\|auto\|all\)/.test(ctlSrc),
  'set-mode accepts exactly list/auto/all');

// Application filter modes.
// The filter modes are a radio group now, built from APP_MODES, not a <select>.
// Scoped to the APP_MODES table: 'exclude' also appears elsewhere in the file
// (comments, the ctl vocabulary), and a bare scan counted four.
const appModesBlock = (webrootSrc.match(/const APP_MODES = \[([\s\S]*?)\];/) || ['', ''])[1];
const appModes = [...appModesBlock.matchAll(/\['(off|include|exclude)',\s*'/g)].map(m => m[1]);
truthy(appModes.length === 3, 'the WebUI offers off/include/exclude for the app filter');
truthy(/APP_MODE\)\s*case "\$3" in off\|include\|exclude\)/.test(ctlSrc),
  'the ctl accepts off/include/exclude for APP_MODE');

// ── lists ─────────────────────────────────────────────────────────────────────
sect('lists');

// The lists are described by LIST_FILES: [key, file, description, icon].
const listKeys = [...webrootSrc.matchAll(/\n\s*\['([a-z_]+)',\s*'[a-z_]+\.list'/g)].map(m => m[1]);
truthy(listKeys.length >= 5, `the WebUI offers ${listKeys.length} lists`);
const listFileCases = new Set();
for (const m of ctlSrc.matchAll(/^\s*([a-z_|.]+)\)\s*echo "\$LISTS_DIR/gm)) {
  for (const k of m[1].split('|')) listFileCases.add(k.replace(/\.list$/, ''));
}
empty(listKeys.filter(k => !listFileCases.has(k)), 'every list the WebUI offers is known to the ctl');

// ── log sources ───────────────────────────────────────────────────────────────
sect('log sources');

// Log sources come from LOG_SOURCES now (a menu, not a <select id="lt">).
// [^\]]* stops at the first inner bracket, so match the whole array body up to the
// line's closing `];`.
const ltList = (webrootSrc.match(/const LOG_SOURCES = \[([\s\S]*?)\];/) || ['', ''])[1];
const logSources = [...ltList.matchAll(/\['([a-z]+)'/g)].map(m => m[1]);
truthy(logSources.length >= 3, `the WebUI offers ${logSources.length} log sources`);
const logFn = (ctlSrc.match(/cmd_get_logs\(\)[\s\S]*?\n\}/) || [''])[0];
for (const src of logSources) {
  // `service` is deliberately the fallback branch (`*)`); the rest must be named
  // either in the case statement or as an early return (e.g. summary).
  const named = new RegExp(`(^|[\\s;])${src}\\)`).test(logFn) ||
                new RegExp(`"\\$1"\\s*=\\s*"${src}"`).test(logFn);
  truthy(named || src === 'service', `the ctl handles the "${src}" log source`);
}
truthy(/\*\)[^;]*SERVICE_LOG/.test(logFn), 'the unnamed log source falls back to service.log');

// ── summary ───────────────────────────────────────────────────────────────────
process.stdout.write('\n----------------------------------------\n');
if (failures.length === 0) {
  process.stdout.write(`PASS  ${pass} checks\n`);
  process.exit(0);
}
process.stdout.write(`FAIL  ${failures.length} of ${pass + failures.length} checks failed\n`);
for (const f of failures) process.stdout.write(`   - ${f}\n`);
process.exit(1);
