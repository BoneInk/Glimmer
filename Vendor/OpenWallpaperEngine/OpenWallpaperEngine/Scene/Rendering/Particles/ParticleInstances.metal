#include "ParticleShared.h"

// Instanced child systems on the GPU (`ParticleChildLink`): every instance follows its source,
// finished ones retire, new ones start for the parent's events and each decides its emission,
// handed out in slot order to events in their parent's particle order. An event child reads its
// parent's step without a CPU round trip: after the parent's step, `particleEventMark` flags the
// parent particles that make an event (spawned or died this step, and passing the link's
// probability), a prefix sum orders them, `particleEventScatter` lists them, and
// `particleInstanceStep` hands them out to free instances in slot order, updates the instances and
// decides each one's emission. It replaces `particleBegin` for an instanced system; emission,
// simulation and compaction then run as for any system.

/// Flags the parent particle `gid` when it makes an event for this child.
kernel void particleEventMark(device const ParticleState *parentStepped [[buffer(0)]],
                              device const uint *parentAlive [[buffer(1)]],
                              device const uint *parentControl [[buffer(2)]],
                              device uint *flags [[buffer(3)]],
                              constant ParticleParameters &p [[buffer(4)]],
                              uint gid [[thread_position_in_grid]]) {
    if (gid >= parentControl[cTotal]) return;
    const ParticleState particle = parentStepped[gid];
    bool event;
    if (p.instancing.x == lDeath) {
        event = parentAlive[gid] == 0;
    } else {
        event = particle.identity.x - parentControl[cSerialBase] < parentControl[cEmit];
    }
    if (event) event = unitRandom(p.counts.z, particle.identity.x, sEventProbability) < p.link.x;
    flags[gid] = event ? 1 : 0;
}

/// Lists the flagged parent particles in order (`particleScanBlocks` numbered them).
kernel void particleEventScatter(device const uint *flags [[buffer(0)]],
                                 device const uint *offsets [[buffer(1)]],
                                 device const uint *blockSums [[buffer(2)]],
                                 device const uint *parentControl [[buffer(3)]],
                                 device uint *events [[buffer(4)]],
                                 uint gid [[thread_position_in_grid]]) {
    if (gid >= parentControl[cTotal] || flags[gid] == 0) return;
    events[offsets[gid] + blockSums[gid / kGroup]] = gid;
}

/// An instance takes its source particle's place and values (`follow`, `spawn`).
static void trackSource(thread ParticleInstanceState &instance, ParticleState particle) {
    instance.place.xy = particle.positionVelocity.xy;
    instance.source = float4(particle.positionVelocity.zw, particle.life.z, particle.alphaRotation.z);
    instance.sourceColor = float4(particle.color.xyz, particle.alphaRotation.x);
    instance.emission.x = particle.alphaRotation.w;
    instance.emission.y = particle.depth.y;
}

/// Takes another instance's source (a static child of an instanced system inherits from its parent
/// instance's event).
static void inheritSource(thread ParticleInstanceState &instance, ParticleInstanceState parent) {
    instance.source = parent.source;
    instance.sourceColor = parent.sourceColor;
    instance.emission.xy = parent.emission.xy;
}

/// The parent particle with `serial`, by binary search (particles stay in spawn order); `count`
/// when there is none.
static uint findSerial(device const ParticleState *particles, uint count, uint serial) {
    if (count == 0) return 0;
    const uint first = particles[0].identity.x;
    uint low = 0, high = count;
    while (low < high) {
        const uint middle = (low + high) / 2;
        if (particles[middle].identity.x - first < serial - first) low = middle + 1; else high = middle;
    }
    return low < count && particles[low].identity.x == serial ? low : count;
}

/// `ParticleEmitterClock.phaseLength`.
static float phaseLength(uint phase, constant ParticleParameters &p, EmitterParameters e, uint key) {
    const bool emitting = phase % 2 == 0;
    const float2 range = emitting ? e.timing.zw : e.period.xy;
    return randomValue(range.x, range.y, p.counts.z + key * 0x9E3779B9u, phase, emitting ? sPeriodDuration : sPeriodDelay);
}

/// `ParticleEmitterClock.advance`: whether the rate emits (x), the burst goes out (y) and a
/// period starts (z).
static uint3 advanceClock(thread float4 &clock, float deltaTime, constant ParticleParameters &p, EmitterParameters e,
                          uint key) {
    const float delay = e.timing.x, duration = e.timing.y;
    const bool periodic = e.period.z > 0.5;
    clock.x += deltaTime;
    const bool running = duration <= 0 || clock.x - delay < duration;
    if (clock.z == 0) {
        if (clock.x < delay) return uint3(0);
        clock.z = 1;
        clock.y = periodic ? phaseLength(0, p, e, key) : 0;
        clock.w = 0;
        return uint3(running ? 1 : 0, 1, 1);
    }
    uint3 step = uint3(0);
    if (periodic) {
        clock.y -= deltaTime;
        if (clock.y <= 0) {
            const uint phase = uint(clock.z);
            clock.z += 1;
            clock.y = phaseLength(phase, p, e, key);
            if (phase % 2 == 0) {
                clock.w = 0;
                step.z = 1;
                step.y = running ? 1 : 0;
            }
        }
    }
    step.x = running && (!periodic || uint(clock.z - 1) % 2 == 0) ? 1 : 0;
    return step;
}

/// One instance's emission this step: every emitter on its own
/// clock, each counting what the earlier ones spawned.
static uint instanceEmission(thread ParticleInstanceState &instance, uint slot, constant ParticleParameters &p,
                             constant ParticleFrame &f, constant EmitterParameters *emitterParameters,
                             constant EmitterStep *steps, device EmitterState *emitters) {
    // Names an instance's random periods: its event (the parent particle's serial) and its slot.
    const uint key = instance.state.y * 31u + slot + 1u;
    const uint emitterCount = p.instancing.z;
    uint live = instance.state.z;
    uint spawnedHere = 0;
    uint restart = instance.spawn.z;
    for (uint e = 0; e < emitterCount; ++e) {
        EmitterState state = emitters[e];
        const EmitterParameters parameters = emitterParameters[e];
        const EmitterStep step = steps[e];
        // `ParticleEmitterState.clockKey`.
        const uint3 clock = advanceClock(state.clock, f.time.x, p, parameters, key + e * 0x632BE5ABu);
        float carry = state.carry.x;
        const uint2 spawned = emission(int(live), int(f.extra.y), clock.x ? step.rate.x : 0.0f, f.time.x, carry,
                                       clock.y ? int(parameters.flags.z) : 0, rateLimit(step, uint(state.clock.w)));
        state.carry.x = carry;
        state.clock.w += float(spawned.y);
        if (clock.z) restart = instance.spawn.y + spawnedHere;
        state.counts.y = spawnedHere;
        state.counts.z = spawned.x + spawned.y;
        state.counts.w = restart;
        if (state.counts.z > 0) spawnsLayerWorld(state, step);
        emitters[e] = state;
        spawnedHere += state.counts.z;
        live += state.counts.z;
    }
    instance.spawn.z = restart;
    return spawnedHere;
}

/// Clears the emitter states of instance `slot` (a new instance's emitters start afresh).
static void resetEmitters(device EmitterState *emitters, uint emitterCount) {
    for (uint e = 0; e < emitterCount; ++e) emitters[e] = EmitterState{};
}

/// One step of the instances before their particles spawn (follow sources, retire finished
/// instances, start instances for the parent's events, decide each one's emission), then the
/// step's counters as `particleBegin` sets them.
/// One thread: instances are few, and handing out slots in order keeps it deterministic.
kernel void particleInstanceStep(device uint *control [[buffer(0)]],
                                 device ParticleInstanceState *instances [[buffer(1)]],
                                 constant ParticleParameters &p [[buffer(2)]],
                                 constant ParticleFrame &f [[buffer(3)]],
                                 device const ParticleState *parentStepped [[buffer(4)]],
                                 device const ParticleState *parentParticles [[buffer(5)]],
                                 device const uint *parentControl [[buffer(6)]],
                                 device const uint *events [[buffer(7)]],
                                 device const ParticleInstanceState *parentInstances [[buffer(8)]],
                                 constant EmitterParameters *emitterParameters [[buffer(9)]],
                                 constant EmitterStep *steps [[buffer(10)]],
                                 device EmitterState *emitters [[buffer(11)]]) {
    const uint slots = p.instancing.y;
    const uint emitterCount = p.instancing.z;
    const uint kind = p.instancing.x;
    uint count = control[cCount];
    const uint dead = control[cDead];
    uint emitted = 0;
    if (f.misc.y > 0.5) {
        count = 0;
        for (uint slot = 0; slot < slots; ++slot) {
            instances[slot] = ParticleInstanceState{};
            resetEmitters(emitters + slot * emitterCount, emitterCount);
        }
    } else {
        const uint parentCount = parentControl[cCount];
        for (uint slot = 0; slot < slots; ++slot) {
            ParticleInstanceState instance = instances[slot];
            instance.place.zw = instance.place.xy;
            // Last step's spawns join the instance's sequence.
            instance.spawn.y += instance.spawn.x;
            instance.spawn.x = 0;
            if (kind == lStatic) {
                const ParticleInstanceState source = parentInstances[slot];
                if (source.state.x & iFresh) {
                    const uint live = instance.state.z;
                    instance = ParticleInstanceState{};
                    resetEmitters(emitters + slot * emitterCount, emitterCount);
                    instance.state.x = iActive | iEmitting | iFresh;
                    instance.state.z = live;
                    instance.place = float4(source.place.xy, source.place.xy);
                    inheritSource(instance, source);
                } else if (instance.state.x & iActive) {
                    instance.state.x &= ~iFresh;
                    instance.place.xy = source.place.xy;
                    inheritSource(instance, source);
                    const bool emitting = (source.state.x & iActive) != 0;
                    instance.state.x = emitting ? (instance.state.x | iEmitting) : (instance.state.x & ~iEmitting);
                }
            } else if (instance.state.x & iActive) {
                instance.state.x &= ~(iFresh | iClearing);
                if (kind == lFollow || kind == lSpawn) {
                    if (instance.state.x & iEmitting) {
                        const uint found = findSerial(parentParticles, parentCount, instance.state.y);
                        if (found < parentCount) {
                            trackSource(instance, parentParticles[found]);
                        } else {
                            instance.state.x &= ~iEmitting;
                            if (kind == lFollow) instance.state.x |= iClearing;
                        }
                    }
                } else {
                    instance.state.x &= ~iEmitting;
                }
            }
            const uint state = instance.state.x;
            if ((state & iActive) && !(state & (iEmitting | iClearing | iFresh)) && instance.state.z == 0) {
                instance = ParticleInstanceState{};
                resetEmitters(emitters + slot * emitterCount, emitterCount);
            }
            instances[slot] = instance;
        }
        if (kind != lStatic) {
            const uint eventCount = control[cEventTotal];
            uint slot = 0;
            for (uint event = 0; event < eventCount; ++event) {
                while (slot < slots && (instances[slot].state.x & iActive)) ++slot;
                if (slot >= slots) break;
                const ParticleState source = parentStepped[events[event]];
                ParticleInstanceState instance = ParticleInstanceState{};
                instance.state.x = iActive | iEmitting | iFresh;
                instance.state.y = source.identity.x;
                trackSource(instance, source);
                instance.place.zw = instance.place.xy;
                instances[slot] = instance;
                resetEmitters(emitters + slot * emitterCount, emitterCount);
            }
        }
        for (uint slot = 0; slot < slots; ++slot) {
            ParticleInstanceState instance = instances[slot];
            instance.state.w = emitted;
            if ((instance.state.x & iActive) && (instance.state.x & iEmitting)) {
                instance.spawn.x = instanceEmission(instance, slot, p, f, emitterParameters, steps,
                                                    emitters + slot * emitterCount);
                emitted += instance.spawn.x;
            } else {
                // Spawns nothing: the emit step finds no emitter spawning in it.
                for (uint e = 0; e < emitterCount; ++e) emitters[slot * emitterCount + e].counts.yz = uint2(0);
            }
            // Counted afresh by this step's simulation.
            instance.state.z = 0;
            instances[slot] = instance;
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

/// The parent particles a linked child's control points take
/// this step, one thread per instance (1 for a system without instances). After the parent's step.
kernel void particleLinkPoints(device const ParticleState *parentParticles [[buffer(0)]],
                               device const uint *parentControl [[buffer(1)]],
                               device LinkedPoints *linked [[buffer(2)]],
                               constant ParticleParameters &p [[buffer(3)]],
                               constant uint &slots [[buffer(4)]],
                               uint slot [[thread_position_in_grid]]) {
    if (slot >= slots) return;
    const uint start = p.linking.y;
    const uint wanted = start < 8 ? 8 - start : 0;
    const bool perInstance = p.linking.z != 0;
    LinkedPoints points;
    for (uint i = 0; i < 8; ++i) points.points[i] = float4(0);
    uint count = 0;
    const uint total = parentControl[cCount];
    for (uint index = 0; index < total && count < wanted; ++index) {
        const ParticleState particle = parentParticles[index];
        if (perInstance && uint(particle.trail.z) != slot) continue;
        points.points[count] = float4(particle.positionVelocity.xy, particle.depth.x, 0);
        ++count;
    }
    points.count = uint4(count, 0, 0, 0);
    linked[slot] = points;
}
