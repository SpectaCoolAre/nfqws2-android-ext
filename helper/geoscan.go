// Проверка DNS с обходом геоблока (DoT): какие серверы из списка доступны в
// этой сети, как быстро отвечают и для каких сервисов отдают адрес своего
// прокси. Прокси — это ответ, не совпадающий с ответом DNS сети: такой сервер
// для этого домена действительно обходит геоблок. Ответ, совпавший с DNS
// сети, — сервер этот домен не обслуживает (dns.zapret.moe, например, берёт
// только сервисы ИИ), и с ним сайт упрётся в геоблок.
//
//	nfqws2-helper -geoscan dns.comss.one,dns.zapret.moe -samples chatgpt.com,claude.ai -boot 213.87.142.94:53
//
// Строка на сервер, через табуляцию:
//
//	сервер  ok|fail  мс  прокси  образцов  домен=p|s|f,…  tls|https|-  [ошибка]
//
// мс — соединение и рукопожатие TLS плюс первый ответ; p — прокси, s — тот же
// адрес, что у DNS сети, f — нет ответа. Серверы проверяются параллельно, по
// одному соединению на сервер, запросы к нему — в нём же друг за другом.
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
	"strings"
	"sync"
	"time"
)

// dnsQuery — запрос A с рекурсией
func dnsQuery(id uint16, name string) ([]byte, error) {
	q := []byte{byte(id >> 8), byte(id), 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0}
	for _, l := range strings.Split(strings.TrimSuffix(name, "."), ".") {
		if l == "" || len(l) > 63 {
			return nil, fmt.Errorf("плохое имя %q", name)
		}
		q = append(q, byte(len(l)))
		q = append(q, l...)
	}
	return append(q, 0, 0, 1, 0, 1), nil
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
	var ips []net.IP
	for i := 0; i < an; i++ {
		if off, err = skipName(m, off); err != nil {
			return id, rcode, ips, err
		}
		if off+10 > len(m) {
			return id, rcode, ips, errors.New("обрыв записи")
		}
		typ := binary.BigEndian.Uint16(m[off:])
		rdl := int(binary.BigEndian.Uint16(m[off+8:]))
		off += 10
		if off+rdl > len(m) {
			return id, rcode, ips, errors.New("обрыв данных")
		}
		if typ == 1 && rdl == 4 {
			ips = append(ips, net.IP(append([]byte(nil), m[off:off+4]...)))
		}
		off += rdl
	}
	return id, rcode, ips, nil
}

// udpResolve — адреса имени у обычного DNS (DNS сети), с одним повтором
func udpResolve(server, name string, wait time.Duration) ([]net.IP, error) {
	c, err := net.Dial("udp", server)
	if err != nil {
		return nil, err
	}
	defer c.Close()
	id := uint16(time.Now().UnixNano())
	q, err := dnsQuery(id, name)
	if err != nil {
		return nil, err
	}
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
			rid, rcode, ips, perr := dnsAnswerA(buf[:n])
			if rid != id || buf[2]&0x80 == 0 {
				continue
			}
			if perr != nil {
				return nil, perr
			}
			if rcode != 0 {
				return nil, fmt.Errorf("rcode %d", rcode)
			}
			return ips, nil
		}
	}
	return nil, errors.New("нет ответа")
}

// junkIP — ответ, который ничего не обходит: 0.0.0.0, локальные и частные
// адреса (так некоторые DNS «блокируют» домен)
func junkIP(ip net.IP) bool {
	return ip.IsUnspecified() || ip.IsLoopback() || ip.IsPrivate() || ip.IsLinkLocalUnicast()
}

// classify — p: прокси (адреса не пересекаются с адресами DNS сети), s: тот
// же адрес, f: пусто или мусор
func classify(got, real []net.IP) byte {
	ok := false
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
	}
	if !ok {
		return 'f'
	}
	return 'p'
}

type scanResult struct {
	server string
	ok     bool
	ms     int64
	marks  []byte
	proto  string // tls — DoT, https — DoH (DoT не прошёл), "-" — ни один
	err    string
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
	r := scanResult{server: server, marks: make([]byte, n), proto: "-"}
	for i := range r.marks {
		r.marks[i] = 'f'
	}
	return r
}

// dotScan — одно соединение DoT с сервером и запросы по образцам
func dotScan(server string, samples []string, real map[string][]net.IP, boot string, wait time.Duration) scanResult {
	r := newResult(server, len(samples))
	host, port := server, "853"
	if h, p, err := net.SplitHostPort(server); err == nil {
		host, port = h, p
	}
	deadline := time.Now().Add(wait)
	ctx, cancel := context.WithDeadline(context.Background(), deadline)
	defer cancel()
	addr, err := serverAddr(host, boot, wait/3)
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
	c.SetDeadline(deadline)
	base := uint16(time.Now().UnixNano())
	for i, s := range samples {
		q, err := dnsQuery(base+uint16(i), s)
		if err != nil {
			continue
		}
		msg := make([]byte, 2+len(q))
		binary.BigEndian.PutUint16(msg, uint16(len(q)))
		copy(msg[2:], q)
		if _, err := c.Write(msg); err != nil {
			r.err = err.Error()
			return r
		}
	}
	lb := make([]byte, 2)
	for got := 0; got < len(samples); got++ {
		if _, err := io.ReadFull(c, lb); err != nil {
			if got == 0 {
				r.err = err.Error()
				return r
			}
			break
		}
		m := make([]byte, binary.BigEndian.Uint16(lb))
		if _, err := io.ReadFull(c, m); err != nil {
			break
		}
		if got == 0 {
			r.ok, r.proto = true, "tls"
			r.ms = time.Since(t0).Milliseconds()
		}
		id, rcode, ips, err := dnsAnswerA(m)
		i := int(id - base)
		if i < 0 || i >= len(samples) || err != nil || rcode != 0 {
			continue
		}
		r.marks[i] = classify(ips, real[samples[i]])
	}
	return r
}

// dohScan — то же по DoH (https://сервер/dns-query, POST), одним соединением;
// так ходит и dnsproxy модуля, и это выручает, если в сети закрыт или
// подменён порт 853
func dohScan(server string, samples []string, real map[string][]net.IP, boot string, wait time.Duration) scanResult {
	r := newResult(server, len(samples))
	host, _, err := net.SplitHostPort(server)
	if err != nil {
		host = server
	}
	deadline := time.Now().Add(wait)
	addr, err := serverAddr(host, boot, wait/3)
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
	t0 := time.Now()
	for i, s := range samples {
		if time.Now().After(deadline) {
			break
		}
		q, err := dnsQuery(0, s)
		if err != nil {
			continue
		}
		req, _ := http.NewRequest("POST", "https://"+host+"/dns-query", bytes.NewReader(q))
		req.Header.Set("Content-Type", "application/dns-message")
		req.Header.Set("Accept", "application/dns-message")
		resp, err := cl.Do(req)
		if err != nil {
			if !r.ok {
				r.err = certErr(err)
				return r
			}
			continue
		}
		m, _ := io.ReadAll(io.LimitReader(resp.Body, 65535))
		resp.Body.Close()
		if resp.StatusCode != 200 {
			if !r.ok {
				r.err = "DoH: ответ " + resp.Status
				return r
			}
			continue
		}
		if !r.ok {
			r.ok, r.proto = true, "https"
			r.ms = time.Since(t0).Milliseconds()
		}
		_, rcode, ips, err := dnsAnswerA(m)
		if err == nil && rcode == 0 {
			r.marks[i] = classify(ips, real[s])
		}
	}
	return r
}

// dohPort — порт DoH (тесты подменяют)
var dohPort = "443"

// scanServer — DoT; не прошёл — DoH. Обе ошибки — в итог
func scanServer(server string, samples []string, real map[string][]net.IP, boot string, wait time.Duration) scanResult {
	r := dotScan(server, samples, real, boot, wait)
	if r.ok {
		return r
	}
	h := dohScan(server, samples, real, boot, wait)
	if h.ok {
		return h
	}
	r.err = "DoT: " + r.err + "; DoH: " + h.err
	return r
}

// geoScan — все серверы разом; эталон — ответы DNS сети на образцы
func geoScan(servers, samples []string, boot string, wait time.Duration) []scanResult {
	real := make(map[string][]net.IP)
	var mu sync.Mutex
	var wg sync.WaitGroup
	for _, s := range samples {
		wg.Add(1)
		go func(s string) {
			defer wg.Done()
			ips, _ := udpResolve(boot, s, wait/2)
			mu.Lock()
			real[s] = ips
			mu.Unlock()
		}(s)
	}
	wg.Wait()
	res := make([]scanResult, len(servers))
	for i, s := range servers {
		wg.Add(1)
		go func(i int, s string) {
			defer wg.Done()
			res[i] = scanServer(s, samples, real, boot, wait)
		}(i, s)
	}
	wg.Wait()
	return res
}

func formatScan(r scanResult, samples []string) string {
	st, p := "fail", 0
	if r.ok {
		st = "ok"
	}
	parts := make([]string, len(samples))
	for i, s := range samples {
		parts[i] = s + "=" + string(r.marks[i])
		if r.marks[i] == 'p' {
			p++
		}
	}
	line := fmt.Sprintf("%s\t%s\t%d\t%d\t%d\t%s\t%s", r.server, st, r.ms, p, len(samples), strings.Join(parts, ","), r.proto)
	if r.err != "" {
		line += "\t" + strings.ReplaceAll(r.err, "\t", " ")
	}
	return line
}
