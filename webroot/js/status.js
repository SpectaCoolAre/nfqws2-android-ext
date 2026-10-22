/* nfqws2 WebUI · status.js — экран «Состояние» и выбор стратегии
   Скрипты подключаются из index.html обычными <script> по порядку и делят одну
   глобальную область: функции и let/const одного файла видны в остальных. */

/* ── Время работы: tabular-nums, ровно раз в секунду ───────────────────── */
let uptTimer = null;
function fmtUptime(sec){
  sec = Math.max(0, Math.floor(sec));
  const d = Math.floor(sec / 86400); sec -= d * 86400;
  const h = Math.floor(sec / 3600); sec -= h * 3600;
  const m = Math.floor(sec / 60); sec -= m * 60;
  const p = n => String(n).padStart(2, '0');
  if(d > 0) return d + ' ' + t('д') + ' ' + p(h) + ':' + p(m) + ':' + p(sec);
  if(h > 0) return p(h) + ':' + p(m) + ':' + p(sec);
  return p(m) + ':' + p(sec);
}
/* Отсчёт ведёт сама страница по performance.now() — монотонным часам, которые
   не трогают ни перевод часов, ни смена часового пояса. Служба присылает время
   работы (тоже по часам с загрузки) раз в полторы секунды, но привязка к нему
   — только при расхождении больше 2 с: перезапуск службы или телефон спал.
   Иначе каждый опрос сдвигал бы отсчёт на округление и задержку ответа, и
   секунды то замирали, то перескакивали. Следующий тик — ровно на границе
   секунды, а не через 1000 мс от прошлого: setInterval копит опоздания. */
let uptAnchor = null;   // {ms: время работы, t: performance.now() в тот момент}
function uptElapsedMs(){ return uptAnchor.ms + (performance.now() - uptAnchor.t); }
function stopUptTimer(){
  if(uptTimer){ clearTimeout(uptTimer); uptTimer = null; }
  uptAnchor = null;
  $('upt').textContent = '—';
}
function uptTick(){
  const ms = uptElapsedMs();
  $('upt').textContent = fmtUptime(ms / 1000);
  uptTimer = setTimeout(uptTick, 1000 - (ms % 1000) + 10);
}
function startUptTimer(ms){
  ms = Math.max(0, ms);
  if(uptAnchor && Math.abs(uptElapsedMs() - ms) < 2000) return;
  uptAnchor = {ms, t: performance.now()};
  if(uptTimer) clearTimeout(uptTimer);
  uptTick();
}
/* ══ Стратегии ═══════════════════════════════════════════════════════════
   Описаний у стратегий нет намеренно: что работает, зависит от провайдера и
   региона, и описание обещало бы больше, чем может. Вместо них — группы по
   происхождению, на одном листе, с заголовком над каждой. */
let strategies = [{name: 'default', kind: 'builtin', mod: false}], currentStrategy = 'default', pendingStrategy = 'default';
const STRATEGY_GROUPS = [
  ['smart', 'Умный режим'], ['base', 'Базовая'], ['alt', 'Flowseal · ALT'], ['fake', 'Flowseal · FAKE TLS AUTO'],
  ['simple', 'Flowseal · SIMPLE FAKE'], ['authors', 'Авторские'], ['user', 'Пользовательские']
];
function strategyGroup(s){
  if(s.kind === 'import' || s.kind === 'user') return 'user';
  if(s.name === 'default') return 'base';
  if(s.name === 'smart') return 'smart';
  if(/^alt\d*(_|$)/i.test(s.name)) return 'alt';
  if(/^fake_tls_auto/i.test(s.name)) return 'fake';
  if(/^simple_fake/i.test(s.name)) return 'simple';
  return 'authors';
}
const groupTitle = g => t((STRATEGY_GROUPS.find(x => x[0] === g) || ['', ''])[1]);
const strategyName = s => s === 'default' ? t('По умолчанию') : s === 'smart' ? t('Умный режим') : String(s).replace(/^imp:/, '');
const findStrategy = n => strategies.find(s => s.name === n);

async function loadStrategies(){
  const r = await ctlx(['list-strategies']);
  const list = r.code ? [] : r.out.split('\n').filter(Boolean).map(l => {
    const p = l.split('\t');
    return {name: p[0], kind: p[1] || 'builtin', mod: p[2] === '1'};
  });
  strategies = [{name: 'default', kind: 'builtin', mod: false}].concat(list.filter(s => s.name !== 'default'));
}
async function initStrategySelector(){
  const r2 = await ctlx(['get-strategy']);
  currentStrategy = (!r2.code && r2.out.trim()) || 'default';
  await loadStrategies();
  renderStrategyRow();
}
function renderStrategyRow(){
  const s = findStrategy(currentStrategy) || {name: currentStrategy, kind: /^imp:/.test(currentStrategy) ? 'import' : 'builtin'};
  $('strategy-current').textContent = strategyName(currentStrategy);
  $('strategy-group').textContent = groupTitle(strategyGroup(s)) + (s.mod ? ' · ' + t('изменена') : '');
}
function strategyItem(s){
  const sel = s.name === pendingStrategy;
  return '<label class="list-item clickable state' + (sel ? ' selected' : '') + '">' +
    '<input type="radio" class="radio" name="strategy" value="' + esc(s.name) + '"' + (sel ? ' checked' : '') + '>' +
    '<span class="li-text"><span class="li-primary truncate">' + esc(strategyName(s.name)) + '</span>' +
      (s.mod || s.kind === 'import' || s.name === currentStrategy ? '<span class="li-tags">' +
        (s.name === currentStrategy ? '<span class="pill">' + esc(t('Текущая')) + '</span>' : '') +
        (s.mod ? '<span class="pill tonal">' + esc(t('Изменена')) + '</span>' : '') +
        (s.kind === 'import' ? '<span class="pill tonal">' + esc(t('Импорт')) + '</span>' : '') + '</span>' : '') +
    '</span>' +
    '<span class="li-trail li-actions">' +
      (s.mod ? '<button type="button" class="icon-btn sm state" data-act="reset" data-s="' + esc(s.name) + '"' +
        ' aria-label="' + esc(t('Сбросить «{0}» к исходнику', strategyName(s.name))) + '" title="' + esc(t('Сбросить к исходнику')) + '">' +
        icon('restart', 's20') + '</button>' : '') +
    '</span></label>';
}
function renderStrategyList(animate){
  const cmp = (a, b) => a.name.localeCompare(b.name, undefined, {numeric: true, sensitivity: 'base'});
  const html = STRATEGY_GROUPS.map(([g]) => {
    const items = strategies.filter(s => strategyGroup(s) === g).sort(cmp);
    if(!items.length) return '';
    return '<div class="sheet-group" role="presentation">' + esc(groupTitle(g)) + '</div>' +
      '<div class="list">' + items.map(strategyItem).join('') + '</div>';
  }).join('');
  const box = $('strategy-list');
  box.innerHTML = html;
  if(animate){ box.classList.remove('appear'); void box.offsetWidth; box.classList.add('appear'); }
  box.querySelectorAll('input.radio').forEach(r => {
    r.onchange = () => {
      pendingStrategy = r.value;
      box.querySelectorAll('.list-item').forEach(li => li.classList.toggle('selected', li.querySelector('input').value === pendingStrategy));
    };
  });
  box.querySelectorAll('button[data-act]').forEach(b => {
    b.onclick = e => {
      e.preventDefault(); e.stopPropagation();
      resetStrategy(b.dataset.s);
    };
  });
}
/* Долгое нажатие на стратегию — меню: изменить, поделиться, скопировать.
   Карандаш в строке убран: список остаётся простым выбором для всех, а
   правка — для тех, кто знает про удержание (подсказка — над списком). */
function strategyMenu(row){
  const name = row.querySelector('input.radio').value;
  openMenu(row, [
    {label: t('Изменить'), icon: 'edit', onClick: () => {
      if(name === 'default'){ closeSheet(); navigate('config'); toast(t('Стандартная стратегия — это nfqws2.conf во вкладке «Конфиг»')); }
      else editStrategy(name);
    }},
    {label: t('Поделиться'), icon: 'share', onClick: () => shareStrategy(name)},
    {label: t('Скопировать'), sub: t('Как текст'), icon: 'copy', onClick: () => copyStrategy(name)}
  ]);
}
/* Сразу файлом: текстом стратегию и так можно взять — «Скопировать» */
async function shareStrategy(name){
  const r = await ctlx(['strategy-path', name]);
  if(r.code){ toast(errText(r, 'Не удалось поделиться')); return; }
  shareFile('file', r.out.trim());
}
async function copyStrategy(name){
  const r = await ctlx(['strategy-get-b64', name]);
  if(r.code){ toast(errText(r, 'Не удалось прочитать стратегию')); return; }
  toast(await copyText(unb64(r.out.trim())) ? t('Стратегия «{0}» скопирована', strategyName(name)) : t('Не удалось скопировать'));
}
onLongPress($('strategy-list'), '.list-item', strategyMenu);

/* Долгое нажатие на части строки состояния: «DNS …» — экран DNS, «Домашний
   Wi‑Fi» — его настройки; «назад» вернёт на главную */
onLongPress($('sub'), '[data-go]', el => openFrom(el.dataset.go));

async function openStrategySheet(){
  pendingStrategy = currentStrategy;
  renderStrategyList(false);
  $('strategy-apply').innerHTML = icon('check', 's18') + esc(S.running ? t('Применить и перезапустить') : t('Применить'));
  openSheet('strategy-sheet');
  const list = $('strategy-list'), sel = list.querySelector('.selected');
  if(sel) list.scrollTop = sel.offsetTop - list.offsetTop - (list.clientHeight - sel.offsetHeight) / 2;
  await loadStrategies();
  if(openSheetId === 'strategy-sheet'){
    const top = list.scrollTop;
    renderStrategyList(false);
    list.scrollTop = top;
  }
}
async function applySelectedStrategy(){
  const val = pendingStrategy;
  closeSheet();
  await applyStrategy(val);
}
async function applyStrategy(val){
  const r = await withBusy(['set-strategy', val]);
  if(r.code){ toast(errText(r, 'Не удалось применить стратегию')); return; }
  currentStrategy = val;
  renderStrategyRow();
  if(S.running) await act('restart');
  else { toast(t('Стратегия «{0}» применится при следующем запуске', strategyName(val))); stat(); }
  // умный режим без выученного в этой сети — предложить обучение
  if(val === 'smart' && currentPage !== 'smart') smartOffer();
}
function editStrategy(name){
  // без пояснения внизу: с клавиатурой оно ехало вверх; что правку можно
  // откатить, видно по кнопке сброса, которая появится у стратегии
  openEditorWith({target: 'strategy', key: name, title: strategyName(name) + '.conf', lang: 'conf', b64: true,
    load: ['strategy-get-b64', name]});
}
async function resetStrategy(name){
  if(!await mdConfirm(t('Сбросить «{0}»?', strategyName(name)),
    t('Ваши правки стратегии будут удалены, вернётся версия из релиза.'), {ok: t('Сбросить'), danger: true})) return;
  const r = await withBusy(['strategy-reset', name]);
  if(r.code){ toast(errText(r, 'Не удалось сбросить')); return; }
  await loadStrategies();
  renderStrategyRow();
  if(openSheetId === 'strategy-sheet') renderStrategyList(true);
  toast(t('Стратегия «{0}» сброшена', strategyName(name)),
    name === currentStrategy ? {label: t('Применить'), fn: () => applyStrategy(name)} : null);
}

/* ══ СОСТОЯНИЕ ═══════════════════════════════════════════════════════════ */
/* Строки-переключатели — однострочные: только заголовок и сам переключатель.
   Описания под ними владелец считает лишними, они ломают ритм списка.
   На главном — только то, что действительно нужно пользователю; служебное
   (контроль работы, лимиты) — в блоке разработчика. */
const SW = [
  ['AUTOSTART', 'Автозапуск при загрузке', 'autostart'],
  ['IPV6_ENABLED', 'Обрабатывать IPv6', 'ipv6'],
  ['BLOCK_QUIC', 'Блокировать QUIC', 'block_quic'],
  ['ENABLE_HOTSPOT', 'Точка доступа с nfqws2', 'enable_hotspot']
];
// Меняют аргументы nfqws2 — служба перезапускается сама, без вопроса
const RESTART_KEYS = {CALLS_BYPASS: 1};
const DEV_SW = [
  ['WATCHDOG', 'Watchdog', 'watchdog'],
  ['META_QUIC_REJECT', 'Отказ QUIC для Instagram', 'meta_quic'],
  ['CALLS_BYPASS', 'Обход звонков (не тестировалось)', 'calls_bypass'],
  ['DNS_PUSH', 'Push-уведомления через DNS Google', 'dns_push']
];
/* Переключатели разработчика, доступные в этой сборке: DNS_PUSH — только
   при DNS профилях (сборка с dnsproxy) */
const devSwitches = j => DEV_SW.filter(([k]) => k !== 'DNS_PUSH' || j.dns_available == 1);
const LIMITS = [
  ['PKT_LIMIT_OUT', 'Исходящие пакеты', 'Сколько первых пакетов соединения обрабатывать', 'pkt_limit_out'],
  ['PKT_LIMIT_IN', 'Входящие пакеты', 'Сколько первых ответных пакетов обрабатывать', 'pkt_limit_in']
];

function banner(kind, ic, text){
  return '<div class="banner' + (kind ? ' ' + kind : '') + '">' + icon(ic) +
    '<span class="grow">' + esc(text) + '</span></div>';
}

let svcBusy = '';
function renderHeroActions(){
  const run = !!S.running, bt = $('bt'), rs = $('bt-restart');
  const busyLabel = {start: t('Запуск…'), stop: t('Остановка…'), restart: t('Перезапуск…'), 'home-pause': t('Пауза…')}[svcBusy];
  bt.disabled = !!svcBusy;
  bt.classList.toggle('with-icon', !!svcBusy);
  bt.innerHTML = busyLabel
    ? '<span class="spinner"></span><span>' + esc(busyLabel) + '</span>'
    : '<span>' + esc(run ? t('Остановить') : t('Запустить')) + '</span>';
  rs.hidden = !run || !!svcBusy;
  // Пауза — только когда обход запущен вручную в домашней сети
  $('bt-pause').hidden = !run || !!svcBusy || !S.home_override;
}

function switchRow(k, label, on){
  return '<label class="list-item clickable state">' +
    '<span class="li-text"><span class="li-primary">' + esc(t(label)) + '</span></span>' +
    '<span class="li-trail"><input type="checkbox" class="switch" role="switch" aria-label="' + esc(t(label)) + '"' +
      (on ? ' checked' : '') + ' onchange="setp(' + jsArg(k) + ', this.checked ? 1 : 0)"></span>' +
  '</label>';
}
function renderParams(j){
  j = j || {};
  setHTML('sws', SW.map(([k, label, jk]) => switchRow(k, label, j[jk] == 1)).join(''), false);
  if($('dev-sws') && devMode){
    const lim = LIMITS.map(([k, label, hint, jk]) =>
      '<div class="list-item two-line clickable state" role="button" tabindex="0" aria-haspopup="dialog"' +
        ' onclick="editLimit(' + jsArg(k) + ', ' + jsArg(t(label)) + ', ' + (+j[jk] || 15) + ')">' +
        '<span class="li-text"><span class="li-primary">' + esc(t(label)) + '</span>' +
          '<span class="li-secondary">' + esc(t(hint)) + '</span></span>' +
        '<span class="li-trail">' +
          '<span class="li-value">' + esc(j[jk] != null ? j[jk] : '—') + '</span>' + icon('chevron-right', 's24') +
        '</span>' +
      '</div>');
    setHTML('dev-sws', devSwitches(j).map(([k, label, jk]) => switchRow(k, label, j[jk] == 1)).concat(lim).join(''), false);
  }
  if($('dev-block')) $('dev-block').hidden = !devMode;
}

/* Отрисовка из последнего известного статуса: экран показывает данные сразу,
   а свежие приходят следом, без пустого кадра. */
function renderStatus(){
  const j = S;
  if(!j || j.running == null){ renderHeroActions(); renderParams({}); return; }
  const paused = !j.running && !!j.paused;
  if(j.strategy) currentStrategy = j.strategy;
  $('hero-status').className = 'hero' + (j.running ? ' running' : (paused ? ' paused' : ''));
  heroIcon(j.running ? 'shield' : (paused ? 'pause' : 'stop'));
  // На паузе времени работы нет — строка с прочерком только занимала место
  $('hero-stats').hidden = paused;
  $('st').textContent = j.running ? t('Служба работает') : (paused ? t('Пауза') : t('Служба остановлена'));
  // Вместо лимита (он зависит от ядра и виден в «Диагностике») — состояние DNS
  // Части подписи с data-go открываются долгим нажатием: DNS — экран DNS,
  // «Домашний Wi‑Fi» — его настройки
  const part = (text, go) => go ? '<span data-go="' + go + '">' + esc(text) + '</span>' : esc(text);
  const dns = j.dns_available == 1 ? ' · ' + part(j.dns_enabled != 1 ? t('DNS выключен')
    : (j.dns_paused === 'vpn' ? t('DNS на паузе при VPN') : j.dns_paused === 'home' ? t('DNS на паузе дома') : t('DNS включён')), 'dns') : '';
  // Подпись — одна строка; подробности паузы — в title.
  const sub = paused
    ? (j.paused === '@vpn' ? esc(t('Включён VPN')) : part(t('Домашний Wi‑Fi'), 'wifi')) + dns
    : esc(t('Режим') + ' ' + (j.mode || '—')) + dns;
  setHTML('sub', sub, false);
  $('sub').title = paused ? (j.paused === '@vpn' ? t('Включён VPN. Обход возобновится, когда VPN отключится.')
    : t('Домашний Wi‑Fi «{0}». Обход возобновится, когда телефон уйдёт из этой сети.', j.paused)) : '';
  if(j.running) startUptTimer(j.uptime_ms != null ? j.uptime_ms : (j.uptime || 0) * 1000); else stopUptTimer();
  renderHeroActions();
  renderParams(j);
  $('dbg').checked = (j.log_level == 1);

  let w = '';
  if(j.qdrop > 0) w += banner('danger', 'warn', t('Ядро сбросило {0} пакетов: nfqws2 не успевает обрабатывать очередь {1}.', j.qdrop, j.queue));
  if(j.log_level == 1) w += banner('', 'info', t('Включён подробный журнал отладки: обработка заметно медленнее.'));
  setHTML('warn', w, false);
}

/* Значок в карточке: щит — обход работает, пауза, стоп, ошибка связи */
function heroIcon(name){ const u = $('hero-ic'); if(u) u.setAttribute('href', '#i-' + name); }

let statPending = null;
async function stat(quiet){
  if(statPending) return statPending;
  statPending = (async () => {
    if(!quiet) busy(true);
    const raw = await ctl(['json-status']);
    if(!quiet) busy(false);
    let j = null, a = raw.indexOf('{'), b = raw.lastIndexOf('}');
    if(a >= 0 && b > a){ try { j = JSON.parse(raw.slice(a, b + 1)); } catch(e) {} }
    if(!j){
      if(quiet) return;
      $('hero-status').className = 'hero offline';
      heroIcon('error');
      $('hero-stats').hidden = false;
      $('st').textContent = t('Нет связи с модулем');
      $('sub').textContent = t('Проверьте root-доступ и наличие {0}', CTL);
      stopUptTimer();
      renderHeroActions();
      setHTML('warn', banner('danger', 'error', 'json-status: ' + (raw.trim() || t('(пустой ответ)')).slice(0, 200)), false);
      return;
    }
    S = j;
    renderStatus();
    if(currentPage === 'lists'){ renderMode(); renderListFiles(); }
  })();
  try { return await statPending; } finally { statPending = null; }
}

/* ── Автообновление статуса: пока экран виден и на нём есть что обновлять ──
   Полный json-status — это запуск nfqws2-ctl с чтением конфига и списков,
   и гонять его чаще раза в 5 секунд накладно. Поэтому на «Состоянии» раз в
   1,5 с читается только «подпись»: жив ли процесс, причина паузы, ручной
   запуск дома, включён ли DNS — несколько файлов одной командой. Изменилась
   подпись (пауза ↔ работа, падение, смена сети) — сразу полный статус, и
   карточка обновляется за 1–2 секунды, а не через 5–7. Опрос тихий — без
   полосы загрузки, и пропускается, пока открыт редактор или идёт команда. */
const POLL_PAGES = {control: 1, lists: 1};
const SIG_CMD = 'd=/data/adb/nfqws2; p=$(cat "$d/state/nfqws2.pid" 2>/dev/null); ' +
  'kill -0 "$p" 2>/dev/null && echo "run $p"; echo "p:$(cat "$d/state/home_paused" 2>/dev/null)"; ' +
  'echo "o:$(cat "$d/state/home_override" 2>/dev/null)"; [ -f "$d/dns/enabled" ] && echo dns; true';
let statSig = null, sigBusy = false, lastFull = 0;
function pollIdle(){
  return document.visibilityState === 'visible' && POLL_PAGES[currentPage] &&
    !busyCount && !svcBusy && !editorCtx && !openSheetId;
}
async function readSig(){
  const r = await sh(SIG_CMD, 4000);
  return r.code ? null : r.out.trim();
}
// Подпись читается ДО статуса: изменение между ними поймает следующий тик
async function fullStat(){
  lastFull = Date.now();
  // не прочиталась — пустая: иначе полный статус шёл бы на каждом тике
  if(currentPage === 'control') statSig = (await readSig()) || '';
  await stat(true);
}
async function statPoll(){
  if(!pollIdle() || sigBusy) return;
  sigBusy = true;
  try {
    // «Списки» и счётчики меняются без смены подписи — раз в 5 с полный статус
    const due = Date.now() - lastFull >= 5000;
    if(currentPage !== 'control'){ if(due) await fullStat(); return; }
    if(statSig === null || due){ await fullStat(); return; }
    const sig = await readSig();
    if(sig !== null && sig !== statSig && pollIdle()){ await fullStat(); return; }
  } finally { sigBusy = false; }
}
setInterval(statPoll, 1500);
document.addEventListener('visibilitychange', () => {
  if(document.visibilityState === 'visible' && POLL_PAGES[currentPage]) fullStat();
});

async function setp(k, v){
  const r = await withBusy(['set', k, String(v)]);
  // не сохранилось — S прежний, разметка та же, и setHTML не вернул бы
  // переключатель на место: сбрасываем его кэш
  if(r.code) ['sws', 'dev-sws'].forEach(id => { const el = $(id); if(el) el._html = ''; });
  if(!r.code && RESTART_KEYS[k] && S.running){
    const rr = await withBusy(['restart'], 60000);
    toast(rr.code ? errText(rr, 'Не удалось перезапустить службу') : t('Сохранено, служба перезапущена'));
    return stat();
  }
  const needRestart = !r.code && S.running && /перезапуск/i.test(r.out);
  toast(r.code ? errText(r, 'Не удалось сохранить') : (needRestart ? t('Применится после перезапуска службы') : t('Сохранено')),
    needRestart ? {label: t('Перезапустить'), fn: restartSvc} : null);
  stat();
}
async function editLimit(key, title, cur){
  const v = await mdPrompt(title, t('Целое число от 1 до 15.'), String(cur), t('Пакетов на соединение'), {type: 'number', inputmode: 'numeric'});
  if(v == null || v === '') return;
  const n = parseInt(v, 10);
  if(!(n >= 1 && n <= 15)){ toast(t('Нужно целое число от 1 до 15')); return; }
  if(n !== cur) setp(key, n);
}
async function act(a){
  svcBusy = a;
  if(a === 'stop') stopUptTimer();
  renderHeroActions();
  const r = await withBusy([a], 40000);
  svcBusy = '';
  const ok = {start: 'Служба запущена', stop: 'Служба остановлена', restart: 'Служба перезапущена',
    'home-pause': 'Обход на паузе в домашнем Wi‑Fi'}[a];
  toast(r.code ? errText(r, 'Команда не выполнена') : t(ok));
  await stat();
}
function toggle(){ act(S.running ? 'stop' : 'start'); }
function restartSvc(){ act('restart'); }
function pauseHome(){ act('home-pause'); }
