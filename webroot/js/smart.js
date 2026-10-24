/* nfqws2 WebUI · smart.js — умный режим: насколько он обучен, что выучено, обучение
   Скрипты подключаются из index.html обычными <script> по порядку и делят одну
   глобальную область: функции и let/const одного файла видны в остальных. */

/* ══ УМНЫЙ РЕЖИМ ═════════════════════════════════════════════════════════
   Сверху — насколько он уже обучен в выбранной сети, ниже — плитки: сайты,
   виды соединений, ошибки, обучение. В плитку можно зайти: там подробности.
   Статистику можно смотреть для любой сети, не только текущей. */
let SMS = null, smartTimer = null, smartView = null;
// Виды соединений: в каждый входят наборы вариантов (slot) своих профилей
// [ключ, заголовок плитки, заголовок подробностей, значок, наборы]
const SMART_GROUPS = [
  ['tls', 'TLS', 'Сайты (TLS)', 'globe', ['tls', 'tls_cf', 'tls_16', 'tls_as']],
  ['google', 'Google', 'Google и YouTube', 'shield', ['google']],
  ['quic', 'QUIC', 'QUIC', 'tune', ['quic', 'quic_16']]
];
const SMART_SLOT_TITLE = {tls: 'Обычные сайты', tls_cf: 'Сайты за Cloudflare', tls_16: 'Хостинги и CDN (обрыв на 16 КБ)',
  tls_as: 'Хостинги: Contabo, Frantech и другие', google: 'Google и YouTube', quic: 'QUIC', quic_16: 'QUIC на хостингах и CDN'};
/* Фоновое обучение идёт вместе со службой: на паузе или остановленной оно
   ждёт и продолжится само, когда служба снова заработает */
function smartLearnState(m){
  if(m.learn != 1) return {value: t('Выкл.'), sub: t('только по ходу работы'), on: false};
  if(m.active != 1) return {value: t('Ждёт'), sub: t('начнётся в умном режиме'), on: false};
  if(m.paused == 1) return {value: t('Пауза'), sub: t('продолжится, когда служба возобновит работу'), on: false};
  if(m.running != 1) return {value: t('Пауза'), sub: t('служба остановлена — продолжится при запуске'), on: false};
  if(m.offline == 1) return {value: t('Ждёт сеть'), sub: t('нет связи — продолжится, когда сеть появится'), on: false};
  return {value: t('Идёт'), sub: t('открыто сайтов: {0}', (m.bg || {}).n || 0), on: true};
}

async function smartInit(){ await smartLoad(); }
async function smartLoad(){
  const r = await ctlx(smartView ? ['smart-status', smartView] : ['smart-status']);
  try { SMS = JSON.parse(r.out); } catch(e){ SMS = null; }
  // выбранной сети больше нет (забыли) — обратно на текущую
  if(SMS && smartView && !(SMS.nets || []).some(n => n.id === smartView)){ smartView = null; return smartLoad(); }
  renderSmart();
  if(openSheetId === 'smart-sheet' && smartSheetKind === 'learn') smartTrainSheet();
  clearTimeout(smartTimer);
  // пока экран открыт — раз в 20 секунд свежая статистика (фоновое обучение идёт)
  if(SMS && (currentPage === 'config' && isSmartMode())) smartTimer = setTimeout(() => { if((currentPage === 'config' && isSmartMode())) smartLoad(); }, 20000);
}
const smartNetLabel = n => n.id === 'mobile' || /^mobile-/.test(n.id) ? t('Мобильная: {0}', n.label) : n.id === 'wifi' ? t('Wi‑Fi') : t('Wi‑Fi: {0}', n.label);
const isPassName = name => /без обхода/i.test(name || '');
const pct = (ok, err) => ok + err > 0 ? Math.round(100 * ok / (ok + err)) : null;

/* Насколько умный режим обучен в сети, 0–100.
   Блокировки по стране почти одинаковые: что видно на одних сайтах вида
   соединения, то верно и для других. Поэтому главное — знает ли он, какой
   вариант работает в каждом виде (TLS, Google, QUIC), и насколько он в этом
   уверен; затем — как часто соединения проходят без ошибок; и немного — как
   много сайтов он уже видел.
   · Уверенность вида: доля удач лучшего варианта (у которого их хотя бы три),
     умноженная на полноту данных — 30 удач в виде дают полную.
   · Знание = 0,5·TLS + 0,3·Google + 0,2·QUIC.
   · Точность — доля удачных соединений, без сайтов «не похоже на блокировку»
     (там сервер недоступен или бан по адресу, а не DPI).
   · Охват — 50 сайтов и больше.
   Итог = 45% знания + 35% точности + 20% охвата. */
function smartGroupStat(m, g){
  const slots = SMART_GROUPS.find(x => x[0] === g)[4];
  let ok = 0, err = 0, best = null, bestShare = 0, total = 0;
  slots.forEach(sl => (m.top && m.top[sl] || []).forEach(v => {
    ok += v.ok; err += v.err;
    if(isPassName(v.name)) return;
    total += v.ok;
    const sh = (v.ok + 1) / (v.ok + v.err + 2);
    if(v.ok >= 3 && sh > bestShare){ best = v; bestShare = sh; }
  }));
  return {ok, err, best, conf: best ? bestShare * Math.min(1, total / 30) : 0};
}
function smartProgress(m){
  const cur = (m.nets || []).find(n => n.id === m.view) || {sites: 0};
  const g = {}; SMART_GROUPS.forEach(([k]) => g[k] = smartGroupStat(m, k));
  const know = 0.5 * g.tls.conf + 0.3 * g.google.conf + 0.2 * g.quic.conf;
  const acc = m.acc && m.acc.ok + m.acc.err > 0 ? m.acc.ok / (m.acc.ok + m.acc.err) : 0;
  const cov = Math.min(1, (cur.sites || 0) / 50);
  return {p: Math.round(100 * (0.45 * know + 0.35 * acc + 0.2 * cov)), g, acc, sites: cur.sites || 0};
}
function smartLevel(p){
  return p < 30 ? t('Только начинает') : p < 60 ? t('Учится') : p < 85 ? t('Хорошо знает сеть') : t('Знает сеть');
}
function smartRing(p){
  const r = 42, c = 2 * Math.PI * r, off = c * (1 - Math.max(0, Math.min(100, p)) / 100);
  return '<svg class="smart-ring" viewBox="0 0 100 100" aria-hidden="true">' +
    '<circle class="track" cx="50" cy="50" r="' + r + '"/>' +
    '<circle class="bar" cx="50" cy="50" r="' + r + '" stroke-dasharray="' + c.toFixed(1) + '" stroke-dashoffset="' + off.toFixed(1) + '"/>' +
  '</svg><span class="smart-ring-val">' + p + '<small>%</small></span>';
}
function smartTile(o){
  // без действия — просто плитка с числом, не кнопка
  const tag = o.on ? 'button' : 'div';
  return '<' + tag + (o.on ? ' type="button"' : '') + ' class="smart-tile' + (o.on ? ' state' : ' static') + (o.tone ? ' ' + o.tone : '') + '"' +
    (o.id ? ' id="' + esc(o.id) + '"' : '') + (o.on ? ' onclick="' + o.on + '"' : '') + '>' +
    '<span class="st-head">' + icon(o.icon, 's20') + '<span class="st-title">' + esc(t(o.title)) + '</span></span>' +
    '<span class="st-value">' + esc(o.value) + '</span>' +
    '<span class="st-sub">' + esc(o.sub || '') + '</span>' +
  '</' + tag + '>';
}

function renderSmart(){
  const m = SMS;
  if(!m){ setHTML('smart-body', banner('danger', 'error', t('Не удалось прочитать состояние умного режима')), false); return; }
  const nets = m.nets || [];
  const view = nets.find(n => n.id === m.view);
  const parts = [];
  const pr = smartProgress(m);
  // шапка: кольцо обученности и сеть, чью статистику смотрим
  const netText = view ? smartNetLabel(view) : (m.offline == 1 ? t('Нет связи') : t('Сеть ещё не определена'));
  parts.push('<div class="smart-hero">' +
    '<div class="smart-ring-box">' + smartRing(pr.p) + '</div>' +
    '<div class="smart-hero-text">' +
      '<span class="smart-hero-level">' + esc(smartLevel(pr.p)) + '</span>' +
      '<span class="smart-hero-sub">' + esc(m.offline == 1 && view && view.current == 1 ? t('Нет связи — перебор на паузе') : t('Обученность в этой сети')) + '</span>' +
      (nets.length > 1
        ? '<button type="button" class="chip dropdown state" aria-haspopup="menu" onclick="smartPickNet(this)"><span>' + esc(netText) + '</span>' + icon('caret', 's18') + '</button>'
        : '<span class="smart-hero-net">' + icon(view && /^mobile/.test(view.id) ? 'globe' : 'wifi', 's18') + esc(netText) + '</span>') +
    '</div></div>');
  // плитки
  const probs = (m.problems || []).length, nodpi = (m.nodpi || []).length;
  const tiles = [
    {icon: 'list', title: 'Сайты', value: String(pr.sites), sub: pr.acc ? t('открываются в {0}% случаев', Math.round(pr.acc * 100)) : t('пока ничего'), on: "smartSites('all')"}
  ];
  SMART_GROUPS.forEach(([k, title, , ic]) => {
    const g = pr.g[k], p = pct(g.ok, g.err);
    tiles.push({icon: ic, title, value: p == null ? '—' : p + '%',
      sub: g.best ? g.best.name : (p == null ? t('нет данных') : t('ещё подбирает')), on: "smartGroup('" + k + "')"});
  });
  tiles.push({icon: probs ? 'warn' : 'check', title: 'Ошибки', value: String(probs + nodpi), tone: probs ? 'warn' : '',
    sub: probs || nodpi ? t('подбирает: {0} · не DPI: {1}', probs, nodpi) : t('всё открывается'), on: 'smartProblems()'});
  const ls = smartLearnState(m);
  tiles.push({icon: ls.on ? 'auto' : 'pause', title: 'Обучение', value: ls.value, sub: ls.sub, on: 'smartTrainSheet()'});
  parts.push('<div class="smart-tiles">' + tiles.map(smartTile).join('') + '</div>');
  // действия
  parts.push('<div class="list">' +
    settingsRow({icon: 'share', title: 'Поделиться обучением', sub: t('Файл с выученным в этой сети'), on: 'smartExport()'}) +
    settingsRow({icon: 'upload', title: 'Загрузить обучение', sub: t('Добавить выученное из файла в текущую сеть'), on: "$('smart-imp').click()"}) +
  '</div>');
  parts.push('<div class="row">' +
    (view ? '<button class="btn text with-icon state danger" onclick="smartReset(' + jsArg(view.id) + ')">' + icon('trash', 's18') + '<span>' + esc(t('Забыть эту сеть')) + '</span></button>' : '') +
    (nets.length ? '<button class="btn text with-icon state danger" onclick="smartReset(\'all\')">' + icon('trash', 's18') + '<span>' + esc(t('Забыть всё')) + '</span></button>' : '') +
  '</div>');
  setHTML('smart-body', parts.join(''), false);
}

function smartPickNet(anchor){
  openMenu(anchor, (SMS.nets || []).map(n => ({
    label: smartNetLabel(n), sub: plural(n.sites, t('сайт'), t('сайта'), t('сайтов')) + (n.current == 1 ? ' · ' + t('сейчас') : ''),
    icon: n.id === SMS.view ? 'check' : '',
    onClick: () => { smartView = n.current == 1 ? null : n.id; smartLoad(); }
  })));
}

/* Лист подробностей — один на все плитки */
let smartSheetKind = '';
function smartSheet(title, html, kind){
  smartSheetKind = kind || '';
  $('smart-sheet-title').textContent = title;
  $('smart-sheet-body').innerHTML = html;
  $('smart-sheet-body').scrollTop = 0;
  if(openSheetId !== 'smart-sheet') openSheet('smart-sheet');
}
function smartSiteRows(list){
  if(!list.length) return '<div class="empty"><span>' + esc(t('Пока пусто')) + '</span></div>';
  return '<div class="list">' + list.map(s =>
    settingsRow({icon: s.err > s.ok ? 'warn' : 'check', title: s.host,
      sub: (s.name || '#' + s.n) + ' · ' + t('удачных {0} · с ошибками {1}', s.ok, s.err)})).join('') + '</div>';
}
async function smartSitesList(grp){
  const r = await ctlx(['smart-sites', SMS.view, grp]);
  try { return JSON.parse(r.out); } catch(e){ return []; }
}
async function smartSites(grp){
  smartSheet(t('Выученные сайты'), '<div class="helper">' + esc(t('Загрузка…')) + '</div>');
  const list = await smartSitesList(grp);
  smartSheet(t('Выученные сайты'), '<div class="helper">' + esc(t('Сайт и вариант, на котором он сейчас работает. Первые 300 — по числу удачных соединений.')) + '</div>' + smartSiteRows(list));
}
async function smartGroup(k){
  const [, , title, , slots] = SMART_GROUPS.find(x => x[0] === k);
  const top = SMS.top || {};
  const varRows = slots.filter(sl => (top[sl] || []).length).map(sl =>
    '<div class="list">' + (slots.length > 1 ? '<div class="sheet-group" role="presentation">' + esc(t(SMART_SLOT_TITLE[sl])) + '</div>' : '') +
      top[sl].slice().sort((a, b) => b.sites - a.sites || b.ok - a.ok).slice(0, 6).map(v => {
        const p = pct(v.ok, v.err);
        return settingsRow({icon: v.err > v.ok ? 'warn' : 'check', title: v.name || ('#' + v.n),
          sub: t('Сайтов: {0} · удачных {1}%', v.sites, p == null ? '—' : p)});
      }).join('') + '</div>').join('');
  smartSheet(t(title), (varRows || '<div class="empty"><span>' + esc(t('Пока нет данных')) + '</span></div>') +
    '<h2 class="subhead">' + esc(t('Сайты')) + '</h2><div id="smart-grp-sites"><div class="helper">' + esc(t('Загрузка…')) + '</div></div>');
  const list = await smartSitesList(k);
  const box = $('smart-grp-sites');
  if(box) box.innerHTML = smartSiteRows(list);
}
async function smartProblems(){
  const nodpi = SMS.nodpi || [];
  smartSheet(t('Ошибки'), '<div class="helper">' + esc(t('Загрузка…')) + '</div>');
  const list = await smartSitesList('problems');
  smartSheet(t('Ошибки'),
    '<h2 class="subhead">' + esc(t('Подбирает вариант')) + '</h2>' +
    '<div class="helper">' + esc(t('На текущем варианте у них ошибок больше, чем удач: умный режим уже ищет им другой.')) + '</div>' +
    smartSiteRows(list) +
    '<h2 class="subhead">' + esc(t('Не похоже на блокировку')) + '</h2>' +
    '<div class="helper">' + esc(t('Не открылись ни на одном варианте: сервер недоступен или бан по адресу. 6 часов их не трогает.')) + '</div>' +
    (nodpi.length ? '<div class="list">' + nodpi.map(h => settingsRow({icon: 'info', title: h})).join('') + '</div>'
      : '<div class="empty"><span>' + esc(t('Таких нет')) + '</span></div>'));
}
function smartTrainSheet(){
  const m = SMS, bg = m.bg || {}, ls = smartLearnState(m);
  smartSheet(t('Обучение'),
    '<div class="helper">' + esc(t('Умный режим учится сам, по ходу работы. Фоновое обучение раз в две минуты открывает один сайт из списка популярных и ваших — так он заранее знает обход для каждого вида соединений. Оно идёт, пока работает служба: на паузе и без сети ждёт и продолжается само.')) + '</div>' +
    '<div class="list">' +
      settingsRow({icon: 'auto', title: 'Фоновое обучение', sub: bg.n ? t('Открыто сайтов: {0}, из них удачно {1}', bg.n, bg.ok || 0) + (bg.last ? ' · ' + bg.last : '') : t('Раз в две минуты, пока работает умный режим'),
        sw: true, checked: m.learn == 1, on: 'smartLearnToggle(this.checked)'}) +
      (m.learn == 1 ? settingsRow({icon: ls.on ? 'check' : 'pause', title: ls.on ? t('Идёт') : ls.value, sub: ls.sub}) : '') +
    '</div>', 'learn');
}
async function smartLearnToggle(on){
  const r = await withBusy(['set', 'SMART_LEARN', on ? '1' : '0']);
  if(r.code){ toast(errText(r, 'Не удалось сохранить')); return; }
  SMS.learn = on ? 1 : 0;
  renderSmart();
  toast(on ? t('Фоновое обучение включено') : t('Фоновое обучение выключено'));
}

function plural(n, one, few, many){
  n = Number(n) || 0;
  const m10 = n % 10, m100 = n % 100;
  const w = (m10 === 1 && m100 !== 11) ? one : (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14)) ? few : many;
  return n + ' ' + w;
}
async function smartReset(id){
  const all = id === 'all';
  if(!await mdConfirm(all ? t('Забыть всё выученное?') : t('Забыть выученное в этой сети?'),
    t('Умный режим начнёт подбирать варианты заново. Служба перезапустится.'), {ok: t('Забыть'), danger: true})) return;
  const r = await withBusy(['smart-reset', id], 40000);
  toast(r.code ? errText(r, 'Не удалось сбросить') : t('Выученное забыто'));
  if(all || id === smartView) smartView = null;
  smartLoad();
}
/* Поделиться обучением: файл .tsv выученного в выбранной сети */
async function smartExport(){
  if(!SMS) await smartLoad();
  if(!SMS || !SMS.view){ toast(t('В этой сети ещё ничего не выучено')); return; }
  const r = await withBusy(window.ksu ? ['smart-export', SMS.view, 'path'] : ['smart-export', SMS.view]);
  const out = (r.out || '').trim();
  if(r.code || !out){ toast(errText(r, 'Не удалось сохранить')); return; }
  const p = out.split('\n')[0].split('\t');
  await exportBlobFile(p[2] ? b64toBlob(p[2], 'text/tab-separated-values') : null, p[0], 'text/tab-separated-values', p[1], SAVE_DIR_DEFAULT);
}
async function smartImport(files){
  const f = files && files[0];
  $('smart-imp').value = '';
  if(!f) return;
  if(!await mdConfirm(t('Загрузить обучение?'),
    t('Сайты из файла, которых здесь ещё нет, добавятся к выученному в текущей сети. Своё выученное останется. Служба перезапустится.'), {ok: t('Загрузить'), iconName: 'upload'})) return;
  const text = await f.text();
  const r = await withBusy(['smart-import-b64', b64(text)], 60000);
  if(r.code){ toast(errText(r, 'Не удалось загрузить')); return; }
  toast(t('Добавлено сайтов: {0}', (r.out || '0').trim()));
  smartView = null;
  smartLoad();
}
