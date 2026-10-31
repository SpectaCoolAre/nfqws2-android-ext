package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/binary"
	"io"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
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
	pool := x509.NewCertPool()
	pool.AddCert(cert)
	tlsRoots = pool
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

func TestGeoScanTellsProxyFromRealAnswer(t *testing.T) {
	realIP := net.ParseIP("93.184.216.34")
	boot := fakeDNS(t, func(q []byte) []byte { return reply(q, realIP) })
	dot := fakeDoT(t, func(name string) net.IP {
		switch name {
		case "ai.example":
			return net.ParseIP("5.5.5.5") // прокси сервера
		case "game.example":
			return realIP // не обслуживает — тот же адрес, что у DNS сети
		case "zero.example":
			return net.ParseIP("0.0.0.0")
		}
		return nil
	})
	samples := []string{"ai.example", "game.example", "zero.example", "none.example"}
	res := geoScan([]string{dot}, samples, boot, 3*time.Second)
	if len(res) != 1 || !res[0].ok {
		t.Fatalf("сервер не ответил: %+v", res)
	}
	if got := string(res[0].marks); got != "psff" {
		t.Fatalf("метки %q, ждали psff (прокси, тот же адрес, 0.0.0.0, NXDOMAIN)", got)
	}
	line := formatScan(res[0], samples)
	if !strings.HasPrefix(line, dot+"\tok\t") || !strings.Contains(line, "\t1\t4\tai.example=p,game.example=s") {
		t.Fatalf("строка: %q", line)
	}
}

func TestGeoScanDeadServer(t *testing.T) {
	boot := fakeDNS(t, func(q []byte) []byte { return reply(q, net.ParseIP("1.2.3.4")) })
	ln, _ := net.Listen("tcp", "127.0.0.1:0")
	dead := ln.Addr().String()
	ln.Close() // порт закрыт — соединения нет
	res := geoScan([]string{dead}, []string{"a.example"}, boot, 2*time.Second)
	if res[0].ok || res[0].err == "" {
		t.Fatalf("закрытый порт — не ok и с ошибкой: %+v", res[0])
	}
	if l := formatScan(res[0], []string{"a.example"}); !strings.Contains(l, "\tfail\t0\t0\t1\ta.example=f\t") {
		t.Fatalf("строка: %q", l)
	}
}

func TestGeoScanResolvesServerNameViaNetworkDNS(t *testing.T) {
	boot := fakeDNS(t, func(q []byte) []byte {
		if qname(q) == "dot.example" {
			return reply(q, net.ParseIP("127.0.0.1"))
		}
		return nil // имя сервера не разрешилось бы — молчание
	})
	res := geoScan([]string{"nosuch.example:853"}, []string{"a.example"}, boot, 2*time.Second)
	if res[0].ok || !strings.Contains(res[0].err, "имя сервера") {
		t.Fatalf("неразрешённое имя сервера: %+v", res[0])
	}
}

func TestGeoScanNamesTheIssuerOfAnUntrustedCertificate(t *testing.T) {
	boot := fakeDNS(t, func(q []byte) []byte { return reply(q, net.ParseIP("1.2.3.4")) })
	dot := fakeDoT(t, func(string) net.IP { return net.ParseIP("5.5.5.5") })
	tlsRoots = x509.NewCertPool() // сертификат сервера ничем не подписан из доверенного
	dohPort = "1"                 // и DoH нет
	t.Cleanup(func() { dohPort = "443" })
	res := geoScan([]string{dot}, []string{"a.example"}, boot, 2*time.Second)
	if res[0].ok || !strings.Contains(res[0].err, "DoT: сертификат не доверен: выдан «dot» для «dot»") {
		t.Fatalf("причина: %q", res[0].err)
	}
	if !strings.Contains(res[0].err, "; DoH: ") {
		t.Fatalf("и что с DoH: %q", res[0].err)
	}
}

func TestGeoScanFallsBackToDoH(t *testing.T) {
	realIP := net.ParseIP("93.184.216.34")
	boot := fakeDNS(t, func(q []byte) []byte { return reply(q, realIP) })
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/dns-query" || r.Header.Get("Content-Type") != "application/dns-message" {
			http.Error(w, "bad", 400)
			return
		}
		q, _ := io.ReadAll(r.Body)
		ip := realIP
		if qname(q) == "ai.example" {
			ip = net.ParseIP("5.5.5.5")
		}
		w.Header().Set("Content-Type", "application/dns-message")
		w.Write(reply(q, ip))
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
	res := geoScan([]string{"127.0.0.1:1"}, []string{"ai.example", "game.example"}, boot, 3*time.Second)
	if !res[0].ok || res[0].proto != "https" || string(res[0].marks) != "ps" {
		t.Fatalf("DoH: %+v", res[0])
	}
	if l := formatScan(res[0], []string{"ai.example", "game.example"}); !strings.HasSuffix(l, "\tai.example=p,game.example=s\thttps") {
		t.Fatalf("строка: %q", l)
	}
}
