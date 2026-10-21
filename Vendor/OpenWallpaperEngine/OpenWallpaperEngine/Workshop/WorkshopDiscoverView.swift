import SwiftUI

/// The Discover tab: WE's curated Workshop lists (`WorkshopDiscover.home`), each a row of cards
/// that scrolls on sideways, and "See More" opens one as a grid that scrolls on downwards. The
/// cards are the Workshop tab's, with its download, preview and context menu.
struct WorkshopDiscoverView: View {
    @ObservedObject var model: WorkshopDiscoverViewModel
    @ObservedObject var workshop: WorkshopViewModel
    var contentViewModel: ContentViewModel
    let cardSize: CGFloat

    var body: some View {
        Group {
            if let section = model.openSection {
                grid(section)
            } else {
                home
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar {
            if model.openSection != nil {
                ToolbarItem(placement: .navigation) {
                    Button {
                        model.openSection = nil
                    } label: {
                        Label("Back", systemImage: "chevron.backward")
                    }
                    .help("Back to Discover")
                }
            }
            ToolbarItem {
                Button {
                    model.reload()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Load the lists again")
            }
            WindowActionsToolbar(viewModel: contentViewModel)
        }
    }

    // MARK: Home

    private var home: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                if model.needsAPIKey { apiKeyNotice }
                ForEach(model.visibleSections) { section in
                    sectionRow(section)
                }
            }
            .padding()
        }
    }

    private func sectionRow(_ section: WorkshopDiscoverSection) -> some View {
        let row = model.row(section)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(section.title.text)
                    .font(.title3.bold())
                Spacer()
                Button("See More") { model.openSection = section }
                    .buttonStyle(.link)
                    .disabled(row.items.isEmpty)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 13) {
                    ForEach(row.items) { item in
                        card(item, in: row.items)
                            .frame(width: cardSize, height: cardSize)
                            .onAppear { loadMoreIfLast(item, in: section) }
                    }
                    if row.isLoading || (row.items.isEmpty && row.error == nil) {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: cardSize / 2, height: cardSize)
                    }
                }
            }
            .frame(height: cardSize)
            if let error = row.error, !model.needsAPIKey {
                errorRow(error, section: section)
            }
        }
        .task { await model.loadIfNeeded(section) }
    }

    // MARK: See More

    private func grid(_ section: WorkshopDiscoverSection) -> some View {
        let row = model.row(section)
        return ScrollView {
            VStack(alignment: .leading, spacing: 13) {
                Text(section.title.text)
                    .font(.title2.bold())
                if model.needsAPIKey { apiKeyNotice }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: cardSize, maximum: cardSize), spacing: 13)],
                          alignment: .leading, spacing: 13) {
                    ForEach(row.items) { item in
                        card(item, in: row.items)
                            .onAppear { loadMoreIfLast(item, in: section) }
                    }
                }
                if row.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else if let error = row.error, !model.needsAPIKey {
                    errorRow(error, section: section)
                }
            }
            .padding()
        }
        .task(id: section.id) { await model.loadIfNeeded(section) }
    }

    // MARK: Parts

    /// A card; ⇧-click selects a run within `list`, its row or grid.
    private func card(_ item: WorkshopItem, in list: [WorkshopItem]) -> some View {
        WorkshopItemCard(item: item, viewModel: workshop, selectionOrder: list)
    }

    private func loadMoreIfLast(_ item: WorkshopItem, in section: WorkshopDiscoverSection) {
        guard model.row(section).items.last?.id == item.id else { return }
        Task { await model.loadMore(section) }
    }

    private func errorRow(_ error: String, section: WorkshopDiscoverSection) -> some View {
        HStack {
            Label(error, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Button("Try Again") { Task { await model.loadMore(section) } }
        }
        .font(.callout)
    }

    private var apiKeyNotice: some View {
        VStack(spacing: 8) {
            Text("A Steam Web API key is required to browse.")
                .foregroundStyle(.secondary)
            SteamWebAPIKeyView(onSaved: { model.reload() })
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical)
    }
}

extension WorkshopDiscoverSection.Title {
    /// The list's heading, in WE's wording.
    var text: LocalizedStringResource {
        switch self {
        case .popularRightNow:
            return LocalizedStringResource("Popular Right Now", comment: "Discover list: the month's most popular approved wallpapers")
        case .mostPopularWeek:
            return LocalizedStringResource("Most Popular (Week)", comment: "Discover list: the week's most popular wallpapers")
        case .recentApproved:
            return LocalizedStringResource("Recent Approved Wallpapers", comment: "Discover list: the newest wallpapers the Wallpaper Engine team approved")
        case .topRated:
            return LocalizedStringResource("Top Rated", comment: "Discover list and sort order: the highest rated wallpapers")
        case .popularApproved:
            return LocalizedStringResource("Popular Approved Wallpapers", comment: "Discover list: the year's most popular approved wallpapers")
        case .popularGenre(let tag):
            let genre = String(localized: LocalizedLabels.filterOption(tag))
            return LocalizedStringResource("Popular \(genre) Wallpapers", comment: "Discover list; %@ is a Workshop genre or tag, such as Anime")
        }
    }
}
