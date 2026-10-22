-- nfqws2-android-ext: умный режим — обучаемый оркестратор (лицензия MIT)
--
-- Похож на circular из zapret-auto.lua: перед вариантами обхода с меткой
-- strategy=N стоит один вызов smart, и он решает, какой вариант применить к
-- соединению. Чем отличается:
--
--   * Счётчики. Для каждого сайта и каждого варианта — удачи и ошибки, и такие
--     же итоги по всей сети. Старые события со временем весят меньше (вдвое за
--     час): вариант, который сломался сегодня, не держится на вчерашних удачах.
--   * Ошибки видны и посреди работы, а не только в начале соединения. В начале
--     — сброс (RST), повторные отправки, редирект DPI, обрыв на ~16 КБ. Посреди
--     — наблюдатель раз в 3 секунды смотрит таблицу TCP-соединений телефона
--     (/proc/net/tcp): соединение к сайту, по которому телефон раз за разом
--     переотправляет данные без ответа, — поток режут. Это ошибка того
--     варианта, на котором шло соединение, даже если начало было удачным.
--     Застрявшее соединение модуль обрывает (state/smart_kill → iptables), и
--     приложение сразу открывает новое — уже на другом варианте.
--   * Решение — по счётчикам: вариант меняется после двух ошибок подряд или
--     когда ошибок у него стало больше удач. Новым выбирается вариант с лучшей
--     долей удач для этого сайта, а без данных о сайте — лучший в этой сети.
--     Лучший в сети вариант — стартовый для новых сайтов: общее правило
--     находится само, а сайты-исключения закрепляются за своим.
--   * Без пинг-понга и без заморозок: сломавшийся вариант «остывает» — 5 минут,
--     при повторе 10, 20… до двух часов — и всё это время выбирается только
--     при отсутствии лучшего. Сайт с ошибками никогда не замирает на месте.
--   * Без перебора при пропавшей связи: модуль сообщает, что сети нет, а когда
--     разом ломаются три сайта и не открывается ни один, — ошибки не считаются.
--   * Выученное — на диске, отдельно для каждой сети (Wi‑Fi по SSID, мобильная
--     по оператору). Новая сеть начинает с копии прежней и меняется сама.
--   * Не всякая ошибка — DPI: если сайт ломается на половине вариантов (и хотя
--     бы на четырёх), а не открылся ни на одном, — дело не в блокировке (сервер лежит, прокси
--     или само приложение). Такой сайт на 6 часов перестаёт перебираться и
--     обрываться. Наблюдатель смотрит только на соединения приложений (uid от
--     10000): системные и root-процессы — прокси, VPN, проверки модуля — не его.
--   * Сайт — домен второго уровня, а для общих зон (co.uk, com.ru, msk.ru,
--     workers.dev, github.io…) — третьего: иначе все британские сайты были бы
--     одним «co.uk».
--   * Пока идёт обучение (есть state/smart_training), вариант меняется после
--     первой же ошибки.
-- Инструкции без strategy= выполняются всегда (как у обычного профиля).
--
-- Аргументы smart:
--   slot=<имя>   набор вариантов; профили с одним slot делят выученное и должны
--                перечислять одни и те же варианты в одном порядке
--   home=<путь>  каталог модуля с данными (/data/adb/nfqws2)
--   first=N      с какого варианта начинать новый сайт, пока в сети нет
--                явного лучшего (по умолчанию 1)
--   pass=N       вариант «без обхода»: лучшим в сети не бывает и пробуется
--                последним, если сайту раньше не помогал
--   okin=N       tcp: сколько байт должно прийти, чтобы начало соединения
--                считалось удачным (17000 — дальше обрыва на 16 КБ)
--   retrans=N, udp_in=N, udp_out=N — как у стандартного детектора

SMART = SMART or {
	home = nil, net = nil, db = {}, ns = {}, nstrat = {}, conns = {},
	dirty = false, saved = 0, netcheck = 0, offline = false, training = false,
	lastok = 0, lastconn = 0, failhosts = {}, suspect_since = nil, watching = false,
	proc = { "/proc/net/tcp", "/proc/net/tcp6" }
}
local SM = SMART

local SAVE_EVERY = 20       -- сек: как часто сбрасывать выученное на диск
local NET_EVERY = 5         -- сек: как часто смотреть, не сменилась ли сеть
local MAX_HOSTS = 3000      -- больше записей на сеть не храним
local HALF = 3600           -- сек: за это время вес события падает вдвое
local COOL_BASE = 300       -- сек: первое «остывание» сломавшегося варианта
local COOL_MAX = 7200
local SWITCH_GAP = 15       -- сек: не чаще одной смены варианта у сайта
local WATCH_MS = 3000       -- наблюдатель за соединениями
local STUCK_RETRANS = 2     -- столько неудачных переотправок подряд — поток режут
local APP_UID = 10000       -- наблюдатель — только за приложениями
local NODPI_VARIANTS = 4    -- ошибки хотя бы на стольких вариантах (и на половине набора), ни одной удачи — не DPI
local NODPI_TIME = 6 * 3600

-- Общие зоны: сайт в них — на уровень глубже
local SLD2 = { co = 1, com = 1, net = 1, org = 1, gov = 1, edu = 1, ac = 1, ["or"] = 1, ne = 1, go = 1,
	ltd = 1, plc = 1, gen = 1, nic = 1, mil = 1, biz = 1, info = 1, me = 1, ["in"] = 1 }
local SHARED = { ["msk.ru"] = 1, ["spb.ru"] = 1, ["workers.dev"] = 1, ["pages.dev"] = 1, ["github.io"] = 1,
	["herokuapp.com"] = 1, ["appspot.com"] = 1, ["vercel.app"] = 1, ["netlify.app"] = 1, ["web.app"] = 1,
	["firebaseapp.com"] = 1, ["blogspot.com"] = 1, ["cloudfront.net"] = 1, ["azurewebsites.net"] = 1 }
local function shared_zone(two)
	if SHARED[two] then return true end
	local sld, tld = two:match("^([^.]+)%.([^.]+)$")
	return sld ~= nil and SLD2[sld] ~= nil and #tld == 2
end
-- Ключ сайта. Без имени — адрес, но только там, где имени и не будет
-- (mtproto и прочее): у TLS, HTTP и QUIC имя приходит с первым пакетом данных
local function site_key(desync)
	local h = desync.track and desync.track.hostname
	if not h then
		local p = desync.track and desync.track.l7proto
		if p == "tls" or p == "http" or p == "quic" then return nil end
		return host_ip(desync)
	end
	if desync.track.hostname_is_ip then return h end
	local two = dissect_nld(h, 2)
	if not two then return h end
	if shared_zone(two) then return dissect_nld(h, 3) or h end
	return two
end

local function now() return os.time() end

local function readline(path)
	local f = io.open(path, "r")
	if not f then return nil end
	local s = f:read("*l")
	f:close()
	return s
end

local function netfile(net) return SM.home .. "/smart/" .. net .. ".tsv" end

local function csv_parse(s)
	local t = {}
	if s and s ~= "" then
		for k, v in string.gmatch(s, "(%d+):([%d.]+)") do t[tonumber(k)] = tonumber(v) end
	end
	return t
end
local function csv_dump(t, prec)
	local a = {}
	for k, v in pairs(t) do
		if v >= 0.05 then a[#a + 1] = k .. ":" .. (prec and string.format("%.1f", v) or string.format("%d", v)) end
	end
	table.sort(a)
	return table.concat(a, ",")
end

-- Старение счётчиков: вдвое за HALF секунд
local function age(o, t)
	if not o.dt then o.dt = t; return end
	local dt = t - o.dt
	if dt < 60 then return end
	local k = 0.5 ^ (dt / HALF)
	for v, x in pairs(o.ok) do o.ok[v] = x * k end
	for v, x in pairs(o.err) do o.err[v] = x * k end
	o.dt = t
end
local function share(ok, err) return ((ok or 0) + 1) / ((ok or 0) + (err or 0) + 2) end

local function netstat(slot)
	local s = SM.ns[slot]
	if not s then s = { ok = {}, err = {} }; SM.ns[slot] = s end
	return s
end
local function restat()
	SM.ns = {}
	for key, r in pairs(SM.db) do
		local slot = key:match("^([^|]+)|")
		if slot then
			local s = netstat(slot)
			for v, x in pairs(r.ok) do s.ok[v] = (s.ok[v] or 0) + x end
			for v, x in pairs(r.err) do s.err[v] = (s.err[v] or 0) + x end
		end
	end
end

local function newrec(cur)
	return { cur = cur, ok = {}, err = {}, cool = {}, cooln = {}, streak = 0, sw = 0, seen = 0 }
end

local function load_net(net)
	local f = io.open(netfile(net), "r")
	if not f then return false end
	local head = f:read("*l")
	-- файлы первых тестовых сборок — другой формат: начинаем заново
	if not head or not head:find("^#v2") then f:close(); return false end
	local db = {}
	for line in f:lines() do
		local slot, host, cur, ok, err, cool, seen =
			line:match("^([^\t#]+)\t([^\t]+)\t(%d+)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t(%d+)")
		-- «co.uk» и подобные — записи прежних сборок, где общая зона была сайтом
		if slot and not shared_zone(host) then
			local r = newrec(tonumber(cur))
			r.ok, r.err, r.seen = csv_parse(ok), csv_parse(err), tonumber(seen)
			r.dt = r.seen
			for v, until_t in pairs(csv_parse(cool)) do
				if v == 0 then r.nodpi = until_t else r.cool[v] = until_t end
			end
			db[slot .. "|" .. host] = r
		end
	end
	f:close()
	SM.db = db
	return true
end

local function save()
	if not SM.home or not SM.net or SM.net == "offline" then return end
	SM.saved = now()
	if not SM.dirty then return end
	local keys = {}
	for k in pairs(SM.db) do keys[#keys + 1] = k end
	if #keys > MAX_HOSTS then
		table.sort(keys, function(a, b) return SM.db[a].seen > SM.db[b].seen end)
		for i = MAX_HOSTS + 1, #keys do SM.db[keys[i]] = nil end
		restat()
	end
	local path = netfile(SM.net)
	local f = io.open(path .. ".tmp", "w")
	if not f then DLOG_ERR("smart: cannot write " .. path); return end
	f:write("#v2 slot\thost\tcur\tok\terr\tcool\tseen\n")
	local t = now()
	for k, r in pairs(SM.db) do
		local slot, host = k:match("^([^|]+)|(.*)$")
		local cool = {}
		for v, u in pairs(r.cool) do if u > t then cool[v] = u end end
		-- «не похоже на блокировку» — до какого времени, под номером 0
		if r.nodpi and r.nodpi > t then cool[0] = r.nodpi end
		f:write(slot, "\t", host, "\t", r.cur, "\t", csv_dump(r.ok, true), "\t", csv_dump(r.err, true), "\t",
			csv_dump(cool), "\t", r.seen or 0, "\n")
	end
	f:close()
	os.rename(path .. ".tmp", path)
	SM.dirty = false
end

-- Сеть: модуль пишет её id в state/smart_net (или offline, если сети нет)
local function check_net()
	local t = now()
	if t - SM.netcheck < NET_EVERY then return end
	SM.netcheck = t
	local net = readline(SM.home .. "/state/smart_net") or "default"
	net = net:gsub("[^%w%-_.]", "_")
	if net == "" then net = "default" end
	SM.offline = (net == "offline")
	local tf = io.open(SM.home .. "/state/smart_training", "r")
	SM.training = tf ~= nil
	if tf then tf:close() end
	if SM.offline or net == SM.net then return end
	if SM.net then save() end
	local prev = SM.net
	SM.net = net
	if load_net(net) then
		DLOG("smart: network '" .. net .. "': loaded")
	else
		-- новая сеть — с копии выученного в прежней; меняется уже отдельно
		DLOG("smart: network '" .. net .. "' is new, starting from a copy of '" .. tostring(prev) .. "'")
		for _, r in pairs(SM.db) do r.cool = {}; r.cooln = {}; r.streak = 0 end
		SM.dirty = true
	end
	restat()
	SM.conns = {}
end

-- Лучший вариант в сети: самая высокая доля удач среди тех, у кого их хотя бы
-- три. Иначе — first
local function leader(slot, n, first, pass)
	local s = SM.ns[slot]
	local best, bs
	if s then
		for v = 1, n do
			if v ~= pass and (s.ok[v] or 0) >= 3 then
				local sc = share(s.ok[v], s.err[v])
				if not best or sc > bs then best, bs = v, sc end
			end
		end
	end
	if best and bs >= 0.6 then return best end
	return first
end

-- Следующий вариант для сайта: лучшая доля удач у сайта (если он на варианте
-- бывал) или в сети. Остывающие — только если других нет
local function next_strategy(slot, r, n, t, pass)
	local s = netstat(slot)
	local best, bs
	for v = 1, n do
		if v ~= r.cur then
			local net = share(s.ok[v], s.err[v])
			local seen = (r.ok[v] or 0) + (r.err[v] or 0)
			local sc = seen >= 0.5 and (0.7 * share(r.ok[v], r.err[v]) + 0.3 * net) or (net - 0.05)
			if v == pass and (r.ok[v] or 0) < 0.5 then sc = sc - 1 end
			if (r.cool[v] or 0) > t then sc = sc - 2 end
			-- при равенстве — ближайший по номеру после текущего
			sc = sc - (((v - r.cur) % n) * 0.0001)
			if not best or sc > bs then best, bs = v, sc end
		end
	end
	return best
end

-- Связь пропала или совсем плохая: несколько сайтов ломаются разом, а не
-- открывается ни один. Такие ошибки не считаются — блокировка тут ни при чём.
-- Если «всё молчит» дольше двух минут при живой сети — это уже похоже на
-- блокировку, и ошибки снова считаются
local function network_suspect(key, t)
	if SM.offline then return true end
	SM.failhosts[key] = t
	local n = 0
	for h, ft in pairs(SM.failhosts) do
		if t - ft > 30 then SM.failhosts[h] = nil else n = n + 1 end
	end
	if n >= 3 and t - SM.lastok > 30 then
		SM.suspect_since = SM.suspect_since or t
		return t - SM.suspect_since < 120
	end
	SM.suspect_since = nil
	return false
end

local function count(r, slot, field, v, d, t)
	age(r, t)
	local s = netstat(slot)
	age(s, t)
	r[field][v] = math.max(0, (r[field][v] or 0) + d)
	s[field][v] = math.max(0, (s[field][v] or 0) + d)
	SM.dirty = true
end

local function on_ok(slot, r, v, t)
	count(r, slot, "ok", v, 1, t)
	if v == r.cur then r.streak = 0; r.cooln[v] = 0 end
	SM.lastok = t
	SM.suspect_since = nil
end

-- Ошибка соединения, шедшего на варианте v. undo — до этого оно было
-- засчитано удачей (поток оборвали уже после начала)
local function on_err(slot, key, r, v, n, t, pass, undo)
	-- уже ясно, что дело не в DPI: не считаем и не перебираем
	if r.nodpi and r.nodpi > t then return end
	if network_suspect(key, t) then
		DLOG("smart: " .. key .. ": error ignored — network looks down")
		return
	end
	if undo then count(r, slot, "ok", v, -1, t) end
	count(r, slot, "err", v, 1, t)
	if v ~= r.cur then return end   -- сайт уже ушёл с этого варианта
	r.streak = (r.streak or 0) + 1
	local need = SM.training and 1 or 2
	local bad = r.streak >= need or ((r.err[v] or 0) >= 2 and (r.err[v] or 0) > (r.ok[v] or 0))
	if not bad or t - (r.sw or 0) < SWITCH_GAP then return end
	-- ошибки на многих вариантах и ни одной удачи — это не блокировка: сервер
	-- недоступен, прокси или само приложение. Перебор тут ничего не даст
	local bad_v, any_ok = 0, 0
	for x = 1, n do
		if (r.err[x] or 0) >= 0.5 then bad_v = bad_v + 1 end
		any_ok = any_ok + (r.ok[x] or 0)
	end
	if bad_v >= math.max(NODPI_VARIANTS, math.ceil(n / 2)) and any_ok < 0.5 then
		r.nodpi = t + NODPI_TIME
		r.streak = 0
		DLOG("smart: " .. key .. ": fails on " .. bad_v .. " variants, never worked — not DPI, leaving it alone for " .. NODPI_TIME .. "s")
		return
	end
	-- вариант остывает: чем чаще ломается, тем дольше
	r.cooln[v] = (r.cooln[v] or 0) + 1
	r.cool[v] = t + math.min(COOL_MAX, COOL_BASE * 2 ^ (r.cooln[v] - 1))
	local nxt = next_strategy(slot, r, n, t, pass)
	if nxt then
		DLOG("smart: " .. key .. ": " .. v .. " -> " .. nxt .. " (ok " .. string.format("%.1f", r.ok[v] or 0) ..
			", err " .. string.format("%.1f", r.err[v] or 0) .. ")")
		r.cur = nxt
	end
	r.streak = 0
	r.sw = t
end

local function count_strategies(desync)
	local n = SM.nstrat[desync.func_instance]
	if n then return n end
	n = 0
	for _, instance in pairs(desync.plan) do
		local s = tonumber(instance.arg.strategy)
		if s and s > n then n = s end
	end
	SM.nstrat[desync.func_instance] = n
	return n
end

local function detector_args(desync)
	local a = {}
	for k, v in pairs(desync.arg) do a[k] = v end
	return setmetatable({ arg = a }, { __index = desync }), a
end

-- ── Наблюдатель за соединениями ──────────────────────────────────────────
-- Адрес из /proc/net/tcp: IPv4 — 8 hex-цифр, байты задом наперёд; IPv6 — 32,
-- по четыре байта задом наперёд
local function proc_ip(h)
	if #h == 8 then
		return string.format("%d.%d.%d.%d", tonumber(h:sub(7, 8), 16), tonumber(h:sub(5, 6), 16),
			tonumber(h:sub(3, 4), 16), tonumber(h:sub(1, 2), 16))
	end
	local g = {}
	for i = 0, 3 do
		local w = h:sub(i * 8 + 1, i * 8 + 8)
		local b = w:sub(7, 8) .. w:sub(5, 6) .. w:sub(3, 4) .. w:sub(1, 2)
		g[#g + 1] = b:sub(1, 4); g[#g + 1] = b:sub(5, 8)
	end
	return table.concat(g, ":")
end

-- Соединения, по которым телефон переотправляет данные и не слышит ответа:
-- ESTABLISHED, к 443/80, таймер переотправки взведён, неудачных попыток уже
-- STUCK_RETRANS, сокет приложения (uid от APP_UID). Возвращает
-- {локальный порт = адрес сервера}
local function stuck_sockets()
	local res = {}
	for _, path in ipairs(SM.proc) do
		local f = io.open(path, "r")
		if f then
			f:read("*l")
			for line in f:lines() do
				local lp, rip, rp, st, tr, retr, uid = line:match("^%s*%d+:%s+%x+:(%x+)%s+(%x+):(%x+)%s+(%x%x)%s+%x+:%x+%s+(%x%x):%x+%s+(%x+)%s+(%d+)")
				if lp and st == "01" and tr == "01" and tonumber(retr, 16) >= STUCK_RETRANS and tonumber(uid) >= APP_UID then
					local rport = tonumber(rp, 16)
					if rport == 443 or rport == 80 then res[tonumber(lp, 16)] = proc_ip(rip) end
				end
			end
			f:close()
		end
	end
	return res
end

function smart_watch()
	local ok, err = pcall(function()
		local t = now()
		-- без трафика наблюдатель спит: таблицу читать незачем
		if t - SM.lastconn > 120 then return end
		local stuck = stuck_sockets()
		local hits, keys, nkeys = {}, {}, 0
		for lp, ip in pairs(stuck) do
			local c = SM.conns[lp]
			local cr = c and SM.db[c.key]
			if c and not c.stuck and t - c.t >= 3 and not (cr and cr.nodpi and cr.nodpi > t) then
				hits[#hits + 1] = { c = c, ip = ip, lp = lp }
				if not keys[c.key] then keys[c.key] = true; nkeys = nkeys + 1 end
			end
		end
		if #hits == 0 then return end
		-- застряло сразу у трёх и больше сайтов — это связь, а не DPI
		local network = nkeys >= 3 and t - SM.lastok > 10
		local kill = {}
		for _, h in ipairs(hits) do
			local c = h.c
			c.stuck = true
			if not network then
				local r = SM.db[c.key]
				if r then
					DLOG("smart: " .. c.key .. ": connection :" .. h.lp .. " stuck mid-stream on variant " .. c.v)
					on_err(c.slot, c.key, r, c.v, c.n, t, c.pass, c.ok)
				end
				kill[#kill + 1] = (h.ip:find(":") and "6 " or "4 ") .. h.ip .. " " .. h.lp
			end
		end
		-- застрявшие соединения модуль обрывает: приложение переподключится
		-- на новом варианте, а не будет ждать своего таймаута
		if #kill > 0 and SM.home then
			local f = io.open(SM.home .. "/state/smart_kill", "a")
			if f then f:write(table.concat(kill, "\n"), "\n"); f:close() end
		end
		-- память: соединения старше получаса забываем
		for lp, c in pairs(SM.conns) do if t - c.t > 1800 then SM.conns[lp] = nil end end
	end)
	if not ok then DLOG_ERR("smart_watch: " .. tostring(err)) end
end

local function watch_start()
	if SM.watching or not timer_set then return end
	SM.watching = true
	timer_set("smart_watch", smart_watch, WATCH_MS, false)
end

function smart(ctx, desync)
	orchestrate(ctx, desync)
	if not desync.track then
		DLOG_ERR("smart: conntrack is missing but required")
		return replay_execution_plan(desync)
	end
	if not SM.home then SM.home = desync.arg.home or "/data/adb/nfqws2" end
	local t = now()
	check_net()
	if SM.dirty and t - SM.saved >= SAVE_EVERY then save() end

	local slot = desync.arg.slot or "default"
	local host = site_key(desync)
	local n = count_strategies(desync)
	if not host or n == 0 then
		local verdict = VERDICT_PASS
		while true do
			local instance = plan_instance_pop(desync)
			if not instance then break end
			if not instance.arg.strategy or tonumber(instance.arg.strategy) == 1 then
				verdict = plan_instance_execute(desync, verdict, instance)
			end
		end
		return verdict
	end

	local key = slot .. "|" .. host
	local pass = tonumber(desync.arg.pass)
	local r = SM.db[key]
	if not r then
		r = newrec(leader(slot, n, tonumber(desync.arg.first) or 1, pass))
		SM.db[key] = r
	end
	if r.cur > n then r.cur = 1 end
	r.seen = t

	local crec = automate_conn_record(desync)
	if crec and not crec.smart then
		-- новое соединение идёт на текущем варианте сайта; его итог засчитается
		-- этому варианту, даже если сайт к тому времени перейдёт на другой
		crec.smart = { maxin = 0, tin = t, v = r.cur, key = key, slot = slot, n = n, pass = pass, t = t }
		-- прежнее соединение к этому сайту замерло на 14–17 КБ и браузер скоро
		-- открыл новое — это обрыв по объёму. Ответ, который просто уложился в
		-- эти размеры, так не выглядит: новое соединение сразу после него не нужно
		local prev = r.lastc
		if prev and not prev.done and prev.maxin >= 14000 and prev.maxin < 17000 and t - prev.tin <= 30 then
			prev.done = true
			DLOG("smart: " .. key .. ": previous connection stalled at " .. prev.maxin .. " bytes")
			on_err(slot, key, r, prev.v, n, t, pass)
		end
		r.lastc = crec.smart
		-- для наблюдателя: по локальному порту он узнает сайт и вариант
		if desync.dis.tcp and desync.outgoing then
			SM.conns[desync.dis.tcp.th_sport] = crec.smart
			SM.lastconn = t
			watch_start()
		end
	end
	local cs = crec and crec.smart
	if cs and not cs.done then
		local okin = tonumber(desync.arg.okin) or 17000
		if desync.dis.tcp and not desync.outgoing and #desync.dis.payload > 0 then
			local p = pos_get(desync, 'p')
			if p > cs.maxin then cs.maxin = p end
			cs.tin = t
		end
		local dd, a = detector_args(desync)
		a.inseq = tostring(okin)
		if standard_success_detector(dd, crec) then
			cs.done = true
			cs.ok = true
			on_ok(slot, r, cs.v, t)
		else
			a.inseq = "4096"
			if standard_failure_detector(dd, crec) then
				cs.done = true
				on_err(slot, key, r, cs.v, n, t, pass)
			end
		end
	end

	-- соединение до конца идёт на своём варианте: смена варианта сайта
	-- касается новых соединений
	local v = cs and cs.v or r.cur
	if v > n then v = r.cur end
	local verdict = VERDICT_PASS
	while true do
		local instance = plan_instance_pop(desync)
		if not instance then break end
		local s = tonumber(instance.arg.strategy)
		if not s or s == v then
			verdict = plan_instance_execute(desync, verdict, instance)
		end
	end
	return verdict
end
