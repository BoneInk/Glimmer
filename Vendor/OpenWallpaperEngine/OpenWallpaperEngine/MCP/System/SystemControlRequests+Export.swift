import Foundation
import OWEControlProtocol

/// iPhone & iPad Export: Scene Edit / Export's mode that renders a scene as a Live Photo for
/// a device's lock screen. The devices and their search are the mode's own (`DeviceModel`,
/// `DeviceModelSearch`); the crop and clip are clamped as the mode clamps them.
extension SystemControlRequests {
    func devices(_ params: ControlParameters) throws -> JSONValue {
        let query = try params.string("query") ?? ""
        let devices = DeviceModelSearch.filter(DeviceModel.all, query: query)
        let names = devices.prefix(8).map(\.name).joined(separator: ", ") + (devices.count > 8 ? ", …" : "")
        let message = devices.isEmpty ? "No device matches \"\(query)\"."
            : "\(devices.count) \(devices.count == 1 ? "device" : "devices") \(query.isEmpty ? "can be exported for" : devices.count == 1 ? "matches" : "match"): \(names)."
        return ["devices": .array(devices.map(Self.json)), "total": .number(Double(devices.count)), "message": .string(message)]
    }

    func exportSettings(_ params: ControlParameters, lookup: ControlLookup) throws -> JSONValue {
        let defaults = service.exportDefaults
        var result: [String: JSONValue] = [
            "device": Self.json(defaults.device),
            "qualities": .array(LivePhotoQuality.allCases.map { .string($0.rawValue) }),
            "default_quality": .string(LivePhotoQuality.best.rawValue),
            "save_to_photos": .bool(defaults.savesToPhotos),
            "photos_album": .string(defaults.photosAlbum),
            "photos_access": .string(defaults.photosAccess),
            "max_zoom": .number(LivePhotoCrop.maximumZoom),
            "clip_lengths": ["shortest": .number(LivePhotoClip.shortestChosen), "longest": .number(LivePhotoClip.duration)],
            "clip_timeline_seconds": .number(LivePhotoClip.timelineLength),
            "frame_rate": .number(Double(LivePhotoClip.frameRate)),
        ]
        var message = "The export remembers \(defaults.device.name); Also Save to Photos Album is "
            + (defaults.savesToPhotos ? "on (album \"\(defaults.photosAlbum)\", Photos access \(defaults.photosAccess))." : "off.")
        if let id = try params.string("wallpaper_id") {
            let wallpaper = try Self.exportable(lookup.wallpaper(id))
            let size = try service.sceneSize(of: wallpaper)
            result["wallpaper"] = ControlLookup.json(wallpaper)
            result["scene"] = ["width": .number(size.x), "height": .number(size.y)]
            message += " \"\(wallpaper.title)\" is \(Int(size.x))×\(Int(size.y)) scene units; the crop's centre is in those, from its top-left."
        }
        result["message"] = .string(message)
        return .object(result)
    }

    func exportLivePhoto(_ params: ControlParameters, lookup: ControlLookup) async throws -> JSONValue {
        let wallpaper = try Self.exportable(lookup.wallpaper(params.required("wallpaper_id")))
        let defaults = service.exportDefaults
        let device = try params.string("device").map(Self.device) ?? defaults.device
        let crop = try Self.object(params, "crop")
        let clip = try Self.object(params, "clip")
        let settings = try Self.object(params, "settings")

        var center: SIMD2<Double>?
        let centerX = try crop?.double("center_x"), centerY = try crop?.double("center_y")
        if centerX != nil || centerY != nil {
            let size = try service.sceneSize(of: wallpaper)
            center = SIMD2<Double>(centerX ?? size.x / 2, centerY ?? size.y / 2)
        }
        let quality: LivePhotoQuality
        if let name = try settings?.string("quality") {
            guard let chosen = LivePhotoQuality(rawValue: name) else {
                throw ControlError(.invalidParams, "settings.quality must be best, high or smaller.")
            }
            quality = chosen
        } else {
            quality = .best
        }
        let request = SystemLivePhotoRequest(
            wallpaper: wallpaper, device: device, zoom: try crop?.double("zoom") ?? 1, center: center,
            clipStart: try clip?.double("start"), clipLength: try clip?.double("length") ?? LivePhotoClip.duration,
            quality: quality, savesToPhotos: try settings?.bool("save_to_photos") ?? true,
            outputFolder: try params.string("output_folder").map(Self.outputFolder))
        let result = try await service.exportLivePhoto(request)
        return Self.json(result, wallpaper: wallpaper, device: device, quality: quality)
    }

    // MARK: Arguments

    static func exportable(_ wallpaper: ControlWallpaper) throws -> ControlWallpaper {
        guard wallpaper.type == "scene" else {
            throw ControlError(.unsupported, "\"\(wallpaper.title)\" is a \(wallpaper.type) wallpaper; the iPhone & iPad Export mode exports scenes only.")
        }
        return wallpaper
    }

    /// A device by its name (any case), or the one device a search for it finds.
    static func device(_ name: String) throws -> DeviceModel {
        if let device = DeviceModel.all.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { return device }
        let matches = DeviceModelSearch.filter(DeviceModel.all, query: name)
        if matches.count == 1 { return matches[0] }
        guard !matches.isEmpty else {
            throw ControlError(.notFound, "No device \"\(name)\". devices_list lists them.")
        }
        let names = matches.prefix(10).map { "\"\($0.name)\"" }.joined(separator: ", ")
        throw ControlError(.invalidParams, "\"\(name)\" matches \(matches.count) devices (\(names)\(matches.count > 10 ? ", …" : "")); give one's full name.")
    }

    /// An existing folder, by its absolute path.
    static func outputFolder(_ path: String) throws -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard expanded.hasPrefix("/") else {
            throw ControlError(.invalidParams, "output_folder must be an absolute path.")
        }
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ControlError(.notFound, "output_folder \(expanded) isn't an existing folder.")
        }
        return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
    }

    /// One of the request's objects (`crop`, `clip`, `settings`), read as parameters of its own.
    static func object(_ params: ControlParameters, _ key: String) throws -> ControlParameters? {
        guard params.has(key) else { return nil }
        guard let object = params.raw[key]?.objectValue else { throw ControlError(.invalidParams, "\(key) must be an object.") }
        return ControlParameters(object)
    }

    // MARK: Writing

    static func json(_ device: DeviceModel) -> JSONValue {
        [
            "id": .string(device.id), "name": .string(device.name), "family": .string(device.family.rawValue),
            "width": .number(Double(device.pixelSize.x)), "height": .number(Double(device.pixelSize.y)),
            "year": .number(Double(device.year)),
        ]
    }

    static func json(_ result: SystemLivePhotoResult, wallpaper: ControlWallpaper, device: DeviceModel,
                     quality: LivePhotoQuality) -> JSONValue {
        let folder = result.photo.deletingLastPathComponent().path(percentEncoded: false)
        var message = "Exported \"\(wallpaper.title)\" as a Live Photo for \(device.name) (\(device.pixelSize.x)×\(device.pixelSize.y)): "
            + "\(result.photo.lastPathComponent) and \(result.movie.lastPathComponent) in \(folder)."
        if result.isInCache {
            message += " They stay in the app's cache folder until the next export from the iPhone & iPad Export mode clears it; pass output_folder to keep them."
        }
        if let photos = photosSentence(result.photos) { message += " " + photos }
        return [
            "wallpaper": ControlLookup.json(wallpaper),
            "device": json(device),
            "photo": .string(result.photo.path(percentEncoded: false)),
            "movie": .string(result.movie.path(percentEncoded: false)),
            "in_cache": .bool(result.isInCache),
            "crop": [
                "zoom": .number(result.crop.zoom),
                "center_x": .number(result.crop.center.x), "center_y": .number(result.crop.center.y),
                "scene_width": .number(result.crop.sceneSize.x), "scene_height": .number(result.crop.sceneSize.y),
            ],
            "clip": [
                "start": .number(result.clip.start), "length": .number(result.clip.length),
                "automatic": .bool(result.clipIsAutomatic),
            ],
            "quality": .string(quality.rawValue),
            "photos": json(result.photos),
            "message": .string(message),
        ]
    }

    private static func json(_ photos: SystemLivePhotoResult.Photos) -> JSONValue {
        switch photos {
        case .off: return ["status": "off"]
        case .skipped: return ["status": "skipped"]
        case .saved(let album): return ["status": "saved", "album": .string(album)]
        case .failed(let album, let reason): return ["status": "failed", "album": .string(album), "reason": .string(reason)]
        case .needsAccess(let album, let access):
            return ["status": "needs_access", "album": .string(album), "photos_access": .string(access)]
        }
    }

    private static func photosSentence(_ photos: SystemLivePhotoResult.Photos) -> String? {
        switch photos {
        case .off: return nil
        case .skipped: return "save_to_photos: false left it out of the Photos album this time."
        case .saved(let album): return "Also saved to the \"\(album)\" album in Photos (Also Save to Photos Album is on)."
        case .failed(let album, let reason): return "It couldn't be saved to the \"\(album)\" album in Photos: \(reason)"
        case .needsAccess(let album, let access):
            let how = access == "not_determined"
                ? "turn on Also Save to Photos Album once in Scene Edit / Export's iPhone & iPad Export mode (Export Settings) and allow access"
                : "allow Open Wallpaper Engine full access in System Settings › Privacy & Security › Photos"
            return "Also Save to Photos Album is on, but Open Wallpaper Engine may not use Photos (access: \(access)), so it wasn't saved to \"\(album)\". To save there, \(how)."
        }
    }
}
