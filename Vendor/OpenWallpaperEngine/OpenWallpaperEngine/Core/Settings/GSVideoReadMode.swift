import Foundation

/// WE's "Video loading" setting (`videoreadmode`, its Settings › Advanced): `fromdisk` (the
/// default) plays a video wallpaper from its file, `frommemory` reads the file into memory once
/// and plays it from there (`VideoFileSource`). The raw values are WE's.
enum GSVideoReadMode: String, CaseIterable, Identifiable, Codable {
    var id: Self { self }
    case fromDisk = "fromdisk"
    case inMemory = "frommemory"
}
