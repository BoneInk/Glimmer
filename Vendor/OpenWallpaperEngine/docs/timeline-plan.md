# Timeline animations: evidence and plan

**Status: 2026-09-26. T0–T7 are implemented, with the optimisation pass** (§4 has what's left: animation layers, with areas 6 and 7). This covers roadmap notes area 3 (timeline animations) and the animation half of SceneScript WP12 (docs/scenescript-plan.md). It sets out:

- WE's format for animated values;
- how `wallpaper64.exe` evaluates them;
- the script API over them;
- where our implementation stands;
- work packages that parallel agents can take.

Where the ground truth comes from:

- **Binary:** `wallpaper64.exe` from the 2026-09 install. The disassembly is `we64.asm` in the session scratchpad, helper `/Volumes/980Pro/dd-agentPD/re/we.py`.
- **Typings:** `/Volumes/980Pro/dd-scenescript/spec/lib.sceneScript.d.ts`.
- **Docs:** docs.wallpaperengine.io, the timeline pages: introduction, modes, combined and animationevents.
- **Library:** the Steam workshop folder and `/Volumes/980Pro/OpenWallpaperStorage`, 148 items, `scene.pkg` contents included.

The extracted data, scripts and annotated disassembly are in `/Volumes/980Pro/dd-timeline`:

| File | Contents |
|---|---|
| `animations.json` | every `animation` object |
| `texs_frames.json` | every sprite `.tex` |
| `anim_scripts.json` | scripts that use the animation API |
| `we_anim_ref.py` | a float32 reference model of WE's math |
| `compare.py`, `divergence.json` | our output compared with that model |
| `parse_region.asm`, `sampler_clock.asm`, `frame_eval.asm`, `script_api.asm` | annotated disassembly |

## 1. Format and library survey

### 1.1 Property animations (`scene.json`, `.pkg`, asset `assets.json`)

An animated property is a bound value with an `animation` member. The value can also carry a `script` and `scriptproperties`:

```json
"alpha": { "value": 0.4, "script": "…",
  "animation": {
    "c0": [ { "frame": 0,  "value": 0.35, "back": {"enabled": true, "x": -1, "y": 0},
              "front": {"enabled": true, "x": 1, "y": 0}, "lockangle": true, "locklength": true },
            { "frame": 54, "value": 0.40, … } ],
    "c1": [ … ], "c2": [ … ],
    "options": { "fps": 30, "length": 120, "mode": "loop", "wraploop": true, "startpaused": false,
                 "name": "glow", "events": [ {"name": "sword", "frame": 12} ],
                 "parent": {"key": "origin"}, "children": [ {"key": "alpha"} ] },
    "relative": true
  } }
```

What WE reads (the parse is at `0x1401a50b5`…`0x1401a57f4`; keyframes at `0x1401a8ce0`; options at `0x1401a96b0` and `0x1401a8c10`):

| Field | Read as | Notes |
|---|---|---|
| `c0`…`c3` | arrays of keyframes, one per component | The property's type picks how many are sampled (`0x14017242d` switch on the descriptor's type code): 4 (float) one, 1 (Vec2) two, 2 (Vec3) three, 3 (Vec4) four. Any other type is evaluated but never written: `visible`, a bool, registers as type 6 everywhere scripts can reach it (`0x14025e5b2`, `0x14026ca60`, `0x1401ee931`), so a timeline on a `visible` changes nothing. |
| keyframe `frame` | **int** (`asInt`) | A keyframe whose frame is ≤ the previous one is **dropped**; the list is never sorted. |
| keyframe `value` | float | Must be a number, or the keyframe is dropped. So is a keyframe without a numeric `frame`. |
| `back` / `front` | `{enabled, x, y}` | `enabled` true stores the handle and sets flag bit 0 (back) or bit 1 (front). A disabled handle is stored as (0, 0). |
| keyframe `step` | bool | True means flags = 4 (hold) and the handles are ignored. |
| `lockangle`, `locklength`, `magic` | ignored | Editor state only. None of these strings is in the exe. |
| `options.fps` | float, required | fps ≤ 0 or a missing fps fails the options: no channels, no events. |
| `options.length` | int, required | Frames. duration = length / fps; a duration ≤ 0 fails the options. |
| `options.mode` | `"mirror"` sets flag 1, `"single"` sets flag 2, anything else is loop | |
| `options.random` | bool, flag 4 | Parsed, but the clock never reads it. Not in the library. |
| `options.wraploop` | bool, flag 0x10 | Keyframe fix-up at load (§2.2). |
| `options.startpaused` | bool, flag 0x20000000 | The paused bit. |
| `options.name` | string | `IAnimation.name`; what `getAnimation(name)` finds. |
| `options.parent.key` | string | Links this animation to its parent's clock (§2.5). |
| `options.children` | ignored at runtime | The children name the parent. |
| `options.events` | `[{name, frame}]` | Stored as time = frame × (1/fps) with the name (`0x1401a9410`). |
| `options.smoothing`, `stiffness` | ignored | Always `null` in the library. |
| `relative` | presence only | §2.2. The key is erased after use (`0x1401a55c9`). |
| `previewvalue` | ignored | Editor state. |

**Library counts** (64 animations in 15 items: 55 in `scene.json`, 9 in asset `assets.json`):

- **Targets.** 28 object fields: `alpha` 19, `origin` 4, `scale` 4, `angles` 1. 36 effect constants: `multiply` 22 (the shared "thumbnail fade" script asset in 10 items), `opacity` 10 (3803044683), 3 `Cutout …` (3074485715), `alpha` 1 (3639372043). None on `color`, `size`, `visible`, text, particles or `general`.
- **Shape and timing.**
  - Channels: 55 have one channel, 9 have three.
  - fps: 30 (26), 15 (22), 60 (14), 4 (1), 120 (1). Lengths from 2 to 600 frames.
- **Modes.**
  - `single`: 50, 30 of them `startpaused` (all script-started).
  - `loop`: 14, 11 of them `wraploop`.
  - `mirror`: 0.
- **Options.** 18 are named. `events`: one has the key, and its list is empty. `random`: 0.
- **`relative`:** 8 (origin 4, scale 3, angles 1). Every one has a Vec3 string `value`.
- **Linked animations:** 5 parents with 6 children.
  - 3074485715: three cutout constants.
  - 3187908708 and 3546971487: the `Title` and `Artist` origins, each driving its `alpha`.
- **Keyframes:** 182.
  - 117 have the default handles (back (−1, 0), front (1, 0)); 65 have `magic` handles with other x and y.
  - Disabled handles, `step`, unsorted, duplicate, negative or non-integer frames: 0.
  - A channel starting after frame 0: 16. A last keyframe before `length`: 52; exactly at `length`: 30.
- **Holders.** `value` with `script`: 38. `value` alone: 26. `user` together with `animation`: 0.

### 1.2 Texture (sprite-sheet and GIF) animations

- **Where they live.** An animated `.tex` ends with a `TEXS000n` block: `count`, then (v3) the GIF width and height, then `count` frames of 32 bytes each: `imageIndex` (int), `frametime` (float seconds), and x, y, width, widthY, heightX, height (ints in v1, floats in v2 and v3).
- **The same fields in WE** (`0x14015f281`): the frame's +4 is the image index, +0x10…+0x1c the frame rect.
- **No `rate` field.** A `.tex` has no rate. The playback rate is script-only (`ITextureAnimation.rate`).
- **Material combos.** The material's `SPRITESHEET` combos, and the particle-only `spritesheetsequences` in `.tex.json`, are separate from this.

**Library:** 31 animated `.tex` files.

- **Versions:** `TEXS0003` 29, `TEXS0002` 2.
- **Frame times:** 27 have one frame time, 4 have varying times.
- **Images:** 6 are multi-image (2–3 atlases in `TEXB`).
- **Zero frame time:** one has a frame with frame time 0 (2176097362 `Moic (1).tex`).
- **Users:** image layers in 1606860844, 1877013475, 2176097362, 2963872291, 3000562427 and 1394503570. The rest are particle sprite sheets.

### 1.3 Scripts that use the animation API (scenes only)

The Workshop's 12 `getAnimation('…')` sites belong to web wallpaper 1081733658, so they are out of scope.

| API | Sites / items | Users |
|---|---|---|
| `thisObject.getAnimation()` + `play`/`stop` | 23 / 9 | 2134765860, 2370927443, 2978204069, 2978738836, 3000562427, 3109042108, 3352730400 (`multiply` fade on a thumbnail change); 3187908708 and 3546971487 (8 each: media origins with linked `alpha` children) |
| `getAnimation(name)`, `thisScene.getAnimation` | 0 | |
| `getTextureAnimation()` | 11 / 2 | 2176097362 (Dance Club: audio-driven `rate`), 2963872291 (`rate` 0/5/9, `stop`, `setFrame(0/1)`, `getFrame() == 30`, `frameCount - 1`, `isPlaying`) |
| `.pause()` on an animation | 3453730450 | |
| `join()`, `animationEvent`, animation layers, bones | 0 | |

## 2. WE's evaluation (from the binary)

### 2.1 Objects and per-frame order

Each `animation` becomes an animation object (0x110 bytes, vtable `0x14048df78`). Its layout:

| Offset | Field |
|---|---|
| +0x08 | owner (object or material) |
| +0x10 | property descriptor (type code, setter at vtable +0x18) |
| +0x18 | enabled byte |
| +0x20 | vector of channels (0x30 bytes each: keyframes, then a per-frame sample cache at +0x18) |
| +0x38 | the clock (below) |
| +0x50 | events |
| +0x68 | name |
| +0x90 | parent key |
| +0xb0 | parent animation |
| +0xf8 | the script wrapper (`IAnimation`), whose float +0xd0 is `rate` |
| +0x108 | script handle, for event dispatch |

The clock (`anim+0x38`):

| Offset | Field |
|---|---|
| +0x0 | `frameDuration` = 1/fps |
| +0x4 | `time` (float seconds, this animation's own) |
| +0x8 | `duration` = length/fps |
| +0xc | flags: 1 mirror, 2 single, 4 random, 0x10 wraploop, 0x20000000 paused, 0x40000000 finished, 0x80000000 mirror running backwards |
| +0x10 | `length` (int) |

Every frame (`0x140172370`…`0x1401726f3`, inside the scene frame `0x140171440`, after cursor, user-property and media dispatch and before the engine tick and `update`: plan P1):

1. `clockOwner = anim.parent ?? anim`.
2. If `clockOwner` wasn't advanced this engine frame (frame counter `[engine+0x144]`), it is advanced once: `advance(clock, delta × rate)`.
   - `delta` is the frame delta handed to the script frame (`xmm1` at `0x1401802e5`).
   - `rate` is the wrapper's `rate`, or 1 when no script has fetched the animation.
3. The value is sampled from **this** animation's channels at the **owner's** clock (§2.3).
4. The property's setter writes it, **every frame, paused or not**.
5. Each event crossed during the advance calls `animationEvent` (§3.3).

### 2.2 Load-time transforms

- **`relative`** (`0x1401a538a`, `0x1401a89a0`). Only when the holder's `value` is a string. Up to three space-separated floats are parsed from it, and component *i* is **added to every keyframe of `c<i>`**, for `c0`…`c2`.
  - So a relative animation is baked once at load against the *authored* value.
  - A numeric (scalar) `value` is never offset, so a relative scalar animation is absolute.
- **`wraploop`** (`0x1401a98b0`, per channel, with ≥ 2 keyframes):
  1. Keyframes with `frame > length` are dropped from the end, keeping at least one.
  2. If the last keyframe isn't at `length`, a keyframe is appended there.
  3. The last keyframe's value is **set to the first keyframe's value**. This overwrites an authored keyframe at `length`.
  4. If the first keyframe has a front handle, the last one gets back handle = −(first.front.x, first.front.y), enabled. Otherwise its back handle is disabled.

### 2.3 Interpolation (`0x1401a9bc0`, sampled per **integer** frame, then cached)

`S(n)` for an integer frame `n`, over keyframes `k[0…m]`:

- There are no keyframes → 0.
- `n ≤ k[0].frame` → `k[0].value`.
- `n ≥ k[m].frame` → `k[m].value`.
- Otherwise, with `p = k[i−1]`, `q = k[i]` and `p.frame ≤ n < q.frame`:
  - If `n == p.frame` or `q` has the step flag → `p.value`. The step flag belongs to the **later** keyframe.
  - Otherwise, a cubic Bézier:
    - `L = q.frame − p.frame` and `h = L/2`.
    - x control points: `x0 = p.frame`, `x1 = p.frame + h·p.front.x`, `x2 = q.frame + h·q.back.x`, `x3 = q.frame`. A handle's x is in half-segment units, so the default ±1 reaches the segment's midpoint.
    - y control points: `y0 = p.value`, `y1 = p.value + p.front.y`, `y2 = q.value + q.back.y`, `y3 = q.value`. A handle's y is an absolute offset in value units.
    - `t` is found by bisection: `t = 0` and `step = 0.999`; up to 1000 times, stop if `|Bx(t) − n| < 0.01`, else `step *= 0.5` and `t −= step` when `Bx > n`, else `t += step`. Then `t` is clamped to [0, 1].
    - The result is `By(t)`, in float32 throughout.
- **Consequences:**
  - The default handles ((−1, 0) and (1, 0)) are an **ease-in-out**, not linear. WE's docs: easing by Bézier by default.
  - Disabled handles are stored as (0, 0), which makes the curve **exactly linear**. That is the docs' "none" curve mode.
  - The `enabled` bits are never read by the sampler.

The value at clock time `t` (`0x1401723d8`…`0x140172697`), per channel:

```
F    = t / frameDuration
f0   = clamp(trunc(F), 0, length − 1)          // trunc toward zero, then clamp
f1   = min(f0 + 1, length)
frac = fmodf(t, frameDuration) / frameDuration
v    = S(f1)·frac + S(f0)·(1 − frac)          // linear between integer-frame samples
```

- `frac` isn't clamped. A negative `t`, possible with a negative `rate` in single mode, gives a negative `frac`, which extrapolates below frame 0.
- At the end of a single animation, `frac` is `fmodf(length/fps, 1/fps)` in float32: 0, or just under 1.

### 2.4 The clock (`0x1401a9f60`, `advance(clock, d)`)

- **When it doesn't move.** A paused or finished clock (flags & 0x60000000) doesn't advance. Neither does a single clock with `time ≥ duration`, or one with `duration ≤ 0`.
- **The step.** A mirror clock running backwards negates `d`. Then `new = time + d`, and the events in [time, new) are fired going forward, or those in (new, time] going backward.
- **After the step, by mode:**

| Mode | What happens |
|---|---|
| single | `new ≥ duration` sets the finished flag, and `time = duration`. |
| mirror, forward | `new ≥ duration` sets the backwards bit, and `time = duration − fmodf(new, duration)`. |
| mirror, backward | `new ≤ 0` clears the backwards bit, and `time = −fmodf(new, duration)`. |
| loop | If `new < 0`, `time = fmodf(new + duration, duration)`. If `time ≥ duration`, `time = fmodf(time, duration)`. The events in [0, time) fire after a forward wrap, those in (time, duration] after a backward one. |

- **The time.** `time` is a float32 per animation, advanced by deltas. It is not a function of scene time: pausing, `setFrame` and `rate` all simply change it. Every animation starts at time 0 when the scene loads.

### 2.5 Linked animations (`options.parent`)

- **How the link resolves.** When the scene registers animations (`0x1401769dd`…`0x140176a51`), a child is linked to a parent when both have the same owner and the parent property's key (`descriptor+0x38`) equals the child's `parent.key`.
- **What the link does.** Every frame, the child samples its own keyframes at the parent's time (and the parent's `length` clamp).
- **Removing the parent** clears the link (`0x1401774b4`).
- Docs, "Combined timeline animations": one timeline with the settings of the first animation.
- **So** `thisObject.getAnimation().play()` on the `origin` of 3187908708 also runs its `alpha`.

### 2.6 How the value combines with everything else

- **Static value and user property: the animation wins.** The setter runs every frame, so an animated property always shows the timeline's value, even while paused (a `startpaused` property holds its first keyframe's value, not the authored `value`).
  - A user binding on the same property only changes the value until the next frame. The library has no such case.
  - For a `relative` animation, the base is the authored value baked at load. Whether a later user change re-bakes it is unknown (no library case).
- **Script (P2, P3): the script's return wins for that frame.** The animation writes before the scripts run.
  - `update(value)` receives this frame's animated value, and its applied return is what gets drawn.
  - The next frame, the animation overwrites it again. So an accumulator on an animated property does not run away.
- **Roadmap E7 has it backwards.** WE never lets a static value shadow a timeline.

### 2.7 Texture animations (`0x14015f0e0`, `0x14015fdd0`, `0x140206380`)

- **One clock per texture, shared by every material that uses it.** The state is `frame`, `time` at +0x9c/+0xa0, and a once-per-engine-frame guard at +0xa4.
- **When it moves.** The shared clock advances when a material binds the texture, so a texture only moves while something draws it. A layer's `ITextureAnimation` override (§3.2) advances in the image layer's `update(delta)` (`0x1401fdf90`, vtable slot +0xf8; the step at `0x1402063c1` is reached on both paths of that function's early test), not in its draw. Whether the engine calls `update` for a hidden layer isn't traced.
- **Advance** with `d` = the engine frame time `[engine+0x14c]`:
  - If `d > 0`, then `time += d`. If `time ≥ frames[frame].frametime`, the clock goes to the next frame (wrapping to 0), `time −= frametime`, and `time = min(time, frames[next].frametime)`.
  - A negative `d` walks backwards the same way.
- **At most one frame per engine frame.** A texture with frame times below the frame interval plays slower than authored, and a 0 s frame still shows for one engine frame.
- **The sprite frame is not interpolated.** The frame's rect and image index go to the material: `g_Texture0Rotation/Translation` and the image slot.
- **An editor override** (`[engine+0x132c] ≥ 0`) pins a frame. It doesn't apply to wallpapers.

## 3. Script API

### 3.1 `IAnimation` (property timelines; the wrapper's `+0xc8` → the animation)

Callbacks at `0x140170770`…`0x1401708ba`; binding at `0x140177f8e`.

| Member | WE |
|---|---|
| `fps` | `1 / frameDuration` |
| `frameCount` | `length` |
| `duration` | `length / fps` (seconds) |
| `name` | `options.name` |
| `rate` | A plain float on the wrapper; it multiplies the delta. Any number is accepted: 0 freezes, a negative number runs backwards. |
| `play()` | If finished, `time = 0`. Clears paused and finished. |
| `pause()` | Sets paused. |
| `stop()` | Sets paused, clears finished and the backwards bit, `time = 0`. |
| `isPlaying()` | `(flags & (paused \| finished)) == 0` |
| `getFrame()` | `time / frameDuration`, a fractional frame. |
| `setFrame(f)` | `time = f · frameDuration`, not clamped. It keeps the play state; a finished single stays finished, and `play()` then restarts it from 0. |

- **Finding the animation.** `getAnimation()` with no name, in a property's script, is that property's animation (d.ts). `getAnimation(name)` on a layer matches `options.name`, else the property of that key, which is how an unnamed timeline is found (2321732083's `getAnimation('origin')`, scenescript-replay-findings notes RF3); `thisScene.getAnimation(name)` searches every layer by name.
- **Where the binding lives.** `getAnimation` is bound by `scenescript64.dll`, not the exe (the exe has no `getAnimation` string; its reflection tables start at `getAnimationLayer`). `IScene.getAnimation`'s callback is `0x181635ee0` (bound at `0x181631824`, among `getLayerCount`…`createModelData`); past the global-scope check it continues at `0x18163613d`:
  - with no argument, or one that isn't a string (V8 instance type ≥ 0x80), it returns `null` (isolate root +0x378);
  - otherwise it converts the name and calls the host interface (`[this+0x18]`, vtable +0x78) with **no owner** (`edx = 0`) and the name; a result is wrapped (`0x181652380`), none returns `undefined` (root +0x368).
  - The host's search itself isn't traced. We search every owner in registration order: the layers in scene order (created ones after), each with its own fields, its effects' and their materials', then the scene's settings. `IObject.getAnimation`'s DLL path isn't traced either.

### 3.2 `ITextureAnimation` (image layers; wrapper at `layer+0x4c0`; callbacks at `0x1401fa2a0`…`0x1401fa500`)

The wrapper holds `frame` (+0xe8), `time` (+0xec), `rate` (+0xe4), `playing` (+0xe0) and `override` (+0x48).

| Member | WE |
|---|---|
| `frameCount` | the number of TEXS frames |
| `duration` | the texture's total duration |
| `rate` | Writing a value ≠ 1 copies the shared frame and time and turns on the override. |
| `play()` | `playing = 1`. It does not turn on the override. |
| `pause()` | Copies the shared state, `playing = 0`, override on. |
| `stop()` | Frame 0, time 0, `playing = 0`, override on. |
| `isPlaying()` | False only while overridden and not playing. |
| `setFrame(n)` | Int frame `n`, time 0. If not yet overridden: override on and `playing = 1`. |
| `getFrame()` | The **integer** frame: the override's, or the shared one. |
| `join()` | Override off; back to the shared clock. |

- **An overridden animation advances by `engine frametime × rate`** with the same one-frame-per-tick rule, and only while `playing` (`0x1402063c1`).

### 3.3 `animationEvent(event, value)`

- **Dispatch.** Events fire during the clock advance (§2.4). They dispatch as callback 6 (`0x1401726e7` → `0x140177ad0`) to every initialised script that exports `animationEvent` and is either attached to the animation's **owner** (`script+0x8 == owner`) or is the handle the animation carries (`+0x108`). The docs agree: "only scripts attached to the layer".
- **Arguments.** The event is `AnimationEvent {name, frame}`; `value` and the applied return follow plan P3.
- **Which events fire.** Events fire as a clock moves, at [old, new) (§2.4), and only a clock owner's clock moves: a linked child's own clock never advances, so its events never fire. Every event of a frame is the **owner's** (the parent's), sent to the scripts of the animation it belongs to.
- **Library use.** No library scene defines one.

### 3.4 Animation layers

`getAnimationLayer*`, `createAnimationLayer`, `playSingleAnimation`, `destroyAnimationLayer` and `IAnimationLayer` (`blend`, `visible`, `addEndedCallback`) drive **puppet and model** animations only (binding `0x1402113xx`, `0x14026cexx`). Without area 6/7 rigs they have nothing to act on. They stay stubs until those areas; there are 0 library users.

## 4. Our implementation and its gaps

How it runs (T1–T7):

- **Model.** `Scene/Format/SceneTimelineDocument` reads §1.1; `Scene/Values/SceneTimelineAnimation`, `SceneTimelineChannel` and `SceneTimelineClock` are §2.2–§2.4 in float32, checked bit for bit against the oracle (`Scripts/timeline-reference.py`, `Tests/Fixtures/Timeline/`). A channel solves and caches a frame the first time it is asked for (not every frame before it), and past 64 k frames solves without caching.
- **One set per renderer.** `SceneMetalRenderer` keeps its timeline state in `SceneRendererAnimations`: a `SceneAnimationSet` built from the content's `scene.json` (`SceneMetalContent.timelines`), kept, clocks and all, across content rebuilt from the same document (a user property), as it keeps the scripts; new scripts or a new document start a new set. Each draw advances it once by `SceneClock.delta`, after the last script frame's calls were applied and before the scripts run (P1). Wallpapers without scripts animate the same way, and a hung script can't stop them. A rebuild drops the texture animations of the layers it no longer has.
- **Where values go.** The property's type decides (§1.1): numbers and vectors are written, a bool (`visible`) never is.
  - Object fields (`origin`, `scale`, `angles`, `alpha`, `color`, `brightness`, `size`, `parallaxDepth`, a sound's `volume`) are read per frame into `SceneObjectAnimation`, by index, and replace the static and user-bound value (§2.6).
  - Effect constants are `SceneValueSource.animation(site:)`, nested over `user` and under `script`, bound to `.material(object, effect, pass)` by `SceneEffectPlanBuilder` and resolved through `LiveSceneValueContext.animations`. An inspector edit replaces only the value under the timeline. A chain is reused while its live-bound constants keep their values, so a paused or finished fade costs nothing.
  - `general.*` numbers (bloom strength and threshold, camera shake and parallax settings) and a particle system's `instanceoverride` values take their timeline's value under a script's.
  - A value that isn't finite (WE keeps a NaN clock for good) draws the static value instead, logged once; scripts still see WE's value.
- **Scripts (P2).** The frame input carries every site's `SceneAnimationState` (its value included), every layer's texture state, the frame's events and the set's frame counter. `SceneScriptSceneMirror` publishes them into the animation buffer, writes each animated material constant's and scene setting's value into the scripts' pool and scene buffer, posts `animationEvent` for each event (to the clock owner's slot), and turns the slots scripts called into render events (`.animation`, `.textureAnimation`, tagged with the frame they saw). A field or constant a timeline drives gets the animated value every frame, so `update(value)` sees it and a script's write or return wins only for its frame. A script frame that overran the draw's wait comes back after later advances; the set replays those on the restored clock, so no advance is lost.
- **Textures.** An animated image layer registers its texture (`SceneMetalLayer.textureKey`) with the set's `SceneTextureAnimations`. Drawing binds the texture, which steps its shared clock once per frame; a layer a script controls draws its override, which the set steps with the frame, drawn or hidden (§2.7). A frame outside the sheet draws frame 0. An effect's or image material's animated texture takes its texture's shared clock too (made on the first bind when no layer has it): the frame's atlas and its rect as `g_TextureNRotation/Translation`.
- **Deleted.** `SceneTimeline`, the invented `WEKeyframeAnimation` format, `SceneValueAnimation`, the mirror's loop-only clocks and `animationTimes`, and the scene-time sprite frame.
- **Tests.**
  - `TimelineRenderTests` (headless renders of `Scenes/timeline`): an ease-in-out alpha loop against the model; relative origin, scale and angles; a start-paused single played by a script with its linked child; identity and accumulator scripts on moving timelines; an effect constant, and scripts on animated constants (identity, `init`, a one-off write); a shared sprite sheet and one a script holds; an effect sampling a sprite sheet through its frame rect.
  - `TimelineLibraryRenderTests` (T6): every animated library scene through the real loader and renderer with its scripts, a song starting halfway; the drawn values against the model while a clock follows its `load-60` run and against the set once a script moved it, sprite frames against a reference clock, no NaN, one advance per draw.
  - `TimelineCostTests` (the cost, below), `SceneRendererAnimationsTests` (NaN at the boundary, late script frames, texture overrides and rebuilds, settings and overrides, material-bound clocks), `EffectGraphReuseTests` (a held timeline's chain is reused), `SceneScriptWallpaperTests` (state in, calls back, events to the owner, animated scene settings), `SceneScriptAnimationObjectTests` (`thisScene.getAnimation`), `SceneValueTests`, `ParticleEmitterMotionTests`.

**The optimisation pass.** `TimelineCostTests`, thread CPU time of `SceneRendererAnimations`' advance and a frame's reads (every layer's fields, every animated constant, every sprite frame, the scripts' states), built with `-O` (the app's Release optimisation; the test bundle can't load into an ad hoc Release build here), before (`a4aff37`) and after (`b68c641`):

| | before | after |
|---|---|---|
| 20 timelines (600-frame loops, ease handles) | 8.33 µs | 3.12 µs |
| 128 timelines | 51.9 µs | 16.0 µs |
| 1000 timelines | 427 µs | 126 µs |
| First frame after `setFrame(599)` on 128 cold timelines (TF8) | 3036 µs | 65 µs |
| 3453730450 (9 timelines, p50 / p99) | 5.50 / 6.79 µs | 2.75 / 3.58 µs |
| 3803044683 (10 constants, p50 / p99) | 3.38 / 6.88 µs | 2.38 / 3.62 µs |
| Every other animated library scene, p50 | 0.33–3.21 µs | 0.38–2.21 µs |

What changed: the channel cache solves only the frames asked for; the set keeps values in SIMD4s, samples a site only when its clock owner's time moved (paused, finished and rate-0 timelines cost a comparison), and builds no dictionary per frame; animated objects read their fields by index; a chain whose only live inputs are held timelines is reused instead of re-rendered. The library's timelines cost at most 3.6 µs p99 a frame, under TL20's 50 µs.

What is left:

- **Animation layers** (§3.4): with areas 6 and 7.
- **Not traced:** the host's `getAnimation` search order (§3.1) and whether a hidden layer's `update` runs (§2.7). The "needs WE ground truth" list in test-risks has the rest.
- **Drift is WE's** (TL11, TF7): a float32 clock summed per frame drifts from exact time (a 1 s loop is 0.86 s off after 24 h at 144 Hz, 0.98 s at 60 Hz), and two displays at different refresh rates drift apart. WE's clock does the same at its own tick rate, so this stays.
- **Particle materials** don't take an animated asset texture's clock: particles animate their sheets by their own `spritesheetsequences` and `animationmode`.

| Feature | WE semantics | Our status | Library users |
|---|---|---|---|
| `c0…c3` + `options` on object fields | §1.1 | ✅ origin, scale, angles, alpha, color, brightness, size, parallaxDepth, volume | alpha 19, origin 4, scale 4, angles 1 |
| Effect-constant animations | same, owner = material | ✅ | 36 (10 items) |
| Bézier handles, per-frame sampling, `step`, keyframe order | §2.3, §1.1 | ✅ | all |
| `single`, `loop`, `mirror` clock, `startpaused`, `wraploop`, `relative` | §2.2, §2.4 | ✅ | 50 / 14 / 0 |
| Linked `parent`/`children` clocks | §2.5 | ✅ | 6 children |
| Animation beats static and user; script return wins for its frame | §2.6 | ✅ fields, constants, scene settings | all 64; 38 scripted |
| `IAnimation` on objects, effects, materials and the scene | §3.1 | ✅ | 23 sites / 9 items |
| `getAnimation(name)`, `thisScene.getAnimation` | §3.1 | ✅ every owner; the host's order untraced | 0 |
| `animationEvent` | §3.3 | ✅ | 0 |
| Texture clock and `ITextureAnimation` | §2.7, §3.2 | ✅ override steps with the frame | 6 image items |
| Scene settings, particle overrides animated | §1.1 | ✅ numbers and vectors | 0 |
| `visible` animated | §1.1: type 6, never written | ✅ not drawn, as WE | 0 |
| Sprite-sheet effect and material textures | §2.7 | ✅ (T7) | 0 found |
| Animation layers | §3.4 | ⚪ stubs (areas 6/7) | 0 |

## 5. Plan

Rules that hold throughout:

- No per-name cases; the float32 math follows §2 exactly.
- A layout move is its own commit.
- The translated shader output doesn't change, so `ShaderVariantTranslator.revision` stays.

Each package lists the files it owns. Packages in the same phase share no files.

### Phase A (in parallel)

**T1 — The timeline model** (owns `Scene/Values/SceneValueAnimation.swift`, rewritten, and a new `Scene/Values/SceneTimelineClock.swift`).

- **The model.** A pure value type, parsed per §1.1 and holding:
  - channels of `{frame: Int32, value, flags, back, front}`;
  - the options flags;
  - events;
  - the parent key and name.
- **At load:** the relative bake (given the holder's `value` string) and the wraploop fix-up (§2.2).
- **The sampler.** `S(n)` with a lazily grown per-frame `[Float]` cache, and `value(atTime:)` per §2.3.
- **The clock.** `SceneTimelineClock` holds `time`, the flags and `advance(d) -> [firedEvent]`, per §2.4.
- **API semantics.** `play()`, `pause()`, `stop()`, `setFrame`, `frame` and `isPlaying` from §3.1.
- **Scope.** No renderer and no JSON beyond `SceneJSON` / Foundation.
- **Tests:** unit tests for every branch in §2.2–§2.4 (step on the later key, dropped out-of-order keys, disabled handles are linear, the default handles' midpoint value, wraploop overwriting a key at `length`, a mirror bounce, loop backwards, single finishing and `play()` restarting, a negative rate, `setFrame` past the length).

**T0 — The oracle and the library sweep** (owns new files only: `Scripts/timeline-reference.py`, a port of `/Volumes/980Pro/dd-timeline/we_anim_ref.py`, `Tests/Fixtures/Timeline/`, `OpenWallpaperEngineTests/TimelineLibrarySweepTests.swift`).

1. The script walks both library roots, `.pkg` included, as `survey.py` does. For every animation it writes the input JSON, the holder's `value` and the sampled values: at a fixed delta sequence (1/60, 1/144, 1/30 and a jittered one), under play, pause, stop, `setFrame` and `rate` scenarios, over 2 × the duration.
2. That fixture is committed (it is small: 64 animations).
3. The test runs T1's model over the same inputs and demands equality to 1e-5. When `OWE_LIBRARY` is set, it also re-scans the live library, so a new wallpaper fails loudly when its shape isn't covered: an unknown option key, a keyframe field outside the known set, a `mode` other than loop, mirror or single.

**T5a — The texture clock** (owns `Scene/Format/TEXParser.swift`, `Scene/Format/TEXSpriteFrames.swift` and a new `Scene/Rendering/SceneTextureAnimationClock.swift`).

- Keep 0 s frames. Parse TEXS v1/v2/v3 into one frame model.
- Add a shared per-texture clock per §2.7 (one frame per tick, backwards), plus an override state per §3.2 (`rate`, `pause`, `stop`, `setFrame`, `join`, int `getFrame`).
- **Tests:** a synthetic TEXS with frame times shorter than the tick, a 0 s frame, a negative rate, and override then join; plus a sweep over the 31 library `.tex` files: every one parses, and the frame count and duration match `texs_frames.json`.

**T4a — The script-side semantics** (owns `Resources/SceneScript/objects-animations.js` and its JS tests).

- `IAnimation`: `isPlaying` from the paused and finished flags mirrored in the animation buffer (add `flags` and `time` slots to the layout through the store's layout constant, coordinated with T2); `play()` restarts a finished one; `stop()` clears the backwards bit; `getFrame` fractional; `setFrame` unclamped.
- `ITextureAnimation`: the override and `join` of §3.2, int `getFrame`.
- **Tests:** the `SceneScriptObjectModelTests` style, per method, including 2963872291's pattern: `getFrame() == 30`, then `rate = 0`.

### Phase B (after T1; T2 and T3 in parallel)

**T2 — The scene's timelines** (owns a new `Scene/Values/SceneTimelineSet.swift`, `Scene/Scripting/Host/SceneScriptSceneMirror.swift`, `Scene/Scripting/Objects/SceneScriptObjectStore.swift`, `SceneScriptAnimationDescription.swift` and `Scene/Loading/SceneScriptSceneDescriber.swift`).

- **One set per wallpaper instance.** It holds every animation keyed by (owner, property key), and links parents by key within the same owner (§2.5).
- **Advance.** It advances each clock owner once per frame by `SceneClock.delta × rate`, in the P1 slot (after media, before timers and `update`). Advancing moves from the mirror into the set, and the mirror's own loop-only `Clock` is deleted.
- **Scripts.** It publishes each animation's value and state (time, flags) to the renderer and to scripts. Script commands act on the set directly, for objects, effects, materials and the scene; this removes the "not script-controlled" log.
- **`getAnimation(name)`:** `thisScene` searches every owner.
- **Events.** Fired events queue `animationEvent(event, value)` to the owner's scripts, with its return applied through the P3 converter.
- **Tests:**
  - a linked child follows its parent (the 3187908708 shape);
  - `thisObject.getAnimation().play()` on a `startpaused` single runs once and holds;
  - `animationEvent` fires once per crossing, forward and backward, including a loop wrap;
  - two displays keep separate clocks.

**T3 — The renderer** (owns `Scene/Format/SceneObject.swift`, the animation fields; `Scene/Rendering/SceneObjectMotion.swift`; `Scene/Rendering/SceneMetalRenderer.swift`; `Scene/Rendering/SceneRenderContent.swift`; `Scene/Loading/SceneContentLoader.swift`; `Scene/Values/SceneValueSource.swift` and `SceneValueResolver.swift`; `Scene/Values/ShaderConstantResolver.swift`; `Scene/Rendering/EffectGraphRenderer.swift`, `ImageMaterialUniforms.swift`; and it deletes `Scene/Rendering/SceneTimeline.swift`).

- **Decoding.** Object fields keep the raw `animation` JSON and build T1 models. The `WEKeyframeAnimation` types and the invented fixture format go: `particle-animated-parent` is rewritten in WE's format.
- **Precedence (§2.6).** Script-owned beats animated, animated beats user or static. `SceneValueSource` nests the animation *outside* `user`. `relative` bakes on the authored value.
- **Where values come from.** Values are read from T2's set (per frame, per instance) instead of scene time.
- **Caches.** Animated constants stay dynamic for the static-chain cache (`UniformProgram.isStatic`).
- **Sprite frames.** The texture frame comes from T5a's clock, through a hook T5a provides.
- **Tests:** headless renders through the real loader:
  - an alpha loop at t = 0, ¼, ½ against the oracle;
  - a relative origin moves by its offsets;
  - a `startpaused` constant holds its first keyframe (not `value`);
  - a scripted `update(v){return v}` on an animated field draws the animation;
  - an accumulator on an animated field does not run away;
  - E7: origin, scale and angles animate.
  - Also re-run `LibrarySweepTests` and the particle-parent tests.

### Phase C (after B)

**T6 — Library verification and performance** (owns new test files only). Done: `TimelineLibraryRenderTests`, `TimelineCostTests`, the optimisation pass (§4) and the script cost table (docs/scenescript-plan.md).

- A headless render sweep over the 15 animated items at fixed times, recording each animated field's drawn value against the T0 fixture.
- Frame-time cost: the Bézier cache is filled lazily; 600-frame channels must cost nothing after warm-up.
- The `SceneScriptLibraryCostTests` table is updated.

**T7 — Sprite-sheet effect textures** (roadmap notes 8.15; owns the effect texture binding in `EffectGraphRenderer`, after T3 lands). Done. Effect and material textures with TEXS frames read the shared clock, and `g_Texture<n>Rotation/Translation` per frame.

**Later, with areas 6 and 7:** animation layers, the puppet `animationEvent` and bones (§3.4).

### Open questions (need WE ground truth; add to test-risks "needs WE ground truth")

- **`rate`:** the default and the conversion of the value written to it. We assume 1 and any number.
- **`delta`:** whether the delta at `0x1401802e5` equals `engine.frametime` (it matters when the speed slider is below 1).
- **User changes and `relative`:** does a user change re-bake a `relative` animation, or does WE reload the scene?
- **Precision:** float32 `frac` at the end of a single (0 or ≈1).
- **Flag 4:** what `options.random` does, since the clock ignores it.
