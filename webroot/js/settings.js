/* nfqws2 WebUI · settings.js — настройки, домашняя Wi‑Fi, резервная копия
   Скрипты подключаются из index.html обычными <script> по порядку и делят одну
   глобальную область: функции и let/const одного файла видны в остальных. */

/* ══ НАСТРОЙКИ ═══════════════════════════════════════════════════════════
   Как настройки Android: группы с заголовком, у каждой строки — пояснение. */
function settingsRow(o){
  if(o.sw){
    return '<label class="list-item' + (o.sub ? ' two-line' : '') + ' clickable state">' +
      '<span class="li-icon">' + icon(o.icon, 's24') + '</span>' +
      '<span class="li-text"><span class="li-primary">' + esc(t(o.title)) + '</span>' +
        (o.sub ? '<span class="li-secondary">' + esc(o.sub) + '</span>' : '') + '</span>' +
      '<span class="li-trail"><input type="checkbox" class="switch" role="switch" aria-label="' + esc(t(o.title)) + '"' +
        (o.checked ? ' checked' : '') + (o.id ? ' id="' + esc(o.id) + '"' : '') +
        ' onchange="' + o.on + '"></span>' +
    '</label>';
  }
  return '<div class="list-item' + (o.sub ? ' two-line' : '') + (o.on ? ' clickable state" role="button" tabindex="0"' +
      (o.menu ? ' aria-haspopup="menu"' : '') + ' onclick="' + o.on + '"' : '"') + '>' +
    '<span class="li-icon">' + icon(o.icon, 's24') + '</span>' +
    '<span class="li-text"><span class="li-primary">' + esc(t(o.title)) + '</span>' +
      (o.sub ? '<span class="li-secondary">' + esc(o.sub) + '</span>' : '') + '</span>' +
    (o.value ? '<span class="li-trail li-value">' + esc(o.value) + '</span>' : '') +
    (o.chevron ? '<span class="li-trail">' + icon('chevron-right', 's24') + '</span>' : '') +
  '</div>';
}
function renderSettings(){
  const homeN = S.home_wifi == 1 ? t('Включено') : t('Выключено');
  const groups = [
    ['Работа', [
      {icon: 'home', title: 'Домашняя Wi‑Fi', sub: t('Пауза обхода в домашних сетях') + ' · ' + homeN, on: "navigate('wifi')", chevron: true},
      {icon: 'refresh', title: 'Стратегии по сетям', sub: t('Запоминать стратегию отдельно для каждой сети'), sw: true, checked: S.net_strategy == 1, on: 'toggleNetStrategy(this.checked)'}
    ]],
    ['Инструменты', [
      {icon: 'apps', title: 'Фильтр приложений', sub: t('Обход только для выбранных приложений или для всех, кроме них'), on: "navigate('apps')", chevron: true},
      {icon: 'test', title: 'Проверка доступности', sub: t('Открывает адреса из probe_hosts.list через обход'), on: "navigate('test')", chevron: true},
      {icon: 'medical', title: 'Диагностика', sub: t('Ядро, правила iptables и аргументы запуска'), on: "navigate('diag')", chevron: true}
    ].concat(S.dns_available == 1 ? [
      // только если в модуле есть dnsproxy
      {icon: 'dns', title: 'DNS по профилям', sub: t('Свои DoH, DoT и DNS-серверы для выбранных доменов'), on: "navigate('dns')", chevron: true}
    ] : [])],
    ['Резервная копия', [
      {icon: 'download', title: 'Создать копию', sub: t('Конфиг, списки, стратегии и оформление — в архив .tar'), on: 'createBackup()'},
      {icon: 'upload', title: 'Восстановить из копии', sub: t('Выбрать архив .tar или из списка'), on: 'openBackupSheet()'}
    ]],
    ['Оформление', [
      {icon: 'palette', title: 'Тема оформления', sub: t('Светлая, тёмная, AMOLED и цвет акцента'), on: 'openMonetModal()'},
      {icon: 'motion', title: 'Отключение анимаций', sw: true, checked: isAnimationsDisabled(), id: 'animations-toggle', on: 'toggleAnimations(this.checked); renderSettings()'},
      {icon: 'apps', title: 'Ярлык на рабочий стол', sub: t('Добавить на главный экран телефона'), on: 'addDesktopShortcut()'},
      {icon: 'translate', title: 'Язык', sub: LANG === 'en' ? 'English' : 'Русский', on: 'pickLanguage(this)', menu: true}
    ]],
    ['О модуле', [
      {icon: 'info', title: 'nfqws2 for Android', sub: t('Версия {0}', S.version || '—'), on: 'openUrl(' + jsArg(GITHUB_URL) + ')', chevron: true}
    ]]
  ];
  let devHtml = '';
  if(devMode){
    const j = S || {};
    const lim = LIMITS.map(([k, label, hint, jk]) =>
      '<div class="list-item two-line clickable state" role="button" tabindex="0" aria-haspopup="dialog"' +
        ' onclick="editLimit(' + jsArg(k) + ', ' + jsArg(t(label)) + ', ' + (+j[jk] || 15) + ')">' +
        '<span class="li-text"><span class="li-primary">' + esc(t(label)) + '</span>' +
          '<span class="li-secondary">' + esc(t(hint)) + '</span></span>' +
        '<span class="li-trail">' +
          '<span class="li-value">' + esc(j[jk] != null ? j[jk] : '—') + '</span>' + icon('chevron-right', 's24') +
        '</span>' +
      '</div>');
    const rows = DEV_SW.map(([k, label, jk]) => switchRow(k, label, j[jk] == 1)).concat(lim).join('');
    devHtml = '<div class="stack" id="dev-block"><h2 class="subhead">' + esc(t('Для разработчиков')) + '</h2><div class="list" id="dev-sws">' + rows + '</div></div>';
  }
  setHTML('settings-body', groups.map(([title, rows]) =>
    '<div class="stack"><h2 class="subhead">' + esc(t(title)) + '</h2><div class="list">' + rows.map(settingsRow).join('') + '</div></div>').join('') +
    devHtml, false);
}
const GITHUB_URL = 'https://github.com/SpectaCoolAre/nfqws2-android-ext';

let deferredInstallPrompt = null;
if(typeof window !== 'undefined'){
  window.addEventListener('beforeinstallprompt', e => {
    e.preventDefault();
    deferredInstallPrompt = e;
  });
}

function addDesktopShortcut(){
  if(deferredInstallPrompt){
    deferredInstallPrompt.prompt();
    deferredInstallPrompt.userChoice.then(choiceResult => {
      if(choiceResult && choiceResult.outcome === 'accepted'){
        toast(t('Ярлык добавлен на рабочий стол'));
      }
      deferredInstallPrompt = null;
    });
    return;
  }
  mdDialog({
    title: t('Ярлык на рабочий стол'),
    text: t('KernelSU: в списке модулей удерживайте кнопку WebUI на карточке nfqws2 и выберите «Создать ярлык».\nMMRL и KsuWebUI: «Создать ярлык» в меню модуля.\nИконка ярлыка подставится из модуля сама.'),
    iconName: 'apps',
    ok: t('Понятно'),
    cancel: false
  });
}

/* Ссылку открывает система (браузер по умолчанию): внутри WebView менеджера
   переход увёл бы со страницы модуля без пути назад. */
async function openUrl(url){
  const r = await sh('am start -a android.intent.action.VIEW -d ' + q(url) + ' >/dev/null 2>&1', 8000);
  if(r.code) try { window.open(url, '_blank'); } catch(e) {}
}
function pickLanguage(anchor){
  openMenu(anchor, [['ru', 'Русский'], ['en', 'English']].map(([k, label]) => ({
    label, icon: k === LANG ? 'check' : '', onClick: () => setLanguage(k)
  })));
}
function setLanguage(l){
  if(l === LANG) return;
  LANG = l;
  store.set('nfq_lang', l);
  rerenderAll();
}
/* Смена языка без перезагрузки: статические узлы переводятся по data-t,
   динамические перерисовываются, видимый экран дочитывает свои данные. */
function rerenderAll(){
  translateStatic();
  renderAppBar(currentPage, false);
  renderStatus();
  renderStrategyRow();
  renderMode(); renderListFiles();
  renderLogChips();
  drawThemeUI();
  if(currentPage === 'settings') renderSettings();
  if(currentPage === 'apps'){ renderAppModes(); drawPk(false); }
  if(currentPage === 'wifi') renderWifi();
  if(currentPage === 'test') testInit();
  if(currentPage === 'diag') diagInit();
  if(currentPage === 'dns') renderDns();
  if(currentPage === 'dnsprof') renderDnsProfile();
  if(currentPage === 'logs') loadLog();
  if(currentPage === 'config'){ loadImports(); checkConfModified(); }
}

/* ══ ДОМАШНЯЯ WI-FI ══════════════════════════════════════════════════════ */
let homeList = [], currentSsid = '';
async function wifiInit(){
  renderWifi();
  const [r1, r2] = await Promise.all([ctlx(['get-list', 'home']), ctlx(['wifi-ssid'])]);
  homeList = (r1.code ? '' : r1.out).split('\n').map(s => s.replace(/\r$/, '')).filter(s => s.trim() && s.trim()[0] !== '#');
  currentSsid = r2.code ? '' : r2.out.replace(/\n+$/, '');
  await stat(true);
  renderWifi();
}
function renderWifi(){
  const on = S.home_wifi == 1;
  $('wifi-toggle').checked = on;
  $('wifi-main').classList.toggle('on', on);
  $('wifi-body').classList.toggle('is-disabled', !on);
  $('wifi-body').inert = !on;
  setHTML('wifi-suggest', on && currentSsid && !homeList.includes(currentSsid)
    ? '<div class="suggest">' + icon('wifi', 's24') +
        '<span class="grow">' + esc(t('Сейчас телефон подключён к «{0}». Добавить эту сеть в домашние?', currentSsid)) + '</span>' +
        '<button class="btn tonal sm state" onclick="addHome(' + jsArg(currentSsid) + ')">' + esc(t('Добавить')) + '</button></div>'
    : '', true);
  setHTML('wifi-list', homeList.length ? homeList.map(s =>
    '<div class="list-item">' +
      '<span class="li-icon plain">' + icon('wifi', 's24') + '</span>' +
      '<span class="li-text"><span class="li-primary truncate">' + esc(s) + '</span>' +
        (s === currentSsid ? '<span class="li-secondary">' + esc(t('Подключено сейчас')) + '</span>' : '') + '</span>' +
      '<button class="icon-btn sm state" aria-label="' + esc(t('Убрать сеть {0}', s)) + '" onclick="removeHome(' + jsArg(s) + ')">' +
        icon('trash', 's20') + '</button>' +
    '</div>').join('')
    : '<div class="empty"><span class="empty-icon">' + icon('home', 's24') + '</span><span>' +
      esc(t('Домашних сетей пока нет. Подключитесь к своей Wi‑Fi — модуль сам предложит её добавить.')) + '</span></div>', false);
}
async function saveHomeList(list){
  const r = await withBusy(['save-list-b64', 'home', b64(list.join('\n') + (list.length ? '\n' : ''))], 30000);
  if(r.code){ toast(errText(r, 'Не удалось сохранить')); return false; }
  homeList = list;
  return true;
}
async function addHome(ssid){
  ssid = String(ssid || '');
  if(!ssid || homeList.includes(ssid)) return;
  if(await saveHomeList(homeList.concat([ssid]))){
    toast(t('«{0}» добавлена в домашние сети', ssid));
    await stat(true);
    renderWifi();
  }
}
async function removeHome(ssid){
  if(await saveHomeList(homeList.filter(s => s !== ssid))){
    toast(t('«{0}» убрана из домашних сетей', ssid));
    await stat(true);
    renderWifi();
  }
}
async function addHomeManual(){
  const v = await mdPrompt(t('Добавить сеть'), t('Имя сети (SSID) в точности как в настройках Wi‑Fi.'), currentSsid && !homeList.includes(currentSsid) ? currentSsid : '', 'SSID',
    {ok: t('Добавить')});
  if(v) addHome(v);
}
async function setHomeWifi(on){
  const r = await withBusy(['set', 'HOME_WIFI', on ? '1' : '0'], 40000);
  if(r.code){ toast(errText(r, 'Не удалось сохранить')); $('wifi-toggle').checked = !on; return; }
  await stat(true);
  renderWifi();
  // Умное предложение: функцию включили, телефон уже в Wi‑Fi, а сеть ещё не в списке.
  if(on && currentSsid && !homeList.includes(currentSsid)){
    const ok = await mdConfirm(t('Это домашняя сеть?'),
      t('Сейчас телефон подключён к «{0}». Добавить её в домашние — тогда в ней обход будет вставать на паузу.', currentSsid),
      {ok: t('Добавить'), cancel: t('Не сейчас'), iconName: 'home'});
    if(ok) addHome(currentSsid);
  }
}

/* ══ РЕЗЕРВНАЯ КОПИЯ ═════════════════════════════════════════════════════ */
const UI_KEYS = ['m3_seed', 'm3_mode', 'm3_amoled', 'm3_containers', 'm3_monochrome', 'nfq_lang', 'nfq_dev'];
async function createBackup(){
  const ui = {};
  UI_KEYS.forEach(k => { const v = store.get(k); if(v != null) ui[k] = v; });
  const r = await withBusy(['backup-create', b64(JSON.stringify(ui))], 60000);
  if(r.code){ toast(errText(r, 'Не удалось создать копию')); return; }
  const parts = r.out.trim().split('\n')[0].split('\t');
  const filename = parts[0] || ('nfqws2-backup-' + Date.now() + '.tar');
  const filePath = parts[1] || '';
  const b64Data = parts[2] || '';
  if(b64Data){
    const blob = b64toBlob(b64Data, 'application/x-tar');
    await exportBlobFile(blob, filename, 'application/x-tar', filePath);
  } else {
    toast(t('Копия сохранена: {0}', filename));
  }
}
async function openBackupSheet(){
  setHTML('backup-list', '<div class="list-item"><span class="spinner"></span><span class="li-text"><span class="li-secondary">' +
    esc(t('Поиск копий…')) + '</span></span></div>', false);
  openSheet('backup-sheet');
  // Список — после выезда листа: exec без spawn занимает главный поток,
  // и анимация дёргалась
  await new Promise(res => setTimeout(res, isAnimationsDisabled() ? 0 : 480));
  if(openSheetId !== 'backup-sheet') return;
  const r = await ctlx(['backup-list']);
  if(openSheetId !== 'backup-sheet') return;
  const rows = (r.code ? '' : r.out).split('\n').filter(Boolean).map(l => l.split('\t'));
  setHTML('backup-list', rows.length ? rows.map(([name, size]) => {
    const m = name.match(/(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})/);
    const when = m ? m[3] + '.' + m[2] + '.' + m[1] + ' ' + m[4] + ':' + m[5] : name;
    return '<div class="list-item two-line clickable state" role="button" tabindex="0" onclick="restoreBackup(' + jsArg(name) + ')">' +
      '<span class="li-icon">' + icon('upload', 's24') + '</span>' +
      '<span class="li-text"><span class="li-primary">' + esc(when) + '</span>' +
        '<span class="li-secondary li-mono truncate">' + esc(name) + ' · ' + Math.max(1, Math.round((+size || 0) / 1024)) + ' KB</span></span>' +
    '</div>';
  }).join('') : '<div class="empty"><span class="empty-icon">' + icon('download', 's24') + '</span><span>' +
    esc(t('В папке Download/nfqws2 копий нет. Выберите файл вручную.')) + '</span></div>');
}
function applyRestoredUi(raw){
  const line = (raw || '').trim().split('\n')[0];
  if(line){
    try {
      const ui = JSON.parse(unb64(line));
      UI_KEYS.forEach(k => { if(ui[k] != null) store.set(k, String(ui[k])); });
      LANG = store.get('nfq_lang') === 'en' ? 'en' : 'ru';
      devMode = store.get('nfq_dev') === '1';
      currentMode = store.get('m3_mode') || 'auto';
      const sd = (store.get('m3_seed') || '').toLowerCase();
      if(/^#[0-9a-f]{6}$/.test(sd)) currentSeed = sd;
      applyTheme();
    } catch(e) {}
  }
  stat();
  initStrategySelector();
  rerenderAll();
}
async function restoreBackupFromFile(file){
  if(!file) return;
  if($('backupFile')) $('backupFile').value = '';
  if(!await mdConfirm(t('Восстановить копию?'),
    t('Конфиг, пользовательские списки, стратегии и оформление будут заменены содержимым «{0}».', file.name),
    {ok: t('Восстановить'), danger: true})) return;
  closeSheet();
  try {
    const b64Data = await blobToB64(file);
    const r = await withBusy(['backup-restore-b64', b64Data], 90000);
    if(r.code){ toast(errText(r, 'Не удалось восстановить копию')); return; }
    applyRestoredUi(r.out);
    toast(t('Копия восстановлена'));
  } catch(e){
    toast(t('Ошибка чтения файла: {0}', (e && e.message) || String(e)));
  }
}
async function restoreBackup(name){
  if(!await mdConfirm(t('Восстановить копию?'), t('Конфиг, пользовательские списки, стратегии и оформление будут заменены содержимым «{0}».', name),
    {ok: t('Восстановить'), danger: true})) return;
  closeSheet();
  const r = await withBusy(['backup-restore', name], 90000);
  if(r.code){ toast(errText(r, 'Не удалось восстановить копию')); return; }
  applyRestoredUi(r.out);
  toast(t('Копия восстановлена'));
}

async function toggleHotspot(checked){
  const on = typeof checked === 'boolean' ? checked : (S.enable_hotspot != 1);
  const r = await withBusy(['set', 'ENABLE_HOTSPOT', on ? '1' : '0'], 40000);
  if(r.code) toast(errText(r, 'Не удалось переключить точку доступа'));
  else { S.enable_hotspot = on ? 1 : 0; if(typeof renderStatus === 'function') renderStatus(); stat(); }
}

async function toggleNetStrategy(checked){
  const on = typeof checked === 'boolean' ? checked : (S.net_strategy != 1);
  const r = await withBusy(['set', 'NET_STRATEGY', on ? '1' : '0'], 40000);
  if(r.code) toast(errText(r, 'Не удалось переключить привязку стратегий'));
  else { S.net_strategy = on ? 1 : 0; renderSettings(); stat(); }
}

