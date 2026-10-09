/* nfqws2 WebUI · core.js — ядро: утилиты, язык, мост к модулю, меню, диалоги, навигация, история «Назад»
   Скрипты подключаются из index.html обычными <script> по порядку и делят одну
   глобальную область: функции и let/const одного файла видны в остальных. */

/* ══════════════════════════════════════════════════════════════════════════
   nfqws2 WebUI · Material Design 3
   Данные берутся только из bin/nfqws2-ctl; UI деградирует мягко, если моста нет.
   ══════════════════════════════════════════════════════════════════════════ */
const MOD = '/data/adb/modules/nfqws2-android-ext', CTL = MOD + '/bin/nfqws2-ctl';
const $ = id => document.getElementById(id);
let S = {}, seq = 0, pkgs = [], currentEditorTarget = '';
const q = s => "'" + String(s).replace(/'/g, "'\\''") + "'";
const b64 = s => btoa(unescape(encodeURIComponent(s)));
const unb64 = s => { try { return decodeURIComponent(escape(atob(s))); } catch(e) { return atob(s); } };
function b64toBlob(b64Data, contentType){
  contentType = contentType || 'application/x-tar';
  const bin = atob(String(b64Data || '').replace(/\s+/g, ''));
  const len = bin.length;
  const bytes = new Uint8Array(len);
  for(let i = 0; i < len; i++) bytes[i] = bin.charCodeAt(i);
  return new Blob([bytes], { type: contentType });
}
function blobToB64(blob){
  return new Promise((resolve, reject) => {
    const r = new FileReader();
    r.onload = () => {
      const s = String(r.result || '');
      resolve(s.includes(',') ? s.split(',')[1] : s);
    };
    r.onerror = reject;
    r.readAsDataURL(blob);
  });
}
async function exportBlobFile(blob, filename, mimeType, localFilePath){
  mimeType = mimeType || 'application/x-tar';
  if(typeof navigator !== 'undefined' && navigator.canShare && typeof File !== 'undefined'){
    try {
      const file = new File([blob], filename, { type: mimeType });
      if(navigator.canShare({ files: [file] })){
        await navigator.share({ files: [file], title: filename });
        toast(t('Экспорт завершён: {0}', filename));
        return true;
      }
    } catch(e){
      if(e && e.name === 'AbortError') return false;
    }
  }
  if(typeof window !== 'undefined' && window.showSaveFilePicker){
    try {
      const handle = await window.showSaveFilePicker({
        suggestedName: filename,
        types: [{ description: filename, accept: { [mimeType]: ['.tar'] } }]
      });
      const writable = await handle.createWritable();
      await writable.write(blob);
      await writable.close();
      toast(t('Файл сохранён: {0}', filename));
      return true;
    } catch(e){
      if(e && e.name === 'AbortError') return false;
    }
  }
  try {
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = filename;
    document.body.appendChild(a);
    a.click();
    setTimeout(() => { a.remove(); URL.revokeObjectURL(url); }, 2000);
  } catch(e) {}
  if(localFilePath && typeof window !== 'undefined' && window.ksu){
    try {
      await sh('am start -a android.intent.action.SEND -t ' + q(mimeType) +
               ' --eu android.intent.extra.STREAM ' + q('file://' + localFilePath) +
               ' --es android.intent.extra.SUBJECT ' + q(filename) + ' >/dev/null 2>&1');
    } catch(e) {}
  }
  toast(t('Экспорт завершён: {0}', filename));
  return true;
}
const esc = s => String(s == null ? '' : s).replace(/[&<>"]/g, c => ({'&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;'}[c]));
/* Значение внутрь JS-строки в HTML-атрибуте, например onclick="f('ИМЯ')".
   Одного esc() здесь мало: HTML-декодер вернёт &#39; обратно в кавычку ДО того,
   как строку увидит JS-парсер, и она вырвется из литерала. Поэтому сначала
   кавычим для JS (JSON.stringify экранирует кавычки, слэши и переводы строк),
   а потом получившуюся двойную кавычку прячем от HTML через esc(). */
const jsArg = v => esc(JSON.stringify(String(v == null ? '' : v)));
const icon = (name, cls) => '<svg aria-hidden="true" class="icon ' + (cls || 's20') + '"><use href="#i-' + name + '"/></svg>';

/* localStorage бывает недоступен (приватный режим, запрет сайта) — интерфейс от этого не ломается */
const store = {
  get(k){ try { return localStorage.getItem(k); } catch(e) { return null; } },
  set(k, v){ try { localStorage.setItem(k, v); } catch(e) {} },
  del(k){ try { localStorage.removeItem(k); } catch(e) {} }
};

/* ── Язык интерфейса ──────────────────────────────────────────────────────
   Ключ перевода — сама русская строка: разметка и код остаются читаемыми,
   а словарь EN (в конце скрипта) отображает её на английскую. Русский —
   язык по умолчанию независимо от языка системы. Статические узлы помечены
   data-t (текст) и data-ta (список атрибутов): исходник запоминается при
   первом проходе, поэтому язык переключается без перезагрузки. */
let LANG = store.get('nfq_lang') === 'en' ? 'en' : 'ru';
let EN = {};
function t(s){
  let r = (LANG === 'en' && EN[s] != null) ? EN[s] : s;
  for(let i = 1; i < arguments.length; i++) r = r.split('{' + (i - 1) + '}').join(arguments[i]);
  return r;
}
function translateStatic(){
  document.documentElement.lang = LANG;
  document.querySelectorAll('[data-t]').forEach(el => {
    if(el.dataset.ru == null) el.dataset.ru = el.textContent.trim();
    const key = el.getAttribute('data-t') || el.dataset.ru;
    el.textContent = (LANG === 'en' && EN[key] != null) ? EN[key] : el.dataset.ru;
  });
  document.querySelectorAll('[data-ta]').forEach(el => el.dataset.ta.split(',').forEach(a => {
    const k = 'ru_' + a.replace(/-/g, '_');
    if(el.dataset[k] == null) el.dataset[k] = el.getAttribute(a) || '';
    el.setAttribute(a, t(el.dataset[k]));
  }));
}
const fmtCount = n => Number(n).toLocaleString(LANG === 'en' ? 'en-US' : 'ru-RU');

/* ── Ripple: pointerdown на любой .state, делегирование переживает innerHTML ── */
document.addEventListener('pointerdown', e => {
  let el = e.target.closest && e.target.closest('.state, .nav-dest');
  if(el && el.classList.contains('nav-dest')) el = el.querySelector('.nav-ind');
  if(!el || el.classList.contains('is-disabled') || el.disabled) return;
  const r = el.getBoundingClientRect();
  const size = Math.max(r.width, r.height) * 2.2;
  const s = document.createElement('span');
  s.className = 'ripple';
  const L = (e.clientX || r.left + r.width / 2) - r.left - size / 2, T = (e.clientY || r.top + r.height / 2) - r.top - size / 2;
  s.style.cssText = 'width:' + size + 'px;height:' + size + 'px;left:' + L + 'px;top:' + T + 'px';
  // Волна не выходит за форму элемента, даже если у него overflow: visible
  // (у чипов — ради зоны касания 48dp): иначе круг расползался далеко за чип
  if(getComputedStyle(el).overflow === 'visible')
    s.style.clipPath = 'inset(' + Math.max(0, -T) + 'px ' + Math.max(0, size + L - r.width) + 'px ' +
      Math.max(0, size + T - r.height) + 'px ' + Math.max(0, -L) + 'px round ' + (getComputedStyle(el).borderRadius || '0') + ')';
  el.append(s);
  setTimeout(() => s.remove(), 520);
}, {passive: true});

/* div-строки с role="button" обязаны активироваться клавиатурой, как настоящие кнопки */
document.addEventListener('keydown', e => {
  if(e.key !== 'Enter' && e.key !== ' ') return;
  const el = e.target && e.target.closest && e.target.closest('[role="button"]:not(button)');
  if(el && !el.classList.contains('is-disabled')){ e.preventDefault(); el.click(); }
});

/* ── Menu: открывается под якорем, переворачивается вверх без места ───────
   Повторное нажатие на якорь закрывает меню (как anchor.onclick → menu.open =
   !menu.open в Material Web). Касание вне меню только закрывает его: слой
   menu-back ловит click целиком, и элемент под пальцем не срабатывает. */
let openMenuEntry = null;
function closeMenu(){ if(openMenuEntry) openMenuEntry.close(); }
function openMenu(anchor, items){
  if(openMenuEntry && openMenuEntry.anchor === anchor){ closeMenu(); return null; }
  closeMenu();
  const viaKeyboard = anchor.matches(':focus-visible');
  const menu = document.createElement('div');
  menu.className = 'menu';
  menu.setAttribute('role', 'menu');
  for(const it of items){
    if(it === '-'){ const sep = document.createElement('div'); sep.className = 'sep'; sep.setAttribute('role', 'separator'); menu.append(sep); continue; }
    const mi = document.createElement('button');
    mi.className = 'mi state';
    mi.type = 'button';
    mi.setAttribute('role', 'menuitem');
    mi.innerHTML = ('icon' in it ? '<span class="mi-icon">' + (it.icon ? icon(it.icon, 's24') :
        '<span style="display:block;width:24px;height:24px"></span>') + '</span>' : '') +
      '<span class="mi-text">' + esc(it.label) + (it.sub ? '<span class="mi-sub">' + esc(it.sub) + '</span>' : '') + '</span>';
    mi.onclick = () => { close(); if(it.onClick) it.onClick(); };
    menu.append(mi);
  }
  const back = document.createElement('div');
  back.className = 'menu-back';
  back.addEventListener('click', e => { e.preventDefault(); close(); });
  $('layer').append(back, menu);
  const r = anchor.getBoundingClientRect(), mw = menu.offsetWidth, mh = menu.offsetHeight;
  let top = r.bottom + 4;
  if(top + mh > innerHeight - 8){ top = Math.max(8, r.top - mh - 4); menu.classList.add('up'); }
  const end = r.left + r.width / 2 > innerWidth / 2;
  if(end) menu.classList.add('end');
  menu.style.left = Math.max(8, Math.min(end ? r.right - mw : r.left, innerWidth - mw - 8)) + 'px';
  menu.style.top = top + 'px';
  anchor.setAttribute('aria-expanded', 'true');
  const itemsEls = () => [...menu.querySelectorAll('.mi')];
  const onKey = e => {
    if(e.key === 'Escape'){ e.stopPropagation(); e.preventDefault(); close(); anchor.focus(); return; }
    if(e.key === 'ArrowDown' || e.key === 'ArrowUp'){
      e.preventDefault();
      const els = itemsEls(), i = els.indexOf(document.activeElement);
      const n = e.key === 'ArrowDown' ? (i + 1) % els.length : (i - 1 + els.length) % els.length;
      els[i < 0 ? 0 : n].focus();
    }
    if(e.key === 'Tab') close();
  };
  addEventListener('keydown', onKey, true);
  if(viaKeyboard){ const f = itemsEls()[0]; if(f) f.focus(); }
  let closed = false;
  const entry = { close, anchor };
  openMenuEntry = entry;
  scheduleSync();
  function close(){
    if(closed) return; closed = true;
    removeEventListener('keydown', onKey, true);
    back.remove();
    menu.classList.add('closing');
    setTimeout(() => menu.remove(), 110);
    anchor.setAttribute('aria-expanded', 'false');
    if(openMenuEntry === entry) openMenuEntry = null;
    scheduleSync();
  }
  return entry;
}


/* ── Мост к модулю ─────────────────────────────────────────────────────────
   ksu.exec(cmd, opts, cb) в KernelSU выполняет команду СИНХРОННО внутри вызова
   из JS: пока шелл работает, главный поток страницы стоит. Отсюда рывки
   анимаций при переходе на «Состояние» и «Списки»: json-status успевал
   заблокировать поток раньше, чем стартовала анимация экрана. ksu.spawn
   запускает процесс в фоне и присылает вывод построчно, поэтому, если он
   есть и отвечает, все команды идут через него; exec — запасной путь для
   менеджеров без spawn. */
let spawnOK = false;
function makeEmitter(){
  const h = {};
  return {
    on(ev, fn){ (h[ev] = h[ev] || []).push(fn); return this; },
    emit(ev){ const a = [].slice.call(arguments, 1); (h[ev] || []).forEach(f => { try { f.apply(null, a); } catch(e) {} }); }
  };
}
/* Менеджеры по-разному отдают stdout из spawn: построчно, кусками или
   строками без переводов строк. Последний вариант склеивал многострочный
   вывод в одну строку — список стратегий превращался в один «MartinBacker…»,
   а приложения и импорты — в один элемент. Поэтому вывод обрамляется сам:
   каждая строка заканчивается разделителем \x1e, код выхода команды идёт
   последней записью. Переводы строк от менеджера просто выбрасываются. */
const REC = '\x1e', RC_TAG = '__nfq_rc=';
const frameCmd = cmd => '{ ' + cmd + '\nprintf \'\\n' + RC_TAG + '%s\\n\' "$?"; } | awk \'{ printf "%s\\036\\n", $0; fflush() }\'';
function spawnRun(cmd, ms, onLine){
  return new Promise(res => {
    const id = '__sp' + (++seq), out = [], err = [];
    let done = 0, tm = 0, buf = '', rc = null;
    const child = makeEmitter();
    child.stdout = makeEmitter();
    child.stderr = makeEmitter();
    const fin = (c, extraErr) => {
      if(done) return; done = 1; clearTimeout(tm);
      setTimeout(() => { delete window[id]; }, 1000);
      if(buf.replace(/[\r\n]/g, '')) take(buf.replace(/[\r\n]/g, ''));
      if(extraErr) err.push(extraErr);
      while(out.length && out[out.length - 1] === '') out.pop();   // пустая строка перед кодом выхода
      res({code: rc != null ? rc : (+c || 0), out: out.join('\n'), err: err.join('\n')});
    };
    const take = rec => {
      if(rec.indexOf(RC_TAG) === 0){ rc = parseInt(rec.slice(RC_TAG.length), 10) || 0; return; }
      out.push(rec);
      if(onLine) try { onLine(rec); } catch(e) {}
    };
    child.stdout.on('data', d => {
      buf += String(d).replace(/[\r\n]/g, '');
      let i;
      while((i = buf.indexOf(REC)) >= 0){ take(buf.slice(0, i)); buf = buf.slice(i + 1); }
    });
    child.stderr.on('data', d => err.push(String(d)));
    child.on('exit', c => fin(rc == null && c != null ? c : rc));
    child.on('error', e => fin(1, String(e)));
    window[id] = child;
    tm = setTimeout(() => fin(-1, t('Таймаут')), ms);
    // Аргументы KernelSU склеивает пробелами без кавычек, поэтому вся команда
    // уходит одной строкой, а список аргументов пуст.
    try { window.ksu.spawn(frameCmd(cmd), '[]', '{}', id); } catch(e) { fin(1, String(e)); }
  });
}
function execRun(cmd, ms){
  return new Promise(res => {
    const k = window.ksu;
    if(!k || !k.exec){ res({code: 1, out: '', err: t('Нет моста ksu.exec')}); return; }
    const id = '__cb' + (++seq); let done = 0;
    const fin = (c, o, e) => { if(done) return; done = 1; clearTimeout(tm); delete window[id]; res({code: +c || 0, out: String(o || ''), err: String(e || '')}); };
    const tm = setTimeout(() => fin(-1, '', t('Таймаут')), ms);
    window[id] = fin;
    try { k.exec(cmd, '{}', id); } catch(e) { try { k.exec(cmd, id); } catch(e2) { fin(1, '', String(e2)); } }
  });
}
async function sh(cmd, ms, onLine){
  ms = ms || 15000;
  if(spawnOK) return spawnRun(cmd, ms, onLine);
  const r = await execRun(cmd, ms);
  if(onLine) r.out.split('\n').forEach(l => { try { onLine(l); } catch(e) {} });
  return r;
}
async function detectSpawn(){
  if(!window.ksu || typeof window.ksu.spawn !== 'function') return;
  // Проверяем не только что spawn отвечает, но и что строки и код выхода
  // доходят без искажений; иначе остаёмся на exec.
  const r = await spawnRun("printf 'nfq_a\\n\\nnfq_b\\n'; (exit 3)", 3000);
  spawnOK = r.code === 3 && r.out === 'nfq_a\n\nnfq_b';
}
const ctlCmd = a => (LANG === 'en' ? 'NFQWS_LANG=en ' : '') + 'sh ' + q(CTL) + ' ' + a.map(q).join(' ');
/* Длинный аргумент (base64 архива или большого списка) одной командой не
   пройдёт: предел ядра на длину аргумента ~128 КБ. Такой уходит частями
   командой upload, а в саму команду идёт ссылка @up:<метка>. */
const UPLOAD_CHUNK = 48000;
async function uploadArgs(a){
  const out = [];
  for(const v of a){
    if(typeof v !== 'string' || v.length <= UPLOAD_CHUNK){ out.push(v); continue; }
    const tk = 'u' + Date.now().toString(36) + Math.random().toString(36).slice(2, 8);
    for(let i = 0; i < v.length; i += UPLOAD_CHUNK){
      const r = await sh(ctlCmd(['upload', tk, v.slice(i, i + UPLOAD_CHUNK)]), 20000);
      if(r.code) throw new Error((r.err || r.out || 'upload').trim());
    }
    out.push('@up:' + tk);
  }
  return out;
}
async function ctl(a, ms){
  try { a = await uploadArgs(a); } catch(e){ toast(String(e.message || e).slice(0, 160)); return ''; }
  const r = await sh(ctlCmd(a), ms);
  if(r.code && r.err && !r.out) toast(r.err.slice(0, 160));
  return r.out + (r.code && r.err ? '\n' + r.err : '');
}
async function ctlx(a, ms, onLine){
  try { a = await uploadArgs(a); } catch(e){ return {code: 1, out: '', err: String(e.message || e)}; }
  return await sh(ctlCmd(a), ms, onLine);
}
const errText = (r, fallback) => ((r.err || '').trim() || (r.out || '').trim().split('\n').pop() || t(fallback));

/* Буфер обмена: Clipboard API, а где WebView его не даёт — старый execCommand */
async function copyText(text){
  try { await navigator.clipboard.writeText(text); return true; }
  catch(e){
    const ta = document.createElement('textarea');
    ta.value = text;
    ta.style.cssText = 'position:fixed;opacity:0;pointer-events:none';
    document.body.append(ta);
    ta.select();
    let ok = false;
    try { ok = document.execCommand('copy'); } catch(e2) {}
    ta.remove();
    return ok;
  }
}

/* ── Snackbar: M3 (label + optional text action, 4s / 8s с действием) ──── */
let snackAction = null;
function toast(m, action){
  $('prompt-msg').textContent = m;
  const b = $('prompt-action');
  snackAction = action || null;
  b.hidden = !action;
  if(action) b.textContent = action.label || t('Повторить');
  const pc = $('prompt-container');
  pc.classList.add('show');
  clearTimeout(pc._t);
  pc._t = setTimeout(() => pc.classList.remove('show'), action ? 8000 : 4000);
}
$('prompt-action').onclick = () => {
  $('prompt-container').classList.remove('show');
  const a = snackAction; snackAction = null;
  if(a && a.fn) a.fn();
};

/* ── Индикатор занятости (linear progress под app bar) ─────────────────── */
let busyCount = 0;
function busy(on){
  busyCount = Math.max(0, busyCount + (on ? 1 : -1));
  const idle = busyCount === 0;
  $('progress-top').hidden = idle;
  $('content').setAttribute('aria-busy', idle ? 'false' : 'true');
}
async function withBusy(a, ms){
  busy(true);
  try { return await ctlx(a, ms); } finally { busy(false); }
}

/* Перерисовка без лишнего мигания: содержимое меняется только если оно
   действительно другое, а новые строки проявляются, а не возникают. */
function setHTML(el, html, animate){
  if(typeof el === 'string') el = $(el);
  if(!el || el._html === html) return false;
  el._html = html;
  el.innerHTML = html;
  if(animate !== false){ el.classList.remove('appear'); void el.offsetWidth; el.classList.add('appear'); }
  return true;
}

/* ── Basic dialog (M3) вместо native confirm/prompt ──────────────────────
   Как md-dialog: фокус удерживается внутри (Tab не уходит под scrim), после
   закрытия возвращается туда, откуда диалог открыли. Иконка — 24dp цвета
   secondary над заголовком, заголовок тогда по центру. */
let dialogCb = null, dialogReturnFocus = null;
function dialogResolve(val){
  if(!$('dialog-wrap').classList.contains('open')) return;
  const cb = dialogCb; dialogCb = null;
  $('dialog-wrap').classList.remove('open');
  const back = dialogReturnFocus; dialogReturnFocus = null;
  if(back && document.contains(back)) try { back.focus({preventScroll: true}); } catch(e) {}
  scheduleSync();
  if(cb) cb(val);
}
function mdDialog(opts){
  if(dialogCb) dialogResolve(false);
  return new Promise(res => {
    dialogCb = res;
    dialogReturnFocus = document.activeElement;
    const dlg = $('dialog');
    $('d-title').textContent = opts.title || '';
    $('d-body').textContent = opts.text || '';
    $('d-body').hidden = !opts.text;
    const showIcon = opts.icon !== false;
    const ic = $('d-icon');
    ic.hidden = !showIcon;
    ic.className = 'd-icon' + (opts.danger ? ' danger' : '');
    ic.innerHTML = icon(opts.iconName || (opts.danger ? 'error' : 'warn'), 's24');
    dlg.classList.toggle('has-icon', showIcon);
    const ok = $('d-ok');
    ok.className = 'btn text state' + (opts.danger ? ' danger' : '');
    ok.textContent = opts.ok || t('ОК');
    const cancel = $('d-cancel');
    cancel.hidden = opts.cancel === false;
    cancel.textContent = typeof opts.cancel === 'string' ? opts.cancel : t('Отмена');
    const f = $('d-field');
    f.hidden = !opts.input;
    if(opts.input){
      const di = $('d-input');
      di.type = opts.input.type || 'text';
      di.inputMode = opts.input.inputmode || '';
      di.value = opts.input.value || '';
      $('d-label').textContent = opts.input.label || t('Значение');
    }
    /* alertdialog — только для прерывающих подтверждений; ввод значения это обычный dialog */
    dlg.setAttribute('role', opts.input ? 'dialog' : 'alertdialog');
    $('dialog-wrap').classList.add('open');
    scheduleSync();
    setTimeout(() => { (opts.input ? $('d-input') : dlg).focus(); }, 80);
  });
}
const mdConfirm = (title, text, o) => mdDialog(Object.assign({title, text}, o || {})).then(v => !!v);
async function mdPrompt(title, text, value, label, extra){
  extra = extra || {};
  return mdDialog({title, text, ok: extra.ok || t('Сохранить'), icon: false,
    input: {value, label, type: extra.type, inputmode: extra.inputmode}})
    .then(v => (v === false ? null : v));
}
$('d-ok').onclick = () => dialogResolve($('d-field').hidden ? true : $('d-input').value.trim());
$('d-input').onkeydown = e => { if(e.key === 'Enter') dialogResolve($('d-input').value.trim()); };
$('dialog-wrap').addEventListener('keydown', e => {
  if(e.key !== 'Tab') return;
  const els = [...$('dialog').querySelectorAll('button, input')].filter(el => el.offsetParent !== null && !el.disabled);
  if(!els.length) return;
  const first = els[0], last = els[els.length - 1], a = document.activeElement;
  if(e.shiftKey && (a === first || a === $('dialog'))){ e.preventDefault(); last.focus(); }
  else if(!e.shiftKey && a === last){ e.preventDefault(); first.focus(); }
});

/* ══ Навигация: Navigation bar + дочерние экраны ═════════════════════════
   Разделы верхнего уровня — в Navigation bar, переход между ними fade through.
   Настройки — дочерний экран за кнопкой-шестерёнкой; из них открываются
   следующие уровни (приложения, проверка, диагностика, домашняя Wi‑Fi):
   shared axis X вперёд/назад, стрелка «Назад», панель навигации скрыта. */
const PAGE_META = {
  control:  {title: 'Состояние', init: () => { renderStatus(); stat(); initStrategySelector(); }},
  lists:    {title: 'Списки', init: () => { renderMode(); renderListFiles(); stat(); }},
  logs:     {title: 'Журналы', init: () => loadLog(),
             actions: [{icon: 'refresh', label: 'Обновить журнал', fn: () => loadLog()}]},
  config:   {title: 'Конфиг', init: () => confInit()},
  settings: {title: 'Настройки', child: true, init: () => renderSettings()},
  wifi:     {title: 'Домашняя Wi‑Fi', child: true, parent: 'settings', init: () => wifiInit()},
  apps:     {title: 'Фильтр приложений', child: true, parent: 'settings', init: () => appsInit(),
             actions: [{icon: 'refresh', label: 'Обновить список приложений', fn: () => loadPk()}]},
  test:     {title: 'Проверка доступности', child: true, parent: 'settings', init: () => testInit()},
  diag:     {title: 'Диагностика', child: true, parent: 'settings', init: () => diagInit(),
             actions: [{icon: 'refresh', label: 'Проверить снова', fn: () => diagInit()}]},
  dns:      {title: 'DNS по профилям', child: true, parent: 'settings', init: () => dnsInit(),
             actions: [{icon: 'refresh', label: 'Обновить состояние', fn: () => dnsInit()}]},
  dnsprof:  {title: 'Профиль DNS', child: true, parent: 'dns', init: () => dnsProfInit()},
  hosts:    {title: 'Редактор hosts', child: true, parent: 'settings', init: () => hostsInit(),
             actions: [{icon: 'refresh', label: 'Обновить состояние', fn: () => hostsInit()}]}
};
let currentPage = 'control', lastTop = 'control', transitionCleanup = null;
const pageDepth = p => { const m = PAGE_META[p]; return !m.child ? 0 : (m.parent ? pageDepth(m.parent) + 1 : 1); };

function renderAppBar(page, animate){
  const m = PAGE_META[page];
  $('back-btn').hidden = !m.child;
  $('settings-btn').hidden = !!m.child;
  const tEl = $('app-title');
  tEl.textContent = t(m.title);
  if(animate !== false && !isAnimationsDisabled()){ tEl.classList.remove('swap'); void tEl.offsetWidth; tEl.classList.add('swap'); }
  fillBarActions(m.actions);
}
/* Кнопки справа в верхней панели; экран может подменить их на время (выбор профилей DNS) */
function fillBarActions(actions){
  const box = $('bar-actions');
  box.innerHTML = '';
  (actions || []).forEach(a => {
    const b = document.createElement('button');
    b.type = 'button';
    b.className = 'icon-btn state';
    b.title = t(a.label);
    b.setAttribute('aria-label', t(a.label));
    b.innerHTML = icon(a.icon, 's24');
    b.onclick = a.fn;
    if(a.disabled) b.disabled = true;
    box.append(b);
  });
}
function renderNavBar(page){
  document.querySelectorAll('.nav-dest').forEach(b => {
    if(b.dataset.page === page) b.setAttribute('aria-current', 'page');
    else b.removeAttribute('aria-current');
  });
  document.body.classList.toggle('nav-hidden', !!PAGE_META[page].child);
}
/* Анимация экрана снимается по animationend, а не по таймеру: если главный
   поток занят (exec-фолбэк), таймер успевал сработать раньше первого кадра
   и срезал анимацию — экран появлялся рывком. Запасной таймер остаётся на
   случай, когда событие не придёт (reduced motion, скрытая вкладка). */
/* Прокрутка экранов: уходя, экран запоминает её; вперёд (в дочерний экран)
   открываем с начала, а назад и по вкладкам — там, где пользователь был. */
const pageScroll = {};
function showPage(page, mode){
  if(transitionCleanup) transitionCleanup();
  const from = document.querySelector('.page.active');
  const to = document.querySelector('.page[data-page="' + page + '"]');
  if(!to || from === to) return;
  const animate = !matchMedia('(prefers-reduced-motion: reduce)').matches && !isAnimationsDisabled();
  if(from){
    if(animate){
      const r = from.getBoundingClientRect();
      from.style.cssText = 'position:fixed;top:' + r.top + 'px;left:' + r.left + 'px;width:' + r.width + 'px';
      from.classList.add('leaving', 'leave-' + mode);
    }
    from.classList.remove('active');
  }
  to.classList.add('active');
  if(animate) to.classList.add('enter-' + mode);
  const y = mode === 'forward' ? 0 : (pageScroll[page] || 0);
  scrollTo(0, y);
  $('app-bar').classList.toggle('scrolled', scrollY > 8);
  let timer = 0;
  const onEnd = e => { if(e.target === to && e.animationName === 'fade-in') cleanup(); };
  const cleanup = () => {
    clearTimeout(timer);
    to.removeEventListener('animationend', onEnd);
    if(from){ from.classList.remove('leaving', 'leave-' + mode); from.style.cssText = ''; }
    to.classList.remove('enter-' + mode);
    if(transitionCleanup === cleanup) transitionCleanup = null;
  };
  transitionCleanup = cleanup;
  if(animate){ to.addEventListener('animationend', onEnd); timer = setTimeout(cleanup, 1200); }
  else cleanup();
}
/* Данные экрана грузятся после того, как анимация пошла: два кадра, чтобы
   стиль нового экрана точно ушёл в композитор. Без spawn первый вызов ещё и
   ждёт конца анимации — синхронный exec иначе заморозил бы её первый кадр. */
function afterTransition(fn){
  requestAnimationFrame(() => requestAnimationFrame(() => setTimeout(fn, spawnOK ? 0 : 320)));
}
function navigate(page){
  if(page === currentPage){
    if(!PAGE_META[page].child) scrollTo({top: 0, behavior: 'smooth'});
    return;
  }
  closeMenu();
  const d0 = pageDepth(currentPage), d1 = pageDepth(page);
  const mode = d1 > d0 ? 'forward' : (d1 < d0 ? 'back' : 'fade');
  pageScroll[currentPage] = scrollY;
  // Выбор профилей DNS живёт только на своём экране
  dnsLongCancel();
  if(dnsSel){ dnsSel = null; if(currentPage === 'dns') renderDns(); }
  if(mode === 'forward') delete pageScroll[page];
  currentPage = page;
  if(!PAGE_META[page].child) lastTop = page;
  renderNavBar(page);
  renderAppBar(page);
  showPage(page, mode);
  const target = page;
  afterTransition(() => {
    if(currentPage !== target) return;
    // Экран мог быть короче до загрузки данных — тогда прокрутка упёрлась
    // в его конец; дотягиваем, если пользователь за это время не листал.
    const want = pageScroll[target] || 0, had = scrollY;
    Promise.resolve(PAGE_META[target].init()).then(() => {
      if(currentPage === target && want > had && scrollY === had) scrollTo(0, want);
    }).catch(() => {});
  });
  scheduleSync();
}
function goBack(){
  if(dnsSel && currentPage === 'dns') return dnsSelExit();
  navigate(PAGE_META[currentPage].parent || lastTop);
}
document.querySelectorAll('.nav-dest').forEach(b => { b.onclick = () => navigate(b.dataset.page); });

/* ── Режим разработчика: долгое нажатие на кнопку настроек ───────────────
   Показывает на главном экране служебные переключатели, которые обычному
   пользователю не нужны (контроль работы, лимиты пакетов).
   Обычное нажатие по-прежнему открывает настройки; после долгого нажатия
   следующий click гасится, чтобы настройки не открылись вдобавок. */
let devMode = store.get('nfq_dev') === '1';
(function bindSettingsPress(){
  const b = $('settings-btn');
  let tm = 0, fired = false;
  const cancel = () => { clearTimeout(tm); tm = 0; };
  b.addEventListener('pointerdown', () => {
    cancel(); fired = false;
    tm = setTimeout(() => {
      tm = 0; fired = true;
      devMode = !devMode;
      store.set('nfq_dev', devMode ? '1' : '0');
      renderParams(S);
      if(currentPage === 'settings') renderSettings();
      toast(devMode ? t('Режим разработчика включён') : t('Режим разработчика выключен'));
    }, 650);
  });
  ['pointerup', 'pointerleave', 'pointercancel'].forEach(ev => b.addEventListener(ev, cancel));
  b.addEventListener('contextmenu', e => e.preventDefault());
  b.addEventListener('click', () => { if(fired){ fired = false; return; } navigate('settings'); });
})();

/* Зоны системных жестов Android: полоска внизу (домой, недавние) и края
   слева/справа («назад»). Касание оттуда — жест системы, а не нажатие на
   то, что под пальцем. Нижняя зона — не меньше системного отступа снизу. */
let insetProbe = null;
function inGestureZone(x, y){
  // var(--bottom-inset) — цепочка var()/env(): значение даёт только вычисленный размер
  if(!insetProbe){
    insetProbe = document.createElement('div');
    insetProbe.style.cssText = 'position:fixed;left:0;bottom:0;width:0;visibility:hidden;pointer-events:none;height:var(--bottom-inset)';
    document.body.append(insetProbe);
  }
  const inset = insetProbe.offsetHeight || 0;
  return y > innerHeight - Math.max(32, inset + 8) || x < 24 || x > innerWidth - 24;
}

/* elevation on scroll: surface → surface-container */
addEventListener('scroll', () => $('app-bar').classList.toggle('scrolled', scrollY > 8), {passive: true});

/* ── Modal bottom sheets: один scrim на все листы ──────────────────────── */
let openSheetId = null, sheetReturnFocus = null;
/* Фон за модальным листом должен выходить из порядка обхода и из AT.
   inert появился в Chromium 102; старше — остаётся только scrim без ловушки. */
function setBackgroundInert(on){
  if(!('inert' in HTMLElement.prototype)) return;
  ['#content', '.app-bar', '.nav-bar'].forEach(sel => {
    const el = document.querySelector(sel);
    if(el) el.inert = on;
  });
}
function openSheet(id){
  if(openSheetId && openSheetId !== id) closeSheet();
  openSheetId = id;
  const el = $(id);
  sheetReturnFocus = document.activeElement;
  el.tabIndex = -1;
  el.classList.add('open');
  $('sheet-scrim').classList.add('show');
  setBackgroundInert(true);
  setTimeout(() => el.focus({ preventScroll: true }), 60);
  scheduleSync();
}
function closeSheet(){
  if(!openSheetId) return;
  const el = $(openSheetId);
  el.classList.remove('open');
  el.style.transform = '';
  sheetScrimRelease();
  $('sheet-scrim').classList.remove('show');
  setBackgroundInert(false);
  if(sheetReturnFocus && sheetReturnFocus.focus) sheetReturnFocus.focus({ preventScroll: true });
  sheetReturnFocus = null;
  openSheetId = null;
  scheduleSync();
}
function openMonetModal(){ drawThemeUI(); openSheet('monet-modal'); }

/* ── «Назад»: сначала оверлеи, потом дочерний экран, потом домой, потом выход ── */
function handleBack(allowExit){
  if(openMenuEntry){ closeMenu(); return true; }
  if($('dialog-wrap').classList.contains('open')){ dialogResolve(false); return true; }
  if($('editor-panel').classList.contains('open')){
    if(!$('find-bar').hidden){ toggleFind(false); return true; }
    closeSlideEditor(); return true;
  }
  if(openSheetId){ closeSheet(); return true; }
  if(dnsSel && currentPage === 'dns'){ dnsSelExit(); return true; }
  if(PAGE_META[currentPage].child){ goBack(); return true; }
  if(allowExit && currentPage !== 'control'){ navigate('control'); return true; }
  return false;
}
/* config.json: backInterceptor = javascript — менеджер сам зовёт этот обработчик */
window.onBackKeyPressed = function(){
  if(handleBack(true)) return;
  try { window.ksu && window.ksu.exit && window.ksu.exit(); } catch(e) {}
};
document.addEventListener('keydown', e => { if(e.key === 'Escape') handleBack(false); });

/* ── Жест «Назад» через историю WebView ──────────────────────────────────
   KernelSU и KsuWebUI на жест «Назад» делают webView.goBack(), если в
   истории есть куда идти, иначе закрывают WebUI. Раньше держалась одна
   «сторожевая» запись, и после каждого жеста она добавлялась заново. Но
   Chromium помечает пропускаемыми записи, добавленные без действия
   пользователя (history manipulation intervention): жест «Назад» — не
   действие, поэтому заново добавленная запись через раз пропускалась, и
   WebUI закрывался целиком.
   Теперь в истории по записи на каждый открытый слой (вкладка не
   «Состояние», дочерние экраны, лист, редактор, диалог, меню) плюс одна
   запасная. Записи добавляются только пока у страницы есть свежее действие
   пользователя (касание, клавиша), а жест «Назад» лишь расходует уже
   имеющиеся: закрыл слой — и записей ровно столько, сколько нужно. Если
   слой после жеста не закрылся (например, спросили «Закрыть без
   сохранения?»), выручает запасная запись, а недостача доливается при
   следующем касании. На главном экране без оверлеев записей нет, и жест
   закрывает WebUI, как и положено. */
let histDepth = (history.state && history.state.nfq) || 0, histPending = false, syncTimer = 0;
function uiLayers(){
  let n = pageDepth(currentPage) + (PAGE_META[currentPage].child ? (lastTop !== 'control' ? 1 : 0) : (currentPage !== 'control' ? 1 : 0));
  if(openSheetId) n++;
  if(dnsSel && currentPage === 'dns') n++;
  if(editorCtx) n++;
  if($('dialog-wrap').classList.contains('open')) n++;
  if(openMenuEntry) n++;
  return n;
}
const canPush = () => !navigator.userActivation || navigator.userActivation.isActive;
function syncHistory(){
  syncTimer = 0;
  updateScrollLock();
  if(histPending) return;                      // ждём popstate от нашего history.go()
  const layers = uiLayers(), target = layers ? layers + 1 : 0;
  try {
    if(target > histDepth){
      if(!canPush()) return;                   // дольём при следующем касании
      while(histDepth < target) history.pushState({nfq: ++histDepth}, '');
    } else if(target < histDepth){
      histPending = true;
      history.go(target - histDepth);
    }
  } catch(e) { histPending = false; }
}
/* Откладываем на такт: «закрыть меню → открыть экран» должно дать одно итоговое состояние */
function scheduleSync(){ if(!syncTimer) syncTimer = setTimeout(syncHistory, 0); }
addEventListener('popstate', e => {
  const d = (e.state && e.state.nfq) || 0;
  if(histPending){ histPending = false; histDepth = d; scheduleSync(); return; }
  const was = histDepth;
  histDepth = d;
  if(d < was) handleBack(true);
  scheduleSync();
});
/* Касание и клавиша дают странице действие пользователя — самое время долить записи */
['pointerdown', 'keydown'].forEach(ev => addEventListener(ev, () => setTimeout(syncHistory, 0), true));

/* ── Пока открыт лист, диалог, меню или редактор, фон не прокручивается ──
   Без этого свайп по scrim или «дотянутая» прокрутка списка внутри листа
   уезжала в страницу под ним. */
function updateScrollLock(){
  const lock = !!(openSheetId || editorCtx || openMenuEntry || $('dialog-wrap').classList.contains('open'));
  document.documentElement.classList.toggle('scroll-locked', lock);
}

/* ── Клавиатура: нижняя панель не поднимается вместе с ней ───────────────
   При adjustResize окно WebView сжимается, и fixed-панель выезжает над
   клавиатурой. На время ввода прячем её, как это делают приложения Google.
   Признак клавиатуры: фокус в текстовом поле и высота окна заметно меньше
   эталонной; сразу после фокуса — авансом, пока клавиатура выезжает. */
const isTextInput = el => !!el && (el.tagName === 'TEXTAREA' ||
  (el.tagName === 'INPUT' && !/^(checkbox|radio|range|button|submit|file|color)$/i.test(el.type)));
const vpHeight = () => (window.visualViewport ? visualViewport.height : innerHeight);
let vpBase = vpHeight(), kbPendingUntil = 0;
function updateKeyboard(){
  const h = vpHeight(), focused = isTextInput(document.activeElement);
  if(!focused) vpBase = Math.max(vpBase, h);
  const open = focused && (vpBase - h > 120 || Date.now() < kbPendingUntil);
  document.body.classList.toggle('kb-open', open);
}
document.addEventListener('focusin', e => {
  if(!isTextInput(e.target)) return;
  kbPendingUntil = Date.now() + 700;
  updateKeyboard();
  setTimeout(updateKeyboard, 750);
});
document.addEventListener('focusout', () => setTimeout(updateKeyboard, 60));
(window.visualViewport || window).addEventListener('resize', updateKeyboard);
addEventListener('orientationchange', () => { vpBase = 0; setTimeout(updateKeyboard, 300); });

/* ── Bottom sheet: смахивание вниз за drag handle, нажатие на него закрывает ── */
/* Затемнение и размытие фона идут за пальцем: тянешь лист вниз — фон
   проясняется, возвращаешь — снова размывается. Отпустил — дальше переход
   CSS от текущего значения: к нулю, если лист закрывается, или обратно. */
const SHEET_BLUR = 6;
function sheetScrimFollow(sheet, dy){
  const sc = $('sheet-scrim'), p = Math.max(0, Math.min(1, 1 - dy / Math.max(1, sheet.offsetHeight)));
  sc.style.transition = 'none';
  sc.style.opacity = p;
  sc.style.webkitBackdropFilter = sc.style.backdropFilter = 'blur(' + (SHEET_BLUR * p).toFixed(2) + 'px)';
}
function sheetScrimRelease(){
  const sc = $('sheet-scrim');
  sc.style.transition = sc.style.opacity = sc.style.webkitBackdropFilter = sc.style.backdropFilter = '';
}
function initSheetDrag(sheet){
  const zone = sheet.querySelector('.sheet-drag');
  let y0 = null, dy = 0, dragged = false;
  zone.addEventListener('pointerdown', e => {
    y0 = e.clientY; dy = 0; dragged = false;
    sheet.style.transition = 'none';
    zone.setPointerCapture(e.pointerId);
  });
  zone.addEventListener('pointermove', e => {
    if(y0 == null) return;
    dy = Math.max(0, e.clientY - y0);
    if(dy > 4) dragged = true;
    sheet.style.transform = 'translateY(' + dy + 'px)';
    sheetScrimFollow(sheet, dy);
  });
  const end = () => {
    if(y0 == null) return;
    y0 = null;
    sheet.style.transition = '';
    sheetScrimRelease();
    if(dy > Math.min(120, sheet.offsetHeight * .25)) requestAnimationFrame(() => closeSheet());
    else sheet.style.transform = '';
  };
  zone.addEventListener('pointerup', end);
  zone.addEventListener('pointercancel', end);
  zone.addEventListener('click', () => { if(dragged){ dragged = false; return; } closeSheet(); });
}
document.querySelectorAll('.sheet').forEach(initSheetDrag);

/* ── Лист со списком: смахивание вниз с любого места, как ящик приложений Pixel ──
   Список в начале и палец пошёл вниз — тянется сам лист, и отпущенный ниже
   порога (или брошенный вниз) он закрывается. Список прокручен или жест
   начался вверх — обычная прокрутка до конца касания. */
function initSheetSwipe(sheet){
  const list = sheet.querySelector('.sheet-scroll');
  if(!list) return;
  let y0 = 0, lastY = 0, lastT = 0, v = 0, state = '', inList = false;   // '' | 'wait' | 'drag' | 'scroll'
  sheet.addEventListener('touchstart', e => {
    state = '';
    if(e.touches.length !== 1 || e.target.closest('.sheet-drag')) return;
    y0 = lastY = e.touches[0].clientY; lastT = e.timeStamp; v = 0;
    // Заголовок и пояснение над списком тянут лист всегда; сам список —
    // только когда он прокручен в начало
    inList = !!e.target.closest('.sheet-scroll');
    state = !inList || list.scrollTop <= 0 ? 'wait' : 'scroll';
  }, {passive: true});
  sheet.addEventListener('touchmove', e => {
    if(!state || state === 'scroll') return;
    const y = e.touches[0].clientY, dy = y - y0;
    if(state === 'wait'){
      if(dy < 0 || (inList && list.scrollTop > 0)){ state = 'scroll'; return; }
      // Вниз от начала списка прокручивать некуда: забираем жест сразу, пока
      // браузер не начал свою прокрутку (после неё touchmove не отменить)
      if(e.cancelable) e.preventDefault();
      if(dy < 8) return;
      state = 'drag'; y0 = y; sheet.style.transition = 'none';
    }
    if(e.cancelable) e.preventDefault();
    if(e.timeStamp > lastT){ v = (y - lastY) / (e.timeStamp - lastT); lastY = y; lastT = e.timeStamp; }
    sheet.style.transform = 'translateY(' + Math.max(0, y - y0) + 'px)';
    sheetScrimFollow(sheet, Math.max(0, y - y0));
  }, {passive: false});
  const end = e => {
    if(state !== 'drag'){ state = ''; return; }
    state = '';
    if(e.cancelable) e.preventDefault();                 // отпущенный жест — не нажатие
    const dy = Math.max(0, lastY - y0);
    sheet.style.transition = '';
    sheetScrimRelease();
    if(e.type === 'touchend' && (dy > Math.min(120, sheet.offsetHeight * .25) || (v > .5 && dy > 24))) requestAnimationFrame(() => closeSheet());
    else sheet.style.transform = '';
  };
  sheet.addEventListener('touchend', end, {passive: false});
  sheet.addEventListener('touchcancel', end);
}
document.querySelectorAll('.sheet.list-sheet').forEach(initSheetSwipe);
