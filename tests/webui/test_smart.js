#!/usr/bin/env node
/*
 * Экран «Умный режим»: кольцо обученности, плитки, подробности в листе,
 * просмотр статистики другой сети. Ответы ctl — подменные.
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
const SHOT = process.env.SMART_SHOT || '';
const STATUS = JSON.stringify({
  running: true, pid: '4710', uptime: 52, strategy: 'smart', version: 'v2.2.1', mode: 'auto', smart: 1,
  pkt_limit_out: 15, pkt_limit_in: 15, block_quic: 0, app_mode: 'off', autostart: 1, watchdog: 1, ipv6: 1,
  log_level: 0, qdrop: 0, queue: 300, app_uids: 0, home_wifi: 0, vpn_pause: 0, paused: '',
  dns_available: 1, dns_enabled: 1,
  counts: { user: 3, auto: 1, exclude: 2, ipset: 4, ipset_exclude: 1, apps: 0 }
});
const v = (n, name, ok, err, sites) => ({ n, name, ok, err, sites });
const SMART_MOB = JSON.stringify({
  active: 1, running: 1, net: 'mobile-25001', view: 'mobile-25001', offline: 0, training: 0, learn: 1,
  bg: { n: '42', ok: '39', last: 'www.reddit.com' }, train: {},
  nets: [{ id: 'mobile-25001', label: 'MTS', sites: 64, ok: 900, err: 80, current: 1 },
         { id: 'wifi-1', label: 'Home', sites: 12, ok: 40, err: 30, current: 0 }],
  top: { tls: [v(1, 'MartinBacker #1', 300, 20, 40), v(2, 'MartinBacker #2', 20, 15, 4), v(14, 'без обхода', 50, 0, 6)],
         tls_16: [v(7, 'MartinBacker: хостинги (16 КБ)', 60, 5, 8)],
         google: [v(1, 'hardcorp74: Google', 200, 10, 5)],
         quic: [v(1, 'MartinBacker', 25, 10, 4)] },
  problems: [{ host: 'x.com', slot: 'tls', n: 2, name: 'MartinBacker #2', ok: 1, err: 4 }],
  nodpi: ['dead.example'], acc: { ok: 880, err: 70 }
});
const SMART_WIFI = JSON.stringify(Object.assign(JSON.parse(SMART_MOB), {
  view: 'wifi-1', top: { tls: [v(1, 'MartinBacker #1', 30, 25, 10)] }, problems: [], nodpi: [], acc: { ok: 30, err: 25 }
}));
const SITES = JSON.stringify([{ host: 'soundcloud.com', slot: 'tls_16', n: 7, name: 'MartinBacker: хостинги (16 КБ)', ok: 40, err: 1, e: 1 },
  { host: 'youtube.com', slot: 'google', n: 1, name: 'hardcorp74: Google', ok: 30, err: 0, e: 1 }]);
const STUB = `window.__calls = []; window.__strat = 'smart';
window.ksu = { exec: function(cmd, o, cb){
  var id = [o, cb].reverse().find(function(x){ return typeof x === 'string'; });
  window.__calls.push(cmd);
  var out = 'OK', rc = 0;
  if (cmd.indexOf('json-status') >= 0) out = ${JSON.stringify(STATUS)};
  else if (cmd.indexOf('list-strategies') >= 0) out = 'smart\\tbuiltin\\t0\\nalt2\\tbuiltin\\t0\\nhardcorp74\\tbuiltin\\t0';
  else if (cmd.indexOf('get-strategy') >= 0) out = window.__strat;
  else if (cmd.indexOf("'set-strategy'") >= 0) { window.__strat = /'set-strategy' '([^']+)'/.exec(cmd)[1]; out = 'OK'; }
  else if (cmd.indexOf("'bypass-info'") >= 0) out = JSON.stringify({ strategy: window.__strat, last: 'alt2', modified: 1, imports: ['my-isp'],
    stat: { ok: 1840, err: 96, since: 1761000000 }, meta: { author: 'Flowseal', repo: 'rndnaame/nfqws-menu', date: '2026-09-30', edited: '2026-10-20' } });
  else if (cmd.indexOf("'live-status'") >= 0) out = JSON.stringify({ rss: 9420, hwm: 11800, packets: 1284000, drops: 0, net: window.__strat === 'smart' ? 'mobile-25001' : 'wifi-1',
    net_label: window.__strat === 'smart' ? 'MTS' : 'Home', dns_hits: 3120, conn: window.__strat === 'smart' ? { ok: 900, err: 80 } : { ok: 1840, err: 96 } });
  else if (cmd.indexOf("'smart-status' 'wifi-1'") >= 0) out = ${JSON.stringify(SMART_WIFI)};
  else if (cmd.indexOf("'smart-status'") >= 0) out = ${JSON.stringify(SMART_MOB)};
  else if (cmd.indexOf("'smart-sites'") >= 0) out = ${JSON.stringify(SITES)};
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
  const page = await browser.newPage({ viewport: { width: 400, height: 860 }, deviceScaleFactor: 2 });
  page.on('pageerror', e => fail('page error: ' + e.message));
  await page.addInitScript(STUB);
  await page.goto(INDEX);
  await page.waitForTimeout(400);

  sect('the home screen in smart mode: no strategies, the mode and how well it learned');
  eq('#i-auto', await page.getAttribute('#strategy-ic', 'href'), 'the row shows the smart icon');
  eq('Умный режим', await page.$eval('#strategy-head', e => e.textContent), 'and the mode, not a strategy');
  await page.waitForTimeout(300);
  truthy(/Обучен на \d+%/.test(await page.$eval('#strategy-current', e => e.textContent)), 'with how well it learned');
  truthy(await page.$$eval('#live-tiles .smart-tile', l => l.length) >= 5, 'live tiles under the mode card');
  await page.waitForTimeout(300);
  const live = await page.$eval('#live-tiles', e => e.textContent);
  truthy(live.includes('MTS') && live.includes('92%') && /9,2 МБ/.test(live), 'the network, the connections and the memory of nfqws2 (' + live.slice(0, 120) + '…)');
  if (SHOT) await page.screenshot({ path: SHOT.replace(/\.png$/, '-home.png'), fullPage: true });
  eq('#i-auto', await page.getAttribute('#nav-bypass-ic', 'href'), 'the «Bypass» tab wears the smart icon');
  await page.click('#strategy-row');
  await page.waitForTimeout(700);
  eq('config', await page.evaluate(() => currentPage), 'the row opens the «Bypass» tab');
  truthy(await page.$eval('#mode-seg .seg[data-mode="smart"]', e => e.classList.contains('selected')), 'with smart mode selected on top');
  truthy(await page.$eval('#bypass-strat', e => e.hidden), 'strategy tiles are hidden');

  sect('the smart mode screen');
  const pctText = await page.$eval('.smart-ring-val', e => e.textContent);
  truthy(/^\d+%$/.test(pctText), 'a ring with a percentage (' + pctText + ')');
  const p = parseInt(pctText, 10);
  truthy(p >= 60 && p <= 100, 'a well-learned network scores high');
  eq(6, await page.$$eval('#smart-body .smart-tile', l => l.length), 'six tiles: sites, TLS, Google, QUIC, errors, training');
  const tileText = await page.$$eval('#smart-body .smart-tile', l => l.map(e => e.textContent).join(' | '));
  truthy(tileText.includes('64') && tileText.includes('MartinBacker #1') && tileText.includes('hardcorp74: Google'), 'tiles show the count and leading variants');
  if (SHOT) await page.screenshot({ path: SHOT, fullPage: true });

  sect('a tile opens its details');
  await page.click('#smart-body .smart-tile >> nth=1');
  await page.waitForTimeout(500);
  truthy(await page.evaluate(() => openSheetId === 'smart-sheet'), 'the sheet is open');
  const body = await page.$eval('#smart-sheet-body', e => e.textContent);
  truthy(body.includes('MartinBacker: хостинги (16 КБ)') && body.includes('soundcloud.com'), 'with variants per profile and the sites');
  if (SHOT) await page.screenshot({ path: SHOT.replace(/\.png$/, '-sheet.png') });
  await page.evaluate(() => closeSheet());
  await page.waitForTimeout(400);

  sect('another network can be viewed');
  await page.click('.smart-hero .chip');
  await page.waitForTimeout(200);
  await page.click('.menu [role=menuitem] >> nth=1');
  await page.waitForTimeout(400);
  truthy((await page.evaluate(() => window.__calls.join('\n'))).includes("'smart-status' 'wifi-1'"), 'its statistics are asked for');
  const p2 = parseInt(await page.$eval('.smart-ring-val', e => e.textContent), 10);
  truthy(p2 < p, 'and the ring shows its own, lower score (' + p2 + ')');

  sect('switching to strategies');
  await page.click('#mode-seg .seg[data-mode="strat"]');
  await page.waitForTimeout(400);
  truthy(await page.evaluate(() => $('dialog-wrap').classList.contains('open')), 'switching modes asks first');
  truthy((await page.textContent('#dialog-wrap')).includes('Служба будет перезапущена в другом режиме работы'), 'and warns about the restart');
  await page.click('#d-cancel');
  await page.waitForTimeout(400);
  eq(0, (await page.evaluate(() => window.__calls.join('\n'))).split("'set-strategy'").length - 1, 'cancel changes nothing');
  truthy(await page.$eval('#mode-seg .seg[data-mode="smart"]', e => e.classList.contains('selected')), 'smart mode stays selected');
  await page.click('#mode-seg .seg[data-mode="strat"]');
  await page.waitForTimeout(400);
  if (SHOT) await page.screenshot({ path: SHOT.replace(/\.png$/, '-confirm.png') });
  await page.click('#d-ok');
  await page.waitForTimeout(150);
  truthy((await page.$eval('#strat-body', e => e.textContent)).includes('alt2'), 'the new strategy shows at once, not after the restart');
  await page.waitForTimeout(750);
  truthy((await page.evaluate(() => window.__calls.join('\n'))).includes("'set-strategy' 'alt2'"), 'goes back to the last strategy');
  truthy(await page.$eval('#bypass-smart', e => e.hidden), 'the smart statistics are hidden');
  const hero = await page.$eval('#strat-body .strat-hero', e => e.textContent);
  truthy(hero.includes('alt2') && hero.includes('Сменить') && hero.includes('Сбросить правки'), 'a strategy card with «change» and, since it was edited, «reset» (' + hero + ')');
  const src = await page.$eval('#strat-body .strat-src', e => e.textContent);
  truthy(src.includes('Flowseal') && src.includes('rndnaame/nfqws-menu') && src.includes('2026') && src.includes('Ваша правка'), 'where it comes from, with the date and the edit date (' + src + ')');
  const st = await page.$$eval('#strat-body .smart-tile', l => l.map(e => e.textContent).join(' | '));
  truthy(st.includes('1840') && st.includes('96') && st.includes('95%'), 'connection statistics on this strategy (' + st.slice(0, 120) + '…)');
  await page.click('#strat-body .smart-tile:has-text("Поделиться")'); await page.waitForTimeout(300);
  truthy((await page.evaluate(() => window.__calls.join('\n'))).includes("'strategy-path' 'alt2'"), 'the share tile sends the current strategy as a file');
  await page.evaluate(() => $('prompt-container').classList.remove('show'));
  eq(0, await page.$$eval('#strat-body', l => l.filter(e => /Прежний конфиг|правлен вручную/.test(e.textContent)).length), 'no «previous config» or «edited by hand» any more');
  eq('#i-config', await page.getAttribute('#nav-bypass-ic', 'href'), 'the tab wears the config icon');
  if (SHOT) await page.screenshot({ path: SHOT.replace(/\.png$/, '-strat.png'), fullPage: true });
  await page.evaluate(() => openStrategySheet()); await page.waitForTimeout(700);
  eq('Применить', (await page.textContent('#strategy-apply')).trim(), 'the sheet button is just «Apply», even with the service running');
  eq(null, await page.$('#strategy-list input[value="smart"]'), 'smart mode is not among the strategies');
  await page.evaluate(() => closeSheet()); await page.waitForTimeout(400);
  await page.click('.nav-dest[data-page="control"]'); await page.waitForTimeout(700);
  eq('alt2', await page.$eval('#strategy-current', e => e.textContent), 'the home screen shows the strategy again');
  if (SHOT) await page.screenshot({ path: SHOT.replace(/\.png$/, '-home-strat.png'), fullPage: true });

  sect('settings → module behaviour');
  await page.evaluate(() => navigate('settings')); await page.waitForTimeout(500);
  const rows = await page.$$eval('#page-settings .li-primary, [data-page="settings"] .li-primary', l => l.map(e => e.textContent));
  const iw = rows.indexOf('Работа модуля');
  truthy(iw > 0 && rows[iw - 1] === 'Редактор hosts' && rows[iw + 1] === 'Фильтр приложений', 'third item, between the hosts editor and the app filter (' + rows.slice(0, 5).join(', ') + ')');
  await page.evaluate(() => navigate('work')); await page.waitForTimeout(600);
  truthy(await page.$('#work-body .split-sw input.switch') != null, 'Wi‑Fi pause is one split row with a switch');
  eq(4, await page.$$eval('#work-sws input.switch', l => l.length), 'autostart, IPv6, QUIC, hotspot');
  if (SHOT) await page.screenshot({ path: SHOT.replace(/\.png$/, '-work.png'), fullPage: true });

  await browser.close();
  process.stdout.write(`\n${failures.length ? 'FAIL' : 'PASS'}  ${pass} checks${failures.length ? ', ' + failures.length + ' failed' : ''}\n`);
  process.exit(failures.length ? 1 : 0);
})();
