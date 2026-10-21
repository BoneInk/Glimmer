import AppKit
import Combine

/// A wallpaper window's content: the wallpaper's view, placed on the display by the wallpaper's
/// display options there (`WallpaperDisplayOptions`: offset, zoom, flip). The options are a
/// transform of this view's layer's sublayers, so Core Animation applies them as the frame is
/// shown: a change draws nothing again, whatever the wallpaper's type. Parts the picture leaves
/// uncovered show the window's black.
final class WallpaperDisplayTransformView: NSView {
    private let screenID: String
    private weak var viewModel: WallpaperViewModel?
    private var options = WallpaperDisplayOptions.identity
    private var cancellables = Set<AnyCancellable>()

    @MainActor
    init(content: NSView, screenID: String, viewModel: WallpaperViewModel) {
        self.screenID = screenID
        self.viewModel = viewModel
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        addSubview(content)
        // Read after the change lands: `@Published` emits before it stores the new value.
        viewModel.displayOptions.$entries.map { _ in () }
            .merge(with: viewModel.$wallpapers.map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in MainActor.assumeIsolated { self?.refresh() } }
            .store(in: &cancellables)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @MainActor
    private func refresh() {
        guard let viewModel else { return }
        let options = viewModel.displayOptions(on: screenID)
        guard options != self.options else { return }
        self.options = options
        applyTransform()
    }

    override func layout() {
        super.layout()
        applyTransform()
    }

    private func applyTransform() {
        guard let layer else { return }
        let size = bounds.size
        let anchor = CGPoint(x: layer.anchorPoint.x * size.width, y: layer.anchorPoint.y * size.height)
        let transform = options.transformsPicture
            ? CATransform3DMakeAffineTransform(options.transform(size: size, anchor: anchor))
            : CATransform3DIdentity
        guard !CATransform3DEqualToTransform(layer.sublayerTransform, transform) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.sublayerTransform = transform
        CATransaction.commit()
    }
}
