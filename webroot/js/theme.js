/* nfqws2 WebUI · theme.js — тема оформления: генератор ролей M3 и лист темы
   Скрипты подключаются из index.html обычными <script> по порядку и делят одну
   глобальную область: функции и let/const одного файла видны в остальных. */

/* ══ Тема: генератор цветовых ролей M3 из seed ═══════════════════════════ */
function hexToRgb(hex){
  hex = String(hex).replace('#', '');
  if(hex.length === 3) hex = hex.split('').map(x => x + x).join('');
  return [parseInt(hex.slice(0, 2), 16), parseInt(hex.slice(2, 4), 16), parseInt(hex.slice(4, 6), 16)];
}
function rgbToHex(r, g, b){
  const p = x => Math.max(0, Math.min(255, Math.round(x))).toString(16).padStart(2, '0');
  return '#' + p(r) + p(g) + p(b);
}
function hexToHsl(hex){
  const c = hexToRgb(hex), r = c[0] / 255, g = c[1] / 255, b = c[2] / 255;
  const max = Math.max(r, g, b), min = Math.min(r, g, b);
  let h = 0, s = 0; const l = (max + min) / 2;
  if(max !== min){
    const d = max - min;
    s = l > .5 ? d / (2 - max - min) : d / (max + min);
    if(max === r) h = (g - b) / d + (g < b ? 6 : 0);
    else if(max === g) h = (b - r) / d + 2;
    else h = (r - g) / d + 4;
    h /= 6;
  }
  return [h * 360, s, l];
}
function hslToHex(h, s, l){
  h = ((h % 360) + 360) % 360; s = Math.max(0, Math.min(1, s)); l = Math.max(0, Math.min(1, l)); h /= 360;
  if(s === 0){ const v = l * 255; return rgbToHex(v, v, v); }
  const q = l < .5 ? l * (1 + s) : l + s - l * s, p = 2 * l - q;
  const hue = t => {
    if(t < 0) t += 1; if(t > 1) t -= 1;
    if(t < 1 / 6) return p + (q - p) * 6 * t;
    if(t < 1 / 2) return q;
    if(t < 2 / 3) return p + (q - p) * (2 / 3 - t) * 6;
    return p;
  };
  return rgbToHex(hue(h + 1 / 3) * 255, hue(h) * 255, hue(h - 1 / 3) * 255);
}
/* ── CIE Lab: тона M3 заданы светлотой L*, поэтому палитры строятся в Lab, а не в HSL ── */
const toLinear = c => { c /= 255; return c <= .04045 ? c / 12.92 : Math.pow((c + .055) / 1.055, 2.4); };
const toSrgb = c => 255 * (c <= .0031308 ? c * 12.92 : 1.055 * Math.pow(c, 1 / 2.4) - .055);
function rgbToLab(rgb){
  const r = toLinear(rgb[0]), g = toLinear(rgb[1]), b = toLinear(rgb[2]);
  const x = (r * .4124564 + g * .3575761 + b * .1804375) / .95047;
  const y = r * .2126729 + g * .7151522 + b * .0721750;
  const z = (r * .0193339 + g * .1191920 + b * .9503041) / 1.08883;
  const f = t => t > .008856 ? Math.cbrt(t) : 7.787 * t + 16 / 116;
  const fx = f(x), fy = f(y), fz = f(z);
  return [116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz)];
}
function labToRgb(lab){
  const fy = (lab[0] + 16) / 116, fx = lab[1] / 500 + fy, fz = fy - lab[2] / 200;
  const fi = t => t * t * t > .008856 ? t * t * t : (t - 16 / 116) / 7.787;
  const x = fi(fx) * .95047, y = fi(fy), z = fi(fz) * 1.08883;
  return [toSrgb(x * 3.2404542 + y * -1.5371385 + z * -.4985314),
          toSrgb(x * -.9692660 + y * 1.8760108 + z * .0415560),
          toSrgb(x * .0556434 + y * -.2040259 + z * 1.0572252)];
}
const inGamut = rgb => rgb[0] >= -.2 && rgb[0] <= 255.2 && rgb[1] >= -.2 && rgb[1] <= 255.2 && rgb[2] >= -.2 && rgb[2] <= 255.2;

/* Стили Material You — как их называет Android (secure
   theme_customization_overlay_packages, theme_style): хрома палитр и сдвиг тона
   в градусах. Тон 0..100 = L*; хрома уменьшается бисекцией, пока цвет не
   войдёт в sRGB. Свой акцент считается тональным стилем — как у Android по
   умолчанию. CONTENT и FIDELITY берут хрому у самого цвета */
const STYLES = {
  TONAL_SPOT: {primary: [36, 0], secondary: [16, 0], tertiary: [24, 60], neutral: [6, 0], neutralVariant: [8, 0]},
  VIBRANT: {primary: [200, 0], secondary: [24, 0], tertiary: [32, 60], neutral: [10, 0], neutralVariant: [12, 0]},
  EXPRESSIVE: {primary: [40, 240], secondary: [24, 15], tertiary: [32, 60], neutral: [8, 0], neutralVariant: [12, 0]},
  SPRITZ: {primary: [12, 0], secondary: [8, 0], tertiary: [16, 60], neutral: [2, 0], neutralVariant: [2, 0]},
  RAINBOW: {primary: [48, 0], secondary: [16, 0], tertiary: [24, 60], neutral: [0, 0], neutralVariant: [0, 0]},
  FRUIT_SALAD: {primary: [48, -50], secondary: [36, -50], tertiary: [36, 0], neutral: [10, 0], neutralVariant: [16, 0]},
  MONOCHROMATIC: {primary: [0, 0], secondary: [0, 0], tertiary: [0, 0], neutral: [0, 0], neutralVariant: [0, 0]},
  CONTENT: c => ({primary: [c, 0], secondary: [Math.max(c - 32, c / 2), 0], tertiary: [c / 2, 60], neutral: [c / 8, 0], neutralVariant: [c / 8 + 4, 0]})
};
STYLES.FIDELITY = STYLES.CONTENT;
function tone(lab, t, palette, style){
  const seedC = Math.hypot(lab[1], lab[2]);
  let chroma, shift = 0;
  if(palette === 'error') chroma = seedC * .9;
  else {
    const st = STYLES[style] || STYLES.TONAL_SPOT;
    const spec = (typeof st === 'function' ? st(seedC) : st)[palette];
    chroma = seedC < .4 ? 0 : spec[0];
    shift = spec[1] * Math.PI / 180;
  }
  const hue = Math.atan2(lab[2], lab[1]) + shift;
  const at = s => labToRgb([t, Math.cos(hue) * chroma * s, Math.sin(hue) * chroma * s]);
  if(inGamut(at(1))) return rgbToHex.apply(null, at(1));
  let lo = 0, hi = 1;
  for(let i = 0; i < 14; i++){
    const mid = (lo + hi) / 2;
    if(inGamut(at(mid))) lo = mid; else hi = mid;
  }
  return rgbToHex.apply(null, at(lo));
}

const PALETTES = [
  ['Сирень', '#deb0da'], ['Лаванда', '#d0bcff'], ['Pixel Blue', '#a8c7fa'], ['Сакура', '#f4b5d2'],
  ['Циан', '#7bd0ff'], ['Изумруд', '#6dd58c'], ['Янтарь', '#f3c774'], ['Коралл', '#ffb4ab'],
  ['Монохром', '#757575']
];
const ERROR_LAB = rgbToLab(hexToRgb('#B3261E'));
let currentSeed = '#6750a4', currentMode = 'auto';

/* KSU подставляет динамические цвета через colors.css — читаем --primary.
   В обычном браузере его нет, там акцент берётся из системного Highlight. */
function systemSeed(){
  const raw = getComputedStyle(document.documentElement).getPropertyValue('--primary').trim();
  if(raw){
    if(raw.charAt(0) === '#') return raw.length >= 7 ? raw.slice(0, 7).toLowerCase() : '#6750a4';
    const m = raw.match(/(\d+)\D+(\d+)\D+(\d+)/);
    if(m) return rgbToHex(+m[1], +m[2], +m[3]).toLowerCase();
  }
  const probe = document.createElement('div');
  probe.style.cssText = 'position:absolute;visibility:hidden;color:Highlight';
  document.body.appendChild(probe);
  const accent = getComputedStyle(probe).color;
  probe.remove();
  const mm = /rgba?\(\s*(\d+)[\s,]+(\d+)[\s,]+(\d+)/.exec(accent || '');
  if(!mm) return '#6750a4';
  const rgb = [+mm[1], +mm[2], +mm[3]], lab = rgbToLab(rgb);
  if(Math.hypot(lab[1], lab[2]) < 6) return '#6750a4';
  return rgbToHex(rgb[0], rgb[1], rgb[2]).toLowerCase();
}
function isDark(){
  if(currentMode === 'light') return false;
  if(currentMode === 'dark') return true;
  return matchMedia('(prefers-color-scheme: dark)').matches;
}
function isMonochrome(){
  return store.get('m3_monochrome') === 'true' || currentSeed === '#757575';
}
function roles(seedHex, dark, amoled, monochrome, style){
  const isMono = monochrome !== undefined ? !!monochrome : (String(seedHex).toLowerCase() === '#757575');
  const lab = rgbToLab(hexToRgb(seedHex));
  const p = (t, pal) => tone(lab, t, pal || 'primary', style);
  const e = t => tone(ERROR_LAB, t, 'error');
  const R = {};
  if(dark){
    if(isMono){
      R.primary = '#ffffff'; R.onPrimary = '#000000';
      R.primaryContainer = amoled ? '#262626' : '#393939'; R.onPrimaryContainer = '#e2e2e2';
      R.secondary = '#c6c6c6'; R.onSecondary = '#1a1a1a';
      R.secondaryContainer = amoled ? '#2e2e2e' : '#424242'; R.onSecondaryContainer = '#e2e2e2';
      R.tertiary = '#d0d0d0'; R.onTertiary = '#1a1a1a';
      R.tertiaryContainer = amoled ? '#282828' : '#3a3a3a'; R.onTertiaryContainer = '#e2e2e2';
      R.error = e(80); R.onError = e(20); R.errorContainer = e(30); R.onErrorContainer = e(90);
      R.background = amoled ? '#000000' : '#131313'; R.onBackground = '#e2e2e2';
      R.surface = amoled ? '#000000' : '#131313'; R.onSurface = '#e2e2e2';
      R.surfaceVariant = '#444444'; R.onSurfaceVariant = '#c6c6c6';
      R.surfaceDim = amoled ? '#000000' : '#131313'; R.surfaceBright = '#383838';
      R.surfaceContainerLowest = amoled ? '#000000' : '#0e0e0e';
      R.surfaceContainerLow = amoled ? '#141414' : '#1a1a1a';
      R.surfaceContainer = amoled ? '#1c1c1c' : '#202020';
      R.surfaceContainerHigh = amoled ? '#262626' : '#282828';
      R.surfaceContainerHighest = amoled ? '#303030' : '#333333';
      R.outline = '#8e8e8e'; R.outlineVariant = '#444444';
      R.inverseSurface = '#e2e2e2'; R.inverseOnSurface = '#1b1b1b';
      R.inversePrimary = '#000000';
      R.statusOk = '#6dd58c'; R.statusWarn = '#f0c14b'; R.statusBad = '#ffb4ab';
    } else {
      R.primary = p(80); R.onPrimary = p(20);
      R.primaryContainer = p(30); R.onPrimaryContainer = p(90);
      R.secondary = p(80, 'secondary'); R.onSecondary = p(20, 'secondary');
      R.secondaryContainer = p(30, 'secondary'); R.onSecondaryContainer = p(90, 'secondary');
      R.tertiary = p(80, 'tertiary'); R.onTertiary = p(20, 'tertiary');
      R.tertiaryContainer = p(30, 'tertiary'); R.onTertiaryContainer = p(90, 'tertiary');
      R.error = e(80); R.onError = e(20); R.errorContainer = e(30); R.onErrorContainer = e(90);
      R.background = amoled ? '#000000' : p(6, 'neutral'); R.onBackground = p(90, 'neutral');
      R.surface = amoled ? '#000000' : p(6, 'neutral'); R.onSurface = p(90, 'neutral');
      R.surfaceVariant = p(30, 'neutralVariant'); R.onSurfaceVariant = p(80, 'neutralVariant');
      R.surfaceDim = amoled ? '#000000' : p(6, 'neutral'); R.surfaceBright = p(24, 'neutral');
      R.surfaceContainerLowest = amoled ? '#000000' : p(4, 'neutral');
      /* AMOLED: фон чёрный, а контейнеры светлее обычного тёмного — с лёгким
         оттенком акцента, чтобы карточки читались на чёрном. */
      R.surfaceContainerLow = amoled ? p(11, 'neutralVariant') : p(10, 'neutral');
      R.surfaceContainer = amoled ? p(14, 'neutralVariant') : p(12, 'neutral');
      R.surfaceContainerHigh = amoled ? p(18, 'neutralVariant') : p(17, 'neutral');
      R.surfaceContainerHighest = amoled ? p(23, 'neutralVariant') : p(22, 'neutral');
      R.outline = p(60, 'neutralVariant'); R.outlineVariant = p(30, 'neutralVariant');
      R.inverseSurface = p(90, 'neutral'); R.inverseOnSurface = p(20, 'neutral');
      R.inversePrimary = p(40);
      R.statusOk = '#6dd58c'; R.statusWarn = '#f0c14b'; R.statusBad = '#ffb4ab';
    }
  } else {
    if(isMono){
      R.primary = '#000000'; R.onPrimary = '#ffffff';
      R.primaryContainer = '#e2e2e2'; R.onPrimaryContainer = '#1b1b1b';
      R.secondary = '#5e5e5e'; R.onSecondary = '#ffffff';
      R.secondaryContainer = '#e6e6e6'; R.onSecondaryContainer = '#1b1b1b';
      R.tertiary = '#606060'; R.onTertiary = '#ffffff';
      R.tertiaryContainer = '#e8e8e8'; R.onTertiaryContainer = '#1b1b1b';
      R.error = e(40); R.onError = e(100); R.errorContainer = e(90); R.onErrorContainer = e(10);
      R.background = '#f9f9f9'; R.onBackground = '#1a1a1a';
      R.surface = '#f9f9f9'; R.onSurface = '#1a1a1a';
      R.surfaceVariant = '#e0e0e0'; R.onSurfaceVariant = '#444444';
      R.surfaceDim = '#dedede'; R.surfaceBright = '#f9f9f9';
      R.surfaceContainerLowest = '#ffffff';
      R.surfaceContainerLow = '#f3f3f3';
      R.surfaceContainer = '#eeeeee';
      R.surfaceContainerHigh = '#e8e8e8';
      R.surfaceContainerHighest = '#e2e2e2';
      R.outline = '#757575'; R.outlineVariant = '#c6c6c6';
      R.inverseSurface = '#303030'; R.inverseOnSurface = '#f1f1f1';
      R.inversePrimary = '#ffffff';
      R.statusOk = '#166a33'; R.statusWarn = '#6b5000'; R.statusBad = '#a01811';
    } else {
      R.primary = p(40); R.onPrimary = p(100);
      R.primaryContainer = p(90); R.onPrimaryContainer = p(10);
      R.secondary = p(40, 'secondary'); R.onSecondary = p(100, 'secondary');
      R.secondaryContainer = p(90, 'secondary'); R.onSecondaryContainer = p(10, 'secondary');
      R.tertiary = p(40, 'tertiary'); R.onTertiary = p(100, 'tertiary');
      R.tertiaryContainer = p(90, 'tertiary'); R.onTertiaryContainer = p(10, 'tertiary');
      R.error = e(40); R.onError = e(100); R.errorContainer = e(90); R.onErrorContainer = e(10);
      R.background = p(98, 'neutral'); R.onBackground = p(10, 'neutral');
      R.surface = p(98, 'neutral'); R.onSurface = p(10, 'neutral');
      R.surfaceVariant = p(90, 'neutralVariant'); R.onSurfaceVariant = p(30, 'neutralVariant');
      R.surfaceDim = p(87, 'neutral'); R.surfaceBright = p(98, 'neutral');
      R.surfaceContainerLowest = p(100, 'neutral');
      R.surfaceContainerLow = p(96, 'neutral');
      R.surfaceContainer = p(94, 'neutral');
      R.surfaceContainerHigh = p(92, 'neutral');
      R.surfaceContainerHighest = p(90, 'neutral');
      R.outline = p(50, 'neutralVariant'); R.outlineVariant = p(80, 'neutralVariant');
      R.inverseSurface = p(20, 'neutral'); R.inverseOnSurface = p(95, 'neutral');
      R.inversePrimary = p(80);
      R.statusOk = '#166a33'; R.statusWarn = '#6b5000'; R.statusBad = '#a01811';
    }
  }
  /* fixed-роли не зависят от темы (для этого и называются fixed): tone 90/80/30/10.
     Без них схема не совпадает с Android Dynamic Color по набору ролей. */
  if(isMono){
    R.primaryFixed = '#e2e2e2'; R.primaryFixedDim = '#c6c6c6'; R.primaryFixedVariant = '#444444';
    R.onPrimaryFixed = '#181818'; R.onPrimaryFixedVariant = '#444444';
    R.secondaryFixed = '#e2e2e2'; R.secondaryFixedDim = '#c6c6c6'; R.secondaryFixedVariant = '#444444';
    R.onSecondaryFixed = '#181818'; R.onSecondaryFixedVariant = '#444444';
    R.tertiaryFixed = '#e2e2e2'; R.tertiaryFixedDim = '#c6c6c6';
    R.tertiaryFixedVariant = '#444444'; R.onTertiaryFixed = '#181818';
    R.onTertiaryFixedVariant = '#444444';
    R.surfaceTint = dark ? '#ffffff' : '#000000'; R.shadow = '#000000';
  } else {
    R.primaryFixed = p(90); R.primaryFixedDim = p(80); R.primaryFixedVariant = p(30);
    R.onPrimaryFixed = p(10); R.onPrimaryFixedVariant = p(30);
    R.secondaryFixed = p(90, 'secondary'); R.secondaryFixedDim = p(80, 'secondary'); R.secondaryFixedVariant = p(30, 'secondary');
    R.onSecondaryFixed = p(10, 'secondary'); R.onSecondaryFixedVariant = p(30, 'secondary');
    R.tertiaryFixed = p(90, 'tertiary'); R.tertiaryFixedDim = p(80, 'tertiary');
    R.tertiaryFixedVariant = p(30, 'tertiary'); R.onTertiaryFixed = p(10, 'tertiary');
    R.onTertiaryFixedVariant = p(30, 'tertiary');
    R.surfaceTint = R.primary; R.shadow = '#000000';
  }
  return R;
}
const ROLE_VAR = {
  primary: '--md-sys-color-primary', onPrimary: '--md-sys-color-on-primary',
  primaryContainer: '--md-sys-color-primary-container', onPrimaryContainer: '--md-sys-color-on-primary-container',
  secondary: '--md-sys-color-secondary', onSecondary: '--md-sys-color-on-secondary',
  secondaryContainer: '--md-sys-color-secondary-container', onSecondaryContainer: '--md-sys-color-on-secondary-container',
  tertiary: '--md-sys-color-tertiary', onTertiary: '--md-sys-color-on-tertiary',
  tertiaryContainer: '--md-sys-color-tertiary-container', onTertiaryContainer: '--md-sys-color-on-tertiary-container',
  error: '--md-sys-color-error', onError: '--md-sys-color-on-error',
  errorContainer: '--md-sys-color-error-container', onErrorContainer: '--md-sys-color-on-error-container',
  background: '--md-sys-color-background', onBackground: '--md-sys-color-on-background',
  surface: '--md-sys-color-surface', onSurface: '--md-sys-color-on-surface',
  surfaceVariant: '--md-sys-color-surface-variant', onSurfaceVariant: '--md-sys-color-on-surface-variant',
  surfaceDim: '--md-sys-color-surface-dim', surfaceBright: '--md-sys-color-surface-bright',
  surfaceContainerLowest: '--md-sys-color-surface-container-lowest',
  surfaceContainerLow: '--md-sys-color-surface-container-low',
  surfaceContainer: '--md-sys-color-surface-container',
  surfaceContainerHigh: '--md-sys-color-surface-container-high',
  surfaceContainerHighest: '--md-sys-color-surface-container-highest',
  outline: '--md-sys-color-outline', outlineVariant: '--md-sys-color-outline-variant',
  inverseSurface: '--md-sys-color-inverse-surface', inverseOnSurface: '--md-sys-color-inverse-on-surface',
  inversePrimary: '--md-sys-color-inverse-primary',
  surfaceTint: '--md-sys-color-surface-tint', shadow: '--md-sys-color-shadow',
  primaryFixed: '--md-sys-color-primary-fixed', primaryFixedDim: '--md-sys-color-primary-fixed-dim',
  primaryFixedVariant: '--md-sys-color-primary-fixed-variant', onPrimaryFixed: '--md-sys-color-on-primary-fixed',
  onPrimaryFixedVariant: '--md-sys-color-on-primary-fixed-variant',
  secondaryFixed: '--md-sys-color-secondary-fixed', secondaryFixedDim: '--md-sys-color-secondary-fixed-dim',
  secondaryFixedVariant: '--md-sys-color-secondary-fixed-variant', onSecondaryFixed: '--md-sys-color-on-secondary-fixed',
  onSecondaryFixedVariant: '--md-sys-color-on-secondary-fixed-variant',
  tertiaryFixed: '--md-sys-color-tertiary-fixed', tertiaryFixedDim: '--md-sys-color-tertiary-fixed-dim',
  tertiaryFixedVariant: '--md-sys-color-tertiary-fixed-variant', onTertiaryFixed: '--md-sys-color-on-tertiary-fixed',
  onTertiaryFixedVariant: '--md-sys-color-on-tertiary-fixed-variant'
};
/* ── Тема системы ────────────────────────────────────────────────────────
   Пока акцент не выбран вручную, WebUI берёт у Android готовые цвета ролей
   (nfqws2-ctl monet-system): с теми же стилем и контрастом, что у «Настроек».
   Где их нет (Android до 14), палитра считается по сиду и стилю системы.
   Ответ хранится и в браузере, чтобы тема была верной с первого кадра */
let SYS = null;
try { SYS = JSON.parse(store.get('m3_sys') || 'null'); } catch(e){ SYS = null; }
const systemTheme = () => !/^#[0-9a-f]{6}$/.test((store.get('m3_seed') || '').toLowerCase());
const camel = s => s.replace(/_([a-z])/g, (m, c) => c.toUpperCase());
function parseSystemTheme(out){
  const o = {style: '', seed: '', light: {}, dark: {}, fixed: {}};
  String(out || '').split('\n').forEach(l => {
    const f = l.trim().split(/\s+/);
    if(f[0] === 'style' && f[1]) o.style = f[1];
    else if(f[0] === 'seed' && /^#[0-9a-f]{6}$/.test(f[1])) o.seed = f[1];
    else if(f.length === 3 && o[f[1]] && /^#[0-9a-f]{6}$/.test(f[2])) o[f[1]][camel(f[0])] = f[2];
  });
  return (o.seed || Object.keys(o.dark).length) ? o : null;
}
async function loadSystemTheme(){
  const r = await ctlx(['monet-system'], 90000);
  const o = r.code ? null : parseSystemTheme(r.out);
  if(!o) return false;
  SYS = o;
  store.set('m3_sys', JSON.stringify(o));
  if(systemTheme()){
    if(o.seed) currentSeed = o.seed;
    applyTheme();
  }
  return true;
}
// AMOLED: фон и поверхность — чёрные, контейнеры остаются цветными, как в системе
function blacken(R){
  R.background = R.surface = R.surfaceDim = R.surfaceContainerLowest = '#000000';
}
function themeRoles(dark, amoled){
  const sys = systemTheme() && SYS;
  const style = sys && SYS.style ? SYS.style : 'TONAL_SPOT';
  const seed = sys && SYS.seed ? SYS.seed : currentSeed;
  const own = sys ? SYS[dark ? 'dark' : 'light'] || {} : {};
  const exact = Object.keys(own).length > 0;
  const R = roles(seed, dark, amoled && !exact, sys ? style === 'MONOCHROMATIC' : isMonochrome(), style);
  if(exact){
    Object.assign(R, own, SYS.fixed || {});
    R.surfaceTint = R.primary;
    if(!own.inverseSurface) R.inverseSurface = R.onSurface;
    if(amoled) blacken(R);
  }
  return R;
}
function applyTheme(skipUI){
  const dark = isDark();
  const amoled = store.get('m3_amoled') === 'true' && dark;
  const containers = store.get('m3_containers') !== 'false';
  const R = themeRoles(dark, amoled);
  // Палитра уходит в <style id="theme-vars">, а не инлайном на documentElement.
  // Инлайн-стиль нельзя переопределить из CSS — ни правилом компонента, ни
  // медиазапросом, — поэтому он закрывает тему наглухо. Отдельный блок в <head>
  // участвует в каскаде обычным порядком.
  let css = ':root{';
  for(const k in ROLE_VAR) css += ROLE_VAR[k] + ':' + R[k] + ';';
  css += '--status-ok:' + R.statusOk + ';--status-warn:' + R.statusWarn + ';--status-bad:' + R.statusBad + ';}';
  $('theme-vars').textContent = css;
  document.documentElement.setAttribute('data-mode', dark ? 'dark' : 'light');
  document.documentElement.setAttribute('data-amoled', amoled ? 'true' : 'false');
  document.documentElement.setAttribute('data-containers', containers ? 'true' : 'false');
  const meta = document.querySelector('meta[name="theme-color"]');
  if(meta) meta.setAttribute('content', R.background);
  if(!skipUI) drawThemeUI();
}
/* ── Лист темы ────────────────────────────────────────────────────────────
   Сверху живой предпросмотр на текущих ролях, ниже — режим, AMOLED, готовые
   акценты и свой цвет. Свой цвет выбирается «руками» на круге: угол — тон,
   расстояние от центра — насыщенность; яркость — отдельным ползунком, HEX —
   для точного значения. Пока палец ведёт по кругу, тема применяется сразу,
   а в память пишется по отпусканию. */
let wheelH = 270, wheelS = .6, wheelDrag = false, wheelFrame = 0;
function drawThemeUI(){
  setHTML('theme-mode', [['auto', 'Авто'], ['light', 'Светлая'], ['dark', 'Тёмная']].map(m =>
    '<button class="seg state' + (currentMode === m[0] ? ' on' : '') + '" aria-pressed="' + (currentMode === m[0]) +
    '" onclick="setThemeMode(' + jsArg(m[0]) + ')"><span class="check">' + icon('check', 's18') + '</span>' + esc(t(m[1])) + '</button>').join(''), false);
  const dark = isDark();
  const mono = isMonochrome();
  setHTML('palette-grid', PALETTES.map(p => {
    // Образец — как в выборе обоев Pixel: тон 80 основной палитры сверху,
    // вторичная и третичная снизу; в любой теме он читается одинаково.
    const isThisMono = p[1].toLowerCase() === '#757575';
    const r = roles(p[1], true, false, isThisMono);
    const on = !systemTheme() && (isThisMono ? mono : (!mono && p[1].toLowerCase() === currentSeed));
    return '<button class="swatch-dot state' + (on ? ' on' : '') + '" aria-pressed="' + on + '" title="' + esc(t(p[0])) + '"' +
      ' aria-label="' + esc(t(p[0])) + '" onclick="applyMonet(' + jsArg(p[1]) + ')"' +
      ' style="--sw-a:' + r.primary + ';--sw-b:' + r.secondary + ';--sw-c:' + r.tertiary + '">' +
      '<span class="sw-check">' + icon('check', 's20') + '</span></button>';
  }).join(''), false);
  setHTML('tp-roles', ['primary', 'secondary', 'tertiary', 'primary-container', 'error'].map(v =>
    '<span class="tp-role" style="background:var(--md-sys-color-' + v + ')"></span>').join(''), false);
  $('amoled-toggle').checked = store.get('m3_amoled') === 'true';
  $('amoled-toggle').disabled = !dark;
  if($('containers-toggle')) $('containers-toggle').checked = store.get('m3_containers') !== 'false';
  syncPicker(true);
}
/* Круг, ползунок и HEX отражают текущий seed. fromSeed=false — когда seed
   только что получен с самого круга: тон и насыщенность берём как есть,
   без обратного пересчёта (он округляет и дёргает бегунок). */
function syncPicker(fromSeed){
  const hsl = hexToHsl(currentSeed);
  if(fromSeed){ wheelH = hsl[0]; wheelS = hsl[1]; $('cd-lum').value = Math.round(Math.min(85, Math.max(20, hsl[2] * 100))); }
  const L = +$('cd-lum').value;
  const stops = [];
  for(let h = 0; h <= 360; h += 30) stops.push('hsl(' + h + ' 100% ' + L + '%)');
  $('wheel').style.background = 'radial-gradient(closest-side, hsl(0 0% ' + L + '%), hsl(0 0% ' + L + '% / 0)), conic-gradient(' + stops.join(',') + ')';
  const a = wheelH * Math.PI / 180, r = wheelS * 50;
  const th = $('wheel-thumb');
  th.style.left = (50 + Math.sin(a) * r) + '%';
  th.style.top = (50 - Math.cos(a) * r) + '%';
  th.style.background = currentSeed;
  $('wheel').setAttribute('aria-valuenow', Math.round(wheelH));
  $('custom-swatch').style.background = currentSeed;
  if(document.activeElement !== $('custom-hex-input')) $('custom-hex-input').value = currentSeed.replace('#', '').toUpperCase();
}
const wheelHex = () => hslToHex(wheelH, wheelS, +$('cd-lum').value / 100);
function wheelApply(final){
  store.set('m3_monochrome', 'false');
  currentSeed = wheelHex().toLowerCase();
  if(!wheelFrame) wheelFrame = requestAnimationFrame(() => { wheelFrame = 0; applyTheme(true); syncPicker(false); });
  if(final){ store.set('m3_seed', currentSeed); setTimeout(drawThemeUI, 30); }
}
function wheelPick(e){
  const r = $('wheel').getBoundingClientRect();
  const dx = e.clientX - (r.left + r.width / 2), dy = e.clientY - (r.top + r.height / 2);
  wheelH = (Math.atan2(dx, -dy) * 180 / Math.PI + 360) % 360;
  wheelS = Math.min(1, Math.hypot(dx, dy) / (r.width / 2));
  wheelApply(false);
}
(function initWheel(){
  const w = $('wheel');
  w.addEventListener('pointerdown', e => { wheelDrag = true; w.setPointerCapture(e.pointerId); w.classList.add('drag'); wheelPick(e); });
  w.addEventListener('pointermove', e => { if(wheelDrag) wheelPick(e); });
  const end = () => { if(!wheelDrag) return; wheelDrag = false; w.classList.remove('drag'); wheelApply(true); };
  w.addEventListener('pointerup', end);
  w.addEventListener('pointercancel', end);
  w.addEventListener('keydown', e => {
    const k = {ArrowLeft: [-5, 0], ArrowRight: [5, 0], ArrowUp: [0, .05], ArrowDown: [0, -.05]}[e.key];
    if(!k) return;
    e.preventDefault();
    wheelH = (wheelH + k[0] + 360) % 360;
    wheelS = Math.min(1, Math.max(0, wheelS + k[1]));
    wheelApply(true);
  });
})();
function onWheelLum(){ wheelApply(false); clearTimeout(onWheelLum.t); onWheelLum.t = setTimeout(() => store.set('m3_seed', currentSeed), 300); }
function setThemeMode(m){
  currentMode = m;
  store.set('m3_mode', m);
  applyTheme();
}
function applyMonet(seedHex){
  if(!/^#[0-9a-fA-F]{6}$/.test(seedHex)) return;
  const hex = seedHex.toLowerCase();
  store.set('m3_monochrome', hex === '#757575' ? 'true' : 'false');
  currentSeed = hex;
  store.set('m3_seed', currentSeed);
  applyTheme();
}
function toggleAmoled(on){
  store.set('m3_amoled', on ? 'true' : 'false');
  applyTheme();
}
function toggleContainers(on){
  store.set('m3_containers', on ? 'true' : 'false');
  applyTheme();
}
function onHexInput(val){
  const clean = val.replace(/[^0-9a-fA-F]/g, '').slice(0, 6);
  $('custom-hex-input').value = clean;
  if(clean.length !== 6) return;
  const hex = '#' + clean.toLowerCase();
  store.set('m3_monochrome', hex === '#757575' ? 'true' : 'false');
  currentSeed = hex;
  store.set('m3_seed', currentSeed);
  // полная перерисовка: иначе подсветка прежнего пресета оставалась бы;
  // поле HEX в фокусе drawThemeUI не трогает
  applyTheme();
}
function resetTheme(){
  ['m3_seed', 'm3_mode', 'm3_amoled', 'm3_containers', 'm3_monochrome', 'm3_last_color_seed', 'm3_no_animations', 'm3_animations'].forEach(k => store.del(k));
  currentMode = 'auto';
  currentSeed = (SYS && SYS.seed) || systemSeed();
  applyTheme();
  toast(t('Тема сброшена к системной'));
  loadSystemTheme();
}
/* «С обоев»: тема снова как у системы — цвета ролей у Android, без своего акцента */
async function detectSystemMonet(showToastNotice){
  store.del('m3_seed'); store.del('m3_monochrome');
  currentSeed = (SYS && SYS.seed) || systemSeed();
  applyTheme();
  const ok = await loadSystemTheme();
  if(showToastNotice) toast(ok && SYS.seed ? t('Акцент с обоев: {0}', SYS.seed.toUpperCase()) : t('Тема как у системы'));
}
