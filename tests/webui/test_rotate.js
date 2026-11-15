#!/usr/bin/env node
/*
 * Поворот экрана в KernelSU Next: окно WebUI не объявляет configChanges, и
 * Android при повороте пересоздаёт его — страница грузится заново (заставка и
 * главная). Модуль помнит открытый экран (отметка жизни nfq_alive) и после
 * поворота открывает его без заставки. Обычное открытие — с заставкой.
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
  if (cmd.indexOf('json-status') >= 0) out = ${JSON.stringify(STATUS)};
  else if (cmd.indexOf('list-strategies') >= 0) out = 'alt\\tbuiltin\\t0\\nalt2\\tbuiltin\\t0';
  else if (cmd.indexOf('get-strategy') >= 0) out = 'alt';
  else if (cmd.indexOf("'changelog'") >= 0) out = ${JSON.stringify(CHANGELOG)};
  else if (cmd.indexOf("'strategy-path'") >= 0) out = '/data/adb/modules/nfqws2/strategies/alt2.conf';
  else if (cmd.indexOf("'strategy-get-b64'") >= 0) out = btoa('--filter-tcp=443\\n');
  setTimeout(function(){ if (window[id]) window[id](rc, out, ''); }, 0);
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
  const errors = [];
  // новое окно WebUI = новая вкладка: своя история, общий localStorage
  async function open(w, h) {
    const p = await ctx.newPage();
    p.on('pageerror', e => errors.push(e.message));
    await p.setViewportSize({ width: w, height: h });
    await p.goto(INDEX, { waitUntil: 'domcontentloaded' });
    return p;
  }
  const splashShown = p => p.evaluate(() => { const s = document.getElementById('splash'); return !!s && getComputedStyle(s).display !== 'none'; });
  const cur = p => p.evaluate(() => currentPage);

  sect('a plain open shows the splash');
  let page = await open(380, 760);
  truthy(await splashShown(page), 'the splash is up on the first frame');
  await page.waitForTimeout(1200);

  sect('rotation recreates the window: same screen, no splash');
  await page.evaluate(() => navigate('settings')); await page.waitForTimeout(1500);
  eq('settings', await cur(page), 'settings are open in portrait');
  const alive = await page.evaluate(() => JSON.parse(localStorage.getItem('nfq_alive') || 'null'));
  truthy(alive && alive.page === 'settings' && alive.o === 'p', 'the alive mark knows the screen and the orientation');
  // как KernelSU Next: новое окно — уже в другой ориентации (старое закрываем
  // после: headless Chromium при мгновенном закрытии вкладки теряет её
  // последние записи localStorage, на телефоне отметка пишется раз в секунду)
  const old = page;
  page = await open(760, 380);
  await old.close();
  eq(false, await splashShown(page), 'no splash after the rotation');
  await page.waitForTimeout(1200);
  eq('settings', await cur(page), 'and the same screen comes back');
  await page.close();

  sect('an open long after, or in the same orientation, is a plain open');
  // отметку пишет живое окно — её заменяем без него
  await ctx.addInitScript(() => { if (location.hash === '#stale') localStorage.setItem('nfq_alive', JSON.stringify({ t: Date.now() - 60000, o: 'l', page: 'settings', y: 0 })); });
  page = await ctx.newPage();
  page.on('pageerror', e => errors.push(e.message));
  await page.setViewportSize({ width: 380, height: 760 });
  await page.goto(INDEX.replace(/$/, '#stale'), { waitUntil: 'domcontentloaded' });
  truthy(await splashShown(page), 'a stale mark (a minute old): the splash');
  await page.waitForTimeout(1200);
  eq('control', await cur(page), 'and the status screen');
  await page.evaluate(() => { navigate('settings'); });
  await page.waitForTimeout(1200);
  const prev = page;
  page = await open(380, 760);
  await prev.close();
  truthy(await splashShown(page), 'a fresh mark in the same orientation (a reopen, not a rotation): the splash');
  await page.waitForTimeout(1200);
  await page.close();

  eq(0, errors.length, 'no page errors: ' + errors.join(' | '));
  await browser.close();
  process.stdout.write(`\n${failures.length ? 'FAIL' : 'PASS'}  ${pass} passed, ${failures.length} failed\n`);
  for (const f of failures) process.stdout.write(`   - ${f}\n`);
  process.exit(failures.length ? 1 : 0);
})();
