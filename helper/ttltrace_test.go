package main

import (
	"net"
	"strings"
	"testing"
	"time"
)

// Фильтр — на 3-м узле, сервер — на 8-м: блокированный пакет со сроком 3 и
// больше фильтр видит и режет поток, со сроком 1–2 — не видит
func TestTTLTraceFindsTheFilter(t *testing.T) {
	oh, oq := hopsProbe, quicProbe
	t.Cleanup(func() { hopsProbe, quicProbe = oh, oq })
	hopsProbe = func(string, time.Duration) int { return 8 }
	quicProbe = func(_ string, blocked, _ []byte, ttl int, _ time.Duration) bool {
		return ttl == 0 || ttl < 3
	}
	if got := ttlTrace("1.2.3.4", []byte("b"), []byte("o"), time.Second); got != "8\t3\tфильтр — на 3-м узле" {
		t.Fatalf("итог: %q", got)
	}
	// QUIC по имени не режут — места не найти
	quicProbe = func(string, []byte, []byte, int, time.Duration) bool { return true }
	if got := ttlTrace("1.2.3.4", []byte("b"), []byte("o"), time.Second); !strings.HasPrefix(got, "8\t-\tQUIC по имени не режут") {
		t.Fatalf("итог: %q", got)
	}
	hopsProbe = func(string, time.Duration) int { return 0 }
	if got := ttlTrace("1.2.3.4", nil, nil, time.Second); got != "0\t-\tсервер не ответил" {
		t.Fatalf("итог: %q", got)
	}
}

// Настоящие пробы на loopback: TCP отвечает с первого узла, UDP-сервер — на пакет
func TestTTLProbesOnLoopback(t *testing.T) {
	ln, _ := net.Listen("tcp", "127.0.0.1:0")
	t.Cleanup(func() { ln.Close() })
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			c.Close()
		}
	}()
	_, p, _ := net.SplitHostPort(ln.Addr().String())
	uc, _ := net.ListenPacket("udp", "127.0.0.1:"+p)
	if uc == nil {
		t.Skip("UDP-порт занят")
	}
	t.Cleanup(func() { uc.Close() })
	go func() {
		buf := make([]byte, 2048)
		for {
			n, a, err := uc.ReadFrom(buf)
			if err != nil {
				return
			}
			if string(buf[:n]) == "open" {
				uc.WriteTo([]byte("hi"), a)
			}
		}
	}()
	ttlPort = p
	t.Cleanup(func() { ttlPort = "443" })
	if h := serverHops("127.0.0.1", time.Second); h != 1 {
		t.Fatalf("узлов до loopback: %d", h)
	}
	if !quicAnswer("127.0.0.1", []byte("blocked"), []byte("open"), 2, time.Second) {
		t.Fatal("ответ на обычный пакет после блокированного со сроком 2")
	}
}
