import Foundation

/// A clip of the `MDLA` section, versions 1–6 (docs/models-plan.md §1.4). A scene's
/// `animationlayers` name it by `id`.
public struct MDLAnimation: Equatable {
    /// How the clip plays past its end (0x1401a8c71): "mirror" ping-pongs, "single" plays once,
    /// any other name loops.
    public enum Mode: Equatable {
        case loop, mirror, single

        public init(name: String) {
            switch name {
            case "mirror": self = .mirror
            case "single": self = .single
            default: self = .loop
            }
        }
    }

    /// A bone or link track: `frames + 1` samples of 9 floats (`MDLBonePose`).
    public struct Track: Equatable {
        /// Bit 0: disabled, the bone keeps its bind pose.
        public var flags: UInt32
        public var samples: [Float]

        public var isDisabled: Bool { flags & 1 != 0 }

        /// The pose at `frame` (0…frames).
        public func pose(at frame: Int) -> MDLBonePose {
            let base = frame * MDLBonePose.floatCount
            return MDLBonePose(samples[base..<(base + MDLBonePose.floatCount)])
        }

        public init(flags: UInt32, samples: [Float]) {
            self.flags = flags
            self.samples = samples
        }
    }

    /// One float per frame: a constraint track (`tag` is its value) or one of the scalar lists
    /// (`tag` is the u32 WE skips before it).
    public struct ScalarTrack: Equatable {
        public var tag: UInt32
        public var samples: [Float]

        public init(tag: UInt32, samples: [Float]) {
            self.tag = tag
            self.samples = samples
        }
    }

    /// The morph-weight tracks of one mesh (`MDLA` 4 and later).
    public struct MeshTrack: Equatable {
        public struct MorphTrack: Equatable {
            public var morph: UInt16
            public var samples: [Float]

            public init(morph: UInt16, samples: [Float]) {
                self.morph = morph
                self.samples = samples
            }
        }

        /// Bit 0: `weight` and `morphTracks` follow.
        public var flags: UInt32
        public var weight: Float?
        public var morphTracks: [MorphTrack]?

        public init(flags: UInt32, weight: Float? = nil, morphTracks: [MorphTrack]? = nil) {
            self.flags = flags
            self.weight = weight
            self.morphTracks = morphTracks
        }
    }

    /// When flags & 1: the clip the model editor cut from an earlier one ("Add Clip"), with its
    /// root-motion bone (0x140264fc9…0x140265348, the 0xc0-byte record at anim+0x150: the index
    /// at +0x8, the four u32s at +0xc…+0x18). WE's editor writes one for every clip it cuts
    /// (docs/test-risks.md MG4: start 0, end 30, offset 0, bone −1 or 2 for a 30-frame clip).
    public struct Reference: Equatable {
        /// The clip it was cut from (earlier in the file).
        public var animation: UInt16
        /// The editor's Start frame and End frame, in the source clip; with root motion WE reads
        /// the root's start and end matrices there (unless the clip matches its loop, flag 0x400).
        public var startFrame: UInt32
        public var endFrame: UInt32
        /// The editor's Frame offset: a layer on the clip starts that many frames into it, its
        /// loop phase-shifted rather than delayed (WE 2.8's capture 509 E; `SceneAnimationLayer`).
        public var frameOffset: UInt32
        /// The editor's Motion root bone; −1 for None.
        public var rootBone: Int32

        public init(animation: UInt16, startFrame: UInt32, endFrame: UInt32, frameOffset: UInt32, rootBone: Int32) {
            self.animation = animation
            self.startFrame = startFrame
            self.endFrame = endFrame
            self.frameOffset = frameOffset
            self.rootBone = rootBone
        }
    }

    /// The clip flags the model editor sets (docs/test-risks.md MG4; 0x14021cc0c, 0x140225900).
    public enum Flag {
        /// `reference` follows.
        public static let reference: UInt32 = 0x1
        /// "Match loop" (on by default): the root's start and end matrices come from this clip's
        /// first and last frames rather than the source clip's Start and End frames.
        public static let matchLoop: UInt32 = 0x400
        /// Root motion on position x, y, z and rotation x, y, z; the editor offers only yaw of the
        /// rotations, and WE applies only yaw.
        public static let rootPositionX: UInt32 = 0x800
        public static let rootPositionY: UInt32 = 0x1000
        public static let rootPositionZ: UInt32 = 0x2000
        public static let rootRotationX: UInt32 = 0x4000
        public static let rootRotationY: UInt32 = 0x8000
        public static let rootRotationZ: UInt32 = 0x10000
        public static let rootMotion: UInt32 = 0x1f800
    }

    public struct Event: Equatable {
        public var frame: Float
        public var name: String

        public init(frame: Float, name: String) {
            self.frame = frame
            self.name = name
        }
    }

    public var id: UInt64
    public var name: String
    /// The mode as written; `mode` interprets it.
    public var modeName: String
    public var fps: Float
    /// The last frame index: every track has `frames + 1` samples.
    public var frames: UInt32
    /// `Flag`s: bit 0, `reference` follows; 0x400 Match loop; 0x1f800 the root-motion axes. WE
    /// sets 0x80000000 in its copy when a track is disabled.
    public var flags: UInt32
    /// One per bone in the library.
    public var boneTracks: [Track]
    /// `MDLA` 2 and later: one per skeleton link.
    public var linkTracks: [Track]?
    /// `MDLA` 2 and later: one per skeleton constraint.
    public var constraintTracks: [ScalarTrack]?
    /// `MDLA` 3 and later: one per Puppet Warp texture channel, its `g_BlendMap` entry (the
    /// clip's list at +0xd8, 0x1402646dc; the puppet update samples it at 0x1401fefa0…0x1401ffa2e).
    public var scalarTracksA: [ScalarTrack]?
    /// `MDLA` 3 and later, when present: one per bone track, the bone's keyed Opacity
    /// (`boneAlphaTracks`).
    public var scalarTracksB: [ScalarTrack]?
    /// `MDLA` 4 and later, when present: one per mesh.
    public var meshTracks: [MeshTrack]?
    /// `MDLA` 5 and later: the animated model's box.
    public var bounds: MDLBounds?
    /// `MDLA` 6 and later, when present: one per bone track, the bone's keyed Depth offset
    /// (`boneDepthTracks`).
    public var scalarTracksC: [ScalarTrack]?
    public var reference: Reference?
    public var events: [Event]

    /// Puppet Warp's per-bone Opacity keyed in the clip (WE 2.8's capture 509 F: the editor's
    /// animation track "Opacity" writes the second scalar list): `g_BonesAlpha`, which WE fades the
    /// bone's part by at run time.
    public var boneAlphaTracks: [ScalarTrack]? { scalarTracksB }
    /// Puppet Warp's per-bone Depth offset keyed in the clip, stepped (509 B: the editor's track
    /// "Depth offset" writes the third scalar list): added to the bone's depth
    /// (`MDLSkeleton.boneDepths`), it reorders the parts at run time.
    public var boneDepthTracks: [ScalarTrack]? { scalarTracksC }

    public var mode: Mode { Mode(name: modeName) }
    /// `frames / fps` seconds (0x1401a8c10).
    public var duration: Float { Float(frames) / fps }

    public init(id: UInt64, name: String, modeName: String, fps: Float, frames: UInt32, flags: UInt32, boneTracks: [Track], linkTracks: [Track]? = nil, constraintTracks: [ScalarTrack]? = nil, scalarTracksA: [ScalarTrack]? = nil, scalarTracksB: [ScalarTrack]? = nil, meshTracks: [MeshTrack]? = nil, bounds: MDLBounds? = nil, scalarTracksC: [ScalarTrack]? = nil, reference: Reference? = nil, events: [Event]) {
        self.id = id
        self.name = name
        self.modeName = modeName
        self.fps = fps
        self.frames = frames
        self.flags = flags
        self.boneTracks = boneTracks
        self.linkTracks = linkTracks
        self.constraintTracks = constraintTracks
        self.scalarTracksA = scalarTracksA
        self.scalarTracksB = scalarTracksB
        self.meshTracks = meshTracks
        self.bounds = bounds
        self.scalarTracksC = scalarTracksC
        self.reference = reference
        self.events = events
    }
}
