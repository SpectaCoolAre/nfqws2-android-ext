/* nfqws2 WebUI · logs.js — экран «Журналы»
   Скрипты подключаются из index.html обычными <script> по порядку и делят одну
   глобальную область: функции и let/const одного файла видны в остальных. */

/* ══ ЖУРНАЛЫ ═════════════════════════════════════════════════════════════ */
const LOG_SOURCES = [['summary', 'Краткая статистика'], ['service', 'Служба'], ['nfqws', 'Процесс'],
  ['auto', 'Автообучение'], ['debug', 'Отладка'], ['dns', 'DNS']];
/* Журнал DNS — только если в модуле есть dnsproxy */
const logSources = () => LOG_SOURCES.filter(s => s[0] !== 'dns' || S.dns_available == 1);
let logSource = store.get('nfq_log_src') || 'service', logLines = '100', logErrors = false;
if(!LOG_SOURCES.some(s => s[0] === logSource)) logSource = 'service';
function renderLogChips(){
  // до первого статуса (S пуст) не знаем, есть ли dnsproxy — сохранённый выбор не трогаем
  if(logSource === 'dns' && S.dns_available != null && S.dns_available != 1) logSource = 'service';
  const src = t((LOG_SOURCES.find(s => s[0] === logSource) || LOG_SOURCES[1])[1]);
  const sum = logSource === 'summary';
  $('log-chips').innerHTML =
    '<button class="chip dropdown state" aria-haspopup="menu" aria-expanded="false" aria-label="' + esc(t('Журнал: {0}', src)) + '"' +
      ' onclick="pickLogSource(this)"><span>' + esc(src) + '</span>' + icon('caret', 's18') + '</button>' +
    (sum ? '' :
      '<button class="chip dropdown state" aria-haspopup="menu" aria-expanded="false" aria-label="' + esc(t('Показывать строк: {0}', logLines)) + '"' +
        ' onclick="pickLogLines(this)"><span>' + esc(t('{0} строк', logLines)) + '</span>' + icon('caret', 's18') + '</button>' +
      '<button class="chip filter state' + (logErrors ? ' selected' : '') + '" aria-pressed="' + logErrors + '" onclick="toggleLogErrors()">' +
        '<span class="chip-check">' + icon('check', 's18') + '</span><span>' + esc(t('Ошибки')) + '</span></button>');
}
function pickLogSource(anchor){
  openMenu(anchor, logSources().map(([k, label]) => ({
    label: t(label), icon: k === logSource ? 'check' : '',
    onClick: () => { logSource = k; store.set('nfq_log_src', k); loadLog(); }
  })));
}
function pickLogLines(anchor){
  openMenu(anchor, ['100', '300', '1000'].map(n => ({
    label: t('{0} строк', n), icon: n === logLines ? 'check' : '',
    onClick: () => { logLines = n; loadLog(); }
  })));
}
function toggleLogErrors(){ logErrors = !logErrors; loadLog(); }

/* Долгое нажатие на значок журналов в шапке — действие на выбор (настройка
   на экране «Журналы»): экспорт или очистка без вопросов */
const LOGS_LONG = [['export', 'Экспорт логов'], ['clear', 'Очистка журналов']];
let logsLong = store.get('nfq_logs_long') === 'clear' ? 'clear' : 'export';
function renderLogsLong(){
  $('logs-long-value').textContent = t((LOGS_LONG.find(x => x[0] === logsLong) || LOGS_LONG[0])[1]);
}
function pickLogsLong(anchor){
  openMenu(anchor, LOGS_LONG.map(([k, label]) => ({
    label: t(label), icon: k === logsLong ? 'check' : '',
    onClick: () => { logsLong = k; store.set('nfq_logs_long', k); renderLogsLong(); }
  })));
}
async function logsLongAction(){
  if(logsLong === 'clear'){
    const r = await withBusy(['clear-logs']);
    toast(r.code ? errText(r, 'Не удалось очистить журналы') : t('Журналы очищены (долгое нажатие на значок журналов)'));
    if(currentPage === 'logs') loadLog();
  } else {
    toast(t('Экспорт журналов (долгое нажатие на значок журналов)'));
    exportLogs();
  }
}
onLongPress($('logs-btn'), null, logsLongAction);
const STATUS_MAP = {ok: ['ok', 'check'], warn: ['warn', 'warn'], fail: ['bad', 'error'], info: ['info', 'info']};
function statusRows(text){
  return text.trim().split('\n').filter(Boolean).map(l => l.split('\t')).map(([s, n, d]) => {
    const m = STATUS_MAP[s] || STATUS_MAP.info;
    return '<div class="list-item' + (d ? ' two-line' : '') + '">' +
      '<span class="status ' + m[0] + '">' + icon(m[1], 's16') + '</span>' +
      '<span class="li-text"><span class="li-primary">' + esc(n || '') + '</span>' +
      (d ? '<span class="li-secondary">' + esc(d) + '</span>' : '') + '</span></div>';
  }).join('');
}
let logReq = 0;
async function loadLog(){
  renderLogChips();
  // быстрые переключения: ответ на старый запрос не должен затереть новый
  const id = ++logReq;
  const sum = logSource === 'summary';
  $('lg').hidden = sum;
  $('lg-sum').hidden = !sum;
  if(sum){
    const r = await ctlx(['get-logs', 'summary'], 30000);
    if(id !== logReq) return;
    setHTML('lg-sum', statusRows(r.code ? '' : r.out) || '<div class="list-item"><span class="li-text"><span class="li-secondary">' +
      esc(r.code ? errText(r, 'Не удалось прочитать журнал') : t('Нет данных')) + '</span></span></div>');
    return;
  }
  const r = await ctlx(['get-logs', logSource, logLines].concat(logErrors ? ['errors'] : []), 30000);
  if(id !== logReq) return;
  const text = (r.code ? errText(r, 'Не удалось прочитать журнал') : r.out).replace(/\s+$/, '') || t('Журнал пуст');
  const lg = $('lg');
  lg.innerHTML = text.length < 400000 ? highlight(text, 'log') : esc(text);
  lg.classList.remove('appear'); void lg.offsetWidth; lg.classList.add('appear');
  lg.scrollTop = lg.scrollHeight;
}
async function exportLogs(){
  const dir = SAVE_DIR_DEFAULT;
  const r = await withBusy(['export-logs'], 30000);
  if(r.code){ toast(errText(r, 'Не удалось экспортировать журналы')); return; }
  const parts = r.out.trim().split('\n')[0].split('\t');
  // без архива (нет tar) ctl кладёт файлы в папку и пишет одну строку о ней
  if(parts.length < 3 || !parts[2]){ toast(r.out.trim()); return; }
  await exportBlobFile(b64toBlob(parts[2], 'application/x-tar'), parts[0], 'application/x-tar', parts[1], dir);
}
async function clearLogs(){
  if(!await mdConfirm(t('Очистить журналы?'), t('service.log, nfqws2.log, отладочный, журнал автообучения и журнал DNS будут обнулены.'),
    {ok: t('Очистить'), danger: true})) return;
  const r = await withBusy(['clear-logs']);
  toast(r.code ? errText(r, 'Не удалось очистить журналы') : t('Журналы очищены'));
  loadLog();
}
