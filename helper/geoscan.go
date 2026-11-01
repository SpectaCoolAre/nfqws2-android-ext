// Проверка DNS с обходом геоблока: какие серверы из списка доступны в этой
// сети, как быстро отвечают и для каких доменов списка геоблока отдают адрес
// своего прокси, — и куда по итогам отправлять каждый домен.
//
//	nfqws2-helper -geoscan dns.comss.one,dns.zapret.moe -samples @geoblock.list -boot 213.87.142.94:53
//
// Проверяются все домены списка, а не несколько образцов: один сервер редко
// обходит всё, и где чей прокси, видно только по самому домену.
//
// Ответ сервера на домен: p — прокси (чужая сеть, см. classify), s — не
// обходит (тот же адрес или та же сеть, что у DNS сети), f — нет ответа.
// Прокси бывает двух родов:
//
//   - свой адрес у домена (сервер отдаёт его только этому сайту) — переправка
//     соединений как есть, работает для любого протокола;
//   - общий адрес на много сайтов — прокси по имени: разбирает имя сайта в
//     TLS (SNI) или HTTP. Сайт и приложения по HTTPS работают, а протокол без
//     имени (игры, свои протоколы) уходит туда, куда прокси настроен, — не
//     туда. Так Clash of Clans через общий прокси dns.malw.link попадал на
//     сервер Brawl Stars.
//
// Поэтому домен отправляется к серверам, у которых для него свой адрес, если
// такие есть, иначе — к тем, у кого прокси общий для меньшего числа сайтов
// (см. planRoutes). Какой протокол у приложения, DNS знать не может, — а так
// подходит любой.
//
// Вывод — строка на сервер, через табуляцию:
//
//	сервер  ok|fail  мс  обходит  доменов  своим-адресом  tls|https|-  [ошибка]
//
// строки об общих адресах прокси «+сервер<TAB>адрес<TAB>сайтов» (их читает
// частая проверка, -shared) и строка на домен: «=домен<TAB>сервер,сервер» —
// куда его отправлять, «=домен<TAB>-» — никто не обходит, в DNS сети. Нет
// строки — данных о домене нет (серверы не ответили), он идёт в общий пул.
//
// Частая проверка — та же, по нескольким десяткам доменов, которыми
// пользуются (см. lib/dns.sh dns_geo_hot_list): общий ли адрес прокси, она
// берёт и из прошлой полной проверки (-shared), иначе общий на сотни сайтов
// прокси в ней выглядел бы своим у домена.
package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"sort"
	"strings"
	"sync"
	"time"
)

// dnsQuery — запрос A с рекурсией
func dnsQuery(id uint16, name string) ([]byte, error) { return dnsQueryType(id, name, 1) }

// dnsQueryType — запрос записи типа qtype (1 — A, 16 — TXT)
func dnsQueryType(id uint16, name string, qtype uint16) ([]byte, error) {
	q := []byte{byte(id >> 8), byte(id), 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0}
	for _, l := range strings.Split(strings.TrimSuffix(name, "."), ".") {
		if l == "" || len(l) > 63 {
			return nil, fmt.Errorf("плохое имя %q", name)
		}
		q = append(q, byte(len(l)))
		q = append(q, l...)
	}
	return append(q, 0, byte(qtype>>8), byte(qtype), 0, 1), nil
}

// skipName — длина имени в сообщении (со сжатием)
func skipName(m []byte, off int) (int, error) {
	for {
		if off >= len(m) {
			return 0, errors.New("обрыв имени")
		}
		l := int(m[off])
		switch {
		case l == 0:
			return off + 1, nil
		case l&0xc0 == 0xc0:
			return off + 2, nil
		default:
			off += 1 + l
		}
	}
}

// dnsAnswerA — ID, код ответа и адреса A из ответа
func dnsAnswerA(m []byte) (uint16, int, []net.IP, error) {
	id, rcode, rds, err := dnsAnswerRR(m, 1)
	var ips []net.IP
	for _, rd := range rds {
		if len(rd) == 4 {
			ips = append(ips, net.IP(rd))
		}
	}
	return id, rcode, ips, err
}

// dnsAnswerRR — ID, код ответа и данные записей типа want из ответа
func dnsAnswerRR(m []byte, want uint16) (uint16, int, [][]byte, error) {
	if len(m) < 12 {
		return 0, 0, nil, errors.New("короткий ответ")
	}
	id := binary.BigEndian.Uint16(m)
	rcode := int(m[3] & 0x0f)
	qd, an := int(binary.BigEndian.Uint16(m[4:])), int(binary.BigEndian.Uint16(m[6:]))
	off := 12
	var err error
	for i := 0; i < qd; i++ {
		if off, err = skipName(m, off); err != nil {
			return id, rcode, nil, err
		}
		off += 4
	}
	var rds [][]byte
	for i := 0; i < an; i++ {
		if off, err = skipName(m, off); err != nil {
			return id, rcode, rds, err
		}
		if off+10 > len(m) {
			return id, rcode, rds, errors.New("обрыв записи")
		}
		typ := binary.BigEndian.Uint16(m[off:])
		rdl := int(binary.BigEndian.Uint16(m[off+8:]))
		off += 10
		if off+rdl > len(m) {
			return id, rcode, rds, errors.New("обрыв данных")
		}
		if typ == want {
			rds = append(rds, append([]byte(nil), m[off:off+rdl]...))
		}
		off += rdl
	}
	return id, rcode, rds, nil
}

// udpResolve — адреса имени у обычного DNS (DNS сети), с одним повтором
func udpResolve(server, name string, wait time.Duration) ([]net.IP, error) {
	q, err := dnsQuery(uint16(time.Now().UnixNano()), name)
	if err != nil {
		return nil, err
	}
	m, err := udpExchange(server, q, wait)
	if err != nil {
		return nil, err
	}
	_, rcode, ips, err := dnsAnswerA(m)
	if err != nil {
		return nil, err
	}
	if rcode != 0 {
		return nil, fmt.Errorf("rcode %d", rcode)
	}
	return ips, nil
}

// udpExchange — запрос q к DNS по UDP и ответ на него, с одним повтором
func udpExchange(server string, q []byte, wait time.Duration) ([]byte, error) {
	c, err := net.Dial("udp", server)
	if err != nil {
		return nil, err
	}
	defer c.Close()
	buf := make([]byte, 1500)
	deadline := time.Now().Add(wait)
	for try := 0; try < 2; try++ {
		if _, err := c.Write(q); err != nil {
			return nil, err
		}
		until := deadline
		if try == 0 {
			until = time.Now().Add(wait / 2)
		}
		c.SetReadDeadline(until)
		for {
			n, err := c.Read(buf)
			if err != nil {
				var ne net.Error
				if errors.As(err, &ne) && ne.Timeout() {
					break
				}
				return nil, err
			}
			if n < 12 || buf[0] != q[0] || buf[1] != q[1] || buf[2]&0x80 == 0 {
				continue
			}
			return append([]byte(nil), buf[:n]...), nil
		}
	}
	return nil, errors.New("нет ответа")
}

// junkIP — ответ, который ничего не обходит: 0.0.0.0, локальные и частные
// адреса (так некоторые DNS «блокируют» домен)
func junkIP(ip net.IP) bool {
	return ip.IsUnspecified() || ip.IsLoopback() || ip.IsPrivate() || ip.IsLinkLocalUnicast()
}

// classify — p: прокси, s: не обходит, f: пусто или мусор, u: неизвестно.
//
// Не обходит — адрес совпал с ответом DNS сети или принадлежит той же сети
// (AS): у крупных облаков и CDN (Amazon, Google, Microsoft…) разные DNS
// отдают разные адреса одного сервиса, и «не совпал» ещё не значит «прокси»
// (dns.zapret.moe на gamea.clashofclans.com отдаёт другие адреса Amazon).
// Прокси DNS обхода стоят у хостеров (AEZA, HostLab, Private Layer…) — это
// чужая сеть. Номер AS неизвестен (служба не ответила, или нет эталона) —
// u, решает geoScan по тому, общий ли это адрес
func classify(got, real []net.IP, asn map[string][]string) byte {
	ref := make(map[string]bool)
	for _, r := range real {
		for _, a := range asn[asnKey(r)] {
			ref[a] = true
		}
	}
	ok, unknown := false, len(ref) == 0
	for _, g := range got {
		if junkIP(g) {
			continue
		}
		ok = true
		for _, r := range real {
			if g.Equal(r) {
				return 's'
			}
		}
		as := asn[asnKey(g)]
		if len(as) == 0 {
			unknown = true
		}
		for _, a := range as {
			if ref[a] {
				return 's'
			}
		}
	}
	switch {
	case !ok:
		return 'f'
	case unknown:
		return 'u'
	}
	return 'p'
}

// asnKey — /24 адреса: владелец у /24 один, а запросов так меньше
func asnKey(ip net.IP) string {
	v := ip.To4()
	if v == nil {
		return ""
	}
	return fmt.Sprintf("%d.%d.%d", v[0], v[1], v[2])
}

// asnZone — служба Team Cymru: TXT <октеты наоборот>.origin.asn.cymru.com →
// «14618 | 54.198.0.0/16 | US | arin | 2014-10-23» (тесты подменяют)
var asnZone = "origin.asn.cymru.com"

// asnCache — файл кэша номеров AS («/24<TAB>AS AS<TAB>unix»): адрес сети
// хостера годами не меняется, и повторная проверка спрашивает только новые
var asnCache string

const asnCacheTTL = 7 * 24 * 3600

func loadASN() map[string][]string {
	out := make(map[string][]string)
	b, err := os.ReadFile(asnCache)
	if asnCache == "" || err != nil {
		return out
	}
	now := time.Now().Unix()
	for _, l := range strings.Split(string(b), "\n") {
		f := strings.Split(l, "\t")
		if len(f) != 3 {
			continue
		}
		var t int64
		fmt.Sscan(f[2], &t)
		if now-t < asnCacheTTL && f[1] != "" {
			out[f[0]] = strings.Fields(f[1])
		}
	}
	return out
}

func saveASN(m map[string][]string, fresh map[string]bool, old string) {
	if asnCache == "" {
		return
	}
	now := time.Now().Unix()
	var b strings.Builder
	// прежние строки — с их временем, новые — с нынешним
	for _, l := range strings.Split(old, "\n") {
		f := strings.Split(l, "\t")
		if len(f) == 3 && !fresh[f[0]] {
			var t int64
			fmt.Sscan(f[2], &t)
			if now-t < asnCacheTTL {
				b.WriteString(l + "\n")
			}
		}
	}
	for k := range fresh {
		if as := m[k]; len(as) > 0 {
			fmt.Fprintf(&b, "%s\t%s\t%d\n", k, strings.Join(as, " "), now)
		}
	}
	tmp := asnCache + ".tmp"
	if os.WriteFile(tmp, []byte(b.String()), 0644) == nil {
		os.Rename(tmp, asnCache)
	}
}

// asnLookup — номера AS для адресов (по ключу asnKey): из кэша, остальные —
// через DNS сети, параллельно; не ответившие пропускаются
func asnLookup(boot string, ips []net.IP, wait time.Duration) map[string][]string {
	cached := loadASN()
	out := make(map[string][]string, len(cached))
	for k, v := range cached {
		out[k] = v
	}
	old, _ := os.ReadFile(asnCache)
	fresh := make(map[string]bool)
	seen := make(map[string]bool)
	var mu sync.Mutex
	var wg sync.WaitGroup
	sem := make(chan struct{}, 32)
	for _, ip := range ips {
		k := asnKey(ip)
		if k == "" || seen[k] || junkIP(ip) || cached[k] != nil {
			continue
		}
		seen[k] = true
		v := ip.To4()
		wg.Add(1)
		go func(k string, v net.IP) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			name := fmt.Sprintf("%d.%d.%d.%d.%s", v[3], v[2], v[1], v[0], asnZone)
			q, err := dnsQueryType(uint16(time.Now().UnixNano()), name, 16)
			if err != nil {
				return
			}
			m, err := udpExchange(boot, q, wait)
			if err != nil {
				return
			}
			_, rcode, rds, err := dnsAnswerRR(m, 16)
			if err != nil || rcode != 0 {
				return
			}
			var as []string
			for _, rd := range rds {
				if len(rd) < 1 || int(rd[0])+1 > len(rd) {
					continue
				}
				f := strings.SplitN(string(rd[1:1+int(rd[0])]), "|", 2)
				for _, a := range strings.Fields(f[0]) {
					if a != "NA" {
						as = append(as, a)
					}
				}
			}
			if len(as) > 0 {
				mu.Lock()
				out[k] = as
				fresh[k] = true
				mu.Unlock()
			}
		}(k, v)
	}
	wg.Wait()
	if len(fresh) > 0 {
		saveASN(out, fresh, string(old))
	}
	return out
}

type scanResult struct {
	server string
	ok     bool
	ms     int64
	marks  []byte
	ans    [][]net.IP // адреса по доменам (nil — нет ответа)
	share  []int      // сколько сайтов делят адрес прокси (см. shareCounts)
	proto  string     // tls — DoT, https — DoH (DoT не прошёл), "-" — ни один
	err    string
	tries  int // попыток подключения (см. scanTries) и удачных из них
	okTry  int
	cert   int // доменов, где прокси не дал настоящего сертификата (см. verifyRoutes)
}

// tlsRoots — корневые сертификаты; nil — собрать из системы (тесты подставляют свой)
var tlsRoots *x509.CertPool

// Каталоги сертификатов Android: с Android 14 актуальные лежат в APEX
// conscrypt, /system — прежнее место, cacerts-added — добавленные
// пользователем. Go сам смотрит только /system/etc/security/cacerts и пути
// Linux, а SSL_CERT_DIR в окружении (бывает у оболочки WebUI) заменяет их все
var androidCertDirs = []string{"/apex/com.android.conscrypt/cacerts", "/system/etc/security/cacerts", "/data/misc/user/0/cacerts-added"}

var rootsOnce sync.Once
var roots *x509.CertPool

func rootPool() *x509.CertPool {
	if tlsRoots != nil {
		return tlsRoots
	}
	rootsOnce.Do(func() {
		p, err := x509.SystemCertPool()
		if err != nil || p == nil {
			p = x509.NewCertPool()
		}
		for _, d := range androidCertDirs {
			ents, err := os.ReadDir(d)
			if err != nil {
				continue
			}
			for _, e := range ents {
				if b, err := os.ReadFile(d + "/" + e.Name()); err == nil {
					p.AppendCertsFromPEM(b)
				}
			}
		}
		roots = p
	})
	return roots
}

// certErr — понятная причина отказа TLS: чей сертификат пришёл. Чужой
// издатель у всех серверов разом — признак подмены соединения в сети
func certErr(err error) string {
	var ua x509.UnknownAuthorityError
	if errors.As(err, &ua) && ua.Cert != nil {
		iss := ua.Cert.Issuer.CommonName
		if len(ua.Cert.Issuer.Organization) > 0 {
			iss += ", " + ua.Cert.Issuer.Organization[0]
		}
		return fmt.Sprintf("сертификат не доверен: выдан «%s» для «%s»", strings.TrimPrefix(iss, ", "), ua.Cert.Subject.CommonName)
	}
	var he x509.HostnameError
	if errors.As(err, &he) && he.Certificate != nil {
		return fmt.Sprintf("сертификат на другое имя: «%s»", he.Certificate.Subject.CommonName)
	}
	return err.Error()
}

// serverAddr — адрес сервера у DNS сети: системный резолвер ушёл бы в перехват модуля
func serverAddr(host, boot string, wait time.Duration) (string, error) {
	if net.ParseIP(host) != nil {
		return host, nil
	}
	ips, err := udpResolve(boot, host, wait)
	if err != nil || len(ips) == 0 {
		msg := "имя сервера не разрешилось"
		if err != nil {
			msg += ": " + err.Error()
		}
		return "", errors.New(msg)
	}
	return ips[0].String(), nil
}

func newResult(server string, n int) scanResult {
	r := scanResult{server: server, marks: make([]byte, n), ans: make([][]net.IP, n), share: make([]int, n), proto: "-"}
	for i := range r.marks {
		r.marks[i] = 'f'
	}
	return r
}

// dotBatch — сколько запросов держать в полёте в одном соединении DoT:
// серверы ограничивают очередь соединения, лишнее теряют молча
const dotBatch = 50

// dotScan — одно соединение DoT с сервером, запросы пачками по dotBatch
func dotScan(server string, names []string, boot string, wait time.Duration) scanResult {
	r := newResult(server, len(names))
	host, port := server, "853"
	if h, p, err := net.SplitHostPort(server); err == nil {
		host, port = h, p
	}
	deadline := time.Now().Add(wait)
	ctx, cancel := context.WithDeadline(context.Background(), deadline)
	defer cancel()
	addr, err := serverAddr(host, boot, 3*time.Second)
	if err != nil {
		r.err = err.Error()
		return r
	}
	t0 := time.Now()
	d := tls.Dialer{NetDialer: &net.Dialer{}, Config: &tls.Config{ServerName: host, MinVersion: tls.VersionTLS12, RootCAs: rootPool()}}
	c, err := d.DialContext(ctx, "tcp", net.JoinHostPort(addr, port))
	if err != nil {
		r.err = certErr(err)
		return r
	}
	defer c.Close()
	base := uint16(time.Now().UnixNano())
	lb := make([]byte, 2)
	for start := 0; start < len(names); start += dotBatch {
		end := start + dotBatch
		if end > len(names) {
			end = len(names)
		}
		c.SetWriteDeadline(deadline)
		for i := start; i < end; i++ {
			q, err := dnsQuery(base+uint16(i), names[i])
			if err != nil {
				continue
			}
			msg := make([]byte, 2+len(q))
			binary.BigEndian.PutUint16(msg, uint16(len(q)))
			copy(msg[2:], q)
			if _, err := c.Write(msg); err != nil {
				if !r.ok {
					r.err = err.Error()
				}
				return r
			}
		}
		// ответы пачки; не пришедшие за 3 секунды — потеряны (f)
		until := time.Now().Add(3 * time.Second)
		if until.After(deadline) {
			until = deadline
		}
		c.SetReadDeadline(until)
		for got := start; got < end; got++ {
			if _, err := io.ReadFull(c, lb); err != nil {
				if !r.ok {
					r.err = err.Error()
					return r
				}
				break
			}
			m := make([]byte, binary.BigEndian.Uint16(lb))
			if _, err := io.ReadFull(c, m); err != nil {
				break
			}
			if !r.ok {
				r.ok, r.proto = true, "tls"
				r.ms = time.Since(t0).Milliseconds()
			}
			id, rcode, ips, err := dnsAnswerA(m)
			i := int(id - base)
			if i < 0 || i >= len(names) || err != nil || rcode != 0 {
				continue
			}
			r.ans[i] = ips
		}
		if time.Now().After(deadline) {
			break
		}
	}
	return r
}

// dohScan — то же по DoH (https://сервер/dns-query, POST): так ходит и
// dnsproxy модуля, и это выручает, если в сети закрыт или подменён порт 853.
// Первый запрос — один (проверка соединения и сертификата), остальные —
// параллельно в том же соединении HTTP/2
func dohScan(server string, names []string, boot string, wait time.Duration) scanResult {
	r := newResult(server, len(names))
	host, _, err := net.SplitHostPort(server)
	if err != nil {
		host = server
	}
	deadline := time.Now().Add(wait)
	addr, err := serverAddr(host, boot, 3*time.Second)
	if err != nil {
		r.err = err.Error()
		return r
	}
	tr := &http.Transport{
		DialContext: func(ctx context.Context, network, _ string) (net.Conn, error) {
			return (&net.Dialer{}).DialContext(ctx, network, net.JoinHostPort(addr, dohPort))
		},
		TLSClientConfig:   &tls.Config{ServerName: host, MinVersion: tls.VersionTLS12, RootCAs: rootPool()},
		ForceAttemptHTTP2: true,
		MaxConnsPerHost:   1,
	}
	defer tr.CloseIdleConnections()
	cl := &http.Client{Transport: tr, Timeout: time.Until(deadline)}
	ask := func(name string) ([]net.IP, error) {
		q, err := dnsQuery(0, name)
		if err != nil {
			return nil, nil
		}
		req, _ := http.NewRequest("POST", "https://"+host+"/dns-query", bytes.NewReader(q))
		req.Header.Set("Content-Type", "application/dns-message")
		req.Header.Set("Accept", "application/dns-message")
		resp, err := cl.Do(req)
		if err != nil {
			return nil, errors.New(certErr(err))
		}
		m, _ := io.ReadAll(io.LimitReader(resp.Body, 65535))
		resp.Body.Close()
		if resp.StatusCode != 200 {
			return nil, errors.New("DoH: ответ " + resp.Status)
		}
		_, rcode, ips, err := dnsAnswerA(m)
		if err != nil || rcode != 0 {
			return nil, nil
		}
		return ips, nil
	}
	if len(names) == 0 {
		return r
	}
	t0 := time.Now()
	ips, err := ask(names[0])
	if err != nil {
		r.err = err.Error()
		return r
	}
	r.ok, r.proto, r.ms = true, "https", time.Since(t0).Milliseconds()
	r.ans[0] = ips
	var wg sync.WaitGroup
	sem := make(chan struct{}, 16)
	for i := 1; i < len(names); i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			if time.Now().After(deadline) {
				return
			}
			if ips, err := ask(names[i]); err == nil {
				r.ans[i] = ips
			}
		}(i)
	}
	wg.Wait()
	return r
}

// dohPort — порт DoH (тесты подменяют)
var dohPort = "443"

// scanServer — DoT; не прошёл — DoH. Обе ошибки — в итог
func scanServer(server string, names []string, boot string, wait time.Duration) scanResult {
	r := dotScan(server, names, boot, wait)
	if r.ok {
		return r
	}
	h := dohScan(server, names, boot, wait)
	if h.ok {
		return h
	}
	r.err = "DoT: " + r.err + "; DoH: " + h.err
	return r
}

// scanTries — сколько раз подключаться к серверу: блокировка иногда
// включается не с первого соединения, и сервер, ответивший на часть
// попыток, — «через раз» (в маршрутах — после надёжных). Первая попытка —
// сама проверка, остальные — отдельными соединениями с одним запросом, разом
const scanTries = 3

func scanServerTries(server string, names []string, boot string, wait time.Duration) scanResult {
	if len(names) == 0 {
		return scanServer(server, names, boot, wait)
	}
	extra := make(chan bool, scanTries-1)
	for k := 1; k < scanTries; k++ {
		go func() { extra <- scanServer(server, names[:1], boot, wait/2).ok }()
	}
	r := scanServer(server, names, boot, wait)
	r.tries = scanTries
	if r.ok {
		r.okTry++
	}
	for k := 1; k < scanTries; k++ {
		if <-extra {
			r.okTry++
		}
	}
	return r
}

// flaky — ответил не на все попытки
func (r *scanResult) flaky() bool { return r.okTry > 0 && r.okTry < r.tries }

// verifyProxy — настоящий ли сертификат сайта отдаёт адрес прокси по его
// имени: прокси DNS обхода пропускает TLS сайта как есть, и рабочий отдаёт
// сертификат самого сайта; неработающий рвёт соединение или подставляет
// чужой (идея — zapretgui, MIT, censorliber: «честен ли DNS» по сертификату).
// Затем — что отвечает сайт (siteRefuses).
// Тесты подменяют
var verifyProxy = func(ip net.IP, host string, wait time.Duration) bool {
	d := tls.Dialer{NetDialer: &net.Dialer{Timeout: wait}, Config: &tls.Config{ServerName: host, MinVersion: tls.VersionTLS12, RootCAs: rootPool()}}
	ctx, cancel := context.WithTimeout(context.Background(), wait)
	defer cancel()
	c, err := d.DialContext(ctx, "tcp", net.JoinHostPort(ip.String(), proxyTLSPort))
	if err != nil {
		return false
	}
	defer c.Close()
	// и что отвечает сам сайт: страница «необычный трафик», капча или «не
	// работает в вашей стране» — прокси сайт не обходит (у Gemini так бывает
	// у прокси, чей адрес Google считает подозрительным)
	c.SetDeadline(time.Now().Add(wait))
	fmt.Fprintf(c, "GET / HTTP/1.1\r\nHost: %s\r\nUser-Agent: Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 Chrome/130.0 Mobile Safari/537.36\r\nAccept: text/html\r\nConnection: close\r\n\r\n", host)
	b, _ := io.ReadAll(io.LimitReader(c, 32768))
	return !siteRefuses(string(b))
}

// siteRefuses — ответ сайта говорит, что через этот адрес его не открыть:
// код 429, переадресация на страницу «sorry» Google, текст о необычном
// трафике или о том, что сервис недоступен в стране. Пустой ответ (сервер
// закрыл соединение после рукопожатия) — не довод: так бывает и у живых
func siteRefuses(resp string) bool {
	head, body, _ := strings.Cut(resp, "\r\n\r\n")
	low := strings.ToLower(head)
	if f := strings.Fields(head); len(f) >= 2 && f[1] == "429" {
		return true
	}
	for _, l := range strings.Split(low, "\r\n") {
		if strings.HasPrefix(l, "location:") && (strings.Contains(l, "/sorry/") || strings.Contains(l, "unsupported")) {
			return true
		}
	}
	low = strings.ToLower(body)
	for _, m := range []string{"unusual traffic", "our systems have detected", "not available in your country", "isn't supported in your country",
		"is not supported in your country", "not available in your region", "unsupported_country", "unsupported country"} {
		if strings.Contains(low, m) {
			return true
		}
	}
	return false
}

// proxyTLSPort — порт сайта для verifyProxy (тесты подменяют)
var proxyTLSPort = "443"

// verifyRoutes — проверка по факту для частой проверки: для каждого домена и
// сервера с прокси — сертификат по адресу прокси (verifyProxy). Хоть у
// одного сервера настоящий — серверы, у кого нет, для домена не годятся
// (отметка c). Ни у кого — домен, видимо, не HTTPS (игра) или недоступен
// весь: тогда проверка ничего не решает
func verifyRoutes(res []scanResult, names []string, wait time.Duration) {
	type key struct{ ip, host string }
	good := make(map[key]bool)
	var mu sync.Mutex
	var wg sync.WaitGroup
	sem := make(chan struct{}, 24)
	first := func(a []net.IP) net.IP {
		for _, ip := range a {
			if !junkIP(ip) && ip.To4() != nil {
				return ip
			}
		}
		return nil
	}
	seen := make(map[key]bool)
	for k := range res {
		for i, m := range res[k].marks {
			ip := first(res[k].ans[i])
			if m != 'p' || ip == nil {
				continue
			}
			kk := key{ip.String(), names[i]}
			if seen[kk] {
				continue
			}
			seen[kk] = true
			wg.Add(1)
			go func(kk key, ip net.IP) {
				defer wg.Done()
				sem <- struct{}{}
				defer func() { <-sem }()
				ok := verifyProxy(ip, kk.host, wait)
				mu.Lock()
				good[kk] = ok
				mu.Unlock()
			}(kk, ip)
		}
	}
	wg.Wait()
	for i := range names {
		any := false
		for k := range res {
			if ip := first(res[k].ans[i]); res[k].marks[i] == 'p' && ip != nil && good[key{ip.String(), names[i]}] {
				any = true
			}
		}
		if !any {
			continue
		}
		for k := range res {
			if ip := first(res[k].ans[i]); res[k].marks[i] == 'p' && ip != nil && !good[key{ip.String(), names[i]}] {
				res[k].marks[i] = 'c'
				res[k].cert++
			}
		}
	}
}

// Кто на самом деле отвечает на обычный DNS: имя whoami.akamai.net
// возвращает адрес резолвера, который пришёл за ответом (идея — zapretgui,
// MIT, censorliber). Запрос «к 8.8.8.8», на который пришёл резолвер не из
// сети Google (AS15169), — перехвачен по дороге: сеть подменяет ответы
// публичных DNS своими. Так было у МТС: dig @8.8.8.8 отдавал её ответы
type whoAns struct {
	name, server, as string // as — чей должен быть ответивший резолвер ("" — DNS сети)
	ip               net.IP
}

var whoamiName = "whoami.akamai.net"

// whoamiTargets — публичные DNS и их сети (тесты подменяют)
var whoamiTargets = []whoAns{{name: "google", server: "8.8.8.8:53", as: "15169"}, {name: "cloudflare", server: "1.1.1.1:53", as: "13335"}}

func whoamiAll(boot string, wait time.Duration) []whoAns {
	all := append([]whoAns{{name: "net", server: boot}}, whoamiTargets...)
	var wg sync.WaitGroup
	for i := range all {
		wg.Add(1)
		go func(w *whoAns) {
			defer wg.Done()
			if ips, err := udpResolve(w.server, whoamiName, wait); err == nil && len(ips) > 0 {
				w.ip = ips[0]
			}
		}(&all[i])
	}
	wg.Wait()
	return all
}

// formatWhoami — «?whoami<TAB>net=адрес/AS<TAB>google=…<TAB>intercept=0|1»
func formatWhoami(who []whoAns, asn map[string][]string) string {
	parts := []string{"?whoami"}
	icpt := 0
	for _, w := range who {
		v := "-"
		if w.ip != nil {
			as := strings.Join(asn[asnKey(w.ip)], " ")
			v = w.ip.String() + "/" + as
			if w.as != "" && as != "" {
				own := false
				for _, a := range asn[asnKey(w.ip)] {
					own = own || a == w.as
				}
				if !own {
					icpt = 1
				}
			}
		}
		parts = append(parts, w.name+"="+v)
	}
	return strings.Join(append(parts, fmt.Sprintf("intercept=%d", icpt)), "\t")
}

// whoamiCheck — включает проверку перехвата (полная проверка); итог — lastWhoami
var whoamiCheck bool
var lastWhoami string

// verifyCerts — включает verifyRoutes (частая проверка, -verify)
var verifyCerts bool

// siteOf — сайт домена (последние две метки, у co.uk и подобных — три):
// поддомены одного сайта у прокси считаются одним сайтом
func siteOf(name string) string {
	l := strings.Split(strings.TrimSuffix(strings.ToLower(name), "."), ".")
	n := 2
	if len(l) >= 3 && len(l[len(l)-1]) == 2 {
		switch l[len(l)-2] {
		case "co", "com", "net", "org", "gov", "edu", "ac", "or", "ne", "go":
			n = 3
		}
	}
	if len(l) <= n {
		return strings.Join(l, ".")
	}
	return strings.Join(l[len(l)-n:], ".")
}

// ipSites — сколько разных сайтов получили от сервера каждый адрес прокси
// (вместе с известным по прошлой полной проверке, см. knownShare)
func ipSites(r *scanResult, names []string) map[string]int {
	sites := make(map[string]map[string]bool)
	for i, a := range r.ans {
		if r.marks[i] != 'p' && r.marks[i] != 'u' {
			continue
		}
		for _, ip := range a {
			if junkIP(ip) {
				continue
			}
			k := ip.String()
			if sites[k] == nil {
				sites[k] = make(map[string]bool)
			}
			sites[k][siteOf(names[i])] = true
		}
	}
	out := make(map[string]int, len(sites))
	for k, v := range sites {
		out[k] = len(v)
	}
	for k, n := range knownShare[r.server] {
		if n > out[k] {
			out[k] = n
		}
	}
	return out
}

// knownShare — общие адреса прокси по прошлой полной проверке (сервер →
// адрес → сайтов): частая проверка идёт по нескольким десяткам доменов, и
// общий на сотни сайтов прокси в ней выглядел бы своим у домена
var knownShare map[string]map[string]int

// shareCounts — для каждого домена: сколько разных сайтов получили от этого
// сервера тот же адрес прокси (наибольшее по адресам ответа). 1 — свой адрес
func shareCounts(r *scanResult, names []string) {
	sites := ipSites(r, names)
	for i, a := range r.ans {
		r.share[i] = 0
		if r.marks[i] != 'p' && r.marks[i] != 'u' {
			continue
		}
		for _, ip := range a {
			if n := sites[ip.String()]; n > r.share[i] {
				r.share[i] = n
			}
		}
	}
}

// formatShared — строки «+сервер<TAB>адрес<TAB>сайтов» об общих адресах
// прокси (на два сайта и больше): их читает следующая частая проверка
func formatShared(res []scanResult, names []string) []string {
	var out []string
	for k := range res {
		r := &res[k]
		sites := ipSites(r, names)
		keys := make([]string, 0, len(sites))
		for ip, n := range sites {
			if n > 1 {
				keys = append(keys, ip)
			}
		}
		sort.Strings(keys)
		for _, ip := range keys {
			out = append(out, fmt.Sprintf("+%s\t%s\t%d", r.server, ip, sites[ip]))
		}
	}
	return out
}

// loadShared — общие адреса из файла прошлой проверки (строки «+…»)
func loadShared(path string) map[string]map[string]int {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	out := make(map[string]map[string]int)
	for _, l := range strings.Split(string(b), "\n") {
		if !strings.HasPrefix(l, "+") {
			continue
		}
		f := strings.Split(l[1:], "\t")
		if len(f) != 3 {
			continue
		}
		var n int
		fmt.Sscan(f[2], &n)
		if out[f[0]] == nil {
			out[f[0]] = make(map[string]int)
		}
		out[f[0]][f[1]] = n
	}
	return out
}

// geoScan — все серверы разом; эталон — ответы DNS сети на те же домены
func geoScan(servers, names []string, boot string, wait time.Duration) []scanResult {
	// время: эталон — до четверти, серверы — половина, номера AS — остаток
	refWait, scanWait, asnWait := wait/4, wait/2, wait/4
	if refWait > 4*time.Second {
		refWait = 4 * time.Second
	}
	real := make([][]net.IP, len(names))
	var wg sync.WaitGroup
	sem := make(chan struct{}, 32)
	for i, s := range names {
		wg.Add(1)
		go func(i int, s string) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			real[i], _ = udpResolve(boot, s, refWait)
		}(i, s)
	}
	wg.Wait()
	res := make([]scanResult, len(servers))
	for i, s := range servers {
		wg.Add(1)
		go func(i int, s string) {
			defer wg.Done()
			res[i] = scanServerTries(s, names, boot, scanWait)
		}(i, s)
	}
	wg.Wait()
	// номера AS: всех адресов эталона и первых адресов ответов, не
	// совпавших с ним (у совпавших и так ясно)
	var ips []net.IP
	for _, a := range real {
		ips = append(ips, a...)
	}
	for _, r := range res {
		for i, a := range r.ans {
			if len(a) > 0 && classify(a, real[i], nil) != 's' {
				if len(a) > 3 {
					a = a[:3]
				}
				ips = append(ips, a...)
			}
		}
	}
	// кто на самом деле отвечает (whoami.akamai.net): запрос — до номеров AS
	var who []whoAns
	if whoamiCheck {
		who = whoamiAll(boot, refWait)
		for _, w := range who {
			if w.ip != nil {
				ips = append(ips, w.ip)
			}
		}
	}
	asn := asnLookup(boot, ips, asnWait)
	if whoamiCheck {
		lastWhoami = formatWhoami(who, asn)
	}
	for k := range res {
		r := &res[k]
		for i, a := range r.ans {
			r.marks[i] = classify(a, real[i], asn)
		}
		// неизвестная сеть: адрес, общий для нескольких сайтов, — прокси
		// (у настоящего сайта свой адрес); свой — считаем настоящим
		shareCounts(r, names)
		for i := range r.marks {
			if r.marks[i] == 'u' {
				if r.share[i] > 1 {
					r.marks[i] = 'p'
				} else {
					r.marks[i] = 's'
				}
			}
		}
		shareCounts(r, names)
	}
	if verifyCerts {
		verifyRoutes(res, names, 4*time.Second)
	}
	return res
}

// route — куда отправлять домен: серверы (индексы res) или direct — никто не
// обходит, в DNS сети; known=false — данных нет
type route struct {
	servers []int
	direct  bool
	known   bool
}

// planRoutes — для каждого домена до max серверов, у которых для него
// прокси. Сначала — серверы со своим адресом у домена (подходят для любого
// протокола); нет таких — те, у кого адрес прокси общий для меньшего числа
// сайтов, при равенстве — быстрые. Серверы со своим адресом и общим не
// смешиваются: dnsproxy берёт первый ответ, и общий прокси увёл бы игру не туда
func planRoutes(res []scanResult, n, max int) []route {
	out := make([]route, n)
	for i := 0; i < n; i++ {
		var cand []int
		real := false
		for k, r := range res {
			if !r.ok {
				continue
			}
			switch r.marks[i] {
			case 'p':
				cand = append(cand, k)
			case 's':
				real = true
			}
		}
		if len(cand) == 0 {
			out[i] = route{direct: real, known: real}
			continue
		}
		less := func(a, b int) bool {
			sa, sb := res[a].share[i], res[b].share[i]
			if (sa == 1) != (sb == 1) {
				return sa == 1
			}
			// «через раз» — после надёжных
			if fa, fb := res[a].flaky(), res[b].flaky(); fa != fb {
				return fb
			}
			if sa != sb {
				return sa < sb
			}
			return res[a].ms < res[b].ms
		}
		for a := 1; a < len(cand); a++ {
			for b := a; b > 0 && less(cand[b], cand[b-1]); b-- {
				cand[b], cand[b-1] = cand[b-1], cand[b]
			}
		}
		if res[cand[0]].share[i] == 1 {
			k := 0
			for k < len(cand) && res[cand[k]].share[i] == 1 {
				k++
			}
			cand = cand[:k]
		}
		if len(cand) > max {
			cand = cand[:max]
		}
		out[i] = route{servers: cand, known: true}
	}
	return out
}

func formatScan(r scanResult) string {
	st, p, own := "fail", 0, 0
	if r.ok {
		st = "ok"
	}
	for i, m := range r.marks {
		if m == 'p' {
			p++
			if r.share[i] == 1 {
				own++
			}
		}
	}
	line := fmt.Sprintf("%s\t%s\t%d\t%d\t%d\t%d\t%s", r.server, st, r.ms, p, len(r.marks), own, r.proto)
	if r.err != "" {
		line += "\t" + strings.ReplaceAll(r.err, "\t", " ")
	}
	return line
}

// formatInfo — строки «!сервер<TAB>удачных/попыток<TAB>без сертификата»
func formatInfo(res []scanResult) []string {
	var out []string
	for _, r := range res {
		if r.tries > 0 {
			out = append(out, fmt.Sprintf("!%s\t%d/%d\t%d", r.server, r.okTry, r.tries, r.cert))
		}
	}
	return out
}

func formatRoutes(res []scanResult, names []string, rt []route) []string {
	var out []string
	for i, x := range rt {
		switch {
		case !x.known:
		case x.direct:
			out = append(out, "="+names[i]+"\t-")
		default:
			hs := make([]string, len(x.servers))
			for j, k := range x.servers {
				hs[j] = res[k].server
			}
			out = append(out, "="+names[i]+"\t"+strings.Join(hs, ","))
		}
	}
	return out
}
