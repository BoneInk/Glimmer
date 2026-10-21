#!/usr/bin/env python3
"""CPU skinning reference for Wallpaper Engine skeletons: the oracle of SkinningReferenceTests.

    ./Scripts/skinning-reference.py pose FILE --clip NAME_OR_ID --times T[,T...] [--out FILE]
    ./Scripts/skinning-reference.py fixtures [--out FILE]   # Tests/Fixtures/Models/skinning.json
    ./Scripts/skinning-reference.py library [--out FILE]    # the library rigs docs/models-plan.md M6 names

Each output line is one model: {"file", "clip", "bones", "poses": [{"time", "clockTime", "frame0",
"frame1", "fraction", "palette": [16 floats per bone], "positions": {mesh index: [x, y, z, ...]}}]}.
Matrices are 16 floats in the .mdl's memory order (a D3D row-vector matrix, translation in 12..14,
which is the column-major memory of the column-vector matrix).

WE's rules (docs/models-plan.md §1.3, §1.4, §2.8), written out independently of the app:
- The clip clock starts at 0 and advances once by `time` (0x1401a9f60): a loop wraps with fmod, a
  mirror turns at its end, a single clip stops at its duration. The clock is float32, as WE's is: at
  1.1 s of a 30 fps clip trunc(t / frameDuration) is 33 but fmod(t, frameDuration) is almost a whole
  frame, so the pose is nearly frame 34's, which double precision would not reproduce.
- f0 = clamp(trunc(t / frameDuration), 0, frames - 1), f1 = min(f0 + 1, frames),
  fraction = fmod(t, frameDuration) / frameDuration (0x140170580).
- Samples are position, Euler xyz (radians), scale; q = qz*qy*qx. Position and scale are lerped,
  the rotation nlerped along the shorter arc. A disabled track keeps the bind transform.
- local = T*R*S; world = world(parent)*local (column vectors); palette = world*inverse(bindWorld).
- A vertex's skinned position is sum_i w_i * palette[index_i] * (p, 1).

Plain Python 3; it reads the .mdl with mdl-reference.py (same folder).
"""
import argparse
import importlib.util
import json
import math
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
FIXTURES = os.path.join(REPO, 'Tests', 'Fixtures', 'Models')

_spec = importlib.util.spec_from_file_location('mdl_reference', os.path.join(HERE, 'mdl-reference.py'))
mdl = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(mdl)

# The rigs M6 checks: (item, file, clip, times). Library files are found through mdl-reference's roots.
LIBRARY = [
    ('3159348391', 'models/pj/pj.mdl', None, [0.25, 1.1, 2.7]),
    ('3159348391', 'models/parappa/parappa.mdl', None, [0.25, 1.1, 2.7]),
    ('3233200129', 'models/sas@Shuffling/sas@Shuffling.mdl', None, [0.25, 1.1, 2.7]),
    ('2515150033', 'models/centurion 1080p_sheet_puppet.mdl', None, [0.0, 1.3, 4.9]),
    ('2321732083', 'models/samurai_puppet.mdl', None, [0.0, 1.3, 4.9]),
]


# ---------------------------------------------------------------- matrices (column-major 16 floats)
def mul(a, b):
    """a*b for column-major 4x4 matrices."""
    out = [0.0] * 16
    for c in range(4):
        for r in range(4):
            out[c * 4 + r] = sum(a[k * 4 + r] * b[c * 4 + k] for k in range(4))
    return out


def inverse(m):
    """General 4x4 inverse (Gauss-Jordan with partial pivoting)."""
    a = [[m[c * 4 + r] for c in range(4)] + [1.0 if r == k else 0.0 for k in range(4)] for r in range(4)]
    for col in range(4):
        pivot = max(range(col, 4), key=lambda r: abs(a[r][col]))
        if abs(a[pivot][col]) < 1e-30:
            raise ValueError('singular bind matrix')
        a[col], a[pivot] = a[pivot], a[col]
        p = a[col][col]
        a[col] = [v / p for v in a[col]]
        for r in range(4):
            if r != col and a[r][col] != 0.0:
                f = a[r][col]
                a[r] = [v - f * w for v, w in zip(a[r], a[col])]
    return [a[r][4 + c] for c in range(4) for r in range(4)]


def transform(m, p):
    return [m[r] * p[0] + m[4 + r] * p[1] + m[8 + r] * p[2] + m[12 + r] for r in range(3)]


def quat_euler(ex, ey, ez):
    """q = qz*qy*qx from half angles (0x1402640c0); (x, y, z, w)."""
    cx, sx = math.cos(ex * 0.5), math.sin(ex * 0.5)
    cy, sy = math.cos(ey * 0.5), math.sin(ey * 0.5)
    cz, sz = math.cos(ez * 0.5), math.sin(ez * 0.5)
    return (sx * cy * cz - cx * sy * sz, cx * sy * cz + sx * cy * sz,
            cx * cy * sz - sx * sy * cz, cx * cy * cz + sx * sy * sz)


def nlerp(a, b, t):
    if sum(x * y for x, y in zip(a, b)) < 0:
        b = tuple(-v for v in b)
    m = [x * (1 - t) + y * t for x, y in zip(a, b)]
    n = math.sqrt(sum(v * v for v in m))
    return tuple(v / n for v in m)


def trs(t, q, s):
    x, y, z, w = q
    r = [1 - 2 * (y * y + z * z), 2 * (x * y + z * w), 2 * (x * z - y * w),
         2 * (x * y - z * w), 1 - 2 * (x * x + z * z), 2 * (y * z + x * w),
         2 * (x * z + y * w), 2 * (y * z - x * w), 1 - 2 * (x * x + y * y)]
    return [r[0] * s[0], r[1] * s[0], r[2] * s[0], 0.0,
            r[3] * s[1], r[4] * s[1], r[5] * s[1], 0.0,
            r[6] * s[2], r[7] * s[2], r[8] * s[2], 0.0,
            t[0], t[1], t[2], 1.0]


# ---------------------------------------------------------------- the clock (0x1401a9f60, 0x140170580)
def f32(x):
    return struct.unpack('<f', struct.pack('<f', x))[0]


def clock_time(mode, duration, time):
    time = f32(time)
    if duration <= 0:
        return 0.0
    if mode == 'single':
        return min(time, duration)
    if mode == 'mirror':
        if time >= duration:
            # One step past the end turns it (the reference only steps once).
            return f32(duration - math.fmod(time, duration))
        return time
    t = time
    if t < 0:
        t = math.fmod(f32(t + duration), duration)
    if t >= duration:
        t = math.fmod(t, duration)
    return t


def sample_position(t, frame_duration, frames):
    last = frames - 1
    truncated = int(f32(t / frame_duration))
    f0 = 0 if min(truncated, last) <= 0 else min(truncated, last)
    f1 = min(f0 + 1, frames)
    return f0, f1, f32(math.fmod(t, frame_duration) / frame_duration)


# ---------------------------------------------------------------- posing
def pose(model, clip, time):
    bones = model['skeleton']['bones']
    parents = []
    for i, b in enumerate(bones):
        p = b['parent']
        parents.append(p if p != 0xFFFFFFFF and p < i else None)
    bind_local = [b['matrix'] for b in bones]
    bind_world = []
    for i in range(len(bones)):
        bind_world.append(bind_local[i] if parents[i] is None else mul(bind_world[parents[i]], bind_local[i]))
    fps, frames = clip['fps'], clip['frames']
    frame_duration = f32(1.0 / fps)
    duration = f32(frames / fps)
    t = clock_time(clip['mode'], duration, time)
    f0, f1, fraction = sample_position(t, frame_duration, frames)
    local = []
    for i in range(len(bones)):
        track = clip['bone_tracks'][i] if i < len(clip['bone_tracks']) else None
        if track is None or track['flags'] & 1:
            local.append(bind_local[i])
            continue
        data = track['data']
        count = len(data) // 9

        def at(f):
            f = max(0, min(f, count - 1))
            v = data[f * 9:f * 9 + 9]
            return v[0:3], quat_euler(v[3], v[4], v[5]), v[6:9]
        pa, qa, sa = at(f0)
        pb, qb, sb = at(f1)
        tr = [a + (b - a) * fraction for a, b in zip(pa, pb)]
        sc = [a + (b - a) * fraction for a, b in zip(sa, sb)]
        local.append(trs(tr, nlerp(qa, qb, fraction), sc))
    world = []
    for i in range(len(bones)):
        world.append(local[i] if parents[i] is None else mul(world[parents[i]], local[i]))
    palette = [mul(w, inverse(b)) for w, b in zip(world, bind_world)]
    return dict(time=time, clockTime=t, frame0=f0, frame1=f1, fraction=fraction,
                palette=[v for m in palette for v in m])


def skin(model, palette):
    out = {}
    nb = len(model['skeleton']['bones'])
    for mi, mesh in enumerate(model['meshes']):
        attrs = mesh.get('vertices', {})
        pos = attrs.get('a_Position') or attrs.get('a_PositionVec4')
        idx, wts = attrs.get('a_BlendIndices'), attrs.get('a_BlendWeights')
        if pos is None or idx is None or wts is None:
            continue
        comps = 4 if 'a_PositionVec4' in attrs and attrs.get('a_Position') is None else 3
        positions = []
        for v in range(mesh['vertex_count']):
            p = pos[v * comps:v * comps + 3]
            acc = [0.0, 0.0, 0.0]
            for k in range(4):
                w, b = wts[v * 4 + k], idx[v * 4 + k]
                if w == 0.0 or b >= nb:
                    continue
                q = transform(palette[b * 16:b * 16 + 16], p)
                acc = [a + w * c for a, c in zip(acc, q)]
            positions.extend(acc)
        out[str(mi)] = positions
    return out


def find_clip(model, name):
    clips = model['animations'] or []
    if name is None:
        return clips[0] if clips else None
    for c in clips:
        if c['name'] == name or str(c['id']) == str(name):
            return c
    return None


def reference(path, data, clip_name, times):
    model = mdl.parse(data, decode=True)
    clip = find_clip(model, clip_name)
    if model['skeleton'] is None or clip is None:
        raise SystemExit('%s: no skeleton or clip %r' % (path, clip_name))
    poses = []
    for t in times:
        p = pose(model, clip, t)
        palette = p['palette']
        p['positions'] = skin(model, palette)
        poses.append(p)
    return dict(file=path, clip=clip['name'], clipID=clip['id'], bones=len(model['skeleton']['bones']), poses=poses)


def library_blob(item, file):
    for root, it, name, blob in mdl.library_files():
        if it == item and name.replace('\\', '/') == file:
            return blob
    return None


def write(entries, out):
    text = ''.join(json.dumps(e, separators=(',', ':')) + '\n' for e in entries)
    if out == '-':
        sys.stdout.write(text)
    else:
        with open(out, 'w', encoding='utf-8') as f:
            f.write(text)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    sub = parser.add_subparsers(dest='command', required=True)
    p = sub.add_parser('pose')
    p.add_argument('file')
    p.add_argument('--clip')
    p.add_argument('--times', required=True)
    p.add_argument('--out', default='-')
    f = sub.add_parser('fixtures')
    f.add_argument('--out', default=os.path.join(FIXTURES, 'skinning.json'))
    lib = sub.add_parser('library')
    lib.add_argument('--out', default='-')
    args = parser.parse_args()
    if args.command == 'pose':
        times = [float(t) for t in args.times.split(',')]
        write([reference(args.file, open(args.file, 'rb').read(), args.clip, times)], args.out)
    elif args.command == 'fixtures':
        path = os.path.join(FIXTURES, 'v13-puppet.mdl')
        entry = reference(os.path.relpath(path, REPO), open(path, 'rb').read(), None, [0.0, 0.05, 0.13])
        write([entry], args.out)
    else:
        entries = []
        for item, file, clip, times in LIBRARY:
            blob = library_blob(item, file)
            if blob is None:
                continue
            entry = reference(file, blob, clip, times)
            entry['item'] = item
            entries.append(entry)
        write(entries, args.out)


if __name__ == '__main__':
    main()
