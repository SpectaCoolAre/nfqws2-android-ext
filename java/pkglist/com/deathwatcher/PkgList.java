package com.deathwatcher;
import java.io.*;
import java.lang.reflect.*;
import java.util.*;
public class PkgList {
    static class AppItem implements Comparable<AppItem> {
        String pkg;
        String name;
        String icon;
        boolean system;
        boolean selected;
        AppItem(String pkg, String name, String icon, boolean system) {
            this.pkg = pkg;
            this.name = name;
            this.icon = icon;
            this.system = system;
        }
        @Override
        public int compareTo(AppItem o) {
            if (this.selected != o.selected) {
                return this.selected ? -1 : 1;
            }
            return this.name.compareToIgnoreCase(o.name);
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
            Object pm = getPackageManager();
            if (pm != null) {
                List<?> apps = getInstalledApps(pm);
                Class<?> appInfoCls = Class.forName("android.content.pm.ApplicationInfo");
                Field pkgField = appInfoCls.getField("packageName");
                Field flagsField = appInfoCls.getField("flags");
                Method loadLabel = appInfoCls.getMethod("loadLabel", Class.forName("android.content.pm.PackageManager"));
                Method loadIcon = appInfoCls.getMethod("loadIcon", Class.forName("android.content.pm.PackageManager"));
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
                        // Filter: include 3rd party, updated system, launchable, or already selected apps
                        boolean isSelected = selectedPkgs.contains(pkg.toLowerCase(Locale.ROOT));
                        if (!isSystem || isUpdatedSystem || hasLaunch || isSelected) {
                            CharSequence cs = null;
                            try {
                                cs = (CharSequence) loadLabel.invoke(ai, pm);
                            } catch (Throwable ignored) {}
                            String label = (cs != null && cs.length() > 0) ? cs.toString().trim() : pkg;
                            String icon = "";
                            try {
                                Object drawable = loadIcon.invoke(ai, pm);
                                if (drawable != null) {
                                    icon = drawableToBase64Png(drawable);
                                }
                            } catch (Throwable ignored) {}
                            AppItem item = new AppItem(pkg, label, icon, isSystem && !isUpdatedSystem);
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
            sb.append("\"system\":").append(item.system);
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
                fos.write(json.getBytes("UTF-8"));
                fos.flush();
                fos.close();
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
    private static Object getPackageManager() {
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
                    if (ctx != null) {
                        Method getPm = ctx.getClass().getMethod("getPackageManager");
                        Object pm = getPm.invoke(ctx);
                        if (pm != null) return pm;
                    }
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
                Object ctx = getCtx.invoke(at);
                if (ctx != null) {
                    Method getPm = ctx.getClass().getMethod("getPackageManager");
                    return getPm.invoke(ctx);
                }
            } catch (Throwable ignored) {}
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
            Object bitmap = createBitmap.invoke(null, size, size, argb8888);
            Constructor<?> canvasCtor = canvasCls.getConstructor(bitmapCls);
            Object canvas = canvasCtor.newInstance(bitmap);
            Method setBounds = drawableCls.getMethod("setBounds", int.class, int.class, int.class, int.class);
            setBounds.invoke(drawable, 0, 0, size, size);
            Method draw = drawableCls.getMethod("draw", canvasCls);
            draw.invoke(drawable, canvas);
            ByteArrayOutputStream baos = new ByteArrayOutputStream();
            Field pngField = compressFormatCls.getField("PNG");
            Object pngFormat = pngField.get(null);
            Method compress = bitmapCls.getMethod("compress", compressFormatCls, int.class, OutputStream.class);
            compress.invoke(bitmap, pngFormat, 100, baos);
            Method recycle = bitmapCls.getMethod("recycle");
            recycle.invoke(bitmap);
            byte[] bytes = baos.toByteArray();
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