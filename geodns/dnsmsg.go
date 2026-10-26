// Разбор DNS-сообщений: ровно столько, сколько нужно арбитру — вопрос,
// адреса из ответа, наименьший TTL. Без зависимостей.
package main

import (
	"encoding/binary"
	"errors"
	"net"
	"strings"
)

const (
	typeA     = 1
	typeAAAA  = 28
	typeHTTPS = 65
)

var errShort = errors.New("короткое DNS-сообщение")

// Question — первый вопрос запроса: имя в нижнем регистре без точки в конце
type Question struct {
	Name string
	Type uint16
}

func skipName(m []byte, off int) (int, error) {
	for {
		if off >= len(m) {
			return 0, errShort
		}
		l := int(m[off])
		switch {
		case l == 0:
			return off + 1, nil
		case l&0xC0 == 0xC0:
			return off + 2, nil
		default:
			off += 1 + l
		}
	}
}

func readName(m []byte, off int) (string, error) {
	var parts []string
	for jumps := 0; jumps < 32; {
		if off >= len(m) {
			return "", errShort
		}
		l := int(m[off])
		switch {
		case l == 0:
			return strings.ToLower(strings.Join(parts, ".")), nil
		case l&0xC0 == 0xC0:
			if off+1 >= len(m) {
				return "", errShort
			}
			off = int(binary.BigEndian.Uint16(m[off:]) & 0x3FFF)
			jumps++
		default:
			if off+1+l > len(m) {
				return "", errShort
			}
			parts = append(parts, string(m[off+1:off+1+l]))
			off += 1 + l
		}
	}
	return "", errors.New("петля в сжатии имён")
}

// ParseQuestion — первый вопрос и смещение после него
func ParseQuestion(m []byte) (Question, int, error) {
	if len(m) < 12 || binary.BigEndian.Uint16(m[4:]) == 0 {
		return Question{}, 0, errShort
	}
	name, err := readName(m, 12)
	if err != nil {
		return Question{}, 0, err
	}
	off, err := skipName(m, 12)
	if err != nil || off+4 > len(m) {
		return Question{}, 0, errShort
	}
	return Question{Name: name, Type: binary.BigEndian.Uint16(m[off:])}, off + 4, nil
}

// Answer — адреса A/AAAA из раздела ответов, наименьший TTL, код ответа
type Answer struct {
	IPs   []net.IP
	TTL   uint32
	Rcode int
	Count int
}

func ParseAnswer(m []byte) (Answer, error) {
	var a Answer
	if len(m) < 12 {
		return a, errShort
	}
	a.Rcode = int(m[3] & 0x0F)
	qd := int(binary.BigEndian.Uint16(m[4:]))
	an := int(binary.BigEndian.Uint16(m[6:]))
	a.Count = an
	off := 12
	var err error
	for i := 0; i < qd; i++ {
		if off, err = skipName(m, off); err != nil {
			return a, err
		}
		off += 4
	}
	a.TTL = 0xFFFFFFFF
	for i := 0; i < an; i++ {
		if off, err = skipName(m, off); err != nil {
			return a, err
		}
		if off+10 > len(m) {
			return a, errShort
		}
		typ := binary.BigEndian.Uint16(m[off:])
		ttl := binary.BigEndian.Uint32(m[off+4:])
		rdl := int(binary.BigEndian.Uint16(m[off+8:]))
		off += 10
		if off+rdl > len(m) {
			return a, errShort
		}
		if ttl < a.TTL {
			a.TTL = ttl
		}
		if typ == typeA && rdl == 4 || typ == typeAAAA && rdl == 16 {
			a.IPs = append(a.IPs, net.IP(append([]byte(nil), m[off:off+rdl]...)))
		}
		off += rdl
	}
	if a.TTL == 0xFFFFFFFF {
		a.TTL = 0
	}
	return a, nil
}

// SetID — ответ под ID запроса клиента
func SetID(m []byte, id uint16) []byte {
	out := append([]byte(nil), m...)
	if len(out) >= 2 {
		binary.BigEndian.PutUint16(out, id)
	}
	return out
}

// BuildQuery — запрос с одним вопросом (RD)
func BuildQuery(id uint16, name string, typ uint16) []byte {
	m := make([]byte, 12, 12+len(name)+6)
	binary.BigEndian.PutUint16(m, id)
	m[2] = 0x01 // RD
	binary.BigEndian.PutUint16(m[4:], 1)
	for _, p := range strings.Split(strings.TrimSuffix(name, "."), ".") {
		if p == "" || len(p) > 63 {
			continue
		}
		m = append(m, byte(len(p)))
		m = append(m, p...)
	}
	m = append(m, 0, byte(typ>>8), byte(typ), 0, 1)
	return m
}

// ServFail — ответ «сервер не справился» на запрос
func ServFail(q []byte) []byte {
	if len(q) < 12 {
		return nil
	}
	_, end, err := ParseQuestion(q)
	if err != nil {
		end = 12
	}
	out := append([]byte(nil), q[:end]...)
	out[2] = 0x80 | (q[2] & 0x01) // QR, RD как в запросе
	out[3] = 0x82                 // RA, SERVFAIL
	for i := 6; i < 12; i++ {
		out[i] = 0
	}
	if end == 12 {
		out[5] = 0
	}
	return out
}

// baseDomain — «сайт» имени: два последних уровня (для подсчёта разных сайтов)
func baseDomain(name string) string {
	p := strings.Split(name, ".")
	if len(p) <= 2 {
		return name
	}
	return strings.Join(p[len(p)-2:], ".")
}
