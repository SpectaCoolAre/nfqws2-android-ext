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
