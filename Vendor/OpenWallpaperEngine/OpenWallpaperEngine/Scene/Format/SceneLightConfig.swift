import Foundation

/// `general.lightconfig`: the scene's light budget (docs/lighting-plan.md §2.2). Without it, WE
/// packs no light into the `LightingV1` arrays and every `LIGHTS_*` combo is 0.
///
/// `wallpaper64.exe` parses it at 0x140187695 into one word (ctx+0x121c): 4 bits for each base
/// count and 2 bits for each shadow or cookie subset, so a count is its authored integer masked to
/// that width (20 → 4). A key that isn't a number is skipped. The base counts include their
/// subsets.
struct WELightConfig: Decodable, Equatable {
    var point = 0
    var spot = 0
    var tube = 0
    var directional = 0
    var spotShadow = 0
    var spotCookie = 0
    var spotShadowCookie = 0
    var directionalShadow = 0
    var pointShadow = 0

    static let baseMask = 0xF
    static let subsetMask = 0x3

    init(point: Int = 0, spot: Int = 0, tube: Int = 0, directional: Int = 0, spotShadow: Int = 0,
         spotCookie: Int = 0, spotShadowCookie: Int = 0, directionalShadow: Int = 0, pointShadow: Int = 0) {
        self.point = point & Self.baseMask
        self.spot = spot & Self.baseMask
        self.tube = tube & Self.baseMask
        self.directional = directional & Self.baseMask
        self.spotShadow = spotShadow & Self.subsetMask
        self.spotCookie = spotCookie & Self.subsetMask
        self.spotShadowCookie = spotShadowCookie & Self.subsetMask
        self.directionalShadow = directionalShadow & Self.subsetMask
        self.pointShadow = pointShadow & Self.subsetMask
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        func count(_ key: String) -> Int {
            let codingKey = AnyCodingKey(stringValue: key)
            guard let value = container.decodeLogged(SceneJSON.self, forKey: codingKey, userInfo: decoder.userInfo) else {
                return 0
            }
            guard case .number(let number) = value, number.isFinite, abs(number) < 1e9 else {
                OWELog.error(.scene, "lightconfig.\(key) is \(value), not a number; WE skips it")
                return 0
            }
            return Int(number)
        }
        self.init(point: count("point"), spot: count("spot"), tube: count("tube"), directional: count("directional"),
                  spotShadow: count("spotshadow"), spotCookie: count("spotcookie"),
                  spotShadowCookie: count("spotshadowcookie"), directionalShadow: count("directionalshadow"),
                  pointShadow: count("pointshadow"))
    }

    /// The budget WE keeps when the user's shadows setting is disabled (the parser's branch at
    /// 0x140187c39): `spotshadowcookie` is OR-ed (bitwise, not added) into `spotcookie`, and the
    /// other shadow counts are 0.
    var withShadowsDisabled: WELightConfig {
        WELightConfig(point: point, spot: spot, tube: tube, directional: directional,
                      spotCookie: spotCookie | spotShadowCookie)
    }
}
