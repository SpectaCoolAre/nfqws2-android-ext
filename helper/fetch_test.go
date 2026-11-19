package main

import (
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestFetchOK(t *testing.T) {
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/go" {
			http.Redirect(w, r, "/there", http.StatusFound)
			return
		}
		w.Write([]byte(strings.Repeat("x", 30000)))
	}))
	defer srv.Close()
	body := filepath.Join(t.TempDir(), "b")
	r := fetch(srv.URL+"/", nil, "UA", body)
	if r.rc != 0 || r.code != 200 || r.size != 30000 {
		t.Fatalf("ok: %+v", r)
	}
	if !(r.tc > 0 && r.ta >= r.tc && r.tt >= r.ta && r.tot >= r.tt) {
		t.Fatalf("times: %+v", r)
	}
	if b, _ := os.ReadFile(body); len(b) != 30000 {
		t.Fatalf("body file %d", len(b))
	}
	f := strings.Fields(r.line())
	if len(f) != 8 || f[0] != "200" || f[7] != "-" || f[6] != "127.0.0.1" {
		t.Fatalf("line %q", r.line())
	}
	r = fetch(srv.URL+"/go", nil, "", "")
	if r.rc != 0 || r.code != 302 || !strings.HasSuffix(r.redirect, "/there") {
		t.Fatalf("redirect: %+v", r)
	}
}

// -max: дальше нужного ответ не читается, и это удача, а не обрыв
func TestFetchMax(t *testing.T) {
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(strings.Repeat("x", 500000)))
	}))
	defer srv.Close()
	fetchMax = 40000
	defer func() { fetchMax = 0 }()
	r := fetch(srv.URL+"/", nil, "", "")
	if r.rc != 0 || r.code != 200 || r.size < 40000 || r.size > 40000+(32<<10) {
		t.Fatalf("max: %+v", r)
	}
}

func TestFetchRefused(t *testing.T) {
	l, _ := net.Listen("tcp", "127.0.0.1:0")
	addr := l.Addr().String()
	l.Close()
	r := fetch("https://"+addr+"/", nil, "", "")
	if r.rc != 7 || r.tc != 0 {
		t.Fatalf("refused: %+v", r)
	}
}

func TestFetchTLSReset(t *testing.T) {
	l, _ := net.Listen("tcp", "127.0.0.1:0")
	defer l.Close()
	go func() {
		for {
			c, err := l.Accept()
			if err != nil {
				return
			}
			buf := make([]byte, 512)
			c.Read(buf)
			c.(*net.TCPConn).SetLinger(0)
			c.Close()
		}
	}()
	r := fetch("https://"+l.Addr().String()+"/", nil, "", "")
	if r.rc != 35 || r.tc == 0 || r.ta != 0 {
		t.Fatalf("reset in TLS: %+v", r)
	}
}

func TestFetchTLSHang(t *testing.T) {
	old := fetchTotalTO
	fetchTotalTO = 700 * time.Millisecond
	defer func() { fetchTotalTO = old }()
	l, _ := net.Listen("tcp", "127.0.0.1:0")
	defer l.Close()
	go func() {
		for {
			c, err := l.Accept()
			if err != nil {
				return
			}
			defer c.Close()
		}
	}()
	r := fetch("https://"+l.Addr().String()+"/", nil, "", "")
	if r.rc != 28 || r.tc == 0 || r.ta != 0 {
		t.Fatalf("hang in TLS (DPI ate the ClientHello): %+v", r)
	}
}

func TestFetchFollowAndPin(t *testing.T) {
	n := 0
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/":
			// кука ставится переадресацией на себя, как у защиты от ботов
			if _, err := r.Cookie("ok"); err != nil {
				http.SetCookie(w, &http.Cookie{Name: "ok", Value: "1", Path: "/"})
				http.Redirect(w, r, "/", http.StatusFound)
				return
			}
			w.Write([]byte("page"))
		case "/loop":
			n++
			http.Redirect(w, r, "/loop", http.StatusFound)
		}
	}))
	defer srv.Close()
	r := fetchWith(srv.URL+"/", nil, "", "", fetchOpt{follow: 5})
	if r.rc != 0 || r.code != 200 || r.size != 4 {
		t.Fatalf("follow with a cookie: %+v", r)
	}
	r = fetchWith(srv.URL+"/loop", nil, "", "", fetchOpt{follow: 5})
	if r.rc != 47 || r.redirect == "" {
		t.Fatalf("too many redirects: %+v", r)
	}
	// pin: имя в адресе, подключение — к заданному адресу
	u := strings.Replace(srv.URL, "127.0.0.1", "pinned.example", 1)
	r = fetchWith(u+"/", nil, "", "", fetchOpt{follow: 5, pin: "127.0.0.1"})
	if r.rc != 0 || r.code != 200 || r.ip != "127.0.0.1" {
		t.Fatalf("pinned address: %+v", r)
	}
}
