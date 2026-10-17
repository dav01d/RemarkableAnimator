// AppLoad backend: streams the Marker's pressure, tilt and eraser end to the QML frontend.
//
// xochitl hands AppLoad apps the pen as a plain mouse (position only), so this reads the
// pen's evdev device directly. Position still comes from the mouse events in QML; this only
// supplies what the mouse lacks.
//
// Protocol (AppLoad): SOCK_SEQPACKET unix socket at argv[1]; each message is a
// { u32 type; u32 length } header packet followed by a payload packet.
// We send type 1 = "pressure tiltX tiltY eraser touching" (pressure 0..1000, tilt -1000..1000).

#include <dirent.h>
#include <fcntl.h>
#include <linux/input.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#define MSG_PEN 1
#define MSG_TERMINATE 0xFFFFFFFFu
#define MIN_INTERVAL_MS 15
#define MIN_PRESSURE_STEP 15 // of 1000: AppLoad logs every message, so send only real changes

static int send_msg(int fd, uint32_t type, const char *text) {
    if (fd < 0) return printf("%u: %s\n", type, text) < 0 ? -1 : fflush(stdout); // --print mode
    uint32_t header[2] = { type, (uint32_t)strlen(text) };
    if (send(fd, header, sizeof header, 0) < 0) return -1;
    return header[1] ? (int)send(fd, text, header[1], 0) : 0;
}

static int open_pen(void) {
    DIR *dir = opendir("/dev/input");
    struct dirent *e;
    int found = -1;
    while (dir && found < 0 && (e = readdir(dir))) {
        if (strncmp(e->d_name, "event", 5)) continue;
        char path[64], name[128] = "";
        snprintf(path, sizeof path, "/dev/input/%s", e->d_name);
        int fd = open(path, O_RDONLY | O_NONBLOCK);
        if (fd < 0) continue;
        ioctl(fd, EVIOCGNAME(sizeof name), name);
        if (strstr(name, "marker")) found = fd; else close(fd);
    }
    if (dir) closedir(dir);
    return found;
}

static long now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000L + ts.tv_nsec / 1000000L;
}

// Scale a raw axis value to -1000..1000 (or 0..1000 for axes with min 0)
static int norm(int v, const struct input_absinfo *a) {
    if (a->maximum <= a->minimum) return 0;
    if (a->minimum < 0) return (int)(v * 1000L / (a->maximum > -a->minimum ? a->maximum : -a->minimum));
    return (int)((v - a->minimum) * 1000L / (a->maximum - a->minimum));
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s <socket> | --print\n", argv[0]); return 1; }

    // --print: no frontend, write messages to stdout (for testing on the tablet)
    int sock = -1;
    if (strcmp(argv[1], "--print")) {
        sock = socket(AF_UNIX, SOCK_SEQPACKET, 0);
        struct sockaddr_un addr = { .sun_family = AF_UNIX };
        strncpy(addr.sun_path, argv[1], sizeof addr.sun_path - 1);
        if (sock < 0 || connect(sock, (struct sockaddr *)&addr, sizeof addr) < 0) { perror("[pen] connect"); return 1; }
    }

    int pen = open_pen();
    if (pen < 0) { fprintf(stderr, "[pen] marker input device not found\n"); return 1; }

    struct input_absinfo ap = {0}, atx = {0}, aty = {0};
    ioctl(pen, EVIOCGABS(ABS_PRESSURE), &ap);
    ioctl(pen, EVIOCGABS(ABS_TILT_X), &atx);
    ioctl(pen, EVIOCGABS(ABS_TILT_Y), &aty);
    fprintf(stderr, "[pen] streaming: pressure max %d, tilt x %d..%d\n", ap.maximum, atx.minimum, atx.maximum);

    int pressure = 0, tx = 0, ty = 0, eraser = 0, touching = 0;
    int sent_eraser = -1, sent_touching = -1, sent_pressure = -1000, dirty = 0;
    long last_sent = 0;
    struct pollfd fds[2] = { { sock, POLLIN, 0 }, { pen, POLLIN, 0 } }; // fd -1 is ignored by poll

    for (;;) {
        if (poll(fds, 2, -1) < 0) break;

        if (fds[0].revents) { // frontend closed or told us to terminate
            uint32_t header[2];
            char buf[256];
            if (recv(sock, header, sizeof header, 0) <= 0) break;
            if (header[1] && recv(sock, buf, sizeof buf, 0) <= 0) break;
            if (header[0] == MSG_TERMINATE) break;
        }

        if (fds[1].revents & POLLIN) {
            struct input_event ev[64];
            ssize_t n = read(pen, ev, sizeof ev);
            for (ssize_t i = 0; i < n / (ssize_t)sizeof *ev; i++) {
                struct input_event *e = &ev[i];
                if (e->type == EV_ABS) {
                    if (e->code == ABS_PRESSURE) pressure = norm(e->value, &ap);
                    else if (e->code == ABS_TILT_X) tx = norm(e->value, &atx);
                    else if (e->code == ABS_TILT_Y) ty = norm(e->value, &aty);
                    dirty = 1;
                } else if (e->type == EV_KEY) {
                    if (e->code == BTN_TOOL_RUBBER) eraser = e->value != 0;
                    else if (e->code == BTN_TOUCH) touching = e->value != 0;
                    dirty = 1;
                } else if (e->type == EV_SYN && e->code == SYN_REPORT && dirty) {
                    long t = now_ms();
                    // Tool/contact changes go out immediately; pressure only while touching,
                    // when it moved noticeably, at most every 15ms. Hover sends nothing.
                    int changed = eraser != sent_eraser || touching != sent_touching;
                    int pressed = touching && abs(pressure - sent_pressure) >= MIN_PRESSURE_STEP
                                  && t - last_sent >= MIN_INTERVAL_MS;
                    if (changed || pressed) {
                        char msg[64];
                        snprintf(msg, sizeof msg, "%d %d %d %d %d", pressure, tx, ty, eraser, touching);
                        if (send_msg(sock, MSG_PEN, msg) < 0) return 0;
                        sent_eraser = eraser; sent_touching = touching; sent_pressure = pressure;
                        last_sent = t; dirty = 0;
                    }
                }
            }
        }
    }
    return 0;
}
