-- Запуск tests/lua/test_smart.lua в обычном LuaJIT, без бинарника nfqws2
-- (tests/module/test_smart.sh, когда NFQWS2_TEST_BIN не задан). Здесь — только
-- то, что nfqws2 даёт скриптам сам и что нужно оркестратору: битовые
-- операции, журнал, pid и часы для зерна случайных чисел, сложение по модулю
-- 2^32. Всё остальное — настоящие zapret-lib/auto/smart.lua
NFQWS2_COMPAT_VER = 6
local bit = require("bit")
bitand, bitor, bitxor, bitnot = bit.band, bit.bor, bit.bxor, bit.bnot
bitlshift, bitrshift = bit.lshift, bit.rshift
DLOG = function() end
DLOG_ERR = function() end
DLOG_CONDUP = function() end
TH_FIN, TH_SYN, TH_RST, TH_PUSH, TH_ACK, TH_URG = 1, 2, 4, 8, 16, 32
VERDICT_PASS, VERDICT_MODIFY, VERDICT_DROP = 0, 1, 2
VERDICT_MASK, VERDICT_PRESERVE_NEXT = 3, 4
HEXDUMP_DLOG_MAX = 32
getpid = function() return 1 end
gettid = function() return 1 end
clock_gettime = function() return os.time(), 0 end
u32add = function(...) local s = 0; for _, x in ipairs({ ... }) do s = s + x end; return s % 4294967296 end
