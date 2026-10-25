// Live pen ink and eraser through xochitl's own pen path while Animator arms it
// (reMarkable 2, OS 3.29.0.153 only). Animator rewrites ARM_FILE every second while a drawing
// canvas is up: "on x y w h size eraserTool eraseRadius" (screen px) or "off". A stale file
// (Animator gone) counts as off. Both are only a preview: Animator still draws, erases and keeps
// the real strokes, and draws the rubbed area again when the eraser lifts.
#define _GNU_SOURCE
#include <dirent.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <link.h>
#include <linux/input.h>
#include <poll.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define ARM_FILE "/tmp/animator-ink"
#define ARM_STALE_S 3       // s without a heartbeat from Animator: off
#define ARM_CHECK_MS 200
#define SCREEN_W 1404
#define SCREEN_H 1872
static const unsigned char BUILD_ID[20] = { 0xc1,0xa6,0x69,0x8e,0xc0,0x51,0x2d,0xdd,0x88,0xc2,
                                            0xba,0x5c,0xa7,0x13,0x39,0x09,0x88,0x97,0x80,0x56 };
// xochitl 3.29.0.153 offsets from its load base
#define OFF_FB_INSTANCE    0x164f79c // EPFramebuffer* singleton
#define OFF_UPDATE_BLOCKS  0x81093c  // updateInBlocks(fb**, const QRegion&, waveform, pixelMode, flags, label)
#define FB_IMAGE 0x58                 // QImage, RGB32
#define FB_IMAGE_PTR 0x64             // QImage*, the current image (0 = the one at FB_IMAGE)
#define FB_MASK 0x68                  // QImage, Grayscale8: the pen draws only where this is set
#define WAVE_DU 1
#define PIXEL_PEN 8
#define FLAG_FASTDRAW 2

typedef void (*UpdateFn)(void **fb, const void *region, int waveform, int pixelMode, int flags, const char *label);
typedef void (*RegionCtor)(void *self, int x, int y, int w, int h, int type);
typedef void (*RegionDtor)(void *self);
typedef int (*ImgInt)(const void *img);
typedef const unsigned char *(*ImgBits)(const void *img);

static uintptr_t base;
static int build_ok;
static RegionCtor rctor;
static RegionDtor rdtor;
static ImgInt format, width, height, stride;
static ImgBits bits;

static struct { int on, x, y, w, h, erase; float size, eraseR; } arm;

// Where to draw this stroke: the screen image and the pen mask
static struct { char *fb; uint32_t *px; unsigned char *mk; int ps, ms; } surf;

static int find_main(struct dl_phdr_info *info, size_t size, void *data) {
    (void)size; (void)data;
    base = info->dlpi_addr;
    for (int i = 0; i < info->dlpi_phnum; i++) {
        const ElfW(Phdr) *ph = &info->dlpi_phdr[i];
        if (ph->p_type != PT_NOTE) continue;
        const unsigned char *p = (const unsigned char *)(base + ph->p_vaddr), *end = p + ph->p_memsz;
        while (p + 12 <= end) {
            uint32_t namesz = *(uint32_t *)p, descsz = *(uint32_t *)(p + 4), type = *(uint32_t *)(p + 8);
            const unsigned char *desc = p + 12 + ((namesz + 3) & ~3u);
            if (type == 3 && descsz == 20 && !memcmp(desc, BUILD_ID, 20)) build_ok = 1; // NT_GNU_BUILD_ID
            p = desc + ((descsz + 3) & ~3u);
        }
    }
    return 1; // the first entry is the program itself
}

static long now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000L + ts.tv_nsec / 1000000L;
}

static void read_arm(void) {
    struct stat st;
    char buf[128] = "";
    arm.on = 0;
    if (stat(ARM_FILE, &st) < 0 || time(NULL) - st.st_mtime > ARM_STALE_S) return;
    FILE *f = fopen(ARM_FILE, "r");
    if (!f) return;
    int n = fgets(buf, sizeof buf, f) ? sscanf(buf, "on %d %d %d %d %f %d %f", &arm.x, &arm.y, &arm.w, &arm.h,
                                                 &arm.size, &arm.erase, &arm.eraseR) : 0;
    if (n < 7) { arm.erase = 0; arm.eraseR = 0; } // an older Animator: ink only
    arm.on = n >= 5 && arm.w > 0 && arm.h > 0 && arm.size > 0;
    fclose(f);
}

// Find the screen image and pen mask, and check they are what this build is known to have
static int open_surface(void) {
    char *fb = *(char **)(base + OFF_FB_INSTANCE);
    if (!fb) return 0;
    void *img = *(void **)(fb + FB_IMAGE_PTR);
    if (!img) img = fb + FB_IMAGE;
    void *mask = fb + FB_MASK;
    if (format(img) != 4 || width(img) != SCREEN_W || height(img) != SCREEN_H || format(mask) != 24
        || width(mask) != SCREEN_W || height(mask) != SCREEN_H) {
        fprintf(stderr, "[ink] unexpected screen layout (fmt %d/%d), not drawing\n", format(img), format(mask));
        return 0;
    }
    surf.fb = fb;
    surf.px = (uint32_t *)bits(img);
    surf.mk = (unsigned char *)bits(mask);
    surf.ps = stride(img) / 4;
    surf.ms = stride(mask);
    return 1;
}

static int clampi(int v, int lo, int hi) { return v < lo ? lo : v > hi ? hi : v; }

// Paint a round-ended segment of width w, clipped to the armed canvas; returns its box
static void segment(float x0, float y0, float x1, float y1, float w, uint32_t ink, int box[4]) {
    float r = w / 2 < 0.75f ? 0.75f : w / 2;
    int bx0 = clampi((int)((x0 < x1 ? x0 : x1) - r), arm.x, arm.x + arm.w - 1);
    int by0 = clampi((int)((y0 < y1 ? y0 : y1) - r), arm.y, arm.y + arm.h - 1);
    int bx1 = clampi((int)((x0 > x1 ? x0 : x1) + r + 1), arm.x, arm.x + arm.w - 1);
    int by1 = clampi((int)((y0 > y1 ? y0 : y1) + r + 1), arm.y, arm.y + arm.h - 1);
    float dx = x1 - x0, dy = y1 - y0, len2 = dx * dx + dy * dy;
    for (int y = by0; y <= by1; y++)
        for (int x = bx0; x <= bx1; x++) {
            float px = x + 0.5f - x0, py = y + 0.5f - y0;
            float t = len2 > 0 ? (px * dx + py * dy) / len2 : 0;
            t = t < 0 ? 0 : t > 1 ? 1 : t;
            float ex = px - t * dx, ey = py - t * dy;
            if (ex * ex + ey * ey > r * r) continue;
            surf.px[y * surf.ps + x] = ink;
            surf.mk[y * surf.ms + x] = 0xFF;
        }
    box[0] = bx0; box[1] = by0; box[2] = bx1; box[3] = by1;
}

static void show(const int b[4]) {
    void *region[2] = {0};
    void *fbHolder = surf.fb;
    rctor(region, b[0], b[1], b[2] - b[0] + 1, b[3] - b[1] + 1, 0);
    ((UpdateFn)(base + OFF_UPDATE_BLOCKS))(&fbHolder, region, WAVE_DU, PIXEL_PEN, FLAG_FASTDRAW, " - animator ink");
    rdtor(region);
}

#define HAS_BIT(bits, n) ((bits)[(n) / 8] >> ((n) % 8) & 1)

static int open_pen(void) {
    DIR *dir = opendir("/dev/input");
    struct dirent *e;
    int found = -1;
    while (dir && found < 0 && (e = readdir(dir))) {
        if (strncmp(e->d_name, "event", 5)) continue;
        char path[64];
        unsigned char abs_bits[ABS_MAX / 8 + 1] = {0}, key_bits[KEY_MAX / 8 + 1] = {0};
        snprintf(path, sizeof path, "/dev/input/%s", e->d_name);
        int fd = open(path, O_RDONLY | O_NONBLOCK);
        if (fd < 0) continue;
        ioctl(fd, EVIOCGBIT(EV_ABS, sizeof abs_bits), abs_bits);
        ioctl(fd, EVIOCGBIT(EV_KEY, sizeof key_bits), key_bits);
        if (HAS_BIT(abs_bits, ABS_PRESSURE) && HAS_BIT(key_bits, BTN_TOOL_PEN)) found = fd; else close(fd);
    }
    if (dir) closedir(dir);
    return found;
}

static void *pen_loop(void *arg) {
    (void)arg;
    int pen = open_pen();
    if (pen < 0) { fprintf(stderr, "[ink] pen not found\n"); return NULL; }
    struct input_absinfo ax = {0}, ay = {0}, ap = {0};
    ioctl(pen, EVIOCGABS(ABS_X), &ax);
    ioctl(pen, EVIOCGABS(ABS_Y), &ay);
    ioctl(pen, EVIOCGABS(ABS_PRESSURE), &ap);
    if (ax.maximum <= 0 || ay.maximum <= 0 || ap.maximum <= ap.minimum) { fprintf(stderr, "[ink] odd pen ranges\n"); return NULL; }
    fprintf(stderr, "[ink] ready: pen x 0..%d y 0..%d pressure ..%d\n", ax.maximum, ay.maximum, ap.maximum);

    int rx = 0, ry = 0, rp = 0, touch = 0, rubber = 0;
    int stroke = 0, have_last = 0, sbox[4] = {0}, updates = 0;
    float lx = 0, ly = 0;
    long last_arm = 0, t_stroke = 0, update_us = 0;
    struct pollfd pfd = { pen, POLLIN, 0 };
    for (;;) {
        poll(&pfd, 1, ARM_CHECK_MS);
        long t = now_ms();
        if (!touch && t - last_arm >= ARM_CHECK_MS) { read_arm(); last_arm = t; }
        struct input_event ev[64];
        ssize_t n = read(pen, ev, sizeof ev);
        for (ssize_t i = 0; i < n / (ssize_t)sizeof *ev; i++) {
            struct input_event *e = &ev[i];
            if (e->type == EV_ABS) {
                if (e->code == ABS_X) rx = e->value;
                else if (e->code == ABS_Y) ry = e->value;
                else if (e->code == ABS_PRESSURE) rp = e->value;
            } else if (e->type == EV_KEY) {
                if (e->code == BTN_TOUCH) touch = e->value != 0;
                else if (e->code == BTN_TOOL_RUBBER) rubber = e->value != 0;
            } else if (e->type == EV_SYN && e->code == SYN_REPORT) {
                int erasing = rubber || arm.erase;
                if (touch && arm.on && (!erasing || arm.eraseR > 0)) {
                    if (!stroke) {
                        if (!open_surface()) { arm.on = 0; continue; }
                        stroke = 1; updates = 0; update_us = 0; t_stroke = now_ms();
                        sbox[0] = SCREEN_W; sbox[1] = SCREEN_H; sbox[2] = sbox[3] = 0;
                    }
                    // The panel's portrait frame: x along the digitizer's y, y against its x
                    float sx = ry * (float)SCREEN_W / ay.maximum, sy = (ax.maximum - rx) * (float)SCREEN_H / ax.maximum;
                    if (sx >= arm.x && sx < arm.x + arm.w && sy >= arm.y && sy < arm.y + arm.h) {
                        float p = (rp - ap.minimum) / (float)(ap.maximum - ap.minimum);
                        int b[4];
                        if (erasing) segment(have_last ? lx : sx, have_last ? ly : sy, sx, sy, 2 * arm.eraseR, 0xFFFFFFFFu, b);
                        else segment(have_last ? lx : sx, have_last ? ly : sy, sx, sy, arm.size * (0.3f + 1.4f * (p > 1 ? 1 : p)), 0xFF000000u, b);
                        struct timespec a, z;
                        clock_gettime(CLOCK_MONOTONIC, &a);
                        show(b);
                        clock_gettime(CLOCK_MONOTONIC, &z);
                        update_us += (z.tv_sec - a.tv_sec) * 1000000L + (z.tv_nsec - a.tv_nsec) / 1000;
                        updates++;
                        if (b[0] < sbox[0]) sbox[0] = b[0];
                        if (b[1] < sbox[1]) sbox[1] = b[1];
                        if (b[2] > sbox[2]) sbox[2] = b[2];
                        if (b[3] > sbox[3]) sbox[3] = b[3];
                        lx = sx; ly = sy; have_last = 1;
                    } else have_last = 0;
                } else if (stroke && !touch) {
                    // The mask is the pen's scratch: clear what this stroke marked
                    for (int y = sbox[1]; y <= sbox[3]; y++) memset(surf.mk + y * surf.ms + sbox[0], 0, sbox[2] - sbox[0] + 1);
                    fprintf(stderr, "[ink] stroke: %d updates, %ld us per update call, %ld ms\n",
                            updates, updates ? update_us / updates : 0, now_ms() - t_stroke);
                    stroke = 0; have_last = 0;
                }
            }
        }
    }
    return NULL;
}

void _xovi_construct(void) {
    dl_iterate_phdr(find_main, NULL);
    if (!build_ok) { fprintf(stderr, "[ink] unknown xochitl build, staying off\n"); return; }
    rctor = (RegionCtor)dlsym(RTLD_DEFAULT, "_ZN7QRegionC1EiiiiNS_10RegionTypeE");
    rdtor = (RegionDtor)dlsym(RTLD_DEFAULT, "_ZN7QRegionD1Ev");
    format = (ImgInt)dlsym(RTLD_DEFAULT, "_ZNK6QImage6formatEv");
    width = (ImgInt)dlsym(RTLD_DEFAULT, "_ZNK6QImage5widthEv");
    height = (ImgInt)dlsym(RTLD_DEFAULT, "_ZNK6QImage6heightEv");
    stride = (ImgInt)dlsym(RTLD_DEFAULT, "_ZNK6QImage12bytesPerLineEv");
    bits = (ImgBits)dlsym(RTLD_DEFAULT, "_ZNK6QImage4bitsEv");
    if (!rctor || !rdtor || !format || !width || !height || !stride || !bits) { fprintf(stderr, "[ink] Qt symbols missing, staying off\n"); return; }
    pthread_t t;
    pthread_create(&t, NULL, pen_loop, NULL);
    pthread_detach(t);
}
