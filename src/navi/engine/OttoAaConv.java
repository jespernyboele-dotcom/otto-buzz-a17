/*
 * OttoAaConv — Android Auto navigation messages (0x8003 / 0x8006 / 0x8007) -> normalized OTTO navigation
 * model -> otto_rgid event lines.
 *
 * Stage 1 (normalized, "N ..." lines) keeps everything Android Auto gave, including raw values.
 * Stage 2 (engine events) writes the otto_rgid input format (R4: plus the optional totals mcount / lanetot).
 * SPEC R2 (offline analysis build, not installed): stage 2 = producer state machine of OTTO_NATIVE_RGI_PRODUCER_SPEC_R2 §4,
 *     reroute policy selectable (--policy=A|B, no default), AndroidX type table, exit angles, junction type.
 * R6: canonical producer model (Addendum 11): reroute = state 5, state 0, new route from index 0; lanes selected only
 *     through the route update; the maneuver object is never sent twice; roundabouts carry junction type and exit angle.
 * R5: a maneuver without lanes says "lanes not showing" explicitly once lanes were shown in the session.
 * R4: maneuver and lane indices increase through the session and are never reused; a maneuver, its lanes and
 * its first distance are committed together.
 *
 * Only values observed in the Addendum-4 captures are given a meaning. Anything else is carried as
 * UNKNOWN with its raw number. Nothing is invented: no current road, no lane data that was not sent,
 * no reinterpretation of the roundabout angle.
 *
 * offline:  java OttoAaConv <capture file with "NAV <ms> <type hex> <payload hex>" lines> [--norm|--engine|--both]
 */
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.util.*;

public final class OttoAaConv {
    // ---------- strict protobuf reader: any inconsistency marks the whole message bad ----------
    static final class Rd {
        final byte[] b; int p; final int end; boolean bad;
        int no, wt; long num; int off, len;
        Rd(byte[] b, int off, int len) { this.b = b; p = off; end = off + len; }
        private long var() {
            long v = 0; int sh = 0;
            while (true) {
                if (p >= end || sh > 63) { bad = true; return 0; }
                int c = b[p++] & 0xff; v |= (long) (c & 0x7f) << sh; sh += 7;
                if ((c & 0x80) == 0) return v;
            }
        }
        boolean next() {
            if (bad || p >= end) return false;
            long k = var(); if (bad) return false;
            no = (int) (k >>> 3); wt = (int) (k & 7);
            if (no <= 0) { bad = true; return false; }
            if (wt == 0) { num = var(); }
            else if (wt == 2) { long l = var(); if (bad || l < 0 || l > end - p) { bad = true; return false; } len = (int) l; off = p; p += len; }
            else if (wt == 1) { if (end - p < 8) { bad = true; return false; } off = p; len = 8; p += 8; }
            else if (wt == 5) { if (end - p < 4) { bad = true; return false; } off = p; len = 4; p += 4; }
            else { bad = true; return false; }
            return !bad;
        }
        Rd sub() { return new Rd(b, off, len); }
        String str() { return new String(b, off, len, StandardCharsets.UTF_8); }
    }

    // ---------- parsed messages ----------
    static final class Dir { int shape; boolean rec; }
    static final class Step {
        int man = -1; boolean hasExitNo, hasExitAngle; int exitNo, exitAngle;
        String road = "", cue = ""; List<List<Dir>> lanes = new ArrayList<>();
        String key() { return man + "/" + (hasExitNo ? exitNo : -1) + "/" + (hasExitAngle ? exitAngle : -1) + "/" + road + "/" + cue; }
    }
    static final class State { List<Step> steps = new ArrayList<>(); List<String> dest = new ArrayList<>(); }
    static final class Dist { boolean hasM; long m; String shown = ""; boolean hasUnit; int unit; }
    static final class Pos { Dist step; boolean hasStepS; long stepS; Dist dest; String eta = ""; boolean hasDestS; long destS;
        int destCount; Dist destLast; String etaLast = ""; boolean hasDestSLast; long destSLast;   // X7: last of several destination distances
        boolean hasRoad; String curRoad = ""; }                                                    // X8: 0x8007 field 3

    static String name1(Rd r) { String s = ""; while (r.next()) if (r.no == 1 && r.wt == 2) s = r.str(); return s; }
    static State parseState(byte[] b) {
        State st = new State(); Rd m = new Rd(b, 0, b.length); List<Rd> all = new ArrayList<>(); all.add(m);
        while (m.next()) {
            if (m.no == 1 && m.wt == 2) {
                Step s = new Step(); Rd r = m.sub(); all.add(r);
                while (r.next()) {
                    if (r.no == 1 && r.wt == 2) { Rd x = r.sub(); all.add(x); while (x.next()) { if (x.no == 1 && x.wt == 0) s.man = (int) x.num; else if (x.no == 2 && x.wt == 0) { s.hasExitNo = true; s.exitNo = (int) x.num; } else if (x.no == 3 && x.wt == 0) { s.hasExitAngle = true; s.exitAngle = (int) x.num; } } }
                    else if (r.no == 2 && r.wt == 2) { Rd x = r.sub(); all.add(x); s.road = name1(x); }
                    else if (r.no == 3 && r.wt == 2) { List<Dir> lane = new ArrayList<>(); Rd l = r.sub(); all.add(l);
                        while (l.next()) if (l.no == 1 && l.wt == 2) { Dir d = new Dir(); Rd x = l.sub(); all.add(x); while (x.next()) { if (x.no == 1 && x.wt == 0) d.shape = (int) x.num; else if (x.no == 2 && x.wt == 0) d.rec = x.num != 0; } lane.add(d); }
                        s.lanes.add(lane); }
                    else if (r.no == 4 && r.wt == 2) { Rd x = r.sub(); all.add(x); s.cue = name1(x); }
                }
                st.steps.add(s);
            } else if (m.no == 2 && m.wt == 2) { Rd x = m.sub(); all.add(x); st.dest.add(name1(x)); }
        }
        for (Rd r : all) if (r.bad) return null;
        return st;
    }
    static Dist parseDist(Rd r, List<Rd> all) {
        Dist d = new Dist(); all.add(r);
        while (r.next()) { if (r.no == 1 && r.wt == 0) { d.hasM = true; d.m = r.num; } else if (r.no == 2 && r.wt == 2) d.shown = r.str(); else if (r.no == 3 && r.wt == 0) { d.hasUnit = true; d.unit = (int) r.num; } }
        return d;
    }
    static Pos parsePos(byte[] b) {
        Pos p = new Pos(); Rd m = new Rd(b, 0, b.length); List<Rd> all = new ArrayList<>(); all.add(m);
        while (m.next()) {
            if (m.no == 1 && m.wt == 2) { Rd s = m.sub(); all.add(s); while (s.next()) { if (s.no == 1 && s.wt == 2) p.step = parseDist(s.sub(), all); else if (s.no == 2 && s.wt == 0) { p.hasStepS = true; p.stepS = s.num; } } }
            else if (m.no == 2 && m.wt == 2 && optPosition.equals("legacy")) {      // exactly the R2 statement
                if (p.dest != null) continue; Rd s = m.sub(); all.add(s); while (s.next()) { if (s.no == 1 && s.wt == 2) p.dest = parseDist(s.sub(), all); else if (s.no == 2 && s.wt == 2) p.eta = s.str(); else if (s.no == 3 && s.wt == 0) { p.hasDestS = true; p.destS = s.num; } }
            }
            else if (m.no == 2 && m.wt == 2) {
                Rd s = m.sub(); all.add(s); Dist d = null; String eta = ""; boolean hasS = false; long ds = 0;
                while (s.next()) { if (s.no == 1 && s.wt == 2) d = parseDist(s.sub(), all); else if (s.no == 2 && s.wt == 2) eta = s.str(); else if (s.no == 3 && s.wt == 0) { hasS = true; ds = s.num; } }
                p.destCount++;
                if (p.destCount == 1) { p.dest = d; p.eta = eta; p.hasDestS = hasS; p.destS = ds; }      // first entry: exactly as before
                p.destLast = d; p.etaLast = eta; p.hasDestSLast = hasS; p.destSLast = ds;
            }
            else if (m.no == 3 && m.wt == 2 && !optPosition.equals("legacy")) { Rd x = m.sub(); all.add(x); p.hasRoad = true; p.curRoad = name1(x); }   // X8: current road
        }
        for (Rd r : all) if (r.bad) return null;
        return p;
    }
    static int parseStatus(byte[] b) {
        Rd m = new Rd(b, 0, b.length); int v = -1;
        while (m.next()) if (m.no == 1 && m.wt == 0) v = (int) m.num;
        return m.bad ? -2 : v;
    }

    // ---------- observed vocabulary (Addendum 4) ----------
    static String kind(Step s) {
        switch (s.man) {
            case 1: return "DEPART"; case 3: return "KEEP_LEFT"; case 4: return "EXIT_RIGHT"; case 5: return "SLIGHT_LEFT";
            case 6: return "SLIGHT_RIGHT"; case 7: return "LEFT"; case 8: return "RIGHT"; case 11: return "U_TURN";
            case 22: return "MOTORWAY_EXIT_RIGHT"; case 35: return "ROUNDABOUT"; case 46: return "ROUNDABOUT_EXIT"; case 39: return "ARRIVE";
            default: return "UNKNOWN_" + s.man;
        }
    }
    /** Reroute policy of stage 2: 'A' = state 5, state 0, new route from index 0; 'B' = state 5, indices continue. No default. */
    /* 0.5: OTTO_CONV_COMPAT=0.3 in the environment (regression runs only) restores every candidate-0.3 default, including
     * "no default reroute policy". It is never set on a device. */
    static final boolean COMPAT03 = "0.3".equals(System.getenv("OTTO_CONV_COMPAT"));
    static char reroutePolicy = COMPAT03 ? 0 : 'A';       // B7: policy A (route end, restart from index 0) is the default
    // ---- candidate switches (OFFLINE_NIGHT). Defaults = corrected behaviour; each has a value that restores the R2 bytes. ----
    static String optSourceName = "";          // X5: 0x5201 0x13 only when configured (R2 bytes: "Google Maps")
    static String optDestination = "first";    // X7: "first" (unchanged default) | "last"; which entry is the final stop is UNRESOLVED
    static String optDrivingSide = "source";   // X3: "source" = only where the roundabout direction implies it | "legacy" = always stated, default right
    static String optLaneUnknown = "keep";     // X6: "keep" = publish the set without the unknown direction | "drop" = R2: do not publish the set
    static String optLaneIndex = "independent"; // X17 (experiment, not a default): "aligned" = lane index never below the current maneuver index
    static String optPosition = "extended";    // X7 / X8: read every destination distance and field 3 of 0x8007 | "legacy" = R2: first destination only, field 3 not read
    static String optState0 = "inactive";      // X4: Android Auto state 0 handled like INACTIVE | "ignore" = R2: no effect
    static String optUnits = "source";         // X2: "source" = the unit the source states | "legacy" = R2: km for units 2 / 3, metres for everything else
    /* ---- 0.5 (architecture decisions B1-B12, 2026-10-12). The core sends only what the source states or what is true by definition.
     *      Anything a particular receiver needs beyond that lives in the receiver profile, which is OFF by default. ---- */
    static String optSideDefault = COMPAT03 ? "none" : "right";   // B5: traffic side where the source does not reveal it: right | left | none (installation setting)
    static String optJunction = COMPAT03 ? "source" : "all";     // B5: JunctionType on: all maneuvers (1 roundabout family, 0 otherwise) | turns (U-turns / ramps only) | source (roundabout family only)
    static String optText = COMPAT03 ? "legacy" : "exact";       // B8: exact = text reaches the engine unchanged (escaped on the line) | legacy = '|' -> '/', controls -> ' ', trimmed
    static String optReceiver = "none";                           // B1: receiver profile: none | mib4
    static String optMib4LeftOffRamp = "type22";                  // B3 (open until the car test): with --receiver=mib4, left off-ramp as type22 | source
    /* ---- 0.6: receiver rules as plain options, so a receiver profile FILE can set them (auto = the 0.5 behaviour of --receiver). ---- */
    static String optRbtNoNumber = "auto";                        // B2: roundabout with an angle but no valid exit number: auto | enter (core) | exit1
    static String optLeftOffRamp = "auto";                        // B3: left off-ramp (21/23): auto | source (core) | type22
    static String optFullCircleCcw = "plus180";                   // R4.1 R-3 / D-4 (open decision): counter-clockwise full circle (360) -> plus180 (0.5) | minus180 (R4 S5)
    static long clockBaseMs = -1;                                 // B9: wall clock (epoch ms) of capture time 0; -1 = no valid time base -> no arrival time is sent
    long wallMs = -1;                                             // set by a live caller before feed(): valid wall clock of this message, or -1
    static final long CLOCK_FLOOR_MS = 1735689600000L;            // 2025-01-01: anything earlier is not a set clock
    static boolean mib4() { return optReceiver.equals("mib4"); }
    /** one command-line argument of the 0.5 group; false = not ours */
    static boolean arg05(String x) {
        if (x.startsWith("--side-default=")) { optSideDefault = x.substring(15); return true; }
        if (x.startsWith("--junction-type=")) { optJunction = x.substring(16); return true; }
        if (x.startsWith("--text=")) { optText = x.substring(7); return true; }
        if (x.startsWith("--receiver=")) { optReceiver = x.substring(11); return true; }
        if (x.startsWith("--mib4-left-off-ramp=")) { optMib4LeftOffRamp = x.substring(21); return true; }
        if (x.startsWith("--rbt-no-number=")) { optRbtNoNumber = x.substring(16); return true; }
        if (x.startsWith("--left-off-ramp=")) { optLeftOffRamp = x.substring(16); return true; }
        if (x.startsWith("--full-circle-ccw=")) { optFullCircleCcw = x.substring(18); return true; }
        if (x.startsWith("--clock-base=")) { try { clockBaseMs = Long.parseLong(x.substring(13)); } catch (NumberFormatException e) { clockBaseMs = -2; } return true; }
        return false;
    }
    static String check05() {
        if (!optSideDefault.equals("none") && !optSideDefault.equals("right") && !optSideDefault.equals("left")) return "--side-default=right|left|none";
        if (!optJunction.equals("all") && !optJunction.equals("turns") && !optJunction.equals("source")) return "--junction-type=all|turns|source";
        if (!optText.equals("exact") && !optText.equals("legacy")) return "--text=exact|legacy";
        if (!optReceiver.equals("none") && !optReceiver.equals("mib4")) return "--receiver=none|mib4";
        if (!optMib4LeftOffRamp.equals("type22") && !optMib4LeftOffRamp.equals("source")) return "--mib4-left-off-ramp=type22|source";
        if (!optRbtNoNumber.equals("auto") && !optRbtNoNumber.equals("enter") && !optRbtNoNumber.equals("exit1")) return "--rbt-no-number=auto|enter|exit1";
        if (!optLeftOffRamp.equals("auto") && !optLeftOffRamp.equals("source") && !optLeftOffRamp.equals("type22")) return "--left-off-ramp=auto|source|type22";
        if (!optFullCircleCcw.equals("plus180") && !optFullCircleCcw.equals("minus180")) return "--full-circle-ccw=plus180|minus180";
        if (clockBaseMs != -1 && clockBaseMs < CLOCK_FLOOR_MS) return "--clock-base=<epoch milliseconds, 2025 or later>";
        return null;
    }
    static void resetOptions() { optSourceName = ""; optDestination = "first"; optDrivingSide = "source"; optLaneUnknown = "keep"; optUnits = "source"; optState0 = "inactive"; optPosition = "extended"; optLaneIndex = "independent";
        optSideDefault = COMPAT03 ? "none" : "right"; optJunction = COMPAT03 ? "source" : "all"; optText = COMPAT03 ? "legacy" : "exact"; optReceiver = "none"; optMib4LeftOffRamp = "type22"; clockBaseMs = -1;
        optRbtNoNumber = "auto"; optLeftOffRamp = "auto"; optFullCircleCcw = "plus180"; }
    static boolean roundabout(int m) { return m == 32 || m == 33 || m == 34 || m == 35; }
    static boolean clockwise(int m) { return m == 32 || m == 33 || m == 43 || m == 44; }
    /** X3: the roundabout circulation is the only place where Android Auto reveals the traffic side; elsewhere it is unknown. */
    static String sideOf(int m) {
        if (clockwise(m)) return "left";
        if (roundabout(m) || (m >= 43 && m <= 46) || optDrivingSide.equals("legacy")) return "right";
        return optSideDefault;                 // B5: installation setting; "none" = the field is left out
    }
    static boolean validExit(Step s) { return s.hasExitNo && s.exitNo >= 1 && s.exitNo <= 19; }
    /** JunctionType: 1 = roundabout, 0 = not a roundabout; -1 = not sent */
    static int junctionType(Step s) {
        if (roundabout(s.man) || (s.man >= 43 && s.man <= 46)) return 1;
        if (optJunction.equals("all")) return 0;
        if (optJunction.equals("turns") && s.man >= 11 && s.man <= 24) return 0;
        return -1;
    }
    /** AndroidX Maneuver.TYPE_* -> iAP2 maneuver type name. Values outside the AndroidX enum: NO_TURN, logged as unknown. */
    /** 0.6: the receiver rules as options. "auto" keeps 0.5: the rule applies only with --receiver=mib4. */
    static boolean rbtNoNumberExit1() { return optRbtNoNumber.equals("exit1") || (optRbtNoNumber.equals("auto") && mib4()); }
    static boolean leftOffRampType22() {
        if (optLeftOffRamp.equals("auto")) return mib4() && optMib4LeftOffRamp.equals("type22");
        return optLeftOffRamp.equals("type22");
    }
    static String rgiType(Step s) {
        // Receiver rules - NOT part of the universal core. Each rule states something the source did not say.
        if ((s.man == 33 || s.man == 35) && s.hasExitAngle && !validExit(s) && rbtNoNumberExit1()) return "ROUNDABOUT_EXIT_1";   // B2: the MIB4 never shows the number and needs an exit type to draw a roundabout
        if ((s.man == 21 || s.man == 23) && leftOffRampType22()) return "HIGHWAY_OFF_RAMP_LEFT";                                  // B3: open until type 8 with a negative angle has been seen on the car
        switch (s.man) {
            case 0: return "NO_TURN"; case 1: return "START_ROUTE"; case 2: return "FOLLOW_ROAD";
            case 3: return "KEEP_LEFT"; case 4: return "KEEP_RIGHT";
            case 5: return "SLIGHT_LEFT_TURN"; case 6: return "SLIGHT_RIGHT_TURN"; case 7: return "LEFT_TURN"; case 8: return "RIGHT_TURN";
            case 9: return "SHARP_LEFT_TURN"; case 10: return "SHARP_RIGHT_TURN"; case 11: case 12: return "U_TURN";
            case 13: case 14: case 15: case 16: case 17: case 18: case 19: case 20: return "ON_RAMP";
            case 21: case 22: case 23: case 24: return "OFF_RAMP";
            case 25: return "KEEP_LEFT"; case 26: return "KEEP_RIGHT";
            case 32: case 33: case 34: case 35: return s.hasExitNo && s.exitNo >= 1 && s.exitNo <= 19 ? "ROUNDABOUT_EXIT_" + s.exitNo : "ENTER_ROUNDABOUT";
            case 36: return "STRAIGHT_AHEAD"; case 37: case 38: case 47: case 48: case 49: case 50: return "ENTER_FERRY";
            case 39: case 40: return "ARRIVE_AT_DESTINATION"; case 41: return "ARRIVE_DESTINATION_LEFT"; case 42: return "ARRIVE_DESTINATION_RIGHT";
            case 43: case 45: return "ENTER_ROUNDABOUT"; case 44: case 46: return "EXIT_ROUNDABOUT";
            default: return "NO_TURN";      // 27-29 merge (no iAP2 counterpart), 30/31 undefined, anything newer
        }
    }
    /** signed exit angle where the type alone does not carry the side; 9999 = none */
    static int exitAngle(Step s) {
        if (roundabout(s.man) && s.hasExitAngle && (s.man == 33 || s.man == 35)) {   // degrees travelled round the circle -> bearing of the exit
            if (s.exitAngle == 360 && !clockwise(s.man) && optFullCircleCcw.equals("minus180")) return -180;   // R4 S5: the travel bends left
            int a = clockwise(s.man) ? s.exitAngle - 180 : 180 - s.exitAngle; while (a > 180) a -= 360; while (a <= -180) a += 360; return a;
        }
        switch (s.man) {
            case 11: case 19: return -180; case 12: case 20: return 180;
            case 13: case 21: return -45; case 14: case 22: return 45; case 15: case 23: return -90; case 16: case 24: return 90;
            case 17: return -135; case 18: return 135;
            default: return 9999;
        }
    }
    static String shapeName(int v) {
        switch (v) { case 1: return "straight"; case 2: return "slight_left"; case 3: return "slight_right"; case 4: return "left"; case 5: return "right"; case 8: return "u_turn_left"; default: return "shape" + v; }
    }
    static int shapeAngle(int v) {       // degrees, left negative; 9999 = not known
        switch (v) { case 1: return 0; case 2: return -45; case 3: return 45; case 4: return -90; case 5: return 90; case 6: return -135; case 7: return 135; case 8: return -180; case 9: return 180; default: return 9999; }
    }
    static String unitName(Dist d) { if (!d.hasUnit) return "none"; switch (d.unit) { case 1: return "m"; case 2: return "km"; case 3: return "km_1dec"; default: return "unit" + d.unit; } }
    /** X2: all eight AA distance units. The numeric value is metres in every locale; only the display unit differs. */
    static String engUnit(Dist d) {
        if (optUnits.equals("legacy")) return d.hasUnit && (d.unit == 2 || d.unit == 3) ? "km" : "m";
        if (!d.hasUnit) return "none";
        switch (d.unit) { case 1: return "m"; case 2: case 3: return "km"; case 4: case 5: return "mi"; case 6: return "ft"; case 7: return "yd"; default: return "none"; }
    }
    static String statusName(int v) { switch (v) { case 1: return "ACTIVE"; case 2: return "INACTIVE"; case 3: return "REROUTING"; default: return "UNKNOWN_" + v; } }

    // ---------- converter state ----------
    final List<String> out = new ArrayList<>();
    final boolean wantNorm, wantEng;
    int status = -1; String curKey = null; Step cur; int seq = 0; String lanesKey = ""; String dest = "";
    boolean routeOpen; String lastTrip = ""; Pos lastPos; long rejected, accepted;
    OttoAaConv(boolean norm, boolean eng) { wantNorm = norm; wantEng = eng; }

    static String q(String s) { return "\"" + s.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", " ").replace("\r", " ") + "\""; }
    /** B8: text for an engine event line, UNCHANGED for the receiver. The line format needs '|' and line ends for itself, so they are
     *  escaped (\\ = backslash, \p = '|', \xHH = control character) and the engine restores them. Only U+0000 cannot be carried
     *  (it ends an iAP2 string). Nothing is trimmed, replaced, normalized or transliterated. Cut at 300 bytes on a code point
     *  boundary: the engine keeps at most 255 bytes of any text. */
    static String evExact(String s) {
        StringBuilder sb = new StringBuilder(); int bytes = 0;
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i); int w = c < 0x80 ? 1 : c < 0x800 ? 2 : Character.isHighSurrogate(c) ? 4 : Character.isLowSurrogate(c) ? 0 : 3;
            if (Character.isHighSurrogate(c) && (i + 1 >= s.length() || !Character.isLowSurrogate(s.charAt(i + 1)))) w = 3;   // lone surrogate: becomes U+FFFD on output
            if (bytes + w > 300) break;
            bytes += w;
            if (c == 0) continue;
            if (c == '\\') sb.append("\\\\"); else if (c == '|') sb.append("\\p");
            else if (c < 0x20 || c == 0x7f) sb.append("\\x").append(Character.forDigit(c >> 4, 16)).append(Character.forDigit(c & 15, 16));
            else sb.append(c);
        }
        if (sb.length() > 0 && Character.isHighSurrogate(sb.charAt(sb.length() - 1)) && bytes >= 297) sb.setLength(sb.length() - 1);
        return sb.toString();
    }
    static String ev(String s) {         // text inside an engine event
        if (optText.equals("exact")) return evExact(s);
        StringBuilder sb = new StringBuilder();   // legacy (0.3): no separators, no control characters
        int bytes = 0;                    // X19: an event line must stay far below the engine's 4096-byte line buffer. The engine itself
        for (int i = 0; i < s.length(); i++) {   // cuts every text to at most 255 bytes, so 400 bytes here never changes what is sent.
            char c = s.charAt(i); int w = c < 0x80 ? 1 : c < 0x800 ? 2 : Character.isHighSurrogate(c) ? 4 : Character.isLowSurrogate(c) ? 0 : 3;
            if (bytes + w > 400) break;
            bytes += w; sb.append(c == '|' ? '/' : c < 0x20 ? ' ' : c);
        }
        if (sb.length() > 0 && Character.isHighSurrogate(sb.charAt(sb.length() - 1))) sb.setLength(sb.length() - 1);
        return sb.toString().trim();
    }
    void n(String s) { if (wantNorm) out.add("N " + s); }
    void e(String s) { if (wantEng) out.add(s); }
    void reject(int type, String why) { rejected++; n("REJECT type=" + String.format("%04x", type) + " " + why + " (state unchanged)"); }

    static String lanesText(Step s) {
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < s.lanes.size(); i++) { sb.append(i > 0 ? " " : "").append("L").append(i).append("=");
            List<Dir> l = s.lanes.get(i); for (int j = 0; j < l.size(); j++) sb.append(j > 0 ? "," : "").append(shapeName(l.get(j).shape)).append(l.get(j).rec ? "*" : ""); }
        return sb.toString();
    }
    /** engine lane event, or null when the set exceeds the 8-lane / 16-direction limit (then no lanes are sent, "showing 0") */
    static String lanesEngine(Step s, int idx) {
        StringBuilder sb = new StringBuilder("LANE|idx=" + idx);
        if (s.lanes.isEmpty() || s.lanes.size() > 8) return null;
        for (List<Dir> l : s.lanes) {
            if (l.isEmpty() || l.size() > 16) return null;
            StringBuilder a = new StringBuilder(); Integer hl = null;
            boolean rec = false, recUnknown = false;   // X6: a direction with an unknown shape is left out; the lane (and its recommendation) is kept
            for (int j = 0; j < l.size(); j++) {
                int ang = shapeAngle(l.get(j).shape); if (l.get(j).rec) rec = true;
                if (ang == 9999) { if (optLaneUnknown.equals("drop")) return null; if (l.get(j).rec) recUnknown = true; continue; }
                a.append(a.length() > 0 ? "," : "").append(ang); if (l.get(j).rec && hl == null) hl = ang;
            }
            // X6b: the recommended direction is the unknown one and no known direction is recommended -> list NO direction for this
            // lane. Listing the known, non-recommended ones would make a receiver that falls back to the first angle highlight
            // a direction the source never recommended (seen with the public parser).
            if (recUnknown && hl == null) a.setLength(0);
            sb.append("|l=").append(rec ? "preferred" : "notgood").append(":").append(a).append(hl != null ? ":" + hl : "");
        }
        return sb.toString();
    }
    // Indices grow for the whole guidance session and are never reused for a different maneuver / lane set:
    // the head unit keeps what it was given under an index. They restart only after the source went inactive.
    int manIdx = -1, laneIdx = -1; boolean pendingMan, pendingFresh, reroutePending, endPending; String laneExtra = ""; boolean roadSent;
    int nextLaneIdx() { return optLaneIndex.equals("aligned") ? Math.max(laneIdx + 1, manIdx) : laneIdx + 1; }
    /** the new maneuver, its lanes and the first position leave together, in one commit */
    void flushManeuver(boolean freshPos) {
        if (!pendingMan || cur == null) return;
        pendingMan = false; pendingFresh = false; Step s = cur;
        if (endPending) { endPending = false; e("ROUTE_END"); }   // a route that went inactive is ended on the wire (state 0) before
                                                                  // index 0 is used again; no effect if the engine already ended it
        if (reroutePending) {
            reroutePending = false;
            if (reroutePolicy == 'A') { e("ROUTE_END"); manIdx = -1; laneIdx = -1; laneExtra = ""; }   // H-A: old route ends (state 0), indices restart
        }                                                                                              // H-B: nothing ends, indices continue
        manIdx++;
        e("ROUTE_BEGIN");
        StringBuilder mm = new StringBuilder("MAN|idx=" + manIdx + "|type=" + rgiType(s) + "|side=" + sideOf(s.man));
        String desc = !s.cue.isEmpty() ? s.cue : s.road;
        if (!desc.isEmpty()) mm.append("|desc=").append(ev(desc));
        if (s.man != 1 && !s.road.isEmpty()) mm.append("|after=").append(ev(s.road));   // for a depart step "road" is instruction text
        if (junctionType(s) >= 0) mm.append("|jtype=").append(junctionType(s));
        if (exitAngle(s) != 9999) mm.append("|exit=").append(exitAngle(s));
        laneExtra = "";
        String le = s.lanes.isEmpty() ? null : lanesEngine(s, nextLaneIdx());
        if (le != null) { laneIdx = nextLaneIdx(); mm.append("|lane=").append(laneIdx); laneExtra = "|lanecur=" + laneIdx + "|laneshow=1|lanetot=" + (laneIdx + 1); }
        else laneExtra = "|laneshow=0|lanetot=" + (laneIdx + 1);   // R6: always say explicitly that no lanes are showing
        e(mm.toString()); if (le != null) e(le);
        routeOpen = true; lastTrip = "";
        tripEvents(true, freshPos);
    }
    void tripEvents(boolean full) { tripEvents(full, true); }
    void tripEvents(boolean full, boolean stepValid) {
        StringBuilder t = new StringBuilder("TRIP");
        if (full) { t.append("|state=active|cur=" + manIdx + "|mcount=" + (manIdx + 1) + "|visible=1" + (optSourceName.isEmpty() ? "" : "|src=" + ev(optSourceName)) + laneExtra); if (!dest.isEmpty()) t.append("|dest=").append(ev(dest)); }
        Pos p = lastPos;
        if (p != null) {
            boolean last = optDestination.equals("last") && p.destCount > 1;
            Dist pd = last ? p.destLast : p.dest; boolean pHasS = last ? p.hasDestSLast : p.hasDestS; long pS = last ? p.destSLast : p.destS;
            if (p.hasRoad && !p.curRoad.isEmpty()) { t.append("|road=").append(ev(p.curRoad)); roadSent = true; }       // X8
            else if (roadSent) { t.append("|road="); roadSent = false; }                                                // withdrawn, not left stale
            if (stepValid && p.step != null && p.step.hasM) { t.append("|dnext=").append(Math.min(p.step.m, Integer.MAX_VALUE)); if (!p.step.shown.isEmpty()) t.append("|dnstr=").append(ev(p.step.shown)); t.append("|dnunits=").append(engUnit(p.step)); }
            if (pd != null && pd.hasM) { t.append("|drem=").append(Math.min(pd.m, Integer.MAX_VALUE)); if (!pd.shown.isEmpty()) t.append("|drstr=").append(ev(pd.shown)); t.append("|drunits=").append(engUnit(pd)); }
            if (pHasS && pS >= 0) t.append("|trem=").append(pS);
            if (pHasS && pS >= 0 && wallMs >= CLOCK_FLOOR_MS) t.append("|eta=").append((wallMs / 1000 + pS + 30) / 60 * 60);   // B9: arrival = valid clock + remaining time, to the whole minute
                                                                                             // (an arrival clock shows minutes; unrounded it would change every second while standing still)
        }
        String s = t.toString();
        if (s.equals("TRIP") || (!full && s.equals(lastTrip))) return;
        lastTrip = full ? "" : s; e(s); e("COMMIT");
    }

    /** one decrypted navigation-channel message; never throws on bad input */
    void feed(int type, byte[] body) {
        try {
            if (type == 0x8003) {
                int v = parseStatus(body);
                if (v < 0) { reject(type, v == -2 ? "malformed" : "no status field"); return; }
                accepted++;
                if (v == status) return;
                status = v; n("STATUS " + statusName(v) + " raw=" + v);
                if (v == 3) { if (routeOpen) { e("STATE|rerouting"); reroutePending = true; } }
                else if (v == 1) {
                    if (routeOpen && reroutePending) { if (cur != null && !pendingMan) { pendingMan = true; pendingFresh = true; } }   // republish as a new route
                    else if (routeOpen) e("STATE|active");
                }
                else if (v == 2 || (v == 0 && optState0.equals("inactive"))) { if (routeOpen) { e("STATE|inactive"); endPending = true; } routeOpen = false; curKey = null; cur = null; lanesKey = ""; lastPos = null; lastTrip = ""; pendingMan = false; pendingFresh = false; reroutePending = false; manIdx = -1; laneIdx = -1; laneExtra = ""; }
            } else if (type == 0x8006) {
                State st = parseState(body);
                if (st == null) { reject(type, "malformed"); return; }
                if (st.steps.isEmpty()) { reject(type, "no step"); return; }
                accepted++;
                if (st.steps.size() > 1) n("NOTE steps=" + st.steps.size() + " (only the first is the current maneuver; the rest are kept in this line: " + st.steps.size() + ")");
                Step s = st.steps.get(0);
                // still waiting (no position came): send without a distance — unless it is a republish of the same step (its last
                // position is still valid), and not at all when the republish is overtaken by a different step (that one is sent instead)
                if (!(pendingFresh && !s.key().equals(curKey))) flushManeuver(pendingFresh);
                String d = st.dest.isEmpty() ? "" : optDestination.equals("last") ? st.dest.get(st.dest.size() - 1) : st.dest.get(0);
                if (!d.equals(dest)) { dest = d; n("DESTINATION " + q(d) + " count=" + st.dest.size()); if (routeOpen && s.key().equals(curKey)) { e("TRIP|dest=" + ev(d)); e("COMMIT"); } }
                if (!s.key().equals(curKey)) {
                    curKey = s.key(); cur = s; seq++; lanesKey = "";
                    n("MANEUVER seq=" + seq + " kind=" + kind(s) + " raw=" + s.man + (s.hasExitNo ? " exit_number=" + s.exitNo : "") + (s.hasExitAngle ? " exit_angle_raw=" + s.exitAngle : "")
                        + " road=" + q(s.road) + " cue=" + q(s.cue) + " arrival=" + (s.man == 39 ? 1 : 0));
                    pendingMan = true; pendingFresh = false;   // sent with the position that follows, so the distance is this maneuver's own
                }
                String lk = lanesText(s);
                if (!lk.equals(lanesKey)) {
                    lanesKey = lk;
                    if (s.lanes.isEmpty()) { n("LANES seq=" + seq + " none"); if (!pendingMan) { laneExtra = "|laneshow=0|lanetot=" + (laneIdx + 1); e("TRIP|lanecur=none" + laneExtra); e("COMMIT"); } }
                    else {
                        n("LANES seq=" + seq + " count=" + s.lanes.size() + " " + lk);
                        String le = lanesEngine(s, nextLaneIdx());
                        if (le == null) n("NOTE lanes not forwarded: shape outside the observed vocabulary");
                        else if (!pendingMan) {      // R6: lanes arriving later: publish the lane object under a new lane index and
                            laneIdx = nextLaneIdx(); // select it in the route update; the maneuver object is not sent again
                            laneExtra = "|lanecur=" + laneIdx + "|laneshow=1|lanetot=" + (laneIdx + 1);
                            e(le); e("TRIP" + laneExtra); e("COMMIT");
                        }
                    }
                }
            } else if (type == 0x8007) {
                Pos p = parsePos(body);
                if (p == null) { reject(type, "malformed"); return; }
                accepted++; lastPos = p;
                StringBuilder sb = new StringBuilder("POSITION seq=" + seq);
                if (p.step != null) sb.append(p.step.hasM ? " step_m=" + p.step.m : "").append(" step_text=").append(q(p.step.shown)).append(" step_unit=").append(unitName(p.step));
                if (p.hasStepS) sb.append(" step_s=").append(p.stepS);
                if (p.dest != null) sb.append(p.dest.hasM ? " dest_m=" + p.dest.m : "").append(" dest_text=").append(q(p.dest.shown)).append(" dest_unit=").append(unitName(p.dest));
                if (p.hasDestS) sb.append(" dest_s=").append(p.destS);
                if (!p.eta.isEmpty()) sb.append(" eta_text=").append(q(p.eta));
                if (p.destCount > 1) { sb.append(" dest_count=").append(p.destCount); if (p.destLast != null) sb.append(p.destLast.hasM ? " dest2_m=" + p.destLast.m : "").append(" dest2_text=").append(q(p.destLast.shown)).append(" dest2_unit=").append(unitName(p.destLast)); if (p.hasDestSLast) sb.append(" dest2_s=").append(p.destSLast); }
                if (p.hasRoad) sb.append(" current_road=").append(q(p.curRoad));
                n(sb.toString());
                if (pendingMan) flushManeuver(true); else if (routeOpen) tripEvents(false);
            } else { accepted++; n("OTHER type=" + String.format("%04x", type) + " len=" + body.length); }
        } catch (RuntimeException ex) { reject(type, "internal " + ex.getClass().getSimpleName()); }
    }

    static byte[] unhex(String h) {
        if ((h.length() & 1) != 0) return null;
        byte[] b = new byte[h.length() / 2];
        for (int i = 0; i < b.length; i++) { int hi = Character.digit(h.charAt(2 * i), 16), lo = Character.digit(h.charAt(2 * i + 1), 16); if (hi < 0 || lo < 0) return null; b[i] = (byte) (hi * 16 + lo); }
        return b;
    }
    public static void main(String[] a) throws IOException {
        String mode = a.length > 1 ? a[1] : "--both";
        for (String x : a) if (x.startsWith("--policy=") && x.length() == 10) reroutePolicy = x.charAt(9);
        for (String x : a) { if (x.startsWith("--source-name=")) optSourceName = x.substring(14); else if (x.startsWith("--destination=")) optDestination = x.substring(14); else if (x.startsWith("--driving-side=")) optDrivingSide = x.substring(15); else arg05(x); }
        if (check05() != null) { System.err.println(check05()); System.exit(2); }
        if (!optDestination.equals("first") && !optDestination.equals("last")) { System.err.println("--destination=first|last"); System.exit(2); }
        if (!optDrivingSide.equals("source") && !optDrivingSide.equals("legacy")) { System.err.println("--driving-side=source|legacy"); System.exit(2); }
        for (String x : a) if (x.startsWith("--lane-unknown=")) optLaneUnknown = x.substring(15);
        if (!optLaneUnknown.equals("keep") && !optLaneUnknown.equals("drop")) { System.err.println("--lane-unknown=keep|drop"); System.exit(2); }
        for (String x : a) if (x.startsWith("--lane-index=")) optLaneIndex = x.substring(13);
        if (!optLaneIndex.equals("independent") && !optLaneIndex.equals("aligned")) { System.err.println("--lane-index=independent|aligned"); System.exit(2); }
        for (String x : a) if (x.startsWith("--position=")) optPosition = x.substring(11);
        if (!optPosition.equals("extended") && !optPosition.equals("legacy")) { System.err.println("--position=extended|legacy"); System.exit(2); }
        for (String x : a) if (x.startsWith("--state0=")) optState0 = x.substring(9);
        if (!optState0.equals("inactive") && !optState0.equals("ignore")) { System.err.println("--state0=inactive|ignore"); System.exit(2); }
        for (String x : a) if (x.startsWith("--units=")) optUnits = x.substring(8);
        if (!optUnits.equals("source") && !optUnits.equals("legacy")) { System.err.println("--units=source|legacy"); System.exit(2); }
        if (!mode.equals("--norm") && reroutePolicy != 'A' && reroutePolicy != 'B') { System.err.println("stage 2 needs --policy=A or --policy=B (no default)"); System.exit(2); }
        OttoAaConv c = new OttoAaConv(!mode.equals("--engine"), !mode.equals("--norm"));
        PrintStream o = new PrintStream(new FileOutputStream(FileDescriptor.out), false, "UTF-8");
        try (BufferedReader r = new BufferedReader(new InputStreamReader(new FileInputStream(a[0]), StandardCharsets.UTF_8))) {
            String line;
            while ((line = r.readLine()) != null) {
                if (line.startsWith("#")) { o.println(line); continue; }
                if (!line.startsWith("NAV ")) continue;
                String[] f = line.split(" ", -1);
                int type; byte[] body = f.length >= 4 ? unhex(f[3]) : f.length == 3 ? new byte[0] : null;
                try { type = Integer.parseInt(f[2], 16); } catch (RuntimeException ex) { c.reject(0, "bad line"); type = -1; }
                if (type >= 0) { if (body == null) c.reject(type, "bad hex"); else { long ms = -1; try { ms = Long.parseLong(f[1]); } catch (RuntimeException ex) { }
                    c.wallMs = clockBaseMs >= CLOCK_FLOOR_MS && ms >= 0 ? clockBaseMs + ms : -1; c.feed(type, body); } }
                for (String s : c.out) o.println(s);
                c.out.clear();
            }
        }
        o.println("# SUMMARY accepted=" + c.accepted + " rejected=" + c.rejected + " maneuvers=" + c.seq);
        o.flush();
    }
}
