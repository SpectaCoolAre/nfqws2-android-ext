/* nfqws2 WebUI · apps.js — фильтр приложений
   Скрипты подключаются из index.html обычными <script> по порядку и делят одну
   глобальную область: функции и let/const одного файла видны в остальных. */

/* ══ ПРИЛОЖЕНИЯ ══════════════════════════════════════════════════════════ */
const APP_MODES = [
  ['off', 'Выключен', 'Обрабатывается трафик всех приложений'],
  ['include', 'Только выбранные', 'Трафик остальных приложений идёт напрямую'],
  ['exclude', 'Все, кроме выбранных', 'Выбранные приложения идут напрямую']
];
async function appsInit(){
  renderAppModes();
  if(pkgs.length) drawPk(); else loadPk();
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
    pkgs = [];
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

function isAppSystem(item){
  if(typeof item === 'object' && typeof item.system === 'boolean') return item.system;
  if(typeof item === 'object' && item.system != null) return item.system === true || item.system === 1 || item.system === 'true';
  const p = typeof item === 'string' ? item : (item.pkg || '');
  return p.startsWith('com.android.') || p.startsWith('android') || p.startsWith('com.google.android.packageinstaller') || p.startsWith('com.google.android.gms');
}

function setAppTypeFilter(type){
  appTypeFilter = type;
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
  const f = $('pf').value.trim().toLowerCase();
  const s = await getAppsList();
  const shown = pkgs.filter(item => {
    const p = typeof item === 'string' ? item : (item.pkg || '');
    const n = typeof item === 'string' ? item : (item.name || item.pkg || '');
    const matchSearch = !f || p.toLowerCase().includes(f) || n.toLowerCase().includes(f);
    if(!matchSearch) return false;
    if(appTypeFilter === 'all') return true;
    if(appTypeFilter === 'selected') return s.has(p);
    const isSys = isAppSystem(item);
    if(appTypeFilter === 'system') return isSys;
    if(appTypeFilter === 'user') return !isSys;
    return true;
  });
  shown.sort((a, b) => {
    const pa = typeof a === 'string' ? a : a.pkg;
    const pb = typeof b === 'string' ? b : b.pkg;
    const sa = s.has(pa) ? 1 : 0;
    const sb = s.has(pb) ? 1 : 0;
    if(sa !== sb) return sb - sa;
    const na = typeof a === 'string' ? a : (a.name || a.pkg || '');
    const nb = typeof b === 'string' ? b : (b.name || b.pkg || '');
    return na.localeCompare(nb, undefined, { sensitivity: 'base' });
  });
  $('pk-count').textContent = t('Найдено {0} из {1}, выбрано {2}', shown.length, pkgs.length, s.size) +
    (shown.length > 120 ? '. ' + t('Показаны первые 120, уточните поиск') : '');
  const slice = shown.slice(0, 120);
  /* class="sel-single sel-first sel-mid sel-last" */
  setHTML('pk', slice.map((item, idx) => {
    const p = typeof item === 'string' ? item : item.pkg;
    const name = typeof item === 'string' ? item : (item.name || item.pkg);
    const icon = typeof item === 'object' && item.icon ? item.icon : '';
    const isSys = isAppSystem(item);
    const badge = isSys ? ' · ' + esc(t('Системное')) : '';
    const sel = s.has(p);
    let selCls = '';
    if(sel){
      const prev = idx > 0 && s.has(typeof slice[idx - 1] === 'string' ? slice[idx - 1] : slice[idx - 1].pkg);
      const next = idx < slice.length - 1 && s.has(typeof slice[idx + 1] === 'string' ? slice[idx + 1] : slice[idx + 1].pkg);
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
        '<input type="checkbox" class="checkbox" data-pkg="' + esc(p) + '"' + (sel ? ' checked' : '') + '>' +
      '</span>' +
    '</label>';
  }).join('') ||
    '<div class="list-item"><span class="li-text"><span class="li-secondary">' + esc(t('Ничего не найдено')) + '</span></span></div>', !!animate);
  $('pk').querySelectorAll('input[data-pkg]').forEach(cb => {
    cb.onchange = () => togglePkg(cb.getAttribute('data-pkg'), cb.checked);
  });
}
/* Сохранения идут по очереди: параллельные save-list-b64 со снимками списка
   могли лечь в обратном порядке, и одно переключение терялось */
let pkSave = Promise.resolve();
function togglePkg(p, want){
  return (pkSave = pkSave.then(() => togglePkgNow(p, want), () => togglePkgNow(p, want)));
}
async function togglePkgNow(p, want){
  const s = await getAppsList();
  // s — тот же Set, что лежит в кэше: он мутируется на месте, так что кэш уже
  // актуален и перечитывать список после сохранения не нужно.
  if(want) s.add(p); else s.delete(p);
  const r = await withBusy(['save-list-b64', 'apps', b64([...s].join('\n'))], 30000);
  // не сохранилось — вернуть кэш к тому, что на диске
  if(r.code){ if(want) s.delete(p); else s.add(p); }
  if(r.code) toast(errText(r, 'Не удалось сохранить'), {label: t('Повторить'), fn: () => togglePkg(p, want)});
  else toast((want ? t('Добавлено: {0}', p) : t('Убрано: {0}', p)));
  await drawPk(false);
  await stat(true);
  renderAppModes();
}
