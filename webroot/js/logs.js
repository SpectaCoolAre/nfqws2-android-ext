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
  if(logSource === 'dns' && !logSources().some(s => s[0] === 'dns')) logSource = 'service';
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
async function loadLog(){
  renderLogChips();
  const sum = logSource === 'summary';
  $('lg').hidden = sum;
  $('lg-sum').hidden = !sum;
  if(sum){
    const r = await ctlx(['get-logs', 'summary'], 30000);
    setHTML('lg-sum', statusRows(r.code ? '' : r.out) || '<div class="list-item"><span class="li-text"><span class="li-secondary">' +
      esc(r.code ? errText(r, 'Не удалось прочитать журнал') : t('Нет данных')) + '</span></span></div>');
    return;
  }
  const r = await ctlx(['get-logs', logSource, logLines].concat(logErrors ? ['errors'] : []), 30000);
  const text = (r.code ? errText(r, 'Не удалось прочитать журнал') : r.out).replace(/\s+$/, '') || t('Журнал пуст');
  const lg = $('lg');
  lg.innerHTML = text.length < 400000 ? highlight(text, 'log') : esc(text);
  lg.classList.remove('appear'); void lg.offsetWidth; lg.classList.add('appear');
  lg.scrollTop = lg.scrollHeight;
}
async function exportLogs(){
  const dir = await askSaveDir(t('Экспорт журналов'));
  if(dir === null) return;
  const r = await withBusy(['export-logs'], 30000);
  if(r.code){ toast(errText(r, 'Не удалось экспортировать журналы')); return; }
  const parts = r.out.trim().split('\n')[0].split('\t');
  const filename = parts[0] || ('nfqws2-logs-' + Date.now() + '.tar');
  const filePath = parts[1] || '';
  const b64Data = parts[2] || '';
  if(b64Data){
    const blob = b64toBlob(b64Data, 'application/x-tar');
    await exportBlobFile(blob, filename, 'application/x-tar', filePath, dir);
  } else {
    toast(t('Журналы сохранены: {0}', filename));
  }
}
async function clearLogs(){
  if(!await mdConfirm(t('Очистить журналы?'), t('service.log, nfqws2.log, отладочный и журнал автообучения будут обнулены.'),
    {ok: t('Очистить'), danger: true})) return;
  await withBusy(['clear-logs']);
  toast(t('Журналы очищены'));
  loadLog();
}
