import AppKit
import Observation
import SwiftUI

/// A presentation route only: opening it never changes playback or library navigation.
@MainActor @Observable
final class WorkspaceWallpaperDetails {
    struct Route: Identifiable {
        let id = UUID()
        let key: String
        var item: WallpaperItem?
        var result: WorkshopSearchResult?
        var scenePreview: (any WorkspaceScenePreviewOwning)?

        @MainActor
        var scenePreviewModel: SceneWallpaperPreviewModel? {
            (scenePreview as? SceneWallpaperPreviewPreparation)?.model
        }
    }
    typealias ScenePreviewPreparationFactory = @MainActor
        (WallpaperItem, AppStorage, Int, SceneVector2?) -> any WorkspaceScenePreviewOwning

    private(set) var route: Route?
    // One immutable bitmap is retained from takeoff through both handoffs.
    var coverImage: NSImage?
    var destinationSnapshot: NSImage?
    var snapshotPreparationFinished = false
    var destinationCoverVisible = false
    var livePreviewOpacity: Double = 1
    var suppressSource = false
    var closing = false
    private var pendingSourceKey: String?
    @ObservationIgnored private var scenePreviewStorage: AppStorage?
    @ObservationIgnored private var scenePreviewWallpaperFPS = 30
    @ObservationIgnored var scenePreviewPreparationFactory: ScenePreviewPreparationFactory = {
        SceneWallpaperPreviewPreparation(item: $0, storage: $1, wallpaperFPS: $2,
                                         screenResolution: $3)
    }
    @ObservationIgnored var scenePreviewScreenResolutionProvider: @MainActor () -> SceneVector2? = {
        SceneWallpaperClickContext.physicalDisplayResolution()
    }
    @ObservationIgnored var localWallpaperLookup: @MainActor (String) -> WallpaperItem? = { _ in nil }

    /// Queue completion precedes import. Observe the live library before
    /// replacing the public preview with a local detail page.
    var downloadedItemForCurrentResult: WallpaperItem? {
        guard !closing, let result = route?.result,
              let item = localWallpaperLookup(result.id),
              item.workshopID == result.id, item.fileExists else { return nil }
        return item
    }

    @discardableResult
    func promoteDownloadedResult() -> Bool {
        guard var current = route, let item = downloadedItemForCurrentResult else { return false }
        current.item = item
        current.result = nil
        if item.isSceneWallpaper, let scenePreviewStorage {
            current.scenePreview = scenePreviewPreparationFactory(
                item, scenePreviewStorage, scenePreviewWallpaperFPS,
                scenePreviewScreenResolutionProvider())
        }
        destinationSnapshot = nil
        snapshotPreparationFinished = false
        // Keep the route identity and source key so the card-opening flight
        // does not replay and Back still returns to the same browsing page.
        route = current
        return true
    }

    func configureScenePreview(storage: AppStorage, wallpaperFPS: Int) {
        scenePreviewStorage = storage
        scenePreviewWallpaperFPS = min(max(wallpaperFPS, 1), 240)
        if let preview = route?.scenePreview as? SceneWallpaperPreviewPreparation {
            preview.model.setWallpaperFPS(scenePreviewWallpaperFPS)
        } else if route?.scenePreview == nil, !closing, let item = route?.item,
                  item.isSceneWallpaper, item.fileExists {
            route?.scenePreview = scenePreviewPreparationFactory(
                item, storage, scenePreviewWallpaperFPS,
                scenePreviewScreenResolutionProvider())
        }
    }

    func prepareSource(_ key: String) { pendingSourceKey = key }
    private func consumeSource(for key: String) -> String {
        defer { pendingSourceKey = nil }
        if let pendingSourceKey, pendingSourceKey == key || pendingSourceKey.hasPrefix(key + ":") { return pendingSourceKey }
        if let route, route.key == key || route.key.hasPrefix(key + ":") { return route.key }
        return key
    }
    func open(_ item: WallpaperItem) {
        cancelCurrentScenePreview()
        resetCover()
        closing = false
        let scenePreview: (any WorkspaceScenePreviewOwning)?
        if item.isSceneWallpaper, item.fileExists, let scenePreviewStorage {
            scenePreview = scenePreviewPreparationFactory(
                item, scenePreviewStorage, scenePreviewWallpaperFPS,
                scenePreviewScreenResolutionProvider())
        } else {
            scenePreview = nil
        }
        route = Route(key: consumeSource(for: Self.key(for: item)), item: item, result: nil,
                      scenePreview: scenePreview)
    }
    func open(_ result: WorkshopSearchResult) {
        if let item = localWallpaperLookup(result.id), item.workshopID == result.id, item.fileExists {
            open(item)
            return
        }
        cancelCurrentScenePreview()
        resetCover()
        closing = false
        route = Route(key: consumeSource(for: "workshop:\(result.id)"), item: nil, result: result,
                      scenePreview: nil)
    }
    func acceptSnapshot(_ image: NSImage?, routeID: UUID) {
        guard route?.id == routeID, !closing, !snapshotPreparationFinished else { return }
        destinationSnapshot = image; snapshotPreparationFinished = true
    }
    func dismiss() {
        closing = true
        cancelCurrentScenePreview()
    }
    func dismissForCreatorNavigation() {
        cancelCurrentScenePreview()
        route = nil; closing = false; pendingSourceKey = nil; resetCover()
    }
    func finishDismissal(_ id: UUID) {
        guard route?.id == id, closing else { return }
        cancelCurrentScenePreview()
        route = nil; closing = false; resetCover()
    }
    private func cancelCurrentScenePreview() {
        route?.scenePreview?.cancel()
    }
    private func resetCover() {
        coverImage = nil; destinationSnapshot = nil; snapshotPreparationFinished = false; destinationCoverVisible = false
        livePreviewOpacity = 1; suppressSource = false
    }
    static func key(for item: WallpaperItem) -> String {
        item.workshopID.map { "workshop:\($0)" } ?? "library:\(item.id)"
    }
}

private struct WorkspaceWallpaperDetailsKey: EnvironmentKey {
    static let defaultValue: WorkspaceWallpaperDetails? = nil
}
extension EnvironmentValues {
    var workspaceWallpaperDetails: WorkspaceWallpaperDetails? {
        get { self[WorkspaceWallpaperDetailsKey.self] }
        set { self[WorkspaceWallpaperDetailsKey.self] = newValue }
    }
}

enum WallpaperCoverContentMode: Equatable { case fill, fit }

struct WallpaperCoverGeometry: Equatable {
    var frame: CGRect
    var image: NSImage?
    var data: Data?
    var remoteURL: URL?
    var requiresSnapshot = false
    var ready = true
    var mode: WallpaperCoverContentMode = .fill
    var cornerRadius: CGFloat = 22
    var geometryPriority = 0
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.frame == rhs.frame && lhs.image === rhs.image && lhs.data == rhs.data && lhs.remoteURL == rhs.remoteURL
            && lhs.requiresSnapshot == rhs.requiresSnapshot && lhs.ready == rhs.ready && lhs.mode == rhs.mode && lhs.cornerRadius == rhs.cornerRadius && lhs.geometryPriority == rhs.geometryPriority
    }
    func hasSameLayout(as other: Self) -> Bool {
        frame == other.frame && mode == other.mode && cornerRadius == other.cornerRadius
    }
}
private struct WallpaperCoverGeometryKey: PreferenceKey {
    static let defaultValue: [String: WallpaperCoverGeometry] = [:]
    static func reduce(value: inout [String: WallpaperCoverGeometry], nextValue: () -> [String: WallpaperCoverGeometry]) {
        value.merge(nextValue(), uniquingKeysWith: { previous, latest in
            // Download cards also register their outer frame. Keep the bitmap
            // captured by the actual artwork rather than its URL-only wrapper.
            var merged = latest.geometryPriority >= previous.geometryPriority ? latest : previous
            let artwork = latest.image != nil || latest.data != nil ? latest : previous
            merged.image = artwork.image; merged.data = artwork.data
            merged.remoteURL = merged.remoteURL ?? artwork.remoteURL
            return merged
        })
    }
}
extension View {
    func wallpaperCoverSource(_ key: String?, image: NSImage? = nil, data: Data? = nil, remoteURL: URL? = nil, geometryPriority: Int = 0) -> some View {
        modifier(WallpaperCoverSourceModifier(key: key, image: image, data: data, remoteURL: remoteURL, geometryPriority: geometryPriority))
    }
    func wallpaperCoverDestination(enabled: Bool = true, ready: Bool = true,
                                   mode: WallpaperCoverContentMode = .fill, cornerRadius: CGFloat = 12, requiresSnapshot: Bool = false) -> some View {
        modifier(WallpaperCoverDestinationModifier(enabled: enabled, ready: ready, mode: mode, cornerRadius: cornerRadius, requiresSnapshot: requiresSnapshot))
    }
}

private struct WallpaperCoverSourceModifier: ViewModifier {
    let key: String?
    let image: NSImage?
    let data: Data?
    let remoteURL: URL?
    let geometryPriority: Int
    @Environment(\.workspaceWallpaperDetails) private var presentation
    func body(content: Content) -> some View {
        content
            .opacity(key != nil && presentation?.route?.key == key && presentation?.suppressSource == true ? 0 : 1)
            .background {
                if let key {
                    GeometryReader { geometry in
                        Color.clear.preference(key: WallpaperCoverGeometryKey.self,
                            value: [key: .init(frame: geometry.frame(in: .named("wallpaper-detail-content")),
                                image: image, data: data, remoteURL: remoteURL, geometryPriority: geometryPriority)])
                    }
                }
            }
    }
}

private struct WallpaperCoverDestinationModifier: ViewModifier {
    let enabled: Bool
    let ready: Bool
    let mode: WallpaperCoverContentMode
    let cornerRadius: CGFloat
    let requiresSnapshot: Bool
    @Environment(\.workspaceWallpaperDetails) private var presentation
    func body(content: Content) -> some View {
        // Read observable presentation values while THIS body is tracked. Reads
        // made only inside overlay/GeometryReader's deferred builders can leave
        // an old opaque Canvas covering a player which is already running.
        let image = presentation?.destinationSnapshot ?? presentation?.coverImage
        let hasCover = presentation?.coverImage != nil
        let hasSnapshot = presentation?.destinationSnapshot != nil
        let coverVisible = presentation?.destinationCoverVisible == true
        let opacity = presentation?.livePreviewOpacity ?? 1
        let routeID = presentation?.route?.id
        return content
            // The ready renderer remains opaque below a single fading cover.
            .opacity(enabled && hasCover && !coverVisible ? 0 : 1)
            .overlay {
                if enabled, let image, coverVisible {
                    GeometryReader { geometry in
                        let rect = CGRect(origin: .zero, size: geometry.size)
                        WallpaperCoverCanvas(image: image, frame: rect, imageFrame: WallpaperCoverTransitionGeometry.imageFrame(
                            imageSize: image.size, container: rect, mode: hasSnapshot ? .fill : mode), cornerRadius: cornerRadius)
                    }
                    .opacity(1 - opacity)
                    .allowsHitTesting(false)
                }
            }
            .background {
                if enabled, let routeID {
                    GeometryReader { geometry in
                        Color.clear.preference(key: WallpaperCoverGeometryKey.self,
                            value: ["destination:\(routeID)": .init(frame: geometry.frame(in: .named("wallpaper-detail-content")),
                                requiresSnapshot: requiresSnapshot, ready: ready, mode: mode, cornerRadius: cornerRadius)])
                    }
                }
            }
    }
}

/// Immutable endpoints: later preferences cannot retarget a flight in progress.
struct WallpaperCoverFlightSnapshot {
    let image: NSImage
    let source: WallpaperCoverGeometry
    let destination: WallpaperCoverGeometry
    var sourceImageFrame: CGRect? = nil
    var destinationSourceImageFrame: CGRect? = nil
    var secondImage: NSImage? = nil
    var secondImageSourceFrame: CGRect? = nil
    var secondImageDestinationFrame: CGRect? = nil
    var sourceBlend: CGFloat = 0
    var destinationBlend: CGFloat = 1
    func state(at progress: CGFloat) -> WallpaperCoverRenderState {
        let frame = WallpaperCoverTransitionGeometry.frame(source: source.frame, destination: destination.frame,
            progress: progress, reduceMotion: false)
        let from = sourceImageFrame ?? WallpaperCoverTransitionGeometry.imageFrame(imageSize: image.size, container: source.frame, mode: source.mode)
        let to = destinationSourceImageFrame ?? WallpaperCoverTransitionGeometry.imageFrame(imageSize: image.size, container: destination.frame, mode: destination.mode)
        return .init(frame: frame, imageFrame: WallpaperCoverTransitionGeometry.frame(source: from, destination: to,
            progress: progress, reduceMotion: false), cornerRadius: source.cornerRadius +
                (destination.cornerRadius - source.cornerRadius) * min(1, max(0, progress)),
            secondImageFrame: secondImageSourceFrame.flatMap { from in secondImageDestinationFrame.map {
                WallpaperCoverTransitionGeometry.frame(source: from, destination: $0, progress: progress, reduceMotion: false) } },
            blend: secondImage == nil ? 0 : sourceBlend + (destinationBlend - sourceBlend) * min(1, max(0, progress)))
    }
}
struct WallpaperCoverRenderState: Equatable, Sendable {
    let frame: CGRect
    let imageFrame: CGRect
    let cornerRadius: CGFloat
    var secondImageFrame: CGRect? = nil
    var blend: CGFloat = 0
}
enum WallpaperCoverTransitionGeometry {
    static func frame(source: CGRect, destination: CGRect, progress: CGFloat, reduceMotion: Bool) -> CGRect {
        guard !reduceMotion else { return destination }
        let t = min(1, max(0, progress))
        return CGRect(x: source.minX + (destination.minX - source.minX) * t,
                      y: source.minY + (destination.minY - source.minY) * t,
                      width: source.width + (destination.width - source.width) * t,
                      height: source.height + (destination.height - source.height) * t)
    }
    static func imageFrame(imageSize: CGSize, container: CGRect, mode: WallpaperCoverContentMode) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return container }
        let x = container.width / imageSize.width, y = container.height / imageSize.height
        let scale = mode == .fill ? max(x, y) : min(x, y)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: container.midX - size.width / 2, y: container.midY - size.height / 2,
                      width: size.width, height: size.height)
    }
}

/// Rendering records a plain, locked value rather than publishing SwiftUI state.
/// A close during takeoff can reverse from the actual onscreen frame, not the
/// animation's already-committed model value of 1.
final class WallpaperCoverFlightTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: WallpaperCoverRenderState?
    func record(_ value: WallpaperCoverRenderState) { lock.lock(); latest = value; lock.unlock() }
    func read() -> WallpaperCoverRenderState? { lock.lock(); defer { lock.unlock() }; return latest }
}

/// Geometry AND image crop are recomputed from the same interpolated scalar on
/// every display frame. No layout/position modifier gets a second animation.
struct WallpaperCoverFlightView: View, Animatable {
    let snapshot: WallpaperCoverFlightSnapshot
    nonisolated var progress: CGFloat
    var tracker: WallpaperCoverFlightTracker? = nil
    nonisolated var animatableData: CGFloat { get { progress } set { progress = newValue } }
    var body: some View {
        let state = snapshot.state(at: progress)
        WallpaperCoverCanvas(image: snapshot.image, frame: state.frame,
            imageFrame: state.imageFrame, cornerRadius: state.cornerRadius,
            secondImage: snapshot.secondImage, secondImageFrame: state.secondImageFrame, blend: state.blend,
            onRender: { [tracker] in tracker?.record(state) })
    }
}
private struct WallpaperCoverCanvas: View {
    let image: NSImage
    let frame: CGRect
    let imageFrame: CGRect
    let cornerRadius: CGFloat
    var secondImage: NSImage? = nil
    var secondImageFrame: CGRect? = nil
    var blend: CGFloat = 0
    var onRender: (@Sendable () -> Void)? = nil
    var body: some View {
        Canvas { context, _ in
            onRender?()
            let clip = Path(roundedRect: frame, cornerRadius: cornerRadius)
            context.clip(to: clip)
            context.fill(clip, with: .color(.black))
            if let secondImage, let secondImageFrame {
                context.draw(Image(nsImage: secondImage).interpolation(.high), in: secondImageFrame)
                context.opacity = 1 - blend
            }
            context.draw(Image(nsImage: image).interpolation(.high), in: imageFrame)
        }
        .accessibilityHidden(true)
    }
}

struct WorkspaceWallpaperDetailsHost<Content: View, Detail: View>: View {
    let presentation: WorkspaceWallpaperDetails
    @ViewBuilder let content: () -> Content
    @ViewBuilder let detail: (WorkspaceWallpaperDetails.Route) -> Detail
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.windowGlassReduceMotionOverride) private var reviewReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || reviewReduceMotion }
    private enum Phase { case idle, waitingForLayout, flying, landed, revealing, live, closingBlend, returning }
    @GlassState private var phase: Phase = .idle
    @GlassState private var geometries: [String: WallpaperCoverGeometry] = [:]
    @GlassState private var source: WallpaperCoverGeometry?
    @GlassState private var layoutCandidate: WallpaperCoverGeometry?
    @GlassState private var layoutSettled = false
    @GlassState private var flight: WallpaperCoverFlightSnapshot?
    @GlassState private var flightTracker = WallpaperCoverFlightTracker()
    @GlassState private var preparedFlight: WallpaperCoverFlightSnapshot?
    @GlassState private var progress: CGFloat = 0
    @GlassState private var pageOpacity: Double = 0
    @GlassState private var layoutTask: Task<Void, Never>?
    @GlassState private var animationTicket = UUID()

    var body: some View {
        ZStack(alignment: .topLeading) {
            content()
                .allowsHitTesting(presentation.route == nil)
                .accessibilityHidden(presentation.route != nil)
            if let route = presentation.route {
                detail(route)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .windowBackgroundColor))
                    // A fully transparent WK host cannot produce its first RAF
                    // frame. This imperceptible preparation alpha keeps it mounted
                    // and drawable while the browser remains visible.
                    .opacity(phase == .waitingForLayout && geometries["destination:\(route.id)"]?.requiresSnapshot == true ? 0.001 : pageOpacity)
                    .allowsHitTesting(phase == .landed || phase == .revealing || phase == .live)
                    .zIndex(1)
                if let flight, phase == .flying || phase == .returning {
                    WallpaperCoverFlightView(snapshot: flight, progress: progress, tracker: flightTracker)
                        .allowsHitTesting(false).zIndex(2)
                }
            }
        }
        .coordinateSpace(name: "wallpaper-detail-content")
        .clipped()
        .environment(\.workspaceWallpaperDetails, presentation)
        .onPreferenceChange(WallpaperCoverGeometryKey.self) { values in
            geometries = values
            guard let route = presentation.route, let target = values["destination:\(route.id)"] else { return }
            if phase == .waitingForLayout { stabilize(target, route: route) }
            else if phase == .landed { revealIfReady(route) }
            else if phase == .live, !target.ready, presentation.coverImage != nil {
                phase = .landed; presentation.destinationCoverVisible = true; presentation.livePreviewOpacity = 0
            }
        }
        .onChange(of: presentation.route?.id, initial: true) { _, id in
            layoutTask?.cancel(); layoutTask = nil
            animationTicket = UUID(); flight = nil; preparedFlight = nil; progress = 0; pageOpacity = 0; layoutCandidate = nil; layoutSettled = false
            phase = id == nil ? .idle : .waitingForLayout
            source = presentation.route.flatMap { geometries[$0.key] }
            if let route = presentation.route, let target = geometries["destination:\(route.id)"] { stabilize(target, route: route) }
        }
        .onChange(of: presentation.snapshotPreparationFinished) { _, finished in
            guard finished, layoutSettled, phase == .waitingForLayout, let route = presentation.route,
                  let target = geometries["destination:\(route.id)"] else { return }
            beginOpen(route, target: target)
        }
        .onChange(of: presentation.closing) { _, closing in
            if closing, let route = presentation.route { beginClose(route) }
        }
        .onDisappear { layoutTask?.cancel(); animationTicket = UUID() }
        .onExitCommand { if presentation.route != nil { presentation.dismiss() } }
    }

    private func stabilize(_ target: WallpaperCoverGeometry, route: WorkspaceWallpaperDetails.Route) {
        guard target.frame.width > 0, target.frame.height > 0 else { return }
        if reduceMotion { beginOpen(route, target: target); return }
        if let layoutCandidate, layoutCandidate.hasSameLayout(as: target) { return }
        layoutCandidate = target; layoutSettled = false
        layoutTask?.cancel()
        layoutTask = Task { @MainActor in
            // This is a debounce of THIS route's measured layout, never a timeout
            // fallback to an old or invented destination.
            try? await Task.sleep(for: .milliseconds(32))
            guard !Task.isCancelled, presentation.route?.id == route.id, !presentation.closing,
                  phase == .waitingForLayout,
                  let current = geometries["destination:\(route.id)"], current.hasSameLayout(as: target) else { return }
            layoutSettled = true
            beginOpen(route, target: current)
        }
    }
    private func beginOpen(_ route: WorkspaceWallpaperDetails.Route, target: WallpaperCoverGeometry) {
        guard reduceMotion || !target.requiresSnapshot || presentation.snapshotPreparationFinished else { return }
        let origin = source ?? geometries[route.key]
        let image = origin?.image ?? origin?.data.flatMap(NSImage.init(data:))
        presentation.suppressSource = true
        if !reduceMotion, let origin, let image {
            presentation.coverImage = image; presentation.livePreviewOpacity = 0
            var snapshot = WallpaperCoverFlightSnapshot(image: image, source: origin, destination: target)
            if let destinationImage = presentation.destinationSnapshot {
                let sourceEnd = WallpaperCoverSnapshotAlignment.match(source: image, target: destinationImage, in: target.frame)?.sourceFrame
                    ?? WallpaperCoverTransitionGeometry.imageFrame(imageSize: image.size, container: target.frame, mode: .fill)
                let sourceStart = snapshot.state(at: 0).imageFrame
                let scale = sourceStart.width / sourceEnd.width
                snapshot.destinationSourceImageFrame = sourceEnd
                snapshot.secondImage = destinationImage
                snapshot.secondImageSourceFrame = CGRect(x: sourceStart.minX - (sourceEnd.minX - target.frame.minX) * scale,
                    y: sourceStart.minY - (sourceEnd.minY - target.frame.minY) * scale,
                    width: target.frame.width * scale, height: target.frame.height * scale)
                snapshot.secondImageDestinationFrame = target.frame
            }
            preparedFlight = snapshot
            fly(snapshot, route: route, returning: false)
        } else {
            phase = .live
            withAnimation(.easeOut(duration: 0.16)) { pageOpacity = 1 }
        }
    }
    private func fly(_ snapshot: WallpaperCoverFlightSnapshot, route: WorkspaceWallpaperDetails.Route, returning: Bool) {
        let ticket = UUID(); animationTicket = ticket
        var transaction = Transaction(); transaction.disablesAnimations = true
        withTransaction(transaction) {
            flight = snapshot; progress = 0
            flightTracker.record(snapshot.state(at: 0))
            phase = returning ? .returning : .flying
            presentation.destinationCoverVisible = false
        }
        Task { @MainActor in
            await Task.yield()
            guard animationTicket == ticket, presentation.route?.id == route.id else { return }
            withAnimation(.timingCurve(0.22, 0.8, 0.25, 1, duration: returning ? 0.42 : 0.48), completionCriteria: .removed) {
                progress = 1; pageOpacity = returning ? 0 : 1
            } completion: {
                guard animationTicket == ticket, presentation.route?.id == route.id else { return }
                if returning { presentation.finishDismissal(route.id) }
                else { land(snapshot, route: route) }
            }
        }
    }
    private func land(_ snapshot: WallpaperCoverFlightSnapshot, route: WorkspaceWallpaperDetails.Route) {
        guard !presentation.closing else { return }
        if let latest = geometries["destination:\(route.id)"], !latest.hasSameLayout(as: snapshot.destination) {
            // Late intrinsic-size changes cannot bend the original flight. Finish
            // it first, then move the SAME bitmap continuously into the new box.
            var continuation = WallpaperCoverFlightSnapshot(image: snapshot.image, source: snapshot.destination, destination: latest,
                sourceImageFrame: snapshot.state(at: 1).imageFrame)
            if let second = snapshot.secondImage {
                continuation.secondImage = second
                continuation.secondImageSourceFrame = snapshot.state(at: 1).secondImageFrame
                continuation.secondImageDestinationFrame = latest.frame
                continuation.sourceBlend = 1; continuation.destinationBlend = 1
            }
            fly(continuation, route: route, returning: false)
            return
        }
        var transaction = Transaction(); transaction.disablesAnimations = true
        withTransaction(transaction) {
            presentation.destinationCoverVisible = true
            phase = .landed; flight = nil
        }
        revealIfReady(route)
    }
    private func revealIfReady(_ route: WorkspaceWallpaperDetails.Route) {
        guard phase == .landed, geometries["destination:\(route.id)"]?.ready == true, !presentation.closing else { return }
        let ticket = UUID(); animationTicket = ticket
        phase = .revealing
        withAnimation(.easeInOut(duration: 0.24), completionCriteria: .removed) {
            presentation.livePreviewOpacity = 1
        } completion: {
            guard animationTicket == ticket, presentation.route?.id == route.id, !presentation.closing else { return }
            phase = .live
        }
    }
    private func beginClose(_ route: WorkspaceWallpaperDetails.Route) {
        layoutTask?.cancel(); animationTicket = UUID()
        guard !reduceMotion, let image = presentation.coverImage,
              let origin = geometries[route.key] ?? source,
              let target = geometries["destination:\(route.id)"] else {
            phase = .closingBlend
            withAnimation(.easeOut(duration: 0.16), completionCriteria: .removed) { pageOpacity = 0 } completion: {
                presentation.finishDismissal(route.id)
            }
            return
        }
        // Closing during takeoff reverses the actual rendered flight without
        // switching to the live preview's frame or choosing another image.
        if phase == .flying, let current = flight {
            let state = flightTracker.read() ?? current.state(at: 0)
            let from = WallpaperCoverGeometry(frame: state.frame, mode: current.destination.mode, cornerRadius: state.cornerRadius)
            var reverse = WallpaperCoverFlightSnapshot(image: image, source: from, destination: origin, sourceImageFrame: state.imageFrame)
            if let preparedFlight, let second = current.secondImage {
                reverse.secondImage = second; reverse.secondImageSourceFrame = state.secondImageFrame
                reverse.secondImageDestinationFrame = preparedFlight.secondImageSourceFrame
                reverse.sourceBlend = state.blend; reverse.destinationBlend = 0
            }
            fly(reverse, route: route, returning: true)
            return
        }
        phase = .closingBlend; presentation.destinationCoverVisible = true
        let ticket = UUID(); animationTicket = ticket
        withAnimation(.easeInOut(duration: 0.2), completionCriteria: .removed) {
            presentation.livePreviewOpacity = 0
        } completion: {
            guard animationTicket == ticket, presentation.route?.id == route.id else { return }
            var reverse = WallpaperCoverFlightSnapshot(image: image, source: target, destination: origin)
            if let preparedFlight, let second = preparedFlight.secondImage {
                reverse.sourceImageFrame = preparedFlight.destinationSourceImageFrame
                reverse.secondImage = second; reverse.secondImageSourceFrame = target.frame
                reverse.secondImageDestinationFrame = preparedFlight.secondImageSourceFrame
                reverse.sourceBlend = 1; reverse.destinationBlend = 0
            }
            fly(reverse, route: route, returning: true)
        }
    }
}
