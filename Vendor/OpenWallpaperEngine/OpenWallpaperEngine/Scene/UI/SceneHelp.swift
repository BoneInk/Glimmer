import SwiftUI

/// Tooltip copy for effects, shaders and their parameters.
///
/// Wallpaper Engine ships no descriptions for authored parameters — a control is often just a
/// shader constant name — so the guidance here is written to say what a value actually does and
/// which direction to move it.
enum SceneHelp {
    // MARK: - Effects

    private static let effectDescriptions: [String: String] = [
        "audiobars": String(localized: "Draws bars that rise and fall with the audio you are hearing. Needs Screen & System Audio Recording permission.", comment: "Scene Edit / Export tooltip for the audiobars effect"),
        "blend": String(localized: "Mixes a second image into the layer using a Photoshop-style blend mode.", comment: "Scene Edit / Export tooltip for the blend effect"),
        "blendgradient": String(localized: "Fades the layer into a gradient, usually to darken edges or tint one side.", comment: "Scene Edit / Export tooltip for the blendgradient effect"),
        "blur": String(localized: "Softens the layer. This is the cheap blur; use Blur Precise when you need a cleaner result.", comment: "Scene Edit / Export tooltip for the blur effect"),
        "blurprecise": String(localized: "A higher quality, more expensive blur. Prefer it for large radii where the fast blur shows banding.", comment: "Scene Edit / Export tooltip for the blurprecise effect"),
        "blurradial": String(localized: "Blurs outward from a centre point, giving a zoom or speed streak look.", comment: "Scene Edit / Export tooltip for the blurradial effect"),
        "chromaticaberration": String(localized: "Splits red and blue channels apart, imitating a cheap camera lens. Subtle values read best.", comment: "Scene Edit / Export tooltip for the chromaticaberration effect"),
        "cloudmotion": String(localized: "Drifts a cloud texture across the layer.", comment: "Scene Edit / Export tooltip for the cloudmotion effect"),
        "clouds": String(localized: "Overlays procedural clouds.", comment: "Scene Edit / Export tooltip for the clouds effect"),
        "colorkey": String(localized: "Makes one colour transparent, like a green screen. Raise Tolerance until the colour disappears, then raise Fuzziness to soften the edge.", comment: "Scene Edit / Export tooltip for the colorkey effect"),
        "cursorripple": String(localized: "Sends ripples out from the pointer as it moves.", comment: "Scene Edit / Export tooltip for the cursorripple effect"),
        "depthparallax": String(localized: "Shifts parts of the image by a depth map so it looks three-dimensional as the pointer moves.", comment: "Scene Edit / Export tooltip for the depthparallax effect"),
        "edgedetection": String(localized: "Keeps only the outlines in the image.", comment: "Scene Edit / Export tooltip for the edgedetection effect"),
        "empty": String(localized: "A placeholder that does nothing. Authors use it to reserve a slot in the effect stack.", comment: "Scene Edit / Export tooltip for the empty effect"),
        "filmgrain": String(localized: "Adds moving film grain. Keep the amount low or it swamps darker scenes.", comment: "Scene Edit / Export tooltip for the filmgrain effect"),
        "fire": String(localized: "Adds a rising flame distortion.", comment: "Scene Edit / Export tooltip for the fire effect"),
        "fisheye": String(localized: "Bulges the image outward from a centre point like a fisheye lens.", comment: "Scene Edit / Export tooltip for the fisheye effect"),
        "foliagesway": String(localized: "Sways the layer as if leaves were moving in wind.", comment: "Scene Edit / Export tooltip for the foliagesway effect"),
        "glitter": String(localized: "Scatters sparkles across the layer.", comment: "Scene Edit / Export tooltip for the glitter effect"),
        "godrays": String(localized: "Casts light shafts from a bright source through the scene.", comment: "Scene Edit / Export tooltip for the godrays effect"),
        "hueshift": String(localized: "Rotates every colour around the colour wheel.", comment: "Scene Edit / Export tooltip for the hueshift effect"),
        "hyperdrive": String(localized: "Stretches the image into streaks for a warp-speed look.", comment: "Scene Edit / Export tooltip for the hyperdrive effect"),
        "iris": String(localized: "Opens or closes a circular mask over the layer.", comment: "Scene Edit / Export tooltip for the iris effect"),
        "lightshafts": String(localized: "Adds directional beams of light across the layer.", comment: "Scene Edit / Export tooltip for the lightshafts effect"),
        "localcontrast": String(localized: "Sharpens local detail without changing overall brightness. High values look crunchy.", comment: "Scene Edit / Export tooltip for the localcontrast effect"),
        "motionblur": String(localized: "Smears the image along its direction of motion.", comment: "Scene Edit / Export tooltip for the motionblur effect"),
        "nitro": String(localized: "Pulses a speed-boost distortion.", comment: "Scene Edit / Export tooltip for the nitro effect"),
        "opacity": String(localized: "Fades the layer in or out.", comment: "Scene Edit / Export tooltip for the opacity effect"),
        "parallax": String(localized: "Moves the layer against the pointer so it appears to sit at a different depth.", comment: "Scene Edit / Export tooltip for the parallax effect"),
        "perspective": String(localized: "Tilts the layer in 3D space.", comment: "Scene Edit / Export tooltip for the perspective effect"),
        "pulse": String(localized: "Scales the layer in time with the audio.", comment: "Scene Edit / Export tooltip for the pulse effect"),
        "reflection": String(localized: "Mirrors the layer below itself, as if on water or glass.", comment: "Scene Edit / Export tooltip for the reflection effect"),
        "refraction": String(localized: "Bends the image as if seen through rippled glass.", comment: "Scene Edit / Export tooltip for the refraction effect"),
        "scroll": String(localized: "Slides the texture continuously, useful for tiling backgrounds.", comment: "Scene Edit / Export tooltip for the scroll effect"),
        "shake": String(localized: "Jitters the layer. Masked so only part of the image moves.", comment: "Scene Edit / Export tooltip for the shake effect"),
        "shimmer": String(localized: "Runs a soft highlight across the layer.", comment: "Scene Edit / Export tooltip for the shimmer effect"),
        "shine": String(localized: "Sweeps a bright band across the layer. The mask controls which parts can catch the light.", comment: "Scene Edit / Export tooltip for the shine effect"),
        "skew": String(localized: "Leans the layer to one side.", comment: "Scene Edit / Export tooltip for the skew effect"),
        "spin": String(localized: "Rotates a circular region of the layer.", comment: "Scene Edit / Export tooltip for the spin effect"),
        "swing": String(localized: "Rocks the layer back and forth around its base.", comment: "Scene Edit / Export tooltip for the swing effect"),
        "tint": String(localized: "Multiplies the layer by a colour.", comment: "Scene Edit / Export tooltip for the tint effect"),
        "transform": String(localized: "Offsets, scales or rotates the layer.", comment: "Scene Edit / Export tooltip for the transform effect"),
        "twirl": String(localized: "Swirls the image around a centre point.", comment: "Scene Edit / Export tooltip for the twirl effect"),
        "vhs": String(localized: "Adds tape distortion, colour bleed and scanlines.", comment: "Scene Edit / Export tooltip for the vhs effect"),
        "volumetricfog": String(localized: "Adds depth-aware fog that thickens toward the bottom of the scene.", comment: "Scene Edit / Export tooltip for the volumetricfog effect"),
        "watercaustics": String(localized: "Projects rippling underwater light patterns.", comment: "Scene Edit / Export tooltip for the watercaustics effect"),
        "waterflow": String(localized: "Pushes the image along as if it were flowing water.", comment: "Scene Edit / Export tooltip for the waterflow effect"),
        "waterripple": String(localized: "Adds expanding ripples across the surface.", comment: "Scene Edit / Export tooltip for the waterripple effect"),
        "waterwaves": String(localized: "Distorts the layer with rolling waves.", comment: "Scene Edit / Export tooltip for the waterwaves effect"),
        "xray": String(localized: "Reveals a second image through a moving window.", comment: "Scene Edit / Export tooltip for the xray effect")
    ]

    static func effect(_ name: String) -> String {
        effectDescriptions[name.lowercased()]
            ?? String(localized: "Applies the \(name.lowercased()) effect to this layer.",
                      comment: "Scene Edit / Export tooltip for an effect without a description; %@ is its file name")
    }

    // MARK: - Parameters

    /// Per-effect wording, because the same key means different things depending on the effect:
    /// `strength` is a pixel offset for Shake, a colour-split distance for Chromatic Aberration and
    /// an audio sensitivity for Audio Bars.
    private static let effectParameters: [String: [String: String]] = [
        "tint": [
            "alpha": String(localized: "How strongly the tint colour is mixed in. 0 leaves the layer untouched, 1 replaces it with the colour.", comment: "Scene Edit / Export tooltip for the tint effect's alpha parameter")
        ],
        "opacity": [
            "alpha": String(localized: "Transparency of the layer. 0 hides it completely, 1 is fully solid.", comment: "Scene Edit / Export tooltip for the opacity effect's alpha parameter")
        ],
        "fisheye": [
            "size": String(localized: "How much of the layer the lens covers. Small values bulge only the centre.", comment: "Scene Edit / Export tooltip for the fisheye effect's size parameter"),
            "scale": String(localized: "How hard the lens bends the image. Negative values pinch inward instead of bulging out.", comment: "Scene Edit / Export tooltip for the fisheye effect's scale parameter")
        ],
        "scroll": [
            "speedx": String(localized: "Horizontal scroll speed. Negative scrolls left, 0 stops. Only looks seamless on tiling textures.", comment: "Scene Edit / Export tooltip for the scroll effect's speedx parameter"),
            "speedy": String(localized: "Vertical scroll speed. Negative scrolls up, 0 stops.", comment: "Scene Edit / Export tooltip for the scroll effect's speedy parameter")
        ],
        "chromaticaberration": [
            "strength": String(localized: "How far the red and blue channels separate. Keep it small — past a few pixels it stops reading as a lens and starts looking broken.", comment: "Scene Edit / Export tooltip for the chromaticaberration effect's strength parameter"),
            "centerfalloff": String(localized: "How quickly the split fades toward the centre. High values keep the centre sharp and push the fringing to the edges, like a real lens.", comment: "Scene Edit / Export tooltip for the chromaticaberration effect's centerfalloff parameter")
        ],
        "colorkey": [
            "alpha": String(localized: "Opacity left behind where the colour is keyed out. 0 makes matched pixels fully transparent.", comment: "Scene Edit / Export tooltip for the colorkey effect's alpha parameter"),
            "fuzziness": String(localized: "Softness of the cut-out edge. Raise it if the keyed edge looks jagged; too high and the subject goes semi-transparent.", comment: "Scene Edit / Export tooltip for the colorkey effect's fuzziness parameter"),
            "tolerance": String(localized: "How close a pixel must be to the key colour to be removed. Raise it until the background is gone, then stop — going further eats the subject.", comment: "Scene Edit / Export tooltip for the colorkey effect's tolerance parameter")
        ],
        "spin": [
            "size": String(localized: "Radius of the spinning disc, as a fraction of the layer.", comment: "Scene Edit / Export tooltip for the spin effect's size parameter"),
            "feather": String(localized: "Softness of the disc edge. Very small values leave a visible hard circle.", comment: "Scene Edit / Export tooltip for the spin effect's feather parameter")
        ],
        "depthparallax": [
            "depthx": String(localized: "How far the image shifts horizontally with the pointer. Needs a depth map; without one nothing moves.", comment: "Scene Edit / Export tooltip for the depthparallax effect's depthx parameter"),
            "depthy": String(localized: "How far the image shifts vertically with the pointer.", comment: "Scene Edit / Export tooltip for the depthparallax effect's depthy parameter"),
            "perspective": String(localized: "Adds scaling with depth so near parts grow as they shift, rather than just sliding.", comment: "Scene Edit / Export tooltip for the depthparallax effect's perspective parameter")
        ],
        "shake": [
            "strength": String(localized: "How far the layer moves each shake, in pixels.", comment: "Scene Edit / Export tooltip for the shake effect's strength parameter"),
            "speed": String(localized: "How rapidly it shakes.", comment: "Scene Edit / Export tooltip for the shake effect's speed parameter"),
            "friction": String(localized: "How quickly each shake settles. High values give a short sharp jolt, low values keep it wobbling.", comment: "Scene Edit / Export tooltip for the shake effect's friction parameter")
        ],
        "waterwaves": [
            "strength": String(localized: "Height of the waves — how far pixels are displaced.", comment: "Scene Edit / Export tooltip for the waterwaves effect's strength parameter"),
            "speed": String(localized: "How fast the waves travel.", comment: "Scene Edit / Export tooltip for the waterwaves effect's speed parameter"),
            "scale": String(localized: "Wavelength. Low values give many small ripples, high values give a few broad swells.", comment: "Scene Edit / Export tooltip for the waterwaves effect's scale parameter"),
            "exponent": String(localized: "Sharpness of the wave crests. 1 is a smooth sine; higher values give peaked, choppier water.", comment: "Scene Edit / Export tooltip for the waterwaves effect's exponent parameter"),
            "direction": String(localized: "Direction the waves travel, in degrees.", comment: "Scene Edit / Export tooltip for the waterwaves effect's direction parameter")
        ],
        "nitro": [
            "multiply": String(localized: "Strength of the speed-boost distortion.", comment: "Scene Edit / Export tooltip for the nitro effect's multiply parameter"),
            "smoothness": String(localized: "How gradually the distortion ramps in and out. Low values snap, high values glide.", comment: "Scene Edit / Export tooltip for the nitro effect's smoothness parameter")
        ],
        "vhs": [
            "strength": String(localized: "Overall amount of tape degradation.", comment: "Scene Edit / Export tooltip for the vhs effect's strength parameter"),
            "chromatic": String(localized: "How far colour bleeds sideways, like worn tape.", comment: "Scene Edit / Export tooltip for the vhs effect's chromatic parameter"),
            "artifacts": String(localized: "Density of dropouts and noise specks.", comment: "Scene Edit / Export tooltip for the vhs effect's artifacts parameter"),
            "distortionstrength": String(localized: "How far the tracking glitch tears the image sideways.", comment: "Scene Edit / Export tooltip for the vhs effect's distortionstrength parameter"),
            "distortionspeed": String(localized: "How often the tracking glitch rolls through.", comment: "Scene Edit / Export tooltip for the vhs effect's distortionspeed parameter"),
            "distortionwidth": String(localized: "Height of the torn band. Small values give a thin tracking line, large values disturb most of the frame.", comment: "Scene Edit / Export tooltip for the vhs effect's distortionwidth parameter")
        ],
        "audiobars": [
            "opacity": String(localized: "Transparency of the bars.", comment: "Scene Edit / Export tooltip for the audiobars effect's opacity parameter"),
            "strength": String(localized: "How far the bars react to volume. Raise it for quiet music, lower it if the bars keep hitting the ceiling.", comment: "Scene Edit / Export tooltip for the audiobars effect's strength parameter"),
            "minimum": String(localized: "Height the bars keep in silence, so they do not vanish between beats.", comment: "Scene Edit / Export tooltip for the audiobars effect's minimum parameter"),
            "bars": String(localized: "How many bars are drawn across the layer.", comment: "Scene Edit / Export tooltip for the audiobars effect's bars parameter"),
            "gap": String(localized: "Spacing between bars, as a fraction of their width.", comment: "Scene Edit / Export tooltip for the audiobars effect's gap parameter"),
            "smoothing": String(localized: "How much bar movement is averaged over time. High values glide, 0 reacts instantly and jitters.", comment: "Scene Edit / Export tooltip for the audiobars effect's smoothing parameter"),
            "glow": String(localized: "Brightness of the halo around each bar.", comment: "Scene Edit / Export tooltip for the audiobars effect's glow parameter"),
            "red": String(localized: "Red component of the bar colour.", comment: "Scene Edit / Export tooltip for the audiobars effect's red parameter"),
            "green": String(localized: "Green component of the bar colour.", comment: "Scene Edit / Export tooltip for the audiobars effect's green parameter"),
            "blue": String(localized: "Blue component of the bar colour.", comment: "Scene Edit / Export tooltip for the audiobars effect's blue parameter")
        ],
        "hueshift": [
            "audioamount": String(localized: "How far the hue rotates at full volume.", comment: "Scene Edit / Export tooltip for the hueshift effect's audioamount parameter"),
            "audioexponent": String(localized: "Shapes the response curve. Above 1 ignores quiet passages and reacts mainly to peaks.", comment: "Scene Edit / Export tooltip for the hueshift effect's audioexponent parameter"),
            "frequencymin": String(localized: "Lowest frequency band that drives the shift. Raise it to ignore bass.", comment: "Scene Edit / Export tooltip for the hueshift effect's frequencymin parameter"),
            "frequencymax": String(localized: "Highest frequency band that drives the shift. Lower it to ignore cymbals and hiss.", comment: "Scene Edit / Export tooltip for the hueshift effect's frequencymax parameter"),
            "intensity": String(localized: "Hue rotation applied even without audio.", comment: "Scene Edit / Export tooltip for the hueshift effect's intensity parameter")
        ],
        "hyperdrive": [
            "audioamount": String(localized: "How much the warp reacts to volume.", comment: "Scene Edit / Export tooltip for the hyperdrive effect's audioamount parameter"),
            "audioexponent": String(localized: "Shapes the response curve. Above 1 reacts mainly to peaks.", comment: "Scene Edit / Export tooltip for the hyperdrive effect's audioexponent parameter"),
            "frequencymin": String(localized: "Lowest frequency band that drives the warp. Raise it to ignore bass.", comment: "Scene Edit / Export tooltip for the hyperdrive effect's frequencymin parameter"),
            "frequencymax": String(localized: "Highest frequency band that drives the warp.", comment: "Scene Edit / Export tooltip for the hyperdrive effect's frequencymax parameter"),
            "strength": String(localized: "How far the image stretches into streaks.", comment: "Scene Edit / Export tooltip for the hyperdrive effect's strength parameter"),
            "speed": String(localized: "How fast the streaks travel outward.", comment: "Scene Edit / Export tooltip for the hyperdrive effect's speed parameter")
        ],
        "volumetricfog": [
            "density": String(localized: "How thick the fog is. Small changes read strongly — start low.", comment: "Scene Edit / Export tooltip for the volumetricfog effect's density parameter"),
            "drift": String(localized: "How fast the fog moves across the scene.", comment: "Scene Edit / Export tooltip for the volumetricfog effect's drift parameter"),
            "near": String(localized: "Depth where the fog starts. Nothing closer than this is fogged.", comment: "Scene Edit / Export tooltip for the volumetricfog effect's near parameter"),
            "far": String(localized: "Depth where the fog reaches full density. Keep it above Fog Near or the gradient inverts.", comment: "Scene Edit / Export tooltip for the volumetricfog effect's far parameter")
        ],
        "parallax": [
            "amount": String(localized: "How far the layer slides against the pointer. Give background layers more than foreground ones to sell the depth.", comment: "Scene Edit / Export tooltip for the parallax effect's amount parameter")
        ],
        "foliagesway": [
            "strength": String(localized: "How far the leaves bend.", comment: "Scene Edit / Export tooltip for the foliagesway effect's strength parameter"),
            "scale": String(localized: "Size of the sway pattern. Low values move the whole layer together, high values ripple through it.", comment: "Scene Edit / Export tooltip for the foliagesway effect's scale parameter"),
            "speeduv": String(localized: "How fast the sway travels through the foliage.", comment: "Scene Edit / Export tooltip for the foliagesway effect's speeduv parameter")
        ],
        "waterripple": [
            "ripplestrength": String(localized: "How far the surface is displaced by each ripple.", comment: "Scene Edit / Export tooltip for the waterripple effect's ripplestrength parameter"),
            "scale": String(localized: "Size of the ripples. Low values give broad swells, high values fine ridges.", comment: "Scene Edit / Export tooltip for the waterripple effect's scale parameter"),
            "animationspeed": String(localized: "How fast the ripples spread.", comment: "Scene Edit / Export tooltip for the waterripple effect's animationspeed parameter")
        ],
        "godrays": [
            "rayintensity": String(localized: "Brightness of the shafts of light.", comment: "Scene Edit / Export tooltip for the godrays effect's rayintensity parameter"),
            "raylength": String(localized: "How far the shafts reach from their source.", comment: "Scene Edit / Export tooltip for the godrays effect's raylength parameter"),
            "raythreshold": String(localized: "How bright a pixel must be to emit rays. Lower it if nothing glows; raise it if the whole image smears.", comment: "Scene Edit / Export tooltip for the godrays effect's raythreshold parameter")
        ],
        "lightshafts": [
            "colorwintensity": String(localized: "Brightness of the shafts.", comment: "Scene Edit / Export tooltip for the lightshafts effect's colorwintensity parameter"),
            "rayradius": String(localized: "How wide the shafts spread.", comment: "Scene Edit / Export tooltip for the lightshafts effect's rayradius parameter"),
            "rayspeed": String(localized: "How fast the shafts drift.", comment: "Scene Edit / Export tooltip for the lightshafts effect's rayspeed parameter")
        ]
    ]

    /// Fallback for authored shader constants, matched most-specific-first.
    private static let parameterDescriptions: [(match: String, text: String)] = [
        ("ray_threshold", String(localized: "How bright a pixel must be before it casts rays. Lower it to catch more of the image, raise it to keep rays on highlights only.", comment: "Scene Edit / Export tooltip for an effect parameter named like ray_threshold")),
        ("ray_intensity", String(localized: "Brightness of the light rays.", comment: "Scene Edit / Export tooltip for an effect parameter named like ray_intensity")),
        ("ray_length", String(localized: "How far the rays reach from their source.", comment: "Scene Edit / Export tooltip for an effect parameter named like ray_length")),
        ("noise_amount", String(localized: "How strongly noise distorts the result. Small values keep it organic; large values look grainy.", comment: "Scene Edit / Export tooltip for an effect parameter named like noise_amount")),
        ("noise_scale", String(localized: "Size of the noise pattern. Lower is coarser and blotchier, higher is finer.", comment: "Scene Edit / Export tooltip for an effect parameter named like noise_scale")),
        ("blur_scale", String(localized: "How far the blur reaches on each axis.", comment: "Scene Edit / Export tooltip for an effect parameter named like blur_scale")),
        ("centerfalloff", String(localized: "How quickly the effect fades away from the centre.", comment: "Scene Edit / Export tooltip for an effect parameter named like centerfalloff")),
        ("threshold", String(localized: "The cut-off where the effect starts to apply. Lower catches more of the image, higher restricts it to the strongest pixels.", comment: "Scene Edit / Export tooltip for an effect parameter named like threshold")),
        ("fuzziness", String(localized: "Softness of the edge where the effect stops. Raise it to avoid a hard cut.", comment: "Scene Edit / Export tooltip for an effect parameter named like fuzziness")),
        ("tolerance", String(localized: "How closely a pixel must match before it is affected. Raise it until the whole target area is covered, then stop.", comment: "Scene Edit / Export tooltip for an effect parameter named like tolerance")),
        ("smoothness", String(localized: "How gradually the effect blends at its boundary.", comment: "Scene Edit / Export tooltip for an effect parameter named like smoothness")),
        ("feather", String(localized: "Softens the boundary of the affected region.", comment: "Scene Edit / Export tooltip for an effect parameter named like feather")),
        ("density", String(localized: "How much of the area the effect fills.", comment: "Scene Edit / Export tooltip for an effect parameter named like density")),
        ("friction", String(localized: "How quickly the motion settles. High values stop it sharply, low values let it keep moving.", comment: "Scene Edit / Export tooltip for an effect parameter named like friction")),
        ("exponent", String(localized: "Shapes the response curve. Above 1 emphasises peaks and ignores small values.", comment: "Scene Edit / Export tooltip for an effect parameter named like exponent")),
        ("multiply", String(localized: "Strength of the blend. 0 leaves the layer untouched, 1 applies it fully.", comment: "Scene Edit / Export tooltip for an effect parameter named like multiply")),
        ("direction", String(localized: "Direction the effect travels, in degrees.", comment: "Scene Edit / Export tooltip for an effect parameter named like direction")),
        ("angle", String(localized: "Rotation applied by the effect, in degrees.", comment: "Scene Edit / Export tooltip for an effect parameter named like angle")),
        ("speedx", String(localized: "Horizontal speed. Negative values move the other way, 0 stops.", comment: "Scene Edit / Export tooltip for an effect parameter named like speedx")),
        ("speedy", String(localized: "Vertical speed. Negative values move the other way, 0 stops.", comment: "Scene Edit / Export tooltip for an effect parameter named like speedy")),
        ("repeatx", String(localized: "How many times the texture tiles horizontally.", comment: "Scene Edit / Export tooltip for an effect parameter named like repeatx")),
        ("repeaty", String(localized: "How many times the texture tiles vertically.", comment: "Scene Edit / Export tooltip for an effect parameter named like repeaty")),
        ("frequencymin", String(localized: "Lowest audio frequency band that drives this. Raise it to ignore bass.", comment: "Scene Edit / Export tooltip for an effect parameter named like frequencymin")),
        ("frequencymax", String(localized: "Highest audio frequency band that drives this. Lower it to ignore hiss and cymbals.", comment: "Scene Edit / Export tooltip for an effect parameter named like frequencymax")),
        ("audioamount", String(localized: "How strongly audio drives this parameter.", comment: "Scene Edit / Export tooltip for an effect parameter named like audioamount")),
        ("audioexponent", String(localized: "Shapes the audio response. Above 1 reacts mainly to peaks.", comment: "Scene Edit / Export tooltip for an effect parameter named like audioexponent")),
        ("speed", String(localized: "How quickly the effect animates. 0 freezes it.", comment: "Scene Edit / Export tooltip for an effect parameter named like speed")),
        ("frequency", String(localized: "How often the pattern repeats over time.", comment: "Scene Edit / Export tooltip for an effect parameter named like frequency")),
        ("phase", String(localized: "Offsets the start of the animation, useful for de-syncing two copies of an effect.", comment: "Scene Edit / Export tooltip for an effect parameter named like phase")),
        ("center", String(localized: "Point the effect radiates from, as a fraction of the layer (0.5, 0.5 is the middle).", comment: "Scene Edit / Export tooltip for an effect parameter named like center")),
        ("radius", String(localized: "Size of the affected region.", comment: "Scene Edit / Export tooltip for an effect parameter named like radius")),
        ("bloomthreshold", String(localized: "How bright a pixel must be before it glows.", comment: "Scene Edit / Export tooltip for an effect parameter named like bloomthreshold")),
        ("bloom", String(localized: "Strength of the glow around bright areas.", comment: "Scene Edit / Export tooltip for an effect parameter named like bloom")),
        ("brightness", String(localized: "Overall lightness. 1 leaves the layer unchanged.", comment: "Scene Edit / Export tooltip for an effect parameter named like brightness")),
        ("contrast", String(localized: "Separation between lights and darks. 1 leaves the layer unchanged.", comment: "Scene Edit / Export tooltip for an effect parameter named like contrast")),
        ("saturation", String(localized: "Colour richness. 0 is greyscale, 1 is unchanged.", comment: "Scene Edit / Export tooltip for an effect parameter named like saturation")),
        ("exposure", String(localized: "Simulated camera exposure. Positive brightens, negative darkens.", comment: "Scene Edit / Export tooltip for an effect parameter named like exposure")),
        ("gamma", String(localized: "Midtone brightness curve. 1 leaves the layer unchanged.", comment: "Scene Edit / Export tooltip for an effect parameter named like gamma")),
        ("hue", String(localized: "Rotates every colour around the colour wheel.", comment: "Scene Edit / Export tooltip for an effect parameter named like hue")),
        ("opacity", String(localized: "Transparency. 0 is invisible, 1 is solid.", comment: "Scene Edit / Export tooltip for an effect parameter named like opacity")),
        ("alpha", String(localized: "Transparency. 0 is invisible, 1 is solid.", comment: "Scene Edit / Export tooltip for an effect parameter named like alpha")),
        ("color", String(localized: "Colour used by this effect.", comment: "Scene Edit / Export tooltip for an effect parameter named like color")),
        ("scale", String(localized: "Size of the pattern relative to the layer.", comment: "Scene Edit / Export tooltip for an effect parameter named like scale")),
        ("size", String(localized: "Size of the affected area.", comment: "Scene Edit / Export tooltip for an effect parameter named like size")),
        ("strength", String(localized: "How strongly the effect is applied.", comment: "Scene Edit / Export tooltip for an effect parameter named like strength")),
        ("intensity", String(localized: "How strongly the effect is applied.", comment: "Scene Edit / Export tooltip for an effect parameter named like intensity")),
        ("amount", String(localized: "How strongly the effect is applied. 0 disables it.", comment: "Scene Edit / Export tooltip for an effect parameter named like amount"))
    ]

    static func parameter(effect: String? = nil, key: String, title: String = "",
                          displaysDegrees: Bool = false) -> String {
        let normalized = key.lowercased()
        if let effect, let specific = effectParameters[effect.lowercased()]?[normalized] {
            return specific
        }
        if let match = parameterDescriptions.first(where: { normalized.contains($0.match) }) {
            return match.text
        }
        if displaysDegrees { return String(localized: "Rotation applied by the effect, in degrees.") }
        let label = title.isEmpty ? key : title
        return label.isEmpty ? String(localized: "Adjusts this parameter.")
            : String(localized: "Adjusts \(label.lowercased()).",
                     comment: "Scene Edit / Export tooltip for an effect parameter; %@ is its name")
    }

    // MARK: - Wallpaper controls

    static let volume = String(localized: "Loudness of the wallpaper's own soundtrack. Set it to 0 to keep the wallpaper silent.", comment: "Details panel tooltip")
    static let videoSpeed = String(localized: "Playback speed of the video. 1 is normal; 0 pauses it.", comment: "Details panel tooltip")
    static let audioSpeed = String(localized: "Playback speed of the soundtrack. Link it to the video speed to keep them in step.", comment: "Details panel tooltip")
    static let linkRates = String(localized: "Keep the audio speed matched to the video speed.", comment: "Details panel tooltip")
    static let placement = String(localized: "How the wallpaper is fitted to the screen when its aspect ratio differs.", comment: "Details panel tooltip")
    static let sceneMusic = String(localized: "Play the soundtrack that ships with this wallpaper.", comment: "Details panel tooltip")
    static let sceneMusicVolume = String(localized: "Loudness of the wallpaper's own soundtrack.", comment: "Details panel tooltip")

    static let musicSyncSource = String(localized: """
    Music sync follows the wallpaper's own soundtrack while you can hear it. \
    Mute the wallpaper and it follows whatever else is playing on your Mac instead.
    """, comment: "Details panel tooltip for the music sync controls")

    static func musicSync(_ title: String) -> String {
        switch title.lowercased() {
        case "zoom": return String(localized: "Scales the picture with the beat. \(musicSyncSource)", comment: "%@ is the music sync explanation")
        case "pace": return String(localized: "Speeds the video up and down with the beat. Negative values slow it on loud passages. \(musicSyncSource)", comment: "%@ is the music sync explanation")
        case "tilt": return String(localized: "Rocks the picture with the beat, in degrees. \(musicSyncSource)", comment: "%@ is the music sync explanation")
        case "saturation": return String(localized: "Makes colours richer on loud passages. \(musicSyncSource)", comment: "%@ is the music sync explanation")
        default: return musicSyncSource
        }
    }
}
