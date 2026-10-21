import Foundation
import simd

/// Where a `spatialization` sound plays from, as WE places it (docs/scenescript-plan.md, sound
/// layers). wallpaper64.exe puts every file of the sound at one position in the camera's frame each
/// update (0x1401f5029…0x1401f53ff) and at `play()` (0x1401f5460 with its setter flag, called from
/// 0x1401f6905), and on `play()` also sets `attenuation` and `mindistance` (vt+0xe0, vt+0xe8). The
/// files are SFML sources on OpenAL Soft 1.21.1 in mediaextensions64.dll (`sf::SoundSource`:
/// `AL_POSITION`, `AL_ROLLOFF_FACTOR`, `AL_REFERENCE_DISTANCE`); the listener stays at SFML's
/// default (the origin, looking down −z with y up), no distance model is set (inverse distance,
/// clamped) and no source is listener-relative.
///
/// - Position: `d` = the object's world translation − the camera eye (ctx+0x68), in the camera's
///   frame as (right·d, −up·d, forward·d) (right ctx+0x16c, up ctx+0x178, forward ctx+0x160).
/// - An orthographic scene (ctx+0x118 bit 10) keeps only the direction and sets the distance to
///   max(q − z, 0) / q, with q = (width + height) / 4 of its projection (ctx+0x84, +0x88) and z the
///   object's world z: 1 on the scene plane, so there only the direction pans.
/// - Before the render context has a camera (ctx+0x144 = 0) the sound sits at (0, 0, 100000).
/// - OpenAL Soft spatializes mono sources only (`AL_SOURCE_SPATIALIZE_SOFT` auto): a stereo file
///   plays as it is, with no attenuation or panning.
/// - Gain: `mindistance / (mindistance + attenuation · (max(distance, mindistance) − mindistance))`
///   (`CalcAttnSourceParams`); `mindistance` 0 attenuates nothing.
/// - Pan: OpenAL Soft's stereo output for speakers (pair-wise panning, the "panpot" first-order
///   decoder): azimuth `az` = atan2(x, −z) pushed toward the sides in front
///   (`ScaleAzimuthFront`, ×1.5 up to 90°), elevation `ev` = asin(y). Left and right are
///   0.5 ∓ 0.5·sin az·cos ev + 0.0956623·cos az·cos ev. A source at the listener plays centred.
///
/// The gains are per channel against a stereo file's level: OpenAL plays a plain mono source
/// centred, `monoLevel` (0.595662) a channel, which WE's capture confirms (a stereo tone is
/// 1.6789× the same tone in mono). [I: HRTF, which OpenAL Soft picks for headphones, is not
/// modelled.]
///
/// WE's capture on speakers (2.8.0.42) matches the centre, the distance attenuation (to 4
/// decimals) and the stereo passthrough; toward the scene's edges its pan is up to 0.018 stronger
/// than this model. The panning code in mediaextensions64.dll is 1.21.1's as modelled here (the
/// pair-wise branch at 0x180192ecb, `CalcAngleCoeffs` 0x180190340, the decoder at 0x1802cd148),
/// so the difference lies outside it; see docs/scenescript-plan.md.
enum SceneSoundSpatialization {
    /// The camera a frame draws with, as the sound update reads it from the render context.
    struct Listener: Equatable {
        var eye: SIMD3<Float>
        var right: SIMD3<Float>
        var up: SIMD3<Float>
        var forward: SIMD3<Float>
        /// An orthographic scene's projection width and height; nil for a perspective one.
        var orthographicSize: SIMD2<Float>?

        /// A frame's camera: its view matrix's first two rows are WE's right and up.
        init(camera: SceneFrameCamera, orthographicSize: SIMD2<Float>?) {
            let view = camera.view.transpose
            eye = camera.eye
            right = SIMD3(view.columns.0.x, view.columns.0.y, view.columns.0.z)
            up = SIMD3(view.columns.1.x, view.columns.1.y, view.columns.1.z)
            forward = camera.forward
            self.orthographicSize = orthographicSize
        }

        init(eye: SIMD3<Float>, right: SIMD3<Float>, up: SIMD3<Float>, forward: SIMD3<Float>,
             orthographicSize: SIMD2<Float>?) {
            self.eye = eye
            self.right = right
            self.up = up
            self.forward = forward
            self.orthographicSize = orthographicSize
        }
    }

    /// Where a sound sits before there is a camera (0x1401f53d6).
    static let unplaced = SIMD3<Float>(0, 0, 100_000)

    /// A plain mono source's level in each channel against a stereo source's: panned to the front
    /// centre.
    static let monoLevel: Float = 0.5 + firstOrderX

    /// The stereo decoder's X (front) weight, 0.0552306 × √3 (`StereoConfig` in panning.cpp).
    private static let firstOrderX: Float = 0.0552305643 * 1.732050808

    /// The OpenAL source position of a sound at `world` (0x1401f5212…0x1401f53e7).
    static func position(world: SIMD3<Float>, listener: Listener?) -> SIMD3<Float> {
        guard let listener else { return unplaced }
        let d = world - listener.eye
        var position = SIMD3<Float>(simd_dot(listener.right, d), -simd_dot(listener.up, d), simd_dot(listener.forward, d))
        if let size = listener.orthographicSize {
            let length = simd_length(position)
            let reach = (size.x + size.y) * 0.25
            let scale = max(reach - world.z, 0) / reach
            position = length > 0 ? position / length * scale : .zero
        }
        return position
    }

    /// The left and right gains of a mono source at `position`: OpenAL Soft 1.21.1's distance
    /// attenuation and stereo panning.
    static func gains(position: SIMD3<Float>, minDistance: Float, attenuation: Float) -> SIMD2<Float> {
        // `alSourcef` refuses a negative (or NaN) value, which leaves SFML's default of 1.
        let reference: Float = minDistance >= 0 ? minDistance : 1
        let rolloff: Float = attenuation >= 0 ? attenuation : 1
        let length = simd_length(position)
        // `ToSource.normalize(RefDistance / 1024)`: closer than that is at the listener.
        let limit = max(reference / 1024, Float.ulpOfOne)
        let distance: Float = length > limit ? length : 0
        var gain: Float = 1
        if reference > 0 {
            let clamped = max(distance, reference)
            let attenuated = reference + (clamped - reference) * rolloff
            if attenuated > 0 { gain = min(reference / attenuated, 1) }
        }
        let panned: SIMD2<Float>
        if distance > Float.ulpOfOne {
            let direction = position / length
            let elevation = asin(min(max(direction.y, -1), 1))
            let azimuth = scaledAzimuthFront(atan2(direction.x, -direction.z))
            let side = sin(azimuth) * cos(elevation)
            let front = cos(azimuth) * cos(elevation) * firstOrderX
            panned = SIMD2(0.5 - 0.5 * side + front, 0.5 + 0.5 * side + front)
        } else {
            panned = SIMD2(repeating: monoLevel)
        }
        return panned * gain
    }

    /// `ScaleAzimuthFront(azimuth, 1.5)`: a source in front is pushed toward the side speakers.
    private static func scaledAzimuthFront(_ azimuth: Float) -> Float {
        let magnitude = abs(azimuth)
        guard magnitude < .pi / 2 else { return azimuth }
        return copysign(min(magnitude * 1.5, .pi / 2), azimuth)
    }
}
