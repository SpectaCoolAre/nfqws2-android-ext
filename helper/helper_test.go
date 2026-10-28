package main

import (
	"net"
	"testing"
	"time"
)

// fakeDNS отвечает на каждый запрос по правилу reply (nil — молчит)
func fakeDNS(t *testing.T, reply func(q []byte) []byte) string {
	t.Helper()
	pc, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { pc.Close() })
	go func() {
		buf := make([]byte, 1500)
		for {
			n, from, err := pc.ReadFrom(buf)
			if err != nil {
				return
			}
			if r := reply(append([]byte(nil), buf[:n]...)); r != nil {
				pc.WriteTo(r, from)
			}
		}
	}()
	return pc.LocalAddr().String()
}

func answer(q []byte) []byte { r := append([]byte(nil), q...); r[2] |= 0x80; r[3] = 3; return r }

func TestProbeQueryIsLocalPTR(t *testing.T) {
	q := probeQuery(0xabcd)
	if q[0] != 0xab || q[1] != 0xcd || q[5] != 1 {
		t.Fatalf("заголовок: %x", q[:12])
	}
	tail := q[len(q)-4:]
	if tail[1] != 12 || tail[3] != 1 {
		t.Fatalf("тип/класс: %x", tail)
	}
	if string(q[12:len(q)-4]) != "\x011\x010\x010\x03127\x07in-addr\x04arpa\x00" {
		t.Fatalf("имя: %q", q[12:len(q)-4])
	}
}

func TestProbeAnswered(t *testing.T) {
	addr := fakeDNS(t, answer)
	if err := probeDNS(addr, time.Second); err != nil {
		t.Fatal(err)
	}
}

func TestProbeSilentFails(t *testing.T) {
	addr := fakeDNS(t, func([]byte) []byte { return nil })
	start := time.Now()
	if err := probeDNS(addr, 400*time.Millisecond); err == nil {
		t.Fatal("молчащий DNS засчитан")
	}
	if d := time.Since(start); d > time.Second {
		t.Fatalf("ждал %v — дольше срока", d)
	}
}

func TestProbeIgnoresForeignID(t *testing.T) {
	addr := fakeDNS(t, func(q []byte) []byte { r := answer(q); r[0] ^= 0xff; return r })
	if err := probeDNS(addr, 400*time.Millisecond); err == nil {
		t.Fatal("ответ с чужим ID засчитан")
	}
}

func TestProbeRetriesLostPacket(t *testing.T) {
	n := 0
	addr := fakeDNS(t, func(q []byte) []byte {
		if n++; n == 1 {
			return nil
		}
		return answer(q)
	})
	if err := probeDNS(addr, time.Second); err != nil {
		t.Fatalf("после потерянного первого: %v", err)
	}
}

func TestProbeNobodyListens(t *testing.T) {
	pc, _ := net.ListenPacket("udp", "127.0.0.1:0")
	addr := pc.LocalAddr().String()
	pc.Close()
	if err := probeDNS(addr, 400*time.Millisecond); err == nil {
		t.Fatal("закрытый порт засчитан")
	}
}
