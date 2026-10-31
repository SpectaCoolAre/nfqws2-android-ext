// nfqws2-helper — то, чего нет в shell на Android: будильник, который будит
// телефон из глубокого сна (alarm.go), и проверка, что dnsproxy модуля
// отвечает на запросы (probe.go).
//
//	nfqws2-helper -alarm 5m -run "sh /путь/service.sh push_beat"
//	nfqws2-helper -probe 127.0.0.1:15353[,127.0.0.1:15356]
//	nfqws2-helper -geoscan dns.comss.one,… -samples @geoblock.list -boot 213.87.142.94:53 [-asncache файл]
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
	wait := flag.Duration("wait", 3*time.Second, "сколько ждать ответа на проверку")
	geo := flag.String("geoscan", "", "DoT-серверы через запятую: доступность и покрытие геоблока (см. geoscan.go)")
	samples := flag.String("samples", "", "домены для -geoscan через запятую или @файл (строка — домен, # — комментарий)")
	asnc := flag.String("asncache", "", "файл кэша номеров AS для -geoscan")
	maxRoute := flag.Int("max", 3, "-geoscan: сколько серверов на домен")
	boot := flag.String("boot", "", "DNS сети (адрес:53) для -geoscan: эталон ответов и адреса серверов")
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
			if err := probeDNS(a, *wait); err != nil {
				log.Printf("%s: %v", a, err)
				bad = true
			}
		}
		if bad {
			os.Exit(1)
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
		res := geoScan(splitList(*geo), ss, *boot, w)
		for _, r := range res {
			fmt.Println(formatScan(r))
		}
		for _, l := range formatRoutes(res, ss, planRoutes(res, len(ss), *maxRoute)) {
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
