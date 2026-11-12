# Умный DNS: dns_geo_routes (lib/dns.sh). Входы — переменные -v, см. вызов там.
function site(d,   n, a, x, i) {
  for (x = d; ; x = substr(x, i + 1)) { if (x in grp) return "@" grp[x]; if ((i = index(x, ".")) == 0) break }
  n = split(d, a, "."); return n < 2 ? d : a[n - 1] "." a[n] }
function usable(h) { return h != "" && (h in pr) && !(h in off) }
# сервер группы годен: обходит домены, которыми пользуются, и не меньше 70%
# доменов группы от лучшего: DoH-серверы отвечают не на все запросы проверки
# (NullsProxy — на половину), и неотвеченный домен выглядит необходимым
function gfit(s, h) { return cnt[s, h] >= nr && call[s, h] * 10 >= mx[s] * 7 }
function out(d, x) { if (x == "-") print d "\t-"; else print d "\t" x "\t" pr[x] }
BEGIN { while ((getline l < of) > 0) { gsub(/[[:space:]]/, "", l); if (l != "") off[l] = 1 }
  while ((getline l < pf) > 0) { split(l, a, " "); if (a[1] != "") pin[a[1]] = a[2] }
  while ((getline l < gf) > 0) { sub(/#.*/, "", l); n = split(tolower(l), a, " "); for (i = 2; i <= n; i++) grp[a[i]] = a[1] }
  while ((getline l < gpf) > 0) { split(l, a, " "); if (a[1] != "") gpin[a[1]] = a[2] }
  # «=сервер» — закреплён за группой: вся группа через него, пока он отвечает
  while ((getline l < prf) > 0) { sub(/#.*/, "", l); n = split(tolower(l), a, " ")
    for (i = 2; i <= n; i++) { if (substr(a[i], 1, 1) == "=") { a[i] = substr(a[i], 2); fixed["@" a[1]] = a[i] }; pref["@" a[1], a[i]] = i } }
  # основные сервисы — «используемые» всегда, есть частая проверка или нет
  nb = split(base, bl, " "); for (i = 1; i <= nb; i++) basehot[bl[i]] = 1
  while ((getline l < rf) > 0) { split(l, a, "\t"); if (a[1] != "") { rsc[a[1], a[2]] = a[3] + 0; rst[a[1], a[2]] = a[4] + 0 } }
  # busybox awk пишет в файл, открытый getline, впустую — закрыть
  close(of); close(pf); close(gf); close(gpf); close(prf); close(rf)
  n = 0 }
!/^[#=+!?]/ && $2 == "ok" { pr[$1] = ($7 == "https" ? "https" : "tls"); next }
# сервер, не ответивший в частой проверке, сейчас недоступен
# (keepfail — роутер: он спрашивает только по DoH, и сервер, на которого только
# что пришлась полная проверка, частой не отвечает — ограничение частоты, а
# не недоступность; маршруты стягивались на единственный ответивший)
!/^[#=+!?]/ && $2 == "fail" && FILENAME == hf && !keepfail { delete pr[$1]; next }
/^=/ { d = substr($1, 2); if (!(d in rt)) ord[++n] = d; rt[d] = $2; netb[d] = ($3 == "net"); if (FILENAME == hf || (d in basehot)) hot[d] = 1
  if (FILENAME != hf) rtf[d] = $2 }
END {
  # кто какой домен обходит; вес домена, которым пользуются, — 1000
  for (k = 1; k <= n; k++) {
    d = ord[k]; s = site(d); dom[s, ++nd[s]] = d
    if (d in hot) { hall[s]++; if (netb[d]) hnet[s]++ }
    if (rt[d] == "-") continue
    m = split(rt[d], hs, ",")
    for (i = 1; i <= m; i++) if (usable(hs[i])) {
      by[d, hs[i]] = 1; if (!nby[d]++) { first[d] = hs[i]; nk[s]++ }
      if (!((s, hs[i]) in cnt)) so[s, ++ns[s]] = hs[i]
      cnt[s, hs[i]] += (d in hot) ? 1000 : 1; call[s, hs[i]]++
    }
    if (d in hot) hotn[s]++
  }
  # то же по полной проверке — по ней одна неудачная частая сервер группы не снимает
  for (k = 1; k <= n; k++) {
    d = ord[k]; if (!(d in rtf) || rtf[d] == "-") continue
    s = site(d); m = split(rtf[d], hs, ","); c = 0
    for (i = 1; i <= m; i++) if (usable(hs[i])) { callf[s, hs[i]]++; c++; if (d in basehot) bf[s, hs[i]]++
      byf[d, hs[i]] = 1; if (!(d in firstf)) firstf[d] = hs[i] }
    if (c) nkf[s]++
    if (c && (d in basehot)) nbf[s]++
  }
  for (s in nd) {
    isg = substr(s, 1, 1) == "@"
    # годен: обходит все домены сайта, которыми пользуются (частой
    # проверки нет — все известные)
    nr = hotn[s] ? hotn[s] * 1000 : (nk[s] ? nk[s] : 1)
    ch[s] = ""
    if (isg) {
      g = (s in gpin) ? gpin[s] : ""
      # DNS сети обходит группу сам — с запасом в обе стороны
      if (hall[s] > 0 && (g == "-" ? hnet[s] * 2 > hall[s] : hnet[s] == hall[s])) { ch[s] = "-"; continue }
      if (g == "-") g = ""
      # закреплённый сервер: проверка «обходит / не обходит» тут не решает
      # (NullsProxy обслуживает все игры Supercell, а в проверке видны два-три
      # домена — ответил на половину запросов), нужен только ответ сервера
      if ((s in fixed) && usable(fixed[s])) { ch[s] = fixed[s]; continue }
      # лучшее покрытие группы — среди обходящих домены, которыми пользуются
      mx[s] = 0; mxf = 0; anyfit = 0
      for (i = 1; i <= ns[s]; i++) { h = so[s, i]; if (cnt[s, h] >= nr && call[s, h] > mx[s]) mx[s] = call[s, h]; if (callf[s, h] > mxf) mxf = callf[s, h] }
      for (i = 1; i <= ns[s]; i++) if (gfit(s, so[s, i])) anyfit = 1
      if (usable(g) && gfit(s, g)) { ch[s] = g; continue }
      # по старым данным сети — пока отвечает; одна неудачная частая
      # проверка не снимает, если по полной обходит всё
      if (usable(g) && !fresh) { ch[s] = g; continue }
      # …но только если по ней он обходит и основные сервисы группы (claude.ai,
      # gemini.google.com): bezmezhau держал Anthropic и Google по второстепенным
      # доменам, а сами Claude и Gemini через него не открывались (12.11, МТС)
      if (usable(g) && ((s, g) in rst) && rst[s, g] < 2 && mxf && callf[s, g] * 10 >= mxf * 7 && bf[s, g] + 0 >= nbf[s] + 0) { ch[s] = g; continue }
      # используемые не обходит никто — держится выбранный, пока отвечает
      if (usable(g) && !anyfit) { ch[s] = g; continue }
      # новый: годные (предпочтительные, надёжные), затем обходящие
      # используемые и больше доменов, затем обходящие больше
      best = ""
      for (i = 1; i <= ns[s]; i++) { h = so[s, i]
        tr = gfit(s, h) ? 2 : (cnt[s, h] >= nr ? 1 : 0)
        p = (tr == 2 && ((s, h) in pref)) ? 1000 - pref[s, h] : 0; r = (tr == 2 && ((s, h) in rsc)) ? rsc[s, h] : .5
        if (best == "" || tr > bt || (tr == bt && (p > bp || (p == bp && (r > br + .001 || (r > br - .001 && (call[s, h] > call[s, best] || (call[s, h] == call[s, best] && cnt[s, h] > cnt[s, best])))))))) { best = h; bt = tr; bp = p; br = r } }
      ch[s] = best; continue
    } else {
      # обычный сайт: пул его обходит — своего сервера не нужно
      if (usable(pool) && ((s, pool) in cnt) && cnt[s, pool] >= nr) continue
      g = (s in pin) ? pin[s] : ""
    }
    # выбранный держится, пока годен, не подвёл две проверки подряд и
    # отвечает; по старым данным сети — пока отвечает
    if (usable(g) && ((s, g) in cnt ? cnt[s, g] >= nr : 0)) { ch[s] = g; continue }
    if (usable(g) && (!fresh || (((s, g) in rst) && rst[s, g] < 2))) { ch[s] = g; continue }
    # новый: годные — предпочтительные, надёжные по истории, обходящие больше
    best = ""; bp = 0; br = -1
    for (i = 1; i <= ns[s]; i++) { h = so[s, i]; if (cnt[s, h] < nr) continue
      p = ((s, h) in pref) ? 1000 - pref[s, h] : 0; r = ((s, h) in rsc) ? rsc[s, h] : .5
      if (best == "" || p > bp || (p == bp && (r > br + .001 || (r > br - .001 && cnt[s, h] > cnt[s, best])))) { best = h; bp = p; br = r } }
    # годных нет — тот, что обходит больше всех
    if (best == "") for (i = 1; i <= ns[s]; i++) { h = so[s, i]; if (best == "" || cnt[s, h] > cnt[s, best]) best = h }
    if (!isg && best == pool) best = ""
    ch[s] = best
  }
  # второй сервер группы — обходящий больше всех её доменов после выбранного
  for (s in ch) if (substr(s, 1, 1) == "@" && ch[s] != "" && ch[s] != "-") {
    sec[s] = ""
    for (i = 1; i <= ns[s]; i++) { h = so[s, i]; if (h != ch[s] && usable(h) && (sec[s] == "" || call[s, h] > call[s, sec[s]])) sec[s] = h }
  }
  for (k = 1; k <= n; k++) {
    d = ord[k]; s = site(d)
    if (ch[s] == "-") { out(d, "-"); continue }
    # группа — через свой сервер (один адрес выхода). Домен группы, который
    # он не обходит (отдаёт настоящий адрес), а другие обходят, — к ним: иначе
    # он шёл напрямую с адреса телефона. Так Gemini ушёл в геоблок: webshift
    # обходит gemini.google.com, а signaler-pa, apis.google.com — нет (12.11)
    # Решает полная проверка (одна неудачная частая — нет) и только по свежим
    # данным сети (по старым сервер группы держится, пока отвечает);
    # закреплённый за группой сервер (NullsProxy) — целиком
    if (ch[s] != "" && substr(s, 1, 1) == "@") {
      if (fresh && !(s in fixed) && !((d, ch[s]) in byf) && (d in firstf)) out(d, (sec[s] != "" && ((d, sec[s]) in byf)) ? sec[s] : firstf[d])
      else out(d, ch[s])
      continue
    }
    # у обычного сайта к его серверу — домены, которые тот обходит, остальные — в пул
    if (ch[s] != "" && ((d, ch[s]) in by)) { out(d, ch[s]); continue }
    # и пул его не обходит — к тому, кто обходит
    if (nby[d] && !((d, pool) in by)) { out(d, first[d]); continue }
    # домен, который не обходит никто или обходит сам DNS сети (роутер), —
    # в DNS сети
    if (rt[d] == "-") out(d, "-")
  }
  # домены групп, которых проверка ещё не знает, — к серверу группы
  while ((getline l < gl) > 0) {
    sub(/[[:space:]]*#.*/, "", l); gsub(/[[:space:]]/, "", l); d = tolower(l)
    if (d == "" || (d in rt) || (d in done)) continue
    done[d] = 1; s = site(d)
    if (substr(s, 1, 1) == "@" && ch[s] != "") out(d, ch[s])
  }
  if (save == "save") {
    if ("*" in pin) print "* " pin["*"] > pf
    for (s in ch) if (ch[s] != "" && ch[s] != "-" && substr(s, 1, 1) != "@") print s, ch[s] > pf
    for (s in ch) if (substr(s, 1, 1) == "@" && ch[s] != "") gpin[s] = ch[s]
    for (s in gpin) if (gpin[s] != "") print s, gpin[s] > gpf
  }
}
