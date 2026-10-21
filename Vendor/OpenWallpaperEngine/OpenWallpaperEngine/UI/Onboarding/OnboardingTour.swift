import OWEInspectorKit
import SwiftUI

/// The feature tour the first-run sheet showed, now a page of the setup assistant's welcome step:
/// one page of highlights at a time, with arrows and dots to move between them.
struct OnboardingTour: View {
    @Environment(\.appAccentColor) private var accentColor
    @State private var pageIndex = 0

    private var pages: [Page] { Page.all }

    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(pages[pageIndex].title)
                    .font(.headline)
                Text(pages[pageIndex].subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { pageIndex -= 1 }
                } label: {
                    Label("Back", systemImage: "chevron.left").labelStyle(.iconOnly)
                }
                .disabled(pageIndex == 0)
                HStack(spacing: 5) {
                    ForEach(pages.indices, id: \.self) { index in
                        Circle()
                            .fill(index == pageIndex ? accentColor : Color.secondary.opacity(0.3))
                            .frame(width: 6, height: 6)
                    }
                }
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { pageIndex += 1 }
                } label: {
                    Label("Next", systemImage: "chevron.right").labelStyle(.iconOnly)
                }
                .disabled(pageIndex == pages.count - 1)
            }
            .buttonStyle(.borderless)
            VStack(spacing: 10) {
                ForEach(pages[pageIndex].sections) { section in
                    NewSection(title: section.title,
                               text: section.text,
                               systemImage: section.systemImage,
                               imageColor: section.imageColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .id(pageIndex)
            .transition(.opacity)
        }
    }
}

extension OnboardingTour {
    struct Section: Identifiable {
        let id = UUID()
        let title: LocalizedStringKey
        let text: LocalizedStringKey
        let systemImage: String
        var imageColor: Color = .accentColor
    }

    struct Page {
        let title: LocalizedStringKey
        let subtitle: LocalizedStringKey
        let sections: [Section]

        static let all: [Page] = [
            Page(title: "Welcome to Open Wallpaper Engine",
                 subtitle: "A live wallpaper engine for macOS",
                 sections: [
                    Section(title: "Every Wallpaper Type",
                            text: "Play scene, video, web and image wallpapers, with a familiar layout if you already know Wallpaper Engine.",
                            systemImage: "photo.on.rectangle.angled"),
                    Section(title: "Steam Workshop Built In",
                            text: "Browse, search and subscribe to Workshop items without leaving the app, then set them as your wallpaper in one click.",
                            systemImage: "square.and.arrow.down",
                            imageColor: .blue),
                    Section(title: "One Wallpaper Per Display",
                            text: "Assign a different wallpaper to each screen, or mirror one across all of them.",
                            systemImage: "display.2",
                            imageColor: .purple)
                 ]),
            Page(title: "Scenes, Effects and Music",
                 subtitle: "Powered by a Metal renderer",
                 sections: [
                    Section(title: "Full Effect Stack",
                            text: "Scene wallpapers render through Metal with their authored effects. Videos render the same way, so blur, bloom, tint and the rest apply to them too.",
                            systemImage: "wand.and.stars",
                            imageColor: .purple),
                    Section(title: "Sync to Music",
                            text: "Zoom, pace, tilt and saturation can pulse with audio. A wallpaper with its own soundtrack follows that; when it is silent, it follows whatever else is playing.",
                            systemImage: "waveform",
                            imageColor: .pink),
                    Section(title: "Scene Edit / Export",
                            text: "Edit layers and effects live on the running wallpaper, or switch to iPhone & iPad Export to make a Live Photo lock screen without changing your desktop.",
                            systemImage: "square.stack.3d.up",
                            imageColor: .orange)
                 ]),
            Page(title: "Make It Yours",
                 subtitle: "Playlists, favourites and your own media",
                 sections: [
                    Section(title: "Add Video or Image URLs",
                            text: "Paste a link to any video or image. Images are turned into a scene, so the effect stack applies to them as well.",
                            systemImage: "link",
                            imageColor: .teal),
                    Section(title: "Playlists and Favourites",
                            text: "Change wallpapers on a timer, at login, by time of day or by day of week, with Wallpaper Engine's transitions, and keep the wallpapers you love a click away.",
                            systemImage: "heart.fill",
                            imageColor: .red),
                    Section(title: "Tune Every Property",
                            text: "Adjust volume, playback speed, placement and any property the wallpaper's author exposed, right from the details sidebar.",
                            systemImage: "slider.horizontal.3",
                            imageColor: .indigo)
                 ]),
            Page(title: "Runs Quietly in the Background",
                 subtitle: "You stay in control of resources",
                 sections: [
                    Section(title: "Kind to Your Battery",
                            text: "Choose what happens on battery, when another app goes fullscreen, or when your displays sleep — from keeping wallpapers running to pausing or stopping them.",
                            systemImage: "battery.75",
                            imageColor: .green),
                    Section(title: "Performance You Set",
                            text: "Pick the frame rate, anti-aliasing and texture quality that suit your Mac, and check the Diagnostics page to see the impact.",
                            systemImage: "speedometer",
                            imageColor: .red),
                    Section(title: "Always a Menu Bar Away",
                            text: "Pause, mute or switch wallpapers from the menu bar at any time. Open Settings to fine-tune the rest.",
                            systemImage: "menubar.arrow.up.rectangle",
                            imageColor: .yellow)
                 ])
        ]
    }

    struct NewSection: View {
        var title: LocalizedStringKey
        var text: LocalizedStringKey
        var textColor: Color = .primary
        var systemImage: String
        var imageColor: Color = .accentColor

        var body: some View {
            HStack(alignment: .top, spacing: 4) {
                Image(systemName: systemImage)
                    .frame(width: 40, height: 36)
                    .font(.title)
                    .foregroundStyle(imageColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(textColor)
                        .font(.body)
                        .bold()
                    Text(text)
                        .foregroundStyle(textColor)
                }
                .multilineTextAlignment(.leading)
                Spacer()
            }
        }
    }
}
