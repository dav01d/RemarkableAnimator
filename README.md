# RemarkableAnimator

Flipbook animation **on** the reMarkable Paper Pro Move: draw frames with the Marker, play them
back on the tablet, and share them to your phone via QR code.

<p align="center"><img src="docs/images/drawing.png" width="480" alt="Animator on the tablet: a bouncing ball on its own layer over a held ground layer, with onion skin showing the previous frames in grey and the next one in blue"></p>

## Examples
Drawn and exported on the tablet with Animator: the same 18-frame animation as a GIF and as an
animated SVG (the SVG stays sharp at any size).

<p align="center">
  <img src="docs/examples/waking-up.gif" width="480" alt="Example GIF: a sketched animal curled up asleep wakes, lifts its head and looks at a ball">
  <br><br>
  <img src="docs/examples/waking-up.svg" width="480" alt="The same animation as an animated SVG">
</p>

## Features
- Pressure-sensitive pen in 3 sizes; flip the Marker (or tap the eraser button) to erase
- Black ink for finished lines, light grey for roughs (exports leave grey out). Or sketch on its
  own layer and hide it with the layer's eye
- Up to 3 layers with names; a layer can **Hold** a drawing across frames instead of redrawing it
- Onion skin: earlier drawings in fading grey, the next one in light blue
- Timeline and project list with thumbnails; drag frames to reorder; playback at 6–24 fps
- Undo/redo, rename, delete; everything autosaves on the tablet (works offline)
- Palm rejection: a resting hand can't draw or press the timeline and bottom bar; fingers still
  work on the top bar, keyboard and menus, in case you put the pen down
- Share to your phone with a QR code (see below)

## Sharing
Tap the share button (top right), pick how the link reaches your phone, then a format:

<p align="center"><img src="docs/images/share-options.png" width="560" alt="The share screen: Upload link or Wi-Fi (no cloud), then GIF, Animated SVG, SVG frames or PDF flipbook"></p>

- **Upload link:** the file is uploaded to [catbox.moe](https://catbox.moe) (anonymous, only when
  you share). To use your own server instead, see [Upload target](#upload-target).
- **Wi-Fi (no cloud):** the tablet serves the file itself for 10 minutes while Animator stays open.
  Your phone must be on the same Wi-Fi.

| Format | Good for |
|---|---|
| **GIF** | Plays anywhere: messages, social posts |
| **Animated SVG** | One small file that loops in any browser and stays sharp at any size |
| **SVG frames** | A zip with one SVG per frame (layers as groups), for Illustrator, Inkscape or Figma |
| **PDF flipbook** | One page per frame; from your phone you can send it to the reMarkable app |

Then scan the code with your phone's camera:

<p align="center"><img src="docs/images/share-ready.png" width="420" alt="Your GIF is ready: a QR code and the link (an example link here)"></p>

## What you need
- A reMarkable Paper Pro Move on software version 3.28
- A computer and the tablet's USB cable

> [!WARNING]
> **Turning on Developer Mode erases your tablet** (it's a factory reset). Back up first.
> Turning it off later is another reset. Modding is at your own risk.

## Install
About 20 minutes the first time. You'll: back up, turn on Developer Mode, add the two community
tools that let the tablet run apps (XOVI and AppLoad), then copy Animator over.
**Already have XOVI and AppLoad?** Skip to [step 4](#4-install-animator).

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
- **Updating Animator:** first close Animator on the tablet with its ✕ (restarting the tablet's UI
  while the app is open can crash it), then download the new ZIP and repeat step 4. Your
  animations are kept.

## Upload target
Exports go to catbox.moe by default (anonymous, no account). To use your own server, create
`/home/root/.local/share/remarkable-animator/settings.json` on the tablet:
```json
{ "upload": { "url": "https://example.com/upload", "field": "file", "params": {} } }
```
The response may be plain text containing the link, or JSON with a `url` field.

## Build
```powershell
# Backend (pen pressure, Wi-Fi share): static aarch64 binary via zig (winget install zig.zig)
zig cc -target aarch64-linux-musl -O2 -static -s -o src/backend/entry backend/pen.c backend/share.c
# QML resources, with PySide6's rcc
rcc --binary src/resources.qrc -o src/resources.rcc
# Close the app on the tablet, then copy and restart xochitl (AppLoad caches the app until then)
.\deploy.ps1 -Restart
```
Machine-specific deploy settings (tablet Wi-Fi IP, an SSH askpass helper) go in a git-ignored
`deploy.local.ps1`; see the top of `deploy.ps1`.

## How it works
The reMarkable's UI imposes some surprising constraints (the pen arrives as a mouse, the e-ink
renderer can't draw vector shapes, a one-minute watchdog). [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
explains them and how the app works around each.

## License
[MIT](LICENSE)
