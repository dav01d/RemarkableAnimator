import QtQuick
import QtCore
import net.asivery.AppLoad 1.0
import net.asivery.ApploadUtils
import "QrCode.js" as QrCodeLib

// Rendering note: xochitl's e-paper scene graph (libqsgepaper) only draws rectangles,
// images, text and painted items; QtQuick.Shapes renders nothing there. So the live
// stroke is drawn into small Canvas tiles under the pen (tiny e-ink updates) and on
// pen-up it is baked into the frame's Canvas image and the tiles are destroyed.
Rectangle {
    id: root
    anchors.fill: parent
    color: "white"

    // AppLoad contract: emit close() to exit, unloading() is called on teardown
    signal close
    function unloading() { playTimer.stop(); saveProject(); penBackend.terminate(); } // stop the pen backend too

    // ---------------------------------------------------------------
    // MODEL
    // frames[i] = { key, canvas, strokes: [stroke], undo: [op], redo: [op], queue: [stroke], full, trash: [Item], dirty, edits }
    // edits     = [[at, deleteCount, [stroke]]] spliced into strokes since the last save, or null: unsaved as a whole
    // stroke    = { tool, color, pts: [{x, y, w}] }
    // op        = { t: "add", s } | { t: "swap", before: [stroke], after: [stroke] }
    // ---------------------------------------------------------------
    property var frames: []
    property int frameCount: 0
    property int current: 0
    property int historyRev: 0 // bumped on every edit so Undo/Redo enablement re-evaluates
    property int frameKeys: 0  // last frame key handed out; the storage worker caches saved frames by key

    // Tools
    // One pressure-sensitive pen in three sizes: black to finish, light grey to plan.
    // Flip the Marker, or pick the eraser, to erase.
    property string inkColor: "#000000"
    readonly property string planInk: "#c0c0c0"
    property bool eraserTool: false
    property bool showPlanning: true    // planning ink on screen; export always leaves it out
    property var sizes: [2, 5, 10]
    property int sizeIndex: 1

    // Playback
    property bool isPlaying: false
    property int onionDepth: 2          // how many previous frames show through (0 = off)
    property var fpsOptions: [6, 8, 12, 24]
    property int fpsIndex: 2
    readonly property int fps: fpsOptions[fpsIndex]

    // Pen state streamed by the backend (backend/pen.c): xochitl gives apps the Marker
    // as a plain mouse, so pressure, tilt and the eraser end come from evdev instead
    property real penPressure: 0        // 0..1, 0 = no backend data yet
    property bool penEraser: false

    AppLoad {
        id: penBackend
        applicationID: "remarkable-animator"
        onMessageReceived: (type, contents) => {
            if (type !== 1) return;
            var v = contents.split(" "); // "pressure tiltX tiltY eraser touching"
            root.penPressure = v[0] / 1000;
            root.penEraser = v[3] === "1";
        }
    }

    // Live gesture
    property var live: null             // stroke being drawn, plus tiles: { "col,row": { canvas, segs } }
    property int liveTile: 128          // px: size of the Canvas tiles the live stroke is drawn into
    property var eraseOp: null          // { x, y, before, hit } while the eraser is down
    property bool liveErasing: false
    property double moveWaiting: 0      // time of the first pen move not yet on a drawn frame

    // Export
    property string statusMessage: ""
    property string exportedUrl: ""
    property bool showExportModal: false
    property bool isExporting: false

    readonly property var frame: current < frameCount ? frames[current] : null
    readonly property bool canUndo: historyRev >= 0 && !!frame && frame.undo.length > 0
    readonly property bool canRedo: historyRev >= 0 && !!frame && frame.redo.length > 0

    onCurrentChanged: refreshLayers()
    onShowPlanningChanged: {
        for (var i = 0; i < frames.length; i++) frames[i].full = true;
        refreshLayers();
    }

    // Latency probe: pen move -> next frame the window has drawn (app side only; the e-ink
    // panel adds its own refresh on top)
    Connections {
        target: root.Window.window
        function onFrameSwapped() {
            if (!root.moveWaiting || !root.live) return;
            var ms = Date.now() - root.moveWaiting, l = root.live;
            root.moveWaiting = 0;
            l.lat = (l.lat || 0) + ms; l.frames = (l.frames || 0) + 1; l.latMax = Math.max(l.latMax || 0, ms);
        }
    }
    onIsPlayingChanged: refreshLayers()
    onOnionDepthChanged: refreshLayers()

    Component.onCompleted: {
        loadSettings();
        insertFrame(0, null);
        storage.sendMessage({ op: "list", dir: storageDir }); // then reopen the latest animation
    }

    // ---------------------------------------------------------------
    // PROJECTS: autosaved to <data>/remarkable-animator, reopened on launch
    // ---------------------------------------------------------------
    readonly property string storageDir: StandardPaths.writableLocation(StandardPaths.GenericDataLocation) + "/remarkable-animator"
    property string projectId: ""
    property string projectName: ""
    property var projectIndex: []
    property bool showProjects: false
    property bool loading: false        // suppresses autosave while frames are rebuilt

    onHistoryRevChanged: if (!loading && projectId) saveTimer.restart()

    Timer { id: saveTimer; interval: 2000; onTriggered: root.saveProject() }

    WorkerScript {
        id: storage
        source: "StorageWorker.js"
        onMessage: (m) => {
            if (m.op === "list") {
                root.projectIndex = m.index;
                if (!root.projectId) m.index.length ? root.openProject(m.index[0].id) : root.newProject();
            } else if (m.op === "loaded") {
                root.applyProject(m.project);
            } else if (m.op === "saved") {
                root.projectIndex = m.index;
            } else {
                console.log("[Animator] storage:", m.message);
                for (var i = 0; i < root.frames.length; i++) root.frames[i].edits = null; // resend everything next save
                if (!root.projectId) root.newProject(); // unreadable save: don't leave the user without a project
            }
        }
    }

    function saveProject() {
        if (!projectId) return;
        saveTimer.stop();
        // Handing strokes to the worker copies them on this thread, so send only what changed since
        // the last save: each frame's edits, or the whole frame when that's fewer points to copy
        var t0 = Date.now(), order = [], whole = {}, edits = {}, n = 0, pts = 0;
        for (var i = 0; i < frames.length; i++) {
            var f = frames[i];
            order.push(f.key);
            if (f.edits && !f.edits.length) continue;
            var all = pointCount(f.strokes), changed = f.edits ? f.edits.reduce((c, e) => c + pointCount(e[2]), 0) : Infinity;
            if (changed < all) { edits[f.key] = f.edits; pts += changed; } else { whole[f.key] = f.strokes; pts += all; }
            f.edits = [];
            n++;
        }
        storage.sendMessage({ op: "save", dir: storageDir,
                              project: { id: projectId, name: projectName, fps: fps, order: order, whole: whole, edits: edits } });
        console.log("[Animator][perf] save handoff", n, "of", order.length, "frames,", pts, "pts,", Date.now() - t0, "ms");
    }

    function pointCount(strokes) { return strokes.reduce((c, s) => c + s.pts.length, 0); }

    function newProject() {
        saveProject();
        projectId = "anim-" + Date.now();
        projectName = "Animation " + (projectIndex.length + 1);
        resetFrames([[]]);
        showProjects = false;
        saveProject();
    }

    // "edited 5 min ago" (the tablet's clock is UTC, so relative times read better)
    function ago(ms) {
        var s = (Date.now() - ms) / 1000;
        if (s < 60) return "just now";
        if (s < 3600) return Math.floor(s / 60) + " min ago";
        if (s < 86400) return Math.floor(s / 3600) + " h ago";
        var d = Math.floor(s / 86400);
        return d === 1 ? "yesterday" : d + " days ago";
    }

    property bool showRename: false
    property string renameText: ""

    function startRename() { renameText = projectName; showRename = true; }

    function typeKey(k) {
        if (renameText.length >= 32) return;
        var capital = renameText.length === 0 || renameText[renameText.length - 1] === " ";
        renameText += capital ? k.toUpperCase() : k;
    }

    function finishRename() {
        var name = renameText.trim();
        if (name) { projectName = name; saveProject(); }
        showRename = false;
    }

    function openProject(id) {
        showProjects = false;
        if (id === projectId) return;
        saveProject();
        storage.sendMessage({ op: "load", dir: storageDir, id: id });
    }

    function applyProject(p) {
        projectId = p.id;
        projectName = p.name;
        var fi = fpsOptions.indexOf(p.fps);
        if (fi >= 0) fpsIndex = fi;
        resetFrames(p.frames.length ? p.frames : [[]]);
        if (p.frames.length) for (var i = 0; i < frames.length; i++) frames[i].edits = []; // the storage worker kept them
        saveProject(); // marks it most recent, so it reopens next launch
    }

    // Replace every frame with the given stroke lists
    function resetFrames(data) {
        loading = true;
        isPlaying = false;
        for (var i = 0; i < frames.length; i++) frames[i].canvas.destroy();
        frames = [];
        frameCount = 0;
        frameKeys = 0; // keys 1..n, as the storage worker keys a project it loads
        current = 0;
        for (var j = 0; j < data.length; j++) insertFrame(j, { strokes: data[j] });
        current = 0;
        refreshLayers();
        loading = false;
    }

    // One frame's baked ink
    Component {
        id: canvasComp
        Canvas {
            anchors.fill: parent
            renderTarget: Canvas.Image
            renderStrategy: Canvas.Immediate
            onWidthChanged: root.repaint(root.frameOf(this))
            onHeightChanged: root.repaint(root.frameOf(this))
            onPaint: root.paintFrame(this)
        }
    }

    // One tile of the live stroke
    Component {
        id: tileComp
        Canvas {
            width: root.liveTile; height: root.liveTile
            renderTarget: Canvas.Image
            renderStrategy: Canvas.Immediate
            onPaint: root.paintTile(this)
        }
    }

    // ---------------------------------------------------------------
    // FRAMES
    // ---------------------------------------------------------------
    function insertFrame(at, copyFrom) {
        var f = { key: ++frameKeys, strokes: copyFrom ? copyFrom.strokes.slice() : [], undo: [], redo: [], queue: [], full: true, trash: [], edits: null };
        f.canvas = canvasComp.createObject(stage);
        frames.splice(at, 0, f);
        frameCount = frames.length;
        current = at;
        refreshLayers();
        historyRev++;
    }

    function deleteFrame() {
        if (frameCount <= 1) { clearFrame(); return; }
        frames[current].canvas.destroy();
        frames.splice(current, 1);
        frameCount = frames.length;
        current = Math.min(current, frameCount - 1);
        refreshLayers();
        historyRev++;
    }

    function moveFrame(from, to) {
        if (from === to) return;
        frames.splice(to, 0, frames.splice(from, 1)[0]);
        current = to;
        refreshLayers();
        historyRev++; // autosave
    }

    function goTo(i) {
        if (i >= 0 && i < frameCount) current = i;
    }

    function refreshLayers() {
        for (var i = 0; i < frames.length; i++) {
            var c = frames[i].canvas;
            c.visible = i === current;
            if (c.visible && (frames[i].full || frames[i].queue.length)) c.requestPaint();
        }
        onionCanvas.requestPaint();
    }

    Timer {
        id: playTimer
        interval: Math.round(1000 / root.fps)
        repeat: true
        running: root.isPlaying && root.frameCount > 1
        onTriggered: root.current = (root.current + 1) % root.frameCount
    }

    // ---------------------------------------------------------------
    // RENDERING
    // ---------------------------------------------------------------
    function repaint(f) {
        if (!f || !f.canvas) return;
        f.full = true;
        f.canvas.requestPaint();
    }

    // Redraw only one area (the eraser's footprint): much less drawing, and the e-ink
    // panel refreshes a small square instead of the whole frame
    function repaintArea(f, r) {
        if (!f || !f.canvas) return;
        // Strokes still waiting to be drawn may have just been erased; drop the stale
        // copies and redraw their area from the current stroke list instead
        for (var i = 0; i < f.queue.length; i++) {
            var b = bounds(f.queue[i]);
            r = unite(r, { x: b.x0 - b.w, y: b.y0 - b.w, w: b.x1 - b.x0 + 2 * b.w, h: b.y1 - b.y0 + 2 * b.w });
        }
        f.queue = [];
        if (f.dirty) r = unite(f.dirty, r);
        f.dirty = r;
        f.canvas.markDirty(Qt.rect(r.x, r.y, r.w, r.h));
    }

    function unite(a, b) {
        var x = Math.min(a.x, b.x), y = Math.min(a.y, b.y);
        return { x: x, y: y, w: Math.max(a.x + a.w, b.x + b.w) - x, h: Math.max(a.y + a.h, b.y + b.h) - y };
    }

    // Queue a stroke to be drawn onto the frame image, updating only its own area
    function queueStroke(f, s) {
        var b = bounds(s);
        f.queue.push(s);
        f.canvas.markDirty(Qt.rect(b.x0 - b.w, b.y0 - b.w, b.x1 - b.x0 + 2 * b.w, b.y1 - b.y0 + 2 * b.w));
    }

    // Looked up rather than stored on the Canvas: a JS object assigned to a QML
    // property is copied, so the Canvas would see a stale snapshot
    function frameOf(c) {
        for (var i = 0; i < frames.length; i++) if (frames[i].canvas === c) return frames[i];
        return null;
    }

    // Draws onto the frame's image: everything after undo/clear, only the dirty area after
    // an erase, then any newly queued strokes
    function paintFrame(c) {
        var f = frameOf(c), ctx = c.getContext("2d");
        if (!f || !ctx) return;
        var t0 = Date.now(), drawn = 0, mode = f.full ? "full" : f.dirty ? "area" : "queue";
        if (f.full) {
            ctx.clearRect(0, 0, c.width, c.height);
            for (var i = 0; i < f.strokes.length; i++) drawStroke(ctx, f.strokes[i]);
            drawn = f.strokes.length;
        } else {
            var d = f.dirty;
            if (d) {
                ctx.save();
                ctx.beginPath();
                ctx.rect(d.x, d.y, d.w, d.h);
                ctx.clip();
                ctx.clearRect(d.x, d.y, d.w, d.h);
                for (var k = 0; k < f.strokes.length; k++) {
                    var b = bounds(f.strokes[k]), m = b.w / 2;
                    if (b.x1 + m < d.x || b.x0 - m > d.x + d.w || b.y1 + m < d.y || b.y0 - m > d.y + d.h) continue;
                    drawStroke(ctx, f.strokes[k]);
                    drawn++;
                }
                ctx.restore();
            }
            for (var q = 0; q < f.queue.length; q++) drawStroke(ctx, f.queue[q]);
            drawn += f.queue.length;
        }
        f.full = false;
        f.dirty = null;
        f.queue = [];
        // The ink is on the image now, so the live preview dots can go
        for (var j = 0; j < f.trash.length; j++) f.trash[j].destroy();
        f.trash = [];
        var ms = Date.now() - t0;
        if (ms > 10) console.log("[Animator][perf] paint", mode, drawn, "strokes", ms, "ms");
    }

    // Onion skin: earlier frames drawn in lighter greys, each step back half as dark
    // (50%, 25%, 12.5%). Baked as solid colors because item opacity is unreliable on e-paper.
    function paintOnion(c) {
        var ctx = c.getContext("2d");
        if (!ctx) return;
        ctx.clearRect(0, 0, c.width, c.height);
        for (var back = onionDepth; back >= 1; back--) {
            var f = frames[current - back];
            if (!f) continue;
            for (var i = 0; i < f.strokes.length; i++) drawStroke(ctx, f.strokes[i], Math.pow(0.5, back));
        }
    }

    // Blend a #rrggbb color toward white, keeping `strength` of its darkness
    function fade(hex, strength) {
        var out = "#";
        for (var i = 1; i < 7; i += 2) {
            var v = Math.round(255 - (255 - parseInt(hex.substr(i, 2), 16)) * strength);
            out += (v < 16 ? "0" : "") + v.toString(16);
        }
        return out;
    }

    // Any ink but black is planning (older animations used a darker grey)
    function isPlanning(s) { return s.color !== "#000000"; }

    function drawStroke(ctx, s, strength) {
        if (!showPlanning && isPlanning(s)) return;
        var pts = s.pts, color = strength ? fade(s.color, strength) : s.color;
        ctx.globalCompositeOperation = s.tool === "area" ? "destination-out" : "source-over";
        ctx.strokeStyle = color;
        ctx.fillStyle = color;
        ctx.lineCap = "round";
        ctx.lineJoin = "round";
        if (pts.length === 1) {
            ctx.beginPath();
            ctx.arc(pts[0].x, pts[0].y, pts[0].w / 2, 0, 2 * Math.PI);
            ctx.fill();
        }
        // Batch runs of equal width into one path
        for (var i = 1; i < pts.length; ) {
            var w = pts[i].w;
            ctx.lineWidth = w;
            ctx.beginPath();
            ctx.moveTo(pts[i - 1].x, pts[i - 1].y);
            while (i < pts.length && pts[i].w === w) { ctx.lineTo(pts[i].x, pts[i].y); i++; }
            ctx.stroke();
        }
        ctx.globalCompositeOperation = "source-over";
    }

    // The live line goes into Canvas tiles created under the pen as it moves: a handful of
    // items however long the stroke, so nothing is baked until pen-up, and each move
    // repaints only the small area it touches
    function addSegment(s, a, b) {
        var r = Math.max(a.w, b.w) / 2 + 1, T = liveTile;
        var x0 = Math.min(a.x, b.x) - r, y0 = Math.min(a.y, b.y) - r;
        var x1 = Math.max(a.x, b.x) + r, y1 = Math.max(a.y, b.y) + r;
        for (var col = Math.floor(x0 / T); col <= Math.floor(x1 / T); col++) {
            for (var row = Math.floor(y0 / T); row <= Math.floor(y1 / T); row++) {
                var key = col + "," + row, t = s.tiles[key];
                if (!t) t = s.tiles[key] = { canvas: tileComp.createObject(liveLayer, { x: col * T, y: row * T }), segs: [] };
                t.segs.push([a, b]);
                t.canvas.markDirty(Qt.rect(x0 - col * T, y0 - row * T, x1 - x0, y1 - y0));
            }
        }
    }

    function paintTile(c) {
        var t = null, ctx = c.getContext("2d");
        if (live) for (var k in live.tiles) if (live.tiles[k].canvas === c) t = live.tiles[k];
        if (!t || !ctx) return; // after pen-up the frame image has the ink
        ctx.strokeStyle = live.color;
        ctx.fillStyle = live.color;
        ctx.lineCap = "round";
        for (var i = 0; i < t.segs.length; i++) {
            var a = t.segs[i][0], b = t.segs[i][1];
            ctx.beginPath();
            if (a === b) { ctx.arc(a.x - c.x, a.y - c.y, a.w / 2, 0, 2 * Math.PI); ctx.fill(); continue; }
            ctx.lineWidth = b.w;
            ctx.moveTo(a.x - c.x, a.y - c.y);
            ctx.lineTo(b.x - c.x, b.y - c.y);
            ctx.stroke();
        }
        t.segs = [];
    }

    // ---------------------------------------------------------------
    // STROKES
    // ---------------------------------------------------------------
    function strokeWidth(pressure) {
        var p = pressure > 0 ? Math.min(1, pressure) : 0.6; // no backend data yet: medium
        // ~5x from light to hard; half-pixel steps give long equal-width runs to batch
        return Math.max(0.5, Math.round(sizes[sizeIndex] * (0.3 + 1.4 * p) * 2) / 2);
    }

    function pushOp(op) {
        frame.undo.push(op);
        frame.redo = [];
        historyRev++;
    }

    // Every change to a frame's strokes goes through here, so autosave can send just the change
    function spliceStrokes(f, at, del, ins) {
        f.strokes.splice.apply(f.strokes, [at, del].concat(ins));
        if (f.edits) f.edits.push([at, del, ins]);
    }

    function undo() {
        var f = frame, op = f && f.undo.pop();
        if (!op) return;
        if (op.t === "add") spliceStrokes(f, f.strokes.indexOf(op.s), 1, []);
        else spliceStrokes(f, 0, f.strokes.length, op.before);
        f.redo.push(op);
        repaint(f);
        historyRev++;
    }

    function redo() {
        var f = frame, op = f && f.redo.pop();
        if (!op) return;
        if (op.t === "add") spliceStrokes(f, f.strokes.length, 0, [op.s]);
        else spliceStrokes(f, 0, f.strokes.length, op.after);
        f.undo.push(op);
        repaint(f);
        historyRev++;
    }

    function clearFrame() {
        var f = frame;
        if (!f.strokes.length) return;
        pushOp({ t: "swap", before: f.strokes.slice(), after: [] });
        spliceStrokes(f, 0, f.strokes.length, []);
        repaint(f);
    }

    function bounds(s) {
        if (!s.box) {
            var b = { x0: 1e9, y0: 1e9, x1: -1e9, y1: -1e9, w: 0 };
            for (var i = 0; i < s.pts.length; i++) {
                var p = s.pts[i];
                b.x0 = Math.min(b.x0, p.x); b.x1 = Math.max(b.x1, p.x);
                b.y0 = Math.min(b.y0, p.y); b.y1 = Math.max(b.y1, p.y);
                b.w = Math.max(b.w, p.w);
            }
            s.box = b;
        }
        return s.box;
    }

    // Rub out only what's under the eraser: drop the covered points and split the stroke
    // into the pieces that remain (like the notebook app's eraser)
    function eraseAt(x, y) {
        var R = 16, strokes = frame.strokes, hitAny = false;
        for (var i = strokes.length - 1; i >= 0; i--) {
            var s = strokes[i], b = bounds(s), reach = R + b.w / 2;
            if (!showPlanning && isPlanning(s)) continue; // don't rub out what you can't see
            if (x < b.x0 - reach || x > b.x1 + reach || y < b.y0 - reach || y > b.y1 + reach) continue;
            var pieces = [], run = [], hit = false;
            for (var j = 0; j < s.pts.length; j++) {
                var p = s.pts[j];
                if (Math.hypot(p.x - x, p.y - y) < R + p.w / 2) {
                    hit = true;
                    if (run.length) pieces.push(run);
                    run = [];
                } else run.push(p);
            }
            if (!hit) continue;
            if (run.length) pieces.push(run);
            var repl = [];
            for (var k = 0; k < pieces.length; k++)
                if (pieces[k].length > 1 || s.pts.length === 1) repl.push({ tool: s.tool, color: s.color, pts: pieces[k] });
            spliceStrokes(frame, i, 1, repl);
            hitAny = true;
        }
        if (hitAny) {
            eraseOp.hit = true;
            var pad = R + 20; // covers the removed ink and the new round ends
            repaintArea(frame, { x: x - pad, y: y - pad, w: 2 * pad, h: 2 * pad });
        }
    }

    // ---------------------------------------------------------------
    // PEN INPUT
    // ---------------------------------------------------------------
    function beginGesture(pt, eraserEnd) {
        if (isPlaying || showExportModal || !frame) return;
        var x = pt.position.x, y = pt.position.y;
        if (eraserEnd) {
            liveErasing = true;
            eraseOp = { x: x, y: y, before: frame.strokes.slice(), hit: false };
            eraseAt(x, y);
            return;
        }
        var p = { x: x, y: y, w: strokeWidth(pt.pressure) };
        live = { tool: "pen", color: inkColor, pts: [p], tiles: {} };
        addSegment(live, p, p);
    }

    function moveGesture(pt) {
        var t0 = Date.now();
        if (live && !moveWaiting) moveWaiting = t0;
        moveGestureImpl(pt);
        var g = live || eraseOp;
        if (g) { g.ms = (g.ms || 0) + Date.now() - t0; g.ev = (g.ev || 0) + 1; }
    }

    function moveGestureImpl(pt) {
        var x = pt.position.x, y = pt.position.y;
        if (liveErasing) {
            // Sweep the eraser along the path so fast swipes don't skip strokes
            var n = Math.ceil(Math.hypot(x - eraseOp.x, y - eraseOp.y) / 8);
            for (var k = 1; k <= n; k++) eraseAt(eraseOp.x + (x - eraseOp.x) * k / n, eraseOp.y + (y - eraseOp.y) * k / n);
            eraseOp.x = x; eraseOp.y = y;
            return;
        }
        if (!live) return;
        var last = live.pts[live.pts.length - 1];
        var dx = x - last.x, dy = y - last.y;
        if (dx * dx + dy * dy < 4) return; // 2px minimum step
        var p = { x: x, y: y, w: strokeWidth(pt.pressure) };
        live.pts.push(p);
        addSegment(live, last, p);
    }

    function endGesture() {
        if (liveErasing) console.log("[Animator][perf] erase", eraseOp.ev || 0, "moves,", eraseOp.ms || 0, "ms JS");
        if (liveErasing && eraseOp.hit) pushOp({ t: "swap", before: eraseOp.before, after: frame.strokes.slice() });
        if (live) {
            var f = frame, s = { tool: live.tool, color: live.color, pts: live.pts };
            spliceStrokes(f, f.strokes.length, 0, [s]);
            for (var k in live.tiles) f.trash.push(live.tiles[k].canvas);
            queueStroke(f, s);
            pushOp({ t: "add", s: s });
            console.log("[Animator][perf] stroke", s.pts.length, "pts,", Object.keys(live.tiles).length, "tiles,", live.ev || 0, "moves,",
                        live.ms || 0, "ms JS (", ((live.ms || 0) / Math.max(1, live.ev || 0)).toFixed(1), "ms/move ),",
                        live.frames || 0, "frames, move->frame avg", ((live.lat || 0) / Math.max(1, live.frames || 0)).toFixed(0),
                        "ms max", live.latMax || 0, "ms");
        }
        live = null;
        moveWaiting = 0;
        eraseOp = null;
        liveErasing = false;
    }

    // ---------------------------------------------------------------
    // UI BUILDING BLOCKS
    // ---------------------------------------------------------------
    component Btn: Rectangle {
        id: btn
        property string label
        property string icon            // an Icon name, shown before the label
        property bool on: false
        property bool flat: false       // toolbar style: no outline, solid black when on
        property bool enabledLook: true
        readonly property color ink: on ? "white" : (enabledLook ? "black" : "#aaaaaa")
        signal tap
        width: Math.max(60, content.implicitWidth + 26)
        height: 58
        radius: 8
        color: on ? "black" : "white"
        border.color: "black"
        border.width: flat ? 0 : 2
        Row {
            id: content
            anchors.centerIn: parent
            spacing: 6
            Loader {
                active: btn.icon !== ""
                visible: active
                anchors.verticalCenter: parent.verticalCenter
                sourceComponent: Icon { name: btn.icon; ink: btn.ink }
            }
            Text {
                visible: btn.label !== ""
                anchors.verticalCenter: parent.verticalCenter
                text: btn.label
                font.pixelSize: 21
                font.bold: true
                color: btn.ink
            }
        }
        TapHandler {
            gesturePolicy: TapHandler.ReleaseWithinBounds
            onTapped: btn.tap()
        }
    }

    component Bar: Rectangle {
        default property alias content: flow.data
        width: parent.width
        height: flow.implicitHeight + 16
        color: "white"
        Flow {
            id: flow
            x: 8; y: 8
            width: parent.width - 16
            spacing: 8
        }
        Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 2; color: "black" }
    }

    // ---------------------------------------------------------------
    // TOP: app actions + tools
    // ---------------------------------------------------------------
    // Thin outline icons drawn on a Canvas (the tablet font may lack the glyphs, and its scene
    // graph only draws rectangles, images, text and painted items)
    component Icon: Canvas {
        property string name
        property color ink: "black"
        width: 36; height: 36
        onInkChanged: requestPaint()
        onNameChanged: requestPaint()
        onPaint: {
            var c = getContext("2d");
            c.reset();
            c.strokeStyle = ink; c.fillStyle = ink;
            c.lineWidth = 3; c.lineCap = "round"; c.lineJoin = "round";
            c.beginPath();
            switch (name) {
            case "redo": c.translate(width, 0); c.scale(-1, 1); // then draw the undo arrow mirrored
            case "undo":
                c.moveTo(12, 11); c.lineTo(22, 11); c.arc(22, 19.5, 8.5, -Math.PI / 2, Math.PI / 2, false); c.lineTo(11, 28);
                c.stroke();
                c.beginPath(); c.moveTo(4, 11); c.lineTo(13, 4); c.lineTo(13, 18); c.closePath(); c.fill();
                return;
            case "eraser": // a tilted block, its tip marked off
                c.moveTo(6, 22); c.lineTo(19, 9); c.lineTo(30, 20); c.lineTo(17, 33); c.closePath();
                c.moveTo(12, 16); c.lineTo(23, 27); break;
            case "eye-off": c.moveTo(7, 29); c.lineTo(29, 7); // then the eye, struck through
            case "eye":
                c.moveTo(4, 18); c.quadraticCurveTo(18, 4, 32, 18); c.quadraticCurveTo(18, 32, 4, 18);
                c.moveTo(23, 18); c.arc(18, 18, 5, 0, 2 * Math.PI); break;
            case "close": c.moveTo(9, 9); c.lineTo(27, 27); c.moveTo(27, 9); c.lineTo(9, 27); break;
            case "projects": c.rect(6, 6, 10, 10); c.rect(20, 6, 10, 10); c.rect(6, 20, 10, 10); c.rect(20, 20, 10, 10); break;
            case "share": // arrow up out of a tray
                c.moveTo(18, 22); c.lineTo(18, 5); c.moveTo(11, 12); c.lineTo(18, 5); c.lineTo(25, 12);
                c.moveTo(11, 16); c.lineTo(6, 16); c.lineTo(6, 31); c.lineTo(30, 31); c.lineTo(30, 16); c.lineTo(25, 16); break;
            case "prev": c.moveTo(22, 8); c.lineTo(12, 18); c.lineTo(22, 28); break;
            case "next": c.moveTo(14, 8); c.lineTo(24, 18); c.lineTo(14, 28); break;
            case "play": c.moveTo(11, 7); c.lineTo(28, 18); c.lineTo(11, 29); c.closePath(); c.fill(); return;
            case "stop": c.rect(10, 10, 16, 16); c.fill(); return;
            case "new": c.rect(8, 5, 20, 26); c.moveTo(18, 12); c.lineTo(18, 24); c.moveTo(12, 18); c.lineTo(24, 18); break;
            case "copy": c.rect(13, 11, 16, 21); c.moveTo(8, 26); c.lineTo(8, 5); c.lineTo(23, 5); break;
            case "delete": // trash can
                c.moveTo(6, 9); c.lineTo(30, 9); c.moveTo(14, 9); c.lineTo(14, 5); c.lineTo(22, 5); c.lineTo(22, 9);
                c.moveTo(9, 9); c.lineTo(11, 31); c.lineTo(25, 31); c.lineTo(27, 9);
                c.moveTo(15, 14); c.lineTo(15, 26); c.moveTo(21, 14); c.lineTo(21, 26); break;
            case "onion": // the current frame over fainter earlier ones
                c.arc(23, 18, 9, 0, 2 * Math.PI); c.stroke();
                c.globalAlpha = 0.45; c.beginPath(); c.arc(16, 18, 9, Math.PI / 2, 3 * Math.PI / 2); c.stroke();
                c.globalAlpha = 0.25; c.beginPath(); c.arc(9, 18, 7, Math.PI / 2, 3 * Math.PI / 2);
                break;
            }
            c.stroke();
        }
    }

    // One row: navigation, the animation's name (tap to rename), pen, history, export
    Rectangle {
        id: topBars
        anchors.top: parent.top
        width: parent.width
        height: 74
        z: 10

        Row {
            id: leftGroup
            x: 8; y: 8
            spacing: 8
            Btn { icon: "close"; flat: true; onTap: root.close() }
            Btn { icon: "projects"; flat: true; onTap: root.showProjects = true }
        }
        Text {
            anchors.left: leftGroup.right; anchors.right: rightGroup.left
            anchors.leftMargin: 12; anchors.rightMargin: 12
            height: parent.height
            verticalAlignment: Text.AlignVCenter
            text: root.projectName
            font.pixelSize: 24; font.bold: true
            elide: Text.ElideRight
            TapHandler { onTapped: root.startRename() }
        }
        Row {
            id: rightGroup
            anchors.right: parent.right; anchors.rightMargin: 8
            y: 8
            spacing: 6
            Repeater {
                model: root.sizes.length
                Btn {
                    on: root.sizeIndex === index
                    flat: true
                    width: 58
                    onTap: { root.sizeIndex = index; root.eraserTool = false; }
                    Rectangle {
                        anchors.centerIn: parent
                        width: 6 + index * 10; height: width; radius: width / 2
                        color: parent.on ? "white" : "black"
                    }
                }
            }
            Item { width: 12; height: 1 } // gap between groups
            Repeater {
                model: ["#000000", root.planInk]
                Btn {
                    on: root.inkColor === modelData && !root.eraserTool
                    flat: true
                    width: 58
                    onTap: { root.inkColor = modelData; root.eraserTool = false; if (index) root.showPlanning = true; }
                    Rectangle { anchors.centerIn: parent; width: 30; height: 30; radius: 6; color: modelData; border.color: "white"; border.width: 2 }
                }
            }
            Btn { icon: "eraser"; flat: true; width: 58; on: root.eraserTool; onTap: root.eraserTool = !root.eraserTool }
            Item { width: 12; height: 1 } // gap between groups
            Btn { icon: "undo"; flat: true; width: 58; enabledLook: root.canUndo; onTap: root.undo() }
            Btn { icon: "redo"; flat: true; width: 58; enabledLook: root.canRedo; onTap: root.redo() }
            Btn { icon: "share"; flat: true; width: 58; onTap: root.startExport() }
        }
        Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 2; color: "black" }
    }

    // ---------------------------------------------------------------
    // DRAWING STAGE
    // ---------------------------------------------------------------
    Item {
        id: canvasArea
        anchors.top: topBars.bottom
        anchors.bottom: bottomBars.top
        width: parent.width
        clip: true

        Item {
            id: stage
            anchors.fill: parent
            Canvas {
                id: onionCanvas
                anchors.fill: parent
                z: -1 // under the frame canvases
                visible: !root.isPlaying && root.onionDepth > 0
                renderTarget: Canvas.Image
                renderStrategy: Canvas.Immediate
                onPaint: root.paintOnion(this)
            }
        }
        Item { id: liveLayer; anchors.fill: parent; z: 1 } // pen preview above the frames

        // Tell xochitl which e-ink waveform to use for this region. UFast puts the live stroke
        // on the panel noticeably sooner; it's 1-bit, so grey ink settles when Fast takes over
        DisplayMethodArea {
            anchors.fill: parent
            displayMethod: root.isPlaying ? DisplayMethodArea.Animate
                         : root.live ? DisplayMethodArea.UFast : DisplayMethodArea.Fast
        }

        // The Marker reaches AppLoad apps as plain (non-synthesized) mouse events. Fingers
        // arrive as synthesized ones; refusing those means palms never draw. The eraser end
        // is reported by the pen backend (or as a non-left button).
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.AllButtons
            preventStealing: true
            onPressed: (m) => {
                if (m.source !== Qt.MouseEventNotSynthesized) { m.accepted = false; return; }
                root.beginGesture({ position: Qt.point(m.x, m.y), pressure: root.penPressure },
                                  root.eraserTool || root.penEraser || m.button !== Qt.LeftButton);
            }
            onPositionChanged: (m) => root.moveGesture({ position: Qt.point(m.x, m.y), pressure: root.penPressure })
            onReleased: root.endGesture()
            onCanceled: root.endGesture()
        }

    }

    // ---------------------------------------------------------------
    // BOTTOM: timeline + playback
    // ---------------------------------------------------------------
    Column {
        id: bottomBars
        anchors.bottom: parent.bottom
        width: parent.width
        z: 10

        Rectangle { width: parent.width; height: 2; color: "black" }

        ListView {
            id: strip
            width: parent.width
            height: 64
            orientation: ListView.Horizontal
            spacing: 6
            leftMargin: 8; rightMargin: 8
            model: root.frameCount
            currentIndex: root.current
            onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)

            // Press and hold a frame, then drag it left/right to retime the animation
            property int dragFrom: -1
            property int dragTo: -1
            property int scrollSlop: 24 // px the pen may wander during a hold before it scrolls instead
            interactive: dragFrom < 0

            delegate: Rectangle {
                y: 6
                width: 52; height: 52; radius: 6
                color: index === strip.dragFrom ? "#bbbbbb" : index === root.current ? "black" : "white"
                border.color: "black"
                border.width: strip.dragFrom >= 0 && index === strip.dragTo ? 6 : 2
                Text {
                    anchors.centerIn: parent
                    text: index + 1
                    font.pixelSize: 20; font.bold: true
                    color: index === root.current && index !== strip.dragFrom ? "white" : "black"
                }
                // The pen jitters past Qt's drag distance (~1 mm here) before a hold fires, which
                // let the ListView steal the press. Keep the press and scroll the strip ourselves.
                MouseArea {
                    anchors.fill: parent
                    pressAndHoldInterval: 350
                    preventStealing: true
                    property real pressX
                    property real pressContentX
                    property bool scrolling: false
                    onPressed: (m) => {
                        pressX = mapToItem(strip, m.x, 0).x;
                        pressContentX = strip.contentX;
                        scrolling = false;
                    }
                    onClicked: if (!scrolling) root.goTo(index)
                    onPressAndHold: if (!scrolling) { strip.dragFrom = index; strip.dragTo = index; }
                    onPositionChanged: (m) => {
                        if (strip.dragFrom < 0) {
                            var dx = mapToItem(strip, m.x, 0).x - pressX;
                            if (Math.abs(dx) > strip.scrollSlop) scrolling = true;
                            if (!scrolling) return;
                            var minX = strip.originX - strip.leftMargin;
                            var maxX = Math.max(minX, strip.originX + strip.contentWidth + strip.rightMargin - strip.width);
                            strip.contentX = Math.max(minX, Math.min(maxX, pressContentX - dx));
                            return;
                        }
                        var p = mapToItem(strip.contentItem, m.x, m.y);
                        strip.dragTo = Math.max(0, Math.min(root.frameCount - 1, Math.floor((p.x + 3) / 58)));
                    }
                    onReleased: {
                        if (strip.dragFrom >= 0) root.moveFrame(strip.dragFrom, strip.dragTo);
                        strip.dragFrom = -1;
                    }
                    onCanceled: strip.dragFrom = -1
                }
            }
        }

        Bar {
            Btn { icon: "prev"; flat: true; onTap: root.goTo(root.current - 1) }
            Btn { icon: root.isPlaying ? "stop" : "play"; flat: true; on: root.isPlaying; onTap: root.isPlaying = !root.isPlaying }
            Btn { icon: "next"; flat: true; onTap: root.goTo(root.current + 1) }
            Btn { icon: "new"; flat: true; onTap: root.insertFrame(root.current + 1, null) }
            Btn { icon: "copy"; flat: true; onTap: root.insertFrame(root.current + 1, root.frame) }
            Btn {
                id: delBtn
                property bool armed: false
                icon: "delete"
                label: armed ? "Sure?" : ""
                flat: true
                on: armed
                onTap: {
                    if (armed) { armed = false; root.deleteFrame(); }
                    else { armed = true; disarm.restart(); }
                }
                Timer { id: disarm; interval: 3000; onTriggered: delBtn.armed = false }
            }
            Btn {
                icon: "onion"
                label: root.onionDepth ? root.onionDepth : "Off"
                flat: true
                enabledLook: root.onionDepth > 0
                onTap: root.onionDepth = (root.onionDepth + 1) % 4
            }
            Btn {
                icon: root.showPlanning ? "eye" : "eye-off"
                label: "Plan"
                flat: true
                enabledLook: root.showPlanning
                onTap: root.showPlanning = !root.showPlanning
            }
            Btn { label: root.fps + " fps"; flat: true; onTap: root.fpsIndex = (root.fpsIndex + 1) % root.fpsOptions.length }
            Btn { label: "Clear"; flat: true; onTap: root.clearFrame() }
        }
    }

    // ---------------------------------------------------------------
    // RENAME SCREEN (own keyboard: xochitl's isn't available to AppLoad QML apps)
    // ---------------------------------------------------------------
    Rectangle {
        anchors.fill: parent
        visible: root.showRename
        color: "white"
        z: 95
        MouseArea { anchors.fill: parent }

        Column {
            anchors.centerIn: parent
            width: parent.width - 32
            spacing: 14

            Text { text: "Rename animation"; font.pixelSize: 28; font.bold: true }
            Rectangle {
                width: parent.width; height: 80
                border.color: "black"; border.width: 3; radius: 8
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    x: 20; width: parent.width - 40
                    text: root.renameText + "|"
                    font.pixelSize: 34
                    elide: Text.ElideLeft
                }
            }
            Repeater {
                model: ["1234567890", "qwertyuiop", "asdfghjkl", "zxcvbnm"]
                Row {
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: 6
                    Repeater {
                        model: modelData.split("")
                        Btn {
                            width: (root.width - 32 - 9 * 6) / 10; height: 72
                            label: modelData.toUpperCase()
                            onTap: root.typeKey(modelData)
                        }
                    }
                }
            }
            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 6
                Btn { label: "Cancel"; height: 72; onTap: root.showRename = false }
                Btn { label: "Space"; height: 72; width: 240; onTap: root.typeKey(" ") }
                Btn { label: "Delete"; height: 72; onTap: root.renameText = root.renameText.slice(0, -1) }
                Btn { label: "Save"; height: 72; on: true; onTap: root.finishRename() }
            }
        }
    }

    // ---------------------------------------------------------------
    // PROJECTS SCREEN
    // ---------------------------------------------------------------
    Rectangle {
        anchors.fill: parent
        visible: root.showProjects
        color: "white"
        z: 90
        MouseArea { anchors.fill: parent } // swallow input under the list

        Column {
            id: projHeader
            width: parent.width
            Bar {
                Btn { label: "Close"; onTap: root.showProjects = false }
                Btn { label: "+ New animation"; on: true; onTap: root.newProject() }
                Text {
                    height: 58; verticalAlignment: Text.AlignVCenter
                    text: "  Your animations"
                    font.pixelSize: 24; font.bold: true
                }
            }
        }

        ListView {
            anchors.top: projHeader.bottom
            anchors.bottom: parent.bottom
            width: parent.width
            clip: true
            model: root.projectIndex
            delegate: Rectangle {
                width: ListView.view.width
                height: 96
                color: modelData.id === root.projectId ? "#e6e6e6" : "white"
                Column {
                    anchors.verticalCenter: parent.verticalCenter
                    x: 24
                    spacing: 4
                    Text { text: modelData.name; font.pixelSize: 26; font.bold: true }
                    Text {
                        text: modelData.frames + (modelData.frames === 1 ? " frame" : " frames") +
                              "  ·  edited " + root.ago(modelData.updated)
                        font.pixelSize: 20; color: "#555555"
                    }
                }
                Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: "#aaaaaa" }
                TapHandler { onTapped: root.openProject(modelData.id) }
            }
        }
    }

    // ---------------------------------------------------------------
    // EXPORT & SHARE MODAL
    // ---------------------------------------------------------------
    Rectangle {
        anchors.fill: parent
        color: "#88000000"
        visible: root.showExportModal
        z: 100

        MouseArea { anchors.fill: parent } // swallow touches under the modal

        Rectangle {
            width: Math.min(parent.width - 40, 820)
            height: col.implicitHeight + 60
            anchors.centerIn: parent
            color: "white"
            border.color: "black"
            border.width: 3
            radius: 12

            Column {
                id: col
                anchors.centerIn: parent
                spacing: 20
                width: parent.width - 60

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: root.isExporting ? "Exporting..." : (root.exportedUrl !== "" ? "Your GIF is ready!" : "Export failed")
                    font.pixelSize: 28; font.bold: true
                }

                Text {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.Wrap
                    text: root.statusMessage
                    font.pixelSize: 20
                    color: "#555555"
                }

                Canvas {
                    id: qrCanvas
                    width: 340; height: 340
                    anchors.horizontalCenter: parent.horizontalCenter
                    visible: root.exportedUrl !== "" && !root.isExporting
                    onPaint: {
                        var ctx = getContext("2d");
                        ctx.fillStyle = "#FFFFFF";
                        ctx.fillRect(0, 0, width, height);
                        if (!root.exportedUrl) return;
                        var qr = QrCodeLib.getQRCode(root.exportedUrl);
                        var cell = Math.floor(width / qr.size);
                        var off = Math.floor((width - cell * qr.size) / 2);
                        ctx.fillStyle = "#000000";
                        for (var r = 0; r < qr.size; r++)
                            for (var c = 0; c < qr.size; c++)
                                if (qr.isDark(r, c)) ctx.fillRect(off + c * cell, off + r * cell, cell, cell);
                    }
                }

                Text {
                    width: parent.width
                    visible: root.exportedUrl !== "" && !root.isExporting
                    text: root.exportedUrl
                    font.pixelSize: 18
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WrapAnywhere
                }

                Row {
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: 20
                    visible: !root.isExporting
                    Btn { label: root.exportedUrl !== "" ? "Done" : "Cancel"; onTap: root.showExportModal = false }
                    Btn { label: "Retry"; on: true; visible: root.exportedUrl === ""; onTap: root.startExport() }
                }
            }
        }
    }

    // ---------------------------------------------------------------
    // EXPORT PIPELINE
    // ---------------------------------------------------------------
    function startExport() {
        isPlaying = false;
        showExportModal = true;
        isExporting = true;
        exportedUrl = "";
        statusMessage = "Rendering " + frameCount + " frames...";
        exportTimer.start();
    }

    Timer { id: exportTimer; interval: 80; onTriggered: root.runExportPipeline() }

    WorkerScript {
        id: exportWorker
        source: "ExportWorker.js"
        onMessage: (m) => m.bytes ? root.upload(m.bytes) : (root.statusMessage = m.progress)
    }

    function runExportPipeline() {
        var W = 480, k = W / stage.width, H = Math.round(stage.height * k);
        var strokes = [];
        for (var f = 0; f < frames.length; f++) strokes.push(frames[f].strokes.filter(s => !isPlanning(s))); // finished ink only
        exportWorker.sendMessage({ frames: strokes, W: W, H: H, k: k, fps: fps });
    }

    // Where Export uploads: catbox.moe by default (anonymous, no key). A tablet can override it
    // in <storageDir>/settings.json: { "upload": { "url": "...", "field": "...", "params": {} } }
    property var uploader: ({ url: "https://catbox.moe/user/api.php", field: "fileToUpload",
                              params: { reqtype: "fileupload" } })

    function loadSettings() {
        var xhr = new XMLHttpRequest();
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE || !xhr.responseText) return;
            try {
                var u = JSON.parse(xhr.responseText).upload;
                if (u && u.url) root.uploader = { url: u.url, field: u.field || "file", params: u.params || {} };
            } catch (e) {
                console.log("[Animator] ignoring unreadable settings.json:", e);
            }
        };
        xhr.open("GET", storageDir + "/settings.json");
        xhr.send();
    }

    function upload(gifBytes) {
        statusMessage = "Uploading GIF...";
        var boundary = "----AnimatorBoundary" + Math.random().toString(36).substring(2);
        var head = "";
        for (var key in uploader.params)
            head += "--" + boundary + "\r\nContent-Disposition: form-data; name=\"" + key + "\"\r\n\r\n" +
                    uploader.params[key] + "\r\n";
        head += "--" + boundary + "\r\n" +
                "Content-Disposition: form-data; name=\"" + uploader.field + "\"; filename=\"flipbook.gif\"\r\n" +
                "Content-Type: image/gif\r\n\r\n";
        var foot = "\r\n--" + boundary + "--\r\n";
        var payload = new Uint8Array(head.length + gifBytes.length + foot.length);
        for (var h = 0; h < head.length; h++) payload[h] = head.charCodeAt(h);
        payload.set(gifBytes, head.length);
        for (var b = 0; b < foot.length; b++) payload[head.length + gifBytes.length + b] = foot.charCodeAt(b);

        var xhr = new XMLHttpRequest();
        xhr.open("POST", uploader.url);
        xhr.setRequestHeader("Content-Type", "multipart/form-data; boundary=" + boundary);
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return;
            root.isExporting = false;
            if (xhr.status !== 200 && xhr.status !== 201) {
                root.statusMessage = xhr.status ? "Upload error (HTTP " + xhr.status + ")" : "Network error: couldn't reach the upload server";
                return;
            }
            var match = xhr.responseText.match(/https?:\/\/[^\s'"\\,}]+/);
            try { root.exportedUrl = JSON.parse(xhr.responseText.replace(/'/g, '"')).url; }
            catch (e) { root.exportedUrl = match ? match[0] : ""; }
            root.statusMessage = root.exportedUrl ? "Scan with your phone to view & share:"
                                                  : "Uploaded, but couldn't read the link: " + xhr.responseText;
            qrCanvas.requestPaint();
        };
        xhr.send(payload.buffer);
    }
}
