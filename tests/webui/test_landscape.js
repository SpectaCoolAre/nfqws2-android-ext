#!/usr/bin/env node
/*
 * Альбомная ориентация: каждый экран — две равные колонки по центру с
 * одинаковыми полями слева и справа, левая (главное) закреплена, ничего не
 * вылезает за экран и не тянется во всю ширину планшета; группы настроек —
 * в две колонки; навигация — компактная, значок и подпись в строку.
 * Плюс «Отключать DNS на Wi‑Fi» на «Работе модуля»: серая, пока выключена
 * пауза на Wi‑Fi.
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
const SHOTS = process.env.SHOTS || '';
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
         { id: 'wifi-1', label: 'Home', sites: 12, ok: 40, err: 30, current: 0 },
         { id: 'wifi-2', label: 'Дача', home: 1, sites: 7, ok: 20, err: 2, current: 0 }],
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
const bv = (n, name, tests, ok, tls, ttfb, uniq, f16, reset, timeout) => ({ n, name, tests, ok, ms_tls: tls, ms_ttfb: ttfb, uniq, f16, reset, timeout, other: 0 });
const BENCH_REP = JSON.stringify({ net: 'mobile-25001', hosts: 114, skipped: 9, noconn: 'privateinternetaccess.com', fams: [
  { fam: 'google', blocked: 9, solved: 9, unblocked: 0, unsolved: '', variants: [bv(1, 'hardcorp74: Google', 27, 27, 96, 310, 2, 0, 0, 0), bv(13, 'alt9: Google', 27, 19, 140, 420, 0, 0, 2, 6)] },
  { fam: 'tls', blocked: 61, solved: 57, unblocked: 35, unsolved: 'lrclib.net mi.com rferl.org svoboda.org', noconn: 'cloudflarestatus.com', variants: [
    bv(1, 'MartinBacker #1', 183, 165, 88, 360, 3, 2, 4, 12), bv(6, 'MartinBacker: Cloudflare', 183, 151, 92, 380, 5, 0, 9, 23),
    Object.assign(bv(29, 'FAKE TLS AUTO ALT2', 61, 44, 120, 450, 1, 3, 2, 12), { conn: 7 }), bv(14, 'без обхода', 61, 0, -1, -1, 0, 0, 30, 31)] }] });
const STUB = `window.__calls = []; window.__strat = 'smart';
window.ksu = { exec: function(cmd, o, cb){
  var id = [o, cb].reverse().find(function(x){ return typeof x === 'string'; });
  window.__calls.push(cmd);
  var out = 'OK', rc = 0;
  if (cmd.indexOf('json-status') >= 0) out = ${JSON.stringify(STATUS)}.replace('"home_wifi":0', '"home_wifi":' + (window.__home || 0));
  else if (cmd.indexOf('get-logs') >= 0) out = 'line one\\nline two';
  else if (cmd.indexOf("'dns-state'") >= 0) out = '#status\\nenabled=1\\ndefault=net\\nproxy=running\\nrules=on\\nipv6=redirect\\nprivate=off\\nnet_dns=192.168.1.1\\nhits=1234\\nmax_profiles=32\\nmax_servers=12\\nmax_domains=1000\\nsmart=1\\ncdn=running\\ngeo=on\\ngeo_domains=722\\ngeo_updated=\\n#profile instagram\\nNAME=Instagram\\nENABLED=1\\nSERVER=https://doh.cleanbrowsing.org/doh/family-filter/\\nDOMAIN=instagram.com';
  else if (cmd.indexOf('get-list') >= 0) out = 'example.com\\nsite.org';
  else if (cmd.indexOf('list-apps') >= 0) out = 'com.termux\\ncom.example.one';
  else if (cmd.indexOf("'set' 'HOME_WIFI'") >= 0) { window.__home = cmd.indexOf("'1'") >= 0 ? 1 : 0; out = 'OK'; }
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
  else if (cmd.indexOf("'smart-bench' 'status'") >= 0) out = JSON.stringify(window.__bench || { running: 0, stage: 'done', hosts: 114, done1: 114, hosts2: 61, done2: 61, tests: 4710, start: 1700000000, end: 1700002400, stopped: 0 });
  else if (cmd.indexOf("'smart-bench' 'report'") >= 0) out = ${JSON.stringify(BENCH_REP)};
  else if (cmd.indexOf("'smart-bench' 'start'") >= 0) { window.__bench = { running: 1, stage: '1', hosts: 114, done1: 23, hosts2: 0, done2: 0, tests: 812, prep: 114, plan: 3300, planned: 640, start: Math.floor(Date.now() / 1000) - 420, end: 0, stopped: 0 }; }
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

const PAGES = ['control', 'lists', 'logs', 'config', 'settings', 'work', 'wifi', 'dns', 'hosts', 'test', 'diag', 'apps'];
const VIEWPORTS = [
  { w: 915, h: 412, label: 'phone 915×412' },
  { w: 780, h: 360, label: 'small phone 780×360' },
  { w: 1280, h: 800, label: 'tablet 1280×800' },
];

(async () => {
  let browser;
  try { browser = await chromium.launch(); } catch (e) {
    process.stdout.write('SKIP  chromium is not available: ' + e.message.split('\n')[0] + '\n');
    process.exit(0);
  }
  for (const vp of VIEWPORTS) {
    const ctx = await browser.newContext({ viewport: { width: vp.w, height: vp.h }, deviceScaleFactor: 2, isMobile: true, hasTouch: true });
    await ctx.addInitScript(STUB);
    await ctx.addInitScript(() => { try { localStorage.setItem('nfq_seen_ver', 'v2.2.1'); } catch (e) {} });
    const page = await ctx.newPage();
    const errors = [];
    page.on('pageerror', e => errors.push(e.message));
    await page.goto(INDEX, { waitUntil: 'load' });
    await page.waitForTimeout(900);

    sect(`${vp.label}: navigation`);
    const nav = await page.evaluate(() => {
      const d = document.querySelector('.nav-dest'), b = document.getElementById('nav-bar').getBoundingClientRect();
      return { dir: getComputedStyle(d).flexDirection, h: Math.round(b.height), l: Math.round(b.left), r: Math.round(innerWidth - b.right) };
    });
    eq('row', nav.dir, 'icon and label side by side');
    truthy(nav.h <= 52, `the bar is compact (${nav.h} px)`);
    truthy(Math.abs(nav.l - nav.r) <= 2, `and centred (${nav.l} / ${nav.r})`);

    for (const p of PAGES) {
      sect(`${vp.label}: ${p}`);
      await page.evaluate(pg => { if (pg !== 'control') navigate(pg); }, p);
      await page.waitForTimeout(1100);
      const g = await page.evaluate(() => {
        const pg = document.querySelector('.page.active');
        const r = pg.getBoundingClientRect();
        const cols = [...pg.children].filter(c => c.classList.contains('pcol')).map(c => {
          const b = c.getBoundingClientRect(); return { l: b.left, r: b.right, w: b.width, pos: getComputedStyle(c).position, lead: c.classList.contains('pcol-lead') };
        });
        const grid = pg.querySelector('.settings-grid, .cols2');
        // что-то шире своей колонки или экрана
        let over = '';
        pg.querySelectorAll('*').forEach(e => {
          if (over || !e.getClientRects().length) return;
          const b = e.getBoundingClientRect();
          if (b.width && (b.right > innerWidth + 1 || b.left < -1)) over = (e.id || e.className || e.tagName) + ' ' + Math.round(b.left) + '..' + Math.round(b.right);
        });
        return { l: r.left, r: innerWidth - r.right, w: r.width, cols, gridCols: grid ? getComputedStyle(grid).columnCount : null,
                 split: pg.classList.contains('split'), over, scrollW: document.documentElement.scrollWidth };
      });
      truthy(Math.abs(g.l - g.r) <= 2, `symmetric side margins (${Math.round(g.l)} / ${Math.round(g.r)})`);
      truthy(g.w <= 1120 + 1, `no wider than 1120 px (${Math.round(g.w)})`);
      truthy(g.l >= 24, `with a margin of at least 24 px (${Math.round(g.l)})`);
      eq('', g.over, 'nothing sticks out of the screen');
      truthy(g.scrollW <= vp.w, 'no horizontal scroll');
      if (g.split) {
        eq(2, g.cols.length, 'two columns');
        if (g.cols.length === 2) {
          truthy(Math.abs(g.cols[0].w - g.cols[1].w) <= 8, `of equal width (${Math.round(g.cols[0].w)} / ${Math.round(g.cols[1].w)})`);
          truthy(g.cols[0].r <= g.cols[1].l, 'side by side');
          if (g.cols[0].lead) eq('sticky', g.cols[0].pos, 'the main column stays in place');
        }
      } else {
        eq('2', g.gridCols, 'groups are laid out in two columns');
      }
      if (SHOTS) await page.screenshot({ path: path.join(SHOTS, `land-${vp.w}-${p}.png`) });
      await page.evaluate(() => { while (PAGE_META[currentPage] && PAGE_META[currentPage].child) goBack(); navigate('control'); });
      await page.waitForTimeout(500);
    }

    sect(`${vp.label}: main column stays while the right one scrolls`);
    await page.evaluate(() => navigate('config')); await page.waitForTimeout(1100);
    const y0 = await page.evaluate(() => document.querySelector('.page.active .pcol-lead').getBoundingClientRect().top);
    // немного, а не до конца: у самого конца страницы закреплённая колонка
    // уезжает вместе с ней — так и должно быть
    await page.evaluate(() => { const sc = document.getElementById('scroller'); sc.scrollTop = Math.min(120, (sc.scrollHeight - sc.clientHeight) / 3); });
    await page.waitForTimeout(300);
    const y1 = await page.evaluate(() => document.querySelector('.page.active .pcol-lead').getBoundingClientRect().top);
    const scrolled = await page.evaluate(() => document.getElementById('scroller').scrollTop);
    if (scrolled > 0) truthy(Math.abs(y1 - y0) <= 1, `the mode and the hero do not move (${Math.round(y0)} → ${Math.round(y1)})`);
    else ok('the page fits the screen, nothing to scroll');
    const lead = await page.evaluate(() => [...document.querySelectorAll('.page.active .pcol-lead > :not([hidden])')].map(e => e.id || e.className));
    truthy(lead.includes('mode-seg') && lead.includes('smart-lead'), 'the mode switch and the hero are in the main column: ' + lead.join(', '));
    await page.evaluate(() => { document.getElementById('scroller').scrollTop = 0; navigate('control'); }); await page.waitForTimeout(500);
    const tilesRight = await page.evaluate(() => document.getElementById('live-tiles').getBoundingClientRect().left > innerWidth / 2 - 20);
    truthy(tilesRight, 'state: the live tiles are on the right, next to the service card');

    eq(0, errors.length, 'no page errors' + (errors.length ? ': ' + errors.join('; ') : ''));
    await ctx.close();
  }

  sect('work: DNS on home Wi‑Fi follows the Wi‑Fi pause');
  {
    const ctx = await browser.newContext({ viewport: { width: 412, height: 892 }, isMobile: true, hasTouch: true });
    await ctx.addInitScript(STUB);
    const page = await ctx.newPage();
    await page.goto(INDEX, { waitUntil: 'load' }); await page.waitForTimeout(800);
    await page.evaluate(() => navigate('work')); await page.waitForTimeout(800);
    const order = await page.$$eval('#work-body .list .li-primary', l => l.map(e => e.textContent));
    const i = order.indexOf('Отключать DNS на Wi‑Fi');
    truthy(i > 0 && order[i - 1] === 'Отключать на Wi‑Fi' && order[i + 1] === 'Отключать при VPN', 'between the Wi‑Fi and the VPN pause: ' + order.slice(0, 4).join(', '));
    eq(true, await page.$eval('#work-dns-home', e => e.disabled), 'greyed out while the Wi‑Fi pause is off');
    truthy(await page.$eval('#work-dns-home', e => e.closest('.list-item').classList.contains('is-disabled')), 'the whole row looks inactive');
    eq(0, await page.$$eval('#wifi-body #wifi-dns', l => l.length), 'and it is gone from the Wi‑Fi screen');
    await page.click('#work-wifi', { force: true }); await page.waitForTimeout(900);
    eq(false, await page.$eval('#work-dns-home', e => e.disabled), 'the Wi‑Fi pause on — it can be switched');
    await page.click('#work-dns-home', { force: true }); await page.waitForTimeout(600);
    truthy(await page.evaluate(() => window.__calls.some(c => c.indexOf("'dns-set-home' '1'") >= 0)), 'and saves the DNS pause');
    await ctx.close();
  }

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
