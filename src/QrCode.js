// QR Code encoder: byte mode, error correction level M, versions 1-40, best mask.
// Follows the structure of Project Nayuki's reference implementation (ISO/IEC 18004).

.pragma library

var ECC_PER_BLOCK = [-1, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26,
                     26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28];
var NUM_BLOCKS = [-1, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16,
                  17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49];
var ECL_FORMAT_BITS = 0; // level M

function bit(x, i) { return ((x >>> i) & 1) !== 0; }

function utf8(s) {
    var enc = encodeURIComponent(s), out = [];
    for (var i = 0; i < enc.length; i++) {
        if (enc[i] === "%") { out.push(parseInt(enc.substr(i + 1, 2), 16)); i += 2; }
        else out.push(enc.charCodeAt(i));
    }
    return out;
}

function numRawDataModules(ver) {
    var result = (16 * ver + 128) * ver + 64;
    if (ver >= 2) {
        var numAlign = Math.floor(ver / 7) + 2;
        result -= (25 * numAlign - 10) * numAlign - 55;
        if (ver >= 7) result -= 36;
    }
    return result;
}

function numDataCodewords(ver) {
    return Math.floor(numRawDataModules(ver) / 8) - ECC_PER_BLOCK[ver] * NUM_BLOCKS[ver];
}

function alignmentPositions(ver, size) {
    if (ver === 1) return [];
    var numAlign = Math.floor(ver / 7) + 2;
    var step = Math.floor((ver * 8 + numAlign * 3 + 5) / (numAlign * 4 - 4)) * 2;
    var result = [6];
    for (var pos = size - 7; result.length < numAlign; pos -= step) result.splice(1, 0, pos);
    return result;
}

// GF(2^8) arithmetic and Reed-Solomon
function gfMul(x, y) {
    var z = 0;
    for (var i = 7; i >= 0; i--) {
        z = (z << 1) ^ ((z >>> 7) * 0x11D);
        z ^= ((y >>> i) & 1) * x;
    }
    return z;
}

function rsDivisor(degree) {
    var result = [];
    for (var i = 0; i < degree - 1; i++) result.push(0);
    result.push(1);
    var root = 1;
    for (i = 0; i < degree; i++) {
        for (var j = 0; j < result.length; j++) {
            result[j] = gfMul(result[j], root);
            if (j + 1 < result.length) result[j] ^= result[j + 1];
        }
        root = gfMul(root, 0x02);
    }
    return result;
}

function rsRemainder(data, divisor) {
    var result = divisor.map(function() { return 0; });
    for (var i = 0; i < data.length; i++) {
        var factor = data[i] ^ result.shift();
        result.push(0);
        for (var j = 0; j < divisor.length; j++) result[j] ^= gfMul(divisor[j], factor);
    }
    return result;
}

function addEccAndInterleave(data, ver) {
    var numBlocks = NUM_BLOCKS[ver], eccLen = ECC_PER_BLOCK[ver];
    var raw = Math.floor(numRawDataModules(ver) / 8);
    var numShort = numBlocks - raw % numBlocks;
    var shortLen = Math.floor(raw / numBlocks);
    var div = rsDivisor(eccLen), blocks = [];
    for (var i = 0, k = 0; i < numBlocks; i++) {
        var dat = data.slice(k, k + shortLen - eccLen + (i < numShort ? 0 : 1));
        k += dat.length;
        var ecc = rsRemainder(dat, div);
        if (i < numShort) dat.push(0);
        blocks.push(dat.concat(ecc));
    }
    var result = [];
    for (i = 0; i < blocks[0].length; i++)
        for (var j = 0; j < blocks.length; j++)
            if (i !== shortLen - eccLen || j >= numShort) result.push(blocks[j][i]);
    return result;
}

function getQRCode(text) {
    var data = utf8(text), ver, capBits;
    for (ver = 1; ver <= 40; ver++) {
        capBits = numDataCodewords(ver) * 8;
        if (4 + (ver < 10 ? 8 : 16) + data.length * 8 <= capBits) break;
    }
    if (ver > 40) throw new Error("Text too long for a QR code");

    // Bit stream: mode, length, payload, terminator, padding
    var bits = [];
    function put(v, n) { for (var i = n - 1; i >= 0; i--) bits.push((v >>> i) & 1); }
    put(4, 4);
    put(data.length, ver < 10 ? 8 : 16);
    for (var i = 0; i < data.length; i++) put(data[i], 8);
    put(0, Math.min(4, capBits - bits.length));
    put(0, (8 - bits.length % 8) % 8);
    for (var pad = 0xEC; bits.length < capBits; pad ^= 0xEC ^ 0x11) put(pad, 8);
    var codewords = [];
    for (i = 0; i < bits.length; i += 8) {
        var v = 0;
        for (var b = 0; b < 8; b++) v = (v << 1) | bits[i + b];
        codewords.push(v);
    }
    var all = addEccAndInterleave(codewords, ver);

    var size = ver * 4 + 17, m = [], fn = [];
    for (var y = 0; y < size; y++) {
        m.push([]); fn.push([]);
        for (var x = 0; x < size; x++) { m[y].push(false); fn[y].push(false); }
    }
    function setF(x, y, dark) { m[y][x] = dark; fn[y][x] = true; }

    // Function patterns
    for (i = 0; i < size; i++) { setF(6, i, i % 2 === 0); setF(i, 6, i % 2 === 0); }
    [[3, 3], [size - 4, 3], [3, size - 4]].forEach(function(c) {
        for (var dy = -4; dy <= 4; dy++)
            for (var dx = -4; dx <= 4; dx++) {
                var d = Math.max(Math.abs(dx), Math.abs(dy)), xx = c[0] + dx, yy = c[1] + dy;
                if (xx >= 0 && xx < size && yy >= 0 && yy < size) setF(xx, yy, d !== 2 && d !== 4);
            }
    });
    var al = alignmentPositions(ver, size), n = al.length;
    for (i = 0; i < n; i++)
        for (var j = 0; j < n; j++) {
            if ((i === 0 && j === 0) || (i === 0 && j === n - 1) || (i === n - 1 && j === 0)) continue;
            for (var dy2 = -2; dy2 <= 2; dy2++)
                for (var dx2 = -2; dx2 <= 2; dx2++)
                    setF(al[i] + dx2, al[j] + dy2, Math.max(Math.abs(dx2), Math.abs(dy2)) !== 1);
        }
    function drawFormat(mask) {
        var d = ECL_FORMAT_BITS << 3 | mask, rem = d;
        for (var i = 0; i < 10; i++) rem = (rem << 1) ^ ((rem >>> 9) * 0x537);
        var fb = (d << 10 | rem) ^ 0x5412;
        for (i = 0; i <= 5; i++) setF(8, i, bit(fb, i));
        setF(8, 7, bit(fb, 6)); setF(8, 8, bit(fb, 7)); setF(7, 8, bit(fb, 8));
        for (i = 9; i < 15; i++) setF(14 - i, 8, bit(fb, i));
        for (i = 0; i < 8; i++) setF(size - 1 - i, 8, bit(fb, i));
        for (i = 8; i < 15; i++) setF(8, size - 15 + i, bit(fb, i));
        setF(8, size - 8, true);
    }
    drawFormat(0); // reserve the area before placing data
    if (ver >= 7) {
        var rem = ver;
        for (i = 0; i < 12; i++) rem = (rem << 1) ^ ((rem >>> 11) * 0x1F25);
        var vb = ver << 12 | rem;
        for (i = 0; i < 18; i++) {
            var a = size - 11 + i % 3, c2 = Math.floor(i / 3);
            setF(a, c2, bit(vb, i)); setF(c2, a, bit(vb, i));
        }
    }

    // Data in zigzag column pairs
    var idx = 0;
    for (var right = size - 1; right >= 1; right -= 2) {
        if (right === 6) right = 5;
        for (var vert = 0; vert < size; vert++)
            for (j = 0; j < 2; j++) {
                x = right - j;
                y = ((right + 1) & 2) === 0 ? size - 1 - vert : vert;
                if (!fn[y][x] && idx < all.length * 8) {
                    m[y][x] = bit(all[idx >>> 3], 7 - (idx & 7));
                    idx++;
                }
            }
    }

    function applyMask(mask) {
        for (var y = 0; y < size; y++)
            for (var x = 0; x < size; x++) {
                if (fn[y][x]) continue;
                var inv;
                switch (mask) {
                case 0: inv = (x + y) % 2 === 0; break;
                case 1: inv = y % 2 === 0; break;
                case 2: inv = x % 3 === 0; break;
                case 3: inv = (x + y) % 3 === 0; break;
                case 4: inv = (Math.floor(x / 3) + Math.floor(y / 2)) % 2 === 0; break;
                case 5: inv = x * y % 2 + x * y % 3 === 0; break;
                case 6: inv = (x * y % 2 + x * y % 3) % 2 === 0; break;
                default: inv = ((x + y) % 2 + x * y % 3) % 2 === 0;
                }
                if (inv) m[y][x] = !m[y][x];
            }
    }

    function penalty() {
        var p = 0, dark = 0;
        var finder = [true, false, true, true, true, false, true];
        for (var pass = 0; pass < 2; pass++)
            for (var a = 0; a < size; a++) {
                var run = 0, prev = null, line = [];
                for (var b = 0; b < size; b++) {
                    var v = pass === 0 ? m[a][b] : m[b][a];
                    line.push(v);
                    if (v === prev) { run++; if (run === 5) p += 3; else if (run > 5) p++; }
                    else { run = 1; prev = v; }
                }
                // Finder-like 1011101 with 4 light modules on either side
                for (b = 0; b + 7 <= size; b++) {
                    var match = true;
                    for (var k = 0; k < 7 && match; k++) match = line[b + k] === finder[k];
                    if (!match) continue;
                    var lightBefore = true, lightAfter = true;
                    for (k = 1; k <= 4; k++) {
                        if (b - k >= 0 && line[b - k]) lightBefore = false;
                        if (b + 6 + k < size && line[b + 6 + k]) lightAfter = false;
                    }
                    if (lightBefore || lightAfter) p += 40;
                }
            }
        for (var y = 0; y < size; y++)
            for (var x = 0; x < size; x++) {
                if (m[y][x]) dark++;
                if (x < size - 1 && y < size - 1) {
                    var c = m[y][x];
                    if (c === m[y][x + 1] && c === m[y + 1][x] && c === m[y + 1][x + 1]) p += 3;
                }
            }
        var total = size * size;
        p += (Math.ceil(Math.abs(dark * 20 - total * 10) / total) - 1) * 10;
        return p;
    }

    var bestMask = 0, best = Infinity;
    for (var mask = 0; mask < 8; mask++) {
        applyMask(mask);
        drawFormat(mask);
        var score = penalty();
        if (score < best) { best = score; bestMask = mask; }
        applyMask(mask); // XOR again to undo
    }
    applyMask(bestMask);
    drawFormat(bestMask);

    return {
        size: size,
        isDark: function(row, col) { return m[row][col]; }
    };
}
