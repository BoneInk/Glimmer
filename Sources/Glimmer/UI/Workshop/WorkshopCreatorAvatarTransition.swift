import AppKit
import Observation
import SwiftUI

enum WorkshopCreatorAvatarRole: Hashable { case detail, gallery }

struct WorkshopCreatorAvatarKey: Hashable {
    let authorID: String
    let role: WorkshopCreatorAvatarRole
}

struct WorkshopCreatorAvatarGeometry: Equatable {
    let frame: CGRect
    let image: NSImage?
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.frame == rhs.frame && lhs.image === rhs.image
    }
    var isValid: Bool {
        frame.width > 0 && frame.height > 0 &&
        [frame.minX, frame.minY, frame.width, frame.height].allSatisfy { $0.isFinite }
    }
}

struct WorkshopCreatorAvatarFlight: Identifiable {
    let id = UUID()
    let authorID: String
    let source: WorkshopCreatorAvatarGeometry
    let destination: WorkshopCreatorAvatarGeometry
    func frame(at progress: CGFloat) -> CGRect {
        let t = min(1, max(0, progress))
        return CGRect(x: source.frame.minX + (destination.frame.minX - source.frame.minX) * t,
                      y: source.frame.minY + (destination.frame.minY - source.frame.minY) * t,
                      width: source.frame.width + (destination.frame.width - source.frame.width) * t,
                      height: source.frame.height + (destination.frame.height - source.frame.height) * t)
    }
}

@MainActor @Observable
final class WorkshopCreatorAvatarTransition {
    private(set) var authorID: String?
    private(set) var source: WorkshopCreatorAvatarGeometry?
    private(set) var flight: WorkshopCreatorAvatarFlight?
    var progress: CGFloat = 0
    @ObservationIgnored private var geometries: [WorkshopCreatorAvatarKey: WorkshopCreatorAvatarGeometry] = [:]

    func begin(authorID: String, reduceMotion: Bool) {
        cancel()
        guard !reduceMotion, let source = geometries[.init(authorID: authorID, role: .detail)], source.isValid else { return }
        self.authorID = authorID; self.source = source
        prepareFlight()
    }

    func update(_ values: [WorkshopCreatorAvatarKey: WorkshopCreatorAvatarGeometry]) {
        geometries = values
        if let flight, let latest = values[.init(authorID: flight.authorID, role: .gallery)],
           latest.frame != flight.destination.frame {
            // Resizing cancels the flight instead of landing at a stale point.
            cancel(); return
        }
        prepareFlight()
    }

    private func prepareFlight() {
        guard flight == nil, let authorID, let source,
              let destination = geometries[.init(authorID: authorID, role: .gallery)], destination.isValid else { return }
        flight = .init(authorID: authorID, source: source, destination: destination)
    }

    func finish(_ id: UUID) { if flight?.id == id { cancel() } }
    func cancel() { authorID = nil; source = nil; flight = nil; progress = 0 }
}

private struct WorkshopCreatorAvatarGeometryKey: PreferenceKey {
    static let defaultValue: [WorkshopCreatorAvatarKey: WorkshopCreatorAvatarGeometry] = [:]
    static func reduce(value: inout [WorkshopCreatorAvatarKey: WorkshopCreatorAvatarGeometry],
                       nextValue: () -> [WorkshopCreatorAvatarKey: WorkshopCreatorAvatarGeometry]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

private struct WorkshopCreatorAvatarTransitionKey: EnvironmentKey {
    static let defaultValue: WorkshopCreatorAvatarTransition? = nil
}
extension EnvironmentValues {
    var workshopCreatorAvatarTransition: WorkshopCreatorAvatarTransition? {
        get { self[WorkshopCreatorAvatarTransitionKey.self] }
        set { self[WorkshopCreatorAvatarTransitionKey.self] = newValue }
    }
}

private enum WorkshopCreatorAvatarSpace { static let name = "workshop-creator-avatar-navigation" }

struct WorkshopCreatorAvatarAnchor: ViewModifier {
    let authorID: String
    let role: WorkshopCreatorAvatarRole?
    let image: NSImage?
    @Environment(\.workshopCreatorAvatarTransition) private var transition
    func body(content: Content) -> some View {
        content
            .opacity(role != nil && transition?.authorID == authorID ? 0 : 1)
            .background {
                if let role, transition != nil {
                    GeometryReader { geometry in
                        Color.clear.preference(key: WorkshopCreatorAvatarGeometryKey.self,
                            value: [.init(authorID: authorID, role: role): .init(
                                frame: geometry.frame(in: .named(WorkshopCreatorAvatarSpace.name)), image: image)])
                    }
                }
            }
    }
}

struct WorkshopCreatorAvatarTransitionHost: ViewModifier {
    let transition: WorkshopCreatorAvatarTransition
    func body(content: Content) -> some View {
        content
            .environment(\.workshopCreatorAvatarTransition, transition)
            .coordinateSpace(name: WorkshopCreatorAvatarSpace.name)
            .onPreferenceChange(WorkshopCreatorAvatarGeometryKey.self) { transition.update($0) }
            .overlay(alignment: .topLeading) {
                if let source = transition.source {
                    let frame = transition.flight?.frame(at: transition.progress) ?? source.frame
                    Group {
                        if let image = source.image { Image(nsImage: image).resizable().scaledToFill() }
                        else { Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.secondary) }
                    }
                    .frame(width: frame.width, height: frame.height)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .offset(x: frame.minX, y: frame.minY)
                    .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .onChange(of: transition.flight?.id) { _, id in
                guard let id else { return }
                Task { @MainActor in
                    await Task.yield()
                    guard transition.flight?.id == id else { return }
                    withAnimation(.timingCurve(0.22, 0.8, 0.25, 1, duration: 0.46), completionCriteria: .removed) {
                        transition.progress = 1
                    } completion: { transition.finish(id) }
                }
            }
            .onDisappear { transition.cancel() }
    }
}
