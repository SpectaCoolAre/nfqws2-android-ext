package com.deathwatcher;
import java.io.*;
import java.lang.reflect.*;
import java.util.*;

public class PkgList {
    static class UserRecord {
        final int id;
        final String name;
        final boolean isWork;
        UserRecord(int id, String name, boolean isWork) {
            this.id = id;
            this.name = name;
            this.isWork = isWork;
        }
    }

    static class AppItem implements Comparable<AppItem> {
        String pkg;
        String name;
        String icon;
        boolean system;
        boolean selected;
        int userId;
        String userName;
        boolean isWork;

        AppItem(String pkg, String name, String icon, boolean system, int userId, String userName, boolean isWork) {
            this.pkg = pkg;
            this.name = name;
            this.icon = icon;
            this.system = system;
            this.userId = userId;
            this.userName = userName;
            this.isWork = isWork;
        }

        @Override
        public int compareTo(AppItem o) {
            if (this.selected != o.selected) {
                return this.selected ? -1 : 1;
            }
            int c = this.name.compareToIgnoreCase(o.name);
            if (c != 0) return c;
            if (this.userId != o.userId) {
                return this.userId < o.userId ? -1 : 1;
            }
            return this.pkg.compareTo(o.pkg);
        }
    }

    public static void main(String[] args) {
        String outFile = null;
        String appsListFile = null;
        for (int i = 0; i < args.length; i++) {
            if ("--out".equals(args[i]) && i + 1 < args.length) {
                outFile = args[++i];
            } else if ("--apps-list".equals(args[i]) && i + 1 < args.length) {
                appsListFile = args[++i];
            } else if (args[i].endsWith(".json")) {
                outFile = args[i];
            }
        }
        Set<String> selectedPkgs = new HashSet<String>();
        if (appsListFile != null) {
            readSelected(new File(appsListFile), selectedPkgs);
        } else {
            File defApps = new File("/data/adb/modules/nfqws2-android/apps.list");
            if (defApps.exists()) readSelected(defApps, selectedPkgs);
        }

        List<AppItem> items = new ArrayList<AppItem>();
        try {
            Object sysCtx = getSystemContext();
            List<UserRecord> users = getUsers(sysCtx);

            Class<?> appInfoCls = Class.forName("android.content.pm.ApplicationInfo");
            Class<?> pmCls = Class.forName("android.content.pm.PackageManager");
            Field pkgField = appInfoCls.getField("packageName");
            Field flagsField = appInfoCls.getField("flags");
            Method loadLabel = appInfoCls.getMethod("loadLabel", pmCls);
            Method loadIcon = appInfoCls.getMethod("loadIcon", pmCls);
            Method loadUnbadgedIcon = null;
            try {
                loadUnbadgedIcon = appInfoCls.getMethod("loadUnbadgedIcon", pmCls);
            } catch (Throwable ignored) {}

            for (UserRecord user : users) {
                Object pm = getPackageManagerForUser(sysCtx, user.id);
                if (pm == null && user.id == 0 && sysCtx != null) {
                    try {
                        pm = sysCtx.getClass().getMethod("getPackageManager").invoke(sysCtx);
                    } catch (Throwable ignored) {}
                }
                if (pm == null) continue;

                List<?> apps = getInstalledApps(pm);
                Method getLaunchIntent = null;
                try {
                    getLaunchIntent = pm.getClass().getMethod("getLaunchIntentForPackage", String.class);
                } catch (Throwable ignored) {}

                for (Object ai : apps) {
                    if (ai == null) continue;
                    try {
                        String pkg = (String) pkgField.get(ai);
                        if (pkg == null || pkg.isEmpty() || "android".equals(pkg)) continue;
                        int flags = flagsField.getInt(ai);
                        boolean isSystem = (flags & 1) != 0; // FLAG_SYSTEM
                        boolean isUpdatedSystem = (flags & 128) != 0; // FLAG_UPDATED_SYSTEM_APP
                        boolean hasLaunch = false;
                        if (getLaunchIntent != null) {
                            try {
                                hasLaunch = getLaunchIntent.invoke(pm, pkg) != null;
                            } catch (Throwable ignored) {}
                        }
                        String lowerPkg = pkg.toLowerCase(Locale.ROOT);
                        String userPrefixedPkg = user.id + ":" + lowerPkg;
                        boolean isSelected = selectedPkgs.contains(lowerPkg) || selectedPkgs.contains(userPrefixedPkg);
                        if (!isSystem || isUpdatedSystem || hasLaunch || isSelected) {
                            CharSequence cs = null;
                            try {
                                cs = (CharSequence) loadLabel.invoke(ai, pm);
                            } catch (Throwable ignored) {}
                            String label = (cs != null && cs.length() > 0) ? cs.toString().trim() : pkg;
                            String icon = "";
                            try {
                                Object drawable = null;
                                // 1. Try loadUnbadgedIcon first — critical for work profiles (user.id != 0).
                                // Android's ApplicationInfo.loadIcon() calls getUserBadgedIcon(), which queries
                                // DevicePolicyManager / LauncherApps and crashes with NullPointerException
                                // in headless app_process sessions. loadUnbadgedIcon bypasses badging completely.
                                if (loadUnbadgedIcon != null) {
                                    try {
                                        drawable = loadUnbadgedIcon.invoke(ai, pm);
                                    } catch (Throwable ignored) {}
                                }
                                // 2. For work profile apps, try pm.getApplicationIcon(pkg) — high-level PM lookup
                                if (drawable == null && user.id != 0) {
                                    try {
                                        Method getAppIcon = pm.getClass().getMethod("getApplicationIcon", String.class);
                                        drawable = getAppIcon.invoke(pm, pkg);
                                    } catch (Throwable ignored) {}
                                }
                                // 3. Fallback: load via per-package context for work profiles
                                if (drawable == null && user.id != 0 && sysCtx != null) {
                                    Object appPm = getPackageManagerForUserPkg(sysCtx, pkg, user.id);
                                    if (appPm != null) {
                                        if (loadUnbadgedIcon != null) {
                                            try {
                                                drawable = loadUnbadgedIcon.invoke(ai, appPm);
                                            } catch (Throwable ignored) {}
                                        }
                                        if (drawable == null) {
                                            try {
                                                drawable = loadIcon.invoke(ai, appPm);
                                            } catch (Throwable ignored) {}
                                        }
                                    }
                                }
                                // 4. Standard loadIcon fallback
                                if (drawable == null) {
                                    try {
                                        drawable = loadIcon.invoke(ai, pm);
                                    } catch (Throwable ignored) {}
                                }
                                // 5. If still null, try launcher activity icon
                                if (drawable == null && getLaunchIntent != null) {
                                    try {
                                        Object intent = getLaunchIntent.invoke(pm, pkg);
                                        if (intent != null) {
                                            Method getActivityIcon = pm.getClass().getMethod("getActivityIcon", intent.getClass());
                                            drawable = getActivityIcon.invoke(pm, intent);
                                        }
                                    } catch (Throwable ignored) {}
                                }
                                if (drawable != null) {
                                    icon = drawableToBase64Png(drawable);
                                }
                            } catch (Throwable ignored) {}
                            AppItem item = new AppItem(pkg, label, icon, isSystem && !isUpdatedSystem, user.id, user.name, user.isWork);
                            item.selected = isSelected;
                            items.add(item);
                        }
                    } catch (Throwable ignored) {}
                }
            }
        } catch (Throwable t) {
            // Output minimal info or error
        }

        Collections.sort(items);
        StringBuilder sb = new StringBuilder();
        sb.append("[\n");
        for (int i = 0; i < items.size(); i++) {
            AppItem item = items.get(i);
            sb.append("  {");
            sb.append("\"pkg\":").append(jsonEscape(item.pkg)).append(",");
            sb.append("\"name\":").append(jsonEscape(item.name)).append(",");
            sb.append("\"icon\":").append(jsonEscape(item.icon)).append(",");
            sb.append("\"system\":").append(item.system).append(",");
            sb.append("\"userId\":").append(item.userId).append(",");
            sb.append("\"userName\":").append(jsonEscape(item.userName)).append(",");
            sb.append("\"isWork\":").append(item.isWork);
            sb.append("}");
            if (i < items.size() - 1) sb.append(",");
            sb.append("\n");
        }
        sb.append("]\n");
        String json = sb.toString();
        if (outFile != null) {
            try {
                File out = new File(outFile);
                File parent = out.getParentFile();
                if (parent != null && !parent.exists()) parent.mkdirs();
                FileOutputStream fos = new FileOutputStream(out);
                try {
                    fos.write(json.getBytes("UTF-8"));
                    fos.flush();
                } finally {
                    fos.close();
                }
            } catch (Throwable t) {
                System.out.print(json);
                return;
            }
        }
        System.out.print(json);
    }

    private static void readSelected(File f, Set<String> set) {
        if (!f.exists()) return;
        BufferedReader r = null;
        try {
            r = new BufferedReader(new InputStreamReader(new FileInputStream(f), "UTF-8"));
            String line;
            while ((line = r.readLine()) != null) {
                line = line.trim();
                if (line.isEmpty() || line.startsWith("#")) continue;
                set.add(line.toLowerCase(Locale.ROOT));
            }
        } catch (Throwable ignored) {
        } finally {
            if (r != null) try { r.close(); } catch (Throwable ignored) {}
        }
    }

    private static Object getSystemContext() {
        try {
            try {
                Class<?> looperCls = Class.forName("android.os.Looper");
                Method getMainLooper = looperCls.getMethod("getMainLooper");
                if (getMainLooper.invoke(null) == null) {
                    Method prep = looperCls.getMethod("prepareMainLooper");
                    prep.invoke(null);
                }
            } catch (Throwable ignored) {}
            try {
                Class<?> atCls = Class.forName("android.app.ActivityThread");
                Method sysMain = atCls.getMethod("systemMain");
                Object at = sysMain.invoke(null);
                if (at != null) {
                    Method getCtx = atCls.getMethod("getSystemContext");
                    Object ctx = getCtx.invoke(at);
                    if (ctx != null) return ctx;
                }
            } catch (Throwable ignored) {}
            try {
                Class<?> atCls = Class.forName("android.app.ActivityThread");
                Constructor<?> ctor = atCls.getDeclaredConstructor();
                ctor.setAccessible(true);
                Object at = ctor.newInstance();
                try {
                    Method attach = atCls.getDeclaredMethod("attach", boolean.class, long.class);
                    attach.setAccessible(true);
                    attach.invoke(at, true, 0L);
                } catch (Throwable t) {
                    Method attach = atCls.getDeclaredMethod("attach", boolean.class);
                    attach.setAccessible(true);
                    attach.invoke(at, true);
                }
                Method getCtx = atCls.getMethod("getSystemContext");
                return getCtx.invoke(at);
            } catch (Throwable ignored) {}
        } catch (Throwable ignored) {}
        return null;
    }

    private static List<UserRecord> getUsers(Object ctx) {
        List<UserRecord> result = new ArrayList<UserRecord>();
        if (ctx != null) {
            try {
                Method getSystemService = ctx.getClass().getMethod("getSystemService", String.class);
                Object um = getSystemService.invoke(ctx, "user");
                if (um != null) {
                    Method getUsersMethod = um.getClass().getMethod("getUsers");
                    List<?> list = (List<?>) getUsersMethod.invoke(um);
                    if (list != null && !list.isEmpty()) {
                        Class<?> uiCls = Class.forName("android.content.pm.UserInfo");
                        Field fId = uiCls.getField("id");
                        Field fName = null;
                        try { fName = uiCls.getField("name"); } catch (Throwable ignored) {}
                        Field fFlags = null;
                        try { fFlags = uiCls.getField("flags"); } catch (Throwable ignored) {}
                        Method isManagedProfile = null;
                        try { isManagedProfile = uiCls.getMethod("isManagedProfile"); } catch (Throwable ignored) {}

                        for (Object u : list) {
                            if (u == null) continue;
                            // one malformed user must not hide all the others
                            try {
                                int id = fId.getInt(u);
                                String name = (fName != null) ? (String) fName.get(u) : "";
                                int flags = (fFlags != null) ? fFlags.getInt(u) : 0;
                                // authoritative signal only: isManagedProfile() or FLAG_MANAGED_PROFILE.
                                // A guest or second user also has id > 0 but is not a work profile.
                                boolean isWork = false;
                                if (isManagedProfile != null) {
                                    try {
                                        Object res = isManagedProfile.invoke(u);
                                        if (res instanceof Boolean) isWork = (Boolean) res;
                                    } catch (Throwable ignored) {}
                                }
                                if (!isWork && (flags & 0x00000020) != 0) { // FLAG_MANAGED_PROFILE = 0x20
                                    isWork = true;
                                }
                                if (name == null || name.trim().isEmpty()) {
                                    if (id == 0) name = "Личный";
                                    else if (isWork) name = "Рабочий (" + id + ")";
                                    else name = "Пользователь " + id;
                                }
                                result.add(new UserRecord(id, name, isWork));
                            } catch (Throwable ignored) {}
                        }
                    }
                }
            } catch (Throwable ignored) {}
        }
        if (result.isEmpty()) {
            result.add(new UserRecord(0, "Личный", false));
        }
        return result;
    }

    private static Object getUserHandle(Class<?> uhCls, int userId) {
        try {
            Method of = uhCls.getMethod("of", int.class);
            return of.invoke(null, userId);
        } catch (Throwable t) {
            try {
                Constructor<?> ctor = uhCls.getConstructor(int.class);
                return ctor.newInstance(userId);
            } catch (Throwable ignored) {}
        }
        return null;
    }

    private static Object getPackageManagerForUser(Object sysCtx, int userId) {
        if (sysCtx == null) return null;
        if (userId == 0) {
            try {
                return sysCtx.getClass().getMethod("getPackageManager").invoke(sysCtx);
            } catch (Throwable ignored) {}
        }
        // Android 11+ (API 30+): createContextAsUser(UserHandle, int) creates a user-bound
        // context directly without package name lookup overhead.
        try {
            Class<?> uhCls = Class.forName("android.os.UserHandle");
            Object userHandle = getUserHandle(uhCls, userId);
            if (userHandle != null) {
                try {
                    Method createContextAsUser = sysCtx.getClass().getMethod("createContextAsUser", uhCls, int.class);
                    Object userCtx = createContextAsUser.invoke(sysCtx, userHandle, 0);
                    if (userCtx != null) {
                        return userCtx.getClass().getMethod("getPackageManager").invoke(userCtx);
                    }
                } catch (Throwable ignored) {}
            }
        } catch (Throwable ignored) {}

        // Fallback for Android 8-10: createPackageContextAsUser("android", ...)
        return getPackageManagerForUserPkg(sysCtx, "android", userId);
    }

    // Creates a per-package context as the target user and returns its PackageManager.
    // This is required so that ApplicationInfo.loadUnbadgedIcon(pm) / loadIcon(pm) can resolve
    // drawable resources from the APK installed in the work profile (user.id != 0).
    private static Object getPackageManagerForUserPkg(Object sysCtx, String pkg, int userId) {
        if (sysCtx == null) return null;
        try {
            Class<?> uhCls = Class.forName("android.os.UserHandle");
            Object userHandle = getUserHandle(uhCls, userId);
            if (userHandle != null) {
                Method createPkgCtx = sysCtx.getClass().getMethod("createPackageContextAsUser", String.class, int.class, uhCls);
                // CONTEXT_IGNORE_SECURITY = 2
                Object userCtx = createPkgCtx.invoke(sysCtx, pkg, 2, userHandle);
                if (userCtx != null) {
                    return userCtx.getClass().getMethod("getPackageManager").invoke(userCtx);
                }
            }
        } catch (Throwable ignored) {}
        return null;
    }

    private static List<?> getInstalledApps(Object pm) {
        try {
            Method m = pm.getClass().getMethod("getInstalledApplications", int.class);
            Object res = m.invoke(pm, 0);
            if (res instanceof List) return (List<?>) res;
        } catch (Throwable ignored) {}
        try {
            Method m = pm.getClass().getMethod("getInstalledPackages", int.class);
            Object res = m.invoke(pm, 0);
            if (res instanceof List) {
                List<Object> apps = new ArrayList<Object>();
                for (Object pi : (List<?>) res) {
                    try {
                        Field f = pi.getClass().getField("applicationInfo");
                        Object ai = f.get(pi);
                        if (ai != null) apps.add(ai);
                    } catch (Throwable ignored) {}
                }
                return apps;
            }
        } catch (Throwable ignored) {}
        return Collections.emptyList();
    }

    private static String drawableToBase64Png(Object drawable) {
        try {
            Class<?> drawableCls = Class.forName("android.graphics.drawable.Drawable");
            Class<?> bitmapCls = Class.forName("android.graphics.Bitmap");
            Class<?> configCls = Class.forName("android.graphics.Bitmap$Config");
            Class<?> canvasCls = Class.forName("android.graphics.Canvas");
            Class<?> compressFormatCls = Class.forName("android.graphics.Bitmap$CompressFormat");
            Class<?> base64Cls = Class.forName("android.util.Base64");
            int size = 48;
            Field argb8888Field = configCls.getField("ARGB_8888");
            Object argb8888 = argb8888Field.get(null);
            Method createBitmap = bitmapCls.getMethod("createBitmap", int.class, int.class, configCls);
            Method recycle = bitmapCls.getMethod("recycle");
            Object bitmap = createBitmap.invoke(null, size, size, argb8888);
            ByteArrayOutputStream baos = new ByteArrayOutputStream();
            byte[] bytes;
            try {
                Constructor<?> canvasCtor = canvasCls.getConstructor(bitmapCls);
                Object canvas = canvasCtor.newInstance(bitmap);
                Method setBounds = drawableCls.getMethod("setBounds", int.class, int.class, int.class, int.class);
                setBounds.invoke(drawable, 0, 0, size, size);
                Method draw = drawableCls.getMethod("draw", canvasCls);
                draw.invoke(drawable, canvas);
                Field pngField = compressFormatCls.getField("PNG");
                Object pngFormat = pngField.get(null);
                Method compress = bitmapCls.getMethod("compress", compressFormatCls, int.class, OutputStream.class);
                compress.invoke(bitmap, pngFormat, 100, baos);
                bytes = baos.toByteArray();
            } finally {
                // the bitmap is native memory: release it even when drawing or
                // compression throws, and never leave the stream to the GC
                try { recycle.invoke(bitmap); } catch (Throwable ignored) {}
                try { baos.close(); } catch (Throwable ignored) {}
            }
            Method encodeToString = base64Cls.getMethod("encodeToString", byte[].class, int.class);
            Field noWrapField = base64Cls.getField("NO_WRAP");
            int noWrap = noWrapField.getInt(null);
            String b64 = (String) encodeToString.invoke(null, bytes, noWrap);
            return "data:image/png;base64," + b64;
        } catch (Throwable ignored) {
            return "";
        }
    }

    private static String jsonEscape(String s) {
        if (s == null) return "null";
        StringBuilder sb = new StringBuilder("\"");
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            switch (c) {
                case '"': sb.append("\\\""); break;
                case '\\': sb.append("\\\\"); break;
                case '\b': sb.append("\\b"); break;
                case '\f': sb.append("\\f"); break;
                case '\n': sb.append("\\n"); break;
                case '\r': sb.append("\\r"); break;
                case '\t': sb.append("\\t"); break;
                default:
                    if (c < ' ') {
                        String t = "000" + Integer.toHexString(c);
                        sb.append("\\u").append(t.substring(t.length() - 4));
                    } else {
                        sb.append(c);
                    }
                    break;
            }
        }
        sb.append("\"");
        return sb.toString();
    }
}
