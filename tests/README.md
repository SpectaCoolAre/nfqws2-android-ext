# tests

Regression suite for the module and its WebUI. No dependencies for the module
side; the browser side needs `node` and, for the geometry test, `playwright`.

```
sh tests/run.sh            # everything
sh tests/run.sh --fast     # skip the slow service/rule-set and browser suites
sh tests/run.sh --keep     # keep the throwaway sandboxes for inspection
```

Exit status is 0 only when every suite passes.

## Layout

```
tests/
  run.sh                  orchestrator: runs every suite, prints a summary
  lib/
    harness.sh            assertions, sandbox builder, module helpers
    dump-ctl.sh           prints one ctl command's output from a fresh sandbox
    mock/                 stubs for the Android tools the module calls
      iptables            iptables/ip6tables with a real (tiny) rule store
      rm                  plain, fast, non-interactive rm
      nfqws2              fake daemon: writes a pidfile and detaches
      android-stub        pm / getprop / sysctl / modprobe, dispatched by name
  module/
    test_data.sh          configs, lists, blobs, module.prop, installer
    test_packaging.sh     the built archive carries module files only
    test_common.sh        pure logic from lib/common.sh
    test_ctl.sh           every nfqws2-ctl command the WebUI uses
    test_service.sh       service lifecycle and the generated iptables rules
  webui/
    test_static.js        script syntax, icon sprite, ids, accessibility
    test_contract.js      what index.html expects vs what the ctl actually emits
    test_layout.js        rendered geometry in headless Chromium
```

## Why the module tests need a sandbox

The scripts are written for a rooted Android device: they read `/data/adb`,
call `iptables`, `pm`, `getprop` and `sysctl`, and expect `sh` to be mksh.
`lib/harness.sh` builds a throwaway copy of the module under `/tmp`, puts stub
Android tools in front of `PATH`, and points `CONFDIR` at the sandbox, so every
system call is observable and nothing touches the real device state.

Two of those stubs are load-bearing:

* **`iptables`** keeps a real (if tiny) rule store. `firewall_stop()` and
  `firewall_start()` drain rules with `while iptables -D ... ; do :; done`, so a
  stub that always returns success loops forever.
* **`rm`** replaces the real one, which on some Windows setups is a safe-delete
  wrapper that can take seconds per call and occasionally prompts. The module
  removes files on nearly every code path, so the suite would crawl without it.

## Portability

The module scripts are checked and run under **dash** as well as bash — dash is
much closer to the `sh` Android ships. `NFQWS_TEST_SHELLS` overrides the list:

```
NFQWS_TEST_SHELLS="sh" sh tests/run.sh
```

## Environment

| Variable | Meaning |
|---|---|
| `NFQWS_TEST_KEEP=1` | keep the sandboxes and print their paths |
| `NFQWS_TEST_SHELLS` | shells to run the module suites under (default `dash bash`) |
| `NFQWS_TEST_NODE` | node binary for the WebUI suites |
| `NFQWS_TEST_NODE_PATH` | alias for `NODE_PATH`, so `playwright` resolves |
| `NFQWS_TEST_TMP` | parent directory for the sandboxes (default `/tmp`) |

The browser suite prints `SKIP` and exits 0 when `playwright` cannot be
resolved, so the rest of the suite still runs.

## Runtime

A full run takes several minutes on Windows/Git Bash: every process spawn costs
a few hundred milliseconds there and the suite spawns thousands of them
(`test_service.sh` alone builds ~260 iptables rules). The same suite finishes in
seconds on Linux. Use `--fast` while iterating.

## What each suite is really guarding

* **`test_data.sh`** — the shipped data must agree with itself. `customize.sh`
  installs from `lists/` while `reset-lists` restores from `defaults/lists/`, so
  if those two copies drift, a fresh install and a reset produce different
  results. That already happened once (commit `af8101b`).
* **`test_packaging.sh`** — the module archive must not carry `tests/`, `tools/`,
  `.workbuddy-ai/` or a nested release zip. It builds with `tools/build.py` and
  also simulates a hand-made `zip -r .` archive through the installer's cleanup,
  because the two guards protect against different mistakes: the builder stops
  the mistake at build time, the cleanup stops it at install time. Note that
  `unzip -x 'tests/*'` does **not** work for this — `*` does not cross `/`.
* **`test_common.sh`** — path rewriting in `norm_args` (the specific
  `/opt/etc/nfqws2/lua` rule has to win over the generic `/opt/etc/nfqws2` one),
  strategy filtering, config validation, and the argument assembly order.
* **`test_ctl.sh`** — `json-status` is the WebUI's only data source. Every field
  the UI reads must exist, and every field it compares numerically must be a
  JSON number: one stray non-numeric value makes the whole document
  unparseable and takes the UI down.
* **`test_contract.js`** — the same contract, checked from the WebUI's side:
  every command, parameter, list key and log source the UI sends must be
  accepted by the ctl.
* **`test_layout.js`** — geometry that was wrong once and is easy to break
  again: the split button's inner corner radius (a `9999px` radius next to a
  small one makes the browser scale *all* radii down, flattening the inner
  corners while `getComputedStyle` still reports the intended value), the
  counters living in their own card rather than inside the hero, and switch rows
  staying single-line.

## Hosts network pause and DNS cache refresh

* [test_hosts_pause.sh](module/test_hosts_pause.sh) exercises the real hosts ctl
  and service policy with sandboxed mounts: independent home/VPN switches,
  overlapping reasons, no-op polls, edits while paused, cold-start reconciliation,
  manual disable, backups including legacy archives, mount/stat errors, conflict
  detection, lock recovery, and racing watchers. Cache mocks record the visible
  file when notified; they do not assert Android runtime behavior.
* [test_dns_cache.sh](module/test_dns_cache.sh) mocks the bounded Android commands
  and checks capability detection, status/error parsing, native-before-app order,
  missing tools, permissions and timeouts. No real Android settings or services
  are modified by these tests.
* [test_hosts.js](webui/test_hosts.js) checks the hosts pause controls, status,
  errors, truthful saved/applied messages and independent home SSID editing.
* [Java resolver fixtures](java/dns-cache/run.sh) compile the production helper
  against tiny fake Android APIs, checking capability gaps, actual network IDs,
  duplicate IDs, vanished networks, and permission errors. Use a JDK 17 via
  `JAVA_HOME` (or `JAVAC`/`JAVA`). With no usable JDK the runner exits 77 and the
  main test runner reports SKIP; CI installs JDK 17 and requires these tests.

The cache helper uses the existing PkgList build (Java 8 bytecode, D8 min-api 21);
there is no new module minimum Android version. Host-side tests are not a rooted
Android/device test, and cannot prove visibility in every app mount namespace,
ROM-specific hidden-API availability, or invalidation of an app's private cache.
