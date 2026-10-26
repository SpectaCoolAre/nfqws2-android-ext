// Состояние между перезапусками: geodns перезапускается при каждой смене
// сети, и без этого всё узнанное (адреса прокси, решения по доменам)
// пришлось бы узнавать заново — каждый домен снова ждал бы провайдеров.
//
// Файл — строки «P провайдер адрес unix» и «D домен провайдер|- unix-до».
package main

import (
	"bufio"
	"fmt"
	"net"
	"os"
	"strconv"
	"strings"
	"time"
)

func (a *Arbiter) SaveState(path string) error {
	var b strings.Builder
	for _, p := range a.Providers {
		p.mu.Lock()
		for ip, t := range p.proxy {
			if time.Since(t) < proxyKeep {
				fmt.Fprintf(&b, "P %s %s %d\n", p.Name, ip, t.Unix())
			}
		}
		p.mu.Unlock()
	}
	now := time.Now()
	a.mu.Lock()
	for name, d := range a.cache {
		if d.until.After(now) {
			prov := "-"
			if d.prov >= 0 {
				prov = a.Providers[d.prov].Name
			}
			fmt.Fprintf(&b, "D %s %s %d\n", name, prov, d.until.Unix())
		}
	}
	a.mu.Unlock()
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, []byte(b.String()), 0644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// LoadState — что было узнано до перезапуска. Провайдер с известными
// адресами прокси сразу готов: «не под геоблоком» можно запоминать до
// первой проверки канареек
func (a *Arbiter) LoadState(path string) (proxies, decisions int) {
	f, err := os.Open(path)
	if err != nil {
		return 0, 0
	}
	defer f.Close()
	idx := map[string]int{}
	for i, p := range a.Providers {
		idx[p.Name] = i
	}
	now := time.Now()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		fs := strings.Fields(sc.Text())
		if len(fs) != 4 {
			continue
		}
		ts, err := strconv.ParseInt(fs[3], 10, 64)
		if err != nil {
			continue
		}
		t := time.Unix(ts, 0)
		switch fs[0] {
		case "P":
			i, ok := idx[fs[1]]
			if ip := net.ParseIP(fs[2]); !ok || ip == nil || !usable(ip) || now.Sub(t) >= proxyKeep {
				continue
			}
			p := a.Providers[i]
			p.mu.Lock()
			p.proxy[fs[2]] = t
			p.canaryAt = now
			p.mu.Unlock()
			proxies++
		case "D":
			if !t.After(now) {
				continue
			}
			prov := -1
			if fs[2] != "-" {
				i, ok := idx[fs[2]]
				if !ok {
					continue
				}
				prov = i
			}
			a.mu.Lock()
			a.cache[fs[1]] = decision{prov, t}
			a.mu.Unlock()
			decisions++
		}
	}
	return proxies, decisions
}
