/*
 * OTTO NAVI car GPS (P5 smoothing, offline build; P3 base).
 *
 * Buzz NMEA arrives in /dev/cargps_serial (OEM ctzgps kernel module; lylinkservice writes it when
 * persist.ly.hugps.enable=1). This process reads it and feeds Android's "gps" provider as a test
 * provider while the car delivers valid, fresh fixes. When the car goes silent the test provider is
 * removed again, so OTTO's own GNSS is the "gps" provider exactly as today (owner 2026-10-16:
 * car primary, OTTO GNSS fallback, Android location provider).
 *
 * One long-lived process, no per-fix exec. Android calls go through ILocationManager by reflection
 * (A17 framework-location.jar 4087eeb7..., signatures checked): addTestProvider(String,
 * ProviderProperties, List, String, String), setTestProviderEnabled(String, boolean, String, String),
 * setTestProviderLocation(String, Location, String, String), removeTestProvider(String, String, String).
 * LocationManagerService only checks AppOp 58 (MOCK_LOCATION) for the given package.
 *
 * P5: the car sends only 1 fix/s, so the arrow in Maps jumps once a second (owner 2026-10-16: map
 * moves evenly, arrow jumps). Between two car fixes the [Predictor] reports --rate-hz positions moved
 * forward along the car's own speed and course (turn rate and acceleration from the last two fixes). A real car fix
 * always replaces the estimate; no estimate is made more than --max-predict-ms after the last fix.
 * Locations also carry speed and bearing accuracy. Fix arrival gaps are logged with the stats.
 * A stop file gives a graceful exit (SIGTERM does not run shutdown hooks in app_process, P4), and a
 * leftover "gps" test provider is removed at startup.
 *
 * Usage:
 *   app_process / OttoCarGps [--device=/dev/cargps_serial] [--identity=root|shell] [--pkg=NAME]
 *                            [--accuracy=5.0] [--stale-ms=5000] [--car-on=3] [--off-ms=3000] [--dry]
 *                            [--rate-hz=10] [--max-predict-ms=1500] [--speed-acc=0.5] [--bearing-acc=5]
 *                            [--stop-file=PATH] [--no-set-clock]
 *   java OttoCarGps --replay=FILE --start=HH:MM:SS[.s] [--line-ms=333] [--tail-ms=5000] [--rate-hz=10] (offline test)
 */
import java.io.*;
import java.lang.reflect.*;
import java.util.*;

public final class OttoCarGps {

    // ---------------------------------------------------------------- options
    static String device = "/dev/cargps_serial";
    static String identity = "root";
    static String pkg = null;
    static float accuracyM = 5.0f;
    static long staleMs = 5000;
    static int carOn = 3;
    static long offMs = 3000;
    static boolean dry = false;
    static String replay = null;
    static long clockSkewMs = 0;                                            // replay only: simulated wall-clock error
    static long simMonoMs = -1;                                             // replay only: simulated monotonic clock
    /** Monotonic milliseconds (unaffected by the wall clock being unset or stepped). */
    static long monoMs() { return simMonoMs >= 0 ? simMonoMs : System.nanoTime() / 1000000L; }
    /** F6: beyond this the wall clock is treated as unset (OTTO boots at the build date until network time). */
    static final long CLOCK_UNSET_MS = 3600000L;
    static boolean setClock = true;                                         // F7: --no-set-clock disables it
    static boolean clockSet;
    static String replayStart = null;
    static long lineMs = 333;
    static long tailMs = 5000;
    static int rateHz = 10;
    static long maxPredictMs = 1500;
    /** 2026-11-01 (proven on a drive): Location extras "satellites" on every fix. Google Maps navigation declared
     *  "Searching for GPS" within 30-60 s on fresh car fixes without it, and held GPS for a whole drive with it.
     *  The car sends no satellite count; 12 stands for a good fix. --sat-extra=0 turns it off. */
    static int satExtra = 12;
    static float speedAccMps = 0.5f;
    static float bearingAccDeg = 5.0f;
    static String stopFile = null;

    // ---------------------------------------------------------------- fix
    static final class Fix {
        long utcMs;
        double lat, lon;
        float speedMps;
        float bearing;
        boolean hasBearing;
        int ggaQuality = -1;
        double ellipsoidAlt;
        boolean hasAlt;
        long arrivalMs;                                                     // local clock when the line was read
        boolean predicted;
    }

    // ---------------------------------------------------------------- NMEA
    static final class Nmea {
        private static final double KNOT = 0.514444;
        private int lastGgaQuality = -1;
        private double lastGgaMsl = Double.NaN, lastGgaSep = Double.NaN;
        private String lastGgaTime = null;
        int rejectedChecksum, rejectedFormat;

        static boolean checksumOk(String s) {
            int star = s.lastIndexOf('*');
            if (!s.startsWith("$") || star < 0 || star + 3 > s.length()) return false;
            int sum = 0;
            for (int i = 1; i < star; i++) sum ^= s.charAt(i);
            try {
                return sum == Integer.parseInt(s.substring(star + 1, star + 3), 16);
            } catch (NumberFormatException e) {
                return false;
            }
        }

        /** Returns a complete fix for a valid RMC sentence, null otherwise. GGA only updates the cache. */
        Fix feed(String line) {
            String s = line.trim();
            if (s.isEmpty()) return null;
            if (!checksumOk(s)) { rejectedChecksum++; return null; }
            String[] f = s.substring(1, s.lastIndexOf('*')).split(",", -1);
            String type = f[0].length() >= 5 ? f[0].substring(2) : f[0];
            try {
                if (type.equals("GGA") && f.length >= 12) {
                    lastGgaTime = f[1];
                    lastGgaQuality = f[6].isEmpty() ? -1 : Integer.parseInt(f[6]);
                    lastGgaMsl = f[9].isEmpty() ? Double.NaN : Double.parseDouble(f[9]);
                    lastGgaSep = f[11].isEmpty() ? Double.NaN : Double.parseDouble(f[11]);
                    return null;
                }
                if (type.equals("RMC") && f.length >= 10) {
                    if (!"A".equals(f[2])) return null;                       // V = no valid fix
                    if (f[1].length() < 6 || f[9].length() != 6 || f[3].isEmpty() || f[5].isEmpty()) {
                        rejectedFormat++;
                        return null;
                    }
                    Fix x = new Fix();
                    x.utcMs = utc(f[9], f[1]);
                    x.lat = degrees(f[3], f[4], 2);
                    x.lon = degrees(f[5], f[6], 3);
                    x.speedMps = f[7].isEmpty() ? 0f : (float) (Double.parseDouble(f[7]) * KNOT);
                    if (!f[8].isEmpty()) { x.bearing = (float) Double.parseDouble(f[8]); x.hasBearing = true; }
                    if (f[1].equals(lastGgaTime)) {                           // same epoch as the cached GGA
                        x.ggaQuality = lastGgaQuality;
                        if (!Double.isNaN(lastGgaMsl) && !Double.isNaN(lastGgaSep)) {
                            x.ellipsoidAlt = lastGgaMsl + lastGgaSep;            // only when the source gives both
                            x.hasAlt = true;
                        }
                    }
                    return x;
                }
            } catch (RuntimeException e) {
                rejectedFormat++;
            }
            return null;                                                      // PASCD and others: ignored
        }

        static double degrees(String v, String hemi, int degDigits) {
            double d = Double.parseDouble(v.substring(0, degDigits));
            double m = Double.parseDouble(v.substring(degDigits));
            double r = d + m / 60.0;
            return ("S".equals(hemi) || "W".equals(hemi)) ? -r : r;
        }

        static long utc(String ddmmyy, String hhmmss) {
            Calendar c = Calendar.getInstance(TimeZone.getTimeZone("UTC"));
            c.clear();
            c.set(2000 + Integer.parseInt(ddmmyy.substring(4, 6)), Integer.parseInt(ddmmyy.substring(2, 4)) - 1,
                    Integer.parseInt(ddmmyy.substring(0, 2)), Integer.parseInt(hhmmss.substring(0, 2)),
                    Integer.parseInt(hhmmss.substring(2, 4)), Integer.parseInt(hhmmss.substring(4, 6)));
            long ms = c.getTimeInMillis();
            int dot = hhmmss.indexOf('.');
            if (dot > 0) ms += Math.round(Double.parseDouble("0" + hhmmss.substring(dot)) * 1000);
            return ms;
        }
    }

    // ---------------------------------------------------------------- source selection
    interface Sink {
        void toCar() throws Exception;
        void toOtto() throws Exception;
        void report(Fix f) throws Exception;
    }

    static final class Selector {
        enum State { OTTO, CAR }
        State state = State.OTTO;
        int good;
        long lastGoodMs = Long.MIN_VALUE;                                   // monotonic
        int rejectedStale, reported, switches, freshByArrival;
        long prevUtcMs = Long.MIN_VALUE, prevMonoMs;
        final Sink sink;

        Selector(Sink sink) { this.sink = sink; }

        /* A fix is fresh when its UTC time is close to the wall clock (as before), or, F6 2026-10-31, when the wall clock
         * is clearly unset (OTTO boots at the build date and only gets network time on Wi-Fi) and the fix arrived about
         * one GPS second after the previous one, with its UTC time one second later too. That still rejects the old
         * lines ctzgps keeps from boot: they arrive as one burst. Before F6 every car fix was rejected until network
         * time arrived (seen 2026-10-31: stale=7 at boot), i.e. for a whole drive without network. */
        boolean fresh(Fix f, long nowMs) {
            long mono = monoMs();
            boolean byArrival = false;
            if (prevUtcMs != Long.MIN_VALUE) {
                long dUtc = f.utcMs - prevUtcMs, dMono = mono - prevMonoMs;
                byArrival = dUtc >= 500 && dUtc <= 2000 && dMono >= 500 && dMono <= 2000 && Math.abs(dUtc - dMono) <= 500;
            }
            prevUtcMs = f.utcMs; prevMonoMs = mono;
            long skew = Math.abs(nowMs - f.utcMs);
            if (skew <= staleMs) return true;
            if (skew > CLOCK_UNSET_MS && byArrival) { freshByArrival++; return true; }
            return false;
        }

        void onFix(Fix f, long nowMs) throws Exception {
            if (!fresh(f, nowMs)) {                                          // ctzgps keeps old lines from boot
                rejectedStale++;
                return;
            }
            if (freshByArrival >= carOn && Math.abs(nowMs - f.utcMs) > CLOCK_UNSET_MS) setClockFromCar(f, nowMs);
            good++;
            lastGoodMs = monoMs();
            f.arrivalMs = nowMs;
            if (state == State.OTTO && good >= carOn) {
                state = State.CAR;
                switches++;
                log(nowMs, "source=CAR after " + good + " valid fresh fixes");
                sink.toCar();
            }
            if (state == State.CAR) {
                sink.report(f);
                reported++;
            }
        }

        void onTick(long nowMs) throws Exception {
            long mono = monoMs();                                           // F6: a wall-clock step is not a car silence
            if (lastGoodMs != Long.MIN_VALUE && mono - lastGoodMs > offMs) {
                good = 0;
                if (state == State.CAR) {
                    state = State.OTTO;
                    switches++;
                    log(nowMs, "source=OTTO (no valid car fix for " + (mono - lastGoodMs) + " ms)");
                    sink.toOtto();
                }
            }
        }
    }

    // ---------------------------------------------------------------- smoothing
    /**
     * Sits between the selector and the real sink. Real fixes pass straight through; tick() fills the
     * gap until the next one by dead reckoning from the last fix (constant speed, constant turn rate).
     */
    static final class Predictor implements Sink {
        private static final double EARTH_M = 6371008.8;
        private static final float MIN_SPEED_MPS = 1.0f;                     // below this: hold, bearing is noise
        private static final float MAX_YAW_DPS = 45f;
        private static final float MAX_ACCEL_MPS2 = 4f;
        final Sink out;
        private boolean active;
        private Fix last;
        private float yawDps;
        private float accelMps2;
        int predicted;
        // arrival gaps between real fixes, reset with every stat line
        long gapMin = Long.MAX_VALUE, gapMax, gapSum;
        int gapN, gapLate;

        Predictor(Sink out) { this.out = out; }

        public void toCar() throws Exception { out.toCar(); active = true; }

        public void toOtto() throws Exception {
            active = false;
            last = null;
            out.toOtto();
        }

        public void report(Fix f) throws Exception {
            yawDps = 0f;
            accelMps2 = 0f;
            if (last != null) {
                long gap = f.arrivalMs - last.arrivalMs;
                gapMin = Math.min(gapMin, gap);
                gapMax = Math.max(gapMax, gap);
                gapSum += gap;
                gapN++;
                if (gap > 1500) gapLate++;
                long dtUtc = f.utcMs - last.utcMs;
                if (dtUtc >= 500 && dtUtc <= 2000) {
                    float a = (f.speedMps - last.speedMps) * 1000f / dtUtc;
                    accelMps2 = Math.max(-MAX_ACCEL_MPS2, Math.min(MAX_ACCEL_MPS2, a));
                    if (f.hasBearing && last.hasBearing && f.speedMps >= MIN_SPEED_MPS) {
                        float d = wrap180(f.bearing - last.bearing);
                        yawDps = Math.max(-MAX_YAW_DPS, Math.min(MAX_YAW_DPS, d * 1000f / dtUtc));
                    }
                }
            }
            last = f;
            out.report(f);
        }

        void tick(long nowMs) throws Exception {
            if (!active || last == null || !last.hasBearing || last.speedMps < MIN_SPEED_MPS) return;
            long dt = nowMs - last.arrivalMs;
            if (dt < 1000 / rateHz / 2 || dt > maxPredictMs) return;
            out.report(advance(last, dt, yawDps, accelMps2));
            predicted++;
        }

        static Fix advance(Fix f, long dtMs, float yawDps, float accelMps2) {
            double t = dtMs / 1000.0;
            if (accelMps2 < 0) t = Math.min(t, f.speedMps / -accelMps2);       // braking: never roll backwards
            double mid = Math.toRadians(f.bearing + yawDps * t / 2);           // chord of a constant-rate turn
            double dist = f.speedMps * t + accelMps2 * t * t / 2;
            Fix p = new Fix();
            p.lat = f.lat + Math.toDegrees(dist * Math.cos(mid) / EARTH_M);
            p.lon = f.lon + Math.toDegrees(dist * Math.sin(mid) / (EARTH_M * Math.cos(Math.toRadians(f.lat))));
            p.utcMs = f.utcMs + dtMs;                                        // real dt, also when t was capped
            p.speedMps = (float) Math.max(0, f.speedMps + accelMps2 * t);
            p.bearing = (float) ((f.bearing + yawDps * t) % 360 + 360) % 360;
            p.hasBearing = true;
            p.ggaQuality = f.ggaQuality;
            p.ellipsoidAlt = f.ellipsoidAlt;
            p.hasAlt = f.hasAlt;
            p.arrivalMs = f.arrivalMs;
            p.predicted = true;
            return p;
        }

        static float wrap180(float d) {
            d %= 360f;
            if (d > 180f) d -= 360f;
            if (d < -180f) d += 360f;
            return d;
        }

        String takeStats() {
            String s = "predicted=" + predicted + " gap_n=" + gapN
                    + (gapN > 0 ? " gap_ms_min=" + gapMin + " avg=" + gapSum / gapN + " max=" + gapMax : "")
                    + " gap_late=" + gapLate;
            gapMin = Long.MAX_VALUE;
            gapMax = gapSum = 0;
            gapN = gapLate = 0;
            return s;
        }
    }

    // ---------------------------------------------------------------- sinks
    static final class LogSink implements Sink {
        public void toCar() { System.out.println("SINK toCar"); }
        public void toOtto() { System.out.println("SINK toOtto"); }
        public void report(Fix f) {
            System.out.printf(Locale.ROOT, "SINK %s utc=%d lat=%.6f lon=%.6f spd=%.2f brg=%s q=%d alt=%s%n",
                    f.predicted ? "predict" : "report ", f.utcMs, f.lat, f.lon, f.speedMps, f.hasBearing ? String.format(Locale.ROOT, "%.1f", f.bearing) : "-",
                    f.ggaQuality, f.hasAlt ? String.format(Locale.ROOT, "%.1f", f.ellipsoidAlt) : "-");
        }
    }

    static final class AndroidSink implements Sink {
        private final Object ilm;
        private final Class<?> ilmClass, locClass, propsClass;
        private boolean active;

        AndroidSink() throws Exception {
            Class<?> sm = Class.forName("android.os.ServiceManager");
            Object binder = sm.getMethod("getService", String.class).invoke(null, "location");
            if (binder == null) throw new IllegalStateException("location service not found");
            ilmClass = Class.forName("android.location.ILocationManager");
            ilm = Class.forName("android.location.ILocationManager$Stub")
                    .getMethod("asInterface", Class.forName("android.os.IBinder")).invoke(null, binder);
            locClass = Class.forName("android.location.Location");
            propsClass = Class.forName("android.location.provider.ProviderProperties");
        }

        private Object props() throws Exception {
            Class<?> b = Class.forName("android.location.provider.ProviderProperties$Builder");
            Object x = b.getConstructor().newInstance();
            b.getMethod("setHasSatelliteRequirement", boolean.class).invoke(x, true);
            b.getMethod("setHasAltitudeSupport", boolean.class).invoke(x, true);
            b.getMethod("setHasSpeedSupport", boolean.class).invoke(x, true);
            b.getMethod("setHasBearingSupport", boolean.class).invoke(x, true);
            b.getMethod("setPowerUsage", int.class).invoke(x, 1);           // POWER_USAGE_LOW
            try { b.getMethod("setAccuracy", int.class).invoke(x, 1); } catch (NoSuchMethodException ignored) { } // ACCURACY_FINE
            return b.getMethod("build").invoke(x);
        }

        public void toCar() throws Exception {
            ilmClass.getMethod("addTestProvider", String.class, propsClass, List.class, String.class, String.class)
                    .invoke(ilm, "gps", props(), new ArrayList<String>(), pkg, null);
            ilmClass.getMethod("setTestProviderEnabled", String.class, boolean.class, String.class, String.class)
                    .invoke(ilm, "gps", true, pkg, null);
            active = true;
        }

        /** P4: a killed run can leave the mock "gps" behind; remove it before anything else. */
        boolean removeLeftover() {
            try {
                ilmClass.getMethod("removeTestProvider", String.class, String.class, String.class).invoke(ilm, "gps", pkg, null);
                return true;
            } catch (Exception e) {
                return false;                                                // none was there
            }
        }

        public void toOtto() throws Exception {
            if (!active) return;
            active = false;
            ilmClass.getMethod("removeTestProvider", String.class, String.class, String.class).invoke(ilm, "gps", pkg, null);
        }

        public void report(Fix f) throws Exception {
            Object l = locClass.getConstructor(String.class).newInstance("gps");
            locClass.getMethod("setLatitude", double.class).invoke(l, f.lat);
            locClass.getMethod("setLongitude", double.class).invoke(l, f.lon);
            locClass.getMethod("setTime", long.class).invoke(l, f.utcMs);
            long ern = (Long) Class.forName("android.os.SystemClock").getMethod("elapsedRealtimeNanos").invoke(null);
            locClass.getMethod("setElapsedRealtimeNanos", long.class).invoke(l, ern);
            locClass.getMethod("setAccuracy", float.class).invoke(l, accuracyM);
            locClass.getMethod("setSpeed", float.class).invoke(l, f.speedMps);
            locClass.getMethod("setSpeedAccuracyMetersPerSecond", float.class).invoke(l, speedAccMps);
            if (f.hasBearing) {
                locClass.getMethod("setBearing", float.class).invoke(l, f.bearing);
                locClass.getMethod("setBearingAccuracyDegrees", float.class).invoke(l, bearingAccDeg);
            }
            if (f.hasAlt) locClass.getMethod("setAltitude", double.class).invoke(l, f.ellipsoidAlt);
            if (satExtra > 0) {
                Class<?> bc = Class.forName("android.os.Bundle");
                Object b = bc.getConstructor().newInstance();
                bc.getMethod("putInt", String.class, int.class).invoke(b, "satellites", satExtra);
                locClass.getMethod("setExtras", bc).invoke(l, b);
            }
            ilmClass.getMethod("setTestProviderLocation", String.class, locClass, String.class, String.class)
                    .invoke(ilm, "gps", l, pkg, null);
        }
    }

    // ---------------------------------------------------------------- logging
    /* F7 2026-10-31: OTTO has no battery-backed clock and boots at the build date; network time only comes over Wi-Fi.
     * Once the car has sent carOn consecutive fixes that are fresh by arrival while the wall clock is more than an hour
     * off, set the system clock from the car's UTC time (root, toybox date; Android notices the change and sends
     * TIME_SET). Never when the clock is within an hour, so it cannot fight network time. At most once per process. */
    static void setClockFromCar(Fix f, long nowMs) {
        if (!setClock || clockSet) return;
        clockSet = true;
        String stamp = String.format(Locale.ROOT, "%1$tm%1$td%1$tH%1$tM%1$tY.%1$tS", utcCal(f.utcMs));
        if (replay != null || dry) { log(nowMs, "clock: would set to car UTC " + stamp + " (dry)"); return; }
        try {
            Process p = new ProcessBuilder("/system/bin/toybox", "date", "-u", stamp).redirectErrorStream(true).start();
            int rc = p.waitFor();
            log(System.currentTimeMillis(), "clock: set from car UTC " + stamp + " rc=" + rc + " (was " + new Date(nowMs) + ")");
        } catch (Exception e) {
            log(nowMs, "clock: set failed " + e);
        }
    }

    static Calendar utcCal(long ms) {
        Calendar c = Calendar.getInstance(TimeZone.getTimeZone("UTC"));
        c.setTimeInMillis(ms);
        return c;
    }

    static void log(long nowMs, String msg) {
        System.out.println(String.format(Locale.ROOT, "%tF %<tT otto_cargps: %s", new Date(nowMs), msg));
        System.out.flush();
    }

    // ---------------------------------------------------------------- main
    public static void main(String[] args) throws Exception {
        for (String a : args) {
            if (a.startsWith("--device=")) device = a.substring(9);
            else if (a.startsWith("--identity=")) identity = a.substring(11);
            else if (a.startsWith("--pkg=")) pkg = a.substring(6);
            else if (a.startsWith("--accuracy=")) accuracyM = Float.parseFloat(a.substring(11));
            else if (a.startsWith("--stale-ms=")) staleMs = Long.parseLong(a.substring(11));
            else if (a.startsWith("--car-on=")) carOn = Integer.parseInt(a.substring(9));
            else if (a.startsWith("--off-ms=")) offMs = Long.parseLong(a.substring(9));
            else if (a.equals("--dry")) dry = true;
            else if (a.equals("--no-set-clock")) setClock = false;
            else if (a.startsWith("--replay=")) replay = a.substring(9);
            else if (a.startsWith("--start=")) replayStart = a.substring(8);
            else if (a.startsWith("--clock-skew-ms=")) clockSkewMs = Long.parseLong(a.substring(16));
            else if (a.startsWith("--line-ms=")) lineMs = Long.parseLong(a.substring(10));
            else if (a.startsWith("--tail-ms=")) tailMs = Long.parseLong(a.substring(10));
            else if (a.startsWith("--rate-hz=")) rateHz = Integer.parseInt(a.substring(10));
            else if (a.startsWith("--max-predict-ms=")) maxPredictMs = Long.parseLong(a.substring(17));
            else if (a.startsWith("--sat-extra=")) satExtra = Integer.parseInt(a.substring(12));
            else if (a.startsWith("--speed-acc=")) speedAccMps = Float.parseFloat(a.substring(12));
            else if (a.startsWith("--bearing-acc=")) bearingAccDeg = Float.parseFloat(a.substring(14));
            else if (a.startsWith("--stop-file=")) stopFile = a.substring(12);
            else throw new IllegalArgumentException("unknown option " + a);
        }
        if (rateHz < 1 || rateHz > 20) throw new IllegalArgumentException("--rate-hz must be 1..20");
        if (pkg == null) pkg = identity.equals("shell") ? "com.android.shell" : "android";
        if (replay != null) { runReplay(); return; }
        runLive();
    }

    /** Offline: replay a capture with a simulated clock (no Android needed). */
    static void runReplay() throws Exception {
        Nmea nmea = new Nmea();
        Predictor pred = new Predictor(new LogSink());
        Selector sel = new Selector(pred);
        long tickMs = 1000 / rateHz;
        BufferedReader r = new BufferedReader(new FileReader(replay));
        String line;
        List<String> lines = new ArrayList<>();
        while ((line = r.readLine()) != null) lines.add(line);
        r.close();
        String date = null;
        for (String l : lines) if (l.startsWith("$GPRMC") && Nmea.checksumOk(l.trim())) { date = l.split(",")[9]; break; }
        long now = Nmea.utc(date, replayStart.replace(":", "")) + clockSkewMs;
        simMonoMs = 0;
        for (String l : lines) {
            Fix f = nmea.feed(l);
            if (f != null) sel.onFix(f, now);
            for (long t = 0; t < lineMs; ) {
                long step = Math.min(tickMs, lineMs - t);
                t += step;
                now += step; simMonoMs += step;
                sel.onTick(now);
                pred.tick(now);
            }
        }
        for (long t = 0; t < tailMs; t += tickMs) { now += tickMs; simMonoMs += tickMs; sel.onTick(now); pred.tick(now); }
        System.out.println("STATS " + pred.takeStats());
        System.out.printf("RESULT state=%s reported=%d rejected_stale=%d fresh_by_arrival=%d rejected_checksum=%d rejected_format=%d switches=%d%n",
                sel.state, sel.reported, sel.rejectedStale, sel.freshByArrival, nmea.rejectedChecksum, nmea.rejectedFormat, sel.switches);
    }

    /** Live: block on the device, tick every 500 ms for the fallback timer. */
    static void runLive() throws Exception {
        final InputStream in = new FileInputStream(device);                  // open as root, before any uid drop
        if (identity.equals("shell")) {
            Class.forName("android.system.Os").getMethod("setuid", int.class).invoke(null, 2000);
        }
        final Sink sink;
        if (dry) {
            sink = new LogSink();
        } else {
            AndroidSink a = new AndroidSink();
            log(System.currentTimeMillis(), "leftover gps test provider removed=" + a.removeLeftover());
            sink = a;
        }
        final Predictor pred = new Predictor(sink);
        final Selector sel = new Selector(pred);
        final Nmea nmea = new Nmea();
        Runtime.getRuntime().addShutdownHook(new Thread(() -> {             // never leave a mock "gps" behind
            try { if (sel.state == Selector.State.CAR) sink.toOtto(); } catch (Exception ignored) { }
        }));
        log(System.currentTimeMillis(), "start device=" + device + " identity=" + identity + " pkg=" + pkg
                + " dry=" + dry + " accuracy=" + accuracyM + " stale_ms=" + staleMs + " car_on=" + carOn + " off_ms=" + offMs
                + " rate_hz=" + rateHz + " max_predict_ms=" + maxPredictMs + " sat_extra=" + satExtra + " stop_file=" + stopFile);
        final Object lock = new Object();
        Thread reader = new Thread(() -> {
            BufferedReader br = new BufferedReader(new InputStreamReader(in));
            try {
                String l;
                while ((l = br.readLine()) != null) {
                    synchronized (lock) {
                        Fix f = nmea.feed(l);
                        if (f != null) sel.onFix(f, System.currentTimeMillis());
                    }
                }
                log(System.currentTimeMillis(), "device stream ended");
            } catch (Exception e) {
                log(System.currentTimeMillis(), "reader error: " + e);
            }
            System.exit(3);                                                  // supervisor restarts us
        }, "cargps-reader");
        reader.setDaemon(true);
        reader.start();
        long nextStat = System.currentTimeMillis() + 60000;
        while (true) {
            Thread.sleep(1000 / rateHz);
            long now = System.currentTimeMillis();
            synchronized (lock) {
                if (stopFile != null && new File(stopFile).exists()) {         // graceful stop: provider removed first
                    if (sel.state == Selector.State.CAR) sink.toOtto();
                    log(now, "stop file seen, provider removed, exit");
                    System.exit(0);
                }
                sel.onTick(now);
                try {
                    pred.tick(now);
                } catch (Exception e) {
                    log(now, "predict error: " + e);                         // never stop on an estimate
                }
                if (now >= nextStat) {
                    nextStat = now + 60000;
                    log(now, "stat state=" + sel.state + " reported=" + sel.reported + " stale=" + sel.rejectedStale + " fresh_by_arrival=" + sel.freshByArrival
                            + " bad_checksum=" + nmea.rejectedChecksum + " bad_format=" + nmea.rejectedFormat + " switches=" + sel.switches
                            + " " + pred.takeStats());
                }
            }
        }
    }
}
