// Расстояние до сервера и до фильтра (идея — zapretgui, MIT, censorliber,
// diagnostics/path_trace.py).
//
// До сервера: соединение TCP, у которого SYN живёт k узлов (IP_TTL = k).
// Наименьшее k, при котором сервер ответил, — число узлов до него.
//
// До фильтра — через QUIC (UDP 443), если QUIC к сайту режут по имени.
// Фильтр, увидев пакет с запрещённым именем, запоминает поток и режет его
// дальше целиком. С одного сокета уходит QUIC Initial с запрещённым именем
// со сроком жизни k узлов — до сервера он не дойдёт, — а следом, с обычным
// сроком, Initial с посторонним именем. Если фильтр ближе k-го узла, он
// видел первый пакет, и второй тоже пропадёт; если дальше — сервер ответит.
// Наименьшее k, при котором ответа нет, — место фильтра. Перебор — только по
// узлам до сервера: пакет, дошедший до сервера, проверяет уже сервер.
//
// Зачем: фейк с таким сроком жизни фильтр видит, а сервер — нет (вариант
// умного режима с ip_ttl берёт его вместо постоянного 2).
//
//	nfqws2-helper -ttltrace -ip 142.250.74.14 -blocked quic_youtube.bin -open quic_google.bin
//
// Строка: «узлов-до-сервера<TAB>узел-фильтра|-<TAB>пояснение»; 0 — сервер
// не ответил ни на каком сроке.
package main

import (
	"context"
	"fmt"
	"net"
	"os"
	"sync"
	"syscall"
	"time"
)

const ttlMax = 24

// ttlPort — порт сервера (тесты подменяют)
var ttlPort = "443"

func ttlControl(ttl int) func(string, string, syscall.RawConn) error {
	return func(network, _ string, c syscall.RawConn) error {
		var serr error
		c.Control(func(fd uintptr) {
			if network == "tcp6" || network == "udp6" {
				serr = syscall.SetsockoptInt(int(fd), syscall.IPPROTO_IPV6, syscall.IPV6_UNICAST_HOPS, ttl)
			} else {
				serr = syscall.SetsockoptInt(int(fd), syscall.IPPROTO_IP, syscall.IP_TTL, ttl)
			}
		})
		return serr
	}
}

// serverHops — узлов до сервера (0 — не ответил)
func serverHops(ip string, wait time.Duration) int {
	ok := make([]bool, ttlMax+1)
	var wg sync.WaitGroup
	for k := 1; k <= ttlMax; k++ {
		wg.Add(1)
		go func(k int) {
			defer wg.Done()
			d := net.Dialer{Timeout: wait, Control: ttlControl(k)}
			ctx, cancel := context.WithTimeout(context.Background(), wait)
			defer cancel()
			if c, err := d.DialContext(ctx, "tcp", net.JoinHostPort(ip, ttlPort)); err == nil {
				c.Close()
				ok[k] = true
			}
		}(k)
	}
	wg.Wait()
	for k := 1; k <= ttlMax; k++ {
		if ok[k] {
			return k
		}
	}
	return 0
}

// quicAnswer — ответил ли сервер на open после blocked со сроком ttl (0 —
// blocked не посылать)
func quicAnswer(ip string, blocked, open []byte, ttl int, wait time.Duration) bool {
	d := net.Dialer{}
	if ttl > 0 {
		d.Control = ttlControl(ttl)
	}
	c, err := d.Dial("udp", net.JoinHostPort(ip, ttlPort))
	if err != nil {
		return false
	}
	defer c.Close()
	if ttl > 0 {
		c.Write(blocked)
		time.Sleep(50 * time.Millisecond)
		// дальше — обычный срок
		if rc, err := c.(*net.UDPConn).SyscallConn(); err == nil {
			ttlControl(64)("udp", "", rc)
		}
	}
	c.Write(open)
	c.SetReadDeadline(time.Now().Add(wait))
	buf := make([]byte, 2048)
	_, err = c.Read(buf)
	return err == nil
}

// пробы (тесты подменяют: на loopback срок жизни не убывает)
var hopsProbe = serverHops
var quicProbe = quicAnswer

func ttlTrace(ip string, blocked, open []byte, wait time.Duration) string {
	hops := hopsProbe(ip, wait)
	if hops == 0 {
		return "0\t-\tсервер не ответил"
	}
	if len(blocked) == 0 || len(open) == 0 {
		return fmt.Sprintf("%d\t-\tнет пакетов QUIC для замера фильтра", hops)
	}
	// замер имеет смысл, если QUIC с обычным именем проходит, а с
	// запрещённым — нет (его режут по имени)
	if !quicProbe(ip, nil, open, 0, wait) {
		return fmt.Sprintf("%d\t-\tQUIC к серверу не проходит", hops)
	}
	if quicProbe(ip, blocked, open, 64, wait) {
		return fmt.Sprintf("%d\t-\tQUIC по имени не режут — место фильтра так не найти", hops)
	}
	got := make([]bool, hops)
	var wg sync.WaitGroup
	for k := 1; k < hops; k++ {
		wg.Add(1)
		go func(k int) {
			defer wg.Done()
			got[k] = quicProbe(ip, blocked, open, k, wait)
		}(k)
	}
	wg.Wait()
	for k := 1; k < hops; k++ {
		if !got[k] {
			return fmt.Sprintf("%d\t%d\tфильтр — на %d-м узле", hops, k, k)
		}
	}
	return fmt.Sprintf("%d\t-\tфильтр не перед сервером", hops)
}

func runTTLTrace(ip, blockedPath, openPath string, wait time.Duration) {
	if net.ParseIP(ip) == nil {
		fmt.Fprintln(os.Stderr, "-ttltrace: нужен -ip")
		os.Exit(2)
	}
	blocked, _ := os.ReadFile(blockedPath)
	open, _ := os.ReadFile(openPath)
	fmt.Println(ttlTrace(ip, blocked, open, wait))
}
