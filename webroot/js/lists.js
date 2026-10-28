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
  ['geoblock', 'geoblock.list', 'Сервисы с геоблоком — для умного режима DNS', 'globe'],
  ['probe_hosts', 'probe_hosts.list', 'Адреса для проверки доступности', 'wifi']
];

function renderMode(){
  setHTML('mode', ['auto', 'list', 'all'].map(m =>
    '<button class="seg state' + (S.mode === m ? ' on' : '') + '" aria-pressed="' + (S.mode === m) + '"' +
    ' onclick="setMode(' + jsArg(m) + ')"><span class="check">' + icon('check', 's18') + '</span>' + m + '</button>').join(''), false);
  $('mode-desc').textContent = MODE_INFO[S.mode] ? t(MODE_INFO[S.mode]) : '';
}
function renderListFiles(){
  const c = S.counts || {};
  setHTML('list-files', LIST_FILES.map(([key, file, desc, ic]) =>
    '<div class="list-item two-line clickable state" role="button" tabindex="0"' +
      ' onclick="openSlideEditor(' + jsArg('list') + ', ' + jsArg(key) + ')">' +
      '<span class="li-icon">' + icon(ic, 's24') + '</span>' +
      '<span class="li-text"><span class="li-primary li-mono">' + file + '</span>' +
        '<span class="li-secondary">' + esc(t(desc)) + '</span></span>' +
      '<span class="li-trail">' +
        (c[key] != null ? '<span class="li-value">' + fmtCount(c[key]) + '</span>' : '') +
        icon('chevron-right', 's24') + '</span>' +
    '</div>').join(''), false);
  renderExtraLists();
}
/* Дополнительные списки: скачиваются по запросу, а не идут с модулем —
   rkn.list (zapret4rocket, ~125 тыс. доменов) и ipset Flowseal (подсети
   сервисов, в т.ч. Cloudflare). Ключ, id, файл, описание, поле json-status */
const EXTRA_LISTS = [
  ['EXTRA_RKN', 'rkn', 'rkn.list', 'Домены из реестра блокировок (zapret4rocket)', 'extra_rkn'],
  ['EXTRA_FLOWSEAL', 'flowseal', 'ipset_flowseal.list', 'Подсети сервисов из Flowseal', 'extra_flowseal']
];
function renderExtraLists(){
  const c = S.counts || {};
  const rows = EXTRA_LISTS.map(([key, id, file, desc, f]) => settingsRow({
    icon: id === 'rkn' ? 'list' : 'globe', title: file, sw: true, checked: S[f] == 1,
    sub: t(desc) + (c[id] ? ' · ' + fmtCount(c[id]) : ''), on: 'toggleExtraList(' + jsArg(id) + ', this.checked)'}));
  if(EXTRA_LISTS.some(e => S[e[4]] == 1))
    rows.push(settingsRow({icon: 'restart', title: 'Обновить дополнительные списки', sub: t('Скачать свежие версии включённых списков'), on: 'updateExtraLists()'}));
  setHTML('extra-lists', rows.join(''), false);
}
async function toggleExtraList(id, on){
  const e = EXTRA_LISTS.find(x => x[1] === id);
  if(on) toast(t('Скачивание {0}…', e[2]));
  const r = await withBusy(['set', e[0], on ? '1' : '0'], 120000);
  if(r.code){ toast(errText(r, 'Не удалось сохранить')); $('extra-lists')._html = ''; }
  else { S[e[4]] = on ? 1 : 0; toast(on ? t('{0} подключён', e[2]) : t('{0} отключён', e[2])); }
  renderExtraLists(); stat();
}
async function updateExtraLists(){
  const on = EXTRA_LISTS.filter(e => S[e[4]] == 1);
  toast(t('Обновление списков…'));
  const bad = [];
  for(const e of on){ const r = await withBusy(['extra-list-update', e[1]], 120000); if(r.code) bad.push(e[2]); }
  toast(bad.length ? t('Не удалось обновить: {0} — старый оставлен', bad.join(', ')) : t('Списки обновлены'));
  stat();
}
async function setMode(m){
  // прежний режим — для быстрого действия «Режим работы» на вкладке «Списки»
  if(S.mode && S.mode !== m) store.set('nfq_prev_mode', S.mode);
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
