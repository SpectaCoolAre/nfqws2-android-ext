#!/usr/bin/env node
/*
 * Browser tests for webroot/index.html: rendered geometry, plus the handful of
 * interactions whose cost or correctness only shows up in a real page (the
 * package search, which must not shell out per keystroke).
 *
 * The page is a KernelSU WebUI: it renders its lists from `ksu.exec` output, so
 * opening the file in a browser shows an empty skeleton and every visual
 * conclusion drawn from it is wrong. This test stubs the bridge, renders the
 * page in headless Chromium at real device widths and asserts the geometry —
 * which is how the layout regressions fixed on 2026-10-04 were found, and what
 * keeps them from coming back.
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

const REPO = path.resolve(__dirname, '..', '..');
const INDEX = 'file:///' + path.join(REPO, 'webroot', 'index.html').replace(/\\/g, '/');

// import_safe_name() strips quotes, but a file dropped straight into imports/
// (by an older version, a backup, a root shell) never went through it.
const HOSTILE_IMPORT = "x');window.__pwned=1;//";

const STATUS = JSON.stringify({
  running: true, pid: '4710', uptime: 52, strategy: 'alt13', version: 'v1.3.6', mode: 'auto',
  pkt_limit_out: 2, pkt_limit_in: 2, block_quic: 0, app_mode: 'off',
  autostart: 1, watchdog: 1, ipv6: 1, log_level: 0, qdrop: 0, queue: 300,
  app_uids: 1,
  counts: { user: 381, auto: 25, exclude: 2839, ipset: 28420, ipset_exclude: 637, apps: 1 },
});
const STRATEGIES = 'default\nalt\nalt2\nalt3\nalt13\nfake_tls_auto\nsimple_fake\nhardcorp74\nkrushaaa\nMartinBacker\nUvvi2\neduncey\nexp';

const STUB = `
window.__calls = [];
window.ksu = { exec: function(cmd, opts, cb){
  var args = [opts, cb], id = null;
  for (var i = args.length - 1; i >= 0; i--) {
    if (typeof args[i] === 'string') { id = args[i]; break; }
  }
  window.__calls.push(cmd);
  var out = 'OK';
  if (cmd.indexOf('home_paused') >= 0) out = window.__sig || 'run 4710';
  else if (cmd.indexOf('json-status') >= 0) out = window.__st ? JSON.stringify(window.__st) : ${JSON.stringify(STATUS)};
  else if (cmd.indexOf('list-strategies') >= 0) out = ${JSON.stringify(STRATEGIES)};
  else if (cmd.indexOf('get-strategy') >= 0) out = 'alt13';
  else if (cmd.indexOf('get-list') >= 0 && cmd.indexOf('apps') >= 0) out = 'com.termux\\ncom.example.one';
  else if (cmd.indexOf('get-list') >= 0) out = 'example.com';
  else if (cmd.indexOf('list-apps') >= 0) out = 'com.termux\\ncom.example.one\\ncom.example.two\\ncom.other';
  else if (cmd.indexOf('list-imports') >= 0) out = ${JSON.stringify(HOSTILE_IMPORT)};
  else if (cmd.indexOf('get-conf') >= 0) out = 'A=1';
  setTimeout(function(){ if (window[id]) window[id](0, out, ''); }, 0);
  return 'job';
}};
`;

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

const VIEWPORTS = [
  { w: 360, dpr: 2.75, label: '360px' },
  { w: 400, dpr: 2.7, label: '400px' },
  { w: 467, dpr: 2.31, label: '467px (owner device)' },
];

(async () => {
  const browser = await chromium.launch();

  for (const vp of VIEWPORTS) {
    for (const mode of ['dark', 'light']) {
      const ctx = await browser.newContext({
        viewport: { width: vp.w, height: 900 },
        deviceScaleFactor: vp.dpr, isMobile: true, hasTouch: true,
      });
      await ctx.addInitScript(`try{localStorage.setItem('m3_mode','${mode}');}catch(e){}`);
      await ctx.addInitScript(STUB);
      const page = await ctx.newPage();
      const pageErrors = [];
      page.on('pageerror', e => pageErrors.push(e.message));
      await page.goto(INDEX, { waitUntil: 'load' });
      await page.waitForTimeout(700);
      // #mode and the other list-driven controls are built by renderMode() / PAGE_META
      await page.evaluate(() => {
        if (typeof devMode !== 'undefined') devMode = true;
        if (typeof renderParams === 'function' && typeof S !== 'undefined') renderParams(S);
        if (typeof renderMode === 'function') renderMode();
        // the switches live on «Работа модуля» (Settings), built on demand
        if (typeof renderWork === 'function') renderWork();
      });
      await page.waitForTimeout(300);

      const label = `${vp.label} ${mode}`;
      sect(label);

      eq('', pageErrors.join(' | '), 'the page loads without script errors');

      const geo = await page.evaluate(() => {
        // Every probe below is null-tolerant on purpose. This suite measures a
        // specific markup, and when that markup changes the old behaviour was to
        // throw inside page.evaluate — which aborts the whole run, so nothing at
        // all got measured and the failure read as a crash rather than a report.
        // Missing elements now yield empty/zero values and the checks below say
        // which ones, which is the useful signal.
        const cs = el => (el ? getComputedStyle(el) : { borderRadius: '', gridTemplateColumns: '' });
        const box = el => (el ? el.getBoundingClientRect() : { height: 0, width: 0, left: 0, right: 0, top: 0, bottom: 0 });
        const q = s => document.querySelector(s);
        const txt = el => (el && el.textContent != null ? el.textContent : '');
        // borderRadius comes back as a shorthand: one value means all four
        // corners, two mean vertical/horizontal pairs.
        const radii = el => {
          if (!el) return [];
          const parts = cs(el).borderRadius.split(/\s+/).map(v => parseFloat(v));
          if (parts.length === 1) return [parts[0], parts[0], parts[0], parts[0]];
          if (parts.length === 2) return [parts[0], parts[1], parts[0], parts[1]];
          if (parts.length === 3) return [parts[0], parts[1], parts[2], parts[1]];
          return parts;
        };
        const out = {};

        out.statusText = txt(q('#st'));
        out.heroCounters = document.querySelectorAll('.hero-metrics, .hero .m').length;

        // The counters card and the split button are gone from the control page.
        // The numbers now sit next to each list on the lists page, and the hero
        // carries a plain start/stop button with a separate restart icon. Those
        // probes and their checks were dropped rather than repointed: there is
        // nothing on this screen to measure, and inventing a stand-in would only
        // assert that the stand-in exists.
        out.cardRadius = radii(q('.group'))[0];
        out.heroRadius = radii(q('.hero'))[0];
        const tb = box(q('#app-title')), ab = box(q('#app-bar'));
        out.titleLeftOff = Math.round(tb.left - ab.left);
        out.titleText = q('#app-title').textContent;
        const lb = box(q('#brand-logo')), gb = box(q('#logs-btn'));
        out.logoVisible = getComputedStyle(q('#brand-logo')).display !== 'none' && lb.width === 28;
        out.logoNextToTitle = lb.left >= tb.right && lb.left - tb.right <= 12;
        out.logsAtRight = !q('#logs-btn').hidden && Math.round(ab.right - gb.right) <= 16 && gb.left > lb.right;
        out.settingsTab = !!q('#nav-settings');
        out.heroLeft = Math.round(box(q('.hero')).left);

        const sws = [...document.querySelectorAll('#work-sws .list-item')];
        out.swsFirstRadius = radii(sws[0]);
        out.swsLastRadius = radii(sws[sws.length - 1]);
        out.swsMiddleRadius = sws.length > 2 ? radii(sws[1]) : [];
        out.swsRows = sws.length;
        // The container holds the switches and, below them, the packet limits. The
        // conventions are about the switches, so count them separately instead of
        // asking whether *any* row has a description — the limits have one.
        out.swsSwitchRows = sws.filter(r => r.querySelector('input.switch')).length;
        out.swsSwitchWithSecondary = sws.filter(r => r.querySelector('input.switch') && r.querySelector('.li-secondary')).length;
        out.swsHasIcons = sws.some(r => r.querySelector('.li-icon'));

        // The strategy row renders into #strategy-current; the doctor moved to the
        // diagnostics page and is not on this screen any more.
        out.strategyRowRadius = radii(q('#strategy-row.mode-card'))[0];

        // The only text field is the search bar, and it lives on the apps page —
        // hidden while this screen is up, so getBoundingClientRect returns 0. Read
        // the computed height instead: it is the layout value being pinned here.
        const searchBar = q('.search-bar');
        out.fieldHeight = searchBar ? parseFloat(cs(searchBar).height) : 0;
        out.fieldRadius = radii(searchBar);

        const segs = [...document.querySelectorAll('#mode .seg')];
        out.segCount = segs.length;
        if (segs.length) {
          out.segFirst = radii(segs[0]);
          out.segLast = radii(segs[segs.length - 1]);
          out.segGap = segs.length > 1 ? box(segs[1]).left - box(segs[0]).right : 0;
        }

        const icons = [...document.querySelectorAll('svg.icon')];
        out.iconCount = icons.length;
        out.iconFill = icons.length ? cs(icons[0]).fill : '';
        out.iconStroke = icons.length ? cs(icons[0]).stroke : '';
        // Icons inside closed overlays (.fs-dialog, .sheet, .dialog-wrap, #layer) have no
        // box at all or are scaled away — only judge the ones that are actually on screen.
        out.zeroSizedIcons = icons
          .filter(i => i.getClientRects().length > 0)
          .filter(i => !i.closest('.sheet, .dialog-wrap, .fs-dialog, #layer, .segmented .seg:not(.on)'))
          .filter(i => { const b = box(i); return b.width < 8 || b.height < 8; }).length;
        out.visibleIcons = icons.filter(i => i.getClientRects().length > 0).length;

        // The palette must not be inline: an inline role cannot be overridden
        // from CSS, which is how the CSS palette silently became dead code.
        out.inlineRoleVars = (document.documentElement.getAttribute('style') || '').includes('--md-sys-color-');
        const tvEl = document.getElementById('theme-vars');
        out.themeVarsRule = (tvEl && tvEl.textContent ? tvEl.textContent : '').trim().slice(0, 6);

        // Generic overflow check on the containers that must never scroll sideways.
        out.overflow = ['.content', '.hero', '.group'].map(sel => {
          const el = q(sel);
          return el ? el.scrollWidth - el.clientWidth : 0;
        });
        out.docOverflow = document.documentElement.scrollWidth - document.documentElement.clientWidth;

        // Every tappable thing should be at least 40px in one dimension.
        out.tinyTargets = [...document.querySelectorAll('.btn, .icon-btn, .seg, .switch, .checkbox')]
          .filter(el => { const b = box(el); return b.height > 0 && b.height < 32; }).length;

        return out;
      });

      // ── hero ──
      eq('Работает', geo.statusText, 'the service state is rendered from json-status');
      eq(0, geo.heroCounters, 'the hero carries no counters');
      eq('nfqws2-android-ext', geo.titleText, 'top level: the module name instead of the section title');
      truthy(geo.titleLeftOff <= 24, 'the name sits in the left corner: ' + geo.titleLeftOff + ' px from the edge');
      truthy(geo.logoVisible && geo.logoNextToTitle, 'the 28px logo right after the name');
      truthy(geo.logsAtRight, 'logs in the top right corner');
      truthy(geo.settingsTab, 'settings is a bottom navigation tab');

      // ── shapes ──
      // Cards are .group on --shape-large (16dp) and the hero is on
      // --shape-extra-large (28dp). Both are M3 Expressive steps, which is what the
      // project targets; the old 12dp was the baseline card corner.
      eq(16, geo.cardRadius, 'cards use the 16dp corner (--shape-large)');
      eq(28, geo.heroRadius, 'the hero follows the extra-large corner (28dp)');
      eq(28, geo.strategyRowRadius, 'the mode card follows the hero corner (28dp)');
      eq('16,16,4,4', geo.swsFirstRadius.join(','), 'the first list row has 16dp outer corners');
      eq('4,4,16,16', geo.swsLastRadius.join(','), 'the last list row has 16dp outer corners');
      eq('4,4,4,4', geo.swsMiddleRadius.join(','), 'the middle list rows use 4dp inner corners');
      // #work-sws holds the four switches (calls bypass moved to developer settings). The conventions are about the switches.
      eq(4, geo.swsRows, 'the list holds the four switches');
      eq(4, geo.swsSwitchRows, 'all four of those rows are switches');
      eq(false, geo.swsHasIcons, 'switch rows carry no leading icons');
      eq(0, geo.swsSwitchWithSecondary, 'switch rows carry no descriptions');
      const swsHeight = await page.evaluate(async () => {
        navigate('work'); await new Promise(r => setTimeout(r, 400));
        const row = document.querySelector('#work-sws .list-item');
        const h = row ? Math.round(row.getBoundingClientRect().height) : 0;
        navigate('control'); await new Promise(r => setTimeout(r, 400));
        return h;
      });
      eq(56, swsHeight, 'switch rows are single-line (56dp)');

      // ── fields, segmented ──
      // The only text field on this screen is the search bar: 56dp tall and a pill,
      // which is the M3 search-bar spec rather than the filled-field one.
      eq(56, geo.fieldHeight, 'the search bar is 56dp tall');
      eq('9999,9999,9999,9999', geo.fieldRadius.join(','), 'the search bar is a pill (M3 search bar)');
      truthy(geo.segCount === 3, 'the mode control renders three segments');
      eq('9999,0,0,9999', geo.segFirst.join(','), 'the first segment is pill-shaped on the outside');
      eq('0,9999,9999,0', geo.segLast.join(','), 'the last segment is pill-shaped on the outside');
      truthy(Math.abs(geo.segGap) <= 1, 'segments are joined, not separated by a gap');

      // ── icons ──
      truthy(geo.iconCount > 10, `${geo.iconCount} icons are rendered`);
      truthy(/rgb/.test(geo.iconFill) && geo.iconFill !== 'none', 'icons paint with currentColor (Material Symbols)');
      truthy(geo.visibleIcons > 10, `${geo.visibleIcons} icons are visible`);
      if (geo.zeroSizedIcons > 0) process.stdout.write('   DEBUG zero sized: ' + JSON.stringify(geo.zeroSizedIconsList) + '\n');
      eq(0, geo.zeroSizedIcons, 'no visible icon collapsed to zero size');

      // ── colour roles stay themable from CSS ──
      truthy(!geo.inlineRoleVars, 'no colour role is applied as an inline style');
      eq(':root{', geo.themeVarsRule, 'the generated palette lives in its own <style>');
      await page.addStyleTag({ content: ':root{--md-sys-color-primary:rgb(1, 2, 3);}' });
      const overridden = await page.evaluate(() =>
        getComputedStyle(document.documentElement).getPropertyValue('--md-sys-color-primary').trim());
      eq('rgb(1, 2, 3)', overridden, 'a plain CSS rule can override a colour role');

      // ── overflow ──
      eq('0,0,0', geo.overflow.join(','), 'no container overflows horizontally');
      eq(0, geo.docOverflow, 'the document does not scroll sideways');
      eq(0, geo.tinyTargets, 'no tappable control is below 32dp tall');

      await ctx.close();
    }
  }

  // Behaviour does not depend on the viewport or the theme, so it runs once
  // instead of inside the loop above. That loop exists to measure geometry, and
  // repeating these checks in all six of its passes only made the suite slower.
  {
    const ctx = await browser.newContext({
      viewport: { width: 467, height: 900 }, deviceScaleFactor: 2.31,
      isMobile: true, hasTouch: true,
    });
    await ctx.addInitScript(STUB);
    const page = await ctx.newPage();
    await page.goto(INDEX, { waitUntil: 'load' });
    await page.waitForTimeout(700);

    // ── the package search must not shell out per keystroke ──
    // Every ctl call is a process on the device, and drawPk() used to re-read
    // apps.list on each one. ctl() quotes every argument, so match on the
    // pieces rather than on 'get-list apps'.
    const listReads = () => page.evaluate(() =>
      window.__calls.filter(c => c.indexOf('get-list') >= 0 && c.indexOf('apps') >= 0).length);

    // The apps page has to be on screen: a hidden input cannot be typed into.
    await page.evaluate(() => {
      document.querySelectorAll('.page').forEach(s => s.classList.toggle('active', s.dataset.page === 'apps'));
    });
    await page.waitForTimeout(150);

    await page.evaluate(() => { window.__calls = []; });
    await page.evaluate(() => loadPk());
    await page.waitForTimeout(400);
    eq(1, await listReads(), 'opening the package list reads apps.list exactly once');
    const listed = await page.evaluate(() => document.querySelectorAll('#pk input[data-pkg]').length);
    eq(4, listed, 'the package list is rendered');

    const selRadii = await page.evaluate(() => {
      const getRadii = el => {
        const parts = getComputedStyle(el).borderRadius.split(/\s+/).map(v => parseFloat(v));
        if (parts.length === 1) return [parts[0], parts[0], parts[0], parts[0]];
        if (parts.length === 2) return [parts[0], parts[1], parts[0], parts[1]];
        if (parts.length === 3) return [parts[0], parts[1], parts[2], parts[1]];
        return parts;
      };
      return [...document.querySelectorAll('#pk .list-item.selected')].map(getRadii);
    });
    eq('16,16,0,0', selRadii[0].join(','), 'first selected app has rounded top corners and flat bottom');
    eq('0,0,16,16', selRadii[1].join(','), 'last selected app has flat top and rounded bottom corners');

    await page.evaluate(() => { window.__calls = []; });
    await page.evaluate(() => { document.getElementById('pf').value = ''; });
    await page.evaluate(() => {
      window.__renders = 0;
      new MutationObserver(() => { window.__renders++; })
        .observe(document.getElementById('pk'), { childList: true });
    });
    await page.type('#pf', 'com.example', { delay: 20 });
    await page.waitForTimeout(400);
    eq(0, await listReads(), 'typing in the search does not re-read apps.list');
    const renders = await page.evaluate(() => window.__renders);
    truthy(renders === 1, `eleven keystrokes caused ${renders} re-render(s), not eleven`);
    const filtered = await page.evaluate(() => document.querySelectorAll('#pk input[data-pkg]').length);
    eq(2, filtered, 'the filter still narrows the list to the final query');

    // ── an import name cannot escape its onclick handler ──
    // Escaping for HTML alone is not enough: the attribute decoder turns
    // &#39; back into a quote before the JS parser sees the string, so the
    // value has to be quoted for JS first (see jsArg in index.html).
    await page.evaluate(() => {
      window.__pwned = undefined;
      document.querySelectorAll('.page').forEach(s => s.classList.toggle('active', s.dataset.page === 'config'));
    });
    await page.waitForTimeout(150);
    // импорты — в листе стратегий, группа «Пользовательские»
    await page.evaluate(() => openStrategySheet());
    await page.waitForTimeout(700);
    await page.evaluate(n => { strategies.push({name: 'imp:' + n, kind: 'import', mod: false}); renderStrategyList(false); }, HOSTILE_IMPORT);
    await page.waitForTimeout(200);
    eq(1, await page.evaluate(n => [...document.querySelectorAll('#strategy-list .li-primary')].filter(e => e.textContent === n).length, HOSTILE_IMPORT),
      'the hostile import name is rendered as a row');
    await page.evaluate(() => {
      const r = [...document.querySelectorAll('#strategy-list .list-item')].pop();
      if (r) r.click();
    });
    await page.waitForTimeout(300);
    await page.evaluate(() => closeSheet());
    eq(undefined, await page.evaluate(() => window.__pwned),
      'choosing it does not run the name as code');

    // ── a superseded dialog resolves instead of hanging ──
    // One dialog is on screen at a time but each call has its own promise, so
    // opening a second one used to overwrite dialogCb and leave the first
    // waiting forever — a fast double tap was enough.
    const dialogs = await page.evaluate(async () => {
      const race = p => Promise.race([p, new Promise(r => setTimeout(() => r('TIMEOUT'), 400))]);
      const first = mdDialog({ title: 'first', text: 'a' });
      const second = mdDialog({ title: 'second', text: 'b' });
      const firstResult = await race(first);
      const onScreen = document.getElementById('d-title').textContent;
      dialogResolve(false);
      const secondResult = await race(second);
      return { firstResult, secondResult, onScreen };
    });
    eq(false, dialogs.firstResult, 'the superseded dialog resolves as cancelled, not never');
    eq('second', dialogs.onScreen, 'the newer dialog is the one on screen');
    eq(false, dialogs.secondResult, 'and it resolves when dismissed');

    // ── reopening the theme sheet re-syncs it with the current state ──
    // The drawThemeUI() in openMonetModal() looks like a duplicate of the one
    // in applyTheme(), and it is not: applyTheme() redraws on change, this one
    // re-syncs on open. The difference shows on the hex field, which can hold
    // a half-typed value that was never applied — currentSeed only changes on
    // six characters. This check exists to stop the call being "cleaned up".
    const sheet = await page.evaluate(async () => {
      const wait = () => new Promise(r => setTimeout(r, 80));
      openMonetModal(); await wait();
      const field = document.getElementById('custom-hex-input');
      field.value = 'abc';
      field.dispatchEvent(new Event('input', { bubbles: true }));
      const typed = field.value;
      closeSheet(); await wait();
      openMonetModal(); await wait();
      const reopened = field.value;
      closeSheet(); await wait();
      return { typed, reopened };
    });
    eq('abc', sheet.typed, 'a half-typed hex value stays in the field while the sheet is open');
    truthy(sheet.reopened !== sheet.typed, 'reopening the sheet discards the half-typed value');
    truthy(/^[0-9A-F]{6}$/.test(sheet.reopened), 'the field shows the current seed again');

    // ── the handlers that quote their arguments still pass them through ──
    // setMode, setThemeMode, applyMonet and setp now take their value through
    // jsArg(), so the argument reaches them as a JS string literal rather than a
    // bare word. These three clicks check that the value survives the trip.
    const handlers = await page.evaluate(async () => {
      const wait = () => new Promise(r => setTimeout(r, 150));
      // #mode is filled by renderMode(), which runs when the lists page is shown.
      document.querySelectorAll('.page').forEach(s => s.classList.toggle('active', s.dataset.page === 'lists'));
      await wait();
      if (typeof listsInit === 'function') await listsInit();
      else if (typeof renderMode === 'function') { renderMode(); if (typeof renderListFiles === 'function') renderListFiles(); }
      await wait();
      window.__calls = [];
      const seg = document.querySelector('#mode button.seg');
      if (seg) seg.click();
      await wait();
      const modeCall = window.__calls.find(c => c.indexOf('set-mode') >= 0) || '';
      window.__calls = [];
      if (typeof renderWork === 'function') renderWork();
      const sw = document.querySelector('#work-sws input.switch');
      if (sw) sw.click();
      await wait();
      const swCall = window.__calls.filter(c => c.indexOf("'set'") >= 0)[0] || '';
      return { modeCall, swCall };
    });
    // ctl() quotes every argument, so the recorded command reads
    // `sh '…/nfqws2-ctl' 'set-mode' 'auto'` — match on the quoted pieces.
    truthy(handlers.modeCall.indexOf("'set-mode'") >= 0 && handlers.modeCall.indexOf("'auto'") >= 0,
      `a mode segment reaches setMode() with its value intact (saw: ${handlers.modeCall || 'no call'})`);
    truthy(handlers.swCall.indexOf("'set'") >= 0 && handlers.swCall.indexOf('AUTOSTART') >= 0,
      `a switch row reaches setp() with its key intact (saw: ${handlers.swCall || 'no call'})`);

    const swatch = await page.evaluate(async () => {
      const wait = () => new Promise(r => setTimeout(r, 120));
      const before = currentSeed;
      openMonetModal(); await wait();
      const b = document.querySelector('#palette-grid button:not(.on)') || document.querySelector('#palette-grid button');
      if (!b) return { clicked: false };
      b.click(); await wait();
      closeSheet();
      return { clicked: true, before, after: currentSeed };
    });
    truthy(swatch.clicked && /^#[0-9a-f]{6}$/.test(swatch.after) && swatch.after !== swatch.before,
      'a palette swatch reaches applyMonet() and changes the seed');

    const containerToggle = await page.evaluate(async () => {
      const wait = () => new Promise(r => setTimeout(r, 60));
      const getRadii = el => {
        const parts = getComputedStyle(el).borderRadius.split(/\s+/).map(v => parseFloat(v));
        if (parts.length === 1) return [parts[0], parts[0], parts[0], parts[0]];
        if (parts.length === 2) return [parts[0], parts[1], parts[0], parts[1]];
        if (parts.length === 3) return [parts[0], parts[1], parts[2], parts[1]];
        return parts;
      };
      openMonetModal(); await wait();
      const toggle = document.querySelector('#containers-toggle');
      if (!toggle) return { found: false };
      if (typeof renderWork === 'function') renderWork();
      toggle.click(); await wait();
      const row = document.querySelector('#work-sws .list-item');
      const offRadius = getRadii(row);
      toggle.click(); await wait();
      const onRadius = getRadii(row);
      closeSheet();
      return { found: true, offRadius, onRadius };
    });
    truthy(containerToggle.found, 'containers toggle is present in theme sheet');
    eq('8,8,8,8', containerToggle.offRadius.join(','), 'disabling containers flattens list items to 8dp');
    eq('16,16,4,4', containerToggle.onRadius.join(','), 're-enabling containers restores stacked corners');

    await ctx.close();
  }

  // ── strategy sheet: blurred background, swipe down from the list ────────
  {
    sect('strategy sheet swipe');
    const ctx = await browser.newContext({ viewport: { width: 400, height: 700 }, isMobile: true, hasTouch: true });
    await ctx.addInitScript(STUB);
    const page = await ctx.newPage();
    const pageErrors = [];
    page.on('pageerror', e => pageErrors.push(e.message));
    await page.goto(INDEX, { waitUntil: 'load' });
    await page.waitForTimeout(600);
    // Палец по списку: синтетические TouchEvent, как их шлёт WebView
    const swipe = (from, to, opts = {}) => page.evaluate(async ([from, to, opts]) => {
      const list = document.querySelector('#strategy-list');
      if (opts.scroll != null) list.scrollTop = opts.scroll;
      const el = opts.at ? document.querySelector(opts.at) : (list.querySelector('.list-item') || list), r = el.getBoundingClientRect(), x = r.left + 20;
      const touch = y => new Touch({ identifier: 1, target: el, clientX: x, clientY: y });
      const fire = (type, y) => {
        const t = touch(y);
        const ev = new TouchEvent(type, { bubbles: true, cancelable: true, touches: type === 'touchend' ? [] : [t], changedTouches: [t] });
        el.dispatchEvent(ev);
        return ev.defaultPrevented;
      };
      const y0 = r.top + 10;
      fire('touchstart', y0);
      let prevented = false;
      const steps = 8;
      for (let i = 1; i <= steps; i++) {
        prevented = fire('touchmove', y0 + (to - from) * i / steps) || prevented;
        await new Promise(r => setTimeout(r, opts.slow ? 40 : 8));
      }
      const mid = document.querySelector('#strategy-sheet').style.transform;
      const sc = getComputedStyle(document.querySelector('#sheet-scrim'));
      const midScrim = { opacity: +sc.opacity, blur: parseFloat((sc.backdropFilter.match(/blur\(([\d.]+)px\)/) || [0, 6])[1]) };
      fire('touchend', y0 + (to - from));
      await new Promise(r => setTimeout(r, 120));
      return { prevented, mid, midScrim, open: document.querySelector('#strategy-sheet').classList.contains('open') };
    }, [from, to, opts]);

    await page.evaluate(() => openStrategySheet()); await page.waitForTimeout(500);
    const blur = await page.evaluate(() => getComputedStyle(document.querySelector('#sheet-scrim')).backdropFilter);
    truthy(/blur\(\d/.test(blur) && blur !== 'blur(0px)', 'the background under the sheet is blurred: ' + blur);
    const canScroll = await page.evaluate(() => { const l = document.querySelector('#strategy-list'); return l.scrollHeight > l.clientHeight + 40; });
    truthy(canScroll, 'the strategy list is long enough to scroll');
    let r = await swipe(0, 300, { scroll: 40 });
    truthy(r.open && !r.prevented && !r.mid, 'with the list scrolled, a swipe down scrolls the list and leaves the sheet');
    r = await swipe(0, -200, { scroll: 0 });
    truthy(r.open && !r.prevented, 'a swipe up from the top scrolls the list');
    r = await swipe(0, 40, { scroll: 0, slow: true });
    truthy(r.open && r.prevented && /translateY\(\d/.test(r.mid), 'a short slow pull from the top moves the sheet and lets it spring back');
    truthy(r.midScrim.opacity < 1 && r.midScrim.opacity > 0.5 && r.midScrim.blur < 6 && r.midScrim.blur > 3,
      'the dim and blur follow the finger: ' + JSON.stringify(r.midScrim));
    truthy(await page.evaluate(() => !document.querySelector('#strategy-sheet').style.transform), 'the sheet returns to place');
    await page.waitForTimeout(500);
    const back = await page.evaluate(() => getComputedStyle(document.querySelector('#sheet-scrim')).backdropFilter);
    eq('blur(6px)', back, 'released, the blur grows back');
    r = await swipe(0, 300, { scroll: 200, at: '#strategy-sheet .sheet-desc' });
    truthy(!r.open && r.prevented, 'a swipe down on the description closes the sheet even with the list scrolled');
    await page.waitForTimeout(500);
    await page.evaluate(() => openStrategySheet()); await page.waitForTimeout(500);
    r = await swipe(0, 300, { scroll: 0 });
    truthy(!r.open, 'a swipe down from the top of the list closes the sheet');
    await page.waitForTimeout(500);
    const blurOff = await page.evaluate(() => getComputedStyle(document.querySelector('#sheet-scrim')).backdropFilter);
    truthy(blurOff === 'none' || blurOff === 'blur(0px)', 'and the blur goes away with it: ' + blurOff);
    // Большой аргумент (архив для восстановления) уходит частями через upload
    const up = await page.evaluate(async () => {
      window.__calls = [];
      await ctlx(['backup-restore-b64', 'QUJD'.repeat(30000)]);
      return window.__calls.map(c => { const m = c.match(/nfqws2-ctl' '([a-z0-9-]+)' '([^']*)'/); return m ? [m[1], m[2].slice(0, 4), c.length] : ['?', '', c.length]; });
    });
    eq('upload,upload,upload,backup-restore-b64', up.map(c => c[0]).join(','), 'a 120 KB argument is sent in pieces, then by reference');
    truthy(up.every(c => c[2] < 60000), 'every command stays far below the kernel limit');
    eq('@up:', up[3][1], 'the command gets @up:<tag> instead of the data');
    // Выделение текста: только поля ввода и журналы
    const sel = await page.evaluate(() => {
      const us = el => el ? getComputedStyle(el).userSelect || getComputedStyle(el).webkitUserSelect : 'missing';
      return { title: us(document.querySelector('#app-title')), row: us(document.querySelector('.list-item .li-primary')),
               log: us(document.querySelector('#lg')), args: us(document.querySelector('#args')), ta: us(document.querySelector('textarea')) };
    });
    eq(JSON.stringify({ title: 'none', row: 'none', log: 'text', args: 'text', ta: 'text' }), JSON.stringify(sel), 'only inputs and logs can be selected');
    // Волна на чипе не выходит за чип
    await page.evaluate(() => navigate('logs')); await page.waitForTimeout(900);
    const rip = await page.evaluate(() => {
      const chip = document.querySelector('#log-chips .chip'), r = chip.getBoundingClientRect();
      chip.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true, clientX: r.left + 10, clientY: r.top + 10 }));
      const s = chip.querySelector('.ripple');
      return s ? s.style.clipPath : 'none';
    });
    truthy(/^inset\(/.test(rip), 'a chip ripple is clipped to the chip: ' + rip);
    eq('', pageErrors.join(' | '), 'no script errors');
    await ctx.close();
  }

  // ── status card: quick refresh on pause/resume, steady size ────────────
  {
    sect('status card refresh');
    const ctx = await browser.newContext({ viewport: { width: 360, height: 800 }, isMobile: true, hasTouch: true });
    await ctx.addInitScript(STUB);
    const page = await ctx.newPage();
    const pageErrors = [];
    page.on('pageerror', e => pageErrors.push(e.message));
    await page.goto(INDEX, { waitUntil: 'load' });
    await page.waitForTimeout(2000);
    const running = await page.evaluate(() => ({ h: document.querySelector('#hero-status').offsetHeight, st: $('st').textContent }));
    eq('Работает', running.st, 'starts as running');
    const base = Object.assign({}, await page.evaluate(() => S), { dns_available: 1, dns_enabled: 1 });
    const t0 = Date.now();
    await page.evaluate(st => {
      window.__st = Object.assign({}, st, { running: false, pid: '', uptime: 0,
        paused: 'Очень длинное имя домашней сети, которое не помещается в одну строку', home_override: '' });
      window.__sig = 'p:home';
    }, base);
    await page.waitForFunction(() => $('st').textContent === 'Пауза', null, { timeout: 4000 }).catch(() => {});
    const dt = Date.now() - t0;
    const paused = await page.evaluate(() => {
      const sub = $('sub');
      return { st: $('st').textContent, h: document.querySelector('#hero-status').offsetHeight, sub: sub.textContent,
        oneLine: sub.offsetHeight <= parseFloat(getComputedStyle(sub).lineHeight) + 1, title: sub.title };
    });
    eq('Пауза', paused.st, 'the pause shows up');
    truthy(dt < 2500, 'within about a second and a half, not on the 5 s poll: ' + dt + ' ms');
    truthy(!paused.sub.includes('DNS'), 'DNS has its own tile, not a part of the subtitle: ' + paused.sub);
    truthy(paused.oneLine, 'the subtitle stays on one line');
    truthy(await page.evaluate(() => $('hero-stats').hidden), 'no uptime row while paused');
    eq('#i-pause', await page.evaluate(() => $('hero-ic').getAttribute('href')), 'the pause icon in the card');
    truthy(!paused.sub.includes('Очень длинное'), 'the network name is not in the subtitle');
    truthy(paused.title.includes('возобновится'), 'the full explanation is in the title');
    await page.evaluate(st => { window.__st = Object.assign({}, st, { paused: '@vpn', running: false }); window.__sig = 'p:@vpn'; }, base);
    await page.waitForFunction(() => $('sub').textContent.startsWith('Включён VPN'), null, { timeout: 4000 }).catch(() => {});
    eq('Включён VPN', await page.evaluate(() => $('sub').textContent), 'a VPN pause reads short too');
    const t1 = Date.now();
    await page.evaluate(st => { window.__st = st; window.__sig = 'run 4711'; }, base);
    await page.waitForFunction(() => $('st').textContent === 'Работает', null, { timeout: 4000 }).catch(() => {});
    truthy(Date.now() - t1 < 2500, 'resuming shows up as fast: ' + (Date.now() - t1) + ' ms');
    eq('#i-shield', await page.evaluate(() => $('hero-ic').getAttribute('href')), 'running: the shield icon');
    truthy(await page.evaluate(() => !$('hero-stats').hidden), 'the uptime row is back');
    const n = await page.evaluate(() => window.__calls.filter(c => c.indexOf('json-status') >= 0).length);
    await page.waitForTimeout(3200);
    const n2 = await page.evaluate(() => window.__calls.filter(c => c.indexOf('json-status') >= 0).length);
    truthy(n2 - n <= 1, 'with nothing changing the full status is not re-read every tick: ' + (n2 - n));
    eq('', pageErrors.join(' | '), 'no script errors');
    await ctx.close();
  }

  // ── theme sheet: scrolls like the others, the colour wheel picks ────────
  {
    sect('theme sheet swipe');
    const ctx = await browser.newContext({ viewport: { width: 360, height: 640 }, isMobile: true, hasTouch: true });
    await ctx.addInitScript(STUB);
    const page = await ctx.newPage();
    const pageErrors = [];
    page.on('pageerror', e => pageErrors.push(e.message));
    await page.goto(INDEX, { waitUntil: 'load' });
    await page.waitForTimeout(600);
    const swipe = (at, dy, scroll) => page.evaluate(async ([at, dy, scroll]) => {
      const list = document.querySelector('#monet-modal .sheet-scroll');
      list.scrollTop = scroll;
      const el = document.querySelector(at), r = el.getBoundingClientRect(), x = r.left + r.width / 2, y0 = r.top + r.height / 2;
      const fire = (type, y) => {
        const t = new Touch({ identifier: 1, target: el, clientX: x, clientY: y });
        const ev = new TouchEvent(type, { bubbles: true, cancelable: true, touches: type === 'touchend' ? [] : [t], changedTouches: [t] });
        el.dispatchEvent(ev);
        return ev.defaultPrevented;
      };
      fire('touchstart', y0);
      let prevented = false;
      for (let i = 1; i <= 8; i++) { prevented = fire('touchmove', y0 + dy * i / 8) || prevented; await new Promise(r => setTimeout(r, 8)); }
      const mid = document.querySelector('#monet-modal').style.transform;
      fire('touchend', y0 + dy);
      await new Promise(r => setTimeout(r, 120));
      return { prevented, mid, open: document.querySelector('#monet-modal').classList.contains('open') };
    }, [at, dy, scroll]);

    await page.evaluate(() => openMonetModal()); await page.waitForTimeout(500);
    eq(null, await page.$('#monochrome-toggle'), 'there is no separate monochrome switch');
    truthy(await page.evaluate(() => { const l = document.querySelector('#monet-modal .sheet-scroll'); return l && l.scrollHeight > l.clientHeight + 40; }),
      'the theme sheet content scrolls on a small screen');
    let r = await swipe('#wheel', 200, 0);
    truthy(r.open && !r.prevented && !r.mid, 'dragging on the colour wheel does not move the sheet');
    r = await swipe('#monet-modal .theme-preview', 300, 40);
    truthy(r.open && !r.mid, 'with the content scrolled, a swipe down scrolls it');
    r = await swipe('#monet-modal .theme-preview', 300, 0);
    truthy(!r.open && r.prevented, 'at the top, a swipe down closes the sheet');
    eq('', pageErrors.join(' | '), 'no script errors');
    await ctx.close();
  }

  // ── list editor: find and remove duplicates ─────────────────────────────
  {
    sect('list editor: find and duplicates');
    const ctx = await browser.newContext({ viewport: { width: 400, height: 800 }, isMobile: true, hasTouch: true });
    await ctx.addInitScript(STUB);
    const page = await ctx.newPage();
    const pageErrors = [];
    page.on('pageerror', e => pageErrors.push(e.message));
    await page.goto(INDEX, { waitUntil: 'load' });
    await page.waitForTimeout(600);
    await page.evaluate(() => openSlideEditor('list', 'user'));
    await page.waitForTimeout(700);
    const text = ['# мои домены', 'youtube.com', 'example.com', 'googlevideo.com', 'Example.com', 'ytimg.com',
      '', 'youtube.com # дубль', 'example.com.', 'other.org'].concat(Array.from({ length: 200 }, (_, i) => 'host' + i + '.net'), ['last-youtube.com']).join('\n');
    await page.evaluate(t => { const ta = document.querySelector('#panel-editor-text'); ta.value = t; ta.dispatchEvent(new Event('input')); }, text);
    eq(false, await page.isHidden('#panel-dedupe-btn'), 'a list editor offers duplicate removal');
    await page.click('#panel-find-btn');
    eq(true, await page.isVisible('#find-bar'), 'the search button opens the find bar');
    await page.fill('#find-q', 'youtube');
    await page.waitForTimeout(200);
    eq('', await page.textContent('#find-count'), 'typing alone does not search');
    await page.click('#find-go');
    eq('1 / 3', await page.textContent('#find-count'), 'Find counts the matches, case-insensitively');
    const mark1 = await page.evaluate(() => ({ hidden: document.querySelector('#find-mark').hidden, sel: (t => t.value.slice(t.selectionStart, t.selectionEnd))(document.querySelector('#panel-editor-text')) }));
    eq(JSON.stringify({ hidden: false, sel: 'youtube' }), JSON.stringify(mark1), 'the first match is selected and marked');
    await page.click('#find-next'); await page.click('#find-next');
    eq('3 / 3', await page.textContent('#find-count'), 'the down arrow goes to the next match');
    const far = await page.evaluate(() => {
      const ta = document.querySelector('#panel-editor-text'), mk = document.querySelector('#find-mark').getBoundingClientRect(), box = ta.getBoundingClientRect();
      return { scrolled: ta.scrollTop > 0, inView: mk.top >= box.top && mk.bottom <= box.bottom };
    });
    eq(JSON.stringify({ scrolled: true, inView: true }), JSON.stringify(far), 'a match far down is scrolled into view');
    await page.click('#find-next');
    eq('1 / 3', await page.textContent('#find-count'), 'and wraps around');
    await page.click('#find-prev');
    eq('3 / 3', await page.textContent('#find-count'), 'the up arrow goes back');
    await page.fill('#find-q', 'nothing-here');
    await page.press('#find-q', 'Enter');
    eq('0', await page.textContent('#find-count'), 'Enter searches too; no match is shown as 0');
    await page.fill('#find-q', '"youtube.com"');
    await page.press('#find-q', 'Enter');
    eq('1 / 2', await page.textContent('#find-count'), 'in quotes only whole entries match (not last-youtube.com)');
    await page.fill('#find-q', '"youtube"');
    await page.press('#find-q', 'Enter');
    eq('0', await page.textContent('#find-count'), 'and a part of a domain in quotes finds nothing');
    await page.evaluate(() => handleBack(true));
    eq(true, await page.isHidden('#find-bar'), 'back closes the find bar first');
    eq(true, await page.evaluate(() => document.querySelector('#editor-panel').classList.contains('open')), 'and keeps the editor open');

    await page.click('#panel-dedupe-btn');
    const after = await page.evaluate(() => document.querySelector('#panel-editor-text').value.split('\n'));
    eq(JSON.stringify(['# мои домены', 'youtube.com', 'example.com', 'googlevideo.com', 'ytimg.com', '', 'other.org']), JSON.stringify(after.slice(0, 7)),
      'later duplicates are removed (case, trailing dot and comment ignored), the first one stays');
    eq(208, after.length, 'unique lines are kept');
    truthy((await page.textContent('#prompt-msg')).includes('3'), 'the snackbar says how many were removed');
    await page.click('#prompt-action');
    eq(text, await page.evaluate(() => document.querySelector('#panel-editor-text').value), 'undo brings the text back');
    await page.evaluate(() => closeSlideEditor(true));
    await page.waitForTimeout(500);

    // Жест системы: касание у нижнего края не начинает долгое нажатие
    eq(true, await page.evaluate(() => inGestureZone(200, innerHeight - 5) && inGestureZone(5, 300) && !inGestureZone(200, 300)),
      'touches at the bottom bar and the side edges are system gestures');
    eq('', pageErrors.join(' | '), 'no script errors');
    await ctx.close();
  }

  // ── what's new after an update ──────────────────────────────────────────
  {
    sect("what's new after an update");
    const CL = '### Изменения в v1.3.6:\n\n- **Поиск** в списках\n- Файл `user.list`\n\n### Изменения в v1.3.5:\n\n- старое\n';
    const run = async seen => {
      const ctx = await browser.newContext({ viewport: { width: 400, height: 800 } });
      if (seen != null) await ctx.addInitScript(`try{localStorage.setItem('nfq_seen_ver', ${JSON.stringify(seen)})}catch(e){}`);
      await ctx.addInitScript(STUB);
      await ctx.addInitScript(`(function(){ var base = window.ksu.exec; window.ksu.exec = function(cmd, o, cb){
        if (cmd.indexOf("'changelog'") < 0) return base.apply(this, arguments);
        var id = typeof cb === 'string' ? cb : o; setTimeout(function(){ window[id](0, ${JSON.stringify(CL)}, ''); }, 0); return 'j'; }; })();`);
      const page = await ctx.newPage();
      await page.goto(INDEX, { waitUntil: 'load' });
      await page.waitForTimeout(900);
      const r = await page.evaluate(() => ({ open: document.querySelector('#whatsnew-sheet').classList.contains('open'),
        title: document.querySelector('#whatsnew-title').textContent, body: document.querySelector('#whatsnew-body').innerHTML,
        seen: localStorage.getItem('nfq_seen_ver') }));
      await ctx.close();
      return r;
    };
    let r = await run('v1.3.5');
    eq(true, r.open, 'after an update the sheet opens by itself');
    truthy(r.title.includes('v1.3.6') && r.body.includes('<b>Поиск</b>') && r.body.includes('<code>user.list</code>') && !r.body.includes('старое'),
      'with the changes of this version only, formatted');
    eq('v1.3.6', r.seen, 'and remembers the version');
    r = await run('v1.3.6');
    eq(false, r.open, 'the same version does not show it again');
    r = await run(null);
    eq(false, r.open, 'a fresh install does not show it');
  }

  // ── hosts editor ─────────────────────────────────────────────────────────
  {
    sect('hosts editor');
    const ctx = await browser.newContext({ viewport: { width: 360, height: 800 }, isMobile: true, hasTouch: true });
    await ctx.addInitScript(STUB);
    await ctx.addInitScript(`(function(){
      var base = window.ksu.exec;
      window.__h = { enabled: 0, adaway: 0, differs: 0, preset: '', calls: [] };
      function state(){ var h = window.__h; return ['#status', 'enabled=' + h.enabled, 'mounted=' + h.enabled, 'differs=' + h.differs, 'conflicts=',
        'bypass=3', 'bypass_preset=' + h.preset, 'blocked=1200', 'block_custom=2', 'imported=', 'dir=/data/adb/nfqws2/hosts',
        '#preset adaway', 'NAME=AdAway', 'DESC=Реклама', 'URL=https://adaway.org/hosts.txt', 'BLOCK=1', 'ENABLED=' + h.adaway, h.adaway ? 'COUNT=1200' : '',
        '#preset geohide', 'NAME=GeoHide', 'DESC=Доступ', 'URL=https://geohide.ru/eu/hosts', 'BYPASS=1', 'ENABLED=0',
        '#preset malw', 'NAME=dns.malw.link', 'DESC=Доступ', 'BLOCK_DESC=Реклама', 'URL=https://x/hosts', 'BYPASS=1', 'BLOCK=1', 'ENABLED=0',
        '#url', 'URL=https://example.org/my.txt'].join('\\n'); }
      window.ksu.exec = function(cmd, opts, cb){
        if (cmd.indexOf("'hosts-") < 0 && cmd.indexOf("'share'") < 0) return base.apply(this, arguments);
        var id = typeof cb === 'string' ? cb : opts, h = window.__h, out = 'OK';
        h.calls.push(cmd);
        if (cmd.indexOf("'hosts-state'") >= 0) out = state();
        else if (cmd.indexOf("'hosts-set-enabled' '1'") >= 0) h.enabled = 1;
        else if (cmd.indexOf("'hosts-set-enabled' '0'") >= 0) h.enabled = 0;
        else if (cmd.indexOf("'hosts-preset' 'adaway' '1'") >= 0) h.adaway = 1;
        else if (cmd.indexOf("'hosts-bypass-preset' 'geohide'") >= 0) h.preset = 'geohide';
        else if (cmd.indexOf("'hosts-sync' 'apply'") >= 0) h.differs = 0;
        else if (cmd.indexOf("'hosts-block-add'") >= 0) out = '2';
        else if (cmd.indexOf("'hosts-get' 'bypass'") >= 0) out = '1.2.3.4 a.example';
        else if (cmd.indexOf("'hosts-update'") >= 0) out = 'S\\tpreset:adaway\\tok 1200';
        setTimeout(function(){ if (window[id]) window[id](0, out, ''); }, 0);
        return 'job';
      };
    })();`);
    const page = await ctx.newPage();
    const pageErrors = [];
    page.on('pageerror', e => pageErrors.push(e.message));
    await page.goto(INDEX, { waitUntil: 'load' });
    await page.waitForTimeout(500);
    await page.evaluate(() => navigate('settings')); await page.waitForTimeout(700);
    truthy((await page.textContent('#settings-body')).includes('Редактор hosts'), 'settings list the hosts editor');
    await page.evaluate(() => navigate('hosts')); await page.waitForTimeout(900);
    eq(false, await page.isChecked('#hosts-toggle'), 'it starts off');
    const src = await page.textContent('#hosts-sources');
    truthy(src.includes('AdAway') && src.includes('dns.malw.link') && src.includes('example.org/my.txt'), 'block sources and own links are listed');
    truthy(!src.includes('GeoHide'), 'a bypass-only preset is not a block source');
    truthy(!/\d{4}\.\d\d\.\d\d/.test(await page.textContent('[data-page="hosts"]')), 'no build date is shown');
    await page.click('#hosts-main'); await page.waitForTimeout(500);
    eq(1, await page.evaluate(() => window.__h.enabled), 'the switch turns the own hosts on');
    truthy(/1\D?200/.test(await page.textContent('#hosts-block')), 'the block part shows its size');
    truthy((await page.textContent('#hosts-bypass')).includes('/data/adb/nfqws2/hosts/bypass.txt'), 'the bypass file path is shown');
    truthy((await page.textContent('#hosts-block')).includes('/data/adb/nfqws2/hosts/block.txt'), 'and the block file path');
    await page.click('#hosts-block .list-item:has-text("block.txt")'); await page.waitForTimeout(400);
    truthy(await page.evaluate(() => window.__h.calls.some(c => c.indexOf("'share' 'file' '/data/adb/nfqws2/hosts/block.txt'") >= 0)), 'block.txt is shared as a file');
    await page.click('#hosts-sources label:has-text("AdAway")'); await page.waitForTimeout(500);
    eq(1, await page.evaluate(() => window.__h.adaway), 'a block preset is switched on');
    await page.click('#hosts-bypass .list-item:has-text("Загрузить пресет")'); await page.waitForTimeout(400);
    await page.click('[role="menu"] [role="menuitem"]:has-text("GeoHide")'); await page.waitForTimeout(400);
    eq(true, await page.evaluate(() => $('dialog-wrap').classList.contains('open')), 'loading a bypass preset asks first');
    await page.click('#d-ok'); await page.waitForTimeout(500);
    eq('geohide', await page.evaluate(() => window.__h.preset), 'and loads it');
    truthy((await page.textContent('#hosts-bypass')).includes('GeoHide'), 'the bypass names the loaded preset');
    await page.click('#hosts-block .list-item:has-text("Добавить домены")'); await page.waitForTimeout(400);
    await page.fill('#d-input', 'a.ads.example, b.ads.example'); await page.click('#d-ok'); await page.waitForTimeout(500);
    truthy(await page.evaluate(() => window.__h.calls.some(c => c.indexOf("'hosts-block-add' 'a.ads.example, b.ads.example'") >= 0)), 'block domains are added from the dialog');
    await page.click('#hosts-bypass .list-item:has-text("Записи обхода")'); await page.waitForTimeout(700);
    eq('1.2.3.4 a.example', await page.inputValue('#panel-editor-text'), 'bypass entries open in the editor');
    await page.fill('#panel-editor-text', '1.2.3.4 a.example\n5.6.7.8 b.example');
    await page.click('#panel-save-btn'); await page.waitForTimeout(500);
    truthy(await page.evaluate(() => window.__h.calls.some(c => c.indexOf("'hosts-save-b64' 'bypass'") >= 0)), 'saving sends them to the module');
    eq(false, await page.evaluate(() => document.querySelector('#editor-panel').classList.contains('open')), 'and closes the editor');
    await page.evaluate(() => { window.__h.differs = 1; return hostsInit(); }); await page.waitForTimeout(400);
    truthy((await page.textContent('#hosts-warn')).includes('различаются'), 'edited part files are reported');
    await page.click('#hosts-warn button:has-text("Применить")'); await page.waitForTimeout(500);
    truthy(await page.evaluate(() => window.__h.calls.some(c => c.indexOf("'hosts-sync' 'apply'") >= 0)), 'and can be applied');
    eq('', (await page.textContent('#hosts-warn')).trim(), 'after which the notice is gone');
    await page.click('#hosts-update'); await page.waitForTimeout(500);
    truthy((await page.textContent('#prompt-msg')).includes('1 из 1'), 'updating sources reports how many worked');
    await page.evaluate(() => setLanguage('en')); await page.waitForTimeout(300);
    const en = await page.textContent('[data-page="hosts"]');
    const ru = (en.replace(/Реклама|Доступ|\/data\/adb\S*/g, '').match(/[А-Яа-яЁё]{4,}[^\n]{0,30}/g) || []);
    eq('', ru.join(' | '), 'the screen is translated');
    await page.evaluate(() => setLanguage('ru'));
    eq('', pageErrors.join(' | '), 'no script errors');
    await ctx.close();
  }

  // ── reachability: one domain ─────────────────────────────────────────────
  {
    sect('reachability: one domain');
    const ctx = await browser.newContext({ viewport: { width: 360, height: 800 }, isMobile: true, hasTouch: true });
    await ctx.addInitScript(STUB);
    await ctx.addInitScript(`(function(){
      var base = window.ksu.exec;
      window.__dc = 'MODE\\tlist\\nIP\\t1.2.3.4\\nR\\t1\\tfail tls_rst\\nR\\t2\\tfail tls_rst\\nR\\t3\\tfail drop\\ndone';
      window.ksu.exec = function(cmd, opts, cb){
        if (cmd.indexOf('domain-check') < 0) return base.apply(this, arguments);
        var id = typeof cb === 'string' ? cb : opts;
        setTimeout(function(){ if (window[id]) window[id](0, window.__dc, ''); }, 0);
        return 'job';
      };
    })();`);
    const page = await ctx.newPage();
    const pageErrors = [];
    page.on('pageerror', e => pageErrors.push(e.message));
    await page.goto(INDEX, { waitUntil: 'load' });
    await page.waitForTimeout(500);
    await page.evaluate(() => navigate('test')); await page.waitForTimeout(800);
    await page.click('#test-tabs .seg[data-tab="domain"]');
    eq(true, await page.isVisible('#test-sec-domain'), 'the Domain tab shows the domain form');
    eq(false, await page.isVisible('#tb'), 'and hides the batch run button');
    await page.fill('#dc-q', 'blocked.example');
    await page.click('#dc-go'); await page.waitForTimeout(400);
    let res = await page.textContent('#dc-res');
    truthy(res.includes('Не под обходом'), 'a domain outside the lists of a list-mode strategy is reported as not bypassed');
    truthy(res.includes('Ни в одном списке') && res.includes('1.2.3.4'), 'with the lists and the IP');
    truthy(res.includes('Не открылся') && res.includes('TLS RST'), 'and why it did not open');
    eq(true, await page.isVisible('#dc-res button:has-text("Добавить в user.list")'), 'it offers to add the domain to user.list');
    await page.evaluate(() => { window.__dc = 'MODE\tauto\nLIST\texclude.list\texclude\tblocked.example\nR\t1\tok 120\ndone'; });
    await page.click('#dc-go'); await page.waitForTimeout(400);
    res = await page.textContent('#dc-res');
    truthy(res.includes('В исключениях'), 'an excluded domain is reported as excluded');
    eq(true, await page.isVisible('#dc-res button:has-text("Открыть список")'), 'with a shortcut to the list it is in');
    // Несколько списков — выбор; редактор открывается сразу с точным поиском записи
    await page.evaluate(() => { window.__dc = 'MODE\tauto\nLIST\tuser.list\thost\tblocked.example\nLIST\trkn.list\tidle\tblocked.example\ndone'; });
    await page.click('#dc-go'); await page.waitForTimeout(400);
    await page.click('#dc-res button:has-text("Открыть список")'); await page.waitForTimeout(200);
    eq(2, await page.$$eval('.menu .mi', m => m.length), 'several lists are offered to choose from');
    await page.click('.menu .mi:has-text("user.list")'); await page.waitForTimeout(900);
    eq(true, await page.isVisible('#find-bar'), 'the list opens with the find bar');
    eq('"blocked.example"', await page.inputValue('#find-q'), 'searching for the exact entry');
    await page.evaluate(() => closeSlideEditor(true)); await page.waitForTimeout(500);
    await page.evaluate(() => openSlideEditor('list', 'exclude')); await page.waitForTimeout(700);
    eq(true, await page.isHidden('#find-bar'), 'another list opened later has no leftover search');
    await page.evaluate(() => closeSlideEditor(true)); await page.waitForTimeout(500);
    // «Вероятная причина»: попытки через обход, без него, скорость и DNS
    const dcRun = async out => { await page.evaluate(o => { window.__dc = o; }, out); await page.click('#dc-go'); await page.waitForTimeout(400); return page.textContent('#dc-res'); };
    res = await dcRun('MODE\tall\nIP\t1.2.3.4\nR\t1\tfail tls_rst\nR\t2\tfail tls_rst\nR\t3\tfail tls_rst\nN\tok 90\ndone');
    truthy(res.includes('Вероятная причина') && res.includes('Обход мешает'), 'fails through the bypass but opens without it: the bypass is to blame');
    res = await dcRun('MODE\tall\nR\t1\tfail drop\nR\t2\tfail drop\nR\t3\tfail drop\nN\tfail drop\ndone');
    truthy(res.includes('ни через обход, ни без него'), 'fails both ways: the variant does not get past the block, or the site is down');
    res = await dcRun('MODE\tall\nR\t1\tok 200\nR\t2\tok 210\nR\t3\tok 190\nK\tok\nN\tfail tls_rst\nS\t900000 4096\nD\tdefault\topportunistic\ndone');
    truthy(res.includes('очень медленно (4 КБ/с)'), 'opens but crawls: looks like throttling');
    truthy(res.includes('4 КБ/с — медленно'), 'with the measured speed');
    truthy(res.includes('«Частный DNS»') && res.includes('автоматически'), 'Private DNS on «automatic» is pointed out');
    truthy(res.includes('через DNS по умолчанию'), 'and the route of the module DNS is shown');
    res = await dcRun('MODE\tall\nR\t1\tok 200\nR\t2\tok 210\nR\t3\tok 190\nN\tok 80\nS\t2000 900000\nD\tgeo\toff\ndone');
    truthy(res.includes('не заблокирован'), 'opens both ways: not blocked at all');
    truthy(res.includes('слишком маленький для замера'), 'a tiny answer is not taken for a speed');
    truthy(!res.includes('«Частный DNS»'), 'Private DNS off: no warning');
    truthy(res.includes('с обходом геоблока'), 'a geo-blocked service goes to the bypass DNS');
    await page.click('#test-tabs .seg[data-tab="all"]');
    eq(true, await page.isVisible('#tb'), 'back on All the batch run button returns');
    eq(false, await page.isVisible('#test-sec-domain'), 'and the domain form hides');
    eq('', pageErrors.join(' | '), 'no script errors');
    await ctx.close();
  }

  // ── repeated reachability check ─────────────────────────────────────────
  // The second run must start from an empty screen: rows of the first run used
  // to stay, the new ones were appended below them with the same ids, and the
  // results landed in the old rows.
  {
    sect('reachability check run twice');
    const RUNS = [
      ['tool\tcurl', 'H\t0\ta.example', 'H\t1\tb.example', 'H\t2\tc.example',
       'R\t0\t1\tok 10', 'R\t1\t1\tfail drop', 'R\t2\t1\tok 30',
       'T16\t0\tHetzner\t1.1.1.1\t443\tclean\t20ms', 'T16\t1\tOVH\t2.2.2.2\t443\tdetected\t16KB',
       'DNS\t0\tGoogle\t8.8.8.8\tok\tok\tno\tOK', 'done'],
      ['tool\tcurl', 'H\t0\tz.example', 'H\t1\ty.example',
       'R\t1\t1\tok 5', 'R\t0\t1\tok 7',
       'T16\t0\tCloudflare\t3.3.3.3\t443\tclean\t9ms',
       'DNS\t0\tQuad9\t9.9.9.9\tfail\tnone\tno\tOK', 'DNS\t1\tYandex\t77.88.8.8\tok\tnone\tno\tOK', 'done'],
    ];
    const ctx = await browser.newContext({ viewport: { width: 400, height: 900 } });
    await ctx.addInitScript(STUB);
    await ctx.addInitScript(`(function(){
      var runs = ${JSON.stringify(RUNS)}, n = 0, base = window.ksu.exec;
      window.ksu.exec = function(cmd, opts, cb){
        var net = cmd.indexOf('net-info') >= 0;
        if (cmd.indexOf('probe-dpi') < 0 && !net) return base.apply(this, arguments);
        var id = typeof cb === 'string' ? cb : opts;
        var out = net ? 'NET\\t5.18.158.84\\tRU\\tZ-Telecom\\tAS41733\\twlan0\\t192.168.1.1\\t8.8.8.8\\trunning\\talt13'
                      : runs[Math.min(n++, runs.length - 1)].join('\\n');
        setTimeout(function(){ if (window[id]) window[id](0, out, ''); }, 0);
        return 'job';
      };
    })();`);
    const page = await ctx.newPage();
    const pageErrors = [];
    page.on('pageerror', e => pageErrors.push(e.message));
    await page.goto(INDEX, { waitUntil: 'load' });
    await page.waitForTimeout(500);
    const snap = () => page.evaluate(() => {
      const rows = sel => [...document.querySelectorAll(sel + ' > .list-item')].map(r => r.querySelector('.li-primary').textContent.trim());
      return {
        web: rows('#tr'), tcp: rows('#test-tcp16-list'), dns: rows('#test-dns-list'),
        rec: document.querySelector('#test-recommendation')?.hidden ? '' : document.querySelector('#test-recommendation .badge')?.textContent.trim(),
        webTrail: [...document.querySelectorAll('#tr .li-trail')].map(e => e.textContent),
        report: Object.keys(webResults).length + '/' + Object.keys(dnsResults).length,
      };
    });
    await page.evaluate(() => runTest());
    const first = await snap();
    eq('a.example,b.example,c.example', first.web.join(','), 'the first run lists its hosts');
    await page.evaluate(() => runTest());
    const second = await snap();
    eq('z.example,y.example', second.web.join(','), 'the second run shows only its own hosts, in order');
    eq('1/1,1/1', second.webTrail.join(','), 'the results land in the new rows');
    eq('Cloudflare (3.3.3.3)', second.tcp.join(','), 'TCP 16-20KB rows are replaced');
    eq('Quad9 (9.9.9.9),Yandex (77.88.8.8)', second.dns.join(','), 'DNS rows are replaced');
    truthy(second.rec && second.rec.length > 0, 'strategy recommendation badge is displayed on completion');
    eq('2/2', second.report, 'the report holds only the second run');
    const card = await page.evaluate(() => [document.getElementById('net-ip').textContent, document.getElementById('net-isp').textContent]);
    eq('5.18.158.84 (RU)', card[0], 'the network card shows the IP');
    eq('Z-Telecom · AS41733 · DNS: 8.8.8.8', card[1], 'the network card shows provider, AS and DNS');
    eq(0, pageErrors.length, 'no page errors' + (pageErrors.length ? ': ' + pageErrors.join('; ') : ''));
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
