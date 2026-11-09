"""Checks what rollconvert made of a test roll (copies of negative.dng), on macOS.

  python3 mac/Fixtures/check.py <roll folder>

The positive must be a 16-bit sRGB TIFF whose grays come out as the converter's own maths makes them
(the same numbers the web converter and the scripts give), plus a JPEG and a valid Compositor project.
"""
import json, os, re, struct, subprocess, sys, tempfile, zlib

roll = sys.argv[1]
out = os.path.join(roll, 'Positief')
problems = []

def check(ok, message):
    print(('  ok  ' if ok else '  FAIL ') + message)
    if not ok:
        problems.append(message)

def sips(path, *keys):
    args = ['sips']
    for k in keys:
        args += ['-g', k]
    text = subprocess.run(args + [path], capture_output=True, text=True).stdout
    return dict(re.findall(r'^\s+(\w+): (.*)$', text, re.M))

def png(path):
    """Width, height, bit depth and rows of channel values of an RGB(A) PNG."""
    data = open(path, 'rb').read()
    assert data[:8] == b'\x89PNG\r\n\x1a\n'
    i, idat, ihdr = 8, b'', None
    while i < len(data):
        n = struct.unpack('>I', data[i:i + 4])[0]
        kind, body = data[i + 4:i + 8], data[i + 8:i + 8 + n]
        i += 12 + n
        if kind == b'IHDR':
            ihdr = struct.unpack('>IIBBBBB', body)
        elif kind == b'IDAT':
            idat += body
    w, h, depth, ctype = ihdr[:4]
    channels = {2: 3, 6: 4}[ctype]
    bpp = channels * depth // 8
    stride = w * bpp
    raw = zlib.decompress(idat)
    rows, prev = [], bytearray(stride)
    for y in range(h):
        f = raw[y * (stride + 1)]
        line = bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for x in range(stride):
            a = line[x - bpp] if x >= bpp else 0
            b = prev[x]
            c = prev[x - bpp] if x >= bpp else 0
            if f == 1: line[x] = (line[x] + a) & 255
            elif f == 2: line[x] = (line[x] + b) & 255
            elif f == 3: line[x] = (line[x] + (a + b) // 2) & 255
            elif f == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[x] = (line[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        rows.append(line)
        prev = line
    def pixel(x, y):
        o = x * bpp
        if depth == 16:
            return [struct.unpack('>H', rows[y][o + 2 * k:o + 2 * k + 2])[0] / 257 for k in range(3)]
        return [rows[y][o + k] for k in range(3)]
    return w, h, depth, pixel

scans = sorted(f for f in os.listdir(roll) if f.lower().endswith('.dng'))
print(f'{len(scans)} scans in {roll}')
for scan in scans:
    name = scan[:-4]
    tif, jpg, comp = (os.path.join(out, name + ext) for ext in ('.tif', '.jpg', '.comp'))
    check(os.path.isfile(tif) and os.path.isfile(jpg) and os.path.isdir(comp), f'{name}: TIFF, JPEG and Compositor project written')

name = scans[0][:-4]
tif = os.path.join(out, name + '.tif')
info = sips(tif, 'pixelWidth', 'pixelHeight', 'bitsPerSample', 'samplesPerPixel', 'space', 'profile', 'hasAlpha')
print('  TIFF:', info)
check(info.get('bitsPerSample') == '16', 'TIFF is 16-bit')
check(info.get('space') == 'RGB' and info.get('hasAlpha') == 'no', 'TIFF is RGB without alpha')
check('sRGB' in info.get('profile', ''), 'TIFF carries an sRGB profile')
jinfo = sips(os.path.join(out, name + '.jpg'), 'format', 'pixelWidth', 'profile')
check(jinfo.get('format') == 'jpeg' and jinfo.get('pixelWidth') == info.get('pixelWidth'), 'JPEG at full size')

# The positive's grays, as the converter's maths gives them for this test negative (the web converter
# and burke2comp agree): a ramp from black to white, neutral all the way.
with tempfile.TemporaryDirectory() as tmp:
    as_png = os.path.join(tmp, 'positive.png')
    subprocess.run(['sips', '-s', 'format', 'png', tif, '--out', as_png], capture_output=True, check=True)
    w, h, depth, pixel = png(as_png)
    expected = {20: 0, 100: 15, 200: 43, 300: 81, 400: 137, 500: 214, 580: 255}
    for x, value in expected.items():
        rgb = pixel(x, 100)
        check(max(rgb) - min(rgb) <= 3 and all(abs(v - value) <= 3 for v in rgb),
              f'ramp at x={x}: {[round(v) for v in rgb]} ≈ {value} gray')
    red = pixel(150, 300)
    check(red[0] > red[1] + 80 and red[0] > red[2] + 80, f'red patch is red: {[round(v) for v in red]}')

# The Compositor project: the rules Compositor checks before it opens one
comp = os.path.join(out, name + '.comp')
m = json.load(open(os.path.join(comp, 'manifest.json')))
check(m['format'] == 'com.compositor.project' and m['version'] == 12, 'manifest format and version 12')
names = [l['name'] for l in m['layers']]
check(names == ['Scan', 'Inversie', 'Filmbasis', 'Witpunt & kleur', 'Hue/Saturation', 'Contrast'], f'layers {names}')
ids = [l['id'] for l in m['layers']]
check(len(set(ids)) == len(ids) and all(re.fullmatch(r'[0-9A-F-]{36}', i) for i in ids) and m['activeLayerID'] in ids,
      'layer ids are unique uppercase UUIDs')
for l in m['layers']:
    if 'adjustment' in l:
        a = l['adjustment']
        ok = all(k in a for k in ('kind', 'hue', 'saturation', 'lightness', 'colorize', 'levels', 'curves'))
        for points in a['curves']['channels']:
            ok = ok and 2 <= len(points) <= 32 and points[0]['x'] == 0 and points[-1]['x'] == 255
            ok = ok and all(p['x'] < q['x'] for p, q in zip(points, points[1:]))
        check(ok, f'{l["name"]}: a valid adjustment')
    else:
        path = os.path.join(comp, 'images', l['imageFile'])
        check(l['imageFile'] == l['id'] + '.png' and os.path.isfile(path), f'{l["name"]}: image {l["imageFile"]}')
        lw, lh, ldepth, _ = png(path)
        size = (m['width'], m['height']) if l['name'] == 'Scan' else (1, 1)
        check((lw, lh) == size and ldepth == 16, f'{l["name"]}: {lw}×{lh}, {ldepth}-bit')
base = next(l for l in m['layers'] if l['name'] == 'Filmbasis')
check(base['blendMode'] == 'Subtract' and base['opacity'] == 0.8, 'Filmbasis on Subtract at 80%')

print('All checks passed' if not problems else f'{len(problems)} problem(s)')
sys.exit(1 if problems else 0)
