#!/usr/bin/env node
/*
 * «Настройки», открытые раньше первого ответа json-status: строки, зависящие
 * от состояния (DNS профили — только при dnsproxy), появляются, как только
 * ответ придёт, а не после ухода на другую страницу и обратно.
 *
 * Needs playwright + a chromium build; exits 0 with SKIP when absent.
 */
'use strict';

const path = require('path');
let chromium;
try {
  ({ chromium } = require('playwright'));
} catch (e) {
  process.stdout.write('SKIP  playwright is not installed (set NODE_PATH to a workspace that has it)\n');
  process.exit(0);
}

const INDEX = 'file:///' + path.join(path.resolve(__dirname, '..', '..'), 'webroot', 'index.html').replace(/\\/g, '/');
const STATUS = JSON.stringify({
  running: true, pid: '4710', uptime: 52, strategy: 'alt', version: 'v2.1.0', mode: 'auto',
  pkt_limit_out: 15, pkt_limit_in: 15, block_quic: 0, app_mode: 'off', autostart: 1, watchdog: 1, ipv6: 1,
  log_level: 0, qdrop: 0, queue: 300, app_uids: 0, home_wifi: 0, vpn_pause: 0, paused: '',
  dns_available: 1, dns_enabled: 1,
  counts: { user: 3, auto: 1, exclude: 2, ipset: 4, ipset_exclude: 1, apps: 0 }
});
const CHANGELOG = '### Изменения в v2.1.0:\n\n- Пункт один\n- Пункт два\n';
const STUB = `window.__calls = [];
window.ksu = { exec: function(cmd, o, cb){
  var id = [o, cb].reverse().find(function(x){ return typeof x === 'string'; });
  window.__calls.push(cmd);
  var out = 'OK', rc = 0;
  if (cmd.indexOf('json-status') >= 0) out = JSON.stringify(Object.assign(JSON.parse(${JSON.stringify(STATUS)}), window.__st || {}));
  else if (cmd.indexOf('list-strategies') >= 0) out = 'alt\\tbuiltin\\t0\\nalt2\\tbuiltin\\t0';
  else if (cmd.indexOf('get-strategy') >= 0) out = 'alt';
  else if (cmd.indexOf("'changelog'") >= 0) out = ${JSON.stringify(CHANGELOG)};
  else if (cmd.indexOf("'strategy-path'") >= 0) out = '/data/adb/modules/nfqws2/strategies/alt2.conf';
  else if (cmd.indexOf("'strategy-get-b64'") >= 0) out = btoa('--filter-tcp=443\\n');
  var delay = cmd.indexOf('json-status') >= 0 && !window.__stDone ? 2000 : 0;
  if (cmd.indexOf('json-status') >= 0) window.__stDone = true;
  setTimeout(function(){ if (window[id]) window[id](rc, out, ''); }, delay);
  return 'job';
}};`;

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

(async () => {
  let browser;
  try { browser = await chromium.launch(); } catch (e) {
    process.stdout.write('SKIP  chromium is not available: ' + e.message.split('\n')[0] + '\n');
    process.exit(0);
  }
  const ctx = await browser.newContext({ viewport: { width: 380, height: 760 } });
  await ctx.addInitScript(STUB);
  await ctx.addInitScript(() => { try { localStorage.setItem('nfq_seen_ver', 'v2.1.0'); } catch (e) {} });
  const page = await ctx.newPage();
  const errors = [];
  page.on('pageerror', e => errors.push(e.message));
  await page.goto(INDEX, { waitUntil: 'load' });
  await page.waitForTimeout(200);

  sect('settings opened before the first status');
  await page.evaluate(() => navigate('settings'));
  await page.waitForTimeout(300);
  const dnsRow = () => page.$$eval('#settings-body .li-primary', r => r.some(e => e.textContent.trim() === 'DNS профили'));
  eq(false, await dnsRow(), 'no status yet — no DNS row');
  await page.waitForTimeout(2600);
  eq(true, await dnsRow(), 'the status arrives — the DNS row appears without leaving the page');
  eq('settings', await page.evaluate(() => currentPage), 'still on settings');
  eq(0, errors.length, 'no page errors' + (errors.length ? ': ' + errors.join('; ') : ''));

  await browser.close();
  process.stdout.write(`\n${failures.length ? 'FAIL' : 'PASS'}  ${pass} checks${failures.length ? ', ' + failures.length + ' failed' : ''}\n`);
  failures.forEach(f => process.stdout.write('   - ' + f + '\n'));
  process.exit(failures.length ? 1 : 0);
})();
