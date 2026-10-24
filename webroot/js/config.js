/* nfqws2 WebUI · config.js — экран «Конфиг» и импорт
   Скрипты подключаются из index.html обычными <script> по порядку и делят одну
   глобальную область: функции и let/const одного файла видны в остальных. */

/* ══ ОБХОД: СТРАТЕГИИ ИЛИ УМНЫЙ РЕЖИМ ════════════════════════════════════
   Два режима работы. «Стратегии» — выбранная стратегия и её конфиг
   nfqws2.conf: правка, проверка, импорт, прежний конфиг. «Умный режим» —
   его статистика (smart.js). Переключатель — сверху вкладки; режим — это
   просто текущая стратегия: smart или любая другая. */
const IMPORT_EXTS = ['.txt', '.conf', '.ini', '.cfg', '.list', '.bat'];
let BYP = null;
const isSmartMode = () => currentStrategy === 'smart';
async function confInit(){
  const r = await ctlx(['bypass-info']);
  try { BYP = JSON.parse(r.out); } catch(e){ BYP = null; }
  if(BYP && BYP.strategy) currentStrategy = BYP.strategy;
  renderBypass();
  if(isSmartMode()) await smartLoad();
}
/* Значок вкладки, переключатель и строка на главной — по режиму */
function updateModeUi(){
  const smart = isSmartMode();
  const ic = $('nav-bypass-ic');
  if(ic) ic.setAttribute('href', smart ? '#i-auto' : '#i-config');
  document.querySelectorAll('#mode-seg .seg').forEach(b => {
    const on = (b.dataset.mode === 'smart') === smart;
    b.classList.toggle('selected', on);
    b.setAttribute('aria-checked', on ? 'true' : 'false');
  });
}
function renderBypass(){
  const smart = isSmartMode();
  updateModeUi();
  $('bypass-strat').hidden = smart;
  $('bypass-smart').hidden = !smart;
  if(!smart) renderStrat();
}
function renderStrat(){
  const b = BYP || {imports: [], modified: 0, stat: {}, meta: {}};
  const s = findStrategy(currentStrategy) || {name: currentStrategy, kind: /^imp:/.test(currentStrategy) ? 'import' : 'builtin'};
  const st = b.stat || {}, mt = b.meta || {};
  const parts = [];
  // карточка стратегии: сменить; сбросить — только если конфиг правили
  parts.push('<div class="smart-hero strat-hero">' +
    '<span class="strat-hero-ic">' + icon('globe', 's24') + '</span>' +
    '<div class="smart-hero-text">' +
      '<span class="smart-hero-sub">' + esc(groupTitle(strategyGroup(s))) + '</span>' +
      '<span class="smart-hero-level">' + esc(strategyName(currentStrategy)) + '</span>' +
      '<span class="row strat-hero-acts">' +
        '<button type="button" class="btn tonal sm state" onclick="openStrategySheet()">' + esc(t('Сменить')) + '</button>' +
        (b.modified == 1 ? '<button type="button" class="btn text sm state danger" onclick="resetConf()">' + esc(t('Сбросить правки')) + '</button>' : '') +
      '</span>' +
    '</div></div>');
  // откуда стратегия: из модуля (meta.tsv), правка её не стирает
  if(mt.author || mt.repo || mt.date){
    parts.push('<div class="strat-src">' + icon('info', 's20') + '<span>' +
      esc([mt.author ? t('Автор: {0}', mt.author) : '', mt.repo, mt.date ? t('обновлена {0}', fmtDate(mt.date)) : ''].filter(Boolean).join(' · ')) +
      (mt.edited ? '<br>' + esc(t('Ваша правка от {0}', fmtDate(mt.edited))) : '') + '</span></div>');
  }
  // статистика соединений на этой стратегии (наблюдатель smartstat)
  const ok = +st.ok || 0, err = +st.err || 0, p = pct(ok, err);
  parts.push('<h2 class="subhead">' + esc(t('Как работает')) + '</h2>');
  parts.push('<div class="smart-tiles">' + [
    {icon: 'check', title: 'Удачные', value: String(ok), sub: t('соединений открылось'), on: ''},
    {icon: 'warn', title: 'Ошибки', value: String(err), sub: t('сбросы и повторы без ответа'), on: '', tone: err > ok && err ? 'warn' : ''},
    {icon: 'status', title: 'Успешность', value: p == null ? '—' : p + '%', sub: p == null ? t('появится по ходу работы') : t('доля удачных соединений'), on: ''},
    // выбранная стратегия — файлом, как «Поделиться» в списке по долгому нажатию
    {icon: 'share', title: 'Поделиться', value: String(currentStrategy).replace(/^imp:/, '') + '.conf', sub: t('отправить стратегию файлом'),
      on: 'shareStrategy(currentStrategy)'}
  ].map(smartTile).join('') + '</div>');
  setHTML('strat-body', parts.join(''), false);
}
function fmtDate(d){
  const m = /^(\d{4})-(\d\d)-(\d\d)$/.exec(d || '');
  return m ? new Date(+m[1], +m[2] - 1, +m[3]).toLocaleDateString(LANG === 'en' ? 'en-GB' : 'ru-RU', {day: 'numeric', month: 'long', year: 'numeric'}) : (d || '');
}
/* Совместимость: правка конфига и импорт обновляют вкладку */
async function checkConfModified(){ if(currentPage === 'config') await confInit(); }
async function loadImports(){
  if(currentPage === 'config') await confInit();
  // импорты — в листе стратегий, группа «Пользовательские»
  if(openSheetId === 'strategy-sheet'){ await loadStrategies(); renderStrategyList(true); }
}
/* Импорт — из листа стратегий: файлом или вставленным текстом */
function importPick(anchor){
  openMenu(anchor, [
    {label: t('Файлом'), sub: '.txt, .conf, .bat, .ini', icon: 'file', onClick: () => $('impFile').click()},
    {label: t('Текстом'), sub: t('Вставить конфиг nfqws2-keenetic'), icon: 'edit', onClick: () => { closeSheet(); importPaste(); }}
  ]);
}
async function setBypassMode(mode){
  if((mode === 'smart') === isSmartMode()) return;
  const target = mode === 'smart' ? 'smart' : ((BYP && BYP.last) || 'hardcorp74');
  updateModeUi();
  const ok = await mdConfirm(mode === 'smart' ? t('Включить умный режим?') : t('Вернуться к стратегиям?'),
    S.running ? t('Служба будет перезапущена в другом режиме работы.') : t('Режим включится при следующем запуске службы.'),
    {ok: S.running ? t('Перезапустить') : t('Переключить')});
  if(!ok) return;
  await applyStrategy(target);
  await confInit();
}
async function resetConf(){
  const ok = await mdConfirm(t('Сбросить конфиг?'),
    t('Ручные правки nfqws2.conf будут отменены, вернётся стратегия «{0}». Прежний конфиг сохранится как .bak.', strategyName(currentStrategy)),
    {ok: t('Сбросить'), danger: true});
  if(!ok) return;
  const r = await withBusy(['reset-conf']);
  toast(r.code ? errText(r, 'Не удалось сбросить') : t('Конфиг сброшен'),
    !r.code && S.running ? {label: t('Перезапустить'), fn: restartSvc} : null);
  confInit();
  stat();
}
async function openImport(name){
  const r = await withBusy(['get-import-merged-b64', name]);
  if(r.code){ toast(errText(r, 'Импорт не найден')); return; }
  openEditorWith({
    target: 'conf', title: name, lang: 'conf',
    hint: t('Предпросмотр импорта с вашими настройками Android. «Сохранить» заменит nfqws2.conf.'),
    text: unb64(r.out.trim()), dirty: true
  });
}
async function renameImport(name){
  const v = await mdPrompt(t('Переименовать конфиг'), t('Слэши, кавычки и $ будут убраны.'), name, t('Имя'));
  if(!v || v === name) return;
  const r = await withBusy(['rename-import', name, v]);
  toast(r.code ? errText(r, 'Не удалось переименовать') : t('Переименовано'));
  loadImports();
}
async function delImport(name){
  if(!await mdConfirm(t('Удалить «{0}»?', name), t('Файл импорта будет удалён безвозвратно.'), {ok: t('Удалить'), danger: true})) return;
  const r = await withBusy(['delete-import', name]);
  toast(r.code ? errText(r, 'Не удалось удалить') : t('Удалено'));
  loadImports();
}
/* Вторая строка ответа import-add-b64 — параметры, которых нет в этой сборке
   nfqws2: модуль вырезает их при импорте, иначе nfqws2 не запустится. */
function importRemoved(r){
  const m = /^removed\t(.+)$/m.exec(r.out || '');
  return m ? t('убраны параметры, неизвестные nfqws2 этого модуля: {0}', m[1]) : '';
}
function showImportMsg(text){
  $('impMsg').textContent = text || '';
  $('impMsg').hidden = !text;
}
async function importFiles(files){
  if(!files || !files.length) return;
  let ok = 0, fail = 0;
  const errs = [];
  for(const f of files){
    const ext = (f.name.match(/\.[^.]+$/) || [''])[0].toLowerCase();
    if(!IMPORT_EXTS.includes(ext)){ fail++; errs.push(f.name + ': ' + t('расширение не подходит ({0})', IMPORT_EXTS.join(' '))); continue; }
    const r = await withBusy(['import-add-b64', b64(f.name.replace(/\.[^.]+$/, '')), b64(await f.text())]);
    if(!r.code){ ok++; const rm = importRemoved(r); if(rm) errs.push(f.name + ': ' + rm); }
    else { fail++; errs.push(f.name + ': ' + errText(r, 'отклонён')); }
  }
  $('impFile').value = '';
  showImportMsg(errs.join('\n'));
  toast(t('Импортировано: {0}', ok) + (fail ? ', ' + t('отклонено: {0}', fail) : ''));
  loadImports();
}
function importPaste(){
  openEditorWith({target: 'import-new', title: t('Новый импорт'), saveLabel: t('Импортировать'), text: '', lang: 'conf',
    hint: t('Вставьте конфиг nfqws2-keenetic целиком. Перед сохранением модуль проверит, что это действительно он.')});
}
