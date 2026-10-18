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
window.__dns = { enabled: false, def: 'net', priv: 'off', privHost: '', service: true, profiles: {}, calls: [] };
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
      'max_profiles=32', 'max_servers=8', 'max_domains=1000'];
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
      case 'dns-delete': a.slice(1).forEach(id => { delete st.profiles[id]; if (st.def === id) st.def = 'net'; }); return [0, 'OK'];
    }
    return [1, '', 'unknown'];
  }
  window.ksu = { exec: function(cmd, opts, cb){
    var id = typeof cb === 'string' ? cb : opts;
    var rc = 0, out = 'OK', err = '';
    (window.__cmds = window.__cmds || []).push(cmd);
    if (cmd.indexOf("'DOH_BYPASS'") >= 0) window.__doh = cmd.indexOf("'1'") >= 0 ? 1 : 0;
    if (cmd.indexOf('json-status') >= 0) out = ${JSON.stringify(STATUS)}.replace('"dns_available"', '"doh_bypass":' + (window.__doh || 0) + ',"dns_available"');
    else if (cmd.indexOf('list-strategies') >= 0) out = 'default\\talt13';
    else if (cmd.indexOf('get-strategy') >= 0) out = 'default';
    else if (cmd.indexOf("'dns-") >= 0) { const a = args(cmd); const r = dns(a.slice(a.findIndex(x => x.startsWith('dns-'))));
      rc = r[0]; out = r[1] || ''; err = r[2] || ''; }
    // __dnsSlow: медленный ответ dns-state — проверка слепка экрана
    var slow = cmd.indexOf("'dns-state'") >= 0 && window.__dnsSlow;
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
    truthy(await page.isVisible('#dns-profiles .empty'), 'an empty state is shown without profiles');
    await page.click('#dns-main'); await idle();
    eq(true, await page.evaluate(() => window.__dns.enabled), 'the main switch turns the feature on');
    eq(false, await page.evaluate(() => $('dns-body').classList.contains('is-disabled')), 'and enables the body');
    truthy((await page.textContent('#dns-general')).includes('Не активно'), 'the state says nothing is applied yet');

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
    eq('dns', await page.evaluate(() => currentPage), 'back returns to the DNS screen');
    truthy((await page.textContent('#dns-general .list-item')).includes('Игры'), 'the default DNS row names the profile');
    let state = await page.textContent('#dns-general');
    truthy(state.includes('Перехвачено запросов'), 'the state shows interception working');
    truthy(state.includes('остальное — через «Игры»'), 'and names the profile everything else goes to');
    truthy(!state.includes('192.168.1.1'), 'the network DNS is not shown while it is not used');
    await shot('main');
    await page.click('#dns-profiles .list-item:has-text("Игры")'); await idle();
    await page.click('button:has-text("Удалить профиль")');
    await answer();
    eq('dns', await page.evaluate(() => currentPage), 'deleting returns to the list');
    eq('net', await page.evaluate(() => window.__dns.def), 'the default falls back to the network DNS');

    sect(`${mode}: selecting several profiles`);
    await page.evaluate(() => { Object.assign(window.__dns.profiles, { s1: 'NAME=Alpha\nENABLED=0', s2: 'NAME=Beta\nENABLED=0', s3: 'NAME=Gamma\nENABLED=0' }); });
    await page.evaluate(() => dnsInit()); await idle();
    const total = await page.$$eval('#dns-profiles .list-item', r => r.length);
    const longPress = async sel => { const b = await page.$eval(sel, e => { e.scrollIntoView({ block: "center" }); const r = e.getBoundingClientRect(); return [r.x + r.width / 3, r.y + r.height / 2]; });
      await page.mouse.move(b[0], b[1]); await page.mouse.down(); await page.waitForTimeout(650); await page.mouse.up(); await idle(); };
    await longPress('#dns-profiles .list-item:has-text("Alpha")');
    eq('dns', await page.evaluate(() => currentPage), 'a long press does not open the profile');
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
    eq('DNS профили', await page.textContent('#app-title'), 'and the title');
    await longPress('#dns-profiles .list-item:has-text("Alpha")');
    await page.click('#bar-actions .icon-btn:nth-child(1)'); await idle();
    eq(total, await page.$$eval('#dns-profiles .list-item.selected', r => r.length), 'select all selects every profile');
    await page.click('#dns-profiles .list-item:has-text("Alpha")'); await idle();
    await page.click('#dns-profiles .list-item[data-id="google"]'); await idle();
    const keep = await page.$$eval('#dns-profiles .list-item:not(.selected) .li-primary', r => r.map(e => e.textContent));
    await page.click('#bar-actions .icon-btn:nth-child(3)');
    await page.waitForSelector('#dialog-wrap.open');
    truthy((await page.textContent('#dialog-wrap')).includes('Удалить'), 'delete asks first');
    await page.click('#d-ok'); await idle();
    const left = Object.keys(await page.evaluate(() => window.__dns.profiles));
    eq(2, left.length, 'the selected profiles are deleted in one call');
    truthy(await page.evaluate(() => window.__dns.calls.some(c => /^dns-delete \S+ \S+/.test(c))), 'with several ids');
    eq(keep.sort(), (await page.$$eval('#dns-profiles .li-primary', r => r.map(e => e.textContent))).sort(), 'only the unselected ones are left');
    eq(0, await page.$$eval('#dns-profiles .checkbox', r => r.length), 'and the list is back to normal');
    await longPress('#dns-profiles .list-item:has-text("Alpha")');
    await page.evaluate(() => handleBack(true)); await idle();
    eq('dns', await page.evaluate(() => currentPage), 'back leaves the selection, not the screen');
    // Палец на профиле, а системный жест «назад» уводит с экрана без pointerup
    const at = await page.$eval('#dns-profiles .list-item', e => { e.scrollIntoView({ block: 'center' }); const r = e.getBoundingClientRect(); return [r.x + 30, r.y + 20]; });
    await page.mouse.move(at[0], at[1]); await page.mouse.down();
    await page.evaluate(() => goBack()); await page.waitForTimeout(700);
    await page.mouse.up(); await idle();
    eq('settings', await page.evaluate(() => currentPage), 'a back gesture during a press leaves the screen');
    truthy(!(await page.textContent('#app-title')).includes('Выбрано') && !(await page.$('#bar-actions .icon-btn')),
      'and the selection bar does not appear on the settings screen');
    await page.evaluate(() => navigate('dns')); await idle();
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
      await p2.evaluate(() => { window.__dnsSlow = 1; navigate('dns'); });
      await p2.waitForTimeout(500);
      const early = await p2.evaluate(() => ({ count: document.querySelectorAll('#dns-profiles .list-item').length,
        on: $('dns-toggle').checked, locked: document.querySelector('.page[data-page="dns"]').inert }));
      truthy(early.count > 0, 'before the answer the last seen profiles are already on screen: ' + early.count);
      truthy(early.locked, 'the snapshot takes no taps until fresh data arrive');
      await p2.waitForTimeout(1600);
      truthy(await p2.evaluate(() => !document.querySelector('.page[data-page="dns"]').inert), 'fresh data unlock the screen');
      await p2.close();
    }

    sect(`${mode}: scroll position`);
    await page.evaluate(() => scrollToY(scroller.scrollHeight)); await idle();
    const y0 = await page.evaluate(() => scrollPos());
    truthy(y0 > 0, 'the DNS screen is scrolled down');
    await page.evaluate(() => openDnsProfile(dnsSt.profiles[0].id)); await page.waitForTimeout(900);
    eq(0, await page.evaluate(() => scrollPos()), 'a profile opens from the top');
    await page.evaluate(() => goBack()); await page.waitForTimeout(900);
    eq(y0, await page.evaluate(() => scrollPos()), 'back returns to the same place in the list');
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
    const txt = await page.textContent('[data-page="dns"]');
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
