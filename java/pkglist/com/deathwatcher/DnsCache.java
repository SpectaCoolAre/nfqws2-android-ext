package com.deathwatcher;

import java.lang.reflect.Field;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.util.LinkedHashSet;
import java.util.Locale;
import java.util.Set;

/**
 * Optional native resolver-cache refresh, launched by lib/dns-cache.sh as root.
 * Compiles with the existing Java 8 / D8 min-api 21 PkgList build, without an
 * Android SDK compile dependency. Uses only runtime, named framework APIs.
 *
 * IDnsResolver (and its Java Stub) is not exposed to app_process on every ROM.
 * In particular the base Android 10 interface has no flushNetworkCache method.
 * That is unsupported, not a reason to issue guessed Binder transactions or
 * destroy/recreate resolver configuration. The shell always handles the separate
 * application-cache broadcast, including when this helper cannot do anything.
 */
public final class DnsCache {
    private DnsCache() {}

    private static final class Result {
        final String status;
        final String reason;
        Result(String status, String reason) {
            this.status = status;
            this.reason = reason;
        }
    }

    public static void main(String[] args) {
        Result result;
        if (args.length != 0) {
            result = new Result("failed", "invalid_arguments");
        } else {
            try {
                result = flush();
            } catch (Throwable error) {
                result = classify(error, "helper_error");
            }
        }
        System.out.println("resolver=" + result.status);
        System.out.println("resolver_reason=" + result.reason);
        System.out.flush();
        // ActivityThread/Binders may have started other threads. Do not linger;
        // the external timeout is still required for hung framework/Binder calls.
        System.exit("failed".equals(result.status) ? 1 : 0);
    }

    private static Result flush() throws Exception {
        final Class<?> resolverClass;
        final Method flushCache;
        final Method asInterface;
        final Method checkService;
        try {
            resolverClass = Class.forName("android.net.IDnsResolver");
            flushCache = resolverClass.getMethod("flushNetworkCache", int.class);
            if (flushCache.getReturnType() != void.class) {
                return new Result("unsupported", "method_unavailable");
            }
            Class<?> binderClass = Class.forName("android.os.IBinder");
            asInterface = Class.forName("android.net.IDnsResolver$Stub")
                    .getMethod("asInterface", binderClass);
            // checkService is non-waiting: never waitForService/getService polling.
            checkService = Class.forName("android.os.ServiceManager")
                    .getMethod("checkService", String.class);
        } catch (ClassNotFoundException error) {
            return new Result("unsupported", "resolver_api_unavailable");
        } catch (NoSuchMethodException error) {
            return new Result("unsupported", "method_unavailable");
        } catch (LinkageError error) {
            return new Result("unsupported", "resolver_api_unavailable");
        }

        final Class<?> networkClass;
        final Field netIdField;
        final Object[] networks;
        try {
            networkClass = Class.forName("android.net.Network");
            // Android Network's named netId field: never decode guessed handles,
            // parse dumpsys text, or try a default such as 0/100.
            netIdField = networkClass.getField("netId");
            if (netIdField.getType() != int.class) {
                return new Result("unsupported", "network_id_unavailable");
            }
            Object context = systemContext();
            if (context == null) return new Result("failed", "context_unavailable");
            Class<?> contextClass = Class.forName("android.content.Context");
            Object manager = contextClass.getMethod("getSystemService", String.class)
                    .invoke(context, "connectivity");
            if (manager == null) return new Result("failed", "connectivity_unavailable");
            Class<?> managerClass = Class.forName("android.net.ConnectivityManager");
            Object all = managerClass.getMethod("getAllNetworks").invoke(manager);
            if (!(all instanceof Object[])) {
                return new Result("failed", "enumeration_failed");
            }
            networks = (Object[]) all;
        } catch (NoSuchFieldException error) {
            return new Result("unsupported", "network_id_unavailable");
        } catch (Throwable error) {
            return classify(error, "enumeration_failed");
        }

        Set<Integer> netIds = new LinkedHashSet<Integer>();
        Result problem = null;
        for (Object network : networks) {
            if (network == null) {
                problem = merge(problem, new Result("failed", "network_gone"));
                continue;
            }
            if (!networkClass.isInstance(network)) {
                problem = merge(problem, new Result("failed", "enumeration_failed"));
                continue;
            }
            try {
                int netId = netIdField.getInt(network);
                if (netId <= 0) {
                    problem = merge(problem, new Result("failed", "invalid_network_id"));
                } else {
                    netIds.add(Integer.valueOf(netId));
                }
            } catch (Throwable error) {
                problem = merge(problem, classify(error, "network_id_failed"));
            }
        }
        if (netIds.isEmpty()) {
            return problem != null ? problem : new Result("none", "no_networks");
        }

        final Object resolver;
        try {
            Object binder = checkService.invoke(null, "dnsresolver");
            if (binder == null) {
                return merge(problem, new Result("unsupported", "service_unavailable"));
            }
            resolver = asInterface.invoke(null, binder);
            if (resolver == null || !resolverClass.isInstance(resolver)) {
                return merge(problem, new Result("failed", "resolver_unavailable"));
            }
        } catch (Throwable error) {
            return merge(problem, classify(error, "service_error"));
        }

        int flushed = 0;
        for (Integer netId : netIds) {
            try {
                // Reflect on the public interface, not a private Proxy class.
                // Use the actual IDs returned by ConnectivityManager, once each.
                flushCache.invoke(resolver, netId);
                flushed++;
            } catch (Throwable error) {
                // Networks may disappear between enumeration and the Binder call.
                // Report that accurately, but still try all other enumerated IDs.
                problem = merge(problem, classify(error, "flush_failed"));
            }
        }
        if (problem != null) {
            if (flushed > 0 && "unsupported".equals(problem.status)) {
                return new Result("failed", problem.reason);
            }
            return problem;
        }
        return new Result("ok", "flushed");
    }

    private static Object systemContext() throws Exception {
        Class<?> looperClass = Class.forName("android.os.Looper");
        if (looperClass.getMethod("getMainLooper").invoke(null) == null) {
            looperClass.getMethod("prepareMainLooper").invoke(null);
        }
        Class<?> threadClass = Class.forName("android.app.ActivityThread");
        Object thread = threadClass.getMethod("systemMain").invoke(null);
        if (thread == null) return null;
        return threadClass.getMethod("getSystemContext").invoke(thread);
    }

    private static Result merge(Result previous, Result next) {
        if (previous == null) return next;
        // A capability gap cannot hide an actual failure elsewhere in the batch.
        if (!"failed".equals(previous.status) && "failed".equals(next.status)) return next;
        // Permissions deserve a specific diagnosis even if a network also vanished.
        if ("permission_denied".equals(next.reason)) return next;
        return previous;
    }

    private static Throwable unwrap(Throwable error) {
        while (error instanceof InvocationTargetException) {
            Throwable cause = ((InvocationTargetException) error).getTargetException();
            if (cause == null || cause == error) break;
            error = cause;
        }
        return error;
    }

    private static Result classify(Throwable error, String fallback) {
        error = unwrap(error);
        if (error instanceof SecurityException || errno(error, "EPERM") || errno(error, "EACCES")) {
            return new Result("failed", "permission_denied");
        }
        if (errno(error, "ENONET") || errno(error, "ENODEV") || errno(error, "ENOENT")) {
            return new Result("failed", "network_gone");
        }
        if (errno(error, "ETIMEDOUT")) return new Result("failed", "timeout");
        if (error instanceof ClassNotFoundException || error instanceof NoClassDefFoundError) {
            return new Result("unsupported", "framework_unavailable");
        }
        if (error instanceof NoSuchMethodException || error instanceof NoSuchMethodError
                || error instanceof AbstractMethodError || error instanceof UnsupportedOperationException
                || errno(error, "ENOSYS") || errno(error, "EOPNOTSUPP")) {
            return new Result("unsupported", "method_unavailable");
        }
        if (error instanceof IllegalAccessException) {
            return new Result("unsupported", "reflection_unavailable");
        }
        // AIDL can expose the named method while an older service rejects it.
        String message = String.valueOf(error.getMessage()).toLowerCase(Locale.ROOT);
        if (message.contains("permission denied") || message.contains("permission denial")) {
            return new Result("failed", "permission_denied");
        }
        if ("android.os.RemoteException".equals(error.getClass().getName())
                && (message.contains("unimplemented") || message.contains("unknown transaction"))) {
            return new Result("unsupported", "method_unavailable");
        }
        return new Result("failed", fallback);
    }

    private static boolean errno(Throwable error, String name) {
        if (!"android.os.ServiceSpecificException".equals(error.getClass().getName())) return false;
        try {
            int code = error.getClass().getField("errorCode").getInt(error);
            int expected = Class.forName("android.system.OsConstants").getField(name).getInt(null);
            return code == expected || code == -expected;
        } catch (Exception unavailable) {
            return false;
        } catch (LinkageError unavailable) {
            return false;
        }
    }
}
