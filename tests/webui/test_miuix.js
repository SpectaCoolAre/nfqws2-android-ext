#!/usr/bin/env node
/*
 * Дизайн HyperOS (miuix): переключатель в «Оформлении», размеры и цвета
 * компонентов из miuix, сворачивание большого заголовка, диалог снизу, обе
 * палитры (системная и классическая) и возврат к Material 3 без следов.
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
const STATUS = JSON.stringify({ running: true, pid: '4710', uptime: 52, strategy: 'alt', version: 'v2.3.0', mode: 'auto',
  pkt_limit_out: 15, pkt_limit_in: 15, block_quic: 0, app_mode: 'off', autostart: 1, watchdog: 1, ipv6: 1,
  log_level: 0, qdrop: 0, queue: 300, app_uids: 0, home_wifi: 0, vpn_pause: 0, paused: '',
  dns_available: 1, dns_enabled: 0, counts: { user: 3, auto: 1, exclude: 2, ipset: 4, ipset_exclude: 1, apps: 0 } });
const STUB = `window.ksu = { exec: function(cmd, o, cb){
  var id = [o, cb].reverse().find(function(x){ return typeof x === 'string'; });
  var out = 'OK';
  if (cmd.indexOf('json-status') >= 0) out = ${JSON.stringify(STATUS)};
  else if (cmd.indexOf('list-strategies') >= 0) out = 'alt\\tbuiltin\\t0';
  else if (cmd.indexOf('get-strategy') >= 0) out = 'alt';
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
  if (JSON.stringify(expected) === JSON.stringify(actual)) ok(msg);
  else fail(`${msg} -- expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
}
function truthy(cond, msg) { cond ? ok(msg) : fail(msg); }

(async () => {
  const browser = await chromium.launch();
  const ctx = await browser.newContext({ viewport: { width: 400, height: 860 }, deviceScaleFactor: 1, isMobile: true, hasTouch: true });
  await ctx.addInitScript(STUB);
  await ctx.addInitScript(() => { try { localStorage.setItem('m3_mode', 'light'); localStorage.setItem('nfq_seen_ver', 'v9'); } catch (e) {} });
  const page = await ctx.newPage();
  const errors = [];
  page.on('pageerror', e => errors.push(e.message));
  await page.goto(INDEX, { waitUntil: 'load' });
  await page.waitForTimeout(800);
  const box = sel => page.$eval(sel, e => { const r = e.getBoundingClientRect(); return { w: Math.round(r.width), h: Math.round(r.height), top: Math.round(r.top), bottom: Math.round(r.bottom) }; });
  const css = (sel, prop, pseudo) => page.$eval(sel, (e, a) => getComputedStyle(e, a[1] || null)[a[0]], [prop, pseudo]);

  sect('Material 3 by default');
  eq('m3', await page.evaluate(() => document.documentElement.dataset.design), 'the design is Material 3 until chosen');
  await page.evaluate(() => navigate('work')); await page.waitForTimeout(700);
  const m3sw = await box('#work-body .switch, .page.active .switch');
  eq([52, 32], [m3sw.w, m3sw.h], 'the M3 switch is 52×32');
  eq('none', await css('.page.active > .mx-title', 'display'), 'no large title in M3');

  sect('switching to HyperOS in the theme sheet');
  await page.evaluate(() => { navigate('settings'); openSheet('monet-modal'); }); await page.waitForTimeout(700);
  eq(['Material 3', 'HyperOS'], await page.$$eval('#theme-design .seg', l => l.map(e => e.textContent.trim())), 'the design choice is Material 3 or HyperOS');
  await page.click('#theme-design .seg:nth-child(2)'); await page.waitForTimeout(300);
  eq('miuix', await page.evaluate(() => document.documentElement.dataset.design), 'one tap switches to HyperOS');
  eq('miuix', await page.evaluate(() => localStorage.getItem('ui_design')), 'and it is remembered');
  eq(0, await page.$$eval('#mx-colors, #mx-colors-row', l => l.length), 'there is no separate colour choice: HyperOS brings its own colours');
  eq([true, true, true], await page.$$eval('#containers-row, #accent-block, #amoled-row', l => l.map(e => e.hidden)), 'containers, accent and AMOLED are not offered: cards always, own palette, dark is black already');
  eq('none', await css('.theme-preview', 'display'), 'nor the accent preview');
  truthy(await page.$eval('#monet-modal .mx-sheet-close', e => getComputedStyle(e).display !== 'none'), 'the sheet has a close cross');
  eq('center', await css('#monet-modal .sheet-title', 'textAlign'), 'and a centred title');
  eq('#3482ff', await page.evaluate(() => getComputedStyle(document.documentElement).getPropertyValue('--md-sys-color-primary').trim()), 'the accent is the HyperOS blue #3482FF');
  eq('rgb(52, 130, 255)', await css('#theme-design .seg.on', 'backgroundColor'), 'the chosen segment is filled with the accent');
  await page.evaluate(() => closeSheet()); await page.waitForTimeout(400);

  sect('HyperOS look: plain, advanced textures, liquid glass, glow');
  await page.evaluate(() => { navigate('settings'); openSheet('monet-modal'); }); await page.waitForTimeout(600);
  eq(['Обычный', 'Текстуры', 'Стекло'], await page.$$eval('#mx-looks .mx-look-opt .mxl-name', l => l.map(e => e.textContent.trim())), 'three looks to choose from, as picture slides');
  eq('tex', await page.$eval('#mx-looks [aria-checked="true"]', e => e.dataset.look), 'by default: advanced textures');
  truthy(await page.evaluate(() => $('mx-aurora-toggle').checked), 'and the glow on the home screen');
  truthy(/blur/.test(await css('.nav-bar', 'backdropFilter')), 'textures: the navigation bar blurs what is under it');
  truthy(/blur/.test(await css('.mx-look-opt[data-look="tex"] .w-nav', 'backdropFilter')), 'the textures slide shows real blur under its navigation capsule');
  eq(6, await page.$$eval('.mx-look-opt[data-look="tex"] .mxl-art .w', l => l.length), 'each slide is the module home in miniature: logs button, status card, two tiles, notification, navigation');
  eq('none', await css('.nav-bar', 'content', '::after'), 'textures: no glass rim — only the blur');
  eq('none', await css('.mx-look-opt[data-look="tex"] .w-nav', 'content', '::before'), 'and none on the textures slide either');
  truthy((await css('.mx-look-opt[data-look="glass"] .w-nav', 'backdropFilter')).includes('blur'), 'the glass slide blurs a little');
  eq('1px', await css('.mx-look-opt[data-look="glass"] .w-nav', 'padding', '::before'), 'and draws the glass rim');
  truthy((await css('.mx-look-opt .mxl-art', 'backgroundImage')).includes('mx-look.jpg'), 'slides sit on a detailed HyperOS wallpaper, so blur and glass show');
  await page.click('#mx-looks [data-look="plain"]'); await page.waitForTimeout(300);
  eq(['0', '0'], await page.evaluate(() => [document.documentElement.dataset.mxTex, document.documentElement.dataset.mxGlass]), 'the plain slide switches textures and glass off');
  eq('none', await css('.nav-bar', 'backdropFilter'), 'plain: the navigation bar is solid, no blur');
  eq('rgb(255, 255, 255)', await css('.nav-bar', 'backgroundColor'), 'and opaque');
  eq('plain', await page.$eval('#mx-looks [aria-checked="true"]', e => e.dataset.look), 'the chosen slide is marked');
  await page.click('#mx-looks [data-look="glass"]'); await page.waitForTimeout(300);
  eq(['1', '1'], await page.evaluate(() => [document.documentElement.dataset.mxTex, document.documentElement.dataset.mxGlass]), 'glass comes on top of textures');
  const gl = await css('.nav-bar', 'backdropFilter');
  truthy(/blur/.test(gl) && !/url\(/.test(gl), 'glass: a light blur, no SVG filter (Android WebView shows a hole for it): ' + gl);
  eq('1px', await css('.nav-bar', 'padding', '::after'), 'with a rim drawn along the outline');
  truthy(/Жидкое стекло/.test(await page.textContent('#mx-look-desc')), 'the chosen look is explained under the slides');
  await page.click('#mx-looks [data-look="tex"]'); await page.waitForTimeout(300);
  await page.evaluate(() => closeSheet()); await page.waitForTimeout(400);
  await page.evaluate(() => navigate('control')); await page.waitForTimeout(700);
  eq('block', await css('.page[data-page="control"] .mx-aurora', 'display'), 'the home screen has the living glow');
  const m1 = await page.$eval('.mx-aurora .a1', e => e.style.transform + '|' + e.style.opacity);
  await page.waitForTimeout(600);
  const m2 = await page.$eval('.mx-aurora .a1', e => e.style.transform + '|' + e.style.opacity);
  truthy(m1 && m1 !== m2 && /translate/.test(m2), 'and it moves and pulses: ' + m1 + ' → ' + m2);
  await page.evaluate(() => navigate('lists')); await page.waitForTimeout(1300);
  const s1 = await page.$eval('.mx-aurora .a1', e => e.style.transform);
  await page.waitForTimeout(500);
  eq(s1, await page.$eval('.mx-aurora .a1', e => e.style.transform), 'while the home screen is not shown, it stands still');
  await page.waitForTimeout(1500);
  await page.evaluate(() => navigate('control')); await page.waitForTimeout(120);
  const nums = t => (t.match(/-?[\d.]+/g) || []).map(Number);
  const s2 = await page.$eval('.mx-aurora .a1', e => e.style.transform);
  const jump = Math.max(...nums(s1).map((v, i) => Math.abs(v - nums(s2)[i])));
  truthy(jump < 3, 'back on the home screen it goes on from the same frame, without a jump: ' + s1 + ' → ' + s2);
  await page.waitForTimeout(300);
  truthy(await page.$eval('.mx-aurora .a1', e => e.style.transform) !== s2, 'and moves on at once, without a pause');
  await page.waitForTimeout(600);
  eq('static', await page.evaluate(() => getComputedStyle(document.querySelector('.page[data-page="lists"]')).position === 'fixed' ? 'static' : getComputedStyle(document.querySelector('.page[data-page="lists"]')).position), 'other tabs keep their own layout');
  await page.evaluate(() => setMxLook('aurora', false)); await page.waitForTimeout(200);
  eq('none', await css('.page[data-page="control"] .mx-aurora', 'display'), 'the glow can be switched off');
  await page.evaluate(() => setMxLook('aurora', true));

  sect('home title in one line');
  for (const w of [340, 400]) {
    await page.setViewportSize({ width: w, height: 860 }); await page.waitForTimeout(400);
    const g = await page.evaluate(() => { const h = document.querySelector('.page[data-page="control"] > .mx-title'), tx = h.querySelector('.mx-title-text'), lg = h.querySelector('.brand-logo');
      const a = tx.getBoundingClientRect(), b = lg.getBoundingClientRect();
      return { lines: Math.round(a.height / parseFloat(getComputedStyle(tx).lineHeight)), fs: parseFloat(getComputedStyle(tx).fontSize), sameRow: Math.abs((a.top + a.bottom) / 2 - (b.top + b.bottom) / 2) < 8, fits: b.right <= innerWidth };
    });
    eq({ lines: 1, sameRow: true, fits: true }, { lines: g.lines, sameRow: g.sameRow, fits: g.fits }, w + ' px: the module name stays on one line with its logo (font ' + g.fs + ' px)');
  }
  await page.setViewportSize({ width: 400, height: 860 }); await page.waitForTimeout(300);

  sect('opening splash and the busy indicator');
  eq(null, await page.$('#splash'), 'the opening splash is gone once the status screen is ready');
  await page.evaluate(() => busy(true, false)); await page.waitForTimeout(1300);
  const pb = await page.$eval('#progress-top', e => { const r = e.getBoundingClientRect(), cs = getComputedStyle(e); return { w: Math.round(r.width), h: Math.round(r.height), round: cs.borderRadius, centre: Math.round(r.left + r.width / 2), bar: getComputedStyle(e.querySelector('.progress-linear')).display }; });
  eq({ w: 44, h: 44, round: '50%', centre: 200, bar: 'none' }, pb, 'HyperOS: a round floating capsule with a spinner at the top centre instead of a line in the air');
  await page.evaluate(() => busy(false, false)); await page.waitForTimeout(200);
  eq(true, await page.$eval('#progress-top', e => e.hidden), 'and it goes when done');

  sect('home: progressive blur under the status bar');
  eq(null, await page.$('#sb-scrim'), 'no status bar scrim: the system colours its icons itself');
  await page.evaluate(() => navigate('control')); await page.waitForTimeout(600);
  eq('0', await css('.mx-home-fade', 'opacity'), 'at the top of the home screen nothing is blurred');
  await page.evaluate(() => { $('content').style.minHeight = '2000px'; scrollToY(200); }); await page.waitForTimeout(700);
  eq('1', await css('.mx-home-fade', 'opacity'), 'scrolled — cards going under the status bar blur, fading in');
  eq(['blur(1.5px)', 'blur(4px)', 'blur(8px)', 'blur(16px)'], await page.$$eval('.mx-home-fade i', l => l.map(e => getComputedStyle(e).backdropFilter)), 'the blur grows towards the edge, layer by layer');
  truthy(/opacity/.test(await css('.mx-home-fade', 'transition')), 'it comes and goes smoothly');
  await page.evaluate(() => { scrollToY(0); $('content').style.minHeight = ''; }); await page.waitForTimeout(400);

  sect('the settings index');
  eq('rgb(247, 247, 247)', await css('body', 'backgroundColor'), 'the page is #F7F7F7');
  eq('rgba(0, 0, 0, 0)', await css('#settings-body .list', 'backgroundColor'), 'rows lie on the background, not on cards');
  eq('rgb(52, 130, 255)', await css('#settings-body .li-icon[data-tone="blue"]', 'backgroundColor'), 'each row has a coloured square icon');
  truthy(await page.$$eval('#settings-body .li-icon[data-tone]', l => new Set(l.map(e => getComputedStyle(e).backgroundColor)).size >= 6), 'in different colours');
  eq('none', await css('#settings-body .li-secondary', 'display'), 'no explanations under the titles');
  eq('0', await page.$eval('#settings-body .subhead', e => getComputedStyle(e).display === 'none' ? '0' : '1'), 'no group titles: groups are split by a line');
  truthy(await page.$eval('#settings-body > .stack + .stack', e => parseFloat(getComputedStyle(e).borderTopWidth) > 0), 'a line between the groups');
  const lang = await page.$eval('#settings-body .list-item[data-long="lang"]', e => e.textContent);
  truthy(/Русский/.test(lang), 'the language row shows its value on the right');
  truthy(await page.$eval('#settings-body .list-item[data-long="lang"] use[href="#i-unfold"]', e => !!e), 'with ⇅: it opens a choice, not a screen');

  sect('inner screens');
  await page.evaluate(() => navigate('work')); await page.waitForTimeout(700);
  eq('rgb(255, 255, 255)', await css('.page.active .list', 'backgroundColor'), 'a group of rows is a white card');
  eq('16px', await css('.page.active .list', 'borderTopLeftRadius'), 'with 16dp corners');
  eq('rgba(0, 0, 0, 0)', await css('.page.active .list-item', 'backgroundColor'), 'its rows have no backgrounds of their own');
  eq('none', await css('.page.active .list-item .li-icon', 'display'), 'and no icons: the text says what a row does');
  const sw = await box('.page.active .switch');
  eq([49, 28], [sw.w, sw.h], 'the switch is 49×28');
  eq('none', await css('.page.active .switch', 'display', '::after'), 'without the check mark of M3');
  eq('17px', await css('.page.active .list-item .li-primary', 'fontSize'), 'row titles are 17sp');
  eq('400', await css('.page.active .list-item .li-primary', 'fontWeight'), 'of regular weight');
  eq('rgba(0, 0, 0, 0.6)', await css('.page.active .subhead', 'color'), 'group titles are small and grey');

  sect('a choice of one: a check on the right');
  await page.evaluate(() => navigate('apps')); await page.waitForTimeout(900);
  const radio = await page.$eval('#amode-list .list-item .radio:checked', e => { const r = e.getBoundingClientRect(), p = e.closest('.list-item').getBoundingClientRect(); return p.right - r.right; });
  truthy(radio < 40, 'the mark of the chosen mode is at the right edge (' + Math.round(radio) + ' px)');
  eq('rgb(52, 130, 255)', await css('#amode-list .list-item:has(.radio:checked) .li-primary', 'color'), 'and the chosen mode is blue');

  sect('the app list');
  eq('none', await css('#pk-filter-chips', 'display'), 'no filter chips');
  truthy(/Показывать/i.test(await page.$eval('#pk-sort', e => e.textContent)) && await page.$eval('#pk-sort', e => getComputedStyle(e).display !== 'none'), 'the filter is a header line «Показывать: … ⇅»');
  await page.click('#pk-sort'); await page.waitForTimeout(300);
  eq(4, await page.$$eval('.menu .mi', l => l.length), 'it opens the four choices');
  const pick = await page.$eval('.menu .mi:has(use[href="#i-check"])', e => { const i = e.querySelector('.mi-icon').getBoundingClientRect(), t = e.querySelector('.mi-text').getBoundingClientRect();
    return { right: i.left > t.right, color: getComputedStyle(e).color }; });
  truthy(pick.right, 'the check of the current choice is on the right, as DropdownImpl');
  eq('rgb(52, 130, 255)', pick.color, 'and the current choice is blue');
  eq('none', await css('#pk-sort', 'textTransform'), 'the header is in sentence case, as other group titles');
  await page.click('.menu .mi:nth-child(4)'); await page.waitForTimeout(400);
  truthy(/Выбранные/.test(await page.$eval('#pk-sort', e => e.textContent)), 'and shows the chosen one');
  await page.evaluate(() => setAppTypeFilter('all')); await page.waitForTimeout(300);
  const cb = await box('#pk .checkbox');
  eq([49, 28], [cb.w, cb.h], 'an app is switched with a switch, as in the notification list');
  truthy(await page.$eval('#pk .li-trail', e => parseFloat(getComputedStyle(e).borderLeftWidth) > 0), 'behind a vertical line');
  eq('rgb(255, 255, 255)', await css('.page.active .row:has(> .btn.text)', 'backgroundColor'), 'the actions under the list are a card');
  eq('rgb(52, 130, 255)', await css('.page.active .row:has(> .btn.text) .btn', 'color'), 'with blue text');
  await page.evaluate(() => navigate('work')); await page.waitForTimeout(600);

  sect('the large title is part of the page and scrolls with it');
  const T = '.page.active > .mx-title';
  eq('flex', await css(T, 'display'), 'a large title on top of the page');
  eq('Работа модуля', await page.$eval(T, e => e.textContent), 'with the screen name');
  eq('32px', await css(T, 'fontSize'), '32sp, as TopAppBar of miuix');
  eq('0', await css('#app-title', 'opacity'), 'the small title is hidden at the top');
  eq('rgba(0, 0, 0, 0)', await css('#app-bar', 'backgroundColor'), 'the bar is see-through above the page top');
  // в том же кадре: заголовок двигает сама прокрутка, а не обработчик после неё
  const moved = await page.evaluate(() => { $('content').style.minHeight = '3000px';
    const h = document.querySelector('.page.active > .mx-title'), y0 = h.getBoundingClientRect().top;
    scrollToY(120); return Math.round(y0 - h.getBoundingClientRect().top); });
  eq(120, moved, 'the title moves with the scroll at once, with no lag');
  await page.evaluate(() => scrollToY(300)); await page.waitForTimeout(500);
  truthy(await page.$eval('#app-bar', e => e.classList.contains('mx-collapsed')), 'scrolled under the bar — the bar collapses');
  await page.waitForFunction(() => getComputedStyle($('app-title')).opacity === '1', null, { timeout: 3000 }).catch(() => {});
  eq('1', await css('#app-title', 'opacity'), 'the small title shows');
  await page.evaluate(() => { scrollToY(0); $('content').style.minHeight = ''; }); await page.waitForTimeout(400);
  eq(false, await page.$eval('#app-bar', e => e.classList.contains('mx-collapsed')), 'back at the top it unfolds');
  const wrap = await page.evaluate(() => { const h = document.querySelector('.page.active > .mx-title'), x = h.querySelector('.mx-title-text'), t0 = x.textContent;
    x.textContent = 'Подробная информация и характеристики'; const r = [h.offsetHeight, h.scrollWidth <= h.clientWidth + 1]; x.textContent = t0; return r; });
  truthy(wrap[0] >= 80 && wrap[1], 'a long title wraps onto the next line instead of being cut: ' + wrap[0] + 'px');
  await page.evaluate(() => goBack()); await page.waitForTimeout(600);

  sect('screen transitions, as MiuixDefault of miuix-nav');
  await page.evaluate(() => navigate('settings')); await page.waitForTimeout(900);
  const mid = await page.evaluate(() => new Promise(res => {
    const from = document.querySelector('.page.active'); navigate('work'); const to = document.querySelector('.page.active');
    setTimeout(() => res({ from: from.getBoundingClientRect().left, to: to.getBoundingClientRect().left,
      dim: +getComputedStyle(document.querySelector('.mx-dim')).opacity, op: +getComputedStyle(from).opacity,
      bg: getComputedStyle(to, '::before').backgroundColor }), 120);
  }));
  truthy(mid.to > 12 && mid.to < 412, 'the new screen slides in from the right: ' + Math.round(mid.to));
  truthy(mid.from < 12 && mid.from > -103 - 1, 'the old one moves left, at most a quarter of the width: ' + Math.round(mid.from));
  truthy(mid.dim > 0 && mid.dim <= .5, 'and darkens under it: ' + mid.dim.toFixed(2));
  truthy(mid.op < 1 && mid.op >= .9, 'and fades a little: ' + mid.op.toFixed(2));
  eq('rgb(247, 247, 247)', mid.bg, 'the new screen is an opaque sheet while it moves');
  await page.waitForTimeout(700);
  eq([0, 0], await page.evaluate(() => [document.querySelectorAll('.mx-dim').length, document.querySelectorAll('.page.leaving, .page.mx-surface').length]), 'nothing is left over after the transition');
  const backMid = await page.evaluate(() => new Promise(res => { const from = document.querySelector('.page.active'); goBack();
    setTimeout(() => res(from.getBoundingClientRect().left), 120); }));
  truthy(backMid > 12, 'back: the screen leaves to the right: ' + Math.round(backMid));
  await page.waitForTimeout(800);
  eq('settings', await page.evaluate(() => currentPage), 'and the parent is back');
  // уже открытая вкладка обновляет данные, когда перелистывание закончилось
  const initAt = await page.evaluate(() => new Promise(res => {
    const m = PAGE_META.control, o = m.init; m.init = () => { m.init = o; res(transitionCleanup ? 'during' : 'after'); return o(); };
    navigate('control');
  }));
  eq('after', initAt, 'an open tab reloads its data after the slide, not in the middle of it');
  await page.waitForTimeout(400);

  sect('header, logo, notifications');
  await page.evaluate(() => navigate('control')); await page.waitForTimeout(800);
  const lg = await page.evaluate(() => { const l = $('brand-logo'), t = document.querySelector('.page.active > .mx-title .mx-title-text');
    const a = l.getBoundingClientRect(), b = t.getBoundingClientRect();
    return { inTitle: !!l.closest('.page[data-page="control"] > .mx-title'), right: a.left >= b.right, row: Math.abs((a.top + a.bottom) / 2 - (b.top + b.bottom) / 2) < 8, shown: getComputedStyle(l).display !== 'none' }; });
  truthy(lg.inTitle && lg.shown, 'the module logo (the game egg) sits in the large title of the main screen');
  truthy(lg.right && lg.row, 'right of the name, on the same line');
  const lgb = await page.evaluate(() => { const r = $('logs-btn').getBoundingClientRect(); return [Math.round(r.right), innerWidth]; });
  truthy(lgb[1] - lgb[0] <= 16, 'the logs icon stays on the right of the bar: ' + (lgb[1] - lgb[0]) + 'px from the edge');
  await page.evaluate(() => navigate('work')); await page.waitForTimeout(800);
  await page.evaluate(() => { $('content').style.minHeight = '3000px'; scrollToY(300); }); await page.waitForTimeout(500);
  const tc = await page.evaluate(() => { const r = $('app-title').getBoundingClientRect(), tw = document.createRange(); tw.selectNodeContents($('app-title'));
    const t = tw.getBoundingClientRect(); return Math.round((t.left + t.right) / 2 - innerWidth / 2); });
  truthy(Math.abs(tc) <= 2, 'the small title in the bar is centred, as in HyperOS: ' + tc + 'px off');
  // отскок у края двигает страницу, но не прокрутку: шапка от него не сворачивается
  await page.evaluate(() => { scrollToY(0); document.querySelector('.page.active').style.transform = 'translateY(-200px)'; barScroll(); });
  eq(false, await page.$eval('#app-bar', e => e.classList.contains('mx-collapsed')), 'a bounce at the edge does not collapse the bar: no two titles at once');
  await page.evaluate(() => { document.querySelector('.page.active').style.transform = ''; $('content').style.minHeight = ''; barScroll(); });
  const os = await page.evaluate(() => [mxOverscroll(100), mxOverscroll(innerHeight), innerHeight].map(Math.round));
  truthy(os[0] <= 55 && os[1] <= os[2] / 3 + 1, 'pulling past the edge is stiff: 100 px of finger moves the page ' + os[0] + ' px, a full screen — ' + os[1]);
  const peak = await page.evaluate(() => new Promise(res => { const el = document.querySelector('.page.active'); stretchAbsorb(true, 8);
    let m = 0; const t0 = performance.now(); (function f(){ const tr = new DOMMatrix(getComputedStyle(el).transform); m = Math.max(m, Math.abs(tr.m42));
      if (performance.now() - t0 < 500) requestAnimationFrame(f); else res(Math.round(m)); })(); }));
  truthy(peak > 0 && peak <= 70, 'a hard fling into the edge bounces, but not by a hundred pixels: ' + peak + ' px at most');
  const slow = await page.evaluate(() => new Promise(res => { const el = document.querySelector('.page.active'); stretchAbsorb(true, .6);
    let m = 0; const t0 = performance.now(); (function f(){ const tr = new DOMMatrix(getComputedStyle(el).transform); m = Math.max(m, Math.abs(tr.m42));
      if (performance.now() - t0 < 500) requestAnimationFrame(f); else res(Math.round(m)); })(); }));
  truthy(slow >= 10, 'a scroll that reaches the edge already slowing down still bounces visibly: ' + slow + ' px');
  await page.evaluate(() => toast('Список приложений обновлён')); await page.waitForTimeout(700);
  const sn = await page.evaluate(() => { const e = $('prompt-container'), c = getComputedStyle(e);
    return { r: c.borderTopLeftRadius, w: e.getBoundingClientRect().width, blur: /blur/.test(c.backdropFilter || c.webkitBackdropFilter || ''), ic: getComputedStyle(e.querySelector('.snack-ic')).display }; });
  eq('28px', sn.r, 'a notification is a pill');
  truthy(sn.w < 412 - 40 && sn.blur, 'as wide as its text, on a blurred backdrop: ' + Math.round(sn.w) + 'px');
  eq('grid', sn.ic, 'with the module icon on the left');
  await page.evaluate(() => $('prompt-container').classList.remove('show'));

  sect('dialog from the bottom');
  await page.evaluate(() => { window.__d = mdConfirm('Перезапустить службу?', 'Обход прервётся на пару секунд.', { ok: 'Перезапустить' }); });
  await page.waitForSelector('#dialog-wrap.open'); await page.waitForTimeout(500);
  const d = await box('.dialog');
  truthy(860 - d.bottom <= 16, 'the dialog sits at the bottom of the screen (' + (860 - d.bottom) + ' px)');
  eq('32px', await css('.dialog', 'borderTopLeftRadius'), 'with 32dp corners');
  eq('center', await css('.dialog .d-title', 'textAlign'), 'the title is centred');
  const btns = await page.$$eval('.dialog .d-actions .btn:not([hidden])', l => l.map(e => Math.round(e.getBoundingClientRect().width)));
  truthy(btns.length === 2 && Math.abs(btns[0] - btns[1]) <= 1, 'the two buttons share the width equally: ' + btns);
  eq('rgb(52, 130, 255)', await css('#d-ok', 'backgroundColor'), 'the main one is filled with the accent');
  await page.click('#d-cancel'); await page.waitForTimeout(300);

  sect('navigation bar');
  await page.evaluate(() => navigate('control')); await page.waitForTimeout(700);
  eq('1', await css('.nav-dest[aria-current="page"]', 'opacity', '::before'), 'the current tab sits in its own pill, as in HyperOS 3');
  const pill = await css('.nav-dest[aria-current="page"]', 'backgroundColor', '::before');
  truthy(/0\.20\d* 0\.50\d* 1 \/ 0\.1|52, 130, 255, 0\.1/.test(pill), 'a light blue one: ' + pill);
  eq('rgb(52, 130, 255)', await css('.nav-dest[aria-current="page"]', 'color'), 'with a blue icon and label');
  eq('1', await css('.nav-dest:not([aria-current])', 'opacity'), 'other tabs are not faded: the bar does not look grey');
  eq('rgb(0, 0, 0)', await css('.nav-dest:not([aria-current])', 'color'), 'they are in the text colour');

  sect('status card');
  eq('rgb(255, 255, 255)', await css('#hero-status', 'backgroundColor'), 'the status card is a white card, not filled with the accent');
  await page.evaluate(() => { const c = $('hero-status').cloneNode(true); c.id = 'hero-probe'; c.querySelectorAll('[id]').forEach(e => e.removeAttribute('id')); c.style.transition = 'none'; c.querySelectorAll('*').forEach(e => e.style.transition = 'none'); $('hero-status').after(c); c.className = 'hero running'; });
  eq('rgb(255, 255, 255)', await css('#hero-probe', 'backgroundColor'), 'also while running');
  eq('rgb(52, 130, 255)', await css('#hero-probe .hero-icon', 'backgroundColor'), 'running: the icon is blue');
  eq('rgb(0, 0, 0)', await css('#hero-probe .hero-state', 'color'), 'the state is plain black text');
  eq('rgb(240, 240, 240)', await css('#hero-probe .hero-actions .btn', 'backgroundColor'), '«Stop» is a grey secondary button');
  await page.evaluate(() => { $('hero-probe').className = 'hero paused'; });
  eq('rgb(255, 138, 0)', await css('#hero-probe .hero-icon', 'backgroundColor'), 'paused: the icon is orange');
  await page.evaluate(() => { $('hero-probe').className = 'hero'; });
  eq('rgb(52, 130, 255)', await css('#hero-probe .hero-actions .btn', 'backgroundColor'), 'stopped: «Start» is the blue button');
  await page.evaluate(() => $('hero-probe').remove());
  truthy(await page.$eval('.nav-bar', e => /blur/.test(getComputedStyle(e).backdropFilter || getComputedStyle(e).webkitBackdropFilter || '')), 'the bar keeps its blur');
  const nb = await box('.nav-bar');
  truthy(860 - nb.bottom >= 8, 'and floats above the bottom edge');

  sect('back to Material 3');
  await page.evaluate(() => setDesign('m3')); await page.waitForTimeout(300);
  eq('m3', await page.evaluate(() => document.documentElement.dataset.design), 'Material 3 again');
  await page.evaluate(() => navigate('work')); await page.waitForTimeout(700);
  const back = await box('.page.active .switch');
  eq([52, 32], [back.w, back.h], 'the M3 switch is back');
  eq('none', await css('.page.active > .mx-title', 'display'), 'and no large title');
  truthy(await page.evaluate(() => $('brand-logo').parentElement === $('app-bar')), 'the logo is back in the bar, next to the name');
  truthy(await page.evaluate(() => getComputedStyle(document.documentElement).getPropertyValue('--mx-card').trim() === ''), 'no miuix variables are left in the theme');

  sect('English');
  await page.evaluate(() => { setDesign('miuix'); setLanguage('en'); openSheet('monet-modal'); }); await page.waitForTimeout(600);
  const txt = await page.$eval('#monet-modal', e => e.textContent);
  truthy(/Design/.test(txt), 'the new choice is translated');

  eq([], errors, 'no page errors');
  await browser.close();
  process.stdout.write('\n----------------------------------------\n');
  if (!failures.length) { process.stdout.write(`PASS  ${pass} checks\n`); process.exit(0); }
  process.stdout.write(`FAIL  ${failures.length} of ${pass + failures.length} checks failed\n`);
  for (const f of failures) process.stdout.write(`   - ${f}\n`);
  process.exit(1);
})();
