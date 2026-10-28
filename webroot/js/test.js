/* nfqws2 WebUI · test.js — DPI Detector & проверка доступности */

const PROBE_REASON = {
  dns: 'DNS не отвечает',
  dns_fail: 'Ошибка DNS',
  reset: 'Соединение сброшено',
  tls_rst: 'TLS RST (сброс ClientHello)',
  tls_alert: 'TLS Alert (SNI блок)',
  tls_spoof: 'Подмена ответа (Spoof)',
  tls_mitm: 'Подмена сертификата (MITM)',
  drop: 'Тихий сброс (Drop)',
  timeout: 'Нет ответа (Timeout)',
  isp_redir: 'Заглушка провайдера (RKN)',
  ws_blocked: 'WebSocket режется (Discord)',
  refused: 'Соединение отклонено',
  tls: 'Ошибка TLS',
  other: 'Ошибка'
};

let testRunning = false;
let testCancelled = false;
let webViewAbortCtrl = null;
let currentTestTab = 'all';
let netInfoData = null;
let webResults = {};
let tcp16Results = {};
let dnsResults = {};
let lastRecommendation = null;

function testInit(){
  // секции результатов — по текущей вкладке (в разметке TCP 16K и DNS скрыты);
  // selectTestTab сам обновляет описание
  selectTestTab(currentTestTab);
  stat(true).then(renderTestWarn);
  renderTestWarn();
  refreshNetInfo();
}

function updateTestDesc(){
  const d = $('test-desc');
  if(!d) return;
  if(currentTestTab === 'web'){
    d.textContent = t('Каждый адрес из probe_hosts.list открывается с устройства три раза. Анализируются активные сбросы (TLS RST), инжекции TLS Alert, тихий дроп и подмена сертификатов.');
  } else if(currentTestTab === 'tcp16'){
    d.textContent = t('Тестирование соединений к зарубежным CDN и хостингам (Cloudflare, Hetzner, DO, OVH) с нарастающим объёмом данных до 32 КБ для выявления фильтра TCP 16-20KB.');
  } else if(currentTestTab === 'dns'){
    d.textContent = t('Проверка резолверов по UDP:53 и DoH для обнаружения перехвата портов провайдером и подмены IP-адресов на заглушки РКН.');
  } else {
    d.textContent = t('Комплексный анализ цензуры DPI: проверка доступности сайтов, детекция блокировок TCP 16-20KB и анализ перехвата DNS.');
  }
}

function selectTestTab(tab){
  currentTestTab = tab;
  document.querySelectorAll('#test-tabs .seg').forEach(btn => {
    btn.classList.toggle('on', btn.dataset.tab === tab);
  });
  const showWeb = tab === 'all' || tab === 'web';
  const showTcp = tab === 'all' || tab === 'tcp16';
  const showDns = tab === 'all' || tab === 'dns';
  // «Домен» — своя форма вместо общего запуска и его результатов
  const dom = tab === 'domain';
  ['test-run', 'test-warn', 'test-recommendation', 'test-empty'].forEach(id => {
    const el = $(id);
    if(!el) return;
    if(dom){ if(!el.hidden) el.dataset.domHidden = '1'; el.hidden = true; }
    else if(el.dataset.domHidden){ delete el.dataset.domHidden; el.hidden = false; }
  });
  $('test-sec-domain').hidden = !dom;
  if(dom){
    $('test-sec-web').hidden = $('test-sec-tcp16').hidden = $('test-sec-dns').hidden = true;
    return;
  }

  if($('test-sec-web')) $('test-sec-web').hidden = !showWeb;
  if($('test-sec-tcp16')) $('test-sec-tcp16').hidden = !showTcp;
  if($('test-sec-dns')) $('test-sec-dns').hidden = !showDns;

  updateTestDesc();
}

/* net-info отвечает одной строкой: NET <TAB> ip loc isp asn iface gw dns status strategy,
   неизвестное значение — «—». Раньше её разбирали как пары «ключ<TAB>значение»,
   и карточка сети всегда показывала «Локальная сеть». */
const NET_FIELDS = ['ip', 'loc', 'isp', 'asn', 'iface', 'gw', 'dns', 'status', 'strategy'];
function parseNetInfo(out){
  const data = {};
  const line = (out || '').split('\n').find(l => l.startsWith('NET\t'));
  if(!line) return data;
  const p = line.split('\t');
  NET_FIELDS.forEach((k, i) => {
    const v = (p[i + 1] || '').trim();
    if(v && v !== '—') data[k] = v;
  });
  return data;
}

async function refreshNetInfo(){
  const ipEl = $('net-ip'), ispEl = $('net-isp'), badgeEl = $('net-badge');
  if(!ipEl || !ispEl) return;
  ispEl.textContent = t('Загрузка сети…');
  const r = await ctlx(['net-info'], 15000);   // два curl по 4–6 с
  if(r.code && !r.out){
    ispEl.textContent = t('Сетевые данные недоступны');
    return;
  }
  const data = parseNetInfo(r.out);
  netInfoData = data;
  ipEl.textContent = data.ip ? `${data.ip} (${data.loc || '?'})` : t('Локальная сеть');
  const ispText = [data.isp, data.asn, data.dns ? `DNS: ${data.dns}` : ''].filter(Boolean).join(' · ');
  ispEl.textContent = ispText || t('Информация о провайдере отсутствует');

  if(badgeEl){
    const active = data.status === 'running';
    badgeEl.innerHTML = `<span class="status ${active ? 'ok' : 'info'}">${icon(active ? 'shield' : 'wifi', 's16')}</span>`;
  }
}

function renderTestWarn(){
  let w = '';
  if(S.running === false) w += banner('', 'info', S.paused
    ? (S.paused === '@vpn'
        ? t('Служба на паузе, пока включён VPN: проверяется прямое соединение, без обхода.')
        : S.paused === '@wl'
        ? t('Служба на паузе: у оператора белые списки. Проверяется прямое соединение, без обхода.')
        : t('Служба на паузе в домашнем Wi‑Fi: проверяется прямое соединение, без обхода.'))
    : t('Служба остановлена: проверяется прямое соединение, без обхода.'));
  setHTML('test-warn', w, false);
}

function testRow(i, h){
  return '<div class="list-item two-line" id="trow' + i + '">' +
    '<span class="status info" id="ti' + i + '"><span class="spinner" style="width:14px;height:14px;"></span></span>' +
    '<span class="li-text"><span class="li-primary li-mono truncate">' + esc(h) + '</span>' +
      '<span class="li-secondary" id="ts' + i + '">' + esc(t('Проверка…')) + '</span></span>' +
    '<span class="li-trail li-value" id="tr' + i + '">…</span>' +
  '</div>';
}

function finishTestRow(i, res){
  const ok = res.filter(x => x.ok), n = res.length;
  const badge = $('ti' + i);
  if(!badge) return;
  badge.className = 'status ' + (ok.length === n ? 'ok' : (ok.length ? 'warn' : 'bad'));
  badge.innerHTML = icon(ok.length === n ? 'check' : (ok.length ? 'warn' : 'close'), 's16');
  const tr = $('tr' + i);
  if(tr) tr.textContent = ok.length + '/' + n;
  const reasons = [...new Set(res.filter(x => !x.ok).map(x => t(PROBE_REASON[x.reason] || PROBE_REASON.other)))];
  const ts = $('ts' + i);
  if(ts) ts.textContent = (ok.length ? t('{0} мс в среднем', Math.round(ok.reduce((a, x) => a + x.ms, 0) / ok.length)) : '') +
    (ok.length && reasons.length ? ' · ' : '') + reasons.join(', ');
}

function renderTcp16Row(i, provider, ip, port, status, detail){
  const isClean = status === 'clean';
  const isDetected = status === 'detected';
  const stClass = isClean ? 'ok' : (isDetected ? 'bad' : 'info');
  const icName = isClean ? 'check' : (isDetected ? 'warn' : 'close');
  const trailText = isClean ? `${detail || 'OK'}` : (isDetected ? t('БЛОК @ {0}', detail) : t('Недоступен'));
  return '<div class="list-item two-line" id="tcprow' + i + '">' +
    '<span class="status ' + stClass + '">' + icon(icName, 's16') + '</span>' +
    '<span class="li-text">' +
      '<span class="li-primary truncate">' + esc(provider.replace(/_/g, ' ')) + ' <span class="muted li-mono">(' + esc(ip) + ')</span></span>' +
      '<span class="li-secondary">' + esc(isClean ? t('Чисто, передача данных стабильна') : (isDetected ? t('Обрыв сессии ТСПУ после {0}', detail) : t('Хост недоступен'))) + '</span>' +
    '</span>' +
    '<span class="li-trail ' + (isDetected ? 't-label-medium bad' : 'li-value') + '">' + esc(trailText) + '</span>' +
  '</div>';
}

function renderDnsRow(i, name, ip, udp, doh, hijacked, detail){
  const isHijacked = hijacked === 'yes';
  const isUdpOk = udp === 'ok', noUdp = udp === 'none';   // none — нет nslookup, UDP не проверялся
  const stClass = isHijacked ? 'bad' : (isUdpOk || noUdp ? 'ok' : 'warn');
  const icName = isHijacked ? 'warn' : (isUdpOk || noUdp ? 'check' : 'close');
  let sub = `UDP: ${isUdpOk ? 'OK' : noUdp ? '—' : t('Блок')}`;
  if(doh === 'dot_ok') sub += ' · DoT: OK';   // сервер без DoH: открыт ли хотя бы DoT
  else if(doh && doh !== 'none') sub += ` · DoH: ${doh === 'ok' ? 'OK' : t('Блок')}`;
  if(isHijacked) sub += ` · ${detail}`;
  const trail = isHijacked ? t('ПЕРЕХВАТ') : (isUdpOk ? 'OK' : noUdp ? '—' : t('СБОЙ'));
  return '<div class="list-item two-line" id="dnsrow' + i + '">' +
    '<span class="status ' + stClass + '">' + icon(icName, 's16') + '</span>' +
    '<span class="li-text">' +
      '<span class="li-primary truncate">' + esc(name.replace(/_/g, ' ')) + ' <span class="muted li-mono">(' + esc(ip) + ')</span></span>' +
      '<span class="li-secondary">' + esc(sub) + '</span>' +
    '</span>' +
    '<span class="li-trail ' + (isHijacked ? 't-label-medium bad' : 'li-value') + '">' + esc(trail) + '</span>' +
  '</div>';
}

function resetTestResults(){
  ['tr', 'test-tcp16-list', 'test-dns-list'].forEach(id => {
    const el = $(id);
    if(el){ el.innerHTML = ''; el._html = ''; }
  });
  webResults = {}; tcp16Results = {}; dnsResults = {}; lastRecommendation = null;
  const recEl = $('test-recommendation');
  if(recEl){ recEl.hidden = true; recEl.innerHTML = ''; }
}

async function stopTest(){
  if(!testRunning) return;
  testCancelled = true;
  if(webViewAbortCtrl){
    try { webViewAbortCtrl.abort(); } catch(_){}
  }
  const tb = $('tb');
  if(tb){
    tb.disabled = true;
    tb.innerHTML = '<span class="spinner"></span><span>' + esc(t('Остановка…')) + '</span>';
  }
  await ctlx(['probe-cancel']);
  toast(t('Проверка остановлена'));
}

async function runTest(){
  if(testRunning){
    await stopTest();
    return;
  }
  testRunning = true;
  testCancelled = false;
  webViewAbortCtrl = new AbortController();

  const tb = $('tb');
  if(tb){
    tb.disabled = false;
    tb.classList.add('danger');
    tb.innerHTML = icon('stop', 's18') + '<span>' + esc(t('Остановить')) + '</span>';
  }
  if($('test-empty')) $('test-empty').hidden = true;

  resetTestResults();

  await stat(true);
  renderTestWarn();
  await refreshNetInfo();

  const hosts = [];
  let tool = '';

  const onLine = l => {
    if(testCancelled) return;
    const p = l.split('\t');
    if(p[0] === 'tool') {
      tool = p[1];
    } else if(p[0] === 'H') {
      hosts[+p[1]] = p[2];
      webResults[p[1]] = {host: p[2], list: []};
      $('tr').insertAdjacentHTML('beforeend', testRow(p[1], p[2]));
    } else if(p[0] === 'R' && webResults[p[1]]) {
      const v = (p[3] || '').split(' ');
      const resItem = v[0] === 'ok' ? {ok: true, ms: +v[1] || 0} : {ok: false, reason: v[1] || 'other'};
      webResults[p[1]].list.push(resItem);
      const rowEl = $('tr' + p[1]);
      if(rowEl) rowEl.textContent = webResults[p[1]].list.filter(x => x.ok).length + '/' + webResults[p[1]].list.length;
      if(webResults[p[1]].list.length === 3) finishTestRow(p[1], webResults[p[1]].list);
    } else if(p[0] === 'T16') {
      const idx = p[1], provider = p[2], ip = p[3], port = p[4], st = p[5], detail = p[6];
      tcp16Results[idx] = {provider, ip, port, status: st, detail};
      const existing = $('tcprow' + idx);
      const rowHtml = renderTcp16Row(idx, provider, ip, port, st, detail);
      if(existing) existing.outerHTML = rowHtml;
      else if($('test-tcp16-list')) $('test-tcp16-list').insertAdjacentHTML('beforeend', rowHtml);
    } else if(p[0] === 'DNS') {
      const idx = p[1], name = p[2], ip = p[3], udp = p[4], doh = p[5], hijacked = p[6], detail = p[7];
      dnsResults[idx] = {name, ip, udp, doh, hijacked, detail};
      const existing = $('dnsrow' + idx);
      const rowHtml = renderDnsRow(idx, name, ip, udp, doh, hijacked, detail);
      if(existing) existing.outerHTML = rowHtml;
      else if($('test-dns-list')) $('test-dns-list').insertAdjacentHTML('beforeend', rowHtml);
    }
  };

  try {
    const r = await ctlx(['probe-dpi', currentTestTab], 180000, onLine);
    if(!testCancelled){
      // WebView проверяет только сайты — на вкладках TCP 16K и DNS ему нечего делать
      if((tool === 'none' && (currentTestTab === 'all' || currentTestTab === 'web')) || (r.code && !hosts.length && currentTestTab === 'web')) {
        await runTestWebView();
      } else {
        Object.keys(webResults).forEach(i => {
          if(webResults[i].list.length < 3) {
            finishTestRow(i, webResults[i].list.length ? webResults[i].list : [{ok: false, reason: 'timeout'}]);
          }
        });
      }
    }
  } finally {
    testRunning = false;
    if(tb){
      tb.classList.remove('danger');
      tb.disabled = false;
      tb.innerHTML = icon('play', 's18') + '<span>' + esc(t('Проверить снова')) + '</span>';
    }
    // остановленная проверка — не основание для рекомендации: недоделанные
    // адреса считались бы сбоями
    if(!testCancelled) renderRecommendation();
  }
}

/* Запасной путь: fetch из WebView */
async function probeFetch(u, signal){
  const t0 = performance.now();
  try {
    await fetch('https://' + u + (u.includes('?') ? '&' : '?') + '_=' + Date.now() + Math.random(),
      {mode: 'no-cors', cache: 'no-store', credentials: 'omit', signal});
    return {ok: true, ms: performance.now() - t0};
  } catch(e) {
    return {ok: false, reason: signal && signal.aborted ? 'timeout' : 'reset'};
  }
}

async function runTestWebView(){
  setHTML('test-warn', $('test-warn').innerHTML + banner('', 'warn',
    t('На устройстве нет curl или busybox wget с TLS — проверка идёт через WebView и показывает лишь приблизительную картину.')), false);
  const r = await ctlx(['get-list', 'probe_hosts']);
  const hosts = (r.code ? '' : r.out).split('\n').map(s => s.trim()).filter(s => s && s[0] !== '#');
  setHTML('tr', hosts.map((h, i) => testRow(i, h)).join(''), false);
  // результаты — туда же, где их ждут рекомендация и отчёт
  hosts.forEach((h, i) => { webResults[i] = {host: h, list: []}; });
  if(!hosts.length){
    if($('test-empty')) $('test-empty').hidden = false;
    if($('test-empty-title')) $('test-empty-title').textContent = t('probe_hosts.list пуст');
    return;
  }
  for(let i = 0; i < hosts.length; i++){
    if(testCancelled) break;
    const h = hosts[i];
    const out = webResults[i].list;
    for(let k = 0; k < 3; k++){
      if(testCancelled) break;
      const subCtrl = new AbortController();
      // «Стоп» прерывает и текущий запрос, а не ждёт его таймаута
      const onStop = () => subCtrl.abort();
      webViewAbortCtrl.signal.addEventListener('abort', onStop);
      const tm = setTimeout(() => subCtrl.abort(), 6000);
      try {
        out.push(await probeFetch(h, subCtrl.signal));
      } finally { clearTimeout(tm); webViewAbortCtrl.signal.removeEventListener('abort', onStop); }
    }
    finishTestRow(i, out);
  }
}

/* Анализ результатов и автоподбор стратегии */
function analyzeProbeResults(webRes, tcp16Res, dnsRes){
  const webKeys = Object.keys(webRes || {});
  const tcpKeys = Object.keys(tcp16Res || {});
  const dnsKeys = Object.keys(dnsRes || {});

  if(!webKeys.length && !tcpKeys.length && !dnsKeys.length) return null;

  let totalWeb = webKeys.length;
  let okWeb = 0;
  let rstCount = 0;
  let alertCount = 0;
  let dropCount = 0;
  let otherFailWeb = 0;

  webKeys.forEach(k => {
    const list = webRes[k].list || [];
    const oks = list.filter(x => x.ok);
    if(oks.length >= 2 || (list.length > 0 && oks.length === list.length)) {
      okWeb++;
    } else {
      const reasons = list.filter(x => !x.ok).map(x => x.reason);
      if(reasons.some(r => r === 'tls_alert')) alertCount++;
      else if(reasons.some(r => r === 'tls_rst' || r === 'reset')) rstCount++;
      else if(reasons.some(r => r === 'drop' || r === 'timeout')) dropCount++;
      else otherFailWeb++;
    }
  });

  let tcp16Detected = 0;
  tcpKeys.forEach(k => {
    const st = tcp16Res[k].status;
    if(st === 'detected') tcp16Detected++;
  });

  let dnsHijacked = 0;
  let dnsUdpBlocked = 0;
  dnsKeys.forEach(k => {
    if(dnsRes[k].hijacked === 'yes') dnsHijacked++;
    if(dnsRes[k].udp === 'fail') dnsUdpBlocked++;
  });

  const failWeb = totalWeb - okWeb;
  const isClean = (failWeb === 0 && tcp16Detected === 0);

  let strategy = 'fake_tls_auto';
  let altStrategies = ['alt4_mod', 'alt11'];
  let summaryTitle = '';
  let reason = '';

  if(isClean){
    const cur = currentStrategy || 'default';
    strategy = cur;
    altStrategies = cur === 'default' ? ['fake_tls_auto', 'alt4_mod'] : ['default', 'fake_tls_auto'];
    summaryTitle = t('Блокировок не обнаружено');
    reason = t('Все проверенные сайты и соединения к CDN работают стабильно без вмешательства DPI.');
  } else if(tcp16Detected > 0){
    if(alertCount > 0 || rstCount > 0){
      strategy = 'fake_tls_auto_alt2';
      altStrategies = ['fake_tls_auto_alt3', 'alt4_mod'];
      summaryTitle = t('Обнаружены TCP 16-20KB и фильтрация TLS');
      reason = t('DPI разрывает сессии после 16-20 КБ данных и блокирует ClientHello. Рекомендуется стратегия со сплитом пакетов и маскировкой перекрытиями (multisplit + seqovl).');
    } else {
      strategy = 'alt4_mod';
      altStrategies = ['alt4', 'fake_tls_auto_alt2'];
      summaryTitle = t('Обнаружен фильтр TCP 16-20KB');
      reason = t('Соединения к зарубежным CDN (Cloudflare/Hetzner) обрываются после 16-20 КБ данных. Рекомендуется сегментация TCP-пакетов.');
    }
  } else if(alertCount > 0){
    strategy = 'fake_tls_auto';
    altStrategies = ['fake_tls_auto_alt', 'simple_fake_alt2'];
    summaryTitle = t('Обнаружена блокировка по SNI (TLS Alert)');
    reason = t('DPI перехватывает имя хоста в ClientHello и посылает TLS Alert. Рекомендуется стратегия с поддельным SNI и рандомизацией.');
  } else if(rstCount > 0){
    strategy = 'fake_tls_auto';
    altStrategies = ['simple_fake_alt2', 'alt8'];
    summaryTitle = t('Обнаружен активный сброс (TLS RST)');
    reason = t('DPI инжектирует пакеты TCP RST при попытке установить защищённое соединение. Рекомендуется отправка фейкового ClientHello со сдвигом окна.');
  } else if(dropCount > 0){
    strategy = 'alt11';
    altStrategies = ['alt12', 'exp'];
    summaryTitle = t('Обнаружен тихий сброс (Drop / Timeout)');
    reason = t('DPI молча отбрасывает пакеты без ответа. Рекомендуется стратегия с повышенным числом повторов (repeats=8) и модификацией TCP Timestamps.');
  } else {
    strategy = 'eduncey';
    altStrategies = ['hardcorp74', 'fake_tls_auto'];
    summaryTitle = t('Смешанный профиль цензуры');
    reason = t('Обнаружен нестандартный профиль блокировок. Рекомендуется адаптивная стратегия с циклическим самоподбором методов (circular).');
  }

  let dnsWarning = '';
  if(dnsHijacked > 0 || dnsUdpBlocked > 0){
    dnsWarning = t('Внимание: обнаружен перехват или подмена DNS провайдером. Рекомендуется включить «Частный DNS» (DoH) в настройках системы.');
  }

  return {
    strategy,
    altStrategies,
    title: summaryTitle,
    reason,
    dnsWarning,
    isClean
  };
}

function renderRecommendation(){
  const el = $('test-recommendation');
  if(!el) return;
  const rec = analyzeProbeResults(webResults, tcp16Results, dnsResults);
  lastRecommendation = rec;
  if(!rec){
    el.hidden = true;
    el.innerHTML = '';
    return;
  }
  el.hidden = false;

  const cur = currentStrategy || 'default';
  const isCurrent = cur === rec.strategy;
  const stratTitle = strategyName(rec.strategy);

  let html = '<div class="subhead-row" style="margin-top:0;">' +
    '<span class="subhead plain">' + esc(t('Автоподбор стратегии')) + '</span>' +
    '<span class="badge ' + (rec.isClean ? 'ok' : 'primary') + '">' + esc(rec.title) + '</span>' +
  '</div>' +
  '<div class="t-body-medium">' + esc(rec.reason) + '</div>';

  if(rec.dnsWarning){
    html += '<div class="helper warn" style="margin-top:8px;">' + icon('warn', 's16') + ' ' + esc(rec.dnsWarning) + '</div>';
  }

  html += '<div class="row" style="margin-top:12px; flex-wrap:wrap; gap:8px;">' +
    '<button class="btn with-icon state ' + (isCurrent ? 'tonal' : '') + '" onclick="applyRecommendedStrategy(' + jsArg(rec.strategy) + ')"' + (isCurrent ? ' disabled' : '') + '>' +
      icon(isCurrent ? 'check' : 'tune', 's18') +
      '<span>' + (isCurrent ? esc(t('Стратегия «{0}» уже действует', stratTitle)) : esc(t('Применить «{0}»', stratTitle))) + '</span>' +
    '</button>';

  if(rec.altStrategies && rec.altStrategies.length > 0){
    rec.altStrategies.forEach(altName => {
      const isAltCur = cur === altName;
      const altTitle = strategyName(altName);
      html += '<button class="btn tonal sm state" onclick="applyRecommendedStrategy(' + jsArg(altName) + ')"' + (isAltCur ? ' disabled' : '') + '>' +
        '<span>' + esc(isAltCur ? altTitle + ' (' + t('действует') + ')' : altTitle) + '</span>' +
      '</button>';
    });
  }

  html += '</div>';

  el.innerHTML = html;
}

async function applyRecommendedStrategy(name){
  await applyStrategy(name);
  renderRecommendation();
}

function copyTestReport(){
  let rep = '### DPI Detector (nfqws2-android-ext)\n\n';
  if(netInfoData){
    rep += `**Сеть:** IP: ${netInfoData.ip || '—'} (${netInfoData.loc || '—'}), Провайдер: ${netInfoData.isp || '—'} (${netInfoData.asn || '—'})\n`;
    rep += `**Обход:** ${netInfoData.status === 'running' ? 'Активен' : 'Остановлен'}, Стратегия: ${netInfoData.strategy || '—'}, DNS: ${netInfoData.dns || '—'}\n\n`;
  }
  const rec = lastRecommendation || analyzeProbeResults(webResults, tcp16Results, dnsResults);
  if(rec){
    rep += `#### Анализ и автоподбор стратегии:\n`;
    rep += `- Вердикт: ${rec.title}\n`;
    rep += `- Рекомендованная стратегия: ${rec.strategy}\n`;
    rep += `- Обоснование: ${rec.reason}\n`;
    if(rec.dnsWarning) rep += `- DNS: ${rec.dnsWarning}\n`;
    rep += '\n';
  }
  if(Object.keys(webResults).length > 0){
    rep += '#### Сайты и сервисы:\n';
    for(const k of Object.keys(webResults)){
      const item = webResults[k];
      const ok = item.list.filter(x => x.ok);
      const fails = [...new Set(item.list.filter(x => !x.ok).map(x => PROBE_REASON[x.reason] || x.reason))];
      rep += `- ${item.host}: ${ok.length}/${item.list.length}` + (ok.length ? ` (${Math.round(ok.reduce((a,x)=>a+x.ms,0)/ok.length)} мс)` : '') + (fails.length ? ` [${fails.join(', ')}]` : '') + '\n';
    }
    rep += '\n';
  }
  if(Object.keys(tcp16Results).length > 0){
    rep += '#### TCP 16-20KB блокировка (CDN и хостинги):\n';
    for(const k of Object.keys(tcp16Results)){
      const it = tcp16Results[k];
      rep += `- ${it.provider} (${it.ip}): ${it.status === 'clean' ? 'CLEAN (' + it.detail + ')' : (it.status === 'detected' ? 'DETECTED @ ' + it.detail : 'UNREACHABLE')}\n`;
    }
    rep += '\n';
  }
  if(Object.keys(dnsResults).length > 0){
    rep += '#### DNS и перехват:\n';
    for(const k of Object.keys(dnsResults)){
      const it = dnsResults[k];
      rep += `- ${it.name} (${it.ip}): UDP=${it.udp}, DoH=${it.doh}, Перехват=${it.hijacked === 'yes' ? 'ДА (' + it.detail + ')' : 'НЕТ'}\n`;
    }
    rep += '\n';
  }

  if(navigator.clipboard && navigator.clipboard.writeText){
    navigator.clipboard.writeText(rep).then(() => toast(t('Отчёт скопирован в буфер обмена')));
  } else {
    const ta = document.createElement('textarea');
    ta.value = rep;
    document.body.appendChild(ta);
    ta.select();
    document.execCommand('copy');
    document.body.removeChild(ta);
    toast(t('Отчёт скопирован в буфер обмена'));
  }
}

/* ══ Проверка одного домена ══════════════════════════════════════════════
   domain-check отвечает строками MODE / LIST / IP / R (попытки) / done; итог
   складываем здесь: исключён ли домен, попадает ли под обход, открывается ли. */
const DC_ROLE = {
  host: 'список обхода', auto: 'автообучение', exclude: 'исключения',
  ipset: 'IP-список обхода', 'ipset-exclude': 'IP-исключения', idle: 'не подключён к текущей стратегии'
};
let dcRunning = false;
async function runDomainCheck(){
  const q = $('dc-q').value.trim();
  if(!q || dcRunning) return;
  dcRunning = true;
  $('dc-go').disabled = true;
  $('dc-q').blur();
  const st = {mode: '', lists: [], ip: '', tries: [], keep: ''};
  const paint = done => setHTML('dc-res', dcRender(q, st, done), false);
  paint(false);
  const r = await ctlx(['domain-check', q], 60000, line => {
    const p = line.split('\t');
    if(p[0] === 'MODE') st.mode = p[1];
    else if(p[0] === 'LIST') st.lists.push({file: p[1], role: p[2], entry: p[3]});
    else if(p[0] === 'IP') st.ip = p[1];
    else if(p[0] === 'R'){ const [ok, v] = (p[2] || '').split(' '); st.tries.push({ok: ok === 'ok', v}); }
    else if(p[0] === 'K') st.keep = p[1];
    else return;
    paint(false);
  });
  dcRunning = false;
  $('dc-go').disabled = false;
  if(r.code){ setHTML('dc-res', banner('danger', 'error', errText(r, 'Не удалось проверить домен')), false); return; }
  paint(true);
}
function dcVerdict(st){
  const has = role => st.lists.some(l => l.role === role);
  if(has('exclude') || has('ipset-exclude')) return ['warn', 'warn', t('В исключениях: обход к этому домену не применяется')];
  if(has('host') || has('auto') || has('ipset')) return ['ok', 'check', t('Под обходом')];
  if(st.mode === 'all') return ['ok', 'check', t('Под обходом: режим «все сайты, кроме исключений»')];
  return ['warn', 'info', t('Не под обходом: домена нет в списках, которые использует текущая стратегия')];
}
function dcRender(q, st, done){
  const out = [];
  if(st.mode){
    const [kind, ic, text] = dcVerdict(st);
    out.push(banner(kind === 'ok' ? '' : 'warn', ic, text));
    if(!S.running) out.push(banner('', 'info', t('Служба остановлена — сейчас обход не работает ни для каких доменов.')));
  }
  const rows = [];
  if(st.mode) rows.push(dcRow('list', t('Списки'), st.lists.length
    ? st.lists.map(l => l.file + ' — ' + l.entry + ' (' + t(DC_ROLE[l.role] || l.role) + ')').join('\n')
    : t('Ни в одном списке')));
  if(st.ip) rows.push(dcRow('globe', t('IP-адрес'), st.ip));
  const n = st.tries.length, ok = st.tries.filter(x => x.ok);
  if(n || !done){
    let sub;
    if(!n) sub = t('Проверяю…');
    else if(ok.length) sub = t('Открылся {0} из {1}, ~{2} мс', ok.length, n, Math.round(ok.reduce((a, x) => a + (+x.v || 0), 0) / ok.length));
    else sub = t('Не открылся: {0}', [...new Set(st.tries.map(x => t(PROBE_REASON[x.v] || PROBE_REASON.other)))].join(', '));
    rows.push(dcRow('test', t('Доступность через обход'), sub, n && !done ? '' : (n ? (ok.length === n ? 'ok' : ok.length ? 'warn' : 'bad') : '')));
  } else if(done) rows.push(dcRow('test', t('Доступность через обход'), t('Нет curl или wget — открыть сайт с устройства нечем')));
  // второй запрос по тому же соединению: так ходят приложения и браузер
  if(st.keep === 'ok') rows.push(dcRow('refresh', t('Повторный запрос'), t('Проходит по тому же соединению'), 'ok'));
  else if(st.keep === 'stall') rows.push(dcRow('refresh', t('Повторный запрос'),
    t('Зависает: первый запрос отвечает, следующий по тому же соединению — нет. Соединение замораживается после первого обмена — приложения покажут ошибку со второго запроса'), 'bad'));
  else if(n === 3 && ok.length && !done) rows.push(dcRow('refresh', t('Повторный запрос'), t('Проверяю…')));
  if(rows.length) out.push('<div class="list">' + rows.join('') + '</div>');
  if(done && st.mode){
    const acts = [];
    if(!st.lists.some(l => l.role === 'host'))
      acts.push('<button class="btn tonal with-icon state" onclick="dcAddUser(' + jsArg(q) + ')">' + icon('add', 's18') + '<span>' + esc(t('Добавить в user.list')) + '</span></button>');
    if(st.lists.length)
      acts.push('<button class="btn text state" aria-haspopup="menu" onclick="dcPickList(this)">' + esc(t('Открыть список')) + '</button>');
    dcLast = st;
    if(acts.length) out.push('<div class="row">' + acts.join('') + '</div>');
  }
  return out.join('');
}
function dcRow(ic, title, sub, status){
  const sic = {ok: 'check', warn: 'warn', bad: 'error'}[status];
  const st = sic ? '<span class="status ' + status + '">' + icon(sic, 's16') + '</span>' : '';
  return '<div class="list-item two-line">' +
    '<span class="li-icon plain">' + icon(ic, 's24') + '</span>' +
    '<span class="li-text"><span class="li-primary">' + esc(title) + '</span>' +
      '<span class="li-secondary selectable-pre">' + esc(sub) + '</span></span>' + st + '</div>';
}
async function dcAddUser(q){
  const r = await withBusy(['add-domain', q]);
  if(r.code){ toast(errText(r, 'Не удалось добавить')); return; }
  // ответ ctl — по-русски («Добавлено: x»); в интерфейсе — своя строка
  toast(t('Добавлено: {0}', (r.out || '').trim().split(': ').pop() || q));
  runDomainCheck();
}
/* Открыть список, где нашёлся домен, сразу с поиском этой записи. Списков
   несколько — выбор из меню. Ждём именно тот редактор, который открыли: если
   открыть не удалось и пользователь открыл другой список, поиск туда не лезет. */
let dcLast = null;
function dcPickList(anchor){
  const lists = dcLast ? dcLast.lists : [];
  if(lists.length === 1) return dcOpenList(lists[0].file, lists[0].entry);
  openMenu(anchor, lists.map(l => ({label: l.file, sub: l.entry, icon: 'list', onClick: () => dcOpenList(l.file, l.entry)})));
}
async function dcOpenList(file, entry){
  openSlideEditor('list', file.replace(/\.list$/, ''));
  const o = editorCtx;
  if(!o) return;
  for(let i = 0; i < 300 && editorCtx === o && o.original === undefined; i++) await new Promise(r => setTimeout(r, 100));
  if(editorCtx !== o || o.original === undefined) return;
  toggleFind(true, true);
  $('find-q').value = '"' + entry + '"';
  findRun();
}
