#!/usr/bin/env node
/**
 * test_apps.js — Unit tests for App Filter (System / User / Selected / All):
 * - isAppSystem classification (boolean flag, truthy values, package prefixes)
 * - setAppTypeFilter chip toggle and accessibility attributes
 * - drawPk filtering logic for all / user / system / selected
 * - Badge rendering on system apps
 * - i18n dictionary and static markup invariants
 */
'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const REPO = path.resolve(__dirname, '..', '..');
const APPS_JS = path.join(REPO, 'webroot', 'js', 'apps.js');
const CORE_JS = path.join(REPO, 'webroot', 'js', 'core.js');
const I18N_JS = path.join(REPO, 'webroot', 'js', 'i18n-en.js');
const INDEX_HTML = path.join(REPO, 'webroot', 'index.html');

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

// Load apps.js and core.js in sandbox
const chips = {};
const mockElements = {
  'pk-filter-chips': {
    querySelectorAll: (sel) => {
      if (sel === '.chip') return Object.values(chips);
      return [];
    }
  },
  'pf': { value: '' },
  'pk-count': { textContent: '' },
  'pk': {
    innerHTML: '',
    _html: null,
    querySelectorAll: () => []
  },
  'apps-info': { textContent: '' },
  'amode-list': { innerHTML: '' },
  'pk-chip-work': { style: { display: 'none' } }
};

['all', 'user', 'system', 'work', 'selected'].forEach(type => {
  const classes = new Set(['chip', 'filter', 'state']);
  if (type === 'all') classes.add('selected');
  chips[type] = {
    getAttribute: attr => attr === 'data-type' ? type : null,
    setAttribute: (attr, val) => { chips[type]['_' + attr] = val; },
    classList: {
      contains: c => classes.has(c),
      toggle: (c, on) => { if (on) classes.add(c); else classes.delete(c); }
    },
    _role: 'button',
    '_aria-pressed': type === 'all' ? 'true' : 'false'
  };
});

let renderedHtml = '';
const sandbox = {
  console,
  setTimeout: (fn, ms) => fn(),
  clearTimeout: () => {},
  t: str => str,
  esc: str => String(str).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;'),
  icon: (name, sz) => `<svg class="${sz}"><use href="#i-${name}"/></svg>`,
  setHTML: (id, html) => {
    if (id === 'pk') renderedHtml = html;
  },
  $: id => mockElements[id] || null,
  ctlx: async (args) => {
    if (args && args[0] === 'get-list' && args[1] === 'apps') {
      return { code: 0, out: 'org.telegram.messenger\n' };
    }
    return { code: 0, out: '' };
  },
  toast: () => {},
  withBusy: async (cmd) => ({ code: 0, out: '' }),
  stat: async () => {},
  S: { app_mode: 'off', counts: { apps: 0 } },
  pkgs: []
};

vm.createContext(sandbox);
const appsCode = fs.readFileSync(APPS_JS, 'utf8');
vm.runInContext(appsCode, sandbox);

// ── isAppSystem classification ───────────────────────────────────────────────
sect('isAppSystem classification');

truthy(sandbox.isAppSystem({ pkg: 'com.android.settings', name: 'Настройки', system: true }),
  'item with system: true is system');
truthy(!sandbox.isAppSystem({ pkg: 'org.telegram.messenger', name: 'Telegram', system: false }),
  'item with system: false is user');
truthy(sandbox.isAppSystem({ pkg: 'com.custom.sys', system: 1 }),
  'item with system: 1 is system');
truthy(!sandbox.isAppSystem({ pkg: 'com.custom.user', system: 0 }),
  'item with system: 0 is user');
truthy(sandbox.isAppSystem({ pkg: 'com.custom.sys', system: 'true' }),
  'item with system: "true" is system');

// Fallback prefixes when system flag is null or omitted
truthy(sandbox.isAppSystem({ pkg: 'com.android.vending' }),
  'fallback com.android. prefix is system');
truthy(sandbox.isAppSystem({ pkg: 'android' }),
  'fallback android package is system');
truthy(sandbox.isAppSystem({ pkg: 'com.google.android.packageinstaller' }),
  'fallback com.google.android.packageinstaller is system');
truthy(sandbox.isAppSystem({ pkg: 'com.google.android.gms' }),
  'fallback com.google.android.gms is system');
truthy(!sandbox.isAppSystem({ pkg: 'com.aurora.store' }),
  'fallback non-system package is not system');
truthy(!sandbox.isAppSystem({ pkg: 'ru.yandex.searchplugin' }),
  'fallback yandex package is not system');

// Plain string inputs
truthy(sandbox.isAppSystem('com.android.shell'), 'string com.android.shell is system');
truthy(sandbox.isAppSystem('android'), 'string android is system');
truthy(sandbox.isAppSystem('com.google.android.gms'), 'string com.google.android.gms is system');
truthy(!sandbox.isAppSystem('org.mozilla.firefox'), 'string org.mozilla.firefox is not system');

// ── Multi-user / Shelter classification ─────────────────────────────────────
sect('Multi-user / Shelter (Option B) classification');

truthy(sandbox.isAppWork({ pkg: 'com.slack', userId: 10, isWork: true }),
  'item with isWork: true is work profile');
truthy(sandbox.isAppWork({ pkg: 'com.slack', userId: 10 }),
  'item with userId > 0 is work profile');
truthy(!sandbox.isAppWork({ pkg: 'com.slack', userId: 0, isWork: false }),
  'item with userId: 0 is not work profile');
truthy(!sandbox.isAppWork({ pkg: 'com.slack', userId: 11, isWork: false }),
  'a guest or second user is not a work profile');
truthy(!sandbox.isAppWork({ pkg: 'com.slack', userId: 12, isWork: 'false' }),
  'the generator isWork flag wins over the bare user id');
truthy(!sandbox.isAppWork({ pkg: 'com.slack' }),
  'item without userId is not work profile');
truthy(!sandbox.isAppWork('com.slack'),
  'string is not work profile');

eq('10:org.telegram.messenger', sandbox.appKey({ pkg: 'org.telegram.messenger', userId: 10 }),
  'appKey generates prefixed key for secondary profile');
// a bare package in apps.list means «every profile» to resolve_app_uids(), so
// the personal copy must be named explicitly too, otherwise selecting it also
// enables the work copy
eq('0:org.telegram.messenger', sandbox.appKey({ pkg: 'org.telegram.messenger', userId: 0 }),
  'appKey names the personal profile explicitly');
eq('org.telegram.messenger', sandbox.appKey('org.telegram.messenger'),
  'appKey preserves plain string');

const mockSet = new Set(['org.telegram.messenger', '10:com.slack', '0:com.custom.app']);
truthy(sandbox.isAppSelected(mockSet, { pkg: 'org.telegram.messenger', userId: 0 }),
  'global package selection matches user 0');
truthy(sandbox.isAppSelected(mockSet, { pkg: 'org.telegram.messenger', userId: 10 }),
  'global package selection matches user 10 (Shelter)');
truthy(sandbox.isAppSelected(mockSet, { pkg: 'com.slack', userId: 10 }),
  'prefixed package matches targeted user 10');
truthy(!sandbox.isAppSelected(mockSet, { pkg: 'com.slack', userId: 0 }),
  'prefixed package (10:) does not match user 0');
truthy(sandbox.isAppSelected(mockSet, { pkg: 'com.custom.app', userId: 0 }),
  'prefixed package (0:) matches user 0');

// ── setAppTypeFilter & chips ────────────────────────────────────────────────
sect('setAppTypeFilter & chip toggling');

sandbox.setAppTypeFilter('user');
eq('user', vm.runInContext('appTypeFilter', sandbox), 'filter is updated to "user"');
truthy(chips['user'].classList.contains('selected'), 'user chip is selected');
eq('true', chips['user']['_aria-pressed'], 'user chip aria-pressed is true');
truthy(!chips['all'].classList.contains('selected'), 'all chip is unselected');
eq('false', chips['all']['_aria-pressed'], 'all chip aria-pressed is false');

sandbox.setAppTypeFilter('system');
eq('system', vm.runInContext('appTypeFilter', sandbox), 'filter is updated to "system"');
truthy(chips['system'].classList.contains('selected'), 'system chip is selected');
eq('true', chips['system']['_aria-pressed'], 'system chip aria-pressed is true');
truthy(!chips['user'].classList.contains('selected'), 'user chip is unselected');

sandbox.setAppTypeFilter('selected');
eq('selected', vm.runInContext('appTypeFilter', sandbox), 'filter is updated to "selected"');
truthy(chips['selected'].classList.contains('selected'), 'selected chip is selected');

sandbox.setAppTypeFilter('all');
eq('all', vm.runInContext('appTypeFilter', sandbox), 'filter is restored to "all"');
truthy(chips['all'].classList.contains('selected'), 'all chip is selected');
eq('true', chips['all']['_aria-pressed'], 'all chip aria-pressed is true');

// ── drawPk filtering logic ──────────────────────────────────────────────────
sect('drawPk filtering');

(async () => {
  sandbox.pkgs = [
    { pkg: 'com.android.settings', name: 'Настройки', system: true },
    { pkg: 'com.android.systemui', name: 'Интерфейс системы', system: true },
    { pkg: 'org.telegram.messenger', name: 'Telegram', system: false },
    { pkg: 'com.whatsapp', name: 'WhatsApp', system: false }
  ];

  // Set mock selected apps: telegram is selected
  vm.runInContext("appsCache = new Set(['org.telegram.messenger'])", sandbox);

  // 1. All filter
  sandbox.setAppTypeFilter('all');
  await sandbox.drawPk(false);
  truthy(renderedHtml.includes('com.android.settings'), 'all includes settings');
  truthy(renderedHtml.includes('org.telegram.messenger'), 'all includes telegram');

  // 2. User filter
  sandbox.setAppTypeFilter('user');
  await sandbox.drawPk(false);
  truthy(!renderedHtml.includes('com.android.settings'), 'user excludes settings');
  truthy(!renderedHtml.includes('com.android.systemui'), 'user excludes systemui');
  truthy(renderedHtml.includes('org.telegram.messenger'), 'user includes telegram');
  truthy(renderedHtml.includes('com.whatsapp'), 'user includes whatsapp');

  // 3. System filter
  sandbox.setAppTypeFilter('system');
  await sandbox.drawPk(false);
  truthy(renderedHtml.includes('com.android.settings'), 'system includes settings');
  truthy(renderedHtml.includes('com.android.systemui'), 'system includes systemui');
  truthy(!renderedHtml.includes('org.telegram.messenger'), 'system excludes telegram');
  truthy(!renderedHtml.includes('com.whatsapp'), 'system excludes whatsapp');
  truthy(renderedHtml.includes('· Системное'), 'system rows display system badge');

  // 4. Selected filter
  sandbox.setAppTypeFilter('selected');
  await sandbox.drawPk(false);
  truthy(renderedHtml.includes('org.telegram.messenger'), 'selected includes telegram');
  truthy(!renderedHtml.includes('com.whatsapp'), 'selected excludes unselected whatsapp');
  truthy(!renderedHtml.includes('com.android.settings'), 'selected excludes unselected settings');

  // 5. Work Profile filter & badge rendering
  sandbox.pkgs.push({
    pkg: 'org.telegram.messenger',
    name: 'Telegram',
    system: false,
    userId: 10,
    userName: 'Shelter',
    isWork: true
  });
  sandbox.setAppTypeFilter('work');
  await sandbox.drawPk(false);
  truthy(renderedHtml.includes('· Shelter'), 'work profile app displays work badge with profile name');
  truthy(renderedHtml.includes('data-key="10:org.telegram.messenger"'), 'work profile app outputs 10:pkg data-key');
  truthy(!renderedHtml.includes('com.whatsapp'), 'work filter excludes main profile apps');

  // ── i18n and markup invariants ──────────────────────────────────────────────
  sect('i18n & markup invariants');

  const html = fs.readFileSync(INDEX_HTML, 'utf8');
  truthy(html.includes('id="pk-filter-chips"'), 'markup defines pk-filter-chips wrapper');
  truthy(html.includes('data-type="all"'), 'markup defines "all" chip');
  truthy(html.includes('data-type="user"'), 'markup defines "user" chip');
  truthy(html.includes('data-type="system"'), 'markup defines "system" chip');
  truthy(html.includes('data-type="work"'), 'markup defines "work" chip');
  truthy(html.includes('data-type="selected"'), 'markup defines "selected" chip');
  truthy(html.includes('data-ta="aria-label"'), 'chips wrapper has data-ta="aria-label"');

  const i18nSrc = fs.readFileSync(I18N_JS, 'utf8');
  const enMatch = i18nSrc.match(/EN\s*=\s*(\{[\s\S]*?\});/);
  truthy(enMatch, 'EN dictionary found in i18n-en.js');
  const EN = eval(`(${enMatch[1]})`);

  eq('App filter', EN['Фильтр приложений'], 'Фильтр приложений translated to App filter');
  eq('User', EN['Пользовательские приложения'], 'Пользовательские приложения translated to User');
  eq('System', EN['Системные'], 'Системные translated to System');
  eq('Work', EN['Рабочие'], 'Рабочие translated to Work');
  eq('Work profile', EN['Рабочий профиль'], 'Рабочий профиль translated to Work profile');
  eq('Selected', EN['Выбранные'], 'Выбранные translated to Selected');
  eq('System', EN['Системное'], 'Системное translated to System');
  eq('Custom', EN['Пользовательские'], 'Strategy group Пользовательские preserved as Custom');

  // ── summary ─────────────────────────────────────────────────────────────────
  process.stdout.write('\n----------------------------------------\n');
  if (failures.length === 0) {
    process.stdout.write(`PASS  ${pass} checks\n`);
    process.exit(0);
  }
  process.stdout.write(`FAIL  ${failures.length} of ${pass + failures.length} checks failed\n`);
  for (const f of failures) process.stdout.write(`   - ${f}\n`);
  process.exit(1);
})();
