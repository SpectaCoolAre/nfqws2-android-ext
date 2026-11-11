#!/usr/bin/env node
/**
 * test_dns.js — экран «DNS по профилям» (только версия extended).
 *
 * Страница открывается в Chromium с заглушкой ksu.exec, которая держит профили
 * в памяти и отвечает на dns-* так же, как nfqws2-ctl (формат dns-state и
 * dns-save-b64 — из lib/dns.sh). Проходятся основные сценарии: включение,
 * пресет, свой профиль с сервером и доменами, DNS по умолчанию, удаление,
 * предупреждение о «Частном DNS».
 */
'use strict';

const fs = require('fs');
const path = require('path');

let chromium;
try {
  ({ chromium } = require('playwright'));
} catch (e) {
  process.stdout.write('SKIP  playwright is not installed (set NODE_PATH to a workspace that has it)\n');
  process.exit(0);
}

const REPO = path.resolve(__dirname, '..', '..');
if (!fs.existsSync(path.join(REPO, 'webroot', 'js', 'dns.js'))) {
  process.stdout.write('SKIP  dns.js only exists in the extended build\n');
  process.exit(0);
}
const INDEX = 'file:///' + path.join(REPO, 'webroot', 'index.html').replace(/\\/g, '/');
const PRESETS = fs.readdirSync(path.join(REPO, 'defaults', 'dns-presets')).filter(f => f.endsWith('.conf'))
  .map(f => ({ id: f.replace(/\.conf$/, ''), text: fs.readFileSync(path.join(REPO, 'defaults', 'dns-presets', f), 'utf8') }));
const SHOTS = process.env.NFQWS_SHOTS || '';

const STATUS = JSON.stringify({
  running: true, pid: '4710', uptime: 52, strategy: 'alt13', version: 'v1.9.6-extended', mode: 'auto',
  pkt_limit_out: 15, pkt_limit_in: 15, block_quic: 0, app_mode: 'off',
  autostart: 1, watchdog: 1, ipv6: 1, log_level: 0, qdrop: 0, queue: 300, app_uids: 0, dns_available: 1,
  counts: { user: 381, auto: 25, exclude: 2839, ipset: 28420, ipset_exclude: 637, apps: 0 },
});

// Заглушка модуля: ksu.exec разбирает команду nfqws2-ctl и отвечает из памяти.
const STUB = `
window.__dns = { enabled: false, def: 'net', priv: 'off', privHost: '', service: true, profiles: {}, calls: [], geoN: 722, geoAt: 0 };
window.__presets = ${JSON.stringify(PRESETS)};
(function(){
  const st = window.__dns;
  const args = cmd => { const out = []; const re = /'((?:[^']|'\\\\'')*)'/g; let m;
    while ((m = re.exec(cmd))) out.push(m[1].replace(/'\\\\''/g, "'")); return out; };
  const dec = s => decodeURIComponent(escape(atob(s)));
  function norm(text){
    let name = '', desc = '', en = 0; const sv = [], dm = [];
    text.split('\\n').forEach(l => {
      if (l.startsWith('NAME=')) name = l.slice(5).trim();
      else if (l.startsWith('DESC=')) desc = l.slice(5);
      else if (l.startsWith('ENABLED=')) en = l.slice(8) === '1' ? 1 : 0;
      else if (l.startsWith('SERVER=') && !sv.includes(l.slice(7))) sv.push(l.slice(7));
      else if (l.startsWith('DOMAIN=') && !dm.includes(l.slice(7))) dm.push(l.slice(7));
    });
    if (!name) throw 'Нужно название профиля';
    if (sv.some(s => /\\s/.test(s))) throw 'Неверный адрес сервера';
    return ['NAME=' + name].concat(desc ? ['DESC=' + desc] : [], ['ENABLED=' + en], sv.map(s => 'SERVER=' + s), dm.map(d => 'DOMAIN=' + d)).join('\\n');
  }
  function state(){
    const any = Object.values(st.profiles).some(t => /ENABLED=1/.test(t) && /DOMAIN=/.test(t) && /SERVER=/.test(t));
    const on = st.enabled && (any || st.def !== 'net');
    let out = ['#status', 'enabled=' + (st.enabled ? 1 : 0), 'default=' + st.def,
      'proxy=' + (on ? 'running' : 'stopped'), 'rules=' + (on ? 'on' : 'off'), 'ipv6=redirect',
      'private=' + st.priv, 'private_host=' + st.privHost, 'net_dns=192.168.1.1', 'hits=' + (on ? 1234 : 0), 'error=',
      'max_profiles=32', 'max_servers=8', 'max_domains=1000', 'smart=' + (window.__smart === 0 ? 0 : 1),
      'cdn=' + (st.enabled && window.__smart !== 0 ? 'running' : ''),
      'geo=' + (window.__geo !== 0 ? 'on' : 'off'), 'geo_domains=' + st.geoN, 'geo_updated=' + st.geoAt, 'geo_pool=dns.fast.example', 'geo_for_dns.fast.example=600', 'geo_for_dns.ai.example=12', 'geo_direct=110', 'geo_try_dns.ai.example=2/3', 'geo_intercept=1', 'geo_off=' + (st.geoOff || ''), 'geo_who_net=213.87.1.1/8359', 'geo_who_google=213.87.1.1/8359', 'geo_who_cloudflare=-', 'geo_cert_dns.ai.example=4', 'geo_overlap_x=2', 'geo_scan_time=1767225600',
      'geo_svc_dns.fast.example=Fast', 'geo_svc_doh.fast.example/sync=Fast', 'geo_svc_dns.ai.example=dns.ai.example', 'geo_svc_dns.dead.example=Dead',
      'geo_svc_new.example=New', 'geo_addr_dns.fast.example=198.51.100.7', 'geo_down_doh.fast.example/sync=203.0.113.5,1767225600,1767227400',
      '#geoscan', 'dns.fast.example\tok\t40\t610\t722\t5\ttls', 'dns.ai.example\tok\t20\t40\t722\t12\ttls',
      'doh.fast.example/sync\tok\t90\t300\t722\t1\thttps\tDoT: dial tcp 1.2.3.4:853: i/o timeout',
      'dns.dead.example\tfail\t0\t0\t722\t0\t-\ttimeout', 'dns.gone.example\tfail\t0\t0\t722\t0\t-\ttimeout', '#status'];
    Object.keys(st.profiles).forEach(id => { out.push('#profile ' + id); out = out.concat(st.profiles[id].split('\\n')); });
    window.__presets.forEach(p => { out.push('#preset ' + p.id); out = out.concat(p.text.trim().split('\\n')); });
    return out.join('\\n');
  }
  function dns(a){
    st.calls.push(a.join(' '));
    switch (a[0]) {
      case 'dns-state': return [0, state()];
      case 'dns-set-enabled': st.enabled = a[1] === '1'; return [0, 'OK'];
      case 'dns-set-default': if (a[1] !== 'net' && !st.profiles[a[1]]) return [1, '', 'Профиль не найден'];
        st.def = a[1]; return [0, 'OK'];
      case 'dns-save-b64': try { st.profiles[a[1]] = norm(dec(a[2])); return [0, 'OK']; } catch (e) { return [1, '', String(e)]; }
      case 'dns-profile-enable': st.profiles[a[1]] = st.profiles[a[1]].replace(/ENABLED=\\d/, 'ENABLED=' + a[2]); return [0, 'OK'];
      case 'dns-geo-scan': return [0, '1767225600'];
      case 'dns-geo-scan-wait': return [0, 'dns.fast.example'];
      case 'dns-geo-off': st.geoOff = a[2] === '1' ? a[1].split(',').join(' ') : ''; return [0, 'OK'];
      case 'dns-geo-update': st.geoN = 731; st.geoAt = 1767225600; return [0, '731'];
      case 'dns-delete': a.slice(1).forEach(id => { delete st.profiles[id]; if (st.def === id) st.def = 'net'; }); return [0, 'OK'];
    }
    return [1, '', 'unknown'];
  }
  window.ksu = { exec: function(cmd, opts, cb){
    var id = typeof cb === 'string' ? cb : opts;
    var rc = 0, out = 'OK', err = '';
    (window.__cmds = window.__cmds || []).push(cmd);
    if (cmd.indexOf("'DOH_BYPASS'") >= 0) window.__doh = cmd.indexOf("'1'") >= 0 ? 1 : 0;
    if (cmd.indexOf("'DNS_SMART'") >= 0) window.__smart = cmd.indexOf("'1'") >= 0 ? 1 : 0;
    if (cmd.indexOf("'DNS_GEO'") >= 0) window.__geo = cmd.indexOf("'1'") >= 0 ? 1 : 0;
    if (cmd.indexOf("'dns-mode'") >= 0) window.__smart = window.__geo = cmd.indexOf("'smart'") >= 0 ? 1 : 0;
    if (cmd.indexOf('json-status') >= 0) out = ${JSON.stringify(STATUS)}.replace('"dns_available"', '"doh_bypass":' + (window.__doh || 0) + ',"dns_smart":' + (window.__smart === 0 ? 0 : 1) + ',"dns_geo":' + (window.__geo === 0 ? 0 : 1) + ',"dns_available"');
    else if (cmd.indexOf('list-strategies') >= 0) out = 'default\\talt13';
    else if (cmd.indexOf('get-strategy') >= 0) out = 'default';
    else if (cmd.indexOf("'dns-mode'") >= 0) out = 'OK';
    else if (cmd.indexOf("'dns-") >= 0) { const a = args(cmd); const r = dns(a.slice(a.findIndex(x => x.startsWith('dns-'))));
      rc = r[0]; out = r[1] || ''; err = r[2] || ''; }
    // __dnsSlow: медленный ответ dns-state — проверка слепка экрана
    var slow = (cmd.indexOf("'dns-state'") >= 0 && window.__dnsSlow) || (cmd.indexOf("'dns-set-enabled'") >= 0 && window.__dnsSetSlow);
    setTimeout(function(){ if (window[id]) window[id](rc, out, err); }, slow ? 1500 : 0);
    return 'job';
  }};
})();
`;

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
  for (const mode of ['light', 'dark']) {
    const ctx = await browser.newContext({ viewport: { width: 400, height: 900 }, deviceScaleFactor: 2, isMobile: true, hasTouch: true });
    await ctx.addInitScript(`try{localStorage.setItem('m3_mode','${mode}');}catch(e){}`);
    await ctx.addInitScript(STUB);
    const page = await ctx.newPage();
    const errors = [];
    page.on('pageerror', e => errors.push(e.message));
    await page.goto(INDEX, { waitUntil: 'load' });
    await page.waitForTimeout(500);
    const idle = () => page.waitForTimeout(450);
    // Диалоги: подставить значение в поле и нажать ОК / выбрать пункт меню
    const answer = async value => {
      await page.waitForSelector('#dialog-wrap.open');
      if (value !== undefined && await page.isVisible('#d-input')) await page.fill('#d-input', value);
      await page.click('#d-ok');
      await idle();
    };
    const menuPick = async label => { await page.waitForSelector('.menu .mi'); await page.click(`.menu .mi:has-text("${label}")`); await idle(); };
    const shot = async name => { if (SHOTS) await page.screenshot({ path: path.join(SHOTS, `${mode}-${name}.png`), fullPage: true }); };

    sect(`${mode}: settings → tools → DNS`);
    await page.evaluate(() => navigate('settings')); await idle();
    // обычная сборка (нет dnsproxy): пункта нет
    const hidden = await page.evaluate(() => { const was = S.dns_available; S.dns_available = 0; renderSettings();
      const has = $('settings-body').textContent.includes('DNS профили'); S.dns_available = was; renderSettings(); return !has; });
    truthy(hidden, 'the regular build (no dnsproxy) has no DNS item');
    const row = await page.$('#settings-body .list-item:has-text("DNS профили")');
    truthy(!!row, 'the DNS row is in the settings');
    const group = await page.evaluate(() => {
      const r = [...document.querySelectorAll('#settings-body .list-item')].find(e => e.textContent.includes('DNS профили'));
      return r && r.closest('.stack').querySelector('.subhead').textContent;
    });
    eq('Инструменты', group, 'in the Tools group');
    truthy((await page.textContent('#settings-body')).includes('Версия v1.9.6-extended'), 'the version reads "v1.9.6-extended", as on GitHub');
    await row.click(); await idle();
    eq('dns', await page.evaluate(() => currentPage), 'it opens the DNS screen');
    eq(true, await page.evaluate(() => $('dns-body').classList.contains('is-disabled')), 'the body is greyed out while the feature is off');

    sect(`${mode}: work mode`);
    eq('smart', await page.evaluate(() => $('dns-mode-seg').querySelector('.seg.selected').dataset.mode), 'smart mode is the default');
    truthy((await page.textContent('#dns-nav')).includes('Обход геоблока'), 'it leads to the geo-block bypass');
    truthy((await page.textContent('#dns-nav')).includes('Включится вместе с DNS модуля'), 'and shows speed, which starts with DNS');
    eq(0, await page.$$eval('[data-page="dns"] [aria-expanded]', r => r.length), 'no folding groups: sections are screens of their own');
    await page.click('#dns-mode-seg .seg[data-mode="profiles"]');
    await page.waitForSelector('#dialog-wrap.open');
    truthy((await page.textContent('#dialog-wrap')).includes('Перейти на профили?'), 'switching asks first');
    await page.click("#d-cancel"); await page.waitForTimeout(400);
    eq(false, await page.evaluate(() => window.__cmds.some(c => c.indexOf("'dns-mode'") >= 0)), 'cancel changes nothing');
    eq('smart', await page.evaluate(() => $('dns-mode-seg').querySelector('.seg.selected').dataset.mode), 'and the mode stays');
    await page.click('#dns-mode-seg .seg[data-mode="profiles"]');
    await page.waitForSelector('#dialog-wrap.open');
    await page.click("#d-ok"); await page.waitForTimeout(800);
    truthy(await page.evaluate(() => window.__cmds.some(c => c.indexOf("'dns-mode' 'profiles'") >= 0)), 'confirmed: one command switches the mode');
    eq('profiles', await page.evaluate(() => $('dns-mode-seg').querySelector('.seg.selected').dataset.mode), 'profiles mode is selected');
    eq(false, (await page.textContent('#dns-nav')).includes('Обход геоблока'), 'the smart sections are hidden');
    truthy((await page.textContent('#dns-nav')).includes('Профили'), 'profiles stay');
    await page.click('#dns-mode-seg .seg[data-mode="smart"]');
    await page.waitForSelector('#dialog-wrap.open');
    truthy((await page.textContent('#dialog-wrap')).includes('Включить умный режим DNS?'), 'back to smart asks too');
    await page.click("#d-ok"); await page.waitForTimeout(800);
    eq('smart', await page.evaluate(() => $('dns-mode-seg').querySelector('.seg.selected').dataset.mode), 'smart mode again');

    sect(`${mode}: DoT/DoH blocking bypass`);
    eq(false, await page.isChecked('#dns-doh input'), 'the DoT/DoH bypass is off by default');
    eq(false, await page.evaluate(() => !!$('dns-doh').closest('[inert]')), 'and can be switched while DNS profiles are off');
    await page.click('#dns-doh label'); await page.waitForTimeout(700);
    truthy(await page.evaluate(() => window.__cmds.some(c => c.indexOf("'set' 'DOH_BYPASS' '1'") >= 0)), 'the switch saves DOH_BYPASS=1');
    truthy(await page.evaluate(() => window.__cmds.some(c => /'restart'/.test(c))), 'and restarts the running service');
    eq(true, await page.isChecked('#dns-doh input'), 'the switch stays on');
    await page.click('#dns-doh label'); await page.waitForTimeout(700);

    sect(`${mode}: switching on`);
    // Пресеты в профили кладёт модуль при первом запуске (test_dns.sh); у заглушки их нет
    truthy((await page.textContent('#dns-nav .list-item:has-text("Профили")')).includes('Профилей пока нет'), 'the profiles line sums them up');
    // включение — секунды: экран меняется сразу, второе нажатие не выключает
    await page.evaluate(() => { window.__dnsSetSlow = 1; });
    await page.click('#dns-main'); await page.waitForTimeout(150);
    const sw = await page.evaluate(() => ({ on: $('dns-main').classList.contains('on'), checked: $('dns-toggle').checked, body: !$('dns-body').classList.contains('is-disabled') }));
    eq({ on: true, checked: true, body: true }, sw, 'the switch shows «on» at once, before the module answers');
    await page.click('#dns-main'); await page.waitForTimeout(100);
    eq(true, await page.evaluate(() => $('dns-toggle').checked), 'a second tap while it switches is ignored');
    await page.evaluate(() => { window.__dnsSetSlow = 0; });
    await page.waitForTimeout(1700); await idle();
    eq(1, await page.evaluate(() => window.__dns.calls.filter(c => c.startsWith('dns-set-enabled')).length), 'only one command is sent');
    eq(true, await page.evaluate(() => window.__dns.enabled), 'the main switch turns the feature on');
    eq(false, await page.evaluate(() => $('dns-body').classList.contains('is-disabled')), 'and enables the body');
    truthy((await page.textContent('#dns-general')).includes('Не активно'), 'the state says nothing is applied yet');
    truthy((await page.textContent('#dns-general')).includes('DNS по умолчанию'), 'smart mode: the default DNS row is there too (it is used in smart mode as well)');
    truthy((await page.textContent('#dns-warn')).includes('Домены из списка геоблока есть в профилях x (2)'), 'a profile that takes domains of the geo-block list away from the bypass is warned about');
    eq(false, (await page.textContent('#dns-warn')).includes('перехватывает'), 'interception of plain DNS is not mentioned while no profile has plain addresses — nothing to fix');
    truthy((await page.textContent('#dns-nav .list-item:has-text("Обход геоблока")')).includes('DNS: dns.fast.example'), 'the geo-block bypass line names the DNS in use');
    await page.click('#dns-nav .list-item:has-text("Обход геоблока")'); await idle();
    eq('dnsgeo', await page.evaluate(() => currentPage), 'a tap opens the geo-block bypass screen');
    eq('Обход геоблока', await page.textContent('#app-title'), 'with its own title');
    let geoTxt = await page.textContent('#dns-geo');
    await shot('geo');
    truthy(geoTxt.includes('40 мс · обходит 610 из 722 · работают 2 из 2 · в пуле'), 'unfolded: each checked server in one short line');
    truthy(geoTxt.includes('20 мс · обходит 40 из 722 · через раз · доменов: 12'), 'a server outside the pool says how many domains go to it, and that it answers now and then');
    truthy(geoTxt.includes('не отвечает') && !geoTxt.includes('timeout'), 'a dead one just says it does not answer');
    truthy(geoTxt.includes('Fast') && !geoTxt.includes('doh.fast.example') && geoTxt.includes('работают 2 из 2'), 'services are shown by name, with how many of their variants work');
    truthy(geoTxt.includes('ещё не проверялся'), 'a service new in the list says it was not checked yet');
    eq(false, geoTxt.includes('dns.gone.example'), 'a server left out of the list is not shown from an old check');
    await page.click('#dns-geo .list-item:has(.li-primary:text-is("Fast"))');
    await page.waitForSelector('#dialog-wrap.open');
    const svc = await page.textContent('#dialog-wrap');
    truthy(svc.includes('tls://dns.fast.example') && svc.includes('https://doh.fast.example/sync') && svc.includes('Адрес: 198.51.100.7'), 'a tap on a service shows each variant: DoT or DoH by its own path, and the address');
    truthy(svc.includes('DoT не прошёл (нет ответа) — работает по DoH'), 'and why a variant goes over DoH');
    truthy(svc.includes('На паузе в этой сети: прокси 203.0.113.5 не открывается и через обход'), 'a variant whose proxy does not open here says it is paused');
    await page.click('#d-ok'); await idle(); await page.waitForTimeout(400);
    truthy(await page.evaluate(() => window.__dns.calls.includes('dns-geo-off dns.fast.example,doh.fast.example/sync 1')), 'switching off takes every variant of the service');
    truthy((await page.textContent('#dns-geo')).includes('отключён вручную'), 'the service says it is off');
    await page.click('#dns-geo .list-item:has(.li-primary:text-is("Fast"))'); await page.waitForSelector('#dialog-wrap.open');
    await page.click('#d-ok'); await idle(); await page.waitForTimeout(400);
    truthy(await page.evaluate(() => window.__dns.calls.includes('dns-geo-off dns.fast.example,doh.fast.example/sync 0')), 'and back on');
    await page.click('#dns-geo .list-item:has-text("dns.ai.example")');
    await page.waitForSelector('#dialog-wrap.open');
    const info = await page.textContent('#dialog-wrap');
    truthy(info.includes('Обходит геоблок для 40 из 722 доменов списка') && info.includes('Из них своим адресом: 12') && info.includes('Направлено к нему доменов: 12') && info.includes('Отвечает через раз: 2 из 3') && info.includes('для 4 доменов'), 'a tap on a server shows what it bypasses, what goes to it and how reliable it is');
    truthy((await page.textContent('#d-ok')).includes('Не использовать'), 'a server can be switched off by hand from there');
    await page.click('#d-cancel'); await page.waitForTimeout(400);
    eq(false, await page.evaluate(() => window.__dns.calls.some(c => c.startsWith('dns-geo-off dns.ai.example'))), 'closing the dialog changes nothing');
    await page.click('#dns-geo .list-item:has-text("dns.ai.example")');
    await page.waitForSelector('#dialog-wrap.open');
    await page.click('#d-ok'); await idle(); await page.waitForTimeout(400);
    truthy(await page.evaluate(() => window.__dns.calls.includes('dns-geo-off dns.ai.example 1')), '«Don\'t use» switches it off');
    truthy((await page.textContent('#dns-geo')).includes('отключён вручную'), 'and the list says so');
    await page.click('#dns-geo .list-item:has-text("dns.ai.example")');
    await page.waitForSelector('#dialog-wrap.open');
    truthy((await page.textContent('#dialog-wrap')).includes('Отключён вручную') && (await page.textContent('#d-ok')).includes('Использовать снова'), 'its dialog offers to use it again');
    await page.click('#d-ok'); await idle(); await page.waitForTimeout(400);
    truthy(await page.evaluate(() => window.__dns.calls.includes('dns-geo-off dns.ai.example 0')), 'and back on');
    await page.click('#dns-geo .clickable:has-text("Проверить DNS сейчас")'); await idle(); await page.waitForTimeout(300);
    truthy(await page.evaluate(() => window.__dns.calls.includes('dns-geo-scan')), 'the check can be run at once');
    truthy(await page.evaluate(() => window.__dns.calls.includes('dns-geo-scan-wait 1767225600')), 'it runs in the background and the screen waits for its result by the request time');
    truthy(geoTxt.includes('geoblock.list · доменов: 722'), 'the service list shows its size');
    await page.click('#dns-geo .clickable:has-text("Обновить список")'); await idle(); await page.waitForTimeout(400);
    truthy(await page.evaluate(() => window.__dns.calls.includes('dns-geo-update')), 'the update button downloads a fresh list');
    truthy((await page.textContent('#dns-geo')).includes('доменов: 731'), 'and the new size is shown');
    await page.evaluate(() => goBack()); await idle();
    eq('dns', await page.evaluate(() => currentPage), 'back leads to the DNS screen');

    sect(`${mode}: the profiles screen`);
    await page.click('#dns-nav .list-item:has-text("Профили")'); await idle();
    eq('dnsprofiles', await page.evaluate(() => currentPage), 'a tap opens the profiles screen');
    eq('Профили DNS', await page.textContent('#app-title'), 'with its own title');
    truthy(await page.isVisible('#dns-profiles .empty'), 'an empty state is shown without profiles');

    sect(`${mode}: a preset`);
    await page.click('#dns-add'); await menuPick('Из пресетов');
    await page.waitForSelector('#dns-preset-sheet.open');
    const presetNames = PRESETS.map(p => (/^NAME=(.*)$/m.exec(p.text) || [])[1]).sort();
    eq(presetNames, (await page.$$eval('#dns-preset-list .li-primary', l => l.map(e => e.textContent))).slice().sort(), 'every preset is offered');
    const withDomains = PRESETS.filter(p => /^DOMAIN=/m.test(p.text)).length;
    truthy(withDomains >= 1, 'a preset comes with domains (GeoHide)');
    eq(Array(withDomains).fill('dns').join(','), (await page.$$eval('#dns-preset-list .li-icon use', l => l.map(e => e.getAttribute('href').slice(3)))).slice(0, withDomains).join(','),
      'presets with domains come first');
    await shot('presets');
    await page.click('#dns-preset-list .list-item:has(.li-primary:text-is("Google Public DNS"))'); await idle();
    const gpre = await page.evaluate(() => window.__dns.profiles.google || '');
    eq(['https://dns.google/dns-query', 'tls://dns.google', '8.8.8.8', '8.8.4.4'],
      gpre.split('\n').filter(l => l.startsWith('SERVER=')).map(l => l.slice(7)), 'the preset is saved with DoH, DoT and both IPs');
    truthy(gpre.includes('ENABLED=0'), 'a preset without domains is added switched off');
    await page.click('#dns-profiles .list-item:has-text("Google Public DNS")'); await idle();
    eq(['DoH (HTTPS)', 'DoT (TLS)', 'Обычный DNS', 'Обычный DNS'],
      await page.$$eval('#dnsp-servers .li-secondary', l => l.map(e => e.textContent)), 'plain IPs are shown as one plain DNS type');
    await page.evaluate(() => goBack()); await idle();

    sect(`${mode}: a new profile`);
    await page.click('#dns-add'); await menuPick('Новый профиль');
    await answer('Игры');
    eq('dnsprof', await page.evaluate(() => currentPage), 'a new profile opens its own screen');
    eq('Игры', await page.textContent('#app-title'), 'titled with the profile name');
    truthy(await page.isVisible('#dnsp-servers .empty'), 'it asks for a server first');
    // сервер DoT: тип из меню, затем адрес; имя без схемы
    await page.click('#dnsp-add-server'); await menuPick('DoT (TLS)');
    await answer('dns.google');
    // DoH: только имя — допишется /dns-query
    await page.click('#dnsp-add-server'); await menuPick('DoH (HTTPS)');
    await answer('dns.comss.one');
    // неверный адрес — повторный запрос, затем отмена
    const types = await page.evaluate(async () => { addDnsServer($('dnsp-add-server')); await new Promise(r => setTimeout(r, 200));
      const l = [...document.querySelectorAll('.menu .mi-text')].map(e => e.textContent); closeMenu(); return l; });
    await idle();
    truthy(types.includes('Обычный DNS') && !types.some(x => /UDP|TCP/.test(x)), 'one plain DNS type, no UDP/TCP split');
    await page.click('#dnsp-add-server'); await menuPick('Обычный DNS');
    await answer('dns.google');
    truthy(await page.isVisible('#dialog-wrap.open'), 'a plain DNS server by name is refused and asked again');
    await page.click('#d-cancel'); await idle();
    const gid = () => Object.keys(window.__dns.profiles).find(k => k !== 'google');
    let prof = await page.evaluate(`window.__dns.profiles[(${gid})()]`);
    truthy(prof.includes('SERVER=tls://dns.google'), 'DoT is stored as tls://');
    truthy(prof.includes('SERVER=https://dns.comss.one/dns-query'), 'DoH gets /dns-query');
    eq(2, await page.$$eval('#dnsp-servers .list-item', l => l.length), 'two servers are listed');
    // домены: несколько за раз, мусор отбрасывается, кириллица -> punycode
    await page.click('#dnsp-add-domain');
    await answer('https://www.Roblox.com/games, *.rbxcdn.com пример.рф bad..name');
    prof = await page.evaluate(`window.__dns.profiles[(${gid})()]`);
    truthy(prof.includes('DOMAIN=www.roblox.com') && prof.includes('DOMAIN=rbxcdn.com'), 'URLs and wildcards become plain domains');
    truthy(prof.includes('DOMAIN=xn--e1afmkfd.xn--p1ai'), 'a Cyrillic domain is stored in punycode');
    truthy(!prof.includes('bad..name'), 'an invalid domain is skipped');
    eq(3, await page.$$eval('#dnsp-domains .list-item', l => l.length), 'three domains are listed');
    // включение и выбор по умолчанию
    await page.click('#dnsp-head label.list-item'); await idle();
    truthy((await page.evaluate(() => window.__dns.profiles[dnsCur])).includes('ENABLED=1'), 'the profile is switched on from its screen');
    await page.click('#dnsp-head .list-item:has-text("DNS по умолчанию")'); await idle();
    eq(await page.evaluate(() => dnsCur), await page.evaluate(() => window.__dns.def), 'it can become the default DNS');
    await shot('profile');
    // правка доменов списком
    await page.click('button:has-text("Редактировать списком")'); await idle();
    await page.fill('#panel-editor-text', 'a.example\nb.example  # second\n# comment line\n');
    await page.click('#panel-save-btn'); await idle();
    prof = await page.evaluate(() => window.__dns.profiles[dnsCur]);
    truthy(/DOMAIN=a\.example\nDOMAIN=b\.example$/.test(prof), 'the list editor replaces the domains');
    await page.click('#panel-save-btn').catch(() => {});

    sect(`${mode}: back and delete`);
    await page.evaluate(() => goBack()); await idle();
    eq('dnsprofiles', await page.evaluate(() => currentPage), 'back returns to the profiles');
    await page.evaluate(() => goBack()); await idle();
    eq('dns', await page.evaluate(() => currentPage), 'and then to the DNS screen');
    await page.click('#dns-mode-seg .seg[data-mode="profiles"]');
    await page.waitForSelector('#dialog-wrap.open'); await page.click("#d-ok"); await page.waitForTimeout(800);
    truthy((await page.textContent('#dns-general')).includes('DNS по умолчанию') && (await page.textContent('#dns-general')).includes('Игры'), 'profiles mode: the default DNS row names the profile');
    let state = await page.textContent('#dns-general');
    truthy(state.includes('Перехвачено запросов'), 'the state shows interception working');
    truthy(state.includes('остальное — через «Игры»'), 'and names the profile everything else goes to');
    truthy(!state.includes('192.168.1.1'), 'the network DNS is not shown while it is not used');
    await shot('main');
    await page.click('#dns-nav .list-item:has-text("Профили")'); await idle();
    await page.click('#dns-profiles .list-item:has-text("Игры")'); await idle();
    await page.click('button:has-text("Удалить профиль")');
    await answer();
    eq('dnsprofiles', await page.evaluate(() => currentPage), 'deleting returns to the list');
    eq('net', await page.evaluate(() => window.__dns.def), 'the default falls back to the network DNS');

    sect(`${mode}: selecting several profiles`);
    await page.evaluate(() => { Object.assign(window.__dns.profiles, { s1: 'NAME=Alpha\nENABLED=0', s2: 'NAME=Beta\nENABLED=0', s3: 'NAME=Gamma\nENABLED=0' }); });
    await page.evaluate(() => dnsInit()); await idle();
    const total = await page.$$eval('#dns-profiles .list-item[data-id]', r => r.length);
    const longPress = async sel => { const b = await page.$eval(sel, e => { e.scrollIntoView({ block: "center" }); const r = e.getBoundingClientRect(); return [r.x + r.width / 3, r.y + r.height / 2]; });
      await page.mouse.move(b[0], b[1]); await page.mouse.down(); await page.waitForTimeout(650); await page.mouse.up(); await idle(); };
    await longPress('#dns-profiles .list-item:has-text("Alpha")');
    eq('dnsprofiles', await page.evaluate(() => currentPage), 'a long press does not open the profile');
    eq(total, await page.$$eval('#dns-profiles .list-item .checkbox', r => r.length), 'it turns every switch into a checkbox');
    eq(0, await page.$$eval('#dns-profiles .switch', r => r.length), 'no switches are left');
    eq(['Alpha'], await page.$$eval('#dns-profiles .list-item.selected .li-primary', r => r.map(e => e.textContent)), 'the pressed profile is selected');
    truthy((await page.textContent('#app-title')).includes('1'), 'the title counts the selection');
    eq(3, await page.$$eval('#bar-actions .icon-btn', r => r.length), 'the top bar has select all, cancel and delete');
    await shot('select');
    await page.click('#dns-profiles .list-item:has-text("Beta")'); await idle();
    eq(2, await page.$$eval('#dns-profiles .list-item.selected', r => r.length), 'a tap adds a profile to the selection');
    await page.click('#bar-actions .icon-btn:nth-child(2)'); await idle();
    eq(0, await page.$$eval('#dns-profiles .checkbox', r => r.length), 'cancel brings the switches back');
    eq('Профили DNS', await page.textContent('#app-title'), 'and the title');
    await longPress('#dns-profiles .list-item:has-text("Alpha")');
    await page.click('#bar-actions .icon-btn:nth-child(1)'); await idle();
    eq(total, await page.$$eval('#dns-profiles .list-item.selected', r => r.length), 'select all selects every profile');
    await page.click('#dns-profiles .list-item:has-text("Alpha")'); await idle();
    await page.click('#dns-profiles .list-item[data-id="google"]'); await idle();
    const keep = await page.$$eval('#dns-profiles .list-item[data-id]:not(.selected) .li-primary', r => r.map(e => e.textContent));
    await page.click('#bar-actions .icon-btn:nth-child(3)');
    await page.waitForSelector('#dialog-wrap.open');
    truthy((await page.textContent('#dialog-wrap')).includes('Удалить'), 'delete asks first');
    await page.click('#d-ok'); await idle();
    const left = Object.keys(await page.evaluate(() => window.__dns.profiles));
    eq(2, left.length, 'the selected profiles are deleted in one call');
    truthy(await page.evaluate(() => window.__dns.calls.some(c => /^dns-delete \S+ \S+/.test(c))), 'with several ids');
    eq(keep.sort(), (await page.$$eval('#dns-profiles .list-item[data-id] .li-primary', r => r.map(e => e.textContent))).sort(), 'only the unselected ones are left');
    eq(0, await page.$$eval('#dns-profiles .checkbox', r => r.length), 'and the list is back to normal');
    await longPress('#dns-profiles .list-item:has-text("Alpha")');
    await page.evaluate(() => handleBack(true)); await idle();
    eq('dnsprofiles', await page.evaluate(() => currentPage), 'back leaves the selection, not the screen');
    // Палец на профиле, а системный жест «назад» уводит с экрана без pointerup
    const at = await page.$eval('#dns-profiles .list-item[data-id]', e => { e.scrollIntoView({ block: 'center' }); const r = e.getBoundingClientRect(); return [r.x + 30, r.y + 20]; });
    await page.mouse.move(at[0], at[1]); await page.mouse.down();
    await page.evaluate(() => goBack()); await page.waitForTimeout(700);
    await page.mouse.up(); await idle();
    eq('dns', await page.evaluate(() => currentPage), 'a back gesture during a press leaves the screen');
    truthy(!(await page.textContent('#app-title')).includes('Выбрано') && !(await page.$('#bar-actions .icon-btn:not([aria-label="Журнал DNS"])')),
      'and the selection bar does not appear on the DNS screen');
    await page.evaluate(() => navigate('dnsprofiles')); await idle();
    eq(0, await page.$$eval('#dns-profiles .checkbox', r => r.length), 'and restores the switches');

    sect(`${mode}: IPv6 note only when a working profile has an IPv6 server`);
    {
      const v6note = await page.evaluate(() => {
        const keep = {status: dnsSt.status, profiles: dnsSt.profiles};
        const run = profiles => { dnsSt.status = {enabled: '1', ipv6: 'none', rules: 'on', default: 'net'}; dnsSt.profiles = profiles; return /IPv6/.test(dnsWarnings()); };
        const r = {
          v4only: run([{id: 'a', enabled: true, servers: ['1.1.1.1', 'tls://one.one.one.one'], domains: []}]),
          v6on: run([{id: 'a', enabled: true, servers: ['1.1.1.1', '2606:4700::1111'], domains: []}]),
          v6off: run([{id: 'a', enabled: false, servers: ['tls://[2606:4700::1111]'], domains: []}])
        };
        dnsSt.status = {enabled: '1', ipv6: 'none', rules: 'on', default: 'a'};
        dnsSt.profiles = [{id: 'a', enabled: false, servers: ['[2001:db8::1]:53'], domains: []}];
        r.v6default = /IPv6/.test(dnsWarnings());
        dnsSt.status = keep.status; dnsSt.profiles = keep.profiles;
        return r;
      });
      eq(false, v6note.v4only, 'no IPv6 servers in the profiles — no IPv6 note');
      eq(true, v6note.v6on, 'an enabled profile with an IPv6 server — the note is shown');
      eq(false, v6note.v6off, 'an IPv6 server only in a disabled profile does not count');
      eq(true, v6note.v6default, 'the default profile counts even when not switched on');
    }

    sect(`${mode}: snapshot while loading`);
    {
      // свежая страница (кэш экрана в памяти пуст), ответ dns-state задерживается
      const p2 = await ctx.newPage();
      await p2.goto(INDEX, { waitUntil: 'load' });
      // localStorage между вкладками Chromium синхронизирует асинхронно и под
      // нагрузкой может не успеть: слепок первой вкладки переносится явно
      const snapDns = await page.evaluate(() => snapGet('dns'));
      truthy(!!snapDns, 'the DNS screen left a snapshot behind');
      await p2.evaluate(v => snapSet('dns', v), snapDns);
      await p2.evaluate(() => { window.__dnsSlow = 1; navigate('dnsprofiles'); });
      await p2.waitForTimeout(500);
      const early = await p2.evaluate(() => ({ count: document.querySelectorAll('#dns-profiles .list-item[data-id]').length,
        on: $('dns-toggle').checked, locked: document.querySelector('.page[data-page="dnsprofiles"]').inert }));
      truthy(early.count > 0, 'before the answer the last seen profiles are already on screen: ' + early.count);
      truthy(early.locked, 'the snapshot takes no taps until fresh data arrive');
      await p2.waitForTimeout(1600);
      truthy(await p2.evaluate(() => !document.querySelector('.page[data-page="dnsprofiles"]').inert), 'fresh data unlock the screen');
      await p2.close();
    }

    sect(`${mode}: scroll position`);
    // на экране профилей должно быть что листать
    await page.evaluate(() => { for (let i = 0; i < 14; i++) window.__dns.profiles['z' + i] = 'NAME=Zeta ' + i + '\nENABLED=0'; });
    await page.evaluate(() => dnsInit()); await idle();
    await page.evaluate(() => scrollToY(scroller.scrollHeight)); await idle();
    const y0 = await page.evaluate(() => scrollPos());
    truthy(y0 > 0, 'the profiles screen is scrolled down');
    await page.evaluate(() => openDnsProfile(dnsSt.profiles[0].id)); await page.waitForTimeout(900);
    eq(0, await page.evaluate(() => scrollPos()), 'a profile opens from the top');
    await page.evaluate(() => goBack()); await page.waitForTimeout(900);
    eq(y0, await page.evaluate(() => scrollPos()), 'back returns to the same place in the list');
    await page.evaluate(() => goBack()); await page.waitForTimeout(900);
    eq('dns', await page.evaluate(() => currentPage), 'back to the DNS screen');
    await page.evaluate(() => goBack()); await page.waitForTimeout(900);
    eq('settings', await page.evaluate(() => currentPage), 'back to settings');
    await page.evaluate(() => navigate('dns')); await page.waitForTimeout(900);

    sect(`${mode}: independent of the service`);
    // профиль с доменами, чтобы было что применять
    await page.evaluate(() => { window.__dns.profiles.google = window.__dns.profiles.google.replace('ENABLED=0', 'ENABLED=1') + '\nDOMAIN=chatgpt.com'; });
    await page.evaluate(() => { window.__dns.service = false; }); await page.evaluate(() => dnsInit()); await idle();
    truthy(!(await page.textContent('#dns-general')).includes('Без службы обхода'), 'there is no standalone switch');
    truthy(!(await page.textContent('#dns-warn')).includes('Служба не запущена'), 'no "service stopped" warning');
    state = await page.textContent('#dns-general');
    truthy(state.includes('Работает'), 'DNS works with the service stopped');
    truthy(state.includes('остальное — через DNS сети (192.168.1.1)'), 'the network DNS is shown when it is the default');
    const warnTxt = await page.textContent('#dns-warn');
    truthy(warnTxt.includes('ответил не их сервер, а сервер сети (213.87.1.1, AS8359)') && warnTxt.includes('(8.8.8.8, 8.8.4.4)'), 'an enabled profile with plain addresses: the warning says who really answered and which addresses to change');
    await shot('standalone');
    await page.evaluate(() => { window.__dns.service = true; });

    sect(`${mode}: Private DNS`);
    await page.evaluate(() => { window.__dns.priv = 'hostname'; window.__dns.privHost = 'dns.google'; });
    await page.evaluate(() => dnsInit()); await idle();
    const warn = await page.textContent('#dns-warn');
    truthy(warn.includes('Частный DNS') && warn.includes('dns.google'), 'Private DNS with a host is flagged');
    truthy((await page.textContent('#dns-general')).includes('Не применяется'), 'and the state does not claim to work');
    const btn = await page.$eval('#dns-warn .btn', b => b.scrollWidth <= b.clientWidth + 1);
    truthy(btn, 'the Open button is not squeezed');
    await shot('private');

    sect(`${mode}: English`);
    await page.evaluate(() => setLanguage('en')); await idle();
    const txt = await page.$$eval('[data-page="dns"], [data-page="dnsgeo"], [data-page="dnsprofiles"]', l => l.map(e => e.textContent).join('\n'));
    truthy(!/[А-Яа-яЁё]/.test(txt), 'no Russian text left on the screen in English' + ((txt.match(/[^.\n]*[А-Яа-яЁё][^.\n]*/g) || []).slice(0, 3).join(' | ') ? ': ' + (txt.match(/[А-Яа-яЁё][^\n]{0,40}/g) || []).slice(0, 3).join(' | ') : ''));
    await page.evaluate(() => setLanguage('ru')); await idle();

    eq([], errors, 'no page errors');
    await ctx.close();
  }
  await browser.close();
  process.stdout.write('\n----------------------------------------\n');
  if (!failures.length) { process.stdout.write(`PASS  ${pass} checks\n`); process.exit(0); }
  process.stdout.write(`FAIL  ${failures.length} of ${pass + failures.length} checks failed\n`);
  for (const f of failures) process.stdout.write(`   - ${f}\n`);
  process.exit(1);
})();
