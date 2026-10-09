/* nfqws2 WebUI · hosts.js — редактор hosts без перезагрузки
   Логика — как у bindhosts (https://github.com/bindhosts/bindhosts): свой файл
   монтируется поверх /system/etc/hosts и правится на месте. Здесь — экран:
   включение, свои записи, исключения, пресеты-источники и их обновление.
   Скрипты подключаются из index.html обычными <script> по порядку и делят одну
   глобальную область: функции и let/const одного файла видны в остальных. */

let hostsSt = {status: {}, presets: [], urls: []}, hostsLoaded = false;
const HOSTS_KIND_ICON = {block: 'shield', redirect: 'globe'};

/* hosts-state: «#status» с ключ=значение, затем «#preset <id>» и «#url» */
function parseHostsState(text){
  const st = {status: {}, presets: [], urls: []};
  let cur = st.status;
  for(const line of (text || '').split('\n')){
    if(line === '#status'){ cur = st.status; continue; }
    if(line.startsWith('#preset ')){ cur = {id: line.slice(8).trim()}; st.presets.push(cur); continue; }
    if(line === '#url'){ cur = {}; st.urls.push(cur); continue; }
    const i = line.indexOf('=');
    if(i > 0) cur[line.slice(0, i).toLowerCase()] = line.slice(i + 1);
  }
  return st;
}
async function loadHostsState(){
  const r = await ctlx(['hosts-state'], 20000);
  if(r.code && !r.out){ toast(errText(r, 'Не удалось прочитать настройки hosts')); return false; }
  hostsSt = parseHostsState(r.out);
  hostsLoaded = true;
  return true;
}
async function hostsInit(){
  if(!hostsLoaded) renderHosts();
  if(await loadHostsState()) renderHosts();
}

function renderHosts(){
  const s = hostsSt.status, on = s.enabled === '1';
  $('hosts-toggle').checked = on;
  $('hosts-main').classList.toggle('on', on);
  const w = [];
  if(s.conflicts) w.push(banner('warn', 'warn', t('Hosts уже меняет модуль {0}. Отключите его, чтобы включить свой hosts здесь.', s.conflicts)));
  if(on && s.mounted !== '1') w.push(banner('danger', 'error', t('Свой hosts включён, но не подключён к системе. Выключите и включите его снова или перезагрузите телефон.')));
  setHTML('hosts-warn', hostsLoaded ? w.join('') : '', false);
  const fmt = n => fmtCount(+n || 0);
  setHTML('hosts-general',
    settingsRow({icon: 'edit', title: 'Мои записи', sub: t('Записей: {0} · важнее источников', fmt(s.custom)), on: "editHostsFile('custom')", chevron: true}) +
    settingsRow({icon: 'shield', title: 'Исключения', sub: t('Домены, которые не брать из источников'), on: "editHostsFile('whitelist')", chevron: true}) +
    settingsRow({icon: 'file', title: 'Текущий hosts', sub: on && s.mounted === '1'
      ? t('Блокировок: {0} · перенаправлений: {1}', fmt(s.blocked), fmt(s.redirects))
      : t('Системный файл'), on: 'viewHostsCurrent()', chevron: true}), false);
  $('hosts-built').textContent = s.built ? t('собран {0}', s.built) : '';
  const rows = hostsSt.presets.map(p => {
    const sub = t(p.desc || '') + (p.count ? ' · ' + t('записей: {0}', fmt(p.count)) : '');
    return '<label class="list-item two-line clickable state">' +
      '<span class="li-icon">' + icon(HOSTS_KIND_ICON[p.kind] || 'shield', 's24') + '</span>' +
      '<span class="li-text"><span class="li-primary">' + esc(p.name || p.id) + '</span>' +
        '<span class="li-secondary">' + esc(sub) + '</span></span>' +
      '<span class="li-trail"><input type="checkbox" class="switch" role="switch"' + (p.enabled === '1' ? ' checked' : '') +
        ' aria-label="' + esc(p.name || p.id) + '" onchange="setHostsPreset(' + jsArg(p.id) + ', this.checked, this)"></span>' +
    '</label>';
  }).concat(hostsSt.urls.map(u =>
    '<div class="list-item two-line">' +
      '<span class="li-icon">' + icon('download', 's24') + '</span>' +
      '<span class="li-text"><span class="li-primary truncate">' + esc(u.url.replace(/^https?:\/\//, '')) + '</span>' +
        '<span class="li-secondary">' + esc(u.count ? t('записей: {0}', fmt(u.count)) : t('ещё не скачан')) + '</span></span>' +
    '</div>'));
  setHTML('hosts-sources', rows.join(''), false);
}

async function setHostsEnabled(on, el){
  const r = await withBusy(['hosts-set-enabled', on ? '1' : '0'], 120000);
  if(r.code){ toast(errText(r, 'Не удалось переключить hosts')); el.checked = !on; return; }
  toast(on ? t('Свой hosts подключён') : t('Возвращён системный hosts'));
  await hostsInit();
}
async function setHostsPreset(id, on, el){
  if(on) toast(t('Скачиваю источник…'));
  const r = await withBusy(['hosts-preset', id, on ? '1' : '0'], 120000);
  if(r.code) toast(errText(r, 'Не удалось изменить источник'));
  if(r.code && !on) el.checked = true;
  await hostsInit();
}
async function updateHostsSources(){
  const b = $('hosts-update');
  b.disabled = true;
  const res = [];
  const r = await withBusy(['hosts-update'], 300000);
  b.disabled = false;
  (r.out || '').split('\n').forEach(l => { const p = l.split('\t'); if(p[0] === 'S') res.push(p); });
  const ok = res.filter(p => /^ok/.test(p[2])).length;
  if(r.code) toast(errText(r, 'Не удалось обновить источники'));
  else toast(res.length ? t('Обновлено источников: {0} из {1}', ok, res.length) : t('Источники не выбраны — собраны только свои записи'));
  await hostsInit();
}

const HOSTS_FILES = {
  custom: ['Мои записи', 'По одной записи на строку: IP и домен, например 1.2.3.4 example.com. Строки с # игнорируются. Сохранение применяется сразу.'],
  whitelist: ['Исключения', 'Домены, которые не нужно брать из источников, по одному на строку; поддомены тоже исключаются. Свои записи не затрагиваются.'],
  sources: ['Свои ссылки', 'Ссылки на файлы hosts, по одной на строку. Включённые пресеты записаны как preset:<имя>. После сохранения нажмите «Обновить источники».']
};
function editHostsFile(key){
  const [title, hint] = HOSTS_FILES[key];
  openEditorWith({target: 'hosts', title: t(title), lang: 'list', hint: t(hint), load: ['hosts-get', key],
    onSave: async val => {
      const r = await withBusy(['hosts-save-b64', key, b64(val.replace(/\s*$/, '\n'))], 120000);
      if(r.code) return errText(r, 'Не удалось сохранить');
      toast(hostsSt.status.enabled === '1' && key !== 'sources' ? t('Сохранено и применено') : t('Сохранено'));
      hostsInit();
      return '';
    }});
}
function viewHostsCurrent(){
  openEditorWith({target: 'hosts', title: '/system/etc/hosts', lang: 'list', readonly: true,
    hint: t('Только просмотр: то, что сейчас видит система.'), load: ['hosts-get', 'current']});
}
