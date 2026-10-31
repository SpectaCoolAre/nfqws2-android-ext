#!/bin/sh
# Отладочный замер умного режима (nfqws2-ctl smart-bench): сайты сети через
# все варианты, этап 2 по лучшим, сводка JSON и текстом. Оркестратор здесь
# заменяет поддельный curl: он сам читает «сайт вариант» и пишет профиль.

HERE=$(cd "$(dirname "$0")" && pwd)
TESTS_DIR=$(cd "$HERE/.." && pwd)
REPO_DIR=$(cd "$TESTS_DIR/.." && pwd)
. "$TESTS_DIR/lib/harness.sh"

sandbox_init
load_common
# набор вариантов замера (#@bench-…) проверяется отдельно, в конце
sed -i '/^#@bench-/d' "$MODDIR/strategies/smart.conf"
cp -f "$MODDIR/strategies/smart.conf" "$CONFFILE"; echo smart > "$ACTIVE_FILE"
reload_conf

# curl: вариант — из state/smart_bench.*, профиль — как сообщил бы оркестратор.
# blocked.example открывается на 2 и 4, slow.example — только на 3 (и рвётся на
# 16 КБ на 1), open.example — и без обхода, yt.example — профиль google
# (вариантов 3), открывает 3; dead.example — не открывается ничем
cat > "$MOCKBIN/curl" <<'X'
#!/bin/sh
o=""; for a; do [ "$p" = "-o" ] && o="$a"; p="$a"; u="$a"; done
# проверка TCP без TLS (http://<адрес>:443/): адрес у сайта — «ip-<сайт>»
case "$u" in
  http://ip-*)
    key=${u#http://ip-}; key=${key%%:*}
    case "$key" in
      closed.example) echo "0.000000"; exit 28 ;;
      pen.example) [ -f "$BENCH_STATE/pen.block" ] && { rm -f "$BENCH_STATE/pen.block"; echo "0.000000"; exit 28; } ;;
      late.example) [ "$(cat "$BENCH_STATE/late.n" 2>/dev/null || echo 0)" -le 2 ] && { echo "0.000000"; exit 28; } ;;
    esac
    echo "0.030000"; exit 0 ;;
esac
cp -f "$BENCH_STATE/smart_bench" "$BENCH_STATE/bench.mark" 2>/dev/null
[ -n "$BENCH_HANG" ] && sleep 30
h=${u#https://}; h=${h%%/*}; key=${h#www.}; key=${key#cdn.}
# ответ как у curl -w: код, connect, appconnect, первый байт, всего, байт, адрес, переадресация
R() { echo "$1 $2 $3 $4 $5 $6 ip-$key ${7:-}"; }
v=$(cat "$BENCH_STATE"/smart_bench.[0-9]* 2>/dev/null | awk -v h="$key" '$1 == h { print $2 }')
slot=tls; n=4; [ "$key" = yt.example ] && { slot=google; n=3; }
[ "$key" = nodns.example ] && exit 6
# listed.example попадает в профиль только как cdn.listed.example (так он в списке)
[ "$key" = listed.example ] && [ "$h" != cdn.listed.example ] && { R 000 0.050 0 0 10 0; exit 28; }
echo "$h" >> "$BENCH_STATE/curl.hosts"
# late.example: адрес закрыт на первых двух пробах, потом открывается
if [ "$key" = late.example ]; then
  c=$(cat "$BENCH_STATE/late.n" 2>/dev/null || echo 0); echo $((c + 1)) > "$BENCH_STATE/late.n"
  [ "$c" -lt 2 ] && { R 000 0.000000 0.000000 0 5.0 0; exit 28; }
fi
# closed.example: адрес закрыт — не соединяется никогда
[ "$key" = closed.example ] && { R 000 0.000000 0.000000 0 5.0 0; exit 28; }
# pen.example: после каждого варианта ТСПУ на время закрывает адрес — следующая
# попытка не соединяется (и TCP тоже), повтор в конце этапа проходит
if [ "$key" = pen.example ]; then
  if [ -s "$BENCH_STATE/pen.last" ]; then rm -f "$BENCH_STATE/pen.last"; : > "$BENCH_STATE/pen.block"; R 000 0.000000 0.000000 0 5.0 0; exit 28; fi
  [ "$v" != 0 ] && [ "$v" != - ] && echo "$v" > "$BENCH_STATE/pen.last"
fi
[ "$v" = - ] && printf '%s\t%s\t%s\t0\n' "$key" "$slot" "$n" >> "$BENCH_STATE/smart_bench.seen"
# переадресации — на варианте 1 (без обхода эти сайты не открываются)
case "$h:$v" in
  redir.example:1) R 301 0.050 0.120 0.300 0.400 0 https://other.example/; exit 0 ;;
  same.example:1) R 301 0.050 0.120 0.300 0.400 0 https://www.same.example/x; exit 0 ;;
  www.same.example:1) R 200 0.050 0.120 0.300 0.400 30000; exit 0 ;;
  stub.example:1) R 302 0.050 0.120 0.300 0.400 0 "http://warning.rt.ru/?id=1"; exit 0 ;;
esac
# page.example: на варианте 1 вместо сайта — страница-заглушка (без переадресации)
case "$key:$v" in page.example:1) printf '<title>Доступ к ресурсу ограничен</title>' > "$o"; R 200 0.050 0.120 0.300 0.400 40; exit 0 ;;
  page.example:2) printf '<title>Page</title>%s' "$(head -c 30000 /dev/zero | tr '\0' a)" > "$o"; R 200 0.050 0.120 0.300 0.400 30000; exit 0 ;; esac
# drop.example: DPI молча роняет ClientHello — curl отвечает как при закрытом
# адресе (time_connect 0), но TCP соединяется; открывает только 4
case "$key:$v" in drop.example:4) ;; drop.example:*) R 000 0.000000 0.000000 0 5.0 0; exit 28 ;; esac
case "$key:$v" in
  open.example:*|pen.example:*|late.example:2|drop.example:4|listed.example:1|blocked.example:2|blocked.example:4|slow.example:3|yt.example:3)
    R 200 0.050 0.120 0.300 0.400 30000; exit 0 ;;
  slow.example:1) R 200 0.050 0.120 0.300 10.0 16000; exit 28 ;;
  blocked.example:1) R 000 0.050 0 0 1 0; exit 35 ;;
  *) R 000 0.050 0.000000 0 10 0; exit 28 ;;
esac
X
chmod 0755 "$MOCKBIN/curl"
BENCH_STATE="$STATE_DIR"; BENCH_SETTLE=0 BENCH_PAUSE=0; export BENCH_STATE BENCH_SETTLE BENCH_PAUSE

mkdir -p "$SMART_DIR"
echo mobile-25001 > "$SMART_NET_FILE"
printf '#v4 header\ntls\tblocked.example\t1\t\t\t\t1\ntls_16\tslow.example\t1\t\t\t\t1\ntls\topen.example\t1\t\t\t\t1\ngoogle\tyt.example\t1\t\t\t\t1\ntls\tdead.example\t1\t\t\t\t1\ntls\tnodns.example\t1\t\t\t\t1\ntls\tlisted.example\t1\t\t\t\t1\ntls\tpen.example\t1\t\t\t\t1\ntls\tclosed.example\t1\t\t\t\t1\ntls\tredir.example\t1\t\t\t\t1\ntls\tsame.example\t1\t\t\t\t1\ntls\tstub.example\t1\t\t\t\t1\ntls\tlate.example\t1\t\t\t\t1\ntls\tdrop.example\t1\t\t\t\t1\ntls\tpage.example\t1\t\t\t\t1\n' > "$SMART_DIR/mobile-25001.tsv"
printf 'cdn.listed.example\n' >> "$LISTS_DIR/user.list"

section "the benchmark runs every site through every variant"
ctl smart-bench start
assert_rc 1 "$ctl_rc" "it needs the smart mode running"
mkdir -p "$BENCH_DIR"
ctl smart-bench run
assert_rc 0 "$ctl_rc" "a run finishes"
res="$SMART_DIR/bench-mobile-25001.tsv"
assert_file "$res" "the results are kept next to what was learned (and go into the log export)"
assert_eq "5" "$(awk -F'\t' '$1 == 1 && $2 == "blocked.example"' "$res" | grep -c .)" "a tls site: without bypass and on each of its 4 variants"
assert_eq "4" "$(awk -F'\t' '$1 == 1 && $2 == "yt.example"' "$res" | grep -c .)" "a google site: on the 3 variants of its own profile"
assert_contains "$(awk -F'\t' '$2 == "slow.example" && $4 == 1 { print $5 }' "$res")" "16kb" "a transfer cut at 16 KB is told apart"
assert_contains "$(awk -F'\t' '$2 == "blocked.example" && $4 == 1 { print $5 }' "$res")" "tls" "a broken handshake too"
assert_eq "2" "$(awk -F'\t' '$2 == "nodns.example"' "$res" | grep -c .)" "a site without DNS is tried bare and with www., then skipped"
assert_eq "5" "$(awk -F'\t' '$1 == 1 && $2 == "listed.example"' "$res" | grep -c .)" "a site that is in the lists only by a subdomain is found under that name"
assert_contains "$(cat "$BENCH_DIR/urls")" "listed.example	cdn.listed.example" "and the name is kept for stage 2"
assert_no_file "$SMART_BENCH_FILE" "when it ends the orchestrator is let go"
assert_contains "$(cat "$STATE_DIR/bench.mark")" "6 " "while it runs the orchestrator gets its pid (stale files are ignored)"
assert_eq "3" "$(awk -F'\t' '$1 == 1 && $2 == "pen.example" && $5 == "connect"' "$res" | grep -c .)" "TCP not connecting is told apart"
assert_eq "4" "$(awk -F'\t' '$1 == 1 && $2 == "pen.example" && $4 > 0 && $5 == "ok"' "$res" | grep -c .)" "and each such variant is tried again at the end of the stage, until it connects"
assert_eq "1 2 3 4" "$(awk -F'\t' '$1 == 1 && $2 == "pen.example" && $4 > 0 && $5 == "ok" { print $4 }' "$res" | sort -n | tr '\n' ' ' | sed 's/ $//')" "every variant gets its real result"
assert_eq "" "$(awk -F'\t' '$1 == 0 && $4 != "-"' "$res")" "name probes run on the site's learned variant, not without bypass (an open SNI makes the DPI close the address)"
assert_eq "1" "$(awk -F'\t' '$1 == 1 && $2 == "closed.example" && $5 == "connect"' "$res" | grep -c .)" "a site whose name probes never connect (twice): one «no connection» line, no attempt without bypass"
assert_eq "4" "$(awk -F'\t' '$1 == 1 && $2 == "late.example" && $4 > 0' "$res" | grep -c .)" "a site whose probes did not connect at first is prepared again later and tried on every variant"
assert_eq "ok" "$(awk -F'\t' '$1 == 1 && $2 == "late.example" && $4 == 2 { print $5 }' "$res")" "with its real results"
assert_eq "hs_timeout hs_timeout hs_timeout" "$(awk -F'\t' '$1 == 1 && $2 == "drop.example" && $4 > 0 && $4 < 4 { print $5 }' "$res" | tr '\n' ' ' | sed 's/ $//')" "a ClientHello the DPI drops (curl shows it like a closed address) is told apart by a TCP check: the variant failed"
assert_eq "4" "$(awk -F'\t' '$1 == 1 && $2 == "drop.example" && $4 > 0' "$res" | grep -c .)" "and it is not retried — it is the variant's result"
assert_eq "" "$(grep -x 'other.example' "$STATE_DIR/curl.hosts")" "a redirect to another site is not followed (that connection would not run on the tested variant)"
assert_eq "ok" "$(awk -F'\t' '$1 == 1 && $2 == "redir.example" && $4 == 1 { print $5 }' "$res")" "but the site answered: the variant got through"
assert_contains "$(grep -c -x 'www.same.example' "$STATE_DIR/curl.hosts")" "" "a redirect within the site is followed"
assert_eq "30000" "$(awk -F'\t' '$1 == 1 && $2 == "same.example" && $4 == 1 { print $11 }' "$res")" "and measured to the end"
assert_eq "isp_redir" "$(awk -F'\t' '$1 == 1 && $2 == "stub.example" && $4 == 1 { print $5 }' "$res")" "a redirect to the ISP stub page is not a success"
assert_eq "isp_redir" "$(awk -F'\t' '$1 == 1 && $2 == "page.example" && $4 == 1 { print $5 }' "$res")" "nor an ISP block page served in place of the site"
assert_eq "ok" "$(awk -F'\t' '$1 == 1 && $2 == "page.example" && $4 == 2 { print $5 }' "$res")" "the site itself is"
assert_eq "blocked.example listed.example late.example blocked.example listed.example late.example" "$(awk -F'\t' '$1 == 1 && $4 > 0 { printf "%s%s", (n++ ? " " : ""), $2 }' "$BENCH_DIR/res.0" | cut -d' ' -f1-6)" "variants go round all the sites of a worker, not one site after another"
section "stage 2: the best variants again, on blocked sites they open"
assert_eq "8" "$(awk -F'\t' '$1 == 2 && $2 == "blocked.example"' "$res" | grep -c .)" "the variants that opened blocked sites (1, 2, 3, 4), twice each"
assert_eq "0" "$(awk -F'\t' '$1 == 2 && $2 == "open.example"' "$res" | grep -c .)" "a site that opens without bypass is not repeated"
assert_eq "0" "$(awk -F'\t' '$1 == 2 && $2 == "dead.example"' "$res" | grep -c .)" "nor one nothing opens"

section "the report"
ctl smart-bench report
printf '%s' "$ctl_out" > "$SANDBOX/rep.json"
node -e 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))' "$SANDBOX/rep.json" 2>/dev/null
assert_rc 0 $? "is valid JSON"
assert_contains "$ctl_out" '"fam":"tls","blocked":10,"solved":8,"unblocked":2,"unsolved":"' "per family: blocked, solved, open without bypass"
assert_contains "$ctl_out" 'dead.example' "never opened: one nothing opens"
assert_contains "$(printf '%s' "$ctl_out" | sed 's/"noconn":"closed.example"//')" 'stub.example' "and one that only ever reached the ISP stub page"
assert_contains "$ctl_out" '"noconn":"closed.example"' "a site that never connected is apart, not «never opened»"
assert_contains "$ctl_out" '{"n":1,"name":"hardcorp74: Google","tests":1,"ok":0,"ms_tls":-1,' "a variant that opened nothing blocked has no time"
assert_contains "$ctl_out" '"f16":3,"reset":3,' "how the failures ended"
assert_contains "$ctl_out" '{"n":3,"name":"MartinBacker #3","tests":26,"ok":3,' "a variant: tries and successes on blocked sites, with its name"
assert_contains "$ctl_out" '{"n":1,"name":"MartinBacker #1","tests":26,"ok":9,"ms_tls":70,"ms_ttfb":300,"uniq":3,"f16":3,"reset":3,"timeout":7,"other":4,' "a redirect to another site and within it count for the variant, the ISP stub does not"
assert_contains "$ctl_out" '"ms_tls":70,"ms_ttfb":300,"uniq":1' "median handshake and first byte, and how many sites only it opens"
assert_contains "$ctl_out" '"fam":"google","blocked":1,"solved":1' "google apart"
assert_eq "3" "$(printf '%s' "$ctl_out" | grep -o '"conn":[0-9]*' | awk -F: '{ s += $2 } END { print s }')" "tries that could not connect are counted apart, not as the variant's failures"
ctl smart-bench report text
assert_contains "$ctl_out" "нет соединения" "the text report has it too"
assert_contains "$ctl_out" "адрес закрыт — варианты тут не помогут): closed.example" "a closed address is named apart"
assert_contains "$ctl_out" "Не открылись ни на одном варианте: dead.example" "the text report names what nothing opens"
ctl smart-bench path
assert_eq "$SMART_DIR/bench-mobile-25001.txt" "$ctl_out" "a file to share"
ctl share text "$SMART_DIR/bench-mobile-25001.txt"
assert_eq "0 OK" "$ctl_rc $ctl_out" "and «Share report» may share it (it was refused: «this file cannot be shared»)"
ctl share text "$SMART_DIR/mobile-25001.tsv"
assert_rc 1 "$ctl_rc" "other files there still may not"
ctl smart-bench status
assert_contains "$ctl_out" '"running":0,"stage":"done","hosts":15,"done1":15' "status: done, all sites"

section "a killed run lets the orchestrator go too"
rm -f "$STATE_DIR/bench.mark"
BENCH_HANG=1 sh "$MODDIR/bin/nfqws2-ctl" smart-bench run >/dev/null 2>&1 &
kpid=$!
i=0; while [ ! -f "$STATE_DIR/bench.mark" ] && [ $i -lt 300 ]; do sleep 0.1; i=$((i + 1)); done
assert_contains "$(cat "$STATE_DIR/bench.mark" 2>/dev/null)" "6 " "the run is under way (workers and its pid)"
kill -TERM "$kpid"; wait "$kpid" 2>/dev/null
assert_no_file "$SMART_BENCH_FILE" "killed: the files are removed"
assert_eq "" "$(ls "$STATE_DIR"/smart_bench.[0-9]* 2>/dev/null)" "and the per-worker ones"

section "the live report while a run is going"
# идущий замер: процесс «smart-bench run» жив, данные — в res.*
sh -c 'sleep 30; :' smart-bench run >/dev/null 2>&1 & lp=$!
sleep 0.3
if tr '\0' ' ' < "/proc/$lp/cmdline" 2>/dev/null | grep -q "smart-bench run"; then
  echo "$lp" > "$BENCH_DIR/pid"
  ctl smart-bench report
  assert_contains "$ctl_out" '"noconn":"","fams"' "while it runs: no «never connected» list yet (those sites are tried again)"
  assert_not_contains "$ctl_out" 'dead.example' "nor «never opened»"
  assert_contains "$ctl_out" '"blocked":10,"solved":8' "but the counts are there"
  ctl smart-bench status
  assert_contains "$ctl_out" '"prep":15,' "status: how many sites are prepared (stage 1 starts with that)"
  rm -f "$BENCH_DIR/pid"
else
  echo "   skip live report (exec -a unsupported)"
fi
kill "$lp" 2>/dev/null

section "a stale run whose pid went to another process"
sleep 30 &
other=$!
echo "$other" > "$BENCH_DIR/pid"; echo "2 $other" > "$SMART_BENCH_FILE"; echo "x.example 0" > "$STATE_DIR/smart_bench.0"
sed -i 's/^stage=.*/stage=1/' "$BENCH_DIR/info"
ctl smart-bench status
assert_contains "$ctl_out" '"running":0' "is not taken for a running benchmark"
ctl smart-bench stop
assert_no_file "$SMART_BENCH_FILE" "stop clears what it left"
assert_no_file "$STATE_DIR/smart_bench.0" "including the per-worker files"
ctl smart-bench status
assert_contains "$ctl_out" '"stage":"done"' "and the screen no longer shows it as going"
kill "$other" 2>/dev/null

section "a benchmark set: candidates against the best old variants"
printf '#@bench-tls 2,4-9\n#@bench-google 3\n' >> "$MODDIR/strategies/smart.conf"
# как при запуске из WebUI (smart-bench start): каталог замера — с чистого листа
rm -rf "$BENCH_DIR"; mkdir -p "$BENCH_DIR"; rm -f "$SMART_DIR/bench-mobile-25001.tsv"
ctl smart-bench run
res="$SMART_DIR/bench-mobile-25001.tsv"
assert_eq "0 2 4" "$(awk -F'\t' '$1 == 1 && $2 == "blocked.example" { print $4 }' "$res" | sort -n | tr '\n' ' ' | sed 's/ $//')" "a run tries a site without bypass and on the listed variants only (a range too), those the profile has"
assert_eq "0 3" "$(awk -F'\t' '$1 == 1 && $2 == "yt.example" { print $4 }' "$res" | sort -n | tr '\n' ' ' | sed 's/ $//')" "google sites — on the google set"
assert_eq "" "$(awk -F'\t' '$1 == 2 && $4 != 2 && $4 != 4 && $4 != 3' "$res")" "stage 2 repeats only variants of the set"
sed -i '/^#@bench-/d' "$MODDIR/strategies/smart.conf"

section "the extended pool switch"
ctl set SMART_POOL 1
assert_eq "ext" "$(cat "$SMART_POOL_FILE" 2>/dev/null)" "on: the orchestrator is told at once"
ctl json-status
assert_contains "$ctl_out" '"smart_pool":1' "and the WebUI sees it"
ctl set SMART_POOL 0
assert_no_file "$SMART_POOL_FILE" "off"

harness_finish
