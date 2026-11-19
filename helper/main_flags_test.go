package main

import (
	"os"
	"os/exec"
	"strings"
	"testing"
)

// Флаги командной строки: main() запускается в отдельном процессе (так же,
// как модуль зовёт helper). 19.11: второй флаг с уже занятым именем (-max)
// ронял helper при любом запуске — panic «flag redefined», а тесты функций
// этого не видели
func TestMainFlags(t *testing.T) {
	if os.Getenv("HELPER_MAIN") == "1" {
		os.Args = append([]string{"nfqws2-helper"}, strings.Fields(os.Getenv("HELPER_ARGS"))...)
		main()
		return
	}
	cmd := exec.Command(os.Args[0], "-test.run=^TestMainFlags$")
	cmd.Env = append(os.Environ(), "HELPER_MAIN=1", "HELPER_ARGS=-fetch https://127.0.0.1:1/ -resolve 127.0.0.1:1 -o /dev/null -limit 1")
	out, _ := cmd.CombinedOutput()
	if strings.Contains(string(out), "panic") || strings.Contains(string(out), "flag redefined") || strings.Contains(string(out), "flag provided but not defined") {
		t.Fatalf("helper does not start: %s", out)
	}
	if f := strings.Fields(string(out)); len(f) < 8 {
		t.Fatalf("no fetch line: %q", out)
	}
}
