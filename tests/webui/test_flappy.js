#!/usr/bin/env node
/*
 * Пасхалка: 12 быстрых нажатий на логотип в шапке открывают игру, тап
 * подбрасывает логотип, проигрыш ждёт тапа, рекорд запоминается, «Назад»
 * закрывает игру и возвращает интерфейс. Редкие нажатия игру не открывают.
 *
 * Needs playwright + a chromium build; exits 0 with SKIP when absent.
 * SHOTS=dir — сохранить снимки экрана (светлая и тёмная тема).
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
const STUB = `window.__turbo = [];
window.ksu = { exec: function(cmd, o, cb){
  var id = [o, cb].reverse().find(function(x){ return typeof x === 'string'; });
  if (cmd.indexOf("'smart-turbo'") >= 0) window.__turbo.push(cmd.indexOf("'on'") >= 0 ? 'on' : 'off');
  var out = 'OK';
  if (cmd.indexOf('json-status') >= 0) out = JSON.stringify({ running: true, pid: '4710', uptime: 5, strategy: 'alt',
    version: 'v2.1.3', mode: 'auto', app_mode: 'off', autostart: 1, watchdog: 1, ipv6: 1, paused: '',
    dns_available: 0, dns_enabled: 0, counts: { user: 0, auto: 0, exclude: 0, ipset: 0, ipset_exclude: 0, apps: 0 } });
  else if (cmd.indexOf('list-strategies') >= 0) out = 'alt\\tbuiltin\\t0';
  else if (cmd.indexOf('get-strategy') >= 0) out = 'alt';
  setTimeout(function(){ if (window[id]) window[id](0, out, ''); }, 5);
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

async function run(browser, scheme) {
  const ctx = await browser.newContext({ viewport: { width: 380, height: 760 }, colorScheme: scheme, hasTouch: true });
  await ctx.addInitScript(STUB);
  await ctx.addInitScript(() => { try { localStorage.setItem('nfq_seen_ver', 'v2.1.3'); } catch (e) {} });
  const page = await ctx.newPage();
  const errors = [];
  page.on('pageerror', e => errors.push(e.message));
  await page.goto(INDEX, { waitUntil: 'load' });
  await page.waitForTimeout(800);
  const open = () => page.evaluate(() => flappy.open);
  // Кликаем по координатам: page.click ждал бы конца тряски и растягивал паузы
  const box = await page.evaluate(() => { const r = document.getElementById('brand-logo').getBoundingClientRect(); return [r.x + r.width / 2, r.y + r.height / 2]; });
  const tapLogo = () => page.mouse.click(box[0], box[1]);

  sect(`${scheme}: slow taps`);
  for (let i = 0; i < 14; i++) { await tapLogo(); await page.waitForTimeout(700); }
  eq(false, await open(), 'taps far apart do not open the game');

  sect(`${scheme}: fast taps`);
  for (let i = 0; i < 12; i++) { await tapLogo(); await page.waitForTimeout(120); }
  eq(true, await open(), '12 quick taps open the game');
  await page.waitForTimeout(300);
  eq('on', await page.evaluate(() => window.__turbo[window.__turbo.length - 1]), 'the game speeds background learning up');
  eq('hidden', await page.evaluate(() => getComputedStyle(document.getElementById('brand-logo')).visibility), 'the logo left the header');
  await page.waitForTimeout(1900);
  truthy(await page.evaluate(() => document.elementFromPoint(190, 400).closest('#flappy') !== null), 'the overlay takes all taps');
  if (process.env.SHOTS) await page.screenshot({ path: path.join(process.env.SHOTS, `flappy-${scheme}-ready.png`) });

  sect(`${scheme}: play`);
  // Держим логотип в воздухе, пока не появятся трубы, затем даём упасть
  for (let i = 0; i < 9; i++) { await page.mouse.click(190, 500); await page.waitForTimeout(330); }
  if (process.env.SHOTS) await page.screenshot({ path: path.join(process.env.SHOTS, `flappy-${scheme}-play.png`) });
  await page.waitForTimeout(3000);
  if (process.env.SHOTS) await page.screenshot({ path: path.join(process.env.SHOTS, `flappy-${scheme}-dead.png`) });
  eq(true, await open(), 'a loss keeps the game open');
  await page.evaluate(() => localStorage.setItem('nfq_flappy_best', '7'));

  sect(`${scheme}: back`);
  await page.evaluate(() => handleBack(true));
  await page.waitForTimeout(800);
  eq(false, await open(), 'Back closes the game');
  await page.waitForTimeout(300);
  eq('off', await page.evaluate(() => window.__turbo[window.__turbo.length - 1]), 'and closing it slows it back down');
  eq(null, await page.$('#flappy'), 'the overlay is gone');
  eq('visible', await page.evaluate(() => getComputedStyle(document.getElementById('brand-logo')).visibility), 'the logo is back');
  eq('control', await page.evaluate(() => currentPage), 'Back did not leave the main screen');

  sect(`${scheme}: arrow and best score`);
  await page.reload({ waitUntil: 'load' });
  await page.waitForTimeout(800);
  for (let i = 0; i < 12; i++) { await tapLogo(); await page.waitForTimeout(120); }
  await page.waitForTimeout(1900);
  if (process.env.SHOTS) await page.screenshot({ path: path.join(process.env.SHOTS, `flappy-${scheme}-best.png`) });
  await page.click('#flappy button');
  await page.waitForTimeout(500);
  eq(false, await open(), 'the arrow closes the game');

  eq(0, errors.length, 'no page errors' + (errors.length ? ': ' + errors.join('; ') : ''));
  await ctx.close();
}

/* Альбомная ориентация: поле не шире квадрата и по центру — иначе препятствия
   редкие и видны издалека, игра другая */
async function landscape(browser) {
  const ctx = await browser.newContext({ viewport: { width: 915, height: 412 }, hasTouch: true });
  await ctx.addInitScript(STUB);
  await ctx.addInitScript(() => { try { localStorage.setItem('nfq_seen_ver', 'v2.1.3'); } catch (e) {} });
  const page = await ctx.newPage();
  const errors = [];
  page.on('pageerror', e => errors.push(e.message));
  await page.goto(INDEX, { waitUntil: 'load' });
  await page.waitForTimeout(800);
  sect('landscape: square field');
  const box = await page.evaluate(() => { const r = document.getElementById('brand-logo').getBoundingClientRect(); return [r.x + r.width / 2, r.y + r.height / 2]; });
  for (let i = 0; i < 12; i++) { await page.mouse.click(box[0], box[1]); await page.waitForTimeout(120); }
  await page.waitForTimeout(2000);
  eq(true, await page.evaluate(() => flappy.open), 'the game opens in landscape');
  const cv = await page.evaluate(() => { const r = document.querySelector('#flappy canvas').getBoundingClientRect(); return [Math.round(r.left), Math.round(r.width), Math.round(r.height)]; });
  eq(412, cv[1], 'the field is no wider than it is tall');
  eq(412, cv[2], 'and takes the full height');
  eq(Math.round((915 - 412) / 2), cv[0], 'centred');
  truthy(await page.evaluate(() => document.elementFromPoint(40, 300).closest('#flappy') !== null), 'the sides still take taps');
  if (process.env.SHOTS) await page.screenshot({ path: path.join(process.env.SHOTS, 'flappy-landscape.png') });
  eq(0, errors.length, 'no page errors' + (errors.length ? ': ' + errors.join('; ') : ''));
  await ctx.close();
}

(async () => {
  let browser;
  try { browser = await chromium.launch(); } catch (e) {
    process.stdout.write('SKIP  chromium is not available: ' + e.message.split('\n')[0] + '\n');
    process.exit(0);
  }
  await run(browser, 'light');
  await run(browser, 'dark');
  await landscape(browser);
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
