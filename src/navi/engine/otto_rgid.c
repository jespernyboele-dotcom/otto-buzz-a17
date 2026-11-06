/*
 * otto_rgid — OTTO route-guidance engine (test component, R1)
 *
 * normalized navigation events (text lines) -> stateful iAP2 Route Guidance output
 * (0x5202 maneuver cache, 0x5204 lane cache, 0x5201 route snapshot) for the proven
 * transport @com.liaoyuan.rlink.iapserver2 (command 3, selector 0, one message per command).
 *
 * Separate from /system/bin/otto_navbridge: it does not replace or touch it.
 *
 * Modes:
 *   otto_rgid fixture            events on stdin, emitted messages printed as "TX ..." lines
 *   otto_rgid run [--dry]        events on stdin, messages sent to iapserver2 (HU needed)
 *
 * Event lines (fields separated by '|', key=value):
 *   CAPS|road=N|dest=N|after=N|desc=N|mancap=N|lanedesc=N|lanecap=N   limits declared by the HU
 *   ROUTE_BEGIN                      start staging a NEW route generation (empty caches)
 *   MAN|idx=N|type=NAME|desc=..|after=..|dist=M|dstr=..|units=NAME|side=right/left|jtype=N|
 *       angles=a,b,c|exit=A|lane=N|exitinfo=..
 *   LANE|idx=N|desc=..|l=STATUS:a,b,c:HL|l=...          STATUS notgood/good/preferred, HL optional
 *   TRIP|state=NAME|mstate=N|road=..|dest=..|eta=S|trem=S|drem=M|drstr=..|drunits=NAME|
 *        dnext=M|dnstr=..|dnunits=NAME|cur=i,j|lanecur=N|laneshow=0/1|visible=0/1|src=..|mcount=N|lanetot=N
 *   COMMIT                           validate everything staged, adopt atomically, emit
 *   STATE|NAME                       source state only (active rerouting inactive arrived ...)
 *   ROUTE_END                        source says the route is over
 *   HU_5200|<hex>  HU_5203|<hex>  HU_DISCONNECT          head-unit lifecycle
 *   TICK|ms                          advance the clock (fixture mode)
 */
#include <ctype.h>
#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/un.h>

#define MAXMSG 2040             /* message + selector byte must stay < 2048 (lylinkservice buffer) */
#define NMAN 32
#define NLEV 16
#define NLANE 8
#define NANG 16
#define NCUR 16
#define REROUTE_DEBOUNCE_MS 3000
#define CAPTURE_WINDOW_MS 1000
#define CAPTURE_RETRY_MS 30000

enum { ST_NONE = 0, ST_ROUTE_SET, ST_ARRIVED, ST_LOADING, ST_LOCATING, ST_REROUTING, ST_PROCEED };

typedef struct {
    int used; uint16_t idx; int type;
    char desc[256], after[256], dstr[32], exitinfo[64];
    int has_dist; uint32_t dist; int units, side, jtype;
    int nang; int16_t ang[NANG]; int has_exit; int16_t exitang; int lane;
    uint32_t sent;
} man_t;
typedef struct { int status, nang; int16_t ang[NANG]; int has_hl; int16_t hl; } lane_t;
typedef struct { int used; uint16_t idx; char desc[64]; int nl; lane_t l[NLANE]; uint32_t sent; } lev_t;
typedef struct {
    int state, mstate;
    char road[256], dest[256], src[64], drstr[32], dnstr[32];
    int has_eta; uint64_t eta; int has_trem; uint64_t trem;
    int has_drem; uint32_t drem; int drunits; int has_dnext; uint32_t dnext; int dnunits;
    int ncur; uint16_t cur[NCUR]; int lanecur, laneshow, visible;
    int mcount, lanetot;        /* optional totals stated by the source; -1 = count what is cached */
} trip_t;
typedef struct { man_t m[NMAN]; lev_t l[NLEV]; trip_t t; } route_t;
typedef struct { uint8_t b[MAXMSG + 8]; size_t n; int bad; } msg_t;

static struct { int road, dest, after, desc, mancap, lanedesc, lanecap; } caps = { 255, 255, 255, 255, NMAN, 63, NLEV };
static route_t cur, stage;
static int staging, stage_new, src_active;
static uint32_t gen, sent5201;
static int hu_sub; static unsigned hu_comp; static uint32_t hu_gen;
static long clock_ms, pending_clear_at = -1;
static long opt_confirm_ms = 0, confirm_at = -1; static int confirm_armed;   /* P8, see startup_clean */
static int mode_fixture = 1, mode_dry;
/* candidate 0.3 switches (command line, after the mode): defaults = protocol behaviour; the other value restores 0.2 bytes */
static int opt_requests_honor = 1;   /* X16: --requests=honor|ignore  - send 0x13 / 0x14 / exit info only when the 0x5200 asked for them */
static int opt_text_escaped = 1;     /* 0.5 / B8: --text=escaped|raw  - text values carry \\\\ (backslash), \\p ('|') and \\xHH (control character) */
static int opt_angles_repeat = 1;    /* X15: --angles=repeat|packed   - one int16 per TLV, TLV repeated (LaneAngle, JunctionElementAngle) */
static int req_src, req_srcrg, req_exit;   /* presence requests of the current subscription's 0x5200 (ids 1, 2, 3) */
static int chk_src, chk_srcrg, chk_exit;   /* requests seen in the message being checked */
static unsigned long n_tx, n_drop, n_reject;

static void say(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
#include <stdarg.h>
static int opt_quiet;                /* P3: --log=quiet - no line per message or per held event; a service log must not grow by a line a second */
static void say(const char *fmt, ...) {
    if (opt_quiet && (!strncmp(fmt, "SOCKET_WRITTEN", 14) || !strncmp(fmt, "HOLD ", 5))) return;
    va_list ap; va_start(ap, fmt); vprintf(fmt, ap); va_end(ap); putchar('\n'); fflush(stdout);
}
static long now_ms(void) {
    struct timespec ts;
    if (mode_fixture) return clock_ms;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000L + ts.tv_nsec / 1000000L;
}

/* ---------- names ---------- */
static const char *const MT[54] = {
    "NO_TURN", "LEFT_TURN", "RIGHT_TURN", "STRAIGHT_AHEAD", "U_TURN", "FOLLOW_ROAD", "ENTER_ROUNDABOUT",
    "EXIT_ROUNDABOUT", "OFF_RAMP", "ON_RAMP", "ARRIVE_END_OF_NAVIGATION", "START_ROUTE",
    "ARRIVE_AT_DESTINATION", "KEEP_LEFT", "KEEP_RIGHT", "ENTER_FERRY", "EXIT_FERRY", "CHANGE_FERRY",
    "START_ROUTE_WITH_U_TURN", "U_TURN_AT_ROUNDABOUT", "LEFT_TURN_AT_END", "RIGHT_TURN_AT_END",
    "HIGHWAY_OFF_RAMP_LEFT", "HIGHWAY_OFF_RAMP_RIGHT", "ARRIVE_DESTINATION_LEFT", "ARRIVE_DESTINATION_RIGHT",
    "U_TURN_WHEN_POSSIBLE", "ARRIVE_END_OF_DIRECTIONS", "ROUNDABOUT_EXIT_1", "ROUNDABOUT_EXIT_2",
    "ROUNDABOUT_EXIT_3", "ROUNDABOUT_EXIT_4", "ROUNDABOUT_EXIT_5", "ROUNDABOUT_EXIT_6", "ROUNDABOUT_EXIT_7",
    "ROUNDABOUT_EXIT_8", "ROUNDABOUT_EXIT_9", "ROUNDABOUT_EXIT_10", "ROUNDABOUT_EXIT_11", "ROUNDABOUT_EXIT_12",
    "ROUNDABOUT_EXIT_13", "ROUNDABOUT_EXIT_14", "ROUNDABOUT_EXIT_15", "ROUNDABOUT_EXIT_16", "ROUNDABOUT_EXIT_17",
    "ROUNDABOUT_EXIT_18", "ROUNDABOUT_EXIT_19", "SHARP_LEFT_TURN", "SHARP_RIGHT_TURN", "SLIGHT_LEFT_TURN",
    "SLIGHT_RIGHT_TURN", "CHANGE_HIGHWAY", "CHANGE_HIGHWAY_LEFT", "CHANGE_HIGHWAY_RIGHT" };
static int name_in(const char *v, const char *const *tab, int n) {
    int i; for (i = 0; i < n; i++) if (strcmp(v, tab[i]) == 0) return i; return -1;
}
static int units_of(const char *v) {
    static const char *const U[5] = { "km", "mi", "m", "yd", "ft" }; return name_in(v, U, 5);
}
static int state_of(const char *v) {
    static const char *const S[7] = { "inactive", "active", "arrived", "loading", "locating", "rerouting", "proceed" };
    return name_in(v, S, 7);
}
static int lstatus_of(const char *v) {
    static const char *const S[3] = { "notgood", "good", "preferred" }; return name_in(v, S, 3);
}

/* ---------- message building ---------- */
static void put8(msg_t *m, unsigned v) { if (m->n + 1 > MAXMSG) { m->bad = 1; return; } m->b[m->n++] = (uint8_t)v; }
static void put16(msg_t *m, unsigned v) { put8(m, v >> 8); put8(m, v); }
static void put32(msg_t *m, uint32_t v) { put16(m, v >> 16); put16(m, v & 0xffff); }
static void put64(msg_t *m, uint64_t v) { put32(m, (uint32_t)(v >> 32)); put32(m, (uint32_t)v); }
static void begin(msg_t *m, unsigned id) { m->n = 0; m->bad = 0; put16(m, 0x4040); put16(m, 0); put16(m, id); }
static void end(msg_t *m) { m->b[2] = (uint8_t)(m->n >> 8); m->b[3] = (uint8_t)m->n; }
static void tlv8(msg_t *m, unsigned id, unsigned v) { put16(m, 5); put16(m, id); put8(m, v); }
static void tlv16(msg_t *m, unsigned id, unsigned v) { put16(m, 6); put16(m, id); put16(m, v); }
static void tlv32(msg_t *m, unsigned id, uint32_t v) { put16(m, 8); put16(m, id); put32(m, v); }
static void tlv64(msg_t *m, unsigned id, uint64_t v) { put16(m, 12); put16(m, id); put64(m, v); }
/* UTF-8 text, cut at a character boundary to `cap` bytes, NUL-terminated */
static void tlvstr(msg_t *m, unsigned id, const char *s, int cap) {
    size_t n = strlen(s), i;
    if (cap >= 0 && n > (size_t)cap) { n = (size_t)cap; while (n > 0 && ((unsigned char)s[n] & 0xc0) == 0x80) n--; }
    put16(m, (unsigned)(n + 5)); put16(m, id);
    for (i = 0; i < n; i++) put8(m, (unsigned char)s[i]);
    put8(m, 0);
}
static void tlvarr16(msg_t *m, unsigned id, const int16_t *a, int n) {
    int i; put16(m, (unsigned)(4 + 2 * n)); put16(m, id); for (i = 0; i < n; i++) put16(m, (uint16_t)a[i]);
}
/* X15: a repeatable int16 parameter - one TLV per value (packed form kept behind --angles=packed) */
static void tlvrep16(msg_t *m, unsigned id, const int16_t *a, int n) {
    int i; if (!opt_angles_repeat) { tlvarr16(m, id, a, n); return; }
    for (i = 0; i < n; i++) tlv16(m, id, (uint16_t)a[i]);
}
static void dist_text(char *out, size_t cap, uint32_t meters, int units) {
    double v;
    switch (units) {
    case 0: v = meters / 1000.0; break;
    case 1: v = meters / 1609.344; break;
    case 3: v = meters / 0.9144; break;
    case 4: v = meters / 0.3048; break;
    default: snprintf(out, cap, "%u", (unsigned)meters); return;
    }
    if ((units == 0 || units == 1) && v < 10.0) snprintf(out, cap, "%.1f", v); else snprintf(out, cap, "%.0f", v);
}
static void build_5202(msg_t *m, unsigned comp, const man_t *a) {
    char ds[32];
    begin(m, 0x5202);
    tlv16(m, 0x00, comp);
    tlv16(m, 0x01, a->idx);
    if (a->desc[0]) tlvstr(m, 0x02, a->desc, caps.desc);
    tlv8(m, 0x03, (unsigned)a->type);
    if (a->after[0]) tlvstr(m, 0x04, a->after, caps.after);
    if (a->has_dist) {
        tlv32(m, 0x05, a->dist);
        if (a->dstr[0]) snprintf(ds, sizeof(ds), "%s", a->dstr); else dist_text(ds, sizeof(ds), a->dist, a->units);
        tlvstr(m, 0x06, ds, 31);
        tlv8(m, 0x07, (unsigned)a->units);
    }
    if (a->side >= 0) tlv8(m, 0x08, (unsigned)a->side);   /* side=none: the source does not know the traffic side */
    if (a->jtype >= 0) tlv8(m, 0x09, (unsigned)a->jtype);
    if (a->nang > 0) tlvrep16(m, 0x0a, a->ang, a->nang);
    if (a->has_exit) tlv16(m, 0x0b, (uint16_t)a->exitang);
    if (a->lane >= 0) tlv16(m, 0x0c, (unsigned)a->lane);
    if (a->exitinfo[0] && (!opt_requests_honor || req_exit)) tlvstr(m, 0x0d, a->exitinfo, 63);   /* X16 */
    end(m);
}
static void build_5204(msg_t *m, unsigned comp, const lev_t *e) {
    int i;
    begin(m, 0x5204);
    tlv16(m, 0x00, comp);
    tlv16(m, 0x01, e->idx);
    for (i = 0; i < e->nl; i++) {                /* one LaneInformations group per lane */
        const lane_t *l = &e->l[i];
        unsigned inner = 6 + 5 + (l->nang ? (opt_angles_repeat ? 6 * (unsigned)l->nang : 4 + 2 * (unsigned)l->nang) : 0) + (l->has_hl ? 6 : 0);
        put16(m, 4 + inner); put16(m, 0x02);
        tlv16(m, 0x00, (unsigned)i);
        tlv8(m, 0x01, (unsigned)l->status);
        if (l->nang) tlvrep16(m, 0x02, l->ang, l->nang);
        if (l->has_hl) tlv16(m, 0x03, (uint16_t)l->hl);
    }
    if (e->desc[0]) tlvstr(m, 0x03, e->desc, caps.lanedesc);
    end(m);
}
static int count_man(const route_t *r) { int i, n = 0; for (i = 0; i < NMAN; i++) n += r->m[i].used; return n; }
static int count_lev(const route_t *r) { int i, n = 0; for (i = 0; i < NLEV; i++) n += r->l[i].used; return n; }
static void build_5201(msg_t *m, unsigned comp, const route_t *r) {
    const trip_t *t = &r->t; char ds[32]; int16_t tmp[NCUR]; int i;
    begin(m, 0x5201);
    tlv16(m, 0x00, comp);
    tlv8(m, 0x01, (unsigned)t->state);
    if (t->mstate >= 0) tlv8(m, 0x02, (unsigned)t->mstate);
    if (t->road[0]) tlvstr(m, 0x03, t->road, caps.road);
    if (t->dest[0]) tlvstr(m, 0x04, t->dest, caps.dest);
    if (t->has_eta) tlv64(m, 0x05, t->eta);
    if (t->has_trem) tlv64(m, 0x06, t->trem);
    if (t->has_drem) {
        tlv32(m, 0x07, t->drem);
        if (t->drstr[0]) snprintf(ds, sizeof(ds), "%s", t->drstr); else dist_text(ds, sizeof(ds), t->drem, t->drunits);
        tlvstr(m, 0x08, ds, 31);
        if (t->drunits >= 0) tlv8(m, 0x09, (unsigned)t->drunits);
    }
    if (t->has_dnext) {
        tlv32(m, 0x0a, t->dnext);
        if (t->dnstr[0]) snprintf(ds, sizeof(ds), "%s", t->dnstr); else dist_text(ds, sizeof(ds), t->dnext, t->dnunits);
        tlvstr(m, 0x0b, ds, 31);
        if (t->dnunits >= 0) tlv8(m, 0x0c, (unsigned)t->dnunits);
    }
    if (t->ncur > 0) { for (i = 0; i < t->ncur; i++) tmp[i] = (int16_t)t->cur[i]; tlvarr16(m, 0x0d, tmp, t->ncur); }
    if (t->mcount >= 0) tlv16(m, 0x0e, (unsigned)t->mcount);
    else tlv16(m, 0x0e, (unsigned)(count_man(r) < caps.mancap ? count_man(r) : caps.mancap));   /* what the HU was actually given */
    tlv8(m, 0x0f, t->visible ? 1 : 0);
    if (count_lev(r) > 0 || t->lanecur >= 0 || t->lanetot >= 0) {   /* lanetot stated: say explicitly that lanes are (not) showing */
        if (t->lanecur >= 0) tlv16(m, 0x10, (unsigned)t->lanecur);
        tlv16(m, 0x11, (unsigned)(t->lanetot >= 0 ? t->lanetot : count_lev(r)));
        tlv8(m, 0x12, t->laneshow ? 1 : 0);
    }
    if (t->src[0] && (!opt_requests_honor || req_src)) tlvstr(m, 0x13, t->src, 63);          /* X16: only when requested */
    if (!opt_requests_honor || req_srcrg) tlv8(m, 0x14, 1);
    end(m);
}
static void build_stop(msg_t *m, unsigned comp) { begin(m, 0x5201); tlv16(m, 0x00, comp); tlv8(m, 0x01, 0); end(m); }
static uint32_t hash_msg(const msg_t *m) {
    uint32_t h = 2166136261u; size_t i;
    for (i = 0; i < m->n; i++) { h ^= m->b[i]; h *= 16777619u; }
    return h ? h : 1;
}

/* ---------- transport ---------- */
/* P2: three build classes. Offline: no transport at all. Test: only an abstract name that starts with "nr.test." given on the
 * command line - this build does not contain the OEM name. Device: the OEM name, fixed. */
#if defined(OTTO_TEST_ENDPOINT) && !defined(OTTO_OFFLINE_NO_SOCKET)
static const char *endpoint_name = 0;
#elif !defined(OTTO_OFFLINE_NO_SOCKET)
static const char *endpoint_name = "com.liaoyuan.rlink.iapserver2";
#endif
static int connect_iap(void) {
#ifdef OTTO_OFFLINE_NO_SOCKET
    return -1;                  /* offline campaign build: no transport compiled in */
#else
    struct sockaddr_un a; const char *name = endpoint_name; size_t n; int fd;
    if (!name) return -1;
    n = strlen(name);
    fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) return -1;
    memset(&a, 0, sizeof(a)); a.sun_family = AF_UNIX; memcpy(a.sun_path + 1, name, n);
    if (connect(fd, (struct sockaddr *)&a, (socklen_t)(offsetof(struct sockaddr_un, sun_path) + 1 + n)) != 0) { close(fd); return -1; }
    return fd;
#endif
}
static int write_all(int fd, const uint8_t *p, size_t n) {
    while (n) { ssize_t w = write(fd, p, n); if (w < 0) { if (errno == EINTR) continue; return -1; } p += w; n -= (size_t)w; }
    return 0;
}
static int tx_fd = -1;
static void link_lost(const char *why);
/* returns 0 when the bytes were handed to the socket; that is NOT proof of delivery to the HU */
static int tx(const msg_t *m) {
    uint8_t f[MAXMSG + 16]; uint32_t len = (uint32_t)m->n + 1; size_t i; unsigned id = (m->b[4] << 8) | m->b[5];
    if (m->bad || m->n < 6 || len >= 2048) { n_drop++; say("DROP msg=0x%04X len=%zu (bound)", id, m->n); return -2; }
    if (mode_fixture || mode_dry) {
        printf("TX 0x%04X len=%zu ", id, m->n);
        for (i = 0; i < m->n; i++) printf("%02X", m->b[i]);
        putchar('\n'); n_tx++; return 0;
    }
    f[0] = 3; f[1] = f[2] = f[3] = 0; f[4] = (uint8_t)len; f[5] = (uint8_t)(len >> 8); f[6] = f[7] = 0; f[8] = 0;
    memcpy(f + 9, m->b, m->n);
    if (tx_fd < 0) tx_fd = connect_iap();
    if (tx_fd < 0 || write_all(tx_fd, f, 9 + m->n) != 0) {
        n_drop++; say("SOCKET_WRITE_FAILED msg=0x%04X", id);
        link_lost("write failed");      /* P2: the peer is gone - nothing more is sent until the head unit's 0x5200 has been read again */
        return -1;
    }
    n_tx++; say("SOCKET_WRITTEN msg=0x%04X len=%zu (delivery to HU not confirmed here)", id, m->n);
    usleep(20000);
    return 0;
}

/* ---------- engine ---------- */
static man_t *find_man(route_t *r, unsigned idx, int add) {
    int i, fr = -1;
    for (i = 0; i < NMAN; i++) { if (r->m[i].used && r->m[i].idx == idx) return &r->m[i]; if (!r->m[i].used && fr < 0) fr = i; }
    if (!add || fr < 0) return 0;
    memset(&r->m[fr], 0, sizeof(man_t)); r->m[fr].used = 1; r->m[fr].idx = (uint16_t)idx;
    r->m[fr].jtype = -1; r->m[fr].lane = -1; r->m[fr].units = 2;
    return &r->m[fr];
}
static lev_t *find_lev(route_t *r, unsigned idx, int add) {
    int i, fr = -1;
    for (i = 0; i < NLEV; i++) { if (r->l[i].used && r->l[i].idx == idx) return &r->l[i]; if (!r->l[i].used && fr < 0) fr = i; }
    if (!add || fr < 0) return 0;
    memset(&r->l[fr], 0, sizeof(lev_t)); r->l[fr].used = 1; r->l[fr].idx = (uint16_t)idx;
    return &r->l[fr];
}
static void trip_reset(trip_t *t) { memset(t, 0, sizeof(*t)); t->mstate = -1; t->lanecur = -1; t->mcount = -1; t->lanetot = -1; t->visible = 1; t->drunits = 2; t->dnunits = 2; }
static void route_reset(route_t *r) { memset(r, 0, sizeof(*r)); trip_reset(&r->t); }
static int is_current(const route_t *r, unsigned idx) { int i; for (i = 0; i < r->t.ncur; i++) if (r->t.cur[i] == idx) return 1; return 0; }

/* everything a 0x5201 refers to goes out before it; unchanged objects are not repeated */
static void emit(int force) {
    msg_t m; int i, pass, sent_man = 0, tx_def = 0;
    if (!hu_sub) { say("HOLD no HU subscription (source %s)", src_active ? "active" : "inactive"); return; }
    if (!src_active) return;
    for (pass = 0; pass < 2; pass++)                 /* current maneuvers first, then the rest, up to the HU's capacity */
        for (i = 0; i < NMAN; i++) {
            man_t *a = &cur.m[i]; uint32_t h;
            if (!a->used || (is_current(&cur, a->idx) ? pass != 0 : pass != 1)) continue;
            if (sent_man >= caps.mancap) { say("SKIP maneuver idx=%u (HU capacity %d)", a->idx, caps.mancap); continue; }
            sent_man++;
            build_5202(&m, hu_comp, a); h = hash_msg(&m);
            if (!force && a->sent == h) continue;
            if (tx(&m) == 0) { a->sent = h; tx_def = 1; } else if (!hu_sub) return;
        }
    for (i = 0; i < NLEV; i++) {
        lev_t *e = &cur.l[i]; uint32_t h;
        if (!e->used) continue;
        build_5204(&m, hu_comp, e); h = hash_msg(&m);
        if (!force && e->sent == h) continue;
        if (tx(&m) == 0) e->sent = h; else if (!hu_sub) return;
    }
    if (!hu_sub) return;
    build_5201(&m, hu_comp, &cur);
    if (force || sent5201 != hash_msg(&m)) { if (tx(&m) == 0) sent5201 = hash_msg(&m); }
    if (confirm_armed && tx_def && hu_sub) { confirm_armed = 0; confirm_at = now_ms() + opt_confirm_ms; }
}
static void confirm_due(void) {
    if (confirm_at < 0 || now_ms() < confirm_at || staging) return;      /* never between an event and its COMMIT */
    confirm_at = -1;
    if (hu_sub && src_active) { say("CONFIRM first definition after the subscription, repeated with its update (gen=%u)", gen); emit(1); }
}
static void forget_sent(void) { int i; for (i = 0; i < NMAN; i++) cur.m[i].sent = 0; for (i = 0; i < NLEV; i++) cur.l[i].sent = 0; sent5201 = 0; }
/* ---------- P2: link loss, recovery pacing, start-up clean ---------- */
static long retry_cap = CAPTURE_RETRY_MS, retry_cur = CAPTURE_RETRY_MS, last_try;
static int opt_startup = 1;          /* --startup-clean=state0 (1) | flush (2) | off (0) */
static int startup_done;
/* P8: a receiver can still hold a definition from an earlier writer (or from our own flush); it then draws THAT for the first
 * maneuver it is given (seen on the VW MIB4, car session 2026-10-12, probe 1). A definition repeated together with an active
 * update does replace the picture (video 3, case C1). So the first definition sent after every subscription is sent once
 * more, with its update, opt_confirm_ms later. 0 = off. */
static volatile sig_atomic_t g_stop;
static void on_sig(int s) { (void)s; g_stop = 1; }
static void link_lost(const char *why) {
    if (tx_fd >= 0) { close(tx_fd); tx_fd = -1; }
    if (!hu_sub) return;
    hu_sub = 0; forget_sent(); confirm_at = -1;      /* the next subscription replays the whole current picture */
    retry_cur = retry_cap / 15 > 10 ? retry_cap / 15 : 10; last_try = now_ms();   /* look again soon (2 s on a device), then back off */
    say("HU_LINK_LOST (%s); sending stops until the head unit's 0x5200 has been read again; source state kept", why);
}
/* What a freshly started engine does not know: whether an earlier writer died between a definition and its update.
 * state0 = say "no route" once (true in every case). flush = additionally use up a definition left pending on receivers
 * that hold one until the next active update (seen on the VW MIB4, video 3): definition + active update without a list + no route. */
static void startup_clean(unsigned comp) {
    msg_t m;
    if (opt_startup == 2) {
        begin(&m, 0x5202); tlv16(&m, 0x00, comp); tlv16(&m, 0x01, 0); tlv8(&m, 0x03, 0); end(&m);
        if (tx(&m) != 0) return;
        begin(&m, 0x5201); tlv16(&m, 0x00, comp); tlv8(&m, 0x01, 1); tlv16(&m, 0x0e, 1); tlv8(&m, 0x0f, 1); end(&m);
        if (tx(&m) != 0) return;
    }
    build_stop(&m, comp);
    if (tx(&m) == 0) say("STARTUP_CLEAN %s done", opt_startup == 2 ? "flush" : "state0");
}
static void route_over(const char *why) {
    msg_t m;
    if (hu_sub && src_active) { build_stop(&m, hu_comp); tx(&m); }
    say("ROUTE_OVER %s gen=%u", why, gen);
    route_reset(&cur); src_active = 0; staging = 0; pending_clear_at = -1; sent5201 = 0;
    if (confirm_at >= 0) { confirm_at = -1; confirm_armed = 1; }          /* the route ended before its confirmation: confirm the next one */
}

/* ---------- event parsing ---------- */
static int hexbytes(const char *s, uint8_t *out, int cap) {
    int n = 0;
    while (*s) {
        unsigned v;
        if (isspace((unsigned char)*s)) { s++; continue; }
        if (!isxdigit((unsigned char)s[0]) || !isxdigit((unsigned char)s[1]) || n >= cap) return -1;
        sscanf(s, "%2x", &v); out[n++] = (uint8_t)v; s += 2;
    }
    return n;
}
/* whole-message check: header, exact length, id, complete TLV walk. Returns ComponentID or -1 (none), -2 (malformed). */
static int hu_msg_check(const uint8_t *b, int n, unsigned id) {
    int off = 6, comp = -1;
    chk_src = chk_srcrg = chk_exit = 0;
    if (n < 6 || b[0] != 0x40 || b[1] != 0x40 || ((b[2] << 8) | b[3]) != n || (unsigned)((b[4] << 8) | b[5]) != id) return -2;
    while (off < n) {
        int tl, tid;
        if (n - off < 4) return -2;
        tl = (b[off] << 8) | b[off + 1]; tid = (b[off + 2] << 8) | b[off + 3];
        if (tl < 4 || tl > n - off) return -2;
        if (tid == 0) { if (tl != 6) return -2; comp = (b[off + 4] << 8) | b[off + 5]; }   /* unknown ids: ignored */
        else if (tid == 1) chk_src = 1; else if (tid == 2) chk_srcrg = 1; else if (tid == 3) chk_exit = 1;   /* X16: presence requests */
        off += tl;
    }
    return comp;
}
static int csv16(const char *v, int16_t *out, int cap) {
    int n = 0; char *e;
    while (*v) { long x = strtol(v, &e, 10); if (e == v || n >= cap || x < -32768 || x > 65535) return -1; out[n++] = (int16_t)x; v = (*e == ',') ? e + 1 : e; if (*e && *e != ',') return -1; }
    return n;
}
static int num(const char *v, long lo, long hi, long *out) { char *e; long x = strtol(v, &e, 10); if (e == v || *e || x < lo || x > hi) return -1; *out = x; return 0; }
/* X12: copy text into a fixed buffer without cutting a multi-byte UTF-8 character (snprintf cut at the byte limit) */
static int hexv(int c) { return c >= '0' && c <= '9' ? c - '0' : c >= 'a' && c <= 'f' ? c - 'a' + 10 : c >= 'A' && c <= 'F' ? c - 'A' + 10 : -1; }
/* B8: restores the three escapes of the event line in place (the result is never longer). Anything else, including a
 * backslash that starts no known escape, is kept byte for byte; \x00 is dropped because it would end the iAP2 string. */
static void unescape(char *v) {
    char *o = v;
    for (; *v; v++) {
        if (v[0] == '\\' && v[1] == '\\') { *o++ = '\\'; v++; }
        else if (v[0] == '\\' && v[1] == 'p') { *o++ = '|'; v++; }
        else if (v[0] == '\\' && v[1] == 'x' && hexv((unsigned char)v[2]) >= 0 && hexv((unsigned char)v[3]) >= 0) {
            int c = hexv((unsigned char)v[2]) * 16 + hexv((unsigned char)v[3]); if (c) *o++ = (char)c; v += 3; }
        else *o++ = *v;
    }
    *o = 0;
}
static void cp_utf8(char *dst, size_t cap, const char *v0) {
    char *v = (char *)v0; size_t n;
    if (opt_text_escaped) unescape(v);
    n = strlen(v);
    if (n >= cap) { n = cap - 1; while (n > 0 && ((unsigned char)v[n] & 0xc0) == 0x80) n--; }
    memcpy(dst, v, n); dst[n] = 0;
}
#define CP(dst, v) cp_utf8(dst, sizeof(dst), v)

static int ev_man(route_t *r, char **kv, int n) {
    man_t *a = 0; int i; long x;
    for (i = 0; i < n; i++) if (strncmp(kv[i], "idx=", 4) == 0) { if (num(kv[i] + 4, 0, 65535, &x)) return -1; a = find_man(r, (unsigned)x, 1); }
    if (!a) return -1;
    for (i = 0; i < n; i++) {
        char *k = kv[i], *v = strchr(k, '='); if (!v) return -1; *v++ = 0;
        if (!strcmp(k, "idx")) ;
        else if (!strcmp(k, "type")) { if ((a->type = name_in(v, MT, 54)) < 0) return -1; }
        else if (!strcmp(k, "desc")) CP(a->desc, v);
        else if (!strcmp(k, "after")) CP(a->after, v);
        else if (!strcmp(k, "dist")) { if (num(v, 0, 0x7fffffff, &x)) return -1; a->dist = (uint32_t)x; a->has_dist = 1; }
        else if (!strcmp(k, "dstr")) CP(a->dstr, v);
        else if (!strcmp(k, "units")) { if ((a->units = units_of(v)) < 0) return -1; }
        else if (!strcmp(k, "side")) { if (!strcmp(v, "right")) a->side = 0; else if (!strcmp(v, "left")) a->side = 1; else if (!strcmp(v, "none")) a->side = -1; else return -1; }
        else if (!strcmp(k, "jtype")) { if (num(v, 0, 255, &x)) return -1; a->jtype = (int)x; }
        else if (!strcmp(k, "angles")) { if ((a->nang = csv16(v, a->ang, NANG)) < 0) return -1; }
        else if (!strcmp(k, "exit")) { if (num(v, -32768, 32767, &x)) return -1; a->exitang = (int16_t)x; a->has_exit = 1; }
        else if (!strcmp(k, "lane")) { if (num(v, 0, 65535, &x)) return -1; a->lane = (int)x; }
        else if (!strcmp(k, "exitinfo")) CP(a->exitinfo, v);
        else return -1;
    }
    return 0;
}
static int ev_lane(route_t *r, char **kv, int n) {
    lev_t *e = 0; int i; long x;
    for (i = 0; i < n; i++) if (strncmp(kv[i], "idx=", 4) == 0) { if (num(kv[i] + 4, 0, 65535, &x)) return -1; e = find_lev(r, (unsigned)x, 1); }
    if (!e) return -1;
    e->nl = 0; e->desc[0] = 0;
    for (i = 0; i < n; i++) {
        char *k = kv[i], *v = strchr(k, '='); if (!v) return -1; *v++ = 0;
        if (!strcmp(k, "idx")) ;
        else if (!strcmp(k, "desc")) CP(e->desc, v);
        else if (!strcmp(k, "l")) {
            lane_t *l; char *a = strchr(v, ':'), *h = 0;
            if (e->nl >= NLANE || !a) return -1;
            l = &e->l[e->nl]; memset(l, 0, sizeof(*l)); *a++ = 0;
            if ((h = strchr(a, ':'))) *h++ = 0;
            if ((l->status = lstatus_of(v)) < 0) return -1;
            if ((l->nang = csv16(a, l->ang, NANG)) < 0) return -1;
            if (h && *h) { if (num(h, -32768, 32767, &x)) return -1; l->hl = (int16_t)x; l->has_hl = 1; }
            e->nl++;
        } else return -1;
    }
    return e->nl > 0 ? 0 : -1;
}
static int ev_trip(route_t *r, char **kv, int n) {
    trip_t *t = &r->t; int i; long x; int16_t tmp[NCUR];
    for (i = 0; i < n; i++) {
        char *k = kv[i], *v = strchr(k, '='); if (!v) return -1; *v++ = 0;
        if (!strcmp(k, "state")) { if ((t->state = state_of(v)) < 0) return -1; }
        else if (!strcmp(k, "mstate")) { if (num(v, 0, 255, &x)) return -1; t->mstate = (int)x; }
        else if (!strcmp(k, "road")) CP(t->road, v);
        else if (!strcmp(k, "dest")) CP(t->dest, v);
        else if (!strcmp(k, "src")) CP(t->src, v);
        else if (!strcmp(k, "eta")) { t->eta = strtoull(v, 0, 10); t->has_eta = 1; }
        else if (!strcmp(k, "trem")) { t->trem = strtoull(v, 0, 10); t->has_trem = 1; }
        else if (!strcmp(k, "drem")) { if (num(v, 0, 0x7fffffff, &x)) return -1; t->drem = (uint32_t)x; t->has_drem = 1; }
        else if (!strcmp(k, "drstr")) CP(t->drstr, v);
        else if (!strcmp(k, "drunits")) { if (!strcmp(v, "none")) t->drunits = -1; else if ((t->drunits = units_of(v)) < 0) return -1; }
        else if (!strcmp(k, "dnext")) { if (num(v, 0, 0x7fffffff, &x)) return -1; t->dnext = (uint32_t)x; t->has_dnext = 1; }
        else if (!strcmp(k, "dnstr")) CP(t->dnstr, v);
        else if (!strcmp(k, "dnunits")) { if (!strcmp(v, "none")) t->dnunits = -1; else if ((t->dnunits = units_of(v)) < 0) return -1; }
        else if (!strcmp(k, "cur")) { int j, c = csv16(v, tmp, NCUR); if (c < 0) return -1; t->ncur = c; for (j = 0; j < c; j++) t->cur[j] = (uint16_t)tmp[j]; }
        else if (!strcmp(k, "lanecur")) { if (!strcmp(v, "none")) t->lanecur = -1; else { if (num(v, 0, 65535, &x)) return -1; t->lanecur = (int)x; } }
        else if (!strcmp(k, "laneshow")) t->laneshow = atoi(v) != 0;
        else if (!strcmp(k, "visible")) t->visible = atoi(v) != 0;
        else if (!strcmp(k, "mcount")) { if (num(v, 0, 65535, &x)) return -1; t->mcount = (int)x; }
        else if (!strcmp(k, "lanetot")) { if (num(v, 0, 65535, &x)) return -1; t->lanetot = (int)x; }
        else return -1;
    }
    return 0;
}
static int stage_valid(const route_t *r, char *why, size_t cap) {
    msg_t m; int i;
    for (i = 0; i < r->t.ncur; i++) if (!find_man((route_t *)r, r->t.cur[i], 0)) { snprintf(why, cap, "current maneuver %u not in cache", r->t.cur[i]); return 0; }
    if (r->t.laneshow && (r->t.lanecur < 0 || !find_lev((route_t *)r, (unsigned)r->t.lanecur, 0))) { snprintf(why, cap, "lane guidance shown but lane event missing"); return 0; }
    if (r->t.lanecur >= 0 && !find_lev((route_t *)r, (unsigned)r->t.lanecur, 0)) { snprintf(why, cap, "lane event %d not in cache", r->t.lanecur); return 0; }
    for (i = 0; i < NMAN; i++) if (r->m[i].used) {
        if (r->m[i].lane >= 0 && !find_lev((route_t *)r, (unsigned)r->m[i].lane, 0)) { snprintf(why, cap, "maneuver %u links missing lane event %d", r->m[i].idx, r->m[i].lane); return 0; }
        build_5202(&m, 0, &r->m[i]); if (m.bad || m.n + 1 >= 2048) { snprintf(why, cap, "maneuver %u too large", r->m[i].idx); return 0; }
    }
    for (i = 0; i < NLEV; i++) if (r->l[i].used) { build_5204(&m, 0, &r->l[i]); if (m.bad || m.n + 1 >= 2048) { snprintf(why, cap, "lane event %u too large", r->l[i].idx); return 0; } }
    build_5201(&m, 0, r); if (m.bad || m.n + 1 >= 2048) { snprintf(why, cap, "route update too large"); return 0; }
    return 1;
}
static void begin_stage(int fresh) {
    if (staging && !fresh) return;
    if (fresh) route_reset(&stage); else stage = cur;
    staging = 1; stage_new = fresh;
}
static void subscribe(unsigned comp) {
    hu_sub = 1; hu_comp = comp; hu_gen++;
    forget_sent();
    say("HU_SUBSCRIBED comp=0x%04X hu_gen=%u", comp, hu_gen);
    confirm_armed = opt_confirm_ms > 0; confirm_at = -1;
    if (!mode_fixture && !mode_dry && opt_startup && !startup_done) { startup_clean(comp); startup_done = hu_sub; }   /* first subscription of this process; repeated if it failed */
    if (src_active && hu_sub) { say("REPLAY full snapshot gen=%u", gen); emit(1); }
}
static int from_capture;   /* set only while a message read from the live HU is being handled */
static void handle(char *line) {
    char *kv[64]; int n = 0; char *p, *cmd; char why[96];
    line[strcspn(line, "\r\n")] = 0;
    if (!line[0] || line[0] == '#') return;
    /* on the live socket a subscription may only come from the HU itself, never from the event input */
    if (!mode_fixture && !mode_dry && !from_capture && strncmp(line, "HU_", 3) == 0) { n_reject++; say("REJECT simulated HU event on the live transport"); return; }
    cmd = line;
    for (p = strchr(line, '|'); p && n < 64; p = strchr(p, '|')) { *p++ = 0; kv[n++] = p; }
    if (!strcmp(cmd, "TICK")) { clock_ms += n ? atol(kv[0]) : 0; }
    else if (!strcmp(cmd, "CAPS")) {
        int i; for (i = 0; i < n; i++) { char *v = strchr(kv[i], '='); int x; if (!v) continue; *v++ = 0; x = atoi(v);
            if (!strcmp(kv[i], "road")) caps.road = x; else if (!strcmp(kv[i], "dest")) caps.dest = x; else if (!strcmp(kv[i], "after")) caps.after = x;
            else if (!strcmp(kv[i], "desc")) caps.desc = x; else if (!strcmp(kv[i], "mancap")) caps.mancap = x; else if (!strcmp(kv[i], "lanedesc")) caps.lanedesc = x;
            else if (!strcmp(kv[i], "lanecap")) caps.lanecap = x; }
    }
    else if (!strcmp(cmd, "ROUTE_BEGIN")) begin_stage(1);
    else if (!strcmp(cmd, "MAN") || !strcmp(cmd, "LANE") || !strcmp(cmd, "TRIP")) {
        int rc;
        begin_stage(0);
        rc = !strcmp(cmd, "MAN") ? ev_man(&stage, kv, n) : !strcmp(cmd, "LANE") ? ev_lane(&stage, kv, n) : ev_trip(&stage, kv, n);
        if (rc != 0) { staging = 0; n_reject++; say("REJECT malformed %s event; staged changes discarded", cmd); }
    }
    else if (!strcmp(cmd, "COMMIT")) {
        if (!staging) { say("COMMIT nothing staged"); return; }
        staging = 0;
        if (!stage_valid(&stage, why, sizeof(why))) { n_reject++; say("REJECT commit: %s; previous state kept", why); return; }
        if (stage.t.state == ST_NONE) stage.t.state = ST_ROUTE_SET;
        if (stage_new || !src_active) { gen++; say("ROUTE_GENERATION %u (%d maneuvers, %d lane events)", gen, count_man(&stage), count_lev(&stage)); }
        cur = stage;
        if (stage_new) forget_sent();
        src_active = 1; pending_clear_at = -1;
        emit(0);
    }
    else if (!strcmp(cmd, "STATE")) {
        int s = n ? state_of(kv[0]) : -1;
        if (s < 0) { n_reject++; say("REJECT unknown state"); return; }
        if (s == ST_NONE) {
            if (src_active && pending_clear_at < 0) { pending_clear_at = now_ms() + REROUTE_DEBOUNCE_MS; say("PENDING_CLEAR source inactive, waiting %d ms", REROUTE_DEBOUNCE_MS); }
        } else if (src_active) {
            if (pending_clear_at >= 0) { pending_clear_at = -1; say("PENDING_CLEAR cancelled (source %s)", kv[0]); }
            cur.t.state = s; emit(0);
        } else say("IGNORED state %s without a committed route", kv[0]);
    }
    else if (!strcmp(cmd, "ROUTE_END")) { if (src_active) route_over("source ended"); }
    else if (!strcmp(cmd, "HU_5200") || !strcmp(cmd, "HU_5203")) {
        uint8_t b[512]; int len = n ? hexbytes(kv[0], b, sizeof(b)) : -1, c;
        unsigned id = !strcmp(cmd, "HU_5200") ? 0x5200 : 0x5203;
        c = len < 0 ? -2 : hu_msg_check(b, len, id);
        if (c == -2 || (id == 0x5200 && c < 0)) { n_reject++; say("REJECT malformed 0x%04X from HU; subscription unchanged", id); return; }
        if (id == 0x5200) { req_src = chk_src; req_srcrg = chk_srcrg; req_exit = chk_exit; subscribe((unsigned)c); }
        else if (c >= 0 && hu_sub && (unsigned)c != hu_comp) say("IGNORED 0x5203 for other component 0x%04X", (unsigned)c);
        else { hu_sub = 0; forget_sent(); say("HU_UNSUBSCRIBED (0x5203); sending stops, source state kept"); }
    }
    else if (!strcmp(cmd, "HU_DISCONNECT")) { hu_sub = 0; forget_sent(); if (tx_fd >= 0) { close(tx_fd); tx_fd = -1; } say("HU_DISCONNECTED; sending stops, source state kept"); }
    else { n_reject++; say("REJECT unknown event %s", cmd); }
    if (pending_clear_at >= 0 && now_ms() >= pending_clear_at) route_over("source inactive past debounce");
    confirm_due();
}

/* ---------- live: read the HU's cached 0x5200 through a short pass-mode window (same method as otto_navbridge) ---------- */
static int rd_n(int fd, uint8_t *p, size_t n, long deadline) {
    while (n) {
        struct timeval tv; long left = deadline - now_ms(); fd_set r; ssize_t g;
        if (left <= 0) return -1;
        FD_ZERO(&r); FD_SET(fd, &r); tv.tv_sec = left / 1000; tv.tv_usec = (left % 1000) * 1000;
        if (select(fd + 1, &r, 0, 0, &tv) <= 0) return -1;
        g = read(fd, p, n); if (g <= 0) return -1; p += g; n -= (size_t)g;
    }
    return 0;
}
static int capture_5200(uint8_t *out, int cap) {
    static const uint8_t ON[8] = { 1, 0, 0, 0, 0, 0, 0, 0 }, OFF[8] = { 0, 0, 0, 0, 0, 0, 0, 0 };
    uint8_t h[8], buf[2048]; int fd = connect_iap(), got = -1, i; long dl;
    if (fd < 0) return -1;
    dl = now_ms() + 3000;
    for (i = 0; i < 2; i++) {                                   /* greeting: 0x0B len 1, 0x0C len 4 */
        uint32_t len;
        if (rd_n(fd, h, 8, dl) != 0) { close(fd); return -1; }
        len = h[4] | (h[5] << 8) | (h[6] << 16) | ((uint32_t)h[7] << 24);
        if (len > sizeof(buf) || rd_n(fd, buf, len, dl) != 0) { close(fd); return -1; }
    }
    if (write_all(fd, ON, 8) == 0) {
        dl = now_ms() + CAPTURE_WINDOW_MS;
        while (rd_n(fd, h, 8, dl) == 0) {
            uint32_t cmd = h[0] | (h[1] << 8), len = h[4] | (h[5] << 8) | (h[6] << 16) | ((uint32_t)h[7] << 24);
            const uint8_t *m = buf; int ml;
            if (len > sizeof(buf) || rd_n(fd, buf, len, dl) != 0) break;
            if (cmd != 0x0a || len < 12) continue;
            ml = (int)len; if (buf[0] == 0x00 && buf[1] == 0x40) { m = buf + 1; ml--; }
            if (ml >= 12 && ml <= cap && m[0] == 0x40 && m[1] == 0x40 && m[4] == 0x52 && m[5] == 0x00) { memcpy(out, m, (size_t)ml); got = ml; break; }
        }
    }
    (void)write_all(fd, OFF, 8);
    shutdown(fd, SHUT_RDWR); close(fd);
    return got;
}

/* P2: line input for run mode. A blocking stdio read is not reliably interrupted by a stop signal, so the engine waits with
 * poll() and looks at the stop flag twice a second. Same result as fgets(): one line including its '\n', or the first cap-1
 * bytes of a longer one; 0 at end of input or when a stop was requested. */
static int read_line(char *out, int cap) {
    static char buf[32768]; static int have, eof; int i;
    for (;;) {
        for (i = 0; i < have && i < cap - 1; i++) if (buf[i] == '\n') { i++; break; }
        if ((i > 0 && buf[i - 1] == '\n') || i == cap - 1 || (eof && have > 0)) {
            if (eof && !(i > 0 && buf[i - 1] == '\n') && i < cap - 1) i = have < cap - 1 ? have : cap - 1;
            memcpy(out, buf, (size_t)i); out[i] = 0; memmove(buf, buf + i, (size_t)(have - i)); have -= i; return 1;
        }
        if (eof || g_stop) return 0;
        { struct pollfd pf; ssize_t r; pf.fd = 0; pf.events = POLLIN; pf.revents = 0;
          if (poll(&pf, 1, 500) <= 0) return 2;        /* P3: nothing from the source for half a second (2) - let the caller do its timed work */
          r = read(0, buf + have, sizeof(buf) - (size_t)have);
          if (r < 0) { if (errno == EINTR || errno == EAGAIN) continue; eof = 1; }
          else if (r == 0) eof = 1; else have += (int)r; }
    }
}
int main(int argc, char **argv) {
    static char line[16384]; int linecap = sizeof(line);   /* 0.5: escaped text can be up to four times its length */
    if (getenv("OTTO_CONV_COMPAT") && !strcmp(getenv("OTTO_CONV_COMPAT"), "0.3")) { opt_text_escaped = 0; linecap = 4096; }   /* regression runs only: candidate-0.3 behaviour */
    route_reset(&cur);
    if (argc >= 2 && !strcmp(argv[1], "run")) { int k; mode_fixture = 0; for (k = 2; k < argc; k++) if (!strcmp(argv[k], "--dry")) mode_dry = 1; }   /* P5: --dry anywhere */
    else if (argc < 2 || strcmp(argv[1], "fixture")) { fprintf(stderr, "usage: otto_rgid fixture | run [--dry]   [--requests=honor|ignore] [--angles=repeat|packed]   (events on stdin)\n"); return 2; }
    { int ai; for (ai = 2; ai < argc; ai++) {
        if (!strcmp(argv[ai], "--requests=ignore")) opt_requests_honor = 0; else if (!strcmp(argv[ai], "--requests=honor")) opt_requests_honor = 1;
        else if (!strcmp(argv[ai], "--text=raw")) opt_text_escaped = 0; else if (!strcmp(argv[ai], "--text=escaped")) opt_text_escaped = 1;
        else if (!strcmp(argv[ai], "--angles=packed")) opt_angles_repeat = 0; else if (!strcmp(argv[ai], "--angles=repeat")) opt_angles_repeat = 1;
        else if (!strcmp(argv[ai], "--log=quiet")) opt_quiet = 1; else if (!strcmp(argv[ai], "--log=full")) opt_quiet = 0;
        else if (!strcmp(argv[ai], "--startup-clean=state0")) opt_startup = 1; else if (!strcmp(argv[ai], "--startup-clean=flush")) opt_startup = 2;
        else if (!strcmp(argv[ai], "--startup-clean=off")) opt_startup = 0;
        else if (!strncmp(argv[ai], "--confirm-first=", 16) && atol(argv[ai] + 16) >= 100 && atol(argv[ai] + 16) <= 5000) opt_confirm_ms = atol(argv[ai] + 16);
#if defined(OTTO_TEST_ENDPOINT) && !defined(OTTO_OFFLINE_NO_SOCKET)
        else if (!strncmp(argv[ai], "--endpoint=nr.test.", 19) && argv[ai][19]) endpoint_name = argv[ai] + 11;
        else if (!strncmp(argv[ai], "--capture-retry-ms=", 19) && atol(argv[ai] + 19) >= 50) retry_cap = atol(argv[ai] + 19);
#endif
        else if (strcmp(argv[ai], "--dry")) { fprintf(stderr, "unknown option %s\n", argv[ai]); return 2; } } }
#if defined(OTTO_TEST_ENDPOINT) && !defined(OTTO_OFFLINE_NO_SOCKET)
    if (!mode_fixture && !mode_dry && !endpoint_name) { fprintf(stderr, "test build: --endpoint=nr.test.<name> is required; no other endpoint can be reached\n"); return 3; }
#endif
    retry_cur = retry_cap; last_try = -retry_cap;
    if (!mode_fixture) {             /* a vanished peer must end in an error return, not in a killed process; a stop request must end with a route end */
        struct sigaction sa; memset(&sa, 0, sizeof(sa)); sa.sa_handler = on_sig;   /* no SA_RESTART: the blocking read returns */
        signal(SIGPIPE, SIG_IGN); sigaction(SIGTERM, &sa, 0); sigaction(SIGINT, &sa, 0); sigaction(SIGHUP, &sa, 0);
    }
    for (;;) {
        int got = g_stop ? 0 : mode_fixture ? fgets(line, linecap, stdin) != 0 : read_line(line, linecap);
        if (!got) break;
        if (mode_fixture && line[0] == '#') { fputs(line, stdout); continue; }
        if (got == 1) handle(line);
        /* P3: timed work also runs while the source is silent. Android Auto sends nothing more after "inactive", so the
         * route end that follows the debounce must not wait for a next message. */
        else { if (pending_clear_at >= 0 && now_ms() >= pending_clear_at) route_over("source inactive past debounce"); confirm_due(); }
        /* P2: --dry opens no socket at all. Never between an event and its COMMIT: the replay would be followed by the same
         * definition a second time, because the staged copy does not know it was just sent. */
        if (!mode_fixture && !mode_dry && src_active && !hu_sub && !staging && now_ms() - last_try >= retry_cur) {
            uint8_t b[512]; char ev[1100] = "HU_5200|"; int n, i;
            last_try = now_ms();
            n = capture_5200(b, sizeof(b));
            if (n > 0) { retry_cur = retry_cap; for (i = 0; i < n; i++) sprintf(ev + 8 + 2 * i, "%02X", b[i]); from_capture = 1; handle(ev); from_capture = 0; }
            else { say("CAPTURE no 0x5200 from the HU (no CarPlay session?)"); retry_cur = retry_cur * 2 > retry_cap ? retry_cap : retry_cur * 2; }
        }
    }
    if (!mode_fixture && src_active) route_over(g_stop ? "stop requested" : "engine exiting");
    say("SUMMARY tx=%lu dropped=%lu rejected=%lu", n_tx, n_drop, n_reject);
    return 0;
}
