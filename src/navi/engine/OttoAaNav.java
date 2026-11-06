/*
 * OttoAaNav — minimal headless Android Auto head-unit-side client for OTTO (navigation data only).
 *
 * Connects to Android Auto's head unit server on 127.0.0.1:5277, announces protocol 1.7 and the
 * smallest service set Android Auto accepts (sensor, video, input, system audio, microphone,
 * navigation status), keeps video focus native so no video is streamed, grants navigation focus,
 * and prints every navigation-channel message as one line:
 *     NAV <ms> <type hex> <payload hex>            raw
 *     ... followed by a decoded line for 0x8003 / 0x8006 / 0x8007
 * It never touches USB, Bluetooth, Wi-Fi settings or the CarPlay stack.
 *
 * run:  CLASSPATH=/path/otto_aanav.jar app_process / OttoAaNav [host] [seconds, 0 = until closed] [route file]
 *       CLASSPATH=/path/otto_aanav.jar app_process / OttoAaNav replay <capture file>   (same code path, no network)
 * Every navigation message is also passed in-process to OttoAaConv; its normalized lines ("N ...") and
 * otto_rgid event lines ("E ...") are printed after the raw and decoded lines.
 * With a route file the client also announces a LOCATION sensor and feeds one position per second.
 */
import java.io.*;
import java.net.*;
import java.nio.ByteBuffer;
import java.security.*;
import java.security.cert.*;
import java.security.spec.PKCS8EncodedKeySpec;
import java.util.*;
import javax.net.ssl.*;

public final class OttoAaNav {
    static final int SEN = 1, VID = 2, INP = 3, AUD = 5, MIC = 7, NAV = 10;
    // service discovery response: byte-identical to the set proven with the probe (2026-10-10)
    static final String SDR = "0a100801120c0a02080d0a02080a0a0208010a1508021a110803220b080110011800200028a00128010a0c08032208120608a00610e0030a1308051a0f080110021a0708807d1010180128010a0f08072a0b0801120708807d101018010a09080a420508f4031002120a566f6c6b73776167656e1a0849442e2042757a7a2204323032362a0f4f54544f2d494442555a5a2d30303130003a044f54544f42044f54544f4a0131520131580072044f54544f";
    // head-unit certificate and key published with the open-source head unit implementations
    static final String CERT = "MIIDJTCCAg0CAnZTMA0GCSqGSIb3DQEBCwUAMFsxCzAJBgNVBAYTAlVTMRMwEQYDVQQIDApDYWxpZm9ybmlhMRYwFAYDVQQHDA1Nb3VudGFpbiBWaWV3MR8wHQYDVQQKDBZHb29nbGUgQXV0b21vdGl2ZSBMaW5rMB4XDTE0MDcwODIyNDkxOFoXDTQ0MDcwNzIyNDkxOFowVTELMAkGA1UEBhMCVVMxCzAJBgNVBAgMAkNBMRYwFAYDVQQHDA1Nb3VudGFpbiBWaWV3MSEwHwYDVQQKDBhHb29nbGUtQW5kcm9pZC1SZWZlcmVuY2UwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQCpqQmvoDW/XsREoj20dRcMqJGWh8RlUoHB8CpBpsoqV4nAuvNngkyrdpCf1yg0fVAp2Ugj5eOtzbiN6BxoNHpPgiZ64pc+JRlwjmyHpssDaHzP+zHZM7acwMcroNVyynSzpiydEDyx/KPtEz5AsKi7c7AYYEtnCmAnK/waN1RT5KdZ9f97D9NeF7Ljdk+IKFROJh7Nv/YGiv9GdPZh/ezSm2qhD3gzdh9PYs2cu0u+N17PYpSYB7vXPcYa/gmIVipIJ5RuMQVBWrCgtfzwKPqbnJQVykm8LnysK+8RCgmPLN3uhsZx6Whax2TVXb1q68DoiaFPhvMfPr2i/9IKaC69AgMBAAEwDQYJKoZIhvcNAQELBQADggEBAIpfjQriEtbpUyWLoOOfJsjFN04+ajq91XALCPd+2ixWHZIBJiucrrf0H7OgY7eFnNbU0cRqiDZHI8BtvzFxNi/JgXqCmSHRrlaoIsITfqo8KHwcAMs4qWTeLQmkTXBZYz0M3HwC7N1vOGjAJJN5qENIm1Jq+/3cfxVg2zhHPKY8qtdgl73YIXb9Xx3WmPCBeRBCKJncj0Rq14uaOjWXRyBgbmdzMXJzFGPHx3wN04JqGyfPFlDazXExFQwuAryjoYBRdxPxGufeQCp3am4xxI2oxNIzR+4LnOcDhgU1B7sbkVzbKj5gjdOQAmxnKCfBtUNB63a7yzGPYGPIwlBsm54=";
    static final String KEY = "MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQCpqQmvoDW/XsREoj20dRcMqJGWh8RlUoHB8CpBpsoqV4nAuvNngkyrdpCf1yg0fVAp2Ugj5eOtzbiN6BxoNHpPgiZ64pc+JRlwjmyHpssDaHzP+zHZM7acwMcroNVyynSzpiydEDyx/KPtEz5AsKi7c7AYYEtnCmAnK/waN1RT5KdZ9f97D9NeF7Ljdk+IKFROJh7Nv/YGiv9GdPZh/ezSm2qhD3gzdh9PYs2cu0u+N17PYpSYB7vXPcYa/gmIVipIJ5RuMQVBWrCgtfzwKPqbnJQVykm8LnysK+8RCgmPLN3uhsZx6Whax2TVXb1q68DoiaFPhvMfPr2i/9IKaC69AgMBAAECggEAbBoW3963IG6jpA+0PW11+EzYJw/u5ZiCsS3z3s0Fd6E7VqBIQyXU8FOlpxMSvQ8zqtaVjroGLlIsS88feo4leM+28Qm70I8W/I7jPDPcmxlSnbqycnDu5EY5IeVi27eAUI+LUbBs3APb900Rl2p4uKfoBkAlC0yjI5J1GcczZhf7RDh1wGgFWZI+ljiSrfpdiA4XmcZ9c7FlO5+NTotZzYeNx1iZprajV1/dlDy8UWEkwoWtppeGzUf3HHgl8yay62ub2vo5I1Z7Z98Roq8KC1o7k2IXOrHztCl3X03gMwlIF4WQ6Fx5LZDU9dfaPhzkutekVgbtO9SzHgb3NXCZwQKBgQDcSS/OLll18ssjBwc7PsdaIFIPlF428Tk8qezEnDmHS6xeztkGnpOlilk9jYSsVUbQmq8MwBSjfMVH95B0w0yyfOYqjgTocg4lRCoPuBdnuBY/lU1Lws4FoGsGMNFkHWjHzl622mavkJiDzWA+CORPUllS/DnPKJnZk2n0zZRKaQKBgQDFKqvePMx/a/ayQ09UZYxov0vwRyNkHevmwEGQjOiHKozWvLqWhCvFtwo+VqHqmCw95cYUpg1GvppB6Lnw2uHgWAWxr3ugDjaRYSqG/L7FG6FDF+1sPvBuxNpBmto59TI1fBFmU9VBGLDnr1M27qH3KTWlA3lCsovV6Dbk7D+vNQKBgE6GgFYdS6KyFBu+a6OA84t7LgWDvDoVr3Oil1ZW4mMKZL2/OroTWUqPkNRSWFMeawn9uhzvc+v7lE/dPk+BNxwBTgMpcTJzRfue2ueTljRQ+Q1daZpyLQLwdnZUfLAVk752IGlKXYSEJPoHAiHbBZgJIPJmGy1vqbhXxlOP3SbRAoGBAJoAQ2/5gy0/sdf5FRxxmOM0D+dkWTNY36pDnrJ+LR1uUcVkckUghWQQHRMl7aBkLaJHN5lnPdV1CN3UHnAPNwBZIFFyJJiWoW6aO3JmNceVVjcmmE7FNlz+qw81GaDNcOMvvhN0BYyr8Xl1iwTMDXwVFw6FkRBUjz6L+1yBXxjFAoGAJZcU+tEM1+gHPCqHK2bPkfYOCyEAro4zY/VWXZKHgCoPau8Uc9+vFu2QVMb5kVyLTdyRLQKpooR6f8En6utS/G15YuqRYqzSTrMBzpRrqIwbgKI9RHNPAvhtVAmXnwsYDPIQ1rrELK6WzTjUySRd7gyCoq+DlY7ZKDa7FUz05Ek=";

    static InputStream in; static OutputStream out; static SSLEngine tls;
    // ---- OFFLINE INTEGRATION (isolated copy, 2026-10-11) ----
    // OFFLINE_BUILD = true: the network block of main() is a compile-time-dead branch (javac emits no code for it), so this
    // build contains no java.net use at all. A device build would set it to false; that build is NOT part of this work.
    // P3: three build classes, selected by the build script through this one constant (javac drops the unreachable branches):
    //   0 OFFLINE  no network code at all            1 TEST  plaintext frames from a loopback TEST port (never 5277), no TLS
    //   2 DEVICE   Android Auto's head unit server on 127.0.0.1:5277 with TLS
    static final int BUILD = 0;
    static final boolean OFFLINE_BUILD = BUILD == 0;
    // "replayframes" mode: recorded / synthetic PLAINTEXT Android Auto frames from a file go through the same frame reader,
    // fragment reassembly and channel dispatch as live traffic; everything the client would send is discarded.
    static boolean offlineFrames;
    static final long t0 = System.currentTimeMillis();
    static ByteBuffer netIn = ByteBuffer.allocate(1 << 17), appIn = ByteBuffer.allocate(1 << 17);

    // P3: --events-only = stdout carries nothing but engine event lines (UTF-8, no prefix), so it can be piped straight into the
    // engine without any shell filter. Everything else goes to stderr: INFO lines always, raw / decoded / normalized lines with --log=full.
    static boolean eventsOnly, logFull = true, etaClock;
    static PrintStream evOut, logOut;
    static void initOut() throws IOException {
        if (!eventsOnly) return;
        evOut = new PrintStream(new FileOutputStream(FileDescriptor.out), false, "UTF-8"); logOut = new PrintStream(new FileOutputStream(FileDescriptor.err), false, "UTF-8");
    }
    static void say(String s) {
        if (!eventsOnly) { System.out.println(s); System.out.flush(); return; }
        if (logFull || s.startsWith("INFO") || s.startsWith("#")) { logOut.println(s); logOut.flush(); }
    }
    static void event(String l) {
        if (!eventsOnly) { say("E " + l); return; }
        evOut.print(l); evOut.print('\n');
    }
    static void eventsDone() {
        if (!eventsOnly) return;
        evOut.flush();
        if (evOut.checkError()) { logOut.println("INFO the engine is gone (event pipe closed); ending"); logOut.flush(); System.exit(4); }
    }
    static byte[] unhex(String h) { byte[] b = new byte[h.length() / 2]; for (int i = 0; i < b.length; i++) b[i] = (byte) Integer.parseInt(h.substring(2 * i, 2 * i + 2), 16); return b; }
    static String hex(byte[] b, int off, int len) { StringBuilder sb = new StringBuilder(); for (int i = off; i < off + len; i++) sb.append(String.format("%02x", b[i])); return sb.toString(); }

    // ---- protobuf helpers ----
    static byte[] varint(long v) { ByteArrayOutputStream o = new ByteArrayOutputStream(); while (true) { int b = (int) (v & 0x7f); v >>>= 7; if (v != 0) o.write(b | 0x80); else { o.write(b); break; } } return o.toByteArray(); }
    static byte[] fVar(int no, long v) { byte[] k = varint((long) no << 3), x = varint(v), r = new byte[k.length + x.length]; System.arraycopy(k, 0, r, 0, k.length); System.arraycopy(x, 0, r, k.length, x.length); return r; }
    static final class Rd {
        final byte[] b; int p; final int end;
        Rd(byte[] b, int off, int len) { this.b = b; p = off; end = off + len; }
        boolean more() { return p < end; }
        long var() { long v = 0; int sh = 0; while (true) { int c = b[p++] & 0xff; v |= (long) (c & 0x7f) << sh; sh += 7; if ((c & 0x80) == 0) return v; } }
        int no, wt; long num; int off, len;
        boolean next() {                       // false on end or malformed input
            if (p >= end) return false;
            try {
                long k = var(); no = (int) (k >>> 3); wt = (int) (k & 7);
                if (wt == 0) num = var();
                else if (wt == 2) { len = (int) var(); off = p; if (len < 0 || off + len > end) return false; p += len; }
                else if (wt == 1) { off = p; len = 8; p += 8; } else if (wt == 5) { off = p; len = 4; p += 4; } else return false;
                return p <= end;
            } catch (ArrayIndexOutOfBoundsException e) { return false; }
        }
        Rd sub() { return new Rd(b, off, len); }
        String str() { return new String(b, off, len, java.nio.charset.StandardCharsets.UTF_8); }
    }

    // ---- framing ----
    static void readFully(byte[] b, int n) throws IOException { int g = 0; while (g < n) { int r = in.read(b, g, n - g); if (r < 0) throw new EOFException("Android Auto closed the connection"); g += r; } }
    static void sendPlain(int ch, int type, byte[] body) throws IOException {
        byte[] f = new byte[6 + body.length]; int n = body.length + 2;
        f[0] = (byte) ch; f[1] = 3; f[2] = (byte) (n >> 8); f[3] = (byte) n; f[4] = (byte) (type >> 8); f[5] = (byte) type;
        System.arraycopy(body, 0, f, 6, body.length); out.write(f); out.flush();
    }
    static synchronized void send(int ch, int type, byte[] body, int flags) throws IOException {
        if (offlineFrames) return;                                       // nothing leaves the process in the offline frame mode
        ByteBuffer src = ByteBuffer.allocate(body.length + 2); src.put((byte) (type >> 8)).put((byte) type).put(body).flip();
        ByteBuffer dst = ByteBuffer.allocate(tls.getSession().getPacketBufferSize() + body.length + 64);
        tls.wrap(src, dst); dst.flip();
        int n = dst.remaining(); byte[] f = new byte[4 + n];
        f[0] = (byte) ch; f[1] = (byte) flags; f[2] = (byte) (n >> 8); f[3] = (byte) n; dst.get(f, 4, n);
        out.write(f); out.flush();
    }
    static void send(int ch, int type, byte[] body) throws IOException { send(ch, type, body, 0x0b); }

    static void handshake() throws Exception {
        sendPlain(0, 1, new byte[] { 0, 1, 0, 7 });                              // version request 1.7
        byte[] h = new byte[4]; readFully(h, 4); int n = ((h[2] & 0xff) << 8) | (h[3] & 0xff); byte[] p = new byte[n]; readFully(p, n);
        say("INFO version response " + hex(p, 0, n));
        KeyFactory kf = KeyFactory.getInstance("RSA");
        PrivateKey key = kf.generatePrivate(new PKCS8EncodedKeySpec(Base64.getDecoder().decode(KEY)));
        java.security.cert.Certificate cert = CertificateFactory.getInstance("X.509").generateCertificate(new ByteArrayInputStream(Base64.getDecoder().decode(CERT)));
        KeyStore ks = KeyStore.getInstance(KeyStore.getDefaultType()); ks.load(null, null);
        ks.setKeyEntry("hu", key, new char[0], new java.security.cert.Certificate[] { cert });
        KeyManagerFactory kmf = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm()); kmf.init(ks, new char[0]);
        TrustManager[] tm = { new X509TrustManager() {
            public void checkClientTrusted(X509Certificate[] c, String a) { } public void checkServerTrusted(X509Certificate[] c, String a) { }
            public X509Certificate[] getAcceptedIssuers() { return new X509Certificate[0]; } } };
        SSLContext ctx = SSLContext.getInstance("TLSv1.2"); ctx.init(kmf.getKeyManagers(), tm, null);
        tls = ctx.createSSLEngine(); tls.setUseClientMode(true); tls.beginHandshake();
        ByteBuffer empty = ByteBuffer.allocate(0), net = ByteBuffer.allocate(1 << 16), app = ByteBuffer.allocate(1 << 16);
        ByteBuffer inbuf = ByteBuffer.allocate(1 << 16); inbuf.flip();
        while (true) {
            SSLEngineResult.HandshakeStatus hs = tls.getHandshakeStatus();
            if (hs == SSLEngineResult.HandshakeStatus.NEED_WRAP) {
                net.clear(); tls.wrap(empty, net); net.flip();
                if (net.hasRemaining()) { byte[] d = new byte[net.remaining()]; net.get(d); sendPlain(0, 3, d); }
            } else if (hs == SSLEngineResult.HandshakeStatus.NEED_UNWRAP) {
                app.clear(); SSLEngineResult r = tls.unwrap(inbuf, app);
                if (r.getStatus() == SSLEngineResult.Status.BUFFER_UNDERFLOW) {
                    readFully(h, 4); n = ((h[2] & 0xff) << 8) | (h[3] & 0xff); p = new byte[n]; readFully(p, n);
                    if (n < 2 || p[1] != 3) continue;
                    inbuf.compact(); inbuf.put(p, 2, n - 2); inbuf.flip();
                }
            } else if (hs == SSLEngineResult.HandshakeStatus.NEED_TASK) { Runnable t; while ((t = tls.getDelegatedTask()) != null) t.run(); }
            else break;
        }
        say("INFO TLS " + tls.getSession().getProtocol() + " " + tls.getSession().getCipherSuite());
        sendPlain(0, 4, fVar(1, 0));                                            // auth complete
        netIn.clear(); netIn.put(inbuf); netIn.flip();
    }
    static byte[] decrypt(byte[] p, int n) throws SSLException {
        netIn.compact(); netIn.put(p, 0, n); netIn.flip();
        ByteArrayOutputStream o = new ByteArrayOutputStream();
        while (netIn.hasRemaining()) {
            appIn.clear(); SSLEngineResult r = tls.unwrap(netIn, appIn); appIn.flip();
            byte[] d = new byte[appIn.remaining()]; appIn.get(d); o.write(d, 0, d.length);
            if (r.getStatus() != SSLEngineResult.Status.OK) break;
        }
        return o.toByteArray();
    }

    // ---- navigation decoding (names from the public protocol description) ----
    /** X18: text printed in LOG lines must not be able to start a new line (a line beginning with "E " is an engine event). */
    static String clean(String s) { StringBuilder b = new StringBuilder(s.length()); for (int i = 0; i < s.length(); i++) { char c = s.charAt(i); b.append(c < 0x20 || c == 0x7f ? ' ' : c); } return b.toString(); }
    static String road(Rd r) { String s = ""; while (r.next()) if (r.no == 1 && r.wt == 2) s = r.str(); return clean(s); }
    static String dist(Rd r) { String s = ""; while (r.next()) { if (r.no == 1) s += " meters=" + r.num; else if (r.no == 2) s += " shown=\"" + clean(r.str()) + "\""; else if (r.no == 3) s += " unit=" + r.num; } return s; }
    static void decode(int type, byte[] b) {
        StringBuilder sb = new StringBuilder();
        Rd m = new Rd(b, 0, b.length);
        if (type == 0x8003) { while (m.next()) if (m.no == 1) sb.append("STATUS ").append(m.num); }
        else if (type == 0x8006) {
            int si = 0;
            while (m.next()) {
                if (m.no == 1 && m.wt == 2) {
                    sb.append("\n  STEP ").append(si++); Rd s = m.sub(); int li = 0;
                    while (s.next()) {
                        if (s.no == 1 && s.wt == 2) { Rd x = s.sub(); while (x.next()) { if (x.no == 1) sb.append(" maneuver=").append(x.num); else if (x.no == 2) sb.append(" exit_number=").append(x.num); else if (x.no == 3) sb.append(" exit_angle=").append((int) x.num); } }
                        else if (s.no == 2 && s.wt == 2) sb.append(" road=\"").append(road(s.sub())).append("\"");
                        else if (s.no == 3 && s.wt == 2) { sb.append(" lane").append(li++).append("=["); Rd l = s.sub(); while (l.next()) if (l.no == 1 && l.wt == 2) { Rd d = l.sub(); long shape = 0, rec = 0; while (d.next()) { if (d.no == 1) shape = d.num; else if (d.no == 2) rec = d.num; } sb.append(shape).append(rec != 0 ? "*" : "").append(" "); } sb.append("]"); }
                        else if (s.no == 4 && s.wt == 2) sb.append(" cue=\"").append(road(s.sub())).append("\"");
                    }
                } else if (m.no == 2 && m.wt == 2) sb.append("\n  DESTINATION \"").append(road(m.sub())).append("\"");
            }
            sb.insert(0, "STATE steps=" + si);
        } else if (type == 0x8007) {
            sb.append("POSITION");
            while (m.next()) {
                if (m.no == 1 && m.wt == 2) { Rd s = m.sub(); while (s.next()) { if (s.no == 1 && s.wt == 2) sb.append(" step:").append(dist(s.sub())); else if (s.no == 2) sb.append(" step_seconds=").append(s.num); } }
                else if (m.no == 2 && m.wt == 2) { Rd s = m.sub(); while (s.next()) { if (s.no == 1 && s.wt == 2) sb.append(" dest:").append(dist(s.sub())); else if (s.no == 2 && s.wt == 2) sb.append(" eta=\"").append(clean(s.str())).append("\""); else if (s.no == 3) sb.append(" dest_seconds=").append(s.num); } }
                else if (m.no == 3 && m.wt == 2) sb.append(" current_road=\"").append(road(m.sub())).append("\"");
            }
        } else sb.append("OTHER");
        say("  " + sb);
    }

    // ---- optional location feed: file with one line per second "lat_e7 lon_e7 speed_mm_s bearing_e6" ----
    static String routeFile; static long feedIntervalMs = 1000; static volatile boolean feeding;
    static byte[] cat(byte[]... p) { ByteArrayOutputStream o = new ByteArrayOutputStream(); for (byte[] x : p) o.write(x, 0, x.length); return o.toByteArray(); }
    static byte[] fLen(int no, byte[] b) { return cat(varint(((long) no << 3) | 2), varint(b.length), b); }
    static void startFeed() {
        if (routeFile == null || feeding) return; feeding = true;
        Thread t = new Thread(() -> {
            try (BufferedReader r = new BufferedReader(new FileReader(routeFile))) {
                String line; int i = 0; long next = System.currentTimeMillis();
                while ((line = r.readLine()) != null) {
                    String[] f = line.trim().split(" "); if (f.length < 4) continue;
                    long lat = Long.parseLong(f[0]), lon = Long.parseLong(f[1]), spd = Long.parseLong(f[2]), brg = Long.parseLong(f[3]);
                    byte[] loc = cat(fVar(1, System.currentTimeMillis()), fVar(2, lat), fVar(3, lon), fVar(4, 3000), fVar(5, 5000), fVar(6, spd), fVar(7, brg));
                    send(SEN, 0x8003, fLen(1, loc));
                    if (i % 5 == 0) say("LOC " + (System.currentTimeMillis() - t0) + " i=" + i + " lat=" + lat + " lon=" + lon + " speed_mm_s=" + spd + " bearing_e6=" + brg);
                    i++; next += feedIntervalMs; long w = next - System.currentTimeMillis(); if (w > 0) Thread.sleep(w);
                }
                say("INFO location feed finished after " + i + " positions");
            } catch (Exception e) { say("INFO location feed stopped: " + e); }
        });
        t.setDaemon(true); t.start();
    }

    // ---- one navigation message: raw line, decoded line(s), then the converter in-process ----
    static final OttoAaConv conv = new OttoAaConv(true, true);
    static void onNav(long ms, int type, byte[] body) {
        say("NAV " + ms + " " + String.format("%04x", type) + " " + hex(body, 0, body.length));       // raw bytes are always kept
        try { decode(type, body); } catch (RuntimeException e) { say("  DECODE_FAILED"); }
        // B9: arrival time needs a valid wall clock. Replay: only with --clock-base. Live: the device clock, and only when it is plausibly set.
        // P3: on a device the arrival time is sent only when the service says the clock can be trusted (--eta=clock; it checks that
        // the system keeps network time). Without that switch no arrival time is ever sent.
        conv.wallMs = BUILD != 2 ? (OttoAaConv.clockBaseMs >= OttoAaConv.CLOCK_FLOOR_MS ? OttoAaConv.clockBaseMs + ms : -1)
                                 : (etaClock && System.currentTimeMillis() >= OttoAaConv.CLOCK_FLOOR_MS ? System.currentTimeMillis() : -1);
        conv.feed(type, body);                                                                           // works on the bytes, not on log text
        for (String l : conv.out) { if (l.startsWith("N ")) say(l); else event(l); }
        conv.out.clear(); eventsDone();
    }
    /** P3: the source is gone (connection lost, byebye). Same path as Android Auto saying INACTIVE: the route is closed in the
     *  converter and the engine clears it after its own debounce. Nothing is sent if there was no route. */
    static void sourceLost(String why) {
        say("INFO source lost (" + why + "): treated as navigation INACTIVE");
        onNav(System.currentTimeMillis() - t0, 0x8003, new byte[] { 0x08, 0x02 });
    }
    /** offline: push the NAV lines of a capture through exactly the same path as live messages */
    static void replay(String file) throws IOException {
        try (BufferedReader r = new BufferedReader(new InputStreamReader(new FileInputStream(file), java.nio.charset.StandardCharsets.UTF_8))) {
            String line;
            while ((line = r.readLine()) != null) {
                if (!line.startsWith("NAV ")) continue;
                String[] f = line.split(" ", -1);
                int type; byte[] body = f.length >= 4 ? OttoAaConv.unhex(f[3]) : f.length == 3 ? new byte[0] : null;
                try { type = Integer.parseInt(f[2], 16); } catch (RuntimeException ex) { conv.reject(0, "bad line"); type = -1; }
                if (type >= 0) { if (body == null) conv.reject(type, "bad hex"); else { onNav(0, type, body); continue; } }
                for (String l : conv.out) { if (l.startsWith("N ")) say(l); else event(l); }
                conv.out.clear(); eventsDone();
            }
        }
        say("# SUMMARY accepted=" + conv.accepted + " rejected=" + conv.rejected + " maneuvers=" + conv.seq);
    }

    /** converter switches accepted anywhere on the command line; everything else keeps its old position and meaning */
    static String[] options(String[] a0) {
        List<String> pos = new ArrayList<>();
        for (String x : a0) {
            if (x.startsWith("--policy=") && x.length() == 10) OttoAaConv.reroutePolicy = x.charAt(9);
            else if (OttoAaConv.arg05(x)) { }
            else if (x.equals("--events-only")) { eventsOnly = true; logFull = false; }
            else if (x.equals("--eta=clock")) etaClock = true; else if (x.equals("--eta=off")) etaClock = false;
            else if (x.equals("--log=full")) logFull = true; else if (x.equals("--log=quiet")) logFull = false;
            else if (x.startsWith("--connect-retries=")) connectRetries = Integer.parseInt(x.substring(18));
            else if (BUILD == 1 && x.startsWith("--test-port=")) testPort = Integer.parseInt(x.substring(12));
            else if (BUILD == 1 && x.startsWith("--retry-ms=")) retryBaseMs = Long.parseLong(x.substring(11));
            else if (x.startsWith("--source-name=")) OttoAaConv.optSourceName = x.substring(14);
            else if (x.startsWith("--destination=")) OttoAaConv.optDestination = x.substring(14);
            else if (x.startsWith("--driving-side=")) OttoAaConv.optDrivingSide = x.substring(15);
            else if (x.startsWith("--lane-unknown=")) OttoAaConv.optLaneUnknown = x.substring(15);
            else if (x.startsWith("--units=")) OttoAaConv.optUnits = x.substring(8);
            else if (x.startsWith("--state0=")) OttoAaConv.optState0 = x.substring(9);
            else if (x.startsWith("--position=")) OttoAaConv.optPosition = x.substring(11);
            else if (x.startsWith("--lane-index=")) OttoAaConv.optLaneIndex = x.substring(13);
            else if (x.startsWith("--")) { System.err.println("unknown option " + x); System.exit(2); }
            else pos.add(x);
        }
        if (OttoAaConv.reroutePolicy != 'A' && OttoAaConv.reroutePolicy != 'B') { System.err.println("--policy=A or --policy=B is required (no default)"); System.exit(2); }
        if (OttoAaConv.check05() != null) { System.err.println(OttoAaConv.check05()); System.exit(2); }
        if (!OttoAaConv.optDestination.equals("first") && !OttoAaConv.optDestination.equals("last")) { System.err.println("--destination=first|last"); System.exit(2); }
        if (!OttoAaConv.optDrivingSide.equals("source") && !OttoAaConv.optDrivingSide.equals("legacy")) { System.err.println("--driving-side=source|legacy"); System.exit(2); }
        if (!OttoAaConv.optLaneUnknown.equals("keep") && !OttoAaConv.optLaneUnknown.equals("drop")) { System.err.println("--lane-unknown=keep|drop"); System.exit(2); }
        if (!OttoAaConv.optUnits.equals("source") && !OttoAaConv.optUnits.equals("legacy")) { System.err.println("--units=source|legacy"); System.exit(2); }
        if (!OttoAaConv.optState0.equals("inactive") && !OttoAaConv.optState0.equals("ignore")) { System.err.println("--state0=inactive|ignore"); System.exit(2); }
        if (!OttoAaConv.optPosition.equals("extended") && !OttoAaConv.optPosition.equals("legacy")) { System.err.println("--position=extended|legacy"); System.exit(2); }
        if (!OttoAaConv.optLaneIndex.equals("independent") && !OttoAaConv.optLaneIndex.equals("aligned")) { System.err.println("--lane-index=independent|aligned"); System.exit(2); }
        return pos.toArray(new String[0]);
    }
    static int connectRetries = 5, testPort = -1; static long retryBaseMs = 2000; static volatile int sessionNo;
    // P4: a head unit server that accepts the TCP connection but never answers (seen on the device) must not hang the client.
    static final int READ_TIMEOUT_MS = 20000, SILENT_MAX = 3; static volatile boolean sdrSeen; static int silent;
    static long navCount;
    /** one connection's frame loop; returns when the peer closes, says byebye, or the time is over */
    static void readLoop(long end) throws Exception {
        byte[] h = new byte[4], x = new byte[4]; Map<Integer, ByteArrayOutputStream> frag = new HashMap<>();
        try {
            while (System.currentTimeMillis() < end) {
                readFully(h, 4); int ch = h[0] & 0xff, flags = h[1] & 0xff, n = ((h[2] & 0xff) << 8) | (h[3] & 0xff);
                if ((flags & 3) == 1) readFully(x, 4);
                byte[] p = new byte[n]; readFully(p, n);
                if ((flags & 8) != 0 && offlineFrames) { say("INFO encrypted frame skipped (the offline frame mode has no TLS session)"); continue; }
                byte[] d = (flags & 8) != 0 ? decrypt(p, n) : p;
                int fl = flags & 3;
                if (fl != 3) { ByteArrayOutputStream f = frag.get(ch); if (fl == 1 || f == null) { f = new ByteArrayOutputStream(); frag.put(ch, f); } f.write(d, 0, d.length); if (fl != 2) continue; d = f.toByteArray(); frag.remove(ch); }
                if (d.length < 2) continue;
                int type = ((d[0] & 0xff) << 8) | (d[1] & 0xff); byte[] body = Arrays.copyOfRange(d, 2, d.length);
                boolean ctl = ch == 0 || (flags & 4) != 0;
                if (ch == 0 && type == 5) { send(0, 6, unhex(SDR)); sdrSeen = true; say("INFO service discovery answered"); say("SDR " + SDR); }
                else if (ctl && type == 7) { send(ch, 8, fVar(1, 0), 0x0f); say("INFO channel " + ch + " opened"); }
                else if (ch == 0 && type == 0x0b) { Rd r = new Rd(body, 0, body.length); long ts = 0; while (r.next()) if (r.no == 1) ts = r.num; send(0, 0x0c, fVar(1, ts)); }
                else if (ch == 0 && type == 0x0d) { send(0, 0x0e, fVar(1, 2)); say("INFO navigation focus granted"); }
                else if (ch == 0 && type == 0x12) { Rd r = new Rd(body, 0, body.length); long q = 0; while (r.next()) if (r.no == 1) q = r.num; send(0, 0x13, fVar(1, q == 4 ? 3 : 1)); }
                else if (ch == 0 && type == 0x0f) { send(0, 0x10, new byte[0]); say("INFO byebye from Android Auto " + hex(body, 0, body.length)); break; }
                else if (ch == VID && type == 0x8000) { ByteArrayOutputStream c = new ByteArrayOutputStream(); c.write(fVar(1, 2)); c.write(fVar(2, 1)); c.write(fVar(3, 0)); send(ch, 0x8003, c.toByteArray());
                    ByteArrayOutputStream v = new ByteArrayOutputStream(); v.write(fVar(1, 2)); v.write(fVar(2, 1)); send(ch, 0x8008, v.toByteArray()); say("INFO video focus kept native (no video stream)"); }
                else if (ch == AUD && type == 0x8000) { ByteArrayOutputStream c = new ByteArrayOutputStream(); c.write(fVar(1, 2)); c.write(fVar(2, 1)); c.write(fVar(3, 0)); send(ch, 0x8003, c.toByteArray()); }
                else if ((ch == VID || ch == AUD) && (type == 0 || type == 1)) { ByteArrayOutputStream c = new ByteArrayOutputStream(); c.write(fVar(1, 0)); c.write(fVar(2, 1)); send(ch, 0x8004, c.toByteArray()); }
                else if (ch == SEN && type == 0x8001) { Rd r = new Rd(body, 0, body.length); long st = 0; while (r.next()) if (r.no == 1) st = r.num; send(ch, 0x8002, fVar(1, 0));
                    if (st == 1) { say("INFO location sensor requested by Android Auto"); startFeed(); }
                    if (st == 13) send(ch, 0x8003, new byte[] { 0x6a, 0x02, 0x08, 0x00 }); if (st == 10) send(ch, 0x8003, new byte[] { 0x52, 0x02, 0x08, 0x01 }); }
                else if (ch == INP && type == 0x8002) send(ch, 0x8003, fVar(1, 0));
                else if (ch == NAV) { navCount++; onNav(offlineFrames ? 0 : System.currentTimeMillis() - t0, type, body); }
            }
        } catch (EOFException e) { say("INFO " + e.getMessage()); }
    }
    public static void main(String[] a0) throws Exception {
        String[] a = options(a0); initOut();
        if (a.length == 2 && a[0].equals("replay")) { replay(a[1]); return; }
        if (a.length == 2 && a[0].equals("replayframes")) {
            in = new BufferedInputStream(new FileInputStream(a[1]), 1 << 16); out = new OutputStream() { public void write(int b) { } }; offlineFrames = true;
            readLoop(Long.MAX_VALUE);
            say("INFO end, navigation messages=" + navCount);
            say("# SUMMARY accepted=" + conv.accepted + " rejected=" + conv.rejected + " maneuvers=" + conv.seq);
            return;
        }
        if (BUILD == 0) { System.err.println("offline build: only 'replay <capture>' and 'replayframes <frame file>' exist; no network mode is compiled in"); System.exit(3); }
        if (BUILD != 0) {                                                 // compile-time dead in the offline build
            String host = a.length > 0 ? a[0] : "127.0.0.1"; long seconds = a.length > 1 ? Long.parseLong(a[1]) : 0;
            routeFile = a.length > 2 ? a[2] : null;
            if (a.length > 3) { feedIntervalMs = Long.parseLong(a[3]); if (feedIntervalMs < 286 || feedIntervalMs > 1000) throw new IllegalArgumentException("feed interval must be 286..1000 ms (max 3.5x)"); }
            int port = 5277;
            if (BUILD == 1) {                                             // test class: loopback, a test port, plaintext frames, nothing is ever sent
                port = testPort; offlineFrames = true;
                if (!host.equals("127.0.0.1") || port < 1024 || port > 65535 || port == 5277) { System.err.println("test build: only 127.0.0.1 and --test-port=<1024..65535, not 5277>"); System.exit(3); }
            }
            long end = seconds > 0 ? System.currentTimeMillis() + seconds * 1000 : Long.MAX_VALUE, backoff = retryBaseMs; int fails = 0;
            while (System.currentTimeMillis() < end) {
                Socket s = new Socket(); boolean connected = false; final int me = ++sessionNo;
                try {
                    s.connect(new InetSocketAddress(host, port), 5000); s.setTcpNoDelay(true); connected = true; fails = 0; backoff = retryBaseMs;
                    sdrSeen = false; if (BUILD == 2) s.setSoTimeout(READ_TIMEOUT_MS);          // a live session is never silent: our ping every 2 s is answered
                    in = new BufferedInputStream(s.getInputStream(), 1 << 16); out = s.getOutputStream();
                    netIn.clear(); netIn.flip(); appIn.clear(); feeding = false;
                    say("INFO connected to " + host + ":" + port + " (session " + me + ")");
                    if (BUILD == 2) {
                        handshake();
                        Thread ping = new Thread(() -> { try { while (sessionNo == me) { Thread.sleep(2000); if (sessionNo == me) send(0, 0x0b, fVar(1, System.currentTimeMillis())); } } catch (Exception e) { } });
                        ping.setDaemon(true); ping.start();
                    }
                    readLoop(end);
                } catch (IOException | java.security.GeneralSecurityException e) {
                    say("INFO " + (connected ? "session ended: " : "cannot connect: ") + e);
                    if (!connected && ++fails >= connectRetries) { say("INFO giving up after " + fails + " failed connections (is the head unit server running?)"); eventsDone(); System.exit(10); }
                } finally { sessionNo++; try { s.close(); } catch (IOException e) { } }
                if (connected) sourceLost("connection " + me + " ended");
                if (connected && BUILD == 2) { silent = sdrSeen ? 0 : silent + 1;
                    if (silent >= SILENT_MAX) { say("INFO giving up: " + silent + " connections in a row were accepted but never reached service discovery (head unit server stuck?)"); eventsDone(); System.exit(11); } }
                if (System.currentTimeMillis() >= end) break;
                Thread.sleep(backoff); backoff = Math.min(backoff * 2, 30000);
            }
        }
        say("INFO end, navigation messages=" + navCount);
        say("# SUMMARY accepted=" + conv.accepted + " rejected=" + conv.rejected + " maneuvers=" + conv.seq);
    }
}
