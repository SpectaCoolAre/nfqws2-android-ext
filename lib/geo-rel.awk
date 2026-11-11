# Умный DNS: dns_geo_rel_update (lib/dns.sh). Входы — переменные -v, см. вызов там.
# сайт — как в dns_geo_routes: группа или две последние части имени
# (раньше история была только у групп, и обычные сайты меняли сервер по
# первой же неудачной проверке: Supercell — почти каждый час)
function site(d,   x, i, n, a) { for (x = d; ; x = substr(x, i + 1)) { if (x in grp) return "@" grp[x]; if ((i = index(x, ".")) == 0) break }
  n = split(d, a, "."); return n < 2 ? d : a[n - 1] "." a[n] }
BEGIN { while ((getline l < gf) > 0) { sub(/#.*/, "", l); n = split(tolower(l), a, " "); for (i = 2; i <= n; i++) grp[a[i]] = a[1] }
  while ((getline l < rf) > 0) { split(l, a, "\t"); if (a[1] != "") { sc[a[1], a[2]] = a[3]; st[a[1], a[2]] = a[4]; key[a[1] SUBSEP a[2]] = 1 } }
  # busybox awk пишет в файл, открытый getline, впустую — закрыть
  close(gf); close(rf) }
!/^[#=+!?]/ && NF > 2 { srv[$1] = 1; next }
/^=/ { d = substr($1, 2); s = site(d); if (s == "" || $2 == "-") next
  used[s]++; m = split($2, hs, ","); for (i = 1; i <= m; i++) hit[s, hs[i]]++ }
END {
  for (s in used) for (h in srv) if (hit[s, h] > best[s]) best[s] = hit[s, h]
  for (s in used) for (h in srv) {
    # группа: не меньше 90% её доменов от лучшего, как в dns_geo_routes;
    # обычный сайт — все его домены
    ok = (substr(s, 1, 1) == "@" ? hit[s, h] > 0 && hit[s, h] * 10 >= best[s] * 9 : hit[s, h] == used[s]) ? 1 : 0
    old = ((s, h) in sc) ? sc[s, h] : .5
    sc[s, h] = old * .75 + ok * .25; st[s, h] = ok ? 0 : st[s, h] + 1; key[s SUBSEP h] = 1
  }
  for (k in key) { split(k, a, SUBSEP); printf "%s\t%s\t%.3f\t%d\n", a[1], a[2], sc[a[1], a[2]], st[a[1], a[2]] > rf }
}
