#!/usr/bin/env node
/*
 * Время работы на главной идёт ровно: каждая смена — ровно +1 секунда и
 * примерно через секунду, как бы ни дрожали ответы службы (округление,
 * задержка опроса), и что бы ни делали системные часы (перевод времени,
 * смена часового пояса). Перезапуск службы отсчёт сбрасывает.
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
// Служба: время работы с ошибкой до ±jitter мс и ответ с задержкой до 300 мс.
// legacy — ответ прежних версий: только целые секунды, без uptime_ms
const STUB = `window.__srv = { base: performance.now() - 52000, jitter: 600, legacy: false };
window.ksu = { exec: function(cmd, o, cb){
  var id = [o, cb].reverse().find(function(x){ return typeof x === 'string'; });
  var out = 'OK';
  if (cmd.indexOf('json-status') >= 0) {
    var s = window.__srv, ms = Math.max(0, Math.floor(performance.now() - s.base + (Math.random() * 2 - 1) * s.jitter));
    var j = { running: true, pid: '4710', uptime: Math.floor(ms / 1000), strategy: 'alt', version: 'v2.1.2', mode: 'auto',
      pkt_limit_out: 15, pkt_limit_in: 15, block_quic: 0, app_mode: 'off', autostart: 1, watchdog: 1, ipv6: 1,
      log_level: 0, qdrop: 0, queue: 300, app_uids: 0, home_wifi: 0, vpn_pause: 0, paused: '', pending: '',
      dns_available: 0, dns_enabled: 0, counts: { user: 0, auto: 0, exclude: 0, ipset: 0, ipset_exclude: 0, apps: 0 } };
    if (!s.legacy) j.uptime_ms = ms;
    out = JSON.stringify(j);
  }
  else if (cmd.indexOf('list-strategies') >= 0) out = 'alt\\tbuiltin\\t0';
  else if (cmd.indexOf('get-strategy') >= 0) out = 'alt';
  setTimeout(function(){ if (window[id]) window[id](0, out, ''); }, Math.random() * 300);
  return 'job';
}};
window.__upt = [];
document.addEventListener('DOMContentLoaded', function(){
  new MutationObserver(function(){ window.__upt.push([performance.now(), document.getElementById('upt').textContent]); })
    .observe(document.getElementById('upt'), { childList: true, characterData: true, subtree: true });
});`;

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
const secs = s => s.split(':').reduce((a, x) => a * 60 + Number(x), 0);

// Смены отображения за окно: каждая на +1 с, интервал 1000 мс ± 150
function steady(rec, label) {
  const ch = [];
  for (const r of rec) if (!ch.length || ch[ch.length - 1][1] !== r[1]) ch.push(r);
  const steps = [], gaps = [];
  for (let i = 1; i < ch.length; i++) { steps.push(secs(ch[i][1]) - secs(ch[i - 1][1])); gaps.push(Math.round(ch[i][0] - ch[i - 1][0])); }
  truthy(steps.length >= 4, `${label}: the display changed ${steps.length} times`);
  eq(true, steps.every(s => s === 1), `${label}: every change is exactly +1 s (${steps.join(',')})`);
  const bad = gaps.filter(g => g < 850 || g > 1150);
  eq(0, bad.length, `${label}: every change comes about a second after the last (${gaps.join(',')})`);
}

(async () => {
  let browser;
  try { browser = await chromium.launch(); } catch (e) {
    process.stdout.write('SKIP  chromium is not available: ' + e.message.split('\n')[0] + '\n');
    process.exit(0);
  }
  const ctx = await browser.newContext({ viewport: { width: 380, height: 760 } });
  await ctx.addInitScript(STUB);
  await ctx.addInitScript(() => { try { localStorage.setItem('nfq_seen_ver', 'v2.1.2'); } catch (e) {} });
  const page = await ctx.newPage();
  const errors = [];
  page.on('pageerror', e => errors.push(e.message));
  await page.goto(INDEX, { waitUntil: 'load' });
  await page.waitForTimeout(1500);
  const take = async ms => {
    await page.evaluate(() => { window.__upt = []; });
    await page.waitForTimeout(ms);
    return page.evaluate(() => window.__upt);
  };

  sect('jittery polls');
  steady(await take(7500), 'answers off by up to ±0.6 s');
  const shown = secs(await page.textContent('#upt'));
  const real = await page.evaluate(() => (performance.now() - window.__srv.base) / 1000);
  truthy(Math.abs(shown - real) < 2, `and it stays with the real uptime (${shown} vs ${real.toFixed(1)})`);

  sect('system clock changes');
  await page.evaluate(() => { const d = Date.now; Date.now = () => d() + 3600e3 - 37e3; });
  steady(await take(5500), 'the clock is moved by an hour');

  sect('service restart');
  await page.evaluate(() => { window.__srv.base = performance.now(); });
  await page.waitForTimeout(2500);
  truthy(secs(await page.textContent('#upt')) <= 3, 'a restarted service starts the count over: ' + await page.textContent('#upt'));
  steady(await take(5500), 'after the restart');

  sect('older service without uptime_ms');
  await page.evaluate(() => { window.__srv.legacy = true; });
  steady(await take(5500), 'whole seconds only');

  sect('stopped');
  await page.evaluate(() => { S.running = false; stopUptTimer(); });
  eq('—', await page.textContent('#upt'), 'a stopped service shows a dash');

  eq(0, errors.length, 'no page errors' + (errors.length ? ': ' + errors.join('; ') : ''));
  await browser.close();

  process.stdout.write('\n----------------------------------------\n');
  if (failures.length === 0) {
    process.stdout.write(`PASS  ${pass} checks\n`);
    process.exit(0);
  }
  process.stdout.write(`FAIL  ${failures.length} of ${pass + failures.length} checks failed\n`);
  for (const f of failures) process.stdout.write(`   - ${f}\n`);
  process.exit(1);
})();
