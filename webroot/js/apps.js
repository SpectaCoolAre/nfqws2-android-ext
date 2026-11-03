/* nfqws2 WebUI · apps.js — фильтр приложений
   Скрипты подключаются из index.html обычными <script> по порядку и делят одну
   глобальную область: функции и let/const одного файла видны в остальных. */

/* ══ ПРИЛОЖЕНИЯ ══════════════════════════════════════════════════════════ */
const APP_MODES = [
  ['off', 'Выключен', 'Обрабатывается трафик всех приложений'],
  ['include', 'Только выбранные', 'Трафик остальных приложений идёт напрямую'],
  ['exclude', 'Все, кроме выбранных', 'Выбранные приложения идут напрямую']
];
let pkgsCheckedAt = 0;
async function appsInit(){
  if(pkgs.length){
    drawPk();
    // Тихая сверка: ставили или удаляли приложения — модуль пересоберёт
    // список сам, и экран обновится без спиннера (из оригинала, 0badd3d).
    // Список везёт значки в base64 — не чаще раза в минуту (оригинал, 4bae987)
    if(Date.now() - pkgsCheckedAt > 60000){
      pkgsCheckedAt = Date.now();
      ctlx(['list-apps']).then(r => {
        const raw = (r.out || '').trim();
        if(r.code || !raw.startsWith('[')) return;
        try {
          const next = JSON.parse(raw);
          if(next.length !== pkgs.length || JSON.stringify(next) !== JSON.stringify(pkgs)){ pkgs = next; drawPk(false); }
        } catch(_) {}
      });
    }
  } else loadPk();
  // режимы — один раз, уже со свежими счётчиками (оригинал, 4bae987)
  await stat(true);
  renderAppModes();
}
function renderAppModes(){
  const cur = S.app_mode || 'off';
  setHTML('amode-list', APP_MODES.map(([v, label, hint]) =>
    '<label class="list-item two-line clickable state' + (v === cur ? ' selected' : '') + '">' +
      '<input type="radio" class="radio" name="amode" value="' + v + '"' + (v === cur ? ' checked' : '') +
        ' onchange="setAppMode(this.value)">' +
      '<span class="li-text"><span class="li-primary">' + esc(t(label)) + '</span><span class="li-secondary">' + esc(t(hint)) + '</span></span>' +
    '</label>').join(''), false);
  const n = (S.counts || {}).apps || 0;
  $('apps-info').textContent = cur === 'off'
    ? t('Фильтр выключен. Выбрано приложений: {0}.', n)
    : t('Фильтр включён. Выбрано приложений: {0}.', n) + (S.app_uids > 0 ? ' ' + t('UID найдено: {0}.', S.app_uids) : '');
}
async function setAppMode(v){
  const r = await withBusy(['set', 'APP_MODE', v], 30000);
  toast(r.code ? errText(r, 'Не удалось сменить режим') : t('Режим фильтра сохранён'));
  await stat();
  // режим не сменился — разметка та же, и выбранная кнопка осталась бы нажатой
  if(r.code) $('amode-list')._html = '';
  renderAppModes();
}
async function loadPk(force){
  clearTimeout(pkTimer);   // отменяем отложенную перерисовку от старого ввода
  $('pk').innerHTML = '<div class="list-item"><span class="spinner"></span>' +
    '<span class="li-text"><span class="li-secondary">' + esc(t('Загрузка списка приложений…')) + '</span></span></div>';
  $('pk')._html = null;
  const r = force ? await ctlx(['list-apps', 'refresh'], 30000) : await ctlx(['list-apps'], 30000);
  if(r.code){
    // уже показанный список (с названиями и иконками) не теряем
    toast(errText(r, 'Не удалось получить список приложений'));
  } else {
    const raw = (r.out || '').trim();
    if(raw.startsWith('[')){
      try {
        pkgs = JSON.parse(raw);
      } catch(_){
        pkgs = raw.split('\n').map(s => s.trim()).filter(Boolean);
      }
    } else {
      pkgs = raw.split('\n').map(s => s.trim()).filter(Boolean);
    }
  }
  await drawPk(true);
}
/* Список выбранных приложений кэшируется. drawPk() — обработчик oninput у поля
   поиска, и без кэша каждая нажатая буква запускала отдельный шелл: на телефоне
   это заметные рывки при наборе, а результат всё равно не менялся — фильтруется
   только локальный список пакетов. Кэш сбрасывается там, где список мог
   измениться помимо togglePkg(): после ручного редактирования в редакторе. */
let appsCache = null;
let appTypeFilter = 'all';

/* Рабочий профиль и другие пользователи (Shelter, Island, второе
   пространство; оригинал, aadd63e, 07dea35). Ключ в apps.list —
   «пользователь:пакет»: голый «пакет» модуль понимает как «во всех
   профилях», и выбор личной копии включал бы и рабочую. Рабочий ли профиль,
   знает генератор списка (isWork): гость или второй пользователь — тоже id > 0 */
function appUser(item){ return (typeof item === 'object' && item && item.userId != null) ? Number(item.userId) : 0; }
function isAppWork(item){
  if(typeof item !== 'object' || !item) return false;
  if(item.isWork != null) return item.isWork === true || item.isWork === 1 || item.isWork === 'true';
  return appUser(item) > 0;
}
function appPkg(item){ return typeof item === 'string' ? item : (item && item.pkg) || ''; }
function appKey(item){ return typeof item === 'string' ? item : appUser(item) + ':' + appPkg(item); }
function isAppSelected(s, item){
  const p = appPkg(item);
  return !!p && (s.has(p) || s.has(appUser(item) + ':' + p));
}

function isAppSystem(item){
  if(typeof item === 'object' && typeof item.system === 'boolean') return item.system;
  if(typeof item === 'object' && item.system != null) return item.system === true || item.system === 1 || item.system === 'true';
  const p = typeof item === 'string' ? item : (item.pkg || '');
  return p.startsWith('com.android.') || p.startsWith('android') || p.startsWith('com.google.android.packageinstaller') || p.startsWith('com.google.android.gms');
}

/* HyperOS: фильтр списка — строкой-заголовком «Показывать: … ⇅» с меню, как
   выбор сортировки в списках приложений Xiaomi; в Material 3 — чипы */
const APP_TYPES = [['all', 'Все'], ['user', 'Пользовательские'], ['system', 'Системные'], ['selected', 'Выбранные'], ['work', 'Рабочие']];
const appTypes = () => APP_TYPES.filter(a => a[0] !== 'work' || pkgs.some(isAppWork));
function renderPkSort(){
  const cur = APP_TYPES.find(a => a[0] === appTypeFilter) || APP_TYPES[0];
  if($('pk-sort')) $('pk-sort').innerHTML = '<span>' + esc(t('Показывать: {0}', t(cur[1]))) + '</span>' + icon('unfold', 's16');
}
function pickAppTypeFilter(anchor){
  openMenu(anchor, appTypes().map(([k, label]) => ({label: t(label), icon: k === appTypeFilter ? 'check' : '', onClick: () => setAppTypeFilter(k)})));
}
function setAppTypeFilter(type){
  appTypeFilter = type;
  renderPkSort();
  const wrap = $('pk-filter-chips');
  if(wrap){
    wrap.querySelectorAll('.chip').forEach(c => {
      const on = c.getAttribute('data-type') === type;
      c.classList.toggle('selected', on);
      c.setAttribute('aria-pressed', on ? 'true' : 'false');
    });
  }
  drawPk(false);
}

async function getAppsList(){
  if(appsCache) return appsCache;
  const r = await ctlx(['get-list', 'apps']);
  appsCache = new Set((r.code ? '' : r.out).split('\n').map(s => s.trim()).filter(s => s && s[0] !== '#'));
  return appsCache;
}
/* Фильтр перерисовывает до 120 строк на каждое нажатие, поэтому ввод
   придерживается: ctl уже не дёргается (кэш выше), а вот innerHTML — дорогой. */
let pkTimer = null;
function pkSearchInput(){
  clearTimeout(pkTimer);
  pkTimer = setTimeout(() => drawPk(false), 180);
}
async function drawPk(animate){
  // рабочих приложений нет (профиль удалили) — и фильтра по ним нет
  const hasWork = pkgs.some(isAppWork);
  if($('pk-chip-work')) $('pk-chip-work').hidden = !hasWork;
  if(!hasWork && appTypeFilter === 'work'){ setAppTypeFilter('all'); return; }
  renderPkSort();
  const f = $('pf').value.trim().toLowerCase();
  const s = await getAppsList();
  const shown = pkgs.filter(item => {
    const p = appPkg(item);
    const n = typeof item === 'string' ? item : (item.name || item.pkg || '');
    const matchSearch = !f || p.toLowerCase().includes(f) || n.toLowerCase().includes(f);
    if(!matchSearch) return false;
    if(appTypeFilter === 'all') return true;
    if(appTypeFilter === 'selected') return isAppSelected(s, item);
    if(appTypeFilter === 'work') return isAppWork(item);
    const isSys = isAppSystem(item);
    if(appTypeFilter === 'system') return isSys;
    if(appTypeFilter === 'user') return !isSys;
    return true;
  });
  shown.sort((a, b) => {
    const sa = isAppSelected(s, a) ? 1 : 0;
    const sb = isAppSelected(s, b) ? 1 : 0;
    if(sa !== sb) return sb - sa;
    const na = typeof a === 'string' ? a : (a.name || a.pkg || '');
    const nb = typeof b === 'string' ? b : (b.name || b.pkg || '');
    return na.localeCompare(nb, undefined, { sensitivity: 'base' }) || appUser(a) - appUser(b);
  });
  // выбрано — приложений, а не записей: личная и рабочая копия — одно
  const nSel = new Set([...s].map(k => k.replace(/^\d+:/, ''))).size;
  $('pk-count').textContent = t('Найдено {0} из {1}, выбрано {2}', shown.length, pkgs.length, nSel) +
    (shown.length > 120 ? '. ' + t('Показаны первые 120, уточните поиск') : '');
  const slice = shown.slice(0, 120);
  /* class="sel-single sel-first sel-mid sel-last" */
  setHTML('pk', slice.map((item, idx) => {
    const p = typeof item === 'string' ? item : item.pkg;
    const name = typeof item === 'string' ? item : (item.name || item.pkg);
    const icon = typeof item === 'object' && item.icon ? item.icon : '';
    const isSys = isAppSystem(item);
    const uName = typeof item === 'object' && item && item.userName ? item.userName : '';
    const badge = (isSys ? ' · ' + esc(t('Системное')) : '') +
      (isAppWork(item) ? ' · ' + esc(uName || t('Рабочий профиль')) : '');
    const sel = isAppSelected(s, item);
    let selCls = '';
    if(sel){
      const prev = idx > 0 && isAppSelected(s, slice[idx - 1]);
      const next = idx < slice.length - 1 && isAppSelected(s, slice[idx + 1]);
      if(!prev && !next) selCls = ' sel-single';
      else if(!prev && next) selCls = ' sel-first';
      else if(prev && next) selCls = ' sel-mid';
      else selCls = ' sel-last';
    }
    const iconHtml = icon
      ? '<img class="app-ico" src="' + esc(icon) + '" alt="" loading="lazy">'
      : '<span class="app-ico-fallback"><svg class="icon s24" aria-hidden="true"><use href="#i-apps"/></svg></span>';
    return '<label class="list-item two-line clickable state' + (sel ? ' selected' + selCls : '') + '">' +
      '<span class="li-icon plain app-ico-cell">' + iconHtml + '</span>' +
      '<span class="li-text">' +
        '<span class="li-primary">' + esc(name) + '</span>' +
        '<span class="li-secondary li-mono">' + esc(p) + badge + '</span>' +
      '</span>' +
      '<span class="li-trail">' +
        '<input type="checkbox" class="checkbox" data-key="' + esc(appKey(item)) + '" data-pkg="' + esc(p) + '"' + (sel ? ' checked' : '') + '>' +
      '</span>' +
    '</label>';
  }).join('') ||
    '<div class="list-item"><span class="li-text"><span class="li-secondary">' + esc(t('Ничего не найдено')) + '</span></span></div>', !!animate, false);
  $('pk').querySelectorAll('input[data-key]').forEach(cb => {
    cb.onchange = () => togglePkg(cb.getAttribute('data-key'), cb.getAttribute('data-pkg'), cb.checked);
  });
}
/* Сохранения идут по очереди: параллельные save-list-b64 со снимками списка
   могли лечь в обратном порядке, и одно переключение терялось */
let pkSave = Promise.resolve();
function togglePkg(key, p, want){
  return (pkSave = pkSave.then(() => togglePkgNow(key, p, want), () => togglePkgNow(key, p, want)));
}
async function togglePkgNow(key, p, want){
  const s = await getAppsList();
  // s — тот же Set, что лежит в кэше: он мутируется на месте, так что кэш уже
  // актуален и перечитывать список после сохранения не нужно.
  const before = new Set(s);
  if(want) s.add(key);
  else {
    s.delete(key);
    // запись без профиля («во всех профилях») снимается с этой копии, а
    // другие копии того же приложения остаются выбранными (оригинал, 07dea35)
    if(s.has(p)){
      s.delete(p);
      pkgs.forEach(o => { if(appPkg(o) === p && appKey(o) !== key) s.add(appKey(o)); });
    }
  }
  const r = await withBusy(['save-list-b64', 'apps', b64([...s].join('\n'))], 30000);
  // не сохранилось — вернуть кэш к тому, что на диске
  if(r.code){ s.clear(); before.forEach(k => s.add(k)); }
  const name = (pkgs.find(o => appKey(o) === key) || {}).name || p;
  if(r.code) toast(errText(r, 'Не удалось сохранить'), {label: t('Повторить'), fn: () => togglePkg(key, p, want)});
  else toast((want ? t('Добавлено: {0}', name) : t('Убрано: {0}', name)));
  await drawPk(false);
  await stat(true);
  renderAppModes();
}
