// Runs in a WorkerScript thread: projects can hold tens of thousands of points, and
// serializing them on the UI thread would stall xochitl.
// Files: <dir>/index.json = [{ id, name, updated, frames, thumb }], <dir>/<id>.json = project:
//   (thumb: frame 1's finished ink as [[x, y, x, y, ...]], a few hundred points at most)
//   { id, name, fps, length, layers: [{ name, visible, faded, cels: [{ at, strokes }] }] }
//   (version 1 had frames: [strokes] in place of length and layers; it loads as one layer)
// Strokes are stored compactly: { t: tool, c: color, p: [x, y, w, x, y, w, ...] }.
//
// Messages in:  { op: "list", dir } | { op: "load", dir, id } | { op: "delete", dir, id } (replies "list")
//               | { op: "save", dir, project: { id, name, fps, layers: [{ name, visible, faded, cels: [key | 0] }],
//                                             whole: { key: strokes }, edits: { key: [[at, deleteCount, strokes]] } } }
// A loaded project's drawings are keyed 1..n, layer by layer, as the UI keys them.
// Messages out: { op: "list", index } | { op: "saved", index } | { op: "error", message }
//               | { op: "loaded", project: { id, name, fps, length, layers: [{ name, visible, faded, cels: [strokes | null] }] } }

function request(method, url, body, done) {
    var xhr = new XMLHttpRequest();
    xhr.onreadystatechange = function() {
        if (xhr.readyState === XMLHttpRequest.DONE) done(xhr.status === 200 || xhr.status === 0 ? xhr.responseText : null);
    };
    xhr.open(method, url);
    xhr.send(body);
}

function readIndex(dir, done) {
    request("GET", dir + "/index.json", null, function(text) {
        var index = [];
        try { index = text ? JSON.parse(text) : []; } catch (e) {}
        done(index);
    });
}

function round1(v) { return Math.round(v * 10) / 10; }

function pack(strokes) {
    return strokes.map(function(s) {
        var p = [];
        for (var i = 0; i < s.pts.length; i++) p.push(round1(s.pts[i].x), round1(s.pts[i].y), round1(s.pts[i].w));
        return { t: s.tool, c: s.color, p: p };
    });
}

// The UI sends only drawings edited since its last save; the rest come from here, packed
var saved = { id: "", drawings: {} }; // drawings by key

function unpack(strokes) {
    return strokes.map(function(s) {
        var pts = [];
        for (var i = 0; i < s.p.length; i += 3) pts.push({ x: s.p[i], y: s.p[i + 1], w: s.p[i + 2] });
        return { tool: s.t, color: s.c, pts: pts };
    });
}

function failed(message) { WorkerScript.sendMessage({ op: "error", message: message }); }

var thumbPoints = 300; // about how many points a project list thumbnail keeps

function thumbnail(layers) {
    var strokes = [], total = 0;
    for (var l = layers.length - 1; l >= 0; l--) // bottom layer first; every layer starts with a drawing
        if (layers[l].visible && !layers[l].faded && layers[l].cels.length)
            layers[l].cels[0].strokes.forEach(function(s) { if (s.c === "#000000") { strokes.push(s.p); total += s.p.length / 3; } });
    var step = Math.max(1, Math.ceil(total / thumbPoints));
    return strokes.map(function(p) {
        var out = [];
        for (var i = 0; i < p.length; i += 3 * step) out.push(Math.round(p[i]), Math.round(p[i + 1]));
        out.push(Math.round(p[p.length - 3]), Math.round(p[p.length - 2]));
        return out;
    });
}

WorkerScript.onMessage = function(msg) {
    if (msg.op === "list") {
        readIndex(msg.dir, function(index) { WorkerScript.sendMessage({ op: "list", index: index }); });
    } else if (msg.op === "load") {
        request("GET", msg.dir + "/" + msg.id + ".json", null, function(text) {
            try {
                var project = JSON.parse(text), key = 0;
                if (project.frames) { // version 1: one layer, a drawing on every frame
                    project.length = project.frames.length;
                    project.layers = [{ name: "Layer 1", visible: true,
                                        cels: project.frames.map(function(f, i) { return { at: i, strokes: f }; }) }];
                    delete project.frames;
                }
                saved = { id: project.id, drawings: {} };
                project.layers.forEach(function(l) {
                    var cels = [];
                    for (var i = 0; i < project.length; i++) cels.push(null);
                    l.cels.forEach(function(c) { saved.drawings[++key] = c.strokes; cels[c.at] = unpack(c.strokes); });
                    l.cels = cels;
                });
                WorkerScript.sendMessage({ op: "loaded", project: project });
            } catch (e) {
                failed("Couldn't open that animation");
            }
        });
    } else if (msg.op === "delete") {
        if (saved.id === msg.id) saved = { id: "", drawings: {} };
        // XMLHttpRequest can't remove a file: empty it and drop it from the index
        request("PUT", msg.dir + "/" + msg.id + ".json", "", function() {
            readIndex(msg.dir, function(index) {
                index = index.filter(function(e) { return e.id !== msg.id; });
                request("PUT", msg.dir + "/index.json", JSON.stringify(index), function() {
                    WorkerScript.sendMessage({ op: "list", index: index });
                });
            });
        });
    } else if (msg.op === "save") {
        var p = msg.project, layers = [], kept = {}, length = p.layers[0].cels.length;
        if (saved.id !== p.id) saved = { id: p.id, drawings: {} };
        for (var key in p.whole) saved.drawings[key] = pack(p.whole[key]);
        for (key in p.edits) {
            var d = saved.drawings[key];
            if (!d) return failed("Couldn't save");
            p.edits[key].forEach(function(e) { d.splice.apply(d, [e[0], e[1]].concat(pack(e[2]))); });
        }
        for (var l = 0; l < p.layers.length; l++) {
            var cels = [];
            for (var i = 0; i < length; i++) {
                key = p.layers[l].cels[i];
                if (!key) continue; // held
                if (!saved.drawings[key]) return failed("Couldn't save");
                cels.push({ at: i, strokes: kept[key] = saved.drawings[key] });
            }
            layers.push({ name: p.layers[l].name, visible: p.layers[l].visible, faded: p.layers[l].faded, cels: cels });
        }
        saved.drawings = kept; // forget deleted drawings
        var body = JSON.stringify({ id: p.id, name: p.name, fps: p.fps, length: length, layers: layers });
        request("PUT", msg.dir + "/" + p.id + ".json", body, function(ok) {
            if (ok === null) return failed("Couldn't save");
            readIndex(msg.dir, function(index) {
                index = index.filter(function(e) { return e.id !== p.id; });
                index.unshift({ id: p.id, name: p.name, updated: Date.now(), frames: length, thumb: thumbnail(layers) });
                request("PUT", msg.dir + "/index.json", JSON.stringify(index), function() {
                    WorkerScript.sendMessage({ op: "saved", index: index });
                });
            });
        });
    }
};
