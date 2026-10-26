// Арбитр: каждый запрос — быстрому маршруту (dnsproxy модуля) и всем
// провайдерам с обходом сразу; ответ провайдера с адресом его прокси —
// домен под геоблоком, отдаём его. Иначе — ответ быстрого маршрута.
package main

import (
	"bufio"
	"context"
	"fmt"
	"log"
	"net"
	"os"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

type decision struct {
	prov  int // номер провайдера с обходом, -1 — быстрый маршрут
	until time.Time
}

type Arbiter struct {
	Fast      Upstream
	Providers []*Provider
	Never     *Suffixes // никогда в обход
	Always    *Suffixes // всегда в обход (если провайдер ответил)
	Canaries  []string
	Wait      time.Duration // сколько ждать провайдеров
	Timeout   time.Duration // ответ быстрого маршрута

	mu      sync.Mutex
	cache   map[string]decision
	answers map[Question]keptAns
	recent  []recentGeo

	nQ, nGeo, nFast, nNever, nFail atomic.Int64
}

type recentGeo struct {
	Name string `json:"d"`
	Prov string `json:"p"`
	At   int64  `json:"t"`
}

// ── списки доменов (совпадение по суффиксу: example.com покрывает и a.example.com)
type Suffixes struct{ m map[string]struct{} }

func LoadSuffixes(paths ...string) *Suffixes {
	s := &Suffixes{m: map[string]struct{}{}}
	for _, p := range paths {
		if p == "" {
			continue
		}
		f, err := os.Open(p)
		if err != nil {
			continue
		}
		sc := bufio.NewScanner(f)
		for sc.Scan() {
			l := strings.TrimSpace(sc.Text())
			if i := strings.IndexAny(l, "# \t"); i >= 0 {
				l = strings.TrimSpace(l[:i])
			}
			l = strings.ToLower(strings.Trim(l, "."))
			if l != "" {
				s.m[l] = struct{}{}
			}
		}
		f.Close()
	}
	return s
}

func (s *Suffixes) Match(name string) bool {
	if s == nil {
		return false
	}
	for {
		if _, ok := s.m[name]; ok {
			return true
		}
		i := strings.IndexByte(name, '.')
		if i < 0 {
			return false
		}
		name = name[i+1:]
	}
}

func (a *Arbiter) cached(name string) (decision, bool) {
	a.mu.Lock()
	defer a.mu.Unlock()
	d, ok := a.cache[name]
	if ok && time.Now().After(d.until) {
		delete(a.cache, name)
		ok = false
	}
	return d, ok
}

func (a *Arbiter) remember(name string, d decision) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if len(a.cache) > 20000 {
		a.cache = map[string]decision{}
	}
	a.cache[name] = d
	if d.prov >= 0 {
		a.recent = append(a.recent, recentGeo{name, a.Providers[d.prov].Name, time.Now().Unix()})
		if len(a.recent) > 30 {
			a.recent = a.recent[len(a.recent)-30:]
		}
	}
}

type provRes struct {
	i int
	r []byte
	a Answer
}

// Handle — ответ на запрос клиента (с его ID)
func (a *Arbiter) Handle(q []byte) []byte {
	a.nQ.Add(1)
	id := uint16(0)
	if len(q) >= 2 {
		id = uint16(q[0])<<8 | uint16(q[1])
	}
	qq, _, err := ParseQuestion(q)
	ctx, cancel := context.WithTimeout(context.Background(), a.Timeout)
	defer cancel()
	if err != nil || a.Never.Match(qq.Name) || len(a.Providers) == 0 {
		if err == nil && a.Never.Match(qq.Name) {
			a.nNever.Add(1)
		}
		return a.fastOnly(ctx, q)
	}

	// решение уже есть: только нужный маршрут (ответ провайдера — из кэша по TTL)
	if d, ok := a.cached(qq.Name); ok {
		if d.prov >= 0 {
			if r := a.keptAnswer(qq); r != nil {
				a.nGeo.Add(1)
				return SetID(r, id)
			}
			if r, err := a.Providers[d.prov].Exchange(ctx, q); err == nil {
				a.nGeo.Add(1)
				a.keepAnswer(qq, r)
				return SetID(r, id)
			}
		}
		return a.fastOnly(ctx, q)
	}

	// быстрый маршрут — исходный запрос
	type fastRes struct {
		r   []byte
		err error
	}
	fch := make(chan fastRes, 1)
	go func() { r, err := a.Fast.Exchange(ctx, q); fch <- fastRes{r, err} }()

	// провайдеры: по A-записи имени решается для любого типа запроса (AAAA,
	// HTTPS): иначе приложение ушло бы на настоящий IPv6-адрес
	probe := q
	if qq.Type != typeA {
		probe = BuildQuery(newID(), qq.Name, typeA)
	}
	pch := make(chan provRes, len(a.Providers))
	waiting := 0
	for i, p := range a.Providers {
		if p.Down() || !a.InUse(p) {
			continue
		}
		waiting++
		go func(i int, p *Provider) {
			r, err := p.Exchange(ctx, probe)
			var an Answer
			if err == nil {
				an, err = ParseAnswer(r)
			}
			if err != nil {
				r = nil
			}
			pch <- provRes{i, r, an}
		}(i, p)
	}

	var fast fastRes
	gotFast := false
	var fastA []net.IP
	var res []provRes
	deadline := time.NewTimer(a.Wait)
	defer deadline.Stop()
	for !gotFast || waiting > 0 {
		select {
		case fast = <-fch:
			gotFast = true
			if fast.err == nil && qq.Type == typeA {
				if an, err := ParseAnswer(fast.r); err == nil {
					fastA = an.IPs
				}
			}
		case x := <-pch:
			waiting--
			if x.r != nil {
				res = append(res, x)
			}
		case <-deadline.C:
			waiting = 0 // кто не успел — не ждём
			if !gotFast {
				fast = <-fch
				gotFast = true
			}
		}
	}

	// провайдеры — по порядку (первый — главный, обычно DNS по умолчанию у
	// пользователя), а не кто быстрее ответил: иначе домены одного сервиса
	// расходятся по разным прокси. Сначала — провайдер, в чьём собственном
	// списке домен; затем — ответ с адресом прокси
	sort.Slice(res, func(i, j int) bool { return res[i].i < res[j].i })
	always := a.Always.Match(qq.Name)
	pick := -1
	var pickR []byte
	for _, x := range res {
		p := a.Providers[x.i]
		if fastA != nil {
			if ip := p.Learn(qq.Name, x.a.IPs, fastA); ip != "" {
				log.Printf("%s: адрес %s — прокси (отдаётся вместо настоящего для разных сайтов)", p.Name, ip)
			}
		}
	}
	for _, x := range res {
		if p := a.Providers[x.i]; len(x.a.IPs) > 0 && p.Claimed(qq.Name) {
			pick, pickR = x.i, x.r
			if !a.seen(qq.Name) {
				log.Printf("%s: в списке %s — через него", qq.Name, p.Name)
			}
			break
		}
	}
	for _, x := range res {
		if pick >= 0 {
			break
		}
		p := a.Providers[x.i]
		if ip, ok := p.IsProxy(x.a.IPs, fastA); ok {
			pick, pickR = x.i, x.r
			if !a.seen(qq.Name) {
				log.Printf("%s: под геоблоком — через %s (адрес прокси %s)", qq.Name, p.Name, ip)
			}
		}
	}
	for _, x := range res {
		if always && pick < 0 && len(x.a.IPs) > 0 {
			pick, pickR = x.i, x.r
		}
	}

	ready := true
	for _, p := range a.Providers {
		ready = ready && (p.Ready() || !a.InUse(p))
	}
	if pick >= 0 {
		a.remember(qq.Name, decision{pick, time.Now().Add(decisionKeep)})
		p := a.Providers[pick]
		p.mu.Lock()
		p.hits++
		p.mu.Unlock()
		a.nGeo.Add(1)
		if qq.Type == typeA {
			a.keepAnswer(qq, pickR)
			return SetID(pickR, id)
		}
		if r, err := p.Exchange(ctx, q); err == nil {
			a.keepAnswer(qq, r)
			return SetID(r, id)
		}
		return a.fastOnly(ctx, q)
	}
	// «не под геоблоком» запоминаем, только когда адреса прокси уже известны
	// и кто-то из провайдеров ответил — иначе через минуту спросим снова
	if ready && len(res) > 0 {
		a.remember(qq.Name, decision{-1, time.Now().Add(decisionKeep)})
	}
	if fast.err == nil {
		a.nFast.Add(1)
		return SetID(fast.r, id)
	}
	// быстрый маршрут не ответил — лучше ответ провайдера, чем никакого
	for _, x := range res {
		if qq.Type == typeA {
			return SetID(x.r, id)
		}
	}
	a.nFail.Add(1)
	return ServFail(q)
}

// InUse — основной всегда; запасной — только когда все основные молчат:
// домены пользователя не уходят лишним DNS, пока работают основные
func (a *Arbiter) InUse(p *Provider) bool {
	if !p.Reserve {
		return true
	}
	for _, q := range a.Providers {
		if !q.Reserve && !q.Failing() {
			return false
		}
	}
	return true
}

func (a *Arbiter) seen(name string) bool {
	a.mu.Lock()
	defer a.mu.Unlock()
	for _, r := range a.recent {
		if r.Name == name {
			return true
		}
	}
	return false
}

// решение по домену живёт долго: что под геоблоком, меняется редко, а
// каждое новое решение — ожидание ответа провайдеров
const decisionKeep = 6 * time.Hour

type keptAns struct {
	r     []byte
	until time.Time
}

// ответы провайдеров для доменов в обходе — по их TTL (от 30 с до 30 мин)
func (a *Arbiter) keepAnswer(qq Question, r []byte) {
	an, err := ParseAnswer(r)
	if err != nil || an.Rcode != 0 {
		return
	}
	t := an.TTL
	if t < 30 {
		t = 30
	}
	if t > 1800 {
		t = 1800
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.answers == nil || len(a.answers) > 4096 {
		a.answers = map[Question]keptAns{}
	}
	a.answers[qq] = keptAns{append([]byte(nil), r...), time.Now().Add(time.Duration(t) * time.Second)}
}

func (a *Arbiter) keptAnswer(qq Question) []byte {
	a.mu.Lock()
	defer a.mu.Unlock()
	k, ok := a.answers[qq]
	if !ok || time.Now().After(k.until) {
		return nil
	}
	return append([]byte(nil), k.r...)
}

func (a *Arbiter) fastOnly(ctx context.Context, q []byte) []byte {
	r, err := a.Fast.Exchange(ctx, q)
	if err != nil {
		a.nFail.Add(1)
		return ServFail(q)
	}
	a.nFast.Add(1)
	return r
}

// Canaries — адреса прокси каждого провайдера по сервисам с геоблоком
func (a *Arbiter) CheckCanaries() {
	for _, p := range a.Providers {
		found := map[string]int{}
		answered := 0
		for _, c := range a.Canaries {
			ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
			q := BuildQuery(newID(), c, typeA)
			pr, err1 := p.Exchange(ctx, q)
			fr, err2 := a.Fast.Exchange(ctx, BuildQuery(newID(), c, typeA))
			cancel()
			if err1 != nil {
				continue
			}
			answered++
			pa, err := ParseAnswer(pr)
			if err != nil {
				continue
			}
			var fa Answer
			if err2 == nil {
				fa, _ = ParseAnswer(fr)
			}
			for _, ip := range pa.IPs {
				if !overlap([]net.IP{ip}, fa.IPs) {
					found[ip.String()]++
				}
			}
		}
		got := p.SetCanary(found)
		switch {
		case answered == 0:
			log.Printf("%s: не отвечает (заблокирован или нет сети) — домены идут быстрым маршрутом", p.Name)
		case len(got) == 0:
			log.Printf("%s: ответил, но своих прокси для проверочных сервисов не отдал — узнаю по ходу работы", p.Name)
		default:
			log.Printf("%s: адреса прокси: %s", p.Name, strings.Join(got, ", "))
		}
	}
}

func (a *Arbiter) Status() string {
	a.mu.Lock()
	rec := append([]recentGeo(nil), a.recent...)
	a.mu.Unlock()
	var b strings.Builder
	fmt.Fprintf(&b, `{"t":%d,"queries":%d,"geo":%d,"fast":%d,"never":%d,"fail":%d,"providers":[`,
		time.Now().Unix(), a.nQ.Load(), a.nGeo.Load(), a.nFast.Load(), a.nNever.Load(), a.nFail.Load())
	for i, p := range a.Providers {
		p.mu.Lock()
		n := 0
		for _, t := range p.proxy {
			if time.Since(t) < proxyKeep {
				n++
			}
		}
		ok := int64(0)
		if !p.lastOK.IsZero() {
			ok = p.lastOK.Unix()
		}
		down := p.fails >= downAfter
		name, hits := p.Name, p.hits
		p.mu.Unlock()
		fmt.Fprintf(&b, `%s{"name":%q,"proxies":%d,"hits":%d,"last_ok":%d,"down":%t,"reserve":%t,"active":%t}`,
			comma(i), name, n, hits, ok, down, p.Reserve, a.InUse(p))
	}
	b.WriteString(`],"recent":[`)
	for i := len(rec) - 1; i >= 0; i-- {
		fmt.Fprintf(&b, `%s{"d":%q,"p":%q,"t":%d}`, comma(len(rec)-1-i), rec[i].Name, rec[i].Prov, rec[i].At)
	}
	b.WriteString("]}\n")
	return b.String()
}

func comma(i int) string {
	if i > 0 {
		return ","
	}
	return ""
}
