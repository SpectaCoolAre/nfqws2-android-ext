// Серверы: обычный DNS (UDP, при обрезанном ответе — TCP) и DoH (RFC 8484).
package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"strings"
	"time"
)

type Upstream interface {
	Exchange(ctx context.Context, q []byte) ([]byte, error)
	String() string
}

// ── обычный DNS ──────────────────────────────────────────────────────────
type plainUpstream struct{ addr string }

func (u *plainUpstream) String() string { return u.addr }

func (u *plainUpstream) Exchange(ctx context.Context, q []byte) ([]byte, error) {
	r, err := u.udp(ctx, q)
	if err == nil && len(r) > 2 && r[2]&0x02 != 0 { // TC — ответ не влез, повтор по TCP
		return u.tcp(ctx, q)
	}
	return r, err
}

func (u *plainUpstream) udp(ctx context.Context, q []byte) ([]byte, error) {
	var d net.Dialer
	c, err := d.DialContext(ctx, "udp", u.addr)
	if err != nil {
		return nil, err
	}
	defer c.Close()
	if dl, ok := ctx.Deadline(); ok {
		c.SetDeadline(dl)
	}
	if _, err := c.Write(q); err != nil {
		return nil, err
	}
	buf := make([]byte, 65535)
	for {
		n, err := c.Read(buf)
		if err != nil {
			return nil, err
		}
		// ответ на чужой ID (запоздавший) — ждём свой
		if n >= 2 && buf[0] == q[0] && buf[1] == q[1] {
			return append([]byte(nil), buf[:n]...), nil
		}
	}
}

func (u *plainUpstream) tcp(ctx context.Context, q []byte) ([]byte, error) {
	var d net.Dialer
	c, err := d.DialContext(ctx, "tcp", u.addr)
	if err != nil {
		return nil, err
	}
	defer c.Close()
	if dl, ok := ctx.Deadline(); ok {
		c.SetDeadline(dl)
	}
	return tcpExchange(c, q)
}

func tcpExchange(c io.ReadWriter, q []byte) ([]byte, error) {
	b := make([]byte, 2+len(q))
	binary.BigEndian.PutUint16(b, uint16(len(q)))
	copy(b[2:], q)
	if _, err := c.Write(b); err != nil {
		return nil, err
	}
	var l [2]byte
	if _, err := io.ReadFull(c, l[:]); err != nil {
		return nil, err
	}
	r := make([]byte, binary.BigEndian.Uint16(l[:]))
	_, err := io.ReadFull(c, r)
	return r, err
}

// ── DoH ──────────────────────────────────────────────────────────────────
type dohUpstream struct {
	url    string
	client *http.Client
}

func (u *dohUpstream) String() string { return u.url }

// newDoH — клиент DoH; имя сервера резолвится через resolver (быстрый маршрут
// модуля), а не через систему: перехват завернул бы запрос обратно к нам
func newDoH(url string, resolver string) *dohUpstream {
	r := &net.Resolver{PreferGo: true, Dial: func(ctx context.Context, network, address string) (net.Conn, error) {
		var d net.Dialer
		return d.DialContext(ctx, "udp", resolver)
	}}
	dialer := &net.Dialer{Timeout: 5 * time.Second, Resolver: r, KeepAlive: 30 * time.Second}
	tr := &http.Transport{
		DialContext:         dialer.DialContext,
		TLSClientConfig:     &tls.Config{MinVersion: tls.VersionTLS12},
		ForceAttemptHTTP2:   true,
		MaxIdleConnsPerHost: 4,
		IdleConnTimeout:     90 * time.Second,
		TLSHandshakeTimeout: 5 * time.Second,
	}
	return &dohUpstream{url: url, client: &http.Client{Transport: tr}}
}

func (u *dohUpstream) Exchange(ctx context.Context, q []byte) ([]byte, error) {
	// ID в DoH — 0 (RFC 8484), ответ потом получает ID клиента
	body := SetID(q, 0)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, u.url, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/dns-message")
	req.Header.Set("Accept", "application/dns-message")
	resp, err := u.client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	r, err := io.ReadAll(io.LimitReader(resp.Body, 65535))
	if err != nil {
		return nil, err
	}
	if len(r) < 12 {
		return nil, errShort
	}
	return SetID(r, binary.BigEndian.Uint16(q)), nil
}

// parseUpstream — https://… (DoH) или адрес[:порт] обычного DNS; DoT, DoQ и
// прочие схемы арбитру не нужны — у провайдеров есть DoH и обычные адреса
func parseUpstream(s, resolver string) (Upstream, error) {
	switch {
	case strings.HasPrefix(s, "https://"):
		return newDoH(s, resolver), nil
	case strings.Contains(s, "://"):
		return nil, errors.New("схема не поддерживается: " + s)
	}
	if _, _, err := net.SplitHostPort(s); err != nil {
		s = net.JoinHostPort(strings.Trim(s, "[]"), "53")
	}
	return &plainUpstream{addr: s}, nil
}
