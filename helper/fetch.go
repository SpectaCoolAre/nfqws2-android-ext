package main

// -fetch: одна попытка HTTPS для отладочного замера (nfqws2-ctl bench_one), где
// нет curl. Встроенный wget busybox не отдаёт ни времени соединения и TLS, ни
// причины неудачи, а его урезанный TLS с частью сайтов не договаривается вовсе
// — на Pixel (14.11) замер показывал 0 мс и одинаковый итог у всех вариантов.
//
//	nfqws2-helper -fetch https://site/ -resolve 127.0.0.1:15353[,…] [-o тело] [-ua …]
//
// Вывод — как -w у curl в замере, одной строкой:
//
//	код connect appconnect starttransfer total байт адрес переадресация
//
// время — секунды от начала, переадресация — «-», если её нет. Код завершения
// — как у curl: 0 ответ сервера (любой HTTP), 6 имя не разрешилось, 7 отказ в
// соединении, 28 тайм-аут (connect 0 — TCP не соединился), 35 сбой TLS,
// 52 соединение закрыто без ответа, 56 сброс после TLS.

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/cookiejar"
	"net/http/httptrace"
	"net/url"
	"os"
	"strings"
	"sync/atomic"
	"syscall"
	"time"
)

var (
	fetchConnectTO = 5 * time.Second
	fetchTotalTO   = 10 * time.Second
)

const fetchBodyMax = 256 << 10 // в файл тела — не больше (заглушку узнают по началу)

// fetchMax — -max: читать ответ не дальше стольких байт (0 — до конца)
var fetchMax int64

type fetchResult struct {
	code            int
	tc, ta, tt, tot float64
	size            int64
	ip, redirect    string
	rc              int
}

func (r fetchResult) line() string {
	red := r.redirect
	if red == "" {
		red = "-"
	}
	ip := r.ip
	if ip == "" {
		ip = "-"
	}
	return fmt.Sprintf("%03d %.6f %.6f %.6f %.6f %d %s %s", r.code, r.tc, r.ta, r.tt, r.tot, r.size, ip, red)
}

// fetchResolve: адрес имени через данные DNS (как у приложений — DNS модуля
// или сети), первый ответивший
func fetchResolve(host string, servers []string) (string, error) {
	if ip := net.ParseIP(host); ip != nil {
		return host, nil
	}
	var last error = errors.New("нет DNS")
	for _, s := range servers {
		ips, err := udpResolve(s, host, 2*time.Second)
		if err == nil && len(ips) > 0 {
			return ips[0].String(), nil
		}
		if err != nil {
			last = err
		}
	}
	return "", last
}

func isTimeout(err error) bool {
	var ne net.Error
	return errors.Is(err, context.DeadlineExceeded) || (errors.As(err, &ne) && ne.Timeout())
}

func isReset(err error) bool {
	return errors.Is(err, syscall.ECONNRESET) || errors.Is(err, syscall.EPIPE) ||
		strings.Contains(err.Error(), "connection reset")
}

// fetchOpt — для проверки доступности (как curl -L --max-redirs N и --resolve):
// follow — сколько переадресаций пройти (с куками, как у браузера: сайты с
// защитой от ботов ставят куку переадресацией на себя), pin — адрес первого
// узла вместо DNS (проверка без обхода идёт к тому же адресу)
type fetchOpt struct {
	follow int
	pin    string
}

func fetch(raw string, servers []string, ua, bodyFile string) (r fetchResult) {
	return fetchWith(raw, servers, ua, bodyFile, fetchOpt{})
}

func fetchWith(raw string, servers []string, ua, bodyFile string, o fetchOpt) (r fetchResult) {
	start := time.Now()
	since := func() float64 { return time.Since(start).Seconds() }
	defer func() { r.tot = since() }()
	u, err := url.Parse(raw)
	if err != nil || u.Host == "" {
		r.rc = 3
		return r
	}
	host := u.Hostname()
	port := u.Port()
	if port == "" {
		port = "443"
	}
	ip := o.pin
	if ip == "" {
		var err error
		if ip, err = fetchResolve(host, servers); err != nil {
			r.rc = 6
			return r
		}
	}
	r.ip = ip
	ctx, cancel := context.WithTimeout(context.Background(), fetchTotalTO)
	defer cancel()
	// адрес — свой у каждого узла (переадресация бывает на другой домен)
	dial := func(ctx context.Context, _, addr string) (net.Conn, error) {
		h, p, err := net.SplitHostPort(addr)
		if err != nil {
			return nil, err
		}
		a := ip
		if h != host {
			if a, err = fetchResolve(h, servers); err != nil {
				return nil, &net.DNSError{Err: err.Error(), Name: h, IsNotFound: true}
			}
		}
		d := net.Dialer{Timeout: fetchConnectTO}
		return d.DialContext(ctx, "tcp", net.JoinHostPort(a, p))
	}
	_ = port
	tr := &http.Transport{
		DialContext:       dial,
		TLSClientConfig:   &tls.Config{InsecureSkipVerify: true},
		ForceAttemptHTTP2: true,
		DisableKeepAlives: true,
	}
	jar, _ := cookiejar.New(nil)
	cl := &http.Client{Transport: tr, Jar: jar, CheckRedirect: func(req *http.Request, via []*http.Request) error {
		if len(via) > o.follow {
			if o.follow > 0 {
				r.redirect = req.URL.String()
				r.rc = 47 // как curl: переадресаций больше разрешённого
			}
			return http.ErrUseLastResponse
		}
		return nil
	}}
	// отметки времени пишут горутины транспорта (и после тайм-аута тоже) —
	// атомарно, в наносекундах от начала
	var atc, ata, att atomic.Int64
	mark := func(a *atomic.Int64) { a.CompareAndSwap(0, int64(time.Since(start))) }
	sec := func(a *atomic.Int64) float64 { return time.Duration(a.Load()).Seconds() }
	defer func() { r.tc, r.ta, r.tt = sec(&atc), sec(&ata), sec(&att) }()
	trace := &httptrace.ClientTrace{
		ConnectDone: func(_, _ string, err error) {
			if err == nil {
				mark(&atc)
			}
		},
		TLSHandshakeDone: func(_ tls.ConnectionState, err error) {
			if err == nil {
				mark(&ata)
			}
		},
		GotFirstResponseByte: func() { mark(&att) },
	}
	req, _ := http.NewRequestWithContext(httptrace.WithClientTrace(ctx, trace), "GET", raw, nil)
	if ua != "" {
		req.Header.Set("User-Agent", ua)
	}
	resp, err := cl.Do(req)
	if err != nil {
		tc, ta := atc.Load(), ata.Load()
		switch {
		case tc == 0 && isTimeout(err):
			r.rc = 28
		case tc == 0:
			r.rc = 7
		case ta == 0 && isTimeout(err):
			r.rc = 28
		case ta == 0:
			r.rc = 35
		case isTimeout(err):
			r.rc = 28
		case isReset(err):
			r.rc = 56
		default:
			r.rc = 52
		}
		return r
	}
	defer resp.Body.Close()
	r.code = resp.StatusCode
	if loc := resp.Header.Get("Location"); o.follow == 0 && loc != "" && resp.StatusCode >= 300 && resp.StatusCode < 400 {
		if lu, err := u.Parse(loc); err == nil {
			r.redirect = lu.String()
		}
	}
	var w io.Writer = io.Discard
	var f *os.File
	if bodyFile != "" {
		if f, err = os.Create(bodyFile); err == nil {
			defer f.Close()
		}
	}
	buf := make([]byte, 32<<10)
	for {
		n, err := resp.Body.Read(buf)
		if n > 0 {
			if f != nil && r.size < fetchBodyMax {
				k := int64(n)
				if r.size+k > fetchBodyMax {
					k = fetchBodyMax - r.size
				}
				f.Write(buf[:k])
			}
			w.Write(buf[:n])
			r.size += int64(n)
		}
		if err == io.EOF {
			break
		}
		if r.rc == 47 {
			break
		}
		// -max: прочитано сколько нужно — дальше не качаем (первичная настройка
		// умного режима: 20 КБ уже значат, что DPI соединение пропустил, а
		// страницы целиком на тысячу попыток — сотни мегабайт)
		if fetchMax > 0 && r.size >= fetchMax {
			break
		}
		if err != nil {
			if isTimeout(err) {
				r.rc = 28
			} else {
				r.rc = 56
			}
			return r
		}
	}
	return r
}

func runFetch(raw, resolvers, ua, bodyFile string, follow int, pin string) {
	r := fetchWith(raw, splitList(resolvers), ua, bodyFile, fetchOpt{follow: follow, pin: pin})
	fmt.Println(r.line())
	os.Exit(r.rc)
}
