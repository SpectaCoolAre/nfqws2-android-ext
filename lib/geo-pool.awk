# Общий код умного DNS модуля и geodns на роутере (extras/keenetic): одна
# логика выбора серверов обхода геоблока для обоих. Входы — переменные -v, см.
# вызов в lib/dns.sh (dns_geo_pool).
BEGIN { while ((getline l < of) > 0) { gsub(/[[:space:]]/, "", l); if (l != "") off[l] = 1 }
  while ((getline l < pf) > 0) { split(l, a, " "); if (a[1] == "*") pin = a[2] } }
!/^[#=+!?]/ && $2 == "ok" && $4 > 0 && !($1 in off) { c++; h[c] = $1; ms[c] = $3; pr[c] = ($7 == "https" ? "https" : "tls"); p[c] = $4 + 0; if (p[c] > max) max = p[c] }
END { for (i = 1; i <= c; i++) if (p[i] == max || (h[i] == pin && p[i] * 10 >= max * 9)) print (h[i] == pin ? -1 : ms[i]) "\t" h[i] "\t" pr[i] }
