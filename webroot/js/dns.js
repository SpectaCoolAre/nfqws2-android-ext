/* nfqws2 WebUI · dns.js — DNS по профилям
   Скрипты подключаются из index.html обычными <script> по порядку и делят одну
   глобальную область: функции и let/const одного файла видны в остальных.

   Как в Keenetic: профиль — это DNS-серверы (DoH, DoT, DoQ, обычные) и домены;
   запросы к доменам профиля и их поддоменам идут на его серверы, остальные —
   на DNS по умолчанию. Всё сохраняется сразу, без кнопки «Сохранить»: так же
   устроены экраны домашней Wi‑Fi и фильтра приложений. Модуль проверяет ввод
   ещё раз (lib/dns.sh), здесь — только чтобы подсказать раньше. */

/* Типы серверов: схема адреса в синтаксисе dnsproxy */
const DNS_TYPES = [
  {k: 'doh',  label: 'DoH (HTTPS)',          short: 'DoH',  enc: true,  ph: 'https://dns.google/dns-query',
   hint: 'Адрес DoH-сервера. Если ввести только имя, допишется /dns-query.'},
  {k: 'dot',  label: 'DoT (TLS)',            short: 'DoT',  enc: true,  ph: 'dns.google',
   hint: 'Имя или IP DoT-сервера, порт по умолчанию 853.'},
  {k: 'doq',  label: 'DoQ (QUIC)',           short: 'DoQ',  enc: true,  ph: 'dns.adguard-dns.com',
   hint: 'Имя или IP DoQ-сервера, порт по умолчанию 853.'},
  {k: 'doh3', label: 'DoH3 (HTTP/3)',        short: 'DoH3', enc: true,  ph: 'https://dns.google/dns-query',
   hint: 'DoH поверх HTTP/3 (QUIC). Сервер должен его поддерживать.'},
  // Как «DNS-сервер» в Keenetic: запрос по UDP, ответ, который в UDP не влез, —
  // повтором по TCP (так делает dnsproxy). Отдельный «только TCP» в меню не
  // предлагается, но адрес tcp:// из старых профилей и файлов показывается.
  {k: 'udp',  label: 'Обычный DNS',          short: 'DNS',  enc: false, ph: '1.1.1.1',
   hint: 'IP-адрес сервера, при необходимости с портом: 1.1.1.1:53 или [2606:4700::1111]:53. Длинные ответы сервер сам отдаёт по TCP.'},
  {k: 'tcp',  label: 'Обычный DNS (только TCP)', short: 'TCP', enc: false, ph: '1.1.1.1', hidden: true,
   hint: 'IP-адрес или имя, при необходимости с портом.'},
  {k: 'sdns', label: 'DNS-штамп (sdns://)',  short: 'sdns', enc: true,  ph: 'sdns://…',
   hint: 'Штамп DNSCrypt или DoH целиком, начиная с sdns://.'}
];
const dnsTypeOf = s => /^https:\/\//.test(s) ? 'doh' : /^h3:\/\//.test(s) ? 'doh3' : /^tls:\/\//.test(s) ? 'dot' :
  /^quic:\/\//.test(s) ? 'doq' : /^tcp:\/\//.test(s) ? 'tcp' : /^sdns:\/\//.test(s) ? 'sdns' : 'udp';
const dnsTypeMeta = k => DNS_TYPES.find(x => x.k === k) || DNS_TYPES[4];
/* Адрес без схемы — для строки списка: тип и так подписан */
const dnsServerShort = s => s.replace(/^(https|h3|tls|quic|tcp|udp):\/\//, '');

/* Имя хоста в punycode (пример.рф -> xn--e1afmkfd.xn--p1ai): так его сравнивает dnsproxy */
function dnsPuny(host){
  if(/^[\x00-\x7f]*$/.test(host)) return host.toLowerCase();
  try { return new URL('http://' + host).hostname; } catch(e) { return ''; }
}
const DNS_HOST_RE = /^([a-z0-9-]+\.)*[a-z0-9-]+$|^\[[0-9a-f:.]+\]$/i;
const DNS_IP4_RE = /^\d{1,3}(\.\d{1,3}){3}$/;
const DNS_DOMAIN_RE = /^[a-z0-9_]([a-z0-9_-]{0,61}[a-z0-9_])?(\.[a-z0-9_]([a-z0-9_-]{0,61}[a-z0-9_])?)*$/;

/* Ввод пользователя -> адрес в синтаксисе dnsproxy, или '' если не разобрать */
function dnsBuildServer(type, raw){
  let v = String(raw || '').trim();
  if(!v || /\s|["'`$\\]/.test(v)) return '';
  if(type === 'sdns') return /^sdns:\/\/[A-Za-z0-9_=-]+$/.test(v) ? v : '';
  v = v.replace(/^(https|h3|tls|quic|tcp|udp):\/\//i, '');
  const m = /^(\[[^\]]+\]|[^/:]+)(:\d{1,5})?(\/.*)?$/.exec(v);
  if(!m) {
    // голый IPv6 без скобок — только для обычного DNS
    return type === 'udp' && /^[0-9a-f]*:[0-9a-f:.]+(%[\w.-]+)?$/i.test(v) ? v : '';
  }
  const host = m[1].startsWith('[') ? m[1] : dnsPuny(m[1]), port = m[2] || '', path = m[3] || '';
  if(!host || !DNS_HOST_RE.test(host)) return '';
  if(type === 'doh' || type === 'doh3'){
    if(path && !/^\/[\w.~%/?=&+-]*$/.test(path)) return '';
    return (type === 'doh' ? 'https://' : 'h3://') + host + port + (path || '/dns-query');
  }
  if(path) return '';
  if(type === 'dot') return 'tls://' + host + port;
  if(type === 'doq') return 'quic://' + host + port;
  if(type === 'tcp') return 'tcp://' + host + port;
  // обычный DNS по UDP — только IP: имя сервера резолвить было бы нечем
  if(!(DNS_IP4_RE.test(host) || host.startsWith('['))) return '';
  return host + port;
}

/* Строка доменов (через пробел, запятую или с новой строки) -> {ok, bad} */
function dnsParseDomains(text){
  const ok = [], bad = [];
  // комментарий — от # до конца строки, как в списках модуля
  String(text || '').split('\n').map(l => l.replace(/#.*$/, '')).join(' ').split(/[\s,;]+/).forEach(w => {
    if(!w) return;
    let d = w.toLowerCase().replace(/^[a-z]+:\/\//, '').replace(/[/:?#].*$/, '').replace(/^\*?\./, '').replace(/\.$/, '');
    d = dnsPuny(d);
    if(d && DNS_DOMAIN_RE.test(d) && d.length <= 253){ if(!ok.includes(d)) ok.push(d); }
    else bad.push(w);
  });
  return {ok, bad};
}

/* ── Состояние ──────────────────────────────────────────────────────────── */
let dnsSt = {status: {}, profiles: [], presets: []}, dnsLoaded = false, dnsCur = null;
/* Выбор профилей (долгое нажатие): null — обычный список, иначе Set id */
let dnsSel = null;

/* Ответ dns-state: #status (ключ=значение), затем #profile/#preset с содержимым файлов */
function parseDnsState(out){
  const st = {status: {}, profiles: [], presets: []};
  let cur = null;
  String(out || '').split('\n').forEach(raw => {
    const l = raw.replace(/\r$/, '');
    if(l === '#status'){ cur = st.status; return; }
    const h = /^#(profile|preset) ([a-z0-9_-]+)$/.exec(l);
    if(h){
      cur = {id: h[2], name: '', desc: '', enabled: false, servers: [], domains: []};
      (h[1] === 'profile' ? st.profiles : st.presets).push(cur);
      return;
    }
    if(!cur) return;
    const i = l.indexOf('=');
    if(i < 0) return;
    const k = l.slice(0, i), v = l.slice(i + 1);
    if(cur === st.status) cur[k] = v;
    else if(k === 'NAME') cur.name = v;
    else if(k === 'DESC') cur.desc = v;
    else if(k === 'ENABLED') cur.enabled = v === '1';
    else if(k === 'SERVER' && v) cur.servers.push(v);
    else if(k === 'DOMAIN' && v) cur.domains.push(v);
  });
  return st;
}
const dnsSerialize = p => ['NAME=' + p.name.replace(/[\r\n]/g, ' ')]
  .concat(p.desc ? ['DESC=' + p.desc.replace(/[\r\n]/g, ' ')] : [])
  .concat(['ENABLED=' + (p.enabled ? 1 : 0)], p.servers.map(s => 'SERVER=' + s), p.domains.map(d => 'DOMAIN=' + d))
  .join('\n') + '\n';
const dnsMax = (k, def) => +dnsSt.status['max_' + k] || def;
const dnsProfile = id => dnsSt.profiles.find(p => p.id === id);

async function loadDnsState(){
  const r = await ctlx(['dns-state'], 20000);
  if(r.code && !r.out){ toast(errText(r, 'Не удалось прочитать настройки DNS')); return false; }
  dnsSt = parseDnsState(r.out);
  dnsSt.profiles.sort((a, b) => a.name.localeCompare(b.name, LANG));
  dnsLoaded = true;
  return true;
}

/* Склонение: 1 сервер, 2 сервера, 5 серверов */
function dnsPlural(n, one, few, many){
  if(LANG === 'en') return n === 1 ? one : few;
  const a = n % 10, b = n % 100;
  return a === 1 && b !== 11 ? one : (a >= 2 && a <= 4 && (b < 12 || b > 14) ? few : many);
}
const dnsCountServers = n => n + ' ' + dnsPlural(n, t('сервер'), t('сервера'), t('серверов'));
const dnsCountDomains = n => n + ' ' + dnsPlural(n, t('домен'), t('домена'), t('доменов'));
function dnsProfileSummary(p){
  const types = [...new Set(p.servers.map(s => dnsTypeMeta(dnsTypeOf(s)).short))].join(', ');
  const parts = [];
  if(p.servers.length) parts.push((types ? types + ' · ' : '') + dnsCountServers(p.servers.length));
  else parts.push(t('нет серверов'));
  parts.push(p.domains.length ? dnsCountDomains(p.domains.length) : t('без доменов'));
  if(dnsSt.status.default === p.id) parts.push(t('по умолчанию'));
  return parts.join(' · ');
}

/* ══ ЭКРАН «DNS по профилям» ════════════════════════════════════════════ */
async function dnsInit(){
  if(dnsSel) dnsSelExit(true);
  if(!dnsLoaded) renderDns();
  if(await loadDnsState()) renderDns();
}

function dnsDefaultLabel(){
  const d = dnsSt.status.default || 'net';
  if(d === 'net') return t('DNS сети');
  const p = dnsProfile(d);
  return p ? p.name : t('DNS сети');
}

/* Что сейчас мешает или о чём стоит знать — баннеры над списком */
function dnsWarnings(){
  const s = dnsSt.status, w = [];
  if(s.enabled !== '1') return '';
  if(s.private === 'hostname')
    // как предложение на экране домашней Wi‑Fi: текст и кнопка, которая не сжимается
    w.push('<div class="suggest">' + icon('warn', 's24') + '<span class="grow">' +
      esc(t('В Android включён «Частный DNS» ({0}): запросы идут мимо модуля, и профили не применяются, пока он не выключен.', s.private_host || '—')) +
      '</span><button class="btn tonal sm state" onclick="openPrivateDnsSettings()">' + esc(t('Открыть')) + '</button></div>');
  if(s.proxy === 'missing')
    w.push(banner('danger', 'error', t('В модуле нет dnsproxy. Переустановите модуль из архива релиза.')));
  else if(s.error)
    w.push(banner('danger', 'error', t('Ошибка: {0}', s.error)));
  if(s.service !== 'running' && s.standalone !== '1')
    w.push(banner('', 'info', t('Служба не запущена: профили применятся при её запуске. Чтобы DNS работал и без неё, включите «Без службы обхода».')));
  if(s.ipv6 === 'none' && s.rules === 'on')
    w.push(banner('warn', 'warn', t('Запросы к IPv6-серверам DNS идут мимо: в ядре нет ip6tables nat, а у сети нет IPv4-серверов.')));
  return w.join('');
}

function dnsStateRow(){
  const s = dnsSt.status;
  let title, sub = '';
  const working = s.rules === 'on' && s.proxy === 'running';
  if(s.private === 'hostname') title = t('Не применяется: включён «Частный DNS»');
  else if(working){
    title = s.service === 'running' ? t('Работает') : t('Работает без службы обхода');
    sub = t('Перехвачено запросов: {0}', fmtCount(+s.hits || 0));
  } else if(s.service !== 'running' && s.standalone !== '1') title = t('Ожидает запуска службы');
  else if(!dnsSt.profiles.some(p => p.enabled && p.servers.length && p.domains.length) && (s.default || 'net') === 'net')
    title = t('Не активно: нет включённых профилей с доменами');
  else title = t('Не работает — см. журнал DNS');
  // Куда сейчас уходит всё, что не попало в профили: выбранный профиль или
  // DNS сети. Адреса сети — только когда они и правда используются.
  if(working){
    const d = s.default || 'net', p = d !== 'net' && dnsProfile(d);
    sub += ' · ' + (p ? t('остальное — через «{0}»', p.name)
      : t('остальное — через DNS сети{0}', s.net_dns ? ' (' + s.net_dns.replace(/,/g, ', ') + ')' : ''));
  }
  return '<div class="list-item' + (sub ? ' two-line' : '') + '">' +
    '<span class="li-icon">' + icon('status', 's24') + '</span>' +
    '<span class="li-text"><span class="li-primary">' + esc(title) + '</span>' +
      (sub ? '<span class="li-secondary">' + esc(sub) + '</span>' : '') + '</span></div>';
}

function renderDns(){
  const s = dnsSt.status, on = s.enabled === '1';
  $('dns-toggle').checked = on;
  $('dns-main').classList.toggle('on', on);
  $('dns-body').classList.toggle('is-disabled', !on || !dnsLoaded);
  $('dns-body').inert = !on || !dnsLoaded;
  // одной строкой через setHTML: дописанное мимо него он не видит и повторял бы
  setHTML('dns-warn', !dnsLoaded ? '' : dnsWarnings() + (s.private === 'opportunistic' && on
    ? '<div class="helper">' + esc(t('«Частный DNS» в Android — «Автоматически»: если DNS сети поддерживает DoT, часть запросов может пройти мимо модуля. Надёжнее выбрать «Отключено».')) + '</div>'
    : ''), false);
  setHTML('dns-general',
    settingsRow({icon: 'globe', title: 'DNS по умолчанию', sub: dnsDefaultLabel() + ' · ' + t('для доменов вне профилей'),
      on: 'pickDnsDefault(this)', menu: true}) +
    settingsRow({icon: 'shield', title: 'Без службы обхода', sw: true, checked: s.standalone === '1',
      sub: t('DNS работает, даже когда служба остановлена или на паузе. Выключить его тогда можно только переключателем выше.'),
      on: 'setDnsStandalone(this.checked, this)'}) +
    (dnsLoaded && on ? dnsStateRow() : '') +
    settingsRow({icon: 'search', title: 'Проверить домен', sub: t('Через какой профиль он резолвится и в какой адрес'), on: 'testDnsDomain()'}) +
    settingsRow({icon: 'logs', title: 'Журнал DNS', sub: t('Запуски, перезапуски и ошибки dnsproxy'), on: 'openDnsLog()'}),
    false);
  const max = dnsMax('profiles', 32);
  $('dns-count').textContent = dnsSt.profiles.length ? dnsSt.profiles.length + ' / ' + max : '';
  setHTML('dns-profiles', dnsSt.profiles.length ? dnsSt.profiles.map(p => {
    const sel = dnsSel && dnsSel.has(p.id);
    return '<div class="list-item two-line clickable state' + (sel ? ' selected' : '') + '" role="button" tabindex="0" data-id="' + esc(p.id) + '"' +
        (dnsSel ? ' aria-pressed="' + !!sel + '"' : '') + ' onclick="dnsRowClick(' + jsArg(p.id) + ')">' +
      '<span class="li-icon">' + icon('dns', 's24') + '</span>' +
      '<span class="li-text"><span class="li-primary truncate">' + esc(p.name) + '</span>' +
        '<span class="li-secondary truncate">' + esc(dnsProfileSummary(p)) + '</span></span>' +
      '<span class="li-trail">' + (dnsSel
        ? '<input type="checkbox" class="checkbox" tabindex="-1" aria-hidden="true"' + (sel ? ' checked' : '') + ' onclick="event.preventDefault()">'
        : '<input type="checkbox" class="switch" role="switch"' + (p.enabled ? ' checked' : '') +
          ' aria-label="' + esc(t('Профиль «{0}» включён', p.name)) + '" onclick="event.stopPropagation()"' +
          ' onchange="toggleDnsProfile(' + jsArg(p.id) + ', this.checked, this)">') + '</span>' +
    '</div>';
  }).join('')
    : '<div class="empty"><span class="empty-icon">' + icon('dns', 's24') + '</span><span>' +
      esc(t('Профилей пока нет. Добавьте свой или возьмите готовый из пресетов.')) + '</span></div>', false);
  $('dns-add').disabled = dnsSt.profiles.length >= max;
}

/* ── Выбор нескольких профилей ─────────────────────────────────────────
   Долгое нажатие на профиль включает выбор: переключатели становятся
   флажками, в верхней панели — «выбрать все», «отмена» и «удалить».
   «Назад» и «отмена» возвращают обычный список. */
function dnsRowClick(id){
  if(dnsLongFired){ dnsLongFired = false; return; }
  if(!dnsSel) return openDnsProfile(id);
  if(dnsSel.has(id)) dnsSel.delete(id); else dnsSel.add(id);
  if(!dnsSel.size) return dnsSelExit();
  dnsSelRender();
}
function dnsSelEnter(id){
  dnsSel = new Set([id]);
  dnsSelRender();
  scheduleSync();
}
function dnsSelExit(quiet){
  dnsSel = null;
  if(quiet || currentPage !== 'dns') return;
  renderAppBar('dns', false);
  renderDns();
  scheduleSync();
}
function dnsSelRender(){
  if(!dnsSel || currentPage !== 'dns') return;
  $('app-title').textContent = t('Выбрано: {0}', dnsSel.size);
  const all = dnsSt.profiles.length && dnsSt.profiles.every(p => dnsSel.has(p.id));
  fillBarActions([
    {icon: 'select-all', label: all ? 'Снять выбор' : 'Выбрать все', fn: dnsSelAll},
    {icon: 'close', label: 'Отменить выбор', fn: () => dnsSelExit()},
    {icon: 'trash', label: 'Удалить выбранные', fn: dnsSelDelete}
  ]);
  renderDns();
}
function dnsSelAll(){
  if(dnsSt.profiles.every(p => dnsSel.has(p.id))) return dnsSelExit();
  dnsSt.profiles.forEach(p => dnsSel.add(p.id));
  dnsSelRender();
}
async function dnsSelDelete(){
  const ps = dnsSt.profiles.filter(p => dnsSel.has(p.id));
  if(!ps.length) return;
  const one = ps.length === 1;
  const yes = await mdConfirm(one ? t('Удалить профиль?') : t('Удалить профили: {0}?', ps.length),
    one ? t('Профиль «{0}» со всеми серверами и доменами будет удалён.', ps[0].name)
        : t('Будут удалены со всеми серверами и доменами: {0}.', ps.map(p => '«' + p.name + '»').join(', ')),
    {ok: t('Удалить'), danger: true});
  if(!yes) return;
  const r = await withBusy(['dns-delete'].concat(ps.map(p => p.id)), 40000);
  if(r.code){ toast(errText(r, 'Не удалось удалить')); return; }
  await loadDnsState();
  dnsSelExit();
  toast(one ? t('Профиль «{0}» удалён', ps[0].name) : t('Удалено профилей: {0}', ps.length));
}
/* Долгое нажатие: 500 мс без сдвига пальца; click после него гасится */
let dnsLongFired = false, dnsLongCancel = () => {};
(function bindDnsLongPress(){
  const box = $('dns-profiles');
  let tm = 0, x0 = 0, y0 = 0;
  const cancel = () => { clearTimeout(tm); tm = 0; };
  box.addEventListener('pointerdown', e => {
    const row = e.target.closest('.list-item[data-id]');
    cancel(); dnsLongFired = false;
    if(!row || dnsSel || e.target.closest('.switch')) return;
    // Касание у края экрана — начало системного жеста Android («домой» снизу,
    // «назад» сбоку): WebView получает его pointerdown, но pointerup уже не
    // приходит, и таймер включал выбор профиля. Такие касания не считаем.
    if(e.pointerType !== 'mouse' && inGestureZone(e.clientX, e.clientY)) return;
    x0 = e.clientX; y0 = e.clientY;
    // Жест «назад» системы мог увести с экрана, не прислав pointerup: тогда
    // таймер срабатывал уже на другом экране и вешал туда панель выбора
    tm = setTimeout(() => {
      tm = 0;
      if(currentPage !== 'dns' || !row.isConnected || openSheetId || document.hidden || !document.hasFocus()) return;
      dnsLongFired = true; dnsSelEnter(row.dataset.id);
    }, 500);
  });
  box.addEventListener('pointermove', e => { if(tm && Math.hypot(e.clientX - x0, e.clientY - y0) > 10) cancel(); });
  ['pointerup', 'pointercancel', 'pointerleave'].forEach(ev => box.addEventListener(ev, cancel));
  dnsLongCancel = cancel;
  // Жест увёл WebView в фон (свернули, открыли список приложений) — отмена
  addEventListener('blur', cancel);
  addEventListener('pagehide', cancel);
  document.addEventListener('visibilitychange', cancel);
  box.addEventListener('contextmenu', e => { if(e.target.closest('.list-item[data-id]')) e.preventDefault(); });
})();

function openDnsLog(){ logSource = 'dns'; store.set('nfq_log_src', 'dns'); navigate('logs'); }

async function setDnsEnabled(on){
  const r = await withBusy(['dns-set-enabled', on ? '1' : '0'], 40000);
  if(r.code){ toast(errText(r, 'Не удалось сохранить')); $('dns-toggle').checked = !on; return; }
  await loadDnsState();
  renderDns();
}

async function setDnsStandalone(on, el){
  const r = await withBusy(['dns-set-standalone', on ? '1' : '0'], 40000);
  if(r.code){ toast(errText(r, 'Не удалось сохранить')); if(el) el.checked = !on; return; }
  await loadDnsState();
  renderDns();
}

function pickDnsDefault(anchor){
  const cur = dnsSt.status.default || 'net';
  const items = [{label: t('DNS сети (как без модуля)'), icon: cur === 'net' ? 'check' : '', onClick: () => setDnsDefault('net')}];
  const withServers = dnsSt.profiles.filter(p => p.servers.length);
  if(withServers.length) items.push('-');
  withServers.forEach(p => items.push({label: p.name, icon: cur === p.id ? 'check' : '', onClick: () => setDnsDefault(p.id)}));
  openMenu(anchor, items);
}
async function setDnsDefault(id){
  const r = await withBusy(['dns-set-default', id], 40000);
  if(r.code){ toast(errText(r, 'Не удалось сохранить')); return; }
  dnsSt.status.default = id;
  await loadDnsState();
  if(currentPage === 'dns') renderDns(); else if(currentPage === 'dnsprof') renderDnsProfile();
}

async function toggleDnsProfile(id, on, el){
  const p = dnsProfile(id);
  if(!p) return;
  if(on && !p.servers.length){
    toast(t('Сначала добавьте в профиль DNS-сервер'));
    if(el) el.checked = false;
    return;
  }
  const r = await withBusy(['dns-profile-enable', id, on ? '1' : '0'], 40000);
  if(r.code){ toast(errText(r, 'Не удалось сохранить')); if(el) el.checked = !on; return; }
  p.enabled = on;
  if(on && !p.domains.length && dnsSt.status.default !== id)
    toast(t('В профиле нет доменов: он работает, только если выбран DNS по умолчанию'));
  await loadDnsState();
  if(currentPage === 'dns') renderDns(); else renderDnsProfile();
}

/* Свободный идентификатор профиля: из названия латиницей, иначе p1, p2… */
function dnsNewId(base){
  let id = String(base || '').toLowerCase().replace(/[^a-z0-9_-]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 30);
  if(!id) id = 'p';
  let n = 1, out = id;
  while(dnsProfile(out)) out = id + '-' + (++n);
  return out;
}

function addDnsProfile(anchor){
  openMenu(anchor, [
    {label: t('Новый профиль'), icon: 'add', onClick: createDnsProfile},
    {label: t('Из пресетов…'), icon: 'list', onClick: openDnsPresets}
  ]);
}
async function createDnsProfile(){
  const name = await mdPrompt(t('Новый профиль'), t('Например: Instagram, ИИ-сервисы, Игры.'), '', t('Название'), {ok: t('Создать')});
  if(!name) return;
  const p = {id: dnsNewId(name), name, desc: '', enabled: false, servers: [], domains: []};
  if(await saveDnsProfile(p, true)) openDnsProfile(p.id);
}

function openDnsPresets(){
  // сначала пресеты с доменами (что и куда), за ними публичные серверы для «по умолчанию»
  const list = dnsSt.presets.slice().sort((a, b) => (b.domains.length > 0) - (a.domains.length > 0) || a.name.localeCompare(b.name, LANG));
  setHTML('dns-preset-list', list.map(p =>
    '<div class="list-item two-line clickable state" role="button" tabindex="0" onclick="addDnsPreset(' + jsArg(p.id) + ')">' +
      '<span class="li-icon">' + icon(p.domains.length ? 'dns' : 'globe', 's24') + '</span>' +
      '<span class="li-text"><span class="li-primary">' + esc(t(p.name)) + '</span>' +
        '<span class="li-secondary">' + esc(t(p.desc) || dnsProfileSummary(p)) + '</span></span>' +
    '</div>').join(''), false);
  openSheet('dns-preset-sheet');
}
async function addDnsPreset(id){
  const pre = dnsSt.presets.find(p => p.id === id);
  if(!pre) return;
  closeSheet();
  const p = Object.assign({}, pre, {id: dnsNewId(pre.id), name: t(pre.name), desc: t(pre.desc),
    servers: pre.servers.slice(), domains: pre.domains.slice(), enabled: pre.domains.length > 0});
  if(await saveDnsProfile(p, true)){
    toast(t('Профиль «{0}» добавлен', p.name));
    if(currentPage === 'dns') renderDns();
  }
}

/* Сохранение профиля целиком; модуль применяет его сразу, если служба запущена */
async function saveDnsProfile(p, isNew){
  const r = await withBusy(['dns-save-b64', p.id, b64(dnsSerialize(p))], 40000);
  if(r.code){ toast(errText(r, 'Не удалось сохранить')); return false; }
  await loadDnsState();
  return true;
}

async function testDnsDomain(){
  const v = await mdPrompt(t('Проверить домен'), t('Запрос пойдёт через системный резолвер — так же, как у приложений.'), 'instagram.com', t('Домен'),
    {ok: t('Проверить')});
  if(!v) return;
  const {ok} = dnsParseDomains(v);
  if(!ok.length){ toast(t('Некорректный домен')); return; }
  const r = await withBusy(['dns-test', ok[0]], 20000);
  if(r.code){ toast(errText(r, 'Не удалось проверить')); return; }
  const [ip, prof] = (r.out.trim().split('\n').pop() || '').split('\t');
  const p = prof && dnsProfile(prof);
  mdDialog({title: ok[0], iconName: 'dns', cancel: false, ok: t('Понятно'),
    text: t('Адрес: {0}', ip && ip !== '—' ? ip : t('не получен')) + '\n' +
      t('Через: {0}', p ? t('профиль «{0}»', p.name) : t('DNS по умолчанию — {0}', dnsDefaultLabel()))});
}

/* «Частный DNS» в Android: отдельного экрана для него нет, ближайший —
   «Сеть и интернет», он там внизу. */
async function openPrivateDnsSettings(){
  const r = await sh('am start -a android.settings.WIRELESS_SETTINGS >/dev/null 2>&1', 8000);
  if(r.code) toast(t('Откройте: Настройки → Сеть и интернет → Частный DNS'));
}

/* ══ ЭКРАН ПРОФИЛЯ ══════════════════════════════════════════════════════ */
const DNS_DOMAINS_SHOWN = 50;

function openDnsProfile(id){
  dnsCur = id;
  navigate('dnsprof');
}
async function dnsProfInit(){
  if(!dnsLoaded) await loadDnsState();
  renderDnsProfile();
}
function renderDnsProfile(){
  const p = dnsProfile(dnsCur);
  if(!p){ if(currentPage === 'dnsprof') goBack(); return; }
  $('app-title').textContent = p.name;
  const isDef = dnsSt.status.default === p.id;
  setHTML('dnsp-head',
    '<label class="list-item clickable state">' +
      '<span class="li-icon">' + icon('dns', 's24') + '</span>' +
      '<span class="li-text"><span class="li-primary">' + esc(t('Профиль включён')) + '</span></span>' +
      '<span class="li-trail"><input type="checkbox" class="switch" role="switch" id="dnsp-enabled"' + (p.enabled ? ' checked' : '') +
        ' aria-label="' + esc(t('Профиль включён')) + '" onchange="toggleDnsProfile(dnsCur, this.checked, this)"></span>' +
    '</label>' +
    settingsRow({icon: 'edit', title: 'Название', sub: p.name, on: 'renameDnsProfile()'}) +
    settingsRow({icon: 'info', title: 'Описание', sub: p.desc || t('Не задано'), on: 'describeDnsProfile()'}) +
    settingsRow({icon: 'globe', title: 'DNS по умолчанию', sub: isDef
        ? t('Да: всё, что не попало в другие профили, идёт через этот')
        : t('Нет: только домены этого профиля'), on: 'toggleDnsDefaultHere()'}),
    false);

  const maxS = dnsMax('servers', 8);
  $('dnsp-scount').textContent = p.servers.length + ' / ' + maxS;
  setHTML('dnsp-servers', p.servers.length ? p.servers.map((s, i) => {
    const m = dnsTypeMeta(dnsTypeOf(s));
    return '<div class="list-item two-line clickable state" role="button" tabindex="0" onclick="editDnsServer(' + i + ')">' +
      '<span class="li-icon">' + icon(m.enc ? 'shield' : 'globe', 's24') + '</span>' +
      '<span class="li-text"><span class="li-primary li-mono truncate">' + esc(dnsServerShort(s)) + '</span>' +
        '<span class="li-secondary">' + esc(t(m.label)) + '</span></span>' +
      '<button class="icon-btn sm state" aria-label="' + esc(t('Убрать сервер {0}', dnsServerShort(s))) + '"' +
        ' onclick="event.stopPropagation(); removeDnsServer(' + i + ')">' + icon('trash', 's20') + '</button>' +
    '</div>';
  }).join('') : '<div class="empty"><span class="empty-icon">' + icon('globe', 's24') + '</span><span>' +
    esc(t('Добавьте хотя бы один DNS-сервер: без него профиль не работает.')) + '</span></div>', false);
  $('dnsp-add-server').disabled = p.servers.length >= maxS;

  const maxD = dnsMax('domains', 1000);
  $('dnsp-dcount').textContent = p.domains.length + ' / ' + maxD;
  const shown = p.domains.slice(0, DNS_DOMAINS_SHOWN);
  setHTML('dnsp-domains', p.domains.length ? shown.map((d, i) =>
    '<div class="list-item">' +
      '<span class="li-text"><span class="li-primary li-mono truncate">' + esc(d) + '</span></span>' +
      '<button class="icon-btn sm state" aria-label="' + esc(t('Убрать домен {0}', d)) + '" onclick="removeDnsDomain(' + i + ')">' +
        icon('trash', 's20') + '</button>' +
    '</div>').join('') +
    (p.domains.length > shown.length
      ? '<div class="list-item clickable state" role="button" tabindex="0" onclick="editDnsDomainsText()">' +
          '<span class="li-text"><span class="li-secondary">' +
          esc(t('И ещё {0} — открыть списком', p.domains.length - shown.length)) + '</span></span></div>'
      : '')
    : '<div class="empty"><span class="empty-icon">' + icon('list', 's24') + '</span><span>' +
      esc(isDef ? t('Доменов нет: профиль работает как DNS по умолчанию.')
                : t('Доменов нет: профиль используется, только если выбран DNS по умолчанию.')) + '</span></div>', false);
  $('dnsp-add-domain').disabled = p.domains.length >= maxD;
}

/* Изменить профиль и сохранить; при ошибке — откат к сохранённому */
async function updateDnsProfile(fn){
  const p = dnsProfile(dnsCur);
  if(!p) return false;
  const next = Object.assign({}, p, {servers: p.servers.slice(), domains: p.domains.slice()});
  if(fn(next) === false) return false;
  const ok = await saveDnsProfile(next);
  renderDnsProfile();
  return ok;
}

async function renameDnsProfile(){
  const p = dnsProfile(dnsCur);
  const v = await mdPrompt(t('Название профиля'), '', p.name, t('Название'));
  if(v) updateDnsProfile(x => { x.name = v; });
}
async function describeDnsProfile(){
  const p = dnsProfile(dnsCur);
  const v = await mdPrompt(t('Описание профиля'), t('Необязательно: для чего этот профиль.'), p.desc, t('Описание'));
  if(v !== null) updateDnsProfile(x => { x.desc = v; });
}
function toggleDnsDefaultHere(){
  const p = dnsProfile(dnsCur);
  if(dnsSt.status.default === p.id) setDnsDefault('net');
  else if(!p.servers.length) toast(t('Сначала добавьте в профиль DNS-сервер'));
  else setDnsDefault(p.id);
}

/* Добавление сервера: сначала тип (меню), затем адрес */
function addDnsServer(anchor){
  openMenu(anchor, DNS_TYPES.filter(m => !m.hidden)
    .map(m => ({label: t(m.label), icon: m.enc ? 'shield' : 'globe', onClick: () => promptDnsServer(m.k, '', -1)})));
}
function editDnsServer(i){
  const p = dnsProfile(dnsCur), s = p && p.servers[i];
  if(s != null) promptDnsServer(dnsTypeOf(s), s, i);
}
async function promptDnsServer(type, value, index){
  const m = dnsTypeMeta(type);
  let v = value;
  for(;;){
    v = await mdPrompt(t(m.label), t(m.hint) + '\n' + t('Например: {0}', m.ph), v || '', t('Адрес сервера'),
      {ok: index < 0 ? t('Добавить') : t('Сохранить'), inputmode: 'url'});
    if(v === null) return;
    const srv = dnsBuildServer(type, v);
    if(!srv){ toast(t('Не похоже на адрес сервера {0}', m.short)); continue; }
    const p = dnsProfile(dnsCur);
    if(p.servers.some((s, j) => s === srv && j !== index)){ toast(t('Такой сервер уже есть')); return; }
    await updateDnsProfile(x => { if(index < 0) x.servers.push(srv); else x.servers[index] = srv; });
    return;
  }
}
async function removeDnsServer(i){
  await updateDnsProfile(x => {
    x.servers.splice(i, 1);
    // без серверов профиль работать не может — выключаем, а не держим «включённым впустую»
    if(!x.servers.length) x.enabled = false;
  });
}

async function addDnsDomains(){
  const v = await mdPrompt(t('Добавить домены'),
    t('Один или несколько через пробел или запятую. Поддомены входят сами: instagram.com — это и www.instagram.com.'),
    '', t('Домены'), {ok: t('Добавить'), inputmode: 'url'});
  if(!v) return;
  const {ok, bad} = dnsParseDomains(v);
  const p = dnsProfile(dnsCur);
  const fresh = ok.filter(d => !p.domains.includes(d));
  if(bad.length) toast(t('Пропущены некорректные: {0}', bad.slice(0, 3).join(', ') + (bad.length > 3 ? '…' : '')));
  if(!fresh.length){ if(!bad.length) toast(t('Эти домены уже есть')); return; }
  if(p.domains.length + fresh.length > dnsMax('domains', 1000)){ toast(t('В профиле не больше {0} доменов', dnsMax('domains', 1000))); return; }
  await updateDnsProfile(x => { x.domains = x.domains.concat(fresh); });
}
async function removeDnsDomain(i){
  await updateDnsProfile(x => { x.domains.splice(i, 1); });
}
/* Весь список доменов — в полноэкранном редакторе, по одному на строку */
function editDnsDomainsText(){
  const p = dnsProfile(dnsCur);
  openEditorWith({target: 'dns-domains', title: p.name, lang: 'list',
    hint: t('По одному домену на строку. Поддомены входят сами. Строки с # игнорируются.'),
    text: p.domains.join('\n') + (p.domains.length ? '\n' : ''),
    onSave: async val => {
      const {ok, bad} = dnsParseDomains(val);
      if(bad.length) return t('Некорректные домены: {0}', bad.slice(0, 5).join(', ') + (bad.length > 5 ? '…' : ''));
      if(ok.length > dnsMax('domains', 1000)) return t('В профиле не больше {0} доменов', dnsMax('domains', 1000));
      const saved = await updateDnsProfile(x => { x.domains = ok; });
      return saved ? '' : t('Не удалось сохранить');
    }});
}

async function deleteDnsProfile(){
  const p = dnsProfile(dnsCur);
  if(!p) return;
  const yes = await mdConfirm(t('Удалить профиль?'), t('Профиль «{0}» со всеми серверами и доменами будет удалён.', p.name),
    {ok: t('Удалить'), danger: true});
  if(!yes) return;
  const r = await withBusy(['dns-delete', p.id], 40000);
  if(r.code){ toast(errText(r, 'Не удалось удалить')); return; }
  await loadDnsState();
  toast(t('Профиль «{0}» удалён', p.name));
  goBack();
}
