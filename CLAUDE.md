# RemarkableAnimator

AppLoad app for the reMarkable Paper Pro Move. Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
first: the tablet's renderer and input behave unlike desktop Qt, and most bugs come from that.

- **Build**: `src/backend/entry` from `backend/pen.c` + `share.c` (zig cc, aarch64-linux-musl, static) and
  `src/resources.rcc` from `src/resources.qrc` (rcc --binary). Rebuild both before deploying.
- **Deploy**: AppLoad caches the app until xochitl restarts, so reopening it runs the old code.
  Close the app, then `deploy.ps1 -Restart`. Don't restart xochitl while the app is open (it can
  crash and reboot the tablet).
- **Test on desktop** with PySide6 under `QT_QUICK_BACKEND=software` (closest to the tablet),
  with stub QML modules for `net.asivery.AppLoad` and `net.asivery.ApploadUtils`.
- **On the tablet**, `journalctl -u xochitl` shows the app's `console.log` output.
- Never block the UI thread for long; xochitl's watchdog kills it after one minute.

If a `private/` folder exists (the maintainer's notes, not part of this repo), read
`private/NOTES.md` too.
