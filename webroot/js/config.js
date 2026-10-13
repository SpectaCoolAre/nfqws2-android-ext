/* nfqws2 WebUI · config.js — экран «Конфиг» и импорт
   Скрипты подключаются из index.html обычными <script> по порядку и делят одну
   глобальную область: функции и let/const одного файла видны в остальных. */

/* ══ КОНФИГУРАЦИЯ И ИМПОРТ ═══════════════════════════════════════════════ */
const IMPORT_EXTS = ['.txt', '.conf', '.ini', '.cfg', '.list', '.bat'];
async function confInit(){ await Promise.all([loadImports(), checkConfModified()]); }
/* «Сбросить» видна, только когда сбрасывать есть что: действующий конфиг
   отличается от исходника текущей стратегии (без учёта переключателей). */
async function checkConfModified(){
  const [r, r2] = await Promise.all([ctlx(['conf-modified']), ctlx(['get-strategy'])]);
  if(!r2.code && r2.out.trim()) currentStrategy = r2.out.trim();
  const mod = !r.code && r.out.trim() === '1';
  const row = $('conf-reset');
  if(row.hidden === mod){
    row.hidden = !mod;
    if(mod){ row.classList.remove('appear-item'); void row.offsetWidth; row.classList.add('appear-item'); }
  }
  $('conf-reset-sub').textContent = t('Отменить ручные правки и вернуть стратегию «{0}»', strategyName(currentStrategy));
}
async function resetConf(){
  const ok = await mdConfirm(t('Сбросить конфиг?'),
    t('Ручные правки nfqws2.conf будут отменены, вернётся стратегия «{0}». Прежний конфиг сохранится как .bak.', strategyName(currentStrategy)),
    {ok: t('Сбросить'), danger: true});
  if(!ok) return;
  const r = await withBusy(['reset-conf']);
  toast(r.code ? errText(r, 'Не удалось сбросить') : t('Конфиг сброшен'),
    !r.code && S.running ? {label: t('Перезапустить'), fn: restartSvc} : null);
  checkConfModified();
  stat();
}
async function loadImports(){
  const r = await ctlx(['list-imports']);
  const names = r.code ? [] : r.out.split('\n').map(s => s.trim()).filter(Boolean);
  setHTML('impList', names.length ? names.map(n =>
    '<div class="list-item clickable state" role="button" tabindex="0" data-imp="' + esc(n) + '"' +
      ' onclick="openImport(this.dataset.imp)">' +
      '<span class="li-icon">' + icon('file', 's24') + '</span>' +
      '<span class="li-text"><span class="li-primary truncate">' + esc(n) + '</span></span>' +
      '<button class="icon-btn sm state" aria-haspopup="menu" aria-label="' + esc(t('Действия с конфигом {0}', n)) + '"' +
        ' data-imp="' + esc(n) + '" onclick="event.stopPropagation(); importMenu(this, this.dataset.imp)">' +
        icon('more', 's24') + '</button>' +
    '</div>').join('')
    : '<div class="empty"><span class="empty-icon">' + icon('upload', 's24') + '</span>' +
      '<span>' + esc(t('Импортированные конфиги появятся здесь и в выборе стратегии, в группе «Пользовательские».')) + '</span></div>');
}
function importMenu(anchor, name){
  openMenu(anchor, [
    {label: t('Применить как стратегию'), icon: 'check', onClick: () => applyStrategy('imp:' + name)},
    {label: t('Открыть'), icon: 'edit', onClick: () => openImport(name)},
    {label: t('Переименовать'), icon: 'tune', onClick: () => renameImport(name)},
    '-',
    {label: t('Удалить'), icon: 'trash', onClick: () => delImport(name)}
  ]);
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
