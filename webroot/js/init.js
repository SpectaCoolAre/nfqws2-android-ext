/* nfqws2 WebUI · init.js — запуск
   Скрипты подключаются из index.html обычными <script> по порядку и делят одну
   глобальную область: функции и let/const одного файла видны в остальных. */

/* ══ Init ════════════════════════════════════════════════════════════════
   Последний скрипт: к этому моменту все модули уже загружены. */
currentMode = store.get('m3_mode') || 'auto';
const savedSeed = (store.get('m3_seed') || '').toLowerCase();
currentSeed = /^#[0-9a-f]{6}$/.test(savedSeed) ? savedSeed : (SYS && SYS.seed) || systemSeed();
applyTheme();
matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => { if(currentMode === 'auto') applyTheme(); });
translateStatic();
renderNavBar('control');
renderAppBar('control', false);
renderLogChips();
renderParams({});
warmTabs();
// поворот и смена размера окна меняют ширину страницы — невидимые вкладки за ней
addEventListener('resize', () => { if(!transitionCleanup && !swipe.st) warmTabs(); });
(async () => {
  await detectSpawn();
  // цвета системы — в фоне: первый раз это секунды, дальше ответ из кэша модуля
  if(systemTheme()) loadSystemTheme();
  await stat();
  splashOut();
  initStrategySelector();
  loadLive();
  checkWhatsNew();
})();

/* Заставка уходит, когда «Состояние» получило первые данные и отрисовалось
   (два кадра); служба долго не отвечает — всё равно через 4 с */
function splashOut(){
  const el = document.getElementById('splash');
  if(!el || el.classList.contains('out')) return;
  requestAnimationFrame(() => requestAnimationFrame(() => {
    el.classList.add('out');
    setTimeout(() => el.remove(), 400);
  }));
}
setTimeout(splashOut, 4000);
