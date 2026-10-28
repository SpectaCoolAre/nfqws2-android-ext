// Проверка dnsproxy: жив процесс — ещё не значит, что он отвечает. Запрос —
// PTR для 127.0.0.1: на него dnsproxy отвечает сам (из hosts или NXDOMAIN для
// частных адресов), не спрашивая серверы, поэтому молчащие серверы или
// пропавшая сеть не выглядят как зависший dnsproxy. Ответ засчитывается по
// совпавшему ID; повтор через полсрока — на случай потерянного пакета.
package main

import (
	"errors"
	"net"
	"time"
)

var probeName = []byte("\x011\x010\x010\x03127\x07in-addr\x04arpa\x00")

func probeQuery(id uint16) []byte {
	q := []byte{byte(id >> 8), byte(id), 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0}
	q = append(q, probeName...)
	return append(q, 0, 12, 0, 1) // PTR, IN
}

func probeDNS(addr string, wait time.Duration) error {
	c, err := net.Dial("udp", addr)
	if err != nil {
		return err
	}
	defer c.Close()
	id := uint16(time.Now().UnixNano())
	q := probeQuery(id)
	deadline := time.Now().Add(wait)
	buf := make([]byte, 1500)
	for try := 0; try < 2; try++ {
		if _, err := c.Write(q); err != nil {
			return err
		}
		until := deadline
		if try == 0 {
			until = time.Now().Add(wait / 2)
		}
		c.SetReadDeadline(until)
		for {
			n, err := c.Read(buf)
			if err != nil {
				var ne net.Error
				if errors.As(err, &ne) && ne.Timeout() {
					break
				}
				return err // ICMP «порт закрыт» — никто не слушает
			}
			if n >= 12 && buf[0] == byte(id>>8) && buf[1] == byte(id) && buf[2]&0x80 != 0 {
				return nil
			}
		}
	}
	return errors.New("нет ответа")
}
