// nfqws2-helper — то, чего нет в shell на Android: будильник, который будит
// телефон из глубокого сна (alarm.go), и проверка, что dnsproxy модуля
// отвечает на запросы (probe.go).
//
//	nfqws2-helper -alarm 5m -run "sh /путь/service.sh push_beat"
//	nfqws2-helper -probe 127.0.0.1:15353[,127.0.0.1:15356]
//	nfqws2-helper -sniprobe youtube.com -ip 142.250.74.14
//	nfqws2-helper -ttltrace -ip 142.250.74.14 -blocked quic_youtube.bin -open quic_google.bin
//	nfqws2-helper -geoscan dns.comss.one,… -samples @geoblock.list -boot 213.87.142.94:53 [-asncache файл] [-shared файл] [-groups файл]
package main

import (
	"flag"
	"fmt"
	"log"
	"os"
	"strings"
	"time"
)

func main() {
	alarm := flag.Duration("alarm", 0, "режим будильника: интервал (см. alarm.go)")
	run := flag.String("run", "", "команда будильника")
	probe := flag.String("probe", "", "адреса DNS через запятую: ответил ли каждый (см. probe.go)")
	pname := flag.String("name", "", "с -probe: спросить адрес этого имени (ответ серверов, а не самого dnsproxy)")
	wait := flag.Duration("wait", 3*time.Second, "сколько ждать ответа на проверку")
	geo := flag.String("geoscan", "", "DoT-серверы через запятую: доступность и покрытие геоблока (см. geoscan.go)")
	samples := flag.String("samples", "", "домены для -geoscan через запятую или @файл (строка — домен, # — комментарий)")
	asnc := flag.String("asncache", "", "файл кэша номеров AS для -geoscan")
	maxRoute := flag.Int("max", 3, "-geoscan: сколько серверов на домен")
	sni := flag.String("sniprobe", "", "имя сайта: режут по имени или закрыт адрес (см. sniprobe.go), с -ip")
	sniIP := flag.String("ip", "", "адрес для -sniprobe и -ttltrace")
	ttl := flag.Bool("ttltrace", false, "узлов до сервера и до фильтра (см. ttltrace.go), с -ip, -blocked, -open")
	qBlocked := flag.String("blocked", "", "-ttltrace: QUIC Initial с запрещённым именем")
	qOpen := flag.String("open", "", "-ttltrace: QUIC Initial с обычным именем")
	verify := flag.Bool("verify", false, "-geoscan: проверить сертификат по адресу прокси (частая проверка)")
	verifyHosts := flag.String("verifyhosts", "", "-geoscan: проверить ответ сайта по адресу прокси только у этих доменов (через запятую или пробел; полная проверка)")
	dohFlag := flag.Bool("doh", false, "-geoscan: только DoH (роутер ходит к серверам через https-dns-proxy)")
	shared := flag.String("shared", "", "-geoscan: файл прошлой полной проверки — её общие адреса прокси (частая проверка)")
	boot := flag.String("boot", "", "DNS сети (адрес:53) для -geoscan: эталон ответов и адреса серверов")
	groups := flag.String("groups", "", "-geoscan: файл групп сайтов — их доменам все кандидаты (см. planRoutes)")
	ask := flag.String("ask", "", "сервер обхода (имя, имя/путь): что он отвечает на домены -samples (с -boot); строка «домен<TAB>адреса»")
	ref := flag.String("ref", "", "-geoscan: честные DNS для эталона ответов через запятую (адрес:53 или https://имя); DNS сети — запасной")
	flag.Parse()
	log.SetFlags(log.Ldate | log.Ltime)
	log.SetPrefix("nfqws2-helper: ")
	switch {
	case *alarm > 0:
		runAlarm(*alarm, *run)
	case *probe != "":
		bad := false
		for _, a := range strings.Split(*probe, ",") {
			if a = strings.TrimSpace(a); a == "" {
				continue
			}
			err := error(nil)
			if *pname != "" {
				_, err = udpResolve(a, *pname, *wait)
			} else {
				err = probeDNS(a, *wait)
			}
			if err != nil {
				log.Printf("%s: %v", a, err)
				bad = true
			}
		}
		if bad {
			os.Exit(1)
		}
	case *ttl:
		runTTLTrace(*sniIP, *qBlocked, *qOpen, *wait)
	case *sni != "":
		runSniProbe(*sni, *sniIP, *wait)
	case *ask != "":
		// Какой адрес сервер даёт для домена сейчас: проверка прокси идёт по
		// нему, а не по самому частому адресу сервера — тот мог быть прокси
		// совсем других сайтов (игровой у NullsProxy), и рабочий сервер
		// вставал на паузу
		if *boot == "" || *samples == "" {
			log.Print("-ask: нужны -samples и -boot")
			os.Exit(2)
		}
		ss, err := domainList(*samples)
		if err != nil || len(ss) == 0 {
			log.Printf("-samples: %v", err)
			os.Exit(2)
		}
		w := *wait
		if w < 6*time.Second {
			w = 6 * time.Second
		}
		dohOnly = *dohFlag
		lines, err := askServer(*ask, ss, *boot, w)
		if err != nil {
			log.Printf("%s: %v", *ask, err)
		}
		for _, l := range lines {
			fmt.Println(l)
		}
	case *geo != "":
		if *boot == "" || *samples == "" {
			log.Print("-geoscan: нужны -samples и -boot")
			os.Exit(2)
		}
		ss, err := domainList(*samples)
		if err != nil || len(ss) == 0 {
			log.Printf("-samples: %v", err)
			os.Exit(2)
		}
		w := *wait
		if w < 6*time.Second {
			w = 6 * time.Second
		}
		asnCache = *asnc
		refServers = splitList(*ref)
		if *shared != "" {
			knownShare = loadShared(*shared)
		}
		verifyCerts = *verify
		verifyOnly = map[string]bool{}
		for _, h := range strings.Fields(strings.ReplaceAll(*verifyHosts, ",", " ")) {
			verifyOnly[h] = true
		}
		dohOnly = *dohFlag
		whoamiCheck = !*verify // перехват — в полной проверке
		res := geoScan(splitList(*geo), ss, *boot, w)
		for _, r := range res {
			fmt.Println(formatScan(r))
		}
		for _, l := range formatShared(res, ss) {
			fmt.Println(l)
		}
		for _, l := range formatInfo(res) {
			fmt.Println(l)
		}
		if lastWhoami != "" {
			fmt.Println(lastWhoami)
		}
		var wide []bool
		if *groups != "" {
			if wide, err = groupWide(*groups, ss); err != nil {
				log.Printf("-groups: %v", err)
			}
		}
		for _, l := range formatRoutes(res, ss, applyNetBypass(planRoutes(res, len(ss), *maxRoute, wide), lastNetBypass)) {
			fmt.Println(l)
		}
	default:
		flag.Usage()
		os.Exit(2)
	}
}

func splitList(s string) []string {
	var out []string
	for _, a := range strings.Split(s, ",") {
		if a = strings.TrimSpace(a); a != "" {
			out = append(out, a)
		}
	}
	return out
}

// domainList — домены: через запятую или @файл; без повторов, в нижнем регистре
func domainList(s string) ([]string, error) {
	items := splitList(s)
	if strings.HasPrefix(s, "@") {
		b, err := os.ReadFile(s[1:])
		if err != nil {
			return nil, err
		}
		items = nil
		for _, l := range strings.Split(string(b), "\n") {
			if i := strings.IndexByte(l, '#'); i >= 0 {
				l = l[:i]
			}
			if l = strings.TrimSpace(l); l != "" {
				items = append(items, l)
			}
		}
	}
	var out []string
	seen := make(map[string]bool)
	for _, d := range items {
		d = strings.ToLower(strings.TrimSuffix(d, "."))
		if !seen[d] {
			seen[d] = true
			out = append(out, d)
		}
	}
	return out, nil
}
