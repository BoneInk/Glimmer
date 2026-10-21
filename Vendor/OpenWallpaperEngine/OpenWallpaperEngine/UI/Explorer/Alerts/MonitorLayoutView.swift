import OWEInspectorKit
import SwiftUI

// MARK: - Monitor Layout View

/// The displays as arranged in System Settings: click to select, Shift-click to add to the
/// selection, right-click for WE's monitor menu (stretch and clone groups, the main clone display,
/// flip, splits, Copy to and Swap with, and mute). Each group is outlined around its displays, a stretch with a solid line
/// and a clone with a dashed one; a split display shows its regions, each selectable.
struct MonitorLayoutView: View {
    @ObservedObject var wallpaperViewModel: WallpaperViewModel
    @State private var isFlipLimitationShown = false
    /// The display or region being split, or the split being edited (`DisplaySplitSheet`).
    @State private var splitEdit: DisplaySplitSheet.Edit?

    var body: some View {
        let screens = NSScreen.screens
        let bounds = combinedBounds(screens)
        let resolution = wallpaperViewModel.layoutResolution

        GeometryReader { geo in
            let scale = min(
                geo.size.width / max(bounds.width, 1),
                geo.size.height / max(bounds.height, 1)
            ) * 0.85
            let origin = CGPoint(x: (geo.size.width - bounds.width * scale) / 2,
                                 y: (geo.size.height - bounds.height * scale) / 2)
            let rect = { (frame: CGRect) -> CGRect in
                CGRect(x: origin.x + (frame.origin.x - bounds.origin.x) * scale,
                       y: origin.y + (bounds.height - (frame.origin.y - bounds.origin.y) - frame.height) * scale,
                       width: frame.width * scale, height: frame.height * scale)
            }

            ZStack {
                ForEach(resolution.stretches) { stretch in
                    GroupOutline(rect: rect(stretch.canvas).insetBy(dx: -6, dy: -6), isStretch: true)
                }
                ForEach(resolution.clones) { clone in
                    let members = screens.filter { clone.screens.contains(WallpaperViewModel.screenId(for: $0)) }
                    GroupOutline(rect: members.map { rect($0.frame) }.reduce(CGRect.null) { $0.union($1) }
                        .insetBy(dx: -6, dy: -6), isStretch: false)
                }

                ForEach(screens, id: \.self) { screen in
                    let screenId = WallpaperViewModel.screenId(for: screen)
                    if let regions = resolution.regions[screenId] {
                        ForEach(regions, id: \.id) { region in
                            tile(region.id, name: displayName(region.id), frame: rect(region.rect), isMain: false)
                        }
                    } else {
                        tile(screenId, name: WallpaperViewModel.screenName(for: screen), frame: rect(screen.frame),
                             isMain: screen == .main)
                    }
                }
            }
        }
        .alert("Flip Clone Display", isPresented: $isFlipLimitationShown) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("At least one display must be the source display and cannot be flipped.")
        }
        .sheet(item: $splitEdit) { edit in
            DisplaySplitSheet(edit: edit) { split in
                if edit.isNew {
                    wallpaperViewModel.split(edit.id, split)
                } else {
                    wallpaperViewModel.editSplit(edit.id, split)
                }
            }
        }
    }

    /// A display's or region's tile.
    private func tile(_ id: String, name: String, frame: CGRect, isMain: Bool) -> some View {
        MonitorRectangle(
            name: name,
            wallpaperTitle: wallpaperViewModel.wallpaper(for: id).project.title,
            isSelected: wallpaperViewModel.selectedScreenIds.contains(id),
            isEnabled: wallpaperViewModel.isScreenEnabled(id),
            isMain: isMain,
            isMainCloneDisplay: wallpaperViewModel.isMainCloneDisplay(id),
            isFlipped: wallpaperViewModel.isFlipped(id),
            isMuted: wallpaperViewModel.isMuted(id)
        )
        .frame(width: frame.width, height: frame.height)
        .position(x: frame.midX, y: frame.midY)
        .onTapGesture {
            wallpaperViewModel.selectScreen(id, extendingSelection: NSEvent.modifierFlags.contains(.shift))
        }
        .contextMenu { menu(for: id, name: name) }
    }

    /// WE's monitor menu for the display or region `id`.
    @ViewBuilder
    private func menu(for id: String, name: String) -> some View {
        let model = wallpaperViewModel
        let isCloned = model.isCloned(id)
        let isRegion = model.isSplitRegion(id)
        // WE offers groups on whole displays only, not on a split's regions.
        if model.displayLayout.layout == .perDisplay, !isRegion {
            let selection = model.selectedScreenIds.union([id]).filter { !$0.contains("/") }
            Button("Add Stretch Group") { model.addStretchGroup(selection) }
                .disabled(selection.count < 2)
            Button("Add Clone Group") { model.addCloneGroup(selection) }
                .disabled(selection.count < 2)
            if isCloned || model.isStretched(id) {
                Button("Remove from Group") { model.removeFromGroup(id) }
                Button("Remove Group") { model.removeGroup(containing: id) }
            }
        }
        if isCloned {
            Divider()
            if model.isChosenMainCloneDisplay(id) {
                Button("Remove Main Clone Display") { model.setMainCloneDisplay(id, false) }
            } else {
                Button("Set as Main Clone Display") { model.setMainCloneDisplay(id, true) }
            }
            Toggle("Flip Clone Display", isOn: Binding(
                get: { model.isFlipped(id) },
                set: { _ in if !model.toggleFlip(id) { isFlipLimitationShown = true } }
            ))
        }
        if model.canSplit(id) || isRegion {
            Divider()
            if model.canSplit(id), let rect = model.displayRect(of: id) {
                Button("Add Split") { splitEdit = DisplaySplitSheet.Edit(id: id, name: name, size: rect.size, split: nil) }
            }
            if let parent = model.parentSplit(of: id), let rect = model.splitRect(of: parent.id) {
                Button("Edit Split") {
                    splitEdit = DisplaySplitSheet.Edit(id: parent.id, name: name, size: rect.size, split: parent.split)
                }
                Button("Remove Split") { model.removeSplit(id) }
                Button("Remove All Splits") { model.removeAllSplits(id) }
            }
        }
        // WE's Copy to and Swap with, before Mute as in WE's menu.
        let transferTargets = model.transferTargets(from: id)
        if !transferTargets.isEmpty {
            Divider()
            Menu("Copy to") {
                ForEach(transferTargets, id: \.self) { target in
                    Button(displayName(target)) { model.copyWallpaper(from: id, to: target) }
                }
            }
            Menu("Swap with") {
                ForEach(transferTargets, id: \.self) { target in
                    Button(displayName(target)) { model.swapWallpapers(id, target) }
                }
            }
        }
        Divider()
        if model.isMuted(id) {
            Button("Unmute") { model.toggleMute(id) }
        } else {
            Button("Mute") { model.toggleMute(id) }
        }
    }

    /// The name a display or a split display's region goes by, as its tile shows it.
    private func displayName(_ id: String) -> String {
        let screenId = DisplayLayoutResolution.screen(of: id)
        guard let screen = NSScreen.screens.first(where: { WallpaperViewModel.screenId(for: $0) == screenId }) else { return id }
        let name = WallpaperViewModel.screenName(for: screen)
        guard let index = wallpaperViewModel.layoutResolution.regions[screenId]?.firstIndex(where: { $0.id == id }) else {
            return name
        }
        return String(localized: "\(name) Split \(index + 1)")
    }

    private func combinedBounds(_ screens: [NSScreen]) -> CGRect {
        screens.reduce(.zero) { $0.union($1.frame) }
    }
}

// MARK: - Group outline

/// A group's outline: solid around a stretch (one wallpaper over the canvas, gaps included),
/// dashed around a clone, each labelled.
private struct GroupOutline: View {
    @Environment(\.appAccentColor) private var accentColor
    let rect: CGRect
    let isStretch: Bool

    var body: some View {
        let color = isStretch ? Color.teal : accentColor
        RoundedRectangle(cornerRadius: 10)
            .strokeBorder(color.opacity(0.75),
                          style: StrokeStyle(lineWidth: 2, dash: isStretch ? [] : [6, 4]))
            .overlay(alignment: .topLeading) {
                Text(isStretch ? "Stretch Group" : "Clone Group")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(color)
                    .padding(.horizontal, 4)
                    .background(.background, in: Capsule())
                    .offset(x: 8, y: -7)
            }
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .allowsHitTesting(false)
            .accessibilityElement(children: .combine)
    }
}

// MARK: - Monitor Rectangle

struct MonitorRectangle: View {
    let name: String
    let wallpaperTitle: String
    let isSelected: Bool
    let isEnabled: Bool
    let isMain: Bool
    var isMainCloneDisplay = false
    var isFlipped = false
    var isMuted = false

    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(isEnabled ? Color(nsColor: .controlBackgroundColor) : Color(nsColor: .separatorColor).opacity(0.3))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: isSelected ? 0 : 1)
            )
            .selectionHighlight(isSelected, cornerRadius: 6)
            .overlay {
                VStack(spacing: 2) {
                    HStack(spacing: 4) {
                        if isMain {
                            Image(systemName: "star.fill")
                                .font(.caption2)
                                .foregroundStyle(.yellow)
                        }
                        Text(name)
                            .font(.caption)
                            .fontWeight(.medium)
                            .lineLimit(1)
                    }
                    if isEnabled {
                        Text(wallpaperTitle.isEmpty ? String(localized: "No wallpaper") : wallpaperTitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text("Disabled")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    badges
                }
                .padding(4)
            }
    }

    @ViewBuilder private var badges: some View {
        if isMainCloneDisplay || isFlipped || isMuted {
            HStack(spacing: 6) {
                if isMainCloneDisplay {
                    Image(systemName: "rectangle.on.rectangle")
                        .accessibilityLabel(Text("Main Clone Display"))
                        .help(Text("Main Clone Display"))
                }
                if isFlipped {
                    Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                        .accessibilityLabel(Text("Flipped"))
                        .help(Text("Flipped"))
                }
                if isMuted {
                    Image(systemName: "speaker.slash.fill")
                        .accessibilityLabel(Text("Muted"))
                        .help(Text("Muted"))
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }
}
