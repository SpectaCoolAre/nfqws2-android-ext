// Почему сайт не открылся: режут по имени сайта или закрыт сам адрес. Три
// дешёвые пробы к тому же адресу (идея — zapretgui, MIT, censorliber,
// diagnostics/block_cause.py):
//
//  1. Тот же адрес, другое имя. В начале TLS браузер открытым текстом
//     называет сайт (SNI). Если с именем сайта соединение рвётся, а с чужим
//     именем или вовсе без имени тот же сервер отвечает — режут по имени.
//     Ответом считается и отказ сервера («не знаю такого имени»): раз он
//     дошёл, дорога открыта. Отдельно — то же имя другими буквами
//     (GOOGLEVIDEO.COM): сервер регистр не различает, а фильтр, ищущий имя
//     буква в букву, его пропустит.
//
//  2. Обычный HTTP, порт 80: часть операторов вместо сайта отдаёт страницу о
//     блокировке или код 451.
//
//  3. Само соединение TCP — когда адрес не принимает его вовсе.
//
//     nfqws2-helper -sniprobe youtube.com -ip 142.250.74.14
//
// Строка: «причина<TAB>tcp=… sni=… other=… none=… case=… http=…»; причина —
// addr (адрес закрыт), name (режут по имени), name-case (по имени, но
// другими буквами проходит), tls (рвут любое TLS к адресу), none (эти пробы
// проходят — дело не в имени и не в адресе). Каждая проба — ok, reset,
// timeout, closed, refused или ошибка; http — код ответа или «-».
package main

import (
	"bufio"
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"strings"
	"syscall"
	"time"
)

// sniOther — постороннее имя: сайт, который нигде не блокируют
const sniOther = "example.com"

// sniPorts — порты TLS и HTTP (тесты подменяют)
var sniPorts = [2]string{"443", "80"}

func netReason(err error) string {
	var ne net.Error
	switch {
	case err == nil:
		return "ok"
	case errors.Is(err, syscall.ECONNRESET):
		return "reset"
	case errors.Is(err, syscall.ECONNREFUSED):
		return "refused"
	case errors.As(err, &ne) && ne.Timeout():
		return "timeout"
	case errors.Is(err, io.EOF), errors.Is(err, io.ErrUnexpectedEOF):
		return "closed"
	}
	return "error"
}

// tlsReach — дошло ли начало TLS с этим именем до сервера: рукопожатие или
// отказ самого сервера (alert) — да; сброс, обрыв, тишина — нет
func tlsReach(ip, name string, wait time.Duration) string {
	c, err := net.DialTimeout("tcp", net.JoinHostPort(ip, sniPorts[0]), wait)
	if err != nil {
		return netReason(err)
	}
	defer c.Close()
	c.SetDeadline(time.Now().Add(wait))
	t := tls.Client(c, &tls.Config{ServerName: name, InsecureSkipVerify: true, MinVersion: tls.VersionTLS12})
	err = t.HandshakeContext(context.Background())
	var ae tls.AlertError
	var re tls.RecordHeaderError
	if err == nil || errors.As(err, &ae) || errors.As(err, &re) || strings.Contains(fmt.Sprint(err), "remote error") {
		return "ok"
	}
	return netReason(err)
}

// httpStatus — код ответа на GET http://host/ к этому адресу или «-»
func httpStatus(ip, host string, wait time.Duration) string {
	c, err := net.DialTimeout("tcp", net.JoinHostPort(ip, sniPorts[1]), wait)
	if err != nil {
		return "-"
	}
	defer c.Close()
	c.SetDeadline(time.Now().Add(wait))
	fmt.Fprintf(c, "GET / HTTP/1.1\r\nHost: %s\r\nUser-Agent: Mozilla/5.0\r\nConnection: close\r\n\r\n", host)
	line, err := bufio.NewReader(c).ReadString('\n')
	if f := strings.Fields(line); err == nil && len(f) >= 2 && strings.HasPrefix(f[0], "HTTP/") {
		return f[1]
	}
	return "-"
}

func sniProbe(host, ip string, wait time.Duration) string {
	type res struct{ k, v string }
	ch := make(chan res, 6)
	run := func(k string, f func() string) { go func() { ch <- res{k, f()} }() }
	run("tcp", func() string {
		c, err := net.DialTimeout("tcp", net.JoinHostPort(ip, sniPorts[0]), wait)
		if err == nil {
			c.Close()
		}
		return netReason(err)
	})
	run("sni", func() string { return tlsReach(ip, host, wait) })
	run("other", func() string { return tlsReach(ip, sniOther, wait) })
	run("none", func() string { return tlsReach(ip, "", wait) })
	run("case", func() string { return tlsReach(ip, strings.ToUpper(host), wait) })
	run("http", func() string { return httpStatus(ip, host, wait) })
	r := make(map[string]string)
	for i := 0; i < 6; i++ {
		x := <-ch
		r[x.k] = x.v
	}
	cause := "none"
	switch {
	case r["tcp"] != "ok":
		cause = "addr"
	case r["sni"] == "ok":
	case r["other"] == "ok" || r["none"] == "ok":
		cause = "name"
		if r["case"] == "ok" {
			cause = "name-case"
		}
	default:
		cause = "tls"
	}
	var parts []string
	for _, k := range []string{"tcp", "sni", "other", "none", "case", "http"} {
		parts = append(parts, k+"="+r[k])
	}
	return cause + "\t" + strings.Join(parts, " ")
}

func runSniProbe(host, ip string, wait time.Duration) {
	if net.ParseIP(ip) == nil || host == "" {
		fmt.Fprintln(os.Stderr, "-sniprobe: нужны имя и -ip")
		os.Exit(2)
	}
	fmt.Println(sniProbe(host, ip, wait))
}
