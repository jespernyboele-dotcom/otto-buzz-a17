/* OTTO R14 — A17 replacement for the OEM libscreenrecord.so (32-bit ARM).
 * R3 test (2026-10-25): bitrate override from /data/adb/otto/config/recorder_bitrate (absent = unchanged
 * behaviour) for the standby server and every session, plus a 10 s log of the bitrate actually delivered.
 * R5 (2026-10-31): the first synthetic AU after an encoder AU waits 25 ms instead of one frame (16.667 ms).
 * With a 60 fps source the encoder's own jitter made R3 insert ~10 synthetic AUs/s between real ones (70 AU/s
 * sent); R4 (the same change as a binary patch) measured 59.8 real + 0.2 synthetic AU/s in the car.
 * R6 (2026-10-31): during the first 90 s after boot, up to 5 scrcpy start failures (0.5 s apart) before falling back to
 * screenrecord, instead of 2. A server started before Android's display is on (~25 s) often delivers nothing; once
 * (boot cac97410) two failures in a row fell back to screenrecord and lylinkservice then rebooted the box.
 * Same C entry points and object interface that lyscrservice uses:
 *   obj = ScreenRecord_Create();  vtable: [0] dtor [1] deleting dtor [2] init(params)
 *   [3] start() [4] stop();  params = { int w; int h; float fps; int bitrate; cb }
 *   cb(type, data, size): type 1 = codec config (SPS+PPS), type 2 = one frame (Annex B).
 * The OEM library drives libgui/libstagefright through A13-only ABI; this one gets the
 * H.264 stream from A17's own /system/bin/screenrecord through a pipe instead.
 * Freestanding C: only libc + liblog symbols, declared by hand. */
typedef unsigned int u32; typedef unsigned char u8;
typedef void (*frame_cb)(int, void *, int);
struct pollfd { int fd; short events; short revents; };
extern void *malloc(u32); extern void free(void *); extern void *memmove(void *, const void *, u32);
extern int pipe(int *); extern int fork(void); extern int dup2(int, int); extern int close(int);
extern int execv(const char *, char *const *); extern void _exit(int);
extern int read(int, void *, u32); extern int poll(struct pollfd *, u32, int);
extern int kill(int, int); extern int waitpid(int, int *, int); extern int fcntl(int, int, ...);
extern int pthread_create(long *, const void *, void *(*)(void *), void *); extern int pthread_join(long, void **);
extern int snprintf(char *, u32, const char *, ...); extern int usleep(u32);
extern int __android_log_print(int, const char *, const char *, ...);
struct timespec_ { long tv_sec; long tv_nsec; };
extern int clock_gettime(int, struct timespec_ *);
static long now_ms(void) { struct timespec_ t; clock_gettime(1 /* CLOCK_MONOTONIC */, &t); return t.tv_sec * 1000 + t.tv_nsec / 1000000; }
#define KEEPALIVE_MS 2000
struct sockaddr_un_ { unsigned short sun_family; char sun_path[108]; };
extern int socket(int, int, int); extern int connect(int, const void *, u32);
extern int access(const char *, int); extern int putenv(char *); extern int open(const char *, int, ...);
extern int pthread_mutex_lock(void *); extern int pthread_mutex_unlock(void *);
extern u32 strlen(const char *); extern int getpid(void); extern int prctl(int, ...);
static long mtx[10];                              /* zero-initialised pthread_mutex_t */
static volatile int sb_pid; static volatile u32 sb_scid; static volatile long sb_born; static volatile int in_session;
static u32 scid_ctr;
static const char *jar_path(void) {
    if (access("/system/etc/otto_scrcpy_server.jar", 4) == 0) return "/system/etc/otto_scrcpy_server.jar";
    if (access("/data/local/tmp/otto_scrcpy_server.jar", 4) == 0) return "/data/local/tmp/otto_scrcpy_server.jar";
    return 0;
}
/* R3: lyscrservice's liblog output never reaches logcat on A17, so every line also goes to a file (cap 1 MiB) */
typedef __builtin_va_list va_list_;
extern int vsnprintf(char *, u32, const char *, va_list_); extern int write(int, const void *, u32); extern long lseek(int, long, int);
static void rlog(const char *fmt, ...) {
    char line[256]; va_list_ ap; int n, fd; long t = now_ms();
    __builtin_va_start(ap, fmt); n = snprintf(line, sizeof(line), "%ld.%03ld ", t / 1000, t % 1000);
    n += vsnprintf(line + n, sizeof(line) - (u32)n - 1, fmt, ap); __builtin_va_end(ap);
    if (n > (int)sizeof(line) - 2) n = (int)sizeof(line) - 2;
    __android_log_print(6, "ScreenRecord", "%s", line);
    line[n++] = '\n';
    fd = open("/data/adb/otto/logs/recorder.log", 01 | 0100 | 02000 /* O_WRONLY|O_CREAT|O_APPEND */, 0644);
    if (fd < 0) return;
    if (lseek(fd, 0, 2 /* SEEK_END */) > 1048576) { close(fd); fd = open("/data/adb/otto/logs/recorder.log", 01 | 0100 | 01000 /* O_TRUNC */, 0644); if (fd < 0) return; }
    write(fd, line, (u32)n); close(fd);
}
#define LOG(...) rlog(__VA_ARGS__)
/* R3: bits/s from /data/adb/otto/config/recorder_bitrate (decimal); 0 = no override or out of 1-40 Mbit/s */
static int cfg_bitrate(void) {
    char b[16]; int fd = open("/data/adb/otto/config/recorder_bitrate", 0 /* O_RDONLY */), n, i, v = 0;
    if (fd < 0) return 0;
    n = read(fd, b, sizeof(b)); close(fd);
    for (i = 0; i < n && i < 9 && b[i] >= '0' && b[i] <= '9'; i++) v = v * 10 + (b[i] - '0');
    return (v >= 1000000 && v <= 40000000) ? v : 0;
}
static int eff_rate(int asked) { int v = cfg_bitrate(); return v ? v : asked; }
#define BUFSZ (4u * 1024u * 1024u)

struct Params { int w; int h; int fps_bits; int bitrate; frame_cb cb; };
struct Obj { void **vptr; int w; int h; int bitrate; frame_cb cb; long thread; volatile int state; volatile int child; };

static int nal_start(const u8 *b, u32 n, u32 from, u32 *sclen) {   /* next start code at/after from, or -1 */
    u32 i;
    for (i = from; i + 3 <= n; i++) {
        if (b[i] == 0 && b[i + 1] == 0) {
            if (b[i + 2] == 1) { *sclen = 3; return (int)i; }
            if (i + 4 <= n && b[i + 2] == 0 && b[i + 3] == 1) { *sclen = 4; return (int)i; }
        }
    }
    return -1;
}

/* Split a buffer of whole NAL units into config (7,8) and access units, call cb for each. */
static void eg_config(const u8 *nal, u32 n); static void eg_frame(u8 *au, u32 n);
static int eg_active;      /* set while the scrcpy backend runs */
static void out_cfg(struct Obj *o, u8 *d, u32 n) {
    if (eg_active) { u32 sc = 0, sc2 = 0; int pos = nal_start(d, n, 0, &sc), next; while (pos >= 0) { u32 hdr = (u32)pos + sc; if (hdr >= n) break; next = nal_start(d, n, hdr, &sc2); eg_config(d + hdr, (next >= 0 ? (u32)next : n) - hdr); sc = sc2; pos = next; } }
    o->cb(1, d, (int)n);
}
static void out_frame(struct Obj *o, u8 *d, u32 n) { if (eg_active) eg_frame(d, n); o->cb(2, d, (int)n); }
static void emit(struct Obj *o, u8 *b, u32 n, int *frames) {
    u32 sc = 0, sc2 = 0, au_start = 0, cfg_start = 0; int pos, next, in_cfg = 0, au_has_vcl = 0, have_au = 0;
    pos = nal_start(b, n, 0, &sc);
    while (pos >= 0) {
        u32 hdr = (u32)pos + sc; int type, first_mb0, is_vcl;
        if (hdr >= n) break;
        next = nal_start(b, n, hdr, &sc2);
        type = b[hdr] & 0x1f; is_vcl = (type >= 1 && type <= 5);
        first_mb0 = (hdr + 1 < n) ? (b[hdr + 1] & 0x80) : 0;
        if (type == 7 || type == 8) {
            if (have_au) { out_frame(o, b + au_start, (u32)pos - au_start); (*frames)++; have_au = 0; au_has_vcl = 0; }
            if (!in_cfg) { in_cfg = 1; cfg_start = (u32)pos; }
        } else {
            if (in_cfg) { out_cfg(o, b + cfg_start, (u32)pos - cfg_start); in_cfg = 0; }
            if (have_au && au_has_vcl && (!is_vcl || first_mb0)) {
                out_frame(o, b + au_start, (u32)pos - au_start); (*frames)++; have_au = 0; au_has_vcl = 0;
            }
            if (!have_au) { have_au = 1; au_start = (u32)pos; }
            if (is_vcl) au_has_vcl = 1;
        }
        sc = sc2; pos = next;
    }
    if (in_cfg) out_cfg(o, b + cfg_start, n - cfg_start);
    if (have_au) { out_frame(o, b + au_start, n - au_start); (*frames)++; }
}

/* Keep-alive: lylinkservice reboots the box ("addH264Data fail") when no frame arrives
 * for ~10 s, and screenrecord only encodes when the picture changes. When idle, alternate
 * the display colour matrix between two near-identity values (1.0 / 0.9999): invisible,
 * but SurfaceFlinger recomposes and the encoder emits a small P-frame. */
static void sf_nudge(int phase) {
    int pid = fork();
    if (pid == 0) {
        char *e = phase ? "0.9999" : "1";
        char *argv[40]; int i = 0, k;
        argv[i++] = "service"; argv[i++] = "call"; argv[i++] = "SurfaceFlinger"; argv[i++] = "1015";
        argv[i++] = "i32"; argv[i++] = phase < 0 ? "0" : "1";
        if (phase >= 0) for (k = 0; k < 16; k++) { argv[i++] = "f"; argv[i++] = (k % 5 == 0) ? ((k == 15) ? "1" : e) : "0"; }
        argv[i] = 0;
        close(1); close(2);
        execv("/system/bin/service", argv); _exit(127);
    }
    if (pid > 0) waitpid(pid, 0, 0);
}

/* ---- fallback backend: A17 screenrecord + idle colour-matrix nudge (the accepted R17 path) ---- */
static void *run_screenrecord(void *arg) {
    struct Obj *o = (struct Obj *)arg; u8 *buf; int frames = 0, logged = 0, spawns = 0, nudges = 0, phase = 0; long last_frame;
    char size[32], rate[32];
    LOG("otto-a17 run: %dx%d bitrate=%d", o->w, o->h, o->bitrate);
    buf = (u8 *)malloc(BUFSZ);
    if (!buf) { LOG("otto-a17 ERROR: malloc"); o->state = 0; return 0; }
    snprintf(size, sizeof(size), "%dx%d", o->w, o->h); snprintf(rate, sizeof(rate), "%d", eff_rate(o->bitrate));
    while (o->state == 1) {                       /* (re)spawn screenrecord until stopped */
        int fds[2]; int pid; u32 have = 0;
        last_frame = now_ms();
        if (pipe(fds) != 0) { LOG("otto-a17 ERROR: pipe"); usleep(500000); continue; }
        pid = fork();
        if (pid == 0) {
            char *argv[10]; int i = 0;
            argv[i++] = "screenrecord"; argv[i++] = "--output-format=h264";
            argv[i++] = "--size"; argv[i++] = size; argv[i++] = "--bit-rate"; argv[i++] = rate;
            argv[i++] = "--time-limit"; argv[i++] = "0"; argv[i++] = "-"; argv[i] = 0;
            dup2(fds[1], 1); close(fds[0]); close(fds[1]);
            execv("/system/bin/screenrecord", argv); _exit(127);
        }
        close(fds[1]);
        if (pid < 0) { LOG("otto-a17 ERROR: fork"); close(fds[0]); usleep(500000); continue; }
        o->child = pid; fcntl(fds[0], 1031 /* F_SETPIPE_SZ */, 1048576);
        spawns++; LOG("otto-a17 screenrecord pid=%d spawn=%d", pid, spawns);
        while (o->state == 1) {
            struct pollfd p; int r; p.fd = fds[0]; p.events = 1 /* POLLIN */; p.revents = 0;
            r = poll(&p, 1, have ? 4 : 200);
            if (r > 0 && (p.revents & 1)) {
                int n = read(fds[0], buf + have, BUFSZ - have);
                if (n <= 0) { LOG("otto-a17 stream ended (read=%d)", n); break; }
                have += (u32)n;
                if (have < BUFSZ - 65536u) continue;   /* keep gathering until the writer pauses */
            } else if (r > 0) { LOG("otto-a17 pipe closed revents=%d", (int)p.revents); break; }
            if (have) {
                emit(o, buf, have, &frames); have = 0; last_frame = now_ms();
                if (!logged && frames > 0) { LOG("otto-a17 first frame delivered"); logged = 1; }
            } else if (logged && now_ms() - last_frame >= KEEPALIVE_MS) {
                phase = !phase; sf_nudge(phase); nudges++; last_frame = now_ms();
                if (nudges == 1 || nudges % 100 == 0) LOG("otto-a17 keep-alive nudge #%d (frames=%d)", nudges, frames);
            }
        }
        kill(pid, 2); usleep(100000); kill(pid, 9); waitpid(pid, 0, 0); o->child = 0;
        close(fds[0]);
        if (o->state == 1) usleep(300000);
    }
    free(buf);
    if (nudges) sf_nudge(-1);                     /* clear the colour matrix again */
    LOG("otto-a17 run exit, frames=%d spawns=%d nudges=%d", frames, spawns, nudges);
    return 0;
}

/* ---- 60 fps cadence engine (scrcpy backend, Baseline/CAVLC stream) ----
 * The encoder goes quiet on a static screen (the platform repeats a frame at most 10 times).
 * To keep a constant ~60 fps access-unit cadence the wrapper inserts standard P slices in which
 * every macroblock is skipped ("picture unchanged", 10 bytes at 1920x840). All frames are
 * reference frames, so frame_num of the encoder's own P slices is renumbered to stay continuous.
 * Only enabled when the stream matches what the generator assumes (Baseline, CAVLC, POC type 2,
 * single slice group, no weighted prediction, no redundant pictures). */
static struct { int on, sps_ok, pps_ok, fn_bits, nmb, deblock, cnt, have_idr, synth, real; } eg;
static long long now_us(void) { struct timespec_ t; clock_gettime(1, &t); return (long long)t.tv_sec * 1000000 + t.tv_nsec / 1000; }
struct br { const u8 *b; u32 n, p; };
static u32 br_u(struct br *r, int k) { u32 v = 0; while (k--) { u32 by = r->p >> 3; v = (v << 1) | (by < r->n ? (r->b[by] >> (7 - (r->p & 7))) & 1 : 0); r->p++; } return v; }
static u32 br_ue(struct br *r) { int z = 0; while (z < 24 && br_u(r, 1) == 0) z++; return z ? ((1u << z) - 1 + br_u(r, z)) : 0; }
static int br_se(struct br *r) { u32 v = br_ue(r); return (v & 1) ? (int)((v + 1) >> 1) : -(int)(v >> 1); }
static u32 unescape(const u8 *in, u32 n, u8 *out, u32 cap) {
    u32 i, o = 0, z = 0;
    for (i = 0; i < n && o < cap; i++) { if (z >= 2 && in[i] == 3) { z = 0; continue; } out[o++] = in[i]; z = in[i] ? 0 : z + 1; }
    return o;
}
static void eg_config(const u8 *nal, u32 n) {          /* nal points at the NAL header byte */
    u8 t[96]; struct br r; int type = nal[0] & 0x1f;
    r.n = unescape(nal + 1, n - 1, t, sizeof(t)); r.b = t; r.p = 0;
    if (type == 7) {
        u32 profile = br_u(&r, 8), poc, w, h; br_u(&r, 16); br_ue(&r);
        eg.sps_ok = 0;
        if (profile != 66) return;
        eg.fn_bits = (int)br_ue(&r) + 4; poc = br_ue(&r);
        if (poc != 2) return;
        br_ue(&r); br_u(&r, 1); w = br_ue(&r) + 1; h = br_ue(&r) + 1;
        if (!br_u(&r, 1)) return;                           /* frame_mbs_only_flag must be 1 */
        eg.nmb = (int)(w * h); eg.sps_ok = (eg.fn_bits <= 16 && eg.nmb > 0);
    } else if (type == 8) {
        u32 entropy, bottom, groups, l0, wp, redundant;
        br_ue(&r); br_ue(&r); entropy = br_u(&r, 1); bottom = br_u(&r, 1); groups = br_ue(&r);
        eg.pps_ok = 0;
        if (groups) return;
        l0 = br_ue(&r); br_ue(&r); wp = br_u(&r, 1); br_u(&r, 2); br_se(&r); br_se(&r); br_se(&r);
        eg.deblock = (int)br_u(&r, 1); br_u(&r, 1); redundant = br_u(&r, 1);
        eg.pps_ok = (!entropy && !bottom && l0 == 0 && !wp && !redundant);
    }
    eg.on = eg.sps_ok && eg.pps_ok;
}
/* renumber every slice of one access unit in place; returns 1 if the unit is usable */
static void eg_frame(u8 *au, u32 n) {
    u32 sc = 0, sc2 = 0; int pos = nal_start(au, n, 0, &sc), next;
    while (pos >= 0) {
        u32 hdr = (u32)pos + sc; int type; if (hdr >= n) break;
        next = nal_start(au, n, hdr, &sc2); type = au[hdr] & 0x1f;
        if (type == 5) { eg.cnt = 0; eg.have_idr = 1; }
        else if (type == 1 && eg.on && eg.have_idr) {
            struct br r; u32 first, k; r.b = au + hdr + 1; r.n = n - hdr - 1; r.p = 0;
            first = br_ue(&r); br_ue(&r); br_ue(&r);
            if (first == 0) eg.cnt = (eg.cnt + 1) & ((1 << eg.fn_bits) - 1);
            for (k = 0; k < (u32)eg.fn_bits; k++) {
                u32 bp = r.p + k, by = hdr + 1 + (bp >> 3), sh = 7 - (bp & 7), bit = (eg.cnt >> (eg.fn_bits - 1 - k)) & 1;
                au[by] = (u8)((au[by] & ~(1u << sh)) | (bit << sh));
            }
        }
        sc = sc2; pos = next;
    }
    eg.real++;
}
struct bw { u8 raw[32]; u32 p; };
static void bw_u(struct bw *w, int k, u32 v) { while (k--) { if ((v >> k) & 1) w->raw[w->p >> 3] |= (u8)(0x80 >> (w->p & 7)); w->p++; } }
static void bw_ue(struct bw *w, u32 v) { int n = 0; u32 x = v + 1; while (x >> (n + 1)) n++; bw_u(w, n, 0); bw_u(w, n + 1, v + 1); }
static u32 eg_skip_slice(u8 *out) {                    /* returns length, start code included */
    struct bw w; u32 i, n, o = 0, z = 0;
    for (i = 0; i < sizeof(w.raw); i++) w.raw[i] = 0;
    w.p = 0;
    eg.cnt = (eg.cnt + 1) & ((1 << eg.fn_bits) - 1);
    bw_ue(&w, 0); bw_ue(&w, 0); bw_ue(&w, 0); bw_u(&w, eg.fn_bits, (u32)eg.cnt);
    bw_u(&w, 1, 0); bw_u(&w, 1, 0); bw_u(&w, 1, 0);       /* no override, no list modification, sliding window */
    bw_ue(&w, 0);                                         /* slice_qp_delta se(0) */
    if (eg.deblock) bw_ue(&w, 1);                         /* disable_deblocking_filter_idc = 1 */
    bw_ue(&w, (u32)eg.nmb);                               /* mb_skip_run = whole picture */
    bw_u(&w, 1, 1); n = (w.p + 7) >> 3;                   /* rbsp stop bit, zero aligned */
    out[o++] = 0; out[o++] = 0; out[o++] = 0; out[o++] = 1; out[o++] = 0x41;
    for (i = 0; i < n; i++) { if (z >= 2 && w.raw[i] <= 3) { out[o++] = 3; z = 0; } out[o++] = w.raw[i]; z = w.raw[i] ? 0 : z + 1; }
    return o;
}

/* ---- primary backend: scrcpy-server (platform MediaCodec, repeat-previous-frame, raw Annex B) ---- */
static int spawn_scrcpy(u32 scid, int w, int h, int bitrate) {
    static char cp[160]; char a_scid[24], a_rate[40]; const char *jar = jar_path(); int pid;
    if (!jar) return -1;
    int rate = eff_rate(bitrate);
    snprintf(a_scid, sizeof(a_scid), "scid=%08x", scid); snprintf(a_rate, sizeof(a_rate), "video_bit_rate=%d", rate);
    LOG("otto-r3 scrcpy scid=%08x bitrate=%d (asked %d)", scid, rate, bitrate);
    (void)w; (void)h;
    pid = fork();
    if (pid == 0) {
        char *argv[24]; int i = 0, fd;
        prctl(1 /* PR_SET_PDEATHSIG */, 9);        /* never outlive lyscrservice */
        snprintf(cp, sizeof(cp), "CLASSPATH=%s", jar); putenv(cp);
        argv[i++] = "app_process"; argv[i++] = "/"; argv[i++] = "com.genymobile.scrcpy.Server"; argv[i++] = "4.1";
        argv[i++] = a_scid; argv[i++] = "log_level=info"; argv[i++] = "tunnel_forward=true"; argv[i++] = "control=false";
        argv[i++] = "audio=false"; argv[i++] = "cleanup=false"; argv[i++] = "raw_stream=true"; argv[i++] = "video_codec=h264";
        argv[i++] = "video_encoder=c2.qti.avc.encoder"; argv[i++] = "max_size=0"; argv[i++] = "downsize_on_error=false";
        argv[i++] = a_rate; argv[i++] = "max_fps=60"; argv[i++] = "power_on=false";
        argv[i++] = "video_codec_options=profile=1,level=8192"; argv[i] = 0;
        fd = open("/dev/null", 2); if (fd >= 0) { dup2(fd, 0); dup2(fd, 1); dup2(fd, 2); }
        execv("/system/bin/app_process", argv); _exit(127);
    }
    return pid;
}
static void reap(int pid) { if (pid > 0) { kill(pid, 15); usleep(150000); kill(pid, 9); waitpid(pid, 0, 0); } }
static int alive(int pid) { return pid > 0 && waitpid(pid, 0, 1 /* WNOHANG */) == 0; }
static long uptime_ms(void) { return now_ms(); }

/* standby manager: keeps one idle server ready so that start() only has to connect */
static int sb_w = 1920, sb_h = 840, sb_rate = 4194304;
static void *standby_thread(void *arg) {
    (void)arg;
    for (;;) {
        usleep(1000000);
        if (uptime_ms() < 18000 || in_session || !jar_path()) continue;
        pthread_mutex_lock(mtx);
        if (sb_pid > 0 && !alive(sb_pid)) {            /* died while idle (e.g. too early in boot) */
            long age = now_ms() - sb_born; sb_pid = 0;
            pthread_mutex_unlock(mtx);
            if (age < 5000) usleep(3000000);
            continue;
        }
        if (sb_pid <= 0 && !in_session) {
            sb_scid = (((u32)getpid() & 0x7fff) << 16 | (++scid_ctr & 0xffff)) & 0x7fffffff;
            sb_pid = spawn_scrcpy(sb_scid, sb_w, sb_h, sb_rate); sb_born = now_ms();
            LOG("otto-r2 standby scrcpy pid=%d scid=%08x", sb_pid, sb_scid);
        }
        pthread_mutex_unlock(mtx);
    }
    return 0;
}
__attribute__((constructor)) static void r2_init(void) {
    long t; pthread_create(&t, 0, standby_thread, 0);
}

/* returns 0 when stopped normally, 1 on backend failure */
static int run_scrcpy(struct Obj *o, u8 *buf, int *frames, int *logged) {
    int pid; u32 scid; int fd = -1, tries; u32 have = 0; long t_start = now_ms(), t_conn, last = 0; int got = 0, rc = 1;
    struct sockaddr_un_ sa; char name[32]; u32 nlen, i;
    pthread_mutex_lock(mtx);
    if (sb_pid > 0 && alive(sb_pid)) { pid = sb_pid; scid = sb_scid; sb_pid = 0; }
    else { sb_pid = 0; scid = (((u32)getpid() & 0x7fff) << 16 | (++scid_ctr & 0xffff)) & 0x7fffffff; pid = spawn_scrcpy(scid, o->w, o->h, o->bitrate); }
    pthread_mutex_unlock(mtx);
    if (pid <= 0) { LOG("otto-r2 scrcpy unavailable"); return 1; }
    snprintf(name, sizeof(name), "scrcpy_%08x", scid); nlen = strlen(name);
    for (i = 0; i < sizeof(sa.sun_path); i++) sa.sun_path[i] = 0;
    sa.sun_family = 1; for (i = 0; i < nlen; i++) sa.sun_path[1 + i] = name[i];
    for (tries = 0; tries < 80 && o->state == 1; tries++) {      /* up to ~4 s for a cold server */
        fd = socket(1 /* AF_UNIX */, 1 /* SOCK_STREAM */, 0);
        if (fd >= 0 && connect(fd, &sa, 2 + 1 + nlen) == 0) break;
        if (fd >= 0) close(fd);
        fd = -1;
        if (!alive(pid)) { LOG("otto-r2 scrcpy pid=%d exited before connect", pid); waitpid(pid, 0, 0); return 1; }
        usleep(50000);
    }
    if (fd < 0) { LOG("otto-r2 scrcpy connect timeout"); reap(pid); return 1; }
    t_conn = now_ms(); o->child = pid;
    LOG("otto-r2 scrcpy pid=%d scid=%08x connected after %ld ms", pid, scid, t_conn - t_start);
    eg.on = eg.sps_ok = eg.pps_ok = eg.have_idr = eg.cnt = eg.synth = eg.real = 0; eg_active = 1;
    {
    long long due = 0; u8 skip[48]; u32 win_bytes = 0; long win_t = now_ms(); int win_real = 0, win_synth = 0;
    while (o->state == 1) {
        struct pollfd p; int r, to; long long t = now_us();
        p.fd = fd; p.events = 1; p.revents = 0;
        if (have) to = 2;
        else if (eg.on && eg.have_idr && due) { long long d = (due - t) / 1000; to = d < 0 ? 0 : (d > 100 ? 100 : (int)d); }
        else to = 100;
        r = poll(&p, 1, to);
        if (r > 0 && (p.revents & 1)) {
            int n = read(fd, buf + have, BUFSZ - have);
            if (n <= 0) { LOG("otto-r2 scrcpy stream ended (read=%d)", n); break; }
            have += (u32)n; win_bytes += (u32)n;
            if (have < BUFSZ - 65536u) continue;
        } else if (r > 0) { LOG("otto-r2 scrcpy socket closed revents=%d", (int)p.revents); break; }
        if (have) {
            emit(o, buf, have, frames); have = 0; last = now_ms(); due = now_us() + 25000;   /* R5: 1.5 frames */
            if (!got) { got = 1; LOG("otto-r2 scrcpy first data %ld ms after start; cadence engine %s (fn_bits=%d mbs=%d)", last - t_start, eg.on ? "ON" : "OFF", eg.fn_bits, eg.nmb); }
            if (!*logged && *frames > 0) { LOG("otto-a17 first frame delivered"); *logged = 1; }
        } else if (eg.on && eg.have_idr && due && now_us() >= due) {
            u32 n = eg_skip_slice(skip); o->cb(2, skip, (int)n); (*frames)++; eg.synth++;
            due += 16667; if (due < now_us() - 50000) due = now_us() + 16667;
        } else if (!got && now_ms() - t_conn > 3000) { LOG("otto-r2 scrcpy no data within 3 s"); break; }
        else if (!eg.on && got && now_ms() - last > 5000) { LOG("otto-r2 scrcpy stalled >5 s"); break; }
        if (now_ms() - win_t >= 10000) {           /* R3: what the encoder really delivered */
            long dt = now_ms() - win_t;
            LOG("otto-r3 stats %ld ms: %u kbit/s real=%d synth=%d", dt, (u32)((unsigned long long)win_bytes * 8u / (u32)dt),
                eg.real - win_real, eg.synth - win_synth);
            win_bytes = 0; win_t = now_ms(); win_real = eg.real; win_synth = eg.synth;
        }
    }
    }
    eg_active = 0;
    LOG("otto-r2 scrcpy session end: real=%d synthetic=%d", eg.real, eg.synth);
    if (o->state != 1) rc = 0;
    close(fd); reap(pid); o->child = 0;
    return rc;
}

static void *run(void *arg) {
    struct Obj *o = (struct Obj *)arg; u8 *buf; int frames = 0, logged = 0, fails = 0;
    in_session = 1; sb_w = o->w; sb_h = o->h; sb_rate = o->bitrate;
    buf = (u8 *)malloc(BUFSZ);
    if (buf && jar_path()) {
        LOG("otto-r2 run: %dx%d bitrate=%d backend=scrcpy", o->w, o->h, o->bitrate);
        int maxf = now_ms() < 90000 ? 5 : 2;            /* R6: early boot gets more attempts */
        while (o->state == 1 && fails < maxf) {
            long t = now_ms();
            if (run_scrcpy(o, buf, &frames, &logged) == 0) break;
            if (now_ms() - t > 30000) fails = 0;       /* it ran fine for a while: not a startup failure */
            fails++;
            LOG("otto-r2 scrcpy backend failure #%d of %d (frames so far %d)", fails, maxf, frames);
            if (fails < maxf && now_ms() < 90000) usleep(500000);
        }
    }
    if (buf) free(buf);
    in_session = 0;
    if (o->state == 1) {
        LOG("otto-r2 falling back to screenrecord backend");
        return run_screenrecord(o);
    }
    LOG("otto-r2 run exit, frames=%d", frames);
    return 0;
}

static void m_dtor(struct Obj *o) { (void)o; }
static void m_stop(struct Obj *o) {
    if (!o->state) return;
    LOG("otto-a17 stop"); o->state = 2; pthread_join(o->thread, 0); o->state = 0;
}
static void m_deldtor(struct Obj *o) { if (o) { m_stop(o); free(o); } }
static int m_init(struct Obj *o, struct Params *p) {
    o->w = p->w; o->h = p->h; o->bitrate = p->bitrate; o->cb = p->cb;
    LOG("otto-a17 -->init:%dx%d bitRate=%d (Recorder 2.1-R3 test: override %d)", o->w, o->h, o->bitrate, cfg_bitrate());
    LOG("init ok");
    return 0;
}
static void m_start(struct Obj *o) {
    if (o->state) return;
    o->state = 1;
    if (pthread_create(&o->thread, 0, run, o) != 0) { o->state = 0; LOG("otto-a17 ERROR: pthread_create"); }
}
static void *vtable[5] = { (void *)m_dtor, (void *)m_deldtor, (void *)m_init, (void *)m_start, (void *)m_stop };

__attribute__((visibility("default"))) void *ScreenRecord_Create(void) {
    struct Obj *o = (struct Obj *)malloc(sizeof(struct Obj));
    if (!o) return 0;
    o->vptr = vtable; o->w = 0; o->h = 0; o->bitrate = 0; o->cb = 0; o->thread = 0; o->state = 0; o->child = 0;
    return o;
}
__attribute__((visibility("default"))) void *MiniCap_Create(void) { return ScreenRecord_Create(); }
