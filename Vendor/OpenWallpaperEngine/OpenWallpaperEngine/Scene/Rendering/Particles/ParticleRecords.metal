#include "ParticleShared.h"

// The GPU step's last stage: record counts, indirect draw arguments and the records a system is
// drawn from, for WE's particle materials and for the renderer's built-in draw. Run by
// `ParticleGPUSimulator` after the step.

// MARK: - Draw

/// Record counts and indirect draw arguments; patches a rope's `g_RenderVar0` point count.
kernel void particleFinish(device uint *control [[buffer(0)]],
                           device float *uniforms [[buffer(1)]],
                           constant ParticleParameters &p [[buffer(2)]],
                           constant ParticleFrame &f [[buffer(3)]]) {
    const uint count = control[cCount];
    const uint segments = count > 0 ? count - 1 : 0;
    const uint subdivision = uint(p.trail.z);
    uint material = count, fallback = count;
    switch (f.indices.w) {
    case kDrawRope: material = segments; break;
    case kDrawRopeTrail: material = control[cTrailTotal]; break;
    case kFallbackRope: fallback = segments * subdivision; break;
    case kFallbackRopeTrail: fallback = control[cTrailTotal] * subdivision; break;
    default: break;
    }
    // Index count, instances, first index, base vertex, base instance.
    control[cMaterialDraw] = f.indices.y;
    control[cMaterialDraw + 1] = material;
    control[cMaterialDraw + 2] = 0;
    control[cMaterialDraw + 3] = 0;
    control[cMaterialDraw + 4] = 0;
    control[cFallbackDraw] = 4;
    control[cFallbackDraw + 1] = fallback;
    control[cFallbackDraw + 2] = 0;
    control[cFallbackDraw + 3] = 0;
    if (f.indices.z != 0xFFFFFFFFu) {
        const float points = float(count);
        device float *renderVar = uniforms + f.indices.z;
        renderVar[0] = points;
        renderVar[1] = 0;
        renderVar[2] = 1;
        renderVar[3] = points;
    }
}

/// A renderer after a system's first (`ParticleSystemRuntime.simulation`) draws the particles the
/// system's step left: that step's counters and dispatch arguments into its own control block,
/// before its own draw arguments and records are written.
kernel void particleFollowControl(device const uint *simulation [[buffer(0)]],
                                  device uint *control [[buffer(1)]],
                                  uint gid [[thread_position_in_grid]]) {
    if (gid < cMaterialDraw) control[gid] = simulation[gid];
}

/// One particle's record.
static SpriteRecord spriteRecord(ParticleState particle, constant ParticleParameters &p, constant ParticleFrame &f) {
    SpriteRecord record;
    record.position = float4(particle.positionVelocity.xy, particle.depth.x, 0);
    // Sprites take the emitter's transform through `g_Orientation*`; trails scale by its area.
    record.rotationSize = float4(particle.spin.xy, particle.alphaRotation.z, particle.life.z * f.motionExtras.w);

    record.velocityLifetime = float4(particle.positionVelocity.zw, particle.depth.y, spritePhase(particle, p));
    record.color = recordColor(particle, p, f);
    return record;
}

/// A sprite record for every live particle.
kernel void particleWriteSprites(device const ParticleState *particles [[buffer(0)]],
                                 device SpriteRecord *records [[buffer(1)]],
                                 device const uint *control [[buffer(2)]],
                                 constant ParticleParameters &p [[buffer(3)]],
                                 constant ParticleFrame &f [[buffer(4)]],
                                 uint gid [[thread_position_in_grid]]) {
    if (gid >= control[cCount]) return;
    records[gid] = spriteRecord(particles[gid], p, f);
}

/// A rope's strands (one per instance) for an instanced system, in O(n): a stable counting sort of
/// the particle indices by instance. `order` holds each instance's first place (`slots` words), its length
/// (`slots`), the sorted indices (`capacity`), then each particle's place in its strand. One thread,
/// since the sort must keep spawn order within an instance.
kernel void particleRopeOrder(device const ParticleState *particles [[buffer(0)]],
                              device uint *order [[buffer(1)]],
                              device const uint *control [[buffer(2)]],
                              constant uint2 &sizes [[buffer(3)]],
                              uint gid [[thread_position_in_grid]]) {
    if (gid != 0) return;
    const uint count = control[cCount];
    const uint slots = max(sizes.x, 1u);
    device uint *starts = order;
    device uint *lengths = order + slots;
    device uint *sorted = order + slots * 2;
    device uint *rank = sorted + sizes.y;
    for (uint s = 0; s < slots; ++s) lengths[s] = 0;
    for (uint i = 0; i < count; ++i) {
        const uint s = min(uint(particles[i].trail.z), slots - 1);
        rank[i] = lengths[s];
        lengths[s] += 1;
    }
    uint running = 0;
    for (uint s = 0; s < slots; ++s) {
        starts[s] = running;
        running += lengths[s];
    }
    for (uint i = 0; i < count; ++i) {
        const uint s = min(uint(particles[i].trail.z), slots - 1);
        sorted[starts[s] + rank[i]] = i;
    }
}

/// The rope strand of particle `gid`: the next and previous particle of its strand (`count`
/// for none), its place on the strand, the strand's length and its oldest particle. A system without
/// instances is one strand; an instanced one has one per instance, read from `particleRopeOrder`'s
/// `order` (`sizes`: slots, capacity).
struct RopeNeighbours { uint next, previous, index, length, oldest; };

static RopeNeighbours ropeNeighbours(device const ParticleState *particles, uint count, uint gid,
                                     constant ParticleParameters &p, device const uint *order, uint2 sizes) {
    RopeNeighbours n;
    if (!(p.counts.y & kInstanced)) {
        n.next = gid + 1 < count ? gid + 1 : count;
        n.previous = gid > 0 ? gid - 1 : count;
        n.index = gid;
        n.length = count;
        n.oldest = 0;
        return n;
    }
    const uint slots = max(sizes.x, 1u);
    const uint s = min(uint(particles[gid].trail.z), slots - 1);
    device const uint *sorted = order + slots * 2;
    const uint start = order[s];
    n.length = order[slots + s];
    n.index = sorted[sizes.y + gid];
    n.next = n.index + 1 < n.length ? sorted[start + n.index + 1] : count;
    n.previous = n.index > 0 ? sorted[start + n.index - 1] : count;
    n.oldest = sorted[start];
    return n;
}

/// `ParticleRopeUV.layout`: a strand's point count (x) and the shift of its places (y).
static float2 ropeLayout(uint points, float oldestAge, uint died, constant ParticleParameters &p, constant ParticleFrame &f) {
    const float alive = float(points);
    float rate = f.rope.x;
    const float lifetime = f.rope.y;
    if (rate * lifetime > alive) rate = min(f.rope.z, rate);
    const float expected = rate * lifetime;
    float count = alive, shift = 0;
    if (p.counts.y & kRopeScrolling) {
        count = expected - 1;
        shift = float(died);
    } else if (expected > 0 && alive >= expected - 1 && (p.counts.y & kRopeSmoothing)) {
        count = expected - 1;
        shift = saturateValue((lifetime - oldestAge) * rate) - 1;
    }
    return float2(count * f.rope.w, shift);
}

/// One strand through the system (one per instance), oldest
/// particle first.
kernel void particleWriteRope(device const ParticleState *particles [[buffer(0)]],
                              device RopeRecord *records [[buffer(1)]],
                              device const uint *control [[buffer(2)]],
                              constant ParticleParameters &p [[buffer(3)]],
                              constant ParticleFrame &f [[buffer(4)]],
                              device const uint *order [[buffer(5)]],
                              constant uint2 &orderSizes [[buffer(6)]],
                              uint gid [[thread_position_in_grid]]) {
    const uint count = control[cCount];
    if (gid + 1 >= count) return;
    const RopeNeighbours n = ropeNeighbours(particles, count, gid, p, order, orderSizes);
    if (n.next == count) {
        records[gid] = RopeRecord{};
        return;
    }
    const ParticleState start = particles[gid];
    const ParticleState end = particles[n.next];
    const float2 previous = particles[n.previous < count ? n.previous : gid].positionVelocity.xy;
    const RopeNeighbours after = ropeNeighbours(particles, count, n.next, p, order, orderSizes);
    const float2 next = particles[after.next < count ? after.next : n.next].positionVelocity.xy;
    const float2 layout = ropeLayout(n.length, particles[n.oldest].life.x, control[cDied], p, f);
    RopeRecord record;
    record.start = float4(start.positionVelocity.xy, start.depth.x, start.life.z * f.motionExtras.w);
    record.end = float4(end.positionVelocity.xy, end.depth.x, layout.x);
    record.previous = float4(previous, 0, float(n.index) + layout.y);
    record.next = float4(next, 0, end.life.z * f.motionExtras.w);
    record.endColor = recordColor(end, p, f);
    record.color = recordColor(start, p, f);
    records[gid] = record;
}

/// A point of a `ropetrail` particle's trail, newest first: the particle, then its history.
static float2 trailPointNewestFirst(ParticleState particle, device const float2 *own, uint index) {
    if (index == 0) return particle.positionVelocity.xy;
    const int count = int(particle.identity.z);
    const int newest = (int(particle.identity.w) - 1 + count) % count;
    return own[(newest - (int(index) - 1) + count * 2) % count];
}

/// `ropetrail`: one strand per particle through its history, newest point first. Each segment holds
/// the strand's sample count over uvscale (WE's `in_ParticleTrailLength`, 0x1402334be…0x1402334d8),
/// or its own index when the trail scrolls, and its index (`in_ParticleTrailPosition`).
kernel void particleWriteRopeTrails(device const ParticleState *particles [[buffer(0)]],
                                    device RopeRecord *records [[buffer(1)]],
                                    device const float2 *history [[buffer(2)]],
                                    device const uint *offsets [[buffer(3)]],
                                    device const uint *blockSums [[buffer(4)]],
                                    device const uint *control [[buffer(5)]],
                                    constant ParticleParameters &p [[buffer(6)]],
                                    constant ParticleFrame &f [[buffer(7)]],
                                    uint gid [[thread_position_in_grid]]) {
    if (gid >= control[cCount]) return;
    const ParticleState particle = particles[gid];
    const uint count = particle.identity.z;
    if (count == 0) return;
    device const float2 *own = history + gid * p.counts.w;
    const uint base = offsets[gid] + blockSums[gid / kGroup];
    const uint points = count + 1;
    // WE's `in_ParticleTrailLength`: the samples over uvscale (`f.rope.w`).
    const float trailLength = float(count) * f.rope.w;
    const float4 rgba = recordColor(particle, p, f);
    const float size = particle.life.z * f.motionExtras.w;
    for (uint segment = 0; segment < points - 1; ++segment) {
        const float2 start = trailPointNewestFirst(particle, own, segment);
        const float2 end = trailPointNewestFirst(particle, own, segment + 1);
        const float2 previous = trailPointNewestFirst(particle, own, segment > 0 ? segment - 1 : 0);
        const float2 next = trailPointNewestFirst(particle, own, min(segment + 2, points - 1));
        RopeRecord record;
        record.start = float4(start, 0, size);
        // Scrolling trails read the segment as their vertex index (`in_TrailVertexIndex`).
        record.end = float4(end, 0, (p.counts.y & kRopeScrolling) ? float(segment) : trailLength);
        record.previous = float4(previous, 0, float(segment));
        record.next = float4(next, 0, size);
        record.endColor = rgba;
        record.color = rgba;
        records[base + segment] = record;
    }
}

// MARK: - Built-in draw

/// One `sprite` or `*trail` sprite through the renderer's own quad.
static FallbackInstance fallbackSprite(ParticleState particle, constant ParticleParameters &p, constant ParticleFrame &f) {
    const float opacity = particleOpacity(particle, p, f);
    FallbackInstance instance;
    if (f.indices.w == kFallbackSpriteTrail) {
        // `ComputeParticleTrailTangents` (common_particles.h): the quad is the size wide and the
        // size times the speed's stretch (`length`, clamped to `minlength`…`maxlength`) long.
        const float size = particle.life.z * f.motionExtras.w;
        const float2 velocity = particle.positionVelocity.zw;
        const float speed = length(velocity);
        const float stretch = max(p.trailLimits.y, min(speed * p.trail.y, p.trailLimits.x));
        const float width = p.sprite.w > 0.5 ? max(2.0f, size * 0.08f) : size;
        instance = fallbackInstance(particle.positionVelocity.xy, float2(width, size * stretch), opacity, f);
        instance.rotation = speed > 0.01f ? atan2(velocity.y, velocity.x) - M_PI_F / 2 : particle.alphaRotation.z;
    } else {
        const float size = particle.life.z;
        instance = fallbackInstance(particle.positionVelocity.xy, float2(size), opacity, f);
        instance.particleShape = 1;
        instance.rotation = particle.alphaRotation.z;
        spriteAxes(instance, float2x2(f.spriteLinear.xy, f.spriteLinear.zw), particle.alphaRotation.z, size, f);
    }
    instance.color = particle.color;
    const float4 cell = spriteSheetCell(particle, p);
    instance.uvOrigin = cell.xy;
    instance.uvAxisX = float2(cell.z, 0);
    instance.uvAxisY = float2(0, cell.w);
    return instance;
}

/// `sprite` and `*trail` sprites through the renderer's own quad.
kernel void particleWriteFallbackSprites(device const ParticleState *particles [[buffer(0)]],
                                         device FallbackInstance *instances [[buffer(1)]],
                                         device const uint *control [[buffer(2)]],
                                         constant ParticleParameters &p [[buffer(3)]],
                                         constant ParticleFrame &f [[buffer(4)]],
                                         uint gid [[thread_position_in_grid]]) {
    if (gid >= control[cCount]) return;
    instances[gid] = fallbackSprite(particles[gid], p, f);
}

// MARK: - Compaction with records

/// `particleCompact` for sprites (no trail history), writing each survivor's record where it
/// lands, so the sprite writers' pass over the compacted particles isn't needed.
kernel void particleCompactSprites(device const ParticleState *stepped [[buffer(0)]],
                                   device ParticleState *particles [[buffer(1)]],
                                   device const uint *alive [[buffer(2)]],
                                   device const uint *offsets [[buffer(3)]],
                                   device const uint *blockSums [[buffer(4)]],
                                   device const uint *control [[buffer(5)]],
                                   constant ParticleParameters &p [[buffer(6)]],
                                   constant ParticleFrame &f [[buffer(7)]],
                                   device SpriteRecord *records [[buffer(8)]],
                                   uint gid [[thread_position_in_grid]]) {
    if (gid >= control[cTotal] || alive[gid] == 0) return;
    const uint destination = offsets[gid] + blockSums[gid / kGroup];
    const ParticleState particle = stepped[gid];
    particles[destination] = particle;
    records[destination] = spriteRecord(particle, p, f);
}

/// `particleCompactSprites` for the built-in draw's sprites.
kernel void particleCompactFallbackSprites(device const ParticleState *stepped [[buffer(0)]],
                                           device ParticleState *particles [[buffer(1)]],
                                           device const uint *alive [[buffer(2)]],
                                           device const uint *offsets [[buffer(3)]],
                                           device const uint *blockSums [[buffer(4)]],
                                           device const uint *control [[buffer(5)]],
                                           constant ParticleParameters &p [[buffer(6)]],
                                           constant ParticleFrame &f [[buffer(7)]],
                                           device FallbackInstance *instances [[buffer(8)]],
                                           uint gid [[thread_position_in_grid]]) {
    if (gid >= control[cTotal] || alive[gid] == 0) return;
    const uint destination = offsets[gid] + blockSums[gid / kGroup];
    const ParticleState particle = stepped[gid];
    particles[destination] = particle;
    instances[destination] = fallbackSprite(particle, p, f);
}

/// A quad the built-in draw skips (shorter than 0.01): nothing drawn.
static FallbackInstance emptyInstance(constant ParticleFrame &f) {
    return fallbackInstance(float2(0), float2(0), 0, f);
}

/// `rope` through the built-in quad: `subdivision` Catmull-Rom pieces per segment.
kernel void particleWriteFallbackRope(device const ParticleState *particles [[buffer(0)]],
                                      device FallbackInstance *instances [[buffer(1)]],
                                      device const uint *control [[buffer(2)]],
                                      constant ParticleParameters &p [[buffer(3)]],
                                      constant ParticleFrame &f [[buffer(4)]],
                                      device const uint *order [[buffer(5)]],
                              constant uint2 &orderSizes [[buffer(6)]],
                              uint gid [[thread_position_in_grid]]) {
    const uint count = control[cCount];
    if (gid + 1 >= count) return;
    const uint subdivision = uint(p.trail.z);
    const RopeNeighbours n = ropeNeighbours(particles, count, gid, p, order, orderSizes);
    if (n.next == count) {
        for (uint step = 0; step < subdivision; ++step) instances[gid * subdivision + step] = emptyInstance(f);
        return;
    }
    const RopeNeighbours after = ropeNeighbours(particles, count, n.next, p, order, orderSizes);
    const ParticleState previous = particles[n.previous < count ? n.previous : gid];
    const ParticleState start = particles[gid];
    const ParticleState end = particles[n.next];
    const ParticleState following = particles[after.next < count ? after.next : n.next];
    const float startOpacity = particleOpacity(start, p, f), endOpacity = particleOpacity(end, p, f);
    for (uint step = 0; step < subdivision; ++step) {
        const float t0 = float(step) / float(subdivision);
        const float t1 = float(step + 1) / float(subdivision);
        // The piece's far end is the next spline point; the segment's last one is `end` itself.
        const float2 from = catmullRom(previous.positionVelocity.xy, start.positionVelocity.xy,
                                       end.positionVelocity.xy, following.positionVelocity.xy, t0);
        const bool last = step + 1 == subdivision;
        const float2 to = last ? end.positionVelocity.xy
            : catmullRom(previous.positionVelocity.xy, start.positionVelocity.xy,
                         end.positionVelocity.xy, following.positionVelocity.xy, t1);
        // A rope ribbon is twice the particle's size wide.
        const float scale = 2 * f.motionExtras.w;
        const float fromSize = (start.life.z + (end.life.z - start.life.z) * t0) * scale;
        const float toSize = (last ? end.life.z : start.life.z + (end.life.z - start.life.z) * t1) * scale;
        const float4 fromColor = mix(start.color, end.color, float4(t0));
        const float4 toColor = last ? end.color : mix(start.color, end.color, float4(t1));
        const float fromOpacity = startOpacity + (endOpacity - startOpacity) * t0;
        const float toOpacity = last ? endOpacity : startOpacity + (endOpacity - startOpacity) * t1;
        const float2 delta = to - from;
        const float pieceLength = length(delta);
        FallbackInstance instance = emptyInstance(f);
        if (pieceLength > 0.01f) {
            instance = fallbackInstance((from + to) / 2, float2(pieceLength, (fromSize + toSize) / 2),
                                        (fromOpacity + toOpacity) / 2, f);
            instance.rotation = atan2(delta.y, delta.x);
            instance.color = (fromColor + toColor) / 2;
        }
        instances[gid * subdivision + step] = instance;
    }
}

/// A point of a `ropetrail` particle's trail, oldest first: its history, then the particle.
static float2 trailPointOldestFirst(ParticleState particle, device const float2 *own, uint index) {
    const uint count = particle.identity.z;
    if (index >= count) return particle.positionVelocity.xy;
    return own[(particle.identity.w + index) % count];
}

/// `ropetrail` through the built-in quad: one Catmull-Rom strand per particle.
kernel void particleWriteFallbackRopeTrails(device const ParticleState *particles [[buffer(0)]],
                                            device FallbackInstance *instances [[buffer(1)]],
                                            device const float2 *history [[buffer(2)]],
                                            device const uint *offsets [[buffer(3)]],
                                            device const uint *blockSums [[buffer(4)]],
                                            device const uint *control [[buffer(5)]],
                                            constant ParticleParameters &p [[buffer(6)]],
                                            constant ParticleFrame &f [[buffer(7)]],
                                            uint gid [[thread_position_in_grid]]) {
    if (gid >= control[cCount]) return;
    const ParticleState particle = particles[gid];
    const uint count = particle.identity.z;
    if (count == 0) return;
    device const float2 *own = history + gid * p.counts.w;
    const uint subdivision = uint(p.trail.z);
    const uint base = (offsets[gid] + blockSums[gid / kGroup]) * subdivision;
    const uint points = count + 1;
    const uint pieces = (points - 1) * subdivision;
    const float opacity = particleOpacity(particle, p, f);
    const float4 cell = spriteSheetCell(particle, p);
    const bool fadeAlpha = (uint(p.trail.w) & 1u) != 0, fadeSize = (uint(p.trail.w) & 2u) != 0;
    for (uint segment = 0; segment < points - 1; ++segment) {
        const float2 previous = trailPointOldestFirst(particle, own, segment > 0 ? segment - 1 : segment);
        const float2 start = trailPointOldestFirst(particle, own, segment);
        const float2 end = trailPointOldestFirst(particle, own, segment + 1);
        const float2 following = trailPointOldestFirst(particle, own, segment + 2 < points ? segment + 2 : segment + 1);
        for (uint step = 0; step < subdivision; ++step) {
            const uint piece = segment * subdivision + step;
            const float2 from = catmullRom(previous, start, end, following, float(step) / float(subdivision));
            const bool last = step + 1 == subdivision;
            const float2 to = last ? end : catmullRom(previous, start, end, following, float(step + 1) / float(subdivision));
            const float2 delta = to - from;
            const float pieceLength = length(delta);
            FallbackInstance instance = emptyInstance(f);
            if (pieceLength > 0.01f) {
                // 0 at the oldest sample, 1 at the particle itself.
                const float progress = float(piece + 1) / float(pieces);
                // A rope ribbon is twice the particle's size wide.
                const float size = 2 * particle.life.z * f.motionExtras.w;
                const float width = fadeSize ? size * progress : size;
                instance = fallbackInstance((from + to) / 2, float2(pieceLength, max(width, 0.01f)),
                                            fadeAlpha ? opacity * progress : opacity, f);
                instance.rotation = atan2(delta.y, delta.x);
                instance.color = particle.color;
                instance.uvOrigin = cell.xy;
                instance.uvAxisX = float2(cell.z, 0);
                instance.uvAxisY = float2(0, cell.w);
            }
            instances[base + piece] = instance;
        }
    }
}
