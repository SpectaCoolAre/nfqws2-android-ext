// nfqws2-helper — то, чего нет в shell на Android: будильник, который будит
// телефон из глубокого сна (alarm.go), и проверка, что dnsproxy модуля
// отвечает на запросы (probe.go).
//
//	nfqws2-helper -alarm 5m -run "sh /путь/service.sh push_beat"
//	nfqws2-helper -probe 127.0.0.1:15353[,127.0.0.1:15356]
//	nfqws2-helper -geoscan dns.comss.one,… -samples chatgpt.com,… -boot 213.87.142.94:53
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
	samples := flag.String("samples", "", "домены-образцы для -geoscan через запятую")
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
		ss := splitList(*samples)
		w := *wait
		if w < 6*time.Second {
			w = 6 * time.Second
		}
		for _, r := range geoScan(splitList(*geo), ss, *boot, w) {
			fmt.Println(formatScan(r, ss))
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
