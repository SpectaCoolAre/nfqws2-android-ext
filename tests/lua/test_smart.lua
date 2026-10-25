-- Тест оркестратора умного режима (lua/zapret-smart.lua). Запускается внутри
-- самого nfqws2: --intercept=0 --lua-init=@zapret-lib.lua ... @test_smart.lua.
-- Пакеты — поддельные таблицы desync, часы — подменные, каталог — из
-- SMART_TEST_HOME, таблица TCP-соединений — свой файл вместо /proc/net/tcp.

local HOME = SMART_TEST_HOME
local clock = 1000000
os.time = function() return clock end
-- фильтры диапазонов и отсечки здесь не проверяем; таймер наблюдателя зовём сами
pos_check_range = function() return true end
cutoff_shim_check = function() return false end
timer_set = nil
-- адрес сервера у всех поддельных соединений — один (как в tcpline), если не задан
host_ip = function(d) return d.track.ip or "104.244.42.1" end
SMART.proc = { HOME .. "/tcp" }

local failed, total = 0, 0
local function check(cond, name)
	total = total + 1
	if cond then io.write("   ok   ", name, "\n")
	else failed = failed + 1; io.write("   FAIL ", name, "\n") end
end
local function section(s) io.write("\n== ", s, "\n") end
local function writefile(p, s) local f = io.open(p, "w"); f:write(s); f:close() end
local function readall(p) local f = io.open(p, "r"); if not f then return nil end; local s = f:read("*a"); f:close(); return s end

local called = {}
function tf(ctx, desync) called[#called + 1] = desync.arg.strategy or "always"; return VERDICT_PASS end

local N = 4 -- варианты 1..4, 4 — «без обхода»
local function plan()
	local p = {}
	for s = 1, N do
		p[#p + 1] = { func = "tf", func_instance = "tf_" .. s, arg = { strategy = tostring(s) }, payload_filter = "all", range = {} }
	end
	p[#p + 1] = { func = "tf", func_instance = "tf_always", arg = {}, payload_filter = "all", range = {} }
	return p
end

local port = 40000
local function conn(host)
	port = port + 1
	return { hostname = host, lua_state = {}, port = port,
		pos = { direct = { pcounter = 1, tcp = { rseq = 1, pos = 100, uppos_prev = 0 } }, reverse = {} } }
end
-- один пакет соединения через smart; вернёт вариант, что применился
local function packet(track, opts)
	opts = opts or {}
	called = {}
	local tcp = track.pos.direct.tcp
	if opts.retrans then tcp.uppos_prev, tcp.pos = 200, 100 else tcp.uppos_prev, tcp.pos = 0, 100 end
	tcp.rseq = opts.seq or 1
	if opts.incoming then tcp.pos = (opts.seq or 1) + (opts.len or 1400) end
	local desync = { target = {},
		track = track, outgoing = not opts.incoming, l7payload = "tls_client_hello",
		dis = { tcp = { th_flags = (opts.rst and TH_RST or 0) + (opts.fin and TH_FIN or 0), th_sport = track.port, th_dport = 443 }, payload = string.rep("x", opts.len or 100) },
		arg = { slot = opts.slot or "tls", home = HOME, pass = tostring(opts.pass or N), first = opts.first, base = opts.base },
		func_instance = "smart_" .. (opts.slot or "tls"), plan = (opts.plan or plan)()
	}
	if opts.outgoing then desync.outgoing = true end
	smart(nil, desync)
	for _, s in ipairs(called) do if s ~= "always" then return tonumber(s) end end
	return nil
end
local function failconn(host, slot) local c = conn(host); local s = packet(c, { slot = slot }); for i = 1, 3 do packet(c, { retrans = true, slot = slot }) end; return s, c end
local function okconn(host, slot) local c = conn(host); local s = packet(c, { slot = slot }); packet(c, { incoming = true, seq = 18000, slot = slot }); return s, c end
local function rec(host, slot) return SMART.db[(slot or "tls") .. "|" .. host] end
local function later(s) clock = clock + (s or 20) end
-- несколько неудачных соединений подряд, по одному раз в 20 секунд
local function fails(host, k, slot) for i = 1, k or 3 do later(); failconn(host, slot) end end
-- строка /proc/net/tcp: соединение с локальным портом lp, застрявшее (переотправки) или нет
local function tcpline(lp, stuck, uid)
	return string.format("   1: 0200000A:%04X 012AF468:01BB 01 00000000:00000000 %s %08X  %d 0 0 1 0000000000000000 20 4 30 10 -1",
		lp, stuck and "01:00000040" or "00:00000000", stuck and 5 or 0, uid or 10123)
end
local function tcptable(lines) writefile(HOME .. "/tcp", "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n" .. table.concat(lines, "\n") .. "\n") end

writefile(HOME .. "/state/smart_names", "tls 1 MartinBacker #1\ntls 2 MartinBacker #2\n")
writefile(HOME .. "/state/smart_net", "wifi-home\n")

section("a new site starts from the first variant and keeps it while it works")
check(okconn("a.example") == 1, "first variant applied")
check(rec("a.example").ok[1] == 1, "the success is counted")
check(okconn("a.example") == 1, "the next connection stays on it")

section("three errors in the window switch the site; one or two do not")
later(); failconn("b.example")
check(rec("b.example").cur == 1, "one error: still on 1")
later(); failconn("b.example")
check(rec("b.example").cur == 1, "two errors: still on 1")
later(); failconn("b.example")
check(rec("b.example").cur ~= 1, "the third one switches")
local nb = rec("b.example").cur
check((rec("b.example").cool[1] or 0) > clock, "and the broken variant cools down")
check(okconn("b.example") == nb, "the new variant is applied")

section("an error between successes does not switch a good variant")
for i = 1, 4 do later(); okconn("g.example") end
later(); failconn("g.example"); later(); okconn("g.example"); later(); failconn("g.example")
later(); okconn("g.example"); later(); failconn("g.example")
check(rec("g.example").cur == 1, "errors here and there, mostly successes — stays")

section("the variant that works best in the network starts new sites")
for _, h in ipairs({ "c.example", "d.example", "e.example" }) do
	fails(h)
	check(rec(h).cur == nb, h .. ": after errors goes to the variant that works for others")
	later(); okconn(h)
end
for _, h in ipairs({ "c.example", "d.example", "e.example", "b.example" }) do later(); okconn(h) end
-- у варианта 1 тоже удачи (a, g), но и ошибки у c, d, e, b
check(okconn("new.example") == nb, "a brand new site starts on the network's best")

section("the no-bypass variant is never the best and is tried last")
for i = 1, 12 do
	local h = "p" .. i .. ".example"
	SMART.db["tls|" .. h] = { cur = N, ok = { [N] = 3 }, err = {}, cool = {}, cooln = {}, streak = 0, sw = 0, seen = clock, dt = clock }
	SMART.ns.tls.ok[N] = (SMART.ns.tls.ok[N] or 0) + 3
end
check(okconn("q.example") == nb, "many sites without bypass do not make it the start")
fails("r.example")
check(rec("r.example").cur ~= N, "a failing site does not jump to no-bypass first")

section("a site that fails everywhere keeps trying, but slowly and without loops")
later(400)
local h = "flaky.example"
okconn(h)   -- однажды он открылся: значит, дело в DPI, и перебор нужен
local seenv, switches, last = {}, 0, nil
for i = 1, 24 do
	okconn("alive" .. (i % 5) .. ".example")
	failconn(h)
	later(10)
	local v = rec(h).cur
	if v ~= last then switches = switches + 1; seenv[v] = true; last = v end
end
local nseen = 0; for _ in pairs(seenv) do nseen = nseen + 1 end
check(nseen >= 3, "it tried several variants (" .. nseen .. ")")
check(switches <= 24 * 10 / 15 + 1, "no more than one switch per 15 seconds (" .. switches .. ")")
check(rec(h).nodpi == nil, "it worked once, so it is still treated as blocked")
fails(h)
check(clock - rec(h).sw < 65, "and it never freezes: errors still move it on")

section("a site that never worked on any variant is not a DPI problem")
later(400)
local dead = "dead.example"
for i = 1, 24 do okconn("alive" .. (i % 5) .. ".example"); failconn(dead); later(10) end
check((rec(dead).nodpi or 0) > clock, "after failing on every variant it is left alone")
local dv = rec(dead).cur
fails(dead)
check(rec(dead).cur == dv, "no more switching")
local _, dc = okconn(dead); later(5)
os.remove(HOME .. "/state/smart_kill")
tcptable({ tcpline(dc.port, true) }); smart_watch(); smart_watch()
check(readall(HOME .. "/state/smart_kill") == nil, "and its stuck connections are not cut")
tcptable({ tcpline(dc.port, false) })

section("cooling grows when the same variant breaks again")
local cg = "cool.example"
okconn(cg)
local cv = rec(cg).cur
fails(cg)
local first_cool = rec(cg).cool[cv] - clock
rec(cg).cool[cv] = 0; rec(cg).cur = cv; rec(cg).sw = 0; rec(cg).win = {}
fails(cg)
check(rec(cg).cool[cv] - clock > first_cool, "the second cooldown is longer")

section("everything fails at once: the network is down, errors are not counted")
later(200)
for _, x in ipairs({ "x1.example", "x2.example", "x3.example", "x4.example" }) do failconn(x); failconn(x) end
check(rec("x4.example").cur == nb and (rec("x4.example").err[nb] or 0) == 0, "the fourth silent site has no errors")
later(200); okconn("a.example")

section("the module says there is no network: nothing is counted")
later(10)
writefile(HOME .. "/state/smart_net", "offline\n")
later(6)
failconn("off.example"); later(); failconn("off.example"); later(); failconn("off.example")
check(rec("off.example").cur == nb and next(rec("off.example").err) == nil, "no errors while offline")
writefile(HOME .. "/state/smart_net", "wifi-home\n")
later(6); okconn("a.example")

section("a connection keeps its variant even after the site switches")
local kc = conn("keep.example"); local kv = packet(kc)
fails("keep.example")
check(rec("keep.example").cur ~= kv, "the site moved on")
check(packet(kc) == kv, "the old connection still goes on its own variant")

section("mid-stream: a connection that started fine and then got stuck is an error")
later(400)
local ms = "video.example"
local _, m1 = okconn(ms)
local mv = rec(ms).cur
check(rec(ms).ok[mv] == 1, "the start counted as a success")
later(5)
tcptable({ tcpline(m1.port, true), tcpline(port + 100, false) })
smart_watch()
check(next(rec(ms).err) == nil, "one look is not enough: it must still be stuck on the next check")
smart_watch()
check(rec(ms).ok[mv] == 1 and (rec(ms).err[mv] or 0) == 1, "then it is an error of that variant, and the start still counts as a success")
local kill = readall(HOME .. "/state/smart_kill") or ""
check(kill:find("4 104.244.42.1 " .. m1.port, 1, true) ~= nil, "and is handed to the module to be cut (" .. kill:gsub("\n", " ") .. ")")
smart_watch()
check((rec(ms).err[mv] or 0) == 1, "the same stuck connection is counted once")
later(20); local _, m2 = okconn(ms); later(5)
tcptable({ tcpline(m2.port, true) }); smart_watch(); smart_watch()
check(rec(ms).cur == mv, "a second mid-stream stall is not enough yet")
later(20); local _, m3 = okconn(ms); later(5)
tcptable({ tcpline(m3.port, true) }); smart_watch(); smart_watch()
check(rec(ms).cur ~= mv, "a third mid-stream stall switches the variant")
tcptable({ tcpline(m3.port, false) })

section("mid-stream: only apps are watched, not root processes (proxies, the module itself)")
later(400); os.remove(HOME .. "/state/smart_kill")
local _, rc = okconn("rootproxy.example")
later(5)
tcptable({ tcpline(rc.port, true, 0) }); smart_watch(); smart_watch()
check(next(rec("rootproxy.example").err) == nil, "a stuck root socket is not an error")
check(readall(HOME .. "/state/smart_kill") == nil, "and is not cut")
tcptable({})

section("mid-stream: stuck at three sites at once is the network, not DPI")
later(400); os.remove(HOME .. "/state/smart_kill")
local s1, s2, s3 = select(2, okconn("n1.example")), select(2, okconn("n2.example")), select(2, okconn("n3.example"))
later(15)
tcptable({ tcpline(s1.port, true), tcpline(s2.port, true), tcpline(s3.port, true) })
SMART.lastok = clock - 20
smart_watch(); smart_watch()
check((rec("n1.example").err[rec("n1.example").cur] or 0) == 0, "no errors counted")
check(readall(HOME .. "/state/smart_kill") == nil, "nothing is cut")

section("a connection that stalls at ~16 KB is an error")
later(400)
local st = "stall.example"
okconn("alive1.example")
local t1 = conn(st); local st0 = packet(t1); packet(t1, { incoming = true, seq = 14500, len = 1400 })
later(10)
local t2 = conn(st); packet(t2); packet(t2, { incoming = true, seq = 14500, len = 1400 })
later(10)
local t3 = conn(st); packet(t3); packet(t3, { incoming = true, seq = 14500, len = 1400 })
later(20)
packet(conn(st))
check(rec(st).cur ~= st0, "switched after three stalled connections")
local sm = "small.example"
local u1 = conn(sm); packet(u1); packet(u1, { incoming = true, seq = 9000, len = 1400 })
later(100)
packet(conn(sm))
check(next(rec(sm).err) == nil, "a small reply long ago is not a stall")

section("old events weigh less")
local ag = rec("g.example")
local okw = ag.ok[1]
later(3 * 3600); okconn("g.example")
check(ag.ok[1] < okw * 0.25 + 1.01, "three hours later old successes count about an eighth")

section("learned data is saved per network and a new network starts from a copy")
later(30); okconn("a.example")
local f = readall(HOME .. "/smart/wifi-home.tsv")
check(f and f:find("^#v4") ~= nil, "the file has the v4 header")
check(f and f:find("tls\tb%.example\t" .. nb .. "\t") ~= nil, "wifi-home.tsv has b.example on its variant")
writefile(HOME .. "/state/smart_net", "mobile-25001\n")
later(6)
check(okconn("b.example") == nb, "the new network starts from the copy")
fails("b.example")
local mob = rec("b.example").cur
check(mob ~= nb, "and changes on its own")
later(30); okconn("a.example")
writefile(HOME .. "/state/smart_net", "wifi-home\n")
later(6)
check(okconn("b.example") == nb, "back on Wi‑Fi the Wi‑Fi choice is still there")
writefile(HOME .. "/state/smart_net", "mobile-25001\n")
later(6); okconn("a.example")
check(rec("b.example").cur == mob, "back on mobile — the mobile one")

section("a file from an old test build is not loaded")
writefile(HOME .. "/smart/old.tsv", "# slot\thost\tcur\twins\tfails\tflips\tfreeze\tseen\ntls\tz.example\t3\t3:5\t\t0\t0\t1\n")
writefile(HOME .. "/state/smart_net", "old\n")
later(6); okconn("a.example")
check(rec("z.example") == nil, "the old format is ignored")
writefile(HOME .. "/smart/v2old.tsv", "#v2 slot\thost\tcur\tok\terr\tcool\tseen\ntls\tco.uk\t6\t\t6:9.0\t\t1\ntls\tkeep.example\t2\t2:3.0\t\t0:9999999999\t1\n")
writefile(HOME .. "/state/smart_net", "v2old\n")
later(6); okconn("a.example")
check(rec("co.uk") == nil, "a co.uk record from the previous build is dropped")
check(rec("keep.example") and rec("keep.example").nodpi == nil, "a «not DPI» mark of the previous build is dropped (it came from false stalls)")
check(rec("keep.example").everok == true, "a site with successes counts as one that opened")
later(30); okconn("a.example")
local v3 = readall(HOME .. "/smart/v2old.tsv") or ""
check(v3:find("^#v4") ~= nil, "the file is saved in the new format")
check(v3:find("keep%.example\t2\t[^\n]*\te\n") ~= nil, "with the «opened» flag")

section("mid-stream: stuck sockets to several servers at once (any app) are the network")
later(400); os.remove(HOME .. "/state/smart_kill")
local _, w1 = okconn("weak.example"); later(5)
local function tcpline_ip(lp, iphex) return tcpline(lp, true):gsub("012AF468", iphex) end
tcptable({ tcpline(w1.port, true), tcpline_ip(50001, "0101A8C0"), tcpline_ip(50002, "0201A8C0") })
smart_watch(); smart_watch()
check(next(rec("weak.example").err) == nil, "a weak signal stalls everything: no error for the site")
check(readall(HOME .. "/state/smart_kill") == nil, "and nothing is cut")
tcptable({})

section("mid-stream: a reused port of another server is not the site's connection")
later(400)
local _, pr = okconn("reuse.example"); later(5)
tcptable({ tcpline_ip(pr.port, "0101A8C0") }); smart_watch(); smart_watch()
check(next(rec("reuse.example").err) == nil, "the local port now talks to another address — ignored")
tcptable({})

section("mid-stream: IPv4 through an IPv6 socket (::ffff:a.b.c.d) is matched")
later(400)
local _, v6c = okconn("mapped.example"); later(5)
writefile(HOME .. "/tcp", "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n" ..
	string.format("   1: 0000000000000000FFFF00000200000A:%04X 0000000000000000FFFF0000012AF468:01BB 01 00000000:00000000 01:00000040 00000005  10123 0 0 1 0000000000000000 20 4 30 10 -1\n", v6c.port))
smart_watch(); smart_watch()
check((rec("mapped.example").err[rec("mapped.example").cur] or 0) >= 1 or next(rec("mapped.example").err) ~= nil, "the stall is seen")
tcptable({})

section("a site that works but stalls mid-stream on many variants is never «not DPI»")
later(400)
local yt = "youtube-like.example"
for i = 1, 12 do
	local _, yc = okconn(yt); later(5)
	tcptable({ tcpline(yc.port, true) }); smart_watch(); smart_watch(); tcptable({})
	later(20)
end
check(rec(yt).nodpi == nil, "it opened every time — mid-stream stalls never make it «not DPI»")
check(rec(yt).everok == true, "it is remembered as a site that opened")

section("«not DPI» puts the site back on its starting variant")
later(400)
local nd = "never.example"
local start_v = select(1, failconn(nd))
for i = 1, 16 do okconn("alive" .. (i % 5) .. ".example"); failconn(nd); later(10) end
check((rec(nd).nodpi or 0) > clock, "never opened, failed from the start everywhere — «not DPI»")
check(rec(nd).cur == start_v, "and it is back on the variant it started with, not the last one tried")

section("a short answer and a normal close is a success, the server's reset after it is not DPI")
later(400)
local sh = "short.example"
local c = conn(sh); packet(c); packet(c, { incoming = true, seq = 1, len = 900 })
packet(c, { fin = true })
check((rec(sh).ok[rec(sh).cur] or 0) == 1, "a 900-byte answer closed with FIN counts as a success")
packet(c, { incoming = true, rst = true, seq = 950, len = 0 })
check(next(rec(sh).err) == nil, "the reset the server answers the close with is not an error")
local c2 = conn(sh); packet(c2); packet(c2, { fin = true })
check((rec(sh).ok[rec(sh).cur] or 0) == 1, "closed without any answer — not a success")
local c3 = conn(sh); packet(c3); packet(c3, { incoming = true, rst = true, seq = 1, len = 0 })
check((rec(sh).err[rec(sh).cur] or 0) == 1, "a reset before any answer and without a close is still an error")

section("YouTube-like: many short answers and resets after close never make it «not DPI»")
later(400)
local yt2 = "yt-short.example"
for i = 1, 20 do
	local cc = conn(yt2); packet(cc); packet(cc, { incoming = true, seq = 1, len = 1200 })
	packet(cc, { fin = true }); packet(cc, { incoming = true, rst = true, seq = 1250, len = 0 })
	later(10)
end
check(next(rec(yt2).err) == nil, "no errors at all")
check(rec(yt2).nodpi == nil and rec(yt2).everok, "it is a site that opens")

section("SoundCloud-like: a working variant with rare errors stays, and the site comes back to it")
later(400)
local sc = "soundcloud-like.example"
for i = 1, 5 do
	for j = 1, 5 do later(); okconn(sc) end
	later(); failconn(sc)
end
check(rec(sc).cur == 1, "five successes to one error, over and over — it stays on 1")
later(); failconn(sc); later(); failconn(sc); later(); failconn(sc)
check(rec(sc).cur == 1, "even three errors in a row do not move a variant with a long good history")
later(); failconn(sc)
local sc2 = rec(sc).cur
check(sc2 ~= 1, "the fourth one does")
later(400)
fails(sc)
check(rec(sc).cur == 1, "when the new one breaks too, the site goes back to the one that worked, not further away")

section("an app that resets the connection after the answer — a success")
later(400)
local ar = "appreset.example"
local c1 = conn(ar); packet(c1); packet(c1, { incoming = true, seq = 1, len = 1500 })
packet(c1, { rst = true, outgoing = true })
check((rec(ar).ok[1] or 0) == 1 and next(rec(ar).err) == nil, "a 1.5 KB answer, then the app's own reset: a success")
local c2 = conn(ar); packet(c2); packet(c2, { rst = true, outgoing = true })
check((rec(ar).ok[1] or 0) == 1 and next(rec(ar).err) == nil, "the app gave up before any answer: neither")

section("a server reset after its answer is not DPI")
later(30)
local sr = "srvreset.example"
local c3 = conn(sr); packet(c3); packet(c3, { incoming = true, seq = 1, len = 1233 })
packet(c3, { incoming = true, rst = true, seq = 1240, len = 0 })
check(next(rec(sr).err) == nil, "a reset after 1.2 KB of the server's answer is not an error")

section("keep-alive: an answered connection that stays alive is a success")
later(400)
local ka = "keepalive.example"
local kc1 = conn(ka); packet(kc1); packet(kc1, { incoming = true, seq = 1, len = 900 })
check(next(rec(ka).ok) == nil, "900 bytes and still open: not yet")
tcptable({ tcpline(kc1.port, false) })
later(10); smart_watch()
check(next(rec(ka).ok) == nil, "10 seconds later: not yet")
later(25); smart_watch()
check((rec(ka).ok[1] or 0) == 1, "alive half a minute without getting stuck: a success")
tcptable({})

section("a connection that works for minutes weighs more than a short error")
later(400)
local lw = "longwork.example"
local _, lc = okconn(lw)
tcptable({ tcpline(lc.port, false) })
for i = 1, 8 do later(60); smart_watch() end
tcptable({})
local lv = rec(lw).cur
check(math.abs((rec(lw).ok[lv] or 0) - 4) < 0.3, "one connection that worked 8 minutes counts as four successes (" .. string.format("%.2f", rec(lw).ok[lv] or 0) .. ")")
fails(lw)
check(rec(lw).cur == lv, "three short errors after it do not move the site")

section("the watcher does not count a failed connection twice")
later(400); os.remove(HOME .. "/state/smart_kill")
local dw = "double.example"
okconn(dw); okconn(dw)
local dv = rec(dw).cur
local _, dfc = failconn(dw)
check((rec(dw).err[dv] or 0) == 1, "the retransmissions are one error")
later(5)
tcptable({ tcpline(dfc.port, true) }); smart_watch(); smart_watch()
check((rec(dw).err[dv] or 0) == 1, "the watcher sees it stuck and does not add a second")
check((readall(HOME .. "/state/smart_kill") or ""):find(" " .. dfc.port, 1, true) ~= nil, "but still cuts it so the app reconnects")
tcptable({})

section("stuck before any answer is an error of the start, not mid-stream")
later(400)
local sb = "stuckbefore.example"
local sbc = conn(sb); local sbv = packet(sbc)
later(5)
tcptable({ tcpline(sbc.port, true) }); smart_watch(); smart_watch()
check((rec(sb).err[sbv] or 0) == 1 and rec(sb).early[sbv], "one error, marked as an error of the start")
tcptable({})

section("tuning: a variant that worked and broke is first tried with another parameter")
later(400)
-- набор с настоящими именами функций: подстраиваются только их параметры
local got = {}
local function rec_args(name) return function(ctx, desync) got[#got + 1] = name .. ":" .. (desync.arg.blob or "") .. ":" .. (desync.arg.repeats or "") .. ":" .. (desync.arg.tls_mod or "") .. ":" .. (desync.arg.pos or ""); return VERDICT_PASS end end
local real_fake, real_ms = fake, multisplit
fake, multisplit = rec_args("fake"), rec_args("multisplit")
local function mplan()
	return {
		{ func = "fake", func_instance = "fake_1", arg = { blob = "tls_google", repeats = "2", tls_mod = "rnd,dupsid,sni=www.google.com", strategy = "1" }, payload_filter = "all", range = {} },
		{ func = "multisplit", func_instance = "multisplit_2", arg = { pos = "1,midsld", strategy = "1" }, payload_filter = "all", range = {} },
		{ func = "fake", func_instance = "fake_3", arg = { blob = "stun", repeats = "6", strategy = "2" }, payload_filter = "all", range = {} },
		{ func = "tf", func_instance = "tf_3", arg = { strategy = "3" }, payload_filter = "all", range = {} },
	}
end
local MO = { slot = "mt", plan = mplan, pass = 3 }
local function mok(h) local c = conn(h); packet(c, MO); packet(c, { incoming = true, seq = 18000, slot = "mt", plan = mplan, pass = 3 }); return c end
local function mfail(h) local c = conn(h); packet(c, MO); for i = 1, 3 do packet(c, { retrans = true, slot = "mt", plan = mplan, pass = 3 }) end; return c end
local mh = "tune.example"
got = {}; mok(mh)
check(got[1] == "fake:tls_google:2:rnd,dupsid,sni=www.google.com:" and got[2] == "multisplit::::1,midsld", "the author's variant runs as written (" .. tostring(got[1]) .. ")")
for i = 1, 3 do later(); mok(mh) end
for i = 1, 5 do later(); mfail(mh) end
local mid = rec(mh, "mt").cur
check(mid > 100 and SMART.mut.mt[mid] and SMART.mut.mt[mid].base == 1, "it moved to a tuned variant of the same one (" .. mid .. ")")
check(#SMART.mut.mt[mid].ch == 1, "with exactly one parameter changed")
later(); got = {}; mok(mh)
local diff = 0
if got[1] ~= "fake:tls_google:2:rnd,dupsid,sni=www.google.com:" then diff = diff + 1 end
if got[2] ~= "multisplit::::1,midsld" then diff = diff + 1 end
check(#got >= 2 and diff == 1, "the tuned variant runs the same blocks with one value changed (" .. table.concat(got, " | ") .. ")")
check((rec(mh, "mt").ok[mid] or 0) == 1, "its success is its own")
-- проба отладочного замера на сайте с подстроенным вариантом: он и работает,
-- а не «без обхода» (номер подстройки больше числа вариантов профиля)
writefile(HOME .. "/state/smart_bench", "1 1\n"); writefile(HOME .. "/state/smart_bench.0", mh .. " - " .. clock .. "\n")
later(6); got = {}; mok(mh)
check(#got >= 2, "a benchmark name probe on a tuned variant runs that variant, not without bypass (" .. #got .. " blocks)")
os.remove(HOME .. "/state/smart_bench"); os.remove(HOME .. "/state/smart_bench.0"); later(6)
later(30); okconn("a.example")
local mf = readall(HOME .. "/smart/" .. (readall(HOME .. "/state/smart_net") or ""):gsub("%s+$", "") .. ".tsv") or ""
check(mf:find("\n#m\tmt\t" .. mid .. "\t1\t") ~= nil, "it is saved with the network")
local here = (readall(HOME .. "/state/smart_net") or ""):gsub("%s+$", "")
writefile(HOME .. "/state/smart_net", "wifi-elsewhere\n"); later(6); okconn("a.example")
SMART.mut.mt = nil
writefile(HOME .. "/state/smart_net", here .. "\n"); later(6); okconn("a.example")
check(SMART.mut.mt and SMART.mut.mt[mid] and SMART.mut.mt[mid].base == 1 and #SMART.mut.mt[mid].ch == 1, "and loaded back with it")
check(rec(mh, "mt").cur == mid, "the site is still on it")
-- другой сайт, у которого вариант 1 тоже сломался, может взять уже удачную подстройку
local mh2 = "tune2.example"
for i = 1, 3 do later(); mok(mh2) end
SMART.mutt.mt = clock + 3600 -- новых подстроек не делать: есть удачная
for i = 1, 5 do later(); mfail(mh2) end
check(rec(mh2, "mt").cur == mid, "another site whose variant broke picks up the tuning that already helped")
-- неудачная и никем не используемая подстройка через час удаляется
SMART.mut.mt[999] = { base = 2, ch = { { i = 1, k = "repeats", val = "8" } }, t = clock }
later(3700); okconn("a.example"); SMART.dirty = true; later(30); okconn("a.example")
check(SMART.mut.mt[999] == nil and SMART.mut.mt[mid] ~= nil, "a tuning that helped nobody is removed after an hour, a good one stays")
fake, multisplit = real_fake, real_ms

section("shared zones: every co.uk site is its own site")
later(30)
okconn("kws2.ebally.co.uk"); okconn("www.bbc.co.uk")
check(rec("ebally.co.uk") ~= nil and rec("bbc.co.uk") ~= nil, "ebally.co.uk and bbc.co.uk, not one co.uk")
check(rec("co.uk") == nil, "there is no co.uk record")
okconn("foo.workers.dev")
check(rec("foo.workers.dev") ~= nil, "workers.dev sites are separate too")
check(rec("example") == nil and rec("a.example") ~= nil, "ordinary domains are still second level")

section("no hostname yet: a TLS connection is not recorded, mtproto goes by address")
local nh = conn(nil); nh.l7proto = "tls"
local before_n = 0; for _ in pairs(SMART.db) do before_n = before_n + 1 end
packet(nh)
local after_n = 0; for _ in pairs(SMART.db) do after_n = after_n + 1 end
check(after_n == before_n, "no record for a TLS connection without a name")
local mt = conn(nil); mt.l7proto = "mtproto"
host_ip = function() return "149.154.167.51" end
packet(mt)
check(rec("149.154.167.51") ~= nil, "mtproto has no name and is keyed by address")

section("the journal tells what smart mode decided")
local jr = readall(HOME .. "/logs/smart.log") or ""
check(jr:find("b.example: MartinBacker #1 → MartinBacker #2", 1, true) ~= nil, "a switch is in the journal, with variant names")
check(jr:find("подстройк", 1, true) ~= nil, "so is tuning")
check(jr:find("не похоже на блокировку", 1, true) ~= nil, "and «not DPI»")
check(jr:find("застряло", 1, true) ~= nil, "and cut connections")

section("strategies mode: the statistics observer only counts")
do
	local function sp(track, opts)
		opts = opts or {}
		local tcp = track.pos.direct.tcp
		if opts.retrans then tcp.uppos_prev, tcp.pos = 200, 100 else tcp.uppos_prev, tcp.pos = 0, 100 end
		tcp.rseq = opts.seq or 1
		if opts.incoming then tcp.pos = (opts.seq or 1) + (opts.len or 1400) end
		local desync = { track = track, outgoing = not opts.incoming, l7payload = "tls_client_hello",
			dis = { tcp = { th_flags = (opts.rst and TH_RST or 0) + (opts.fin and TH_FIN or 0), th_sport = track.port, th_dport = 443 }, payload = string.rep("x", opts.len or 100) },
			arg = { home = HOME, name = "alt2" }, func_instance = "smartstat_1" }
		return smartstat(nil, desync)
	end
	SMART_STAT.name = nil
	local c1 = conn("a.example"); sp(c1); local v = sp(c1, { incoming = true, seq = 18000 })
	check(v == nil, "it returns no verdict: packets pass as the strategy decides")
	local c2 = conn("b.example"); sp(c2); for i = 1, 3 do sp(c2, { retrans = true }) end
	local c3 = conn("c.example"); sp(c3); sp(c3, { incoming = true, seq = 1, len = 900 }); sp(c3, { fin = true })
	local c4 = conn("d.example"); sp(c4); sp(c4, { incoming = true, rst = true, seq = 1, len = 0 })
	check(SMART_STAT.ok == 2 and SMART_STAT.err == 2, "successes and errors are counted (" .. SMART_STAT.ok .. "/" .. SMART_STAT.err .. ")")
	sp(c1, { incoming = true, seq = 30000 })
	check(SMART_STAT.ok == 2, "a decided connection is not counted again")
	later(30); local c5 = conn("e.example"); sp(c5); sp(c5, { incoming = true, seq = 18000 })
	later(30); sp(conn("f.example"))   -- сохраняется не чаще раза в 20 с, на следующем пакете
	local sf = readall(HOME .. "/state/strat_stat") or ""
	check(sf:find("^alt2\t3\t2\t") ~= nil, "and saved per strategy (" .. sf:gsub("\n", " ") .. ")")
end

section("the extended pool joins the search only when enabled")
do
	local function run(h)
		local seen = {}
		-- сайт хоть раз открылся — ошибки дальше не принимаются за «не DPI»
		local c0 = conn(h); packet(c0, { slot = "pool", base = 2, pass = 9 }); packet(c0, { incoming = true, seq = 18000, slot = "pool", base = 2, pass = 9 })
		for i = 1, 10 do
			later(); local c = conn(h); local v = packet(c, { slot = "pool", base = 2, pass = 9 })
			seen[v or 0] = true
			for k = 1, 3 do packet(c, { retrans = true, slot = "pool", base = 2, pass = 9 }) end
			okconn("anchor.example")   -- связь есть: ошибки — не от сети
		end
		return seen
	end
	local s1 = run("pool1.example")
	check(s1[1] and s1[2] and not s1[3] and not s1[4], "off: only the base set (1–2) is tried")
	writefile(HOME .. "/state/smart_pool", "ext\n"); later(6)
	local s2 = run("pool2.example")
	check(s2[3] or s2[4], "on: variants past the base set are tried too")
	os.remove(HOME .. "/state/smart_pool"); later(6)
	-- набор — список номеров: варианта 2 в нём нет, хотя он «внутри» диапазона
	local seen = {}
	local c0 = conn("pool3.example"); packet(c0, { slot = "pool3", base = "1,3-4", pass = 9 }); packet(c0, { incoming = true, seq = 18000, slot = "pool3", base = "1,3-4", pass = 9 })
	for i = 1, 10 do
		later(); local c = conn("pool3.example"); local v = packet(c, { slot = "pool3", base = "1,3-4", pass = 9 }); seen[v or 0] = true
		for k = 1, 3 do packet(c, { retrans = true, slot = "pool3", base = "1,3-4", pass = 9 }) end
		okconn("anchor.example")
	end
	check(seen[1] and seen[3] and not seen[2], "a list: only its numbers are tried (1, 3, 4 — not 2)")
	later(); local v = packet(conn("pool2.example"), { slot = "pool", base = 2, pass = 9 })
	check(v == 1 or v == 2, "off again: a site sitting on a pool variant goes back to the base set (" .. tostring(v) .. ")")
end

section("debug benchmark: the variant is forced and nothing is learned")
do
	-- замер оборвался: файлы остались — сайт на обычном обучении
	writefile(HOME .. "/state/smart_bench", "2 12345\n")
	writefile(HOME .. "/state/smart_bench.1", "bench.example 0\n")
	later(6)
	check(packet(conn("bench.example")) ~= nil, "a record without time (an older version) is ignored")
	writefile(HOME .. "/state/smart_bench.1", "bench.example 0 " .. (clock - 120) .. "\n")
	check(packet(conn("bench.example")) ~= nil, "a record older than a minute (the benchmark died) is ignored")
	local function bw(v) writefile(HOME .. "/state/smart_bench.1", "bench.example " .. v .. " " .. clock .. "\n") end
	bw(3)
	local c = conn("www.bench.example")
	check(packet(c) == 3, "the connection runs on the variant the benchmark asked for")
	for i = 1, 3 do packet(c, { retrans = true }) end
	local r = rec("bench.example")
	check(not r or ((r.err[3] or 0) == 0 and (r.ok[3] or 0) == 0), "its failure is not learned")
	local seen = readall(HOME .. "/state/smart_bench.seen") or ""
	check(seen:find("bench.example\ttls\t4\t3", 1, true) ~= nil, "the profile it landed in is reported (" .. seen:gsub("\n", " ") .. ")")
	bw(0)
	called = {}
	check(packet(conn("bench.example")) == nil and called[1] == "always", "variant 0: no bypass, only the common instances")
	bw(99)
	check(packet(conn("bench.example")) == nil, "a variant this profile does not have: no bypass")
	local cur = rec("bench.example") and rec("bench.example").cur
	bw("-")
	local pv = packet(conn("bench.example"))
	check(pv ~= nil and pv == cur, "a name probe («-»): the site's learned variant, not without bypass (" .. tostring(pv) .. ")")
	check((readall(HOME .. "/state/smart_bench.seen") or ""):find("bench.example\ttls\t4\t" .. tostring(cur), 1, true) ~= nil, "and its profile is reported")
	check(okconn("other.example") ~= nil, "other sites are not touched")
	os.remove(HOME .. "/state/smart_bench"); later(6)
	local v = packet(conn("bench.example"))
	check(v ~= nil, "benchmark over: the site is handled by the smart mode again")
end

section("slots are separate")
check(okconn("b.example", "quic") == 1, "the same site in another slot starts fresh")

io.write("\n", failed == 0 and "PASS" or "FAIL", "  ", total - failed, " of ", total, " checks passed\n")
os.exit(failed == 0 and 0 or 1)
