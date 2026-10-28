// nfqws2-helper — то, чего нет в shell на Android: будильник, который будит
// телефон из глубокого сна (alarm.go), и проверка, что dnsproxy модуля
// отвечает на запросы (probe.go).
//
//	nfqws2-helper -alarm 5m -run "sh /путь/service.sh push_beat"
//	nfqws2-helper -probe 127.0.0.1:15353[,127.0.0.1:15356]
package main

import (
	"flag"
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
	default:
		flag.Usage()
		os.Exit(2)
	}
}
