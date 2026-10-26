// Провайдеры DNS с обходом геоблока и решение по ответу.
//
// Такой DNS (comss, GeoHide, malw…) для доменов, которые он обслуживает,
// отдаёт адрес своего прокси за границей, для остальных — настоящий адрес.
// Значит, «домен под геоблоком» видно по ответу: в нём адрес прокси этого
// провайдера. Адреса прокси узнаются сами: у провайдера спрашиваются
// «канарейки» — сервисы с геоблоком; его адреса, которых нет в обычном
// ответе и которые повторяются у разных канареек, — прокси. Дообучение на
// ходу: адрес, который провайдер отдаёт вместо настоящего для нескольких
// разных сайтов, — тоже прокси.
package main

import (
	"context"
	"math/rand"
	"net"
	"sync"
	"time"
)

const (
	learnSites  = 4               // разных сайтов с одним «чужим» адресом — это прокси
	proxyKeep   = 6 * time.Hour   // адрес прокси без подтверждений забывается
	downAfter   = 3               // ошибок подряд — провайдер считается молчащим
	downRecheck = 2 * time.Minute // молчащего спрашиваем снова не раньше
)

type Provider struct {
	Name    string
	Ups     []Upstream
	Reserve bool      // запасной: спрашивается, только когда основные все молчат
	Claims  *Suffixes // домены, которые провайдер обслуживает по своему списку

	mu       sync.Mutex
	proxy    map[string]time.Time           // адрес прокси -> когда последний раз подтверждён
	cand     map[string]map[string]struct{} // кандидат -> сайты, где он был вместо настоящего
	fails    int
	lastOK   time.Time
	lastTry  time.Time
	canaryAt time.Time
	hits     int
}

func NewProvider(name string, ups []Upstream) *Provider {
	return &Provider{Name: name, Ups: ups, proxy: map[string]time.Time{}, cand: map[string]map[string]struct{}{}}
}

// Exchange — у всех адресов провайдера сразу (DoH и обычный), первый ответ
func (p *Provider) Exchange(ctx context.Context, q []byte) ([]byte, error) {
	type res struct {
		r   []byte
		err error
	}
	ch := make(chan res, len(p.Ups))
	for _, u := range p.Ups {
		go func(u Upstream) {
			r, err := u.Exchange(ctx, q)
			if err == nil {
				if a, perr := ParseAnswer(r); perr != nil || (a.Rcode != 0 && a.Rcode != 3) {
					err = errShort
				}
			}
			ch <- res{r, err}
		}(u)
	}
	var last error
	for range p.Ups {
		x := <-ch
		if x.err == nil {
			p.mu.Lock()
			p.fails, p.lastOK = 0, time.Now()
			p.mu.Unlock()
			return x.r, nil
		}
		last = x.err
	}
	p.mu.Lock()
	p.fails++
	p.lastTry = time.Now()
	p.mu.Unlock()
	return nil, last
}

// Down — молчит несколько раз подряд: не ждём его ответа, но изредка проверяем
func (p *Provider) Down() bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.fails >= downAfter && time.Since(p.lastTry) < downRecheck
}

// Failing — молчит несколько раз подряд (перепроверка не в счёт)
func (p *Provider) Failing() bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.fails >= downAfter
}

// IsProxy — есть ли в ответе адрес прокси этого провайдера. С ответом
// быстрого маршрута (fast) прокси — и соседний адрес из той же /24, которого
// нет в обычном ответе: у провайдера бывают отдельные прокси (для игр и т.п.)
// в той же сети, канарейки их не покажут
func (p *Provider) IsProxy(ips, fast []net.IP) (string, bool) {
	p.mu.Lock()
	defer p.mu.Unlock()
	for _, ip := range ips {
		if !usable(ip) {
			continue
		}
		if t, ok := p.proxy[ip.String()]; ok && time.Since(t) < proxyKeep {
			p.proxy[ip.String()] = time.Now()
			return ip.String(), true
		}
	}
	if len(fast) == 0 || overlap(ips, fast) {
		return "", false
	}
	for _, ip := range ips {
		v4 := ip.To4()
		if v4 == nil || !usable(ip) {
			continue
		}
		for k, t := range p.proxy {
			if time.Since(t) >= proxyKeep {
				continue
			}
			if q := net.ParseIP(k).To4(); q != nil && q[0] == v4[0] && q[1] == v4[1] && q[2] == v4[2] {
				p.proxy[ip.String()] = time.Now()
				return ip.String(), true
			}
		}
	}
	return "", false
}

// Claimed — домен из собственного списка провайдера
func (p *Provider) Claimed(name string) bool { return p.Claims.Match(name) }

func (p *Provider) Ready() bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	return !p.canaryAt.IsZero()
}

// Learn — провайдер отдал для сайта адреса, которых нет в обычном ответе:
// адрес, повторившийся так у нескольких разных сайтов, — прокси
func (p *Provider) Learn(name string, geo, fast []net.IP) (newProxy string) {
	if len(geo) == 0 || len(fast) == 0 || overlap(geo, fast) {
		return ""
	}
	site := baseDomain(name)
	p.mu.Lock()
	defer p.mu.Unlock()
	for _, ip := range geo {
		if !usable(ip) {
			continue
		}
		k := ip.String()
		if _, ok := p.proxy[k]; ok {
			continue
		}
		s := p.cand[k]
		if s == nil {
			if len(p.cand) > 4096 { // память не бесконечна: начать заново
				p.cand = map[string]map[string]struct{}{}
			}
			s = map[string]struct{}{}
			p.cand[k] = s
		}
		s[site] = struct{}{}
		if len(s) >= learnSites {
			p.proxy[k] = time.Now()
			delete(p.cand, k)
			newProxy = k
		}
	}
	return newProxy
}

// SetCanary — итог проверки канареек: адреса, повторившиеся у двух и более
func (p *Provider) SetCanary(found map[string]int) []string {
	p.mu.Lock()
	defer p.mu.Unlock()
	var got []string
	for ip, n := range found {
		if x := net.ParseIP(ip); n >= 2 && x != nil && usable(x) {
			p.proxy[ip] = time.Now()
			got = append(got, ip)
		}
	}
	p.canaryAt = time.Now()
	return got
}

// usable — адрес, который может быть прокси: не 0.0.0.0 (так DNS с обходом
// блокируют рекламу и трекеры), не локальный и не частный
func usable(ip net.IP) bool {
	return !(ip.IsUnspecified() || ip.IsLoopback() || ip.IsPrivate() || ip.IsLinkLocalUnicast() || ip.IsMulticast())
}

func overlap(a, b []net.IP) bool {
	for _, x := range a {
		for _, y := range b {
			if x.Equal(y) {
				return true
			}
		}
	}
	return false
}

func newID() uint16 { return uint16(rand.Intn(65536)) }
