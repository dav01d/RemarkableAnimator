// Wi-Fi share: serves one exported file over HTTP, so a phone on the same Wi-Fi can fetch it
// without a cloud upload. It runs inside the pen backend's poll loop, so nothing here blocks:
// every socket is non-blocking and each wake-up does at most one small recv or send per client.
// Only GET/HEAD of the shared file's name is answered; anything else gets a 404.

#include "share.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#define MAX_FILE_BYTES (64 << 20)
#define CLIENT_TIMEOUT_MS 15000 // drop a phone that stops talking, to free its slot
#define SEND_CHUNK (64 << 10)   // per send, so one wake-up never copies much (the pen waits)

struct client {
    int fd;                     // -1: free slot
    long seen;                  // last activity
    char req[1024];
    size_t got;
    char head[512];             // response headers, once the request is in
    size_t head_len, body_len, sent;
};

static int listener = -1;
static char *file;
static size_t file_len;
static char name[128], type[96];
static long deadline;
static struct client clients[SHARE_CLIENTS];

static void drop(struct client *c) {
    close(c->fd);
    c->fd = -1;
}

static void stop(void) {
    for (int i = 0; i < SHARE_CLIENTS; i++) if (clients[i].fd >= 0) drop(&clients[i]);
    if (listener >= 0) close(listener);
    listener = -1;
    free(file);
    file = NULL;
}

// The tablet's Wi-Fi IPv4: the first up, non-loopback interface that isn't USB networking
static int wifi_ip(char *ip, size_t size) {
    struct ifaddrs *list, *a;
    int found = -1;
    if (getifaddrs(&list) < 0) return -1;
    for (a = list; a && found < 0; a = a->ifa_next) {
        if (!a->ifa_addr || a->ifa_addr->sa_family != AF_INET) continue;
        if (!(a->ifa_flags & IFF_UP) || (a->ifa_flags & IFF_LOOPBACK) || !strncmp(a->ifa_name, "usb", 3)) continue;
        if (inet_ntop(AF_INET, &((struct sockaddr_in *)a->ifa_addr)->sin_addr, ip, size)) found = 0;
    }
    freeifaddrs(list);
    return found;
}

static int open_listener(void) {
    int fd = socket(AF_INET, SOCK_STREAM, 0), one = 1;
    struct sockaddr_in addr = { .sin_family = AF_INET, .sin_port = htons(SHARE_PORT),
                                .sin_addr.s_addr = htonl(INADDR_ANY) };
    if (fd < 0) return -1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, (void *)&one, sizeof one);
    if (bind(fd, (struct sockaddr *)&addr, sizeof addr) < 0 || listen(fd, 8) < 0
        || fcntl(fd, F_SETFL, O_NONBLOCK) < 0) { close(fd); return -1; }
    return fd;
}

static char *read_file(const char *path, size_t *len) {
    FILE *f = fopen(path, "rb");
    char *data = NULL;
    long n;
    if (!f) return NULL;
    if (!fseek(f, 0, SEEK_END) && (n = ftell(f)) >= 0 && n <= MAX_FILE_BYTES && !fseek(f, 0, SEEK_SET)
        && (data = malloc(n ? n : 1)) && fread(data, 1, n, f) != (size_t)n) { free(data); data = NULL; }
    fclose(f);
    *len = data ? (size_t)n : 0;
    return data;
}

int share_start(const char *path, const char *mime, long now, char *reply, size_t size) {
    char ip[INET_ADDRSTRLEN];
    const char *base = strrchr(path, '/');
    base = base ? base + 1 : path;
    if (wifi_ip(ip, sizeof ip) < 0) return snprintf(reply, size, "Connect the tablet to Wi-Fi first"), -1;

    size_t len;
    char *data = read_file(path, &len);
    if (!data) return snprintf(reply, size, "Couldn't read %s", base), -1;
    if (listener < 0) {
        for (int i = 0; i < SHARE_CLIENTS; i++) clients[i].fd = -1;
        if ((listener = open_listener()) < 0) {
            free(data);
            return snprintf(reply, size, "Couldn't open port %d: %s", SHARE_PORT, strerror(errno)), -1;
        }
    }
    for (int i = 0; i < SHARE_CLIENTS; i++) if (clients[i].fd >= 0) drop(&clients[i]); // they point into the old file
    free(file);
    file = data;
    file_len = len;
    snprintf(name, sizeof name, "%s", base);
    snprintf(type, sizeof type, "%s", mime);
    deadline = now + SHARE_TIMEOUT_MS;
    snprintf(reply, size, "http://%s:%d/%s", ip, SHARE_PORT, name);
    return 0;
}

int share_fds(struct pollfd *fds) {
    int n = 0, busy = 0;
    if (listener < 0) return 0;
    for (int i = 0; i < SHARE_CLIENTS; i++) {
        if (clients[i].fd < 0) continue;
        fds[n++] = (struct pollfd){ clients[i].fd, clients[i].head_len ? POLLOUT : POLLIN, 0 };
        busy++;
    }
    if (busy < SHARE_CLIENTS) fds[n++] = (struct pollfd){ listener, POLLIN, 0 }; // full: let them queue
    return n;
}

int share_timeout(long now) {
    if (listener < 0) return -1;
    long next = deadline;
    for (int i = 0; i < SHARE_CLIENTS; i++)
        if (clients[i].fd >= 0 && clients[i].seen + CLIENT_TIMEOUT_MS < next) next = clients[i].seen + CLIENT_TIMEOUT_MS;
    return next > now ? (int)(next - now) : 0;
}

// The request is in: answer GET/HEAD /<name> with the file, anything else with a 404
static void respond(struct client *c) {
    char method[8] = "", target[256] = "";
    sscanf(c->req, "%7s %255s", method, target);
    char *query = strchr(target, '?');
    if (query) *query = 0;
    int head_only = !strcmp(method, "HEAD");
    int found = (head_only || !strcmp(method, "GET")) && target[0] == '/' && !strcmp(target + 1, name);
    c->body_len = found ? file_len : 0;
    c->head_len = snprintf(c->head, sizeof c->head, found
        ? "HTTP/1.0 200 OK\r\nContent-Type: %s\r\nContent-Length: %zu\r\n"
          "Content-Disposition: inline; filename=\"%s\"\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        : "HTTP/1.0 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        type, file_len, name);
    if (head_only) c->body_len = 0;
}

static void serve(struct client *c, short revents, long now) {
    if (revents & (POLLERR | POLLNVAL)) { drop(c); return; }
    if (!c->head_len) { // still reading the request
        ssize_t n = recv(c->fd, c->req + c->got, sizeof c->req - 1 - c->got, 0);
        if (n <= 0) { drop(c); return; }
        c->got += n;
        c->req[c->got] = 0;
        c->seen = now;
        if (strstr(c->req, "\r\n\r\n") || c->got == sizeof c->req - 1) respond(c);
        return;
    }
    const char *out = c->sent < c->head_len ? c->head + c->sent : file + (c->sent - c->head_len);
    size_t left = c->sent < c->head_len ? c->head_len - c->sent : c->head_len + c->body_len - c->sent;
    ssize_t n = send(c->fd, out, left < SEND_CHUNK ? left : SEND_CHUNK, MSG_NOSIGNAL);
    if (n < 0) { if (errno != EAGAIN && errno != EWOULDBLOCK) drop(c); return; }
    c->sent += n;
    c->seen = now;
    if (c->sent == c->head_len + c->body_len) drop(c);
}

void share_run(const struct pollfd *fds, int n, long now) {
    for (int i = 0; i < n && listener >= 0; i++) {
        if (!fds[i].revents) continue;
        if (fds[i].fd == listener) {
            int fd = accept(listener, NULL, NULL);
            if (fd < 0) continue;
            struct client *c = NULL;
            for (int k = 0; k < SHARE_CLIENTS && !c; k++) if (clients[k].fd < 0) c = &clients[k];
            if (!c || fcntl(fd, F_SETFL, O_NONBLOCK) < 0) { close(fd); continue; }
            *c = (struct client){ .fd = fd, .seen = now };
        } else {
            for (int k = 0; k < SHARE_CLIENTS; k++)
                if (clients[k].fd == fds[i].fd) { serve(&clients[k], fds[i].revents, now); break; }
        }
    }
    if (listener < 0) return;
    if (now >= deadline) { stop(); return; }
    for (int k = 0; k < SHARE_CLIENTS; k++)
        if (clients[k].fd >= 0 && now - clients[k].seen >= CLIENT_TIMEOUT_MS) drop(&clients[k]);
}
