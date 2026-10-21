import AppKit
import SwiftUI
import UniformTypeIdentifiers
import OWESceneEditing
import WEFormat

/// What the New Wallpaper sheet needs from the app.
public struct NewWallpaperServices {
    /// The Wallpaper Storage folder, where new wallpapers go.
    public var library: URL
    /// WE's project templates from the user's WE copy (`projects/templates`).
    public var templates: () -> [WallpaperTemplate]
    /// Copies a folder into the library (the app copies without links).
    public var copyFolder: (URL, URL) throws -> Void
    /// Imports folders that are wallpapers already (a project.json); false when none is one.
    public var importWallpapers: ([URL]) -> Bool
    /// A wallpaper was made: the library lists it, and a scene opens in the Wallpaper Editor.
    public var created: (URL, _ isScene: Bool) -> Void

    public init(library: URL, templates: @escaping () -> [WallpaperTemplate], copyFolder: @escaping (URL, URL) throws -> Void,
                importWallpapers: @escaping ([URL]) -> Bool, created: @escaping (URL, Bool) -> Void) {
        self.library = library
        self.templates = templates
        self.copyFolder = copyFolder
        self.importWallpapers = importWallpapers
        self.created = created
    }
}

/// New Wallpaper…, Wallpaper Engine's welcome page and template wizard (`EditorWelcomeModalCtrl`,
/// `editortemplatewizardmodal`): a scene from a picture, resized to a display size when the
/// picture isn't one; a scene from a template (WE's Empty one at a chosen size, or one of the
/// templates of the user's WE copy with its pictures replaced); or a folder imported, a web
/// wallpaper's (with its index.html) or a wallpaper's as it is. The new wallpaper goes into the
/// Wallpaper Storage folder, and a scene opens in the Wallpaper Editor.
public struct NewWallpaperSheet: View {
    enum Page: Hashable { case picture, template, folder }

    private let services: NewWallpaperServices
    private let dismiss: () -> Void
    @State private var page = Page.picture
    @State private var title = ""
    @State private var problem: String?
    // A picture's scene.
    @State private var picture: NewWallpaperBuilder.Picture?
    @State private var schemeColor = Color.black
    @State private var resizes = false
    @State private var resolution: NewWallpaperResolution?
    // A template's.
    @State private var templates: [WallpaperTemplate] = []
    @State private var template: WallpaperTemplate?
    @State private var emptyWidth = 1920
    @State private var emptyHeight = 1080
    @State private var templatePictures: [String: NewWallpaperBuilder.Picture] = [:]
    // An imported folder.
    @State private var folder: URL?

    public init(services: NewWallpaperServices, dismiss: @escaping () -> Void) {
        self.services = services
        self.dismiss = dismiss
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker(selection: $page) {
                Text(L("From a Picture")).tag(Page.picture)
                Text(L("From a Template")).tag(Page.template)
                Text(L("Import Folder")).tag(Page.folder)
            } label: {
                EmptyView()
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(16)
            Form {
                switch page {
                case .picture: picturePage
                case .template: templatePage
                case .folder: folderPage
                }
                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Text(L("New wallpapers go into the Wallpaper Storage folder."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L("Cancel"), role: .cancel, action: dismiss)
                    .keyboardShortcut(.cancelAction)
                Button(L("Create"), action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate)
            }
            .padding(16)
        }
        .frame(width: 560, height: 560)
        .onAppear { templates = services.templates() }
        .onChange(of: page) { _, _ in problem = nil }
    }

    // MARK: Picture

    @ViewBuilder private var picturePage: some View {
        Section {
            LabeledContent(L("Picture")) {
                HStack {
                    Text(picture.map { "\($0.url.lastPathComponent) (\($0.width) × \($0.height))" } ?? L("No file selected"))
                        .foregroundStyle(picture == nil ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button(L("Choose…")) { choosePicture() }
                }
            }
            TextField(L("Title"), text: $title)
            ColorPicker(L("Scheme Color"), selection: $schemeColor, supportsOpacity: false)
        } footer: {
            Text(L("PNG, JPEG, GIF (its first frame) or any picture macOS reads."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if let picture {
            let recommendation = NewWallpaperResolution.recommendation(width: picture.width, height: picture.height)
            Section {
                Toggle(L("Resize Picture"), isOn: $resizes)
                if resizes {
                    Picker(L("Resize To"), selection: $resolution) {
                        ForEach(Array(recommendation.options.enumerated()), id: \.element) { index, option in
                            let name = Self.title(of: option)
                            Text(index == 0 ? L("\(name) (Recommended)") : name)
                                .tag(NewWallpaperResolution?.some(option))
                        }
                    }
                }
            } footer: {
                let width = String(picture.width), height = String(picture.height)
                if recommendation.isPortrait {
                    Text(L("This is a portrait picture of \(width) × \(height) pixels. Unless you have a portrait display, much of it is cut off."))
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if recommendation.suggestsResize {
                    Text(L("This picture is \(width) × \(height) pixels, which isn’t a common display size. Resizing it is recommended."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func choosePicture() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let chosen = try NewWallpaperBuilder.Picture(url: url)
            picture = chosen
            if title.isEmpty || title == L("New Wallpaper") { title = url.deletingPathExtension().lastPathComponent }
            schemeColor = Self.color(NewWallpaperBuilder.dominantColor(of: chosen.image))
            let recommendation = NewWallpaperResolution.recommendation(width: chosen.width, height: chosen.height)
            resizes = recommendation.suggestsResize
            resolution = recommendation.options.first
            problem = nil
        } catch {
            problem = Self.message(error)
        }
    }

    // MARK: Template

    @ViewBuilder private var templatePage: some View {
        Section {
            Picker(L("Template"), selection: $template) {
                Text(L("Empty")).tag(WallpaperTemplate?.none)
                ForEach(templates) { template in
                    Text(verbatim: template.name).tag(WallpaperTemplate?.some(template))
                }
            }
            TextField(L("Title"), text: $title)
            if let template {
                if let preview = template.preview, let image = NSImage(contentsOf: preview) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxHeight: 120)
                }
                ForEach(template.options, id: \.destination) { option in
                    LabeledContent {
                        HStack {
                            Text(templatePictures[option.destination]?.url.lastPathComponent ?? L("No file selected"))
                                .foregroundStyle(templatePictures[option.destination] == nil ? .secondary : .primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button(L("Choose…")) { chooseTemplatePicture(option) }
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: option.name)
                            if !option.description.isEmpty {
                                Text(verbatim: option.description).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } else {
                LabeledContent(L("Size")) {
                    HStack {
                        TextField(L("Width"), value: $emptyWidth, format: .number).frame(width: 70)
                        Text(verbatim: "×")
                        TextField(L("Height"), value: $emptyHeight, format: .number).frame(width: 70)
                    }
                    .labelsHidden()
                }
            }
        } footer: {
            if templates.isEmpty {
                Text(L("Wallpaper Engine’s templates come from your Wallpaper Engine copy (Settings › Assets)."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func chooseTemplatePicture(_ option: WallpaperTemplate.Option) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = option.animatedOnly ? [.gif] : [.image]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            templatePictures[option.destination] = try NewWallpaperBuilder.Picture(url: url)
            problem = nil
        } catch {
            problem = Self.message(error)
        }
    }

    // MARK: Folder

    @ViewBuilder private var folderPage: some View {
        Section {
            LabeledContent(L("Folder")) {
                HStack {
                    Text(folder?.lastPathComponent ?? L("No folder selected"))
                        .foregroundStyle(folder == nil ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button(L("Choose…")) { chooseFolder() }
                }
            }
            if folder.map(isWebFolder) == true {
                TextField(L("Title"), text: $title)
            }
        } footer: {
            Text(L("A web wallpaper’s folder (with its index.html) becomes a web wallpaper. A wallpaper’s folder (with its project.json) is imported as it is."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func isWebFolder(_ url: URL) -> Bool {
        !WEProjectFile.exists(in: url)
            && FileManager.default.fileExists(atPath: url.appending(path: "index.html").path)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        folder = url
        if title.isEmpty { title = url.lastPathComponent }
        let hasProject = WEProjectFile.exists(in: url)
        problem = hasProject || isWebFolder(url) ? nil : L("The folder has no index.html or project.json.")
    }

    // MARK: Create

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var canCreate: Bool {
        switch page {
        case .picture: return picture != nil && !trimmedTitle.isEmpty
        case .template:
            guard !trimmedTitle.isEmpty else { return false }
            guard let template else { return emptyWidth > 0 && emptyHeight > 0 }
            return template.options.allSatisfy { templatePictures[$0.destination] != nil }
        case .folder:
            guard let folder else { return false }
            return isWebFolder(folder) ? !trimmedTitle.isEmpty
                : WEProjectFile.exists(in: folder)
        }
    }

    private func create() {
        let builder = NewWallpaperBuilder()
        do {
            switch page {
            case .picture:
                guard let picture else { return }
                let folder = try builder.scene(from: picture, title: trimmedTitle, schemeColor: Self.text(schemeColor),
                                               resize: resizes ? resolution : nil, in: services.library)
                services.created(folder, true)
            case .template:
                let folder: URL
                if let template {
                    folder = try builder.scene(from: template, title: trimmedTitle, pictures: templatePictures,
                                               in: services.library)
                } else {
                    folder = try builder.emptyScene(title: trimmedTitle, width: emptyWidth, height: emptyHeight,
                                                    in: services.library)
                }
                services.created(folder, true)
            case .folder:
                guard let source = folder else { return }
                if isWebFolder(source) {
                    let made = try builder.webWallpaper(from: source, title: trimmedTitle, in: services.library,
                                                        copy: services.copyFolder)
                    services.created(made, false)
                } else if !services.importWallpapers([source]) {
                    problem = L("The folder has no index.html or project.json.")
                    return
                }
            }
            dismiss()
        } catch {
            problem = Self.message(error)
        }
    }

    // MARK: Text

    static func message(_ error: Error) -> String {
        switch error as? NewWallpaperBuilder.Failure {
        case .unreadableImage(let name)?: return L("\(name) isn’t a picture that can be read.")
        case .noIndexPage?: return L("The folder has no index.html or project.json.")
        case .missingPicture(let name)?: return L("Choose a picture for \(name).")
        case nil: return L("The wallpaper couldn’t be made: \(error.localizedDescription)")
        }
    }

    /// A size as the Resize To menu lists it: its group and pixels (WE's resolution tags).
    static func title(of resolution: NewWallpaperResolution) -> String {
        let size = "\(resolution.width) × \(resolution.height)"
        switch resolution.group {
        case .widescreen: return L("Widescreen: \(size)")
        case .ultrawide: return L("Ultra Widescreen: \(size)")
        case .dual: return L("Dual Monitor: \(size)")
        case .triple: return L("Triple Monitor: \(size)")
        case .portrait: return L("Portrait Monitor / Phone: \(size)")
        }
    }

    static func color(_ text: String) -> Color { PropertyColor.color(text) }
    static func text(_ color: Color) -> String { PropertyColor.text(color) }
}
