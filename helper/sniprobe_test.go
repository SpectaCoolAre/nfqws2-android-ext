package main

import (
	"bytes"
	"crypto/tls"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// fakeSNIServer — TLS на 127.0.0.1, который, как фильтр, обрывает сбросом
// соединение с именем blocked (буква в букву); остальным отвечает. HTTP —
// со своим кодом
func fakeSNIServer(t *testing.T, blocked string, httpCode int) {
	t.Helper()
	cert := httptest.NewTLSServer(http.NotFoundHandler()) // ради сертификата
	cfg := &tls.Config{Certificates: cert.TLS.Certificates}
	cert.Close()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
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
				buf := make([]byte, 4096)
				c.SetReadDeadline(time.Now().Add(2 * time.Second))
				n, _ := c.Read(buf)
				if blocked != "" && bytes.Contains(buf[:n], []byte(blocked)) {
					c.(*net.TCPConn).SetLinger(0) // сброс, как у фильтра
					return
				}
				tls.Server(&prefixConn{c, buf[:n]}, cfg).Handshake()
			}(c)
		}
	}()
	hs := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(httpCode) }))
	t.Cleanup(hs.Close)
	_, tp, _ := net.SplitHostPort(ln.Addr().String())
	_, hp, _ := net.SplitHostPort(hs.Listener.Addr().String())
	sniPorts = [2]string{tp, hp}
	t.Cleanup(func() { sniPorts = [2]string{"443", "80"} })
}

type prefixConn struct {
	net.Conn
	pre []byte
}

func (p *prefixConn) Read(b []byte) (int, error) {
	if len(p.pre) > 0 {
		n := copy(b, p.pre)
		p.pre = p.pre[n:]
		return n, nil
	}
	return p.Conn.Read(b)
}

func TestSniProbeTellsNameFromAddress(t *testing.T) {
	fakeSNIServer(t, "youtube.com", 200)
	got := sniProbe("youtube.com", "127.0.0.1", 2*time.Second)
	if !strings.HasPrefix(got, "name-case\t") || !strings.Contains(got, "sni=reset") || !strings.Contains(got, "other=ok") || !strings.Contains(got, "http=200") {
		t.Fatalf("по имени, другими буквами проходит: %q", got)
	}
	if got := sniProbe("open.example", "127.0.0.1", 2*time.Second); !strings.HasPrefix(got, "none\t") {
		t.Fatalf("имя проходит — дело не в нём: %q", got)
	}
}

func TestSniProbeClosedAddress(t *testing.T) {
	ln, _ := net.Listen("tcp", "127.0.0.1:0")
	_, p, _ := net.SplitHostPort(ln.Addr().String())
	ln.Close()
	sniPorts = [2]string{p, p}
	t.Cleanup(func() { sniPorts = [2]string{"443", "80"} })
	if got := sniProbe("x.example", "127.0.0.1", time.Second); !strings.HasPrefix(got, "addr\ttcp=refused") {
		t.Fatalf("адрес закрыт: %q", got)
	}
}
