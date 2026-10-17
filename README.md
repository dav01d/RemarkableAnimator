# RemarkableAnimator

Flipbook animation **on** the reMarkable Paper Pro Move: draw frames with the Marker, play them
back on the tablet, and share them as a GIF via QR code.

## Features
- Pressure-sensitive pen (3 sizes, black/grey); flip the Marker to erase what you rub over
- Frames with fading onion skin, drag-to-reorder, playback at 6–24 fps
- Undo/redo, rename, a Projects screen; everything autosaves on the tablet (works offline)
- Export the current animation as a GIF, uploaded to [catbox.moe](https://catbox.moe) and
  shared via a QR code (only when you tap Export)

## What you need
- A reMarkable Paper Pro Move on software version 3.28
- A computer and the tablet's USB cable

> [!WARNING]
> **Turning on Developer Mode erases your tablet** (it's a factory reset). Back up first.
> Turning it off later is another reset. Modding is at your own risk.

## Install

### 1. Back up your tablet
Let the tablet finish syncing, then check on [my.remarkable.com](https://my.remarkable.com) or in
the reMarkable desktop app that every notebook you care about is there. Anything that isn't will be
gone after step 2.

### 2. Turn on Developer Mode
On the tablet, go to **Settings → General → Paper Tablet → Software → Advanced → Developer Mode**.
The tablet resets; set it up again and sign back in. (reMarkable's own guide:
[Developer Mode](https://developer.remarkable.com/documentation/developer-mode).)

Now find the tablet's password: **Settings → General → Help → About → Copyrights and Licenses**,
under "General Information". The username is `root`. You'll type this password a few times below.

**Check it works:** plug the tablet into your computer, open a terminal (Windows: PowerShell,
Mac: Terminal) and run `ssh root@10.11.99.1`. Type `yes` if asked, then the password. If you get a
prompt on the tablet, you're in. Type `exit` to leave.

### 3. Install XOVI and AppLoad
These community tools let the tablet run extra apps like this one. The easiest way is the
[Vellum](https://github.com/vellum-dev/vellum-cli#installation) package manager: install it by
following that link, then on the tablet (over `ssh`) run `vellum add xovi` and `vellum add appload`,
and follow anything they tell you to do.

(Prefer doing it by hand? [Install XOVI](https://github.com/asivery/rm-xovi-extensions#to-install-xovi),
then [AppLoad](https://github.com/asivery/rm-appload).)

### 4. Install Animator
1. On this page, click the green **Code** button → **Download ZIP**, and unzip it.
2. Plug the tablet in by USB.
3. Open a terminal in the unzipped folder and copy the app over. It will ask for the tablet's
   password several times; that's normal.
   - **Windows** (right-click inside the folder → **Open in Terminal**):
     ```powershell
     powershell -ExecutionPolicy Bypass -File .\deploy.ps1 -Restart
     ```
   - **Mac / Linux:**
     ```bash
     ssh root@10.11.99.1 mkdir -p /home/root/xovi/exthome/appload/RemarkableAnimator
     scp -r src/* root@10.11.99.1:/home/root/xovi/exthome/appload/RemarkableAnimator/
     ssh root@10.11.99.1 "chmod +x /home/root/xovi/exthome/appload/RemarkableAnimator/backend/entry && systemctl restart xochitl"
     ```
4. The tablet's screen reloads. Open the AppLoad menu and tap **Animator**. 🎉

### If something goes wrong
- **Animator vanished after the tablet restarted:** XOVI switches itself off on every restart
  (on purpose, so a bad mod can't trap your tablet). Plug in, `ssh root@10.11.99.1`, and run
  `xovi/start`.
- **After a reMarkable software update:** updates switch the mods off, and AppLoad currently needs
  version 3.28, so hold off on updating if you can. With Vellum, `vellum reenable` turns them
  back on.
- **Updating Animator:** download the new ZIP and repeat step 4, but first close Animator on the
  tablet (restarting the tablet's UI while the app is open can crash it).

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
