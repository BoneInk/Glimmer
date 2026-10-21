import Foundation

/// One package "Send over Wi-Fi" offers: what the phone's page shows of it, and the file and
/// preview the server reads. The server finds it by its number (`index`: its place in a batch, or
/// its Android exports list entry's number), never by a path from the request.
struct AndroidWiFiFile: Equatable, Identifiable, Sendable {
    /// What the page calls the package.
    enum Kind: String, Codable, Equatable, Sendable {
        case sceneDynamic, scenePreRendered, video
    }

    var index: Int
    var title: String
    var kind: Kind
    var url: URL
    var size: Int64
    var previewURL: URL?
    /// `<title>.mpkg`, unique within the batch: the name the phone saves it under.
    var downloadName: String
    /// The Android device it was framed for, when the export chose one.
    var device: String? = nil

    var id: Int { index }

    static func kind(type: String, mode: AndroidExportOptions.Mode?) -> Kind {
        if type == "video" { return .video }
        return mode == .preRendered ? .scenePreRendered : .sceneDynamic
    }

    /// The batch's packages, in its order.
    static func files(of batch: AndroidExportBatch) -> [AndroidWiFiFile] {
        let names = AndroidExportNaming.uniqueNames(batch.outputs.map(\.title), taken: [])
        return zip(batch.outputs, names).enumerated().map { index, pair in
            let (output, name) = pair
            return AndroidWiFiFile(index: index, title: output.title, kind: kind(type: output.type, mode: output.mode),
                                   url: output.url, size: output.size, previewURL: output.previewURL, downloadName: name)
        }
    }
}
