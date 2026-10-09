/* nfqws2 WebUI · init.js — запуск
   Скрипты подключаются из index.html обычными <script> по порядку и делят одну
   глобальную область: функции и let/const одного файла видны в остальных. */

/* ══ Init ════════════════════════════════════════════════════════════════
   Последний скрипт: к этому моменту все модули уже загружены. */
currentMode = store.get('m3_mode') || 'auto';
const savedSeed = (store.get('m3_seed') || '').toLowerCase();
currentSeed = /^#[0-9a-f]{6}$/.test(savedSeed) ? savedSeed : systemSeed();
applyTheme();
matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => { if(currentMode === 'auto') applyTheme(); });
translateStatic();
renderNavBar('control');
renderAppBar('control', false);
renderLogChips();
renderParams({});
(async () => {
  await detectSpawn();
  await stat();
  initStrategySelector();
  checkWhatsNew();
})();
