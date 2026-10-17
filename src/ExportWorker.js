// Runs in a WorkerScript thread: rasterizing and encoding takes seconds on the tablet, and
// doing it on the UI thread stalls xochitl until its watchdog kills it.
// job = { frames: [[stroke]], W, H, k, fps } -> replies { progress } ... then { bytes }

WorkerScript.onMessage = function(job) {
    var gif = createGif(job.W, job.H, job.fps);
    for (var i = 0; i < job.frames.length; i++) {
        WorkerScript.sendMessage({ progress: "Encoding frame " + (i + 1) + " of " + job.frames.length + "..." });
        gif.addFrame(rasterize(job.frames[i], job.W, job.H, job.k));
    }
    WorkerScript.sendMessage({ bytes: gif.getBytes() });
};

// Rasterize one frame into a 1-bit buffer by stamping discs along each stroke
function rasterize(strokes, W, H, k) {
    var px = new Uint8Array(W * H);
    for (var si = 0; si < strokes.length; si++) {
        var s = strokes[si], val = s.color === "#ffffff" ? 0 : 1;
        for (var i = 0; i < s.pts.length; i++) {
            var p = s.pts[i], q = s.pts[Math.max(0, i - 1)];
            var r = Math.max(0.7, p.w * k / 2);
            var steps = Math.max(1, Math.ceil(Math.hypot(p.x - q.x, p.y - q.y) * k / Math.max(0.5, r * 0.6)));
            for (var t = 0; t <= steps; t++) {
                var cx = (q.x + (p.x - q.x) * t / steps) * k, cy = (q.y + (p.y - q.y) * t / steps) * k;
                for (var y = Math.max(0, Math.floor(cy - r)); y <= Math.min(H - 1, Math.ceil(cy + r)); y++)
                    for (var x = Math.max(0, Math.floor(cx - r)); x <= Math.min(W - 1, Math.ceil(cx + r)); x++)
                        if ((x - cx) * (x - cx) + (y - cy) * (y - cy) <= r * r) px[y * W + x] = val;
            }
        }
    }
    return px;
}

// Standalone Minimal Animated GIF Encoder (1-bit / 2-color)
// Generates compliant GIF89a binaries from 2D monochrome pixel buffers

function createGif(width, height, fps) {
    var delayCentis = Math.round(100 / fps);
    var bytes = [];

    function writeByte(b) {
        bytes.push(b & 0xFF);
    }

    function writeWord(w) {
        bytes.push(w & 0xFF);
        bytes.push((w >> 8) & 0xFF);
    }

    function writeString(s) {
        for (var i = 0; i < s.length; i++) {
            bytes.push(s.charCodeAt(i));
        }
    }

    // 1. Header
    writeString("GIF89a");

    // 2. Logical Screen Descriptor
    writeWord(width);
    writeWord(height);
    writeByte(0x80); // GCT present, 1 bit/pixel (2 colors)
    writeByte(0);    // Background color index (0 = white)
    writeByte(0);    // Pixel aspect ratio

    // 3. Global Color Table (2 colors: 0=White, 1=Black)
    writeByte(255); writeByte(255); writeByte(255); // #FFFFFF
    writeByte(0);   writeByte(0);   writeByte(0);   // #000000

    // 4. Netscape 2.0 Loop Extension
    writeByte(0x21); // Extension Introducer
    writeByte(0xFF); // Application Extension Label
    writeByte(11);   // Block Size
    writeString("NETSCAPE2.0");
    writeByte(3);    // Sub-block length
    writeByte(1);    // Loop sub-block ID
    writeWord(0);    // Loop count (0 = infinite)
    writeByte(0);    // Terminator

    return {
        addFrame: function(pixels) {
            // pixels: Uint8Array or Array of length width * height (0 for white, 1 for black)

            // Graphic Control Extension
            writeByte(0x21);
            writeByte(0xF9);
            writeByte(4);    // Block size
            writeByte(0x08); // Disposal: Restore to background color
            writeWord(delayCentis);
            writeByte(0);    // Transparent color index
            writeByte(0);    // Block terminator

            // Image Descriptor
            writeByte(0x2C); // Image separator
            writeWord(0);    // Left
            writeWord(0);    // Top
            writeWord(width);
            writeWord(height);
            writeByte(0x00); // No local color table

            // LZW Compression for 1-bit images
            var minCodeSize = 2;
            writeByte(minCodeSize);

            var clearCode = 1 << minCodeSize; // 4
            var eoiCode = clearCode + 1;       // 5
            var nextCode = eoiCode + 1;        // 6
            var codeSize = minCodeSize + 1;    // 3

            // Dictionary as a trie over the 2-symbol alphabet: child[code * 2 + pixel] holds
            // (next code + 1), 0 = absent. Integer lookups instead of growing string keys.
            var child = new Int16Array(4096 * 2);
            var bitBuf = 0;
            var bitCount = 0;
            var subBlock = [];

            function flushSubBlock() {
                if (subBlock.length > 0) {
                    writeByte(subBlock.length);
                    for (var b = 0; b < subBlock.length; b++) {
                        writeByte(subBlock[b]);
                    }
                    subBlock = [];
                }
            }

            function writeBits(code, bits) {
                bitBuf |= (code << bitCount);
                bitCount += bits;
                while (bitCount >= 8) {
                    subBlock.push(bitBuf & 0xFF);
                    if (subBlock.length === 254) {
                        flushSubBlock();
                    }
                    bitBuf >>= 8;
                    bitCount -= 8;
                }
            }

            function resetTable() {
                for (var i = 0; i < child.length; i++) child[i] = 0;
                codeSize = minCodeSize + 1;
                nextCode = eoiCode + 1;
            }

            resetTable();
            writeBits(clearCode, codeSize);

            var current = pixels[0] ? 1 : 0;

            for (var p = 1; p < pixels.length; p++) {
                var k = pixels[p] ? 1 : 0;
                var next = child[current * 2 + k];

                if (next) {
                    current = next - 1;
                } else {
                    writeBits(current, codeSize);

                    if (nextCode < 4096) {
                        child[current * 2 + k] = nextCode + 1;
                        nextCode++;
                        if (nextCode > (1 << codeSize) && codeSize < 12) {
                            codeSize++;
                        }
                    } else {
                        writeBits(clearCode, codeSize);
                        resetTable();
                    }
                    current = k;
                }
            }

            writeBits(current, codeSize);
            writeBits(eoiCode, codeSize);

            // Flush remaining bits
            if (bitCount > 0) {
                subBlock.push(bitBuf & 0xFF);
            }
            flushSubBlock();
            writeByte(0); // Terminator for image data
        },

        getBytes: function() {
            writeByte(0x3B); // GIF Trailer
            return bytes;
        }
    };
}
