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
/* Карточка «Состояния» — сразу из слепка прошлого статуса: экран готов и
   кнопки нажимаются с первого кадра, заставка не ждёт службу. Слепок —
   данные, а не готовая разметка: в каком бы состоянии служба ни была (пауза,
   VPN, остановлена), карточка рисуется по ним той же функцией. Первой
   командой — подпись (несколько файлов, самое дешёвое чтение): она за доли
   секунды поправляет то, что успело смениться без экрана; полный статус — следом */
const snapStatus = (() => { try { return JSON.parse(snapGet('status') || 'null'); } catch(e){ return null; } })();
if(snapStatus && snapStatus.running != null){
  // время работы шло и без экрана
  if(snapStatus.running && snapStatus.saved_at > 0) snapStatus.uptime_ms = (+snapStatus.uptime_ms || 0) + Math.max(0, Date.now() - snapStatus.saved_at);
  S = snapStatus;
  renderStatus();
  splashOut();
}
(async () => {
  await detectSpawn();
  // цвета системы — в фоне: первый раз это секунды, дальше ответ из кэша модуля
  if(systemTheme()) loadSystemTheme();
  if(S.running != null){ const sig = await readSig(); statSig = sigKey(sig) || ''; applySig(sig); }
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
