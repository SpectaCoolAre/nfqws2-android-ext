-- lua/zapret-nzvideo.lua (шаг nz_first2 из NetZapret) в обычном LuaJIT, без
-- nfqws2: то, что движок даёт скриптам (u8/bu8, отсечка экземпляра, часы,
-- таймер, отправка) — заглушки ниже. Запускает tests/module/test_smart.sh.
-- Проверяется то, на что опирается модуль: малое окно только после среза,
-- множитель окна убирается (или занижается в тяжёлом режиме), окно каждого
-- пакета пересчитывается обратно, шаг по имени — только для своих имён
local pass, fail = 0, 0
local function check(cond, what)
	if cond then pass = pass + 1; print("   ok   " .. what)
	else fail = fail + 1; print("   FAIL " .. what) end
end
local function section(name) print("== " .. name) end

TCP_KIND_SCALE = 3
u8 = function(s) return string.byte(s, 1) end
bu8 = function(n) return string.char(n) end
local cut = {}
instance_cutoff = function(ctx, dir) cut[#cut + 1] = dir == nil and "both" or tostring(dir) end
local fclock = 1000
clock_getfloattime = function() return fclock end
local timers = {}
timer_set = function(name, fn, ms, once, data) timers[#timers + 1] = { name = name, fn = fn, ms = ms, data = data } end
desync_timer_name = function(d) return "t" .. tostring(d.func_instance) end
local sent = {}
rawsend_dissect = function(dis, opts) sent[#sent + 1] = { dis = dis, opts = opts } end
dis_reverse = function(d) d.reversed = true end
ntop = function(ip) return ip end

dofile("zapret-nzvideo.lua")

local CTX = {}
-- соединение: track с состоянием, позиция сервера (seq0) для подтверждений
local function conn(ip, host)
	return { lua_state = {}, hostname = host, pos = { server = { tcp = { seq0 = 5000 } } }, ip = ip }
end
local function cutall() for _, x in ipairs(cut) do if x == "both" then return true end end return false end
local function packet(c, o)
	o = o or {}
	local tcp = { th_flags = o.flags or TH_ACK, th_win = o.win or 1000, th_ack = o.ack or 5001, options = o.options }
	local d = {
		dis = { tcp = tcp, ip = { ip_dst = c.ip }, payload = o.payload or "" },
		track = c, arg = o.arg or {}, outgoing = true, func_instance = "nz", ifin = "rmnet0",
	}
	cut = {}
	local v = nz_first2(CTX, d)
	return v, tcp, d
end
local function syn(c, arg, scale)
	return packet(c, { flags = TH_SYN, win = 65535, options = { { kind = TCP_KIND_SCALE, data = bu8(scale or 7) } }, arg = arg })
end
local function has_scale(tcp)
	for _, o in ipairs(tcp.options or {}) do if o.kind == TCP_KIND_SCALE then return u8(o.data) end end
	return nil
end
local IP = "\74\125\8\33"     -- 74.125.8.33, группа 74.125.8.32/28

section("an ordinary connection to a video node is only watched")
do
	local c = conn(IP, "rr1---sn-abc.googlevideo.com")
	local v, tcp = syn(c, { syn = true, far = "35" })
	check(v == nil and has_scale(tcp) == 7, "the first SYN to a group is left as is")
	check(c.lua_state.nz_first2 == "watch", "and the connection is watched")
	fclock = fclock + 0.04
	local v2, t2 = packet(c, { payload = "CH", arg = { reset = true, far = "35" } })
	check(v2 == nil and t2.th_win == 1000, "its ClientHello keeps the window")
	check(#timers == 1 and timers[1].ms == 1000, "a reset timer is armed for 1 s")
	packet(c, { ack = 5100, arg = { reset = true, far = "35" } })
	check(c.lua_state.nz_first2_data_seen, "the server answered: the connection is fine")
end

section("a cut answer gives the group a small window")
do
	timers = {}
	local c = conn(IP, "rr1---sn-abc.googlevideo.com")
	syn(c, { syn = true })
	packet(c, { payload = "CH", arg = {} })
	-- ответа нет; через 3 с — новое соединение к той же группе
	local now0 = os.time
	os.time = function() return now0() + 3 end
	local c2 = conn("\74\125\8\40", "rr2---sn-abc.googlevideo.com")
	local v, tcp = syn(c2, { syn = true })
	check(c2.lua_state.nz_first2 == "small", "the next connection to the group (another address in it) gets the small window")
	check(v == VERDICT_MODIFY and has_scale(tcp) == nil, "its SYN goes without the window scale option")
	local v2, t2 = packet(c2, { payload = "CH", arg = {} })
	check(v2 == VERDICT_MODIFY and t2.th_win == 2, "its ClientHello says the window is 2 bytes")
	os.time = now0
end

section("heavy mode: the scale is lowered and every window is scaled back")
do
	local c = conn("\173\194\1\1", "rr3---sn-xyz.googlevideo.com")
	local v, tcp = syn(c, { syn = true, always = true, scale = "1" }, 7)
	check(v == VERDICT_MODIFY and has_scale(tcp) == 1, "SYN: scale 7 is lowered to 1")
	check(c.lua_state.nz_first2_shift == 6 and c.lua_state.nz_first2_first == 1, "the shift is 6, the first window 1 (2 bytes at scale 1)")
	local _, t1 = packet(c, { payload = "CH", arg = { ramp = true } })
	check(t1.th_win == 1, "before the answer: window 1")
	local _, t2 = packet(c, { ack = 6000, win = 500, arg = { ramp = true } })
	check(t2.th_win == 32000, "after it every window is the phone's one times 64 (500 -> 32000)")
	local _, t3 = packet(c, { ack = 9000, win = 4000, arg = { ramp = true } })
	check(t3.th_win == 65535, "and never more than 65535")
	local o = conn("\173\194\1\2", "rr4---sn-xyz.googlevideo.com")
	o.lua_state.nz_first2 = "watch"
	local vo, to = packet(o, { ack = 6000, win = 500, arg = { ramp = true } })
	check(vo == nil and to.th_win == 500 and cutall(), "an ordinary connection is not touched by the ramp step, and it switches itself off")
end

section("the name step is only for its names (module argument hosts)")
do
	local c = conn("\142\250\1\1", "www.google.com")
	c.lua_state.nz_first2 = "small"
	local v, tcp = packet(c, { payload = "CH", arg = { reset = true, hosts = "googlevideo.com,youtube.com" } })
	check(v == nil and tcp.th_win == 1000 and cutall(), "www.google.com: no window change, the step switches itself off")
	local y = conn("\142\250\1\2", "www.youtube.com")
	y.lua_state.nz_first2 = "small"
	local vy, ty = packet(y, { payload = "CH", arg = { reset = true, hosts = "googlevideo.com,youtube.com" } })
	check(vy == VERDICT_MODIFY and ty.th_win == 2, "www.youtube.com: a subdomain of a listed name gets the small window")
	local z = conn("\142\250\1\3", "notyoutube.com")
	z.lua_state.nz_first2 = "small"
	local vz = packet(z, { payload = "CH", arg = { hosts = "youtube.com" } })
	check(vz == nil, "notyoutube.com is not youtube.com")
end

print(string.rep("-", 40))
if fail == 0 then print("PASS  " .. pass .. " of " .. pass .. " checks passed")
else print("FAIL  " .. pass .. " of " .. (pass + fail) .. " checks passed") end
