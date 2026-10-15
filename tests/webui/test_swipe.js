#!/usr/bin/env node
/*
 * Вкладки листаются, как в Telegram для Android: нажатие в нижней панели
 * сдвигает страницы (промежуточные вкладки не показываются), горизонтальный
 * свайп тянет соседнюю вкладку за пальцем. Вертикальная прокрутка главнее:
 * вертикальный и диагональный (45°) жест прокручивают страницу и вкладку не
 * меняют, у края экрана (жест «Назад» Android) свайп не начинается.
 * Касания идут через CDP Input.dispatchTouchEvent — как на телефоне, с
 * touch-action и решением браузера о прокрутке.
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
  running: true, pid: '4710', uptime: 52, strategy: 'alt13', version: 'v2.0.5', mode: 'auto',
  pkt_limit_out: 15, pkt_limit_in: 15, block_quic: 0, app_mode: 'off', autostart: 1, watchdog: 1, ipv6: 1,
  log_level: 0, qdrop: 0, queue: 300, app_uids: 0, home_wifi: 0, vpn_pause: 0, paused: '', pending: '',
  counts: { user: 3, auto: 1, exclude: 2, ipset: 4, ipset_exclude: 1, apps: 0 }
});
const STUB = `window.ksu = { exec: function(cmd, o, cb){
  var id = [o, cb].reverse().find(function(x){ return typeof x === 'string'; });
  var out = 'OK';
  if (cmd.indexOf('json-status') >= 0) out = ${JSON.stringify(STATUS)};
  else if (cmd.indexOf('list-strategies') >= 0) out = 'alt13';
  else if (cmd.indexOf('get-strategy') >= 0) out = 'alt13';
  setTimeout(function(){ if (window[id]) window[id](0, out, ''); }, 0);
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
  const ctx = await browser.newContext({ viewport: { width: 380, height: 560 }, hasTouch: true, isMobile: true });
  await ctx.addInitScript(STUB);
  const page = await ctx.newPage();
  const errors = [];
  page.on('pageerror', e => errors.push(e.message));
  await page.goto(INDEX, { waitUntil: 'load' });
  await page.waitForTimeout(1000);
  const cdp = await ctx.newCDPSession(page);
  const line = (x0, y0, x1, y1, n) => Array.from({ length: n + 1 }, (_, i) => [x0 + (x1 - x0) * i / n, y0 + (y1 - y0) * i / n]);
  async function touch(pts, opts = {}) {
    await cdp.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [{ x: pts[0][0], y: pts[0][1] }] });
    for (const [x, y] of pts.slice(1)) {
      await cdp.send('Input.dispatchTouchEvent', { type: 'touchMove', touchPoints: [{ x, y }] });
      await page.waitForTimeout(opts.step || 16);
    }
    if (opts.mid) await opts.mid();
    await cdp.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
    await page.waitForTimeout(600);
  }
  const cur = () => page.evaluate(() => currentPage);
  // капсула навигации и ширина документа: ни сдвиг вкладок, ни растяжение их не меняют
  const navGeo = () => page.evaluate(() => { const r = $('nav-bar').getBoundingClientRect();
    return [Math.round(r.left), Math.round(r.top), Math.round(r.width), document.documentElement.scrollWidth].join(); });
  const NAV0 = await navGeo();
  const shown = () => page.evaluate(() => [...document.querySelectorAll('.page')]
    .filter(e => getComputedStyle(e).display !== 'none').map(e => e.dataset.page).sort().join(','));

  sect('tap in the navigation bar');
  await page.click('.nav-dest[data-page="config"]');
  await page.waitForTimeout(100);
  eq('config,control', await shown(), 'state → config slides the two pages, lists and settings stay hidden');
  eq(NAV0, await navGeo(), 'mid-slide the navigation bar and the document width do not move');
  const xs = await page.evaluate(() => ['control', 'config'].map(p => document.querySelector(`.page[data-page="${p}"]`).getBoundingClientRect().left));
  truthy(xs[0] < 0 && xs[1] > 16, 'the old page leaves to the left, the new one comes from the right: ' + xs.map(Math.round));
  await page.waitForTimeout(500);
  eq('config', await shown(), 'after the slide only config is on screen');
  await page.click('.nav-dest[data-page="control"]');
  await page.waitForTimeout(600);
  eq('control', await cur(), 'and back to state');

  sect('vertical gestures win');
  await touch(line(190, 420, 200, 160, 15));
  eq('control', await cur(), 'a vertical swipe keeps the tab');
  truthy(await page.evaluate(() => scrollPos() > 0), 'and scrolls the page');
  await touch(line(300, 400, 180, 280, 10));
  eq('control', await cur(), 'a 45° swipe is a scroll too');
  const y1 = await page.evaluate(() => scrollPos());
  await touch(line(200, 160, 220, 420, 15));
  const y2 = await page.evaluate(() => scrollPos());
  truthy(y2 < y1, `a slightly diagonal swipe down scrolls back: ${Math.round(y1)} → ${Math.round(y2)}`);
  eq('control', await cur(), 'on the same tab');
  await page.evaluate(() => scrollToY(0));

  sect('horizontal swipe');
  let mid = '';
  await touch(line(300, 300, 120, 306, 12), { mid: async () => { mid = await shown(); } });
  eq('control,lists', mid, 'while dragging the neighbour tab is visible next to the current one');
  eq('lists', await cur(), 'a long swipe left opens the next tab');
  eq('page', await page.getAttribute('.nav-dest[data-page="lists"]', 'aria-current'), 'and the navigation bar follows');
  await touch(line(200, 300, 250, 300, 10, ), { step: 40 });
  eq('lists', await cur(), 'a short slow drag springs back');
  eq('lists', await shown(), 'and hides the neighbour');
  await touch(line(100, 300, 170, 302, 3));
  eq('control', await cur(), 'a quick short fling right goes to the previous tab');
  // Нажатие в панели сразу после быстрого свайпа. Браузер вёл свой жест с
  // инерцией (touch-action его только фильтровал), и следующее касание шло на
  // её остановку: pointerdown/pointerup были, click — нет, вкладка не менялась
  for (const [delay, to] of [[50, 'config'], [300, 'control']]) {
    const fl = [[320, 300], [280, 301], [220, 302], [150, 303], [90, 303]];
    await cdp.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [{ x: fl[0][0], y: fl[0][1] }] });
    for (const [x, y] of fl.slice(1)) {
      await cdp.send('Input.dispatchTouchEvent', { type: 'touchMove', touchPoints: [{ x, y }] });
      await page.waitForTimeout(8);
    }
    await cdp.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
    const from = await cur();
    await page.waitForTimeout(delay);
    const xy = await page.$eval(`.nav-dest[data-page="${to}"]`, e => { const r = e.getBoundingClientRect(); return [r.x + r.width / 2, r.y + r.height / 2]; });
    let clicked = false;
    await page.evaluate(() => { window.__clk = 0; document.addEventListener('click', () => window.__clk++, { capture: true, once: true }); });
    await cdp.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [{ x: xy[0], y: xy[1] }] });
    await page.waitForTimeout(60);
    await cdp.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
    await page.waitForTimeout(500);
    clicked = await page.evaluate(() => window.__clk > 0);
    eq(to, await cur(), `a fast swipe to ${from}, a tap on ${to} ${delay} ms later switches the tab`);
    truthy(clicked, 'and the browser delivers the click (no fling left behind to swallow it)');
  }
  await page.click('.nav-dest[data-page="control"]'); await page.waitForTimeout(600);
  await touch(line(100, 300, 330, 300, 12));
  eq('control', await cur(), 'the first tab has nothing on the left: an elastic bounce');
  let midR = '';
  await touch(line(100, 300, 300, 302, 10), { mid: async () => { midR = await navGeo(); } });
  eq(NAV0, midR, 'dragging right (the page overhangs the right edge) does not widen the document or shift the navigation bar');
  await touch(line(10, 300, 300, 300, 12));
  eq('control', await cur(), 'a swipe from the screen edge is left to the Android back gesture');

  sect('text fields');
  await page.click('.nav-dest[data-page="lists"]'); await page.waitForTimeout(600);
  const fld = await page.$eval('.page[data-page="lists"] input[type="text"], .page[data-page="lists"] input:not([type])', e => {
    const r = e.getBoundingClientRect(); return [r.left + r.width / 2, r.top + r.height / 2]; });
  await touch(line(fld[0] + 100, fld[1], fld[0] - 120, fld[1] + 4, 12));
  eq('settings', await cur(), 'a swipe across an unfocused field still turns the tab');
  await page.click('.nav-dest[data-page="lists"]'); await page.waitForTimeout(600);
  await page.focus('.page[data-page="lists"] input[type="text"], .page[data-page="lists"] input:not([type])');
  await touch(line(fld[0] + 100, fld[1], fld[0] - 120, fld[1] + 4, 12));
  eq('lists', await cur(), 'a swipe inside a focused field moves the caret, not the tab');
  await page.evaluate(() => document.activeElement.blur());
  await page.click('.nav-dest[data-page="control"]'); await page.waitForTimeout(600);

  sect('overscroll stretch');
  eq(0, await page.evaluate(() => document.scrollingElement.scrollHeight - innerHeight), 'the document root never scrolls: WebView has nothing to stretch, the bars stay put');
  const navBefore = await page.evaluate(() => [getComputedStyle($('nav-bar')).transform, Math.round($('nav-bar').getBoundingClientRect().top)].join());
  eq(1, await page.evaluate(() => scroller.getBoundingClientRect().height - innerHeight),
    'the scroll layer is 1px taller than the screen: Chromium does not promote it to the root scroller');
  await page.evaluate(() => { window.__tm = [0, 0]; document.addEventListener('touchmove', e => { window.__tm[0]++; if (e.defaultPrevented) window.__tm[1]++; }, { passive: true }); });
  let pulled = {};
  await touch(line(190, 200, 190, 440, 12), { mid: async () => { pulled = await page.evaluate(() => ({
    page: document.querySelector('.page.active').style.transform,
    nav: [getComputedStyle($('nav-bar')).transform, Math.round($('nav-bar').getBoundingClientRect().top)].join() })); } });
  truthy(/scaleY\(1\.0\d+\)/.test(pulled.page), 'pulling down at the top stretches the page: ' + pulled.page);
  eq(navBefore, pulled.nav, 'the navigation bar stays put');
  const tm = await page.evaluate(() => window.__tm);
  truthy(tm[1] > 0 && tm[1] >= tm[0] - 1, `while the page stretches the browser does not get the pull (${tm[1]} of ${tm[0]} moves held back)`);
  eq(NAV0, await navGeo(), 'and the document is no wider than the screen');
  eq('', await page.evaluate(() => document.querySelector('.page.active').style.transform), 'the page springs back on release');
  eq('control', await cur(), 'and the tab is the same');

  sect('pull to refresh');
  await page.evaluate(() => { window.__rc = 0; const o = window.ksu.exec; window.ksu.exec = function(c){ if (c.indexOf('net-recheck') >= 0) window.__rc++; return o.apply(this, arguments); }; });
  await touch(line(190, 200, 190, 260, 8));
  eq(0, await page.evaluate(() => __rc), 'a short pull on the status screen does not refresh');
  let ptrMid = '';
  await touch(line(190, 200, 190, 440, 12), { mid: async () => { ptrMid = await page.evaluate(() => [$('ptr').style.opacity, $('ptr').classList.contains('ready')].join()); } });
  eq('1,true', ptrMid, 'a long pull shows the refresh mark, ready to fire');
  eq(1, await page.evaluate(() => __rc), 'and releasing it asks the service to recheck network, VPN and DNS');
  eq('0', await page.evaluate(() => $('ptr').style.opacity), 'the mark goes away when done');

  sect('fling into an edge');
  // Системный отскок WebView отключён (двигал шапку и навигацию), поэтому
  // удар инерции о край — свой: короткое растяжение страницы
  await page.evaluate(() => { window.__abs = []; const o = stretchAbsorb; stretchAbsorb = (t, v) => { __abs.push(t ? 'top' : 'bottom'); return o(t, v); }; });
  const navF = await navGeo();
  // Инерция — покадровой прокруткой при отпущенном пальце: отскок срабатывает
  // по событиям scroll, ему всё равно, кто крутит. Настоящий бросок через CDP
  // (серия touchMove) запускал инерцию Chromium через раз — решала скорость
  // в момент отпускания, а её задавали задержки самого CDP
  async function flingInto(edge, speed = 1.5) {   // px/мс
    await page.evaluate(() => { __abs.length = 0; });
    await page.evaluate(([e, v]) => new Promise(done => {
      const max = scroller.scrollHeight - scroller.clientHeight, dir = e === 'bottom' ? 1 : -1;
      let y = e === 'bottom' ? Math.max(0, max - 200) : Math.min(max, 200), t = 0;
      scrollToY(y);
      requestAnimationFrame(function step(now){
        if (t) y += dir * v * (now - t);
        t = now;
        scrollToY(Math.max(0, Math.min(max, y)));
        if (y > 0 && y < max) requestAnimationFrame(step); else setTimeout(done, 300);
      });
    }), [edge, speed]);
    return page.evaluate(() => __abs.join());
  }
  eq('bottom', await flingInto('bottom'), 'a fling that runs into the bottom bounces the page');
  await page.waitForTimeout(600);   // два отскока подряд не чаще раза в 0,5 с
  eq('top', await flingInto('top'), 'and one into the top bounces it too');
  await page.waitForTimeout(600);
  eq('', await flingInto('bottom', .1), 'a slow arrival at the edge does not bounce');
  eq(navF, await navGeo(), 'the navigation bar does not move');

  sect('child screens');
  await page.evaluate(() => navigate('logs'));
  await page.waitForTimeout(600);
  await touch(line(300, 300, 80, 300, 12));
  eq('logs', await cur(), 'child screens do not swipe');

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
