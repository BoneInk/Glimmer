#!/usr/bin/env python3
"""Reference model of Wallpaper Engine's timeline animations, and the generator of the test oracle.

    ./Scripts/timeline-reference.py fixture  [--out DIR]   # Tests/Fixtures/Timeline/cases.json
    ./Scripts/timeline-reference.py library  [--out DIR] [--items ID,...]
                                                           # Tests/Fixtures/Timeline/library-expected.json
    ./Scripts/timeline-reference.py all      [--out DIR]   # both
    ./Scripts/timeline-reference.py survey                 # list the library's animations

Both generators read the library (`fixture` needs it for the library cases it copies; its synthetic
cases need nothing). The roots are the Steam workshop folder and OpenWallpaperStorage, in that
order; `OWE_LIBRARY` (paths separated by ':') replaces them. `library --items` keeps only those
items (TimelineLibrarySweepTests runs it at test time for items the committed file doesn't cover).
Each library group carries the SHA-256 of the file it was read from, so the test can tell a file
that changed since the fixture from a model regression. Plain Python 3, no packages.

WHAT IT MODELS (docs/timeline-plan.md §2, from wallpaper64.exe of 2026-09)

Property timelines (an `animation` inside a bound value):
  parse      0x1401a50b5..0x1401a57f4, keyframes 0x1401a8ce0, options 0x1401a96b0/0x1401a8c10,
             events 0x1401a9410, relative 0x1401a538a/0x1401a89a0, wraploop 0x1401a98b0
  sampler    0x1401a9bc0  S(n), one integer frame, cubic Bezier found by bisection
  per frame  0x140172370..0x1401726aa  owner clock advanced once by delta * rate, value lerped
             between the samples of the two integer frames around the clock time
  clock      0x1401a9f60  advance(d), single / mirror / loop, events crossed
  script API 0x140170770..0x1401708ba  play pause stop isPlaying getFrame setFrame rate
Texture (TEXS) animations:
  0x14015f0e0 (shared clock), 0x14015fdd0 (script override), 0x140206380: at most one frame per tick

FLOAT32

WE computes in float32 (SSE `ss` instructions). Every operation here goes through `f32()`: the
double result of one +, -, *, / of two float32 values rounded once to float32 is the correctly
rounded float32 result (53 >= 2*24 + 2), and fmod is exact. So each line below is one float32
instruction, in WE's operand order where it matters (the order is noted when it was read from
the disassembly). Anyone porting this (T1 in Scene/Values) must keep:

  Bezier x:  ((u*u)*u)*x0 + x1*(((3*u)*u)*t) + x2*(((3*u)*t)*t) + ((t*t)*t)*x3,
             added as ((b + a) + c) + d, where u = 1 - t
  Bezier y:  the same with y0 = p.value, y1 = p.value + p.front.y, y2 = q.value + q.back.y, y3
  stop test: abs(float32(Bx - n)) widened to double, compared < 0.01 (the double 0.01)
  lerp:      S(f0) * (1 - frac) + S(f1) * frac

KNOWN GAPS OF THE MODEL (no library case; see the plan's open questions)

  - Channels a property's type does not sample are ignored; channels it samples that are absent
    are empty and sample 0. The fixture gives the component count explicitly.
  - Invalid options (fps <= 0, no length, duration <= 0) are not modelled; no case uses them.
  - `relative` parses the holder's string with Python's float() per token, 0 when a token is not
    a number (WE's exact tokenizer is not traced).
  - A linked parent that is itself linked: the child uses the parent's own clock.
"""

import argparse
import hashlib
import math
import os
import re
import struct
import sys
import json

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_OUT = os.path.join(REPO, "Tests", "Fixtures", "Timeline")
DEFAULT_ROOTS = [
    "/Volumes/980Pro/Crossover/bottles/Steam Bottle/drive_c/Program Files (x86)/Steam/steamapps/workshop/content/431960",
    "/Volumes/980Pro/OpenWallpaperStorage",
]

# ---------------------------------------------------------------------------------------------
# float32

def f32(x):
    """Rounds a Python float to the nearest float32 (inf on overflow, like the FPU)."""
    try:
        return struct.unpack("<f", struct.pack("<f", x))[0]
    except OverflowError:
        return math.copysign(math.inf, x)


def fmodf(a, b):
    """C fmodf: exact, so the double fmod of two float32 values is already a float32."""
    if b == 0 or math.isinf(a) or math.isnan(a) or math.isnan(b):
        return math.nan
    return math.fmod(a, b)


def cvttss2si(x):
    """Truncation toward zero to int32; NaN and out-of-range give INT32_MIN, as on x86."""
    if math.isnan(x) or not (-2147483648.0 <= x < 2147483648.0):
        return -2147483648
    return int(x)


def is_number(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool)


# ---------------------------------------------------------------------------------------------
# Keyframes (0x1401a8ce0)

FLAG_BACK, FLAG_FRONT, FLAG_STEP = 1, 2, 4


class Keyframe:
    __slots__ = ("frame", "value", "flags", "back_x", "back_y", "front_x", "front_y")

    def __init__(self, frame, value, flags=0, back=(0.0, 0.0), front=(0.0, 0.0)):
        self.frame = frame
        self.value = value
        self.flags = flags
        self.back_x, self.back_y = back
        self.front_x, self.front_y = front


def _handle(raw):
    """(enabled, x, y) of a `back`/`front` object. A disabled or absent handle is stored as (0, 0)."""
    if not isinstance(raw, dict):
        return False, 0.0, 0.0
    enabled = raw.get("enabled", True)
    if isinstance(enabled, bool) and not enabled:
        return False, 0.0, 0.0
    x = raw.get("x", 0)
    y = raw.get("y", 0)
    return True, f32(x) if is_number(x) else 0.0, f32(y) if is_number(y) else 0.0


def parse_channel(entries, base=0.0):
    """One `cN` array. A keyframe without a numeric frame and value is dropped, and so is one whose
    (truncated) frame is not after the previous kept keyframe: the list is never sorted. `base` is
    the `relative` offset, added to every value (value + base, in float32)."""
    keys = []
    last = None
    for entry in entries if isinstance(entries, list) else []:
        if not isinstance(entry, dict):
            continue
        frame, value = entry.get("frame"), entry.get("value")
        if not is_number(frame) or not is_number(value):
            continue
        frame = int(frame)  # asInt: truncation toward zero
        if last is not None and frame <= last:
            continue
        key = Keyframe(frame, f32(f32(value) + f32(base)))
        if entry.get("step") is True:
            key.flags = FLAG_STEP  # the handles are ignored
        else:
            on, x, y = _handle(entry.get("back"))
            if on:
                key.flags |= FLAG_BACK
                key.back_x, key.back_y = x, y
            on, x, y = _handle(entry.get("front"))
            if on:
                key.flags |= FLAG_FRONT
                key.front_x, key.front_y = x, y
        keys.append(key)
        last = frame
    return keys


def wrap_channel(keys, length):
    """The wraploop fix-up (0x1401a98b0), for a channel of at least two keyframes."""
    if len(keys) <= 1:
        return
    while len(keys) > 1 and keys[-1].frame > length:
        keys.pop()
    if len(keys) <= 1:
        return
    first = keys[0]
    if keys[-1].frame != length:
        keys.append(Keyframe(length, 0.0))
    last = keys[-1]
    last.value = first.value  # overwrites an authored keyframe at `length` too
    if first.flags & FLAG_FRONT:
        last.flags |= FLAG_BACK
        last.back_x, last.back_y = -first.front_x, -first.front_y
    else:
        last.flags &= ~FLAG_BACK  # only the bit: the sampler still reads the stored handle


# ---------------------------------------------------------------------------------------------
# The sampler S(n) (0x1401a9bc0). WE fills a per-channel cache of every integer frame up to n.

def _bezier(u, t, c0, c1, c2, c3):
    a = f32(f32(f32(u * u) * u) * c0)
    three_u = f32(u * 3.0)
    b = f32(c1 * f32(f32(three_u * u) * t))
    c = f32(c2 * f32(f32(three_u * t) * t))
    d = f32(f32(f32(t * t) * t) * c3)
    return f32(f32(f32(b + a) + c) + d)


def sample(keys, n):
    if not keys:
        return 0.0
    if n <= keys[0].frame:
        return keys[0].value
    for i in range(1, len(keys)):
        p, q = keys[i - 1], keys[i]
        if p.frame <= n < q.frame:
            if n == p.frame or q.flags & FLAG_STEP:
                return p.value  # the step flag belongs to the later keyframe
            half = f32(f32(q.frame - p.frame) * 0.5)
            x0 = f32(p.frame)
            x1 = f32(f32(half * p.front_x) + x0)
            x2 = f32(f32(half * q.back_x) + f32(q.frame))
            x3 = f32(q.frame)
            target = f32(n)
            t, step = 0.0, f32(0.999)
            for _ in range(1000):
                x = _bezier(f32(1.0 - t), t, x0, x1, x2, x3)
                if abs(f32(x - target)) < 0.01:
                    break
                step = f32(step * 0.5)
                t = f32(t - step) if x > target else f32(t + step)
            t = min(t, 1.0)
            if 0.0 > t:
                t = 0.0
            y1 = f32(p.value + p.front_y)
            y2 = f32(q.value + q.back_y)
            return _bezier(f32(1.0 - t), t, p.value, y1, y2, q.value)
    return keys[-1].value


# ---------------------------------------------------------------------------------------------
# The clock (anim + 0x38) and the script API on it

MIRROR, SINGLE, RANDOM, WRAPLOOP = 0x1, 0x2, 0x4, 0x10
PAUSED, FINISHED, BACKWARDS = 0x20000000, 0x40000000, 0x80000000


class Clock:
    def __init__(self, fps, length, flags, events):
        self.frame_duration = f32(1.0 / fps)
        self.duration = f32(f32(length) / fps)
        self.length = length
        self.flags = flags
        self.time = 0.0
        self.rate = 1.0  # the IAnimation wrapper's float; 1 when no script fetched it
        self.events = events  # [(time, name)] in parse order

    # 0x1401a9f60
    def advance(self, d):
        """Moves the clock by d seconds; returns the names of the events crossed, in order."""
        fired = []
        flags = self.flags
        if flags & (PAUSED | FINISHED):
            return fired
        if flags & SINGLE and self.time >= self.duration:
            return fired
        if 0.0 >= self.duration:
            return fired
        backwards = bool(flags & BACKWARDS)
        if backwards:
            d = -d
        old = self.time
        new = f32(d + old)
        if d > 0.0:
            fired += [name for time, name in self.events if time >= old and new > time]
        else:
            fired += [name for time, name in self.events if time > new and old >= time]
        self.time = new
        if flags & SINGLE:
            if new >= self.duration:
                self.flags |= FINISHED
                self.time = self.duration
        elif flags & MIRROR:
            if backwards:
                if 0.0 >= new:
                    self.time = -fmodf(new, self.duration)
                    self.flags &= ~BACKWARDS
            elif new >= self.duration:
                self.flags |= BACKWARDS
                self.time = f32(self.duration - fmodf(new, self.duration))
        else:
            if 0.0 > new:
                self.time = fmodf(f32(new + self.duration), self.duration)
                if self.time >= 0.0:
                    fired += [name for time, name in self.events
                              if time > self.time and self.duration >= time]
            if self.time >= self.duration:
                self.time = fmodf(self.time, self.duration)
                if self.duration > self.time:
                    fired += [name for time, name in self.events
                              if time >= 0.0 and self.time > time]
        return fired

    def tick(self, delta):
        """One engine frame: advance by delta * rate (0x1401723b5: rate * delta)."""
        return self.advance(f32(f32(self.rate) * f32(delta)))

    # IAnimation (docs/timeline-plan.md §3.1)
    def play(self):
        if self.flags & FINISHED:
            self.time = 0.0
        self.flags &= ~(PAUSED | FINISHED)

    def pause(self):
        self.flags |= PAUSED

    def stop(self):
        self.flags = (self.flags | PAUSED) & ~(FINISHED | BACKWARDS)
        self.time = 0.0

    def set_frame(self, frame):
        self.time = f32(f32(frame) * self.frame_duration)

    def get_frame(self):
        return f32(self.time / self.frame_duration)

    def is_playing(self):
        return self.flags & (PAUSED | FINISHED) == 0

    def state(self):
        """The fixture's state bits: 1 paused, 2 finished, 4 running backwards (mirror)."""
        return ((1 if self.flags & PAUSED else 0) | (2 if self.flags & FINISHED else 0)
                | (4 if self.flags & BACKWARDS else 0))


# ---------------------------------------------------------------------------------------------
# A property timeline

class Timeline:
    def __init__(self, animation, holder_value=None, components=None):
        options = animation["options"]
        fps = f32(options["fps"])
        length = int(options["length"])
        mode = options.get("mode")
        flags = MIRROR if mode == "mirror" else SINGLE if mode == "single" else 0
        if options.get("random") is True:
            flags |= RANDOM
        if options.get("wraploop") is True:
            flags |= WRAPLOOP
        if options.get("startpaused") is True:
            flags |= PAUSED
        frame_duration = f32(1.0 / fps)
        events = []
        for event in options.get("events") or []:
            if isinstance(event, dict) and isinstance(event.get("name"), str) and is_number(event.get("frame")):
                events.append((f32(f32(event["frame"]) * frame_duration), event["name"]))
        self.clock = Clock(fps, length, flags, events)
        self.name = options.get("name") if isinstance(options.get("name"), str) else ""
        parent = options.get("parent")
        self.parent_key = parent.get("key") if isinstance(parent, dict) and isinstance(parent.get("key"), str) else None

        base = [0.0, 0.0, 0.0]
        if "relative" in animation and isinstance(holder_value, str):
            base = relative_offsets(holder_value) or base
        self.channels = []
        for i in range(4):  # c0..c3, up to the first that isn't an array (0x1401a56dd..0x1401a575c)
            if not isinstance(animation.get("c%d" % i), list):
                break
            keys = parse_channel(animation["c%d" % i], base[i] if i < 3 else 0.0)
            if flags & WRAPLOOP:
                wrap_channel(keys, length)
            self.channels.append(keys)
        # The property's type picks how many channels are sampled. WE indexes the channel vector
        # without a bounds check, so a type wider than the channels present is undefined: the
        # model returns only the components that exist.
        self.components = min(components if components is not None else 4, len(self.channels))
        self._cache = [dict() for _ in range(4)]

    def _sample(self, channel, n):
        cache = self._cache[channel]
        if n not in cache:
            cache[n] = sample(self.channels[channel], n)
        return cache[n]

    def value(self, clock):
        """This timeline's channels at `clock` (its own, or its parent's): 0x1401723d8..0x140172697."""
        position = f32(clock.time / clock.frame_duration)
        truncated = cvttss2si(position)
        f0 = min(truncated, clock.length - 1)
        f0 = f0 if f0 > 0 else 0
        f1 = min(f0 + 1, clock.length)
        frac = f32(fmodf(clock.time, clock.frame_duration) / clock.frame_duration)
        out = []
        for c in range(self.components):
            later = f32(self._sample(c, f1) * frac)
            earlier = f32(self._sample(c, f0) * f32(1.0 - frac))
            out.append(f32(earlier + later))
        return out


def c_atof(data):
    """C atof on bytes: leading whitespace, then the longest decimal, hex, inf or nan prefix; 0 if none."""
    text = data.decode("latin-1")
    match = re.match(r"[ \t\n\v\f\r]*([+-]?)(0[xX](?:[0-9a-fA-F]+\.?[0-9a-fA-F]*|\.[0-9a-fA-F]+)(?:[pP][+-]?\d+)?"
                     r"|(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?|[iI][nN][fF](?:[iI][nN][iI][tT][yY])?|[nN][aA][nN])", text)
    if not match:
        return 0.0
    sign, body = match.group(1), match.group(2)
    if body[:2] in ("0x", "0X"):
        value = float.fromhex(body if "p" in body.lower() else body + "p0")
    else:
        value = float(body)
    return -value if sign == "-" else value


def relative_offsets(text):
    """`relative`'s offsets from the holder's string value (0x1401a53f6..0x1401a54f2): three atof
    tokens separated by runs of ' '. An empty string gives zeros; fewer than three tokens give None
    (nothing is added). Each offset is the double from atof rounded to float32."""
    data = text.encode("utf-8").split(b"\0")[0]
    if not data:
        return [0.0, 0.0, 0.0]
    offsets, index = [], 0
    for component in range(3):
        offsets.append(f32(c_atof(data[index:])))
        if component == 2:
            break
        while index < len(data) and data[index] != 0x20:
            index += 1
        if index >= len(data):
            return None
        while index < len(data) and data[index] == 0x20:
            index += 1
    return offsets


def components_of(holder_value, animation):
    """The component count the property's type implies, taken from its authored value."""
    if isinstance(holder_value, str):
        return max(1, min(4, len(holder_value.split())))
    if is_number(holder_value) or isinstance(holder_value, bool):
        return 1
    return max([i + 1 for i in range(4) if ("c%d" % i) in animation] or [1])


# ---------------------------------------------------------------------------------------------
# Texture (TEXS) animation clock (0x14015fdd0; the shared clock 0x14015f0e0 is the same with rate 1)

class TextureClock:
    def __init__(self, frame_times):
        self.frame_times = [f32(t) for t in frame_times]
        self.frame = 0
        self.time = 0.0
        self.rate = 1.0

    def advance(self, d):
        times = self.frame_times
        count = len(times)
        current = times[self.frame] if 0 <= self.frame < count else times[0]
        if d > 0.0:
            self.time = f32(d + self.time)
            if self.time >= current:
                self.frame += 1
                self.time = f32(self.time - current)
                if self.frame >= count:
                    self.frame = 0
                self.time = min(self.time, times[self.frame])
        elif 0.0 > d:
            self.time = f32(d + self.time)
            if not (0.0 < self.time):
                self.frame -= 1
                if self.frame < 0:
                    self.frame = count - 1
                self.time = max(f32(self.time + times[self.frame]), 0.0)

    def tick(self, delta):
        self.advance(f32(f32(delta) * f32(self.rate)))


# ---------------------------------------------------------------------------------------------
# Scenarios. A run is a list of ops applied to the clock owner; `expect` records the state after
# selected ticks. Ops:
#   ["advance", dt, n]        n ticks of dt seconds (times the clock's rate)
#   ["cycle", [dt, ...], n]   n ticks, tick k uses dts[k % len]
#   ["play"] ["pause"] ["stop"] ["setFrame", f] ["rate", r]
# Records: [op, tick, time, state, frame, [[values of timeline 0], [timeline 1], ...]]
#   op = the op's index (-1 before the first op), tick = the tick within an advance op (0 for the
#   others). Events: [op, tick, [names]] for every tick that fired any.

JITTER = [1 / 240, 1 / 60, 1 / 37, 1 / 144, 0.05, 1 / 90, 1 / 75]


def op_ticks(op):
    return op[2] if op[0] in ("advance", "cycle") else 0


def standard_runs(duration, frame_duration, length):
    """The scenarios every library timeline is run through, over twice its duration."""
    def ticks(dt):
        return max(1, int(math.ceil(2.0 * max(duration, 1e-3) / dt)))
    half = max(1, ticks(1 / 60) // 4)
    return [
        ("load-60", [["advance", 1 / 60, ticks(1 / 60)]]),
        ("play-144", [["play"], ["advance", 1 / 144, ticks(1 / 144)]]),
        ("play-30", [["play"], ["advance", 1 / 30, ticks(1 / 30)]]),
        ("play-jitter", [["play"], ["cycle", JITTER, ticks(sum(JITTER) / len(JITTER))]]),
        ("controls", [
            ["play"], ["advance", 1 / 60, half],
            ["pause"], ["advance", 1 / 60, 10],
            ["rate", 2.0], ["play"], ["advance", 1 / 60, half // 2 + 1],
            ["setFrame", length * 0.75], ["advance", 1 / 60, 10],
            ["rate", -1.0], ["play"], ["advance", 1 / 60, half],
            ["rate", 0.0], ["advance", 1 / 60, 10],
            ["setFrame", length + 3.5], ["rate", 0.5], ["advance", 1 / 60, 10],
            ["stop"], ["advance", 1 / 60, 5],
            ["play"], ["rate", 1.0], ["advance", 1 / 60, half * 2],
        ]),
    ]


def run(owner, timelines, ops, max_records):
    """Plays `ops` on owner.clock; samples every timeline at that clock."""
    clock = owner.clock
    total = sum(op_ticks(op) for op in ops)
    stride = max(1, int(math.ceil(total / max_records)))
    records, events = [], []

    def record(op_index, tick):
        records.append([op_index, tick, clock.time, clock.state(), clock.get_frame(),
                        [t.value(clock) for t in timelines]])

    record(-1, 0)
    seen = 0
    for index, op in enumerate(ops):
        kind = op[0]
        if kind in ("advance", "cycle"):
            for k in range(op[2]):
                dt = op[1] if kind == "advance" else op[1][k % len(op[1])]
                fired = clock.tick(dt)
                seen += 1
                if fired:
                    events.append([index, k, fired])
                if fired or seen % stride == 0 or k == op[2] - 1:
                    record(index, k)
            continue
        if kind == "play":
            clock.play()
        elif kind == "pause":
            clock.pause()
        elif kind == "stop":
            clock.stop()
        elif kind == "setFrame":
            clock.set_frame(op[1])
        elif kind == "rate":
            clock.rate = f32(op[1])
        else:
            raise ValueError("unknown op %r" % (op,))
        record(index, 0)
    return records, events


def texture_run(frame_times, ops, max_records):
    clock = TextureClock(frame_times)
    total = sum(op_ticks(op) for op in ops)
    stride = max(1, int(math.ceil(total / max_records)))
    records = [[-1, 0, clock.frame, clock.time]]
    seen = 0
    for index, op in enumerate(ops):
        if op[0] == "advance":
            for k in range(op[2]):
                clock.tick(op[1])
                seen += 1
                if seen % stride == 0 or k == op[2] - 1:
                    records.append([index, k, clock.frame, clock.time])
        elif op[0] == "rate":
            clock.rate = f32(op[1])
            records.append([index, 0, clock.frame, clock.time])
        else:
            raise ValueError("unknown texture op %r" % (op,))
    return records


# ---------------------------------------------------------------------------------------------
# The library: the workshop folder and OpenWallpaperStorage, `.pkg` contents included

KNOWN_ANIMATION_KEYS = {"c0", "c1", "c2", "c3", "options", "relative", "previewvalue"}
KNOWN_OPTION_KEYS = {"fps", "length", "mode", "wraploop", "startpaused", "random", "name", "events",
                     "parent", "children", "smoothing", "stiffness"}
KNOWN_KEYFRAME_KEYS = {"frame", "value", "back", "front", "step", "lockangle", "locklength"}
KNOWN_HANDLE_KEYS = {"enabled", "x", "y", "magic"}
KNOWN_MODES = {"loop", "mirror", "single"}


def library_roots():
    env = os.environ.get("OWE_LIBRARY")
    return [p for p in env.split(":") if p] if env else DEFAULT_ROOTS


def read_pkg(path):
    data = open(path, "rb").read()
    offset = 4 + struct.unpack_from("<I", data, 0)[0]
    count = struct.unpack_from("<I", data, offset)[0]
    offset += 4
    entries = []
    for _ in range(count):
        size = struct.unpack_from("<I", data, offset)[0]
        offset += 4
        name = data[offset:offset + size].decode("utf-8", "replace")
        offset += size
        start, length = struct.unpack_from("<II", data, offset)
        offset += 8
        entries.append((name, start, length))
    return [(name, data[offset + start:offset + start + length]) for name, start, length in entries]


def library_files(items=None):
    """Yields (item, file, name, bytes). Per item: `.pkg` entries first, then loose files, both in
    sorted order; a (item, name) already seen, in this root or an earlier one, is skipped. `name`
    is the entry name in a package and the item-relative path of a loose file; `file` is the
    item-relative path, with `::entry` for package entries. `items`, when given, keeps only those."""
    seen = set()
    for root in library_roots():
        if not os.path.isdir(root):
            continue
        for item in sorted(os.listdir(root)):
            base = os.path.join(root, item)
            if not os.path.isdir(base) or (items is not None and item not in items):
                continue
            files = sorted(os.path.relpath(os.path.join(d, f), base)
                           for d, _, names in os.walk(base) for f in names)
            for rel in files:
                if rel.endswith(".pkg"):
                    try:
                        entries = read_pkg(os.path.join(base, rel))
                    except (OSError, struct.error) as error:
                        print("error: %s/%s: %s" % (item, rel, error), file=sys.stderr)
                        continue
                    for name, blob in sorted(entries, key=lambda e: e[0]):
                        if (item, name) not in seen:
                            seen.add((item, name))
                            yield item, rel + "::" + name, name, blob
            for rel in files:
                if not rel.endswith(".pkg") and (item, rel) not in seen:
                    seen.add((item, rel))
                    with open(os.path.join(base, rel), "rb") as handle:
                        yield item, rel, rel, handle.read()


def is_timeline(value):
    return isinstance(value, dict) and ("options" in value or any(("c%d" % i) in value for i in range(4)))


def find_animations(items=None):
    """Every timeline in the library's JSON files: {item, file, sha256, path, holder, animation}."""
    found = []

    def walk(node, path, item, file, digest):
        if isinstance(node, dict):
            if is_timeline(node.get("animation")):
                found.append(dict(item=item, file=file, sha256=digest, path=path, holder=node,
                                  animation=node["animation"]))
            for key, value in node.items():
                walk(value, path + [str(key)], item, file, digest)
        elif isinstance(node, list):
            for index, value in enumerate(node):
                walk(value, path + [str(index)], item, file, digest)

    for item, file, name, blob in library_files(items):
        if not name.endswith(".json"):
            continue
        try:
            document = json.loads(blob.decode("utf-8-sig"))
        except (UnicodeDecodeError, ValueError):
            continue
        walk(document, [], item, file, hashlib.sha256(blob).hexdigest())
    return found


def shape_problems(animation):
    """What the model does not know about, so a new wallpaper fails loudly instead of silently."""
    problems = ["animation key %r" % k for k in animation if k not in KNOWN_ANIMATION_KEYS]
    options = animation.get("options")
    if not isinstance(options, dict):
        return problems + ["no options"]
    problems += ["option %r" % k for k in options if k not in KNOWN_OPTION_KEYS]
    if options.get("mode") not in KNOWN_MODES:
        problems.append("mode %r" % options.get("mode"))
    if not is_number(options.get("fps")) or options["fps"] <= 0:
        problems.append("fps %r" % options.get("fps"))
    if not is_number(options.get("length")) or options["length"] <= 0:
        problems.append("length %r" % options.get("length"))
    for i in range(4):
        for key in animation.get("c%d" % i) or []:
            if not isinstance(key, dict):
                problems.append("c%d keyframe %r" % (i, key))
                continue
            problems += ["keyframe key %r" % k for k in key if k not in KNOWN_KEYFRAME_KEYS]
            for side in ("back", "front"):
                if isinstance(key.get(side), dict):
                    problems += ["handle key %r" % k for k in key[side] if k not in KNOWN_HANDLE_KEYS]
    return problems


def link_groups(animations):
    """Clock groups: a timeline and the siblings (same owner, same file) whose options.parent.key
    names its property key (§2.5). Returns [[owner record, children sorted by key...]] in library
    order."""
    by_owner = {}
    for record in animations:
        by_owner.setdefault((record["item"], record["file"], tuple(record["path"][:-1])), []).append(record)
    groups = []
    for record in animations:
        siblings = by_owner[(record["item"], record["file"], tuple(record["path"][:-1]))]
        keys = {r["path"][-1] for r in siblings}
        parent = Timeline(record["animation"]).parent_key
        if parent is not None and parent in keys and parent != record["path"][-1]:
            continue  # sampled at its parent's clock, in the parent's group
        children = sorted((r for r in siblings if r is not record
                           and Timeline(r["animation"]).parent_key == record["path"][-1]),
                          key=lambda r: r["path"][-1])
        groups.append([record] + children)
    return groups


# ---------------------------------------------------------------------------------------------
# JSON output: float32 values in the shortest form that reads back to the same float32

def fmt_float(x):
    if math.isnan(x) or math.isinf(x):
        raise ValueError("non-finite value %r in the oracle" % x)
    if x == int(x) and abs(x) < 1e15:
        return str(int(x)) if x != 0 or math.copysign(1, x) > 0 else "-0.0"
    for digits in range(6, 18):
        text = "%.*g" % (digits, x)
        if f32(float(text)) == x:
            return text
    return repr(x)


def dump(value, indent=0, inline_depth=None):
    """JSON with one record per line, so fixture diffs stay readable."""
    if isinstance(value, bool) or value is None:
        return json.dumps(value)
    if isinstance(value, float):
        return fmt_float(value)
    if isinstance(value, (int, str)):
        return json.dumps(value, ensure_ascii=False)
    if inline_depth == 0 or (isinstance(value, list) and all(not isinstance(v, (dict, list)) for v in value)):
        if isinstance(value, dict):
            return "{" + ", ".join(json.dumps(k) + ": " + dump(v, 0, 0) for k, v in value.items()) + "}"
        return "[" + ", ".join(dump(v, 0, 0) for v in value) + "]"
    pad, inner = "  " * indent, "  " * (indent + 1)
    deeper = None if inline_depth is None else inline_depth - 1
    if isinstance(value, dict):
        if not value:
            return "{}"
        body = [inner + json.dumps(k) + ": " + dump(v, indent + 1, _inline_for(k, deeper)) for k, v in value.items()]
        return "{\n" + ",\n".join(body) + "\n" + pad + "}"
    if not value:
        return "[]"
    body = [inner + dump(v, indent + 1, deeper) for v in value]
    return "[\n" + ",\n".join(body) + "\n" + pad + "]"


def _inline_for(key, deeper):
    # Records, events, ops, animations and texture frame times each go on one line.
    return 1 if key in ("records", "events", "ops") else 0 if key in ("animation", "frameTimes") else deeper


def f32_list(values):
    return [f32(v) for v in values]


def run_json(name, ops, records, events):
    return dict(name=name, ops=[_op_json(op) for op in ops], records=records, events=events)


def _op_json(op):
    if op[0] == "advance":
        return ["advance", f32(op[1]), op[2]]
    if op[0] == "cycle":
        return ["cycle", f32_list(op[1]), op[2]]
    if op[0] in ("setFrame", "rate"):
        return [op[0], f32(op[1])]
    return list(op)


def _f32_ops(ops):
    """The ops as the test reads them: every delta, frame and rate already float32."""
    return [_op_json(op) for op in ops]


def timeline_case(case_id, source, covers, members, runs=None, max_records=64):
    """members: [(key, holder value, components, animation)], the clock owner first."""
    timelines = [Timeline(animation, value, components) for _, value, components, animation in members]
    owner = timelines[0]
    if runs is None:
        runs = standard_runs(owner.clock.duration, owner.clock.frame_duration, owner.clock.length)
    out_runs = []
    for name, ops in runs:
        ops = _f32_ops(ops)
        fresh = [Timeline(animation, value, components) for _, value, components, animation in members]
        records, events = run(fresh[0], fresh, ops, max_records)
        out_runs.append(run_json(name, ops, records, events))
    return dict(id=case_id, source=source, covers=covers,
                timelines=[dict(key=key, value=value, components=components, animation=animation)
                           for key, value, components, animation in members],
                runs=out_runs)


# ---------------------------------------------------------------------------------------------
# The committed fixture: representative library timelines and synthetic edge cases

def _key(frame, value, back=(-1, 0), front=(1, 0), **extra):
    key = {"frame": frame, "value": value,
           "back": {"enabled": back is not None, "x": back[0] if back else 0, "y": back[1] if back else 0},
           "front": {"enabled": front is not None, "x": front[0] if front else 0, "y": front[1] if front else 0}}
    key.update(extra)
    return key


def _anim(channels, **options):
    animation = {"c%d" % i: keys for i, keys in enumerate(channels)}
    animation["options"] = dict(dict(fps=30, length=60, mode="loop"), **options)
    return animation


LIBRARY_PICKS = [
    # (item, path suffix, id, covers)
    ("2134765860", "objects/6/angles", "lib-angles-relative-loop", ["loop", "relative", "vec3", "default-handles"]),
    ("2134765860", "objects/23/effects/1/passes/0/constantshadervalues/multiply", "lib-multiply-fade",
     ["single", "startpaused", "effect-constant", "default-handles"]),
    ("2542737668", "objects/22/alpha", "lib-alpha-loop-5keys", ["loop", "no-wraploop", "default-handles"]),
    ("3074485715", "constantshadervalues/Cutout Gradient Value 1 (Fade = 0.1)", "lib-cutout-linked",
     ["single", "linked-children", "effect-constant"]),
    ("3187908708", "objects/1/origin", "lib-title-origin-linked-alpha",
     ["single", "relative", "linked-children", "late-first-key"]),
    ("3187908708", "objects/0/scale", "lib-scale-relative-custom-handles",
     ["single", "startpaused", "relative", "custom-handles"]),
    ("3453730450", "objects/0/alpha", "lib-alpha-custom-handles-key-at-length", ["single", "custom-handles"]),
    ("3639372043", "constantshadervalues/alpha", "lib-alpha-wraploop-120fps", ["loop", "wraploop", "custom-handles"]),
    ("3803044683", "constantshadervalues/opacity", "lib-opacity-wraploop-short", ["loop", "wraploop", "custom-handles"]),
]


def synthetic_cases():
    cases = []

    def add(case_id, covers, members, runs=None):
        cases.append(timeline_case(case_id, "synthetic", covers, members, runs))

    add("syn-mirror-bounce", ["mirror", "default-handles"],
        [("alpha", 1.0, 1, _anim([[_key(0, 0.0), _key(20, 1.0), _key(40, 0.25)]], mode="mirror", length=40))])
    add("syn-disabled-handles-linear", ["disabled-handles", "loop"],
        [("alpha", 1.0, 1, _anim([[_key(0, 0.0, None, None), _key(30, 3.0, None, None), _key(60, -1.0, None, None)]]))])
    add("syn-handles-without-enabled", ["handles-missing-enabled", "handles-missing-xy"],
        [("alpha", 1.0, 1, _anim([[{"frame": 0, "value": 0, "front": {"x": 2}},
                                   {"frame": 30, "value": 1, "back": {"y": 0.5}},
                                   {"frame": 45, "value": 0}]], mode="single", length=45))])
    add("syn-step-on-later-key", ["step", "single"],
        [("alpha", 1.0, 1, _anim([[_key(0, 0.0), _key(10, 1.0, step=True), _key(20, 0.5), _key(30, 2.0, step=True)]],
                                 mode="single", length=40))])
    add("syn-dropped-keys", ["out-of-order-keys", "duplicate-keys", "non-integer-frames", "malformed-keys"],
        [("alpha", 1.0, 1, _anim([[_key(0, 0.0), _key(20, 1.0), _key(10, 5.0), _key(20, 6.0),
                                   _key(25.9, 0.5), _key(25.1, 9.0), {"frame": 30}, {"frame": "40", "value": 1},
                                   {"frame": 35, "value": True}, _key(50, 0.25)]], mode="loop", length=60))])
    add("syn-wraploop-overwrites-key-at-length", ["wraploop", "key-at-length", "keys-after-length"],
        [("alpha", 1.0, 1, _anim([[_key(0, 0.2, front=(0.5, 0.3)), _key(20, 1.0), _key(40, 7.0), _key(45, 9.0)]],
                                 mode="loop", length=40, wraploop=True))])
    add("syn-wraploop-no-front-handle", ["wraploop", "disabled-handles"],
        [("alpha", 1.0, 1, _anim([[_key(5, 0.5, front=None), _key(25, 1.5)]], mode="loop", length=40, wraploop=True))])
    add("syn-relative-two-tokens-ignored", ["relative", "relative-short-string"],
        [("origin", "10 -20", 3, _anim([[_key(0, 1.0), _key(30, 2.0)], [_key(0, 1.0), _key(30, 2.0)],
                                        [_key(0, 1.0), _key(30, 2.0)]], mode="loop", length=30) | {"relative": True})])
    add("syn-relative-odd-spacing", ["relative", "relative-tokenizer"],
        [("origin", " 5   -2.5e1 1x7", 3, _anim([[_key(0, 1.0), _key(30, 2.0)], [_key(0, 1.0), _key(30, 2.0)],
                                                  [_key(0, 1.0), _key(30, 2.0)]], mode="loop", length=30) | {"relative": True}),
         ("scale", "", 3, _anim([[_key(0, 1.0), _key(30, 2.0)], [_key(0, 1.0)], [_key(0, 3.0)]], length=30,
                                parent={"key": "origin"}) | {"relative": True})])
    add("syn-wraploop-keeps-disabled-back-values", ["wraploop", "key-at-length", "disabled-handles"],
        [("alpha", 1.0, 1, _anim([[_key(0, 0.25, front=None), _key(20, 1.0), _key(40, 3.0, back=(-1.5, 0.75))]],
                                 mode="loop", length=40, wraploop=True))])
    add("syn-relative-scalar-is-absolute", ["relative-scalar"],
        [("alpha", 0.5, 1, _anim([[_key(0, 1.0), _key(30, 2.0)]], length=30) | {"relative": True})])
    add("syn-empty-channel-samples-zero", ["empty-channel", "vec3"],
        [("scale", "1 1 1", 3, _anim([[_key(0, 1.0), _key(30, 2.0)], [], [_key(0, 3.0)]], length=30))])
    add("syn-channels-stop-at-gap", ["channel-gap"],
        [("scale", "1 1 1", 3, {"c0": [_key(0, 1.0), _key(30, 2.0)], "c1": {"not": "an array"},
                                "c2": [_key(0, 3.0)], "options": {"fps": 30, "length": 30, "mode": "loop"}})])
    add("syn-single-key-and-empty", ["single-key"],
        [("alpha", 1.0, 1, _anim([[_key(12, 0.75)]], length=30))])
    add("syn-events-loop", ["events", "loop", "negative-rate"],
        [("alpha", 1.0, 1, _anim([[_key(0, 0.0), _key(30, 1.0)]], length=30,
                                 events=[{"name": "start", "frame": 0}, {"name": "mid", "frame": 15},
                                         {"name": "end", "frame": 30}, {"name": "late", "frame": 29.5}]))])
    add("syn-events-mirror-single", ["events", "mirror"],
        [("alpha", 1.0, 1, _anim([[_key(0, 0.0), _key(30, 1.0)]], mode="mirror", length=30,
                                 events=[{"name": "a", "frame": 3}, {"name": "b", "frame": 27}]))])
    add("syn-single-negative-rate", ["single", "negative-rate", "negative-time"],
        [("alpha", 1.0, 1, _anim([[_key(0, 0.0), _key(10, 1.0), _key(30, 0.0)]], mode="single", length=30))],
        runs=[("negative", [["rate", -1.0], ["advance", 1 / 60, 30], ["rate", 2.0], ["advance", 1 / 60, 60],
                            ["play"], ["setFrame", -4.0], ["advance", 1 / 144, 20]])])
    add("syn-linked-parent-length", ["linked-children", "loop"],
        [("origin", "0 0 0", 3, _anim([[_key(0, 0.0), _key(20, 10.0)], [_key(0, 0.0)], [_key(0, 0.0)]],
                                       length=20, children=[{"key": "alpha"}])),
         ("alpha", 1.0, 1, _anim([[_key(0, 0.0), _key(40, 1.0)]], length=40, fps=15, parent={"key": "origin"}))])
    add("syn-fps-rounding", ["fps-rounding", "loop"],
        [("alpha", 1.0, 1, _anim([[_key(0, 0.0), _key(7, 1.0)]], fps=7, length=7))])
    return cases


def texture_cases(library_tex):
    cases = []
    runs_standard = lambda total: [
        ("60", [["advance", 1 / 60, int(math.ceil(2 * total * 60)) + 1]]),
        ("144", [["advance", 1 / 144, int(math.ceil(2 * total * 144)) + 1]]),
        ("rate", [["rate", 2.0], ["advance", 1 / 60, 40], ["rate", 0.0], ["advance", 1 / 60, 5],
                  ["rate", -1.0], ["advance", 1 / 60, 60], ["rate", 0.3], ["advance", 1 / 30, 40]]),
    ]
    for case_id, source, times in library_tex + [
        ("syn-tex-shorter-than-tick", "synthetic", [0.004, 0.004, 0.004, 0.1]),
        ("syn-tex-zero-frames", "synthetic", [0.0, 0.05, 0.0, 0.0, 0.1]),
    ]:
        total = sum(f32(t) for t in times)
        runs = []
        for name, ops in runs_standard(total):
            ops = _f32_ops(ops)
            runs.append(dict(name=name, ops=ops, records=texture_run(times, ops, 160)))
        cases.append(dict(id=case_id, source=source, frameTimes=f32_list(times), runs=runs))
    return cases


def library_tex_frame_times(item, suffix):
    for it, file, name, blob in library_files():
        if it == item and name.endswith(suffix) and blob[:4] == b"TEXV":
            index = blob.rfind(b"TEXS000")
            if index < 0:
                continue
            version = blob[index:index + 8]
            offset = index + 9
            count = struct.unpack_from("<I", blob, offset)[0]
            offset += 4 + (8 if version == b"TEXS0003" else 0)
            return file, [struct.unpack_from("<f", blob, offset + 4 + 32 * k)[0] for k in range(count)]
    return None, None


def make_fixture(out):
    animations = find_animations()
    if not animations:
        sys.exit("no library found (roots: %s); the fixture's library cases need it" % library_roots())
    groups = link_groups(animations)
    cases = []
    for item, suffix, case_id, covers in LIBRARY_PICKS:
        group = next((g for g in groups if g[0]["item"] == item and "/".join(g[0]["path"]).endswith(suffix)), None)
        if group is None:
            sys.exit("library pick %s %s not found" % (item, suffix))
        members = [(r["path"][-1], r["holder"].get("value"), components_of(r["holder"].get("value"), r["animation"]),
                    r["animation"]) for r in group]
        source = "library %s %s %s" % (item, group[0]["file"], "/".join(group[0]["path"]))
        cases.append(timeline_case(case_id, source, covers, members))
    cases += synthetic_cases()

    library_tex = []
    file, times = library_tex_frame_times("2176097362", "Moic (1).tex")
    if times is None:
        sys.exit("2176097362 Moic (1).tex not found")
    library_tex.append(("lib-tex-zero-frame", "library 2176097362 " + file, times))
    file, times = library_tex_frame_times("1606860844", "tumblr_pgsh50NSQQ1wsj6zro1_1280.tex")
    if times is not None:
        library_tex.append(("lib-tex-uniform", "library 1606860844 " + file, times))

    fixture = dict(
        about="Expected float32 values of WE's timeline maths, from Scripts/timeline-reference.py fixture. "
              "Do not edit by hand.",
        tolerance=1e-5,
        timelines=cases,
        textures=texture_cases(library_tex),
    )
    write(os.path.join(out, "cases.json"), fixture)


# The library file keeps three of the standard runs, so it stays small; the fixture has all five.
LIBRARY_RUNS = ("load-60", "play-jitter", "controls")


def make_library(out, items=None):
    animations = find_animations(items)
    if not animations and items is None:
        sys.exit("no library found (roots: %s)" % library_roots())
    entries = []
    for group in link_groups(animations):
        problems = [p for r in group for p in shape_problems(r["animation"])]
        if problems:
            sys.exit("%s %s %s: unknown shape: %s" % (group[0]["item"], group[0]["file"],
                                                     "/".join(group[0]["path"]), problems))
        members = [(r["path"][-1], r["holder"].get("value"), components_of(r["holder"].get("value"), r["animation"]),
                    r["animation"]) for r in group]
        owner = Timeline(group[0]["animation"])
        runs = [r for r in standard_runs(owner.clock.duration, owner.clock.frame_duration, owner.clock.length)
                if r[0] in LIBRARY_RUNS]
        case = timeline_case(None, None, None, members, runs, max_records=32)
        entries.append(dict(item=group[0]["item"], file=group[0]["file"], sha256=group[0]["sha256"],
                            paths=["/".join(r["path"]) for r in group],
                            components=[m[2] for m in members],
                            runs=case["runs"]))
    fixture = dict(
        about="Every timeline of the library under the reference model, from Scripts/timeline-reference.py "
              "library. Keyed by item, file and JSON path, with the SHA-256 of that file; the test re-reads the "
              "animations from the library. "
              "Do not edit by hand.",
        tolerance=1e-5,
        roots=[os.path.basename(r) for r in library_roots()],
        groups=entries,
    )
    write(os.path.join(out, "library-expected.json"), fixture)


def write(path, value):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(dump(value) + "\n")
    print("wrote %s (%d bytes)" % (os.path.relpath(path, REPO), os.path.getsize(path)))


def survey():
    for group in link_groups(find_animations()):
        head = group[0]
        options = head["animation"]["options"]
        print(head["item"], head["file"], "/".join(head["path"]), options.get("mode"), options.get("fps"),
              options.get("length"), "+%d linked" % (len(group) - 1) if len(group) > 1 else "")


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("command", choices=["fixture", "library", "all", "survey"])
    parser.add_argument("--out", default=DEFAULT_OUT)
    parser.add_argument("--items", help="library: comma-separated item ids to keep")
    args = parser.parse_args()
    if args.command in ("fixture", "all"):
        make_fixture(args.out)
    if args.command in ("library", "all"):
        make_library(args.out, set(filter(None, args.items.split(","))) if args.items else None)
    if args.command == "survey":
        survey()


if __name__ == "__main__":
    main()
