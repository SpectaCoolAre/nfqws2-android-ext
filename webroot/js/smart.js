/* nfqws2 WebUI · smart.js — умный режим: выученное по сетям и обучение
   Скрипты подключаются из index.html обычными <script> по порядку и делят одну
   глобальную область: функции и let/const одного файла видны в остальных. */

/* ══ УМНЫЙ РЕЖИМ ═════════════════════════════════════════════════════════
   Стратегия smart сама подбирает вариант обхода для каждого сайта и помнит
   его отдельно для каждой сети. Здесь — что выучено, обучение и сброс. */
let SMS = null, smartTimer = null;
const SMART_SLOTS = [['tls', 'Сайты (TLS)'], ['google', 'Google и YouTube'], ['quic', 'QUIC']];
const SMART_TRAIN_TEXT = {
  starting: 'Запуск…', running: 'Идёт обучение', waiting: 'Нет связи — обучение ждёт сеть',
  done: 'Обучение завершено', stopped: 'Обучение остановлено', offline: 'Сети так и не было — обучение прервано',
  error: 'Нечем проверять сайты: нет curl или wget'
};

async function smartInit(){
  await smartLoad();
}
async function smartLoad(){
  const r = await ctlx(['smart-status']);
  try { SMS = JSON.parse(r.out); } catch(e){ SMS = null; }
  renderSmart();
  clearTimeout(smartTimer);
  // пока идёт обучение — обновлять ход, пока экран открыт
  if(SMS && SMS.training == 1 && currentPage === 'smart') smartTimer = setTimeout(smartLoad, 3000);
}
const smartNetLabel = n => n.id === 'mobile' || /^mobile-/.test(n.id) ? t('Мобильная: {0}', n.label) : n.id === 'wifi' ? t('Wi‑Fi') : t('Wi‑Fi: {0}', n.label);

function renderSmart(){
  const m = SMS;
  if(!m){ setHTML('smart-body', banner('danger', 'error', t('Не удалось прочитать состояние умного режима')), false); return; }
  const cur = (m.nets || []).find(n => n.current == 1);
  const parts = [];
  if(m.active != 1){
    parts.push('<div class="suggest">' + icon('auto', 's24') + '<span class="grow">' +
      esc(t('Умный режим сейчас не выбран. Он сам подберёт обход для каждого сайта из вариантов MartinBacker, hardcorp74 и альтов Flowseal и запомнит его для каждой сети.')) + '</span>' +
      '<button class="btn tonal sm state" onclick="smartEnable()">' + esc(t('Включить')) + '</button></div>');
  }
  // состояние: сеть, сколько выучено
  const netText = m.offline == 1 ? t('Нет связи — перебор на паузе') : cur ? smartNetLabel(cur) : t('Сеть ещё не определена');
  parts.push('<div class="list">' +
    settingsRow({icon: m.offline == 1 ? 'warn' : 'wifi', title: 'Сеть', sub: netText}) +
    settingsRow({icon: 'auto', title: 'Выучено в этой сети', sub: cur ? plural(cur.sites, t('сайт'), t('сайта'), t('сайтов')) : t('пока ничего')}) +
    (cur && (cur.ok || cur.err) ? settingsRow({icon: 'status', title: 'Соединения', sub: t('Удачных {0} · с ошибками {1} — свежие весят больше', cur.ok, cur.err)}) : '') +
  '</div>');
  // обучение
  const tr = m.train || {}, running = m.training == 1;
  const prog = tr.total ? t('{0} из {1}: открылось {2}, не открылось {3}', tr.done || 0, tr.total, tr.ok || 0, tr.fail || 0) : '';
  parts.push('<h2 class="subhead">' + esc(t('Обучение')) + '</h2>' +
    '<div class="helper">' + esc(t('DPI-детектор по очереди открывает сайты из «Проверки доступности» и сайты за Cloudflare и на хостингах, а умный режим на них подбирает варианты. Можно не обучать: он учится и сам, по ходу работы, — просто первые открытия заблокированных сайтов будут медленнее.')) + '</div>' +
    '<div class="list">' +
      (tr.state ? settingsRow({icon: running ? 'refresh' : tr.state === 'done' ? 'check' : 'info', title: SMART_TRAIN_TEXT[tr.state] || tr.state,
        sub: prog + (running && tr.host ? (prog ? ' · ' : '') + tr.host : '')}) : '') +
      (running
        ? settingsRow({icon: 'stop', title: 'Остановить обучение', on: 'smartTrain(false)'})
        : settingsRow({icon: 'play', title: 'Обучить сейчас', sub: m.active == 1 && m.running == 1 ? t('В фоне, 5–20 минут; можно закрыть WebUI') : t('Нужен запущенный умный режим'), on: 'smartTrain(true)'})) +
    '</div>');
  // лидеры по наборам вариантов
  const top = m.top || {};
  const slots = SMART_SLOTS.filter(([k]) => (top[k] || []).length);
  if(slots.length){
    parts.push('<h2 class="subhead">' + esc(t('Что работает в этой сети')) + '</h2>' +
      slots.map(([k, title]) => '<div class="list">' +
        '<div class="sheet-group" role="presentation">' + esc(t(title)) + '</div>' +
        top[k].slice().sort((a, b) => b.sites - a.sites || b.ok - a.ok).slice(0, 5).map(v =>
          settingsRow({icon: v.err > v.ok ? 'warn' : 'check', title: v.name || ('#' + v.n),
            sub: t('Сайтов на нём: {0} · удачных {1} · с ошибками {2}', v.sites, v.ok, v.err)})).join('') +
      '</div>').join(''));
  }
  // сайты, у которых на текущем варианте ошибок больше, чем удач: умный режим
  // уже ищет им другой вариант
  const probs = m.problems || [];
  if(probs.length){
    parts.push('<h2 class="subhead">' + esc(t('Сайты с ошибками')) + '</h2>' +
      '<div class="helper">' + esc(t('На текущем варианте у них ошибок больше, чем удач. Умный режим уже подбирает им другой: при следующей ошибке вариант сменится, а застрявшие соединения он обрывает сам, чтобы приложение переподключилось.')) + '</div>' +
      '<div class="list">' + probs.slice().sort((a, b) => b.err - a.err).slice(0, 10).map(p =>
        settingsRow({icon: 'warn', title: p.host, sub: (p.name || '#' + p.n) + ' · ' + t('удачных {0} · с ошибками {1}', p.ok, p.err)})).join('') + '</div>');
  }
  // ни один вариант не помог и удач не было — дело не в DPI; такие сайты
  // умный режим не перебирает и их соединения не обрывает
  const nodpi = m.nodpi || [];
  if(nodpi.length){
    parts.push('<h2 class="subhead">' + esc(t('Не похоже на блокировку')) + '</h2>' +
      '<div class="helper">' + esc(t('Эти сайты не открылись ни на одном варианте: дело не в DPI — сервер недоступен, мешает прокси или само приложение. Умный режим 6 часов их не трогает: не перебирает варианты и не обрывает соединения.')) + '</div>' +
      '<div class="list">' + nodpi.slice(0, 10).map(h => settingsRow({icon: 'info', title: h})).join('') + '</div>');
  }
  // сети: выученное хранится отдельно для каждой
  const nets = m.nets || [];
  parts.push('<h2 class="subhead">' + esc(t('Сети')) + '</h2>' +
    '<div class="helper">' + esc(t('Для каждой сети — своё выученное. Новая сеть начинает с копии выученного в прежней и дальше меняется сама; при возвращении в сеть ничего не перебирается заново.')) + '</div>' +
    (nets.length ? '<div class="list">' + nets.map(n =>
      '<div class="list-item two-line">' +
        '<span class="li-icon plain">' + icon(/^mobile/.test(n.id) ? 'globe' : 'wifi', 's24') + '</span>' +
        '<span class="li-text"><span class="li-primary truncate">' + esc(smartNetLabel(n)) + '</span>' +
          '<span class="li-secondary">' + esc(plural(n.sites, t('сайт'), t('сайта'), t('сайтов')) + (n.current == 1 ? ' · ' + t('сейчас') : '')) + '</span></span>' +
        '<button class="icon-btn sm state" aria-label="' + esc(t('Забыть выученное в {0}', smartNetLabel(n))) + '" onclick="smartReset(' + jsArg(n.id) + ')">' +
          icon('trash', 's20') + '</button>' +
      '</div>').join('') + '</div>'
      : '<div class="empty"><span class="empty-icon">' + icon('wifi', 's24') + '</span><span>' + esc(t('Сетей пока нет: они появятся, когда умный режим начнёт работать.')) + '</span></div>') +
    (nets.length ? '<div class="row"><button class="btn text with-icon state danger" onclick="smartReset(\'all\')">' + icon('trash', 's18') + '<span>' + esc(t('Забыть всё выученное')) + '</span></button></div>' : ''));
  setHTML('smart-body', parts.join(''), false);
}
function plural(n, one, few, many){
  n = Number(n) || 0;
  const m10 = n % 10, m100 = n % 100;
  const w = (m10 === 1 && m100 !== 11) ? one : (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14)) ? few : many;
  return n + ' ' + w;
}
async function smartEnable(){
  await applyStrategy('smart');
  await smartLoad();
  smartOffer();
}
/* Умный режим выбран, а в этой сети он ещё ничего не знает — предложить
   обучение сейчас. Отказ — не беда: он учится и по ходу работы */
async function smartOffer(){
  const r = await ctlx(['smart-status']);
  let m; try { m = JSON.parse(r.out); } catch(e){ return; }
  if(m.active != 1 || m.training == 1 || m.running != 1) return;
  const cur = (m.nets || []).find(n => n.current == 1);
  if(cur && cur.sites >= 5) return;
  const ok = await mdConfirm(t('Обучить умный режим сейчас?'),
    t('В этой сети он пока почти ничего не знает. Обучение в фоне откроет проверочные сайты и подберёт для них варианты (5–20 минут). Без обучения он научится сам, по ходу работы.'),
    {ok: t('Обучить'), cancel: t('Учиться по ходу'), iconName: 'auto'});
  if(ok) smartTrain(true);
}
async function smartTrain(on){
  const r = await withBusy(['smart-train', on ? 'start' : 'stop']);
  if(r.code){ toast(errText(r, on ? 'Не удалось начать обучение' : 'Не удалось остановить')); return; }
  toast(on ? t('Обучение идёт в фоне') : t('Обучение остановлено'));
  if(currentPage === 'smart') smartLoad();
}
async function smartReset(id){
  const all = id === 'all';
  if(!await mdConfirm(all ? t('Забыть всё выученное?') : t('Забыть выученное в этой сети?'),
    t('Умный режим начнёт подбирать варианты заново. Служба перезапустится.'), {ok: t('Забыть'), danger: true})) return;
  const r = await withBusy(['smart-reset', id], 40000);
  toast(r.code ? errText(r, 'Не удалось сбросить') : t('Выученное забыто'));
  smartLoad();
}
