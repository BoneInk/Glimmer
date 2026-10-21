//
//  FilterResults.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/6/29.
//

import SwiftUI

/// The Installed tab's filters, in the main window's sidebar.
struct FilterResults: View {
    var viewModel: FilterResultsViewModel

    @State private var expandedSections: Set<String> = ["Show Only", "Type", "Category", "Age Rating", "Resolution", "Source", "Tags"]

    var body: some View {
        List {
            Button {
                viewModel.reset()
            } label: {
                Label("Reset Filters", systemImage: "arrow.triangle.2.circlepath")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
            }
            .glassButtonStyle(.prominent)
            .listRowSeparator(.hidden)

            Section("Show Only:", isExpanded: isExpanded("Show Only")) {
                ShowOnlyFilterRows(
                    isOn: { viewModel.showOnly.contains(FRShowOnly(rawValue: 1 << $0)) },
                    set: { index, isOn in
                        if isOn {
                            viewModel.showOnly.insert(FRShowOnly(rawValue: 1 << index))
                        } else {
                            viewModel.showOnly.remove(FRShowOnly(rawValue: 1 << index))
                        }
                        OWELog.debug(.ui, "Filter viewModel.showOnly = \(String(describing: viewModel.showOnly))")
                    })
            }
            Section("Type", isExpanded: isExpanded("Type")) {
                toggles(\.type, name: "type")
            }
            Section("Category", isExpanded: isExpanded("Category")) {
                toggles(\.category, name: "category")
            }
            Section("Age Rating", isExpanded: isExpanded("Age Rating")) {
                toggles(\.ageRating, name: "ageRating")
            }
            // Resolution and Tags match the wallpaper's tags, project.json's and the Workshop item's.
            Section("Resolution", isExpanded: isExpanded("Resolution")) {
                ResolutionFilterRows(isOn: resolutionIsOn, set: setResolution)
            }
            // Source isn't matched against wallpapers yet.
            Section("Source", isExpanded: isExpanded("Source")) {
                toggles(\.source, name: "source")
            }
            .disabled(true)
            Section("Tags", isExpanded: isExpanded("Tags")) {
                allNoneButtons(\.tag)
                toggles(\.tag, name: "tag")
            }
        }
        .listStyle(.sidebar)
        .toggleStyle(.checkbox)
        .lineLimit(1)
    }

    private func isExpanded(_ title: String) -> Binding<Bool> {
        Binding(
            get: { expandedSections.contains(title) },
            set: { expanded in
                withAnimation {
                    if expanded { expandedSections.insert(title) } else { expandedSections.remove(title) }
                }
            }
        )
    }

    /// One checkbox per option; option `i` is bit `1 << i`.
    private func toggles<Option: FilterResultsModel>(
        _ keyPath: ReferenceWritableKeyPath<FilterResultsViewModel, Option>, name: String
    ) -> some View {
        ForEach(Array(Option.options.enumerated()), id: \.offset) { i, option in
            Toggle(isOn: Binding<Bool>(get: {
                viewModel[keyPath: keyPath].contains(Option(rawValue: 1 << i))
            }, set: {
                if $0 {
                    viewModel[keyPath: keyPath].insert(Option(rawValue: 1 << i))
                } else {
                    viewModel[keyPath: keyPath].remove(Option(rawValue: 1 << i))
                }
                OWELog.debug(.ui, "Filter viewModel.\(name) = \(String(describing: viewModel[keyPath: keyPath]))")
            })) {
                Text(option.label)
            }
        }
    }

    private func allNoneButtons<Option: FilterResultsModel>(
        _ keyPath: ReferenceWritableKeyPath<FilterResultsViewModel, Option>
    ) -> some View {
        HStack {
            Button("All") {
                viewModel[keyPath: keyPath] = .all
            }
            Button("None") {
                viewModel[keyPath: keyPath] = .none
            }
        }
        .buttonStyle(.link)
    }

    private func resolutionIsOn(_ tag: String) -> Bool {
        bit(\.widescreenResolution, tag) ?? bit(\.ultraWidescreenResolution, tag)
            ?? bit(\.dualscreenResolution, tag) ?? bit(\.triplescreenResolution, tag)
            ?? bit(\.potraitscreenResolution, tag) ?? bit(\.miscResolution, tag) ?? false
    }

    private func setResolution(_ tag: String, _ isOn: Bool) {
        _ = setBit(\.widescreenResolution, tag, isOn) || setBit(\.ultraWidescreenResolution, tag, isOn)
            || setBit(\.dualscreenResolution, tag, isOn) || setBit(\.triplescreenResolution, tag, isOn)
            || setBit(\.potraitscreenResolution, tag, isOn) || setBit(\.miscResolution, tag, isOn)
    }

    /// The stored bit of a resolution tag in the filter group that has it; nil in other groups.
    private func bit<Option: FilterResultsModel>(
        _ keyPath: ReferenceWritableKeyPath<FilterResultsViewModel, Option>, _ tag: String
    ) -> Bool? {
        guard let index = Option.optionKeys.firstIndex(of: tag) else { return nil }
        return viewModel[keyPath: keyPath].contains(Option(rawValue: 1 << index))
    }

    private func setBit<Option: FilterResultsModel>(
        _ keyPath: ReferenceWritableKeyPath<FilterResultsViewModel, Option>, _ tag: String, _ isOn: Bool
    ) -> Bool {
        guard let index = Option.optionKeys.firstIndex(of: tag) else { return false }
        if isOn {
            viewModel[keyPath: keyPath].insert(Option(rawValue: 1 << index))
        } else {
            viewModel[keyPath: keyPath].remove(Option(rawValue: 1 << index))
        }
        return true
    }
}
