// Wi-Fi share: serves the latest export over HTTP on the local network (see share.c)
#pragma once
#include <poll.h>
#include <stddef.h>

#define SHARE_PORT 8765
#define SHARE_CLIENTS 4           // phones fetching at once; more wait in the listen queue
#define SHARE_FDS (1 + SHARE_CLIENTS)
#ifndef SHARE_TIMEOUT_MS
#define SHARE_TIMEOUT_MS (10 * 60 * 1000) // the link stops working after this
#endif

// Serve the file at path (Content-Type type) until SHARE_TIMEOUT_MS from now, replacing any
// earlier one. Writes the link to reply and returns 0, or writes the reason and returns -1.
int share_start(const char *path, const char *type, long now, char *reply, size_t size);
int share_fds(struct pollfd *fds);  // the sockets to poll (at most SHARE_FDS); returns how many
int share_timeout(long now);        // poll timeout in ms until the next deadline, -1 if idle
void share_run(const struct pollfd *fds, int n, long now); // after poll: serve, expire
