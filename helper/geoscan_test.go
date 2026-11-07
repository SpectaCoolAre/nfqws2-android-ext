package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/binary"
	"fmt"
	"io"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// qname — имя из запроса
func qname(q []byte) string {
	var parts []string
	for off := 12; off < len(q) && q[off] != 0; off += 1 + int(q[off]) {
		parts = append(parts, string(q[off+1:off+1+int(q[off])]))
	}
	return strings.Join(parts, ".")
}

// reply — ответ с одной записью A (ip == nil — NXDOMAIN)
func reply(q []byte, ip net.IP) []byte {
	r := append([]byte(nil), q...)
	r[2] |= 0x80
	if ip == nil {
		r[3] = 3
		return r
	}
	r[3] = 0
	r[7] = 1 // ANCOUNT
	return append(r, 0xc0, 12, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, ip[12], ip[13], ip[14], ip[15])
}

// fakeDoT — сервер DoT на 127.0.0.1 со своим сертификатом (его корень
// подставляется в tlsRoots); answer — адрес для имени
func fakeDoT(t *testing.T, answer func(name string) net.IP) string {
	t.Helper()
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	tpl := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "dot"},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour),
		IPAddresses: []net.IP{net.ParseIP("127.0.0.1")}, IsCA: true, BasicConstraintsValid: true,
		KeyUsage: x509.KeyUsageCertSign | x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}}
	der, err := x509.CreateCertificate(rand.Reader, tpl, tpl, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	cert, _ := x509.ParseCertificate(der)
	if tlsRoots == nil { // несколько серверов в одном тесте — один пул
		tlsRoots = x509.NewCertPool()
	}
	tlsRoots.AddCert(cert)
	t.Cleanup(func() { tlsRoots = nil })
	ln, err := tls.Listen("tcp", "127.0.0.1:0", &tls.Config{Certificates: []tls.Certificate{{Certificate: [][]byte{der}, PrivateKey: key}}})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go func(c net.Conn) {
				defer c.Close()
				lb := make([]byte, 2)
				for {
					if _, err := io.ReadFull(c, lb); err != nil {
						return
					}
					q := make([]byte, binary.BigEndian.Uint16(lb))
					if _, err := io.ReadFull(c, q); err != nil {
						return
					}
					r := reply(q, answer(qname(q)))
					out := make([]byte, 2+len(r))
					binary.BigEndian.PutUint16(out, uint16(len(r)))
					copy(out[2:], r)
					c.Write(out)
				}
			}(c)
		}
	}()
	return ln.Addr().String()
}

// replyTXT — ответ с одной записью TXT
func replyTXT(q []byte, txt string) []byte {
	r := append([]byte(nil), q...)
	r[2] |= 0x80
	r[3] = 0
	r[7] = 1
	rd := append([]byte{byte(len(txt))}, txt...)
	r = append(r, 0xc0, 12, 0, 16, 0, 1, 0, 0, 0, 60, byte(len(rd)>>8), byte(len(rd)))
	return append(r, rd...)
}

// asOf — номер AS по первому октету (для поддельного DNS сети)
var asOf = map[string]string{"93": "15133", "54": "14618", "3": "14618", "81": "51852", "179": "213520", "206": "205431", "83": "41745", "5": "64500", "127": "64501"}

// netDNS — поддельный DNS сети: эталонные адреса (ref; нет — NXDOMAIN) и
// номера AS (TXT …origin.asn.cymru.com) по asOf; asOK=false — служба молчит
func netDNS(t *testing.T, ref func(name string) net.IP, asOK bool, txt *int32) string {
	t.Helper()
	return fakeDNS(t, func(q []byte) []byte {
		n := qname(q)
		if strings.HasSuffix(n, ".origin.asn.cymru.com") {
			if txt != nil {
				atomic.AddInt32(txt, 1)
			}
			oct := strings.Split(n, ".")
			if as, ok := asOf[oct[3]]; ok && asOK {
				return replyTXT(q, as+" | "+oct[3]+".0.0.0/8 | US | arin | 2014-10-23")
			}
			return reply(q, nil)
		}
		return reply(q, ref(n))
	})
}

func ip(s string) net.IP { return net.ParseIP(s) }

func TestGeoScanTellsProxyFromRealAnswer(t *testing.T) {
	boot := netDNS(t, func(string) net.IP { return ip("93.184.216.34") }, true, nil)
	dot := fakeDoT(t, func(name string) net.IP {
		switch name {
		case "ai.example":
			return ip("5.5.5.5") // прокси сервера, чужая сеть
		case "game.example":
			return ip("93.184.216.34") // не обслуживает — тот же адрес
		case "cdn.example":
			return ip("93.1.2.3") // другой адрес той же сети — тоже не прокси
		case "zero.example":
			return ip("0.0.0.0")
		}
		return nil
	})
	names := []string{"ai.example", "game.example", "cdn.example", "zero.example", "none.example"}
	res := geoScan([]string{dot}, names, boot, 6*time.Second)
	if !res[0].ok || string(res[0].marks) != "pssff" {
		t.Fatalf("метки %q, ждали pssff: %+v", res[0].marks, res[0])
	}
	if l := formatScan(res[0]); !strings.HasPrefix(l, dot+"\tok\t") || !strings.HasSuffix(l, "\t1\t5\t1\ttls") {
		t.Fatalf("строка: %q", l)
	}
}

// Служба номеров AS не ответила: адрес, общий для нескольких сайтов, —
// прокси; свой у одного сайта — считаем настоящим (так безопаснее)
func TestGeoScanUnknownNetwork(t *testing.T) {
	boot := netDNS(t, func(string) net.IP { return ip("93.184.216.34") }, false, nil)
	dot := fakeDoT(t, func(name string) net.IP {
		if name == "lone.example" {
			return ip("54.1.2.3")
		}
		return ip("179.254.166.174")
	})
	names := []string{"a.example", "b.example", "lone.example"}
	if res := geoScan([]string{dot}, names, boot, 6*time.Second); string(res[0].marks) != "pps" {
		t.Fatalf("метки %q, ждали pps", res[0].marks)
	}
}

// Как на устройстве: malw — один общий прокси на всё (Clash of Clans через
// него попадал на Brawl Stars), Comss — свой адрес для игры и общий пул для
// ИИ, zapret.moe — прокси только для ИИ. Игра — к Comss, и только к нему
func TestGeoScanRoutesEachDomainToFittingServers(t *testing.T) {
	real := map[string]string{"chatgpt.com": "93.0.0.1", "claude.ai": "93.0.0.2", "gamea.clashofclans.com": "54.0.0.1",
		"game.clashofclans.com": "54.0.0.2", "intel.com": "93.0.0.3"}
	boot := netDNS(t, func(n string) net.IP { return ip(real[n]) }, true, nil)
	malw := fakeDoT(t, func(n string) net.IP {
		if n == "intel.com" {
			return ip(real[n])
		}
		return ip("179.254.166.174")
	})
	comss := fakeDoT(t, func(n string) net.IP {
		switch n {
		case "gamea.clashofclans.com", "game.clashofclans.com":
			return ip("81.17.20.86")
		case "chatgpt.com", "claude.ai":
			return ip("206.223.251.18")
		}
		return ip(real[n])
	})
	zapret := fakeDoT(t, func(n string) net.IP {
		if n == "chatgpt.com" {
			return ip("83.217.211.149")
		}
		return ip(real[n])
	})
	names := []string{"chatgpt.com", "claude.ai", "gamea.clashofclans.com", "game.clashofclans.com", "intel.com"}
	servers := []string{malw, comss, zapret}
	res := geoScan(servers, names, boot, 6*time.Second)
	for k, want := range []string{"pppps", "pppps", "pssss"} {
		if string(res[k].marks) != want {
			t.Fatalf("%s: метки %q, ждали %q", servers[k], res[k].marks, want)
		}
	}
	if res[0].share[2] != 3 || res[1].share[2] != 1 || res[1].share[0] != 2 || res[2].share[0] != 1 {
		t.Fatalf("общие адреса: malw %v, comss %v, zapret %v", res[0].share, res[1].share, res[2].share)
	}
	got := strings.Join(formatRoutes(res, names, planRoutes(res, len(names), 3, nil)), "|")
	want := strings.Join([]string{
		"=chatgpt.com\t" + zapret,           // свой адрес — только он
		"=claude.ai\t" + comss + "," + malw, // общие: сначала тот, где сайтов меньше
		"=gamea.clashofclans.com\t" + comss,
		"=game.clashofclans.com\t" + comss,
		"=intel.com\t-", // никто не обходит — в DNS сети
	}, "|")
	if got != want {
		t.Fatalf("маршруты:\n%s\nждали:\n%s", strings.ReplaceAll(got, "|", "\n"), strings.ReplaceAll(want, "|", "\n"))
	}
	if l := formatScan(res[1]); !strings.Contains(l, "\t4\t5\t2\ttls") {
		t.Fatalf("Comss: обходит 4, своим адресом 2: %q", l)
	}
}

func TestSiteOf(t *testing.T) {
	for in, want := range map[string]string{"gamea.clashofclans.com": "clashofclans.com", "claude.ai": "claude.ai",
		"a.b.bbc.co.uk": "bbc.co.uk", "ai": "ai", "x.y.example.com.": "example.com"} {
		if got := siteOf(in); got != want {
			t.Errorf("siteOf(%q) = %q, ждали %q", in, got, want)
		}
	}
}

// Весь список (сотни доменов) — пачками в одном соединении
func TestGeoScanManyDomainsOverOneConnection(t *testing.T) {
	boot := netDNS(t, func(string) net.IP { return ip("93.184.216.34") }, true, nil)
	dot := fakeDoT(t, func(string) net.IP { return ip("5.5.5.5") })
	names := make([]string, 180)
	for i := range names {
		names[i] = "d" + strconv.Itoa(i) + ".example"
	}
	res := geoScan([]string{dot}, names, boot, 8*time.Second)
	if !strings.HasSuffix(formatScan(res[0]), "\t180\t180\t0\ttls") {
		t.Fatalf("все 180 — прокси, общий адрес: %q", formatScan(res[0]))
	}
}

// Номера AS кэшируются: повторная проверка их не спрашивает
func TestGeoScanCachesNetworkNumbers(t *testing.T) {
	asnCache = t.TempDir() + "/asn.cache"
	t.Cleanup(func() { asnCache = "" })
	var txt int32
	boot := netDNS(t, func(string) net.IP { return ip("93.184.216.34") }, true, &txt)
	dot := fakeDoT(t, func(string) net.IP { return ip("5.5.5.5") })
	geoScan([]string{dot}, []string{"a.example"}, boot, 6*time.Second)
	if atomic.LoadInt32(&txt) != 2 {
		t.Fatalf("запросов номеров AS: %d, ждали 2 (эталон и прокси)", txt)
	}
	res := geoScan([]string{dot}, []string{"a.example"}, boot, 6*time.Second)
	if atomic.LoadInt32(&txt) != 2 || string(res[0].marks) != "p" {
		t.Fatalf("из кэша: запросов %d, метки %q", txt, res[0].marks)
	}
}

func TestGeoScanDeadServer(t *testing.T) {
	boot := netDNS(t, func(string) net.IP { return ip("1.2.3.4") }, true, nil)
	ln, _ := net.Listen("tcp", "127.0.0.1:0")
	dead := ln.Addr().String()
	ln.Close() // порт закрыт — соединения нет
	res := geoScan([]string{dead}, []string{"a.example"}, boot, 6*time.Second)
	if res[0].ok || res[0].err == "" {
		t.Fatalf("закрытый порт — не ok и с ошибкой: %+v", res[0])
	}
	if l := formatScan(res[0]); !strings.Contains(l, "\tfail\t0\t0\t1\t0\t-\t") {
		t.Fatalf("строка: %q", l)
	}
	if r := formatRoutes(res, []string{"a.example"}, planRoutes(res, 1, 3, nil)); len(r) != 0 {
		t.Fatalf("нет данных — нет маршрута: %q", r)
	}
}

func TestGeoScanResolvesServerNameViaNetworkDNS(t *testing.T) {
	boot := fakeDNS(t, func(q []byte) []byte { return nil })
	res := geoScan([]string{"nosuch.example:853"}, []string{"a.example"}, boot, 6*time.Second)
	if res[0].ok || !strings.Contains(res[0].err, "имя сервера") {
		t.Fatalf("неразрешённое имя сервера: %+v", res[0])
	}
}

func TestGeoScanNamesTheIssuerOfAnUntrustedCertificate(t *testing.T) {
	boot := netDNS(t, func(string) net.IP { return ip("1.2.3.4") }, true, nil)
	dot := fakeDoT(t, func(string) net.IP { return ip("5.5.5.5") })
	tlsRoots = x509.NewCertPool() // сертификат сервера ничем не подписан из доверенного
	dohPort = "1"                 // и DoH нет
	t.Cleanup(func() { dohPort = "443" })
	res := geoScan([]string{dot}, []string{"a.example"}, boot, 6*time.Second)
	if res[0].ok || !strings.Contains(res[0].err, "DoT: сертификат не доверен: выдан «dot» для «dot»") {
		t.Fatalf("причина: %q", res[0].err)
	}
	if !strings.Contains(res[0].err, "; DoH: ") {
		t.Fatalf("и что с DoH: %q", res[0].err)
	}
}

func TestGeoScanFallsBackToDoH(t *testing.T) {
	boot := netDNS(t, func(string) net.IP { return ip("93.184.216.34") }, true, nil)
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/dns-query" || r.Header.Get("Content-Type") != "application/dns-message" {
			http.Error(w, "bad", 400)
			return
		}
		q, _ := io.ReadAll(r.Body)
		a := ip("93.184.216.34")
		if strings.HasPrefix(qname(q), "ai") {
			a = ip("5.5.5.5")
		}
		w.Header().Set("Content-Type", "application/dns-message")
		w.Write(reply(q, a))
	}))
	t.Cleanup(srv.Close)
	pool := x509.NewCertPool()
	pool.AddCert(srv.Certificate())
	tlsRoots = pool
	t.Cleanup(func() { tlsRoots = nil })
	_, port, _ := net.SplitHostPort(srv.Listener.Addr().String())
	dohPort = port
	t.Cleanup(func() { dohPort = "443" })
	// DoT на 127.0.0.1:1 закрыт — проверка уходит на DoH того же сервера
	names := []string{"ai.example", "game.example", "ai2.example"}
	res := geoScan([]string{"127.0.0.1:1"}, names, boot, 6*time.Second)
	if !res[0].ok || res[0].proto != "https" || string(res[0].marks) != "psp" {
		t.Fatalf("DoH: %+v", res[0])
	}
	if l := formatScan(res[0]); !strings.HasSuffix(l, "\t2\t3\t0\thttps") {
		t.Fatalf("строка: %q", l)
	}
}

// Частая проверка по нескольким доменам: адрес прокси, общий по полной
// проверке, остаётся общим, хотя в ней он у одного домена
func TestGeoScanHotUsesSharedAddressesOfTheFullCheck(t *testing.T) {
	real := map[string]string{"chatgpt.com": "93.0.0.1", "claude.ai": "93.0.0.2", "gamea.clashofclans.com": "54.0.0.1"}
	boot := netDNS(t, func(n string) net.IP { return ip(real[n]) }, true, nil)
	malw := fakeDoT(t, func(n string) net.IP { return ip("179.254.166.174") })
	comss := fakeDoT(t, func(n string) net.IP {
		if n == "gamea.clashofclans.com" {
			return ip("81.17.20.86")
		}
		return ip(real[n])
	})
	full := geoScan([]string{malw, comss}, []string{"chatgpt.com", "claude.ai", "gamea.clashofclans.com"}, boot, 6*time.Second)
	sh := formatShared(full, []string{"chatgpt.com", "claude.ai", "gamea.clashofclans.com"})
	if len(sh) != 1 || sh[0] != "+"+malw+"\t179.254.166.174\t3" {
		t.Fatalf("общие адреса: %q", sh)
	}
	path := t.TempDir() + "/full.tsv"
	os.WriteFile(path, []byte(strings.Join(sh, "\n")+"\n"), 0644)
	knownShare = loadShared(path)
	t.Cleanup(func() { knownShare = nil })
	hot := []string{"gamea.clashofclans.com"}
	res := geoScan([]string{malw, comss}, hot, boot, 6*time.Second)
	if res[0].share[0] != 3 || res[1].share[0] != 1 {
		t.Fatalf("malw — общий (3), Comss — свой (1): %d %d", res[0].share[0], res[1].share[0])
	}
	if r := formatRoutes(res, hot, planRoutes(res, 1, 3, nil)); len(r) != 1 || r[0] != "=gamea.clashofclans.com\t"+comss {
		t.Fatalf("игра — к Comss: %q", r)
	}
}

// Сервер «через раз» (ответил не на все попытки) — в маршруте после надёжного,
// даже если быстрее
func TestPlanRoutesPutsFlakyServersLast(t *testing.T) {
	mk := func(name string, ms int64, okTry int) scanResult {
		return scanResult{server: name, ok: true, ms: ms, marks: []byte("p"), share: []int{2}, tries: 3, okTry: okTry}
	}
	res := []scanResult{mk("fast-flaky", 10, 2), mk("slow-stable", 90, 3)}
	if got := formatRoutes(res, []string{"a.example"}, planRoutes(res, 1, 3, nil)); got[0] != "=a.example\tslow-stable,fast-flaky" {
		t.Fatalf("маршрут: %q", got)
	}
	if got := formatInfo(res); got[0] != "!fast-flaky\t2/3\t0" {
		t.Fatalf("строка о попытках: %q", got)
	}
}

// Проверка по факту: прокси, который не отдаёт настоящий сертификат сайта, —
// не для этого домена, если у другого сервера сертификат настоящий; у
// домена без HTTPS (никто не прошёл) — ничего не меняется
func TestVerifyRoutesDropsProxiesWithoutTheRealCertificate(t *testing.T) {
	good := map[string]bool{"5.5.5.5 gemini.google.com": true}
	orig := verifyProxy
	verifyProxy = func(ip net.IP, host string, _ time.Duration) bool { return good[ip.String()+" "+host] }
	t.Cleanup(func() { verifyProxy = orig })
	mk := func(name, a1, a2 string) scanResult {
		return scanResult{server: name, ok: true, marks: []byte("pp"), share: []int{1, 1},
			ans: [][]net.IP{{ip(a1)}, {ip(a2)}}, tries: 3, okTry: 3}
	}
	res := []scanResult{mk("dns-ai", "5.5.5.5", "81.17.20.86"), mk("magicdns", "2.56.175.196", "81.17.20.87")}
	names := []string{"gemini.google.com", "gamea.clashofclans.com"}
	verifyRoutes(res, names, time.Second)
	if string(res[0].marks) != "pp" || string(res[1].marks) != "cp" || res[1].cert != 1 {
		t.Fatalf("метки: %q %q", res[0].marks, res[1].marks)
	}
	if r := formatRoutes(res, names, planRoutes(res, 2, 3, nil)); r[0] != "=gemini.google.com\tdns-ai" {
		t.Fatalf("Gemini — только к рабочему: %q", r)
	}
}

func TestVerifyProxyChecksTheSiteCertificate(t *testing.T) {
	srv := httptest.NewTLSServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}))
	t.Cleanup(srv.Close)
	pool := x509.NewCertPool()
	pool.AddCert(srv.Certificate())
	tlsRoots = pool
	t.Cleanup(func() { tlsRoots = nil })
	_, port, _ := net.SplitHostPort(srv.Listener.Addr().String())
	proxyTLSPort = port
	t.Cleanup(func() { proxyTLSPort = "443" })
	if !verifyProxy(ip("127.0.0.1"), "example.com", 2*time.Second) {
		t.Fatal("сертификат на example.com — настоящий")
	}
	if verifyProxy(ip("127.0.0.1"), "gemini.google.com", 2*time.Second) {
		t.Fatal("сертификат на другое имя — не настоящий")
	}
}

// Сеть перехватывает обычный DNS: «ответ 8.8.8.8» пришёл от резолвера сети
// оператора, а не Google
func TestWhoamiDetectsInterception(t *testing.T) {
	boot := netDNS(t, func(n string) net.IP {
		if n == "whoami.akamai.net" {
			return ip("93.1.1.1") // резолвер оператора
		}
		return ip("93.184.216.34")
	}, true, nil)
	orig := whoamiTargets
	whoamiTargets = []whoAns{{name: "google", server: boot, as: "15169"}} // «8.8.8.8» отвечает тот же резолвер
	whoamiCheck = true
	t.Cleanup(func() { whoamiTargets = orig; whoamiCheck = false; lastWhoami = "" })
	dot := fakeDoT(t, func(string) net.IP { return ip("5.5.5.5") })
	geoScan([]string{dot}, []string{"a.example"}, boot, 6*time.Second)
	if lastWhoami != "?whoami\tnet=93.1.1.1/15133\tgoogle=93.1.1.1/15133\tintercept=1" {
		t.Fatalf("итог: %q", lastWhoami)
	}
	whoamiTargets = []whoAns{{name: "google", server: boot, as: "15133"}}
	geoScan([]string{dot}, []string{"a.example"}, boot, 6*time.Second)
	if !strings.HasSuffix(lastWhoami, "intercept=0") {
		t.Fatalf("ответ из своей сети — не перехват: %q", lastWhoami)
	}
}

func TestSiteRefuses(t *testing.T) {
	for _, c := range []struct {
		resp string
		bad  bool
	}{
		{"HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n<html>Gemini</html>", false},
		{"HTTP/1.1 302 Found\r\nLocation: https://www.google.com/sorry/index?continue=x\r\n\r\n", true},
		{"HTTP/1.1 429 Too Many Requests\r\n\r\n", true},
		{"HTTP/1.1 200 OK\r\n\r\nOur systems have detected unusual traffic from your computer network.", true},
		{"HTTP/1.1 200 OK\r\n\r\nGemini isn't supported in your country yet", true},
		{"HTTP/1.1 302 Found\r\nLocation: https://gemini.google.com/app\r\n\r\n", false},
		{"", false},
	} {
		if got := siteRefuses(c.resp); got != c.bad {
			t.Errorf("%q: %v, ждали %v", c.resp, got, c.bad)
		}
	}
}

// Дома DNS сети — роутер, который сам обходит геоблок (в его настройках
// Comss): он отдаёт адреса прокси. Эталон «настоящих» адресов — честный DNS
// (refServers), а не роутер: иначе сервер с настоящим адресом выглядел бы
// обходящим, а Comss — нет (так Gemini и Clash of Clans дома шли не туда)
func TestGeoScanReferenceIsNotTheBypassingRouter(t *testing.T) {
	real := map[string]string{"gemini.google.com": "142.250.74.14", "chatgpt.com": "104.18.32.47"}
	router := netDNS(t, func(string) net.IP { return ip("206.223.251.18") }, true, nil) // роутер с Comss
	honest := netDNS(t, func(n string) net.IP { return ip(real[n]) }, true, nil)
	comss := fakeDoT(t, func(string) net.IP { return ip("206.223.251.18") })
	plain := fakeDoT(t, func(n string) net.IP { return ip(real[n]) }) // ничего не обходит
	names := []string{"gemini.google.com", "chatgpt.com"}
	refServers = []string{honest}
	defer func() { refServers = nil }()
	res := geoScan([]string{comss, plain}, names, router, 6*time.Second)
	if string(res[0].marks) != "pp" || string(res[1].marks) != "ss" {
		t.Fatalf("с честным эталоном: Comss %q (ждали pp), без обхода %q (ждали ss)", res[0].marks, res[1].marks)
	}
	// честный DNS не ответил — эталон из DNS сети, как раньше: домены не
	// остаются без эталона
	refServers = []string{"127.0.0.1:1"}
	if r := refAnswers(names, router, 2*time.Second); len(r[0]) != 1 || !r[0][0].Equal(ip("206.223.251.18")) {
		t.Fatalf("запасной эталон: %v", r)
	}
}

// Домен группы сайтов — ко всем, кто его обходит: и к серверам с общим
// адресом прокси, хотя у одного для него свой, и больше max
func TestPlanRoutesGroupDomainKeepsAllCandidates(t *testing.T) {
	mk := func(name string, ms int64, share int) scanResult {
		return scanResult{server: name, ok: true, ms: ms, marks: []byte("p"), share: []int{share}}
	}
	res := []scanResult{mk("wlrus", 80, 1), mk("magicdns", 120, 9), mk("malw", 170, 9), mk("dagami", 300, 9)}
	names := []string{"signaler-pa.clients6.google.com"}
	if r := formatRoutes(res, names, planRoutes(res, 1, 3, nil)); r[0] != "=signaler-pa.clients6.google.com\twlrus" {
		t.Fatalf("без группы — только свой адрес: %q", r)
	}
	f := filepath.Join(t.TempDir(), "groups.list")
	if err := os.WriteFile(f, []byte("# группы\ngoogle google.com googleapis.com google\nopenai chatgpt.com\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	w, err := groupWide(f, []string{"signaler-pa.clients6.google.com", "gemini.google", "notgoogle.com", "chatgpt.com"})
	if err != nil || fmt.Sprint(w) != "[true true false true]" {
		t.Fatalf("группы: %v %v", w, err)
	}
	if r := formatRoutes(res, names, planRoutes(res, 1, 3, w[:1])); r[0] != "=signaler-pa.clients6.google.com\twlrus,magicdns,malw,dagami" {
		t.Fatalf("в группе — все: %q", r)
	}
}

// DNS сети (роутер) сам отдаёт адрес прокси — домен остаётся ему; заглушка
// провайдера и настоящий адрес обходом не считаются
func TestNetBypassMarks(t *testing.T) {
	ip := func(s string) []net.IP { return []net.IP{net.ParseIP(s)} }
	res := []scanResult{{ok: true, marks: []byte{'p', 'p', 's', 'p'},
		ans: [][]net.IP{ip("45.114.60.100"), ip("45.114.60.100"), ip("142.250.1.1"), ip("206.223.246.75")}}}
	real := [][]net.IP{ip("142.250.1.1"), ip("142.250.1.2"), ip("142.250.1.1"), ip("142.250.1.3")}
	netAns := [][]net.IP{ip("45.114.60.100"), ip("188.186.157.49"), ip("142.250.1.1"), ip("206.223.246.9")}
	got := netBypassMarks(netAns, real, res)
	// последний — соседний адрес в той же /24, что и прокси: сайт на том же
	// облаке, а не обход
	want := []bool{true, false, false, false}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("домен %d: %v, ждали %v", i, got[i], want[i])
		}
	}
	rt := applyNetBypass([]route{{servers: []int{0}, known: true}, {servers: []int{0}, known: true}}, got)
	out := formatRoutes(res, []string{"gemini.google.com", "facebook.com"}, rt)
	if len(out) != 2 || out[0] != "=gemini.google.com\t-\tnet" || out[1] != "=facebook.com\t" {
		t.Fatalf("маршруты: %q", out)
	}
}
