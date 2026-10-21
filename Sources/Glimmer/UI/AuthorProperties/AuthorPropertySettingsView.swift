import AppKit
import SwiftUI

/// 嵌入父级的 ScrollView；不创建背景、播放器或运行时，不在打开时提交设置。
@MainActor
struct AuthorPropertySettingsView: View {
    let project: AuthorPropertyProject
    let overrideStore: AuthorPropertyOverrideStore
    let itemID: UUID
    let capabilities: AuthorPropertyEditingCapabilities
    let resourceActions: AuthorPropertyResourceActions?
    let preferredLanguages: [String]
    let showsOnlyEditableProperties: Bool
    let sceneUnreferencedScalarKeys: Set<String>
    let onValuesChanged: @MainActor ([String: GWJSONValue]) async throws -> Void

    @GlassState private var session: AuthorPropertySettingsSession?
    @GlassState private var searchText = ""
    @GlassState private var modifiedOnly = false
    @GlassState private var resourcePanel: NSOpenPanel?

    init(project: AuthorPropertyProject, overrideStore: AuthorPropertyOverrideStore, itemID: UUID,
         capabilities: AuthorPropertyEditingCapabilities, resourceActions: AuthorPropertyResourceActions? = nil,
         preferredLanguages: [String] = Locale.preferredLanguages,
         showsOnlyEditableProperties: Bool = false,
         sceneUnreferencedScalarKeys: Set<String> = [],
         onValuesChanged: @escaping @MainActor ([String: GWJSONValue]) async throws -> Void) {
        self.project = project
        self.overrideStore = overrideStore
        self.itemID = itemID
        self.capabilities = capabilities
        self.resourceActions = resourceActions
        self.preferredLanguages = preferredLanguages
        self.showsOnlyEditableProperties = showsOnlyEditableProperties
        self.sceneUnreferencedScalarKeys = sceneUnreferencedScalarKeys
        self.onValuesChanged = onValuesChanged
    }

    private struct Identity: Hashable {
        let itemID: UUID
        let source: Data
        let capabilities: AuthorPropertyEditingCapabilities
        let store: ObjectIdentifier
        let resourcesAvailable: Bool
    }

    private var sourceSession: AuthorPropertySettingsSession? {
        guard let session, session.itemID == itemID,
              session.project.sourceData == project.sourceData else { return nil }
        return session
    }
    private var effectiveCapabilities: AuthorPropertyEditingCapabilities {
        AuthorPropertySettingsSummary.effectiveCapabilities(capabilities, session: sourceSession)
    }
    private var currentSession: AuthorPropertySettingsSession? {
        guard let sourceSession, sourceSession.capabilities == effectiveCapabilities else { return nil }
        return sourceSession
    }
    private var optionCount: Int {
        project.properties.filter {
            $0.kind != .text && (!showsOnlyEditableProperties || effectiveCapabilities.allows($0, project: project,
                values: currentSession?.values ?? project.resolve(overrides: [:]).values))
        }.count
    }

    var body: some View {
        GlassStyleReader { style in
            VStack(alignment: .leading, spacing: 12) {
                heading
                if effectiveCapabilities.editableKeys.isEmpty {
                    Text(capabilities.unsupportedReason.isEmpty ? "当前壁纸尚未支持修改这些选项，可查看作者提供的值。" : capabilities.unsupportedReason)
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let session = currentSession {
                    if session.isLoading {
                        ProgressView("正在读取作者设置…").controlSize(.small)
                    } else {
                        filters(session, style: style)
                        if !session.isReady {
                            feedback(session)
                        } else {
                            propertyList(session, style: style)
                            feedback(session)
                        }
                    }
                } else {
                    ProgressView("正在读取作者设置…").controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: Identity(itemID: itemID, source: project.sourceData,
                           capabilities: effectiveCapabilities, store: ObjectIdentifier(overrideStore), resourcesAvailable: resourceActions != nil)) {
            resourcePanel?.cancel(nil)
            resourcePanel = nil
            session = nil
            let candidate = AuthorPropertySettingsSession(project: project, overrideStore: overrideStore,
                itemID: itemID, capabilities: effectiveCapabilities, resourceActions: resourceActions, onValuesChanged: onValuesChanged)
            await candidate.load()
            guard !Task.isCancelled else { return }
            session = candidate
        }
        .onDisappear {
            resourcePanel?.cancel(nil)
            resourcePanel = nil
        }
        .onChange(of: itemID) { _, _ in searchText = ""; modifiedOnly = false }
        .accessibilityIdentifier("author-property-settings")
    }

    private var heading: some View {
        Text("作者设置").font(.callout.weight(.semibold)).foregroundStyle(.secondary)
        .accessibilityIdentifier("author-property-summary")
    }

    @ViewBuilder private func filters(_ session: AuthorPropertySettingsSession, style: GlassStyle) -> some View {
        let hasModified = project.properties.contains { session.isModified($0.key) }
        if optionCount > 8 || hasModified || modifiedOnly {
            VStack(spacing: 10) {
                if optionCount > 8 {
                    HStack(spacing: 9) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("搜索作者设置", text: $searchText)
                            .textFieldStyle(.plain)
                            .accessibilityIdentifier("author-property-search")
                        if !searchText.isEmpty {
                            Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.borderless).accessibilityLabel("清除作者设置搜索")
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(style.groupedBackground(cornerRadius: 14))
                }
                if hasModified || modifiedOnly {
                    HStack(spacing: 12) {
                        Toggle("仅已修改", isOn: $modifiedOnly)
                            .toggleStyle(.switch).controlSize(.small).font(.callout)
                            .accessibilityIdentifier("author-property-modified-only")
                        Spacer(minLength: 8)
                        if hasModified {
                            Button("重置") { session.resetEditable() }
                                .buttonStyle(.glass).controlSize(.small)
                                .disabled(session.editableModifiedKeys.isEmpty || !session.isReady || session.isSaving)
                                .help("恢复当前播放器可编辑的选项；保留未知或尚未支持的保存值")
                                .accessibilityIdentifier("author-property-reset-all")
                        }
                    }
                }
            }
        }
    }

    private func visibleDefinitions(_ session: AuthorPropertySettingsSession) -> [AuthorPropertyDefinition] {
        let query = optionCount > 8 ? searchText.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        return project.properties.filter { definition in
            if showsOnlyEditableProperties && !effectiveCapabilities.allows(definition, project: project, values: session.values) { return false }
            if case .hidden = project.visibility(for: definition.key, values: session.values) { return false }
            if modifiedOnly && !session.isModified(definition.key) { return false }
            return query.isEmpty || localized(definition.text).localizedCaseInsensitiveContains(query)
                || definition.key.localizedCaseInsensitiveContains(query)
        }
    }

    @ViewBuilder private func propertyList(_ session: AuthorPropertySettingsSession, style: GlassStyle) -> some View {
        let definitions = visibleDefinitions(session)
        if definitions.isEmpty {
            VStack(spacing: 9) {
                Image(systemName: "slider.horizontal.3").font(.title2).foregroundStyle(.secondary)
                Text(project.properties.isEmpty ? "这个项目没有作者选项" : "没有符合筛选的可见选项")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 24)
        } else {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(definitions) { definition in
                    if definition.kind == .text {
                        Text(localized(definition.text))
                            .font(.callout.weight(.semibold))
                            .textSelection(.enabled)
                            .padding(.top, 8)
                            .accessibilityAddTraits(.isHeader)
                    } else {
                        propertyRow(definition, session: session, style: style)
                    }
                }
            }
        }
    }

    private func propertyRow(_ definition: AuthorPropertyDefinition,
                             session: AuthorPropertySettingsSession, style: GlassStyle) -> some View {
        let inline = definition.kind == .bool || definition.kind == .color || definition.kind == .combo
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(localized(definition.text)).font(.callout.weight(.medium)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if inline {
                    editor(definition, session: session)
                        .disabled(definition.isEditableSchema && !session.canEdit(definition))
                        .accessibilityLabel(localized(definition.text))
                        .frame(maxWidth: definition.kind == .combo ? 180 : nil, alignment: .trailing)
                }
                if definition.isEditableSchema && session.isModified(definition.key) {
                    Button { session.reset(definition) } label: { Image(systemName: "arrow.counterclockwise") }
                        .buttonStyle(.glass).controlSize(.small)
                        .disabled(!session.canEdit(definition))
                        .help("恢复此项默认值")
                        .accessibilityLabel("恢复\(localized(definition.text))的默认值")
                        .accessibilityIdentifier("author-property-reset-\(definition.key)")
                }
            }
            if !inline {
                editor(definition, session: session)
                    .disabled(definition.isEditableSchema && !session.canEdit(definition))
            }
            if case .unsupported(let reason) = project.visibility(for: definition.key, values: session.values) {
                Label("此选项的显示条件暂不支持：\(reason)", systemImage: "lock")
                    .font(.caption).foregroundStyle(.secondary)
            } else if definition.isEditableSchema, !capabilities.editableKeys.isEmpty,
                      !capabilities.editableKeys.contains(definition.key) {
                Label("当前播放器尚不支持修改此项", systemImage: "lock")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if sceneUnreferencedScalarKeys.contains(definition.key) {
                Label("未在原作中找到此选项的绑定，可能不会改变画面", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("author-property-usage-\(definition.key)")
            }
            ForEach(session.diagnostics.filter { $0.key == definition.key }, id: \.self) { diagnostic in
                Text(diagnostic.message).font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(style.groupedBackground(cornerRadius: 16))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("author-property-\(definition.key)")
    }

    @ViewBuilder private func editor(_ definition: AuthorPropertyDefinition,
                                    session: AuthorPropertySettingsSession) -> some View {
        let value = session.values[definition.key] ?? definition.defaultValue
        switch definition.kind {
        case .bool:
            Toggle(localized(definition.text), isOn: Binding(
                get: { session.values[definition.key]?.boolValue ?? false },
                set: { session.set(.bool($0), for: definition) }))
                .toggleStyle(.switch).labelsHidden()
        case .color:
            ColorPicker(localized(definition.text), selection: Binding(
                get: { color(session.values[definition.key]?.stringValue ?? "0 0 0") },
                set: { session.set(.string(rgb($0)), for: definition) }), supportsOpacity: false)
                .labelsHidden()
        case .slider:
            slider(definition, session: session)
        case .combo:
            if definition.options.isEmpty || definition.options.contains(where: { $0.value == nil }) {
                Text("作者的选项定义不完整，当前仅供查看。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Picker(localized(definition.text), selection: Binding<GWJSONValue>(
                    get: { session.values[definition.key] ?? .null },
                    set: { session.set($0, for: definition) })) {
                    if session.values[definition.key] == nil { Text("未设置").tag(GWJSONValue.null).disabled(true) }
                    ForEach(definition.options) { option in
                        if let value = option.value { Text(localized(option.label)).tag(value) }
                    }
                }
                .pickerStyle(.menu).labelsHidden()
            }
        case .textinput:
            TextField(localized(definition.text), text: Binding(
                get: { session.values[definition.key]?.stringValue ?? "" },
                set: { session.set(.string($0), for: definition) }), axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(1...4)
        case .file, .directory:
            VStack(alignment: .leading, spacing: 8) {
                let selectedPath = value?.stringValue ?? ""
                Text(selectedPath.isEmpty ? "未选择" : definition.kind == .directory ? "已授权文件夹" : (selectedPath as NSString).lastPathComponent)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                HStack(spacing: 10) {
                    Button(definition.kind == .directory ? "选择文件夹…" : "选择文件…") {
                        Task { await choosePath(definition, session: session) }
                    }
                    .accessibilityIdentifier("author-property-choose-\(definition.key)")
                    if definition.kind == .directory {
                        Button("刷新") { session.performResource(.refresh, for: definition) }
                            .disabled(selectedPath.isEmpty)
                            .help("重新扫描已授权目录并更新壁纸资源")
                            .accessibilityIdentifier("author-property-refresh-\(definition.key)")
                    }
                    Button("清除") { session.performResource(.clear, for: definition) }
                        .disabled(selectedPath.isEmpty)
                        .accessibilityIdentifier("author-property-clear-\(definition.key)")
                }
                .buttonStyle(.glass).controlSize(.small)
                .disabled(session.isSaving || resourcePanel != nil)
                if resourceActions == nil {
                    Text("暂不支持资源选项").font(.caption).foregroundStyle(.secondary)
                }
            }

        case .unknown:
            Text("暂不支持此作者选项")
                .font(.caption).foregroundStyle(.secondary)
        case .text:
            EmptyView()
        }
    }

    @ViewBuilder private func slider(_ definition: AuthorPropertyDefinition,
                                    session: AuthorPropertySettingsSession) -> some View {
        if let minimum = definition.minimum, let maximum = definition.maximum,
           minimum.isFinite, maximum.isFinite, minimum < maximum {
            let binding = Binding<Double>(
                get: { min(max(session.values[definition.key]?.numberValue ?? minimum, minimum), maximum) },
                set: { proposed in
                    let number = definition.fraction == true ? proposed : proposed.rounded()
                    session.set(.number(min(max(number, minimum), maximum)), for: definition)
                })
            VStack(spacing: 7) {
                HStack(spacing: 14) {
                    if let step = definition.step, step.isFinite, step > 0 {
                        Slider(value: binding, in: minimum...maximum, step: step)
                    } else if definition.fraction != true {
                        Slider(value: binding, in: minimum...maximum, step: 1)
                    } else {
                        Slider(value: binding, in: minimum...maximum)
                    }
                    Text(numberText(session.values[definition.key]?.numberValue ?? minimum, precision: definition.precision))
                        .font(.callout.monospacedDigit()).frame(minWidth: 50, alignment: .trailing)
                }
                .accessibilityLabel(localized(definition.text))
                HStack {
                    Text(numberText(minimum, precision: definition.precision))
                    Spacer()
                    Text(numberText(maximum, precision: definition.precision))
                }
                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
        } else {
            Text(session.values[definition.key]?.numberValue.map { numberText($0, precision: definition.precision) } ?? "作者未提供有效滑块范围")
                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func feedback(_ session: AuthorPropertySettingsSession) -> some View {
        if session.isSaving {
            ProgressView().controlSize(.small)
        }
        if let error = session.errorText {
            VStack(alignment: .leading, spacing: 10) {
                Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                    .accessibilityIdentifier("author-property-error")
                if !session.isReady || session.canRetry {
                    Button("重试") {
                        if session.isReady { session.retry() } else { Task { await session.load() } }
                    }
                    .buttonStyle(.glass).controlSize(.small).disabled(session.isSaving)
                }
            }
        }
    }

    private func localized(_ text: String) -> String {
        project.localizedText(text, preferredLanguages: preferredLanguages)
    }

    private func numberText(_ number: Double, precision: Int?) -> String {
        if let precision { return String(format: "%.*f", precision, number) }
        return number.formatted(.number.precision(.fractionLength(0...4)))
    }

    private func color(_ value: String) -> Color {
        let rgb = value.split(whereSeparator: \.isWhitespace).compactMap { Double($0) }
        guard rgb.count == 3, rgb.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return .black }
        return Color(.sRGB, red: rgb[0], green: rgb[1], blue: rgb[2], opacity: 1)
    }

    private func rgb(_ color: Color) -> String {
        guard let value = NSColor(color).usingColorSpace(.sRGB) else { return "0 0 0" }
        return String(format: "%.8g %.8g %.8g", locale: Locale(identifier: "en_US_POSIX"),
                      min(max(value.redComponent, 0), 1), min(max(value.greenComponent, 0), 1), min(max(value.blueComponent, 0), 1))
    }

    private func choosePath(_ definition: AuthorPropertyDefinition, session: AuthorPropertySettingsSession) async {
        guard session.canEdit(definition), resourceActions != nil, !session.isSaving, resourcePanel == nil else { return }
        let panel = NSOpenPanel()
        resourcePanel = panel
        panel.title = localized(definition.text)
        panel.canChooseDirectories = definition.kind == .directory
        panel.canChooseFiles = definition.kind == .file
        panel.allowsMultipleSelection = false
        let response = await panel.begin()
        guard resourcePanel === panel else { return }
        resourcePanel = nil
        guard response == .OK, !Task.isCancelled, self.session === session, let url = panel.url else { return }
        session.performResource(.select(url), for: definition)
    }
}
