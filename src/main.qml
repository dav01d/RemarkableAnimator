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
    // layers[l] = { name, visible, cels: [drawing | null] }: top layer first, one cel per frame;
    //             null holds the layer's drawing from an earlier frame
    // drawing   = { key, rev, canvas, strokes: [stroke], undo: [op], redo: [op], queue: [stroke], full, trash: [Item], dirty, edits }
    //             (rev counts edits, so a thumbnail knows when to redraw)
    // edits     = [[at, deleteCount, [stroke]]] spliced into strokes since the last save, or null: unsaved as a whole
    // stroke    = { tool, color, pts: [{x, y, w}] }
    // op        = { t: "add", s } | { t: "swap", before: [stroke], after: [stroke] }
    // ---------------------------------------------------------------
    property var layers: []
    property int layerCount: 0
    property int currentLayer: 0
    readonly property int maxLayers: 3
    property int frameCount: 0
    property int current: 0
    property int historyRev: 0 // bumped on every edit so Undo/Redo enablement re-evaluates
    property int frameKeys: 0  // last drawing key handed out; the storage worker caches saved drawings by key

    // Tools
    // One pressure-sensitive pen in three sizes: black to finish, light grey to plan.
    // Flip the Marker, or pick the eraser, to erase.
    property string inkColor: "#000000"
    readonly property string planInk: "#c0c0c0"
    property bool eraserTool: false
    property var sizes: [2, 5, 10]
    property int sizeIndex: 1

    // Playback
    property bool isPlaying: false
    property int onionDepth: 2          // how many previous frames show through (0 = off)
    readonly property string nextInk: "#2060c0" // the next drawing's onion skin (blue on colour panels)
    property var fpsOptions: [6, 8, 12, 24]
    property int fpsIndex: 2
    readonly property int fps: fpsOptions[fpsIndex]

    // Pen state streamed by the backend (backend/pen.c): xochitl gives apps the Marker
    // as a plain mouse, so pressure, tilt and the eraser end come from evdev instead
    property real penPressure: 0        // 0..1, 0 = no backend data yet
    property bool penEraser: false
    readonly property bool isRm2: Math.min(Screen.width, Screen.height) === 1404 // its panel's short side (Paper Pro 1620, Move 954)

    AppLoad {
        id: penBackend
        applicationID: "remarkable-animator"
        onMessageReceived: (type, contents) => {
            if (type === 2) return root.wifiShared(contents); // the Wi-Fi share's link, or why it failed
            if (type !== 1) return;
            var v = contents.split(" "); // "pressure tiltX tiltY eraser touching"
            root.penPressure = v[0] / 1000;
            root.penEraser = v[3] === "1";
            if (root.penEraser && root.live) root.liveToEraser();
            // On the reMarkable 2 the pen's release can arrive looking like a palm's, which the
            // canvas refuses; the pen leaving the glass ends the stroke instead
            if (root.isRm2 && v[4] === "0" && (root.live || root.liveErasing)) root.endGesture();
        }
    }

    // Live gesture
    property var live: null             // stroke being drawn, plus tiles: { "col,row": { canvas, segs } }
    // px: size of the Canvas tiles the live stroke is drawn into. Smaller on the reMarkable 2: its
    // panel updates cost more the bigger they are, and wait for overlapping ones still running
    readonly property int liveTile: isRm2 ? 64 : 128
    readonly property int frameTile: isRm2 ? 400 : 100000 // px: parts of a drawing's baked ink (one part off the rM2)
    readonly property int minStep: isRm2 ? 4 : 2 // px between stroke points: half the points on the slower reMarkable 2
    property var eraseOp: null          // { x, y, before, hit } while the eraser is down
    property bool liveErasing: false
    property double moveWaiting: 0      // time of the first pen move not yet on a drawn frame

    // Export
    property string statusMessage: ""
    property string exportedUrl: ""
    property string exportFormat: ""    // "gif" | "svg" | "zip" | "pdf"; empty while choosing
    readonly property var exportFormats: ({ gif: { label: "GIF", file: "flipbook.gif", type: "image/gif" },
                                            svg: { label: "Animated SVG", file: "flipbook.svg", type: "image/svg+xml" },
                                            zip: { label: "SVG frames", file: "flipbook-svg.zip", type: "application/zip" },
                                            pdf: { label: "PDF flipbook", file: "flipbook.pdf", type: "application/pdf" } })
    property bool shareWifi: false      // serve the export from the tablet on Wi-Fi instead of uploading it
    property bool showExportModal: false
    property bool isExporting: false

    // The drawing under the pen: the current layer's at the current frame (its own or a held one)
    readonly property var frame: historyRev >= 0 && current < frameCount ? drawingAt(currentLayer, current) : null
    readonly property bool canUndo: historyRev >= 0 && !!frame && frame.undo.length > 0
    readonly property bool canRedo: historyRev >= 0 && !!frame && frame.redo.length > 0

    onCurrentChanged: refreshLayers()
    onCurrentLayerChanged: refreshLayers()

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
        resetLayers(blankLayers());
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

    onHistoryRevChanged: {
        if (!loading && projectId) saveTimer.restart();
        thumbTimer.restart();
    }

    Timer { id: saveTimer; interval: 2000; onTriggered: root.saveProject() }

    // Timeline thumbnails redraw once the pen has rested, so drawing stays fast
    property int thumbRev: 0
    Timer { id: thumbTimer; interval: 1500; onTriggered: root.thumbRev++ }
    readonly property int thumbStep: 4  // thumbnails draw every 4th point

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
                root.drawings().forEach(d => d.edits = null); // resend everything next save
                if (!root.projectId) root.newProject(); // unreadable save: don't leave the user without a project
            }
        }
    }

    function saveProject() {
        if (!projectId) return;
        saveTimer.stop();
        // Handing strokes to the worker copies them on this thread, so send only what changed since
        // the last save: each drawing's edits, or the whole drawing when that's fewer points to copy
        var t0 = Date.now(), all = drawings(), whole = {}, edits = {}, n = 0, pts = 0;
        for (var i = 0; i < all.length; i++) {
            var f = all[i];
            if (f.edits && !f.edits.length) continue;
            var size = pointCount(f.strokes), changed = f.edits ? f.edits.reduce((c, e) => c + pointCount(e[2]), 0) : Infinity;
            if (changed < size) { edits[f.key] = f.edits; pts += changed; } else { whole[f.key] = f.strokes; pts += size; }
            f.edits = [];
            n++;
        }
        var shape = layers.map(l => ({ name: l.name, visible: l.visible, cels: l.cels.map(d => d ? d.key : 0) }));
        storage.sendMessage({ op: "save", dir: storageDir,
                              project: { id: projectId, name: projectName, fps: fps, layers: shape, whole: whole, edits: edits } });
        console.log("[Animator][perf] save handoff", n, "of", all.length, "drawings,", pts, "pts,", Date.now() - t0, "ms");
    }

    function pointCount(strokes) { return strokes.reduce((c, s) => c + s.pts.length, 0); }

    function newProject() {
        saveProject();
        projectId = "anim-" + Date.now();
        var n = projectIndex.length + 1; // the next number no animation has (some may be deleted)
        while (projectIndex.some(e => e.name === "Animation " + n)) n++;
        projectName = "Animation " + n;
        resetLayers(blankLayers());
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
    property int renameLayer: -1        // the layer being renamed, or -1 for the animation
    readonly property int renameMax: renameLayer < 0 ? 32 : 10 // a layer name fits its header
    property bool kbShift: false        // the next letter is upper case (on again after a space)
    property bool kbNumbers: false      // the keyboard shows digits and symbols

    function startRename(l) {
        renameLayer = l === undefined ? -1 : l;
        renameText = renameLayer < 0 ? projectName : layers[l].name;
        kbShift = false;
        kbNumbers = false;
        showRename = true;
    }

    function typeKey(k) {
        if (renameText.length >= renameMax) return;
        renameText += kbShift ? k.toUpperCase() : k;
        kbShift = k === " ";
    }

    function finishRename() {
        var name = renameText.trim();
        if (name && renameLayer < 0) { projectName = name; saveProject(); }
        else if (name) { layers[renameLayer].name = name; historyRev++; } // autosave
        showRename = false;
    }

    // The list reply then opens the most recent one left (or a new one)
    function deleteProject(id) {
        if (id === projectId) { saveTimer.stop(); projectId = ""; }
        storage.sendMessage({ op: "delete", dir: storageDir, id: id });
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
        resetLayers(p.length ? p.layers : blankLayers());
        if (p.length) drawings().forEach(d => d.edits = []); // the storage worker kept them
        saveProject(); // marks it most recent, so it reopens next launch
    }

    function blankLayers() { return [{ name: "Layer 1", visible: true, cels: [[]] }]; }

    // Replace every layer with the given ones: [{ name, visible, cels: [strokes | null] }]
    function resetLayers(data) {
        loading = true;
        isPlaying = false;
        drawings().forEach(d => d.canvas.destroy());
        layers = [];
        frameKeys = 0; // keys 1..n, layer by layer, as the storage worker keys a project it loads
        for (var l = 0; l < data.length; l++)
            layers.push({ name: data[l].name, visible: data[l].visible, cels: data[l].cels.map(s => s ? newDrawing(s) : null) });
        layerCount = layers.length;
        currentLayer = 0;
        frameCount = data[0].cels.length;
        current = 0;
        refreshLayers();
        historyRev++;
        loading = false;
    }

    // One drawing's baked ink, in Canvas parts so a new stroke repaints only the parts it touches:
    // on the reMarkable 2 a repainted Canvas goes to the panel whole, and the next stroke waits
    // for it. Elsewhere one part covers the stage (frameTile).
    Component {
        id: canvasComp
        Item {
            anchors.fill: parent
            onWidthChanged: root.layoutParts(root.frameOf(this))
            onHeightChanged: root.layoutParts(root.frameOf(this))
        }
    }
    Component {
        id: partComp
        Canvas {
            renderTarget: Canvas.Image
            renderStrategy: Canvas.Immediate
            onAvailableChanged: if (available) requestPaint() // a paint asked for before it was ready did nothing
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
    function newDrawing(strokes) {
        var d = { key: ++frameKeys, rev: 0, strokes: strokes, undo: [], redo: [], parts: [], trash: [], edits: null };
        d.canvas = canvasComp.createObject(stage);
        layoutParts(d);
        return d;
    }

    // Cut the drawing's canvas into parts of frameTile px, each repainted in full
    function layoutParts(f) {
        if (!f) return;
        f.parts.forEach(p => p.canvas.destroy());
        var c = f.canvas, T = frameTile;
        f.parts = [];
        for (var y = 0; y < c.height; y += T)
            for (var x = 0; x < c.width; x += T)
                f.parts.push({ canvas: partComp.createObject(c, { x: x, y: y, width: Math.min(T, c.width - x), height: Math.min(T, c.height - y) }),
                               full: true, dirty: null, queue: [] });
    }

    // A layer always starts with a drawing: if its first frame became a hold, its first drawing moves there
    function keepFirstDrawing(l) {
        var cels = layers[l].cels, i = cels.findIndex(d => d);
        if (i > 0) { cels[0] = cels[i]; cels[i] = null; }
    }

    // The drawing layer l shows at frame i: its own, or the one it holds from an earlier frame
    function drawingAt(l, i) {
        var cels = layers[l].cels;
        while (i >= 0 && !cels[i]) i--;
        return i >= 0 ? cels[i] : null;
    }

    function drawings() {
        var all = [];
        for (var l = 0; l < layers.length; l++) all = all.concat(layers[l].cels.filter(d => d));
        return all;
    }

    // A new frame: a drawing on the current layer (blank or a copy); the other layers hold
    function insertFrame(at, copyFrom) {
        for (var l = 0; l < layers.length; l++) {
            layers[l].cels.splice(at, 0, l === currentLayer ? newDrawing(copyFrom ? copyFrom.strokes.slice() : []) : null);
            keepFirstDrawing(l);
        }
        frameCount = layers[0].cels.length;
        current = at;
        refreshLayers();
        historyRev++;
    }

    function deleteFrame() {
        if (frameCount <= 1) { clearFrame(); return; }
        for (var l = 0; l < layers.length; l++) {
            var cels = layers[l].cels, d = cels.splice(current, 1)[0];
            if (!d) continue;
            if (current < cels.length && !cels[current]) cels[current] = d; // still held in the next frame
            else d.canvas.destroy();
            keepFirstDrawing(l);
        }
        frameCount = layers[0].cels.length;
        current = Math.min(current, frameCount - 1);
        refreshLayers();
        historyRev++;
    }

    function moveFrame(from, to) {
        if (from === to) return;
        for (var l = 0; l < layers.length; l++) {
            layers[l].cels.splice(to, 0, layers[l].cels.splice(from, 1)[0]);
            keepFirstDrawing(l);
        }
        current = to;
        refreshLayers();
        historyRev++; // autosave
    }

    // Hold: the current layer keeps showing its earlier drawing here. Draw: a drawing of its own,
    // starting as a copy of the held one.
    function toggleHold() {
        var cels = layers[currentLayer].cels, d = cels[current];
        if (current === 0) return; // a layer always starts with a drawing
        if (d) { d.canvas.destroy(); cels[current] = null; }
        else cels[current] = newDrawing(frame.strokes.slice());
        refreshLayers();
        historyRev++;
    }

    // A new layer goes on top, with one blank drawing held through the whole animation
    function addLayer() {
        if (layers.length >= maxLayers) return;
        var cels = [newDrawing([])];
        for (var i = 1; i < frameCount; i++) cels.push(null);
        layers.unshift({ name: "Layer " + (layers.length + 1), visible: true, cels: cels });
        layerCount = layers.length;
        currentLayer = 0;
        refreshLayers();
        historyRev++;
    }

    function deleteLayer(l) {
        if (layers.length <= 1) return;
        layers.splice(l, 1)[0].cels.forEach(d => d && d.canvas.destroy());
        layerCount = layers.length;
        currentLayer = Math.min(currentLayer, layerCount - 1);
        refreshLayers();
        historyRev++;
    }

    function toggleLayer(l) {
        layers[l].visible = !layers[l].visible;
        refreshLayers();
        historyRev++;
    }

    function goTo(i) {
        if (i >= 0 && i < frameCount) current = i;
    }

    // Show each visible layer's drawing for the current frame
    function refreshLayers() {
        for (var l = 0; l < layers.length; l++) {
            var shown = layers[l].visible ? drawingAt(l, current) : null, cels = layers[l].cels;
            for (var i = 0; i < cels.length; i++) {
                var d = cels[i];
                if (!d) continue;
                d.canvas.z = -0.1 * l; // upper layers on top, all above the onion skin
                d.canvas.visible = d === shown;
                if (d.canvas.visible) d.parts.forEach(p => { if (pending(p)) p.canvas.requestPaint(); });
                else dropTrash(d); // unbaked ink would float over other frames
            }
        }
        if (onionCanvas.visible) onionCanvas.requestPaint(); // a hidden Canvas still paints: none while playing
        console.log("[Animator][perf] frame", current, "live items", liveLayer.children.length, "rM2", isRm2, Screen.width + "x" + Screen.height);
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
        f.parts.forEach(p => { p.full = true; p.canvas.requestPaint(); });
    }

    // Redraw only one area (the eraser's footprint): much less drawing, and the e-ink
    // panel refreshes a small square instead of the whole frame
    function repaintArea(f, r) {
        if (!f || !f.canvas) return;
        // Strokes still waiting to be drawn may have just been erased; drop the stale
        // copies and redraw their area from the current stroke list instead
        for (var p of f.parts) {
            for (var s of p.queue) p.dirty = p.dirty ? unite(p.dirty, strokeRect(s)) : strokeRect(s);
            p.queue = [];
        }
        for (p of partsIn(f, r)) p.dirty = p.dirty ? unite(p.dirty, r) : r;
        for (p of f.parts) if (p.dirty) markPart(p, p.dirty);
    }

    // The parts of drawing f that overlap r (stage coordinates)
    function partsIn(f, r) {
        return f.parts.filter(p => r.x < p.canvas.x + p.canvas.width && r.x + r.w > p.canvas.x
                                   && r.y < p.canvas.y + p.canvas.height && r.y + r.h > p.canvas.y);
    }
    function pending(p) { return p.full || p.dirty || p.queue.length; }
    function markPart(p, r) { p.canvas.markDirty(Qt.rect(r.x - p.canvas.x, r.y - p.canvas.y, r.w, r.h)); }
    function strokeRect(s) {
        var b = bounds(s);
        return { x: b.x0 - b.w, y: b.y0 - b.w, w: b.x1 - b.x0 + 2 * b.w, h: b.y1 - b.y0 + 2 * b.w };
    }

    function unite(a, b) {
        var x = Math.min(a.x, b.x), y = Math.min(a.y, b.y);
        return { x: x, y: y, w: Math.max(a.x + a.w, b.x + b.w) - x, h: Math.max(a.y + a.h, b.y + b.h) - y };
    }

    // Queue a stroke to be drawn onto the frame image, updating only its own area
    function queueStroke(f, s) {
        var r = strokeRect(s);
        for (var p of partsIn(f, r)) { p.queue.push(s); markPart(p, r); }
    }

    // The live tiles of strokes not baked yet
    function dropTrash(f) {
        for (var j = 0; j < f.trash.length; j++) f.trash[j].destroy();
        f.trash = [];
    }

    // Looked up rather than stored on the Canvas: a JS object assigned to a QML
    // property is copied, so the Canvas would see a stale snapshot
    function frameOf(c) {
        return drawings().find(d => d.canvas === c || d.canvas === c.parent) || null; // a drawing, or one of its parts
    }

    // Draws onto one part of the frame's image: everything after undo/clear, only the dirty
    // area after an erase, then any newly queued strokes
    function paintFrame(c) {
        var f = frameOf(c), p = f && f.parts.find(p => p.canvas === c), ctx = c.getContext("2d");
        if (!p || !ctx) return;
        var t0 = Date.now(), drawn = 0, mode = p.full ? "full" : p.dirty ? "area" : "queue";
        ctx.save();
        ctx.translate(-c.x, -c.y); // strokes are in stage coordinates
        var d = p.full ? { x: c.x, y: c.y, w: c.width, h: c.height } : p.dirty;
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
        if (!p.full) for (var q = 0; q < p.queue.length; q++) drawStroke(ctx, p.queue[q]);
        drawn += p.queue.length;
        ctx.restore();
        p.full = false;
        p.dirty = null;
        p.queue = [];
        // The ink is on the image now, so the live preview dots can go
        if (!f.parts.some(pending)) dropTrash(f);
        var ms = Date.now() - t0;
        if (ms > 10) console.log("[Animator][perf] paint", mode, drawn, "strokes", ms, "ms");
    }

    // Onion skin: the current layer's earlier drawings in lighter greys, each step back half as
    // dark (50%, 25%, 12.5%), and its next drawing in light blue. Baked as solid colors because
    // item opacity is unreliable on e-paper.
    function paintOnion(c) {
        var ctx = c.getContext("2d");
        if (!ctx || !frameCount) return;
        ctx.clearRect(0, 0, c.width, c.height);
        var cels = layers[currentLayer].cels, i = current, earlier = [];
        while (i >= 0 && !cels[i]) i--; // where the drawing on screen starts
        while (--i >= 0 && earlier.length < onionDepth) if (cels[i]) earlier.push(cels[i]);
        for (var back = earlier.length; back >= 1; back--) {
            var f = earlier[back - 1];
            for (var k = 0; k < f.strokes.length; k++) drawStroke(ctx, f.strokes[k], Math.pow(0.5, back));
        }
        var next = cels.slice(current + 1).find(d => d);
        if (next) for (var n = 0; n < next.strokes.length; n++) drawStroke(ctx, next.strokes[n], 0.5, nextInk);
    }

    // A drawing in miniature (thin lines, every few points), centred in the canvas; pts is either
    // [{x, y}] or flat [x, y, ...] (the project list's thumbnails)
    function paintThumb(c, strokes) {
        var ctx = c.getContext("2d");
        if (!ctx) return;
        ctx.reset();
        var k = Math.min(c.width / stage.width, c.height / stage.height);
        ctx.translate((c.width - stage.width * k) / 2, (c.height - stage.height * k) / 2);
        ctx.scale(k, k);
        ctx.lineWidth = 1.5 / k; ctx.lineCap = "round"; ctx.lineJoin = "round";
        for (var i = 0; i < strokes.length; i++) {
            var s = strokes[i], flat = !s.pts, pts = flat ? s : s.pts, n = flat ? pts.length / 2 : pts.length;
            if (!n) continue;
            var at = j => flat ? [pts[2 * j], pts[2 * j + 1]] : [pts[j].x, pts[j].y];
            ctx.strokeStyle = flat ? "black" : s.color;
            ctx.beginPath();
            ctx.moveTo.apply(ctx, at(0));
            for (var j = flat ? 1 : thumbStep; j < n; j += flat ? 1 : thumbStep) ctx.lineTo.apply(ctx, at(j));
            ctx.lineTo.apply(ctx, at(n - 1));
            ctx.stroke();
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

    function drawStroke(ctx, s, strength, tint) {
        var pts = s.pts, color = strength ? fade(tint || s.color, strength) : s.color;
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
        f.rev++;
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
        if (!frame.strokes.length) return;
        if (!layers[currentLayer].cels[current]) toggleHold(); // held: clear a copy, not the earlier frame
        var f = frame;
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

    // Rub out only what the eraser covered moving from (x0, y0) to (x, y): drop the covered
    // points and split the stroke into the pieces that remain (like the notebook app's eraser).
    // One pass per pen move, each point measured once against the whole path: a long scribble
    // is thousands of points, too many to re-check every few pixels on the reMarkable 2
    function eraseAlong(x0, y0, x, y) {
        var R = 16, strokes = frame.strokes, hitAny = false;
        var dx = x - x0, dy = y - y0, len2 = dx * dx + dy * dy;
        var minX = Math.min(x0, x), maxX = Math.max(x0, x), minY = Math.min(y0, y), maxY = Math.max(y0, y);
        for (var i = strokes.length - 1; i >= 0; i--) {
            var s = strokes[i], b = bounds(s), reach = R + b.w / 2;
            if (maxX < b.x0 - reach || minX > b.x1 + reach || maxY < b.y0 - reach || minY > b.y1 + reach) continue;
            var pieces = [], run = [], hit = false;
            for (var j = 0; j < s.pts.length; j++) {
                var p = s.pts[j], r = R + p.w / 2;
                if (p.x > minX - r && p.x < maxX + r && p.y > minY - r && p.y < maxY + r && nearPath(p.x - x0, p.y - y0, dx, dy, len2, r)) {
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
            repaintArea(frame, { x: minX - pad, y: minY - pad, w: maxX - minX + 2 * pad, h: maxY - minY + 2 * pad });
        }
    }

    // Whether a point (px, py), relative to the path's start, is within r of the path (dx, dy)
    function nearPath(px, py, dx, dy, len2, r) {
        var t = len2 && Math.max(0, Math.min(1, (px * dx + py * dy) / len2)), ex = px - t * dx, ey = py - t * dy;
        return ex * ex + ey * ey < r * r;
    }

    // ---------------------------------------------------------------
    // PEN INPUT
    // ---------------------------------------------------------------
    function beginGesture(pt, eraserEnd) {
        if (isPlaying || showExportModal || !frame) return;
        if (live || liveErasing) endGesture(); // its release never came: keep it, don't orphan its tiles
        var x = pt.position.x, y = pt.position.y;
        if (eraserEnd) {
            liveErasing = true;
            eraseOp = { x: x, y: y, before: frame.strokes.slice(), hit: false };
            eraseAlong(x, y, x, y);
            return;
        }
        var p = { x: x, y: y, w: strokeWidth(pt.pressure) };
        live = { tool: "pen", color: inkColor, pts: [p], tiles: {} };
        addSegment(live, p, p);
    }

    // Only the backend knows which end is down, and on the reMarkable 2 its word can come just
    // after the touch (the pen is in range a few ms before it lands): redo the stroke as an erase
    function liveToEraser() {
        var pts = live.pts;
        for (var k in live.tiles) live.tiles[k].canvas.destroy();
        live = null;
        moveWaiting = 0;
        beginGesture({ position: Qt.point(pts[0].x, pts[0].y) }, true);
        for (var i = 1; i < pts.length; i++) moveGestureImpl({ position: Qt.point(pts[i].x, pts[i].y) });
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
            // Erase along the whole path since the last move so fast swipes don't skip strokes
            eraseAlong(eraseOp.x, eraseOp.y, x, y);
            eraseOp.x = x; eraseOp.y = y;
            return;
        }
        if (!live) return;
        var last = live.pts[live.pts.length - 1];
        var dx = x - last.x, dy = y - last.y;
        if (dx * dx + dy * dy < minStep * minStep) return;
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
                        "ms max", live.latMax || 0, "ms,", live.palm || 0, "palm moves refused");
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
        property bool palmGuard: false  // pen only: for buttons where the drawing hand rests
        property int fontSize: 21
        readonly property color ink: on ? "white" : (enabledLook ? "black" : "#aaaaaa")
        signal tap
        signal hold
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
                font.pixelSize: btn.fontSize
                font.bold: true
                color: btn.ink
            }
        }
        TapHandler {
            // palms and fingers are touch; the pen is mouse or stylus to Qt
            acceptedDevices: btn.palmGuard ? PointerDevice.AllDevices & ~PointerDevice.TouchScreen : PointerDevice.AllDevices
            gesturePolicy: TapHandler.ReleaseWithinBounds
            onTapped: btn.tap()
            onLongPressed: btn.hold()
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
            case "hold": // a drawing held along the timeline
                c.rect(4, 11, 14, 14); c.moveTo(18, 18); c.lineTo(32, 18); break;
            case "shift": // an outlined arrow up
                c.moveTo(18, 5); c.lineTo(31, 18); c.lineTo(24, 18); c.lineTo(24, 30); c.lineTo(12, 30);
                c.lineTo(12, 18); c.lineTo(5, 18); c.closePath(); break;
            case "backspace":
                c.moveTo(4, 18); c.lineTo(12, 8); c.lineTo(32, 8); c.lineTo(32, 28); c.lineTo(12, 28); c.closePath();
                c.moveTo(17, 13); c.lineTo(26, 23); c.moveTo(26, 13); c.lineTo(17, 23); break;
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
                    onTap: { root.inkColor = modelData; root.eraserTool = false; }
                    Rectangle { anchors.centerIn: parent; width: 30; height: 30; radius: 6; color: modelData; border.color: "white"; border.width: 2 }
                }
            }
            Btn { icon: "eraser"; flat: true; width: 58; on: root.eraserTool; onTap: root.eraserTool = !root.eraserTool }
            Item { width: 12; height: 1 } // gap between groups
            Btn { icon: "undo"; flat: true; width: 58; enabledLook: root.canUndo; onTap: root.undo() }
            Btn { icon: "redo"; flat: true; width: 58; enabledLook: root.canRedo; onTap: root.redo() }
            Btn { icon: "share"; flat: true; width: 58; onTap: root.chooseExport() }
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
                onVisibleChanged: if (visible) requestPaint()
                onPaint: root.paintOnion(this)
            }
        }
        Item { id: liveLayer; anchors.fill: parent; z: 1 } // pen preview above the frames

        // Tell xochitl which e-ink waveform to use for this region. UFast puts the live stroke
        // (and the eraser's gaps) on the panel noticeably sooner; it's 1-bit, so grey ink settles when Fast takes over.
        // Not on the reMarkable 2: there a switch repaints the whole canvas in software (~200 ms
        // before each stroke shows), and switching often leaves the panel out of step with the app
        DisplayMethodArea {
            anchors.fill: parent
            displayMethod: root.isPlaying ? DisplayMethodArea.Animate
                         : (root.live || root.liveErasing) && !root.isRm2 ? DisplayMethodArea.UFast : DisplayMethodArea.Fast
        }

        // The Marker reaches AppLoad apps as plain (non-synthesized) mouse events. Fingers
        // arrive as synthesized ones; refusing those means palms never draw. The eraser end
        // is reported by the pen backend (or as a non-left button). On the reMarkable 2 a resting
        // palm's moves and releases also reach the stroke, so those are refused too.
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.AllButtons
            preventStealing: true
            onPressed: (m) => {
                if (m.source !== Qt.MouseEventNotSynthesized) { m.accepted = false; return; }
                root.beginGesture({ position: Qt.point(m.x, m.y), pressure: root.penPressure },
                                  root.eraserTool || root.penEraser || m.button !== Qt.LeftButton);
            }
            onPositionChanged: (m) => {
                if (!root.isRm2 || m.source === Qt.MouseEventNotSynthesized) root.moveGesture({ position: Qt.point(m.x, m.y), pressure: root.penPressure });
                else if (root.live) root.live.palm = (root.live.palm || 0) + 1;
            }
            onReleased: (m) => { if (!root.isRm2 || m.source === Qt.MouseEventNotSynthesized) root.endGesture(); }
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

        Row {
            width: parent.width

            // One header per layer: tap to draw on it (again to rename it), hold to delete it; the eye hides it
            Column {
                id: layerHeads
                topPadding: 6; leftPadding: 8
                spacing: 6
                Repeater {
                    model: root.layerCount
                    Row {
                        spacing: 2
                        Btn {
                            palmGuard: true
                            id: layerBtn
                            property bool armed: false
                            width: 130; height: 52
                            label: armed ? "Delete?" : root.historyRev >= 0 && root.layers[index] ? root.layers[index].name : ""
                            on: index === root.currentLayer || armed
                            onTap: {
                                if (armed) { armed = false; root.deleteLayer(index); }
                                else if (index === root.currentLayer) root.startRename(index);
                                else root.currentLayer = index;
                            }
                            onHold: if (root.layerCount > 1) { armed = true; disarmLayer.restart(); }
                            Timer { id: disarmLayer; interval: 3000; onTriggered: layerBtn.armed = false }
                        }
                        Btn {
                            palmGuard: true
                            width: 44; height: 52; flat: true
                            icon: root.historyRev >= 0 && root.layers[index] && root.layers[index].visible ? "eye" : "eye-off"
                            onTap: root.toggleLayer(index)
                        }
                    }
                }
                Btn {
                    palmGuard: true
                    visible: root.layerCount < root.maxLayers
                    width: 176; height: 40
                    label: "+ Layer"
                    onTap: root.addLayer()
                }
            }

            ListView {
                id: strip
                width: parent.width - layerHeads.width
                height: layerHeads.height
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
                interactive: false // the pen scrolls it below; a palm mustn't

                // One column per frame, one cell per layer: a thumbnail where a drawing starts (its
                // number in the corner), a line where the layer holds it
                delegate: Item {
                    id: column
                    property int frameIndex: index
                    y: 6
                    width: 52; height: root.layerCount * 58 - 6
                    Repeater {
                        model: root.layerCount
                        Item {
                            readonly property var cels: root.historyRev >= 0 && root.layers[index] ? root.layers[index].cels : []
                            readonly property bool drawn: root.historyRev >= 0 && !!cels[column.frameIndex] // same array after edits: re-read on each
                            readonly property bool here: column.frameIndex === root.current
                            readonly property bool mine: here && index === root.currentLayer
                            readonly property var drawing: root.historyRev >= 0 && drawn ? cels[column.frameIndex] : null
                            y: index * 58
                            width: 52; height: 52
                            Rectangle { // held: the drawing carries on
                                visible: !parent.drawn
                                x: -3; width: 58; height: 4
                                anchors.verticalCenter: parent.verticalCenter
                                color: "black"
                            }
                            Rectangle {
                                id: cellBox
                                readonly property Item cell: parent
                                visible: cell.drawn || cell.here
                                anchors.fill: parent; radius: 6
                                color: column.frameIndex === strip.dragFrom ? "#bbbbbb" : cell.drawn ? "white" : "transparent"
                                border.color: "black"
                                border.width: strip.dragFrom >= 0 && column.frameIndex === strip.dragTo ? 6 : cell.here ? 4 : 2
                                Canvas {
                                    anchors.fill: parent; anchors.margins: 4
                                    visible: cellBox.cell.drawn
                                    renderTarget: Canvas.Image
                                    // Redraws when its drawing changes: at once for another drawing, after the pen rests for edits
                                    readonly property string stamp: root.thumbRev >= 0 && cellBox.cell.drawing
                                                                    ? cellBox.cell.drawing.key + ":" + cellBox.cell.drawing.rev : ""
                                    onStampChanged: requestPaint()
                                    onPaint: root.paintThumb(this, cellBox.cell.drawing ? cellBox.cell.drawing.strokes : [])
                                }
                                Rectangle { // the drawing's number within its layer; black on the one under the pen
                                    visible: cellBox.cell.drawn
                                    width: Math.max(18, num.implicitWidth + 6); height: 18; radius: 4
                                    color: cellBox.cell.mine ? "black" : "white"
                                    border.color: "black"; border.width: 1
                                    Text {
                                        id: num
                                        anchors.centerIn: parent
                                        text: root.historyRev >= 0 && cellBox.cell.cels.slice(0, column.frameIndex + 1).filter(d => d).length
                                        font.pixelSize: 13; font.bold: true
                                        color: cellBox.cell.mine ? "white" : "black"
                                    }
                                }
                            }
                        }
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
                            if (m.source !== Qt.MouseEventNotSynthesized) { m.accepted = false; return; } // palm
                            pressX = mapToItem(strip, m.x, 0).x;
                            pressContentX = strip.contentX;
                            scrolling = false;
                        }
                        onClicked: (m) => {
                            if (scrolling) return;
                            root.goTo(index);
                            root.currentLayer = Math.max(0, Math.min(root.layerCount - 1, Math.floor(m.y / 58)));
                        }
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
        }

        Bar {
            Btn { palmGuard: true; icon: "prev"; flat: true; onTap: root.goTo(root.current - 1) }
            Btn { palmGuard: true; icon: root.isPlaying ? "stop" : "play"; flat: true; on: root.isPlaying; onTap: root.isPlaying = !root.isPlaying }
            Btn { palmGuard: true; icon: "next"; flat: true; onTap: root.goTo(root.current + 1) }
            Btn { palmGuard: true; icon: "new"; flat: true; onTap: root.insertFrame(root.current + 1, null) }
            Btn { palmGuard: true; icon: "copy"; flat: true; onTap: root.insertFrame(root.current + 1, root.frame) }
            Btn {
                palmGuard: true
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
                palmGuard: true
                id: holdBtn
                property bool armed: false
                readonly property bool held: root.historyRev >= 0 && root.layerCount > 0 && root.current < root.frameCount
                                             && !root.layers[root.currentLayer].cels[root.current]
                icon: "hold"
                label: armed ? "Sure?" : "Hold"
                flat: true
                on: held || armed
                enabledLook: root.current > 0
                onTap: {
                    if (root.current === 0) return;
                    // making a hold drops this frame's own drawing, so ask first if it has ink
                    if (!held && !armed && root.frame.strokes.length) { armed = true; disarmHold.restart(); return; }
                    armed = false;
                    root.toggleHold();
                }
                Timer { id: disarmHold; interval: 3000; onTriggered: holdBtn.armed = false }
            }
            Btn {
                palmGuard: true
                icon: "onion"
                label: root.onionDepth ? root.onionDepth : "Off"
                flat: true
                enabledLook: root.onionDepth > 0
                onTap: root.onionDepth = (root.onionDepth + 1) % 4
            }
            Btn { palmGuard: true; label: root.fps + " fps"; flat: true; onTap: root.fpsIndex = (root.fpsIndex + 1) % root.fpsOptions.length }
            Btn { palmGuard: true; label: "Clear"; flat: true; onTap: root.clearFrame() }
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
            x: 16; y: 16
            width: parent.width - 32
            spacing: 14

            Item {
                width: parent.width; height: 58
                Btn { label: "Cancel"; flat: true; onTap: root.showRename = false }
                Text {
                    anchors.centerIn: parent
                    text: root.renameLayer < 0 ? "Rename animation" : "Rename layer"
                    font.pixelSize: 28; font.bold: true
                }
            }
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
        }

        // Docked at the bottom like reMarkable's: white keys on grey, lower case unless Shift
        Rectangle {
            anchors.bottom: parent.bottom
            width: parent.width
            height: keys.height + 24
            color: "#e0e0e0"
            Column {
                id: keys
                x: 12; y: 12
                width: parent.width - 24
                spacing: 8
                readonly property real keyW: (width - 9 * 8) / 10
                Repeater {
                    model: root.kbNumbers ? ["1234567890", "-/:;()&@'#", ".,?!"] : ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
                    Row {
                        anchors.horizontalCenter: parent.horizontalCenter
                        spacing: 8
                        Btn {
                            visible: index === 2 && !root.kbNumbers
                            icon: "shift"; flat: true; on: root.kbShift
                            width: keys.keyW * 1.5; height: 80
                            onTap: root.kbShift = !root.kbShift
                        }
                        Repeater {
                            model: modelData.split("")
                            Btn {
                                flat: true
                                width: keys.keyW; height: 80; fontSize: 28
                                label: root.kbShift ? modelData.toUpperCase() : modelData
                                onTap: root.typeKey(modelData)
                            }
                        }
                        Btn {
                            visible: index === 2
                            icon: "backspace"; flat: true
                            width: keys.keyW * 1.5; height: 80
                            onTap: root.renameText = root.renameText.slice(0, -1)
                        }
                    }
                }
                Row {
                    spacing: 8
                    Btn {
                        label: root.kbNumbers ? "abc" : "123"; flat: true
                        width: keys.keyW * 1.5; height: 80
                        onTap: root.kbNumbers = !root.kbNumbers
                    }
                    Btn { flat: true; width: keys.width - 3 * keys.keyW - 16; height: 80; onTap: root.typeKey(" ") }
                    Btn { label: "Done"; on: true; width: keys.keyW * 1.5; height: 80; onTap: root.finishRename() }
                }
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
                Btn { icon: "close"; flat: true; onTap: root.showProjects = false }
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
                id: projRow
                property bool armed: false
                width: ListView.view.width
                height: 96
                color: modelData.id === root.projectId ? "#e6e6e6" : "white"
                Canvas { // frame 1 in miniature, kept in the index by the storage worker
                    x: 16; y: 8
                    width: Math.round(height * stage.width / Math.max(1, stage.height)); height: parent.height - 16
                    renderTarget: Canvas.Image
                    onPaint: root.paintThumb(this, modelData.thumb || [])
                    Rectangle { anchors.fill: parent; color: "transparent"; border.color: "#aaaaaa"; border.width: 1 }
                }
                Column {
                    anchors.verticalCenter: parent.verticalCenter
                    x: 136
                    spacing: 4
                    Text { text: modelData.name; font.pixelSize: 26; font.bold: true }
                    Text {
                        text: modelData.frames + (modelData.frames === 1 ? " frame" : " frames") +
                              "  ·  edited " + root.ago(modelData.updated)
                        font.pixelSize: 20; color: "#555555"
                    }
                }
                Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: "#aaaaaa" }
                Item { // tap the row to open it; the trash keeps its own taps
                    width: trash.x; height: parent.height
                    TapHandler { onTapped: root.openProject(modelData.id) }
                }
                Btn {
                    id: trash
                    anchors.right: parent.right; anchors.rightMargin: 16
                    anchors.verticalCenter: parent.verticalCenter
                    icon: "delete"; label: projRow.armed ? "Delete?" : ""
                    flat: true; on: projRow.armed
                    onTap: {
                        if (projRow.armed) root.deleteProject(modelData.id);
                        else { projRow.armed = true; disarmRow.restart(); }
                    }
                    Timer { id: disarmRow; interval: 3000; onTriggered: projRow.armed = false }
                }
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
                    text: !root.exportFormat ? "Share animation" : root.isExporting ? "Exporting..."
                        : root.exportedUrl !== "" ? "Your " + root.exportFormats[root.exportFormat].label + " is ready!" : "Export failed"
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

                Row { // where the link points: an upload, or the tablet itself on Wi-Fi
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: 12
                    visible: !root.exportFormat
                    Btn { label: "Upload link"; on: !root.shareWifi; onTap: root.shareWifi = false }
                    Btn { label: "Wi-Fi (no cloud)"; on: root.shareWifi; onTap: root.shareWifi = true }
                }

                Row { // pick a format
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: 12
                    visible: !root.exportFormat
                    Repeater {
                        model: ["gif", "svg", "zip", "pdf"]
                        Btn { label: root.exportFormats[modelData].label; onTap: root.startExport(modelData) }
                    }
                }

                Row {
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: 20
                    visible: !root.isExporting
                    Btn { label: root.exportedUrl !== "" ? "Done" : "Cancel"; onTap: root.showExportModal = false }
                    Btn { label: "Retry"; on: true; visible: root.exportFormat && root.exportedUrl === ""; onTap: root.startExport(root.exportFormat) }
                }
            }
        }
    }

    // ---------------------------------------------------------------
    // EXPORT PIPELINE
    // ---------------------------------------------------------------
    function chooseExport() {
        isPlaying = false;
        exportFormat = "";
        exportedUrl = "";
        statusMessage = "GIF plays anywhere; SVG and PDF keep the lines sharp (PDF: a page per frame). Planning ink is left out.";
        showExportModal = true;
    }

    function startExport(format) {
        exportFormat = format || "gif";
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
        var frames = [];
        for (var f = 0; f < frameCount; f++) {
            var shown = [];
            for (var l = layers.length - 1; l >= 0; l--) { // bottom layer first
                var d = layers[l].visible ? drawingAt(l, f) : null;
                if (d) shown.push({ name: layers[l].name, strokes: d.strokes.filter(s => !isPlanning(s)) }); // finished ink only
            }
            frames.push(shown);
        }
        exportWorker.sendMessage({ format: exportFormat, frames: frames, W: W, H: H, k: k,
                                   stageW: Math.round(stage.width), stageH: Math.round(stage.height), fps: fps });
    }

    // Where Export uploads: catbox.moe by default (anonymous, no key). A tablet can override it
    // in <storageDir>/settings.json: { "upload": { "url": "...", "field": "...", "params": {} } }.
    // Kept as JSON text and parsed per upload: the tablet's Qt can lose objects nested in a QML
    // property, which dropped catbox's reqtype field (it answered HTTP 412)
    property string uploaderJson: JSON.stringify({ url: "https://catbox.moe/user/api.php", field: "fileToUpload",
                                                   params: { reqtype: "fileupload" } })

    function loadSettings() {
        var xhr = new XMLHttpRequest();
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE || !xhr.responseText) return;
            try {
                var u = JSON.parse(xhr.responseText).upload;
                if (u && u.url) root.uploaderJson = JSON.stringify({ url: u.url, field: u.field || "file", params: u.params || {} });
            } catch (e) {
                console.log("[Animator] ignoring unreadable settings.json:", e);
            }
        };
        xhr.open("GET", storageDir + "/settings.json");
        xhr.send();
    }

    function upload(fileBytes) {
        if (shareWifi) return shareOnWifi(fileBytes);
        var format = exportFormats[exportFormat], uploader = JSON.parse(uploaderJson);
        statusMessage = "Uploading " + format.label + "...";
        var boundary = "----AnimatorBoundary" + Math.random().toString(36).substring(2);
        var head = "";
        for (var key in uploader.params)
            head += "--" + boundary + "\r\nContent-Disposition: form-data; name=\"" + key + "\"\r\n\r\n" +
                    uploader.params[key] + "\r\n";
        head += "--" + boundary + "\r\n" +
                "Content-Disposition: form-data; name=\"" + uploader.field + "\"; filename=\"" + format.file + "\"\r\n" +
                "Content-Type: " + format.type + "\r\n\r\n";
        var foot = "\r\n--" + boundary + "--\r\n";
        var payload = new Uint8Array(head.length + fileBytes.length + foot.length);
        for (var h = 0; h < head.length; h++) payload[h] = head.charCodeAt(h);
        payload.set(fileBytes, head.length);
        for (var b = 0; b < foot.length; b++) payload[head.length + fileBytes.length + b] = foot.charCodeAt(b);

        var xhr = new XMLHttpRequest();
        xhr.open("POST", uploader.url);
        xhr.setRequestHeader("Content-Type", "multipart/form-data; boundary=" + boundary);
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return;
            root.isExporting = false;
            if (xhr.status !== 200 && xhr.status !== 201) {
                // Name the server and quote its reply: a refusal from the tablet (e.g. 412) is otherwise a mystery
                var host = uploader.url.split("/")[2];
                console.log("[Animator] upload to", uploader.url, "failed: HTTP", xhr.status, "
" +
                            xhr.getAllResponseHeaders() + "
" + xhr.responseText.slice(0, 2000));
                root.statusMessage = xhr.status ? "Upload error (HTTP " + xhr.status + " from " + host + "): " +
                                                  xhr.responseText.replace(/<[^>]*>/g, " ").replace(/\s+/g, " ").trim().slice(0, 160)
                                                : "Network error: couldn't reach " + host;
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

    // Wi-Fi share: QML can't listen on a socket, so the pen backend serves the file
    // (backend/share.c). Write it where the backend can read it, then ask for the link.
    function shareOnWifi(fileBytes) {
        var format = exportFormats[exportFormat], file = storageDir + "/" + format.file;
        statusMessage = "Starting the Wi-Fi share...";
        var xhr = new XMLHttpRequest();
        xhr.open("PUT", file);
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return;
            penBackend.sendMessage(2, format.type + " " + decodeURIComponent(file.replace(/^file:\/\//, "")));
            shareTimeout.start();
        };
        xhr.send(new Uint8Array(fileBytes).buffer);
    }

    function wifiShared(reply) {
        shareTimeout.stop();
        isExporting = false;
        var ok = reply.indexOf("http") === 0;
        exportedUrl = ok ? reply : "";
        statusMessage = ok ? "On the same Wi-Fi, scan with your phone. The link works for 10 minutes while Animator stays open:"
                           : reply; // SHARE_TIMEOUT_MS in backend/share.h
        qrCanvas.requestPaint();
    }

    Timer {
        id: shareTimeout
        interval: 5000
        onTriggered: { root.isExporting = false; root.statusMessage = "The tablet's share server didn't answer"; }
    }

    // Startup refresh: the panel keeps a ghost of xochitl's menu, so flash the whole screen
    // black then white on a full-quality waveform, as xochitl does every so often
    readonly property int flashMs: 500  // how long each step of the flash stays up
    Rectangle {
        id: flash
        anchors.fill: parent
        z: 1000
        color: "black"
        DisplayMethodArea { anchors.fill: parent; displayMethod: DisplayMethodArea.Content }
        Timer {
            running: true
            interval: root.flashMs
            repeat: true
            onTriggered: if (flash.color == "#000000") flash.color = "white"; else { flash.visible = false; stop(); }
        }
    }
}
