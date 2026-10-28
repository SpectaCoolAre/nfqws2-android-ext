// Будильник для «Вылечить уведомления»: раз в интервал будит телефон даже из
// глубокого сна (таймер ядра CLOCK_BOOTTIME_ALARM, нужен root) и запускает
// команду — она просит Google Play Services послать пульс в соединение
// уведомлений. Обычный sleep в скрипте во сне стоит, а мобильный оператор
// как раз во сне и выбрасывает молчащее соединение.
//
//	nfqws2-helper -alarm 5m -run "sh /путь/service.sh push_beat"
//
// Команда вернула 3 — опция выключена, будильник завершается.
package main

import (
	"log"
	"os"
	"os/exec"
	"syscall"
	"time"
	"unsafe"
)

const (
	clockBoottime      = 7
	clockBoottimeAlarm = 9
	wakeLockName       = "nfqws2_push"
)

type itimerspec struct {
	Interval syscall.Timespec
	Value    syscall.Timespec
}

// newTimer — timerfd на CLOCK_BOOTTIME_ALARM; без прав — на CLOCK_BOOTTIME
// (идёт и во сне, но не будит: сработает при ближайшем пробуждении)
func newTimer(every time.Duration) (int, bool, error) {
	wakes := true
	fd, _, e := syscall.Syscall(syscall.SYS_TIMERFD_CREATE, clockBoottimeAlarm, 0, 0)
	if e != 0 {
		wakes = false
		if fd, _, e = syscall.Syscall(syscall.SYS_TIMERFD_CREATE, clockBoottime, 0, 0); e != 0 {
			return -1, false, e
		}
	}
	ts := syscall.NsecToTimespec(int64(every))
	spec := itimerspec{Interval: ts, Value: ts}
	if _, _, e := syscall.Syscall6(syscall.SYS_TIMERFD_SETTIME, fd, 0, uintptr(unsafe.Pointer(&spec)), 0, 0, 0); e != 0 {
		syscall.Close(int(fd))
		return -1, false, e
	}
	return int(fd), wakes, nil
}

// держать процессор, пока команда работает и пульс уходит (с запасом по времени)
func wakeLock(on bool) {
	if on {
		os.WriteFile("/sys/power/wake_lock", []byte(wakeLockName+" 20000000000"), 0)
	} else {
		os.WriteFile("/sys/power/wake_unlock", []byte(wakeLockName), 0)
	}
}

func runAlarm(every time.Duration, cmd string) {
	fd, wakes, err := newTimer(every)
	if err != nil {
		log.Printf("будильник: таймер не создан (%v) — обычные паузы", err)
	} else if !wakes {
		log.Printf("будильник: таймер без пробуждения (нет CLOCK_BOOTTIME_ALARM)")
	}
	shell := "/system/bin/sh"
	if _, err := os.Stat(shell); err != nil {
		shell = "sh"
	}
	buf := make([]byte, 8)
	for {
		if fd >= 0 {
			if _, err := syscall.Read(fd, buf); err != nil && err != syscall.EINTR {
				time.Sleep(every)
			}
		} else {
			time.Sleep(every)
		}
		wakeLock(true)
		c := exec.Command(shell, "-c", cmd)
		err := c.Run()
		time.Sleep(3 * time.Second) // пульс уходит из процесса Google Play Services
		wakeLock(false)
		if ee, ok := err.(*exec.ExitError); ok && ee.ExitCode() == 3 {
			return
		}
	}
}
