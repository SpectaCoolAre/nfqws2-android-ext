#!/usr/bin/env node
/**
 * test_export.js — Unit tests for export & backup via system file manager:
 * - b64toBlob and blobToB64 binary roundtrip
 * - exportBlobFile multi-tier dispatch (Web Share, File System Picker, Download, Intent)
 * - Markup invariants (backupFile input, exportLogs trigger)
 * - i18n dictionary completeness for export/backup strings
 */
'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const REPO = path.resolve(__dirname, '..', '..');
const CORE_JS = path.join(REPO, 'webroot', 'js', 'core.js');
const SETTINGS_JS = path.join(REPO, 'webroot', 'js', 'settings.js');
const LOGS_JS = path.join(REPO, 'webroot', 'js', 'logs.js');
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

// Setup sandbox environment
const sharedIntents = [];
let downloadedFiles = [];

class MockBlob {
  constructor(chunks, opts) {
    this.chunks = chunks || [];
    this.type = (opts && opts.type) || '';
    let size = 0;
    for (const c of this.chunks) size += c.length || 0;
    this.size = size;
  }
}

class MockFile extends MockBlob {
  constructor(chunks, name, opts) {
    super(chunks, opts);
    this.name = name;
  }
}

class MockFileReader {
  readAsDataURL(blob) {
    const bytes = [];
    for (const c of blob.chunks) {
      for (let i = 0; i < c.length; i++) bytes.push(c[i]);
    }
    const b64 = Buffer.from(bytes).toString('base64');
    this.result = `data:${blob.type || 'application/octet-stream'};base64,${b64}`;
    if (this.onload) this.onload();
  }
}

let mockShareCalled = false;
let mockPickerCalled = false;

const sandbox = {
  console,
  addEventListener: () => {},
  removeEventListener: () => {},
  window: { addEventListener: () => {}, removeEventListener: () => {} },
  history: { state: null, pushState: () => {}, replaceState: () => {} },
  innerHeight: 800,
  innerWidth: 360,
  Blob: MockBlob,
  File: MockFile,
  FileReader: MockFileReader,
  Uint8Array,
  atob: s => Buffer.from(s, 'base64').toString('binary'),
  btoa: s => Buffer.from(s, 'binary').toString('base64'),
  escape: s => encodeURIComponent(s),
  unescape: s => decodeURIComponent(s),
  encodeURIComponent,
  decodeURIComponent,
  URL: {
    createObjectURL: blob => 'blob://mock-url',
    revokeObjectURL: () => {}
  },
  document: {
    addEventListener: () => {},
    removeEventListener: () => {},
    getElementById: id => ({
      onclick: null,
      addEventListener: () => {},
      classList: { add: () => {}, remove: () => {}, toggle: () => {} }
    }),
    querySelectorAll: () => [],
    createElement: tag => {
      if (tag === 'a') {
        const link = {
          href: '',
          download: '',
          click: () => { downloadedFiles.push({ href: link.href, download: link.download }); },
          remove: () => {}
        };
        return link;
      }
      return {};
    },
    body: { appendChild: () => {}, removeChild: () => {} }
  },
  navigator: {
    canShare: opts => opts && opts.files && opts.files.length > 0,
    share: async opts => { mockShareCalled = true; }
  },
  sh: async cmd => { sharedIntents.push(cmd); return { code: 0, out: '' }; },
  toast: () => {},
  t: str => str,
  setTimeout: (fn, ms) => setTimeout(fn, 0),
  clearTimeout: id => clearTimeout(id)
};

vm.createContext(sandbox);
const coreCode = fs.readFileSync(CORE_JS, 'utf8');
vm.runInContext(coreCode, sandbox);

// ── b64toBlob and blobToB64 roundtrip ─────────────────────────────────────────
sect('b64toBlob & blobToB64 roundtrip');

const sampleStr = 'nfqws2-android-backup-test-data-12345';
const sampleB64 = Buffer.from(sampleStr, 'utf8').toString('base64');

const blob = sandbox.b64toBlob(sampleB64, 'application/x-tar');
truthy(blob instanceof MockBlob, 'b64toBlob returns Blob instance');
eq('application/x-tar', blob.type, 'Blob MIME type is application/x-tar');
eq(sampleStr.length, blob.size, 'Blob size matches original byte length');

(async () => {
  const roundtripB64 = await sandbox.blobToB64(blob);
  eq(sampleB64, roundtripB64, 'blobToB64 restores exact original base64');

  // ── exportBlobFile multi-tier dispatch ──────────────────────────────────────
  sect('exportBlobFile multi-tier dispatch');

  mockShareCalled = false;
  await sandbox.exportBlobFile(blob, 'backup.tar', 'application/x-tar', '/sdcard/Download/backup.tar');
  truthy(mockShareCalled, 'exportBlobFile triggers navigator.share when available');

  // Test fallback to octet-stream when application/x-tar is rejected by canShare
  mockShareCalled = false;
  let sharedFiles = [];
  const canShare0 = sandbox.navigator.canShare, share0 = sandbox.navigator.share;
  sandbox.navigator.canShare = opts => opts && opts.files && opts.files.every(f => f.type !== 'application/x-tar');
  sandbox.navigator.share = async opts => { mockShareCalled = true; sharedFiles = opts.files; };
  await sandbox.exportBlobFile(blob, 'backup.tar', 'application/x-tar', '/sdcard/Download/backup.tar');
  truthy(mockShareCalled, 'exportBlobFile falls back to whitelisted MIME type for navigator.share');
  eq('application/octet-stream', sharedFiles[0].type, 'shared file uses application/octet-stream when x-tar is rejected');
  sandbox.navigator.canShare = canShare0; sandbox.navigator.share = share0;

  // Test fallback when navigator.canShare is disabled
  sandbox.navigator.canShare = null;
  downloadedFiles = [];
  sandbox.window = {
    showSaveFilePicker: async () => {
      mockPickerCalled = true;
      return {
        createWritable: async () => ({
          write: async () => {},
          close: async () => {}
        })
      };
    }
  };
  await sandbox.exportBlobFile(blob, 'backup.tar', 'application/x-tar');
  truthy(mockPickerCalled, 'exportBlobFile uses showSaveFilePicker when share is unavailable');

  // Test fallback to <a download>
  delete sandbox.window.showSaveFilePicker;
  downloadedFiles = [];
  sandbox.window.ksu = {
    exec: (cmd, arg2, arg3) => {
      sharedIntents.push(cmd);
      const cbId = typeof arg3 === 'string' ? arg3 : (typeof arg2 === 'string' ? arg2 : null);
      if (cbId && sandbox[cbId]) sandbox[cbId](0, '', '');
    }
  };
  await sandbox.exportBlobFile(blob, 'backup.tar', 'application/x-tar', '/sdcard/Download/backup.tar');
  truthy(downloadedFiles.length > 0, 'exportBlobFile falls back to <a download>');
  eq('backup.tar', downloadedFiles[0].download, 'download attribute matches requested filename');
  const sendCmd = sharedIntents.find(cmd => cmd.includes('am start -a android.intent.action.SEND') && cmd.includes('backup.tar'));
  truthy(sendCmd, 'exportBlobFile executes am start ACTION_SEND intent in ksu environment');
  truthy(sendCmd && sendCmd.includes("-t 'application/x-tar'"), 'intent carries the real type of the archive');
  truthy(sendCmd && sendCmd.includes('-d "$u"'), 'and the link as intent data: am does not move EXTRA_STREAM to ClipData, so only this gives the receiving app (Telegram) read access');
  truthy(sendCmd && sendCmd.includes('-f 0x10000001'), 'intent passes NEW_TASK and GRANT_READ_URI_PERMISSION flags');
  truthy(sendCmd && sendCmd.includes('--user 0'), 'intent targets primary user');
  truthy(sendCmd && !sendCmd.includes('file:///sdcard/Download/backup.tar"'), 'no bare file:// URI is shared');

  // ── markup invariants ───────────────────────────────────────────────────────
  sect('markup invariants');

  const html = fs.readFileSync(INDEX_HTML, 'utf8');
  truthy(html.includes('id="backupFile"'), 'index.html contains backupFile file input');
  truthy(html.includes('accept=".tar,application/x-tar"'), 'backupFile accepts .tar and application/x-tar');
  truthy(html.includes('restoreBackupFromFile(this.files[0])'), 'backupFile invokes restoreBackupFromFile onchange');
  truthy(html.includes('onclick="$(\'backupFile\').click()"'), 'backup-sheet contains button to trigger backupFile');
  truthy(html.includes('onclick="exportLogs()"'), 'logs page contains exportLogs button');
  truthy(html.includes('>Экспорт логов</span>'), 'export button is titled "Экспорт логов"');

  // ── i18n completeness ───────────────────────────────────────────────────────
  sect('i18n completeness');

  const i18nSrc = fs.readFileSync(I18N_JS, 'utf8');
  const enMatch = i18nSrc.match(/EN\s*=\s*(\{[\s\S]*?\});/);
  truthy(enMatch, 'EN dictionary found in i18n-en.js');
  const EN = eval(`(${enMatch[1]})`);

  eq('Export logs', EN['Экспорт логов'], 'Экспорт логов translation');
  eq('Pick archive file', EN['Выбрать файл архива'], 'Выбрать файл архива translation');
  eq('Config, lists, strategies and appearance — as a .tar archive',
    EN['Конфиг, списки, стратегии и оформление — в архив .tar'],
    'Конфиг в архив .tar translation');
  eq('Pick a .tar archive or from the list',
    EN['Выбрать архив .tar или из списка'],
    'Выбрать архив .tar или из списка translation');
  eq('Pick a .tar archive via the file manager or from the list below. Current settings, lists and strategies will be replaced.',
    EN['Выберите архив .tar через проводник или сохранённую копию из списка ниже. Текущие настройки, списки и стратегии будут заменены.'],
    'Backup sheet description translation');

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
