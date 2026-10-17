# RemarkableAnimator

Flipbook animation **on** the reMarkable Paper Pro Move: draw frames with the Marker, play them
back on the tablet, and share them as a GIF via QR code.

## Features
- Pressure-sensitive pen (3 sizes, black/grey); flip the Marker to erase what you rub over
- Frames with fading onion skin, drag-to-reorder, playback at 6–24 fps
- Undo/redo, rename, a Projects screen; everything autosaves on the tablet (works offline)
- Export the current animation as a GIF, uploaded to [catbox.moe](https://catbox.moe) and
  shared via a QR code (only when you tap Export)

## Requirements
- reMarkable Paper Pro Move, OS 3.28, in Developer Mode (SSH access)
- [XOVI](https://github.com/asivery/xovi) + [AppLoad](https://github.com/asivery/rm-appload)
  (e.g. via the Vellum package manager)

Developer Mode requires a factory reset and modding is at your own risk.

## Install
Copy the contents of `src/` to `/home/root/xovi/exthome/appload/RemarkableAnimator/` on the
tablet, make `backend/entry` executable, and restart xochitl once (`systemctl restart xochitl`).
"Animator" then appears in the AppLoad menu. `deploy.ps1` automates this from Windows.

## Upload target
Exports go to catbox.moe by default (anonymous, no account). To use your own server, create
`/home/root/.local/share/remarkable-animator/settings.json` on the tablet:
```json
{ "upload": { "url": "https://example.com/upload", "field": "file", "params": {} } }
```
The response may be plain text containing the link, or JSON with a `url` field.

## Build
```powershell
# Pen pressure backend: static aarch64 binary via zig (pip install ziglang)
python -m ziglang cc -target aarch64-linux-musl -O2 -static -s -o src/backend/entry backend/pen.c
# QML resources, with PySide6's rcc
rcc --binary src/resources.qrc -o src/resources.rcc
# Copy to the tablet, then exit and reopen the app (AppLoad reloads it on launch)
.\deploy.ps1
```
Machine-specific deploy settings (tablet Wi-Fi IP, an SSH askpass helper) go in a git-ignored
`deploy.local.ps1`; see the top of `deploy.ps1`.

## How it works
The reMarkable's UI imposes some surprising constraints (the pen arrives as a mouse, the e-ink
renderer can't draw vector shapes, a one-minute watchdog). [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
explains them and how the app works around each.

## License
[MIT](LICENSE)
