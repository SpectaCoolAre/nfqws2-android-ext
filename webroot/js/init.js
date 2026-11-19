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
  if(S.strategy) currentStrategy = S.strategy;
  LIVE = snapJSON('live');
  renderStatus();
  prerenderTabs();
  splashOut();
}
(async () => {
  await detectSpawn();
  // цвета системы — в фоне: первый раз это секунды, дальше ответ из кэша модуля
  if(systemTheme()) loadSystemTheme();
  if(S.running != null){ const sig = await readSig(); statSig = sigKey(sig) || ''; applySig(sig); }
  await stat();
  if(!snapStatus || snapStatus.running == null) prerenderTabs();
  splashOut();
  initStrategySelector();
  // свежие данные вкладки «Обход» — в фоне, пока пользователь на главной:
  // её самый долгий запрос (сравнение конфига) не ждёт первого открытия
  setTimeout(() => { if(currentPage !== 'config' && !pageInited.has('config')) confInit().catch(() => {}); }, 2500);
  // плитки — из слепка уже на экране; свежие — чуть позже, чтобы на холодном
  // старте не стоять в очереди перед командами открытого экрана
  if(LIVE) setTimeout(() => { if(currentPage === 'control') loadLive(); }, 1500); else loadLive();
  checkWhatsNew();
})();

/* Остальные вкладки — пока на экране логотип (19.11): из слепков прошлого
   открытия и последнего статуса. Первое открытие вкладки показывает готовый
   экран сразу, свежие данные приходят следом, а не пустой экран, который
   строится на глазах. Ошибка одной вкладки не мешает остальным */
function prerenderTabs(){
  [() => { renderMode(); renderListFiles(); },
   () => renderSettings(),
   () => {
     if(!BYP) BYP = snapJSON('byp');
     if(!SMS && !smartView) SMS = snapJSON('sms');
     renderBypass();
     if(isSmartMode() && SMS) renderSmart();
   }].forEach(f => { try { f(); } catch(e) {} });
}

/* Заставка уходит, когда «Состояние» получило первые данные и отрисовалось
   (два кадра); служба долго не отвечает — всё равно через 4 с */
function splashOut(){
  const el = document.getElementById('splash');
  if(!el || el.classList.contains('out')) return;
  requestAnimationFrame(() => requestAnimationFrame(() => {
    el.classList.add('out');
    // фон окна до стилей (index.html) — дальше фон темы
    setTimeout(() => { el.remove(); document.documentElement.style.removeProperty('background'); }, 400);
  }));
}
setTimeout(splashOut, 4000);
