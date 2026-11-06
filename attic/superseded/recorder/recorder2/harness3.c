/* harness 3: one 20 s session; logs access units per second and the largest gap; writes the stream */
typedef void (*frame_cb)(int, void *, int);
extern void *ScreenRecord_Create(void); extern int usleep(unsigned); extern void _exit(int);
extern int __android_log_print(int, const char *, const char *, ...);
extern int open(const char *, int, ...); extern int write(int, const void *, unsigned); extern int close(int);
struct timespec_ { long tv_sec; long tv_nsec; }; extern int clock_gettime(int, struct timespec_ *);
static long ms(void) { struct timespec_ t; clock_gettime(1, &t); return t.tv_sec * 1000 + t.tv_nsec / 1000000; }
struct Params { int w; int h; float fps; int bitrate; frame_cb cb; };
static int fd = -1, persec[40], small[40], ncfg, nfrm; static long t0, t_first, t_last, maxgap, gap_over_25, gap_over_50;
static void cb(int type, void *data, int size) {
    long n = ms(); int s = (int)((n - t0) / 1000);
    if (fd >= 0) write(fd, data, size);
    if (type == 1) { ncfg++; return; }
    nfrm++; if (s >= 0 && s < 40) { persec[s]++; if (size <= 16) small[s]++; }
    if (!t_first) t_first = n; else { long g = n - t_last; if (g > maxgap) maxgap = g; if (g > 25) gap_over_25++; if (g > 50) gap_over_50++; }
    t_last = n;
}
void _start(void) {
    struct Params p; void **obj; void **vt; int i; char line[400]; int o = 0;
    usleep(6000000);
    p.w = 1920; p.h = 840; p.fps = 60.0f; p.bitrate = 4194304; p.cb = cb;
    fd = open("/data/local/tmp/otto_r2_harness3.h264", 01101, 0644);
    obj = (void **)ScreenRecord_Create(); vt = (void **)obj[0]; t0 = ms();
    ((int (*)(void *, void *))vt[2])(obj, &p); ((void (*)(void *))vt[3])(obj);
    for (i = 0; i < 200; i++) usleep(100000);
    ((void (*)(void *))vt[4])(obj); ((void (*)(void *))vt[1])(obj);
    if (fd >= 0) close(fd);
    __android_log_print(6, "OTTOHARNESS", "H3 first_frame_ms=%ld cfg=%d frames=%d max_gap_ms=%ld gaps>25ms=%ld gaps>50ms=%ld", t_first - t0, ncfg, nfrm, maxgap, gap_over_25, gap_over_50);
    __android_log_print(6, "OTTOHARNESS", "H3 AU/s   : %d %d %d %d %d %d %d %d %d %d | %d %d %d %d %d %d %d %d %d %d", persec[0],persec[1],persec[2],persec[3],persec[4],persec[5],persec[6],persec[7],persec[8],persec[9],persec[10],persec[11],persec[12],persec[13],persec[14],persec[15],persec[16],persec[17],persec[18],persec[19]);
    __android_log_print(6, "OTTOHARNESS", "H3 skip/s : %d %d %d %d %d %d %d %d %d %d | %d %d %d %d %d %d %d %d %d %d", small[0],small[1],small[2],small[3],small[4],small[5],small[6],small[7],small[8],small[9],small[10],small[11],small[12],small[13],small[14],small[15],small[16],small[17],small[18],small[19]);
    _exit(0);
}
