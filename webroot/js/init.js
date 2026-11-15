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
/* Отметка жизни для поворота (см. index.html): какой экран открыт, куда
   прокручен и в какой ориентации — раз в секунду, пока окно видно, и при уходе */
/* ориентация — та, в которой окно открылось: пересозданное поворотом окно
   рождается в другой, а старое могло успеть получить новый размер перед уходом */
const BORN_O = innerWidth > innerHeight ? 'l' : 'p';
function aliveBeat(force){
  if(document.hidden && !force) return;
  store.set('nfq_alive', JSON.stringify({t: Date.now(), o: BORN_O, page: currentPage, y: Math.round(scrollPos())}));
}
setInterval(aliveBeat, 1000);
document.addEventListener('visibilitychange', () => { if(document.hidden) aliveBeat(true); });
addEventListener('pagehide', () => aliveBeat(true));
(async () => {
  await detectSpawn();
  // окно пересоздано поворотом — сразу тот же экран и прокрутка
  const rot = window.NFQ_ROT;
  if(rot && PAGE_META[rot.page]){
    if(rot.page !== currentPage) navigate(rot.page);
    const y = +rot.y || 0;
    if(y) [300, 900, 1800].forEach(ms => setTimeout(() => { if(currentPage === rot.page && scrollPos() < y) scrollToY(y); }, ms));
  }
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
