import OWEInspectorKit
import SwiftUI

struct WorkshopBrowserView: View {
    @ObservedObject var viewModel: WorkshopViewModel
    var contentViewModel: ContentViewModel
    @State private var hasAPIKey = true
    /// Measured, so the page size leaves room for the pagination row whatever its style.
    @State private var footerHeight: CGFloat = 44

    private func updateItemsPerPage(in geometry: GeometryProxy) {
        let size = CGSize(width: geometry.size.width, height: max(geometry.size.height - footerHeight - 8, 1))
        Task {
            await viewModel.updateItemsPerPage(for: size, itemSize: contentViewModel.navigation.explorerIconSize - 5)
        }
    }

    var body: some View {
        workshopContent
            .padding(.horizontal)
            .padding(.top, 8)
            .onAppear { hasAPIKey = SteamCredentials.webAPIKey().load() != nil }
            .onChange(of: viewModel.searchText) { oldText, newText in
                // The field's clear button empties it: search again from the first page.
                guard newText.isEmpty, !oldText.isEmpty else { return }
                viewModel.currentPage = 1
                Task { await viewModel.search() }
            }
            .toolbar { browserToolbar }
            .confirmationDialog(
                "Download Selected Wallpapers",
                isPresented: $viewModel.isBatchDownloadConfirming
            ) {
                Button("Download \(viewModel.selectedItemIds.count) Wallpapers") {
                    viewModel.downloadSelectedItems()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Download \(viewModel.selectedItemIds.count) selected wallpapers to your library?")
            }
    }

    /// Search first, then the browser's items, then the window's.
    @ToolbarContentBuilder private var browserToolbar: some ToolbarContent {
        ToolbarSearchField.item(text: $viewModel.searchText, prompt: "Search wallpapers...") {
            viewModel.currentPage = 1
            Task { await viewModel.search() }
        }
        // WE shows "Exact phrase" by the search field once the search has a space in it.
        if WorkshopSearchText.offersExactPhrase(viewModel.searchText) {
            ToolbarItem {
                Toggle("Exact phrase", isOn: Binding(get: { viewModel.exactPhrase },
                                                     set: { viewModel.setExactPhrase($0) }))
                    .toggleStyle(.checkbox)
                    .help("Find the words together and in this order")
            }
        }
        if #available(macOS 26, *) {
            ToolbarSpacer(.fixed)
        }
        ToolbarItemGroup {
            if let base = viewModel.presetBase {
                Label {
                    Text("Browsing presets for: \(base.title)", comment: "%@ is a wallpaper title")
                } icon: {
                    Image(systemName: "slider.horizontal.below.square.filled.and.square")
                }
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.secondary)
                Button {
                    viewModel.clearPresetFilter()
                } label: {
                    Label("Clear preset filter", systemImage: "xmark.circle.fill")
                }
                .help("Clear preset filter")
            }
            if viewModel.authorId != nil {
                Label("Author Workshop", systemImage: "person.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.secondary)
                Button {
                    viewModel.clearAuthorFilter()
                } label: {
                    Label("Clear author filter", systemImage: "xmark.circle.fill")
                }
                .help("Clear author filter")
            }
        }
        ToolbarItemGroup {
            if !viewModel.selectedItemIds.isEmpty {
                Button {
                    if viewModel.selectedItemIds.count > 1 {
                        viewModel.isBatchDownloadConfirming = true
                    } else {
                        viewModel.downloadSelectedItems()
                    }
                } label: {
                    Label("Download Selected (\(viewModel.selectedItemIds.count))", systemImage: "arrow.down.circle")
                }
                .labelStyle(.titleAndIcon)
                .help("Download the selected wallpapers")

                Button {
                    viewModel.clearSelection()
                } label: {
                    Label("Clear selection", systemImage: "xmark")
                }
                .help("Clear selection")
            }
        }
        ToolbarItem {
            Button {
                contentViewModel.presentation.isCollectionImportPresented = true
            } label: {
                Label("Import Workshop Collection…", systemImage: "square.stack.3d.down.right")
            }
            .help("Download the items of a Workshop collection")
        }
        ToolbarItem {
            Picker("Sort", selection: $viewModel.sortOrder) {
                ForEach(WorkshopSortOrder.allCases) { order in
                    Text(order.displayName).tag(order)
                }
            }
            .pickerStyle(.menu)
            .help("Sort")
            .onChange(of: viewModel.sortOrder) {
                viewModel.currentPage = 1
                Task { await viewModel.search() }
            }
        }
        WindowActionsToolbar(viewModel: contentViewModel)
    }

    private func searchWithNewKey() {
        hasAPIKey = true
        viewModel.currentPage = 1
        Task { await viewModel.search() }
    }

    private var workshopContent: some View {
        VStack(spacing: 8) {
            // Results
            if viewModel.isLoading && viewModel.items.isEmpty {
                Spacer()
                ProgressView("Searching Workshop…")
                Spacer()
            } else if let error = viewModel.errorMessage, viewModel.items.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text(error)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    SteamWebAPIKeyView(onSaved: searchWithNewKey)
                }
                Spacer()
            } else if viewModel.items.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "sparkle.magnifyingglass")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("Search the Steam Workshop")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text("Find wallpapers by name, tag, or browse trending content.")
                        .font(.callout)
                        .foregroundStyle(.tertiary)

                    if !hasAPIKey {
                        Divider().frame(width: 300).padding(.vertical, 4)
                        Text("A Steam Web API key is required to browse.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        SteamWebAPIKeyView(onSaved: searchWithNewKey)
                    }
                }
                Spacer()
            } else {
                GeometryReader { geometry in
                    VStack(spacing: 8) {
                        LazyVGrid(columns: [
                            GridItem(
                                .adaptive(
                                    minimum: contentViewModel.navigation.explorerIconSize - 5,
                                    maximum: contentViewModel.navigation.explorerIconSize - 5
                                ),
                                spacing: 13
                            )
                        ], alignment: .leading, spacing: 13) {
                            ForEach(viewModel.visibleItems) { item in
                                WorkshopItemCard(item: item, viewModel: viewModel)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                        WorkshopPagination(viewModel: viewModel)
                            .padding(.bottom, 8)
                            .background(GeometryReader { footer in
                                Color.clear.preference(key: WorkshopFooterHeightKey.self, value: footer.size.height)
                            })
                    }
                    .onPreferenceChange(WorkshopFooterHeightKey.self) { footerHeight = $0 }
                    .onAppear { updateItemsPerPage(in: geometry) }
                    .onChange(of: geometry.size) { updateItemsPerPage(in: geometry) }
                    .onChange(of: contentViewModel.navigation.explorerIconSize) { updateItemsPerPage(in: geometry) }
                    .onChange(of: footerHeight) { updateItemsPerPage(in: geometry) }
                }
            }
        }
        .task {
            if viewModel.items.isEmpty {
                await viewModel.search()
            }
        }
    }
}

private struct WorkshopFooterHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 44
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct WorkshopPagination: View {
    @ObservedObject var viewModel: WorkshopViewModel

    var body: some View {
        HStack(spacing: 6) {
            Button {
                viewModel.currentPage -= 1
                Task { await viewModel.search() }
            } label: {
                Image(systemName: "chevron.left")
            }
            .accessibilityLabel(Text("Previous Page"))
            .disabled(viewModel.currentPage == 1 || viewModel.isLoading)

            ForEach(pageNumbers, id: \.self) { page in
                if page == viewModel.currentPage {
                    pageButton(page)
                        .glassButtonStyle(.prominent)
                } else {
                    pageButton(page)
                        .glassButtonStyle()
                }
            }

            Button {
                viewModel.currentPage += 1
                Task { await viewModel.search() }
            } label: {
                Image(systemName: "chevron.right")
            }
            .accessibilityLabel(Text("Next Page"))
            .disabled(!viewModel.hasNextPage || viewModel.isLoading)
        }
    }

    private var pageNumbers: [Int] {
        let firstPage = max(1, viewModel.currentPage - 2)
        let lastPage = viewModel.hasNextPage ? viewModel.currentPage + 2 : viewModel.currentPage
        return Array(firstPage...lastPage)
    }

    private func pageButton(_ page: Int) -> some View {
        Button("\(page)") {
            viewModel.currentPage = page
            Task { await viewModel.search() }
        }
        .disabled(viewModel.isLoading)
    }
}

/// The Workshop tab's filters, in the main window's sidebar. Every change searches again.
/// Within Show Only, Rating, Type, Category and Resolution any checked option matches (OR); genres match
/// all or any, as the toggle beside them says; the sections narrow the results together.
struct WorkshopFiltersSidebar: View {
    @ObservedObject var viewModel: WorkshopViewModel
    @State private var expandedSections: Set<String> = ["Filter Settings", "Show Only", "Rating", "Type", "Category", "Resolution", "Genre"]

    var body: some View {
        List {
            Button {
                viewModel.resetFilters()
            } label: {
                Label("Reset Filters", systemImage: "arrow.triangle.2.circlepath")
                    .frame(maxWidth: .infinity)
            }
            .glassButtonStyle(.prominent)
            .listRowSeparator(.hidden)

            // WE's Workshop Filter Settings: Show Anime or Hide Anime, kept by Reset Filters.
            Section("Filter Settings", isExpanded: isExpanded("Filter Settings")) {
                Toggle("Hide Anime", isOn: Binding(get: { viewModel.filter.hidesAnime },
                                                   set: { viewModel.setHidesAnime($0) }))
                    .toggleStyle(.checkbox)
                    .help("Leaves out wallpapers tagged Anime, MMD, Girls, Guys or Music, unless you check that genre")
            }

            Section("Show Only:", isExpanded: isExpanded("Show Only")) {
                ShowOnlyFilterRows(
                    isOn: { index in
                        WorkshopShowOnly(rawValue: index).map(viewModel.filter.showOnly.contains) ?? false
                    },
                    set: { index, isOn in
                        guard let option = WorkshopShowOnly(rawValue: index) else { return }
                        viewModel.updateFilter { filter in
                            if isOn { filter.showOnly.insert(option) } else { filter.showOnly.remove(option) }
                        }
                    })
            }
            tagSection("Rating", id: "Rating", tags: WorkshopTags.ratings, \.ratings)
            tagSection("Type", id: "Type", tags: WorkshopTags.types, \.types)
            tagSection("Category", id: "Category", tags: WorkshopTags.categories, \.categories)
            Section("Resolution", isExpanded: isExpanded("Resolution")) {
                ResolutionFilterRows(
                    isOn: { viewModel.filter.resolutions.contains($0) },
                    set: { tag, isOn in
                        viewModel.updateFilter { filter in
                            if isOn { filter.resolutions.insert(tag) } else { filter.resolutions.remove(tag) }
                        }
                    })
            }
            Section(isExpanded: isExpanded("Genre")) {
                ForEach(WorkshopTags.genres, id: \.self) { tag in
                    toggle(tag: tag, \.genres)
                }
            } header: {
                HStack {
                    Text("Genre")
                    Spacer()
                    genreMatchToggle
                }
            }
        }
        .listStyle(.sidebar)
    }

    /// States the current genre mode and switches it.
    private var genreMatchToggle: some View {
        let matchesAll = viewModel.filter.genreMatch == .all
        return Button(matchesAll ? "Match all (AND)" : "Match any (OR)") {
            viewModel.updateFilter { $0.genreMatch = matchesAll ? .any : .all }
        }
        .buttonStyle(.link)
        .font(.caption)
        .help(matchesAll
              ? "Showing wallpapers with every checked genre. Click to show wallpapers with any of them."
              : "Showing wallpapers with any checked genre. Click to show only wallpapers with all of them.")
    }

    private func isExpanded(_ title: String) -> Binding<Bool> {
        Binding(
            get: { expandedSections.contains(title) },
            set: { expanded in
                if expanded { expandedSections.insert(title) } else { expandedSections.remove(title) }
            }
        )
    }

    private func tagSection(_ title: LocalizedStringKey, id: String, tags: [String],
                            _ keyPath: WritableKeyPath<WorkshopFilter, Set<String>>) -> some View {
        Section(title, isExpanded: isExpanded(id)) {
            ForEach(tags, id: \.self) { tag in
                toggle(tag: tag, keyPath)
            }
        }
    }

    private func toggle(tag: String,
                        _ keyPath: WritableKeyPath<WorkshopFilter, Set<String>>) -> some View {
        Toggle(isOn: Binding(
            get: { viewModel.filter[keyPath: keyPath].contains(tag) },
            set: { isOn in
                viewModel.updateFilter { filter in
                    if isOn { filter[keyPath: keyPath].insert(tag) } else { filter[keyPath: keyPath].remove(tag) }
                }
            }
        )) {
            Text(LocalizedLabels.filterOption(tag))
        }
        .toggleStyle(.checkbox)
    }
}
