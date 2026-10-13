/* nfqws2 WebUI · lists.js — экран «Списки»
   Скрипты подключаются из index.html обычными <script> по порядку и делят одну
   глобальную область: функции и let/const одного файла видны в остальных. */

/* ══ СПИСКИ ══════════════════════════════════════════════════════════════ */
const MODE_INFO = {
  auto: 'Обходит домены из user.list и сам добавляет в auto.list те, что оказались заблокированы.',
  list: 'Обходит только домены из user.list.',
  all: 'Обходит всё, кроме доменов из exclude.list.'
};
/* Здесь только общие списки. Сервисные (google, youtube, ipset_discord …)
   принадлежат стратегиям с отдельными профилями и приходят с релизом. */
const LIST_FILES = [
  ['auto', 'auto.list', 'Выученные автоматически', 'list'],
  ['user', 'user.list', 'Домены для обхода', 'list'],
  ['exclude', 'exclude.list', 'Домены-исключения', 'list'],
  ['ipset', 'ipset.list', 'IP-адреса и подсети для обхода', 'globe'],
  ['ipset_exclude', 'ipset_exclude.list', 'IP-исключения', 'globe'],
  ['probe_hosts', 'probe_hosts.list', 'Адреса для проверки доступности', 'wifi']
];
const pendingLists = () => String(S.pending || '').split(',').filter(Boolean);

function renderMode(){
  setHTML('mode', ['auto', 'list', 'all'].map(m =>
    '<button class="seg state' + (S.mode === m ? ' on' : '') + '" aria-pressed="' + (S.mode === m) + '"' +
    ' onclick="setMode(' + jsArg(m) + ')"><span class="check">' + icon('check', 's18') + '</span>' + m + '</button>').join(''), false);
  $('mode-desc').textContent = MODE_INFO[S.mode] ? t(MODE_INFO[S.mode]) : '';
}
function renderListFiles(){
  const c = S.counts || {}, pend = pendingLists();
  setHTML('list-files', LIST_FILES.map(([key, file, desc, ic]) =>
    '<div class="list-item two-line clickable state" role="button" tabindex="0"' +
      ' onclick="openSlideEditor(' + jsArg('list') + ', ' + jsArg(key) + ')">' +
      '<span class="li-icon">' + icon(ic, 's24') + '</span>' +
      '<span class="li-text"><span class="li-primary li-mono">' + file + '</span>' +
        '<span class="li-secondary">' + esc(pend.includes(key) ? t('Доступна новая версия из релиза') : t(desc)) + '</span></span>' +
      '<span class="li-trail">' +
        (pend.includes(key) ? '<button type="button" class="icon-btn sm state pending-btn" aria-label="' + esc(t('Доступна новая версия списка')) + '"' +
          ' onclick="event.stopPropagation(); offerListUpdate(' + jsArg(key) + ')">' + icon('warn', 's20') + '</button>' : '') +
        (c[key] != null ? '<span class="li-value">' + fmtCount(c[key]) + '</span>' : '') +
        icon('chevron-right', 's24') + '</span>' +
    '</div>').join(''), false);
}
/* Новая версия списка из релиза ждёт, пока пользователь сам решит: его
   правки установщик не трогает. «Отмена» просто оставляет всё как есть. */
async function offerListUpdate(key){
  if(!key) return;
  const ok = await mdConfirm(t('Обновить {0}.list?', key),
    t('В новой версии модуля этот список обновился, а у вас он изменён. Заменить ваш список версией из релиза? Ваши правки будут потеряны.'),
    {ok: t('Заменить'), iconName: 'warn'});
  if(!ok) return;
  const r = await withBusy(['list-update', key], 30000);
  if(r.code){ toast(errText(r, 'Не удалось обновить список')); return; }
  toast(t('{0}.list обновлён', key));
  await stat();
  renderListFiles();
  if(editorCtx && editorCtx.target === 'list' && editorCtx.key === key){
    const r2 = await ctlx(['get-list', key], 30000);
    if(!r2.code && editorCtx && editorCtx.key === key){
      $('panel-editor-text').value = r2.out;
      editorCtx.original = r2.out;
      highlightEditor();
    }
    $('panel-pending').hidden = true;
  }
}
async function setMode(m){
  const r = await withBusy(['set-mode', m]);
  const needRestart = !r.code && S.running && /перезапуск/i.test(r.out);
  toast(r.code ? errText(r, 'Не удалось сменить режим') : t('Режим: {0}', m),
    needRestart ? {label: t('Перезапустить'), fn: restartSvc} : null);
  stat();
}
async function clearAuto(){
  if(!await mdConfirm(t('Очистить auto.list?'), t('Выученные автоматически домены будут удалены.'), {ok: t('Очистить'), danger: true})) return;
  const r = await withBusy(['clear-auto']);
  toast(r.code ? errText(r, 'Не удалось очистить') : t('auto.list очищен'));
  stat();
}
async function addDom(){
  const d = $('dom').value.trim();
  if(!d) return;
  const r = await withBusy(['add-domain', d]);
  toast(r.code ? errText(r, 'Не удалось добавить') : t('Добавлено: {0}', (r.out.trim().split(': ').pop() || d)));
  if(!r.code) $('dom').value = '';
  stat();
}
async function resetLists(){
  const ok = await mdConfirm(t('Вернуть стандартные списки?'),
    t('Правки в user, exclude, ipset, ipset_exclude и probe_hosts будут удалены.'), {ok: t('Вернуть'), danger: true});
  if(!ok) return;
  const r = await withBusy(['reset-lists']);
  toast(r.code ? errText(r, 'Не удалось вернуть списки') : t('Списки возвращены к стандартным'));
  stat();
}
