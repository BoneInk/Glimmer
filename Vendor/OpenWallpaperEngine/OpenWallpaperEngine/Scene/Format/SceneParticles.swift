import Foundation

struct WEParticleSystem: Codable {
    var emitter: [WEParticleEmitter]?
    var initializer: [WEParticleInitializer]?
    var `operator`: [WEParticleOperator]?
    var renderer: [WEParticleRenderer]?
    var material: String?
    @WEFlexibleInt var maxcount: Int?
    @WEFlexibleInt var flags: Int?
    @WEFlexibleDouble var starttime: Double?
    var animationmode: String?
    @WEFlexibleDouble var sequencemultiplier: Double?
    var controlpoint: [WEParticleControlPoint]?
    /// Child systems (`WEParticleChild`): static ones placed on this system, event ones spawned
    /// for its particles.
    var children: [WEParticleChild]?

    /// `flags` bit 0: particles ignore the system's transform once spawned (`worldspace`).
    var isWorldSpace: Bool { ((flags ?? 0) & 1) != 0 }
}

/// An entry of a particle system's `children`.
struct WEParticleChild: Codable {
    /// Path of the child's particle json.
    var name: String?
    /// `static` (the default), `eventfollow`, `eventspawn` or `eventdeath`.
    var type: String?
    var origin: WEFlexValue?
    var scale: WEFlexValue?
    var angles: WEFlexValue?
    /// Chance an event creates an instance of the child (default 1).
    @WEFlexibleDouble var probability: Double?
    /// Event children: how many instances of the child may exist at once (default 10).
    @WEFlexibleInt var maxcount: Int?
    /// Bit 0: the child's control points from `controlpointstartindex` on are this system's particles.
    @WEFlexibleInt var flags: Int?
    @WEFlexibleInt var controlpointstartindex: Int?
    @WEFlexibleInt var id: Int?
}

struct WEParticleEmitter: Codable {
    @WEFlexibleInt var id: Int?
    var name: String?
    @WEFlexibleDouble var rate: Double?
    var origin: WEFlexValue?
    var distancemax: WEFlexValue?
    var distancemin: WEFlexValue?
    @WEFlexibleDouble var speedmax: Double?
    @WEFlexibleDouble var speedmin: Double?
    @WEFlexibleInt var controlpoint: Int?
    /// Particles emitted at once when the emitter starts (and at each period, when periodic).
    @WEFlexibleInt var instantaneous: Int?
    /// Timing (`ParticleEmitterTiming`): seconds before it starts, seconds it emits (0: for ever).
    @WEFlexibleDouble var delay: Double?
    @WEFlexibleDouble var duration: Double?
    /// Bit 1: at most one particle a frame; bit 2: random periodic emission.
    @WEFlexibleInt var flags: Int?
    @WEFlexibleDouble var minperiodicduration: Double?
    @WEFlexibleDouble var maxperiodicduration: Double?
    @WEFlexibleDouble var minperiodicdelay: Double?
    @WEFlexibleDouble var maxperiodicdelay: Double?
    @WEFlexibleInt var maxtoemitperperiod: Int?
    /// Per-axis scale of the spawn shape ("1 1 0" by default).
    var directions: WEFlexValue?
    /// Per-axis sign the spawn offset is forced to (0 keeps both).
    var sign: WEFlexValue?
    /// A sphere's spread around its +x axis: 0 a full sphere, 1 one direction.
    @WEFlexibleDouble var cone: Double?
    /// `layerimage`: the random offset's range (flag 0x80000).
    var offsetmin: WEFlexValue?
    var offsetmax: WEFlexValue?
    /// Audio response: 0 off, 1 left, 2 right, 3 both channels (`ParticleAudioResponse`).
    @WEFlexibleInt var audioprocessingmode: Int?
    @WEFlexibleDouble var audioprocessingexponent: Double?
    var audioprocessingbounds: WEFlexValue?
    @WEFlexibleInt var audioprocessingfrequencystart: Int?
    @WEFlexibleInt var audioprocessingfrequencyend: Int?
}

struct WEParticleControlPoint: Codable {
    @WEFlexibleInt var id: Int?
    @WEFlexibleInt var flags: Int?
    var offset: String?
    var locktopointer: Bool?
    @WEFlexibleInt var parentcontrolpoint: Int?
}

struct WEParticleInitializer: Codable {
    @WEFlexibleInt var id: Int?
    var name: String?
    var min: WEFlexValue?
    var max: WEFlexValue?
    @WEFlexibleDouble var exponent: Double?
    // hsvcolorrandom, colorlist
    @WEFlexibleDouble var huemin: Double?
    @WEFlexibleDouble var huemax: Double?
    @WEFlexibleInt var huesteps: Int?
    @WEFlexibleDouble var saturationmin: Double?
    @WEFlexibleDouble var saturationmax: Double?
    @WEFlexibleDouble var valuemin: Double?
    @WEFlexibleDouble var valuemax: Double?
    var colors: [String]?
    @WEFlexibleDouble var huenoise: Double?
    @WEFlexibleDouble var saturationnoise: Double?
    @WEFlexibleDouble var valuenoise: Double?
    // turbulentvelocityrandom, positionoffsetrandom
    @WEFlexibleDouble var phasemin: Double?
    @WEFlexibleDouble var phasemax: Double?
    @WEFlexibleDouble var timescale: Double?
    @WEFlexibleDouble var scale: Double?
    @WEFlexibleDouble var offset: Double?
    var forward: WEFlexValue?
    var right: WEFlexValue?
    var directions: WEFlexValue?
    var sign: WEFlexValue?
    @WEFlexibleDouble var distance: Double?
    @WEFlexibleInt var octaves: Int?
    // mapsequence…
    @WEFlexibleInt var controlpoint: Int?
    @WEFlexibleInt var controlpointstart: Int?
    @WEFlexibleInt var controlpointend: Int?
    var arcdirection: WEFlexValue?
    @WEFlexibleDouble var sizereductionamount: Double?
    // remapinitialvalue
    var inputcomponent: String?
    var outputcomponent: String?
    var transformfunction: String?
    @WEFlexibleDouble var transforminputscale: Double?
    @WEFlexibleInt var transformoctaves: Int?
    var inputrangemin: WEFlexValue?
    var inputrangemax: WEFlexValue?
    var outputrangemin: WEFlexValue?
    var outputrangemax: WEFlexValue?
    @WEFlexibleInt var inputcontrolpoint1: Int?
    @WEFlexibleInt var outputcontrolpoint0: Int?
    @WEFlexibleInt var outputcontrolpoint1: Int?
    @WEFlexibleInt var flags: Int?
    @WEFlexibleDouble var count: Double?
    @WEFlexibleDouble var arcamount: Double?
    var limitbehavior: String?
    var axis: String?
    var bounds: String?
    var speedmin: WEFlexValue?
    var speedmax: WEFlexValue?
    var input: String?
    var output: String?
    var operation: String?
    @WEFlexibleInt var inputcontrolpoint0: Int?
    /// Audio response: 0 off, 1 left, 2 right, 3 both channels (`ParticleAudioResponse`).
    @WEFlexibleInt var audioprocessingmode: Int?
    @WEFlexibleDouble var audioprocessingexponent: Double?
    var audioprocessingbounds: WEFlexValue?
    @WEFlexibleInt var audioprocessingfrequencystart: Int?
    @WEFlexibleInt var audioprocessingfrequencyend: Int?
}

struct WEParticleOperator: Codable {
    @WEFlexibleInt var id: Int?
    var name: String?
    /// The blend window over the particle's life (`ParticleBlend`).
    @WEFlexibleDouble var blendinstart: Double?
    @WEFlexibleDouble var blendinend: Double?
    @WEFlexibleDouble var blendoutstart: Double?
    @WEFlexibleDouble var blendoutend: Double?
    @WEFlexibleDouble var deletethreshold: Double?
    var offset: WEFlexValue?
    @WEFlexibleDouble var reductionouter: Double?
    @WEFlexibleDouble var centerforce: Double?
    @WEFlexibleDouble var ringpullforce: Double?
    @WEFlexibleDouble var separationthreshold: Double?
    @WEFlexibleInt var controlpointstart: Int?
    @WEFlexibleInt var controlpointend: Int?
    var inputcomponent: String?
    var outputcomponent: String?
    @WEFlexibleInt var transformoctaves: Int?
    var inputrangemin: WEFlexValue?
    var inputrangemax: WEFlexValue?
    @WEFlexibleInt var inputcontrolpoint0: Int?
    @WEFlexibleInt var inputcontrolpoint1: Int?
    @WEFlexibleInt var outputcontrolpoint0: Int?
    @WEFlexibleInt var outputcontrolpoint1: Int?
    var gravity: String?
    @WEFlexibleDouble var drag: Double?
    @WEFlexibleDouble var fadeintime: Double?
    @WEFlexibleDouble var fadeouttime: Double?
    var scale: WEFlexValue?
    @WEFlexibleDouble var speedmin: Double?
    @WEFlexibleDouble var speedmax: Double?
    @WEFlexibleDouble var timescale: Double?
    var mask: WEFlexValue?
    @WEFlexibleDouble var phasemin: Double?
    @WEFlexibleDouble var phasemax: Double?
    @WEFlexibleInt var controlpoint: Int?
    var origin: WEFlexValue?
    @WEFlexibleDouble var threshold: Double?
    @WEFlexibleDouble var starttime: Double?
    @WEFlexibleDouble var endtime: Double?
    var startvalue: WEFlexValue?
    var endvalue: WEFlexValue?
    var force: String?
    var axis: String?
    @WEFlexibleDouble var distanceinner: Double?
    @WEFlexibleDouble var distanceouter: Double?
    @WEFlexibleDouble var speedinner: Double?
    @WEFlexibleDouble var speedouter: Double?
    @WEFlexibleDouble var maxspeed: Double?
    @WEFlexibleDouble var ringradius: Double?
    @WEFlexibleDouble var ringwidth: Double?
    @WEFlexibleDouble var ringpulldistance: Double?
    @WEFlexibleDouble var alignmentfactor: Double?
    @WEFlexibleDouble var cohesionfactor: Double?
    @WEFlexibleDouble var separationfactor: Double?
    @WEFlexibleDouble var neighborthreshold: Double?
    @WEFlexibleDouble var frequencymin: Double?
    @WEFlexibleDouble var frequencymax: Double?
    @WEFlexibleDouble var scalemin: Double?
    @WEFlexibleDouble var scalemax: Double?
    @WEFlexibleDouble var reductioninner: Double?
    @WEFlexibleDouble var variablestrength: Double?
    var input: String?
    var output: String?
    var operation: String?
    var transformfunction: String?
    @WEFlexibleDouble var transforminputscale: Double?
    var outputrangemin: WEFlexValue?
    var outputrangemax: WEFlexValue?
    /// `movement`: bit 0 gives gravity in the scene rather than the system's space. Collision
    /// operators: bit 0 locks the shape to `controlpoint`, bit 1 stops rotation on contact.
    @WEFlexibleInt var flags: Int?
    /// Audio response: 0 off, 1 left, 2 right, 3 both channels (`ParticleAudioResponse`).
    @WEFlexibleInt var audioprocessingmode: Int?
    @WEFlexibleDouble var audioprocessingexponent: Double?
    var audioprocessingbounds: WEFlexValue?
    @WEFlexibleInt var audioprocessingfrequencystart: Int?
    @WEFlexibleInt var audioprocessingfrequencyend: Int?
    // Collision operators (`ParticleCollision`).
    var collisionbehavior: String?
    @WEFlexibleDouble var bouncefactor: Double?
    var plane: WEFlexValue?
    @WEFlexibleDouble var distance: Double?
    @WEFlexibleDouble var radius: Double?
    var size: WEFlexValue?
    var forward: WEFlexValue?
}

struct WEParticleRenderer: Codable {
    @WEFlexibleInt var id: Int?
    var name: String?       // "sprite", "spritetrail"
    @WEFlexibleDouble var length: Double?
    @WEFlexibleDouble var maxlength: Double?
    @WEFlexibleDouble var minlength: Double?
    @WEFlexibleInt var segments: Int?
    @WEFlexibleInt var subdivision: Int?
    var fadealpha: Bool?
    var fadesize: Bool?
    /// Every renderer (`ParticleOrientation`): "screen", "upright" or "fixed", the axis, and flags
    /// (bit 0: the axis is in the scene rather than the object).
    var orientation: String?
    var axis: WEFlexValue?
    @WEFlexibleInt var flags: Int?
    /// `rope` and `ropetrail` (`ParticleRopeUV`): texture repeats along the rope, smoothing and
    /// scrolling.
    @WEFlexibleDouble var uvscale: Double?
    var uvsmoothing: Bool?
    var uvscrolling: Bool?
}

// MARK: - String Parsing Helpers
