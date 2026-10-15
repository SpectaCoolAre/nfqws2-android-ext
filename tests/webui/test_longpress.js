#!/usr/bin/env node
/*
 * Долгие нажатия: дополнительные действия спрятаны за удержанием, обычное
 * нажатие остаётся прежним. Карточка состояния → DNS («назад» — на главную),
 * стратегия → меню (изменить, поделиться, скопировать), версия → список
 * изменений, язык → другой язык, «DNS профили» → перезапуск DNS, название
 * модуля в шапке → режим разработчика, значок журналов → действие на выбор.
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
  log_level: 0, qdrop: 0, queue: 300, app_uids: 0, home_wifi: 0, vpn_pause: 0, paused: '', pending: '',
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
  const page = await ctx.newPage();
  const errors = [];
  page.on('pageerror', e => errors.push(e.message));
  await page.goto(INDEX, { waitUntil: 'load' });
  await page.waitForTimeout(1000);

  const center = sel => page.$eval(sel, e => { e.scrollIntoView({ block: 'center' }); const r = e.getBoundingClientRect(); return [r.x + r.width / 2, r.y + r.height / 2]; });
  async function hold(sel, ms = 650) {
    const [x, y] = await center(sel);
    await page.mouse.move(x, y); await page.mouse.down();
    await page.waitForTimeout(ms);
    await page.mouse.up();
    await page.waitForTimeout(350);
  }
  const cur = () => page.evaluate(() => currentPage);
  const snack = () => page.evaluate(() => $('prompt-container').classList.contains('show') ? $('prompt-msg').textContent : '');
  const calls = re => page.evaluate(r => window.__calls.filter(c => new RegExp(r).test(c)).length, re);
  const closeAll = () => page.evaluate(() => { closeMenu(); closeSheet(); $('prompt-container').classList.remove('show'); });

  sect('status card → DNS, home Wi‑Fi');
  await hold('#sub [data-go="dns"]');
  eq('dns', await cur(), 'holding «DNS включён» in the status line opens the DNS screen');
  await page.evaluate(() => goBack()); await page.waitForTimeout(500);
  eq('control', await cur(), 'and back returns to the status screen, not to settings');
  await page.click('#sub'); await page.waitForTimeout(300);
  eq('control', await cur(), 'a plain tap on it does nothing');
  {
    const r = await page.$eval('#sub', e => { const b = e.getBoundingClientRect(); return [b.x + 6, b.y + b.height / 2]; });
    await page.mouse.move(r[0], r[1]); await page.mouse.down(); await page.waitForTimeout(650); await page.mouse.up(); await page.waitForTimeout(350);
  }
  eq('control', await cur(), 'holding «Режим auto» does nothing either');
  await page.evaluate(() => { S.running = false; S.paused = 'MyNet'; renderStatus(); });
  eq('Домашний Wi‑Fi · DNS включён', await page.textContent('#sub'), 'on a home Wi‑Fi pause the line is «Домашний Wi‑Fi» (masculine)');
  await hold('#sub [data-go="wifi"]');
  eq('wifi', await cur(), 'and holding it opens the home Wi‑Fi settings');
  await page.evaluate(() => goBack()); await page.waitForTimeout(500);
  eq('control', await cur(), 'back returns to the status screen');
  await page.evaluate(() => { S.running = true; S.paused = ''; renderStatus(); });

  sect('strategy menu');
  await page.evaluate(() => openStrategySheet()); await page.waitForTimeout(600);
  eq(0, await page.$$eval('#strategy-list [data-act="edit"]', r => r.length), 'the pencil is gone from the rows');
  truthy(await page.$eval('#strategy-sheet .sheet-hint', e => e.offsetHeight > 0 && /Удерживайте/.test(e.textContent)), 'a hint above the list tells about the long press');
  const before = await page.evaluate(() => pendingStrategy);
  await hold('#strategy-list .list-item:has(input[value="alt2"])');
  const items = await page.$$eval('.menu .mi-text', r => r.map(e => e.firstChild.textContent));
  eq('Изменить,Поделиться,Скопировать', items.join(), 'holding a strategy opens edit / share / copy');
  eq(before, await page.evaluate(() => pendingStrategy), 'and does not select it');
  await page.click('.menu .mi:nth-child(3)'); await page.waitForTimeout(300);
  eq(1, await calls("'strategy-get-b64' 'alt2'"), 'copy reads the strategy text');
  truthy(/скопирована/.test(await snack()), 'and says so: ' + await snack());
  await page.evaluate(() => $('prompt-container').classList.remove('show'));
  await hold('#strategy-list .list-item:has(input[value="alt2"])');
  await page.click('.menu .mi:nth-child(2)'); await page.waitForTimeout(300);
  eq(1, await calls("'strategy-path' 'alt2'"), 'share asks for the strategy file');
  eq(1, await calls("'share' 'file' '/data/adb/modules/nfqws2/strategies/alt2.conf'"), 'and shares it as a file straight away');
  eq(0, await page.$$eval('.menu', r => r.length), 'without asking file or text');
  await hold('#strategy-list .list-item:has(input[value="alt2"])');
  await page.click('.menu .mi:nth-child(1)'); await page.waitForTimeout(500);
  truthy(await page.evaluate(() => $('editor-panel').classList.contains('open')), 'edit opens the strategy editor');
  eq('', await page.textContent('#panel-hint'), 'without the explanation at the bottom');
  eq(0, await page.$eval('#panel-hint', e => e.offsetHeight), 'which takes no room');
  await page.evaluate(() => closeSlideEditor()); await page.waitForTimeout(400);
  await page.click('#strategy-list .list-item:has(input[value="alt2"])'); await page.waitForTimeout(200);
  eq('alt2', await page.evaluate(() => pendingStrategy), 'a plain tap still selects the strategy');
  await closeAll(); await page.waitForTimeout(400);

  sect('settings');
  await page.click('.nav-dest[data-page="settings"]'); await page.waitForTimeout(700);
  truthy(!(await page.$eval('#settings-body', e => /Что нового/.test(e.textContent))), 'the «Что нового» row is gone');
  await hold('#settings-body [data-long="ver"]');
  truthy(await page.evaluate(() => openSheetId === 'whatsnew-sheet'), 'holding the version opens the changelog');
  eq(2, await page.$$eval('#whatsnew-body li', r => r.length), 'with the items of this version');
  await closeAll(); await page.waitForTimeout(400);
  eq('settings', await cur(), 'and the tap that ends the hold does not open GitHub or leave');
  await hold('#settings-body [data-long="lang"]');
  eq('en', await page.evaluate(() => LANG), 'holding the language switches it at once');
  truthy(/Language switched: English/.test(await snack()), 'with a snackbar: ' + await snack());
  eq(0, await page.$$eval('.menu', r => r.length), 'without the language menu');
  await hold('#settings-body [data-long="lang"]');
  eq('ru', await page.evaluate(() => LANG), 'and back');
  await closeAll();
  await hold('#settings-body [data-long="dns"]');
  eq(1, await calls("'dns-restart'"), 'holding «DNS профили» restarts DNS');
  eq('DNS перезапущен', await snack(), 'with a snackbar');
  eq('settings', await cur(), 'without opening the DNS screen');

  sect('developer mode');
  const dev0 = await page.evaluate(() => devMode);
  await hold('#nav-settings', 800);
  eq(dev0, await page.evaluate(() => devMode), 'the settings tab no longer toggles developer mode');
  await hold('#app-title');
  eq(!dev0, await page.evaluate(() => devMode), 'holding the module name does');
  truthy(/Режим разработчика/.test(await snack()), 'with a snackbar');
  await hold('#brand-logo');
  eq(dev0, await page.evaluate(() => devMode), 'and so does its icon');

  sect('logs icon');
  await closeAll();
  await hold('#logs-btn');
  eq('settings', await cur(), 'holding the logs icon does not open the logs');
  truthy(/Экспорт журналов/.test(await snack()), 'by default it exports them: ' + await snack());
  await page.evaluate(() => { if ($('dialog-wrap').classList.contains('open')) dialogResolve(false); });
  await page.click('#logs-btn'); await page.waitForTimeout(600);
  eq('logs', await cur(), 'a tap still opens the logs');
  eq('Экспорт логов', await page.textContent('#logs-long-value'), 'where the long-press action is set');
  await page.click('#logs-long-value'); await page.waitForTimeout(200);
  await page.click('.menu .mi:nth-child(2)'); await page.waitForTimeout(200);
  eq('Очистка журналов', await page.textContent('#logs-long-value'), 'and can be switched to clearing');
  const cl0 = await calls("'clear-logs'");
  await page.evaluate(() => { goBack(); $('prompt-container').classList.remove('show'); }); await page.waitForTimeout(600);
  await hold('#logs-btn');
  eq(cl0 + 1, await calls("'clear-logs'"), 'then holding the icon clears the logs');
  truthy(/Журналы очищены/.test(await snack()), 'with a snackbar: ' + await snack());

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
