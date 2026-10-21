#!/usr/bin/env python3
"""Reference parser of Wallpaper Engine's .mdl models, and the generator of the test oracle.

    ./Scripts/mdl-reference.py dump FILE... [--inline N] [--out FILE]
    ./Scripts/mdl-reference.py fixtures [--out FILE]      # Tests/Fixtures/Models/expected.json
    ./Scripts/mdl-reference.py library [--known FILE] [--inline N] [--out FILE]
                                                          # Tests/Fixtures/Models/library.json

`dump` prints the decode of each file. `fixtures` decodes the committed fixture models
(`Tests/Fixtures/Models/*.mdl` and WE's vendored `models/editor/camera/camera.mdl`) with every
array inline (WE's camera with the library's limit). `library` decodes every .mdl of the library, loose or inside a `.pkg`: the Workshop
folder (`OWE_WORKSHOP`), OpenWallpaperStorage (`OWE_LIBRARY`), and WE's default projects and
assets (`OWE_WE_INSTALL`, the wallpaper_engine folder). With `--known FILE` (a previous library
output) it decodes only the files that are new or whose bytes changed, which is how
MDLLibrarySweepTests checks the files its committed fixture doesn't cover. Plain Python 3, no
packages.

THE DECODE (what MDLParseTests and MDLLibrarySweepTests compare field for field)

Every field the parser reads, in file order, as JSON. An array of numbers with more than `--inline`
elements (default: all inline for `dump` and `fixtures`, 16 for `library`) is written as
{"count": n, "sha256": hex} of its packed little-endian values: f32 for floats (MDMP's 16-bit signed
normalised values are decoded to f32 first), u32 for integers, u8 for raw bytes. A file the parser rejects is
{"error": {"kind": ..., "message": ...}}; kind is "truncated" (a read past the end),
"not_mdlv", "too_many_bones" or "malformed".

THE PARSER (docs/models-plan.md §1; the spec with addresses is dd-models/re-mdl/FORMAT.md)

The reader in wallpaper64.exe (0x140261880, "CModelLoader"-like). parse(data) -> dict. Strict:
every read is bounds-checked (the binary's reader returns 0 on overrun instead), every section
must end exactly at its stored end offset, and anything after the terminating empty tag must be
zero padding (0x00, or 0xCD then 0x00).

This is mdl.py of that analysis with numpy replaced by the standard library; its output is
identical on all 122 library files.
"""
import argparse
import array
import hashlib
import json
import os
import struct
import sys

assert sys.byteorder == 'little'

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIXTURES = os.path.join(REPO, 'Tests', 'Fixtures', 'Models')
# WE's own models, read from the assets named by OWE_ASSETS and recorded as 'assets:<path>'.
ASSET_MODELS = ['models/editor/camera/camera.mdl']
ASSETS = os.environ.get('OWE_ASSETS', '')

# ---------------------------------------------------------------- vertex format
# Tables at 0x140484a20 (mask), 0x1404849b0 (byte size), 0x140484a90 (GLSL
# attribute name), 0x140482af0 (D3D11_INPUT_ELEMENT_DESC: semantic, index,
# DXGI format).  Attribute order in the interleaved vertex == table order
# (AlignedByteOffset accumulated in table order at 0x1400d81c6..0x1400d8213).
VERTEX_ATTRS = [
    # mask,      size, glsl name,            semantic,       idx, dxgi fmt, (type, n)
    (0x00000001, 12, 'a_Position',         'POSITION',     0, 6,  ('f4', 3)),
    (0x00010000, 16, 'a_PositionVec4',     'POSITION',     0, 2,  ('f4', 4)),
    (0x02000000, 12, 'a_PositionC1',       'POSITION',     1, 6,  ('f4', 3)),
    (0x00000002, 12, 'a_Normal',           'NORMAL',       0, 6,  ('f4', 3)),
    (0x00000004, 16, 'a_Tangent4',         'TANGENT',      0, 2,  ('f4', 4)),
    (0x00800000, 16, 'a_BlendIndices',     'BLENDINDICES', 0, 3,  ('u4', 4)),
    (0x01000000, 16, 'a_BlendWeights',     'BLENDWEIGHT',  0, 2,  ('f4', 4)),
    (0x00000008, 8,  'a_TexCoord',         'TEXCOORD',     0, 16, ('f4', 2)),
    (0x00000010, 12, 'a_TexCoordVec3',     'TEXCOORD',     0, 6,  ('f4', 3)),
    (0x00000020, 16, 'a_TexCoordVec4',     'TEXCOORD',     0, 2,  ('f4', 4)),
    (0x00000040, 8,  'a_TexCoordC1',       'TEXCOORD',     1, 16, ('f4', 2)),
    (0x00000080, 12, 'a_TexCoordVec3C1',   'TEXCOORD',     1, 6,  ('f4', 3)),
    (0x00000100, 16, 'a_TexCoordVec4C1',   'TEXCOORD',     1, 2,  ('f4', 4)),
    (0x00000200, 8,  'a_TexCoordC2',       'TEXCOORD',     2, 16, ('f4', 2)),
    (0x00000400, 12, 'a_TexCoordVec3C2',   'TEXCOORD',     2, 6,  ('f4', 3)),
    (0x00000800, 16, 'a_TexCoordVec4C2',   'TEXCOORD',     2, 2,  ('f4', 4)),
    (0x00001000, 8,  'a_TexCoordC3',       'TEXCOORD',     3, 16, ('f4', 2)),
    (0x00002000, 12, 'a_TexCoordVec3C3',   'TEXCOORD',     3, 6,  ('f4', 3)),
    (0x00004000, 16, 'a_TexCoordVec4C3',   'TEXCOORD',     3, 2,  ('f4', 4)),
    (0x00020000, 8,  'a_TexCoordC4',       'TEXCOORD',     4, 16, ('f4', 2)),
    (0x00040000, 12, 'a_TexCoordVec3C4',   'TEXCOORD',     4, 6,  ('f4', 3)),
    (0x00080000, 16, 'a_TexCoordVec4C4',   'TEXCOORD',     4, 2,  ('f4', 4)),
    (0x00100000, 8,  'a_TexCoordC5',       'TEXCOORD',     5, 16, ('f4', 2)),
    (0x00200000, 12, 'a_TexCoordVec3C5',   'TEXCOORD',     5, 6,  ('f4', 3)),
    (0x00400000, 16, 'a_TexCoordVec4C5',   'TEXCOORD',     5, 2,  ('f4', 4)),
    (0x00008000, 16, 'a_Color',            'COLOR',        0, 2,  ('f4', 4)),
]
KNOWN_FORMAT_BITS = 0
for _a in VERTEX_ATTRS:
    KNOWN_FORMAT_BITS |= _a[0]


def vertex_layout(fmt):
    """[(name, semantic, index, offset, size, (dtype, n))], stride"""
    out, off = [], 0
    for mask, size, name, sem, idx, dxgi, np_t in VERTEX_ATTRS:
        if fmt & mask:
            out.append(dict(name=name, semantic=sem, index=idx, offset=off,
                            size=size, dxgi=dxgi, dtype=np_t[0], comps=np_t[1]))
            off += size
    return out, off


class MDLError(Exception):
    pass


def _array(code, raw):
    a = array.array(code)
    a.frombytes(bytes(raw))
    return a


class Reader:
    """Mirror of the binary's stream reader {base, cur, size, section_end}."""

    def __init__(self, b):
        self.b = b
        self.o = 0
        self.n = len(b)

    def need(self, k, what):
        if self.o + k > self.n:
            raise MDLError('overrun reading %s at 0x%x (+%d > %d)' % (what, self.o, k, self.n))

    def u8(self):  # 0x1402616e0
        self.need(1, 'u8'); v = self.b[self.o]; self.o += 1; return v

    def u16(self):  # 0x140261680
        self.need(2, 'u16'); v = struct.unpack_from('<H', self.b, self.o)[0]; self.o += 2; return v

    def u32(self):  # 0x14009c560
        self.need(4, 'u32'); v = struct.unpack_from('<I', self.b, self.o)[0]; self.o += 4; return v

    def i32(self):
        self.need(4, 'i32'); v = struct.unpack_from('<i', self.b, self.o)[0]; self.o += 4; return v

    def u64(self):  # 0x1402616b0
        self.need(8, 'u64'); v = struct.unpack_from('<Q', self.b, self.o)[0]; self.o += 8; return v

    def f32(self):  # 0x14009c590
        self.need(4, 'f32'); v = struct.unpack_from('<f', self.b, self.o)[0]; self.o += 4; return v

    def fN(self, k):
        self.need(4 * k, 'f32[%d]' % k)
        v = list(struct.unpack_from('<%df' % k, self.b, self.o)); self.o += 4 * k; return v

    def u32N(self, k):
        self.need(4 * k, 'u32[%d]' % k)
        v = _array('I', self.b[self.o:self.o + 4 * k]); self.o += 4 * k; return v

    def mat4(self):  # 0x1400d3ef0 / 0x140261710 with 0x40, or inline 4x movups
        return self.fN(16)

    def capped(self, maxbytes):  # 0x1400d3ef0: u32 length, then min(length, maxbytes) bytes
        if self.o + 4 + maxbytes > self.n:
            raise MDLError('capped read of %d at 0x%x overruns (binary zero-fills)' % (maxbytes, self.o))
        n = struct.unpack_from('<i', self.b, self.o)[0]; self.o += 4
        if n < 0:
            raise MDLError('negative capped length')
        k = min(n, maxbytes)
        v = self.b[self.o:self.o + k]; self.o += k
        return n, v

    def cstr(self):  # 0x14009c500
        e = self.b.find(b'\0', self.o)
        if e < 0:
            raise MDLError('unterminated string at 0x%x' % self.o)
        raw = self.b[self.o:e]; self.o = e + 1
        return raw.decode('utf-8', 'surrogateescape')

    def blob(self):  # 0x14009c5c0: u32 byte length + bytes
        n = self.u32()
        self.need(n, 'blob[%d]' % n)
        v = self.b[self.o:self.o + n]; self.o += n
        return v

    def section_end(self):  # 0x140261770: u32 absolute end offset of the section
        e = self.u32()
        if e > self.n:
            raise MDLError('section end 0x%x beyond file (0x%x)' % (e, self.n))
        return e


def _tagver(tag):
    # 0x1402c82c0 == atoi(tag + 4)
    digits = ''
    for ch in tag[4:]:
        if ch.isdigit(): digits += ch
        else: break
    return int(digits) if digits else 0


# ---------------------------------------------------------------- MDLV
def parse_mdlv(r, decode):
    tag = r.cstr()
    if tag[:4] != 'MDLV':
        raise MDLError('not an MDLV file: %r' % tag[:16])
    ver = _tagver(tag)
    hdr = dict(tag=tag, version=ver)
    hdr['legacy_format'] = r.u32()        # [rsp+0x60]; vertex format when ver < 15
    hdr['materials_per_mesh'] = r.u32()   # [model+0x8]
    hdr['mesh_count'] = r.u32()           # [rbp-0x78]
    meshes = []
    for mi in range(hdr['mesh_count']):
        m = dict(index=mi, offset=r.o)
        m['materials'] = [r.cstr() for _ in range(hdr['materials_per_mesh'])]
        m['flags'] = r.u32() if ver >= 4 else 0      # mesh+0x18
        if m['flags'] & 2:
            m['flags_extra_u32'] = r.u32()            # mesh+0x1c
        if ver >= 17:
            b = r.fN(6)                                 # mesh+0x20..0x34
            m['bounds'] = dict(min=b[:3], max=b[3:])
            m['format'] = r.u32()
        elif ver >= 15:
            m['format'] = r.u32()
        else:
            m['format'] = hdr['legacy_format']
        if m['format'] & ~KNOWN_FORMAT_BITS:
            raise MDLError('unknown vertex format bits 0x%x' % (m['format'] & ~KNOWN_FORMAT_BITS))
        layout, stride = vertex_layout(m['format'])
        m['stride'] = stride
        m['layout'] = [dict(name=a['name'], offset=a['offset'], dtype=a['dtype'], comps=a['comps']) for a in layout]
        vo = r.o + 4
        vb = r.blob()
        io = r.o + 4
        ib = r.blob()
        if stride == 0 or len(vb) % stride:
            raise MDLError('mesh %d: vertex bytes %d not a multiple of stride %d' % (mi, len(vb), stride))
        m['vertex_count'] = len(vb) // stride
        m['vertex_bytes_offset'] = vo
        isz = 4 if m['flags'] & 1 else 2
        m['index_size'] = isz
        if len(ib) % isz:
            raise MDLError('mesh %d: index bytes %d not a multiple of %d' % (mi, len(ib), isz))
        m['index_count'] = len(ib) // isz
        m['index_bytes_offset'] = io
        idx = _array('I' if isz == 4 else 'H', ib)
        m['index_max'] = int(max(idx)) if len(idx) else -1
        if decode:
            m['indices'] = idx
            attrs = {}
            vc = m['vertex_count']
            for a in layout:
                o, s = a['offset'], a['size']
                raw = b''.join(bytes(vb[i * stride + o:i * stride + o + s]) for i in range(vc))
                attrs[a['name']] = _array('I' if a['dtype'] == 'u4' else 'f', raw)
            m['vertices'] = attrs
        if ver >= 21:
            if r.u8():                                   # 0x140261b6b
                m['extra_u32'] = r.u32()                 # read and discarded
                b1 = r.blob()                            # mesh+0x80 size, +0x88 ptr
                m['blob1_bytes'] = len(b1)
                if decode: m['blob1'] = b1
            if r.u8():                                   # 0x140261b9b
                b2 = r.blob()                            # mesh+0xa8 ptr, count=size>>4 at +0xa0
                m['blob16_count'] = len(b2) >> 4
                m['blob16_bytes'] = len(b2)
                if len(b2) & 15:
                    raise MDLError('blob16 size %d not multiple of 16' % len(b2))
                if decode: m['blob16'] = _array('f', b2)
        if ver >= 23:
            n = r.u32()                                  # 0x140261be5
            recs = []
            c16 = m.get('blob16_count', 0)
            for _ in range(n):
                g = dict(id=r.u64(), name=r.cstr())       # rec+0x0 (u64), rec+0x38 (char*)
                g['flags'] = r.u32()                     # rec+0x44; rec+0x40 = (flags&1)?2:1
                k1 = r.u32(); g['list_a'] = r.u32N(k1).tolist()   # rec+0x8 vector<u32>
                k2 = r.u32(); g['list_b'] = r.u32N(k2).tolist()   # rec+0x20 vector<u32>
                for v in g['list_a'] + g['list_b']:
                    if v >= c16:
                        raise MDLError('v23 record index %d >= blob16 count %d' % (v, c16))
                recs.append(g)
            m['groups'] = recs
        meshes.append(m)
    return hdr, meshes


# ---------------------------------------------------------------- MDLS
def parse_mdls(r, sv, end, model):
    sk = dict(version=sv)
    nb = r.u32()                                  # 0x1402624f4
    if nb > 0x80:
        raise MDLError('bone count %d > 128 (binary fast-fails, 0x140262501)' % nb)
    bones = []
    for i in range(nb):
        b = dict(index=i, name=r.cstr())          # bone+0x0 std::string
        b['flags'] = r.u32()                      # bone+0x64
        b['parent'] = r.u32()                     # bone+0x60 (0xffffffff = root)
        n, raw = r.capped(0x40)                   # 0x14026257e: u32 len + <=64 bytes -> bone+0x20
        if n != 64:
            raise MDLError('bone matrix length %d != 64' % n)
        b['matrix'] = list(struct.unpack('<16f', raw))
        b['props_json'] = r.cstr()                # parsed by 0x140265c30 into bone+0x68
        bones.append(b)
    sk['bones'] = bones
    if sv >= 2:
        n2 = r.u16()                              # 0x1402625d5 -> model+0x78, 0x80-byte records
        recs = []
        for i in range(n2):
            e = dict(index=i, name=r.cstr())
            e['bone'] = r.u32()                   # rec+0x60
            e['type'] = r.u32()                   # rec+0x64 (0 -> map model+0x120, 1 -> map model+0x160)
            e['matrix'] = r.mat4()                # rec+0x20
            recs.append(e)
        sk['bone_links'] = recs
        if r.u8():                                # 0x14026273b
            sk['bind_matrices'] = [r.mat4() for _ in range(nb)]     # model+0x48
            sk['link_bind_matrices'] = [r.mat4() for _ in range(n2)]  # model+0x90
        n3 = r.u32()                              # model+0x28
        cons = []
        for _ in range(n3):
            c = dict(bone=r.u32(), a=r.u32(), b=r.u32(), flags=0)
            if c['bone'] >= nb:
                raise MDLError('constraint bone %d >= %d' % (c['bone'], nb))
            if sv >= 4:
                c['flags'] = r.u32()
            if c['flags'] & 2:
                c['f0'] = r.f32(); c['f1'] = r.f32()
            cons.append(c)
        sk['constraints'] = cons
        n4 = r.u16()                              # 0x140262a19
        sk['n4_ids'] = r.u32N(n4).tolist()         # model+0xd8 vector<u32>
        n4maps = []
        for _ in range(n4):
            m = r.u16()
            ent = []
            for _ in range(m):
                k = r.u32(); v = r.fN(3)          # key -> 12 bytes stored at node+0x14
                ent.append((k, v))
            n4maps.append(ent)
        sk['n4_maps'] = n4maps                    # model+0xf0, 64-byte map objects
        n5 = r.u16()                              # 0x140262bfe -> model+0x108
        chains = []
        for i in range(n5):
            ch = dict(bone=r.u32())               # rec+0; bones[bone].0xd4 = i
            if ch['bone'] >= nb:
                raise MDLError('chain bone %d >= %d' % (ch['bone'], nb))
            k = r.u32()
            ch['links'] = r.u32N(k).tolist()      # indices into bone_links (rec+0x20)
            for j in ch['links']:
                if j >= n2:
                    raise MDLError('chain link %d >= %d' % (j, n2))
            k2 = r.u16()
            elems = []
            for _ in range(k2):
                el = dict(bone=r.u32())            # 32-byte element +0
                if el['bone'] >= nb:
                    raise MDLError('chain elem bone %d >= %d' % (el['bone'], nb))
                k3 = r.u16()
                subs = []
                for _ in range(k3):
                    s = dict(bone=r.u32(), flags=r.u32(), f0=r.f32(), f1=r.f32())
                    k4 = r.u16()
                    s['bones'] = r.u32N(k4).tolist()
                    if s['bone'] >= nb or any(x >= nb for x in s['bones']):
                        raise MDLError('chain sub bone out of range')
                    subs.append(s)
                el['subs'] = subs
                elems.append(el)
            ch['elems'] = elems
            chains.append(ch)
        sk['chains'] = chains
        if r.u8():                                # 0x140263430 -> model+0x1a0, 0x4c-byte
            sk['bone_vec3_mat4'] = [(r.fN(3), r.mat4()) for _ in range(nb)]
        if r.u8():                                # 0x14026360d -> model+0x1d0 (clamped to nb-1)
            sk['bone_u32_a'] = r.u32N(nb).tolist()
        if sv >= 3 and r.u8():                    # 0x1402637d6 -> model+0x1e8
            sk['bone_u32_b'] = r.u32N(nb).tolist()
    return sk


# ---------------------------------------------------------------- MDLA
FRAME_FLOATS = 9  # pos xyz, euler xyz (radians, q = qz*qy*qx), scale xyz


def _track(r, frames, per_frame, decode, what):
    size = r.u32()
    r.need(size, what)
    if size != per_frame * (frames + 1):
        raise MDLError('%s: %d bytes != %d*(frames+1=%d)' % (what, size, per_frame, frames + 1))
    raw = r.b[r.o:r.o + size]; r.o += size
    if decode:
        return _array('f', raw)
    return size


def parse_mdla(r, av, end, model, decode):
    nb = len(model['skeleton']['bones']) if model.get('skeleton') else 0
    n2 = len(model['skeleton'].get('bone_links', [])) if model.get('skeleton') else 0
    n3 = len(model['skeleton'].get('constraints', [])) if model.get('skeleton') else 0
    nmesh = model['header']['mesh_count']
    na = r.i32()                                   # 0x1402639b2
    anims = []
    for ai in range(max(na, 0)):
        a = dict(index=ai, offset=r.o)
        a['id'] = r.u64()                          # anim+0x0
        a['name'] = r.cstr()                       # anim+0x8
        a['mode'] = r.cstr()                       # anim+0x28
        a['fps'] = r.f32()                         # anim+0x48
        a['frames'] = r.u32()                      # anim+0x4c
        a['flags'] = r.u32()                       # anim+0x50
        fr = a['frames']
        nt = r.i32()
        tracks = []
        for ti in range(max(nt, 0)):
            tf = r.u32()
            tracks.append(dict(flags=tf, data=_track(r, fr, 36, decode, 'bone track')))
        a['bone_tracks'] = tracks
        if av >= 2:
            a['link_tracks'] = []
            for _ in range(n2):
                tf = r.u32()
                a['link_tracks'].append(dict(flags=tf, data=_track(r, fr, 36, decode, 'link track')))
            a['constraint_tracks'] = []
            for _ in range(n3):
                v = r.u32()
                a['constraint_tracks'].append(dict(value=v, data=_track(r, fr, 4, decode, 'constraint track')))
        if av >= 3:
            k = r.u32()
            a['scalar_tracks_a'] = []
            for _ in range(k):
                v = r.u32()                        # skipped by the binary
                a['scalar_tracks_a'].append(dict(skipped=v, data=_track(r, fr, 4, decode, 'scalar a')))
            if r.u8():
                a['scalar_tracks_b'] = []
                for _ in range(len(tracks)):
                    v = r.u32()
                    a['scalar_tracks_b'].append(dict(skipped=v, data=_track(r, fr, 4, decode, 'scalar b')))
        if av >= 4 and r.u8():
            a['mesh_tracks'] = []
            for _ in range(nmesh):
                mf = r.u32()
                mt = dict(flags=mf)
                if mf & 1:
                    mt['f'] = r.f32()
                    k = r.u16()
                    mt['morph_tracks'] = []
                    for _ in range(k):
                        mi = r.u16()
                        mt['morph_tracks'].append(dict(morph=mi, data=_track(r, fr, 4, decode, 'morph weight')))
                a['mesh_tracks'].append(mt)
        if av >= 5:
            a['bounds'] = r.fN(6)                  # anim+0x54..0x68: AABB min xyz, max xyz
        if av >= 6 and r.u8():
            a['scalar_tracks_c'] = []
            for _ in range(len(tracks)):
                v = r.u32()
                a['scalar_tracks_c'].append(dict(skipped=v, data=_track(r, fr, 4, decode, 'scalar c')))
        if a['flags'] & 1:                          # 0x140264fc9: additive/relative-to-other-anim block
            a['ref'] = dict(anim=r.u16(), u0=r.u32(), u1=r.u32(), u2=r.u32(), u3=r.u32())
            if a['ref']['anim'] >= ai:
                raise MDLError('anim ref %d >= %d' % (a['ref']['anim'], ai))
        ne = r.i32()
        a['events'] = [dict(frame=r.f32(), name=r.cstr()) for _ in range(max(ne, 0))]
        anims.append(a)
    return anims


# ---------------------------------------------------------------- MDAT / MDMP / MDLE
def parse_mdat(r):
    n = r.u16()
    return [dict(bone=r.u16(), name=r.cstr(), matrix=r.mat4()) for _ in range(n)]


def _snorms(raw):
    # 16-bit signed normalised, as WE copies them into its RGBA16 SNORM morph textures (format
    # 0x13 -> DXGI 13, 0x1400d2a4d; MG5): max(v / 32767, -1), rounded to f32 as the app's
    # MDLMorphTargets.float(snormBits:) gives it.
    return [max(struct.unpack('<f', struct.pack('<f', v / 32767.0))[0], -1.0)
            for v in struct.unpack('<%dh' % (len(raw) // 2), raw)]


def parse_mdmp(r, model, decode):
    nb = len(model['skeleton']['bones']) if model.get('skeleton') else 0
    out = []
    for m in model['meshes']:
        n = r.u16()
        mm = dict(mesh=m['index'], count=n, targets=[])
        if n:
            mm['f'] = r.f32()                      # mesh+0x60
            mm['vertex_count'] = r.u32()           # mesh+0x64
            vc = mm['vertex_count']
            for _ in range(n):
                t = dict(id=r.u64(), name=r.cstr())
                p = r.blob()
                vc = min(vc, len(p) // 6)          # 0x14026578f: clamp
                if len(p) != 6 * vc:
                    raise MDLError('morph position blob %d != 6*%d' % (len(p), vc))
                t['position_bytes'] = len(p)
                if decode: t['positions'] = _snorms(p)
                fl = m['flags']
                if fl & 0x400:
                    q = r.blob()
                    if len(q) != 6 * vc: raise MDLError('morph normal blob')
                    t['normal_bytes'] = len(q)
                    if decode: t['normals'] = _snorms(q)
                if fl & 0x800:
                    q = r.blob()
                    if len(q) != 6 * vc: raise MDLError('morph tangent blob')
                    t['tangent_bytes'] = len(q)
                    if decode: t['tangents'] = _snorms(q)
                if fl & 0x1000:
                    q = r.blob()
                    if len(q) != 2 * vc: raise MDLError('morph 2-byte blob')
                    t['u16_bytes'] = len(q)
                    if decode: t['u16'] = bytes(q)
                if fl & 0x2000:
                    t['bone'] = r.u32(); t['u'] = r.u32(); t['f0'] = r.f32(); t['f1'] = r.f32()
                    if t['bone'] >= nb: raise MDLError('morph bone out of range')
                mm['targets'].append(t)
            mm['vertex_count'] = vc
        out.append(mm)
    return out


# ---------------------------------------------------------------- top level
def parse(data, decode=False):
    r = Reader(data)
    hdr, meshes = parse_mdlv(r, decode)
    model = dict(header=hdr, meshes=meshes, sections=[], skeleton=None,
                 animations=None, attachments=None, morphs=None, mdle=None)
    tags = [(0, hdr['tag'])]
    if hdr['version'] < 13:                       # 0x140262382: cmp edi,0xd; jl return
        model['end'] = r.o
        model['trailing_padding'] = len(data) - r.o
        if model['trailing_padding']:
            raise MDLError('%d bytes after v<13 mesh data' % model['trailing_padding'])
        model['tags'] = tags
        return model
    while True:
        to = r.o
        tag = r.cstr()                             # 0x1402623d8 / 0x140265926..0x14026598e
        if tag == '':
            break
        tags.append((to, tag))
        end = r.section_end()                     # 0x140261770
        sec = dict(tag=tag, offset=to, end=end)
        ver = _tagver(tag)
        if tag[:4] == 'MDLS':
            model['skeleton'] = parse_mdls(r, ver, end, model)
        elif tag[:4] == 'MDLA':
            model['animations'] = parse_mdla(r, ver, end, model, decode)
            model['animations_version'] = ver
        elif tag[:8] == 'MDAT0001':
            model['attachments'] = parse_mdat(r)
        elif tag[:8] == 'MDMP0001':
            model['morphs'] = parse_mdmp(r, model, decode)
        elif tag == 'MDLE0002':
            nb = len(model['skeleton']['bones']) if model['skeleton'] else 0
            n, raw = r.capped(nb * 64)             # 0x140265909: u32 len + <= nb*64 bytes -> model+0x60
            if n != nb * 64:
                raise MDLError('MDLE length %d != %d*64' % (n, nb))
            model['mdle'] = [list(struct.unpack_from('<16f', raw, 64 * i)) for i in range(nb)]
        else:
            sec['skipped'] = True
        sec['parsed_end'] = r.o
        if not sec.get('skipped') and r.o != end:
            raise MDLError('section %s parsed to 0x%x but ends at 0x%x' % (tag, r.o, end))
        model['sections'].append(sec)
        r.o = end
    model['tags'] = tags
    model['end'] = r.o
    rest = data[r.o:]
    model['trailing_padding'] = len(rest)
    # Never read by the binary.  Old (MDLV0013-era) writers emitted a fixed 1 MiB / 8 MiB
    # buffer: the tail is 0x00, or 0xCD (MSVC debug-heap "uninitialised" fill) then 0x00.
    nz, ncd = len(rest) - rest.count(0), rest.count(0xCD)
    model['trailing_fill'] = {'00': rest.count(0), 'cd': ncd}
    if nz != ncd:
        raise MDLError('unexpected bytes (not 0x00/0xCD fill) after terminating tag at 0x%x' % r.o)
    return model


# ---------------------------------------------------------------- the decode as JSON
class Dumper:
    """The parse as the JSON the Swift tests rebuild from MDLModel (MDLReferenceDump)."""

    def __init__(self, inline):
        self.inline = inline

    def array(self, values, kind):
        """kind: 'f' (f32), 'I' (u32) or 'B' (u8)."""
        values = values if isinstance(values, array.array) and values.typecode == kind else array.array(kind, values)
        if self.inline is None or len(values) <= self.inline:
            return list(values)
        return {'count': len(values), 'sha256': hashlib.sha256(values.tobytes()).hexdigest()}

    @staticmethod
    def text(s):
        return s.encode('utf-8', 'surrogateescape').decode('utf-8', 'replace')

    def model(self, m):
        h = m['header']
        return {
            'tag': self.text(h['tag']), 'version': h['version'], 'legacy_format': h['legacy_format'],
            'materials_per_mesh': h['materials_per_mesh'], 'bounds': self.bounds(m['meshes']),
            'meshes': [self.mesh(me) for me in m['meshes']],
            'sections': [{'tag': self.text(s['tag']), 'offset': s['offset'], 'end': s['end'],
                          'parsed_end': s['parsed_end'], 'skipped': bool(s.get('skipped'))}
                         for s in m['sections']],
            'skeleton': self.skeleton(m['skeleton']) if m['skeleton'] else None,
            'animations_version': m.get('animations_version'),
            'animations': [self.animation(a) for a in m['animations']] if m['animations'] is not None else None,
            'attachments': [{'bone': a['bone'], 'name': self.text(a['name']), 'matrix': a['matrix']}
                            for a in m['attachments']] if m['attachments'] is not None else None,
            'morphs': [self.morphs(x) for x in m['morphs']] if m['morphs'] is not None else None,
            'reference_pose': self.array([v for x in m['mdle'] for v in x], 'f') if m['mdle'] is not None else None,
            'end': m['end'], 'trailing_bytes': m['trailing_padding'],
        }

    @staticmethod
    def bounds(meshes):
        # 0x1402617c0 then 0x140262345: the union of the mesh boxes (minss/maxss), valid when
        # max.x > min.x; otherwise +-131072.
        f32 = lambda x: struct.unpack('<f', struct.pack('<f', x))[0]
        lo, hi = [f32(3.4028234663852886e38)] * 3, [-f32(3.4028234663852886e38)] * 3
        for me in meshes:
            b = me.get('bounds') or {'min': [0.0] * 3, 'max': [0.0] * 3}
            lo = [a if a < c else c for a, c in zip(b['min'], lo)]
            hi = [a if a > c else c for a, c in zip(b['max'], hi)]
        if meshes and hi[0] > lo[0]:
            return {'min': lo, 'max': hi}
        return {'min': [-131072.0] * 3, 'max': [131072.0] * 3}

    def mesh(self, me):
        out = {
            'materials': [self.text(s) for s in me['materials']], 'flags': me['flags'],
            'flags_extra': me.get('flags_extra_u32'), 'bounds': me.get('bounds'), 'format': me['format'],
            'stride': me['stride'], 'vertex_count': me['vertex_count'], 'index_size': me['index_size'],
            'index_count': me['index_count'],
            'attributes': {a['name']: [a['offset'], self.array(me['vertices'][a['name']], 'I' if a['dtype'] == 'u4' else 'f')]
                           for a in me['layout']},
            'indices': self.array(me['indices'], 'I'),
            'blob1': None, 'blob16': None, 'groups': None,
        }
        if 'blob1' in me:
            out['blob1'] = {'u32': me['extra_u32'], 'bytes': self.array(bytes(me['blob1']), 'B')}
        if 'blob16' in me:
            out['blob16'] = self.array(me['blob16'], 'f')
        if 'groups' in me:
            out['groups'] = [{'id': g['id'], 'name': self.text(g['name']), 'flags': g['flags'],
                              'list_a': self.array(g['list_a'], 'I'), 'list_b': self.array(g['list_b'], 'I')}
                             for g in me['groups']]
        return out

    def skeleton(self, sk):
        out = {
            'version': sk['version'],
            'bones': [{'name': self.text(b['name']), 'flags': b['flags'], 'parent': b['parent'],
                       'matrix': b['matrix'], 'props': self.text(b['props_json'])} for b in sk['bones']],
            'links': None, 'bind_matrices': None, 'link_bind_matrices': None, 'constraints': None,
            'ni_ids': None, 'ni_maps': None, 'ik_sets': None, 'bone_vectors': None,
            'bone_u32_a': None, 'bone_u32_b': None,
        }
        if sk['version'] >= 2:
            out['links'] = [{'name': self.text(e['name']), 'bone': e['bone'], 'type': e['type'], 'matrix': e['matrix']}
                            for e in sk['bone_links']]
            if 'bind_matrices' in sk:
                out['bind_matrices'] = self.array([v for x in sk['bind_matrices'] for v in x], 'f')
                out['link_bind_matrices'] = self.array([v for x in sk['link_bind_matrices'] for v in x], 'f')
            out['constraints'] = [{'bone': c['bone'], 'a': c['a'], 'b': c['b'], 'flags': c['flags'],
                                   'f0': c.get('f0'), 'f1': c.get('f1')} for c in sk['constraints']]
            out['ni_ids'] = self.array(sk['n4_ids'], 'I')
            out['ni_maps'] = [[[k, v] for k, v in ent] for ent in sk['n4_maps']]
            out['ik_sets'] = [{'bone': c['bone'], 'links': self.array(c['links'], 'I'),
                               'elements': [{'bone': e['bone'],
                                             'joints': [{'bone': s['bone'], 'flags': s['flags'], 'f0': s['f0'],
                                                         'f1': s['f1'], 'bones': self.array(s['bones'], 'I')}
                                                        for s in e['subs']]}
                                            for e in c['elems']]}
                              for c in sk['chains']]
            if 'bone_vec3_mat4' in sk:
                out['bone_vectors'] = self.array([v for vec, mat in sk['bone_vec3_mat4'] for v in vec + mat], 'f')
            if 'bone_u32_a' in sk:
                out['bone_u32_a'] = self.array(sk['bone_u32_a'], 'I')
            if 'bone_u32_b' in sk:
                out['bone_u32_b'] = self.array(sk['bone_u32_b'], 'I')
        return out

    def tracks(self, tracks, key):
        return {key: self.array([t[key] for t in tracks], 'I'),
                'samples': self.array([v for t in tracks for v in t['data']], 'f')}

    def animation(self, a):
        out = {
            'id': a['id'], 'name': self.text(a['name']), 'mode': self.text(a['mode']), 'fps': a['fps'],
            'frames': a['frames'], 'flags': a['flags'], 'bone_tracks': self.tracks(a['bone_tracks'], 'flags'),
            'link_tracks': None, 'constraint_tracks': None, 'scalar_tracks_a': None, 'scalar_tracks_b': None,
            'mesh_tracks': None, 'bounds': a.get('bounds'), 'scalar_tracks_c': None, 'reference': a.get('ref'),
            'events': [{'frame': e['frame'], 'name': self.text(e['name'])} for e in a['events']],
        }
        if 'link_tracks' in a:
            out['link_tracks'] = self.tracks(a['link_tracks'], 'flags')
            out['constraint_tracks'] = self.tracks(a['constraint_tracks'], 'value')
        for key in ('scalar_tracks_a', 'scalar_tracks_b', 'scalar_tracks_c'):
            if key in a:
                out[key] = self.tracks(a[key], 'skipped')
        if 'mesh_tracks' in a:
            out['mesh_tracks'] = [{'flags': mt['flags'], 'f': mt.get('f'),
                                   'morph_tracks': [{'morph': t['morph'], 'samples': self.array(t['data'], 'f')}
                                                    for t in mt['morph_tracks']] if 'morph_tracks' in mt else None}
                                  for mt in a['mesh_tracks']]
        return out

    def morphs(self, mm):
        out = {'mesh': mm['mesh'], 'f': mm.get('f'), 'vertex_count': mm.get('vertex_count'), 'targets': []}
        for t in mm['targets']:
            out['targets'].append({
                'id': t['id'], 'name': self.text(t['name']), 'positions': self.array(t['positions'], 'f'),
                'normals': self.array(t['normals'], 'f') if 'normals' in t else None,
                'tangents': self.array(t['tangents'], 'f') if 'tangents' in t else None,
                'u16': self.array(t['u16'], 'B') if 'u16' in t else None,
                'modifier': {'bone': t['bone'], 'mode': t['u'], 'f0': t['f0'], 'f1': t['f1']} if 'bone' in t else None,
            })
        return out


def error_kind(message):
    if message.startswith('overrun') or message.startswith('unterminated') or 'overruns' in message:
        return 'truncated'
    if message.startswith('not an MDLV'):
        return 'not_mdlv'
    if message.startswith('bone count'):
        return 'too_many_bones'
    return 'malformed'


def decode(data, inline):
    try:
        return Dumper(inline).model(parse(data, decode=True))
    except MDLError as e:
        return {'error': {'kind': error_kind(str(e)), 'message': str(e)}}


def encode(value):
    return json.dumps(value, ensure_ascii=False, allow_nan=False, separators=(',', ':'))


# ---------------------------------------------------------------- library
def roots():
    we = os.environ.get('OWE_WE_INSTALL') or \
        '/Volumes/980Pro/Crossover/bottles/Steam Bottle/drive_c/Program Files (x86)/Steam/steamapps/common/wallpaper_engine'
    return [
        ('workshop', os.environ.get('OWE_WORKSHOP')
         or '/Volumes/980Pro/Crossover/bottles/Steam Bottle/drive_c/Program Files (x86)/Steam/steamapps/workshop/content/431960'),
        ('storage', os.environ.get('OWE_LIBRARY') or '/Volumes/980Pro/OpenWallpaperStorage'),
        ('default', os.path.join(we, 'projects', 'defaultprojects')),
        ('assets', os.path.join(we, 'assets')),
    ]


def read_pkg(path):
    data = open(path, 'rb').read()
    offset = 4 + struct.unpack_from('<I', data, 0)[0]
    count = struct.unpack_from('<I', data, offset)[0]
    offset += 4
    entries = []
    for _ in range(count):
        size = struct.unpack_from('<I', data, offset)[0]
        offset += 4
        name = data[offset:offset + size].decode('utf-8', 'replace')
        offset += size
        start, length = struct.unpack_from('<II', data, offset)
        offset += 8
        entries.append((name, start, length))
    return [(name, data[offset + start:offset + start + length]) for name, start, length in entries]


def library_files():
    """(root, item, file, bytes) of every .mdl: `file` is item-relative, `x.pkg::entry` inside a
    package. The assets root has no items: its item is "-" and every .mdl under it is listed."""
    for root, path in roots():
        if not os.path.isdir(path):
            continue
        if root == 'assets':
            for d, _, names in sorted(os.walk(path)):
                for f in sorted(names):
                    if f.endswith('.mdl'):
                        p = os.path.join(d, f)
                        yield root, '-', os.path.relpath(p, path), open(p, 'rb').read()
            continue
        for item in sorted(os.listdir(path)):
            base = os.path.join(path, item)
            if not os.path.isdir(base):
                continue
            files = sorted(os.path.relpath(os.path.join(d, f), base) for d, _, names in os.walk(base) for f in names)
            for rel in files:
                if rel.endswith('.pkg'):
                    try:
                        entries = read_pkg(os.path.join(base, rel))
                    except (OSError, struct.error) as error:
                        print('error: %s/%s: %s' % (item, rel, error), file=sys.stderr)
                        continue
                    for name, blob in sorted(entries, key=lambda e: e[0]):
                        if name.endswith('.mdl'):
                            yield root, item, rel + '::' + name, blob
                elif rel.endswith('.mdl'):
                    with open(os.path.join(base, rel), 'rb') as handle:
                        yield root, item, rel, handle.read()


def write(lines, out, what):
    text = '[\n' + ',\n'.join(lines) + '\n]\n'
    if out == '-':
        sys.stdout.write(text)
    else:
        with open(out, 'w', encoding='utf-8') as handle:
            handle.write(text)
        print('wrote %s (%d %s)' % (out, len(lines), what), file=sys.stderr)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    sub = parser.add_subparsers(dest='command', required=True)
    d = sub.add_parser('dump')
    d.add_argument('files', nargs='+')
    d.add_argument('--inline', type=int)
    d.add_argument('--out', default='-')
    f = sub.add_parser('fixtures')
    f.add_argument('--out', default=os.path.join(FIXTURES, 'expected.json'))
    lib = sub.add_parser('library')
    lib.add_argument('--known')
    lib.add_argument('--inline', type=int, default=16)
    lib.add_argument('--out', default=os.path.join(FIXTURES, 'library.json'))
    args = parser.parse_args()

    if args.command == 'dump':
        lines = [encode({'file': p, 'inline': args.inline, 'model': decode(open(p, 'rb').read(), args.inline)})
                 for p in args.files]
        write(lines, args.out, 'models')
    elif args.command == 'fixtures':
        paths = sorted(os.path.relpath(os.path.join(FIXTURES, n), REPO) for n in os.listdir(FIXTURES) if n.endswith('.mdl'))
        # The hand-built fixtures in full; WE's camera (36 KB) with its long arrays as digests.
        lines = [encode({'file': p, 'inline': None, 'model': decode(open(os.path.join(REPO, p), 'rb').read(), None)})
                 for p in paths]
        if not ASSETS:
            sys.exit('set OWE_ASSETS to the assets folder: expected.json also covers WE\'s camera model')
        lines += [encode({'file': 'assets:' + p, 'inline': 16, 'model': decode(open(os.path.join(ASSETS, p), 'rb').read(), 16)})
                  for p in ASSET_MODELS]
        write(lines, args.out, 'models')
    else:
        known = set()
        if args.known:
            known = {(e['root'], e['item'], e['file'], e['sha256']) for e in json.load(open(args.known, encoding='utf-8'))}
        lines = []
        for root, item, file, blob in library_files():
            digest = hashlib.sha256(blob).hexdigest()
            if (root, item, file, digest) in known:
                continue
            lines.append(encode({'root': root, 'item': item, 'file': file, 'sha256': digest, 'size': len(blob),
                                 'inline': args.inline, 'model': decode(blob, args.inline)}))
        write(lines, args.out, 'library models')


if __name__ == '__main__':
    main()
