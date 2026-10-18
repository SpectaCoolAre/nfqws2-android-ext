/* ── Пасхалка: частые нажатия на логотип в шапке ────────────────────────
   Логотип трясётся всё сильнее, уезжает за правый край, и через затемнение
   открывается Flappy Bird: вместо птички — логотип, вместо труб — столбики
   из слов BAN. Всё рисуется на canvas текстом и цветами текущей темы,
   картинок нет. Рекорд — в localStorage. Выход — «Назад» или стрелка.

   WebView рисует canvas в UI-потоке приложения-менеджера: тяжёлый кадр там
   — это «приложение не отвечает». Поэтому весь текст (город, трубы, земля,
   логотип) рисуется один раз в спрайты на CPU, по одному за такт, пока
   идёт катсцена, а кадр игры — только копирование готовых картинок. */
const flappy = (() => {
  const NEED = 12, GAP_MS = 650, BEST_KEY = 'nfq_flappy_best';
  let taps = 0, lastTap = 0, shakeAnim = null;
  let ov = null, cv = null, ctx = null, raf = 0, open = false, starting = false, gen = 0;
  let W = 0, H = 0, dpr = 1, C = {}, font = 'sans-serif', sp = null, top0 = 44;
  let st, best = +store.get(BEST_KEY) || 0;

  const logo = () => $('brand-logo');
  const cssv = n => getComputedStyle(document.documentElement).getPropertyValue('--md-sys-color-' + n).trim() || '#888';
  const rnd = (a, b) => a + Math.random() * (b - a);
  const groundY = () => Math.round(H * .88);
  const unit = () => Math.min(H / 46, W / 18);

  function onTap(){
    if(!$('app-bar').classList.contains('top') || open || starting) return;
    const now = performance.now();
    taps = now - lastTap < GAP_MS ? taps + 1 : 1;
    lastTap = now;
    const el = logo(), k = taps / NEED, a = 1.5 + k * 9, d = Math.max(60, 260 - k * 200);
    if(shakeAnim) shakeAnim.cancel();
    shakeAnim = el.animate([{transform: 'none'}, {transform: `translateX(${-a}px) rotate(${-a}deg)`},
      {transform: `translateX(${a}px) rotate(${a}deg)`}, {transform: 'none'}],
      {duration: d, iterations: Math.max(1, Math.round(GAP_MS / d))});
    if(taps >= NEED){ taps = 0; launch(el); }
  }

  /* Катсцена: копия логотипа поверх всего уезжает вправо, мимо кнопки журналов.
     Спрайты готовятся параллельно; игра начинается, когда готово и то и другое */
  function launch(el){
    starting = true; open = true;
    if(shakeAnim) shakeAnim.cancel();
    try { build(); } catch(e) { fail(e); return; }
    scheduleSync();
    const r = el.getBoundingClientRect(), fly = el.cloneNode(true);
    fly.removeAttribute('id');
    fly.style.cssText = `position:fixed;left:${r.left}px;top:${r.top}px;margin:0;z-index:96;will-change:transform`;
    document.body.append(fly);
    el.style.visibility = 'hidden';
    let parts = 2;
    const go = () => {
      if(--parts || !open) return;
      cv.style.opacity = 1; ov.querySelector('button').style.opacity = 1;
      starting = false; reset(); loop();
    };
    prepare(go);
    const dx = innerWidth - r.left + 40;
    fly.animate([{transform: 'none'}, {transform: 'translateX(-14px) rotate(-30deg)', offset: .3},
      {transform: `translateX(${dx}px) rotate(540deg)`}],
      {duration: 1100, easing: 'cubic-bezier(.5,0,.75,0)', fill: 'forwards'}).onfinish = () => {
      fly.remove();
      go();
    };
  }

  function build(){
    ov = document.createElement('div');
    ov.id = 'flappy';
    ov.style.cssText = 'position:fixed;inset:0;z-index:95;touch-action:none;user-select:none;-webkit-user-select:none';
    ov.innerHTML = '<div style="position:absolute;inset:0;background:#000;opacity:0;pointer-events:none"></div>' +
      '<canvas style="position:absolute;inset:0;width:100%;height:100%;opacity:0;transition:opacity .5s"></canvas>' +
      `<button class="icon-btn state tone-on" aria-label="${t('Назад')}" style="position:absolute;left:4px;` +
      'top:calc(var(--top-inset) + 4px);opacity:0;transition:opacity .5s;z-index:1">' +
      '<svg aria-hidden="true" class="icon"><use href="#i-back"/></svg></button>';
    document.body.append(ov);
    /* Затемнение — отдельный слой: анимация прозрачности идёт на композиторе */
    ov.firstChild.animate([{opacity: 0}, {opacity: .85}], {duration: 1500, easing: 'ease-in', fill: 'forwards'});
    cv = ov.querySelector('canvas');
    ctx = cv.getContext('2d', {alpha: false});
    ov.querySelector('button').addEventListener('click', e => { e.stopPropagation(); close(); });
    ov.addEventListener('pointerdown', e => {
      e.stopPropagation();
      if(e.target.closest('button') || starting) return;
      e.preventDefault();
      flap();
    });
    ov.addEventListener('pointerup', e => e.stopPropagation());
    ov.addEventListener('contextmenu', e => e.preventDefault());
    addEventListener('resize', onResize);
    addEventListener('keydown', onKey, true);
    document.addEventListener('visibilitychange', onVis);
    font = getComputedStyle(document.body).fontFamily;
  }

  function onKey(e){
    if(e.key === ' ' || e.key === 'ArrowUp'){ e.preventDefault(); e.stopPropagation(); if(!starting) flap(); }
  }
  function onVis(){ if(st) st.last = 0; }
  let rzTimer = 0;
  function onResize(){
    clearTimeout(rzTimer);
    rzTimer = setTimeout(() => { if(open && !starting) prepare(() => {}); }, 200);
  }

  /* Игра — шутка: при любой ошибке просто закрываемся, интерфейс важнее */
  function fail(e){
    close();
    toast('flappy: ' + (e && e.message || e));
  }

  function close(){
    if(!open) return;
    open = false; starting = false; gen++;
    cancelAnimationFrame(raf);
    removeEventListener('resize', onResize);
    removeEventListener('keydown', onKey, true);
    document.removeEventListener('visibilitychange', onVis);
    const o = ov; ov = null; sp = null;
    if(o){
      o.style.pointerEvents = 'none';
      o.animate([{opacity: 1}, {opacity: 0}], {duration: 300, fill: 'forwards'}).onfinish = () => o.remove();
    }
    /* Логотип возвращается на место слева */
    const el = logo();
    el.style.visibility = '';
    el.animate([{transform: `translateX(${-el.getBoundingClientRect().right - 20}px) rotate(-540deg)`}, {transform: 'none'}],
      {duration: 700, easing: 'cubic-bezier(.2,.8,.3,1)'});
    scheduleSync();
  }

  /* ── Спрайты ──────────────────────────────────────────────────────────
     Каждый рисуется на CPU-холсте (willReadFrequently) — не в GPU-очереди
     менеджера — и по одному за такт, чтобы не держать поток. */
  function prepare(done){
    const my = ++gen;
    dpr = Math.min(devicePixelRatio || 1, 2);
    W = innerWidth; H = innerHeight;
    cv.width = Math.round(W * dpr); cv.height = Math.round(H * dpr);
    C = {sky: cssv('surface-container-lowest'), sky2: cssv('secondary-container'), far: cssv('secondary-container'),
      farHi: cssv('on-secondary-container'), near: cssv('surface-container-highest'), win: cssv('tertiary'),
      dim: cssv('outline-variant'), star: cssv('outline'), moon: cssv('tertiary-container'),
      ground: cssv('surface-container-high'), line: cssv('primary'),
      pipe: cssv('tertiary-container'), pipeTx: cssv('on-tertiary-container'), pipeEdge: cssv('tertiary'),
      p: cssv('primary'), onP: cssv('on-primary'), tx: cssv('on-surface'), bg: cssv('surface')};
    top0 = topInset() + 10;
    const gy = groundY(), u = unit(), pw = u * 2.9, fs = Math.round(pw * .5), next = {};
    const jobs = [
      () => next.moon = sprite(16, 16, 1, g => {
        g.fillStyle = C.moon; g.font = `9px ${font}`; g.textAlign = 'center'; g.textBaseline = 'middle'; g.fillText('●', 8, 8.5);
      }),
      () => next.stars = sprite(W, gy, dpr, drawStars),
      () => next.far = sprite(Math.max(W, 360) * 1.3, gy, .35, drawFar),   // низкое разрешение = размытие
      () => next.near = sprite(Math.max(W, 360) * 1.6, gy, dpr, drawNear),
      () => next.ground = sprite(W + 28, H - gy, dpr, drawGround),
      () => next.pipeDown = sprite(pw + u * .6, gy + fs * 2, dpr, (g, w, h) => drawPipe(g, w, h, pw, fs, false)),
      () => next.pipeUp = sprite(pw + u * .6, gy + fs * 2, dpr, (g, w, h) => drawPipe(g, w, h, pw, fs, true)),
      () => next.logo = sprite(u * 3.4, u * 3.4, dpr, (g, w) => drawLogo(g, w, u * 1.15))
    ];
    /* Готовый CPU-холст переводим в ImageBitmap: в видеопамять он уходит
       один раз, а не при каждом кадре */
    const bitmaps = () => Promise.all(Object.keys(next).map(k => {
      const c = next[k];
      if(!window.createImageBitmap) return null;
      return createImageBitmap(c).then(b => { b.w = c.w; b.h = c.h; next[k] = b; }, () => {});
    }));
    const run = () => {
      if(my !== gen || !open) return;
      try { jobs.shift()(); } catch(e) { fail(e); return; }
      if(jobs.length){ setTimeout(run, 16); return; }
      bitmaps().then(() => {
        if(my !== gen || !open) return;
        next.pw = pw;
        sp = next;
        done();
      });
    };
    setTimeout(run, 16);
  }

  function sprite(w, h, scale, fn){
    w = Math.ceil(w); h = Math.ceil(h);
    const c = document.createElement('canvas');
    c.width = Math.max(1, Math.ceil(w * scale)); c.height = Math.max(1, Math.ceil(h * scale));
    const g = c.getContext('2d', {willReadFrequently: true});
    g.scale(scale, scale); g.textBaseline = 'top';
    fn(g, w, h);
    c.w = w; c.h = h;
    return c;
  }

  /* Небо вместе со звёздами: градиент вертикальный, так что плитка стыкуется */
  function drawStars(g, w, h){
    const sky = g.createLinearGradient(0, 0, 0, h);
    sky.addColorStop(0, C.sky); sky.addColorStop(1, C.sky2);
    g.fillStyle = sky; g.fillRect(0, 0, w, h);
    g.globalAlpha = .55; g.fillStyle = C.sky; g.fillRect(0, 0, w, h); g.globalAlpha = 1;
    const chars = '··+✦˚*·';
    for(let i = 0; i < Math.min(90, w * h / 4200); i++){
      g.globalAlpha = rnd(.35, .9);
      g.fillStyle = Math.random() < .3 ? C.win : C.star;
      g.font = `${Math.round(rnd(8, 15))}px ${font}`;
      g.fillText(chars[i % chars.length], rnd(0, w), rnd(0, h * .6));
    }
    /* Еле заметные столбики 0/1 — пакеты, летящие по сети */
    g.font = `10px monospace`; g.fillStyle = C.dim;
    for(let x = 6; x < w; x += rnd(40, 90)){
      g.globalAlpha = rnd(.15, .35);
      for(let y = rnd(0, h * .3), n = rnd(3, 9); n-- > 0; y += 11) g.fillText(Math.random() < .5 ? '0' : '1', x, y);
    }
    g.globalAlpha = 1;
  }

  /* Дома — строками моноширинных символов: одна строка — один вызов */
  function house(g, x, h, cols, rows, cs, body, win, lit){
    const top = h - rows * cs;
    for(let r = 0; r < rows; r++){
      const y = top + r * cs;
      g.fillStyle = body; g.globalAlpha = 1;
      g.fillText('█'.repeat(cols), x, y);
      if(!win || r === 0 || r === rows - 1) continue;
      let a = '', b = '';
      for(let c = 0; c < cols; c++){
        const edge = c === 0 || c === cols - 1, on = !edge && Math.random() < lit;
        a += on ? '▪' : ' '; b += !edge && !on && Math.random() < .5 ? '·' : ' ';
      }
      g.fillStyle = win; g.globalAlpha = .9; g.fillText(a, x, y);
      g.fillStyle = C.dim; g.globalAlpha = .6; g.fillText(b, x, y);
    }
    g.globalAlpha = 1;
  }

  function drawFar(g, w, h){
    const cs = 9;
    g.font = `${cs}px monospace`;
    const cw = g.measureText('█').width || cs * .6;
    for(let x = -20; x < w; ){
      const cols = Math.round(rnd(5, 11)), rows = Math.round(rnd(h * .16, h * .42) / cs), bw = cols * cw;
      for(const X of x < 0 ? [x, x + w] : [x]) house(g, X, h, cols, rows, cs, C.far, C.farHi, .2);
      x += bw + Math.round(rnd(0, 3)) * cw;
    }
  }

  function drawNear(g, w, h){
    const cs = 11;
    g.font = `${cs}px monospace`;
    const cw = g.measureText('█').width || cs * .6;
    for(let x = 0; x < w; ){
      const cols = Math.round(rnd(5, 11)), rows = Math.round(rnd(h * .1, h * .3) / cs), bw = cols * cw;
      if(x + bw > w) break;
      house(g, x, h, cols, rows, cs, C.near, C.win, .4);
      g.fillStyle = C.near;
      // Крыша: ряд «▄» во всю ширину дома или шпиль «▲» по центру
      if(Math.random() < .5) g.fillText('▄'.repeat(cols), x, h - rows * cs - cs);
      else g.fillText('▲', x + bw / 2 - g.measureText('▲').width / 2, h - rows * cs - cs);
      x += bw + Math.round(rnd(2, 6)) * cw;
    }
  }

  function drawGround(g, w, h){
    g.fillStyle = C.ground; g.fillRect(0, 0, w, h);
    g.fillStyle = C.line; g.fillRect(0, 0, w, 2);
    g.font = `12px monospace`; g.fillStyle = C.dim;
    for(let x = 0, i = 0; x < w; x += 14, i++) g.fillText(i % 2 ? '╲' : '╱', x, 14);
    g.globalAlpha = .6;
    for(let x = 0; x < w; x += 28) g.fillText('·', x, 30);
    g.globalAlpha = 1;
  }

  /* Столбик BAN с шапкой у зазора. down — нижняя труба (шапка сверху),
     up — верхняя (шапка снизу); сверху вниз всегда читается B-A-N */
  function drawPipe(g, w, h, pw, fs, up){
    const x = (w - pw) / 2, ch = fs * 1.05, cap = fs * 1.25, r = pw * .18;
    g.fillStyle = C.pipe; rr(g, x, up ? -r : 0, pw, h + r, r); g.fill();
    g.strokeStyle = C.pipeEdge; g.lineWidth = 2; g.stroke();
    g.textAlign = 'center'; g.textBaseline = 'middle';
    g.fillStyle = C.pipeTx; g.font = `900 ${fs}px ${font}`;
    for(let i = 0, n = Math.ceil(h / ch); i < n; i++){
      const cy = up ? h - cap - ch * (i + .5) : cap + ch * (i + .5);
      g.fillText('BAN'[up ? 2 - i % 3 : i % 3], w / 2, cy + 1);
    }
    const cy = up ? h - cap : 0;
    g.fillStyle = C.pipeEdge; rr(g, 0, cy, w, cap, cap * .3); g.fill();
    g.fillStyle = C.pipe; g.font = `900 ${Math.round(fs * .62)}px ${font}`;
    g.fillText('BAN', w / 2, cy + cap / 2 + 1);
  }

  /* Логотип: круг цвета темы и «N2» из того же SVG-символа, что в шапке */
  function drawLogo(g, w, r){
    g.translate(w / 2, w / 2);
    g.shadowColor = 'rgba(0,0,0,.3)'; g.shadowBlur = 8; g.shadowOffsetY = 2;
    g.fillStyle = C.p; g.beginPath(); g.arc(0, 0, r, 0, Math.PI * 2); g.fill();
    g.shadowColor = 'transparent';
    const s = r * 1.3 / 512;
    g.scale(s, s); g.translate(-256, -256);
    g.fillStyle = C.onP;
    document.querySelectorAll('#i-n2 polygon').forEach(pg => {
      const pts = pg.getAttribute('points').trim().split(/\s+/);
      g.beginPath();
      pts.forEach((s, i) => { const [x, y] = s.split(','); i ? g.lineTo(+x, +y) : g.moveTo(+x, +y); });
      g.closePath(); g.fill();
    });
  }

  /* ── Игра ── */
  function reset(){
    const u = unit();
    st = {mode: 'ready', x: W * .28, y: groundY() * .45, vy: 0, r: u * 1.15, pipes: [], score: 0, scroll: 0,
      t: 0, last: 0, dead: 0, acc: 0, next: 0, newBest: false};
  }

  function flap(){
    if(!st) return;
    if(st.mode === 'dead'){
      if(performance.now() - st.dead < 450) return;  // случайный тап сразу после проигрыша не перезапускает
      reset(); return;
    }
    if(st.mode === 'ready') st.mode = 'play';
    st.vy = -H * .58;
  }

  function spawn(){
    const u = unit(), gap = Math.max(H * .24, u * 7.2), m = H * .1;
    st.pipes.push({x: W + u * 2, top: rnd(m, groundY() - m - gap), gap, w: sp.pw, passed: false});
  }

  function step(dt){
    st.t += dt;
    if(st.mode === 'dead') return;
    const speed = H * .21, gy = groundY();
    st.scroll += speed * dt;
    if(st.mode === 'ready'){ st.y = gy * .45 + Math.sin(st.t * 3) * unit() * .6; return; }
    st.vy = Math.min(st.vy + H * 1.85 * dt, H * 1.2);
    st.y += st.vy * dt;
    if(st.y < st.r){ st.y = st.r; st.vy = 0; }
    st.next -= speed * dt;
    if(st.next <= 0){ spawn(); st.next = Math.max(H * .42, W * .55); }
    const r = st.r * .82;
    for(const p of st.pipes){
      p.x -= speed * dt;
      if(!p.passed && p.x + p.w < st.x - r){ p.passed = true; st.score++; }
      const cx = Math.max(p.x, Math.min(st.x, p.x + p.w));
      for(const [y0, y1] of [[-1e4, p.top], [p.top + p.gap, 1e4]]){
        const cy = Math.max(y0, Math.min(st.y, y1));
        if((st.x - cx) ** 2 + (st.y - cy) ** 2 < r * r) die();
      }
    }
    st.pipes = st.pipes.filter(p => p.x + p.w > -20);
    if(st.y + r >= gy){ st.y = gy - r; die(); }
  }

  function die(){
    if(st.mode === 'dead') return;
    st.mode = 'dead'; st.dead = performance.now();
    if(st.score > best){ best = st.score; st.newBest = true; store.set(BEST_KEY, best); }
    try { navigator.vibrate && navigator.vibrate(40); } catch(e) {}
  }

  function loop(){
    raf = requestAnimationFrame(now => {
      if(!open) return;
      const dt = st.last ? Math.min((now - st.last) / 1000, .05) : 0;
      st.last = now;
      st.acc += dt;
      try {
        while(st.acc >= 1 / 120){ step(1 / 120); st.acc -= 1 / 120; }
        if(sp) draw();
      } catch(e) { fail(e); return; }
      loop();
    });
  }

  const put = (img, x, y) => ctx.drawImage(img, x, y, img.w, img.h);
  function scrolled(img, v, y){
    const w = img.w;
    for(let x = -((st.scroll * v) % w); x < W; x += w) put(img, x, y);
  }

  function draw(){
    const g = ctx, gy = groundY(), u = unit();
    g.setTransform(dpr, 0, 0, dpr, 0, 0);
    scrolled(sp.stars, .04, 0);
    const m = H * .2;  // луна: крошечный «●», растянутый до размытого пятна
    g.drawImage(sp.moon, W * .7 - m / 2, gy * .06, m, m);
    scrolled(sp.far, .18, gy - sp.far.h);
    scrolled(sp.near, .42, gy - sp.near.h);
    /* Трубы-баны: куски готовых столбиков */
    const pd = sp.pipeDown, pu = sp.pipeUp, k = pd.width / pd.w;
    for(const p of st.pipes){
      const x = p.x - (pd.w - p.w) / 2, hb = Math.min(gy - p.top - p.gap, pd.h), ht = Math.min(p.top, pu.h);
      if(hb > 0) g.drawImage(pd, 0, 0, pd.width, hb * k, x, p.top + p.gap, pd.w, hb);
      if(ht > 0) g.drawImage(pu, 0, (pu.h - ht) * k, pu.width, ht * k, x, p.top - ht, pu.w, ht);
    }
    put(sp.ground, -(st.scroll % 28), gy);
    /* Логотип */
    g.save();
    g.translate(st.x, st.y);
    g.rotate(st.mode === 'ready' ? 0 : Math.max(-.45, Math.min(1.2, st.vy / (H * .9))));
    put(sp.logo, -sp.logo.w / 2, -sp.logo.h / 2);
    g.restore();
    /* Счёт и подсказки */
    g.textAlign = 'center'; g.textBaseline = 'top';
    label(g, String(st.score), W / 2, top0, `800 ${Math.round(u * 2.6)}px ${font}`);
    label(g, `BEST ${best}`, W / 2, top0 + u * 2.9, `600 ${Math.round(u * .8)}px ${font}`);
    if(st.mode !== 'play'){
      const blink = .55 + .45 * Math.sin(st.t * 4);
      g.globalAlpha = st.mode === 'dead' ? 1 : blink;
      if(st.mode === 'dead'){
        label(g, st.newBest ? 'NEW BEST!' : 'BANNED', W / 2, gy * .3, `900 ${Math.round(u * 1.8)}px ${font}`);
        g.globalAlpha = blink;
      }
      label(g, st.mode === 'dead' ? 'tap to restart' : 'tap to start', W / 2, gy * .62, `600 ${Math.round(u * 1.05)}px ${font}`);
      g.globalAlpha = 1;
    }
  }

  function rr(g, x, y, w, h, r){
    g.beginPath();
    if(g.roundRect) g.roundRect(x, y, w, h, r); else g.rect(x, y, w, h);
  }

  function label(g, s, x, y, f){
    g.font = f; g.lineJoin = 'round';
    g.lineWidth = 5; g.strokeStyle = C.bg; g.strokeText(s, x, y);
    g.fillStyle = C.tx; g.fillText(s, x, y);
  }

  function topInset(){
    const p = document.createElement('div');
    p.style.cssText = 'position:fixed;top:0;height:var(--top-inset);width:0;visibility:hidden;pointer-events:none';
    document.body.append(p);
    const h = p.offsetHeight;
    p.remove();
    return Math.max(h, 44);
  }

  const el = logo();
  if(el) el.addEventListener('click', onTap);
  return {get open(){ return open; }, close};
})();
