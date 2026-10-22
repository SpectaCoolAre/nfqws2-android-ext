#!/bin/sh
# Pure host fixtures: no Android SDK, app_process, Binder, or device changes.
# Invoke with JAVA_HOME pointing at a JDK 9+ (the production build uses --release 8).
# Exit 77 explicitly skips an unavailable/stub Java toolchain.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
REPO_DIR=$(cd "$HERE/../../.." && pwd)
JAVAC=${JAVAC:-${JAVA_HOME:+$JAVA_HOME/bin/}javac}
JAVA=${JAVA:-${JAVA_HOME:+$JAVA_HOME/bin/}java}
if ! "$JAVAC" -version >/dev/null 2>&1 || ! "$JAVA" -version >/dev/null 2>&1; then
  printf 'SKIP DNS-cache Java fixtures: usable JDK unavailable (set JAVA_HOME/JAVAC/JAVA)\n'
  exit 77
fi
TMP=$(mktemp -d "${TMPDIR:-/tmp}/nfqws2-dns-java.XXXXXX")
TMP=$(cd "$TMP" && pwd)
cleanup() {
  case "$TMP" in
    /*/nfqws2-dns-java.??????)
      [ "$(cd "$TMP" && pwd)" = "$TMP" ] && rm -rf -- "$TMP" ;;
    *) printf 'Refusing unexpected Java fixture path\n' >&2 ;;
  esac
}
trap cleanup EXIT
trap 'exit 130' INT TERM
SRC="$TMP/src"
mkdir -p "$SRC/android/net" "$SRC/android/os" "$SRC/android/app" \
  "$SRC/android/content" "$SRC/android/system" "$SRC/fixture" \
  "$TMP/helper" "$TMP/fixtures" "$TMP/old-src/android/net" "$TMP/old"
cat > "$SRC/fixture/Scenario.java" <<'JAVA'
package fixture;
import java.io.FileWriter;
import java.io.IOException;
public final class Scenario {
    public static boolean is(String name) { return name.equals(System.getProperty("test.case")); }
    public static void record(int id) throws IOException {
        FileWriter out = new FileWriter(System.getProperty("test.trace"), true);
        try { out.write(Integer.toString(id) + "\n"); } finally { out.close(); }
    }
}
JAVA
cat > "$SRC/android/os/IBinder.java" <<'JAVA'
package android.os;
public interface IBinder {}
JAVA
cat > "$SRC/android/os/ServiceManager.java" <<'JAVA'
package android.os;
import fixture.Scenario;
public final class ServiceManager {
    public static IBinder checkService(String name) {
        if (!"dnsresolver".equals(name)) throw new AssertionError("wrong service");
        if (Scenario.is("service-missing")) return null;
        if (Scenario.is("service-denied")) throw new SecurityException("denied");
        return new IBinder() {};
    }
}
JAVA
cat > "$SRC/android/os/Looper.java" <<'JAVA'
package android.os;
public final class Looper {
    private static Looper main;
    public static Looper getMainLooper() { return main; }
    public static void prepareMainLooper() { main = new Looper(); }
}
JAVA
cat > "$SRC/android/os/ServiceSpecificException.java" <<'JAVA'
package android.os;
public class ServiceSpecificException extends RuntimeException {
    public final int errorCode;
    public ServiceSpecificException(int code) { errorCode = code; }
}
JAVA
cat > "$SRC/android/os/RemoteException.java" <<'JAVA'
package android.os;
public class RemoteException extends Exception {
    public RemoteException(String message) { super(message); }
}
JAVA
cat > "$SRC/android/system/OsConstants.java" <<'JAVA'
package android.system;
public final class OsConstants {
    public static final int EPERM=1, EACCES=13, ENONET=64, ENODEV=19, ENOENT=2;
    public static final int ETIMEDOUT=110, ENOSYS=38, EOPNOTSUPP=95;
}
JAVA
cat > "$SRC/android/app/ActivityThread.java" <<'JAVA'
package android.app;
import android.content.Context;
import fixture.Scenario;
public final class ActivityThread {
    public static ActivityThread systemMain() { return new ActivityThread(); }
    public Context getSystemContext() { return Scenario.is("context-null") ? null : new Context(); }
}
JAVA
cat > "$SRC/android/content/Context.java" <<'JAVA'
package android.content;
import android.net.ConnectivityManager;
import fixture.Scenario;
public class Context {
    public Object getSystemService(String name) {
        if (!"connectivity".equals(name)) throw new AssertionError("wrong manager");
        return Scenario.is("manager-null") ? null : new ConnectivityManager();
    }
}
JAVA
cat > "$SRC/android/net/Network.java" <<'JAVA'
package android.net;
public final class Network {
    public final int netId;
    public Network(int id) { netId=id; }
}
JAVA
cat > "$SRC/android/net/ConnectivityManager.java" <<'JAVA'
package android.net;
import fixture.Scenario;
public final class ConnectivityManager {
    public Network[] getAllNetworks() {
        if (Scenario.is("enumeration-denied")) throw new SecurityException("denied");
        if (Scenario.is("enumeration-error")) throw new IllegalStateException("broken");
        if (Scenario.is("null-array")) return null;
        if (Scenario.is("none")) return new Network[0];
        if (Scenario.is("invalid")) return new Network[] {new Network(0), new Network(-7)};
        if (Scenario.is("null-entry")) return new Network[] {null, new Network(844)};
        if (Scenario.is("mixed-invalid")) return new Network[] {new Network(0), new Network(844)};
        return new Network[] {new Network(731), new Network(844), new Network(731)};
    }
}
JAVA
cat > "$SRC/android/net/IDnsResolver.java" <<'JAVA'
package android.net;
import android.os.IBinder;
import android.os.RemoteException;
import android.os.ServiceSpecificException;
import android.system.OsConstants;
import fixture.Scenario;
public interface IDnsResolver {
    void flushNetworkCache(int id) throws Exception;
    abstract class Stub {
        public static IDnsResolver asInterface(IBinder binder) {
            return Scenario.is("resolver-null") ? null : new Proxy();
        }
        // Private on purpose: reflection must invoke the public interface method.
        private static final class Proxy implements IDnsResolver {
            public void flushNetworkCache(int id) throws Exception {
                Scenario.record(id);
                if (Scenario.is("unimplemented")) throw new RemoteException("Method flushNetworkCache is unimplemented.");
                if (Scenario.is("unsupported")) throw new UnsupportedOperationException();
                if (id != 731) return;
                if (Scenario.is("denied")) throw new SecurityException("denied");
                if (Scenario.is("errno-denied")) throw new ServiceSpecificException(OsConstants.EACCES);
                if (Scenario.is("gone")) throw new ServiceSpecificException(OsConstants.ENONET);
                if (Scenario.is("timeout")) throw new ServiceSpecificException(OsConstants.ETIMEDOUT);
                if (Scenario.is("failure")) throw new IllegalStateException("broken");
            }
        }
    }
}
JAVA
# No production source changes or SDK stubs on the production compilation classpath.
"$JAVAC" --release 8 -d "$TMP/helper" "$REPO_DIR/java/pkglist/com/deathwatcher/DnsCache.java"
"$JAVAC" --release 8 -d "$TMP/fixtures" "$SRC"/fixture/*.java "$SRC"/android/*/*.java
# API-29-like interface, with no named flush method. Loaded ahead of the fixture.
cat > "$TMP/old-src/android/net/IDnsResolver.java" <<'JAVA'
package android.net;
public interface IDnsResolver { boolean isAlive(); }
JAVA
"$JAVAC" --release 8 -d "$TMP/old" "$TMP/old-src/android/net/IDnsResolver.java"
PASS=0
FAIL=0
BOTH=$(printf '731\n844')
run_case() { # scenario status reason exit trace [classpath]
  scenario=$1; status=$2; reason=$3; expected_rc=$4; trace=$5
  classpath=${6:-$TMP/helper:$TMP/fixtures}
  : > "$TMP/trace"
  rc=0
  out=$("$JAVA" -Dtest.case="$scenario" -Dtest.trace="$TMP/trace" -cp "$classpath" com.deathwatcher.DnsCache 2>&1) || rc=$?
  expected=$(printf 'resolver=%s\nresolver_reason=%s' "$status" "$reason")
  actual_trace=$(cat "$TMP/trace")
  if [ "$rc" = "$expected_rc" ] && [ "$out" = "$expected" ] && [ "$actual_trace" = "$trace" ]; then
    PASS=$((PASS + 1)); printf 'ok %s\n' "$scenario"
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL %s: rc=%s expected=%s; output=[%s]; trace=[%s] expected=[%s]\n' \
      "$scenario" "$rc" "$expected_rc" "$out" "$actual_trace" "$trace"
  fi
}
run_case missing-api unsupported resolver_api_unavailable 0 '' "$TMP/helper"
run_case missing-method unsupported method_unavailable 0 '' "$TMP/old:$TMP/helper:$TMP/fixtures"
run_case duplicate-ids ok flushed 0 "$BOTH"
run_case none none no_networks 0 ''
run_case invalid failed invalid_network_id 1 ''
run_case mixed-invalid failed invalid_network_id 1 844
run_case null-entry failed network_gone 1 844
run_case null-array failed enumeration_failed 1 ''
run_case enumeration-denied failed permission_denied 1 ''
run_case enumeration-error failed enumeration_failed 1 ''
run_case context-null failed context_unavailable 1 ''
run_case manager-null failed connectivity_unavailable 1 ''
run_case service-missing unsupported service_unavailable 0 ''
run_case service-denied failed permission_denied 1 ''
run_case resolver-null failed resolver_unavailable 1 ''
run_case denied failed permission_denied 1 "$BOTH"
run_case errno-denied failed permission_denied 1 "$BOTH"
run_case gone failed network_gone 1 "$BOTH"
run_case timeout failed timeout 1 "$BOTH"
run_case failure failed flush_failed 1 "$BOTH"
run_case unimplemented unsupported method_unavailable 0 "$BOTH"
run_case unsupported unsupported method_unavailable 0 "$BOTH"
printf 'DNS-cache Java fixtures: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
