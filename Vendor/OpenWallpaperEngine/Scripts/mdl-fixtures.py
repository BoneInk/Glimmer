#!/usr/bin/env python3
"""Writes the hand-built .mdl fixtures of MDLParseTests, then their expected decode.

    ./Scripts/mdl-fixtures.py      # Tests/Fixtures/Models/*.mdl, then mdl-reference.py fixtures

One small model per version and section of docs/models-plan.md §1, every optional block present
somewhere, and a few malformed ones (their expected decode is the reference parser's error). The
bytes are laid out as WE's reader reads them (dd-models/re-mdl/FORMAT.md); the values are made up.
The expected decode comes from Scripts/mdl-reference.py, not from this writer. Plain Python 3.
"""
import math
import os
import struct
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(REPO, 'Tests', 'Fixtures', 'Models')
ALL_FORMAT_BITS = 0x3ffffff


class W:
    def __init__(self):
        self.b = bytearray()

    def raw(self, b): self.b += b; return self
    def u8(self, v): return self.raw(struct.pack('<B', v))
    def u16(self, v): return self.raw(struct.pack('<H', v))
    def u32(self, v): return self.raw(struct.pack('<I', v))
    def i32(self, v): return self.raw(struct.pack('<i', v))
    def u64(self, v): return self.raw(struct.pack('<Q', v))
    def f32(self, *v): return self.raw(struct.pack('<%df' % len(v), *v))
    def cstr(self, s): return self.raw(s.encode('utf-8') + b'\0')
    def blob(self, b): return self.u32(len(b)).raw(b)

    def section(self, tag, body):
        """cstr tag, u32 absolute end offset, body."""
        self.cstr(tag)
        end = len(self.b) + 4 + len(body)
        return self.u32(end).raw(body)


STRIDE = {1: 12, 0x10000: 16, 0x2000000: 12, 2: 12, 4: 16, 0x800000: 16, 0x1000000: 16, 8: 8, 0x10: 12, 0x20: 16,
          0x40: 8, 0x80: 12, 0x100: 16, 0x200: 8, 0x400: 12, 0x800: 16, 0x1000: 8, 0x2000: 12, 0x4000: 16,
          0x20000: 8, 0x40000: 12, 0x80000: 16, 0x100000: 8, 0x200000: 12, 0x400000: 16, 0x8000: 16}
ORDER = [1, 0x10000, 0x2000000, 2, 4, 0x800000, 0x1000000, 8, 0x10, 0x20, 0x40, 0x80, 0x100, 0x200, 0x400, 0x800,
         0x1000, 0x2000, 0x4000, 0x20000, 0x40000, 0x80000, 0x100000, 0x200000, 0x400000, 0x8000]


def vertices(fmt, count, seed):
    """Interleaved vertices in table order: every float distinct, blend indices small ints."""
    out = bytearray()
    for v in range(count):
        for bit in ORDER:
            if not fmt & bit:
                continue
            n = STRIDE[bit] // 4
            if bit == 0x800000:
                out += struct.pack('<4I', v % 3, (v + 1) % 3, 0, 1)
            elif bit == 0x1000000:
                out += struct.pack('<4f', 0.5, 0.25, 0.125, 0.125)
            else:
                out += struct.pack('<%df' % n, *[seed + v * 0.5 + bit.bit_length() * 0.01 + k * 0.001 for k in range(n)])
    return bytes(out)


def indices(values, wide):
    return struct.pack('<%d%s' % (len(values), 'I' if wide else 'H'), *values)


def mesh(w, version, materials, fmt, count, flags=0, extra=None, bounds=None, blob1=None, blob16=None, groups=None,
         index_values=None):
    for m in materials:
        w.cstr(m)
    if version >= 4:
        w.u32(flags)
    if flags & 2:
        w.u32(extra)
    if version >= 17:
        w.f32(*bounds)
    if version >= 15:
        w.u32(fmt)
    w.blob(vertices(fmt, count, len(w.b) * 0.001))
    w.blob(indices(index_values or [0, 1, 2], flags & 1))
    if version >= 21:
        if blob1 is None:
            w.u8(0)
        else:
            w.u8(1).u32(1).blob(blob1)
        if blob16 is None:
            w.u8(0)
        else:
            w.u8(1).blob(blob16)
    if version >= 23:
        groups = groups or []
        w.u32(len(groups))
        for gid, name, gflags, a, b in groups:
            w.u64(gid).cstr(name).u32(gflags).u32(len(a))
            for x in a: w.u32(x)
            w.u32(len(b))
            for x in b: w.u32(x)


def header(version, legacy, materials_per_mesh, meshes):
    return W().cstr('MDLV%04d' % version).u32(legacy).u32(materials_per_mesh).u32(meshes)


def matrix(tx, ty, tz, angle=0.0):
    c, s = math.cos(angle), math.sin(angle)
    return [c, s, 0, 0, -s, c, 0, 0, 0, 0, 1, 0, tx, ty, tz, 1]


def bones(w, specs):
    """specs: (name, flags, parent, matrix, props)."""
    w.u32(len(specs))
    for name, flags, parent, m, props in specs:
        w.cstr(name).u32(flags).u32(parent).u32(64).f32(*m).cstr(props)
    return w


SKELETON = [('root', 1, 0xffffffff, matrix(0, 0, 0), ''),
            ('arm', 1, 0, matrix(1, 2, 0, 0.5), '{"se":true}'),
            ('hand', 3, 1, matrix(0.5, 0, 0, -0.25), '')]


def frames(count, seed):
    """count frames of 9 floats: position, Euler xyz (radians), scale."""
    out = []
    for f in range(count):
        t = seed + f
        out += [t, t * 0.5, -t, 0.1 * t, -0.2 * t, 0.3 * t, 1 + 0.01 * t, 1, 1 - 0.01 * t]
    return struct.pack('<%df' % len(out), *out)


def scalars(count, seed):
    return struct.pack('<%df' % count, *[seed + 0.25 * k for k in range(count)])


def skeleton(version, links=0, bind=False, constraints=0, ni=0, iksets=0, has_a=False, has_b=False, has_c=False):
    w = bones(W(), SKELETON)
    nb = len(SKELETON)
    if version < 2:
        return w.b
    w.u16(links)
    for i in range(links):
        w.cstr('link%d' % i).u32(i % nb).u32(i % 2).f32(*matrix(i, 0, 0))
    w.u8(1 if bind else 0)
    if bind:
        for i in range(nb): w.f32(*matrix(0, i, 0))
        for i in range(links): w.f32(*matrix(0, 0, i))
    w.u32(constraints)
    for i in range(constraints):
        w.u32(i % nb).u32(7).u32(8)
        flags = 2 if i % 2 == 0 else 1
        if version >= 4:
            w.u32(flags)
            if flags & 2:
                w.f32(-0.5, 0.75)
    w.u16(ni)
    for i in range(ni): w.u32(100 + i)
    for i in range(ni):
        w.u16(2)
        for k in range(2): w.u32(k).f32(i, k, 0.5)
    w.u16(iksets)
    for i in range(iksets):
        w.u32(2).u32(links)
        for k in range(links): w.u32(k)
        w.u16(1).u32(1).u16(1).u32(2).u32(4).f32(0.1, 0.2).u16(2).u32(0).u32(1)
    w.u8(1 if has_a else 0)
    if has_a:
        for i in range(nb): w.f32(i, i + 1, i + 2).f32(*matrix(i, 0, i + 1))
    w.u8(1 if has_b else 0)
    if has_b:
        for i in range(nb): w.u32(nb - 1 - i)
    if version >= 3:
        w.u8(1 if has_c else 0)
        if has_c:
            for i in range(nb): w.u32(900 + 100 * i)
    return w.b


def animations(version, clips, links=0, constraints=0, meshes=1):
    """clips: (id, name, mode, fps, frames, flags, disabled tracks, events, reference)."""
    nb = len(SKELETON)
    w = W().i32(len(clips))
    for cid, name, mode, fps, count, flags, disabled, events, reference in clips:
        w.u64(cid).cstr(name).cstr(mode).f32(fps).u32(count).u32(flags).i32(nb)
        for t in range(nb):
            w.u32(1 if t in disabled else 0).blob(frames(count + 1, t))
        if version >= 2:
            for i in range(links): w.u32(0).blob(frames(count + 1, 10 + i))
            for i in range(constraints): w.u32(5 + i).blob(scalars(count + 1, i))
        if version >= 3:
            w.u32(1).u32(77).blob(scalars(count + 1, 3))
            w.u8(1)
            for t in range(nb): w.u32(t).blob(scalars(count + 1, 4 + t))
        if version >= 4:
            w.u8(1)
            for m in range(meshes):
                if m == 0:
                    w.u32(1).f32(0.5).u16(1).u16(0).blob(scalars(count + 1, 9))
                else:
                    w.u32(0)
        if version >= 5:
            w.f32(-1, -2, -3, 1, 2, 3)
        if version >= 6:
            w.u8(1)
            for t in range(nb): w.u32(t).blob(scalars(count + 1, 6 + t))
        if flags & 1:
            w.u16(reference).u32(1).u32(2).u32(3).u32(4)
        w.i32(len(events))
        for frame, event in events:
            w.f32(frame).cstr(event)
    return w.b


def terminate(w, fill=b''):
    return bytes(w.cstr('').b) + fill


def write_all():
    files = {}

    w = header(3, 0xb, 1, 1)
    mesh(w, 3, ['materials/old.json'], 0xb, 3)
    files['v3-no-flags.mdl'] = bytes(w.b)

    w = header(4, 0xb, 2, 2)
    mesh(w, 4, ['materials/a.json', 'materials/a_skin1.json'], 0xb, 3)
    mesh(w, 4, ['materials/b.json', 'materials/b_skin1.json'], 0xb, 4, index_values=[0, 1, 2, 2, 3, 0])
    files['v4-static.mdl'] = bytes(w.b)

    w = header(13, 0x1800009, 1, 1)
    mesh(w, 13, ['materials/puppet.json'], 0x1800009, 4, index_values=[0, 1, 2, 2, 3, 0])
    w.section('MDLS0001', skeleton(1))
    w.section('MDLA0001', animations(1, [(439, 'clip', 'mirror', 30, 2, 0, {2}, [], 0)]))
    files['v13-puppet.mdl'] = terminate(w, b'\xcd' * 16 + b'\0' * 48)

    w = header(14, 0x9, 1, 1)
    mesh(w, 14, ['materials/plain.json'], 0x9, 3)
    w.section('XTRA0001', b'\x01\x02\x03 bytes WE skips')
    files['v14-unknown-section.mdl'] = terminate(w)

    w = header(16, 0, 1, 2)
    mesh(w, 16, ['materials/every.json'], ALL_FORMAT_BITS, 2, index_values=[0, 1, 1])
    mesh(w, 16, ['materials/vec4.json'], 0x27, 3)
    files['v16-formats.mdl'] = terminate(w)

    w = header(17, 0, 1, 2)
    mesh(w, 17, ['materials/wide.json'], 0xf, 3, flags=3, extra=0xabcd, bounds=[-1, -2, -3, 4, 5, 6])
    mesh(w, 17, ['materials/narrow.json'], 0xf, 3, flags=4, bounds=[-7, 0, 0, 1, 8, 9])
    files['v17-bounds.mdl'] = terminate(w)

    clips = [(1, 'idle', 'loop', 30, 3, 0, set(), [(1.5, 'step')], 0),
             (2, 'wave', 'single', 7.25, 1, 1, {0}, [], 0)]
    w = header(19, 0, 1, 1)
    mesh(w, 19, ['materials/skinned.json'], 0x180000f, 3, bounds=[0, 0, 0, 1, 1, 1])
    w.section('MDLS0002', skeleton(2, links=2, bind=True, constraints=2, ni=1, iksets=1, has_a=True, has_b=True))
    w.section('MDLA0005', animations(5, clips, links=2, constraints=2))
    files['v19-skeleton.mdl'] = terminate(w)

    blob16 = struct.pack('<12f', *[0.0] * 12)
    w = header(21, 0, 1, 2)
    mesh(w, 21, ['materials/one.json'], 0x180000f, 3, bounds=[0, 0, 0, 1, 1, 1],
         blob1=struct.pack('<9f', *[k * 1.5 for k in range(9)]), blob16=blob16)
    mesh(w, 21, ['materials/two.json'], 0x9, 3, bounds=[0, 0, 0, 2, 1, 1])
    w.section('MDLS0003', skeleton(3, has_a=True, has_b=True, has_c=True))
    w.section('MDLA0006', animations(6, [(5, 'run', 'loop', 60, 2, 0, set(), [], 0)], meshes=2))
    files['v21-skeleton.mdl'] = terminate(w)

    groups = [(0x1122334455667788, 'upper', 1, [0, 1], [2]), (9, 'lower', 0, [], [])]
    w = header(23, 0, 1, 1)
    mesh(w, 23, ['materials/full.json'], 0x181000f, 3, flags=0x3c04, bounds=[-1, -1, -1, 1, 1, 1],
         blob16=blob16, groups=groups)
    w.section('MDLS0004', skeleton(4, links=1, constraints=2))
    w.section('MDAT0001', W().u16(1).u16(2).cstr('правая рука').f32(*matrix(3, 4, 5)).b)
    w.section('MDLA0006', animations(6, [(8, 'blink', 'mirror', 24, 1, 0, set(), [(0, 'start'), (1, 'end')], 0)],
                                     links=1, constraints=2))
    morphs = W().u16(2).f32(1.0).u32(3)
    for t in range(2):
        morphs.u64(40 + t).cstr('shape%d' % t)
        morphs.blob(struct.pack('<9e', *[0.5 * k - t for k in range(9)]))
        morphs.blob(struct.pack('<9e', *[0.25 * k for k in range(9)]))
        morphs.blob(struct.pack('<9e', *[-0.125 * k for k in range(9)]))
        morphs.blob(bytes([1, 2, 3, 4, 5, 6]))
        morphs.u32(1).u32(2).f32(0.5, 4.0)
    w.section('MDMP0001', morphs.b)
    reference = W().u32(64 * len(SKELETON))
    for i, spec in enumerate(SKELETON):
        reference.f32(*(matrix(9, 9, 9) if i == 1 else spec[3]))
    w.section('MDLE0002', reference.b)
    files['v23-full.mdl'] = terminate(w)

    # Malformed: each is rejected by the reference parser.
    w = header(13, 0x9, 1, 0)
    w.section('MDLS0001', W().u32(129).b)
    files['bad-129-bones.mdl'] = terminate(w)

    files['bad-not-mdlv.mdl'] = bytes(W().cstr('MDLX0023').u32(0).u32(0).u32(0).b)

    w = header(13, 0x1800009, 1, 1)
    mesh(w, 13, ['materials/puppet.json'], 0x1800009, 3)
    w.section('MDLS0001', skeleton(1))
    clip = bytearray(animations(1, [(1, 'short', 'loop', 30, 2, 0, set(), [], 0)]))
    track = clip.index(struct.pack('<I', 36 * 3))
    clip[track:track + 4] = struct.pack('<I', 36 * 2)  # one frame too few, the rest shifted
    w.section('MDLA0001', bytes(clip))
    files['bad-track-size.mdl'] = terminate(w)

    w = header(23, 0, 1, 1)
    mesh(w, 23, ['m.json'], 0x9, 3, bounds=[0] * 6, blob16=blob16, groups=[(1, 'g', 0, [3], [])])
    files['bad-group-index.mdl'] = terminate(w)

    w = header(14, 0x9, 1, 1)
    mesh(w, 14, ['m.json'], 0x9, 3)
    w.cstr('MDLS0001').u32(0x7fffffff)
    files['bad-section-end.mdl'] = terminate(w)

    w = header(4, 0x9, 1, 1).cstr('m.json').u32(0).blob(b'\0' * 21).blob(b'')
    files['bad-stride.mdl'] = bytes(w.b)

    w = header(4, 0x9, 1, 1).cstr('m.json').u32(0).u32(0xffffffff)
    files['bad-huge-blob.mdl'] = bytes(w.b)

    w = header(16, 0, 1, 1).cstr('m.json').u32(0).u32(0x4000009).blob(b'').blob(b'')
    files['bad-format-bits.mdl'] = bytes(w.b)

    w = header(13, 0x9, 1, 0)
    w.section('MDLS0001', skeleton(1))
    w.section('MDLA0001', W().i32(1).u64(1).cstr('ref').cstr('loop').f32(30).u32(0).u32(1).i32(3)
              .u32(0).blob(frames(1, 0)).u32(0).blob(frames(1, 0)).u32(0).blob(frames(1, 0))
              .u16(0).u32(0).u32(0).u32(0).u32(0).i32(0).b)
    files['bad-reference-clip.mdl'] = terminate(w)

    os.makedirs(OUT, exist_ok=True)
    for name in os.listdir(OUT):
        if name.endswith('.mdl') and name not in files:
            os.remove(os.path.join(OUT, name))
    for name, data in sorted(files.items()):
        with open(os.path.join(OUT, name), 'wb') as handle:
            handle.write(data)
    print('wrote %d fixtures to %s' % (len(files), os.path.relpath(OUT, REPO)), file=sys.stderr)


if __name__ == '__main__':
    write_all()
    subprocess.check_call([sys.executable, os.path.join(REPO, 'Scripts', 'mdl-reference.py'), 'fixtures'])
