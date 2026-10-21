import ImageIO
import MetalKit

/// WE's media system textures (`SceneSystemTexture`): `$mediaThumbnail`, the now-playing artwork,
/// and `$mediaPreviousThumbnail`, the artwork it replaced. Fed by the process's media session; each
/// new image is decoded and uploaded once, on a background queue, when the session reports it; the
/// render thread only takes the finished texture. Without artwork a texture is nil, and the layer
/// shows its own image (also while a new image is still being made, the old one is kept).
///
/// A renderer makes one only while its content binds a media texture, so a wallpaper without one
/// never starts the media session.
final class SceneMediaTextures {
    private typealias Artwork = (key: Int, png: Data)
    /// An artwork's texture; nil while it is being made or when it can't be.
    private typealias Made = (key: Int, texture: MTLTexture?)

    private let source: MediaSessionSource
    private var subscription: Int?
    /// Makes the textures, one image at a time.
    private let queue = DispatchQueue(label: "SceneMediaTextures", qos: .utility)
    private let makeTexture: (Data) -> MTLTexture?
    /// Owns `current`, `previous` and `textures`: the source reports on its own queue, the
    /// textures are made on `queue`, the renderer reads on its thread.
    private let lock = NSLock()
    private var current: Artwork?
    private var previous: Artwork?
    /// The finished textures by artwork key (the current and previous artwork's at most).
    private var textures: [Int: MTLTexture?] = [:]

    convenience init(source: MediaSessionSource, device: MTLDevice) {
        let loader = MTKTextureLoader(device: device)
        self.init(source: source) { Self.upload($0, loader: loader, device: device) }
    }

    /// `makeTexture` decodes and uploads one PNG (any thread but the render thread).
    init(source: MediaSessionSource, makeTexture: @escaping (Data) -> MTLTexture?) {
        self.source = source
        self.makeTexture = makeTexture
        subscription = source.subscribe { [weak self] state in self?.receive(state) }
    }

    deinit {
        if let subscription { source.unsubscribe(subscription) }
    }

    /// Takes a state from the source (any thread). A track without artwork clears the thumbnail;
    /// new artwork moves the old one to the previous thumbnail and starts making its texture.
    /// The same artwork again (every timeline tick) does nothing.
    func receive(_ state: MediaSessionState) {
        let artwork: Artwork? = state.thumbnail.artwork.flatMap { key in state.thumbnail.png.map { (key, $0) } }
        let started: Artwork? = lock.withLock {
            guard artwork?.key != current?.key else { return nil }
            if let current { previous = current }
            current = artwork
            let kept = Set([current?.key, previous?.key].compactMap { $0 })
            textures = textures.filter { kept.contains($0.key) }
            return artwork.flatMap { textures[$0.key] == nil ? $0 : nil }
        }
        guard let started else { return }
        queue.async { [weak self] in
            guard let self else { return }
            // Superseded before its turn: nothing shows it.
            let wanted = self.lock.withLock { self.current?.key == started.key || self.previous?.key == started.key }
            guard wanted else { return }
            let texture = self.makeTexture(started.png)
            self.lock.withLock {
                guard self.current?.key == started.key || self.previous?.key == started.key else { return }
                self.textures[started.key] = .some(texture)
            }
        }
    }

    /// The texture's image now; nil without artwork, while it is still being made (or when it
    /// can't be decoded, logged once per image). Render thread: no decoding or upload here.
    func texture(_ kind: SceneSystemTexture) -> MTLTexture? {
        lock.withLock {
            let artwork: Artwork?
            switch kind {
            case .mediaThumbnail: artwork = current
            case .mediaPreviousThumbnail: artwork = previous
            }
            guard let artwork, let made = textures[artwork.key] else { return nil }
            return made
        }
    }

    /// Waits for the textures in the making (tests).
    func waitForUploads() { queue.sync {} }

    private static func upload(_ png: Data, loader: MTKTextureLoader, device: MTLDevice) -> MTLTexture? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            OWELog.error(.scene, "The now-playing artwork (\(png.count) bytes) can't be decoded; media thumbnails show their layers' images")
            return nil
        }
        do {
            return try SceneTextureUpload.texture(from: image, loader: loader, device: device)
        } catch {
            OWELog.error(.scene, "The now-playing artwork (\(image.width)×\(image.height)) can't be uploaded: \(error)")
            return nil
        }
    }
}
