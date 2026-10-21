#include "ParticleProgram.h"

// The particle simulation, on the GPU: WE's emission arithmetic, program (`ParticleProgram.h`)
// and random draws (`ParticleRandom`). Structures mirror `ParticleGPUTypes.swift`;
// `particleLayoutSizes` lets a test check the two agree (`ParticleGPULayoutTests`).
//
// One frame of one system, all in one compute encoder (`ParticleGPUSimulator`), in WE's order
// (`wallpaper64.exe` 0x140236cd0: age and die, emit and initialize, operate):
//   age → begin → emit → simulate → scan → compact → [trail scan] → finish → write records.
// Particles stay in spawn order: the compaction is an order-preserving prefix sum, so rope
// neighbours and boids' neighbours are WE's.

// MARK: - Step

/// Particles the boids slice was counted into (`particleBoidsScatter`).
constant uint cBoidsTotal = 5;

/// Every particle ages by the step; one past its lifetime dies. An
/// instanced system's instances lose their dead.
kernel void particleAge(device ParticleState *particles [[buffer(0)]],
                        device uint *alive [[buffer(1)]],
                        device uint *control [[buffer(2)]],
                        constant ParticleParameters &p [[buffer(3)]],
                        constant ParticleFrame &f [[buffer(4)]],
                        device ParticleInstanceState *instances [[buffer(5)]],
                        uint gid [[thread_position_in_grid]]) {
    if (gid >= control[cCount]) return;
    // Only the age changes: load and store its lifetime, not the whole particle.
    device ParticleState &particle = particles[gid];
    const float2 life = particle.life.xy;
    const float age = life.x + f.time.x;
    particle.life.x = age;
    const bool dies = life.y < age;
    alive[gid] = dies ? 0 : 1;
    if (!dies) return;
    atomic_fetch_add_explicit((device atomic_uint *)(control + cDead), 1u, memory_order_relaxed);
    if (p.counts.y & kInstanced) {
        // `state.z`: uint 18 of the 24 in an instance.
        device uint *live = (device uint *)(instances + uint(particle.trail.z)) + 18;
        atomic_fetch_sub_explicit((device atomic_uint *)live, 1u, memory_order_relaxed);
    }
}

/// Emission counts and the frame's dispatch size: every
/// emitter in turn, each counting what the earlier ones spawned (`wallpaper64.exe` 0x1402378a0).
kernel void particleBegin(device uint *control [[buffer(0)]],
                          constant ParticleParameters &p [[buffer(1)]],
                          constant ParticleFrame &f [[buffer(2)]],
                          constant EmitterStep *steps [[buffer(3)]],
                          device EmitterState *emitters [[buffer(4)]]) {
    uint count = control[cCount];
    const uint dead = control[cDead];
    const uint emitterCount = f.emission.y;
    uint emitted = 0;
    if (f.misc.y > 0.5) {
        count = 0;
        for (uint e = 0; e < emitterCount; ++e) {
            emitters[e].carry.x = 0;
            emitters[e].counts = uint4(0);
        }
    } else {
        const uint live = count - min(dead, count);
        for (uint e = 0; e < emitterCount; ++e) {
            const EmitterStep step = steps[e];
            EmitterState state = emitters[e];
            if (step.control.z != 0) {
                state.counts.x = 0;
                control[cPeriodSerial] = control[cSerial] + emitted;
            }
            float carry = state.carry.x;
            const uint2 spawned = emission(int(live + emitted), int(f.extra.y), step.rate.x, f.time.x, carry,
                                           int(step.control.x), rateLimit(step, state.counts.x));
            state.carry.x = carry;
            state.counts.x += spawned.y;
            state.counts.y = emitted;
            state.counts.z = spawned.x + spawned.y;
            state.counts.w = control[cPeriodSerial];
            if (state.counts.z > 0) spawnsLayerWorld(state, step);
            emitters[e] = state;
            emitted += state.counts.z;
        }
    }
    const uint total = count + emitted;
    control[cCount] = count;
    control[cEmit] = emitted;
    control[cTotal] = total;
    control[cLive] = total - min(f.misc.y > 0.5 ? 0u : dead, total);
    control[cDied] = f.misc.y > 0.5 ? 0u : control[cDied] + dead;
    control[cDead] = 0;
    control[cSerialBase] = control[cSerial];
    control[cSerial] = control[cSerial] + emitted;
    control[cDispatch] = max((total + kGroup - 1) / kGroup, 1u);
    control[cDispatch + 1] = 1;
    control[cDispatch + 2] = 1;
}

/// The emitter of spawn `index` among `emitters` (their first spawn and count, `counts.yz`).
static uint spawningEmitter(device const EmitterState *emitters, uint count, uint index) {
    for (uint e = 0; e + 1 < count; ++e) {
        if (index < emitters[e].counts.y + emitters[e].counts.z) return e;
    }
    return count > 0 ? count - 1 : 0;
}

/// The frame's control points for one instance (`ParticleFrameInputs.placed(at:previous:)`,
/// `linked`): the ones sitting in the scene don't move with it; linked ones are parent particles.
static void placeProgramPoints(thread ProgramContext &c, constant ParticleParameters &p, constant ParticleFrame &f,
                               float2 translation, float2 previousTranslation, bool linkedPoints, LinkedPoints linked) {
    c.origin = f.spaceMotion.xy + translation;
    for (uint i = 0; i < 8; ++i) {
        c.points[i] = f.controlPoints[i].xyz;
        c.previousPoints[i] = f.previousControlPoints[i].xyz;
        c.axes[i] = f.controlPointAxes[i];
        if (f.extra.x & (1u << i)) {
            c.points[i] -= float3(c.toSpace * translation, 0);
            c.previousPoints[i] -= float3(c.toSpace * previousTranslation, 0);
        }
    }
    if (!linkedPoints || p.linking.x == 0) return;
    const uint start = p.linking.y;
    for (uint i = 0; i < linked.count.x; ++i) {
        const uint index = start + i;
        if (index < max(start, 1u) || index >= 8) continue;
        const float4 position = linked.points[i];
        c.points[index] = float3(c.toSpace * (position.xy - c.origin), position.z);
    }
}

/// The program's view of the step for particle `serial`.
static ProgramContext programContext(constant ParticleParameters &p, constant ParticleFrame &f, uint serial) {
    ProgramContext c;
    c.deltaTime = f.time.x;
    c.dragDeltaTime = f.time.z;
    c.engineTime = f.time.w;
    c.systemTime = f.time.y;
    c.timeOfDay = f.misc.x;
    c.seed = p.counts.z;
    c.serial = serial;
    c.random = unitRandom(p.counts.z, serial, sOperator);
    c.space = float2x2(f.spaceLinear.xy, f.spaceLinear.zw);
    c.toSpace = float2x2(f.toSpace.xy, f.toSpace.zw);
    c.emitterAxes = float3x3(1);
    c.worldSpace = (p.counts.y & kWorldSpace) != 0;
    c.hasSource = false;
    c.source = ParticleInstanceState{};
    c.spawnScale = f.spawnScale;
    c.sequenceIndex = 0;
    c.sequenceRestartIndex = 0;
    c.layerOrigin = f.misc.zw;
    return c;
}

/// An affine transform of the plane: linear columns, translation.
static float2 placed(float4 linear, float2 translation, float2 point) {
    return float2x2(linear.xy, linear.zw) * point + translation;
}

/// A `layerimage` emitter's spawn, at one of its points at
/// random, through its bone on a rigged layer; with flag 0x40000 launched with the point's motion.
/// False without points.
static bool emitFromImage(EmitterParameters e, EmitterStep step, EmitterState emitterState, device const int4 *imagePoints,
                          constant ImageBone *bones, thread const ProgramContext &c, thread float3 &position,
                          thread float3 &velocity, thread float3 &color) {
    const uint count = e.image.y;
    if (count == 0) return false;
    const uint pick = min(uint(unitRandom(c.seed, c.serial, sSpawnAngle) * float(count)), count - 1);
    const int4 point = imagePoints[e.image.x + pick];
    float2 local = float2(point.xy);
    if (e.image.w != 0) {
        const float3 span = e.maximum.xyz - e.minimum.xyz;
        local += float2(e.minimum.x + unitRandom(c.seed, c.serial, sSpawnHeight) * span.x,
                        e.minimum.y + unitRandom(c.seed, c.serial, sSpawnRadius) * span.y);
    }
    const bool boned = point.w >= 0 && uint(point.w) < step.bones.y;
    const ImageBone bone = boned ? bones[step.bones.x + uint(point.w)] : ImageBone{};
    const float2 now = boned ? placed(bone.currentLinear, bone.translations.xy, local)
                             : placed(step.imageLinear, step.imageTranslation.xy, local);
    position = float3(now, 0);
    velocity = float3(0);
    const float frameTime = step.rate.y;
    if (e.flags.w != 0 && frameTime > 0) {
        float2 before;
        if (boned) {
            before = placed(bone.previousLinear, bone.translations.zw, local);
        } else {
            // The layer's world at the emitter's last step that spawned, the identity before one.
            const bool set = emitterState.spawnWorldTranslation.z != 0;
            const float2 world = set ? placed(emitterState.spawnWorldLinear, emitterState.spawnWorldTranslation.xy, local) : local;
            before = placed(step.toSpaceLinear, step.translations.zw, world);
        }
        const float share = (e.minimum.w + unitRandom(c.seed, c.serial, sEmitterSpeed) * (e.maximum.w - e.minimum.w)) * c.spawnScale.w;
        velocity = float3((now - before) / frameTime * share, 0);
    }
    color = e.image.z != 0 ? float3((point.z >> 16) & 0xff, (point.z >> 8) & 0xff, point.z & 0xff) / 255.0f : float3(1);
    return true;
}

/// A new particle: the emitter's shape, WE's base values and every initializer (0x14023b340:
/// lifetime 1, size 0.5, the instance colour and alpha). A `remapinitialvalue` that writes a
/// control point writes it into `inputs` for the spawns and the operators after it.
static ParticleState spawn(uint serial, constant ParticleParameters &p, constant ParticleFrame &f,
                           constant ProgramOp *program, thread ProgramContext &c, EmitterParameters emitter,
                           EmitterStep step, EmitterState emitterState, device const int4 *imagePoints,
                           constant ImageBone *bones) {
    ProgramState state;
    state.age = 0;
    state.lifetime = 1;
    state.size = 0;
    state.baseSize = 0.5f;
    state.alpha = 1;
    state.baseAlpha = f.spawnScale.y;
    state.rotation = 0;
    state.angularVelocity = 0;
    state.rotationXY = float2(0);
    state.angularVelocityXY = float2(0);
    state.color = float3(1);

    state.baseColor = f.colorScale.xyz;
    c.emitterAxes = programAxes(c, uint(emitter.origin.w));
    if (emitter.flags.x == 2) {
        state.position = float3(0);
        state.velocity = float3(0);
        float3 color;
        if (emitFromImage(emitter, step, emitterState, imagePoints, bones, c, state.position, state.velocity, color)) {
            state.baseColor *= color;
        }
    } else {
        emitParticle(emitter, c, state.position, state.velocity);
    }
    state.previous = state.position;
    runInitializers(program, f.extra.w & 0xFFFFu, state, c);
    const float size = state.baseSize * f.motionExtras.x;
    const uint frames = max(uint(p.spriteSheet.x), 1u);
    ParticleState particle;
    particle.positionVelocity = float4(c.space * state.position.xy + c.origin, c.space * state.velocity.xy);
    particle.life = float4(0, state.lifetime, size, size);
    particle.alphaRotation = float4(state.baseAlpha, state.baseAlpha, state.rotation + f.motionExtras.y, state.angularVelocity);
    particle.color = float4(state.baseColor, 1);
    particle.baseColor = particle.color;
    particle.trail = float4(0);
    particle.identity = uint4(serial, min(uint(unitRandom(p.counts.z, serial, sSpriteFrame) * float(frames)), frames - 1), 0, 0);
    particle.depth = float4(state.position.z, state.velocity.z, 0, 0);
    particle.spin = float4(state.rotationXY, state.angularVelocityXY);
    return particle;
}


/// The instance whose spawns this step include spawn `index` (a step spawns instance by
/// instance): the last one starting at or before it.
static uint spawningInstance(device const ParticleInstanceState *instances, uint count, uint index) {
    uint low = 0, high = count;
    while (low + 1 < high) {
        const uint middle = (low + high) / 2;
        if (instances[middle].state.w <= index) low = middle; else high = middle;
    }
    return low;
}

kernel void particleEmit(device ParticleState *particles [[buffer(0)]],
                         device const uint *control [[buffer(1)]],
                         constant ParticleParameters &p [[buffer(2)]],
                         constant ParticleFrame &f [[buffer(3)]],
                         device const ParticleInstanceState *instances [[buffer(4)]],
                         device const LinkedPoints *linked [[buffer(5)]],
                         constant ProgramOp *program [[buffer(6)]],
                         constant EmitterParameters *emitterParameters [[buffer(7)]],
                         device const EmitterState *emitters [[buffer(8)]],
                         constant EmitterStep *steps [[buffer(10)]],
                         device const int4 *imagePoints [[buffer(11)]],
                         constant ImageBone *bones [[buffer(12)]],
                         uint gid [[thread_position_in_grid]]) {
    if (gid >= control[cEmit]) return;
    const uint serial = control[cSerialBase] + gid;
    const uint emitterCount = p.instancing.z;
    ProgramContext c = programContext(p, f, serial);
    ParticleState particle;
    if (p.counts.y & kInstanced) {
        const uint instance = spawningInstance(instances, p.instancing.y, gid);
        const ParticleInstanceState source = instances[instance];
        placeProgramPoints(c, p, f, source.place.xy, source.place.zw, true, p.linking.x != 0 ? linked[instance] : LinkedPoints{});
        c.hasSource = true;
        c.source = source;
        const uint local = gid - source.state.w;
        device const EmitterState *own = emitters + instance * emitterCount;
        const uint e = spawningEmitter(own, emitterCount, local);
        const uint index = source.spawn.y + local;
        c.sequenceIndex = index;
        c.sequenceRestartIndex = index - own[e].counts.w;
        particle = spawn(serial, p, f, program, c, emitterParameters[e], steps[e], own[e], imagePoints, bones);
        particle.trail.z = float(instance);
    } else {
        placeProgramPoints(c, p, f, float2(0), float2(0), true, p.linking.x != 0 ? linked[0] : LinkedPoints{});
        const uint e = spawningEmitter(emitters, emitterCount, gid);
        c.sequenceIndex = serial;
        c.sequenceRestartIndex = serial - emitters[e].counts.w;
        particle = spawn(serial, p, f, program, c, emitterParameters[e], steps[e], emitters[e], imagePoints, bones);
    }
    particles[control[cCount] + gid] = particle;
}

/// Resolves a particle that moved from `previous` to `position` against a collision shape
/// (`ParticleCollisionPlacement`), the shape carried by `shift` (`moved(by:)`).
static void collide(CollisionPlacement collision, float2 shift, thread float2 &position, thread float2 &velocity,
                    thread float &angularVelocity, thread bool &dies, float2 previous) {
    float4 shape = collision.shape;
    const uint kind = uint(collision.response.w);
    if (collision.extra.z < 0.5) {
        if (kind == 0) shape.z += dot(shape.xy, shift);
        else shape.xy += shift;
    }
    float2 normal;
    if (kind == 0) {
        const float depth = dot(shape.xy, position) - shape.z;
        if (!(depth < 0)) return;
        position -= shape.xy * depth;
        normal = shape.xy;
    } else if (kind == 1) {
        const float2 offset = position - shape.xy;
        const float distance = length(offset);
        if (!(distance < shape.z)) return;
        normal = distance > 1e-6f ? offset / distance : float2(0, 1);
        position = shape.xy + normal * shape.z;
    } else {
        const float2 n = shape.zw;
        const float depth = dot(n, position - shape.xy);
        if (!(depth <= 0 && dot(n, previous - shape.xy) > 0 && abs(dot(position - shape.xy, collision.axis.xy)) < collision.axis.z
              && abs(dot(position - shape.xy, collision.extra.xy)) < collision.axis.w)) return;
        position -= n * depth * 1.05f;
        normal = n;
    }
    const uint behavior = uint(collision.response.y);
    if (behavior == 0) velocity += normal * dot(normal, velocity) * collision.response.x;
    else if (behavior == 1) velocity -= normal * dot(normal, velocity);
    else if (behavior == 2) velocity = float2(0);
    else dies = true;
    if (collision.response.z > 0.5) angularVelocity = 0;
}

/// A `collisionmodel`'s capsules against a particle (0x1402508c0 bounce, 0x140250e00 slide,
/// 0x140251320 stop, 0x1402517d0 delete), in 3D (the particle's depth is z). Every capsule tests
/// the particle where it was when the operator started, as a point: the closest point of the
/// segment, then a hit when it is nearer than the radius; the last capsule hit gives the normal
/// (away from the segment) and the depth. A hit pushes the particle out to the surface and bounces
/// (v += n·(n·v)·−(1 + bouncefactor)), slides (the normal part removed) or stops; "delete" only
/// kills it. The placements share their response.
static void collideCapsules(constant CollisionPlacement *collisions, uint first, uint end, thread float3 &position,
                            thread float3 &velocity, thread bool &dies) {
    const float3 point = position;
    bool hit = false;
    float3 normal = float3(0);
    float depth = 0;
    for (uint index = first; index < end; ++index) {
        const CollisionPlacement capsule = collisions[index];
        const float along = min(max(dot(point - capsule.shape.xyz, capsule.axis.xyz), 0.0f), capsule.shape.w);
        const float3 offset = point - (capsule.shape.xyz + capsule.axis.xyz * along);
        const float squared = dot(offset, offset);
        if (!(squared < capsule.axis.w * capsule.axis.w)) continue;
        const float distance = sqrt(squared);
        normal = distance > 1e-6f ? offset / distance : float3(0, 1, 0);
        depth = distance - capsule.axis.w;
        hit = true;
    }
    if (!hit) return;
    const float4 response = collisions[first].response;
    const uint behavior = uint(response.y);
    if (behavior == 3) {
        dies = true;
        return;
    }
    position -= normal * depth;
    if (behavior == 0) velocity += normal * (dot(normal, velocity) * response.x);
    else if (behavior == 1) velocity -= normal * dot(normal, velocity);
    else velocity = float3(0);
}

static bool programCollide(ProgramOp record, thread ProgramState &p, thread const ProgramContext &c,
                           constant CollisionPlacement *collisions, uint collisionCount, float2 shift) {
    const uint first = record.header.z & 0xFFFFu, count = record.header.z >> 16;
    float2 position = c.space * p.position.xy + c.origin;
    float2 velocity = c.space * p.velocity.xy;
    const float2 previous = c.space * p.previous.xy + c.origin;
    bool dies = false;
    const uint start = min(first, collisionCount), end = min(first + count, collisionCount);
    if (start < end && uint(collisions[start].response.w) == 3) {
        // `collisionmodel`: capsules stay where their model is (not carried by `shift`).
        float3 point = float3(position, p.position.z), motion = float3(velocity, p.velocity.z);
        collideCapsules(collisions, start, end, point, motion, dies);
        p.position = float3(c.toSpace * (point.xy - c.origin), point.z);
        p.velocity = float3(c.toSpace * motion.xy, motion.z);
        return dies;
    }
    for (uint index = first; index < min(first + count, collisionCount); ++index) {
        collide(collisions[index], shift, position, velocity, p.angularVelocity, dies, previous);
    }
    p.position = float3(c.toSpace * (position - c.origin), p.position.z);
    p.velocity = float3(c.toSpace * velocity, p.velocity.z);
    return dies;
}

/// Carries a particle along with its emitter's move, `linear`
/// and `translation`.
static void follow(thread ParticleState &particle, device float2 *own, constant ParticleParameters &p,
                   float2x2 linear, float2 translation) {
    particle.positionVelocity = float4(linear * particle.positionVelocity.xy + translation,
                                       linear * particle.positionVelocity.zw);
    if (p.counts.y & kHistory) {
        for (uint sample = 0; sample < particle.identity.z; ++sample) own[sample] = linear * own[sample] + translation;
    }
}

/// Particle `gid`'s place in its step: its instance's move and slot, and whether it clears.
struct SimulateStart {
    float2 shift, previousShift;
    uint slot;
    bool clearing;
    ParticleInstanceState instance;
};

/// The start of particle `gid`'s step: it follows its emitter's (or
/// its instance's) move. False for a particle that died aging, which stays as it is.
static bool beginSimulate(uint gid, thread ParticleState &particle, thread SimulateStart &start,
                          device const uint *alive, device float2 *history, uint aged, constant ParticleParameters &p,
                          constant ParticleFrame &f, device ParticleInstanceState *instances) {
    if (gid < aged && alive[gid] == 0) return false;
    const uint flags = p.counts.y;
    const float2x2 motion = float2x2(f.motionLinear.xy, f.motionLinear.zw);
    device float2 *own = history + gid * p.counts.w;
    start.shift = float2(0);
    start.previousShift = float2(0);
    start.clearing = false;
    start.instance = ParticleInstanceState{};
    start.slot = (flags & kInstanced) ? uint(particle.trail.z) : 0;
    if (flags & kInstanced) {
        // The instance's move around its own position.
        start.instance = instances[start.slot];
        start.shift = start.instance.place.xy;
        start.previousShift = start.instance.place.zw;
        start.clearing = (start.instance.state.x & iClearing) != 0;
        const bool moved = f.motionExtras.z > 0.5 || any(start.instance.place.xy != start.instance.place.zw);
        if (!(flags & kWorldSpace) && moved && gid < aged) {
            follow(particle, own, p, motion, start.instance.place.xy + f.spaceMotion.zw - motion * start.instance.place.zw);
        }
    } else if (f.motionExtras.z > 0.5 && gid < aged) {
        follow(particle, own, p, motion, f.spaceMotion.zw);
    }
    return true;
}

/// The program's view of particle `particle`'s step.
static ProgramContext simulateContext(ParticleState particle, SimulateStart start, constant ParticleParameters &p,
                                      constant ParticleFrame &f, device const LinkedPoints *linked) {
    ProgramContext c = programContext(p, f, particle.identity.x);
    placeProgramPoints(c, p, f, start.shift, start.previousShift, true,
                       p.linking.x != 0 ? linked[start.slot] : LinkedPoints{});
    if (p.counts.y & kInstanced) {
        c.hasSource = true;
        c.source = start.instance;
    }
    // `ParticleFrameInputs.substeps`: at a frame-rate limit of 20 or less the operators run twice,
    // in half steps.
    const uint substeps = max(f.emission.x, 1u);
    c.deltaTime /= float(substeps);
    c.dragDeltaTime /= float(substeps);
    return c;
}

/// `particle` as the program sees it, in the system's space.
static ProgramState simulateState(ParticleState particle, thread const ProgramContext &c) {
    ProgramState state;
    state.position = float3(c.toSpace * (particle.positionVelocity.xy - c.origin), particle.depth.x);
    state.velocity = float3(c.toSpace * particle.positionVelocity.zw, particle.depth.y);
    state.previous = state.position;
    state.age = particle.life.x;
    state.lifetime = particle.life.y;
    state.size = particle.life.z;
    state.baseSize = particle.life.w;
    state.alpha = particle.alphaRotation.x;
    state.baseAlpha = particle.alphaRotation.y;
    state.rotation = particle.alphaRotation.z;
    state.angularVelocity = particle.alphaRotation.w;
    state.rotationXY = particle.spin.xy;
    state.angularVelocityXY = particle.spin.zw;
    state.color = particle.color.xyz;

    state.baseColor = particle.baseColor.xyz;
    return state;
}

/// The step's result into `stepped`, with its trail history and
/// the instance's live count.
static void endSimulate(uint gid, ParticleState particle, ProgramState state, thread const ProgramContext &c, bool dies,
                        SimulateStart start, device ParticleState *stepped, device uint *alive, device float2 *history,
                        constant ParticleParameters &p, constant ParticleFrame &f,
                        device ParticleInstanceState *instances) {
    const uint flags = p.counts.y;
    device float2 *own = history + gid * p.counts.w;
    const float2 position = c.space * state.position.xy + c.origin;
    particle.positionVelocity = float4(position, c.space * state.velocity.xy);
    particle.life = float4(dies ? state.lifetime : particle.life.x, state.lifetime, state.size, particle.life.w);
    particle.alphaRotation = float4(state.alpha, particle.alphaRotation.y, state.rotation, state.angularVelocity);
    particle.color = float4(state.color, particle.color.w);
    particle.depth = float4(state.position.z, state.velocity.z, 0, 0);
    particle.spin = float4(state.rotationXY, state.angularVelocityXY);
    if (flags & kHistory) {

        // The system's countdown ran out (`ParticleFrameInputs.samplesTrail`), or the particle is new.
        const uint limit = p.counts.w;
        if (f.emission.z != 0 || particle.identity.z == 0) {
            if (particle.identity.z < limit) {
                own[particle.identity.z] = position;
                particle.identity.z += 1;
            } else {
                own[particle.identity.w] = position;
                particle.identity.w = (particle.identity.w + 1) % limit;
            }
        }
    }
    stepped[gid] = particle;
    const bool lives = !start.clearing;
    alive[gid] = lives ? 1 : 0;
    if ((flags & kInstanced) && lives) {
        // `state.z`: uint 18 of an instance.
        device uint *live = (device uint *)(instances + start.slot) + 18;
        atomic_fetch_add_explicit((device atomic_uint *)live, 1u, memory_order_relaxed);
    }
}

/// Every operator. Reads `particles` (boids read neighbours from
/// there too), writes `stepped`; particles that died aging stay dead.
kernel void particleSimulate(device const ParticleState *particles [[buffer(0)]],
                             device ParticleState *stepped [[buffer(1)]],
                             device uint *alive [[buffer(2)]],
                             device float2 *history [[buffer(3)]],
                             device const uint *control [[buffer(4)]],
                             constant ParticleParameters &p [[buffer(5)]],
                             constant ParticleFrame &f [[buffer(6)]],
                             device ParticleInstanceState *instances [[buffer(7)]],
                             constant CollisionPlacement *collisions [[buffer(8)]],
                             device const LinkedPoints *linked [[buffer(9)]],
                             constant ProgramOp *program [[buffer(10)]],
                             device const BoidsMember *boidsMembers [[buffer(11)]],
                             constant uint &listsBoids [[buffer(12)]],
                             uint gid [[thread_position_in_grid]]) {
    const uint total = control[cTotal];
    if (gid >= total) return;
    const uint aged = control[cCount];
    ParticleState particle = particles[gid];
    SimulateStart start;
    if (!beginSimulate(gid, particle, start, alive, history, aged, p, f, instances)) {
        stepped[gid] = particle;
        return;
    }
    ProgramContext c = simulateContext(particle, start, p, f, linked);
    ProgramState state = simulateState(particle, c);
    // The boids slice, when `particleBoidsScatter` listed it this step.
    const BoidsList boids = {boidsMembers, listsBoids != 0 ? control[cBoidsTotal] : ~0u};
    bool dies = false;
    for (uint substep = 0; substep < max(f.emission.x, 1u); ++substep) {
        dies = runOperators(program + (f.extra.w & 0xFFFFu), f.extra.w >> 16, state, c, collisions, f.extra.z, start.shift,
                            particles, total, gid, control[cLive], f.indices.x, alive, aged, boids) || dies;
    }
    endSimulate(gid, particle, state, c, dies, start, stepped, alive, history, p, f, instances);
}

// MARK: - Boids

/// Whether particle `gid` (below `control[cTotal]`) is in this step's boids slice, as the boids
/// operator decides it: alive after aging, and its serial's group of four in the frame's slice.
static bool inBoidsSlice(uint gid, device const ParticleState *particles, device const uint *alive,
                         device const uint *control, constant ParticleFrame &f) {
    if (gid < control[cCount] && alive[gid] == 0) return false;
    const uint slices = control[cLive] / 200 + 1;
    return (particles[gid].identity.x / 4) % slices == f.indices.x % slices;
}

/// Flags the boids slice's members into `flags`, which `particleScanBlocks` then numbers in place.
kernel void particleBoidsMark(device const ParticleState *particles [[buffer(0)]],
                              device const uint *alive [[buffer(1)]],
                              device const uint *control [[buffer(2)]],
                              constant ParticleFrame &f [[buffer(3)]],
                              device uint *flags [[buffer(4)]],
                              uint gid [[thread_position_in_grid]]) {
    if (gid >= control[cTotal]) return;
    flags[gid] = inBoidsSlice(gid, particles, alive, control, f) ? 1 : 0;
}

/// Lists the boids slice's members in particle order, so each member's boids read the slice
/// (about 200 particles) instead of every particle.
kernel void particleBoidsScatter(device const ParticleState *particles [[buffer(0)]],
                                 device const uint *alive [[buffer(1)]],
                                 device const uint *control [[buffer(2)]],
                                 constant ParticleFrame &f [[buffer(3)]],
                                 device const uint *offsets [[buffer(4)]],
                                 device const uint *blockSums [[buffer(5)]],
                                 device BoidsMember *members [[buffer(6)]],
                                 uint gid [[thread_position_in_grid]]) {
    if (gid >= control[cTotal] || !inBoidsSlice(gid, particles, alive, control, f)) return;
    const ParticleState particle = particles[gid];
    BoidsMember member;
    member.positionVelocity = particle.positionVelocity;
    member.depth = particle.depth.xy;
    member.index = gid;
    member.pad = 0;
    members[offsets[gid] + blockSums[gid / kGroup]] = member;
}

// MARK: - Control point writes

static void loadPoints(thread ProgramContext &c, device const float4 *points) {
    for (uint i = 0; i < 8; ++i) c.points[i] = points[i].xyz;
}

static void storePoints(device float4 *points, thread const ProgramContext &c) {
    for (uint i = 0; i < 8; ++i) points[i] = float4(c.points[i], 0);
}

/// The kept points of the last step: the previous points, and the points the object's instance
/// override drives while it doesn't change (`ParticleFrameInputs.keptPoints`, `f.misc`).
static void applyKeptPoints(thread ProgramContext &c, device const PointState &state, constant ParticleFrame &f) {
    if (state.flags.x == 0) return;
    const uint pinned = f.extra.x >> 8;
    for (uint i = 0; i < 8; ++i) {
        const float3 kept = state.kept[i].xyz;
        c.previousPoints[i] = kept;
        if (pinned & (1u << i)) c.points[i] = kept;
    }
}

/// `particleEmit` for a program whose initializers write control points: one thread spawns in order,
/// each spawn reading what the ones before it wrote. Also starts every slot's points for the step.
kernel void particleEmitSerial(device ParticleState *particles [[buffer(0)]],
                               device const uint *control [[buffer(1)]],
                               constant ParticleParameters &p [[buffer(2)]],
                               constant ParticleFrame &f [[buffer(3)]],
                               device const ParticleInstanceState *instances [[buffer(4)]],
                               device const LinkedPoints *linked [[buffer(5)]],
                               constant ProgramOp *program [[buffer(6)]],
                               constant EmitterParameters *emitterParameters [[buffer(7)]],
                               device const EmitterState *emitters [[buffer(8)]],
                               device PointState *points [[buffer(9)]],
                               constant EmitterStep *steps [[buffer(10)]],
                               device const int4 *imagePoints [[buffer(11)]],
                               constant ImageBone *bones [[buffer(12)]]) {
    const bool instanced = (p.counts.y & kInstanced) != 0;
    const uint slots = instanced ? max(p.instancing.y, 1u) : 1u;
    for (uint slot = 0; slot < slots; ++slot) {
        ProgramContext c = programContext(p, f, 0);
        const ParticleInstanceState source = instanced ? instances[slot] : ParticleInstanceState{};
        placeProgramPoints(c, p, f, source.place.xy, source.place.zw, true, p.linking.x != 0 ? linked[slot] : LinkedPoints{});
        applyKeptPoints(c, points[slot], f);
        storePoints(points[slot].points, c);
    }
    const uint emitterCount = p.instancing.z;
    const uint count = control[cEmit];
    for (uint gid = 0; gid < count; ++gid) {
        const uint serial = control[cSerialBase] + gid;
        ProgramContext c = programContext(p, f, serial);
        ParticleState particle;
        uint slot = 0;
        if (instanced) {
            slot = spawningInstance(instances, p.instancing.y, gid);
            const ParticleInstanceState source = instances[slot];
            placeProgramPoints(c, p, f, source.place.xy, source.place.zw, true, p.linking.x != 0 ? linked[slot] : LinkedPoints{});
            applyKeptPoints(c, points[slot], f);
            loadPoints(c, points[slot].points);
            c.hasSource = true;
            c.source = source;
            const uint local = gid - source.state.w;
            device const EmitterState *own = emitters + slot * emitterCount;
            const uint e = spawningEmitter(own, emitterCount, local);
            const uint index = source.spawn.y + local;
            c.sequenceIndex = index;
            c.sequenceRestartIndex = index - own[e].counts.w;
            particle = spawn(serial, p, f, program, c, emitterParameters[e], steps[e], own[e], imagePoints, bones);
            particle.trail.z = float(slot);
        } else {
            placeProgramPoints(c, p, f, float2(0), float2(0), true, p.linking.x != 0 ? linked[0] : LinkedPoints{});
            applyKeptPoints(c, points[0], f);
            loadPoints(c, points[0].points);
            const uint e = spawningEmitter(emitters, emitterCount, gid);
            c.sequenceIndex = serial;
            c.sequenceRestartIndex = serial - emitters[e].counts.w;
            particle = spawn(serial, p, f, program, c, emitterParameters[e], steps[e], emitters[e], imagePoints, bones);
        }
        storePoints(points[slot].points, c);
        particles[control[cCount] + gid] = particle;
    }
}

/// `particleSimulate` for a program whose operators write control points
/// (`ParticleProgram.operatorsWriteControlPoints`): one thread runs record by record over every
/// particle, groups of four reading the points the previous group left and the first of each
/// writing them. Keeps each slot's points for the next step.
kernel void particleSimulateSerial(device const ParticleState *particles [[buffer(0)]],
                                   device ParticleState *stepped [[buffer(1)]],
                                   device uint *alive [[buffer(2)]],
                                   device float2 *history [[buffer(3)]],
                                   device const uint *control [[buffer(4)]],
                                   constant ParticleParameters &p [[buffer(5)]],
                                   constant ParticleFrame &f [[buffer(6)]],
                                   device ParticleInstanceState *instances [[buffer(7)]],
                                   constant CollisionPlacement *collisions [[buffer(8)]],
                                   device const LinkedPoints *linked [[buffer(9)]],
                                   constant ProgramOp *program [[buffer(10)]],
                                   device PointState *points [[buffer(11)]],
                                   device SerialState *serial [[buffer(12)]]) {
    const uint total = control[cTotal];
    const uint aged = control[cCount];
    const bool instanced = (p.counts.y & kInstanced) != 0;
    const uint slots = instanced ? max(p.instancing.y, 1u) : 1u;
    constant ProgramOp *operators = program + (f.extra.w & 0xFFFFu);
    const uint operatorCount = f.extra.w >> 16;
    for (uint gid = 0; gid < total; ++gid) {
        ParticleState particle = particles[gid];
        SimulateStart start;
        if (!beginSimulate(gid, particle, start, alive, history, aged, p, f, instances)) {
            stepped[gid] = particle;
            continue;
        }
        stepped[gid] = particle;
        const ProgramContext c = simulateContext(particle, start, p, f, linked);
        serial[gid].state = simulateState(particle, c);
        serial[gid].dies = 0;
    }
    for (uint substep = 0; substep < max(f.emission.x, 1u); ++substep) {
        for (uint gid = 0; gid < total; ++gid) {
            if (gid < aged && alive[gid] == 0) continue;
            ProgramState state = serial[gid].state;
            beginRun(state);
            serial[gid].state = state;
        }
        for (uint k = 0; k < operatorCount; ++k) {
            for (uint slot = 0; slot < slots; ++slot) points[slot].flags.y = 0;
            for (uint gid = 0; gid < total; ++gid) {
                if (gid < aged && alive[gid] == 0) continue;
                const ParticleState particle = stepped[gid];
                SimulateStart start;
                start.slot = instanced ? uint(particle.trail.z) : 0;
                start.instance = instanced ? instances[start.slot] : ParticleInstanceState{};
                start.shift = start.instance.place.xy;
                start.previousShift = start.instance.place.zw;
                ProgramContext c = simulateContext(particle, start, p, f, linked);
                applyKeptPoints(c, points[start.slot], f);
                device PointState &own = points[start.slot];
                const bool first = own.flags.y % 4 == 0;
                if (first) {
                    for (uint i = 0; i < 8; ++i) own.group[i] = own.points[i];
                }
                loadPoints(c, own.group);
                ProgramState state = serial[gid].state;
                if (runOperator(operators[k], state, c, collisions, f.extra.z, start.shift, particles, total, gid,
                                control[cLive], f.indices.x, alive, aged, BoidsList{nullptr, ~0u})) {
                    serial[gid].dies = 1;
                }
                serial[gid].state = state;
                if (first) storePoints(own.points, c);
                own.flags.y += 1;
            }
        }
    }
    for (uint gid = 0; gid < total; ++gid) {
        if (gid < aged && alive[gid] == 0) continue;
        const ParticleState particle = stepped[gid];
        SimulateStart start;
        start.slot = instanced ? uint(particle.trail.z) : 0;
        start.instance = instanced ? instances[start.slot] : ParticleInstanceState{};
        start.shift = start.instance.place.xy;
        start.previousShift = start.instance.place.zw;
        start.clearing = (start.instance.state.x & iClearing) != 0;
        const ProgramContext c = simulateContext(particle, start, p, f, linked);
        endSimulate(gid, particle, serial[gid].state, c, serial[gid].dies != 0, start, stepped, alive, history, p, f,
                    instances);
    }
    // A system without instances keeps its points for the next step: as the previous points, and
    // on the points its instance override drives until the override changes (0x14022e468).
    for (uint slot = 0; slot < slots; ++slot) {
        for (uint i = 0; i < 8; ++i) points[slot].kept[i] = points[slot].points[i];
        points[slot].flags.x = instanced ? 0u : 1u;
    }
}

// MARK: - Compaction

/// Per-group exclusive prefix sums of `values` (`control[countIndex]` of them) and each group's total.
kernel void particleScanBlocks(device const uint *values [[buffer(0)]],
                               device uint *offsets [[buffer(1)]],
                               device uint *blockSums [[buffer(2)]],
                               device const uint *control [[buffer(3)]],
                               constant uint &countIndex [[buffer(4)]],
                               uint gid [[thread_position_in_grid]],
                               uint lid [[thread_index_in_threadgroup]],
                               uint group [[threadgroup_position_in_grid]],
                               uint lane [[thread_index_in_simdgroup]],
                               uint simdIndex [[simdgroup_index_in_threadgroup]],
                               uint simdCount [[simdgroups_per_threadgroup]]) {
    threadgroup uint totals[64];
    const uint count = control[countIndex];
    const uint value = gid < count ? values[gid] : 0;
    const uint prefix = groupExclusiveScan(value, lid, lane, simdIndex, simdCount, totals);
    if (gid < count) offsets[gid] = prefix;
    if (lid == kGroup - 1) blockSums[group] = prefix + value;
}

/// Turns the group totals into group offsets (one threadgroup) and stores the grand total in
/// `grandTotals[indices.y]`; the value count is `control[indices.x]`.
kernel void particleScanBlockSums(device uint *blockSums [[buffer(0)]],
                                  device const uint *control [[buffer(1)]],
                                  constant uint2 &indices [[buffer(2)]],
                                  device uint *grandTotals [[buffer(3)]],
                                  uint lid [[thread_index_in_threadgroup]],
                                  uint lane [[thread_index_in_simdgroup]],
                                  uint simdIndex [[simdgroup_index_in_threadgroup]],
                                  uint simdCount [[simdgroups_per_threadgroup]]) {
    threadgroup uint totals[64];
    threadgroup uint carry;
    const uint blocks = (control[indices.x] + kGroup - 1) / kGroup;
    if (lid == 0) carry = 0;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint base = 0; base < blocks; base += kGroup) {
        const uint index = base + lid;
        const uint value = index < blocks ? blockSums[index] : 0;
        const uint prefix = groupExclusiveScan(value, lid, lane, simdIndex, simdCount, totals);
        const uint running = carry;
        if (index < blocks) blockSums[index] = running + prefix;
        threadgroup_barrier(mem_flags::mem_threadgroup);
        if (lid == kGroup - 1) carry = running + prefix + value;
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    if (lid == 0) grandTotals[indices.y] = carry;
}

/// Moves the survivors back to `particles`, in order, with their trail history.
kernel void particleCompact(device const ParticleState *stepped [[buffer(0)]],
                            device ParticleState *particles [[buffer(1)]],
                            device const uint *alive [[buffer(2)]],
                            device const uint *offsets [[buffer(3)]],
                            device const uint *blockSums [[buffer(4)]],
                            device const float2 *history [[buffer(5)]],
                            device float2 *nextHistory [[buffer(6)]],
                            device uint *trailCounts [[buffer(7)]],
                            device const uint *control [[buffer(8)]],
                            constant ParticleParameters &p [[buffer(9)]],
                            uint gid [[thread_position_in_grid]]) {
    if (gid >= control[cTotal] || alive[gid] == 0) return;
    const uint destination = offsets[gid] + blockSums[gid / kGroup];
    const ParticleState particle = stepped[gid];
    particles[destination] = particle;
    if (p.counts.y & kHistory) {
        const uint limit = p.counts.w;
        for (uint sample = 0; sample < particle.identity.z; ++sample) {
            nextHistory[destination * limit + sample] = history[gid * limit + sample];
        }
        trailCounts[destination] = particle.identity.z;
    }
}

// MARK: - Layout

/// The sizes of the shared structures, for the layout test (`ParticleGPULayoutTests`).
kernel void particleLayoutSizes(device uint *sizes [[buffer(0)]]) {
    sizes[0] = sizeof(ParticleState);
    sizes[1] = sizeof(ParticleParameters);
    sizes[2] = sizeof(ParticleFrame);
    sizes[3] = sizeof(SpriteRecord);
    sizes[4] = sizeof(RopeRecord);
    sizes[5] = sizeof(FallbackInstance);
    sizes[6] = sizeof(ParticleInstanceState);
    sizes[7] = sizeof(CollisionPlacement);
    sizes[8] = sizeof(LinkedPoints);
    sizes[9] = sizeof(EmitterParameters);
    sizes[10] = sizeof(EmitterStep);
    sizes[11] = sizeof(EmitterState);
    sizes[12] = sizeof(PointState);
    sizes[13] = sizeof(SerialState);
}
