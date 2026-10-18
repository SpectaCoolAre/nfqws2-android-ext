#!/usr/bin/env node
/*
 * Быстрые действия: долгое нажатие на вкладку внизу открывает меню, фон под
 * ним (кроме капсулы вкладок) размыт. Меню висит до выбора или касания мимо;
 * действие сначала открывает свою вкладку, потом делает своё. Обычное
 * нажатие на вкладку — по-прежнему просто переход.
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
  const page = await ctx.newPage();
  const errors = [];
  page.on('pageerror', e => errors.push(e.message));
  await page.goto(INDEX, { waitUntil: 'load' });
  await page.waitForTimeout(1000);

  const center = sel => page.$eval(sel, e => { const r = e.getBoundingClientRect(); return [r.x + r.width / 2, r.y + r.height / 2]; });
  async function hold(sel, ms = 650) {
    const [x, y] = await center(sel);
    await page.mouse.move(x, y); await page.mouse.down();
    await page.waitForTimeout(ms);
    await page.mouse.up();
    await page.waitForTimeout(500);
  }
  const cur = () => page.evaluate(() => currentPage);
  const items = () => page.$$eval('.menu .mi-text', r => r.map(e => e.firstChild.textContent));
  const scrim = () => page.evaluate(() => $('nav-scrim').classList.contains('show'));
  const calls = re => page.evaluate(r => window.__calls.filter(c => new RegExp(r).test(c)).length, re);
  const nav = p => `.nav-dest[data-page="${p}"]`;

  sect('menu and blur');
  await hold(nav('control'));
  eq('control', await cur(), 'holding a tab does not switch to it by itself');
  eq('Перезапуск,Остановить,Выбор стратегии', (await items()).join(), 'Состояние: restart, stop, strategy');
  eq(true, await scrim(), 'the rest of the window is blurred');
  const z = await page.evaluate(() => [getComputedStyle($('nav-scrim')).zIndex, getComputedStyle($('nav-bar')).zIndex, getComputedStyle($('app-bar')).zIndex].map(Number));
  truthy(z[0] < z[1] && z[0] > z[2], 'under the tab capsule but over the app bar: ' + z.join(','));
  const blur = await page.evaluate(() => getComputedStyle($('nav-scrim')).transition);
  truthy(/backdrop-filter/.test(blur), 'the blur fades in like the sheet scrim');
  await page.waitForTimeout(800);
  eq(1, await page.$$eval('.menu', r => r.length), 'the menu stays open');
  await page.mouse.click(190, 200); await page.waitForTimeout(400);
  eq(0, await page.$$eval('.menu', r => r.length), 'a tap on empty space closes it');
  eq(false, await scrim(), 'and the blur goes');
  eq('control', await cur(), 'and nothing under the finger fires');

  sect('Состояние');
  await page.evaluate(() => navigate('lists')); await page.waitForTimeout(600);
  await hold(nav('control'));
  await page.click('.menu .mi:nth-child(3)'); await page.waitForTimeout(900);
  eq('control', await cur(), '«Выбор стратегии» opens the status tab');
  eq('strategy-sheet', await page.evaluate(() => openSheetId), 'and the strategy sheet');
  await page.evaluate(() => closeSheet()); await page.waitForTimeout(400);
  await hold(nav('control'));
  await page.click('.menu .mi:nth-child(1)'); await page.waitForTimeout(600);
  eq(1, await calls("'restart'"), '«Перезапуск» restarts the service');

  sect('Списки');
  await hold(nav('lists'));
  eq('Очистить auto.list,Режим работы: list', (await items()).join(), 'clear auto and the other mode (no previous one yet: list)');
  await page.click('.menu .mi:nth-child(2)'); await page.waitForTimeout(900);
  eq('lists', await cur(), 'the action opens the lists tab');
  eq(1, await calls("'set-mode' 'list'"), 'and switches the mode');
  eq('auto', await page.evaluate(() => localStorage.getItem('nfq_prev_mode')), 'the previous mode is remembered');
  await page.evaluate(() => { window.__st = {mode: 'list'}; S.mode = 'list'; });
  await hold(nav('lists'));
  eq('Режим работы: auto', (await items())[1], 'and offered next time: two modes back and forth');
  await page.evaluate(() => closeMenu()); await page.waitForTimeout(300);
  await hold(nav('lists'));
  await page.click('.menu .mi:nth-child(1)'); await page.waitForTimeout(700);
  eq(true, await page.evaluate(() => $('dialog-wrap').classList.contains('open')), '«Очистить auto.list» asks first, as the button does');
  await page.evaluate(() => dialogResolve(false)); await page.waitForTimeout(300);

  sect('Настройки');
  for (const [i, pg] of [[1, 'dns'], [2, 'hosts'], [3, 'test']]) {
    await page.evaluate(() => navigate('control')); await page.waitForTimeout(600);
    await hold(nav('settings'));
    if (i === 1) eq('DNS профили,Редактор hosts,Проверка доступности', (await items()).join(), 'DNS, hosts, reachability check');
    await page.click(`.menu .mi:nth-child(${i})`); await page.waitForTimeout(1200);
    eq(pg, await cur(), `item ${i} opens settings, then «${pg}»`);
    await page.evaluate(() => goBack()); await page.waitForTimeout(600);
    eq('settings', await cur(), 'and back leads to settings');
  }

  sect('Конфиг');
  await hold(nav('config'));
  eq('Редактировать,Импортировать,Поделиться', (await items()).join(), 'edit, import, share');
  await page.click('.menu .mi:nth-child(1)'); await page.waitForTimeout(1000);
  eq('config', await cur(), 'the action opens the config tab');
  eq(true, await page.evaluate(() => $('editor-panel').classList.contains('open')), 'and the config editor');
  await page.evaluate(() => closeSlideEditor()); await page.waitForTimeout(500);
  await hold(nav('config'));
  await page.click('.menu .mi:nth-child(3)'); await page.waitForTimeout(800);
  truthy((await page.$$eval('.menu', r => r.length)) === 1, '«Поделиться» opens the share menu of the config row');
  await page.evaluate(() => closeMenu()); await page.waitForTimeout(300);
  const [fc] = await Promise.all([page.waitForEvent('filechooser', { timeout: 3000 }).catch(() => null),
    (async () => { await hold(nav('config')); await page.click('.menu .mi:nth-child(2)'); })()]);
  truthy(!!fc, '«Импортировать» opens the file picker');

  sect('plain tap');
  await page.click(nav('lists')); await page.waitForTimeout(600);
  eq('lists', await cur(), 'a plain tap still switches tabs');
  eq(0, await page.$$eval('.menu', r => r.length), 'without a menu');

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
