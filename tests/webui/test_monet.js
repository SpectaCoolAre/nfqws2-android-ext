#!/usr/bin/env node
// Test suite for Android Material You / Monet palette detection and application.
//
// Tests:
// 1. Color space math: hex <-> RGB <-> CIE Lab, HSL roundtrips, chroma scaling
// 2. M3 Tonal Palette generation (roles):
//    - Light, Dark, and AMOLED modes
//    - Completeness of all 42 required M3 color roles
//    - Contrast & luminance hierarchy (onPrimary vs primary, onSurface vs surface)
//    - AMOLED invariants (background/surface = #000000, container luminance > 0)
// 3. Theme like the system: Android's own role colours (nfqws2-ctl monet-system)
//    - parsing style, seed and per-mode roles
//    - system colours used as they are; AMOLED blackens only background/surface
//    - an own accent replaces them, reset brings them back
//    - without role colours the palette follows the system style (VIBRANT, TONAL_SPOT…)
// 4. Palette application & DOM injection:
//    - CSS custom properties written to #theme-vars
//    - meta[name="theme-color"] sync
//    - HTML data attributes (data-mode, data-amoled, data-containers)

const fs = require('fs');
const path = require('path');
const vm = require('vm');

let pass = 0;
const failures = [];
function ok(msg) { pass++; process.stdout.write(`   ok   ${msg}\n`); }
function fail(msg) { failures.push(msg); process.stdout.write(`   FAIL ${msg}\n`); }
function eq(exp, act, msg) {
  if (exp === act) ok(msg);
  else fail(`${msg} -- expected ${JSON.stringify(exp)}, got ${JSON.stringify(act)}`);
}
function truthy(cond, msg) {
  if (cond) ok(msg);
  else fail(`${msg} -- expected truthy, got ${JSON.stringify(cond)}`);
}
function sect(name) { process.stdout.write(`\n== ${name}\n`); }

const REPO = path.resolve(__dirname, '../..');
const themeSrc = fs.readFileSync(path.join(REPO, 'webroot/js/theme.js'), 'utf8');

// Build a clean sandbox imitating browser environment
const dom = {
  themeVars: { textContent: '' },
  meta: { attrs: {}, setAttribute(k, v) { this.attrs[k] = v; } },
  docEl: { attrs: {}, setAttribute(k, v) { this.attrs[k] = v; }, getPropertyValue() { return ''; } },
  amoledToggle: { checked: false, disabled: false },
  monochromeToggle: { checked: false, disabled: false },
  containersToggle: { checked: true, disabled: false },
  animationsToggle: { checked: false, disabled: false },
  storage: {},
  shMockOutput: '',
};

const store = {
  get(k) { return dom.storage[k] || null; },
  set(k, v) { dom.storage[k] = String(v); },
  del(k) { delete dom.storage[k]; },
};

const sandbox = {
  console,
  document: {
    documentElement: {
      setAttribute: (k, v) => { dom.docEl.attrs[k] = v; },
      getAttribute: (k) => dom.docEl.attrs[k] || null,
    },
    querySelector: (sel) => {
      if (sel === 'meta[name="theme-color"]') return dom.meta;
      return null;
    },
    createElement: () => ({ style: {}, appendChild: () => {}, remove: () => {} }),
    body: { appendChild: () => {} },
  },
  getComputedStyle: () => ({
    getPropertyValue: () => '',
    color: 'rgb(103, 80, 164)',
  }),
  matchMedia: () => ({ matches: true, addEventListener: () => {} }),
  $: (id) => {
    if (id === 'theme-vars') return dom.themeVars;
    if (id === 'amoled-toggle') return dom.amoledToggle;
    if (id === 'monochrome-toggle') return dom.monochromeToggle;
    if (id === 'containers-toggle') return dom.containersToggle;
    if (id === 'animations-toggle' || id === 'settings-anim-toggle') return dom.animationsToggle;
    const mockEl = {
      checked: false, style: {}, setAttribute: () => {}, value: '',
      addEventListener: () => {}, classList: { add: () => {}, remove: () => {} },
      getBoundingClientRect: () => ({ left: 0, top: 0, width: 100, height: 100 }),
    };
    return mockEl;
  },
  setHTML: () => {},
  icon: () => '',
  esc: (s) => s,
  t: (s) => s,
  jsArg: (s) => JSON.stringify(s),
  toast: () => {},
  store,
  sh: async () => ({ code: 0, out: dom.shMockOutput }),
  ctlx: async () => ({ code: 0, out: dom.shMockOutput }),
  requestAnimationFrame: (cb) => { cb(); return 0; },
};

vm.createContext(sandbox);
vm.runInContext(themeSrc, sandbox);

// ── 1. Color math and conversions ───────────────────────────────────────────
sect('color conversions');
eq([255, 0, 0].join(','), sandbox.hexToRgb('#ff0000').join(','), 'hexToRgb handles red');
eq([0, 255, 0].join(','), sandbox.hexToRgb('#00ff00').join(','), 'hexToRgb handles green');
eq([0, 0, 255].join(','), sandbox.hexToRgb('#0000ff').join(','), 'hexToRgb handles blue');
eq('#a8c7fa', sandbox.rgbToHex(168, 199, 250).toLowerCase(), 'rgbToHex converts RGB components');

const labWhite = sandbox.rgbToLab([255, 255, 255]);
truthy(Math.abs(labWhite[0] - 100) < 0.5, 'CIE Lab L* of pure white is ~100');
const labBlack = sandbox.rgbToLab([0, 0, 0]);
truthy(Math.abs(labBlack[0] - 0) < 0.5, 'CIE Lab L* of pure black is 0');

// Round-trip RGB -> Lab -> RGB
const testRgb = [103, 80, 164];
const testLab = sandbox.rgbToLab(testRgb);
const backRgb = sandbox.labToRgb(testLab).map(Math.round);
truthy(Math.max(...testRgb.map((v, i) => Math.abs(v - backRgb[i]))) <= 1,
  'RGB -> Lab -> RGB round-trip error is within 1 sRGB quantum');

// ── 2. M3 Tonal Palette generation (roles) ──────────────────────────────────
sect('monet roles generation');
const seed = '#a8c7fa'; // Pixel Blue
const lightRoles = vm.runInContext('roles(currentSeed, false, false)', sandbox);
const darkRoles = vm.runInContext('roles(currentSeed, true, false)', sandbox);
const amoledRoles = vm.runInContext('roles(currentSeed, true, true)', sandbox);
const roleVar = vm.runInContext('ROLE_VAR', sandbox);

// Verify all required roles exist in output
for (const k of Object.keys(roleVar)) {
  truthy(typeof lightRoles[k] === 'string' && /^#[0-9a-fA-F]{6}$/.test(lightRoles[k]),
    `light roles includes valid hex for ${k}`);
  truthy(typeof darkRoles[k] === 'string' && /^#[0-9a-fA-F]{6}$/.test(darkRoles[k]),
    `dark roles includes valid hex for ${k}`);
  truthy(typeof amoledRoles[k] === 'string' && /^#[0-9a-fA-F]{6}$/.test(amoledRoles[k]),
    `amoled roles includes valid hex for ${k}`);
}

// Light vs Dark tone relations
const lightBgL = sandbox.rgbToLab(sandbox.hexToRgb(lightRoles.background))[0];
const lightOnBgL = sandbox.rgbToLab(sandbox.hexToRgb(lightRoles.onBackground))[0];
truthy(lightBgL > 90 && lightOnBgL < 20, 'light theme background is high luminance, onBackground is dark');

const darkBgL = sandbox.rgbToLab(sandbox.hexToRgb(darkRoles.background))[0];
const darkOnBgL = sandbox.rgbToLab(sandbox.hexToRgb(darkRoles.onBackground))[0];
truthy(darkBgL < 15 && darkOnBgL > 80, 'dark theme background is low luminance, onBackground is bright');

// AMOLED requirements
eq('#000000', amoledRoles.background.toLowerCase(), 'AMOLED background is pure black #000000');
eq('#000000', amoledRoles.surface.toLowerCase(), 'AMOLED surface is pure black #000000');
eq('#000000', amoledRoles.surfaceDim.toLowerCase(), 'AMOLED surfaceDim is pure black #000000');
eq('#000000', amoledRoles.surfaceContainerLowest.toLowerCase(), 'AMOLED surfaceContainerLowest is pure black #000000');

const amoledLowL = sandbox.rgbToLab(sandbox.hexToRgb(amoledRoles.surfaceContainerLow))[0];
truthy(amoledLowL > 5 && amoledLowL < 20, 'AMOLED container surfaces have subtle visible luminance (>0)');

// Monochrome roles verification
const monoLightRoles = vm.runInContext('roles("#757575", false, false)', sandbox);
const monoDarkRoles = vm.runInContext('roles("#757575", true, false)', sandbox);
const monoAmoledRoles = vm.runInContext('roles("#757575", true, true)', sandbox);
for (const k of Object.keys(roleVar)) {
  truthy(typeof monoLightRoles[k] === 'string' && /^#[0-9a-fA-F]{6}$/.test(monoLightRoles[k]),
    `mono light roles includes valid hex for ${k}`);
  truthy(typeof monoDarkRoles[k] === 'string' && /^#[0-9a-fA-F]{6}$/.test(monoDarkRoles[k]),
    `mono dark roles includes valid hex for ${k}`);
  truthy(typeof monoAmoledRoles[k] === 'string' && /^#[0-9a-fA-F]{6}$/.test(monoAmoledRoles[k]),
    `mono amoled roles includes valid hex for ${k}`);
}
eq('#000000', monoLightRoles.primary.toLowerCase(), 'monochrome light primary is pure black #000000');
eq('#ffffff', monoLightRoles.onPrimary.toLowerCase(), 'monochrome light onPrimary is pure white #ffffff');
eq('#ffffff', monoDarkRoles.primary.toLowerCase(), 'monochrome dark primary is pure white #ffffff');
eq('#000000', monoDarkRoles.onPrimary.toLowerCase(), 'monochrome dark onPrimary is pure black #000000');
eq('#000000', monoAmoledRoles.background.toLowerCase(), 'monochrome AMOLED background is pure black #000000');
eq('#000000', monoAmoledRoles.surface.toLowerCase(), 'monochrome AMOLED surface is pure black #000000');
eq('#000000', monoAmoledRoles.surfaceDim.toLowerCase(), 'monochrome AMOLED surfaceDim is pure black #000000');
eq('#000000', monoAmoledRoles.surfaceContainerLowest.toLowerCase(), 'monochrome AMOLED surfaceContainerLowest is pure black #000000');

// ── 3. Тема как у системы: готовые цвета ролей Android ─────────────────────
sect('system theme: Android\'s own role colours');

(async () => {
  const SYS_OUT = [
    'style VIBRANT', 'seed #d4bee9',
    'background dark #2a1340', 'surface dark #2a1340', 'on_surface dark #ecdcf6',
    'surface_container dark #3b2552', 'surface_container_low dark #33204a', 'primary dark #e2c4ff',
    'primary_container dark #5b3b7a', 'surface_dim dark #2a1340', 'surface_container_lowest dark #1f0d33',
    'background light #fff7ff', 'primary light #6f4a8e', 'primary_fixed fixed #ebdcff', 'junk line'
  ].join('\n');
  const parsed = sandbox.parseSystemTheme(SYS_OUT);
  eq('VIBRANT', parsed.style, 'the style is parsed');
  eq('#d4bee9', parsed.seed, 'and the seed');
  eq('#3b2552', parsed.dark.surfaceContainer, 'roles are camelCased per mode');
  eq('#ebdcff', parsed.fixed.primaryFixed, 'fixed colours are kept apart');
  eq(null, sandbox.parseSystemTheme('OK'), 'an empty answer is not a theme');

  // Без своего акцента — цвета Android как есть
  delete dom.storage['m3_seed'];
  dom.shMockOutput = SYS_OUT;
  vm.runInContext("currentMode = 'dark'", sandbox);
  await sandbox.detectSystemMonet(false);
  const css = () => dom.themeVars.textContent;
  truthy(css().includes('--md-sys-color-background:#2a1340'), 'the background is the system one, not a computed near-black');
  truthy(css().includes('--md-sys-color-surface-container:#3b2552'), 'containers too');
  truthy(css().includes('--md-sys-color-primary:#e2c4ff'), 'and the accent');
  truthy(css().includes('--md-sys-color-primary-fixed:#ebdcff'), 'fixed colours come from Android');
  truthy(css().includes('--md-sys-color-secondary:#'), 'roles Android did not give are computed');
  eq('#d4bee9', vm.runInContext('currentSeed', sandbox), 'the picker shows the system seed');
  eq(undefined, dom.storage['m3_seed'], 'no own accent is stored');
  truthy(dom.storage['m3_sys'] && JSON.parse(dom.storage['m3_sys']).style === 'VIBRANT', 'the answer is remembered for the next start');

  // AMOLED поверх цветов системы: фон чёрный, контейнеры — как у системы
  sandbox.toggleAmoled(true);
  truthy(css().includes('--md-sys-color-background:#000000'), 'AMOLED: the background turns black');
  truthy(css().includes('--md-sys-color-surface-container:#3b2552'), 'AMOLED: containers keep the system colour, so the switch is visible');
  sandbox.toggleAmoled(false);
  truthy(css().includes('--md-sys-color-background:#2a1340'), 'AMOLED off: the system background is back');

  // Свой акцент — своя палитра, система больше не подставляется
  sandbox.applyMonet('#7bd0ff');
  truthy(!css().includes('--md-sys-color-background:#2a1340'), 'an own accent replaces the system colours');
  sandbox.resetTheme();
  truthy(css().includes('--md-sys-color-background:#2a1340'), 'reset brings the system theme back');

  // Где Android цветов ролей не даёт — палитра по стилю системы
  dom.shMockOutput = 'style VIBRANT\nseed #d4bee9';
  await sandbox.detectSystemMonet(false);
  const vib = vm.runInContext('roles("#d4bee9", true, false, false, "VIBRANT")', sandbox);
  const ton = vm.runInContext('roles("#d4bee9", true, false, false, "TONAL_SPOT")', sandbox);
  const chroma = h => { const l = sandbox.rgbToLab(sandbox.hexToRgb(h)); return Math.hypot(l[1], l[2]); };
  truthy(css().includes('--md-sys-color-background:' + vib.background), 'without role colours the style decides');
  truthy(chroma(vib.surfaceContainer) > chroma(ton.surfaceContainer), 'a vibrant style tints surfaces more than the tonal one');
  truthy(chroma(ton.surfaceContainer) > 3, 'even the tonal style tints them visibly (Android-like, not grey)');
  vm.runInContext("currentMode = 'auto'", sandbox);

  // ── 4. Palette application and container settings ───────────────────────────
  sect('palette application & containers');
  sandbox.applyMonet('#6dd58c');
  eq('#6dd58c', vm.runInContext('currentSeed', sandbox), 'applyMonet sets currentSeed');
  eq('#6dd58c', dom.storage['m3_seed'], 'applyMonet stores seed');
  truthy(dom.themeVars.textContent.includes('--md-sys-color-primary:'), 'theme-vars receives primary color role');
  truthy(dom.themeVars.textContent.includes('--md-sys-color-surface-container-low:'), 'theme-vars receives surfaceContainerLow role');

  // Test container toggle
  eq('true', dom.docEl.attrs['data-containers'], 'containers are enabled by default');
  sandbox.toggleContainers(false);
  eq('false', dom.docEl.attrs['data-containers'], 'toggleContainers(false) sets data-containers="false"');
  eq('false', dom.storage['m3_containers'], 'toggleContainers(false) stores setting');
  sandbox.toggleContainers(true);
  eq('true', dom.docEl.attrs['data-containers'], 'toggleContainers(true) sets data-containers="true"');

  // ── 5. Monochrome theme toggle and preset ─────────────────────────────────
  sect('monochrome theme toggle & preset');
  const palettes = vm.runInContext('PALETTES', sandbox);
  truthy(palettes.some(p => p[0] === 'Монохром' && p[1] === '#757575'), 'PALETTES includes Monochrome preset');

  // Отдельного переключателя монохрома нет: тема включается пресетом
  truthy(typeof sandbox.toggleMonochrome === 'undefined', 'toggleMonochrome is removed (preset only)');

  // Test applyMonet('#757575') activates monochrome
  sandbox.applyMonet('#757575');
  eq('true', dom.storage['m3_monochrome'], 'applyMonet(#757575) stores m3_monochrome="true"');
  truthy(vm.runInContext('isMonochrome()', sandbox), 'isMonochrome() is true after applyMonet(#757575)');

  // Test applyMonet('#deb0da') deactivates monochrome
  sandbox.applyMonet('#deb0da');
  eq('false', dom.storage['m3_monochrome'], 'applyMonet(#deb0da) stores m3_monochrome="false"');
  truthy(!vm.runInContext('isMonochrome()', sandbox), 'isMonochrome() is false after applying color');

  // ── 6. No animations toggle ───────────────────────────────────────────────
  sect('animations toggle is gone');
  truthy(typeof sandbox.toggleAnimations === 'undefined', 'toggleAnimations was removed');
  eq(undefined, dom.docEl.attrs['data-animations'], 'data-animations is not set');

  // Summary
  process.stdout.write('\n----------------------------------------\n');
  if (failures.length === 0) {
    process.stdout.write(`PASS  ${pass} checks\n`);
    process.exit(0);
  }
  process.stdout.write(`FAIL  ${failures.length} of ${pass + failures.length} checks failed\n`);
  for (const f of failures) process.stdout.write(`   - ${f}\n`);
  process.exit(1);
})();
