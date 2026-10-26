package main

import (
	"context"
	"encoding/binary"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

// fakeUp — сервер в памяти: имя -> адреса (A); задержка, отказ
type fakeUp struct {
	name  string
	ans   map[string][]string
	delay time.Duration
	fail  bool
	mu    sync.Mutex
	calls int
}

func (f *fakeUp) String() string { return f.name }
func (f *fakeUp) Exchange(ctx context.Context, q []byte) ([]byte, error) {
	f.mu.Lock()
	f.calls++
	f.mu.Unlock()
	if f.fail {
		return nil, errors.New("молчит")
	}
	select {
	case <-time.After(f.delay):
	case <-ctx.Done():
		return nil, ctx.Err()
	}
	qq, end, err := ParseQuestion(q)
	if err != nil {
		return nil, err
	}
	r := append([]byte(nil), q[:end]...)
	r[2] |= 0x80
	r[3] = 0x80
	var n uint16
	if qq.Type == typeA {
		for _, a := range f.ans[qq.Name] {
			ip := net.ParseIP(a).To4()
			r = append(r, 0xC0, 0x0C, 0, 1, 0, 1, 0, 0, 0x01, 0x2C, 0, 4)
			r = append(r, ip...)
			n++
		}
	}
	binary.BigEndian.PutUint16(r[6:], n)
	for i := 8; i < 12; i++ {
		r[i] = 0
	}
	return r, nil
}

func ips(t *testing.T, r []byte) string {
	a, err := ParseAnswer(r)
	if err != nil {
		t.Fatal(err)
	}
	var s []string
	for _, ip := range a.IPs {
		s = append(s, ip.String())
	}
	return strings.Join(s, ",")
}

func setup() (*Arbiter, *fakeUp, *fakeUp, *fakeUp) {
	fast := &fakeUp{name: "fast", ans: map[string][]string{
		"chatgpt.com": {"104.18.32.47"}, "claude.ai": {"160.79.104.10"}, "gemini.google.com": {"142.250.1.1"},
		"example.org": {"93.184.215.14"}, "sber.ru": {"1.1.1.2"}, "www.spotify.com": {"35.186.224.1"},
	}}
	// comss: прокси 5.5.5.5 для сервисов с геоблоком, настоящие — для остальных
	comss := &fakeUp{name: "comss", ans: map[string][]string{
		"chatgpt.com": {"5.5.5.5"}, "claude.ai": {"5.5.5.5"}, "gemini.google.com": {"5.5.5.6"},
		"example.org": {"93.184.215.14"}, "sber.ru": {"5.5.5.5"},
	}}
	// geohide обслуживает spotify, comss — нет
	geohide := &fakeUp{name: "geohide", ans: map[string][]string{
		"chatgpt.com": {"7.7.7.7"}, "claude.ai": {"7.7.7.7"}, "www.spotify.com": {"7.7.7.7"},
		"example.org": {"93.184.215.14"},
	}}
	comss.ans["www.spotify.com"] = []string{"35.186.224.1"}
	a := &Arbiter{
		Fast:      fast,
		Providers: []*Provider{NewProvider("comss", []Upstream{comss}), NewProvider("geohide", []Upstream{geohide})},
		Never:     &Suffixes{m: map[string]struct{}{"ru": {}}},
		Always:    &Suffixes{m: map[string]struct{}{}},
		Canaries:  []string{"chatgpt.com", "claude.ai", "gemini.google.com"},
		Wait:      300 * time.Millisecond, Timeout: 2 * time.Second, cache: map[string]decision{},
	}
	return a, fast, comss, geohide
}

func TestParse(t *testing.T) {
	q := BuildQuery(0x1234, "WWW.Example.org", typeAAAA)
	qq, _, err := ParseQuestion(q)
	if err != nil || qq.Name != "www.example.org" || qq.Type != typeAAAA {
		t.Fatalf("вопрос: %+v %v", qq, err)
	}
	if binary.BigEndian.Uint16(ServFail(q)[2:]) != 0x8182 {
		t.Fatal("SERVFAIL")
	}
	if baseDomain("a.b.example.com") != "example.com" {
		t.Fatal("сайт")
	}
}

func TestCanariesLearnProxies(t *testing.T) {
	a, _, _, _ := setup()
	a.CheckCanaries()
	if _, ok := a.Providers[0].IsProxy([]net.IP{net.ParseIP("5.5.5.5")}, nil); !ok {
		t.Fatal("comss: 5.5.5.5 у двух канареек — прокси")
	}
	if _, ok := a.Providers[0].IsProxy([]net.IP{net.ParseIP("5.5.5.6")}, nil); ok {
		t.Fatal("адрес одной канарейки ещё не прокси")
	}
	if _, ok := a.Providers[1].IsProxy([]net.IP{net.ParseIP("7.7.7.7")}, nil); !ok {
		t.Fatal("geohide: 7.7.7.7")
	}
}

func TestDecisionByAnswer(t *testing.T) {
	a, _, _, _ := setup()
	a.CheckCanaries()
	ask := func(name string, typ uint16) []byte { return a.Handle(BuildQuery(0x4242, name, typ)) }
	if got := ips(t, ask("chatgpt.com", typeA)); got != "5.5.5.5" && got != "7.7.7.7" {
		t.Fatalf("chatgpt.com — через прокси, получено %q", got)
	}
	if got := ips(t, ask("example.org", typeA)); got != "93.184.215.14" {
		t.Fatalf("обычный сайт — быстрый маршрут, получено %q", got)
	}
	if got := ips(t, ask("www.spotify.com", typeA)); got != "7.7.7.7" {
		t.Fatalf("сервис, который обслуживает только один провайдер, — через него, получено %q", got)
	}
	if got := ips(t, ask("sber.ru", typeA)); got != "1.1.1.2" {
		t.Fatalf("«никогда в обход» — быстрый маршрут, даже если провайдер отдал прокси, получено %q", got)
	}
	r := ask("example.org", typeA)
	if binary.BigEndian.Uint16(r) != 0x4242 {
		t.Fatal("ответ — с ID клиента")
	}
}

func TestAAAAFollowsA(t *testing.T) {
	a, fast, _, _ := setup()
	a.CheckCanaries()
	fast.mu.Lock()
	before := fast.calls
	fast.mu.Unlock()
	r := a.Handle(BuildQuery(1, "claude.ai", typeAAAA))
	an, _ := ParseAnswer(r)
	if len(an.IPs) != 0 {
		t.Fatal("AAAA домена под геоблоком — ответ провайдера (без настоящего IPv6)")
	}
	if d, ok := a.cached("claude.ai"); !ok || d.prov < 0 {
		t.Fatal("решение запомнено")
	}
	_ = before
}

func TestProviderDownGoesFast(t *testing.T) {
	a, _, comss, geohide := setup()
	a.CheckCanaries()
	comss.fail, geohide.fail = true, true
	a.cache = map[string]decision{}
	start := time.Now()
	if got := ips(t, a.Handle(BuildQuery(1, "chatgpt.com", typeA))); got != "104.18.32.47" {
		t.Fatalf("все провайдеры молчат — быстрый маршрут, получено %q", got)
	}
	if time.Since(start) > time.Second {
		t.Fatal("отказ провайдеров не задерживает ответ")
	}
}

func TestSlowProviderIsNotWaitedForever(t *testing.T) {
	a, _, comss, geohide := setup()
	a.CheckCanaries()
	comss.delay, geohide.delay = 2*time.Second, 2*time.Second
	a.cache = map[string]decision{}
	start := time.Now()
	ips(t, a.Handle(BuildQuery(1, "example.org", typeA)))
	if el := time.Since(start); el > 600*time.Millisecond {
		t.Fatalf("медленные провайдеры ждутся не дольше Wait, ждали %v", el)
	}
	if _, ok := a.cached("example.org"); ok {
		t.Fatal("без ответа провайдеров «не под геоблоком» не запоминается")
	}
}

func TestLearnOnTheFly(t *testing.T) {
	a, fast, comss, _ := setup()
	// канарейки не дали адреса 9.9.9.9; он отдаётся вместо настоящего у 4 сайтов
	for i, s := range []string{"a1.com", "a2.net", "a3.org", "a4.io"} {
		fast.ans[s] = []string{"10.0.0." + string(rune('1'+i))}
		comss.ans[s] = []string{"9.9.9.9"}
	}
	a.CheckCanaries()
	for _, s := range []string{"a1.com", "a2.net", "a3.org", "a4.io"} {
		a.Handle(BuildQuery(1, s, typeA))
	}
	if _, ok := a.Providers[0].IsProxy([]net.IP{net.ParseIP("9.9.9.9")}, nil); !ok {
		t.Fatal("адрес вместо настоящего у разных сайтов — прокси")
	}
}

func TestDoHExchange(t *testing.T) {
	up := &fakeUp{name: "doh", ans: map[string][]string{"chatgpt.com": {"5.5.5.5"}}}
	var gotID uint16 = 0xFFFF
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || r.Header.Get("Content-Type") != "application/dns-message" {
			http.Error(w, "bad", 400)
			return
		}
		q, _ := io.ReadAll(r.Body)
		gotID = binary.BigEndian.Uint16(q)
		resp, _ := up.Exchange(r.Context(), q)
		w.Header().Set("Content-Type", "application/dns-message")
		w.Write(resp)
	}))
	defer srv.Close()
	d := newDoH(srv.URL+"/dns-query", "127.0.0.1:1")
	r, err := d.Exchange(context.Background(), BuildQuery(0x7777, "chatgpt.com", typeA))
	if err != nil {
		t.Fatal(err)
	}
	if gotID != 0 {
		t.Fatalf("в DoH ID запроса — 0 (RFC 8484), был %x", gotID)
	}
	if binary.BigEndian.Uint16(r) != 0x7777 || ips(t, r) != "5.5.5.5" {
		t.Fatal("ответ DoH — с ID клиента и адресами")
	}
}

func TestReserveOnlyWhenPrimariesSilent(t *testing.T) {
	a, _, comss, geohide := setup()
	astra := &fakeUp{name: "astracat", ans: map[string][]string{
		"chatgpt.com": {"8.8.4.4"}, "claude.ai": {"8.8.4.4"}, "example.org": {"93.184.215.14"},
	}}
	res := NewProvider("astracat", []Upstream{astra})
	res.Reserve = true
	a.Providers = append(a.Providers, res)
	a.CheckCanaries()
	astra.mu.Lock()
	astra.calls = 0
	astra.mu.Unlock()
	a.Handle(BuildQuery(1, "example.org", typeA))
	a.Handle(BuildQuery(1, "chatgpt.com", typeA))
	astra.mu.Lock()
	n := astra.calls
	astra.mu.Unlock()
	if n != 0 {
		t.Fatalf("пока основные отвечают, запасному домены не уходят, запросов: %d", n)
	}
	if !strings.Contains(a.Status(), `"reserve":true,"active":false`) {
		t.Fatal("в состоянии запасной — в резерве")
	}
	// основные замолчали (заблокированы): обход — через запасной
	comss.fail, geohide.fail = true, true
	for i := 0; i < downAfter; i++ {
		a.cache = map[string]decision{}
		a.Handle(BuildQuery(1, "claude.ai", typeA))
	}
	a.cache = map[string]decision{}
	if got := ips(t, a.Handle(BuildQuery(1, "claude.ai", typeA))); got != "8.8.4.4" {
		t.Fatalf("основные молчат — через запасной, получено %q", got)
	}
	if !strings.Contains(a.Status(), `"reserve":true,"active":true`) {
		t.Fatal("в состоянии запасной — в работе")
	}
}

func TestPriorityNotSpeed(t *testing.T) {
	a, _, comss, _ := setup()
	a.CheckCanaries()
	// geohide — первый по порядку (DNS по умолчанию), comss отвечает быстрее
	a.Providers[0], a.Providers[1] = a.Providers[1], a.Providers[0]
	comss.delay = 0
	if got := ips(t, a.Handle(BuildQuery(1, "chatgpt.com", typeA))); got != "7.7.7.7" {
		t.Fatalf("прокси отдали оба — берётся первый по порядку, а не самый быстрый, получено %q", got)
	}
}

func TestClaimedDomainGoesToItsProvider(t *testing.T) {
	a, fast, comss, geohide := setup()
	fast.ans["game.brawlstarsgame.com"] = []string{"34.1.1.1"}
	comss.ans["game.brawlstarsgame.com"] = []string{"5.5.5.5"}
	geohide.ans["game.brawlstarsgame.com"] = []string{"8.1.2.3"} // адрес, которого канарейки не показали
	a.Providers[1].Claims = &Suffixes{m: map[string]struct{}{"brawlstarsgame.com": {}}}
	a.CheckCanaries()
	if got := ips(t, a.Handle(BuildQuery(1, "game.brawlstarsgame.com", typeA))); got != "8.1.2.3" {
		t.Fatalf("домен из списка провайдера — через него, даже если прокси отдал и другой, получено %q", got)
	}
}

func TestNeighbourProxy(t *testing.T) {
	a, fast, _, geohide := setup()
	fast.ans["game.clashofclans.com"] = []string{"34.1.1.2"}
	geohide.ans["game.clashofclans.com"] = []string{"7.7.7.90"} // та же /24, что у известного 7.7.7.7
	a.CheckCanaries()
	if got := ips(t, a.Handle(BuildQuery(1, "game.clashofclans.com", typeA))); got != "7.7.7.90" {
		t.Fatalf("соседний адрес прокси из той же /24 — тоже прокси, получено %q", got)
	}
	if _, ok := a.Providers[1].IsProxy([]net.IP{net.ParseIP("7.7.7.90")}, nil); !ok {
		t.Fatal("и запоминается")
	}
}

func TestStateSurvivesRestart(t *testing.T) {
	a, _, _, _ := setup()
	a.CheckCanaries()
	a.Handle(BuildQuery(1, "chatgpt.com", typeA))
	a.Handle(BuildQuery(1, "example.org", typeA))
	path := t.TempDir() + "/geo.state"
	if err := a.SaveState(path); err != nil {
		t.Fatal(err)
	}
	b, _, comss, geohide := setup()
	np, nd := b.LoadState(path)
	if np == 0 || nd != 2 {
		t.Fatalf("загружено: прокси %d, решений %d", np, nd)
	}
	if d, ok := b.cached("chatgpt.com"); !ok || d.prov < 0 {
		t.Fatal("решение «под геоблоком» пережило перезапуск")
	}
	if d, ok := b.cached("example.org"); !ok || d.prov >= 0 {
		t.Fatal("и «не под геоблоком» тоже")
	}
	comss.delay, geohide.delay = 2*time.Second, 2*time.Second
	start := time.Now()
	b.Handle(BuildQuery(1, "example.org", typeA))
	if time.Since(start) > 200*time.Millisecond {
		t.Fatal("известный домен после перезапуска не ждёт провайдеров")
	}
}

func TestGeoAnswerCached(t *testing.T) {
	a, _, comss, geohide := setup()
	a.CheckCanaries()
	a.Handle(BuildQuery(1, "claude.ai", typeA))
	comss.mu.Lock()
	c0 := comss.calls
	comss.mu.Unlock()
	geohide.mu.Lock()
	g0 := geohide.calls
	geohide.mu.Unlock()
	if got := ips(t, a.Handle(BuildQuery(2, "claude.ai", typeA))); got != "5.5.5.5" {
		t.Fatalf("повтор — тот же ответ, получено %q", got)
	}
	comss.mu.Lock()
	c1 := comss.calls
	comss.mu.Unlock()
	geohide.mu.Lock()
	g1 := geohide.calls
	geohide.mu.Unlock()
	if c1 != c0 || g1 != g0 {
		t.Fatal("повтор — из кэша, без запроса провайдеру")
	}
}

func TestBlockedAnswerIsNotProxy(t *testing.T) {
	a, fast, comss, _ := setup()
	// comss блокирует трекеры ответом 0.0.0.0 — это не прокси
	for i, s := range []string{"t1.com", "t2.net", "t3.org", "t4.io", "t5.dev"} {
		fast.ans[s] = []string{"10.1.0." + string(rune('1'+i))}
		comss.ans[s] = []string{"0.0.0.0"}
	}
	a.CheckCanaries()
	for _, s := range []string{"t1.com", "t2.net", "t3.org", "t4.io", "t5.dev"} {
		a.Handle(BuildQuery(1, s, typeA))
	}
	if _, ok := a.Providers[0].IsProxy([]net.IP{net.ParseIP("0.0.0.0")}, nil); ok {
		t.Fatal("0.0.0.0 не становится прокси")
	}
	if got := ips(t, a.Handle(BuildQuery(1, "t5.dev", typeA))); got != "10.1.0.5" {
		t.Fatalf("заблокированный провайдером трекер — обычным маршрутом, получено %q", got)
	}
}
