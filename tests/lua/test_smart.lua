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
	local desync = {
		track = track, outgoing = not opts.incoming, l7payload = "tls_client_hello",
		dis = { tcp = { th_flags = 0, th_sport = track.port, th_dport = 443 }, payload = string.rep("x", opts.len or 100) },
		arg = { slot = opts.slot or "tls", home = HOME, pass = tostring(N), first = opts.first },
		func_instance = "smart_" .. (opts.slot or "tls"), plan = plan()
	}
	smart(nil, desync)
	for _, s in ipairs(called) do if s ~= "always" then return tonumber(s) end end
	return nil
end
local function failconn(host, slot) local c = conn(host); local s = packet(c, { slot = slot }); for i = 1, 3 do packet(c, { retrans = true, slot = slot }) end; return s, c end
local function okconn(host, slot) local c = conn(host); local s = packet(c, { slot = slot }); packet(c, { incoming = true, seq = 18000, slot = slot }); return s, c end
local function rec(host, slot) return SMART.db[(slot or "tls") .. "|" .. host] end
local function later(s) clock = clock + (s or 20) end
-- строка /proc/net/tcp: соединение с локальным портом lp, застрявшее (переотправки) или нет
local function tcpline(lp, stuck, uid)
	return string.format("   1: 0200000A:%04X 012AF468:01BB 01 00000000:00000000 %s %08X  %d 0 0 1 0000000000000000 20 4 30 10 -1",
		lp, stuck and "01:00000040" or "00:00000000", stuck and 3 or 0, uid or 10123)
end
local function tcptable(lines) writefile(HOME .. "/tcp", "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n" .. table.concat(lines, "\n") .. "\n") end

writefile(HOME .. "/state/smart_net", "wifi-home\n")

section("a new site starts from the first variant and keeps it while it works")
check(okconn("a.example") == 1, "first variant applied")
check(rec("a.example").ok[1] == 1, "the success is counted")
check(okconn("a.example") == 1, "the next connection stays on it")

section("two errors in a row switch the site; one error does not")
later(); failconn("b.example")
check(rec("b.example").cur == 1, "one error: still on 1")
later(); failconn("b.example")
check(rec("b.example").cur ~= 1, "the second one switches")
local nb = rec("b.example").cur
check((rec("b.example").cool[1] or 0) > clock, "and the broken variant cools down")
check(okconn("b.example") == nb, "the new variant is applied")

section("an error between successes does not switch a good variant")
for i = 1, 4 do later(); okconn("g.example") end
later(); failconn("g.example"); later(); okconn("g.example"); later(); failconn("g.example")
check(rec("g.example").cur == 1, "errors here and there, mostly successes — stays")

section("the variant that works best in the network starts new sites")
for _, h in ipairs({ "c.example", "d.example", "e.example" }) do
	later(); failconn(h); later(); failconn(h)
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
local _, qc = failconn("r.example"); later(); failconn("r.example")
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
later(20); failconn(h); later(20); failconn(h)
check(clock - rec(h).sw < 45, "and it never freezes: errors still move it on")

section("a site that never worked on any variant is not a DPI problem")
later(400)
local dead = "dead.example"
for i = 1, 16 do okconn("alive" .. (i % 5) .. ".example"); failconn(dead); later(10) end
check((rec(dead).nodpi or 0) > clock, "after failing on every variant it is left alone")
local dv = rec(dead).cur
later(20); failconn(dead); later(20); failconn(dead)
check(rec(dead).cur == dv, "no more switching")
local _, dc = okconn(dead); later(5)
os.remove(HOME .. "/state/smart_kill")
tcptable({ tcpline(dc.port, true) }); smart_watch()
check(readall(HOME .. "/state/smart_kill") == nil, "and its stuck connections are not cut")
tcptable({ tcpline(dc.port, false) })

section("cooling grows when the same variant breaks again")
local cg = "cool.example"
okconn(cg)
local cv = rec(cg).cur
later(); failconn(cg); later(); failconn(cg)
local first_cool = rec(cg).cool[cv] - clock
rec(cg).cool[cv] = 0; rec(cg).cur = cv; rec(cg).sw = 0; rec(cg).streak = 0
later(); failconn(cg); later(); failconn(cg)
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
later(); failconn("keep.example"); later(); failconn("keep.example")
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
check(rec(ms).ok[mv] == 0 and (rec(ms).err[mv] or 0) == 1, "the stuck connection turns that success into an error")
local kill = readall(HOME .. "/state/smart_kill") or ""
check(kill:find("4 104.244.42.1 " .. m1.port, 1, true) ~= nil, "and is handed to the module to be cut (" .. kill:gsub("\n", " ") .. ")")
smart_watch()
check((rec(ms).err[mv] or 0) == 1, "the same stuck connection is counted once")
later(20); local _, m2 = okconn(ms); later(5)
tcptable({ tcpline(m2.port, true) }); smart_watch()
check(rec(ms).cur ~= mv, "a second mid-stream stall switches the variant")
tcptable({ tcpline(m2.port, false) })

section("mid-stream: only apps are watched, not root processes (proxies, the module itself)")
later(400); os.remove(HOME .. "/state/smart_kill")
local _, rc = okconn("rootproxy.example")
later(5)
tcptable({ tcpline(rc.port, true, 0) }); smart_watch()
check(next(rec("rootproxy.example").err) == nil, "a stuck root socket is not an error")
check(readall(HOME .. "/state/smart_kill") == nil, "and is not cut")
tcptable({})

section("mid-stream: stuck at three sites at once is the network, not DPI")
later(400); os.remove(HOME .. "/state/smart_kill")
local s1, s2, s3 = select(2, okconn("n1.example")), select(2, okconn("n2.example")), select(2, okconn("n3.example"))
later(15)
tcptable({ tcpline(s1.port, true), tcpline(s2.port, true), tcpline(s3.port, true) })
SMART.lastok = clock - 20
smart_watch()
check((rec("n1.example").err[rec("n1.example").cur] or 0) == 0, "no errors counted")
check(readall(HOME .. "/state/smart_kill") == nil, "nothing is cut")

section("a connection that stalls at ~16 KB is an error")
later(400)
local st = "stall.example"
okconn("alive1.example")
local t1 = conn(st); local st0 = packet(t1); packet(t1, { incoming = true, seq = 14500, len = 1400 })
later(10)
local t2 = conn(st); packet(t2); packet(t2, { incoming = true, seq = 14500, len = 1400 })
later(20)
packet(conn(st))
check(rec(st).cur ~= st0, "switched after two stalled connections")
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
check(f and f:find("^#v2") ~= nil, "the file has the v2 header")
check(f and f:find("tls\tb%.example\t" .. nb .. "\t") ~= nil, "wifi-home.tsv has b.example on its variant")
writefile(HOME .. "/state/smart_net", "mobile-25001\n")
later(6)
check(okconn("b.example") == nb, "the new network starts from the copy")
later(); failconn("b.example"); later(); failconn("b.example")
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
check(rec("keep.example") and rec("keep.example").nodpi == 9999999999, "«not DPI» survives a restart")

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

section("slots are separate")
check(okconn("b.example", "quic") == 1, "the same site in another slot starts fresh")

io.write("\n", failed == 0 and "PASS" or "FAIL", "  ", total - failed, " of ", total, " checks passed\n")
os.exit(failed == 0 and 0 or 1)
