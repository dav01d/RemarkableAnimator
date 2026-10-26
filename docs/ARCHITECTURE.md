# Architecture

RemarkableAnimator is an [AppLoad](https://github.com/asivery/rm-appload) app: a QML frontend
running inside xochitl (the reMarkable UI), plus a tiny native backend for pen pressure.

## Files
| File | Job |
|---|---|
| `src/main.qml` | UI, pen input, rendering, frame/undo model, projects, export upload |
| `src/ExportWorker.js` | Builds the export: 1-bit animated GIF, animated SVG, a zip of SVG frames or a PDF flipbook (WorkerScript thread) |
| `src/StorageWorker.js` | Saves, loads and lists projects as JSON (WorkerScript thread) |
| `src/QrCode.js` | QR code generator (byte mode, level M) for the share screen |
| `backend/pen.c` → `src/backend/<cpu>/entry` | Streams pen pressure, tilt and eraser end to the frontend; `src/backend/entry` starts the one for the tablet's CPU (`aarch64`: Paper Pro, `armv7l`: reMarkable 2) |
| `backend/share.c` (in the same binary) | Wi-Fi share: serves the latest export over HTTP on port 8765 for 10 minutes and reports the link |
| `extension/animator-ink.c` → `src/extension/animator-ink.so` | reMarkable 2 only: a XOVI extension that inks the pen and eraser through xochitl's own fast pen path while Animator arms it (see below) |

## What the platform taught us
| Behaviour on the tablet (OS 3.28) | How the app handles it |
|---|---|
| xochitl hands AppLoad apps the **Marker as a plain mouse** (position only). Its tablet events arrive with position 0,0. | Draw from a `MouseArea`. Fingers arrive as *synthesized* mouse events and are refused, which gives palm rejection. |
| **No pressure, tilt or eraser** in those mouse events. | `backend/pen.c`, an AppLoad backend, reads the Marker's evdev device (`Elan marker input`: 4096 pressure levels, tilt ±90°, eraser end) and streams changes over AppLoad's socket. |
| xochitl's scene graph (`libqsgepaper`) only draws **rectangles, images, text and painted items**. `QtQuick.Shapes` renders nothing, **rotated Rectangles don't draw**, item `opacity` is unreliable. | The live stroke is drawn into small `Canvas` tiles created under the pen (a long stroke needs ~20), baked into a per-frame `Canvas` image on pen-up. Onion skin is baked as lighter greys instead of opacity. |
| The e-ink waveform is chosen per region (`DisplayMethodArea`). `UFast` puts new ink on the panel noticeably sooner than `Fast`, but it's 1-bit. | The canvas uses `UFast` while the pen is down and `Fast` otherwise, so grey ink settles on pen-up. |
| Opening the app leaves a **ghost of xochitl's menu** on the panel; partial updates never clear it. | On launch the app flashes the whole screen black, then white, on the `Content` waveform (`flashMs` per step). |
| xochitl has a **one-minute watchdog**: block its UI thread that long and it is killed. | Export and saving run in `WorkerScript` threads; the live stroke stays a handful of items however long it gets; erasing redraws only the eraser's area. |
| A JS object assigned to a QML property is **copied**. | Canvases look their frame up instead of holding a reference. |
| Handing data to a `WorkerScript` deep-copies it **on the UI thread** (~1 s for a 650 KB project). | Autosave sends only the strokes added or changed since the last save (or the whole frame when that is less); the storage worker keeps the rest, including the frames it just loaded. |
| AppLoad logs a line for every backend message. | The backend sends only real pressure changes (≥1.5%, at most every 15 ms) and nothing while hovering. |
| AppLoad caches an app's `resources.rcc` until xochitl restarts; a reboot drops XOVI (its hook lives on tmpfs). | Deploying is copy, close the app, restart xochitl (`deploy.ps1 -Restart`). If AppLoad disappears after a reboot, run `/home/root/xovi/start`. |
| AppLoad's virtual keyboard only serves framebuffer apps. | Rename has its own on-screen keyboard. |
| QML can't listen on a socket. | The Wi-Fi share writes the export next to the projects and asks the backend (message 2) to serve it; the backend answers with `http://<Wi-Fi IP>:8765/<file>`, which the QR code shows. Its sockets are non-blocking and live in the pen's poll loop, so a phone never stalls the pen. |

## The reMarkable 2
| Behaviour (OS 3.29.0.153) | How the app handles it |
|---|---|
| The panel is driven in software (SWTCON). Updates cost more the bigger they are, and a new one waits for any overlapping update still running. | Smaller live tiles (64 px), a drawing's ink in 400 px parts so a stroke repaints only what it touched, blank parts hidden so playback updates only inked areas, half the stroke points. |
| Switching a region's waveform repaints it in software (~200 ms), and `UFast` (xochitl's pen mode) only draws pixels marked in a pen mask Qt never sets, which leaves stuck ink. | The canvas stays on `Fast`. |
| xochitl's own pen bypasses Qt: it writes the screen image and that mask itself and queues DU updates flagged *FastDraw*, which don't wait for each other. | The `animator-ink` extension does the same for Animator. Animator arms it with a heartbeat file (`/tmp/animator-ink`: canvas rect, pen size, eraser tool and radius; off after 3 s without one). It reads the pen's evdev itself and inks black, or white for the eraser, as a preview; Animator still draws, erases and saves the real strokes, and when the eraser lifts it moves a paper patch over the rubbed area so Qt draws other layers there again. The extension calls stripped xochitl functions by address, so it checks xochitl's build-id and stays off on any other build. |
| The pen enters range only 5–30 ms before it touches, so the backend's eraser word can come after the press; the pen's release sometimes arrives as a synthesized (palm-like) event; resting palms move the mouse. | A late eraser word redoes the stroke as an erase; the backend's "not touching" ends a stroke; synthesized moves and releases are refused. |
| AppLoad can start the backend before its socket exists. | The backend retries connecting for 5 s. |

## Data
Projects live in `/home/root/.local/share/remarkable-animator/`: `index.json` lists them (with a
small thumbnail of frame 1) and each `<id>.json` holds
`{ id, name, fps, length, layers: [{ name, visible, faded, cels: [{ at, strokes }] }] }`: a layer's drawing
at frame `at` holds until its next cel. Strokes are stored compactly as
`{ t: tool, c: color, p: [x, y, width, ...] }`; black is finished ink, any other color is planning
ink (never exported). A `faded` layer is a rough: drawn at half strength, left out of exports.
Files from before layers (`frames: [strokes]`) open as one layer.
