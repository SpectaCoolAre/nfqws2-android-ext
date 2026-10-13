/* nfqws2 WebUI · hosts.js — редактор hosts без перезагрузки
   Логика — как у bindhosts (https://github.com/bindhosts/bindhosts): свой файл
   монтируется поверх /system/etc/hosts и правится на месте. hosts из двух
   частей: обход ограничений (bypass.txt, правится здесь, пресет — один) и
   блокировка рекламы (block.txt, собирается из источников и своих доменов;
   огромный, поэтому не открывается — только число и файл).
   Скрипты подключаются из index.html обычными <script> по порядку и делят одну
   глобальную область: функции и let/const одного файла видны в остальных. */

let hostsSt = {status: {}, presets: [], urls: []}, hostsLoaded = false;

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
  const r = await ctlx(['hosts-state'], 30000);
  if(r.code && !r.out){ toast(errText(r, 'Не удалось прочитать настройки hosts')); return false; }
  hostsSt = parseHostsState(r.out);
  hostsLoaded = true;
  snapSet('hosts', r.out);
  return true;
}
async function hostsInit(){
  if(!hostsLoaded){
    const snap = snapGet('hosts');   // слепок прошлого открытия — сразу, свежее следом
    if(snap){ hostsSt = parseHostsState(snap); hostsLoaded = true; snapLock('hosts', true); }
    renderHosts();
  }
  const ok = await loadHostsState();
  snapLock('hosts', false);
  if(ok) renderHosts();
}

const hostsPath = name => (hostsSt.status.dir || '/data/adb/nfqws2/hosts') + '/' + name;
/* Строка файла: имя и путь, по нажатию — «Поделиться» (большой — только файлом) */
function hostsFileRow(name, big){
  const p = hostsPath(name);
  return settingsRow({icon: 'share', title: name, sub: p, menu: !big,
    on: big ? 'shareFile(\'file\', ' + jsArg(p) + ')' : 'shareFileMenu(this, ' + jsArg(p) + ')'});
}

function renderHosts(){
  const s = hostsSt.status, on = s.enabled === '1', fmt = n => fmtCount(+n || 0);
  $('hosts-toggle').checked = on;
  $('hosts-main').classList.toggle('on', on);
  const w = [];
  if(s.conflicts) w.push(banner('warn', 'warn', t('Hosts уже меняет модуль {0}. Отключите его, чтобы включить свой hosts здесь.', s.conflicts)));
  if(on && s.mounted !== '1') w.push(banner('danger', 'error', t('Свой hosts включён, но не подключён к системе. Выключите и включите его снова или перезагрузите телефон.')));
  if(on && s.differs === '1') w.push(banner('', 'info', t('Файлы частей и подключённый hosts различаются: их правили вне WebUI.')) +
    '<div class="row">' +
      '<button class="btn tonal state" onclick="hostsSync(\'apply\')">' + esc(t('Применить файлы')) + '</button>' +
      '<button class="btn text state" onclick="hostsSync(\'import\')">' + esc(t('Взять из hosts')) + '</button>' +
    '</div>');
  setHTML('hosts-warn', hostsLoaded ? w.join('') : '', false);

  const bp = hostsSt.presets.find(p => p.id === s.bypass_preset);
  setHTML('hosts-bypass',
    settingsRow({icon: 'edit', title: 'Записи обхода',
      sub: t('Записей: {0}', fmt(s.bypass)) + (bp ? ' · ' + bp.name : ''), on: "editHostsFile('bypass')", chevron: true}) +
    settingsRow({icon: 'download', title: 'Загрузить пресет', sub: t('GeoHide или dns.malw.link — заменит записи обхода'),
      on: 'hostsBypassMenu(this)', menu: true}) +
    hostsFileRow('bypass.txt'), false);

  setHTML('hosts-block',
    settingsRow({icon: 'shield', title: 'Заблокировано доменов', value: fmt(s.blocked)}) +
    settingsRow({icon: 'edit', title: 'Свои домены', sub: t('Доменов: {0}', fmt(s.block_custom)), on: "editHostsFile('block_custom')", chevron: true}) +
    settingsRow({icon: 'add', title: 'Добавить домены', sub: t('Один или несколько через пробел или запятую'), on: 'hostsBlockAdd()'}) +
    settingsRow({icon: 'list', title: 'Исключения', sub: t('Домены, которые не блокировать'), on: "editHostsFile('whitelist')", chevron: true}) +
    hostsFileRow('block.txt', true), false);

  const sw = (id, name, sub, checked, dis) =>
    '<label class="list-item two-line clickable state">' +
      '<span class="li-icon">' + icon('shield', 's24') + '</span>' +
      '<span class="li-text"><span class="li-primary">' + esc(name) + '</span>' +
        '<span class="li-secondary">' + esc(sub) + '</span></span>' +
      '<span class="li-trail"><input type="checkbox" class="switch" role="switch"' + (checked ? ' checked' : '') + (dis ? ' disabled' : '') +
        ' aria-label="' + esc(name) + '" onchange="setHostsPreset(' + jsArg(id) + ', this.checked, this)"></span>' +
    '</label>';
  const rows = hostsSt.presets.filter(p => p.block === '1').map(p =>
    sw(p.id, p.name || p.id, t(p.block_desc || p.desc || '') + (p.count ? ' · ' + t('доменов: {0}', fmt(p.count)) : ''), p.enabled === '1'))
  .concat(hostsSt.urls.map(u =>
    '<div class="list-item two-line">' +
      '<span class="li-icon">' + icon('download', 's24') + '</span>' +
      '<span class="li-text"><span class="li-primary truncate">' + esc(u.url.replace(/^https?:\/\//, '')) + '</span>' +
        '<span class="li-secondary">' + esc(u.count ? t('доменов: {0}', fmt(u.count)) : t('ещё не скачан')) + '</span></span>' +
    '</div>'));
  if(+s.imported) rows.push(
    '<div class="list-item two-line">' +
      '<span class="li-icon">' + icon('file', 's24') + '</span>' +
      '<span class="li-text"><span class="li-primary">' + esc(t('Из прежнего hosts')) + '</span>' +
        '<span class="li-secondary">' + esc(t('доменов: {0}', fmt(s.imported))) + '</span></span>' +
    '</div>');
  setHTML('hosts-sources', rows.join(''), false);
}

async function setHostsEnabled(on, el){
  const r = await withBusy(['hosts-set-enabled', on ? '1' : '0'], 120000);
  if(r.code){ toast(errText(r, 'Не удалось переключить hosts')); el.checked = !on; return; }
  toast(on ? t('Свой hosts подключён') : t('Возвращён системный hosts'));
  await hostsInit();
}
async function hostsSync(how){
  if(how === 'import' && !await mdConfirm(t('Взять из hosts?'),
    t('Записи обхода заменятся частью из hosts; новые домены блокировки попадут в свои, удалённые — в исключения.'), {ok: t('Взять')})) return;
  const r = await withBusy(['hosts-sync', how], 120000);
  if(r.code) toast(errText(r, 'Не удалось синхронизировать'));
  else toast(how === 'apply' ? t('Сохранено и применено') : t('Файлы частей обновлены'));
  await hostsInit();
}
/* Пресет обхода — один: на домен резолвер берёт одну запись, а смесь адресов
   разных сервисов для одного сайта ломает его чаще, чем помогает */
function hostsBypassMenu(anchor){
  openMenu(anchor, hostsSt.presets.filter(p => p.bypass === '1').map(p =>
    ({label: p.name || p.id, sub: t(p.desc || ''), icon: 'globe', onClick: () => loadBypassPreset(p)})));
}
async function loadBypassPreset(p){
  if(!await mdConfirm(t('Загрузить {0}?', p.name || p.id),
    t('Записи обхода заменятся записями пресета. Пресеты не смешиваются: для одного домена работает только одна запись.'),
    {ok: t('Заменить'), iconName: 'download'})) return;
  toast(t('Скачиваю пресет…'));
  const r = await withBusy(['hosts-bypass-preset', p.id], 120000);
  if(r.code) toast(errText(r, 'Не удалось загрузить пресет'));
  else toast(t('Пресет {0} загружен', p.name || p.id));
  await hostsInit();
}
async function setHostsPreset(id, on, el){
  if(on) toast(t('Скачиваю источник…'));
  const r = await withBusy(['hosts-preset', id, on ? '1' : '0'], 120000);
  if(r.code){
    toast(errText(r, 'Не удалось изменить источник'));
    // состояние прежнее — сброс кэша, чтобы переключатель вернулся на место
    $('hosts-sources')._html = '';
  }
  await hostsInit();
}
async function hostsBlockAdd(){
  const v = await mdPrompt(t('Заблокировать домены'), t('Через пробел или запятую. Много доменов удобнее вставить в «Свои домены».'), '', t('Домены'), {ok: t('Добавить')});
  if(!v) return;
  const r = await withBusy(['hosts-block-add', v], 120000);
  if(r.code){ toast(errText(r, 'Не удалось добавить')); return; }
  toast(t('Добавлено доменов: {0}', (r.out || '').trim()));
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
  else toast(res.length ? t('Обновлено источников: {0} из {1}', ok, res.length) : t('Источники не выбраны — собраны только свои домены'));
  await hostsInit();
}

const HOSTS_FILES = {
  bypass: ['Записи обхода', 'По одной записи на строку: IP и домен, например 1.2.3.4 example.com. Строки с # игнорируются. Сохранение применяется сразу.'],
  block_custom: ['Свои домены', 'Домены для блокировки, по одному на строку. Сохранение применяется сразу.'],
  whitelist: ['Исключения', 'Домены, которые не блокировать, по одному на строку; поддомены тоже не блокируются.'],
  sources: ['Свои ссылки', 'Ссылки на файлы hosts для блокировки, по одной на строку. Включённые пресеты записаны как preset:<имя>. После сохранения нажмите «Обновить источники».']
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
