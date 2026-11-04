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
  log_level: 0, qdrop: 0, queue: 300, app_uids: 0, home_wifi: 0, vpn_pause: 0, paused: '',
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
  // UI_DESIGN=miuix — те же жесты в дизайне HyperOS
  const MX = process.env.UI_DESIGN === 'miuix';
  if (MX) await ctx.addInitScript(() => { try { localStorage.setItem('ui_design', 'miuix'); } catch (e) {} });
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
    .filter(e => getComputedStyle(e).display !== 'none' && getComputedStyle(e).visibility !== 'hidden').map(e => e.dataset.page).sort().join(','));
  // остальные вкладки держатся разложенными, но невидимыми — свайп показывает готовую страницу
  const warm = () => page.evaluate(() => [...document.querySelectorAll('.page.warm')]
    .filter(e => getComputedStyle(e).display !== 'none' && getComputedStyle(e).visibility === 'hidden').map(e => e.dataset.page).sort().join(','));

  sect('tap in the navigation bar');
  // Сдвиг идёт анимацией в композиторе (300 мс); под нагрузкой он успевал
  // закончиться раньше, чем тест посмотрит. Поэтому анимации сдвига ставятся
  // на паузу на трети пути, замер — и дальше
  await page.evaluate(() => { const o = slidePages; window.__slide = [];
    slidePages = (from, to, opt) => { o(from, to, opt);
      window.__slide = [...from.getAnimations(), ...to.getAnimations()];
      __slide.forEach(a => { a.pause(); a.currentTime = a.effect.getTiming().duration / 3; });
      slidePages = o; }; });
  await page.click('.nav-dest[data-page="config"]');
  await page.waitForFunction(() => window.__slide.length > 0, null, { timeout: 3000 }).catch(() => {});
  eq('config,control', await shown(), 'state → config slides the two pages, lists and settings stay hidden');
  eq(NAV0, await navGeo(), 'mid-slide the navigation bar and the document width do not move');
  const xs = await page.evaluate(() => ['control', 'config'].map(p => document.querySelector(`.page[data-page="${p}"]`).getBoundingClientRect().left));
  truthy(xs[0] < 0 && xs[1] > 16, 'the old page leaves to the left, the new one comes from the right: ' + xs.map(Math.round));
  await page.evaluate(() => window.__slide.forEach(a => a.play()));
  await page.waitForTimeout(500);
  eq('config', await shown(), 'after the slide only config is on screen');
  eq('control,lists,settings', await warm(), 'the other tabs stay laid out but invisible: the next swipe shows a ready page');
  eq(0, await page.evaluate(() => document.querySelector('.page[data-page="lists"]').offsetHeight > 0 ? 0 : 1), 'a hidden tab keeps its layout (has height)');
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
  // Бросок узнаётся по скорости пальца (метки времени событий), а CDP под
  // нагрузкой доставляет движения с задержкой — скорость выходит ниже порога,
  // и это уже не бросок. Скорость, которую увидела страница, записывается;
  // если доставка была слишком медленной, жест повторяется (до 3 раз)
  await page.evaluate(() => { const o = swipeRelease; window.__rv = [];
    swipeRelease = (e, c) => { const tr = swipe.trail || [], a = tr[0], b = tr[tr.length - 1];
      if (swipe.st === 2 && a && b && b[0] > a[0]) __rv.push((b[1] - a[1]) / (b[0] - a[0])); return o(e, c); }; });
  let rv = [];
  for (let k = 0; k < 3; k++) {
    await page.evaluate(() => { __rv.length = 0; });
    await touch(line(100, 300, 170, 302, 3), { step: 0 });
    rv = await page.evaluate(() => __rv.slice());
    if (await cur() === 'control' || !(rv.length && rv[0] <= .4)) break;
    process.stdout.write(`   (the moves arrived too slowly: ${rv[0].toFixed(2)} px/ms — again)\n`);
  }
  eq('control', await cur(), 'a quick short fling right goes to the previous tab' + (rv.length ? ` (${rv[0].toFixed(2)} px/ms)` : ''));
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
  eq('control', await cur(), 'the first tab has nothing on the left: the swipe does nothing');
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
  if (MX) {
    // HyperOS: страница не растягивается, а сдвигается с затуханием (miuix overScrollVertical)
    const dy = +((/translateY\(([\d.]+)px\)/.exec(pulled.page) || [])[1] || 0);
    truthy(dy > 20 && dy < 240, 'pulling down at the top moves the page down, damped, not stretched: ' + pulled.page);
  } else truthy(/scaleY\(1\.0\d+\)/.test(pulled.page), 'pulling down at the top stretches the page: ' + pulled.page);
  eq(navBefore, pulled.nav, 'the navigation bar stays put');
  const tm = await page.evaluate(() => window.__tm);
  truthy(tm[1] > 0 && tm[1] >= tm[0] - 1, `while the page stretches the browser does not get the pull (${tm[1]} of ${tm[0]} moves held back)`);
  eq(NAV0, await navGeo(), 'and the document is no wider than the screen');
  eq('', await page.evaluate(() => document.querySelector('.page.active').style.transform), 'the page springs back on release');
  eq('control', await cur(), 'and the tab is the same');

  // «потяни, чтобы обновить» убрано: состояние и так обновляется само
  sect('no pull to refresh');
  await page.evaluate(() => { window.__rc = 0; const o = window.ksu.exec; window.ksu.exec = function(c){ if (c.indexOf('net-recheck') >= 0) window.__rc++; return o.apply(this, arguments); }; });
  await touch(line(190, 200, 190, 440, 12));
  eq(0, await page.evaluate(() => __rc), 'a long pull on the status screen only bounces, it does not refresh');
  eq(null, await page.evaluate(() => document.getElementById('ptr')), 'there is no refresh mark');
  // палец лёг на то, что перерисовалось во время жеста (время работы,
  // плитки): конец касания не должен теряться — иначе отскок на инерции не
  // срабатывал больше никогда
  await touch(line(190, 300, 190, 260, 6), { mid: async () => { await page.evaluate(() => {
    const el = document.elementFromPoint(190, 260); const c = el.cloneNode(true); el.replaceWith(c); }); } });
  eq(0, await page.evaluate(() => fling.touching), 'a touch that ends on a re-rendered element still counts as ended');

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
  // Скорость прокрутки страница считает между событиями scroll и обнуляет при
  // паузе больше 100 мс: под нагрузкой кадры бывают реже, и тогда это уже не
  // бросок. Ожидаемый отскок — до трёх попыток
  async function flingRetry(edge) {
    let r = '';
    for (let k = 0; k < 3 && !r; k++) {
      if (k) { process.stdout.write('   (no bounce: frames came too rarely — again)\n'); await page.waitForTimeout(600); }
      r = await flingInto(edge);
    }
    return r;
  }
  eq('bottom', await flingRetry('bottom'), 'a fling that runs into the bottom bounces the page');
  await page.waitForTimeout(600);   // два отскока подряд не чаще раза в 0,5 с
  eq('top', await flingRetry('top'), 'and one into the top bounces it too');
  await page.waitForTimeout(600);
  eq('', await flingInto('bottom', .1), 'a slow arrival at the edge does not bounce');
  // Короткая страница: прокрутка упирается в край, пока палец ещё на экране,
  // инерции после отпускания нет — отскок даёт скорость пальца в момент
  // отпускания (палец двигал страницу к краю)
  const release = v => page.evaluate(v => new Promise(done => { __abs.length = 0; fling.last = 0;
    scrollToY(scroller.scrollHeight); setTimeout(() => {
      finger.v = v; finger.t = performance.now();
      document.dispatchEvent(new TouchEvent('touchend', { touches: [], bubbles: true }));
      setTimeout(() => done(__abs.join()), 50); }, 120); }), v);
  eq('bottom', await release(-1.2), 'a finger released at the end of a short page while pushing towards it bounces the page');
  await page.waitForTimeout(600);
  eq('', await release(.8), 'a finger moving away from the edge does not');
  await page.waitForTimeout(600);
  eq('', await release(-.1), 'nor a finger that barely moved');
  await page.evaluate(() => scrollToY(0)); await page.waitForTimeout(600);
  eq(navF, await navGeo(), 'the navigation bar does not move');

  sect('child screens');
  await page.evaluate(() => navigate('logs'));
  await page.waitForTimeout(600);
  await touch(line(300, 300, 80, 300, 12));
  eq('logs', await cur(), 'child screens do not swipe');

  sect('a swipe that starts with a slight downward move');
  // У края страницы палец, чуть ушедший вниз, сначала начинал оттягивание. Когда
  // жест забирал свайп, оттягивание отпускалось анимацией на той же странице, и
  // полсекунды она держала страницу на месте: соседняя вкладка уже въезжала,
  // а текущая стояла (видео с телефона)
  await page.evaluate(() => { navigate('control'); }); await page.waitForTimeout(700);
  await page.evaluate(() => scrollToY(0));
  const dpts = [[300, 300], [300, 302], [299, 304]];
  for (let i = 1; i <= 8; i++) dpts.push([299 - i * 14, 304]);
  let pair = null;
  await touch(dpts, { mid: async () => { pair = await page.evaluate(() => {
    const f = document.querySelector('.page[data-page="control"]'), p = document.querySelector('.page.peek');
    return { gap: p ? Math.round(p.getBoundingClientRect().left - f.getBoundingClientRect().left) : -1, anims: f.getAnimations().length, w: innerWidth,
      moved: Math.round(f.getBoundingClientRect().left) }; }); } });
  eq(pair.w, pair.gap, 'the current tab and the neighbour move together, a screen apart');
  eq(0, pair.anims, 'nothing holds the current tab back while the finger drags it');
  truthy(pair.moved < -60, 'the current tab follows the finger at once: ' + pair.moved + 'px');
  if (await cur() !== 'lists') await page.evaluate(() => navigate('lists'));
  await page.waitForTimeout(600);

  sect('a scroll that runs into the edge without lifting the finger');
  // Жестом ведёт браузер (касание уже нельзя отменить): прокрутка у края
  // непрерывно переходит в оттягивание, а обратный ход отпускает его пружиной —
  // вести оттягивание за пальцем нельзя: браузер в то же время прокручивает
  // страницу, и она ехала бы быстрее пальца
  await page.evaluate(() => { $('content').style.minHeight = '3000px'; scrollToY(scroller.scrollHeight - scroller.clientHeight - 60); });
  await page.waitForTimeout(300);
  const tr = [];
  const spts = [[200, 450]];
  for (let i = 1; i <= 12; i++) spts.push([200, 450 - i * 15]);
  for (let i = 1; i <= 12; i++) spts.push([200, 270 + i * 15]);
  await cdp.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [{ x: 200, y: 450 }] });
  for (const [x, y] of spts.slice(1)) {
    await cdp.send('Input.dispatchTouchEvent', { type: 'touchMove', touchPoints: [{ x, y }] });
    await page.waitForTimeout(20);
    tr.push(await page.evaluate(() => [Math.round(stretch.pull), Math.round(scroller.scrollTop)]));
  }
  await cdp.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
  await page.waitForTimeout(600);
  const fwd = tr.slice(0, 12);
  truthy(Math.min(...fwd.map(t => t[0])) < -20, 'a scroll that reaches the edge goes on into a pull, in one movement: ' + fwd.map(t => t[0]).join(','));
  // обратный ход: оттягивание уходит пружиной, а не пальцем (в пределах
  // анимации отпускания), прокрутка дальше — с пальцем, не быстрее
  const back = tr.slice(16).map(t => t[1]), steps = back.slice(1).map((v, i) => back[i] - v).filter(d => d);
  truthy(steps.every(d => d <= 16), 'on the way back the page goes with the finger, not faster: ' + steps.join(','));
  eq(0, await page.evaluate(() => stretch.pull), 'and the pull is gone after release');
  await page.evaluate(() => { $('content').style.minHeight = ''; scrollToY(0); });

  sect('holding the logs icon anywhere on it');
  // кнопка журналов у правого края: удержание её правой трети раньше
  // пропускалось как «жест назад», и долгое нажатие срабатывало через раз
  await page.evaluate(() => { window.__lp = 0; window.logsLongAction = () => { __lp++; }; });
  const lb = await page.evaluate(() => { const b = $('logs-btn').getBoundingClientRect(); return [b.left, b.right, b.top + b.height / 2]; });
  for (const k of [.2, .5, .85]) {
    const x = lb[0] + (lb[1] - lb[0]) * k;
    await cdp.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [{ x, y: lb[2] }] });
    await page.waitForTimeout(700);
    await cdp.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
    await page.waitForTimeout(400);
  }
  eq(3, await page.evaluate(() => __lp), 'a long press works on the left, the middle and the right part of the icon');
  eq('lists', await cur(), 'and none of them opens the logs');

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
