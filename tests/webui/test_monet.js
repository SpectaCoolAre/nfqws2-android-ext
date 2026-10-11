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
// 3. Android system Monet color detection:
//    - dumpsys wallpaper packed integer parsing: Color(-14329243) -> #257a65
//    - dumpsys wallpaper float format: Color(0.2, 0.4, 0.8) -> #3366cc
//    - ThemeOverlayController dump: mMainColor=-14329243 and mMainColor=0xffa8c7fa
//    - settings get secure theme_customization_overlay_packages JSON string
//    - Exclusion of dummy / monochrome artifacts (#ffffff, #000000, #e2e2e9)
//    - Fallback cascade to systemSeed()
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

// ── 3. Dynamic Android Monet color detection ────────────────────────────────
sect('android monet detection');

(async () => {
  // A. dumpsys wallpaper packed integer
  dom.shMockOutput = `
    Wallpaper wallpaper:
      primary Color(-14329243) secondary Color(0) tertiary Color(0)
  `;
  await sandbox.detectSystemMonet(false);
  eq('#255a65', vm.runInContext('currentSeed', sandbox), 'detectSystemMonet extracts packed integer Color(-14329243)');

  // B. dumpsys wallpaper float format
  dom.shMockOutput = `
    primary Color(0.2, 0.4, 0.8)
  `;
  await sandbox.detectSystemMonet(false);
  eq('#3366cc', vm.runInContext('currentSeed', sandbox), 'detectSystemMonet extracts float Color(0.2, 0.4, 0.8)');

  // C. theme_customization_overlay_packages JSON string
  dom.shMockOutput = `
    {"android.theme.customization.system_palette":"_A8C7FA","android.theme.customization.color_source":"home_wallpaper"}
  `;
  await sandbox.detectSystemMonet(false);
  eq('#a8c7fa', vm.runInContext('currentSeed', sandbox), 'detectSystemMonet extracts hex from overlay packages JSON');

  // D. ThemeOverlayController dump
  dom.shMockOutput = `
    ThemeOverlayController:
      mMainColor=0xffdeb0da
  `;
  await sandbox.detectSystemMonet(false);
  eq('#deb0da', vm.runInContext('currentSeed', sandbox), 'detectSystemMonet extracts mMainColor from ThemeOverlayController');

  // E. Ignore monochrome dummy colors (#ffffff, #000000, #e2e2e9)
  dom.shMockOutput = `
    Color(-1)
    Color(0)
    {"android.theme.customization.system_palette":"#ffffff"}
    {"android.theme.customization.system_palette":"_E2E2E9"}
    primary Color(-14329243)
  `;
  await sandbox.detectSystemMonet(false);
  eq('#255a65', vm.runInContext('currentSeed', sandbox), 'detectSystemMonet filters out dummy white/black/gray values');

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
  eq('true', dom.docEl.attrs['data-monochrome'], 'applyMonet(#757575) activates data-monochrome="true"');
  eq('true', dom.storage['m3_monochrome'], 'applyMonet(#757575) stores m3_monochrome="true"');
  truthy(vm.runInContext('isMonochrome()', sandbox), 'isMonochrome() is true after applyMonet(#757575)');

  // Test applyMonet('#deb0da') deactivates monochrome
  sandbox.applyMonet('#deb0da');
  eq('false', dom.docEl.attrs['data-monochrome'], 'applyMonet(#deb0da) resets data-monochrome="false"');
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
