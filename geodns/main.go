// geodns — арбитр DNS модуля nfqws2-android-ext: обход геоблока без списков.
// Быстрый маршрут — dnsproxy модуля (его профили, CDN и кэш); провайдеры с
// обходом (comss, GeoHide, malw…) спрашиваются параллельно, и домен уходит в
// обход, только если провайдер ответил адресом своего прокси.
//
//	geodns -listen 127.0.0.1:15353 -fast 127.0.0.1:15356 -providers файл \
//	       -never файл[,файл] -always файл -canary chatgpt.com,claude.ai -status файл
//
// Файл провайдеров: строка на провайдера — «имя адрес адрес …», адрес —
// https://… (DoH) или IP[:порт] обычного DNS.
package main

import (
	"bufio"
	"flag"
	"io"
	"log"
	"net"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"
)

func main() {
	listen := flag.String("listen", "127.0.0.1:15353", "адреса через запятую")
	fast := flag.String("fast", "127.0.0.1:15356", "быстрый маршрут (dnsproxy модуля)")
	provFile := flag.String("providers", "", "файл провайдеров с обходом")
	never := flag.String("never", "", "списки «никогда в обход», через запятую")
	always := flag.String("always", "", "список «всегда в обход»")
	canary := flag.String("canary", "chatgpt.com,claude.ai,gemini.google.com,copilot.microsoft.com,www.notion.so,spotify.com", "сервисы с геоблоком для проверки провайдеров")
	status := flag.String("status", "", "файл состояния (JSON) для WebUI")
	state := flag.String("state", "", "файл узнанного (адреса прокси, решения) между перезапусками")
	wait := flag.Duration("wait", 1500*time.Millisecond, "сколько ждать провайдеров")
	timeout := flag.Duration("timeout", 5*time.Second, "ответ быстрого маршрута")
	flag.Parse()
	log.SetFlags(log.Ldate | log.Ltime)
	log.SetPrefix("geodns: ")

	fastUp := &plainUpstream{addr: *fast}
	provs := loadProviders(*provFile, *fast)
	a := &Arbiter{
		Fast: fastUp, Providers: provs,
		Never: LoadSuffixes(strings.Split(*never, ",")...), Always: LoadSuffixes(*always),
		Canaries: splitList(*canary), Wait: *wait, Timeout: *timeout,
		cache: map[string]decision{},
	}
	names := []string{}
	for _, p := range provs {
		if p.Reserve {
			names = append(names, p.Name+" (запасной)")
		} else {
			names = append(names, p.Name)
		}
	}
	log.Printf("старт: быстрый маршрут %s, обход геоблока: %s", *fast, strings.Join(names, ", "))
	if *state != "" {
		if np, nd := a.LoadState(*state); np+nd > 0 {
			log.Printf("узнанное до перезапуска: адресов прокси %d, решений по доменам %d", np, nd)
		}
	}

	for _, addr := range splitList(*listen) {
		if err := serveUDP(addr, a); err != nil {
			log.Fatalf("не слушается %s: %v", addr, err)
		}
		if err := serveTCP(addr, a); err != nil {
			log.Printf("TCP %s: %v", addr, err)
		}
	}

	// канарейки: сразу, потом раз в 30 минут; пока кто-то не готов или
	// молчит — раз в 2 минуты
	go func() {
		time.Sleep(time.Second)
		for {
			a.CheckCanaries()
			next := 30 * time.Minute
			for _, p := range provs {
				p.mu.Lock()
				empty := len(p.proxy) == 0 || p.fails >= downAfter
				p.mu.Unlock()
				if empty && a.InUse(p) {
					next = 2 * time.Minute
				}
			}
			time.Sleep(next)
		}
	}()
	go func() {
		for n := 1; ; n++ {
			if *status != "" {
				tmp := *status + ".tmp"
				if os.WriteFile(tmp, []byte(a.Status()), 0644) == nil {
					os.Rename(tmp, *status)
				}
			}
			if *state != "" && n%6 == 0 {
				a.SaveState(*state)
			}
			time.Sleep(10 * time.Second)
		}
	}()
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGTERM, syscall.SIGINT)
	<-sig
	if *state != "" {
		a.SaveState(*state)
	}
	log.Printf("остановлен")
}

func splitList(s string) []string {
	var out []string
	for _, x := range strings.Split(s, ",") {
		if x = strings.TrimSpace(x); x != "" {
			out = append(out, x)
		}
	}
	return out
}

func loadProviders(path, resolver string) []*Provider {
	var out []*Provider
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		fs := strings.Fields(sc.Text())
		if len(fs) < 2 || strings.HasPrefix(fs[0], "#") {
			continue
		}
		var ups []Upstream
		var claims *Suffixes
		for _, s := range fs[1:] {
			if strings.HasPrefix(s, "@") { // «@файл» — собственный список доменов провайдера
				claims = LoadSuffixes(s[1:])
				continue
			}
			u, err := parseUpstream(s, resolver)
			if err != nil {
				log.Printf("%s: %v — пропущен", fs[0], err)
				continue
			}
			ups = append(ups, u)
		}
		if len(ups) > 0 {
			// «+имя» — запасной провайдер
			p := NewProvider(strings.TrimPrefix(fs[0], "+"), ups)
			p.Reserve = strings.HasPrefix(fs[0], "+")
			p.Claims = claims
			out = append(out, p)
		}
	}
	return out
}

func serveUDP(addr string, a *Arbiter) error {
	pc, err := net.ListenPacket("udp", addr)
	if err != nil {
		return err
	}
	go func() {
		buf := make([]byte, 65535)
		for {
			n, from, err := pc.ReadFrom(buf)
			if err != nil {
				if ne, ok := err.(net.Error); ok && ne.Timeout() {
					continue
				}
				log.Printf("UDP %s: %v", addr, err)
				time.Sleep(100 * time.Millisecond)
				continue
			}
			q := append([]byte(nil), buf[:n]...)
			go func() {
				r := a.Handle(q)
				if len(r) > 1232 && len(r) > maxUDP(q) {
					r = truncate(r)
				}
				pc.WriteTo(r, from)
			}()
		}
	}()
	return nil
}

func serveTCP(addr string, a *Arbiter) error {
	l, err := net.Listen("tcp", addr)
	if err != nil {
		return err
	}
	go func() {
		for {
			c, err := l.Accept()
			if err != nil {
				time.Sleep(100 * time.Millisecond)
				continue
			}
			go func(c net.Conn) {
				defer c.Close()
				c.SetDeadline(time.Now().Add(30 * time.Second))
				rd := bufio.NewReader(c)
				for {
					var l [2]byte
					if _, err := io.ReadFull(rd, l[:]); err != nil {
						return
					}
					q := make([]byte, int(l[0])<<8|int(l[1]))
					if _, err := io.ReadFull(rd, q); err != nil {
						return
					}
					r := a.Handle(q)
					out := append([]byte{byte(len(r) >> 8), byte(len(r))}, r...)
					if _, err := c.Write(out); err != nil {
						return
					}
				}
			}(c)
		}
	}()
	return nil
}

// maxUDP — размер ответа, который клиент примет по UDP (EDNS0 или 512)
func maxUDP(q []byte) int {
	_, off, err := ParseQuestion(q)
	if err != nil || len(q) < 12 || q[11] == 0 && q[10] == 0 {
		return 512
	}
	// OPT в разделе дополнительных записей: имя 0, тип 41, класс — размер
	if off+5 <= len(q) && q[off] == 0 && q[off+1] == 0 && q[off+2] == 41 {
		return int(q[off+3])<<8 | int(q[off+4])
	}
	return 512
}

// truncate — только заголовок и вопрос с флагом TC: клиент повторит по TCP
func truncate(r []byte) []byte {
	_, end, err := ParseQuestion(r)
	if err != nil {
		end = 12
	}
	out := append([]byte(nil), r[:end]...)
	out[2] |= 0x02
	for i := 6; i < 12; i++ {
		out[i] = 0
	}
	return out
}
