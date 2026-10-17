// Runs in a WorkerScript thread: projects can hold tens of thousands of points, and
// serializing them on the UI thread would stall xochitl.
// Files: <dir>/index.json = [{ id, name, updated, frames }], <dir>/<id>.json = project.
// Strokes are stored compactly: { t: tool, c: color, p: [x, y, w, x, y, w, ...] }.
//
// Messages in:  { op: "list", dir } | { op: "load", dir, id }
//               | { op: "save", dir, project: { id, name, fps, order: [key], changed: { key: strokes } } }
// Messages out: { op: "list", index } | { op: "loaded", project } | { op: "saved", index }
//               | { op: "error", message }

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

// The UI sends only frames edited since its last save; the rest come from here, packed
var saved = { id: "", frames: {} }; // frames by key

function unpack(frames) {
    return frames.map(function(strokes) {
        return strokes.map(function(s) {
            var pts = [];
            for (var i = 0; i < s.p.length; i += 3) pts.push({ x: s.p[i], y: s.p[i + 1], w: s.p[i + 2] });
            return { tool: s.t, color: s.c, pts: pts };
        });
    });
}

WorkerScript.onMessage = function(msg) {
    if (msg.op === "list") {
        readIndex(msg.dir, function(index) { WorkerScript.sendMessage({ op: "list", index: index }); });
    } else if (msg.op === "load") {
        request("GET", msg.dir + "/" + msg.id + ".json", null, function(text) {
            try {
                var project = JSON.parse(text);
                project.frames = unpack(project.frames);
                WorkerScript.sendMessage({ op: "loaded", project: project });
            } catch (e) {
                WorkerScript.sendMessage({ op: "error", message: "Couldn't open that animation" });
            }
        });
    } else if (msg.op === "save") {
        var p = msg.project, frames = [], kept = {};
        if (saved.id !== p.id) saved = { id: p.id, frames: {} };
        for (var key in p.changed) saved.frames[key] = pack(p.changed[key]);
        for (var i = 0; i < p.order.length; i++) {
            var f = saved.frames[p.order[i]];
            if (!f) { WorkerScript.sendMessage({ op: "error", message: "Couldn't save" }); return; }
            frames.push(kept[p.order[i]] = f);
        }
        saved.frames = kept; // forget deleted frames
        var body = JSON.stringify({ id: p.id, name: p.name, fps: p.fps, frames: frames });
        request("PUT", msg.dir + "/" + p.id + ".json", body, function(ok) {
            if (ok === null) { WorkerScript.sendMessage({ op: "error", message: "Couldn't save" }); return; }
            readIndex(msg.dir, function(index) {
                index = index.filter(function(e) { return e.id !== p.id; });
                index.unshift({ id: p.id, name: p.name, updated: Date.now(), frames: frames.length });
                request("PUT", msg.dir + "/index.json", JSON.stringify(index), function() {
                    WorkerScript.sendMessage({ op: "saved", index: index });
                });
            });
        });
    }
};
