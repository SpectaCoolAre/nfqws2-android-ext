/* nfqws2 WebUI · lists.js — экран «Списки»
   Скрипты подключаются из index.html обычными <script> по порядку и делят одну
   глобальную область: функции и let/const одного файла видны в остальных. */

/* ══ СПИСКИ ══════════════════════════════════════════════════════════════ */
const MODE_INFO = {
  auto: 'Обходит домены из user.list и сам добавляет в auto.list те, что оказались заблокированы.',
  list: 'Обходит только домены из user.list.',
  all: 'Обходит всё, кроме доменов из exclude.list.'
};
/* На вкладке — пять главных списков. Остальные (сервисные, IP-списки
   хостингов, списки проверки и созданные пользователем) — на своём экране
   «Все списки» (alllists) */
const LIST_FILES = [
  ['auto', 'auto.list', 'Выученные автоматически', 'list'],
  ['user', 'user.list', 'Домены для обхода', 'list'],
  ['exclude', 'exclude.list', 'Домены-исключения', 'list'],
  ['ipset', 'ipset.list', 'IP-адреса и подсети для обхода', 'globe'],
  ['ipset_exclude', 'ipset_exclude.list', 'IP-исключения', 'globe']
];
/* Подписи известных списков на экране «Все списки»; остальные — без подписи */
const LIST_DESC = {
  geoblock: 'Сервисы с геоблоком — для умного режима DNS',
  google: 'Google и YouTube — свой профиль стратегий',
  discord: 'Discord — свой профиль стратегий',
  user_extra: 'Дополнительные домены стратегии hardcorp74',
  whitelist_sni: 'Имена из белых списков — для их распознавания',
  rkn: 'Домены из реестра блокировок (дополнительный)',
  ipset_as: 'Подсети хостингов — обход обрыва на 16 КБ',
  ipset_flowseal: 'Подсети сервисов из Flowseal (дополнительный)',
  ipset_cf_full: 'Подсети Cloudflare',
  ipset_amazon: 'Подсети Amazon',
  ipset_do: 'Подсети DigitalOcean',
  ipset_ovh: 'Подсети OVH',
  probe_hosts: 'Сайты для проверки доступности',
  probe_dns: 'DNS-серверы для проверки доступности',
  probe_tg: 'Адреса Telegram для проверки доступности',
  tcp16: 'Адреса для проверки обрыва на 16 КБ'
};
const LIST_GROUPS = [
  ['Списки доменов', n => !/^(ipset_|probe_)/.test(n) && n !== 'tcp16', 'list'],
  ['IP-адреса и подсети', n => /^ipset_/.test(n), 'globe'],
  ['Для проверки доступности', n => /^probe_/.test(n) || n === 'tcp16', 'test']
];
let allLists = null;
async function allListsInit(){
  if(!allLists) setHTML('all-lists', '<div class="empty">' + esc(t('Загрузка…')) + '</div>', false);
  const r = await ctlx(['list-all']);
  if(r.code){ setHTML('all-lists', banner('danger', 'error', errText(r, 'Не удалось прочитать списки')), false); return; }
  const main = new Set(LIST_FILES.map(f => f[0]));
  allLists = r.out.trim().split('\n').map(l => l.split('\t')).filter(x => x[0] && !main.has(x[0]));
  renderAllLists();
}
function renderAllLists(){
  if(!allLists) return;
  const q = ($('all-lists-q') && $('all-lists-q').value || '').trim().toLowerCase();
  const out = [];
  LIST_GROUPS.forEach(([title, fit, ic]) => {
    const rows = allLists.filter(([n]) => fit(n) && (!q || (n + ' ' + t(LIST_DESC[n] || '')).toLowerCase().includes(q)));
    if(!rows.length) return;
    out.push('<div class="stack"><h2 class="subhead">' + esc(t(title)) + '</h2><div class="list">' + rows.map(([n, c]) =>
      '<div class="list-item' + (LIST_DESC[n] ? ' two-line' : '') + ' clickable state" role="button" tabindex="0"' +
        ' onclick="openSlideEditor(' + jsArg('list') + ', ' + jsArg(n) + ')">' +
        '<span class="li-icon">' + icon(ic, 's24') + '</span>' +
        '<span class="li-text"><span class="li-primary li-mono">' + esc(n) + '.list</span>' +
          (LIST_DESC[n] ? '<span class="li-secondary">' + esc(t(LIST_DESC[n])) + '</span>' : '') + '</span>' +
        '<span class="li-trail"><span class="li-value">' + fmtCount(+c || 0) + '</span>' + icon('chevron-right', 's24') + '</span>' +
      '</div>').join('') + '</div></div>');
  });
  setHTML('all-lists', out.join('') || '<div class="empty">' + esc(t('Ничего не найдено')) + '</div>', false);
}

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
    '</div>').join('') +
    // остальные списки модуля — на своём экране
    '<div class="list-item two-line clickable state" role="button" tabindex="0" onclick="navigate(' + jsArg('alllists') + ')">' +
      '<span class="li-icon">' + icon('list', 's24') + '</span>' +
      '<span class="li-text"><span class="li-primary">' + esc(t('Все списки')) + '</span>' +
        '<span class="li-secondary">' + esc(t('Сервисные, IP-списки хостингов, для проверки и ваши')) + '</span></span>' +
      '<span class="li-trail">' + icon('chevron-right', 's24') + '</span>' +
    '</div>', false);
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
