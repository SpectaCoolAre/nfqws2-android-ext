#!/usr/bin/env node
/**
 * Hosts editor regression tests — dependency-free Node VM, no Android runtime.
 * Exercises actual hosts code and shared render/escaping helpers with a ctl stub.
 */
'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');
const REPO = path.resolve(__dirname, '..', '..');
const read = file => fs.readFileSync(path.join(REPO, file), 'utf8');
const hostsCode = read('webroot/js/hosts.js');
const coreCode = read('webroot/js/core.js');
const settingsCode = read('webroot/js/settings.js');
const html = read('webroot/index.html');

let pass = 0, section = '';
const failures = [];
function sect(name) { section = name; process.stdout.write(`\n== ${name}\n`); }
function ok(msg) { pass++; process.stdout.write(`   ok   ${msg}\n`); }
function fail(msg) { failures.push(`[${section}] ${msg}`); process.stdout.write(`   FAIL ${msg}\n`); }
function eq(expected, actual, msg) {
  if (JSON.stringify(expected) === JSON.stringify(actual)) ok(msg);
  else fail(`${msg} -- expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
}
function truthy(value, msg) { value ? ok(msg) : fail(msg); }

// Load real helpers rather than duplicating their HTML escaping in the stub.
function fn(source, name) {
  const match = source.match(new RegExp(`^function ${name}\\([^]*?^}`, 'm'));
  if (!match) throw new Error(`Function not found: ${name}`);
  return match[0];
}
function element() {
  const classes = new Set();
  return { innerHTML: '', textContent: '', checked: false, disabled: false, inert: false,
    classList: {
      add: name => classes.add(name), remove: name => classes.delete(name),
      contains: name => classes.has(name),
      toggle: (name, on) => on ? classes.add(name) : classes.delete(name)
    }
  };
}
const elements = {};
for (const id of ['hosts-toggle', 'hosts-main', 'hosts-pause', 'hosts-warn', 'hosts-cache',
  'hosts-bypass', 'hosts-block', 'hosts-sources', 'hosts-update', 'prompt-msg',
  'prompt-action', 'prompt-container', 'wifi-toggle', 'wifi-main', 'wifi-body',
  'wifi-dns', 'wifi-dns-toggle', 'wifi-suggest', 'wifi-list']) elements[id] = element();
const calls = [], toasts = [], translations = new Set(), snapshots = {};
Object.defineProperty(elements['prompt-msg'], 'textContent', {
  get: () => toasts[toasts.length - 1] || '', set: value => toasts.push(value)
});
let commandResult, stateResult, editor;
const sandbox = {
  console, LANG: 'ru', EN: {},
  $: id => elements[id],
  setTimeout: () => 0, clearTimeout: () => {},
  fmtCount: value => String(value),
  b64: value => Buffer.from(value, 'utf8').toString('base64'),
  snapGet: key => snapshots[key], snapSet: (key, value) => { snapshots[key] = value; },
  snapLock: () => {},
  ctlx: async (args, timeout) => {
    calls.push({ args: Array.from(args), timeout });
    if (args[0] !== 'hosts-state') throw new Error(`Unexpected read: ${args}`);
    return stateResult || { code: 0, out: sandbox.response, err: '' };
  },
  withBusy: async (args, timeout) => {
    calls.push({ args: Array.from(args), timeout });
    return commandResult;
  },
  mdConfirm: async () => true,
  openEditorWith: options => { editor = options; },
  S: { running: false, home_wifi: 0, vpn_pause: 0, dns_available: 0, dns_home_pause: 0 },
  homeList: [], currentSsid: ''
};
vm.createContext(sandbox);
const run = source => vm.runInContext(source, sandbox);
run(read('webroot/js/i18n-en.js'));
for (const name of ['esc', 'jsArg', 'icon', 'errText']) {
  const match = coreCode.match(new RegExp(`^const ${name} = .+$`, 'm'));
  if (!match) throw new Error(`Helper not found: ${name}`);
  run(match[0]);
}
run(fn(coreCode, 't'));
const translate = sandbox.t;
sandbox.t = (key, ...args) => { if (/[А-Яа-яЁё]/.test(key)) translations.add(key); return translate(key, ...args); };
run(fn(coreCode, 'setHTML'));
run('let snackAction = null;\n' + fn(coreCode, 'toast'));
run(fn(settingsCode, 'settingsRow'));
run(fn(settingsCode, 'renderWifi'));
run(fn(read('webroot/js/status.js'), 'banner'));
run(hostsCode);

const defaults = { enabled: '1', mounted: '1', pause_home: '0', pause_vpn: '0', paused: '',
  error: '', conflicts: '', differs: '0', cache_apps: '', cache_resolver: '',
  bypass: '1', blocked: '2', block_custom: '1' };
const state = (status = {}, extra = '') => '#status\n' + Object.entries({ ...defaults, ...status })
  .filter(([, value]) => value !== undefined).map(([key, value]) => `${key}=${value}`).join('\n') + '\n' + extra;
function render(status = {}, extra = '') {
  sandbox.response = state(status, extra);
  run('hostsSt = parseHostsState(response); hostsLoaded = true; renderHosts();');
}
function reset() {
  calls.length = 0; toasts.length = 0;
  commandResult = { code: 0, out: 'OK', err: '' }; stateResult = null;
}
const markup = id => elements[id].innerHTML;
const warnings = () => markup('hosts-warn');
const lastToast = () => toasts[toasts.length - 1];
const pauseInput = kind => (markup('hosts-pause').match(/<input\b[^>]*>/g) || [])
  .find(tag => tag.includes(`setHostsPause('${kind}',`)) || '';
const checked = kind => / checked(?:\s|>)/.test(pauseInput(kind));
const decodeAttr = value => value.replace(/&quot;/g, '"').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&amp;/g, '&');
const hostsSection = html.match(/<section[^>]*data-page="hosts"[^>]*>([\s\S]*?)<\/section>/)[1];
const wifiSection = html.match(/<section[^>]*data-page="wifi"[^>]*>([\s\S]*?)<\/section>/)[1];

async function main() {
  reset();
  sect('state contract and independent controls');
  const parsed = sandbox.parseHostsState(state({ pause_home: '1', pause_vpn: '1', paused: 'vpn',
    mounted: '0', error: 'mount failed: path=a=b', cache_apps: 'ok', cache_resolver: 'unsupported' },
  '#preset example\nNAME=Example\nblock=1\n#url\nurl=https://example.test/hosts?a=b\ncount=5\n'));
  eq('vpn', parsed.status.paused, 'actual pause reason is parsed');
  eq('mount failed: path=a=b', parsed.status.error, 'backend error preserves embedded equals');
  eq('unsupported', parsed.status.cache_resolver, 'cache outcome is preserved');
  eq('Example', parsed.presets[0].name, 'existing preset records still parse');
  eq('https://example.test/hosts?a=b', parsed.urls[0].url, 'existing URL records still parse');
  render({ enabled: '0', mounted: '0', pause_home: undefined, pause_vpn: undefined });
  eq(false, checked('home'), 'missing home option defaults off');
  eq(false, checked('vpn'), 'missing VPN option defaults off');
  for (const kind of ['home', 'vpn']) {
    truthy(/role="switch"/.test(pauseInput(kind)) && /aria-label="[^"]+"/.test(pauseInput(kind)), `${kind} switch is labelled`);
  }
  truthy(markup('hosts-pause').includes('onclick="navigate(\'wifi\')"'), 'SSID list links to the existing Wi-Fi page');
  truthy(!/disabled|inert/.test(markup('hosts-pause')), 'hosts options remain usable with hosts, nfqws2 and DNS off');
  truthy(!/inert|is-disabled/.test(hostsSection), 'the hosts editor is not disabled with its main switch');

  sect('actual pause reason, errors and conflicts');
  for (const reason of ['vpn', 'home']) {
    render({ mounted: '0', pause_home: '1', pause_vpn: '1', paused: reason });
    truthy(warnings().includes(reason === 'vpn' ? 'на паузе при VPN' : 'на паузе в домашнем Wi‑Fi'), `${reason} actual reason is shown`);
    truthy(!warnings().includes(reason === 'vpn' ? 'на паузе в домашнем Wi‑Fi' : 'на паузе при VPN'), `${reason} is not replaced by the other configured option`);
    truthy(!warnings().includes('danger') && !warnings().includes('не подключён'), `${reason} pause is informational, not a disconnected error`);
    eq(true, elements['hosts-toggle'].checked, `${reason} pause leaves the persistent main switch on`);
    truthy(markup('hosts-bypass').includes("editHostsFile('bypass')"), `${reason} pause still allows editing`);
  }
  render({ pause_home: '1', pause_vpn: '1' });
  eq('', warnings(), 'configured options alone do not imply a current pause');
  render({ mounted: '0', pause_home: '1', pause_vpn: '1' });
  truthy(warnings().includes('banner danger') && warnings().includes('не подключён'), 'unexplained disconnection still warns even with both options on');
  render({ mounted: '0', paused: 'unexpected' });
  truthy(warnings().includes('не подключён'), 'unknown pause values cannot hide a disconnection');
  for (const reason of ['home', 'vpn']) {
    render({ enabled: '0', mounted: '0', paused: reason });
    eq('', warnings(), `switched-off hosts does not show a stale ${reason} pause`);
  }
  const hostile = '<img src=x onerror="boom()"> & mount=a=b';
  for (const status of [{ mounted: '0', paused: 'home' }, { mounted: '1', paused: '' }, { enabled: '0', mounted: '1', paused: 'vpn' }]) {
    render({ ...status, error: hostile, conflicts: hostile });
    truthy(warnings().includes('banner danger') && warnings().includes('banner warn'), 'real errors and module conflicts remain visible');
    truthy(warnings().includes('&lt;img') && warnings().includes('&quot;boom()&quot;') && warnings().includes('&amp;'), 'backend error and conflict text are HTML escaped');
    truthy(!warnings().includes('<img'), 'backend text cannot create HTML nodes');
  }
  render({ differs: '1' });
  truthy(warnings().includes("hostsSync('import')"), 'mounted file differences retain sync actions');
  render({ mounted: '0', paused: 'vpn', differs: '1' });
  truthy(!warnings().includes('hostsSync('), 'paused hosts does not offer importing the restored system hosts');

  sect('last soft-cache attempt, not an all-app guarantee');
  const cacheCases = [
    [{ cache_apps: 'ok', cache_resolver: 'ok' }, false, 'приложения уведомлены', 'стандартный кэш резолвера обновлён'],
    [{ cache_apps: 'failed', cache_resolver: 'ok' }, true, 'не удалось уведомить приложения'],
    [{ cache_apps: 'ok', cache_resolver: 'failed' }, true, 'не удалось обновить кэш резолвера'],
    [{ cache_apps: 'failed', cache_resolver: 'failed' }, true, 'не удалось уведомить приложения', 'не удалось обновить кэш резолвера'],
    [{ cache_apps: 'unsupported', cache_resolver: 'unsupported' }, false, 'уведомление приложений не поддерживается', 'обновление кэша резолвера не поддерживается'],
    [{ cache_apps: 'ok', cache_resolver: 'none' }, false, 'кэш резолвера не обновлялся']
  ];
  for (const [status, failed, ...messages] of cacheCases) {
    render({ mounted: '0', paused: 'home', ...status });
    truthy(messages.every(text => markup('hosts-cache').includes(text)), `cache result: ${JSON.stringify(status)}`);
    eq(failed, markup('hosts-cache').includes('banner warn'), 'only a failed refresh is a warning');
    truthy(!markup('hosts-cache').includes('danger') && !/disabled|inert/.test(markup('hosts-pause')), 'cache capability never fatally disables hosts');
  }
  render({ cache_apps: '__proto__', cache_resolver: '<img src=x>' });
  eq('', markup('hosts-cache'), 'unknown cache values are not interpreted or interpolated');
  render();
  eq('', markup('hosts-cache'), 'no attempt means no success claim');
  truthy(hostsSection.includes('Собственный кэш приложения и открытые соединения могут потребовать перезапуска этого приложения.'), 'cache caveat names app-owned caches and open connections');
  truthy(hostsSection.includes('обход через hosts и блокировка рекламы временно не действуют'), 'pause explains that both hosts parts stop applying');
  truthy(hostsSection.includes('Списки сохраняются и доступны для правки'), 'pause explains list preservation and editing');

  sect('backend text in existing hosts rows stays escaped');
  const dir = '/data/hosts/\'"/><img src=x>';
  render({ dir, bypass_preset: 'example' }, `#preset example\nname=${hostile}\nblock=1\nenabled=1\n#url\nurl=https://example.test/${hostile}\n`);
  for (const id of ['hosts-bypass', 'hosts-block', 'hosts-sources']) {
    truthy(!markup(id).includes('<img') && markup(id).includes('&lt;img'), `${id} escapes backend display text`);
  }
  let sharedPath;
  sandbox.shareFileMenu = (_el, value) => { sharedPath = value; };
  const shareHandler = [...markup('hosts-bypass').matchAll(/onclick="([^"]*)"/g)].find(m => m[1].startsWith('shareFileMenu'))[1];
  run(decodeAttr(shareHandler));
  eq(dir + '/bypass.txt', sharedPath, 'file-share handler preserves hostile path as one JS argument');

  sect('pause commands and actual state');
  for (const kind of ['home', 'vpn']) for (const on of [true, false]) {
    reset();
    const old = { enabled: '0', mounted: '0', ['pause_' + kind]: on ? '0' : '1' };
    render(old);
    sandbox.response = state({ ...old, ['pause_' + kind]: on ? '1' : '0' });
    const input = { checked: on };
    await sandbox.setHostsPause(kind, on, input);
    eq(['hosts-set-pause', kind, on ? '1' : '0'], calls[0].args, `${kind} ${on} uses the exact ctl contract`);
    eq(120000, calls[0].timeout, 'pause command keeps the hosts operation timeout');
    eq(['hosts-state'], calls[1].args, 'successful command refreshes actual state');
    eq(on, checked(kind), 'refreshed option is rendered');
    eq('Сохранено', lastToast(), 'option success does not claim that hosts was mounted');
  }
  reset();
  render({ mounted: '0', pause_home: '1', pause_vpn: '1', paused: 'vpn' });
  sandbox.response = state({ mounted: '0', pause_home: '1', pause_vpn: '0', paused: 'home' });
  await sandbox.setHostsPause('vpn', false, { checked: false });
  truthy(warnings().includes('на паузе в домашнем Wi‑Fi') && !warnings().includes('не подключён'), 'removing VPN pause still shows the remaining home pause');
  reset();
  await sandbox.setHostsPause('invalid', true, { checked: true });
  eq([], calls, 'an invalid pause kind cannot reach ctl');

  sect('main switch reports actual state');
  for (const [fresh, on, expected] of [
    [{ mounted: '0', paused: 'vpn' }, true, 'Сохранено'],
    [{ mounted: '0', paused: 'home' }, true, 'Сохранено'],
    [{ mounted: '0' }, true, 'Сохранено'],
    [{}, true, 'Свой hosts подключён'],
    [{ enabled: '0', mounted: '0' }, false, 'Возвращён системный hosts']
  ]) {
    reset(); render(); sandbox.response = state(fresh);
    await sandbox.setHostsEnabled(on, { checked: on });
    eq(['hosts-set-enabled', on ? '1' : '0'], calls[0].args, 'main switch contract stays unchanged');
    eq(expected, lastToast(), 'main switch success matches refreshed state');
  }

  sect('failed toggles reconcile persisted desired state');
  for (const kind of ['enabled', 'home', 'vpn']) for (const on of [true, false]) {
    const main = kind === 'enabled', key = main ? 'enabled' : 'pause_' + kind;
    for (const [name, persists, readFails, commandFails] of [
      ['persisted apply failure', true, false, true],
      ['rejected command', false, false, true],
      ['apply and state fetch fail', true, true, true],
      ['successful command, state fetch fails', true, true, false]
    ]) {
      reset();
      const label = `${kind} ${on}: ${name}`;
      const before = { enabled: '1', mounted: (main ? !on : on) ? '1' : '0',
        paused: main || on ? '' : kind, [key]: on ? '0' : '1' };
      render(before);
      // Applying can fail after persisting the flag, leaving the old mount intact.
      sandbox.response = state({ ...before, [key]: persists ? (on ? '1' : '0') : before[key],
        error: commandFails && persists ? hostile : '' });
      if (commandFails) commandResult = { code: 1, out: '', err: hostile };
      if (readFails) stateResult = { code: 1, out: '', err: 'state read failed' };
      const input = main ? elements['hosts-toggle'] : { checked: on };
      input.checked = on;
      if (main) await sandbox.setHostsEnabled(on, input);
      else await sandbox.setHostsPause(kind, on, input);
      const expected = persists && !readFails ? on : !on;
      eq(expected, input.checked, `${label}: checkbox follows fresh state or last-known fallback`);
      eq(expected, main ? elements['hosts-toggle'].checked : checked(kind), `${label}: rendered choice is accurate`);
      eq(expected ? '1' : '0', run(`hostsSt.status[${JSON.stringify(key)}]`), `${label}: stored UI state is accurate`);
      eq([main ? ['hosts-set-enabled', on ? '1' : '0'] : ['hosts-set-pause', kind, on ? '1' : '0'], ['hosts-state']],
        calls.map(call => call.args), `${label}: status is fetched even after a command error`);
      eq((readFails ? ['state read failed'] : []).concat(commandFails ? [hostile] : []), toasts,
        `${label}: only error toasts, never a false success`);
      if (persists && !readFails) truthy(warnings().includes('banner danger') && warnings().includes('&lt;img') && !warnings().includes('<img'),
        `${label}: refreshed backend error is visible and escaped`);
    }
  }
  eq('', elements['prompt-msg'].innerHTML, 'real toast helper writes backend errors only as textContent');

  sect('editor and sync saved versus applied');
  const states = [
    ['disabled', { enabled: '0', mounted: '0' }, false],
    ['home pause', { mounted: '0', paused: 'home' }, false],
    ['VPN pause', { mounted: '0', paused: 'vpn' }, false],
    ['unexpected unmount', { mounted: '0' }, false],
    ['mounted', {}, true],
    ['inconsistent pause marker', { paused: 'vpn' }, false]
  ];
  for (const key of ['bypass', 'block_custom', 'whitelist', 'sources']) {
    for (const [label, status, applied] of states) {
      reset(); render(status);
      sandbox.editHostsFile(key);
      eq(['hosts-get', key], Array.from(editor.load), `${key} remains editable: ${label}`);
      eq('', await editor.onSave('example.test  \n\n'), 'successful save returns no editor error');
      eq(['hosts-save-b64', key, Buffer.from('example.test\n').toString('base64')], calls[0].args, 'save uses base64 and one trailing newline');
      eq(applied && key !== 'sources' ? 'Сохранено и применено' : 'Сохранено', lastToast(), `${key} save toast: ${label}`);
    }
    truthy(!editor.hint.includes('Сохранение применяется сразу'), `${key} hint makes no unconditional immediate-apply promise`);
    if (key !== 'sources') truthy(editor.hint.includes('подключён и не на паузе'), `${key} hint explains when edits apply`);
  }
  for (const [before, after, expected] of [
    [{}, { mounted: '0', paused: 'vpn' }, 'Сохранено'],
    [{}, { enabled: '0', mounted: '0' }, 'Сохранено'],
    [{ mounted: '0', paused: 'home' }, {}, 'Сохранено и применено']
  ]) {
    reset(); render(before); sandbox.editHostsFile('bypass'); sandbox.response = state(after);
    await editor.onSave('1.2.3.4 example.test');
    eq(expected, lastToast(), 'toast follows post-save state, not the state when the editor opened');
  }
  reset(); render(); sandbox.editHostsFile('bypass');
  commandResult = { code: 1, out: '', err: hostile };
  eq(hostile, await editor.onSave('example.test'), 'save failure returns backend error to editor');
  eq([], toasts, 'failed save never shows a success toast');
  reset(); render(); sandbox.editHostsFile('bypass');
  stateResult = { code: 1, out: state(), err: 'state read failed' };
  eq('', await editor.onSave('example.test'), 'saved file remains saved when status refresh fails');
  eq('state read failed', lastToast(), 'failed status read is not masked by an applied toast');
  for (const [label, status, applied] of states) {
    reset(); render(status); await sandbox.hostsSync('apply');
    eq(applied ? 'Сохранено и применено' : 'Сохранено', lastToast(), `sync apply toast: ${label}`);
  }
  reset(); render(); await sandbox.hostsSync('import');
  eq('Файлы частей обновлены', lastToast(), 'import keeps its part-files-updated toast');
  reset(); render(); commandResult = { code: 1, out: '', err: hostile };
  await sandbox.hostsSync('apply');
  eq(hostile, lastToast(), 'sync failure is not masked by refreshed mounted status');

  sect('shared home SSID list is independent of nfqws2 activation');
  sandbox.homeList = ['Existing']; sandbox.currentSsid = 'New & <SSID>';
  sandbox.S = { home_wifi: 0, dns_available: 1, dns_home_pause: 1 };
  sandbox.renderWifi();
  eq(false, elements['wifi-body'].inert, 'HOME_WIFI=0 does not lock the shared SSID list');
  truthy(!elements['wifi-body'].classList.contains('is-disabled'), 'HOME_WIFI=0 does not gray out list editing');
  truthy(markup('wifi-list').includes('removeHome('), 'saved SSIDs remain editable');
  truthy(markup('wifi-suggest').includes('addHome(') && markup('wifi-suggest').includes('&lt;SSID&gt;'), 'new SSID suggestion works safely while nfqws2 pausing is off');
  eq(true, elements['wifi-dns'].inert, 'only the dependent DNS-home row remains inactive');
  eq(true, elements['wifi-dns-toggle'].disabled, 'DNS-home switch keeps the HOME_WIFI requirement');
  sandbox.S.home_wifi = 1; sandbox.renderWifi();
  eq(false, elements['wifi-dns-toggle'].disabled, 'DNS-home switch is available when HOME_WIFI is on');
  sandbox.S.home_wifi = 0; sandbox.S.dns_available = 0; sandbox.renderWifi();
  eq(true, elements['wifi-dns'].hidden, 'regular module still hides unavailable DNS profiles');
  eq(false, elements['wifi-body'].inert, 'hosts list editing needs neither nfqws2 nor DNS enabled');

  sect('English translations and static markup');
  truthy(hostsSection.includes('id="hosts-pause"') && hostsSection.includes('id="hosts-cache"'), 'hosts markup contains the new render targets');
  for (const match of (hostsSection + wifiSection).matchAll(/data-t>([^<]+)</g)) {
    const key = match[1].trim();
    if (/[А-Яа-яЁё]/.test(key)) translations.add(key);
  }
  translations.add('Не удалось изменить паузу hosts');
  const missing = [...translations].filter(key => !sandbox.EN[key]);
  eq([], missing, 'all exercised hosts/Wi-Fi text and new static strings have English translations');
  sandbox.LANG = 'en';
  render({ mounted: '0', paused: 'vpn', pause_home: '1', pause_vpn: '1', cache_apps: 'ok', cache_resolver: 'unsupported' });
  const english = ['hosts-pause', 'hosts-warn', 'hosts-cache', 'hosts-bypass', 'hosts-block', 'hosts-sources'].map(markup).join('');
  truthy(!/[А-Яа-яЁё]/.test(english), 'English hosts UI contains no untranslated Russian text');
  truthy(english.includes('apps notified') && english.includes('resolver cache refresh unsupported'), 'English cache text distinguishes notification and unsupported refresh');
  const caveat = sandbox.EN['Модуль пытается обновить стандартные DNS-кэши и уведомить приложения. Собственный кэш приложения и открытые соединения могут потребовать перезапуска этого приложения.'];
  truthy(caveat.includes('standard DNS caches') && caveat.includes("app's own cache") && caveat.includes('open connections') && caveat.includes('restarting that app'), 'English caveat makes no all-app immediate-refresh promise');
}

main().catch(error => fail(error.stack || String(error))).then(() => {
  process.stdout.write('\n----------------------------------------\n');
  if (!failures.length) process.stdout.write(`PASS  ${pass} checks\n`);
  else {
    process.stdout.write(`FAIL  ${failures.length} of ${pass + failures.length} checks failed\n`);
    for (const failure of failures) process.stdout.write(`   - ${failure}\n`);
  }
  process.exitCode = failures.length ? 1 : 0;
});
